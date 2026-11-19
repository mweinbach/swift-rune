struct Glass {
    vec4 a;        // rect x, y, w, h
    vec4 b;        // second shape rect (w = 0: none)
    vec4 r;        // radius a, radius b, smooth-union k, morph a->b
    vec4 p0;       // thickness, bevel, gap, dome
    vec4 p1;       // ior, dispersion (n400 - n700), frost, presence
    vec4 tint;     // absorption per px rgb, glow from GI
};

struct GLight {
    vec4 pos;      // x, y, z, radius
    vec4 color;    // rgb intensity, unused
};


layout(std140) uniform RunePass {
    vec4 size, misc, shadow;
    Glass glass[8];
    GLight glights[32];
} u;
uniform sampler2D uTex0, uTex1, uTex2, uTex3, uTex4, uTex5, uTex6, uTex7, uTex8;
out vec4 result;
float choose(float a, float b, bool c) { return c ? b : a; }
vec4 pyramidSample(vec2 topUV, int level) {
    vec2 uv = vec2(topUV.x, 1.0 - topUV.y);
    switch(level) {
    case 0: return texture(uTex2, uv);
    case 1: return texture(uTex3, uv);
    case 2: return texture(uTex4, uv);
    case 3: return texture(uTex5, uv);
    case 4: return texture(uTex6, uv);
    case 5: return texture(uTex7, uv);
    default: return texture(uTex8, uv);
    }
}
const float glassPI = 3.14159265;

float g_smoothstep(float e0, float e1, float x) {
    if (e0 == e1) {
        return x >= e1 ? 1.0 : 0.0;
    }
    float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

const float GL_CONTINUOUS_K = 1.52866483;
float g_sd_continuous(vec2 p, vec2 halfSize, float r) {
    float e = GL_CONTINUOUS_K * r;
    vec2 q = halfSize - abs(p);
    vec2 v = vec2(e) - q;
    if (v.x <= 0.0 || v.y <= 0.0) { return max(-q.x, -q.y); }
    float u = atan(v.y, v.x) * (4.0 / glassPI) - 1.0;
    float u2 = u * u;
    return length(v) - e * (1.14602295 + u2 * (-0.37573161 + u2 * (0.30796609 - 0.07724354 * u2)));
}

float g_sd_rrect(vec2 p, vec2 halfSize, float r0) {
    if (r0 < 0.0) { return g_sd_continuous(p, halfSize, min(-r0, min(halfSize.x, halfSize.y))); }
    float r = min(r0, min(halfSize.x, halfSize.y));
    vec2 q = abs(p) - halfSize + vec2(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

float g_smin(float a, float b, float k) {
    if (k <= 0.0) {
        return min(a, b);
    }
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

float g_sdf(Glass g, vec2 p) {
    float da = g_sd_rrect(p - (g.a.xy + g.a.zw * 0.5), g.a.zw * 0.5, g.r.x);
    if (g.b.z <= 0.0) {
        return da;
    }
    float db = g_sd_rrect(p - (g.b.xy + g.b.zw * 0.5), g.b.zw * 0.5, g.r.y);
    return mix(g_smin(da, db, g.r.z), db, g.r.w);
}

float g_dome(Glass g, vec2 p) {
    vec2 halfSize = g.a.zw * 0.5;
    float ri = min(halfSize.x, halfSize.y);
    float dc = g_sd_rrect(p - (g.a.xy + halfSize), halfSize, ri);
    float x = clamp(-dc / max(ri, 1e-4), 0.0, 1.0);
    return g.p0.w * g.p1.w * x * x * (3.0 - 2.0 * x) * (1.0 - g.r.w);
}

float g_height_d(Glass g, vec2 p, float d) {
    float thick = g.p0.x * g.p1.w;
    float bevel = max(g.p0.y, 1.0);
    float x = clamp(-d / bevel, 0.0, 1.0);
    float prof = sqrt(max(1.0 - (1.0 - x) * (1.0 - x), 0.0));
    return g.p0.z + thick * (0.04 + 0.96 * prof) + g_dome(g, p);
}

float g_height(Glass g, vec2 p) {
    return g_height_d(g, p, g_sdf(g, p));
}

vec3 g_normal_at(Glass g, vec2 p) {
    float e = 0.5;
    float hx = g_height(g, p + vec2(e, 0.0)) - g_height(g, p - vec2(e, 0.0));
    float hy = g_height(g, p + vec2(0.0, e)) - g_height(g, p - vec2(0.0, e));
    return normalize(vec3(-hx / (2.0 * e), -hy / (2.0 * e), 1.0));
}

float g_fresnel(float cos_i, float n1, float n2) {
    float ci = clamp(cos_i, 0.0, 1.0);
    float s2 = (n1 / n2) * (n1 / n2) * (1.0 - ci * ci);
    if (s2 >= 1.0) {
        return 1.0;
    }
    float ct = sqrt(1.0 - s2);
    float rs = (n1 * ci - n2 * ct) / (n1 * ci + n2 * ct);
    float rp = (n1 * ct - n2 * ci) / (n1 * ct + n2 * ci);
    return 0.5 * (rs * rs + rp * rp);
}

vec3 g_env(vec3 d) {
    float up = clamp(d.z, 0.0, 1.0);
    vec3 c = mix(vec3(0.006, 0.007, 0.011), vec3(0.030, 0.034, 0.046), up);
    vec3 box = normalize(vec3(-0.42, -0.58, 0.70));
    c = c + vec3(0.85, 0.88, 0.95) * g_smoothstep(0.80, 0.97, dot(d, box)) * 4.0;
    vec3 strip = normalize(vec3(0.80, 0.10, 0.59));
    c = c + vec3(0.55, 0.62, 0.80) * g_smoothstep(0.93, 0.99, dot(d, strip)) * 2.0;
    return c * u.misc.y;
}

vec3 g_bspline(vec2 uv, float lod) {
    vec2 dim = vec2(max(((ivec2(u.size.xy) + 1) / 2) >> int(lod), ivec2(1)));
    vec2 st = uv * dim - 0.5;
    vec2 i = floor(st);
    vec2 f = st - i;
    vec2 w0 = (1.0 - f) * (1.0 - f) * (1.0 - f) / 6.0;
    vec2 w1 = (4.0 - 6.0 * f * f + 3.0 * f * f * f) / 6.0;
    vec2 w2 = (1.0 + 3.0 * f + 3.0 * f * f - 3.0 * f * f * f) / 6.0;
    vec2 w3 = f * f * f / 6.0;
    vec2 g0 = w0 + w1;
    vec2 g1 = w2 + w3;
    vec2 h0 = (i + vec2(-1.0) + w1 / g0 + 0.5) / dim;
    vec2 h1 = (i + vec2(1.0) + w3 / g1 + 0.5) / dim;
    vec3 a = pyramidSample(vec2(h0.x, h0.y), int(lod)).rgb;
    vec3 b = pyramidSample(vec2(h1.x, h0.y), int(lod)).rgb;
    vec3 c = pyramidSample(vec2(h0.x, h1.y), int(lod)).rgb;
    vec3 d = pyramidSample(vec2(h1.x, h1.y), int(lod)).rgb;
    return g0.y * (g0.x * a + g1.x * b) + g1.y * (g0.x * c + g1.x * d);
}

vec3 g_ui_at(
        vec2 p,
    float radius
) {
    vec2 uv = p / u.size.xy;
    vec3 sharp = texture(uTex0, vec2(uv.x, 1.0 - uv.y)).rgb;
    if (radius <= 1.0) {
        return sharp;
    }
    float maxLod = max(u.misc.x - 1.0, 0.0);
    float lod = clamp(log2(radius) - 1.0, 0.0, maxLod);
    float l0 = floor(lod);
    vec3 blur = mix(
        g_bspline(uv, l0),
        g_bspline(uv, min(l0 + 1.0, maxLod)),
        lod - l0
    );
    return mix(sharp, blur, g_smoothstep(1.0, 3.0, radius));
}

float g_shadow(Glass g, vec2 p) {
    float blur = max(u.shadow.z, 1e-3);
    float d = g_sdf(g, p - u.shadow.xy * g.p1.w);
    float s = 1.0 - g_smoothstep(-blur, blur * 1.6, d);
    float contact = 1.0 - g_smoothstep(0.0, 10.0, g_sdf(g, p));
    return clamp((s * 0.7 + contact * 0.3) * u.misc.z * g.p1.w, 0.0, 0.9);
}

vec3 g_floor_at(
        Glass g,
    vec2 q,
    float radius
) {
    vec3 c = g_ui_at(q, radius);
    float dq = g_sdf(g, q);
    float sh = g_shadow(g, q);
    vec3 flu = texture(uTex1, q / u.size.xy).rgb;
    float bevel = max(g.p0.y, 1.0);
    float rz = (-dq - bevel * 0.45) / (bevel * 0.22);
    float ring = exp(-(rz * rz)) * choose(0.0, 1.0, dq < 0.0);
    c = c * (1.0 - sh) + (flu * 0.55 + vec3(0.01)) * ring * u.misc.w * g.p1.w;
    return c;
}

struct GlassPath {
    vec2 q;
    vec3 dir;
    float len;
    float t_out;
    bool floor;
};

GlassPath g_trace(Glass g, vec2 p, vec3 n, float zt, float ior) {
    GlassPath o;
    o.q = p;
    o.dir = vec3(0.0, 0.0, 1.0);
    vec3 v = vec3(0.0, 0.0, -1.0);
    vec3 r1 = refract(v, n, 1.0 / ior);
    float s = (zt - g.p0.z) / max(-r1.z, 1e-3);
    vec2 pb = p + r1.xy * s;
    vec3 up = vec3(0.0, 0.0, 1.0);
    float ci = -r1.z;
    vec3 r2 = refract(r1, up, ior);
    if (dot(r2, r2) > 0.0) {
        o.floor = true;
        o.q = pb + r2.xy * (g.p0.z / max(-r2.z, 0.05));
        o.len = s;
        o.t_out = 1.0 - g_fresnel(ci, ior, 1.0);
        return o;
    }
    vec3 r1b = reflect(r1, up);
    float t = (zt - g.p0.z) / max(r1b.z, 1e-3);
    for (int k = 0; k < 4; k += 1) {
        t = (g_height(g, pb + r1b.xy * t) - g.p0.z) / max(r1b.z, 1e-3);
    }
    vec2 pe = pb + r1b.xy * t;
    vec3 ne = g_normal_at(g, pe);
    vec3 r3 = refract(r1b, -ne, ior);
    o.floor = false;
    o.len = s + t;
    if (dot(r3, r3) > 0.0) {
        o.dir = r3;
        o.t_out = 1.0 - g_fresnel(dot(r1b, ne), ior, 1.0);
    } else {
        o.dir = reflect(r1b, ne);
        o.t_out = 0.25;
    }
    return o;
}

vec3 g_spectrum(int i) {
    const vec3 w[8] = vec3[8](
        vec3(0.20, 0.00, 0.62),
        vec3(0.12, 0.02, 1.00),
        vec3(0.00, 0.22, 0.86),
        vec3(0.00, 0.62, 0.30),
        vec3(0.18, 0.92, 0.00),
        vec3(0.70, 0.62, 0.00),
        vec3(1.00, 0.20, 0.00),
        vec3(0.62, 0.00, 0.00)
    );
    return w[i];
}

float g_ggx(float nh, float a) {
    float a2 = a * a;
    float d = nh * nh * (a2 - 1.0) + 1.0;
    return a2 / (glassPI * d * d);
}

vec4 g_shade(
        Glass g,
    vec2 p,
    float spec_var,
    float fp
) {
    float d = g_sdf(g, p);
    float cov = clamp(0.5 - d, 0.0, 1.0);
    if (cov <= 0.0) {
        return vec4(0.0);
    }
    float zt = g_height_d(g, p, d);
    vec3 n = g_normal_at(g, p);
    float ior = g.p1.x;
    float disp = g.p1.y;
    float frost = g.p1.z;
    float B = disp / (1.0 / (0.4 * 0.4) - 1.0 / (0.7 * 0.7));
    float A = ior - B / (0.55 * 0.55);
    float n_lo = A + B / (0.7 * 0.7);
    float n_hi = A + B / (0.4 * 0.4);
    GlassPath a = g_trace(g, p, n, zt, n_lo);
    GlassPath b = g_trace(g, p, n, zt, n_hi);
    vec3 trans = vec3(0.0);
    vec3 wsum = vec3(0.0);
    for (int i = 0; i < 8; i += 1) {
        float k = float(i) / 7.0;
        vec3 w = g_spectrum(i);
        vec3 c;
        float len;
        float tout;
        if (a.floor && b.floor) {
            vec2 q = mix(b.q, a.q, k);
            len = mix(b.len, a.len, k);
            tout = mix(b.t_out, a.t_out, k);
            c = g_floor_at(g, q, max(frost * (6.0 + len * 0.35), fp));
        } else if (!a.floor && !b.floor) {
            vec3 dir = normalize(mix(b.dir, a.dir, k));
            len = mix(b.len, a.len, k);
            tout = mix(b.t_out, a.t_out, k);
            c = g_env(dir);
        } else {
            GlassPath pa = (k > 0.5) ? a : b;
            len = pa.len;
            tout = pa.t_out;
            if (pa.floor) {
                c = g_floor_at(g, pa.q, max(frost * (6.0 + len * 0.35), fp));
            } else {
                c = g_env(pa.dir);
            }
        }
        vec3 beer = exp(-g.tint.rgb * len);
        trans = trans + w * c * beer * tout;
        wsum = wsum + w;
    }
    trans = trans / wsum;

    vec3 v_up = vec3(0.0, 0.0, 1.0);
    float F = g_fresnel(n.z, 1.0, ior);
    vec3 rr = reflect(vec3(0.0, 0.0, -1.0), n);
    float reach = min(zt * length(rr.xy) / max(-rr.z, 1e-3), zt * 4.0);
    vec3 below = g_ui_at(p + normalize(rr.xy + vec2(1e-5)) * reach, 4.0 + reach * 0.08);
    vec3 refl = mix(g_env(rr), below, g_smoothstep(0.05, -0.15, rr.z));
    vec3 flu = texture(uTex1, p / u.size.xy).rgb;
    vec3 col = trans * (1.0 - F) + refl * F;
    col = col + flu * frost * 0.10;

    vec3 P = vec3(p, zt);
    float rough = mix(0.035, 0.32, frost);
    vec3 spec = vec3(0.0);
    int nl = int(u.size.w);
    for (int i = 0; i < nl; i += 1) {
        GLight L = u.glights[i];
        vec3 D = L.pos.xyz - P;
        float dist = length(D);
        vec3 l = D / max(dist, 1e-3);
        float ndl = max(dot(n, l), 0.0);
        if (ndl <= 0.0) {
            continue;
        }
        vec3 h = normalize(l + v_up);
        float a0 = sqrt(rough * rough + spec_var);
        float al = clamp(a0 + L.pos.w / (2.0 * max(dist, 1e-4)), 0.02, 1.0);
        float energy = (a0 * a0) / (al * al);
        float fh = g_fresnel(max(dot(l, h), 0.0), 1.0, ior);
        float fall = 1.0 / (1.0 + dist * dist / (L.pos.w * L.pos.w + 1.0));
        spec = spec + L.color.rgb * g_ggx(max(dot(n, h), 0.0), al) * energy * fh * ndl * fall;
    }
    col = col + spec;

    float bevel = max(g.p0.y, 1.0);
    float rimT = 1.0 - clamp(-d / bevel, 0.0, 1.0);
    float rim = rimT * rimT;
    col = col + flu * rim * g.tint.w;
    return vec4(col, cov);
}

void traceFootprint(Glass g, vec2 p, float distance, out vec3 normal, out vec2 ray) {
    normal = vec3(0.0, 0.0, 1.0);
    ray = p;
    if (g.p1.w > 0.0 && distance < 8.0) {
        normal = g_normal_at(g, p);
        GlassPath path = g_trace(g, p, normal, g_height(g, p), g.p1.x);
        ray = path.floor ? path.q : p + path.dir.xy * 400.0;
    }
}

void main() {
    vec2 p = vec2(gl_FragCoord.x, u.size.y - gl_FragCoord.y);
    vec3 base = texelFetch(uTex0, ivec2(gl_FragCoord.xy), 0).rgb;
    int ng = int(u.size.z);
    float reach = u.shadow.z * 2.5 + length(u.shadow.xy) + 12.0;
    vec3 col = base;
    for (int gk = 0; gk < ng; gk += 1) {
        Glass g = u.glass[gk];
        float d = g_sdf(g, p);
        vec3 nv;
        vec2 q0;
        traceFootprint(g, p, d, nv, q0);
        vec3 dn = dFdx(nv);
        vec3 dm = dFdy(nv);
        vec2 qy = dFdy(q0);
        if ((int(u.size.y) & 1) != 0) {
            // Fragment quads are aligned to the bottom in GL and the top in Metal.
            // An odd framebuffer height changes which adjacent row supplies derivatives.
            vec2 neighbor = p + vec2(0.0, (int(p.y) & 1) == 0 ? 1.0 : -1.0);
            vec3 otherNormal;
            vec2 otherRay;
            traceFootprint(g, neighbor, g_sdf(g, neighbor), otherNormal, otherRay);
            dm = nv - otherNormal;
            qy = q0 - otherRay;
        }
        float spec_var = min(0.5 * (dot(dn, dn) + dot(dm, dm)), 0.18);
        float fp = clamp(max(length(dFdx(q0)), length(qy)) * 0.5 - 0.5, 0.0, 24.0);
        if (g.p1.w > 0.0 && d <= reach) {
            vec3 outside = col * (1.0 - g_shadow(g, p));
            float bevel = max(g.p0.y, 1.0);
            if (d > 1.0) {
                col = outside;
            } else if (-d < bevel + 1.0) {
                const vec2 o[4] = vec2[4](
                    vec2(-0.125, -0.375),
                    vec2(0.375, -0.125),
                    vec2(0.125, 0.375),
                    vec2(-0.375, 0.125)
                );
                vec4 acc = vec4(0.0);
                for (int k = 0; k < 4; k += 1) {
                    vec4 s = g_shade(g, p + o[k], spec_var, fp);
                    acc = acc + vec4(s.rgb * s.a, s.a);
                }
                acc = acc * 0.25;
                col = outside * (1.0 - acc.a) + acc.rgb;
            } else {
                vec4 s = g_shade(g, p, spec_var, fp);
                col = mix(outside, s.rgb, s.a);
            }
        }
    }
    result = vec4(col, 1.0);
}
