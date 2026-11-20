float fill_mask(Ctx c, float border) {
    float inside = clamp(0.5 - c.d * c.scale, 0.0, 1.0);
    if (border <= 0.0) { return inside; }
    return inside * clamp(0.5 + (c.d + border) * c.scale, 0.0, 1.0);
}

vec2 rot2(vec2 v, float a) {
    float cs = cos(a);
    float sn = sin(a);
    return vec2(cs * v.x - sn * v.y, sn * v.x + cs * v.y);
}

vec3 stop_lin(uint f0, uint k) {
    return tableEntry(f0 + 2u * k).rgb;
}

vec3 stop_lab(uint f0, uint k) {
    return tableEntry(f0 + 2u * k + 1u).rgb;
}

vec2 stop_pt(uint f0, uint k) {
    return vec2(tableEntry(f0 + 2u * k).w, tableEntry(f0 + 2u * k + 1u).w);
}

vec3 oklab_to_lin(vec3 c) {
    float l = c.x + 0.39633778 * c.y + 0.21580376 * c.z;
    float m = c.x - 0.10556135 * c.y - 0.06385417 * c.z;
    float s = c.x - 0.08948418 * c.y - 1.29148555 * c.z;
    float l3 = l * l * l;
    float m3 = m * m * m;
    float s3 = s * s * s;
    return max(vec3(
        4.07674166 * l3 - 3.30771159 * m3 + 0.23096993 * s3,
        -1.26843800 * l3 + 2.60975740 * m3 - 0.34131940 * s3,
        -0.00419609 * l3 - 0.70341861 * m3 + 1.70761470 * s3
    ), vec3(0.0));
}

vec3 palette_ramp(uint f0, uint n, float x) {
    if (n <= 1u) { return stop_lin(f0, 0u); }
    float fx = clamp(x, 0.0, 1.0) * float(n - 1u);
    uint k = min(uint(fx), n - 2u);
    return oklab_to_lin(mix(stop_lab(f0, k), stop_lab(f0, k + 1u), fx - float(k)));
}

vec3 ramp_loop(uint f0, uint n, float x) {
    if (n <= 1u) { return stop_lin(f0, 0u); }
    float fx = fract(x) * float(n);
    uint k = min(uint(fx), n - 1u);
    return oklab_to_lin(mix(stop_lab(f0, k), stop_lab(f0, (k + 1u) % n), fx - float(k)));
}

vec4 paint(vec3 col, float m, Inst i, vec2 px, Globals g) {
    float a = m * clamp(i.aux.y, 0.0, 1.0);
    return finish(vec4(col * a, a), px, g);
}

float tone_at(
    Inst i,
    Ctx c,
    vec2 p,
    int kind,
    float angle,
    Globals g,
    sampler2D backdrop,
    sampler2D source,
    BackdropEncoding enc
) {
    float v;
    vec2 q = p - c.c;
    if (kind == 0) {
        vec2 dir = vec2(cos(angle), sin(angle));
        float ext = abs(c.half_size.x * dir.x) + abs(c.half_size.y * dir.y);
        v = dot(q, dir) / max(ext, 1e-3) * 0.5 + 0.5;
    } else if (kind == 1) {
        v = 1.0 - clamp(length(q / max(c.half_size, vec2(1e-3))) / 1.3, 0.0, 1.0);
    } else if (kind == 2) {
        float t = c.t * i.p1.y;
        v = 0.5 + 0.62 * fbm3(p / max(i.p1.x, 1.0) + vec2(t * 0.31, t * 0.17), c.seed);
    } else if (kind == 3) {
        v = to_srgb(vec3(lum(bd(p, c.scale, g, backdrop, enc).rgb))).x;
    } else {
        vec4 s = sampleTopLeft(source, (p - i.aux2.xy) / max(i.aux2.zw, vec2(1e-3)), 0.0);
        v = to_srgb(vec3(lum(s.rgb))).x;
    }
    return clamp((v - 0.5) * i.p1.w + 0.5 + i.p1.z * 0.5, 0.0, 1.0);
}

float bayer(uvec2 cell, uint bits) {
    uint v = 0u;
    for (uint b = 0u; b < bits; b++) {
        uint x = (cell.x >> b) & 1u;
        uint y = (cell.y >> b) & 1u;
        uint sh = 2u * (bits - 1u - b);
        v |= (((x ^ y) << 1u) | y) << sh;
    }
    return (float(v) + 0.5) / float(1u << (2u * bits));
}

vec3 slab_tilt(Ctx c, float border, float bevel, float dome) {
    float depth = -c.d;
    vec2 gv = sd_grad(c);
    vec2 tilt = vec2(0.0);
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
    vec2 qn = c.q / max(c.half_size, vec2(1.0));
    tilt += vec2(qn.x * 0.55, qn.y) * dome * (border > 0.0 ? 0.25 : 0.8);
    return vec3(tilt, rim);
}

float flow_h(vec2 u, vec2 w, float t, uint seed) {
    vec2 p = u + w;
    return gnoise(p + vec2(0.0, t * 0.11), seed + 3u) + 0.5 * gnoise(rot_mul(p) * 2.03 - vec2(t * 0.07, 0.0), seed + 17u);
}

vec3 studio(vec3 r, float contrast) {
    float up = -r.y;
    float e = up + 0.1;
    float w = 0.014;
    float sky = 0.2 + 0.6 * exp(-max(e, 0.0) * 3.2) + 0.45 * exp(-max(e, 0.0) * 24.0);
    float key = w_smoothstep(0.80, 0.95, dot(r, normalize(vec3(-0.3, -0.82, 0.5)))) * 2.4;
    float strip = gauss(r.x - 0.6, 0.075) * w_smoothstep(-0.05, 0.2, e) * (1.0 - w_smoothstep(0.55, 0.9, up)) * 1.7;
    float fill_l = gauss(r.x + 0.72, 0.045) * w_smoothstep(0.0, 0.25, e) * (1.0 - w_smoothstep(0.4, 0.8, up)) * 0.55;
    float lights = (key + strip + fill_l) * contrast;
    float fl = w_smoothstep(0.05, 1.0, -e);
    float pool = 0.16 * gauss(r.x + 0.25, 0.35) * w_smoothstep(0.25, 0.9, -e);
    float ground = (0.014 + 0.3 * fl * fl + pool + 0.05 * gauss(e + 0.06, 0.04)) / (contrast * contrast);
    float h = w_smoothstep(-w, w, e);
    vec3 skyc = (sky * mix(1.0, 0.82, clamp(contrast - 1.0, 0.0, 1.0)) + lights) * vec3(0.97, 0.99, 1.03);
    vec3 floorc = ground * vec3(1.04, 1.0, 0.95);
    return mix(floorc, skyc, h);
}

vec3 shoulder(vec3 c) {
    float k = 0.78;
    return mix(c, k + (1.0 - k) * (1.0 - exp(-(c - k) / (1.0 - k))), greaterThan(c, vec3(k)));
}

vec4 liquid_metal(Inst i, Ctx c, float m, vec2 px, Globals g) {
    float flow = i.p0.x;
    float sc = max(i.p0.y, 1.0);
    float t = c.t * i.p0.z;
    vec3 slab = slab_tilt(c, i.aux.x, i.p0.w, i.p1.x);
    vec2 tilt = slab.xy;
    float rim = slab.z;
    float hgt = 0.0;
    float bend = 0.0;
    if (flow > 0.0) {
        vec2 u = (i.p2.x > 0.5 ? c.q : c.p) / sc;
        vec2 wv = vec2(
            gnoise(u * 0.6 + vec2(t * 0.05, 1.7), c.seed + 7u),
            gnoise(u * 0.6 + vec2(4.3, -t * 0.06), c.seed + 11u)
        ) * 0.9;
        float e = 0.04;
        hgt = flow_h(u, wv, t, c.seed);
        float hx = flow_h(u + vec2(e, 0.0), wv, t, c.seed) - hgt;
        float hy = flow_h(u + vec2(0.0, e), wv, t, c.seed) - hgt;
        vec2 grad = vec2(hx, hy) / e;
        float k = flow * 0.42 * (1.0 - 0.6 * rim * rim);
        tilt -= grad * k;
        bend = length(grad) * k;
    }
    vec3 n = normalize(vec3(tilt, 1.0));
    vec3 r = vec3(2.0 * n.z * n.xy, 2.0 * n.z * n.z - 1.0);
    r = vec3(rot2(r.xy, i.p1.y), r.z);
    float contrast = max(i.p1.w, 0.1);
    vec3 env = studio(normalize(r), contrast) * i.c1.rgb;
    vec3 f0 = i.c0.rgb;
    float cz = clamp(1.0 - n.z, 0.0, 1.0);
    float cz2 = cz * cz;
    vec3 f = f0 + (vec3(1.0) - f0) * (cz2 * cz2 * cz);
    float ir = i.p1.z;
    if (ir > 0.0) {
        float ph = 1.6 * (1.0 - n.z) + 0.35 * hgt;
        vec3 film = 0.5 + 0.5 * cos(TAU * (vec3(ph) + vec3(0.0, 0.33, 0.67)));
        float k = ir * clamp(w_smoothstep(0.04, 0.45, 1.0 - n.z) + bend * 0.8, 0.0, 1.0);
        f *= mix(vec3(1.0), 0.55 + 0.9 * film, k);
    }
    vec3 col = shoulder(f * env);
    return paint(col, m, i, px, g);
}

vec4 plastic(Inst i, Ctx c, float m, vec2 px, Globals g) {
    vec3 slab = slab_tilt(c, i.aux.x, i.p0.z, i.p0.y);
    vec3 n = normalize(vec3(slab.xy, 1.0));
    vec3 l = vec3(rot2(vec2(0.0, -1.0), i.p0.w) * 0.6428, 0.766);
    float nl = dot(n, l);
    vec3 base = clamp(i.c0.rgb, vec3(0.0), vec3(1.0));
    float shade = 0.4 + 0.7833 * max(nl, 0.0);
    vec3 col = mix(base * min(shade, 1.0), vec3(1.0), clamp((shade - 1.0) * 0.6, 0.0, 1.0));
    float rough = clamp(i.p0.x, 0.02, 1.0);
    float a = min(rough * rough + 0.1, 1.0);
    float a2 = a * a;
    vec3 h = normalize(l + vec3(0.0, 0.0, 1.0));
    float nh = max(dot(n, h), 0.0);
    float dd = nh * nh * (a2 - 1.0) + 1.0;
    float ndf = a2 / (PI * dd * dd);
    float fh = 1.0 - h.z;
    float spec = ndf * (0.04 + 0.96 * fh * fh * fh * fh * fh) * max(nl, 0.0) * 2.5;
    float fz = 1.0 - clamp(n.z, 0.0, 1.0);
    float sky = 0.55 + 0.45 * w_smoothstep(-0.5, 0.5, -n.y);
    float edge = 0.96 * fz * fz * fz * fz * fz * sky * (1.0 - 0.5 * rough);
    col += (vec3(1.0) - col) * knee(spec + edge);
    return paint(col, m, i, px, g);
}

vec4 fluted(
    Inst i,
    Ctx c,
    float m,
    vec2 px,
    Globals g,
    sampler2D backdrop,
    sampler2D blurred,
    BackdropEncoding enc
) {
    float s = c.scale;
    float rib = max(i.p0.x, 1.0);
    vec2 across = vec2(cos(i.p0.y), sin(i.p0.y));
    float u = dot(c.p - c.c, across) / rib;
    float local = fract(u) - 0.5;
    float x = local * 2.0;
    float o = -x * (1.0 + 0.35 * x * x) * i.p0.z;
    float dsp = i.p1.x * 0.3 * abs(x);
    vec2 srcg = c.p + across * o;
    vec2 srcr = c.p + across * o * (1.0 + dsp);
    vec2 srcb = c.p + across * o * (1.0 - dsp);
    vec3 col = vec3(
        bd(srcr, s, g, backdrop, enc).r,
        bd(srcg, s, g, backdrop, enc).g,
        bd(srcb, s, g, backdrop, enc).b
    );
    float frost = i.p0.w;
    if (frost > 0.0) {
        if (i.xf.x > 0.5) {
            vec3 blr = vec3(
                bdb(srcr, s, g, blurred, enc).r,
                bdb(srcg, s, g, blurred, enc).g,
                bdb(srcb, s, g, blurred, enc).b
            );
            col = mix(col, blr, i.xf.y);
        } else {
            vec2 along = vec2(-across.y, across.x);
            float j = ign(px) - 0.5;
            vec3 acc = vec3(0.0);
            for (int k = 0; k < 4; k++) {
                acc += bd(srcg + along * (float(k) - 1.5 + j) * 3.0 * frost, s, g, backdrop, enc).rgb;
            }
            col = mix(col, acc * 0.25, frost);
        }
        float k = w_smoothstep(0.0, 0.6, frost);
        float l = lum(col);
        vec3 sat = max(mix(vec3(l), col, 1.0 + 0.5 * k), vec3(0.0));
        col = to_lin(to_srgb(sat) * (1.0 - 0.2 * k) + vec3(0.07 * k));
    }
    col = mix(col, col * i.c0.rgb, i.p1.z);
    float hl = i.p1.y;
    float aa = c.aa / rib;
    float groove = 1.0 - w_smoothstep(0.0, max(0.06, aa * 2.0), 0.5 - abs(local));
    float sheen = gauss(local + 0.22, 0.13) * 0.1 + gauss(local + 0.34, 0.03) * 0.1;
    float lip = gauss(local - 0.44, max(0.025, aa)) * 0.06;
    float lift = 0.35 + 0.65 * sqrt(clamp(lum(col), 0.0, 1.0));
    col = col * (1.0 - 0.28 * hl * groove) + vec3((sheen + lip) * hl * lift);
    float a = m * clamp(i.aux.y, 0.0, 1.0);
    return vec4(col * a, a);
}

vec4 mesh_gradient(Inst i, Ctx c, float m, vec2 px, Globals g) {
    uint f0 = uint(i.xf.x);
    uint n = uint(i.xf.y);
    vec2 uv = (c.p - i.rect.xy) / max(i.rect.zw, vec2(1.0));
    float t = c.t * i.p0.y;
    float warp = i.p0.w;
    if (warp > 0.0) {
        uv += warp * 0.09 * vec2(
            gnoise(uv * 2.1 + vec2(t * 0.11, 0.0), c.seed + 5u),
            gnoise(uv * 2.1 + vec2(3.7, -t * 0.09), c.seed + 9u)
        );
    }
    vec2 aspect = i.rect.zw / max(max(i.rect.z, i.rect.w), 1.0);
    float sharp = clamp(i.p0.z, 0.1, 8.0);
    vec3 lab = vec3(0.0);
    float wsum = 0.0;
    for (uint k = 0u; k < n; k++) {
        vec2 d = (uv - stop_pt(f0, k)) * aspect;
        float w = pow(dot(d, d) + 0.004, -sharp);
        lab += stop_lab(f0, k) * w;
        wsum += w;
    }
    return paint(oklab_to_lin(lab / max(wsum, 1e-6)), m, i, px, g);
}

vec4 dither_fill(
    Inst i,
    Ctx c,
    float m,
    Globals g,
    sampler2D backdrop,
    sampler2D source,
    BackdropEncoding enc
) {
    uint f0 = uint(i.xf.x);
    uint n = max(uint(i.xf.y), 1u);
    float pix = max(i.p0.z, 0.25);
    vec2 rel = c.p - i.rect.xy;
    vec2 cell = floor(rel / pix);
    uvec2 ci = uvec2(ivec2(cell));
    float tone = tone_at(i, c, i.rect.xy + (cell + 0.5) * pix, int(i.p0.y + 0.5), i.p0.w, g, backdrop, source, enc);
    int pat = clamp(int(i.p0.x + 0.5), 1, 5);
    float th;
    if (pat <= 3) {
        th = bayer(ci, uint(pat));
    } else if (pat == 4) {
        uint side = max(uint(i.xf.w), 1u);
        th = dat1(uint(i.xf.z), (ci.y % side) * side + ci.x % side);
    } else {
        th = u01(ci.x * 7919u + pcg(ci.y + c.seed));
    }
    float lv = float(max(n, 2u) - 1u);
    float v = tone * lv;
    uint k = min(uint(floor(v) + (fract(v) > th ? 1.0 : 0.0)), n - 1u);
    float a = m * clamp(i.aux.y, 0.0, 1.0);
    return vec4(stop_lin(f0, k) * a, a);
}

vec4 grain_gradient(Inst i, Ctx c, float m, vec2 px, Globals g) {
    uint f0 = uint(i.xf.x);
    uint n = uint(i.xf.y);
    int kind = int(i.p0.x + 0.5);
    float ang = i.p0.y;
    vec2 ctr = i.rect.xy + i.p0.zw * i.rect.zw;
    float x;
    if (kind == 0) {
        vec2 dir = vec2(cos(ang), sin(ang));
        float ext = abs(c.half_size.x * dir.x) + abs(c.half_size.y * dir.y);
        x = dot(c.q, dir) / max(ext, 1e-3) * 0.5 + 0.5;
    } else if (kind == 1) {
        x = length(c.p - ctr) / max(length(c.half_size), 1e-3);
    } else {
        vec2 d = c.p - ctr;
        float th = (any(notEqual(d, vec2(0.0))) ? atan(d.y, d.x) : 0.0);
        x = fract((th - ang) / TAU);
    }
    float amount = i.p1.x;
    float size = max(i.p1.y, 0.25);
    uint frame = i.p1.w > 0.0 ? uint(floor(c.t * i.p1.w)) : 0u;
    uvec2 gc = uvec2(ivec2(floor((c.p - i.rect.xy) / size)));
    uint h = pcg(gc.x + pcg(gc.y + pcg(frame + c.seed * 977u)));
    float nx = u01(h) + u01(h + 1u) - 1.0;
    vec3 col = (kind == 2) ? ramp_loop(f0, n, x + nx * amount * 0.2) : palette_ramp(f0, n, x + nx * amount * 0.2);
    float nb = u01(h + 2u) + u01(h + 3u) - 1.0;
    if (i.p1.z > 0.5) {
        col *= 1.0 + nb * amount * 0.18;
    } else {
        vec3 nc = vec3(nb, u01(h + 4u) + u01(h + 5u) - 1.0, u01(h + 6u) + u01(h + 7u) - 1.0);
        col *= vec3(1.0) + nc * amount * 0.18;
    }
    return paint(col, m, i, px, g);
}

vec4 metaballs(Inst i, Ctx c, float m, vec2 px, Globals g) {
    uint f0 = uint(i.xf.x);
    uint b0 = uint(i.xf.z);
    uint nb = uint(i.xf.w);
    float field = 0.0;
    vec2 grad = vec2(0.0);
    vec3 lab = vec3(0.0);
    float rsum = 0.0;
    for (uint k = 0u; k < nb; k++) {
        vec4 b = tableEntry(b0 + k);
        vec2 d = c.p - b.xy;
        float r2 = b.z * b.z;
        float dd = dot(d, d) + 1e-3;
        float f = r2 / dd;
        field += f;
        grad += -2.0 * f / dd * d;
        lab += stop_lab(f0, uint(b.w)) * f;
        rsum += b.z * f;
    }
    vec3 base = i.c0.rgb;
    vec3 col = (field > 1e-5 ? oklab_to_lin(lab / max(field, 1e-6)) : base);
    float ravg = rsum / max(field, 1e-6);
    float cov_m = (field > 1e-3 ? clamp(0.5 + (field - 1.0) * ravg * 0.5 * c.scale, 0.0, 1.0) : 0.0);
    float steep = 1.0 - w_smoothstep(1.0, 2.6, field);
    vec2 nxy = -grad / sqrt(dot(grad, grad) + 1e-6) * steep * 0.9;
    vec3 nrm = normalize(vec3(nxy, 1.0));
    vec3 l = normalize(vec3(-0.45, -0.6, 0.66));
    float diff = max(dot(nrm, l), 0.0);
    float spec = pow(max(dot(reflect(-l, nrm), vec3(0.0, 0.0, 1.0)), 1e-4), 28.0);
    vec3 body = col * (0.6 + 0.5 * diff) + vec3(spec * i.p0.w * 0.8);
    vec3 halo = col * w_smoothstep(0.25, 1.0, field) * 0.18;
    return paint(mix(base + halo, body, cov_m), m, i, px, g);
}

vec4 swirl_fill(Inst i, Ctx c, float m, vec2 px, Globals g) {
    uint f0 = uint(i.xf.x);
    uint n = uint(i.xf.y);
    float sc = max(i.p0.x, 1.0);
    float t = c.t * i.p0.y;
    float rr = length(c.q) / max(min(c.half_size.x, c.half_size.y), 1.0);
    vec2 q = rot2(c.q, i.p0.z * TAU * exp(-rr * rr * 0.8)) / sc;
    vec2 w1 = vec2(
        fbm3(q + vec2(t * 0.1, 0.0), c.seed),
        fbm3(q + vec2(5.2, 1.3 - t * 0.08), c.seed + 3u)
    );
    float v = fbm3(q + w1 * i.p0.w * 1.5 + vec2(0.0, t * 0.05), c.seed + 7u);
    return paint(palette_ramp(f0, n, 0.5 + 0.75 * v), m, i, px, g);
}

vec4 voronoi_fill(Inst i, Ctx c, float m, vec2 px, Globals g) {
    uint f0 = uint(i.xf.x);
    uint n = uint(i.xf.y);
    float sc = max(i.p0.x, 2.0);
    float t = c.t * i.p0.y;
    float t0 = fract(t * (1.0 / TAU)) * TAU;
    float t1 = fract(t * (0.8 / TAU)) * TAU;
    vec2 p = (c.p - i.rect.xy) / sc;
    vec2 ip = floor(p);
    float best = 8.0;
    ivec2 bc = ivec2(0);
    vec2 bo = vec2(0.0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            ivec2 cc = ivec2(ip) + ivec2(x, y);
            float h = hcell(cc, c.seed);
            float h2 = hcell(cc, c.seed + 1u);
            vec2 o = vec2(0.5) + 0.38 * vec2(sin(t0 + TAU * h), cos(t1 + TAU * h2));
            vec2 d = vec2(cc) + o - p;
            float dd = dot(d, d);
            if (dd < best) { best = dd; bc = cc; bo = d; }
        }
    }
    float edge = 8.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            if (x == 0 && y == 0) { continue; }
            ivec2 cc = bc + ivec2(x, y);
            float h = hcell(cc, c.seed);
            float h2 = hcell(cc, c.seed + 1u);
            vec2 o = vec2(0.5) + 0.38 * vec2(sin(t0 + TAU * h), cos(t1 + TAU * h2));
            vec2 d = vec2(cc) + o - p;
            vec2 dv = d - bo;
            if (dot(dv, dv) > 1e-6) { edge = min(edge, dot(0.5 * (bo + d), normalize(dv))); }
        }
    }
    uint k = uint(hcell(bc, c.seed + 2u) * float(n)) % max(n, 1u);
    vec3 col = stop_lin(f0, k) * (1.0 - i.p0.w * 0.55 * clamp(best * 1.6, 0.0, 1.0));
    float seam = i.p0.z * 0.5;
    if (seam > 0.0) {
        float e = clamp(0.5 + (edge * sc - seam) * c.scale, 0.0, 1.0);
        col = mix(i.c0.rgb, col, e);
    }
    return paint(col, m, i, px, g);
}

vec4 waves_fill(Inst i, Ctx c, float m, vec2 px, Globals g) {
    uint f0 = uint(i.xf.x);
    uint n = uint(i.xf.y);
    float ang = i.p0.w;
    vec2 dir = vec2(-sin(ang), cos(ang));
    vec2 along = vec2(cos(ang), sin(ang));
    float ext = abs(c.half_size.x * dir.x) + abs(c.half_size.y * dir.y);
    float ext2 = abs(c.half_size.x * along.x) + abs(c.half_size.y * along.y);
    float v = dot(c.q, dir) / max(2.0 * ext, 1e-3) + 0.5;
    float s = dot(c.q, along) / max(2.0 * ext2, 1e-3) + 0.5;
    float aa = c.aa / max(2.0 * ext, 1e-3);
    float soft = max(i.p1.x, aa);
    float t = c.t * i.p0.z;
    vec3 col = stop_lin(f0, 0u);
    for (uint k = 1u; k < n; k++) {
        float fk = float(k);
        float h = hcell(ivec2(int(k), 3), c.seed);
        float fq = i.p0.y * (0.8 + 0.4 * h);
        float ph1 = fract(t * 0.2 * (1.0 + 0.3 * fk) + h);
        float ph2 = fract(-t * 0.13) * TAU + 1.7 * fk;
        float y = fk / float(n) + i.p0.x * (0.7 * sin(TAU * (fq * s + ph1)) + 0.3 * sin(TAU * fq * 2.3 * s + ph2));
        float shade = exp(-max(y - v, 0.0) / 0.025) * 0.18 * step(v, y);
        col *= 1.0 - shade;
        col = mix(col, stop_lin(f0, k), w_smoothstep(y - soft, y + soft, v));
    }
    return paint(col, m, i, px, g);
}

vec4 halftone_fill(
    Inst i,
    Ctx c,
    float m,
    vec2 px,
    Globals g,
    sampler2D backdrop,
    sampler2D source,
    BackdropEncoding enc
) {
    float pitch = max(i.p0.z, 1.0);
    float ang = i.p2.x;
    vec2 r = rot2(c.p - c.c, -ang) / pitch;
    vec2 base = floor(r - 0.5);
    int kind = int(i.p0.y + 0.5);
    float ink = 0.0;
    for (int y = 0; y <= 1; y++) {
        for (int x = 0; x <= 1; x++) {
            vec2 cc = base + vec2(float(x), float(y)) + 0.5;
            vec2 w = c.c + rot2(cc * pitch, ang);
            float cov_t = 1.0 - tone_at(i, c, w, kind, i.p0.w, g, backdrop, source, enc);
            float rad = sqrt(cov_t / PI) * 1.12;
            float d = (length(r - cc) - rad) * pitch;
            ink = max(ink, clamp(0.5 - d * c.scale, 0.0, 1.0));
        }
    }
    return paint(mix(i.c1.rgb, i.c0.rgb, ink), m, i, px, g);
}

vec4 shade_fill(
    Inst i,
    vec2 px,
    Globals g,
    sampler2D backdrop,
    sampler2D source,
    sampler2D blurred,
    BackdropEncoding enc
) {
    Ctx c = make_ctx(i, px);
    float m = fill_mask(c, i.aux.x);
    if (m <= 0.0) { return vec4(0.0); }
    switch (c.variant) {
        case 0: return liquid_metal(i, c, m, px, g);
        case 1: return mesh_gradient(i, c, m, px, g);
        case 2: return dither_fill(i, c, m, g, backdrop, source, enc);
        case 3: return grain_gradient(i, c, m, px, g);
        case 4: return fluted(i, c, m, px, g, backdrop, blurred, enc);
        case 5: return metaballs(i, c, m, px, g);
        case 6: return swirl_fill(i, c, m, px, g);
        case 7: return voronoi_fill(i, c, m, px, g);
        case 8: return waves_fill(i, c, m, px, g);
        case 9: return halftone_fill(i, c, m, px, g, backdrop, source, enc);
        default: return plastic(i, c, m, px, g);
    }
}

void main() {
    Globals g = fxGlobals;
    BackdropEncoding enc = fxBackdrop;
    vec2 px = recover_pixel(g);
    Inst i = fxInstance;
    vec4 shaded = shade_fill(i, px, g, uTex0, uTex1, uTex2, enc);
    fragColor = fx_fs(shaded, i, px, g, uTex0, enc);
}
