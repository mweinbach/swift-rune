import { forEachAtlasPageRun } from './rune-web-packet.mjs';

const wordsPerInstance = 32, block = 64;

// Compare the wire bits, including signed zeros and unpublished float representations
// in effect payloads. The WASI buffer may be reused for input immediately after draw.
function equalInstance(a, b, index) {
    const end = (index + 1) * wordsPerInstance;
    for (let i = end - wordsPerInstance; i < end; i++) if (a[i] !== b[i]) return false;
    return true;
}

function bindingChanged(a, b, first, end) {
    for (let i = first * wordsPerInstance; i < end * wordsPerInstance; i += wordsPerInstance) {
        const kind = b[i + 17];
        if (a[i + 17] !== kind || (kind === 7 && a[i + 16] !== b[i + 16]) ||
            (kind === 2 && a[i + 18] !== b[i + 18])) return true;
    }
    return false;
}

export class RuneInstanceUploads {
    constructor() {
        this.snapshot = new Uint32Array(0);
        this.heldFloats = new Float32Array(this.snapshot.buffer);
        this.count = 0;
        this.imageCount = 0;
        this.glyphCount = 0;
        this.runs = null;
    }

    // upload receives a half-open range of instance indices. The driver allocates its
    // GPU buffer first and sets replaced if its previous contents cannot be reused.
    prepare(scene, replaced, upload) {
        const {instances, count, cycleRuns} = scene;
        const imageCount = scene.paged ? scene.imagePages.length : 0;
        const glyphCount = scene.paged ? scene.glyphPages.length : 0;
        let rebatch = count !== this.count || imageCount !== this.imageCount || glyphCount !== this.glyphCount;
        const incoming = new Uint32Array(instances.buffer, instances.byteOffset, instances.length);
        if (incoming.length > this.snapshot.length) {
            // A growing CPU snapshot is seeded in one write along with the GPU allocation.
            this.snapshot = new Uint32Array(2 ** Math.ceil(Math.log2(incoming.length)));
            this.heldFloats = new Float32Array(this.snapshot.buffer);
            replaced = true;
        }
        const held = this.snapshot;
        const oldFloats = this.heldFloats;
        const write = (first, end) => {
            upload(first, end);
            if (imageCount && !rebatch && !cycleRuns) rebatch = bindingChanged(oldFloats, instances, first, end);
            const start = first * wordsPerInstance;
            held.set(incoming.subarray(start, end * wordsPerInstance), start);
        };
        try {
            if (replaced || this.count === 0) {
                if (count) write(0, count);
            } else if (cycleRuns) {
                // The negotiated cycle packet guarantees all other instances are unchanged.
                for (const [begin, end] of cycleRuns) {
                    let first = begin;
                    while (first < end && equalInstance(held, incoming, first)) first++;
                    if (first < end) write(first, end);
                }
            } else {
                const shared = Math.min(this.count, count);
                let begin = -1, last = 0;
                const join = (first, end) => {
                    if (begin >= 0 && first > last + block) {
                        write(begin, last);
                        begin = -1;
                    }
                    if (begin < 0) begin = first;
                    last = end;
                };
                // For a block where every item moves, only its ends need comparing.
                for (let start = 0; start < shared; start += block) {
                    let first = start, end = Math.min(start + block, shared);
                    while (first < end && equalInstance(held, incoming, first)) first++;
                    if (first === end) continue;
                    while (end > first + 1 && equalInstance(held, incoming, end - 1)) end--;
                    join(first, end);
                }
                if (count > shared) join(shared, count);
                if (begin >= 0) write(begin, last);
            }
            if (rebatch) {
                this.runs = null;
                if (imageCount) {
                    const runs = [];
                    forEachAtlasPageRun(instances, 0, count, imageCount, glyphCount,
                        (first, length, image, glyph) => runs.push({first, end: first + length, image, glyph}));
                    this.runs = runs;
                }
            }
            this.count = count;
            this.imageCount = imageCount;
            this.glyphCount = glyphCount;
        } catch (error) {
            // Some queue writes may have succeeded. Retry every live byte on the next frame.
            this.count = 0;
            this.runs = null;
            throw error;
        }
    }

    // Layers, damage and surface insertion cut the frame at arbitrary indices.
    // Intersect just the resident runs covering that slice.
    forEachRun(first, count, draw) {
        if (!count) return;
        if (!this.runs) {
            draw(first, count, 0, 0);
            return;
        }
        const end = first + count, runs = this.runs;
        let lo = 0, hi = runs.length;
        while (lo < hi) {
            const mid = Math.floor((lo + hi) / 2);
            if (runs[mid].end <= first) lo = mid + 1;
            else hi = mid;
        }
        for (let i = lo; i < runs.length && runs[i].first < end; i++) {
            const run = runs[i], start = Math.max(first, run.first);
            draw(start, Math.min(end, run.end) - start, run.image, run.glyph);
        }
    }
}
