// Native document elements mirror the drawn text and geometry. The browser owns selection,
// fragment navigation, and horizontal momentum scrolling inside the document.
const tags = new Map(Object.entries({
    main: 'main', navigation: 'nav', banner: 'header', contentinfo: 'footer',
    region: 'section', article: 'article', complementary: 'aside', list: 'ul', listitem: 'li',
    figure: 'figure', text: 'p', link: 'a', button: 'button'
}));

export function documentTag(node) {
    if (Number.isInteger(node.inlineStart) && Number.isInteger(node.inlineEnd)) return 'a';
    if (node.role === 'heading') return 'h' + Math.max(1, Math.min(6, Math.trunc(node.level) || 2));
    return tags.get(node.role) ?? 'div';
}

export function installDocumentSelectionStyle(root) {
    if (root.hasAttribute('data-rune-document-mirror')) return;
    root.setAttribute('data-rune-document-mirror', '');
    root.style.opacity = '1';
    root.style.color = 'transparent';
    const style = root.ownerDocument.createElement('style');
    style.textContent = `
        [data-rune-document-mirror] { forced-color-adjust:none }
        [data-rune-document-mirror] :where(a,button,input,textarea) {
            background:transparent; color:transparent; -webkit-tap-highlight-color:transparent
        }
        [data-rune-document-mirror] :where(input,textarea):not(:focus) { caret-color:transparent }
        [data-rune-document-mirror] :where(ul,li) { list-style:none }
        [data-rune-document-mirror] :focus-visible {
            outline:2px solid var(--rune-focus,Highlight); outline-offset:2px; border-radius:4px
        }
        [data-rune-document-mirror] ::selection {
            background:var(--rune-selection,rgba(80,150,255,.35)); color:transparent
        }
        [data-rune-document-mirror] [data-rune-scroll-x]::-webkit-scrollbar { display:none }
    `;
    root.append(style);
}

function setFont(box, font) {
    const style = box.style;
    style.fontFamily = font?.family || 'sans-serif';
    style.fontSize = (font?.size ?? 14) + 'px';
    style.fontWeight = font?.weight ?? 'normal';
    style.fontStyle = font?.italic ? 'italic' : 'normal';
    style.lineHeight = font ? font.lineHeight + 'px' : '1.25';
    style.letterSpacing = font ? font.tracking + 'px' : 'normal';
    style.textAlign = font?.align ?? 'start';
    style.whiteSpace = 'pre-wrap';
    style.overflowWrap = 'break-word';
}

function syncScroller(record, node, send) {
    const { box } = record;
    if (!Number.isFinite(node.pageContentWidth)) {
        if (record.pageScroll) {
            box.removeEventListener('scroll', record.pageScroll.listener);
            record.spacer.remove();
            record.spacer = null;
            record.pageScroll = null;
            box.removeAttribute('data-rune-scroll-x');
            box.style.removeProperty('scrollbar-width');
            box.style.removeProperty('touch-action');
        }
        return;
    }
    let scroll = record.pageScroll;
    if (!scroll) {
        const spacer = box.ownerDocument.createElement('span');
        spacer.style.cssText = 'position:absolute;left:0;top:0;height:1px;pointer-events:none';
        spacer.setAttribute('aria-hidden', 'true');
        box.append(spacer);
        record.spacer = spacer;
        scroll = { requested: undefined, pending: false, seen: 0 };
        scroll.listener = () => {
            const offset = box.scrollLeft;
            if (Math.abs(offset - scroll.seen) <= 0.5) return;
            scroll.seen = offset;
            send({ kind: 'pageScrollX', key: node.path, x: offset });
        };
        box.setAttribute('data-rune-scroll-x', '');
        box.addEventListener('scroll', scroll.listener, { passive: true });
        record.pageScroll = scroll;
    }
    const width = Math.max(0, node.pageContentWidth) + 'px';
    if (record.spacer.style.width !== width) record.spacer.style.width = width;
    const requested = Math.max(0, node.pageScrollX ?? 0);
    if (scroll.requested !== requested) {
        scroll.requested = requested;
        scroll.pending = true;
    }
    box.style.overflowX = 'auto';
    box.style.overflowY = 'hidden';
    box.style.pointerEvents = 'auto';
    box.style.touchAction = 'pan-x pan-y pinch-zoom';
    box.style.scrollbarWidth = 'none';
}

export function applyDocumentNode(record, node, send) {
    const { box, control } = record;
    if (record.defaultID === undefined) record.defaultID = box.id;
    const id = node.anchor || record.defaultID;
    if (box.id !== id) box.id = id;
    const text = node.role === 'text' || node.role === 'heading';
    const link = box.localName === 'a';
    const button = box.localName === 'button';
    const inline = link && Number.isInteger(node.inlineStart) && Number.isInteger(node.inlineEnd);
    if (button) box.type = 'button';
    if (link) {
        // Internal link actions also have a Rune ID. Only navigable URLs get an href.
        if (/^(?:https?:\/\/|mailto:|#)/i.test(node.url ?? '') && !node.states?.includes('disabled')) {
            if (box.getAttribute('href') !== node.url) box.setAttribute('href', node.url);
        } else box.removeAttribute('href');
        if (/#link-\d+$/.test(node.path) && /^(?:https?:\/\/|mailto:)/i.test(box.getAttribute('href') ?? '')) {
            box.target = '_blank';
            box.rel = 'noopener noreferrer';
        } else {
            box.removeAttribute('target');
            box.removeAttribute('rel');
        }
        box.style.textDecoration = 'none';
    }
    if (inline) {
        // The parent carries the painted font and wraps this real text range in the anchor.
        box.style.position = 'static';
        box.style.font = 'inherit';
        box.style.letterSpacing = 'inherit';
        box.style.whiteSpace = 'inherit';
    } else if (text || link || button) {
        box.style.position = 'absolute';
        setFont(box, node.font);
    }
    box.style.pointerEvents = node.selectable || link ? 'auto' : 'none';
    if (text || link || button) {
        box.style.userSelect = box.style.webkitUserSelect = inline ? 'inherit' : node.selectable ? 'text' : 'none';
        box.style.cursor = link ? 'pointer' : node.selectable ? 'text' : '';
    }
    if (node.role === 'text') {
        if (node.documentText != null && node.name && node.documentText !== node.name) {
            if (box.getAttribute('aria-label') !== node.name) box.setAttribute('aria-label', node.name);
        } else box.removeAttribute('aria-label');
    }
    if (control !== box) control.style.background = 'transparent';
    syncScroller(record, node, send);
}

// Keep the text and anchor nodes for untouched ranges. Replacing innerHTML would collapse
// a browser selection on each geometry update, even when the text itself did not change.
function layoutInlineLinks(record, slots, content) {
    if (!record.children.length && !record.inlineFlow) return false;
    const links = record.children.map(path => slots.get(path)).filter(child => child?.box.localName === 'a' &&
        Number.isInteger(child.node.inlineStart) && Number.isInteger(child.node.inlineEnd));
    if (!links.length) {
        if (record.inlineFlow) {
            for (const gap of record.inlineFlow) gap.remove();
            record.inlineFlow = null;
        }
        return false;
    }
    links.sort((a, b) => a.node.inlineStart - b.node.inlineStart);
    const gaps = record.inlineFlow ??= [];
    const { box } = record;
    let cursor = box.firstChild;
    function place(element) {
        if (element !== cursor) box.insertBefore(element, cursor);
        cursor = element.nextSibling;
    }
    function putText(element, words) {
        if (element.data !== words) element.data = words;
        place(element);
    }
    const leading = record.text ?? (record.documentText ??= box.ownerDocument.createTextNode(''));
    let end = 0;
    for (let i = 0; i < links.length; i++) {
        const link = links[i];
        const start = Math.max(end, Math.min(content.length, link.node.inlineStart));
        const stop = Math.max(start, Math.min(content.length, link.node.inlineEnd));
        putText(i ? gaps[i - 1] : leading, content.slice(end, start));
        const words = content.slice(start, stop);
        if (!link.documentText) {
            link.documentText = box.ownerDocument.createTextNode(words);
            link.box.append(link.documentText);
        } else if (link.documentText.data !== words) link.documentText.data = words;
        place(link.box);
        gaps[i] ??= box.ownerDocument.createTextNode('');
        end = stop;
    }
    putText(gaps[links.length - 1], content.slice(end));
    while (gaps.length > links.length) gaps.pop().remove();
    return true;
}

export function finishDocumentNode(record, slots) {
    const { box, node, pageScroll } = record;
    if (pageScroll?.pending) {
        pageScroll.pending = false;
        box.scrollLeft = pageScroll.requested;
        // The browser can clamp this offset at the end, and delivers its scroll event later.
        pageScroll.seen = box.scrollLeft;
    }
    const content = node.documentText ?? node.name ?? '';
    if ((node.role === 'heading' || node.role === 'text') && layoutInlineLinks(record, slots, content)) return;
    if (node.role === 'text') {
        if (record.text.data !== content) record.text.data = content;
        return;
    }
    if (node.role !== 'heading' && node.role !== 'link' && node.role !== 'button') return;
    if (box.localName === 'a' && Number.isInteger(node.inlineStart)) return;
    // A heading wrapping a drawn text node already gets that child's contents (including its
    // selection). Label-only nodes need a text node for native Find, copying and narration.
    const hasContents = record.children.some(path => !path.startsWith(node.path + '#link-'));
    const label = !hasContents ? content : null;
    if (label) {
        if (!record.documentText) {
            record.documentText = box.ownerDocument.createTextNode(label);
            box.append(record.documentText);
        } else if (record.documentText.data !== label) record.documentText.data = label;
    } else if (record.documentText) {
        record.documentText.remove();
        record.documentText = null;
    }
}
