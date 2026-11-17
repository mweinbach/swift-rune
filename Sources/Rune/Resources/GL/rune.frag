#ifdef GL_ES
precision highp sampler2D;
#endif

uniform vec2 uViewport;
uniform sampler2D uGlyphAtlas;
uniform sampler2D uImageAtlas;

flat in vec4 rect;
flat in vec4 radii;
flat in vec4 fillColor;
flat in vec4 border;
flat in vec4 params;
flat in vec4 uv;
flat in vec4 clipRect;
flat in vec4 fade;
flat in vec4 originTurn;
out vec4 outColor;

float saturate(float x) { return clamp(x, 0.0, 1.0); }

vec4 premultiplied(vec4 color, float coverage) {
    float alpha = color.a * coverage;
    return vec4(color.rgb * alpha, alpha);
}

// Keep fractional mask coverage at shader precision, including on fixed-point GL texture filters.
float filteredGlyph(vec2 atlasUV) {
    ivec2 size = textureSize(uGlyphAtlas, 0);
    vec2 pixel = clamp(atlasUV, 0.0, 1.0) * vec2(size) - 0.5;
    ivec2 first = ivec2(floor(pixel));
    ivec2 last = clamp(first + ivec2(1), ivec2(0), size - 1);
    first = clamp(first, ivec2(0), size - 1);
    vec2 f = fract(pixel);
    float topLeft = texelFetch(uGlyphAtlas, first, 0).r;
    float topRight = texelFetch(uGlyphAtlas, ivec2(last.x, first.y), 0).r;
    float bottomLeft = texelFetch(uGlyphAtlas, ivec2(first.x, last.y), 0).r;
    float bottomRight = texelFetch(uGlyphAtlas, last, 0).r;
    return mix(mix(topLeft, topRight, f.x), mix(bottomLeft, bottomRight, f.x), f.y);
}

vec4 sampleImage(vec2 coords) {
    vec2 size = vec2(textureSize(uImageAtlas, 0));
    vec2 start = clamp(uv.xy, 0.0, 1.0) * size;
    vec2 end = clamp(uv.zw, 0.0, 1.0) * size;
    vec2 lower = min(start, end);
    vec2 upper = max(start, end);
    if (all(greaterThan(border.zw, border.xy))) {
        lower = clamp(border.xy, vec2(0.0), size);
        upper = clamp(border.zw, vec2(0.0), size);
    }
    // Normalizing an integer texel edge can round it just outside its atlas slot.
    vec2 lo = min(floor(lower + lower * 1.1920929e-7), size - 1.0);
    vec2 hi = clamp(ceil(upper - upper * 1.1920929e-7) - 1.0, lo, size - 1.0);
    vec2 pixel = clamp(mix(start, end, coords) - 0.5, lo, hi);
    ivec2 first = ivec2(floor(pixel));
    ivec2 last = min(first + ivec2(1), ivec2(hi));
    vec2 f = fract(pixel);
    vec4 topLeft = premultiplied(texelFetch(uImageAtlas, first, 0), 1.0);
    vec4 topRight = premultiplied(texelFetch(uImageAtlas, ivec2(last.x, first.y), 0), 1.0);
    vec4 bottomLeft = premultiplied(texelFetch(uImageAtlas, ivec2(first.x, last.y), 0), 1.0);
    vec4 bottomRight = premultiplied(texelFetch(uImageAtlas, last, 0), 1.0);
    return mix(mix(topLeft, topRight, f.x), mix(bottomLeft, bottomRight, f.x), f.y);
}

float cornerRadius(vec2 p, vec4 corners) {
    if (p.x < 0.0) return p.y < 0.0 ? corners.x : corners.w;
    return p.y < 0.0 ? corners.y : corners.z;
}

// Negative radii select Rune's continuous-corner profile.
float boxDistance(vec2 p, vec2 halfSize, vec4 corners) {
    float raw = cornerRadius(p, corners);
    float r = min(abs(raw), max(0.0, min(halfSize.x, halfSize.y)));
    vec2 q = abs(p) - halfSize + r;
    float sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    if (raw >= 0.0 || r <= 0.0001) return sd;
    vec2 u = max(abs(p) - (halfSize - r * 1.528665), 0.0) / (r * 1.528665);
    if (min(u.x, u.y) <= 0.0) return sd;
    float squircle = (pow(pow(u.x, 2.4) + pow(u.y, 2.4), 1.0 / 2.4) - 1.0) * (r * 0.85);
    return mix(sd, squircle, 0.35 * saturate(min(u.x, u.y) * 2.0));
}

float coverage(float sd) { return saturate(0.5 - sd); }

vec4 roundedRect(vec2 p, vec2 halfSize) {
    float outer = boxDistance(p, halfSize, radii);
    float outerCoverage = coverage(outer);
    if (border.a <= 0.0001 || outerCoverage <= 0.0) return premultiplied(fillColor, outerCoverage);
    float inner = outer - 10.0;
    if (params.x != 0.0) {
        // Per-edge widths are packed in top, right, bottom, left order.
        vec4 edges = params.x < 0.0 ? uv : vec4(params.x);
        vec2 shift = vec2(edges.w - edges.y, edges.x - edges.z) * 0.5;
        vec2 inset = vec2(edges.w + edges.y, edges.x + edges.z) * 0.5;
        vec4 insetRadius = (edges.xxzz + edges.wyyw) * 0.5;
        vec4 innerRadii = sign(radii) * max(abs(radii) - insetRadius, 0.0);
        inner = boxDistance(p - shift, max(halfSize - inset, 0.0), innerRadii);
    }
    float fillCoverage = border.a >= 0.999 ? coverage((outer + inner) * 0.5) : outerCoverage;
    vec4 stroke = premultiplied(border, max(outerCoverage - coverage(inner), 0.0));
    return stroke + premultiplied(fillColor, fillCoverage) * (1.0 - stroke.a);
}

float erfApprox(float x) {
    float t = 1.0 / (1.0 + 0.3275911 * abs(x));
    float factor = (((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t
        - 0.284496736) * t + 0.254829592) * t);
    return sign(x) * (1.0 - factor * exp(-x * x));
}

float gaussianShadow(vec2 p, vec2 halfSize, float radius, float blur) {
    if (blur <= 0.5) return coverage(boxDistance(p, halfSize, vec4(radius)));
    float sigma = max(blur * 0.5, 0.25);
    float r = min(max(0.0, radius), min(halfSize.x, halfSize.y));
    float low = max(-halfSize.y, p.y - 3.0 * sigma);
    float high = min(halfSize.y, p.y + 3.0 * sigma);
    if (low >= high) return 0.0;
    float strideY = (high - low) * 0.25;
    float inv = 1.0 / (1.41421356 * sigma);
    float sum = 0.0;
    for (int i = 0; i < 4; ++i) {
        float y = low + (float(i) + 0.5) * strideY;
        float dyCorner = max(0.0, abs(y) - (halfSize.y - r));
        float halfWidth = halfSize.x - r + sqrt(max(0.0, r * r - dyCorner * dyCorner));
        float integralX = 0.5 * (erfApprox((p.x + halfWidth) * inv) - erfApprox((p.x - halfWidth) * inv));
        float dy = (y - p.y) / sigma;
        sum += integralX * (0.3989422804 / sigma) * exp(-0.5 * dy * dy) * strideY;
    }
    return saturate(sum);
}

float dropShadow(vec2 pixel) {
    vec4 caster = border.z > 0.0 && border.w > 0.0 ? border : rect;
    vec2 halfSize = caster.zw * 0.5;
    vec2 casterPoint = pixel - caster.xy - halfSize;
    vec2 p = casterPoint - uv.xy;
    float r = max(0.0, abs(cornerRadius(p, radii)) + params.z);
    float shadow = gaussianShadow(p, max(halfSize + params.z, 0.0), r, params.x);
    if (params.w > 0.5) shadow *= 1.0 - coverage(boxDistance(casterPoint, halfSize, radii));
    return shadow;
}

float ringCoverage(vec2 p, vec2 halfSize, float width, float outerCoverage) {
    float inner = boxDistance(p, max(halfSize - width, 0.0), max(abs(radii) - width, 0.0));
    return max(outerCoverage - coverage(inner), 0.0);
}

vec4 linearGradient(vec2 p, vec2 halfSize, float outerCoverage) {
    vec2 dir = vec2(cos(params.z), sin(params.z));
    float extent = dot(abs(dir), halfSize);
    float t = extent > 0.0001 ? saturate(0.5 + dot(p, dir) / (2.0 * extent)) : 0.5;
    float mask = params.x > 0.0 ? ringCoverage(p, halfSize, params.x, outerCoverage) : outerCoverage;
    return premultiplied(mix(fillColor, border, t), mask);
}

float segment(vec2 pixel) {
    vec2 edge = uv.zw - uv.xy;
    float len2 = dot(edge, edge);
    float halfWidth = max(params.x, 1.0) * 0.5;
    float weight = saturate(params.x);
    if (len2 < 0.000001) return coverage(length(pixel - uv.xy) - halfWidth) * weight;
    if (params.z >= 0.5) {
        float t = saturate(dot(pixel - uv.xy, edge) / len2);
        return coverage(length(pixel - (uv.xy + edge * t)) - halfWidth) * weight;
    }
    float len = sqrt(len2);
    vec2 dir = edge / len;
    vec2 p = pixel - (uv.xy + uv.zw) * 0.5;
    vec2 q = abs(vec2(dot(p, dir), dot(p, vec2(-dir.y, dir.x)))) - vec2(len * 0.5, halfWidth);
    return coverage(length(max(q, 0.0)) + min(max(q.x, q.y), 0.0)) * weight;
}

float cross2(vec2 a, vec2 b) { return a.x * b.y - a.y * b.x; }

float triangle(vec2 pixel) {
    vec2 vertices[3] = vec2[3](uv.xy, uv.zw, originTurn.xy);
    float area = cross2(vertices[1] - vertices[0], vertices[2] - vertices[0]);
    if (abs(area) < 0.00001) return 0.0;
    int aaMask = int(round(params.x));
    float result = 1.0;
    for (int i = 0; i < 3; ++i) {
        vec2 edge = vertices[(i + 1) % 3] - vertices[i];
        float len = length(edge);
        if (len < 0.00001) return 0.0;
        vec2 oriented = edge * sign(area);
        float d = cross2(pixel - vertices[i], oriented) / len;
        if ((aaMask & (1 << i)) != 0) {
            result = min(result, coverage(d));
        } else {
            // Half-open interior edges let adjacent triangles own their shared edge exactly once.
            bool ownsTie = oriented.y > 0.0 || (oriented.y == 0.0 && oriented.x < 0.0);
            if (d > 0.0 || (d == 0.0 && !ownsTie)) return 0.0;
        }
    }
    return result;
}

float ringArc(vec2 p, vec2 halfSize, float radius) {
    const float quarterTurn = 1.5707963268;
    float r = clamp(radius, 0.0, min(halfSize.x, halfSize.y));
    vec2 straight = halfSize - r;
    float top = 2.0 * straight.x;
    float side = 2.0 * straight.y;
    float arc = quarterTurn * r;
    if (p.y <= -straight.y && abs(p.x) <= straight.x) return p.x + straight.x;
    if (p.x > straight.x && p.y < -straight.y) return top + atan(p.x - straight.x, -p.y - straight.y) * r;
    if (p.x >= straight.x && abs(p.y) <= straight.y) return top + arc + (p.y + straight.y);
    if (p.x > straight.x && p.y > straight.y) return top + arc + side + atan(p.y - straight.y, p.x - straight.x) * r;
    if (p.y >= straight.y && abs(p.x) <= straight.x) return top + 2.0 * arc + side + (straight.x - p.x);
    if (p.x < -straight.x && p.y > straight.y) return 2.0 * top + 2.0 * arc + side + atan(-p.x - straight.x, p.y - straight.y) * r;
    if (p.x <= -straight.x && abs(p.y) <= straight.y) return 2.0 * top + 3.0 * arc + side + (straight.y - p.y);
    return 2.0 * top + 3.0 * arc + 2.0 * side + atan(-p.y - straight.y, -p.x - straight.x) * r;
}

float dashedRing(vec2 p, vec2 halfSize, float outerCoverage) {
    float width = max(0.5, params.x);
    float mask = ringCoverage(p, halfSize, width, outerCoverage);
    if (mask <= 0.0) return 0.0;
    float radius = max(0.0, abs(cornerRadius(p, radii)) - width * 0.5);
    float arc = ringArc(p, max(halfSize - width * 0.5, 0.0), radius);
    float period = max(params.z + params.w, 1.0);
    float pos = mod(arc + uv.x, period);
    float dash = max(min(saturate(pos + 0.5), saturate(params.z - pos + 0.5)), saturate(pos - period + params.z + 0.5));
    return mask * dash;
}

vec4 shade(vec2 pixel) {
    vec2 halfSize = rect.zw * 0.5;
    vec2 p = pixel - (rect.xy + halfSize);
    if (originTurn.z != 0.0) {
        float c = cos(-originTurn.z);
        float s = sin(-originTurn.z);
        p = mat2(c, s, -s, c) * p;
    }

    // Layer, backdrop and effect markers are handled by the pass encoder.
    int kind = int(round(params.y));
    if (kind == 0) return roundedRect(p, halfSize);
    if (kind == 1) return premultiplied(fillColor, dropShadow(pixel));
    if (kind == 2) {
        float mask;
        if (params.z == 1.0 && originTurn.z == 0.0) {
            vec2 offset = pixel - rect.xy;
            if (any(lessThan(offset, vec2(0.0))) || any(greaterThanEqual(offset, rect.zw))) return vec4(0.0);
            vec2 size = vec2(textureSize(uGlyphAtlas, 0));
            vec2 start = uv.xy * size;
            vec2 texel = floor(start + abs(start) * 1.1920929e-7) + floor(offset);
            if (any(lessThan(texel, vec2(0.0))) || any(greaterThanEqual(texel, size))) return vec4(0.0);
            mask = texelFetch(uGlyphAtlas, ivec2(texel), 0).r;
        } else {
            vec2 coords = (p + halfSize) / max(rect.zw, 0.0001);
            if (any(lessThan(coords, vec2(0.0))) || any(greaterThan(coords, vec2(1.0)))) return vec4(0.0);
            mask = filteredGlyph(uv.xy + (uv.zw - uv.xy) * coords);
        }
        if (params.w > 0.0 && abs(params.w - 1.0) > 0.001) mask = pow(saturate(mask), params.w);
        return premultiplied(fillColor, mask);
    }
    if (kind == 5) return premultiplied(fillColor, segment(pixel));
    if (kind == 6) return premultiplied(fillColor, triangle(pixel));

    float outerCoverage = coverage(boxDistance(p, halfSize, radii));
    if (outerCoverage <= 0.0) return vec4(0.0);
    if (kind == 3) {
        float r = max(0.0, abs(cornerRadius(p - uv.xy, radii)) - params.z);
        float lit = gaussianShadow(p - uv.xy, max(halfSize - params.z, 0.0), r, params.x);
        return premultiplied(fillColor, outerCoverage * saturate(1.0 - lit));
    }
    if (kind == 4) return linearGradient(p, halfSize, outerCoverage);
    if (kind == 7) {
        vec2 coords = clamp((p + halfSize) / max(rect.zw, 0.0001), 0.0, 1.0);
        return sampleImage(coords) * vec4(fillColor.rgb, 1.0) * (fillColor.a * outerCoverage);
    }
    if (kind == 10) return premultiplied(fillColor, dashedRing(p, halfSize, outerCoverage));
    if (kind == 11) {
        float t = saturate(length((pixel - uv.xy) / max(uv.zw, 0.001)));
        return premultiplied(mix(fillColor, border, t), outerCoverage);
    }
    return vec4(0.0);
}

void main() {
    // GL framebuffer coordinates start at the bottom. All atlas UVs and Rune geometry start at the top.
    vec2 pixel = vec2(gl_FragCoord.x, uViewport.y - gl_FragCoord.y);
    vec2 clipped = clamp(min(pixel - clipRect.xy, clipRect.xy + clipRect.zw - pixel) + 0.5, 0.0, 1.0);
    float mask = clipped.x * clipped.y;
    if (clipRect.z <= 0.0 || clipRect.w <= 0.0 || mask <= 0.0) {
        outColor = vec4(0.0);
        return;
    }
    if (fade.z != 0.0) mask *= mix(fade.w, 1.0, saturate(dot(pixel - originTurn.xy, fade.xy) * fade.z));
    outColor = shade(pixel) * mask;
}
