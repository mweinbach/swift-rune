// Half-resolution signed distance to the nearest occluder, its Z slab, and GI emitter distance.
void main() {
    vec2 p = gl_FragCoord.xy / F.gs.z;
    vec4 nearest = vec4(256.0, 0.0, 0.0, 256.0);
    for (int i = 0; i < int(F.counts.x); ++i) {
        Prim pr = primAt(i);
        uint flags = flags_of(pr);
        float d = prim_sd(pr, p);
        if ((flags & (F_EMIT | F_HINT)) != 0u) nearest.w = min(nearest.w, d);
        if ((flags & F_OCC) != 0u && d < nearest.x) nearest.xyz = vec3(d, pr.z.xy);
    }
    result = nearest;
}
