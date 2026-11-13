import Foundation
import Rune
import RuneMotion

/// An action button rendered by `RuneKnobs.actions`.
public struct KnobAction<State> {
    public var cap: String
    public var label: String
    public var run: (inout State, inout Tx) -> Void

    public init(cap: String, label: String, run: @escaping (inout State, inout Tx) -> Void) {
        self.cap = cap
        self.label = label
        self.run = run
    }
}

private enum PanelTypography {
    static let label = TextStyle(size: 12.0, weight: 450.0).lh(16.0)
    static let value = TextStyle(size: 11.5, weight: 450.0).lh(16.0)
    static let title = TextStyle(size: 13.0, weight: 600.0).lh(18.0).letterSpacing(-0.13)
    static let chip = TextStyle(size: 12.0, weight: 500.0).lh(16.0)
    static let chipOn = TextStyle(size: 12.0, weight: 600.0).lh(16.0)
    static let caption = TextStyle(size: 11.0, weight: 500.0).lh(14.0)
    static let digit = TextStyle(size: 8.5, weight: 600.0).lh(10.0)
    static let measurer = TextSystem()

    static func textWidth(_ text: String, style: TextStyle) -> Float {
        measurer.measure(text, style: style, maxWidth: nil, pixelScale: 1.0).x
    }
}

/// Responsive layout mode for a choice knob at a card width (`rows.rs:247`).
public enum ChoiceShape: Equatable, Sendable {
    case inline
    case grid(cols: Int)
    case long(cols: Int)
}

public extension RuneKnobs {
    /// Compute choice row layout shape for a knob and card width (`rows.rs:269`).
    static func choiceShape(_ knob: Knob, cardWidth: Float, showSettledDot: Bool = false) -> ChoiceShape {
        let pad: Float = 10
        let optPad: Float = 7
        let optGap: Float = 2
        let well: Float = 2
        let longThreshold = 10
        let n = knob.labels.count
        guard n > 0 else { return .inline }
        let dotW: Float = showSettledDot ? 9 : 0
        let inlineOptions = knob.labels.reduce(Float(0)) { acc, l in
            acc + PanelTypography.textWidth(l, style: PanelTypography.chipOn) + 2 * optPad
        }
        let inlineNeed = inlineOptions + optGap * Float(max(0, n - 1)) + 2 * well + dotW
        let labelNeed = PanelTypography.textWidth(knob.title, style: PanelTypography.label) + 2 * pad + 16
        if inlineNeed + labelNeed <= cardWidth {
            return .inline
        }
        let cellW = (knob.labels.map { PanelTypography.textWidth($0, style: PanelTypography.chipOn) }.max() ?? 24)
            + 2 * optPad + dotW
        let room = max(40, cardWidth - 2 * (pad - 6))
        let fit = max(1, min(n, Int(floor((room - 2 * well + optGap) / (cellW + optGap)))))
        let rows = (n + fit - 1) / fit
        let cols = (n + max(1, rows) - 1) / max(1, rows)
        return n > longThreshold ? .long(cols: cols) : .grid(cols: cols)
    }
    /// Floating overlay knobs panel (`rune_knobs::layer`). Returns an empty element when `knobs.open == false`.
    static func layer<State>(
        knobs: Knobs,
        groups: [KnobGroup],
        style: KnobStyle = .dark(),
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        guard knobs.open else {
            return El<State>(direction: .row).key("knobs-layer")
        }

        let current = knobs.current(in: groups)
        let card: El<State> = col()
            .key("knobs-floating-panel")
            .w(300)
            .bg(style.bg)
            .border(1, style.border)
            .rounded(12)
            .p(10)
            .gap(8)
            .shadows([Shadow(x: 0, y: 12, blur: 32, spread: 0, color: style.shadow)])
            .onKey { state, ev, tx in
                if RuneKnobs.key(&state[keyPath: keyPath], event: ev) {
                    tx.instant()
                    return true
                }
                if state[keyPath: keyPath].panelKey(groups: groups, event: ev) {
                    tx.instant()
                    return true
                }
                return false
            }
            .child(headerBar(knobs: knobs, groups: groups, current: current, style: style, keyPath: keyPath))
            .child(groupTabs(knobs: knobs, groups: groups, current: current, style: style, keyPath: keyPath))

        var body = card
        if let group = current {
            let gi = groups.firstIndex(where: { $0.name == group.name }) ?? 0
            body = body
                .child(presetTray(knobs: knobs, group: group, style: style, keyPath: keyPath))
                .child(knobCard(
                    knobs: knobs,
                    group: group,
                    groupIndex: gi,
                    knobIndices: Array(0..<group.knobs.count),
                    markedIndex: knobs.kbd ? knobs.cursor : nil,
                    cardWidth: 280,
                    style: style,
                    keyPath: keyPath
                ))
            if let hotName = knobs.hot,
               let hotKnob = group.knobs.first(where: { $0.name == hotName }),
               !hotKnob.describe.isEmpty {
                body = body.child(
                    text(hotKnob.describe)
                        .font(PanelTypography.caption)
                        .color(style.fg3)
                        .px(4)
                )
            }
        } else if knobs.picking {
            body = body.child(
                row()
                    .wFull()
                    .p(12)
                    .rounded(8)
                    .bg(style.inset)
                    .center()
                    .child(text("Click a region in the window to inspect its knobs").font(PanelTypography.label).color(style.fg2))
            )
        }

        var root = El<State>(direction: .row)
            .key("knobs-layer")
            .absolute(x: 0, y: 0)
            .wFull()
            .hFull()
            .child(body.absolute(x: 16, y: 16))
        root = appendOverlayChildren(
            to: root,
            knobs: knobs,
            groups: groups,
            style: style,
            keyPath: keyPath,
            containerKey: "knobs-layer"
        )
        return root
    }

    private static func regionAt(_ rects: [(String, [Float])], x: Float, y: Float) -> String? {
        rects
            .filter { _, r in x >= r[0] && x < r[0] + r[2] && y >= r[1] && y < r[1] + r[3] }
            .min { ($0.1[2] * $0.1[3]) < ($1.1[2] * $1.1[3]) }?
            .0
    }

    private static func appendOverlayChildren<State>(
        to container: El<State>,
        knobs: Knobs,
        groups: [KnobGroup],
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>,
        containerKey: String
    ) -> El<State> {
        guard knobs.open else { return container }
        var out = container
        let origin = windowLayout(containerKey).map { ($0[0], $0[1]) } ?? (Float(0), Float(0))
        let rects: [(String, [Float])] = groups.compactMap { g in
            guard !g.region.isEmpty, let r = windowLayout(g.region) else { return nil }
            return (g.name, r)
        }
        if knobs.picking {
            out = out.child(
                el()
                    .key("knobs-pick")
                    .absolute(x: 0, y: 0)
                    .wFull()
                    .hFull()
                    .onPointerMove { state, press, tx in
                        tx.instant()
                        let hit = regionAt(rects, x: press.window.x, y: press.window.y)
                        if state[keyPath: keyPath].hoverGroup != hit {
                            state[keyPath: keyPath].hoverGroup = hit
                        }
                    }
                    .onHover { state, inside, tx in
                        if !inside {
                            tx.instant()
                            state[keyPath: keyPath].hoverGroup = nil
                        }
                    }
                    .onClick { state, tx in
                        tx.instant()
                        if let hovered = state[keyPath: keyPath].hoverGroup {
                            state[keyPath: keyPath].pick(hovered)
                        }
                    }
            )
        }
        if let outlined = knobs.hoverGroup,
           let (name, r) = rects.first(where: { $0.0 == outlined }) {
            var outline: El<State> = el()
                .key("knobs-outline")
                .absolute(x: r[0] - origin.0, y: r[1] - origin.1)
                .w(r[2])
                .h(r[3])
                .rounded(6)
                .border(1, style.outline)
                .inert(true)
            if knobs.picking {
                outline = outline.child(
                    row()
                        .key("knobs-tag")
                        .absolute(x: 6, y: 6)
                        .h(20)
                        .px(7)
                        .center()
                        .rounded(5)
                        .bg(style.bg)
                        .child(text(name).font(PanelTypography.caption).color(style.fg))
                )
            }
            out = out.child(outline)
        }
        return out
    }

    /// Right-hand side panel wrapping `page` (`rune_knobs::side`).
    static func side<State>(
        page: El<State>,
        knobs: Knobs,
        groups: [KnobGroup],
        style: KnobStyle = .dark(),
        seen: Set<Int> = [],
        keyPath: WritableKeyPath<State, Knobs>,
        filterEditKeyPath: WritableKeyPath<State, TextEdit>? = nil
    ) -> El<State> {
        let w = knobs.sideW()
        let slide = knobs.slide()
        var pageBox: El<State> = col()
            .key("knobs-page")
            .grow(1)
            .shrink(1)
            .minW(0)
            .hFull()
            .minH(0)
            .child(page)
        if knobs.open {
            var over: El<State> = el().key("knobs-over").absolute(x: 0, y: 0).wFull().hFull()
            over = appendOverlayChildren(
                to: over,
                knobs: knobs,
                groups: groups,
                style: style,
                keyPath: keyPath,
                containerKey: "knobs-over"
            )
            pageBox = pageBox.child(over)
        }

        var sideBox: El<State> = el()
            .key("knobs-side")
            .w(knobs.open ? w : 0)
            .hFull()
            .clip(true)
            .motion(slide)

        if knobs.open {
            let sidePanel = sidePanelContent(
                knobs: knobs,
                groups: groups,
                style: style,
                seen: seen,
                keyPath: keyPath,
                filterEditKeyPath: filterEditKeyPath
            )
            let edge: El<State> = el()
                .key("knobs-edge")
                .absolute(x: 0, y: 0)
                .w(6)
                .hFull()
                .cursor(.resizeColumn)
                .onDragStart { state, tx in
                    tx.instant()
                    state[keyPath: keyPath].resizeStartWidth = state[keyPath: keyPath].sideW()
                }
                .onDrag { state, drag, tx in
                    tx.instant()
                    let base = state[keyPath: keyPath].resizeStartWidth > 0
                        ? state[keyPath: keyPath].resizeStartWidth
                        : state[keyPath: keyPath].sideW()
                    let resized = (base - drag.delta.x)
                        .clamped(to: RuneKnobsDefaults.sideMin...RuneKnobsDefaults.sideMax)
                        .rounded()
                    state[keyPath: keyPath].width = resized
                }
                .onDragEnd { state, cancelled, tx in
                    tx.instant()
                    if cancelled {
                        state[keyPath: keyPath].width = state[keyPath: keyPath].resizeStartWidth
                    }
                    state[keyPath: keyPath].resizeStartWidth = 0
                }
                .onDoubleClick { state, tx in
                    tx.instant()
                    state[keyPath: keyPath].width = 0
                }
            sideBox = sideBox.child(sidePanel).child(edge)
        }

        return El<State>(direction: .row)
            .key("knobs-side-shell")
            .wFull()
            .hFull()
            .minH(0)
            .child(pageBox)
            .child(sideBox)
    }

    /// Inline panel suitable for embedding inside a playground column (`rune_knobs::inline`).
    static func inline<State>(
        knobs: Knobs,
        groups: [KnobGroup],
        style: KnobStyle = .dark(),
        showHeader: Bool = true,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        let current = knobs.current(in: groups)
        var root: El<State> = col()
            .key("knobs-panel")
            .wFull()
            .bg(style.bg)
            .border(1, style.border)
            .rounded(10)
            .p(10)
            .gap(8)
        if showHeader {
            root = root.child(headerBar(knobs: knobs, groups: groups, current: current, style: style, keyPath: keyPath))
        }
        if groups.count > 1 {
            root = root.child(groupTabs(knobs: knobs, groups: groups, current: current, style: style, keyPath: keyPath))
        }
        if let group = current {
            let gi = groups.firstIndex(where: { $0.name == group.name }) ?? 0
            root = root
                .child(presetTray(knobs: knobs, group: group, style: style, keyPath: keyPath))
                .child(knobCard(
                    knobs: knobs,
                    group: group,
                    groupIndex: gi,
                    knobIndices: Array(0..<group.knobs.count),
                    markedIndex: knobs.kbd ? knobs.cursor : nil,
                    cardWidth: 280,
                    style: style,
                    keyPath: keyPath
                ))
        }
        return root
    }

    /// Action pill bar (`rune_knobs::actions`).
    static func actions<State>(style: KnobStyle = .dark(), _ items: [KnobAction<State>]) -> El<State> {
        var bar: El<State> = row().key("knobs-actions").gap(6)
        for (idx, item) in items.enumerated() {
            bar = bar.child(
                El<State>(direction: .row)
                    .key("knobs-action-\(idx)")
                    .role(.button)
                    .px(8)
                    .py(4)
                    .gap(6)
                    .rounded(6)
                    .bg(style.fill)
                    .hover(style.fillHover)
                    .center()
                    .onClick { state, tx in item.run(&state, &tx) }
                    .child(text(item.cap).font(PanelTypography.caption).color(style.fg3))
                    .child(text(item.label).font(PanelTypography.chip).color(style.fg))
            )
        }
        return bar
    }

    // MARK: - Side Panel Builder

    private static func sidePanelContent<State>(
        knobs: Knobs,
        groups: [KnobGroup],
        style: KnobStyle,
        seen: Set<Int>,
        keyPath: WritableKeyPath<State, Knobs>,
        filterEditKeyPath: WritableKeyPath<State, TextEdit>?
    ) -> El<State> {
        let plan = KnobTree.plan(knobs: knobs, groups: groups, seen: seen)
        let w = knobs.sideW()

        let effectiveEditKP = filterEditKeyPath ?? keyPath.appending(path: \.edit)

        var panel: El<State> = col()
            .key("knobs-side-panel")
            .w(w)
            .shrink(0)
            .hFull()
            .minH(0)
            .bg(style.bg)
            .border(1, style.border)
            .p(10)
            .gap(8)
            .focusable(true)
            .onKey { state, ev, tx in
                if state[keyPath: keyPath].filtering {
                    state[keyPath: keyPath].filtering = false
                }
                let isToggleShortcut: Bool = {
                    switch ev.key {
                    case .command(let ch) where (ch == "k" || ch == "K") && ev.mods.shift:
                        return true
                    case .text(let s) where (s == "k" || s == "K") && ev.mods.primaryCommand && ev.mods.shift:
                        return true
                    default:
                        return false
                    }
                }()
                if isToggleShortcut {
                    state[keyPath: keyPath].toggle()
                    tx.instant()
                    return true
                }
                let wasFiltering = state[keyPath: keyPath].filtering
                if KnobTree.handleKey(&state[keyPath: keyPath], groups: groups, seen: seen, event: ev) {
                    if !wasFiltering && state[keyPath: keyPath].filtering {
                        if let customKP = filterEditKeyPath {
                            state[keyPath: customKP].setText(state[keyPath: keyPath].query)
                            state[keyPath: customKP].selectAll()
                        }
                        tx.focus("knobs-filter-input")
                        tx.instant()
                    } else {
                        tx.motion(state[keyPath: keyPath].foldSpring())
                    }
                    return true
                }
                return false
            }
            .onPointerMove { state, _, tx in
                if state[keyPath: keyPath].kbd && state[keyPath: keyPath].drag == nil {
                    state[keyPath: keyPath].kbd = false
                    tx.instant()
                }
            }

        panel = panel.child(
            sideFilterBar(
                knobs: knobs,
                groups: groups,
                plan: plan,
                style: style,
                keyPath: keyPath,
                effectiveEditKP: effectiveEditKP,
                customEditKP: filterEditKeyPath
            )
        )

        if !plan.tabs.isEmpty {
            panel = panel.child(sideTabsBar(plan: plan, style: style, keyPath: keyPath))
        }

        var scrollCol: El<State> = col()
            .key("knobs-scroll")
            .wFull()
            .grow(1)
            .minH(0)
            .gap(6)
            .scroll()

        let sectionEls = sideSections(
            knobs: knobs,
            groups: groups,
            plan: plan,
            cardWidth: max(120, w - 20),
            style: style,
            keyPath: keyPath
        )
        if sectionEls.isEmpty {
            scrollCol = scrollCol.child(
                text("Nothing matches")
                    .key("knobs-none")
                    .font(PanelTypography.chip)
                    .color(style.fg3)
                    .px(10)
            )
        } else {
            for secEl in sectionEls {
                scrollCol = scrollCol.child(secEl)
            }
        }

        return panel
            .child(scrollCol)
            .child(sideAboutFooter(knobs: knobs, groups: groups, style: style))
    }

    private static func sideFilterBar<State>(
        knobs: Knobs,
        groups: [KnobGroup],
        plan: KnobTreePlan,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>,
        effectiveEditKP: WritableKeyPath<State, TextEdit>,
        customEditKP: WritableKeyPath<State, TextEdit>?
    ) -> El<State> {
        let matchCount = plan.sections.reduce(0) { acc, s in
            acc + s.subs.reduce(0) { $0 + $1.knobs.count }
        }
        let countLabel = matchCount == 1 ? "1 knob" : "\(matchCount) knobs"

        if knobs.filtering {
            var r: El<State> = El<State>(direction: .row)
                .key("knobs-filter-row")
                .wFull()
                .h(28)
                .px(8)
                .gap(8)
                .rounded(6)
                .bg(style.inset)
                .border(1, style.outline)
                .center()
                .child(
                    el()
                        .key("knobs-filter-field")
                        .grow(1)
                        .minW(0)
                        .hFull()
                        .center()
                        .focusReturn("knobs-side-panel")
                        .child(
                            textInput(key: "knobs-filter-input", effectiveEditKP)
                                .wFull()
                                .font(PanelTypography.label)
                                .color(style.fg)
                                .onInputKey { state, ev, tx in
                                    if KnobTree.filterKey(&state[keyPath: keyPath], groups: groups, plan: plan, event: ev) {
                                        tx.instant()
                                        return true
                                    }
                                    return false
                                }
                                .onChange { state, newText, tx in
                                    tx.instant()
                                    state[keyPath: keyPath].query = newText
                                    if customEditKP != nil {
                                        state[keyPath: keyPath].syncEdit()
                                    }
                                    state[keyPath: keyPath].kbd = true
                                    KnobTree.refilter(&state[keyPath: keyPath], groups: groups, before: plan)
                                }
                        )
                )
            if !knobs.query.isEmpty {
                r = r.child(text(countLabel).font(PanelTypography.value).color(style.fg3))
            }
            return r
        }
        var pill: El<State> = El<State>(direction: .row)
            .key("knobs-filter-pill")
            .wFull()
            .h(26)
            .px(8)
            .gap(8)
            .rounded(6)
            .bg(style.inset)
            .center()
            .onClick { state, tx in
                tx.instant()
                state[keyPath: keyPath].kbd = true
                state[keyPath: keyPath].startFilter()
                if let customKP = customEditKP {
                    state[keyPath: customKP].setText(state[keyPath: keyPath].query)
                    state[keyPath: customKP].selectAll()
                }
                tx.focus("knobs-filter-input")
            }
            .child(text(knobs.query.isEmpty ? "Press / to filter" : knobs.query).font(PanelTypography.label).color(knobs.query.isEmpty ? style.fg3 : style.fg))
            .child(spacer())
        if !knobs.query.isEmpty {
            pill = pill.child(text(countLabel).font(PanelTypography.value).color(style.fg3))
        }
        return pill
    }

    private static func sideTabsBar<State>(
        plan: KnobTreePlan,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        var tabRow: El<State> = row().key("knobs-side-tabs").wFull().gap(4).p(2).rounded(8).bg(style.inset)
        for (i, (tabName, isOnScreen)) in plan.tabs.enumerated() {
            let selected = plan.tab == tabName
            tabRow = tabRow.child(
                El<State>(direction: .row)
                    .key("knobs-side-tab-\(i)")
                    .role(.tab)
                    .grow(1)
                    .h(24)
                    .px(8)
                    .gap(4)
                    .rounded(6)
                    .bg(selected ? style.raised : .transparent)
                    .center()
                    .onClick { state, tx in
                        tx.settle()
                        state[keyPath: keyPath].tab = tabName
                    }
                    .child(text(tabName).font(selected ? PanelTypography.chipOn : PanelTypography.chip).color(selected ? style.fg : style.fg2))
                    .child(isOnScreen ? el().size(4, 4).rounded(2).bg(style.fg3) : el())
            )
        }
        return tabRow
    }

    private static func sideSections<State>(
        knobs: Knobs,
        groups: [KnobGroup],
        plan: KnobTreePlan,
        cardWidth: Float,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> [El<State>] {
        var out: [El<State>] = []
        for (si, sec) in plan.sections.enumerated() {
            switch sec.head {
            case .page(let pageName):
                out.append(
                    El<State>(direction: .row)
                        .key("knobs-sec-page-\(si)")
                        .role(.button)
                        .wFull()
                        .px(4)
                        .py(4)
                        .gap(6)
                        .onClick { state, tx in
                            tx.motion(state[keyPath: keyPath].foldSpring())
                            state[keyPath: keyPath].setFolded(pageName, sec.open)
                            state[keyPath: keyPath].treeAt = .page(pageName)
                            state[keyPath: keyPath].kbd = true
                        }
                        .child(text(sec.open ? "▾" : "▸").font(PanelTypography.caption).color(style.fg3))
                        .child(text(pageName).font(PanelTypography.title).color(style.fg))
                )
            case .caption(let cap):
                out.append(text(cap.uppercased()).font(PanelTypography.caption).color(style.fg3).px(4))
            case .bare:
                break
            }

            guard sec.open else { continue }
            for sub in sec.subs {
                out.append(
                    sideGroupSection(
                        knobs: knobs,
                        groups: groups,
                        sub: sub,
                        cardWidth: cardWidth,
                        style: style,
                        keyPath: keyPath
                    )
                )
            }
        }
        return out
    }

    private static func sideGroupSection<State>(
        knobs: Knobs,
        groups: [KnobGroup],
        sub: KnobTreeSub,
        cardWidth: Float,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        let g = groups[sub.groupIndex]
        let gi = sub.groupIndex
        let titleText = sub.full && !g.under.isEmpty ? "\(g.under) · \(g.name)" : g.name
        let hovered = knobs.hoverGroup == g.name
        let lit = hovered || knobs.group == g.name
        let mark: Int? = if knobs.kbd, case .knob(let atG, let atI) = knobs.treeAt, atG == gi { atI } else { nil }

        var header: El<State> = El<State>(direction: .row)
            .key("knobs-sub-head-\(gi)")
            .role(.button)
            .wFull()
            .h(28)
            .px(4)
            .gap(6)
            .center()
            .onHover { state, inside, tx in
                tx.instant()
                if inside {
                    state[keyPath: keyPath].hoverGroup = g.name
                } else if state[keyPath: keyPath].hoverGroup == g.name {
                    state[keyPath: keyPath].hoverGroup = nil
                }
            }
            .onClick { state, tx in
                tx.motion(state[keyPath: keyPath].foldSpring())
                state[keyPath: keyPath].setFolded(g.name, sub.open)
                state[keyPath: keyPath].treeAt = .group(gi)
                state[keyPath: keyPath].kbd = true
                if !sub.open {
                    state[keyPath: keyPath].group = g.name
                }
            }
            .onSecondaryClick { state, _, tx in
                tx.instant()
                state[keyPath: keyPath].reset(g)
            }
            .child(text(sub.open ? "▾" : "▸").font(PanelTypography.caption).color(style.fg3))
            .child(text(titleText).font(PanelTypography.chipOn).color(lit ? style.fg : style.fg2))
            .child(spacer())

        if hovered {
            header = header
                .child(
                    iconButton(
                        key: "knobs-sec-\(gi)-random",
                        svg: KnobIcons.random,
                        active: true,
                        style: style
                    ) { state, tx in
                        tx.instant()
                        state[keyPath: keyPath].random(g)
                    }
                )
                .child(
                    iconButton(
                        key: "knobs-sec-\(gi)-reset",
                        svg: KnobIcons.reset,
                        active: knobs.canReset(g),
                        style: style
                    ) { state, tx in
                        tx.instant()
                        state[keyPath: keyPath].reset(g)
                    }
                )
        } else {
            header = header.child(
                text("\(sub.knobs.count)")
                    .font(PanelTypography.value)
                    .color(sub.open ? style.fg3 : style.fg2)
            )
        }

        var body: El<State> = col()
            .key("knobs-sec-\(gi)-body")
            .wFull()
            .clip(true)
            .child(
                knobCard(
                    knobs: knobs,
                    group: g,
                    groupIndex: gi,
                    knobIndices: sub.knobs,
                    markedIndex: mark,
                    cardWidth: cardWidth,
                    style: style,
                    keyPath: keyPath
                )
            )
        if !sub.open {
            body = body.h(0)
        }

        return col()
            .key("knobs-sec-\(gi)")
            .wFull()
            .child(header)
            .child(body)
    }

    private static func describedKnob(knobs: Knobs, groups: [KnobGroup]) -> Knob? {
        if let hot = knobs.hot {
            for g in groups {
                if let match = g.knobs.first(where: { $0.name == hot }) {
                    return match
                }
            }
        }
        if knobs.kbd, case .knob(let gi, let ki) = knobs.treeAt,
           groups.indices.contains(gi), groups[gi].knobs.indices.contains(ki) {
            return groups[gi].knobs[ki]
        }
        return nil
    }

    private static func sideAboutFooter<State>(
        knobs: Knobs,
        groups: [KnobGroup],
        style: KnobStyle
    ) -> El<State> {
        var box: El<State> = col()
            .key("knobs-about")
            .wFull()
            .h(64)
            .px(4)
            .pt(6)
            .gap(2)

        guard let d = describedKnob(knobs: knobs, groups: groups) else {
            return box.child(
                text("↑↓ move   ←→ fold, open or change   1–9 pick   / filter")
                    .font(PanelTypography.caption)
                    .color(style.fg3)
            )
        }

        box = box.child(text(d.title).font(PanelTypography.title).color(style.fg2))
        if !d.describe.isEmpty {
            box = box.child(
                text(d.describe)
                    .key("knobs-about-line")
                    .font(PanelTypography.caption)
                    .color(style.fg3)
            )
        }
        let optIdx: Int? = if let ho = knobs.hotOpt, ho.0 == d.name {
            ho.1
        } else if !d.labels.isEmpty {
            Int(knobs.get(d).rounded())
        } else {
            nil
        }
        if let j = optIdx, d.labels.indices.contains(j) {
            let hint = d.hint(at: j)
            if !hint.isEmpty {
                box = box.child(
                    text("\(d.labels[j]): \(hint)")
                        .key("knobs-about-option")
                        .font(PanelTypography.caption)
                        .color(style.fg2)
                )
            }
        }
        return box
    }

    // MARK: - Header, Group Tabs, Presets, Knob Rows

    private static func headerBar<State>(
        knobs: Knobs,
        groups: [KnobGroup],
        current: KnobGroup?,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        let canUndo = knobs.canUndo
        let canReset = current.map { knobs.canReset($0) } ?? false

        var bar: El<State> = row()
            .key("knobs-header")
            .wFull()
            .h(26)
            .gap(4)
            .center()
            .child(text(current?.name ?? "Knobs").font(PanelTypography.title).color(style.fg))
            .child(spacer())

        if groups.count > 1 {
            bar = bar.child(iconButton(
                key: "knobs-btn-target",
                svg: KnobIcons.target,
                active: knobs.picking,
                style: style
            ) { state, tx in
                tx.settle()
                if state[keyPath: keyPath].picking {
                    state[keyPath: keyPath].picking = false
                } else {
                    state[keyPath: keyPath].pickRegion()
                }
            })
        }

        bar = bar.child(iconButton(
            key: "knobs-btn-undo",
            svg: KnobIcons.undo,
            active: canUndo,
            style: style
        ) { state, tx in
            guard state[keyPath: keyPath].canUndo else { return }
            tx.instant()
            state[keyPath: keyPath].undo()
        })

        if let g = current {
            bar = bar
                .child(iconButton(key: "knobs-btn-random", svg: KnobIcons.random, active: true, style: style) { state, tx in
                    tx.instant()
                    state[keyPath: keyPath].random(g)
                })
                .child(iconButton(key: "knobs-btn-reset", svg: KnobIcons.reset, active: canReset, style: style) { state, tx in
                    guard state[keyPath: keyPath].canReset(g) else { return }
                    tx.instant()
                    state[keyPath: keyPath].reset(g)
                })
                .child(iconButton(key: "knobs-btn-copy", svg: KnobIcons.copy, active: true, style: style) { state, tx in
                    let snippet = state[keyPath: keyPath].code(g)
                    tx.copyText(snippet)
                })
        }

        return bar
    }

    private static func groupTabs<State>(
        knobs: Knobs,
        groups: [KnobGroup],
        current: KnobGroup?,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        guard groups.count > 1 else { return El<State>(direction: .row).key("knobs-tabs-empty") }
        var strip: El<State> = row()
            .key("knobs-group-tabs")
            .wFull()
            .gap(2)
            .p(2)
            .rounded(8)
            .bg(style.inset)
        for (i, g) in groups.enumerated() {
            let selected = current?.name == g.name
            strip = strip.child(
                El<State>(direction: .row)
                    .key("knobs-group-tab-\(i)")
                    .role(.tab)
                    .grow(1)
                    .h(24)
                    .px(8)
                    .rounded(6)
                    .bg(selected ? style.raised : .transparent)
                    .hover(style.fillHover)
                    .center()
                    .onHover { state, inside, tx in
                        tx.settle()
                        state[keyPath: keyPath].hoverGroup = inside ? g.name : nil
                    }
                    .onClick { state, tx in
                        tx.settle()
                        state[keyPath: keyPath].pick(g.name)
                    }
                    .child(text(g.name).font(selected ? PanelTypography.chipOn : PanelTypography.chip).color(selected ? style.fg : style.fg3))
            )
        }
        return strip
    }

    private static func presetTray<State>(
        knobs: Knobs,
        group: KnobGroup,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        let activeName = knobs.activePreset(group)
        var entries: [(name: String, saved: Bool)] = [(RuneKnobsDefaults.defaultPresetName, false)]
        entries.append(contentsOf: group.presets.map { ($0.name, false) })
        if let savedList = knobs.saved[group.name] {
            entries.append(contentsOf: savedList.map { ($0.name, true) })
        }

        var tray: El<State> = row()
            .key("knobs-presets")
            .wFull()
            .gap(2)
            .p(2)
            .rounded(8)
            .bg(style.inset)

        for (i, entry) in entries.enumerated() {
            let on = entry.name == activeName
            let drifted = on && knobs.drifted(group, name: entry.name)
            let shown = (entry.name == RuneKnobsDefaults.defaultPresetName) ? group.defaultLabel : entry.name
            var chip: El<State> = row()
                .key("knobs-preset-\(i)")
                .role(.button)
                .grow(1)
                .minW(48)
                .h(24)
                .px(8)
                .gap(5)
                .center()
                .rounded(6)
                .bg(on ? style.raised : .transparent)
                .hover(style.fillHover)
                .onClick { state, tx in
                    tx.settle()
                    state[keyPath: keyPath].apply(group, name: entry.name)
                }
                .child(text(shown).font(on ? PanelTypography.chipOn : PanelTypography.chip).color(on ? style.fg : style.fg2))
            if drifted {
                chip = chip.child(el().key("drift").size(4, 4).rounded(2).bg(style.fg3))
            }
            if entry.saved {
                chip = chip.onSecondaryClick { state, _, tx in
                    tx.settle()
                    state[keyPath: keyPath].deletePreset(group, name: entry.name)
                }
            }
            tray = tray.child(chip)
        }

        tray = tray.child(
            El<State>(direction: .row)
                .key("knobs-save")
                .role(.button)
                .w(28)
                .h(24)
                .center()
                .rounded(6)
                .hover(style.fillHover)
                .onClick { state, tx in
                    tx.settle()
                    state[keyPath: keyPath].savePreset(group)
                }
                .child(text("+").font(PanelTypography.chipOn).color(style.fg2))
        )
        return tray
    }

    private static func knobCard<State>(
        knobs: Knobs,
        group: KnobGroup,
        groupIndex: Int,
        knobIndices: [Int],
        markedIndex: Int?,
        cardWidth: Float = 280,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        let measuredCardW = Rune.layoutWith("knobs-card") { $0[2].rounded() } ?? cardWidth
        var card: El<State> = col()
            .key("knobs-card")
            .wFull()
            .rounded(8)
            .bg(style.fill)
            .clip(true)

        for (n, idx) in knobIndices.enumerated() {
            let d = group.knobs[idx]
            var r: El<State> = switch d.kind {
            case .bool:
                boolRow(knobs: knobs, group: group, groupIndex: groupIndex, index: idx, knob: d, style: style, keyPath: keyPath)
            case .select:
                choiceRow(knobs: knobs, group: group, groupIndex: groupIndex, index: idx, knob: d, cardWidth: measuredCardW, style: style, keyPath: keyPath)
            case .color:
                colorRow(knobs: knobs, group: group, groupIndex: groupIndex, index: idx, knob: d, style: style, keyPath: keyPath)
            case .text:
                textRow(knobs: knobs, group: group, groupIndex: groupIndex, index: idx, knob: d, style: style, keyPath: keyPath)
            case .vec2:
                vec2Row(knobs: knobs, group: group, groupIndex: groupIndex, index: idx, knob: d, style: style, keyPath: keyPath)
            case .spring:
                springRow(knobs: knobs, group: group, groupIndex: groupIndex, index: idx, knob: d, style: style, keyPath: keyPath)
            case .float, .int:
                sliderRow(knobs: knobs, group: group, groupIndex: groupIndex, index: idx, knob: d, style: style, keyPath: keyPath)
            }

            if markedIndex == idx {
                r = r.bg(style.fillHover)
            }
            if n > 0 {
                r = r.child(el().key("rule-\(n)").absolute(x: 0, y: 0).wFull().h(0.5).bg(style.rule))
            }
            card = card.child(r)
        }
        return card
    }

    // MARK: - Individual Knob Row Builders

    private static func sliderRow<State>(
        knobs: Knobs,
        group: KnobGroup,
        groupIndex: Int,
        index: Int,
        knob: Knob,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        let val = knobs.get(knob)
        let span = max(1e-5, knob.max - knob.min)
        let frac = min(max((val - knob.min) / span, 0), 1)
        let isDragging = knobs.drag == knob.name
        let isHot = knobs.hot == knob.name
        let changed = abs(val - knob.default) > 1e-4
        let trackFill = isDragging ? style.sliderActive : (isHot ? style.sliderHover : style.slider)
        let formatted = knob.kind == .int ? "\(Int(val.rounded()))" : trimFloat(val)

        return el()
            .key("knob-\(knob.name)")
            .role(.slider)
            .wFull()
            .h(32)
            .bg(isHot || isDragging ? style.fillHover : .transparent)
            .onHover { state, inside, tx in
                tx.instant()
                if inside {
                    state[keyPath: keyPath].hot = knob.name
                } else if state[keyPath: keyPath].hot == knob.name {
                    state[keyPath: keyPath].hot = nil
                }
            }
            .onSecondaryClick { state, _, tx in
                tx.instant()
                state[keyPath: keyPath].touch(group: group.name, groupIndex: groupIndex, knobIndex: index)
                state[keyPath: keyPath].resetKnob(knob)
            }
            .onDrag { state, drag, tx in
                tx.instant()
                let w = max(1, drag.size.x)
                let t = min(max(drag.local.x / w, 0), 1)
                let nextVal = knob.min + t * (knob.max - knob.min)
                if state[keyPath: keyPath].drag != knob.name {
                    state[keyPath: keyPath].checkpoint()
                    state[keyPath: keyPath].touch(group: group.name, groupIndex: groupIndex, knobIndex: index)
                    state[keyPath: keyPath].drag = knob.name
                }
                state[keyPath: keyPath].set(knob, nextVal)
            }
            .onDragEnd { state, _, tx in
                tx.instant()
                if state[keyPath: keyPath].drag == knob.name {
                    state[keyPath: keyPath].drag = nil
                }
            }
            .child(
                El<State>(direction: .row)
                    .key("fill")
                    .absolute(x: 0, y: 0)
                    .wFrac(frac)
                    .h(32)
                    .bg(trackFill)
                    .child(spacer())
                    .child(
                        el()
                            .key("handle")
                            .w(3)
                            .minW(3)
                            .h(20)
                            .mt(6)
                            .rounded(1.5)
                            .bg(style.handle)
                            .opacity(isDragging ? 0.95 : (isHot ? 0.65 : 0))
                    )
            )
            .child(
                El<State>(direction: .row)
                    .key("text")
                    .absolute(x: 0, y: 0)
                    .wFull()
                    .h(32)
                    .px(10)
                    .gap(8)
                    .center()
                    .child(text(knob.title).font(PanelTypography.label).color(style.fg2))
                    .child(spacer())
                    .child(text(formatted).font(PanelTypography.value).color(isHot || isDragging || changed ? style.fg : style.fg2))
            )
    }

    private static func choiceOptionCell<State>(
        knobs: Knobs,
        group: KnobGroup,
        groupIndex: Int,
        index: Int,
        knob: Knob,
        optIdx: Int,
        optLabel: String,
        cellWidth: Float?,
        keyed: Bool,
        settledIdx: Int?,
        selectedIdx: Int,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        let on = optIdx == selectedIdx
        var opt: El<State> = El<State>(direction: .row)
            .key("knob-\(knob.name)-opt-\(optIdx)")
            .role(.button)
            .h(22)
            .px(7)
            .gap(5)
            .center()
            .rounded(5)
            .bg(on ? style.raised : .transparent)
            .hover(style.fillHover)
            .onHover { state, inside, tx in
                tx.instant()
                if inside {
                    state[keyPath: keyPath].hot = knob.name
                    state[keyPath: keyPath].hotOpt = (knob.name, optIdx)
                } else if state[keyPath: keyPath].hotOpt?.0 == knob.name && state[keyPath: keyPath].hotOpt?.1 == optIdx {
                    state[keyPath: keyPath].hotOpt = nil
                }
            }
            .onClick { state, tx in
                tx.instant()
                state[keyPath: keyPath].touch(group: group.name, groupIndex: groupIndex, knobIndex: index)
                state[keyPath: keyPath].change(knob, Float(optIdx))
            }
            .child(text(optLabel).font(on ? PanelTypography.chipOn : PanelTypography.chip).color(on ? style.fg : style.fg2))
        if settledIdx == optIdx {
            opt = opt.child(el().key("current").size(4, 4).rounded(2).bg(style.fg3))
        }
        if keyed && optIdx < 9 {
            opt = opt.child(
                text("\(optIdx + 1)")
                    .key("digit")
                    .font(PanelTypography.digit)
                    .color(style.fg3)
                    .absolute(x: 1.5, y: 1.5)
            )
        }
        if let cw = cellWidth {
            opt = opt.w(cw)
        }
        return opt
    }

    private static func choiceRow<State>(
        knobs: Knobs,
        group: KnobGroup,
        groupIndex: Int,
        index: Int,
        knob: Knob,
        cardWidth: Float,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        let selectedIdx = Int(knobs.get(knob).rounded())
        let settledIdx = knobs.settled?[knob.name].map { Int(knob.clamp($0).rounded()) }
        let shape = RuneKnobs.choiceShape(knob, cardWidth: cardWidth, showSettledDot: settledIdx != nil)
        let keyed: Bool = if case .knob(let atG, let atI) = knobs.treeAt, atG == groupIndex, atI == index { true } else { false }

        func buildGrid(cols: Int) -> El<State> {
            let optGap: Float = 2
            let well: Float = 2
            let pad: Float = 10
            let room = max(40, cardWidth - 2 * (pad - 6) - 2 * well)
            let cw = max(20, (room - optGap * Float(max(0, cols - 1))) / Float(max(1, cols)))
            var grid: El<State> = col().key("seg").wFull().p(well).gap(optGap).rounded(7).bg(style.inset)
            var r = 0
            while r * cols < knob.labels.count {
                var line: El<State> = row().key("line-\(r)").gap(optGap)
                for c in 0..<cols {
                    let j = r * cols + c
                    if j < knob.labels.count {
                        line = line.child(
                            choiceOptionCell(
                                knobs: knobs, group: group, groupIndex: groupIndex, index: index,
                                knob: knob, optIdx: j, optLabel: knob.labels[j], cellWidth: cw,
                                keyed: keyed, settledIdx: settledIdx, selectedIdx: selectedIdx,
                                style: style, keyPath: keyPath
                            )
                        )
                    }
                }
                grid = grid.child(line)
                r += 1
            }
            return grid
        }

        let inner: El<State> = switch shape {
        case .inline:
            {
                var seg: El<State> = row().key("seg").h(26).p(2).gap(2).rounded(7).bg(style.inset)
                for (optIdx, optLabel) in knob.labels.enumerated() {
                    seg = seg.child(
                        choiceOptionCell(
                            knobs: knobs, group: group, groupIndex: groupIndex, index: index,
                            knob: knob, optIdx: optIdx, optLabel: optLabel, cellWidth: nil,
                            keyed: keyed, settledIdx: settledIdx, selectedIdx: selectedIdx,
                            style: style, keyPath: keyPath
                        )
                    )
                }
                return El<State>(direction: .row)
                    .key("knob-\(knob.name)")
                    .wFull()
                    .h(36)
                    .pl(10)
                    .pr(6)
                    .gap(8)
                    .center()
                    .child(text(knob.title).font(PanelTypography.label).color(style.fg2))
                    .child(spacer())
                    .child(seg)
            }()
        case .grid(let cols):
            col()
                .key("knob-\(knob.name)")
                .wFull()
                .px(4)
                .pb(6)
                .child(
                    El<State>(direction: .row)
                        .key("head")
                        .wFull()
                        .h(28)
                        .px(6)
                        .center()
                        .child(text(knob.title).font(PanelTypography.label).color(style.fg2))
                        .child(spacer())
                )
                .child(buildGrid(cols: cols))
        case .long(let cols):
            {
                let open = knobs.expanded == knob.name
                let n = max(1, knob.labels.count)
                let curLabel = knob.labels.indices.contains(selectedIdx) ? knob.labels[selectedIdx] : ""
                let stepper: El<State> = row()
                    .key("stepper")
                    .h(26)
                    .p(2)
                    .gap(2)
                    .center()
                    .rounded(7)
                    .bg(style.inset)
                    .child(
                        El<State>(direction: .row)
                            .key("prev")
                            .role(.button)
                            .size(22, 22)
                            .center()
                            .rounded(5)
                            .hover(style.fillHover)
                            .onClick { state, tx in
                                tx.instant()
                                state[keyPath: keyPath].touch(group: group.name, groupIndex: groupIndex, knobIndex: index)
                                let cur = Int(state[keyPath: keyPath].get(knob).rounded())
                                let next = ((cur - 1) % n + n) % n
                                state[keyPath: keyPath].change(knob, Float(next))
                            }
                            .child(text("‹").font(PanelTypography.chip).color(style.fg2))
                    )
                    .child(
                        El<State>(direction: .row)
                            .key("current")
                            .role(.button)
                            .h(22)
                            .px(8)
                            .gap(6)
                            .center()
                            .rounded(5)
                            .bg(open ? style.raised : .transparent)
                            .hover(style.fillHover)
                            .onClick { state, tx in
                                tx.instant()
                                state[keyPath: keyPath].expanded = (state[keyPath: keyPath].expanded == knob.name) ? nil : knob.name
                            }
                            .child(text(curLabel).font(PanelTypography.chip).color(style.fg))
                            .child(text("\(selectedIdx + 1)/\(n)").font(PanelTypography.value).color(style.fg3))
                    )
                    .child(
                        El<State>(direction: .row)
                            .key("next")
                            .role(.button)
                            .size(22, 22)
                            .center()
                            .rounded(5)
                            .hover(style.fillHover)
                            .onClick { state, tx in
                                tx.instant()
                                state[keyPath: keyPath].touch(group: group.name, groupIndex: groupIndex, knobIndex: index)
                                let cur = Int(state[keyPath: keyPath].get(knob).rounded())
                                let next = (cur + 1) % n
                                state[keyPath: keyPath].change(knob, Float(next))
                            }
                            .child(text("›").font(PanelTypography.chip).color(style.fg2))
                    )
                let head: El<State> = El<State>(direction: .row)
                    .key("head")
                    .wFull()
                    .h(36)
                    .pl(6)
                    .gap(8)
                    .center()
                    .child(text(knob.title).font(PanelTypography.label).color(style.fg2))
                    .child(spacer())
                    .child(stepper)
                var box: El<State> = col().key("knob-\(knob.name)").wFull().px(4).child(head)
                if open {
                    box = box.pb(6).child(buildGrid(cols: cols))
                }
                return box
            }()
        }

        return inner
            .onHover { state, inside, tx in
                tx.instant()
                if inside {
                    state[keyPath: keyPath].hot = knob.name
                } else if state[keyPath: keyPath].hot == knob.name {
                    state[keyPath: keyPath].hot = nil
                }
            }
            .onSecondaryClick { state, _, tx in
                tx.instant()
                state[keyPath: keyPath].touch(group: group.name, groupIndex: groupIndex, knobIndex: index)
                state[keyPath: keyPath].resetKnob(knob)
            }
            .onClick { state, tx in
                tx.instant()
                state[keyPath: keyPath].touch(group: group.name, groupIndex: groupIndex, knobIndex: index)
            }
    }

    private static func boolRow<State>(
        knobs: Knobs,
        group: KnobGroup,
        groupIndex: Int,
        index: Int,
        knob: Knob,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        let on = knobs.getBool(knob)
        return El<State>(direction: .row)
            .key("knob-\(knob.name)")
            .role(.checkbox)
            .wFull()
            .h(32)
            .px(10)
            .gap(8)
            .center()
            .onHover { state, inside, tx in
                tx.instant()
                if inside { state[keyPath: keyPath].hot = knob.name }
                else if state[keyPath: keyPath].hot == knob.name { state[keyPath: keyPath].hot = nil }
            }
            .onClick { state, tx in
                tx.settle()
                state[keyPath: keyPath].checkpoint()
                state[keyPath: keyPath].setBool(knob, !on)
                state[keyPath: keyPath].touch(group: group.name, groupIndex: groupIndex, knobIndex: index)
            }
            .onSecondaryClick { state, _, tx in
                tx.instant()
                state[keyPath: keyPath].touch(group: group.name, groupIndex: groupIndex, knobIndex: index)
                state[keyPath: keyPath].resetKnob(knob)
            }
            .child(text(knob.title).font(PanelTypography.label).color(style.fg2))
            .child(spacer())
            .child(
                row()
                    .w(34)
                    .h(18)
                    .p(2)
                    .rounded(9)
                    .bg(on ? style.sliderActive : style.inset)
                    .child(
                        el()
                            .size(14, 14)
                            .rounded(7)
                            .bg(style.handle)
                            .offset(on ? 16 : 0, 0)
                    )
            )
    }

    private static func colorRow<State>(
        knobs: Knobs,
        group: KnobGroup,
        groupIndex: Int,
        index: Int,
        knob: Knob,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        let c = knobs.getColor(knob)
        return El<State>(direction: .row)
            .key("knob-\(knob.name)")
            .wFull()
            .h(32)
            .px(10)
            .gap(8)
            .center()
            .onHover { state, inside, tx in
                tx.instant()
                if inside { state[keyPath: keyPath].hot = knob.name }
                else if state[keyPath: keyPath].hot == knob.name { state[keyPath: keyPath].hot = nil }
            }
            .onSecondaryClick { state, _, tx in
                tx.instant()
                state[keyPath: keyPath].touch(group: group.name, groupIndex: groupIndex, knobIndex: index)
                state[keyPath: keyPath].resetKnob(knob)
            }
            .child(text(knob.title).font(PanelTypography.label).color(style.fg2))
            .child(spacer())
            .child(text(c.hexString()).font(PanelTypography.value).color(style.fg3))
            .child(el().size(18, 18).rounded(4).bg(c).border(1, style.border))
    }

    private static func textRow<State>(
        knobs: Knobs,
        group: KnobGroup,
        groupIndex: Int,
        index: Int,
        knob: Knob,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        let val = knobs.getText(knob)
        return El<State>(direction: .row)
            .key("knob-\(knob.name)")
            .wFull()
            .h(32)
            .px(10)
            .gap(8)
            .center()
            .onHover { state, inside, tx in
                tx.instant()
                if inside { state[keyPath: keyPath].hot = knob.name }
                else if state[keyPath: keyPath].hot == knob.name { state[keyPath: keyPath].hot = nil }
            }
            .onSecondaryClick { state, _, tx in
                tx.instant()
                state[keyPath: keyPath].touch(group: group.name, groupIndex: groupIndex, knobIndex: index)
                state[keyPath: keyPath].resetKnob(knob)
            }
            .child(text(knob.title).font(PanelTypography.label).color(style.fg2))
            .child(spacer())
            .child(
                row()
                    .px(8)
                    .py(3)
                    .rounded(5)
                    .bg(style.inset)
                    .child(text(val.isEmpty ? "—" : val).font(PanelTypography.value).color(style.fg))
            )
    }

    private static func vec2Row<State>(
        knobs: Knobs,
        group: KnobGroup,
        groupIndex: Int,
        index: Int,
        knob: Knob,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        let v = knobs.getVec2(knob)
        return El<State>(direction: .row)
            .key("knob-\(knob.name)")
            .wFull()
            .h(32)
            .px(10)
            .gap(8)
            .center()
            .onHover { state, inside, tx in
                tx.instant()
                if inside { state[keyPath: keyPath].hot = knob.name }
                else if state[keyPath: keyPath].hot == knob.name { state[keyPath: keyPath].hot = nil }
            }
            .onSecondaryClick { state, _, tx in
                tx.instant()
                state[keyPath: keyPath].touch(group: group.name, groupIndex: groupIndex, knobIndex: index)
                state[keyPath: keyPath].resetKnob(knob)
            }
            .child(text(knob.title).font(PanelTypography.label).color(style.fg2))
            .child(spacer())
            .child(text("(\(trimFloat(v.x)), \(trimFloat(v.y)))").font(PanelTypography.value).color(style.fg))
    }

    private static func springRow<State>(
        knobs: Knobs,
        group: KnobGroup,
        groupIndex: Int,
        index: Int,
        knob: Knob,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        let s = knobs.getSpring(knob)
        return El<State>(direction: .row)
            .key("knob-\(knob.name)")
            .wFull()
            .h(32)
            .px(10)
            .gap(8)
            .center()
            .onHover { state, inside, tx in
                tx.instant()
                if inside { state[keyPath: keyPath].hot = knob.name }
                else if state[keyPath: keyPath].hot == knob.name { state[keyPath: keyPath].hot = nil }
            }
            .onSecondaryClick { state, _, tx in
                tx.instant()
                state[keyPath: keyPath].touch(group: group.name, groupIndex: groupIndex, knobIndex: index)
                state[keyPath: keyPath].resetKnob(knob)
            }
            .child(text(knob.title).font(PanelTypography.label).color(style.fg2))
            .child(spacer())
            .child(text("\(trimFloat(s.duration))s · \(trimFloat(s.bounce))").font(PanelTypography.value).color(style.fg))
    }

    private static func iconButton<State>(
        key: String,
        svg: SVGIcon,
        active: Bool,
        style: KnobStyle,
        action: @escaping (inout State, inout Tx) -> Void
    ) -> El<State> {
        row()
            .key(key)
            .role(.button)
            .size(24, 24)
            .rounded(6)
            .center()
            .bg(active ? style.fill : .transparent)
            .hover(style.fillHover)
            .onClick(action)
            .child(icon(svg, size: 13).color(active ? style.fg : style.fg3))
    }
}
