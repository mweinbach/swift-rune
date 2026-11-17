// Surface uniforms are shared with the fragment shader. Rune positions are top-left, in pixels.
#ifndef RUNE_VERTEX_ID
#define RUNE_VERTEX_ID gl_VertexID
#endif
uniform vec4 uSurface[13];
void main() {
    vec2 corner = vec2(RUNE_VERTEX_ID & 1, (RUNE_VERTEX_ID >> 1) & 1);
    vec2 pixel = uSurface[1].xy + corner * uSurface[1].zw;
    gl_Position = vec4(((pixel - uSurface[0].zw) / uSurface[0].xy * 2.0 - 1.0) * vec2(1.0, -1.0), 0.0, 1.0);
}
