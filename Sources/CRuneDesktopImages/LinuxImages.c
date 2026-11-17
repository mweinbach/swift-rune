#if defined(__linux__) && !defined(__ANDROID__)
#include "CRuneDesktopImages.h"
#include "ExifOrientation.h"
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <lcms2.h>
#include <webp/demux.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    uint32_t limit;
    RuneImageEmit emit;
    void *context;
    char *error;
    size_t error_size;
    uint64_t emitted_bytes;
    gboolean invalid_size;
} Decode;

static int fail(Decode *d, const char *message) {
    if (d->error && d->error_size)
        g_strlcpy(d->error, message, d->error_size);
    return 0;
}

static int valid_size(uint32_t w, uint32_t h) {
    return w && h && w <= RUNE_IMAGE_MAX_SIDE && h <= RUNE_IMAGE_MAX_SIDE &&
           (uint64_t)w * h * 4 <= RUNE_IMAGE_MAX_BYTES;
}

static void fit(int *w, int *h, uint32_t limit) {
    int longest = MAX(*w, *h);
    if (!limit || longest <= (int)limit) return;
    *w = MAX(1, (int)(((int64_t)*w * limit + longest / 2) / longest));
    *h = MAX(1, (int)(((int64_t)*h * limit + longest / 2) / longest));
}

static void size_prepared(GdkPixbufLoader *loader, int w, int h, gpointer context) {
    Decode *d = context;
    // Keep ordinary frames at their source size until the sRGB conversion.
    // An oversized source can still use the loader's bounded thumbnail path.
    if (w > 0 && h > 0 && valid_size((uint32_t)w, (uint32_t)h)) return;
    if (w <= 0 || h <= 0) {
        d->invalid_size = TRUE;
    } else {
        fit(&w, &h, d->limit);
        d->invalid_size = !valid_size((uint32_t)w, (uint32_t)h);
    }
    gdk_pixbuf_loader_set_size(loader, d->invalid_size ? 1 : w, d->invalid_size ? 1 : h);
}

/* GdkPixbuf exposes the embedded profile but gives us unconverted RGB(A)
 * samples. Work on an owned copy: the input can be a decoder's next canvas. */
static cmsHTRANSFORM srgb_transform(const uint8_t *bytes, size_t size, gboolean alpha) {
    if (!bytes || !size || size > UINT32_MAX) return NULL;
    cmsHPROFILE input = cmsOpenProfileFromMem(bytes, (cmsUInt32Number)size);
    if (!input) return NULL;
    cmsHTRANSFORM transform = NULL;
    if (cmsGetColorSpace(input) == cmsSigRgbData) {
        cmsHPROFILE output = cmsCreate_sRGBProfile();
        if (output) {
            cmsUInt32Number layout = alpha ? TYPE_RGBA_8 : TYPE_RGB_8;
            transform = cmsCreateTransform(input, layout, output, layout, INTENT_RELATIVE_COLORIMETRIC,
                                           alpha ? cmsFLAGS_COPY_ALPHA : 0);
            cmsCloseProfile(output);
        }
    }
    cmsCloseProfile(input);
    return transform;
}

static cmsHTRANSFORM pixbuf_transform(GdkPixbuf *source) {
    const char *profile = gdk_pixbuf_get_option(source, "icc-profile");
    if (!profile) return NULL;
    gsize size;
    guchar *bytes = g_base64_decode(profile, &size);
    cmsHTRANSFORM result = srgb_transform(bytes, size, gdk_pixbuf_get_has_alpha(source));
    g_free(bytes);
    return result;
}

static int emit_pixbuf(Decode *d, GdkPixbuf *source, double duration, cmsHTRANSFORM transform) {
    if (!source) return fail(d, "Image loader did not produce a frame");
    GdkPixbuf *pixels = gdk_pixbuf_apply_embedded_orientation(source);
    if (!pixels) return fail(d, "Unable to orient decoded frame");
    int w = gdk_pixbuf_get_width(pixels);
    int h = gdk_pixbuf_get_height(pixels);
    fit(&w, &h, d->limit);
    uint64_t bytes = (uint64_t)w * h * 4;
    if (!valid_size((uint32_t)w, (uint32_t)h) || d->emitted_bytes > RUNE_IMAGE_MAX_BYTES - bytes) {
        g_object_unref(pixels);
        return fail(d, "Decoded image frames exceed size limit");
    }
    cmsHTRANSFORM local_transform = transform ? NULL : pixbuf_transform(source);
    if (local_transform) transform = local_transform;
    if (transform) {
        int src_w = gdk_pixbuf_get_width(pixels), src_h = gdk_pixbuf_get_height(pixels);
        GdkPixbuf *converted = gdk_pixbuf_new(GDK_COLORSPACE_RGB, gdk_pixbuf_get_has_alpha(pixels),
                                              8, src_w, src_h);
        if (converted) {
            cmsDoTransformLineStride(transform, gdk_pixbuf_read_pixels(pixels), gdk_pixbuf_get_pixels(converted),
                                     (cmsUInt32Number)src_w, (cmsUInt32Number)src_h,
                                     (cmsUInt32Number)gdk_pixbuf_get_rowstride(pixels),
                                     (cmsUInt32Number)gdk_pixbuf_get_rowstride(converted), 0, 0);
        }
        if (local_transform) cmsDeleteTransform(local_transform);
        g_object_unref(pixels);
        if (!converted) return fail(d, "Unable to allocate color-converted frame");
        pixels = converted;
    }
    if (w != gdk_pixbuf_get_width(pixels) || h != gdk_pixbuf_get_height(pixels)) {
        GdkPixbuf *scaled = gdk_pixbuf_scale_simple(pixels, w, h, GDK_INTERP_BILINEAR);
        g_object_unref(pixels);
        pixels = scaled;
    }
    if (pixels && !gdk_pixbuf_get_has_alpha(pixels)) {
        GdkPixbuf *rgba = gdk_pixbuf_add_alpha(pixels, FALSE, 0, 0, 0);
        g_object_unref(pixels);
        pixels = rgba;
    }
    if (!pixels) return fail(d, "Unable to allocate decoded frame");
    int ok = d->emit(d->context, (uint32_t)w, (uint32_t)h, gdk_pixbuf_read_pixels(pixels),
                     (size_t)gdk_pixbuf_get_rowstride(pixels), duration);
    g_object_unref(pixels);
    if (!ok) return fail(d, "Image consumer rejected decoded frame");
    d->emitted_bytes += bytes;
    return 1;
}

/* GdkPixbuf's animation iterator exposes presentation time but no frame count,
 * loop count or original delays. Read those from the GIF's length-delimited
 * blocks and let GdkPixbuf decode, dispose and composite the actual frames. */
static int gif_metadata(const uint8_t *p, size_t n, GArray *delays, uint32_t *loop_count,
                        size_t *first_frame_only, uint32_t limit) {
    if (n < 13) return 0;
    uint32_t w = p[6] | ((uint32_t)p[7] << 8);
    uint32_t h = p[8] | ((uint32_t)p[9] << 8);
    if (!valid_size(w, h)) return 0;
    int stored_w = (int)w, stored_h = (int)h;
    fit(&stored_w, &stored_h, limit);
    size_t pos = 13 + ((p[10] & 128) ? (size_t)3 << ((p[10] & 7) + 1) : 0);
    unsigned delay_ms = 100;
    size_t first_end = 0;
    while (pos < n) {
        const uint8_t marker = p[pos++];
        if (marker == 0x3b) return delays->len != 0;
        if (marker == 0x2c) {
            if (n - pos < 9) return 0;
            int packed = p[pos + 8];
            pos += 9;
            if (packed & 128) pos += (size_t)3 << ((packed & 7) + 1);
            if (pos >= n) return 0;
            ++pos; /* LZW code size */
            g_array_append_val(delays, delay_ms);
            if (first_end && !rune_image_animation_fits((uint32_t)stored_w, (uint32_t)stored_h, delays->len)) {
                *first_frame_only = first_end;
                g_array_set_size(delays, 1);
                return 1;
            }
            delay_ms = 100;
        } else if (marker == 0x21) {
            if (n - pos < 2) return 0;
            int label = p[pos++];
            if (label == 0xf9 && p[pos] == 4 && n - pos >= 5) {
                unsigned delay = p[pos + 2] | ((unsigned)p[pos + 3] << 8);
                delay_ms = delay ? delay * 10 : 100;
            } else if (label == 0xff && n - pos >= 16 && p[pos] == 11 &&
                       (!memcmp(p + pos + 1, "NETSCAPE2.0", 11) ||
                        !memcmp(p + pos + 1, "ANIMEXTS1.0", 11)) &&
                       p[pos + 12] == 3 && p[pos + 13] == 1) {
                *loop_count = p[pos + 14] | ((uint32_t)p[pos + 15] << 8);
            }
        } else {
            return 0;
        }
        for (;;) {
            if (pos >= n) return 0;
            size_t len = p[pos++];
            if (!len) break;
            if (len > n - pos) return 0;
            pos += len;
        }
        if (marker == 0x2c && !first_end) first_end = pos;
    }
    return 0;
}

G_GNUC_BEGIN_IGNORE_DEPRECATIONS /* GdkPixbufAnimationIter's public clock uses GTimeVal. */
static int emit_animation(Decode *d, GdkPixbufAnimation *animation, const GArray *delays) {
    GTimeVal wall_time = {0, 0};
    GdkPixbufAnimationIter *it = gdk_pixbuf_animation_get_iter(animation, &wall_time);
    int result = 1;
    for (guint i = 0; i < delays->len; ++i) {
        double duration = g_array_index(delays, unsigned, i) / 1000.0;
        result = emit_pixbuf(d, gdk_pixbuf_animation_iter_get_pixbuf(it), duration, NULL);
        if (!result || i + 1 == delays->len) break;
        /* Some GIF loaders clamp short delays. Use their clock to select the
         * next pixels, independently of the authored delay reported above. */
        int delay = gdk_pixbuf_animation_iter_get_delay_time(it);
        if (delay < 0) {
            result = fail(d, "GIF decoder stopped before its final frame");
            break;
        }
        g_time_val_add(&wall_time, MAX(delay, 1) * (glong)1000);
        gdk_pixbuf_animation_iter_advance(it, &wall_time);
    }
    g_object_unref(it);
    return result;
}
G_GNUC_END_IGNORE_DEPRECATIONS

static int decode_webp(Decode *d, const uint8_t *data, size_t size, uint32_t *loop_count) {
    WebPData encoded = {data, size};
    WebPDemuxer *demux = WebPDemux(&encoded);
    if (!demux) return fail(d, "Invalid WebP container");
    uint32_t w = WebPDemuxGetI(demux, WEBP_FF_CANVAS_WIDTH);
    uint32_t h = WebPDemuxGetI(demux, WEBP_FF_CANVAS_HEIGHT);
    uint32_t frames = WebPDemuxGetI(demux, WEBP_FF_FRAME_COUNT);
    uint32_t flags = WebPDemuxGetI(demux, WEBP_FF_FORMAT_FLAGS);
    *loop_count = flags & ANIMATION_FLAG ? WebPDemuxGetI(demux, WEBP_FF_LOOP_COUNT) : 0;
    WebPDemuxDelete(demux);
    if (!frames || !valid_size(w, h)) return fail(d, "Invalid WebP dimensions or empty animation");
    int stored_w = (int)w, stored_h = (int)h;
    fit(&stored_w, &stored_h, d->limit);
    if (!rune_image_animation_fits((uint32_t)stored_w, (uint32_t)stored_h, frames)) frames = 1;
    WebPAnimDecoder *decoder = WebPAnimDecoderNew(&encoded, NULL); /* MODE_RGBA */
    if (!decoder) return fail(d, "Unable to open WebP decoder");
    const WebPDemuxer *metadata = WebPAnimDecoderGetDemuxer(decoder);
    WebPChunkIterator chunk;
    char orientation[2] = {'1', 0};
    if (WebPDemuxGetChunk(metadata, "EXIF", 1, &chunk)) {
        orientation[0] = (char)('0' + rune_exif_orientation(chunk.chunk.bytes, chunk.chunk.size));
        WebPDemuxReleaseChunkIterator(&chunk);
    }
    cmsHTRANSFORM transform = NULL;
    if (WebPDemuxGetChunk(metadata, "ICCP", 1, &chunk)) {
        transform = srgb_transform(chunk.chunk.bytes, chunk.chunk.size, TRUE);
        WebPDemuxReleaseChunkIterator(&chunk);
    }
    int previous_ms = 0, result = 1;
    for (uint32_t i = 0; i < frames; ++i) {
        uint8_t *rgba = NULL;
        int timestamp = 0;
        if (!WebPAnimDecoderGetNext(decoder, &rgba, &timestamp) || timestamp < previous_ms) {
            result = fail(d, "Invalid WebP frame");
            break;
        }
        GdkPixbuf *frame = gdk_pixbuf_new_from_data(rgba, GDK_COLORSPACE_RGB, TRUE, 8,
                                                    (int)w, (int)h, (int)w * 4, NULL, NULL);
        if (frame && orientation[0] != '1') gdk_pixbuf_set_option(frame, "orientation", orientation);
        result = emit_pixbuf(d, frame, timestamp > previous_ms ? (timestamp - previous_ms) / 1000.0 : 0.1,
                             transform);
        if (frame) g_object_unref(frame);
        if (!result) break;
        previous_ms = timestamp;
    }
    if (transform) cmsDeleteTransform(transform);
    WebPAnimDecoderDelete(decoder);
    return result;
}

int rune_image_decode(const uint8_t *data, size_t size, uint32_t max_dimension,
                      uint32_t *loop_count, RuneImageEmit emit, void *context,
                      char *error, size_t error_size) {
    Decode d = {MIN(max_dimension, RUNE_IMAGE_MAX_SIDE), emit, context, error, error_size, 0, FALSE};
    if (!data || !size || !loop_count || !emit) return fail(&d, "Empty encoded image");
    *loop_count = 0;
    if (size >= 12 && !memcmp(data, "RIFF", 4) && !memcmp(data + 8, "WEBP", 4))
        return decode_webp(&d, data, size, loop_count);
    GArray *delays = NULL;
    size_t first_frame_only = 0;
    if (size >= 6 && (!memcmp(data, "GIF87a", 6) || !memcmp(data, "GIF89a", 6))) {
        *loop_count = UINT32_MAX;
        delays = g_array_new(FALSE, FALSE, sizeof(unsigned));
        if (!gif_metadata(data, size, delays, loop_count, &first_frame_only, d.limit)) {
            g_array_free(delays, TRUE);
            return fail(&d, "Invalid or oversized GIF");
        }
    }
    GdkPixbufLoader *loader = gdk_pixbuf_loader_new();
    g_signal_connect(loader, "size-prepared", G_CALLBACK(size_prepared), &d);
    GError *reason = NULL;
    gboolean written = gdk_pixbuf_loader_write(loader, data, first_frame_only ? first_frame_only : size, &reason);
    if (written && first_frame_only) {
        const uint8_t trailer = 0x3b;
        written = gdk_pixbuf_loader_write(loader, &trailer, 1, &reason);
    }
    gboolean closed = gdk_pixbuf_loader_close(loader, written ? &reason : NULL);
    int result;
    if (!written || !closed || d.invalid_size) {
        result = fail(&d, reason ? reason->message : "Invalid image dimensions");
    } else if (delays && delays->len > 1) {
        GdkPixbufAnimation *animation = gdk_pixbuf_loader_get_animation(loader);
        result = animation ? emit_animation(&d, animation, delays) : fail(&d, "Missing GIF frames");
    } else {
        double duration = delays ? g_array_index(delays, unsigned, 0) / 1000.0 : 0.1;
        result = emit_pixbuf(&d, gdk_pixbuf_loader_get_pixbuf(loader), duration, NULL);
    }
    g_clear_error(&reason);
    g_object_unref(loader);
    if (delays) g_array_free(delays, TRUE);
    return result;
}
#endif
