#if defined(__linux__) && !defined(__ANDROID__)
#include "CRuneMedia.h"
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#include <math.h>
#include <string.h>

struct RuneMedia {
    GstElement *player;
    GstAppSink *frames;
    GstElement *audio_sink;
    GstBus *bus;
    RuneMediaInfo info;
    gboolean mirror_input;
    gboolean playing;
    gboolean pending_paused_seek;
    gboolean ended;
    gdouble rate;
    gchar *failure;
};

static int fail(char *error, size_t capacity, const char *message) {
    if (error && capacity) g_strlcpy(error, message, capacity);
    return 0;
}

/* Without a GLib main loop the host's pull/status calls also drain the bus. */
static int check_bus(RuneMedia *media, char *error, size_t capacity) {
    GstMessage *message;
    while ((message = gst_bus_pop(media->bus))) {
        if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS) media->ended = TRUE;
        if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR && !media->failure) {
            GError *detail = NULL;
            gst_message_parse_error(message, &detail, NULL);
            media->failure = g_strdup(detail ? detail->message : "GStreamer playback failed");
            g_clear_error(&detail);
        }
        gst_message_unref(message);
    }
    return media->failure ? fail(error, capacity, media->failure) : 1;
}

void rune_media_close(RuneMedia *media) {
    if (!media) return;
    if (media->player) gst_element_set_state(media->player, GST_STATE_NULL);
    if (media->bus) gst_object_unref(media->bus);
    if (media->frames) gst_object_unref(media->frames);
    if (media->audio_sink) gst_object_unref(media->audio_sink);
    if (media->player) gst_object_unref(media->player);
    g_free(media->failure);
    g_free(media);
}

static gint video_rotation(GstElement *player, gboolean *mirror) {
    GstTagList *tags = NULL;
    gint track = 0;
    g_object_get(player, "current-video", &track, NULL);
    g_signal_emit_by_name(player, "get-video-tags", track, &tags);
    gchar *name = NULL;
    if (tags) {
        gst_tag_list_get_string(tags, GST_TAG_IMAGE_ORIENTATION, &name);
        gst_tag_list_unref(tags);
    }
    *mirror = name && g_str_has_prefix(name, "flip-");
    const gchar *turn = *mirror ? name + strlen("flip-") : name;
    gint rotation = 0;
    if (g_strcmp0(turn, "rotate-90") == 0) rotation = 90;
    else if (g_strcmp0(turn, "rotate-180") == 0) rotation = 180;
    else if (g_strcmp0(turn, "rotate-270") == 0) rotation = 270;
    g_free(name);
    return rotation;
}

static gboolean video_info(RuneMedia *media) {
    GstPad *pad = gst_element_get_static_pad(GST_ELEMENT(media->frames), "sink");
    GstCaps *caps = gst_pad_get_current_caps(pad);
    gst_object_unref(pad);
    if (!caps) return FALSE;
    GstVideoInfo video;
    gboolean usable = gst_video_info_from_caps(&video, caps);
    gst_caps_unref(caps);
    if (!usable || video.width <= 0 || video.height <= 0 ||
        video.width > 16384 || video.height > 16384) return FALSE;
    media->info.width = (uint32_t)video.width;
    media->info.height = (uint32_t)video.height;
    if (video.fps_n > 0 && video.fps_d > 0)
        media->info.frame_duration = (double)video.fps_d / video.fps_n;
    media->info.rotation_clockwise = video_rotation(media->player, &media->mirror_input);
    return TRUE;
}

RuneMedia *rune_media_open(const char *uri, int audio_only, int headless,
                          RuneMediaInfo *info, char *error, size_t capacity) {
    GError *init_error = NULL;
    if (!uri || !info) {
        fail(error, capacity, "Missing media URI or metadata destination");
        return NULL;
    }
    if (!gst_init_check(NULL, NULL, &init_error)) {
        fail(error, capacity, init_error ? init_error->message : "GStreamer initialization failed");
        g_clear_error(&init_error);
        return NULL;
    }
    RuneMedia *media = g_new0(RuneMedia, 1);
    media->rate = 1;
    media->info.duration = -1;
    media->player = gst_element_factory_make("playbin", NULL);
    if (!media->player) {
        fail(error, capacity, "GStreamer playbin is unavailable; install the base plugins");
        goto failed;
    }
    gst_object_ref_sink(media->player);
    media->bus = gst_element_get_bus(media->player);
    GstElement *sink = gst_element_factory_make("appsink", NULL);
    if (!sink) {
        fail(error, capacity, "GStreamer appsink is unavailable; install the base plugins");
        goto failed;
    }
    media->frames = GST_APP_SINK(gst_object_ref_sink(sink));
    GstCaps *caps = gst_caps_new_empty_simple("video/x-raw");
    gst_caps_set_simple(caps, "format", G_TYPE_STRING, "BGRA", NULL);
    gst_app_sink_set_caps(media->frames, caps);
    gst_caps_unref(caps);
    /* Latest-frame delivery stays bounded when a window is occluded or minimized. */
    g_object_set(sink, "max-buffers", 1u, "drop", TRUE, "wait-on-eos", FALSE,
                 "enable-last-sample", FALSE, NULL);
    g_object_set(media->player, "video-sink", sink, "uri", uri, NULL);
    {
        GstElement *sound = headless ? NULL : gst_element_factory_make("autoaudiosink", NULL);
        if (!sound) sound = gst_element_factory_make("fakesink", NULL);
        if (!sound) {
            fail(error, capacity, "Missing the GStreamer audio sink plugins");
            goto failed;
        }
        gst_object_ref_sink(sound);
        g_object_set(sound, "sync", TRUE, NULL);
        g_object_set(media->player, "audio-sink", sound, NULL);
        if (headless) gst_object_unref(sound);
        else media->audio_sink = sound;
    }
    /* GstPlayFlags registers its names with the flags property. */
    GParamSpec *spec = g_object_class_find_property(G_OBJECT_GET_CLASS(media->player), "flags");
    if (spec && G_IS_PARAM_SPEC_FLAGS(spec)) {
        GFlagsClass *flags_type = G_PARAM_SPEC_FLAGS(spec)->flags_class;
        const GFlagsValue *text = g_flags_get_value_by_nick(flags_type, "text");
        const GFlagsValue *video = g_flags_get_value_by_nick(flags_type, "video");
        guint flags = 0;
        g_object_get(media->player, "flags", &flags, NULL);
        if (text) flags &= ~text->value;
        if (audio_only && video) flags &= ~video->value;
        g_object_set(media->player, "flags", flags, NULL);
    }

    GstStateChangeReturn state = gst_element_set_state(media->player, GST_STATE_PAUSED);
    if (state == GST_STATE_CHANGE_ASYNC)
        state = gst_element_get_state(media->player, NULL, NULL, 10 * GST_SECOND);
    if (!check_bus(media, error, capacity)) goto failed;
    if (state == GST_STATE_CHANGE_FAILURE || state == GST_STATE_CHANGE_ASYNC) {
        fail(error, capacity, state == GST_STATE_CHANGE_ASYNC
             ? "Timed out waiting for GStreamer to preroll media"
             : "GStreamer could not open a playable media stream");
        goto failed;
    }
    gint audio_streams = 0, video_streams = 0;
    g_object_get(media->player, "n-audio", &audio_streams, "n-video", &video_streams, NULL);
    media->info.has_audio = audio_streams > 0;
    if (!audio_only && video_streams > 0) {
        if (!video_info(media)) {
            fail(error, capacity, "Video has no supported raw BGRA output dimensions");
            goto failed;
        }
    } else if (!media->info.has_audio) {
        fail(error, capacity, audio_only ? "Media has no playable audio track" : "Media has no playable video track");
        goto failed;
    }
    gint64 duration = GST_CLOCK_TIME_NONE;
    if (gst_element_query_duration(media->player, GST_FORMAT_TIME, &duration) && duration >= 0)
        media->info.duration = (double)duration / GST_SECOND;
    *info = media->info;
    return media;

failed:
    rune_media_close(media);
    return NULL;
}

static gboolean perform_seek(RuneMedia *media, double seconds, double rate,
                             char *error, size_t capacity) {
    if (!isfinite(seconds) || seconds < 0 || seconds >= (double)G_MAXINT64 / GST_SECOND)
        return fail(error, capacity, "Media seek time is outside the supported range");
    gint64 position = (gint64)(seconds * GST_SECOND);
    if (!gst_element_seek(media->player, rate, GST_FORMAT_TIME,
                          GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE,
                          GST_SEEK_TYPE_SET, position, GST_SEEK_TYPE_NONE, GST_CLOCK_TIME_NONE))
        return fail(error, capacity, "GStreamer could not seek this stream");
    media->ended = FALSE;
    media->rate = rate;
    return TRUE;
}

int rune_media_frame(RuneMedia *media, double seconds, uint8_t *pixels, size_t length,
                     char *error, size_t capacity) {
    if (!media || !pixels || !isfinite(seconds)) {
        fail(error, capacity, "Invalid media frame request");
        return -1;
    }
    if (!check_bus(media, error, capacity)) return -1;
    const size_t row_bytes = (size_t)media->info.width * 4;
    if (!row_bytes || !media->info.height) return 0;
    if (length < row_bytes * media->info.height) {
        fail(error, capacity, "Media frame destination is too small");
        return -1;
    }
    GstSample *sample = NULL;
    if (seconds >= 0) {
        if (media->info.duration > 0)
            seconds = MIN(seconds, MAX(0.0, media->info.duration - 0.000001));
        if (!perform_seek(media, seconds, media->rate, error, capacity)) return -1;
        sample = gst_app_sink_try_pull_preroll(media->frames, 5 * GST_SECOND);
    } else if (media->playing) {
        sample = gst_app_sink_try_pull_sample(media->frames, 0);
    } else {
        /* A flushing seek returns before the new paused frame has arrived. */
        sample = gst_app_sink_try_pull_preroll(media->frames, media->pending_paused_seek ? 5 * GST_SECOND : 0);
        media->pending_paused_seek = FALSE;
    }
    if (!sample) return check_bus(media, error, capacity) ? 0 : -1;
    GstVideoInfo video;
    GstVideoFrame frame;
    GstCaps *caps = gst_sample_get_caps(sample);
    GstBuffer *buffer = gst_sample_get_buffer(sample);
    gboolean mapped = caps && buffer && gst_video_info_from_caps(&video, caps) &&
        GST_VIDEO_INFO_FORMAT(&video) == GST_VIDEO_FORMAT_BGRA &&
        video.width == (gint)media->info.width && video.height == (gint)media->info.height &&
        gst_video_frame_map(&frame, &video, buffer, GST_MAP_READ);
    if (!mapped) {
        gst_sample_unref(sample);
        fail(error, capacity, "GStreamer delivered an incompatible video sample");
        return -1;
    }
    const guint8 *row = GST_VIDEO_FRAME_PLANE_DATA(&frame, 0);
    gint stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
    for (guint y = 0; y < media->info.height; ++y) {
        const guint8 *src = row + (gssize)y * stride;
        guint8 *dst = pixels + y * row_bytes;
        if (media->mirror_input) {
            /* GStreamer's flip-rotate tags mirror stored pixels before rotating. */
            for (guint x = 0; x < media->info.width; ++x)
                memcpy(dst + 4 * x, src + row_bytes - 4 * (x + 1), 4);
        } else {
            memcpy(dst, src, row_bytes);
        }
    }
    gst_video_frame_unmap(&frame);
    gst_sample_unref(sample);
    return 1;
}

static gboolean is_fake_sink(GstElement *element) {
    GstElementFactory *factory = gst_element_get_factory(element);
    return factory && g_str_equal(gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(factory)), "fakesink");
}

/* autoaudiosink falls back to fakesink when it cannot open any device.
 * Muted video can still render, but audible playback must name the failure. */
static gboolean audio_unavailable(GstElement *sink) {
    if (!GST_IS_BIN(sink)) return is_fake_sink(sink);
    GstIterator *children = gst_bin_iterate_recurse(GST_BIN(sink));
    GValue item = G_VALUE_INIT;
    gboolean found = FALSE;
    GstIteratorResult result;
    while ((result = gst_iterator_next(children, &item)) == GST_ITERATOR_OK ||
           result == GST_ITERATOR_RESYNC) {
        if (result == GST_ITERATOR_RESYNC) {
            gst_iterator_resync(children);
            continue;
        }
        found = is_fake_sink(g_value_get_object(&item));
        g_value_reset(&item);
        if (found) break;
    }
    if (G_VALUE_TYPE(&item)) g_value_unset(&item);
    gst_iterator_free(children);
    return found;
}

int rune_media_transport(RuneMedia *media, int playing, double seek_seconds,
                         double rate, double volume, int muted, char *error, size_t capacity) {
    if (!media || !isfinite(rate) || rate <= 0 || !isfinite(seek_seconds) || !isfinite(volume))
        return fail(error, capacity, "Invalid media transport request");
    if (!check_bus(media, error, capacity)) return 0;
    if (playing && !muted && volume > 0 && media->info.has_audio &&
        media->audio_sink && audio_unavailable(media->audio_sink))
        return fail(error, capacity, "GStreamer could not open a Linux audio output device");
    if (seek_seconds >= 0 || rate != media->rate) {
        if (seek_seconds < 0) {
            gint64 time = 0;
            if (!gst_element_query_position(media->player, GST_FORMAT_TIME, &time) || time < 0)
                return fail(error, capacity, "GStreamer could not read the playback position");
            seek_seconds = (double)time / GST_SECOND;
        }
        if (!perform_seek(media, seek_seconds, rate, error, capacity)) return 0;
    }
    g_object_set(media->player, "volume", CLAMP(volume, 0.0, 1.0), "mute", (gboolean)!!muted, NULL);
    GstState state = playing ? GST_STATE_PLAYING : GST_STATE_PAUSED;
    if (gst_element_set_state(media->player, state) == GST_STATE_CHANGE_FAILURE)
        return check_bus(media, error, capacity) ? fail(error, capacity, "GStreamer rejected playback state") : 0;
    media->playing = !!playing;
    media->pending_paused_seek = !playing && seek_seconds >= 0;
    return 1;
}

int rune_media_status(RuneMedia *media, double *seconds, int *ended, char *error, size_t capacity) {
    if (!media || !seconds || !ended) return fail(error, capacity, "Invalid media status request");
    if (!check_bus(media, error, capacity)) return 0;
    gint64 position = 0;
    if (gst_element_query_position(media->player, GST_FORMAT_TIME, &position) && position >= 0)
        *seconds = (double)position / GST_SECOND;
    else
        *seconds = media->ended ? MAX(0.0, media->info.duration) : 0.0;
    *ended = media->ended;
    return 1;
}
#endif
