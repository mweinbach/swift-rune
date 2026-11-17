// FS_PASS specializes this shader for each step of Rune's stable-fluids solver.
#ifdef GL_ES
precision highp sampler2D;
#endif
layout(std140) uniform RunePass {
    vec4 dims;       // grid size, cell size in points, time step
    vec4 origin;     // top-left in points, simulation time, reset
    vec4 shape;      // emitter center and half extent
    vec4 shape2;     // corner radius, seed, rise, scale
    vec4 fire;       // buoyancy, cooling, smoke generation, vorticity
    vec4 fire2;      // sway, speed, smoke dissipation, fuel depth
};
uniform sampler2D uTex0;
uniform sampler2D uTex1;
out vec4 result;

// Boundary conditions live in Rune's top-left coordinate space. Framebuffer row 0 is at the bottom.
ivec2 cellOf(ivec2 pixel) { return ivec2(pixel.x, int(dims.y) - 1 - pixel.y); }
vec4 field(sampler2D source, ivec2 cell) {
    return texelFetch(source, cellOf(clamp(cell, ivec2(0), ivec2(dims.xy) - 1)), 0);
}
vec4 previousState(ivec2 c) { return origin.w > 0.5 ? vec4(0.0) : field(uTex0, c); }
vec2 positionOf(ivec2 c) { return origin.xy + (vec2(c) + 0.5) * dims.z; }
float distanceToShape(vec2 p) {
    float radius = min(shape2.x, min(shape.z, shape.w));
    vec2 q = abs(p - shape.xy) - shape.zw + radius;
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}
bool solid(ivec2 c) { return distanceToShape(positionOf(c)) < -fire2.w - 1.0; }
const ivec2 dx = ivec2(1, 0), dy = ivec2(0, 1);

uint pcg(uint v) {
    uint s = v * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
float hashCell(ivec2 c, uint seed) {
    return float(pcg(uint(c.x) ^ pcg(uint(c.y) ^ pcg(seed))) >> 8u) * (1.0 / 16777216.0);
}
float noiseValue(vec2 p, uint seed) {
    ivec2 i = ivec2(floor(p));
    vec2 f = fract(p);
    vec2 w = f * f * (3.0 - 2.0 * f);
    return mix(mix(hashCell(i, seed), hashCell(i + dx, seed), w.x),
               mix(hashCell(i + dy, seed), hashCell(i + dx + dy, seed), w.x), w.y) * 2.0 - 1.0;
}
float emission(float x) {
    float t = origin.z;
    uint seed = uint(shape2.y);
    float spacing = max(shape2.w * 0.32, 3.5);
    float slow = noiseValue(vec2(x / spacing, t * 0.55 * fire2.y), seed) * 0.7
               + noiseValue(vec2(x / spacing * 2.3 + 5.1, t * 1.1 * fire2.y), seed + 1u) * 0.3;
    float fast = noiseValue(vec2(x / spacing * 1.7 + 11.0, t * 6.0 * fire2.y), seed + 2u);
    float radius = min(shape2.x, min(shape.z, shape.w));
    float edge = abs(x - shape.x);
    float ends = radius > 0.0 ? 1.0 - smoothstep(shape.z - radius * 1.6, shape.z - radius * 0.35, edge)
                              : (edge < shape.z ? 1.0 : 0.0);
    return smoothstep(-0.1, 0.4, slow + 0.25 * fast) * ends;
}
float fuelBand(vec2 p) {
    float d = distanceToShape(p);
    vec2 offset = vec2(0.5 * dims.z, 0.0);
    vec2 gradient = vec2(distanceToShape(p + offset) - distanceToShape(p - offset),
                         distanceToShape(p + offset.yx) - distanceToShape(p - offset.yx));
    float up = clamp(-gradient.y / max(length(gradient), 1e-4), 0.0, 1.0);
    return smoothstep(-fire2.w - 1.5, -fire2.w + 0.5, d)
         * (1.0 - smoothstep(0.0, dims.z + 1.5, d)) * smoothstep(0.35, 0.8, up);
}

float pressure(sampler2D source, ivec2 c, float center) {
    if (c.y < 0) return 0.0;
    if (c.x < 0 || c.x >= int(dims.x) || c.y >= int(dims.y) || solid(c)) return center;
    return field(source, c).r;
}
vec4 cubicWeights(float t) {
    float t2 = t * t, t3 = t2 * t;
    return vec4(-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1.0,
                -1.5 * t3 + 2.0 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2);
}
vec4 sampleCubic(vec2 p) {
    vec2 g = (p - origin.xy) / dims.z - 0.5;
    ivec2 base = ivec2(floor(g));
    vec4 wx = cubicWeights(fract(g.x)), wy = cubicWeights(fract(g.y));
    vec4 acc = vec4(0.0);
    for (int y = 0; y < 4; ++y) {
        vec4 row = vec4(0.0);
        for (int x = 0; x < 4; ++x) row += wx[x] * field(uTex0, base + ivec2(x - 1, y - 1));
        acc += wy[y] * row;
    }
    vec4 a = field(uTex0, base), b = field(uTex0, base + dx);
    vec4 c = field(uTex0, base + dy), d = field(uTex0, base + dx + dy);
    return clamp(acc, min(min(a, b), min(c, d)), max(max(a, b), max(c, d)));
}

void main() {
    ivec2 c = cellOf(ivec2(gl_FragCoord.xy));
    float h = dims.z, dt = dims.w;
#if FS_PASS == 0 // Curl
    float curl = (previousState(c + dx).y - previousState(c - dx).y
                - previousState(c + dy).x + previousState(c - dy).x) / (2.0 * h);
    result = vec4(curl, 0.0, 0.0, 0.0);
#elif FS_PASS == 1 // Forces, fuel injection and cooling
    vec4 state = previousState(c);
    vec2 v = state.xy;
    float heat = state.z, smoke = state.w;
    vec2 p = positionOf(c);
    float above = shape.y - shape.w - p.y;
    v.y -= dt * (fire.x * heat - fire.x * 0.12 * smoke);
    if (origin.w < 0.5) {
        vec2 gradient = vec2(abs(field(uTex1, c + dx).r) - abs(field(uTex1, c - dx).r),
                             abs(field(uTex1, c + dy).r) - abs(field(uTex1, c - dy).r)) / (2.0 * h);
        float magnitude = length(gradient);
        if (magnitude > 1e-4) {
            gradient /= magnitude;
            float lift = clamp(above / max(shape2.z * 0.4, 8.0), 0.15, 1.0);
            v += dt * fire.w * lift * h * vec2(gradient.y, -gradient.x) * field(uTex1, c).r;
        }
    }
    float t = origin.z;
    uint seed = uint(shape2.y);
    float sway = noiseValue(vec2(p.x / 90.0, t * 0.35 * fire2.y), seed + 9u)
               + 0.5 * noiseValue(vec2(p.x / 30.0 + 3.0, p.y / 40.0 - t * 0.9 * fire2.y), seed + 10u);
    v.x += dt * fire2.x * sway * clamp(above / 40.0, 0.0, 1.0);
    float band = fuelBand(p);
    if (band > 0.0) {
        float e = emission(p.x) * band;
        heat = max(heat, e * (0.95 + 0.25 * noiseValue(vec2(p.x / 3.0, t * 9.0), seed + 4u)));
        v.y = mix(v.y, -shape2.z * (0.6 + 0.6 * e), e * 0.6);
    }
    float lost = heat * (1.0 - exp(-dt * fire.y));
    heat -= lost;
    smoke += lost * fire.z * (1.0 - smoothstep(0.25, 0.55, heat));
    smoke *= exp(-dt * fire2.z);
    if (solid(c)) { v = vec2(0.0); heat *= 0.5; smoke = 0.0; }
    v.x *= exp(-dt * 7.0 * smoothstep(0.1, 0.6, heat));
    float fade = smoothstep(0.0, 4.0, min(min(float(c.x), dims.x - 1.0 - float(c.x)), float(c.y)));
    result = vec4(v, heat * fade, smoke * fade);
#elif FS_PASS == 2 // Divergence
    float l = solid(c - dx) ? 0.0 : field(uTex0, c - dx).x;
    float r = solid(c + dx) ? 0.0 : field(uTex0, c + dx).x;
    float t = solid(c - dy) ? 0.0 : field(uTex0, c - dy).y;
    float b = solid(c + dy) ? 0.0 : field(uTex0, c + dy).y;
    vec2 p = positionOf(c);
    float src = fuelBand(p) * emission(p.x) * shape2.z * 0.2 / h;
    result = vec4((r - l + b - t) / (2.0 * h) - src, 0.0, 0.0, 0.0);
#elif FS_PASS == 3 // Jacobi pressure iteration
    float pc = field(uTex0, c).r;
    float sum = pressure(uTex0, c - dx, pc) + pressure(uTex0, c + dx, pc)
              + pressure(uTex0, c - dy, pc) + pressure(uTex0, c + dy, pc);
    result = vec4((sum - h * h * field(uTex1, c).r) * 0.25, 0.0, 0.0, 0.0);
#elif FS_PASS == 4 // Remove pressure gradient
    vec4 state = field(uTex0, c);
    float pc = field(uTex1, c).r;
    vec2 gradient = vec2(pressure(uTex1, c + dx, pc) - pressure(uTex1, c - dx, pc),
                         pressure(uTex1, c + dy, pc) - pressure(uTex1, c - dy, pc)) / (2.0 * h);
    vec2 v = solid(c) ? vec2(0.0) : state.xy - gradient;
    float speed = length(v), limit = 2.0 * h / dt;
    if (speed > limit) v *= limit / speed;
    result = vec4(v, state.zw);
#else // Advect by midpoint backtracing with a monotone cubic sampler
    vec2 p = positionOf(c);
    vec2 mid = p - 0.5 * dt * field(uTex0, c).xy;
    vec4 advected = sampleCubic(p - dt * sampleCubic(mid).xy);
    result = vec4(advected.xy, max(advected.zw, vec2(0.0)));
#endif
}
