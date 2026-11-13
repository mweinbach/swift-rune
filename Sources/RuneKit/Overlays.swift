import Foundation
import Rune
import RuneMotion

// MARK: - Overlay Placement & Menu / Combobox / ToastStack Types

public enum OverlayPlacement: Sendable, Hashable {
    case top
    case bottom
    case leading
    case trailing
}

public enum MenuEntry<State> {
    case item(
        id: String,
        label: String,
        shortcut: [String]? = nil,
        icon: SVGIcon? = nil,
        destructive: Bool = false,
        disabled: Bool = false,
        onSelect: (inout State, inout Tx) -> Void
    )
    case separator
    case section(String)
}

public struct ComboboxOption<ID: Hashable & Sendable & CustomStringConvertible>: Sendable {
    public var id: ID
    public var label: String
    public var detail: String?

    public init(id: ID, label: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

// `ToastEntry`, `ToastPlacement`, and `Kit.toastStack` live in `ToastStack.swift`.

extension Kit {
    // MARK: - Scrim (`rune_kit::overlay::scrim`)

    /// Full-viewport modal backdrop scrim (`Kit::scrim`).
    public func scrim<State>(
        key: String = "scrim",
        onDismiss: ((inout State) -> Void)? = nil
    ) -> El<State> {
        var elNode: El<State> = el()
            .key(key)
            .pin(top: 0, right: 0, bottom: 0, left: 0)
            .bg(c.scrim)
            .z(90)
            .transition(Transition.opacity.spring(motion.overlay))

        if let onDismiss {
            elNode = elNode.onClick { s, _ in onDismiss(&s) }
        }
        return elNode
    }

    // MARK: - Tooltip (`rune_kit::overlay::Tooltip`)

    /// Hover/focus tooltip overlay (`Kit::tooltip`).
    public func tooltip<State>(
        key: String,
        text tooltipText: String,
        placement: OverlayPlacement = .top,
        isVisible: Bool,
        trigger: El<State>
    ) -> El<State> {
        var wrap: El<State> = col().key(key).child(trigger)
        if isVisible {
            var bubble: El<State> = row()
                .key("\(key)-tip")
                .px(8)
                .py(4)
                .rounded(radius.sm)
                .bg(c.bgInverse)
                .shadows(shadowLayers(elevation.floating))
                .z(80)
                .transition(Transition.scale(0.95).kitRules(small: true).spring(motion.overlay))
                .child(text(tooltipText).font(ty.smallMedium).color(c.textInverse).noWrap())

            switch placement {
            case .top:
                bubble = bubble.pin(bottom: 28, left: 0)
            case .bottom:
                bubble = bubble.pin(top: 28, left: 0)
            case .leading:
                bubble = bubble.pin(top: 0, right: 28)
            case .trailing:
                bubble = bubble.pin(top: 0, left: 28)
            }
            wrap = wrap.child(bubble)
        }
        return wrap
    }

    // MARK: - Popover & HoverCard (`rune_kit::overlay::{Popover, HoverCard}`)

    /// Anchored popover container (`Kit::popover`).
    public func popover<State>(
        key: String,
        isOpen: Bool,
        placement: OverlayPlacement = .bottom,
        trigger: El<State>,
        content: () -> El<State>
    ) -> El<State> {
        var wrap: El<State> = col().key(key).child(trigger)
        if isOpen {
            var panel: El<State> = col()
                .key("\(key)-panel")
                .p(8)
                .rounded(radius.lg)
                .bg(c.surfaceRaised)
                .shadows(shadowLayers(elevation.floating))
                .z(60)
                .transition(Transition.scale(0.96).kitRules().spring(motion.overlay))
                .child(content())

            switch placement {
            case .top: panel = panel.pin(bottom: 36, left: 0)
            case .bottom: panel = panel.pin(top: 36, left: 0)
            case .leading: panel = panel.pin(top: 0, right: 36)
            case .trailing: panel = panel.pin(top: 0, left: 36)
            }
            wrap = wrap.child(panel)
        }
        return wrap
    }

    /// Hover-triggered preview card (`Kit::hover_card`).
    public func hoverCard<State>(
        key: String,
        isOpen: Bool,
        placement: OverlayPlacement = .bottom,
        trigger: El<State>,
        content: () -> El<State>
    ) -> El<State> {
        popover(key: key, isOpen: isOpen, placement: placement, trigger: trigger, content: content)
    }

    // MARK: - Menu (`rune_kit::menu`)

    /// Vertical menu list with sections, separators, icons, and shortcut hints (`Kit::menu`).
    public func menu<State>(
        key: String,
        entries: [MenuEntry<State>]
    ) -> El<State> {
        var list: El<State> = col()
            .key(key)
            .role(.menu)
            .minW(180)
            .p(4)
            .gap(2)
            .rounded(radius.lg)
            .bg(c.surfaceRaised)
            .shadows(shadowLayers(elevation.floating))
            .focusGroup(true)

        for (idx, entry) in entries.enumerated() {
            switch entry {
            case .separator:
                list = list.child(el().key("\(key)-sep-\(idx)").wFull().h(1).my(3).bg(c.borderMuted))

            case .section(let title):
                list = list.child(
                    row().key("\(key)-sec-\(idx)").px(8).py(4)
                        .child(text(title).font(ty.smallMedium).color(c.textFaint))
                )

            case let .item(id, label, shortcut, svg, destructive, disabled, onSelect):
                let fgCol = destructive ? c.danger.fg : c.textBase
                var itemRow: El<State> = row()
                    .key("\(key)-\(id)")
                    .role(.menuItem)
                    .label(label)
                    .wFull()
                    .h(28)
                    .px(8)
                    .gap(8)
                    .itemsCenter()
                    .rounded(radius.sm)

                if let svg {
                    itemRow = itemRow.child(icon(svg, size: 14).color(destructive ? c.danger.fg : c.iconMuted))
                }
                itemRow = itemRow.child(text(label).font(ty.ui).color(fgCol).grow(1).ellipsis())
                if let shortcut, !shortcut.isEmpty {
                    itemRow = itemRow.child(keybind(shortcut, variant: .subtle))
                }
                if disabled {
                    itemRow = itemRow.opacity(0.45).inert(true)
                } else {
                    itemRow = itemRow.hover(c.hover).press(c.pressed).focusRing(c.borderFocus).onClick(onSelect)
                }
                list = list.child(itemRow)
            }
        }
        return list
    }

    // MARK: - Combobox (`rune_kit::combobox`)

    /// Filterable searchable select dropdown (`Kit::combobox`).
    public func combobox<State, ID: Hashable & Sendable & CustomStringConvertible>(
        key: String,
        options: [ComboboxOption<ID>],
        selected: ID?,
        queryKeyPath: WritableKeyPath<State, TextEdit>,
        queryText: String,
        isOpen: Bool,
        placeholder: String = "Filter options...",
        onToggleOpen: @escaping (inout State, Bool) -> Void,
        onSelect: @escaping (inout State, ID) -> Void
    ) -> El<State> {
        let selectedLabel = selected.flatMap { id in options.first(where: { $0.id == id })?.label } ?? placeholder
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
            .child(text(selectedLabel).font(ty.ui).color(selected == nil ? c.textFaint : c.textBase).ellipsis())
            .child(icon(KitIcons.chevronDown, size: 14).color(c.iconMuted))

        var root: El<State> = col().key(key).wFull().child(trigger)
        if isOpen {
            let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let filtered = trimmed.isEmpty
                ? options
                : options.filter { $0.label.lowercased().contains(trimmed) }

            var popup: El<State> = col()
                .key("\(key)-popup")
                .pin(top: 36, right: 0, left: 0)
                .p(6)
                .gap(4)
                .rounded(radius.lg)
                .bg(c.surfaceRaised)
                .shadows(shadowLayers(elevation.floating))
                .z(55)
                .child(searchField(key: "\(key)-search", queryKeyPath, placeholder: placeholder))

            if filtered.isEmpty {
                popup = popup.child(
                    row().px(8).py(8).child(text("No matches").font(ty.small).color(c.textFaint))
                )
            } else {
                for opt in filtered {
                    let isSel = (opt.id == selected)
                    popup = popup.child(
                        listItem(
                            key: "\(key)-opt-\(opt.id)",
                            title: opt.label,
                            subtitle: opt.detail,
                            trailing: isSel ? icon(KitIcons.check, size: 13).color(c.textAccent) : nil,
                            selected: isSel
                        ) { s, _ in
                            onSelect(&s, opt.id)
                            onToggleOpen(&s, false)
                        }
                    )
                }
            }
            root = root.child(popup)
        }
        return root
    }

    // MARK: - Shell: WindowTitlebar & Sidebar (`rune_kit::shell`)

    /// Compact window titlebar (`Kit::window_titlebar`).
    public func windowTitlebar<State>(
        key: String = "titlebar",
        title: String,
        subtitle: String? = nil,
        leading: El<State>? = nil,
        trailing: El<State>? = nil
    ) -> El<State> {
        var titleCol: El<State> = row().gap(8).itemsCenter()
            .child(text(title).font(ty.uiMedium).color(c.textBase).noWrap())
        if let subtitle, !subtitle.isEmpty {
            titleCol = titleCol.child(text(subtitle).font(ty.small).color(c.textFaint).noWrap())
        }

        return row()
            .key(key)
            .wFull()
            .h(44)
            .px(14)
            .itemsCenter()
            .justifyBetween()
            .bg(c.bgDeep)
            .borderSides(bottom: 1.0, color: c.borderMuted)
            .child(row().gap(8).itemsCenter().child(leading).child(titleCol))
            .child(trailing)
    }

    /// Body text inheriting page typography (`overlay::body_text`).
    public func bodyText<State>(_ content: String) -> El<State> {
        var style = ty.ui
        style.letterSpacing = 0.0
        return text(content).font(style.lh(24.0)).color(c.stdText)
    }

    /// Overlay text inheriting strong document ink (`overlay::overlay_text`).
    public func overlayText<State>(_ content: String) -> El<State> {
        var style = ty.ui
        style.letterSpacing = 0.0
        return text(content).font(style.lh(24.0)).color(c.textStrong)
    }

    /// Sidebar shell container with header, sections, and optional footer (`Kit::sidebar`).
    public func sidebar<State>(
        key: String = "sidebar",
        header: El<State>? = nil,
        sections: [El<State>],
        footer: El<State>? = nil
    ) -> El<State> {
        col()
            .key(key)
            .sizeFull()
            .p(10)
            .gap(12)
            .bg(c.layer01)
            .child(header)
            .child(
                col()
                    .wFull()
                    .grow(1)
                    .minH(0)
                    .gap(10)
                    .scroll()
                    .children(sections)
            )
            .child(footer)
    }
}

// MARK: - TooltipStyle & Tooltip (`rune_kit::overlay::{TooltipAppearance, TooltipStyle, Tooltip}`)

/// Visual density preset for `Tooltip` (`rune_kit::overlay::TooltipAppearance`).
public enum TooltipAppearance: Sendable, Equatable, Hashable {
    case compact
    case standard
    case large
}

/// Visual styling, typography, shadows, motion, and `HelpLook` adapter for `Tooltip`
/// (`rune_kit::overlay::TooltipStyle`).
public struct TooltipStyle: Sendable {
    public var fillColor: Color
    public var borderSpec: (width: Float, color: Color)?
    public var radiusValue: Float
    public var paddingValue: (x: Float, y: Float)
    public var maxWidthValue: Float?
    public var fontValue: TextStyle
    public var inkColor: Color
    public var shadowLayers: [Shadow]
    public var motionValue: Spring
    public var keys: (fill: Color, ink: Color)

    public init(
        fill: Color,
        border: (width: Float, color: Color)? = nil,
        radius: Float = 4.0,
        padding: (x: Float, y: Float) = (6.0, 5.0),
        maxWidth: Float? = nil,
        font: TextStyle,
        ink: Color,
        shadows: [Shadow] = [],
        motion: Spring,
        keys: (fill: Color, ink: Color)
    ) {
        self.fillColor = fill
        self.borderSpec = border
        self.radiusValue = radius
        self.paddingValue = padding
        self.maxWidthValue = maxWidth
        self.fontValue = font
        self.inkColor = ink
        self.shadowLayers = shadows
        self.motionValue = motion
        self.keys = keys
    }

    public static func fromKit(_ k: Kit, _ appearance: TooltipAppearance = .compact) -> TooltipStyle {
        let c = k.c
        var style = TooltipStyle(
            fill: c.layer01,
            border: nil,
            radius: 4.0,
            padding: (6.0, 5.0),
            maxWidth: nil,
            font: k.ty.smallMedium,
            ink: c.textBase,
            shadows: k.shadowLayers(k.elevation.floating),
            motion: k.motion.overlay,
            keys: (c.layer03, c.textMuted)
        )
        switch appearance {
        case .compact:
            return style
        case .large:
            style.paddingValue = (12.0, 12.0)
            var largeFont = k.ty.uiCompact
            largeFont.weight = 530.0
            style.fontValue = largeFont
            return style
        case .standard:
            let weakBorder = c.borderWeak.a > 0 ? c.borderWeak : c.borderMuted
            let invertStrong = c.textInvertStrong.a > 0 ? c.textInvertStrong : c.textInverse
            let mdElevation = k.elevation.md.isEmpty ? k.elevation.floating : k.elevation.md
            style.fillColor = c.surfaceFloat
            style.borderSpec = (1.0, weakBorder)
            style.radiusValue = k.radius.sm
            style.paddingValue = (8.0, 2.0)
            style.maxWidthValue = 320.0
            style.fontValue = k.ty.textSmallMedium
            style.inkColor = invertStrong
            style.shadowLayers = k.shadowLayers(mdElevation)
            return style
        }
    }

    public static func neutral(dark: Bool) -> TooltipStyle {
        fromKit(Kit.neutral(dark: dark), .compact)
    }

    public func fill(_ color: Color) -> TooltipStyle {
        var copy = self
        copy.fillColor = color
        return copy
    }

    public func border(_ width: Float, _ color: Color) -> TooltipStyle {
        var copy = self
        copy.borderSpec = width > 0.0 ? (width, color) : nil
        return copy
    }

    public func radius(_ r: Float) -> TooltipStyle {
        var copy = self
        copy.radiusValue = r
        return copy
    }

    public func padding(_ x: Float, _ y: Float) -> TooltipStyle {
        var copy = self
        copy.paddingValue = (x, y)
        return copy
    }

    public func maxWidth(_ w: Float) -> TooltipStyle {
        var copy = self
        copy.maxWidthValue = w
        return copy
    }

    public func font(_ f: TextStyle) -> TooltipStyle {
        var copy = self
        copy.fontValue = f
        return copy
    }

    public func ink(_ color: Color) -> TooltipStyle {
        var copy = self
        copy.inkColor = color
        return copy
    }

    public func shadows(_ layers: [Shadow]) -> TooltipStyle {
        var copy = self
        copy.shadowLayers = layers
        return copy
    }

    public func motion(_ spring: Spring) -> TooltipStyle {
        var copy = self
        copy.motionValue = spring
        return copy
    }

    public var textStyle: TextStyle { fontValue }
    public var textColor: Color { inkColor }

    /// Produces a `Rune.HelpLook` configured with this tooltip style's tokens and timings.
    public func helpLook() -> HelpLook {
        let (ringW, ringCol) = borderSpec ?? (0.0, .transparent)
        let keyFont = TextStyle(
            size: 11.0,
            weight: 530.0,
            lineHeight: 11.0,
            letterSpacing: 0.05,
            family: fontValue.family
        )
        return HelpLook.system(dark: false)
            .fill(fillColor)
            .ink(inkColor)
            .ring(ringW, ringCol)
            .radius(radiusValue)
            .padding(paddingValue.x, paddingValue.y)
            .font(fontValue)
            .maxWidth(maxWidthValue)
            .shadows(shadowLayers)
            .gap(4.0)
            .margin(8.0)
            .delay(0.4)
            .skipDelay(0.3)
            .fade(enter: 0.12, exit: 0.08, scale: 0.96)
            .keycaps(fill: keys.fill, ink: keys.ink, font: keyFont, upper: true)
            .keycapShape(height: 14.0, padX: 4.0, radius: 2.0, gap: 2.0, lead: 6.0)
            .rowGap(6.0)
    }
}

/// Anchored tooltip builder (`rune_kit::overlay::Tooltip`).
public struct Tooltip<State> {
    private enum Content {
        case el(El<State>)
        case text(String, (TextStyle, Color)?)
    }

    private let key: String
    private var triggerEl: El<State>?
    private var value: [Content] = []
    private var appearanceValue: TooltipAppearance = .compact
    private var isOpen: Bool = false
    private var placementValue: Placement = .bottom

    public init(_ key: String) {
        self.key = key
    }

    public func trigger(_ t: El<State>) -> Tooltip<State> {
        var copy = self
        copy.triggerEl = t
        return copy
    }

    public func text(_ k: Kit, _ s: String) -> Tooltip<State> {
        var copy = self
        copy.value.append(.text(s, (font(k), ink(k))))
        return copy
    }

    public func label(_ s: String) -> Tooltip<State> {
        var copy = self
        copy.value.append(.text(s, nil))
        return copy
    }

    public func child(_ c: El<State>) -> Tooltip<State> {
        var copy = self
        copy.value.append(.el(c))
        return copy
    }

    public func appearance(_ a: TooltipAppearance) -> Tooltip<State> {
        var copy = self
        copy.appearanceValue = a
        return copy
    }

    public func open(_ o: Bool) -> Tooltip<State> {
        var copy = self
        copy.isOpen = o
        return copy
    }

    public func placement(_ p: Placement) -> Tooltip<State> {
        var copy = self
        copy.placementValue = p
        return copy
    }

    public func font(_ k: Kit) -> TextStyle {
        TooltipStyle.fromKit(k, appearanceValue).fontValue
    }

    public func ink(_ k: Kit) -> Color {
        TooltipStyle.fromKit(k, appearanceValue).inkColor
    }

    public func build(kit k: Kit, layer: inout [El<State>]) -> El<State> {
        let style = TooltipStyle.fromKit(k, appearanceValue)
        return render(style: style, layer: &layer)
    }

    public func render(style: TooltipStyle, layer: inout [El<State>]) -> El<State> {
        let anchorKey = "\(key)-trigger"
        if !isOpen {
            var rowWrap: El<State> = row().key(anchorKey)
            if let triggerEl { rowWrap = rowWrap.child(triggerEl) }
            return rowWrap
        }

        let words: [String] = value.compactMap { item in
            switch item {
            case .text(let s, _): return s
            case .el: return nil
            }
        }
        let described = words.joined(separator: " ")

        var triggerWrap: El<State> = row().key(anchorKey)
        if let triggerEl {
            triggerWrap = triggerWrap.child(described.isEmpty ? triggerEl : triggerEl.description(described))
        }

        let children: [El<State>] = value.map { item in
            switch item {
            case .el(let e):
                if style.maxWidthValue != nil && e.role == .text && e.textStyle.wrap == .wrap {
                    return e.shrink(1.0)
                }
                return e
            case .text(let s, let look):
                let (font, ink) = look ?? (style.fontValue, style.inkColor)
                let t: El<State> = Rune.text(s).font(font).color(ink).a11yHidden()
                if style.maxWidthValue != nil {
                    return t.wrapText().shrink(1.0)
                }
                return t
            }
        }

        var body: El<State> = row()
            .key("\(key)-tooltip")
            .role(.tooltip)
            .itemsCenter()
            .gap(6.0)
            .children(children)
        if !described.isEmpty {
            body = body.label(described)
        }
        if let w = style.maxWidthValue {
            body = body.maxW(w)
        }
        body = body
            .px(style.paddingValue.x)
            .py(style.paddingValue.y)
            .rounded(style.radiusValue)
            .bg(style.fillColor)
        if let b = style.borderSpec {
            body = body.border(b.width, b.color)
        }
        if !style.shadowLayers.isEmpty {
            body = body.shadows(style.shadowLayers)
        }

        let (side, align) = placementValue.split()
        layer.append(
            body
                .anchoredFit(anchorKey, side: side.runeSide, align: align.runeAlign, gap: 4.0)
                .animate(style.motionValue)
                .z(80)
        )
        return triggerWrap
    }
}

/// Anchored hover card preview (`rune_kit::overlay::HoverCard`).
public struct HoverCard<State> {
    private let key: String
    private var triggerEl: El<State>?
    private var body: [El<State>] = []
    private var isOpen: Bool = false
    private var placementValue: Placement = .bottom

    public init(_ key: String) {
        self.key = key
    }

    public func trigger(_ t: El<State>) -> HoverCard<State> {
        var copy = self
        copy.triggerEl = t
        return copy
    }

    public func child(_ c: El<State>) -> HoverCard<State> {
        var copy = self
        copy.body.append(c)
        return copy
    }

    public func open(_ o: Bool) -> HoverCard<State> {
        var copy = self
        copy.isOpen = o
        return copy
    }

    public func placement(_ p: Placement) -> HoverCard<State> {
        var copy = self
        copy.placementValue = p
        return copy
    }

    public func build(kit k: Kit, layer: inout [El<State>]) -> El<State> {
        let anchorKey = "\(key)-trigger"
        var triggerWrap: El<State> = row().key(anchorKey).wFull()
        if let triggerEl {
            triggerWrap = triggerWrap.child(triggerEl)
        }
        guard isOpen else {
            return triggerWrap
        }
        let content: El<State> = col()
            .key("\(key)-card")
            .minW(200.0)
            .maxW(320.0)
            .child(col().p(4.0).children(body))
        let raisedCard = PopoverAnchor.raised(k, content, radius: k.radius.lg)
        let (side, align) = placementValue.split()
        layer.append(
            raisedCard
                .anchoredFit(anchorKey, side: side.runeSide, align: align.runeAlign, gap: 4.0)
                .animate(k.motion.overlay)
                .z(60)
        )
        return triggerWrap
    }
}
