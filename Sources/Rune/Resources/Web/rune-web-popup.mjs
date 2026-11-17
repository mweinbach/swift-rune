// A canvas owns its app menus. Other secondary clicks use the browser's own menu over
// an actual text field, selection, link or page instead of offering to save the canvas.
export function mountRunePopup(canvas, send, fields, signal) {
    const doc = canvas.ownerDocument;
    const win = doc.defaultView;
    let levels = [], token = null, listeners, nativeCleanup, claimed = false;

    function disarm() {
        nativeCleanup?.();
        nativeCleanup = null;
    }

    function closeFrom(depth) {
        while (levels.length > depth) {
            const level = levels.pop();
            level.parent?.row.setAttribute('aria-expanded', 'false');
            level.menu.remove();
        }
    }

    function hide(refocus = false) {
        const wasOpen = levels.length > 0;
        closeFrom(0);
        listeners?.abort();
        listeners = null;
        token = null;
        if (wasOpen && refocus) canvas.focus({preventScroll: true});
    }

    function answer(id) {
        if (token == null) return;
        const current = token;
        hide(true);
        send({kind: 'menu', token: current, id});
    }

    function show(packet, point) {
        hide();
        disarm();
        if (!packet?.menu) return;
        token = packet.token;
        const colors = packet.dark
            ? ['#2b2b2b', '#f2f2f2', '#8f8f8f', '#454545', '#3d3d3d']
            : ['#fff', '#1a1a1a', '#8c8c8c', '#e0e0e0', '#ebebeb'];
        const [background, fg, muted, line, hover] = colors;

        function focus(level, item, pointer = false) {
            if (!item) return;
            if (level.active !== item) {
                if (level.active) level.active.row.style.background = '';
                level.active = item;
                closeFrom(levels.indexOf(level) + 1);
            }
            item.row.style.background = item.enabled ? hover : '';
            item.row.focus({preventScroll: true});
            if (pointer && item.enabled && item.submenu) openSub(level, item);
            if (!pointer) {
                const list = level.menu.getBoundingClientRect(), row = item.row.getBoundingClientRect();
                if (row.top < list.top) level.menu.scrollTop += row.top - list.top;
                else if (row.bottom > list.bottom) level.menu.scrollTop += row.bottom - list.bottom;
            }
        }

        function open(spec, left, top, minWidth, parent = null) {
            const menu = doc.createElement('div');
            menu.setAttribute('data-rune-menu', '');
            menu.setAttribute('role', 'menu');
            menu.tabIndex = -1;
            menu.style.cssText = `position:fixed;z-index:2147483647;box-sizing:border-box;padding:4px;margin:0;max-width:calc(100vw - 8px);max-height:calc(100vh - 8px);overflow:auto;border:1px solid ${line};border-radius:8px;box-shadow:0 4px 16px rgba(0,0,0,.18);font:13px/18px system-ui,sans-serif;background:${background};color:${fg};user-select:none;outline:none`;
            menu.style.minWidth = Math.min(Math.max(minWidth, 160), Math.max(0, win.innerWidth - 8)) + 'px';
            const level = {menu, rows: [], active: null, parent};
            levels.push(level);
            for (const entry of spec.items) {
                if (entry.separator) {
                    const rule = doc.createElement('div');
                    rule.setAttribute('role', 'separator');
                    rule.style.cssText = `height:1px;margin:4px 0;background:${line}`;
                    menu.append(rule);
                    continue;
                }
                const row = doc.createElement('div');
                const item = {row, id: entry.id, title: entry.submenu ?? entry.title,
                    enabled: entry.enabled !== false, submenu: entry.menu};
                level.rows.push(item);
                row.setAttribute('role', entry.checked ? 'menuitemcheckbox' : 'menuitem');
                if (entry.checked) row.setAttribute('aria-checked', 'true');
                if (!item.enabled) row.setAttribute('aria-disabled', 'true');
                if (item.submenu) {
                    row.setAttribute('aria-haspopup', 'menu');
                    row.setAttribute('aria-expanded', 'false');
                } else row.dataset.runeMenuId = item.id;
                row.tabIndex = -1;
                row.style.cssText = `display:flex;align-items:center;gap:16px;padding:4px 10px 4px 26px;border-radius:4px;position:relative;cursor:default;white-space:nowrap;outline:none;color:${item.enabled ? fg : muted}`;
                const title = doc.createElement('span');
                title.style.flex = '1';
                title.textContent = item.title;
                row.append(title);
                if (entry.checked) {
                    const tick = doc.createElement('span');
                    tick.textContent = '✓';
                    tick.setAttribute('aria-hidden', 'true');
                    tick.style.cssText = 'position:absolute;left:9px';
                    row.append(tick);
                }
                if (item.submenu || entry.keyEquivalent) {
                    const hint = doc.createElement('span');
                    hint.setAttribute('aria-hidden', 'true');
                    hint.textContent = item.submenu ? '›' : entry.keyEquivalent.replace(/^mod\+/i,
                        /Mac|iP/.test(win.navigator.platform) ? '⌘' : 'Ctrl+');
                    hint.style.color = muted;
                    row.append(hint);
                }
                row.addEventListener('pointerenter', () => focus(level, item, true));
                row.addEventListener('click', event => {
                    event.preventDefault();
                    if (!item.enabled) return;
                    if (item.submenu) openSub(level, item);
                    else answer(item.id);
                });
                menu.append(row);
            }
            doc.body.append(menu);
            const rect = menu.getBoundingClientRect();
            if (left + rect.width > win.innerWidth - 4) {
                left = parent ? parent.row.getBoundingClientRect().left - rect.width + 4 : win.innerWidth - rect.width - 4;
            }
            if (top + rect.height > win.innerHeight - 4) {
                top = !parent && top - rect.height >= 4 ? top - rect.height : win.innerHeight - rect.height - 4;
            }
            menu.style.left = Math.max(4, left) + 'px';
            menu.style.top = Math.max(4, top) + 'px';
            return level;
        }

        function openSub(level, item) {
            if (!item.submenu || !item.enabled) return null;
            const index = levels.indexOf(level) + 1;
            if (levels[index]?.parent === item) return levels[index];
            closeFrom(index);
            const rect = item.row.getBoundingClientRect();
            item.row.setAttribute('aria-expanded', 'true');
            return open(item.submenu, rect.right - 4, rect.top - 5, 0, item);
        }

        const top = open(packet.menu, point.x, point.y, point.width);
        top.menu.focus({preventScroll: true});
        const selected = top.rows.find(item => item.id !== undefined && item.id === packet.menu.selected);
        if (selected) {
            const bounds = top.menu.getBoundingClientRect();
            const offset = selected.row.getBoundingClientRect().top - bounds.top;
            top.menu.style.top = Math.max(4, Math.min(win.innerHeight - bounds.height - 4, point.y - offset)) + 'px';
            focus(top, selected);
        }

        function key(event) {
            const level = levels.at(-1);
            if (!level) return;
            const rows = level.rows.filter(item => item.enabled);
            const at = rows.indexOf(level.active);
            const k = event.key;
            if (k === 'Escape' && levels.length > 1 || k === 'ArrowLeft' && levels.length > 1) {
                closeFrom(levels.length - 1);
                level.parent.row.focus({preventScroll: true});
            } else if (k === 'Escape' || k === 'Tab') answer(null);
            else if (k === 'Home') focus(level, rows[0]);
            else if (k === 'End') focus(level, rows.at(-1));
            else if (k === 'ArrowDown') focus(level, rows[(at + 1) % rows.length]);
            else if (k === 'ArrowUp') focus(level, rows[at <= 0 ? rows.length - 1 : at - 1]);
            else if (k === 'ArrowRight' || k === 'Enter' || k === ' ') {
                if (level.active?.enabled) {
                    if (level.active.submenu) {
                        const child = openSub(level, level.active);
                        focus(child, child.rows.find(item => item.enabled));
                    } else if (k !== 'ArrowRight') answer(level.active.id);
                }
            } else if (!event.altKey && !event.ctrlKey && !event.metaKey && k.length === 1 && /\S/u.test(k)) {
                const hit = rows.slice(at + 1).concat(rows.slice(0, at + 1))
                    .find(item => item.title.trim().toLocaleLowerCase().startsWith(k.toLocaleLowerCase()));
                if (hit) focus(level, hit);
            } else return;
            event.preventDefault();
            event.stopPropagation();
        }
        listeners = new AbortController();
        const options = {capture: true, signal: listeners.signal};
        doc.addEventListener('keydown', key, options);
        doc.addEventListener('pointerdown', event => {
            if (!levels.some(level => level.menu.contains(event.target))) answer(null);
        }, options);
        win.addEventListener('blur', () => answer(null), {signal: listeners.signal});
        win.addEventListener('resize', () => answer(null), {signal: listeners.signal});
    }

    function arm(event, claim) {
        disarm();
        claimed = claim.kind === 'app' && !event.shiftKey;
        if (claimed) return true;
        send({kind: 'secondaryBrowser'});
        const field = claim.kind === 'field' && fields.activeEditor();
        if (field) {
            const before = field.style.cssText;
            const was = field.parentNode, next = field.nextSibling;
            // The accessibility mirror may have a transformed, clipped containing block.
            doc.body.append(field);
            Object.assign(field.style, {position:'fixed', left:event.clientX - 2 + 'px', top:event.clientY - 2 + 'px',
                width:'4px', height:'4px', opacity:'0', pointerEvents:'auto', zIndex:'2147483646'});
            field.focus({preventScroll:true});
            nativeCleanup = () => {
                field.style.cssText = before;
                if (was?.isConnected && field.parentNode === doc.body) was.insertBefore(field, next?.parentNode === was ? next : null);
            };
        } else {
            const link = !claim.selection && /^(?:https?:\/\/|mailto:)/.test(claim.href ?? '');
            const target = doc.createElement(link ? 'a' : 'span');
            if (link) {
                target.href = claim.href;
                target.target = '_blank';
                target.rel = 'noopener noreferrer';
            }
            target.dataset.runeContext = '';
            target.style.cssText = `position:fixed;left:${event.clientX-4}px;top:${event.clientY-4}px;width:8px;height:8px;overflow:hidden;z-index:2147483646;opacity:0;white-space:pre;user-select:text`;
            target.textContent = claim.selection ?? claim.text ?? '';
            doc.body.append(target);
            if (claim.selection) {
                const range = doc.createRange();
                range.selectNodeContents(target);
                doc.getSelection().removeAllRanges();
                doc.getSelection().addRange(range);
            }
            nativeCleanup = () => {
                const selection = doc.getSelection();
                if (target.contains(selection?.anchorNode)) selection.removeAllRanges();
                target.remove();
            };
        }
        return false;
    }

    // During a captured app press the browser sends contextmenu at different times on macOS
    // and Windows. Keep the decision until the next gesture, independently of pointerup.
    canvas.addEventListener('contextmenu', event => {
        if (claimed || levels.length) event.preventDefault();
    }, {signal});
    for (const name of ['pointerdown', 'wheel', 'keydown']) {
        win.addEventListener(name, event => {
            if (name === 'pointerdown' && event.button === 2) return;
            claimed = false;
            disarm();
        }, {capture:true, passive:true, signal});
    }
    return { show, arm, dispose() { hide(); disarm(); } };
}
