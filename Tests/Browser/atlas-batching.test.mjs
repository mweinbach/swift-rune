import {test} from 'node:test';
import assert from 'node:assert/strict';
import {forEachAtlasPageRun} from '../../Sources/Rune/Resources/Web/rune-web-packet.mjs';

test('only image and glyph binding changes split ordinary primitive runs', () => {
    // render/upload/tests.rs::batches_break_only_where_the_bound_page_changes
    const primitives = [[0], [7,1], [0], [1], [2,0,2], [3], [2], [0], [7,1]];
    const stream = new Float32Array(32 * primitives.length);
    for (const [i, [kind, image = 0, glyph = 0]] of primitives.entries()) {
        stream.set([image,kind,glyph], i * 32 + 16);
    }
    const runs = [];
    forEachAtlasPageRun(stream,0,primitives.length,2,3,(first,count,image,glyph) =>
        runs.push([first,first+count,glyph ? ['g',glyph-1] : ['i',image]]));
    assert.deepEqual(runs, [[0,1,['i',0]], [1,4,['i',1]], [4,6,['g',1]], [6,8,['i',0]], [8,9,['i',1]]]);
});

test('unknown glyph pages select the base glyph and missing images stay transparent', () => {
    const stream = new Float32Array(5 * 32);
    for (const [i, params] of [[1,7,0],[0,2,0],[0,2,12],[8,7,0],[-1,7,0]].entries()) {
        stream.set(params, i * 32 + 16);
    }
    const actual = [];
    forEachAtlasPageRun(stream,0,5,2,2,(...run) => actual.push(run));
    assert.deepEqual(actual, [[0,2,1,0],[2,1,0,0],[3,1,-1,0],[4,1,0,0]]);
});
