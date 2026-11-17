#pragma once
#ifdef _WIN32
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

struct RuneMedia;
struct RuneMediaInfo;
typedef struct RuneMediaPicture RuneMediaPicture;
typedef struct RunePictureInfo {
    uint32_t width, height, natural_width;
    int full_range, bt709;
} RunePictureInfo;

/* Opens a live player on the renderer's adapter. A null LUID uses the default adapter.
   Software decoding, and finally the legacy RGB path, remain available on unsupported systems. */
struct RuneMedia *rune_media_open_video(const char *uri, const int64_t *adapter_luid,
                                        struct RuneMediaInfo *info, RunePictureInfo *picture,
                                        char *error, size_t capacity);
/* Headless Rune surfaces use deterministic CPU-decoded NV12 and the same track geometry. */
struct RuneMedia *rune_media_open_still(const char *uri, struct RuneMediaInfo *info, RunePictureInfo *picture,
                                        char *error, size_t capacity);
/* 1 transfers an NV12 picture; 0 means no new picture/free slot; 2 selects
   rune_media_frame for a legacy RGB reader; -1 reports an error. If retaining_time
   is nonnegative the caller already owns the picture at that sample PTS. */
int rune_media_picture(struct RuneMedia *media, double seconds, double retaining_time, RuneMediaPicture **picture,
                       char *error, size_t capacity);
/* A non-null texture is an immutable subresource-zero ID3D11Texture2D. Software
   decoder output additionally exposes packed Y followed by UV via rune_media_picture_bytes. */
void *rune_media_picture_texture(const RuneMediaPicture *picture);
/* True if MF delivered an IMFDXGIBuffer and the decoder picture was copied entirely on its D3D device. */
int rune_media_picture_dxgi_source(const RuneMediaPicture *picture);
const uint8_t *rune_media_picture_bytes(const RuneMediaPicture *picture);
void rune_media_picture_release(RuneMediaPicture *picture);
/* Timestamp of the most recent delivered sample, negative before the first. */
double rune_media_last_picture_time(const struct RuneMedia *media);
#ifdef __cplusplus
}
#endif
#endif
