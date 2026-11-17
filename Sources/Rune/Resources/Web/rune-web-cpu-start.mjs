// A canvas cannot switch context types. Present CPU frames underneath the input canvas
// while its GPU pipelines compile. The owner can style, size and focus the original canvas.
export function mountCPUUnderlay(canvas) {
    const parent = canvas.parentNode;
    if (!parent) return null;
    const surface = canvas.ownerDocument.createElement('canvas');
    const context = surface.getContext('2d', {alpha: false});
    if (!context) return null;
    surface.setAttribute('aria-hidden', 'true');
    surface.style.cssText = 'position:fixed;pointer-events:none;display:block;margin:0;border:0;padding:0;';
    const opacity = canvas.style.opacity;
    surface.style.zIndex = getComputedStyle(canvas).zIndex;
    canvas.style.opacity = '0';
    parent.insertBefore(surface, canvas);
    let removed = false;
    function place() {
        const r = canvas.getBoundingClientRect();
        surface.style.left = r.left + 'px';
        surface.style.top = r.top + 'px';
        surface.style.width = r.width + 'px';
        surface.style.height = r.height + 'px';
    }
    place();
    const observer = new ResizeObserver(place);
    observer.observe(canvas);
    window.addEventListener('scroll', place, true);
    return {
        context, place,
        remove() {
            if (removed) return;
            removed = true;
            observer.disconnect();
            window.removeEventListener('scroll', place, true);
            if (canvas.style.opacity === '0') canvas.style.opacity = opacity;
            surface.width = surface.height = 0;
            surface.remove();
        }
    };
}

// Store pixels on the page. Browsers can upload page-owned ImageData without retaining or
// copying an entire WebAssembly memory buffer; only the current strip crosses that boundary.
export function makeCPUFrameTransfer(wasm) {
    let staged = new Uint8ClampedArray(0);
    const rects = new Uint32Array(8 * 4);
    return (context, address, length) => {
        const info = new DataView(wasm.memory.buffer, address, length);
        const width = info.getUint32(0, true), height = info.getUint32(4, true);
        const count = info.getUint32(8, true), deferred = info.getUint32(12, true);
        const edgesEnd = 32 + 16 * count;
        if (width < 1 || height < 1 || count > 8 || (length !== edgesEnd && length !== edgesEnd + 8)) throw Error('Invalid Rune CPU damage frame');
        const paintUs = info.getFloat64(16, true), rasterUs = info.getFloat64(24, true);
        const fillUs = length === edgesEnd ? 0 : info.getFloat64(edgesEnd, true);
        if (deferred) return; // A native surface or GPU-only effect keeps the last good frame displayed.
        // Changing a Canvas 2D backing size clears every pixel, including on a deferred resize.
        if (context.canvas.width !== width) context.canvas.width = width;
        if (context.canvas.height !== height) context.canvas.height = height;
        const stats = globalThis.__runeCpuFrames;
        const timed = Array.isArray(stats);
        if (count === 0) {
            if (timed) stats.push([fillUs, paintUs, rasterUs, 0, 0, 0]);
            return;
        }
        // The strip export uses the same scratch buffer as this header and can grow WASM memory.
        rects.set(new Uint32Array(wasm.memory.buffer, address + 32, count * 4));
        const started = timed ? performance.now() : 0;
        let swizzleUs = 0, pixels = 0;
        for (let r = 0; r < count; ++r) {
            const i = r * 4, x = rects[i], y = rects[i + 1];
            const w = rects[i + 2] - x, h = rects[i + 3] - y;
            if (w <= 0 || h <= 0 || x + w > width || y + h > height) throw Error('Invalid Rune CPU damage rectangle');
            const byteCount = w * h * 4;
            if (staged.length < byteCount) staged = new Uint8ClampedArray(byteCount);
            const rowsPerStrip = Math.max(1, Math.floor(16384 / w));
            const copyStart = timed ? performance.now() : 0;
            for (let row = 0; row < h; row += rowsPerStrip) {
                const rows = Math.min(rowsPerStrip, h - row);
                const n = wasm.rune_web_cpu_rect(r, row, rows);
                if (n !== rows * w * 4) throw Error('Invalid Rune CPU pixel strip');
                const pointer = wasm.rune_web_buffer(0);
                staged.set(new Uint8Array(wasm.memory.buffer, pointer, n), row * w * 4);
            }
            if (timed) swizzleUs += (performance.now() - copyStart) * 1000;
            context.putImageData(new ImageData(staged.subarray(0, byteCount), w, h), x, y);
            pixels += w * h;
        }
        if (timed) stats.push([fillUs, paintUs, rasterUs, (performance.now() - started) * 1000, swizzleUs, pixels]);
    };
}
