import Foundation
import Rune

/// One row item in a `PopupList` (`rune_kit::popup_list::PopupItem`).
public struct PopupListItem: Sendable, Equatable, Hashable {
    public var id: String
    public var label: String
    public var description: String?
    public var shortcut: String?
    public var disabled: Bool

    public init(
        id: String,
        label: String,
        description: String? = nil,
        shortcut: String? = nil,
        disabled: Bool = false
    ) {
        self.id = id
        self.label = label
        self.description = (description?.isEmpty == true) ? nil : description
        self.shortcut = (shortcut?.isEmpty == true) ? nil : shortcut
        self.disabled = disabled
    }
}

/// Keyboard-navigable filterable popup list state (`rune_kit::popup_list`).
public struct PopupListState: Sendable, Equatable {
    public var query: String = ""
    public var activeIndex: Int? = 0
    public var open: Bool = false

    public init(open: Bool = false, query: String = "", activeIndex: Int? = 0) {
        self.open = open
        self.query = query
        self.activeIndex = activeIndex
    }

    public func filtered(_ items: [PopupListItem]) -> [PopupListItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { item in
            item.label.lowercased().contains(q) ||
            (item.description?.lowercased().contains(q) ?? false) ||
            item.id.lowercased().contains(q)
        }
    }

    public mutating func moveNext(in items: [PopupListItem]) {
        let list = filtered(items)
        guard !list.isEmpty else { activeIndex = nil; return }
        let start = activeIndex ?? -1
        for step in 1...list.count {
            let idx = (start + step + list.count) % list.count
            if !list[idx].disabled {
                activeIndex = idx
                return
            }
        }
    }

    public mutating func movePrevious(in items: [PopupListItem]) {
        let list = filtered(items)
        guard !list.isEmpty else { activeIndex = nil; return }
        let start = activeIndex ?? 0
        for step in 1...list.count {
            let idx = (start - step + list.count) % list.count
            if !list[idx].disabled {
                activeIndex = idx
                return
            }
        }
    }

    public func activeItem(in items: [PopupListItem]) -> PopupListItem? {
        let list = filtered(items)
        guard let idx = activeIndex, idx >= 0, idx < list.count, !list[idx].disabled else {
            return list.first(where: { !$0.disabled })
        }
        return list[idx]
    }
}

extension Kit {
    /// Keyboard-navigable filterable popup listbox (`rune_kit::popup_list::PopupList`).
    public func popupList<State>(
        key: String = "popup-list",
        items: [PopupListItem],
        activeIndex: Int? = nil,
        emptyText: String = "No results",
        width: Float = 260,
        maxHeight: Float = 240,
        onSelect: @escaping (inout State, PopupListItem) -> Void
    ) -> El<State> {
        var listCol: El<State> = col()
            .key("\(key)-items")
            .wFull()
            .p(4)
            .gap(2)

        if items.isEmpty {
            listCol = listCol.child(
                row()
                    .wFull()
                    .px(10)
                    .py(8)
                    .child(text(emptyText).font(ty.textSmall).color(c.textMuted))
            )
        } else {
            for (idx, item) in items.enumerated() {
                let isActive = activeIndex == idx
                var rowEl: El<State> = row()
                    .key("\(key)-item-\(item.id)")
                    .wFull()
                    .px(8)
                    .py(6)
                    .gap(8)
                    .itemsCenter()
                    .justifyBetween()
                    .rounded(radius.sm)
                    .bg(isActive ? c.surfaceHover : .transparent)
                    .opacity(item.disabled ? 0.45 : 1.0)

                var leftCol: El<State> = col().grow(1).minW(0).gap(1)
                    .child(text(item.label).font(ty.uiCompact).color(isActive ? c.textStrong : c.textBase))
                if let desc = item.description {
                    leftCol = leftCol.child(text(desc).font(ty.small).color(c.textMuted))
                }
                rowEl = rowEl.child(leftCol)

                if let shortcut = item.shortcut {
                    rowEl = rowEl.child(text(shortcut).font(ty.small).color(c.textFaint))
                }

                if !item.disabled {
                    rowEl = rowEl.onClick { s in
                        onSelect(&s, item)
                    }
                }
                listCol = listCol.child(rowEl)
            }
        }

        return col()
            .key(key)
            .w(width)
            .maxH(maxHeight)
            .rounded(radius.md)
            .bg(c.surfaceRaised)
            .border(1.0, c.borderBase)
            .clip(true)
            .child(listCol)
    }
}
