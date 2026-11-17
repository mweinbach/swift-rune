#if defined(__linux__) && !defined(__ANDROID__)
#include "RuneMicrophone.h"
#include <gst/app/gstappsrc.h>
#include <gst/audio/audio-format.h>

struct RuneMicAAC {
    GstElement *pipeline;
    GstAppSrc *source;
    GstBus *bus;
    guint64 frames;
    guint32 rate;
    guint16 channels;
    gboolean finished;
    gchar *failure;
};

static int fail(char *error, size_t capacity, const char *message) {
    if (error && capacity) g_strlcpy(error, message, capacity);
    return 0;
}

static int fail_sink(RuneMicAAC *sink, char *error, size_t capacity, const char *message) {
    if (!sink->failure) sink->failure = g_strdup(message);
    return fail(error, capacity, sink->failure);
}

static int pipeline_message(RuneMicAAC *sink, GstMessage *message, char *error, size_t capacity) {
    if (message && GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
        GError *detail = NULL;
        gst_message_parse_error(message, &detail, NULL);
        fail_sink(sink, error, capacity, detail ? detail->message : "GStreamer AAC encoding failed");
        g_clear_error(&detail);
    }
    if (message) gst_message_unref(message);
    return sink->failure ? fail(error, capacity, sink->failure) : 1;
}

static const char *encoder_for(guint rate, guint channels) {
    static const char *encoders[] = {"avenc_aac", "fdkaacenc", "voaacenc"};
    GstCaps *caps = gst_caps_new_simple("audio/x-raw", "rate", G_TYPE_INT, (gint)rate,
                                        "channels", G_TYPE_INT, (gint)channels, NULL);
    const char *selected = NULL;
    for (size_t i = 0; i < G_N_ELEMENTS(encoders); i++) {
        GstElementFactory *factory = gst_element_factory_find(encoders[i]);
        if (!factory) continue;
        gboolean supports_format = gst_element_factory_can_sink_any_caps(factory, caps);
        gst_object_unref(factory);
        if (supports_format) {
            selected = encoders[i];
            break;
        }
    }
    gst_caps_unref(caps);
    return selected;
}

RuneMicAAC *rune_mic_aac_open(const char *path_utf8, uint32_t rate, uint16_t channels,
                              char *error, size_t capacity) {
    if (!path_utf8 || !path_utf8[0] || rate < 8000 || rate > 192000 || (channels != 1 && channels != 2)) {
        fail(error, capacity, "Invalid path or audio format for AAC recording");
        return NULL;
    }
    GError *detail = NULL;
    if (!gst_init_check(NULL, NULL, &detail)) {
        fail(error, capacity, detail ? detail->message : "Could not initialize GStreamer");
        g_clear_error(&detail);
        return NULL;
    }
    const char *encoder = encoder_for(rate, channels);
    if (!encoder) {
        fail(error, capacity, "No installed GStreamer AAC encoder supports the requested rate and channels");
        return NULL;
    }
    // Only a factory selected above enters the pipeline description. Set the caller's path directly.
    gchar *description = g_strdup_printf(
        "appsrc name=pcm format=time ! audioconvert ! %s ! audio/mpeg,mpegversion=4,stream-format=raw "
        "! mp4mux ! filesink name=output sync=false", encoder);
    RuneMicAAC *sink = g_new0(RuneMicAAC, 1);
    sink->pipeline = gst_parse_launch(description, &detail);
    g_free(description);
    if (!sink->pipeline || detail) {
        fail(error, capacity, detail ? detail->message : "Could not construct the AAC recording pipeline");
        g_clear_error(&detail);
        rune_mic_aac_close(sink);
        return NULL;
    }
    sink->rate = rate;
    sink->channels = channels;
    sink->bus = gst_element_get_bus(sink->pipeline);
    sink->source = GST_APP_SRC(gst_bin_get_by_name(GST_BIN(sink->pipeline), "pcm"));
    GstCaps *caps = gst_caps_new_simple("audio/x-raw", "format", G_TYPE_STRING, GST_AUDIO_NE(F32),
                                       "layout", G_TYPE_STRING, "interleaved", "channels", G_TYPE_INT, (gint)channels,
                                       "rate", G_TYPE_INT, (gint)rate, NULL);
    gst_app_src_set_caps(sink->source, caps);
    gst_caps_unref(caps);
    GstElement *output = gst_bin_get_by_name(GST_BIN(sink->pipeline), "output");
    g_object_set(output, "location", path_utf8, NULL);
    gst_object_unref(output);
    if (gst_element_set_state(sink->pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        if (pipeline_message(sink, gst_bus_pop_filtered(sink->bus, GST_MESSAGE_ERROR), error, capacity))
            fail(error, capacity, "Could not open AAC recording output");
        rune_mic_aac_close(sink);
        return NULL;
    }
    return sink;
}

int rune_mic_aac_write(RuneMicAAC *sink, const float *interleaved, uint32_t frames,
                       char *error, size_t capacity) {
    if (!sink || sink->finished || (!interleaved && frames))
        return fail(error, capacity, "AAC recording is closed or its sample buffer is invalid");
    if (!pipeline_message(sink, gst_bus_pop_filtered(sink->bus, GST_MESSAGE_ERROR), error, capacity)) return 0;
    if (!frames) return 1;
    const guint64 bytes = (guint64)frames * sink->channels * sizeof(float);
    if (bytes > G_MAXSIZE || sink->frames > G_MAXUINT64 - frames)
        return fail_sink(sink, error, capacity, "AAC sample buffer is too large");

    // Apply backpressure when capture gets ahead. An error on the streaming thread must
    // still reach stop/cancel on the recorder worker if the queue stops draining.
    const guint64 queue_limit = (guint64)sink->rate * sink->channels * sizeof(float) * 4;
    const gint64 deadline = g_get_monotonic_time() + 3 * G_USEC_PER_SEC;
    while (gst_app_src_get_current_level_bytes(sink->source) > queue_limit) {
        GstMessage *message = gst_bus_timed_pop_filtered(sink->bus, 10 * GST_MSECOND, GST_MESSAGE_ERROR);
        if (!pipeline_message(sink, message, error, capacity)) return 0;
        if (g_get_monotonic_time() >= deadline)
            return fail_sink(sink, error, capacity, "AAC output stopped accepting captured audio");
    }
    GstBuffer *buffer = gst_buffer_new_allocate(NULL, (gsize)bytes, NULL);
    if (!buffer) return fail_sink(sink, error, capacity, "Could not allocate an AAC input buffer");
    gst_buffer_fill(buffer, 0, interleaved, (gsize)bytes);
    GstClockTime pts = gst_util_uint64_scale(sink->frames, GST_SECOND, sink->rate);
    GstClockTime end = gst_util_uint64_scale(sink->frames + frames, GST_SECOND, sink->rate);
    GST_BUFFER_PTS(buffer) = pts;
    GST_BUFFER_DURATION(buffer) = end - pts;
    GstFlowReturn result = gst_app_src_push_buffer(sink->source, buffer);
    if (result != GST_FLOW_OK) return fail_sink(sink, error, capacity, gst_flow_get_name(result));
    sink->frames += frames;
    return 1;
}

int rune_mic_aac_finish(RuneMicAAC *sink, char *error, size_t capacity) {
    if (!sink) return fail(error, capacity, "No AAC recording is open");
    if (sink->failure) return fail(error, capacity, sink->failure);
    if (sink->finished) return 1;
    if (!sink->frames) return fail_sink(sink, error, capacity, "No audio samples were recorded");
    GstFlowReturn result = gst_app_src_end_of_stream(sink->source);
    if (result != GST_FLOW_OK) return fail_sink(sink, error, capacity, gst_flow_get_name(result));
    // EOS arrives from the sink after the encoder and MP4 muxer have drained.
    GstMessage *message = gst_bus_timed_pop_filtered(sink->bus, 4 * GST_SECOND, GST_MESSAGE_ERROR | GST_MESSAGE_EOS);
    if (!message) return fail_sink(sink, error, capacity, "Timed out while finalizing the AAC recording");
    if (!pipeline_message(sink, message, error, capacity)) return 0;
    if (gst_element_set_state(sink->pipeline, GST_STATE_NULL) == GST_STATE_CHANGE_FAILURE)
        return fail_sink(sink, error, capacity, "Could not close the AAC file");
    sink->finished = TRUE;
    return 1;
}

void rune_mic_aac_close(RuneMicAAC *sink) {
    if (!sink) return;
    if (sink->pipeline) gst_element_set_state(sink->pipeline, GST_STATE_NULL);
    if (sink->bus) gst_object_unref(sink->bus);
    if (sink->source) gst_object_unref(sink->source);
    if (sink->pipeline) gst_object_unref(sink->pipeline);
    g_free(sink->failure);
    g_free(sink);
}
#endif
