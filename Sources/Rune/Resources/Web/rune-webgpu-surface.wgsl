// Swift Rune portable native surface uniforms use unpacked clip edges and radii.
struct Uniforms {
    viewport: vec4<f32>, node: vec4<f32>, image: vec4<f32>, radii: vec4<f32>,
    clip: vec4<f32>, fade: vec4<f32>, fadeOrigin: vec4<f32>, color: vec4<f32>, sampling: vec4<f32>, orient: vec4<f32>,
    widths: vec4<f32>, offsets: vec4<f32>, corners: vec4<f32>,
};
@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var plane0: texture_2d<f32>;
@group(0) @binding(2) var plane1: texture_2d<f32>;
@group(0) @binding(3) var filtering: sampler;
struct Out { @builtin(position) pos: vec4<f32> };
@vertex fn vs(@builtin(vertex_index) vi: u32) -> Out {
    let corner = vec2<f32>(f32(vi & 1u), f32(vi >> 1u));
    let p = u.node.xy + corner * u.node.zw;
    let local = p - u.viewport.zw;
    return Out(vec4<f32>(local.x / u.viewport.x * 2.0 - 1.0, 1.0 - local.y / u.viewport.y * 2.0, 0.0, 1.0));
}
fn linear(v: vec3<f32>) -> vec3<f32> {
    let x = clamp(v, vec3<f32>(0.0), vec3<f32>(1.0));
    if u.color.z > 1.5 { return x; }
    if u.color.z < 0.5 { return select(pow((x + 0.055) / 1.055, vec3<f32>(2.4)), x / 12.92, x <= vec3<f32>(0.04045)); }
    return select(pow((x + 0.099) / 1.099, vec3<f32>(1.0 / 0.45)), x / 4.5, x < vec3<f32>(0.081));
}
fn convert(a: vec4<f32>, uv: vec2<f32>) -> vec4<f32> {
    if u.color.x < 0.5 || u.color.x > 2.5 { return vec4<f32>(linear(a.rgb) * a.a, a.a); }
    var y = a.r;
    var c = uv - vec2<f32>(128.0 / 255.0);
    if u.color.x < 1.5 { y = (y - 16.0 / 255.0) * (255.0 / 219.0); c *= 255.0 / 224.0; }
    var kr = 0.299; var kb = 0.114;
    if u.color.y > 0.5 { kr = 0.2126; kb = 0.0722; }
    let r = y + 2.0 * (1.0 - kr) * c.y;
    let b = y + 2.0 * (1.0 - kb) * c.x;
    let g = (y - kr * r - kb * b) / (1.0 - kr - kb);
    return vec4<f32>(linear(vec3<f32>(r,g,b)), 1.0);
}
fn sample_linear(uv: vec2<f32>) -> vec4<f32> {
    return convert(textureSampleLevel(plane0, filtering, uv, 0.0), textureSampleLevel(plane1, filtering, uv, 0.0).rg);
}
@fragment fn fs(i: Out) -> @location(0) vec4<f32> {
    let p = i.pos.xy + u.viewport.zw;
    var local = p - u.image.xy;
    let unflipped = local / u.image.zw;
    if any(unflipped < vec2<f32>(0.0)) || any(unflipped >= vec2<f32>(1.0)) { discard; }
    // Mirror about the image centre: Fill crops stay centred and 1:1 texels stay exact.
    if u.sampling.w > 0.5 { local.x = u.image.z - local.x; }
    // Quarter turns and flips about the centre, into the buffer's (unrotated) image space.
    let m = mat2x2<f32>(u.orient.xz, u.orient.yw);
    let size = abs(u.orient.xz) * u.image.z + abs(u.orient.yw) * u.image.w;
    let buffer = m * (local - u.image.zw * 0.5) + size * 0.5;
    let uv = buffer / size;
    var col: vec4<f32>;
    if u.sampling.x > 0.5 {
        // Integer device-pixel origin + pixel-centre positions: no interpolation, even at Retina 2x.
        let texel = clamp(vec2<i32>(floor(buffer)), vec2(0), vec2<i32>(textureDimensions(plane0)) - 1);
        col = convert(textureLoad(plane0, texel, 0), textureLoad(plane1, texel / 2, 0).rg);
    } else {
        let ratio = u.sampling.yz / size;
        // Bounded area supersampling for large shrink ratios (up to 8x8 bilinear taps).
        // Convert each sample before accumulating so filtering is in linear light.
        let taps = vec2<i32>(clamp(ceil(ratio), vec2<f32>(1.0), vec2<f32>(8.0)));
        col = vec4<f32>(0.0);
        for (var y = 0; y < taps.y; y++) { for (var x = 0; x < taps.x; x++) {
            let offset = (vec2<f32>(f32(x)+0.5, f32(y)+0.5) / vec2<f32>(taps) - 0.5) / size;
            col += sample_linear(uv + offset);
        }}
        col /= f32(taps.x * taps.y);
    }
    let half = u.node.zw * 0.5;
    let distance = sd_rounded(p - u.node.xy - half, half, u.radii);
    let hard = vec4(p - u.clip.xy, u.clip.zw - p);
    var mask = clamp(0.5 - distance, 0.0, 1.0);
    for (var edge = 0u; edge < 4u; edge++) {
        let w = u.widths[edge]; let offset = u.offsets[edge]; let d = hard[edge];
        var a = ramp(d, w);
        if offset >= 1.0 { a = ramp(d, 0.0); }
        else if offset > 0.0 { a = min(ramp(d, 0.0), ramp(d + offset * abs(w), w)); }
        mask *= a;
    }
    if any(u.corners != vec4(0.0)) {
        let extent = (u.clip.zw - u.clip.xy) * 0.5;
        mask *= clamp(0.5 - sd_rounded(p - u.clip.xy - extent, extent, u.corners), 0.0, 1.0);
    }
    if u.fade.z != 0.0 {
        let d = dot(p - u.fadeOrigin.xy, u.fade.xy) * u.fade.z;
        mask *= mix(u.fade.w, 1.0, clamp(d, 0.0, 1.0));
    }
    return col * (mask * u.color.w);
}
