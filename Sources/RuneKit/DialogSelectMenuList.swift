import Foundation
import Rune

// MARK: - Select (`rune_kit::select`)

/// Trigger style for `Select` (`rune_kit::select::SelectAppearance`).
public enum SelectAppearance: String, Sendable, Hashable {
    /// Borderless inline trigger, 24pt tall.
    case inline
    /// Field trigger (default 280pt wide, 28pt tall).
    case field
}

/// Option picker button and virtualised modal listbox (`rune_kit::select::Select`).
public struct Select<State> {
    public static var listboxMaxHeight: Float { 4.0 + 6.0 * 30.0 + 22.0 }

    private let key: String
    private var options: [(group: String?, label: String)]
    private var optionDetails: [String?] = []
    private var widthValue: Float = 280.0
    private var currentValue: String?
    private var placeholderText: String = ""
    private var a11yName: String?
    private var isOpen: Bool = false
    private var isInvalid: Bool = false
    private var controlState: ControlVisualState = .rest
    private var appearanceStyle: SelectAppearance = .inline
    private var highlightedOption: String?
    private var placementValue: Placement = .bottomEnd
    private var chooseHandler: ((inout State, String, inout Tx) -> Void)?
    private var toggleHandler: ((inout State, inout Tx) -> Void)?
    private var closeHandler: ((inout State, inout Tx) -> Void)?

    public init(_ key: String, options: [String]) {
        self.key = key
        self.options = options.map { (nil, $0) }
    }

    public static func grouped(_ key: String, options: [(String, String)]) -> Select<State> {
        var s = Select<State>(key, options: [])
        s.options = options.map { ($0.0, $0.1) }
        return s
    }

    public func details(_ d: [String?]) -> Select<State> {
        var copy = self
        copy.optionDetails = d
        return copy
    }

    public func width(_ w: Float) -> Select<State> {
        var copy = self
        copy.widthValue = w
        return copy
    }

    public func current(_ c: String?) -> Select<State> {
        var copy = self
        copy.currentValue = c
        return copy
    }

    public func placeholder(_ p: String) -> Select<State> {
        var copy = self
        copy.placeholderText = p
        return copy
    }

    public func label(_ l: String) -> Select<State> {
        var copy = self
        copy.a11yName = l
        return copy
    }

    public func open(_ o: Bool) -> Select<State> {
        var copy = self
        copy.isOpen = o
        return copy
    }

    public func invalid(_ i: Bool = true) -> Select<State> {
        var copy = self
        copy.isInvalid = i
        return copy
    }

    public func appearance(_ a: SelectAppearance) -> Select<State> {
        var copy = self
        copy.appearanceStyle = a
        return copy
    }

    public func highlighted(_ h: String?) -> Select<State> {
        var copy = self
        copy.highlightedOption = h
        return copy
    }

    public func placement(_ p: Placement) -> Select<State> {
        var copy = self
        copy.placementValue = p
        return copy
    }

    public func state(_ s: ControlVisualState) -> Select<State> {
        var copy = self
        copy.controlState = s
        return copy
    }

    public func disabled(_ d: Bool = true) -> Select<State> {
        var copy = self
        if d { copy.controlState = .disabled }
        return copy
    }

    public func onToggle(_ f: @escaping (inout State) -> Void) -> Select<State> {
        var copy = self
        copy.toggleHandler = { s, _ in f(&s) }
        return copy
    }

    public func onToggleTx(_ f: @escaping (inout State, inout Tx) -> Void) -> Select<State> {
        var copy = self
        copy.toggleHandler = f
        return copy
    }

    public func onClose(_ f: @escaping (inout State) -> Void) -> Select<State> {
        var copy = self
        copy.closeHandler = { s, _ in f(&s) }
        return copy
    }

    public func onChoose(_ f: @escaping (inout State, String, inout Tx) -> Void) -> Select<State> {
        var copy = self
        copy.chooseHandler = f
        return copy
    }

    /// Builds only the trigger button (for custom menus or `Combobox`).
    public func trigger(kit k: Kit) -> El<State> {
        buildTrigger(kit: k)
    }

    public func build(kit k: Kit, layer: inout [El<State>], cx: Cx<State>? = nil) -> El<State> {
        let triggerEl = buildTrigger(kit: k)
        let disabled = controlState == .disabled
        guard !disabled && isOpen else {
            return triggerEl
        }

        let c = k.c
        let anchorKey = "\(key)-trigger"
        let closeCb = closeHandler
        let chooseCb = chooseHandler
        let opts = options

        var list: El<State> = col().key("rows").p(4.0).itemsStretch()
        var currentGroup: String? = nil
        var afterItem = false
        let weakText = c.textWeak.a > 0 ? c.textWeak : c.textMuted

        for (i, entry) in options.enumerated() {
            if entry.group != currentGroup {
                currentGroup = entry.group
                if let g = currentGroup {
                    list = list.child(
                        row()
                            .key("group\(i)")
                            .h(28.0)
                            .px(12.0)
                            .itemsCenter()
                            .child(text(g).font(k.ty.smallMedium).color(c.textFaint))
                    )
                    afterItem = false
                }
            }

            let isSel = currentValue == entry.label
            let isHL = highlightedOption == entry.label
            let optKey = "option\(i)"

            var item: El<State> = row()
                .key(optKey)
                .role(.option)
                .focusable(true)
                .itemSelected(isSel)
                .positionInSet(i + 1, size: opts.count)
                .autofocus(isSel || (currentValue == nil && i == 0))
                .label(entry.label)
                .h(28.0)
                .pl(12.0)
                .pr(6.0)
                .gap(8.0)
                .itemsCenter()
                .rounded(4.0)
                .mt(afterItem ? 2.0 : 0.0)
                .bg(isHL ? c.hover : .transparent)
                .hover(c.hover)
                .focusRing(c.borderFocus)
                .child(text(entry.label).key("label").font(k.ty.uiCompact).color(c.textBase).grow(1.0).shrink(1.0).ellipsis().a11yHidden())
                .child(
                    el()
                        .key("indicator")
                        .size(16.0, 16.0)
                        .center()
                        .a11yHidden()
                        .child(icon(KitIcons.checkSmall, size: 14.0).color(c.iconBase).opacity(isSel ? 1.0 : 0.0))
                )

            if i < optionDetails.count, let desc = optionDetails[i] {
                item = item.description(desc)
            }

            let optVal = entry.label
            item = item
                .onClick { s, tx in
                    chooseCb?(&s, optVal, &tx)
                    tx.focus(anchorKey)
                }
                .onKey { s, ev, tx in
                    switch ev.key {
                    case .enter, .space, .text(" "):
                        chooseCb?(&s, optVal, &tx)
                        tx.focus(anchorKey)
                        return true
                    case .arrowDown:
                        if opts.count > 0 {
                            tx.focus("option\((i + 1) % opts.count)")
                        }
                        return true
                    case .arrowUp:
                        if opts.count > 0 {
                            tx.focus("option\((i - 1 + opts.count) % opts.count)")
                        }
                        return true
                    case .escape:
                        closeCb?(&s, &tx)
                        tx.focus(anchorKey)
                        return true
                    case .tab where !ev.mods.cmd && !ev.mods.ctrl && !ev.mods.alt:
                        return closeCb != nil
                    case .text(let ch) where !ev.mods.cmd && !ev.mods.ctrl && !ev.mods.alt:
                        let needle = ch.lowercased()
                        if let matchIdx = (1...opts.count).map({ (i + $0) % opts.count }).first(where: {
                            opts[$0].label.lowercased().hasPrefix(needle)
                        }) {
                            tx.focus("option\(matchIdx)")
                            return true
                        }
                        return false
                    default:
                        return false
                    }
                }

            list = list.child(item)
            afterItem = true
        }

        let boxName = a11yName ?? placeholderText
        let listbox: El<State> = col()
            .key("listbox")
            .role(.listbox)
            .label(boxName)
            .focusGroup(true)
            .maxH(Self.listboxMaxHeight)
            .minH(0.0)
            .shrink(1.0)
            .child(PopoverAnchor.fitScroll(list))

        var content: El<State> = col()
            .key("\(key)-content")
            .role(.dialog)
            .label(boxName)
            .minW(160.0)
            .maxW(368.0)
            .child(listbox)

        let _ = weakText
        if let closeCb {
            content = content
                .onKey { s, ev, tx in
                    if ev.key == .escape {
                        closeCb(&s, &tx)
                        tx.focus(anchorKey)
                        return true
                    }
                    return false
                }
            let surface: El<State> = content
                .rounded(6.0)
                .bg(k.c.layer01)
                .shadows(k.shadowLayers(k.elevation.floating))
                .onPointerDown { _, _, _ in }
            let anchoredSurface = PopoverAnchor.anchored(
                k,
                surface,
                anchor: anchorKey,
                placement: placementValue,
                gap: 2.0,
                window: cx?.viewport
            )
            let scrimEl: El<State> = el()
                .key("\(key)-scrim")
                .absolute(x: 0.0, y: 0.0)
                .wFull()
                .hFull()
                .a11yHidden()
                .onClick { s, tx in
                    closeCb(&s, &tx)
                    tx.focus(anchorKey)
                }
                .focusable(false)
            layer.append(PopoverAnchor.modalOverlay(key: key, z: 60, scrim: scrimEl, content: anchoredSurface))
        } else {
            let surface: El<State> = content
                .rounded(6.0)
                .bg(k.c.layer01)
                .shadows(k.shadowLayers(k.elevation.floating))
                .onPointerDown { _, _, _ in }
            layer.append(
                PopoverAnchor.anchored(k, surface, anchor: anchorKey, placement: placementValue, gap: 2.0, window: cx?.viewport)
            )
        }
        return triggerEl
    }

    private func buildTrigger(kit k: Kit) -> El<State> {
        let c = k.c
        let disabled = controlState == .disabled
        let anchorKey = "\(key)-trigger"
        let red = isInvalid && !disabled
        let labelText = currentValue ?? placeholderText
        let ink: Color = if red {
            c.danger.fg
        } else if currentValue != nil {
            c.textBase
        } else {
            c.textFaint
        }
        let chevron = isOpen ? KitIcons.chevronUp : KitIcons.chevronDown
        let name = a11yName ?? placeholderText

        var trigger: El<State> = row()
            .key(anchorKey)
            .role(.combobox)
            .label(name)
            .expanded(isOpen)
            .disabled(disabled)
            .inert(disabled)
            .itemsCenter()
            .focusable(!disabled)

        if let currentValue {
            trigger = trigger.a11yValue(currentValue)
        }

        switch appearanceStyle {
        case .inline:
            let font = k.ty.uiMedium.lh(16.0)
            let isHover = controlState == .hover || isOpen
            trigger = trigger
                .h(24.0)
                .pl(8.0)
                .pr(4.0)
                .py(4.0)
                .gap(4.0)
                .rounded(k.radius.sm)
                .child(text(labelText).key("value").font(font).color(ink).ellipsis().a11yHidden())
                .child(icon(chevron, size: 16.0).key("chevron").color(c.iconMuted).a11yHidden())
            if isHover {
                trigger = trigger.bg(c.hover)
            } else if controlState == .pressed {
                trigger = trigger.bg(c.pressed)
            } else if !disabled {
                trigger = trigger.hover(c.hover).press(c.pressed)
            }

        case .field:
            let bgColor = (isOpen || controlState == .hover) ? Tok.forBlend(c.hover, over: c.bgBase) : c.bgBase
            trigger = trigger
                .w(widthValue)
                .h(28.0)
                .pr(6.0)
                .gap(8.0)
                .rounded(k.radius.md)
                .bg(bgColor)
                .child(
                    row()
                        .key("value")
                        .grow(1.0)
                        .shrink(1.0)
                        .pl(8.0)
                        .a11yHidden()
                        .child(text(labelText).font(k.ty.uiCompact).color(ink).ellipsis().a11yHidden())
                )
                .child(
                    el()
                        .size(20.0, 20.0)
                        .center()
                        .a11yHidden()
                        .child(icon(chevron, size: 16.0).key("chevron").color(c.iconMuted))
                )

            if isInvalid && !disabled {
                trigger = trigger.border(1.0, c.danger.fg)
            } else if controlState == .focus && !isOpen {
                trigger = trigger.border(1.0, c.borderFocus)
            } else {
                let elev = k.elevation.input.isEmpty ? k.elevation.buttonNeutral : k.elevation.input
                trigger = trigger.shadows(k.shadowLayers(elev))
                if !isOpen {
                    trigger = trigger.focusRing(c.borderFocus, offset: 0.0)
                }
                if controlState == .rest && !isOpen && !disabled {
                    trigger = trigger.hover(c.hover)
                }
            }
        }

        if disabled {
            return trigger.opacity(0.5)
        }

        let toggleCb = toggleHandler
        let selectedIndex = currentValue.flatMap { cur in options.firstIndex { $0.label == cur } } ?? 0
        if let toggleCb {
            trigger = trigger
                .onClick { s, tx in
                    toggleCb(&s, &tx)
                }
                .onKey { s, ev, tx in
                    switch ev.key {
                    case .arrowDown, .arrowUp, .space, .enter, .text(" "):
                        toggleCb(&s, &tx)
                        tx.focus("option\(selectedIndex)")
                        return true
                    default:
                        return false
                    }
                }
        }
        return trigger
    }
}

// MARK: - Dialog (`rune_kit::dialog`)

/// Modal dialog surface trapping focus and supporting click-outside/Escape dismissal
/// (`rune_kit::dialog::Dialog`).
public struct Dialog<State> {
    private let key: String
    private let titleText: String
    private var descriptionText: String?
    private var body: [El<State>] = []
    private var isOpen: Bool = false
    private var outsideDismiss: Bool = true
    private var widthValue: Float = 480.0
    private var fitContent: Bool = false
    private var closeHandler: ((inout State, inout Tx) -> Void)?

    public init(_ key: String, _ title: String) {
        self.key = key
        self.titleText = title
    }

    public func open(_ o: Bool) -> Dialog<State> {
        var copy = self
        copy.isOpen = o
        return copy
    }

    public func description(_ d: String) -> Dialog<State> {
        var copy = self
        copy.descriptionText = d
        return copy
    }

    public func child(_ b: El<State>) -> Dialog<State> {
        var copy = self
        copy.body.append(b)
        return copy
    }

    public func width(_ w: Float) -> Dialog<State> {
        var copy = self
        copy.widthValue = w
        return copy
    }

    public func fit() -> Dialog<State> {
        var copy = self
        copy.fitContent = true
        return copy
    }

    public func clickOutside(_ on: Bool) -> Dialog<State> {
        var copy = self
        copy.outsideDismiss = on
        return copy
    }

    public func onClose(_ f: @escaping (inout State) -> Void) -> Dialog<State> {
        var copy = self
        copy.closeHandler = { s, _ in f(&s) }
        return copy
    }

    public func onCloseTx(_ f: @escaping (inout State, inout Tx) -> Void) -> Dialog<State> {
        var copy = self
        copy.closeHandler = f
        return copy
    }

    public func build(kit k: Kit, layer: inout [El<State>]) {
        guard isOpen, let closeHandler else { return }

        let closeBtn: El<State> = k.iconButton(
            key: "\(key)-close",
            svg: KitIcons.close,
            label: "Close",
            size: .sm,
            variant: .ghost
        ) { s, tx in
            closeHandler(&s, &tx)
        }
        .key("close")
        .autofocus(true)
        .size(20.0, 20.0)
        .mt(-2.0)
        .mr(-2.0)

        let titleFont: TextStyle = if descriptionText != nil {
            TextStyle(size: 15.0, weight: 500.0).lh(20.0)
        } else {
            k.ty.uiMedium.lh(16.0)
        }

        var titleCol: El<State> = col()
            .grow(1.0)
            .gap(4.0)
            .child(text(titleText).font(titleFont).color(k.c.textBase).a11yHidden())

        if let desc = descriptionText {
            titleCol = titleCol.child(text(desc).font(k.ty.ui.lh(20.0)).color(k.c.textMuted).a11yHidden())
        }

        var bodyCol: El<State> = col().key("body").wFull()
        for b in body {
            bodyCol = bodyCol.child(b)
        }

        var panel: El<State> = fitContent ? col() : col().h(368.0)
        bodyCol = fitContent ? bodyCol : bodyCol.grow(1.0)

        panel = panel
            .key("\(key)-dialog")
            .role(.dialog)
            .label(titleText)
            .modalTx(clickOutside: outsideDismiss, dismiss: closeHandler)
            .wFull()
            .maxW(widthValue)
            .rounded(6.0)
            .bg(k.c.layer01)
            .shadows(k.shadowLayers(k.elevation.overlay))
            .animate(k.motion.overlay)
            .child(
                row()
                    .key("header")
                    .wFull()
                    .p(16.0)
                    .itemsStart()
                    .child(titleCol)
                    .child(closeBtn)
            )
            .child(bodyCol)
            .onPointerDown { _, _, _ in }
            .onKey { s, ev, tx in
                if ev.key == .escape {
                    closeHandler(&s, &tx)
                    return true
                }
                return false
            }

        if let desc = descriptionText {
            panel = panel.description(desc)
        }

        var scrim: El<State> = el()
            .key("\(key)-scrim")
            .absolute(x: 0.0, y: 0.0)
            .wFull()
            .hFull()
            .bg(k.c.scrim)
            .animate(k.motion.overlay)
            .a11yHidden()

        if outsideDismiss {
            scrim = scrim.onClick { s, tx in
                closeHandler(&s, &tx)
            }
            .focusable(false)
        } else {
            scrim = scrim.onPointerDown { _, _, _ in }
        }

        let dialogLayer: El<State> = col()
            .key("\(key)-layer")
            .absolute(x: 0.0, y: 0.0)
            .wFull()
            .hFull()
            .p(16.0)
            .center()
            .child(panel)

        layer.append(PopoverAnchor.modalOverlay(key: key, z: 45, scrim: scrim, content: dialogLayer))
    }
}

// MARK: - Menu & ContextMenu (`rune_kit::menu`)

/// Context menu helper anchored at a secondary-press point (`rune_kit::menu::context_menu`).
public func contextMenu<State>(
    _ key: String,
    trigger: El<State>,
    at point: PointerPress?
) -> Menu<State> {
    var m = Menu<State>(key).trigger(trigger).context(true).open(point != nil)
    if let p = point {
        m = m.at(p.window.x, p.window.y)
    }
    return m
}

/// Entry inside an upstream-aligned `Menu`.
public enum MenuBarEntry<State> {
    case item(MenuItem<State>)
    case separator
    case label(String)
}

/// One row item in `Menu` (`rune_kit::menu::MenuItem`).
public struct MenuItem<State> {
    private let labelText: String
    private var iconSVG: SVGIcon?
    private var leadEl: El<State>?
    private var shortcutText: String?
    private var badgeText: String?
    private var descriptionText: String?
    private var isDanger: Bool = false
    private var checkedState: Bool?
    private var submenuData: (entries: [MenuBarEntry<State>], open: Bool)?
    private var itemState: ControlVisualState = .rest
    private var selectHandler: ((inout State, inout Tx) -> Void)?

    public init(_ label: String) {
        self.labelText = label
    }

    public func icon(_ svg: SVGIcon) -> MenuItem<State> {
        var copy = self
        copy.iconSVG = svg
        return copy
    }

    public func lead(_ el: El<State>) -> MenuItem<State> {
        var copy = self
        copy.leadEl = el
        return copy
    }

    public func shortcut(_ s: String) -> MenuItem<State> {
        var copy = self
        copy.shortcutText = s
        return copy
    }

    public func badge(_ b: String) -> MenuItem<State> {
        var copy = self
        copy.badgeText = b
        return copy
    }

    public func description(_ d: String) -> MenuItem<State> {
        var copy = self
        copy.descriptionText = d
        return copy
    }

    public func danger(_ on: Bool = true) -> MenuItem<State> {
        var copy = self
        copy.isDanger = on
        return copy
    }

    public func checked(_ on: Bool) -> MenuItem<State> {
        var copy = self
        copy.checkedState = on
        return copy
    }

    public func submenu(_ entries: [MenuBarEntry<State>], open: Bool) -> MenuItem<State> {
        var copy = self
        copy.submenuData = (entries, open)
        return copy
    }

    public func state(_ s: ControlVisualState) -> MenuItem<State> {
        var copy = self
        copy.itemState = s
        return copy
    }

    public func disabled(_ on: Bool = true) -> MenuItem<State> {
        var copy = self
        if on { copy.itemState = .disabled }
        return copy
    }

    public func onSelect(_ f: @escaping (inout State) -> Void) -> MenuItem<State> {
        var copy = self
        copy.selectHandler = { s, _ in f(&s) }
        return copy
    }

    public func onSelectTx(_ f: @escaping (inout State, inout Tx) -> Void) -> MenuItem<State> {
        var copy = self
        copy.selectHandler = f
        return copy
    }

    fileprivate func build(
        kit k: Kit,
        standard: Bool,
        key: String,
        layer: inout [El<State>],
        cx: Cx<State>?
    ) -> El<State> {
        let c = k.c
        let strong = c.textStrong.a > 0 ? c.textStrong : c.textBase
        let weak = c.textWeak.a > 0 ? c.textWeak : c.textMuted
        let stdIcon = c.stdIcon.a > 0 ? c.stdIcon : c.iconMuted
        let raisedHover = c.surfaceRaisedHover.a > 0 ? c.surfaceRaisedHover : c.hover

        let disabled = itemState == .disabled
        let highlighted = itemState == .hover || (submenuData?.open == true)
        let hoverColor = standard ? raisedHover : c.hover
        let font = standard ? k.ty.textSmallMedium : k.ty.uiCompact
        let baseInk = standard ? (disabled ? weak : strong) : c.textBase
        let danger = isDanger && !disabled
        let ink = danger ? c.danger.fg : baseInk

        var content: El<State> = row().key("content").grow(1.0).shrink(1.0).gap(8.0).itemsCenter().a11yHidden()
        if let leadEl {
            content = content.child(leadEl)
        }
        if let svg = iconSVG {
            let iconColor = danger ? c.danger.fg : (standard ? stdIcon : c.iconBase)
            content = content.child(Rune.icon(svg, size: 14.0).key("icon").color(iconColor).a11yHidden())
        }

        let labelEl: El<State> = text(labelText).key("label").font(font).color(ink).ellipsis().a11yHidden()
        if let d = descriptionText {
            let dFont = standard ? k.ty.textXsmall : k.ty.small
            let dColor = standard ? weak : c.textFaint
            content = content.child(
                col()
                    .key("text")
                    .grow(1.0)
                    .shrink(1.0)
                    .gap(2.0)
                    .child(labelEl)
                    .child(text(d).key("description").font(dFont).color(dColor).ellipsis().a11yHidden())
            )
        } else {
            content = content.child(labelEl)
        }

        var e: El<State> = row()
            .key(key)
            .role(checkedState != nil ? .menuItemCheckbox : .menuItem)
            .label(labelText)
            .disabled(disabled)
            .rounded(standard ? k.radius.sm : 4.0)
            .gap(8.0)
            .itemsCenter()

        if let on = checkedState {
            e = e.checked(on).itemSelected(on)
        }
        if let d = descriptionText, let b = badgeText {
            e = e.description("\(d), \(b)")
        } else if let d = descriptionText ?? badgeText {
            e = e.description(d)
        }
        if let s = shortcutText {
            e = e.shortcutHint(s)
        }
        if let sub = submenuData {
            e = e.expanded(sub.open)
        }

        switch (standard, descriptionText != nil) {
        case (true, _):
            e = e.px(8.0).py(4.0)
        case (false, false):
            e = e.h(28.0).pl(12.0).pr(6.0)
        case (false, true):
            e = e.minH(28.0).py(6.0).pl(12.0).pr(6.0)
        }

        if highlighted {
            e = e.bg(hoverColor)
        } else if !disabled {
            e = e.hover(hoverColor)
        }

        e = e.child(content)

        if let s = shortcutText {
            let st = k.ty.smallMedium.lh(11.0)
            e = e.child(text(s).key("shortcut").font(st).color(c.textFaint).a11yHidden())
        }
        if let b = badgeText {
            e = e.child(
                row()
                    .key("badge")
                    .h(16.0)
                    .px(4.0)
                    .center()
                    .rounded(2.0)
                    .bg(c.layer02)
                    .border(0.5, c.borderBase)
                    .a11yHidden()
                    .child(text(b).font(k.ty.smallMedium.lh(11.0)).color(c.textMuted))
            )
        }
        if let on = checkedState {
            let mark: El<State> = Rune.icon(KitIcons.checkSmall, size: 14.0)
                .color(standard ? stdIcon : c.iconBase)
                .opacity(on ? 1.0 : 0.0)
            e = e.child(el().key("indicator").size(16.0, 16.0).center().a11yHidden().child(mark))
        }
        if let (entries, subOpen) = submenuData {
            e = e.child(
                Rune.icon(KitIcons.caretRight, size: 16.0)
                    .key("chevron")
                    .color(standard ? stdIcon : c.textFaint)
                    .a11yHidden()
            )
            if subOpen {
                var subMenu = Menu<State>("\(key)-sub")
                for subEntry in entries {
                    switch subEntry {
                    case .item(let subItem): subMenu = subMenu.item(subItem)
                    case .separator: subMenu = subMenu.separator()
                    case .label(let l): subMenu = subMenu.groupLabel(l)
                    }
                }
                subMenu = subMenu.minWidth(160.0)
                if standard { subMenu = subMenu.standard() }
                var deeper: [El<State>] = []
                let surface = subMenu.buildSurface(kit: k, layer: &deeper, cx: cx)
                layer.append(
                    PopoverAnchor.anchored(k, surface, anchor: key, placement: .rightStart, gap: 0.0, window: cx?.viewport)
                )
                layer.append(contentsOf: deeper)
            }
        }

        if disabled && !standard {
            e = e.opacity(0.5)
        }

        e = e.focusable(!disabled).inert(disabled)
        if !disabled, let selectHandler {
            e = e
                .onClick { s, tx in selectHandler(&s, &tx) }
                .onKey { s, ev, tx in
                    if ev.key == .enter || ev.key == .space || ev.key == .text(" ") {
                        selectHandler(&s, &tx)
                        return true
                    }
                    return false
                }
        }
        return e
    }
}

/// Dropdown / context menu (`rune_kit::menu::Menu`).
public struct Menu<State> {
    private let key: String
    private var triggerEl: El<State>?
    private var entries: [MenuBarEntry<State>] = []
    private var isOpen: Bool = false
    private var isStandard: Bool = false
    private var placementValue: Placement = .bottomStart
    private var gutterValue: Float = 6.0
    private var minWidthValue: Float = 160.0
    private var atPoint: (Float, Float)?
    private var isContext: Bool = false
    private var closeHandler: ((inout State, inout Tx) -> Void)?

    public init(_ key: String) {
        self.key = key
    }

    public func trigger(_ t: El<State>) -> Menu<State> {
        var copy = self
        copy.triggerEl = t
        return copy
    }

    public func item(_ i: MenuItem<State>) -> Menu<State> {
        var copy = self
        copy.entries.append(.item(i))
        return copy
    }

    public func separator() -> Menu<State> {
        var copy = self
        copy.entries.append(.separator)
        return copy
    }

    public func groupLabel(_ l: String) -> Menu<State> {
        var copy = self
        copy.entries.append(.label(l))
        return copy
    }

    public func open(_ o: Bool) -> Menu<State> {
        var copy = self
        copy.isOpen = o
        return copy
    }

    public func standard() -> Menu<State> {
        var copy = self
        copy.isStandard = true
        copy.minWidthValue = 128.0
        return copy
    }

    public func placement(_ p: Placement) -> Menu<State> {
        var copy = self
        copy.placementValue = p
        return copy
    }

    public func gutter(_ g: Float) -> Menu<State> {
        var copy = self
        copy.gutterValue = g
        return copy
    }

    public func minWidth(_ w: Float) -> Menu<State> {
        var copy = self
        copy.minWidthValue = w
        return copy
    }

    public func at(_ x: Float, _ y: Float) -> Menu<State> {
        var copy = self
        copy.atPoint = (x, y)
        return copy
    }

    public func context(_ on: Bool) -> Menu<State> {
        var copy = self
        copy.isContext = on
        return copy
    }

    public func onClose(_ f: @escaping (inout State) -> Void) -> Menu<State> {
        var copy = self
        copy.closeHandler = { s, _ in f(&s) }
        return copy
    }

    fileprivate func buildSurface(kit k: Kit, layer: inout [El<State>], cx: Cx<State>?) -> El<State> {
        let c = k.c
        let weakBorder = c.borderWeak.a > 0 ? c.borderWeak : c.borderMuted
        let weakText = c.textWeak.a > 0 ? c.textWeak : c.textMuted
        let stdBorder = c.stdBorder.a > 0 ? c.stdBorder : c.borderBase

        var frame: El<State> = col()
            .key("\(key)-menu")
            .role(.menu)
            .focusGroup(true)
            .minW(minWidthValue)
            .itemsStretch()

        if isStandard {
            frame = frame
                .rounded(k.radius.md)
                .bg(c.surfaceRaised)
                .border(1.0, k.alpha(stdBorder, 0.5))
                .shadows(k.shadowLayers(k.elevation.md.isEmpty ? k.elevation.floating : k.elevation.md))
        } else {
            frame = frame
                .rounded(6.0)
                .bg(c.layer01)
                .shadows(k.shadowLayers(k.elevation.floating))
        }

        var list: El<State> = col().key("rows").itemsStretch().p(isStandard ? 4.0 : 2.0)
        for (i, entry) in entries.enumerated() {
            switch entry {
            case .item(let item):
                list = list.child(
                    item.build(kit: k, standard: isStandard, key: "\(key)-item\(i)", layer: &layer, cx: cx)
                )
            case .separator:
                let m: Float = isStandard ? 4.0 : 2.0
                let sepCol = isStandard ? weakBorder : c.borderMuted
                list = list.child(el().key("sep\(i)").h(1.0).mt(m).mb(m).ml(-m).mr(-m).bg(sepCol).a11yHidden())
            case .label(let l):
                let e: El<State> = row().key("label\(i)").itemsCenter()
                if isStandard {
                    let lbl: El<State> = text(l).font(k.ty.textXsmallMedium).color(weakText)
                    list = list.child(e.px(8.0).py(4.0).child(lbl))
                } else {
                    let lbl: El<State> = text(l).font(k.ty.smallMedium).color(c.textFaint)
                    list = list.child(e.h(28.0).px(12.0).child(lbl))
                }
            }
        }
        return frame.child(
            col()
                .key("scroll")
                .shrink(1.0)
                .minH(0.0)
                .scrollY()
                .child(list)
        )
    }

    public func build(kit k: Kit, layer: inout [El<State>], cx: Cx<State>? = nil) -> El<State> {
        let anchorKey = "\(key)-trigger"
        let returnKey = triggerEl?.keyId ?? anchorKey
        let isPointer = isContext || atPoint != nil
        var triggerWrap: El<State> = row().key(anchorKey)
        if let t = triggerEl {
            triggerWrap = triggerWrap.child(isPointer ? t : t.expanded(isOpen))
        }
        guard isOpen else {
            return triggerWrap
        }

        var subs: [El<State>] = []
        var surface = buildSurface(kit: k, layer: &subs, cx: cx)
            .onPointerDown { _, _, _ in }
        if let closeHandler {
            surface = surface
                .modalTx(clickOutside: false) { s, tx in
                    closeHandler(&s, &tx)
                    tx.focus(returnKey)
                }
                .focusReturn(returnKey)
                .onKey { s, ev, tx in
                    if ev.key == .escape {
                        closeHandler(&s, &tx)
                        tx.focus(returnKey)
                        return true
                    }
                    return false
                }
        }

        let effectivePlacement: Placement
        let effectiveGutter: Float
        let effectiveAnchor: String
        if atPoint != nil {
            effectivePlacement = .bottomStart
            effectiveGutter = 0.0
            effectiveAnchor = "\(key)-point"
        } else {
            effectivePlacement = placementValue
            effectiveGutter = gutterValue
            effectiveAnchor = anchorKey
        }

        let estH = min(320.0, max(44.0, Float(entries.count) * 32.0 + 8.0))
        let anchoredSurface = PopoverAnchor.anchored(
            k,
            surface,
            anchor: effectiveAnchor,
            placement: effectivePlacement,
            gap: effectiveGutter,
            at: atPoint,
            window: cx?.viewport,
            estimatedSize: (max(minWidthValue, 160.0), estH)
        )

        if let closeHandler {
            let scrimEl: El<State> = el()
                .key("\(key)-scrim")
                .absolute(x: 0.0, y: 0.0)
                .wFull()
                .hFull()
                .a11yHidden()
                .onClick { s, tx in
                    closeHandler(&s, &tx)
                    tx.focus(returnKey)
                }
                .focusable(false)
            layer.append(PopoverAnchor.modalOverlay(key: key, z: 60, scrim: scrimEl, content: anchoredSurface))
        } else {
            layer.append(anchoredSurface)
        }
        layer.append(contentsOf: subs)
        return triggerWrap
    }
}

// MARK: - List (`rune_kit::list`)

/// One item row inside `List` (`rune_kit::list::ListItem`).
public struct ListItem<State> {
    public let label: String
    public var groupName: String?
    public var isSelected: Bool = false
    public var selectHandler: ((inout State, inout Tx) -> Void)?

    public init(_ label: String) {
        self.label = label
    }

    public func group(_ g: String) -> ListItem<State> {
        var copy = self
        copy.groupName = g
        return copy
    }

    public func selected(_ on: Bool = true) -> ListItem<State> {
        var copy = self
        copy.isSelected = on
        return copy
    }

    public func onSelect(_ f: @escaping (inout State, inout Tx) -> Void) -> ListItem<State> {
        var copy = self
        copy.selectHandler = f
        return copy
    }
}

/// Optional search header + grouped listbox rows with active icon and dividers
/// (`rune_kit::list::List`).
public struct List<State> {
    private var itemList: [ListItem<State>] = []
    private var searchEdit: (keyPath: WritableKeyPath<State, TextEdit>, placeholder: String)?
    private var activeIdx: Int? = 0
    private var hasDivider: Bool = false
    private var activeIconSVG: SVGIcon?
    private var emptyText: String = "No results"
    private var addRowEl: El<State>?

    public init() {}

    public func item(_ i: ListItem<State>) -> List<State> {
        var copy = self
        copy.itemList.append(i)
        return copy
    }

    public func search(_ keyPath: WritableKeyPath<State, TextEdit>, placeholder: String) -> List<State> {
        var copy = self
        copy.searchEdit = (keyPath, placeholder)
        return copy
    }

    public func active(_ i: Int?) -> List<State> {
        var copy = self
        copy.activeIdx = i
        return copy
    }

    public func divider(_ on: Bool = true) -> List<State> {
        var copy = self
        copy.hasDivider = on
        return copy
    }

    public func activeIcon(_ svg: SVGIcon) -> List<State> {
        var copy = self
        copy.activeIconSVG = svg
        return copy
    }

    public func emptyMessage(_ m: String) -> List<State> {
        var copy = self
        copy.emptyText = m
        return copy
    }

    public func addRow(_ e: El<State>) -> List<State> {
        var copy = self
        copy.addRowEl = e
        return copy
    }

    public func build(kit k: Kit) -> El<State> {
        let c = k.c
        let strong = c.textStrong.a > 0 ? c.textStrong : c.textBase
        let weak = c.textWeak.a > 0 ? c.textWeak : c.textMuted
        let raisedHover = c.surfaceRaisedHover.a > 0 ? c.surfaceRaisedHover : c.hover
        let stdIcon = c.stdIconStrong.a > 0 ? c.stdIconStrong : (c.stdIcon.a > 0 ? c.stdIcon : c.iconBase)
        let weakBorder = c.borderWeak.a > 0 ? c.borderWeak : c.borderMuted
        let itemFont = TextStyle(size: 14.0, weight: 500.0).lh(21.0)

        var root: El<State> = col().wFull().gap(12.0)

        if let search = searchEdit {
            let inputEl: El<State> = Rune.textInput(key: "input", search.keyPath)
                .label(search.placeholder)
                .font(TextStyle(size: 14.0, weight: 400.0).lh(20.0))
                .color(strong)
                .placeholder(search.placeholder, color: weak)
                .grow(1.0)
                .shrink(1.0)

            root = root.child(
                row().key("search-wrapper").wFull().mb(4.0).gap(8.0).itemsCenter().child(
                    row()
                        .key("search")
                        .grow(1.0)
                        .p(8.0)
                        .gap(8.0)
                        .itemsCenter()
                        .rounded(k.radius.md)
                        .bg(c.surfaceBase)
                        .child(icon(KitIcons.search, size: 16.0).color(stdIcon))
                        .child(inputEl)
                )
            )
        }

        let isListbox = itemList.contains { $0.selectHandler != nil }
        var scrollCol: El<State> = col()
            .key("scroll")
            .role(isListbox ? .listbox : .list)
            .wFull()
            .gap(12.0)
        if isListbox {
            scrollCol = scrollCol.focusGroup(true)
        }

        if itemList.isEmpty && addRowEl == nil {
            scrollCol = scrollCol.child(
                col()
                    .key("empty")
                    .wFull()
                    .px(48.0)
                    .py(32.0)
                    .center()
                    .child(text(emptyText).font(TextStyle(size: 14.0, weight: 400.0).lh(21.0)).color(weak))
            )
        }

        let pressableIndices = itemList.enumerated().compactMap { $0.element.selectHandler != nil ? $0.offset : nil }

        var groups: [El<State>] = []
        var currentGroup: (name: String?, el: El<State>)? = nil
        let n = itemList.count
        var places: [(Int, Int)] = Array(repeating: (1, max(1, n)), count: n)
        do {
            var runStart = 0
            while runStart < n {
                var runEnd = runStart + 1
                while runEnd < n && itemList[runEnd].groupName == itemList[runStart].groupName {
                    runEnd += 1
                }
                let runCount = runEnd - runStart
                for j in 0..<runCount {
                    places[runStart + j] = (j + 1, runCount)
                }
                runStart = runEnd
            }
        }

        for (i, item) in itemList.enumerated() {
            if currentGroup == nil || currentGroup?.name != item.groupName {
                if let existing = currentGroup {
                    groups.append(existing.el)
                }
                var gCol: El<State> = col().key("group\(i)").wFull()
                if let gName = item.groupName {
                    gCol = gCol
                        .role(.group)
                        .label(gName)
                        .child(
                            row()
                                .key("header")
                                .wFull()
                                .pt(8.0)
                                .pb(8.0)
                                .pl(8.0)
                                .pr(12.0)
                                .bg(c.surfaceRaised)
                                .a11yHidden()
                                .child(text(gName).font(itemFont).color(weak))
                        )
                }
                currentGroup = (item.groupName, gCol)
            }

            let isAct = activeIdx == i
            let pressable = item.selectHandler != nil

            var r: El<State> = row()
                .key("item\(i)")
                .role(pressable ? .option : .listItem)
                .label(item.label)
                .positionInSet(places[i].0, size: places[i].1)
                .wFull()
                .px(8.0)
                .py(6.0)
                .itemsCenter()
                .rounded(k.radius.md)
                .gap(4.0)
                .child(text(item.label).font(itemFont).color(strong).shrink(1.0).ellipsis().a11yHidden())

            if item.isSelected {
                r = r.child(icon(KitIcons.checkSmall, size: 16.0).color(stdIcon).a11yHidden())
            }
            if isAct {
                r = r.bg(raisedHover)
                if let ai = activeIconSVG {
                    r = r.child(icon(ai, size: 16.0).color(stdIcon).a11yHidden())
                }
            } else {
                r = r.hover(raisedHover)
            }

            if pressable {
                r = r.focusable(true).itemSelected(item.isSelected).focusRing(c.borderFocus)
            }
            if hasDivider && i + 1 < n {
                r = r.child(el().key("divider").h(1.0).pin(right: 16.0, bottom: 0.0, left: 16.0).bg(weakBorder).a11yHidden())
            }
            if let handler = item.selectHandler {
                let pIdx = pressableIndices.firstIndex(of: i)
                r = r
                    .onClick { s, tx in handler(&s, &tx) }
                    .onKey { s, ev, tx in
                        switch ev.key {
                        case .enter, .space, .text(" "):
                            handler(&s, &tx)
                            return true
                        case .arrowDown:
                            if let pIdx, !pressableIndices.isEmpty {
                                let next = pressableIndices[(pIdx + 1) % pressableIndices.count]
                                tx.focus("item\(next)")
                            }
                            return true
                        case .arrowUp:
                            if let pIdx, !pressableIndices.isEmpty {
                                let prev = pressableIndices[(pIdx - 1 + pressableIndices.count) % pressableIndices.count]
                                tx.focus("item\(prev)")
                            }
                            return true
                        case .home:
                            if let first = pressableIndices.first {
                                tx.focus("item\(first)")
                            }
                            return true
                        case .end:
                            if let last = pressableIndices.last {
                                tx.focus("item\(last)")
                            }
                            return true
                        default:
                            return false
                        }
                    }
            }

            if var group = currentGroup {
                group.el = group.el.child(r)
                currentGroup = group
            }
        }

        if let remaining = currentGroup {
            groups.append(remaining.el)
        }
        if let addRowEl {
            groups.append(col().key("add").wFull().child(addRowEl))
        }

        for (idx, g) in groups.enumerated() {
            scrollCol = scrollCol.child(idx + 1 == groups.count ? g.pb(12.0) : g)
        }
        return root.child(scrollCol)
    }
}
