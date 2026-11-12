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

public struct ToastEntry: Sendable, Equatable {
    public var id: String
    public var message: String
    public var tone: BadgeTone

    public init(id: String, message: String, tone: BadgeTone = .neutral) {
        self.id = id
        self.message = message
        self.tone = tone
    }
}

public enum ToastPlacement: Sendable, Hashable {
    case topTrailing
    case bottomTrailing
    case bottomCenter
}

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

    // MARK: - ToastStack (`rune_kit::toast_stack`)

    /// Positioned stack of active toast notifications (`Kit::toast_stack`).
    public func toastStack<State>(
        key: String = "toast-stack",
        toasts: [ToastEntry],
        placement: ToastPlacement = .bottomTrailing,
        onDismiss: @escaping (inout State, String) -> Void
    ) -> El<State> {
        var stack: El<State> = col().key(key).gap(8).z(95)
        switch placement {
        case .topTrailing:
            stack = stack.pin(top: 16, right: 16)
        case .bottomTrailing:
            stack = stack.pin(right: 16, bottom: 16)
        case .bottomCenter:
            stack = stack.pin(right: 16, bottom: 16, left: 16).itemsCenter()
        }
        for entry in toasts {
            let entryId = entry.id
            stack = stack.child(
                toast(key: "\(key)-\(entryId)", message: entry.message, tone: entry.tone) { s in
                    onDismiss(&s, entryId)
                }
            )
        }
        return stack
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
            .h(38)
            .px(14)
            .itemsCenter()
            .justifyBetween()
            .bg(c.page)
            .borderSides(bottom: 1.0, color: c.borderMuted)
            .child(row().gap(8).itemsCenter().child(leading).child(titleCol))
            .child(trailing)
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
