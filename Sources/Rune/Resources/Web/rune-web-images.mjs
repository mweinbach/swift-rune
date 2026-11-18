// Browser codecs produce composited, upright sRGB canvases. Swift owns cache entries,
// frame timing, mip generation and atlas uploads on every platform.
import { browserImageAnimation } from './rune-web-image-animation.mjs';
import { createBrowserImagePixels } from './rune-web-image-pixels.mjs';

const maxSide = 8192;
const maxBytes = 256 * 1024 * 1024;
const utf8 = new TextDecoder();
const encoder = new TextEncoder();
const codecChecks = new WeakMap();

// Some engines expose ImageDecoder yet flatten transparent pixels against black and
// count the initial GIF play as a repetition. Check the pixels and metadata once
// before entrusting it with alpha or animation. Opaque JPEG needs neither feature.
function nativeAlphaAndAnimation(Decoder) {
    if (!codecChecks.has(Decoder)) codecChecks.set(Decoder, (async () => {
        // Transparent top-left pixel, two frames, three additional NETSCAPE repeats.
        const bytes = Uint8Array.from(atob('R0lGODlhBQADAIEAAAAAAP8AAAAAAAAAACH/C05FVFNDQVBFMi4wAwEDAAAh+QQFBgAAACwAAAAABQADAAAICwABCBQYYKBBgQEBACH5BA0NAAAALAMAAQABAAEAgQAAAP8AAAD/AAAAAAgEAAUEBAA7'), c => c.charCodeAt(0));
        const decoder = new Decoder({ type: 'image/gif', data: bytes, preferAnimation: true });
        try {
            await decoder.tracks.ready;
            if (decoder.tracks.selectedTrack?.repetitionCount !== 3) return false;
            const { image } = await decoder.decode({ frameIndex: 0 });
            try {
                const canvas = document.createElement('canvas');
                canvas.width = 1; canvas.height = 1;
                const ctx = canvas.getContext('2d', { willReadFrequently: true });
                ctx.drawImage(image, 0, 0);
                return ctx.getImageData(0, 0, 1, 1).data[3] === 0;
            } finally { image.close(); }
        } finally { decoder.close(); }
    })().catch(() => false));
    return codecChecks.get(Decoder);
}

// DOM-to-WebGL transfer can bypass color profile conversion. For tagged artwork,
// convert to sRGB in Canvas 2D before reading the unassociated RGBA channels.
function needsCanvasColor(bytes, type) {
    if (type === 'image/gif') {
        for (let i = bytes.indexOf(73, 3); i >= 0; i = bytes.indexOf(73, i + 1)) {
            if (bytes[i - 3] === 33 && bytes[i - 2] === 255 && bytes[i - 1] === 11 &&
                String.fromCharCode(...bytes.subarray(i, i + 11)) === 'ICCRGBG1012') return true;
        }
        return false;
    }
    if (type === 'image/webp') return bytes[12] === 86 && bytes[15] === 88 && (bytes[20] & 32) !== 0;
    if (type !== 'image/png') return true;
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let specified = false, standard = false;
    for (let offset = 8; offset + 12 <= bytes.length; ) {
        const size = view.getUint32(offset);
        const tag = String.fromCharCode(...bytes.subarray(offset + 4, offset + 8));
        if (tag === 'IDAT') break;
        if (tag === 'iCCP' || tag === 'cICP') return true;
        if (tag === 'gAMA' || tag === 'cHRM') specified = true;
        if (tag === 'sRGB') standard = true;
        offset += size + 12;
    }
    return specified && !standard;
}

function hasPNGAnimation(bytes) {
    if (bytes.length < 33 || bytes[0] !== 137 || bytes[1] !== 80 || bytes[2] !== 78 || bytes[3] !== 71) return false;
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    for (let offset = 8; offset + 12 <= bytes.length;) {
        const length = view.getUint32(offset);
        if (offset + 12 + length > bytes.length) return false;
        const tag = view.getUint32(offset + 4);
        if (tag === 0x6163544c) return length === 8; // acTL precedes the first IDAT in APNG.
        if (tag === 0x49444154 || tag === 0x49454e44) return false;
        offset += 12 + length;
    }
    return false;
}

function checkSize(width, height) {
    if (!Number.isInteger(width) || !Number.isInteger(height) || width <= 0 || height <= 0 ||
        width > maxSide || height > maxSide) throw Error(`Invalid image dimensions ${width}×${height} (limit ${maxSide})`);
}

function thumbnail(width, height, limit) {
    const scale = limit > 0 ? Math.min(1, limit / Math.max(width, height)) : 1;
    return [Math.max(1, Math.round(width * scale)), Math.max(1, Math.round(height * scale))];
}

// Matches DecodedImage.animationStorage, including the straight frame and every mip.
function frameCost(width, height) {
    let size = width * height * 4;
    for (;;) {
        size += width * height * 4;
        if (width === 1 && height === 1) return size;
        width = Math.max(1, width >> 1);
        height = Math.max(1, height >> 1);
    }
}

// ImageDecoder requires a MIME type even for encoded bytes with no URL. Read the
// common raster headers so an oversized source is rejected before pixel decoding.
function identify(bytes, type) {
    const n = bytes.length;
    const view = new DataView(bytes.buffer, bytes.byteOffset, n);
    const tag = (offset, length) => String.fromCharCode(...bytes.subarray(offset, offset + length));
    if (n >= 24 && bytes[0] === 137 && tag(1, 3) === 'PNG') {
        return ['image/png', view.getUint32(16), view.getUint32(20)];
    }
    if (n >= 10 && ['GIF87a', 'GIF89a'].includes(tag(0, 6))) {
        return ['image/gif', view.getUint16(6, true), view.getUint16(8, true)];
    }
    if (n >= 12 && tag(0, 4) === 'RIFF' && tag(8, 4) === 'WEBP') {
        const chunk = tag(12, 4);
        if (n >= 30 && chunk === 'VP8X') {
            const uint24 = i => bytes[i] + bytes[i + 1] * 256 + bytes[i + 2] * 65536;
            return ['image/webp', uint24(24) + 1, uint24(27) + 1];
        }
        if (n >= 25 && chunk === 'VP8L') {
            const bits = view.getUint32(21, true);
            return ['image/webp', (bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1];
        }
        if (n >= 30 && chunk === 'VP8 ') return ['image/webp', view.getUint16(26, true) & 0x3fff, view.getUint16(28, true) & 0x3fff];
        return ['image/webp'];
    }
    if (n >= 3 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) {
        let offset = 2;
        while (offset + 3 < n && bytes[offset] === 255) {
            while (bytes[offset] === 255) offset++;
            const marker = bytes[offset++];
            if (marker === 218 || marker === 217 || offset + 2 > n) break;
            const length = view.getUint16(offset);
            if (length < 2 || offset + length > n) break;
            if (length >= 8 && marker >= 192 && marker <= 207 && ![196, 200, 204].includes(marker)) {
                return ['image/jpeg', view.getUint16(offset + 5), view.getUint16(offset + 3)];
            }
            offset += length;
        }
        return ['image/jpeg'];
    }
    if (n >= 16 && tag(4, 4) === 'ftyp') {
        // AVIF can declare an ISOBMFF brand as its major brand and avif/avis as a compatible brand.
        const end = Math.min(view.getUint32(0), n);
        for (let i = 8; i + 4 <= end; i += 4) {
            if (i !== 12 && ['avif', 'avis'].includes(tag(i, 4))) return ['image/avif'];
        }
    }
    if (n > 2 && tag(0, 2) === 'BM') return ['image/bmp'];
    if (n > 4 && view.getUint32(0) === 256) return ['image/x-icon'];
    const whitespace = [9, 10, 12, 13, 32];
    let first = bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf ? 3 : 0;
    while (whitespace.includes(bytes[first])) first++;
    if (bytes[first] === 60) return ['image/svg+xml'];
    return [type?.split(';')[0].toLowerCase() || ''];
}

// The browser may sniff a data URL again when it paints the serialized SVG. Give it
// only the four raster formats Rune accepts, with a MIME type matching the actual bytes.
function svgRasterURL(href) {
    const comma = href.indexOf(',');
    if (!/^data:/i.test(href) || comma < 5) return null;
    const parts = href.slice(5, comma).toLowerCase().split(';');
    const mime = parts[0].trim() || 'text/plain';
    const base64 = parts.at(-1).trim() === 'base64';
    if (!['text/plain', 'image/png', 'image/jpg', 'image/jpeg', 'image/gif', 'image/webp'].includes(mime)) return null;

    // Twelve decoded bytes cover RIFF/WEBP, the longest signature. Read through
    // percent escapes and folded base64 without duplicating an entire raster.
    let header = '';
    for (let i = comma + 1; i < href.length && header.length < (base64 ? 16 : 12); ++i) {
        let ch = href[i];
        if (ch === '%') {
            const hex = href.slice(i + 1, i + 3);
            if (!/^[0-9a-f]{2}$/i.test(hex)) return null;
            ch = String.fromCharCode(parseInt(hex, 16));
            i += 2;
        }
        if (!base64 || !/[\t\n\f\r ]/.test(ch)) header += ch;
    }
    if (base64) {
        try { header = atob(header); } catch { return null; }
    }
    let type;
    if (header.startsWith('\x89PNG\r\n\x1a\n')) type = 'image/png';
    else if (header.startsWith('\xff\xd8\xff')) type = 'image/jpeg';
    else if (header.startsWith('GIF87a') || header.startsWith('GIF89a')) type = 'image/gif';
    else if (header.startsWith('RIFF') && header.slice(8, 12) === 'WEBP') type = 'image/webp';
    else return null;
    if (mime !== 'text/plain' && (mime === 'image/jpg' ? 'image/jpeg' : mime) !== type) return null;
    return 'data:' + type + (base64 ? ';base64,' : ',') + href.slice(comma + 1);
}

function resolveSVGImageResources(svg) {
    const xlink = 'http://www.w3.org/1999/xlink';
    for (const image of svg.querySelectorAll('image, feImage')) {
        const href = (image.getAttribute('href') ?? image.getAttributeNS(xlink, 'href') ?? '').trim();
        image.removeAttributeNS(xlink, 'href');
        if (image.localName === 'feImage' && href.startsWith('#')) {
            // usvg resolves a filter's fragment against this same document.
            for (let node = image; node; node = node.parentElement) {
                node.removeAttributeNS('http://www.w3.org/XML/1998/namespace', 'base');
            }
            image.setAttribute('href', href);
        } else {
            const raster = svgRasterURL(href);
            if (raster) image.setAttribute('href', raster);
            else image.removeAttribute('href');
        }
    }
    // Rasterization consumes the authored resource. A timed attribute must not
    // replace the validated URI when the browser paints the detached document.
    for (const anim of svg.querySelectorAll('animate[attributeName], set[attributeName]')) {
        const attribute = anim.getAttribute('attributeName').trim().split(':').pop();
        if (attribute === 'href' || attribute === 'base') anim.remove();
    }
}

// Assign the raster box explicitly so viewBox-only SVGs use their own aspect ratio,
// including in browsers that give unsized HTML images a 300×150 default viewport.
function svgImage(bytes, limit) {
    const parser = new DOMParser();
    let svg = parser.parseFromString(utf8.decode(bytes), 'image/svg+xml').documentElement;
    if (svg.localName === 'svg' && !svg.namespaceURI) {
        const markup = new XMLSerializer().serializeToString(svg).replace(/^<svg(?=[\s/>])/, '<svg xmlns="http://www.w3.org/2000/svg"');
        svg = parser.parseFromString(markup, 'image/svg+xml').documentElement;
    }
    if (svg.localName !== 'svg' || svg.namespaceURI !== 'http://www.w3.org/2000/svg') throw Error('Invalid SVG document');
    resolveSVGImageResources(svg);
    const absolute = name => {
        const value = svg[name].baseVal;
        return svg.hasAttribute(name) && value.unitType !== SVGLength.SVG_LENGTHTYPE_PERCENTAGE && value.value > 0 ? value.value : null;
    };
    const box = svg.viewBox.baseVal;
    const ratio = box.width > 0 && box.height > 0 ? box.width / box.height : 1;
    const intrinsicWidth = absolute('width'), intrinsicHeight = absolute('height');
    const width = intrinsicWidth ?? (intrinsicHeight ? intrinsicHeight * ratio : box.width || 16);
    const height = intrinsicHeight ?? width / ratio;
    const extent = Math.max(width, height);
    const side = limit || Math.min(4096, Math.ceil(extent * 2));
    const w = Math.max(1, Math.round(width / extent * side)), h = Math.max(1, Math.round(height / extent * side));
    checkSize(w, h);
    svg.setAttribute('width', w);
    svg.setAttribute('height', h);
    if (!svg.hasAttribute('viewBox')) svg.setAttribute('viewBox', `0 0 ${width} ${height}`);
    return new Blob([new XMLSerializer().serializeToString(svg)], { type: 'image/svg+xml' });
}

// HTML image loading provides natural dimensions without requesting full pixel decoding.
async function loadImage(blob, signal) {
    const image = new Image();
    const url = URL.createObjectURL(blob);
    try {
        await new Promise((resolve, reject) => {
            const abort = () => { image.removeAttribute('src'); reject(signal.reason); };
            signal.throwIfAborted();
            signal.addEventListener('abort', abort, { once: true });
            image.onload = () => { signal.removeEventListener('abort', abort); resolve(); };
            image.onerror = () => { signal.removeEventListener('abort', abort); reject(Error('Browser could not read the encoded image')); };
            image.src = url;
        });
        checkSize(image.naturalWidth, image.naturalHeight);
        return image;
    } finally { URL.revokeObjectURL(url); }
}

async function decode(bytes, mediaType, limit, sourceMode, signal, pixels, emit) {
    if (bytes[0] === 31 && bytes[1] === 139) {
        let expanded = 0;
        const bounded = new TransformStream({ transform(chunk, output) {
            expanded += chunk.byteLength;
            if (expanded > maxBytes) throw Error('Expanded image exceeds the 256 MiB limit');
            output.enqueue(chunk);
        } });
        const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'), { signal }).pipeThrough(bounded);
        bytes = new Uint8Array(await new Response(stream).arrayBuffer());
    }
    const [type, sourceWidth, sourceHeight] = identify(bytes, mediaType);
    if (sourceWidth !== undefined) checkSize(sourceWidth, sourceHeight);
    const vector = type === 'image/svg+xml';
    const image = sourceWidth === undefined
        ? await loadImage(vector ? svgImage(bytes, limit) : new Blob([bytes], { type }), signal) : null;
    let surface, context;
    function draw(source, width, height, duration) {
        signal.throwIfAborted();
        if (!surface || surface.width !== width || surface.height !== height) {
            surface = document.createElement('canvas');
            surface.width = width; surface.height = height;
            context = surface.getContext('2d', { willReadFrequently: true, colorSpace: 'srgb' });
            if (!context) throw Error('Browser does not provide an RGBA canvas');
            context.globalCompositeOperation = 'copy';
            context.imageSmoothingQuality = 'high';
        }
        // drawImage applies the VideoFrame rotation and flip and converts its colors
        // to sRGB. getImageData hands Swift a tightly-packed, unpremultiplied canvas.
        context.drawImage(source, 0, 0, width, height);
        return emit(context.getImageData(0, 0, width, height).data, width, height, duration);
    }
    const rasterLimit = sourceMode === 1 || vector ? 0 : limit;
    const Decoder = globalThis.ImageDecoder;
    // Some native decoders ignore WebP EXIF. The container fallback applies its
    // orientation once to the still image or each fully composited animation frame.
    const webpExif = type === 'image/webp' && bytes[15] === 88 && (bytes[20] & 8) !== 0;
    if (!vector && !webpExif && type && Decoder && await Decoder.isTypeSupported(type) &&
        (type === 'image/jpeg' || await nativeAlphaAndAnimation(Decoder))) {
        signal.throwIfAborted();
        const options = { data: bytes, type, preferAnimation: true, transfer: [bytes.buffer] };
        if (sourceWidth && rasterLimit && rasterLimit < Math.max(sourceWidth, sourceHeight)) {
            [options.desiredWidth, options.desiredHeight] = thumbnail(sourceWidth, sourceHeight, rasterLimit);
        }
        const decoder = new Decoder(options);
        const close = () => decoder.close();
        signal.addEventListener('abort', close, { once: true });
        try {
            await decoder.tracks.ready;
            const track = decoder.tracks.selectedTrack;
            if (!track?.frameCount) throw Error('Image has no frames');
            let count = track.animated ? track.frameCount : 1;
            for (let i = 0; i < count; i++) {
                const { image: frame } = await decoder.decode({ frameIndex: i });
                try {
                    checkSize(frame.codedWidth, frame.codedHeight);
                    checkSize(frame.displayWidth, frame.displayHeight);
                    const [w, h] = thumbnail(frame.displayWidth, frame.displayHeight, rasterLimit);
                    if (i === 0 && count > Math.floor(maxBytes / frameCost(w, h))) count = 1;
                    const duration = (frame.duration ?? 0) / 1e6;
                    const color = frame.colorSpace;
                    if ((frame.format === 'BGRA' || frame.format === 'RGBA') && frame.rotation === 0 && frame.flip === false &&
                        frame.visibleRect.width === w && frame.visibleRect.height === h &&
                        color.fullRange && color.primaries === 'bt709' && color.transfer === 'iec61966-2-1' && color.matrix === 'rgb') {
                        // A trip through premultiplied 8-bit canvas pixels loses RGB precision
                        // wherever alpha is partial. Keep the codec's original straight channels.
                        const rgba = new Uint8Array(w * h * 4);
                        await frame.copyTo(rgba, { layout: [{ offset: 0, stride: w * 4 }] });
                        signal.throwIfAborted();
                        if (frame.format === 'BGRA') {
                            for (let j = 0; j < rgba.length; j += 4) {
                                const blue = rgba[j]; rgba[j] = rgba[j + 2]; rgba[j + 2] = blue;
                            }
                        }
                        if (!emit(rgba, w, h, duration)) return;
                    } else if (!draw(frame, w, h, duration)) return;
                } finally { frame.close(); }
            }
            return count === 1 ? 1 : Number.isFinite(track.repetitionCount) ? track.repetitionCount + 1 : 0;
        } finally {
            signal.removeEventListener('abort', close);
            decoder.close();
        }
    }
    const useCanvasColor = needsCanvasColor(bytes, type);
    const animation = browserImageAnimation(bytes, type);
    if (animation) return pixels.compose(animation, rasterLimit, loadImage, emit, signal, useCanvasColor);
    const source = image || await loadImage(new Blob([bytes], { type }), signal);
    const [w, h] = thumbnail(source.naturalWidth, source.naturalHeight, rasterLimit);
    signal.throwIfAborted();
    if (!vector && w === source.naturalWidth && h === source.naturalHeight) {
        if (emit(pixels.read(source, w, h, useCanvasColor), w, h, 0)) return 1;
        return;
    }
    if (draw(source, w, h, 0)) return 1;
}

export function createRuneImageDecoder(getExports) {
    const pending = new Map();
    const pixels = createBrowserImagePixels({ thumbnail, frameCost, maxBytes });
    let disposed = false;
    function write(wasm, bytes) {
        const address = wasm.rune_web_buffer(bytes.length) >>> 0;
        if (!address) throw Error('Could not reserve Rune image buffer');
        new Uint8Array(wasm.memory.buffer, address, bytes.length).set(bytes);
    }
    return {
        start(id, pointer, length, maxDimension, sourceMode) {
            if (disposed) return;
            pending.get(id)?.abort();
            const controller = new AbortController();
            const { signal } = controller;
            pending.set(id, controller);
            const wasm = getExports();
            async function run() {
                const input = new Uint8Array(wasm.memory.buffer, pointer >>> 0, length >>> 0);
                let bytes, type;
                // The reactor can resize or overwrite the shared buffer as soon as start returns.
                if (sourceMode) {
                    const response = await fetch(utf8.decode(input), { signal });
                    if (!response.ok) throw Error(`Image request failed (HTTP ${response.status})`);
                    type = response.headers.get('Content-Type');
                    bytes = new Uint8Array(await response.arrayBuffer());
                } else { bytes = input.slice(); }
                // URL fetches land here before Swift has seen the bytes. Its APNG reader also
                // retains animation when the browser's ImageDecoder cannot preserve transparency.
                if (wasm.rune_web_image_apng && hasPNGAnimation(bytes)) {
                    signal.throwIfAborted();
                    write(wasm, bytes);
                    if (wasm.rune_web_image_apng(id, bytes.length, sourceMode === 1 ? 0 : maxDimension)) return;
                }
                const plays = await decode(bytes, type, maxDimension, sourceMode, signal, pixels, (rgba, width, height, duration) => {
                    write(wasm, rgba);
                    return wasm.rune_web_image_frame(id, width, height, duration);
                });
                if (!signal.aborted && plays !== undefined) wasm.rune_web_image_finish(id, plays, 0);
            }
            run().catch(error => {
                if (signal.aborted) return;
                const message = encoder.encode(String(error?.message || error).slice(0, 256) || 'Image decoding failed');
                let length = -1;
                try { write(wasm, message); length = message.length; } catch { /* Swift supplies the fallback diagnostic. */ }
                wasm.rune_web_image_finish(id, 0, length);
            }).finally(() => { if (pending.get(id) === controller) pending.delete(id); });
        },
        dispose() {
            disposed = true;
            for (const job of pending.values()) job.abort();
            pending.clear();
            pixels.dispose();
        }
    };
}
