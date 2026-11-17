// Run from a Windows SDK developer shell using Run.ps1.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <wrl/client.h>
#include <GL/gl.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "D3DVideoPlanes.h"
#include "RuneDecodedPlanes.h"
#include "RuneSharedTexture.h"

using Microsoft::WRL::ComPtr;
static_assert(sizeof(uint8_t) == 1);
// Match the decoder ring's DWORD-aligned backing width, including a non-aligned visible picture.
constexpr UINT codedW = 32, codedH = 18;
constexpr GLenum red = 0x1903, rg = 0x8227, r8 = 0x8229, rg8 = 0x822B;

static void require(bool value, const char *what) {
    if (!value) { std::fprintf(stderr, "failed: %s\n", what); std::exit(1); }
}
extern "C" void *rune_win_gl_proc(const char *name) {
    auto proc = wglGetProcAddress(name);
    if (proc && reinterpret_cast<uintptr_t>(proc) > 3 && proc != reinterpret_cast<PROC>(-1))
        return reinterpret_cast<void *>(proc);
    return reinterpret_cast<void *>(GetProcAddress(GetModuleHandleW(L"opengl32.dll"), name));
}

#include "Compositor.h"

struct GLContext {
    HWND window = CreateWindowExW(0, L"STATIC", L"Rune NV12 fixture", WS_POPUP, 0, 0, 32, 32, nullptr, nullptr, nullptr, nullptr);
    HDC dc = GetDC(window);
    HGLRC gl;
    GLContext() {
        PIXELFORMATDESCRIPTOR desc{sizeof(desc), 1};
        desc.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
        desc.iPixelType = PFD_TYPE_RGBA; desc.cColorBits = 32;
        int fmt = ChoosePixelFormat(dc, &desc);
        require(fmt && SetPixelFormat(dc, fmt, &desc), "set GL pixel format");
        HGLRC bootstrap = wglCreateContext(dc);
        require(bootstrap && wglMakeCurrent(dc,bootstrap), "activate bootstrap GL context");
        using CreateCore = HGLRC (WINAPI *)(HDC,HGLRC,const int *);
        auto create = reinterpret_cast<CreateCore>(rune_win_gl_proc("wglCreateContextAttribsARB"));
        const int attributes[] = {0x2091,3,0x2092,3,0x9126,1,0};
        gl = create ? create(dc,nullptr,attributes) : nullptr;
        require(gl && wglMakeCurrent(dc,gl), "activate desktop OpenGL 3.3 core context");
        wglDeleteContext(bootstrap);
        std::printf("GL=%s %s, WGL_NV_DX_interop2=%d\n", glGetString(GL_RENDERER), glGetString(GL_VERSION), rune_win_shared_gl_available());
    }
    ~GLContext() { wglMakeCurrent(nullptr,nullptr); wglDeleteContext(gl); ReleaseDC(window,dc); DestroyWindow(window); }
};

static std::vector<uint8_t> expected(UINT plane, UINT generation, UINT width, UINT height) {
    std::vector<uint8_t> bytes(size_t(width) * (height >> plane));
    for (UINT j=0; j<(height>>plane); ++j)
        for (UINT x=0; x<width; ++x) bytes[j*width+x] = uint8_t((39*plane + 133*j + 11*x + generation*17) % 256);
    return bytes;
}

static bool exercise(Compositor &compositor, D3D_DRIVER_TYPE driver, UINT w, UINT h, bool &exact) {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> ctx;
    HRESULT hr = D3D11CreateDevice(nullptr, driver, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &ctx);
    if (FAILED(hr)) { std::printf("driver=%d create-device=0x%08lx\n", driver, (unsigned long)hr); return false; }
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = codedW; desc.Height = codedH; desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;
    desc.Format=DXGI_FORMAT_NV12;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    ComPtr<ID3D11Texture2D> image;
    hr = device->CreateTexture2D(&desc, nullptr, &image);
    if (FAILED(hr)) {
        desc.BindFlags = 0;
        hr = device->CreateTexture2D(&desc, nullptr, &image);
    }
    if (FAILED(hr)) { std::printf("driver=%d NV12-texture=0x%08lx\n", driver, (unsigned long)hr); return false; }
    GLuint textures[2];
    glGenTextures(2,textures);
    glPixelStorei(GL_UNPACK_ALIGNMENT,1);
    glPixelStorei(GL_PACK_ALIGNMENT,1);
    for (UINT i=0;i<2;i++) {
        glBindTexture(GL_TEXTURE_2D,textures[i]);
        glTexImage2D(GL_TEXTURE_2D,0,i ? rg8:r8,w>>i,h>>i,0,i?rg:red,GL_UNSIGNED_BYTE,nullptr);
    }
    require(!glGetError(),"R8/RG8 allocations");
    auto *uploader = rune_win_plane_uploader_create();
    rune_video::SplitPlanes split;
    rune_video::NV12Image input{image.Get(),w,h};
    require(input.open(), "open GPU image");
    bool verifiedSplit = false;
    UINT directTransfers = 0;
    for (UINT generation=0;generation<3;generation++) {
        auto coded = expected(0,generation,codedW,codedH);
        auto uv = expected(1,generation,codedW,codedH);
        coded.insert(coded.end(),uv.begin(),uv.end());
        ctx->UpdateSubresource(image.Get(),0,nullptr,coded.data(),codedW,0);
        auto luma = expected(0,generation,w,h);
        auto chroma = expected(1,generation,w,h);
        std::vector<uint8_t> y(luma.size()), c(chroma.size());
        char message[512]{};
        require(rune_win_plane_read(image.Get(),w,h,y.data(),y.size(),c.data(),c.size(),message,sizeof(message)),message);
        for (UINT p=0; p<2; ++p) {
            const auto &actual = p ? c : y, &reference = p ? chroma : luma;
            for (size_t n=0;n<actual.size();++n) {
                if (actual[n]==reference[n]) continue;
                std::printf("driver=%d, mapping plane %u (%zu,%zu) expected %u got %u. First four row starts:",
                            driver,p,n%w,n/w,unsigned(reference[n]),unsigned(actual[n]));
                for (UINT row=0;row<4;row++) std::printf(" %u/%u",unsigned(actual[row*w]),unsigned(reference[row*w]));
                std::printf("\n");
                exact = false;
                break;
            }
        }
        require(!rune_win_plane_read(image.Get(),w,h,y.data(),y.size()-1,c.data(),c.size(),message,sizeof(message)), "reject short output");
        RuneWinPlaneCopy copy{uploader,image.Get(),w,h,rune_win_shared_gl_available()};
        require(rune_win_plane_copy_gl(&copy,textures[0],textures[1]),"upload NV12 to both GL textures");
        directTransfers += !!copy.transferred_on_gpu;
        for (UINT i=0;i<2;i++) {
            std::vector<uint8_t> bytes(i?c.size():y.size());
            glBindTexture(GL_TEXTURE_2D,textures[i]);
            glGetTexImage(GL_TEXTURE_2D,0,i?rg:red,GL_UNSIGNED_BYTE,bytes.data());
            require(!glGetError(), "GL plane readback");
            if (bytes != (i ? chroma : luma)) {
                std::printf("driver=%d GL plane %u differs at revision %u\n",driver,i,generation);
                exact = false;
            }
        }
        compositor.compare(copy,luma,chroma,generation);
        hr = split.run(input);
        if (FAILED(hr)) continue; // The staging path above is required even on drivers without shader-readable NV12.
        for (UINT i=0;i<2;i++) {
            D3D11_TEXTURE2D_DESC output;
            split.planes[i]->GetDesc(&output);
            output.Usage = D3D11_USAGE_STAGING; output.BindFlags = 0; output.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            ComPtr<ID3D11Texture2D> staging;
            require(SUCCEEDED(device->CreateTexture2D(&output,nullptr,&staging)), "stage compute output");
            ctx->CopyResource(staging.Get(),split.planes[i].Get());
            D3D11_MAPPED_SUBRESOURCE map{};
            require(SUCCEEDED(ctx->Map(staging.Get(),0,D3D11_MAP_READ,0,&map)), "map compute output");
            const auto *ref = i ? chroma.data():luma.data();
            for (UINT j=0; j<output.Height; ++j) {
                if (!std::memcmp(static_cast<const uint8_t *>(map.pData)+size_t(j)*map.RowPitch,ref+j*w,w)) continue;
                std::printf("driver=%d shader plane %u row %u differs at revision %u\n",driver,i,j,generation);
                exact = false;
                break;
            }
            ctx->Unmap(staging.Get(),0);
        }
        verifiedSplit = true;
    }
    std::printf("driver=%d, %ux%u visible in %ux%u, 3 NV12 updates / full RGBA draws, direct-WGL=%u/3, D3D11 shader split=%s (0x%08lx)\n",driver,w,h,codedW,codedH,directTransfers,
                verifiedSplit?"passed":"unsupported",(unsigned long)hr);
    rune_win_plane_uploader_destroy(uploader);
    glDeleteTextures(2,textures);
    return true;
}
int main(int argc, char **argv) {
    require(argc==2,"provide Rune's GL shader directory");
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    GLContext context;
    Compositor compositor(argv[1]);
    bool exact = true;
    for (auto width : {30u, 26u}) {
        UINT height = width == 30 ? 18u : 14u;
        bool hardware = exercise(compositor, D3D_DRIVER_TYPE_HARDWARE, width, height, exact);
        bool warp = exercise(compositor, D3D_DRIVER_TYPE_WARP, width, height, exact);
        require(hardware || warp, "NV12 on one D3D11 adapter");
    }
    require(exact, "cropped samples on every available driver");
}
