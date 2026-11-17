// QueuedOutlineFill.instance covers its integer atlas placement and transparent
// gutter. The cropped ink rectangle is integral and has no opacity or fade.
flat in vec4 vRect;
flat in vec4 vRadii;
flat in vec4 vBorder;
flat in vec4 vClip;
out float mask;

// One call site per curve algorithm, including grouped native glyphs. Keeping
// the tile and individual cases in one loop avoids inlining both band walks
// twice in the R8 fragment program.
float mask_coverage(vec2 pixel) {
    uint record = uint(vBorder.x);
    uint mode = uint(vBorder.w + 0.5);
    bool tile = mode == 4u;
    uint count = tile ? min(outline_texel(record).x, 64u) : 1u;
    vec2 p = pixel - vRadii.xy;
    uint destination = 0u;
    for (uint i = 0u; i < count; ++i) {
        uint shape = record, hint = uint(vBorder.y);
        float scale = vRadii.z, radius = vBorder.z;
        bool slug = mode == 1u;
        vec2 local = vec2(p.x / (mode == 3u ? 3.0 : 1.0), -p.y);
        if (tile) {
            uint offset = record + 1u + 3u * i;
            vec4 rect = vec4(outline_texel(offset));
            if (any(lessThan(p, rect.xy)) || any(greaterThanEqual(p, rect.xy + rect.zw))) continue;
            vec4 transform = uintBitsToFloat(outline_texel(offset + 1u));
            uvec4 glyph = outline_texel(offset + 2u);
            shape = glyph.x;
            hint = glyph.y;
            slug = glyph.z == 1u;
            local = vec2(p.x - transform.x, transform.y - p.y);
            scale = transform.z;
            radius = transform.w;
        }
#ifdef RUNE_UNIT_WINFOIL
        float coverage = outline_coverage(shape, 0u, local, 1.0, 0.0, 0.5, 0.5);
#else
        float coverage = slug ? outline_slug(shape, hint, local, scale, radius, 0.5)
                              : outline_coverage(shape, hint, local, scale, radius, 0.5, 0.5);
#endif
        if (!tile) return coverage;
        uint source = uint(roundEven(clamp(coverage, 0.0, 1.0) * 255.0));
        destination = source + (destination * (255u - source) + 127u) / 255u;
        if (destination == 255u) break;
    }
    return float(destination) / 255.0;
}

void main() {
    vec2 pixel = gl_FragCoord.xy;
    if (any(lessThan(pixel, vRect.xy)) || any(greaterThanEqual(pixel, vRect.xy + vRect.zw))) discard;
    mask = 0.0;
    if (all(greaterThanEqual(pixel, vClip.xy)) && all(lessThan(pixel, vClip.zw))) {
        float coverage = mask_coverage(pixel);
        mask = roundEven(clamp(coverage, 0.0, 1.0) * 255.0) / 255.0;
    }
}
