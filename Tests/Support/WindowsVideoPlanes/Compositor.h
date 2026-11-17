#pragma once
#include "CRuneGL.h"
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

// Compare the ordinary production frame + surface shaders against the encoded byte-plane path.
class Compositor {
    RuneGL *renderer;
    RuneGLPassDevice *pass;
    char error[1024]{};
    static std::string load(const char *directory, const char *name) {
        std::ifstream input(std::string(directory)+"/"+name, std::ios::binary);
        require(input.good(), name);
        return std::string(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
    }
public:
    explicit Compositor(const char *directory) {
        auto fullscreen = load(directory,"fullscreen.vert");
        renderer = rune_gl_create_device(rune_win_gl_proc, fullscreen.c_str(), load(directory,"layer.frag").c_str(),
                                         error,sizeof(error));
        require(renderer, error);
        auto fragment = load(directory,"outline.frag")+"\n"+load(directory,"frame.frag");
        require(rune_gl_configure_frame(renderer,load(directory,"frame.vert").c_str(),fragment.c_str(),
                                        fullscreen.c_str(),load(directory,"frame_blur.frag").c_str(),error,sizeof(error)),error);
        require(rune_gl_configure_surfaces(renderer,load(directory,"surface.vert").c_str(),
                                           load(directory,"surface.frag").c_str(),error,sizeof(error)),error);
        pass = rune_gl_pass_open(rune_win_gl_proc,error,sizeof(error));
        require(pass,error);
    }
    ~Compositor() { rune_gl_pass_close(pass); rune_gl_destroy(renderer); }

    void compare(RuneWinPlaneCopy &copy, const std::vector<uint8_t> &y,
                 const std::vector<uint8_t> &uv, UINT generation) {
        const int w = copy.width, h = copy.height;
        const int format = generation & 1 ? 2 : 1;
        RuneGLPassTarget target{};
        require(rune_gl_pass_target(pass,RuneGLPassRGBA8,w,h,0,&target,error,sizeof(error)),error);
        RuneGLSurfaceDraw draw{};
        draw.uniforms[1][2] = draw.uniforms[2][2] = draw.uniforms[4][2] = float(w);
        draw.uniforms[1][3] = draw.uniforms[2][3] = draw.uniforms[4][3] = float(h);
        draw.uniforms[7][0] = float(format);
        draw.uniforms[7][1] = generation & 1 ? 1.0f : 0.0f;
        draw.uniforms[7][2] = 2; // sRGB compositing
        draw.uniforms[7][3] = draw.uniforms[8][0] = draw.uniforms[9][0] = draw.uniforms[9][3] = 1;
        draw.uniforms[8][1] = float(w);
        draw.uniforms[8][2] = float(h);
        std::vector<uint8_t> actual(size_t(w)*h*4), reference(actual.size());
        const uint8_t glyph = 0, image[4]{};
        const float clear[4]{};
        for (UINT mode=0;mode<2;mode++) {
            draw.key = mode+1;
            draw.version = generation+1;
            if (!mode) {
                require(rune_gl_surface_copy_nv12(renderer,draw.key,draw.version,w,h,format,
                                                  rune_win_plane_copy_gl,&copy,error,sizeof(error)),error);
            } else {
                require(rune_gl_surface_upload(renderer,draw.key,draw.version,w,h,format,
                                               y.data(),y.size(),uv.data(),uv.size(),error,sizeof(error)),error);
            }
            rune_gl_pass_bind_target(pass,target);
            require(rune_gl_render_frame(renderer,w,h,clear,1,nullptr,0,&glyph,1,1,image,1,1,&draw,1,error,sizeof(error)),error);
            auto &out = mode ? reference : actual;
            require(rune_gl_pass_read(pass,target,out.data(),out.size(),error,sizeof(error)),error);
        }
        rune_gl_pass_delete_target(pass,&target);
        require(actual==reference, "full compositor RGBA pixels differ");
        bool varied = false;
        for (size_t index=4;index<actual.size();index+=4)
            if (actual[index]!=actual[0] || actual[index+1]!=actual[1]) { varied=true;break; }
        require(varied, "surface did not paint distinct colors");
    }
};
