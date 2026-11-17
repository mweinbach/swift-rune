import Foundation

/// Faithful WGSL-to-MSL translations of upstream Rune shaders (`clip.wgsl`, `shader.wgsl`,
/// `gpu/springs.wgsl`, `backdrop_blur.wgsl`, `backdrop_composite.wgsl`, `layer_blur.wgsl`, `outline.wgsl`).
public enum RenderShaders {
    /// Upstream `clip.wgsl` WGSL source string (for compositors inspecting `CLIP_WGSL`).
    public static let clipWGSL: String = #"""
const CONTINUOUS_K: f32 = 1.52866483;
fn sd_continuous(p: vec2<f32>, half: vec2<f32>, r: f32) -> f32 {
    let e = CONTINUOUS_K * r;
    let q = half - abs(p);
    let v = vec2<f32>(e) - q;
    if (v.x <= 0.0 || v.y <= 0.0) { return max(-q.x, -q.y); }
    let u = atan2(v.y, v.x) * (4.0 / 3.14159265) - 1.0;
    let u2 = u * u;
    return length(v) - e * (1.14602295 + u2 * (-0.37573161 + u2 * (0.30796609 - 0.07724354 * u2)));
}
fn sd_rounded(p: vec2<f32>, half: vec2<f32>, radii: vec4<f32>) -> f32 {
    var r = radii.x;
    if (p.x > 0.0) { r = select(radii.y, radii.z, p.y > 0.0); }
    else { r = select(radii.x, radii.w, p.y > 0.0); }
    if (r < 0.0) { return sd_continuous(p, half, min(-r, min(half.x, half.y))); }
    r = min(r, min(half.x, half.y));
    let q = abs(p) - half + vec2<f32>(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2<f32>(0.0))) - r;
}
fn ramp(d: f32, fade: f32) -> f32 {
    if (fade == 0.0) { return clamp(d + 0.5, 0.0, 1.0); }
    let x = clamp(d / abs(fade), 0.0, 1.0);
    if (fade < 0.0) { return x; }
    return x * x * (3.0 - 2.0 * x);
}
fn unpack_clip_radii(w: u32) -> vec4<f32> {
    if (w == 0u) { return vec4<f32>(0.0); }
    if ((w & 0x60000000u) != 0x60000000u) { return vec4<f32>(bitcast<f32>(w)); }
    let step = select(0.5, 2.0, (w & 0x10000000u) != 0u);
    let sgn = select(1.0, -1.0, (w & 0x80000000u) != 0u);
    return vec4<f32>(f32(w & 0x7fu), f32((w >> 7u) & 0x7fu), f32((w >> 14u) & 0x7fu), f32((w >> 21u) & 0x7fu)) * (step * sgn);
}
fn clip_alpha(p: vec2<f32>, c: vec4<f32>, packed: vec4<u32>) -> f32 {
    let f = vec4<f32>(unpack2x16float(packed.x), unpack2x16float(packed.y));
    let offset = unpack4x8unorm(packed.z);
    let hard = vec4<f32>(p - c.xy, c.zw - p);
    var alpha = 1.0;
    for (var edge = 0u; edge < 4u; edge++) {
        var a = ramp(hard[edge], f[edge]);
        if offset[edge] >= 1.0 { a = ramp(hard[edge], 0.0); }
        else if offset[edge] > 0.0 { a = min(ramp(hard[edge], 0.0), ramp(hard[edge] + offset[edge] * abs(f[edge]), f[edge])); }
        alpha *= a;
    }
    if packed.w != 0u {
        let half = (c.zw - c.xy) * 0.5;
        alpha *= clamp(0.5 - sd_rounded(p - c.xy - half, half, unpack_clip_radii(packed.w)), 0.0, 1.0);
    }
    return alpha;
}
"""#

    /// Shared MSL clip math (`clip.wgsl`), prepended to Rune shaders and usable by custom Metal compositors.
    public static let clipMSL: String = """
    constant float CONTINUOUS_K = 1.52866483;

    static inline float sd_continuous(float2 p, float2 halfSize, float r) {
        float e = CONTINUOUS_K * r;
        float2 q = halfSize - abs(p);
        float2 v = float2(e) - q;
        if (v.x <= 0.0 || v.y <= 0.0) { return max(-q.x, -q.y); }
        float u = atan2(v.y, v.x) * (4.0 / 3.14159265) - 1.0;
        float u2 = u * u;
        return length(v) - e * (1.14602295 + u2 * (-0.37573161 + u2 * (0.30796609 - 0.07724354 * u2)));
    }

    static inline float sd_rounded(float2 p, float2 halfSize, float4 radii) {
        float r = radii.x;
        if (p.x > 0.0) {
            r = select(radii.y, radii.z, p.y > 0.0);
        } else {
            r = select(radii.x, radii.w, p.y > 0.0);
        }
        if (r < 0.0) {
            return sd_continuous(p, halfSize, min(-r, min(halfSize.x, halfSize.y)));
        }
        r = min(r, min(halfSize.x, halfSize.y));
        float2 q = abs(p) - halfSize + float2(r);
        return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - r;
    }

    static inline float clip_ramp(float d, float fade) {
        if (fade == 0.0) {
            return clamp(d + 0.5, 0.0, 1.0);
        }
        float x = clamp(d / abs(fade), 0.0, 1.0);
        if (fade < 0.0) {
            return x;
        }
        return x * x * (3.0 - 2.0 * x);
    }

    static inline float4 unpack_clip_radii(uint w) {
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

    static inline float clip_alpha(float2 p, float4 c, uint4 packed) {
        float2 f01 = float2(as_type<half2>(packed.x));
        float2 f23 = float2(as_type<half2>(packed.y));
        float f[4] = { f01.x, f01.y, f23.x, f23.y };
        float4 offset = unpack_unorm4x8_to_float(packed.z);
        float hard[4] = { p.x - c.x, p.y - c.y, c.z - p.x, c.w - p.y };
        float offsets[4] = { offset.x, offset.y, offset.z, offset.w };
        float alpha = 1.0;
        for (uint edge = 0u; edge < 4u; edge++) {
            float a = clip_ramp(hard[edge], f[edge]);
            if (offsets[edge] >= 1.0) {
                a = clip_ramp(hard[edge], 0.0);
            } else if (offsets[edge] > 0.0) {
                a = min(clip_ramp(hard[edge], 0.0), clip_ramp(hard[edge] + offsets[edge] * abs(f[edge]), f[edge]));
            }
            alpha *= a;
        }
        if (packed.w != 0u) {
            float2 halfSize = (c.zw - c.xy) * 0.5;
            alpha *= clamp(0.5 - sd_rounded(p - c.xy - halfSize, halfSize, unpack_clip_radii(packed.w)), 0.0, 1.0);
        }
        return alpha;
    }
    """

    /// Faithful MSL translation of `clip.wgsl` + `shader.wgsl` + `gpu/springs.wgsl`.
    public static let shaderMSL: String = """
    #include <metal_stdlib>
    using namespace metal;

    \(clipMSL)

    struct RenderGlobals {
        float2 viewport;
        float2 pad;
        float4 flags;
        float4 projection;
    };

    struct RenderInstanceIn {
        float4 rect;
        float4 radii;
        float4 fill;
        float4 border;
        float4 params;
        float4 uv;
        float4 clip;
        uint4 fade;
    };

    struct RenderOut {
        float4 pos [[position]];
        float2 p;
        float4 rect [[flat]];
        float4 radii [[flat]];
        float4 fill [[flat]];
        float4 border [[flat]];
        float4 params [[flat]];
        float4 uv [[flat]];
        float4 clip [[flat]];
        uint4 fade [[flat]];
    };

    static inline RenderOut base_vs(RenderInstanceIn i, uint vi, constant RenderGlobals &g) {
        float2 corner = float2(float(vi & 1u), float(vi >> 1u));
        float kind = i.params.y;
        float grow = 1.0 + i.params.z * 2.0;
        if (kind > 0.5 && kind < 1.5) {
            grow = i.params.z * 3.0 + 1.0;
        } else if (kind > 1.5 && kind < 2.5) {
            grow = 0.0;
        } else if (kind > 2.5 && kind < 3.5) {
            grow = 1.0;
        } else if (kind > 4.5 && kind < 9.5) {
            grow = 1.0;
        }
        float2 lo = i.rect.xy - float2(grow);
        float2 sz = select(i.rect.zw + float2(2.0 * grow), float2(0.0), kind > 11.5);
        float2 hi = lo + sz;
        if (kind < 1.5 && i.uv.z < 0.0) {
            lo = max(lo, i.rect.xy + i.uv.xy);
            hi = max(min(hi, i.rect.xy + float2(-i.uv.z, i.uv.w)), lo);
        }
        float2 p = select(lo, hi, corner > float2(0.5));
        float2 screen = p;
        if (kind > 1.5 && kind < 2.5 && i.params.x != 0.0) {
            float2 center = i.rect.xy + i.rect.zw * 0.5;
            float2 q = p - center;
            float c = cos(i.params.x);
            float s = sin(i.params.x);
            screen = center + float2(c * q.x - s * q.y, s * q.x + c * q.y);
        }
        if (kind > 7.5 && kind < 8.5 && i.border.y != 0.0) {
            float2 q = p - i.border.zw;
            float c = cos(i.border.y);
            float s = sin(i.border.y);
            screen = i.border.zw + float2(c * q.x - s * q.y, s * q.x + c * q.y);
        }
        RenderOut o;
        float2 size_px = select(g.viewport, g.projection.zw, g.projection.z > 0.0);
        float2 local = screen - g.projection.xy;
        o.pos = float4(local.x / size_px.x * 2.0 - 1.0, 1.0 - local.y / size_px.y * 2.0, 0.0, 1.0);
        o.p = p;
        o.rect = i.rect;
        o.radii = i.radii;
        o.fill = i.fill;
        o.border = i.border;
        o.params = i.params;
        o.uv = i.uv;
        o.clip = i.clip;
        o.fade = i.fade;
        return o;
    }

    vertex RenderOut vs(
        uint vi [[vertex_id]],
        uint iid [[instance_id]],
        constant RenderInstanceIn *instances [[buffer(0)]],
        constant RenderGlobals &g [[buffer(1)]]
    ) {
        return base_vs(instances[iid], vi, g);
    }

    // --- GPU Springs (`gpu/springs.wgsl`) ---
    struct SpringTrack {
        float4 abcd;
        float2 rates;
        float goal;
        uint kind;
        float2 start;
        float duration;
        float pad;
    };

    struct SpringNode {
        SpringTrack x;
        SpringTrack y;
        SpringTrack opacity;
    };

    static inline float spring_exp(float x) {
        if (x < -87.0) { return 0.0; }
        float xc = clamp(x, -87.0, 88.0);
        float k = rint(xc * 1.4426950408889634);
        float r = fma(-k, 0.0000014286068, fma(-k, 0.69314575, xc));
        float r2 = r * r;
        float a = 1.0 + r;
        float b = fma(r, 1.0 / 6.0, 0.5);
        float c = fma(r, 1.0 / 120.0, 1.0 / 24.0);
        float p = fma(r2, fma(r2, fma(r2, 1.0 / 720.0, c), b), a);
        return p * as_type<float>(uint(int(k) + 127) << 23u);
    }

    static inline float2 spring_sample(SpringTrack s, float2 time) {
        float whole = float(int(time.x) - int(s.start.x));
        float t = max(whole + (time.y - s.start.y), 0.0);
        if (s.kind == 0u || t >= s.duration) { return float2(s.goal, 0.0); }
        float4 c = s.abcd;
        if (s.kind == 1u) {
            float e = exp(-s.rates.x * t);
            float co = cos(s.rates.y * t);
            float si = sin(s.rates.y * t);
            return float2(s.goal + e * (c.x * co + c.y * si), e * (c.z * co + c.w * si));
        }
        if (s.kind == 2u) {
            float e = exp(-s.rates.x * t);
            return float2(s.goal + (c.x + c.y * t) * e, (c.z + c.w * t) * e);
        }
        float e1 = spring_exp(c.z * t);
        float e2 = spring_exp(c.w * t);
        return float2(s.goal + (c.x * e1 + c.y * e2), c.x * c.z * e1 + c.y * c.w * e2);
    }

    vertex RenderOut vs_springs(
        uint vi [[vertex_id]],
        uint iid [[instance_id]],
        constant RenderInstanceIn *instances [[buffer(0)]],
        constant RenderGlobals &g [[buffer(1)]],
        constant SpringNode *spring_nodes [[buffer(2)]],
        constant uint *spring_ids [[buffer(3)]]
    ) {
        SpringNode node = spring_nodes[spring_ids[iid]];
        float2 time = g.pad;
        float2 offset = float2(spring_sample(node.x, time).x, spring_sample(node.y, time).x);
        float alpha = clamp(spring_sample(node.opacity, time).x, 0.0, 1.0);
        RenderInstanceIn i = instances[iid];
        i.rect = float4(i.rect.xy + offset, i.rect.zw);
        i.fill *= alpha;
        // Image border stores atlas bounds rather than a paint color.
        if (i.params.y != 7.0) { i.border *= alpha; }
        if (i.params.y > 3.5 && i.params.y < 4.5) { i.uv *= alpha; }
        if (i.params.y > 4.5 && i.params.y < 6.5) {
            i.radii += float4(offset, offset);
            if (i.params.y > 5.5) { i.uv = float4(i.uv.xy + offset, i.uv.zw); }
        }
        return base_vs(i, vi, g);
    }

    // --- Fragment helpers (`shader.wgsl:111-358`) ---
    static inline float gaussian(float x, float sigma) {
        return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * 3.14159265) * sigma);
    }

    static inline float2 erf2(float2 x) {
        float2 s = sign(x);
        float2 a = abs(x);
        float2 r = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
        r = r * r;
        return s - s / (r * r);
    }

    static inline float shadow_x(float x, float y, float sigma, float corner, float2 halfSize) {
        float delta = min(halfSize.y - corner - abs(y), 0.0);
        float curved = halfSize.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
        float2 integral = 0.5 + 0.5 * erf2((x + float2(-curved, curved)) * (sqrt(0.5) / sigma));
        return integral.y - integral.x;
    }

    constant float SHADOW_INSIDE = 0.99863125;

    static inline float shadow_fn(float2 p, float2 halfSize, float sigma, float corner) {
        if (abs(p.x) <= halfSize.x - 6.0 * sigma && abs(p.y) <= halfSize.y - corner - 6.0 * sigma) {
            return SHADOW_INSIDE;
        }
        float lo = p.y - halfSize.y;
        float hi = p.y + halfSize.y;
        float start = clamp(-3.0 * sigma, lo, hi);
        float end = clamp(3.0 * sigma, lo, hi);
        float step = (end - start) / 4.0;
        float y = start + step * 0.5;
        float v = 0.0;
        for (int k = 0; k < 4; k = k + 1) {
            v = v + shadow_x(p.x, p.y - y, sigma, corner, halfSize) * gaussian(y, sigma) * step;
            y = y + step;
        }
        return v;
    }

    static inline float segment_fn(float2 p, float2 a, float2 b, float hw, bool roundCap) {
        float2 ba = b - a;
        float len = length(ba);
        if (len < 1e-4) {
            if (!roundCap) { return 0.0; }
            float eff_hw = max(hw, 0.5);
            return min(2.0 * hw, 1.0) * clamp(0.5 - (length(p - a) - eff_hw), 0.0, 1.0);
        }
        float2 u = ba / len;
        float2 q = p - a;
        float along = dot(q, u);
        float perp = abs(q.x * u.y - q.y * u.x);
        float eff_hw = max(hw, 0.5);
        float weight = min(2.0 * hw, 1.0);
        if (roundCap) {
            float clamped = clamp(along, 0.0, len);
            return weight * clamp(0.5 - (length(q - u * clamped) - eff_hw), 0.0, 1.0);
        } else {
            float2 edge = float2(abs(along - len * 0.5) - len * 0.5, perp - eff_hw);
            float d = min(max(edge.x, edge.y), 0.0) + length(max(edge, float2(0.0)));
            return weight * clamp(0.5 - d, 0.0, 1.0);
        }
    }

    static inline float edge_fn(float2 p, float2 a, float2 b, float2 c) {
        float2 e = b - a;
        float l = max(length(e), 1e-6);
        float2 n = float2(-e.y, e.x) / l;
        float s = select(-1.0, 1.0, dot(c - a, n) >= 0.0);
        return dot(p - a, n) * s;
    }

    static inline bool owns_fn(float2 p, float2 a, float2 b, float2 c) {
        bool swap = a.x > b.x || (a.x == b.x && a.y > b.y);
        float2 lo = select(a, b, swap);
        float2 hi = select(b, a, swap);
        float2 e = hi - lo;
        float side = e.x * (c.y - lo.y) - e.y * (c.x - lo.x);
        float v = e.x * (p.y - lo.y) - e.y * (p.x - lo.x);
        if (side > 0.0) {
            return v >= 0.0;
        }
        return v < 0.0;
    }

    static inline float soft_fn(float2 p, float2 a, float2 b, float2 c) {
        float d = edge_fn(p, a, b, c);
        float2 e = b - a;
        float t = dot(p - a, e) / max(dot(e, e), 1e-6);
        if (t < 0.0 || t > 1.0) {
            return select(0.0, 1.0, d >= 0.0);
        }
        return clamp(d + 0.5, 0.0, 1.0);
    }

    static inline float triangle_fn(float2 p, float2 a, float2 b, float2 c, uint aa) {
        float cov = 1.0;
        if ((aa & 1u) == 1u) {
            cov = cov * soft_fn(p, a, b, c);
        } else if (!owns_fn(p, a, b, c)) {
            return 0.0;
        }
        if ((aa & 2u) == 2u) {
            cov = cov * soft_fn(p, b, c, a);
        } else if (!owns_fn(p, b, c, a)) {
            return 0.0;
        }
        if ((aa & 4u) == 4u) {
            cov = cov * soft_fn(p, c, a, b);
        } else if (!owns_fn(p, c, a, b)) {
            return 0.0;
        }
        return cov;
    }

    static inline float4 srgb_encode(float4 c) {
        if (c.a <= 0.0) { return float4(0.0); }
        float3 u = clamp(c.rgb / c.a, float3(0.0), float3(1.0));
        float3 enc = select(pow(u, float3(1.0 / 2.4)) * 1.055 - float3(0.055), u * 12.92, u <= float3(0.0031308));
        return float4(enc * c.a, c.a);
    }

    static inline float4 image_texel(int2 t, bool premultiplied, texture2d<float> images, constant RenderGlobals &g) {
        float4 c = images.read(uint2(t));
        if (g.flags.x > 0.5) {
            if (c.a <= 0.0) { return float4(0.0); }
            float3 lin = select(c.rgb, c.rgb / c.a, premultiplied);
            return float4(srgb_encode(float4(lin, 1.0)).rgb * c.a, c.a);
        }
        if (premultiplied) { return c; }
        return float4(c.rgb * c.a, c.a);
    }

    static inline float2 ring_arc(float2 p, float2 size, float4 radii, float bw) {
        float h = bw * 0.5;
        float2 halfSize = size * 0.5;
        float4 rc = max(min(abs(radii), float4(min(halfSize.x, halfSize.y))) - float4(h), float4(0.0));
        float4 e = rc + float4(h);
        float4 arc = rc * 1.5707964;
        float s_tr = max(size.x - bw - rc.x - rc.y, 0.0);
        float s_right = s_tr + arc.y;
        float s_br = s_right + max(size.y - bw - rc.y - rc.z, 0.0);
        float s_bottom = s_br + arc.z;
        float s_bl = s_bottom + max(size.x - bw - rc.z - rc.w, 0.0);
        float s_left = s_bl + arc.w;
        float s_tl = s_left + max(size.y - bw - rc.w - rc.x, 0.0);
        float top = p.x - e.x;
        float right = s_right + p.y - e.y;
        float bottom = s_bottom + size.x - e.z - p.x;
        float left = s_left + size.y - e.w - p.y;
        float s;
        if (p.x > halfSize.x) {
            if (p.y > halfSize.y) {
                float2 v = p - (size - float2(e.z));
                if (v.x > 0.0 && v.y > 0.0) { s = s_br + atan2(v.y, v.x) * rc.z; }
                else { s = select(bottom, right, size.x - p.x < size.y - p.y); }
            } else {
                float2 v = p - float2(size.x - e.y, e.y);
                if (v.x > 0.0 && v.y < 0.0) { s = s_tr + atan2(v.x, -v.y) * rc.y; }
                else { s = select(top, right, size.x - p.x < p.y); }
            }
        } else if (p.y > halfSize.y) {
            float2 v = p - float2(e.w, size.y - e.w);
            if (v.x < 0.0 && v.y > 0.0) { s = s_bl + atan2(-v.x, v.y) * rc.w; }
            else { s = select(bottom, left, p.x < size.y - p.y); }
        } else {
            float2 v = p - float2(e.x);
            if (v.x < 0.0 && v.y < 0.0) { s = s_tl + atan2(-v.y, -v.x) * rc.x; }
            else { s = select(top, left, p.x < p.y); }
        }
        return float2(s, s_tl + arc.x);
    }

    static inline float dash_cov(float s, float total, float3 d) {
        float nominal = d.x + d.y;
        float k = max(total, 0.001) / (max(floor(total / nominal + 0.5), 1.0) * nominal);
        float period = nominal * k;
        float dash = d.x * k;
        float a = s + d.z * k - dash * 0.5;
        float m = a - period * floor(a / period + 0.5);
        return clamp(dash * 0.5 - abs(m) + 0.5, 0.0, 1.0);
    }

    static inline float4 border_over(float4 fill, float4 edge, float d, float inner_d, float soft, float bw, float opacity, bool shrink) {
        float cov = clamp(0.5 - d / (soft * 2.0), 0.0, 1.0);
        float ring = max(cov - clamp(0.5 - inner_d / (soft * 2.0), 0.0, 1.0), 0.0);
        float hide = clamp(edge.a / clamp(opacity, 1e-6, 1.0), 0.0, 1.0);
        float under = clamp(0.5 - (d + select(0.0, bw * 0.5, shrink && hide > 0.999)) / (soft * 2.0), 0.0, 1.0);
        return edge * ring + fill * (under * (1.0 - hide * ring));
    }

    static inline float box_cov(float2 p, float2 halfSize, float4 radii) {
        float r = radii.x;
        if (p.x > 0.0) {
            r = select(radii.y, radii.z, p.y > 0.0);
        } else {
            r = select(radii.x, radii.w, p.y > 0.0);
        }
        if (r == 0.0) {
            float2 e = clamp(min(halfSize, p + float2(0.5)) - max(-halfSize, p - float2(0.5)), float2(0.0), float2(1.0));
            return e.x * e.y;
        }
        return clamp(0.5 - sd_rounded(p, halfSize, radii), 0.0, 1.0);
    }

    static inline float hole_alpha(float2 p, float4 h) {
        if (h.w <= 0.0) { return 1.0; }
        return clamp((length(p - h.xy) - (h.z + h.w) * 0.5) / max(h.w - h.z, 1.0) + 0.5, 0.0, 1.0);
    }

    static inline float4 layer_texel(int2 t, float2 size, texture2d<float> images) {
        int2 dims = int2(images.get_width(), images.get_height());
        int2 bound = min(int2(size), dims);
        if (any(t < int2(0)) || any(t >= bound)) { return float4(0.0); }
        return images.read(uint2(t));
    }

    #ifdef RUNE_WINDFOIL
    static inline float4 rune_fragment(RenderOut i, constant RenderGlobals &g,
        texture2d<float> atlas, texture2d<float> images, texture2d<uint> outlines, thread float4 &lcd_cov) {
    #else
    fragment float4 fs(
        RenderOut i [[stage_in]],
        constant RenderGlobals &g [[buffer(1)]],
        texture2d<float> atlas [[texture(0)]],
        texture2d<float> images [[texture(1)]]
    ) {
    #endif
        if (i.params.y > 7.5 && i.params.y < 8.5) {
            float2 screen = i.pos.xy + g.projection.xy;
            float2 p = screen - i.rect.xy;
            float4 color;
            if (i.border.y != 0.0) {
                float2 q = screen - i.border.zw;
                float c = cos(i.border.y);
                float s = sin(i.border.y);
                p = i.border.zw + float2(c * q.x + s * q.y, c * q.y - s * q.x) - i.rect.xy;
                float2 local = p - float2(0.5);
                float2 base = floor(local);
                float2 f = local - base;
                int2 t0 = int2(base);
                color = mix(
                    mix(layer_texel(t0, i.rect.zw, images), layer_texel(t0 + int2(1, 0), i.rect.zw, images), f.x),
                    mix(layer_texel(t0 + int2(0, 1), i.rect.zw, images), layer_texel(t0 + int2(1, 1), i.rect.zw, images), f.x),
                    f.y
                );
            } else if (any(p < float2(0.0)) || any(p >= i.rect.zw)) {
                discard_fragment();
            } else if (i.uv.z > 0.0) {
                float2 local = p * i.uv.zw / i.rect.zw - float2(0.5);
                int2 hi = max(int2(i.uv.zw) - int2(1), int2(0));
                float2 base = floor(local);
                float2 f = local - base;
                int2 t0 = clamp(int2(base), int2(0), hi);
                int2 t1 = clamp(int2(base) + int2(1, 1), int2(0), hi);
                color = mix(
                    mix(layer_texel(t0, i.uv.zw, images), layer_texel(int2(t1.x, t0.y), i.uv.zw, images), f.x),
                    mix(layer_texel(int2(t0.x, t1.y), i.uv.zw, images), layer_texel(t1, i.uv.zw, images), f.x),
                    f.y
                );
            } else {
                color = layer_texel(int2(floor(p)), i.rect.zw, images);
            }
            return select(color, clamp(color, float4(0.0), float4(1.0)), i.params.x == 1.0)
                * i.fill.a
                * clip_alpha(screen, i.clip, i.fade)
                * hole_alpha(screen, i.radii);
        }

        float kind = i.params.y;
        if (kind > 11.5) { discard_fragment(); }
        float2 halfSize = i.rect.zw * 0.5;
        float2 center = i.rect.xy + halfSize;
        float4 col = float4(0.0);
        float2 clip_p = i.pos.xy + g.projection.xy;

        if (kind < 0.5) {
            float d = sd_rounded(i.p - center, halfSize, i.radii);
            float soft = max(i.params.z, 0.5);
            float bw = i.params.x;
            if (bw > 0.0) {
                float4 w = i.uv;
                bool sides = w.z >= 0.0 && any(w != float4(0.0));
                float inner_d = d + bw;
                if (sides) {
                    float2 ih = max(halfSize - float2(w.y + w.w, w.x + w.z) * 0.5, float2(0.0));
                    float2 ic = center + float2(w.w - w.y, w.x - w.z) * 0.5;
                    float4 cut = float4(max(w.x, w.w), max(w.x, w.y), max(w.z, w.y), max(w.z, w.w));
                    inner_d = sd_rounded(i.p - ic, ih, sign(i.radii) * max(abs(i.radii) - cut, float4(0.0)));
                }
                col = border_over(i.fill, i.border, d, inner_d, soft, bw, i.params.w, !sides && any(i.radii != float4(0.0)));
            } else {
                col = i.fill * clamp(0.5 - d / (soft * 2.0), 0.0, 1.0);
            }
        } else if (kind < 1.5) {
            float sigma = max(i.params.z, 0.01);
            float corner = min(abs(i.radii.x), min(halfSize.x, halfSize.y));
            col = i.fill * shadow_fn(i.p - center, halfSize, sigma, corner);
            if (i.uv.z > 0.0) {
                float2 hole = i.uv.zw * 0.5;
                col = col * clamp(0.5 + sd_rounded(i.p - (i.rect.xy + i.uv.xy + hole), hole, float4(i.radii.w)), 0.0, 1.0);
            }
        } else if (kind > 6.5) {
            float d = sd_rounded(i.p - center, halfSize, i.radii);
            if (kind > 10.5) {
                float soft = max(i.params.z, 0.5);
                float cov = clamp(0.5 - d / (soft * 2.0), 0.0, 1.0);
                float t0_raw = i.params.x;
                float t1_raw = i.params.w;
                bool lower_open = t0_raw >= 1.5;
                bool upper_open = t1_raw >= 1.5;
                float t0 = select(t0_raw, t0_raw - 2.0, lower_open);
                float t1 = select(t1_raw, t1_raw - 2.0, upper_open);
                float t;
                if (i.uv.z > 0.0) {
                    t = length((i.p - i.rect.xy - i.uv.xy) / i.uv.zw);
                } else {
                    t = 0.5 + dot(i.p - center, i.uv.xy);
                }
                if ((lower_open && t < t0) || (upper_open && t >= t1)) {
                    col = float4(0.0);
                } else {
                    float u = select(clamp((t - t0) / (t1 - t0), 0.0, 1.0), select(0.0, 1.0, t >= t0), t1 <= t0 + 1e-6);
                    col = mix(i.fill, i.border, u) * cov;
                }
            } else if (kind > 9.5) {
                float soft = max(i.params.z, 0.5);
                float bw = i.params.x;
                float ring = clamp(0.5 - d / (soft * 2.0), 0.0, 1.0) - clamp(0.5 - (d + bw) / (soft * 2.0), 0.0, 1.0);
                float t = clamp((i.p.y - i.rect.y) / max(i.rect.w, 1.0), 0.0, 1.0);
                float2 arc = ring_arc(i.pos.xy + g.projection.xy - i.rect.xy, i.rect.zw, i.radii, bw);
                col = mix(i.fill, i.border, t) * (ring * dash_cov(arc.x, arc.y, i.uv.xyz));
            } else {
                float2 size = float2(images.get_width(), images.get_height());
                float2 end = i.uv.xy + i.uv.zw;
                // The UV window may be a fractional crop within a larger packed image.
                bool hasBounds = all(i.border.zw > i.border.xy);
                float2 lower = clamp(hasBounds ? i.border.xy : min(i.uv.xy, end), float2(0), size);
                float2 upper = clamp(hasBounds ? i.border.zw : max(i.uv.xy, end), float2(0), size);
                float2 lo = min(floor(lower + lower * 1.1920929e-7), size - 1.0);
                float2 hi = clamp(ceil(upper - upper * 1.1920929e-7) - 1.0, lo, size - 1.0);
                float2 coords = (i.p - i.rect.xy) / i.rect.zw;
                float2 pixel = clamp(i.uv.xy + coords * i.uv.zw - 0.5, lo, hi);
                int2 t0 = int2(floor(pixel));
                int2 t1 = min(t0 + int2(1), int2(hi));
                float2 f = fract(pixel);
                bool premultiplied = i.params.z > 0.5;
                float4 c = mix(
                    mix(image_texel(t0, premultiplied, images, g), image_texel(int2(t1.x, t0.y), premultiplied, images, g), f.x),
                    mix(image_texel(int2(t0.x, t1.y), premultiplied, images, g), image_texel(t1, premultiplied, images, g), f.x),
                    f.y
                );
                col = c * (i.fill.a * clamp(0.5 - d, 0.0, 1.0));
            }
        } else if (kind > 4.5 && kind < 5.5) {
            col = i.fill * segment_fn(i.pos.xy + g.projection.xy, i.radii.xy, i.radii.zw, i.params.x, i.params.z > 0.5);
        } else if (kind > 5.5 && kind < 6.5) {
            col = i.fill * triangle_fn(i.pos.xy + g.projection.xy, i.radii.xy, i.radii.zw, i.uv.xy, uint(i.params.x + 0.5));
        } else if (kind > 2.5) {
            if (kind < 3.5) {
                float spread = i.params.x;
                float2 ih = max(halfSize - float2(spread), float2(0.0));
                float2 q = i.p - center - i.uv.xy;
                float lit;
                if (i.params.z < 0.3) {
                    lit = box_cov(q, ih, sign(i.radii) * max(abs(i.radii) - float4(spread), float4(0.0)));
                } else {
                    lit = shadow_fn(q, ih, i.params.z, max(min(abs(i.radii.x) - spread, min(ih.x, ih.y)), 0.0));
                }
                col = i.fill * box_cov(i.p - center, halfSize, i.radii) * (1.0 - clamp(lit, 0.0, 1.0));
            } else {
                float d = sd_rounded(i.p - center, halfSize, i.radii);
                float t = clamp((i.p.y - i.rect.y) / max(i.rect.w, 1.0), 0.0, 1.0);
                float soft = max(i.params.z, 0.5);
                float bw = i.params.x;
                if (bw > 0.0) {
                    col = border_over(i.fill, mix(i.border, i.uv, t), d, d + bw, soft, bw, i.params.w, any(i.radii != float4(0.0)));
                } else {
                    col = mix(i.fill, i.uv, t) * clamp(0.5 - d / (soft * 2.0), 0.0, 1.0);
                }
            }
        } else {
            float2 screen = clip_p;
            bool rotated = i.params.x != 0.0;
            int2 atlasDims = int2(atlas.get_width(), atlas.get_height());
            int2 maxCoord = max(atlasDims - int2(1), int2(0));
            float cov;
            #ifdef RUNE_WINDFOIL
            if (i.radii.w > 0.0) {
                cov = outline_glyph(i.radii, i.border, screen, outlines, lcd_cov);
            } else if (i.radii.x > 0.5 && i.uv.z == 0.0 && !rotated) {
                cov = lcd_mask(i.rect, i.uv, screen, atlas, lcd_cov);
            } else
            #endif
            if (i.uv.z > 0.0 || rotated) {
                float2 p = select(screen, i.p, rotated);
                float2 span = select(i.rect.zw, i.uv.zw, i.uv.z > 0.0);
                float2 local = (p - i.rect.xy) * span / max(i.rect.zw, float2(1e-5)) - float2(0.5);
                int2 uv = int2(i.uv.xy + floor(local));
                float2 f = fract(local);
                float a00 = atlas.read(uint2(clamp(uv, int2(0), maxCoord))).r;
                float a10 = atlas.read(uint2(clamp(uv + int2(1, 0), int2(0), maxCoord))).r;
                float a01 = atlas.read(uint2(clamp(uv + int2(0, 1), int2(0), maxCoord))).r;
                float a11 = atlas.read(uint2(clamp(uv + int2(1, 1), int2(0), maxCoord))).r;
                cov = mix(mix(a00, a10, f.x), mix(a01, a11, f.x), f.y);
            } else {
                int2 texel = clamp(int2(i.uv.xy + floor(screen - i.rect.xy)), int2(0), maxCoord);
                cov = atlas.read(uint2(texel)).r;
            }
            if (i.params.w < 0.0) {
                col = float4(rint(cov * 255.0) / 255.0);
            } else {
                col = i.fill * pow(cov, i.params.w);
            }
        }
        float4 source = col * clip_alpha(clip_p, i.clip, i.fade);
        bool flatFill = kind == 0.0 && i.params.x == 0.0 && i.fill.a > 0.0 && i.fill.a < 1.0;
        bool grayMask = kind == 2.0 && i.radii.w == 0.0 && i.radii.x == 0.0
            && i.params.x == 0.0 && i.uv.z == 0.0 && i.params.w >= 0.0;
        if (g.flags.y > 0.5 && g.projection.z == 0.0 && (flatFill || grayMask)) {
            // Match the CPU byte blender after the fragment's coverage and clip are known.
            return rint(saturate(source) * 255.0) / 255.0;
        }
        return source;
    }
    #ifdef RUNE_WINDFOIL
    #ifdef RUNE_DUAL_SOURCE
    struct RuneDualColor {
        float4 color [[color(0), index(0)]];
        float4 blend [[color(0), index(1)]];
    };
    fragment RuneDualColor fs_windfoil(
    #else
    fragment float4 fs_windfoil(
    #endif
        RenderOut i [[stage_in]], constant RenderGlobals &g [[buffer(1)]],
        texture2d<float> atlas [[texture(0)]], texture2d<float> images [[texture(1)]],
        texture2d<uint> outlines [[texture(2)]]) {
        float4 lcd_cov = float4(0.0);
        float4 c = rune_fragment(i, g, atlas, images, outlines, lcd_cov);
        #ifdef RUNE_DUAL_SOURCE
        if (lcd_cov.w == 0.0) { return RuneDualColor{c, float4(c.a)}; }
        float e = i.params.w;
        float mean = pow((lcd_cov.r + lcd_cov.g + lcd_cov.b) / 3.0, e);
        if (mean < 1.0e-5) { return RuneDualColor{float4(0.0), float4(0.0)}; }
        float3 k = pow(lcd_cov.rgb, float3(e)) / mean;
        return RuneDualColor{float4(c.rgb * k, c.a), float4(c.a * k, c.a)};
        #else
        return c;
        #endif
    }
    #endif
    """

    internal static func windfoilMSL(dualSource: Bool) -> String {
        let defines = dualSource ? "#define RUNE_WINDFOIL 1\n#define RUNE_DUAL_SOURCE 1\n" : "#define RUNE_WINDFOIL 1\n"
        return defines + outlineMSL + "\n" + shaderMSL
    }

    /// Faithful MSL translation of `backdrop_blur.wgsl`.
    public static let backdropBlurMSL: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct BlurLevel {
        float4 w;
        float4 region;
        float4 map;
        float4 place;
    };

    struct BlurV {
        float4 pos [[position]];
        float2 uv;
    };

    vertex BlurV backdrop_blur_vs(uint vi [[vertex_id]]) {
        float2 p = float2(float((vi << 1u) & 2u), float(vi & 2u));
        BlurV o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    static inline float4 sample_clamped(texture2d<float> src, sampler smp, float2 uv, constant BlurLevel &u) {
        return src.sample(smp, clamp(uv, u.region.xy, u.region.zw), level(0.0));
    }

    fragment float4 backdrop_blur_down(
        BlurV in [[stage_in]],
        texture2d<float> src [[texture(0)]],
        sampler smp [[sampler(0)]],
        constant BlurLevel &u [[buffer(0)]]
    ) {
        float2 t = 1.0 / float2(float(src.get_width()), float(src.get_height()));
        float2 uv = in.uv * u.map.xy + u.map.zw;
        float4 a = sample_clamped(src, smp, uv + t * float2(-2.0, -2.0), u);
        float4 b = sample_clamped(src, smp, uv + t * float2(0.0, -2.0), u);
        float4 c = sample_clamped(src, smp, uv + t * float2(2.0, -2.0), u);
        float4 d = sample_clamped(src, smp, uv + t * float2(-1.0, -1.0), u);
        float4 e = sample_clamped(src, smp, uv + t * float2(1.0, -1.0), u);
        float4 f = sample_clamped(src, smp, uv + t * float2(-2.0, 0.0), u);
        float4 g = sample_clamped(src, smp, uv, u);
        float4 h = sample_clamped(src, smp, uv + t * float2(2.0, 0.0), u);
        float4 i = sample_clamped(src, smp, uv + t * float2(-1.0, 1.0), u);
        float4 j = sample_clamped(src, smp, uv + t * float2(1.0, 1.0), u);
        float4 k = sample_clamped(src, smp, uv + t * float2(-2.0, 2.0), u);
        float4 l = sample_clamped(src, smp, uv + t * float2(0.0, 2.0), u);
        float4 m = sample_clamped(src, smp, uv + t * float2(2.0, 2.0), u);
        return (d + e + i + j) * 0.125
             + (a + b + g + f) * 0.03125
             + (b + c + h + g) * 0.03125
             + (f + g + l + k) * 0.03125
             + (g + h + m + l) * 0.03125;
    }

    fragment float4 backdrop_blur_up(
        BlurV in [[stage_in]],
        texture2d<float> src [[texture(0)]],
        texture2d<float> fine [[texture(1)]],
        sampler smp [[sampler(0)]],
        constant BlurLevel &u [[buffer(0)]]
    ) {
        float2 t = 1.0 / float2(float(src.get_width()), float(src.get_height()));
        float2 uv = in.uv * u.map.xy + u.map.zw;
        float4 c = sample_clamped(src, smp, uv, u) * 4.0;
        c += (sample_clamped(src, smp, uv + float2(t.x, 0.0), u)
            + sample_clamped(src, smp, uv - float2(t.x, 0.0), u)
            + sample_clamped(src, smp, uv + float2(0.0, t.y), u)
            + sample_clamped(src, smp, uv - float2(0.0, t.y), u)) * 2.0;
        c += sample_clamped(src, smp, uv + t, u)
           + sample_clamped(src, smp, uv - t, u)
           + sample_clamped(src, smp, uv + float2(t.x, -t.y), u)
           + sample_clamped(src, smp, uv + float2(-t.x, t.y), u);
        c /= 16.0;
        float4 f = fine.sample(smp, clamp(uv, u.region.xy, u.region.zw), level(0.0));
        return mix(f, c, u.w.x);
    }
    """

    /// Faithful MSL translation of `clip.wgsl` + `backdrop_composite.wgsl`.
    public static let backdropCompositeMSL: String = """
    #include <metal_stdlib>
    using namespace metal;

    \(clipMSL)

    struct RenderGlobals {
        float2 viewport;
        float2 pad;
        float4 flags;
        float4 projection;
    };

    struct BlurLevel {
        float4 w;
        float4 region;
        float4 map;
        float4 place;
    };

    struct RenderInstanceIn {
        float4 rect;
        float4 radii;
        float4 fill;
        float4 border;
        float4 params;
        float4 uv;
        float4 clip;
        uint4 fade;
    };

    struct BCompOut {
        float4 pos [[position]];
        float2 p;
        float4 rect [[flat]];
        float4 radii [[flat]];
        float alpha [[flat]];
        float4 clip [[flat]];
        uint4 fade [[flat]];
    };

    vertex BCompOut backdrop_composite_vs(
        uint vi [[vertex_id]],
        uint iid [[instance_id]],
        constant RenderInstanceIn *instances [[buffer(0)]],
        constant RenderGlobals &g [[buffer(1)]]
    ) {
        RenderInstanceIn i = instances[iid];
        float2 corner = float2(float(vi & 1u), float(vi >> 1u));
        float2 p = i.rect.xy - float2(1.0) + corner * (i.rect.zw + float2(2.0));
        float2 size_px = select(g.viewport, g.projection.zw, g.projection.z > 0.0);
        float2 local = p - g.projection.xy;
        BCompOut o;
        o.pos = float4(local.x / size_px.x * 2.0 - 1.0, 1.0 - local.y / size_px.y * 2.0, 0.0, 1.0);
        o.p = p;
        o.rect = i.rect;
        o.radii = i.radii;
        o.alpha = i.fill.a;
        o.clip = i.clip;
        o.fade = i.fade;
        return o;
    }

    fragment float4 backdrop_composite_fs(
        BCompOut i [[stage_in]],
        texture2d<float> blurred [[texture(0)]],
        sampler smp [[sampler(0)]],
        constant BlurLevel &u [[buffer(0)]]
    ) {
        float2 halfSize = i.rect.zw * 0.5;
        float d = sd_rounded(i.p - (i.rect.xy + halfSize), halfSize, i.radii);
        float cov = clamp(0.5 - d, 0.0, 1.0) * clip_alpha(i.p, i.clip, i.fade) * i.alpha;
        float4 col = blurred.sample(smp, (i.p - u.place.xy) / u.place.zw, level(0.0));
        return col * cov;
    }
    """

    /// Faithful MSL translation of `layer_blur.wgsl` (Gaussian H/V + exact area prefilter + resample).
    public static let layerBlurMSL: String = """
    #include <metal_stdlib>
    using namespace metal;

    constant uint LBLUR_MODE [[function_constant(0)]];
    constant bool LBLUR_ADDITIVE [[function_constant(1)]];

    struct LayerBlurUniforms {
        float4 config;
        float4 mapping;
        float4 taps[128];
    };

    struct LBlurV {
        float4 pos [[position]];
    };

    vertex LBlurV layer_blur_vs(uint v [[vertex_id]]) {
        LBlurV o;
        o.pos = float4(float((v << 1u) & 2u) * 2.0 - 1.0, float(v & 2u) * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    static inline float4 bounded_load(int2 p, texture2d<float> source, constant LayerBlurUniforms &u) {
        if (any(p < int2(0)) || any(p >= int2(u.config.xy))) { return float4(0.0); }
        float4 color = source.read(uint2(p));
        return select(color, clamp(color, float4(0.0), float4(1.0)), LBLUR_ADDITIVE);
    }

    static inline float4 sample_zero(float2 p, texture2d<float> source, sampler linearSmp, constant LayerBlurUniforms &u) {
        if (LBLUR_ADDITIVE) {
            float2 q = p - 0.5;
            int2 base = int2(floor(q));
            float2 fraction = fract(q);
            float4 a = bounded_load(base, source, u);
            float4 b = bounded_load(base + int2(1, 0), source, u);
            float4 c = bounded_load(base + int2(0, 1), source, u);
            float4 d = bounded_load(base + int2(1, 1), source, u);
            return mix(mix(a, b, fraction.x), mix(c, d, fraction.x), fraction.y);
        }
        float2 edge = clamp(p + 0.5, float2(0.0), float2(1.0)) * clamp(u.config.xy + 0.5 - p, float2(0.0), float2(1.0));
        float2 dims = float2(float(source.get_width()), float(source.get_height()));
        float2 uv = clamp(p, float2(0.5), u.config.xy - 0.5) / dims;
        return source.sample(linearSmp, uv, level(0.0)) * edge.x * edge.y;
    }

    fragment float4 layer_blur_fs(
        float4 p [[position]],
        texture2d<float> source [[texture(0)]],
        sampler linearSmp [[sampler(0)]],
        constant LayerBlurUniforms &u [[buffer(0)]]
    ) {
        if (LBLUR_MODE == 2u) {
            float2 lo = (p.xy - 0.5) * u.mapping.xy;
            float2 hi = (p.xy + 0.5) * u.mapping.xy;
            float4 sum = float4(0.0);
            int y0 = int(floor(lo.y));
            int y1 = int(ceil(hi.y));
            int x0 = int(floor(lo.x));
            int x1 = int(ceil(hi.x));
            for (int y = y0; y < y1; y++) {
                float wy = max(0.0, min(hi.y, float(y + 1)) - max(lo.y, float(y)));
                for (int x = x0; x < x1; x++) {
                    float wx = max(0.0, min(hi.x, float(x + 1)) - max(lo.x, float(x)));
                    sum += bounded_load(int2(x, y), source, u) * wx * wy;
                }
            }
            return sum / (u.mapping.x * u.mapping.y);
        }
        if (LBLUR_MODE == 3u) {
            return sample_zero(p.xy * u.mapping.xy, source, linearSmp, u);
        }
        float2 axis = select(float2(1.0, 0.0), float2(0.0, 1.0), u.config.z > 0.5);
        float4 color = sample_zero(p.xy, source, linearSmp, u) * u.taps[0].y;
        uint count = uint(u.config.w);
        for (uint tap = 1u; tap < count; tap++) {
            float2 offset = axis * u.taps[tap].x;
            color += (sample_zero(p.xy + offset, source, linearSmp, u) + sample_zero(p.xy - offset, source, linearSmp, u)) * u.taps[tap].y;
        }
        return color;
    }
    """

    /// Faithful MSL translation of `outline.wgsl` (Windfoil closed-form box filter, Slug rays, hinting, LCD RGB).
    public static let outlineMSL: String = """
    #include <metal_stdlib>
    using namespace metal;

    constant float OUTLINE_HINT_REACH = 1.5;
    constant bool OUTLINE_SUBPIXEL [[function_constant(0)]];

    static inline uint4 outline_texel(uint i, texture2d<uint> outlines) {
        return outlines.read(uint2(i & 1023u, i >> 10u));
    }

    static inline float2 outline_move(uint code) {
        return float2(float(code & 3u) - 1.0, float((code >> 2u) & 3u));
    }

    static inline float outline_hint(float y, float4 a, float4 b, float4 c) {
        if (y < a.y) { return y; }
        if (y <= a.z) { return (y - a.y) * c.x + a.y; }
        if (y <= b.x) { return (y - a.z) * c.y + a.w; }
        if (y <= b.z) { return y + (b.y - b.x); }
        return (y - b.z) * c.z + b.w;
    }

    static inline float outline_inside(float2 a2, float2 a1, float x0, float ta, float tb, float hx) {
        if (tb <= ta) { return 0.0; }
        float tm = 0.5 * (ta + tb);
        float d = 0.5 * (tb - ta);
        float x_mid = (a2.x * tm + a1.x) * tm + x0 + hx;
        float2 dmid = 2.0 * a2 * tm + a1;
        return 2.0 * d * x_mid * dmid.y + (2.0 * d * d * d / 3.0) * (a2.x * dmid.y + 2.0 * a2.y * dmid.x);
    }

    static inline float outline_integrate(float2 q1, float2 q2, float2 q3, float lo, float hi, float hx) {
        float2 a2 = q1 - 2.0 * q2 + q3;
        float2 a1 = 2.0 * (q2 - q1);
        bool y_rising = q3.y >= q1.y;
        bool x_rising = q3.x >= q1.x;
        float4 A2 = a2.yyxx;
        float4 A1 = a1.yyxx;
        float4 V = float4(select(float2(hi, lo), float2(lo, hi), y_rising), -hx, hx);
        bool4 R = bool4(y_rising, y_rising, x_rising, x_rising);
        float4 SG = select(float4(-1.0), float4(1.0), R);
        float4 C = q1.yyxx - V;
        bool4 sat0 = (C * SG) >= float4(0.0);
        bool4 sat1 = ((q3.yyxx - V) * SG) <= float4(0.0);
        float4 disc = max(A1 * A1 - 4.0 * A2 * C, float4(0.0));
        float4 sq = sqrt(disc);
        float4 qq = -0.5 * (A1 + select(-sq, sq, A1 >= float4(0.0)));
        bool4 use_r1 = (A1 < float4(0.0)) == R;
        float4 num = select(C, qq, use_r1);
        float4 den = select(qq, A2, use_r1);
        bool4 valid = den != float4(0.0);
        float4 t_raw = clamp(select(float4(0.0), num / select(float4(1.0), den, valid), valid), float4(0.0), float4(1.0));
        float4 T = select(select(t_raw, float4(1.0), sat1), float4(0.0), sat0);
        if (T.y <= T.x) { return 0.0; }
        float2 tc = clamp(T.zw, T.xx, T.yy);
        float t1 = select(tc.y, tc.x, x_rising);
        float t2 = max(select(tc.x, tc.y, x_rising), t1);
        float acc = outline_inside(a2, a1, q1.x, t1, t2, hx);
        float2 rab = select(float2(T.x, t1), float2(t2, T.y), x_rising);
        float d = max(rab.y - rab.x, 0.0);
        float tm = 0.5 * (rab.x + rab.y);
        acc = acc + d * (2.0 * a2.y * tm + a1.y) * (2.0 * hx);
        return acc;
    }

    static inline float outline_coverage(uint rec, uint hint, float2 local, float scale, float r, float hw, float hx, texture2d<uint> outlines) {
        uint4 head = outline_texel(rec, outlines);
        uint count = head.y;
        float y0 = as_type<float>(head.z);
        float inv_h = as_type<float>(head.w);
        bool hinted = hint != 0u;
        float4 ha = float4(0.0), hb = float4(0.0), hc = float4(0.0);
        if (hinted) {
            ha = as_type<float4>(outline_texel(hint, outlines));
            hb = as_type<float4>(outline_texel(hint + 1u, outlines));
            hc = as_type<float4>(outline_texel(hint + 2u, outlines));
        }
        float reach = select(0.0, OUTLINE_HINT_REACH, hinted);
        uint b0 = 0u, b1 = 0u;
        if (count > 1u) {
            float last = float(count - 1u);
            b0 = uint(clamp(floor(((local.y - hw - 2.0 * r - reach) / scale - y0) * inv_h), 0.0, last));
            b1 = uint(clamp(floor(((local.y + hw + reach) / scale - y0) * inv_h), 0.0, last));
        }
        float acc = 0.0;
        for (uint band = b0; band <= b1; band = band + 1u) {
            float e0 = -3.0e38;
            float e1 = 3.0e38;
            if (count > 1u) {
                e0 = (y0 + float(band) / inv_h) * scale;
                e1 = (y0 + float(band + 1u) / inv_h) * scale;
            }
            uint4 entry = outline_texel(head.x + band, outlines);
            bool sorted = entry.y > 4u;
            for (uint k = 0u; k < entry.y; k = k + 1u) {
                uint4 t0 = outline_texel(entry.x + 2u * k, outlines);
                uint4 t1 = outline_texel(entry.x + 2u * k + 1u, outlines);
                if (as_type<float>(t1.w) * scale + r - local.x <= -hx) {
                    if (sorted) { break; }
                    continue;
                }
                uint code = t1.z;
                float2 oa = outline_move(code & 15u) * r;
                float2 ob = outline_move((code >> 4u) & 15u) * r;
                float2 p0 = as_type<float2>(t0.xy) * scale + oa;
                float2 p1 = as_type<float2>(t0.zw) * scale + oa;
                float2 p2 = as_type<float2>(t1.xy) * scale + ob;
                float wlo = -hw;
                float whi = hw;
                float be0 = e0 + oa.y;
                float be1 = e1 + oa.y;
                if (hinted) {
                    p0.y = outline_hint(p0.y, ha, hb, hc);
                    p1.y = outline_hint(p1.y, ha, hb, hc);
                    p2.y = outline_hint(p2.y, ha, hb, hc);
                    be0 = outline_hint(be0, ha, hb, hc);
                    be1 = outline_hint(be1, ha, hb, hc);
                }
                if ((code & 256u) != 0u) {
                    p1 = (p0 + p2) * 0.5;
                } else {
                    wlo = max(wlo, be0 - local.y);
                    whi = min(whi, be1 - local.y);
                }
                float2 q1 = p0 - local;
                float2 q3 = p2 - local;
                float lo = max(wlo, min(q1.y, q3.y));
                float hi = min(whi, max(q1.y, q3.y));
                if (hi <= lo || max(q1.x, q3.x) <= -hx) { continue; }
                if (min(q1.x, q3.x) >= hx) {
                    acc = acc + 2.0 * hx * (clamp(q3.y, wlo, whi) - clamp(q1.y, wlo, whi));
                    continue;
                }
                acc = acc + outline_integrate(q1, p1 - local, q3, lo, hi, hx);
            }
        }
        return min(abs(acc) / (4.0 * hx * hw), 1.0);
    }

    static inline float outline_root(float p0, float p1, float p2, float c) {
        float a2 = p0 - 2.0 * p1 + p2;
        float a1 = 2.0 * (p1 - p0);
        float a0 = p0 - c;
        if (abs(a2) < 1.0e-6) {
            return clamp(-a0 / select(a1, 1.0e-6, abs(a1) < 1.0e-6), 0.0, 1.0);
        }
        float sq = sqrt(max(a1 * a1 - 4.0 * a2 * a0, 0.0));
        float t0 = (-a1 - sq) / (2.0 * a2);
        float t1 = (-a1 + sq) / (2.0 * a2);
        return clamp(select(t1, t0, t0 >= -1.0e-4 && t0 <= 1.0 + 1.0e-4), 0.0, 1.0);
    }

    static inline float outline_slug(uint rec, uint hint, float2 local, float scale, float r, float hw, texture2d<uint> outlines) {
        uint4 head = outline_texel(rec, outlines);
        uint count = head.y;
        float y0 = as_type<float>(head.z);
        float inv_h = as_type<float>(head.w);
        bool hinted = hint != 0u;
        float4 ha = float4(0.0), hb = float4(0.0), hc = float4(0.0);
        if (hinted) {
            ha = as_type<float4>(outline_texel(hint, outlines));
            hb = as_type<float4>(outline_texel(hint + 1u, outlines));
            hc = as_type<float4>(outline_texel(hint + 2u, outlines));
        }
        float reach = select(0.0, OUTLINE_HINT_REACH, hinted);
        uint b0 = 0u, b1 = 0u;
        if (count > 1u) {
            float last = float(count - 1u);
            b0 = uint(clamp(floor(((local.y - hw - 2.0 * r - reach) / scale - y0) * inv_h), 0.0, last));
            b1 = uint(clamp(floor(((local.y + hw + reach) / scale - y0) * inv_h), 0.0, last));
        }
        float across = 0.0, winding = 0.0, down = 0.0;
        for (uint band = b0; band <= b1; band = band + 1u) {
            float e0 = -3.0e38, e1 = 3.0e38;
            if (count > 1u) {
                e0 = (y0 + float(band) / inv_h) * scale;
                e1 = (y0 + float(band + 1u) / inv_h) * scale;
            }
            uint4 entry = outline_texel(head.x + band, outlines);
            for (uint k = 0u; k < entry.y; k = k + 1u) {
                uint4 t0 = outline_texel(entry.x + 2u * k, outlines);
                uint4 t1 = outline_texel(entry.x + 2u * k + 1u, outlines);
                uint code = t1.z;
                float2 oa = outline_move(code & 15u) * r;
                float2 ob = outline_move((code >> 4u) & 15u) * r;
                float2 p0 = as_type<float2>(t0.xy) * scale + oa;
                float2 p1 = as_type<float2>(t0.zw) * scale + oa;
                float2 p2 = as_type<float2>(t1.xy) * scale + ob;
                float be0 = e0 + oa.y, be1 = e1 + oa.y;
                if (hinted) {
                    p0.y = outline_hint(p0.y, ha, hb, hc);
                    p1.y = outline_hint(p1.y, ha, hb, hc);
                    p2.y = outline_hint(p2.y, ha, hb, hc);
                    be0 = outline_hint(be0, ha, hb, hc);
                    be1 = outline_hint(be1, ha, hb, hc);
                }
                if ((code & 256u) != 0u) {
                    p1 = (p0 + p2) * 0.5;
                    be0 = -3.0e38;
                    be1 = 3.0e38;
                }
                float2 q0 = p0 - local, q1 = p1 - local, q2 = p2 - local;
                float ylo = max(min(q0.y, q2.y), be0 - local.y);
                float yhi = min(max(q0.y, q2.y), be1 - local.y);
                if (q0.y != q2.y && ylo <= 0.0 && 0.0 < yhi) {
                    float t = outline_root(q0.y, q1.y, q2.y, 0.0);
                    float x = mix(mix(q0.x, q1.x, t), mix(q1.x, q2.x, t), t);
                    float s = sign(q2.y - q0.y);
                    across = across + s * clamp(x / (2.0 * hw) + 0.5, 0.0, 1.0);
                    winding = winding + s * select(0.0, 1.0, x > 0.0);
                }
                if (q0.x != q2.x && min(q0.x, q2.x) <= 0.0 && 0.0 < max(q0.x, q2.x)) {
                    float t = outline_root(q0.x, q1.x, q2.x, 0.0);
                    float y = mix(mix(q0.y, q1.y, t), mix(q1.y, q2.y, t), t);
                    if (abs(y) < hw && y >= be0 - local.y && y < be1 - local.y) {
                        down = down - sign(q2.x - q0.x) * (clamp(y / (2.0 * hw) + 0.5, 0.0, 1.0) - select(0.0, 1.0, y > 0.0));
                    }
                }
            }
        }
        return 0.5 * (min(abs(across), 1.0) + min(abs(winding + down), 1.0));
    }

    static inline float outline_rgb(uint rec, uint hint, float2 local, float scale, float r, float hw, texture2d<uint> outlines, thread float4 &lcd_cov) {
        float2 third = float2(2.0 * hw / 3.0, 0.0);
        float3 c = float3(
            outline_coverage(rec, hint, local - third, scale, r, hw, hw, outlines),
            outline_coverage(rec, hint, local, scale, r, hw, hw, outlines),
            outline_coverage(rec, hint, local + third, scale, r, hw, hw, outlines)
        );
        lcd_cov = float4(c, 1.0);
        return (c.x + c.y + c.z) / 3.0;
    }

    // A native shaping cluster can contain multiple overlapping glyphs. Its resting R8 tile
    // uses the same per-glyph byte rounding and source-over as the native mask compositor.
    static inline float outline_tile(uint rec, float2 p, texture2d<uint> outlines) {
        uint count = min(outline_texel(rec, outlines).x, 64u);
        uint dest = 0u;
        for (uint i = 0u; i < count && dest < 255u; ++i) {
            uint base = rec + 1u + 3u * i;
            uint4 bounds = outline_texel(base, outlines);
            float2 lo = float2(bounds.xy);
            if (any(p < lo) || any(p >= lo + float2(bounds.zw))) { continue; }
            float4 placement = as_type<float4>(outline_texel(base + 1u, outlines));
            uint4 glyph = outline_texel(base + 2u, outlines);
            float2 local = float2(p.x - placement.x, placement.y - p.y);
            float coverage = glyph.z == 1u
                ? outline_slug(glyph.x, glyph.y, local, placement.z, placement.w, 0.5, outlines)
                : outline_coverage(glyph.x, glyph.y, local, placement.z, placement.w, 0.5, 0.5, outlines);
            uint a = uint(rint(saturate(coverage) * 255.0));
            dest = a + (dest * (255u - a) + 127u) / 255u;
        }
        return float(dest) / 255.0;
    }

    static inline float outline_glyph(float4 radii, float4 border, float2 screen, texture2d<uint> outlines, thread float4 &lcd_cov) {
        float z = radii.w;
        uint rec = uint(border.x);
        uint hint = uint(border.y);
        float hw = 0.5 / z;
        uint mode = uint(border.w + 0.5);
        if (mode == 4u) { return outline_tile(rec, screen - radii.xy, outlines); }
        float across = select(1.0, 3.0, mode == 3u);
        float2 local = float2((screen.x - radii.x) / across, radii.y - screen.y) / z;
        if (mode == 1u) { return outline_slug(rec, hint, local, radii.z, border.z, hw, outlines); }
        if (mode == 2u && OUTLINE_SUBPIXEL) { return outline_rgb(rec, hint, local, radii.z, border.z, hw, outlines, lcd_cov); }
        return outline_coverage(rec, hint, local, radii.z, border.z, hw, hw, outlines);
    }

    static inline float lcd_mask(float4 rect, float4 uv, float2 screen, texture2d<float> atlas, thread float4 &lcd_cov) {
        float2 p = floor(screen - rect.xy);
        int2 t = int2(uv.xy) + int2(int(p.x) * 3, int(p.y));
        int2 dims = int2(atlas.get_width(), atlas.get_height());
        int2 maxCoord = max(dims - int2(1), int2(0));
        float3 c = float3(
            atlas.read(uint2(clamp(t, int2(0), maxCoord))).r,
            atlas.read(uint2(clamp(t + int2(1, 0), int2(0), maxCoord))).r,
            atlas.read(uint2(clamp(t + int2(2, 0), int2(0), maxCoord))).r
        );
        lcd_cov = float4(c, 1.0);
        return (c.x + c.y + c.z) / 3.0;
    }
    """
}
