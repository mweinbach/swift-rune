const width = 32, height = 16, clip = [0, 0, width, height];
function instance(kind, rect, color, crop = clip) {
    const p = new Float32Array(32);
    p.set(rect);
    p.set(color, 8);
    p[17] = kind;
    p.set(crop, 24);
    return p;
}
const layer = instance(8, [0, 0, 18, 16], [0, 0, 0, 0.5], [2, 2, 18, 13]);
layer[16] = 1; // Additive group. Both geometry and surface draws contribute.
layer[31] = 3; // Packed uniform clip radius, float bit pattern.
const instances = [
    instance(0, clip, [1, 0, 0, 1]), layer,
    instance(0, [0, 0, 18, 16], [0, 0.5, 0, 0.5]),
    instance(0, [8, 4, 3, 6], [1, 1, 1, 1]),
    instance(9, clip, [0, 0, 0, 0])
];
function surface(before, key, revision, rect, format, primary, chroma = []) {
    const planes = new Uint8Array(248 + primary.length + chroma.length);
    const header = new Uint32Array(planes.buffer, 0, 10);
    header.set([before, key, 1, revision, 0, 2, 2, format, primary.length, chroma.length]);
    const uniforms = new Float32Array(planes.buffer, 40, 52);
    uniforms.set([width, height, 0, 0]);
    uniforms.set(rect, 4);
    uniforms.set(rect, 8);
    uniforms.set(clip, 16);
    uniforms.set([format, 1, 2, 1], 28);
    uniforms.set([0, 2, 2, 0], 32);
    uniforms.set([1, 0, 0, 1], 36);
    planes.set(primary, 248);
    planes.set(chroma, 248 + primary.length);
    return planes;
}
function packet(index) {
    const initial = index === 0, replaced = index === 2;
    const pixel = replaced ? [0, 255, 0, 128] : [255, 0, 0, 128];
    const revision = replaced ? 2 : 1;
    const surfaces = [
        surface(3, 1, revision, [0, 0, 18, 16], 0, initial || replaced ? Array(4).fill(pixel).flat() : []),
        surface(5, 1, revision, [19, 1, 6, 7], 0, []),
        surface(0xffffffff, 2, 1, [24, 8, 8, 8], 2, initial ? [128, 128, 128, 128] : [], initial ? [128, 128] : [])
    ];
    const atlases = initial ? [0, 255, 255, 255, 255] : [];
    const bytes = new Uint8Array(56 + instances.length * 128 + atlases.length + surfaces.reduce((s, p) => s + p.length, 0));
    const header = new Uint32Array(bytes.buffer, 0, 14);
    header.set([0x32475352, width, height, initial ? 7 : 1, instances.length, 1, 1, 1, 1]);
    new Float32Array(bytes.buffer, 36, 4).set([0, 0, 0, 1]);
    header[13] = surfaces.length;
    let offset = 56;
    for (const p of instances) {
        bytes.set(new Uint8Array(p.buffer), offset);
        offset += 128;
    }
    bytes.set(atlases, offset);
    offset += atlases.length;
    for (const s of surfaces) {
        bytes.set(s, offset);
        offset += s.length;
    }
    return bytes;
}
export { width, height, clip, instance, surface, packet };
