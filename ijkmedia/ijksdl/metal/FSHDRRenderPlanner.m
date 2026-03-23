//
//  FSHDRRenderPlanner.m
//  FSPlayer
//

#import "FSHDRRenderPlanner.h"
#include "ijksdl/ffmpeg/ijksdl_inc_ffmpeg.h"
#include <math.h>

static const float kFSHDRDefaultSourceMaxNits = 1000.0f;
static const float kFSHDRDefaultSDRTargetMaxNits = 100.0f;
static const float kFSHDRDefaultTargetMinNits = 0.0f;
static const float kFSHDRDefaultHDRTargetMaxNits = 1000.0f;

static BOOL fs_hdr_frame_is_hdr(const FSHDRFrameInfo *frameInfo)
{
    if (!frameInfo || !frameInfo->valid) {
        return NO;
    }
    return frameInfo->content_type == FS_HDR_CONTENT_TYPE_HDR10 ||
           frameInfo->content_type == FS_HDR_CONTENT_TYPE_HLG ||
           frameInfo->content_type == FS_HDR_CONTENT_TYPE_DOLBY_VISION_LL;
}

static FSColorTransferFunc fs_hdr_input_transfer(const FSHDRFrameInfo *frameInfo)
{
    if (!frameInfo || !frameInfo->valid) {
        return FSColorTransferFuncLINEAR;
    }

    if (frameInfo->content_type == FS_HDR_CONTENT_TYPE_DOLBY_VISION_LL) {
        return FSColorTransferFuncPQ;
    }

    switch (frameInfo->transfer) {
        case AVCOL_TRC_SMPTE2084:
            return FSColorTransferFuncPQ;
        case AVCOL_TRC_ARIB_STD_B67:
            return FSColorTransferFuncHLG;
        default:
            return FSColorTransferFuncLINEAR;
    }
}

static float fs_hdr_pq_to_nits(float pq)
{
    const float m1 = 0.1593017578125f;
    const float m2 = 78.84375f;
    const float c1 = 0.8359375f;
    const float c2 = 18.8515625f;
    const float c3 = 18.6875f;
    float x = fmaxf(0.0f, fminf(pq, 1.0f));
    float xpow = powf(x, 1.0f / m2);
    float num = fmaxf(xpow - c1, 0.0f);
    float den = fmaxf(c2 - c3 * xpow, 1e-6f);
    return 10000.0f * powf(num / den, 1.0f / m1);
}

static float fs_hdr_pick_source_min_nits(const FSHDRFrameInfo *frameInfo)
{
    if (!frameInfo) {
        return kFSHDRDefaultTargetMinNits;
    }

    if (frameInfo->dolby_vision.valid && frameInfo->dolby_vision.trim.has_level1 && frameInfo->dolby_vision.trim.min_pq > 0.0f) {
        return fs_hdr_pq_to_nits(frameInfo->dolby_vision.trim.min_pq);
    }

    if (frameInfo->mastering_min_nits > 0.0f) {
        return frameInfo->mastering_min_nits;
    }

    return kFSHDRDefaultTargetMinNits;
}

static float fs_hdr_pick_source_average_nits(const FSHDRFrameInfo *frameInfo)
{
    if (!frameInfo) {
        return 0.0f;
    }

    if (frameInfo->dolby_vision.valid && frameInfo->dolby_vision.trim.has_level1 && frameInfo->dolby_vision.trim.avg_pq > 0.0f) {
        return fs_hdr_pq_to_nits(frameInfo->dolby_vision.trim.avg_pq);
    }

    if (frameInfo->max_fall > 0.0f) {
        return frameInfo->max_fall;
    }

    return 0.0f;
}

static float fs_hdr_pick_source_max_nits(const FSHDRFrameInfo *frameInfo)
{
    if (!frameInfo) {
        return kFSHDRDefaultSourceMaxNits;
    }

    if (frameInfo->content_type == FS_HDR_CONTENT_TYPE_SDR) {
        return kFSHDRDefaultSDRTargetMaxNits;
    }

    if (frameInfo->dolby_vision.valid && frameInfo->dolby_vision.trim.has_level1 && frameInfo->dolby_vision.trim.max_pq > 0.0f) {
        return fs_hdr_pq_to_nits(frameInfo->dolby_vision.trim.max_pq);
    }

    if (frameInfo->max_cll > 0.0f) {
        return frameInfo->max_cll;
    }

    if (frameInfo->mastering_max_nits > 0.0f) {
        return frameInfo->mastering_max_nits;
    }

    if (frameInfo->dolby_vision.valid && frameInfo->dolby_vision.source_max_pq > 0.0f) {
        return fs_hdr_pq_to_nits(frameInfo->dolby_vision.source_max_pq);
    }

    return kFSHDRDefaultSourceMaxNits;
}

@implementation FSHDRRenderPlanner

- (instancetype)init
{
    return [self initWithPreferredColorSpace:FSColorSpaceBT709];
}

- (instancetype)initWithPreferredColorSpace:(FSColorSpace)preferredColorSpace
{
    self = [super init];
    if (self) {
        _preferredColorSpace = preferredColorSpace;
        _preferredToneMapMode = FSHDRToneMapModeBT2390;
    }
    return self;
}

- (FSHDRRenderIntent)planForFrameInfo:(const FSHDRFrameInfo *)frameInfo
                          displayCaps:(FSHDRDisplayCaps)displayCaps
{
    FSHDRRenderIntent intent = {0};
    FSColorSpace targetColorSpace = self.preferredColorSpace;
    BOOL hdrInput = fs_hdr_frame_is_hdr(frameInfo);
    BOOL bt2020Input = NO;
    float sourceMaxNits = 0.0f;
    float scRGBTargetMaxNits = 0.0f;

    intent.valid = frameInfo && frameInfo->valid;
    if (!intent.valid) {
        intent.outputColorSpace = targetColorSpace;
        return intent;
    }

    bt2020Input = frameInfo->primaries == AVCOL_PRI_BT2020 ||
                  frameInfo->matrix == AVCOL_SPC_BT2020_NCL ||
                  frameInfo->matrix == AVCOL_SPC_BT2020_CL ||
                  frameInfo->content_type == FS_HDR_CONTENT_TYPE_DOLBY_VISION_LL;
    sourceMaxNits = fs_hdr_pick_source_max_nits(frameInfo);
    scRGBTargetMaxNits = fmaxf(displayCaps.headroom, 1.0f) * kFSHDRDefaultSDRTargetMaxNits;

    if (targetColorSpace == FSColorSpaceUnknown) {
        if (hdrInput && displayCaps.supportsPQOutput) {
            targetColorSpace = FSColorSpaceBT2100_PQ;
        } else if (hdrInput && displayCaps.supportsSCRGBOutput) {
            targetColorSpace = FSColorSpaceSCRGB;
        } else {
            targetColorSpace = FSColorSpaceBT709;
        }
    }

    if (targetColorSpace != FSColorSpaceBT709 && !displayCaps.supportsExtendedRange) {
        targetColorSpace = FSColorSpaceBT709;
    }

    intent.outputColorSpace = targetColorSpace;
    intent.inputTransfer = fs_hdr_input_transfer(frameInfo);
    intent.usesHDRPipeline = hdrInput || targetColorSpace != FSColorSpaceBT709;
    intent.useDolbyVisionShader = frameInfo->content_type == FS_HDR_CONTENT_TYPE_DOLBY_VISION_LL &&
                                  frameInfo->decode_path == FS_HDR_DECODE_PATH_FFMPEG_SOFTWARE &&
                                  frameInfo->dolby_vision.valid &&
                                  frameInfo->dolby_vision.profile == 5;
    intent.needsToneMapping = hdrInput &&
                              (targetColorSpace == FSColorSpaceBT709 ||
                               (targetColorSpace == FSColorSpaceSCRGB && sourceMaxNits > scRGBTargetMaxNits));
    intent.needsGamutMapping = bt2020Input && targetColorSpace == FSColorSpaceBT709;
    intent.needsHDRDrawable = targetColorSpace != FSColorSpaceBT709 && displayCaps.supportsExtendedRange;
    intent.needsDithering = targetColorSpace == FSColorSpaceBT709;
    intent.toneMapMode = self.preferredToneMapMode;
    intent.sourceMinNits = fs_hdr_pick_source_min_nits(frameInfo);
    intent.sourceMaxNits = sourceMaxNits;
    intent.sourceAverageNits = fs_hdr_pick_source_average_nits(frameInfo);
    intent.targetMinNits = kFSHDRDefaultTargetMinNits;
    if (targetColorSpace == FSColorSpaceBT709) {
        intent.targetMaxNits = kFSHDRDefaultSDRTargetMaxNits;
    } else if (targetColorSpace == FSColorSpaceSCRGB) {
        intent.targetMaxNits = scRGBTargetMaxNits;
    } else {
        intent.targetMaxNits = kFSHDRDefaultHDRTargetMaxNits;
    }
    intent.outputHeadroom = fmaxf(displayCaps.headroom, 1.0f);
    return intent;
}

@end
