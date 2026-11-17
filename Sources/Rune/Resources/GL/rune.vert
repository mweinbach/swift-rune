// Instanced layout matches RuneRef.Primitive. Coordinates use Rune's top-left origin.
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
layout(location = 7) in vec4 aFade;
layout(location = 8) in vec4 aOriginTurn;

uniform vec2 uViewport;
flat out vec4 rect;
flat out vec4 radii;
flat out vec4 fillColor;
flat out vec4 border;
flat out vec4 params;
flat out vec4 uv;
flat out vec4 clipRect;
flat out vec4 fade;
flat out vec4 originTurn;

void main() {
    rect = aRect;
    radii = aRadii;
    fillColor = aFill;
    border = aBorder;
    params = aParams;
    uv = aUV;
    clipRect = aClip;
    fade = aFade;
    originTurn = aOriginTurn;

    vec2 halfSize = aRect.zw * 0.5;
    vec2 extent = halfSize + 2.0;
    if (aOriginTurn.z != 0.0) {
        float c = abs(cos(aOriginTurn.z));
        float s = abs(sin(aOriginTurn.z));
        extent = c * halfSize + s * halfSize.yx + 2.5;
    }
    vec2 corner = vec2((RUNE_VERTEX_ID & 1) != 0 ? 1.0 : -1.0,
                       (RUNE_VERTEX_ID & 2) != 0 ? 1.0 : -1.0);
    vec2 pixel = aRect.xy + halfSize + corner * extent;
    vec2 ndc = (pixel / uViewport * 2.0 - 1.0) * vec2(1.0, -1.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
}
