float shoot(float u) {
    float x = clamp(u, 0.0, 1.0);
    float m = 1.0 - x;
    return 3.0 * m * m * x * (-0.12) + 3.0 * m * x * x * 1.0 + x * x * x;
}

float beat_env(float x) {
    return (x < 0.0 ? exp(-(x / 0.018) * (x / 0.018)) : exp(-x / 0.085));
}

vec2 ping_shot(Ctx c, Inst i, float age, float dur) {
    vec2 o = i.aux.xy;
    vec2 dir = normalize(i.aux.zw);
    float travel = i.p2.x;
    float head_r = i.p2.z;
    if (age < 0.0) { return vec2(0.0); }
    float u = age / dur;
    if (c.reduced) {
        vec2 dest = o + dir * travel;
        float env = w_smoothstep(0.0, 0.2, age) * exp(-max(age - 0.2, 0.0) * 3.0);
        return vec2(env * gauss(length(c.p - dest), head_r * 3.0), 0.0);
    }
    float s_head = shoot(u);
    float s_tail = shoot(u - i.p2.y);
    vec2 hpos = o + dir * travel * s_head;
    vec2 tpos = o + dir * travel * s_tail;
    vec2 sd = segdist(c.p, tpos, hpos);
    float after = max(u - 1.0, 0.0);
    float cool = exp(-after * 3.5);
    float hr = head_r * (1.0 + 0.9 * (1.0 - cool));
    float tailw = head_r * 0.55 * (0.35 + 0.65 * sd.y);
    float tail = gauss(sd.x, tailw) * sd.y * sd.y * 0.8;
    float dh = length(c.p - hpos);
    float head = gauss(dh, hr) + 0.35 * bloom(dh - hr * 0.5, hr * 1.2, hr * 8.0);
    float e = (head + tail) * cool;
    float hot = gauss(dh, hr * 0.45) * cool * cool;
    float fr = 26.0 * (1.0 - exp(-age * 7.0));
    e += exp(-age * 10.0) * w_smoothstep(0.0, 0.03, age) * gauss(length(c.p - o) - fr, 2.0 + age * 6.0) * 0.5;
    return vec2(e, hot);
}

vec4 shade_pulse(
    vec2 pixel,
    Globals g,
    BackdropEncoding enc
) {
    Inst i = fxInstance;
    Ctx c = make_ctx(i, pixel);
    int n = int(i.p0.x + 0.5);
    float period = max(i.p0.y, 0.05);
    float reach = i.p0.z;
    float width = i.p0.w;
    float inten = i.p1.x;
    float occl = (effective_blend_mode(i, enc) == 0u ? i.p2.w : 1.0);
    float outside = w_smoothstep(-c.aa, c.aa, c.d);
    float e = 0.0;
    float hotv = 0.0;

    if (c.variant == 0) {
        if (c.reduced) {
            e = 0.35 * bloom(c.d, reach * 0.18, reach * 0.8);
        } else {
            for (int k = 0; k < n; k++) {
                float ph = fract(c.t / period + float(k) / float(n));
                float r = reach * (1.0 - pow(1.0 - ph, 2.2));
                float w = width * (1.0 + 2.2 * ph);
                float a = pow(1.0 - ph, 1.6) * w_smoothstep(0.0, 0.08, ph);
                float ring = gauss(c.d - r, w);
                float wash = w_smoothstep(r + w, r - w, c.d) * exp(-(r - c.d) / max(reach * 0.22, 1.0));
                e += a * (ring + 0.22 * wash);
            }
            e += 0.18 * bloom(c.d, reach * 0.1, reach * 0.6);
        }
        e *= outside;
    } else if (c.variant == 1) {
        float b = 0.5;
        if (!c.reduced) { b = 0.5 - 0.5 * cos(TAU * c.t / period); b = b * b * (3.0 - 2.0 * b); }
        float r = reach * (0.55 + 0.45 * b);
        e = (0.45 + 0.55 * b) * bloom(c.d, r, r * 5.0) * outside;
        hotv = 0.25 * b * gauss(max(c.d, 0.0), r * 0.25);
    } else if (c.variant == 2) {
        float beat = 0.3;
        float ring = 0.0;
        if (!c.reduced) {
            float tp = c.t / period;
            float kb = floor(tp);
            beat = 0.0;
            for (int k = -1; k < 3; k++) {
                float x = tp - (kb - float(k));
                beat += beat_env(x) + 0.62 * beat_env(x - 0.17);
                float age = x * period;
                if (age > 0.0) {
                    float rr = reach * (1.0 - exp(-age * 4.5));
                    ring += exp(-age * 3.2) * w_smoothstep(0.0, 0.03, age) * (1.0 - w_smoothstep(0.7, 1.3, age)) * gauss(c.d - rr, width * (1.0 + age * 3.0));
                }
            }
            float edge = reach + width * 16.0;
            ring *= 1.0 - w_smoothstep(edge * 0.8, edge, c.d);
        }
        float r = reach * 0.22 * (1.0 + 0.35 * beat);
        e = ((0.25 + 0.75 * beat) * bloom(c.d, r, reach) + 0.55 * ring) * outside;
        hotv = 0.35 * beat * gauss(max(c.d, 0.0), r * 0.25) * outside;
    } else if (c.variant == 3) {
        float dur = max(i.p1.z, 0.05);
        float age0 = c.t - i.p1.y;
        int shots = 1;
        float age = age0;
        if (i.p1.w > 0.0 && age0 > 0.0) {
            age = age0 - floor(age0 / i.p1.w) * i.p1.w;
            shots = 3;
        }
        for (int k = 0; k < shots; k++) {
            float a = age + float(k) * i.p1.w;
            if (a > age0 + 1e-4 || a > dur * 2.2) { break; }
            vec2 pe = ping_shot(c, i, a, dur);
            e += pe.x;
            hotv += pe.y;
        }
    } else {
        float dur = max(i.p1.z, 0.05);
        float age = c.t - i.p1.y;
        if (age >= 0.0 && age < dur) {
            float u = age / dur;
            float r = length(c.p - i.aux.xy);
            float inside = w_smoothstep(c.aa, -c.aa, c.d);
            if (c.reduced) {
                e = 0.06 * (1.0 - u) * w_smoothstep(0.0, 0.08, u) * inside;
            } else {
                float rr = reach * (1.0 - pow(1.0 - u, 3.0));
                float w = width * (1.0 + 3.0 * u);
                float fade = pow(1.0 - u, 1.5);
                float ring = gauss(r - rr, w) * fade * 0.55;
                float fill = w_smoothstep(rr + w, rr - w * 3.0, r) * 0.05 * (1.0 - u) * (1.0 - u) * w_smoothstep(0.0, 0.05, u);
                e = (ring * 0.7 + fill) * inside;
                hotv = ring * 0.1 * inside;
            }
        }
    }
    vec3 col = i.c0.rgb * e + i.c1.rgb * hotv;
    return finish(vec4(col * inten, (e + hotv) * occl * inten), pixel, g);
}

void main() {
    Globals g = fxGlobals;
    BackdropEncoding enc = fxBackdrop;
    vec2 pixel = runePixel;
    fragColor = fx_fs(shade_pulse(pixel, g, enc), fxInstance, pixel, g, uTex0, enc);
}
