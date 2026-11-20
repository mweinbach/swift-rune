vec3 fire_ramp(float T, vec3 c0, vec3 c1, vec3 c2) {
    vec3 col = mix(vec3(0.012, 0.009, 0.008), c0, w_smoothstep(0.04, 0.22, T));
    col = mix(col, c1, w_smoothstep(0.2, 0.5, T));
    col = mix(col, c2, w_smoothstep(0.45, 0.78, T));
    col = mix(col, vec3(1.0, 0.92, 0.74), w_smoothstep(0.8, 1.08, T));
    return col;
}

float fbm4(vec2 p0, uint seed) {
    vec2 p = p0; float a = 0.5; float s = 0.0;
    for (uint o = 0u; o < 4u; o++) {
        s += a * gnoise(p, seed + o * 131u);
        p = rot_mul(p) * 2.03;
        a *= 0.5;
    }
    return s / 0.9375;
}

vec4 flames(Ctx c, Inst i, BackdropEncoding enc) {
    float H = i.p0.x;
    float sc = max(i.p0.y, 1.0);
    float tr = c.t * i.p0.z;
    vec2 nrm = sd_grad(c);
    float up = clamp(-nrm.y, 0.0, 1.0);
    float span = w_smoothstep(c.half_size.x + 2.0, c.half_size.x - c.r * 0.9 - 2.0, abs(c.q.x));
    float hl = H * w_smoothstep(0.15, 0.95, up) * span;
    if (hl < 0.5) { return vec4(0.0); }
    float y = c.d + 1.5;
    float yn = y / hl;
    if (yn > 1.6 || yn < -0.2) { return vec4(0.0); }
    float x = c.p.x / sc;
    float fl = 1.0 + 0.2 * gnoise(vec2(x * 0.45, c.t * 1.3), c.seed + 7u) + 0.07 * gnoise(vec2(x * 1.1 + 9.0, c.t * 8.0), c.seed + 8u);
    float yh = yn / max(fl, 0.4);
    vec2 sw = vec2(0.0);
    if (i.p3.x > 0.0) { sw = i.p3.x * vec2(sin(y / sc * 0.7 + tr * 0.4), 0.0); }
    vec2 wq = vec2(x * 0.7, y / sc * 0.45 - tr * 1.05);
    vec2 w = vec2(gnoise(wq, c.seed), gnoise(wq + vec2(3.7, 1.9), c.seed + 1u)) * i.p2.x * (0.2 + 0.8 * yh);
    float n = fbm4(vec2(x * 1.05, y / sc * 0.5 - tr * 1.6) + w + sw, c.seed + 2u);
    float dens = (1.0 - yh) * 1.2 + n * 0.8 - 0.08;
    float body = w_smoothstep(0.0, 0.06, dens) * w_smoothstep(-0.2, 0.05, yn);
    float T = clamp(dens * (0.95 - 0.5 * yh), 0.0, 1.1);
    vec3 col = fire_ramp(T, i.c0.rgb, i.c1.rgb, i.c2.rgb);
    float e = body * (0.3 + 0.75 * T * T);
    vec3 emis = col * e;
    float smoke = w_smoothstep(-0.32, -0.02, dens) * (1.0 - body) * w_smoothstep(0.35, 0.9, yh) * 0.12;
    float bg = i.p2.z * 0.22 * exp(-max(c.d, 0.0) / max(hl * 0.12, 1.0)) * w_smoothstep(-1.0, 0.5, c.d) * span;
    emis += i.c1.rgb * bg;
    float occl = (effective_blend_mode(i, enc) == 0u ? i.p2.w : 1.0);
    return vec4(emis, body * occl + smoke);
}

vec3 blackbody(float k) {
    float t = k / 100.0;
    float g = clamp((99.4708 * log(max(t, 1.0)) - 161.1196) / 255.0, 0.0, 1.0);
    float b = (t <= 19.0 ? 0.0 : clamp((138.5177 * log(max(t - 10.0, 1.0)) - 305.0448) / 255.0, 0.0, 1.0));
    return to_lin(vec3(1.0, g, b));
}

vec3 flame_light(float T, float gain) {
    float x = max(T, 0.0);
    float e = gain * x * x * x * w_smoothstep(0.08, 0.3, x);
    return vec3(1.0) - exp(-blackbody(1000.0 + 1700.0 * min(x, 1.3)) * e);
}

vec4 sim_at(sampler2D source, vec2 uv) {
    vec2 dim = vec2(textureSize(source, 0).x, textureSize(source, 0).y);
    vec2 g = uv * dim - 0.5;
    vec2 i = floor(g);
    vec2 f = g - i;
    vec2 w0 = (1.0 - f) * (1.0 - f) * (1.0 - f) / 6.0;
    vec2 w1 = (4.0 - 6.0 * f * f + 3.0 * f * f * f) / 6.0;
    vec2 w3 = f * f * f / 6.0;
    vec2 w2 = 1.0 - w0 - w1 - w3;
    vec2 s0 = w0 + w1;
    vec2 s1 = w2 + w3;
    vec2 o0 = (i - 0.5 + w1 / s0) / dim;
    vec2 o1 = (i + 1.5 + w3 / s1) / dim;
    vec4 a = sampleTopLeft(source, vec2(o0.x, o0.y), 0.0);
    vec4 b = sampleTopLeft(source, vec2(o1.x, o0.y), 0.0);
    vec4 c = sampleTopLeft(source, vec2(o0.x, o1.y), 0.0);
    vec4 d = sampleTopLeft(source, vec2(o1.x, o1.y), 0.0);
    return mix(mix(a, b, s1.x), mix(c, d, s1.x), s1.y);
}

vec4 sim_flames(Ctx c, Inst i, sampler2D source) {
    vec2 ext = i.aux.zw;
    vec2 uv = (c.p - i.aux.xy) / ext;
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) { return vec4(0.0); }
    vec4 s = sim_at(source, uv);
    float T = s.z;
    float m = min(min(c.p.x - i.aux.x, i.aux.x + i.p3.y - c.p.x), c.p.y - i.aux.y);
    float win = w_smoothstep(0.0, 18.0, m);
    vec3 rgb = flame_light(T, 6.0) * win;
    float sm = s.w * win;
    float a = 0.0;
    if (sm > 0.002) {
        a = (1.0 - exp(-sm * 1.2)) * i.p2.w * 1.6;
        float lit = 0.0;
        for (int k = 1; k < 5; k++) {
            float tk = sim_at(source, uv + vec2(0.0, float(k) * 7.0 / ext.y)).z;
            lit += tk * tk / float(k);
        }
        vec3 warm = vec3(1.0, 0.45, 0.18) * min(lit, 1.0) * 0.3;
        rgb += a * (vec3(0.11, 0.11, 0.115) + warm);
    }
    float vis = w_smoothstep(0.12, 0.35, T) * win;
    return vec4(rgb, min(a + vis * i.p2.w * 0.5, 1.0));
}

vec4 plasma(Ctx c, Inst i) {
    float sc = max(i.p0.y, 1.0);
    float thick = max(i.p0.x * i.p2.y * 0.3, 2.5);
    vec2 pr = rrect_perim(c.q, c.half_size, c.r);
    float u = pr.x / pr.y;
    float d = c.d - thick * 0.45;
    if (abs(d) > thick * 4.0) { return vec4(0.0); }
    float P = max(round(pr.y / (sc * 2.5)), 3.0);
    float flow = c.t * i.p0.z * (0.35 + 0.25 * i.p3.x);
    float warp = 0.6 * pgnoise(vec2(u * P - flow * 0.6, c.t * 0.35), int(P), c.seed + 3u);
    float r1 = 1.0 - abs(pgnoise(vec2(u * P - flow * 1.4, d / sc * 3.2 + warp), int(P), c.seed));
    float r2 = 1.0 - abs(pgnoise(vec2(u * P * 2.0 + flow * 1.1, d / sc * 4.5 - warp - c.t * 0.6), int(P * 2.0), c.seed + 1u));
    float fil = pow(r1, 10.0) + 0.45 * pow(r2, 12.0);
    float breathe = 0.78 + 0.22 * pgnoise(vec2(u * 3.0 - c.t * 0.25, c.t * 0.2), 3, c.seed + 5u);
    float env = exp(-(d * d) / (thick * thick));
    float halo = exp(-max(d, 0.0) / (thick * 0.9)) * w_smoothstep(-thick, 0.0, d);
    float E = env * (0.18 + 1.2 * fil) * breathe;
    vec3 rgb = i.c0.rgb * halo * 0.28 + i.c1.rgb * E * 0.55 + i.c2.rgb * fil * env * breathe * 0.9
               + vec3(1.0) * pow(fil, 3.0) * env * breathe * 0.35;
    return vec4(rgb, (E * 0.5 + halo * 0.1) * i.p2.w * 2.0);
}

vec4 shade_fire(
    vec2 pixel,
    Globals g,
    sampler2D source,
    BackdropEncoding enc
) {
    Inst i = fxInstance;
    Ctx c = make_ctx(i, pixel);
    float inten = i.p0.w;
    vec4 o = vec4(0.0);
    if (c.variant == 0) {
        o = flames(c, i, enc);
    } else if (c.variant == 1) {
        o = plasma(c, i);
    } else if (c.variant == 4) {
        o = sim_flames(c, i, source);
    }
    vec3 emis = o.rgb;
    float alpha = o.a;

    uint ef = uint(i.xf.x);
    uint en = uint(i.xf.y);
    for (uint k = 0u; k < en; k++) {
        vec4 a = tableEntry(ef + k * 2u);
        vec4 b = tableEntry(ef + k * 2u + 1u);
        vec2 sd = segdist(c.p, a.xy - a.zw, a.xy);
        float T = b.y;
        float core = gauss(sd.x, b.x);
        float halo = gauss(sd.x, b.x * 3.0) * 0.12;
        emis += flame_light(0.45 + T * 0.75, 6.0) * (core * 1.4 + halo) * T;
        alpha += core * T * 0.5;
    }
    return finish(vec4(emis * inten, min(alpha, 1.0) * inten), pixel, g);
}

void main() {
    Globals g = fxGlobals;
    BackdropEncoding enc = fxBackdrop;
    vec2 pixel = recover_pixel(g);
    fragColor = fx_fs(shade_fire(pixel, g, uTex1, enc), fxInstance, pixel, g, uTex0, enc);
}
