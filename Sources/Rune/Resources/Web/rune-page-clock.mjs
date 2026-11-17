// Browser automation can replace the performance object after startup and begin
// its clock at zero. Keep elapsed time continuous across that replacement.
export function createRunePageClock(page = globalThis) {
    let last = 0;
    let offset = 0;
    return () => {
        const source = page.performance?.now?.();
        if (!Number.isFinite(source)) return last;
        const time = source + offset;
        if (time < last) offset = last - source;
        else last = time;
        return last;
    };
}

export const runePageNow = createRunePageClock();

// WASI Preview 1 clock 1 is monotonic. Swift's timers and frame input follow
// the same page clock when a debugger pauses it or installs a replacement.
export function withRunePageClock(wasi, memory) {
    if (typeof wasi?.clock_time_get !== 'function') return wasi;
    return Object.create(wasi, {
        clock_time_get: {
            value(id, precision, address) {
                if (id !== 1) return wasi.clock_time_get(id, precision, address);
                const buffer = memory()?.buffer;
                const pointer = address >>> 0;
                if (!buffer || pointer + 8 > buffer.byteLength) return 21; // __WASI_ERRNO_FAULT
                const ns = runePageNow() * 1e6;
                const ticks = ns >= 2 ** 64 ? 0xffffffffffffffffn : BigInt(Math.trunc(ns));
                new DataView(buffer).setBigUint64(pointer, ticks, true);
                return 0;
            }
        }
    });
}
