vec4 src_at(Inst i, vec2 l, sampler2D source) {
    vec2 uv = (l - i.aux2.xy) / i.aux2.zw;
    return sampleTopLeft(source, uv, 0.0);
}

vec3 pose_at(uint base, uint k, vec2 p) {
    vec4 m = tableEntry(base + k * 2u);
    vec4 tw = tableEntry(base + k * 2u + 1u);
    return vec3(m.x * p.x + m.z * p.y + tw.x, m.y * p.x + m.w * p.y + tw.y, tw.z);
}

void main() {
    Globals g = fxGlobals;
    BackdropEncoding enc = fxBackdrop;
    vec2 pixel = recover_pixel(g);
    Inst i = fxInstance;
    vec2 p = pixel / i.shape.y;
    uint first = uint(i.xf.x);
    uint n = uint(i.xf.y);
    vec4 acc = vec4(0.0);

    if (i.xf.z < 0.5) {
        for (uint k = 0u; k < n; k++) {
            vec3 l = pose_at(first, k, p);
            acc += src_at(i, l.xy, uTex1) * l.z;
        }
    } else {
        float j = 0.5;
        vec2 b = i.aux.xy;
        float wsum = 0.0;
        for (uint k = 0u; k < n; k++) {
            float o = (float(k) + j) / float(n) - 0.5;
            float w = 1.0 - 4.0 * o * o * 0.85;
            vec3 l = pose_at(first, 0u, p - b * o);
            acc += src_at(i, l.xy, uTex1) * (w * l.z);
            wsum += w;
        }
        acc /= max(wsum, 1e-4);
    }

    fragColor = fx_fs(finish(acc, pixel, g), i, pixel, g, uTex0, enc);
}
