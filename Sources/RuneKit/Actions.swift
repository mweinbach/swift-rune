import Foundation
import Rune

/// A command or action item for action bars and command palettes (`rune_kit::actions`).
public struct ActionItem<State>: Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var shortcut: String?
    public var variant: ButtonVariant
    public var disabled: Bool
    public var handler: @Sendable (inout State) -> Void

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        shortcut: String? = nil,
        variant: ButtonVariant = .neutral,
        disabled: Bool = false,
        handler: @escaping @Sendable (inout State) -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
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

    @discardableResult
    public func dispatch(id: String, state: inout State) -> Bool {
        guard let item = items.first(where: { $0.id == id && !$0.disabled }) else {
            return false
        }
        item.handler(&state)
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
    /// Renders a horizontal row of `ActionItem` buttons.
    public func actionBar<State>(
        key: String = "action-bar",
        items: [ActionItem<State>],
        size: ControlSize = .md
    ) -> El<State> {
        var bar: El<State> = row().key(key).gap(8).itemsCenter()
        for item in items {
            let fn = item.handler
            bar = bar.child(
                button(
                    key: "\(key)-\(item.id)",
                    item.title,
                    variant: item.variant,
                    size: size,
                    disabled: item.disabled
                ) { s, _ in
                    fn(&s)
                }
            )
        }
        return bar
    }
}
