float slab(vec4 f, float z) {
    float dz = max(z - f.z, f.y - z);
    vec2 a = vec2(f.x, dz);
    return length(max(a, vec2(0.0))) + min(max(a.x, a.y), 0.0);
}

float trace_shadow(
    vec3 P,
    vec3 L,
    float radius,
    float t_start,
    bool zcut
) {
    vec3 D = L - P;
    float dist = length(D);
    if (dist < 1e-3) {
        return 1.0;
    }
    vec3 rd = D / dist;
    float theta = max(radius / dist, 1e-3);
    float zmax = F.misc.x + 0.5;
    float t = t_start;
    float res = 1.0;
    float ph = 1e10;
    float t_end = dist - radius;
    for (int i = 0; i < 64; i += 1) {
        if (t >= t_end) {
            break;
        }
        vec3 q = P + rd * t;
        if (zcut && rd.z >= 0.0 && q.z > zmax) {
            break;
        }
        float h = slab(texture(uTex1, q.xy * F.gs.z / F.sf.zw), q.z);
        if (h <= 0.0) {
            res = min(res, h / (t * theta));
        } else {
            float y = h * h / (2.0 * ph);
            float dd = sqrt(max(h * h - y * y, 0.0));
            res = min(res, dd / (max(t - y, 1e-3) * theta));
        }
        ph = max(h, 1e-3);
        if (res <= -1.0) {
            break;
        }
        t = t + clamp(abs(h), 0.6 + t * 0.012, 96.0);
    }
    float k = clamp(0.5 + 0.5 * res, 0.0, 1.0);
    return k * k * (3.0 - 2.0 * k);
}

float shaft(vec2 p, Light L) {
    vec2 D = L.pos.xy - p;
    float len = length(D);
    float R = max(L.pos.w * L.extra.w, 1.0);
    const int n = 48;
    float strideLength = len / float(n);
    float w = max(strideLength * 0.6, 2.0);
    float acc = 0.0;
    for (int i = 0; i < n; i += 1) {
        vec2 q = p + D * ((float(i) + 0.5) / float(n));
        float open = w_smoothstep(-w, w, texture(uTex1, q * F.gs.z / F.sf.zw).x);
        float r = length(L.pos.xy - q);
        acc = acc + open * R * R / (r * r + R * R);
    }
    return acc / float(n);
}


// Visibility (and, when enabled, shafts) are packed in horizontal bands of four light channels.
void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    int band = pixel.y / int(F.sf.w);
    int groups = max(1, (int(F.counts.y) + 3) / 4);
    bool air = band >= groups;
    int first = (band % groups) * 4;
    vec2 p = (vec2(pixel.x, pixel.y % int(F.sf.w)) + 0.5) / F.gs.z;
    ivec2 gbufferPixel = clamp(ivec2(p), ivec2(0), ivec2(F.sf.xy) - 1);
    vec3 P = vec3(p, texelFetch(uTex2, gbufferPixel, 0).w + 0.35);
    result = vec4(1.0);
    for (int i = 0; i < 4 && first + i < int(F.counts.y); ++i) {
        Light light = F.lights[first + i];
        if (air) {
            if (light.extra.x > 0.0) result[i] = shaft(p, light);
        } else if (light.pos.z > P.z && light_term(light, P).w > 1e-5) {
            result[i] = trace_shadow(P, light.pos.xyz, light.pos.w * light.extra.w, 0.75, true);
        }
    }
}
