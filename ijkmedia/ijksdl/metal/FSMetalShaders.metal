//
//  FSMetalShaders.metal
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2022/11/23.
//  Copyright © 2022 debugly's Awesome FFmpeg Tutotial. All rights reserved.
//

#include <metal_stdlib>

using namespace metal;

// Include header shared between this Metal shader code and C code executing Metal API commands.
#include "FSMetalShaderTypes.h"

// Vertex shader outputs and fragment shader inputs
struct RasterizerData
{
    // The [[position]] attribute of this member indicates that this value
    // is the clip space position of the vertex when this structure is
    // returned from the vertex function.
    float4 clipSpacePosition [[position]];
    
    //    // Since this member does not have a special attribute, the rasterizer
    //    // interpolates its value with the values of the other triangle vertices
    //    // and then passes the interpolated value to the fragment shader for each
    //    // fragment in the triangle.
    //    float4 color;
    
    float2 textureCoordinate; // 纹理坐标，会做插值处理
};

//float4 subtitle(float4 rgba,float2 texCoord,texture2d<float> subTexture,FSSubtitleArguments subRect)
//{
//    if (!subRect.on) {
//        return rgba;
//    }
//
//    //翻转画面坐标系，这个会影响字幕在画面上的位置；翻转后从底部往上布局
//    texCoord.y = 1 - texCoord.y;
//
//    float sx = subRect.x;
//    float sy = subRect.y;
//    //限定字幕纹理区域
//    if (texCoord.x >= sx && texCoord.x <= (sx + subRect.w) && texCoord.y >= sy && texCoord.y <= (sy + subRect.h)) {
//        //在该区域内，将坐标缩放到 [0,1]
//        texCoord.x = (texCoord.x - sx) / subRect.w;
//        texCoord.y = (texCoord.y - sy) / subRect.h;
//        //flip the y
//        texCoord.y = 1 - texCoord.y;
//        constexpr sampler textureSampler (mag_filter::linear,
//                                          min_filter::linear);
//        // Sample the encoded texture in the argument buffer.
//        float4 textureSample = subTexture.sample(textureSampler, texCoord);
//        // Add the subtitle and color values together and return the result.
//        return float4((1.0 - textureSample.a) * rgba + textureSample);
//    }  else {
//        return rgba;
//    }
//}

/// @brief subtitle direct output fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
fragment float4 subtileDIRECTFragment(RasterizerData input [[stage_in]],
                                      texture2d<float> textureY [[ texture(FSFragmentTextureIndexTextureY) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    return textureY.sample(textureSampler, input.textureCoordinate);
}

fragment float4 subtilePaletteA8Fragment(RasterizerData input [[stage_in]],
                                      texture2d<float, access::read> textureY [[ texture(FSFragmentTextureIndexTextureY) ]],
                                        constant SubtitlePaletteFragmentData &data [[buffer(1)]])
{
    uint2 position = uint2(input.textureCoordinate * float2(data.w, data.h));
    
    int loc = int(textureY.read(position, 0).a * 255);
    uint c = data.colors[loc];
    uint mask = uint(0xFFu);
    uint b = c & mask;
    uint g = (c >> 8) & mask;
    uint r = (c >> 16) & mask;
    uint a = (c >> 24) & mask;

    // from straight to pre-multiplied alpha
    return float4(r, g, b, 255.0) * a / 65025.0;
}

/// @brief subtitle swap r g fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
fragment float4 subtileSWAPRGFragment(RasterizerData input [[stage_in]],
                                      texture2d<float> textureY [[ texture(FSFragmentTextureIndexTextureY) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    return textureY.sample(textureSampler, input.textureCoordinate).bgra;
}


#if __METAL_VERSION__ >= 200

struct FSFragmentShaderArguments {
    texture2d<float> textureY [[ id(FSFragmentTextureIndexTextureY) ]];
    texture2d<float> textureU [[ id(FSFragmentTextureIndexTextureU) ]];
    texture2d<float> textureV [[ id(FSFragmentTextureIndexTextureV) ]];
    device FSConvertMatrix * convertMatrix [[ id(FSFragmentMatrixIndexConvert) ]];
    device FSHDRFragmentUniforms * hdrUniforms [[ id(FSFragmentMatrixIndexHDR) ]];
};

vertex RasterizerData subVertexShader(uint vertexID [[vertex_id]],
                                      constant FSVertex *vertices [[buffer(FSVertexInputIndexVertices)]])
{
    RasterizerData out;
    out.clipSpacePosition = float4(vertices[vertexID].position, 0.0, 1.0);
    out.textureCoordinate = vertices[vertexID].textureCoordinate;
    return out;
}

//支持mvp矩阵
vertex RasterizerData mvpShader(uint vertexID [[vertex_id]],
                                constant FSVertexData & data [[buffer(FSVertexInputIndexVertices)]])
{
    RasterizerData out;
    FSVertex _vertex = data.vertexes[vertexID];
    float4 position = float4(_vertex.position, 0.0, 1.0);
    out.clipSpacePosition = data.modelMatrix * position;
    out.textureCoordinate = _vertex.textureCoordinate;
    return out;
}

float3 rgb_adjust(float3 rgb,float4 rgbAdjustment) {
    //C 是对比度值，B 是亮度值，S 是饱和度
    float B = rgbAdjustment.x;
    float S = rgbAdjustment.y;
    float C = rgbAdjustment.z;
    float on= rgbAdjustment.w;
    if (on > 0.99) {
        rgb = (rgb - 0.5) * C + 0.5;
        rgb = rgb + (0.75 * B - 0.5) / 2.5 - 0.1;
        float3 intensity = float3(rgb * float3(0.299, 0.587, 0.114));
        return intensity + S * (rgb - intensity);
    } else {
        return rgb;
    }
}

// mark -hdr helps

constant float kPQM1 = 0.1593017578125;
constant float kPQM2 = 78.84375;
constant float kPQC1 = 0.8359375;
constant float kPQC2 = 18.8515625;
constant float kPQC3 = 18.6875;
constant float kFSSDRReferenceWhiteNits = 100.0f;

float fs_safe_div(float x, float y)
{
    return x / max(y, 1e-6f);
}

float fs_max_component(float3 rgb)
{
    return max(max(rgb.r, rgb.g), rgb.b);
}

float fs_hash12(float2 p)
{
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

float arib_b67_inverse_oetf(float x)
{
    constexpr float ARIB_B67_A = 0.17883277;
    constexpr float ARIB_B67_B = 0.28466892;
    constexpr float ARIB_B67_C = 0.55991073;

    x = max(x, 0.0);
    if (x <= 0.5) {
        return (x * x) / 3.0;
    }
    return (exp((x - ARIB_B67_C) / ARIB_B67_A) + ARIB_B67_B) / 12.0;
}

float arib_b67_eotf(float x)
{
    x = arib_b67_inverse_oetf(x);
    return x < 0.0 ? x : pow(x, 1.2);
}

float3 arib_b67_eotf_vec(float3 v)
{
    return float3(arib_b67_eotf(v.r),
                  arib_b67_eotf(v.g),
                  arib_b67_eotf(v.b));
}

float fs_pq_eotf(float x)
{
    float xpow = pow(clamp(x, 0.0f, 1.0f), 1.0f / kPQM2);
    float num = max(xpow - kPQC1, 0.0f);
    float den = max(kPQC2 - kPQC3 * xpow, 1e-6f);
    return pow(num / den, 1.0f / kPQM1);
}

float fs_pq_oetf(float x)
{
    float value = pow(clamp(x, 0.0f, 1.0f), kPQM1);
    float num = kPQC1 + kPQC2 * value;
    float den = 1.0f + kPQC3 * value;
    return pow(fs_safe_div(num, den), kPQM2);
}

float3 fs_pq_eotf_vec(float3 v)
{
    return float3(fs_pq_eotf(v.r), fs_pq_eotf(v.g), fs_pq_eotf(v.b));
}

float3 fs_pq_oetf_vec(float3 v)
{
    return float3(fs_pq_oetf(v.r), fs_pq_oetf(v.g), fs_pq_oetf(v.b));
}

float fs_bt1886_inverse_eotf(float x)
{
    return x <= 0.0 ? 0.0 : pow(x, 1.0 / 2.4);
}

float3 fs_bt1886_inverse_eotf_vec(float3 v)
{
    return float3(fs_bt1886_inverse_eotf(v.r),
                  fs_bt1886_inverse_eotf(v.g),
                  fs_bt1886_inverse_eotf(v.b));
}

float fs_bt1886_eotf(float x)
{
    return x <= 0.0 ? 0.0 : pow(x, 2.4);
}

float3 fs_bt1886_eotf_vec(float3 v)
{
    return float3(fs_bt1886_eotf(v.r),
                  fs_bt1886_eotf(v.g),
                  fs_bt1886_eotf(v.b));
}

float fs_tonemap_aces(float x)
{
    const float a = 2.51f;
    const float b = 0.03f;
    const float c = 2.43f;
    const float d = 0.59f;
    const float e = 0.14f;
    return (x * (a * x + b)) / (x * (c * x + d) + e);
}

float fs_tonemap_hable_curve(float x)
{
    const float A = 0.15f;
    const float B = 0.50f;
    const float C = 0.10f;
    const float D = 0.20f;
    const float E = 0.02f;
    const float F = 0.30f;
    return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
}

float3 fs_bt2020_to_bt709_linear(float3 rgb)
{
    return float3(
        dot(rgb, float3(1.6605, -0.5876, -0.0728)),
        dot(rgb, float3(-0.1246, 1.1329, -0.0083)),
        dot(rgb, float3(-0.0182, -0.1006, 1.1187))
    );
}

float3 fs_bt709_to_bt2020_linear(float3 rgb)
{
    return float3(
        dot(rgb, float3(0.627409, 0.329260, 0.043272)),
        dot(rgb, float3(0.069125, 0.919549, 0.011321)),
        dot(rgb, float3(0.016423, 0.088048, 0.895617))
    );
}

float3 fs_hpe_lms_to_bt2020_linear(float3 lms)
{
    return float3(
        dot(lms, float3(3.06441879, -2.16597676, 0.10155818)),
        dot(lms, float3(-0.65612108, 1.78554118, -0.12943749)),
        dot(lms, float3(0.01736321, -0.04725154, 1.03004253))
    );
}

float3 fs_apply_matrix3(float3 v,
                        float3 row0,
                        float3 row1,
                        float3 row2)
{
    return float3(dot(v, row0), dot(v, row1), dot(v, row2));
}

float3 fs_apply_dolby_matrix(float3 v, device const float *m)
{
    return fs_apply_matrix3(v,
                            float3(m[0], m[1], m[2]),
                            float3(m[3], m[4], m[5]),
                            float3(m[6], m[7], m[8]));
}

float fs_eval_dolby_mmr(device const FSDolbyVisionReshapeComp *comp,
                        int pieceIndex,
                        float3 sig)
{
    float value = comp->mmr_constant[pieceIndex];
    float3 sigX = sig.xxy * sig.yzz;
    float4 cross1 = float4(sigX, sigX.x * sig.z);
    int order = clamp(comp->mmr_order[pieceIndex], 1, FS_HDR_MMR_MAX_ORDER);

    value += dot(sig, float3(comp->mmr_coef[pieceIndex][0][0],
                             comp->mmr_coef[pieceIndex][0][1],
                             comp->mmr_coef[pieceIndex][0][2]));
    value += dot(cross1, float4(comp->mmr_coef[pieceIndex][0][3],
                                comp->mmr_coef[pieceIndex][0][4],
                                comp->mmr_coef[pieceIndex][0][5],
                                comp->mmr_coef[pieceIndex][0][6]));

    if (order >= 2) {
        float3 sig2 = sig * sig;
        float4 cross2 = cross1 * cross1;
        value += dot(sig2, float3(comp->mmr_coef[pieceIndex][1][0],
                                  comp->mmr_coef[pieceIndex][1][1],
                                  comp->mmr_coef[pieceIndex][1][2]));
        value += dot(cross2, float4(comp->mmr_coef[pieceIndex][1][3],
                                    comp->mmr_coef[pieceIndex][1][4],
                                    comp->mmr_coef[pieceIndex][1][5],
                                    comp->mmr_coef[pieceIndex][1][6]));
    }

    if (order >= 3) {
        float3 sig3 = sig * sig * sig;
        float4 cross3 = cross1 * cross1 * cross1;
        value += dot(sig3, float3(comp->mmr_coef[pieceIndex][2][0],
                                  comp->mmr_coef[pieceIndex][2][1],
                                  comp->mmr_coef[pieceIndex][2][2]));
        value += dot(cross3, float4(comp->mmr_coef[pieceIndex][2][3],
                                    comp->mmr_coef[pieceIndex][2][4],
                                    comp->mmr_coef[pieceIndex][2][5],
                                    comp->mmr_coef[pieceIndex][2][6]));
    }

    return value;
}

float3 fs_dolby_reshape(float3 signal, device const FSDolbyVisionRenderParams *dv)
{
    float3 sig = clamp(signal, 0.0f, 1.0f);
    float3 sourceSig = sig;

    for (int c = 0; c < FS_HDR_COMPONENT_COUNT; c++) {
        device const FSDolbyVisionReshapeComp *comp = &dv->comp[c];
        int pieceCount = clamp(comp->num_pivots - 1, 0, FS_HDR_MAX_PIECES);
        float s = sourceSig[c];
        int pieceIndex = 0;

        if (pieceCount <= 0) {
            continue;
        }

        for (int i = 0; i < pieceCount; i++) {
            float hi = comp->pivots[i + 1];
            if (i == pieceCount - 1 || s < hi) {
                pieceIndex = i;
                break;
            }
        }

        if (comp->method[pieceIndex] == FS_DV_RESHAPE_MMR) {
            s = fs_eval_dolby_mmr(comp, pieceIndex, sourceSig);
        } else {
            float c0 = comp->poly_coef[pieceIndex][0];
            float c1 = comp->poly_coef[pieceIndex][1];
            float c2 = comp->poly_coef[pieceIndex][2];
            s = (c2 * s + c1) * s + c0;
        }

        sig[c] = clamp(s, comp->pivots[0], comp->pivots[comp->num_pivots - 1]);
    }

    return sig;
}

float3 fs_decode_dolby_vision_linear_bt2020(float3 signal,
                                            device const FSHDRFragmentUniforms *hdrUniforms)
{
    device const FSDolbyVisionRenderParams *dv = &hdrUniforms->dolbyVision;
    float3 reshaped = fs_dolby_reshape(signal, dv);
    float3 nonlinear = fs_apply_dolby_matrix(reshaped, dv->nonlinear_matrix) +
                       float3(dv->nonlinear_offset[0], dv->nonlinear_offset[1], dv->nonlinear_offset[2]);
    float3 lms = fs_pq_eotf_vec(clamp(nonlinear, 0.0f, 1.0f));
    lms = max(fs_apply_dolby_matrix(lms, dv->linear_matrix), 0.0f);
    return max(fs_hpe_lms_to_bt2020_linear(lms), 0.0f);
}

float4 yuv2rgb(float3 yuv, device FSConvertMatrix *convertMatrix)
{
    float3 rgb = convertMatrix->colorMatrix * (yuv + convertMatrix->offset);
    return float4(rgb_adjust(rgb, convertMatrix->adjustment), 1.0f);
}

float3 fs_linearize_hdr_rgb(float3 rgb, int transfer);

float3 fs_source_rgb_to_linear_bt2020(float3 encodedRgb,
                                      device const FSHDRFragmentUniforms *hdrUniforms)
{
    if (hdrUniforms->contentType == FS_HDR_CONTENT_TYPE_SDR) {
        float3 linear709 = fs_bt1886_eotf_vec(clamp(encodedRgb, 0.0f, 1.0f));
        float3 linearBt2020 = linear709;
        if (hdrUniforms->sourceMatrixType == FSYUV2RGBColorMatrixBT2020) {
            linearBt2020 = linear709;
        } else {
            linearBt2020 = fs_bt709_to_bt2020_linear(linear709);
        }
        // Normalize SDR reference white into the same 10000-nit linear domain as PQ EOTF.
        return linearBt2020 * (kFSSDRReferenceWhiteNits / 10000.0f);
    }

    if (hdrUniforms->useDolbyVisionShader && hdrUniforms->dolbyVision.valid) {
        return fs_decode_dolby_vision_linear_bt2020(encodedRgb, hdrUniforms);
    }

    return fs_linearize_hdr_rgb(encodedRgb, hdrUniforms->inputTransfer);
}

float3 fs_linearize_hdr_rgb(float3 rgb, int transfer)
{
    switch (transfer) {
        case FSColorTransferFuncPQ:
            return fs_pq_eotf_vec(clamp(rgb, 0.0f, 1.0f));
        case FSColorTransferFuncHLG:
            return 0.1f * arib_b67_eotf_vec(clamp(rgb, 0.0f, 1.0f));
        default:
            return max(rgb, 0.0f);
    }
}

float fs_bt2390_map_pq(float x,
                       float inputMinPQ,
                       float inputMaxPQ,
                       float outputMinPQ,
                       float outputMaxPQ,
                       float kneeOffset)
{
    float inputRange = max(inputMaxPQ - inputMinPQ, 1e-6f);
    float minLum = clamp((outputMinPQ - inputMinPQ) / inputRange, 0.0f, 1.0f);
    float maxLum = clamp((outputMaxPQ - inputMinPQ) / inputRange, minLum, 1.0f);
    float ks = (1.0f + kneeOffset) * maxLum - kneeOffset;
    float bp = minLum > 0.0f ? min(1.0f / max(minLum, 1e-6f), 4.0f) : 4.0f;
    float gainInv = 1.0f + minLum / max(maxLum, 1e-6f) * pow(max(1.0f - maxLum, 0.0f), bp);
    float gain = maxLum < 1.0f ? 1.0f / gainInv : 1.0f;
    float value = clamp((x - inputMinPQ) / inputRange, 0.0f, 1.0f);

    if (ks < 1.0f && value >= ks) {
        float tb = fs_safe_div(value - ks, 1.0f - ks);
        float tb2 = tb * tb;
        float tb3 = tb2 * tb;
        value = (2.0f * tb3 - 3.0f * tb2 + 1.0f) * ks +
                (tb3 - 2.0f * tb2 + tb) * (1.0f - ks) +
                (-2.0f * tb3 + 3.0f * tb2) * maxLum;
    }

    if (value < 1.0f) {
        value += minLum * pow(max(1.0f - value, 0.0f), bp);
        value = gain * (value - minLum) + minLum;
    }

    return clamp(value * inputRange + inputMinPQ, outputMinPQ, outputMaxPQ);
}

float3 fs_tone_map_bt2390(float3 rgb, device const FSHDRFragmentUniforms *hdrUniforms)
{
    float peak = fs_max_component(rgb);
    if (peak <= 0.0f) {
        return rgb;
    }

    float inputMinPQ = fs_pq_oetf(hdrUniforms->sourceMinNits / 10000.0f);
    float inputMaxPQ = fs_pq_oetf(max(hdrUniforms->sourceMaxNits / 10000.0f, peak));
    float outputMinPQ = fs_pq_oetf(hdrUniforms->targetMinNits / 10000.0f);
    float outputMaxPQ = fs_pq_oetf(hdrUniforms->targetMaxNits / 10000.0f);
    float mappedPeakPQ = fs_bt2390_map_pq(fs_pq_oetf(peak),
                                          inputMinPQ,
                                          inputMaxPQ,
                                          outputMinPQ,
                                          outputMaxPQ,
                                          1.0f);
    float mappedPeak = fs_pq_eotf(mappedPeakPQ);
    return rgb * fs_safe_div(mappedPeak, peak);
}

float3 fs_tone_map_hable(float3 rgb, device const FSHDRFragmentUniforms *hdrUniforms)
{
    float peak = fs_max_component(rgb);
    float sourcePeak = max(hdrUniforms->sourceMaxNits / 10000.0f, peak);
    float targetPeak = max(hdrUniforms->targetMaxNits / 10000.0f, 1e-6f);
    float scale = 1.0f / fs_tonemap_hable_curve(max(sourcePeak / targetPeak, 1.0f));
    float mappedPeak = scale * fs_tonemap_hable_curve(peak / targetPeak) * targetPeak;
    return peak > 0.0f ? rgb * (mappedPeak / peak) : rgb;
}

float3 fs_tone_map_aces(float3 rgb, device const FSHDRFragmentUniforms *hdrUniforms)
{
    float peak = fs_max_component(rgb);
    float sourcePeak = max(hdrUniforms->sourceMaxNits / 10000.0f, peak);
    float targetPeak = max(hdrUniforms->targetMaxNits / 10000.0f, 1e-6f);
    float scale = 1.0f / fs_tonemap_aces(max(sourcePeak / targetPeak, 1.0f));
    float mappedPeak = scale * fs_tonemap_aces(peak / targetPeak) * targetPeak;
    return peak > 0.0f ? rgb * (mappedPeak / peak) : rgb;
}

float3 fs_apply_tone_map(float3 rgb, device const FSHDRFragmentUniforms *hdrUniforms)
{
    if (!hdrUniforms->needsToneMapping) {
        return rgb;
    }

    switch (hdrUniforms->toneMapMode) {
        case FSHDRToneMapModeHable:
            return fs_tone_map_hable(rgb, hdrUniforms);
        case FSHDRToneMapModeACES:
            return fs_tone_map_aces(rgb, hdrUniforms);
        default:
            return fs_tone_map_bt2390(rgb, hdrUniforms);
    }
}

float3 fs_soft_gamut_map_bt709(float3 rgb)
{
    float luma = dot(max(rgb, 0.0f), float3(0.2126f, 0.7152f, 0.0722f));
    float minValue = min(min(rgb.r, rgb.g), rgb.b);
    float maxValue = max(max(rgb.r, rgb.g), rgb.b);
    float excursion = max(max(-minValue, 0.0f), max(maxValue - 1.0f, 0.0f));
    float compression = clamp(excursion / (1.0f + excursion), 0.0f, 1.0f);
    float3 compressed = mix(rgb, float3(luma), compression);
    return clamp(compressed, 0.0f, 1.0f);
}

float3 fs_encode_output_rgb(float3 linearBt2020,
                            device const FSHDRFragmentUniforms *hdrUniforms)
{
    float3 working = max(linearBt2020, 0.0f);
    working = fs_apply_tone_map(working, hdrUniforms);

    switch (hdrUniforms->outputColorSpace) {
        case FSColorSpaceBT2100_PQ:
            return fs_pq_oetf_vec(clamp(working, 0.0f, 1.0f));
        case FSColorSpaceSCRGB: {
            float3 rgb709 = fs_bt2020_to_bt709_linear(working);
            return rgb709 * (10000.0f / 100.0f);
        }
        default: {
            float3 rgb709 = fs_bt2020_to_bt709_linear(working);
            if (hdrUniforms->needsGamutMapping) {
                rgb709 = fs_soft_gamut_map_bt709(rgb709);
            }
            rgb709 *= 10000.0f / max(hdrUniforms->targetMaxNits, 1.0f);
            return fs_bt1886_inverse_eotf_vec(clamp(rgb709, 0.0f, 1.0f));
        }
    }
}

float3 fs_apply_dithering(float3 rgb,
                          float2 texCoord,
                          float2 textureSize,
                          device const FSHDRFragmentUniforms *hdrUniforms)
{
    if (!hdrUniforms->needsDithering) {
        return rgb;
    }
    float2 pixel = floor(texCoord * max(textureSize, float2(1.0f)));
    float noise = fs_hash12(pixel + float2(0.5f)) - 0.5f;
    return rgb + noise / 255.0f;
}

float4 fs_process_hdr_signal(float3 signal,
                             device FSConvertMatrix *convertMatrix,
                             device const FSHDRFragmentUniforms *hdrUniforms,
                             float2 texCoord,
                             float2 textureSize)
{
    float3 encodedRgb = convertMatrix->colorMatrix * (signal + convertMatrix->offset);
    float3 linearBt2020 = fs_source_rgb_to_linear_bt2020(encodedRgb,
                                                         hdrUniforms);

    float3 output = fs_encode_output_rgb(linearBt2020, hdrUniforms);
    output = rgb_adjust(output, convertMatrix->adjustment);
    output = fs_apply_dithering(output, texCoord, textureSize, hdrUniforms);

    if (hdrUniforms->outputColorSpace == FSColorSpaceSCRGB) {
        return float4(output, 1.0f);
    }

    return float4(clamp(output, 0.0f, 1.0f), 1.0f);
}

/// @brief hdr BiPlanar fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY/UV 是索引
/// @param buffer表明是缓存数据，FSFragmentBufferIndexMatrix是索引
fragment float4 nv12FragmentShader(RasterizerData input [[stage_in]],
                                   device FSFragmentShaderArguments & fragmentShaderArgs [[ buffer(FSFragmentBufferLocation0) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    texture2d<float> textureY = fragmentShaderArgs.textureY;
    texture2d<float> textureUV = fragmentShaderArgs.textureU;
    
    float3 yuv = float3(textureY.sample(textureSampler,  input.textureCoordinate).r,
                        textureUV.sample(textureSampler, input.textureCoordinate).rg);
    device const FSHDRFragmentUniforms *hdrUniforms = fragmentShaderArgs.hdrUniforms;
    if (hdrUniforms && hdrUniforms->valid &&
        (hdrUniforms->contentType != FS_HDR_CONTENT_TYPE_SDR ||
         hdrUniforms->outputColorSpace != FSColorSpaceBT709)) {
        return fs_process_hdr_signal(yuv,
                                     fragmentShaderArgs.convertMatrix,
                                     hdrUniforms,
                                     input.textureCoordinate,
                                     float2(textureY.get_width(), textureY.get_height()));
    }
    return yuv2rgb(yuv, fragmentShaderArgs.convertMatrix);
}

/// @brief yuv420p fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY/U/V 是索引
/// @param buffer表明是缓存数据，FSFragmentBufferIndexMatrix是索引
fragment float4 yuv420pFragmentShader(RasterizerData input [[stage_in]],
                                      device FSFragmentShaderArguments & fragmentShaderArgs [[ buffer(FSFragmentBufferLocation0) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    texture2d<float> textureY = fragmentShaderArgs.textureY;
    texture2d<float> textureU = fragmentShaderArgs.textureU;
    texture2d<float> textureV = fragmentShaderArgs.textureV;
    
    float3 yuv = float3(textureY.sample(textureSampler, input.textureCoordinate).r,
                        textureU.sample(textureSampler, input.textureCoordinate).r,
                        textureV.sample(textureSampler, input.textureCoordinate).r);
    device const FSHDRFragmentUniforms *hdrUniforms = fragmentShaderArgs.hdrUniforms;
    if (hdrUniforms && hdrUniforms->valid &&
        (hdrUniforms->contentType != FS_HDR_CONTENT_TYPE_SDR ||
         hdrUniforms->outputColorSpace != FSColorSpaceBT709)) {
        return fs_process_hdr_signal(yuv,
                                     fragmentShaderArgs.convertMatrix,
                                     hdrUniforms,
                                     input.textureCoordinate,
                                     float2(textureY.get_width(), textureY.get_height()));
    }
    return yuv2rgb(yuv, fragmentShaderArgs.convertMatrix);
}

/// @brief uyvy422 fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
/// @param buffer表明是缓存数据，FSFragmentBufferIndexMatrix是索引
fragment float4 uyvy422FragmentShader(RasterizerData input [[stage_in]],
                                      device FSFragmentShaderArguments & fragmentShaderArgs [[ buffer(FSFragmentBufferLocation0) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    texture2d<float> textureY = fragmentShaderArgs.textureY;
    float3 tc = textureY.sample(textureSampler, input.textureCoordinate).rgb;
    float3 yuv = float3(tc.g, tc.b, tc.r);
    device const FSHDRFragmentUniforms *hdrUniforms = fragmentShaderArgs.hdrUniforms;
    if (hdrUniforms && hdrUniforms->valid &&
        (hdrUniforms->contentType != FS_HDR_CONTENT_TYPE_SDR ||
         hdrUniforms->outputColorSpace != FSColorSpaceBT709)) {
        return fs_process_hdr_signal(yuv,
                                     fragmentShaderArgs.convertMatrix,
                                     hdrUniforms,
                                     input.textureCoordinate,
                                     float2(textureY.get_width(), textureY.get_height()));
    }
    return yuv2rgb(yuv, fragmentShaderArgs.convertMatrix);
}

/// @brief ayuv fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
/// @param buffer表明是缓存数据，FSFragmentBufferIndexMatrix是索引
fragment float4 ayuvFragmentShader(RasterizerData input [[stage_in]],
                                   device FSFragmentShaderArguments & fragmentShaderArgs [[ buffer(FSFragmentBufferLocation0) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    texture2d<float> textureY = fragmentShaderArgs.textureY;
    float4 tc = textureY.sample(textureSampler, input.textureCoordinate).rgba;
    float3 yuv = float3(tc.g, tc.b, tc.a);
    device const FSHDRFragmentUniforms *hdrUniforms = fragmentShaderArgs.hdrUniforms;
    if (hdrUniforms && hdrUniforms->valid &&
        (hdrUniforms->contentType != FS_HDR_CONTENT_TYPE_SDR ||
         hdrUniforms->outputColorSpace != FSColorSpaceBT709)) {
        return fs_process_hdr_signal(yuv,
                                     fragmentShaderArgs.convertMatrix,
                                     hdrUniforms,
                                     input.textureCoordinate,
                                     float2(textureY.get_width(), textureY.get_height()));
    }
    return yuv2rgb(yuv, fragmentShaderArgs.convertMatrix);
}

/// @brief bgra fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
fragment float4 bgraFragmentShader(RasterizerData input [[stage_in]],
                                   device FSFragmentShaderArguments & fragmentShaderArgs [[ buffer(FSFragmentBufferLocation0) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    texture2d<float> textureY = fragmentShaderArgs.textureY;
    //auto converted bgra -> rgba
    float4 rgba = textureY.sample(textureSampler, input.textureCoordinate);
    //color adjustment
    device FSConvertMatrix* convertMatrix = fragmentShaderArgs.convertMatrix;
    device const FSHDRFragmentUniforms *hdrUniforms = fragmentShaderArgs.hdrUniforms;
    if (hdrUniforms && hdrUniforms->valid &&
        (hdrUniforms->contentType != FS_HDR_CONTENT_TYPE_SDR ||
         hdrUniforms->outputColorSpace != FSColorSpaceBT709)) {
        float3 linearBt2020 = fs_source_rgb_to_linear_bt2020(rgba.rgb,
                                                             hdrUniforms);
        float3 output = fs_encode_output_rgb(linearBt2020, hdrUniforms);
        output = rgb_adjust(output, convertMatrix->adjustment);
        output = fs_apply_dithering(output,
                                    input.textureCoordinate,
                                    float2(textureY.get_width(), textureY.get_height()),
                                    hdrUniforms);
        if (hdrUniforms->outputColorSpace == FSColorSpaceSCRGB) {
            return float4(output, rgba.a);
        }
        return float4(clamp(output, 0.0f, 1.0f), rgba.a);
    }
    return float4(rgb_adjust(rgba.rgb, convertMatrix->adjustment),rgba.a);
}

/// @brief argb fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
fragment float4 argbFragmentShader(RasterizerData input [[stage_in]],
                                   device FSFragmentShaderArguments & fragmentShaderArgs [[ buffer(FSFragmentBufferLocation0) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    texture2d<float> textureY = fragmentShaderArgs.textureY;
    //auto converted bgra -> rgba;but data is argb,so target is grab
    float4 grab = textureY.sample(textureSampler, input.textureCoordinate);
    //color adjustment
    device FSConvertMatrix* convertMatrix = fragmentShaderArgs.convertMatrix;
    device const FSHDRFragmentUniforms *hdrUniforms = fragmentShaderArgs.hdrUniforms;
    if (hdrUniforms && hdrUniforms->valid &&
        (hdrUniforms->contentType != FS_HDR_CONTENT_TYPE_SDR ||
         hdrUniforms->outputColorSpace != FSColorSpaceBT709)) {
        float3 linearBt2020 = fs_source_rgb_to_linear_bt2020(grab.gra,
                                                             hdrUniforms);
        float3 output = fs_encode_output_rgb(linearBt2020, hdrUniforms);
        output = rgb_adjust(output, convertMatrix->adjustment);
        output = fs_apply_dithering(output,
                                    input.textureCoordinate,
                                    float2(textureY.get_width(), textureY.get_height()),
                                    hdrUniforms);
        if (hdrUniforms->outputColorSpace == FSColorSpaceSCRGB) {
            return float4(output, grab.b);
        }
        return float4(clamp(output, 0.0f, 1.0f), grab.b);
    }
    return float4(rgb_adjust(grab.gra, convertMatrix->adjustment),grab.b);
}

#else

vertex RasterizerData subVertexShader(uint vertexID [[vertex_id]],
                                      constant FSVertex *vertices [[buffer(FSVertexInputIndexVertices)]])
{
    RasterizerData out;
    out.clipSpacePosition = float4(vertices[vertexID].position, 0.0, 1.0);
    out.textureCoordinate = vertices[vertexID].textureCoordinate;
    return out;
}

//支持mvp矩阵
vertex RasterizerData mvpShader(uint vertexID [[vertex_id]],
                                constant FSVertexData & data [[buffer(FSVertexInputIndexVertices)]])
{
    RasterizerData out;
    FSVertex _vertex = data.vertexes[vertexID];
    float4 position = float4(_vertex.position, 0.0, 1.0);
    out.clipSpacePosition = data.modelMatrix * position;
    out.textureCoordinate = _vertex.textureCoordinate;
    return out;
}

float3 rgb_adjust(float3 rgb,float4 rgbAdjustment) {
    //C 是对比度值，B 是亮度值，S 是饱和度
    float B = rgbAdjustment.x;
    float S = rgbAdjustment.y;
    float C = rgbAdjustment.z;
    float on= rgbAdjustment.w;
    if (on > 0.99) {
        rgb = (rgb - 0.5) * C + 0.5;
        rgb = rgb + (0.75 * B - 0.5) / 2.5 - 0.1;
        float3 intensity = float3(rgb * float3(0.299, 0.587, 0.114));
        return intensity + S * (rgb - intensity);
    } else {
        return rgb;
    }
}

/// @brief bgra fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
fragment float4 bgraFragmentShader(RasterizerData input [[stage_in]],
                                   texture2d<float> textureY [[ texture(FSFragmentTextureIndexTextureY) ]],
                                   constant FSConvertMatrix &convertMatrix [[ buffer(FSFragmentMatrixIndexConvert) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    //auto converted bgra -> rgba
    float4 rgba = textureY.sample(textureSampler, input.textureCoordinate);
    //color adjustment
    return float4(rgb_adjust(rgba.rgb, convertMatrix.adjustment),rgba.a);
}

/// @brief argb fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
fragment float4 argbFragmentShader(RasterizerData input [[stage_in]],
                                   texture2d<float> textureY [[ texture(FSFragmentTextureIndexTextureY) ]],
                                   constant FSConvertMatrix &convertMatrix [[ buffer(FSFragmentMatrixIndexConvert) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    //auto converted bgra -> rgba
    float4 grab = textureY.sample(textureSampler, input.textureCoordinate);
    //color adjustment
    return float4(rgb_adjust(grab.gra, convertMatrix.adjustment),grab.b);
}

/// @brief nv12 fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY/UV 是索引
/// @param buffer表明是缓存数据，FSFragmentBufferIndexMatrix是索引
fragment float4 nv12FragmentShader(RasterizerData input [[stage_in]],
                                   texture2d<float> textureY  [[ texture(FSFragmentTextureIndexTextureY)  ]],
                                   texture2d<float> textureUV [[ texture(FSFragmentTextureIndexTextureU) ]],
                                   constant FSConvertMatrix &convertMatrix [[ buffer(FSFragmentMatrixIndexConvert) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    
    float3 yuv = float3(textureY.sample(textureSampler,  input.textureCoordinate).r,
                        textureUV.sample(textureSampler, input.textureCoordinate).rg);
    
    float3 rgb = convertMatrix.matrix * (yuv + convertMatrix.offset);
    //color adjustment
    return float4(rgb_adjust(rgb,convertMatrix.adjustment),1.0);
}

/// @brief yuv420p fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY/U/V 是索引
/// @param buffer表明是缓存数据，FSFragmentBufferIndexMatrix是索引
fragment float4 yuv420pFragmentShader(RasterizerData input [[stage_in]],
                                      texture2d<float> textureY [[ texture(FSFragmentTextureIndexTextureY) ]],
                                      texture2d<float> textureU [[ texture(FSFragmentTextureIndexTextureU) ]],
                                      texture2d<float> textureV [[ texture(FSFragmentTextureIndexTextureV) ]],
                                      constant FSConvertMatrix &convertMatrix [[ buffer(FSFragmentMatrixIndexConvert) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    
    float3 yuv = float3(textureY.sample(textureSampler, input.textureCoordinate).r,
                        textureU.sample(textureSampler, input.textureCoordinate).r,
                        textureV.sample(textureSampler, input.textureCoordinate).r);
    
    float3 rgb = convertMatrix.matrix * (yuv + convertMatrix.offset);
    //color adjustment
    return float4(rgb_adjust(rgb,convertMatrix.adjustment),1.0);
}

/// @brief uyvy422 fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
/// @param buffer表明是缓存数据，FSFragmentBufferIndexMatrix是索引
fragment float4 uyvy422FragmentShader(RasterizerData input [[stage_in]],
                                      texture2d<float> textureY [[ texture(FSFragmentTextureIndexTextureY) ]],
                                      constant FSConvertMatrix &convertMatrix [[ buffer(FSFragmentMatrixIndexConvert) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    float3 tc = textureY.sample(textureSampler, input.textureCoordinate).rgb;
    float3 yuv = float3(tc.g, tc.b, tc.r);
    
    float3 rgb = convertMatrix.matrix * (yuv + convertMatrix.offset);
    //color adjustment
    return float4(rgb_adjust(rgb,convertMatrix.adjustment),1.0);
}
#endif
