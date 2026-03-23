/*
 * FSColorSpace.h
 *
 * Public output colorspace contract used by FSOptions, FSPlayer and the
 * renderer planner. This stays independent from decoder metadata so the
 * playback stack can choose output policy without coupling it to bitstream
 * parsing details.
 */

#ifndef FSColorSpace_h
#define FSColorSpace_h

#if defined(__OBJC__)
#import <Foundation/Foundation.h>
typedef NS_ENUM(NSInteger, FSColorSpace) {
    FSColorSpaceUnknown = 0,
    FSColorSpaceBT709 = 1,
    FSColorSpaceBT2100_PQ = 2,
    FSColorSpaceSCRGB = 3,
};
typedef NS_ENUM(NSInteger, FSHDRToneMapMode) {
    FSHDRToneMapModeBT2390 = 0,
    FSHDRToneMapModeHable = 1,
    FSHDRToneMapModeACES = 2,
};
#else
typedef enum FSColorSpace {
    FSColorSpaceUnknown = 0,
    FSColorSpaceBT709 = 1,
    FSColorSpaceBT2100_PQ = 2,
    FSColorSpaceSCRGB = 3,
} FSColorSpace;
typedef enum FSHDRToneMapMode {
    FSHDRToneMapModeBT2390 = 0,
    FSHDRToneMapModeHable = 1,
    FSHDRToneMapModeACES = 2,
} FSHDRToneMapMode;
#endif

#endif
