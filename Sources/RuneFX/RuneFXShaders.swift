import Foundation
import Rune

public enum RuneFXShaders: Sendable {
    public static let commonPrelude: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct Globals {
        float2 viewport;
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
        float4 rect;
        float4 shape;
        float4 bounds;
        float4 c0;
        float4 c1;
        float4 c2;
        float4 p0;
        float4 p1;
        float4 p2;
        float4 p3;
        float4 t;
        float4 aux;
        float4 aux2;
        float4 xf;
        float4 clip;
        uint4 fade;
    };

    struct VOut {
        float4 pos [[position]];
        uint id [[flat]];
        float2 px;
    };

    inline float dat1(const device float4* data, uint base, uint i) {
        return data[base + (i >> 2u)][i & 3u];
    }

    inline float3 to_srgb(float3 c) {
        float3 lo = c * 12.92;
        float3 hi = 1.055 * pow(max(c, float3(0.0)), float3(1.0 / 2.4)) - 0.055;
        return select(hi, lo, c <= float3(0.0031308));
    }

    inline float3 to_lin(float3 c) {
        float3 lo = c / 12.92;
        float3 hi = pow((max(c, float3(0.0)) + 0.055) / 1.055, float3(2.4));
        return select(hi, lo, c <= float3(0.04045));
    }

    inline float4 bd_lin(float4 c, constant BackdropEncoding& enc) {
        if (enc.encoded > 0.5) {
            float a = max(c.a, 0.0);
            float3 straight = a > 1e-6 ? c.rgb / a : float3(0.0);
            return float4(to_lin(straight) * a, a);
        }
        return c;
    }

    inline float4 bd(float2 p, float scale, constant Globals& g, texture2d<float> backdrop, sampler samp, constant BackdropEncoding& enc) {
        float2 uv = p * scale / g.viewport;
        return bd_lin(backdrop.sample(samp, uv, level(0.0)), enc);
    }

    inline float3 bdb(float2 p, float scale, constant Globals& g, texture2d<float> blurred, sampler samp, constant BackdropEncoding& enc) {
        float2 uv = p * scale / g.viewport;
        return bd_lin(blurred.sample(samp, uv, level(0.0)), enc).rgb;
    }

    constant float TAU = 6.2831853;
    constant float PI = 3.14159265;

    inline uint pcg(uint v) {
        uint s = v * 747796405u + 2891336453u;
        uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
        return (w >> 22u) ^ w;
    }

    inline uint hu(uint a, uint b) {
        return pcg(a ^ pcg(b + 0x9E3779B9u));
    }

    inline float u01(uint n) {
        return float(pcg(n) >> 8u) * (1.0 / 16777216.0);
    }

    inline float hcell(int2 c, uint seed) {
        return float(pcg(as_type<uint>(c.x) ^ pcg(as_type<uint>(c.y) ^ pcg(seed))) >> 8u) * (1.0 / 16777216.0);
    }

    inline float2 grad2(int2 c, uint seed) {
        float a = hcell(c, seed) * TAU;
        return float2(cos(a), sin(a));
    }

    inline float gnoise(float2 p, uint seed) {
        int2 i = int2(floor(p));
        float2 f = p - floor(p);
        float a = dot(grad2(i + int2(0, 0), seed), f - float2(0.0, 0.0));
        float b = dot(grad2(i + int2(1, 0), seed), f - float2(1.0, 0.0));
        float c = dot(grad2(i + int2(0, 1), seed), f - float2(0.0, 1.0));
        float d = dot(grad2(i + int2(1, 1), seed), f - float2(1.0, 1.0));
        float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.41421;
    }

    inline float pgnoise(float2 p, int per, uint seed) {
        int2 i = int2(floor(p));
        float2 f = p - floor(p);
        float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
        int x0 = ((i.x % per) + per) % per;
        int x1 = (x0 + 1) % per;
        float a = dot(grad2(int2(x0, i.y), seed), f);
        float b = dot(grad2(int2(x1, i.y), seed), f - float2(1.0, 0.0));
        float c = dot(grad2(int2(x0, i.y + 1), seed), f - float2(0.0, 1.0));
        float d = dot(grad2(int2(x1, i.y + 1), seed), f - float2(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.41421;
    }

    inline float2 rot_mul(float2 p) {
        return float2(0.8 * p.x - 0.6 * p.y, 0.6 * p.x + 0.8 * p.y);
    }

    inline float fbm(float2 p, uint seed, int octaves) {
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

    inline float fbm3(float2 p0, uint seed) {
        float2 p = p0;
        float a = 0.5;
        float s = 0.0;
        for (uint o = 0u; o < 3u; o++) {
            s += a * gnoise(p, seed + o * 131u);
            p = rot_mul(p) * 2.02;
            a *= 0.5;
        }
        return s / 0.875;
    }

    inline float fbm5(float2 p0, uint seed) {
        float2 p = p0;
        float a = 0.5;
        float s = 0.0;
        for (uint o = 0u; o < 5u; o++) {
            s += a * gnoise(p, seed + o * 131u);
            p = rot_mul(p) * 2.02;
            a *= 0.5;
        }
        return s / 0.96875;
    }

    inline float ign(float2 px) {
        return fract(52.9829189 * fract(dot(floor(px), float2(0.06711056, 0.00583715))));
    }

    inline float sd_rrect(float2 q, float2 half_size, float r) {
        float rr = clamp(r, 0.0, min(half_size.x, half_size.y));
        float2 k = abs(q) - half_size + rr;
        return length(max(k, float2(0.0))) + min(max(k.x, k.y), 0.0) - rr;
    }

    inline float smin(float a, float b, float k) {
        if (k <= 0.0) { return min(a, b); }
        float h = max(k - abs(a - b), 0.0) / k;
        return min(a, b) - h * h * k * 0.25;
    }

    inline float2 rrect_perim(float2 q, float2 half_size, float r0) {
        float r = clamp(r0, 0.0, min(half_size.x, half_size.y));
        float2 b = half_size - r;
        float2 a = abs(q);
        float lq = b.y + r * PI * 0.5 + b.x;
        float s;
        if (a.x > b.x && a.y > b.y) {
            s = b.y + r * atan2(a.y - b.y, a.x - b.x);
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
        return float2(o, 4.0 * lq);
    }

    struct Ctx {
        float2 p;
        float2 q;
        float2 c;
        float2 half_size;
        float r;
        float scale;
        float aa;
        float d;
        float t;
        uint seed;
        int variant;
        bool reduced;
    };

    inline Ctx make_ctx(Inst i, float2 px) {
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

    inline float2 sd_grad(Ctx c) {
        float e = 0.35;
        float dx = sd_rrect(c.q + float2(e, 0.0), c.half_size, c.r) - sd_rrect(c.q - float2(e, 0.0), c.half_size, c.r);
        float dy = sd_rrect(c.q + float2(0.0, e), c.half_size, c.r) - sd_rrect(c.q - float2(0.0, e), c.half_size, c.r);
        float2 gv = float2(dx, dy);
        return gv / max(length(gv), 1e-5);
    }

    inline float erf_approx(float x) {
        float x2 = x * x;
        float a = 0.147;
        float v = sqrt(1.0 - exp(-x2 * (1.2732395 + a * x2) / (1.0 + a * x2)));
        return select(-v, v, x >= 0.0);
    }

    inline float cov(float d, float s) {
        return 0.5 - 0.5 * erf_approx(d / (max(s, 1e-3) * 1.41421));
    }

    inline float gauss(float x, float w) {
        return exp(-(x * x) / max(w * w, 1e-6));
    }

    inline float w_smoothstep(float a, float b, float x) {
        return (a < b) ? smoothstep(a, b, x) : (a > b ? (1.0 - smoothstep(b, a, x)) : (x >= a ? 1.0 : 0.0));
    }

    inline float bloom(float d, float r, float reach) {
        float o = max(d, 0.0);
        float w = 1.0 - smoothstep(reach * 0.5, reach, o);
        return (0.65 * gauss(o, r * 0.35) + 0.35 * gauss(o, r * 1.2)) * w;
    }

    inline float knee(float x) {
        return 1.0 - exp(-max(x, 0.0));
    }

    inline float lum(float3 c) {
        return dot(c, float3(0.2126, 0.7152, 0.0722));
    }

    inline float3 cooled(float3 c, float heat) {
        float3 deep = c * c / max(max(c.r, max(c.g, c.b)), 0.02);
        return mix(deep * 0.55, c, smoothstep(0.0, 0.75, heat));
    }

    inline float2 segdist(float2 p, float2 a, float2 b) {
        float2 ab = b - a;
        float h = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
        return float2(length(p - a - ab * h), h);
    }

    inline float sd_shape(Inst i, float2 p) {
        float2 half_size = i.rect.zw * 0.5;
        float2 center = i.rect.xy + half_size;
        return sd_rrect(p - center, half_size, i.shape.x);
    }

    inline float2 shape_normal(Inst i, float2 p) {
        float e = 0.35;
        float dx = sd_shape(i, p + float2(e, 0.0)) - sd_shape(i, p - float2(e, 0.0));
        float dy = sd_shape(i, p + float2(0.0, e)) - sd_shape(i, p - float2(0.0, e));
        float2 g = float2(dx, dy);
        float len = length(g);
        return len > 1e-5 ? g / len : float2(0.0, -1.0);
    }

    constant float CONTINUOUS_K = 1.52866483;

    inline float sd_continuous(float2 p, float2 half_size, float r) {
        float e = CONTINUOUS_K * r;
        float2 q = half_size - abs(p);
        float2 v = float2(e) - q;
        if (v.x <= 0.0 || v.y <= 0.0) { return max(-q.x, -q.y); }
        float u = atan2(v.y, v.x) * (4.0 / 3.14159265) - 1.0;
        float u2 = u * u;
        return length(v) - e * (1.14602295 + u2 * (-0.37573161 + u2 * (0.30796609 - 0.07724354 * u2)));
    }

    inline float sd_rounded(float2 p, float2 half_size, float4 radii) {
        float r = radii.x;
        if (p.x > 0.0) {
            r = select(radii.y, radii.z, p.y > 0.0);
        } else {
            r = select(radii.x, radii.w, p.y > 0.0);
        }
        if (r < 0.0) { return sd_continuous(p, half_size, min(-r, min(half_size.x, half_size.y))); }
        r = min(r, min(half_size.x, half_size.y));
        float2 q = abs(p) - half_size + float2(r);
        return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - r;
    }

    inline float ramp(float d, float fade) {
        if (fade == 0.0) {
            return clamp(d + 0.5, 0.0, 1.0);
        }
        float x = clamp(d / abs(fade), 0.0, 1.0);
        if (fade < 0.0) {
            return x;
        }
        return x * x * (3.0 - 2.0 * x);
    }

    inline float4 unpack_clip_radii(uint w) {
        if (w == 0u) { return float4(0.0); }
        if ((w & 0x60000000u) != 0x60000000u) {
            return float4(as_type<float>(w));
        }
        float step = select(0.5, 2.0, (w & 0x10000000u) != 0u);
        float sgn = select(1.0, -1.0, (w & 0x80000000u) != 0u);
        return float4(
            float(w & 0x7fu),
            float((w >> 7u) & 0x7fu),
            float((w >> 14u) & 0x7fu),
            float((w >> 21u) & 0x7fu)
        ) * (step * sgn);
    }

    inline float clip_alpha(float2 p, float4 c, uint4 packed) {
        float4 f = float4(float2(as_type<half2>(packed.x)), float2(as_type<half2>(packed.y)));
        float4 offset = unpack_unorm4x8_to_float(packed.z);
        float4 hard = float4(p - c.xy, c.zw - p);
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
        if (packed.w != 0u) {
            float2 half_size = (c.zw - c.xy) * 0.5;
            alpha *= clamp(0.5 - sd_rounded(p - c.xy - half_size, half_size, unpack_clip_radii(packed.w)), 0.0, 1.0);
        }
        return alpha;
    }

    inline uint effective_blend_mode(Inst i, constant BackdropEncoding& enc) {
        uint m = (uint(i.t.w) >> 1u) & 7u;
        if ((m == 1u || m == 3u || m == 4u) && enc.present < 0.5) {
            return 0u;
        }
        return m;
    }

    inline float blend_overlay_ch(float b, float s) {
        return select(1.0 - 2.0 * (1.0 - b) * (1.0 - s), 2.0 * b * s, b <= 0.5);
    }

    inline float3 blend_overlay(float3 b, float3 s) {
        return float3(blend_overlay_ch(b.r, s.r), blend_overlay_ch(b.g, s.g), blend_overlay_ch(b.b, s.b));
    }

    inline float blend_soft_light_ch(float b, float s) {
        if (s <= 0.5) {
            return b - (1.0 - 2.0 * s) * b * (1.0 - b);
        }
        float d = select(sqrt(max(b, 0.0)), ((16.0 * b - 12.0) * b + 4.0) * b, b <= 0.25);
        return b + (2.0 * s - 1.0) * (d - b);
    }

    inline float3 blend_soft_light(float3 b, float3 s) {
        return float3(blend_soft_light_ch(b.r, s.r), blend_soft_light_ch(b.g, s.g), blend_soft_light_ch(b.b, s.b));
    }

    inline float4 finish(float4 c0, float2 px, constant Globals& g) {
        float4 c = max(c0, float4(0.0));
        c.a = min(c.a, 1.0);
        if (g.dither > 0.5) {
            uint2 ip = uint2(px);
            float n = (u01(ip.x + pcg(ip.y)) + u01(ip.x * 7919u + pcg(ip.y + 104729u))) - 1.0;
            float3 s = to_srgb(c.rgb);
            float gate = smoothstep(0.0, 3.0 / 255.0, max(s.r, max(s.g, s.b)));
            c = float4(to_lin(max(s + float3(n / 255.0 * gate), float3(0.0))), c.a);
        }
        return c;
    }

    inline float4 fx_fs(
        float4 shaded,
        Inst i,
        float2 px,
        constant Globals& g,
        texture2d<float> backdrop,
        sampler samp,
        constant BackdropEncoding& enc
    ) {
        float ca = clip_alpha(px, i.clip, i.fade);
        if (ca <= 0.0) { return float4(0.0); }
        float4 c = shaded * i.shape.z;
        uint mode = effective_blend_mode(i, enc);
        if (mode == 0u) {
            if (g.srgb > 0.5) {
                float3 cover = min(max(c.rgb, float3(0.0)), float3(c.a));
                float3 straight = select(float3(0.0), cover / c.a, c.a > 1e-6);
                return float4(to_srgb(straight) * c.a + to_srgb(max(c.rgb, float3(0.0)) - cover), c.a) * ca;
            }
            return c * ca;
        }
        float m = max(c.a, max(c.r, max(c.g, c.b)));
        float as_ = clamp(m * ca, 0.0, 1.0);
        if (as_ <= 0.0) { return float4(0.0); }
        float3 cs_lin = select(float3(0.0), clamp(c.rgb / m, float3(0.0), float3(1.0)), m > 1e-6);
        float3 cs = select(cs_lin, to_srgb(cs_lin), g.srgb > 0.5);
        if (mode == 2u) {
            return float4(cs * as_, as_);
        }
        float4 b_lin = bd(px, 1.0, g, backdrop, samp, enc);
        float ab = clamp(b_lin.a, 0.0, 1.0);
        float3 cb_lin = select(float3(0.0), clamp(b_lin.rgb / ab, float3(0.0), float3(1.0)), ab > 1e-6);
        float3 cb = select(cb_lin, to_srgb(cb_lin), g.srgb > 0.5);
        float3 blended = cb * cs;
        if (mode == 3u) { blended = blend_overlay(cb, cs); }
        if (mode == 4u) { blended = blend_soft_light(cb, cs); }
        return float4(mix(cs, blended, ab) * as_, as_);
    }

    inline float2 recover_pixel(VOut in) {
        return in.pos.xy + round((in.px - in.pos.xy) * 256.0) / 256.0;
    }

    vertex VOut fx_vertex(
        uint vi [[vertex_id]],
        uint ii [[instance_id]],
        constant Globals& g [[buffer(0)]],
        const device Inst* insts [[buffer(1)]]
    ) {
        float4 b = insts[ii].bounds;
        float2 corner = float2(float(vi & 1u), float((vi >> 1u) & 1u));
        float2 px = mix(b.xy, b.zw, corner);
        VOut o;
        o.pos = float4(px.x / g.viewport.x * 2.0 - 1.0, 1.0 - px.y / g.viewport.y * 2.0, 0.0, 1.0);
        o.id = ii;
        o.px = px;
        return o;
    }
    """

    public static let glowShader: String = commonPrelude + """
    inline float3 aura_palette(float u, float3 a, float3 b, float3 c) {
        float x = fract(u) * 3.0;
        float w0 = w_smoothstep(1.0, 0.0, min(x, 3.0 - x));
        float w1 = w_smoothstep(1.0, 0.0, abs(x - 1.0));
        float w2 = w_smoothstep(1.0, 0.0, abs(x - 2.0));
        return (a * w0 + b * w1 + c * w2) / max(w0 + w1 + w2, 1e-4);
    }

    inline float mask_tent(texture2d<float> source, sampler samp, float2 uv, float lod) {
        float2 dims = float2(source.get_width(0), source.get_height(0));
        float2 texel = exp2(lod) / max(dims, float2(1.0));
        float2 o = texel * 0.5;
        float s = source.sample(samp, uv + float2(o.x, o.y), level(lod)).a;
        s += source.sample(samp, uv + float2(-o.x, o.y), level(lod)).a;
        s += source.sample(samp, uv + float2(o.x, -o.y), level(lod)).a;
        s += source.sample(samp, uv + float2(-o.x, -o.y), level(lod)).a;
        return s * 0.25;
    }

    inline float4 shade_glow(
        Inst i,
        float2 px,
        constant Globals& g,
        texture2d<float> backdrop,
        texture2d<float> source,
        sampler samp,
        constant BackdropEncoding& enc
    ) {
        Ctx c = make_ctx(i, px);
        float radius = i.p0.x;
        float intensity = i.p0.y;
        float inner = i.p0.z;
        float occl = select(1.0, i.p0.w, effective_blend_mode(i, enc) == 0u);
        float heat = i.p1.z;
        float hot = i.p1.w;

        float b = 0.0;
        if (!c.reduced && i.p1.y > 0.0) {
            b = 0.5 - 0.5 * cos(TAU * c.t / i.p1.y);
            b = b * b * (3.0 - 2.0 * b);
        }
        float amp = i.p1.x;
        intensity *= (1.0 - amp) + amp * b;
        radius *= 1.0 + 0.22 * amp * b;
        radius *= mix(0.72, 1.0, heat);
        intensity *= pow(max(heat, 0.0), 1.6);
        float3 tint = cooled(i.c0.rgb, heat);
        float reach = radius * i.p2.z;

        float3 light = float3(0.0);
        float alpha = 0.0;
        float edge = w_smoothstep(-c.aa, c.aa, c.d);

        if (c.variant == 3) {
            float2 uv = (c.p - i.aux2.xy) / i.aux2.zw;
            float rpx = radius * c.scale;
            float base = log2(max(rpx, 1.0)) - 0.6;
            float m = 0.45 * mask_tent(source, samp, uv, max(base - 1.0, 0.0))
                    + 0.35 * mask_tent(source, samp, uv, max(base, 0.0))
                    + 0.2 * mask_tent(source, samp, uv, base + 1.3);
            float core = source.sample(samp, uv, level(0.0)).a;
            float gl = knee(m * 1.25 * intensity) * 1.1;
            float hotc = core * hot * w_smoothstep(0.55, 1.0, heat);
            light = tint * gl + i.c1.rgb * hotc * intensity * 0.6;
            alpha = min(gl * occl, 1.0);
            return finish(float4(light, alpha), px, g);
        }

        if (c.variant == 0) {
            float out_g = bloom(c.d, radius, reach);
            float in_g = inner * 0.7 * exp(min(c.d, 0.0) / max(0.4 * radius, 1e-4));
            float gl = mix(in_g, out_g, edge);
            float corew = gauss(max(c.d, 0.0), 0.3 * radius) * hot * w_smoothstep(0.6, 1.0, heat);
            float3 col = mix(tint, i.c1.rgb, corew * 0.8);
            float e = knee(gl * intensity * 1.1);
            light = col * e;
            alpha = e * occl;
        } else if (c.variant == 1) {
            float w = max(i.p2.y, c.aa * 0.75);
            float core = gauss(c.d, w);
            float out_g = bloom(c.d, radius, reach) * edge;
            float in_g = inner * bloom(-c.d, radius * 0.6, reach) * (1.0 - edge);
            float3 corec = mix(tint, i.c1.rgb, 0.7 * hot * w_smoothstep(0.5, 1.0, heat));
            float e = knee((out_g + in_g) * intensity);
            light = corec * core * 1.4 * intensity + tint * e * 0.9;
            alpha = core * 0.6 * intensity + e * occl;
        } else {
            float2 pr = rrect_perim(c.q, c.half_size, c.r);
            float u = pr.x / pr.y;
            float flow = 0.0;
            if (!c.reduced) { flow = c.t * i.p2.x; }
            float3 col = aura_palette(u - flow, tint, i.c1.rgb, i.c2.rgb);
            float wob = 0.85 + 0.15 * pgnoise(float2(u * 6.0, flow * 1.7 + 3.0), 6, c.seed);
            float out_g = bloom(c.d, radius, reach) * edge;
            float in_g = inner * exp(min(c.d, 0.0) / max(0.55 * radius, 1e-4)) * (1.0 - edge);
            float hair = gauss(c.d + 0.6, max(i.p2.y, c.aa)) * 0.9;
            float lit = knee((out_g + in_g) * wob * intensity * 1.1);
            light = col * lit + mix(col, float3(1.0), 0.6) * hair * intensity * hot;
            alpha = lit * occl;
        }
        return finish(float4(light, alpha), px, g);
    }

    fragment float4 fx_glow_fragment(
        VOut in [[stage_in]],
        constant Globals& g [[buffer(0)]],
        const device Inst* insts [[buffer(1)]],
        texture2d<float> backdrop [[texture(0)]],
        texture2d<float> source [[texture(1)]],
        sampler samp [[sampler(0)]],
        constant BackdropEncoding& enc [[buffer(4)]]
    ) {
        Inst i = insts[in.id];
        float2 px = recover_pixel(in);
        float4 shaded = shade_glow(i, px, g, backdrop, source, samp, enc);
        return fx_fs(shaded, i, px, g, backdrop, samp, enc);
    }
    """

    public static let pulseShader: String = commonPrelude + """
    inline float shoot(float u) {
        float x = clamp(u, 0.0, 1.0);
        float m = 1.0 - x;
        return 3.0 * m * m * x * (-0.12) + 3.0 * m * x * x * 1.0 + x * x * x;
    }

    inline float beat_env(float x) {
        return select(exp(-x / 0.085), exp(-(x / 0.018) * (x / 0.018)), x < 0.0);
    }

    inline float2 ping_shot(Ctx c, Inst i, float age, float dur) {
        float2 o = i.aux.xy;
        float2 dir = normalize(i.aux.zw);
        float travel = i.p2.x;
        float head_r = i.p2.z;
        if (age < 0.0) { return float2(0.0); }
        float u = age / dur;
        if (c.reduced) {
            float2 dest = o + dir * travel;
            float env = w_smoothstep(0.0, 0.2, age) * exp(-max(age - 0.2, 0.0) * 3.0);
            return float2(env * gauss(length(c.p - dest), head_r * 3.0), 0.0);
        }
        float s_head = shoot(u);
        float s_tail = shoot(u - i.p2.y);
        float2 hpos = o + dir * travel * s_head;
        float2 tpos = o + dir * travel * s_tail;
        float2 sd = segdist(c.p, tpos, hpos);
        float after = max(u - 1.0, 0.0);
        float cool = exp(-after * 3.5);
        float hr = head_r * (1.0 + 0.9 * (1.0 - cool));
        float tailw = head_r * 0.55 * (0.35 + 0.65 * sd.y);
        float tail = gauss(sd.x, tailw) * sd.y * sd.y * 0.8;
        float dh = length(c.p - hpos);
        float head = gauss(dh, hr) + 0.35 * bloom(dh - hr * 0.5, hr * 1.2, hr * 8.0);
        float e = (head + tail) * cool;
        float hot = gauss(dh, hr * 0.45) * cool * cool;
        float fr = 26.0 * (1.0 - exp(-age * 7.0));
        e += exp(-age * 10.0) * w_smoothstep(0.0, 0.03, age) * gauss(length(c.p - o) - fr, 2.0 + age * 6.0) * 0.5;
        return float2(e, hot);
    }

    inline float4 shade_pulse(
        Inst i,
        float2 px,
        constant Globals& g,
        constant BackdropEncoding& enc
    ) {
        Ctx c = make_ctx(i, px);
        int n = int(i.p0.x + 0.5);
        float period = max(i.p0.y, 0.05);
        float reach = i.p0.z;
        float width = i.p0.w;
        float inten = i.p1.x;
        float occl = select(1.0, i.p2.w, effective_blend_mode(i, enc) == 0u);
        float outside = w_smoothstep(-c.aa, c.aa, c.d);
        float e = 0.0;
        float hotv = 0.0;

        if (c.variant == 0) {
            if (c.reduced) {
                e = 0.35 * bloom(c.d, reach * 0.18, reach * 0.8);
            } else {
                for (int k = 0; k < n; k++) {
                    float ph = fract(c.t / period + float(k) / float(n));
                    float r = reach * (1.0 - pow(1.0 - ph, 2.2));
                    float w = width * (1.0 + 2.2 * ph);
                    float a = pow(1.0 - ph, 1.6) * w_smoothstep(0.0, 0.08, ph);
                    float ring = gauss(c.d - r, w);
                    float wash = w_smoothstep(r + w, r - w, c.d) * exp(-(r - c.d) / max(reach * 0.22, 1.0));
                    e += a * (ring + 0.22 * wash);
                }
                e += 0.18 * bloom(c.d, reach * 0.1, reach * 0.6);
            }
            e *= outside;
        } else if (c.variant == 1) {
            float b = 0.5;
            if (!c.reduced) { b = 0.5 - 0.5 * cos(TAU * c.t / period); b = b * b * (3.0 - 2.0 * b); }
            float r = reach * (0.55 + 0.45 * b);
            e = (0.45 + 0.55 * b) * bloom(c.d, r, r * 5.0) * outside;
            hotv = 0.25 * b * gauss(max(c.d, 0.0), r * 0.25);
        } else if (c.variant == 2) {
            float beat = 0.3;
            float ring = 0.0;
            if (!c.reduced) {
                float tp = c.t / period;
                float kb = floor(tp);
                beat = 0.0;
                for (int k = -1; k < 3; k++) {
                    float x = tp - (kb - float(k));
                    beat += beat_env(x) + 0.62 * beat_env(x - 0.17);
                    float age = x * period;
                    if (age > 0.0) {
                        float rr = reach * (1.0 - exp(-age * 4.5));
                        ring += exp(-age * 3.2) * w_smoothstep(0.0, 0.03, age) * (1.0 - w_smoothstep(0.7, 1.3, age)) * gauss(c.d - rr, width * (1.0 + age * 3.0));
                    }
                }
                float edge = reach + width * 16.0;
                ring *= 1.0 - w_smoothstep(edge * 0.8, edge, c.d);
            }
            float r = reach * 0.22 * (1.0 + 0.35 * beat);
            e = ((0.25 + 0.75 * beat) * bloom(c.d, r, reach) + 0.55 * ring) * outside;
            hotv = 0.35 * beat * gauss(max(c.d, 0.0), r * 0.25) * outside;
        } else if (c.variant == 3) {
            float dur = max(i.p1.z, 0.05);
            float age0 = c.t - i.p1.y;
            int shots = 1;
            float age = age0;
            if (i.p1.w > 0.0 && age0 > 0.0) {
                age = age0 - floor(age0 / i.p1.w) * i.p1.w;
                shots = 3;
            }
            for (int k = 0; k < shots; k++) {
                float a = age + float(k) * i.p1.w;
                if (a > age0 + 1e-4 || a > dur * 2.2) { break; }
                float2 pe = ping_shot(c, i, a, dur);
                e += pe.x;
                hotv += pe.y;
            }
        } else {
            float dur = max(i.p1.z, 0.05);
            float age = c.t - i.p1.y;
            if (age >= 0.0 && age < dur) {
                float u = age / dur;
                float r = length(c.p - i.aux.xy);
                float inside = w_smoothstep(c.aa, -c.aa, c.d);
                if (c.reduced) {
                    e = 0.06 * (1.0 - u) * w_smoothstep(0.0, 0.08, u) * inside;
                } else {
                    float rr = reach * (1.0 - pow(1.0 - u, 3.0));
                    float w = width * (1.0 + 3.0 * u);
                    float fade = pow(1.0 - u, 1.5);
                    float ring = gauss(r - rr, w) * fade * 0.55;
                    float fill = w_smoothstep(rr + w, rr - w * 3.0, r) * 0.05 * (1.0 - u) * (1.0 - u) * w_smoothstep(0.0, 0.05, u);
                    e = (ring * 0.7 + fill) * inside;
                    hotv = ring * 0.1 * inside;
                }
            }
        }
        float3 col = i.c0.rgb * e + i.c1.rgb * hotv;
        return finish(float4(col * inten, (e + hotv) * occl * inten), px, g);
    }

    fragment float4 fx_pulse_fragment(
        VOut in [[stage_in]],
        constant Globals& g [[buffer(0)]],
        const device Inst* insts [[buffer(1)]],
        texture2d<float> backdrop [[texture(0)]],
        sampler samp [[sampler(0)]],
        constant BackdropEncoding& enc [[buffer(4)]]
    ) {
        Inst i = insts[in.id];
        float2 px = recover_pixel(in);
        float4 shaded = shade_pulse(i, px, g, enc);
        return fx_fs(shaded, i, px, g, backdrop, samp, enc);
    }
    """

    public static let electricShader: String = commonPrelude + """
    struct Bolt { float core; float halo; };

    inline Bolt shade_bolt(float dist, float w, float gr) {
        Bolt b;
        b.core = gauss(dist, w);
        float o = dist / gr;
        b.halo = 0.35 / (1.0 + o * o) * (1.0 - w_smoothstep(gr * 2.5, gr * 5.0, dist)) + 0.65 * gauss(dist, gr * 0.6);
        return b;
    }

    inline float lat(float dv, float a, float b, float step_len) {
        float s = (b - a) / step_len;
        float k = rsqrt(1.0 + min(s * s, 3.0));
        return dv * mix(k, 1.0, w_smoothstep(1.5, 8.0, abs(dv)));
    }

    inline float3 fork_col(Inst i, float heat) {
        return mix(mix(i.c2.rgb, i.c0.rgb, w_smoothstep(0.0, 0.5, heat)), i.c1.rgb, w_smoothstep(0.6, 1.0, heat));
    }

    inline float4 shade_electric(
        Inst i,
        float2 px,
        constant Globals& g,
        const device float4* data,
        constant BackdropEncoding& enc
    ) {
        Ctx c = make_ctx(i, px);
        float w = max(i.p0.w, c.aa * 0.7);
        float inten = i.p1.x;
        float gr = max(i.p1.y, 1e-3);
        float gap = i.p2.y;
        uint first = uint(i.xf.x);
        uint n = uint(i.xf.y);
        uint nf = uint(i.xf.z);
        uint ns = uint(i.xf.w);
        uint q4 = n >> 2u;
        float4 fl = data[first + 1u];
        uint base = first + 2u;

        float core = 0.0;
        float halo = 0.0;
        float3 fork_hot = float3(0.0);

        if (c.variant == 0) {
            float2 a = i.aux.xy;
            float2 bb = i.aux.zw;
            float L = max(length(bb - a), 1.0);
            float2 dir = (bb - a) / L;
            float2 nrm = float2(-dir.y, dir.x);
            float2 rel = c.p - a;
            float u = dot(rel, dir) / L;
            float v = dot(rel, nrm);
            float uc = clamp(u, 0.0, 1.0);
            float fi = uc * float(n - 1u);
            uint i0 = min(uint(fi), n - 2u);
            float f = fi - float(i0);
            float step_len = L / float(n - 1u);
            for (uint k = 0u; k < ns; k++) {
                uint sb = base + k * q4;
                float d0 = dat1(data, sb, i0);
                float d1 = dat1(data, sb, i0 + 1u);
                float dd = length(float2((u - uc) * L, lat(v - mix(d0, d1, f), d0, d1, step_len)));
                uint hb = base + (ns + k) * q4;
                float dh = length(float2((u - uc) * L, v - mix(dat1(data, hb, i0), dat1(data, hb, i0 + 1u), f)));
                float bw = select(w * 0.6, w, k == 0u);
                Bolt bo = shade_bolt(dd, bw, gr);
                bo.halo = 0.4 * shade_bolt(dh, bw, gr).halo + 0.6 * shade_bolt(dd, bw, gr * 0.3).halo;
                float kb = select(0.32, 1.0, k == 0u) * fl[k];
                core += bo.core * kb;
                halo += bo.halo * kb;
            }
            halo += 0.6 * (gauss(length(c.p - a), gr * 0.8) + gauss(length(c.p - bb), gr * 0.8));
            core += 0.5 * (gauss(length(c.p - a), w * 2.5) + gauss(length(c.p - bb), w * 2.5));
            uint fb = base + 2u * ns * q4;
            for (uint j = 0u; j < nf; j++) {
                float4 h0 = data[fb];
                float4 h1 = data[fb + 1u];
                float2 o = h0.xy;
                float2 fd = h0.zw;
                float len = h1.x;
                float2 fr = c.p - o;
                float fu = dot(fr, fd) / len;
                float fv = dot(fr, float2(-fd.y, fd.x));
                float fuc = clamp(fu, 0.0, h1.y);
                float ffi = fuc * 15.0;
                uint j0 = min(uint(ffi), 14u);
                float s0 = dat1(data, fb + 2u, j0);
                float s1 = dat1(data, fb + 2u, j0 + 1u);
                float fdist = length(float2((fu - fuc) * len, lat(fv - mix(s0, s1, ffi - float(j0)), s0, s1, len / 15.0)));
                float taper = 1.0 - 0.7 * fuc;
                Bolt bo = shade_bolt(fdist, w * 0.6 * taper, gr * 0.55);
                fork_hot += fork_col(i, h1.w) * (bo.core * 1.1 + bo.halo * 0.45) * h1.z * taper;
                fb += 6u;
            }
        } else {
            float2 pr = rrect_perim(c.q, c.half_size, c.r);
            float s = pr.x;
            float total = pr.y;
            bool calm = c.variant == 2;
            float fi = s / total * float(n);
            uint i0 = uint(floor(fi)) % n;
            uint i1 = (i0 + 1u) % n;
            float f = fi - floor(fi);
            float step_len = total / float(n);
            for (uint k = 0u; k < ns; k++) {
                uint sb = base + k * q4;
                float d0 = dat1(data, sb, i0);
                float d1 = dat1(data, sb, i1);
                float dd = abs(lat(c.d - gap - mix(d0, d1, f), d0, d1, step_len));
                uint hb = base + (ns + k) * q4;
                float dh = abs(c.d - gap - mix(dat1(data, hb, i0), dat1(data, hb, i1), f));
                uint cb = base + (2u * ns + k) * q4;
                float crawl = mix(dat1(data, cb, i0), dat1(data, cb, i1), f);
                float bw = select(w * 0.6, w, k == 0u);
                Bolt bo = shade_bolt(dd, bw, gr);
                bo.halo = 0.4 * shade_bolt(dh, bw, gr).halo + 0.6 * shade_bolt(dd, bw, gr * 0.3).halo;
                float kb = select(0.32, 1.0, k == 0u) * fl[k] * crawl;
                core += bo.core * kb;
                halo += bo.halo * kb;
            }
            if (calm) {
                float sp = i.p0.z * 0.35;
                float bu = fract(s / total - c.t * 0.07 * sp);
                for (int k = 0; k < 3; k++) {
                    float x = fract(bu - float(k) / 3.0 + 0.5) - 0.5;
                    float bead = gauss(x * total, 18.0);
                    halo += bead * gauss(c.d - gap, gr * 0.8) * 0.9;
                    core += bead * gauss(c.d - gap, w * 1.5) * 0.6;
                }
            }
            uint fb = base + 3u * ns * q4;
            for (uint j = 0u; j < nf; j++) {
                float4 h0 = data[fb];
                float4 h1 = data[fb + 1u];
                float len = h1.x;
                float dsv = s - h0.x;
                dsv -= total * round(dsv / total);
                float fu = (c.d - gap - h0.z) / len;
                float fuc = clamp(fu, 0.0, h1.y);
                float ffi = fuc * 15.0;
                uint j0 = min(uint(ffi), 14u);
                float s0 = dat1(data, fb + 2u, j0);
                float s1 = dat1(data, fb + 2u, j0 + 1u);
                float fdist = length(float2((fu - fuc) * len, lat(dsv - mix(s0, s1, ffi - float(j0)), s0, s1, len / 15.0)));
                float taper = 1.0 - 0.7 * fuc;
                Bolt bo = shade_bolt(fdist, w * 0.6 * taper, gr * 0.55);
                fork_hot += fork_col(i, h1.w) * (bo.core * 1.1 + bo.halo * 0.45) * h1.z * taper;
                fb += 6u;
            }
        }
        float occl = select(1.0, i.p2.w, effective_blend_mode(i, enc) == 0u);
        float3 rgb = (i.c1.rgb * core * 1.3 + i.c0.rgb * halo * 0.75 + fork_hot) * inten;
        float a = (core * 0.7 + halo * occl + lum(fork_hot) * 0.5) * inten;
        return finish(float4(rgb, a), px, g);
    }

    fragment float4 fx_electric_fragment(
        VOut in [[stage_in]],
        constant Globals& g [[buffer(0)]],
        const device Inst* insts [[buffer(1)]],
        const device float4* data [[buffer(2)]],
        texture2d<float> backdrop [[texture(0)]],
        sampler samp [[sampler(0)]],
        constant BackdropEncoding& enc [[buffer(4)]]
    ) {
        Inst i = insts[in.id];
        float2 px = recover_pixel(in);
        float4 shaded = shade_electric(i, px, g, data, enc);
        return fx_fs(shaded, i, px, g, backdrop, samp, enc);
    }
    """

    public static let fireShader: String = commonPrelude + """
    inline float3 fire_ramp(float T, float3 c0, float3 c1, float3 c2) {
        float3 col = mix(float3(0.012, 0.009, 0.008), c0, w_smoothstep(0.04, 0.22, T));
        col = mix(col, c1, w_smoothstep(0.2, 0.5, T));
        col = mix(col, c2, w_smoothstep(0.45, 0.78, T));
        col = mix(col, float3(1.0, 0.92, 0.74), w_smoothstep(0.8, 1.08, T));
        return col;
    }

    inline float fbm4(float2 p0, uint seed) {
        float2 p = p0; float a = 0.5; float s = 0.0;
        for (uint o = 0u; o < 4u; o++) {
            s += a * gnoise(p, seed + o * 131u);
            p = rot_mul(p) * 2.03;
            a *= 0.5;
        }
        return s / 0.9375;
    }

    inline float4 flames(Ctx c, Inst i, constant BackdropEncoding& enc) {
        float H = i.p0.x;
        float sc = max(i.p0.y, 1.0);
        float tr = c.t * i.p0.z;
        float2 nrm = sd_grad(c);
        float up = clamp(-nrm.y, 0.0, 1.0);
        float span = w_smoothstep(c.half_size.x + 2.0, c.half_size.x - c.r * 0.9 - 2.0, abs(c.q.x));
        float hl = H * w_smoothstep(0.15, 0.95, up) * span;
        if (hl < 0.5) { return float4(0.0); }
        float y = c.d + 1.5;
        float yn = y / hl;
        if (yn > 1.6 || yn < -0.2) { return float4(0.0); }
        float x = c.p.x / sc;
        float fl = 1.0 + 0.2 * gnoise(float2(x * 0.45, c.t * 1.3), c.seed + 7u) + 0.07 * gnoise(float2(x * 1.1 + 9.0, c.t * 8.0), c.seed + 8u);
        float yh = yn / max(fl, 0.4);
        float2 sw = float2(0.0);
        if (i.p3.x > 0.0) { sw = i.p3.x * float2(sin(y / sc * 0.7 + tr * 0.4), 0.0); }
        float2 wq = float2(x * 0.7, y / sc * 0.45 - tr * 1.05);
        float2 w = float2(gnoise(wq, c.seed), gnoise(wq + float2(3.7, 1.9), c.seed + 1u)) * i.p2.x * (0.2 + 0.8 * yh);
        float n = fbm4(float2(x * 1.05, y / sc * 0.5 - tr * 1.6) + w + sw, c.seed + 2u);
        float dens = (1.0 - yh) * 1.2 + n * 0.8 - 0.08;
        float body = w_smoothstep(0.0, 0.06, dens) * w_smoothstep(-0.2, 0.05, yn);
        float T = clamp(dens * (0.95 - 0.5 * yh), 0.0, 1.1);
        float3 col = fire_ramp(T, i.c0.rgb, i.c1.rgb, i.c2.rgb);
        float e = body * (0.3 + 0.75 * T * T);
        float3 emis = col * e;
        float smoke = w_smoothstep(-0.32, -0.02, dens) * (1.0 - body) * w_smoothstep(0.35, 0.9, yh) * 0.12;
        float bg = i.p2.z * 0.22 * exp(-max(c.d, 0.0) / max(hl * 0.12, 1.0)) * w_smoothstep(-1.0, 0.5, c.d) * span;
        emis += i.c1.rgb * bg;
        float occl = select(1.0, i.p2.w, effective_blend_mode(i, enc) == 0u);
        return float4(emis, body * occl + smoke);
    }

    inline float3 blackbody(float k) {
        float t = k / 100.0;
        float g = clamp((99.4708 * log(max(t, 1.0)) - 161.1196) / 255.0, 0.0, 1.0);
        float b = select(clamp((138.5177 * log(max(t - 10.0, 1.0)) - 305.0448) / 255.0, 0.0, 1.0), 0.0, t <= 19.0);
        return to_lin(float3(1.0, g, b));
    }

    inline float3 flame_light(float T, float gain) {
        float x = max(T, 0.0);
        float e = gain * x * x * x * w_smoothstep(0.08, 0.3, x);
        return float3(1.0) - exp(-blackbody(1000.0 + 1700.0 * min(x, 1.3)) * e);
    }

    inline float4 sim_at(texture2d<float> source, sampler samp, float2 uv) {
        float2 dim = float2(source.get_width(0), source.get_height(0));
        float2 g = uv * dim - 0.5;
        float2 i = floor(g);
        float2 f = g - i;
        float2 w0 = (1.0 - f) * (1.0 - f) * (1.0 - f) / 6.0;
        float2 w1 = (4.0 - 6.0 * f * f + 3.0 * f * f * f) / 6.0;
        float2 w3 = f * f * f / 6.0;
        float2 w2 = 1.0 - w0 - w1 - w3;
        float2 s0 = w0 + w1;
        float2 s1 = w2 + w3;
        float2 o0 = (i - 0.5 + w1 / s0) / dim;
        float2 o1 = (i + 1.5 + w3 / s1) / dim;
        float4 a = source.sample(samp, float2(o0.x, o0.y), level(0.0));
        float4 b = source.sample(samp, float2(o1.x, o0.y), level(0.0));
        float4 c = source.sample(samp, float2(o0.x, o1.y), level(0.0));
        float4 d = source.sample(samp, float2(o1.x, o1.y), level(0.0));
        return mix(mix(a, b, s1.x), mix(c, d, s1.x), s1.y);
    }

    inline float4 sim_flames(Ctx c, Inst i, texture2d<float> source, sampler samp) {
        float2 ext = i.aux.zw;
        float2 uv = (c.p - i.aux.xy) / ext;
        if (any(uv < float2(0.0)) || any(uv > float2(1.0))) { return float4(0.0); }
        float4 s = sim_at(source, samp, uv);
        float T = s.z;
        float m = min(min(c.p.x - i.aux.x, i.aux.x + i.p3.y - c.p.x), c.p.y - i.aux.y);
        float win = w_smoothstep(0.0, 18.0, m);
        float3 rgb = flame_light(T, 6.0) * win;
        float sm = s.w * win;
        float a = 0.0;
        if (sm > 0.002) {
            a = (1.0 - exp(-sm * 1.2)) * i.p2.w * 1.6;
            float lit = 0.0;
            for (int k = 1; k < 5; k++) {
                float tk = sim_at(source, samp, uv + float2(0.0, float(k) * 7.0 / ext.y)).z;
                lit += tk * tk / float(k);
            }
            float3 warm = float3(1.0, 0.45, 0.18) * min(lit, 1.0) * 0.3;
            rgb += a * (float3(0.11, 0.11, 0.115) + warm);
        }
        float vis = w_smoothstep(0.12, 0.35, T) * win;
        return float4(rgb, min(a + vis * i.p2.w * 0.5, 1.0));
    }

    inline float4 plasma(Ctx c, Inst i) {
        float sc = max(i.p0.y, 1.0);
        float thick = max(i.p0.x * i.p2.y * 0.3, 2.5);
        float2 pr = rrect_perim(c.q, c.half_size, c.r);
        float u = pr.x / pr.y;
        float d = c.d - thick * 0.45;
        if (abs(d) > thick * 4.0) { return float4(0.0); }
        float P = max(round(pr.y / (sc * 2.5)), 3.0);
        float flow = c.t * i.p0.z * (0.35 + 0.25 * i.p3.x);
        float warp = 0.6 * pgnoise(float2(u * P - flow * 0.6, c.t * 0.35), int(P), c.seed + 3u);
        float r1 = 1.0 - abs(pgnoise(float2(u * P - flow * 1.4, d / sc * 3.2 + warp), int(P), c.seed));
        float r2 = 1.0 - abs(pgnoise(float2(u * P * 2.0 + flow * 1.1, d / sc * 4.5 - warp - c.t * 0.6), int(P * 2.0), c.seed + 1u));
        float fil = pow(r1, 10.0) + 0.45 * pow(r2, 12.0);
        float breathe = 0.78 + 0.22 * pgnoise(float2(u * 3.0 - c.t * 0.25, c.t * 0.2), 3, c.seed + 5u);
        float env = exp(-(d * d) / (thick * thick));
        float halo = exp(-max(d, 0.0) / (thick * 0.9)) * w_smoothstep(-thick, 0.0, d);
        float E = env * (0.18 + 1.2 * fil) * breathe;
        float3 rgb = i.c0.rgb * halo * 0.28 + i.c1.rgb * E * 0.55 + i.c2.rgb * fil * env * breathe * 0.9
                   + float3(1.0) * pow(fil, 3.0) * env * breathe * 0.35;
        return float4(rgb, (E * 0.5 + halo * 0.1) * i.p2.w * 2.0);
    }

    inline float4 shade_fire(
        Inst i,
        float2 px,
        constant Globals& g,
        const device float4* data,
        texture2d<float> source,
        sampler samp,
        constant BackdropEncoding& enc
    ) {
        Ctx c = make_ctx(i, px);
        float inten = i.p0.w;
        float4 o = float4(0.0);
        if (c.variant == 0) {
            o = flames(c, i, enc);
        } else if (c.variant == 1) {
            o = plasma(c, i);
        } else if (c.variant == 4) {
            o = sim_flames(c, i, source, samp);
        }
        float3 emis = o.rgb;
        float alpha = o.a;

        uint ef = uint(i.xf.x);
        uint en = uint(i.xf.y);
        for (uint k = 0u; k < en; k++) {
            float4 a = data[ef + k * 2u];
            float4 b = data[ef + k * 2u + 1u];
            float2 sd = segdist(c.p, a.xy - a.zw, a.xy);
            float T = b.y;
            float core = gauss(sd.x, b.x);
            float halo = gauss(sd.x, b.x * 3.0) * 0.12;
            emis += flame_light(0.45 + T * 0.75, 6.0) * (core * 1.4 + halo) * T;
            alpha += core * T * 0.5;
        }
        return finish(float4(emis * inten, min(alpha, 1.0) * inten), px, g);
    }

    fragment float4 fx_fire_fragment(
        VOut in [[stage_in]],
        constant Globals& g [[buffer(0)]],
        const device Inst* insts [[buffer(1)]],
        const device float4* data [[buffer(2)]],
        texture2d<float> backdrop [[texture(0)]],
        texture2d<float> source [[texture(1)]],
        sampler samp [[sampler(0)]],
        constant BackdropEncoding& enc [[buffer(4)]]
    ) {
        Inst i = insts[in.id];
        float2 px = recover_pixel(in);
        float4 shaded = shade_fire(i, px, g, data, source, samp, enc);
        return fx_fs(shaded, i, px, g, backdrop, samp, enc);
    }
    """

    public static let distortShader: String = commonPrelude + """
    inline float3 frosted_glass(float3 c, float k) {
        float l = lum(c);
        float3 sat = max(mix(float3(l), c, 1.0 + 0.9 * k), float3(0.0));
        float3 e = to_srgb(sat);
        return to_lin(e * (1.0 - 0.32 * k) + float3(0.11 * k));
    }

    inline float lens_sd(Inst i, float2 q, float2 half_size, float r, float2 ctr) {
        float da = sd_rrect(q, half_size, r);
        if (i.p3.z <= 0.0) { return da; }
        float2 cb = i.p3.xy + i.p3.zw * 0.5 - ctr;
        float db = sd_rrect(q - cb, i.p3.zw * 0.5, i.p2.w);
        return mix(smin(da, db, i.p2.z), db, i.shape.w);
    }

    inline float bend_at(float t) {
        float u = clamp(1.0 - t, 0.0, 0.9999);
        float pw = 3.0;
        float slope = pow(u, pw - 1.0) * pow(max(1.0 - pow(u, pw), 1e-6), 1.0 / pw - 1.0);
        float tilt = atan(min(slope, 1e4));
        float bent = asin(sin(tilt) / 1.5);
        return tan(tilt - bent);
    }

    inline float4 shade_distort(
        Inst i,
        float2 px,
        constant Globals& g,
        texture2d<float> backdrop,
        sampler samp,
        texture2d<float> blurred,
        constant BackdropEncoding& enc
    ) {
        Ctx c = make_ctx(i, px);
        float s = c.scale;

        if (c.variant == 0) {
            float H = i.p0.x;
            float m;
            if (i.p1.x > 0.5) {
                m = w_smoothstep(c.aa, -c.aa * 8.0, c.d);
            } else {
                float above = i.rect.y - c.p.y;
                float side = w_smoothstep(c.half_size.x + 2.0, c.half_size.x - c.r - 4.0, abs(c.q.x));
                m = w_smoothstep(1.0, 1.0 + H * 0.3, above) * (1.0 - w_smoothstep(H * 0.45, H, above)) * side;
            }
            if (m <= 0.0) { return float4(0.0); }
            float t = c.reduced ? 0.0 : c.t;
            float2 q = c.p / max(i.p0.y, 1.0) + float2(0.0, t * i.p0.z);
            float2 o = float2(fbm3(q, c.seed), fbm3(q * float2(1.0, 0.7) + float2(7.3, 2.1), c.seed + 5u)) * i.p0.w;
            float4 col = bd(c.p + o * m, s, g, backdrop, samp, enc);
            return float4(col.rgb, 1.0) * w_smoothstep(0.0, 0.02, m);
        }
        if (c.variant == 1) {
            float age = c.t - i.p1.x;
            float dur = max(i.p1.y, 0.05);
            if (age < 0.0 || age > dur) { return float4(0.0); }
            float u = age / dur;
            float2 rel = c.p - i.aux.xy;
            float r = length(rel);
            float2 dir = rel / max(r, 1e-3);
            float fade = (1.0 - u) * (1.0 - u);
            if (c.reduced) {
                float gl = gauss(r, i.p0.x * 0.25) * 0.12 * fade * w_smoothstep(0.0, 0.1, u);
                return float4(bd(c.p, s, g, backdrop, samp, enc).rgb * gl, 0.0);
            }
            float R = i.p0.x * (1.0 - pow(1.0 - u, 2.6));
            float w = i.p0.y * (1.0 + 1.5 * u);
            float x = (r - R) / w;
            float f = x * exp(-x * x) * 2.33;
            float2 off = -dir * f * i.p0.z * fade;
            float ca = i.p0.w * abs(f) * fade;
            float rr = bd(c.p + off * (1.0 + ca), s, g, backdrop, samp, enc).r;
            float gg = bd(c.p + off, s, g, backdrop, samp, enc).g;
            float bb = bd(c.p + off * (1.0 - ca), s, g, backdrop, samp, enc).b;
            float lit = max(-f, 0.0) * 0.12 * fade * lum(float3(rr, gg, bb));
            float m = w_smoothstep(0.0, 0.01, abs(f) * fade);
            return float4(float3(rr, gg, bb) + lit, 1.0) * m;
        }
        if (c.variant == 2) {
            float d = lens_sd(i, c.q, c.half_size, c.r, c.c);
            float presence = i.p1.x;
            float e = 0.5;
            float gx = lens_sd(i, c.q + float2(e, 0.0), c.half_size, c.r, c.c) - lens_sd(i, c.q - float2(e, 0.0), c.half_size, c.r, c.c);
            float gy = lens_sd(i, c.q + float2(0.0, e), c.half_size, c.r, c.c) - lens_sd(i, c.q - float2(0.0, e), c.half_size, c.r, c.c);
            float2 nrm = float2(gx, gy) / max(length(float2(gx, gy)), 1e-5);
            float coverage = clamp(0.5 - d * s, 0.0, 1.0);
            float sd = lens_sd(i, c.q - float2(0.0, 5.0 * presence), c.half_size, c.r, c.c);
            float fall = exp(-pow(max(sd + 2.0, 0.0), 2.0) / (2.0 * 9.0 * 9.0));
            float contact = exp(-pow(max(d, 0.0), 2.0) / 6.0);
            float dark = min(i.p1.z * presence * (0.55 * fall + 0.45 * contact), 1.0) * (1.0 - coverage);
            if (coverage <= 0.0) {
                return float4(0.0, 0.0, 0.0, dark);
            }
            float depth = -d;
            float bevel = max(i.p0.x, 0.5);
            float tt = clamp(depth / bevel, 0.0, 1.0);
            float bend = i.p0.y * bend_at(tt) * presence;
            float mag = mix(1.0, i.p0.w, presence);
            float2 ctr = c.c;
            float2 inward = -nrm;
            float dsp = i.p0.z;
            float2 local = c.p - ctr;
            float2 srcg = ctr + (local + inward * bend) / mag;
            float2 srcr = ctr + (local + inward * bend * (1.0 - dsp)) / mag;
            float2 srcb = ctr + (local + inward * bend * (1.0 + dsp)) / mag;
            float3 col = float3(
                bd(srcr, s, g, backdrop, samp, enc).r,
                bd(srcg, s, g, backdrop, samp, enc).g,
                bd(srcb, s, g, backdrop, samp, enc).b
            );
            float frost = i.p1.y;
            if (frost > 0.0 && i.xf.x > 0.5) {
                float3 blr = float3(
                    bdb(srcr, s, g, blurred, samp, enc).r,
                    bdb(srcg, s, g, blurred, samp, enc).g,
                    bdb(srcb, s, g, blurred, samp, enc).b
                );
                col = mix(col, blr, i.xf.y);
                float k = presence * w_smoothstep(0.0, 0.6, frost);
                col = frosted_glass(col, k);
                uint2 ip = uint2(px);
                float n = u01(ip.x + pcg(ip.y + 7u)) - u01(ip.x * 7919u + pcg(ip.y + 31u));
                col = to_lin(max(to_srgb(col) + float3(n * 1.6 / 255.0 * k), float3(0.0)));
            } else {
                float rim = bend / max(1.118 * i.p0.y, 1e-3);
                float soften = min(pow(rim, 1.5) * 0.55, 1.0);
                if (soften > 1e-3 || frost > 0.0) {
                    float rad = mix(1.2, 10.0, frost);
                    float j = ign(px) * TAU;
                    float3 acc = float3(0.0);
                    for (int k = 0; k < 8; k++) {
                        float a = j + float(k) * 2.39996;
                        float rr = rad * sqrt((float(k) + 0.5) / 8.0);
                        acc += bd(srcg + float2(cos(a), sin(a)) * rr, s, g, backdrop, samp, enc).rgb;
                    }
                    acc /= 8.0;
                    col = mix(col, acc, clamp(max(soften, frost), 0.0, 1.0));
                }
            }
            col = mix(col, col * i.c0.rgb, i.p2.y * presence);
            float la = i.p2.x;
            float2 L = float2(cos(la), sin(la));
            float facing = max(dot(nrm, L), 0.0);
            float away = max(-dot(nrm, L), 0.0);
            float sky = clamp(0.5 - 0.5 * c.q.y / c.half_size.y, 0.0, 1.0);
            float rimk = i.p1.w;
            float fres = pow(1.0 - tt, 3.0) * 0.05 * (0.25 + 0.75 * sky);
            float line = gauss(depth - 0.75, 0.55);
            float glow = gauss(depth - 1.4, 2.4);
            float spec = line * (0.9 * pow(facing, 2.5) + 0.35 * pow(away, 3.0)) + glow * 0.1 * pow(facing, 4.0);
            float inner = gauss(tt - 0.32, 0.18) * away * away * 0.06;
            float edge = gauss(depth - 0.3, 0.45) * 0.12;
            float light = (0.004 + fres + spec + inner + edge) * presence * rimk;
            col = col * (1.0 - 0.04 * presence) + float3(light);
            float3 base = bd(c.p, s, g, backdrop, samp, enc).rgb * (1.0 - dark);
            return float4(mix(base, col, coverage), 1.0);
        }
        if (c.variant == 3) {
            float feather = max(i.p1.w, c.aa);
            float m = w_smoothstep(feather * 0.5, -feather * 0.5, c.d);
            if (m <= 0.0) { return float4(0.0); }
            float2 uv = c.q / c.half_size;
            float k = i.p0.x;
            float2 bu = uv * (1.0 + k * dot(uv, uv)) / (1.0 + k);
            float inside = w_smoothstep(1.0, 0.985, max(abs(bu.x), abs(bu.y)));
            float2 src = c.c + bu * c.half_size;
            float ca = i.p0.w;
            float3 col = float3(
                bd(src + float2(ca, 0.0), s, g, backdrop, samp, enc).r,
                bd(src, s, g, backdrop, samp, enc).g,
                bd(src - float2(ca, 0.0), s, g, backdrop, samp, enc).b
            );
            float gw = 3.0;
            float3 gl = (
                bd(src + float2(gw, 0.0), s, g, backdrop, samp, enc).rgb +
                bd(src - float2(gw, 0.0), s, g, backdrop, samp, enc).rgb +
                bd(src + float2(0.0, gw), s, g, backdrop, samp, enc).rgb +
                bd(src - float2(0.0, gw), s, g, backdrop, samp, enc).rgb
            ) * 0.25;
            col += gl * i.p1.y;
            float per = max(i.p0.y, 3.0 * c.aa);
            float sl = 0.5 + 0.5 * cos(TAU * (c.p.y - i.rect.y) / per);
            col *= 1.0 - i.p0.z * (1.0 - sl);
            uint col3 = uint(floor(px.x)) % 3u;
            float3 grille = select(select(float3(0.94, 0.94, 1.0), float3(0.94, 1.0, 0.94), col3 == 1u), float3(1.0, 0.94, 0.94), col3 == 0u);
            col *= grille;
            float roll = c.reduced ? 0.0 : gauss(fract((c.p.y - i.rect.y) / i.rect.w - c.t * 0.12) - 0.5, 0.06) * i.p1.z;
            col += float3(roll) * 0.06;
            col *= 1.0 - i.p1.x * pow(dot(uv, uv) * 0.5, 1.5);
            col *= inside;
            return float4(col, 1.0) * m;
        }
        float feather = max(i.p0.w, c.aa);
        float m = w_smoothstep(feather * 0.5, -feather * 0.5, c.d);
        if (m <= 0.0) { return float4(0.0); }
        float2 o = i.p0.xy;
        float gx = 0.0;
        if (i.p0.z > 0.0 && !c.reduced) {
            float slice = floor((c.p.y - i.rect.y) / 6.0);
            float fr = floor(c.t * 12.0);
            uint hsl = hu(c.seed + as_type<uint>(int(slice)), as_type<uint>(int(fr)));
            if (u01(hsl) < 0.12 * i.p0.z) { gx = (u01(hsl + 1u) - 0.5) * 16.0 * i.p0.z; }
        }
        float2 p = c.p + float2(gx, 0.0);
        float3 col = float3(
            bd(p + o, s, g, backdrop, samp, enc).r,
            bd(p, s, g, backdrop, samp, enc).g,
            bd(p - o, s, g, backdrop, samp, enc).b
        );
        return float4(col, 1.0) * m;
    }

    fragment float4 fx_distort_fragment(
        VOut in [[stage_in]],
        constant Globals& g [[buffer(0)]],
        const device Inst* insts [[buffer(1)]],
        texture2d<float> backdrop [[texture(0)]],
        sampler samp [[sampler(0)]],
        texture2d<float> blurred [[texture(2)]],
        constant BackdropEncoding& enc [[buffer(4)]]
    ) {
        Inst i = insts[in.id];
        float2 px = recover_pixel(in);
        float4 shaded = shade_distort(i, px, g, backdrop, samp, blurred, enc);
        return fx_fs(shaded, i, px, g, backdrop, samp, enc);
    }
    """

    public static let motionShader: String = commonPrelude + """
    inline float4 src_at(Inst i, float2 l, texture2d<float> source, sampler samp) {
        float2 uv = (l - i.aux2.xy) / i.aux2.zw;
        return source.sample(samp, uv, level(0.0));
    }

    inline float3 pose_at(const device float4* data, uint base, uint k, float2 p) {
        float4 m = data[base + k * 2u];
        float4 tw = data[base + k * 2u + 1u];
        return float3(m.x * p.x + m.z * p.y + tw.x, m.y * p.x + m.w * p.y + tw.y, tw.z);
    }

    fragment float4 fx_motion_fragment(
        VOut in [[stage_in]],
        constant Globals& g [[buffer(0)]],
        const device Inst* insts [[buffer(1)]],
        const device float4* data [[buffer(2)]],
        texture2d<float> backdrop [[texture(0)]],
        texture2d<float> source [[texture(1)]],
        sampler samp [[sampler(0)]],
        constant BackdropEncoding& enc [[buffer(4)]]
    ) {
        Inst i = insts[in.id];
        float2 px = recover_pixel(in);
        float2 p = px / i.shape.y;
        uint first = uint(i.xf.x);
        uint n = uint(i.xf.y);
        float4 acc = float4(0.0);

        if (i.xf.z < 0.5) {
            for (uint k = 0u; k < n; k++) {
                float3 l = pose_at(data, first, k, p);
                acc += src_at(i, l.xy, source, samp) * l.z;
            }
        } else {
            float j = 0.5;
            float2 b = i.aux.xy;
            float wsum = 0.0;
            for (uint k = 0u; k < n; k++) {
                float o = (float(k) + j) / float(n) - 0.5;
                float w = 1.0 - 4.0 * o * o * 0.85;
                float3 l = pose_at(data, first, 0u, p - b * o);
                acc += src_at(i, l.xy, source, samp) * (w * l.z);
                wsum += w;
            }
            acc /= max(wsum, 1e-4);
        }

        return fx_fs(finish(acc, px, g), i, px, g, backdrop, samp, enc);
    }
    """

    public static let extrasShader: String = commonPrelude + """
    inline float extras_cover(Ctx c, float feather) {
        return w_smoothstep(c.aa * 0.5, -max(feather, c.aa), c.d);
    }

    inline float4 shade_extras(
        Inst i,
        float2 px,
        constant Globals& g,
        const device float4* data,
        texture2d<float> source,
        sampler samp,
        constant BackdropEncoding& enc
    ) {
        Ctx c = make_ctx(i, px);

        if (c.variant == 0) {
            float m;
            if (i.p1.x > 0.5) {
                m = source.sample(samp, (c.p - i.aux2.xy) / i.aux2.zw, level(0.0)).a;
            } else {
                m = extras_cover(c, max(i.p1.z, c.aa * 1.5));
            }
            if (m <= 0.0) { return float4(0.0); }
            float ta = tan(i.p0.z);
            float span = c.half_size.x + c.half_size.y * abs(ta) + i.p0.y * 2.5;
            float x = c.q.x + c.q.y * ta;
            float sheen;
            if (c.reduced) {
                sheen = 0.35 * (0.5 - 0.5 * cos(TAU * c.t / max(i.p0.x, 0.1)));
            } else {
                float ph = fract(c.t / max(i.p0.x, 0.1));
                float travel = clamp(ph / max(1.0 - i.p1.y, 0.05), 0.0, 1.0);
                float e = travel * travel * (3.0 - 2.0 * travel);
                float xc = mix(-span, span, e);
                sheen = gauss(x - xc, i.p0.y) + 0.35 * gauss(x - xc, i.p0.y * 2.6);
            }
            float3 base = i.c1.rgb * i.c1.a;
            return finish(float4(base * m + i.c0.rgb * sheen * i.p0.w * m, i.c1.a * m + sheen * i.p0.w * m * 0.2), px, g);
        }
        if (c.variant == 1) {
            uint f0 = uint(i.xf.x);
            uint n = uint(i.xf.y);
            float body = 0.0;
            float hot = 0.0;
            float halo = 0.0;
            for (uint k = 0u; k < n; k++) {
                float4 a = data[f0 + k * 2u];
                float4 b = data[f0 + k * 2u + 1u];
                float S = max(a.z, 0.01);
                float env = a.w;
                float2 rel = c.p - a.xy;
                float r = length(rel);
                if (r > S * 1.6) { continue; }
                float2 l = float2(b.x * rel.x - b.y * rel.y, b.y * rel.x + b.x * rel.y);
                float2 ax = max(abs(l) / S, float2(1e-6));
                float gg = pow(pow(ax.x, 0.55) + pow(ax.y, 0.55), 1.0 / 0.55);
                float w = c.aa * 0.75 / S;
                float m = 1.0 - w_smoothstep(1.0 - w, 1.0 + w, gg);
                body += env * m;
                hot += env * m * (1.0 - gg) * (1.0 - gg);
                halo += env * gauss(r, S * 0.32);
            }
            float3 tint = i.c0.rgb;
            float3 col = mix(tint, float3(1.0), 0.3) * body + float3(1.0) * hot * 0.8 + tint * halo * 0.12;
            return finish(float4(col * i.p0.w, min(body * 0.9 + halo * 0.05, 1.0) * i.p0.w), px, g);
        }
        if (c.variant == 2) {
            float m = extras_cover(c, max(i.p0.w, c.aa));
            if (m <= 0.0) { return float4(0.0); }
            float sc = max(i.p0.x, 1.0);
            float2 q = c.p / sc;
            float t = c.reduced ? 0.0 : c.t * i.p0.y;
            float uy = (c.p.y - i.rect.y) / i.rect.w;
            float3 col = float3(0.0);
            float3 cols[3] = { i.c0.rgb, i.c1.rgb, i.c2.rgb };
            uint f0 = uint(i.xf.x);
            uint ns = uint(i.xf.y);
            float fx = clamp((c.p.x - i.rect.x) / i.rect.z, 0.0, 1.0) * float(ns - 1u);
            uint x0 = min(uint(fx), ns - 2u);
            float fr = fx - float(x0);
            for (int k = 0; k < 3; k++) {
                float fk = float(k);
                uint yb = f0 + uint(k) * 2u * (ns >> 2u);
                uint wb = yb + (ns >> 2u);
                float wv = mix(dat1(data, wb, x0), dat1(data, wb, x0 + 1u), fr);
                float yk = mix(dat1(data, yb, x0), dat1(data, yb, x0 + 1u), fr);
                float band = gauss(uy - yk, 0.13 + 0.05 * fk);
                float rays = 0.65 + 0.35 * gnoise(float2(q.x * 5.0 + wv * 3.0, t * 0.5 + fk), c.seed + 9u);
                float hem = w_smoothstep(yk + 0.16, yk - 0.02, uy) * 0.5 + 0.5;
                col += cols[k] * band * rays * hem;
            }
            float a = select(min(max(col.r, max(col.g, col.b)), 1.0), lum(col) * 0.4, effective_blend_mode(i, enc) == 0u);
            return finish(float4(col * i.p0.z * m, a * i.p0.z * m), px, g);
        }
        float m = extras_cover(c, max(i.p0.z, c.aa));
        if (m <= 0.0) { return float4(0.0); }
        uint frame = (i.p0.y > 0.0 && !c.reduced) ? uint(floor(c.t * i.p0.y)) : 0u;
        uint2 ip = uint2(px);
        float n = u01(ip.x + pcg(ip.y + pcg(frame + c.seed))) + u01(ip.y * 7919u + pcg(ip.x + 17u + frame)) - 1.0;
        float a = i.p0.x * m;
        if (n >= 0.0) { return float4(float3(n * a), n * a); }
        return float4(0.0, 0.0, 0.0, -n * a);
    }

    fragment float4 fx_extras_fragment(
        VOut in [[stage_in]],
        constant Globals& g [[buffer(0)]],
        const device Inst* insts [[buffer(1)]],
        const device float4* data [[buffer(2)]],
        texture2d<float> backdrop [[texture(0)]],
        texture2d<float> source [[texture(1)]],
        sampler samp [[sampler(0)]],
        constant BackdropEncoding& enc [[buffer(4)]]
    ) {
        Inst i = insts[in.id];
        float2 px = recover_pixel(in);
        float4 shaded = shade_extras(i, px, g, data, source, samp, enc);
        return fx_fs(shaded, i, px, g, backdrop, samp, enc);
    }
    """

    public static let fillShader: String = commonPrelude + """
    inline float fill_mask(Ctx c, float border) {
        float inside = clamp(0.5 - c.d * c.scale, 0.0, 1.0);
        if (border <= 0.0) { return inside; }
        return inside * clamp(0.5 + (c.d + border) * c.scale, 0.0, 1.0);
    }

    inline float2 rot2(float2 v, float a) {
        float cs = cos(a);
        float sn = sin(a);
        return float2(cs * v.x - sn * v.y, sn * v.x + cs * v.y);
    }

    inline float3 stop_lin(const device float4* data, uint f0, uint k) {
        return data[f0 + 2u * k].rgb;
    }

    inline float3 stop_lab(const device float4* data, uint f0, uint k) {
        return data[f0 + 2u * k + 1u].rgb;
    }

    inline float2 stop_pt(const device float4* data, uint f0, uint k) {
        return float2(data[f0 + 2u * k].w, data[f0 + 2u * k + 1u].w);
    }

    inline float3 oklab_to_lin(float3 c) {
        float l = c.x + 0.39633778 * c.y + 0.21580376 * c.z;
        float m = c.x - 0.10556135 * c.y - 0.06385417 * c.z;
        float s = c.x - 0.08948418 * c.y - 1.29148555 * c.z;
        float l3 = l * l * l;
        float m3 = m * m * m;
        float s3 = s * s * s;
        return max(float3(
            4.07674166 * l3 - 3.30771159 * m3 + 0.23096993 * s3,
            -1.26843800 * l3 + 2.60975740 * m3 - 0.34131940 * s3,
            -0.00419609 * l3 - 0.70341861 * m3 + 1.70761470 * s3
        ), float3(0.0));
    }

    inline float3 palette_ramp(const device float4* data, uint f0, uint n, float x) {
        if (n <= 1u) { return stop_lin(data, f0, 0u); }
        float fx = clamp(x, 0.0, 1.0) * float(n - 1u);
        uint k = min(uint(fx), n - 2u);
        return oklab_to_lin(mix(stop_lab(data, f0, k), stop_lab(data, f0, k + 1u), fx - float(k)));
    }

    inline float3 ramp_loop(const device float4* data, uint f0, uint n, float x) {
        if (n <= 1u) { return stop_lin(data, f0, 0u); }
        float fx = fract(x) * float(n);
        uint k = min(uint(fx), n - 1u);
        return oklab_to_lin(mix(stop_lab(data, f0, k), stop_lab(data, f0, (k + 1u) % n), fx - float(k)));
    }

    inline float4 paint(float3 col, float m, Inst i, float2 px, constant Globals& g) {
        float a = m * clamp(i.aux.y, 0.0, 1.0);
        return finish(float4(col * a, a), px, g);
    }

    inline float tone_at(
        Inst i,
        Ctx c,
        float2 p,
        int kind,
        float angle,
        constant Globals& g,
        texture2d<float> backdrop,
        texture2d<float> source,
        sampler samp,
        constant BackdropEncoding& enc
    ) {
        float v;
        float2 q = p - c.c;
        if (kind == 0) {
            float2 dir = float2(cos(angle), sin(angle));
            float ext = abs(c.half_size.x * dir.x) + abs(c.half_size.y * dir.y);
            v = dot(q, dir) / max(ext, 1e-3) * 0.5 + 0.5;
        } else if (kind == 1) {
            v = 1.0 - clamp(length(q / max(c.half_size, float2(1e-3))) / 1.3, 0.0, 1.0);
        } else if (kind == 2) {
            float t = c.t * i.p1.y;
            v = 0.5 + 0.62 * fbm3(p / max(i.p1.x, 1.0) + float2(t * 0.31, t * 0.17), c.seed);
        } else if (kind == 3) {
            v = to_srgb(float3(lum(bd(p, c.scale, g, backdrop, samp, enc).rgb))).x;
        } else {
            float4 s = source.sample(samp, (p - i.aux2.xy) / max(i.aux2.zw, float2(1e-3)), level(0.0));
            v = to_srgb(float3(lum(s.rgb))).x;
        }
        return clamp((v - 0.5) * i.p1.w + 0.5 + i.p1.z * 0.5, 0.0, 1.0);
    }

    inline float bayer(uint2 cell, uint bits) {
        uint v = 0u;
        for (uint b = 0u; b < bits; b++) {
            uint x = (cell.x >> b) & 1u;
            uint y = (cell.y >> b) & 1u;
            uint sh = 2u * (bits - 1u - b);
            v |= (((x ^ y) << 1u) | y) << sh;
        }
        return (float(v) + 0.5) / float(1u << (2u * bits));
    }

    inline float3 slab_tilt(Ctx c, float border, float bevel, float dome) {
        float depth = -c.d;
        float2 gv = sd_grad(c);
        float2 tilt = float2(0.0);
        float rim = 0.0;
        if (border > 0.0) {
            float x = clamp((depth - border * 0.5) / max(border * 0.5, 1e-3), -0.97, 0.97);
            tilt = -gv * x / sqrt(1.0 - x * x);
            rim = abs(x);
        } else {
            float bev = max(bevel, 0.5);
            float x = clamp(1.0 - depth / bev, 0.0, 0.92);
            tilt = gv * x / sqrt(1.0 - x * x);
            rim = x;
        }
        float2 qn = c.q / max(c.half_size, float2(1.0));
        tilt += float2(qn.x * 0.55, qn.y) * dome * select(0.8, 0.25, border > 0.0);
        return float3(tilt, rim);
    }

    inline float flow_h(float2 u, float2 w, float t, uint seed) {
        float2 p = u + w;
        return gnoise(p + float2(0.0, t * 0.11), seed + 3u) + 0.5 * gnoise(rot_mul(p) * 2.03 - float2(t * 0.07, 0.0), seed + 17u);
    }

    inline float3 studio(float3 r, float contrast) {
        float up = -r.y;
        float e = up + 0.1;
        float w = 0.014;
        float sky = 0.2 + 0.6 * exp(-max(e, 0.0) * 3.2) + 0.45 * exp(-max(e, 0.0) * 24.0);
        float key = w_smoothstep(0.80, 0.95, dot(r, normalize(float3(-0.3, -0.82, 0.5)))) * 2.4;
        float strip = gauss(r.x - 0.6, 0.075) * w_smoothstep(-0.05, 0.2, e) * (1.0 - w_smoothstep(0.55, 0.9, up)) * 1.7;
        float fill_l = gauss(r.x + 0.72, 0.045) * w_smoothstep(0.0, 0.25, e) * (1.0 - w_smoothstep(0.4, 0.8, up)) * 0.55;
        float lights = (key + strip + fill_l) * contrast;
        float fl = w_smoothstep(0.05, 1.0, -e);
        float pool = 0.16 * gauss(r.x + 0.25, 0.35) * w_smoothstep(0.25, 0.9, -e);
        float ground = (0.014 + 0.3 * fl * fl + pool + 0.05 * gauss(e + 0.06, 0.04)) / (contrast * contrast);
        float h = w_smoothstep(-w, w, e);
        float3 skyc = (sky * mix(1.0, 0.82, clamp(contrast - 1.0, 0.0, 1.0)) + lights) * float3(0.97, 0.99, 1.03);
        float3 floorc = ground * float3(1.04, 1.0, 0.95);
        return mix(floorc, skyc, h);
    }

    inline float3 shoulder(float3 c) {
        float k = 0.78;
        return select(c, k + (1.0 - k) * (1.0 - exp(-(c - k) / (1.0 - k))), c > float3(k));
    }

    inline float4 liquid_metal(Inst i, Ctx c, float m, float2 px, constant Globals& g) {
        float flow = i.p0.x;
        float sc = max(i.p0.y, 1.0);
        float t = c.t * i.p0.z;
        float3 slab = slab_tilt(c, i.aux.x, i.p0.w, i.p1.x);
        float2 tilt = slab.xy;
        float rim = slab.z;
        float hgt = 0.0;
        float bend = 0.0;
        if (flow > 0.0) {
            float2 u = select(c.p, c.q, i.p2.x > 0.5) / sc;
            float2 wv = float2(
                gnoise(u * 0.6 + float2(t * 0.05, 1.7), c.seed + 7u),
                gnoise(u * 0.6 + float2(4.3, -t * 0.06), c.seed + 11u)
            ) * 0.9;
            float e = 0.04;
            hgt = flow_h(u, wv, t, c.seed);
            float hx = flow_h(u + float2(e, 0.0), wv, t, c.seed) - hgt;
            float hy = flow_h(u + float2(0.0, e), wv, t, c.seed) - hgt;
            float2 grad = float2(hx, hy) / e;
            float k = flow * 0.42 * (1.0 - 0.6 * rim * rim);
            tilt -= grad * k;
            bend = length(grad) * k;
        }
        float3 n = normalize(float3(tilt, 1.0));
        float3 r = float3(2.0 * n.z * n.xy, 2.0 * n.z * n.z - 1.0);
        r = float3(rot2(r.xy, i.p1.y), r.z);
        float contrast = max(i.p1.w, 0.1);
        float3 env = studio(normalize(r), contrast) * i.c1.rgb;
        float3 f0 = i.c0.rgb;
        float cz = clamp(1.0 - n.z, 0.0, 1.0);
        float cz2 = cz * cz;
        float3 f = f0 + (float3(1.0) - f0) * (cz2 * cz2 * cz);
        float ir = i.p1.z;
        if (ir > 0.0) {
            float ph = 1.6 * (1.0 - n.z) + 0.35 * hgt;
            float3 film = 0.5 + 0.5 * cos(TAU * (float3(ph) + float3(0.0, 0.33, 0.67)));
            float k = ir * clamp(w_smoothstep(0.04, 0.45, 1.0 - n.z) + bend * 0.8, 0.0, 1.0);
            f *= mix(float3(1.0), 0.55 + 0.9 * film, k);
        }
        float3 col = shoulder(f * env);
        return paint(col, m, i, px, g);
    }

    inline float4 plastic(Inst i, Ctx c, float m, float2 px, constant Globals& g) {
        float3 slab = slab_tilt(c, i.aux.x, i.p0.z, i.p0.y);
        float3 n = normalize(float3(slab.xy, 1.0));
        float3 l = float3(rot2(float2(0.0, -1.0), i.p0.w) * 0.6428, 0.766);
        float nl = dot(n, l);
        float3 base = clamp(i.c0.rgb, float3(0.0), float3(1.0));
        float shade = 0.4 + 0.7833 * max(nl, 0.0);
        float3 col = mix(base * min(shade, 1.0), float3(1.0), clamp((shade - 1.0) * 0.6, 0.0, 1.0));
        float rough = clamp(i.p0.x, 0.02, 1.0);
        float a = min(rough * rough + 0.1, 1.0);
        float a2 = a * a;
        float3 h = normalize(l + float3(0.0, 0.0, 1.0));
        float nh = max(dot(n, h), 0.0);
        float dd = nh * nh * (a2 - 1.0) + 1.0;
        float ndf = a2 / (PI * dd * dd);
        float fh = 1.0 - h.z;
        float spec = ndf * (0.04 + 0.96 * fh * fh * fh * fh * fh) * max(nl, 0.0) * 2.5;
        float fz = 1.0 - clamp(n.z, 0.0, 1.0);
        float sky = 0.55 + 0.45 * w_smoothstep(-0.5, 0.5, -n.y);
        float edge = 0.96 * fz * fz * fz * fz * fz * sky * (1.0 - 0.5 * rough);
        col += (float3(1.0) - col) * knee(spec + edge);
        return paint(col, m, i, px, g);
    }

    inline float4 fluted(
        Inst i,
        Ctx c,
        float m,
        float2 px,
        constant Globals& g,
        texture2d<float> backdrop,
        sampler samp,
        texture2d<float> blurred,
        constant BackdropEncoding& enc
    ) {
        float s = c.scale;
        float rib = max(i.p0.x, 1.0);
        float2 across = float2(cos(i.p0.y), sin(i.p0.y));
        float u = dot(c.p - c.c, across) / rib;
        float local = fract(u) - 0.5;
        float x = local * 2.0;
        float o = -x * (1.0 + 0.35 * x * x) * i.p0.z;
        float dsp = i.p1.x * 0.3 * abs(x);
        float2 srcg = c.p + across * o;
        float2 srcr = c.p + across * o * (1.0 + dsp);
        float2 srcb = c.p + across * o * (1.0 - dsp);
        float3 col = float3(
            bd(srcr, s, g, backdrop, samp, enc).r,
            bd(srcg, s, g, backdrop, samp, enc).g,
            bd(srcb, s, g, backdrop, samp, enc).b
        );
        float frost = i.p0.w;
        if (frost > 0.0) {
            if (i.xf.x > 0.5) {
                float3 blr = float3(
                    bdb(srcr, s, g, blurred, samp, enc).r,
                    bdb(srcg, s, g, blurred, samp, enc).g,
                    bdb(srcb, s, g, blurred, samp, enc).b
                );
                col = mix(col, blr, i.xf.y);
            } else {
                float2 along = float2(-across.y, across.x);
                float j = ign(px) - 0.5;
                float3 acc = float3(0.0);
                for (int k = 0; k < 4; k++) {
                    acc += bd(srcg + along * (float(k) - 1.5 + j) * 3.0 * frost, s, g, backdrop, samp, enc).rgb;
                }
                col = mix(col, acc * 0.25, frost);
            }
            float k = w_smoothstep(0.0, 0.6, frost);
            float l = lum(col);
            float3 sat = max(mix(float3(l), col, 1.0 + 0.5 * k), float3(0.0));
            col = to_lin(to_srgb(sat) * (1.0 - 0.2 * k) + float3(0.07 * k));
        }
        col = mix(col, col * i.c0.rgb, i.p1.z);
        float hl = i.p1.y;
        float aa = c.aa / rib;
        float groove = 1.0 - w_smoothstep(0.0, max(0.06, aa * 2.0), 0.5 - abs(local));
        float sheen = gauss(local + 0.22, 0.13) * 0.1 + gauss(local + 0.34, 0.03) * 0.1;
        float lip = gauss(local - 0.44, max(0.025, aa)) * 0.06;
        float lift = 0.35 + 0.65 * sqrt(clamp(lum(col), 0.0, 1.0));
        col = col * (1.0 - 0.28 * hl * groove) + float3((sheen + lip) * hl * lift);
        float a = m * clamp(i.aux.y, 0.0, 1.0);
        return float4(col * a, a);
    }

    inline float4 mesh_gradient(Inst i, Ctx c, float m, float2 px, constant Globals& g, const device float4* data) {
        uint f0 = uint(i.xf.x);
        uint n = uint(i.xf.y);
        float2 uv = (c.p - i.rect.xy) / max(i.rect.zw, float2(1.0));
        float t = c.t * i.p0.y;
        float warp = i.p0.w;
        if (warp > 0.0) {
            uv += warp * 0.09 * float2(
                gnoise(uv * 2.1 + float2(t * 0.11, 0.0), c.seed + 5u),
                gnoise(uv * 2.1 + float2(3.7, -t * 0.09), c.seed + 9u)
            );
        }
        float2 aspect = i.rect.zw / max(max(i.rect.z, i.rect.w), 1.0);
        float sharp = clamp(i.p0.z, 0.1, 8.0);
        float3 lab = float3(0.0);
        float wsum = 0.0;
        for (uint k = 0u; k < n; k++) {
            float2 d = (uv - stop_pt(data, f0, k)) * aspect;
            float w = pow(dot(d, d) + 0.004, -sharp);
            lab += stop_lab(data, f0, k) * w;
            wsum += w;
        }
        return paint(oklab_to_lin(lab / max(wsum, 1e-6)), m, i, px, g);
    }

    inline float4 dither_fill(
        Inst i,
        Ctx c,
        float m,
        constant Globals& g,
        const device float4* data,
        texture2d<float> backdrop,
        texture2d<float> source,
        sampler samp,
        constant BackdropEncoding& enc
    ) {
        uint f0 = uint(i.xf.x);
        uint n = max(uint(i.xf.y), 1u);
        float pix = max(i.p0.z, 0.25);
        float2 rel = c.p - i.rect.xy;
        float2 cell = floor(rel / pix);
        uint2 ci = as_type<uint2>(int2(cell));
        float tone = tone_at(i, c, i.rect.xy + (cell + 0.5) * pix, int(i.p0.y + 0.5), i.p0.w, g, backdrop, source, samp, enc);
        int pat = clamp(int(i.p0.x + 0.5), 1, 5);
        float th;
        if (pat <= 3) {
            th = bayer(ci, uint(pat));
        } else if (pat == 4) {
            uint side = max(uint(i.xf.w), 1u);
            th = dat1(data, uint(i.xf.z), (ci.y % side) * side + ci.x % side);
        } else {
            th = u01(ci.x * 7919u + pcg(ci.y + c.seed));
        }
        float lv = float(max(n, 2u) - 1u);
        float v = tone * lv;
        uint k = min(uint(floor(v) + select(0.0, 1.0, fract(v) > th)), n - 1u);
        float a = m * clamp(i.aux.y, 0.0, 1.0);
        return float4(stop_lin(data, f0, k) * a, a);
    }

    inline float4 grain_gradient(Inst i, Ctx c, float m, float2 px, constant Globals& g, const device float4* data) {
        uint f0 = uint(i.xf.x);
        uint n = uint(i.xf.y);
        int kind = int(i.p0.x + 0.5);
        float ang = i.p0.y;
        float2 ctr = i.rect.xy + i.p0.zw * i.rect.zw;
        float x;
        if (kind == 0) {
            float2 dir = float2(cos(ang), sin(ang));
            float ext = abs(c.half_size.x * dir.x) + abs(c.half_size.y * dir.y);
            x = dot(c.q, dir) / max(ext, 1e-3) * 0.5 + 0.5;
        } else if (kind == 1) {
            x = length(c.p - ctr) / max(length(c.half_size), 1e-3);
        } else {
            float2 d = c.p - ctr;
            float th = select(0.0, atan2(d.y, d.x), any(d != float2(0.0)));
            x = fract((th - ang) / TAU);
        }
        float amount = i.p1.x;
        float size = max(i.p1.y, 0.25);
        uint frame = i.p1.w > 0.0 ? uint(floor(c.t * i.p1.w)) : 0u;
        uint2 gc = as_type<uint2>(int2(floor((c.p - i.rect.xy) / size)));
        uint h = pcg(gc.x + pcg(gc.y + pcg(frame + c.seed * 977u)));
        float nx = u01(h) + u01(h + 1u) - 1.0;
        float3 col = (kind == 2) ? ramp_loop(data, f0, n, x + nx * amount * 0.2) : palette_ramp(data, f0, n, x + nx * amount * 0.2);
        float nb = u01(h + 2u) + u01(h + 3u) - 1.0;
        if (i.p1.z > 0.5) {
            col *= 1.0 + nb * amount * 0.18;
        } else {
            float3 nc = float3(nb, u01(h + 4u) + u01(h + 5u) - 1.0, u01(h + 6u) + u01(h + 7u) - 1.0);
            col *= float3(1.0) + nc * amount * 0.18;
        }
        return paint(col, m, i, px, g);
    }

    inline float4 metaballs(Inst i, Ctx c, float m, float2 px, constant Globals& g, const device float4* data) {
        uint f0 = uint(i.xf.x);
        uint b0 = uint(i.xf.z);
        uint nb = uint(i.xf.w);
        float field = 0.0;
        float2 grad = float2(0.0);
        float3 lab = float3(0.0);
        float rsum = 0.0;
        for (uint k = 0u; k < nb; k++) {
            float4 b = data[b0 + k];
            float2 d = c.p - b.xy;
            float r2 = b.z * b.z;
            float dd = dot(d, d) + 1e-3;
            float f = r2 / dd;
            field += f;
            grad += -2.0 * f / dd * d;
            lab += stop_lab(data, f0, uint(b.w)) * f;
            rsum += b.z * f;
        }
        float3 base = i.c0.rgb;
        float3 col = select(base, oklab_to_lin(lab / max(field, 1e-6)), field > 1e-5);
        float ravg = rsum / max(field, 1e-6);
        float cov_m = select(0.0, clamp(0.5 + (field - 1.0) * ravg * 0.5 * c.scale, 0.0, 1.0), field > 1e-3);
        float steep = 1.0 - w_smoothstep(1.0, 2.6, field);
        float2 nxy = -grad / sqrt(dot(grad, grad) + 1e-6) * steep * 0.9;
        float3 nrm = normalize(float3(nxy, 1.0));
        float3 l = normalize(float3(-0.45, -0.6, 0.66));
        float diff = max(dot(nrm, l), 0.0);
        float spec = pow(max(dot(reflect(-l, nrm), float3(0.0, 0.0, 1.0)), 1e-4), 28.0);
        float3 body = col * (0.6 + 0.5 * diff) + float3(spec * i.p0.w * 0.8);
        float3 halo = col * w_smoothstep(0.25, 1.0, field) * 0.18;
        return paint(mix(base + halo, body, cov_m), m, i, px, g);
    }

    inline float4 swirl_fill(Inst i, Ctx c, float m, float2 px, constant Globals& g, const device float4* data) {
        uint f0 = uint(i.xf.x);
        uint n = uint(i.xf.y);
        float sc = max(i.p0.x, 1.0);
        float t = c.t * i.p0.y;
        float rr = length(c.q) / max(min(c.half_size.x, c.half_size.y), 1.0);
        float2 q = rot2(c.q, i.p0.z * TAU * exp(-rr * rr * 0.8)) / sc;
        float2 w1 = float2(
            fbm3(q + float2(t * 0.1, 0.0), c.seed),
            fbm3(q + float2(5.2, 1.3 - t * 0.08), c.seed + 3u)
        );
        float v = fbm3(q + w1 * i.p0.w * 1.5 + float2(0.0, t * 0.05), c.seed + 7u);
        return paint(palette_ramp(data, f0, n, 0.5 + 0.75 * v), m, i, px, g);
    }

    inline float4 voronoi_fill(Inst i, Ctx c, float m, float2 px, constant Globals& g, const device float4* data) {
        uint f0 = uint(i.xf.x);
        uint n = uint(i.xf.y);
        float sc = max(i.p0.x, 2.0);
        float t = c.t * i.p0.y;
        float t0 = fract(t * (1.0 / TAU)) * TAU;
        float t1 = fract(t * (0.8 / TAU)) * TAU;
        float2 p = (c.p - i.rect.xy) / sc;
        float2 ip = floor(p);
        float best = 8.0;
        int2 bc = int2(0);
        float2 bo = float2(0.0);
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                int2 cc = int2(ip) + int2(x, y);
                float h = hcell(cc, c.seed);
                float h2 = hcell(cc, c.seed + 1u);
                float2 o = float2(0.5) + 0.38 * float2(sin(t0 + TAU * h), cos(t1 + TAU * h2));
                float2 d = float2(cc) + o - p;
                float dd = dot(d, d);
                if (dd < best) { best = dd; bc = cc; bo = d; }
            }
        }
        float edge = 8.0;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                if (x == 0 && y == 0) { continue; }
                int2 cc = bc + int2(x, y);
                float h = hcell(cc, c.seed);
                float h2 = hcell(cc, c.seed + 1u);
                float2 o = float2(0.5) + 0.38 * float2(sin(t0 + TAU * h), cos(t1 + TAU * h2));
                float2 d = float2(cc) + o - p;
                float2 dv = d - bo;
                if (dot(dv, dv) > 1e-6) { edge = min(edge, dot(0.5 * (bo + d), normalize(dv))); }
            }
        }
        uint k = uint(hcell(bc, c.seed + 2u) * float(n)) % max(n, 1u);
        float3 col = stop_lin(data, f0, k) * (1.0 - i.p0.w * 0.55 * clamp(best * 1.6, 0.0, 1.0));
        float seam = i.p0.z * 0.5;
        if (seam > 0.0) {
            float e = clamp(0.5 + (edge * sc - seam) * c.scale, 0.0, 1.0);
            col = mix(i.c0.rgb, col, e);
        }
        return paint(col, m, i, px, g);
    }

    inline float4 waves_fill(Inst i, Ctx c, float m, float2 px, constant Globals& g, const device float4* data) {
        uint f0 = uint(i.xf.x);
        uint n = uint(i.xf.y);
        float ang = i.p0.w;
        float2 dir = float2(-sin(ang), cos(ang));
        float2 along = float2(cos(ang), sin(ang));
        float ext = abs(c.half_size.x * dir.x) + abs(c.half_size.y * dir.y);
        float ext2 = abs(c.half_size.x * along.x) + abs(c.half_size.y * along.y);
        float v = dot(c.q, dir) / max(2.0 * ext, 1e-3) + 0.5;
        float s = dot(c.q, along) / max(2.0 * ext2, 1e-3) + 0.5;
        float aa = c.aa / max(2.0 * ext, 1e-3);
        float soft = max(i.p1.x, aa);
        float t = c.t * i.p0.z;
        float3 col = stop_lin(data, f0, 0u);
        for (uint k = 1u; k < n; k++) {
            float fk = float(k);
            float h = hcell(int2(int(k), 3), c.seed);
            float fq = i.p0.y * (0.8 + 0.4 * h);
            float ph1 = fract(t * 0.2 * (1.0 + 0.3 * fk) + h);
            float ph2 = fract(-t * 0.13) * TAU + 1.7 * fk;
            float y = fk / float(n) + i.p0.x * (0.7 * sin(TAU * (fq * s + ph1)) + 0.3 * sin(TAU * fq * 2.3 * s + ph2));
            float shade = exp(-max(y - v, 0.0) / 0.025) * 0.18 * step(v, y);
            col *= 1.0 - shade;
            col = mix(col, stop_lin(data, f0, k), w_smoothstep(y - soft, y + soft, v));
        }
        return paint(col, m, i, px, g);
    }

    inline float4 halftone_fill(
        Inst i,
        Ctx c,
        float m,
        float2 px,
        constant Globals& g,
        texture2d<float> backdrop,
        texture2d<float> source,
        sampler samp,
        constant BackdropEncoding& enc
    ) {
        float pitch = max(i.p0.z, 1.0);
        float ang = i.p2.x;
        float2 r = rot2(c.p - c.c, -ang) / pitch;
        float2 base = floor(r - 0.5);
        int kind = int(i.p0.y + 0.5);
        float ink = 0.0;
        for (int y = 0; y <= 1; y++) {
            for (int x = 0; x <= 1; x++) {
                float2 cc = base + float2(float(x), float(y)) + 0.5;
                float2 w = c.c + rot2(cc * pitch, ang);
                float cov_t = 1.0 - tone_at(i, c, w, kind, i.p0.w, g, backdrop, source, samp, enc);
                float rad = sqrt(cov_t / PI) * 1.12;
                float d = (length(r - cc) - rad) * pitch;
                ink = max(ink, clamp(0.5 - d * c.scale, 0.0, 1.0));
            }
        }
        return paint(mix(i.c1.rgb, i.c0.rgb, ink), m, i, px, g);
    }

    inline float4 shade_fill(
        Inst i,
        float2 px,
        constant Globals& g,
        const device float4* data,
        texture2d<float> backdrop,
        texture2d<float> source,
        sampler samp,
        texture2d<float> blurred,
        constant BackdropEncoding& enc
    ) {
        Ctx c = make_ctx(i, px);
        float m = fill_mask(c, i.aux.x);
        if (m <= 0.0) { return float4(0.0); }
        switch (c.variant) {
            case 0: return liquid_metal(i, c, m, px, g);
            case 1: return mesh_gradient(i, c, m, px, g, data);
            case 2: return dither_fill(i, c, m, g, data, backdrop, source, samp, enc);
            case 3: return grain_gradient(i, c, m, px, g, data);
            case 4: return fluted(i, c, m, px, g, backdrop, samp, blurred, enc);
            case 5: return metaballs(i, c, m, px, g, data);
            case 6: return swirl_fill(i, c, m, px, g, data);
            case 7: return voronoi_fill(i, c, m, px, g, data);
            case 8: return waves_fill(i, c, m, px, g, data);
            case 9: return halftone_fill(i, c, m, px, g, backdrop, source, samp, enc);
            default: return plastic(i, c, m, px, g);
        }
    }

    fragment float4 fx_fill_fragment(
        VOut in [[stage_in]],
        constant Globals& g [[buffer(0)]],
        const device Inst* insts [[buffer(1)]],
        const device float4* data [[buffer(2)]],
        texture2d<float> backdrop [[texture(0)]],
        texture2d<float> source [[texture(1)]],
        sampler samp [[sampler(0)]],
        texture2d<float> blurred [[texture(2)]],
        constant BackdropEncoding& enc [[buffer(4)]]
    ) {
        Inst i = insts[in.id];
        float2 px = recover_pixel(in);
        float4 shaded = shade_fill(i, px, g, data, backdrop, source, samp, blurred, enc);
        return fx_fs(shaded, i, px, g, backdrop, samp, enc);
    }
    """

    public static let blurShader: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct BlurVOut {
        float4 pos [[position]];
        float2 uv;
    };

    vertex BlurVOut fx_blur_vertex(uint vi [[vertex_id]]) {
        float2 p = float2(float((vi << 1u) & 2u), float(vi & 2u));
        BlurVOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    fragment float4 fx_blur_down_fragment(
        BlurVOut in [[stage_in]],
        texture2d<float> src [[texture(0)]],
        sampler smp [[sampler(0)]]
    ) {
        float2 t = 1.0 / float2(src.get_width(), src.get_height());
        float2 uv = in.uv;
        float4 a = src.sample(smp, uv + t * float2(-2.0, -2.0), level(0.0));
        float4 b = src.sample(smp, uv + t * float2( 0.0, -2.0), level(0.0));
        float4 c = src.sample(smp, uv + t * float2( 2.0, -2.0), level(0.0));
        float4 d = src.sample(smp, uv + t * float2(-1.0, -1.0), level(0.0));
        float4 e = src.sample(smp, uv + t * float2( 1.0, -1.0), level(0.0));
        float4 f = src.sample(smp, uv + t * float2(-2.0,  0.0), level(0.0));
        float4 g = src.sample(smp, uv, level(0.0));
        float4 h = src.sample(smp, uv + t * float2( 2.0,  0.0), level(0.0));
        float4 i = src.sample(smp, uv + t * float2(-1.0,  1.0), level(0.0));
        float4 j = src.sample(smp, uv + t * float2( 1.0,  1.0), level(0.0));
        float4 k = src.sample(smp, uv + t * float2(-2.0,  2.0), level(0.0));
        float4 l = src.sample(smp, uv + t * float2( 0.0,  2.0), level(0.0));
        float4 m = src.sample(smp, uv + t * float2( 2.0,  2.0), level(0.0));
        return (d + e + i + j) * 0.125 + (a + b + g + f) * 0.03125 + (b + c + h + g) * 0.03125
             + (f + g + l + k) * 0.03125 + (g + h + m + l) * 0.03125;
    }

    fragment float4 fx_blur_up_fragment(
        BlurVOut in [[stage_in]],
        texture2d<float> src [[texture(0)]],
        texture2d<float> fine [[texture(1)]],
        sampler smp [[sampler(0)]],
        constant float4& u [[buffer(0)]]
    ) {
        float2 t = 1.0 / float2(src.get_width(), src.get_height());
        float2 uv = in.uv;
        float4 c = src.sample(smp, uv, level(0.0)) * 4.0;
        c += (src.sample(smp, uv + float2(t.x, 0.0), level(0.0))
            + src.sample(smp, uv - float2(t.x, 0.0), level(0.0))
            + src.sample(smp, uv + float2(0.0, t.y), level(0.0))
            + src.sample(smp, uv - float2(0.0, t.y), level(0.0))) * 2.0;
        c += src.sample(smp, uv + t, level(0.0))
           + src.sample(smp, uv - t, level(0.0))
           + src.sample(smp, uv + float2(t.x, -t.y), level(0.0))
           + src.sample(smp, uv + float2(-t.x, t.y), level(0.0));
        c /= 16.0;
        float4 f = fine.sample(smp, uv, level(0.0));
        return mix(f, c, u.x);
    }
    """

    public static let mipShader: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct MipVOut {
        float4 pos [[position]];
        float2 uv;
    };

    vertex MipVOut fx_mip_vertex(uint vi [[vertex_id]]) {
        float2 p = float2(float((vi << 1u) & 2u), float(vi & 2u));
        MipVOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    fragment float4 fx_mip_fragment(
        MipVOut in [[stage_in]],
        texture2d<float> src [[texture(0)]],
        sampler smp [[sampler(0)]]
    ) {
        float2 t = 1.0 / float2(src.get_width(), src.get_height());
        float2 uv = in.uv;
        float4 a = src.sample(smp, uv + t * float2(-2.0, -2.0), level(0.0));
        float4 b = src.sample(smp, uv + t * float2( 0.0, -2.0), level(0.0));
        float4 c = src.sample(smp, uv + t * float2( 2.0, -2.0), level(0.0));
        float4 d = src.sample(smp, uv + t * float2(-1.0, -1.0), level(0.0));
        float4 e = src.sample(smp, uv + t * float2( 1.0, -1.0), level(0.0));
        float4 f = src.sample(smp, uv + t * float2(-2.0,  0.0), level(0.0));
        float4 g = src.sample(smp, uv, level(0.0));
        float4 h = src.sample(smp, uv + t * float2( 2.0,  0.0), level(0.0));
        float4 i = src.sample(smp, uv + t * float2(-1.0,  1.0), level(0.0));
        float4 j = src.sample(smp, uv + t * float2( 1.0,  1.0), level(0.0));
        float4 k = src.sample(smp, uv + t * float2(-2.0,  2.0), level(0.0));
        float4 l = src.sample(smp, uv + t * float2( 0.0,  2.0), level(0.0));
        float4 m = src.sample(smp, uv + t * float2( 2.0,  2.0), level(0.0));
        return (d + e + i + j) * 0.125 + (a + b + g + f) * 0.03125 + (b + c + h + g) * 0.03125
             + (f + g + l + k) * 0.03125 + (g + h + m + l) * 0.03125;
    }
    """

    public static let fireSimShader: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct FireSimParams {
        float dt;
        float buoyancy;
        float cooling;
        float smoke;
    };

    struct FireSimUniform {
        float4 dims;
        float4 origin;
        float4 shape;
        float4 shape2;
        float4 fire;
        float4 fire2;
    };

    inline int2 fs_n(constant FireSimUniform& u) { return int2(u.dims.xy); }
    inline bool fs_inside(constant FireSimUniform& u, int2 c) {
        int2 sz = fs_n(u);
        return c.x >= 0 && c.y >= 0 && c.x < sz.x && c.y < sz.y;
    }
    inline uint2 fs_cl(constant FireSimUniform& u, int2 c) {
        return uint2(clamp(c, int2(0), fs_n(u) - 1));
    }
    inline float4 fs_ld(constant FireSimUniform& u, texture2d<float, access::read> s_in, int2 c) {
        if (u.origin.w > 0.5) { return float4(0.0); }
        return s_in.read(fs_cl(u, c));
    }
    inline float fs_la(constant FireSimUniform& u, texture2d<float, access::read> a_in, int2 c) {
        return a_in.read(fs_cl(u, c)).r;
    }
    inline float fs_lb(constant FireSimUniform& u, texture2d<float, access::read> b_in, int2 c) {
        return b_in.read(fs_cl(u, c)).r;
    }
    inline float2 fs_pos(constant FireSimUniform& u, int2 c) {
        return u.origin.xy + (float2(c) + 0.5) * u.dims.z;
    }

    inline float fs_sd_rrect(constant FireSimUniform& u, float2 p) {
        float r = min(u.shape2.x, min(u.shape.z, u.shape.w));
        float2 q = abs(p - u.shape.xy) - u.shape.zw + r;
        return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
    }
    inline bool fs_solid(constant FireSimUniform& u, int2 c) {
        return fs_sd_rrect(u, fs_pos(u, c)) < -u.fire2.w - 1.0;
    }

    inline uint fs_pcg(uint v) {
        uint s = v * 747796405u + 2891336453u;
        uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
        return (w >> 22u) ^ w;
    }
    inline float fs_hash2(int2 c, uint seed) {
        return float(fs_pcg(as_type<uint>(c.x) ^ fs_pcg(as_type<uint>(c.y) ^ fs_pcg(seed))) >> 8u) * (1.0 / 16777216.0);
    }
    inline float fs_vnoise(float2 p, uint seed) {
        int2 i = int2(floor(p));
        float2 f = fract(p);
        float2 w = f * f * (3.0 - 2.0 * f);
        float a = fs_hash2(i, seed);
        float b = fs_hash2(i + int2(1, 0), seed);
        float c = fs_hash2(i + int2(0, 1), seed);
        float d = fs_hash2(i + int2(1, 1), seed);
        return mix(mix(a, b, w.x), mix(c, d, w.x), w.y) * 2.0 - 1.0;
    }

    inline float fs_smoothstep(float a, float b, float x) {
        return (a < b) ? smoothstep(a, b, x) : (a > b ? (1.0 - smoothstep(b, a, x)) : (x >= a ? 1.0 : 0.0));
    }

    inline float fs_emission(constant FireSimUniform& u, float x, float t, uint seed) {
        float sp = max(u.shape2.w * 0.32, 3.5);
        float fs = u.fire2.y;
        float slow = fs_vnoise(float2(x / sp, t * 0.55 * fs), seed) * 0.7
                   + fs_vnoise(float2(x / sp * 2.3 + 5.1, t * 1.1 * fs), seed + 1u) * 0.3;
        float fast = fs_vnoise(float2(x / sp * 1.7 + 11.0, t * 6.0 * fs), seed + 2u);
        float r = min(u.shape2.x, min(u.shape.z, u.shape.w));
        float ends = 1.0 - fs_smoothstep(u.shape.z - r * 1.6, u.shape.z - r * 0.35, abs(x - u.shape.x));
        return fs_smoothstep(-0.1, 0.4, slow + 0.25 * fast) * ends;
    }

    inline float fs_fuel_band(constant FireSimUniform& u, float2 p) {
        float h = u.dims.z;
        float d = fs_sd_rrect(u, p);
        float2 e2 = float2(0.5 * h, 0.0);
        float gx = fs_sd_rrect(u, p + e2) - fs_sd_rrect(u, p - e2);
        float gy = fs_sd_rrect(u, p + e2.yx) - fs_sd_rrect(u, p - e2.yx);
        float up = clamp(-gy / max(length(float2(gx, gy)), 1e-4), 0.0, 1.0);
        float depth = u.fire2.w;
        return fs_smoothstep(-depth - 1.5, -depth + 0.5, d)
             * (1.0 - fs_smoothstep(0.0, h + 1.5, d))
             * fs_smoothstep(0.35, 0.8, up);
    }

    kernel void curl(
        constant FireSimUniform& u [[buffer(0)]],
        texture2d<float, access::read> s_in [[texture(0)]],
        texture2d<float, access::write> r_out [[texture(4)]],
        uint2 id [[thread_position_in_grid]]
    ) {
        int2 c = int2(id);
        if (!fs_inside(u, c)) { return; }
        float h = u.dims.z;
        float w = (fs_ld(u, s_in, c + int2(1, 0)).y - fs_ld(u, s_in, c - int2(1, 0)).y
                 - fs_ld(u, s_in, c + int2(0, 1)).x + fs_ld(u, s_in, c - int2(0, 1)).x) / (2.0 * h);
        r_out.write(float4(w, 0.0, 0.0, 0.0), uint2(c));
    }

    kernel void forces(
        constant FireSimUniform& u [[buffer(0)]],
        texture2d<float, access::read> s_in [[texture(0)]],
        texture2d<float, access::write> s_out [[texture(1)]],
        texture2d<float, access::read> a_in [[texture(2)]],
        uint2 id [[thread_position_in_grid]]
    ) {
        int2 c = int2(id);
        if (!fs_inside(u, c)) { return; }
        float dt = u.dims.w;
        float h = u.dims.z;
        float t = u.origin.z;
        uint seed = uint(u.shape2.y);
        float4 s = fs_ld(u, s_in, c);
        float2 v = s.xy;
        float T = s.z;
        float sm = s.w;
        float2 p = fs_pos(u, c);

        v.y -= dt * (u.fire.x * T - u.fire.x * 0.12 * sm);

        if (u.origin.w < 0.5) {
            float wl = abs(fs_la(u, a_in, c - int2(1, 0)));
            float wr = abs(fs_la(u, a_in, c + int2(1, 0)));
            float wu = abs(fs_la(u, a_in, c - int2(0, 1)));
            float wd = abs(fs_la(u, a_in, c + int2(0, 1)));
            float2 g = float2(wr - wl, wd - wu) / (2.0 * h);
            float gl = length(g);
            if (gl > 1e-4) {
                g /= gl;
                float w = fs_la(u, a_in, c);
                float lift = clamp((u.shape.y - u.shape.w - p.y) / max(u.shape2.z * 0.4, 8.0), 0.15, 1.0);
                v += dt * u.fire.w * lift * h * float2(g.y * w, -g.x * w);
            }
        }

        float above = u.shape.y - u.shape.w - p.y;
        float sway = fs_vnoise(float2(p.x / 90.0, t * 0.35 * u.fire2.y), seed + 9u)
                   + 0.5 * fs_vnoise(float2(p.x / 30.0 + 3.0, p.y / 40.0 - t * 0.9 * u.fire2.y), seed + 10u);
        v.x += dt * u.fire2.x * sway * clamp(above / 40.0, 0.0, 1.0);

        float band = fs_fuel_band(u, p);
        if (band > 0.0) {
            float e = fs_emission(u, p.x, t, seed) * band;
            T = max(T, e * (0.95 + 0.25 * fs_vnoise(float2(p.x / 3.0, t * 9.0), seed + 4u)));
            v.y = mix(v.y, -u.shape2.z * (0.6 + 0.6 * e), e * 0.6);
        }

        float cool = 1.0 - exp(-dt * u.fire.y);
        float lost = T * cool;
        T -= lost;
        sm += lost * u.fire.z * (1.0 - fs_smoothstep(0.25, 0.55, T));
        sm *= exp(-dt * u.fire2.z);

        if (fs_solid(u, c)) {
            v = float2(0.0);
            T *= 0.5;
            sm = 0.0;
        }
        v.x *= exp(-dt * 7.0 * fs_smoothstep(0.1, 0.6, T));
        float edge = min(min(float(c.x), float(fs_n(u).x - 1 - c.x)), float(c.y));
        float fade = fs_smoothstep(0.0, 4.0, edge);
        T *= fade;
        sm *= fade;
        s_out.write(float4(v, T, sm), uint2(c));
    }

    kernel void divergence(
        constant FireSimUniform& u [[buffer(0)]],
        texture2d<float, access::read> s_in [[texture(0)]],
        texture2d<float, access::write> r_out [[texture(4)]],
        uint2 id [[thread_position_in_grid]]
    ) {
        int2 c = int2(id);
        if (!fs_inside(u, c)) { return; }
        float h = u.dims.z;
        float l = select(s_in.read(fs_cl(u, c - int2(1, 0))).x, 0.0, fs_solid(u, c - int2(1, 0)));
        float r = select(s_in.read(fs_cl(u, c + int2(1, 0))).x, 0.0, fs_solid(u, c + int2(1, 0)));
        float t = select(s_in.read(fs_cl(u, c - int2(0, 1))).y, 0.0, fs_solid(u, c - int2(0, 1)));
        float b = select(s_in.read(fs_cl(u, c + int2(0, 1))).y, 0.0, fs_solid(u, c + int2(0, 1)));
        float src = fs_fuel_band(u, fs_pos(u, c)) * fs_emission(u, fs_pos(u, c).x, u.origin.z, uint(u.shape2.y)) * u.shape2.z * 0.2 / h;
        r_out.write(float4((r - l + b - t) / (2.0 * h) - src, 0.0, 0.0, 0.0), uint2(c));
    }

    inline float fs_pn(constant FireSimUniform& u, texture2d<float, access::read> a_in, int2 c, float centre) {
        if (c.y < 0) { return 0.0; }
        if (!fs_inside(u, c) || fs_solid(u, c)) { return centre; }
        return fs_la(u, a_in, c);
    }

    kernel void jacobi(
        constant FireSimUniform& u [[buffer(0)]],
        texture2d<float, access::read> a_in [[texture(2)]],
        texture2d<float, access::read> b_in [[texture(3)]],
        texture2d<float, access::write> r_out [[texture(4)]],
        uint2 id [[thread_position_in_grid]]
    ) {
        int2 c = int2(id);
        if (!fs_inside(u, c)) { return; }
        float h = u.dims.z;
        float pc = fs_la(u, a_in, c);
        float s = fs_pn(u, a_in, c - int2(1, 0), pc) + fs_pn(u, a_in, c + int2(1, 0), pc)
                + fs_pn(u, a_in, c - int2(0, 1), pc) + fs_pn(u, a_in, c + int2(0, 1), pc);
        r_out.write(float4((s - h * h * fs_lb(u, b_in, c)) * 0.25, 0.0, 0.0, 0.0), uint2(c));
    }

    kernel void project(
        constant FireSimUniform& u [[buffer(0)]],
        texture2d<float, access::read> s_in [[texture(0)]],
        texture2d<float, access::write> s_out [[texture(1)]],
        texture2d<float, access::read> a_in [[texture(2)]],
        uint2 id [[thread_position_in_grid]]
    ) {
        int2 c = int2(id);
        if (!fs_inside(u, c)) { return; }
        float h = u.dims.z;
        float4 s = s_in.read(uint2(c));
        float pc = fs_la(u, a_in, c);
        float2 g = float2(
            fs_pn(u, a_in, c + int2(1, 0), pc) - fs_pn(u, a_in, c - int2(1, 0), pc),
            fs_pn(u, a_in, c + int2(0, 1), pc) - fs_pn(u, a_in, c - int2(0, 1), pc)
        ) / (2.0 * h);
        float2 v = s.xy - g;
        if (fs_solid(u, c)) { v = float2(0.0); }
        float vl = length(v);
        float vmax = 2.0 * h / u.dims.w;
        if (vl > vmax) { v *= vmax / vl; }
        s_out.write(float4(v, s.z, s.w), uint2(c));
    }

    inline float4 fs_cr(float t) {
        float t2 = t * t;
        float t3 = t2 * t;
        return float4(-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1.0, -1.5 * t3 + 2.0 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2);
    }

    inline float4 fs_sample_cubic(constant FireSimUniform& u, texture2d<float, access::read> s_in, float2 p) {
        float2 g = (p - u.origin.xy) / u.dims.z - 0.5;
        int2 i0 = int2(floor(g));
        float2 f = g - floor(g);
        float4 wx = fs_cr(f.x);
        float4 wy = fs_cr(f.y);
        float4 acc = float4(0.0);
        for (int y = 0; y < 4; y++) {
            float4 row = float4(0.0);
            for (int x = 0; x < 4; x++) {
                row += wx[x] * s_in.read(fs_cl(u, i0 + int2(x - 1, y - 1)));
            }
            acc += wy[y] * row;
        }
        float4 q0 = s_in.read(fs_cl(u, i0));
        float4 q1 = s_in.read(fs_cl(u, i0 + int2(1, 0)));
        float4 q2 = s_in.read(fs_cl(u, i0 + int2(0, 1)));
        float4 q3 = s_in.read(fs_cl(u, i0 + int2(1, 1)));
        return clamp(acc, min(min(q0, q1), min(q2, q3)), max(max(q0, q1), max(q2, q3)));
    }

    kernel void advect(
        constant FireSimUniform& u [[buffer(0)]],
        texture2d<float, access::read> s_in [[texture(0)]],
        texture2d<float, access::write> s_out [[texture(1)]],
        uint2 id [[thread_position_in_grid]]
    ) {
        int2 c = int2(id);
        if (!fs_inside(u, c)) { return; }
        float2 p = fs_pos(u, c);
        float2 v = s_in.read(uint2(c)).xy;
        float2 mid = p - 0.5 * u.dims.w * v;
        float2 vm = fs_sample_cubic(u, s_in, mid).xy;
        float4 r = fs_sample_cubic(u, s_in, p - u.dims.w * vm);
        s_out.write(float4(r.xy, max(r.z, 0.0), max(r.w, 0.0)), uint2(c));
    }

    kernel void fx_firesim_step_kernel(
        texture2d<float, access::read> prev_field [[texture(0)]],
        texture2d<float, access::write> next_field [[texture(1)]],
        constant FireSimParams& p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= next_field.get_width() || gid.y >= next_field.get_height()) { return; }
        int2 c = int2(gid);
        int2 sz = int2(prev_field.get_width(), prev_field.get_height());
        float4 cur = prev_field.read(uint2(clamp(c + int2(0, 1), int2(0), sz - 1)));
        float4 l = prev_field.read(uint2(clamp(c + int2(-1, 0), int2(0), sz - 1)));
        float4 r = prev_field.read(uint2(clamp(c + int2( 1, 0), int2(0), sz - 1)));
        float4 u = prev_field.read(uint2(clamp(c + int2( 0,-1), int2(0), sz - 1)));
        float temp = max((cur.x * 0.6 + (l.x + r.x + u.x) * 0.1333) - p.cooling * p.dt, 0.0);
        float smoke = max(cur.y * 0.96 + (cur.x - temp) * p.smoke, 0.0);
        next_field.write(float4(temp, smoke, cur.z, cur.w), gid);
    }
    """

    public static func source(for kind: FxEffectKind) -> String {
        switch kind {
        case .glow: return glowShader
        case .pulse: return pulseShader
        case .electric: return electricShader
        case .fire: return fireShader
        case .distort: return distortShader
        case .motion: return motionShader
        case .extras: return extrasShader
        case .fill: return fillShader
        }
    }

    public static func fragmentEntryPoint(for kind: FxEffectKind) -> String {
        "fx_\(kind.shaderName)_fragment"
    }

    #if canImport(Metal)
    public static var resourceBundle: Bundle { Bundle.module }

    public static var precompileEntries: [PrecompiledMetallib.ShaderEntry] {
        var entries = FxEffectKind.allCases.map { kind in
            PrecompiledMetallib.ShaderEntry(
                name: "fx_\(kind.shaderName)",
                source: source(for: kind),
                requiredFunction: "fx_vertex"
            )
        }
        entries.append(PrecompiledMetallib.ShaderEntry(
            name: "fx_blur",
            source: blurShader,
            requiredFunction: "fx_blur_vertex"
        ))
        entries.append(PrecompiledMetallib.ShaderEntry(
            name: "fx_mip",
            source: mipShader,
            requiredFunction: "fx_mip_vertex"
        ))
        entries.append(PrecompiledMetallib.ShaderEntry(
            name: "fx_firesim",
            source: fireSimShader,
            requiredFunction: "fx_firesim_step_kernel"
        ))
        return entries
    }
    #endif
}
