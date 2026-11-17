// Split animated containers into single-frame images for the browser's static codecs.
// Compositing stays in logical canvas coordinates. Only the currently requested patch
// is copied into a Blob, including when Rune retains just the first frame.
const transparent = [0, 0, 0, 0];
const ascii = (bytes, at, length) => String.fromCharCode(...bytes.subarray(at, at + length));
const u16 = (bytes, at) => bytes[at] | bytes[at + 1] << 8;
const u24 = (bytes, at) => u16(bytes, at) | bytes[at + 2] << 16;

function ensure(condition, section) {
    if (!condition) throw Error(`Malformed ${section}`);
}

function exifOrientation(bytes) {
    // WebP stores the TIFF directory directly or after the six-byte EXIF identifier.
    const start = ascii(bytes, 0, 6) === 'Exif\0\0' ? 6 : 0;
    if (bytes.length < start + 8) return 1;
    const tiff = new DataView(bytes.buffer, bytes.byteOffset + start, bytes.length - start);
    const order = tiff.getUint16(0), little = order === 0x4949;
    if ((!little && order !== 0x4d4d) || tiff.getUint16(2, little) !== 42) return 1;
    let pos = tiff.getUint32(4, little);
    if (pos < 8 || pos + 2 > tiff.byteLength) return 1;
    const count = tiff.getUint16(pos, little);
    pos += 2;
    for (let i = 0; i < count && pos + 12 <= tiff.byteLength; i++, pos += 12) {
        if (tiff.getUint16(pos, little) === 0x112 && tiff.getUint16(pos + 2, little) === 3 &&
            tiff.getUint32(pos + 4, little) === 1) {
            const value = tiff.getUint16(pos + 8, little);
            return value >= 1 && value <= 8 ? value : 1;
        }
    }
    return 1;
}

function gifAnimation(bytes) {
    const n = bytes.length;
    ensure(n >= 13 && ['GIF87a', 'GIF89a'].includes(ascii(bytes, 0, 6)), 'GIF header');
    const width = u16(bytes, 6), height = u16(bytes, 8);
    ensure(width > 0 && height > 0 && width <= 8192 && height <= 8192, 'GIF canvas');
    const tableSize = packed => packed & 128 ? 3 << ((packed & 7) + 1) : 0;
    const globalSize = tableSize(bytes[10]), start = 13 + globalSize;
    ensure(start <= n, 'GIF global palette');
    let plays = 1, frameCount = 0, profile;

    function* read(makeImages) {
        let pos = start, control = null;
        while (pos < n) {
            const marker = bytes[pos++];
            if (marker === 0x3b) return;
            if (marker === 0x21) {
                ensure(pos + 1 < n, 'GIF extension');
                const extension = pos - 1, label = bytes[pos++];
                let loop = false, colorProfile = false, first = true;
                for (;;) {
                    ensure(pos < n, 'GIF extension terminator');
                    const size = bytes[pos++];
                    if (size === 0) break;
                    ensure(pos + size <= n, 'GIF extension data');
                    if (first && label === 0xf9) {
                        ensure(size === 4, 'GIF graphic control');
                        control = pos;
                    } else if (first && label === 0xff && size === 11) {
                        const app = ascii(bytes, pos, size);
                        loop = app === 'NETSCAPE2.0' || app === 'ANIMEXTS1.0';
                        colorProfile = app === 'ICCRGBG1012';
                    } else if (loop && size >= 3 && bytes[pos] === 1 && !makeImages) {
                        const repeats = u16(bytes, pos + 1);
                        plays = repeats ? repeats + 1 : 0;
                    }
                    pos += size;
                    first = false;
                }
                if (colorProfile && !makeImages) profile = bytes.subarray(extension, pos);
                if (label === 1) control = null; // Plain Text consumes the preceding GCE too.
                continue;
            }
            ensure(marker === 0x2c && pos + 9 <= n, 'GIF image descriptor');
            const x = u16(bytes, pos), y = u16(bytes, pos + 2);
            const w = u16(bytes, pos + 4), h = u16(bytes, pos + 6), flags = bytes[pos + 8];
            ensure(w > 0 && h > 0 && x + w <= width && y + h <= height, 'GIF frame bounds');
            pos += 9;
            const localSize = tableSize(flags), palette = localSize ? pos : 13;
            const paletteSize = localSize || globalSize;
            ensure(paletteSize && pos + localSize < n, 'GIF frame palette');
            pos += localSize;
            const data = pos++; // LZW minimum code size, then length-prefixed sub-blocks.
            for (;;) {
                ensure(pos < n, 'GIF image terminator');
                const size = bytes[pos++];
                if (size === 0) break;
                ensure(pos + size <= n, 'GIF LZW sub-block');
                pos += size;
            }
            const packed = control === null ? 0 : bytes[control];
            if (makeImages) {
                const delay = control === null ? 0.1 : u16(bytes, control + 1) / 100;
                const transparentIndex = control === null ? 0 : bytes[control + 3];
                const tableFlags = localSize ? flags : bytes[10];
                const header = Uint8Array.of(71, 73, 70, 56, 57, 97, w, w >> 8, h, h >> 8,
                    0xf0 | (tableFlags & 7), transparentIndex, 0);
                const gce = Uint8Array.of(0x21, 0xf9, 4, packed & 1, 0, 0, transparentIndex, 0);
                const descriptor = Uint8Array.of(0x2c, 0, 0, 0, 0, w, w >> 8, h, h >> 8, flags & 0x40);
                const blob = new Blob([header, bytes.subarray(palette, palette + paletteSize), profile, gce, descriptor,
                    bytes.subarray(data, pos), Uint8Array.of(0x3b)].filter(Boolean), { type: 'image/gif' });
                const disposal = (packed >> 2) & 7;
                yield { blob, x, y, width: w, height: h, duration: delay, background: transparent,
                    dispose: disposal === 3 ? 'previous' : disposal === 2 ? 'background' : 'keep', blend: 'over' };
            } else {
                frameCount++;
            }
            control = null;
        }
        throw Error('Missing GIF trailer');
    }
    read(false).next(); // Count frames and collect application metadata without allocating frame buffers.
    ensure(frameCount > 0, 'GIF frame count');
    return frameCount > 1 ? { width, height, plays, frameCount, background: transparent, frames: () => read(true) } : null;
}

function webpAnimation(bytes) {
    ensure(bytes.length >= 12 && ascii(bytes, 0, 4) === 'RIFF' && ascii(bytes, 8, 4) === 'WEBP', 'WebP RIFF header');
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const limit = 8 + view.getUint32(4, true);
    ensure(limit >= 12 && limit <= bytes.length, 'WebP RIFF size');
    function* chunks(start, end) {
        for (let p = start; p < end;) {
            ensure(p + 8 <= end, 'WebP chunk header');
            const size = view.getUint32(p + 4, true), data = p + 8, next = data + size + (size & 1);
            ensure(next <= end, 'WebP chunk size');
            yield { name: ascii(bytes, p, 4), start: p, data, size, next };
            p = next;
        }
    }
    let width, height, plays, icc, frameCount = 0, orientation = 1;
    for (const chunk of chunks(12, limit)) {
        const p = chunk.data;
        if (chunk.name === 'VP8X') {
            ensure(chunk.size >= 10, 'WebP extended header');
            if (!(bytes[p] & (2 | 8))) return null; // Ordinary static image without an orientation tag.
            width = u24(bytes, p + 4) + 1;
            height = u24(bytes, p + 7) + 1;
            ensure(width <= 8192 && height <= 8192, 'WebP animation canvas');
        } else if (chunk.name === 'ICCP') {
            icc = bytes.subarray(chunk.start, chunk.next);
        } else if (chunk.name === 'EXIF') {
            orientation = exifOrientation(bytes.subarray(p, p + chunk.size));
        } else if (chunk.name === 'ANIM') {
            ensure(chunk.size >= 6, 'WebP animation header');
            plays = u16(bytes, p + 4);
        } else if (chunk.name === 'ANMF') {
            frameCount++;
        }
    }
    if (!frameCount) {
        if (orientation === 1 || !width || !height) return null;
        // Some browsers rotate a still WebP in <img>, others ignore EXIF. Decode a
        // metadata-neutral patch and apply the file's orientation to its canvas once.
        function* still() {
            const header = new Uint8Array(bytes.subarray(0, 12)), parts = [header];
            let length = 4;
            for (const chunk of chunks(12, limit)) {
                if (chunk.name === 'EXIF') continue;
                const payload = bytes.subarray(chunk.start, chunk.next);
                if (chunk.name === 'VP8X') {
                    const extended = new Uint8Array(payload);
                    extended[8] &= ~8;
                    parts.push(extended);
                } else {
                    parts.push(payload);
                }
                length += payload.length;
            }
            new DataView(header.buffer, header.byteOffset, header.byteLength).setUint32(4, length, true);
            yield { blob: new Blob(parts, { type: 'image/webp' }), x: 0, y: 0, width, height,
                duration: 0, background: transparent, dispose: 'keep', blend: 'source' };
        }
        return { width, height, frameCount: 1, plays: 1, orientation, background: transparent, frames: still };
    }
    ensure(width && height && plays !== undefined, 'WebP animation');

    function* frames() {
        for (const frame of chunks(12, limit)) {
            if (frame.name !== 'ANMF') continue;
            const p = frame.data;
            ensure(frame.size >= 16, 'WebP frame descriptor');
            const x = 2 * u24(bytes, p), y = 2 * u24(bytes, p + 3);
            const w = 1 + u24(bytes, p + 6), h = 1 + u24(bytes, p + 9);
            const duration = u24(bytes, p + 12) / 1000, flags = bytes[p + 15];
            ensure(x + w <= width && y + h <= height, 'WebP frame bounds');
            let alpha, image, hasAlpha = false;
            for (const chunk of chunks(p + 16, p + frame.size)) {
                const data = chunk.data;
                if (chunk.name === 'ALPH') {
                    ensure(!alpha && !image && chunk.size >= 1, 'WebP alpha chunk');
                    alpha = bytes.subarray(chunk.start, chunk.next);
                    hasAlpha = true;
                } else if (chunk.name === 'VP8 ' || chunk.name === 'VP8L') {
                    ensure(!image, 'WebP frame image');
                    if (chunk.name === 'VP8L') {
                        ensure(!alpha && chunk.size >= 5 && bytes[data] === 0x2f, 'WebP lossless header');
                        const bits = view.getUint32(data + 1, true);
                        ensure(w === 1 + (bits & 0x3fff) && h === 1 + ((bits >>> 14) & 0x3fff), 'WebP lossless frame dimensions');
                        hasAlpha = !!(bits & 0x10000000);
                    } else {
                        ensure(chunk.size >= 10 && bytes[data + 3] === 0x9d && bytes[data + 4] === 1 && bytes[data + 5] === 42, 'WebP lossy header');
                        ensure(w === (u16(bytes, data + 6) & 0x3fff) && h === (u16(bytes, data + 8) & 0x3fff), 'WebP lossy frame dimensions');
                    }
                    image = bytes.subarray(chunk.start, chunk.next);
                }
            }
            ensure(image, 'WebP frame payload');
            const header = Uint8Array.of(82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80,
                86, 80, 56, 88, 10, 0, 0, 0, (icc ? 32 : 0) | (hasAlpha ? 16 : 0), 0, 0, 0,
                w - 1, (w - 1) >> 8, (w - 1) >> 16, h - 1, (h - 1) >> 8, (h - 1) >> 16);
            const length = header.length - 8 + (icc?.length || 0) + (alpha?.length || 0) + image.length;
            new DataView(header.buffer).setUint32(4, length, true);
            const blob = new Blob([header, icc, alpha, image].filter(Boolean), { type: 'image/webp' });
            yield { blob, x, y, width: w, height: h, duration, background: transparent,
                dispose: flags & 1 ? 'background' : 'keep', blend: flags & 2 ? 'source' : 'over' };
        }
    }
    // Browser image elements and libwebp composite onto transparent black. The
    // suggested file background may instead be applied by the presenting app.
    return { width, height, frameCount, plays, orientation, background: transparent, frames };
}

export function browserImageAnimation(bytes, type) {
    if (type === 'image/gif') return gifAnimation(bytes);
    if (type === 'image/webp') return webpAnimation(bytes);
    return null;
}
