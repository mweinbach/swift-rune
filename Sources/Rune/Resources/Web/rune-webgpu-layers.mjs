import { compilePipeline } from './rune-webgpu-health.mjs';
import { LayerCache } from './rune-gpu-layer-cache.mjs';
import { planLayerRects } from './rune-webgl-layers.mjs';
import { blurGroup, drawBackdrop } from './rune-webgpu-filters.mjs';

const usage = () => GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC |
    GPUTextureUsage.COPY_DST | GPUTextureUsage.TEXTURE_BINDING;
const shaders = {
    composite: ['uniform', 'texture', 'sampler'],
    surface: ['uniform', 'texture', 'texture', 'sampler'],
    gaussian: ['texture', 'sampler', 'uniform'],
    backdrop: ['texture', 'texture', 'sampler', 'uniform']
};
const asRect = target => [target.x, target.y, target.width, target.height];
const pipelineKey = (name, format, entry, blend, constants) =>
    [name, format, entry, blend, constants?.MODE, constants?.ADDITIVE].join('/');

function clear(encoder, target) {
    encoder.beginRenderPass({ colorAttachments: [{ view: target.view, loadOp: 'clear', storeOp: 'store',
        clearValue: [0, 0, 0, 0] }] }).end();
}

function copy(encoder, source, target, sx, sy, dx, dy, width, height) {
    encoder.copyTextureToTexture({ texture: source.texture, origin: [sx, sy] },
        { texture: target.texture, origin: [dx, dy] }, [width, height]);
}

export class RuneWebGPUFrame {
    static async create(driver) {
        const frame = new RuneWebGPUFrame(driver);
        try {
            await Promise.all(Object.entries(shaders).map(async ([name, resources]) => {
                const url = new URL('./rune-webgpu-' + name + '.wgsl', import.meta.url);
                const response = await fetch(url);
                if (!response.ok) throw new Error('Unable to load ' + url);
                let code = await response.text();
                if (name === 'composite' || name === 'surface') code = driver.clipSource + '\n' + code;
                const label = 'Rune ' + name;
                const module = driver.device.createShaderModule({ label, code });
                const info = await module.getCompilationInfo?.();
                const errors = (info?.messages ?? []).filter(m => m.type === 'error');
                if (errors.length) throw new Error(label + ': ' + errors.map(m => m.lineNum + ' ' + m.message).join('\n'));
                const entries = resources.map((kind, binding) => {
                    const visibility = GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT;
                    if (kind === 'uniform') return { binding, visibility, buffer: { type: 'uniform' } };
                    if (kind === 'texture') return { binding, visibility, texture: { sampleType: 'float' } };
                    return { binding, visibility, sampler: { type: 'filtering' } };
                });
                const bindings = driver.device.createBindGroupLayout({ label, entries });
                const layout = driver.device.createPipelineLayout({ label, bindGroupLayouts: [bindings] });
                frame.programs.set(name, { module, bindings, layout });
                await frame.preparePipelines(name);
            }));
            return frame;
        } catch (error) {
            frame.dispose();
            throw error;
        }
    }

    constructor(driver) {
        this.driver = driver;
        this.device = driver.device;
        this.programs = new Map();
        this.pipelines = new Map();
        this.targets = [];
        this.retired = [];
        this.images = new Map();
        this.timings = new Set();
        this.waiting = [];
        this.surfaceEpoch = 0;
        this.pages = [];
        this.cache = new LayerCache(8,
            (source, x, y, w, h) => this.capture(source, x, y, w, h),
            target => this.retired.push(target.texture));
    }

    uniform(values) {
        const alignment = this.device.limits.minUniformBufferOffsetAlignment;
        const bytes = values.byteLength;
        let page = this.pages[this.pageIndex];
        if (page && page.used + bytes > page.data.byteLength) page = this.pages[++this.pageIndex];
        if (!page) {
            const size = 64 * 1024;
            const buffer = this.device.createBuffer({ label: 'Rune frame uniforms', size,
                usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
            page = { buffer, data: new Uint8Array(size), used: 0 };
            this.pages.push(page);
        }
        const offset = page.used;
        page.data.set(new Uint8Array(values.buffer, values.byteOffset, bytes), offset);
        page.used += Math.ceil(bytes / alignment) * alignment;
        return { buffer: page.buffer, offset, size: bytes };
    }

    target(x, y, width, height, format = this.driver.layerFormat) {
        let target = this.targets.find(t => !t.inUse && t.width === width && t.height === height && t.format === format);
        if (!target) {
            const max = this.device.limits.maxTextureDimension2D;
            if (!(width > 0 && height > 0 && width <= max && height <= max)) {
                throw new Error('Rune WebGPU render target exceeds device limits: ' + width + 'x' + height);
            }
            const texture = this.device.createTexture({ label: 'Rune compositor target', format,
                size: [width, height], usage: usage() });
            target = { texture, view: texture.createView(), width, height, format };
            this.targets.push(target);
        }
        Object.assign(target, { x, y, inUse: true, used: true });
        return target;
    }

    capture(source, x, y, width, height) {
        let target = source;
        if (width !== source.width || height !== source.height) {
            target = this.target(x, y, width, height);
            copy(this.encoder, source, target, x - source.x, y - source.y, 0, 0, width, height);
        }
        this.targets.splice(this.targets.indexOf(target), 1);
        return target;
    }

    async preparePipelines(name) {
        const { module, layout } = this.programs.get(name);
        const jobs = [];
        const strip = name === 'composite' || name === 'surface';
        const prepare = (format, entry = 'fs', blend, constants) => {
            const key = pipelineKey(name, format, entry, blend, constants);
            const output = { format };
            if (blend !== undefined) {
                const component = { srcFactor: 'one', dstFactor: blend ? 'one' : 'one-minus-src-alpha' };
                output.blend = { color: component, alpha: component };
            }
            const descriptor = { label: 'Rune ' + key, layout,
                vertex: { module, entryPoint: 'vs' },
                fragment: { module, entryPoint: entry, constants, targets: [output] },
                primitive: { topology: strip ? 'triangle-strip' : 'triangle-list' } };
            jobs.push(compilePipeline(this.device, descriptor).then(pipeline => this.pipelines.set(key, pipeline)));
        };
        if (strip) {
            for (const format of [this.driver.format, this.driver.srgbFormat, this.driver.layerFormat]) {
                for (const additive of [false, true]) prepare(format, 'fs', additive);
            }
        } else if (name === 'gaussian') {
            for (const MODE of [0, 2, 3]) for (const ADDITIVE of [false, true]) {
                prepare(this.driver.layerFormat, 'fs', undefined, { MODE, ADDITIVE });
            }
        } else {
            for (const entry of ['fs_down', 'fs_up']) prepare(this.driver.layerFormat, entry);
        }
        await Promise.all(jobs);
    }

    pass(encoder, name, target, resources, { entry = 'fs', constants, blend } = {}) {
        const { bindings } = this.programs.get(name);
        const key = pipelineKey(name, target.format, entry, blend, constants);
        const pipeline = this.pipelines.get(key);
        if (!pipeline) throw new Error('Unsupported Rune WebGPU pipeline ' + key);
        const strip = name === 'composite' || name === 'surface';
        const group = this.device.createBindGroup({ layout: bindings,
            entries: resources.map((resource, binding) => ({ binding, resource })) });
        const pass = encoder.beginRenderPass({ label: 'Rune ' + name, colorAttachments: [{
            view: target.view, loadOp: blend === undefined ? 'clear' : 'load', clearValue: [0, 0, 0, 0], storeOp: 'store'
        }] });
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, group);
        pass.draw(strip ? 4 : 3);
        pass.end();
    }

    composite(encoder, target, source, marker, additive) {
        const values = new Float32Array(40);
        // Preserve all packed clip bits, including encodings which look like float NaNs.
        new Uint8Array(values.buffer).set(new Uint8Array(marker.buffer, marker.byteOffset, marker.byteLength));
        values.set(asRect(target), 32);
        values.set(asRect(source), 36);
        this.pass(encoder, 'composite', target, [this.uniform(values), source.view, this.driver.sampler], { blend: additive });
    }

    prepareSurface(draw) {
        let resident = this.images.get(draw.key);
        const sameShape = resident && resident.width === draw.width && resident.height === draw.height && resident.format === draw.format;
        if (sameShape && resident.revision === draw.revision) {
            resident.epoch = this.surfaceEpoch;
            return resident;
        }
        if (!draw.primary.length) throw new Error('Rune surface references an unavailable WebGPU texture revision');
        const max = this.device.limits.maxTextureDimension2D;
        if (draw.width > max || draw.height > max) throw new Error('Rune surface exceeds WebGPU dimensions');
        // Queue writes follow the previous frame's submit. Within a command buffer, however,
        // every earlier placement still needs its own revision after these writes complete.
        const reuse = sameShape && resident.epoch !== this.surfaceEpoch;
        const textures = reuse ? resident.textures : [], views = reuse ? resident.views : [];
        const plane = (index, format, width, height, stride, bytes) => {
            if (!reuse) {
                const texture = this.device.createTexture({ label: 'Rune native surface', format,
                    size: [width, height], usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
                textures.push(texture);
                views.push(texture.createView());
            }
            this.device.queue.writeTexture({ texture: textures[index] }, bytes, { bytesPerRow: width * stride }, [width, height]);
        };
        try {
            if (draw.format === 1 || draw.format === 2) {
                plane(0, 'r8unorm', draw.width, draw.height, 1, draw.primary);
                plane(1, 'rg8unorm', draw.width / 2, draw.height / 2, 2, draw.chroma);
            } else {
                plane(0, draw.format === 0 ? 'bgra8unorm' : 'rgba8unorm', draw.width, draw.height, 4, draw.primary);
            }
        } catch (error) {
            if (reuse) this.images.delete(draw.key);
            this.retired.push(...textures);
            throw error;
        }
        if (resident && !reuse) this.retired.push(...resident.textures);
        resident = { width: draw.width, height: draw.height, revision: draw.revision, format: draw.format,
            textures, views, epoch: this.surfaceEpoch };
        this.images.set(draw.key, resident);
        return resident;
    }

    drawSurface(encoder, draw, resident, level) {
        const { target, additive } = level;
        const values = draw.uniforms.slice();
        values.set([target.width, target.height, target.x, target.y]);
        this.pass(encoder, 'surface', target,
            [this.uniform(values), resident.views[0], resident.views[1] ?? resident.views[0], this.driver.sampler],
            { blend: additive });
    }

    effect(encoder, marker, stack, index) {
        if (!this.driver.drawGPUEffect) return false;
        const target = stack.at(-1).target;
        const { x, y, width, height, format } = target;
        const bleed = Math.max(0, marker[18]);
        const left = Math.max(0, Math.floor(Math.max(marker[24], marker[0] - bleed)) - x);
        const top = Math.max(0, Math.floor(Math.max(marker[25], marker[1] - bleed)) - y);
        const right = Math.min(width, Math.ceil(Math.min(marker[26], marker[0] + marker[2] + bleed)) - x);
        const bottom = Math.min(height, Math.ceil(Math.min(marker[27], marker[1] + marker[3] + bleed)) - y);
        if (right <= left || bottom <= top) return false;
        let backdrop = null, snapshot = null;
        if (marker[16] >= 0.5) {
            const root = stack[0].target;
            backdrop = target.view;
            if (x || y || width !== root.width || height !== root.height) {
                snapshot = this.target(0, 0, root.width, root.height, format);
                clear(encoder, snapshot);
                const l = Math.max(0, x), t = Math.max(0, y);
                const r = Math.min(root.width, x + width), b = Math.min(root.height, y + height);
                if (r > l && b > t) copy(encoder, target, snapshot, l - x, t - y, l, t, r - l, b - t);
                backdrop = snapshot.view;
            }
        }
        const scratch = this.target(x, y, width, height, format);
        copy(encoder, target, scratch, left, top, left, top, right - left, bottom - top);
        let opacity = 1, turn = 0;
        for (const level of stack) if (level.marker) {
            opacity *= level.marker[11];
            if (level.marker[13]) turn = level.marker[13];
        }
        const accepted = this.driver.drawGPUEffect({ device: this.device, encoder, view: scratch.view, format, backdrop, index,
            mark: ((marker[12] & 65535) | ((marker[13] & 65535) << 16)) >>> 0, data: marker.slice(20, 24),
            rect: marker.slice(0, 4), clip: marker.slice(24, 28), scissor: [left, top, right - left, bottom - top],
            scale: marker[19], width, height, origin: [x, y], inLayer: stack.length > 1, opacity, turn,
            additive: stack.at(-1).additive, srgbBlend: this.driver.srgbBlend });
        if (accepted && typeof accepted.then === 'function') throw new Error('Rune WebGPU effects must encode synchronously');
        if (accepted !== false) copy(encoder, scratch, target, left, top, left, top, right - left, bottom - top);
        if (snapshot) snapshot.inUse = false;
        scratch.inUse = false;
        return true;
    }

    render(encoder, scene, root) {
        this.destroyRetired();
        this.encoder = encoder;
        this.pageIndex = 0;
        this.surfaceEpoch++;
        for (const page of this.pages) page.used = 0;
        for (const target of this.targets) target.used = target.inUse = false;
        this.surfaceFrame = false;
        const { instances, count, width, height, surfaces } = scene;
        const stack = [{ target: root, additive: false }];
        let first = 0, nextSurface = 0, backdrops = 0, effectIndex = 0;
        const flush = end => {
            const level = stack.at(-1);
            if (end > first && level.target) {
                this.driver.drawInstances(encoder, first, end - first, level.target, stack.length - 1, level.additive, scene);
            }
            first = end;
        };
        try {
            let rects;
            const residents = surfaces.map(draw => this.prepareSurface(draw));
            for (let i = 0; i <= count; ++i) {
                while (nextSurface < surfaces.length && (surfaces[nextSurface].before <= i || i === count)) {
                    flush(i);
                    if (stack.at(-1).target) this.drawSurface(encoder, surfaces[nextSurface], residents[nextSurface], stack.at(-1));
                    ++nextSurface;
                }
                if (i === count) break;
                const kind = instances[i * 32 + 17];
                if (kind !== 8 && kind !== 9 && kind !== 12 && kind !== 13) continue;
                flush(i);
                first = i + 1;
                const marker = instances.subarray(i * 32, (i + 1) * 32);
                const parent = stack.at(-1);
                if (kind === 8) {
                    // Flat virtual lists take one instance scan and one instanced draw.
                    if (!rects) {
                        rects = planLayerRects(instances, width, height, surfaces);
                        this.cache.begin(instances);
                    }
                    const rect = rects.get(i);
                    let target = null;
                    if (parent.target && rect[2] > 0 && rect[3] > 0) {
                        const hit = marker[19] >= 0.5 && this.cache.lookup(marker);
                        if (hit) this.composite(encoder, parent.target, hit, marker, parent.additive);
                        else {
                            target = this.target(...rect);
                            clear(encoder, target);
                        }
                    }
                    stack.push({ target, marker, additive: marker[16] >= 0.5 });
                } else if (kind === 9) {
                    if (stack.length < 2) throw new Error('Unexpected Rune WebGPU layer end');
                    const group = stack.pop();
                    if (!group.target) continue;
                    const destination = stack.at(-1);
                    const filtered = blurGroup(this, encoder, group.target, group.marker[18], group.additive);
                    this.composite(encoder, destination.target, filtered, group.marker, destination.additive);
                    if (group.marker[19] >= 0.5) this.cache.store(group.marker, filtered);
                    filtered.inUse = group.target.inUse = false;
                } else if (parent.target && kind === 12) {
                    if (this.effect(encoder, marker, stack, effectIndex)) ++effectIndex;
                } else if (parent.target && kind === 13 && backdrops++ < 4 && marker[16] > 0 && marker[11] > 0) {
                    drawBackdrop(this, encoder, parent.target, marker);
                }
            }
            flush(count);
            const used = new Set(surfaces.map(draw => draw.key));
            for (const [key, resident] of this.images) {
                if (used.has(key)) continue;
                this.retired.push(...resident.textures);
                this.images.delete(key);
            }
            this.targets = this.targets.filter(target => {
                if (!target.used) this.retired.push(target.texture);
                return target.used;
            });
            for (const page of this.pages) if (page.used) {
                this.device.queue.writeBuffer(page.buffer, 0, page.data, 0, page.used);
            }
            this.surfaceFrame = surfaces.length > 0;
            return root;
        } catch (error) {
            this.cache.clear();
            throw error;
        } finally {
            this.encoder = null;
        }
    }

    destroyRetired() {
        for (const texture of this.retired) texture.destroy();
        this.retired.length = 0;
    }

    takeCachedLayers(full = false) { return this.cache.takeChanges(full); }

    submitSurfaceTiming() {
        // Called after queue.submit. Resources used earlier in this frame can now be destroyed.
        this.destroyRetired();
        if (!this.surfaceFrame) return;
        this.surfaceFrame = false;
        const timing = this.driver.surfaceTiming;
        const token = timing?.submitted();
        if (!token) return;
        this.timings.add(token);
        this.waiting.push(token);
        this.fenceTimings();
    }

    fenceTimings() {
        if (this.pendingFence || !this.waiting.length) return;
        const batch = this.waiting;
        this.waiting = [];
        this.pendingFence = batch;
        // A burst of synchronous draws uses at most one outstanding fence. Submissions
        // arriving after this fence are acknowledged against the next queue watermark.
        const finish = success => {
            if (this.pendingFence !== batch) return;
            this.pendingFence = null;
            for (const token of batch) {
                if (this.timings.delete(token)) this.driver.surfaceTiming.completed(token, success);
            }
            this.fenceTimings();
        };
        this.device.queue.onSubmittedWorkDone().then(() => finish(true), () => finish(false));
    }

    cancelTimings() {
        this.surfaceFrame = false;
        this.pendingFence = null;
        this.waiting.length = 0;
        for (const token of this.timings) this.driver.surfaceTiming.completed(token, false);
        this.timings.clear();
    }

    dispose() {
        this.cancelTimings();
        this.cache.clear();
        this.destroyRetired();
        for (const target of this.targets) target.texture.destroy();
        for (const page of this.pages) page.buffer.destroy();
        for (const resident of this.images.values()) for (const texture of resident.textures) texture.destroy();
        this.targets.length = this.pages.length = 0;
        this.images.clear();
    }
}
