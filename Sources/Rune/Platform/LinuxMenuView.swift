#if os(Linux)
import Foundation

extension LinuxApplicationMenu {
    static var barHeight: Float { 28 }
    static var barKey: String { "__rune_linux_menu_bar" }
    static func sectionKey(_ index: Int) -> String { "__rune_linux_menu_section_\(index)" }
    static func listKey(_ index: Int) -> String { "__rune_linux_menu_list_\(index)" }
    static func itemKey(_ id: String) -> String {
        let escaped = id.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "/", with: "%2F")
        return "__rune_linux_menu_item_\(escaped)"
    }

    func view(content: El<State>, in cx: inout Cx<State>) -> El<State> {
        guard !sections.isEmpty else { return content }
        let colors = Tok.theme(dark: cx.systemDark)
        let highlight = Tok.accent(0, dark: cx.systemDark).alpha(0.34)
        let triggers: [El<State>] = sections.indices.map { index in
            let title = sections[index].title
            let open = activeSection == index
            return row()
                .key(Self.sectionKey(index))
                .role(.menuItem).label(title).expanded(open)
                .px(10).h(Self.barHeight).shrink(0).center()
                .bg(open ? highlight : .transparent).hover(highlight)
                .child(text(title).font(Tok.Typography.body).noWrap().color(colors.text).a11yHidden())
                .onClick { [weak self] _ in self?.toggle(section: index) }
                .onPointerMove { [weak self] _, _, tx in
                    self?.hover(section: index)
                    tx.liveOnly()
                }
        }
        let bar: El<State> = row()
            .key(Self.barKey).role(.menuBar).label("Application menu")
            .wFull().h(Self.barHeight).shrink(0).scrollX().bg(colors.card)
            .borderSides(bottom: 1, color: colors.cardBorder)
            .children(triggers)
        var body: El<State> = col().wFull().clip().child(content)
        if !fitsContentHeight { body = body.grow().minH(0) }
        let window: El<State> = col().wFull().children([bar, body])
        guard let section = activeSection, sections.indices.contains(section) else { return window }

        let dismissArea: El<State> = el()
            .pin(top: Self.barHeight, right: 0, bottom: 0, left: 0)
            .z(Int.max - 1).focusable(false).a11yHidden()
            .onClick { [weak self] _ in self?.dismiss() }
        let menu = panel(section, colors: colors, highlight: highlight, viewportWidth: cx.viewport.x)
            .z(Int.max)
        return window.child(dismissArea).child(menu)
    }

    private func panel(_ section: Int, colors: ThemeTokens, highlight: Color, viewportWidth: Float) -> El<State> {
        let group = sections[section]
        let version = revision
        let rows: [El<State>] = group.items.enumerated().map { index, entry in
            if entry.isSeparator {
                return el().role(.separator).h(1).my(3).shrink(0).bg(colors.separator)
            }
            let appearance = LinuxMenuRow(title: entry.title, enabled: entry.enabled, checked: entry.checked,
                                          shortcut: entry.accelerator?.menuKeycaps(on: .linux).joined(separator: "+"))
            var item: El<State> = appearance.element(key: Self.itemKey(entry.id), highlighted: activeItem == index,
                                                     colors: colors, highlight: highlight)
            if entry.enabled {
                item = item.onClick { [weak self] _ in
                    self?.activate(section: section, item: index, revision: version)
                }.onPointerMove { [weak self] _, _, tx in
                    self?.hover(item: index)
                    tx.liveOnly()
                }
            }
            return item
        }
        let list: El<State> = col().key(Self.listKey(section)).minH(0).shrink(1).scrollY()
            .child(col().itemsStretch().p(4).children(rows))
        let width = max(0, viewportWidth - 16)
        return col().role(.menu).label(group.title)
            .minW(min(width, 160)).maxW(width).itemsStretch()
            .bg(colors.card).border(1, colors.cardBorder).rounded(Tok.Radius.sm)
            .shadow(Shadow(y: 3, blur: 8, color: colors.shadow))
            .onPointerDown { _, _, _ in }
            .child(list).anchoredFit(Self.sectionKey(section), side: .bottom, align: .start, gap: 0)
            .instantChanges()
    }
}

/// Display properties shared by application and contextual menu items.
struct LinuxMenuRow {
    static let height: Float = 28
    let title: String
    let enabled: Bool
    let checked: Bool
    let shortcut: String?
    var expanded: Bool? = nil

    func element<State>(key: String, highlighted: Bool, colors: ThemeTokens, highlight: Color) -> El<State> {
        let ink = enabled ? colors.text : colors.textSecondary
        let mark: El<State> = text(checked ? "✓" : "")
            .w(14).shrink(0).font(Tok.Typography.label).color(ink).a11yHidden()
        let label: El<State> = text(title)
            .font(Tok.Typography.body).noWrap().ellipsis().minW(0).color(ink).a11yHidden()
        var item: El<State> = row().key(key)
            .role(checked ? .menuItemCheckbox : .menuItem)
            .label(title).disabled(!enabled).tabIndex(-1)
            .h(Self.height).shrink(0).itemsCenter().px(8).gap(6).rounded(Tok.Radius.xs)
            .bg(highlighted ? highlight : .transparent)
            .child(mark).child(label)
        if checked { item = item.checked(true) }
        if let shortcut {
            item = item.shortcutHint(shortcut).child(el().grow())
                .child(text(shortcut).font(Tok.Typography.label).color(colors.textSecondary).noWrap().a11yHidden())
        }
        if let expanded {
            item = item.expanded(expanded).child(el().grow())
                .child(text(RuneLabels.shared.isRTL ? "‹" : "›").font(Tok.Typography.body).color(ink).a11yHidden())
        }
        return item
    }
}
#endif
