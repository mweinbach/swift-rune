import { wakeRuneBrowser } from './rune-web-wake.mjs';
import { createRuneSpellImports } from './rune-web-spell.mjs';
import { isFixedPitchAsset, writeFixedPitchCells } from './rune-web-fixed-pitch.mjs';
// Font shaping, bidi selection geometry and glyph coverage use the browser's installed
// font fallback. Rune owns line breaking, styles, atlas packing and drawing.
import { withRunePageClock } from './rune-page-clock.mjs';

const utf8 = new TextDecoder('utf-8', { ignoreBOM: true });
const asciiOffsets = Uint32Array.from({ length: 257 }, (_, i) => i);
const utf16be = new TextDecoder('utf-16be');
const pendingFonts = new WeakMap();
const bundledFonts = new WeakMap();
const fontSources = new WeakMap();
const fontPages = new WeakMap();
const reactorFonts = new WeakMap();
const defaultFontDirectory = new URL('../Fonts/', import.meta.url);
const interFiles = ['Inter-Regular', 'Inter-Medium', 'Inter-SemiBold'];
let aliasCount = 0;
let sourceCount = 0;
// In the four UAX #14 dictionary scripts, word boundaries are also soft wraps.
// Keep marks and join controls in the preceding run, as Parley does.
const dictionaryScripts = [['th', 'Thai'], ['lo', 'Lao'], ['km', 'Khmer'], ['my', 'Myanmar'],
    ['ja', 'Han', 'Hiragana', 'Katakana']];
const dictionaryRuns = new RegExp(dictionaryScripts.map(([, ...scripts]) => {
    const group = scripts.map(script => '\\p{Script=' + script + '}').join('');
    return '([' + group + '][' + group + '\\p{Script=Inherited}\\p{Mark}\\u200c\\u200d\\u30fc]*)';
}).join('|'), 'gu');
const wordSegmenters = new Map();
function wordSegmenter(language) {
    if (!wordSegmenters.has(language)) {
        wordSegmenters.set(language, typeof globalThis.Intl?.Segmenter === 'function'
            ? new Intl.Segmenter(language, { granularity: 'word' }) : null);
    }
    return wordSegmenters.get(language);
}
const genericFamilies = new Set(['serif', 'sans-serif', 'monospace', 'cursive', 'fantasy', 'system-ui',
    'ui-serif', 'ui-sans-serif', 'ui-monospace', 'ui-rounded', 'emoji', 'math', 'fangsong']);

function installFont(doc, source, { bundled = false, startup = false, firstCut = false } = {}) {
    const { bytes, info, face } = source;
    let families = fontSources.get(doc);
    if (!families) fontSources.set(doc, families = new Map());
    const key = info.family.toLowerCase();
    let faces = families.get(key);
    if (!faces) families.set(key, faces = new Map());
    const slot = [face.weight, face.style, face.stretch].join('/');
    const previous = faces.get(slot);
    const page = pageFonts(doc);
    if (bundled && (page.appFamilies.has(key) || (previous && !previous.bundled))) return;
    if (firstCut && previous && !previous.firstCut) return;
    // An app that starts with its own family opts out of the bundled family. Fonts arriving
    // later replace the matching width, style and weight while retaining the other faces.
    if (!bundled && startup) {
        page.appFamilies.add(key);
        for (const [slot, source] of faces) {
            if (!source.bundled) continue;
            doc.fonts.delete(source.face);
            faces.delete(slot);
        }
    }
    if (previous) doc.fonts.delete(previous.face);
    doc.fonts.add(face);
    faces.set(slot, { bytes, ...info, face, bundled, firstCut, asciiFixedPitch: source.asciiFixedPitch, id: ++sourceCount });
    const { colorFamilies } = page;
    if ([...faces.values()].some(source => source.color)) colorFamilies.add(key);
    else colorFamilies.delete(key);
}

function cssFamilyKey(css) {
    const name = /^["']/.test(css) ? css.slice(1, -1) : css;
    if (!name.includes('\\')) return name.toLowerCase();
    return name.replace(/\\(?:([0-9a-f]{1,6})\s?|(.))/giu, (_, hex, escaped) => {
        if (!hex) return escaped;
        const point = parseInt(hex, 16);
        return point > 0 && point <= 0x10ffff ? String.fromCodePoint(point) : '\ufffd';
    }).toLowerCase();
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
        const key = cssFamilyKey(css);
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
    const widths = ['ultra-condensed', 'extra-condensed', 'condensed', 'semi-condensed', 'normal',
        'semi-expanded', 'expanded', 'extra-expanded', 'ultra-expanded'];
    const stretch = os2 && os2[1] >= 8 ? widths[data.getUint16(os2[0] + 6) - 1] : undefined;
    return { family, weight: String(Math.min(1000, Math.max(1, weight))), style: italic ? 'italic' : 'normal', stretch: stretch ?? 'normal',
        color: ['COLR', 'CBDT', 'sbix', 'SVG '].some(tag => tags.has(tag)) };
}

function closestFace(faces, line) {
    const distance = face => Math.abs(Number(face.weight) - line.weight) +
        ((face.style === 'italic') === Boolean(line.italic) ? 0 : 1000);
    return [...faces.values()].reduce((a, b) => distance(a) <= distance(b) ? a : b);
}

// Only claim a registered outline when its Unicode subtables agree. Unsupported
// cmaps keep the browser's white platform mask. The bytes have already loaded
// as a FontFace, but their table offsets still need bounds checks here.
function nominalGlyphs(bytes) {
    const font = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    if (font.byteLength < 12 || 12 + font.getUint16(4) * 16 > font.byteLength) return null;
    let cmap, glyphCount = 0;
    for (let i = 0; i < font.getUint16(4); ++i) {
        const record = 12 + 16 * i, tag = font.getUint32(record);
        const offset = font.getUint32(record + 8), size = font.getUint32(record + 12);
        if (offset + size > font.byteLength) return null;
        if (tag === 0x636d6170) cmap = new DataView(bytes.buffer, bytes.byteOffset + offset, size);
        if (tag === 0x6d617870 && size >= 6) glyphCount = font.getUint16(offset + 4);
    }
    if (!cmap || !glyphCount || cmap.byteLength < 4 || 4 + 8 * cmap.getUint16(2) > cmap.byteLength) return null;
    const tables = new Map();
    for (let i = 0; i < cmap.getUint16(2); ++i) {
        const record = 4 + i * 8, platform = cmap.getUint16(record), encoding = cmap.getUint16(record + 2);
        if (platform !== 0 && !(platform === 3 && (encoding === 1 || encoding === 10))) continue;
        const offset = cmap.getUint32(record + 4);
        if (offset + 2 > cmap.byteLength) return null;
        const format = cmap.getUint16(offset);
        if (format === 14 || tables.has(offset)) continue; // Variation sequences are never simple cells.
        if (format !== 4 && format !== 12) return null;
        if (offset + 16 > cmap.byteLength) return null;
        const length = format === 4 ? cmap.getUint16(offset + 2) : cmap.getUint32(offset + 4);
        const count = format === 4 ? cmap.getUint16(offset + 6) / 2 : cmap.getUint32(offset + 12);
        if (!Number.isInteger(count) || !count || 16 + (format === 4 ? 8 : 12) * count > length || offset + length > cmap.byteLength) return null;
        tables.set(offset, { format, count, data: new DataView(cmap.buffer, cmap.byteOffset + offset, length) });
    }
    return point => {
        let found = false;
        for (const { format, count, data } of tables.values()) {
            if (format === 4 && point > 0xffff) continue;
            let lo = 0, hi = count;
            while (lo < hi) {
                const mid = (lo + hi) >>> 1;
                const end = format === 4 ? data.getUint16(14 + 2 * mid) : data.getUint32(20 + 12 * mid);
                if (end < point) lo = mid + 1;
                else hi = mid;
            }
            if (lo === count) return false;
            const start = format === 4 ? data.getUint16(16 + 2 * (count + lo)) : data.getUint32(16 + 12 * lo);
            if (start > point) return false;
            let glyph;
            if (format === 12) {
                glyph = data.getUint32(24 + 12 * lo) + point - start;
            } else {
                const delta = data.getInt16(16 + 2 * (2 * count + lo));
                const rangeWord = 16 + 2 * (3 * count + lo), offset = data.getUint16(rangeWord);
                if (offset) {
                    const index = rangeWord + offset + 2 * (point - start);
                    if (index + 2 > data.byteLength || index % 2) return false;
                    glyph = data.getUint16(index);
                    if (!glyph) return false;
                } else glyph = point;
                glyph = (glyph + delta) & 0xffff;
            }
            if (!glyph || glyph >= glyphCount) return false;
            found = true;
        }
        return found;
    };
}

// These simple scripts do not require a contextual shaping engine to establish
// nominal character support. Marks, emoji and multi-scalar owners may select a
// different face even when the base scalar has a cmap entry.
const simpleSource = /^[\p{Script=Latin}\p{Script=Greek}\p{Script=Cyrillic}\p{Script=Common}]$/u;
const ambiguousSource = /[\p{Mark}\p{Control}\p{Default_Ignorable_Code_Point}\p{Extended_Pictographic}\p{Emoji_Presentation}\p{Regional_Indicator}]/u;

function sourceFamilies(doc, line) {
    const registered = fontSources.get(doc);
    const families = [];
    let pageFaces;
    for (const family of line.families) {
        const faces = registered?.get(family.key);
        if (!faces?.size) break; // An earlier system, generic, or page family can win here.
        const sources = [...faces.values()];
        pageFaces ??= [...doc.fonts];
        if (sources.some(source => !pageFaces.includes(source.face) ||
            (source.face.unicodeRange ?? 'U+0-10FFFF').toUpperCase() !== 'U+0-10FFFF')) break;
        // A page can provide a completely different face under the same CSS name.
        const competing = pageFaces.some(face => cssFamilyKey(face.family) === family.key && !sources.some(source => source.face === face));
        if (competing) break;
        families.push(sources);
    }
    return families;
}

// Only the exact regular face in the first CSS family can establish this
// contract. A user-installed face or an explicitly configured feature/axis
// can change both glyph selection and the range geometry.
function fixedPitchSource(doc, line) {
    if (!line.offsets || line.text.length > 256 ||
        line.explicitDirection !== 'ltr' || line.lang || line.weight !== 400 || line.italic ||
        line.kerning !== 'normal' || /[^ -~]/.test(line.text) || !line.size) return null;
    const key = line.families[0]?.key;
    const sources = fontSources.get(doc)?.get(key);
    if (sources?.size !== 1) return null;
    const source = sources.values().next().value;
    if (!source.asciiFixedPitch || line.aliases.length > 1) return null;
    const alias = line.aliases[0];
    if (alias && alias.source !== source) return null;
    const face = alias?.face ?? source.face;
    const aliasKey = alias?.family.toLowerCase();
    if (!doc.fonts.has(source.face) || !doc.fonts.has(face) || face.status !== 'loaded' ||
        face.weight !== '400' || face.style !== 'normal' || face.stretch !== 'normal' ||
        cssFamilyKey(face.family) !== (aliasKey ?? key) || source.face.unicodeRange.toUpperCase() !== 'U+0-10FFFF' ||
        face.unicodeRange.toUpperCase() !== 'U+0-10FFFF' || face.sizeAdjust !== '100%' ||
        face.variationSettings !== 'normal') return null;
    const features = face.featureSettings;
    if (features !== 'normal' && features !== '"liga" 0, "clig" 0, "calt" 0, "dlig" 0') return null;
    for (const pageFace of doc.fonts) {
        if (pageFace === face || pageFace === source.face) continue;
        const name = cssFamilyKey(pageFace.family);
        if (name === key || name === aliasKey) return null;
    }
    return source;
}

function registeredCell(doc, line, start, end) {
    const from = line.offsets[start], point = line.text.codePointAt(from);
    if ((start > 0 && line.offsets[start - 1] === from) || (end > 0 && line.offsets[end - 1] === line.offsets[end])) return false;
    if (point === undefined || line.offsets[end] - from !== (point > 0xffff ? 2 : 1)) return false;
    if (line.sourceEpoch !== sourceCount) {
        line.sourceEpoch = sourceCount;
        line.sources = sourceFamilies(doc, line);
        line.sourceCells = new Map();
    }
    if (line.sourceCells.has(point)) return line.sourceCells.get(point);
    const scalar = String.fromCodePoint(point);
    // Requiring every eligible weight/style to cover this scalar avoids guessing
    // which CSS face won, including when weight or slant was synthesized.
    const result = simpleSource.test(scalar) && !ambiguousSource.test(scalar) && line.sources.some(sources =>
        sources.every(source => {
            if (source.nominal === undefined) source.nominal = nominalGlyphs(source.bytes);
            return source.nominal?.(point) === true;
        }));
    line.sourceCells.set(point, result);
    return result;
}

// Keep the original outlines and shaping tables. Adding space to each
// advancing glyph lets a DOM Range tell us when an editing caret divides
// one native glyph between characters. This also works with contextual GSUB.
const advanceProbes = new WeakMap();
const probeGapEm = 4;
function advanceProbe(source) {
    if (advanceProbes.has(source)) return advanceProbes.get(source);
    const bytes = source.bytes instanceof Uint8Array ? source.bytes.slice() : new Uint8Array(source.bytes.slice(0));
    const d = new DataView(bytes.buffer);
    const tables = new Map();
    for (let i = 0; i < d.getUint16(4); ++i) {
        const record = 12 + i * 16;
        tables.set(String.fromCharCode(...bytes.subarray(record, record + 4)), record);
    }
    const head = tables.get('head'), hhea = tables.get('hhea'), hmtx = tables.get('hmtx');
    advanceProbes.set(source, null);
    if (!head || !hhea || !hmtx) return null;
    const offset = record => d.getUint32(record + 8);
    const length = record => d.getUint32(record + 12);
    if (length(head) < 20 || length(hhea) < 36) return null;
    const em = d.getUint16(offset(head) + 18) * probeGapEm;
    const count = d.getUint16(offset(hhea) + 34);
    if (!em || count * 4 > length(hmtx)) return null;
    let changed = 0;
    for (let i = 0; i < count; ++i) {
        const p = offset(hmtx) + 4 * i, advance = d.getUint16(p);
        if (!advance) continue;
        if (advance + em > 0xffff) return null;
        d.setUint16(p, advance + em);
        ++changed;
    }
    // Every advance occupies the high word of an hmtx entry. Both its
    // table and its directory checksum contribute to checkSumAdjustment.
    const delta = changed * em * 65536;
    d.setUint32(hmtx + 4, d.getUint32(hmtx + 4) + delta);
    d.setUint32(offset(head) + 8, d.getUint32(offset(head) + 8) - 2 * delta);
    advanceProbes.set(source, bytes);
    return bytes;
}

// For callers that perform their own WebAssembly instantiation. Resolve memory
// lazily because instance.exports does not exist when the imports are prepared.
export function createRuneTextImports(getMemory, doc = globalThis.document, spellDictionaries = []) {
    const runs = new Map();
    const aliases = new Map();
    const familyStacks = [new Map(), new Map()];
    const fixedPitchStyles = new Map();
    // Tokens belong to this reactor and document. A retired token is never reassigned.
    const geometryTokens = new Map();
    let nextGeometryToken = 3;
    let next = 1, root, spans, explicitSpans, range, familyStyle, defaultContext, unkernedContext, svgClusterOwners;
    const memory = () => getMemory().buffer;
    const view = () => new DataView(memory());
    const string = (ptr, n) => utf8.decode(new Uint8Array(memory(), ptr >>> 0, n));

    let previousFont, previousDirection, previousKerning, previousLanguage;
    function applyFont(context, line) {
        // Only the detached default canvas is private. WebKit mounts its unkerned
        // canvas in the document. Resizing or resetting a canvas restores textAlign to start.
        if (context === defaultContext) {
            if (previousFont === line.font && previousDirection === line.direction &&
                previousKerning === line.kerning && previousLanguage === line.lang && context.textAlign === 'left') return;
            previousFont = line.font;
            previousDirection = line.direction;
            previousKerning = line.kerning;
            previousLanguage = line.lang;
        }
        context.font = line.font;
        context.direction = line.direction;
        if ('fontKerning' in context) context.fontKerning = line.kerning;
        context.textAlign = 'left';
        context.textBaseline = 'alphabetic';
        if ('lang' in context) context.lang = line.lang || 'inherit';
    }

    function dictionaryBreaks(ptr, size, result, words) {
        const source = new Uint8Array(memory(), ptr >>> 0, size);
        const text = utf8.decode(source);
        const flags = new Uint8Array(memory(), result >>> 0, (words ? size : text.length) + 1);
        // Visit boundaries in order. Only caret flags need the UTF-8 offset.
        let byte = 0, units = 0;
        function offset(position) {
            if (!words) return position;
            while (units < position) {
                const lead = source[byte];
                const width = lead < 0x80 ? 1 : lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4;
                byte += width;
                units += width === 4 ? 2 : 1;
            }
            return byte;
        }
        for (const match of text.matchAll(dictionaryRuns)) {
            const run = match[0];
            if (run.length === (run.codePointAt(0) > 0xffff ? 2 : 1)) continue;
            const language = dictionaryScripts[match.slice(1).findIndex(group => group !== undefined)][0];
            if (!words && language === 'ja') continue;
            let previous = offset(match.index);
            for (const { index } of wordSegmenter(language)?.segment(run) ?? []) {
                if (!index) continue;
                const boundary = offset(match.index + index);
                flags.fill(0, previous + 1, boundary);
                flags[boundary] = 1;
                previous = boundary;
            }
            flags.fill(0, previous + 1, offset(match.index + run.length));
        }
    }

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

    function retain(line) {
        const id = next;
        runs.set(id, line);
        do { next = (next + 1) >>> 0; } while (next === 0 || runs.has(next));
        return id;
    }

    // A cached native line retains its text nodes and caret coordinates. Only runs
    // currently being measured need to participate in browser layout. Keep a few
    // together for interleaved styled, bidi and font-probe measurements.
    function mountSpan(element) {
        const shelf = explicitSpans && (element.dir === 'ltr' || element.dir === 'rtl') ? explicitSpans : spans;
        if (element.parentNode === shelf) return;
        if (shelf.childElementCount >= 8) shelf.firstElementChild.remove();
        shelf.append(element);
    }

    // Explicit direction and Canvas metrics do not need a DOM node. Materialize
    // the original styled text only for a browser Range or an ownership probe.
    function measurementSpan(line) {
        if (line.element) return line.element;
        const { text, explicitDirection } = line;
        const element = doc.createElement('span');
        element.style.cssText = 'all:initial;display:block;position:absolute;left:0;top:0;width:max-content;white-space:pre;font-kerning:normal;text-size-adjust:none;';
        element.style.font = line.baseFont;
        element.dir = explicitDirection ?? 'auto';
        if (explicitDirection) element.style.setProperty('direction', explicitDirection, 'important');
        if (line.lang !== undefined) {
            element.lang = line.lang;
            element.style.fontKerning = line.kerning;
            if (line.configuredStack) element.style.font = line.font;
        }
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
        line.chunks = chunks;
        line.chunkAt = chunkAt;
        line.element = element;
        return element;
    }

    function fixedPitchStyleKey(line, source) {
        if (!explicitSpans) return null;
        // The closed shelf owns its span styles. Its host and the document
        // element can still be transformed or hidden by the embedding page.
        for (const element of [root, doc.documentElement]) {
            const style = doc.defaultView.getComputedStyle(element);
            if (style.display === 'none' || style.contentVisibility === 'hidden' ||
                style.transform !== 'none' || style.scale !== 'none' || style.rotate !== 'none' ||
                style.translate !== 'none' || style.perspective !== 'none' ||
                (style.zoom !== '1' && style.zoom !== 'normal')) return null;
        }
        // The same certificate also scopes exact vertical ink bounds. A browser
        // without face-wide ascent can return a baseline specific to this line.
        return [source.id, line.size, line.baseline, doc.defaultView.devicePixelRatio].join('/');
    }

    function lineOrigin(line) {
        mountSpan(measurementSpan(line));
        return line.origin ??= line.element.getBoundingClientRect().left;
    }

    function contextFor(line) {
        if (line.kerning !== 'none' || 'fontKerning' in defaultContext) return defaultContext;
        // WebKit takes kerning from an attached canvas's CSS when its 2D context
        // lacks fontKerning. A separate canvas keeps regular lines using native kerning.
        if (!unkernedContext) {
            const canvas = doc.createElement('canvas');
            canvas.style.cssText = 'position:absolute;left:0;top:0;font-kerning:none';
            unkernedContext = canvas.getContext('2d', { willReadFrequently: true });
            if (unkernedContext) root.append(canvas);
        }
        return unkernedContext ?? defaultContext;
    }

    function measure(line, ptr, size) {
        const context = contextFor(line);
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
        line.shaping = null;
        line.clusterOwners = null;
        line.resolvedInk = null;
        line.sourceEpoch = undefined;
        line.numericMaskSource = null;
        line.metrics = new Uint8Array(memory(), ptr, Math.min(size, 40)).slice();
        line.svgText?.parentNode.remove();
        line.svgText = null;
        line.probe?.element.remove();
        line.probe = undefined;
        // Only range, caret and ink queries need a DOM position. Canvas supplies the metrics above.
        line.origin = undefined;
        line.carets?.clear();
        line.tile = null;
    }

    // A certified fixed-pitch face has no contextual substitutions or kerning in
    // printable ASCII, and its outlines fit their advance. Only the two pixels
    // on either side of a cell boundary can sample ink from its neighbor.
    // Keep those pixels paired with that neighbor when reusing a native read.
    // Other faces go directly to the native canvas mask.
    const fragmentStyles = new Map();
    const fragmentByteLimit = 2 * 1024 * 1024, fragmentLimit = 8192;
    let fragmentCount = 0, fragmentBytes = 0;

    function numericMaskPlan(length, pitch, x, width) {
        const first = Math.max(0, Math.floor(x / pitch));
        const last = Math.min(length, Math.ceil((x + width) / pitch));
        if (first >= last) return null;
        const plan = [];
        for (let i = first; i < last; ++i) {
            const lo = i === first ? x : Math.round(i * pitch);
            const hi = i + 1 === last ? x + width : Math.round((i + 1) * pitch);
            if (lo < (i - 1) * pitch + 2 || hi > (i + 2) * pitch - 2) return null;
            const interiorLeft = Math.ceil(i * pitch + 2), interiorRight = Math.floor((i + 1) * pitch - 2);
            for (let left = lo; left < hi;) {
                const end = left < interiorLeft ? interiorLeft : left < interiorRight ? interiorRight : hi;
                const right = Math.min(hi, end), w = right - left;
                // The crop guards limit x to [-255, 20000], w to 257 and the ASCII
                // index to 255. These integers plus three 7-bit codes fit in 53 bits.
                const keyBase = (((left + 256) * 512 + w) * 256 + i) * 2 ** 21;
                plan.push({ index: i, x: left - x, width: w, keyBase,
                    previous: left < interiorLeft && i > 0, next: right > interiorRight && i + 1 < length });
                left = right;
            }
        }
        return plan;
    }

    function copyMaskColumns(source, stride, x, output, outputStride, outputX, width, height) {
        for (let row = 0; row < height; ++row) {
            const from = row * stride + x, to = row * outputStride + outputX;
            for (let col = 0; col < width; ++col) output[to + col] = source[from + col];
        }
    }

    function numericFragmentKey(part, text) {
        const at = part.index;
        const before = part.previous ? text.charCodeAt(at - 1) : 0;
        const after = part.next ? text.charCodeAt(at + 1) : 0;
        return part.keyBase + (before << 14) + (text.charCodeAt(at) << 7) + after;
    }

    // First and last covered rows of the exact white mask. A fractional pen
    // uses the same 60 horizontal and four vertical steps as DesktopGlyphGlide.
    function maskRows(mask, width, height, left, right, phase) {
        const px = phase & 63, py = phase >>> 6, dx = px ? 1 : 0, dy = py ? 1 : 0;
        const bl = px * (4 - py), br = (60 - px) * (4 - py), tl = px * py, tr = (60 - px) * py;
        function covered(row) {
            let i = (row + dy) * width + left + dx;
            const end = i + right - left;
            if (!phase) {
                for (; i < end; ++i) if (mask[i]) return true;
            } else {
                for (; i < end; ++i) {
                    const above = i - dy * width;
                    if (mask[i] * br + mask[i - dx] * bl + mask[above] * tr + mask[above - dx] * tl >= 120) return true;
                }
            }
            return false;
        }
        const limit = height - dy;
        let top = 0, bottom = limit - 1;
        while (top < limit && !covered(top)) ++top;
        if (top === limit) return 1;
        while (bottom > top && !covered(bottom)) --bottom;
        return 2 + (top << 8) + bottom + 1;
    }

    function numericMask(line, x, y, width, height, rgb, destination, left = -1, right = 0, phase = 0) {
        const source = line.numericMaskSource, text = line.text;
        if (!source || line.clip || line.size < 10 || line.size > 128 || !/\d/.test(text) ||
            x < -255 || x + width > 20000 || width > 257 || height > 129 ||
            line.metrics.byteLength < 4 || fixedPitchSource(doc, line) !== source) return false;
        const metrics = new DataView(line.metrics.buffer, line.metrics.byteOffset, line.metrics.byteLength);
        const pitch = metrics.getFloat32(0, true) / text.length;
        if (!(pitch >= 5)) return false;
        if (fragmentBytes >= fragmentByteLimit || fragmentCount >= fragmentLimit || fragmentStyles.size >= 64) {
            fragmentStyles.clear();
            fragmentBytes = fragmentCount = 0;
        }
        // A configured FontFace gets a new CSS alias when its last line is released.
        // The alias key describes the original font bytes, features and variations.
        const styleKey = `${source.id}|${line.baseFont}|${line.aliases[0]?.key ?? ''}|${line.baseline}|${y}|${height}|${rgb}`;
        let style = fragmentStyles.get(styleKey);
        if (!style) {
            style = { samples: new Map(), plans: new Map() };
            fragmentStyles.set(styleKey, style);
        }
        const shape = `${pitch}|${text.length}|${x}|${width}`;
        let plan = style.plans.get(shape);
        if (!plan) {
            plan = numericMaskPlan(text.length, pitch, x, width);
            if (!plan) return false;
            if (style.plans.size >= 64) style.plans.clear();
            style.plans.set(shape, plan);
        }
        // Keep the last complete tile for this style and crop. Patch only fragments
        // whose cell or neighboring glyph changed. A missing sample requires a native read.
        let tile = plan.lastTile;
        if (tile) {
            const buffer = memory();
            let complete = true;
            for (let i = 0; i < plan.length; ++i) {
                const part = plan[i], key = numericFragmentKey(part, text);
                if (tile.keys[i] === key) continue;
                const bytes = style.samples.get(key);
                if (!bytes) { complete = false; break; }
                copyMaskColumns(bytes, part.width, 0, tile.mask, width, part.x, part.width, height);
                tile.keys[i] = key;
            }
            if (complete) {
                if (left >= 0) return maskRows(tile.mask, width, height, left, right, phase);
                new Uint8Array(buffer, destination >>> 0, tile.mask.length).set(tile.mask);
                return true;
            }
        }
        const { mask } = coverage(line, x, y, width, height, rgb);
        let result = true;
        if (left >= 0) result = maskRows(mask, width, height, left, right, phase);
        else new Uint8Array(memory(), destination >>> 0, mask.length).set(mask);
        // A host hook can render again during the native read. Only retain the
        // result if this exact style and crop are still in the live cache.
        if (fragmentStyles.get(styleKey) !== style || style.plans.get(shape) !== plan) return result;
        // The fragments partition the mask. Allow room for all of them, a complete
        // tile, and its keys, even if a nested native read has just filled the cache.
        if (fragmentBytes + 2 * mask.byteLength + plan.length * Float64Array.BYTES_PER_ELEMENT > fragmentByteLimit ||
            fragmentCount + plan.length > fragmentLimit) {
            fragmentStyles.clear();
            fragmentBytes = fragmentCount = 0;
            return result;
        }
        tile = plan.lastTile;
        if (!tile) {
            tile = plan.lastTile = { mask: new Uint8Array(mask.length), keys: new Float64Array(plan.length) };
            // Tile pixels and keys share the fragment byte budget, even after a plan is retired.
            fragmentBytes += tile.mask.byteLength + tile.keys.byteLength;
        }
        tile.mask.set(mask);
        for (let i = 0; i < plan.length; ++i) {
            const part = plan[i], key = numericFragmentKey(part, text);
            tile.keys[i] = key;
            if (style.samples.has(key)) continue;
            const bytes = new Uint8Array(part.width * height);
            copyMaskColumns(mask, width, part.x, bytes, part.width, 0, part.width, height);
            style.samples.set(key, bytes);
            ++fragmentCount;
            fragmentBytes += bytes.length;
        }
        return result;
    }

    function coverage(line, x, y, width, height, rgb = 0xffffff) {
        const last = line.tile;
        if (last && last.x === x && last.y === y && last.width === width && last.height === height && last.rgb === rgb) return last;
        const context = contextFor(line), canvas = context.canvas;
        // A native tile is at most 256 × 128, plus one neighbor for filtering.
        // Keep that working surface across cells. A larger ownership probe gets
        // its requested size and releases the excess on return to ordinary tiles.
        const w = canvas.width > 257 ? width : Math.max(canvas.width, width);
        const h = canvas.height > 129 ? height : Math.max(canvas.height, height);
        let dirty = w === canvas.width && h === canvas.height;
        if (canvas.width !== w) canvas.width = w;
        if (canvas.height !== h) canvas.height = h;
        applyFont(context, line);
        function paint(color) {
            if (dirty) context.clearRect(0, 0, w, h);
            dirty = true;
            context.fillStyle = color;
            if (line.clip) {
                context.save();
                context.beginPath();
                context.rect(line.clip[0] - x, line.clip[1] - y, line.clip[2], line.clip[3]);
                context.clip();
            }
            if (line.clusters) {
                for (const cluster of line.clusters) context.fillTextCluster(cluster, -x, line.baseline - y);
            } else {
                context.fillText(line.text, (line.pen ?? 0) - x, line.baseline - y);
            }
            if (line.clip) context.restore();
            return context.getImageData(0, 0, width, height).data;
        }
        // Desktop Mac canvas antialiasing depends on the foreground even on a clear
        // bitmap. The shader applies opacity and color after sampling this alpha.
        const ink = paint('#' + rgb.toString(16).padStart(6, '0'));
        const mask = new Uint8Array(width * height);
        let rgba;
        if (line.hasColor) {
            // Intrinsic font colors survive a black/white foreground change, including
            // white or black details inside emoji. The difference is the tintable coverage.
            const white = rgb === 0xffffff ? ink : paint('white');
            const black = rgb === 0 ? ink : paint('black');
            rgba = new Uint8ClampedArray(white.length);
            for (let i = 0; i < mask.length; ++i) {
                const j = i * 4;
                const foreground = Math.max(0, Math.min(1, (white[j] - black[j]) / 255));
                mask[i] = Math.round(ink[j + 3] * foreground);
                const intrinsic = 1 - foreground;
                rgba[j + 3] = white[j + 3] * intrinsic;
                if (rgba[j + 3]) {
                    rgba[j] = black[j] / intrinsic;
                    rgba[j + 1] = black[j + 1] / intrinsic;
                    rgba[j + 2] = black[j + 2] / intrinsic;
                }
            }
        } else {
            for (let i = 0; i < mask.length; ++i) mask[i] = ink[i * 4 + 3];
        }
        return line.tile = { x, y, width, height, rgb, mask, rgba };
    }

    function bounds(line, start, end) {
        return unitBounds(line, line.offsets[start], line.offsets[end]);
    }
    function unitBounds(line, from, to) {
        mountSpan(measurementSpan(line));
        const first = line.chunks[line.chunkAt[from]], last = line.chunks[line.chunkAt[to > from ? to - 1 : to]];
        range.setStart(first.node, from - first.start);
        range.setEnd(last.node, to - last.start);
        return range.getBoundingClientRect();
    }

    // Stable SVG implementations expose either the first character under the
    // glyph or identical typographic extents for each character of a ligature.
    // The HTML Range remains the source of independent editing carets.
    function svgOwner(line, index) {
        if (!line.svgText) {
            const ns = 'http://www.w3.org/2000/svg';
            const svg = doc.createElementNS(ns, 'svg');
            svg.style.cssText = 'position:absolute;overflow:visible;';
            const text = doc.createElementNS(ns, 'text');
            text.style.font = line.font;
            text.style.fontKerning = line.kerning;
            text.style.direction = line.direction;
            text.style.whiteSpace = 'pre';
            text.setAttribute('lang', line.lang || '');
            text.textContent = line.text;
            svg.append(text);
            root.append(svg);
            line.svgText = text;
            line.svgMatches = text.getNumberOfChars() === line.text.length;
            line.svgOwners = new Map();
        }
        const text = line.svgText;
        if (!line.svgMatches) return -1;
        if (line.svgOwners.has(index)) return line.svgOwners.get(index);
        const rect = text.getExtentOfChar(index);
        if (!rect.width || !rect.height) return -1;
        const point = new DOMPoint(rect.x + rect.width / 2, rect.y + rect.height / 2);
        const hit = text.getCharNumAtPosition(point);
        let owner = index;
        while (owner > 0) {
            const prev = text.getExtentOfChar(owner - 1);
            if (prev.x !== rect.x || prev.width !== rect.width || prev.y !== rect.y || prev.height !== rect.height) break;
            --owner;
        }
        owner = hit < 0 ? owner : Math.min(owner, hit);
        line.svgOwners.set(index, owner);
        return owner;
    }

    function fontProbe(line) {
        if (line.probe !== undefined) return line.probe;
        line.probe = null;
        const stack = [];
        let hasProbe = false;
        for (const family of line.families) {
            const sources = fontSources.get(doc)?.get(family.key);
            if (sources) {
                const source = closestFace(sources, line);
                const configured = line.aliases.find(alias => alias.source === source);
                const settings = configured?.face ?? source.face;
                const cacheKey = JSON.stringify(['ink advances', source.id, settings.featureSettings, settings.variationSettings]);
                let alias = aliases.get(cacheKey);
                if (!alias) {
                    const bytes = advanceProbe(source);
                    if (bytes) {
                        const name = 'RuneFont' + (++aliasCount);
                        const face = new FontFace(name, bytes, { weight: source.weight, style: source.style, stretch: source.stretch,
                            featureSettings: settings.featureSettings, variationSettings: settings.variationSettings });
                        if (face.status === 'loaded') {
                            doc.fonts.add(face);
                            aliases.set(cacheKey, alias = { key: cacheKey, family: name, face, users: 0 });
                        }
                    }
                }
                if (alias) {
                    ++alias.users;
                    line.aliases.push(alias);
                    stack.push(alias.family);
                    hasProbe = true;
                }
                if (configured) stack.push(configured.family);
            }
            stack.push(family.css);
        }
        if (!hasProbe) return null;
        const element = measurementSpan(line).cloneNode(true);
        element.style.font = line.prefix + stack.join(', ');
        mountSpan(element);
        return line.probe = { element, origin: element.getBoundingClientRect().left,
            chunkAt: line.chunkAt, chunks: line.chunks.map((chunk, i) => ({ start: chunk.start, node: element.childNodes[i] })),
            divided: new Map() };
    }

    function dividedBoundary(line, probe, index) {
        if (index <= 0 || index >= line.text.length) return false;
        if (probe.divided.has(index)) return probe.divided.get(index);
        function boundary(run) {
            const a = unitBounds(run, index - 1, index), b = unitBounds(run, index, index + 1);
            const [first, second] = a.left <= b.left ? [a, b] : [b, a];
            if (Math.abs(first.right - second.left) > 2) return NaN;
            return (first.right + second.left) / 2 - lineOrigin(run);
        }
        // WebKit rounds the Range edges outwards in CSS pixels. A whole
        // advance shifts a glyph boundary by exactly an integral number of ems.
        const shift = boundary(probe) - boundary(line);
        const gap = line.size * probeGapEm;
        const divided = Math.abs(shift - Math.round(shift / gap) * gap) > 2;
        probe.divided.set(index, divided);
        return divided;
    }

    // For a contextual substitution, the advance probe keeps its original glyph
    // and puts space between adjacent advancing glyphs. Read its native ink at
    // the original pen and check it against the source, including overlapping ink.
    function contextualInk(line, owner, end, rect) {
        const probe = fontProbe(line);
        if (!probe || line.hasColor) return null;
        const expanded = unitBounds(probe, owner, end);
        const gap = line.size * probeGapEm;
        if (Math.abs(expanded.width - rect.width - gap) > 2) return null;
        const pen = rect.left - lineOrigin(line);
        const dx = expanded.left - probe.origin - pen;
        const shift = Math.round(dx / gap) * gap;
        if (Math.abs(shift - dx) > 2) return null;
        const l = Math.floor(pen - gap / 2), r = Math.ceil(pen + rect.width + gap / 2);
        const t = Math.floor(line.baseline - line.shaping.actualBoundingBoxAscent);
        const b = Math.ceil(line.baseline + line.shaping.actualBoundingBoxDescent);
        const w = r - l, h = b - t;
        if (w <= 0 || h <= 0 || w * h > 1024 * 1024 || w > 8192 || h > 8192) return null;
        const font = probe.element.style.font;
        const pixels = coverage({ ...line, font, pen: -shift, tile: null }, l, t, w, h).mask;
        const original = coverage(line, l, t, w, h).mask;
        let left = w, right = 0, top = h, bottom = 0;
        for (let i = 0; i < pixels.length; ++i) {
            if (!pixels[i]) continue;
            if (pixels[i] > original[i]) return null;
            const x = i % w, y = Math.floor(i / w);
            left = Math.min(left, x); right = Math.max(right, x + 1);
            top = Math.min(top, y); bottom = Math.max(bottom, y + 1);
        }
        if (!right || !left || right === w) return null;
        const box = [l + left, t + top, right - left, bottom - top];
        return { font, pen: -shift, box, clip: box };
    }

    function shapedMetrics(line, context) {
        if (!line.shaping) {
            applyFont(context, line);
            line.shaping = context.measureText(line.text);
        }
        return line.shaping;
    }

    function fallbackCluster(line, from) {
        if (svgClusterOwners === undefined) {
            // Some SVG engines report independently measured character boxes
            // for a shaped lam-alef. Such boxes may even hit the next letter.
            const sample = { text: 'لا', font: '40px serif', direction: 'rtl', kerning: 'normal', lang: 'ar' };
            svgClusterOwners = svgOwner(sample, 1) === 0;
            sample.svgText?.parentNode.remove();
        }
        let owner = svgClusterOwners ? svgOwner(line, from) : -1;
        let end = from + 1;
        if (owner >= 0) {
            while (end < line.text.length && svgOwner(line, end) === owner) ++end;
        } else {
            const probe = fontProbe(line);
            if (!probe) return null;
            owner = from;
            while (dividedBoundary(line, probe, owner)) --owner;
            while (dividedBoundary(line, probe, end)) ++end;
        }
        return { owner, end };
    }

    function clusterOwner(line, byte) {
        const offsets = line?.offsets;
        if (!offsets || byte <= 0 || byte >= offsets.length - 1 || line.numericMaskSource) return byte;
        const from = offsets[byte];
        if (!from) return 0;
        // Zero is unqueried; 0xffffffff records a unit the host could not resolve.
        const unknown = 0xffffffff;
        if (!line.clusterOwners) {
            const owners = new Uint32Array(line.text.length);
            const shape = shapedMetrics(line, contextFor(line));
            if (shape.getTextClusters) {
                owners.fill(unknown);
                // A logical unit index also handles RTL clusters returned in visual order.
                for (const cluster of shape.getTextClusters(0, line.text.length)) {
                    owners.fill(cluster.start + 1, cluster.start, cluster.end);
                }
            }
            line.clusterOwners = owners;
        }
        const owners = line.clusterOwners;
        if (!owners[from]) {
            const cluster = fallbackCluster(line, from);
            if (cluster) owners.fill(cluster.owner + 1, cluster.owner, cluster.end);
            else owners[from] = unknown;
        }
        if (owners[from] === unknown) return byte;
        const owner = owners[from] - 1;
        if (owner === from && offsets[byte - 1] !== from) return byte;
        if (line.text.length === offsets.length - 1) return owner;
        // UTF-8 continuation bytes repeat their scalar's UTF-16 index.
        let lo = 0, hi = byte;
        while (lo < hi) {
            const mid = lo + Math.floor((hi - lo) / 2);
            if (offsets[mid] < owner) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    function extractedInk(line, from, to) {
        const context = contextFor(line);
        const none = { text: '', box: [0, 0, 0, 0] };
        if (from >= to) return none;
        const shape = shapedMetrics(line, context);
        if (shape.getTextClusters && shape.getActualBoundingBox && context.fillTextCluster) {
            const clusters = shape.getTextClusters(from, to).filter(c => from <= c.start && c.start < to);
            if (!clusters.length) return none;
            let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
            for (const cluster of clusters) {
                const rect = shape.getActualBoundingBox(cluster.start, cluster.end);
                if (!rect.width || !rect.height) continue;
                left = Math.min(left, Math.floor(rect.left));
                top = Math.min(top, Math.floor(rect.top + line.baseline));
                right = Math.max(right, Math.ceil(rect.right));
                bottom = Math.max(bottom, Math.ceil(rect.bottom + line.baseline));
            }
            return left === Infinity ? none : { clusters, box: [left, top, right - left, bottom - top] };
        }
        if (from === 0 && to === line.text.length) return {};
        const cached = line.resolvedInk;
        if (cached && cached.owner <= from && to <= cached.end) return from === cached.owner ? cached.ink : none;
        const cluster = fallbackCluster(line, from);
        if (!cluster || to > cluster.end || cluster.end - cluster.owner < 2) return null;
        const { owner, end } = cluster;
        // A stand-alone shaped cluster already has the source's exact ink.
        function result(ink) {
            if (!ink) return null;
            line.resolvedInk = { owner, end, ink };
            return owner < from ? none : ink;
        }
        if (owner === 0 && end === line.text.length) return result({});

        // A surrounding context can substitute another glyph or change its
        // marks. Only use the isolated draw when its coverage matches the
        // original native line, including the space around the entire cell.
        const rect = unitBounds(line, owner, end);
        const pen = rect.left - lineOrigin(line);
        const text = line.text.slice(owner, end);
        applyFont(context, line);
        const m = context.measureText(text);
        const left = Math.floor(Math.min(pen, pen - m.actualBoundingBoxLeft)) - 1;
        const right = Math.ceil(Math.max(pen + rect.width, pen + m.actualBoundingBoxRight)) + 1;
        const top = Math.floor(line.baseline - shape.actualBoundingBoxAscent);
        const bottom = Math.ceil(line.baseline + shape.actualBoundingBoxDescent);
        const w = right - left, h = bottom - top;
        if (w < 1 || h < 1 || w > 8192 || h > 8192 || w * h > 1024 * 1024) return null;
        const source = coverage(line, left, top, w, h);
        const target = coverage({ ...line, text, pen, tile: null }, left, top, w, h);
        if (!target.mask.every((v, i) => v === source.mask[i]) ||
            (target.rgba && !target.rgba.every((v, i) => v === source.rgba[i]))) {
            return result(contextualInk(line, owner, end, rect));
        }
        const x = Math.floor(pen - m.actualBoundingBoxLeft), y = Math.floor(line.baseline - m.actualBoundingBoxAscent);
        return result({ text, pen, box: [x, y, Math.ceil(pen + m.actualBoundingBoxRight) - x,
            Math.ceil(line.baseline + m.actualBoundingBoxDescent) - y] });
    }
    function caret(line, byte) {
        const carets = line.carets ??= new Map();
        if (carets.has(byte)) return carets.get(byte);
        const x = bounds(line, byte, byte).left - lineOrigin(line);
        carets.set(byte, x);
        return x;
    }

    function cellDirection(line, start, end, x, width, a, b, reportSource) {
        if (!width) return 0;
        // A collapsed DOM range can use the adjacent run's edge at a bidi boundary.
        const direction = Math.min(Math.abs(a - x), Math.abs(b - (x + width))) <=
            Math.min(Math.abs(a - (x + width)), Math.abs(b - x)) ? 1 : -1;
        return reportSource && registeredCell(doc, line, start, end) ? 2 * direction : direction;
    }

    return {
        ...createRuneSpellImports(getMemory, doc, spellDictionaries),
        wake(delay) { wakeRuneBrowser(getMemory(), delay); },
        word_range(ptr, size, position, result) {
            const text = string(ptr, size);
            const segment = wordSegmenter('und')?.segment(text).containing(position);
            const out = view();
            out.setInt32(result, segment?.index ?? 0, true);
            out.setInt32(result + 4, segment ? segment.index + segment.segment.length : text.length, true);
        },
        dictionary_lines(ptr, size, result) {
            dictionaryBreaks(ptr, size, result, false);
        },
        dictionary_words(ptr, size, result) {
            dictionaryBreaks(ptr, size, result, true);
        },
        platform() {
            const nav = doc?.defaultView?.navigator ?? globalThis.navigator;
            const name = nav?.userAgentData?.platform || nav?.platform || '';
            if (/^mac/i.test(name)) return (nav.maxTouchPoints ?? 0) <= 1 ? 1 : 2;
            if (/^(iphone|ipad|ipod)/i.test(name)) return 2;
            if (/^win/i.test(name)) return 3;
            return 0;
        },
        create(ptr, count, familyPtr, familyLen, size, weight, italic, mono, direction, metrics, metricsSize, willConfigure = 0) {
            if (!doc?.documentElement || count <= 0) return 0;
            if (!root) {
                root = doc.createElement('div');
                // These reads finish synchronously. A document-wide live Range for every
                // retained line would also make the browser update them all on removal.
                range = doc.createRange();
                spans = doc.createElement('div');
                spans.style.cssText = 'all:initial;display:contents;';
                root.append(spans);
                // Explicit lines use Rune's authored direction and font. Isolate
                // their measurement from page selectors such as span::first-letter.
                // The slot preserves the document cascade for auto-direction runs.
                if (root.attachShadow) {
                    explicitSpans = spans.cloneNode(false);
                    root.attachShadow({ mode: 'closed' }).append(explicitSpans, doc.createElement('slot'));
                }
                root.setAttribute('aria-hidden', 'true');
                root.inert = true;
                // Shaping spans reset inherited styles. Keep their layout measurable while hiding the whole subtree.
                root.style.cssText = 'all:initial;position:fixed;left:0;top:0;visibility:hidden;opacity:0;pointer-events:none;contain:layout style;';
                familyStyle = doc.createElement('span').style;
                defaultContext = doc.createElement('canvas').getContext('2d', { willReadFrequently: true });
            }
            if (!defaultContext) return 0;
            if (!root.isConnected) doc.documentElement.append(root);
            const text = string(ptr, count);
            const family = string(familyPtr, familyLen);
            // CSS parsing depends on the declared stack and its generic fallback.
            // Face selection still consults the document's currently installed fonts.
            const stacks = familyStacks[mono ? 1 : 0];
            let families = stacks.get(family);
            if (!families) {
                families = familyStack(familyStyle, family, mono ? 'monospace' : 'sans-serif');
                if (stacks.size >= 64) stacks.clear();
                stacks.set(family, families);
            }
            const prefix = (italic ? 'italic ' : '') + weight + ' ' + size + 'px ';
            const font = prefix + families.map(f => f.css).join(', ');
            const explicitDirection = direction === 2 ? 'rtl' : direction === 1 ? 'ltr' : null;
            let offsets;
            if (count <= 256 && text.length === count && !/[^\x00-\x7f]/.test(text)) {
                // UTF-8 byte indices and UTF-16 Range positions coincide for ASCII.
                offsets = asciiOffsets.subarray(0, count + 1);
            } else {
                offsets = new Uint32Array(count + 1);
                let byte = 0, units = 0;
                for (const scalar of text) {
                    const cp = scalar.codePointAt(0);
                    const length = cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
                    offsets.fill(units, byte, byte + length);
                    byte += length;
                    units += scalar.length;
                }
                offsets[count] = units;
            }
            const hasColor = families.some(f => fontPages.get(doc)?.colorFamilies.has(f.key)) ||
                /[\p{Extended_Pictographic}\p{Regional_Indicator}\u20e3]/u.test(text);
            const line = { text, font, baseFont: font, prefix, families, aliases: [], size, weight, italic, kerning: 'normal',
                offsets, hasColor, carets: null, explicitDirection, direction: explicitDirection };
            if (!explicitDirection) {
                mountSpan(measurementSpan(line));
                line.direction = doc.defaultView.getComputedStyle(line.element).direction;
            }
            // A configured run publishes metrics immediately after applying its language
            // and OpenType settings. Older reactors request the default metrics here.
            if (!willConfigure) measure(line, metrics, metricsSize);
            return retain(line);
        },
        extract_ink(id, start, end, metrics, metricsSize) {
            const line = runs.get(id);
            if (!line?.offsets || start < 0 || end < start || end >= line.offsets.length) return 0;
            // A range starting or ending inside a scalar includes only cluster
            // starts at or above its first UTF-8 byte and strictly below its end.
            function unit(byte) {
                while (byte > 0 && line.offsets[byte] === line.offsets[byte - 1]) ++byte;
                return line.offsets[byte];
            }
            const ink = extractedInk(line, unit(start), unit(end));
            if (!ink) return 0;
            new Uint8Array(memory(), metrics, Math.min(metricsSize, line.metrics.length))
                .set(line.metrics.subarray(0, metricsSize));
            ink.box?.forEach((v, i) => view().setInt32(metrics + 12 + 4 * i, v, true));
            const aliases = line.aliases.slice();
            for (const alias of aliases) ++alias.users;
            return retain({ text: line.text, font: line.font, direction: line.direction, kerning: line.kerning,
                baseline: line.baseline, hasColor: line.hasColor, lang: line.lang, aliases, ...ink });
        },
        configure(id, ptr, size, featurePtr, featureLen, axisPtr, axisLen, metrics, metricsSize) {
            const line = runs.get(id);
            releaseAliases(line);
            line.font = line.baseFont;
            line.lang = string(ptr, size);
            if (line.element) {
                line.element.style.font = line.font;
                line.element.lang = line.lang;
            }
            const features = string(featurePtr, featureLen), axes = string(axisPtr, axisLen);
            line.kerning = features.split(',').some(s => s.startsWith('kern=') && Number(s.slice(5)) === 0) ? 'none' : 'normal';
            if (line.element) line.element.style.fontKerning = line.kerning;
            line.configuredStack = Boolean(features || axes);
            if (line.configuredStack) {
                const stack = [];
                for (const family of line.families) {
                    const faces = fontSources.get(doc)?.get(family.key);
                    if (!faces) {
                        stack.push(family.css);
                        continue;
                    }
                    // Canvas has no per-draw arbitrary OpenType settings. A private
                    // FontFace using the original bytes supplies them to Canvas and DOM.
                    const src = closestFace(faces, line);
                    const key = JSON.stringify([src.id, features, axes]);
                    let alias = aliases.get(key);
                    if (!alias) {
                        const settings = (value, integer) => value.split(',').filter(Boolean).map(item => {
                            const [tag, number] = item.split('=');
                            return /^[a-z0-9 ]{4}$/i.test(tag) && Number.isFinite(Number(number))
                                ? '"' + tag + '" ' + (integer ? Math.max(0, Math.trunc(Number(number))) : Number(number)) : '';
                        }).filter(Boolean).join(', ') || 'normal';
                        const family = 'RuneFont' + (++aliasCount);
                        const face = new FontFace(family, src.bytes, { weight: src.weight, style: src.style, stretch: src.stretch,
                            featureSettings: settings(features, true), variationSettings: settings(axes, false) });
                        if (face.status === 'loaded') {
                            doc.fonts.add(face);
                            aliases.set(key, alias = { key, family, face, source: src, users: 0 });
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
                if (line.element) line.element.style.font = line.font;
            }
            measure(line, metrics, metricsSize);
        },
        release(id) {
            const line = runs.get(id);
            releaseAliases(line);
            line?.svgText?.parentNode.remove();
            line?.probe?.element.remove();
            line?.element?.remove();
            runs.delete(id);
            if (!runs.size) root?.remove();
        },
        caret(id, offset) { return caret(runs.get(id), offset); },
        cluster_owner(id, byte) { return clusterOwner(runs.get(id), byte); },
        cell(id, start, end, left, width, reportSource = false) {
            const line = runs.get(id);
            const rect = bounds(line, start, end);
            const x = rect.left - lineOrigin(line);
            const out = view();
            out.setFloat32(left, x, true);
            out.setFloat32(width, rect.width, true);
            return rect.width ? cellDirection(line, start, end, x, rect.width, caret(line, start), caret(line, end), reportSource) : 0;
        },
        cells(id, ptr, count, reportSource) {
            const line = runs.get(id);
            const memoryBuffer = memory();
            const ints = new Int32Array(memoryBuffer, ptr >>> 0, count * 7);
            const floats = new Float32Array(memoryBuffer, ptr >>> 0, count * 7);
            const source = fixedPitchSource(doc, line);
            if (source) {
                const key = fixedPitchStyleKey(line, source);
                if (key && writeFixedPitchCells(fixedPitchStyles, key, line.text.length, ints, floats, reportSource, index => {
                    const rect = bounds(line, index, index + 1);
                    return [rect.left - lineOrigin(line), rect.width, caret(line, index), caret(line, index + 1)];
                })) return;
            }
            const origin = lineOrigin(line);
            for (let i = 0; i < ints.length; i += 7) {
                const start = ints[i], end = ints[i + 1];
                const rect = bounds(line, start, end);
                const x = rect.left - origin, width = rect.width;
                const a = caret(line, start), b = caret(line, end);
                floats[i + 2] = x;
                floats[i + 3] = width;
                floats[i + 4] = a;
                floats[i + 5] = b;
                ints[i + 6] = cellDirection(line, start, end, x, width, a, b, reportSource);
            }
        },
        mask(id, x, y, width, height, destination, rgb = 0xffffff) {
            const line = runs.get(id);
            if (!line || width < 1) return 0;
            if (height < 0 && height >= -129) {
                const phase = rgb === 0xffffff ? 0 : rgb - 0x1000000;
                if (phase < 0 || phase > 255 || (phase & 63) >= 60) return 0;
                const buffer = memory(), pointer = destination >>> 0;
                if (width > 257 || (pointer & 3) || pointer > buffer.byteLength - 8) return 0;
                const [left, right] = new Int32Array(buffer, pointer, 2);
                const dx = (phase & 63) ? 1 : 0, dy = (phase >>> 6) ? 1 : 0;
                if (left < 0 || right <= left || right > width - dx || -height <= dy) return 0;
                return numericMask(line, x, y, width, -height, 0xffffff, 0, left, right, phase) || 0;
            }
            if (height < 1) return 0;
            if (numericMask(line, x, y, width, height, rgb, destination)) return 1;
            const { mask } = coverage(line, x, y, width, height, rgb);
            new Uint8Array(memory(), destination >>> 0, mask.length).set(mask);
            return 1;
        },
        has_color(id, fixedPitch = 0) {
            if (fixedPitch === 3) return 3;
            const line = runs.get(id);
            if (fixedPitch === 2) {
                const source = line && fixedPitchSource(doc, line);
                if (!source) return 0;
                line.numericMaskSource = source;
                const key = fixedPitchStyleKey(line, source);
                if (!key) return 2;
                const existing = geometryTokens.get(key);
                if (existing !== undefined) return existing;
                if (nextGeometryToken >= 0x7fffffff) return 2;
                if (geometryTokens.size >= 64) geometryTokens.clear();
                const token = nextGeometryToken++;
                geometryTokens.set(key, token);
                return token;
            }
            if (fixedPitch) {
                if (!line) return 0;
                line.numericMaskSource = fixedPitchSource(doc, line);
                return line.numericMaskSource ? 2 : 0;
            }
            return line?.hasColor ? 1 : 0;
        },
        color(id, x, y, width, height, destination) {
            const line = runs.get(id);
            if (!line?.hasColor || width < 1 || height < 1) return 0;
            const { rgba } = coverage(line, x, y, width, height);
            new Uint8Array(memory(), destination >>> 0, rgba.length).set(rgba);
            return 1;
        },
        font_url(ptr, count, late) {
            if (doc?.fonts && count) requestFont(getMemory(), doc, string(ptr, count), Boolean(late));
        },
        font(ptr, count) {
            if (!doc?.fonts || !count) return 0;
            const bytes = new Uint8Array(memory(), ptr >>> 0, count >>> 0).slice();
            const info = fontDescriptor(bytes);
            if (!info) return 0;
            try {
                const face = new FontFace(info.family, bytes, info);
                if (face.status === 'error') return 0;
                const key = getMemory();
                const pending = pendingFonts.get(key) ?? [];
                function register() {
                    installFont(doc, { bytes, info, face }, { startup: !fontState(key, doc).presented });
                }
                // Make an already decoded face available immediately while waking Swift only
                // after its font-registration call has returned through the Wasm import.
                const ready = face.status === 'loaded' ? Promise.resolve(register()) : face.load().then(register);
                pending.push(ready.then(() => notifyFontChange(doc)).catch(error =>
                    console.warn('Rune could not register font ' + info.family, error)));
                pendingFonts.set(key, pending);
                return 1;
            } catch { return 0; }
        }
    };
}

export function runeTextFontsReady(memory) {
    const pending = pendingFonts.get(memory) ?? [];
    pendingFonts.delete(memory);
    const state = reactorFonts.get(memory);
    if (state?.eager.size) {
        pending.push(loadAppFonts(state.doc, state.eager, true));
        state.eager.clear();
    }
    return pending.length ? Promise.all(pending) : null;
}

function pageFonts(doc) {
    let page = fontPages.get(doc);
    if (!page) fontPages.set(doc, page = {
        changed: new Set(), urls: new Map(), colorFamilies: new Set(), appFamilies: new Set()
    });
    return page;
}

function notifyFontChange(doc) {
    for (const changed of pageFonts(doc).changed) changed();
}

function fontState(memory, doc) {
    let state = reactorFonts.get(memory);
    if (!state) reactorFonts.set(memory, state = { doc, eager: new Set(), late: new Set(), presented: false });
    return state;
}

async function fetchFace(url, family, weight) {
    const response = await fetch(url);
    if (!response.ok) throw new Error(url + ' returned HTTP ' + response.status);
    const bytes = new Uint8Array(await response.arrayBuffer());
    const info = family ? { family, weight, style: 'normal' } : fontDescriptor(bytes);
    if (!info) throw new Error('Unrecognized TrueType/OpenType font at ' + url);
    const [face, asciiFixedPitch] = await Promise.all([new FontFace(info.family, bytes, info).load(), isFixedPitchAsset(bytes)]);
    return { bytes, info, face, asciiFixedPitch };
}

function loadAppFonts(doc, requested, startup = false) {
    const { urls } = pageFonts(doc);
    const fresh = [...requested].filter(url => !urls.has(url));
    if (fresh.length) {
        // Parallel downloads, registration in declaration order, and one wake for the batch.
        const batch = Promise.all(fresh.map(url => fetchFace(url).catch(error => {
            console.warn('Rune could not load font ' + url, error);
            return null;
        }))).then(sources => {
            for (const source of sources) if (source) installFont(doc, source, { startup });
            if (sources.some(Boolean)) notifyFontChange(doc);
        });
        for (const url of fresh) urls.set(url, batch);
    }
    return Promise.all(new Set([...requested].map(url => urls.get(url))));
}

function requestFont(memory, doc, path, late) {
    let url;
    try { url = new URL(path, doc.baseURI).href; }
    catch (error) { console.warn('Rune could not resolve font ' + path, error); return; }
    const state = fontState(memory, doc);
    if (state.presented) {
        loadAppFonts(doc, [url]);
    } else {
        (late ? state.late : state.eager).add(url);
    }
}

function loadBundledFonts(doc, url, firstCut) {
    let loads = bundledFonts.get(doc);
    if (!loads) bundledFonts.set(doc, loads = new Map());
    const key = url.href + (firstCut ? '#first' : '');
    if (loads.has(key)) return loads.get(key);
    const inter = directory => interFiles.map((file, index) =>
        fetchFace(new URL(directory + file + '.ttf', url), 'Inter', String(400 + 100 * index)));
    const faces = [...inter(firstCut ? 'web/first/' : ''),
        fetchFace(new URL('IBMPlexMono-Regular.ttf', url), 'IBM Plex Mono', '400')];
    let full;
    const entry = {
        ready: Promise.all(faces).then(sources => {
            for (const source of sources) installFont(doc, source, { bundled: true, firstCut: firstCut && source.info.family === 'Inter' });
        }).catch(error => { loads.delete(key); throw error; }),
        complete() {
            if (!firstCut || full) return full;
            const { appFamilies } = pageFonts(doc);
            const sources = fontSources.get(doc)?.get('inter');
            if (appFamilies.has('inter') || !sources || ![...sources.values()].some(source => source.firstCut)) return;
            // Publish all three weights together, and keep every first cut on a failed download.
            full = Promise.all(inter('web/')).then(sources => {
                if (appFamilies.has('inter')) return;
                for (const source of sources) installFont(doc, source, { bundled: true });
                notifyFontChange(doc);
            }).catch(error => console.warn('Rune kept the first-cut Inter faces', error));
            return full;
        }
    };
    loads.set(key, entry);
    return entry;
}

export function mountRuneTextFonts(memory, doc, changed) {
    const state = fontState(memory, doc);
    const { changed: listeners } = pageFonts(state.doc);
    listeners.add(changed);
    return {
        presented() {
            state.presented = true;
            const ready = [state.bundle?.complete(), loadAppFonts(state.doc, state.late)];
            state.late.clear();
            return Promise.all(ready);
        },
        dispose() { listeners.delete(changed); state.presented = false; }
    };
}

// Supply the same WASI imports as for a regular reactor. Pass fontDirectory: null
// to use installed fonts and any FontFace instances already registered by the page.
export async function instantiateRuneBrowser(source, imports, {
    fontDirectory = defaultFontDirectory, document: doc = globalThis.document, spellDictionaries = []
} = {}) {
    let instance;
    const namespaces = { ...imports, rune_text: createRuneTextImports(() => instance.exports.memory, doc, spellDictionaries) };
    if (imports?.wasi_snapshot_preview1) {
        namespaces.wasi_snapshot_preview1 = withRunePageClock(imports.wasi_snapshot_preview1, () => instance?.exports.memory);
    }
    const data = await source;
    if (data instanceof Response && !data.ok) throw new Error('Rune reactor HTTP ' + data.status);
    const binary = data instanceof Response && data.headers.get('content-type')?.split(';')[0] !== 'application/wasm'
        ? await data.arrayBuffer() : data;
    const result = binary instanceof Response ? await WebAssembly.instantiateStreaming(binary, namespaces) :
        await WebAssembly.instantiate(binary, namespaces);
    instance = result.instance ?? result;
    if (doc?.fonts && fontDirectory) {
        const directory = new URL(fontDirectory, import.meta.url);
        // Reactors predating font invalidation and custom four-file bundles use full faces up front.
        const firstCut = directory.href === defaultFontDirectory.href && !!instance.exports.rune_web_fonts_changed;
        const state = fontState(instance.exports.memory, doc);
        state.bundle = loadBundledFonts(doc, directory, firstCut);
        await state.bundle.ready;
    }
    return { instance, module: result.module ?? (binary instanceof WebAssembly.Module ? binary : undefined) };
}
