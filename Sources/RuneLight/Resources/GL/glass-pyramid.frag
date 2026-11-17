uniform sampler2D uTex0;
layout(std140) uniform RunePass { vec4 size; };
out vec4 result;
void main() {
    vec2 sz = vec2(textureSize(uTex0, 0));
    vec2 uv = vec2(gl_FragCoord.x * 2.0 / sz.x, 1.0 - (size.y - gl_FragCoord.y) * 2.0 / sz.y);
    vec2 t = 1.0 / sz;
    vec3 a = texture(uTex0, uv + t * vec2(-2.0, -2.0)).rgb;
    vec3 b = texture(uTex0, uv + t * vec2(0.0, -2.0)).rgb;
    vec3 c = texture(uTex0, uv + t * vec2(2.0, -2.0)).rgb;
    vec3 d = texture(uTex0, uv + t * vec2(-2.0, 0.0)).rgb;
    vec3 e = texture(uTex0, uv).rgb;
    vec3 f = texture(uTex0, uv + t * vec2(2.0, 0.0)).rgb;
    vec3 g = texture(uTex0, uv + t * vec2(-2.0, 2.0)).rgb;
    vec3 h = texture(uTex0, uv + t * vec2(0.0, 2.0)).rgb;
    vec3 i = texture(uTex0, uv + t * vec2(2.0, 2.0)).rgb;
    vec3 j = texture(uTex0, uv + t * vec2(-1.0, -1.0)).rgb;
    vec3 k = texture(uTex0, uv + t * vec2(1.0, -1.0)).rgb;
    vec3 l = texture(uTex0, uv + t * vec2(-1.0, 1.0)).rgb;
    vec3 m = texture(uTex0, uv + t * vec2(1.0, 1.0)).rgb;
    vec3 o = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
    result = vec4(o, 1.0);
}
