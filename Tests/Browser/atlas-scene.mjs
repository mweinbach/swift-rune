export const width = 8, height = 6;
export const viewWidth = 2 * width;

function quad(kind, x) {
    const words = new Float32Array(32);
    words.set([x, 0, width, height]);
    words.set([1, 1, 1, 1], 8);
    words.set([0, kind, 0, 1], 16);
    words.set([0, 0, width, height], 20);
    words.set([0, 0, viewWidth, height], 24);
    return words;
}

export const glyphs = new Uint8Array(width * height);
export const images = new Uint8Array(width * height * 4);
for (let y = 0; y < height; ++y) {
    for (let x = 0; x < width; ++x) {
        glyphs[y * width + x] = 16 + (x + 2 * y) * 8;
        images.set([x % 2 * 255, y % 2 * 255, 255, 255], (y * width + x) * 4);
    }
}

export function apply(pixels, channels, [x, y, w, h], patch) {
    for (let row = 0; row < h; ++row) {
        pixels.set(patch.subarray(row * w * channels, (row + 1) * w * channels), ((y + row) * width + x) * channels);
    }
}

const fullFlag = [2, 4], partialFlag = [8, 16];
export function scene(previous, next, glyph, image, srgbBlend = true) {
    const planes = [glyph, image];
    let flags = 32 | Number(srgbBlend);
    let size = 56 + 2 * 128 + 8;
    for (const [slot, plane] of planes.entries()) {
        if (!plane) continue;
        flags |= plane.rect ? partialFlag[slot] : fullFlag[slot];
        size += (plane.rect ? 16 : 0) + plane.data.byteLength;
    }
    const bytes = new Uint8Array(size);
    const data = new DataView(bytes.buffer);
    let offset = 0;
    function words(values) {
        for (const value of values) { data.setUint32(offset, value, true); offset += 4; }
    }
    words([0x32475352, viewWidth, height, flags, 2, width, height, width, height]);
    new Float32Array(bytes.buffer, offset, 4).set([0, 0, 0, 1]);
    offset += 16;
    words([0]); // Native surface count.
    for (const instance of [quad(2, 0), quad(7, width)]) {
        new Float32Array(bytes.buffer, offset, 32).set(instance);
        offset += 128;
    }
    words([previous, next]);
    for (const plane of planes) {
        if (!plane) continue;
        if (plane.rect) words(plane.rect);
        bytes.set(plane.data, offset);
        offset += plane.data.byteLength;
    }
    return bytes;
}
