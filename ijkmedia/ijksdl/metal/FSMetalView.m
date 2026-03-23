//
//  FSMetalView.m
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2022/11/22.
//  Copyright © 2022 debugly's Awesome FFmpeg Tutotial. All rights reserved.
//

#import "FSMetalView.h"
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVUtilities.h>
#import <CoreImage/CIContext.h>
#import <mach/mach_time.h>
#import <objc/message.h>

// Header shared between C code here, which executes Metal API commands, and .metal files, which
// uses these types as inputs to the shaders.
#import "FSMetalShaderTypes.h"
#import "FSHDRRenderPlanner.h"
#import "FSMetalRenderer.h"
#import "FSMetalSubtitlePipeline.h"
#import "FSMetalOffscreenRendering.h"

#import "ijksdl_vout_ios_gles2.h"
#import "FSMediaPlayback.h"
#import "ijk_vout_common.h"
#include "../ffmpeg/ijksdl_inc_ffmpeg.h"

#if TARGET_OS_IPHONE
typedef CGRect NSRect;
#endif

@interface FSMetalView ()

// The command queue used to pass commands to the device.
@property (nonatomic, strong) id<MTLCommandQueue>commandQueue;
@property (nonatomic, assign) CVMetalTextureCacheRef pictureTextureCache;
@property (atomic, strong) FSMetalRenderer *picturePipeline;
@property (atomic, strong) FSMetalSubtitlePipeline *subPipeline;
@property (nonatomic, strong) FSMetalOffscreenRendering *offscreenRendering;
@property (atomic, strong) FSOverlayAttach *currentAttach;
@property (assign) int hdrAnimationFrameCount;
@property (atomic, strong) NSLock *pilelineLock;
@property (assign) BOOL needCleanBackgroundColor;
@property (nonatomic, copy) dispatch_block_t refreshCurrentPicBlock;
@property (nonatomic, strong) FSHDRRenderPlanner *renderPlanner;
@property (nonatomic, assign) FSHDRRenderIntent currentRenderIntent;
@property (nonatomic, assign) FSColorSpace preferredColorSpace;
@property (nonatomic, assign) FSHDRToneMapMode preferredHDRToneMapMode;
@property (nonatomic, assign) NSUInteger displayIdentity;
@property (nonatomic, assign) NSUInteger displayConfigSignature;

#if TARGET_OS_IOS || TARGET_OS_TV
@property (atomic, assign) BOOL isEnterBackground;
#endif

@end

@implementation FSMetalView

static int fs_hdr_content_type_from_cv_transfer(CFStringRef transferFunction)
{
    if (!transferFunction) {
        return FS_HDR_CONTENT_TYPE_SDR;
    }
    if (CFStringCompare(transferFunction, FS_TransferFunction_ITU_R_2100_HLG, 0) == kCFCompareEqualTo) {
        return FS_HDR_CONTENT_TYPE_HLG;
    }
    if (CFStringCompare(transferFunction, FS_TransferFunction_SMPTE_ST_2084_PQ, 0) == kCFCompareEqualTo ||
        CFStringCompare(transferFunction, FS_TransferFunction_SMPTE_ST_428_1, 0) == kCFCompareEqualTo) {
        return FS_HDR_CONTENT_TYPE_HDR10;
    }
    return FS_HDR_CONTENT_TYPE_SDR;
}

static int fs_hdr_avcol_transfer_from_cv_transfer(CFStringRef transferFunction)
{
    if (!transferFunction) {
        return AVCOL_TRC_UNSPECIFIED;
    }
    if (CFStringCompare(transferFunction, FS_TransferFunction_ITU_R_2100_HLG, 0) == kCFCompareEqualTo) {
        return AVCOL_TRC_ARIB_STD_B67;
    }
    if (CFStringCompare(transferFunction, FS_TransferFunction_SMPTE_ST_2084_PQ, 0) == kCFCompareEqualTo ||
        CFStringCompare(transferFunction, FS_TransferFunction_SMPTE_ST_428_1, 0) == kCFCompareEqualTo) {
        return AVCOL_TRC_SMPTE2084;
    }
    return AVCOL_TRC_UNSPECIFIED;
}

static int fs_hdr_avcol_matrix_from_cv_matrix(CFStringRef colorMatrix)
{
    if (!colorMatrix) {
        return AVCOL_SPC_UNSPECIFIED;
    }
    if (CFStringCompare(colorMatrix, kCVImageBufferYCbCrMatrix_ITU_R_2020, 0) == kCFCompareEqualTo) {
        return AVCOL_SPC_BT2020_NCL;
    }
    if (CFStringCompare(colorMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2, 0) == kCFCompareEqualTo) {
        return AVCOL_SPC_BT709;
    }
    if (CFStringCompare(colorMatrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) == kCFCompareEqualTo) {
        return AVCOL_SPC_BT470BG;
    }
    return AVCOL_SPC_UNSPECIFIED;
}

static int fs_hdr_avcol_primaries_from_cv_primaries(CFStringRef primaries)
{
    if (!primaries) {
        return AVCOL_PRI_UNSPECIFIED;
    }
    if (CFStringCompare(primaries, kCVImageBufferColorPrimaries_ITU_R_2020, 0) == kCFCompareEqualTo) {
        return AVCOL_PRI_BT2020;
    }
    if (CFStringCompare(primaries, kCVImageBufferColorPrimaries_ITU_R_709_2, 0) == kCFCompareEqualTo) {
        return AVCOL_PRI_BT709;
    }
    return AVCOL_PRI_UNSPECIFIED;
}

static void fs_log_hdr_attachment_reconcile_once(FSHDRFrameInfo info)
{
    static uint32_t lastSignature = UINT_MAX;
    uint32_t signature = 0;

    signature |= (uint32_t)(info.content_type & 0x7);
    signature |= (uint32_t)(info.transfer & 0xff) << 3;
    signature |= (uint32_t)(info.primaries & 0xff) << 11;
    signature |= (uint32_t)(info.matrix & 0xff) << 19;
    if (lastSignature == signature) {
        return;
    }
    lastSignature = signature;

    ALOGI("hdr frame reconciled from pixel buffer attachments: content=%d trc=%d primaries=%d matrix=%d\n",
          info.content_type,
          info.transfer,
          info.primaries,
          info.matrix);
}

@synthesize scalingMode = _scalingMode;
// rotate preference
@synthesize rotatePreference = _rotatePreference;
// color conversion preference
@synthesize colorPreference = _colorPreference;
// user defined display aspect ratio
@synthesize darPreference = _darPreference;

@synthesize preventDisplay = _preventDisplay;
#if TARGET_OS_IOS
@synthesize scaleFactor = _scaleFactor;
#endif
@synthesize showHdrAnimation = _showHdrAnimation;

@synthesize displayDelegate = _displayDelegate;

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    
    if (_pictureTextureCache) {
        CFRelease(_pictureTextureCache);
        _pictureTextureCache = NULL;
    }
}

- (BOOL)prepareMetal
{
    _rotatePreference   = (FSRotatePreference){FSRotateNone, 0.0};
    _colorPreference    = (FSColorConvertPreference){1.0, 1.0, 1.0};
    _darPreference      = (FSDARPreference){0.0};
    _pilelineLock = [[NSLock alloc]init];
    _preferredColorSpace = FSColorSpaceBT709;
    _preferredHDRToneMapMode = FSHDRToneMapModeBT2390;
    _renderPlanner = [[FSHDRRenderPlanner alloc] initWithPreferredColorSpace:_preferredColorSpace];
    _renderPlanner.preferredToneMapMode = _preferredHDRToneMapMode;
    
    self.device = MTLCreateSystemDefaultDevice();
    if (!self.device) {
        NSLog(@"No Support Metal.");
        return NO;
    }
    
    CVReturn ret = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, self.device, NULL, &_pictureTextureCache);
    if (ret != kCVReturnSuccess) {
        NSLog(@"Create MetalTextureCache Failed:%d.",ret);
        self.device = nil;
        return NO;
    }
    // default is kCAGravityResize,the content will be filled to new bounds when change view's frame by Implicit Animation
#if TARGET_OS_OSX
    //#76 设置了 kCAGravityCenter 之后发现 macOS 外接1倍屏会出现画面显示到中央，无法填充满的问题，Retina屏幕没有问题
    //self.layer.contentsGravity = kCAGravityCenter;
#else
    self.contentMode = UIViewContentModeCenter;
#endif
    
    // Create the command queue
    self.commandQueue = [self.device newCommandQueue];
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.autoResizeDrawable = YES;
    // important;then use draw method drive rendering.
    self.enableSetNeedsDisplay = NO;
    self.paused = YES;
    [self refreshRenderIntentForAttach:nil];
    self.displayIdentity = [self currentDisplayIdentity];
    self.displayConfigSignature = [self currentDisplayConfigSignature];
    //set default bg color.
    [self setBackgroundColor:0 g:0 b:0];
    
#if TARGET_OS_IOS || TARGET_OS_TV
    self.isEnterBackground = UIApplication.sharedApplication.applicationState == UIApplicationStateBackground;
    
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(applicationDidEnterBackground)
                                               name:UIApplicationDidEnterBackgroundNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(applicationWillEnterForeground)
                                               name:UIApplicationWillEnterForegroundNotification
                                             object:nil];
#endif
    return YES;
}

- (FSHDRDisplayCaps)currentDisplayCaps
{
    FSHDRDisplayCaps caps = {0};
    CGFloat headroom = 1.0;
#if TARGET_OS_IOS || TARGET_OS_TV
    UIScreen *screen = self.window.screen ?: UIScreen.mainScreen;
    if (screen && [screen respondsToSelector:NSSelectorFromString(@"maximumExtendedDynamicRangeColorComponentValue")]) {
        NSNumber *value = [screen valueForKey:@"maximumExtendedDynamicRangeColorComponentValue"];
        if ([value isKindOfClass:[NSNumber class]]) {
            headroom = value.doubleValue;
        }
    }
#else
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    if (screen && [screen respondsToSelector:NSSelectorFromString(@"maximumPotentialExtendedDynamicRangeColorComponentValue")]) {
        NSNumber *value = [screen valueForKey:@"maximumPotentialExtendedDynamicRangeColorComponentValue"];
        if ([value isKindOfClass:[NSNumber class]]) {
            headroom = value.doubleValue;
        }
    } else if (screen && [screen respondsToSelector:NSSelectorFromString(@"maximumExtendedDynamicRangeColorComponentValue")]) {
        NSNumber *value = [screen valueForKey:@"maximumExtendedDynamicRangeColorComponentValue"];
        if ([value isKindOfClass:[NSNumber class]]) {
            headroom = value.doubleValue;
        }
    }
#endif
    caps.supportsExtendedRange = headroom > 1.0;
    caps.supportsPQOutput = caps.supportsExtendedRange;
    caps.supportsSCRGBOutput = caps.supportsExtendedRange;
    caps.headroom = (float) MAX(headroom, 1.0);
    return caps;
}

- (void)invalidatePipelines
{
    [self.pilelineLock lock];
    self.picturePipeline = nil;
    self.subPipeline = nil;
    [self.pilelineLock unlock];
}

- (void)setExtendedDynamicRangeEnabled:(BOOL)enabled
{
    id layer = self.layer;
    SEL selector = NSSelectorFromString(@"setWantsExtendedDynamicRangeContent:");
    if (layer && [layer respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, selector, enabled);
    }
}

- (CGColorSpaceRef)copyColorSpaceForIntent:(FSHDRRenderIntent)intent
{
    if (intent.needsHDRDrawable) {
        if (intent.outputColorSpace == FSColorSpaceBT2100_PQ) {
            if (@available(macOS 11.0, ios 14.0, tvOS 14.0, *)) {
                return CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
            }
        }
        return CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    }
    return CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
}

- (void)applyRenderIntentConfiguration:(FSHDRRenderIntent)intent
{
    MTLPixelFormat targetPixelFormat = intent.needsHDRDrawable ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
    BOOL pixelFormatChanged = self.colorPixelFormat != targetPixelFormat;
    CGColorSpaceRef targetColorSpace = [self copyColorSpaceForIntent:intent];
    BOOL colorSpaceChanged = NO;

    if (targetColorSpace) {
        if (self.colorspace == NULL) {
            colorSpaceChanged = YES;
        } else {
            colorSpaceChanged = !CFEqual(self.colorspace, targetColorSpace);
        }
    } else if (self.colorspace != NULL) {
        colorSpaceChanged = YES;
    }

    if (pixelFormatChanged) {
        self.colorPixelFormat = targetPixelFormat;
    }
    if (colorSpaceChanged) {
        self.colorspace = targetColorSpace;
    }
    [self setExtendedDynamicRangeEnabled:intent.needsHDRDrawable];

    if (targetColorSpace) {
        CGColorSpaceRelease(targetColorSpace);
    }

    if (pixelFormatChanged) {
        [self invalidatePipelines];
    }
}

- (void)refreshRenderIntentForAttach:(FSOverlayAttach *)attach
{
    [self refreshRenderIntentForAttach:attach displayCaps:[self currentDisplayCaps]];
}

- (NSUInteger)currentDisplayConfigSignature
{
    FSHDRDisplayCaps caps = [self currentDisplayCaps];
    float headroom = caps.headroom > 1.0f ? caps.headroom : 1.0f;
    uint32_t headroomQ = (uint32_t)(headroom * 1000.0f + 0.5f);
    NSUInteger signature = 0;
    signature |= (NSUInteger)(caps.supportsExtendedRange & 0x1);
    signature |= (NSUInteger)(caps.supportsPQOutput & 0x1) << 1;
    signature |= (NSUInteger)(caps.supportsSCRGBOutput & 0x1) << 2;
    signature |= (NSUInteger)headroomQ << 3;
    return signature;
}

- (void)refreshRenderIntentForAttach:(FSOverlayAttach *)attach
                         displayCaps:(FSHDRDisplayCaps)displayCaps
{
    if (!self.renderPlanner) {
        self.currentRenderIntent = (FSHDRRenderIntent){0};
    } else if (!attach) {
        FSHDRRenderIntent fallback = {0};
        fallback.outputColorSpace = FSColorSpaceBT709;
        self.currentRenderIntent = fallback;
    } else {
        self.currentRenderIntent = [self.renderPlanner planForFrameInfo:&attach.hdrFrameInfo
                                                            displayCaps:displayCaps];
    }
    [self applyRenderIntentConfiguration:self.currentRenderIntent];
}

- (NSUInteger)currentDisplayIdentity
{
#if TARGET_OS_IOS || TARGET_OS_TV
    UIScreen *screen = self.window.screen ?: UIScreen.mainScreen;
#else
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
#endif
    return (NSUInteger)(__bridge void *)screen;
}

- (void)refreshDisplayConfigurationIfNeeded
{
    NSUInteger displayIdentity = [self currentDisplayIdentity];
    NSUInteger displayConfigSignature = [self currentDisplayConfigSignature];
    if (self.displayIdentity == displayIdentity &&
        self.displayConfigSignature == displayConfigSignature) {
        return;
    }
    self.displayIdentity = displayIdentity;
    self.displayConfigSignature = displayConfigSignature;
    FSHDRDisplayCaps displayCaps = [self currentDisplayCaps];
    [self refreshRenderIntentForAttach:self.currentAttach displayCaps:displayCaps];
    if (self.currentAttach) {
        [self invalidatePipelines];
        [self setNeedsRefreshCurrentPic];
    }
}

- (void)promoteHDRFrameInfoFromPixelBufferIfNeeded:(FSOverlayAttach *)attach
{
    if (!attach || !attach.videoPicture) {
        return;
    }

    FSHDRFrameInfo info = attach.hdrFrameInfo;
    BOOL changed = NO;
    if (!info.valid) {
        info.valid = 1;
        info.content_type = FS_HDR_CONTENT_TYPE_SDR;
    }

    CFStringRef transferFunction = CVBufferGetAttachment(attach.videoPicture, kCVImageBufferTransferFunctionKey, NULL);
    CFStringRef colorMatrix = CVBufferGetAttachment(attach.videoPicture, kCVImageBufferYCbCrMatrixKey, NULL);
    CFStringRef colorPrimaries = CVBufferGetAttachment(attach.videoPicture, kCVImageBufferColorPrimariesKey, NULL);
    int attachmentTransfer = fs_hdr_avcol_transfer_from_cv_transfer(transferFunction);
    int attachmentContentType = fs_hdr_content_type_from_cv_transfer(transferFunction);
    int attachmentMatrix = fs_hdr_avcol_matrix_from_cv_matrix(colorMatrix);
    int attachmentPrimaries = fs_hdr_avcol_primaries_from_cv_primaries(colorPrimaries);
    BOOL isBT2020 = info.primaries == AVCOL_PRI_BT2020 ||
                    info.matrix == AVCOL_SPC_BT2020_NCL ||
                    info.matrix == AVCOL_SPC_BT2020_CL ||
                    attachmentPrimaries == AVCOL_PRI_BT2020 ||
                    attachmentMatrix == AVCOL_SPC_BT2020_NCL ||
                    attachmentMatrix == AVCOL_SPC_BT2020_CL;
    BOOL canPromoteHDR = attachmentContentType != FS_HDR_CONTENT_TYPE_SDR && isBT2020;

    if (info.content_type == FS_HDR_CONTENT_TYPE_SDR &&
        !canPromoteHDR) {
        return;
    }

    if (info.content_type == FS_HDR_CONTENT_TYPE_SDR &&
        canPromoteHDR) {
        info.content_type = attachmentContentType;
        changed = YES;
        if (attachmentTransfer != AVCOL_TRC_UNSPECIFIED) {
            info.transfer = attachmentTransfer;
        }
    }

    if (info.transfer == AVCOL_TRC_UNSPECIFIED &&
        attachmentTransfer != AVCOL_TRC_UNSPECIFIED &&
        info.content_type != FS_HDR_CONTENT_TYPE_SDR) {
        info.transfer = attachmentTransfer;
        changed = YES;
    }
    if (info.primaries == AVCOL_PRI_UNSPECIFIED &&
        attachmentPrimaries != AVCOL_PRI_UNSPECIFIED) {
        info.primaries = attachmentPrimaries;
        changed = YES;
    }
    if (info.matrix == AVCOL_SPC_UNSPECIFIED &&
        attachmentMatrix != AVCOL_SPC_UNSPECIFIED) {
        info.matrix = attachmentMatrix;
        changed = YES;
    }

    if (!changed) {
        return;
    }
    attach.hdrFrameInfo = info;
    fs_log_hdr_attachment_reconcile_once(info);
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        [self prepareMetal];
    }
    return self;
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        [self prepareMetal];
    }
    return self;
}

- (void)setShowHdrAnimation:(BOOL)showHdrAnimation
{
    if (_showHdrAnimation != showHdrAnimation) {
        _showHdrAnimation = showHdrAnimation;
        self.hdrAnimationFrameCount = 0;
    }
}

- (CGSize)computeNormalizedVerticesRatio:(FSOverlayAttach *)attach drawableSize:(CGSize)drawableSize
{
    if (_scalingMode == FSScalingModeFill) {
        return CGSizeMake(1.0, 1.0);
    }
    
    int frameWidth = attach.w;
    int frameHeight = attach.h;
    
    //keep video AVRational
    if (attach.sarNum > 0 && attach.sarDen > 0) {
        frameWidth = 1.0 * attach.sarNum / attach.sarDen * frameWidth;
    }
    
    int zDegrees = 0;
    if (_rotatePreference.type == FSRotateZ) {
        zDegrees += _rotatePreference.degrees;
    }
    zDegrees += attach.autoZRotate;
    
    float darRatio = self.darPreference.ratio;
    
    //when video's z rotate degrees is 90 odd multiple
    if (abs(zDegrees) / 90 % 2 == 1) {
        //need swap user's ratio
        if (darRatio > 0.001) {
            darRatio = 1.0 / darRatio;
        }
        //need swap display size
        int tmp = drawableSize.width;
        drawableSize.width = drawableSize.height;
        drawableSize.height = tmp;
    }
    
    //apply user dar
    if (darRatio > 0.001) {
        if (1.0 * attach.w / attach.h > darRatio) {
            frameHeight = frameWidth * 1.0 / darRatio;
        } else {
            frameWidth = frameHeight * darRatio;
        }
    }
    
    float wRatio = drawableSize.width / frameWidth;
    float hRatio = drawableSize.height / frameHeight;
    float ratio  = 1.0f;
    
    if (_scalingMode == FSScalingModeAspectFit) {
        ratio = FFMIN(wRatio, hRatio);
    } else if (_scalingMode == FSScalingModeAspectFill) {
        ratio = FFMAX(wRatio, hRatio);
    }
    float nW = (frameWidth * ratio / drawableSize.width);
    float nH = (frameHeight * ratio / drawableSize.height);
    return CGSizeMake(nW, nH);
}

- (BOOL)setupSubPipelineIfNeed
{
    if (self.subPipeline) {
        return YES;
    }
    
    FSMetalSubtitlePipeline *subPipeline = [[FSMetalSubtitlePipeline alloc] initWithDevice:self.device
                                                                                  inFormat:FSMetalSubtitleInFormatBRGA
                                                                                 outFormat:FSMetalSubtitleOutFormatDIRECT
                                                                          colorPixelFormat:self.colorPixelFormat];
    
    BOOL created = [subPipeline createRenderPipelineIfNeed];
    
    if (!created) {
        ALOGE("create subRenderPipeline failed.");
        subPipeline = nil;
    }
    
    [self.pilelineLock lock];
    self.subPipeline = subPipeline;
    [self.pilelineLock unlock];
    
    return subPipeline != nil;
}

- (BOOL)setupPipelineIfNeed:(FSOverlayAttach *)attach blend:(BOOL)blend
{
    CVPixelBufferRef pixelBuffer = attach.videoPicture;
    if (!pixelBuffer) {
        return NO;
    }
    if (self.picturePipeline) {
        if ([self.picturePipeline matchPixelBuffer:pixelBuffer]) {
            return YES;
        }
        ALOGI("pixel format not match,need rebuild pipeline");
    }
    
    FSMetalRenderer *picturePipeline = [[FSMetalRenderer alloc] initWithDevice:self.device colorPixelFormat:self.colorPixelFormat];
    BOOL created = [picturePipeline createRenderPipelineIfNeed:pixelBuffer blend:blend];
    
    if (!created) {
        ALOGI("create RenderPipeline failed.");
        picturePipeline = nil;
    }
    
    [self.pilelineLock lock];
    self.picturePipeline = picturePipeline;
    [self.pilelineLock unlock];
    
    return picturePipeline != nil;
}

- (void)encodePicture:(FSOverlayAttach *)attach
        renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder
             viewport:(CGSize)viewport
                ratio:(CGSize)ratio
{
    [self.pilelineLock lock];
    self.picturePipeline.autoZRotateDegrees = attach.autoZRotate;
    self.picturePipeline.rotateType = self.rotatePreference.type;
    self.picturePipeline.rotateDegrees = self.rotatePreference.degrees;
    [self.picturePipeline updateHDRFrameInfo:attach.hdrFrameInfo
                                renderIntent:self.currentRenderIntent];
    
    bool applyAdjust = _colorPreference.brightness != 1.0 || _colorPreference.saturation != 1.0 || _colorPreference.contrast != 1.0;
    [self.picturePipeline updateColorAdjustment:(vector_float4){_colorPreference.brightness,_colorPreference.saturation,_colorPreference.contrast,applyAdjust ? 1.0 : 0.0}];
    self.picturePipeline.vertexRatio = ratio;
    
    self.picturePipeline.textureCrop = CGSizeMake(1.0 * (attach.pixelW - attach.w) / attach.pixelW, 1.0 * (attach.pixelH - attach.h) / attach.pixelH);
    
    // Set the region of the drawable to draw into.
    [renderEncoder setViewport:(MTLViewport){0.0, 0.0, viewport.width, viewport.height, -1.0, 1.0}];
    //upload textures
    [self.picturePipeline uploadTextureWithEncoder:renderEncoder
                                          textures:attach.videoTextures];
    [self.pilelineLock unlock];
}

- (void)encodeSubtitle:(id<MTLRenderCommandEncoder>)renderEncoder
              viewport:(CGSize)viewport
               texture:(id<MTLTexture>)subTexture
{
    [self.pilelineLock lock];
    // Set the region of the drawable to draw into.
    [renderEncoder setViewport:(MTLViewport){0.0, 0.0, viewport.width, viewport.height, -1.0, 1.0}];
    //upload textures
    
    float wRatio = viewport.width / subTexture.width;
    float hRatio = viewport.height / subTexture.height;
    
    CGRect subRect;
    //aspect fit
    if (wRatio < hRatio) {
        float nH = (subTexture.height * wRatio / viewport.height);
        subRect = CGRectMake(-1, -nH, 2.0, 2.0 * nH);
    } else {
        float nW = (subTexture.width * hRatio / viewport.width);
        subRect = CGRectMake(-nW, -1, 2.0 * nW, 2.0);
    }
    
    [self.subPipeline updateSubtitleVertexIfNeed:subRect];
    [self.subPipeline drawTexture:subTexture encoder:renderEncoder];
    [self.pilelineLock unlock];
}

- (void)sendHDRAnimationNotifiOnMainThread:(int)state
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FSPlayerHDRAnimationStateChanged object:self userInfo:@{@"state":@(state)}];
    });
}

/// Called whenever the view needs to render a frame.
- (void)drawRect:(NSRect)dirtyRect
{
#if TARGET_OS_IOS || TARGET_OS_TV
    if (self.isEnterBackground) {
        return;
    }
#endif
    
    FSOverlayAttach * attach = self.currentAttach;
    if (attach.videoTextures.count == 0) {
        if (self.needCleanBackgroundColor) {
            id<CAMetalDrawable> drawable = self.currentDrawable;
            if (drawable) {
                id<MTLTexture> texture = drawable.texture;

                MTLRenderPassDescriptor *passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
                passDescriptor.colorAttachments[0].texture = texture;
                passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
                passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
                passDescriptor.colorAttachments[0].clearColor = self.clearColor;
                
                id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
                id <MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
            
                [commandEncoder endEncoding];
                [commandBuffer presentDrawable:drawable];
                [commandBuffer commit];
                self.needCleanBackgroundColor = NO;
            }
        }
        return;
    }
    
    if (![self setupPipelineIfNeed:attach blend:attach.hasAlpha]) {
        return;
    }
    
    if (attach.subTexture && ![self setupSubPipelineIfNeed]) {
        return;
    }
    CGSize viewport = self.drawableSize;
    
    CGSize ratio = [self computeNormalizedVerticesRatio:attach drawableSize:viewport];
    
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    
    // Obtain a renderPassDescriptor generated from the view's drawable textures.
    MTLRenderPassDescriptor *renderPassDescriptor = self.currentRenderPassDescriptor;
    //MTLRenderPassDescriptor描述一系列attachments的值，类似GL的FrameBuffer；同时也用来创建MTLRenderCommandEncoder
    if(!renderPassDescriptor) {
        ALOGE("renderPassDescriptor can't be nil");
        return;
    }
    // Create a render command encoder.
    id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    
    //[renderEncoder pushDebugGroup:@"encodePicture"];
    
    if (self.showHdrAnimation && [self.picturePipeline isHDR]) {
#define _C(c) (attach.fps > 0 ? (int)ceil(attach.fps * c / 24.0) : c)
        int delay = _C(100);
        int maxCount = _C(100);
#undef _C
        int frameCount = ++self.hdrAnimationFrameCount - delay;
        if (frameCount >= 0) {
            if (frameCount <= maxCount) {
                if (frameCount == 0) {
                    [self sendHDRAnimationNotifiOnMainThread:1];
                } else if (frameCount == maxCount) {
                    [self sendHDRAnimationNotifiOnMainThread:2];
                }
            }
        }
    }
    
    [self encodePicture:attach
          renderEncoder:renderEncoder
               viewport:viewport
                  ratio:ratio];
    
    if (attach.subTexture) {
        [self encodeSubtitle:renderEncoder
                    viewport:viewport
                     texture:attach.subTexture];
    }
    //[renderEncoder popDebugGroup];
    [renderEncoder endEncoding];
    // Schedule a present once the framebuffer is complete using the current drawable.
    id <CAMetalDrawable> currentDrawable = self.currentDrawable;
    if (!currentDrawable) {
        ALOGE("wtf?currentDrawable is nil!");
        return;
    }
    [commandBuffer presentDrawable:currentDrawable];
    // Finalize rendering here & push the command buffer to the GPU.
    [commandBuffer commit];
}

- (CGImageRef)_snapshotWithSubtitle:(BOOL)drawSub
{
    FSOverlayAttach *attach = self.currentAttach;
    
    CVPixelBufferRef pixelBuffer = attach.videoPicture;
    if (!pixelBuffer) {
        return NULL;
    }
    
    if (!self.offscreenRendering) {
        self.offscreenRendering = [FSMetalOffscreenRendering alloc];
    }
    
    float width  = (float)CVPixelBufferGetWidth(pixelBuffer);
    float height = (float)CVPixelBufferGetHeight(pixelBuffer);
    
    //keep video AVRational
    if (attach.sarNum > 0 && attach.sarDen > 0) {
        width = 1.0 * attach.sarNum / attach.sarDen * width;
    }
    
    float darRatio = self.darPreference.ratio;
    
    int zDegrees = 0;
    if (_rotatePreference.type == FSRotateZ) {
        zDegrees += _rotatePreference.degrees;
    }
    zDegrees += attach.autoZRotate;
    //when video's z rotate degrees is 90 odd multiple
    if (abs(zDegrees) / 90 % 2 == 1) {
        int tmp = width;
        width = height;
        height = tmp;
    }
    
    //apply user dar
    if (darRatio > 0.001) {
        if (1.0 * width / height > darRatio) {
            height = width * 1.0 / darRatio;
        } else {
            width = height * darRatio;
        }
    }
    
    CGSize viewport = CGSizeMake(floorf(width), floorf(height));
    
    if (![self setupPipelineIfNeed:attach blend:attach.hasAlpha]) {
        return NULL;
    }
    
    if (drawSub && attach.subTexture && ![self setupSubPipelineIfNeed]) {
        return NULL;
    }
    
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    return [self.offscreenRendering snapshot:viewport device:self.device commandBuffer:commandBuffer doUploadPicture:^(id<MTLRenderCommandEncoder> _Nonnull renderEncoder) {
        
        [self encodePicture:attach
              renderEncoder:renderEncoder
                   viewport:viewport
                      ratio:CGSizeMake(1.0, 1.0)];
        
        if (drawSub && attach.subTexture) {
            [self encodeSubtitle:renderEncoder
                        viewport:viewport
                         texture:attach.subTexture];
        }
    }];
}

- (CGImageRef)_snapshotOrigin:(FSOverlayAttach *)attach
{
    CVPixelBufferRef pixelBuffer = CVPixelBufferRetain(attach.videoPicture);
    //[CIImage initWithCVPixelBuffer:options:] failed because its pixel format f420 is not supported.
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!ciImage) {
        return NULL;
    }
    static CIContext *context = nil;
    if (!context) {
        context = [CIContext contextWithOptions:NULL];
    }
    CGRect rect = CGRectMake(0,0,
                             CVPixelBufferGetWidth(pixelBuffer),
                             CVPixelBufferGetHeight(pixelBuffer));
    CGImageRef imageRef = [context createCGImage:ciImage fromRect:rect];
    CVPixelBufferRelease(pixelBuffer);
    return imageRef ? (CGImageRef)CFAutorelease(imageRef) : NULL;
}

- (CGImageRef)_snapshotScreen
{
    FSOverlayAttach *attach = self.currentAttach;
    
    CVPixelBufferRef pixelBuffer = attach.videoPicture;
    if (!pixelBuffer) {
        return NULL;
    }
    
    if (!self.offscreenRendering) {
        self.offscreenRendering = [FSMetalOffscreenRendering alloc];
    }
    
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
   
    if (![self setupPipelineIfNeed:attach blend:attach.hasAlpha]) {
        return NULL;
    }
    
    if (attach.subTexture && ![self setupSubPipelineIfNeed]) {
        return NULL;
    }
    
    CGSize viewport = self.drawableSize;
    return [self.offscreenRendering snapshot:viewport device:self.device commandBuffer:commandBuffer doUploadPicture:^(id<MTLRenderCommandEncoder> _Nonnull renderEncoder) {
        CVPixelBufferRef pixelBuffer = attach.videoPicture;
        if (pixelBuffer) {
            CGSize ratio = [self computeNormalizedVerticesRatio:attach drawableSize:viewport];
            [self encodePicture:attach
                  renderEncoder:renderEncoder
                       viewport:viewport
                          ratio:ratio];
        }
        
        if (attach.subTexture) {
            [self encodeSubtitle:renderEncoder
                        viewport:viewport
                         texture:attach.subTexture];
        }
    }];
}

- (CGImageRef)snapshot:(FSSnapshotType)aType
{
    switch (aType) {
        case FSSnapshotTypeOrigin:
            return [self _snapshotOrigin:self.currentAttach];
        case FSSnapshotTypeScreen:
            return [self _snapshotScreen];
        case FSSnapshotTypeEffect_Origin:
            return [self _snapshotWithSubtitle:NO];
        case FSSnapshotTypeEffect_Subtitle_Origin:
            return [self _snapshotWithSubtitle:YES];
    }
}

#if TARGET_OS_IOS || TARGET_OS_TV

- (void)applicationDidEnterBackground {
    self.isEnterBackground = YES;
}

- (void)applicationWillEnterForeground {
    self.isEnterBackground = NO;
    [self refreshDisplayConfigurationIfNeeded];
    [self setNeedsRefreshCurrentPic];
}

- (UIImage *)snapshot
{
    CGImageRef cgImg = [self snapshot:FSSnapshotTypeScreen];
    return [[UIImage alloc]initWithCGImage:cgImg];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    [self refreshDisplayConfigurationIfNeeded];
    
    if (!CGSizeEqualToSize(self.drawableSize, self.preferredDrawableSize)) {
        [self setNeedsRefreshCurrentPic];
    }
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    [self refreshDisplayConfigurationIfNeeded];
}

#else

- (void)resizeWithOldSuperviewSize:(NSSize)oldSize
{
    [super resizeWithOldSuperviewSize:oldSize];
    [self refreshDisplayConfigurationIfNeeded];
    [self setNeedsRefreshCurrentPic];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self refreshDisplayConfigurationIfNeeded];
}

#endif

- (void)setNeedsRefreshCurrentPic
{
    if (self.refreshCurrentPicBlock) {
        self.refreshCurrentPicBlock();
    } else {
        [self draw];
    }
}

mp_format * mp_get_metal_format(uint32_t cvpixfmt);

+ (NSArray<id<MTLTexture>> *)doGenerateTexture:(CVPixelBufferRef)pixelBuffer
                                  textureCache:(CVMetalTextureCacheRef)textureCache
{
    if (!pixelBuffer) {
        return nil;
    }
    
    NSMutableArray *result = [NSMutableArray array];
    
    OSType type = CVPixelBufferGetPixelFormatType(pixelBuffer);
    mp_format *ft = mp_get_metal_format(type);
    
    NSAssert(ft != NULL, @"wrong pixel format type.");
    
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    const bool planar = CVPixelBufferIsPlanar(pixelBuffer);
    const int planes  = (int)CVPixelBufferGetPlaneCount(pixelBuffer);
    assert(planar && planes == ft->planes || ft->planes == 1);
    
    for (int i = 0; i < ft->planes; i++) {
        size_t width  = CVPixelBufferGetWidthOfPlane(pixelBuffer, i);
        size_t height = CVPixelBufferGetHeightOfPlane(pixelBuffer, i);
        MTLPixelFormat format = ft->formats[i];
        CVMetalTextureRef textureRef = NULL; // CoreVideo的Metal纹理
        CVReturn status = CVMetalTextureCacheCreateTextureFromImage(NULL, textureCache, pixelBuffer, NULL, format, width, height, i, &textureRef);
        if (status == kCVReturnSuccess) {
            id<MTLTexture> texture = CVMetalTextureGetTexture(textureRef); // 转成Metal用的纹理
            if (texture != nil) {
                [result addObject:texture];
            }
            CFRelease(textureRef);
        }
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    return result;
}

- (void)registerRefreshCurrentPicObserver:(dispatch_block_t)block
{
    self.refreshCurrentPicBlock = block;
}

- (void)setPreferredColorSpace:(FSColorSpace)preferredColorSpace
{
    if (_preferredColorSpace == preferredColorSpace) {
        return;
    }
    _preferredColorSpace = preferredColorSpace;
    self.renderPlanner.preferredColorSpace = preferredColorSpace;
    [self refreshRenderIntentForAttach:self.currentAttach];
    [self setNeedsRefreshCurrentPic];
}

- (void)setPreferredHDRToneMapMode:(FSHDRToneMapMode)preferredHDRToneMapMode
{
    if (_preferredHDRToneMapMode == preferredHDRToneMapMode) {
        return;
    }
    _preferredHDRToneMapMode = preferredHDRToneMapMode;
    self.renderPlanner.preferredToneMapMode = preferredHDRToneMapMode;
    [self refreshRenderIntentForAttach:self.currentAttach];
    [self setNeedsRefreshCurrentPic];
}

- (BOOL)displayAttach:(FSOverlayAttach *)attach
{
    //hold the attach as current.
    self.currentAttach = attach;
    [self promoteHDRFrameInfoFromPixelBufferIfNeeded:attach];
    [self refreshDisplayConfigurationIfNeeded];
    [self refreshRenderIntentForAttach:attach];
    
    if (!attach.videoPicture) {
        ALOGW("FSMetalView: videoPicture is nil\n");
        return NO;
    }
    
    attach.videoTextures = [[self class] doGenerateTexture:attach.videoPicture textureCache:_pictureTextureCache];
    
#if TARGET_OS_IOS || TARGET_OS_TV
    // Execution of the command buffer was aborted due to an error during execution. Insufficient Permission (to submit GPU work from background) (00000006:kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted)
    if (self.isEnterBackground) {
        return NO;
    }
#endif
    
    if (self.preventDisplay) {
        return YES;
    }
    
    if (CGSizeEqualToSize(CGSizeZero, self.drawableSize)) {
        return NO;
    }
    
    //not dispatch to main thread, use current sub thread (ff_vout) draw
    [self draw];
    
    if (self.displayDelegate) {
        [self.displayDelegate videoRenderingDidDisplay:self attach:attach];
    }
    
    return YES;
}

#pragma mark - override setter methods

- (void)setScalingMode:(FSScalingMode)scalingMode
{
    if (_scalingMode != scalingMode) {
        _scalingMode = scalingMode;
        [self setNeedsRefreshCurrentPic];
    }
}

- (void)setRotatePreference:(FSRotatePreference)rotatePreference
{
    if (_rotatePreference.type != rotatePreference.type || _rotatePreference.degrees != rotatePreference.degrees) {
        _rotatePreference = rotatePreference;
        [self setNeedsRefreshCurrentPic];
    }
}

- (void)setColorPreference:(FSColorConvertPreference)colorPreference
{
    if (_colorPreference.brightness != colorPreference.brightness || _colorPreference.saturation != colorPreference.saturation || _colorPreference.contrast != colorPreference.contrast) {
        _colorPreference = colorPreference;
        [self setNeedsRefreshCurrentPic];
    }
}

- (void)setDarPreference:(FSDARPreference)darPreference
{
    if (_darPreference.ratio != darPreference.ratio) {
        _darPreference = darPreference;
        [self setNeedsRefreshCurrentPic];
    }
}

- (void)setBackgroundColor:(uint8_t)r g:(uint8_t)g b:(uint8_t)b
{
    self.clearColor = (MTLClearColor){r/255.0, g/255.0, b/255.0, 1.0f};
    self.needCleanBackgroundColor = YES;
    [self setNeedsRefreshCurrentPic];
}

- (id)context
{
    return self.device;
}

- (NSString *)name
{
    return @"Metal";
}

#if TARGET_OS_OSX
- (NSView *)hitTest:(NSPoint)point
{
    for (NSView *sub in [self subviews]) {
        NSPoint pointInSelf = [self convertPoint:point fromView:self.superview];
        NSPoint pointInSub = [self convertPoint:pointInSelf toView:sub];
        if (NSPointInRect(pointInSub, sub.bounds)) {
            return sub;
        }
    }
    return nil;
}

- (BOOL)acceptsFirstResponder
{
    return NO;
}

- (BOOL)mouseDownCanMoveWindow
{
    return YES;
}
#else
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    return NO;
}
#endif

@end
