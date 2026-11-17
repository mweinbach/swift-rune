import { RuneWebFrameRenderer, decodeWebSurfaces } from './rune-webgl-frame.mjs';

// The WASI reactor retains layout and input. Each packet contains the same device-pixel
// RenderInstance stream used by Metal and desktop GL. Unchanged atlases stay on the GPU.
const stride = 128;
const headerBytes = 56;
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
        this.atlases = [];
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
            for (let i = 0; i < 2; ++i) this.atlases.push({ texture: gl.createTexture() });
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

    atlas(slot, width, height, internal, format, update) {
        const gl = this.gl;
        const atlas = this.atlases[slot];
        gl.activeTexture(gl.TEXTURE0 + slot);
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

    drawInstances(first, count, destination, depth, additive) {
        if (!count) return;
        const gl = this.gl;
        const { program, uniforms: u } = this.primitive;
        gl.bindFramebuffer(gl.FRAMEBUFFER, destination.fbo);
        gl.useProgram(program);
        gl.bindVertexArray(this.primitiveVAO);
        gl.bindBuffer(gl.ARRAY_BUFFER, this.instances);
        for (let i = 0; i < 7; ++i) gl.vertexAttribPointer(i, 4, gl.FLOAT, false, stride, first * stride + i * 16);
        gl.vertexAttribIPointer(7, 4, gl.UNSIGNED_INT, stride, first * stride + 112);
        gl.viewport(0, 0, destination.width, destination.height);
        gl.uniform2f(u.uViewport, destination.width, destination.height);
        if (u.uOrigin) gl.uniform2f(u.uOrigin, destination.x, destination.y);
        gl.uniform1i(u.uSRGBBlend, this.srgbBlend ? 1 : 0);
        gl.uniform1i(u.uInLayer, depth ? 1 : 0);
        gl.uniform1i(u.uGlyphAtlas, 0);
        gl.uniform1i(u.uImageAtlas, 1);
        for (let i = 0; i < 2; ++i) {
            gl.activeTexture(gl.TEXTURE0 + i);
            gl.bindTexture(gl.TEXTURE_2D, this.atlases[i].texture);
        }
        gl.enable(gl.BLEND);
        gl.blendFunc(gl.ONE, additive ? gl.ONE : gl.ONE_MINUS_SRC_ALPHA);
        gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, count);
    }

    draw(memory, pointer, length) {
        if (length < headerBytes || pointer % 4) throw new Error('Invalid Rune scene header');
        const h = new Uint32Array(memory, pointer, headerBytes / 4);
        if (h[0] !== 0x32475352) throw new Error('Unsupported Rune GPU scene format');
        const [, width, height, flags, count, gw, gh, iw, ih] = h;
        if ([width, height, gw, gh, iw, ih].some(n => !n || n > this.maxSize)) {
            throw new Error(`Rune scene exceeds WebGL texture limits (${this.maxSize})`);
        }
        const primitiveBytes = count * stride;
        let offset = headerBytes + primitiveBytes;
        if (length < offset) throw new Error('Invalid Rune scene length');
        const packet = new DataView(memory, pointer, length);
        let sequence, duplicate = false;
        if (flags & 32) {
            const previous = packet.getUint32(offset, true);
            sequence = packet.getUint32(offset + 4, true);
            offset += 8;
            duplicate = sequence === this.atlasSequence;
            if (!duplicate && (flags & 6) !== 6 && previous !== this.atlasSequence) {
                throw new Error('Rune atlas patch requires its matching resident scene');
            }
        }
        function readAtlas(width, height, channels, fullFlag, patchFlag) {
            const full = !!(flags & fullFlag);
            let x = 0, y = 0, w = width, h = height;
            if (flags & patchFlag) {
                if (full || sequence === undefined) throw new Error('Invalid Rune atlas flags');
                x = packet.getUint32(offset, true);
                y = packet.getUint32(offset + 4, true);
                w = packet.getUint32(offset + 8, true);
                h = packet.getUint32(offset + 12, true);
                offset += 16;
                if (!w || !h || x + w > width || y + h > height) throw new Error('Rune atlas patch exceeds its texture');
            } else if (!full) { return null; }
            const size = w * h * channels;
            if (size > length - offset) throw new Error('Truncated Rune atlas data');
            const data = new Uint8Array(memory, pointer + offset, size);
            offset += size;
            return { full, x, y, width: w, height: h, data };
        }
        const glyphs = readAtlas(gw, gh, 1, 2, 8);
        const images = readAtlas(iw, ih, 4, 4, 16);
        const surfaces = decodeWebSurfaces(memory, pointer + offset, pointer + length, h[13]);
        const gl = this.gl;
        this.resize(width, height);
        const clear = new Float32Array(memory, pointer + 36, 4);
        const instances = new Float32Array(memory, pointer + headerBytes, count * 32);
        this.srgbBlend = !!(flags & 1);
        if (!duplicate) {
            this.atlas(0, gw, gh, gl.R8, gl.RED, glyphs);
            this.atlas(1, iw, ih, gl.SRGB8_ALPHA8, gl.RGBA, images);
            this.atlasSequence = sequence;
        }
        gl.viewport(0, 0, width, height);
        gl.bindBuffer(gl.ARRAY_BUFFER, this.instances);
        gl.bufferData(gl.ARRAY_BUFFER, instances, gl.DYNAMIC_DRAW);
        for (const target of this.targets) target.used = false;
        // Metal stores each root blend in UNorm8. An sRGB attachment preserves linear blending.
        const root = this.target(0, 0, width, height, this.rootFormat);
        this.info.colorTarget = this.srgbBlend ? 'RGBA8' : 'SRGB8_ALPHA8';
        this.info.layerTarget = this.floatTargets ? 'RGBA16F' : this.info.colorTarget;
        gl.bindFramebuffer(gl.FRAMEBUFFER, root.fbo);
        gl.clearColor(clear[0], clear[1], clear[2], clear[3]);
        gl.clear(gl.COLOR_BUFFER_BIT);
        this.frameRenderer.render({ instances, count, width, height, surfaces, root, clear, srgbBlend: this.srgbBlend });
        this.targets = this.targets.filter(target => {
            if (target.used) return true;
            gl.deleteFramebuffer(target.fbo);
            gl.deleteTexture(target.texture);
            return false;
        });
    }

    dispose() {
        this.frameRenderer?.dispose();
        const gl = this.gl;
        this.clearTargets();
        for (const atlas of this.atlases) gl.deleteTexture(atlas.texture);
        gl.deleteProgram(this.primitive?.program ?? null);
        gl.deleteProgram(this.layer?.program ?? null);
        gl.deleteBuffer(this.vertices ?? null);
        gl.deleteBuffer(this.instances ?? null);
        gl.deleteVertexArray(this.primitiveVAO ?? null);
        gl.deleteVertexArray(this.fullscreenVAO ?? null);
    }
}
