import Foundation
import RuneMotion

internal struct PlaygroundSizePopupTarget: Sendable {}

internal enum PlaygroundViewTokens {
    static func selectedFill(_ t: ThemeTokens, dark: Bool) -> Color {
        dark ? t.controlOff : t.controlTrack
    }

    static func tertiary(_ t: ThemeTokens) -> Color {
        t.textSecondary.mix(with: t.bg, t: 0.45)
    }

    static func focusedFill(_ accent: Color) -> Color {
        accent.alpha(0.2)
    }

    static var popupMenuSupported: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    static func keycapsString(_ chord: Chord) -> String {
        #if os(macOS)
        return chord.keycaps(on: .mac).joined()
        #else
        return chord.keycaps(on: .linux).joined(separator: "+")
        #endif
    }

    static func triggerCap(_ key: Character) -> String {
        if key == " " { return "Space" }
        return String(key).uppercased()
    }

    static func formatDimension(_ value: Float) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    static let chevronLeft = SVGIcon(
        viewBox: 16.0,
        body: #"<path d="M9.5 4L5.5 8L9.5 12" stroke="currentColor" stroke-width="1.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/>"#
    )

    static let grid = SVGIcon(
        viewBox: 12.0,
        body: #"<rect x="1" y="1" width="4" height="4" rx="1" fill="currentColor"/><rect x="7" y="1" width="4" height="4" rx="1" fill="currentColor"/><rect x="1" y="7" width="4" height="4" rx="1" fill="currentColor"/><rect x="7" y="7" width="4" height="4" rx="1" fill="currentColor"/>"#
    )

    static let chevronRight = SVGIcon(
        viewBox: 16.0,
        body: #"<path d="M6.75 5L9.75 8L6.75 11" stroke="currentColor" stroke-width="1.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/>"#
    )

    static let chevronDown = SVGIcon(
        viewBox: 16.0,
        body: #"<path d="M5 6.75L8 9.75L11 6.75" stroke="currentColor" stroke-width="1.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/>"#
    )

    static let sun = SVGIcon(
        viewBox: 16.0,
        body: #"<circle cx="8" cy="8" r="2.75" stroke="currentColor" stroke-width="1.5" fill="none"/><path d="M8 1.75V3M8 13V14.25M1.75 8H3M13 8H14.25M3.6 3.6L4.45 4.45M11.55 11.55L12.4 12.4M3.6 12.4L4.45 11.55M11.55 4.45L12.4 3.6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>"#
    )

    static let moon = SVGIcon(
        viewBox: 16.0,
        body: #"<path d="M13.25 9.5A5.5 5.5 0 0 1 6.5 2.75A5.5 5.5 0 1 0 13.25 9.5Z" stroke="currentColor" stroke-width="1.5" fill="none" stroke-linejoin="round"/>"#
    )

    static let motion = SVGIcon(
        viewBox: 16.0,
        body: #"<circle cx="10" cy="8" r="3.25" stroke="currentColor" stroke-width="1.5" fill="none"/><path d="M1.75 5.5H4.5M1.25 8H4M1.75 10.5H4.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>"#
    )
}

extension PlaygroundLive {
    // MARK: - Root Window View (`playground/view.rs`)

    internal func buildView(
        appState: State,
        appView: (State, inout Cx<State>) -> El<State>,
        cx: inout Cx<State>,
        viewport: Vec2
    ) -> El<State> {
        let dark = isDark(appState: appState, systemDark: cx.getSystemDark())
        let t = Tok.theme(dark: dark)
        if !isOpen {
            if !showBar {
                return appView(appState, &cx)
            }
            let root = appView(appState, &cx)
            return col()
                .key("playground-closed")
                .w(viewport.x)
                .h(viewport.y)
                .child(root.w(viewport.x).h(max(0.0, viewport.y - PlaygroundConst.bar)))
                .child(barView(t: t))
        }

        let (sidebarW, sideW) = widths(viewportW: viewport.x)
        let stageW = max(0.0, viewport.x - sidebarW - sideW - 2.0)
        var stageEl = buildStage(
            appState: appState,
            appView: appView,
            cx: &cx,
            area: Vec2(stageW, viewport.y),
            dark: dark
        )
        if region == .stage {
            stageEl = stageEl.child(
                el()
                    .key("playground-stage-ring")
                    .pin(top: 0, right: 0, bottom: 0, left: 0)
                    .border(2.0, cx.focusColor())
                    .inert()
            )
        }
        let sideEl = buildSide(appState: appState, cx: &cx, t: t, dark: dark, sideW: sideW, height: viewport.y)
        return row()
            .key("playground")
            .w(viewport.x)
            .h(viewport.y)
            .bg(t.bg)
            .child(buildSidebar(t: t, dark: dark, accent: cx.accent(), inset: cx.titlebarInset(), sidebarW: sidebarW, height: viewport.y))
            .child(el().w(1.0).h(viewport.y).bg(t.separator))
            .child(stageEl)
            .child(el().w(1.0).h(viewport.y).bg(t.separator))
            .child(sideEl)
            .child(buildSidebarEdge(sidebarW: sidebarW, viewport: viewport))
            .child(buildSideEdge(sideW: sideW, viewport: viewport))
    }

    private func barView(t: ThemeTokens) -> El<State> {
        let countText: String? = switch order.count {
        case 0: nil
        case 1: "1 story"
        case let n: "\(n) stories"
        }
        let hintText = shortcut.map(PlaygroundViewTokens.keycapsString)
        let summary = [countText, hintText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")

        let openBtn: El<State> = row()
            .key("playground-open")
            .h(20.0)
            .ml(4.0)
            .px(6.0)
            .gap(6.0)
            .centerY()
            .rounded(Tok.Radius.sm - 1.0)
            .hover(t.hover)
            .press(t.press)
            .child(icon(PlaygroundViewTokens.grid, size: 12.0).color(t.textSecondary))
            .child(text("Playground").font(Tok.Typography.label).color(t.textSecondary))
            .role(.button)
            .label("Open the playground")
            .onClick { _, tx in
                tx.openPlayground()
            }

        return col()
            .wFull()
            .h(PlaygroundConst.bar)
            .bg(t.bg)
            .child(el().wFull().h(1.0).bg(t.separator))
            .child(
                row()
                    .wFull()
                    .h(PlaygroundConst.bar - 1.0)
                    .centerY()
                    .justifyBetween()
                    .child(openBtn)
                    .child(text(summary).font(Tok.Typography.label).color(t.textSecondary).pr(10.0))
            )
    }

    // MARK: - Sidebar (`playground/list.rs`)

    private func buildSidebar(
        t: ThemeTokens,
        dark: Bool,
        accent: Color,
        inset: Float,
        sidebarW: Float,
        height: Float
    ) -> El<State> {
        let back: El<State> = row()
            .key("playground-back")
            .h(PlaygroundConst.control)
            .pl(4.0)
            .pr(8.0)
            .gap(2.0)
            .centerY()
            .rounded(Tok.Radius.sm)
            .hover(t.hover)
            .press(t.press)
            .child(icon(PlaygroundViewTokens.chevronLeft, size: 16.0).color(t.textSecondary))
            .child(text("Back").font(Tok.Typography.label).color(t.text))
            .role(.button)
            .label("Back to the app")
            .onClick { _, tx in
                tx.closePlayground()
            }

        let band: Float = inset > 0.0 ? PlaygroundConst.band : 0.0
        let headerRow = row()
            .w(sidebarW)
            .h(PlaygroundConst.header)
            .pl(8.0)
            .centerY()
            .child(back)

        let onFill = (region == .list) ? PlaygroundViewTokens.focusedFill(accent) : PlaygroundViewTokens.selectedFill(t, dark: dark)

        var listContent: El<State> = col().key("playground-rows").wFull()
        let currentRows = rows()
        for (idx, entry) in currentRows.enumerated() {
            switch entry {
            case .header(let group, let first, let depth):
                listContent = listContent.child(
                    buildHeaderRow(t: t, onFill: onFill, group: group, first: first, depth: depth, isTopRow: idx == 0)
                )
            case .story(let storyIdx, let depth):
                listContent = listContent.child(
                    buildStoryRow(t: t, onFill: onFill, index: storyIdx, depth: depth)
                )
            }
        }
        if currentRows.isEmpty {
            let empty = order.isEmpty ? "No stories" : "No matches"
            listContent = listContent.child(
                text(empty).font(Tok.Typography.body).color(t.textSecondary).px(8.0).pt(4.0)
            )
        }

        let listHeight = max(0.0, height - 2.0 * PlaygroundConst.header - PlaygroundConst.field - band)
        let scrollList = col()
            .key("playground-list")
            .w(sidebarW)
            .h(listHeight)
            .px(8.0)
            .pb(8.0)
            .scrollY()
            .child(listContent)

        var sidebarCol: El<State> = col().w(sidebarW).h(height)
        if band > 0.0 {
            sidebarCol = sidebarCol.child(el().w(sidebarW).h(band).windowDrag())
        }
        return sidebarCol
            .child(headerRow)
            .child(buildFilterField(t: t, sidebarW: sidebarW))
            .child(scrollList)
            .child(buildStageControls(t: t, windowDark: dark, sidebarW: sidebarW))
    }

    private func buildFilterField(t: ThemeTokens, sidebarW: Float) -> El<State> {
        var field = El<State>(direction: .row)
            .key(PlaygroundConst.filterKey)
            .role(.textInput)
            .focusable(true)
            .clip(true)
            .font(Tok.Typography.label)
            .noWrap()
            .color(t.text)
            .caret(t.text, selection: t.text.alpha(0.2))
            .placeholder("Filter", color: PlaygroundViewTokens.tertiary(t))
            .grow(1.0)
            .minW(0.0)
            .label("Filter stories")

        let ctrl = self.controls
        field.handlers.editLens = (
            get: { _ in ctrl.filter },
            set: { _, updated in ctrl.filter = updated }
        )

        return row()
            .w(sidebarW)
            .h(PlaygroundConst.field)
            .px(8.0)
            .pb(8.0)
            .child(
                row()
                    .wFull()
                    .h(PlaygroundConst.field - 8.0)
                    .px(8.0)
                    .centerY()
                    .rounded(Tok.Radius.md)
                    .bg(t.card)
                    .border(1.0, t.cardBorder)
                    .child(field)
            )
    }

    private func sidebarIndent(depth: Int) -> Float {
        8.0 + PlaygroundConst.indent * Float(depth)
    }

    private func buildStoryRow(t: ThemeTokens, onFill: Color, index i: Int, depth: Int) -> El<State> {
        let on = (i == selected && header == nil)
        let storyName = name(of: i)
        let titleEl: El<State> = text(storyName)
            .font(Tok.Typography.body)
            .ellipsis()
            .color((on || i == selected) ? t.text : t.textSecondary)

        var r = row()
            .key("playground-item-\(i)")
            .wFull()
            .h(PlaygroundConst.row)
            .pl(sidebarIndent(depth: depth))
            .pr(8.0)
            .centerY()
            .rounded(Tok.Radius.md)
            .bg(on ? onFill : .transparent)
            .hover(on ? onFill : t.hover)
            .child(titleEl)
            .role(.button)
            .label(storyName)
            .onClick { [weak self] _, tx in
                self?.enqueue(.select(i))
                tx.commit()
            }

        if hasTriggers(i) {
            r = r
                .child(spacer())
                .child(
                    icon(PlaygroundViewTokens.motion, size: 12.0)
                        .key("playground-motion-\(i)")
                        .color(PlaygroundViewTokens.tertiary(t))
                        .ml(6.0)
                )
        }
        return r
    }

    private func buildHeaderRow(
        t: ThemeTokens,
        onFill: Color,
        group: String,
        first: Int,
        depth: Int,
        isTopRow: Bool
    ) -> El<State> {
        let on = (header == group)
        let folded = isFolded(group)
        let displayName: String = {
            if let up = Self.parentGroup(of: group) {
                return String(group.dropFirst(up.count + 1))
            }
            return group
        }()
        let ink = (on || depth == 0) ? t.text : t.textSecondary
        let headerKey = PlaygroundTreeRow.headerKey(first: first, depth: depth)
        let countKey = headerKey.replacingOccurrences(of: "group", with: "count")

        let r: El<State> = row()
            .key(headerKey)
            .wFull()
            .h(24.0)
            .pl(sidebarIndent(depth: depth))
            .pr(8.0)
            .centerY()
            .rounded(Tok.Radius.md)
            .bg(on ? onFill : .transparent)
            .hover(on ? onFill : t.hover)
            .child(
                row()
                    .w(PlaygroundConst.indent)
                    .h(24.0)
                    .center()
                    .child(
                        icon(
                            folded ? PlaygroundViewTokens.chevronRight : PlaygroundViewTokens.chevronDown,
                            size: 12.0
                        )
                        .color(PlaygroundViewTokens.tertiary(t))
                    )
            )
            .child(text(displayName).font(Tok.Typography.section).ellipsis().color(ink))
            .child(spacer())
            .child(
                text(String(countIn(group)))
                    .key(countKey)
                    .font(Tok.Typography.label)
                    .color(PlaygroundViewTokens.tertiary(t))
                    .ml(6.0)
            )
            .role(.button)
            .label(folded ? "Show \(displayName)" : "Hide \(displayName)")
            .onClick { [weak self] _, tx in
                self?.enqueue([.header(group), .fold(group, nil)])
                tx.commit()
            }

        let above: Float = switch (isTopRow, depth) {
        case (true, _): 2.0
        case (_, 0): 10.0
        default: 4.0
        }
        return col().wFull().pt(above).pb(2.0).child(r)
    }

    // MARK: - Stage Controls Footer (`playground/view.rs`)

    private func playgroundIconButton(
        t: ThemeTokens,
        key: String,
        glyph: SVGIcon,
        label: String,
        on: Bool,
        dark: Bool,
        request: PlaygroundRequest
    ) -> El<State> {
        row()
            .key(key)
            .size(PlaygroundConst.control, PlaygroundConst.control)
            .center()
            .rounded(Tok.Radius.sm)
            .bg(on ? PlaygroundViewTokens.selectedFill(t, dark: dark) : .transparent)
            .hover(on ? PlaygroundViewTokens.selectedFill(t, dark: dark) : t.hover)
            .press(t.press)
            .child(icon(glyph, size: 16.0).color(on ? t.text : t.textSecondary))
            .role(.button)
            .label(label)
            .help(label)
            .onClick { [weak self] _, tx in
                self?.enqueue(request)
                tx.commit()
            }
    }

    private func buildStageControls(t: ThemeTokens, windowDark: Bool, sidebarW: Float) -> El<State> {
        let effectiveDark = dark ?? windowDark
        let (glyph, appearanceLabel) = effectiveDark
            ? (PlaygroundViewTokens.moon, "Dark appearance")
            : (PlaygroundViewTokens.sun, "Light appearance")
        let themeBtn = playgroundIconButton(
            t: t,
            key: "playground-theme",
            glyph: glyph,
            label: appearanceLabel,
            on: false,
            dark: windowDark,
            request: .dark(!effectiveDark)
        )
        let reduceBtn = playgroundIconButton(
            t: t,
            key: "playground-reduce-motion",
            glyph: PlaygroundViewTokens.motion,
            label: "Reduce Motion",
            on: reduceMotion,
            dark: windowDark,
            request: .reduceMotion(!reduceMotion)
        )

        var footer: El<State> = row()
            .key("playground-stage-controls")
            .w(sidebarW)
            .h(PlaygroundConst.header)
            .px(8.0)
            .gap(2.0)
            .centerY()
        if !sizes.isEmpty {
            footer = footer.child(buildSizeMenu(t: t))
        }
        return footer
            .child(spacer())
            .child(reduceBtn)
            .child(themeBtn)
    }

    private func buildSizeMenu(t: ThemeTokens) -> El<State> {
        let currentName: String = (sizeIndex > 0 && sizeIndex - 1 < sizes.count) ? sizes[sizeIndex - 1].name : "Window"
        var options: [(String, String)] = [("0", "Window")]
        for (i, pair) in sizes.enumerated() {
            let wStr = PlaygroundViewTokens.formatDimension(pair.size.x)
            let hStr = PlaygroundViewTokens.formatDimension(pair.size.y)
            options.append((String(i + 1), "\(pair.name)  \(wStr)×\(hStr)"))
        }
        let curIndex = sizeIndex
        let totalCount = sizes.count + 1

        return row()
            .key("playground-size")
            .h(PlaygroundConst.control)
            .pl(8.0)
            .pr(4.0)
            .gap(2.0)
            .centerY()
            .rounded(Tok.Radius.sm)
            .hover(t.hover)
            .press(t.press)
            .child(text(currentName).font(Tok.Typography.label).color(t.text))
            .child(icon(PlaygroundViewTokens.chevronDown, size: 16.0).color(t.textSecondary))
            .role(.button)
            .label("Stage size")
            .onClick { [weak self] _, tx in
                guard let self else { return }
                if !PlaygroundViewTokens.popupMenuSupported {
                    self.enqueue(.size((curIndex + 1) % totalCount))
                    tx.commit()
                    return
                }
                let menu = PopupMenu.picker(options, selected: String(curIndex))
                tx.popupMenu(menu, at: "playground-size") { (_: inout PlaygroundSizePopupTarget, picked: String?, pickTx: inout Tx) in
                    if let picked, let idx = Int(picked) {
                        self.enqueue(.size(idx))
                        pickTx.commit()
                    }
                }
            }
    }

    // MARK: - Side Column (`playground/view.rs`)

    private func buildSide(
        appState: State,
        cx: inout Cx<State>,
        t: ThemeTokens,
        dark: Bool,
        sideW: Float,
        height: Float
    ) -> El<State> {
        let i = selected
        var sideCol: El<State> = col()
            .key("playground-side")
            .w(sideW)
            .h(height)
            .px(12.0)
            .pb(12.0)
            .gap(12.0)

        let chrome = cx.chromeInsets()
        let underCaption: Float = chrome.trailing > 0.0 ? chrome.height : 0.0
        sideCol = sideCol.pt(12.0 + underCaption)

        if i < count {
            let groupTitle = group(of: i).replacingOccurrences(of: "/", with: " › ")
            let titleEl: El<State> = col()
                .key("playground-title")
                .px(4.0)
                .gap(2.0)
                .child(text(groupTitle).font(Tok.Typography.section).ellipsis().color(t.textSecondary))
                .child(text(name(of: i)).font(Tok.Typography.title).ellipsis().color(t.text))
            sideCol = sideCol.child(titleEl)
        }

        let slot = buildSideSlot(appState: appState, cx: &cx)
        if let slot {
            var wrappedSlot = el()
                .key("playground-slot-\(i)")
                .wFull()
                .child(slot)
            if hasSideKeysForSelected {
                wrappedSlot = wrappedSlot.focusable(true).noFocusRing()
            }
            sideCol = sideCol.child(wrappedSlot)
        }

        let onFill = PlaygroundViewTokens.focusedFill(cx.accent())
        let variantList = variants()
        let at = variantIndex()

        if !variantList.isEmpty {
            var picker: El<State> = col()
                .key("playground-variants")
                .wFull()
                .p(4.0)
                .gap(2.0)
                .rounded(Tok.Radius.lg)
                .bg(t.card)
                .border(1.0, t.cardBorder)
            for (n, vName) in variantList.prefix(9).enumerated() {
                let on = (n == at)
                let vRow: El<State> = row()
                    .key("playground-variant-\(n)")
                    .wFull()
                    .h(PlaygroundConst.row)
                    .px(4.0)
                    .gap(8.0)
                    .centerY()
                    .rounded(Tok.Radius.md)
                    .bg(on ? PlaygroundViewTokens.selectedFill(t, dark: dark) : .transparent)
                    .focusable(true)
                    .focusHighlight(onFill)
                    .press(t.press)
                    .child(buildKeycap(t: t, label: String(n + 1)))
                    .child(text(vName).font(Tok.Typography.body).ellipsis().color(on ? t.text : t.textSecondary))
                    .role(.button)
                    .label(vName)
                    .onClick { [weak self] _, tx in
                        self?.enqueue(.variant(n))
                        tx.commit()
                    }
                picker = picker.child(vRow)
            }
            sideCol = sideCol.child(picker)
        }

        let triggerList = triggers()
        if !triggerList.isEmpty {
            var card: El<State> = col()
                .key("playground-triggers")
                .wFull()
                .p(4.0)
                .gap(2.0)
                .rounded(Tok.Radius.lg)
                .bg(t.card)
                .border(1.0, t.cardBorder)
            for (k, label) in triggerList {
                let lower = Character(k.lowercased())
                let req: PlaygroundRequest = (lower == "r") ? .replay : .trigger(lower)
                let tRow: El<State> = row()
                    .key("playground-trigger-\(k)")
                    .wFull()
                    .h(PlaygroundConst.row)
                    .px(4.0)
                    .gap(8.0)
                    .centerY()
                    .rounded(Tok.Radius.md)
                    .focusable(true)
                    .focusHighlight(onFill)
                    .press(t.press)
                    .child(buildKeycap(t: t, label: PlaygroundViewTokens.triggerCap(k)))
                    .child(text(label).font(Tok.Typography.body).ellipsis().color(t.text))
                    .role(.button)
                    .label(label)
                    .onClick { [weak self] _, tx in
                        self?.enqueue(req)
                        tx.commit()
                    }
                card = card.child(tRow)
            }
            sideCol = sideCol.child(card)
        }

        let hasControls = (slot != nil || !variantList.isEmpty || !triggerList.isEmpty)
        let hintString = buildHint(variantCount: variantList.count, hasControls: hasControls)
        return sideCol
            .child(spacer())
            .child(
                text(hintString)
                    .key("playground-hint")
                    .font(Tok.Typography.section)
                    .wrapText()
                    .color(t.textSecondary)
                    .px(4.0)
            )
    }

    private func buildKeycap(t: ThemeTokens, label: String) -> El<State> {
        row()
            .key("cap")
            .h(20.0)
            .minW(22.0)
            .px(6.0)
            .center()
            .rounded(Tok.Radius.sm - 2.0)
            .bg(t.controlTrack)
            .child(text(label).font(Tok.Typography.label).color(t.text))
    }

    private func buildHint(variantCount: Int, hasControls: Bool) -> String {
        let clampedVariants = min(variantCount, 9)
        let variantsPart: String? = switch clampedVariants {
        case 0: nil
        case 1: "1\u{a0}variant"
        default: "1–\(clampedVariants)\u{a0}variants"
        }
        let parts: [String?]
        switch region {
        case .list:
            parts = [
                "↑↓\u{a0}stories",
                "←→\u{a0}groups",
                "/\u{a0}filter",
                hasControls ? "Tab\u{a0}controls" : nil,
                "Esc\u{a0}back"
            ]
        case .side:
            parts = ["↑↓\u{a0}controls", variantsPart, "Esc\u{a0}stories"]
        case .stage:
            parts = ["Keys go to the story", "Esc\u{a0}stories"]
        }
        return parts.compactMap { $0 }.joined(separator: "\u{a0}· ")
    }

    private func buildSideSlot(appState: State, cx: inout Cx<State>) -> El<State>? {
        if case .scene = showing {
            guard let entry = sidesByStory.first(where: { $0.storyIndex == selected }) else {
                return nil
            }
            let capturedGen = generation
            var stageCx: Cx<State> = cx.retype()
            let raw: El<State>
            switch entry.side {
            case .stage(let view):
                guard case .scene(let s) = showing else { return nil }
                raw = view(s.state, &stageCx)
            case .real(let view):
                guard case .scene(let s) = showing else { return nil }
                raw = view(s.state, appState, &stageCx)
            case .keys(_, let view):
                guard case .scene(let s) = showing else { return nil }
                raw = view(s.state, sideActive, &stageCx)
            }
            cx.absorb(stageCx)
            return raw.liftHandlers(
                isValid: { [weak self] in
                    guard let self else { return false }
                    return self.generation == capturedGen && self.currentScene != nil
                },
                get: { [weak self] in
                    self?.currentScene?.state
                },
                set: { [weak self] updated in
                    guard let self, self.generation == capturedGen, var cur = self.currentScene else { return }
                    cur.state = updated
                    self.currentScene = cur
                }
            )
        }

        if let (own, box, _) = currentOwn {
            let capturedGen = generation
            return own.renderSide(
                box: box,
                active: sideActive,
                isValid: { [weak self] in
                    guard let self else { return false }
                    return self.generation == capturedGen
                },
                cx: &cx
            )
        }
        return nil
    }

    // MARK: - Stage (`playground/view.rs`)

    private func buildStage(
        appState: State,
        appView: (State, inout Cx<State>) -> El<State>,
        cx: inout Cx<State>,
        area: Vec2,
        dark: Bool
    ) -> El<State> {
        let stageDark = self.dark ?? dark
        let preset = (sizeIndex > 0 && sizeIndex - 1 < sizes.count) ? sizes[sizeIndex - 1].size : nil
        let frame = frameOfSelected()
        let layout = layoutOfSelected()
        let targetSize: Vec2 = (layout == .fill) ? area : (frame ?? preset ?? area)
        let capturedGen = generation

        func runNested(_ body: (inout Cx<State>) -> El<State>) -> El<State> {
            var nestedCx: Cx<State> = cx.retype()
            nestedCx.systemDark = stageDark
            nestedCx.clearChrome()
            if reduceMotion {
                nestedCx.reducedMotion = true
            }
            let root = body(&nestedCx)
            cx.absorb(nestedCx)
            return root
        }

        var content: El<State>? = nil
        var isOverlay = false

        if case .scene(let scene) = showing {
            let page = currentPage
            let unlifted: El<State> = runNested { nestedCx in
                if let page, case .legacy(let legacy) = page.kind {
                    return legacy.view(scene.state, self.legacyControlsForStage(), &nestedCx)
                }
                return appView(scene.state, &nestedCx)
            }
            content = unlifted.liftHandlers(
                isValid: { [weak self] in
                    guard let self else { return false }
                    return self.generation == capturedGen && self.currentScene != nil
                },
                get: { [weak self] in
                    self?.currentScene?.state
                },
                set: { [weak self] updated in
                    guard let self, self.generation == capturedGen, var cur = self.currentScene else { return }
                    cur.state = updated
                    self.currentScene = cur
                }
            )
        } else if let page = currentPage {
            isOverlay = page.isOverlay
            switch page.kind {
            case .live(let pageView):
                content = runNested { nestedCx in
                    pageView(appState, &nestedCx)
                }
            case .own:
                if let (own, box, _) = currentOwn {
                    var nestedCx: Cx<State> = cx.retype()
                    nestedCx.systemDark = stageDark
                    nestedCx.clearChrome()
                    if reduceMotion {
                        nestedCx.reducedMotion = true
                    }
                    content = own.renderView(
                        box: box,
                        isValid: { [weak self] in
                            guard let self else { return false }
                            return self.generation == capturedGen
                        },
                        cx: &nestedCx
                    )
                    cx.absorb(nestedCx)
                }
            case .legacy:
                break
            }
        }

        let inner = Tok.theme(dark: stageDark)
        let resolvedContent = content ?? col().center().child(
            text("Add scenes to AppSpec::scenes, or stories to the playground")
                .font(Tok.Typography.body)
                .color(inner.textSecondary)
        )

        let stageKey = "playground-stage-\(generation)"
        var stage: El<State>
        switch layout {
        case .scroll:
            let innerW = max(0.0, targetSize.x - 2.0 * PlaygroundConst.scrollMargin)
            let marginCol: El<State> = col()
                .key("playground-margin")
                .w(targetSize.x)
                .p(PlaygroundConst.scrollMargin)
                .child(resolvedContent.w(innerW))
            stage = El<State>(direction: .column)
                .key(stageKey)
                .w(targetSize.x)
                .h(targetSize.y)
                .scrollY()
                .child(marginCol)
        case .center, .fill:
            stage = el()
                .key(stageKey)
                .w(targetSize.x)
                .h(targetSize.y)
                .child(resolvedContent.w(targetSize.x).h(targetSize.y))
        }

        let t = Tok.theme(dark: dark)
        var presentedStage = stage
        if layout != .fill {
            if isOverlay {
                presentedStage = stage.dashedBorder(1.0, t.textSecondary.alpha(0.35), dash: 4.0, gap: 3.0)
            } else if frame != nil || preset != nil {
                presentedStage = stage.border(1.0, inner.separator)
            }
        }

        return col()
            .w(area.x)
            .h(area.y)
            .center()
            .bg(inner.bg)
            .clipRounded(0.0)
            .child(presentedStage)
    }

    private func legacyControlsForStage() -> PlaygroundControlValues {
        PlaygroundControlValues()
    }

    // MARK: - Resize Edges (`playground/widths.rs`)

    private func buildSidebarEdge(sidebarW: Float, viewport: Vec2) -> El<State> {
        let vw = viewport.x
        return el()
            .key("playground-sidebar-edge")
            .absolute(x: sidebarW - 3.0, y: 0.0)
            .w(7.0)
            .h(viewport.y)
            .cursor(.resizeColumn)
            .help("Drag to resize; double-click for the default width")
            .onDrag { [weak self] _, drag, tx in
                guard let self else { return }
                tx.instant()
                if !self.dragActiveSidebar {
                    self.dragActiveSidebar = true
                    self.dragStartSidebarW = PlaygroundControls.clampPair(
                        sidebar: self.controls.sidebarW,
                        side: self.controls.sideW,
                        viewportW: vw
                    ).0
                }
                let (_, clampedSide) = PlaygroundControls.clampPair(
                    sidebar: self.controls.sidebarW,
                    side: self.controls.sideW,
                    viewportW: vw
                )
                let maxW = min(PlaygroundConst.sidebarMax, max(PlaygroundConst.sidebarMin, vw - clampedSide - PlaygroundConst.stageMin - 2.0))
                self.controls.sidebarW = min(max(self.dragStartSidebarW + drag.delta.x, PlaygroundConst.sidebarMin), maxW).rounded()
            }
            .onDragEnd { [weak self] _, cancelled, tx in
                guard let self else { return }
                tx.instant()
                self.dragActiveSidebar = false
                if cancelled {
                    self.controls.sidebarW = self.dragStartSidebarW
                } else {
                    self.controls.saveWidths()
                }
            }
            .onDoubleClick { [weak self] _, tx in
                guard let self else { return }
                tx.instant()
                self.controls.sidebarW = PlaygroundConst.sidebar
                self.controls.saveWidths()
            }
    }

    private func buildSideEdge(sideW: Float, viewport: Vec2) -> El<State> {
        let vw = viewport.x
        return el()
            .key("playground-side-edge")
            .absolute(x: vw - sideW - 4.0, y: 0.0)
            .w(7.0)
            .h(viewport.y)
            .cursor(.resizeColumn)
            .help("Drag to resize; double-click for the default width")
            .onDrag { [weak self] _, drag, tx in
                guard let self else { return }
                tx.instant()
                if !self.dragActiveSide {
                    self.dragActiveSide = true
                    self.dragStartSideW = PlaygroundControls.clampPair(
                        sidebar: self.controls.sidebarW,
                        side: self.controls.sideW,
                        viewportW: vw
                    ).1
                }
                let (clampedSidebar, _) = PlaygroundControls.clampPair(
                    sidebar: self.controls.sidebarW,
                    side: self.controls.sideW,
                    viewportW: vw
                )
                let maxW = min(PlaygroundConst.sideMax, max(PlaygroundConst.sideMin, vw - clampedSidebar - PlaygroundConst.stageMin - 2.0))
                self.controls.sideW = min(max(self.dragStartSideW - drag.delta.x, PlaygroundConst.sideMin), maxW).rounded()
            }
            .onDragEnd { [weak self] _, cancelled, tx in
                guard let self else { return }
                tx.instant()
                self.dragActiveSide = false
                if cancelled {
                    self.controls.sideW = self.dragStartSideW
                } else {
                    self.controls.saveWidths()
                }
            }
            .onDoubleClick { [weak self] _, tx in
                guard let self else { return }
                tx.instant()
                self.controls.sideW = PlaygroundConst.side
                self.controls.saveWidths()
            }
    }
}
