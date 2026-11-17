import { makeProgram } from './rune-webgl.mjs';
import { RuneWebBlur } from './rune-webgl-blur.mjs';
import { LayerCache } from './rune-gpu-layer-cache.mjs';
import { planLayerRects } from './rune-webgl-layers.mjs';

function halfFloat(bits) {
    const exponent = (bits >>> 10) & 31, mantissa = bits & 1023;
    const value = exponent === 0 ? mantissa * (2 ** -24) : (1024 + mantissa) * (2 ** (exponent - 25));
    return bits & 0x8000 ? -value : value;
}

// Packed parent edge fades and corner radii occupy the last 16 bytes of RenderInstance.
function bindMarker(gl, layer, marker, isGroup) {
    const u = layer.uniforms;
    const packed = new Uint32Array(marker.buffer, marker.byteOffset + 112, 4);
    const widths = [], offsets = [], corners = [];
    const mixed = (packed[3] & 0x60000000) === 0x60000000;
    const radiusStep = (packed[3] & 0x80000000 ? -1 : 1) * (packed[3] & 0x10000000 ? 2 : 0.5);
    for (let i = 0; i < 4; ++i) {
        widths.push(halfFloat(packed[i >> 1] >>> ((i & 1) * 16)));
        offsets.push(((packed[2] >>> (8 * i)) & 255) / 255);
        corners.push(mixed ? ((packed[3] >>> (7 * i)) & 127) * radiusStep : marker[31]);
    }
    gl.useProgram(layer.program);
    gl.uniform1i(u.uFrameStyle, isGroup && marker[16] >= 0.5 ? 2 : 1);
    gl.uniform4fv(u.uFrameClip, marker, 24, 4);
    gl.uniform4fv(u.uClipWidths, widths);
    gl.uniform4fv(u.uClipOffsets, offsets);
    gl.uniform4fv(u.uClipCorners, corners);
    gl.uniform4fv(u.uRect, marker, 0, 4);
    gl.uniform4fv(u.uRadii, marker, 4, 4);
    // Cached layers use radii to encode their identity rather than a radial hole.
    if (isGroup && marker[19] < 0.5) gl.uniform4fv(u.uHole, marker, 4, 4);
    else gl.uniform4f(u.uHole, 0, 0, 0, 0);
    gl.uniform4f(u.uPose, marker[14], marker[15], marker[13], marker[11]);
}

function captureLayer(driver, source, x, y, w, h) {
    let target = source;
    if (source.width !== w || source.height !== h) {
        target = driver.target(x, y, w, h);
        const gl = driver.gl;
        gl.bindFramebuffer(gl.READ_FRAMEBUFFER, source.fbo);
        gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, target.fbo);
        const left = x - source.x, bottom = source.height - (y - source.y) - h;
        gl.blitFramebuffer(left, bottom, left + w, bottom + h, 0, 0, w, h, gl.COLOR_BUFFER_BIT, gl.NEAREST);
    }
    // Transfer the pooled target to the cache; it may outlive a canvas resize.
    const pooled = driver.targets.indexOf(target);
    if (pooled < 0) throw new Error('Retained Rune layer does not own a render target');
    driver.targets.splice(pooled, 1);
    return target;
}

export class RuneWebFrameRenderer {
    constructor(driver, sources) {
        this.driver = driver;
        this.gl = driver.gl;
        this.images = new Map();
        this.sources = sources;
        this.cache = new LayerCache(driver.floatTargets ? 8 : 4,
            (...args) => captureLayer(driver, ...args),
            target => {
                this.gl.deleteTexture(target.texture);
                this.gl.deleteFramebuffer(target.fbo);
            });
        this.timings = [];
    }

    takeCachedLayers(full = false) { return this.cache.takeChanges(full); }

    submitSurfaceTiming() {
        const timing = this.driver.surfaceTiming;
        if (!this.surfaceFrame || !timing) return;
        this.surfaceFrame = false;
        const token = timing.submitted();
        if (!token) return;
        const gl = this.gl;
        const fence = gl.fenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (!fence) {
            timing.completed(token, false);
            return;
        }
        gl.flush();
        this.timings.push({ token, fence });
        // An embedder can render synchronously many times within a single JS turn.
        // Bound the submitted frames retained by both GL and the reactor.
        if (this.timings.length >= 8) {
            gl.finish();
            this.drainTimings(!gl.isContextLost());
        } else if (this.timer === undefined) {
            this.timer = setTimeout(() => this.pollTimings(), 4);
        }
    }

    pollTimings() {
        this.timer = undefined;
        const gl = this.gl;
        if (gl.isContextLost()) {
            this.cancelTimings();
            return;
        }
        while (this.timings.length) {
            const { token, fence } = this.timings[0];
            const status = gl.clientWaitSync(fence, 0, 0);
            if (status === gl.TIMEOUT_EXPIRED) {
                this.timer = setTimeout(() => this.pollTimings(), 8);
                return;
            }
            this.timings.shift();
            gl.deleteSync(fence);
            this.driver.surfaceTiming.completed(token, status === gl.ALREADY_SIGNALED || status === gl.CONDITION_SATISFIED);
        }
    }

    drainTimings(success) {
        clearTimeout(this.timer);
        this.timer = undefined;
        for (const { token, fence } of this.timings.splice(0)) {
            if (!this.gl.isContextLost()) this.gl.deleteSync(fence);
            this.driver.surfaceTiming.completed(token, success);
        }
    }

    cancelTimings() {
        this.surfaceFrame = false;
        this.drainTimings(false);
    }

    texturePlane(texture, width, height, store, format, bytes, reallocate) {
        const gl = this.gl;
        gl.bindTexture(gl.TEXTURE_2D, texture);
        if (reallocate) {
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
            gl.texImage2D(gl.TEXTURE_2D, 0, store, width, height, 0, format, gl.UNSIGNED_BYTE, bytes);
        } else {
            gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height, format, gl.UNSIGNED_BYTE, bytes);
        }
    }

    prepareSurface(draw) {
        const { gl, driver } = this;
        if (!this.surface) this.surface = makeProgram(gl, this.sources['surface.vert'], this.sources['surface.frag']);
        let resident = this.images.get(draw.key);
        const sameShape = resident?.width === draw.width && resident?.height === draw.height && resident?.format === draw.format;
        if (draw.primary.length) {
            if (draw.width > driver.maxSize || draw.height > driver.maxSize) throw new Error('Rune surface exceeds GL limits');
            if (!resident) {
                resident = { planes: [gl.createTexture(), gl.createTexture()] };
                this.images.set(draw.key, resident);
            }
            const nv12 = draw.format === 1 || draw.format === 2;
            gl.activeTexture(gl.TEXTURE0);
            this.texturePlane(resident.planes[0], draw.width, draw.height, nv12 ? gl.R8 : gl.RGBA8,
                nv12 ? gl.RED : gl.RGBA, draw.primary, !sameShape);
            if (nv12) this.texturePlane(resident.planes[1], draw.width / 2, draw.height / 2,
                gl.RG8, gl.RG, draw.chroma, !sameShape);
            Object.assign(resident, { width: draw.width, height: draw.height, format: draw.format, revision: draw.revision });
        } else if (!sameShape || resident.revision !== draw.revision) {
            throw new Error('Rune surface references an unavailable texture revision');
        }
    }

    drawSurface(draw, level) {
        const { gl, driver } = this;
        const resident = this.images.get(draw.key);
        const target = level.target;
        gl.viewport(0, 0, target.width, target.height);
        gl.bindFramebuffer(gl.FRAMEBUFFER, target.fbo);
        gl.useProgram(this.surface.program);
        gl.bindVertexArray(driver.fullscreenVAO);
        const u = this.surface.uniforms;
        gl.uniform4fv(u['uSurface[0]'], draw.uniforms);
        gl.uniform4f(u['uSurface[0]'], target.width, target.height, target.x, target.y);
        gl.uniform1i(u.uPlane0, 0);
        gl.uniform1i(u.uPlane1, 1);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, resident.planes[0]);
        gl.activeTexture(gl.TEXTURE1);
        gl.bindTexture(gl.TEXTURE_2D, resident.planes[draw.format === 1 || draw.format === 2 ? 1 : 0]);
        gl.enable(gl.BLEND);
        gl.blendFunc(gl.ONE, level.additive ? gl.ONE : gl.ONE_MINUS_SRC_ALPHA);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    }

    filters() {
        if (!this.blur) this.blur = new RuneWebBlur(this.driver, this.sources);
        return this.blur;
    }

    effect(marker, stack, index) {
        const { driver, gl } = this;
        if (!driver.drawEffect) return false;
        const level = stack.at(-1);
        const { x, y, width, height, fbo } = level.target;
        const bleed = Math.max(0, marker[18]);
        const x0 = Math.max(0, Math.floor(Math.max(marker[24], marker[0] - bleed)) - x);
        const y0 = Math.max(0, Math.floor(Math.max(marker[25], marker[1] - bleed)) - y);
        const x1 = Math.min(width, Math.ceil(Math.min(marker[26], marker[0] + marker[2] + bleed)) - x);
        const y1 = Math.min(height, Math.ceil(Math.min(marker[27], marker[1] + marker[3] + bleed)) - y);
        if (x1 <= x0 || y1 <= y0) return false;
        let snapshot = null;
        let backdrop = null;
        gl.disable(gl.SCISSOR_TEST);
        if (marker[16] >= 0.5) {
            // Effect backdrops use the root viewport, even when drawing into a cropped layer.
            backdrop = level.target.texture;
            if (x || y || width !== driver.width || height !== driver.height) {
                snapshot = driver.target();
                gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, snapshot.fbo);
                gl.clearColor(0, 0, 0, 0);
                gl.clear(gl.COLOR_BUFFER_BIT);
                gl.bindFramebuffer(gl.READ_FRAMEBUFFER, fbo);
                const left = Math.max(0, x), top = Math.max(0, y);
                const right = Math.min(driver.width, x + width), bottom = Math.min(driver.height, y + height);
                if (left < right && top < bottom) {
                    gl.blitFramebuffer(left - x, height - (bottom - y), right - x, height - (top - y),
                        left, driver.height - bottom, right, driver.height - top, gl.COLOR_BUFFER_BIT, gl.NEAREST);
                }
                backdrop = snapshot.texture;
            }
        }
        // A hook controls its own WebGL state and can remove its scissor. Seed its
        // private target, then commit only the clipped portion on success.
        const scratch = driver.target(x, y, width, height, level.target.format);
        const copyClip = (source, destination) => {
            gl.bindFramebuffer(gl.READ_FRAMEBUFFER, source);
            gl.readBuffer(gl.COLOR_ATTACHMENT0);
            gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, destination);
            gl.drawBuffers([gl.COLOR_ATTACHMENT0]);
            gl.blitFramebuffer(x0, height - y1, x1, height - y0, x0, height - y1, x1, height - y0, gl.COLOR_BUFFER_BIT, gl.NEAREST);
        };
        copyClip(fbo, scratch.fbo);
        gl.bindFramebuffer(gl.FRAMEBUFFER, scratch.fbo);
        gl.viewport(0, 0, width, height);
        gl.bindVertexArray(null);
        gl.useProgram(null);
        gl.enable(gl.BLEND);
        gl.blendFunc(gl.ONE, level.additive ? gl.ONE : gl.ONE_MINUS_SRC_ALPHA);
        gl.enable(gl.SCISSOR_TEST);
        gl.scissor(x0, height - y1, x1 - x0, y1 - y0);
        let opacity = 1, turn = 0;
        for (const group of stack) {
            if (!group.marker) continue;
            opacity *= group.marker[11];
            if (group.marker[13] !== 0) turn = group.marker[13];
        }
        let commit = false;
        try {
            const result = driver.drawEffect({
                gl, framebuffer: scratch.fbo, backdrop, index,
                mark: ((marker[12] & 65535) | ((marker[13] & 65535) << 16)) >>> 0,
                data: marker.slice(20, 24), rect: marker.slice(0, 4), clip: marker.slice(24, 28),
                scale: marker[19], width, height, origin: [x, y], inLayer: stack.length > 1, opacity, turn,
                srgbBlend: driver.srgbBlend
            });
            if (result && typeof result.then === 'function') throw new Error('Rune WebGL effect callbacks must draw synchronously');
            commit = result !== false;
        } finally {
            if (snapshot) snapshot.inUse = false;
            // Restore the state used by Rune draws and atlas uploads; the callback owns its
            // program, buffers and VAO and must leave the borrowed attachments intact.
            gl.bindFramebuffer(gl.FRAMEBUFFER, level.target.fbo);
            gl.drawBuffers([gl.COLOR_ATTACHMENT0]);
            gl.viewport(0, 0, width, height);
            for (const cap of [gl.SCISSOR_TEST, gl.STENCIL_TEST, gl.DEPTH_TEST, gl.CULL_FACE, gl.DITHER,
                gl.RASTERIZER_DISCARD, gl.SAMPLE_COVERAGE, gl.SAMPLE_ALPHA_TO_COVERAGE]) gl.disable(cap);
            gl.colorMask(true, true, true, true);
            gl.blendEquation(gl.FUNC_ADD);
            gl.bindSampler(0, null);
            gl.bindSampler(1, null);
            gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
            gl.bindBuffer(gl.PIXEL_UNPACK_BUFFER, null);
            gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
            for (const setting of [gl.UNPACK_ROW_LENGTH, gl.UNPACK_SKIP_ROWS, gl.UNPACK_SKIP_PIXELS,
                gl.UNPACK_FLIP_Y_WEBGL, gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL]) gl.pixelStorei(setting, 0);
            if (commit) copyClip(scratch.fbo, fbo);
            scratch.inUse = false;
            gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
        }
        return true;
    }

    render({ instances, count, surfaces, root }) {
        const { gl, driver } = this;
        const stack = [{ target: root, additive: false }];
        let first = 0, surface = 0, backdrops = 0, effectIndex = 0;
        const flush = end => {
            const level = stack.at(-1);
            if (level.target) driver.drawInstances(instances, first, end - first, level.target, stack.length - 1, level.additive);
            first = end;
        };
        try {
            const rects = planLayerRects(instances, driver.width, driver.height, surfaces);
            this.cache.begin(instances);
            for (const draw of surfaces) this.prepareSurface(draw);
            for (let i = 0; i <= count; ++i) {
                // The native hosts accept UInt32.max as the topmost painter position.
                while (surface < surfaces.length && (surfaces[surface].before <= i || i === count)) {
                    flush(i);
                    if (stack.at(-1).target) this.drawSurface(surfaces[surface], stack.at(-1));
                    ++surface;
                }
                if (i === count) break;
                const kind = instances[i * 32 + 17];
                if (kind !== 8 && kind !== 9 && kind !== 12 && kind !== 13) continue;
                flush(i);
                first = i + 1;
                const marker = instances.subarray(i * 32, (i + 1) * 32);
                if (kind === 8) {
                    const rect = rects.get(i);
                    let target = null;
                    if (stack.at(-1).target && rect && rect[2] > 0 && rect[3] > 0) {
                        const parent = stack.at(-1);
                        const hit = marker[19] >= 0.5 && this.cache.lookup(marker);
                        if (hit) {
                            bindMarker(gl, driver.layer, marker, true);
                            driver.fullscreen(1, parent.target, hit, hit, parent.additive);
                        } else {
                            target = driver.target(...rect);
                            gl.bindFramebuffer(gl.FRAMEBUFFER, target.fbo);
                            gl.clearColor(0, 0, 0, 0);
                            gl.clear(gl.COLOR_BUFFER_BIT);
                        }
                    }
                    stack.push({ target, marker, additive: marker[16] >= 0.5 });
                } else if (kind === 9) {
                    if (stack.length < 2) throw new Error('Unexpected Rune GL layer end');
                    const group = stack.pop();
                    const parent = stack.at(-1);
                    if (!group.target) continue;
                    const source = group.marker[18] >= 0.05 ? this.filters().layer(group.target, group.marker,
                        group.additive, [0, 0, group.target.width, group.target.height]) : group.target;
                    bindMarker(gl, driver.layer, group.marker, true);
                    driver.fullscreen(1, parent.target, source, source, parent.additive);
                    if (group.marker[19] >= 0.5) this.cache.store(group.marker, source);
                    source.inUse = group.target.inUse = false;
                } else if (!stack.at(-1).target) {
                    continue;
                } else if (kind === 12) {
                    if (this.effect(marker, stack, effectIndex)) ++effectIndex;
                } else if (kind === 13 && backdrops++ < 4 && marker[16] > 0 && marker[11] > 0) {
                    const level = stack.at(-1);
                    const { x, y, width, height } = level.target;
                    const local = marker.slice();
                    local[0] -= x; local[1] -= y;
                    local[24] -= x; local[25] -= y;
                    local[26] -= x; local[27] -= y;
                    const blurred = this.filters().backdrop(level.target, local);
                    if (blurred === level.target) continue;
                    const combined = driver.target(x, y, width, height, level.target.format);
                    bindMarker(gl, driver.layer, marker, false);
                    driver.fullscreen(2, combined, level.target, blurred);
                    blurred.inUse = level.target.inUse = false;
                    level.target = combined;
                }
            }
            if (stack.length !== 1) throw new Error('Unclosed Rune GL layer');
            flush(count);
            driver.fullscreen(6, null, stack[0].target);
            this.prune(new Set(surfaces.map(draw => draw.key)));
            this.surfaceFrame = surfaces.length > 0;
        } catch (error) {
            this.cache.clear();
            throw error;
        } finally {
            for (const target of driver.targets) target.inUse = false;
        }
    }

    prune(used) {
        for (const [key, entry] of this.images) {
            if (used.has(key)) continue;
            for (const texture of entry.planes) this.gl.deleteTexture(texture);
            this.images.delete(key);
        }
    }

    dispose() {
        this.cancelTimings();
        this.cache.clear();
        this.prune(new Set());
        if (this.surface) this.gl.deleteProgram(this.surface.program);
        this.blur?.dispose();
    }
}
