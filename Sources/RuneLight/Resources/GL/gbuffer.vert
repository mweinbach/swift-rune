// Unused block members are declared identically in both stages for GL program linking.
// The renderer prefixes this vertex stage with common.glsl.
flat out int primitiveID;
void main() {
    primitiveID = gl_InstanceID;
    vec4 rect = texelFetch(uTex0, ivec2(0, primitiveID), 0);
    vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
    vec2 p = rect.xy - 1.0 + corner * (rect.zw + 2.0);
    gl_Position = vec4(2.0 * p / F.sf.xy - 1.0, 0.0, 1.0);
}
