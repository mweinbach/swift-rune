// RSG3 fixture. R8 glyph data deliberately misaligns the first tightly packed page header.
export function pagedPacket({width, height, instances, pages, previous = 0, sequence = 1, glyphs = null, glyphPages = null}) {
    let length = 56 + instances.length * 128 + 8 + (glyphs?.length ?? 0);
    const descriptors = glyphPages ? [...glyphPages, ...pages] : pages;
    for (const page of descriptors) length += 12 + (page.rect ? 16 : 0) + (page.data?.length ?? 0);
    const bytes = new Uint8Array(length);
    const view = new DataView(bytes.buffer);
    let offset = 0;
    const word = value => { view.setUint32(offset, value, true); offset += 4; };
    const append = data => { bytes.set(data, offset); offset += data.length; };
    [0x33475352, width, height, 33 | (glyphs ? 2 : 0) | (glyphPages ? 128 : 0), instances.length, glyphPages?.length ?? 1, glyphPages ? 0 : 1, pages.length, 0].forEach(word);
    [0, 0, 0, 1].forEach(value => {view.setFloat32(offset, value, true); offset += 4;});
    word(0);
    for (const instance of instances) append(new Uint8Array(instance.buffer, instance.byteOffset, 128));
    word(previous); word(sequence);
    if (glyphs) append(glyphs);
    for (const p of descriptors) {
        word(p.width); word(p.height); word(p.rect ? 2 : p.data ? 1 : 0);
        p.rect?.forEach(word);
        if (p.data) append(p.data);
    }
    return bytes;
}
