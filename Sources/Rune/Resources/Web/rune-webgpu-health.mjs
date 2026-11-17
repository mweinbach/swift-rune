export function gpuSummary(device, adapter) {
    const info = device.adapterInfo ?? adapter?.info ?? {};
    const parts = [info.vendor, info.architecture, info.device, info.description].filter(Boolean);
    if (info.isFallbackAdapter || adapter?.isFallbackAdapter) parts.push('fallback adapter');
    parts.push('max texture ' + device.limits.maxTextureDimension2D);
    return parts.join(', ');
}

// Match Rune's per-device error log: the first message names the adapter, the fifth mutes.
export function watchGPU(device, summary, lost, log = console.error) {
    let active = true;
    const seen = new Set();
    function error(event) {
        event.preventDefault();
        const message = event.error?.message ?? '';
        if (seen.size > 4 || seen.has(message)) return;
        seen.add(message);
        const where = seen.size === 1 ? ' on ' + summary : '';
        const mute = seen.size === 5 ? "\n(further GPU errors on this device aren't logged)" : '';
        log('Rune GPU error' + where + ': ' + (event.error?.constructor?.name ?? 'GPUError') + ': ' + message + mute);
    }
    device.addEventListener('uncapturederror', error);
    device.lost.then(info => {
        if (active && info.reason !== 'destroyed') lost((info.reason ?? 'unknown') + ': ' + info.message + ', on ' + summary);
    });
    return () => {
        active = false;
        device.removeEventListener('uncapturederror', error);
    };
}

// Older WebGPU devices may expose only synchronous creation. Bootstrap is the sole compile site.
export async function compilePipeline(device, descriptor) {
    if (typeof device.createRenderPipelineAsync === 'function') return device.createRenderPipelineAsync(descriptor);
    return device.createRenderPipeline(descriptor);
}

export async function scopedGPU(device, operation) {
    for (const kind of ['validation', 'out-of-memory', 'internal']) device.pushErrorScope(kind);
    try {
        return await operation();
    } finally {
        // Pop every scope before yielding, including when pipeline creation threw.
        const errors = await Promise.all([device.popErrorScope(), device.popErrorScope(), device.popErrorScope()]);
        const error = errors.find(Boolean);
        if (error) throw Error((error.constructor?.name ?? 'GPUError') + ': ' + error.message);
    }
}
