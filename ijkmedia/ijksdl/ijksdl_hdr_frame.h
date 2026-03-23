#ifndef FSSDL__IJKSDL_HDR_FRAME_H
#define FSSDL__IJKSDL_HDR_FRAME_H

#define FS_HDR_MAX_PIECES 8
#define FS_HDR_COMPONENT_COUNT 3
#define FS_HDR_MMR_MAX_ORDER 3
#define FS_HDR_MMR_MAX_COEFFS 7
#define FS_HDR_DV_VECTOR_FIELD_COUNT 6

typedef enum FSHDRContentType {
    FS_HDR_CONTENT_TYPE_SDR = 0,
    FS_HDR_CONTENT_TYPE_HDR10 = 1,
    FS_HDR_CONTENT_TYPE_HLG = 2,
    FS_HDR_CONTENT_TYPE_DOLBY_VISION_LL = 3,
} FSHDRContentType;

typedef enum FSHDRDecodePath {
    FS_HDR_DECODE_PATH_UNKNOWN = 0,
    FS_HDR_DECODE_PATH_VIDEOTOOLBOX = 1,
    FS_HDR_DECODE_PATH_FFMPEG_SOFTWARE = 2,
} FSHDRDecodePath;

typedef enum FSDolbyVisionReshapeMethod {
    FS_DV_RESHAPE_NONE = 0,
    FS_DV_RESHAPE_POLYNOMIAL = 1,
    FS_DV_RESHAPE_MMR = 2,
} FSDolbyVisionReshapeMethod;

typedef struct FSDolbyVisionReshapeComp {
    int num_pivots;
    int method[FS_HDR_MAX_PIECES];
    int poly_order[FS_HDR_MAX_PIECES];
    float pivots[FS_HDR_MAX_PIECES + 1];
    float poly_coef[FS_HDR_MAX_PIECES][3];
    float mmr_constant[FS_HDR_MAX_PIECES];
    float mmr_coef[FS_HDR_MAX_PIECES][FS_HDR_MMR_MAX_ORDER][FS_HDR_MMR_MAX_COEFFS];
    int mmr_order[FS_HDR_MAX_PIECES];
} FSDolbyVisionReshapeComp;

typedef struct FSDolbyVisionTrimMetadata {
    int has_level1;
    float min_pq;
    float max_pq;
    float avg_pq;

    int has_level2;
    int target_max_pq;
    int trim_slope;
    int trim_offset;
    int trim_power;
    int trim_chroma_weight;
    int trim_saturation_gain;
    int ms_weight;

    int has_level8;
    int level8_target_display_index;
    int level8_trim_slope;
    int level8_trim_offset;
    int level8_trim_power;
    int level8_trim_chroma_weight;
    int level8_trim_saturation_gain;
    int level8_ms_weight;
    int target_mid_contrast;
    int clip_trim;
    int saturation_vector_field[FS_HDR_DV_VECTOR_FIELD_COUNT];
    int hue_vector_field[FS_HDR_DV_VECTOR_FIELD_COUNT];

    int has_level6;
    float max_luminance;
    float min_luminance;
    float max_cll;
    float max_fall;
} FSDolbyVisionTrimMetadata;

typedef struct FSDolbyVisionRenderParams {
    int valid;
    int profile;
    int level;
    int has_mmr;
    int signal_bit_depth;
    int bl_bit_depth;
    int el_bit_depth;
    int vdr_bit_depth;
    int signal_full_range;
    int bl_signal_full_range;
    int mapping_color_space;
    int mapping_chroma_format_idc;
    int signal_eotf;
    int dm_metadata_id;
    int scene_refresh_flag;
    int ext_mapping_idc_0_4;
    float source_min_pq;
    float source_max_pq;
    float source_diagonal;
    FSDolbyVisionTrimMetadata trim;
    FSDolbyVisionReshapeComp comp[FS_HDR_COMPONENT_COUNT];
    float nonlinear_matrix[9];
    float nonlinear_offset[3];
    float linear_matrix[9];
} FSDolbyVisionRenderParams;

typedef struct FSHDRFrameInfo {
    int valid;
    int content_type;
    int decode_path;
    int primaries;
    int transfer;
    int matrix;
    int full_range;
    float mastering_min_nits;
    float mastering_max_nits;
    float max_cll;
    float max_fall;
    FSDolbyVisionRenderParams dolby_vision;
} FSHDRFrameInfo;

#endif
