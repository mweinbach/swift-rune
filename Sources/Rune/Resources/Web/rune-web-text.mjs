// Font shaping, bidi selection geometry and glyph coverage use the browser's installed
// font fallback. Rune owns line breaking, styles, atlas packing and drawing.
const utf8 = new TextDecoder('utf-8', { ignoreBOM: true });
const utf16be = new TextDecoder('utf-16be');
const pendingFonts = new WeakMap();
const bundledFonts = new WeakMap();
const fontSources = new WeakMap();
let aliasCount = 0;
const genericFamilies = new Set(['serif', 'sans-serif', 'monospace', 'cursive', 'fantasy', 'system-ui',
    'ui-serif', 'ui-sans-serif', 'ui-monospace', 'ui-rounded', 'emoji', 'math', 'fangsong']);

function rememberFont(doc, bytes, info) {
    let families = fontSources.get(doc);
    if (!families) fontSources.set(doc, families = new Map());
    const key = info.family.toLowerCase();
    let faces = families.get(key);
    if (!faces) families.set(key, faces = new Map());
    faces.set(info.weight + info.style, { bytes, ...info });
}

// Preserve quoted commas and escaped characters when walking the authored stack.
// CSSOM normalizes multi-word names, quotes, and generic families for Canvas.
function familyStack(style, raw, fallback) {
    const tokens = raw.match(/(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\\.|[^"',\\])+/gu) ?? [];
    const families = [];
    for (const token of tokens) {
        const value = token.trim();
        if (!value) continue;
        style.fontFamily = '';
        style.fontFamily = value;
        let css = style.fontFamily || CSS.escape(value);
        if (/^(?:inherit|initial|unset|revert|revert-layer)$/i.test(css)) css = JSON.stringify(value);
        const name = css.startsWith('"') ? css.slice(1, -1) : css;
        const key = name.replace(/\\(?:([0-9a-f]{1,6})\s?|(.))/giu, (_, hex, escaped) => {
            if (!hex) return escaped;
            const point = parseInt(hex, 16);
            return point > 0 && point <= 0x10ffff ? String.fromCodePoint(point) : '\ufffd';
        }).toLowerCase();
        families.push({ css, key: !css.startsWith('"') && genericFamilies.has(key) ? null : key });
    }
    if (families.at(-1)?.css !== fallback) families.push({ css: fallback, key: null });
    return families;
}

// Swift AppSpec supplies font bytes. FontFace requires an explicit CSS family; obtain
// the family, weight and style from the sfnt name and OS/2 tables.
function fontDescriptor(bytes) {
    const data = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    if (bytes.length < 12) return null;
    const tags = new Map();
    const tableCount = data.getUint16(4);
    for (let i = 0; i < tableCount; ++i) {
        const pos = 12 + i * 16;
        if (pos + 16 > bytes.length) return null;
        const tag = String.fromCharCode(...bytes.subarray(pos, pos + 4));
        const offset = data.getUint32(pos + 8);
        const size = data.getUint32(pos + 12);
        if (offset + size > bytes.length) return null;
        tags.set(tag, [offset, size]);
    }
    const name = tags.get('name');
    if (!name || name[1] < 6) return null;
    const end = name[0] + name[1];
    const count = data.getUint16(name[0] + 2);
    const strings = name[0] + data.getUint16(name[0] + 4);
    let family, priority = 0;
    for (let i = 0; i < count; ++i) {
        const p = name[0] + 6 + 12 * i;
        if (p + 12 > end) return null;
        const platform = data.getUint16(p);
        const id = data.getUint16(p + 6);
        const pos = strings + data.getUint16(p + 10);
        const length = data.getUint16(p + 8);
        if (![0, 3].includes(platform) || ![1, 16].includes(id) || pos + length > end) continue;
        const score = (id === 16 ? 2 : 0) + (data.getUint16(p + 4) === 0x409 ? 2 : 1);
        if (score > priority) {
            family = utf16be.decode(bytes.subarray(pos, pos + length));
            priority = score;
        }
    }
    if (!family) return null;
    const os2 = tags.get('OS/2');
    const weight = os2 && os2[1] >= 6 ? data.getUint16(os2[0] + 4) : 400;
    const italic = os2 && os2[1] >= 64 && (data.getUint16(os2[0] + 62) & 1);
    return { family, weight: String(Math.min(1000, Math.max(1, weight))), style: italic ? 'italic' : 'normal',
        color: ['COLR', 'CBDT', 'sbix', 'SVG '].some(tag => tags.has(tag)) };
}

function applyFont(context, line) {
    context.font = line.font;
    context.direction = line.direction;
    context.fontKerning = line.kerning;
    context.textAlign = 'left';
    context.textBaseline = 'alphabetic';
    if ('lang' in context) context.lang = line.element.lang || 'inherit';
}

// For callers that perform their own WebAssembly instantiation. Resolve memory
// lazily because instance.exports does not exist when the imports are prepared.
export function createRuneTextImports(getMemory, doc = globalThis.document) {
    const runs = new Map();
    const colorFamilies = new Set();
    const aliases = new Map();
    let next = 1, root, canvas, context;
    const memory = () => getMemory().buffer;
    const view = () => new DataView(memory());
    const string = (ptr, n) => utf8.decode(new Uint8Array(memory(), ptr >>> 0, n));

    function releaseAliases(line) {
        if (!line) return;
        for (const alias of line.aliases) {
            if (--alias.users === 0) {
                doc.fonts.delete(alias.face);
                aliases.delete(alias.key);
            }
        }
        line.aliases.length = 0;
    }

    function measure(line, ptr, size) {
        applyFont(context, line);
        const m = context.measureText(line.text);
        const ascent = m.fontBoundingBoxAscent ?? m.actualBoundingBoxAscent;
        const descent = m.fontBoundingBoxDescent ?? m.actualBoundingBoxDescent;
        const x = Math.floor(-m.actualBoundingBoxLeft);
        const y = Math.floor(ascent - m.actualBoundingBoxAscent);
        const right = Math.ceil(m.actualBoundingBoxRight);
        const bottom = Math.ceil(ascent + m.actualBoundingBoxDescent);
        const out = view();
        out.setFloat32(ptr, m.width, true);
        out.setFloat32(ptr + 4, ascent, true);
        out.setFloat32(ptr + 8, descent, true);
        [x, y, Math.max(0, right - x), Math.max(0, bottom - y)].forEach((v, i) => out.setInt32(ptr + 12 + 4 * i, v, true));
        if (size >= 40) {
            out.setFloat32(ptr + 28, ascent, true);
            out.setFloat32(ptr + 32, descent, true);
            out.setFloat32(ptr + 36, context.measureText('H').actualBoundingBoxAscent, true);
        }
        line.baseline = ascent;
        line.origin = line.element.getBoundingClientRect().left;
        line.carets.clear();
        line.tile = null;
    }

    function coverage(line, x, y, width, height) {
        const last = line.tile;
        if (last && last.x === x && last.y === y && last.width === width && last.height === height) return last;
        if (canvas.width !== width) canvas.width = width;
        if (canvas.height !== height) canvas.height = height;
        applyFont(context, line);
        function paint(color) {
            context.clearRect(0, 0, width, height);
            context.fillStyle = color;
            context.fillText(line.text, -x, line.baseline - y);
            return context.getImageData(0, 0, width, height).data;
        }
        const white = paint('white');
        const mask = new Uint8Array(width * height);
        let rgba;
        if (line.hasColor) {
            // Intrinsic font colors survive a black/white foreground change, including
            // white or black details inside emoji. The difference is the tintable coverage.
            const black = paint('black');
            rgba = new Uint8ClampedArray(white.length);
            for (let i = 0; i < mask.length; ++i) {
                const j = i * 4;
                const foreground = Math.max(0, Math.min(1, (white[j] - black[j]) / 255));
                mask[i] = Math.round(white[j + 3] * foreground);
                const intrinsic = 1 - foreground;
                rgba[j + 3] = white[j + 3] * intrinsic;
                if (rgba[j + 3]) {
                    rgba[j] = black[j] / intrinsic;
                    rgba[j + 1] = black[j + 1] / intrinsic;
                    rgba[j + 2] = black[j + 2] / intrinsic;
                }
            }
        } else {
            for (let i = 0; i < mask.length; ++i) mask[i] = white[i * 4 + 3];
        }
        return line.tile = { x, y, width, height, mask, rgba };
    }

    function bounds(line, start, end) {
        const from = line.offsets[start], to = line.offsets[end];
        const first = line.chunks[line.chunkAt[from]], last = line.chunks[line.chunkAt[to > from ? to - 1 : to]];
        line.range.setStart(first.node, from - first.start);
        line.range.setEnd(last.node, to - last.start);
        return line.range.getBoundingClientRect();
    }
    function caret(line, byte) {
        if (line.carets.has(byte)) return line.carets.get(byte);
        const x = bounds(line, byte, byte).left - line.origin;
        line.carets.set(byte, x);
        return x;
    }

    return {
        platform() {
            const nav = doc?.defaultView?.navigator ?? globalThis.navigator;
            const name = nav?.userAgentData?.platform || nav?.platform || '';
            if (/^mac/i.test(name)) return (nav.maxTouchPoints ?? 0) <= 1 ? 1 : 2;
            if (/^(iphone|ipad|ipod)/i.test(name)) return 2;
            if (/^win/i.test(name)) return 3;
            return 0;
        },
        create(ptr, count, familyPtr, familyLen, size, weight, italic, mono, direction, metrics, metricsSize) {
            if (!doc?.documentElement || count <= 0) return 0;
            if (!root) {
                root = doc.createElement('div');
                root.setAttribute('aria-hidden', 'true');
                root.inert = true;
                root.style.cssText = 'all:initial;position:fixed;left:0;top:0;visibility:hidden;pointer-events:none;contain:layout style;';
                canvas = doc.createElement('canvas');
                context = canvas.getContext('2d', { willReadFrequently: true });
            }
            if (!context) return 0;
            if (!root.isConnected) doc.documentElement.append(root);
            const element = doc.createElement('span');
            const text = string(ptr, count);
            const family = string(familyPtr, familyLen);
            const families = familyStack(element.style, family, mono ? 'monospace' : 'sans-serif');
            const prefix = (italic ? 'italic ' : '') + weight + ' ' + size + 'px ';
            const font = prefix + families.map(f => f.css).join(', ');
            element.style.cssText = 'all:initial;display:block;width:max-content;white-space:pre;font-kerning:normal;text-size-adjust:none;';
            element.style.font = font;
            element.dir = direction === 2 ? 'rtl' : direction === 1 ? 'ltr' : 'auto';
            // Long Range queries on one browser text node rescan a long shaping run.
            // Adjacent text nodes participate in the same inline shaping and bidi
            // context. Bound each lookup without introducing element/style boundaries.
            const chunks = [], chunkAt = new Uint32Array(text.length + 1);
            let from = 0;
            function append(to) {
                const node = doc.createTextNode(text.slice(from, to));
                element.append(node);
                chunkAt.fill(chunks.length, from, to + 1);
                chunks.push({ node, start: from });
                from = to;
            }
            if (text.length > 256 && Intl.Segmenter) {
                for (const { index, segment } of new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(text)) {
                    const end = index + segment.length;
                    if (end - from >= 64 && (/\s/u.test(segment) || end - from >= 128)) append(end);
                }
            }
            if (from < text.length) append(text.length);
            root.append(element);
            const offsets = new Uint32Array(count + 1);
            let byte = 0, units = 0;
            for (const scalar of text) {
                const cp = scalar.codePointAt(0);
                const length = cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
                offsets.fill(units, byte, byte + length);
                byte += length;
                units += scalar.length;
            }
            offsets[count] = units;
            const hasColor = families.some(f => colorFamilies.has(f.key)) || /[\p{Extended_Pictographic}\p{Regional_Indicator}\u20e3]/u.test(text);
            const line = { text, font, baseFont: font, prefix, families, aliases: [], weight, italic, kerning: 'normal',
                element, offsets, chunks, chunkAt, hasColor, range: doc.createRange(), carets: new Map(),
                direction: doc.defaultView.getComputedStyle(element).direction };
            measure(line, metrics, metricsSize);
            const id = next;
            runs.set(id, line);
            do { next = (next + 1) >>> 0; } while (next === 0 || runs.has(next));
            return id;
        },
        configure(id, ptr, size, featurePtr, featureLen, axisPtr, axisLen, metrics, metricsSize) {
            const line = runs.get(id);
            releaseAliases(line);
            line.font = line.baseFont;
            line.element.style.font = line.font;
            line.element.lang = string(ptr, size);
            const features = string(featurePtr, featureLen), axes = string(axisPtr, axisLen);
            line.kerning = features.split(',').some(s => s.startsWith('kern=') && Number(s.slice(5)) === 0) ? 'none' : 'normal';
            line.element.style.fontKerning = line.kerning;
            if (features || axes) {
                const stack = [];
                for (const family of line.families) {
                    const faces = fontSources.get(doc)?.get(family.key);
                    if (!faces) {
                        stack.push(family.css);
                        continue;
                    }
                    // Canvas has no per-draw arbitrary OpenType settings. A private
                    // FontFace using the original bytes supplies them to Canvas and DOM.
                    const entries = [...faces.values()];
                    const distance = face => Math.abs(Number(face.weight) - line.weight) +
                        ((face.style === 'italic') === Boolean(line.italic) ? 0 : 1000);
                    const src = entries.reduce((a, b) => distance(a) <= distance(b) ? a : b);
                    const key = JSON.stringify([family.key, src.weight, src.style, features, axes]);
                    let alias = aliases.get(key);
                    if (!alias) {
                        const settings = (value, integer) => value.split(',').filter(Boolean).map(item => {
                            const [tag, number] = item.split('=');
                            return /^[a-z0-9 ]{4}$/i.test(tag) && Number.isFinite(Number(number))
                                ? '"' + tag + '" ' + (integer ? Math.max(0, Math.trunc(Number(number))) : Number(number)) : '';
                        }).filter(Boolean).join(', ') || 'normal';
                        const family = 'RuneFont' + (++aliasCount);
                        const face = new FontFace(family, src.bytes, { weight: src.weight, style: src.style,
                            featureSettings: settings(features, true), variationSettings: settings(axes, false) });
                        if (face.status === 'loaded') {
                            doc.fonts.add(face);
                            aliases.set(key, alias = { key, family, face, users: 0 });
                        }
                    }
                    if (alias) {
                        ++alias.users;
                        line.aliases.push(alias);
                        stack.push(alias.family);
                    }
                    stack.push(family.css);
                }
                line.font = line.prefix + stack.join(', ');
                line.element.style.font = line.font;
            }
            measure(line, metrics, metricsSize);
        },
        release(id) {
            const line = runs.get(id);
            releaseAliases(line);
            line?.element.remove();
            runs.delete(id);
            if (!runs.size) root?.remove();
        },
        caret(id, offset) { return caret(runs.get(id), offset); },
        cell(id, start, end, left, width) {
            const line = runs.get(id);
            const rect = bounds(line, start, end);
            const x = rect.left - line.origin;
            const out = view();
            out.setFloat32(left, x, true);
            out.setFloat32(width, rect.width, true);
            if (!rect.width) return 0;
            // At a bidi boundary a collapsed DOM range can use the adjacent run's edge.
            // Use the endpoint nearest either edge of this particular grapheme.
            const a = caret(line, start), b = caret(line, end);
            return Math.min(Math.abs(a - x), Math.abs(b - (x + rect.width))) <=
                Math.min(Math.abs(a - (x + rect.width)), Math.abs(b - x)) ? 1 : -1;
        },
        mask(id, x, y, width, height, destination) {
            const line = runs.get(id);
            if (!line || width < 1 || height < 1) return 0;
            const { mask } = coverage(line, x, y, width, height);
            new Uint8Array(memory(), destination >>> 0, mask.length).set(mask);
            return 1;
        },
        has_color(id) { return runs.get(id)?.hasColor ? 1 : 0; },
        color(id, x, y, width, height, destination) {
            const line = runs.get(id);
            if (!line?.hasColor || width < 1 || height < 1) return 0;
            const { rgba } = coverage(line, x, y, width, height);
            new Uint8Array(memory(), destination >>> 0, rgba.length).set(rgba);
            return 1;
        },
        font(ptr, count) {
            if (!doc?.fonts || !count) return 0;
            const bytes = new Uint8Array(memory(), ptr >>> 0, count >>> 0).slice();
            const info = fontDescriptor(bytes);
            if (!info) return 0;
            try {
                const face = new FontFace(info.family, bytes, { weight: info.weight, style: info.style });
                if (face.status === 'error') return 0;
                if (info.color) colorFamilies.add(info.family.toLowerCase());
                rememberFont(doc, bytes, info);
                doc.fonts.add(face);
                const key = getMemory();
                const pending = pendingFonts.get(key) ?? [];
                pending.push(face.load().catch(() => doc.fonts.delete(face)));
                pendingFonts.set(key, pending);
                return 1;
            } catch { return 0; }
        }
    };
}

export function runeTextFontsReady(memory) {
    const pending = pendingFonts.get(memory);
    if (!pending?.length) return null;
    pendingFonts.delete(memory);
    return Promise.all(pending);
}

async function loadBundledFonts(doc, directory) {
    const url = new URL(directory, import.meta.url);
    let loads = bundledFonts.get(doc);
    if (!loads) bundledFonts.set(doc, loads = new Map());
    if (loads.has(url.href)) return loads.get(url.href);
    const faces = [['Inter', 'Inter-Regular', '400'], ['Inter', 'Inter-Medium', '500'],
        ['Inter', 'Inter-SemiBold', '600'], ['IBM Plex Mono', 'IBMPlexMono-Regular', '400']];
    const ready = Promise.all(faces.map(async ([family, file, weight]) => {
        const response = await fetch(new URL(file + '.ttf', url));
        if (!response.ok) throw new Error('Rune font ' + file + ' returned HTTP ' + response.status);
        const bytes = await response.arrayBuffer();
        const face = new FontFace(family, bytes, { weight });
        await face.load();
        doc.fonts.add(face);
        rememberFont(doc, bytes, { family, weight, style: 'normal' });
    })).catch(error => { loads.delete(url.href); throw error; });
    loads.set(url.href, ready);
    return ready;
}

// Supply the same WASI imports as for a regular reactor. Pass fontDirectory: null
// to use installed fonts and any FontFace instances already registered by the page.
export async function instantiateRuneBrowser(source, imports, {
    fontDirectory = new URL('../Fonts/', import.meta.url), document: doc = globalThis.document
} = {}) {
    let instance;
    const namespaces = { ...imports, rune_text: createRuneTextImports(() => instance.exports.memory, doc) };
    const data = await source;
    if (data instanceof Response && !data.ok) throw new Error('Rune reactor HTTP ' + data.status);
    const binary = data instanceof Response && data.headers.get('content-type')?.split(';')[0] !== 'application/wasm'
        ? await data.arrayBuffer() : data;
    const result = binary instanceof Response ? await WebAssembly.instantiateStreaming(binary, namespaces) :
        await WebAssembly.instantiate(binary, namespaces);
    instance = result.instance ?? result;
    if (doc?.fonts && fontDirectory) await loadBundledFonts(doc, fontDirectory);
    return { instance, module: result.module ?? (binary instanceof WebAssembly.Module ? binary : undefined) };
}
