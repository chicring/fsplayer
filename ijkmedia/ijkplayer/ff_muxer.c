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
#include <limits.h>
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

static int fs_pick_video_stream(const AVFormatContext *ifmt_ctx)
{
    if (!ifmt_ctx) {
        return -1;
    }
    for (unsigned int i = 0; i < ifmt_ctx->nb_streams; i++) {
        const AVStream *stream = ifmt_ctx->streams[i];
        if (stream && stream->codecpar && stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            return (int)i;
        }
    }
    return -1;
}

static int fs_stream_has_dovi_conf(const AVStream *stream)
{
#ifdef AV_PKT_DATA_DOVI_CONF
    int side_data_size = 0;
    if (!stream) {
        return 0;
    }
    return av_stream_get_side_data((AVStream *)stream, AV_PKT_DATA_DOVI_CONF, &side_data_size) != NULL &&
           side_data_size > 0;
#else
    (void)stream;
    return 0;
#endif
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
        if (src && side_data_size > 0) {
            uint8_t *dst = av_stream_new_side_data(out_stream, AV_PKT_DATA_CONTENT_LIGHT_LEVEL, side_data_size);
            if (dst) {
                memcpy(dst, src, (size_t)side_data_size);
            }
        }
    }
#endif
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
        case AV_CODEC_ID_MP3:
            return 420;
        case AV_CODEC_ID_ALAC:
            return 400;
        default:
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
    return fallback_audio;
}

int ff_transmux_to_hls_fmp4(
    const char *input_url,
    const char *output_directory,
    const char *headers,
    int segment_duration_sec,
    int timeout_sec
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
    int video_has_key_written = 0;
    int64_t *last_dts_per_stream = NULL;

    if (!input_url || !*input_url || !output_directory || !*output_directory) {
        return -1;
    }

    if (headers && *headers) {
        av_dict_set(&in_opts, "headers", headers, 0);
    }
    av_dict_set(&in_opts, "fflags", "+genpts", 0);
    av_dict_set(&in_opts, "probesize", "20000000", 0);
    av_dict_set(&in_opts, "analyzeduration", "30000000", 0);
    if (timeout_sec > 0) {
        char timeout_buf[32] = {0};
        snprintf(timeout_buf, sizeof(timeout_buf), "%lld", (long long)timeout_sec * 1000000LL);
        av_dict_set(&in_opts, "rw_timeout", timeout_buf, 0);
        av_dict_set(&in_opts, "timeout", timeout_buf, 0);
    }

    ret = avformat_open_input(&ifmt_ctx, input_url, NULL, &in_opts);
    av_dict_free(&in_opts);
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "transmux: avformat_open_input failed, ret=%d\n", ret);
        ret = -2;
        goto end;
    }
    ret = avformat_find_stream_info(ifmt_ctx, NULL);
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "transmux: avformat_find_stream_info failed, ret=%d\n", ret);
        ret = -3;
        goto end;
    }

    video_stream = fs_pick_video_stream(ifmt_ctx);
    audio_stream = fs_pick_audio_stream(ifmt_ctx);
    if (video_stream < 0) {
        av_log(NULL, AV_LOG_ERROR, "transmux: no video stream\n");
        ret = -4;
        goto end;
    }

    char master_playlist_path[PATH_MAX] = {0};
    char segment_filename_pattern[64] = {0};
    snprintf(master_playlist_path, sizeof(master_playlist_path), "%s/master.m3u8", output_directory);
    // Keep segment URI relative to master playlist, otherwise AVPlayer may resolve
    // absolute paths outside the local proxy route (`/bridge/<cacheKey>/...`).
    // snprintf needs escaped '%' here.
    snprintf(segment_filename_pattern, sizeof(segment_filename_pattern), "segment_%%05d.m4s");

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
        ret = avcodec_parameters_copy(out_stream->codecpar, in_stream->codecpar);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "transmux: avcodec_parameters_copy failed, ret=%d\n", ret);
            ret = -8;
            goto end;
        }
        fs_copy_stream_side_data(in_stream, out_stream);
        if (out_stream->codecpar->codec_id == AV_CODEC_ID_HEVC) {
            if (fs_stream_has_dovi_conf(in_stream)) {
                out_stream->codecpar->codec_tag = MKTAG('d', 'v', 'h', '1');
            } else {
                out_stream->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
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
    int normalized_segment_duration_sec = segment_duration_sec > 0 ? segment_duration_sec : 4;
    snprintf(hls_time_buf, sizeof(hls_time_buf), "%d", normalized_segment_duration_sec);
    av_dict_set(&out_opts, "hls_time", hls_time_buf, 0);
    av_dict_set(&out_opts, "hls_playlist_type", "event", 0);
    av_dict_set(&out_opts, "hls_list_size", "0", 0);
    av_dict_set(&out_opts, "hls_segment_type", "fmp4", 0);
    av_dict_set(&out_opts, "hls_flags", "independent_segments+append_list+temp_file", 0);
    av_dict_set(&out_opts, "hls_fmp4_init_filename", "init.mp4", 0);
    av_dict_set(&out_opts, "hls_segment_filename", segment_filename_pattern, 0);
    av_dict_set(&out_opts, "strict", "unofficial", 0);
    av_dict_set(&out_opts, "hls_segment_options", "strict=unofficial:movflags=+frag_keyframe+default_base_moof+delay_moov:write_colr=1", 0);
    av_dict_set(&out_opts, "avoid_negative_ts", "make_non_negative", 0);
    av_dict_set(&out_opts, "max_interleave_delta", "0", 0);
    av_dict_set(&out_opts, "muxdelay", "0", 0);
    av_dict_set(&out_opts, "muxpreload", "0", 0);

    if (video_stream >= 0) {
        AVStream *selected_video = ifmt_ctx->streams[video_stream];
        const char *video_codec_name = selected_video && selected_video->codecpar
            ? avcodec_get_name(selected_video->codecpar->codec_id)
            : "unknown";
        int has_dovi = fs_stream_has_dovi_conf(selected_video);
        av_log(
            NULL,
            AV_LOG_INFO,
            "transmux: selected video stream=%d codec=%s dovi=%d tag=%s\n",
            video_stream,
            video_codec_name,
            has_dovi,
            has_dovi ? "dvh1" : "hvc1"
        );
    }
    if (audio_stream >= 0) {
        AVStream *selected_audio = ifmt_ctx->streams[audio_stream];
        const char *audio_codec_name = selected_audio && selected_audio->codecpar
            ? avcodec_get_name(selected_audio->codecpar->codec_id)
            : "unknown";
        av_log(NULL, AV_LOG_INFO, "transmux: selected audio stream=%d codec=%s\n", audio_stream, audio_codec_name);
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
        if (packet.pts == AV_NOPTS_VALUE && packet.dts == AV_NOPTS_VALUE) {
            av_packet_unref(&packet);
            continue;
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
    if (ret == AVERROR_EOF) {
        ret = 0;
    }
    if (ret < 0) {
        ret = -12;
        goto end;
    }
    ret = av_write_trailer(ofmt_ctx);
    if (ret < 0) {
        ret = -13;
        goto end;
    }
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
