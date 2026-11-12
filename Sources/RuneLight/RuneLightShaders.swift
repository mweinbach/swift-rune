import Foundation

public enum RuneLightShaders: Sendable {
    public static let commonPrelude: String = """
    #include <metal_stdlib>
    using namespace metal;

    constant uint F_OCC = 1u;
    constant uint F_EMIT = 2u;
    constant uint F_RAISED = 4u;
    constant uint F_HINT = 8u;

    struct Frame {
        float4 sf;      // width, height, field_w, field_h
        float4 gs;      // gi_w, gi_h, field_scale, gi_scale
        float4 ambient; // rgb, exposure
        uint4 counts;   // prim_count, light_count, gi_enabled, dither
        float4 misc;    // contact_ao, rim, shafts_over, albedo_floor
        float4 text;    // floor, ceiling, lit, specular
        float4 gi;      // strength, air, bounce, absorption
        float4 bg;      // bg_gloss, bg_rough, emission_gain, time
        float4 ext;     // seed, srgb_out, 0, 0
    };

    struct Prim {
        float4 rect;
        float4 radii;
        float4 z;
        float4 mat;
        float4 emit;
        float4 albedo;
    };

    struct Light {
        float4 pos;   // x, y, z, radius
        float4 color; // rgb, range
        float4 axis;  // dx, dy, dz, half_angle
        float4 extra; // shafts, bulb, specular, softness
    };

    struct CascadeU {
        uint level;
        uint count;
        uint merge;
        uint pad;
    };

    inline uint flags_of(Prim pr) {
        return uint(max(pr.mat.z, 0.0));
    }

    inline float sd_rrect(float2 p, float2 half_size, float4 radii) {
        float r = (p.x > 0.0) ? ((p.y > 0.0) ? radii.z : radii.y) : ((p.y > 0.0) ? radii.w : radii.x);
        r = min(r, min(half_size.x, half_size.y));
        float2 q = abs(p) - half_size + r;
        return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - r;
    }

    inline float slab_sd(float3 f, float z) {
        float dz = max(z - f.z, f.y - z);
        float2 a = float2(f.x, dz);
        return length(max(a, float2(0.0))) + min(max(a.x, a.y), 0.0);
    }

    inline float ggx_d(float ndh, float rough) {
        float a = max(rough * rough, 0.002);
        float a2 = a * a;
        float d = ndh * ndh * (a2 - 1.0) + 1.0;
        return a2 / (3.14159265 * d * d + 1e-6);
    }

    inline float3 to_srgb(float3 c) {
        float3 lo = c * 12.92;
        float3 hi = 1.055 * pow(max(c, float3(0.0)), float3(1.0 / 2.4)) - 0.055;
        return select(hi, lo, c <= float3(0.0031308));
    }
    """

    public static let gbufferShader: String = commonPrelude + """
    struct GBufVOut {
        float4 pos [[position]];
        float2 p;
        uint idx [[flat]];
    };

    struct GBufFragOut {
        float4 g [[color(0)]];
        uint id [[color(1)]];
    };

    vertex GBufVOut light_gbuf_vertex(
        uint vi [[vertex_id]],
        uint ii [[instance_id]],
        constant Frame& F [[buffer(0)]],
        const device Prim* prims [[buffer(1)]]
    ) {
        Prim pr = prims[ii];
        float2 corner = float2(float(vi & 1u), float(vi >> 1u));
        float2 p = pr.rect.xy - float2(1.0) + corner * (pr.rect.zw + float2(2.0));
        GBufVOut o;
        o.pos = float4(p.x / F.sf.x * 2.0 - 1.0, 1.0 - p.y / F.sf.y * 2.0, 0.0, 1.0);
        o.p = p;
        o.idx = ii;
        return o;
    }

    fragment GBufFragOut light_gbuf_fragment(
        GBufVOut in [[stage_in]],
        const device Prim* prims [[buffer(1)]]
    ) {
        Prim pr = prims[in.idx];
        float2 half_size = pr.rect.zw * 0.5;
        float2 q = in.p - (pr.rect.xy + half_size);
        float d = sd_rrect(q, half_size, pr.radii);
        if (d > 0.5 || (flags_of(pr) & F_HINT) != 0u) {
            discard_fragment();
        }
        float e = 0.5;
        float gx = sd_rrect(q + float2(e, 0.0), half_size, pr.radii) - sd_rrect(q - float2(e, 0.0), half_size, pr.radii);
        float gy = sd_rrect(q + float2(0.0, e), half_size, pr.radii) - sd_rrect(q - float2(0.0, e), half_size, pr.radii);
        float2 g = float2(gx, gy);
        float gl = length(g);
        g = gl > 1e-5 ? g / gl : float2(0.0);
        GBufFragOut o;
        o.g = float4(d, g, pr.z.y);
        o.id = in.idx + 1u;
        return o;
    }
    """

    public static let fieldShader: String = commonPrelude + """
    constant float FIELD_CLAMP = 256.0;
    constant uint FIELD_MAX_LOCAL = 256u;

    kernel void light_field_kernel(
        constant Frame& F [[buffer(0)]],
        const device Prim* prims [[buffer(1)]],
        texture2d<float, access::write> out_field [[texture(0)]],
        uint2 gid [[thread_position_in_grid]],
        uint li [[thread_index_in_threadgroup]],
        uint2 wid [[threadgroup_position_in_grid]]
    ) {
        threadgroup uint local_ids[FIELD_MAX_LOCAL];
        threadgroup atomic_uint local_n;

        if (li == 0u) {
            atomic_store_explicit(&local_n, 0u, memory_order_relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        float2 lo = float2(wid * 16u) / F.gs.z;
        float2 hi = float2(wid * 16u + 16u) / F.gs.z;
        float2 tc = (lo + hi) * 0.5;
        float2 th = (hi - lo) * 0.5;
        uint n = F.counts.x;

        for (uint i = li; i < n; i += 256u) {
            Prim pr = prims[i];
            if ((flags_of(pr) & (F_OCC | F_EMIT | F_HINT)) == 0u) { continue; }
            float2 half_size = pr.rect.zw * 0.5;
            float2 c = pr.rect.xy + half_size;
            float2 gap = max(abs(c - tc) - half_size - th, float2(0.0));
            if (length(gap) < FIELD_CLAMP) {
                uint k = atomic_fetch_add_explicit(&local_n, 1u, memory_order_relaxed);
                if (k < FIELD_MAX_LOCAL) {
                    local_ids[k] = i;
                }
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        uint count = min(atomic_load_explicit(&local_n, memory_order_relaxed), FIELD_MAX_LOCAL);
        uint2 fs = uint2(F.sf.zw);
        if (gid.x >= fs.x || gid.y >= fs.y) { return; }

        float2 p = (float2(gid) + 0.5) / F.gs.z;
        float best = FIELD_CLAMP;
        uint best_i = 0xffffffffu;
        float bot = 0.0;
        float top = 0.0;
        float gi = FIELD_CLAMP;

        for (uint k = 0u; k < count; k++) {
            uint i = local_ids[k];
            Prim pr = prims[i];
            float2 half_size = pr.rect.zw * 0.5;
            float2 c = pr.rect.xy + half_size;
            float2 q0 = abs(p - c) - half_size;
            float bd = min(max(q0.x, q0.y), 0.0) + length(max(q0, float2(0.0)));
            if (bd > best && bd > gi) { continue; }
            float d = sd_rrect(p - c, half_size, pr.radii);
            if ((flags_of(pr) & (F_EMIT | F_HINT)) != 0u) {
                gi = min(gi, d);
            }
            if ((flags_of(pr) & F_OCC) != 0u && (d < best || (d == best && i < best_i))) {
                best = d;
                best_i = i;
                bot = pr.z.x;
                top = pr.z.y;
            }
        }
        out_field.write(float4(best, bot, top, gi), gid);
    }
    """

    public static let shadowShader: String = commonPrelude + """
    inline float3 sample_field(texture2d<float> field, sampler smp, float2 p, constant Frame& F) {
        float2 uv = p * F.gs.z / F.sf.zw;
        return field.sample(smp, uv, level(0.0)).xyz;
    }

    inline float trace_shadow(texture2d<float> field, sampler smp, Light lt, float3 p, constant Frame& F) {
        float3 l = lt.pos.xyz;
        float radius = lt.pos.w * lt.extra.w;
        float3 d = l - p;
        float dist = length(d);
        float3 rd = d / max(dist, 1e-6);
        float theta = max(radius / max(dist, 1e-6), 1e-3);
        float t = 0.75;
        float res = 1.0;
        float ph = 1e10;

        for (int step = 0; step < 64; step++) {
            if (t >= dist - radius) { break; }
            float3 q = p + rd * t;
            float h = slab_sd(sample_field(field, smp, q.xy, F), q.z);
            if (h <= 0.0) {
                res = min(res, h / (t * theta));
            } else {
                float y = h * h / (2.0 * ph);
                float dd = sqrt(max(h * h - y * y, 0.0));
                res = min(res, dd / (max(t - y, 1e-3) * theta));
            }
            ph = max(h, 1e-3);
            if (res <= -1.0) { break; }
            t += clamp(abs(h), 0.6 + t * 0.012, 96.0);
        }
        float k = clamp(0.5 + 0.5 * res, 0.0, 1.0);
        return k * k * (3.0 - 2.0 * k);
    }

    inline float trace_shafts(texture2d<float> field, sampler smp, Light lt, float2 p, constant Frame& F) {
        if (lt.extra.x <= 0.0) { return 0.0; }
        float2 d = lt.pos.xy - p;
        float dist = length(d);
        float2 rd = d / max(dist, 1e-6);
        float acc = 0.0;
        const int STEPS = 16;
        for (int s = 0; s < STEPS; s++) {
            float t = (float(s) + 0.5) / float(STEPS) * min(dist, 600.0);
            float2 q = p + rd * t;
            float3 f = sample_field(field, smp, q, F);
            float occ = smoothstep(-2.0, 2.0, f.x);
            acc += occ / float(STEPS);
        }
        return acc * lt.extra.x;
    }

    kernel void light_shadow_kernel(
        constant Frame& F [[buffer(0)]],
        const device Light* lights [[buffer(1)]],
        texture2d<float> field [[texture(0)]],
        texture2d<float> gbuf [[texture(1)]],
        sampler smp [[sampler(0)]],
        texture2d_array<float, access::write> out_vis [[texture(2)]],
        texture2d_array<float, access::write> out_air [[texture(3)]],
        uint3 gid [[thread_position_in_grid]]
    ) {
        uint2 fs = uint2(F.sf.zw);
        if (gid.x >= fs.x || gid.y >= fs.y) { return; }
        uint layer = gid.z;
        float2 p = (float2(gid.xy) + 0.5) / F.gs.z;
        float z = gbuf.sample(smp, p / F.sf.xy, level(0.0)).w;

        float4 vis = float4(1.0);
        float4 air = float4(0.0);
        for (uint c = 0u; c < 4u; c++) {
            uint li = layer * 4u + c;
            if (li < F.counts.y) {
                vis[c] = trace_shadow(field, smp, lights[li], float3(p, z), F);
                air[c] = trace_shafts(field, smp, lights[li], p, F);
            }
        }
        out_vis.write(vis, gid.xy, layer);
        out_air.write(air, gid.xy, layer);
    }
    """

    public static let giSceneShader: String = commonPrelude + """
    kernel void light_gi_scene_kernel(
        constant Frame& F [[buffer(0)]],
        const device Prim* prims [[buffer(1)]],
        const device Light* lights [[buffer(2)]],
        texture2d_array<float> vis [[texture(0)]],
        texture2d<float> extra_emit [[texture(1)]],
        sampler smp [[sampler(0)]],
        texture2d<float, access::write> out_emit [[texture(2)]],
        texture2d<float, access::write> out_occ [[texture(3)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint2 gs = uint2(F.gs.xy);
        if (gid.x >= gs.x || gid.y >= gs.y) { return; }
        float2 p = (float2(gid) + 0.5) / F.gs.w;
        float3 emit_col = extra_emit.sample(smp, p / F.sf.xy, level(0.0)).rgb * F.bg.z;
        float emit_sigma = length(emit_col) > 1e-4 ? 1.0 : 0.0;
        float3 occ_col = float3(0.0);
        float occ_cov = 0.0;

        for (uint i = 0u; i < F.counts.x; i++) {
            Prim pr = prims[i];
            float2 half_size = pr.rect.zw * 0.5;
            float d = sd_rrect(p - (pr.rect.xy + half_size), half_size, pr.radii);
            if (d <= 0.5) {
                if ((flags_of(pr) & F_EMIT) != 0u) {
                    emit_col += pr.emit.rgb;
                    emit_sigma = 1.0;
                }
                if ((flags_of(pr) & F_OCC) != 0u) {
                    occ_col = pr.albedo.rgb * F.gi.z;
                    occ_cov = 1.0;
                }
            }
        }
        out_emit.write(float4(emit_col, emit_sigma), gid);
        out_occ.write(float4(occ_col, occ_cov), gid);
    }
    """

    public static let giCascadeShader: String = commonPrelude + """
    kernel void light_gi_cascade_kernel(
        constant Frame& F [[buffer(0)]],
        constant CascadeU& C [[buffer(1)]],
        texture2d<float> field [[texture(0)]],
        texture2d<float> scene_emit [[texture(1)]],
        texture2d<float> scene_occ [[texture(2)]],
        sampler smp [[sampler(0)]],
        texture2d<float> upper [[texture(3)]],
        texture2d<float, access::write> out_c [[texture(4)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint2 gs = uint2(F.gs.xy);
        if (gid.x >= gs.x || gid.y >= gs.y) { return; }
        uint b = 1u << (C.level + 1u);
        uint dirs = b * b;
        uint2 probe = gid / b;
        uint2 local = gid % b;
        uint dir_idx = local.y * b + local.x;
        float ang = (float(dir_idx) + 0.5) / float(dirs) * 6.28318530718;
        float2 rd = float2(cos(ang), sin(ang));

        float t0 = (C.level == 0u) ? 0.0 : float(1u << (2u * C.level)) * 2.0;
        float t1 = float(1u << (2u * (C.level + 1u))) * 2.0;
        float2 p0 = (float2(probe) + 0.5) * float(b) / F.gs.w;

        float3 rad = float3(0.0);
        float trans = 1.0;
        float t = t0;
        for (int s = 0; s < 12; s++) {
            if (t >= t1) { break; }
            float2 q = p0 + rd * t;
            float2 uv = q / F.sf.xy;
            if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) { break; }
            float4 em = scene_emit.sample(smp, uv, level(0.0));
            float4 oc = scene_occ.sample(smp, uv, level(0.0));
            rad += trans * em.rgb * 0.25;
            trans *= (1.0 - oc.a * F.gi.w * 0.2);
            float d = field.sample(smp, uv, level(0.0)).w;
            t += max(d, 4.0);
        }

        if (C.merge != 0u && C.level + 1u < C.count) {
            float4 up = upper.sample(smp, (float2(gid) + 0.5) / float2(gs), level(0.0));
            rad += trans * up.rgb;
            trans *= up.a;
        }
        out_c.write(float4(rad, trans), gid);
    }
    """

    public static let giFluenceShader: String = commonPrelude + """
    kernel void light_gi_fluence_kernel(
        constant Frame& F [[buffer(0)]],
        texture2d<float> c0 [[texture(0)]],
        texture2d<float, access::write> out_fluence [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint2 gs = uint2(F.gs.xy);
        if (gid.x >= gs.x || gid.y >= gs.y) { return; }
        uint2 base = (gid / 2u) * 2u;
        float4 acc = float4(0.0);
        for (uint y = 0u; y < 2u; y++) {
            for (uint x = 0u; x < 2u; x++) {
                acc += c0.read(min(base + uint2(x, y), gs - 1u));
            }
        }
        out_fluence.write(acc * 0.25, gid);
    }
    """

    public static let compositeShader: String = commonPrelude + """
    struct CompVOut {
        float4 pos [[position]];
        float2 uv;
    };

    vertex CompVOut light_composite_vertex(uint vi [[vertex_id]]) {
        float2 p = float2(float((vi << 1u) & 2u), float(vi & 2u));
        CompVOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    fragment float4 light_composite_fragment(
        CompVOut in [[stage_in]],
        constant Frame& F [[buffer(0)]],
        const device Prim* prims [[buffer(1)]],
        const device Light* lights [[buffer(2)]],
        texture2d<float> base_tex [[texture(0)]],
        texture2d<float> text_tex [[texture(1)]],
        texture2d<float> gbuf [[texture(2)]],
        texture2d<uint> id_tex [[texture(3)]],
        texture2d_array<float> vis_tex [[texture(4)]],
        texture2d_array<float> air_tex [[texture(5)]],
        texture2d<float> field_tex [[texture(6)]],
        texture2d<float> fluence_tex [[texture(7)]],
        sampler smp [[sampler(0)]]
    ) {
        float2 uv = in.uv;
        float2 px = uv * F.sf.xy;
        float4 base_c = base_tex.sample(smp, uv, level(0.0));
        float4 text_c = text_tex.sample(smp, uv, level(0.0));
        float4 gb = gbuf.sample(smp, uv, level(0.0));
        uint pid = id_tex.read(uint2(px)).r;

        float gloss = F.bg.x;
        float rough = F.bg.y;
        float3 nrm = float3(0.0, 0.0, 1.0);
        float z = gb.w;

        if (pid > 0u) {
            Prim pr = prims[pid - 1u];
            gloss = pr.mat.x;
            rough = pr.mat.y;
            if ((flags_of(pr) & F_RAISED) != 0u && pr.z.z > 0.0) {
                float bw = pr.z.z;
                float bh = pr.z.w;
                float k = clamp(1.0 + gb.x / bw, 0.0, 1.0);
                nrm = normalize(float3(gb.yz * k * (bh / bw), 1.0));
            }
        }

        float3 albedo = max(base_c.rgb, float3(F.misc.w));
        float3 total_light = F.ambient.rgb;
        float3 spec_acc = float3(0.0);

        for (uint li = 0u; li < F.counts.y; li++) {
            Light lt = lights[li];
            float3 lvec = lt.pos.xyz - float3(px, z);
            float dist = length(lvec);
            float3 ldir = lvec / max(dist, 1e-4);
            float att = 200.0 * 200.0 / (dist * dist + 200.0 * 200.0 * 0.25);
            float range = max(lt.color.w, 1.0);
            float win = pow(max(1.0 - pow(dist / range, 4.0), 0.0), 2.0);
            float spot = 1.0;
            if (lt.axis.w > 0.0) {
                float cos_a = dot(-ldir, lt.axis.xyz);
                spot = smoothstep(cos(lt.axis.w), cos(lt.axis.w * 0.65), cos_a);
            }
            float vis = vis_tex.sample(smp, uv, li / 4u, level(0.0))[li & 3u];
            float air = air_tex.sample(smp, uv, li / 4u, level(0.0))[li & 3u];
            float ndl = max(dot(nrm, ldir), 0.0);
            float3 hvec = normalize(ldir + float3(0.0, 0.0, 1.0));
            float spec = ggx_d(max(dot(nrm, hvec), 0.0), rough) * gloss * lt.extra.z;
            float3 lc = lt.color.rgb * att * win * spot;
            total_light += lc * (ndl * vis + air * F.misc.z);
            spec_acc += lc * spec * vis;
        }

        if (F.counts.z != 0u) {
            float3 fl = fluence_tex.sample(smp, uv, level(0.0)).rgb;
            total_light += fl * F.gi.x + fl * F.gi.y;
        }

        float3 lit = (albedo * total_light + spec_acc) * F.ambient.w;
        float3 text_lit = clamp(total_light, F.text.x, F.text.y);
        float3 final_rgb = mix(lit, text_c.rgb * mix(float3(1.0), text_lit, F.text.z) + spec_acc * F.text.w, text_c.a);
        if (F.ext.y > 0.5) {
            final_rgb = to_srgb(final_rgb);
        }
        return float4(final_rgb, 1.0);
    }
    """

    public static let glassShader: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct Glass {
        float4 a;
        float4 b;
        float4 r;
        float4 p0;
        float4 p1;
        float4 tint;
    };

    struct GlassLight {
        float4 pos;
        float4 color;
    };

    struct GlassU {
        float4 size;
        float4 misc;
        float4 shadow;
    };

    struct GVOut {
        float4 pos [[position]];
        float2 uv;
    };

    inline float sd_rrect_uniform(float2 p, float2 half_size, float r) {
        float rr = min(r, min(half_size.x, half_size.y));
        float2 q = abs(p) - half_size + rr;
        return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - rr;
    }

    inline float smin(float a, float b, float k) {
        if (k <= 0.0) { return min(a, b); }
        float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
        return mix(b, a, h) - k * h * (1.0 - h);
    }

    vertex GVOut glass_vertex(uint vi [[vertex_id]]) {
        float2 p = float2(float((vi << 1u) & 2u), float(vi & 2u));
        GVOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    fragment float4 glass_fragment(
        GVOut in [[stage_in]],
        constant GlassU& U [[buffer(0)]],
        const device Glass* glasses [[buffer(1)]],
        const device GlassLight* glights [[buffer(2)]],
        texture2d<float> backdrop [[texture(0)]],
        texture2d<float> fluence [[texture(1)]],
        sampler smp [[sampler(0)]]
    ) {
        float2 px = in.uv * U.size.xy;
        float4 col = backdrop.sample(smp, in.uv, level(0.0));
        uint count = uint(U.misc.x);
        for (uint idx = 0u; idx < count; idx++) {
            Glass g = glasses[idx];
            float2 ha = g.a.zw * 0.5;
            float da = sd_rrect_uniform(px - (g.a.xy + ha), ha, g.r.x);
            float d = da;
            if (g.b.z > 0.0 && g.b.w > 0.0) {
                float2 hb = g.b.zw * 0.5;
                float db = sd_rrect_uniform(px - (g.b.xy + hb), hb, g.r.y);
                d = mix(smin(da, db, g.r.z), db, g.r.w);
            }
            if (d < 0.5) {
                float bevel = max(g.p0.y, 1.0);
                float edge = clamp(1.0 + d / bevel, 0.0, 1.0);
                float2 off = float2(edge * edge * g.p0.x * 0.25 * g.p1.w);
                float3 refr = float3(
                    backdrop.sample(smp, (px + off * (1.0 + g.p1.y)) / U.size.xy, level(g.p1.z * 4.0)).r,
                    backdrop.sample(smp, (px + off) / U.size.xy, level(g.p1.z * 4.0)).g,
                    backdrop.sample(smp, (px + off * (1.0 - g.p1.y)) / U.size.xy, level(g.p1.z * 4.0)).b
                );
                float3 absorb = exp(-g.tint.rgb * g.p0.x * g.p1.w);
                float3 fl = fluence.sample(smp, in.uv, level(0.0)).rgb * g.tint.w * exp(-abs(d) / 3.0);
                col.rgb = mix(col.rgb, refr * absorb + fl, 1.0 - smoothstep(-0.5, 0.5, d));
            }
        }
        return col;
    }

    vertex GVOut glass_pyramid_vertex(uint vi [[vertex_id]]) {
        float2 p = float2(float((vi << 1u) & 2u), float(vi & 2u));
        GVOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    fragment float4 glass_pyramid_fragment(
        GVOut in [[stage_in]],
        texture2d<float> src [[texture(0)]],
        sampler smp [[sampler(0)]]
    ) {
        float2 t = 1.0 / float2(src.get_width(), src.get_height());
        float4 c = src.sample(smp, in.uv + t * float2(-0.5, -0.5), level(0.0))
                 + src.sample(smp, in.uv + t * float2( 0.5, -0.5), level(0.0))
                 + src.sample(smp, in.uv + t * float2(-0.5,  0.5), level(0.0))
                 + src.sample(smp, in.uv + t * float2( 0.5,  0.5), level(0.0));
        return c * 0.25;
    }
    """
}
