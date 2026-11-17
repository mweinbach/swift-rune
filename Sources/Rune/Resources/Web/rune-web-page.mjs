// Mount the surface into the article or full-window canvas requested by Swift.
export function selectRuneCanvas(provided, config) {
    let canvas = provided, owned = false;
    const id = typeof canvas === 'string' ? canvas : !canvas && config.canvasId;
    if (id) {
        canvas = document.getElementById(id);
        if (!(canvas instanceof HTMLCanvasElement)) throw Error('Missing Rune canvas #' + id);
    } else if (!canvas) {
        canvas = document.createElement('canvas');
        document.body.append(canvas);
        owned = true;
    }
    const doc = canvas.ownerDocument, win = doc.defaultView;
    let wrapper, probe, staticHandoff;
    const changes = [];
    function style(node, values) {
        for (const [name, value] of Object.entries(values)) {
            const previous = node.style.getPropertyValue(name), priority = node.style.getPropertyPriority(name);
            node.style.setProperty(name, value);
            changes.push(() => {
                if (node.style.getPropertyValue(name) === value) node.style.setProperty(name, previous, priority);
            });
        }
    }
    let page, viewport;
    let savedTitle;
    let requestedHeight;
    const originalHeight = [canvas.style.height, canvas.style.getPropertyPriority('height')];
    const full = !config.webDocument && (owned || (config.fullViewport && !config.fitContentHeight));
    if (config.webDocument) {
        style(doc.body, {margin:'0px'});
        wrapper = doc.createElement('div');
        wrapper.dataset.runeBand = '';
        const staticPage = doc.querySelector('[data-rune-static]:not(style)');
        wrapper.style.cssText = (staticPage ? 'position:absolute;inset:0 0 auto;' : 'position:relative;') +
            'width:100%;height:0;overflow:clip;overflow-anchor:none;';
        canvas.replaceWith(wrapper);
        wrapper.append(canvas);
        style(canvas, {position:'absolute', left:'0px', top:'0px', width:'100%', display:'block',
            'touch-action':'pan-x pan-y pinch-zoom', 'transform-origin':'top left'});
        const oldHeight = canvas.style.height, oldTransform = canvas.style.transform;
        changes.push(() => { canvas.style.height = oldHeight; canvas.style.transform = oldTransform; });
        probe = doc.createElement('div');
        probe.style.cssText = 'position:fixed;visibility:hidden;pointer-events:none;height:100lvh;width:0;';
        wrapper.append(probe);
        if (staticPage) staticHandoff = handOffStatic(doc, win, wrapper, staticPage);
        let offset = 0, height = 0;
        page = {
            container: wrapper,
            focused: false,
            presented() {
                staticHandoff?.presented();
            },
            measure(limit) {
                const dpr = Math.max(0.5, win.devicePixelRatio || 1);
                const view = probe.offsetHeight || win.innerHeight;
                const band = Math.min(view + 512, limit / dpr);
                const width = Math.min(wrapper.clientWidth || doc.documentElement.clientWidth, limit / dpr);
                if (canvas.style.height !== band + 'px') canvas.style.height = band + 'px';
                return [width, band, dpr, Math.min(view, band)];
            },
            scrollY() {
                // An embedded article can have content before it in the native document.
                const docTop = wrapper.getBoundingClientRect().top + win.scrollY;
                return win.scrollY - docTop;
            },
            sync(natural, top, focus) {
                this.focused = Boolean(focus);
                if (natural !== height) { height = natural; wrapper.style.height = Math.ceil(height) + 'px'; }
                if (offset !== top) { offset = top; canvas.style.transform = 'translate3d(0,' + top + 'px,0)'; }
            }
        };
    } else if (full) {
        style(canvas, {position:'fixed', display:'block', 'touch-action':'none'});
        style(doc.body, {margin:'0px', overflow:'hidden', 'overscroll-behavior':'none'});
        viewport = fullWindowViewport(canvas, doc, win);
    } else if (config.canvasId) {
        style(canvas, {width:'100%', display:'block', 'touch-action':config.fitContentHeight ? 'pan-y' : 'none'});
    }
    if (page || full) savedTitle = doc.title;
    return {canvas, page, full, viewport, get hasRequestedHeight() { return requestedHeight !== undefined; },
    setHeight(height) {
        if (page || !Number.isFinite(height) || height <= 0) return false;
        const value = height + 'px';
        if (canvas.style.height === value) return false;
        canvas.style.height = value;
        requestedHeight = canvas.style.height;
        return true;
    }, setTitle(title) {
        if (savedTitle !== undefined) doc.title = title;
    }, dispose() {
        viewport?.dispose();
        if (requestedHeight !== undefined && canvas.style.height === requestedHeight) {
            canvas.style.setProperty('height', ...originalHeight);
        }
        if (savedTitle !== undefined) doc.title = savedTitle;
        staticHandoff?.dispose();
        if (wrapper) wrapper.replaceWith(canvas);
        for (const undo of changes.reverse()) undo();
        if (owned) canvas.remove();
    }};
}

// CSS insets can settle after orientation changes without another window resize.
function fullWindowViewport(canvas, doc, win) {
    const probe = doc.createElement('div');
    probe.style.cssText = 'position:fixed;visibility:hidden;pointer-events:none;width:0;height:0;box-sizing:content-box;' +
        'padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)';
    doc.body.append(probe);
    const original = ['width','height','left','top'].map(name =>
        [name, canvas.style.getPropertyValue(name), canvas.style.getPropertyPriority(name)]);
    let observer;
    return {
        insets: [0, 0, 0, 0],
        watch(resized, options) {
            const update = () => {
                const v = win.visualViewport;
                const rect = [v?.width ?? win.innerWidth, v?.height ?? win.innerHeight,
                              v?.offsetLeft ?? 0, v?.offsetTop ?? 0];
                original.forEach(([name], i) => {
                    const value = rect[i] + 'px';
                    if (canvas.style.getPropertyValue(name) !== value) canvas.style.setProperty(name, value);
                });
                const css = win.getComputedStyle(probe);
                const insets = [css.paddingTop, css.paddingRight, css.paddingBottom, css.paddingLeft]
                    .map(value => parseFloat(value) || 0);
                if (insets.some((n, i) => n !== this.insets[i])) this.insets = insets;
                resized();
            };
            win.visualViewport?.addEventListener('resize', update, options);
            win.visualViewport?.addEventListener('scroll', update, options);
            win.addEventListener('resize', update, options);
            observer = new ResizeObserver(update);
            observer.observe(probe, {box:'border-box'});
            update();
        },
        dispose() {
            observer?.disconnect();
            probe.remove();
            for (const [name, previous, priority] of original) canvas.style.setProperty(name, previous, priority);
        }
    };
}

function handOffStatic(doc, win, wrapper, exported) {
    const input = new AbortController(), signal = input.signal;
    const restore = [];
    let timer = 0, first = 0, second = 0, touch = false, presented = false, swapped = false, lastScroll = -Infinity;
    const defer = () => {
        if (!presented) return;
        win.clearTimeout(timer);
        timer = win.setTimeout(drop, 150);
    };
    function save(element, names) {
        const original = names.map(name => [name, element.getAttribute(name)]);
        restore.push(() => {
            for (const [name, value] of original) {
                if (value === null) element.removeAttribute(name);
                else element.setAttribute(name, value);
            }
        });
    }
    function drop() {
        if (touch || swapped) return;
        if (performance.now() - lastScroll < 120) { defer(); return; }
        swapped = true;
        input.abort();
        win.clearTimeout(timer);
        const nodes = [...doc.querySelectorAll('[data-rune-static]')];
        const anchor = win.scrollY > 0 &&
            [...exported.querySelectorAll('[id]')].find(node => node.getBoundingClientRect().bottom > 0);
        const id = anchor?.id, top = anchor && anchor.getBoundingClientRect().top;
        for (const node of nodes) {
            if (node.tagName === 'STYLE') {
                const previous = node.disabled;
                node.disabled = true;
                restore.push(() => { node.disabled = previous; });
                continue;
            }
            save(node, ['style','inert','aria-hidden','id','data-rune-static','data-rune-static-hidden']);
            Object.assign(node.style, {position:'absolute',width:'0',height:'0',overflow:'hidden',visibility:'hidden'});
            node.inert = true;
            node.setAttribute('aria-hidden', 'true');
            node.removeAttribute('data-rune-static');
            node.setAttribute('data-rune-static-hidden', '');
            node.removeAttribute('id');
            for (const named of node.querySelectorAll('[id]')) { save(named, ['id']); named.removeAttribute('id'); }
        }
        const live = id && wrapper.querySelector('#' + CSS.escape(id));
        if (live) {
            const delta = live.getBoundingClientRect().top - top;
            if (Math.abs(delta) > 2) win.scrollTo({top:win.scrollY + delta, behavior:'instant'});
        }
    }
    win.addEventListener('scroll', () => { lastScroll = performance.now(); defer(); }, {signal, passive:true});
    win.addEventListener('touchstart', () => { touch = true; }, {signal, passive:true});
    const end = event => { touch = Boolean(event.touches?.length); if (!touch) defer(); };
    win.addEventListener('touchend', end, {signal, passive:true});
    win.addEventListener('touchcancel', end, {signal, passive:true});
    return {
        presented() {
            if (presented) return;
            presented = true;
            first = win.requestAnimationFrame(() => { second = win.requestAnimationFrame(drop); });
        },
        dispose() {
            input.abort();
            win.cancelAnimationFrame(first);
            win.cancelAnimationFrame(second);
            win.clearTimeout(timer);
            for (const undo of restore.reverse()) undo();
        }
    };
}
