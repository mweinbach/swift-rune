import { makeProgram } from './rune-webgl.mjs';

import { backdropSigmas, gaussianTaps, roundUp } from './rune-blur-kernel.mjs';

const pyramidStep = 1 << (backdropSigmas.length - 1);

export class RuneWebBlur {
    constructor(driver, sources) {
        this.driver = driver;
        this.gl = driver.gl;
        this.maximum = this.gl.getParameter(this.gl.MAX_TEXTURE_SIZE);
        this.shader = makeProgram(this.gl, sources['fullscreen.vert'], sources['frame_blur.frag']);
        this.scratch = new Map();
    }

    dispose() {
        const gl = this.gl;
        for (const target of this.scratch.values()) {
            gl.deleteTexture(target.texture);
            gl.deleteFramebuffer(target.fbo);
        }
        this.scratch.clear();
        gl.deleteProgram(this.shader.program);
    }

    target(slot, width, height) {
        const gl = this.gl;
        const existing = this.scratch.get(slot);
        const format = this.driver.layerFormat;
        if (existing?.width === width && existing.height === height && existing.format === format) return existing;
        if (!(width > 0 && height > 0 && width <= this.maximum && height <= this.maximum)) {
            throw new Error('Rune blur exceeds the WebGL texture size limit');
        }
        const fbo = gl.createFramebuffer();
        const texture = gl.createTexture();
        try {
            gl.bindTexture(gl.TEXTURE_2D, texture);
            gl.texStorage2D(gl.TEXTURE_2D, 1, format, width, height);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
            gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
            gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
            if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) {
                throw new Error('Could not allocate a WebGL blur framebuffer');
            }
        } catch (error) {
            gl.deleteFramebuffer(fbo);
            gl.deleteTexture(texture);
            throw error;
        }
        if (existing) {
            gl.deleteFramebuffer(existing.fbo);
            gl.deleteTexture(existing.texture);
        }
        const target = { fbo, texture, width, height, format };
        this.scratch.set(slot, target);
        return target;
    }

    pass(mode, input, target, { fine = input, map = [1, 1, 0, 0], region = [0, 0, 1, 1],
        domain = [0, 0, 0, 0], axis = [0, 0], taps, additive = false, blend = 1 } = {}) {
        const gl = this.gl;
        const { program, uniforms: u } = this.shader;
        const w = target.width ?? this.driver.width;
        const h = target.height ?? this.driver.height;
        gl.disable(gl.BLEND);
        gl.disable(gl.SCISSOR_TEST);
        gl.viewport(0, 0, w, h);
        gl.bindFramebuffer(gl.FRAMEBUFFER, target.fbo);
        gl.useProgram(program);
        gl.bindVertexArray(this.driver.fullscreenVAO);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, input.texture);
        gl.activeTexture(gl.TEXTURE1);
        gl.bindTexture(gl.TEXTURE_2D, fine.texture);
        gl.uniform1i(u.uSource, 0);
        gl.uniform1i(u.uFine, 1);
        gl.uniform1i(u.uMode, mode);
        gl.uniform1i(u.uAdditive, additive ? 1 : 0);
        gl.uniform4f(u.uDest, 0, 0, w, h);
        gl.uniform4fv(u.uMap, map);
        gl.uniform4fv(u.uRegion, region);
        gl.uniform4fv(u.uDomain, domain);
        gl.uniform2fv(u.uAxis, axis);
        gl.uniform1f(u.uBlend, blend);
        if (taps) {
            gl.uniform1i(u.uCount, taps.length / 4);
            gl.uniform4fv(u['uTaps[0]'], taps);
        }
        gl.drawArrays(gl.TRIANGLES, 0, 3);
    }

    layer(source, marker, additive, rect = marker) {
        const sigma = Math.min(marker[18], 64);
        if (!(sigma > 0.05)) return source;
        const width = source.width ?? this.driver.width, height = source.height ?? this.driver.height;
        const halo = Math.ceil(3 * sigma);
        const x = Math.max(-halo, Math.floor(rect[0])), y = Math.max(-halo, Math.floor(rect[1]));
        const right = Math.min(width + halo, Math.ceil(rect[0] + rect[2]));
        const bottom = Math.min(height + halo, Math.ceil(rect[1] + rect[3]));
        if (right <= x || bottom <= y) {
            const gl = this.gl, empty = this.driver.target(source.x ?? 0, source.y ?? 0, width, height);
            gl.bindFramebuffer(gl.FRAMEBUFFER, empty.fbo);
            gl.disable(gl.SCISSOR_TEST);
            gl.clearColor(0, 0, 0, 0);
            gl.clear(gl.COLOR_BUFFER_BIT);
            return empty;
        }
        const w = roundUp(right - x, 64), h = roundUp(bottom - y, 64);
        const reduction = Math.max(1, Math.min(sigma / 3, 8));
        const rw = Math.ceil(w / reduction), rh = Math.ceil(h / reduction);
        const sx = w / rw, sy = h / rh;
        const tapsX = gaussianTaps(sigma, sx), tapsY = gaussianTaps(sigma, sy);
        const reduced = rw !== w || rh !== h;
        if (!reduced && tapsX.length === 4 && tapsY.length === 4) return source;
        const local = [0, 0, rw, rh];
        const domain = [x, y, w, h];
        const ping = this.target('horizontal', rw, rh);
        const pong = this.target('vertical', rw, rh);
        let input = source;
        if (reduced) {
            this.pass(0, source, pong, { domain, additive, map: [sx, sy, 0, 0] });
            input = pong;
        }
        this.pass(1, input, ping, { domain: reduced ? local : domain, axis: [1, 0], taps: tapsX, additive });
        this.pass(1, ping, pong, { domain: local, axis: [0, 1], taps: tapsY, additive });
        const result = this.driver.target(source.x ?? 0, source.y ?? 0, width, height);
        this.pass(2, pong, result, { domain: local, map: [1 / sx, 1 / sy, -x / sx, -y / sy], additive });
        return result;
    }

    backdrop(source, marker) {
        const width = source.width ?? this.driver.width, height = source.height ?? this.driver.height;
        const sigma = marker[16];
        if (!(sigma > 0 && marker[11] > 0) || marker[0] >= width || marker[1] >= height
            || marker[0] + marker[2] <= 0 || marker[1] + marker[3] <= 0) return source;
        const s = Math.max(backdropSigmas[0], Math.min(sigma, backdropSigmas.at(-1)));
        let n = 1;
        while (n < backdropSigmas.length - 1 && s > backdropSigmas[n]) n++;
        const a = backdropSigmas[n - 1], b = backdropSigmas[n];
        const share = (s * s - a * a) / (b * b - a * a);
        const reach = Math.min(sigma, b) * 3 + 2;
        const left = Math.max(0, marker[0] - reach), top = Math.max(0, marker[1] - reach);
        const right = Math.min(width, marker[0] + marker[2] + reach);
        const bottom = Math.min(height, marker[1] + marker[3] + reach);
        if (right <= left || bottom <= top) return source;
        const align = 2 << n;
        const x = Math.floor(left / align) * align, y = Math.floor(top / align) * align;
        const pw = roundUp(Math.ceil((right - x) / 2), pyramidStep);
        const ph = roundUp(Math.ceil((bottom - y) / 2), pyramidStep);
        const extentW = pw * 2, extentH = ph * 2;
        const region = [(left - x) / extentW, (top - y) / extentH, (right - x) / extentW, (bottom - y) / extentH];
        const levels = [];
        let input = source;
        for (let i = 0; i <= n; i++) {
            const target = this.target('down' + i, pw >> i, ph >> i);
            this.pass(3, input, target, i ? { region } : {
                region: [left / width, top / height, right / width, bottom / height],
                map: [extentW / width, extentH / height, x / width, y / height]
            });
            levels.push(target);
            input = target;
        }
        for (let i = n - 1; i >= 0; i--) {
            const target = this.target('up' + i, pw >> i, ph >> i);
            this.pass(4, input, target, { region, fine: levels[i], blend: i === n - 1 ? share : 1 });
            input = target;
        }
        const result = this.driver.target(source.x ?? 0, source.y ?? 0, width, height);
        this.pass(5, input, result, { map: [width / extentW, height / extentH, -x / extentW, -y / extentH] });
        return result;
    }
}
