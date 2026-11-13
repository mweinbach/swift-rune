import Foundation
import Rune

/// One selectable item in a `Combobox` (`rune_kit::combobox::ComboboxOption`).
public struct ComboboxItem: Sendable, Equatable, Hashable {
    public var id: String
    public var label: String
    public var detail: String
    public var disabled: Bool

    public init(id: String, label: String, detail: String = "", disabled: Bool = false) {
        self.id = id
        self.label = label
        self.detail = detail
        self.disabled = disabled
    }

    public init(_ opt: ComboboxOption<String>, disabled: Bool = false) {
        self.id = opt.id
        self.label = opt.label
        self.detail = opt.detail ?? ""
        self.disabled = disabled
    }
}

/// Phase of a `ComboboxState` machine (`rune_kit::combobox::ComboboxPhase`).
public enum ComboboxPhase: Sendable, Equatable {
    case closed
    /// `highlight`: the row id chosen by keys or pointer; `nil` selects the query's first enabled row.
    case open(highlight: String?)
}

/// Input event processed by `ComboboxState.step(_:)` (`rune_kit::combobox::ComboboxEvent`).
public enum ComboboxEvent: Sendable, Equatable {
    case toggle(current: String?)
    case close
    case edited
    case highlight(id: String, reveal: Bool)
}

/// Side effect emitted by `ComboboxState.step(_:)` (`rune_kit::combobox::ComboboxEffect`).
public enum ComboboxEffect: Sendable, Equatable {
    case reveal(String)
}

/// Combobox open/highlight/search state machine (`rune_kit::combobox::ComboboxState`).
public struct ComboboxState: Sendable, Equatable {
    public var search: TextEdit
    public private(set) var phase: ComboboxPhase
    public var trackedScrollY: Float = 0.0

    public init(search: TextEdit = TextEdit(), phase: ComboboxPhase = .closed) {
        self.search = search
        self.phase = phase
    }

    public var isOpen: Bool {
        if case .open = phase { return true }
        return false
    }

    public var active: String? {
        if case .open(let highlight) = phase { return highlight }
        return nil
    }

    public mutating func close() {
        _ = step(.close)
    }

    @discardableResult
    public mutating func step(_ event: ComboboxEvent) -> [ComboboxEffect] {
        switch (phase, event) {
        case (.closed, .toggle(let current)):
            search.clear()
            search.preedit = nil
            phase = .open(highlight: current)
            trackedScrollY = 0.0
            if let current {
                return [.reveal(current)]
            }
            return []

        case (.open, .toggle), (.open, .close):
            phase = .closed
            search.cancelPreedit()
            return []

        case (.open, .edited):
            phase = .open(highlight: nil)
            trackedScrollY = 0.0
            return []

        case (.open, .highlight(let id, let reveal)):
            phase = .open(highlight: id)
            return reveal ? [.reveal(id)] : []

        case (.closed, _):
            return []
        }
    }

    /// Returns the index into `options` of the currently highlighted enabled row (or first enabled filtered row).
    public func activeIndex(in options: [ComboboxItem], filtered: [Int]) -> Int? {
        if let activeID = active,
           let match = filtered.first(where: { !options[$0].disabled && options[$0].id == activeID }) {
            return match
        }
        return filtered.first(where: { !options[$0].disabled })
    }

    /// Case-insensitive subsequence match score; contiguous runs and word boundaries rank highest.
    public static func score(query: String, value: String) -> Int? {
        let needle = Array(query)
        var n = 0
        var total = 0
        var previous = false
        var boundary = true

        for ch in value.lowercased() {
            if n < needle.count && ch == needle[n] {
                total += 10 + (previous ? 12 : 0) + (boundary ? 8 : 0)
                previous = true
                n += 1
            } else {
                previous = false
                total -= 1
            }
            boundary = !ch.isLetter && !ch.isNumber
        }
        return n == needle.count ? total : nil
    }

    /// Returns indices into `options` matching `query`, sorted by descending score then original order.
    public static func filtered(_ options: [ComboboxItem], query: String) -> [Int] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Array(options.indices) }
        var matches: [(index: Int, score: Int)] = []
        for (i, opt) in options.enumerated() {
            let labelScore = score(query: q, value: opt.label)
            let detailScore = opt.detail.isEmpty ? nil : score(query: q, value: opt.detail)
            if let best = [labelScore, detailScore].compactMap({ $0 }).max() {
                matches.append((i, best))
            }
        }
        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }
        return matches.map(\.index)
    }
}

/// Searchable select with Popover + borderless TextInput + virtualised `PopupList`
/// (`rune_kit::combobox::Combobox`).
public struct Combobox<State> {
    private let key: String
    private let get: (State) -> ComboboxState
    private let update: (inout State, (inout ComboboxState) -> Void) -> Void
    private let searchKeyPath: WritableKeyPath<State, TextEdit>
    private let options: [ComboboxItem]
    private var chooseHandler: ((inout State, String, inout Tx) -> Void)?
    private var currentID: String?
    private var placeholderText: String = ""
    private var searchPlaceholderText: String = "Search"
    private var emptyText: String = "No results"
    private var widthValue: Float = 280.0
    private var maxHeightValue: Float = 192.0
    private var placementValue: Placement = .bottomStart
    private var triggerOverride: El<State>?
    private var isDisabled: Bool = false
    private var shouldAnimateFiltering: Bool = false
    private var a11yLabel: String?

    public init(
        _ key: String,
        state keyPath: WritableKeyPath<State, ComboboxState>,
        options: [ComboboxItem]
    ) {
        self.key = key
        self.get = { $0[keyPath: keyPath] }
        self.update = { s, body in body(&s[keyPath: keyPath]) }
        self.searchKeyPath = keyPath.appending(path: \.search)
        self.options = options
    }

    public func label(_ text: String) -> Combobox<State> {
        var copy = self
        copy.a11yLabel = text
        return copy
    }

    public func current(_ id: String?) -> Combobox<State> {
        var copy = self
        copy.currentID = id
        return copy
    }

    public func placeholder(_ text: String) -> Combobox<State> {
        var copy = self
        copy.placeholderText = text
        return copy
    }

    public func searchPlaceholder(_ text: String) -> Combobox<State> {
        var copy = self
        copy.searchPlaceholderText = text
        return copy
    }

    public func emptyMessage(_ text: String) -> Combobox<State> {
        var copy = self
        copy.emptyText = text
        return copy
    }

    public func width(_ w: Float) -> Combobox<State> {
        var copy = self
        copy.widthValue = w
        return copy
    }

    public func maxHeight(_ h: Float) -> Combobox<State> {
        var copy = self
        copy.maxHeightValue = h
        return copy
    }

    public func placement(_ p: Placement) -> Combobox<State> {
        var copy = self
        copy.placementValue = p
        return copy
    }

    public func trigger(_ el: El<State>) -> Combobox<State> {
        var copy = self
        copy.triggerOverride = el
        return copy
    }

    public func disabled(_ on: Bool = true) -> Combobox<State> {
        var copy = self
        copy.isDisabled = on
        return copy
    }

    public func animateFiltering(_ on: Bool = true) -> Combobox<State> {
        var copy = self
        copy.shouldAnimateFiltering = on
        return copy
    }

    public func onChoose(_ f: @escaping (inout State, String, inout Tx) -> Void) -> Combobox<State> {
        var copy = self
        copy.chooseHandler = f
        return copy
    }

    public func build(kit k: Kit, layer: inout [El<State>], cx: Cx<State>? = nil) -> El<State> {
        let state = get(cx_placeholder: nil)
        return buildInternal(stateValue: state, kit: k, layer: &layer, cx: cx)
    }

    public func build(_ s: State, kit k: Kit, layer: inout [El<State>], cx: Cx<State>? = nil) -> El<State> {
        buildInternal(stateValue: get(s), kit: k, layer: &layer, cx: cx)
    }

    private func get(cx_placeholder _: Void?) -> ComboboxState { ComboboxState() }

    private func buildInternal(
        stateValue comboState: ComboboxState,
        kit k: Kit,
        layer: inout [El<State>],
        cx: Cx<State>?
    ) -> El<State> {
        let selectedOpt = options.first { $0.id == currentID }
        let name = a11yLabel ?? placeholderText
        let defaultTriggerKey = "\(key)-value-trigger"
        let triggerKey = triggerOverride?.keyId ?? defaultTriggerKey
        let searchKey = "\(key)-search"
        let viewportKey = "\(key)-viewport"
        let open = comboState.isOpen && !isDisabled
        let maxH = maxHeightValue
        let upd = update
        let opts = options
        let curID = currentID

        func scrollToOption(state st: inout ComboboxState, id: String, choices: [Int], tx: inout Tx) {
            guard let pos = choices.firstIndex(where: { opts[$0].id == id }) else { return }
            let rh = PopupList<State>.rowHeight
            let vpH = min(Float(choices.count) * rh, maxH)
            let rowTop = Float(pos) * rh
            let rowBot = rowTop + rh
            if rowTop < st.trackedScrollY {
                st.trackedScrollY = rowTop
            } else if rowBot > st.trackedScrollY + vpH {
                st.trackedScrollY = max(0, rowBot - vpH)
            }
            tx.scrollTo(viewportKey, offset: Vec2(0, st.trackedScrollY), animated: false)
        }

        var triggerEl: El<State>
        if let custom = triggerOverride {
            triggerEl = custom
        } else {
            triggerEl = Select<State>(key + "-value", options: [])
                .current(selectedOpt?.label)
                .placeholder(placeholderText)
                .label(name)
                .appearance(.field)
                .width(widthValue)
                .open(open)
                .disabled(isDisabled)
                .trigger(kit: k)
                .key(defaultTriggerKey)
        }

        if !isDisabled {
            func toggleFromTrigger(_ s: inout State, _ tx: inout Tx) {
                var wasOpen = false
                upd(&s) { st in
                    wasOpen = st.isOpen
                    let effects = st.step(.toggle(current: curID))
                    let choices = ComboboxState.filtered(opts, query: st.search.text)
                    for eff in effects {
                        if case .reveal(let id) = eff {
                            scrollToOption(state: &st, id: id, choices: choices, tx: &tx)
                        }
                    }
                }
                if wasOpen {
                    tx.focus(triggerKey)
                } else {
                    tx.focus(searchKey)
                }
            }

            triggerEl = triggerEl
                .onClick { s, tx in
                    toggleFromTrigger(&s, &tx)
                }
                .onKey { s, ev, tx in
                    switch ev.key {
                    case .enter, .space, .arrowDown, .arrowUp:
                        toggleFromTrigger(&s, &tx)
                        return true
                    case .text(" "):
                        toggleFromTrigger(&s, &tx)
                        return true
                    default:
                        return false
                    }
                }
        }

        var popover = Popover<State>(key)
            .trigger(triggerEl)
            .label(name)
            .placement(placementValue)
            .padding(0.0)
            .open(open)
            .onCloseTx { s, tx in
                upd(&s) { $0.close() }
                tx.focus(triggerKey)
            }

        guard open else {
            return popover.build(kit: k, layer: &layer, cx: cx)
        }

        let choices = ComboboxState.filtered(options, query: comboState.search.text)
        let active = comboState.activeIndex(in: options, filtered: choices)
        let activePos = active.flatMap { orig in choices.firstIndex(of: orig) }
        let page = max(1, Int(floor(maxHeightValue / PopupList<State>.rowHeight)) - 1)
        let chooseCb = chooseHandler
        let searchLabel = name.isEmpty ? "Search" : "Search \(name)"

        var field = Rune.textInput(key: searchKey, searchKeyPath)
            .label(searchLabel)
            .font(k.ty.uiCompact)
            .color(k.c.textBase)
            .placeholder(searchPlaceholderText, color: k.c.textFaint)
            .caret(k.c.bgAccent, selection: k.alpha(k.c.textAccent, 0.30))
            .grow(1.0)
            .shrink(1.0)
            .h(36.0)
            .px(8.0)
            .autofocus(true)

        field = field
            .onChange { s, _, tx in
                upd(&s) { st in
                    st.step(.edited)
                    let updated = ComboboxState.filtered(opts, query: st.search.text)
                    if let firstEnabled = updated.first(where: { !opts[$0].disabled }) {
                        scrollToOption(state: &st, id: opts[firstEnabled].id, choices: updated, tx: &tx)
                    } else {
                        st.trackedScrollY = 0
                        tx.scrollTo(viewportKey, offset: .zero, animated: false)
                    }
                }
            }
            .onKey { s, ev, tx in
                var currentCombo = ComboboxState()
                upd(&s) { currentCombo = $0 }
                if currentCombo.search.preedit != nil {
                    return false
                }
                if ev.key == .escape {
                    upd(&s) { $0.close() }
                    tx.focus(triggerKey)
                    return true
                }
                if ev.mods.alt || ev.mods.logo {
                    return false
                }
                let currentChoices = ComboboxState.filtered(opts, query: currentCombo.search.text)
                let enabled = currentChoices.filter { !opts[$0].disabled }
                let act = currentCombo.activeIndex(in: opts, filtered: enabled)

                if ev.key == .enter {
                    let chosenID = act.map { opts[$0].id }
                    upd(&s) { $0.close() }
                    tx.focus(triggerKey)
                    if let chosenID {
                        chooseCb?(&s, chosenID, &tx)
                    }
                    return true
                }

                let control = ev.mods.ctrl && !ev.mods.shift
                let jump: Int?
                if !ev.mods.cmd && !ev.mods.ctrl && !ev.mods.shift {
                    switch ev.key {
                    case .pageDown: jump = page
                    case .pageUp: jump = -page
                    case .end where currentCombo.search.text.isEmpty: jump = Int.max / 2
                    case .home where currentCombo.search.text.isEmpty: jump = Int.min / 2
                    default: jump = nil
                    }
                } else {
                    jump = nil
                }

                if let jump {
                    if !enabled.isEmpty {
                        let idx = act.flatMap { enabled.firstIndex(of: $0) } ?? 0
                        let clampedNext = min(max(0, idx + jump), enabled.count - 1)
                        let nextID = opts[enabled[clampedNext]].id
                        upd(&s) { st in
                            let effects = st.step(.highlight(id: nextID, reveal: true))
                            for eff in effects {
                                if case .reveal(let id) = eff {
                                    scrollToOption(state: &st, id: id, choices: currentChoices, tx: &tx)
                                }
                            }
                        }
                    }
                    return true
                }

                let delta: Int?
                switch ev.key {
                case .arrowDown where !ev.mods.cmd && !ev.mods.ctrl:
                    delta = 1
                case .arrowUp where !ev.mods.cmd && !ev.mods.ctrl:
                    delta = -1
                case .text("n") where control, .command("n") where control:
                    delta = 1
                case .text("p") where control, .command("p") where control:
                    delta = -1
                default:
                    delta = nil
                }
                guard let delta else { return false }

                if !enabled.isEmpty {
                    let idx = act.flatMap { enabled.firstIndex(of: $0) } ?? 0
                    let count = enabled.count
                    let nextIdx = ((idx + delta) % count + count) % count
                    let nextID = opts[enabled[nextIdx]].id
                    upd(&s) { st in
                        let effects = st.step(.highlight(id: nextID, reveal: true))
                        for eff in effects {
                            if case .reveal(let id) = eff {
                                scrollToOption(state: &st, id: id, choices: currentChoices, tx: &tx)
                            }
                        }
                    }
                }
                return true
            }

        let items: [PopupItem<State>] = choices.map { i in
            let opt = options[i]
            let isCur = currentID == opt.id
            let checkIcon: El<State> = icon(KitIcons.checkSmall, size: 14.0)
                .color(k.c.iconBase)
                .opacity(isCur ? 1.0 : 0.0)
            return PopupItem<State>(opt.id, opt.label)
                .description(opt.detail)
                .disabled(opt.disabled)
                .trailing(checkIcon)
        }

        let list = PopupList<State>(key, anchor: "")
            .label(name)
            .maxHeight(maxHeightValue)
            .items(items)
            .active(activePos)
            .scrollOffset(comboState.trackedScrollY)
            .emptyMessage(emptyText)
            .onActive { s, i in
                guard i < choices.count else { return }
                let id = opts[choices[i]].id
                upd(&s) { _ = $0.step(.highlight(id: id, reveal: false)) }
            }
            .onChoose { s, id, tx in
                upd(&s) { $0.close() }
                tx.focus(triggerKey)
                chooseCb?(&s, id, &tx)
            }
            .buildList(kit: k, cx: cx)

        let dividerColor = k.c.borderWeak.a > 0 ? k.c.borderWeak : k.c.borderMuted
        let searchHeader: El<State> = row()
            .key("header")
            .wFull()
            .px(8.0)
            .gap(6.0)
            .itemsCenter()
            .child(icon(KitIcons.search, size: 14.0).color(k.c.iconMuted))
            .child(field)

        let results: El<State> = col()
            .key("results")
            .wFull()
            .p(4.0)
            .shrink(1.0)
            .minH(0.0)
            .child(list)

        let body: El<State> = col()
            .w(widthValue)
            .shrink(1.0)
            .minH(0.0)
            .child(searchHeader)
            .child(el().key("divider").wFull().h(1.0).bg(dividerColor))
            .child(results)

        popover = popover.child(body)
        return popover.build(kit: k, layer: &layer, cx: cx)
    }
}
