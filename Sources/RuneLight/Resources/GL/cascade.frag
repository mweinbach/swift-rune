vec4 gi_march(
    vec2 a,
    vec2 b,
    float zp,
    float inner
) {
    vec2 gsz = F.gs.xy;
    vec2 D = b - a;
    float len = length(D);
    if (len < 1e-4) {
        return vec4(0.0, 0.0, 0.0, 1.0);
    }
    vec2 dir = D / len;
    vec3 rad = vec3(0.0);
    float T = 1.0;
    float t = 0.0;
    for (int i = 0; i < 48; i += 1) {
        if (t >= len || T < 0.01) {
            break;
        }
        vec2 q = a + dir * t;
        if (any(lessThan(q, vec2(0.0))) || any(greaterThan(q, gsz))) {
            break;
        }
        vec4 f = texture(uTex2, (q / F.gs.w) * F.gs.z / F.sf.zw);
        float de = f.w * F.gs.w;
        float dx = f.x * F.gs.w;
        bool tall = f.z > zp + 0.5;
        float free = min(de, abs(dx));
        if (dx < 0.0 && tall) {
            free = 0.0;
        }
        if (free > 1.0) {
            t = t + max(free - 0.5, 1.0);
            continue;
        }
        float step = min(inner, len - t);
        vec2 uv = (q + dir * step * 0.5) / gsz;
        vec4 em = texture(uTex0, uv);
        vec4 oc = texture(uTex1, uv);
        float blocks = F.gi.w * w_smoothstep(zp, zp + 1.0, f.z);
        float sigma = em.a + oc.a * blocks;
        vec3 e = em.rgb + oc.rgb * blocks;
        float tr = exp(-sigma * step);
        float k = choose(step, (1.0 - tr) / sigma, sigma > 1e-4);
        rad = rad + T * e * k;
        T = T * tr;
        t = t + step;
    }
    return vec4(rad, T);
}

void main() {
    uvec2 gid = uvec2(gl_FragCoord.xy);
    uint n = F.stage.x;
    uint s = 1u << n;
    uint b = 2u << n;
    uvec2 probes = uvec2(F.gs.xy) / s;
    uvec2 probe = gid / b;
    if (probe.x >= probes.x || probe.y >= probes.y) {
        return;
    }
    uvec2 sub = gid % b;
    uint di = sub.y * b + sub.x;
    uint nd = b * b;
    float ang = (float(di) + 0.5) / float(nd) * RL_TAU;
    vec2 dir = vec2(cos(ang), sin(ang));
    vec2 origin = (vec2(probe) + 0.5) * float(s);
    ivec2 pix = clamp(ivec2(origin / F.gs.w), ivec2(0), ivec2(F.sf.xy) - ivec2(1));
    float zp = texelFetch(uTex4, pix, 0).w;
    float p4 = float(1u << (2u * n));
    float t0 = (p4 - 1.0) / 3.0;
    float t1 = (p4 * 4.0 - 1.0) / 3.0;
    float inner = max(1.0, float(s) * 0.5);
    vec2 a = origin + dir * t0;
    vec4 r = vec4(0.0);
    if (n + 1u < F.counts.z) {
        uint us = s * 2u;
        uint ub = b * 2u;
        ivec2 uprobes = ivec2(uvec2(F.gs.xy) / us);
        vec2 f = origin / float(us) - 0.5;
        ivec2 base = ivec2(floor(f));
        vec2 w = fract(f);
        for (int k = 0; k < 4; k += 1) {
            ivec2 o = ivec2(k & 1, k >> 1);
            ivec2 q = clamp(base + o, ivec2(0), uprobes - ivec2(1));
            float wk = choose(1.0 - w.x, w.x, o.x == 1) * choose(1.0 - w.y, w.y, o.y == 1);
            vec2 uo = (vec2(q) + 0.5) * float(us);
            vec4 seg = gi_march(a, uo + dir * t1, zp, inner);
            vec3 far = vec3(0.0);
            if (F.stage.w == 0u) {
                for (uint j = 0u; j < 4u; j += 1u) {
                    uint idx = di * 4u + j;
                    ivec2 tex = q * int(ub) + ivec2(int(idx % ub), int(idx / ub));
                    far += texelFetch(uTex3, tex, 0).rgb;
                }
            }
            r = r + wk * vec4(seg.rgb + seg.a * far * 0.25, seg.a);
        }
    } else {
        r = gi_march(a, origin + dir * t1, zp, inner);
    }
    result = r;
}
