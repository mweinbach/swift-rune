import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { createRuneSpellImports, mountRuneSpelling } from '../../Sources/Rune/Resources/Web/rune-web-spell.mjs';

test('per-reactor dictionary selection, late loads, scoped learning and teardown', async t => {
    const utf8 = new TextEncoder();
    const decode = new TextDecoder();
    const baseURI = 'https://rune.test/app/index.html';
    const doc = { baseURI, defaultView: { navigator: { languages: ['de-AT', 'en-US'] } } };
    const resources = new URL('../../Sources/Rune/Resources/Web/', import.meta.url);
    const pending = new Map();
    const requests = [];
    t.mock.method(globalThis, 'fetch', async (url, options) => {
        if (url.protocol === 'file:') return new Response(await readFile(new URL('rune-spellbook.wasm', resources)));
        requests.push(url.pathname);
        const path = url.pathname.split('/').pop();
        if (path.startsWith('failed.')) return new Response(null, { status: 404 });
        if (pending.has(path)) await pending.get(path).promise;
        if (options.signal.aborted) throw new DOMException('Aborted', 'AbortError');
        return new Response(await readFile(new URL('./spell/' + path, import.meta.url)));
    });
    t.mock.method(console, 'warn', () => {});
    function instance() {
        const memory = new WebAssembly.Memory({ initial: 1 });
        const api = createRuneSpellImports(() => memory, doc, ['de', 'en-US']);
        let wakes = 0;
        const mount = () => mountRuneSpelling(memory, doc, () => wakes++);
        const dispose = mount();
        const call = (op, input = '') => {
            const bytes = utf8.encode(input);
            new Uint8Array(memory.buffer, 0, bytes.length).set(bytes);
            const length = api.spell_request(op, 0, bytes.length);
            api.spell_read(0, length);
            return new Uint8Array(memory.buffer, 0, length).slice();
        };
        return { mount, dispose, wakeCount: () => wakes,
            available: () => JSON.parse(decode.decode(call(0))),
            preferred: () => JSON.parse(decode.decode(call(1))),
            select: tags => call(2, JSON.stringify(tags)),
            ranges(text) {
                const result = call(3, text);
                return [...new Uint32Array(result.buffer)];
            },
            suggest: word => JSON.parse(decode.decode(call(4, word))),
            learn: word => call(5, word), ignore: word => call(6, word) };
    }
    async function waitFor(predicate) {
        for (let step = 0; step < 200; ++step) {
            if (predicate()) return;
            await new Promise(resolve => setTimeout(resolve, 10));
        }
        assert.fail('dictionary readiness timeout');
    }
    const first = instance();
    assert.deepEqual(first.preferred(), ['de-AT', 'en-US']);
    assert.deepEqual(first.available(), ['de', 'en-US']);
    first.select(['de', 'en-US', 'failed']);
    assert.equal(requests.length, 0);
    const sample = '🐾 cafés walking Kinder teh grüßen\nuser@thing foo_bar HTTP /file qqqzz';
    assert.deepEqual(first.ranges(sample), []);
    await waitFor(() => first.wakeCount() === 3);
    const offsets = [...sample.matchAll(/teh|qqqzz/g)].flatMap(({ 0: word, index }) => {
        const start = utf8.encode(sample.slice(0, index)).length;
        return [start, start + word.length];
    });
    assert.deepEqual(first.ranges(sample), offsets);
    assert.deepEqual(first.ranges(sample), offsets);
    assert.ok(first.suggest('teh').includes('the'));
    first.learn('qqqzz');
    first.ignore('teh');
    assert.deepEqual(first.ranges(sample), []);
    first.select(['de']);
    assert.deepEqual(first.ranges('walking'), [0, 7]);
    const other = instance();
    other.select(['en-US']);
    assert.deepEqual(other.ranges('qqqzz'), []);
    await waitFor(() => other.wakeCount() === 1);
    assert.deepEqual(other.ranges('qqqzz'), [0, 5]);

    // The last listener can close while both parts are fetching. A reopened
    // window registers its own fetch and sees only that readiness notification.
    other.dispose();
    let resume;
    const gate = { promise: new Promise(resolve => { resume = resolve; }) };
    pending.set('en-US.dic', gate);
    let close = other.mount();
    assert.deepEqual(other.ranges('qqqzz'), []);
    close();
    close = other.mount();
    assert.deepEqual(other.ranges('qqqzz'), []);
    resume();
    await waitFor(() => other.wakeCount() === 2);
    assert.deepEqual(other.ranges('qqqzz'), [0, 5]);
    other.learn('newword');
    other.select(['de']);
    assert.deepEqual(other.ranges('newword Fehlwort'), []);
    await waitFor(() => other.wakeCount() === 3);
    assert.deepEqual(other.ranges('newword Fehlwort'), [8, 16]);
    close();
    first.dispose();
    assert.equal(requests.filter(url => url.includes('/app/spell/failed.')).length, 2);
});
