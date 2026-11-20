vec3 frosted_glass(vec3 c, float k) {
    float l = lum(c);
    vec3 sat = max(mix(vec3(l), c, 1.0 + 0.9 * k), vec3(0.0));
    vec3 e = to_srgb(sat);
    return to_lin(e * (1.0 - 0.32 * k) + vec3(0.11 * k));
}

float lens_sd(Inst i, vec2 q, vec2 half_size, float r, vec2 ctr) {
    float da = sd_rrect(q, half_size, r);
    if (i.p3.z <= 0.0) { return da; }
    vec2 cb = i.p3.xy + i.p3.zw * 0.5 - ctr;
    float db = sd_rrect(q - cb, i.p3.zw * 0.5, i.p2.w);
    return mix(smin(da, db, i.p2.z), db, i.shape.w);
}

float bend_at(float t) {
    float u = clamp(1.0 - t, 0.0, 0.9999);
    float pw = 3.0;
    float slope = pow(u, pw - 1.0) * pow(max(1.0 - pow(u, pw), 1e-6), 1.0 / pw - 1.0);
    float tilt = atan(min(slope, 1e4));
    float bent = asin(sin(tilt) / 1.5);
    return tan(tilt - bent);
}

vec4 shade_distort(
    vec2 pixel,
    Inst i,
    Globals g,
    sampler2D backdrop,
    sampler2D blurred,
    BackdropEncoding enc
) {
    Ctx c = make_ctx(i, pixel);
    float s = c.scale;

    if (c.variant == 0) {
        float H = i.p0.x;
        float m;
        if (i.p1.x > 0.5) {
            m = w_smoothstep(c.aa, -c.aa * 8.0, c.d);
        } else {
            float above = i.rect.y - c.p.y;
            float side = w_smoothstep(c.half_size.x + 2.0, c.half_size.x - c.r - 4.0, abs(c.q.x));
            m = w_smoothstep(1.0, 1.0 + H * 0.3, above) * (1.0 - w_smoothstep(H * 0.45, H, above)) * side;
        }
        if (m <= 0.0) { return vec4(0.0); }
        float t = c.reduced ? 0.0 : c.t;
        vec2 q = c.p / max(i.p0.y, 1.0) + vec2(0.0, t * i.p0.z);
        vec2 o = vec2(fbm3(q, c.seed), fbm3(q * vec2(1.0, 0.7) + vec2(7.3, 2.1), c.seed + 5u)) * i.p0.w;
        vec4 col = bd(c.p + o * m, s, g, backdrop, enc);
        return vec4(col.rgb, 1.0) * w_smoothstep(0.0, 0.02, m);
    }
    if (c.variant == 1) {
        float age = c.t - i.p1.x;
        float dur = max(i.p1.y, 0.05);
        if (age < 0.0 || age > dur) { return vec4(0.0); }
        float u = age / dur;
        vec2 rel = c.p - i.aux.xy;
        float r = length(rel);
        vec2 dir = rel / max(r, 1e-3);
        float fade = (1.0 - u) * (1.0 - u);
        if (c.reduced) {
            float gl = gauss(r, i.p0.x * 0.25) * 0.12 * fade * w_smoothstep(0.0, 0.1, u);
            return vec4(bd(c.p, s, g, backdrop, enc).rgb * gl, 0.0);
        }
        float R = i.p0.x * (1.0 - pow(1.0 - u, 2.6));
        float w = i.p0.y * (1.0 + 1.5 * u);
        float x = (r - R) / w;
        float f = x * exp(-x * x) * 2.33;
        vec2 off = -dir * f * i.p0.z * fade;
        float ca = i.p0.w * abs(f) * fade;
        float rr = bd(c.p + off * (1.0 + ca), s, g, backdrop, enc).r;
        float gg = bd(c.p + off, s, g, backdrop, enc).g;
        float bb = bd(c.p + off * (1.0 - ca), s, g, backdrop, enc).b;
        float lit = max(-f, 0.0) * 0.12 * fade * lum(vec3(rr, gg, bb));
        float m = w_smoothstep(0.0, 0.01, abs(f) * fade);
        return vec4(vec3(rr, gg, bb) + lit, 1.0) * m;
    }
    if (c.variant == 2) {
        float d = lens_sd(i, c.q, c.half_size, c.r, c.c);
        float presence = i.p1.x;
        float e = 0.5;
        float gx = lens_sd(i, c.q + vec2(e, 0.0), c.half_size, c.r, c.c) - lens_sd(i, c.q - vec2(e, 0.0), c.half_size, c.r, c.c);
        float gy = lens_sd(i, c.q + vec2(0.0, e), c.half_size, c.r, c.c) - lens_sd(i, c.q - vec2(0.0, e), c.half_size, c.r, c.c);
        vec2 nrm = vec2(gx, gy) / max(length(vec2(gx, gy)), 1e-5);
        float coverage = clamp(0.5 - d * s, 0.0, 1.0);
        float sd = lens_sd(i, c.q - vec2(0.0, 5.0 * presence), c.half_size, c.r, c.c);
        float fall = exp(-pow(max(sd + 2.0, 0.0), 2.0) / (2.0 * 9.0 * 9.0));
        float contact = exp(-pow(max(d, 0.0), 2.0) / 6.0);
        float dark = min(i.p1.z * presence * (0.55 * fall + 0.45 * contact), 1.0) * (1.0 - coverage);
        if (coverage <= 0.0) {
            return vec4(0.0, 0.0, 0.0, dark);
        }
        float depth = -d;
        float bevel = max(i.p0.x, 0.5);
        float tt = clamp(depth / bevel, 0.0, 1.0);
        float bend = i.p0.y * bend_at(tt) * presence;
        float mag = mix(1.0, i.p0.w, presence);
        vec2 ctr = c.c;
        vec2 inward = -nrm;
        float dsp = i.p0.z;
        vec2 local = c.p - ctr;
        vec2 srcg = ctr + (local + inward * bend) / mag;
        vec2 srcr = ctr + (local + inward * bend * (1.0 - dsp)) / mag;
        vec2 srcb = ctr + (local + inward * bend * (1.0 + dsp)) / mag;
        vec3 col = vec3(
            bd(srcr, s, g, backdrop, enc).r,
            bd(srcg, s, g, backdrop, enc).g,
            bd(srcb, s, g, backdrop, enc).b
        );
        float frost = i.p1.y;
        if (frost > 0.0 && i.xf.x > 0.5) {
            vec3 blr = vec3(
                bdb(srcr, s, g, blurred, enc).r,
                bdb(srcg, s, g, blurred, enc).g,
                bdb(srcb, s, g, blurred, enc).b
            );
            col = mix(col, blr, i.xf.y);
            float k = presence * w_smoothstep(0.0, 0.6, frost);
            col = frosted_glass(col, k);
            uvec2 ip = uvec2(pixel);
            float n = u01(ip.x + pcg(ip.y + 7u)) - u01(ip.x * 7919u + pcg(ip.y + 31u));
            col = to_lin(max(to_srgb(col) + vec3(n * 1.6 / 255.0 * k), vec3(0.0)));
        } else {
            float rim = bend / max(1.118 * i.p0.y, 1e-3);
            float soften = min(pow(rim, 1.5) * 0.55, 1.0);
            if (soften > 1e-3 || frost > 0.0) {
                float rad = mix(1.2, 10.0, frost);
                float j = ign(pixel) * TAU;
                vec3 acc = vec3(0.0);
                for (int k = 0; k < 8; k++) {
                    float a = j + float(k) * 2.39996;
                    float rr = rad * sqrt((float(k) + 0.5) / 8.0);
                    acc += bd(srcg + vec2(cos(a), sin(a)) * rr, s, g, backdrop, enc).rgb;
                }
                acc /= 8.0;
                col = mix(col, acc, clamp(max(soften, frost), 0.0, 1.0));
            }
        }
        col = mix(col, col * i.c0.rgb, i.p2.y * presence);
        float la = i.p2.x;
        vec2 L = vec2(cos(la), sin(la));
        float facing = max(dot(nrm, L), 0.0);
        float away = max(-dot(nrm, L), 0.0);
        float sky = clamp(0.5 - 0.5 * c.q.y / c.half_size.y, 0.0, 1.0);
        float rimk = i.p1.w;
        float fres = pow(1.0 - tt, 3.0) * 0.05 * (0.25 + 0.75 * sky);
        float line = gauss(depth - 0.75, 0.55);
        float glow = gauss(depth - 1.4, 2.4);
        float spec = line * (0.9 * pow(facing, 2.5) + 0.35 * pow(away, 3.0)) + glow * 0.1 * pow(facing, 4.0);
        float inner = gauss(tt - 0.32, 0.18) * away * away * 0.06;
        float edge = gauss(depth - 0.3, 0.45) * 0.12;
        float light = (0.004 + fres + spec + inner + edge) * presence * rimk;
        col = col * (1.0 - 0.04 * presence) + vec3(light);
        vec3 base = bd(c.p, s, g, backdrop, enc).rgb * (1.0 - dark);
        return vec4(mix(base, col, coverage), 1.0);
    }
    if (c.variant == 3) {
        float feather = max(i.p1.w, c.aa);
        float m = w_smoothstep(feather * 0.5, -feather * 0.5, c.d);
        if (m <= 0.0) { return vec4(0.0); }
        vec2 uv = c.q / c.half_size;
        float k = i.p0.x;
        vec2 bu = uv * (1.0 + k * dot(uv, uv)) / (1.0 + k);
        float inside = w_smoothstep(1.0, 0.985, max(abs(bu.x), abs(bu.y)));
        vec2 src = c.c + bu * c.half_size;
        float ca = i.p0.w;
        vec3 col = vec3(
            bd(src + vec2(ca, 0.0), s, g, backdrop, enc).r,
            bd(src, s, g, backdrop, enc).g,
            bd(src - vec2(ca, 0.0), s, g, backdrop, enc).b
        );
        float gw = 3.0;
        vec3 gl = (
            bd(src + vec2(gw, 0.0), s, g, backdrop, enc).rgb +
            bd(src - vec2(gw, 0.0), s, g, backdrop, enc).rgb +
            bd(src + vec2(0.0, gw), s, g, backdrop, enc).rgb +
            bd(src - vec2(0.0, gw), s, g, backdrop, enc).rgb
        ) * 0.25;
        col += gl * i.p1.y;
        float per = max(i.p0.y, 3.0 * c.aa);
        float sl = 0.5 + 0.5 * cos(TAU * (c.p.y - i.rect.y) / per);
        col *= 1.0 - i.p0.z * (1.0 - sl);
        uint col3 = uint(floor(pixel.x)) % 3u;
        vec3 grille = (col3 == 0u ? vec3(1.0, 0.94, 0.94) : (col3 == 1u ? vec3(0.94, 1.0, 0.94) : vec3(0.94, 0.94, 1.0)));
        col *= grille;
        float roll = c.reduced ? 0.0 : gauss(fract((c.p.y - i.rect.y) / i.rect.w - c.t * 0.12) - 0.5, 0.06) * i.p1.z;
        col += vec3(roll) * 0.06;
        col *= 1.0 - i.p1.x * pow(dot(uv, uv) * 0.5, 1.5);
        col *= inside;
        return vec4(col, 1.0) * m;
    }
    float feather = max(i.p0.w, c.aa);
    float m = w_smoothstep(feather * 0.5, -feather * 0.5, c.d);
    if (m <= 0.0) { return vec4(0.0); }
    vec2 o = i.p0.xy;
    float gx = 0.0;
    if (i.p0.z > 0.0 && !c.reduced) {
        float slice = floor((c.p.y - i.rect.y) / 6.0);
        float fr = floor(c.t * 12.0);
        uint hsl = hu(c.seed + uint(int(slice)), uint(int(fr)));
        if (u01(hsl) < 0.12 * i.p0.z) { gx = (u01(hsl + 1u) - 0.5) * 16.0 * i.p0.z; }
    }
    vec2 p = c.p + vec2(gx, 0.0);
    vec3 col = vec3(
        bd(p + o, s, g, backdrop, enc).r,
        bd(p, s, g, backdrop, enc).g,
        bd(p - o, s, g, backdrop, enc).b
    );
    return vec4(col, 1.0) * m;
}

void main() {
    Globals g = fxGlobals;
    BackdropEncoding enc = fxBackdrop;
    vec2 pixel = recover_pixel(g);
    Inst i = fxInstance;
    vec4 shaded = shade_distort(pixel, i, g, uTex0, uTex2, enc);
    fragColor = fx_fs(shaded, i, pixel, g, uTex0, enc);
}
