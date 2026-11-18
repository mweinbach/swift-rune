// The shipped IBM Plex Mono regular face maps U+0020...007E to one advancing
// glyph each (600/1000 em). Its default GSUB rules need a non-ASCII input or
// context and its GPOS lookups only attach marks. A font with the same CSS
// name, including a replacement at the configured font URL, needs native layout.
const plexMonoDigest = 'fe11304a5fe956d5744e9b6a246cc83d90425245e75a62230044966ca96a7f50';

export async function isFixedPitchAsset(bytes) {
    if (bytes.byteLength !== 155940 || !globalThis.crypto?.subtle) return false;
    try {
        const sha = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
        return Array.from(sha, byte => byte.toString(16).padStart(2, '0')).join('') === plexMonoDigest;
    } catch { return false; }
}

export function writeFixedPitchCells(styles, key, length, ints, floats, reportSource, measure) {
    // Keep multi-grapheme selections and ligature owners on the general path.
    for (let i = 0; i < ints.length; i += 7) {
        if (ints[i] < 0 || ints[i + 1] > length || ints[i + 1] !== ints[i] + 1) return false;
    }
    let positions = styles.get(key);
    if (!positions) {
        if (styles.size >= 32) styles.delete(styles.keys().next().value);
        styles.set(key, positions = []);
    }
    // A selected cell can be wider than the distance between editing carets.
    // Learn each quantity independently from a real DOM Range at this index.
    for (let i = 0; i < ints.length; i += 7) {
        const start = ints[i];
        const cell = positions[start] ??= measure(start);
        floats[i + 2] = cell[0];
        floats[i + 3] = cell[1];
        floats[i + 4] = cell[2];
        floats[i + 5] = cell[3];
        ints[i + 6] = cell[1] ? (reportSource ? 2 : 1) : 0;
    }
    return true;
}
