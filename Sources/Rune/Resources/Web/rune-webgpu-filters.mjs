import { backdropSigmas, gaussianTaps, roundUp } from './rune-blur-kernel.mjs';

// Filter extents and reduction scales follow Rune's Metal and wgpu kernels. Each pass
// owns its uniforms until submission; scratch textures can be reused between ordered passes.
export function blurGroup(frame, encoder, source, sigma, additive) {
    sigma = Math.min(sigma, 64);
    if (!(sigma > 0.05)) return source;
    const w = roundUp(source.width, 64), h = roundUp(source.height, 64);
    const reduction = Math.max(1, Math.min(sigma / 3, 8));
    const rw = Math.ceil(w / reduction), rh = Math.ceil(h / reduction);
    const sx = w / rw, sy = h / rh;
    const tx = gaussianTaps(sigma, sx), ty = gaussianTaps(sigma, sy);
    const reduced = rw !== w || rh !== h;
    if (!reduced && tx.length === 4 && ty.length === 4) return source;
    function pass(mode, input, output, vertical, taps, mx, my) {
        const params = new Float32Array(520);
        params.set([input.width, input.height, vertical, taps?.length / 4 || 0, mx, my]);
        if (taps) params.set(taps, 8);
        frame.pass(encoder, 'gaussian', output, [
            input.view, frame.driver.sampler, frame.uniform(params)
        ], { constants: { MODE: mode, ADDITIVE: additive } });
    }
    const ping = frame.target(0, 0, rw, rh);
    const pong = frame.target(0, 0, rw, rh);
    if (reduced) pass(2, source, pong, 0, null, sx, sy);
    pass(0, reduced ? pong : source, ping, 0, tx, 1, 1);
    pass(0, ping, pong, 1, ty, 1, 1);
    ping.inUse = false;
    if (!reduced && source.width === rw && source.height === rh) {
        pong.x = source.x;
        pong.y = source.y;
        return pong;
    }
    const result = frame.target(source.x, source.y, source.width, source.height);
    pass(3, pong, result, 0, null, 1 / sx, 1 / sy);
    pong.inUse = false;
    return result;
}

export function drawBackdrop(frame, encoder, source, marker) {
    const { width, height } = source;
    const sigma = marker[16];
    const s = Math.max(backdropSigmas[0], Math.min(sigma, backdropSigmas.at(-1)));
    let n = 1;
    while (n < backdropSigmas.length - 1 && s > backdropSigmas[n]) n++;
    const a = backdropSigmas[n - 1], b = backdropSigmas[n];
    const share = (s*s - a*a) / (b*b - a*a);
    const reach = Math.min(sigma, b) * 3 + 2;
    const mx = marker[0] - source.x, my = marker[1] - source.y;
    const left = Math.max(0, mx - reach), top = Math.max(0, my - reach);
    const right = Math.min(width, mx + marker[2] + reach), bottom = Math.min(height, my + marker[3] + reach);
    if (right <= left || bottom <= top) return;
    const align = 2 << n;
    const x = Math.floor(left / align) * align, y = Math.floor(top / align) * align;
    const step = 1 << (backdropSigmas.length - 1);
    const pw = roundUp(Math.ceil((right - x) / 2), step), ph = roundUp(Math.ceil((bottom - y) / 2), step);
    const ew = pw * 2, eh = ph * 2;
    const region = [(left - x) / ew, (top - y) / eh, (right - x) / ew, (bottom - y) / eh];
    const levels = [];
    let input = source;
    function pass(output, entry, fine, weight, bounds, map) {
        const params = new Float32Array([weight, 0, 0, 0, ...bounds, ...map, 0, 0, 0, 0]);
        frame.pass(encoder, 'backdrop', output,
            [input.view, fine.view, frame.driver.sampler, frame.uniform(params)], { entry });
        input = output;
    }
    for (let i = 0; i <= n; ++i) {
        const level = frame.target(0, 0, pw >> i, ph >> i);
        pass(level, 'fs_down', input, 0,
            i ? region : [left / width, top / height, right / width, bottom / height],
            i ? [1, 1, 0, 0] : [ew / width, eh / height, x / width, y / height]);
        levels.push(level);
    }
    for (let i = n - 1; i >= 0; --i) {
        const output = frame.target(0, 0, pw >> i, ph >> i);
        const previous = input;
        pass(output, 'fs_up', levels[i], i === n - 1 ? share : 1, region, [1, 1, 0, 0]);
        previous.inUse = levels[i].inUse = false;
    }
    frame.composite(encoder, source, { ...input, x: source.x + x, y: source.y + y, width: ew, height: eh }, marker, false);
    input.inUse = false;
}
