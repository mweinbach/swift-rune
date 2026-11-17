struct Prim {
    vec4 rect;     // x, y, w, h
    vec4 radii;    // tl, tr, br, bl
    vec4 z;        // bottom, top, bevel width, bevel height
    vec4 mat;      // gloss, roughness, flags, ao reach
    vec4 emit;     // linear radiance rgb, unused
    vec4 albedo;   // rgb albedo for bounce, unused
};

struct Light {
    vec4 pos;      // x, y, z, source radius
    vec4 color;    // linear rgb * intensity, range
    vec4 axis;     // spot axis xyz (unit), half-angle in radians (0 = point light)
    vec4 extra;    // shafts, bulb glow, specular, softness multiplier
};

const float RL_PI = 3.14159265;
const float RL_TAU = 6.28318531;
const float RL_REF = 200.0;
const uint F_OCC = 1u;
const uint F_EMIT = 2u;
const uint F_RAISED = 4u;
const uint F_HINT = 8u;

float w_smoothstep(float e0, float e1, float x) {
    if (e0 == e1) {
        return x >= e1 ? 1.0 : 0.0;
    }
    float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

uint flags_of(Prim p) {
    return uint(max(p.mat.z, 0.0) + 0.5);
}

float sd_rrect(vec2 p, vec2 halfSize, vec4 radii) {
    float r = radii.x;
    if (p.x > 0.0) {
        r = (p.y > 0.0 ? radii.z : radii.y);
    } else {
        r = (p.y > 0.0 ? radii.w : radii.x);
    }
    r = min(r, min(halfSize.x, halfSize.y));
    vec2 q = abs(p) - halfSize + vec2(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

float prim_sd(Prim pr, vec2 p) {
    vec2 halfSize = pr.rect.zw * 0.5;
    return sd_rrect(p - (pr.rect.xy + halfSize), halfSize, pr.radii);
}

float beam_angle(float c) {
    float omc = max(0.0, 1.0 - clamp(c, -1.0, 1.0));
    return sqrt(2.0 * omc) * (1.0 + 0.083333 * omc);
}

float beam_bell(float x) {
    float x2 = x * x;
    return 1.0 / (1.0 + x2 * (1.0 + 0.35 * x2));
}

float beam_lorentz(float x) {
    float x2 = x * x;
    return 1.0 / (1.0 + x2 * (1.0 + 0.48 * x2));
}

float beam_profile(float t) {
    float inner = 0.5;
    float core = 0.45;
    float core_w = 0.34;
    float spill = 0.035;
    float spill_w = 1.6;
    float rings = 0.18;
    if (t >= spill_w * 1.7) {
        return 0.0;
    }
    float ring = 1.0 + rings * (0.2 * beam_bell((t - 0.84) * 12.5) - 0.18 * beam_bell((t - core_w * 1.35) * 9.0));
    return (1.0 - w_smoothstep(inner, 1.0, t)) * ring + core * beam_lorentz(t / core_w) + spill * beam_lorentz(t / spill_w);
}

vec4 light_term(Light L, vec3 P) {
    vec3 D = L.pos.xyz - P;
    float d2 = dot(D, D);
    float d = sqrt(d2);
    vec3 l = D / max(d, 1e-4);
    float x = d / max(L.color.w, 1.0);
    float x2 = x * x;
    float w = clamp(1.0 - x2 * x2, 0.0, 1.0);
    float a = (RL_REF * RL_REF) / (d2 + L.pos.w * L.pos.w) * w * w;
    if (L.axis.w > 0.0) {
        a = a * beam_profile(beam_angle(dot(-l, L.axis.xyz)) / L.axis.w);
    }
    return vec4(l, a);
}

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

layout(std140) uniform RunePass {
    vec4 sf, gs, ambient;
    uvec4 counts;
    vec4 misc, text, gi, bg, ext;
    uvec4 stage;     // cascade index or scene output selection (emission / occlusion)
    Light lights[8];
} F;

// Data texture uTex0 stores each primitive as one row of six RGBA32F texels.
uniform sampler2D uTex0, uTex1, uTex2, uTex3, uTex4, uTex5, uTex6, uTex7;
#ifndef RUNE_LIGHT_VERTEX
out vec4 result;
#endif
Prim primAt(int i) {
    return Prim(texelFetch(uTex0, ivec2(0, i), 0), texelFetch(uTex0, ivec2(1, i), 0),
                texelFetch(uTex0, ivec2(2, i), 0), texelFetch(uTex0, ivec2(3, i), 0),
                texelFetch(uTex0, ivec2(4, i), 0), texelFetch(uTex0, ivec2(5, i), 0));
}
float choose(float a, float b, bool c) { return c ? b : a; }
vec4 choose(vec4 a, vec4 b, bool c) { return c ? b : a; }
