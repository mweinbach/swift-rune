#ifndef RUNE_VERTEX_ID
#define RUNE_VERTEX_ID gl_VertexID
#endif

// One triangle covers the target without an interior edge.
void main() {
    vec2 position = vec2((RUNE_VERTEX_ID << 1) & 2, RUNE_VERTEX_ID & 2);
    gl_Position = vec4(position * 2.0 - 1.0, 0.0, 1.0);
}
