void main() {
    ivec2 b = ivec2(gl_FragCoord.xy) * 2;
    vec3 sum = texelFetch(uTex0, b, 0).rgb + texelFetch(uTex0, b + ivec2(1, 0), 0).rgb
             + texelFetch(uTex0, b + ivec2(0, 1), 0).rgb + texelFetch(uTex0, b + ivec2(1, 1), 0).rgb;
    result = vec4(sum * 0.25, 1.0);
}
