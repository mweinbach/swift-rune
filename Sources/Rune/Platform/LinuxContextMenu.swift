#if os(Linux)
/// One visible column of a context menu. Every newly opened submenu gets a unique
/// token so a queued press from a closed branch cannot select its replacement.
struct LinuxPopupLevel {
    let menu: PopupMenu
    let title: String
    let parentRow: Int?
    let token: UInt64
    var highlighted: Int?

    func canSelect(_ row: Int) -> Bool {
        guard menu.entries.indices.contains(row) else { return false }
        switch menu.entries[row] {
        case .item(let item): return item.enabled
        case .submenu(_, _, let enabled): return enabled
        case .separator: return false
        }
    }

    var selectable: [Int] { menu.entries.indices.filter(canSelect) }
}

final class LinuxContextMenu<State> {
    weak var runtime: Runtime<State>?
    private(set) var levels: [LinuxPopupLevel] = []
    private(set) var show: PopupShow?
    var generation: UInt64 { levels.first?.token ?? 0 }
    var isOpen: Bool { show != nil }

    private var serial: UInt64 = 0
    private var session: PopupSession?
    private var request: ErasedPopupRequest?
    private var focusPath: String?
    private var focusKey: String?
    private var focusRing = false
    private var updateFocus = false
    private var followsPointer = false

    static func rowKey(_ token: UInt64, _ row: Int) -> String { "__rune_context_\(token)_row_\(row)" }
    static func listKey(_ token: UInt64) -> String { "__rune_context_\(token)_list" }

    /// Run between input callbacks. Resolving inside an element's onClick would
    /// reenter the app while its State is still borrowed by pointer dispatch.
    func refresh(at time: Double) {
        guard let runtime else { return }
        if isOpen {
            if !runtime.popupIsOpen || runtime.popupQueue.front !== request {
                close(at: time)
            } else if let answer = session?.takeAnswer(), let answeredRequest = request {
                close(at: time)
                if runtime.popupIsOpen, runtime.popupQueue.front === answeredRequest {
                    try? runtime.resolvePopup(answer.pickedId)
                }
            }
        }
        if !isOpen {
            // Failed requests have already called their completion with nil. Bound
            // this turn in case a completion keeps requesting another invalid menu.
            for _ in 0..<runtime.popupQueue.count {
                guard let next = runtime.takePopup() else { break }
                guard case .success(let popup) = next else { continue }
                let nextSession = PopupSession()
                _ = nextSession.begin()
                session = nextSession
                request = runtime.popupQueue.front
                focusPath = runtime.focusedPath
                focusKey = runtime.focusedKey
                focusRing = runtime.focusVisible
                show = popup
                followsPointer = false
                serial &+= 1
                var root = LinuxPopupLevel(menu: popup.menu, title: "Context menu", parentRow: nil,
                                           token: serial, highlighted: nil)
                if let selected = popup.menu.selectedId {
                    root.highlighted = root.selectable.first {
                        if case .item(let item) = root.menu.entries[$0] { return item.id == selected }
                        return false
                    }
                }
                levels = [root]
                changed()
                break
            }
        }
        guard updateFocus, let level = levels.last else { return }
        updateFocus = false
        let list = Self.listKey(level.token)
        let row = level.highlighted.map { Self.rowKey(level.token, $0) }
        runtime.update(at: time) { _, tx in
            tx.focusWhenShown(row ?? list, ring: true)
            if let row { tx.scrollIntoViewIn(list, row) }
        }
    }

    func cancelAll(at time: Double) {
        if isOpen { close(at: time) }
        runtime?.cancelPopups()
    }

    private func close(at time: Double) {
        session?.cancel()
        session = nil
        request = nil
        show = nil
        levels.removeAll()
        updateFocus = false
        if let runtime {
            // Restore before the user's callback so an explicit focus from that
            // callback wins. The active field can be unkeyed.
            let previous = focusPath.flatMap { runtime.nodeByPath[$0] == nil ? nil : $0 }
                ?? focusKey.flatMap { key in runtime.flatNodes.first(where: { $0.key == key })?.path }
            runtime.setFocus(path: previous, keyboard: focusRing, at: time)
            runtime.markNeedsCommit()
            runtime.waker.wake()
        }
        focusPath = nil
        focusKey = nil
    }

    private func changed() {
        updateFocus = true
        runtime?.markNeedsCommit()
        runtime?.waker.wake()
    }

    func dismiss(generation: UInt64) {
        guard isOpen, self.generation == generation else { return }
        answer(nil)
    }

    private func answer(_ picked: String?) {
        if session?.resolve(picked) == true { runtime?.waker.wake() }
    }

    func pointerMoved() { followsPointer = true }

    /// Highlight a pointer row or reveal its submenu.
    func hover(level depth: Int, row: Int, generation: UInt64) {
        guard followsPointer, levels.indices.contains(depth), levels[depth].token == generation,
              levels[depth].canSelect(row) else { return }
        highlight(depth, row)
        if case .submenu = levels[depth].menu.entries[row] {
            openSubmenu(depth, row, selectFirst: false)
        }
    }

    func activate(level depth: Int, row: Int, generation: UInt64) {
        guard levels.indices.contains(depth), levels[depth].token == generation,
              levels[depth].canSelect(row) else { return }
        switch levels[depth].menu.entries[row] {
        case .item(let item):
            answer(item.id)
        case .submenu:
            highlight(depth, row)
            openSubmenu(depth, row, selectFirst: true)
        case .separator: break
        }
    }

    private func highlight(_ depth: Int, _ row: Int) {
        guard levels[depth].highlighted != row else { return }
        levels.removeSubrange((depth + 1)..<levels.count)
        levels[depth].highlighted = row
        changed()
    }

    private func openSubmenu(_ depth: Int, _ row: Int, selectFirst: Bool) {
        guard case .submenu(let title, let submenu, true) = levels[depth].menu.entries[row] else { return }
        let child = depth + 1
        if levels.indices.contains(child), levels[child].parentRow == row {
            if selectFirst, levels[child].highlighted == nil, let first = levels[child].selectable.first {
                highlight(child, first)
            }
            return
        }
        levels.removeSubrange(child..<levels.count)
        serial &+= 1
        var level = LinuxPopupLevel(menu: submenu, title: title, parentRow: row, token: serial, highlighted: nil)
        if selectFirst { level.highlighted = level.selectable.first }
        levels.append(level)
        changed()
    }

    /// A tracking menu owns keyboard input until dismissed, including keys it does
    /// not bind. Underlying editors and application accelerators stay untouched.
    @discardableResult
    func navigate(_ event: KeyEvent) -> Bool {
        guard let level = levels.last else { return false }
        followsPointer = false
        let depth = levels.count - 1
        let rows = level.selectable
        if !event.mods.ctrl && !event.mods.alt && !event.mods.logo {
            switch event.key {
            case .escape, .arrowLeft, .arrowRight:
                let opensChild = event.key == (RuneLabels.shared.isRTL ? Key.arrowLeft : .arrowRight)
                if opensChild, let row = level.highlighted {
                    openSubmenu(depth, row, selectFirst: true)
                } else if !opensChild && depth > 0 {
                    levels.removeLast()
                    changed()
                } else if event.key == .escape {
                    answer(nil)
                }
                return true
            case .tab:
                answer(nil)
                return true
            case .arrowUp, .arrowDown:
                guard !rows.isEmpty else { return true }
                let step = event.key == .arrowUp ? -1 : 1
                let current = level.highlighted.flatMap { rows.firstIndex(of: $0) } ?? (step < 0 ? 0 : -1)
                highlight(depth, rows[(current + step + rows.count) % rows.count])
                return true
            case .home, .end:
                if let row = event.key == .home ? rows.first : rows.last { highlight(depth, row) }
                return true
            case .space, .enter:
                if let row = level.highlighted ?? rows.first { activate(level: depth, row: row, generation: level.token) }
                return true
            default: break
            }
        }
        if let id = Self.shortcut(event, in: level.menu) {
            answer(id)
        } else if case .text(let letter) = event.key, letter.count == 1, !event.mods.ctrl && !event.mods.alt && !event.mods.logo {
            let start = level.highlighted.flatMap { rows.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            for offset in rows.indices {
                let row = rows[(start + offset) % rows.count]
                let title: String
                switch level.menu.entries[row] {
                case .item(let item): title = item.title
                case .submenu(let name, _, _): title = name
                case .separator: continue
                }
                if title.lowercased().hasPrefix(letter.lowercased()) {
                    highlight(depth, row)
                    break
                }
            }
        }
        return true
    }

    private static func shortcut(_ event: KeyEvent, in menu: PopupMenu) -> String? {
        for entry in menu.entries {
            switch entry {
            case .item(let item) where item.enabled:
                if let key = item.keyEquivalent, Chord(parsing: key)?.matches(event, on: .linux) == true { return item.id }
            case .submenu(_, let child, true):
                if let id = shortcut(event, in: child) { return id }
            default: continue
            }
        }
        return nil
    }
}
#endif
