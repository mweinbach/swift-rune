#if os(Linux)
import RuneMotion

extension LinuxContextMenu {
    func view(content: El<State>, in cx: inout Cx<State>, fitsContentHeight: Bool) -> El<State> {
        // The window and its overlays are siblings. Keep the authored root mounted
        // and preserve its viewport sizing and intrinsic height in both layout passes.
        let viewport = cx.viewport
        var body = content
        if body.layout.width == .auto { body = body.wFull() }
        if body.layout.height == .auto && !fitsContentHeight { body = body.hFull() }
        // Margins, flex-item sizing, and positioning relative to a parent have no
        // effect on a root layout. Putting it in the window must preserve that rule.
        body.layout.margin = .all(0)
        body.layout.flexGrow = 0
        body.layout.flexShrink = 0
        body.layout.flexBasis = .auto
        body.layout.alignSelf = .start
        body.layout.isAbsolute = false
        body.layout.pinLeft = nil
        body.layout.pinRight = nil
        body.layout.pinTop = nil
        body.layout.pinBottom = nil
        let window = col().wFull().child(body)
        guard let show, !levels.isEmpty else { return window }

        let version = generation
        let scrim: El<State> = el().pin(top: 0, right: 0, bottom: 0, left: 0)
            .a11yHidden().focusable(false).pointerButtons([.primary, .middle, .back, .forward])
            .onClick { [weak self] _ in self?.dismiss(generation: version) }
            .onSecondaryClick { [weak self] _, _, _ in self?.dismiss(generation: version) }
            .onWheel { _, _, _ in true }
        var overlay: El<State> = el().key("__rune_linux_context_overlay")
            .absolute(x: 0, y: 0).size(viewport.x, viewport.y).z(Int.max)
            .modal().unmirrored().child(scrim)
        let rtl = RuneLabels.shared.isRTL
        let placement = show.placement(isRTL: rtl)
        let margin = min(8, min(viewport.x, viewport.y) / 2)
        let available = Vec2(max(0, viewport.x - 2 * margin), max(0, viewport.y - 2 * margin))
        let colors = Tok.theme(dark: cx.systemDark)
        let highlight = Tok.accent(0, dark: cx.systemDark).alpha(0.34)
        var previous = MotionRect.zero
        for (depth, level) in levels.enumerated() {
            let expanded = depth + 1 < levels.count ? levels[depth + 1].parentRow : nil
            let rows = level.menu.entries.enumerated().map { index, entry in
                LinuxMenuRow(popupEntry: entry, expanded: expanded == index)
            }
            let height = min(available.y, rows.reduce(8) { $0 + ($1 == nil ? 7 : LinuxMenuRow.height) })
            var width = min(available.x, depth == 0 ? max(144, placement.minWidth) : 128)
            for case let row? in rows where width < available.x {
                width = min(available.x, max(width, row.popupWidth))
            }
            var x = rtl ? placement.at.x - width : placement.at.x
            var y = placement.at.y
            if depth > 0, let parentIndex = level.parentRow {
                let parentKey = Self.rowKey(levels[depth - 1].token, parentIndex)
                let rect = cx.layout(parentKey)
                y = (rect?[1] ?? previous.top + 4) - 4
                let right = previous.right
                let left = previous.left - width
                // Choose the opening side with room, then overlap the parent if the window is narrow.
                x = rtl ? left : right
                if rtl && left < margin { x = right }
                if !rtl && right + width > viewport.x - margin { x = left }
            } else if let id = placement.positionedId,
                      let selected = level.menu.entries.firstIndex(where: {
                          if case .item(let item) = $0 { return item.id == id }
                          return false
                      }) {
                y -= rows.prefix(selected).reduce(4) { $0 + ($1 == nil ? 7 : LinuxMenuRow.height) }
            } else if y + height > viewport.y - margin {
                let top: Float
                if case .rect(let rect) = show.anchor { top = rect.top } else { top = y }
                if top - height >= margin { y = top - height }
            }
            x = min(max(x, margin), viewport.x - width - margin)
            y = min(max(y, margin), viewport.y - height - margin)
            previous = .fromXYWH(x, y, width, height)
            let panel = panel(level, depth: depth, rows: rows, colors: colors, highlight: highlight)
                .dir(rtl ? .rtl : .ltr).absolute(x: x, y: y).size(width, height)
            overlay = overlay.child(panel)
        }
        return window.child(overlay)
    }

    private func panel(_ level: LinuxPopupLevel, depth: Int, rows: [LinuxMenuRow?],
                       colors: ThemeTokens, highlight: Color) -> El<State> {
        let token = level.token
        let entries: [El<State>] = rows.enumerated().map { index, row in
            guard let row else {
                return el().role(.separator).h(1).my(3).shrink(0).bg(colors.separator)
            }
            var item: El<State> = row.element(key: Self.rowKey(token, index), highlighted: level.highlighted == index,
                                               colors: colors, highlight: highlight)
            if row.enabled {
                item = item.onClick { [weak self] _ in self?.activate(level: depth, row: index, generation: token) }
                    .onPointerMove { [weak self] _, _, tx in
                        self?.hover(level: depth, row: index, generation: token)
                        tx.liveOnly()
                    }
            }
            return item
        }
        return col().key(Self.listKey(token)).role(.menu).label(level.title)
            .focusable(true).tabIndex(-1).itemsStretch().scrollY()
            .bg(colors.card).border(1, colors.cardBorder).rounded(Tok.Radius.sm)
            .shadow(Shadow(y: 3, blur: 8, color: colors.shadow))
            .onPointerDown { _, _, _ in }.onSecondaryClick { _, _, _ in }
            .child(col().itemsStretch().p(4).children(entries)).instantChanges()
    }
}

private extension LinuxMenuRow {
    init?(popupEntry: PopupMenuEntry, expanded: Bool) {
        switch popupEntry {
        case .item(let item):
            let hint = item.keyEquivalent.flatMap { Chord(parsing: $0)?.menuKeycaps(on: .linux).joined(separator: "+") }
            self.init(title: item.title, enabled: item.enabled, checked: item.checked, shortcut: hint)
        case .submenu(let title, _, let enabled):
            self.init(title: title, enabled: enabled, checked: false, shortcut: nil, expanded: expanded)
        case .separator:
            return nil
        }
    }

    var popupWidth: Float {
        // Outer padding (8), row padding (16), checkmark (14) and a six-point gap.
        var width = 44 + TextMeasure.measure(title, style: Tok.Typography.body).x
        if let shortcut { width += 12 + TextMeasure.measure(shortcut, style: Tok.Typography.label).x }
        if expanded != nil { width += 12 + TextMeasure.measure("›", style: Tok.Typography.body).x }
        return width.rounded(.up)
    }
}
#endif
