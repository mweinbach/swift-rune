import { mountRuneFrameClock } from './rune-web-wake.mjs';
import { selectRuneCanvas } from './rune-web-page.mjs';
import { loadRuneShaders, RuneWebGL } from './rune-webgl.mjs';
import { runePageNow } from './rune-page-clock.mjs';
import { makeCPUFrameTransfer, mountCPUUnderlay } from './rune-web-cpu-start.mjs';
import { mountRuneSpelling } from './rune-web-spell.mjs';
import { mountRunePopup } from './rune-web-popup.mjs';
import { mountRuneCursor } from './rune-web-cursor.mjs';
import { mountRuneClipboard } from './rune-clipboard.mjs';
import { mountRuneAccessibility } from './rune-web-accessibility.mjs';
import { mountRuneTextFonts, runeTextFontsReady } from './rune-web-text.mjs';
import { createRuneImageDecoder } from './rune-web-images.mjs';
export { createRuneTextImports, instantiateRuneBrowser } from './rune-web-text.mjs';

// Mount alongside Rune's canvas. The page keeps its native text field for screen
// readers, IMEs and text editing, while Rune owns the model and draws its contents.
export function mountRuneFields(canvas, send, placeEditor) {
    const doc = canvas.ownerDocument;
    const plain = doc.createElement('textarea');
    plain.wrap = 'off';
    plain.setAttribute('aria-label', 'Text input');
    const password = doc.createElement('input');
    password.type = 'password';
    password.setAttribute('aria-label', 'Password input');
    password.autocomplete = 'off';
    password.spellcheck = false;

    const listeners = new AbortController();
    const options = { signal: listeners.signal };
    const active = () => doc.activeElement;
    let mirror = null;
    let composing = false;
    for (const field of [plain, password]) {
        const sentKeys = new Set();
        field.addEventListener('blur', () => sentKeys.clear(), options);
        field.addEventListener('keyup', event => {
            if (sentKeys.delete(event.code)) send({ ...keyEvent(event), kind: 'keyup', field: true });
        }, options);
        field.hidden = true;
        field.tabIndex = -1;
        field.style.cssText = 'position:fixed;left:0;top:0;width:1px;height:1px;padding:0;border:0;opacity:0;font-size:16px;pointer-events:none';
        doc.body.append(field);
        field.addEventListener('compositionstart', () => { composing = true; }, options);
        field.addEventListener('compositionend', () => {
            composing = false;
            acceptInput(field);
        }, options);
        field.addEventListener('input', event => {
            if (!composing && !event.isComposing) acceptInput(field);
        }, options);
        field.addEventListener('keydown', event => {
            if (composing || event.isComposing) return;
            if (placeEditor && event.key === 'Tab' && !event.ctrlKey && !event.metaKey && !event.altKey) return;
            // Navigation and undo operate on the full model, beyond the mirrored window.
            // Copy, cut and paste arrive as separate browser clipboard events.
            const chord = event.metaKey || event.ctrlKey;
            if (chord && ['c', 'v', 'x'].includes(event.key.toLowerCase())) return;
            const editing = ['Enter', 'Tab', 'Escape', 'PageUp', 'PageDown', 'Home', 'End',
                'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'];
            if (field === password) editing.push('Backspace', 'Delete');
            if (chord || editing.includes(event.key)) {
                sentKeys.add(event.code);
                if (send({ ...keyEvent(event), field: true })) event.preventDefault();
            }
        }, options);
    }

    function selection() {
        const backward = plain.selectionDirection === 'backward';
        return {
            anchor: backward ? plain.selectionEnd : plain.selectionStart,
            focus: backward ? plain.selectionStart : plain.selectionEnd
        };
    }

    function acceptInput(field) {
        if (!mirror || field !== active()) return;
        if (field === password) {
            const text = password.value;
            password.value = '';
            if (text && mirror.secure) send({ kind: 'insert', key: mirror.key, text });
        } else if (!mirror.secure && plain.value !== mirror.text) {
            send({ kind: 'edit', key: mirror.key, base: mirror.base, expected: mirror.text, text: plain.value, ...selection() });
        }
    }

    const selected = () => {
        if (composing || !mirror || mirror.secure || active() !== plain || plain.value !== mirror.text) return;
        const { anchor, focus } = selection();
        if (anchor !== mirror.anchor || focus !== mirror.focus) {
            send({ kind: 'selection', key: mirror.key, base: mirror.base, expected: mirror.text, anchor, focus });
        }
    };
    plain.addEventListener('select', selected, options);
    doc.addEventListener('selectionchange', selected, options);
    password.addEventListener('beforeinput', event => {
        if (!mirror?.secure || composing || !event.inputType.startsWith('delete')) return;
        const key = event.inputType.endsWith('Backward') ? 'Backspace' : 'Delete';
        if (send({ kind: 'key', key, code: key, field: true })) event.preventDefault();
    }, options);

    return {
        activeEditor() { return mirror ? (mirror.secure ? password : plain) : null; },
        clipboardTarget(target) {
            if (target !== active() || !mirror) return null;
            if (target === password && mirror.secure) return 'password';
            if (target !== plain || composing || mirror.secure) return null;
            selected();
            return 'plain';
        },
        sync(next, activate = false) {
            const ownedFocus = active() === plain || active() === password;
            if (composing && mirror && next?.key === mirror.key && next.secure === mirror.secure) return;
            composing = false;
            mirror = next;
            plain.hidden = !next || next.secure;
            password.hidden = !next?.secure;
            plain.setAttribute('aria-label', next && !next.secure && next.label || 'Text input');
            password.setAttribute('aria-label', next?.secure && next.label || 'Password input');
            password.value = '';
            const text = next && !next.secure ? next.text : '';
            if (plain.value !== text) plain.value = text;
            if (next && !next.secure) {
                const { anchor, focus } = selection();
                if (anchor !== next.anchor || focus !== next.focus) {
                    plain.setSelectionRange(Math.min(next.anchor, next.focus), Math.max(next.anchor, next.focus),
                        next.anchor > next.focus ? 'backward' : 'forward');
                }
            }
            const target = next ? (next.secure ? password : plain) : canvas;
            placeEditor?.(next ? target : null, next?.key);
            if ((ownedFocus || (next && activate)) && active() !== target) target.focus({ preventScroll: true });
        },
        dispose() {
            listeners.abort();
            mirror = null;
            plain.value = password.value = '';
            plain.remove();
            password.remove();
        }
    };
}

function keyEvent(event) {
    return { kind: 'key', code: event.code, key: event.key, repeated: event.repeat, shift: event.shiftKey,
        ctrl: event.ctrlKey, alt: event.altKey, cmd: event.metaKey };
}

// The caller initializes the WASI Preview 1 reactor once, e.g. with wasi.initialize(instance).
// Its Swift entry point creates the same WebAppHost as a standalone WASI command.
export function mountRuneBrowser(canvas, instance, { backend, shaderDirectory, resizeTo, drawEffect, drawGPUEffect } = {}) {
    const wasm = instance.exports;
    const images = wasm.rune_web_image_enable && createRuneImageDecoder(() => wasm);
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    // Older reactors only export CPU frames. Explicit selection remains available for headless comparisons.
    const implicitBackend = backend === undefined && Boolean(wasm.rune_web_scene);
    const automatic = implicitBackend && (!drawGPUEffect || Boolean(drawEffect));
    const preferredGPU = drawGPUEffect || (!drawEffect && navigator.gpu) ? 'webgpu' : 'webgl2';
    backend ??= wasm.rune_web_scene ? preferredGPU : 'cpu';
    if (drawGPUEffect && !drawEffect && backend === 'webgl2') throw Error('A WebGPU effect requires WebGPU');
    if (drawEffect && !drawGPUEffect && backend === 'webgpu') throw Error('Provide drawGPUEffect for WebGPU effects');
    if (!['webgpu', 'webgl2', 'cpu'].includes(backend)) throw new Error('Unknown Rune browser backend: ' + backend);
    if (backend !== 'cpu' && !wasm.rune_web_scene) throw new Error('The reactor does not export rune_web_scene');
    let layout, config;
    try {
        wasm.rune_web_enable();
        if (backend !== 'cpu') {
            wasm.rune_web_enable_atlas_patches?.();
            wasm.rune_web_enable_image_pages?.();
            wasm.rune_web_enable_glyph_pages?.();
        }
        if (backend !== 'cpu') wasm.rune_web_enable_cycle_patches?.();
        wasm.rune_web_image_enable?.();
        if (wasm.__main_void() !== 0) throw new Error('Rune application failed to start');
        wasm.rune_web_enable_accessibility_patches?.();
        const count = wasm.rune_web_config?.();
        config = count ? JSON.parse(decoder.decode(new Uint8Array(wasm.memory.buffer, wasm.rune_web_buffer(0), count))) : {};
        layout = selectRuneCanvas(canvas, config);
        canvas = layout.canvas;
    } catch (error) {
        wasm.rune_web_dispose?.();
        throw error;
    }
    const page = layout.page;
    if (!page && (layout.full || config.canvasId || config.fitContentHeight) && resizeTo === undefined) resizeTo = canvas;
    let cpu = backend === 'cpu' ? canvas.getContext('2d') : null;
    if (backend === 'cpu' && !cpu) {
        layout.dispose();
        wasm.rune_web_dispose?.();
        throw new Error('Rune needs a 2D canvas context for CPU rendering');
    }
    const surfaceTiming = wasm.rune_web_surface_submission && wasm.rune_web_surface_complete ? {
        submitted: () => wasm.rune_web_surface_submission(),
        completed: (id, success) => wasm.rune_web_surface_complete(id, Number(success))
    } : null;
    let gpu, sources, observer, restoreNaturalSize, restoredBeforeFirstDraw;
    const autoSize = !page && backend !== 'cpu' && resizeTo === undefined && CSS.supports('contain-intrinsic-size', '1px');
    let underlay, transferCPU, cpuFirst = false;
    let lost = false;
    let force = true;
    let scale = 1;
    let lastSize, lastInsets;
    const accessibility = wasm.rune_web_accessibility ? mountRuneAccessibility(canvas, send, Boolean(page)) : null;
    const cursor = wasm.rune_web_cursor && mountRuneCursor(canvas);
    const fields = mountRuneFields(canvas, send, accessibility?.attachEditor);
    const listeners = new AbortController();
    const options = { signal: listeners.signal };
    const popup = wasm.rune_web_popup && mountRunePopup(canvas, send, fields, listeners.signal);
    const clipboard = wasm.rune_web_clipboard && mountRuneClipboard(canvas, fields, send, () => {
        const size = wasm.rune_web_clipboard();
        if (!size) return null;
        const bytes = new Uint8Array(wasm.memory.buffer, wasm.rune_web_buffer(0), size);
        return JSON.parse(decoder.decode(bytes));
    }, listeners.signal);
    const initialTab = canvas.getAttribute('tabindex');
    if (initialTab === null) canvas.tabIndex = accessibility ? -1 : 0;
    const started = runePageNow();
    const now = () => (runePageNow() - started) / 1000;
    const frames = mountRuneFrameClock(wasm.memory, tick,
        () => wasm.rune_web_next_wake?.(now()) ?? 0, runePageNow);
    let presented = false;
    const fonts = wasm.rune_web_fonts_changed && mountRuneTextFonts(wasm.memory, canvas.ownerDocument, () => {
        wasm.rune_web_fonts_changed();
        force = true;
        frames.request();
    });
    const stopSpelling = wasm.rune_web_spelling_changed && mountRuneSpelling(wasm.memory, canvas.ownerDocument, () => {
        wasm.rune_web_spelling_changed();
        frames.request();
    });
    let idleRequest = null;

    function cancelIdleText() {
        if (idleRequest === null) return;
        if (window.requestIdleCallback) window.cancelIdleCallback(idleRequest);
        else window.clearTimeout(idleRequest);
        idleRequest = null;
    }

    function scheduleIdleText() {
        if (!presented || idleRequest !== null || !wasm.rune_web_idle_text?.(0)) return;
        function prepare() {
            idleRequest = null;
            if (disposed || lost) return;
            if (navigator.scheduling?.isInputPending?.({ includeContinuous: true })) {
                scheduleIdleText();
                return;
            }
            if (wasm.rune_web_idle_text(1)) scheduleIdleText();
        }
        // Browsers without requestIdleCallback yield to the event loop after the frame.
        idleRequest = window.requestIdleCallback ? window.requestIdleCallback(prepare) : window.setTimeout(prepare, 0);
    }

    function readField() {
        const size = wasm.rune_web_field();
        if (!size) return;
        const pointer = wasm.rune_web_buffer(0);
        const { field, activate } = JSON.parse(decoder.decode(new Uint8Array(wasm.memory.buffer, pointer, size)));
        fields.sync(field ?? null, activate);
    }

    function popupJSON(read) {
        const size = read?.();
        if (!size) return null;
        return JSON.parse(decoder.decode(new Uint8Array(wasm.memory.buffer, wasm.rune_web_buffer(0), size)));
    }
    function syncPopup() {
        if (!popup) return;
        const packet = popupJSON(wasm.rune_web_popup);
        if (!packet) return;
        const box = canvas.getBoundingClientRect();
        const sx = canvas.width ? box.width * scale / canvas.width : 1;
        const sy = canvas.height ? box.height * scale / canvas.height : 1;
        popup.show(packet, {x: box.left + packet.x * sx, y: box.top + packet.y * sy, width: packet.minWidth * sx});
    }

    function send(event) {
        const message = encoder.encode(JSON.stringify(event));
        const pointer = wasm.rune_web_buffer(message.length);
        new Uint8Array(wasm.memory.buffer, pointer, message.length).set(message);
        const handled = wasm.rune_web_event(message.length, now()) !== 0;
        if (handled || (event.kind !== 'pageScroll' && event.kind !== 'pageScrollX' && event.kind !== 'wheel')) frames.request();
        readField();
        clipboard?.drain();
        syncPopup();
        return handled;
    }

    let measuredLimit;
    function updateSize(measure = true) {
        if (!page && !resizeTo) return;
        const dpr = Math.max(0.5, window.devicePixelRatio || 1);
        const limit = gpu?.maxSize ?? 8192;
        // ResizeObserver, display scale and visual viewport changes invalidate the measurement.
        // A scene repaint by itself must not force layout of the accessibility mirror.
        if (measure === false && lastSize && scale === dpr && measuredLimit === limit) return;
        measuredLimit = limit;
        let size;
        if (page) size = page.measure(limit);
        else {
            const rect = resizeTo.getBoundingClientRect();
            const height = layout.hasRequestedHeight && resizeTo !== canvas ? canvas.getBoundingClientRect().height : rect.height;
            size = [rect.width, height, dpr];
        }
        const insets = layout.viewport?.insets;
        if (size[0] <= 0 || size[1] <= 0 || (insets === lastInsets && size.every((n, i) => lastSize?.[i] === n))) return;
        lastSize = size;
        lastInsets = insets;
        scale = dpr;
        return send({ kind: 'resize', x: size[0], y: size[1], dy:size[3], scale, insets });
    }

    function useAppSize(width, height) {
        // A canvas normally derives its intrinsic CSS size from its backing pixels. Preserve its
        // logical size across DPR changes while letting authored CSS and flex/grid control layout.
        const naturalWidth = canvas.hasAttribute('width') ? canvas.width : width;
        const naturalHeight = canvas.hasAttribute('height') ? canvas.height : height;
        const previous = [canvas.style.contain, canvas.style.containIntrinsicSize];
        const contain = getComputedStyle(canvas).contain;
        if (contain === 'content') canvas.style.contain = 'size layout paint style';
        else if (contain !== 'strict' && !contain.split(' ').includes('size')) {
            const rest = contain.split(' ').filter(v => v !== 'none' && v !== 'inline-size');
            canvas.style.contain = ['size', ...rest].join(' ');
        }
        canvas.style.containIntrinsicSize = naturalWidth + 'px ' + naturalHeight + 'px';
        const applied = [canvas.style.contain, canvas.style.containIntrinsicSize];
        restoreNaturalSize = () => {
            if (canvas.style.contain === applied[0]) canvas.style.contain = previous[0];
            if (canvas.style.containIntrinsicSize === applied[1]) canvas.style.containIntrinsicSize = previous[1];
        };
        resizeTo = canvas;
        observer = new ResizeObserver(updateSize);
        observer.observe(canvas);
    }

    let accessibilityIdle = null, accessibilityTimer = null;
    function cancelAccessibilityWork() {
        if (accessibilityIdle !== null) cancelIdleCallback(accessibilityIdle);
        if (accessibilityTimer !== null) clearTimeout(accessibilityTimer);
        accessibilityIdle = accessibilityTimer = null;
    }
    function syncAccessibility(due = false) {
        const size = due ? wasm.rune_web_flush_accessibility() : wasm.rune_web_accessibility?.();
        if (size === -2) {
            // During the idle handoff the canvas still accepts the app's first Tab or key.
            if (initialTab === null && canvas.tabIndex < 0) canvas.tabIndex = 0;
            if (accessibilityIdle !== null || accessibilityTimer !== null) return;
            if (globalThis.requestIdleCallback) {
                accessibilityIdle = requestIdleCallback(() => {
                    accessibilityIdle = null;
                    syncAccessibility(true);
                }, { timeout: 100 });
            } else {
                accessibilityTimer = setTimeout(() => { accessibilityTimer = null; syncAccessibility(true); }, 0);
            }
        } else if (size === -1) {
            if (accessibilityTimer !== null) clearTimeout(accessibilityTimer);
            accessibilityTimer = setTimeout(() => { accessibilityTimer = null; syncAccessibility(true); }, 160);
        } else if (size > 0) {
            cancelAccessibilityWork();
            const bytes = new Uint8Array(wasm.memory.buffer, wasm.rune_web_buffer(0), size);
            accessibility.sync(JSON.parse(decoder.decode(bytes)));
            if (initialTab === null && canvas.tabIndex !== -1) canvas.tabIndex = -1;
        }
    }

    function syncWindowTitle() {
        if ((!layout.full && !page) || !wasm.rune_web_window_title) return;
        const size = wasm.rune_web_window_title();
        if (size >= 0) {
            layout.setTitle(decoder.decode(new Uint8Array(wasm.memory.buffer, wasm.rune_web_buffer(0), size)));
        }
    }

    let firstFit = !page && config.fitContentHeight && wasm.rune_web_window_height;
    function applyWindowHeight() {
        if (!wasm.rune_web_window_height || !layout.setHeight(wasm.rune_web_window_height())) return;
        if (!resizeTo) {
            resizeTo = canvas;
            observer = new ResizeObserver(updateSize);
            observer.observe(canvas);
        }
        updateSize();
    }

    function drawFrame() {
        updateSize(false);
        if (firstFit) {
            firstFit = false;
            applyWindowHeight();
        }
        const full = force;
        // The explicit CPU backend also supports reference-only surfaces for capture tools.
        const length = gpu ? wasm.rune_web_scene(now(), full ? 1 : 0) :
            transferCPU ? wasm.rune_web_cpu_frame(now(), full ? 1 : 0) : wasm.rune_web_frame(now());
        force = false;
        if (length < 0) {
            let reason = 'Rune could not render the browser frame';
            if (length < -1) {
                const pointer = wasm.rune_web_buffer(0);
                reason += ': ' + decoder.decode(new Uint8Array(wasm.memory.buffer, pointer, -length - 1));
            }
            throw new Error(reason);
        }
        let sized = false;
        if (length > 0) {
            let painted = true;
            const pointer = wasm.rune_web_buffer(0);
            const memory = wasm.memory.buffer;
            if (gpu) {
                if (autoSize && !restoreNaturalSize && length >= 56) {
                    const dimensions = new Uint32Array(memory, pointer, 3);
                    useAppSize(dimensions[1], dimensions[2]);
                    sized = true;
                }
                // A custom Swift compositor may request multiple ordered UI passes. A suppressed
                // UI produces a clear-only packet which still has to reach the drawing buffer.
                const passes = Math.max(1, wasm.rune_web_ui_passes?.() ?? 1);
                for (let pass = 0; pass < passes; ++pass) gpu.draw(memory, pointer, length, pass);
                gpu.frameRenderer.submitSurfaceTiming?.();
                if (wasm.rune_web_cached_layers) {
                    const entries = gpu.frameRenderer.takeCachedLayers?.(full);
                    if (entries) {
                        const address = wasm.rune_web_buffer(entries.byteLength);
                        new Uint32Array(wasm.memory.buffer, address, entries.length).set(entries);
                        wasm.rune_web_cached_layers(entries.length / 4);
                    }
                }
            } else {
                const dimensions = new DataView(memory, pointer, 8);
                const width = dimensions.getUint32(0, true);
                const height = dimensions.getUint32(4, true);
                if (underlay && autoSize && !restoreNaturalSize) { useAppSize(width, height); sized = true; }
                if (canvas.width !== width) canvas.width = width;
                if (canvas.height !== height) canvas.height = height;
                if (underlay) {
                    if (!transferCPU) {
                        if (cpu.canvas.width !== width) cpu.canvas.width = width;
                        if (cpu.canvas.height !== height) cpu.canvas.height = height;
                    }
                    underlay.place();
                }
                if (transferCPU) {
                    painted = transferCPU(cpu, pointer, length);
                } else {
                    const pixels = new Uint8ClampedArray(memory, pointer + 8, length - 8);
                    cpu.putImageData(new ImageData(pixels, width, height), 0, 0);
                }
            }
            if (page && wasm.rune_web_page?.() === 12) {
                const [height, top, focused] = new Float32Array(wasm.memory.buffer, wasm.rune_web_buffer(0), 3);
                page.sync(height, top, focused);
            }
            syncAccessibility();
            const cursorSize = wasm.rune_web_cursor?.();
            if (cursorSize) {
                const bytes = new Uint8Array(wasm.memory.buffer, wasm.rune_web_buffer(0), cursorSize);
                cursor.update(JSON.parse(decoder.decode(bytes)));
            }
            if (!presented && painted) {
                presented = true;
                fonts?.presented();
                canvas.dispatchEvent(new CustomEvent('runepresent', {bubbles:true}));
                page?.presented();
            }
        }
        syncWindowTitle();
        applyWindowHeight();
        accessibility?.place();
        readField();
        clipboard?.drain();
        syncPopup();
        // Building the view and running Swift tasks can submit decodes. Start them in this turn
        // once the frame and other readers have finished with the shared WASI buffer.
        if (images) {
            let size;
            while ((size = wasm.rune_web_image_next()) > 0) {
                const address = wasm.rune_web_buffer(0);
                const [id, limit, kind] = new Uint32Array(wasm.memory.buffer, address, 3);
                images.start(id, address + 12, size - 12, limit, kind);
            }
        }
        // Resizing writes an event into the shared reactor buffer. Read the first packet before
        // requesting its device-resolution replacement.
        if (sized && updateSize()) {
            force = true;
            drawFrame();
        }
    }

    function tick() {
        if (disposed || lost) return;
        try {
            drawFrame();
            scheduleIdleText();
        } catch (error) {
            dispose();
            throw error;
        }
    }

    let disposed = false;
    function dispose() {
        if (disposed) return;
        disposed = true;
        restoredBeforeFirstDraw?.resolve();
        images?.dispose();
        fonts?.dispose();
        stopSpelling?.();
        frames.dispose();
        cancelIdleText();
        listeners.abort();
        observer?.disconnect();
        restoreNaturalSize?.();
        gpu?.dispose();
        underlay?.remove();
        underlay = null;
        transferCPU = null;
        cpu = null;
        cursor?.dispose();
        popup?.dispose();
        fields.dispose();
        cancelAccessibilityWork();
        accessibility?.dispose();
        if (initialTab === null) canvas.removeAttribute('tabindex');
        layout.dispose();
        wasm.rune_web_dispose?.();
    }

    try {
        const fontsReady = runeTextFontsReady(wasm.memory);
        function watchDisplayScale() {
            const query = matchMedia('(resolution: ' + (window.devicePixelRatio || 1) + 'dppx)');
            query.addEventListener('change', () => { updateSize(); watchDisplayScale(); },
                { ...options, once: true });
        }
        watchDisplayScale();
        syncWindowTitle();
        layout.viewport?.watch(updateSize, options);
        if (wasm.rune_web_scene) {
            const media = {
                dark: matchMedia('(prefers-color-scheme: dark)'),
                reducedMotion: matchMedia('(prefers-reduced-motion: reduce)'),
                contrast: matchMedia('(prefers-contrast: more)'),
                hover: matchMedia('(hover: hover)'),
                coarse: matchMedia('(pointer: coarse)')
            };
            const update = () => send({ kind: 'preferences',
                ...Object.fromEntries(Object.entries(media).map(([key, query]) => [key, query.matches])) });
            for (const query of Object.values(media)) query.addEventListener('change', update, options);
            update();
        }
        if (page) {
            const scroll = () => send({kind:'pageScroll', y:page.scrollY()});
            window.addEventListener('scroll', scroll, {...options, passive:true});
            window.addEventListener('resize', updateSize, options);
            updateSize();
            scroll();
        }
        canvas.addEventListener('keydown', event => {
            if (page && !page.focused && ['ArrowUp','ArrowDown','PageUp','PageDown','Home','End',' '].includes(event.key)) return;
            if (clipboard && (event.ctrlKey || event.metaKey) && !event.altKey &&
                ['c', 'x', 'v'].includes(event.key.toLowerCase())) return;
            if (!event.isComposing && send(keyEvent(event))) event.preventDefault();
        }, options);
        canvas.addEventListener('keyup', event => {
            if (!event.isComposing && send({ ...keyEvent(event), kind: 'keyup' })) event.preventDefault();
        }, options);
        window.addEventListener('blur', () => send({ kind: 'focuslost' }), options);
        if (!popup) canvas.addEventListener('contextmenu', event => event.preventDefault(), options);
        function localPoint(event) {
            const rect = canvas.getBoundingClientRect();
            if (!rect.width || !rect.height) return null;
            return { x: (event.clientX - rect.left) * canvas.width / (rect.width * scale),
                     y: (event.clientY - rect.top) * canvas.height / (rect.height * scale) };
        }
        canvas.addEventListener('wheel', event => {
            const point = localPoint(event);
            if (point && send({ kind: 'wheel', ...point, dx: event.deltaX, dy: event.deltaY,
                deltaMode: event.deltaMode, shift: event.shiftKey, ctrl: event.ctrlKey,
                alt: event.altKey, cmd: event.metaKey })) event.preventDefault();
        }, { ...options, passive: false });
        const buttons = ['primary', 'middle', 'secondary', 'back', 'forward'];
        for (const kind of ['pointerdown', 'pointermove', 'pointerup', 'pointercancel']) {
            canvas.addEventListener(kind, event => {
                const point = localPoint(event);
                if (!point) return;
                const secondary = event.button === 2 && popup && event.pointerType === 'mouse';
                if (kind === 'pointerdown' && !secondary) {
                    canvas.focus({ preventScroll: true });
                    canvas.setPointerCapture(event.pointerId);
                }
                send({ kind, ...point, button: buttons[event.button], pointerType: event.pointerType, pointerId: event.pointerId,
                    shift: event.shiftKey, ctrl: event.ctrlKey, alt: event.altKey, cmd: event.metaKey });
                if (kind === 'pointerdown' && secondary) {
                    const claim = popupJSON(wasm.rune_web_secondary_claim) ?? {kind:''};
                    if (popup.arm(event, claim)) {
                        canvas.setPointerCapture(event.pointerId);
                        event.preventDefault();
                    }
                } else if (kind === 'pointerdown' && (!page || event.pointerType !== 'touch')) event.preventDefault();
            }, options);
        }
        if (page || resizeTo) {
            observer = new ResizeObserver(updateSize);
            observer.observe(page?.container ?? resizeTo);
        }
        function startCPU() {
            if (!underlay) underlay = mountCPUUnderlay(canvas);
            if (!underlay) return false;
            cpu = underlay.context;
            transferCPU = wasm.rune_web_cpu_frame && wasm.rune_web_cpu_rect ? makeCPUFrameTransfer(wasm) : null;
            wasm.rune_web_reset_renderer?.();
            force = true;
            frames.pause();
            lost = false;
            try {
                drawFrame();
                scheduleIdleText();
                frames.afterPresentation();
                return true;
            } catch (error) {
                underlay.remove();
                underlay = null;
                transferCPU = null;
                cpu = null;
                if (globalThis.RUNE_CPU_FIRST === 'only') throw error;
                console.warn('Rune could not present its CPU frame:', error);
                return false;
            }
        }
        async function presentGPU(renderer) {
            if (disposed) { renderer.dispose(); return; }
            frames.pause();
            gpu = renderer;
            force = true;
            if (underlay) {
                // Keep the last CPU image visible until the new device finished its first submission.
                try {
                    drawFrame();
                    if (renderer.device) await renderer.device.queue.onSubmittedWorkDone();
                    else await finishWebGLFrame(renderer.gl);
                } catch (error) {
                    if (disposed || gpu !== renderer) return;
                    gpu = null;
                    renderer.dispose();
                    // Keep the interactive CPU surface when a device fails its first real frame.
                    wasm.rune_web_reset_renderer?.();
                    force = true;
                    frames.start();
                    throw error;
                }
                if (disposed || gpu !== renderer) return;
                underlay.remove();
                underlay = null;
                transferCPU = null;
                cpu = null;
            }
            frames.start();
        }
        function finishWebGLFrame(gl) {
            const fence = gl.fenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0);
            if (!fence) throw Error('Rune could not fence its first WebGL frame');
            gl.flush();
            return new Promise((resolve, reject) => {
                function check() {
                    if (disposed || gl.isContextLost()) { resolve(); return; }
                    const state = gl.clientWaitSync(fence, 0, 0);
                    if (state === gl.TIMEOUT_EXPIRED) { requestAnimationFrame(check); return; }
                    gl.deleteSync(fence);
                    if (state === gl.WAIT_FAILED) reject(Error('Rune WebGL frame fence failed'));
                    else resolve();
                }
                check();
            });
        }
        function activateWebGL() {
            let glLost = false;
            canvas.addEventListener('webglcontextlost', event => {
                event.preventDefault();
                glLost = lost = true;
                gpu?.frameRenderer.cancelTimings?.();
                gpu = null; // The browser discards every object associated with the lost context.
                frames.pause();
                cancelIdleText();
                if (cpuFirst) startCPU();
            }, options);
            canvas.addEventListener('webglcontextrestored', () => {
                if (disposed) return;
                glLost = lost = false;
                force = true;
                if (!sources) return;
                const pending = restoredBeforeFirstDraw;
                restoredBeforeFirstDraw = null;
                try {
                    presentGPU(new RuneWebGL(canvas, sources, { drawEffect, surfaceTiming })).then(pending?.resolve,
                        error => { dispose(); if (pending) pending.reject(error); else console.error(error); });
                } catch (error) {
                    pending?.reject(error);
                    dispose();
                    if (!pending) throw error;
                }
            }, options);
            return Promise.all([loadRuneShaders(shaderDirectory), fontsReady]).then(([loaded]) => {
                if (disposed) return;
                sources = loaded;
                if (glLost) return new Promise((resolve, reject) => { restoredBeforeFirstDraw = { resolve, reject }; });
                return presentGPU(new RuneWebGL(canvas, sources, { drawEffect, surfaceTiming }));
            });
        }
        async function activateWebGPU() {
            const { RuneWebGPU } = await import('./rune-webgpu.mjs');
            if (disposed) return;
            const create = () => RuneWebGPU.create(canvas, {drawGPUEffect, surfaceTiming, onLost});
            let renderer = await create();
            try {
                await fontsReady;
                if (!disposed && renderer.lostReason) {
                    // A device may disappear while a first-paint font is loading.
                    renderer.dispose();
                    renderer = await create();
                }
                if (renderer.lostReason) throw Error('Rune GPU device lost: ' + renderer.lostReason);
                return await presentGPU(renderer);
            } catch (error) {
                if (gpu !== renderer) renderer.dispose();
                throw error;
            }
        }
        function onLost(renderer, reason) {
            if (disposed || renderer !== gpu) return;
            frames.pause();
            cancelIdleText();
            renderer.dispose();
            gpu = null;
            lost = false;
            force = true;
            console.warn('Rune GPU device lost: ' + reason + '. Requesting a replacement.');
            if (cpuFirst) startCPU();
            activateWebGPU().catch(error => {
                if (disposed) return;
                if (!underlay) dispose();
                console.error('Rune could not restore the WebGPU renderer:', error);
                canvas.dispatchEvent(new CustomEvent('runerenderererror', {detail: error}));
            });
        }
        function startGPU() {
            if (backend === 'webgl2') return activateWebGL();
            return activateWebGPU().catch(error => {
                if (disposed || !automatic || gpu) throw error;
                return activateWebGL();
            });
        }
        let ready;
        // Explicit backend selection is deterministic. Older reactors and inline/document apps
        // keep their GPU-first presentation; full-window apps can keep painting through startup.
        cpuFirst = Boolean(implicitBackend && wasm.rune_web_frame && wasm.rune_web_full_window?.() &&
            globalThis.RUNE_CPU_FIRST !== 'off');
        if (cpuFirst) {
            ready = Promise.resolve(fontsReady).then(() => {
                if (disposed) return;
                if (!startCPU()) return startGPU();
                if (globalThis.RUNE_CPU_FIRST !== 'only') return startGPU().catch(error => {
                    if (disposed || gpu) throw error;
                    console.warn('Rune continues drawing on the CPU:', error);
                });
            });
        } else if (backend !== 'cpu') {
            ready = startGPU();
        } else if (fontsReady) {
            ready = fontsReady.then(() => frames.start());
        } else {
            frames.start();
            ready = Promise.resolve();
        }
        ready = ready.catch(error => { dispose(); throw error; });
        return { dispose, ready, get renderer() { return gpu?.info ?? (cpu ? { api: 'Canvas 2D' } : null); } };
    } catch (error) {
        dispose();
        throw error;
    }
}
