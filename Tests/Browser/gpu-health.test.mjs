import assert from 'node:assert/strict';
import test from 'node:test';
import { compilePipeline, gpuSummary, scopedGPU, watchGPU } from '../../Sources/Rune/Resources/Web/rune-webgpu-health.mjs';

function mockDevice() {
    const device = new EventTarget();
    device.lost = new Promise(resolve => { device.lose = resolve; });
    device.adapterInfo = {vendor: 'test vendor', architecture: 'test chip', isFallbackAdapter: true};
    device.limits = {maxTextureDimension2D: 8192};
    return device;
}

test('each WebGPU device reports four distinct errors, mutes on the fifth and reports unexpected loss', async () => {
    const device = mockDevice(), lines = [], reasons = [];
    const summary = gpuSummary(device);
    const stop = watchGPU(device, summary, r => reasons.push(r), s => lines.push(s));
    function emit(message) {
        const event = new Event('uncapturederror', {cancelable: true});
        event.error = Error(message);
        device.dispatchEvent(event);
        return event.defaultPrevented;
    }
    assert.equal(emit('first'), true);
    emit('first');
    for (const msg of ['two', 'three', 'four', 'five', 'six']) emit(msg);
    assert.equal(lines.length, 5);
    assert.match(lines[0], /test vendor, test chip, fallback adapter, max texture 8192/);
    assert.match(lines[4], /further GPU errors/);
    device.lose({reason: 'unknown', message: 'unplugged'});
    await device.lost;
    assert.match(reasons[0], /unknown: unplugged, on test vendor/);
    stop();
    assert.equal(emit('after disposal'), false);
    for (const intentional of [true, false]) {
        const other = mockDevice();
        const end = watchGPU(other, '', r => reasons.push(r));
        if (!intentional) end();
        other.lose({reason: intentional ? 'destroyed' : 'unknown', message: ''});
        await other.lost;
        end();
    }
    assert.equal(reasons.length, 1);
});

test('WebGPU scopes pop in stack order on success and failure, surfacing internal errors', async () => {
    const pushed = [], popped = [];
    let caught;
    const device = {pushErrorScope: filter => pushed.push(filter), popErrorScope() {
        const filter = pushed.pop();
        popped.push(filter);
        return Promise.resolve(filter === 'internal' ? caught : null);
    }};
    assert.equal(await scopedGPU(device, () => 42), 42);
    caught = Error('shader cache invalid');
    await assert.rejects(scopedGPU(device, () => 0), /shader cache invalid/);
    caught = null;
    await assert.rejects(scopedGPU(device, () => { throw Error('startup'); }), /startup/);
    assert.deepEqual(popped, Array(3).fill(['internal','out-of-memory','validation']).flat());
});

test('WebGPU warms async pipelines when available and can start on older sync-only devices', async () => {
    const seen = [];
    const device = {createRenderPipeline: n => seen.push('sync ' + n),
        createRenderPipelineAsync: n => Promise.resolve(seen.push('async ' + n))};
    await compilePipeline(device, 'first');
    delete device.createRenderPipelineAsync;
    await compilePipeline(device, 'second');
    assert.deepEqual(seen, ['async first','sync second']);
});
