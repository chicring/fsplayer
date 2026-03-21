/*
* ff_record.h
*
* Copyright (c) 2025 debugly <qianlongxu@gmail.com>
*
* This file is part of FSPlayer.
*
* FSPlayer is free software; you can redistribute it and/or
* modify it under the terms of the GNU Lesser General Public
* License as published by the Free Software Foundation; either
* version 3 of the License, or (at your option) any later version.
*
* FSPlayer is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* Lesser General Public License for more details.
*
* You should have received a copy of the GNU Lesser General Public
* License along with FSPlayer; if not, write to the Free Software
* Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
*/

#include "ff_muxer.h"
#include "ff_ffplay_def.h"
#include "ff_packet_list.h"
#include "libavutil/audio_fifo.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

typedef struct FSMuxer {
    const AVFormatContext *ifmt_ctx;
    AVFormatContext *ofmt_ctx;
    SDL_Thread *write_tid;
    SDL_Thread _write_tid;
    PacketQueue packetq;
    int has_key_video_frame;
    
    int is_audio_first;
    int is_video_first;
    int64_t audio_start_pts;
    int64_t video_start_pts;
} FSMuxer;

static int fs_stream_probe_dovi_conf(
    const AVStream *stream,
    int *stream_side_data_hit,
    int *codecpar_side_data_hit,
    int *metadata_hint_hit
);
static int fs_stream_has_dovi_conf(const AVStream *stream);
static int fs_stream_has_dovi_metadata_hint(const AVStream *stream);

typedef struct FSAudioTranscodeContext {
    int enabled;
    int in_stream_index;
    int out_stream_index;
    int64_t next_pts;
    AVCodecContext *decoder;
    AVCodecContext *encoder;
    SwrContext *swr;
    AVAudioFifo *fifo;
    AVFrame *decode_frame;
} FSAudioTranscodeContext;

typedef struct FSTransmuxInterruptContext {
    const atomic_int *cancel_flag;
} FSTransmuxInterruptContext;

static int fs_transmux_interrupt_cb(void *opaque)
{
    FSTransmuxInterruptContext *context = (FSTransmuxInterruptContext *)opaque;
    if (!context || !context->cancel_flag) {
        return 0;
    }
    return atomic_load(context->cancel_flag) ? 1 : 0;
}

static int fs_video_codec_priority(enum AVCodecID codec_id)
{
    switch (codec_id) {
        case AV_CODEC_ID_HEVC:
            return 600;
        case AV_CODEC_ID_H264:
            return 520;
#ifdef AV_CODEC_ID_AV1
        case AV_CODEC_ID_AV1:
            return 460;
#endif
        default:
            return 300;
    }
}

static int fs_pick_video_stream(const AVFormatContext *ifmt_ctx)
{
    if (!ifmt_ctx) {
        return -1;
    }
    int fallback_video = -1;
    int best_video = -1;
    int best_score = INT_MIN;
    for (unsigned int i = 0; i < ifmt_ctx->nb_streams; i++) {
        const AVStream *stream = ifmt_ctx->streams[i];
        if (!stream || !stream->codecpar || stream->codecpar->codec_type != AVMEDIA_TYPE_VIDEO) {
            continue;
        }
        if (fallback_video < 0) {
            fallback_video = (int)i;
        }
        if (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) {
            continue;
        }
        int score = fs_video_codec_priority(stream->codecpar->codec_id);
        if (stream->disposition & AV_DISPOSITION_DEFAULT) {
            score += 40;
        }
        if (fs_stream_has_dovi_conf(stream)) {
            score += 120;
        }
        if (stream->codecpar->color_primaries == AVCOL_PRI_BT2020) {
            score += 20;
        }
        if (stream->codecpar->color_trc == AVCOL_TRC_SMPTE2084) {
            score += 20;
        }
        if (stream->codecpar->width > 0 && stream->codecpar->height > 0) {
            const int pixels = stream->codecpar->width * stream->codecpar->height;
            if (pixels >= 3840 * 2160) {
                score += 25;
            } else if (pixels >= 1920 * 1080) {
                score += 12;
            }
        }
        score -= (int)i;
        if (score > best_score) {
            best_score = score;
            best_video = (int)i;
        }
    }
    if (best_video >= 0) {
        return best_video;
    }
    return fallback_video;
}

static int fs_stream_has_dovi_metadata_hint(const AVStream *stream)
{
    if (!stream || !stream->metadata) {
        return 0;
    }
    const AVDictionaryEntry *tag = NULL;
    while ((tag = av_dict_get(stream->metadata, "", tag, AV_DICT_IGNORE_SUFFIX))) {
        const char *key = tag->key ? tag->key : "";
        const char *value = tag->value ? tag->value : "";
        if (strcasestr(key, "dovi") || strcasestr(key, "dolby") ||
            strcasestr(value, "dovi") || strcasestr(value, "dolby vision")) {
            return 1;
        }
    }
    return 0;
}

static int fs_stream_probe_dovi_conf(
    const AVStream *stream,
    int *stream_side_data_hit,
    int *codecpar_side_data_hit,
    int *metadata_hint_hit
)
{
    int stream_hit = 0;
    int codecpar_hit = 0;
    int metadata_hit = fs_stream_has_dovi_metadata_hint(stream);
#ifdef AV_PKT_DATA_DOVI_CONF
    int side_data_size = 0;
    if (!stream) {
        if (stream_side_data_hit) {
            *stream_side_data_hit = 0;
        }
        if (codecpar_side_data_hit) {
            *codecpar_side_data_hit = 0;
        }
        if (metadata_hint_hit) {
            *metadata_hint_hit = 0;
        }
        return 0;
    }
    {
        const uint8_t *side_data = av_stream_get_side_data((AVStream *)stream, AV_PKT_DATA_DOVI_CONF, &side_data_size);
        if (side_data && side_data_size > 0) {
            stream_hit = 1;
        }
    }
    if (stream->codecpar && stream->codecpar->coded_side_data && stream->codecpar->nb_coded_side_data > 0) {
        for (int i = 0; i < stream->codecpar->nb_coded_side_data; i++) {
            const AVPacketSideData *entry = &stream->codecpar->coded_side_data[i];
            if (entry->type == AV_PKT_DATA_DOVI_CONF && entry->data && entry->size > 0) {
                codecpar_hit = 1;
                break;
            }
        }
    }
#else
    if (!stream) {
        if (stream_side_data_hit) {
            *stream_side_data_hit = 0;
        }
        if (codecpar_side_data_hit) {
            *codecpar_side_data_hit = 0;
        }
        if (metadata_hint_hit) {
            *metadata_hint_hit = 0;
        }
        return 0;
    }
#endif
    if (stream_side_data_hit) {
        *stream_side_data_hit = stream_hit;
    }
    if (codecpar_side_data_hit) {
        *codecpar_side_data_hit = codecpar_hit;
    }
    if (metadata_hint_hit) {
        *metadata_hint_hit = metadata_hit;
    }
    return stream_hit || codecpar_hit;
}

static int fs_stream_has_dovi_conf(const AVStream *stream)
{
    return fs_stream_probe_dovi_conf(stream, NULL, NULL, NULL);
}

static void fs_copy_stream_side_data(const AVStream *in_stream, AVStream *out_stream)
{
    if (!in_stream || !out_stream) {
        return;
    }
#ifdef AV_PKT_DATA_DOVI_CONF
    {
        int side_data_size = 0;
        const uint8_t *src = av_stream_get_side_data((AVStream *)in_stream, AV_PKT_DATA_DOVI_CONF, &side_data_size);
        if ((!src || side_data_size <= 0) && in_stream->codecpar &&
            in_stream->codecpar->coded_side_data && in_stream->codecpar->nb_coded_side_data > 0) {
            for (int i = 0; i < in_stream->codecpar->nb_coded_side_data; i++) {
                const AVPacketSideData *entry = &in_stream->codecpar->coded_side_data[i];
                if (entry->type == AV_PKT_DATA_DOVI_CONF && entry->data && entry->size > 0) {
                    src = entry->data;
                    side_data_size = entry->size;
                    break;
                }
            }
        }
        if (src && side_data_size > 0) {
            uint8_t *dst = av_stream_new_side_data(out_stream, AV_PKT_DATA_DOVI_CONF, side_data_size);
            if (dst) {
                memcpy(dst, src, (size_t)side_data_size);
            }
        }
    }
#endif
#ifdef AV_PKT_DATA_MASTERING_DISPLAY_METADATA
    {
        int side_data_size = 0;
        const uint8_t *src = av_stream_get_side_data((AVStream *)in_stream, AV_PKT_DATA_MASTERING_DISPLAY_METADATA, &side_data_size);
        if ((!src || side_data_size <= 0) && in_stream->codecpar &&
            in_stream->codecpar->coded_side_data && in_stream->codecpar->nb_coded_side_data > 0) {
            for (int i = 0; i < in_stream->codecpar->nb_coded_side_data; i++) {
                const AVPacketSideData *entry = &in_stream->codecpar->coded_side_data[i];
                if (entry->type == AV_PKT_DATA_MASTERING_DISPLAY_METADATA && entry->data && entry->size > 0) {
                    src = entry->data;
                    side_data_size = entry->size;
                    break;
                }
            }
        }
        if (src && side_data_size > 0) {
            uint8_t *dst = av_stream_new_side_data(out_stream, AV_PKT_DATA_MASTERING_DISPLAY_METADATA, side_data_size);
            if (dst) {
                memcpy(dst, src, (size_t)side_data_size);
            }
        }
    }
#endif
#ifdef AV_PKT_DATA_CONTENT_LIGHT_LEVEL
    {
        int side_data_size = 0;
        const uint8_t *src = av_stream_get_side_data((AVStream *)in_stream, AV_PKT_DATA_CONTENT_LIGHT_LEVEL, &side_data_size);
        if ((!src || side_data_size <= 0) && in_stream->codecpar &&
            in_stream->codecpar->coded_side_data && in_stream->codecpar->nb_coded_side_data > 0) {
            for (int i = 0; i < in_stream->codecpar->nb_coded_side_data; i++) {
                const AVPacketSideData *entry = &in_stream->codecpar->coded_side_data[i];
                if (entry->type == AV_PKT_DATA_CONTENT_LIGHT_LEVEL && entry->data && entry->size > 0) {
                    src = entry->data;
                    side_data_size = entry->size;
                    break;
                }
            }
        }
        if (src && side_data_size > 0) {
            uint8_t *dst = av_stream_new_side_data(out_stream, AV_PKT_DATA_CONTENT_LIGHT_LEVEL, side_data_size);
            if (dst) {
                memcpy(dst, src, (size_t)side_data_size);
            }
        }
    }
#endif
}

static int fs_apply_hdr_color_fallback(AVCodecParameters *codecpar)
{
    int changed = 0;
    if (!codecpar) {
        return 0;
    }
    if (codecpar->color_primaries == AVCOL_PRI_UNSPECIFIED) {
        codecpar->color_primaries = AVCOL_PRI_BT2020;
        changed = 1;
    }
    if (codecpar->color_trc == AVCOL_TRC_UNSPECIFIED) {
        codecpar->color_trc = AVCOL_TRC_SMPTE2084;
        changed = 1;
    }
    if (codecpar->color_space == AVCOL_SPC_UNSPECIFIED) {
        codecpar->color_space = AVCOL_SPC_BT2020_NCL;
        changed = 1;
    }
    if (codecpar->color_range == AVCOL_RANGE_UNSPECIFIED) {
        codecpar->color_range = AVCOL_RANGE_MPEG;
        changed = 1;
    }
    return changed;
}

static int fs_contains_ignore_case(const char *text, const char *keyword)
{
    if (!text || !keyword || !*keyword) {
        return 0;
    }
    return strcasestr(text, keyword) != NULL;
}

static int fs_is_commentary_like(const char *text)
{
    return fs_contains_ignore_case(text, "commentary") ||
           fs_contains_ignore_case(text, "description") ||
           fs_contains_ignore_case(text, "narration");
}

static int fs_audio_codec_priority(enum AVCodecID codec_id)
{
    switch (codec_id) {
        case AV_CODEC_ID_EAC3:
            return 480;
        case AV_CODEC_ID_AC3:
            return 500;
        case AV_CODEC_ID_AAC:
            return 520;
#ifdef AV_CODEC_ID_AAC_LATM
        case AV_CODEC_ID_AAC_LATM:
            return 520;
#endif
        default:
            // HLS fMP4 + AVPlayer bridge: prefer codecs that are consistently
            // playable in this path; others should go through AAC fallback.
            return 0;
    }
}

static int fs_pick_audio_stream(const AVFormatContext *ifmt_ctx)
{
    if (!ifmt_ctx) {
        return -1;
    }
    int fallback_audio = -1;
    int best_audio = -1;
    int best_score = INT_MIN;

    for (unsigned int i = 0; i < ifmt_ctx->nb_streams; i++) {
        const AVStream *stream = ifmt_ctx->streams[i];
        if (!stream || !stream->codecpar || stream->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
            continue;
        }
        if (fallback_audio < 0) {
            fallback_audio = (int)i;
        }

        AVDictionaryEntry *title = av_dict_get(stream->metadata, "title", NULL, AV_DICT_IGNORE_SUFFIX);
        AVDictionaryEntry *handler = av_dict_get(stream->metadata, "handler_name", NULL, AV_DICT_IGNORE_SUFFIX);
        const char *title_value = title ? title->value : NULL;
        const char *handler_value = handler ? handler->value : NULL;

        int score = fs_audio_codec_priority(stream->codecpar->codec_id);
        if (score == 0) {
            // TrueHD / DTS / FLAC in HLS fMP4 often yields silent playback on AVPlayer.
            score = -200;
        }

        if (stream->codecpar->codec_id == AV_CODEC_ID_EAC3 &&
            (fs_contains_ignore_case(title_value, "joc") || fs_contains_ignore_case(title_value, "atmos") ||
             fs_contains_ignore_case(handler_value, "joc") || fs_contains_ignore_case(handler_value, "atmos"))) {
            score += 260;
        }

        if (fs_is_commentary_like(title_value) || fs_is_commentary_like(handler_value)) {
            score -= 120;
        }

        // Prefer earlier streams when scores tie.
        score -= (int)i;
        if (score > best_score) {
            best_score = score;
            best_audio = (int)i;
        }
    }

    if (best_audio >= 0 && best_score > -200) {
        return best_audio;
    }
    if (fallback_audio >= 0) {
        const AVStream *fallback_stream = ifmt_ctx->streams[fallback_audio];
        if (fallback_stream && fallback_stream->codecpar &&
            fs_audio_codec_priority(fallback_stream->codecpar->codec_id) > 0) {
            return fallback_audio;
        }
    }
    return -1;
}

static int fs_count_audio_streams(const AVFormatContext *ifmt_ctx)
{
    if (!ifmt_ctx) {
        return 0;
    }
    int count = 0;
    for (unsigned int i = 0; i < ifmt_ctx->nb_streams; i++) {
        const AVStream *stream = ifmt_ctx->streams[i];
        if (!stream || !stream->codecpar) {
            continue;
        }
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            count++;
        }
    }
    return count;
}

static int fs_pick_any_audio_stream(const AVFormatContext *ifmt_ctx)
{
    if (!ifmt_ctx) {
        return -1;
    }
    int fallback_audio = -1;
    int best_audio = -1;
    int best_score = INT_MIN;

    for (unsigned int i = 0; i < ifmt_ctx->nb_streams; i++) {
        const AVStream *stream = ifmt_ctx->streams[i];
        if (!stream || !stream->codecpar || stream->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
            continue;
        }
        if (fallback_audio < 0) {
            fallback_audio = (int)i;
        }

        AVDictionaryEntry *title = av_dict_get(stream->metadata, "title", NULL, AV_DICT_IGNORE_SUFFIX);
        AVDictionaryEntry *handler = av_dict_get(stream->metadata, "handler_name", NULL, AV_DICT_IGNORE_SUFFIX);
        const char *title_value = title ? title->value : NULL;
        const char *handler_value = handler ? handler->value : NULL;

        int score = fs_audio_codec_priority(stream->codecpar->codec_id);
        if (score == 0) {
            // Unsupported codecs still remain candidates for AAC fallback.
            score = 360;
        }
        if (stream->disposition & AV_DISPOSITION_DEFAULT) {
            score += 40;
        }
        if (stream->codecpar->codec_id == AV_CODEC_ID_EAC3 &&
            (fs_contains_ignore_case(title_value, "joc") || fs_contains_ignore_case(title_value, "atmos") ||
             fs_contains_ignore_case(handler_value, "joc") || fs_contains_ignore_case(handler_value, "atmos"))) {
            score += 260;
        }
        if (fs_is_commentary_like(title_value) || fs_is_commentary_like(handler_value)) {
            score -= 120;
        }
        score -= (int)i;

        if (score > best_score) {
            best_score = score;
            best_audio = (int)i;
        }
    }

    return best_audio >= 0 ? best_audio : fallback_audio;
}

static int fs_select_encoder_sample_rate(const AVCodec *encoder, int preferred_sample_rate)
{
    int fallback = preferred_sample_rate > 0 ? preferred_sample_rate : 48000;
    if (!encoder || !encoder->supported_samplerates || encoder->supported_samplerates[0] <= 0) {
        return fallback;
    }

    int best = encoder->supported_samplerates[0];
    int best_delta = abs(best - fallback);
    for (const int *rate = encoder->supported_samplerates; *rate; rate++) {
        int delta = abs(*rate - fallback);
        if (delta < best_delta) {
            best = *rate;
            best_delta = delta;
        }
    }
    return best;
}

static enum AVSampleFormat fs_select_encoder_sample_fmt(const AVCodec *encoder)
{
    if (encoder && encoder->sample_fmts && encoder->sample_fmts[0] != AV_SAMPLE_FMT_NONE) {
        return encoder->sample_fmts[0];
    }
    return AV_SAMPLE_FMT_FLTP;
}

static void fs_release_audio_transcode_context(FSAudioTranscodeContext *ctx)
{
    if (!ctx) {
        return;
    }
    if (ctx->decode_frame) {
        av_frame_free(&ctx->decode_frame);
    }
    if (ctx->fifo) {
        av_audio_fifo_free(ctx->fifo);
    }
    if (ctx->swr) {
        swr_free(&ctx->swr);
    }
    if (ctx->decoder) {
        avcodec_free_context(&ctx->decoder);
    }
    if (ctx->encoder) {
        avcodec_free_context(&ctx->encoder);
    }
    memset(ctx, 0, sizeof(*ctx));
    ctx->in_stream_index = -1;
    ctx->out_stream_index = -1;
}

static int fs_init_audio_transcode_context(
    FSAudioTranscodeContext *ctx,
    AVFormatContext *ifmt_ctx,
    AVFormatContext *ofmt_ctx,
    int in_stream_index,
    AVStream *out_stream
)
{
    if (!ctx || !ifmt_ctx || !ofmt_ctx || !out_stream ||
        in_stream_index < 0 || (unsigned int)in_stream_index >= ifmt_ctx->nb_streams) {
        return AVERROR(EINVAL);
    }

    fs_release_audio_transcode_context(ctx);
    const AVStream *in_stream = ifmt_ctx->streams[in_stream_index];
    if (!in_stream || !in_stream->codecpar) {
        return AVERROR(EINVAL);
    }

    const AVCodec *decoder = avcodec_find_decoder(in_stream->codecpar->codec_id);
    const AVCodec *encoder = avcodec_find_encoder(AV_CODEC_ID_AAC);
    if (!decoder || !encoder) {
        return AVERROR_ENCODER_NOT_FOUND;
    }

    ctx->decoder = avcodec_alloc_context3(decoder);
    if (!ctx->decoder) {
        return AVERROR(ENOMEM);
    }
    int ret = avcodec_parameters_to_context(ctx->decoder, in_stream->codecpar);
    if (ret < 0) {
        return ret;
    }
    ctx->decoder->pkt_timebase = in_stream->time_base;
    ret = avcodec_open2(ctx->decoder, decoder, NULL);
    if (ret < 0) {
        return ret;
    }

    ctx->encoder = avcodec_alloc_context3(encoder);
    if (!ctx->encoder) {
        return AVERROR(ENOMEM);
    }
    int preferred_sample_rate = in_stream->codecpar->sample_rate > 0
        ? in_stream->codecpar->sample_rate
        : (ctx->decoder->sample_rate > 0 ? ctx->decoder->sample_rate : 48000);
    int output_sample_rate = fs_select_encoder_sample_rate(encoder, preferred_sample_rate);

    int input_channels = in_stream->codecpar->ch_layout.nb_channels > 0
        ? in_stream->codecpar->ch_layout.nb_channels
        : (ctx->decoder->ch_layout.nb_channels > 0 ? ctx->decoder->ch_layout.nb_channels : 2);
    int output_channels = input_channels <= 1 ? 1 : 2;

    av_channel_layout_default(&ctx->encoder->ch_layout, output_channels);
    ctx->encoder->sample_rate = output_sample_rate;
    ctx->encoder->sample_fmt = fs_select_encoder_sample_fmt(encoder);
    ctx->encoder->time_base = (AVRational){1, output_sample_rate};
    ctx->encoder->bit_rate = output_channels > 1 ? 192000 : 128000;
    if (ofmt_ctx->oformat->flags & AVFMT_GLOBALHEADER) {
        ctx->encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }
    ret = avcodec_open2(ctx->encoder, encoder, NULL);
    if (ret < 0) {
        return ret;
    }

    ret = avcodec_parameters_from_context(out_stream->codecpar, ctx->encoder);
    if (ret < 0) {
        return ret;
    }
    out_stream->codecpar->codec_tag = 0;
    out_stream->time_base = ctx->encoder->time_base;

    int initial_capacity = FFMAX(ctx->encoder->frame_size > 0 ? ctx->encoder->frame_size * 8 : 4096, 2048);
    ctx->fifo = av_audio_fifo_alloc(ctx->encoder->sample_fmt, ctx->encoder->ch_layout.nb_channels, initial_capacity);
    if (!ctx->fifo) {
        return AVERROR(ENOMEM);
    }
    ctx->decode_frame = av_frame_alloc();
    if (!ctx->decode_frame) {
        return AVERROR(ENOMEM);
    }

    ctx->enabled = 1;
    ctx->in_stream_index = in_stream_index;
    ctx->out_stream_index = out_stream->index;
    ctx->next_pts = 0;
    return 0;
}

static int fs_ensure_audio_swr(FSAudioTranscodeContext *ctx, const AVFrame *decoded_frame)
{
    if (!ctx || !ctx->enabled || !ctx->encoder || !decoded_frame) {
        return AVERROR(EINVAL);
    }
    if (ctx->swr) {
        return 0;
    }

    AVChannelLayout source_layout = {0};
    int source_sample_rate = decoded_frame->sample_rate > 0
        ? decoded_frame->sample_rate
        : (ctx->decoder->sample_rate > 0 ? ctx->decoder->sample_rate : ctx->encoder->sample_rate);
    enum AVSampleFormat source_sample_fmt = decoded_frame->format != AV_SAMPLE_FMT_NONE
        ? (enum AVSampleFormat)decoded_frame->format
        : (ctx->decoder->sample_fmt != AV_SAMPLE_FMT_NONE ? ctx->decoder->sample_fmt : AV_SAMPLE_FMT_FLTP);

    if (decoded_frame->ch_layout.nb_channels > 0) {
        if (av_channel_layout_copy(&source_layout, &decoded_frame->ch_layout) < 0) {
            return AVERROR(EINVAL);
        }
    } else if (ctx->decoder->ch_layout.nb_channels > 0) {
        if (av_channel_layout_copy(&source_layout, &ctx->decoder->ch_layout) < 0) {
            return AVERROR(EINVAL);
        }
    } else {
        av_channel_layout_default(&source_layout, ctx->encoder->ch_layout.nb_channels > 0 ? ctx->encoder->ch_layout.nb_channels : 2);
    }

    int ret = swr_alloc_set_opts2(
        &ctx->swr,
        &ctx->encoder->ch_layout,
        ctx->encoder->sample_fmt,
        ctx->encoder->sample_rate,
        &source_layout,
        source_sample_fmt,
        source_sample_rate,
        0,
        NULL
    );
    av_channel_layout_uninit(&source_layout);
    if (ret < 0) {
        return ret;
    }
    return swr_init(ctx->swr);
}

static int fs_drain_audio_encoder_packets(FSAudioTranscodeContext *ctx, AVFormatContext *ofmt_ctx)
{
    if (!ctx || !ctx->enabled || !ctx->encoder || !ofmt_ctx ||
        ctx->out_stream_index < 0 || (unsigned int)ctx->out_stream_index >= ofmt_ctx->nb_streams) {
        return AVERROR(EINVAL);
    }

    AVPacket packet;
    av_init_packet(&packet);
    while (1) {
        int ret = avcodec_receive_packet(ctx->encoder, &packet);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            return 0;
        }
        if (ret < 0) {
            return ret;
        }

        packet.stream_index = ctx->out_stream_index;
        packet.pos = -1;
        if (packet.duration <= 0) {
            packet.duration = 1;
        }
        av_packet_rescale_ts(
            &packet,
            ctx->encoder->time_base,
            ofmt_ctx->streams[ctx->out_stream_index]->time_base
        );
        ret = av_interleaved_write_frame(ofmt_ctx, &packet);
        av_packet_unref(&packet);
        if (ret < 0) {
            return ret;
        }
    }
}

static int fs_encode_audio_fifo_frame(
    FSAudioTranscodeContext *ctx,
    AVFormatContext *ofmt_ctx,
    int target_samples,
    int pad_silence
)
{
    if (!ctx || !ctx->enabled || !ctx->encoder || !ctx->fifo || target_samples <= 0) {
        return AVERROR(EINVAL);
    }

    AVFrame *frame = av_frame_alloc();
    if (!frame) {
        return AVERROR(ENOMEM);
    }

    frame->format = ctx->encoder->sample_fmt;
    frame->sample_rate = ctx->encoder->sample_rate;
    if (av_channel_layout_copy(&frame->ch_layout, &ctx->encoder->ch_layout) < 0) {
        av_frame_free(&frame);
        return AVERROR(EINVAL);
    }
    frame->nb_samples = target_samples;
    if (av_frame_get_buffer(frame, 0) < 0) {
        av_frame_free(&frame);
        return AVERROR(ENOMEM);
    }

    int available = av_audio_fifo_size(ctx->fifo);
    int read_samples = FFMIN(target_samples, available);
    if (read_samples > 0) {
        int read_count = av_audio_fifo_read(ctx->fifo, (void **)frame->data, read_samples);
        if (read_count != read_samples) {
            av_frame_free(&frame);
            return AVERROR(EIO);
        }
    }

    if (read_samples < target_samples) {
        if (!pad_silence) {
            av_frame_free(&frame);
            return AVERROR(EAGAIN);
        }
        av_samples_set_silence(
            frame->data,
            read_samples,
            target_samples - read_samples,
            ctx->encoder->ch_layout.nb_channels,
            ctx->encoder->sample_fmt
        );
    }

    frame->pts = ctx->next_pts;
    ctx->next_pts += target_samples;

    int ret = avcodec_send_frame(ctx->encoder, frame);
    av_frame_free(&frame);
    if (ret < 0) {
        return ret;
    }
    return fs_drain_audio_encoder_packets(ctx, ofmt_ctx);
}

static int fs_queue_converted_audio(FSAudioTranscodeContext *ctx, AVFrame *converted_frame, AVFormatContext *ofmt_ctx)
{
    if (!ctx || !ctx->enabled || !ctx->fifo || !converted_frame || converted_frame->nb_samples <= 0) {
        return AVERROR(EINVAL);
    }

    int current_size = av_audio_fifo_size(ctx->fifo);
    if (av_audio_fifo_realloc(ctx->fifo, current_size + converted_frame->nb_samples) < 0) {
        return AVERROR(ENOMEM);
    }
    int write_count = av_audio_fifo_write(ctx->fifo, (void **)converted_frame->data, converted_frame->nb_samples);
    if (write_count != converted_frame->nb_samples) {
        return AVERROR(EIO);
    }

    int frame_size = ctx->encoder->frame_size;
    if (frame_size <= 0) {
        while (av_audio_fifo_size(ctx->fifo) > 0) {
            int chunk = FFMIN(av_audio_fifo_size(ctx->fifo), 2048);
            int ret = fs_encode_audio_fifo_frame(ctx, ofmt_ctx, chunk, 0);
            if (ret < 0 && ret != AVERROR(EAGAIN)) {
                return ret;
            }
        }
        return 0;
    }

    while (av_audio_fifo_size(ctx->fifo) >= frame_size) {
        int ret = fs_encode_audio_fifo_frame(ctx, ofmt_ctx, frame_size, 0);
        if (ret < 0) {
            return ret;
        }
    }
    return 0;
}

static int fs_convert_and_queue_audio_frame(
    FSAudioTranscodeContext *ctx,
    const AVFrame *decoded_frame,
    AVFormatContext *ofmt_ctx
)
{
    int ret = fs_ensure_audio_swr(ctx, decoded_frame);
    if (ret < 0) {
        return ret;
    }

    int source_sample_rate = decoded_frame->sample_rate > 0
        ? decoded_frame->sample_rate
        : (ctx->decoder->sample_rate > 0 ? ctx->decoder->sample_rate : ctx->encoder->sample_rate);
    int dst_nb_samples = av_rescale_rnd(
        swr_get_delay(ctx->swr, source_sample_rate) + decoded_frame->nb_samples,
        ctx->encoder->sample_rate,
        source_sample_rate,
        AV_ROUND_UP
    );
    if (dst_nb_samples <= 0) {
        return 0;
    }

    AVFrame *converted = av_frame_alloc();
    if (!converted) {
        return AVERROR(ENOMEM);
    }
    converted->format = ctx->encoder->sample_fmt;
    converted->sample_rate = ctx->encoder->sample_rate;
    if (av_channel_layout_copy(&converted->ch_layout, &ctx->encoder->ch_layout) < 0) {
        av_frame_free(&converted);
        return AVERROR(EINVAL);
    }
    converted->nb_samples = dst_nb_samples;
    if (av_frame_get_buffer(converted, 0) < 0) {
        av_frame_free(&converted);
        return AVERROR(ENOMEM);
    }

    int converted_samples = swr_convert(
        ctx->swr,
        converted->data,
        dst_nb_samples,
        (const uint8_t **)decoded_frame->data,
        decoded_frame->nb_samples
    );
    if (converted_samples < 0) {
        av_frame_free(&converted);
        return converted_samples;
    }
    converted->nb_samples = converted_samples;

    ret = 0;
    if (converted_samples > 0) {
        ret = fs_queue_converted_audio(ctx, converted, ofmt_ctx);
    }
    av_frame_free(&converted);
    return ret;
}

static int fs_process_audio_packet(
    FSAudioTranscodeContext *ctx,
    AVPacket *packet,
    AVFormatContext *ofmt_ctx
)
{
    if (!ctx || !ctx->enabled || !ctx->decoder || !ctx->decode_frame || !packet) {
        return AVERROR(EINVAL);
    }

    int ret = avcodec_send_packet(ctx->decoder, packet);
    if (ret == AVERROR(EAGAIN)) {
        while ((ret = avcodec_receive_frame(ctx->decoder, ctx->decode_frame)) >= 0) {
            int convert_ret = fs_convert_and_queue_audio_frame(ctx, ctx->decode_frame, ofmt_ctx);
            av_frame_unref(ctx->decode_frame);
            if (convert_ret < 0) {
                return convert_ret;
            }
        }
        if (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) {
            return ret;
        }
        ret = avcodec_send_packet(ctx->decoder, packet);
    }
    if (ret < 0) {
        return ret;
    }

    while ((ret = avcodec_receive_frame(ctx->decoder, ctx->decode_frame)) >= 0) {
        int convert_ret = fs_convert_and_queue_audio_frame(ctx, ctx->decode_frame, ofmt_ctx);
        av_frame_unref(ctx->decode_frame);
        if (convert_ret < 0) {
            return convert_ret;
        }
    }
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
        return 0;
    }
    return ret;
}

static int fs_flush_audio_transcode(FSAudioTranscodeContext *ctx, AVFormatContext *ofmt_ctx)
{
    if (!ctx || !ctx->enabled || !ctx->decoder || !ctx->encoder || !ctx->fifo) {
        return 0;
    }

    int ret = avcodec_send_packet(ctx->decoder, NULL);
    if (ret < 0 && ret != AVERROR_EOF && ret != AVERROR(EAGAIN)) {
        return ret;
    }
    while ((ret = avcodec_receive_frame(ctx->decoder, ctx->decode_frame)) >= 0) {
        int convert_ret = fs_convert_and_queue_audio_frame(ctx, ctx->decode_frame, ofmt_ctx);
        av_frame_unref(ctx->decode_frame);
        if (convert_ret < 0) {
            return convert_ret;
        }
    }
    if (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) {
        return ret;
    }

    if (ctx->swr) {
        int source_sample_rate = ctx->decoder->sample_rate > 0 ? ctx->decoder->sample_rate : ctx->encoder->sample_rate;
        int delay = swr_get_delay(ctx->swr, source_sample_rate);
        if (delay > 0) {
            int dst_nb_samples = av_rescale_rnd(delay, ctx->encoder->sample_rate, source_sample_rate, AV_ROUND_UP);
            if (dst_nb_samples > 0) {
                AVFrame *flush_frame = av_frame_alloc();
                if (!flush_frame) {
                    return AVERROR(ENOMEM);
                }
                flush_frame->format = ctx->encoder->sample_fmt;
                flush_frame->sample_rate = ctx->encoder->sample_rate;
                if (av_channel_layout_copy(&flush_frame->ch_layout, &ctx->encoder->ch_layout) < 0) {
                    av_frame_free(&flush_frame);
                    return AVERROR(EINVAL);
                }
                flush_frame->nb_samples = dst_nb_samples;
                if (av_frame_get_buffer(flush_frame, 0) < 0) {
                    av_frame_free(&flush_frame);
                    return AVERROR(ENOMEM);
                }
                int converted = swr_convert(ctx->swr, flush_frame->data, dst_nb_samples, NULL, 0);
                if (converted < 0) {
                    av_frame_free(&flush_frame);
                    return converted;
                }
                flush_frame->nb_samples = converted;
                if (converted > 0) {
                    ret = fs_queue_converted_audio(ctx, flush_frame, ofmt_ctx);
                } else {
                    ret = 0;
                }
                av_frame_free(&flush_frame);
                if (ret < 0) {
                    return ret;
                }
            }
        }
    }

    int frame_size = ctx->encoder->frame_size;
    if (frame_size <= 0) {
        while (av_audio_fifo_size(ctx->fifo) > 0) {
            int chunk = FFMIN(av_audio_fifo_size(ctx->fifo), 2048);
            ret = fs_encode_audio_fifo_frame(ctx, ofmt_ctx, chunk, 0);
            if (ret < 0 && ret != AVERROR(EAGAIN)) {
                return ret;
            }
        }
    } else {
        while (av_audio_fifo_size(ctx->fifo) >= frame_size) {
            ret = fs_encode_audio_fifo_frame(ctx, ofmt_ctx, frame_size, 0);
            if (ret < 0) {
                return ret;
            }
        }
        if (av_audio_fifo_size(ctx->fifo) > 0) {
            ret = fs_encode_audio_fifo_frame(ctx, ofmt_ctx, frame_size, 1);
            if (ret < 0) {
                return ret;
            }
        }
    }

    ret = avcodec_send_frame(ctx->encoder, NULL);
    if (ret < 0 && ret != AVERROR_EOF) {
        return ret;
    }
    return fs_drain_audio_encoder_packets(ctx, ofmt_ctx);
}

int ff_transmux_to_hls_fmp4(
    const char *input_url,
    const char *output_directory,
    const char *headers,
    int64_t start_position_ms,
    int segment_duration_sec,
    int timeout_sec,
    int prefer_dolby_vision,
    const atomic_int *cancel_flag
)
{
    int ret = 0;
    AVFormatContext *ifmt_ctx = NULL;
    AVFormatContext *ofmt_ctx = NULL;
    const AVOutputFormat *hls_output_format = NULL;
    AVDictionary *in_opts = NULL;
    AVDictionary *out_opts = NULL;
    int *stream_mapping = NULL;
    int video_stream = -1;
    int audio_stream = -1;
    int any_audio_stream = -1;
    int audio_transcode_to_aac = 0;
    int selected_video_has_dovi = 0;
    int selected_video_dovi_stream_sd = 0;
    int selected_video_dovi_codecpar_sd = 0;
    int selected_video_dovi_metadata_hint = 0;
    int selected_output_has_dovi = 0;
    int selected_output_dovi_stream_sd = 0;
    int selected_output_dovi_codecpar_sd = 0;
    int selected_output_dovi_metadata_hint = 0;
    int video_has_key_written = 0;
    int64_t *last_dts_per_stream = NULL;
    int synthesized_ts_count = 0;
    int dropped_no_ts_count = 0;
    int64_t normalized_start_position_ms = 0;
    FSAudioTranscodeContext audio_transcode = {0};
    FSTransmuxInterruptContext interrupt_context = {0};
    audio_transcode.in_stream_index = -1;
    audio_transcode.out_stream_index = -1;

    if (!input_url || !*input_url || !output_directory || !*output_directory) {
        return -1;
    }
    normalized_start_position_ms = start_position_ms > 0 ? start_position_ms : 0;

    if (headers && *headers) {
        av_dict_set(&in_opts, "headers", headers, 0);
    }
    av_dict_set(&in_opts, "fflags", "+genpts", 0);
    // Ask demux/parsers to export codec side-data (includes DV config on supported inputs).
    // Equivalent to CLI: -export_side_data +venc_params
    av_dict_set(&in_opts, "export_side_data", "venc_params", 0);
    av_dict_set(&in_opts, "probesize", "20000000", 0);
    av_dict_set(&in_opts, "analyzeduration", "30000000", 0);
    av_dict_set(&in_opts, "reconnect", "1", 0);
    av_dict_set(&in_opts, "reconnect_streamed", "1", 0);
    av_dict_set(&in_opts, "reconnect_at_eof", "1", 0);
    av_dict_set(&in_opts, "reconnect_delay_max", "2", 0);
    if (timeout_sec > 0) {
        int io_timeout_sec = timeout_sec > 10 ? 10 : timeout_sec;
        char timeout_buf[32] = {0};
        snprintf(timeout_buf, sizeof(timeout_buf), "%lld", (long long)io_timeout_sec * 1000000LL);
        av_dict_set(&in_opts, "rw_timeout", timeout_buf, 0);
        av_dict_set(&in_opts, "timeout", timeout_buf, 0);
    }

    ifmt_ctx = avformat_alloc_context();
    if (!ifmt_ctx) {
        ret = -18;
        goto end;
    }
    interrupt_context.cancel_flag = cancel_flag;
    ifmt_ctx->interrupt_callback.callback = fs_transmux_interrupt_cb;
    ifmt_ctx->interrupt_callback.opaque = &interrupt_context;
    ret = avformat_open_input(&ifmt_ctx, input_url, NULL, &in_opts);
    av_dict_free(&in_opts);
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "transmux: avformat_open_input failed, ret=%d\n", ret);
        if (ret == AVERROR_EXIT && cancel_flag && atomic_load(cancel_flag)) {
            ret = -22;
        } else {
            ret = -2;
        }
        goto end;
    }
    ret = avformat_find_stream_info(ifmt_ctx, NULL);
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "transmux: avformat_find_stream_info failed, ret=%d\n", ret);
        if (ret == AVERROR_EXIT && cancel_flag && atomic_load(cancel_flag)) {
            ret = -22;
        } else {
            ret = -3;
        }
        goto end;
    }

    if (normalized_start_position_ms > 0) {
        const int64_t target_ts = av_rescale_q(
            normalized_start_position_ms,
            (AVRational){1, 1000},
            AV_TIME_BASE_Q
        );
        ret = avformat_seek_file(
            ifmt_ctx,
            -1,
            INT64_MIN,
            target_ts,
            INT64_MAX,
            AVSEEK_FLAG_BACKWARD
        );
        if (ret < 0) {
            av_log(
                NULL,
                AV_LOG_ERROR,
                "transmux: avformat_seek_file failed, start_position_ms=%lld ret=%d\n",
                (long long)normalized_start_position_ms,
                ret
            );
            ret = -19;
            goto end;
        }
        avformat_flush(ifmt_ctx);
        av_log(
            NULL,
            AV_LOG_INFO,
            "transmux: start seek applied start_position_ms=%lld target_ts=%lld\n",
            (long long)normalized_start_position_ms,
            (long long)target_ts
        );
    }

    video_stream = fs_pick_video_stream(ifmt_ctx);
    audio_stream = fs_pick_audio_stream(ifmt_ctx);
    any_audio_stream = fs_pick_any_audio_stream(ifmt_ctx);
    const int audio_stream_count = fs_count_audio_streams(ifmt_ctx);
    if (video_stream < 0) {
        av_log(NULL, AV_LOG_ERROR, "transmux: no video stream\n");
        ret = -4;
        goto end;
    }
    if (audio_stream_count > 0 && audio_stream < 0) {
        if (any_audio_stream >= 0) {
            audio_stream = any_audio_stream;
            audio_transcode_to_aac = 1;
            av_log(NULL, AV_LOG_WARNING, "transmux: no compatible copy-audio, enable AAC fallback stream=%d total_audio=%d\n", audio_stream, audio_stream_count);
        } else {
            av_log(NULL, AV_LOG_ERROR, "transmux: no avplayer-compatible audio stream (total_audio=%d)\n", audio_stream_count);
            ret = -16;
            goto end;
        }
    }

    char master_playlist_path[PATH_MAX] = {0};
    char segment_filename_pattern[PATH_MAX] = {0};
    snprintf(master_playlist_path, sizeof(master_playlist_path), "%s/master.m3u8", output_directory);
    // Use absolute output path for writer stability on iOS. Relative segment
    // paths can resolve against the process CWD and fail with "Failed to open file".
    // The app proxy rewrites absolute local paths back to relative bridge paths
    // before serving playlists to AVPlayer.
    // snprintf needs escaped '%' here.
    snprintf(segment_filename_pattern, sizeof(segment_filename_pattern), "%s/segment_%%05d.m4s", output_directory);

    hls_output_format = av_guess_format("hls", NULL, NULL);
    if (!hls_output_format) {
        av_log(NULL, AV_LOG_ERROR, "transmux: hls muxer unavailable, rebuild ffmpeg with --enable-muxer=hls\n");
        ret = -14;
        goto end;
    }

    ret = avformat_alloc_output_context2(&ofmt_ctx, hls_output_format, "hls", master_playlist_path);
    if (ret < 0 || !ofmt_ctx) {
        av_log(NULL, AV_LOG_ERROR, "transmux: avformat_alloc_output_context2 failed, ret=%d\n", ret);
        ret = -5;
        goto end;
    }

    stream_mapping = av_mallocz(sizeof(int) * ifmt_ctx->nb_streams);
    if (!stream_mapping) {
        ret = -6;
        goto end;
    }
    for (unsigned int i = 0; i < ifmt_ctx->nb_streams; i++) {
        stream_mapping[i] = -1;
    }

    for (unsigned int i = 0; i < ifmt_ctx->nb_streams; i++) {
        if ((int)i != video_stream && (int)i != audio_stream) {
            continue;
        }
        AVStream *in_stream = ifmt_ctx->streams[i];
        AVStream *out_stream = avformat_new_stream(ofmt_ctx, NULL);
        if (!in_stream || !out_stream) {
            ret = -7;
            goto end;
        }
        if ((int)i == audio_stream && audio_transcode_to_aac) {
            ret = fs_init_audio_transcode_context(
                &audio_transcode,
                ifmt_ctx,
                ofmt_ctx,
                (int)i,
                out_stream
            );
            if (ret < 0) {
                av_log(NULL, AV_LOG_ERROR, "transmux: init AAC fallback failed, ret=%d\n", ret);
                ret = -17;
                goto end;
            }
            stream_mapping[i] = out_stream->index;
            continue;
        }
        ret = avcodec_parameters_copy(out_stream->codecpar, in_stream->codecpar);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "transmux: avcodec_parameters_copy failed, ret=%d\n", ret);
            ret = -8;
            goto end;
        }
        fs_copy_stream_side_data(in_stream, out_stream);
        if ((out_stream->codecpar->codec_id == AV_CODEC_ID_EAC3 ||
             out_stream->codecpar->codec_id == AV_CODEC_ID_AC3) &&
            out_stream->codecpar->frame_size <= 0) {
            out_stream->codecpar->frame_size = 1536;
        }
        if (out_stream->codecpar->codec_id == AV_CODEC_ID_HEVC) {
            int has_dovi_stream_sd = 0;
            int has_dovi_codecpar_sd = 0;
            int has_dovi_metadata_hint = 0;
            const int has_dovi = fs_stream_probe_dovi_conf(
                in_stream,
                &has_dovi_stream_sd,
                &has_dovi_codecpar_sd,
                &has_dovi_metadata_hint
            );
            const int should_use_dolby_tag = has_dovi && prefer_dolby_vision;
            if (prefer_dolby_vision && !has_dovi) {
                if (fs_apply_hdr_color_fallback(out_stream->codecpar)) {
                    av_log(NULL, AV_LOG_WARNING,
                           "transmux: dolby fallback color tags applied (bt2020/pq) meta_hint=%d\n",
                           has_dovi_metadata_hint);
                }
            }
            if (should_use_dolby_tag) {
                out_stream->codecpar->codec_tag = MKTAG('d', 'v', 'h', '1');
            } else {
                out_stream->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
            }
            if ((int)i == video_stream) {
                selected_video_has_dovi = has_dovi;
                selected_video_dovi_stream_sd = has_dovi_stream_sd;
                selected_video_dovi_codecpar_sd = has_dovi_codecpar_sd;
                selected_video_dovi_metadata_hint = has_dovi_metadata_hint;
                selected_output_has_dovi = fs_stream_probe_dovi_conf(
                    out_stream,
                    &selected_output_dovi_stream_sd,
                    &selected_output_dovi_codecpar_sd,
                    &selected_output_dovi_metadata_hint
                );
            }
        } else {
            out_stream->codecpar->codec_tag = 0;
        }
        out_stream->time_base = in_stream->time_base;
        stream_mapping[i] = out_stream->index;
    }

    if (!(ofmt_ctx->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&ofmt_ctx->pb, master_playlist_path, AVIO_FLAG_WRITE);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "transmux: avio_open failed, ret=%d\n", ret);
            ret = -9;
            goto end;
        }
    }

    char hls_time_buf[16] = {0};
    char hls_start_number_buf[32] = {0};
    int normalized_segment_duration_sec = segment_duration_sec > 0 ? segment_duration_sec : 4;
    int64_t normalized_start_number = 0;
    if (normalized_start_position_ms > 0 && normalized_segment_duration_sec > 0) {
        const int64_t segment_duration_ms = (int64_t)normalized_segment_duration_sec * 1000LL;
        normalized_start_number = segment_duration_ms > 0
            ? normalized_start_position_ms / segment_duration_ms
            : 0;
    }
    snprintf(hls_time_buf, sizeof(hls_time_buf), "%d", normalized_segment_duration_sec);
    av_dict_set(&out_opts, "hls_time", hls_time_buf, 0);
    // Use event playlist during transmux so playlist is updated incrementally
    // and bridge startup can begin before the whole source is processed.
    av_dict_set(&out_opts, "hls_playlist_type", "event", 0);
    av_dict_set(&out_opts, "hls_list_size", "0", 0);
    av_dict_set(&out_opts, "hls_segment_type", "fmp4", 0);
    av_dict_set(&out_opts, "hls_flags", "independent_segments+temp_file", 0);
    av_dict_set(&out_opts, "hls_fmp4_init_filename", "init.mp4", 0);
    av_dict_set(&out_opts, "hls_segment_filename", segment_filename_pattern, 0);
    if (normalized_start_number > 0) {
        snprintf(
            hls_start_number_buf,
            sizeof(hls_start_number_buf),
            "%lld",
            (long long)normalized_start_number
        );
        av_dict_set(&out_opts, "start_number", hls_start_number_buf, 0);
        av_log(
            NULL,
            AV_LOG_INFO,
            "transmux: hls start_number=%lld segment_duration_sec=%d\n",
            (long long)normalized_start_number,
            normalized_segment_duration_sec
        );
    }
    av_dict_set(&out_opts, "strict", "unofficial", 0);
    // Keep segment options minimal and valid across ffmpeg variants to avoid
    // "Some of the provided format options are not recognized" on hls muxer.
    av_dict_set(&out_opts, "hls_segment_options", "strict=unofficial", 0);
    av_dict_set(&out_opts, "avoid_negative_ts", "make_non_negative", 0);
    av_dict_set(&out_opts, "max_interleave_delta", "0", 0);
    av_dict_set(&out_opts, "muxdelay", "0", 0);
    av_dict_set(&out_opts, "muxpreload", "0", 0);

    if (video_stream >= 0) {
        AVStream *selected_video = ifmt_ctx->streams[video_stream];
        const char *video_codec_name = selected_video && selected_video->codecpar
            ? avcodec_get_name(selected_video->codecpar->codec_id)
            : "unknown";
        int log_stream_sd = selected_video_dovi_stream_sd;
        int log_codecpar_sd = selected_video_dovi_codecpar_sd;
        int log_metadata_hint = selected_video_dovi_metadata_hint;
        int has_dovi = selected_video_has_dovi;
        if (!selected_video || !selected_video->codecpar) {
            log_stream_sd = 0;
            log_codecpar_sd = 0;
            log_metadata_hint = 0;
            has_dovi = 0;
        } else if (log_stream_sd == 0 && log_codecpar_sd == 0 && log_metadata_hint == 0 && has_dovi == 0) {
            has_dovi = fs_stream_probe_dovi_conf(
                selected_video,
                &log_stream_sd,
                &log_codecpar_sd,
                &log_metadata_hint
            );
        }
        av_log(
            NULL,
            AV_LOG_INFO,
            "transmux: selected video stream=%d codec=%s dovi=%d prefer_dolby=%d tag=%s color_range=%d primaries=%d trc=%d colorspace=%d dovi_stream_sd=%d dovi_codecpar_sd=%d dovi_meta_hint=%d out_dovi=%d out_stream_sd=%d out_codecpar_sd=%d\n",
            video_stream,
            video_codec_name,
            has_dovi,
            prefer_dolby_vision ? 1 : 0,
            (has_dovi && prefer_dolby_vision) ? "dvh1" : "hvc1",
            selected_video && selected_video->codecpar ? selected_video->codecpar->color_range : -1,
            selected_video && selected_video->codecpar ? selected_video->codecpar->color_primaries : -1,
            selected_video && selected_video->codecpar ? selected_video->codecpar->color_trc : -1,
            selected_video && selected_video->codecpar ? selected_video->codecpar->color_space : -1,
            log_stream_sd,
            log_codecpar_sd,
            log_metadata_hint,
            selected_output_has_dovi,
            selected_output_dovi_stream_sd,
            selected_output_dovi_codecpar_sd
        );
    }
    if (audio_stream >= 0) {
        AVStream *selected_audio = ifmt_ctx->streams[audio_stream];
        const char *audio_codec_name = selected_audio && selected_audio->codecpar
            ? avcodec_get_name(selected_audio->codecpar->codec_id)
            : "unknown";
        av_log(
            NULL,
            AV_LOG_INFO,
            "transmux: selected audio stream=%d codec=%s mode=%s\n",
            audio_stream,
            audio_codec_name,
            audio_transcode_to_aac ? "aac_fallback" : "copy"
        );
    } else {
        av_log(NULL, AV_LOG_WARNING, "transmux: no audio stream selected for avplayer hls bridge\n");
    }

    ret = avformat_write_header(ofmt_ctx, &out_opts);
    av_dict_free(&out_opts);
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "transmux: avformat_write_header failed, ret=%d\n", ret);
        ret = -10;
        goto end;
    }

    if (ofmt_ctx->nb_streams > 0) {
        last_dts_per_stream = av_mallocz(sizeof(int64_t) * ofmt_ctx->nb_streams);
        if (!last_dts_per_stream) {
            ret = -15;
            goto end;
        }
        for (unsigned int i = 0; i < ofmt_ctx->nb_streams; i++) {
            last_dts_per_stream[i] = AV_NOPTS_VALUE;
        }
    }

    AVPacket packet;
    av_init_packet(&packet);
    while ((ret = av_read_frame(ifmt_ctx, &packet)) >= 0) {
        if (cancel_flag && atomic_load(cancel_flag)) {
            av_packet_unref(&packet);
            ret = -22;
            goto end;
        }
        int input_stream_index = packet.stream_index;
        int mapped_index = (input_stream_index >= 0 && (unsigned int)input_stream_index < ifmt_ctx->nb_streams)
            ? stream_mapping[input_stream_index]
            : -1;
        if (mapped_index < 0) {
            av_packet_unref(&packet);
            continue;
        }

        if (!video_has_key_written) {
            if (input_stream_index == video_stream) {
                if (!(packet.flags & AV_PKT_FLAG_KEY)) {
                    av_packet_unref(&packet);
                    continue;
                }
                video_has_key_written = 1;
                av_log(NULL, AV_LOG_INFO, "transmux: first video keyframe accepted pts=%lld dts=%lld\n", packet.pts, packet.dts);
            } else {
                av_packet_unref(&packet);
                continue;
            }
        }

        AVStream *in_stream = ifmt_ctx->streams[input_stream_index];
        AVStream *out_stream = ofmt_ctx->streams[mapped_index];
        if (audio_transcode.enabled && input_stream_index == audio_stream) {
            ret = fs_process_audio_packet(&audio_transcode, &packet, ofmt_ctx);
            av_packet_unref(&packet);
            if (ret < 0) {
                av_log(NULL, AV_LOG_ERROR, "transmux: AAC fallback audio processing failed, ret=%d\n", ret);
                ret = -20;
                goto end;
            }
            continue;
        }
        if (packet.pts == AV_NOPTS_VALUE && packet.dts == AV_NOPTS_VALUE) {
            if ((unsigned int)mapped_index < ofmt_ctx->nb_streams &&
                last_dts_per_stream &&
                last_dts_per_stream[mapped_index] != AV_NOPTS_VALUE) {
                packet.dts = last_dts_per_stream[mapped_index] + 1;
                packet.pts = packet.dts;
                synthesized_ts_count++;
                av_log(
                    NULL,
                    AV_LOG_WARNING,
                    "transmux: synthesized pts/dts stream=%d pts=%lld dts=%lld\n",
                    mapped_index,
                    (long long)packet.pts,
                    (long long)packet.dts
                );
            } else {
                dropped_no_ts_count++;
                av_log(
                    NULL,
                    AV_LOG_WARNING,
                    "transmux: drop packet without pts/dts stream=%d\n",
                    mapped_index
                );
                av_packet_unref(&packet);
                continue;
            }
        }
        if (packet.pts == AV_NOPTS_VALUE) {
            packet.pts = packet.dts;
        }
        if (packet.dts == AV_NOPTS_VALUE) {
            packet.dts = packet.pts;
        }
        if (packet.duration <= 0) {
            packet.duration = 1;
        }
        packet.stream_index = mapped_index;
        packet.pts = av_rescale_q_rnd(packet.pts, in_stream->time_base, out_stream->time_base, AV_ROUND_NEAR_INF | AV_ROUND_PASS_MINMAX);
        packet.dts = av_rescale_q_rnd(packet.dts, in_stream->time_base, out_stream->time_base, AV_ROUND_NEAR_INF | AV_ROUND_PASS_MINMAX);
        packet.duration = av_rescale_q(packet.duration, in_stream->time_base, out_stream->time_base);
        if (packet.duration <= 0) {
            packet.duration = 1;
        }
        packet.pos = -1;
        if (packet.pts != AV_NOPTS_VALUE && packet.dts != AV_NOPTS_VALUE && packet.pts < packet.dts) {
            packet.pts = packet.dts;
        }
        if ((unsigned int)mapped_index < ofmt_ctx->nb_streams) {
            int64_t last_dts = last_dts_per_stream ? last_dts_per_stream[mapped_index] : AV_NOPTS_VALUE;
            if (last_dts != AV_NOPTS_VALUE && packet.dts != AV_NOPTS_VALUE && packet.dts <= last_dts) {
                packet.dts = last_dts + 1;
                if (packet.pts != AV_NOPTS_VALUE && packet.pts < packet.dts) {
                    packet.pts = packet.dts;
                }
            }
            if (last_dts_per_stream && packet.dts != AV_NOPTS_VALUE) {
                last_dts_per_stream[mapped_index] = packet.dts;
            }
        }
        ret = av_interleaved_write_frame(ofmt_ctx, &packet);
        av_packet_unref(&packet);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "transmux: av_interleaved_write_frame failed, ret=%d\n", ret);
            ret = -11;
            goto end;
        }
    }
    if (ret == AVERROR_EXIT && cancel_flag && atomic_load(cancel_flag)) {
        ret = -22;
        goto end;
    }
    if (ret == AVERROR_EOF) {
        ret = 0;
    }
    if (ret < 0) {
        ret = -12;
        goto end;
    }
    if (audio_transcode.enabled) {
        ret = fs_flush_audio_transcode(&audio_transcode, ofmt_ctx);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "transmux: AAC fallback flush failed, ret=%d\n", ret);
            ret = -21;
            goto end;
        }
    }
    ret = av_write_trailer(ofmt_ctx);
    if (ret < 0) {
        ret = -13;
        goto end;
    }
    av_log(
        NULL,
        AV_LOG_INFO,
        "transmux: ts_stats synthesized=%d dropped_no_ts=%d\n",
        synthesized_ts_count,
        dropped_no_ts_count
    );
    ret = 0;

end:
    av_dict_free(&in_opts);
    av_dict_free(&out_opts);
    if (ifmt_ctx) {
        avformat_close_input(&ifmt_ctx);
    }
    if (ofmt_ctx) {
        if (!(ofmt_ctx->oformat->flags & AVFMT_NOFILE) && ofmt_ctx->pb) {
            avio_closep(&ofmt_ctx->pb);
        }
        avformat_free_context(ofmt_ctx);
    }
    if (stream_mapping) {
        av_freep(&stream_mapping);
    }
    if (last_dts_per_stream) {
        av_freep(&last_dts_per_stream);
    }
    fs_release_audio_transcode_context(&audio_transcode);
    return ret;
}

int ff_create_muxer(void **out_ffr, const char *file_name, const AVFormatContext *ifmt_ctx, int audio_stream, int video_stream)
{
    int r = 0;
    
    if (!file_name || !strlen(file_name)) { // 没有路径
        r = -1;
        av_log(NULL, AV_LOG_ERROR, "recrod filename is invalid\n");
        goto end;
    }
    
    if (audio_stream == -1 && video_stream == -1) {
        r = -2;
        av_log(NULL, AV_LOG_ERROR, "recrod stream is invalid\n");
        goto end;
    }
    
    //file_name extension is important!!
    //Could not find tag for codec flv1 in stream #1, codec not currently supported in container
    //vp9 only supported in MP4.
    //Unable to choose an output format for '1747121836247.mkv'; use a standard extension for the filename or specify the format manually.
    
    FSMuxer *fsr = mallocz(sizeof(FSMuxer));
    
    if (packet_queue_init(&fsr->packetq) < 0){
        r = -3;
        goto end;
    }

    // 初始化一个用于输出的AVFormatContext结构体
    avformat_alloc_output_context2(&fsr->ofmt_ctx, NULL, NULL, file_name);
    
    if (!fsr->ofmt_ctx) {
        r = -4;
        av_log(NULL, AV_LOG_ERROR, "recrod check your file extention %s\n", file_name);
        goto end;
    }
    
    for (int i = 0; i < ifmt_ctx->nb_streams; i++) {
        if (i == audio_stream || i == video_stream) {
            AVStream *in_stream = ifmt_ctx->streams[i];
            AVStream *out_stream = avformat_new_stream(fsr->ofmt_ctx, NULL);
            if (!out_stream) {
                r = -5;
                av_log(NULL, AV_LOG_ERROR, "recrod Failed allocating output stream\n");
                goto end;
            }
            AVCodecParameters *in_codecpar = in_stream->codecpar;
            r = avcodec_parameters_copy(out_stream->codecpar, in_codecpar);
            if (r < 0) {
                r = -6;
                av_log(NULL, AV_LOG_ERROR, "recrod Failed to copy context from input to output stream codec context\n");
                goto end;
            }
            out_stream->codecpar->codec_tag = 0;
            // 设置start_time
            out_stream->start_time = AV_NOPTS_VALUE;
            out_stream->index = i;
            if (in_stream->codecpar->extradata_size) {
                out_stream->codecpar->extradata = malloc(in_stream->codecpar->extradata_size);
                memcpy(out_stream->codecpar->extradata, in_stream->codecpar->extradata, in_stream->codecpar->extradata_size);
                out_stream->codecpar->extradata_size = in_stream->codecpar->extradata_size;
            }
//            if (fsr->ofmt_ctx->oformat->flags & AVFMT_GLOBALHEADER) {
//                out_stream->codec->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
//            }
        }
    }
    
    av_dump_format(fsr->ofmt_ctx, 0, file_name, 1);
    fsr->ifmt_ctx = ifmt_ctx;
    
    if (out_ffr) {
        *out_ffr = (void *)fsr;
    }
    return 0;
end:
    return r;
}

static int do_write_muxer(void *ffr, AVPacket *pkt)
{
    if (!ffr) {
        return 0;
    }
    FSMuxer *fsr = (FSMuxer *)ffr;
    int ret = 0;
    
    if (pkt == NULL) {
        av_log(NULL, AV_LOG_ERROR, "recrod packet == NULL");
        return -1;
    }
    
    AVStream *in_stream  = fsr->ifmt_ctx->streams[pkt->stream_index];
    AVStream *out_stream = fsr->ofmt_ctx->streams[pkt->stream_index];
    if (pkt->pts != AV_NOPTS_VALUE) {
        // 转换PTS/DTS
        pkt->pts = av_rescale_q_rnd(pkt->pts, in_stream->time_base, out_stream->time_base, (AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
    } else {
        
    }
    
    pkt->dts = av_rescale_q_rnd(pkt->dts, in_stream->time_base, out_stream->time_base, (AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
    pkt->duration = av_rescale_q(pkt->duration, in_stream->time_base, out_stream->time_base);
    pkt->pos = -1;
    
    if (AVMEDIA_TYPE_AUDIO == in_stream->codecpar->codec_type) {
        if (!fsr->is_audio_first) { // 录制的第一帧
            fsr->is_audio_first = 1;
            fsr->audio_start_pts = pkt->pts;
            pkt->pts = 0;
            pkt->dts = 0;
        } else {
            // 设置了 stream 和 ofmt_ctx 的 start_time都没作用。
            pkt->pts = pkt->pts - fsr->audio_start_pts;
            pkt->dts = pkt->dts - fsr->audio_start_pts;
        }
    } else if (AVMEDIA_TYPE_VIDEO == in_stream->codecpar->codec_type) {
        if (!fsr->is_video_first) { // 录制的第一帧
            fsr->is_video_first = 1;
            fsr->video_start_pts = pkt->pts;
            pkt->pts = 0;
            pkt->dts = 0;
        } else {
            // 设置了 stream 和 ofmt_ctx 的 start_time都没作用。
            pkt->pts = pkt->pts - fsr->video_start_pts;
            pkt->dts = pkt->dts - fsr->video_start_pts;
        }
    }

    // 写入一个AVPacket到输出文件
    if ((ret = av_interleaved_write_frame(fsr->ofmt_ctx, pkt)) < 0) {
        av_log(NULL, AV_LOG_ERROR, "recrod Error muxing packet\n");
    }
    av_packet_unref(pkt);

    return ret;
}

static int write_thread(void *arg)
{
    FSMuxer *fsr = (FSMuxer *)arg;
    
    AVPacket *pkt = av_packet_alloc();
    
    int r = 0;
    // 打开输出文件
    if (!(fsr->ofmt_ctx->oformat->flags & AVFMT_NOFILE)) {
        if (avio_open(&fsr->ofmt_ctx->pb, fsr->ofmt_ctx->url, AVIO_FLAG_WRITE) < 0) {
            r = -8;
            av_log(NULL, AV_LOG_ERROR, "recrod Could not open output file '%s'", fsr->ofmt_ctx->url);
            goto end;
        }
    }
    
    AVDictionary *opts = NULL;
    // 设置 movflags 为 faststart
    if (strcmp(fsr->ofmt_ctx->oformat->name, "mp4") == 0 || strcmp(fsr->ofmt_ctx->oformat->name, "mov") == 0) {
        av_dict_set(&opts, "movflags", "faststart", 0);
    }
    // 写视频文件头
    if (avformat_write_header(fsr->ofmt_ctx, &opts) < 0) {
        r = -9;
        av_log(NULL, AV_LOG_ERROR, "recrod Error occurred when opening output file\n");
        goto end;
    }
    
    while (fsr->packetq.abort_request == 0) {
        int serial = 0;
        int get_pkt = packet_queue_get(&fsr->packetq, pkt, 1, &serial);
        if (get_pkt < 0) {
            r = -10;
            break;
        } else if (get_pkt == 0) {
            r = -11;
            break;
        } else {
            
        }
        
        do_write_muxer(fsr, pkt);
    }
end:
    av_packet_free(&pkt);
    
    if (fsr->ofmt_ctx != NULL) {
        r = av_write_trailer(fsr->ofmt_ctx);
        if (fsr->ofmt_ctx && !(fsr->ofmt_ctx->oformat->flags & AVFMT_NOFILE)) {
            r = avio_close(fsr->ofmt_ctx->pb);
        }
        avformat_free_context(fsr->ofmt_ctx);
        fsr->ofmt_ctx = NULL;
    }
    packet_queue_destroy(&fsr->packetq);
    return r;
}

int ff_start_muxer(void *ffr)
{
    if (!ffr) {
        return -1;
    }
    int r = 0;
    FSMuxer *fsr = (FSMuxer *)ffr;
    packet_queue_start(&fsr->packetq);
    fsr->write_tid = SDL_CreateThreadEx(&fsr->_write_tid, write_thread, fsr, "fsmux");
    if (!fsr->write_tid) {
        av_log(NULL, AV_LOG_FATAL, "recrod SDL_CreateThread(): %s\n", SDL_GetError());
        r = -7;
        goto end;
    }
end:
    return r;
}

static int ff_write_muxer(FSMuxer *fsr, struct AVPacket *packet)
{
    if (!fsr) {
        return -1;
    }
    
    AVPacket *pkt = (AVPacket *)av_malloc(sizeof(AVPacket));
    av_new_packet(pkt, 0);
    av_packet_ref(pkt, packet);
   
    return packet_queue_put(&fsr->packetq, pkt);
}

int ff_write_audio_muxer(void *ffr, struct AVPacket *packet)
{
    if (!ffr) {
        return -1;
    }
    
    FSMuxer *fsr = (FSMuxer *)ffr;
    
    if (!fsr->has_key_video_frame) {
        return -1;
    }
    
    return ff_write_muxer(fsr, packet);
}

int ff_write_video_muxer(void *ffr, struct AVPacket *packet)
{
    if (!ffr) {
        return -1;
    }
    
    FSMuxer *fsr = (FSMuxer *)ffr;
    
    if (!fsr->has_key_video_frame) {
        if (packet->flags & AV_PKT_FLAG_KEY) {
            fsr->has_key_video_frame = 1;
        }
    }
    
    if (!fsr->has_key_video_frame) {
        return -1;
    }
    
    return ff_write_muxer(fsr, packet);
}

void ff_stop_muxer(void *ffr)
{
    if (!ffr) {
        return;
    }
    
    FSMuxer *fsr = (FSMuxer *)ffr;
    packet_queue_abort(&fsr->packetq);
    return;
}

int ff_destroy_muxer(void **ffr)
{
    if (!ffr || !*ffr) {
        return -1;
    }
    int r = 0;
    FSMuxer *fsr = (FSMuxer *)*ffr;
    if (fsr) {
        if (fsr->write_tid) {
            SDL_WaitThread(fsr->write_tid, &r);
        }
        av_freep(ffr);
    }
    return r;
}
