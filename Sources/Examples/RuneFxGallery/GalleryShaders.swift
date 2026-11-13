#if canImport(Metal)
import Metal
#endif

/// Faithful Metal Shading Language ports of `crates/rune-fx/examples/gallery/ui.wgsl`
/// and `crates/rune-fx/examples/gallery/resolve.wgsl`.
enum GalleryShaders {
    static let uiMetalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct UiInst {
        float4 rect;   // px x, y, w, h
        float4 p;      // radius px, border px, kind (0 rect, 1 text, 2 shadow), sigma px
        float4 fill;   // premultiplied linear (top)
        float4 fill2;  // premultiplied linear (bottom)
        float4 border; // premultiplied linear
        float4 uv;     // atlas uv rect
        float4 vp;     // viewport px
    };

    struct UiVOut {
        float4 pos [[position]];
        uint id [[flat]];
        float2 px;
    };

    vertex UiVOut ui_vs(
        uint vi [[vertex_id]],
        uint ii [[instance_id]],
        constant UiInst* us [[buffer(0)]]
    ) {
        UiInst u = us[ii];
        float m = 1.0;
        if (u.p.z > 1.5) {
            m = u.p.w * 3.5 + 1.0;
        }
        float2 corner = float2(float(vi & 1u), float((vi >> 1u) & 1u));
        float2 px = u.rect.xy - m + (u.rect.zw + 2.0 * m) * corner;
        UiVOut o;
        o.pos = float4(px.x / u.vp.x * 2.0 - 1.0, 1.0 - px.y / u.vp.y * 2.0, 0.0, 1.0);
        o.id = ii;
        o.px = px;
        return o;
    }

    static inline float sd_rrect(float2 q, float2 half, float r) {
        float rr = clamp(r, 0.0, min(half.x, half.y));
        float2 k = abs(q) - half + rr;
        return length(max(k, float2(0.0))) + min(max(k.x, k.y), 0.0) - rr;
    }

    static inline float erf_approx(float x) {
        float x2 = x * x;
        float a = 0.147;
        float v = sqrt(1.0 - exp(-x2 * (1.2732395 + a * x2) / (1.0 + a * x2)));
        return (x >= 0.0) ? v : -v;
    }

    fragment float4 ui_fs(
        UiVOut in [[stage_in]],
        constant UiInst* us [[buffer(0)]],
        texture2d<float> atlas [[texture(0)]],
        sampler smp [[sampler(0)]]
    ) {
        UiInst u = us[in.id];
        float2 half = u.rect.zw * 0.5;
        float2 q = in.px - u.rect.xy - half;
        float d = sd_rrect(q, half, u.p.x);
        int kind = int(u.p.z + 0.5);
        if (kind == 1) {
            float2 uv = mix(u.uv.xy, u.uv.zw, (in.px - u.rect.xy) / u.rect.zw);
            float a = atlas.sample(smp, uv, level(0.0)).r;
            return u.fill * pow(a, 0.85);
        }
        if (kind == 2) {
            float a = 0.5 - 0.5 * erf_approx(d / (max(u.p.w, 0.1) * 1.41421));
            return u.fill * a;
        }
        float cov = clamp(0.5 - d, 0.0, 1.0);
        float t = clamp((in.px.y - u.rect.y) / max(u.rect.w, 1.0), 0.0, 1.0);
        float4 fill = mix(u.fill, u.fill2, t);
        float bw = u.p.y;
        float4 o = fill * cov;
        if (bw > 0.0) {
            float inner = clamp(0.5 - (d + bw), 0.0, 1.0);
            float band = cov - inner;
            o = o * (1.0 - u.border.a * band) + u.border * band;
        }
        return o;
    }
    """

    static let resolveMetalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct RV {
        float4 pos [[position]];
    };

    vertex RV vs_full(uint vi [[vertex_id]]) {
        float2 p = float2(float((vi << 1u) & 2u), float(vi & 2u));
        RV o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    static inline uint pcg(uint v) {
        uint s = v * 747796405u + 2891336453u;
        uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
        return (w >> 22u) ^ w;
    }

    static inline float u01(uint n) {
        return float(pcg(n) >> 8u) * (1.0 / 16777216.0);
    }

    static inline float3 to_srgb(float3 c) {
        float3 lo = c * 12.92;
        float3 hi = 1.055 * pow(max(c, float3(0.0)), float3(1.0 / 2.4)) - 0.055;
        return select(hi, lo, c <= float3(0.0031308));
    }

    fragment float4 fs_resolve(
        RV in [[stage_in]],
        texture2d<float> scene [[texture(0)]]
    ) {
        uint2 ip = uint2(in.pos.xy);
        float4 c = scene.read(ip, 0);
        float n = u01(ip.x + pcg(ip.y)) + u01(ip.x * 7919u + pcg(ip.y + 104729u)) - 1.0;
        float3 s = to_srgb(clamp(c.rgb, float3(0.0), float3(1.0))) + float3(n / 255.0);
        return float4(clamp(s, float3(0.0), float3(1.0)), 1.0);
    }
    """
}
