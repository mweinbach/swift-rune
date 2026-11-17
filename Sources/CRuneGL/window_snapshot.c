#include "gl_api.h"
#include <stdlib.h>
#include <string.h>

#define GL_READ_BUFFER 0x0C02
#define GL_PIXEL_PACK_BUFFER 0x88EB
#define GL_PIXEL_PACK_BUFFER_BINDING 0x88ED
#define GL_PACK_ALIGNMENT 0x0D05
#define GL_PACK_ROW_LENGTH 0x0D02
#define GL_PACK_SKIP_PIXELS 0x0D04
#define GL_PACK_SKIP_ROWS 0x0D03

int rune_gl_window_snapshot(RuneGLResolve resolve, int32_t x, int32_t y, int32_t width,
                            int32_t height, int32_t framebuffer_height, uint8_t *rgba, size_t capacity) {
    if (!resolve || !rgba || x < 0 || y < 0 || width <= 0 || height <= 0 ||
        x > INT32_MAX - width || height > framebuffer_height || y > framebuffer_height - height ||
        (uint64_t)width * height > capacity / 4) return 0;

    void (RUNE_GL_CALL *get)(GLenum, GLint *) = resolve("glGetIntegerv");
    GLenum (RUNE_GL_CALL *error)(void) = resolve("glGetError");
    const GLubyte *(RUNE_GL_CALL *get_string)(GLenum) = resolve("glGetString");
    void (RUNE_GL_CALL *bind_framebuffer)(GLenum, GLuint) = resolve("glBindFramebuffer");
    void (RUNE_GL_CALL *bind_buffer)(GLenum, GLuint) = resolve("glBindBuffer");
    void (RUNE_GL_CALL *pixel_store)(GLenum, GLint) = resolve("glPixelStorei");
    void (RUNE_GL_CALL *read_buffer)(GLenum) = resolve("glReadBuffer");
    void (RUNE_GL_CALL *read_pixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *) =
        resolve("glReadPixels");
    if (!get || !error || !get_string || !bind_framebuffer || !bind_buffer || !pixel_store ||
        !read_buffer || !read_pixels || !get_string(GL_VERSION)) return 0;

    size_t stride = (size_t)width * 4;
    uint8_t *row = height > 1 ? malloc(stride) : NULL;
    if (height > 1 && !row) return 0;
    GLint framebuffer, old_read_buffer, pack_buffer, alignment, row_length, skip_pixels, skip_rows;
    get(GL_READ_FRAMEBUFFER_BINDING, &framebuffer);
    bind_framebuffer(GL_READ_FRAMEBUFFER, 0);
    /* Each framebuffer retains its own read-buffer selection. */
    get(GL_READ_BUFFER, &old_read_buffer);
    get(GL_PIXEL_PACK_BUFFER_BINDING, &pack_buffer);
    get(GL_PACK_ALIGNMENT, &alignment);
    get(GL_PACK_ROW_LENGTH, &row_length);
    get(GL_PACK_SKIP_PIXELS, &skip_pixels);
    get(GL_PACK_SKIP_ROWS, &skip_rows);
    bind_buffer(GL_PIXEL_PACK_BUFFER, 0);
    pixel_store(GL_PACK_ALIGNMENT, 1);
    pixel_store(GL_PACK_ROW_LENGTH, 0);
    pixel_store(GL_PACK_SKIP_PIXELS, 0);
    pixel_store(GL_PACK_SKIP_ROWS, 0);
    read_buffer(GL_BACK);
    read_pixels(x, framebuffer_height - y - height, width, height, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    int success = error() == GL_NO_ERROR;
    read_buffer((GLenum)old_read_buffer);
    pixel_store(GL_PACK_ALIGNMENT, alignment);
    pixel_store(GL_PACK_ROW_LENGTH, row_length);
    pixel_store(GL_PACK_SKIP_PIXELS, skip_pixels);
    pixel_store(GL_PACK_SKIP_ROWS, skip_rows);
    bind_buffer(GL_PIXEL_PACK_BUFFER, (GLuint)pack_buffer);
    bind_framebuffer(GL_READ_FRAMEBUFFER, (GLuint)framebuffer);
    if (success) {
        for (int32_t i = 0; i < height / 2; ++i) {
            uint8_t *top = rgba + (size_t)i * stride;
            uint8_t *bottom = rgba + (size_t)(height - i - 1) * stride;
            memcpy(row, top, stride);
            memcpy(top, bottom, stride);
            memcpy(bottom, row, stride);
        }
    }
    free(row);
    return success;
}
