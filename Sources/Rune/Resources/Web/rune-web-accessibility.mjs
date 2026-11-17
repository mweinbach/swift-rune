// The canvas owns pointer input. Its transparent sibling exposes Rune's controls in their
// actual positions to keyboard users, screen readers, and touch exploration.
const roles = {
    icon: 'img', splitter: 'separator', 'menu-item-check-box': 'menuitemcheckbox', 'menu-item-radio': 'menuitemradio'
};
const fieldRoles = new Set(['textbox', 'password-input', 'multiline-text-input']);
const checkedRoles = new Set(['checkbox', 'switch', 'radio', 'menuitemcheckbox', 'menuitemradio']);
const selectedRoles = new Set(['tab', 'option', 'row', 'treeitem', 'gridcell']);
const isEditor = node => fieldRoles.has(node.role) || (node.role === 'combobox' && node.chars != null);

function attribute(element, name, value) {
    if (value == null) {
        if (element.hasAttribute(name)) element.removeAttribute(name);
    } else if (element.getAttribute(name) !== String(value)) {
        element.setAttribute(name, value);
    }
}

let nextMount = 0;

export function mountRuneAccessibility(canvas, send) {
    const doc = canvas.ownerDocument;
    const root = doc.createElement('div');
    root.style.cssText = 'position:absolute;opacity:0;pointer-events:none;overflow:hidden;transform-origin:top left';
    canvas.after(root);
    const live = doc.createElement('div');
    root.append(live);
    const slots = new Map();
    const idPrefix = 'rune-ax-' + ++nextMount + '-';
    const listeners = new AbortController();
    let nextID = 0;
    let viewport;
    let placement;
    let editor;
    let editorPath;
    let syncingFocus = false;

    function place() {
        if (!viewport || viewport[0] <= 0 || viewport[1] <= 0) return;
        const geometry = [canvas.offsetLeft + canvas.clientLeft, canvas.offsetTop + canvas.clientTop,
            ...viewport, canvas.clientWidth / viewport[0], canvas.clientHeight / viewport[1]];
        if (placement && geometry.every((value, i) => value === placement[i])) return;
        placement = geometry;
        const [x, y, w, h, sx, sy] = geometry;
        root.style.left = x + 'px';
        root.style.top = y + 'px';
        root.style.width = w + 'px';
        root.style.height = h + 'px';
        root.style.transform = 'scale(' + sx + ',' + sy + ')';
    }

    function create(node) {
        const field = isEditor(node);
        const range = node.role === 'slider' && !!node.range;
        const box = doc.createElement(node.role === 'text' ? 'span' : 'div');
        box.style.cssText = 'box-sizing:border-box;position:absolute;pointer-events:none;margin:0;padding:0;border:0';
        const text = node.role === 'text' ? doc.createTextNode('') : null;
        if (text) box.append(text);
        let control = box;
        if (field || range) {
            // An unfocused editor can be found by reading, tabbing or touch. The active
            // editor occupies the same slot with its real native selection and IME.
            control = doc.createElement(node.role === 'multiline-text-input' ? 'textarea' : 'input');
            if (control.tagName === 'INPUT') control.type = range ? 'range' : node.role === 'password-input' ? 'password' : 'text';
            control.style.cssText = 'box-sizing:border-box;width:100%;height:100%;margin:0;padding:0;border:0;pointer-events:none';
            box.append(control);
        }
        control.id = idPrefix + ++nextID;
        control.dataset.runeTarget = node.path;
        return { box, control, field, range, text, node };
    }

    function apply(record, node, parentBounds) {
        const { box, control, field } = record;
        const [x, y, width, height] = node.bounds;
        const states = new Set(node.states);
        box.style.left = (x - parentBounds[0]) + 'px';
        box.style.top = (y - parentBounds[1]) + 'px';
        box.style.width = Math.max(0, width) + 'px';
        box.style.height = Math.max(0, height) + 'px';
        box.style.overflow = states.has('clips') ? 'hidden' : 'visible';

        const role = roles[node.role] ?? node.role;
        if ((!field || role === 'combobox') && role !== 'text') attribute(control, 'role', role);
        if (role === 'text') {
            if (record.text.data !== (node.name ?? '')) record.text.data = node.name ?? '';
        } else {
            attribute(control, 'aria-label', node.name);
        }
        attribute(control, 'aria-description', node.description);
        attribute(control, 'aria-keyshortcuts', node.shortcut);
        attribute(control, 'aria-placeholder', node.placeholder);
        attribute(control, 'aria-disabled', states.has('disabled') || null);
        attribute(control, 'aria-readonly', states.has('read-only') || null);
        attribute(control, 'aria-invalid', states.has('invalid') || null);
        attribute(control, 'aria-modal', states.has('modal') || null);
        attribute(control, 'aria-busy', node.busy || null);
        attribute(control, 'aria-sort', node.sort);
        attribute(control, 'aria-level', node.level ?? (role === 'heading' ? 2 : null));
        attribute(control, 'aria-posinset', node.position);
        attribute(control, 'aria-setsize', node.setSize);
        attribute(control, 'aria-live', states.has('live-polite') ? 'polite' : states.has('live-assertive') ? 'assertive' : null);
        attribute(control, 'aria-expanded', states.has('expanded') ? true : states.has('collapsed') ? false : null);
        const selectable = role === 'tab' || role === 'option' || states.has('selected') || states.has('unselected');
        attribute(control, 'aria-selected', selectable && selectedRoles.has(role) ? states.has('selected') : null);
        if (checkedRoles.has(role) || (role === 'button' && (states.has('checked') || states.has('unchecked') || states.has('mixed')))) {
            const checked = states.has('mixed') || node.value === 'mixed' ? 'mixed'
                : states.has('checked') || states.has('selected') || node.value === 'true';
            attribute(control, role === 'button' ? 'aria-pressed' : 'aria-checked', checked);
        } else {
            attribute(control, 'aria-pressed', null);
        }
        attribute(control, 'aria-valuenow', node.range?.[0]);
        attribute(control, 'aria-valuemin', node.range?.[1]);
        attribute(control, 'aria-valuemax', node.range?.[2]);
        attribute(control, 'aria-valuetext', node.range ? node.value : null);
        const actions = node.actions ?? [];
        const reachable = !states.has('disabled') && (node.focusable || actions.includes('focus') || actions.includes('press'));
        attribute(control, 'tabindex', reachable ? 0 : field ? -1 : null);
        if (record.range) {
            const [value, min, max, step] = node.range;
            control.min = min;
            control.max = max;
            control.step = step > 0 ? step : 'any';
            control.value = value;
            control.disabled = states.has('disabled');
        } else if (field) {
            const text = node.role === 'password-input' ? '' : node.value ?? '';
            if (control.value !== text) control.value = text;
            control.readOnly = states.has('read-only');
            control.disabled = states.has('disabled');
        }
        record.node = node;
    }

    function attachEditor(next, key) {
        if (editorPath !== key) {
            const old = slots.get(editorPath);
            if (old?.field) old.control.hidden = false;
        }
        editor = next;
        editorPath = key;
        const slot = slots.get(key);
        if (!editor) return;
        if (!slot?.field) {
            if (editor.parentNode !== doc.body) doc.body.append(editor);
            editor.style.cssText = 'position:fixed;top:0;left:0;width:1px;height:1px;opacity:0;pointer-events:none;font-size:16px';
            editor.tabIndex = -1;
            return;
        }
        slot.control.hidden = true;
        if (editor.parentNode !== slot.box) slot.box.append(editor);
        editor.style.cssText = 'box-sizing:border-box;position:absolute;inset:0;width:100%;height:100%;opacity:0;pointer-events:none;margin:0;padding:0;border:0;font-size:16px';
        editor.tabIndex = 0;
        for (const name of ['role', 'aria-description', 'aria-invalid', 'aria-readonly', 'aria-placeholder',
            'aria-activedescendant', 'aria-controls', 'aria-expanded']) {
            attribute(editor, name, slot.control.getAttribute(name));
        }
        editor.readOnly = slot.control.readOnly;
    }

    function sync(packet) {
        const seen = new Set();
        const ownsFocus = doc.activeElement === canvas || root.contains(doc.activeElement);
        let focused;
        const activeRelations = [];
        const byKey = new Map();
        function visit(node, parent, previousSibling, parentBounds) {
            let record = slots.get(node.path);
            if (record && (record.node.role !== node.role || record.field !== isEditor(node) ||
                record.range !== (node.role === 'slider' && !!node.range))) {
                record.box.remove();
                record = null;
            }
            if (!record) {
                record = create(node);
                slots.set(node.path, record);
            }
            seen.add(node.path);
            if (!byKey.has(node.key)) byKey.set(node.key, []);
            byKey.get(node.key).push(record);
            const anchor = previousSibling ? previousSibling.nextSibling : parent.firstChild;
            if (anchor !== record.box) parent.insertBefore(record.box, anchor);
            apply(record, node, parentBounds);
            if (node.activeDescendant) activeRelations.push(record);
            else {
                attribute(record.control, 'aria-activedescendant', null);
                attribute(record.control, 'aria-controls', null);
            }
            if (node.states?.includes('focused')) focused = record;
            let previous = record.field || record.range ? record.control : record.text;
            for (const child of node.children ?? []) previous = visit(child, record.box, previous, node.bounds);
            return record.box;
        }
        viewport = [packet.width, packet.height];
        place();
        visit(packet.root, root, null, [0, 0]);
        for (const [path, record] of slots) {
            if (!seen.has(path)) { record.box.remove(); slots.delete(path); }
        }
        for (const record of activeRelations) {
            const choices = byKey.get(record.node.activeDescendant) ?? [];
            let scope = record.box, target;
            while (!target && scope && root.contains(scope)) {
                target = choices.find(candidate => scope.contains(candidate.box));
                scope = scope.parentElement;
            }
            attribute(record.control, 'aria-activedescendant', target?.control.id);
            const popup = record.node.role === 'combobox' && target?.box.closest('[role=listbox],[role=tree],[role=grid]');
            attribute(record.control, 'aria-controls', popup?.id || null);
        }
        if (packet.announcement) {
            live.setAttribute('aria-live', packet.announcement.live);
            live.textContent = packet.announcement.text;
        }
        attachEditor(editor, editorPath);
        if (focused && !focused.field && ownsFocus && doc.activeElement !== focused.control) {
            syncingFocus = true;
            try { focused.control.focus({ preventScroll: true }); } finally { syncingFocus = false; }
        }
    }

    function handle(event) {
        if (syncingFocus || event.target === editor) return;
        const target = event.target.closest('[data-rune-target]');
        const record = target && slots.get(target.dataset.runeTarget);
        if (!record || record.node.states?.includes('disabled')) return;
        const actions = record.node.actions ?? [];
        if (event.type === 'input') {
            if (record.range && actions.includes('set-value') && Number.isFinite(target.valueAsNumber)) {
                send({kind: 'accessibility', action: 'set-value', key: record.node.path, number: target.valueAsNumber});
            }
            return;
        }
        let action;
        if (event.type === 'focusin') action = actions.includes('focus') ? 'focus' : record.field ? 'press' : undefined;
        else if (event.type === 'click') action = 'press';
        else if (event.type === 'keydown') {
            if (event.key === 'Tab' || event.isComposing) return;
            if (event.key === 'Enter' || event.key === ' ') {
                if (event.repeat) { event.preventDefault(); return; }
                action = 'press';
            } else if (['ArrowUp', 'ArrowRight'].includes(event.key)) action = 'increment';
            else if (['ArrowDown', 'ArrowLeft'].includes(event.key)) action = 'decrement';
        }
        if (action && actions.includes(action) && send({ kind: 'accessibility', key: record.node.path, action })) {
            event.preventDefault();
        } else if (event.type === 'keydown') {
            if (send({kind: 'key', key: event.key, code: event.code, shift: event.shiftKey, alt: event.altKey,
                ctrl: event.ctrlKey, cmd: event.metaKey})) event.preventDefault();
        }
    }
    for (const type of ['focusin', 'click', 'keydown', 'input']) root.addEventListener(type, handle, { signal: listeners.signal });
    return { sync, place, attachEditor, dispose() { listeners.abort(); slots.clear(); root.remove(); } };
}
