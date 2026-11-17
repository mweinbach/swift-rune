import assert from 'node:assert/strict';
import { test } from 'node:test';
import { RuneInstanceUploads } from '../../Sources/Rune/Resources/Web/rune-instance-uploads.mjs';

function frame(count, backing = new Float32Array(count * 32)) {
    return {count, instances: backing.subarray(0, count * 32), paged: true, imagePages: [{}, {}], glyphPages: [{}, {}]};
}

function upload(state, scene, replaced = false) {
    const writes = [];
    state.prepare(scene, replaced, (first, end) => writes.push([first, end]));
    return writes;
}

test('ordinary uploads join nearby changed spans and preserve the reusable WASI memory', () => {
    const uploader = new RuneInstanceUploads(), buffer = new Float32Array(512 * 32);
    const scene = frame(384, buffer);
    assert.deepEqual(upload(uploader, scene, true), [[0, 384]]);
    assert.deepEqual(upload(uploader, scene), []);
    const bits = new Uint32Array(buffer.buffer);
    for (const [i, v] of [[61,0x80000000],[64,0x7fc01234],[128,0x7fc05678],[320,0xffffffff]]) bits[32*i+31] = v;
    assert.deepEqual(upload(uploader, scene), [[61,129],[320,321]]);
    bits[32*128+31] ^= 1;
    assert.deepEqual(upload(uploader, scene), [[128,129]]);
    assert.deepEqual(upload(uploader, frame(12, buffer)), []);
    assert.deepEqual(upload(uploader, frame(24, buffer)), [[12,24]]);
    assert.deepEqual(upload(uploader, frame(0, buffer)), []);
    assert.deepEqual(upload(uploader, frame(24, buffer)), [[0,24]]);
    assert.deepEqual(upload(uploader, frame(24, buffer), true), [[0,24]]);
});

test('page batches live across movement and cycle changes and clip to each layer or surface', () => {
    const state = new RuneInstanceUploads(), s = frame(12), indices = [1,4,8];
    for (const [j,i] of indices.entries()) {
        s.instances[i*32+17] = j === 1 ? 2 : 7;
        s.instances[i*32+(j === 1 ? 18 : 16)] = 1;
    }
    const batches = (first, count) => {
        const calls = [];
        state.forEachRun(first,count,(...args) => calls.push(args));
        return calls;
    };
    upload(state,s);
    const initial = state.runs;
    assert.deepEqual(batches(2,0), []);
    assert.deepEqual(batches(2,8), [[2,2,1,0],[4,4,0,1],[8,2,1,0]]);
    s.instances[2*32] = 5;
    upload(state,s);
    assert.equal(state.runs,initial);
    const patch = {...s, cycleRuns: [[2,3]]};
    s.instances[2*32+19] = 0.5;
    assert.deepEqual(upload(state, patch), [[2,3]]);
    assert.deepEqual(upload(state, patch), []);
    assert.deepEqual(upload(state,s), []);
    assert.equal(state.runs,initial);
    s.instances[4*32+18] = 0;
    assert.deepEqual(upload(state,s), [[4,5]]);
    assert.deepEqual(batches(2,8), [[2,8,1,0]]);
    s.imagePages.length = 1;
    assert.deepEqual(upload(state,s), []);
    assert.deepEqual(batches(2,8), [[2,8,-1,0]]);
    s.paged = false;
    assert.deepEqual(upload(state,s), []);
    assert.deepEqual(batches(2,8), [[2,8,0,0]]);
});

test('a failed queue write forces the next frame to repopulate the buffer', () => {
    const state = new RuneInstanceUploads(), s = frame(256);
    upload(state,s);
    s.instances[32+1] = 1;
    s.instances[200*32+1] = 2;
    assert.throws(() => state.prepare(s, false, (first) => { if (first === 200) throw Error('device lost'); }), /lost/);
    assert.deepEqual(upload(state,s), [[0,256]]);
});
