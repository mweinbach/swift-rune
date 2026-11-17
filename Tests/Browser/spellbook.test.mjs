import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { loadSpellbook } from '../../Sources/Rune/Resources/Web/rune-spellbook.mjs';

const url = new URL('../../Sources/Rune/Resources/Web/rune-spellbook.wasm', import.meta.url);
const rules = `SET UTF-8
TRY esiarntolcdugmphbyfvkwzxjqé
COMPOUNDMIN 3
COMPOUNDFLAG C
SFX S Y 1
SFX S 0 s .
`;
const words = '5\ncafé/S\nbook/SC\nshelf/C\nshell\nsell\n';

test('Hunspell morphology, compounds, suggestions and per-dictionary learning', async () => {
    const module = await WebAssembly.compile(await readFile(url));
    assert.deepEqual(WebAssembly.Module.imports(module), []);
    const engine = await loadSpellbook(module);
    const english = engine.dictionary(rules, words);
    const filter = engine.dictionary(rules, '1\ncabinet/S\n');
    const other = (await loadSpellbook(module)).dictionary(rules, words);
    try {
        assert.equal(english.check('cafés'), true);
        assert.equal(english.check('bookshelf'), true);
        assert.equal(english.check('books'), true);
        assert.equal(english.check('shelfs'), false);
        assert.equal(english.check('bok'), false);
        assert.ok(english.suggest('bok').includes('book'));
        assert.equal(english.add('RuneKit'), true);
        assert.equal(english.check('RuneKit'), true);
        assert.equal(other.check('RuneKit'), false);
        assert.equal(filter.check('bookshelf'), false);
        assert.equal(filter.check('cabinets'), true);
    } finally {
        english.free();
        other.free();
        filter.free();
    }
    english.free();
    const replacement = engine.dictionary(rules, words);
    assert.throws(() => english.check('book'), /released/);
    assert.equal(replacement.check('RuneKit'), false);
    replacement.free();
});

test('invalid dictionary and UTF-8 errors leave a live engine usable across memory growth', async () => {
    const engine = await loadSpellbook(await readFile(url));
    const live = engine.dictionary(rules, words);
    try {
        assert.throws(() => engine.dictionary(Uint8Array.of(0xff), ''), /UTF-8/);
        assert.throws(() => engine.dictionary('FLAG invalid\n', words));
        const dictionary = Array.from({ length: 30_000 }, (_, i) => 'longentry' + i).join('\n');
        const large = engine.dictionary(new TextEncoder().encode(rules), '30000\n' + dictionary);
        try {
            assert.equal(live.check('cafés'), true);
            assert.ok(live.suggest('bok').includes('book'));
            assert.equal(large.check('longentry29999'), true);
        } finally {
            large.free();
        }
    } finally {
        live.free();
    }
});

test('Rune prose ranges use the pinned Unicode boundaries and survive subsequent engine calls', async () => {
    const engine = await loadSpellbook(await readFile(url));
    const dictionary = engine.dictionary(rules, words);
    // Produced by Rune's Rust spell/web.rs with unicode-segmentation 1.13.3.
    const cases = [
        ['🙂 Hélas l’école naïve Über next-word. a NASA LinkedIn web2 code_path an@host ok',
            [5, 11, 12, 22, 23, 29, 30, 35, 36, 40, 41, 45, 86, 88]],
        ['漢字東京 日本語 カタカナ ภาษาไทย สวัสดี สะกด 運転 🚕 café',
            [23, 35, 61, 67, 70, 76, 102, 107]],
        ["10km pre::code code/path abc=def hi—there Foo42 test.com, don’t don't.",
            [33, 35, 38, 43, 60, 67, 68, 73]],
        ['e\u0301xo éxo ไทยๆ ABC xyz Ωμέγα مرحبا नमस्ते 🌟příliš',
            [6, 10, 28, 31, 32, 42, 43, 53, 77, 86]],
    ];
    try {
        for (const [text, expected] of cases) {
            const ranges = engine.proseRanges(new TextEncoder().encode(text));
            dictionary.suggest('bok');
            engine.proseRanges('unrelated text');
            assert.deepEqual([...ranges], expected);
        }
        assert.deepEqual([...engine.proseRanges('')], []);
    } finally {
        dictionary.free();
    }
});

test('the page shares one lazy fetch and can retry a failed engine request', async () => {
    const binary = await readFile(url);
    let attempts = 0;
    const original = globalThis.fetch;
    try {
        globalThis.fetch = async () => {
            if (++attempts === 1) return new Response(null, { status: 503 });
            return new Response(binary, { headers: { 'Content-Type': 'application/wasm' } });
        };
        await assert.rejects(loadSpellbook(), /503/);
        const [first, second] = await Promise.all([loadSpellbook(), loadSpellbook()]);
        assert.equal(attempts, 2);
        assert.equal(first, second);
    } finally {
        globalThis.fetch = original;
    }
});
