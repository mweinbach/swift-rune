// The pinned dictionary engine is instantiated only after a page asks to check a word.
const bundledURL = new URL('./rune-spellbook.wasm', import.meta.url);
const utf8 = new TextEncoder();
const decode = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
let bundledEngine;

async function openEngine(source) {
    if (source === undefined) {
        const response = await fetch(bundledURL);
        if (!response.ok) throw new Error(`Loading Spellbook returned HTTP ${response.status}`);
        const mime = response.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase();
        source = mime === 'application/wasm' && WebAssembly.compileStreaming
            ? await WebAssembly.compileStreaming(response) : await response.arrayBuffer();
    }
    const module = source instanceof WebAssembly.Module ? source : await WebAssembly.compile(source);
    const { exports: api } = await WebAssembly.instantiate(module);
    // Apps normally dispose their dictionaries with the canvas. A reactor can also be
    // collected before mounting, while the shared engine still serves other canvases.
    const dictionaries = typeof FinalizationRegistry === 'function'
        ? new FinalizationRegistry(id => api.spell_close(id)) : null;

    function write(first, second) {
        const size = first.byteLength + (second?.byteLength ?? 0);
        if (size > 0x7fffffff) throw new RangeError('Spellbook input exceeds the WebAssembly allocation limit');
        const pointer = api.spell_buffer(size) >>> 0;
        if (!pointer) throw new RangeError('Unable to allocate Spellbook input');
        const input = new Uint8Array(api.memory.buffer, pointer, size);
        input.set(first);
        if (second) input.set(second, first.byteLength);
    }

    function result() {
        return new Uint8Array(api.memory.buffer, api.spell_bytes() >>> 0, api.spell_length() >>> 0);
    }

    function dictionaryBytes(value) {
        if (typeof value === 'string') return utf8.encode(value);
        if (value instanceof Uint8Array) return value;
        throw new TypeError('Expected dictionary text or UTF-8 bytes');
    }

    return {
        proseRanges(bytes) {
            write(dictionaryBytes(bytes));
            const pointer = api.spell_prose() >>> 0;
            return new Uint32Array(api.memory.buffer, pointer, api.spell_prose_length() >>> 0).slice();
        },
        dictionary(aff, dic) {
            const rules = dictionaryBytes(aff);
            write(rules, dictionaryBytes(dic));
            let id = api.spell_open(rules.byteLength);
            if (!id) throw new Error(decode.decode(result()));

            function setWord(word) {
                if (!id) throw new Error('Dictionary was released');
                if (typeof word !== 'string') throw new TypeError('Expected a word');
                write(utf8.encode(word));
            }
            const dictionary = {
                check(word) {
                    setWord(word);
                    return Boolean(api.spell_check(id));
                },
                add(word) {
                    setWord(word);
                    return Boolean(api.spell_add(id));
                },
                suggest(word) {
                    setWord(word);
                    api.spell_suggest(id);
                    const data = result();
                    const lengths = new DataView(data.buffer, data.byteOffset, data.byteLength);
                    const words = [];
                    for (let offset = 0; offset < data.byteLength;) {
                        const size = lengths.getUint32(offset, true);
                        offset += 4;
                        words.push(decode.decode(data.subarray(offset, offset + size)));
                        offset += size;
                    }
                    return words;
                },
                free() {
                    dictionaries?.unregister(dictionary);
                    if (id) api.spell_close(id);
                    id = 0;
                },
            };
            dictionaries?.register(dictionary, id, dictionary);
            return dictionary;
        },
    };
}

/** Load the shared browser engine, or make an isolated instance from Wasm bytes/a compiled module. */
export function loadSpellbook(source) {
    if (source !== undefined) return openEngine(source);
    return bundledEngine ??= openEngine().catch(error => {
        bundledEngine = undefined;
        throw error;
    });
}
