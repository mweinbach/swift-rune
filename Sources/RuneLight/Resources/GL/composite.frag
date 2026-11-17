vec4 vis_at(
    vec2 px,
    float zr,
    uint layer
) {
    ivec2 fsz = ivec2(F.sf.zw);
    vec2 f = px * F.gs.z - 0.5;
    ivec2 b = ivec2(floor(f));
    vec2 w = fract(f);
    vec4 acc = vec4(0.0);
    float wsum = 0.0;
    vec4 nearest = vec4(1.0);
    float best = 1e9;
    for (int k = 0; k < 4; k += 1) {
        ivec2 o = ivec2(k & 1, k >> 1);
        ivec2 q = clamp(b + o, ivec2(0), fsz - ivec2(1));
        vec4 v = texelFetch(uTex4, q + ivec2(0, int(layer) * int(F.sf.w)), 0);
        ivec2 qp = clamp(ivec2((vec2(q) + 0.5) / F.gs.z), ivec2(0), ivec2(F.sf.xy) - ivec2(1));
        float dz = abs(texelFetch(uTex3, qp, 0).w - zr);
        float bw = choose(1.0 - w.x, w.x, o.x == 1) * choose(1.0 - w.y, w.y, o.y == 1);
        float ww = bw / (1.0 + dz * dz * 4.0);
        acc = acc + v * ww;
        wsum = wsum + ww;
        if (dz < best) {
            best = dz;
            nearest = v;
        }
    }
    return choose(nearest, acc / wsum, wsum > 1e-3);
}

float ggx(float nh, float a) {
    float a2 = a * a;
    float d = nh * nh * (a2 - 1.0) + 1.0;
    return a2 / (RL_PI * d * d);
}

vec3 shoulder(vec3 x) {
    float k = 0.8;
    vec3 over = max(x - vec3(k), vec3(0.0));
    return min(x, vec3(k)) + (1.0 - k) * (vec3(1.0) - exp(-over / (1.0 - k)));
}

vec3 to_srgb(vec3 c) {
    vec3 lo = c * 12.92;
    vec3 hi = 1.055 * pow(max(c, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055;
    return mix(hi, lo, lessThanEqual(c, vec3(0.0031308)));
}

float ign(vec2 p) {
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void main() {
    // Input UI textures and the destination follow the host GL framebuffer orientation.
    vec2 px = vec2(gl_FragCoord.x, F.sf.y - gl_FragCoord.y);
    vec4 base = texelFetch(uTex1, ivec2(gl_FragCoord.xy), 0);
    vec4 text = F.stage.z != 0u ? texelFetch(uTex2, ivec2(gl_FragCoord.xy), 0) : vec4(0.0);
    vec4 g = texelFetch(uTex3, ivec2(px), 0);
    uint id = uint(g.y) + uint(g.z) * 1024u;
    float sd = g.x;
    float zr = g.w;
    vec2 grad = vec2(0.0);
    vec3 n = vec3(0.0, 0.0, 1.0);
    float gloss = F.bg.x;
    float rough = F.bg.y;
    uint fl = 0u;
    float rim = 0.0;
    bool emissive = false;
    if (id > 0u) {
        Prim pr = primAt(int(id) - 1);
        const vec2 e = vec2(0.5, 0.0);
        grad = vec2(prim_sd(pr, px + e.xy) - prim_sd(pr, px - e.xy),
                    prim_sd(pr, px + e.yx) - prim_sd(pr, px - e.yx));
        float magnitude = length(grad);
        grad = magnitude > 1e-5 ? grad / magnitude : vec2(0.0);
        fl = flags_of(pr);
        gloss = pr.mat.x;
        rough = pr.mat.y;
        emissive = (fl & F_EMIT) != 0u;
        if ((fl & F_RAISED) != 0u) {
            float bw = max(pr.z.z, 0.5);
            float x = clamp(-sd / bw, 0.0, 1.0);
            float slope = pr.z.w / bw * 3.0 * (1.0 - x) * (1.0 - x);
            n = normalize(vec3(grad * slope, 1.0));
        }
        rim = F.bg.w * (1.0 - w_smoothstep(0.0, 2.0, -sd)) * choose(0.0, 1.0, (fl & F_OCC) != 0u);
    }

    vec3 P = vec3(px, zr + 0.35);
    vec3 irr = F.ambient.rgb;
    if ((F.counts.w & 8u) != 0u) {
        vec4 f = texture(uTex6, px * F.gs.z / F.sf.zw);
        float below = max(f.z - zr, 0.0);
        if (below > 0.0 && f.x > 0.0) {
            float reach = below * 3.0 + 6.0;
            float occ = 1.0 - w_smoothstep(0.0, reach, f.x);
            irr = irr * (1.0 - F.bg.z * occ * occ);
        }
    }

    vec3 diffuse = vec3(0.0);
    vec3 spec = vec3(0.0);
    vec3 airc = vec3(0.0);
    uint nl = min(F.counts.y, 8u);
    vec4 v0 = vis_at(px, zr, 0u);
    vec4 v1 = vec4(1.0);
    if (nl > 4u) {
        v1 = vis_at(px, zr, 1u);
    }
    bool shafts = (F.counts.w & 2u) != 0u;
    vec4 a0 = vec4(1.0);
    vec4 a1 = vec4(1.0);
    if (shafts) {
        a0 = vis_at(px, zr, (nl+3u)/4u);
        if (nl > 4u) {
            a1 = vis_at(px, zr, (nl+3u)/4u + 1u);
        }
    }
    for (uint li = 0u; li < nl; li += 1u) {
        Light L = F.lights[li];
        vec4 lt = light_term(L, P);
        vec3 l = lt.xyz;
        float v = (li >= 4u) ? v1[li % 4u] : v0[li % 4u];
        float ndl = max(dot(n, l), 0.0);
        vec3 e = L.color.rgb * lt.w * v;
        float front = choose(1.0, 0.0, L.extra.x > 0.0);
        diffuse = diffuse + e * ndl * front;

        vec3 h = normalize(l + vec3(0.0, 0.0, 1.0));
        float dist = length(L.pos.xyz - P);
        float a = clamp(rough * rough + L.pos.w / (2.0 * max(dist, 1e-4)), 0.02, 1.0);
        float energy = (rough * rough) / a;
        float fres = 0.04 + 0.96 * pow(clamp(1.0 - max(dot(l, h), 0.0), 0.0, 1.0), 5.0);
        spec = spec + e * ndl * ggx(max(dot(n, h), 0.0), a) * energy * fres * gloss * L.extra.z * front;

        vec2 lxy = L.pos.xy - px;
        float face = max(dot(grad, lxy / max(length(lxy), 1e-3)), 0.0);
        spec = spec + e * rim * face * face * max(l.z, 0.15);
        float d2 = length(lxy);
        if (shafts && L.extra.x > 0.0) {
            float av = (li >= 4u) ? a1[li % 4u] : a0[li % 4u];
            float over = choose(1.0, F.misc.w, zr > 0.5);
            float fall = 1.5 * RL_REF / (d2 + 1.5 * RL_REF);
            airc = airc + L.color.rgb * L.extra.x * av * over * fall * fall;
        }
        if (L.extra.y > 0.0) {
            float r = max(L.pos.w, 1.0);
            float q = r * r / (d2 * d2 + r * r);
            airc = airc + L.color.rgb * L.extra.y * (q * sqrt(q) + 0.05 * q);
        }
    }

    vec3 gi_irr = vec3(0.0);
    if ((F.counts.w & 1u) != 0u) {
        vec3 flv = texture(uTex5, px * F.gs.w / F.gs.xy).rgb;
        gi_irr = flv * F.gi.x;
        airc = airc + flv * F.gi.y;
    }

    vec3 lightf = irr + diffuse + gi_irr;
    vec3 col = base.rgb * irr + (base.rgb + vec3(F.ext.x)) * (diffuse + gi_irr) + spec;
    if (emissive) {
        col = base.rgb * max(lightf, vec3(1.0)) + spec * 0.25;
    }

    vec3 tf = mix(vec3(1.0), clamp(lightf, vec3(F.text.x), vec3(F.text.y)), F.text.z);
    col = col * (1.0 - text.a) + text.rgb * tf + spec * text.a * F.text.w;
    col = col + airc * (1.0 - 0.6 * text.a);

    vec3 o = shoulder(col * F.ambient.w);
    if ((F.counts.w & 4u) != 0u) {
        o = to_srgb(o);
        float dn = ign(px + vec2(F.misc.z * 5.588238, 0.0)) + ign(px.yx + vec2(17.0, F.misc.z)) - 1.0;
        o = o + vec3(dn / 255.0);
    }
    result = vec4(o, 1.0);
}
