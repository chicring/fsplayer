//
//  FSMetalRenderer.m
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2022/11/23.
//  Copyright © 2022 debugly's Awesome FFmpeg Tutotial. All rights reserved.
//

#import "FSMetalRenderer.h"
#import "FSMathUtilities.h"
#import "FSMetalPipelineMeta.h"
#include "../ijksdl_log.h"
#include <stdint.h>
#include <string.h>
#include <limits.h>

static const NSUInteger kFSHDRUniformBufferSlots = 3;

static const char *fs_hdr_content_type_name(int contentType)
{
    switch (contentType) {
        case FS_HDR_CONTENT_TYPE_HDR10:
            return "hdr10";
        case FS_HDR_CONTENT_TYPE_HLG:
            return "hlg";
        case FS_HDR_CONTENT_TYPE_DOLBY_VISION_LL:
            return "dolby-vision-ll";
        default:
            return "sdr";
    }
}

static const char *fs_hdr_decode_path_name(int decodePath)
{
    switch (decodePath) {
        case FS_HDR_DECODE_PATH_VIDEOTOOLBOX:
            return "videotoolbox";
        case FS_HDR_DECODE_PATH_FFMPEG_SOFTWARE:
            return "ffmpeg-sw";
        default:
            return "unknown";
    }
}

static const char *fs_hdr_colorspace_name(FSColorSpace colorSpace)
{
    switch (colorSpace) {
        case FSColorSpaceBT2100_PQ:
            return "bt2100-pq";
        case FSColorSpaceSCRGB:
            return "scrgb";
        case FSColorSpaceUnknown:
            return "unknown";
        default:
            return "bt709";
    }
}

static const char *fs_hdr_matrix_name(FSYUV2RGBColorMatrixType matrixType)
{
    switch (matrixType) {
        case FSYUV2RGBColorMatrixBT2020:
            return "bt2020";
        case FSYUV2RGBColorMatrixBT601:
            return "bt601";
        case FSYUV2RGBColorMatrixBT709:
            return "bt709";
        default:
            return "none";
    }
}

static uint32_t fs_hdr_log_signature(FSHDRFrameInfo frameInfo,
                                     FSHDRRenderIntent renderIntent,
                                     FSMetalPipelineMeta *pipelineMeta)
{
    uint32_t signature = 0;
    uint32_t headroomQ = (uint32_t)FFMIN(FFMAX((int)(renderIntent.outputHeadroom * 100.0f + 0.5f), 0), 0x3ff);
    signature |= (uint32_t)(frameInfo.content_type & 0x7);
    signature |= (uint32_t)(frameInfo.decode_path & 0x3) << 3;
    signature |= (uint32_t)(renderIntent.outputColorSpace & 0x7) << 5;
    signature |= (uint32_t)(renderIntent.useDolbyVisionShader & 0x1) << 8;
    signature |= (uint32_t)(renderIntent.needsToneMapping & 0x1) << 9;
    signature |= (uint32_t)(renderIntent.needsGamutMapping & 0x1) << 10;
    signature |= (uint32_t)(renderIntent.needsHDRDrawable & 0x1) << 11;
    signature |= (uint32_t)(pipelineMeta.convertMatrixType & 0x7) << 12;
    signature |= (uint32_t)(frameInfo.dolby_vision.profile & 0x1f) << 16;
    signature |= (uint32_t)(frameInfo.dolby_vision.has_mmr & 0x1) << 21;
    signature |= (uint32_t)(headroomQ & 0x3ff) << 22;
    return signature;
}

@interface FSMetalRenderer()
{
    vector_float4 _colorAdjustment;
    id<MTLDevice> _device;
    MTLPixelFormat _colorPixelFormat;
    FSHDRFrameInfo _hdrFrameInfo;
    FSHDRRenderIntent _renderIntent;
    uint32_t _hdrLogSignature;
}

// The render pipeline generated from the vertex and fragment shaders in the .metal shader file.
@property (nonatomic, strong) id<MTLRenderPipelineState> renderPipeline;
@property (nonatomic, strong) id<MTLBuffer> vertexBuffer;
// The buffer that contains arguments for the fragment shader.
@property (nonatomic, strong) id<MTLBuffer> fragmentShaderArgumentBuffer;
@property (nonatomic, strong) id<MTLArgumentEncoder> argumentEncoder;
@property (nonatomic, strong) id<MTLBuffer> convertMatrixBuff;
@property (nonatomic, strong) id<MTLBuffer> hdrUniformBuff;
@property (nonatomic, assign) BOOL convertMatrixChanged;
@property (nonatomic, assign) BOOL hdrUniformChanged;
@property (nonatomic, assign) NSUInteger hdrUniformOffset;
@property (nonatomic, assign) NSUInteger hdrUniformSlot;

@property (nonatomic, strong) FSMetalPipelineMeta *pipelineMeta;
@property (nonatomic, assign) BOOL vertexChanged;

@end

@implementation FSMetalRenderer

- (instancetype)initWithDevice:(id<MTLDevice>)device
              colorPixelFormat:(MTLPixelFormat)colorPixelFormat
{
    self = [super init];
    if (self) {
        NSAssert(device, @"device can't be nil!");
        _device = device;
        _colorPixelFormat = colorPixelFormat;
        _colorAdjustment = (vector_float4){0.0};
        _hdrPercentage = 0.0;
        _renderIntent.outputColorSpace = FSColorSpaceBT709;
        _hdrLogSignature = UINT_MAX;
    }
    return self;
}

- (BOOL)isHDR
{
    return self.pipelineMeta.hdr || _renderIntent.usesHDRPipeline;
}

- (BOOL)matchPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    return [self.pipelineMeta metaMatchedCVPixelbuffer:pixelBuffer];
}

- (BOOL)createRenderPipelineIfNeed:(CVPixelBufferRef)pixelBuffer blend:(BOOL)blend
{
    if (self.renderPipeline) {
        return YES;
    }
    
    if (!self.pipelineMeta) {
        self.pipelineMeta = [FSMetalPipelineMeta createWithCVPixelbuffer:pixelBuffer];
    }
    
    if (!self.pipelineMeta) {
        return NO;
    }
    
    self.convertMatrixChanged = YES;
    ALOGI("render pipeline:%s\n",[[self.pipelineMeta description]UTF8String]);
    
    NSBundle* bundle = [NSBundle bundleForClass:[self class]];
    NSURL * libURL = [bundle URLForResource:@"default" withExtension:@"metallib"];
    
    NSError *error;
    
    id<MTLLibrary> defaultLibrary = [_device newLibraryWithFile:libURL.path error:&error];
    
    NSParameterAssert(defaultLibrary);
    // Load all the shader files with a .metal file extension in the project.
    //id<MTLLibrary> defaultLibrary = [device newDefaultLibrary];
    id<MTLFunction> vertexFunction = [defaultLibrary newFunctionWithName:@"mvpShader"];
    NSAssert(vertexFunction, @"can't find Vertex Function:vertexShader");
    id<MTLFunction> fragmentFunction = [defaultLibrary newFunctionWithName:self.pipelineMeta.fragmentName];
    NSAssert(vertexFunction, @"can't find Fragment Function:%@",self.pipelineMeta.fragmentName);
    id <MTLArgumentEncoder> argumentEncoder =
        [fragmentFunction newArgumentEncoderWithBufferIndex:FSFragmentBufferLocation0];
    
    NSUInteger argumentBufferLength = argumentEncoder.encodedLength;

    _fragmentShaderArgumentBuffer = [_device newBufferWithLength:argumentBufferLength options:0];

    _fragmentShaderArgumentBuffer.label = @"Argument Buffer";
    
    [argumentEncoder setArgumentBuffer:_fragmentShaderArgumentBuffer offset:0];

    // Configure a pipeline descriptor that is used to create a pipeline state.
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.vertexFunction = vertexFunction;
    pipelineStateDescriptor.fragmentFunction = fragmentFunction;
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = _colorPixelFormat; // 设置颜色格式
    pipelineStateDescriptor.sampleCount = 1;
    // 启用混合
    if (blend) {
        pipelineStateDescriptor.colorAttachments[0].blendingEnabled = YES;
        // 设置混合因子（经典Alpha混合公式）
        pipelineStateDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pipelineStateDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipelineStateDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pipelineStateDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    }

    id<MTLRenderPipelineState> pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor
                                                                                      error:&error]; // 创建图形渲染管道，耗性能操作不宜频繁调用
    // Pipeline State creation could fail if the pipeline descriptor isn't set up properly.
    //  If the Metal API validation is enabled, you can find out more information about what
    //  went wrong.  (Metal API validation is enabled by default when a debug build is run
    //  from Xcode.)
    NSAssert(pipelineState, @"Failed to create pipeline state: %@", error);
    self.argumentEncoder = argumentEncoder;
    self.renderPipeline = pipelineState;
    return YES;
}

- (void)setVertexRatio:(CGSize)vertexRatio
{
    if (!CGSizeEqualToSize(self.vertexRatio, vertexRatio)) {
        _vertexRatio = vertexRatio;
        self.vertexChanged = YES;
    }
}

- (void)setTextureCrop:(CGSize)textureCrop
{
    if (!CGSizeEqualToSize(self.textureCrop, textureCrop)) {
        _textureCrop = textureCrop;
        self.vertexChanged = YES;
    }
}

- (void)setRotateType:(int)rotateType
{
    if (_rotateType != rotateType) {
        _rotateType = rotateType;
        self.vertexChanged = YES;
    }
}

- (void)setRotateDegrees:(float)rotateDegrees
{
    if (_rotateDegrees != rotateDegrees) {
        _rotateDegrees = rotateDegrees;
        self.vertexChanged = YES;
    }
}

- (void)setAutoZRotateDegrees:(float)autoZRotateDegrees
{
    if (_autoZRotateDegrees != autoZRotateDegrees) {
        _autoZRotateDegrees = autoZRotateDegrees;
        self.vertexChanged = YES;
    }
}

- (void)updateColorAdjustment:(vector_float4)s
{
    float s0 = s[0];
    float s1 = s[1];
    float s2 = s[2];
    float s3 = s[3];
    
    vector_float4 d = _colorAdjustment;
    float d0 = d[0];
    float d1 = d[1];
    float d2 = d[2];
    float d3 = d[3];
    
    if (s0 != d0 || s1 != d1 || s2 != d2 || s3 != d3) {
        _colorAdjustment = s;
        self.convertMatrixChanged = YES;
    }
}

- (void)updateHDRFrameInfo:(FSHDRFrameInfo)hdrFrameInfo
              renderIntent:(FSHDRRenderIntent)renderIntent
{
    if (memcmp(&_hdrFrameInfo, &hdrFrameInfo, sizeof(FSHDRFrameInfo)) != 0 ||
        memcmp(&_renderIntent, &renderIntent, sizeof(FSHDRRenderIntent)) != 0) {
        _hdrFrameInfo = hdrFrameInfo;
        _renderIntent = renderIntent;
        self.hdrUniformChanged = YES;

        if (self.pipelineMeta) {
            uint32_t signature = fs_hdr_log_signature(_hdrFrameInfo, _renderIntent, self.pipelineMeta);
            if (_hdrLogSignature != signature) {
                _hdrLogSignature = signature;
                ALOGI("hdr state: content=%s decode=%s dvProfile=%d mmr=%d shader=%d target=%s toneMap=%d gamut=%d hdrDrawable=%d matrix=%s headroom=%.2f sourceMax=%.1f targetMax=%.1f\n",
                      fs_hdr_content_type_name(_hdrFrameInfo.content_type),
                      fs_hdr_decode_path_name(_hdrFrameInfo.decode_path),
                      _hdrFrameInfo.dolby_vision.profile,
                      _hdrFrameInfo.dolby_vision.has_mmr,
                      _renderIntent.useDolbyVisionShader,
                      fs_hdr_colorspace_name(_renderIntent.outputColorSpace),
                      _renderIntent.needsToneMapping,
                      _renderIntent.needsGamutMapping,
                      _renderIntent.needsHDRDrawable,
                      fs_hdr_matrix_name(self.pipelineMeta.convertMatrixType),
                      _renderIntent.outputHeadroom,
                      _renderIntent.sourceMaxNits,
                      _renderIntent.targetMaxNits);
            }
        }
    }
}

- (void)updateVertexIfNeed
{
    if (!self.vertexChanged) {
        return;
    }
    
    self.vertexChanged = NO;
    
    float x = self.vertexRatio.width;
    float y = self.vertexRatio.height;
    /*
     //https://stackoverflow.com/questions/58702023/what-is-the-coordinate-system-used-in-metal
     
     triangle strip
       ↑y
     V3|V4
     --|--→x
     V1|V2
     📐-->V1V2V3
     📐-->V2V3V4
     
     texture
     |---->x
     |V3 V4
     |V1 V2
     ↓y
     */
    float max_t_y = 1.0 * (1 - self.textureCrop.height);
    float max_t_x = 1.0 * (1 - self.textureCrop.width);
    FSVertex quadVertices[4] =
    {   //顶点坐标；                纹理坐标；
        { { -1.0 * x, -1.0 * y }, { 0.f, max_t_y } },
        { {  1.0 * x, -1.0 * y }, { max_t_x, max_t_y } },
        { { -1.0 * x,  1.0 * y }, { 0.f, 0.f } },
        { {  1.0 * x,  1.0 * y }, { max_t_x, 0.f } },
    };
    
    /// These are the view and projection transforms.
    matrix_float4x4 viewMatrix;
    float radian = radians_from_degrees(self.rotateDegrees);
    switch (self.rotateType) {
        case 1:
        {
            viewMatrix = matrix4x4_rotation(radian, 1.0, 0.0, 0.0);
            viewMatrix = matrix_multiply(viewMatrix, matrix4x4_translation(0.0, 0.0, -0.5));
        }
            break;
        case 2:
        {
            viewMatrix = matrix4x4_rotation(radian, 0.0, 1.0, 0.0);
            viewMatrix = matrix_multiply(viewMatrix, matrix4x4_translation(0.0, 0.0, -0.5));
        }
            break;
        case 3:
        {
            viewMatrix = matrix4x4_rotation(radian, 0.0, 0.0, 1.0);
        }
            break;
        default:
        {
            viewMatrix = matrix4x4_identity();
        }
            break;
    }
    
    if (self.autoZRotateDegrees != 0) {
        float zRadin = radians_from_degrees(self.autoZRotateDegrees);
        viewMatrix = matrix_multiply(matrix4x4_rotation(zRadin, 0.0, 0.0, 1.0),viewMatrix);
    }
    
    FSVertexData data = {quadVertices[0],quadVertices[1],quadVertices[2],quadVertices[3],viewMatrix};
    self.vertexBuffer = [_device newBufferWithBytes:&data
                                             length:sizeof(data)
                                            options:MTLResourceStorageModeShared]; // 创建顶点缓存
}

- (void)updateConvertMatrixBufferIfNeed
{
    if (self.convertMatrixChanged || !self.convertMatrixBuff) {
        self.convertMatrixChanged = NO;
        
        FSConvertMatrix convertMatrix = ijk_metal_create_color_matrix(self.pipelineMeta.convertMatrixType, self.pipelineMeta.fullRange);
        convertMatrix.adjustment = _colorAdjustment;
        convertMatrix.transferFun = self.pipelineMeta.transferFunc;
        convertMatrix.hdrPercentage = self.hdrPercentage;
        convertMatrix.hdr = self.pipelineMeta.hdr;
        self.convertMatrixBuff = [_device newBufferWithBytes:&convertMatrix
                                                      length:sizeof(FSConvertMatrix)
                                                     options:MTLResourceStorageModeShared];
    }
}

- (void)updateHDRUniformBufferIfNeed
{
    if (self.hdrUniformChanged || !self.hdrUniformBuff) {
        FSHDRFragmentUniforms uniforms = {0};
        self.hdrUniformChanged = NO;

        uniforms.valid = _hdrFrameInfo.valid;
        uniforms.contentType = _hdrFrameInfo.content_type;
        uniforms.inputTransfer = _renderIntent.inputTransfer;
        uniforms.sourceMatrixType = self.pipelineMeta.convertMatrixType;
        uniforms.outputColorSpace = _renderIntent.outputColorSpace;
        uniforms.outputTransfer = _renderIntent.outputTransfer;
        uniforms.useDolbyVisionShader = _renderIntent.useDolbyVisionShader;
        uniforms.needsToneMapping = _renderIntent.needsToneMapping;
        uniforms.needsGamutMapping = _renderIntent.needsGamutMapping;
        uniforms.allowsPassthrough = _renderIntent.allowsPassthrough;
        uniforms.needsHDRDrawable = _renderIntent.needsHDRDrawable;
        uniforms.needsDithering = _renderIntent.needsDithering;
        uniforms.toneMapMode = _renderIntent.toneMapMode;
        uniforms.masteringMinNits = _hdrFrameInfo.mastering_min_nits;
        uniforms.masteringMaxNits = _hdrFrameInfo.mastering_max_nits;
        uniforms.maxCLL = _hdrFrameInfo.max_cll;
        uniforms.maxFALL = _hdrFrameInfo.max_fall;
        uniforms.sourceMinNits = _renderIntent.sourceMinNits;
        uniforms.sourceMaxNits = _renderIntent.sourceMaxNits;
        uniforms.sourceAverageNits = _renderIntent.sourceAverageNits;
        uniforms.targetMinNits = _renderIntent.targetMinNits;
        uniforms.targetMaxNits = _renderIntent.targetMaxNits;
        uniforms.outputHeadroom = _renderIntent.outputHeadroom;
        uniforms.dolbyVision = _hdrFrameInfo.dolby_vision;

        if (!self.hdrUniformBuff) {
            self.hdrUniformBuff = [_device newBufferWithLength:sizeof(FSHDRFragmentUniforms) * kFSHDRUniformBufferSlots
                                                       options:MTLResourceStorageModeShared];
            self.hdrUniformBuff.label = @"hdrUniforms";
        }
        self.hdrUniformSlot = (self.hdrUniformSlot + 1) % kFSHDRUniformBufferSlots;
        self.hdrUniformOffset = sizeof(FSHDRFragmentUniforms) * self.hdrUniformSlot;
        memcpy((uint8_t *)self.hdrUniformBuff.contents + self.hdrUniformOffset,
               &uniforms,
               sizeof(FSHDRFragmentUniforms));
    }
}

- (void)setHdrPercentage:(float)hdrPercentage
{
    if (0.0 <= hdrPercentage && hdrPercentage <= 1.0 && _hdrPercentage != hdrPercentage) {
        _hdrPercentage = hdrPercentage;
        self.convertMatrixChanged = YES;
    }
}

- (void)uploadTextureWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                        textures:(NSArray*)textures
{
    [self updateVertexIfNeed];
    // Pass in the parameter data.
    [encoder setVertexBuffer:self.vertexBuffer
                      offset:0
                     atIndex:FSVertexInputIndexVertices]; // 设置顶点缓存
 
    [self updateConvertMatrixBufferIfNeed];
    [self updateHDRUniformBufferIfNeed];
    
    //Fragment Function(nv12FragmentShader): missing buffer binding at index 0 for fragmentShaderArgs[0].
    [self.argumentEncoder setArgumentBuffer:self.fragmentShaderArgumentBuffer offset:0];
    
    for (int i = 0; i < [textures count]; i++) {
        id<MTLTexture>t = textures[i];
        [self.argumentEncoder setTexture:t
                                 atIndex:FSFragmentTextureIndexTextureY + i]; // 设置纹理
        
        // Indicate to Metal that the GPU accesses these resources, so they need
        // to map to the GPU's address space.
        if (@available(macOS 10.15, ios 13.0, tvOS 13.0, *)) {
            [encoder useResource:t usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        } else {
            // Fallback on earlier versions
            [encoder useResource:t usage:MTLResourceUsageRead];
        }
    }
    [self.argumentEncoder setBuffer:self.convertMatrixBuff offset:0 atIndex:FSFragmentMatrixIndexConvert];
    [self.argumentEncoder setBuffer:self.hdrUniformBuff offset:self.hdrUniformOffset atIndex:FSFragmentMatrixIndexHDR];
    
    // to map to the GPU's address space.
    if (@available(macOS 10.15, ios 13.0, tvOS 13.0, *)) {
        [encoder useResource:self.convertMatrixBuff usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        [encoder useResource:self.hdrUniformBuff usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
    } else {
        // Fallback on earlier versions
        [encoder useResource:self.convertMatrixBuff usage:MTLResourceUsageRead];
        [encoder useResource:self.hdrUniformBuff usage:MTLResourceUsageRead];
    }
    
    [encoder setFragmentBuffer:self.fragmentShaderArgumentBuffer
                        offset:0
                       atIndex:FSFragmentBufferLocation0];
    
    // 设置渲染管道，以保证顶点和片元两个shader会被调用
    [encoder setRenderPipelineState:self.renderPipeline];
    
    // Draw the triangle.
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4]; // 绘制
}

@end
