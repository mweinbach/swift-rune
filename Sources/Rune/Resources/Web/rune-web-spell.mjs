// Each reactor checks against its own chosen set of dictionaries. Only dictionary assets
// cross the network; the text, suggestions and learned words stay in the browser.
const reactors = new WeakMap();
const utf8 = new TextEncoder();
const decode = new TextDecoder('utf-8', {ignoreBOM: true});
const reasonableWordCache = 8192;

function put(cache, key, value, limit = reasonableWordCache) {
    if (cache.size >= limit) cache.clear();
    cache.set(key, value);
    return value;
}

class BrowserSpelling {
    constructor(doc) {
        this.doc = doc;
        this.selected = [];
        this.generation = 0;
        this.entries = new Map();
        this.listeners = new Set();
        this.learned = new Set();
        this.ignored = new Set();
        this.words = new Map();
        this.lines = new Map();
        this.engine = null;
    }

    invalidate() {
        this.generation = (this.generation + 1) | 0;
        this.lastText = null;
        this.lastRanges = null;
        this.words.clear();
        this.lines.clear();
    }

    select(tags) {
        if (this.selected.length === tags.length && this.selected.every((tag, i) => tag === tags[i])) return;
        this.selected = tags;
        this.invalidate();
    }

    async load(tag, entry) {
        try {
            const base = new URL('spell/', this.doc?.baseURI ?? globalThis.location.href);
            const source = async suffix => {
                const url = new URL(encodeURIComponent(tag) + suffix, base);
                const response = await fetch(url, { signal: entry.abort.signal });
                if (!response.ok) throw Error(url.pathname + ' HTTP ' + response.status);
                return new Uint8Array(await response.arrayBuffer());
            };
            // The optional engine and the two Hunspell files fetch concurrently on first use.
            const [engine, aff, dic] = await Promise.all([
                import('./rune-spellbook.mjs').then(m => m.loadSpellbook()), source('.aff'), source('.dic')
            ]);
            if (this.entries.get(tag) !== entry) return;
            entry.dictionary = engine.dictionary(aff, dic);
            this.engine = engine;
            for (const word of this.learned) entry.dictionary.add(word);
        } catch (error) {
            if (this.entries.get(tag) !== entry) return;
            entry.abort.abort();
            console.warn('Rune spelling could not load ' + tag, error);
        }
        entry.pending = false;
        this.invalidate();
        for (const changed of this.listeners) changed();
    }

    ready() {
        let loading = false;
        const dictionaries = [];
        for (const tag of this.selected) {
            let entry = this.entries.get(tag);
            if (!entry) {
                entry = { pending: true, abort: new AbortController(), dictionary: null };
                this.entries.set(tag, entry);
                void this.load(tag, entry);
            }
            if (entry.pending) loading = true;
            else if (entry.dictionary) dictionaries.push(entry.dictionary);
        }
        return loading ? [] : dictionaries;
    }

    line(text, dictionaries) {
        const previous = this.lines.get(text);
        if (previous) return previous;
        const ranges = [];
        const bytes = utf8.encode(text);
        // Use the pinned Unicode word boundaries and prose exclusions; language-tailored
        // browser segmenters split CJK, Thai and apostrophes differently from Rune.
        const candidates = this.engine.proseRanges(bytes);
        for (let i = 0; i < candidates.length; i += 2) {
            const start = candidates[i], end = candidates[i + 1];
            const word = decode.decode(bytes.subarray(start, end));
            let correct = this.words.get(word);
            if (correct === undefined) {
                correct = this.ignored.has(word) || dictionaries.some(dictionary => dictionary.check(word));
                put(this.words, word, correct);
            }
            if (!correct) ranges.push(start, end);
        }
        const result = { ranges, length: bytes.length };
        // Keep editing a single unbroken paragraph from retaining every old document.
        return bytes.length <= 4096 ? put(this.lines, text, result) : result;
    }

    check(text) {
        if (this.lastText === text) return this.lastRanges;
        if (!text.trim()) return new Uint8Array();
        const dictionaries = this.ready();
        if (!dictionaries.length) return new Uint8Array();
        const bounds = [];
        let byte = 0;
        for (const line of text.split('\n')) {
            const result = this.line(line, dictionaries);
            for (const edge of result.ranges) bounds.push(byte + edge);
            byte += result.length + 1;
        }
        this.lastText = text;
        this.lastRanges = new Uint8Array(Uint32Array.from(bounds).buffer);
        return this.lastRanges;
    }

    suggest(word) {
        if (!word || this.ignored.has(word) || this.learned.has(word)) return [];
        const out = new Set();
        for (const dict of this.ready()) {
            for (const suggestion of dict.suggest(word)) {
                if (suggestion !== word) out.add(suggestion);
                if (out.size === 5) return [...out];
            }
        }
        return [...out];
    }

    learn(word, ignore) {
        if (!word) return;
        if (ignore) {
            this.ignored.add(word);
        } else {
            this.learned.add(word);
            for (const {dictionary} of this.entries.values()) dictionary?.add(word);
        }
        this.invalidate();
    }

    release() {
        const entries = [...this.entries.values()];
        this.entries.clear();
        for (const entry of entries) {
            entry.abort.abort();
            entry.dictionary?.free();
        }
        this.invalidate();
    }
}

function spelling(memory, doc) {
    let state = reactors.get(memory);
    if (!state) {
        state = new BrowserSpelling(doc);
        reactors.set(memory, state);
    }
    return state;
}

export function mountRuneSpelling(memory, doc, changed) {
    const state = spelling(memory, doc);
    state.listeners.add(changed);
    return () => {
        state.listeners.delete(changed);
        if (!state.listeners.size) state.release();
    };
}

// The synchronous C ABI sizes the response before Swift allocates its receiving array.
export function createRuneSpellImports(getMemory, doc, available = []) {
    let response;
    return {
        spell_request(op, address, size) {
            const memory = getMemory();
            const state = spelling(memory, doc);
            const input = size > 0 ? decode.decode(new Uint8Array(memory.buffer, address >>> 0, size)) : '';
            response = null;
            switch (op) {
            case 0: response = utf8.encode(JSON.stringify(available)); break;
            case 1: response = utf8.encode(JSON.stringify(doc?.defaultView?.navigator?.languages ?? globalThis.navigator?.languages ?? [])); break;
            case 2: state.select(JSON.parse(input)); break;
            case 3: response = state.check(input); break;
            case 4: response = utf8.encode(JSON.stringify(state.suggest(input))); break;
            case 5: state.learn(input, false); break;
            case 6: state.learn(input, true); break;
            case 7: return state.generation;
            }
            return response?.length ?? 0;
        },
        spell_read(address, capacity) {
            if (response && capacity === response.length)
                new Uint8Array(getMemory().buffer, address >>> 0, capacity).set(response);
            response = null;
        }
    };
}
