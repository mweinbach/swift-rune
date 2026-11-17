#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include "PresentInterop.h"
#include "include/CRuneWin32.h"
#include "LazyGL.h"
#include <wrl/client.h>
#include <new>
#include <utility>

using Microsoft::WRL::ComPtr;

namespace {
// Win32's system GL header ends at 1.1. These names are part of the required GL 3.3 core ABI.
constexpr GLenum framebuffer = 0x8D40, readFramebuffer = 0x8CA8, drawFramebuffer = 0x8CA9;
constexpr GLenum readBinding = 0x8CAA, drawBinding = 0x8CA6, complete = 0x8CD5;
constexpr GLenum renderbuffer = 0x8D41, renderbufferBinding = 0x8CA7, color0 = 0x8CE0;
constexpr GLenum rgba8 = 0x8058, framebufferSRGB = 0x8DB9, readWriteNV = 1;

template<typename T> T proc(const char *name) {
    return reinterpret_cast<T>(rune_win_gl_proc(name));
}

struct Functions {
    using Gen = void (APIENTRY *)(GLsizei, GLuint *);
    using Bind = void (APIENTRY *)(GLenum, GLuint);
    using Delete = void (APIENTRY *)(GLsizei, const GLuint *);
    using Lock = BOOL (WINAPI *)(HANDLE, GLint, HANDLE *);
    Gen genFB = proc<Gen>("glGenFramebuffers");
    Bind bindFB = proc<Bind>("glBindFramebuffer");
    Delete deleteFB = proc<Delete>("glDeleteFramebuffers");
    Gen genRB = proc<Gen>("glGenRenderbuffers");
    Bind bindRB = proc<Bind>("glBindRenderbuffer");
    Delete deleteRB = proc<Delete>("glDeleteRenderbuffers");
    using Storage = void (APIENTRY *)(GLenum, GLenum, GLsizei, GLsizei);
    Storage storage = proc<Storage>("glRenderbufferStorage");
    using Attach = void (APIENTRY *)(GLenum, GLenum, GLenum, GLuint);
    Attach attach = proc<Attach>("glFramebufferRenderbuffer");
    using Check = GLenum (APIENTRY *)(GLenum);
    Check check = proc<Check>("glCheckFramebufferStatus");
    using Blit = void (APIENTRY *)(GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum);
    Blit blit = proc<Blit>("glBlitFramebuffer");
    using Open = HANDLE (WINAPI *)(void *);
    Open open = proc<Open>("wglDXOpenDeviceNV");
    using Close = BOOL (WINAPI *)(HANDLE);
    Close close = proc<Close>("wglDXCloseDeviceNV");
    using Register = HANDLE (WINAPI *)(HANDLE, void *, GLuint, GLenum, GLenum);
    Register registerObject = proc<Register>("wglDXRegisterObjectNV");
    using Unregister = BOOL (WINAPI *)(HANDLE, HANDLE);
    Unregister unregisterObject = proc<Unregister>("wglDXUnregisterObjectNV");
    Lock lock = proc<Lock>("wglDXLockObjectsNV");
    Lock unlock = proc<Lock>("wglDXUnlockObjectsNV");

    bool available() const {
        return genFB && bindFB && deleteFB && genRB && bindRB && deleteRB && storage &&
               attach && check && blit && open && close && registerObject && unregisterObject && lock && unlock;
    }
};

struct FrameTarget {
    GLuint sourceFB = 0, sourceRB = 0, sharedFB = 0, sharedRB = 0;
    ComPtr<ID3D11Texture2D> texture;
    HANDLE object = nullptr;
    bool locked = false;
    bool initialized = false;
    int width = 0, height = 0;
};

struct SavedBindings {
    const Functions &gl;
    GLint read = 0, draw = 0, rb = 0;
    explicit SavedBindings(const Functions &gl) : gl(gl) {
        rune_lazy_glGetIntegerv(readBinding, &read);
        rune_lazy_glGetIntegerv(drawBinding, &draw);
        rune_lazy_glGetIntegerv(renderbufferBinding, &rb);
    }
    ~SavedBindings() {
        gl.bindFB(readFramebuffer, static_cast<GLuint>(read));
        gl.bindFB(drawFramebuffer, static_cast<GLuint>(draw));
        gl.bindRB(renderbuffer, static_cast<GLuint>(rb));
    }
};
}

struct RunePresentInterop {
    Functions gl;
    ComPtr<ID3D11Device> device;
    HGLRC owner = rune_lazy_wglGetCurrentContext();
    HANDLE interop = nullptr;
    FrameTarget target;
};

RunePresentInterop *rune_present_interop_create(ID3D11Device *device) {
    if (!device || !rune_lazy_wglGetCurrentContext() || !rune_win_shared_gl_available()) return nullptr;
    auto *p = new (std::nothrow) RunePresentInterop;
    if (!p) return nullptr;
    if (!p->gl.available() || !(p->interop = p->gl.open(device))) {
        delete p;
        return nullptr;
    }
    p->device = device;
    return p;
}

namespace {
bool unlock(RunePresentInterop &p, FrameTarget &t) {
    if (!p.gl.unlock(p.interop, 1, &t.object)) return false;
    t.locked = false;
    return true;
}

void releaseTarget(RunePresentInterop &p, FrameTarget &t) {
    if (t.locked) unlock(p, t);
    if (t.sourceFB) p.gl.deleteFB(1, &t.sourceFB);
    if (t.sharedFB) p.gl.deleteFB(1, &t.sharedFB);
    // A failed unlock can leave the driver holding its registration. In that case the
    // context owns the GL name until teardown; deleting it here could recycle a live name.
    bool unregistered = !t.object || p.gl.unregisterObject(p.interop, t.object);
    if (unregistered && t.sharedRB) p.gl.deleteRB(1, &t.sharedRB);
    if (t.sourceRB) p.gl.deleteRB(1, &t.sourceRB);
    t = {};
}

bool allocateTarget(RunePresentInterop &p, FrameTarget &t, int width, int height) {
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = static_cast<UINT>(width);
    desc.Height = static_cast<UINT>(height);
    desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    if (FAILED(p.device->CreateTexture2D(&desc, nullptr, &t.texture))) return false;

    const auto &gl = p.gl;
    SavedBindings saved(gl);
    gl.genFB(1, &t.sourceFB);
    gl.genRB(1, &t.sourceRB);
    if (!t.sourceFB || !t.sourceRB) return false;
    gl.bindFB(framebuffer, t.sourceFB);
    gl.bindRB(renderbuffer, t.sourceRB);
    gl.storage(renderbuffer, rgba8, width, height);
    gl.attach(framebuffer, color0, renderbuffer, t.sourceRB);
    if (gl.check(framebuffer) != complete) return false;

    gl.genFB(1, &t.sharedFB);
    gl.genRB(1, &t.sharedRB);
    if (!t.sharedFB || !t.sharedRB) return false;
    // This texture belongs to the same D3D11 device as the swap chain. NV's lock and
    // unlock synchronize access between GL and that device.
    t.object = gl.registerObject(p.interop, t.texture.Get(), t.sharedRB, renderbuffer, readWriteNV);
    if (!t.object || !gl.lock(p.interop, 1, &t.object)) return false;
    t.locked = true;
    gl.bindFB(framebuffer, t.sharedFB);
    gl.attach(framebuffer, color0, renderbuffer, t.sharedRB);
    bool ready = gl.check(framebuffer) == complete && rune_lazy_glGetError() == GL_NO_ERROR;
    gl.bindFB(framebuffer, t.sourceFB);
    if (!unlock(p, t) || !ready) return false;
    t.width = width;
    t.height = height;
    return true;
}

// The ordinary target has the WGL back buffer's orientation. D3D texture row 0 is the top,
// so the interop blit inverts Y once. Copying to the WGL back buffer uses identical coordinates.
bool copyPixels(const Functions &gl, const FrameTarget &t, GLuint destination, const RECT *rects,
                unsigned count, bool flip) {
    GLint previousRead = 0, previousDraw = 0;
    rune_lazy_glGetIntegerv(readBinding, &previousRead);
    rune_lazy_glGetIntegerv(drawBinding, &previousDraw);
    GLboolean scissor = rune_lazy_glIsEnabled(GL_SCISSOR_TEST), srgb = rune_lazy_glIsEnabled(framebufferSRGB);
    if (scissor) rune_lazy_glDisable(GL_SCISSOR_TEST);
    if (srgb) rune_lazy_glDisable(framebufferSRGB);
    gl.bindFB(readFramebuffer, t.sourceFB);
    gl.bindFB(drawFramebuffer, destination);
    GLint readBuffer = 0, drawBuffer = 0;
    rune_lazy_glGetIntegerv(GL_READ_BUFFER, &readBuffer);
    rune_lazy_glGetIntegerv(GL_DRAW_BUFFER, &drawBuffer);
    rune_lazy_glReadBuffer(color0);
    rune_lazy_glDrawBuffer(destination ? color0 : GL_BACK);
    for (unsigned i = 0; i < count; ++i) {
        const RECT &r = rects[i];
        GLint bottom = t.height - r.bottom, top = t.height - r.top;
        gl.blit(r.left, bottom, r.right, top, r.left, flip ? r.bottom : bottom,
                r.right, flip ? r.top : top, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    }
    bool copied = rune_lazy_glGetError() == GL_NO_ERROR;
    rune_lazy_glReadBuffer(static_cast<GLenum>(readBuffer));
    rune_lazy_glDrawBuffer(static_cast<GLenum>(drawBuffer));
    gl.bindFB(readFramebuffer, static_cast<GLuint>(previousRead));
    gl.bindFB(drawFramebuffer, static_cast<GLuint>(previousDraw));
    if (srgb) rune_lazy_glEnable(framebufferSRGB);
    if (scissor) rune_lazy_glEnable(GL_SCISSOR_TEST);
    return copied;
}
}

bool rune_present_interop_resize(RunePresentInterop *p, int width, int height) {
    if (!p || rune_lazy_wglGetCurrentContext() != p->owner || width <= 0 || height <= 0) return false;
    if (p->target.width == width && p->target.height == height) return true;
    FrameTarget replacement;
    if (!allocateTarget(*p, replacement, width, height)) {
        releaseTarget(*p, replacement);
        // An incomplete allocation can leave multiple error flags (e.g. OUT_OF_MEMORY).
        // Consume them at this boundary so a healthy WGL fallback can render its first frame.
        for (int i = 0; i < 8 && rune_lazy_glGetError() != GL_NO_ERROR; ++i) {}
        return false;
    }
    releaseTarget(*p, p->target);
    p->target = std::move(replacement);
    return true;
}

void rune_present_interop_bind(RunePresentInterop *p) {
    if (p && p->target.sourceFB && rune_lazy_wglGetCurrentContext() == p->owner)
        p->gl.bindFB(framebuffer, p->target.sourceFB);
}

ID3D11Texture2D *rune_present_interop_copy(RunePresentInterop *p, const RECT *dirty, unsigned count) {
    if (!p || !p->target.object || rune_lazy_wglGetCurrentContext() != p->owner || (count && !dirty)) return nullptr;
    FrameTarget &t = p->target;
    RECT full{0, 0, t.width, t.height};
    if (!t.initialized || !count) { dirty = &full; count = 1; }
    for (unsigned i = 0; i < count; ++i) {
        const RECT &r = dirty[i];
        if (r.left < 0 || r.top < 0 || r.right > t.width || r.bottom > t.height ||
            r.right <= r.left || r.bottom <= r.top) return nullptr;
    }
    if (t.locked || !p->gl.lock(p->interop, 1, &t.object)) return nullptr;
    t.locked = true;
    bool copied = copyPixels(p->gl, t, t.sharedFB, dirty, count, true);
    t.initialized = unlock(*p, t) && copied;
    if (!t.initialized) return nullptr;
    return t.texture.Get();
}

void rune_present_interop_fallback(RunePresentInterop *p) {
    if (!p || !p->target.sourceFB || rune_lazy_wglGetCurrentContext() != p->owner) return;
    RECT full{0, 0, p->target.width, p->target.height};
    copyPixels(p->gl, p->target, 0, &full, 1, false);
}

void rune_present_interop_destroy(RunePresentInterop *p, bool current) {
    if (!p) return;
    if (current && rune_lazy_wglGetCurrentContext() == p->owner) {
        releaseTarget(*p, p->target);
        p->gl.close(p->interop);
    }
    delete p;
}
#endif
