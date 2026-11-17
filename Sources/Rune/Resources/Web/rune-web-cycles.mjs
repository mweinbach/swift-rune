import {decodeRuneScene} from './rune-web-packet.mjs';
import {primitiveBounds} from './rune-webgl-layers.mjs';

const fullMagic = 0x32475352, pagedMagic = 0x33475352, cycleMagic = 0x31435352;

function merge(a, b) {
    return [Math.min(a[0], b[0]), Math.min(a[1], b[1]), Math.max(a[2], b[2]), Math.max(a[3], b[3])];
}

function near(a, b, margin) {
    return a[0] <= b[2] + margin && a[1] <= b[3] + margin && b[0] <= a[2] + margin && b[1] <= a[3] + margin;
}

// Rectangles and submission ranges stay fixed for every sample of one paint.
function damagePlan(scene, slots) {
    const areas = [];
    for (const [first, end] of slots) for (let i = first; i < end; ++i) {
        const b = primitiveBounds(scene.instances, i);
        let area = [Math.max(0, Math.floor(b[0]) - 2), Math.max(0, Math.floor(b[1]) - 2),
            Math.min(scene.width, Math.ceil(b[2]) + 2), Math.min(scene.height, Math.ceil(b[3]) + 2)];
        if (area[0] >= area[2] || area[1] >= area[3]) continue;
        let other;
        while ((other = areas.findIndex(r => near(r, area, 8))) >= 0) area = merge(area, areas.splice(other, 1)[0]);
        areas.push(area);
    }
    while (areas.length > 4) areas.push(merge(areas.pop(), areas.pop()));
    const plan = areas.map(area => ({area, runs: []}));
    let afterLayer = 0;
    for (let i = 0; i < scene.count; ++i) {
        let b = primitiveBounds(scene.instances, i);
        if (scene.instances[i * 32 + 17] === 8) {
            let depth = 1;
            while (++i < scene.count) {
                const kind = scene.instances[i * 32 + 17];
                if (kind === 9) {
                    if (--depth === 0) break;
                } else {
                    if (kind === 8) ++depth;
                    const item = primitiveBounds(scene.instances, i);
                    if (item[2] > item[0] && item[3] > item[1]) b = merge(b, item);
                }
            }
            // A hit layer needs its compositor. A miss preserves its previous pixels,
            // even when there are many layers elsewhere in the scene.
            if (depth || areas.some(area => near(b, area, 2))) return null;
            afterLayer = i + 1;
            continue;
        }
        for (const {area, runs} of plan) if (near(b, area, 2)) {
            const last = runs.at(-1);
            if (last && last[1] >= afterLayer && i - last[1] <= 16) last[1] = i + 1;
            else runs.push([i, i + 1]);
        }
    }
    return plan;
}

// The ordinary packet refers into WASM's reusable response buffer. Keep owned bytes only
// for a paint the runtime can advance while every other part of the window rests.
export class RuneCycleScene {
    decode(memory, pointer, length, maxSize, atlasSequence) {
        const packet = new DataView(memory, pointer, length);
        const magic = length >= 4 ? packet.getUint32(0, true) : 0;
        if (magic === cycleMagic) return this.patch(packet);
        const marked = (magic === fullMagic || magic === pagedMagic) && length >= 60 && (packet.getUint32(12, true) & 64);
        this.kept = null;
        const scene = decodeRuneScene(memory, pointer, length - (marked ? 4 : 0), maxSize, atlasSequence);
        if (marked) {
            if (scene.surfaces.length) throw Error('Invalid surface in retained Rune cycle paint');
            this.serial = packet.getUint32(length - 4, true);
            // Filters and turns change pixels beyond an ordinary quad's bounds.
            scene.retainCycleTarget = scene.clear[3] === 1;
            for (let base = 17; scene.retainCycleTarget && base < scene.instances.length; base += 32) {
                const kind = scene.instances[base];
                if (kind >= 12 || (kind === 8 && (scene.instances[base - 4] !== 0 ||
                    scene.instances[base + 1] > 0.05))) scene.retainCycleTarget = false;
            }
            this.plan = null;
            this.planSlots = null;
            this.kept = {...scene, instances: scene.instances.slice(), clear: scene.clear.slice(),
                glyphs: null, images: null, glyphPages: scene.glyphPages.map(page => ({...page, update: null})),
                imagePages: scene.imagePages.map(page => ({...page, update: null})), duplicate: true};
        }
        return scene;
    }

    patch(packet) {
        const kept = this.kept;
        if (!kept || packet.byteLength < 24 || packet.getUint32(4, true) !== kept.width ||
            packet.getUint32(8, true) !== kept.height || packet.getUint32(12, true) !== this.serial ||
            packet.getUint32(16, true) !== kept.count) throw Error('Missing matching Rune cycle paint');
        const count = packet.getUint32(20, true);
        if (!count || count > kept.count || packet.byteLength !== 24 + count * 24)
            throw Error('Invalid Rune cycle patch length');
        const words = new Uint32Array(packet.buffer, packet.byteOffset + 24, count * 6);
        const floats = new Float32Array(words.buffer, words.byteOffset, words.length);
        const runs = [];
        let previous = -1;
        // Validate every record before modifying the retained scene.
        for (let i = 0; i < words.length; i += 6) {
            const index = words[i];
            if (index <= previous || index >= kept.count || kept.instances[index * 32 + 17] !== 0 ||
                !floats.subarray(i + 1, i + 6).every(Number.isFinite))
                throw Error('Invalid Rune cycle slot');
            if (index === previous + 1 && runs.length) runs.at(-1)[1]++;
            else runs.push([index, index + 1]);
            previous = index;
        }
        for (let i = 0; i < words.length; i += 6) {
            const base = words[i] * 32;
            kept.instances.set(floats.subarray(i + 1, i + 5), base + 8);
            kept.instances[base + 19] = floats[i + 5];
        }
        if (kept.retainCycleTarget && (!this.planSlots || runs.length !== this.planSlots.length ||
            runs.some(([a,b], i) => a !== this.planSlots[i][0] || b !== this.planSlots[i][1]))) {
            this.plan = damagePlan(kept, runs);
            this.planSlots = runs;
        }
        return {...kept, cycleRuns: runs, damage: kept.retainCycleTarget ? this.plan : null};
    }
}
