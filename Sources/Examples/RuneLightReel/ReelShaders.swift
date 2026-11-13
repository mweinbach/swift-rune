import Foundation

#if canImport(Metal)
import Metal
#endif

struct ReelGU: Sendable {
    var size: SIMD4<Float> = .zero // W, H, gi_w, gi_h
    var gi: SIMD4<Float> = .zero   // px per gi texel, time, highlighted probe count, unused
    var hp0: SIMD4<Float> = .zero
    var hp1: SIMD4<Float> = .zero
}

struct ReelVP: Sendable {
    var a: SIMD4<Float> = .zero
    var b: SIMD4<Float> = .zero
    var c: SIMD4<Float> = .zero
    var q0: SIMD4<Float> = .zero
    var q1: SIMD4<Float> = .zero
    var q2: SIMD4<Float> = .zero
    var q3: SIMD4<Float> = .zero
}

struct ReelMeanU: Sendable {
    var n: UInt32 = 0
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

struct ReelBloomU: Sendable {
    var p: SIMD4<Float> = .zero
}

struct ReelEncU: Sendable {
    var size: SIMD4<Float> = .zero // W, H, dither 8-bit, dither 10-bit
    var misc: SIMD4<Float> = .zero // bloom mix, bloom scale, 0, 0
}

struct ReelUIInst: Sendable {
    var rect: SIMD4<Float>
    var radii: SIMD4<Float>
    var fill: SIMD4<Float>
    var border: SIMD4<Float>
    var params: SIMD4<Float> // bw, kind (0 rect, 1 glyph, 2 shadow), sigma, 1
    var uv: SIMD4<Float>
    var vp: SIMD4<Float>
}

enum ReelShaders {
    static let uiMetalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Inst {
        float4 rect;
        float4 radii;
        float4 fill;
        float4 border;
        float4 params;
        float4 uv;
        float4 vp;
    };

    struct VOut {
        float4 pos [[position]];
        uint id [[flat]];
        float2 px;
    };

    vertex VOut reel_ui_vs(
        uint vi [[vertex_id]],
        uint ii [[instance_id]],
        constant Inst* insts [[buffer(0)]]
    ) {
        Inst u = insts[ii];
        int kind = int(u.params.y + 0.5);
        float m = (kind == 2) ? (u.params.z * 3.5 + 1.0) : 1.0;
        float2 corner = float2(float(vi & 1u), float((vi >> 1u) & 1u));
        float2 px = u.rect.xy - m + (u.rect.zw + 2.0 * m) * corner;
        VOut o;
        o.pos = float4(px.x / u.vp.x * 2.0 - 1.0, 1.0 - px.y / u.vp.y * 2.0, 0.0, 1.0);
        o.id = ii;
        o.px = px;
        return o;
    }

    static inline float sd_rrect(float2 q, float2 halfSz, float4 radii) {
        float r = (q.x >= 0.0) ? ((q.y >= 0.0) ? radii.z : radii.y) : ((q.y >= 0.0) ? radii.w : radii.x);
        float rr = clamp(r, 0.0, min(halfSz.x, halfSz.y));
        float2 k = abs(q) - halfSz + rr;
        return length(max(k, float2(0.0))) + min(max(k.x, k.y), 0.0) - rr;
    }

    static inline float erf_approx(float x) {
        float x2 = x * x;
        float a = 0.147;
        float v = sqrt(1.0 - exp(-x2 * (1.2732395 + a * x2) / (1.0 + a * x2)));
        return (x >= 0.0) ? v : -v;
    }

    fragment float4 reel_ui_fs(
        VOut in [[stage_in]],
        constant Inst* insts [[buffer(0)]],
        texture2d<float> atlas [[texture(0)]],
        sampler smp [[sampler(0)]]
    ) {
        Inst u = insts[in.id];
        int kind = int(u.params.y + 0.5);
        if (kind == 1) {
            float2 t = (in.px - u.rect.xy) / max(u.rect.zw, float2(1e-4));
            if (any(t < 0.0) || any(t > 1.0)) {
                return float4(0.0);
            }
            float2 uv = mix(u.uv.xy, u.uv.zw, t);
            float a = atlas.sample(smp, uv, level(0.0)).r;
            return u.fill * a;
        }
        float2 halfSz = u.rect.zw * 0.5;
        float2 q = in.px - u.rect.xy - halfSz;
        float d = sd_rrect(q, halfSz, u.radii);
        if (kind == 2) {
            float a = 0.5 - 0.5 * erf_approx(d / (max(u.params.z, 0.1) * 1.41421));
            return u.fill * a;
        }
        float cov = clamp(0.5 - d, 0.0, 1.0);
        float4 o = u.fill * cov;
        float bw = u.params.x;
        if (bw > 0.0) {
            float inner = clamp(0.5 - (d + bw), 0.0, 1.0);
            float band = cov - inner;
            o = o * (1.0 - u.border.a * band) + u.border * band;
        }
        return o;
    }
    """

    static let vizMetalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct G {
        float4 size; // W, H, gi w, gi h
        float4 gi;   // px per gi texel, time, highlighted probe count, unused
        float4 hp[2];
    };

    struct VP {
        float4 a;
        float4 b;
        float4 c;
        float4 q0;
        float4 q1;
        float4 q2;
        float4 q3;
    };

    constant float TAU = 6.28318531;

    struct FOut {
        float4 pos [[position]];
        uint k [[flat]];
    };

    vertex FOut vs_full(uint vi [[vertex_id]], uint ii [[instance_id]]) {
        float2 uv = float2(float((vi << 1u) & 2u), float(vi & 2u));
        FOut o;
        o.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
        o.k = ii;
        return o;
    }

    static inline float3 tone(float3 x) {
        return float3(1.0) - exp(-max(x, float3(0.0)));
    }

    static inline float3 panel(float2 p, constant G& g) {
        float2 uv = p / g.size.xy;
        float v = 1.0 - 0.25 * dot(uv - 0.5, uv - 0.5);
        return float3(0.0075, 0.0085, 0.013) * v;
    }

    static inline float aa_line(float d, float w) {
        float fw = max(fwidth(d), 1e-4);
        return 1.0 - smoothstep(w * 0.5 - fw * 0.5, w * 0.5 + fw * 0.5, abs(d));
    }

    fragment float4 fs_field(
        FOut in [[stage_in]],
        constant G& g [[buffer(0)]],
        texture2d<float> field [[texture(0)]],
        sampler lsamp [[sampler(0)]]
    ) {
        float2 p = in.pos.xy;
        float4 f = field.sample(lsamp, p / g.size.xy, level(0.0));
        float d = f.w;
        float3 col = panel(p, g);
        float fw = max(fwidth(d), 1e-3);
        if (d < 0.0) {
            float x = clamp(-d / 60.0, 0.0, 1.0);
            col = mix(float3(0.20, 0.085, 0.03), float3(0.06, 0.02, 0.008), x);
            float band = abs(fract(-d / 12.0 + 0.5) - 0.5) * 12.0;
            col = col + float3(0.35, 0.16, 0.05) * (1.0 - smoothstep(0.0, fw * 1.2, band)) * 0.5;
        } else {
            float x = clamp(d / 128.0, 0.0, 1.0);
            col = col + mix(float3(0.03, 0.10, 0.16), float3(0.004, 0.012, 0.025), sqrt(x)) * (1.0 - smoothstep(120.0, 128.0, d));
            float band = abs(fract(d / 16.0 + 0.5) - 0.5) * 16.0;
            float line = (1.0 - smoothstep(0.0, fw * 1.2, band)) * (1.0 - smoothstep(96.0, 127.0, d));
            col = col + float3(0.10, 0.32, 0.48) * line * (0.55 - 0.4 * x);
        }
        float zero = 1.0 - smoothstep(0.0, fw * 1.6, abs(d));
        col = col + float3(0.95, 0.85, 0.7) * zero;
        return float4(col, 1.0);
    }

    fragment float4 fs_scene(
        FOut in [[stage_in]],
        constant G& g [[buffer(0)]],
        constant VP* vp [[buffer(1)]],
        texture2d<float> emit [[texture(1)]],
        texture2d<float> occ [[texture(2)]]
    ) {
        float2 p = in.pos.xy;
        VP v = vp[in.k];
        uint2 t = uint2(clamp(int2(p / g.gi.x), int2(0), int2(int(emit.get_width()) - 1, int(emit.get_height()) - 1)));
        float4 em = emit.read(t, 0);
        float4 oc = occ.read(t, 0);
        float3 col = panel(p, g);
        col = col + float3(0.045, 0.05, 0.065) * oc.a;
        float cov = clamp(em.a / 1.5, 0.0, 1.0);
        float3 rad = em.rgb / max(em.a, 1e-4);
        col = col + tone(rad * v.a.z) * cov;
        return float4(col, 1.0);
    }

    static inline int2 ray_tex(uint n, int2 probe, uint j) {
        uint b = 2u << n;
        return probe * int(b) + int2(int(j % b), int(j / b));
    }

    fragment float4 fs_cascade(
        FOut in [[stage_in]],
        constant G& g [[buffer(0)]],
        constant VP* vp [[buffer(1)]],
        texture2d<float> c_own [[texture(3)]],
        texture2d<float> c_mrg [[texture(4)]],
        texture2d<float> m_own [[texture(5)]],
        texture2d<float> m_mrg [[texture(6)]]
    ) {
        float2 p = in.pos.xy;
        VP v = vp[in.k];
        uint n = uint(v.a.x + 0.5);
        float mixk = v.a.y;
        float expo = v.a.z;
        float s = float(1u << n);
        float sp = s * g.gi.x;
        int2 nprobe = int2(g.size.zw / s);
        float3 col = float3(0.0);
        float alpha = 0.0;

        int2 idx = clamp(int2(floor(p / sp)), int2(0), nprobe - int2(1));
        float2 c = (float2(idx) + 0.5) * sp;
        float2 local = p - c;
        float gap = max(0.75, sp * 0.07);
        float halfCell = sp * 0.5 - gap;
        float r = sp * 0.16;
        float2 q = abs(local) - float2(halfCell - r);
        float dcell = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
        float cell = 1.0 - smoothstep(-0.6, 0.6, dcell);
        float3 val = mix(m_own.read(uint2(idx), 0).rgb, m_mrg.read(uint2(idx), 0).rgb, mixk);
        col = col + (tone(val * expo) * 0.95 + float3(0.02, 0.024, 0.034)) * cell * v.b.x;
        alpha = max(alpha, cell * v.b.x * 0.8);
        float dr = max(0.9, sp * 0.06);
        float dot_k = (1.0 - smoothstep(dr - 0.6, dr + 0.6, length(local))) * v.b.y * 0.6 * smoothstep(9.0, 16.0, sp);
        col = mix(col, float3(0.85, 0.9, 1.0), dot_k);

        float t0 = (pow(4.0, float(n)) - 1.0) / 3.0 * g.gi.x;
        float t1 = (pow(4.0, float(n) + 1.0) - 1.0) / 3.0 * g.gi.x;
        uint nd = 4u << (2u * n);
        float grow = v.c.x;
        float t1g = mix(t0 + 0.001, t1, grow);
        int nh = int(g.gi.z);
        float3 ray = float3(0.0);
        float ring = 0.0;
        for (int h = 0; h < nh; h = h + 1) {
            float4 hp4 = g.hp[h / 2];
            float2 hp = hp4.xy;
            if ((h & 1) == 1) {
                hp = hp4.zw;
            }
            int2 pidx = clamp(int2(floor(hp / sp)), int2(0), nprobe - int2(1));
            float2 pc = (float2(pidx) + 0.5) * sp;
            float2 rel = p - pc;
            float rr = length(rel);
            float band = smoothstep(t0 - 1.0, t0 + 1.0, rr) * (1.0 - smoothstep(t1g - 1.0, t1g + 1.0, rr));
            ring = ring + band * 0.025 + (aa_line(rr - t0, v.c.w) + aa_line(rr - t1g, v.c.w) * step(0.01, grow)) * 0.55;
            float gap_px = max(t0, 1.0) * TAU / float(nd);
            uint stride = uint(max(1.0, exp2(ceil(log2(max(14.0 / gap_px, 1.0))))));
            uint shown = nd / stride;
            if (rr > t0 - 3.0 && rr < t1g + 3.0) {
                float ang = atan2(rel.y, rel.x);
                if (ang < 0.0) {
                    ang = ang + TAU;
                }
                float fj = ang / TAU * float(shown) - 0.5;
                int j0 = int(floor(fj));
                for (int o = 0; o < 2; o = o + 1) {
                    int modShown = int(shown);
                    uint js = uint(((j0 + o) % modShown + modShown) % modShown);
                    uint j = js * stride + stride / 2u;
                    float a = (float(j) + 0.5) / float(nd) * TAU;
                    float2 dir = float2(cos(a), sin(a));
                    float along = clamp(dot(rel, dir), t0, t1g);
                    float dist = length(rel - dir * along);
                    float rw = v.c.w;
                    float fade = 1.0 - 0.6 * clamp((along - t0) / max(t1 - t0, 1.0), 0.0, 1.0);
                    float w = (1.0 - smoothstep(rw * 0.5 - 0.6, rw * 0.5 + 0.6, dist)) * fade;
                    if (w > 0.0) {
                        int2 tx = ray_tex(n, pidx, j);
                        float3 rv = mix(c_own.read(uint2(tx), 0).rgb, c_mrg.read(uint2(tx), 0).rgb, mixk);
                        ray = max(ray, (tone(rv * expo * 2.5) * 1.3 + float3(0.06, 0.065, 0.085)) * w);
                    }
                }
            }
            float pd = length(rel);
            ring = ring + (1.0 - smoothstep(6.0, 8.0, pd)) * 1.2 + aa_line(pd - 14.0, v.c.w) * 0.8;
        }
        float3 rk = ray * v.b.z;
        float gk = clamp(ring * v.b.w, 0.0, 1.0);
        col = col + rk + float3(0.75, 0.82, 1.0) * gk;
        alpha = clamp(max(alpha, max(max(rk.r, rk.g), rk.b) * 1.5 + gk), 0.0, 1.0);
        return float4(col, alpha);
    }

    fragment float4 fs_fluence(
        FOut in [[stage_in]],
        constant G& g [[buffer(0)]],
        constant VP* vp [[buffer(1)]],
        texture2d<float> flu [[texture(7)]],
        sampler lsamp [[sampler(0)]]
    ) {
        float2 p = in.pos.xy;
        VP v = vp[in.k];
        float3 f = flu.sample(lsamp, p / g.size.xy, level(0.0)).rgb;
        return float4(panel(p, g) + tone(f * v.a.z), 1.0);
    }

    fragment float4 fs_accum(
        FOut in [[stage_in]],
        constant VP* vp [[buffer(1)]],
        texture2d<float> layer [[texture(8)]]
    ) {
        float4 c = layer.read(uint2(in.pos.xy), 0);
        return float4(c.rgb * vp[in.k].a.x, vp[in.k].a.x);
    }

    fragment float4 fs_mip(
        FOut in [[stage_in]],
        texture2d<float> layer [[texture(8)]],
        sampler lsamp [[sampler(0)]]
    ) {
        float2 sz = float2(layer.get_width(), layer.get_height());
        float2 uv = in.pos.xy * 2.0 / sz;
        return layer.sample(lsamp, uv, level(0.0));
    }

    struct LOut {
        float4 pos [[position]];
        float2 uv;
        uint k [[flat]];
    };

    vertex LOut vs_layer(
        uint vi [[vertex_id]],
        uint ii [[instance_id]],
        constant VP* vp [[buffer(1)]]
    ) {
        VP v = vp[ii];
        float4 q = v.q0;
        if (vi == 1u) {
            q = v.q1;
        } else if (vi == 2u) {
            q = v.q2;
        } else if (vi == 3u) {
            q = v.q3;
        }
        LOut o;
        o.pos = q;
        o.uv = float2(float(vi & 1u), float(vi >> 1u));
        o.k = ii;
        return o;
    }

    fragment float4 fs_layer(
        LOut in [[stage_in]],
        constant VP* vp [[buffer(1)]],
        texture2d<float> layer [[texture(8)]],
        sampler asamp [[sampler(1)]]
    ) {
        VP v = vp[in.k];
        float3 c = layer.sample(asamp, in.uv).rgb;
        float2 fw = max(fwidth(in.uv), float2(1e-6));
        float2 e2 = min(in.uv, float2(1.0) - in.uv) / fw;
        float e = min(e2.x, e2.y);
        float alpha = v.c.y * clamp(e, 0.0, 1.0);
        float frame = (1.0 - smoothstep(0.8, 1.8, e)) * v.c.z;
        float3 rgb = c + float3(0.55, 0.62, 0.78) * frame;
        return float4(rgb * alpha, alpha);
    }
    """

    static let bloomMetalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct BU {
        float4 p; // karis 0/1, tent radius (texels), unused, unused
    };

    struct BOut {
        float4 pos [[position]];
    };

    vertex BOut vs_b(uint vi [[vertex_id]]) {
        float2 uv = float2(float((vi << 1u) & 2u), float(vi & 2u));
        BOut o;
        o.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    static inline float karis(float3 c) {
        return 1.0 / (1.0 + dot(c, float3(0.2126, 0.7152, 0.0722)));
    }

    fragment float4 fs_bdown(
        BOut in [[stage_in]],
        constant BU& bu [[buffer(0)]],
        texture2d<float> bsrc [[texture(0)]],
        sampler bsamp [[sampler(0)]]
    ) {
        float2 sz = float2(bsrc.get_width(), bsrc.get_height());
        float2 uv = in.pos.xy * 2.0 / sz;
        float2 t = 1.0 / sz;
        const float2 s[13] = {
            float2(-2.0, -2.0), float2(0.0, -2.0), float2(2.0, -2.0),
            float2(-2.0, 0.0), float2(0.0, 0.0), float2(2.0, 0.0),
            float2(-2.0, 2.0), float2(0.0, 2.0), float2(2.0, 2.0),
            float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0)
        };
        float3 c[13];
        for (int k = 0; k < 13; k = k + 1) {
            c[k] = max(bsrc.sample(bsamp, uv + t * s[k], level(0.0)).rgb, float3(0.0));
        }
        float3 b0 = (c[9] + c[10] + c[11] + c[12]) * 0.25;
        float3 b1 = (c[0] + c[1] + c[3] + c[4]) * 0.25;
        float3 b2 = (c[1] + c[2] + c[4] + c[5]) * 0.25;
        float3 b3 = (c[3] + c[4] + c[6] + c[7]) * 0.25;
        float3 b4 = (c[4] + c[5] + c[7] + c[8]) * 0.25;
        float4 w = float4(0.5, 0.125, 0.125, 0.125);
        float w4 = 0.125;
        if (bu.p.x > 0.5) {
            w = w * float4(karis(b0), karis(b1), karis(b2), karis(b3));
            w4 = w4 * karis(b4);
        }
        float3 o = (b0 * w.x + b1 * w.y + b2 * w.z + b3 * w.w + b4 * w4) / (w.x + w.y + w.z + w.w + w4);
        return float4(o, 1.0);
    }

    fragment float4 fs_bup(
        BOut in [[stage_in]],
        constant BU& bu [[buffer(0)]],
        texture2d<float> bsrc [[texture(0)]],
        sampler bsamp [[sampler(0)]]
    ) {
        float2 sz = float2(bsrc.get_width(), bsrc.get_height());
        float2 uv = in.pos.xy * 0.5 / sz;
        float2 t = bu.p.y / sz;
        float3 o = bsrc.sample(bsamp, uv, level(0.0)).rgb * 4.0;
        o = o + (bsrc.sample(bsamp, uv + float2(-t.x, 0.0), level(0.0)).rgb
            + bsrc.sample(bsamp, uv + float2(t.x, 0.0), level(0.0)).rgb
            + bsrc.sample(bsamp, uv + float2(0.0, -t.y), level(0.0)).rgb
            + bsrc.sample(bsamp, uv + float2(0.0, t.y), level(0.0)).rgb) * 2.0;
        o = o + bsrc.sample(bsamp, uv - t, level(0.0)).rgb
            + bsrc.sample(bsamp, uv + t, level(0.0)).rgb
            + bsrc.sample(bsamp, uv + float2(t.x, -t.y), level(0.0)).rgb
            + bsrc.sample(bsamp, uv + float2(-t.x, t.y), level(0.0)).rgb;
        return float4(o / 16.0, 1.0);
    }
    """

    static let meanMetalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct MeanU {
        uint n;
        uint pad0;
        uint pad1;
        uint pad2;
    };

    kernel void cs_mean(
        uint3 gid [[thread_position_in_grid]],
        constant MeanU& mu [[buffer(0)]],
        texture2d<float, access::read> csrc [[texture(0)]],
        texture2d<float, access::write> mout [[texture(1)]]
    ) {
        uint2 dims = uint2(mout.get_width(), mout.get_height());
        uint b = 2u << mu.n;
        uint2 np = uint2(csrc.get_width(), csrc.get_height()) / b;
        if (gid.x >= np.x || gid.y >= np.y || gid.x >= dims.x || gid.y >= dims.y) {
            return;
        }
        float3 acc = float3(0.0);
        for (uint y = 0u; y < b; y = y + 1u) {
            for (uint x = 0u; x < b; x = x + 1u) {
                acc = acc + csrc.read(gid.xy * b + uint2(x, y)).rgb;
            }
        }
        mout.write(float4(acc / float(b * b), 1.0), gid.xy);
    }
    """

    static let encMetalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct EncU {
        float4 size; // W, H, dither 8-bit, dither 10-bit
        float4 misc; // bloom mix, bloom scale, unused, unused
    };

    static inline float3 srgb_encode3(float3 c) {
        float3 x = clamp(c, float3(0.0), float3(1.0));
        float3 lo = x * 12.92;
        float3 hi = 1.055 * pow(x, float3(1.0 / 2.4)) - 0.055;
        return select(hi, lo, x <= float3(0.0031308));
    }

    static inline float3 final_px(
        int2 p,
        constant EncU& eu,
        texture2d<float, access::read> img,
        texture2d<float, access::read> overlay,
        texture2d<float> bloom,
        sampler esamp
    ) {
        float3 b = bloom.sample(esamp, (float2(p) + 0.5) / eu.size.xy, level(0.0)).rgb;
        float3 c = mix(img.read(uint2(p)).rgb, b * eu.misc.y, eu.misc.x);
        float4 o = overlay.read(uint2(p));
        return srgb_encode3(c * (1.0 - o.a) + o.rgb);
    }

    static inline float tpdf(int2 p, int ch, texture2d<float, access::read> noise) {
        float4 n = noise.read(uint2(p.x & 63, p.y & 63));
        float4 o = noise.read(uint2((p.x + 32) & 63, (p.y + 17) & 63));
        float a = n.x;
        float b = o.y;
        if (ch == 1) {
            a = n.y;
            b = o.z;
        } else if (ch == 2) {
            a = n.z;
            b = o.x;
        }
        return a + b - 1.0;
    }

    kernel void cs_yuv(
        uint3 gid [[thread_position_in_grid]],
        constant EncU& eu [[buffer(0)]],
        texture2d<float, access::read> img [[texture(0)]],
        texture2d<float, access::read> overlay [[texture(1)]],
        texture2d<float, access::read> noise [[texture(2)]],
        texture2d<float> bloom [[texture(3)]],
        sampler esamp [[sampler(0)]],
        device uint* y8 [[buffer(1)]],
        device uint* y10 [[buffer(2)]]
    ) {
        uint w = uint(eu.size.x);
        uint h = uint(eu.size.y);
        uint x0 = gid.x * 8u;
        uint yy = gid.y * 2u;
        if (x0 >= w || yy >= h) {
            return;
        }
        float cb[4] = {0.0, 0.0, 0.0, 0.0};
        float cr[4] = {0.0, 0.0, 0.0, 0.0};
        for (uint r = 0u; r < 2u; r = r + 1u) {
            uint y = yy + r;
            uint w8[2] = {0u, 0u};
            uint w10[4] = {0u, 0u, 0u, 0u};
            for (uint i = 0u; i < 8u; i = i + 1u) {
                int2 p = int2(int(x0 + i), int(y));
                float3 c = final_px(p, eu, img, overlay, bloom, esamp);
                float yl = dot(c, float3(0.2126, 0.7152, 0.0722));
                cb[i / 2u] = cb[i / 2u] + (c.b - yl) / 1.8556 * 0.25;
                cr[i / 2u] = cr[i / 2u] + (c.r - yl) / 1.5748 * 0.25;
                float d = tpdf(p, 0, noise);
                uint v8 = uint(clamp(round(16.0 + 219.0 * yl + d * eu.size.z), 0.0, 255.0));
                uint v10 = uint(clamp(round(64.0 + 876.0 * yl + d * eu.size.w), 0.0, 1023.0));
                w8[i / 4u] = w8[i / 4u] | (v8 << (8u * (i % 4u)));
                w10[i / 2u] = w10[i / 2u] | (v10 << (16u * (i % 2u)));
            }
            uint o8 = (y * w + x0) / 4u;
            y8[o8] = w8[0];
            y8[o8 + 1u] = w8[1];
            uint o10 = (y * w + x0) / 2u;
            for (uint k = 0u; k < 4u; k = k + 1u) {
                y10[o10 + k] = w10[k];
            }
        }
        uint cw = w / 2u;
        uint crow = yy / 2u;
        uint cx0 = x0 / 2u;
        uint u8w = 0u;
        uint v8w = 0u;
        uint u10[2] = {0u, 0u};
        uint v10[2] = {0u, 0u};
        for (uint k = 0u; k < 4u; k = k + 1u) {
            int2 p = int2(int(cx0 + k), int(crow)) * 2;
            float du = tpdf(p, 1, noise);
            float dv = tpdf(p, 2, noise);
            uint a8 = uint(clamp(round(128.0 + 224.0 * cb[k] + du * eu.size.z), 0.0, 255.0));
            uint b8 = uint(clamp(round(128.0 + 224.0 * cr[k] + dv * eu.size.z), 0.0, 255.0));
            u8w = u8w | (a8 << (8u * k));
            v8w = v8w | (b8 << (8u * k));
            uint a10 = uint(clamp(round(512.0 + 896.0 * cb[k] + du * eu.size.w), 0.0, 1023.0));
            uint b10 = uint(clamp(round(512.0 + 896.0 * cr[k] + dv * eu.size.w), 0.0, 1023.0));
            u10[k / 2u] = u10[k / 2u] | (a10 << (16u * (k % 2u)));
            v10[k / 2u] = v10[k / 2u] | (b10 << (16u * (k % 2u)));
        }
        uint ysz = w * h;
        uint csz = cw * (h / 2u);
        y8[(ysz + crow * cw + cx0) / 4u] = u8w;
        y8[(ysz + csz + crow * cw + cx0) / 4u] = v8w;
        uint b10u = (ysz + crow * cw + cx0) / 2u;
        uint b10v = (ysz + csz + crow * cw + cx0) / 2u;
        y10[b10u] = u10[0];
        y10[b10u + 1u] = u10[1];
        y10[b10v] = v10[0];
        y10[b10v + 1u] = v10[1];
    }

    kernel void cs_rgba(
        uint3 gid [[thread_position_in_grid]],
        constant EncU& eu [[buffer(0)]],
        texture2d<float, access::read> img [[texture(0)]],
        texture2d<float, access::read> overlay [[texture(1)]],
        texture2d<float, access::read> noise [[texture(2)]],
        texture2d<float> bloom [[texture(3)]],
        sampler esamp [[sampler(0)]],
        device uint* rgba [[buffer(3)]]
    ) {
        uint w = uint(eu.size.x);
        uint h = uint(eu.size.y);
        if (gid.x >= w || gid.y >= h) {
            return;
        }
        int2 p = int2(gid.xy);
        float3 c = final_px(p, eu, img, overlay, bloom, esamp);
        uint o = 0u;
        for (int k = 0; k < 3; k = k + 1) {
            uint v = uint(clamp(round(c[k] * 255.0 + tpdf(p, k, noise) * eu.size.z), 0.0, 255.0));
            o = o | (v << (8u * uint(k)));
        }
        rgba[gid.y * w + gid.x] = o | (255u << 24u);
    }
    """
}
