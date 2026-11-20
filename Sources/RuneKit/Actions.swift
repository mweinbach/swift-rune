import Foundation
import Rune
import RuneMotion

/// Label configuration for `Kit.actionButton` (`rune_kit::actions::Button`).
public enum ButtonLabelSpec<State> {
    case text(String)
    case rolling(key: String, text: String)
    case custom(accessibilityLabel: String, (TextStyle, Color) -> El<State>)

    var accessibleLabel: String {
        switch self {
        case let .text(label), let .rolling(_, label):
            return label
        case let .custom(accessibilityLabel, _):
            return accessibilityLabel
        }
    }
}

/// A command or action item for action bars and command palettes (`rune_kit::actions`).
public struct ActionItem<State>: Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var shortcut: String?
    public var help: String?
    public var rollingKey: String?
    public var variant: ButtonVariant
    public var disabled: Bool
    public var handler: @Sendable (inout State) -> Void

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        shortcut: String? = nil,
        help: String? = nil,
        rollingKey: String? = nil,
        variant: ButtonVariant = .neutral,
        disabled: Bool = false,
        handler: @escaping @Sendable (inout State) -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.help = help
        self.rollingKey = rollingKey
        self.variant = variant
        self.disabled = disabled
        self.handler = handler
    }
}

/// Dispatches `ActionItem`s by identifier.
public struct ActionDispatcher<State>: Sendable {
    public var items: [ActionItem<State>]

    public init(items: [ActionItem<State>] = []) {
        self.items = items
    }

    public func item(for id: String) -> ActionItem<State>? {
        items.first(where: { $0.id == id })
    }

    public func canDispatch(id: String) -> Bool {
        items.contains(where: { $0.id == id && !$0.disabled })
    }

    @discardableResult
    public func dispatch(id: String, state: inout State) -> Bool {
        guard let item = items.first(where: { $0.id == id && !$0.disabled }) else {
            return false
        }
        item.handler(&state)
        return true
    }

    @discardableResult
    public func dispatchFirstMatch(query: String, state: inout State) -> Bool {
        guard let first = filter(query: query).first(where: { !$0.disabled }) else {
            return false
        }
        first.handler(&state)
        return true
    }

    public func filter(query: String) -> [ActionItem<State>] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.title.lowercased().contains(q) ||
            ($0.subtitle?.lowercased().contains(q) ?? false) ||
            $0.id.lowercased().contains(q)
        }
    }
}

/// Fluent builder matching `rune_kit::actions::Button`.
public struct Button<State> {
    private var key: String
    private var label: ButtonLabelSpec<State>
    private var variant: ButtonVariant = .neutral
    private var size: ControlSize = .regular
    private var leadingIcon: SVGIcon?
    private var trailingIcon: SVGIcon?
    private var helpText: String?
    private var shortcutText: String?
    private var visualState: ControlVisualState = .rest
    private var isExpanded: Bool?
    private var pressHandler: ((inout State, inout Tx) -> Void)?

    public init(key: String = "button", _ title: String) {
        self.key = key
        self.label = .text(title)
    }

    public init(key: String = "button", label: ButtonLabelSpec<State>) {
        self.key = key
        self.label = label
    }

    public func variant(_ v: ButtonVariant) -> Self { var c = self; c.variant = v; return c }
    public func size(_ s: ControlSize) -> Self { var c = self; c.size = s; return c }
    public func state(_ s: ControlVisualState) -> Self { var c = self; c.visualState = s; return c }
    public func leadingIcon(_ icon: SVGIcon?) -> Self { var c = self; c.leadingIcon = icon; return c }
    public func trailingIcon(_ icon: SVGIcon?) -> Self { var c = self; c.trailingIcon = icon; return c }
    public func help(_ text: String) -> Self { var c = self; c.helpText = text; return c }
    public func shortcut(_ text: String) -> Self { var c = self; c.shortcutText = text; return c }
    public func disabled(_ on: Bool = true) -> Self { on ? state(.disabled) : self }
    public func expanded(_ on: Bool) -> Self { var c = self; c.isExpanded = on; return c }
    public func onPress(_ f: @escaping (inout State, inout Tx) -> Void) -> Self { var c = self; c.pressHandler = f; return c }

    public func build(_ k: Kit) -> El<State> {
        k.actionButton(
            key: key,
            label: label,
            variant: variant,
            size: size,
            leadingIcon: leadingIcon,
            trailingIcon: trailingIcon,
            help: helpText,
            shortcut: shortcutText,
            visualState: visualState,
            expanded: isExpanded,
            onClick: pressHandler
        )
    }
}

/// Formats a shortcut accelerator string for menu-style display (`rune_kit::actions::format_shortcut`).
private func formatActionShortcut(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let platform = KeyPlatform.current
    guard let parsed = try? ParsedShortcut.parseOn(trimmed, platform: platform) else {
        return trimmed
    }
    let sep = platform == .mac ? "" : "+"
    return parsed.menuKeycaps(on: platform).joined(separator: sep)
}

/// Formats the shortcut once for use by the tooltip and the accessibility node.
private func composeActionHelp(
    help: String?,
    label: String,
    shortcut: String?
) -> (tip: String?, shortcut: String) {
    let shortcut = shortcut.map(formatActionShortcut) ?? ""
    if !shortcut.isEmpty {
        if let help, !help.isEmpty { return ("\(help)  \(shortcut)", shortcut) }
        if help == nil && !label.isEmpty { return ("\(label)  \(shortcut)", shortcut) }
        return (shortcut, shortcut)
    }
    return (help.flatMap { $0.isEmpty ? nil : $0 }, shortcut)
}

/// Fluent builder matching `rune_kit::actions::IconButton`.
public struct IconButton<State> {
    private var key: String
    private var svg: SVGIcon
    private var variant: ButtonVariant = .neutral
    private var size: ControlSize = .regular
    private var visualState: ControlVisualState = .rest
    private var labelText: String?
    private var helpText: String?
    private var shortcutText: String?
    private var isExpanded: Bool?
    private var pressHandler: ((inout State, inout Tx) -> Void)?

    public init(key: String = "icon-button", svg: SVGIcon) {
        self.key = key
        self.svg = svg
    }

    public func variant(_ v: ButtonVariant) -> Self { var c = self; c.variant = v; return c }
    public func size(_ s: ControlSize) -> Self { var c = self; c.size = s; return c }
    public func state(_ s: ControlVisualState) -> Self { var c = self; c.visualState = s; return c }
    public func label(_ text: String) -> Self { var c = self; c.labelText = text; return c }
    public func help(_ text: String) -> Self { var c = self; c.helpText = text; return c }
    public func shortcut(_ text: String) -> Self { var c = self; c.shortcutText = text; return c }
    public func disabled(_ on: Bool = true) -> Self { on ? state(.disabled) : self }
    public func expanded(_ on: Bool) -> Self { var c = self; c.isExpanded = on; return c }
    public func onPress(_ f: @escaping (inout State, inout Tx) -> Void) -> Self { var c = self; c.pressHandler = f; return c }

    public func build(_ k: Kit) -> El<State> {
        let a11yLabel = labelText ?? helpText ?? ""
        var node = k.iconButton(
            key: key,
            svg: svg,
            label: a11yLabel,
            size: size,
            variant: variant,
            visualState: visualState,
            expanded: isExpanded,
            omitHelp: true,
            onClick: pressHandler
        )
        let (tip, shortcutHint) = composeActionHelp(
            help: helpText,
            label: labelText ?? "",
            shortcut: shortcutText
        )
        if let tip {
            node = node.help(tip)
        }
        // An explicit empty description keeps a tooltip used as the name from being read twice.
        node = node.description(labelText != nil ? helpText ?? "" : "")
        if !shortcutHint.isEmpty {
            node = node.shortcutHint(shortcutHint)
        }
        return node
    }
}

extension ButtonVariant {
    var isGhost: Bool { self == .ghost || self == .ghostMuted || self == .ghostFaint }
}

struct ButtonSkin {
    var fill: Color
    var hover: Color
    var pressed: Color
    var ink: Color
    var icon: Color
    var shadows: [Shadow] = []
    var sheen: (Color, Color)?
    var disabledOpacity: Float = 0.5
}

extension Kit {
    func buttonSkin(_ variant: ButtonVariant) -> ButtonSkin {
        let ghost = ButtonSkin(fill: .transparent, hover: c.hover, pressed: c.pressed, ink: c.textBase, icon: c.textBase)
        switch variant {
        case .neutral, .danger, .warning:
            let ink = variant == .danger ? c.danger.fg : (variant == .warning ? c.warning.fg : c.textBase)
            return ButtonSkin(fill: c.bgButtonNeutral, hover: c.hover, pressed: c.pressed, ink: ink, icon: ink,
                              shadows: shadowLayers(elevation.buttonNeutral))
        case .ghost: return ghost
        case .ghostMuted, .ghostFaint:
            var skin = ghost
            skin.ink = variant == .ghostMuted ? c.textMuted : c.textFaint
            skin.icon = variant == .ghostMuted ? c.iconMuted : c.iconFaint
            return skin
        case .outline, .loading:
            var skin = ghost
            let loading = variant == .loading
            skin.shadows = [Shadow(y: 0, blur: 0, spread: loading ? 0.5 : 1, color: c.borderMuted, inset: true)]
            if loading {
                skin.fill = c.layer02
                skin.hover = .transparent
                skin.pressed = .transparent
                skin.disabledOpacity = 1
            }
            return skin
        case .primary, .accent:
            let submit = variant == .accent
            let fill = submit ? c.bgIconButtonContrast : c.bgContrast
            let ink = submit ? c.submitFg : c.textContrast
            let top = submit ? on(c.submitHighlight, backdrop: fill) : lightOn(0.2, backdrop: fill)
            return ButtonSkin(fill: fill, hover: on(submit ? c.submitHover : c.contrastHover, backdrop: fill),
                              pressed: on(c.contrastPressed, backdrop: fill), ink: ink, icon: ink,
                              shadows: shadowLayers(elevation.buttonContrast), sheen: (top, light(0)), disabledOpacity: 0.4)
        }
    }

    func paintButton<State>(_ node: El<State>, skin: ButtonSkin, state: ControlVisualState,
                            variant: ButtonVariant, onClick: ((inout State, inout Tx) -> Void)?) -> El<State> {
        let enabled = state != .disabled && variant != .loading
        let fill = switch state {
        case .hover: kitOver(skin.hover, skin.fill)
        case .pressed: kitOver(skin.pressed, skin.fill)
        default: skin.fill
        }
        var button = focusRingState(
            node.bg(fill).shadows(skin.shadows),
            2.0,
            2.0,
            state == .focus && enabled
        )
        if let (top, bottom) = skin.sheen {
            button = button.gradient(top, bottom)
        }
        if state == .disabled { button = button.layerOpacity(skin.disabledOpacity) }
        guard enabled else { return button.disabled() }
        if state == .rest {
            button = button.hover(skin.hover).press(kitPressOver(skin.hover, skin.pressed))
        }
        button = button.focusable()
        if let onClick { button = button.onClick(onClick) }
        return button
    }
}

extension Kit {
    /// Action button supporting plain, rolling-text, and custom styled labels (`rune_kit::actions::Button`).
    public func actionButton<State>(
        key: String,
        label labelSpec: ButtonLabelSpec<State>,
        variant: ButtonVariant = .neutral,
        size: ControlSize = .regular,
        leadingIcon: SVGIcon? = nil,
        trailingIcon: SVGIcon? = nil,
        help: String? = nil,
        shortcut: String? = nil,
        disabled: Bool = false,
        visualState: ControlVisualState = .rest,
        expanded: Bool? = nil,
        onClick: ((inout State, inout Tx) -> Void)?
    ) -> El<State> {
        let state: ControlVisualState = disabled ? .disabled : visualState
        var skin = buttonSkin(variant)
        if expanded == true && state != .disabled && variant.isGhost {
            skin.fill = skin.pressed
            if variant == .ghostMuted {
                skin.ink = c.textBase
                skin.icon = c.iconBase
            }
        }
        let (padding, corner, glyph): (Float, Float, Float) = switch size {
        case .mini: (8, radius.sm, 12)
        case .small: (10, radius.sm, 14)
        case .regular: (12, radius.md, 16)
        case .large: (14, radius.lg, 16)
        case .extraLarge: (18, radius.xl, 16)
        case .sm, .md, .lg: (size.horizontalPadding, radius.md, 14)
        }
        let small = size == .mini || size == .small || size == .sm
        var fontStyle = variant == .ghostMuted ? (small ? ty.small : ty.ui) : (small ? ty.smallMedium : ty.uiMedium)
        if size == .mini { fontStyle.size = 9 }
        var node: El<State> = row()
            .key(key)
            .role(.button)
            .label(labelSpec.accessibleLabel)
            .h(size.height)
            .px(padding)
            .gap(size == .mini ? 4 : 6)
            .center()
            .rounded(corner)

        let (tip, shortcutHint) = composeActionHelp(
            help: help,
            label: labelSpec.accessibleLabel,
            shortcut: shortcut
        )
        if let tip {
            node = node.help(tip)
        }
        node = node.description(help ?? "")
        if !shortcutHint.isEmpty {
            node = node.shortcutHint(shortcutHint)
        }
        if let expanded {
            node = node.expanded(expanded)
        }

        let isRolling: Bool = if case .rolling = labelSpec { true } else { false }
        if let svg = leadingIcon {
            var ic: El<State> = icon(svg, size: glyph).key("icon").color(skin.icon).a11yHidden()
            if isRolling {
                ic = ic.animateLayout(LayoutAnim.widthLeads(RollingText<State>.defaultSpring))
            }
            node = node.child(ic)
        }
        switch labelSpec {
        case let .text(title):
            node = node.child(text(title).key("label").font(fontStyle).color(skin.ink).noWrap().a11yHidden())
        case let .rolling(rollingKey, title):
            node = node
                .animateLayout(LayoutAnim.widthLeads(RollingText<State>.defaultSpring))
                .child(rollingText(key: rollingKey, title, font: fontStyle, color: skin.ink).a11yHidden())
        case let .custom(_, builder):
            node = node.child(builder(fontStyle, skin.ink).a11yHidden())
        }
        if let svg = trailingIcon {
            node = node.child(icon(svg, size: glyph).key("trailing-icon").color(skin.icon).a11yHidden())
        }

        return paintButton(node, skin: skin, state: state, variant: variant, onClick: onClick)
    }

    /// Renders a horizontal row of `ActionItem` buttons.
    public func actionBar<State>(
        key: String = "action-bar",
        items: [ActionItem<State>],
        size: ControlSize = .md
    ) -> El<State> {
        var bar: El<State> = row().key(key).role(.group).gap(8).itemsCenter()
        for item in items {
            let fn = item.handler
            let labelSpec: ButtonLabelSpec<State> = item.rollingKey.map { .rolling(key: $0, text: item.title) } ?? .text(item.title)
            bar = bar.child(
                actionButton(
                    key: "\(key)-\(item.id)",
                    label: labelSpec,
                    variant: item.variant,
                    size: size,
                    help: item.help,
                    shortcut: item.shortcut,
                    disabled: item.disabled
                ) { s, _ in
                    fn(&s)
                }
            )
        }
        return bar
    }
}
