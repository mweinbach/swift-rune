#if defined(__linux__) && !defined(__ANDROID__)

#include "RuneMicrophone.h"
#include <gst/app/gstappsink.h>
#include <gst/gst.h>

struct RuneMic {
    GstElement *pipeline;
    GstAppSink *sink; /* owned by pipeline */
    GstBus *bus;
    GstSample *pending;
    gsize offset;
    gsize bytes_per_frame;
    gboolean paused;
};

static void set_error(char *error, size_t capacity, const char *message) {
    if (error && capacity) g_strlcpy(error, message, capacity);
}

static gboolean capture_failed(RuneMic *mic, char *error, size_t capacity) {
    GstMessage *message = gst_bus_pop_filtered(mic->bus, GST_MESSAGE_ERROR);
    if (!message) return FALSE;
    GError *cause = NULL;
    gst_message_parse_error(message, &cause, NULL);
    set_error(error, capacity, cause ? cause->message : "Microphone capture failed");
    g_clear_error(&cause);
    gst_message_unref(message);
    return TRUE;
}

static gboolean set_state(RuneMic *mic, GstState state, char *error, size_t capacity) {
    GstStateChangeReturn result = gst_element_set_state(mic->pipeline, state);
    if (result == GST_STATE_CHANGE_ASYNC) {
        result = gst_element_get_state(mic->pipeline, NULL, NULL, 5 * GST_SECOND);
    }
    if (capture_failed(mic, error, capacity)) return FALSE;
    if (result == GST_STATE_CHANGE_FAILURE || result == GST_STATE_CHANGE_ASYNC) {
        set_error(error, capacity, result == GST_STATE_CHANGE_FAILURE
                  ? "The audio input could not change state" : "The audio input did not become ready");
        return FALSE;
    }
    return TRUE;
}

static void discard_sample(RuneMic *mic) {
    if (mic->pending) gst_sample_unref(mic->pending);
    mic->pending = NULL;
    mic->offset = 0;
}

/* Select a real capture endpoint. autoaudiosrc can silently use a test source
 * when no devices exist, which would produce a successful but empty recording. */
static GstElement *microphone_source(void) {
    GstDeviceMonitor *monitor = gst_device_monitor_new();
    GstElement *source = NULL;
    gst_device_monitor_add_filter(monitor, "Audio/Source", NULL);
    if (gst_device_monitor_start(monitor)) {
        GList *devices = gst_device_monitor_get_devices(monitor);
        GstDevice *chosen = NULL;
        for (GList *item = devices; item; item = item->next) {
            GstDevice *device = GST_DEVICE(item->data);
            GstStructure *props = gst_device_get_properties(device);
            gboolean preferred = FALSE;
            gboolean is_monitor = FALSE;
            if (props) {
                gst_structure_get_boolean(props, "is-default", &preferred);
                const gchar *kind = gst_structure_get_string(props, "device.class");
                is_monitor = g_strcmp0(kind, "monitor") == 0;
                gst_structure_free(props);
            }
            if (!is_monitor && (!chosen || preferred)) chosen = device;
            if (!is_monitor && preferred) break;
        }
        if (chosen) source = gst_device_create_element(chosen, NULL);
        g_list_free_full(devices, (GDestroyNotify)gst_object_unref);
        gst_device_monitor_stop(monitor);
    }
    gst_object_unref(monitor);
    return source;
}

int rune_mic_permission(void) {
    /* Linux audio servers authorize the connection when the endpoint opens. */
    return 0;
}

RuneMic *rune_mic_open(uint32_t sample_rate, uint16_t channels, int synthetic,
                       char *error, size_t capacity) {
    if (sample_rate < 8000 || sample_rate > 192000 || channels < 1 || channels > 2) {
        set_error(error, capacity, "Unsupported microphone sample rate or channel count");
        return NULL;
    }
    GError *cause = NULL;
    if (!gst_init_check(NULL, NULL, &cause)) {
        set_error(error, capacity, cause ? cause->message : "GStreamer initialization failed");
        g_clear_error(&cause);
        return NULL;
    }
    GstElement *source = synthetic ? gst_element_factory_make("audiotestsrc", NULL) : microphone_source();
    if (!source) {
        set_error(error, capacity, synthetic ? "GStreamer audiotestsrc is unavailable"
                                            : "No accessible audio capture device was found");
        return NULL;
    }
    if (synthetic) g_object_set(source, "is-live", TRUE, "freq", 440.0, "volume", 0.25, NULL);

    RuneMic *mic = g_new0(RuneMic, 1);
    mic->pipeline = gst_pipeline_new(NULL);
    mic->bytes_per_frame = channels * sizeof(float);
    gst_bin_add(GST_BIN(mic->pipeline), source);
    GstElement *convert = gst_element_factory_make("audioconvert", NULL);
    GstElement *resample = gst_element_factory_make("audioresample", NULL);
    GstElement *sink = gst_element_factory_make("appsink", NULL);
    if (convert) gst_bin_add(GST_BIN(mic->pipeline), convert);
    if (resample) gst_bin_add(GST_BIN(mic->pipeline), resample);
    if (sink) gst_bin_add(GST_BIN(mic->pipeline), sink);
    if (!convert || !resample || !sink) {
        set_error(error, capacity, "Install the GStreamer base plug-ins for audio capture");
        rune_mic_close(mic);
        return NULL;
    }
    mic->sink = GST_APP_SINK(sink);
    mic->bus = gst_element_get_bus(mic->pipeline);
#if G_BYTE_ORDER == G_LITTLE_ENDIAN
    const char *format = "F32LE";
#else
    const char *format = "F32BE";
#endif
    GstCaps *caps = gst_caps_new_simple("audio/x-raw", "format", G_TYPE_STRING, format,
                                        "layout", G_TYPE_STRING, "interleaved",
                                        "rate", G_TYPE_INT, (int)sample_rate,
                                        "channels", G_TYPE_INT, (int)channels, NULL);
    gst_app_sink_set_caps(mic->sink, caps);
    gst_caps_unref(caps);
    gst_app_sink_set_max_buffers(mic->sink, 8);
    g_object_set(sink, "sync", FALSE, "enable-last-sample", FALSE, "wait-on-eos", FALSE, NULL);
    if (!gst_element_link_many(source, convert, resample, sink, NULL)) {
        set_error(error, capacity, "The microphone cannot supply the requested audio format");
        rune_mic_close(mic);
        return NULL;
    }
    if (!set_state(mic, GST_STATE_PLAYING, error, capacity)) {
        rune_mic_close(mic);
        return NULL;
    }
    return mic;
}

int rune_mic_read(RuneMic *mic, float *interleaved, uint32_t frame_capacity, uint32_t timeout_ms,
                  char *error, size_t capacity) {
    if (!mic || !interleaved || !frame_capacity || frame_capacity > G_MAXINT) {
        set_error(error, capacity, "Invalid microphone read buffer");
        return -1;
    }
    if (mic->paused) return 0;
    if (capture_failed(mic, error, capacity)) return -1;
    if (!mic->pending) {
        mic->pending = gst_app_sink_try_pull_sample(mic->sink, (GstClockTime)timeout_ms * GST_MSECOND);
        if (!mic->pending) {
            if (capture_failed(mic, error, capacity)) return -1;
            if (!gst_app_sink_is_eos(mic->sink)) return 0;
            set_error(error, capacity, "The microphone input has ended");
            return -1;
        }
    }
    GstBuffer *buffer = gst_sample_get_buffer(mic->pending);
    gsize size = buffer ? gst_buffer_get_size(buffer) : 0;
    if (size % mic->bytes_per_frame != 0) {
        set_error(error, capacity, "The microphone returned incomplete audio frames");
        discard_sample(mic);
        return -1;
    }
    gsize frames = MIN((size - mic->offset) / mic->bytes_per_frame, frame_capacity);
    gsize bytes = frames * mic->bytes_per_frame;
    if (bytes && gst_buffer_extract(buffer, mic->offset, interleaved, bytes) != bytes) {
        set_error(error, capacity, "The microphone sample could not be read");
        discard_sample(mic);
        return -1;
    }
    mic->offset += bytes;
    if (mic->offset == size) discard_sample(mic);
    return (int)frames;
}

int rune_mic_set_paused(RuneMic *mic, int paused, char *error, size_t capacity) {
    if (!mic) {
        set_error(error, capacity, "Microphone session is closed");
        return 0;
    }
    if (mic->paused == (paused != 0)) return 1;
    /* READY flushes pending samples so the next recording segment never
     * includes audio accumulated at or during the pause. */
    if (!set_state(mic, paused ? GST_STATE_READY : GST_STATE_PLAYING, error, capacity)) return 0;
    discard_sample(mic);
    mic->paused = paused != 0;
    return 1;
}

void rune_mic_close(RuneMic *mic) {
    if (!mic) return;
    gst_element_set_state(mic->pipeline, GST_STATE_NULL);
    discard_sample(mic);
    if (mic->bus) gst_object_unref(mic->bus);
    gst_object_unref(mic->pipeline);
    g_free(mic);
}
#endif
