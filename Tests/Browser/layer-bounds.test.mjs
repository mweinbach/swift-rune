import assert from 'node:assert/strict';
import test from 'node:test';
import { planLayerRects } from '../../Sources/Rune/Resources/Web/rune-webgl-layers.mjs';

function instance(kind, rect = [0, 0, 0, 0], options = {}) {
    const p = new Float32Array(32);
    p.set(rect);
    p[11] = options.opacity ?? 0.75;
    p[13] = options.angle ?? 0;
    p[14] = options.pivot?.[0] ?? 0;
    p[15] = options.pivot?.[1] ?? 0;
    p[16] = options.glyphAngle ?? 0;
    p[17] = kind;
    p[18] = options.blur ?? 0;
    p[19] = options.cached ? 1 : 0;
    p.set(options.clip ?? [-1e6, -1e6, 1e6, 1e6], 24);
    return p;
}

function plan(instances, surfaces = []) {
    const packed = new Float32Array(instances.length * 32);
    instances.forEach((instance, i) => packed.set(instance, i * 32));
    return [...planLayerRects(packed, 64, 48, surfaces)];
}

const end = instance(9);

// These rects are also produced by LayersPool.preparePlan on Metal.
test('content outside the viewport can rotate or blur into view', () => {
    assert.deepEqual(plan([instance(8, undefined, { angle: Math.PI / 2 }),
        instance(0, [10, -28, 8, 10]), end]), [[0, [9, -29, 10, 12]]]);
    assert.deepEqual(plan([instance(8, undefined, { blur: 3 }), instance(0, [-7, 14, 4, 4]), end]),
        [[0, [-9, 4, 16, 24]]]);
});

test('nested groups intersect clips and propagate their post-rotation extent', () => {
    const records = [
        instance(8, undefined, { angle: 0.57, pivot: [20, 12], clip: [0, 3, 38, 29] }),
        instance(8, undefined, { angle: -1.1, pivot: [18, 12], blur: 4 }),
        instance(1, [-7, -9, 33, 20], { blur: 1.1 }), end, end,
    ];
    assert.deepEqual(plan(records), [[0, [-2, -6, 46, 44]], [1, [-24, -26, 67, 54]]]);
    assert.deepEqual(plan([instance(8), instance(2, [8.4, 10.3, 22.2, 5.1], { glyphAngle: 0.86 }), end]),
        [[0, [10, 2, 19, 21]]]);
});

test('cached layers retain full bounds when visible and fall back for an oversized target', () => {
    const records = [
        instance(8, [-10, -11, 40, 50], { cached: true }), instance(0, [42, 44, 5, 6]), end,
        instance(8, [-15, -27, 5002, 255], { cached: true }), end,
        instance(8, [-83, -90, 22, 33], { cached: true }), end,
    ];
    assert.deepEqual(plan(records), [[0, [-10, -11, 40, 50]], [3, [0, 0, 64, 48]], [5, [0, 0, 0, 0]]]);
});

test('a surface before a layer end contributes its clipped pixel bounds', () => {
    const uniforms = new Float32Array(52);
    uniforms.set([4.5, 5.5, 10, 20], 4);
    uniforms.set([6.5, 0, 8.5, 26], 16);
    const records = [instance(8), end];
    assert.deepEqual(plan(records, [{ before: 1, uniforms }]), [[0, [6, 5, 3, 21]]]);
    assert.deepEqual(plan(records, [{ before: 0xffffffff, uniforms }]), [[0, [0, 0, 0, 0]]]);
});
