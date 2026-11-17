#ifdef GL_ES
precision highp sampler2D;
#endif

uniform sampler2D uSource;
uniform sampler2D uFine;
uniform int uMode;
uniform int uAdditive;
uniform int uCount;
uniform vec4 uDomain; // Source origin and logical size in top-left texture pixels.
uniform vec4 uDest;   // Reserved origin and physical render-target size.
uniform vec4 uMap;    // Destination to source scale and offset.
uniform vec4 uRegion; // Normalized clamp bounds in top-left texture coordinates.
uniform vec2 uAxis;
uniform float uBlend;
uniform vec4 uTaps[128];
out vec4 outColor;

vec2 textureUV(vec2 uv) { return vec2(uv.x, 1.0 - uv.y); }

vec4 boundedLoad(ivec2 pixel) {
    ivec2 size = textureSize(uSource, 0);
    ivec2 texel = pixel + ivec2(uDomain.xy);
    if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, ivec2(uDomain.zw))) ||
        any(lessThan(texel, ivec2(0))) || any(greaterThanEqual(texel, size))) return vec4(0.0);
    vec4 value = texelFetch(uSource, ivec2(texel.x, size.y - 1 - texel.y), 0);
    return uAdditive != 0 ? clamp(value, 0.0, 1.0) : value;
}

vec4 sampleZero(vec2 pixel) {
    // The first source can be a subrect of the host's full-size layer texture.
    // Pixels outside its stored image are transparent, including a fractional
    // pixel of coverage at the boundary.
    if (uAdditive != 0) {
        vec2 p = pixel - 0.5;
        ivec2 i = ivec2(floor(p));
        vec2 f = fract(p);
        return mix(mix(boundedLoad(i), boundedLoad(i + ivec2(1,0)), f.x),
                   mix(boundedLoad(i + ivec2(0,1)), boundedLoad(i + ivec2(1,1)), f.x), f.y);
    }
    vec2 size = vec2(textureSize(uSource, 0));
    vec2 lo = max(-uDomain.xy, vec2(0.0));
    vec2 hi = min(size - uDomain.xy, uDomain.zw);
    if (any(lessThanEqual(hi, lo))) return vec4(0.0);
    vec2 cover = clamp(pixel - lo + 0.5, 0.0, 1.0) * clamp(hi + 0.5 - pixel, 0.0, 1.0);
    vec2 uv = (clamp(pixel, lo + 0.5, hi - 0.5) + uDomain.xy) / size;
    return texture(uSource, textureUV(uv)) * (cover.x * cover.y);
}

vec4 regionSample(vec2 uv) {
    return texture(uSource, textureUV(clamp(uv, uRegion.xy, uRegion.zw)));
}

void main() {
    vec2 pixel = vec2(gl_FragCoord.x, uDest.w - gl_FragCoord.y);
    if (uMode == 0) {
        // Exact area prefilter. A fractional last texel contributes its area.
        vec2 lo = (pixel - 0.5) * uMap.xy, hi = (pixel + 0.5) * uMap.xy;
        vec4 sum = vec4(0.0);
        for (int y = int(floor(lo.y)); y < int(ceil(hi.y)); ++y) {
            float wy = max(0.0, min(hi.y, float(y + 1)) - max(lo.y, float(y)));
            for (int x = int(floor(lo.x)); x < int(ceil(hi.x)); ++x) {
                float wx = max(0.0, min(hi.x, float(x + 1)) - max(lo.x, float(x)));
                sum += boundedLoad(ivec2(x,y)) * (wx * wy);
            }
        }
        outColor = sum / (uMap.x * uMap.y);
    } else if (uMode == 1) {
        vec4 color = sampleZero(pixel) * uTaps[0].y;
        for (int i = 1; i < uCount; ++i) {
            vec2 delta = uAxis * uTaps[i].x;
            color += (sampleZero(pixel + delta) + sampleZero(pixel - delta)) * uTaps[i].y;
        }
        outColor = color;
    } else if (uMode == 2) {
        outColor = sampleZero(pixel * uMap.xy + uMap.zw);
    } else {
        vec2 uv = pixel / uDest.zw * uMap.xy + uMap.zw;
        if (uMode == 5) {
            outColor = texture(uSource, textureUV(uv));
            return;
        }
        vec2 t = 1.0 / vec2(textureSize(uSource, 0));
        if (uMode == 3) {
            vec4 center = regionSample(uv);
            vec4 near = regionSample(uv - t) + regionSample(uv + t)
                      + regionSample(uv + vec2(-t.x,t.y)) + regionSample(uv + vec2(t.x,-t.y));
            vec4 axes = regionSample(uv + vec2(-2.0*t.x,0.0)) + regionSample(uv + vec2(2.0*t.x,0.0))
                      + regionSample(uv + vec2(0.0,-2.0*t.y)) + regionSample(uv + vec2(0.0,2.0*t.y));
            vec4 corners = regionSample(uv - 2.0*t) + regionSample(uv + 2.0*t)
                         + regionSample(uv + vec2(-2.0*t.x,2.0*t.y)) + regionSample(uv + vec2(2.0*t.x,-2.0*t.y));
            outColor = (near + center) * 0.125 + axes * 0.0625 + corners * 0.03125;
        } else {
            vec4 sum = 4.0 * regionSample(uv);
            sum += 2.0 * (regionSample(uv + vec2(t.x,0.0)) + regionSample(uv - vec2(t.x,0.0))
                        + regionSample(uv + vec2(0.0,t.y)) + regionSample(uv - vec2(0.0,t.y)));
            sum += regionSample(uv + t) + regionSample(uv - t)
                 + regionSample(uv + vec2(-t.x,t.y)) + regionSample(uv + vec2(t.x,-t.y));
            vec4 fine = texture(uFine, textureUV(clamp(uv, uRegion.xy, uRegion.zw)));
            outColor = mix(fine, sum / 16.0, uBlend);
        }
    }
}
