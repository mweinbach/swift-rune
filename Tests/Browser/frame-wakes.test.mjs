import assert from 'node:assert/strict';
import test from 'node:test';
import { mountRuneFrameClock, wakeRuneBrowser } from '../../Sources/Rune/Resources/Web/rune-web-wake.mjs';

test('a resting host uses no callbacks, replaces a later timer, and follows each display refresh while active', () => {
    let now = 0, next = Infinity, drawn = 0, id = 0;
    const frames = new Map(), timers = new Map();
    const old = Object.fromEntries(['requestAnimationFrame', 'cancelAnimationFrame', 'setTimeout', 'clearTimeout']
        .map(key => [key, globalThis[key]]));
    globalThis.requestAnimationFrame = fn => { frames.set(++id, fn); return id; };
    globalThis.cancelAnimationFrame = key => frames.delete(key);
    globalThis.setTimeout = (fn, ms) => { timers.set(++id, {fn, at:now+ms}); return id; };
    globalThis.clearTimeout = key => timers.delete(key);
    const memory = new WebAssembly.Memory({initial:1});
    const host = mountRuneFrameClock(memory, () => { drawn++; }, () => next, () => now);
    function display(hz = 144) {
        const batch = [...frames.values()];
        frames.clear();
        now += 1000 / hz;
        for (const fn of batch) fn(now);
    }
    try {
        host.start();
        assert.equal(drawn, 1);
        assert.equal(frames.size + timers.size, 0);
        wakeRuneBrowser(memory, 2);
        wakeRuneBrowser(memory, 1);
        wakeRuneBrowser(memory, 3);
        assert.equal(timers.size, 1);
        const [{fn, at}] = timers.values();
        assert.ok(at >= 980 && at <= 985);
        now = at;
        timers.clear();
        fn();
        display();
        assert.equal(drawn, 1); // timer woke before the display deadline
        now = 1000;
        next = 0;
        for (const hz of [60, 120, 144]) {
            const before = drawn;
            for (let i = 0; i < hz; i++) display(hz);
            assert.equal(drawn - before, hz);
        }
        assert.equal(timers.size, 0);
        next = Infinity;
        display();
        assert.equal(frames.size + timers.size, 0);
        wakeRuneBrowser(memory, 1);
        wakeRuneBrowser(memory, 0);
        wakeRuneBrowser(memory, 0);
        assert.equal(timers.size, 0);
        assert.equal(frames.size, 1);
        host.dispose();
        wakeRuneBrowser(memory, 0);
        assert.equal(frames.size + timers.size, 0);
    } finally {
        host.dispose();
        for (const [key, value] of Object.entries(old)) {
            if (value === undefined) delete globalThis[key]; else globalThis[key] = value;
        }
    }
});
