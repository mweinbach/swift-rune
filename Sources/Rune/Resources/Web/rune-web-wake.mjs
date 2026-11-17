// Imports resolve their memory lazily; wrappers around an instance share the host of that memory.
const hosts = new WeakMap();

export function wakeRuneBrowser(memory, delay = 0) {
    hosts.get(memory)?.(delay);
}

// At rest the page owns neither a timer nor a requestAnimationFrame. A timer wakes the next
// display frame; continuous motion re-arms directly at the display's own refresh rate.
export function mountRuneFrameClock(memory, draw, nextDelay, clock) {
    let active = false, rendering = false;
    let frame = null, timer = null, due = Infinity;

    function clearTimer() {
        if (timer !== null) clearTimeout(timer);
        timer = null;
    }

    // An expired setTimeout followed by rAF can miss the desired vsync by a whole refresh.
    // Ask for display callbacks near the deadline and leave WASI asleep through early ones.
    const lead = 1000 / 60 + 1;
    function arm() {
        if (frame !== null) return;
        clearTimer();
        const remaining = due - clock();
        if (remaining <= lead) {
            frame = requestAnimationFrame(display);
        } else {
            timer = setTimeout(arm, Math.min(0x7fffffff, Math.ceil(remaining - lead)));
        }
    }

    function request(delay = 0) {
        if (!active || rendering || !Number.isFinite(delay)) return;
        const when = delay <= 0 ? -Infinity : clock() + delay * 1000;
        if (when >= due) return;
        due = when;
        arm();
    }

    function display() {
        frame = null;
        if (!active) return;
        if (clock() + 0.5 < due) { arm(); return; }
        due = Infinity;
        render();
    }

    function render() {
        rendering = true;
        try { draw(); } finally { rendering = false; }
        if (active) request(nextDelay());
    }

    function pause() {
        active = false;
        due = Infinity;
        if (frame !== null) cancelAnimationFrame(frame);
        frame = null;
        clearTimer();
    }

    hosts.set(memory, request);
    return {
        request, pause,
        start() { pause(); active = true; render(); },
        afterPresentation() { pause(); active = true; request(nextDelay()); },
        dispose() { pause(); if (hosts.get(memory) === request) hosts.delete(memory); }
    };
}
