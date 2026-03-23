//
//  FSHDRRenderPlanner.m
//  FSPlayer
//

#import "FSHDRRenderPlanner.h"
#include "ijksdl/ffmpeg/ijksdl_inc_ffmpeg.h"

static BOOL fs_hdr_frame_is_hdr(const FSHDRFrameInfo *frameInfo)
{
    if (!frameInfo || !frameInfo->valid) {
        return NO;
    }
    return frameInfo->content_type == FS_HDR_CONTENT_TYPE_HDR10 ||
           frameInfo->content_type == FS_HDR_CONTENT_TYPE_HLG ||
           frameInfo->content_type == FS_HDR_CONTENT_TYPE_DOLBY_VISION_LL;
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

    intent.valid = frameInfo && frameInfo->valid;
    if (!intent.valid) {
        intent.outputColorSpace = targetColorSpace;
        intent.outputTransfer = FSColorTransferFuncLINEAR;
        return intent;
    }

    bt2020Input = frameInfo->primaries == AVCOL_PRI_BT2020 ||
                  frameInfo->matrix == AVCOL_SPC_BT2020_NCL ||
                  frameInfo->matrix == AVCOL_SPC_BT2020_CL ||
                  frameInfo->content_type == FS_HDR_CONTENT_TYPE_DOLBY_VISION_LL;

    if (targetColorSpace == FSColorSpaceUnknown) {
        if (hdrInput && displayCaps.supportsPQOutput) {
            targetColorSpace = FSColorSpaceBT2100_PQ;
        } else if (hdrInput && displayCaps.supportsSCRGBOutput) {
            targetColorSpace = FSColorSpaceSCRGB;
        } else {
            targetColorSpace = FSColorSpaceBT709;
        }
    }

    intent.outputColorSpace = targetColorSpace;
    intent.outputTransfer = targetColorSpace == FSColorSpaceBT2100_PQ ? FSColorTransferFuncPQ : FSColorTransferFuncLINEAR;
    intent.usesHDRPipeline = hdrInput;
    intent.isDolbyVision = frameInfo->content_type == FS_HDR_CONTENT_TYPE_DOLBY_VISION_LL;
    intent.needsToneMapping = hdrInput && targetColorSpace == FSColorSpaceBT709;
    intent.needsGamutMapping = bt2020Input && targetColorSpace == FSColorSpaceBT709;
    intent.allowsPassthrough = hdrInput &&
                               (targetColorSpace == FSColorSpaceBT2100_PQ ||
                                targetColorSpace == FSColorSpaceSCRGB) &&
                               displayCaps.supportsExtendedRange;
    return intent;
}

@end
