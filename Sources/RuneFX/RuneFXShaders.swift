import Foundation

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
        return float(pcg(uint(c.x) ^ pcg(uint(c.y) ^ pcg(seed))) >> 8u) * (1.0 / 16777216.0);
    }

    inline float2 grad2(int2 c, uint seed) {
        float a = hcell(c, seed) * 6.28318530718;
        return float2(cos(a), sin(a));
    }

    inline float gnoise(float2 p, uint seed) {
        int2 i = int2(floor(p));
        float2 f = fract(p);
        float a = dot(grad2(i + int2(0, 0), seed), f - float2(0.0, 0.0));
        float b = dot(grad2(i + int2(1, 0), seed), f - float2(1.0, 0.0));
        float c = dot(grad2(i + int2(0, 1), seed), f - float2(0.0, 1.0));
        float d = dot(grad2(i + int2(1, 1), seed), f - float2(1.0, 1.0));
        float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.41421;
    }

    inline float fbm(float2 p, uint seed, int octaves) {
        float s = 0.0;
        float a = 0.5;
        float norm = 0.0;
        for (int o = 0; o < octaves; o++) {
            s += a * gnoise(p, seed + uint(o) * 131u);
            norm += a;
            p = float2(0.8 * p.x - 0.6 * p.y, 0.6 * p.x + 0.8 * p.y) * 2.02;
            a *= 0.5;
        }
        return s / max(norm, 1e-4);
    }

    inline float sd_rrect(float2 p, float2 half_size, float r) {
        float rr = min(r, min(half_size.x, half_size.y));
        float2 q = abs(p) - half_size + rr;
        return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - rr;
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

    inline float clip_alpha(Inst i, float2 px) {
        float2 d0 = px - i.clip.xy;
        float2 d1 = i.clip.zw - px;
        float m = min(min(d0.x, d0.y), min(d1.x, d1.y));
        return smoothstep(-0.5, 0.5, m);
    }

    inline float blend_overlay_ch(float b, float s) {
        return b <= 0.5 ? 2.0 * b * s : 1.0 - 2.0 * (1.0 - b) * (1.0 - s);
    }

    inline float3 blend_overlay(float3 b, float3 s) {
        return float3(blend_overlay_ch(b.r, s.r), blend_overlay_ch(b.g, s.g), blend_overlay_ch(b.b, s.b));
    }

    inline float blend_soft_light_ch(float b, float s) {
        if (s <= 0.5) {
            return b - (1.0 - 2.0 * s) * b * (1.0 - b);
        }
        float d = b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(max(b, 0.0));
        return b + (2.0 * s - 1.0) * (d - b);
    }

    inline float3 blend_soft_light(float3 b, float3 s) {
        return float3(blend_soft_light_ch(b.r, s.r), blend_soft_light_ch(b.g, s.g), blend_soft_light_ch(b.b, s.b));
    }

    inline float4 finish(float4 c, Inst i, float2 px, constant Globals& g) {
        c *= i.shape.z * clip_alpha(i, px);
        if (g.srgb > 0.5) {
            float a = clamp(c.a, 0.0, 1.0);
            float3 straight = a > 1e-6 ? c.rgb / a : float3(0.0);
            c = float4(to_srgb(straight) * a, a);
        }
        if (g.dither > 0.5) {
            uint2 ip = uint2(px);
            float n = u01(hu(ip.x, ip.y)) - u01(hu(ip.x + 17u, ip.y + 31u));
            c.rgb += n / 255.0;
        }
        return c;
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
    fragment float4 fx_glow_fragment(
        VOut in [[stage_in]],
        constant Globals& g [[buffer(0)]],
        const device Inst* insts [[buffer(1)]],
        texture2d<float> source [[texture(1)]],
        sampler samp [[sampler(0)]]
    ) {
        Inst i = insts[in.id];
        float2 px = recover_pixel(in);
        float2 p = px / i.shape.y;
        float d = sd_shape(i, p);
        float radius = max(i.p0.x, 0.5);
        float intensity = i.p0.y;
        float inner = i.p0.z;
        float occ = i.p0.w;
        float breathe = i.p1.x;
        float period = max(i.p1.y, 0.1);
        float heat = i.p1.z;
        float hot = i.p1.w;

        float b = 1.0 + breathe * 0.22 * sin(6.28318530718 * i.t.x / period);
        float r_eff = radius * b;
        float inside_mask = mix(1.0, smoothstep(0.0, 1.5, d) + inner * (1.0 - smoothstep(0.0, 1.5, d)), occ);

        float3 col = float3(0.0);
        float alpha = 0.0;
        int variant = int(round(i.t.z));

        if (variant == 0) {
            float falloff = exp(-max(d, 0.0) / r_eff) * (1.0 - smoothstep(r_eff * 3.0, r_eff * i.p2.z, max(d, 0.0)));
            float in_fill = d < 0.0 ? inner * exp(d / r_eff) : 0.0;
            float e = (falloff + in_fill) * intensity * heat * inside_mask;
            col = mix(i.c0.rgb, i.c1.rgb, clamp(e * hot, 0.0, 1.0)) * e;
            alpha = clamp(e * 0.65, 0.0, 1.0);
        } else if (variant == 1) {
            float rim_w = max(i.p2.y, 0.2);
            float core_line = exp(-pow(abs(d) / rim_w, 2.0));
            float halo = exp(-abs(d) / r_eff) * 0.7;
            float e = (core_line * 1.4 + halo) * intensity * heat * inside_mask;
            col = i.c0.rgb * (halo * intensity * heat) + i.c1.rgb * (core_line * intensity * heat * 1.5);
            alpha = clamp(e * 0.75, 0.0, 1.0);
        } else if (variant == 2) {
            float2 c = i.rect.xy + i.rect.zw * 0.5;
            float ang = atan2(p.y - c.y, p.x - c.x) + i.t.x * i.p2.x * 6.28318530718;
            float u = fract(ang / 6.28318530718);
            float3 pal = u < 0.3333 ? mix(i.c0.rgb, i.c1.rgb, u * 3.0)
                : (u < 0.6667 ? mix(i.c1.rgb, i.c2.rgb, (u - 0.3333) * 3.0) : mix(i.c2.rgb, i.c0.rgb, (u - 0.6667) * 3.0));
            float rim = exp(-pow(abs(d) / max(i.p2.y, 0.3), 2.0)) + exp(-max(d, 0.0) / r_eff) * 0.6;
            float e = rim * intensity * heat * inside_mask;
            col = pal * e;
            alpha = clamp(e * 0.7, 0.0, 1.0);
        } else {
            float2 uv = (p - i.aux2.xy) / max(i.aux2.zw, float2(1.0));
            float m = source.sample(samp, uv, level(2.0)).a;
            float e = m * intensity * heat;
            col = mix(i.c0.rgb, i.c1.rgb, clamp(m * hot, 0.0, 1.0)) * e;
            alpha = clamp(e, 0.0, 1.0);
        }

        return finish(float4(col, alpha), i, px, g);
    }
    """

    public static let pulseShader: String = commonPrelude + """
    fragment float4 fx_pulse_fragment(
        VOut in [[stage_in]],
        constant Globals& g [[buffer(0)]],
        const device Inst* insts [[buffer(1)]]
    ) {
        Inst i = insts[in.id];
        float2 px = recover_pixel(in);
        float2 p = px / i.shape.y;
        float d = sd_shape(i, p);
        int count = max(int(round(i.p0.x)), 1);
        float period = max(i.p0.y, 0.05);
        float reach = max(i.p0.z, 1.0);
        float width = max(i.p0.w, 0.2);
        float intensity = i.p1.x;
        float t0 = i.p1.y;
        float duration = max(i.p1.z, 0.05);
        float rep = i.p1.w;
        float occ = i.p2.w;
        int variant = int(round(i.t.z));

        float3 col = float3(0.0);
        float alpha = 0.0;
        float inside_mask = mix(1.0, smoothstep(-1.0, 1.0, d), occ);

        if (variant == 0) {
            for (int k = 0; k < count; k++) {
                float phase = fract(i.t.x / period + float(k) / float(count));
                float r = phase * reach;
                float ring = exp(-pow((d - r) / width, 2.0));
                float fade = (1.0 - phase) * (1.0 - phase) * smoothstep(0.0, 0.08, phase);
                float e = ring * fade * intensity * inside_mask;
                col += mix(i.c0.rgb, i.c1.rgb, ring * 0.5) * e;
                alpha += e * 0.7;
            }
        } else if (variant == 1) {
            float b = 0.5 + 0.5 * sin(6.28318530718 * i.t.x / period);
            float r = reach * (0.4 + 0.6 * b);
            float e = exp(-max(d, 0.0) / max(r, 1.0)) * (0.4 + 0.6 * b) * intensity * inside_mask;
            col = mix(i.c0.rgb, i.c1.rgb, b * 0.4) * e;
            alpha = clamp(e * 0.65, 0.0, 1.0);
        } else if (variant == 2) {
            float ph = fract(i.t.x / period);
            float beat1 = exp(-pow((ph - 0.12) / 0.05, 2.0));
            float beat2 = 0.7 * exp(-pow((ph - 0.28) / 0.06, 2.0));
            float pulse = beat1 + beat2;
            float ring = exp(-pow((d - ph * reach) / max(width * 2.0, 1.0), 2.0)) * (1.0 - ph);
            float e = (pulse * exp(-max(d, 0.0) / max(reach * 0.4, 2.0)) + ring) * intensity * inside_mask;
            col = mix(i.c0.rgb, i.c1.rgb, clamp(pulse, 0.0, 1.0)) * e;
            alpha = clamp(e * 0.75, 0.0, 1.0);
        } else if (variant == 3) {
            float age = rep > 0.0 ? fmod(max(i.t.x - t0, 0.0), rep) : (i.t.x - t0);
            float u = clamp(age / duration, 0.0, 2.2);
            if (u >= 0.0 && u <= 2.2) {
                float travel = i.p2.x;
                float2 from = i.aux.xy;
                float2 dir = i.aux.zw;
                float prog = clamp(u, 0.0, 1.0);
                float ease = 1.0 - pow(1.0 - prog, 3.0);
                float2 head = from + dir * (travel * ease);
                float hd = length(p - head);
                float head_r = max(i.p2.z, 0.5);
                float cool = u > 1.0 ? exp(-(u - 1.0) * 3.0) : 1.0;
                float e = exp(-hd / (head_r * 2.5)) * cool * intensity;
                col = mix(i.c0.rgb, i.c1.rgb, exp(-hd / head_r)) * e;
                alpha = clamp(e, 0.0, 1.0);
            }
        } else {
            float age = i.t.x - t0;
            float u = clamp(age / duration, 0.0, 1.0);
            float2 at = i.aux.xy;
            float r = u * reach;
            float dist = length(p - at);
            float ring = exp(-pow((dist - r) / max(width * 3.0, 1.0), 2.0));
            float mask = 1.0 - smoothstep(-0.5, 0.5, d);
            float e = ring * (1.0 - u) * mask * intensity;
            col = mix(i.c0.rgb, i.c1.rgb, ring * 0.6) * e;
            alpha = clamp(e, 0.0, 1.0);
        }

        return finish(float4(col, clamp(alpha, 0.0, 1.0)), i, px, g);
    }
    """

    public static let electricShader: String = commonPrelude + """
    fragment float4 fx_electric_fragment(
        VOut in [[stage_in]],
        constant Globals& g [[buffer(0)]],
        const device Inst* insts [[buffer(1)]],
        const device float4* data [[buffer(2)]]
    ) {
        Inst i = insts[in.id];
        float2 px = recover_pixel(in);
        float2 p = px / i.shape.y;
        uint base = uint(i.xf.x);
        uint n = max(uint(i.xf.y), 1u);
        uint strands = max(uint(i.xf.w), 1u);
        float4 bright = data[base + 1u];

        float core_w = max(i.p0.w, 0.2);
        float intensity = i.p1.x;
        float glow_w = max(i.p1.y, 0.5);
        float occ = i.p2.w;
        int variant = int(round(i.t.z));

        float dist = 1e5;
        float halo_dist = 1e5;
        float strand_k = bright.x;

        if (variant == 0) {
            float2 a = i.aux.xy;
            float2 b = i.aux.zw;
            float2 ab = b - a;
            float len = max(length(ab), 1.0);
            float2 dir = ab / len;
            float2 nrm = float2(-dir.y, dir.x);
            float u = clamp(dot(p - a, dir) / len, 0.0, 1.0);
            float lat = dot(p - a, nrm);
            uint idx = min(uint(u * float(n - 1u)), n - 1u);
            uint stride_v4 = (n + 3u) >> 2u;
            uint path_base = base + 2u;
            uint halo_base = path_base + strands * stride_v4;
            for (uint s = 0u; s < strands; s++) {
                float off = dat1(data, path_base + s * stride_v4, idx);
                float hoff = dat1(data, halo_base + s * stride_v4, idx);
                dist = min(dist, abs(lat - off));
                halo_dist = min(halo_dist, abs(lat - hoff));
            }
        } else {
            float d = sd_shape(i, p) - i.p2.y;
            float2 c = i.rect.xy + i.rect.zw * 0.5;
            float ang = atan2(p.y - c.y, p.x - c.x);
            float u = fract(ang / 6.28318530718);
            uint idx = min(uint(u * float(n)), n - 1u);
            uint stride_v4 = (n + 3u) >> 2u;
            uint path_base = base + 2u;
            uint halo_base = path_base + strands * stride_v4;
            for (uint s = 0u; s < strands; s++) {
                float off = dat1(data, path_base + s * stride_v4, idx);
                float hoff = dat1(data, halo_base + s * stride_v4, idx);
                dist = min(dist, abs(d - off));
                halo_dist = min(halo_dist, abs(d - hoff));
            }
        }

        float core_e = exp(-pow(dist / core_w, 2.0));
        float halo_e = exp(-halo_dist / glow_w) * 0.65;
        float inside = mix(1.0, smoothstep(-1.0, 1.5, sd_shape(i, p)), occ);
        float e = (core_e * 1.4 + halo_e) * intensity * strand_k * inside;
        float3 col = mix(i.c2.rgb, i.c0.rgb, clamp(halo_e * 1.5, 0.0, 1.0)) * halo_e * intensity * strand_k
                   + i.c1.rgb * core_e * intensity * strand_k * 1.4;
        return finish(float4(col * inside, clamp(e * 0.8, 0.0, 1.0)), i, px, g);
    }
    """

    public static let fireShader: String = commonPrelude + """
    fragment float4 fx_fire_fragment(
        VOut in [[stage_in]],
        constant Globals& g [[buffer(0)]],
        const device Inst* insts [[buffer(1)]],
        const device float4* data [[buffer(2)]]
    ) {
        Inst i = insts[in.id];
        float2 px = recover_pixel(in);
        float2 p = px / i.shape.y;
        float h = max(i.p0.x, 4.0);
        float sc = max(i.p0.y, 2.0);
        float speed = i.p0.z;
        float intensity = i.p0.w;
        float warp = i.p2.x;
        float base_glow = i.p2.z;
        float occ = i.p2.w;
        float swirl = i.p3.x;
        uint seed = uint(i.t.y);
        float tm = i.t.x * speed;

        float d = sd_shape(i, p);
        float3 col = float3(0.0);
        float alpha = 0.0;
        int variant = int(round(i.t.z));

        if (variant != 3) {
            float y_up = variant == 1 ? max(d, 0.0) : max(i.rect.y - p.y, 0.0);
            float u = clamp(y_up / h, 0.0, 1.0);
            float2 np = p / sc + float2(swirl * sin(u * 3.14159 + tm), tm * 1.3);
            float n1 = fbm(np, seed, 4);
            float n2 = fbm(np * 1.7 + float2(n1 * warp, tm * 0.8), seed + 37u, 3);
            float flame = clamp((1.0 - u) * 1.15 + n2 * 0.55 - 0.15, 0.0, 1.0);
            float mask = variant == 1
                ? smoothstep(h, 0.0, max(d, 0.0))
                : smoothstep(-6.0, 0.0, p.x - i.rect.x) * smoothstep(-6.0, 0.0, (i.rect.x + i.rect.z) - p.x) * (1.0 - smoothstep(h * 0.7, h * 1.25, y_up));
            float t_col = clamp(flame * mask + base_glow * exp(-max(d, 0.0) / 10.0) * 0.4, 0.0, 1.0);
            float3 fc = t_col < 0.5 ? mix(i.c0.rgb, i.c1.rgb, t_col * 2.0) : mix(i.c1.rgb, i.c2.rgb, (t_col - 0.5) * 2.0);
            float inside = mix(1.0, smoothstep(-1.0, 1.5, d), occ);
            float e = t_col * intensity * inside;
            col = fc * e;
            alpha = clamp(e, 0.0, 1.0);
        }

        uint e_base = uint(i.xf.x);
        uint e_count = uint(i.xf.y);
        for (uint k = 0u; k < e_count; k++) {
            float4 ep = data[e_base + k * 2u];
            float4 es = data[e_base + k * 2u + 1u];
            float2 pos = ep.xy;
            float2 vel = ep.zw;
            float sz = max(es.x, 0.25);
            float temp = es.y;
            float2 diff = p - pos;
            float vlen = max(length(vel), 1e-4);
            float2 vdir = vel / vlen;
            float along = dot(diff, vdir);
            float perp = length(diff - vdir * along);
            float streak = clamp(along / max(vlen, sz), -1.0, 0.0);
            float ed = length(float2(perp, max(along, 0.0) + max(-along - vlen, 0.0)));
            float g_e = exp(-pow(ed / sz, 2.0)) * temp * intensity;
            float3 ec = mix(i.c1.rgb, i.c2.rgb, clamp(temp, 0.0, 1.0));
            col += ec * g_e * (1.0 + 0.3 * abs(streak));
            alpha = max(alpha, clamp(g_e, 0.0, 1.0));
        }

        return finish(float4(col, alpha), i, px, g);
    }
    """

    public static let distortShader: String = commonPrelude + """
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
        float scale = i.shape.y;
        float2 p = px / scale;
        int variant = int(round(i.t.z));

        if (variant == 0) {
            float h = max(i.p0.x, 1.0);
            float sc = max(i.p0.y, 1.0);
            float spd = i.p0.z;
            float amt = i.p0.w;
            uint seed = uint(i.t.y);
            float2 np = p / sc + float2(0.0, i.t.x * spd);
            float2 off = float2(fbm(np, seed, 3), fbm(np + float2(7.3, 2.1), seed + 19u, 3)) * amt;
            float d = sd_shape(i, p);
            float mask = i.p1.x > 0.5 ? (1.0 - smoothstep(-1.0, 1.0, d)) : smoothstep(h, 0.0, max(i.rect.y - p.y, 0.0));
            float4 c = bd(p + off * mask, scale, g, backdrop, samp, enc);
            return finish(float4(c.rgb * mask, mask), i, px, g);
        } else if (variant == 1) {
            float2 at = i.aux.xy;
            float reach = max(i.p0.x, 1.0);
            float width = max(i.p0.y, 0.5);
            float amt = i.p0.z;
            float chroma = i.p0.w;
            float u = clamp((i.t.x - i.p1.x) / max(i.p1.y, 0.05), 0.0, 1.0);
            float2 diff = p - at;
            float dist = max(length(diff), 1e-3);
            float2 dir = diff / dist;
            float r = u * reach;
            float ring = exp(-pow((dist - r) / width, 2.0)) * (1.0 - u);
            float2 off = dir * (ring * amt);
            float cr = bd(p + off * (1.0 + chroma), scale, g, backdrop, samp, enc).r;
            float cg = bd(p + off, scale, g, backdrop, samp, enc).g;
            float cb = bd(p + off * (1.0 - chroma), scale, g, backdrop, samp, enc).b;
            float a = clamp(ring * 1.2, 0.0, 1.0);
            return finish(float4(float3(cr, cg, cb) * a, a), i, px, g);
        } else if (variant == 2) {
            float d = sd_shape(i, p);
            float bevel = max(i.p0.x, 0.5);
            float depth = i.p0.y;
            float disp = i.p0.z;
            float mag = max(i.p0.w, 0.1);
            float presence = i.p1.x;
            float frost = clamp(i.p1.y, 0.0, 1.0);
            float rim_s = i.p1.w;
            float2 n = shape_normal(i, p);
            float edge_k = clamp(1.0 + d / bevel, 0.0, 1.0);
            float2 bend = n * (edge_k * edge_k * depth * presence);
            float2 center = i.rect.xy + i.rect.zw * 0.5;
            float2 sp = center + (p - center) / mix(1.0, mag, presence) - bend;
            float3 sharp_rgb = float3(
                bd(sp + n * (disp * edge_k * 8.0), scale, g, backdrop, samp, enc).r,
                bd(sp, scale, g, backdrop, samp, enc).g,
                bd(sp - n * (disp * edge_k * 8.0), scale, g, backdrop, samp, enc).b
            );
            float3 blur_rgb = bdb(sp, scale, g, blurred, samp, enc);
            float3 glass_rgb = mix(sharp_rgb, blur_rgb, frost);
            glass_rgb = mix(glass_rgb, i.c0.rgb, i.p2.y * presence);
            float rim = exp(-abs(d) / 1.5) * rim_s * presence * 0.25;
            float mask = 1.0 - smoothstep(-0.5, 0.5, d);
            return finish(float4((glass_rgb + rim) * mask, mask), i, px, g);
        } else if (variant == 3) {
            float2 center = i.rect.xy + i.rect.zw * 0.5;
            float2 uv = (p - center) / max(i.rect.zw * 0.5, float2(1.0));
            float r2 = dot(uv, uv);
            float2 warped = center + uv * (1.0 + i.p0.x * r2) * (i.rect.zw * 0.5);
            float ch = i.p0.w;
            float cr = bd(warped + float2(ch, 0.0), scale, g, backdrop, samp, enc).r;
            float cg = bd(warped, scale, g, backdrop, samp, enc).g;
            float cb = bd(warped - float2(ch, 0.0), scale, g, backdrop, samp, enc).b;
            float scan = 1.0 - i.p0.z * (0.5 + 0.5 * sin(px.y * 3.14159 / max(i.p0.y, 0.5)));
            float vig = 1.0 - i.p1.x * 0.35 * r2;
            float mask = 1.0 - smoothstep(-i.p1.w, 0.5, sd_shape(i, p));
            return finish(float4(float3(cr, cg, cb) * scan * vig * mask, mask), i, px, g);
        } else {
            float2 off = i.p0.xy;
            float cr = bd(p + off, scale, g, backdrop, samp, enc).r;
            float cg = bd(p, scale, g, backdrop, samp, enc).g;
            float cb = bd(p - off, scale, g, backdrop, samp, enc).b;
            float mask = 1.0 - smoothstep(-i.p0.w, 0.5, sd_shape(i, p));
            return finish(float4(float3(cr, cg, cb) * mask, mask), i, px, g);
        }
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
        texture2d<float> source [[texture(1)]],
        sampler samp [[sampler(0)]]
    ) {
        Inst i = insts[in.id];
        float2 px = recover_pixel(in);
        float2 p = px / i.shape.y;
        uint first = uint(i.xf.x);
        uint n = max(uint(i.xf.y), 1u);
        float4 acc = float4(0.0);

        if (i.xf.z < 0.5) {
            for (uint k = 0u; k < n; k++) {
                float3 l = pose_at(data, first, k, p);
                acc += src_at(i, l.xy, source, samp) * l.z;
            }
        } else {
            float2 b = i.aux.xy;
            float wsum = 0.0;
            for (uint k = 0u; k < n; k++) {
                float o = (float(k) + 0.5) / float(n) - 0.5;
                float w = 1.0 - 4.0 * o * o * 0.85;
                float3 l = pose_at(data, first, 0u, p - b * o);
                acc += src_at(i, l.xy, source, samp) * (w * l.z);
                wsum += w;
            }
            acc /= max(wsum, 1e-4);
        }

        return finish(acc, i, px, g);
    }
    """

    public static let extrasShader: String = commonPrelude + """
    fragment float4 fx_extras_fragment(
        VOut in [[stage_in]],
        constant Globals& g [[buffer(0)]],
        const device Inst* insts [[buffer(1)]],
        const device float4* data [[buffer(2)]],
        texture2d<float> source [[texture(1)]],
        sampler samp [[sampler(0)]]
    ) {
        Inst i = insts[in.id];
        float2 px = recover_pixel(in);
        float2 p = px / i.shape.y;
        float d = sd_shape(i, p);
        int variant = int(round(i.t.z));

        if (variant == 0) {
            float period = max(i.p0.x, 0.1);
            float band = max(i.p0.y, 1.0);
            float ang = i.p0.z;
            float intensity = i.p0.w;
            float2 dir = float2(cos(ang), sin(ang));
            float2 c = i.rect.xy + i.rect.zw * 0.5;
            float span = abs(dir.x) * i.rect.z + abs(dir.y) * i.rect.w + band * 2.0;
            float cyc = period + i.p1.y;
            float ph = fract(i.t.x / max(cyc, 0.1));
            float sweep = (ph * cyc / period) * span - span * 0.5;
            float dist = dot(p - c, dir) - sweep;
            float hl = exp(-pow(dist / (band * 0.5), 2.0)) * (ph * cyc < period ? 1.0 : 0.0);
            float mask = 1.0 - smoothstep(-max(i.p1.z, 0.5), 0.5, d);
            if (i.p1.x > 0.5) {
                float2 uv = (p - i.aux2.xy) / max(i.aux2.zw, float2(1.0));
                mask *= source.sample(samp, uv, level(0.0)).a;
            }
            float3 col = mix(i.c1.rgb * i.c1.a, i.c0.rgb, hl * intensity);
            float a = clamp((i.c1.a + hl * intensity) * mask, 0.0, 1.0);
            return finish(float4(col * mask, a), i, px, g);
        } else if (variant == 1) {
            uint base = uint(i.xf.x);
            uint count = uint(i.xf.y);
            float3 col = float3(0.0);
            float a = 0.0;
            for (uint k = 0u; k < count; k++) {
                float4 sp = data[base + k * 2u];
                float4 rot = data[base + k * 2u + 1u];
                float2 q = p - sp.xy;
                float2 r = float2(rot.x * q.x + rot.y * q.y, -rot.y * q.x + rot.x * q.y);
                float sz = max(sp.z, 0.5);
                float star = exp(-length(r) / (sz * 0.25)) + exp(-abs(r.x) / (sz * 0.08) - abs(r.y) / sz) + exp(-abs(r.y) / (sz * 0.08) - abs(r.x) / sz);
                float e = star * sp.w * i.p0.w * 0.5;
                col += i.c0.rgb * e;
                a = max(a, clamp(e, 0.0, 1.0));
            }
            return finish(float4(col, a), i, px, g);
        } else if (variant == 2) {
            uint base = uint(i.xf.x);
            float u = clamp((p.x - i.rect.x) / max(i.rect.z, 1.0), 0.0, 1.0);
            float v = clamp((p.y - i.rect.y) / max(i.rect.w, 1.0), 0.0, 1.0);
            uint idx = min(uint(u * 63.0), 63u);
            float3 col = float3(0.0);
            float3 pal[3] = { i.c0.rgb, i.c1.rgb, i.c2.rgb };
            for (uint k = 0u; k < 3u; k++) {
                float y = dat1(data, base + k * 32u, idx);
                float band = exp(-pow((v - y) / 0.16, 2.0));
                col += pal[k] * band;
            }
            float mask = 1.0 - smoothstep(-max(i.p0.w, 1.0), 0.5, d);
            float e = i.p0.z * mask;
            return finish(float4(col * e, clamp(length(col) * e, 0.0, 1.0)), i, px, g);
        } else {
            uint frame_t = i.p0.y > 0.0 ? uint(floor(i.t.x * i.p0.y)) : 0u;
            uint2 ip = uint2(px);
            float n = u01(hu(ip.x + frame_t * 131u, ip.y + frame_t * 977u)) - 0.5;
            float mask = 1.0 - smoothstep(-max(i.p0.z, 0.5), 0.5, d);
            float gval = n * i.p0.x * mask;
            return finish(float4(float3(gval), abs(gval)), i, px, g);
        }
    }
    """

    public static let fillShader: String = commonPrelude + """
    inline float3 sample_stop_oklab(const device float4* data, uint base, uint count, float u) {
        if (count <= 1u) { return data[base].rgb; }
        float x = clamp(u, 0.0, 1.0) * float(count - 1u);
        uint k = min(uint(floor(x)), count - 2u);
        float f = x - float(k);
        float3 c0 = data[base + k * 2u].rgb;
        float3 c1 = data[base + (k + 1u) * 2u].rgb;
        return mix(c0, c1, f);
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
        float scale = i.shape.y;
        float2 p = px / scale;
        float d = sd_shape(i, p);
        float border = i.aux.x;
        float intensity = i.aux.y;

        float mask = 1.0 - smoothstep(-0.5, 0.5, d);
        if (border > 0.0) {
            mask *= smoothstep(-border - 0.5, -border + 0.5, d);
        }
        if (mask <= 0.0) { return float4(0.0); }

        float2 uv = (p - i.rect.xy) / max(i.rect.zw, float2(1.0));
        int variant = int(round(i.t.z));
        uint seed = uint(i.t.y);
        float3 col = float3(0.0);

        if (variant == 0) {
            float2 anchor_p = i.p2.x > 0.5 ? (p - i.rect.xy) : p;
            float n = fbm(anchor_p / i.p0.y + float2(i.t.x * i.p0.z * 0.25), seed, 4) * i.p0.x;
            float2 g2 = shape_normal(i, p) * clamp(1.0 + d / max(i.p0.w, 1.0), 0.0, 1.0);
            float3 nrm = normalize(float3(g2 + n * 0.45 + (uv - 0.5) * i.p1.x, 1.0));
            float h = clamp(0.5 + 0.5 * (nrm.y * cos(i.p1.y) - nrm.x * sin(i.p1.y)), 0.0, 1.0);
            float studio = pow(smoothstep(0.35, 0.85, h), i.p1.w);
            col = mix(i.c0.rgb * 0.15, i.c1.rgb * i.c0.rgb, studio);
            col += i.p1.z * 0.25 * float3(sin(h * 12.0), sin(h * 12.0 + 2.1), sin(h * 12.0 + 4.2));
        } else if (variant == 1) {
            uint base = uint(i.xf.x);
            uint count = max(uint(i.xf.y), 1u);
            float2 q = uv + fbm(uv * 3.0 + float2(i.t.x * i.p0.y * 0.1), seed, 2) * i.p0.w * 0.2;
            float3 acc = float3(0.0);
            float wsum = 0.0;
            for (uint k = 0u; k < count; k++) {
                float4 c_x = data[base + k * 2u];
                float4 l_y = data[base + k * 2u + 1u];
                float2 pt = float2(c_x.w, l_y.w);
                float w = exp(-length(q - pt) * i.p0.z * 2.5);
                acc += c_x.rgb * w;
                wsum += w;
            }
            col = acc / max(wsum, 1e-4);
        } else if (variant == 2) {
            uint base = uint(i.xf.x);
            uint count = max(uint(i.xf.y), 2u);
            float tone = clamp(dot(uv - 0.5, float2(cos(i.p0.w), sin(i.p0.w))) + 0.5, 0.0, 1.0);
            if (int(round(i.p0.y)) == 3) {
                tone = dot(bd(p, scale, g, backdrop, samp, enc).rgb, float3(0.2126, 0.7152, 0.0722));
            } else if (int(round(i.p0.y)) == 2) {
                tone = 0.5 + 0.5 * fbm(p / i.p1.x + float2(i.t.x * i.p1.y), seed, 3);
            }
            tone = clamp((tone - 0.5) * i.p1.w + 0.5 + i.p1.z, 0.0, 1.0);
            uint2 dp = uint2(floor((p - i.rect.xy) / i.p0.z));
            float thresh = u01(hu(dp.x, dp.y));
            float idx_f = clamp(floor(tone * float(count - 1u) + thresh), 0.0, float(count - 1u));
            col = data[base + uint(idx_f) * 2u].rgb;
        } else if (variant == 3) {
            uint base = uint(i.xf.x);
            uint count = max(uint(i.xf.y), 1u);
            float u = clamp(dot(uv - i.p0.zw, float2(cos(i.p0.y), sin(i.p0.y))) + 0.5, 0.0, 1.0);
            uint ft = i.p1.w > 0.0 ? uint(floor(i.t.x * i.p1.w)) : 0u;
            uint2 gp = uint2(floor(p / i.p1.y));
            float grain = (u01(hu(gp.x + ft * 131u, gp.y + ft * 977u)) - 0.5) * i.p1.x;
            col = sample_stop_oklab(data, base, count, u + grain * 0.25) + grain * 0.06;
        } else if (variant == 4) {
            float rib = max(i.p0.x, 1.0);
            float ca = cos(i.p0.y), sa = sin(i.p0.y);
            float x = (p.x - i.rect.x) * ca + (p.y - i.rect.y) * sa;
            float ph = fract(x / rib) * 2.0 - 1.0;
            float2 off = float2(ca, sa) * (-ph * i.p0.z);
            float3 sharp = bd(p + off, scale, g, backdrop, samp, enc).rgb;
            float3 blur = bdb(p + off, scale, g, blurred, samp, enc);
            col = mix(sharp, blur, clamp(i.p0.w, 0.0, 1.0));
            col = mix(col, i.c0.rgb, i.p1.z) + pow(max(1.0 - abs(ph), 0.0), 4.0) * i.p1.y * 0.15;
        } else if (variant == 5) {
            uint s_base = uint(i.xf.x);
            uint m_base = uint(i.xf.z);
            uint m_count = uint(i.xf.w);
            float f = 0.0;
            float3 acc = float3(0.0);
            for (uint k = 0u; k < m_count; k++) {
                float4 mb = data[m_base + k];
                float dist = max(length(p - mb.xy), 1.0);
                float w = (mb.z * mb.z) / (dist * dist);
                f += w;
                acc += data[s_base + uint(mb.w) * 2u].rgb * w;
            }
            float edge = smoothstep(0.95, 1.15, f);
            col = mix(i.c0.rgb, acc / max(f, 1e-4), edge);
        } else if (variant == 6) {
            uint base = uint(i.xf.x);
            uint count = max(uint(i.xf.y), 1u);
            float2 q = (p - i.rect.xy - i.rect.zw * 0.5) / i.p0.x;
            float r = length(q);
            float ang = atan2(q.y, q.x) + i.p0.z * exp(-r) + i.t.x * i.p0.y;
            float2 wq = float2(cos(ang), sin(ang)) * r;
            float v = 0.5 + 0.5 * fbm(wq + fbm(wq, seed, 2) * i.p0.w, seed + 11u, 3);
            col = sample_stop_oklab(data, base, count, v);
        } else if (variant == 7) {
            uint base = uint(i.xf.x);
            uint count = max(uint(i.xf.y), 1u);
            float2 q = p / i.p0.x;
            int2 cell = int2(floor(q));
            float2 f = fract(q);
            float d1 = 8.0, d2 = 8.0;
            uint best_h = 0u;
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    int2 g2 = cell + int2(x, y);
                    uint h = hu(uint(g2.x) ^ seed, uint(g2.y));
                    float2 pt = float2(float(x), float(y)) + 0.5 + 0.35 * float2(sin(i.t.x * i.p0.y + u01(h) * 6.28), cos(i.t.x * i.p0.y + u01(h + 1u) * 6.28)) - f;
                    float dd = length(pt);
                    if (dd < d1) { d2 = d1; d1 = dd; best_h = h; } else if (dd < d2) { d2 = dd; }
                }
            }
            float3 c = data[base + (best_h % count) * 2u].rgb;
            float seam = 1.0 - smoothstep(0.0, i.p0.z / i.p0.x, d2 - d1);
            col = mix(c * (1.0 - i.p0.w * d1 * 0.5), i.c0.rgb, seam);
        } else if (variant == 8) {
            uint base = uint(i.xf.x);
            uint count = max(uint(i.xf.y), 2u);
            float ca = cos(i.p0.w), sa = sin(i.p0.w);
            float u = uv.x * ca + uv.y * sa;
            float v = uv.y * ca - uv.x * sa;
            col = data[base].rgb;
            for (uint k = 1u; k < count; k++) {
                float level = float(k) / float(count);
                float w = sin(u * i.p0.y * 6.28318 + i.t.x * i.p0.z + float(k) * 1.7) * i.p0.x;
                float edge = smoothstep(level + w - i.p1.x, level + w + i.p1.x, v);
                col = mix(col, data[base + k * 2u].rgb, edge);
            }
        } else if (variant == 9) {
            float cell = max(i.p0.z, 1.0);
            float2 q = (p - i.rect.xy) / cell;
            float2 f = fract(q) - 0.5;
            float tone = clamp(1.0 - length(uv - 0.5) * 1.4, 0.0, 1.0);
            float dot_m = 1.0 - smoothstep(tone * 0.48 - 0.05, tone * 0.48 + 0.05, length(f));
            col = mix(i.c1.rgb, i.c0.rgb, dot_m);
        } else {
            float bevel = max(i.p0.z, 1.0);
            float2 g2 = shape_normal(i, p) * clamp(1.0 + d / bevel, 0.0, 1.0);
            float3 nrm = normalize(float3(g2 * i.p0.y, 1.0));
            float3 ldir = normalize(float3(sin(i.p0.w), -cos(i.p0.w), 1.0));
            float diff = max(dot(nrm, ldir), 0.0);
            float3 hvec = normalize(ldir + float3(0.0, 0.0, 1.0));
            float spec = pow(max(dot(nrm, hvec), 0.0), mix(128.0, 8.0, i.p0.x));
            col = i.c0.rgb * (0.45 + 0.55 * diff) + spec * (1.0 - i.p0.x * 0.8);
        }

        return finish(float4(col * mask * intensity, mask * intensity), i, px, g);
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
}
