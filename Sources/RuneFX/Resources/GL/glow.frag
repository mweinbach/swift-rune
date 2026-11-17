vec3 aura_palette(float u, vec3 a, vec3 b, vec3 c) {
    float x = fract(u) * 3.0;
    float w0 = w_smoothstep(1.0, 0.0, min(x, 3.0 - x));
    float w1 = w_smoothstep(1.0, 0.0, abs(x - 1.0));
    float w2 = w_smoothstep(1.0, 0.0, abs(x - 2.0));
    return (a * w0 + b * w1 + c * w2) / max(w0 + w1 + w2, 1e-4);
}

float mask_tent(sampler2D source, vec2 uv, float lod) {
    vec2 dims = vec2(textureSize(source, 0).x, textureSize(source, 0).y);
    vec2 texel = exp2(lod) / max(dims, vec2(1.0));
    vec2 o = texel * 0.5;
    float s = sampleTopLeft(source, uv + vec2(o.x, o.y), lod).a;
    s += sampleTopLeft(source, uv + vec2(-o.x, o.y), lod).a;
    s += sampleTopLeft(source, uv + vec2(o.x, -o.y), lod).a;
    s += sampleTopLeft(source, uv + vec2(-o.x, -o.y), lod).a;
    return s * 0.25;
}

vec4 shade_glow(
    vec2 pixel,
    Globals g,
    sampler2D backdrop,
    sampler2D source,
    BackdropEncoding enc
) {
    Inst i = fxInstance;
    Ctx c = make_ctx(i, pixel);
    float radius = i.p0.x;
    float intensity = i.p0.y;
    float inner = i.p0.z;
    float occl = (effective_blend_mode(i, enc) == 0u ? i.p0.w : 1.0);
    float heat = i.p1.z;
    float hot = i.p1.w;

    float b = 0.0;
    if (!c.reduced && i.p1.y > 0.0) {
        b = 0.5 - 0.5 * cos(TAU * c.t / i.p1.y);
        b = b * b * (3.0 - 2.0 * b);
    }
    float amp = i.p1.x;
    intensity *= (1.0 - amp) + amp * b;
    radius *= 1.0 + 0.22 * amp * b;
    radius *= mix(0.72, 1.0, heat);
    intensity *= pow(max(heat, 0.0), 1.6);
    vec3 tint = cooled(i.c0.rgb, heat);
    float reach = radius * i.p2.z;

    vec3 light = vec3(0.0);
    float alpha = 0.0;
    float edge = w_smoothstep(-c.aa, c.aa, c.d);

    if (c.variant == 3) {
        vec2 uv = (c.p - i.aux2.xy) / i.aux2.zw;
        float rpx = radius * c.scale;
        float base = log2(max(rpx, 1.0)) - 0.6;
        float m = 0.45 * mask_tent(source, uv, max(base - 1.0, 0.0))
                + 0.35 * mask_tent(source, uv, max(base, 0.0))
                + 0.2 * mask_tent(source, uv, base + 1.3);
        float core = sampleTopLeft(source, uv, 0.0).a;
        float gl = knee(m * 1.25 * intensity) * 1.1;
        float hotc = core * hot * w_smoothstep(0.55, 1.0, heat);
        light = tint * gl + i.c1.rgb * hotc * intensity * 0.6;
        alpha = min(gl * occl, 1.0);
        return finish(vec4(light, alpha), pixel, g);
    }

    if (c.variant == 0) {
        float out_g = bloom(c.d, radius, reach);
        float in_g = inner * 0.7 * exp(min(c.d, 0.0) / max(0.4 * radius, 1e-4));
        float gl = mix(in_g, out_g, edge);
        float corew = gauss(max(c.d, 0.0), 0.3 * radius) * hot * w_smoothstep(0.6, 1.0, heat);
        vec3 col = mix(tint, i.c1.rgb, corew * 0.8);
        float e = knee(gl * intensity * 1.1);
        light = col * e;
        alpha = e * occl;
    } else if (c.variant == 1) {
        float w = max(i.p2.y, c.aa * 0.75);
        float core = gauss(c.d, w);
        float out_g = bloom(c.d, radius, reach) * edge;
        float in_g = inner * bloom(-c.d, radius * 0.6, reach) * (1.0 - edge);
        vec3 corec = mix(tint, i.c1.rgb, 0.7 * hot * w_smoothstep(0.5, 1.0, heat));
        float e = knee((out_g + in_g) * intensity);
        light = corec * core * 1.4 * intensity + tint * e * 0.9;
        alpha = core * 0.6 * intensity + e * occl;
    } else {
        vec2 pr = rrect_perim(c.q, c.half_size, c.r);
        float u = pr.x / pr.y;
        float flow = 0.0;
        if (!c.reduced) { flow = c.t * i.p2.x; }
        vec3 col = aura_palette(u - flow, tint, i.c1.rgb, i.c2.rgb);
        float wob = 0.85 + 0.15 * pgnoise(vec2(u * 6.0, flow * 1.7 + 3.0), 6, c.seed);
        float out_g = bloom(c.d, radius, reach) * edge;
        float in_g = inner * exp(min(c.d, 0.0) / max(0.55 * radius, 1e-4)) * (1.0 - edge);
        float hair = gauss(c.d + 0.6, max(i.p2.y, c.aa)) * 0.9;
        float lit = knee((out_g + in_g) * wob * intensity * 1.1);
        light = col * lit + mix(col, vec3(1.0), 0.6) * hair * intensity * hot;
        alpha = lit * occl;
    }
    return finish(vec4(light, alpha), pixel, g);
}

void main() {
    Globals g = fxGlobals;
    BackdropEncoding enc = fxBackdrop;
    vec2 pixel = runePixel;
    fragColor = fx_fs(shade_glow(pixel, g, uTex0, uTex1, enc), fxInstance, pixel, g, uTex0, enc);
}
