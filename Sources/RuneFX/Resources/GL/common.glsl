#ifdef GL_ES
precision highp sampler2D;
#endif
in vec2 runePixel;
out vec4 fragColor;
uniform sampler2D uTex0;  // Backdrop, in the destination blend space.
uniform sampler2D uTex1;  // Optional mask, motion source or simulation field.
uniform sampler2D uTex2;  // Blurred backdrop.
uniform sampler2D uTex3;  // Packed float4 effect table, by linear index.

vec4 tableEntry(uint index) {
    int width = textureSize(uTex3, 0).x;
    return texelFetch(uTex3, ivec2(int(index) % width, int(index) / width), 0);
}

// Render targets place the first Rune row at the highest GL row.
vec4 sampleTopLeft(sampler2D tex, vec2 uv, float lod) {
    return textureLod(tex, vec2(uv.x, 1.0 - uv.y), lod);
}

float decodeHalf(uint bits) {
    float signValue = (bits & 0x8000u) == 0u ? 1.0 : -1.0;
    uint power = (bits >> 10u) & 31u;
    float mantissa = float(bits & 1023u) / 1024.0;
    if (power == 31u) return uintBitsToFloat(((bits & 0x8000u) << 16u) | 0x7f800000u | ((bits & 1023u) << 13u));
    if (power == 0u) return signValue * mantissa * exp2(-14.0);
    return signValue * (1.0 + mantissa) * exp2(float(power) - 15.0);
}

vec2 unpackHalfPair(uint bits) { return vec2(decodeHalf(bits), decodeHalf(bits >> 16u)); }

vec4 unpackBytes(uint bits) {
    return vec4(uvec4(bits, bits >> 8u, bits >> 16u, bits >> 24u) & 255u) / 255.0;
}

float dat1(uint base, uint i) {
    return tableEntry(base + (i >> 2u))[i & 3u];
}

vec3 to_srgb(vec3 c) {
    vec3 lo = c * 12.92;
    vec3 hi = 1.055 * pow(max(c, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055;
    return mix(hi, lo, lessThanEqual(c, vec3(0.0031308)));
}

vec3 to_lin(vec3 c) {
    vec3 lo = c / 12.92;
    vec3 hi = pow((max(c, vec3(0.0)) + 0.055) / 1.055, vec3(2.4));
    return mix(hi, lo, lessThanEqual(c, vec3(0.04045)));
}

vec4 bd_lin(vec4 c, BackdropEncoding enc) {
    if (enc.encoded > 0.5) {
        float a = max(c.a, 0.0);
        vec3 straight = a > 1e-6 ? c.rgb / a : vec3(0.0);
        return vec4(to_lin(straight) * a, a);
    }
    return c;
}

vec4 bd(vec2 p, float scale, Globals g, sampler2D backdrop, BackdropEncoding enc) {
    vec2 uv = p * scale / g.viewport;
    return bd_lin(sampleTopLeft(backdrop, uv, 0.0), enc);
}

vec3 bdb(vec2 p, float scale, Globals g, sampler2D blurred, BackdropEncoding enc) {
    vec2 uv = p * scale / g.viewport;
    return bd_lin(sampleTopLeft(blurred, uv, 0.0), enc).rgb;
}

const float TAU = 6.2831853;
const float PI = 3.14159265;

uint pcg(uint v) {
    uint s = v * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}

uint hu(uint a, uint b) {
    return pcg(a ^ pcg(b + 0x9E3779B9u));
}

float u01(uint n) {
    return float(pcg(n) >> 8u) * (1.0 / 16777216.0);
}

float hcell(ivec2 c, uint seed) {
    return float(pcg(uint(c.x) ^ pcg(uint(c.y) ^ pcg(seed))) >> 8u) * (1.0 / 16777216.0);
}

vec2 grad2(ivec2 c, uint seed) {
    float a = hcell(c, seed) * TAU;
    return vec2(cos(a), sin(a));
}

float gnoise(vec2 p, uint seed) {
    ivec2 i = ivec2(floor(p));
    vec2 f = p - floor(p);
    float a = dot(grad2(i + ivec2(0, 0), seed), f - vec2(0.0, 0.0));
    float b = dot(grad2(i + ivec2(1, 0), seed), f - vec2(1.0, 0.0));
    float c = dot(grad2(i + ivec2(0, 1), seed), f - vec2(0.0, 1.0));
    float d = dot(grad2(i + ivec2(1, 1), seed), f - vec2(1.0, 1.0));
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.41421;
}

float pgnoise(vec2 p, int per, uint seed) {
    ivec2 i = ivec2(floor(p));
    vec2 f = p - floor(p);
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    int x0 = ((i.x % per) + per) % per;
    int x1 = (x0 + 1) % per;
    float a = dot(grad2(ivec2(x0, i.y), seed), f);
    float b = dot(grad2(ivec2(x1, i.y), seed), f - vec2(1.0, 0.0));
    float c = dot(grad2(ivec2(x0, i.y + 1), seed), f - vec2(0.0, 1.0));
    float d = dot(grad2(ivec2(x1, i.y + 1), seed), f - vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.41421;
}

vec2 rot_mul(vec2 p) {
    return vec2(0.8 * p.x - 0.6 * p.y, 0.6 * p.x + 0.8 * p.y);
}

float fbm(vec2 p, uint seed, int octaves) {
    float s = 0.0;
    float a = 0.5;
    float norm = 0.0;
    for (int o = 0; o < octaves; o++) {
        s += a * gnoise(p, seed + uint(o) * 131u);
        norm += a;
        p = rot_mul(p) * 2.02;
        a *= 0.5;
    }
    return s / max(norm, 1e-4);
}

float fbm3(vec2 p0, uint seed) {
    vec2 p = p0;
    float a = 0.5;
    float s = 0.0;
    for (uint o = 0u; o < 3u; o++) {
        s += a * gnoise(p, seed + o * 131u);
        p = rot_mul(p) * 2.02;
        a *= 0.5;
    }
    return s / 0.875;
}

float fbm5(vec2 p0, uint seed) {
    vec2 p = p0;
    float a = 0.5;
    float s = 0.0;
    for (uint o = 0u; o < 5u; o++) {
        s += a * gnoise(p, seed + o * 131u);
        p = rot_mul(p) * 2.02;
        a *= 0.5;
    }
    return s / 0.96875;
}

float ign(vec2 px) {
    return fract(52.9829189 * fract(dot(floor(px), vec2(0.06711056, 0.00583715))));
}

float sd_rrect(vec2 q, vec2 half_size, float r) {
    float rr = clamp(r, 0.0, min(half_size.x, half_size.y));
    vec2 k = abs(q) - half_size + rr;
    return length(max(k, vec2(0.0))) + min(max(k.x, k.y), 0.0) - rr;
}

float smin(float a, float b, float k) {
    if (k <= 0.0) { return min(a, b); }
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

vec2 rrect_perim(vec2 q, vec2 half_size, float r0) {
    float r = clamp(r0, 0.0, min(half_size.x, half_size.y));
    vec2 b = half_size - r;
    vec2 a = abs(q);
    float lq = b.y + r * PI * 0.5 + b.x;
    float s;
    if (a.x > b.x && a.y > b.y) {
        s = b.y + r * atan(a.y - b.y, a.x - b.x);
    } else if ((a.x - b.x) > (a.y - b.y)) {
        s = min(a.y, b.y);
    } else {
        s = b.y + r * PI * 0.5 + (b.x - min(a.x, b.x));
    }
    float o;
    if (q.x >= 0.0 && q.y >= 0.0) { o = s; }
    else if (q.x < 0.0 && q.y >= 0.0) { o = 2.0 * lq - s; }
    else if (q.x < 0.0) { o = 2.0 * lq + s; }
    else { o = 4.0 * lq - s; }
    return vec2(o, 4.0 * lq);
}

struct Ctx {
    vec2 p;
    vec2 q;
    vec2 c;
    vec2 half_size;
    float r;
    float scale;
    float aa;
    float d;
    float t;
    uint seed;
    int variant;
    bool reduced;
};

Ctx make_ctx(Inst i, vec2 px) {
    Ctx c;
    c.scale = i.shape.y;
    c.p = px / c.scale;
    c.half_size = i.rect.zw * 0.5;
    c.c = i.rect.xy + c.half_size;
    c.q = (px - c.c * c.scale) / c.scale;
    c.r = i.shape.x;
    c.aa = 1.0 / c.scale;
    c.d = sd_rrect(c.q, c.half_size, c.r);
    c.t = i.t.x;
    c.seed = uint(i.t.y);
    c.variant = int(i.t.z + 0.5);
    c.reduced = (uint(i.t.w) & 1u) != 0u;
    return c;
}

vec2 sd_grad(Ctx c) {
    float e = 0.35;
    float dx = sd_rrect(c.q + vec2(e, 0.0), c.half_size, c.r) - sd_rrect(c.q - vec2(e, 0.0), c.half_size, c.r);
    float dy = sd_rrect(c.q + vec2(0.0, e), c.half_size, c.r) - sd_rrect(c.q - vec2(0.0, e), c.half_size, c.r);
    vec2 gv = vec2(dx, dy);
    return gv / max(length(gv), 1e-5);
}

float erf_approx(float x) {
    float x2 = x * x;
    float a = 0.147;
    float v = sqrt(1.0 - exp(-x2 * (1.2732395 + a * x2) / (1.0 + a * x2)));
    return (x >= 0.0 ? v : -v);
}

float cov(float d, float s) {
    return 0.5 - 0.5 * erf_approx(d / (max(s, 1e-3) * 1.41421));
}

float gauss(float x, float w) {
    return exp(-(x * x) / max(w * w, 1e-6));
}

float w_smoothstep(float a, float b, float x) {
    return (a < b) ? smoothstep(a, b, x) : (a > b ? (1.0 - smoothstep(b, a, x)) : (x >= a ? 1.0 : 0.0));
}

float bloom(float d, float r, float reach) {
    float o = max(d, 0.0);
    float w = 1.0 - smoothstep(reach * 0.5, reach, o);
    return (0.65 * gauss(o, r * 0.35) + 0.35 * gauss(o, r * 1.2)) * w;
}

float knee(float x) {
    return 1.0 - exp(-max(x, 0.0));
}

float lum(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec3 cooled(vec3 c, float heat) {
    vec3 deep = c * c / max(max(c.r, max(c.g, c.b)), 0.02);
    return mix(deep * 0.55, c, smoothstep(0.0, 0.75, heat));
}

vec2 segdist(vec2 p, vec2 a, vec2 b) {
    vec2 ab = b - a;
    float h = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    return vec2(length(p - a - ab * h), h);
}

float sd_shape(Inst i, vec2 p) {
    vec2 half_size = i.rect.zw * 0.5;
    vec2 center = i.rect.xy + half_size;
    return sd_rrect(p - center, half_size, i.shape.x);
}

vec2 shape_normal(Inst i, vec2 p) {
    float e = 0.35;
    float dx = sd_shape(i, p + vec2(e, 0.0)) - sd_shape(i, p - vec2(e, 0.0));
    float dy = sd_shape(i, p + vec2(0.0, e)) - sd_shape(i, p - vec2(0.0, e));
    vec2 g = vec2(dx, dy);
    float len = length(g);
    return len > 1e-5 ? g / len : vec2(0.0, -1.0);
}

const float CONTINUOUS_K = 1.52866483;

float sd_continuous(vec2 p, vec2 half_size, float r) {
    float e = CONTINUOUS_K * r;
    vec2 q = half_size - abs(p);
    vec2 v = vec2(e) - q;
    if (v.x <= 0.0 || v.y <= 0.0) { return max(-q.x, -q.y); }
    float u = atan(v.y, v.x) * (4.0 / 3.14159265) - 1.0;
    float u2 = u * u;
    return length(v) - e * (1.14602295 + u2 * (-0.37573161 + u2 * (0.30796609 - 0.07724354 * u2)));
}

float sd_rounded(vec2 p, vec2 half_size, vec4 radii) {
    float r = radii.x;
    if (p.x > 0.0) {
        r = (p.y > 0.0 ? radii.z : radii.y);
    } else {
        r = (p.y > 0.0 ? radii.w : radii.x);
    }
    if (r < 0.0) { return sd_continuous(p, half_size, min(-r, min(half_size.x, half_size.y))); }
    r = min(r, min(half_size.x, half_size.y));
    vec2 q = abs(p) - half_size + vec2(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

float ramp(float d, float fade) {
    if (fade == 0.0) {
        return clamp(d + 0.5, 0.0, 1.0);
    }
    float x = clamp(d / abs(fade), 0.0, 1.0);
    if (fade < 0.0) {
        return x;
    }
    return x * x * (3.0 - 2.0 * x);
}

vec4 unpack_clip_radii(uint w) {
    if (w == 0u) { return vec4(0.0); }
    if ((w & 0x60000000u) != 0x60000000u) {
        return vec4(uintBitsToFloat(w));
    }
    float step = ((w & 0x10000000u) != 0u ? 2.0 : 0.5);
    float sgn = ((w & 0x80000000u) != 0u ? -1.0 : 1.0);
    return vec4(
        float(w & 0x7fu),
        float((w >> 7u) & 0x7fu),
        float((w >> 14u) & 0x7fu),
        float((w >> 21u) & 0x7fu)
    ) * (step * sgn);
}

float clip_alpha(vec2 p, vec4 c, uvec4 packedFade) {
    vec4 f = vec4(vec2(unpackHalfPair(packedFade.x)), vec2(unpackHalfPair(packedFade.y)));
    vec4 offset = unpackBytes(packedFade.z);
    vec4 hard = vec4(p - c.xy, c.zw - p);
    float alpha = 1.0;
    for (uint edge = 0u; edge < 4u; edge++) {
        float a = ramp(hard[edge], f[edge]);
        if (offset[edge] >= 1.0) {
            a = ramp(hard[edge], 0.0);
        } else if (offset[edge] > 0.0) {
            a = min(ramp(hard[edge], 0.0), ramp(hard[edge] + offset[edge] * abs(f[edge]), f[edge]));
        }
        alpha *= a;
    }
    if (packedFade.w != 0u) {
        vec2 half_size = (c.zw - c.xy) * 0.5;
        alpha *= clamp(0.5 - sd_rounded(p - c.xy - half_size, half_size, unpack_clip_radii(packedFade.w)), 0.0, 1.0);
    }
    return alpha;
}

uint effective_blend_mode(Inst i, BackdropEncoding enc) {
    uint m = (uint(i.t.w) >> 1u) & 7u;
    if ((m == 1u || m == 3u || m == 4u) && enc.present < 0.5) {
        return 0u;
    }
    return m;
}

float blend_overlay_ch(float b, float s) {
    return (b <= 0.5 ? 2.0 * b * s : 1.0 - 2.0 * (1.0 - b) * (1.0 - s));
}

vec3 blend_overlay(vec3 b, vec3 s) {
    return vec3(blend_overlay_ch(b.r, s.r), blend_overlay_ch(b.g, s.g), blend_overlay_ch(b.b, s.b));
}

float blend_soft_light_ch(float b, float s) {
    if (s <= 0.5) {
        return b - (1.0 - 2.0 * s) * b * (1.0 - b);
    }
    float d = (b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(max(b, 0.0)));
    return b + (2.0 * s - 1.0) * (d - b);
}

vec3 blend_soft_light(vec3 b, vec3 s) {
    return vec3(blend_soft_light_ch(b.r, s.r), blend_soft_light_ch(b.g, s.g), blend_soft_light_ch(b.b, s.b));
}

vec4 finish(vec4 c0, vec2 px, Globals g) {
    vec4 c = max(c0, vec4(0.0));
    c.a = min(c.a, 1.0);
    if (g.dither > 0.5) {
        uvec2 ip = uvec2(px);
        float n = (u01(ip.x + pcg(ip.y)) + u01(ip.x * 7919u + pcg(ip.y + 104729u))) - 1.0;
        vec3 s = to_srgb(c.rgb);
        float gate = smoothstep(0.0, 3.0 / 255.0, max(s.r, max(s.g, s.b)));
        c = vec4(to_lin(max(s + vec3(n / 255.0 * gate), vec3(0.0))), c.a);
    }
    return c;
}

// The fragment's pixel centre in px, exactly: the interpolated `runePixel` drifts by a few ulps
// that differ between quads, so two equal shapes at different places would shade a little apart.
// GL's gl_FragCoord has Y pointing up, while Rune's pixel space has Y pointing down.
vec2 recover_pixel(Globals g) {
    vec2 pos = vec2(gl_FragCoord.x, g.viewport.y - gl_FragCoord.y);
    return pos + round((runePixel - pos) * 256.0) / 256.0;
}

vec4 fx_fs(
    vec4 shaded,
    Inst i,
    vec2 px,
    Globals g,
    sampler2D backdrop,
    BackdropEncoding enc
) {
    float ca = clip_alpha(px, i.clip, i.fade);
    if (ca <= 0.0) { return vec4(0.0); }
    vec4 c = shaded * i.shape.z;
    uint mode = effective_blend_mode(i, enc);
    if (mode == 0u) {
        if (g.srgb > 0.5) {
            vec3 cover = min(max(c.rgb, vec3(0.0)), vec3(c.a));
            vec3 straight = (c.a > 1e-6 ? cover / c.a : vec3(0.0));
            return vec4(to_srgb(straight) * c.a + to_srgb(max(c.rgb, vec3(0.0)) - cover), c.a) * ca;
        }
        return c * ca;
    }
    float m = max(c.a, max(c.r, max(c.g, c.b)));
    float as_ = clamp(m * ca, 0.0, 1.0);
    if (as_ <= 0.0) { return vec4(0.0); }
    vec3 cs_lin = (m > 1e-6 ? clamp(c.rgb / m, vec3(0.0), vec3(1.0)) : vec3(0.0));
    vec3 cs = (g.srgb > 0.5 ? to_srgb(cs_lin) : cs_lin);
    if (mode == 2u) {
        return vec4(cs * as_, as_);
    }
    vec4 b_lin = bd(px, 1.0, g, backdrop, enc);
    float ab = clamp(b_lin.a, 0.0, 1.0);
    vec3 cb_lin = (ab > 1e-6 ? clamp(b_lin.rgb / ab, vec3(0.0), vec3(1.0)) : vec3(0.0));
    vec3 cb = (g.srgb > 0.5 ? to_srgb(cb_lin) : cb_lin);
    vec3 blended = cb * cs;
    if (mode == 3u) { blended = blend_overlay(cb, cs); }
    if (mode == 4u) { blended = blend_soft_light(cb, cs); }
    return vec4(mix(cs, blended, ab) * as_, as_);
}
