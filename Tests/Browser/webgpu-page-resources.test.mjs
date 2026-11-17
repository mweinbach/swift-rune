import assert from 'node:assert/strict';
import test from 'node:test';
import { RuneWebGPU } from '../../Sources/Rune/Resources/Web/rune-webgpu.mjs';

// GPU allocation failure is driver-dependent. Exercise the transaction before any queue
// writes, including destruction of textures allocated earlier in the rejected transaction.
test('WebGPU atlas pages keep resident textures across patch, resize failure, and truncation', () => {
    const previous = globalThis.GPUTextureUsage;
    globalThis.GPUTextureUsage ??= { TEXTURE_BINDING: 4, COPY_DST: 2 };
    try {
        const allocated = [], writes = [];
        let failureWidth;
        const driver = Object.create(RuneWebGPU.prototype);
        driver.imagePages = [];
        driver.glyphPages = [];
        driver.device = {
            createTexture(descriptor) {
                if (descriptor.size[0] === failureWidth) throw Error('Allocation failed');
                const texture = { descriptor, destroyed: false, createView: () => ({}),
                    destroy() { this.destroyed = true; } };
                allocated.push(texture);
                return texture;
            },
            queue: { writeTexture(...args) { writes.push(args); } }
        };
        const full = (width, channels = 4) => ({ x: 0, y: 0, width, height: 1, full: true,
            data: new Uint8Array(width * channels) });
        const page = (width, update = null) => ({ width, height: width ? 1 : 0, update });
        const sync = (imagePages, glyphs = null, secondary = []) => driver.syncAtlases({ glyphPages: [page(1, glyphs), ...secondary], imagePages });
        sync([page(2, full(2)), page(0), page(3, full(3))], full(1, 1));
        const [glyph, image0, image2] = allocated;
        assert.equal(writes.length, 3);
        sync([page(2), page(0), page(3)]);
        assert.equal(writes.length, 3);
        const patch = { x: 1, y: 0, width: 1, height: 1, full: false, data: new Uint8Array([1, 2, 3, 4]) };
        sync([page(2), page(0), page(3, patch)]);
        assert.equal(allocated.length, 3);
        assert.equal(writes.length, 4);
        assert.deepEqual(writes.at(-1), [{ texture: image2, origin: [1, 0] }, patch.data, { bytesPerRow: 4 }, [1, 1]]);

        failureWidth = 6;
        assert.throws(() => sync([page(4, full(4)), page(6, full(6))]), /Allocation failed/);
        assert.equal(writes.length, 4);
        assert.equal(allocated.at(-1).destroyed, true);
        assert.equal(driver.imagePages[0].texture, image0);
        assert.equal(driver.imagePages[2].texture, image2);
        assert.equal(image0.destroyed || image2.destroyed, false);
        assert.throws(() => sync([page(2, patch), page(0), page(5)]), /Missing full/);
        assert.equal(writes.length, 4);

        sync([page(2)]);
        assert.equal(driver.imagePages.length, 1);
        assert.equal(image2.destroyed, true);
        assert.equal(image0.destroyed || glyph.destroyed, false);

        sync([page(2)], null, [page(3, full(3, 1))]);
        const mask = driver.glyphPages[1].texture;
        assert.equal(mask.descriptor.format, 'r8unorm');
        const glyphPatch = { x: 2, y: 0, width: 1, height: 1, full: false, data: new Uint8Array([128]) };
        const count = writes.length;
        assert.throws(() => sync([page(6, full(6))], null, [page(3, glyphPatch)]), /Allocation failed/);
        assert.equal(writes.length, count);
        sync([page(2)], null, [page(3, glyphPatch)]);
        assert.deepEqual(writes.at(-1), [{ texture: mask, origin: [2, 0] }, glyphPatch.data, { bytesPerRow: 1 }, [1, 1]]);
        sync([page(2)]);
        assert.equal(mask.destroyed, true);
        assert.equal(image0.destroyed || glyph.destroyed, false);
    } finally {
        if (previous === undefined) delete globalThis.GPUTextureUsage;
        else globalThis.GPUTextureUsage = previous;
    }
});
