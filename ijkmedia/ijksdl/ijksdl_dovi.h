#ifndef FSSDL__IJKSDL_DOVI_H
#define FSSDL__IJKSDL_DOVI_H

#define FS_DOVI_MAX_PIECES 8
#define FS_DOVI_COMPONENT_COUNT 3

typedef enum FSDOVIReshapeMethod {
    FS_DOVI_RESHAPE_NONE = 0,
    FS_DOVI_RESHAPE_POLYNOMIAL = 1,
    FS_DOVI_RESHAPE_MMR = 2,
} FSDOVIReshapeMethod;

typedef struct FSDOVIReshapeComp {
    int num_pivots;
    int method[FS_DOVI_MAX_PIECES];
    float pivots[FS_DOVI_MAX_PIECES + 1];
    float poly_coef[FS_DOVI_MAX_PIECES][3];
} FSDOVIReshapeComp;

typedef struct FSDOVIParams {
    int enabled;
    int has_mmr;
    FSDOVIReshapeComp comp[FS_DOVI_COMPONENT_COUNT];
    float nonlinear_matrix[9];
    float nonlinear_offset[3];
    float linear_matrix[9];
} FSDOVIParams;

typedef struct FSDOVIFrameInfo {
    int has_dovi;
    int dovi_profile;
    int is_software_decode;
    FSDOVIParams reshape_params;
} FSDOVIFrameInfo;

#endif
