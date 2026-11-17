// The calibrated effective sigmas of the seven Metal backdrop pyramid levels.
export const backdropSigmas = new Float32Array([1.58, 4.53, 9.62, 19.51, 39.15, 78.36, 156.2]);
export const roundUp = (value, step) => Math.ceil(value / step) * step;

export function gaussianTaps(sigma, scale) {
    const effective = Math.sqrt(Math.max(1e-6, sigma * sigma - (scale * scale - 1) / 4)) / scale;
    if (effective < 0.05) return new Float32Array([0, 1, 0, 0]);
    const radius = Math.min(254, Math.ceil(effective * 3));
    const raw = [1];
    let total = 1;
    for (let k = 1; k <= radius; k++) {
        raw[k] = Math.exp(-k * k / (2 * effective * effective));
        total += 2 * raw[k];
    }
    const taps = [0, 1 / total, 0, 0];
    for (let k = 1; k <= radius; k += 2) {
        const next = raw[k + 1] ?? 0;
        const pair = raw[k] + next;
        if (pair / total > 1e-6) taps.push(k + next / pair, pair / total, 0, 0);
    }
    return new Float32Array(taps);
}
