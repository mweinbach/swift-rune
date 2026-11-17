void main() {
    uvec2 gid = uvec2(gl_FragCoord.xy);
    float texel = 1.0 / F.gs.w;
    vec2 p = (vec2(gid) + 0.5) * texel;
    vec4 em = vec4(0.0);
    vec4 oc = vec4(0.0);
    uint n = F.counts.x;
    for (uint i = 0u; i < n; i += 1u) {
        Prim pr = primAt(int(i));
        uint fl = flags_of(pr);
        if ((fl & (F_EMIT | F_OCC)) == 0u) {
            continue;
        }
        vec2 halfSize = pr.rect.zw * 0.5;
        vec2 c = pr.rect.xy + halfSize;
        if (any(greaterThan(abs(p - c), halfSize + vec2(texel)))) {
            continue;
        }
        float cov = clamp(0.5 - sd_rrect(p - c, halfSize, pr.radii) / texel, 0.0, 1.0);
        if (cov <= 0.0) {
            continue;
        }
        if ((fl & F_EMIT) != 0u) {
            em = mix(em, vec4(pr.emit.rgb * 1.5, 1.5), cov);
            oc = oc * (1.0 - cov);
        } else {
            vec3 e = vec3(0.0);
            if (F.gi.z > 0.0) {
                vec3 P = vec3(p, pr.z.y);
                ivec2 fp = clamp(ivec2(p * F.gs.z), ivec2(0), ivec2(F.sf.zw) - ivec2(1));
                uint nl = min(F.counts.y, 8u);
                for (uint li = 0u; li < nl; li += 1u) {
                    Light L = F.lights[li];
                    vec4 lt = light_term(L, P);
                    float v = texelFetch(uTex1, fp + ivec2(0, int(li / 4u) * int(F.sf.w)), 0)[li % 4u];
                    e = e + L.color.rgb * lt.w * max(lt.z, 0.0) * v;
                }
            }
            em = em * (1.0 - cov);
            oc = mix(oc, vec4(pr.albedo.rgb * e * F.gi.z, 1.0), cov);
        }
    }
    if ((F.counts.w & 16u) != 0u) {
        vec2 sz = F.sf.xy;
        vec3 acc = vec3(0.0);
        for (int k = 0; k < 16; k += 1) {
            vec2 o = (vec2(float(k & 3), float(k >> 2)) - 1.5) * 0.25 * texel;
            acc = acc + texture(uTex2, vec2((p.x + o.x) / sz.x, 1.0 - (p.y + o.y) / sz.y)).rgb;
        }
        em = vec4(em.rgb + acc / 16.0 * F.ext.y, em.a);
    }
    result = F.stage.y == 0u ? em : oc;
}
