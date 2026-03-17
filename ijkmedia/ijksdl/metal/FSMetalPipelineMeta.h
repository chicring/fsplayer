//
//  FSMetalPipelineMeta.h
//  FSPlayer
//
//  Created by debugly on 2023/6/26.
//

#import <Foundation/Foundation.h>
#import "FSMetalShaderTypes.h"
#import <CoreVideo/CVPixelBuffer.h>

NS_ASSUME_NONNULL_BEGIN
NS_CLASS_AVAILABLE(10_13, 11_0)
@interface FSMetalPipelineMeta : NSObject

@property (nonatomic) BOOL hdr;
@property (nonatomic) BOOL fullRange;
@property (nonatomic) NSString* fragmentName;
@property (nonatomic) FSColorTransferFunc transferFunc;
@property (nonatomic) FSYUV2RGBColorMatrixType convertMatrixType;
@property (nonatomic) BOOL doviReshapeEnabled;

+ (FSMetalPipelineMeta *)createWithCVPixelbuffer:(CVPixelBufferRef)pixelBuffer doviInfo:(const FSDOVIFrameInfo *)doviInfo;
- (BOOL)metaMatchedCVPixelbuffer:(CVPixelBufferRef)pixelBuffer doviInfo:(const FSDOVIFrameInfo *)doviInfo;

@end

NS_ASSUME_NONNULL_END
