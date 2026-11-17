#if os(Linux)
/// Main-loop state for the application menu drawn inside each SDL window.
final class LinuxApplicationMenu<State> {
    private let shared: AppShared<State>
    private let applicationTitle: String
    let fitsContentHeight: Bool
    private var snapshot: DesktopMenuSnapshot?
    private(set) var activeSection: Int?
    private(set) var activeItem: Int?
    weak var runtime: Runtime<State>?

    private var returnFocusKey: String?
    private var returnFocusPath: String?
    private var needsFocusUpdate = false
    private var followsPointer = true

    init(shared: AppShared<State>, title: String, fitsContentHeight: Bool = false) {
        self.shared = shared
        self.applicationTitle = title
        self.fitsContentHeight = fitsContentHeight
    }

    var sections: [DesktopMenuSection] { snapshot?.sections ?? [] }
    var revision: UInt64 { snapshot?.revision ?? 0 }

    func refresh() {
        guard let update = AppMenuBridge.desktopSnapshot(for: shared, applicationTitle: applicationTitle,
                                                         after: snapshot?.revision) else { return }
        let oldSection = activeSection.map { sections[$0] }
        let oldItem = activeItem.flatMap { oldSection?.items[$0].id }
        snapshot = update
        if let oldSection {
            if let section = sections.firstIndex(where: { $0.title == oldSection.title }) {
                select(section: section)
                if let oldItem, let index = selectableItems.first(where: { sections[section].items[$0].id == oldItem }) {
                    activeItem = index
                }
            } else {
                dismiss()
            }
        }
        runtime?.markNeedsCommit()
    }

    /// Save the app's keyboard target before a pointer press focuses the menu trigger.
    func rememberFocus() {
        guard activeSection == nil else { return }
        if let key = runtime?.focusedKey, sections.indices.contains(where: { Self.sectionKey($0) == key }) { return }
        returnFocusKey = runtime?.focusedKey
        returnFocusPath = runtime?.focusedPath
    }

    private var selectableItems: [Int] {
        guard let section = activeSection else { return [] }
        let items = sections[section].items
        return items.indices.filter { items[$0].enabled && !items[$0].isSeparator }
    }

    private func selectionChanged() {
        needsFocusUpdate = true
        runtime?.markNeedsCommit()
    }

    private func select(section: Int) {
        activeSection = section
        activeItem = selectableItems.first
        selectionChanged()
    }

    func toggle(section: Int) {
        guard sections.indices.contains(section) else { return }
        if activeSection == section {
            dismiss()
        } else {
            rememberFocus()
            select(section: section)
        }
    }

    func hover(section: Int) {
        guard followsPointer, activeSection != nil, activeSection != section, sections.indices.contains(section) else { return }
        select(section: section)
    }

    func hover(item: Int) {
        guard followsPointer else { return }
        select(item: item)
    }

    // Layout can place a new menu row underneath a stationary pointer. Keep
    // the keyboard selection until the user actually moves the pointer.
    func pointerMoved() {
        followsPointer = true
    }

    private func select(item: Int) {
        guard activeItem != item, selectableItems.contains(item) else { return }
        activeItem = item
        selectionChanged()
    }

    func dismiss() {
        guard activeSection != nil else { return }
        activeSection = nil
        activeItem = nil
        selectionChanged()
    }

    func applyFocus(at time: Double) {
        guard needsFocusUpdate, let runtime else { return }
        needsFocusUpdate = false
        let section = activeSection
        let row = section.flatMap { s in activeItem.map { Self.itemKey(sections[s].items[$0].id) } }
        let target = row ?? section.map(Self.sectionKey) ?? returnFocusKey
        // An app can focus an unnamed control. Its runtime path still identifies
        // that control when the popup closes and its subtree stays mounted.
        if section == nil, target == nil, let path = returnFocusPath,
           let index = runtime.a11yTargetIndex(path), runtime.canFocusIndex(index), runtime.a11yAllowed(index) {
            runtime.setFocus(path: path, keyboard: true, at: time)
            return
        }
        runtime.update(at: time) { _, tx in
            if let target {
                if let section {
                    tx.focusWhenShown(target, ring: true)
                    tx.scrollIntoViewIn(Self.barKey, Self.sectionKey(section))
                    if let row { tx.scrollIntoViewIn(Self.listKey(section), row) }
                } else {
                    tx.focus(target)
                }
            } else {
                tx.blur()
            }
        }
    }

    func activate(section: Int, item: Int, revision expected: UInt64) {
        guard expected == revision, sections.indices.contains(section),
              sections[section].items.indices.contains(item) else { return }
        let entry = sections[section].items[item]
        guard entry.enabled, !entry.isSeparator else { return }
        dismiss()
        _ = AppMenuBridge.fireIfCurrent(id: entry.id, revision: expected, for: shared)
    }

    func matching(_ event: KeyEvent) -> DesktopMenuEntry? {
        snapshot?.matching(event, on: .linux)
    }

    @discardableResult
    func fire(_ entry: DesktopMenuEntry, revision expected: UInt64) -> Bool {
        let accepted = AppMenuBridge.fireIfCurrent(id: entry.id, revision: expected, for: shared)
        if accepted { dismiss() }
        return accepted
    }

    /// F10 or Alt plus a section's initial opens the menu. Once open, keyboard
    /// navigation stays in the menu until an item fires or the user dismisses it.
    func navigate(_ event: KeyEvent) -> Bool {
        guard !sections.isEmpty else { return false }
        if event.key == .f(10), event.mods == .none {
            followsPointer = false
            if activeSection == nil { toggle(section: 0) } else { dismiss() }
            return true
        }
        if event.mods.alt && !event.mods.ctrl && !event.mods.logo,
           case let .text(letter) = event.key, letter.count == 1,
           let section = sections.firstIndex(where: { $0.title.lowercased().hasPrefix(letter.lowercased()) }) {
            followsPointer = false
            if activeSection != section { toggle(section: section) }
            return true
        }
        guard let section = activeSection, !event.mods.ctrl, !event.mods.logo, !event.mods.alt else { return false }
        followsPointer = false
        let items = selectableItems
        switch event.key {
        case .arrowLeft, .arrowRight:
            let step = event.key == .arrowLeft ? -1 : 1
            select(section: (section + step + sections.count) % sections.count)
        case .arrowUp, .arrowDown:
            guard !items.isEmpty else { return true }
            let step = event.key == .arrowUp ? -1 : 1
            let index = activeItem.flatMap { items.firstIndex(of: $0) } ?? (step > 0 ? -1 : 0)
            select(item: items[(index + step + items.count) % items.count])
        case .home:
            if let first = items.first { select(item: first) }
        case .end:
            if let last = items.last { select(item: last) }
        case .enter, .space:
            if let activeItem { activate(section: section, item: activeItem, revision: revision) }
        case .escape, .tab:
            dismiss()
        case .text(let letter) where letter.count == 1:
            let start = activeItem.flatMap { items.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            for i in items.indices {
                let index = items[(start + i) % items.count]
                if sections[section].items[index].title.lowercased().hasPrefix(letter.lowercased()) {
                    select(item: index)
                    break
                }
            }
        default: return false
        }
        return true
    }
}
#endif
