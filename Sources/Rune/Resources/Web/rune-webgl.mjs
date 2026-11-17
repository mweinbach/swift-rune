import { RuneInstanceUploads } from './rune-instance-uploads.mjs';
import { RuneCycleScene } from './rune-web-cycles.mjs';
import { RuneWebFrameRenderer } from './rune-webgl-frame.mjs';

// The WASI reactor retains layout and input. Each packet contains the same device-pixel
// RenderInstance stream used by Metal and desktop GL. Unchanged atlases stay on the GPU.
const stride = 128;
const shaderFiles = ['frame.vert', 'frame.frag', 'fullscreen.vert', 'layer.frag', 'surface.vert', 'surface.frag', 'frame_blur.frag'];

export async function loadRuneShaders(directory = new URL('../GL/', import.meta.url)) {
    const base = new URL(directory, import.meta.url);
    return Object.fromEntries(await Promise.all(shaderFiles.map(async name => {
        const url = new URL(name, base);
        const response = await fetch(url);
        if (!response.ok) throw new Error(`Rune shader ${url} returned HTTP ${response.status}`);
        return [name, await response.text()];
    })));
}

export function makeProgram(gl, vertex, fragment) {
    const program = gl.createProgram();
    const sources = [vertex, fragment];
    try {
        for (const [i, type] of [gl.VERTEX_SHADER, gl.FRAGMENT_SHADER].entries()) {
            const shader = gl.createShader(type);
            // WebGL requires an active per-vertex attribute even for procedural quads.
            const vertexID = i === 0 ? 'layout(location=9) in float runeVertexID;\n#define RUNE_VERTEX_ID int(runeVertexID)\n' : '';
            gl.shaderSource(shader, '#version 300 es\nprecision highp float;\nprecision highp int;\n' + vertexID + sources[i]);
            gl.compileShader(shader);
            if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
                const log = gl.getShaderInfoLog(shader);
                gl.deleteShader(shader);
                throw new Error('Rune WebGL shader compilation failed: ' + log);
            }
            gl.attachShader(program, shader);
            gl.deleteShader(shader);
        }
        gl.linkProgram(program);
        if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
            throw new Error('Rune WebGL program link failed: ' + gl.getProgramInfoLog(program));
        }
        const uniforms = {};
        for (let i = 0; i < gl.getProgramParameter(program, gl.ACTIVE_UNIFORMS); ++i) {
            const name = gl.getActiveUniform(program, i).name;
            uniforms[name] = gl.getUniformLocation(program, name);
        }
        return { program, uniforms };
    } catch (error) {
        gl.deleteProgram(program);
        throw error;
    }
}

function setSampling(gl) {
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
}

export class RuneWebGL {
    constructor(canvas, sources, { drawEffect, surfaceTiming } = {}) {
        const gl = canvas.getContext('webgl2', {
            alpha: true, premultipliedAlpha: false, depth: false, stencil: false, antialias: false
        });
        if (!gl) throw new Error('WebGL 2 is unavailable for this canvas');
        this.gl = gl;
        this.drawEffect = drawEffect;
        this.surfaceTiming = surfaceTiming;
        this.targets = [];
        this.imagePages = [];
        this.glyphPages = [];
        this.instanceUploads = new RuneInstanceUploads();
        this.maxSize = gl.getParameter(gl.MAX_TEXTURE_SIZE);
        this.floatTargets = !!gl.getExtension('EXT_color_buffer_float');
        const debug = gl.getExtension('WEBGL_debug_renderer_info');
        this.info = {
            api: 'WebGL 2',
            vendor: gl.getParameter(debug ? debug.UNMASKED_VENDOR_WEBGL : gl.VENDOR),
            renderer: gl.getParameter(debug ? debug.UNMASKED_RENDERER_WEBGL : gl.RENDERER),
            version: gl.getParameter(gl.VERSION),
            colorTarget: null,
            layerTarget: this.floatTargets ? 'RGBA16F' : null
        };
        try {
            this.primitive = makeProgram(gl, sources['frame.vert'], sources['frame.frag']);
            this.layer = makeProgram(gl, sources['fullscreen.vert'], sources['layer.frag']);
            this.instances = gl.createBuffer();
            this.vertices = gl.createBuffer();
            gl.bindBuffer(gl.ARRAY_BUFFER, this.vertices);
            gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 1, 2, 3]), gl.STATIC_DRAW);
            this.primitiveVAO = gl.createVertexArray();
            this.fullscreenVAO = gl.createVertexArray();
            for (const vao of [this.primitiveVAO, this.fullscreenVAO]) {
                gl.bindVertexArray(vao);
                gl.enableVertexAttribArray(9);
                gl.vertexAttribPointer(9, 1, gl.FLOAT, false, 0, 0);
            }
            gl.bindVertexArray(this.primitiveVAO);
            gl.bindBuffer(gl.ARRAY_BUFFER, this.instances);
            for (let i = 0; i < 8; ++i) {
                gl.enableVertexAttribArray(i);
                gl.vertexAttribDivisor(i, 1);
            }
            this.emptyImage = { texture: gl.createTexture() };
            this.atlas(this.emptyImage, 1, 1, gl.SRGB8_ALPHA8, gl.RGBA, {full: true, data: new Uint8Array(4)});
            gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
            gl.disable(gl.DITHER);
            this.frameRenderer = new RuneWebFrameRenderer(this, sources);
        } catch (error) {
            this.dispose();
            throw error;
        }
    }

    get rootFormat() { return this.srgbBlend ? this.gl.RGBA8 : this.gl.SRGB8_ALPHA8; }
    get layerFormat() { return this.floatTargets ? this.gl.RGBA16F : this.rootFormat; }

    target(x = 0, y = 0, width = this.width, height = this.height, format = this.layerFormat) {
        const gl = this.gl;
        if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1 ||
            width > this.maxSize || height > this.maxSize) throw new Error('Invalid WebGL layer dimensions');
        let target = this.targets.find(t => !t.inUse && t.width === width && t.height === height && t.format === format)
            ?? this.targets.find(t => !t.inUse);
        if (!target) {
            target = { fbo: gl.createFramebuffer(), texture: gl.createTexture() };
            this.targets.push(target);
        }
        if (target.width !== width || target.height !== height || target.format !== format) {
            gl.bindTexture(gl.TEXTURE_2D, target.texture);
            gl.texImage2D(gl.TEXTURE_2D, 0, format, width, height,
                0, gl.RGBA, format === gl.RGBA16F ? gl.HALF_FLOAT : gl.UNSIGNED_BYTE, null);
            setSampling(gl);
            gl.bindFramebuffer(gl.FRAMEBUFFER, target.fbo);
            gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, target.texture, 0);
            if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) {
                throw new Error('Could not allocate a WebGL render target');
            }
        }
        Object.assign(target, { x, y, width, height, format, inUse: true, used: true });
        return target;
    }

    resize(width, height) {
        if (this.width === width && this.height === height) return;
        this.clearTargets();
        this.width = width;
        this.height = height;
        const canvas = this.gl.canvas;
        if (canvas.width !== width) canvas.width = width;
        if (canvas.height !== height) canvas.height = height;
    }

    clearTargets() {
        const gl = this.gl;
        for (const target of this.targets) {
            gl.deleteFramebuffer(target.fbo);
            gl.deleteTexture(target.texture);
        }
        this.targets.length = 0;
    }

    atlas(atlas, width, height, internal, format, update) {
        const gl = this.gl;
        if (!update && atlas.width === width && atlas.height === height && atlas.internal === internal) return;
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, atlas.texture);
        if (atlas.width !== width || atlas.height !== height || atlas.internal !== internal) {
            if (!update?.full) throw new Error('Rune scene needs a complete atlas for this WebGL context');
            gl.texImage2D(gl.TEXTURE_2D, 0, internal, width, height, 0, format, gl.UNSIGNED_BYTE, update.data);
            setSampling(gl);
            Object.assign(atlas, { width, height, internal });
        } else if (update) {
            gl.texSubImage2D(gl.TEXTURE_2D, 0, update.x, update.y, update.width, update.height, format, gl.UNSIGNED_BYTE, update.data);
        }
    }

    syncAtlases(glyphs, images) {
        const gl = this.gl;
        const allocated = [];
        const prepare = (resident, pages, internal, format) => pages.map((page, index) => {
            if (!page.width) return null;
            const old = resident[index];
            if (old?.width === page.width && old.height === page.height) return old;
            if (!page.update?.full) throw new Error('Rune texture page needs a complete atlas for this WebGL context');
            const texture = gl.createTexture();
            if (!texture) throw new Error('Could not allocate Rune WebGL atlas texture');
            allocated.push(texture);
            const atlas = {texture};
            this.atlas(atlas, page.width, page.height, internal, format, page.update);
            const error = gl.getError();
            if (error !== gl.NO_ERROR) throw new Error('Could not allocate Rune WebGL atlas storage (' + error + ')');
            return atlas;
        });
        let nextGlyphs, nextImages;
        try {
            // An allocation can fail after an earlier page succeeded. Keep the old banks
            // usable until replacements for both texture formats are ready.
            nextGlyphs = prepare(this.glyphPages, glyphs, gl.R8, gl.RED);
            nextImages = prepare(this.imagePages, images, gl.SRGB8_ALPHA8, gl.RGBA);
        } catch (error) {
            for (const texture of allocated) gl.deleteTexture(texture);
            throw error;
        }
        const commit = (old, next, pages, internal, format) => {
            for (let i = 0; i < old.length; ++i) {
                const atlas = old[i];
                if (!atlas) continue;
                if (atlas !== next[i]) gl.deleteTexture(atlas.texture);
                else if (pages[i].update) this.atlas(atlas, atlas.width, atlas.height, internal, format, pages[i].update);
            }
        };
        commit(this.glyphPages, nextGlyphs, glyphs, gl.R8, gl.RED);
        commit(this.imagePages, nextImages, images, gl.SRGB8_ALPHA8, gl.RGBA);
        this.glyphPages = nextGlyphs;
        this.imagePages = nextImages;
    }

    fullscreen(mode, destination, source, second = source, additive = false) {
        const gl = this.gl;
        const { program, uniforms: u } = this.layer;
        gl.bindFramebuffer(gl.FRAMEBUFFER, destination?.fbo ?? null);
        gl.viewport(0, 0, destination?.width ?? this.width, destination?.height ?? this.height);
        gl.useProgram(program);
        gl.bindVertexArray(this.fullscreenVAO);
        if (u.uTargetRect) gl.uniform4f(u.uTargetRect, destination?.x ?? 0, destination?.y ?? 0,
            destination?.width ?? this.width, destination?.height ?? this.height);
        if (u.uSourceRect) gl.uniform4f(u.uSourceRect, source.x, source.y, source.width, source.height);
        gl.uniform1i(u.uMode, mode);
        gl.uniform1i(u.uSRGBBlend, this.srgbBlend ? 1 : 0);
        gl.uniform1i(u.uDisplaySRGB, 0);
        gl.uniform1i(u.uSource, 0);
        gl.uniform1i(u.uBlurred, 1);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, source.texture);
        gl.activeTexture(gl.TEXTURE1);
        gl.bindTexture(gl.TEXTURE_2D, second.texture);
        if (mode === 1) {
            gl.enable(gl.BLEND);
            gl.blendFunc(gl.ONE, additive ? gl.ONE : gl.ONE_MINUS_SRC_ALPHA);
        } else {
            gl.disable(gl.BLEND);
        }
        gl.drawArrays(gl.TRIANGLES, 0, 3);
    }

    drawInstances(instances, first, count, destination, depth, additive) {
        if (!count) return;
        const gl = this.gl;
        const { program, uniforms: u } = this.primitive;
        gl.bindFramebuffer(gl.FRAMEBUFFER, destination.fbo);
        gl.useProgram(program);
        gl.bindVertexArray(this.primitiveVAO);
        gl.bindBuffer(gl.ARRAY_BUFFER, this.instances);
        gl.viewport(0, 0, destination.width, destination.height);
        gl.uniform2f(u.uViewport, destination.width, destination.height);
        if (u.uOrigin) gl.uniform2f(u.uOrigin, destination.x, destination.y);
        gl.uniform1i(u.uSRGBBlend, this.srgbBlend ? 1 : 0);
        gl.uniform1i(u.uInLayer, depth ? 1 : 0);
        gl.uniform1i(u.uGlyphAtlas, 0);
        gl.uniform1i(u.uImageAtlas, 1);
        gl.enable(gl.BLEND);
        gl.blendFunc(gl.ONE, additive ? gl.ONE : gl.ONE_MINUS_SRC_ALPHA);
        const draw = (start, length, image, glyph) => {
            for (let i = 0; i < 7; ++i) gl.vertexAttribPointer(i, 4, gl.FLOAT, false, stride, start * stride + i * 16);
            gl.vertexAttribIPointer(7, 4, gl.UNSIGNED_INT, stride, start * stride + 112);
            gl.activeTexture(gl.TEXTURE0);
            gl.bindTexture(gl.TEXTURE_2D, (this.glyphPages[glyph] ?? this.emptyImage).texture);
            gl.activeTexture(gl.TEXTURE1);
            gl.bindTexture(gl.TEXTURE_2D, (this.imagePages[image] ?? this.emptyImage).texture);
            gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, length);
        };
        this.instanceUploads.forEachRun(first, count, draw);
    }

    draw(memory, pointer, length, repeatPass = 0) {
        this.cycleScene ??= new RuneCycleScene();
        const scene = this.cycleScene.decode(memory, pointer, length, this.maxSize, this.atlasSequence);
        const {width, height, count, sequence, duplicate, glyphPages, imagePages, surfaces, clear, instances, srgbBlend,
            damage, retainCycleTarget} = scene;
        const gl = this.gl;
        this.resize(width, height);
        this.srgbBlend = srgbBlend;
        if (!duplicate && !repeatPass) {
            this.syncAtlases(glyphPages, imagePages);
            this.atlasSequence = sequence;
        }
        gl.viewport(0, 0, width, height);
        if (!repeatPass) {
            gl.bindBuffer(gl.ARRAY_BUFFER, this.instances);
            const bytes = instances.byteLength;
            const grow = bytes > (this.instanceCapacity ?? 0);
            if (grow) {
                const capacity = 2 ** Math.ceil(Math.log2(bytes));
                gl.bufferData(gl.ARRAY_BUFFER, capacity, gl.DYNAMIC_DRAW);
                this.instanceCapacity = gl.getBufferParameter(gl.ARRAY_BUFFER, gl.BUFFER_SIZE);
                if (this.instanceCapacity < bytes) throw Error('Could not allocate the Rune WebGL instance buffer');
            }
            this.instanceUploads.prepare(scene, grow, (first, end) =>
                gl.bufferSubData(gl.ARRAY_BUFFER, first * stride, instances, first * 32, (end - first) * 32));
        }
        for (const target of this.targets) target.used = false;
        // Metal stores each root blend in UNorm8. An sRGB attachment preserves linear blending.
        const root = this.target(0, 0, width, height, this.rootFormat);
        this.info.colorTarget = this.srgbBlend ? 'RGBA8' : 'SRGB8_ALPHA8';
        this.info.layerTarget = this.floatTargets ? 'RGBA16F' : this.info.colorTarget;
        gl.bindFramebuffer(gl.FRAMEBUFFER, root.fbo);
        gl.clearColor(clear[0], clear[1], clear[2], clear[3]);
        if (damage && this.cycleRoot === root) {
            gl.enable(gl.SCISSOR_TEST);
            try {
                for (const {area: [l,t,r,b], runs} of damage) {
                    gl.scissor(l, height - b, r - l, b - t);
                    gl.clear(gl.COLOR_BUFFER_BIT);
                    for (const [first, end] of runs)
                        this.drawInstances(instances, first, end - first, root, 0, false);
                }
            } finally {
                gl.disable(gl.SCISSOR_TEST);
                root.inUse = false;
            }
            this.fullscreen(6, null, root);
        } else {
            gl.clear(gl.COLOR_BUFFER_BIT);
            this.frameRenderer.render({ instances, count, width, height, surfaces, root, clear, srgbBlend: this.srgbBlend });
        }
        this.cycleRoot = retainCycleTarget ? root : null;
        this.targets = this.targets.filter(target => {
            if (target.used) return true;
            gl.deleteFramebuffer(target.fbo);
            gl.deleteTexture(target.texture);
            return false;
        });
    }

    dispose() {
        this.instanceUploads = null;
        this.frameRenderer?.dispose();
        const gl = this.gl;
        this.clearTargets();
        for (const atlas of [this.emptyImage, ...this.glyphPages, ...this.imagePages]) {
            if (atlas) gl.deleteTexture(atlas.texture);
        }
        gl.deleteProgram(this.primitive?.program ?? null);
        gl.deleteProgram(this.layer?.program ?? null);
        gl.deleteBuffer(this.vertices ?? null);
        gl.deleteBuffer(this.instances ?? null);
        gl.deleteVertexArray(this.primitiveVAO ?? null);
        gl.deleteVertexArray(this.fullscreenVAO ?? null);
    }
}
