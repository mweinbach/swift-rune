import Foundation
import Rune
import RuneMotion

public enum BadgeTone: Sendable, Hashable {
    case neutral
    case accent
    case success
    case warning
    case danger
    case info
}

public struct TreeItem<ID: Hashable & Sendable & CustomStringConvertible>: Sendable {
    public var id: ID
    public var label: String
    public var isFolder: Bool
    public var children: [TreeItem<ID>]

    public init(id: ID, label: String, isFolder: Bool = false, children: [TreeItem<ID>] = []) {
        self.id = id
        self.label = label
        self.isFolder = isFolder || !children.isEmpty
        self.children = children
    }
}

public struct TableColumn<Row>: Sendable {
    public var title: String
    public var width: Float?
    public var grow: Float
    public var align: TextAlign
    public var cell: @Sendable (Row) -> String

    public init(
        title: String,
        width: Float? = nil,
        grow: Float = 1.0,
        align: TextAlign = .leading,
        cell: @escaping @Sendable (Row) -> String
    ) {
        self.title = title
        self.width = width
        self.grow = grow
        self.align = align
        self.cell = cell
    }
}

extension Kit {
    // MARK: - Text Inputs & Fields

    public func textInputField<State>(
        key: String,
        _ editKeyPath: WritableKeyPath<State, TextEdit>,
        placeholder placeholderText: String = "",
        leadingIcon: SVGIcon? = nil,
        invalid: Bool = false,
        onChange: ((inout State, String, inout Tx) -> Void)? = nil,
        onSubmit: ((inout State, String, inout Tx) -> Void)? = nil
    ) -> El<State> {
        let borderCol = invalid ? c.danger.border : c.borderBase
        let ringCol = invalid ? c.danger.fg : c.borderFocus

        var inputEl = Rune.textInput(key: key, editKeyPath)
            .grow(1)
            .py(6)
            .px(leadingIcon == nil ? 10 : 4)
            .font(ty.ui)
            .color(c.textBase)
            .placeholder(placeholderText, color: c.textFaint)
            .caret(c.bgAccent, selection: c.bgAccent.alpha(0.28))
            .focusRing(ringCol, offset: 1.0)

        if let onChange { inputEl = inputEl.onChange(onChange) }
        if let onSubmit { inputEl = inputEl.onSubmit(onSubmit) }

        var wrapper: El<State> = row()
            .key("\(key)-wrap")
            .wFull()
            .minH(34)
            .itemsCenter()
            .rounded(radius.md)
            .bg(c.surfaceWeak)
            .border(1.0, borderCol)

        if let svg = leadingIcon {
            wrapper = wrapper.child(
                row().pl(10).pr(4).center().child(icon(svg, size: 14).color(c.iconMuted))
            )
        }
        return wrapper.child(inputEl)
    }

    public func textArea<State>(
        key: String,
        _ editKeyPath: WritableKeyPath<State, TextEdit>,
        placeholder placeholderText: String = "",
        minHeight: Float = 84,
        invalid: Bool = false,
        onChange: ((inout State, String, inout Tx) -> Void)? = nil
    ) -> El<State> {
        let borderCol = invalid ? c.danger.border : c.borderBase
        var inputEl = Rune.textInput(key: key, editKeyPath)
            .wFull()
            .minH(minHeight)
            .p(10)
            .rounded(radius.md)
            .bg(c.surfaceWeak)
            .border(1.0, borderCol)
            .font(ty.body)
            .color(c.textBase)
            .placeholder(placeholderText, color: c.textFaint)
            .caret(c.bgAccent, selection: c.bgAccent.alpha(0.28))
            .focusRing(invalid ? c.danger.fg : c.borderFocus, offset: 1.0)

        if let onChange { inputEl = inputEl.onChange(onChange) }
        return inputEl
    }

    public func field<State>(
        label labelText: String,
        description: String? = nil,
        error: String? = nil,
        control: El<State>
    ) -> El<State> {
        var out: El<State> = col().wFull().gap(6)
        out = out.child(text(labelText).font(ty.uiMedium).color(c.textBase))
        out = out.child(control)
        if let error, !error.isEmpty {
            out = out.child(text(error).font(ty.small).color(c.danger.fg))
        } else if let description, !description.isEmpty {
            out = out.child(text(description).font(ty.small).color(c.textMuted))
        }
        return out
    }

    // MARK: - Badges, Dividers, Cards & Progress

    public func badge<State>(_ labelText: String, tone: BadgeTone = .neutral) -> El<State> {
        let (bgCol, fgCol, borderCol): (Color, Color, Color) = {
            switch tone {
            case .neutral: return (c.layer02, c.textMuted, c.borderMuted)
            case .accent: return (c.bgAccent.alpha(0.16), c.textAccent, c.bgAccent.alpha(0.35))
            case .success: return (c.success.bg, c.success.fg, c.success.border)
            case .warning: return (c.warning.bg, c.warning.fg, c.warning.border)
            case .danger: return (c.danger.bg, c.danger.fg, c.danger.border)
            case .info: return (c.info.bg, c.info.fg, c.info.border)
            }
        }()
        return row()
            .h(20)
            .px(8)
            .center()
            .pill()
            .bg(bgCol)
            .border(1.0, borderCol)
            .child(text(labelText).font(ty.smallMedium).color(fgCol).noWrap())
    }

    public func divider<State>() -> El<State> {
        rule(1.0, c.borderMuted)
    }

    public func card<State>(
        key: String? = nil,
        padding: Float = 16,
        _ content: El<State>
    ) -> El<State> {
        var box: El<State> = col()
            .p(padding)
            .rounded(radius.xl)
            .bg(c.surfaceRaised)
            .shadows(shadowLayers(elevation.raised))
            .child(content)
        if let key { box = box.key(key) }
        return box
    }

    public func progress<State>(
        key: String,
        fraction: Float,
        height: Float = 6
    ) -> El<State> {
        let clamped = fraction.clamped(to: 0...1)
        return row()
            .key(key)
            .role(.progress)
            .selected(String(format: "%.0f%%", clamped * 100))
            .wFull()
            .h(height)
            .pill()
            .bg(c.layer02)
            .clip(true)
            .child(
                el()
                    .key("\(key)-bar")
                    .wFrac(clamped)
                    .hFull()
                    .pill()
                    .bg(c.bgAccent)
                    .animateLayout(motion.disclosure)
            )
    }

    public func progressCircle<State>(
        key: String,
        fraction: Float,
        diameter: Float = 24,
        strokeWidth: Float = 2.5
    ) -> El<State> {
        let clamped = fraction.clamped(to: 0...1)
        let r = (diameter - strokeWidth) * 0.5
        let cPt = diameter * 0.5
        var circlePath = VectorPath()
        circlePath.arc(center: Vec2(cPt, cPt), radius: r, startAngle: -.pi * 0.5, endAngle: 1.5 * .pi)
        return el()
            .key(key)
            .role(.progress)
            .square(diameter)
            .shape(.stroke(circlePath, color: c.layer03, width: strokeWidth))
            .shape(.stroke(circlePath, color: c.bgAccent, width: strokeWidth).drawn(clamped))
    }

    // MARK: - Collapsible & Accordion

    public func collapsible<State>(
        key: String,
        title: String,
        isOpen: Bool,
        onToggle: @escaping (inout State, Bool) -> Void,
        content: () -> El<State>
    ) -> El<State> {
        let header: El<State> = row()
            .key("\(key)-header")
            .role(.button)
            .expanded(isOpen)
            .wFull()
            .py(8)
            .px(10)
            .itemsCenter()
            .justifyBetween()
            .rounded(radius.md)
            .hover(c.hover)
            .focusRing(c.borderFocus)
            .onClick { s, _ in onToggle(&s, !isOpen) }
            .child(text(title).font(ty.uiMedium).color(c.textBase))
            .child(
                icon(KitIcons.chevronRight, size: 14)
                    .key("\(key)-chevron")
                    .color(c.iconMuted)
                    .rotate(isOpen ? (.pi * 0.5) : 0)
                    .animate(motion.control)
            )

        var wrap: El<State> = col()
            .key(key)
            .wFull()
            .animateLayout(LayoutAnim.widthLeads(motion.disclosure))
            .child(header)

        if isOpen {
            wrap = wrap.child(
                col()
                    .key("\(key)-body")
                    .wFull()
                    .px(10)
                    .pb(8)
                    .transition(Transition.reveal(edge: .top).spring(motion.disclosure))
                    .child(content())
            )
        }
        return wrap
    }

    // MARK: - Select, Popover, Menu, Dialog & Toast

    public func select<State, ID: Hashable & CustomStringConvertible>(
        key: String,
        options: [(id: ID, label: String)],
        selected: ID,
        isOpen: Bool,
        onToggleOpen: @escaping (inout State, Bool) -> Void,
        onSelect: @escaping (inout State, ID) -> Void
    ) -> El<State> {
        let currentLabel = options.first(where: { $0.id == selected })?.label ?? ""

        let trigger: El<State> = row()
            .key("\(key)-trigger")
            .role(.button)
            .expanded(isOpen)
            .wFull()
            .h(32)
            .px(10)
            .itemsCenter()
            .justifyBetween()
            .rounded(radius.md)
            .bg(c.bgButtonNeutral)
            .border(1.0, isOpen ? c.borderFocus : c.borderBase)
            .hover(c.hover)
            .focusRing(c.borderFocus)
            .onClick { s, _ in onToggleOpen(&s, !isOpen) }
            .child(text(currentLabel).font(ty.ui).color(c.textBase).ellipsis())
            .child(icon(KitIcons.chevronDown, size: 14).color(c.iconMuted))

        var root: El<State> = col().key(key).wFull().child(trigger)

        if isOpen {
            var menuList: El<State> = col()
                .key("\(key)-menu")
                .role(.menu)
                .pin(top: 36, right: 0, left: 0)
                .p(4)
                .gap(2)
                .rounded(radius.lg)
                .bg(c.surfaceRaised)
                .shadows(shadowLayers(elevation.floating))
                .z(50)
                .focusGroup(true)
                .transition(Transition.scale(0.96).kitRules().spring(motion.overlay))

            for opt in options {
                let isSel = (opt.id == selected)
                let item: El<State> = row()
                    .key("\(key)-opt-\(opt.id)")
                    .role(.menuItem)
                    .itemSelected(isSel)
                    .wFull()
                    .h(28)
                    .px(8)
                    .itemsCenter()
                    .justifyBetween()
                    .rounded(radius.sm)
                    .bg(isSel ? c.hover : .transparent)
                    .hover(c.hover)
                    .focusRing(c.borderFocus)
                    .onClick { s, _ in
                        onSelect(&s, opt.id)
                        onToggleOpen(&s, false)
                    }
                    .child(text(opt.label).font(isSel ? ty.uiMedium : ty.ui).color(c.textBase))
                    .child(isSel ? icon(KitIcons.check, size: 13).color(c.textAccent) : nil)

                menuList = menuList.child(item)
            }
            root = root.child(menuList)
        }
        return root
    }

    /// Modal dialog overlay trapping keyboard focus & pointer events (`Kit::dialog`).
    public func dialog<State>(
        key: String,
        title: String,
        description: String? = nil,
        maxWidth: Float = 420,
        onDismiss: @escaping (inout State) -> Void,
        body: El<State>,
        footer: El<State>? = nil
    ) -> El<State> {
        var sheet: El<State> = col()
            .key("\(key)-sheet")
            .role(.dialog)
            .label(title)
            .modal(true)
            .focusable(true)
            .autofocus(true)
            .wFull()
            .maxW(maxWidth)
            .p(20)
            .gap(14)
            .rounded(radius.xl)
            .bg(c.surfaceRaised)
            .shadows(shadowLayers(elevation.overlay))
            .transition(Transition.scale(0.95).kitRules().spring(motion.overlay))
            .onKey { s, ev, _ in
                if ev.key == .escape {
                    onDismiss(&s)
                    return true
                }
                return false
            }

        let header: El<State> = row()
            .wFull()
            .itemsCenter()
            .justifyBetween()
            .child(text(title).font(ty.bodyMedium).size(16).semibold().color(c.textBase))
            .child(
                iconButton(key: "\(key)-close", svg: KitIcons.close, label: "Close", size: .sm) { s, _ in
                    onDismiss(&s)
                }
            )
        sheet = sheet.child(header)

        if let description {
            sheet = sheet.child(text(description).font(ty.ui).color(c.textMuted))
        }
        sheet = sheet.child(body)
        if let footer {
            sheet = sheet.child(footer)
        }

        return row()
            .key(key)
            .pin(top: 0, right: 0, bottom: 0, left: 0)
            .p(24)
            .center()
            .bg(c.scrim)
            .z(100)
            .transition(Transition.opacity.spring(motion.overlay))
            .child(sheet)
    }

    public func toast<State>(
        key: String,
        message: String,
        tone: BadgeTone = .neutral,
        onDismiss: ((inout State) -> Void)? = nil
    ) -> El<State> {
        let (bgCol, fgCol, borderCol, leadingSvg): (Color, Color, Color, SVGIcon?) = {
            switch tone {
            case .neutral: return (c.surfaceRaised, c.textBase, c.borderBase, nil)
            case .accent: return (c.surfaceRaised, c.textBase, c.bgAccent.alpha(0.45), KitIcons.info)
            case .success: return (c.success.bg, c.success.fg, c.success.border, KitIcons.check)
            case .warning: return (c.warning.bg, c.warning.fg, c.warning.border, KitIcons.info)
            case .danger: return (c.danger.bg, c.danger.fg, c.danger.border, KitIcons.circleX)
            case .info: return (c.info.bg, c.info.fg, c.info.border, KitIcons.info)
            }
        }()

        var bar: El<State> = row()
            .key(key)
            .px(14)
            .py(10)
            .gap(10)
            .itemsCenter()
            .rounded(radius.lg)
            .bg(bgCol)
            .border(1.0, borderCol)
            .shadows(shadowLayers(elevation.floating))
            .transition(Transition.push(from: .bottom).spring(motion.overlay))

        if let leadingSvg {
            let iconColor = (tone == .accent) ? c.textAccent : fgCol
            bar = bar.child(icon(leadingSvg, size: 15).color(iconColor))
        }
        bar = bar.child(text(message).font(ty.uiMedium).color(fgCol))

        if let onDismiss {
            bar = bar.child(
                iconButton(key: "\(key)-dismiss", svg: KitIcons.close, label: "Dismiss", size: .sm) { s, _ in
                    onDismiss(&s)
                }
            )
        }
        return bar
    }

    // MARK: - App Shell (`sidebar`, `toolbar`, `splitView`), `tree` & `table`

    public func splitView<State>(
        sidebarWidth: Float = 220,
        sidebar: El<State>,
        detail: El<State>
    ) -> El<State> {
        row()
            .sizeFull()
            .bg(c.page)
            .child(
                col()
                    .w(sidebarWidth)
                    .hFull()
                    .shrink(0)
                    .bg(c.layer01)
                    .borderSides(right: 1.0, color: c.borderMuted)
                    .child(sidebar)
            )
            .child(
                col()
                    .grow(1)
                    .minW(0)
                    .hFull()
                    .bg(c.page)
                    .child(detail)
            )
    }

    public func toolbar<State>(title: String, trailing: El<State>? = nil) -> El<State> {
        row()
            .wFull()
            .h(46)
            .px(16)
            .itemsCenter()
            .justifyBetween()
            .bg(c.page)
            .borderSides(bottom: 1.0, color: c.borderMuted)
            .child(text(title).font(ty.uiMedium).semibold().color(c.textBase))
            .child(trailing)
    }

    public func tree<State, ID: Hashable & Sendable & CustomStringConvertible>(
        key: String,
        roots: [TreeItem<ID>],
        expanded: Set<ID>,
        selected: ID?,
        onToggleExpand: @escaping (inout State, ID) -> Void,
        onSelect: @escaping (inout State, ID) -> Void
    ) -> El<State> {
        var list: El<State> = col().key(key).wFull().gap(2).focusGroup(true)

        func emit(_ item: TreeItem<ID>, depth: Int) {
            let isExp = expanded.contains(item.id)
            let isSel = (selected == item.id)
            let indent = Float(depth) * 14.0 + 8.0

            var rowEl: El<State> = row()
                .key("\(key)-\(item.id)")
                .role(.listItem)
                .itemSelected(isSel)
                .expanded(item.isFolder ? isExp : nil)
                .wFull()
                .h(28)
                .pl(indent)
                .pr(8)
                .gap(6)
                .itemsCenter()
                .rounded(radius.sm)
                .bg(isSel ? c.bgAccent.alpha(0.16) : .transparent)
                .hover(c.hover)
                .focusRing(c.borderFocus)
                .onClick { s, _ in
                    onSelect(&s, item.id)
                    if item.isFolder {
                        onToggleExpand(&s, item.id)
                    }
                }

            if item.isFolder {
                rowEl = rowEl
                    .child(
                        icon(KitIcons.chevronRight, size: 12)
                            .color(c.iconMuted)
                            .rotate(isExp ? .pi * 0.5 : 0)
                            .animate(motion.control)
                    )
                    .child(icon(KitIcons.folder, size: 14).color(isSel ? c.textAccent : c.iconMuted))
            } else {
                rowEl = rowEl
                    .child(el().w(12).h(12))
                    .child(icon(KitIcons.file, size: 14).color(isSel ? c.textAccent : c.iconFaint))
            }

            rowEl = rowEl.child(
                text(item.label)
                    .font(isSel ? ty.uiMedium : ty.ui)
                    .color(isSel ? c.textAccent : c.textBase)
                    .ellipsis()
            )
            list = list.child(rowEl)

            if item.isFolder && isExp {
                for child in item.children {
                    emit(child, depth: depth + 1)
                }
            }
        }

        for root in roots {
            emit(root, depth: 0)
        }
        return list
    }

    public func table<State, Row>(
        key: String,
        columns: [TableColumn<Row>],
        rows: [Row]
    ) -> El<State> {
        var headerRow: El<State> = row()
            .wFull()
            .h(32)
            .px(12)
            .itemsCenter()
            .bg(c.layer01)
            .borderSides(bottom: 1.0, color: c.borderBase)

        for colSpec in columns {
            var hCell: El<State> = row().px(6).itemsCenter()
            if let w = colSpec.width {
                hCell = hCell.w(w).shrink(0)
            } else {
                hCell = hCell.grow(colSpec.grow).minW(0)
            }
            hCell = hCell.child(
                text(colSpec.title)
                    .font(ty.smallMedium)
                    .color(c.textMuted)
                    .textAlign(colSpec.align)
                    .ellipsis()
            )
            headerRow = headerRow.child(hCell)
        }

        var bodyCol: El<State> = col().wFull()
        for (rIdx, rowData) in rows.enumerated() {
            var rEl: El<State> = row()
                .key("\(key)-row-\(rIdx)")
                .wFull()
                .minH(34)
                .px(12)
                .py(6)
                .itemsCenter()
                .hover(c.hover)

            if rIdx + 1 < rows.count {
                rEl = rEl.borderSides(bottom: 1.0, color: c.borderMuted)
            }

            for colSpec in columns {
                var cEl: El<State> = row().px(6).itemsCenter()
                if let w = colSpec.width {
                    cEl = cEl.w(w).shrink(0)
                } else {
                    cEl = cEl.grow(colSpec.grow).minW(0)
                }
                cEl = cEl.child(
                    text(colSpec.cell(rowData))
                        .font(ty.ui)
                        .color(c.textBase)
                        .textAlign(colSpec.align)
                        .ellipsis()
                )
                rEl = rEl.child(cEl)
            }
            bodyCol = bodyCol.child(rEl)
        }

        return col()
            .key(key)
            .wFull()
            .rounded(radius.lg)
            .bg(c.surfaceRaised)
            .border(1.0, c.borderBase)
            .clip(true)
            .child(headerRow)
            .child(bodyCol)
    }
}
