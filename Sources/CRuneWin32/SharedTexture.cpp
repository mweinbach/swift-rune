#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <d3d11_4.h>
#include <d3d12.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include "LazyGL.h"
#include <mutex>
#include <new>
#include <cstdio>
#include <cstring>
#include "include/CRuneWin32.h"
#include "D3DTextureBlit.h"
#include "AdapterPicker.hpp"

using Microsoft::WRL::ComPtr;

struct RuneWinSharedFrame {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11Texture2D> image;
    D3D11_TEXTURE2D_DESC desc{};
};

namespace {
std::mutex deviceLock;
HMONITOR windowMonitor;
LUID windowLuid{};
bool hasWindowLuid;
ComPtr<IDXGIAdapter1> adapter;
ComPtr<ID3D11Device1> device;
ComPtr<ID3D11DeviceContext> context;
ComPtr<ID3D12Device> handleOpener;

template<typename T> T entry(const wchar_t *library, const char *name) {
    HMODULE module = LoadLibraryExW(library, nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    return module ? reinterpret_cast<T>(GetProcAddress(module, name)) : nullptr;
}

int fail(char *message, size_t capacity, const char *operation, HRESULT hr) {
    if (message && capacity) std::snprintf(message, capacity, "%s (HRESULT 0x%08lx)", operation, (unsigned long)hr);
    return 0;
}

template<typename T> T glProc(const char *name) {
    return reinterpret_cast<T>(rune_win_gl_proc(name));
}

bool hasGLExtension(const char *name) {
    auto getString = glProc<const GLubyte *(APIENTRY *)(GLenum, GLuint)>("glGetStringi");
    if (!getString) return false;
    GLint count = 0;
    rune_lazy_glGetIntegerv(0x821D /* NUM_EXTENSIONS */, &count);
    for (GLint i = 0; i < count; ++i) {
        const auto value = reinterpret_cast<const char *>(getString(GL_EXTENSIONS, i));
        if (value && !std::strcmp(value, name)) return true;
    }
    return false;
}

void forgetDevice() {
    context.Reset();
    device.Reset();
    handleOpener.Reset();
    adapter.Reset();
}

HRESULT selectAdapter() {
    if (adapter && (!device || SUCCEEDED(device->GetDeviceRemovedReason()))) return S_OK;
    forgetDevice();
    static const auto create = entry<decltype(&CreateDXGIFactory1)>(L"dxgi.dll", "CreateDXGIFactory1");
    if (!create) return E_NOINTERFACE;
    ComPtr<IDXGIFactory1> factory;
    HRESULT hr = create(IID_PPV_ARGS(&factory));
    if (FAILED(hr)) return hr;
    bool presented = windowMonitor != nullptr;
    const char *reason = nullptr;
    return RuneAdapterPicker::choose(factory.Get(), hasWindowLuid ? &windowLuid : nullptr, presented, adapter, reason, windowMonitor);
}

HRESULT getDevice() {
    HRESULT hr = selectAdapter();
    if (FAILED(hr) || device) return hr;
    static const auto create = entry<decltype(&D3D11CreateDevice)>(L"d3d11.dll", "D3D11CreateDevice");
    if (!create) return E_NOINTERFACE;
    ComPtr<ID3D11Device> base;
    hr = create(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                nullptr, 0, D3D11_SDK_VERSION, &base, nullptr, &context);
    if (SUCCEEDED(hr)) {
        hr = base.As(&device);
        // In addition to Rune's queue lock the WGL driver may enter this device from its own worker.
        ComPtr<ID3D11Multithread> multithread;
        if (SUCCEEDED(base.As(&multithread))) multithread->SetMultithreadProtected(TRUE);
    }
    return hr;
}

HRESULT openFence(const wchar_t *name, ID3D11Fence **result) {
    if (!handleOpener) {
        static const auto create = entry<decltype(&D3D12CreateDevice)>(L"d3d12.dll", "D3D12CreateDevice");
        if (!create) return E_NOINTERFACE;
        HRESULT hr = create(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&handleOpener));
        if (FAILED(hr)) return hr;
    }
    ComPtr<ID3D11Device5> dev5;
    HRESULT hr = device.As(&dev5);
    if (FAILED(hr)) return hr;
    HANDLE handle = nullptr;
    hr = handleOpener->OpenSharedHandleByName(name, GENERIC_ALL, &handle);
    if (FAILED(hr)) return hr;
    hr = dev5->OpenSharedFence(handle, IID_PPV_ARGS(result));
    CloseHandle(handle);
    return hr;
}

HRESULT copySource(const wchar_t *name, uint32_t width, uint32_t height, RuneWinSharedFrame &frame,
                   bool gpuCopy, const char *&operation) {
    ComPtr<ID3D11Texture2D> source;
    operation = "open named shared D3D texture";
    HRESULT hr = device->OpenSharedResourceByName(name, DXGI_SHARED_RESOURCE_READ, IID_PPV_ARGS(&source));
    if (FAILED(hr)) return hr;
    D3D11_TEXTURE2D_DESC desc{};
    source->GetDesc(&desc);
    if (desc.Width != width || desc.Height != height || desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
        desc.ArraySize != 1 || desc.MipLevels != 1 || desc.SampleDesc.Count != 1) {
        operation = "expected a single-mip single-sample BGRA8 texture of the published dimensions";
        return E_INVALIDARG;
    }
    bool keyed = (desc.MiscFlags & D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX) != 0;
    desc.MiscFlags = 0;
    desc.Usage = gpuCopy ? D3D11_USAGE_DEFAULT : D3D11_USAGE_STAGING;
    desc.BindFlags = gpuCopy ? (D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE) : 0;
    desc.CPUAccessFlags = gpuCopy ? 0 : D3D11_CPU_ACCESS_READ;
    operation = "allocate owned D3D frame";
    hr = device->CreateTexture2D(&desc, nullptr, &frame.image);
    if (FAILED(hr)) return hr;
    ComPtr<IDXGIKeyedMutex> mutex;
    if (keyed) {
        operation = "acquire shared texture at key zero";
        hr = source.As(&mutex);
        if (FAILED(hr)) return hr;
        hr = mutex->AcquireSync(0, 0);
        if (hr != S_OK) return FAILED(hr) ? hr : HRESULT_FROM_WIN32(hr);
    }
    context->CopyResource(frame.image.Get(), source.Get());
    if (mutex) {
        operation = "release shared texture at key zero";
        hr = mutex->ReleaseSync(0);
        if (FAILED(hr)) return hr;
    }
    frame.desc = desc;
    frame.context = context;
    frame.device = device;
    return S_OK;
}
} // namespace

void rune_win_shared_note_window(void) {
    HDC dc = rune_lazy_wglGetCurrentDC();
    if (!dc) return;
    HWND window = WindowFromDC(dc);
    HMONITOR monitor = window ? MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST) : nullptr;
    LUID luid{};
    auto getID = glProc<void (APIENTRY *)(GLenum, GLubyte *)>("glGetUnsignedBytevEXT");
    bool hasLuid = getID && hasGLExtension("GL_EXT_memory_object_win32");
    if (hasLuid) {
        getID(0x9599 /* GL_DEVICE_LUID_EXT */, reinterpret_cast<GLubyte *>(&luid));
        hasLuid = luid.LowPart != 0 || luid.HighPart != 0;
    }
    std::lock_guard<std::mutex> guard(deviceLock);
    if (windowMonitor != monitor || hasLuid != hasWindowLuid ||
        luid.LowPart != windowLuid.LowPart || luid.HighPart != windowLuid.HighPart) forgetDevice();
    windowMonitor = monitor;
    windowLuid = luid;
    hasWindowLuid = hasLuid;
}

int rune_win_shared_adapter(int32_t *high, uint32_t *low) {
    std::lock_guard<std::mutex> guard(deviceLock);
    if ((!windowMonitor && !hasWindowLuid) || !high || !low || FAILED(selectAdapter())) return 0;
    DXGI_ADAPTER_DESC1 desc{};
    if (FAILED(adapter->GetDesc1(&desc))) return 0;
    *high = desc.AdapterLuid.HighPart;
    *low = desc.AdapterLuid.LowPart;
    return 1;
}

RuneWinSharedFrame *rune_win_shared_capture(const uint16_t *name, uint32_t width, uint32_t height,
                                            const uint16_t *fenceName, uint64_t value, int gpuCopy,
                                            char *error, size_t capacity) {
    if (!name || !*name || !width || !height || width > 16384 || height > 16384) {
        fail(error, capacity, "invalid shared texture description", E_INVALIDARG);
        return nullptr;
    }
    std::lock_guard<std::mutex> guard(deviceLock);
    HRESULT hr = getDevice();
    if (FAILED(hr)) { fail(error, capacity, "open Direct3D adapter", hr); return nullptr; }
    ComPtr<ID3D11Fence> fence;
    ComPtr<ID3D11DeviceContext4> queue;
    if (fenceName) {
        hr = context.As(&queue);
        if (SUCCEEDED(hr)) hr = openFence(reinterpret_cast<const wchar_t *>(fenceName), &fence);
        if (FAILED(hr)) { fail(error, capacity, "open shared release fence", hr); return nullptr; }
    }
    const char *operation = "allocate owned D3D frame";
    auto frame = new(std::nothrow) RuneWinSharedFrame();
    hr = frame ? copySource(reinterpret_cast<const wchar_t *>(name), width, height, *frame, gpuCopy != 0, operation) : E_OUTOFMEMORY;
    if (fence) {
        // An attempted import releases its producer slot even on a descriptor mismatch.
        HRESULT signal = queue->Signal(fence.Get(), value);
        if (FAILED(signal)) { hr = signal; operation = "signal shared release fence"; }
    }
    context->Flush();
    if (FAILED(hr)) { delete frame; fail(error, capacity, operation, hr); return nullptr; }
    return frame;
}

void rune_win_shared_destroy(RuneWinSharedFrame *frame) { delete frame; }

namespace {
// A staging-only driver copies the producer directly into this publication's readable texture.
template<typename F> int mappedRows(RuneWinSharedFrame &frame, F consume, char *error, size_t capacity) {
    D3D11_TEXTURE2D_DESC desc = frame.desc;
    ComPtr<ID3D11Texture2D> staging = frame.image;
    std::lock_guard<std::mutex> guard(deviceLock);
    if (desc.Usage != D3D11_USAGE_STAGING) {
        desc.Usage = D3D11_USAGE_STAGING;
        desc.BindFlags = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        staging.Reset();
        HRESULT hr = frame.device->CreateTexture2D(&desc, nullptr, &staging);
        if (FAILED(hr)) return fail(error, capacity, "allocate D3D readback texture", hr);
        frame.context->CopyResource(staging.Get(), frame.image.Get());
    }
    D3D11_MAPPED_SUBRESOURCE mapped{};
    HRESULT hr = frame.context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr)) return fail(error, capacity, "map D3D readback texture", hr);
    int result = mapped.RowPitch >= desc.Width * 4 && mapped.RowPitch % 4 == 0
        ? consume(static_cast<const uint8_t *>(mapped.pData), mapped.RowPitch)
        : fail(error, capacity, "invalid D3D readback stride", E_UNEXPECTED);
    frame.context->Unmap(staging.Get(), 0);
    return result;
}
} // namespace

int rune_win_shared_read(RuneWinSharedFrame *frame, uint8_t *destination, size_t count, char *error, size_t capacity) {
    if (!frame || !destination || count != (size_t)frame->desc.Width * frame->desc.Height * 4)
        return fail(error, capacity, "invalid shared texture destination", E_INVALIDARG);
    return mappedRows(*frame, [&](const uint8_t *pixels, size_t stride) {
        const size_t row = (size_t)frame->desc.Width * 4;
        for (UINT y = 0; y < frame->desc.Height; ++y)
            std::memcpy(destination + y * row, pixels + y * stride, row);
        return 1;
    }, error, capacity);
}

int rune_win_shared_upload_gl(void *opaque, uint32_t texture) {
    auto frame = static_cast<RuneWinSharedFrame *>(opaque);
    if (!frame || !texture) return 0;
    return mappedRows(*frame, [&](const uint8_t *pixels, size_t stride) {
        // Rune has unbound the unpack buffer and reset skip/alignment for this upload.
        constexpr GLenum bgra = 0x80E1, rowLength = 0x0CF2;
        rune_lazy_glBindTexture(GL_TEXTURE_2D, texture);
        rune_lazy_glPixelStorei(rowLength, (GLint)(stride / 4));
        rune_lazy_glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, frame->desc.Width, frame->desc.Height, bgra, GL_UNSIGNED_BYTE, pixels);
        rune_lazy_glPixelStorei(rowLength, 0);
        return rune_lazy_glGetError() == GL_NO_ERROR ? 1 : 0;
    }, nullptr, 0);
}

int rune_win_shared_gl_available(void) {
    auto extensions = glProc<const char *(WINAPI *)(HDC)>("wglGetExtensionsStringARB");
    if (!extensions) return 0;
    const char *list = extensions(rune_lazy_wglGetCurrentDC());
    if (!list) return 0;
    const char *name = "WGL_NV_DX_interop2";
    size_t size = std::strlen(name);
    for (const char *p = list; (p = std::strstr(p, name)); p += size) {
        if ((p == list || p[-1] == ' ') && (p[size] == ' ' || p[size] == 0)) return 1;
    }
    return 0;
}

int rune_win_shared_copy_gl(void *opaque, uint32_t destination) {
    auto frame = static_cast<RuneWinSharedFrame *>(opaque);
    return frame && frame->desc.Usage == D3D11_USAGE_DEFAULT
        && rune_win_blit_d3d_texture(frame->device.Get(), frame->image.Get(),
                                    frame->desc.Width, frame->desc.Height, destination);
}

namespace {
struct BlitGLProcs {
    HGLRC context = nullptr;
    HANDLE (WINAPI *open)(void *) = nullptr;
    BOOL (WINAPI *close)(HANDLE) = nullptr;
    HANDLE (WINAPI *reg)(HANDLE, void *, GLuint, GLenum, GLenum) = nullptr;
    BOOL (WINAPI *unreg)(HANDLE, HANDLE) = nullptr;
    BOOL (WINAPI *lock)(HANDLE, GLint, HANDLE *) = nullptr;
    BOOL (WINAPI *unlock)(HANDLE, GLint, HANDLE *) = nullptr;
    void (APIENTRY *genFb)(GLsizei, GLuint *) = nullptr;
    void (APIENTRY *bindFb)(GLenum, GLuint) = nullptr;
    void (APIENTRY *attach)(GLenum, GLenum, GLenum, GLuint, GLint) = nullptr;
    GLenum (APIENTRY *status)(GLenum) = nullptr;
    void (APIENTRY *deleteFb)(GLsizei, const GLuint *) = nullptr;

    bool resolveForCurrent() {
        HGLRC current = rune_lazy_wglGetCurrentContext();
        if (!current) return false;
        if (current != context) {
            context = current;
            open = glProc<HANDLE (WINAPI *)(void *)>("wglDXOpenDeviceNV");
            close = glProc<BOOL (WINAPI *)(HANDLE)>("wglDXCloseDeviceNV");
            reg = glProc<HANDLE (WINAPI *)(HANDLE, void *, GLuint, GLenum, GLenum)>("wglDXRegisterObjectNV");
            unreg = glProc<BOOL (WINAPI *)(HANDLE, HANDLE)>("wglDXUnregisterObjectNV");
            lock = glProc<BOOL (WINAPI *)(HANDLE, GLint, HANDLE *)>("wglDXLockObjectsNV");
            unlock = glProc<BOOL (WINAPI *)(HANDLE, GLint, HANDLE *)>("wglDXUnlockObjectsNV");
            genFb = glProc<void (APIENTRY *)(GLsizei, GLuint *)>("glGenFramebuffers");
            bindFb = glProc<void (APIENTRY *)(GLenum, GLuint)>("glBindFramebuffer");
            attach = glProc<void (APIENTRY *)(GLenum, GLenum, GLenum, GLuint, GLint)>("glFramebufferTexture2D");
            status = glProc<GLenum (APIENTRY *)(GLenum)>("glCheckFramebufferStatus");
            deleteFb = glProc<void (APIENTRY *)(GLsizei, const GLuint *)>("glDeleteFramebuffers");
        }
        return open && close && reg && unreg && lock && unlock && genFb && bindFb && attach && status && deleteFb;
    }
};
} // namespace

bool rune_win_blit_d3d_textures(ID3D11Device *device, const RuneWinD3DBlit *blits, size_t count) {
    constexpr size_t maxBatch = 4;
    if (!device || !blits || count == 0 || count > maxBatch) return false;
    for (size_t i = 0; i < count; ++i) {
        if (!blits[i].texture || !blits[i].destination || !blits[i].width || !blits[i].height) return false;
    }
    thread_local BlitGLProcs procs;
    if (!procs.resolveForCurrent()) return false;
    HANDLE interop = procs.open(device);
    if (!interop) return false;

    GLuint sources[maxBatch]{};
    HANDLE objects[maxBatch]{};
    rune_lazy_glGenTextures(static_cast<GLsizei>(count), sources);
    size_t registered = 0;
    for (; registered < count; ++registered) {
        objects[registered] = procs.reg(interop, blits[registered].texture, sources[registered],
                                        GL_TEXTURE_2D, 0 /* WGL_ACCESS_READ_ONLY_NV */);
        if (!objects[registered]) break;
    }

    bool copied = false;
    if (registered == count && procs.lock(interop, static_cast<GLint>(count), objects)) {
        constexpr GLenum readFB = 0x8CA8, readBinding = 0x8CAA, color0 = 0x8CE0, complete = 0x8CD5;
        GLint previousFB = 0, previousTexture = 0;
        rune_lazy_glGetIntegerv(readBinding, &previousFB);
        rune_lazy_glGetIntegerv(GL_TEXTURE_BINDING_2D, &previousTexture);
        GLuint fb = 0;
        procs.genFb(1, &fb);
        procs.bindFb(readFB, fb);
        if (fb) {
            copied = true;
            for (size_t i = 0; i < count; ++i) {
                procs.attach(readFB, color0, GL_TEXTURE_2D, sources[i], 0);
                if (procs.status(readFB) != complete) {
                    copied = false;
                    break;
                }
                rune_lazy_glReadBuffer(color0);
                rune_lazy_glBindTexture(GL_TEXTURE_2D, blits[i].destination);
                rune_lazy_glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, blits[i].width, blits[i].height);
            }
            if (copied) copied = rune_lazy_glGetError() == GL_NO_ERROR;
        }
        rune_lazy_glBindTexture(GL_TEXTURE_2D, previousTexture);
        procs.bindFb(readFB, previousFB);
        procs.deleteFb(1, &fb);
        if (!procs.unlock(interop, static_cast<GLint>(count), objects)) copied = false;
    }
    for (size_t i = 0; i < registered; ++i) {
        if (!procs.unreg(interop, objects[i])) copied = false;
    }
    rune_lazy_glDeleteTextures(static_cast<GLsizei>(count), sources);
    procs.close(interop);
    return copied;
}

bool rune_win_blit_d3d_texture(ID3D11Device *device, ID3D11Texture2D *texture,
                               UINT width, UINT height, GLuint destination) {
    RuneWinD3DBlit blit{texture, width, height, destination};
    return rune_win_blit_d3d_textures(device, &blit, 1);
}
#endif
