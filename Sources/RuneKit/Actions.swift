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
        case .ghost:
            bgCol = .transparent
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

        let cleanHelp = help?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanShortcut = shortcut?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tip: String? = switch (cleanHelp, cleanShortcut) {
        case let (h?, s?) where !h.isEmpty && !s.isEmpty: "\(h)  \(s)"
        case let (h?, _) where !h.isEmpty: h
        case let (_, s?) where !s.isEmpty: s
        default: nil
        }
        if let tip {
            node = node.help(tip)
        }

        if let svg = leadingIcon {
            node = node.child(icon(svg, size: 14).key("icon").color(fgCol))
        }
        switch labelSpec {
        case let .text(title):
            node = node.child(text(title).key("label").font(fontStyle).color(fgCol).noWrap())
        case let .rolling(rollingKey, title):
            node = node
                .animateLayout(motion.control)
                .child(rollingText(key: rollingKey, title, font: fontStyle, color: fgCol))
        case let .custom(_, builder):
            node = node.child(builder(fontStyle, fgCol))
        }
        if let svg = trailingIcon {
            node = node.child(icon(svg, size: 14).key("trailing-icon").color(fgCol))
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
