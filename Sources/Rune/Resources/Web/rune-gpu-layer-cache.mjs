function keyLanes(lanes, start) {
    let value = 0n;
    for (let i = 3; i >= 0; --i) {
        const lane = Math.min(65535, Math.max(0, Math.round(lanes[start + i])));
        value = (value << 16n) | BigInt(lane);
    }
    return value;
}

function cacheRect(marker) {
    const x = Math.floor(marker[0]), y = Math.floor(marker[1]);
    return [x, y, Math.ceil(marker[0] + marker[2]) - x, Math.ceil(marker[1] + marker[3]) - y];
}

// Map iteration is least- to most-recently used. A texture referenced anywhere in
// this frame must survive admissions: the reactor may already have omitted its draws.
export class LayerCache {
    constructor(bytesPerPixel, capture, release) {
        this.bytesPerPixel = bytesPerPixel;
        this.capture = capture;
        this.release = release;
        this.entries = new Map();
        this.budget = 64 * 1024 * 1024;
        this.bytes = 0;
        this.hits = 0;
        this.dirty = true;
    }

    begin(instances) {
        this.pinned = new Set();
        if (!this.entries.size) return;
        for (let i = 0; i < instances.length; i += 32) {
            if (instances[i + 17] !== 8 || instances[i + 19] < 0.5) continue;
            const entry = this.entries.get(keyLanes(instances, i + 4));
            if (entry && entry.signature === keyLanes(instances, i + 20)) this.pinned.add(entry);
        }
    }

    lookup(marker) {
        const key = keyLanes(marker, 4), entry = this.entries.get(key);
        if (!entry || entry.signature !== keyLanes(marker, 20)) return null;
        this.entries.delete(key);
        this.entries.set(key, entry);
        ++this.hits;
        // A moving or scaled layer samples the original texture at its current bounds.
        const [x, y, width, height] = cacheRect(marker);
        return { ...entry.target, x, y, width, height };
    }

    store(marker, source) {
        const [x, y, w, h] = cacheRect(marker);
        if (w < 1 || h < 1 || w > 4096 || h > 4096
            || x < source.x || y < source.y || x + w > source.x + source.width || y + h > source.y + source.height) return;
        const bytes = w * h * this.bytesPerPixel;
        if (bytes > this.budget) return;
        const key = keyLanes(marker, 4), signature = keyLanes(marker, 20);
        const old = this.entries.get(key);
        if (old) {
            if (this.pinned.has(old)) return;
            this.evict(key, old);
        }
        for (const [id, entry] of this.entries) {
            if (this.bytes + bytes <= this.budget) break;
            if (!this.pinned.has(entry)) this.evict(id, entry);
        }
        if (this.bytes + bytes > this.budget) return;
        const target = this.capture(source, x, y, w, h);
        const entry = { signature, target, bytes };
        this.entries.set(key, entry);
        this.pinned.add(entry);
        this.bytes += bytes;
        this.dirty = true;
    }

    evict(key, entry) {
        this.release(entry.target);
        this.entries.delete(key);
        this.bytes -= entry.bytes;
        this.dirty = true;
    }

    clear() {
        for (const [key, entry] of this.entries) this.evict(key, entry);
    }

    takeChanges(full) {
        if (!full && !this.dirty) return null;
        const words = new Uint32Array(this.entries.size * 4);
        let i = 0;
        for (const [key, { signature }] of this.entries) {
            for (const value of [key, signature]) {
                words[i++] = Number(value & 0xffffffffn);
                words[i++] = Number(value >> 32n);
            }
        }
        this.dirty = false;
        return words;
    }
}
