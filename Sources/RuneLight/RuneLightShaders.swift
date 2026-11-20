import Foundation
import Rune

public enum RuneLightShaders: Sendable {
    public static let commonPrelude: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct Frame {
        float4 sf;       // output size xy, field size zw
        float4 gs;       // gi probe grid xy, field scale (field px per output px), gi scale
        float4 ambient;  // rgb ambient irradiance, exposure
        uint4 counts;    // prims, lights, cascades, flags (1 gi, 2 shafts, 4 encode sRGB, 8 ao, 16 extra emission)
        float4 misc;     // max occluder top z, time, seed, shafts over occluders
        float4 text;     // floor, ceiling, how much light text takes, specular on text
        float4 gi;       // strength, air glow, bounce, absorption per gi texel
        float4 bg;       // background gloss, background roughness, contact AO strength, rim strength
        float4 ext;      // albedo floor, extra emission gain, unused
    };

    struct Prim {
        float4 rect;     // x, y, w, h
        float4 radii;    // tl, tr, br, bl
        float4 z;        // bottom, top, bevel width, bevel height
        float4 mat;      // gloss, roughness, flags, ao reach
        float4 emit;     // linear radiance rgb, unused
        float4 albedo;   // rgb albedo for bounce, unused
    };

    struct Light {
        float4 pos;      // x, y, z, source radius
        float4 color;    // linear rgb * intensity, range
        float4 axis;     // spot axis xyz (unit), half-angle in radians (0 = point light)
        float4 extra;    // shafts, bulb glow, specular, softness multiplier
    };

    constant float RL_PI = 3.14159265f;
    constant float RL_TAU = 6.28318531f;
    constant float RL_REF = 200.0f;
    constant uint F_OCC = 1u;
    constant uint F_EMIT = 2u;
    constant uint F_RAISED = 4u;
    constant uint F_HINT = 8u;

    inline float w_smoothstep(float e0, float e1, float x) {
        if (e0 == e1) {
            return x >= e1 ? 1.0f : 0.0f;
        }
        float t = clamp((x - e0) / (e1 - e0), 0.0f, 1.0f);
        return t * t * (3.0f - 2.0f * t);
    }

    inline uint flags_of(Prim p) {
        return uint(max(p.mat.z, 0.0f) + 0.5f);
    }

    // Rune's rounded rect (clip.wgsl `sd_continuous` / `sd_rounded`):
    // radii tl, tr, br, bl, y down; negative selects Apple's continuous corner.
    constant float CONTINUOUS_K = 1.52866483f;
    inline float sd_continuous(float2 p, float2 halfSize, float r) {
        float e = CONTINUOUS_K * r;
        float2 q = halfSize - abs(p);
        float2 v = float2(e) - q;
        if (v.x <= 0.0f || v.y <= 0.0f) { return max(-q.x, -q.y); }
        float u = atan2(v.y, v.x) * (4.0f / RL_PI) - 1.0f;
        float u2 = u * u;
        return length(v) - e * (1.14602295f + u2 * (-0.37573161f + u2 * (0.30796609f - 0.07724354f * u2)));
    }

    inline float sd_rrect(float2 p, float2 halfSize, float4 radii) {
        float r = radii.x;
        if (p.x > 0.0f) {
            r = select(radii.y, radii.z, p.y > 0.0f);
        } else {
            r = select(radii.x, radii.w, p.y > 0.0f);
        }
        if (r < 0.0f) { return sd_continuous(p, halfSize, min(-r, min(halfSize.x, halfSize.y))); }
        r = min(r, min(halfSize.x, halfSize.y));
        float2 q = abs(p) - halfSize + float2(r);
        return min(max(q.x, q.y), 0.0f) + length(max(q, float2(0.0f))) - r;
    }

    inline float prim_sd(Prim pr, float2 p) {
        float2 halfSize = pr.rect.zw * 0.5f;
        return sd_rrect(p - (pr.rect.xy + halfSize), halfSize, pr.radii);
    }

    inline float beam_angle(float c) {
        float omc = max(0.0f, 1.0f - clamp(c, -1.0f, 1.0f));
        return sqrt(2.0f * omc) * (1.0f + 0.083333f * omc);
    }

    inline float beam_bell(float x) {
        float x2 = x * x;
        return 1.0f / (1.0f + x2 * (1.0f + 0.35f * x2));
    }

    inline float beam_lorentz(float x) {
        float x2 = x * x;
        return 1.0f / (1.0f + x2 * (1.0f + 0.48f * x2));
    }

    inline float beam_profile(float t) {
        float inner = 0.5f;
        float core = 0.45f;
        float core_w = 0.34f;
        float spill = 0.035f;
        float spill_w = 1.6f;
        float rings = 0.18f;
        if (t >= spill_w * 1.7f) {
            return 0.0f;
        }
        float ring = 1.0f + rings * (0.2f * beam_bell((t - 0.84f) * 12.5f) - 0.18f * beam_bell((t - core_w * 1.35f) * 9.0f));
        return (1.0f - w_smoothstep(inner, 1.0f, t)) * ring + core * beam_lorentz(t / core_w) + spill * beam_lorentz(t / spill_w);
    }

    inline float4 light_term(Light L, float3 P) {
        float3 D = L.pos.xyz - P;
        float d2 = dot(D, D);
        float d = sqrt(d2);
        float3 l = D / max(d, 1e-4f);
        float x = d / max(L.color.w, 1.0f);
        float x2 = x * x;
        float w = clamp(1.0f - x2 * x2, 0.0f, 1.0f);
        float a = (RL_REF * RL_REF) / (d2 + L.pos.w * L.pos.w) * w * w;
        if (L.axis.w > 0.0f) {
            a = a * beam_profile(beam_angle(dot(-l, L.axis.xyz)) / L.axis.w);
        }
        return float4(l, a);
    }

    inline float luma(float3 c) {
        return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
    }
    """

    public static let gbufferShader: String = commonPrelude + """
    struct GBufferVOut {
        float4 pos [[position]];
        uint idx [[flat]];
    };

    struct GBufferFOut {
        float4 g [[color(0)]];
        uint id [[color(1)]];
    };

    vertex GBufferVOut gbuffer_vertex(
        uint vi [[vertex_id]],
        uint ii [[instance_id]],
        constant Frame &F [[buffer(0)]],
        device const Prim *prims [[buffer(1)]]
    ) {
        Prim pr = prims[ii];
        float2 corner = float2(float(vi & 1u), float(vi >> 1u));
        float2 p = pr.rect.xy - float2(1.0f) + corner * (pr.rect.zw + float2(2.0f));
        GBufferVOut o;
        o.pos = float4(p.x / F.sf.x * 2.0f - 1.0f, 1.0f - p.y / F.sf.y * 2.0f, 0.0f, 1.0f);
        o.idx = ii;
        return o;
    }

    fragment GBufferFOut gbuffer_fragment(
        GBufferVOut i [[stage_in]],
        device const Prim *prims [[buffer(1)]]
    ) {
        Prim pr = prims[i.idx];
        float2 halfSize = pr.rect.zw * 0.5f;
        // Fragment position is the rasterizer's exact pixel centre; interpolated `p` drifts by
        // subpixel ULPs on some backends, discarding outer-edge pixels that sit on the exact `d == 0.5` cut.
        float2 q = i.pos.xy - (pr.rect.xy + halfSize);
        float d = sd_rrect(q, halfSize, pr.radii);
        if (d > 0.5f || (flags_of(pr) & F_HINT) != 0u) {
            discard_fragment();
        }
        float e = 0.5f;
        float gx = sd_rrect(q + float2(e, 0.0f), halfSize, pr.radii) - sd_rrect(q - float2(e, 0.0f), halfSize, pr.radii);
        float gy = sd_rrect(q + float2(0.0f, e), halfSize, pr.radii) - sd_rrect(q - float2(0.0f, e), halfSize, pr.radii);
        float2 g = float2(gx, gy);
        float gl = length(g);
        g = select(float2(0.0f), g / gl, gl > 1e-5f);
        GBufferFOut o;
        o.g = float4(d, g, pr.z.y);
        o.id = i.idx + 1u;
        return o;
    }
    """

    public static let fieldShader: String = commonPrelude + """
    constant float FIELD_CLAMP = 256.0f;
    constant uint MAX_LOCAL = 256u;

    kernel void field_kernel(
        constant Frame &F [[buffer(0)]],
        device const Prim *prims [[buffer(1)]],
        texture2d<float, access::write> out_field [[texture(0)]],
        uint2 gid [[thread_position_in_grid]],
        uint li [[thread_index_in_threadgroup]],
        uint2 wid [[threadgroup_position_in_grid]]
    ) {
        threadgroup uint local_ids[MAX_LOCAL];
        threadgroup atomic_uint local_n;
        if (li == 0u) {
            atomic_store_explicit(&local_n, 0u, memory_order_relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        float2 lo = float2(wid * 16u) / F.gs.z;
        float2 hi = float2(wid * 16u + 16u) / F.gs.z;
        float2 tc = (lo + hi) * 0.5f;
        float2 th = (hi - lo) * 0.5f;
        uint n = F.counts.x;
        for (uint i = li; i < n; i += 256u) {
            Prim pr = prims[i];
            if ((flags_of(pr) & (F_OCC | F_EMIT | F_HINT)) == 0u) {
                continue;
            }
            float2 halfSize = pr.rect.zw * 0.5f;
            float2 c = pr.rect.xy + halfSize;
            float2 gap = max(abs(c - tc) - halfSize - th, float2(0.0f));
            if (length(gap) < FIELD_CLAMP) {
                uint k = atomic_fetch_add_explicit(&local_n, 1u, memory_order_relaxed);
                if (k < MAX_LOCAL) {
                    local_ids[k] = i;
                }
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        uint count = min(atomic_load_explicit(&local_n, memory_order_relaxed), MAX_LOCAL);
        uint2 fs = uint2(F.sf.zw);
        if (gid.x >= fs.x || gid.y >= fs.y) {
            return;
        }
        float2 p = (float2(gid) + 0.5f) / F.gs.z;
        float best = FIELD_CLAMP;
        uint best_i = 0xffffffffu;
        float bot = 0.0f;
        float top = 0.0f;
        float gi = FIELD_CLAMP;
        for (uint k = 0u; k < count; k += 1u) {
            uint i = local_ids[k];
            Prim pr = prims[i];
            float2 halfSize = pr.rect.zw * 0.5f;
            float2 c = pr.rect.xy + halfSize;
            float2 q0 = abs(p - c) - halfSize;
            float bd = min(max(q0.x, q0.y), 0.0f) + length(max(q0, float2(0.0f)));
            if (bd > best && bd > gi) {
                continue;
            }
            float d = sd_rrect(p - c, halfSize, pr.radii);
            uint fl = flags_of(pr);
            if ((fl & (F_EMIT | F_HINT)) != 0u) {
                gi = min(gi, d);
            }
            if ((fl & F_OCC) != 0u && (d < best || (d == best && i < best_i))) {
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
    inline float4 field_at(texture2d<float> field, sampler samp, constant Frame &F, float2 q) {
        return field.sample(samp, q * F.gs.z / F.sf.zw, level(0.0f));
    }

    inline float slab(float4 f, float z) {
        float dz = max(z - f.z, f.y - z);
        float2 a = float2(f.x, dz);
        return length(max(a, float2(0.0f))) + min(max(a.x, a.y), 0.0f);
    }

    inline float trace_shadow(
        texture2d<float> field,
        sampler samp,
        constant Frame &F,
        float3 P,
        float3 L,
        float radius,
        float t_start,
        bool zcut
    ) {
        float3 D = L - P;
        float dist = length(D);
        if (dist < 1e-3f) {
            return 1.0f;
        }
        float3 rd = D / dist;
        float theta = max(radius / dist, 1e-3f);
        float zmax = F.misc.x + 0.5f;
        float t = t_start;
        float res = 1.0f;
        float ph = 1e10f;
        float t_end = dist - radius;
        for (int i = 0; i < 64; i += 1) {
            if (t >= t_end) {
                break;
            }
            float3 q = P + rd * t;
            if (zcut && rd.z >= 0.0f && q.z > zmax) {
                break;
            }
            float h = slab(field_at(field, samp, F, q.xy), q.z);
            if (h <= 0.0f) {
                res = min(res, h / (t * theta));
            } else {
                float y = h * h / (2.0f * ph);
                float dd = sqrt(max(h * h - y * y, 0.0f));
                res = min(res, dd / (max(t - y, 1e-3f) * theta));
            }
            ph = max(h, 1e-3f);
            if (res <= -1.0f) {
                break;
            }
            t = t + clamp(abs(h), 0.6f + t * 0.012f, 96.0f);
        }
        float k = clamp(0.5f + 0.5f * res, 0.0f, 1.0f);
        return k * k * (3.0f - 2.0f * k);
    }

    inline float shaft(texture2d<float> field, sampler samp, constant Frame &F, float2 p, Light L) {
        float2 D = L.pos.xy - p;
        float len = length(D);
        float R = max(L.pos.w * L.extra.w, 1.0f);
        const int n = 48;
        float step = len / float(n);
        float w = max(step * 0.6f, 2.0f);
        float acc = 0.0f;
        for (int i = 0; i < n; i += 1) {
            float2 q = p + D * ((float(i) + 0.5f) / float(n));
            float open = w_smoothstep(-w, w, field_at(field, samp, F, q).x);
            float r = length(L.pos.xy - q);
            acc = acc + open * R * R / (r * r + R * R);
        }
        return acc / float(n);
    }

    kernel void shadow_kernel(
        constant Frame &F [[buffer(0)]],
        device const Light *lights [[buffer(1)]],
        texture2d<float> field [[texture(0)]],
        texture2d<float> gb0 [[texture(1)]],
        texture2d_array<float, access::write> out_vis [[texture(2)]],
        texture2d_array<float, access::write> out_air [[texture(3)]],
        sampler samp [[sampler(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint2 fs = uint2(F.sf.zw);
        if (gid.x >= fs.x || gid.y >= fs.y) {
            return;
        }
        float2 p = (float2(gid) + 0.5f) / F.gs.z;
        int2 pix = clamp(int2(p), int2(0), int2(F.sf.xy) - int2(1));
        float zr = gb0.read(uint2(pix), 0).w + 0.35f;
        float3 P = float3(p, zr);
        bool shafts = (F.counts.w & 2u) != 0u;
        float4 vis[2];
        float4 air[2];
        vis[0] = float4(1.0f);
        vis[1] = float4(1.0f);
        air[0] = float4(1.0f);
        air[1] = float4(1.0f);
        uint n = min(F.counts.y, 8u);
        for (uint li = 0u; li < n; li += 1u) {
            Light L = lights[li];
            float4 lt = light_term(L, P);
            float v = 1.0f;
            if (lt.w > 1e-5f && L.pos.z > zr) {
                v = trace_shadow(field, samp, F, P, L.pos.xyz, L.pos.w * L.extra.w, 0.75f, true);
            }
            vis[li / 4u][li % 4u] = v;
            if (shafts && L.extra.x > 0.0f) {
                air[li / 4u][li % 4u] = shaft(field, samp, F, p, L);
            }
        }
        out_vis.write(vis[0], gid, 0u);
        out_air.write(air[0], gid, 0u);
        if (n > 4u) {
            out_vis.write(vis[1], gid, 1u);
            out_air.write(air[1], gid, 1u);
        }
    }
    """

    public static let giSceneShader: String = commonPrelude + """
    constant float SIGMA_EMIT = 1.5f;

    kernel void gi_scene_kernel(
        constant Frame &F [[buffer(0)]],
        device const Prim *prims [[buffer(1)]],
        device const Light *lights [[buffer(2)]],
        texture2d_array<float> vis [[texture(0)]],
        texture2d<float> extra [[texture(1)]],
        texture2d<float, access::write> out_emit [[texture(2)]],
        texture2d<float, access::write> out_occ [[texture(3)]],
        sampler lin [[sampler(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint2 gs = uint2(F.gs.xy);
        if (gid.x >= gs.x || gid.y >= gs.y) {
            return;
        }
        float texel = 1.0f / F.gs.w;
        float2 p = (float2(gid) + 0.5f) * texel;
        float4 em = float4(0.0f);
        float4 oc = float4(0.0f);
        uint n = F.counts.x;
        for (uint i = 0u; i < n; i += 1u) {
            Prim pr = prims[i];
            uint fl = flags_of(pr);
            if ((fl & (F_EMIT | F_OCC)) == 0u) {
                continue;
            }
            float2 halfSize = pr.rect.zw * 0.5f;
            float2 c = pr.rect.xy + halfSize;
            if (any(abs(p - c) > halfSize + float2(texel))) {
                continue;
            }
            float cov = clamp(0.5f - sd_rrect(p - c, halfSize, pr.radii) / texel, 0.0f, 1.0f);
            if (cov <= 0.0f) {
                continue;
            }
            if ((fl & F_EMIT) != 0u) {
                em = mix(em, float4(pr.emit.rgb * SIGMA_EMIT, SIGMA_EMIT), cov);
                oc = oc * (1.0f - cov);
            } else {
                float3 e = float3(0.0f);
                if (F.gi.z > 0.0f) {
                    float3 P = float3(p, pr.z.y);
                    int2 fp = clamp(int2(p * F.gs.z), int2(0), int2(F.sf.zw) - int2(1));
                    uint nl = min(F.counts.y, 8u);
                    for (uint li = 0u; li < nl; li += 1u) {
                        Light L = lights[li];
                        float4 lt = light_term(L, P);
                        float v = vis.read(uint2(fp), li / 4u, 0)[li % 4u];
                        e = e + L.color.rgb * lt.w * max(lt.z, 0.0f) * v;
                    }
                }
                em = em * (1.0f - cov);
                oc = mix(oc, float4(pr.albedo.rgb * e * F.gi.z, 1.0f), cov);
            }
        }
        if ((F.counts.w & 16u) != 0u) {
            float2 sz = F.sf.xy;
            float3 acc = float3(0.0f);
            for (int k = 0; k < 16; k += 1) {
                float2 o = (float2(float(k & 3), float(k >> 2)) - 1.5f) * 0.25f * texel;
                acc = acc + extra.sample(lin, (p + o) / sz, level(0.0f)).rgb;
            }
            em = float4(em.rgb + acc / 16.0f * F.ext.y, em.a);
        }
        out_emit.write(em, gid);
        out_occ.write(oc, gid);
    }
    """

    public static let giCascadeShader: String = commonPrelude + """
    struct Cascade {
        uint n;
        uint count;
        uint merge;
        uint pad1;
    };

    inline float4 gi_march(
        constant Frame &F,
        texture2d<float> scene_emit,
        texture2d<float> scene_occ,
        texture2d<float> field,
        sampler samp,
        float2 a,
        float2 b,
        float zp,
        float inner
    ) {
        float2 gsz = F.gs.xy;
        float2 D = b - a;
        float len = length(D);
        if (len < 1e-4f) {
            return float4(0.0f, 0.0f, 0.0f, 1.0f);
        }
        float2 dir = D / len;
        float3 rad = float3(0.0f);
        float T = 1.0f;
        float t = 0.0f;
        for (int i = 0; i < 48; i += 1) {
            if (t >= len || T < 0.01f) {
                break;
            }
            float2 q = a + dir * t;
            if (any(q < float2(0.0f)) || any(q > gsz)) {
                break;
            }
            float4 f = field.sample(samp, (q / F.gs.w) * F.gs.z / F.sf.zw, level(0.0f));
            float de = f.w * F.gs.w;
            float dx = f.x * F.gs.w;
            bool tall = f.z > zp + 0.5f;
            float free = min(de, abs(dx));
            if (dx < 0.0f && tall) {
                free = 0.0f;
            }
            if (free > 1.0f) {
                t = t + max(free - 0.5f, 1.0f);
                continue;
            }
            float step = min(inner, len - t);
            float2 uv = (q + dir * step * 0.5f) / gsz;
            float4 em = scene_emit.sample(samp, uv, level(0.0f));
            float4 oc = scene_occ.sample(samp, uv, level(0.0f));
            float blocks = F.gi.w * w_smoothstep(zp, zp + 1.0f, f.z);
            float sigma = em.a + oc.a * blocks;
            float3 e = em.rgb + oc.rgb * blocks;
            float tr = exp(-sigma * step);
            float k = select(step, (1.0f - tr) / sigma, sigma > 1e-4f);
            rad = rad + T * e * k;
            T = T * tr;
            t = t + step;
        }
        return float4(rad, T);
    }

    kernel void gi_cascade_kernel(
        constant Frame &F [[buffer(0)]],
        constant Cascade &C [[buffer(1)]],
        texture2d<float> scene_emit [[texture(0)]],
        texture2d<float> scene_occ [[texture(1)]],
        texture2d<float> field [[texture(2)]],
        texture2d<float> upper [[texture(3)]],
        texture2d<float> gb0 [[texture(4)]],
        texture2d<float, access::write> out_c [[texture(5)]],
        sampler samp [[sampler(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint n = C.n;
        uint s = 1u << n;
        uint b = 2u << n;
        uint2 probes = uint2(F.gs.xy) / s;
        uint2 probe = gid / b;
        if (probe.x >= probes.x || probe.y >= probes.y) {
            return;
        }
        uint2 sub = gid % b;
        uint di = sub.y * b + sub.x;
        uint nd = b * b;
        float ang = (float(di) + 0.5f) / float(nd) * RL_TAU;
        float2 dir = float2(cos(ang), sin(ang));
        float2 origin = (float2(probe) + 0.5f) * float(s);
        int2 pix = clamp(int2(origin / F.gs.w), int2(0), int2(F.sf.xy) - int2(1));
        float zp = gb0.read(uint2(pix), 0).w;
        float p4 = float(1u << (2u * n));
        float t0 = (p4 - 1.0f) / 3.0f;
        float t1 = (p4 * 4.0f - 1.0f) / 3.0f;
        float inner = max(1.0f, float(s) * 0.5f);
        float2 a = origin + dir * t0;
        float4 r = float4(0.0f);
        if (n + 1u < C.count) {
            uint us = s * 2u;
            uint ub = b * 2u;
            int2 uprobes = int2(uint2(F.gs.xy) / us);
            float2 f = origin / float(us) - 0.5f;
            int2 base = int2(floor(f));
            float2 w = fract(f);
            for (int k = 0; k < 4; k += 1) {
                int2 o = int2(k & 1, k >> 1);
                int2 q = clamp(base + o, int2(0), uprobes - int2(1));
                float wk = select(1.0f - w.x, w.x, o.x == 1) * select(1.0f - w.y, w.y, o.y == 1);
                float2 uo = (float2(q) + 0.5f) * float(us);
                float4 seg = gi_march(F, scene_emit, scene_occ, field, samp, a, uo + dir * t1, zp, inner);
                float3 far = float3(0.0f);
                if (C.merge != 0u) {
                    for (uint j = 0u; j < 4u; j += 1u) {
                        uint idx = di * 4u + j;
                        int2 tex = q * int(ub) + int2(int(idx % ub), int(idx / ub));
                        far = far + upper.read(uint2(tex), 0).rgb;
                    }
                }
                r = r + wk * float4(seg.rgb + seg.a * far * 0.25f, seg.a);
            }
        } else {
            r = gi_march(F, scene_emit, scene_occ, field, samp, a, origin + dir * t1, zp, inner);
        }
        out_c.write(r, gid);
    }
    """

    public static let giFluenceShader: String = commonPrelude + """
    kernel void gi_fluence_kernel(
        constant Frame &F [[buffer(0)]],
        texture2d<float> c0 [[texture(0)]],
        texture2d<float, access::write> out_f [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint2 gs = uint2(F.gs.xy);
        if (gid.x >= gs.x || gid.y >= gs.y) {
            return;
        }
        uint2 b = gid * 2u;
        float4 v = c0.read(b, 0) + c0.read(b + uint2(1u, 0u), 0) + c0.read(b + uint2(0u, 1u), 0)
            + c0.read(b + uint2(1u, 1u), 0);
        out_f.write(float4(v.rgb * 0.25f, 1.0f), gid);
    }
    """

    public static let compositeShader: String = commonPrelude + """
    struct CompositeVOut {
        float4 pos [[position]];
    };

    vertex CompositeVOut composite_vertex(uint vi [[vertex_id]]) {
        float2 uv = float2(float((vi << 1u) & 2u), float(vi & 2u));
        CompositeVOut o;
        o.pos = float4(uv * 2.0f - 1.0f, 0.0f, 1.0f);
        return o;
    }

    inline float4 vis_at(
        texture2d_array<float> tex,
        texture2d<float> gb0,
        constant Frame &F,
        float2 px,
        float zr,
        uint layer
    ) {
        int2 fsz = int2(F.sf.zw);
        float2 f = px * F.gs.z - 0.5f;
        int2 b = int2(floor(f));
        float2 w = fract(f);
        float4 acc = float4(0.0f);
        float wsum = 0.0f;
        float4 nearest = float4(1.0f);
        float best = 1e9f;
        for (int k = 0; k < 4; k += 1) {
            int2 o = int2(k & 1, k >> 1);
            int2 q = clamp(b + o, int2(0), fsz - int2(1));
            float4 v = tex.read(uint2(q), layer, 0);
            int2 qp = clamp(int2((float2(q) + 0.5f) / F.gs.z), int2(0), int2(F.sf.xy) - int2(1));
            float dz = abs(gb0.read(uint2(qp), 0).w - zr);
            float bw = select(1.0f - w.x, w.x, o.x == 1) * select(1.0f - w.y, w.y, o.y == 1);
            float ww = bw / (1.0f + dz * dz * 4.0f);
            acc = acc + v * ww;
            wsum = wsum + ww;
            if (dz < best) {
                best = dz;
                nearest = v;
            }
        }
        return select(nearest, acc / wsum, wsum > 1e-3f);
    }

    inline float ggx(float nh, float a) {
        float a2 = a * a;
        float d = nh * nh * (a2 - 1.0f) + 1.0f;
        return a2 / (RL_PI * d * d);
    }

    inline float3 shoulder(float3 x) {
        float k = 0.8f;
        float3 over = max(x - float3(k), float3(0.0f));
        return min(x, float3(k)) + (1.0f - k) * (float3(1.0f) - exp(-over / (1.0f - k)));
    }

    inline float3 to_srgb(float3 c) {
        float3 lo = c * 12.92f;
        float3 hi = 1.055f * pow(max(c, float3(0.0f)), float3(1.0f / 2.4f)) - 0.055f;
        return select(hi, lo, c <= float3(0.0031308f));
    }

    inline float ign(float2 p) {
        return fract(52.9829189f * fract(dot(p, float2(0.06711056f, 0.00583715f))));
    }

    fragment float4 composite_fragment(
        CompositeVOut in [[stage_in]],
        constant Frame &F [[buffer(0)]],
        device const Prim *prims [[buffer(1)]],
        device const Light *lights [[buffer(2)]],
        texture2d<float> ui_base [[texture(0)]],
        texture2d<float> ui_text [[texture(1)]],
        texture2d<float> gb0 [[texture(2)]],
        texture2d<uint> gb1 [[texture(3)]],
        texture2d_array<float> vis [[texture(4)]],
        texture2d_array<float> air [[texture(5)]],
        texture2d<float> flu [[texture(6)]],
        texture2d<float> field [[texture(7)]],
        sampler samp [[sampler(0)]]
    ) {
        float2 px = in.pos.xy;
        uint2 ip = uint2(px);
        float4 base = ui_base.read(ip, 0);
        float4 text = ui_text.read(ip, 0);
        float4 g = gb0.read(ip, 0);
        uint id = gb1.read(ip, 0).r;
        float sd = g.x;
        float2 grad = g.yz;
        float zr = g.w;

        float3 n = float3(0.0f, 0.0f, 1.0f);
        float gloss = F.bg.x;
        float rough = F.bg.y;
        uint fl = 0u;
        float rim = 0.0f;
        bool emissive = false;
        if (id > 0u) {
            Prim pr = prims[id - 1u];
            fl = flags_of(pr);
            gloss = pr.mat.x;
            rough = pr.mat.y;
            emissive = (fl & F_EMIT) != 0u;
            if ((fl & F_RAISED) != 0u) {
                float bw = max(pr.z.z, 0.5f);
                float x = clamp(-sd / bw, 0.0f, 1.0f);
                float slope = pr.z.w / bw * 3.0f * (1.0f - x) * (1.0f - x);
                n = normalize(float3(grad * slope, 1.0f));
            }
            rim = F.bg.w * (1.0f - w_smoothstep(0.0f, 2.0f, -sd)) * select(0.0f, 1.0f, (fl & F_OCC) != 0u);
        }

        float3 P = float3(px, zr + 0.35f);
        float3 irr = F.ambient.rgb;
        if ((F.counts.w & 8u) != 0u) {
            float4 f = field.sample(samp, px * F.gs.z / F.sf.zw, level(0.0f));
            float below = max(f.z - zr, 0.0f);
            if (below > 0.0f && f.x > 0.0f) {
                float reach = below * 3.0f + 6.0f;
                float occ = 1.0f - w_smoothstep(0.0f, reach, f.x);
                irr = irr * (1.0f - F.bg.z * occ * occ);
            }
        }

        float3 diffuse = float3(0.0f);
        float3 spec = float3(0.0f);
        float3 airc = float3(0.0f);
        uint nl = min(F.counts.y, 8u);
        float4 v0 = vis_at(vis, gb0, F, px, zr, 0u);
        float4 v1 = float4(1.0f);
        if (nl > 4u) {
            v1 = vis_at(vis, gb0, F, px, zr, 1u);
        }
        bool shafts = (F.counts.w & 2u) != 0u;
        float4 a0 = float4(1.0f);
        float4 a1 = float4(1.0f);
        if (shafts) {
            a0 = vis_at(air, gb0, F, px, zr, 0u);
            if (nl > 4u) {
                a1 = vis_at(air, gb0, F, px, zr, 1u);
            }
        }
        for (uint li = 0u; li < nl; li += 1u) {
            Light L = lights[li];
            float4 lt = light_term(L, P);
            float3 l = lt.xyz;
            float v = (li >= 4u) ? v1[li % 4u] : v0[li % 4u];
            float ndl = max(dot(n, l), 0.0f);
            float3 e = L.color.rgb * lt.w * v;
            float front = select(1.0f, 0.0f, L.extra.x > 0.0f);
            diffuse = diffuse + e * ndl * front;

            float3 h = normalize(l + float3(0.0f, 0.0f, 1.0f));
            float dist = length(L.pos.xyz - P);
            float a = clamp(rough * rough + L.pos.w / (2.0f * max(dist, 1e-4f)), 0.02f, 1.0f);
            float energy = (rough * rough) / a;
            float fres = 0.04f + 0.96f * pow(clamp(1.0f - max(dot(l, h), 0.0f), 0.0f, 1.0f), 5.0f);
            spec = spec + e * ndl * ggx(max(dot(n, h), 0.0f), a) * energy * fres * gloss * L.extra.z * front;

            float2 lxy = L.pos.xy - px;
            float face = max(dot(grad, lxy / max(length(lxy), 1e-3f)), 0.0f);
            spec = spec + e * rim * face * face * max(l.z, 0.15f);
            float d2 = length(lxy);
            if (shafts && L.extra.x > 0.0f) {
                float av = (li >= 4u) ? a1[li % 4u] : a0[li % 4u];
                float over = select(1.0f, F.misc.w, zr > 0.5f);
                float fall = 1.5f * RL_REF / (d2 + 1.5f * RL_REF);
                airc = airc + L.color.rgb * L.extra.x * av * over * fall * fall;
            }
            if (L.extra.y > 0.0f) {
                float r = max(L.pos.w, 1.0f);
                float q = r * r / (d2 * d2 + r * r);
                airc = airc + L.color.rgb * L.extra.y * (q * sqrt(q) + 0.05f * q);
            }
        }

        float3 gi_irr = float3(0.0f);
        if ((F.counts.w & 1u) != 0u) {
            float3 flv = flu.sample(samp, px * F.gs.w / F.gs.xy, level(0.0f)).rgb;
            gi_irr = flv * F.gi.x;
            airc = airc + flv * F.gi.y;
        }

        float3 lightf = irr + diffuse + gi_irr;
        float3 col = base.rgb * irr + (base.rgb + float3(F.ext.x)) * (diffuse + gi_irr) + spec;
        if (emissive) {
            col = base.rgb * max(lightf, float3(1.0f)) + spec * 0.25f;
        }

        float3 tf = mix(float3(1.0f), clamp(lightf, float3(F.text.x), float3(F.text.y)), F.text.z);
        col = col * (1.0f - text.a) + text.rgb * tf + spec * text.a * F.text.w;
        col = col + airc * (1.0f - 0.6f * text.a);

        float3 o = shoulder(col * F.ambient.w);
        if ((F.counts.w & 4u) != 0u) {
            o = to_srgb(o);
            float dn = ign(px + float2(F.misc.z * 5.588238f, 0.0f)) + ign(px.yx + float2(17.0f, F.misc.z)) - 1.0f;
            o = o + float3(dn / 255.0f);
        }
        return float4(o, 1.0f);
    }
    """

    public static let glassShader: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct GlassU {
        float4 size;     // w, h, glass count, light count
        float4 misc;     // pyramid levels, env strength, shadow, caustic
        float4 shadow;   // shadow offset xy, blur, unused
    };

    struct Glass {
        float4 a;        // rect x, y, w, h
        float4 b;        // second shape rect (w = 0: none)
        float4 r;        // radius a, radius b, smooth-union k, morph a->b
        float4 p0;       // thickness, bevel, gap, dome
        float4 p1;       // ior, dispersion (n400 - n700), frost, presence
        float4 tint;     // absorption per px rgb, glow from GI
    };

    struct GLight {
        float4 pos;      // x, y, z, radius
        float4 color;    // rgb intensity, unused
    };

    struct GlassVOut {
        float4 pos [[position]];
    };

    constant float GL_PI = 3.14159265f;

    inline float g_smoothstep(float e0, float e1, float x) {
        if (e0 == e1) {
            return x >= e1 ? 1.0f : 0.0f;
        }
        float t = clamp((x - e0) / (e1 - e0), 0.0f, 1.0f);
        return t * t * (3.0f - 2.0f * t);
    }

    vertex GlassVOut glass_vertex(uint vi [[vertex_id]]) {
        float2 uv = float2(float((vi << 1u) & 2u), float(vi & 2u));
        GlassVOut o;
        o.pos = float4(uv * 2.0f - 1.0f, 0.0f, 1.0f);
        return o;
    }

    // Apple's continuous corner (clip.wgsl `sd_continuous` / `sd_rounded`).
    constant float GL_CONTINUOUS_K = 1.52866483f;
    inline float g_sd_continuous(float2 p, float2 halfSize, float r) {
        float e = GL_CONTINUOUS_K * r;
        float2 q = halfSize - abs(p);
        float2 v = float2(e) - q;
        if (v.x <= 0.0f || v.y <= 0.0f) { return max(-q.x, -q.y); }
        float u = atan2(v.y, v.x) * (4.0f / GL_PI) - 1.0f;
        float u2 = u * u;
        return length(v) - e * (1.14602295f + u2 * (-0.37573161f + u2 * (0.30796609f - 0.07724354f * u2)));
    }

    inline float g_sd_rrect(float2 p, float2 halfSize, float r0) {
        if (r0 < 0.0f) { return g_sd_continuous(p, halfSize, min(-r0, min(halfSize.x, halfSize.y))); }
        float r = min(r0, min(halfSize.x, halfSize.y));
        float2 q = abs(p) - halfSize + float2(r);
        return min(max(q.x, q.y), 0.0f) + length(max(q, float2(0.0f))) - r;
    }

    inline float g_smin(float a, float b, float k) {
        if (k <= 0.0f) {
            return min(a, b);
        }
        float h = max(k - abs(a - b), 0.0f) / k;
        return min(a, b) - h * h * k * 0.25f;
    }

    inline float g_sdf(Glass g, float2 p) {
        float da = g_sd_rrect(p - (g.a.xy + g.a.zw * 0.5f), g.a.zw * 0.5f, g.r.x);
        if (g.b.z <= 0.0f) {
            return da;
        }
        float db = g_sd_rrect(p - (g.b.xy + g.b.zw * 0.5f), g.b.zw * 0.5f, g.r.y);
        return mix(g_smin(da, db, g.r.z), db, g.r.w);
    }

    inline float g_dome(Glass g, float2 p) {
        float2 halfSize = g.a.zw * 0.5f;
        float ri = min(halfSize.x, halfSize.y);
        float dc = g_sd_rrect(p - (g.a.xy + halfSize), halfSize, ri);
        float x = clamp(-dc / max(ri, 1e-4f), 0.0f, 1.0f);
        return g.p0.w * g.p1.w * x * x * (3.0f - 2.0f * x) * (1.0f - g.r.w);
    }

    inline float g_height_d(Glass g, float2 p, float d) {
        float thick = g.p0.x * g.p1.w;
        float bevel = max(g.p0.y, 1.0f);
        float x = clamp(-d / bevel, 0.0f, 1.0f);
        float prof = sqrt(max(1.0f - (1.0f - x) * (1.0f - x), 0.0f));
        return g.p0.z + thick * (0.04f + 0.96f * prof) + g_dome(g, p);
    }

    inline float g_height(Glass g, float2 p) {
        return g_height_d(g, p, g_sdf(g, p));
    }

    inline float3 g_normal_at(Glass g, float2 p) {
        float e = 0.5f;
        float hx = g_height(g, p + float2(e, 0.0f)) - g_height(g, p - float2(e, 0.0f));
        float hy = g_height(g, p + float2(0.0f, e)) - g_height(g, p - float2(0.0f, e));
        return normalize(float3(-hx / (2.0f * e), -hy / (2.0f * e), 1.0f));
    }

    inline float g_fresnel(float cos_i, float n1, float n2) {
        float ci = clamp(cos_i, 0.0f, 1.0f);
        float s2 = (n1 / n2) * (n1 / n2) * (1.0f - ci * ci);
        if (s2 >= 1.0f) {
            return 1.0f;
        }
        float ct = sqrt(1.0f - s2);
        float rs = (n1 * ci - n2 * ct) / (n1 * ci + n2 * ct);
        float rp = (n1 * ct - n2 * ci) / (n1 * ct + n2 * ci);
        return 0.5f * (rs * rs + rp * rp);
    }

    inline float3 g_env(constant GlassU &u, float3 d) {
        float up = clamp(d.z, 0.0f, 1.0f);
        float3 c = mix(float3(0.006f, 0.007f, 0.011f), float3(0.030f, 0.034f, 0.046f), up);
        float3 box = normalize(float3(-0.42f, -0.58f, 0.70f));
        c = c + float3(0.85f, 0.88f, 0.95f) * g_smoothstep(0.80f, 0.97f, dot(d, box)) * 4.0f;
        float3 strip = normalize(float3(0.80f, 0.10f, 0.59f));
        c = c + float3(0.55f, 0.62f, 0.80f) * g_smoothstep(0.93f, 0.99f, dot(d, strip)) * 2.0f;
        return c * u.misc.y;
    }

    inline float3 g_bspline(texture2d<float> pyramid, sampler samp, float2 uv, float lod) {
        float2 dim = float2(float(pyramid.get_width(uint(lod))), float(pyramid.get_height(uint(lod))));
        float2 st = uv * dim - 0.5f;
        float2 i = floor(st);
        float2 f = st - i;
        float2 w0 = (1.0f - f) * (1.0f - f) * (1.0f - f) / 6.0f;
        float2 w1 = (4.0f - 6.0f * f * f + 3.0f * f * f * f) / 6.0f;
        float2 w2 = (1.0f + 3.0f * f + 3.0f * f * f - 3.0f * f * f * f) / 6.0f;
        float2 w3 = f * f * f / 6.0f;
        float2 g0 = w0 + w1;
        float2 g1 = w2 + w3;
        float2 h0 = (i + float2(-1.0f) + w1 / g0 + 0.5f) / dim;
        float2 h1 = (i + float2(1.0f) + w3 / g1 + 0.5f) / dim;
        float3 a = pyramid.sample(samp, float2(h0.x, h0.y), level(lod)).rgb;
        float3 b = pyramid.sample(samp, float2(h1.x, h0.y), level(lod)).rgb;
        float3 c = pyramid.sample(samp, float2(h0.x, h1.y), level(lod)).rgb;
        float3 d = pyramid.sample(samp, float2(h1.x, h1.y), level(lod)).rgb;
        return g0.y * (g0.x * a + g1.x * b) + g1.y * (g0.x * c + g1.x * d);
    }

    inline float3 g_ui_at(
        constant GlassU &u,
        texture2d<float> backdrop,
        texture2d<float> pyramid,
        sampler samp,
        float2 p,
        float radius
    ) {
        float2 uv = p / u.size.xy;
        float3 sharp = backdrop.sample(samp, uv, level(0.0f)).rgb;
        if (radius <= 1.0f) {
            return sharp;
        }
        float maxLod = max(u.misc.x - 1.0f, 0.0f);
        float lod = clamp(log2(radius) - 1.0f, 0.0f, maxLod);
        float l0 = floor(lod);
        float3 blur = mix(
            g_bspline(pyramid, samp, uv, l0),
            g_bspline(pyramid, samp, uv, min(l0 + 1.0f, maxLod)),
            lod - l0
        );
        return mix(sharp, blur, g_smoothstep(1.0f, 3.0f, radius));
    }

    inline float g_shadow(constant GlassU &u, Glass g, float2 p) {
        float blur = max(u.shadow.z, 1e-3f);
        float d = g_sdf(g, p - u.shadow.xy * g.p1.w);
        float s = 1.0f - g_smoothstep(-blur, blur * 1.6f, d);
        float contact = 1.0f - g_smoothstep(0.0f, 10.0f, g_sdf(g, p));
        return clamp((s * 0.7f + contact * 0.3f) * u.misc.z * g.p1.w, 0.0f, 0.9f);
    }

    inline float3 g_floor_at(
        constant GlassU &u,
        texture2d<float> backdrop,
        texture2d<float> pyramid,
        texture2d<float> fluence,
        sampler samp,
        Glass g,
        float2 q,
        float radius
    ) {
        float3 c = g_ui_at(u, backdrop, pyramid, samp, q, radius);
        float dq = g_sdf(g, q);
        float sh = g_shadow(u, g, q);
        float3 flu = fluence.sample(samp, q / u.size.xy, level(0.0f)).rgb;
        float bevel = max(g.p0.y, 1.0f);
        float rz = (-dq - bevel * 0.45f) / (bevel * 0.22f);
        float ring = exp(-(rz * rz)) * select(0.0f, 1.0f, dq < 0.0f);
        c = c * (1.0f - sh) + (flu * 0.55f + float3(0.01f)) * ring * u.misc.w * g.p1.w;
        return c;
    }

    struct GlassPath {
        float2 q;
        float3 dir;
        float len;
        float t_out;
        bool floor;
    };

    inline GlassPath g_trace(Glass g, float2 p, float3 n, float zt, float ior) {
        GlassPath o;
        o.q = p;
        o.dir = float3(0.0f, 0.0f, 1.0f);
        float3 v = float3(0.0f, 0.0f, -1.0f);
        float3 r1 = refract(v, n, 1.0f / ior);
        float s = (zt - g.p0.z) / max(-r1.z, 1e-3f);
        float2 pb = p + r1.xy * s;
        float3 up = float3(0.0f, 0.0f, 1.0f);
        float ci = -r1.z;
        float3 r2 = refract(r1, up, ior);
        if (dot(r2, r2) > 0.0f) {
            o.floor = true;
            o.q = pb + r2.xy * (g.p0.z / max(-r2.z, 0.05f));
            o.len = s;
            o.t_out = 1.0f - g_fresnel(ci, ior, 1.0f);
            return o;
        }
        float3 r1b = reflect(r1, up);
        float t = (zt - g.p0.z) / max(r1b.z, 1e-3f);
        for (int k = 0; k < 4; k += 1) {
            t = (g_height(g, pb + r1b.xy * t) - g.p0.z) / max(r1b.z, 1e-3f);
        }
        float2 pe = pb + r1b.xy * t;
        float3 ne = g_normal_at(g, pe);
        float3 r3 = refract(r1b, -ne, ior);
        o.floor = false;
        o.len = s + t;
        if (dot(r3, r3) > 0.0f) {
            o.dir = r3;
            o.t_out = 1.0f - g_fresnel(dot(r1b, ne), ior, 1.0f);
        } else {
            o.dir = reflect(r1b, ne);
            o.t_out = 0.25f;
        }
        return o;
    }

    inline float3 g_spectrum(int i) {
        const float3 w[8] = {
            float3(0.20f, 0.00f, 0.62f),
            float3(0.12f, 0.02f, 1.00f),
            float3(0.00f, 0.22f, 0.86f),
            float3(0.00f, 0.62f, 0.30f),
            float3(0.18f, 0.92f, 0.00f),
            float3(0.70f, 0.62f, 0.00f),
            float3(1.00f, 0.20f, 0.00f),
            float3(0.62f, 0.00f, 0.00f),
        };
        return w[i];
    }

    inline float g_ggx(float nh, float a) {
        float a2 = a * a;
        float d = nh * nh * (a2 - 1.0f) + 1.0f;
        return a2 / (GL_PI * d * d);
    }

    inline float4 g_shade(
        constant GlassU &u,
        device const GLight *glights,
        texture2d<float> backdrop,
        texture2d<float> pyramid,
        texture2d<float> fluence,
        sampler samp,
        Glass g,
        float2 p,
        float spec_var,
        float fp
    ) {
        float d = g_sdf(g, p);
        float cov = clamp(0.5f - d, 0.0f, 1.0f);
        if (cov <= 0.0f) {
            return float4(0.0f);
        }
        float zt = g_height_d(g, p, d);
        float3 n = g_normal_at(g, p);
        float ior = g.p1.x;
        float disp = g.p1.y;
        float frost = g.p1.z;
        float B = disp / (1.0f / (0.4f * 0.4f) - 1.0f / (0.7f * 0.7f));
        float A = ior - B / (0.55f * 0.55f);
        float n_lo = A + B / (0.7f * 0.7f);
        float n_hi = A + B / (0.4f * 0.4f);
        GlassPath a = g_trace(g, p, n, zt, n_lo);
        GlassPath b = g_trace(g, p, n, zt, n_hi);
        float3 trans = float3(0.0f);
        float3 wsum = float3(0.0f);
        for (int i = 0; i < 8; i += 1) {
            float k = float(i) / 7.0f;
            float3 w = g_spectrum(i);
            float3 c;
            float len;
            float tout;
            if (a.floor && b.floor) {
                float2 q = mix(b.q, a.q, k);
                len = mix(b.len, a.len, k);
                tout = mix(b.t_out, a.t_out, k);
                c = g_floor_at(u, backdrop, pyramid, fluence, samp, g, q, max(frost * (6.0f + len * 0.35f), fp));
            } else if (!a.floor && !b.floor) {
                float3 dir = normalize(mix(b.dir, a.dir, k));
                len = mix(b.len, a.len, k);
                tout = mix(b.t_out, a.t_out, k);
                c = g_env(u, dir);
            } else {
                GlassPath pa = (k > 0.5f) ? a : b;
                len = pa.len;
                tout = pa.t_out;
                if (pa.floor) {
                    c = g_floor_at(u, backdrop, pyramid, fluence, samp, g, pa.q, max(frost * (6.0f + len * 0.35f), fp));
                } else {
                    c = g_env(u, pa.dir);
                }
            }
            float3 beer = exp(-g.tint.rgb * len);
            trans = trans + w * c * beer * tout;
            wsum = wsum + w;
        }
        trans = trans / wsum;

        float3 v_up = float3(0.0f, 0.0f, 1.0f);
        float F = g_fresnel(n.z, 1.0f, ior);
        float3 rr = reflect(float3(0.0f, 0.0f, -1.0f), n);
        float reach = min(zt * length(rr.xy) / max(-rr.z, 1e-3f), zt * 4.0f);
        float3 below = g_ui_at(u, backdrop, pyramid, samp, p + normalize(rr.xy + float2(1e-5f)) * reach, 4.0f + reach * 0.08f);
        float3 refl = mix(g_env(u, rr), below, g_smoothstep(0.05f, -0.15f, rr.z));
        float3 flu = fluence.sample(samp, p / u.size.xy, level(0.0f)).rgb;
        float3 col = trans * (1.0f - F) + refl * F;
        col = col + flu * frost * 0.10f;

        float3 P = float3(p, zt);
        float rough = mix(0.035f, 0.32f, frost);
        float3 spec = float3(0.0f);
        int nl = int(u.size.w);
        for (int i = 0; i < nl; i += 1) {
            GLight L = glights[i];
            float3 D = L.pos.xyz - P;
            float dist = length(D);
            float3 l = D / max(dist, 1e-3f);
            float ndl = max(dot(n, l), 0.0f);
            if (ndl <= 0.0f) {
                continue;
            }
            float3 h = normalize(l + v_up);
            float a0 = sqrt(rough * rough + spec_var);
            float al = clamp(a0 + L.pos.w / (2.0f * max(dist, 1e-4f)), 0.02f, 1.0f);
            float energy = (a0 * a0) / (al * al);
            float fh = g_fresnel(max(dot(l, h), 0.0f), 1.0f, ior);
            float fall = 1.0f / (1.0f + dist * dist / (L.pos.w * L.pos.w + 1.0f));
            spec = spec + L.color.rgb * g_ggx(max(dot(n, h), 0.0f), al) * energy * fh * ndl * fall;
        }
        col = col + spec;

        float bevel = max(g.p0.y, 1.0f);
        float rimT = 1.0f - clamp(-d / bevel, 0.0f, 1.0f);
        float rim = rimT * rimT;
        col = col + flu * rim * g.tint.w;
        return float4(col, cov);
    }

    fragment float4 glass_fragment(
        GlassVOut in [[stage_in]],
        constant GlassU &u [[buffer(0)]],
        device const Glass *glass [[buffer(1)]],
        device const GLight *glights [[buffer(2)]],
        texture2d<float> backdrop [[texture(0)]],
        texture2d<float> pyramid [[texture(1)]],
        texture2d<float> fluence [[texture(2)]]
    ) {
        constexpr sampler samp(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
        float2 p = in.pos.xy;
        float3 base = backdrop.read(uint2(p), 0).rgb;
        int ng = int(u.size.z);
        float reach = u.shadow.z * 2.5f + length(u.shadow.xy) + 12.0f;
        float3 col = base;
        for (int gk = 0; gk < ng; gk += 1) {
            Glass g = glass[gk];
            float d = g_sdf(g, p);
            float3 nv = float3(0.0f, 0.0f, 1.0f);
            float2 q0 = p;
            if (g.p1.w > 0.0f && d < 8.0f) {
                nv = g_normal_at(g, p);
                GlassPath tr = g_trace(g, p, nv, g_height(g, p), g.p1.x);
                q0 = tr.floor ? tr.q : (p + tr.dir.xy * 400.0f);
            }
            float3 dn = dfdx(nv);
            float3 dm = dfdy(nv);
            float spec_var = min(2.0f * 0.25f * (dot(dn, dn) + dot(dm, dm)), 0.18f);
            float fpx = max(length(dfdx(q0)), length(dfdy(q0)));
            float fp = clamp(fpx * 0.5f - 0.5f, 0.0f, 24.0f);
            if (g.p1.w > 0.0f && d <= reach) {
                float3 outside = col * (1.0f - g_shadow(u, g, p));
                float bevel = max(g.p0.y, 1.0f);
                if (d > 1.0f) {
                    col = outside;
                } else if (-d < bevel + 1.0f) {
                    const float2 o[4] = {
                        float2(-0.125f, -0.375f),
                        float2(0.375f, -0.125f),
                        float2(0.125f, 0.375f),
                        float2(-0.375f, 0.125f)
                    };
                    float4 acc = float4(0.0f);
                    for (int k = 0; k < 4; k += 1) {
                        float4 s = g_shade(u, glights, backdrop, pyramid, fluence, samp, g, p + o[k], spec_var, fp);
                        acc = acc + float4(s.rgb * s.a, s.a);
                    }
                    acc = acc * 0.25f;
                    col = outside * (1.0f - acc.a) + acc.rgb;
                } else {
                    float4 s = g_shade(u, glights, backdrop, pyramid, fluence, samp, g, p, spec_var, fp);
                    col = mix(outside, s.rgb, s.a);
                }
            }
        }
        return float4(col, 1.0f);
    }

    fragment float4 glass_pyramid_fragment(
        GlassVOut in [[stage_in]],
        texture2d<float> src [[texture(0)]]
    ) {
        constexpr sampler ssamp(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
        float2 sz = float2(float(src.get_width(0)), float(src.get_height(0)));
        float2 uv = in.pos.xy * 2.0f / sz;
        float2 t = 1.0f / sz;
        float3 a = src.sample(ssamp, uv + t * float2(-2.0f, -2.0f), level(0.0f)).rgb;
        float3 b = src.sample(ssamp, uv + t * float2(0.0f, -2.0f), level(0.0f)).rgb;
        float3 c = src.sample(ssamp, uv + t * float2(2.0f, -2.0f), level(0.0f)).rgb;
        float3 d = src.sample(ssamp, uv + t * float2(-2.0f, 0.0f), level(0.0f)).rgb;
        float3 e = src.sample(ssamp, uv, level(0.0f)).rgb;
        float3 f = src.sample(ssamp, uv + t * float2(2.0f, 0.0f), level(0.0f)).rgb;
        float3 g = src.sample(ssamp, uv + t * float2(-2.0f, 2.0f), level(0.0f)).rgb;
        float3 h = src.sample(ssamp, uv + t * float2(0.0f, 2.0f), level(0.0f)).rgb;
        float3 i = src.sample(ssamp, uv + t * float2(2.0f, 2.0f), level(0.0f)).rgb;
        float3 j = src.sample(ssamp, uv + t * float2(-1.0f, -1.0f), level(0.0f)).rgb;
        float3 k = src.sample(ssamp, uv + t * float2(1.0f, -1.0f), level(0.0f)).rgb;
        float3 l = src.sample(ssamp, uv + t * float2(-1.0f, 1.0f), level(0.0f)).rgb;
        float3 m = src.sample(ssamp, uv + t * float2(1.0f, 1.0f), level(0.0f)).rgb;
        float3 o = e * 0.125f + (a + c + g + i) * 0.03125f + (b + d + f + h) * 0.0625f + (j + k + l + m) * 0.125f;
        return float4(o, 1.0f);
    }
    """

    #if canImport(Metal)
    public static var resourceBundle: Bundle { Bundle.module }

    public static var precompileEntries: [PrecompiledMetallib.ShaderEntry] {
        [
            PrecompiledMetallib.ShaderEntry(name: "light_gbuffer", source: gbufferShader, requiredFunction: "gbuffer_vertex"),
            PrecompiledMetallib.ShaderEntry(name: "light_field", source: fieldShader, requiredFunction: "field_kernel"),
            PrecompiledMetallib.ShaderEntry(name: "light_shadow", source: shadowShader, requiredFunction: "shadow_kernel"),
            PrecompiledMetallib.ShaderEntry(name: "light_gi_scene", source: giSceneShader, requiredFunction: "gi_scene_kernel"),
            PrecompiledMetallib.ShaderEntry(name: "light_gi_cascade", source: giCascadeShader, requiredFunction: "gi_cascade_kernel"),
            PrecompiledMetallib.ShaderEntry(name: "light_gi_fluence", source: giFluenceShader, requiredFunction: "gi_fluence_kernel"),
            PrecompiledMetallib.ShaderEntry(name: "light_composite", source: compositeShader, requiredFunction: "composite_vertex"),
            PrecompiledMetallib.ShaderEntry(name: "light_glass", source: glassShader, requiredFunction: "glass_vertex"),
        ]
    }
    #endif
}
