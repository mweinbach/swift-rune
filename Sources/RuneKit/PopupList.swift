import Foundation
import Rune

// MARK: - Legacy PopupListItem / PopupListState / Kit.popupList (kept for compatibility)

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
    /// Keyboard-navigable filterable popup listbox (`Kit::popup_list`).
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

// MARK: - Parity PopupItem & PopupList (`rune_kit::popup_list`)

/// One row in a `PopupList` (`rune_kit::popup_list::PopupItem`).
public struct PopupItem<State> {
    public let id: String
    public let label: String
    public var descriptionText: String?
    public var leadingEl: El<State>?
    public var trailingEl: El<State>?
    public var isDisabled: Bool = false

    public init(_ id: String, _ label: String) {
        self.id = id
        self.label = label
    }

    public init(_ item: PopupListItem) {
        self.id = item.id
        self.label = item.label
        self.descriptionText = item.description
        self.isDisabled = item.disabled
    }

    public func description(_ text: String) -> PopupItem<State> {
        var copy = self
        copy.descriptionText = text.isEmpty ? nil : text
        return copy
    }

    public func leading(_ el: El<State>) -> PopupItem<State> {
        var copy = self
        copy.leadingEl = el
        return copy
    }

    public func trailing(_ el: El<State>) -> PopupItem<State> {
        var copy = self
        copy.trailingEl = el
        return copy
    }

    public func disabled(_ on: Bool = true) -> PopupItem<State> {
        var copy = self
        copy.isDisabled = on
        return copy
    }
}

/// Anchored, virtualised popup listbox driven by an outside field or `Combobox`
/// (`rune_kit::popup_list::PopupList`).
public struct PopupList<State> {
    public static var rowHeight: Float { 28.0 }

    private let key: String
    private var anchorKey: String
    private var isOpen: Bool = true
    private var placementValue: Placement = .topStart
    private var gutterValue: Float = 4.0
    private var widthValue: Float = 260.0
    private var maxHeightValue: Float = 240.0
    private var paddingValue: Float = 4.0
    private var rowRadiusValue: Float = 4.0
    private var itemList: [PopupItem<State>] = []
    private var shouldAnimateFiltering: Bool = false
    private var activeIdx: Int?
    private var trackedScrollYValue: Float = 0.0
    private var preferTrackedScroll: Bool = false
    private var emptyText: String = "No results"
    private var a11yLabel: String?
    private var onActiveHandler: ((inout State, Int) -> Void)?
    private var onChooseHandler: ((inout State, String, inout Tx) -> Void)?
    private var onCloseHandler: ((inout State) -> Void)?

    public init(_ key: String, anchor: String) {
        self.key = key
        self.anchorKey = anchor
    }

    public func anchor(_ anchor: String) -> PopupList<State> {
        var copy = self
        copy.anchorKey = anchor
        return copy
    }

    public func anchored(_ anchor: String, side: Side, align: Align, gap: Float) -> PopupList<State> {
        var copy = self
        copy.anchorKey = anchor
        copy.placementValue = Self.placement(side: side, align: align)
        copy.gutterValue = gap
        return copy
    }

    public func placement(_ p: Placement) -> PopupList<State> {
        var copy = self
        copy.placementValue = p
        return copy
    }

    public func side(_ s: Side) -> PopupList<State> {
        var copy = self
        let (_, a) = copy.placementValue.split()
        copy.placementValue = Self.placement(side: s, align: a)
        return copy
    }

    public func align(_ a: Align) -> PopupList<State> {
        var copy = self
        let (s, _) = copy.placementValue.split()
        copy.placementValue = Self.placement(side: s, align: a)
        return copy
    }

    public func offset(_ gap: Float) -> PopupList<State> {
        gutter(gap)
    }

    public func gutter(_ gap: Float) -> PopupList<State> {
        var copy = self
        copy.gutterValue = gap
        return copy
    }

    public func open(_ on: Bool) -> PopupList<State> {
        var copy = self
        copy.isOpen = on
        return copy
    }

    public func width(_ w: Float) -> PopupList<State> {
        var copy = self
        copy.widthValue = w
        return copy
    }

    public func maxHeight(_ h: Float) -> PopupList<State> {
        var copy = self
        copy.maxHeightValue = h
        return copy
    }

    public func padding(_ p: Float) -> PopupList<State> {
        var copy = self
        copy.paddingValue = p
        return copy
    }

    public func rowRadius(_ r: Float) -> PopupList<State> {
        var copy = self
        copy.rowRadiusValue = r
        return copy
    }

    public func items(_ items: [PopupItem<State>]) -> PopupList<State> {
        var copy = self
        copy.itemList = items
        return copy
    }

    public func item(_ item: PopupItem<State>) -> PopupList<State> {
        var copy = self
        copy.itemList.append(item)
        return copy
    }

    public func animateFiltering(_ on: Bool) -> PopupList<State> {
        var copy = self
        copy.shouldAnimateFiltering = on
        return copy
    }

    public func active(_ i: Int?) -> PopupList<State> {
        var copy = self
        copy.activeIdx = i
        return copy
    }

    public func scrollOffset(_ y: Float) -> PopupList<State> {
        var copy = self
        copy.trackedScrollYValue = max(0, y)
        return copy
    }

    public func preferTrackedScroll(_ on: Bool = true) -> PopupList<State> {
        var copy = self
        copy.preferTrackedScroll = on
        return copy
    }

    public func emptyMessage(_ text: String) -> PopupList<State> {
        var copy = self
        copy.emptyText = text
        return copy
    }

    public func label(_ l: String) -> PopupList<State> {
        var copy = self
        copy.a11yLabel = l
        return copy
    }

    public func onActive(_ f: @escaping (inout State, Int) -> Void) -> PopupList<State> {
        var copy = self
        copy.onActiveHandler = f
        return copy
    }

    public func onChoose(_ f: @escaping (inout State, String, inout Tx) -> Void) -> PopupList<State> {
        var copy = self
        copy.onChooseHandler = f
        return copy
    }

    public func onClose(_ f: @escaping (inout State) -> Void) -> PopupList<State> {
        var copy = self
        copy.onCloseHandler = f
        return copy
    }

    public func buildList(kit k: Kit, cx: Cx<State>? = nil) -> El<State> {
        let validActive: Int? = activeIdx.flatMap { i in
            (i >= 0 && i < itemList.count && !itemList[i].isDisabled) ? i : nil
        }

        let rh = Self.rowHeight
        let viewportKey = "\(key)-viewport"
        let naturalVpH = min(Float(itemList.count) * rh, maxHeightValue)
        let measuredVpH = cx?.layoutSize(viewportKey)?[1]
        let renderVpH = (measuredVpH ?? 0) > 0 ? min(measuredVpH!, naturalVpH) : naturalVpH
        let cxScrollY = cx?.scrollOffset(of: viewportKey).y ?? 0.0
        let scrollY = preferTrackedScroll ? trackedScrollYValue : max(trackedScrollYValue, cxScrollY)
        let overscan: Float = 265.0
        let start = itemList.isEmpty ? 0 : max(0, Int(((scrollY - overscan) / rh).rounded(.down)))
        let end = itemList.isEmpty ? 0 : min(itemList.count, Int(((scrollY + max(renderVpH, rh) + overscan) / rh).rounded(.up)))
        let safeStart = min(start, end)
        let beforeH = Float(safeStart) * rh
        let afterH = Float(max(0, itemList.count - end)) * rh

        var rows: El<State> = col().key("\(key)-rows").wFull().shrink(0.0).kitFilterKeys(itemList.map(\.id))
        if shouldAnimateFiltering {
            // The viewport springs to its new height while matches crossfade in their new row slots.
            rows = rows.animateLayout(.instant)
        }
        let extraActiveBefore = validActive.flatMap { $0 < safeStart ? $0 : nil }
        let extraActiveAfter = validActive.flatMap { $0 >= end ? $0 : nil }

        let weakColor = k.c.textWeak.a > 0 ? k.c.textWeak : k.c.textMuted
        func makeItemRow(_ i: Int) -> El<State> {
            let option = itemList[i]
            let optID = option.id
            let isActive = validActive == i
            var itemRow: El<State> = row()
                .key("\(key)-option-\(optID)")
                .role(.option)
                .label(option.label)
                .itemSelected(isActive)
                .revealSelected(isActive)
                .positionInSet(i + 1, size: itemList.count)
                .disabled(option.isDisabled)
                .wFull()
                .h(rh)
                .shrink(0.0)
                .px(8.0)
                .gap(8.0)
                .itemsCenter()
                .rounded(rowRadiusValue)
                .transition(Transition.opacity)
                .bg(isActive ? k.c.hover : .transparent)
            if shouldAnimateFiltering {
                itemRow = itemRow.animate(k.motion.overlay).animateLayout(.instant)
            }

            if let desc = option.descriptionText {
                itemRow = itemRow.description(desc)
            }
            if let lead = option.leadingEl {
                itemRow = itemRow.child(lead.a11yHidden())
            }
            if let desc = option.descriptionText {
                itemRow = itemRow
                    .child(text(option.label).font(k.ty.uiCompact).color(k.c.textBase).shrink(1.0).ellipsis().a11yHidden())
                    .child(text(desc).key("description").font(k.ty.uiCompact).color(weakColor).grow(1.0).shrink(1.0).ellipsis().a11yHidden())
            } else {
                itemRow = itemRow
                    .child(text(option.label).font(k.ty.uiCompact).color(k.c.textBase).grow(1.0).shrink(1.0).ellipsis().a11yHidden())
            }
            if let trail = option.trailingEl {
                itemRow = itemRow.child(trail.a11yHidden())
            }

            if option.isDisabled {
                itemRow = itemRow.opacity(0.5).inert(true)
            } else {
                if let onActive = onActiveHandler {
                    itemRow = itemRow.onHover { s, hovering, _ in
                        if hovering { onActive(&s, i) }
                    }
                }
                if let onChoose = onChooseHandler {
                    itemRow = itemRow.onClick { s, tx in
                        onChoose(&s, optID, &tx)
                    }
                    .focusable(false)
                }
            }
            if shouldAnimateFiltering {
                itemRow = itemRow.arrivesWhole()
            }
            return itemRow
        }

        if let activeIdx = extraActiveBefore {
            let headH = Float(activeIdx) * rh
            if headH > 0 {
                rows = rows.child(el().key("\(key)-before-head").wFull().h(headH).shrink(0.0).kitVirtualSpacer())
            }
            rows = rows.child(makeItemRow(activeIdx))
            let midH = Float(max(0, safeStart - activeIdx - 1)) * rh
            if midH > 0 {
                rows = rows.child(el().key("\(key)-before-tail").wFull().h(midH).shrink(0.0).kitVirtualSpacer())
            }
        } else if beforeH > 0 {
            rows = rows.child(el().key("\(key)-before").wFull().h(beforeH).shrink(0.0).kitVirtualSpacer())
        }

        for i in safeStart..<end {
            rows = rows.child(makeItemRow(i))
        }

        if let activeIdx = extraActiveAfter {
            let midH = Float(max(0, activeIdx - end)) * rh
            if midH > 0 {
                rows = rows.child(el().key("\(key)-after-head").wFull().h(midH).shrink(0.0).kitVirtualSpacer())
            }
            rows = rows.child(makeItemRow(activeIdx))
            let tailH = Float(max(0, itemList.count - activeIdx - 1)) * rh
            if tailH > 0 {
                rows = rows.child(el().key("\(key)-after-tail").wFull().h(tailH).shrink(0.0).kitVirtualSpacer())
            }
        } else if afterH > 0 {
            rows = rows.child(el().key("\(key)-after").wFull().h(afterH).shrink(0.0).kitVirtualSpacer())
        }

        let isEmpty = itemList.isEmpty
        var viewport: El<State> = col()
            .key(viewportKey)
            .role(.listbox)
            .wFull()
            .shrink(1.0)
            .clipSoft(0.0)
            .scrollY()
            .child(rows)
        viewport = viewport.h(naturalVpH).minH(isEmpty ? 0.0 : rh)
        if shouldAnimateFiltering {
            viewport = viewport.animateLayout(MotionTokens.REFLOW)
        }
        if let a11yLabel {
            viewport = viewport.label(a11yLabel)
        }

        var emptyEl: El<State> = row()
            .key("empty")
            .h(isEmpty ? rh : 0.0)
            .px(8.0)
            .itemsCenter()
            .clip(true)
            .opacity(isEmpty ? 1.0 : 0.0)
            .child(text(emptyText).font(k.ty.uiCompact).color(weakColor))
        if shouldAnimateFiltering {
            emptyEl = emptyEl.tokenMotion(k.motion.overlay)
        }

        return col()
            .key("list")
            .wFull()
            .shrink(1.0)
            .minH(0.0)
            .preserveFocusOnPress(true)
            .onPointerDown { _, _, _ in }
            .child(viewport)
            .child(emptyEl)
    }

    public func build(kit k: Kit, layer: inout [El<State>], cx: Cx<State>? = nil) {
        guard isOpen else { return }
        if let close = onCloseHandler {
            layer.append(PopoverAnchor.scrim(key: "\(key)-scrim", onClose: close))
        }
        let list = buildList(kit: k, cx: cx)
        var content: El<State> = col()
            .key("\(key)-content")
            .w(widthValue)
            .p(paddingValue)
            .preserveFocusOnPress(true)
            .child(list)
        if !shouldAnimateFiltering {
            content = content.animate(k.motion.overlay).instantChanges()
        }
        let surface = PopoverAnchor.raised(k, content, radius: k.radius.md)
        var anchoredOverlay = PopoverAnchor.anchored(
            k,
            surface,
            anchor: anchorKey,
            placement: placementValue,
            gap: gutterValue,
            window: cx?.viewport,
            instant: !shouldAnimateFiltering,
            animateLayout: shouldAnimateFiltering
        )
        if shouldAnimateFiltering {
            anchoredOverlay = anchoredOverlay.animateLayout(MotionTokens.REFLOW)
        }
        layer.append(anchoredOverlay)
    }

    private static func placement(side: Side, align: Align) -> Placement {
        switch (side, align) {
        case (.top, .center): .top
        case (.top, .start): .topStart
        case (.top, .end): .topEnd
        case (.bottom, .center): .bottom
        case (.bottom, .start): .bottomStart
        case (.bottom, .end): .bottomEnd
        case (.left, _): .left
        case (.right, .start): .rightStart
        case (.right, _): .right
        }
    }
}
