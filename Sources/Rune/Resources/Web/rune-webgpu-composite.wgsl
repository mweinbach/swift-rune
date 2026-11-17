// Prepend rune-clip.wgsl. Instance fields retain the same layout as RenderInstance.
struct Group {
    rect: vec4f, hole: vec4f, color: vec4f, pose: vec4f,
    params: vec4f, data: vec4f, clip: vec4f, fade: vec4u,
    destination: vec4f, source: vec4f,
};
@group(0) @binding(0) var<uniform> u: Group;
@group(0) @binding(1) var image: texture_2d<f32>;
@group(0) @binding(2) var sampling: sampler;

fn rotate(p: vec2f, angle: f32) -> vec2f {
    let v = p - u.pose.zw;
    return u.pose.zw + vec2f(cos(angle)*v.x - sin(angle)*v.y, sin(angle)*v.x + cos(angle)*v.y);
}

@vertex fn vs(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
    let corner = vec2f(f32(vi & 1u), f32(vi >> 1u));
    let fringe = u.source.zw / vec2f(textureDimensions(image));
    var p = u.source.xy - fringe + corner * (u.source.zw + 2.0 * fringe);
    if u.params.y == 13.0 {
        p = u.rect.xy - 1.0 + corner * (u.rect.zw + 2.0);
    } else if u.pose.y != 0.0 {
        p = rotate(p, u.pose.y);
    }
    let ndc = (p - u.destination.xy) / u.destination.zw * 2.0 - 1.0;
    return vec4f(ndc.x, -ndc.y, 0.0, 1.0);
}

@fragment fn fs(@builtin(position) position: vec4f) -> @location(0) vec4f {
    let p = position.xy + u.destination.xy;
    var coverage = clip_alpha(p, u.clip, u.fade) * clamp(u.color.a, 0.0, 1.0);
    if u.params.y == 13.0 {
        let half = u.rect.zw * 0.5;
        coverage *= clamp(0.5 - sd_rounded(p - u.rect.xy - half, half, u.hole), 0.0, 1.0);
        return textureSampleLevel(image, sampling, (p - u.source.xy) / u.source.zw, 0.0) * coverage;
    }
    if u.params.w < 0.5 && u.hole.w > 0.0 {
        let d = length(p - u.hole.xy) - (u.hole.z + u.hole.w) * 0.5;
        coverage *= clamp(d / max(u.hole.w - u.hole.z, 1.0) + 0.5, 0.0, 1.0);
    }
    var local = p;
    if u.pose.y != 0.0 { local = rotate(p, -u.pose.y); }
    let uv = (local - u.source.xy) / u.source.zw;
    let size = vec2f(textureDimensions(image));
    let edge = clamp(min(uv, 1.0 - uv) * size + 0.5, vec2f(0.0), vec2f(1.0));
    var color = textureSampleLevel(image, sampling, uv, 0.0);
    if u.params.x >= 0.5 { color = clamp(color, vec4f(0.0), vec4f(1.0)); }
    return color * (coverage * edge.x * edge.y);
}
