#ifdef GL_ES
precision highp sampler2D;
#endif

uniform sampler2D uSource;
uniform sampler2D uBlurred;
uniform int uMode;
uniform int uRadius;
uniform int uHorizontal;
uniform int uSRGBBlend;
uniform int uDisplaySRGB;
uniform vec4 uBounds; // Inclusive texture coordinates for the blur kernel.
uniform vec4 uRect;
uniform vec4 uClip;
uniform vec4 uRadii;
uniform vec4 uFade;
uniform vec4 uPose;   // Fade origin, rotation (radians), group opacity.
// The production RenderFrame ABI supplies four independently faded clip edges
// in screen coordinates and rotates around an explicit pivot.
uniform int uFrameStyle;
uniform vec4 uFrameClip;
uniform vec4 uClipWidths;
uniform vec4 uClipOffsets;
uniform vec4 uClipCorners;
uniform vec4 uHole;
// Device-pixel rectangles in the scene's top-left coordinate space. Zero
// dimensions select the full texture for simple full-viewport WebGL callers.
uniform vec4 uTargetRect;
uniform vec4 uSourceRect;
uniform vec4 uClearColor;
out vec4 outColor;

#ifndef RUNE_ROOT_PASS
float frameBoxDistance(vec2 p, vec2 halfSize, vec4 corners) {
    float r = p.x > 0.0 ? (p.y > 0.0 ? corners.z : corners.y) : (p.y > 0.0 ? corners.w : corners.x);
    vec2 edge = halfSize - abs(p);
    if (r < 0.0) {
        float e = 1.52866483 * min(-r, min(halfSize.x, halfSize.y));
        vec2 v = vec2(e) - edge;
        if (min(v.x, v.y) <= 0.0) return max(-edge.x, -edge.y);
        float t = atan(v.y, v.x) * (4.0 / 3.14159265) - 1.0;
        float t2 = t * t;
        return length(v) - e * (1.14602295 + t2 * (-0.37573161 + t2 * (0.30796609 - 0.07724354 * t2)));
    }
    r = min(r, min(halfSize.x, halfSize.y));
    vec2 q = vec2(r) - edge;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

float edgeRamp(float d, float width) {
    if (width == 0.0) return clamp(d + 0.5, 0.0, 1.0);
    float x = clamp(d / abs(width), 0.0, 1.0);
    return width < 0.0 ? x : x * x * (3.0 - 2.0 * x);
}

float frameCoverage(vec2 p) {
    vec4 distances = vec4(p - uFrameClip.xy, uFrameClip.zw - p);
    float alpha = 1.0;
    for (int i = 0; i < 4; i++) {
        float d = distances[i], width = uClipWidths[i], offset = uClipOffsets[i];
        float a = edgeRamp(d, width);
        if (offset >= 1.0) a = edgeRamp(d, 0.0);
        else if (offset > 0.0) a = min(edgeRamp(d, 0.0), edgeRamp(d + offset * abs(width), width));
        alpha *= a;
    }
    if (any(notEqual(uClipCorners, vec4(0.0)))) {
        vec2 halfSize = (uFrameClip.zw - uFrameClip.xy) * 0.5;
        alpha *= clamp(0.5 - frameBoxDistance(p - uFrameClip.xy - halfSize, halfSize, uClipCorners), 0.0, 1.0);
    }
    return alpha;
}

float clipCoverage(vec2 point) {
    if (any(lessThanEqual(uClip.zw, vec2(0.0)))) return 0.0;
    vec2 coverage = clamp(min(point - uClip.xy, uClip.xy + uClip.zw - point) + 0.5, 0.0, 1.0);
    return coverage.x * coverage.y;
}

// Rune's negative radii select a continuous corner; positive radii select a circle.
float boxDistance(vec2 p, vec2 halfSize) {
    float radius = p.x < 0.0 ? (p.y < 0.0 ? uRadii.x : uRadii.w)
                             : (p.y < 0.0 ? uRadii.y : uRadii.z);
    float r = min(abs(radius), max(0.0, min(halfSize.x, halfSize.y)));
    vec2 q = abs(p) - halfSize + r;
    float circular = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    if (radius >= 0.0 || r <= 1e-4) return circular;
    vec2 u = max(abs(p) - (halfSize - r * 1.528665), 0.0) / (r * 1.528665);
    if (min(u.x, u.y) <= 0.0) return circular;
    float continuous = (pow(pow(u.x, 2.4) + pow(u.y, 2.4), 1.0 / 2.4) - 1.0) * (r * 0.85);
    return mix(circular, continuous, 0.35 * clamp(min(u.x, u.y) * 2.0, 0.0, 1.0));
}

vec4 blur(ivec2 px) {
    ivec2 low = ivec2(uBounds.xy), high = ivec2(uBounds.zw);
    if (any(lessThan(px, low)) || any(greaterThan(px, high))) return texelFetch(uSource, px, 0);
    ivec2 direction = uHorizontal != 0 ? ivec2(1, 0) : ivec2(0, 1);
    vec4 sum = vec4(0.0);
    for (int i = -uRadius; i <= uRadius; ++i) {
        sum += texelFetch(uSource, clamp(px + i * direction, low, high), 0);
    }
    return sum / float(uRadius * 2 + 1);
}

vec4 layer(ivec2 px, vec2 frag, vec2 size) {
    vec2 halfSize = uRect.zw * 0.5, center = uRect.xy + halfSize;
    vec2 pivot = uFrameStyle == 0 ? center : uPose.xy;
    vec2 rel = frag - pivot;
    float s = sin(-uPose.z), c = cos(-uPose.z);
    vec2 local = vec2(c * rel.x - s * rel.y, s * rel.x + c * rel.y);
    float coverage;
    if (uFrameStyle != 0) {
        coverage = frameCoverage(frag);
        if (uHole.w > 0.0) {
            float d = length(frag - uHole.xy) - (uHole.z + uHole.w) * 0.5;
            coverage *= clamp(d / max(uHole.w - uHole.z, 1.0) + 0.5, 0.0, 1.0);
        }
    } else {
        coverage = clipCoverage(frag);
        if (any(greaterThan(uRadii, vec4(0.0)))) {
            coverage *= clamp(0.5 - boxDistance(local, halfSize), 0.0, 1.0);
        }
        if (uFade.z != 0.0) {
            float progress = clamp(dot(frag - uPose.xy, uFade.xy) * uFade.z, 0.0, 1.0);
            coverage *= mix(uFade.w, 1.0, progress);
        }
    }
    if (coverage <= 0.0) return vec4(0.0);
    vec4 source = uSourceRect.z > 0.0 ? uSourceRect : vec4(0.0, 0.0, size);
    vec2 position = uPose.z == 0.0 ? frag : pivot + local;
    vec2 sourcePixel = ((position - source.xy) / source.zw) * size;
    vec4 value;
    if (uPose.z == 0.0 && all(equal(source.zw, size))) {
        ivec2 texel = ivec2(floor(sourcePixel));
        if (any(lessThan(texel, ivec2(0))) || any(greaterThanEqual(texel, ivec2(size)))) return vec4(0.0);
        value = texelFetch(uSource, ivec2(texel.x, int(size.y) - 1 - texel.y), 0);
    } else {
        // Match the oracle's transparent bilinear border on GLES (which lacks CLAMP_TO_BORDER).
        vec2 edge = clamp(min(sourcePixel, size - sourcePixel) + 0.5, 0.0, 1.0);
        value = texture(uSource, vec2(sourcePixel.x, size.y - sourcePixel.y) / size) * (edge.x * edge.y);
    }
    if (uFrameStyle == 2) value = clamp(value, 0.0, 1.0);
    return value * (clamp(uPose.w, 0.0, 1.0) * coverage);
}

#endif

vec3 encodeSRGB(vec3 x) {
    return mix(1.055 * pow(x, vec3(1.0 / 2.4)) - 0.055, 12.92 * x, lessThanEqual(x, vec3(0.0031308)));
}

vec3 decodeSRGB(vec3 x) {
    return mix(pow((x + 0.055) / 1.055, vec3(2.4)), x / 12.92, lessThanEqual(x, vec3(0.04045)));
}

vec4 displayPixel(ivec2 px) {
    // Intermediate buffers hold premultiplied values in the scene's blending space.
    vec4 value = texelFetch(uSource, px, 0);
    if (uMode == 6 && uSRGBBlend == 0) {
        // Recover the stored sRGB byte before dividing. Hardware samplers can
        // approximate sRGB decoding, which is visible after division by a small alpha.
        vec3 stored = floor(encodeSRGB(value.rgb) * 255.0 + 0.5) / 255.0;
        value.rgb = decodeSRGB(stored);
    }
    float alpha = clamp(value.a, 0.0, 1.0);
    // Production reads a UNorm root. At zero stored alpha Metal returns its stored
    // RGB bytes, including tiny linear values represented by the sRGB attachment.
    vec3 rgb = alpha > 1e-5 ? clamp(value.rgb / alpha, 0.0, 1.0) : (uMode == 6 ? value.rgb : vec3(0.0));
    if (uSRGBBlend == 0 && uDisplaySRGB == 0) rgb = encodeSRGB(rgb);
    if (uSRGBBlend != 0 && uDisplaySRGB != 0) rgb = decodeSRGB(rgb);
    return vec4(rgb, alpha);
}

void main() {
    if (uMode == 7) {
        outColor = uClearColor;
        return;
    }
    ivec2 px = ivec2(gl_FragCoord.xy);
#ifdef RUNE_ROOT_PASS
    outColor = displayPixel(px);
#else
    vec2 size = vec2(textureSize(uSource, 0));
    vec4 target = uTargetRect.z > 0.0 ? uTargetRect : vec4(0.0, 0.0, size);
    vec2 frag = target.xy + vec2(gl_FragCoord.x, target.w - gl_FragCoord.y);
    if (uMode == 0) {
        outColor = blur(px);
    } else if (uMode == 1) {
        outColor = layer(px, frag, size);
    } else if (uMode == 2) {
        vec2 halfSize = uRect.zw * 0.5;
        vec2 local = frag - uRect.xy - halfSize;
        vec4 sharp = texelFetch(uSource, px, 0);
        vec4 blurred = texelFetch(uBlurred, px, 0);
        if (uFrameStyle != 0) {
            float d = frameBoxDistance(local, halfSize, uRadii);
            float coverage = clamp(0.5 - d, 0.0, 1.0) * frameCoverage(frag) * uPose.w;
            outColor = blurred * coverage + sharp * (1.0 - blurred.a * coverage);
        } else {
            float coverage = clamp(0.5 - boxDistance(local, halfSize), 0.0, 1.0) * clipCoverage(frag);
            coverage *= uPose.w;
            outColor = blurred * coverage + sharp * (1.0 - blurred.a * coverage);
        }
    } else if (uMode == 4) {
        outColor = min(vec4(1.0), texelFetch(uBlurred, px, 0) + layer(px, frag, size));
    } else if (uMode == 5) {
        vec4 source = uSourceRect.z > 0.0 ? uSourceRect : vec4(0.0, 0.0, size);
        ivec2 coord = ivec2(floor(frag - source.xy));
        bool inside = all(greaterThanEqual(coord, ivec2(0))) && all(lessThan(coord, ivec2(size)));
        outColor = inside ? texelFetch(uSource, ivec2(coord.x, int(size.y)-1-coord.y), 0) : vec4(0.0);
    } else {
        outColor = displayPixel(px);
    }
#endif
}
