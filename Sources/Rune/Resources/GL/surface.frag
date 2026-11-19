// Byte-backed native surfaces. Planes retain their source encoding until after sampling.
uniform vec4 uSurface[13];
uniform sampler2D uPlane0;
uniform sampler2D uPlane1;
out vec4 fragColor;

float cornerRadius(vec2 p, vec4 r) {
    return p.x > 0.0 ? (p.y > 0.0 ? r.z : r.y) : (p.y > 0.0 ? r.w : r.x);
}

float boxDistance(vec2 p, vec2 extent, vec4 radii) {
    float signedRadius = cornerRadius(p, radii);
    float r = min(abs(signedRadius), min(extent.x, extent.y));
    vec2 q = abs(p) - extent + r;
    if (signedRadius >= 0.0) return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    float e = 1.52866483 * r;
    vec2 d = abs(p) - extent;
    vec2 v = d + e;
    if (min(v.x, v.y) <= 0.0) return max(d.x, d.y);
    float u = atan(v.y, v.x) * (4.0 / 3.14159265) - 1.0;
    float u2 = u*u;
    return length(v) - e * (1.14602295 + u2 * (-0.37573161 + u2 * (0.30796609 - 0.07724354 * u2)));
}

float clipRamp(float d, float fade) {
    if (fade == 0.0) return clamp(d + 0.5, 0.0, 1.0);
    float t = clamp(d / abs(fade), 0.0, 1.0);
    return fade < 0.0 ? t : t*t*(3.0 - 2.0*t);
}

float maskAt(vec2 p) {
    vec4 clip = uSurface[4];
    vec4 hard = vec4(p - clip.xy, clip.zw - p);
    float mask = 1.0;
    for (int i = 0; i < 4; ++i) {
        float width = uSurface[10][i];
        float offset = uSurface[11][i];
        float edge = clipRamp(hard[i], width);
        if (offset >= 1.0) edge = clipRamp(hard[i], 0.0);
        else if (offset > 0.0) edge = min(clipRamp(hard[i], 0.0), clipRamp(hard[i] + offset * abs(width), width));
        mask *= edge;
    }
    if (any(notEqual(uSurface[12], vec4(0.0)))) {
        vec2 extent = (clip.zw - clip.xy) * 0.5;
        mask *= clamp(0.5 - boxDistance(p - clip.xy - extent, extent, uSurface[12]), 0.0, 1.0);
    }
    vec4 fade = uSurface[5];
    if (fade.z != 0.0) {
        float d = dot(p - uSurface[6].xy, fade.xy) * fade.z;
        mask *= mix(fade.w, 1.0, clamp(d, 0.0, 1.0));
    }
    vec4 node = uSurface[1];
    vec2 extent = node.zw * 0.5;
    return mask * clamp(0.5 - boxDistance(p - node.xy - extent, extent, uSurface[3]), 0.0, 1.0);
}

vec3 linearRGB(vec3 rgb, float transfer) {
    if (transfer > 1.5) return rgb;
    if (transfer > 0.5) return mix(pow((rgb + 0.099) / 1.099, vec3(1.0 / 0.45)), rgb / 4.5, lessThan(rgb, vec3(0.081)));
    return mix(pow((rgb + 0.055) / 1.055, vec3(2.4)), rgb / 12.92, lessThanEqual(rgb, vec3(0.04045)));
}

vec4 convertSample(vec4 plane0, vec2 plane1) {
    vec4 color = uSurface[7]; // native format, YCbCr matrix, transfer, opacity
    vec3 rgb = plane0.rgb;
    float alpha = plane0.a;
    if (color.x == 0.0) rgb = plane0.bgr; // byte layout BGRA
    else if (color.x < 2.5) {
        float y = plane0.r;
        vec2 cbcr = plane1 - 128.0/255.0;
        if (color.x < 1.5) {
            y = (y - 16.0/255.0) * (255.0/219.0);
            cbcr *= 255.0/224.0;
        }
        if (color.y > 0.5) rgb = vec3(y + 1.5748*cbcr.y, y - 0.187324*cbcr.x - 0.468124*cbcr.y, y + 1.8556*cbcr.x);
        else rgb = vec3(y + 1.402*cbcr.y, y - 0.344136*cbcr.x - 0.714136*cbcr.y, y + 1.772*cbcr.x);
        rgb = clamp(rgb, 0.0, 1.0);
        alpha = 1.0;
    }
    return vec4(linearRGB(rgb, color.z) * alpha, alpha);
}

void main() {
    vec2 p = vec2(gl_FragCoord.x, uSurface[0].y - gl_FragCoord.y) + uSurface[0].zw;
    vec4 image = uSurface[2];
    vec2 local = p - image.xy;
    if (any(lessThan(local, vec2(0.0))) || any(greaterThanEqual(local, image.zw))) discard;
    float mask = maskAt(p) * uSurface[7].w;
    if (mask <= 0.0) discard;
    if (uSurface[8].w > 0.5) local.x = image.z - local.x;
    vec4 orient = uSurface[9];
    mat2 matrix = mat2(orient.xz, orient.yw);
    vec2 size = abs(orient.xz) * image.z + abs(orient.yw) * image.w;
    vec2 bufferPixel = matrix * (local - image.zw * 0.5) + size * 0.5;
    bool nv12 = uSurface[7].x == 1.0 || uSurface[7].x == 2.0;
    vec4 texel = vec4(0.0);
    if (uSurface[8].x > 0.5) {
        ivec2 coord = clamp(ivec2(floor(bufferPixel)), ivec2(0), textureSize(uPlane0, 0) - 1);
        vec2 chroma = nv12 ? texelFetch(uPlane1, coord / 2, 0).rg : vec2(0.0);
        texel = convertSample(texelFetch(uPlane0, coord, 0), chroma);
    } else {
        vec2 divisor = max(size, vec2(1.0));
        vec2 uv = bufferPixel / divisor;
        ivec2 taps = clamp(ivec2(ceil(uSurface[8].yz / divisor)), ivec2(1), ivec2(8));
        for (int y = 0; y < taps.y; ++y) for (int x = 0; x < taps.x; ++x) {
            vec2 offset = ((vec2(x,y) + 0.5) / vec2(taps) - 0.5) / divisor;
            vec2 chroma = nv12 ? textureLod(uPlane1, uv + offset, 0.0).rg : vec2(0.0);
            texel += convertSample(textureLod(uPlane0, uv + offset, 0.0), chroma);
        }
        texel /= float(taps.x * taps.y);
    }
    fragColor = texel * mask;
}
