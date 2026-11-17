in vec2 uv;
out vec4 fragColor;
uniform sampler2D uTex0;

vec4 tap(float x, float y) {
    return textureLod(uTex0, uv + vec2(x, y) / vec2(textureSize(uTex0, 0)), 0.0);
}

void main() {
    vec4 corners = tap(-2.0, -2.0) + tap(2.0, -2.0) + tap(-2.0, 2.0) + tap(2.0, 2.0);
    vec4 cross = tap(0.0, -2.0) + tap(-2.0, 0.0) + tap(2.0, 0.0) + tap(0.0, 2.0);
    vec4 inner = tap(-1.0, -1.0) + tap(1.0, -1.0) + tap(-1.0, 1.0) + tap(1.0, 1.0);
    fragColor = corners / 32.0 + cross / 16.0 + (inner + tap(0.0, 0.0)) / 8.0;
}
