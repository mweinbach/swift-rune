import { documentTag, installDocumentSelectionStyle, applyDocumentNode, finishDocumentNode }
    from './rune-web-document-nodes.mjs';

// The canvas owns pointer input. Its transparent sibling exposes Rune's controls in their
// actual positions to keyboard users, screen readers, and touch exploration.
const roles = {
    "scroll-view": "group",
    icon: 'img', splitter: 'separator', 'menu-item-check-box': 'menuitemcheckbox', 'menu-item-radio': 'menuitemradio'
};
// Keys and inherited scroll-into-view keep a layout box addressable. Without other
// semantics its children can be read directly. Unknown packet fields retain the group.
const layoutFields = new Set(['role', 'key', 'path', 'bounds', 'actions', 'states']);
function isLayoutGroup(node) {
    return node.role === 'group' && !node.states?.length &&
        (!node.actions || node.actions.every(action => action === 'scroll-into-view')) &&
        Object.keys(node).every(key => layoutFields.has(key));
}

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

export function mountRuneAccessibility(canvas, send, documentMode = false) {
    const doc = canvas.ownerDocument;
    const root = doc.createElement('div');
    root.setAttribute('data-rune-a11y', '');
    root.style.cssText = 'position:absolute;opacity:0;pointer-events:none;overflow:hidden;transform-origin:top left;contain:layout style';
    root.setAttribute('role', 'document');
    if (documentMode) {
        root.style.opacity = '1';
        root.style.color = 'transparent';
    }
    canvas.after(root);
    const live = doc.createElement('div');
    root.append(live);
    const slots = new Map();
    const recordsByKey = new Map();
    const relations = new Set();
    let relatedTargets = new Set();
    let page = documentMode;
    let rootPath;
    let focusPath;
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
        const geometry = documentMode ? [0, 0, ...viewport, 1, 1]
            : [canvas.offsetLeft + canvas.clientLeft, canvas.offsetTop + canvas.clientTop,
            ...viewport, canvas.clientWidth / viewport[0], canvas.clientHeight / viewport[1]];
        if (placement && geometry.every((value, i) => value === placement[i])) return;
        placement = geometry;
        const [x, y, w, h, sx, sy] = geometry;
        root.style.left = x + 'px';
        root.style.top = y + 'px';
        root.style.width = w + 'px';
        root.style.height = h + 'px';
        root.style.transform = 'scale(' + sx + ',' + sy + ')';
        if (!documentMode) root.style.contain = 'strict';
    }

    function create(node) {
        const field = isEditor(node);
        const range = node.role === 'slider' && !!node.range;
        const box = doc.createElement(documentTag(node));
        box.style.cssText = 'box-sizing:border-box;position:absolute;pointer-events:none;margin:0;padding:0;border:0';
        if (box.localName === 'button') box.type = 'button';
        if (box.localName === 'li') box.style.listStyle = 'none';
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
        return { box, control, field, range, text, node, bounds: node.bounds, children: [], parent: null, rect: null };
    }

    function position(record) {
        const [left, top, w, h] = record.bounds;
        const width = Math.max(0, w), height = Math.max(0, h);
        const old = record.rect, style = record.box.style;
        if (old && left === old[0] && top === old[1] && width === old[2] && height === old[3]) return;
        if (!old || left !== old[0]) style.left = left + 'px';
        if (!old || top !== old[1]) style.top = top + 'px';
        if (!old || width !== old[2]) style.width = width + 'px';
        if (!old || height !== old[3]) style.height = height + 'px';
        record.rect = [left, top, width, height];
    }

    function apply(record, node) {
        const { box, control, field } = record;
        const states = new Set(node.states);
        box.style.overflow = states.has('clips') ? 'hidden' : 'visible';

        const role = roles[node.role] ?? node.role;
        record.layoutGroup = !page && isLayoutGroup(node);
        if ((!field || role === 'combobox') && role !== 'text') {
            attribute(control, 'role', record.layoutGroup && !relatedTargets.has(record) ? 'presentation' : role);
        }
        if (control.localName === 'button') control.disabled = states.has('disabled');
        if (role === 'text') {
            if (!record.inlineFlow && (!page || node.documentText == null) && record.text.data !== (node.name ?? '')) record.text.data = node.name ?? '';
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
        attribute(control, 'tabindex', reachable ? 0 : field || control.localName === 'button' ? -1 : null);
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
        if (page) applyDocumentNode(record, node, send);
        record.node = node;
        record.bounds = node.bounds;
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

    function forgetKey(record) {
        const key = record.node.key;
        const members = recordsByKey.get(key);
        if (!members) return;
        members.delete(record);
        if (!members.size) recordsByKey.delete(key);
    }

    function rememberKey(record, key) {
        if (key == null) return;
        let members = recordsByKey.get(key);
        if (!members) recordsByKey.set(key, members = new Set());
        members.add(record);
    }

    function resolveTarget(record) {
        const choices = recordsByKey.get(record.node.activeDescendant);
        let scope = record.box, target;
        while (choices?.size && scope && root.contains(scope) && !target) {
            for (const candidate of choices) {
                if (scope.contains(candidate.box) && (!target ||
                    (target.box.compareDocumentPosition(candidate.box) & Node.DOCUMENT_POSITION_PRECEDING))) {
                    target = candidate;
                }
            }
            scope = scope.parentElement;
        }
        attribute(record.control, 'aria-activedescendant', target?.control.id);
        const popup = record.node.role === 'combobox' && target?.box.closest('[role=listbox],[role=tree],[role=grid]');
        attribute(record.control, 'aria-controls', popup?.id || null);
        return target;
    }

    function insertAt(parent, box, anchor) {
        if (box === anchor) return;
        // A DOM move preserves an active field's selection and ongoing IME composition.
        if (box.isConnected && parent.isConnected && parent.moveBefore) parent.moveBefore(box, anchor);
        else parent.insertBefore(box, anchor);
    }

    function orderChildren(parent) {
        let previous = parent.field || parent.range ? parent.control : parent.text;
        for (const path of parent.children) {
            const record = slots.get(path);
            if (!record || record.parent !== parent.node.path) continue;
            const anchor = previous ? previous.nextSibling : parent.box.firstChild;
            insertAt(parent.box, record.box, anchor);
            previous = record.box;
        }
    }

    // Older reactors send a complete tree. It uses the same retained slots as newer delta packets.
    function flatten(rootNode) {
        const nodes = [], children = Object.create(null);
        function visit({children: descendants = [], ...node}, parentX, parentY) {
            const [x, y, width, height] = node.bounds;
            node.bounds = [x - parentX, y - parentY, width, height];
            nodes.push(node);
            children[node.path] = descendants.map(child => child.path);
            for (const child of descendants) visit(child, x, y);
        }
        visit(rootNode, 0, 0);
        return {rootPath: rootNode.path, nodes, children};
    }

    function sync(packet) {
        page = documentMode || (packet.document ?? page);
        if (page) installDocumentSelectionStyle(root);
        const patch = packet.root ? flatten(packet.root) : packet;
        if (patch.bounds && !patch.nodes && !patch.children && !patch.removed &&
            patch.rootPath == null && packet.width == null && !packet.announcement) {
            for (const [path, bounds] of Object.entries(patch.bounds)) {
                const record = slots.get(path);
                if (record) {
                    record.bounds = bounds;
                    position(record);
                }
            }
            return;
        }
        const previousFocus = focusPath;
        const active = doc.activeElement;
        const ownsFocus = active === canvas || root.contains(active);
        let relationsChanged = false, editorChanged = false;
        const positions = new Set(), parents = new Set(), textParents = new Set();
        const nodes = patch.nodes ?? [];
        const removed = new Set(patch.removed ?? []);
        if (patch.rootPath != null) {
            rootPath = patch.rootPath;
            const paths = new Set(nodes.map(node => node.path));
            for (const path of slots.keys()) if (!paths.has(path)) removed.add(path);
        }
        const removedParents = new Set();
        for (const path of removed) {
            const record = slots.get(path);
            if (!record) continue;
            forgetKey(record);
            relations.delete(record);
            if (focusPath === path) focusPath = null;
            if (editorPath === path) editorChanged = true;
            removedParents.add(record.parent);
            record.box.remove();
            slots.delete(path);
            relationsChanged = true;
        }
        for (const path of removedParents) {
            const parent = slots.get(path);
            if (parent && !Object.hasOwn(patch.children ?? {}, path)) {
                parent.children = parent.children.filter(child => !removed.has(child));
            }
        }
        for (const node of nodes) {
            let record = slots.get(node.path);
            const previous = record?.node;
            if (record && (previous.role !== node.role || record.box.localName !== documentTag(node) || record.field !== isEditor(node) ||
                record.range !== (node.role === 'slider' && !!node.range))) {
                const replaced = record;
                forgetKey(replaced);
                relations.delete(replaced);
                replaced.box.remove();
                record = create(node);
                record.parent = replaced.parent;
                record.children = replaced.children;
                parents.add(record.parent);
                parents.add(node.path);
                slots.set(node.path, record);
                rememberKey(record, node.key);
                relationsChanged = true;
            } else if (!record) {
                record = create(node);
                slots.set(node.path, record);
                rememberKey(record, node.key);
                relationsChanged = true;
            } else if (previous.key !== node.key) {
                forgetKey(record);
                rememberKey(record, node.key);
                relationsChanged = true;
            }
            if (node.activeDescendant) relations.add(record);
            else relations.delete(record);
            if (page && previous?.anchor !== node.anchor) relationsChanged = true;
            if (page && (previous?.inlineStart != null || node.inlineStart != null)) textParents.add(record.parent);
            if (previous?.activeDescendant !== node.activeDescendant) {
                relationsChanged = true;
                if (!node.activeDescendant) {
                    attribute(record.control, 'aria-activedescendant', null);
                    attribute(record.control, 'aria-controls', null);
                }
            }
            positions.add(node.path);
            apply(record, node);
            if (node.states?.includes('focused')) focusPath = node.path;
            else if (focusPath === node.path) focusPath = null;
            if (editorPath === node.path) editorChanged = true;
        }
        for (const [path, bounds] of Object.entries(patch.bounds ?? {})) {
            const record = slots.get(path);
            if (!record) continue;
            positions.add(path);
            record.bounds = bounds;
        }
        for (const [path, children] of Object.entries(patch.children ?? {})) {
            const parent = slots.get(path);
            if (!parent) continue;
            if (children.length !== parent.children.length || children.some((child, i) => child !== parent.children[i])) {
                parent.children = children;
                parents.add(path);
                relationsChanged = true;
            }
            for (const child of children) {
                const record = slots.get(child);
                if (!record || record.parent === path) continue;
                record.parent = path;
                parents.add(path);
            }
        }
        const rootNode = slots.get(rootPath);
        if (rootNode) {
            rootNode.parent = null;
            if (rootNode.box.parentNode !== root) insertAt(root, rootNode.box, root.firstChild);
        }
        // Mount parents before their children. A keyed branch can move above its old parent
        // during one update, and inserting it in the old order would form a temporary cycle.
        const ordered = new Set();
        function order(path) {
            if (ordered.has(path)) return;
            ordered.add(path);
            const parent = slots.get(path);
            if (!parent) return;
            for (let p = parent.parent; p != null; p = slots.get(p)?.parent) {
                if (parents.has(p)) order(p);
            }
            orderChildren(parent);
        }
        for (const path of parents) order(path);
        for (const path of positions) {
            const record = slots.get(path);
            if (record) position(record);
        }
        if (page) {
            const changed = new Set([...positions, ...parents, ...removedParents, ...textParents]);
            for (const path of changed) {
                const record = slots.get(path);
                if (record) finishDocumentNode(record, slots);
            }
        }
        if (relationsChanged && (relations.size || relatedTargets.size)) {
            const targets = new Set();
            for (const record of relations) {
                const target = resolveTarget(record);
                if (target) targets.add(target);
            }
            for (const target of relatedTargets) {
                if (target.layoutGroup && !targets.has(target)) attribute(target.control, 'role', 'presentation');
            }
            for (const target of targets) {
                if (target.layoutGroup && !relatedTargets.has(target)) attribute(target.control, 'role', 'group');
            }
            relatedTargets = targets;
        }
        if (packet.width != null && packet.height != null) {
            viewport = [packet.width, packet.height];
            place();
        }
        if (packet.announcement) {
            live.setAttribute('aria-live', packet.announcement.live);
            live.textContent = packet.announcement.text;
        }
        if (editorChanged || (editor && relationsChanged)) attachEditor(editor, editorPath);
        const focused = slots.get(focusPath);
        const changedFocus = focusPath !== previousFocus || doc.activeElement !== active || active === canvas;
        const restore = changedFocus && focused && !focused.field ? focused.control : active;
        if (ownsFocus && restore?.isConnected && doc.activeElement !== restore) {
            syncingFocus = true;
            try { restore.focus({ preventScroll: true }); } finally { syncingFocus = false; }
        }
    }

    function handle(event) {
        if (syncingFocus || event.target === editor) return;
        const target = event.target.closest('[data-rune-target]');
        const record = target && slots.get(target.dataset.runeTarget);
        if (!record || record.node.states?.includes('disabled')) return;
        const actions = record.node.actions ?? [];
        if (page && record.box.localName === 'a' && record.box.hasAttribute('href') &&
            (event.type === 'click' || event.type === 'keydown' && (event.key === 'Enter' || event.key === ' '))) return;
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
    return { sync, place, attachEditor, dispose() { listeners.abort(); slots.clear(); recordsByKey.clear(); relations.clear(); relatedTargets.clear(); root.remove(); } };
}
