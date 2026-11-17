out vec2 runePixel;
void main() {
    vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
    runePixel = mix(fxInstance.bounds.xy, fxInstance.bounds.zw, corner);
    vec2 ndc = runePixel / fxGlobals.viewport * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
}
