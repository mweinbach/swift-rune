// Production 128-byte paint stream. Fragment equations match RenderShaders.shaderMSL.
#ifdef GL_ES
precision highp sampler2D;
#endif
uniform vec2 uViewport;
uniform vec2 uOrigin;
#ifdef RUNE_OUTLINES
uniform int uAtlasFill;
#endif
uniform int uSRGBBlend;
uniform int uInLayer;
uniform sampler2D uGlyphAtlas;
uniform sampler2D uImageAtlas;
in vec2 vPoint;
flat in vec4 vRect;
flat in vec4 vRadii;
flat in vec4 vFill;
flat in vec4 vBorder;
flat in vec4 vParams;
flat in vec4 vUV;
flat in vec4 vClip;
flat in uvec4 vFade;
#ifdef RUNE_OUTLINE_LCD
layout(location = 0, index = 0) out vec4 outColor;
layout(location = 0, index = 1) out vec4 outBlend;
#else
out vec4 outColor;
#endif

const float CONTINUOUS_K = 1.52866483;

float sd_continuous(vec2 p, vec2 halfSize, float r) {
    float e = CONTINUOUS_K * r;
    vec2 q = halfSize - abs(p);
    vec2 v = vec2(e) - q;
    if (v.x <= 0.0 || v.y <= 0.0) { return max(-q.x, -q.y); }
    float u = atan(v.y, v.x) * (4.0 / 3.14159265) - 1.0;
    float u2 = u * u;
    return length(v) - e * (1.14602295 + u2 * (-0.37573161 + u2 * (0.30796609 - 0.07724354 * u2)));
}

float sd_rounded(vec2 p, vec2 halfSize, vec4 radii) {
    float r = radii.x;
    if (p.x > 0.0) {
        r = (p.y > 0.0 ? radii.z : radii.y);
    } else {
        r = (p.y > 0.0 ? radii.w : radii.x);
    }
    if (r < 0.0) {
        return sd_continuous(p, halfSize, min(-r, min(halfSize.x, halfSize.y)));
    }
    r = min(r, min(halfSize.x, halfSize.y));
    vec2 q = abs(p) - halfSize + vec2(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

float clip_ramp(float d, float fade) {
    if (fade == 0.0) {
        return clamp(d + 0.5, 0.0, 1.0);
    }
    float x = clamp(d / abs(fade), 0.0, 1.0);
    if (fade < 0.0) {
        return x;
    }
    return x * x * (3.0 - 2.0 * x);
}

vec4 unpack_clip_radii(uint w) {
    if (w == 0u) { return vec4(0.0); }
    if ((w & 0x60000000u) != 0x60000000u) {
        return vec4(uintBitsToFloat(w));
    }
    float step = ((w & 0x10000000u) != 0u ? 2.0 : 0.5);
    float sgn = ((w & 0x80000000u) != 0u ? -1.0 : 1.0);
    return vec4(
        float(w & 0x7fu),
        float((w >> 7u) & 0x7fu),
        float((w >> 14u) & 0x7fu),
        float((w >> 21u) & 0x7fu)
    ) * (step * sgn);
}


// Half widths are encoded exactly by RenderInstance.packFade. This also works
// on desktop GLSL 3.30, where unpackHalf2x16 is not a core instruction.
float fadeWidth(uint h) {
    uint e = (h >> 10u) & 31u;
    float m = float(h & 1023u);
    float value = e == 0u ? m * (1.0 / 16777216.0) : exp2(float(e) - 15.0) * (1.0 + m / 1024.0);
    return (h & 32768u) == 0u ? value : -value;
}

float clip_alpha(vec2 p, vec4 bounds, uvec4 packedFade) {
    vec4 widths = vec4(fadeWidth(packedFade.x), fadeWidth(packedFade.x >> 16u),
                       fadeWidth(packedFade.y), fadeWidth(packedFade.y >> 16u));
    vec4 distances = vec4(p - bounds.xy, bounds.zw - p);
    float alpha = 1.0;
    for (int edge = 0; edge < 4; ++edge) {
        float offset = float((packedFade.z >> uint(8 * edge)) & 255u) / 255.0;
        float value = clip_ramp(distances[edge], widths[edge]);
        if (offset >= 1.0) {
            value = clip_ramp(distances[edge], 0.0);
        } else if (offset > 0.0) {
            value = min(clip_ramp(distances[edge], 0.0),
                        clip_ramp(distances[edge] + offset * abs(widths[edge]), widths[edge]));
        }
        alpha *= value;
    }
    if (packedFade.w != 0u) {
        vec2 halfSize = (bounds.zw - bounds.xy) * 0.5;
        alpha *= clamp(0.5 - sd_rounded(p - bounds.xy - halfSize, halfSize,
                                       unpack_clip_radii(packedFade.w)), 0.0, 1.0);
    }
    return alpha;
}

float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * 3.14159265) * sigma);
}

vec2 erf2(vec2 x) {
    vec2 s = sign(x);
    vec2 a = abs(x);
    vec2 r = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    r = r * r;
    return s - s / (r * r);
}

float shadow_x(float x, float y, float sigma, float corner, vec2 halfSize) {
    float delta = min(halfSize.y - corner - abs(y), 0.0);
    float curved = halfSize.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
    vec2 integral = 0.5 + 0.5 * erf2((x + vec2(-curved, curved)) * (sqrt(0.5) / sigma));
    return integral.y - integral.x;
}

const float SHADOW_INSIDE = 0.99863125;

float shadow_fn(vec2 p, vec2 halfSize, float sigma, float corner) {
    if (abs(p.x) <= halfSize.x - 6.0 * sigma && abs(p.y) <= halfSize.y - corner - 6.0 * sigma) {
        return SHADOW_INSIDE;
    }
    float lo = p.y - halfSize.y;
    float hi = p.y + halfSize.y;
    float start = clamp(-3.0 * sigma, lo, hi);
    float end = clamp(3.0 * sigma, lo, hi);
    float step = (end - start) / 4.0;
    float y = start + step * 0.5;
    float v = 0.0;
    for (int k = 0; k < 4; k = k + 1) {
        v = v + shadow_x(p.x, p.y - y, sigma, corner, halfSize) * gaussian(y, sigma) * step;
        y = y + step;
    }
    return v;
}

float segment_fn(vec2 p, vec2 a, vec2 b, float hw, bool roundCap) {
    vec2 ba = b - a;
    float len = length(ba);
    if (len < 1e-4) {
        if (!roundCap) { return 0.0; }
        float eff_hw = max(hw, 0.5);
        return min(2.0 * hw, 1.0) * clamp(0.5 - (length(p - a) - eff_hw), 0.0, 1.0);
    }
    vec2 u = ba / len;
    vec2 q = p - a;
    float along = dot(q, u);
    float perp = abs(q.x * u.y - q.y * u.x);
    float eff_hw = max(hw, 0.5);
    float weight = min(2.0 * hw, 1.0);
    if (roundCap) {
        float clamped = clamp(along, 0.0, len);
        return weight * clamp(0.5 - (length(q - u * clamped) - eff_hw), 0.0, 1.0);
    } else {
        vec2 edge = vec2(abs(along - len * 0.5) - len * 0.5, perp - eff_hw);
        float d = min(max(edge.x, edge.y), 0.0) + length(max(edge, vec2(0.0)));
        return weight * clamp(0.5 - d, 0.0, 1.0);
    }
}

float edge_fn(vec2 p, vec2 a, vec2 b, vec2 c) {
    vec2 e = b - a;
    float l = max(length(e), 1e-6);
    vec2 n = vec2(-e.y, e.x) / l;
    float s = (dot(c - a, n) >= 0.0 ? 1.0 : -1.0);
    return dot(p - a, n) * s;
}

bool owns_fn(vec2 p, vec2 a, vec2 b, vec2 c) {
    bool swapped = a.x > b.x || (a.x == b.x && a.y > b.y);
    vec2 lo = (swapped ? b : a);
    vec2 hi = (swapped ? a : b);
    vec2 e = hi - lo;
    float side = e.x * (c.y - lo.y) - e.y * (c.x - lo.x);
    float v = e.x * (p.y - lo.y) - e.y * (p.x - lo.x);
    if (side > 0.0) {
        return v >= 0.0;
    }
    return v < 0.0;
}

float soft_fn(vec2 p, vec2 a, vec2 b, vec2 c) {
    float d = edge_fn(p, a, b, c);
    vec2 e = b - a;
    float t = dot(p - a, e) / max(dot(e, e), 1e-6);
    if (t < 0.0 || t > 1.0) {
        return (d >= 0.0 ? 1.0 : 0.0);
    }
    return clamp(d + 0.5, 0.0, 1.0);
}

float triangle_fn(vec2 p, vec2 a, vec2 b, vec2 c, uint aa) {
    float cov = 1.0;
    if ((aa & 1u) == 1u) {
        cov = cov * soft_fn(p, a, b, c);
    } else if (!owns_fn(p, a, b, c)) {
        return 0.0;
    }
    if ((aa & 2u) == 2u) {
        cov = cov * soft_fn(p, b, c, a);
    } else if (!owns_fn(p, b, c, a)) {
        return 0.0;
    }
    if ((aa & 4u) == 4u) {
        cov = cov * soft_fn(p, c, a, b);
    } else if (!owns_fn(p, c, a, b)) {
        return 0.0;
    }
    return cov;
}

vec4 srgb_encode(vec4 c) {
    if (c.a <= 0.0) { return vec4(0.0); }
    vec3 u = clamp(c.rgb / c.a, vec3(0.0), vec3(1.0));
    vec3 enc = mix(pow(u, vec3(1.0 / 2.4)) * 1.055 - 0.055, u * 12.92, lessThanEqual(u, vec3(0.0031308)));
    return vec4(enc * c.a, c.a);
}

vec4 image_texel(ivec2 t, bool premultiplied) {
    vec4 c = texelFetch(uImageAtlas, t, 0);
    if (uSRGBBlend != 0) {
        if (c.a <= 0.0) { return vec4(0.0); }
        vec3 lin = (premultiplied ? c.rgb / c.a : c.rgb);
        return vec4(srgb_encode(vec4(lin, 1.0)).rgb * c.a, c.a);
    }
    if (premultiplied) { return c; }
    return vec4(c.rgb * c.a, c.a);
}

vec2 ring_arc(vec2 p, vec2 size, vec4 radii, float bw) {
    float h = bw * 0.5;
    vec2 halfSize = size * 0.5;
    vec4 rc = max(min(abs(radii), vec4(min(halfSize.x, halfSize.y))) - vec4(h), vec4(0.0));
    vec4 e = rc + vec4(h);
    vec4 arc = rc * 1.5707964;
    float s_tr = max(size.x - bw - rc.x - rc.y, 0.0);
    float s_right = s_tr + arc.y;
    float s_br = s_right + max(size.y - bw - rc.y - rc.z, 0.0);
    float s_bottom = s_br + arc.z;
    float s_bl = s_bottom + max(size.x - bw - rc.z - rc.w, 0.0);
    float s_left = s_bl + arc.w;
    float s_tl = s_left + max(size.y - bw - rc.w - rc.x, 0.0);
    float top = p.x - e.x;
    float right = s_right + p.y - e.y;
    float bottom = s_bottom + size.x - e.z - p.x;
    float left = s_left + size.y - e.w - p.y;
    float s;
    if (p.x > halfSize.x) {
        if (p.y > halfSize.y) {
            vec2 v = p - (size - vec2(e.z));
            if (v.x > 0.0 && v.y > 0.0) { s = s_br + atan(v.y, v.x) * rc.z; }
            else { s = (size.x - p.x < size.y - p.y ? right : bottom); }
        } else {
            vec2 v = p - vec2(size.x - e.y, e.y);
            if (v.x > 0.0 && v.y < 0.0) { s = s_tr + atan(v.x, -v.y) * rc.y; }
            else { s = (size.x - p.x < p.y ? right : top); }
        }
    } else if (p.y > halfSize.y) {
        vec2 v = p - vec2(e.w, size.y - e.w);
        if (v.x < 0.0 && v.y > 0.0) { s = s_bl + atan(-v.x, v.y) * rc.w; }
        else { s = (p.x < size.y - p.y ? left : bottom); }
    } else {
        vec2 v = p - vec2(e.x);
        if (v.x < 0.0 && v.y < 0.0) { s = s_tl + atan(-v.y, -v.x) * rc.x; }
        else { s = (p.x < p.y ? left : top); }
    }
    return vec2(s, s_tl + arc.x);
}

float dash_cov(float s, float total, vec3 d) {
    float nominal = d.x + d.y;
    float k = max(total, 0.001) / (max(floor(total / nominal + 0.5), 1.0) * nominal);
    float period = nominal * k;
    float dash = d.x * k;
    float a = s + d.z * k - dash * 0.5;
    float m = a - period * floor(a / period + 0.5);
    return clamp(dash * 0.5 - abs(m) + 0.5, 0.0, 1.0);
}

vec4 border_over(vec4 fill, vec4 edge, float d, float inner_d, float soft, float bw, float opacity, bool shrink) {
    float cov = clamp(0.5 - d / (soft * 2.0), 0.0, 1.0);
    float ring = max(cov - clamp(0.5 - inner_d / (soft * 2.0), 0.0, 1.0), 0.0);
    float hide = clamp(edge.a / clamp(opacity, 1e-6, 1.0), 0.0, 1.0);
    float under = clamp(0.5 - (d + (shrink && hide > 0.999 ? bw * 0.5 : 0.0)) / (soft * 2.0), 0.0, 1.0);
    return edge * ring + fill * (under * (1.0 - hide * ring));
}

float box_cov(vec2 p, vec2 halfSize, vec4 radii) {
    float r = radii.x;
    if (p.x > 0.0) {
        r = (p.y > 0.0 ? radii.z : radii.y);
    } else {
        r = (p.y > 0.0 ? radii.w : radii.x);
    }
    if (r == 0.0) {
        vec2 e = clamp(min(halfSize, p + vec2(0.5)) - max(-halfSize, p - vec2(0.5)), vec2(0.0), vec2(1.0));
        return e.x * e.y;
    }
    return clamp(0.5 - sd_rounded(p, halfSize, radii), 0.0, 1.0);
}

void main() {
    float kind = vParams.y;
#ifdef RUNE_OUTLINES
    vec4 lcdCoverage = vec4(0.0);
#endif
    if (kind > 11.5) discard;
    vec2 halfSize = vRect.zw * 0.5;
    vec2 center = vRect.xy + halfSize;
    vec4 col = vec4(0.0);
    // Fragment position is the rasterizer's exact pixel centre; interpolated `vPoint` drifts by
    // subpixel ULPs on some drivers. Only rotated glyphs need interpolated `vPoint`.
    vec2 screen = vec2(gl_FragCoord.x, uViewport.y - gl_FragCoord.y) + uOrigin;

#ifdef RUNE_OUTLINES
    if (uAtlasFill != 0) screen.y = gl_FragCoord.y;
#endif
    if (kind < 0.5) {
        float d = sd_rounded(screen - center, halfSize, vRadii);
        float soft = max(vParams.z, 0.5);
        float bw = vParams.x;
        if (bw > 0.0) {
            vec4 w = vUV;
            bool sides = w.z >= 0.0 && any(notEqual(w, vec4(0.0)));
            float inner_d = d + bw;
            if (sides) {
                vec2 ih = max(halfSize - vec2(w.y + w.w, w.x + w.z) * 0.5, vec2(0.0));
                vec2 ic = center + vec2(w.w - w.y, w.x - w.z) * 0.5;
                vec4 cut = vec4(max(w.x, w.w), max(w.x, w.y), max(w.z, w.y), max(w.z, w.w));
                inner_d = sd_rounded(screen - ic, ih, sign(vRadii) * max(abs(vRadii) - cut, vec4(0.0)));
            }
            col = border_over(vFill, vBorder, d, inner_d, soft, bw, vParams.w, !sides && any(notEqual(vRadii, vec4(0.0))));
        } else {
            col = vFill * clamp(0.5 - d / (soft * 2.0), 0.0, 1.0);
        }
    } else if (kind < 1.5) {
        float sigma = max(vParams.z, 0.01);
        float corner = min(abs(vRadii.x), min(halfSize.x, halfSize.y));
        col = vFill * shadow_fn(screen - center, halfSize, sigma, corner);
        if (vUV.z > 0.0) {
            vec2 hole = vUV.zw * 0.5;
            col = col * clamp(0.5 + sd_rounded(screen - (vRect.xy + vUV.xy + hole), hole, vec4(vRadii.w)), 0.0, 1.0);
        }
    } else if (kind > 6.5) {
        float d = sd_rounded(screen - center, halfSize, vRadii);
        if (kind > 10.5) {
            float soft = max(vParams.z, 0.5);
            float cov = clamp(0.5 - d / (soft * 2.0), 0.0, 1.0);
            float t0_raw = vParams.x;
            float t1_raw = vParams.w;
            bool lower_open = t0_raw >= 1.5;
            bool upper_open = t1_raw >= 1.5;
            float t0 = (lower_open ? t0_raw - 2.0 : t0_raw);
            float t1 = (upper_open ? t1_raw - 2.0 : t1_raw);
            float t;
            if (vUV.z > 0.0) {
                t = length((screen - vRect.xy - vUV.xy) / vUV.zw);
            } else {
                t = 0.5 + dot(screen - center, vUV.xy);
            }
            if ((lower_open && t < t0) || (upper_open && t >= t1)) {
                col = vec4(0.0);
            } else {
                float u = (t1 <= t0 + 1e-6 ? (t >= t0 ? 1.0 : 0.0) : clamp((t - t0) / (t1 - t0), 0.0, 1.0));
                col = mix(vFill, vBorder, u) * cov;
            }
        } else if (kind > 9.5) {
            float soft = max(vParams.z, 0.5);
            float bw = vParams.x;
            float ring = clamp(0.5 - d / (soft * 2.0), 0.0, 1.0) - clamp(0.5 - (d + bw) / (soft * 2.0), 0.0, 1.0);
            float t = clamp((screen.y - vRect.y) / max(vRect.w, 1.0), 0.0, 1.0);
            vec2 arc = ring_arc(screen - vRect.xy, vRect.zw, vRadii, bw);
            col = mix(vFill, vBorder, t) * (ring * dash_cov(arc.x, arc.y, vUV.xyz));
        } else {
            vec2 size = vec2(textureSize(uImageAtlas, 0));
            vec2 end = vUV.xy + vUV.zw;
            // The UV window may be a fractional crop within a larger packed image.
            bool hasBounds = all(greaterThan(vBorder.zw, vBorder.xy));
            vec2 lower = clamp(hasBounds ? vBorder.xy : min(vUV.xy, end), vec2(0), size);
            vec2 upper = clamp(hasBounds ? vBorder.zw : max(vUV.xy, end), vec2(0), size);
            vec2 lo = min(floor(lower + lower * 1.1920929e-7), size - 1.0);
            vec2 hi = clamp(ceil(upper - upper * 1.1920929e-7) - 1.0, lo, size - 1.0);
            vec2 coords = (screen - vRect.xy) / vRect.zw;
            vec2 pixel = clamp(vUV.xy + coords * vUV.zw - 0.5, lo, hi);
            ivec2 t0 = ivec2(floor(pixel));
            ivec2 t1 = min(t0 + ivec2(1), ivec2(hi));
            vec2 f = fract(pixel);
            bool premultiplied = vParams.z > 0.5;
            vec4 c = mix(
                mix(image_texel(t0, premultiplied), image_texel(ivec2(t1.x, t0.y), premultiplied), f.x),
                mix(image_texel(ivec2(t0.x, t1.y), premultiplied), image_texel(t1, premultiplied), f.x),
                f.y
            );
            col = c * (vFill.a * clamp(0.5 - d, 0.0, 1.0));
        }
    } else if (kind > 4.5 && kind < 5.5) {
        col = vFill * segment_fn(screen, vRadii.xy, vRadii.zw, vParams.x, vParams.z > 0.5);
    } else if (kind > 5.5 && kind < 6.5) {
        col = vFill * triangle_fn(screen, vRadii.xy, vRadii.zw, vUV.xy, uint(vParams.x + 0.5));
    } else if (kind > 2.5) {
        if (kind < 3.5) {
            float spread = vParams.x;
            vec2 ih = max(halfSize - vec2(spread), vec2(0.0));
            vec2 q = screen - center - vUV.xy;
            float lit;
            if (vParams.z < 0.3) {
                lit = box_cov(q, ih, sign(vRadii) * max(abs(vRadii) - vec4(spread), vec4(0.0)));
            } else {
                lit = shadow_fn(q, ih, vParams.z, max(min(abs(vRadii.x) - spread, min(ih.x, ih.y)), 0.0));
            }
            col = vFill * box_cov(screen - center, halfSize, vRadii) * (1.0 - clamp(lit, 0.0, 1.0));
        } else {
            float d = sd_rounded(screen - center, halfSize, vRadii);
            float t = clamp((screen.y - vRect.y) / max(vRect.w, 1.0), 0.0, 1.0);
            float soft = max(vParams.z, 0.5);
            float bw = vParams.x;
            if (bw > 0.0) {
                col = border_over(vFill, mix(vBorder, vUV, t), d, d + bw, soft, bw, vParams.w, any(notEqual(vRadii, vec4(0.0))));
            } else {
                col = mix(vFill, vUV, t) * clamp(0.5 - d / (soft * 2.0), 0.0, 1.0);
            }
        }
    } else {
        bool rotated = vParams.x != 0.0;
        vec2 glyphPoint = rotated ? vPoint : screen;
        if (any(lessThan(glyphPoint, vRect.xy)) || any(greaterThanEqual(glyphPoint, vRect.xy + vRect.zw))) discard;
        ivec2 atlasDims = textureSize(uGlyphAtlas, 0);
        ivec2 maxCoord = max(atlasDims - ivec2(1), ivec2(0));
        float cov;
#ifdef RUNE_OUTLINES
        if (vRadii.w > 0.0) {
            cov = outline_glyph(vRadii, vBorder, glyphPoint, lcdCoverage);
        } else if (vRadii.x == 1.0) {
            ivec2 offset = ivec2(floor(glyphPoint - vRect.xy));
            ivec2 texel = ivec2(vUV.xy) + ivec2(3 * offset.x, offset.y);
            vec3 channels = vec3(
                texelFetch(uGlyphAtlas, clamp(texel, ivec2(0), maxCoord), 0).r,
                texelFetch(uGlyphAtlas, clamp(texel + ivec2(1, 0), ivec2(0), maxCoord), 0).r,
                texelFetch(uGlyphAtlas, clamp(texel + ivec2(2, 0), ivec2(0), maxCoord), 0).r);
            lcdCoverage = vec4(channels, 1.0);
            cov = (channels.x + channels.y + channels.z) / 3.0;
        } else
#endif
        if (vUV.z > 0.0 || rotated) {
            vec2 p = glyphPoint;
            vec2 span = (vUV.z > 0.0 ? vUV.zw : vRect.zw);
            vec2 local = (p - vRect.xy) * span / max(vRect.zw, vec2(1e-5)) - vec2(0.5);
            ivec2 uv = ivec2(vUV.xy + floor(local));
            vec2 f = fract(local);
            float a00 = texelFetch(uGlyphAtlas, clamp(uv, ivec2(0), maxCoord), 0).r;
            float a10 = texelFetch(uGlyphAtlas, clamp(uv + ivec2(1, 0), ivec2(0), maxCoord), 0).r;
            float a01 = texelFetch(uGlyphAtlas, clamp(uv + ivec2(0, 1), ivec2(0), maxCoord), 0).r;
            float a11 = texelFetch(uGlyphAtlas, clamp(uv + ivec2(1, 1), ivec2(0), maxCoord), 0).r;
            cov = mix(mix(a00, a10, f.x), mix(a01, a11, f.x), f.y);
        } else {
            ivec2 texel = clamp(ivec2(vUV.xy + floor(screen - vRect.xy)), ivec2(0), maxCoord);
            cov = texelFetch(uGlyphAtlas, texel, 0).r;
        }
        if (vParams.w < 0.0) {
            col = vec4(roundEven(cov * 255.0) / 255.0);
        } else {
            col = vFill * pow(cov, vParams.w);
        }
    }
    vec4 source = col * clip_alpha(screen, vClip, vFade);
    bool flatFill = kind == 0.0 && vParams.x == 0.0 && vFill.a > 0.0 && vFill.a < 1.0;
    bool grayMask = kind == 2.0 && vRadii.w == 0.0 && vRadii.x == 0.0
        && vParams.x == 0.0 && vUV.z == 0.0 && vParams.w >= 0.0;
    if (uSRGBBlend != 0 && uInLayer == 0 && (flatFill || grayMask)) {
        // Match the CPU byte blender after the fragment's coverage and clip are known.
        source = roundEven(clamp(source, 0.0, 1.0) * 255.0) / 255.0;
    }
    // The window's UNorm target saturates fragment output before blending.
    // Preserve floating-point range inside isolated layers.
    outColor = uInLayer == 0 ? clamp(source, 0.0, 1.0) : source;
#ifdef RUNE_OUTLINE_LCD
    outBlend = vec4(outColor.a);
    if (lcdCoverage.w != 0.0) {
        float mean = pow((lcdCoverage.r + lcdCoverage.g + lcdCoverage.b) / 3.0, vParams.w);
        if (mean < 1e-5) {
            outColor = vec4(0.0);
            outBlend = vec4(0.0);
        } else {
            vec3 factors = pow(lcdCoverage.rgb, vec3(vParams.w)) / mean;
            outBlend.rgb = outColor.a * factors;
            outColor.rgb *= factors;
        }
    }
#endif
}
