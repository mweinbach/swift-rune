// Mount alongside Rune's canvas. The page keeps its native text field for screen
// readers, IMEs and text editing, while Rune owns the model and draws its contents.
export function mountRuneFields(canvas, send) {
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
            // Navigation and undo operate on the full model, beyond the mirrored window.
            // A native clipboard operation uses the textarea's real selection and input event.
            const chord = event.metaKey || event.ctrlKey;
            if (chord && ['c', 'v', 'x'].includes(event.key.toLowerCase())) return;
            const editing = ['Enter', 'Tab', 'Escape', 'PageUp', 'PageDown', 'Home', 'End',
                'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'];
            if (field === password) editing.push('Backspace', 'Delete');
            if ((chord || editing.includes(event.key)) && send({ ...keyEvent(event), field: true })) event.preventDefault();
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
    return { kind: 'key', code: event.code, key: event.key, shift: event.shiftKey,
        ctrl: event.ctrlKey, alt: event.altKey, cmd: event.metaKey };
}

// The caller initializes the WASI Preview 1 reactor once, e.g. with wasi.initialize(instance).
// Its Swift entry point creates the same WebAppHost as a standalone WASI command.
export function mountRuneBrowser(canvas, instance) {
    const wasm = instance.exports;
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    const context = canvas.getContext('2d');
    if (!context) throw new Error('Rune needs a 2D canvas context');
    const fields = mountRuneFields(canvas, send);
    const listeners = new AbortController();
    const options = { signal: listeners.signal };
    const initialTab = canvas.getAttribute('tabindex');
    if (initialTab === null) canvas.tabIndex = 0;
    const started = performance.now();
    const now = () => (performance.now() - started) / 1000;
    let request = 0;

    function readField() {
        const size = wasm.rune_web_field();
        if (!size) return;
        const pointer = wasm.rune_web_buffer(0);
        const { field, activate } = JSON.parse(decoder.decode(new Uint8Array(wasm.memory.buffer, pointer, size)));
        fields.sync(field ?? null, activate);
    }

    function send(event) {
        const message = encoder.encode(JSON.stringify(event));
        const pointer = wasm.rune_web_buffer(message.length);
        new Uint8Array(wasm.memory.buffer, pointer, message.length).set(message);
        const handled = wasm.rune_web_event(message.length, now()) !== 0;
        readField();
        return handled;
    }

    function tick() {
        const length = wasm.rune_web_frame(now());
        if (length < 0) {
            dispose();
            throw new Error('Rune could not render the browser frame');
        }
        if (length > 0) {
            const pointer = wasm.rune_web_buffer(0);
            const memory = wasm.memory.buffer;
            const dimensions = new DataView(memory, pointer, 8);
            const width = dimensions.getUint32(0, true);
            const height = dimensions.getUint32(4, true);
            if (canvas.width !== width) canvas.width = width;
            if (canvas.height !== height) canvas.height = height;
            const pixels = new Uint8ClampedArray(memory, pointer + 8, length - 8);
            context.putImageData(new ImageData(pixels, width, height), 0, 0);
        }
        readField();
        request = requestAnimationFrame(tick);
    }

    let disposed = false;
    function dispose() {
        if (disposed) return;
        disposed = true;
        cancelAnimationFrame(request);
        listeners.abort();
        fields.dispose();
        if (initialTab === null) canvas.removeAttribute('tabindex');
        wasm.rune_web_dispose?.();
    }

    try {
        wasm.rune_web_enable();
        if (wasm.__main_void() !== 0) throw new Error('Rune application failed to start');
        canvas.addEventListener('keydown', event => {
            if (!event.isComposing && send(keyEvent(event))) event.preventDefault();
        }, options);
        const buttons = ['primary', 'middle', 'secondary', 'back', 'forward'];
        for (const kind of ['pointerdown', 'pointermove', 'pointerup', 'pointercancel']) {
            canvas.addEventListener(kind, event => {
                if (!event.isPrimary) return;
                const rect = canvas.getBoundingClientRect();
                if (!rect.width || !rect.height) return;
                if (kind === 'pointerdown') {
                    canvas.focus({ preventScroll: true });
                    canvas.setPointerCapture(event.pointerId);
                }
                send({ kind, button: buttons[event.button], pointerType: event.pointerType,
                    x: (event.clientX - rect.left) * canvas.width / rect.width,
                    y: (event.clientY - rect.top) * canvas.height / rect.height });
                if (kind === 'pointerdown') event.preventDefault();
            }, options);
        }
        tick();
        return { dispose };
    } catch (error) {
        dispose();
        throw error;
    }
}
