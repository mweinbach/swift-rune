const stride = 128;
const headerBytes = 56;

const surfaceHeaderBytes = 40;
const surfaceUniformBytes = 13 * 16;
const surfaceRecordBytes = surfaceHeaderBytes + surfaceUniformBytes;

// The preceding R8 image can end on any byte. Only aligned packet views can be
// read directly as Float32Array; plane data never needs realignment.
export function decodeWebSurfaces(memory, offset, end, count) {
    if (end > memory.byteLength || offset > end || count > (end - offset) / surfaceRecordBytes) {
        throw new Error('Invalid Rune surface packet length');
    }
    const view = new DataView(memory);
    const draws = [];
    for (let i = 0; i < count; i++) {
        if (end - offset < surfaceRecordBytes) throw new Error('Truncated Rune surface descriptor');
        const word = index => view.getUint32(offset + index * 4, true);
        const id = index => (BigInt(word(index + 1)) << 32n) | BigInt(word(index));
        const before = word(0), key = id(1), revision = id(3);
        const width = word(5), height = word(6), format = word(7);
        const firstLength = word(8), secondLength = word(9);
        const packed = format === 0 || format === 3;
        if (width < 1 || height < 1 || width > 16384 || height > 16384 || format > 3
            || (!packed && ((width | height) & 1))) throw new Error('Invalid Rune surface dimensions or format');
        if (firstLength || secondLength) {
            const pixels = width * height;
            if (firstLength !== pixels * (packed ? 4 : 1) || secondLength !== (packed ? 0 : pixels / 2)) {
                throw new Error('Invalid Rune surface plane dimensions');
            }
        }
        if (firstLength + secondLength > end - offset - surfaceRecordBytes) {
            throw new Error('Truncated Rune surface planes');
        }
        if (i > 0 && before < draws[i - 1].before) throw new Error('Unordered Rune surface draws');
        const start = offset + surfaceHeaderBytes;
        const uniforms = start % 4 === 0
            ? new Float32Array(memory, start, 52)
            : new Float32Array(new Uint8Array(memory, start, surfaceUniformBytes).slice().buffer);
        offset += surfaceRecordBytes;
        const primary = new Uint8Array(memory, offset, firstLength);
        offset += firstLength;
        const chroma = new Uint8Array(memory, offset, secondLength);
        offset += secondLength;
        draws.push({ before, key, revision, width, height, format, uniforms, primary, chroma });
    }
    if (offset !== end) throw new Error('Trailing data after Rune surface draws');
    return draws;
}

// Validate the full RSG2/RSG3 envelope before either graphics API consumes its zero-copy views.
export function decodeRuneScene(memory, pointer, length, maxSize, atlasSequence) {
    if (length < headerBytes || pointer % 4) throw new Error('Invalid Rune scene header');
    const h = new Uint32Array(memory, pointer, headerBytes / 4);
    const paged = h[0] === 0x33475352;
    if (!paged && h[0] !== 0x32475352) throw new Error('Unsupported Rune GPU scene format');
    const [, width, height, flags, count, gw, gh, iw, ih] = h;
    if (paged && (!iw || ih || !(flags & 32) || (flags & 20))) throw new Error('Invalid Rune paged scene header');
    const pagedGlyphs = paged && !!(flags & 128);
    if (pagedGlyphs && (!gw || gh || (flags & 10))) throw new Error('Invalid Rune glyph page header');
    const dimensions = pagedGlyphs ? [width, height] : paged ? [width, height, gw, gh] : [width, height, gw, gh, iw, ih];
    if (dimensions.some(n => !n || n > maxSize)) {
        throw new Error(`Rune scene exceeds GPU texture limits (${maxSize})`);
    }
    const primitiveBytes = count * stride;
    let offset = headerBytes + primitiveBytes;
    if (length < offset) throw new Error('Invalid Rune scene length');
    const packet = new DataView(memory, pointer, length);
    let sequence, previous, duplicate = false;
    if (flags & 32) {
        previous = packet.getUint32(offset, true);
        sequence = packet.getUint32(offset + 4, true);
        offset += 8;
        duplicate = sequence === atlasSequence;
    }
    function readAtlas(width, height, channels, bits, fullFlag, patchFlag) {
        const full = !!(bits & fullFlag);
        let x = 0, y = 0, w = width, h = height;
        if (bits & patchFlag) {
            if (full || sequence === undefined) throw new Error('Invalid Rune atlas flags');
            x = packet.getUint32(offset, true);
            y = packet.getUint32(offset + 4, true);
            w = packet.getUint32(offset + 8, true);
            h = packet.getUint32(offset + 12, true);
            offset += 16;
            if (!w || !h || x + w > width || y + h > height) throw new Error('Rune atlas patch exceeds its texture');
        } else if (!full) { return null; }
        const size = w * h * channels;
        if (size > length - offset) throw new Error('Truncated Rune atlas data');
        const data = new Uint8Array(memory, pointer + offset, size);
        offset += size;
        return { full, x, y, width: w, height: h, data };
    }
    function readPages(count, channels) {
        if (count > (length - offset) / 12) throw new Error('Truncated Rune texture page descriptors');
        const pages = [];
        for (let index = 0; index < count; index++) {
            if (length - offset < 12) throw new Error('Truncated Rune texture page descriptor');
            const width = packet.getUint32(offset, true), height = packet.getUint32(offset + 4, true);
            const bits = packet.getUint32(offset + 8, true);
            offset += 12;
            if (width > maxSize || height > maxSize || (!width !== !height) || bits > 2 || (!width && bits)) {
                throw new Error('Invalid Rune texture page geometry');
            }
            pages.push({width, height, update: readAtlas(width, height, channels, bits, 1, 2)});
        }
        return pages;
    }
    const glyphPages = pagedGlyphs ? readPages(gw, 1)
        : [{width: gw, height: gh, update: readAtlas(gw, gh, 1, flags, 2, 8)}];
    const imagePages = paged ? readPages(iw, 4)
        : [{width: iw, height: ih, update: readAtlas(iw, ih, 4, flags, 4, 16)}];
    const glyphs = glyphPages[0].update;
    const fullyUploaded = page => !page.width || page.update?.full;
    const full = glyphPages.every(fullyUploaded) && imagePages.every(fullyUploaded);
    if (sequence !== undefined && !duplicate && !full && previous !== atlasSequence) {
        throw new Error('Rune atlas patch requires its matching resident scene');
    }
    const images = imagePages[0].update;
    const surfaces = decodeWebSurfaces(memory, pointer + offset, pointer + length, h[13]);
    const clear = new Float32Array(memory, pointer + 36, 4);
    const instances = new Float32Array(memory, pointer + headerBytes, count * 32);
    return {width, height, count, glyphWidth: glyphPages[0].width, glyphHeight: glyphPages[0].height, glyphPages, imageWidth: imagePages[0].width, imageHeight: imagePages[0].height, imagePages, paged,
        sequence, duplicate, glyphs, images, surfaces, clear, instances, srgbBlend: !!(flags & 1)};
}

// Plain primitives inherit the current binding. Base glyphs can use any image binding.
// A secondary glyph page or a new image page changes the pair as in Renderer::batch.
export function forEachAtlasPageRun(instances, first, count, imageCount, glyphCount, emit) {
    if (!count) return;
    const resolve = (raw, size) => {
        const page = Math.max(0, Math.trunc(raw));
        return page < size ? page : -1;
    };
    let begin = first, image = 0, glyph = 0;
    const end = first + count;
    for (let i = first; i < end; i++) {
        const offset = i * 32 + 16;
        const kind = instances[offset + 1];
        let nextImage = image, nextGlyph = glyph;
        if (kind === 7) {
            nextImage = resolve(instances[offset], imageCount);
            nextGlyph = 0;
        } else if (kind === 2) {
            const requested = resolve(instances[offset + 2], glyphCount);
            // Both root and offscreen Rust targets fall back to the base glyph bind.
            nextGlyph = requested < 0 ? 0 : requested;
            if (requested !== 0 || glyph !== 0) nextImage = 0;
        } else continue;
        if (nextImage === image && nextGlyph === glyph) continue;
        if (begin < i) emit(begin, i - begin, image, glyph);
        begin = i;
        image = nextImage;
        glyph = nextGlyph;
    }
    emit(begin, end - begin, image, glyph);
}
