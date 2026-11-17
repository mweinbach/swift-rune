float extras_cover(Ctx c, float feather) {
    return w_smoothstep(c.aa * 0.5, -max(feather, c.aa), c.d);
}

vec4 shade_extras(
    vec2 pixel,
    Inst i,
    Globals g,
    sampler2D source,
    BackdropEncoding enc
) {
    Ctx c = make_ctx(i, pixel);

    if (c.variant == 0) {
        float m;
        if (i.p1.x > 0.5) {
            m = sampleTopLeft(source, (c.p - i.aux2.xy) / i.aux2.zw, 0.0).a;
        } else {
            m = extras_cover(c, max(i.p1.z, c.aa * 1.5));
        }
        if (m <= 0.0) { return vec4(0.0); }
        float ta = tan(i.p0.z);
        float span = c.half_size.x + c.half_size.y * abs(ta) + i.p0.y * 2.5;
        float x = c.q.x + c.q.y * ta;
        float sheen;
        if (c.reduced) {
            sheen = 0.35 * (0.5 - 0.5 * cos(TAU * c.t / max(i.p0.x, 0.1)));
        } else {
            float ph = fract(c.t / max(i.p0.x, 0.1));
            float travel = clamp(ph / max(1.0 - i.p1.y, 0.05), 0.0, 1.0);
            float e = travel * travel * (3.0 - 2.0 * travel);
            float xc = mix(-span, span, e);
            sheen = gauss(x - xc, i.p0.y) + 0.35 * gauss(x - xc, i.p0.y * 2.6);
        }
        vec3 base = i.c1.rgb * i.c1.a;
        return finish(vec4(base * m + i.c0.rgb * sheen * i.p0.w * m, i.c1.a * m + sheen * i.p0.w * m * 0.2), pixel, g);
    }
    if (c.variant == 1) {
        uint f0 = uint(i.xf.x);
        uint n = uint(i.xf.y);
        float body = 0.0;
        float hot = 0.0;
        float halo = 0.0;
        for (uint k = 0u; k < n; k++) {
            vec4 a = tableEntry(f0 + k * 2u);
            vec4 b = tableEntry(f0 + k * 2u + 1u);
            float S = max(a.z, 0.01);
            float env = a.w;
            vec2 rel = c.p - a.xy;
            float r = length(rel);
            if (r > S * 1.6) { continue; }
            vec2 l = vec2(b.x * rel.x - b.y * rel.y, b.y * rel.x + b.x * rel.y);
            vec2 ax = max(abs(l) / S, vec2(1e-6));
            float gg = pow(pow(ax.x, 0.55) + pow(ax.y, 0.55), 1.0 / 0.55);
            float w = c.aa * 0.75 / S;
            float m = 1.0 - w_smoothstep(1.0 - w, 1.0 + w, gg);
            body += env * m;
            hot += env * m * (1.0 - gg) * (1.0 - gg);
            halo += env * gauss(r, S * 0.32);
        }
        vec3 tint = i.c0.rgb;
        vec3 col = mix(tint, vec3(1.0), 0.3) * body + vec3(1.0) * hot * 0.8 + tint * halo * 0.12;
        return finish(vec4(col * i.p0.w, min(body * 0.9 + halo * 0.05, 1.0) * i.p0.w), pixel, g);
    }
    if (c.variant == 2) {
        float m = extras_cover(c, max(i.p0.w, c.aa));
        if (m <= 0.0) { return vec4(0.0); }
        float sc = max(i.p0.x, 1.0);
        vec2 q = c.p / sc;
        float t = c.reduced ? 0.0 : c.t * i.p0.y;
        float uy = (c.p.y - i.rect.y) / i.rect.w;
        vec3 col = vec3(0.0);
        vec3 cols[3] = vec3[3](i.c0.rgb, i.c1.rgb, i.c2.rgb);
        uint f0 = uint(i.xf.x);
        uint ns = uint(i.xf.y);
        float fx = clamp((c.p.x - i.rect.x) / i.rect.z, 0.0, 1.0) * float(ns - 1u);
        uint x0 = min(uint(fx), ns - 2u);
        float fr = fx - float(x0);
        for (int k = 0; k < 3; k++) {
            float fk = float(k);
            uint yb = f0 + uint(k) * 2u * (ns >> 2u);
            uint wb = yb + (ns >> 2u);
            float wv = mix(dat1(wb, x0), dat1(wb, x0 + 1u), fr);
            float yk = mix(dat1(yb, x0), dat1(yb, x0 + 1u), fr);
            float band = gauss(uy - yk, 0.13 + 0.05 * fk);
            float rays = 0.65 + 0.35 * gnoise(vec2(q.x * 5.0 + wv * 3.0, t * 0.5 + fk), c.seed + 9u);
            float hem = w_smoothstep(yk + 0.16, yk - 0.02, uy) * 0.5 + 0.5;
            col += cols[k] * band * rays * hem;
        }
        float a = (effective_blend_mode(i, enc) == 0u ? lum(col) * 0.4 : min(max(col.r, max(col.g, col.b)), 1.0));
        return finish(vec4(col * i.p0.z * m, a * i.p0.z * m), pixel, g);
    }
    float m = extras_cover(c, max(i.p0.z, c.aa));
    if (m <= 0.0) { return vec4(0.0); }
    uint frame = (i.p0.y > 0.0 && !c.reduced) ? uint(floor(c.t * i.p0.y)) : 0u;
    uvec2 ip = uvec2(pixel);
    float n = u01(ip.x + pcg(ip.y + pcg(frame + c.seed))) + u01(ip.y * 7919u + pcg(ip.x + 17u + frame)) - 1.0;
    float a = i.p0.x * m;
    if (n >= 0.0) { return vec4(vec3(n * a), n * a); }
    return vec4(0.0, 0.0, 0.0, -n * a);
}

void main() {
    Globals g = fxGlobals;
    BackdropEncoding enc = fxBackdrop;
    vec2 pixel = runePixel;
    Inst i = fxInstance;
    vec4 shaded = shade_extras(pixel, i, g, uTex1, enc);
    fragColor = fx_fs(shaded, i, pixel, g, uTex0, enc);
}
