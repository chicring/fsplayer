//
//  FSHDRRenderPlanner.h
//  FSPlayer
//
//  Clean render-planning boundary between decoder metadata transport and the
//  Metal renderer. Inspired by mdk's ColorSpace-driven HDR policy: decoder
//  parses frame semantics, planner chooses output target, renderer executes.
//

#import <Foundation/Foundation.h>
#import "FSMetalShaderTypes.h"
#import "../../wrapper/apple/FSColorSpace.h"
#include "../ijksdl_hdr_frame.h"

typedef struct FSHDRDisplayCaps {
    int supportsExtendedRange;
    int supportsPQOutput;
    int supportsSCRGBOutput;
} FSHDRDisplayCaps;

typedef struct FSHDRRenderIntent {
    int valid;
    int usesHDRPipeline;
    int isDolbyVision;
    int needsToneMapping;
    int needsGamutMapping;
    int allowsPassthrough;
    FSColorSpace outputColorSpace;
    FSColorTransferFunc outputTransfer;
} FSHDRRenderIntent;

NS_ASSUME_NONNULL_BEGIN
NS_CLASS_AVAILABLE(10_13, 11_0)
@interface FSHDRRenderPlanner : NSObject

@property(nonatomic) FSColorSpace preferredColorSpace;

- (instancetype)initWithPreferredColorSpace:(FSColorSpace)preferredColorSpace;
- (FSHDRRenderIntent)planForFrameInfo:(const FSHDRFrameInfo *)frameInfo
                          displayCaps:(FSHDRDisplayCaps)displayCaps;

@end
NS_ASSUME_NONNULL_END
