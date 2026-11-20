// Solid rectangles and native-size A8 glyphs with hard rectangular clips.
#ifdef GL_ES
precision highp sampler2D;
#endif
uniform vec2 uViewport;
uniform vec2 uOrigin;
uniform int uSRGBBlend;
uniform int uInLayer;
uniform sampler2D uGlyphAtlas;
in vec2 vPoint;
flat in vec4 vRect;
flat in vec4 vRadii;
flat in vec4 vFill;
flat in vec4 vParams;
flat in vec4 vUV;
flat in vec4 vClip;
out vec4 outColor;

void main() {
    vec2 screen = vec2(gl_FragCoord.x, uViewport.y - gl_FragCoord.y) + uOrigin;
    vec4 edges = clamp(vec4(screen - vClip.xy, vClip.zw - screen) + 0.5, 0.0, 1.0);
    float clipAlpha = edges.x * edges.y * edges.z * edges.w;
    vec4 color;
    bool byteBlend;
    if (vParams.y == 0.0) {
        vec2 h = vRect.zw * 0.5;
        vec2 p = screen - (vRect.xy + h);
        float r = p.x > 0.0 ? (p.y > 0.0 ? vRadii.z : vRadii.y) : (p.y > 0.0 ? vRadii.w : vRadii.x);
        r = min(r, min(h.x, h.y));
        vec2 q = abs(p) - h + vec2(r);
        float d = min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
        color = vFill * clamp(0.5 - d / (max(vParams.z, 0.5) * 2.0), 0.0, 1.0);
        byteBlend = vFill.a > 0.0 && vFill.a < 1.0;
    } else {
        if (any(lessThan(screen, vRect.xy)) || any(greaterThanEqual(screen, vRect.xy + vRect.zw))) discard;
        ivec2 limit = textureSize(uGlyphAtlas, 0) - 1;
        ivec2 uv = clamp(ivec2(vUV.xy + floor(screen - vRect.xy)), ivec2(0), limit);
        float coverage = texelFetch(uGlyphAtlas, uv, 0).r;
        byteBlend = vParams.w >= 0.0;
        color = byteBlend ? vFill * pow(coverage, vParams.w) : vec4(roundEven(coverage * 255.0) / 255.0);
    }
    vec4 source = color * clipAlpha;
    if (uSRGBBlend != 0 && uInLayer == 0 && byteBlend) {
        source = roundEven(clamp(source, 0.0, 1.0) * 255.0) / 255.0;
    }
    outColor = uInLayer == 0 ? clamp(source, 0.0, 1.0) : source;
}
