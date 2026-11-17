// Glyph outlines from Rune's outline.wgsl. Windfoil integrates the winding of monotone
// quadratic segments over each pixel. Slug samples two rays through the same band record.
// The 1024-texel-wide RGBA32UI store uses exact integer offsets and bit-cast float geometry.
#define RUNE_OUTLINES 1
#ifdef GL_ES
precision highp usampler2D;
#endif
uniform usampler2D uOutlines;
const float OUTLINE_HINT_REACH = 1.5;

uvec4 outline_texel(uint i) {
    return texelFetch(uOutlines, ivec2(int(i & 1023u), int(i >> 10u)), 0);
}

vec2 outline_move(uint code) {
    return vec2(float(code & 3u) - 1.0, float((code >> 2u) & 3u));
}

float outline_hint(float y, vec4 a, vec4 b, vec4 c) {
    if (y < a.y) { return y; }
    if (y <= a.z) { return (y - a.y) * c.x + a.y; }
    if (y <= b.x) { return (y - a.z) * c.y + a.w; }
    if (y <= b.z) { return y + (b.y - b.x); }
    return (y - b.z) * c.z + b.w;
}

float outline_inside(vec2 a2, vec2 a1, float x0, float ta, float tb, float hx) {
    if (tb <= ta) { return 0.0; }
    float tm = 0.5 * (ta + tb);
    float d = 0.5 * (tb - ta);
    float x_mid = (a2.x * tm + a1.x) * tm + x0 + hx;
    vec2 dmid = 2.0 * a2 * tm + a1;
    return 2.0 * d * x_mid * dmid.y + (2.0 * d * d * d / 3.0) * (a2.x * dmid.y + 2.0 * a2.y * dmid.x);
}

float outline_integrate(vec2 q1, vec2 q2, vec2 q3, float lo, float hi, float hx) {
    vec2 a2 = q1 - 2.0 * q2 + q3;
    vec2 a1 = 2.0 * (q2 - q1);
    bool y_rising = q3.y >= q1.y;
    bool x_rising = q3.x >= q1.x;
    vec4 A2 = a2.yyxx;
    vec4 A1 = a1.yyxx;
    vec4 V = vec4((y_rising ? vec2(lo, hi) : vec2(hi, lo)), -hx, hx);
    bvec4 R = bvec4(y_rising, y_rising, x_rising, x_rising);
    vec4 SG = mix(vec4(-1.0), vec4(1.0), R);
    vec4 C = q1.yyxx - V;
    bvec4 sat0 = greaterThanEqual(C * SG, vec4(0.0));
    bvec4 sat1 = lessThanEqual((q3.yyxx - V) * SG, vec4(0.0));
    vec4 disc = max(A1 * A1 - 4.0 * A2 * C, vec4(0.0));
    vec4 sq = sqrt(disc);
    vec4 qq = -0.5 * (A1 + mix(-sq, sq, greaterThanEqual(A1, vec4(0.0))));
    bvec4 use_r1 = equal(lessThan(A1, vec4(0.0)), R);
    vec4 num = mix(C, qq, use_r1);
    vec4 den = mix(qq, A2, use_r1);
    bvec4 valid = notEqual(den, vec4(0.0));
    vec4 t_raw = clamp(mix(vec4(0.0), num / mix(vec4(1.0), den, valid), valid), vec4(0.0), vec4(1.0));
    vec4 T = mix(mix(t_raw, vec4(1.0), sat1), vec4(0.0), sat0);
    if (T.y <= T.x) { return 0.0; }
    vec2 tc = clamp(T.zw, T.xx, T.yy);
    float t1 = (x_rising ? tc.x : tc.y);
    float t2 = max((x_rising ? tc.y : tc.x), t1);
    float acc = outline_inside(a2, a1, q1.x, t1, t2, hx);
    vec2 rab = (x_rising ? vec2(t2, T.y) : vec2(T.x, t1));
    float d = max(rab.y - rab.x, 0.0);
    float tm = 0.5 * (rab.x + rab.y);
    acc = acc + d * (2.0 * a2.y * tm + a1.y) * (2.0 * hx);
    return acc;
}

float outline_coverage(uint rec, uint hint, vec2 local, float scale, float r, float hw, float hx) {
    uvec4 head = outline_texel(rec);
    uint count = head.y;
    float y0 = uintBitsToFloat(head.z);
    float inv_h = uintBitsToFloat(head.w);
    bool hinted = hint != 0u;
    vec4 ha = vec4(0.0), hb = vec4(0.0), hc = vec4(0.0);
    if (hinted) {
        ha = uintBitsToFloat(outline_texel(hint));
        hb = uintBitsToFloat(outline_texel(hint + 1u));
        hc = uintBitsToFloat(outline_texel(hint + 2u));
    }
    float reach = (hinted ? OUTLINE_HINT_REACH : 0.0);
    uint b0 = 0u, b1 = 0u;
    if (count > 1u) {
        float last = float(count - 1u);
        b0 = uint(clamp(floor(((local.y - hw - 2.0 * r - reach) / scale - y0) * inv_h), 0.0, last));
        b1 = uint(clamp(floor(((local.y + hw + reach) / scale - y0) * inv_h), 0.0, last));
    }
    float acc = 0.0;
    for (uint band = b0; band <= b1; band = band + 1u) {
        float e0 = -3.0e38;
        float e1 = 3.0e38;
        if (count > 1u) {
            e0 = (y0 + float(band) / inv_h) * scale;
            e1 = (y0 + float(band + 1u) / inv_h) * scale;
        }
        uvec4 entry = outline_texel(head.x + band);
        bool sorted = entry.y > 4u;
        for (uint k = 0u; k < entry.y; k = k + 1u) {
            uvec4 t0 = outline_texel(entry.x + 2u * k);
            uvec4 t1 = outline_texel(entry.x + 2u * k + 1u);
            if (uintBitsToFloat(t1.w) * scale + r - local.x <= -hx) {
                if (sorted) { break; }
                continue;
            }
            uint code = t1.z;
            vec2 oa = outline_move(code & 15u) * r;
            vec2 ob = outline_move((code >> 4u) & 15u) * r;
            vec2 p0 = uintBitsToFloat(t0.xy) * scale + oa;
            vec2 p1 = uintBitsToFloat(t0.zw) * scale + oa;
            vec2 p2 = uintBitsToFloat(t1.xy) * scale + ob;
            float wlo = -hw;
            float whi = hw;
            float be0 = e0 + oa.y;
            float be1 = e1 + oa.y;
            if (hinted) {
                p0.y = outline_hint(p0.y, ha, hb, hc);
                p1.y = outline_hint(p1.y, ha, hb, hc);
                p2.y = outline_hint(p2.y, ha, hb, hc);
                be0 = outline_hint(be0, ha, hb, hc);
                be1 = outline_hint(be1, ha, hb, hc);
            }
            if ((code & 256u) != 0u) {
                p1 = (p0 + p2) * 0.5;
            } else {
                wlo = max(wlo, be0 - local.y);
                whi = min(whi, be1 - local.y);
            }
            vec2 q1 = p0 - local;
            vec2 q3 = p2 - local;
            float lo = max(wlo, min(q1.y, q3.y));
            float hi = min(whi, max(q1.y, q3.y));
            if (hi <= lo || max(q1.x, q3.x) <= -hx) { continue; }
            if (min(q1.x, q3.x) >= hx) {
                acc = acc + 2.0 * hx * (clamp(q3.y, wlo, whi) - clamp(q1.y, wlo, whi));
                continue;
            }
            acc = acc + outline_integrate(q1, p1 - local, q3, lo, hi, hx);
        }
    }
    return min(abs(acc) / (4.0 * hx * hw), 1.0);
}

float outline_root(float p0, float p1, float p2, float c) {
    float a2 = p0 - 2.0 * p1 + p2;
    float a1 = 2.0 * (p1 - p0);
    float a0 = p0 - c;
    if (abs(a2) < 1.0e-6) {
        return clamp(-a0 / (abs(a1) < 1.0e-6 ? 1.0e-6 : a1), 0.0, 1.0);
    }
    float sq = sqrt(max(a1 * a1 - 4.0 * a2 * a0, 0.0));
    float t0 = (-a1 - sq) / (2.0 * a2);
    float t1 = (-a1 + sq) / (2.0 * a2);
    return clamp((t0 >= -1.0e-4 && t0 <= 1.0 + 1.0e-4 ? t0 : t1), 0.0, 1.0);
}

float outline_slug(uint rec, uint hint, vec2 local, float scale, float r, float hw) {
    uvec4 head = outline_texel(rec);
    uint count = head.y;
    float y0 = uintBitsToFloat(head.z);
    float inv_h = uintBitsToFloat(head.w);
    bool hinted = hint != 0u;
    vec4 ha = vec4(0.0), hb = vec4(0.0), hc = vec4(0.0);
    if (hinted) {
        ha = uintBitsToFloat(outline_texel(hint));
        hb = uintBitsToFloat(outline_texel(hint + 1u));
        hc = uintBitsToFloat(outline_texel(hint + 2u));
    }
    float reach = (hinted ? OUTLINE_HINT_REACH : 0.0);
    uint b0 = 0u, b1 = 0u;
    if (count > 1u) {
        float last = float(count - 1u);
        b0 = uint(clamp(floor(((local.y - hw - 2.0 * r - reach) / scale - y0) * inv_h), 0.0, last));
        b1 = uint(clamp(floor(((local.y + hw + reach) / scale - y0) * inv_h), 0.0, last));
    }
    float across = 0.0, winding = 0.0, down = 0.0;
    for (uint band = b0; band <= b1; band = band + 1u) {
        float e0 = -3.0e38, e1 = 3.0e38;
        if (count > 1u) {
            e0 = (y0 + float(band) / inv_h) * scale;
            e1 = (y0 + float(band + 1u) / inv_h) * scale;
        }
        uvec4 entry = outline_texel(head.x + band);
        for (uint k = 0u; k < entry.y; k = k + 1u) {
            uvec4 t0 = outline_texel(entry.x + 2u * k);
            uvec4 t1 = outline_texel(entry.x + 2u * k + 1u);
            uint code = t1.z;
            vec2 oa = outline_move(code & 15u) * r;
            vec2 ob = outline_move((code >> 4u) & 15u) * r;
            vec2 p0 = uintBitsToFloat(t0.xy) * scale + oa;
            vec2 p1 = uintBitsToFloat(t0.zw) * scale + oa;
            vec2 p2 = uintBitsToFloat(t1.xy) * scale + ob;
            float be0 = e0 + oa.y, be1 = e1 + oa.y;
            if (hinted) {
                p0.y = outline_hint(p0.y, ha, hb, hc);
                p1.y = outline_hint(p1.y, ha, hb, hc);
                p2.y = outline_hint(p2.y, ha, hb, hc);
                be0 = outline_hint(be0, ha, hb, hc);
                be1 = outline_hint(be1, ha, hb, hc);
            }
            if ((code & 256u) != 0u) {
                p1 = (p0 + p2) * 0.5;
                be0 = -3.0e38;
                be1 = 3.0e38;
            }
            vec2 q0 = p0 - local, q1 = p1 - local, q2 = p2 - local;
            float ylo = max(min(q0.y, q2.y), be0 - local.y);
            float yhi = min(max(q0.y, q2.y), be1 - local.y);
            if (q0.y != q2.y && ylo <= 0.0 && 0.0 < yhi) {
                float t = outline_root(q0.y, q1.y, q2.y, 0.0);
                float x = mix(mix(q0.x, q1.x, t), mix(q1.x, q2.x, t), t);
                float s = sign(q2.y - q0.y);
                across = across + s * clamp(x / (2.0 * hw) + 0.5, 0.0, 1.0);
                winding = winding + s * (x > 0.0 ? 1.0 : 0.0);
            }
            if (q0.x != q2.x && min(q0.x, q2.x) <= 0.0 && 0.0 < max(q0.x, q2.x)) {
                float t = outline_root(q0.x, q1.x, q2.x, 0.0);
                float y = mix(mix(q0.y, q1.y, t), mix(q1.y, q2.y, t), t);
                if (abs(y) < hw && y >= be0 - local.y && y < be1 - local.y) {
                    down = down - sign(q2.x - q0.x) * (clamp(y / (2.0 * hw) + 0.5, 0.0, 1.0) - (y > 0.0 ? 1.0 : 0.0));
                }
            }
        }
    }
    return 0.5 * (min(abs(across), 1.0) + min(abs(winding + down), 1.0));
}

#ifdef RUNE_OUTLINE_LCD
float outline_rgb(uint rec, uint hint, vec2 local, float scale, float r, float hw, inout vec4 lcd_cov) {
    vec2 third = vec2(2.0 * hw / 3.0, 0.0);
    vec3 c = vec3(
        outline_coverage(rec, hint, local - third, scale, r, hw, hw),
        outline_coverage(rec, hint, local, scale, r, hw, hw),
        outline_coverage(rec, hint, local + third, scale, r, hw, hw)
    );
    lcd_cov = vec4(c, 1.0);
    return (c.x + c.y + c.z) / 3.0;
}

#endif

// Resting native tiles can contain several glyphs. Composite their already rounded
// coverage bytes in shaping order, including overlapping accents and italic ink.
float outline_tile(uint record, vec2 pixel) {
    uint count = min(outline_texel(record).x, 64u);
    uint destination = 0u;
    for (uint i = 0u; i < count; ++i) {
        uint offset = record + 1u + 3u * i;
        vec4 rect = vec4(outline_texel(offset));
        if (any(lessThan(pixel, rect.xy)) || any(greaterThanEqual(pixel, rect.xy + rect.zw))) continue;
        vec4 transform = uintBitsToFloat(outline_texel(offset + 1u));
        uvec4 glyph = outline_texel(offset + 2u);
        vec2 local = vec2(pixel.x - transform.x, transform.y - pixel.y);
        float coverage = glyph.z == 1u
            ? outline_slug(glyph.x, glyph.y, local, transform.z, transform.w, 0.5)
            : outline_coverage(glyph.x, glyph.y, local, transform.z, transform.w, 0.5, 0.5);
        uint source = uint(roundEven(clamp(coverage, 0.0, 1.0) * 255.0));
        destination = source + (destination * (255u - source) + 127u) / 255u;
        if (destination == 255u) break;
    }
    return float(destination) / 255.0;
}

float outline_glyph(vec4 radii, vec4 border, vec2 screen, inout vec4 lcd_cov) {
    float z = radii.w;
    uint rec = uint(border.x);
    uint hint = uint(border.y);
    float hw = 0.5 / z;
    uint mode = uint(border.w + 0.5);
    if (mode == 4u) { return outline_tile(rec, screen - radii.xy); }
    float across = (mode == 3u ? 3.0 : 1.0);
    vec2 local = vec2((screen.x - radii.x) / across, radii.y - screen.y) / z;
    if (mode == 1u) { return outline_slug(rec, hint, local, radii.z, border.z, hw); }
#ifdef RUNE_OUTLINE_LCD
    if (mode == 2u) { return outline_rgb(rec, hint, local, radii.z, border.z, hw, lcd_cov); }
#endif
    return outline_coverage(rec, hint, local, radii.z, border.z, hw, hw);
}
