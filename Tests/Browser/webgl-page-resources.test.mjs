import {test} from 'node:test';
import assert from 'node:assert/strict';
import {RuneWebGL} from '../../Sources/Rune/Resources/Web/rune-webgl.mjs';

test('WebGL atlas allocation failure preserves both resident banks for retry', () => {
    const driver = Object.create(RuneWebGL.prototype);
    const oldGlyph = {texture:{id:'mask'},width:1,height:1};
    const oldImage = {texture:{id:'photo'},width:1,height:1};
    driver.glyphPages = [oldGlyph]; driver.imagePages = [oldImage];
    let allowed = 1;
    const allocated = [], deleted = [], writes = [];
    driver.gl = {
        R8:1, RED:2, SRGB8_ALPHA8:3, RGBA:4, NO_ERROR:0, getError:() => 0,
        createTexture() {
            if (!allowed--) return null;
            const texture = {id:allocated.length};
            allocated.push(texture);
            return texture;
        },
        deleteTexture(texture) {deleted.push(texture);}
    };
    driver.atlas = (atlas, width, height, internal, _format, update) => {
        writes.push([atlas,update]);
        Object.assign(atlas,{width,height,internal});
    };
    const nextGlyphs = [{width:1,height:1,update:{full:false}}, {width:3,height:1,update:{full:true}}];
    const nextImages = [{width:3,height:1,update:{full:true}}];
    assert.throws(() => driver.syncAtlases(nextGlyphs,nextImages), /Could not allocate/);
    assert.equal(driver.glyphPages[0],oldGlyph);
    assert.equal(driver.imagePages[0],oldImage);
    assert.deepEqual(deleted,allocated);
    assert.ok(writes.every(([atlas]) => atlas !== oldGlyph && atlas !== oldImage));
    allowed = 2;
    driver.syncAtlases(nextGlyphs,nextImages);
    assert.deepEqual(deleted,[allocated[0],oldImage.texture]);
    assert.equal(driver.glyphPages[0],oldGlyph);
    assert.equal(driver.glyphPages[1].texture,allocated[1]);
    assert.equal(driver.imagePages[0].texture,allocated[2]);
    assert.deepEqual(writes.at(-1),[oldGlyph,nextGlyphs[0].update]);
});
