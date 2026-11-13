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
    private var size: ControlSize = .md
    private var leadingIcon: SVGIcon?
    private var trailingIcon: SVGIcon?
    private var helpText: String?
    private var shortcutText: String?
    private var isDisabled: Bool = false
    private var isExpanded: Bool?
    private var pressHandler: (inout State, inout Tx) -> Void = { _, _ in }

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
    public func leadingIcon(_ icon: SVGIcon?) -> Self { var c = self; c.leadingIcon = icon; return c }
    public func trailingIcon(_ icon: SVGIcon?) -> Self { var c = self; c.trailingIcon = icon; return c }
    public func help(_ text: String) -> Self { var c = self; c.helpText = text; return c }
    public func shortcut(_ text: String) -> Self { var c = self; c.shortcutText = text; return c }
    public func disabled(_ on: Bool = true) -> Self { var c = self; c.isDisabled = on; return c }
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
            disabled: isDisabled,
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

/// Composes optional tooltip, trimmed help, and formatted shortcut (`rune_kit::actions::compose_help`).
private func composeActionHelp(
    help: String?,
    label: String,
    shortcut: String?
) -> (tip: String?, cleanHelp: String?, cleanShortcut: String) {
    let cleanHelp = help?.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanShortcut = shortcut.map(formatActionShortcut) ?? ""
    let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    let tip: String? = switch (cleanHelp, cleanLabel, cleanShortcut.isEmpty ? nil : cleanShortcut) {
    case let (h?, _, s?) where !h.isEmpty: "\(h)  \(s)"
    case let (_, l, s?) where !l.isEmpty: "\(l)  \(s)"
    case let (_, _, s?): s
    case let (h?, _, nil) where !h.isEmpty: h
    default: nil
    }
    return (tip, cleanHelp, cleanShortcut)
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
    private var isDisabled: Bool = false
    private var isExpanded: Bool?
    private var pressHandler: (inout State, inout Tx) -> Void = { _, _ in }

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
    public func disabled(_ on: Bool = true) -> Self { var c = self; c.isDisabled = on; return c }
    public func expanded(_ on: Bool) -> Self { var c = self; c.isExpanded = on; return c }
    public func onPress(_ f: @escaping (inout State, inout Tx) -> Void) -> Self { var c = self; c.pressHandler = f; return c }

    public func build(_ k: Kit) -> El<State> {
        let a11yLabel = labelText ?? helpText ?? ""
        let effectiveDisabled = isDisabled || visualState == .disabled
        var node = k.iconButton(
            key: key,
            svg: svg,
            label: a11yLabel,
            size: size,
            variant: variant,
            disabled: effectiveDisabled,
            visualState: effectiveDisabled ? .disabled : visualState,
            expanded: isExpanded,
            omitHelp: true,
            onClick: pressHandler
        )
        let (tip, cleanHelp, cleanShortcut) = composeActionHelp(
            help: helpText,
            label: labelText ?? "",
            shortcut: shortcutText
        )
        if let tip {
            node = node.help(tip)
        }
        // Only expose `help` as a11y description when `label` is set; otherwise `label`
        // already carries `help` and setting both makes VoiceOver speak it twice.
        if labelText != nil, let cleanHelp, !cleanHelp.isEmpty {
            node = node.description(cleanHelp)
        }
        if !cleanShortcut.isEmpty {
            node = node.shortcutHint(cleanShortcut)
        }
        return node
    }
}

extension Kit {
    /// Action button supporting plain, rolling-text, and custom styled labels (`rune_kit::actions::Button`).
    public func actionButton<State>(
        key: String,
        label labelSpec: ButtonLabelSpec<State>,
        variant: ButtonVariant = .neutral,
        size: ControlSize = .md,
        leadingIcon: SVGIcon? = nil,
        trailingIcon: SVGIcon? = nil,
        help: String? = nil,
        shortcut: String? = nil,
        disabled: Bool = false,
        expanded: Bool? = nil,
        onClick: @escaping (inout State, inout Tx) -> Void
    ) -> El<State> {
        let bgCol: Color
        let fgCol: Color
        let hoverCol: Color
        let pressCol: Color
        let borderCol: Color
        let borderW: Float
        let elev: [Shadow]

        switch variant {
        case .primary:
            bgCol = c.bgContrast
            fgCol = c.textContrast
            hoverCol = c.contrastHover
            pressCol = c.contrastPressed
            borderCol = .transparent
            borderW = 0
            elev = elevation.buttonContrast
        case .accent:
            bgCol = c.bgAccent
            fgCol = c.submitFg
            hoverCol = c.submitHover
            pressCol = c.contrastPressed
            borderCol = .transparent
            borderW = 0
            elev = elevation.buttonContrast
        case .neutral:
            bgCol = c.bgButtonNeutral
            fgCol = c.textBase
            hoverCol = c.hover
            pressCol = c.pressed
            borderCol = c.borderBase
            borderW = 1
            elev = elevation.buttonNeutral
        case .ghost, .ghostMuted:
            bgCol = (expanded == true && !disabled) ? c.pressed : .transparent
            fgCol = c.textBase
            hoverCol = c.hover
            pressCol = c.pressed
            borderCol = .transparent
            borderW = 0
            elev = []
        case .danger:
            bgCol = c.danger.bg
            fgCol = c.danger.fg
            hoverCol = c.danger.fg.alpha(0.10)
            pressCol = c.danger.fg.alpha(0.18)
            borderCol = c.danger.border
            borderW = 1
            elev = []
        }

        let fontStyle = (size == .sm) ? ty.smallMedium : ty.uiMedium
        var node: El<State> = row()
            .key(key)
            .role(.button)
            .label(labelSpec.accessibleLabel)
            .h(size.height)
            .px(size.horizontalPadding)
            .gap(6)
            .center()
            .rounded(radius.md)
            .bg(bgCol)
            .border(borderW, borderCol)
            .shadows(shadowLayers(elev))
            .animate(motion.control)

        let (tip, cleanHelp, cleanShortcut) = composeActionHelp(
            help: help,
            label: labelSpec.accessibleLabel,
            shortcut: shortcut
        )
        if let tip {
            node = node.help(tip)
        }
        node = node.description(cleanHelp ?? "")
        if !cleanShortcut.isEmpty {
            node = node.shortcutHint(cleanShortcut)
        }
        if let expanded {
            node = node.expanded(expanded)
        }

        let isRolling: Bool = if case .rolling = labelSpec { true } else { false }
        if let svg = leadingIcon {
            var ic: El<State> = icon(svg, size: 14).key("icon").color(fgCol).a11yHidden()
            if isRolling {
                ic = ic.animateLayout(LayoutAnim.widthLeads(motion.control))
            }
            node = node.child(ic)
        }
        switch labelSpec {
        case let .text(title):
            node = node.child(text(title).key("label").font(fontStyle).color(fgCol).noWrap().a11yHidden())
        case let .rolling(rollingKey, title):
            node = node
                .animateLayout(LayoutAnim.widthLeads(motion.control))
                .child(rollingText(key: rollingKey, title, font: fontStyle, color: fgCol).a11yHidden())
        case let .custom(_, builder):
            node = node.child(builder(fontStyle, fgCol).a11yHidden())
        }
        if let svg = trailingIcon {
            node = node.child(icon(svg, size: 14).key("trailing-icon").color(fgCol).a11yHidden())
        }

        if disabled {
            return node.opacity(0.45).inert(true)
        }
        return node
            .hover(hoverCol)
            .press(pressCol)
            .pressScale(0.97)
            .focusRing(c.borderFocus)
            .onClick(onClick)
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
