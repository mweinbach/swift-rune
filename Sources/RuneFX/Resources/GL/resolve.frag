in vec2 uv;
out vec4 fragColor;
uniform sampler2D uTex0;
layout(std140) uniform RunePass { vec4 options; };

void main() {
    vec4 c = textureLod(uTex0, uv, 0.0);
    if (options.x > 0.0) {
        vec3 linear = max(c.rgb, vec3(0.0));
        c.rgb = mix(1.055 * pow(linear, vec3(1.0 / 2.4)) - 0.055,
                    12.92 * linear, lessThanEqual(linear, vec3(0.0031308)));
    }
    fragColor = c;
}
