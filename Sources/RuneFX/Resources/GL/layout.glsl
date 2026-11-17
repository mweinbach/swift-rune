struct Globals {
    vec2 viewport;
    float dither;
    float srgb;
};

struct BackdropEncoding {
    float encoded;
    float present;
    float pad0;
    float pad1;
};

struct Inst {
    vec4 rect;
    vec4 shape;
    vec4 bounds;
    vec4 c0;
    vec4 c1;
    vec4 c2;
    vec4 p0;
    vec4 p1;
    vec4 p2;
    vec4 p3;
    vec4 t;
    vec4 aux;
    vec4 aux2;
    vec4 xf;
    vec4 clip;
    uvec4 fade;
};

layout(std140) uniform RunePass {
    Inst fxInstance;
    Globals fxGlobals;
    BackdropEncoding fxBackdrop;
};
