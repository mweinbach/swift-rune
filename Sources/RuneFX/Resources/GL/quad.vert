out vec2 uv;
void main() {
    uv = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
    gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}
