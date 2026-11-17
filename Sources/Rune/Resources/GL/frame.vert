// Production RenderInstance. Its last attribute contains four packed UInt32s.
#ifndef RUNE_VERTEX_ID
#define RUNE_VERTEX_ID gl_VertexID
#endif
layout(location = 0) in vec4 aRect;
layout(location = 1) in vec4 aRadii;
layout(location = 2) in vec4 aFill;
layout(location = 3) in vec4 aBorder;
layout(location = 4) in vec4 aParams;
layout(location = 5) in vec4 aUV;
layout(location = 6) in vec4 aClip;
layout(location = 7) in uvec4 aFade;
uniform vec2 uViewport;
uniform vec2 uOrigin;
#ifdef RUNE_OUTLINE_VERTEX
uniform int uAtlasFill;
#endif

out vec2 vPoint;
flat out vec4 vRect;
flat out vec4 vRadii;
flat out vec4 vFill;
flat out vec4 vBorder;
flat out vec4 vParams;
flat out vec4 vUV;
flat out vec4 vClip;
flat out uvec4 vFade;

void main() {
    vRect = aRect;
    vRadii = aRadii;
    vFill = aFill;
    vBorder = aBorder;
    vUV = aUV;
    float kind = aParams.y;
#ifdef RUNE_FRAME_SPRINGS
    if (uSpringFirst >= 0) {
        int node = int(fetchSpringTexel(uSpringIDs, uSpringFirst + gl_InstanceID).x);
        vec2 offset = vec2(sampleSpringTrack(node * 9), sampleSpringTrack(node * 9 + 3));
        float alpha = clamp(sampleSpringTrack(node * 9 + 6), 0.0, 1.0);
        vRect.xy += offset;
        vFill *= alpha;
        if (kind != 7.0) vBorder *= alpha;
        if (kind == 4.0) vUV *= alpha;
        if (kind == 5.0 || kind == 6.0) vRadii += offset.xyxy;
        if (kind == 6.0) vUV.xy += offset;
    }
#endif
    float grow = 1.0 + aParams.z * 2.0;
    if (kind == 1.0) grow = aParams.z * 3.0 + 1.0;
    // At half-pixel origins the GL triangle edge rule covers the opposite row from Rune's top-down glyph rect.
    if (kind == 2.0) grow = 1.0;
    if (kind == 3.0 || (kind >= 5.0 && kind <= 9.0)) grow = 1.0;
    vec2 lo = vRect.xy - grow;
    vec2 hi = lo + vRect.zw + 2.0 * grow;
    if (kind < 1.5 && vUV.z < 0.0) {
        lo = max(lo, vRect.xy + vUV.xy);
        hi = max(lo, min(hi, vRect.xy + vec2(-vUV.z, vUV.w)));
    }
    vec2 corner = vec2(float(RUNE_VERTEX_ID & 1), float((RUNE_VERTEX_ID >> 1) & 1));
    vPoint = mix(lo, hi, corner);
    vec2 point = vPoint;
    if (kind == 2.0 && aParams.x != 0.0) {
        vec2 center = vRect.xy + vRect.zw * 0.5;
        vec2 q = point - center;
        float c = cos(aParams.x), s = sin(aParams.x);
        point = center + mat2(c, s, -s, c) * q;
    }
    gl_Position = vec4(((point - uOrigin) / uViewport * 2.0 - 1.0) * vec2(1.0, -1.0), 0.0, 1.0);
#ifdef RUNE_OUTLINE_VERTEX
    // Sampling uses GL row zero for the first atlas row, as glTex(Sub)Image2D does.
    if (uAtlasFill != 0) gl_Position.y = -gl_Position.y;
#endif
    vParams = aParams;
    vClip = aClip;
    vFade = aFade;
}
