struct Bolt { float core; float halo; };

Bolt shade_bolt(float dist, float w, float gr) {
    Bolt b;
    b.core = gauss(dist, w);
    float o = dist / gr;
    b.halo = 0.35 / (1.0 + o * o) * (1.0 - w_smoothstep(gr * 2.5, gr * 5.0, dist)) + 0.65 * gauss(dist, gr * 0.6);
    return b;
}

float lat(float dv, float a, float b, float step_len) {
    float s = (b - a) / step_len;
    float k = inversesqrt(1.0 + min(s * s, 3.0));
    return dv * mix(k, 1.0, w_smoothstep(1.5, 8.0, abs(dv)));
}

vec3 fork_col(Inst i, float heat) {
    return mix(mix(i.c2.rgb, i.c0.rgb, w_smoothstep(0.0, 0.5, heat)), i.c1.rgb, w_smoothstep(0.6, 1.0, heat));
}

vec4 shade_electric(
    vec2 pixel,
    Globals g,
    BackdropEncoding enc
) {
    Inst i = fxInstance;
    Ctx c = make_ctx(i, pixel);
    float w = max(i.p0.w, c.aa * 0.7);
    float inten = i.p1.x;
    float gr = max(i.p1.y, 1e-3);
    float gap = i.p2.y;
    uint first = uint(i.xf.x);
    uint n = uint(i.xf.y);
    uint nf = uint(i.xf.z);
    uint ns = uint(i.xf.w);
    uint q4 = n >> 2u;
    vec4 fl = tableEntry(first + 1u);
    uint base = first + 2u;

    float core = 0.0;
    float halo = 0.0;
    vec3 fork_hot = vec3(0.0);

    if (c.variant == 0) {
        vec2 a = i.aux.xy;
        vec2 bb = i.aux.zw;
        float L = max(length(bb - a), 1.0);
        vec2 dir = (bb - a) / L;
        vec2 nrm = vec2(-dir.y, dir.x);
        vec2 rel = c.p - a;
        float u = dot(rel, dir) / L;
        float v = dot(rel, nrm);
        float uc = clamp(u, 0.0, 1.0);
        float fi = uc * float(n - 1u);
        uint i0 = min(uint(fi), n - 2u);
        float f = fi - float(i0);
        float step_len = L / float(n - 1u);
        for (uint k = 0u; k < ns; k++) {
            uint sb = base + k * q4;
            float d0 = dat1(sb, i0);
            float d1 = dat1(sb, i0 + 1u);
            float dd = length(vec2((u - uc) * L, lat(v - mix(d0, d1, f), d0, d1, step_len)));
            uint hb = base + (ns + k) * q4;
            float dh = length(vec2((u - uc) * L, v - mix(dat1(hb, i0), dat1(hb, i0 + 1u), f)));
            float bw = (k == 0u ? w : w * 0.6);
            Bolt bo = shade_bolt(dd, bw, gr);
            bo.halo = 0.4 * shade_bolt(dh, bw, gr).halo + 0.6 * shade_bolt(dd, bw, gr * 0.3).halo;
            float kb = (k == 0u ? 1.0 : 0.32) * fl[k];
            core += bo.core * kb;
            halo += bo.halo * kb;
        }
        halo += 0.6 * (gauss(length(c.p - a), gr * 0.8) + gauss(length(c.p - bb), gr * 0.8));
        core += 0.5 * (gauss(length(c.p - a), w * 2.5) + gauss(length(c.p - bb), w * 2.5));
        uint fb = base + 2u * ns * q4;
        for (uint j = 0u; j < nf; j++) {
            vec4 h0 = tableEntry(fb);
            vec4 h1 = tableEntry(fb + 1u);
            vec2 o = h0.xy;
            vec2 fd = h0.zw;
            float len = h1.x;
            vec2 fr = c.p - o;
            float fu = dot(fr, fd) / len;
            float fv = dot(fr, vec2(-fd.y, fd.x));
            float fuc = clamp(fu, 0.0, h1.y);
            float ffi = fuc * 15.0;
            uint j0 = min(uint(ffi), 14u);
            float s0 = dat1(fb + 2u, j0);
            float s1 = dat1(fb + 2u, j0 + 1u);
            float fdist = length(vec2((fu - fuc) * len, lat(fv - mix(s0, s1, ffi - float(j0)), s0, s1, len / 15.0)));
            float taper = 1.0 - 0.7 * fuc;
            Bolt bo = shade_bolt(fdist, w * 0.6 * taper, gr * 0.55);
            fork_hot += fork_col(i, h1.w) * (bo.core * 1.1 + bo.halo * 0.45) * h1.z * taper;
            fb += 6u;
        }
    } else {
        vec2 pr = rrect_perim(c.q, c.half_size, c.r);
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
            float d0 = dat1(sb, i0);
            float d1 = dat1(sb, i1);
            float dd = abs(lat(c.d - gap - mix(d0, d1, f), d0, d1, step_len));
            uint hb = base + (ns + k) * q4;
            float dh = abs(c.d - gap - mix(dat1(hb, i0), dat1(hb, i1), f));
            uint cb = base + (2u * ns + k) * q4;
            float crawl = mix(dat1(cb, i0), dat1(cb, i1), f);
            float bw = (k == 0u ? w : w * 0.6);
            Bolt bo = shade_bolt(dd, bw, gr);
            bo.halo = 0.4 * shade_bolt(dh, bw, gr).halo + 0.6 * shade_bolt(dd, bw, gr * 0.3).halo;
            float kb = (k == 0u ? 1.0 : 0.32) * fl[k] * crawl;
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
            vec4 h0 = tableEntry(fb);
            vec4 h1 = tableEntry(fb + 1u);
            float len = h1.x;
            float dsv = s - h0.x;
            dsv -= total * round(dsv / total);
            float fu = (c.d - gap - h0.z) / len;
            float fuc = clamp(fu, 0.0, h1.y);
            float ffi = fuc * 15.0;
            uint j0 = min(uint(ffi), 14u);
            float s0 = dat1(fb + 2u, j0);
            float s1 = dat1(fb + 2u, j0 + 1u);
            float fdist = length(vec2((fu - fuc) * len, lat(dsv - mix(s0, s1, ffi - float(j0)), s0, s1, len / 15.0)));
            float taper = 1.0 - 0.7 * fuc;
            Bolt bo = shade_bolt(fdist, w * 0.6 * taper, gr * 0.55);
            fork_hot += fork_col(i, h1.w) * (bo.core * 1.1 + bo.halo * 0.45) * h1.z * taper;
            fb += 6u;
        }
    }
    float occl = (effective_blend_mode(i, enc) == 0u ? i.p2.w : 1.0);
    vec3 rgb = (i.c1.rgb * core * 1.3 + i.c0.rgb * halo * 0.75 + fork_hot) * inten;
    float a = (core * 0.7 + halo * occl + lum(fork_hot) * 0.5) * inten;
    return finish(vec4(rgb, a), pixel, g);
}

void main() {
    Globals g = fxGlobals;
    BackdropEncoding enc = fxBackdrop;
    vec2 pixel = runePixel;
    fragColor = fx_fs(shade_electric(pixel, g, enc), fxInstance, pixel, g, uTex0, enc);
}
