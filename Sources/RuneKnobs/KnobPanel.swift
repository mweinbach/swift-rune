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
}

public extension RuneKnobs {
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
            .w(340)
            .maxW(380)
            .bg(style.bg)
            .border(1, style.border)
            .rounded(12)
            .p(10)
            .gap(8)
            .shadows([Shadow(x: 0, y: 12, blur: 32, spread: 0, color: style.shadow)])
            .onKey { state, ev, tx in
                if RuneKnobs.key(&state[keyPath: keyPath], event: ev) {
                    tx.settle()
                    return true
                }
                if state[keyPath: keyPath].panelKey(groups: groups, event: ev) {
                    tx.settle()
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

        return El<State>(direction: .row)
            .key("knobs-layer")
            .absolute(x: 16, y: 16)
            .child(body)
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
        guard knobs.open else { return page }
        let sidePanel = sidePanelContent(
            knobs: knobs,
            groups: groups,
            style: style,
            seen: seen,
            keyPath: keyPath,
            filterEditKeyPath: filterEditKeyPath
        )
        return El<State>(direction: .row)
            .key("knobs-side-shell")
            .wFull()
            .hFull()
            .child(el().grow(1).child(page))
            .child(sidePanel)
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

        var panel: El<State> = col()
            .key("knobs-side-panel")
            .w(w)
            .shrink(0)
            .hFull()
            .bg(style.bg)
            .border(1, style.border)
            .p(10)
            .gap(8)
            .onKey { state, ev, tx in
                if RuneKnobs.key(&state[keyPath: keyPath], event: ev) {
                    tx.settle()
                    return true
                }
                if KnobTree.handleKey(&state[keyPath: keyPath], groups: groups, seen: seen, event: ev) {
                    tx.settle()
                    return true
                }
                return false
            }

        // Filter bar
        if let editKP = filterEditKeyPath {
            panel = panel.child(
                El<State>(direction: .row)
                    .key("knobs-filter-row")
                    .wFull()
                    .h(28)
                    .px(8)
                    .rounded(6)
                    .bg(style.inset)
                    .border(1, knobs.filtering ? style.outline : style.border)
                    .center()
                    .child(
                        textInput(key: "knobs-filter-input", editKP)
                            .wFull()
                            .font(PanelTypography.label)
                            .color(style.fg)
                            .onChange { state, newText, _ in
                                state[keyPath: keyPath].query = newText
                            }
                    )
            )
        } else {
            panel = panel.child(
                El<State>(direction: .row)
                    .key("knobs-filter-pill")
                    .wFull()
                    .h(26)
                    .px(8)
                    .rounded(6)
                    .bg(style.inset)
                    .center()
                    .child(text(knobs.query.isEmpty ? "Filter knobs (/)" : knobs.query).font(PanelTypography.label).color(knobs.query.isEmpty ? style.fg3 : style.fg))
                    .child(spacer())
            )
        }

        // Tabs bar for .tabs layout
        if !plan.tabs.isEmpty {
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
            panel = panel.child(tabRow)
        }

        // Sections
        for (si, sec) in plan.sections.enumerated() {
            switch sec.head {
            case .page(let pageName):
                panel = panel.child(
                    El<State>(direction: .row)
                        .key("knobs-sec-page-\(si)")
                        .role(.button)
                        .wFull()
                        .px(4)
                        .py(4)
                        .gap(6)
                        .onClick { state, tx in
                            tx.settle()
                            let wasFolded = !sec.open
                            state[keyPath: keyPath].setFolded(pageName, !wasFolded)
                        }
                        .child(text(sec.open ? "▾" : "▸").font(PanelTypography.caption).color(style.fg3))
                        .child(text(pageName).font(PanelTypography.title).color(style.fg))
                )
            case .caption(let cap):
                panel = panel.child(
                    text(cap).font(PanelTypography.caption).color(style.fg3).px(4)
                )
            case .bare:
                break
            }

            guard sec.open else { continue }
            for sub in sec.subs {
                let g = groups[sub.groupIndex]
                let titleText = sub.full && !g.under.isEmpty ? "\(g.under) · \(g.name)" : g.name
                panel = panel.child(
                    El<State>(direction: .row)
                        .key("knobs-sub-head-\(sub.groupIndex)")
                        .role(.button)
                        .wFull()
                        .px(4)
                        .py(3)
                        .gap(6)
                        .onClick { state, tx in
                            tx.settle()
                            state[keyPath: keyPath].setFolded(g.name, sub.open)
                            state[keyPath: keyPath].pick(g.name)
                        }
                        .child(text(sub.open ? "▾" : "▸").font(PanelTypography.caption).color(style.fg3))
                        .child(text(titleText).font(PanelTypography.chipOn).color(style.fg2))
                )
                if sub.open {
                    panel = panel.child(
                        knobCard(
                            knobs: knobs,
                            group: g,
                            groupIndex: sub.groupIndex,
                            knobIndices: sub.knobs,
                            markedIndex: nil,
                            style: style,
                            keyPath: keyPath
                        )
                    )
                }
            }
        }

        return panel
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
            tx.settle()
            state[keyPath: keyPath].undo()
        })

        if let g = current {
            bar = bar
                .child(iconButton(key: "knobs-btn-random", svg: KnobIcons.random, active: true, style: style) { state, tx in
                    tx.settle()
                    state[keyPath: keyPath].random(g)
                })
                .child(iconButton(key: "knobs-btn-reset", svg: KnobIcons.reset, active: canReset, style: style) { state, tx in
                    tx.settle()
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
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
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
                boolRow(knobs: knobs, group: group, index: idx, knob: d, style: style, keyPath: keyPath)
            case .select:
                choiceRow(knobs: knobs, group: group, index: idx, knob: d, style: style, keyPath: keyPath)
            case .color:
                colorRow(knobs: knobs, group: group, index: idx, knob: d, style: style, keyPath: keyPath)
            case .text:
                textRow(knobs: knobs, group: group, index: idx, knob: d, style: style, keyPath: keyPath)
            case .vec2:
                vec2Row(knobs: knobs, group: group, index: idx, knob: d, style: style, keyPath: keyPath)
            case .spring:
                springRow(knobs: knobs, group: group, index: idx, knob: d, style: style, keyPath: keyPath)
            case .float, .int:
                sliderRow(knobs: knobs, group: group, index: idx, knob: d, style: style, keyPath: keyPath)
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
        let trackFill = isDragging ? style.sliderActive : (isHot ? style.sliderHover : style.slider)
        let formatted = knob.kind == .int ? "\(Int(val.rounded()))" : trimFloat(val)

        return El<State>(direction: .row)
            .key("knob-\(knob.name)")
            .wFull()
            .h(32)
            .px(10)
            .gap(8)
            .center()
            .onHover { state, inside, tx in
                tx.settle()
                if inside {
                    state[keyPath: keyPath].hot = knob.name
                } else if state[keyPath: keyPath].hot == knob.name {
                    state[keyPath: keyPath].hot = nil
                }
            }
            .onSecondaryClick { state, _, tx in
                tx.settle()
                state[keyPath: keyPath].resetKnob(knob)
            }
            .onDrag { state, drag, tx in
                tx.settle()
                let w = max(1, drag.size.x)
                let t = min(max(drag.local.x / w, 0), 1)
                let nextVal = knob.min + t * (knob.max - knob.min)
                if state[keyPath: keyPath].drag != knob.name {
                    state[keyPath: keyPath].checkpoint()
                    state[keyPath: keyPath].drag = knob.name
                }
                state[keyPath: keyPath].set(knob, nextVal)
                state[keyPath: keyPath].group = group.name
                state[keyPath: keyPath].cursor = index
            }
            .onDragEnd { state, _, tx in
                tx.settle()
                if state[keyPath: keyPath].drag == knob.name {
                    state[keyPath: keyPath].drag = nil
                }
            }
            .child(text(knob.title).font(PanelTypography.label).color(style.fg2))
            .child(
                el()
                    .key("knob-track-\(knob.name)")
                    .grow(1)
                    .h(6)
                    .rounded(3)
                    .bg(style.inset)
                    .clip(true)
                    .child(
                        el()
                            .key("knob-fill-\(knob.name)")
                            .w(max(4, frac * 120))
                            .hFull()
                            .rounded(3)
                            .bg(trackFill)
                    )
            )
            .child(text(formatted).font(PanelTypography.value).color(style.fg))
    }

    private static func choiceRow<State>(
        knobs: Knobs,
        group: KnobGroup,
        index: Int,
        knob: Knob,
        style: KnobStyle,
        keyPath: WritableKeyPath<State, Knobs>
    ) -> El<State> {
        let selectedIdx = Int(knobs.get(knob).rounded())
        var optionsRow: El<State> = row().gap(2).p(2).rounded(6).bg(style.inset)
        for (optIdx, optLabel) in knob.labels.enumerated() {
            let on = optIdx == selectedIdx
            optionsRow = optionsRow.child(
                El<State>(direction: .row)
                    .key("knob-\(knob.name)-opt-\(optIdx)")
                    .role(.button)
                    .px(7)
                    .py(3)
                    .rounded(4)
                    .bg(on ? style.raised : .transparent)
                    .onClick { state, tx in
                        tx.settle()
                        state[keyPath: keyPath].change(knob, Float(optIdx))
                        state[keyPath: keyPath].group = group.name
                        state[keyPath: keyPath].cursor = index
                    }
                    .child(text(optLabel).font(on ? PanelTypography.chipOn : PanelTypography.chip).color(on ? style.fg : style.fg2))
            )
        }
        return El<State>(direction: .row)
            .key("knob-\(knob.name)")
            .wFull()
            .h(32)
            .px(10)
            .gap(8)
            .center()
            .onSecondaryClick { state, _, tx in
                tx.settle()
                state[keyPath: keyPath].resetKnob(knob)
            }
            .child(text(knob.title).font(PanelTypography.label).color(style.fg2))
            .child(spacer())
            .child(optionsRow)
    }

    private static func boolRow<State>(
        knobs: Knobs,
        group: KnobGroup,
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
            .onClick { state, tx in
                tx.settle()
                state[keyPath: keyPath].checkpoint()
                state[keyPath: keyPath].setBool(knob, !on)
                state[keyPath: keyPath].group = group.name
                state[keyPath: keyPath].cursor = index
            }
            .onSecondaryClick { state, _, tx in
                tx.settle()
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
            .onSecondaryClick { state, _, tx in
                tx.settle()
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
            .onSecondaryClick { state, _, tx in
                tx.settle()
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
            .onSecondaryClick { state, _, tx in
                tx.settle()
                state[keyPath: keyPath].resetKnob(knob)
            }
            .child(text(knob.title).font(PanelTypography.label).color(style.fg2))
            .child(spacer())
            .child(text("(\(trimFloat(v.x)), \(trimFloat(v.y)))").font(PanelTypography.value).color(style.fg))
    }

    private static func springRow<State>(
        knobs: Knobs,
        group: KnobGroup,
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
            .onSecondaryClick { state, _, tx in
                tx.settle()
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
