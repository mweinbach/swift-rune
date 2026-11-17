#ifdef _WIN32
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincodec.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "CRuneDesktopImages.h"
#include "ExifOrientation.h"

typedef struct {
    const BYTE *icc;
    UINT icc_size;
    UINT orientation;
    int is_webp;
} ImageMetadata;

typedef struct {
    IWICImagingFactory *factory;
    RuneImageEmit emit;
    void *context;
    UINT limit;
    size_t emitted_bytes;
} Output;

static UINT metadata_uint(IWICMetadataQueryReader *metadata, const WCHAR *path, UINT fallback) {
    PROPVARIANT value;
    PropVariantInit(&value);
    UINT result = fallback;
    if (metadata && SUCCEEDED(IWICMetadataQueryReader_GetMetadataByName(metadata, path, &value))) {
        switch (value.vt) {
            case VT_BOOL: result = value.boolVal != VARIANT_FALSE; break;
            case VT_UI1: result = value.bVal; break;
            case VT_UI2: result = value.uiVal; break;
            case VT_UI4: result = value.ulVal; break;
        }
    }
    PropVariantClear(&value);
    return result;
}

static int valid_size(UINT w, UINT h) {
    return w && h && w <= RUNE_IMAGE_MAX_SIDE && h <= RUNE_IMAGE_MAX_SIDE &&
           (uint64_t)w * h * 4 <= RUNE_IMAGE_MAX_BYTES;
}

static void fit_inside(UINT *w, UINT *h, UINT limit) {
    const UINT longest = *w > *h ? *w : *h;
    if (limit && longest > limit) {
        const UINT fitted_width = (UINT)(((uint64_t)*w * limit + longest / 2) / longest);
        const UINT fitted_height = (UINT)(((uint64_t)*h * limit + longest / 2) / longest);
        *w = fitted_width ? fitted_width : 1;
        *h = fitted_height ? fitted_height : 1;
    }
}

static UINT retained_frame_count(UINT w, UINT h, UINT limit, UINT count) {
    fit_inside(&w, &h, limit);
    return rune_image_animation_fits(w, h, count) ? count : 1;
}

static HRESULT emit_source(Output *out, IWICBitmapSource *source, double delay) {
    IWICBitmapScaler *scaler = NULL;
    IWICBitmapSource *premultiplied = NULL, *rgba = NULL;
    UINT w, h;
    HRESULT hr = IWICBitmapSource_GetSize(source, &w, &h);
    if (FAILED(hr)) return hr;
    if (!w || !h) return WINCODEC_ERR_BADIMAGE;
    const UINT longest = w > h ? w : h;
    fit_inside(&w, &h, out->limit);
    if (!valid_size(w, h)) return WINCODEC_ERR_IMAGESIZEOUTOFRANGE;
    const UINT bytes = w * h * 4;
    if (out->emitted_bytes > RUNE_IMAGE_MAX_BYTES - bytes) return WINCODEC_ERR_IMAGESIZEOUTOFRANGE;
    if (out->limit && longest > out->limit) {
        // Interpolate premultiplied color to preserve the edges of translucent images.
        hr = WICConvertBitmapSource(&GUID_WICPixelFormat32bppPBGRA, source, &premultiplied);
        if (SUCCEEDED(hr)) hr = IWICImagingFactory_CreateBitmapScaler(out->factory, &scaler);
        if (SUCCEEDED(hr)) hr = IWICBitmapScaler_Initialize(scaler, premultiplied, w, h, WICBitmapInterpolationModeFant);
        source = (IWICBitmapSource *)scaler;
    }
    if (SUCCEEDED(hr)) hr = WICConvertBitmapSource(&GUID_WICPixelFormat32bppRGBA, source, &rgba);
    if (SUCCEEDED(hr)) {
        BYTE *pixels = malloc(bytes);
        if (pixels) {
            hr = IWICBitmapSource_CopyPixels(rgba, NULL, w * 4, bytes, pixels);
            if (SUCCEEDED(hr) && !out->emit(out->context, w, h, pixels, w * 4, delay)) hr = E_ABORT;
            free(pixels);
        } else hr = E_OUTOFMEMORY;
    }
    if (rgba) IWICBitmapSource_Release(rgba);
    if (scaler) IWICBitmapScaler_Release(scaler);
    if (premultiplied) IWICBitmapSource_Release(premultiplied);
    if (SUCCEEDED(hr)) out->emitted_bytes += bytes;
    return hr;
}

static IWICColorTransform *srgb_transform(IWICImagingFactory *factory, IWICBitmapFrameDecode *frame,
                                          const ImageMetadata *container) {
    UINT count = 0;
    if (container->is_webp && !container->icc) return NULL;
    if (!container->icc && (FAILED(IWICBitmapFrameDecode_GetColorContexts(frame, 0, NULL, &count)) || !count))
        return NULL;
    IWICColorContext *embedded = NULL, *srgb = NULL;
    IWICColorTransform *transform = NULL;
    HRESULT hr = IWICImagingFactory_CreateColorContext(factory, &embedded);
    if (SUCCEEDED(hr)) {
        if (container->icc) hr = IWICColorContext_InitializeFromMemory(embedded, container->icc, container->icc_size);
        else hr = IWICBitmapFrameDecode_GetColorContexts(frame, 1, &embedded, &count);
    }
    WICColorContextType type;
    UINT space;
    if (SUCCEEDED(hr) && SUCCEEDED(IWICColorContext_GetType(embedded, &type)) && type == WICColorContextExifColorSpace &&
        SUCCEEDED(IWICColorContext_GetExifColorSpace(embedded, &space)) && space == 1) {
        IWICColorContext_Release(embedded);
        return NULL;
    }
    if (SUCCEEDED(hr)) hr = IWICImagingFactory_CreateColorContext(factory, &srgb);
    if (SUCCEEDED(hr)) hr = IWICColorContext_InitializeFromExifColorSpace(srgb, 1);
    if (SUCCEEDED(hr)) hr = IWICImagingFactory_CreateColorTransformer(factory, &transform);
    if (SUCCEEDED(hr)) hr = IWICColorTransform_Initialize(transform, (IWICBitmapSource *)frame,
                                                          embedded, srgb, &GUID_WICPixelFormat64bppRGBA);
    if (srgb) IWICColorContext_Release(srgb);
    if (embedded) IWICColorContext_Release(embedded);
    if (FAILED(hr) && transform) {
        IWICColorTransform_Release(transform);
        transform = NULL;
    }
    return transform;
}

static HRESULT emit_still(Output *out, IWICBitmapFrameDecode *frame, IWICMetadataQueryReader *metadata,
                          const ImageMetadata *container, double delay) {
    UINT orientation = container->orientation;
    if (!orientation) orientation = metadata_uint(metadata, L"/app1/ifd/{ushort=274}", 0);
    if (!orientation) orientation = metadata_uint(metadata, L"/ifd/{ushort=274}", 1);
    // Apply the EXIF raster-to-display transform before calculating the final size.
    static const WICBitmapTransformOptions transforms[] = {
        WICBitmapTransformRotate0, WICBitmapTransformRotate0, WICBitmapTransformFlipHorizontal,
        WICBitmapTransformRotate180, WICBitmapTransformFlipVertical,
        WICBitmapTransformRotate270 | WICBitmapTransformFlipHorizontal,
        WICBitmapTransformRotate90, WICBitmapTransformRotate90 | WICBitmapTransformFlipHorizontal,
        WICBitmapTransformRotate270
    };
    IWICColorTransform *color = srgb_transform(out->factory, frame, container);
    IWICBitmapSource *source = color ? (IWICBitmapSource *)color : (IWICBitmapSource *)frame;
    IWICBitmapFlipRotator *rotator = NULL;
    HRESULT hr = S_OK;
    if (orientation >= 2 && orientation <= 8) {
        hr = IWICImagingFactory_CreateBitmapFlipRotator(out->factory, &rotator);
        if (SUCCEEDED(hr)) hr = IWICBitmapFlipRotator_Initialize(rotator, source, transforms[orientation]);
        source = (IWICBitmapSource *)rotator;
    }
    if (SUCCEEDED(hr)) hr = emit_source(out, source, delay);
    if (rotator) IWICBitmapFlipRotator_Release(rotator);
    if (color) IWICColorTransform_Release(color);
    return hr;
}

// WIC's WebP decoder supplies decoded frames; RIFF supplies their playback metadata.
typedef struct {
    const BYTE *bytes;
    size_t offset, end;
} WebPChunks;

static uint32_t read_le32(const BYTE *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static const BYTE *next_webp_chunk(WebPChunks *chunks, const char *type, size_t minimum) {
    while (chunks->end - chunks->offset >= 8) {
        const BYTE *chunk = chunks->bytes + chunks->offset;
        uint32_t size = read_le32(chunk + 4);
        uint64_t padded = (uint64_t)size + (size & 1);
        chunks->offset += 8;
        if (padded > chunks->end - chunks->offset) {
            chunks->offset = chunks->end;
            break;
        }
        chunks->offset += (size_t)padded;
        if (size >= minimum && !memcmp(chunk, type, 4)) return chunk + 8;
    }
    return NULL;
}

static WebPChunks webp_chunks(const BYTE *bytes, size_t size) {
    WebPChunks result = {0};
    if (size >= 12 && !memcmp(bytes, "RIFF", 4) && !memcmp(bytes + 8, "WEBP", 4)) {
        uint64_t end = (uint64_t)read_le32(bytes + 4) + 8;
        if (end >= 12 && end <= size) {
            result.bytes = bytes;
            result.offset = 12;
            result.end = (size_t)end;
        }
    }
    return result;
}

typedef struct {
    UINT width, height;
    uint32_t *pixels;
    uint32_t background;
    int initialized;
} GifCanvas;

static uint32_t gif_repetitions(IWICMetadataQueryReader *reader) {
    // The Netscape loop extension may follow an unrelated application block.
    for (UINT index = 0; ; ++index) {
        WCHAR query[64];
        PROPVARIANT app;
        PropVariantInit(&app);
        swprintf(query, 64, L"/[%u]appext/Application", index);
        HRESULT hr = IWICMetadataQueryReader_GetMetadataByName(reader, query, &app);
        int loop_block = SUCCEEDED(hr) && app.vt == (VT_VECTOR | VT_UI1) && app.caub.cElems == 11 &&
                (!memcmp(app.caub.pElems, "NETSCAPE2.0", 11) || !memcmp(app.caub.pElems, "ANIMEXTS1.0", 11));
        PropVariantClear(&app);
        if (FAILED(hr)) return UINT32_MAX;
        if (loop_block) {
            PROPVARIANT data;
            PropVariantInit(&data);
            swprintf(query, 64, L"/[%u]appext/Data", index);
            uint32_t loops = UINT32_MAX;
            if (SUCCEEDED(IWICMetadataQueryReader_GetMetadataByName(reader, query, &data)) &&
                data.vt == (VT_VECTOR | VT_UI1) && data.caub.cElems >= 4 &&
                data.caub.pElems[0] == 3 && data.caub.pElems[1] == 1) {
                loops = data.caub.pElems[2] | ((uint32_t)data.caub.pElems[3] << 8);
            }
            PropVariantClear(&data);
            return loops;
        }
    }
}

static void read_gif_header(IWICImagingFactory *factory, IWICBitmapDecoder *decoder,
                            GifCanvas *canvas, uint32_t *loops) {
    *loops = UINT32_MAX;
    IWICMetadataQueryReader *reader = NULL;
    if (FAILED(IWICBitmapDecoder_GetMetadataQueryReader(decoder, &reader))) return;
    canvas->width = metadata_uint(reader, L"/logscrdesc/Width", 0);
    canvas->height = metadata_uint(reader, L"/logscrdesc/Height", 0);
    UINT index = metadata_uint(reader, L"/logscrdesc/BackgroundColorIndex", 256);
    IWICPalette *palette = NULL;
    if (index < 256 && SUCCEEDED(IWICImagingFactory_CreatePalette(factory, &palette))) {
        WICColor colors[256];
        UINT count = 0;
        if (SUCCEEDED(IWICBitmapDecoder_CopyPalette(decoder, palette)) &&
            SUCCEEDED(IWICPalette_GetColors(palette, 256, colors, &count)) && index < count) {
            uint32_t argb = colors[index];
            canvas->background = 0xff000000 | ((argb & 255) << 16) | (argb & 0xff00) | ((argb >> 16) & 255);
        }
        IWICPalette_Release(palette);
    }
    *loops = gif_repetitions(reader);
    IWICMetadataQueryReader_Release(reader);
}

static HRESULT emit_gif_frame(Output *out, GifCanvas *canvas, IWICBitmapFrameDecode *frame,
                              IWICMetadataQueryReader *reader) {
    UINT w, h;
    HRESULT hr = IWICBitmapFrameDecode_GetSize(frame, &w, &h);
    if (FAILED(hr)) return hr;
    UINT x = metadata_uint(reader, L"/imgdesc/Left", 0);
    UINT y = metadata_uint(reader, L"/imgdesc/Top", 0);
    UINT disposal = metadata_uint(reader, L"/grctlext/Disposal", 0);
    UINT delay = metadata_uint(reader, L"/grctlext/Delay", 0);
    const uint32_t background = metadata_uint(reader, L"/grctlext/TransparencyFlag", 0) ? 0 : canvas->background;
    if (x >= canvas->width || y >= canvas->height || !valid_size(w, h) ||
        w > canvas->width - x || h > canvas->height - y) return WINCODEC_ERR_BADIMAGE;
    if (!canvas->initialized) {
        if (background) {
            for (size_t i = 0; i < (size_t)canvas->width * canvas->height; ++i) canvas->pixels[i] = background;
        }
        canvas->initialized = 1;
    }
    const UINT bytes = w * h * 4;
    uint32_t *patch = malloc(bytes);
    uint32_t *saved = disposal == 3 ? malloc(bytes) : NULL;
    IWICBitmapSource *rgba = NULL;
    IWICBitmap *composite = NULL;
    if (!patch || (disposal == 3 && !saved)) hr = E_OUTOFMEMORY;
    if (SUCCEEDED(hr)) hr = WICConvertBitmapSource(&GUID_WICPixelFormat32bppRGBA, (IWICBitmapSource *)frame, &rgba);
    if (SUCCEEDED(hr)) hr = IWICBitmapSource_CopyPixels(rgba, NULL, w * 4, bytes, (BYTE *)patch);
    if (SUCCEEDED(hr)) {
        for (UINT row = 0; row < h; ++row) {
            uint32_t *dst = canvas->pixels + (y + row) * canvas->width + x;
            const uint32_t *src = patch + row * w;
            if (saved) memcpy(saved + row * w, dst, w * 4);
            for (UINT col = 0; col < w; ++col) if (src[col] >> 24) dst[col] = src[col];
        }
        if (!out->limit || (canvas->width <= out->limit && canvas->height <= out->limit)) {
            const size_t full_bytes = (size_t)canvas->width * canvas->height * 4;
            if (out->emitted_bytes > RUNE_IMAGE_MAX_BYTES - full_bytes) hr = WINCODEC_ERR_IMAGESIZEOUTOFRANGE;
            else if (!out->emit(out->context, canvas->width, canvas->height, (BYTE *)canvas->pixels,
                                canvas->width * 4, delay ? delay * 0.01 : 0.1)) hr = E_ABORT;
            else out->emitted_bytes += full_bytes;
        } else {
            hr = IWICImagingFactory_CreateBitmapFromMemory(out->factory, canvas->width, canvas->height,
                    &GUID_WICPixelFormat32bppRGBA, canvas->width * 4, canvas->width * canvas->height * 4,
                    (BYTE *)canvas->pixels, &composite);
            if (SUCCEEDED(hr)) hr = emit_source(out, (IWICBitmapSource *)composite, delay ? delay * 0.01 : 0.1);
        }
        // Disposal applies to just the subframe before the next frame is drawn.
        for (UINT row = 0; (disposal == 2 || disposal == 3) && row < h; ++row) {
            uint32_t *dst = canvas->pixels + (y + row) * canvas->width + x;
            if (saved) memcpy(dst, saved + row * w, w * 4);
            else for (UINT col = 0; col < w; ++col) dst[col] = background;
        }
    }
    if (composite) IWICBitmap_Release(composite);
    if (rgba) IWICBitmapSource_Release(rgba);
    free(saved);
    free(patch);
    return hr;
}

int rune_image_decode(const uint8_t *data, size_t size, uint32_t max_dimension, uint32_t *loop_count,
                      RuneImageEmit emit, void *context, char *error, size_t error_size) {
    HRESULT apartment = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    HRESULT hr = apartment == RPC_E_CHANGED_MODE ? S_OK : apartment;
    IWICImagingFactory *factory = NULL;
    IWICStream *stream = NULL;
    IWICBitmapDecoder *decoder = NULL;
    GifCanvas canvas = {0};
    if (SUCCEEDED(hr) && (!data || !size || size > UINT32_MAX || !emit || !loop_count)) hr = E_INVALIDARG;
    if (SUCCEEDED(hr)) hr = CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER,
                                            &IID_IWICImagingFactory, (void **)&factory);
    if (SUCCEEDED(hr)) hr = IWICImagingFactory_CreateStream(factory, &stream);
    if (SUCCEEDED(hr)) hr = IWICStream_InitializeFromMemory(stream, (BYTE *)data, (DWORD)size);
    if (SUCCEEDED(hr)) hr = IWICImagingFactory_CreateDecoderFromStream(factory, (IStream *)stream, NULL,
                                                                        WICDecodeMetadataCacheOnDemand, &decoder);
    GUID format;
    UINT count = 0;
    if (SUCCEEDED(hr)) hr = IWICBitmapDecoder_GetContainerFormat(decoder, &format);
    if (SUCCEEDED(hr)) hr = IWICBitmapDecoder_GetFrameCount(decoder, &count);
    if (SUCCEEDED(hr) && !count) hr = WINCODEC_ERR_FRAMEMISSING;
    const int gif = SUCCEEDED(hr) && IsEqualGUID(&format, &GUID_ContainerFormatGif);
    if (loop_count) *loop_count = 0;
    WebPChunks webp = {0};
    ImageMetadata container = {0};
    if (SUCCEEDED(hr)) {
        webp = webp_chunks(data, size);
        WebPChunks profile_chunks = webp;
        container.is_webp = webp.bytes != NULL;
        container.icc = next_webp_chunk(&profile_chunks, "ICCP", 1);
        if (container.icc) container.icc_size = read_le32(container.icc - 4);
        WebPChunks exif_chunks = webp;
        const BYTE *animation = next_webp_chunk(&webp, "ANIM", 6);
        if (animation) {
            *loop_count = animation[4] | ((uint32_t)animation[5] << 8);
            const BYTE *exif = next_webp_chunk(&exif_chunks, "EXIF", 8);
            if (exif) container.orientation = rune_exif_orientation(exif, read_le32(exif - 4));
        }
    }
    if (gif) {
        read_gif_header(factory, decoder, &canvas, loop_count);
        if (!valid_size(canvas.width, canvas.height)) hr = WINCODEC_ERR_IMAGESIZEOUTOFRANGE;
        else {
            count = retained_frame_count(canvas.width, canvas.height, max_dimension, count);
            canvas.pixels = calloc((size_t)canvas.width * canvas.height, 4);
            if (!canvas.pixels) hr = E_OUTOFMEMORY;
        }
    }
    Output out = {factory, emit, context, max_dimension, 0};
    for (UINT i = 0; SUCCEEDED(hr) && i < count; ++i) {
        IWICBitmapFrameDecode *frame = NULL;
        IWICMetadataQueryReader *metadata = NULL;
        hr = IWICBitmapDecoder_GetFrame(decoder, i, &frame);
        if (SUCCEEDED(hr) && !gif && i == 0 && count > 1) {
            UINT w, h;
            hr = IWICBitmapFrameDecode_GetSize(frame, &w, &h);
            if (SUCCEEDED(hr)) count = retained_frame_count(w, h, max_dimension, count);
        }
        if (SUCCEEDED(hr)) {
            IWICBitmapFrameDecode_GetMetadataQueryReader(frame, &metadata);
            if (gif) {
                hr = emit_gif_frame(&out, &canvas, frame, metadata);
            } else {
                const BYTE *animation_frame = next_webp_chunk(&webp, "ANMF", 16);
                uint32_t delay_ms = animation_frame ? read_le32(animation_frame + 12) & 0x00ffffff : 0;
                hr = emit_still(&out, frame, metadata, &container, delay_ms ? delay_ms / 1000.0 : 0.1);
            }
        }
        if (metadata) IWICMetadataQueryReader_Release(metadata);
        if (frame) IWICBitmapFrameDecode_Release(frame);
    }
    free(canvas.pixels);
    if (decoder) IWICBitmapDecoder_Release(decoder);
    if (stream) IWICStream_Release(stream);
    if (factory) IWICImagingFactory_Release(factory);
    if (SUCCEEDED(apartment)) CoUninitialize();
    if (FAILED(hr) && error && error_size) {
        const char *message = "Windows Imaging Component could not decode the image";
        if (hr == WINCODEC_ERR_COMPONENTNOTFOUND || hr == WINCODEC_ERR_UNKNOWNIMAGEFORMAT)
            message = "No installed Windows Imaging Component codec recognized the image";
        else if (hr == WINCODEC_ERR_IMAGESIZEOUTOFRANGE)
            message = "Image exceeds Rune's decoded dimensions or animation byte limit";
        else if (hr == E_ABORT)
            message = "Rune rejected a decoded image frame";
        snprintf(error, error_size, "%s (0x%08lx)", message, (unsigned long)hr);
    }
    return SUCCEEDED(hr);
}
#endif
