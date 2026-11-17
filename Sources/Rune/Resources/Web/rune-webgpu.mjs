import { RuneInstanceUploads } from './rune-instance-uploads.mjs';
import { RuneCycleScene } from './rune-web-cycles.mjs';
import { compilePipeline, gpuSummary, scopedGPU, watchGPU } from './rune-webgpu-health.mjs';
import { RuneWebGPUFrame } from './rune-webgpu-layers.mjs';

const stride = 128;
const attributes = Array.from({length: 8}, (_, location) => ({
    shaderLocation: location, offset: location * 16, format: location === 7 ? 'uint32x4' : 'float32x4'
}));

async function shaderSource(name) {
    const url = new URL(name, import.meta.url);
    const response = await fetch(url);
    if (!response.ok) throw Error('Rune shader ' + url + ' returned HTTP ' + response.status);
    return response.text();
}

// Canvas compositing expects premultiplied sRGB. Linear translucent roots must unpremultiply
// before the transfer function and premultiply again. Opaque roots can draw straight to canvas.
const presentShader = `
@group(0) @binding(0) var root: texture_2d<f32>;
@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    let xy = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
    return vec4f(xy * 2.0 - 1.0, 0.0, 1.0);
}
@fragment fn fs(@builtin(position) p: vec4f) -> @location(0) vec4f {
    let color = textureLoad(root, vec2i(p.xy), 0);
    if (color.a <= 0.0) { return vec4f(0.0); }
    let x = clamp(color.rgb / color.a, vec3f(0.0), vec3f(1.0));
    let rgb = select(1.055 * pow(x, vec3f(1.0 / 2.4)) - 0.055, 12.92 * x, x <= vec3f(0.0031308));
    return vec4f(rgb * color.a, color.a);
}`;

export class RuneWebGPU {
    static async create(canvas, { drawGPUEffect, surfaceTiming, onLost } = {}) {
        const api = navigator.gpu;
        if (!api) throw Error('WebGPU is unavailable');
        const adapter = await api.requestAdapter({powerPreference: 'low-power'});
        if (!adapter) throw Error('WebGPU has no compatible adapter');
        const device = await adapter.requestDevice({label: 'Rune', requiredLimits: {
            maxTextureDimension2D: adapter.limits.maxTextureDimension2D
        }});
        const driver = new RuneWebGPU(device, api.getPreferredCanvasFormat(), adapter);
        driver.drawGPUEffect = drawGPUEffect;
        driver.surfaceTiming = surfaceTiming;
        try {
            const [clip, frame] = await Promise.all([shaderSource('rune-clip.wgsl'), shaderSource('rune-frame.wgsl')]);
            driver.clipSource = clip;
            await scopedGPU(device, async () => {
                await Promise.all([driver.prepare(clip + '\n' + frame), RuneWebGPUFrame.create(driver)
                    .then(renderer => { driver.frameRenderer = renderer; })]);
            });
            // Taking a canvas context locks its API. Finish compilation first to allow WebGL fallback.
            driver.context = canvas.getContext('webgpu');
            if (!driver.context) throw Error('WebGPU is unavailable for this canvas');
            driver.context.configure({device, format: driver.format, viewFormats: [driver.srgbFormat],
                usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_SRC | GPUTextureUsage.COPY_DST,
                alphaMode: 'premultiplied'});
            driver.unwatch = watchGPU(device, driver.info.renderer, reason => {
                driver.lostReason = reason;
                onLost?.(driver, reason);
            });
            return driver;
        } catch (error) {
            driver.dispose();
            throw error;
        }
    }

    constructor(device, format, adapter) {
        this.device = device;
        this.format = format;
        this.srgbFormat = format + '-srgb';
        this.layerFormat = 'rgba16float';
        this.maxSize = device.limits.maxTextureDimension2D;
        this.sampler = device.createSampler({minFilter: 'linear', magFilter: 'linear'});
        this.info = {api: 'WebGPU', renderer: gpuSummary(device, adapter), vendor: adapter.info?.vendor ?? '',
            layerTarget: this.layerFormat, maxTextureSize: this.maxSize};
        this.pipelines = new Map();
        this.uniforms = [];
        this.glyphPages = [];
        this.instanceUploads = new RuneInstanceUploads();
        this.imagePages = [];
        // WebGPU initializes new textures to zero. Empty/out-of-range image pages sample
        // this transparent texel independently of the glyph atlas or the real first image.
        this.emptyPage = device.createTexture({ size: [1, 1], format: 'rgba8unorm-srgb', usage: GPUTextureUsage.TEXTURE_BINDING });
        this.emptyPageView = this.emptyPage.createView();
    }

    async prepare(code) {
        const d = this.device;
        const module = d.createShaderModule({label: 'Rune uber-quad', code});
        this.layout = d.createBindGroupLayout({entries: [
            {binding: 0, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: {type: 'uniform'}},
            {binding: 1, visibility: GPUShaderStage.FRAGMENT, texture: {}},
            {binding: 2, visibility: GPUShaderStage.FRAGMENT, texture: {}},
            {binding: 3, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: {type: 'uniform'}}
        ]});
        const layout = d.createPipelineLayout({bindGroupLayouts: [this.layout]});
        const jobs = [];
        for (const format of [this.format, this.srgbFormat, this.layerFormat]) {
            for (const additive of [false, true]) {
                const blend = {operation: 'add', srcFactor: 'one', dstFactor: additive ? 'one' : 'one-minus-src-alpha'};
                jobs.push(compilePipeline(d, {label: 'Rune ' + format, layout,
                    vertex: {module, entryPoint: 'vs', buffers: [{arrayStride: stride, stepMode: 'instance', attributes}]},
                    fragment: {module, entryPoint: 'fs', targets: [{format, blend: {color: blend, alpha: blend}}]},
                    primitive: {topology: 'triangle-strip'}
                }).then(pipeline => this.pipelines.set(format + Number(additive), pipeline)));
            }
        }
        const present = d.createShaderModule({label: 'Rune translucent presentation', code: presentShader});
        jobs.push(compilePipeline(d, {layout: 'auto', vertex: {module: present, entryPoint: 'vs'},
            fragment: {module: present, entryPoint: 'fs', targets: [{format: this.format}]}
        }).then(pipeline => { this.present = pipeline; }));
        await Promise.all(jobs);
    }

    syncAtlases(scene) {
        const unchanged = (pages, old) => pages.length === old.length && pages.every(({ width, height, update }, i) =>
            !update && (width === 0 ? !old[i] : width === old[i]?.width && height === old[i].height));
        if (unchanged(scene.glyphPages, this.glyphPages) && unchanged(scene.imagePages, this.imagePages)) return;
        const allocated = [];
        const prepare = (old, pages, format) => pages.map(({ width, height, update }, i) => {
            if (!width || !height) return null;
            if (old[i]?.width === width && old[i].height === height) return old[i];
            if (!update?.full) throw Error('Missing full Rune atlas after a resize');
            const texture = this.device.createTexture({ size: [width, height], format,
                usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
            allocated.push(texture);
            return { width, height, texture, view: texture.createView() };
        });
        let glyphPages, imagePages;
        try {
            // A resized image page can fail after staging glyph pages, or vice versa.
            // Validate both banks before changing the textures the last frame references.
            glyphPages = prepare(this.glyphPages, scene.glyphPages, 'r8unorm');
            imagePages = prepare(this.imagePages, scene.imagePages, 'rgba8unorm-srgb');
        } catch (error) {
            for (const texture of allocated) texture.destroy();
            throw error;
        }
        const upload = (old, next, pages, channels) => {
            for (const [i, {update}] of pages.entries()) {
                if (next[i] && update) {
                    this.device.queue.writeTexture({ texture: next[i].texture, origin: [update.x, update.y] },
                        update.data, { bytesPerRow: update.width * channels }, [update.width, update.height]);
                }
            }
            for (let i = 0; i < old.length; ++i) {
                if (old[i] !== next[i]) old[i]?.texture.destroy();
            }
        };
        upload(this.glyphPages, glyphPages, scene.glyphPages, 1);
        upload(this.imagePages, imagePages, scene.imagePages, 4);
        this.glyphPages = glyphPages;
        this.imagePages = imagePages;
    }

    drawInstances(encoder, first, count, target, depth, additive, scene, scissor) {
        if (!count) return;
        const d = this.device;
        let slot = this.uniforms[this.nextUniform++];
        if (!slot) {
            // The projection binding must begin on a uniform-aligned offset.
            const offset = d.limits.minUniformBufferOffsetAlignment;
            const buffer = d.createBuffer({size: offset + 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST});
            this.uniforms.push(slot = {buffer, offset, values: new Float32Array((offset + 16) / 4)});
        }
        const {values, offset} = slot;
        const x = depth ? target.x : 0, y = depth ? target.y : 0;
        const w = depth ? target.width : 0, h = depth ? target.height : 0;
        const pos = offset / 4, srgb = Number(this.srgbBlend);
        if (values[0] !== this.width || values[1] !== this.height || values[4] !== srgb ||
            values[pos] !== x || values[pos+1] !== y || values[pos+2] !== w || values[pos+3] !== h) {
            values[0] = this.width; values[1] = this.height; values[4] = srgb; values[5] = srgb;
            values[pos] = x; values[pos+1] = y; values[pos+2] = w; values[pos+3] = h;
            d.queue.writeBuffer(slot.buffer, 0, values);
        }
        slot.groups ??= new WeakMap();
        const pass = encoder.beginRenderPass({colorAttachments: [{view: target.view, loadOp: 'load', storeOp: 'store'}]});
        if (scissor) pass.setScissorRect(...scissor);
        pass.setPipeline(this.pipelines.get(target.format + Number(additive)));
        pass.setVertexBuffer(0, this.instances);
        const draw = (start, length, imagePage, glyphPage) => {
            const glyph = this.glyphPages[glyphPage]?.view ?? this.emptyPageView;
            const image = this.imagePages[imagePage]?.view ?? this.emptyPageView;
            let images = slot.groups.get(glyph);
            if (!images) slot.groups.set(glyph, images = new WeakMap());
            let group = images.get(image);
            if (!group) {
                group = d.createBindGroup({layout: this.layout, entries: [
                    {binding: 0, resource: {buffer: slot.buffer, size: 32}},
                    {binding: 1, resource: glyph}, {binding: 2, resource: image},
                    {binding: 3, resource: {buffer: slot.buffer, offset, size: 16}}
                ]});
                images.set(image, group);
            }
            pass.setBindGroup(0, group);
            pass.draw(4, length, 0, start);
        };
        this.instanceUploads.forEachRun(first, count, draw);
        pass.end();
    }

    draw(memory, pointer, length, repeatPass = 0) {
        this.cycleScene ??= new RuneCycleScene();
        const s = this.cycleScene.decode(memory, pointer, length, this.maxSize, this.atlasSequence);
        const {device: d, context} = this;
        const {width, height, srgbBlend} = s;
        this.width = width; this.height = height; this.srgbBlend = srgbBlend;
        const canvas = context.canvas;
        if (canvas.width !== width) canvas.width = width;
        if (canvas.height !== height) canvas.height = height;
        if (!s.duplicate && !repeatPass) {
            this.syncAtlases(s);
            this.atlasSequence = s.sequence;
        }
        if (!repeatPass) {
            const bytes = s.instances.byteLength;
            const grow = bytes > (this.instances?.size ?? 0);
            if (grow) {
                if (bytes > d.limits.maxBufferSize) throw Error('Rune instance stream exceeds WebGPU buffer limit');
                const buffer = d.createBuffer({label: 'Rune instances', size: Math.min(d.limits.maxBufferSize, 2 ** Math.ceil(Math.log2(bytes))),
                    usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST});
                this.instances?.destroy();
                this.instances = buffer;
            }
            this.instanceUploads.prepare(s, grow, (first, end) =>
                d.queue.writeBuffer(this.instances, first * stride, s.instances, first * 32, (end - first) * 32));
        }
        this.nextUniform = 0;
        const format = srgbBlend ? this.format : this.srgbFormat;
        const screen = context.getCurrentTexture();
        const translucent = !srgbBlend && s.clear[3] < 1;
        if (this.transparentRoot && (!translucent || this.transparentRoot.width !== width ||
            this.transparentRoot.height !== height)) {
            this.transparentRoot.destroy();
            this.transparentRoot = null;
        }
        if (translucent && !this.transparentRoot) {
            this.transparentRoot = d.createTexture({size:[width, height], format,
                usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC | GPUTextureUsage.COPY_DST});
        }
        if (this.cycleRoot && (!s.retainCycleTarget || this.cycleRoot.width !== width || this.cycleRoot.height !== height)) {
            this.cycleRoot.destroy();
            this.cycleRoot = null;
            this.cycleClear?.destroy();
            this.cycleClear = null;
        }
        if (s.retainCycleTarget && !this.cycleRoot) {
            this.cycleRoot = d.createTexture({size: [width, height], format: this.format, viewFormats: [this.srgbFormat],
                usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC | GPUTextureUsage.COPY_DST});
        }
        const texture = this.cycleRoot ?? this.transparentRoot ?? screen;
        const root = {texture, view: texture.createView({format}), format, x:0, y:0, width, height};
        this.info.colorTarget = format;
        const encoder = d.createCommandEncoder();
        if (s.damage?.length) {
            const w = Math.max(...s.damage.map(({area}) => area[2] - area[0]));
            const h = Math.max(...s.damage.map(({area}) => area[3] - area[1]));
            if (!this.cycleClear || this.cycleClear.width < w || this.cycleClear.height < h) {
                this.cycleClear?.destroy();
                this.cycleClear = d.createTexture({size: [w, h], format: this.format, viewFormats: [this.srgbFormat],
                    usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC});
            }
            encoder.beginRenderPass({colorAttachments: [{view: this.cycleClear.createView({format}),
                loadOp: 'clear', storeOp: 'store', clearValue: s.clear}]}).end();
            for (const {area: [l,t,r,b], runs} of s.damage) {
                encoder.copyTextureToTexture({texture: this.cycleClear}, {texture, origin: [l,t]}, [r-l,b-t]);
                for (const [first, end] of runs)
                    this.drawInstances(encoder, first, end-first, root, 0, false, s, [l,t,r-l,b-t]);
            }
        } else {
            encoder.beginRenderPass({colorAttachments: [{view: root.view, loadOp:'clear', storeOp:'store',
                clearValue: s.clear}]}).end();
            this.frameRenderer.render(encoder, s, root);
        }
        if (this.cycleRoot) encoder.copyTextureToTexture({texture}, {texture: screen}, [width, height]);
        if (translucent) {
            const group = d.createBindGroup({layout: this.present.getBindGroupLayout(0), entries: [{binding:0, resource:root.view}]});
            const pass = encoder.beginRenderPass({colorAttachments:[{view: screen.createView(), loadOp:'clear',
                clearValue: [0,0,0,0], storeOp:'store'}]});
            pass.setPipeline(this.present);
            pass.setBindGroup(0, group);
            pass.draw(3);
            pass.end();
        }
        d.queue.submit([encoder.finish()]);
    }

    dispose() {
        if (this.disposed) return;
        this.disposed = true;
        this.unwatch?.();
        this.instanceUploads = null;
        this.frameRenderer?.dispose();
        this.context?.unconfigure();
        this.transparentRoot?.destroy();
        this.cycleRoot?.destroy();
        this.cycleClear?.destroy();
        this.instances?.destroy();
        this.emptyPage.destroy();
        for (const atlas of this.glyphPages) atlas?.texture.destroy();
        for (const atlas of this.imagePages) atlas?.texture.destroy();
        for (const slot of this.uniforms) slot.buffer.destroy();
        this.device.destroy();
    }
}
