in vec2 uv;
out vec4 fragColor;
uniform sampler2D uTex0;
uniform sampler2D uTex1;
layout(std140) uniform RunePass { vec4 blend; };

vec4 tap(float x, float y) {
    return textureLod(uTex0, uv + vec2(x, y) / vec2(textureSize(uTex0, 0)), 0.0);
}

void main() {
    vec4 cross = tap(1.0, 0.0) + tap(-1.0, 0.0) + tap(0.0, 1.0) + tap(0.0, -1.0);
    vec4 corners = tap(-1.0, -1.0) + tap(1.0, -1.0) + tap(-1.0, 1.0) + tap(1.0, 1.0);
    vec4 coarse = (tap(0.0, 0.0) * 4.0 + cross * 2.0 + corners) / 16.0;
    fragColor = mix(textureLod(uTex1, uv, 0.0), coarse, blend.x);
}
