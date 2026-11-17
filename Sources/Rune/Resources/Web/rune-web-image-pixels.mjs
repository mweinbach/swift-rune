// Browser image decoders can expose 8-bit straight alpha through a DOM texture upload.
// A 2D canvas converts profiled sources to sRGB, including on WebKit where texture
// uploads from HTML images can ignore the embedded profile.
function canvas(width, height) {
    if (typeof document === 'undefined') return new OffscreenCanvas(width, height);
    const surface = document.createElement('canvas');
    surface.width = width; surface.height = height;
    return surface;
}

function context2D(surface) {
    const context = surface.getContext('2d', { colorSpace: 'srgb', willReadFrequently: true });
    if (!context) throw Error('Browser does not provide an RGBA canvas');
    return context;
}

function fillRect(canvas, stride, x, y, width, height, color) {
    // A typed view packs the RGBA bytes in host byte order for a full row fill.
    const value = color?.[3] ? new Uint32Array(Uint8Array.from(color).buffer)[0] : 0;
    const words = new Uint32Array(canvas.buffer, canvas.byteOffset, canvas.length / 4);
    for (let row = y; row < y + height; row++) words.fill(value, row * stride + x, row * stride + x + width);
}

function copyRows(source, sourceStride, sourceOffset, dest, destStride, destOffset, width, height) {
    for (let row = 0; row < height; row++) {
        dest.set(source.subarray(sourceOffset, sourceOffset + width * 4), destOffset);
        sourceOffset += sourceStride * 4;
        destOffset += destStride * 4;
    }
}

function blendOver(dest, stride, frame, source) {
    const srcWords = new Uint32Array(source.buffer, source.byteOffset, source.length / 4);
    const dstWords = new Uint32Array(dest.buffer, dest.byteOffset, dest.length / 4);
    let s = 0;
    for (let y = 0; y < frame.height; y++) {
        let d = 4 * ((frame.y + y) * stride + frame.x);
        for (let x = 0; x < frame.width; x++, s += 4, d += 4) {
            const a = source[s + 3];
            if (a === 0) continue;
            if (a === 255 || dest[d + 3] === 0) { dstWords[d / 4] = srcWords[s / 4]; continue; }
            const srcWeight = a * 255;
            const dstWeight = (255 - a) * dest[d + 3];
            const total = srcWeight + dstWeight;
            for (let c = 0; c < 3; c++) dest[d + c] = Math.round((source[s + c] * srcWeight + dest[d + c] * dstWeight) / total);
            dest[d + 3] = Math.round(total / 255);
        }
    }
}

export function createBrowserImagePixels({ thumbnail, frameCost, maxBytes }) {
    let gl, texture, framebuffer, maxTextureSize;
    let fallback, disposed = false;

    function read(image, width, height, useCanvasColor = false) {
        if (disposed) throw Error('Image decoder has been disposed');
        if (image.naturalWidth !== width || image.naturalHeight !== height) throw Error('Decoded image dimensions disagree with its frame');
        if (!useCanvasColor) {
            if (gl === undefined) {
                gl = canvas(1, 1).getContext('webgl2', { antialias: false, depth: false, stencil: false });
                if (gl) {
                    texture = gl.createTexture();
                    framebuffer = gl.createFramebuffer();
                    maxTextureSize = gl.getParameter(gl.MAX_TEXTURE_SIZE);
                    gl.bindTexture(gl.TEXTURE_2D, texture);
                    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
                    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
                    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
                    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
                    gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, gl.BROWSER_DEFAULT_WEBGL);
                    gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
                    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
                }
            }
            if (gl && texture && framebuffer && !gl.isContextLost() && Math.max(width, height) <= maxTextureSize) {
                gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, image);
                if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE && gl.getError() === gl.NO_ERROR) {
                    const bytes = new Uint8Array(width * height * 4);
                    gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, bytes);
                    if (gl.getError() === gl.NO_ERROR) return bytes;
                }
            }
        }
        if (!fallback) fallback = context2D(canvas(width, height));
        const surface = fallback.canvas;
        if (surface.width !== width) surface.width = width;
        if (surface.height !== height) surface.height = height;
        fallback.globalCompositeOperation = 'copy';
        fallback.drawImage(image, 0, 0, width, height);
        return fallback.getImageData(0, 0, width, height).data;
    }

    async function compose(animation, limit, load, emit, signal, useCanvasColor = false) {
        const { width, height, frameCount } = animation;
        const [w, h] = thumbnail(width, height, limit);
        // Animation rectangles are encoded in source coordinates. Orient each completed
        // canvas after composition, preserving the native lossless RGBA bytes.
        const orientation = animation.orientation ?? 1;
        const outputWidth = orientation >= 5 ? h : w;
        const outputHeight = orientation >= 5 ? w : h;
        const transform = {
            2: [w - 1, -1, w], 3: [w * h - 1, -1, -w], 4: [(h - 1) * w, 1, -w],
            5: [0, h, 1], 6: [h - 1, h, -1], 7: [w * h - 1, -h, -1], 8: [(w - 1) * h, -h, 1]
        }[orientation];
        const upright = transform ? new Uint8Array(w * h * 4) : null;
        const count = frameCount > Math.floor(maxBytes / frameCost(w, h)) ? 1 : frameCount;
        let rgba, source2D, scaled2D, presented = 0;
        try {
            for (const frame of animation.frames()) {
                if (signal.aborted || disposed) return;
                const image = await load(frame.blob, signal);
                if (signal.aborted || disposed) return;
                const patch = read(image, frame.width, frame.height, useCanvasColor);
                const full = frame.x === 0 && frame.y === 0 && frame.width === width && frame.height === height;
                const more = ++presented < count;
                const restore = more && frame.dispose === 'previous';
                const offset = (frame.y * width + frame.x) * 4;
                // Taking ownership of full replacements avoids a second canvas-sized allocation.
                const replace = full && (frame.blend === 'source' || (!rgba && !animation.background?.[3]));
                const previousCanvas = restore && replace ? rgba : null;
                let previousPatch;
                if (replace) {
                    rgba = patch;
                } else {
                    if (!rgba) {
                        rgba = new Uint8Array(width * height * 4);
                        if (animation.background?.[3]) fillRect(rgba, width, 0, 0, width, height, animation.background);
                    }
                    if (restore) {
                        previousPatch = new Uint8Array(frame.width * frame.height * 4);
                        copyRows(rgba, width, offset, previousPatch, frame.width, 0, frame.width, frame.height);
                    }
                    if (frame.blend === 'source') copyRows(patch, frame.width, 0, rgba, width, offset, frame.width, frame.height);
                    else blendOver(rgba, width, frame, patch);
                }

                let output = rgba;
                if (w !== width || h !== height) {
                    source2D ??= context2D(canvas(width, height));
                    scaled2D ??= context2D(canvas(w, h));
                    source2D.putImageData(new ImageData(new Uint8ClampedArray(rgba.buffer, rgba.byteOffset, rgba.length), width, height), 0, 0);
                    scaled2D.globalCompositeOperation = 'copy';
                    scaled2D.imageSmoothingQuality = 'high';
                    scaled2D.drawImage(source2D.canvas, 0, 0, w, h);
                    output = scaled2D.getImageData(0, 0, w, h).data;
                }
                if (transform) {
                    const [origin, dx, dy] = transform;
                    const src = new Uint32Array(output.buffer, output.byteOffset, w * h);
                    const dest = new Uint32Array(upright.buffer);
                    let i = 0;
                    for (let y = 0; y < h; y++) {
                        let pos = origin + y * dy;
                        for (let x = 0; x < w; x++, pos += dx) dest[pos] = src[i++];
                    }
                    output = upright;
                }
                if (!emit(output, outputWidth, outputHeight, frame.duration)) return;
                if (!more) return count === 1 ? 1 : animation.plays;
                if (frame.dispose === 'background') fillRect(rgba, width, frame.x, frame.y, frame.width, frame.height, frame.background);
                else if (restore && replace) rgba = previousCanvas;
                else if (restore) copyRows(previousPatch, frame.width, 0, rgba, width, offset, frame.width, frame.height);
            }
            throw Error('Incomplete image animation');
        } catch (error) {
            if (!signal.aborted && !disposed) throw error;
        } finally {
            if (source2D) source2D.canvas.width = 1;
            if (scaled2D) scaled2D.canvas.width = 1;
        }
    }

    function dispose() {
        disposed = true;
        if (gl) {
            gl.deleteFramebuffer(framebuffer);
            gl.deleteTexture(texture);
            gl.getExtension('WEBGL_lose_context')?.loseContext();
            gl = null;
        }
        if (fallback) fallback.canvas.width = 1;
        fallback = null;
    }
    return { read, compose, dispose };
}
