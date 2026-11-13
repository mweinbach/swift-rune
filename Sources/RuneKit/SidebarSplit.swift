import Foundation
import Rune
import RuneMotion

// MARK: - WindowTitlebar, Toolbar, Sidebar, SplitView & Page (`rune_kit::shell`)

/// Compact desktop window titlebar (`rune_kit::shell::WindowTitlebar`).
public struct WindowTitlebar<State> {
    public static var defaultHeight: Float { 44.0 }

    private var keyId: String
    private var titleText: String?
    private var subtitleText: String?
    private var leadingEl: El<State>?
    private var centerEl: El<State>?
    private var tabsEl: El<State>?
    private var trailingEl: El<State>?
    private var insets: ChromeInsets
    private var heightOverride: Float?
    private var topPaddingValue: Float = 0.0
    private var leadingPaddingValue: Float = 14.0
    private var trailingPaddingValue: Float = 12.0
    private var gapValue: Float = 6.0
    private var hasBottomBorder: Bool = true
    private var fillColor: Color?

    public init(key: String = "window-titlebar", title: String? = nil) {
        self.keyId = key
        self.titleText = title
        self.insets = ChromeInsets()
    }

    public static func fromInsets(_ insets: ChromeInsets, key: String = "window-titlebar", title: String? = nil, fallback: Float = defaultHeight) -> WindowTitlebar<State> {
        var bar = WindowTitlebar(key: key, title: title)
        bar.insets = insets
        bar.heightOverride = max(insets.height > 0 ? insets.height : fallback, insets.top)
        return bar
    }

    public func title(_ value: String?) -> Self { var c = self; c.titleText = value; return c }
    public func subtitle(_ value: String?) -> Self { var c = self; c.subtitleText = value; return c }
    public func leading(_ element: El<State>?) -> Self { var c = self; c.leadingEl = element; return c }
    public func center(_ element: El<State>?) -> Self { var c = self; c.centerEl = element; return c }
    public func tabs(_ element: El<State>?) -> Self { var c = self; c.tabsEl = element; return c }
    public func trailing(_ element: El<State>?) -> Self { var c = self; c.trailingEl = element; return c }
    public func insets(_ chrome: ChromeInsets) -> Self { var c = self; c.insets = chrome; return c }
    public func height(_ h: Float) -> Self { var c = self; c.heightOverride = max(1, h); return c }
    public func topPadding(_ points: Float) -> Self { var c = self; c.topPaddingValue = max(0, points); return c }
    public func leadingPadding(_ points: Float) -> Self { var c = self; c.leadingPaddingValue = max(0, points); return c }
    public func trailingPadding(_ points: Float) -> Self { var c = self; c.trailingPaddingValue = max(0, points); return c }
    public func gap(_ points: Float) -> Self { var c = self; c.gapValue = max(0, points); return c }
    public func borderBottom(_ show: Bool) -> Self { var c = self; c.hasBottomBorder = show; return c }
    public func bg(_ color: Color) -> Self { var c = self; c.fillColor = color; return c }

    public var effectiveHeight: Float {
        max(heightOverride ?? Self.defaultHeight, insets.top)
    }

    public func build(_ k: Kit) -> El<State> {
        var leftSlot: El<State> = row()
            .key("\(keyId)-leading")
            .gap(gapValue)
            .itemsCenter()
            .pl(insets.leading + leadingPaddingValue)
        if let leadingEl {
            leftSlot = leftSlot.child(leadingEl)
        }
        if let titleText, !titleText.isEmpty {
            var titleGroup: El<State> = row().gap(8).itemsCenter()
                .child(text(titleText).font(k.ty.uiMedium).color(k.c.textBase).noWrap())
            if let subtitleText, !subtitleText.isEmpty {
                titleGroup = titleGroup.child(text(subtitleText).font(k.ty.small).color(k.c.textFaint).noWrap())
            }
            leftSlot = leftSlot.child(titleGroup)
        }

        var bar: El<State> = row()
            .key(keyId)
            // Blocked on @el: upstream uses `.role("toolbar")`, not in ElementRole yet.
            .role(.group)
            .wFull()
            .h(effectiveHeight)
            .pt(topPaddingValue)
            .gap(gapValue)
            .itemsCenter()
            .justifyBetween()
            .bg(fillColor ?? k.c.bgDeep)
        if hasBottomBorder {
            bar = bar.borderSides(bottom: 1.0, color: k.c.borderMuted)
        }
        bar = bar.child(leftSlot)
        if let tabsEl {
            bar = bar.child(
                row()
                    .key("\(keyId)-tabs")
                    .grow(1)
                    .shrink()
                    .minW(0)
                    .hFull()
                    .itemsCenter()
                    .child(tabsEl)
            )
        } else if let centerEl {
            bar = bar.child(row().key("\(keyId)-center").itemsCenter().child(centerEl))
        }
        var rightSlot: El<State> = row()
            .key("\(keyId)-trailing")
            .gap(gapValue)
            .itemsCenter()
            .pr(insets.trailing + trailingPaddingValue)
        if let trailingEl {
            rightSlot = rightSlot.child(trailingEl)
        }
        return bar.child(rightSlot)
    }
}

/// Top workspace toolbar (`rune_kit::shell::Toolbar`, `TOOLBAR_HEIGHT = 48.0`).
public struct Toolbar<State> {
    public static var height: Float { 48.0 }

    private var keyId: String
    private var titleText: String?
    private var subtitleText: String?
    private var leadingEl: El<State>?
    private var centerEl: El<State>?
    private var trailingEl: El<State>?
    private var leadingInset: Float = 0
    private var trailingInset: Float = 0
    private var hasBottomBorder: Bool = true
    private var fillColor: Color?

    public init(key: String = "toolbar", title: String? = nil) {
        self.keyId = key
        self.titleText = title
    }

    public func title(_ value: String?) -> Self { var c = self; c.titleText = value; return c }
    public func subtitle(_ value: String?) -> Self { var c = self; c.subtitleText = value; return c }
    public func leading(_ element: El<State>?) -> Self { var c = self; c.leadingEl = element; return c }
    public func center(_ element: El<State>?) -> Self { var c = self; c.centerEl = element; return c }
    public func trailing(_ element: El<State>?) -> Self { var c = self; c.trailingEl = element; return c }
    public func inset(leading: Float = 0, trailing: Float = 0) -> Self {
        var c = self
        c.leadingInset = max(0, leading)
        c.trailingInset = max(0, trailing)
        return c
    }
    public func borderBottom(_ show: Bool) -> Self { var c = self; c.hasBottomBorder = show; return c }
    public func bg(_ color: Color) -> Self { var c = self; c.fillColor = color; return c }

    public func build(_ k: Kit) -> El<State> {
        var left: El<State> = row()
            .key("\(keyId)-leading")
            .gap(8)
            .itemsCenter()
            .pl(12 + leadingInset)
        if let leadingEl {
            left = left.child(leadingEl)
        }
        if let titleText, !titleText.isEmpty {
            var stack: El<State> = col().gap(1)
                .child(text(titleText).font(k.ty.uiMedium).color(k.c.textBase).noWrap())
            if let subtitleText, !subtitleText.isEmpty {
                stack = stack.child(text(subtitleText).font(k.ty.small).color(k.c.textFaint).noWrap())
            }
            left = left.child(stack)
        }

        var bar: El<State> = row()
            .key(keyId)
            .wFull()
            .h(Self.height)
            .itemsCenter()
            .justifyBetween()
            .bg(fillColor ?? k.c.page)
        if hasBottomBorder {
            bar = bar.borderSides(bottom: 1.0, color: k.c.borderMuted)
        }
        bar = bar.child(left)
        if let centerEl {
            bar = bar.child(row().key("\(keyId)-center").itemsCenter().child(centerEl))
        }
        var right: El<State> = row()
            .key("\(keyId)-trailing")
            .gap(6)
            .itemsCenter()
            .pr(12 + trailingInset)
        if let trailingEl {
            right = right.child(trailingEl)
        }
        return bar.child(right)
    }
}

/// Metrics shared by `Sidebar`, `SidebarSection`, and `SidebarRow` (`rune_kit::shell::sidebar`).
public enum SidebarConstants {
    public static let rowHeight: Float = 28.0
    public static let twoLineRowHeight: Float = 40.0
    public static let indent: Float = 16.0
    public static let inset: Float = 8.0
}

/// Status badge/dot/spinner drawn on a `SidebarRow` (`rune_kit::shell::RowStatus`).
public enum RowStatus<State> {
    case none
    case badge(String, tone: BadgeTone = .neutral)
    case count(Int)
    case dot(Color)
    case spinner(label: String? = nil)
    case custom(El<State>)
}

/// Sidebar header row (`rune_kit::shell::SidebarHeader`).
public struct SidebarHeader<State> {
    private var keyId: String
    private var titleText: String
    private var subtitleText: String?
    private var leadingEl: El<State>?
    private var trailingEl: El<State>?
    private var onClickFn: ((inout State, inout Tx) -> Void)?

    public init(key: String = "sidebar-header", title: String) {
        self.keyId = key
        self.titleText = title
    }

    public func subtitle(_ value: String?) -> Self { var c = self; c.subtitleText = value; return c }
    public func leading(_ element: El<State>?) -> Self { var c = self; c.leadingEl = element; return c }
    public func trailing(_ element: El<State>?) -> Self { var c = self; c.trailingEl = element; return c }
    public func onClick(_ f: @escaping (inout State, inout Tx) -> Void) -> Self {
        var c = self
        c.onClickFn = f
        return c
    }

    public func build(_ k: Kit) -> El<State> {
        var titleCol: El<State> = col().grow(1).minW(0).gap(1)
            .child(text(titleText).font(k.ty.uiMedium).color(k.c.textBase).ellipsis())
        if let subtitleText, !subtitleText.isEmpty {
            titleCol = titleCol.child(text(subtitleText).font(k.ty.small).color(k.c.textFaint).ellipsis())
        }
        var header: El<State> = row()
            .key(keyId)
            .wFull()
            .minH(36)
            .px(SidebarConstants.inset)
            .py(6)
            .gap(8)
            .itemsCenter()
            .rounded(k.radius.sm)
        if let leadingEl { header = header.child(leadingEl) }
        header = header.child(titleCol)
        if let trailingEl { header = header.child(trailingEl) }
        if let onClickFn {
            header = k.interactive(header).focusRing(k.c.borderFocus).onClick(onClickFn)
        }
        return header
    }
}

/// Collapsible section inside a `Sidebar` (`rune_kit::shell::SidebarSection`).
public struct SidebarSection<State> {
    private var keyId: String
    private var titleText: String?
    private var collapsible: Bool = false
    private var collapsed: Bool = false
    private var onToggleFn: ((inout State, inout Tx) -> Void)?
    private var trailingEl: El<State>?
    private var items: [El<State>] = []

    public init(key: String = "sidebar-section", title: String? = nil) {
        self.keyId = key
        self.titleText = title
    }

    public func collapsible(_ enabled: Bool = true, collapsed: Bool = false) -> Self {
        var c = self
        c.collapsible = enabled
        c.collapsed = collapsed
        return c
    }

    public func onToggle(_ f: @escaping (inout State, inout Tx) -> Void) -> Self {
        var c = self
        c.onToggleFn = f
        return c
    }

    public func trailing(_ element: El<State>?) -> Self { var c = self; c.trailingEl = element; return c }
    public func child(_ rowEl: El<State>) -> Self { var c = self; c.items.append(rowEl); return c }
    public func children(_ rows: [El<State>]) -> Self { var c = self; c.items.append(contentsOf: rows); return c }

    public func build(_ k: Kit) -> El<State> {
        var section: El<State> = col().key(keyId).wFull().gap(2)
        if let titleText, !titleText.isEmpty {
            var header: El<State> = row()
                .key("\(keyId)-header")
                .wFull()
                .h(24)
                .px(SidebarConstants.inset)
                .gap(6)
                .itemsCenter()
                .justifyBetween()
            var labelRow: El<State> = row().gap(4).itemsCenter().grow(1).minW(0)
            if collapsible {
                let glyph = collapsed ? k.glyph.triangleRight : k.glyph.triangleDown
                labelRow = labelRow.child(Rune.icon(glyph, size: 12).color(k.c.iconFaint))
            }
            labelRow = labelRow.child(
                text(titleText).font(k.ty.smallMedium).color(k.c.textFaint).ellipsis()
            )
            header = header.child(labelRow)
            if let trailingEl {
                header = header.child(trailingEl)
            }
            if collapsible, let onToggleFn {
                header = k.interactive(header)
                    .rounded(k.radius.sm)
                    .expanded(!collapsed)
                    .focusRing(k.c.borderFocus)
                    .onClick(onToggleFn)
            }
            section = section.child(header)
        }
        if !collapsed && !items.isEmpty {
            section = section.child(col().key("\(keyId)-rows").wFull().gap(1).children(items))
        }
        return section
    }
}

/// Interactive sidebar item row with selection, indentation, status, close, rename & drag reorder
/// (`rune_kit::shell::SidebarRow`).
public struct SidebarRow<State> {
    private var keyId: String
    private var titleText: String
    private var subtitleText: String?
    private var leadingEl: El<State>?
    private var iconSpec: (svg: SVGIcon, color: Color?)?
    private var indentLevel: Int = 0
    private var selected: Bool = false
    private var active: Bool = false
    private var isDisabled: Bool = false
    private var selectOnlyFlag: Bool = false
    private var rowStatus: RowStatus<State> = .none
    private var trailingActions: [El<State>] = []
    private var onClickFn: ((inout State, inout Tx) -> Void)?
    private var onDoubleClickFn: ((inout State, inout Tx) -> Void)?
    private var onCloseFn: ((inout State, inout Tx) -> Void)?
    private var renameConfig: RenameConfig?
    private var dragReorderHandlers: DragHandlers?

    private struct RenameConfig {
        var keyPath: WritableKeyPath<State, TextEdit>
        var inputKey: String
        var onCommit: (inout State, String, inout Tx) -> Void
        var onCancel: ((inout State, inout Tx) -> Void)?
    }

    private struct DragHandlers {
        var offsetY: Float
        var isDragging: Bool
        var isHeld: Bool
        var onDown: (inout State, PointerPress, inout Tx) -> Void
        var onDrag: (inout State, Drag, inout Tx) -> Void
        var onEnd: (inout State, Bool, inout Tx) -> Void
    }

    public init(key: String, title: String) {
        self.keyId = key
        self.titleText = title
    }

    public func subtitle(_ value: String?) -> Self { var c = self; c.subtitleText = value; return c }
    public func icon(_ svg: SVGIcon, color: Color? = nil) -> Self {
        var c = self
        c.iconSpec = (svg, color)
        return c
    }
    public func leading(_ element: El<State>?) -> Self { var c = self; c.leadingEl = element; return c }
    public func indent(_ depth: Int) -> Self { var c = self; c.indentLevel = max(0, depth); return c }
    public func selected(_ on: Bool = true) -> Self { var c = self; c.selected = on; return c }
    public func active(_ on: Bool = true) -> Self { var c = self; c.active = on; return c }
    public func disabled(_ on: Bool = true) -> Self { var c = self; c.isDisabled = on; return c }
    public func selectOnly(_ on: Bool = true) -> Self { var c = self; c.selectOnlyFlag = on; return c }
    public func status(_ value: RowStatus<State>) -> Self { var c = self; c.rowStatus = value; return c }
    public func action(_ element: El<State>) -> Self { var c = self; c.trailingActions.append(element); return c }
    public func onClick(_ f: @escaping (inout State, inout Tx) -> Void) -> Self { var c = self; c.onClickFn = f; return c }
    public func onDoubleClick(_ f: @escaping (inout State, inout Tx) -> Void) -> Self { var c = self; c.onDoubleClickFn = f; return c }
    public func onClose(_ f: @escaping (inout State, inout Tx) -> Void) -> Self { var c = self; c.onCloseFn = f; return c }

    public func renaming(
        _ editKeyPath: WritableKeyPath<State, TextEdit>,
        inputKey: String? = nil,
        onCommit: @escaping (inout State, String, inout Tx) -> Void,
        onCancel: ((inout State, inout Tx) -> Void)? = nil
    ) -> Self {
        var c = self
        c.renameConfig = RenameConfig(
            keyPath: editKeyPath,
            inputKey: inputKey ?? "\(keyId)-rename",
            onCommit: onCommit,
            onCancel: onCancel
        )
        return c
    }

    public func reorder<ID: Hashable & Sendable>(
        _ keyPath: WritableKeyPath<State, Reorder<ID>>,
        id: ID,
        index: Int,
        count: Int,
        onSwap: @escaping (inout State, Int, Int) -> Void
    ) -> Self {
        let rowHeight = subtitleText == nil ? SidebarConstants.rowHeight : SidebarConstants.twoLineRowHeight
        var c = self
        c.dragReorderHandlers = DragHandlers(
            offsetY: 0,
            isDragging: false,
            isHeld: false,
            onDown: { state, press, _ in
                guard press.button == .primary else { return }
                state[keyPath: keyPath].press(id: id, index: index, at: press.window)
            },
            onDrag: { state, drag, _ in
                _ = state[keyPath: keyPath].drag(to: drag.window, rowHeight: rowHeight, count: count)
            },
            onEnd: { state, cancelled, _ in
                if let move = state[keyPath: keyPath].end(cancelled: cancelled) {
                    onSwap(&state, move.from, move.to)
                }
            }
        )
        return c
    }

    public func reorderState(_ state: Reorder<some Hashable & Sendable>, id: some Hashable & Sendable, index: Int? = nil) -> Self {
        var c = self
        let isDragged = state.isDragging && (state.activeId.map { AnyHashable($0) } == AnyHashable(id))
        let typedOffset: Float = if let index {
            state.shift(forIndex: index)
        } else if state.activeId.map({ AnyHashable($0) }) == AnyHashable(id) {
            state.offsetY
        } else {
            0
        }
        if var handlers = c.dragReorderHandlers {
            handlers.offsetY = typedOffset
            handlers.isDragging = isDragged
            handlers.isHeld = state.isHeld
            c.dragReorderHandlers = handlers
        } else if isDragged || typedOffset != 0 {
            c.dragReorderHandlers = DragHandlers(
                offsetY: typedOffset,
                isDragging: isDragged,
                isHeld: state.isHeld,
                onDown: { _, _, _ in },
                onDrag: { _, _, _ in },
                onEnd: { _, _, _ in }
            )
        }
        return c
    }

    public func build(_ k: Kit) -> El<State> {
        let height = subtitleText == nil ? SidebarConstants.rowHeight : SidebarConstants.twoLineRowHeight
        let padLeft = SidebarConstants.inset + Float(indentLevel) * SidebarConstants.indent
        let bg: Color = (selected || active) ? k.c.surfaceRaised : .transparent
        let fg: Color = isDisabled ? k.c.textFaint : ((selected || active) ? k.c.textBase : k.c.textMuted)
        let subColor = k.c.textFaint

        var content: El<State> = row()
            .key(keyId)
            .role(.listItem)
            .label(titleText)
            .itemSelected(selected)
            .wFull()
            .h(height)
            .pl(padLeft)
            .pr(SidebarConstants.inset)
            .gap(8)
            .itemsCenter()
            .rounded(k.radius.sm)
            .bg(bg)

        if let leadingEl {
            content = content.child(leadingEl)
        } else if let iconSpec {
            content = content.child(Rune.icon(iconSpec.svg, size: 15).color(iconSpec.color ?? k.c.iconMuted))
        }

        if let renameConfig {
            var input: El<State> = Rune.textInput(key: renameConfig.inputKey, renameConfig.keyPath)
                .grow(1)
                .minW(0)
                .py(2)
                .px(4)
                .font(k.ty.ui)
                .color(k.c.textBase)
                .bg(k.c.bgBase)
                .rounded(k.radius.xs)
                .border(1.0, k.c.borderFocus)
                .autofocus()
                .onSubmit { state, text, tx in
                    renameConfig.onCommit(&state, text, &tx)
                }
            if let onCancel = renameConfig.onCancel {
                input = input.onKey { state, event, tx in
                    if event.key == .escape {
                        onCancel(&state, &tx)
                        return true
                    }
                    return false
                }
            }
            content = content.child(input)
        } else {
            var textBlock: El<State> = col().grow(1).minW(0).gap(1)
                .child(text(titleText).font(selected ? k.ty.uiMedium : k.ty.ui).color(fg).ellipsis())
            if let subtitleText, !subtitleText.isEmpty {
                textBlock = textBlock.child(text(subtitleText).font(k.ty.small).color(subColor).ellipsis())
            }
            content = content.child(textBlock)
        }

        switch rowStatus {
        case .none:
            break
        case .badge(let label, let tone):
            content = content.child(k.badge(label, tone: tone))
        case .count(let n):
            content = content.child(text("\(n)").font(k.ty.small).color(k.c.textFaint).noWrap())
        case .dot(let color):
            content = content.child(el().w(7).h(7).rounded(3.5).bg(color))
        case .spinner:
            content = content.child(k.radarSpinner(key: "\(keyId)-spin", size: 12))
        case .custom(let customEl):
            content = content.child(customEl)
        }

        for act in trailingActions {
            content = content.child(act)
        }

        if let onCloseFn, !isDisabled {
            content = content.child(
                k.iconButton(
                    key: "\(keyId)-close",
                    svg: k.glyph.close,
                    label: "Close",
                    size: .sm,
                    variant: .ghost,
                    onClick: onCloseFn
                )
            )
        }

        if !isDisabled {
            if !selected && !active {
                content = content.hover(k.c.surfaceHover)
            }
            if renameConfig == nil, let onClickFn {
                content = content.focusable().focusRing(k.c.borderFocus).onClick(onClickFn)
            }
            if renameConfig == nil, let onDoubleClickFn, !selectOnlyFlag {
                content = content.onDoubleClick(onDoubleClickFn)
            }
            if let drag = dragReorderHandlers, !selectOnlyFlag {
                content = content
                    .onPointerDown(drag.onDown)
                    .onDrag(drag.onDrag)
                    .onDragEnd(drag.onEnd)
                if drag.offsetY != 0 {
                    content = content.offset(0, drag.offsetY)
                }
                if drag.isDragging {
                    content = content.z(20).shadows(k.shadowLayers(k.elevation.raised))
                }
            }
        }
        return content
    }
}

/// Top-level vertical sidebar container (`rune_kit::shell::Sidebar`).
public struct Sidebar<State> {
    private var keyId: String
    private var headerEl: El<State>?
    private var footerEl: El<State>?
    private var sectionsList: [El<State>] = []
    private var scrollable: Bool = true
    private var pad: Float = SidebarConstants.inset
    private var fillColor: Color?

    public init(key: String = "sidebar") {
        self.keyId = key
    }

    public func header(_ element: El<State>?) -> Self { var c = self; c.headerEl = element; return c }
    public func footer(_ element: El<State>?) -> Self { var c = self; c.footerEl = element; return c }
    public func section(_ element: El<State>) -> Self { var c = self; c.sectionsList.append(element); return c }
    public func sections(_ elements: [El<State>]) -> Self { var c = self; c.sectionsList.append(contentsOf: elements); return c }
    public func scrollable(_ enabled: Bool) -> Self { var c = self; c.scrollable = enabled; return c }
    public func padding(_ value: Float) -> Self { var c = self; c.pad = max(0, value); return c }
    public func bg(_ color: Color) -> Self { var c = self; c.fillColor = color; return c }

    public func build(_ k: Kit) -> El<State> {
        var body: El<State> = col()
            .key("\(keyId)-body")
            .wFull()
            .grow(1)
            .minH(0)
            .gap(10)
        if scrollable {
            body = body.scroll()
        }
        body = body.children(sectionsList)

        return col()
            .key(keyId)
            .sizeFull()
            .p(pad)
            .gap(8)
            .bg(fillColor ?? k.c.layer01)
            .child(headerEl)
            .child(body)
            .child(footerEl)
    }
}

/// Built-in sidebar/inspector toggle icon button (`rune_kit::shell::SidebarToggle`).
public struct SidebarToggle<State> {
    private var keyId: String
    private var inspector: Bool
    private var onToggleFn: (inout State, inout Tx) -> Void

    public init(
        key: String = "sidebar-toggle",
        inspector: Bool = false,
        keyPath: WritableKeyPath<State, PaneState>
    ) {
        self.keyId = key
        self.inspector = inspector
        self.onToggleFn = { state, _ in state[keyPath: keyPath].toggle() }
    }

    public init(
        key: String = "sidebar-toggle",
        inspector: Bool = false,
        onToggle: @escaping (inout State, inout Tx) -> Void
    ) {
        self.keyId = key
        self.inspector = inspector
        self.onToggleFn = onToggle
    }

    public func build(_ k: Kit) -> El<State> {
        k.iconButton(
            key: keyId,
            svg: inspector ? KitIcons.inspector : KitIcons.sidebar,
            label: inspector ? "Toggle Inspector" : "Toggle Sidebar",
            size: .sm,
            variant: .ghost,
            onClick: onToggleFn
        )
    }
}

/// Two- or three-pane split workspace shell with resizable sidebar/inspector, toolbar,
/// titlebar chrome inset awareness, collapse/restore motion, and hover-peek
/// (`rune_kit::shell::SplitView`).
public struct SplitView<State> {
    public static var gripWidth: Float { 6.0 }
    public static var dotFade: Float { 0.15 }
    public static var gripStep: Float { 8.0 }

    private struct PaneConfig {
        var keyPath: WritableKeyPath<State, PaneState>
        var state: PaneState
        var builder: (State) -> El<State>
    }

    private var keyId: String
    private var sidebarCfg: PaneConfig?
    private var inspectorCfg: PaneConfig?
    private var contentBuilder: (State) -> El<State>
    private var toolbarEl: El<State>?
    private var titlebarInsetValue: ChromeInsets = ChromeInsets()
    private var showSidebarToggle: Bool = true
    private var frameInsetValue: Float = 0
    private var toolbarInPanelValue: Bool = false
    private var sidebarPaddingValue: Float = 0
    private var paneMotionValue: PaneMotion = .slide
    private var sidebarPeekValue: SidebarPeek = .off
    private var reducedMotionValue: Bool = false

    public init(
        key: String = "split-view",
        content: @escaping (State) -> El<State>
    ) {
        self.keyId = key
        self.contentBuilder = content
    }

    public func sidebar(
        _ keyPath: WritableKeyPath<State, PaneState>,
        current state: PaneState,
        build: @escaping (State) -> El<State>
    ) -> Self {
        var c = self
        c.sidebarCfg = PaneConfig(keyPath: keyPath, state: state, builder: build)
        return c
    }

    public func inspector(
        _ keyPath: WritableKeyPath<State, PaneState>,
        current state: PaneState,
        build: @escaping (State) -> El<State>
    ) -> Self {
        var c = self
        c.inspectorCfg = PaneConfig(keyPath: keyPath, state: state, builder: build)
        return c
    }

    public func toolbar(_ element: El<State>?) -> Self { var c = self; c.toolbarEl = element; return c }
    public func titlebarInset(_ insets: ChromeInsets) -> Self { var c = self; c.titlebarInsetValue = insets; return c }
    public func hideSidebarToggle(_ hidden: Bool = true) -> Self { var c = self; c.showSidebarToggle = !hidden; return c }
    public func sidebarToggle(_ shown: Bool) -> Self { var c = self; c.showSidebarToggle = shown; return c }
    public func frameInset(_ inset: Float) -> Self { var c = self; c.frameInsetValue = max(0, inset); return c }
    public func toolbarInPanel(_ inside: Bool = true) -> Self { var c = self; c.toolbarInPanelValue = inside; return c }
    public func sidebarPadding(_ pad: Float) -> Self { var c = self; c.sidebarPaddingValue = max(0, pad); return c }
    public func paneMotion(_ motion: PaneMotion) -> Self { var c = self; c.paneMotionValue = motion; return c }
    public func sidebarPeek(_ peek: SidebarPeek) -> Self { var c = self; c.sidebarPeekValue = peek; return c }
    public func reducedMotion(_ reduced: Bool) -> Self { var c = self; c.reducedMotionValue = reduced; return c }

    public func build(_ state: State, kit k: Kit) -> El<State> {
        let spring = paneMotionValue.spring(reducedMotion: reducedMotionValue)

        func buildGrip(
            key gripKey: String,
            cfg: PaneConfig,
            positiveGrows: Bool
        ) -> El<State> {
            let keyPath = cfg.keyPath
            let isActive = cfg.state.isResizing
            var handle: El<State> = col()
                .key(gripKey)
                .w(Self.gripWidth)
                .hFull()
                .center()
                .gap(Self.gripStep - 2)
                .bg(.transparent)
                .borderSides(
                    right: positiveGrows ? 0 : 1.0,
                    left: positiveGrows ? 1.0 : 0,
                    color: k.c.borderMuted
                )
                .onPointerDown { s, press, _ in
                    guard press.button == .primary else { return }
                    s[keyPath: keyPath].pressGrip(at: press.window)
                }
                .onDrag { s, drag, _ in
                    s[keyPath: keyPath].dragGrip(
                        deltaX: drag.delta.x,
                        at: drag.window,
                        positiveGrows: positiveGrows
                    )
                }
                .onDragEnd { s, cancelled, _ in
                    if cancelled {
                        s[keyPath: keyPath].cancelResize()
                    } else {
                        s[keyPath: keyPath].releaseGrip()
                    }
                }
                .onDoubleClick { s, _ in
                    s[keyPath: keyPath].resetWidth()
                }
            let dotAlpha: Float = isActive ? 0.55 : Self.dotFade
            for _ in 0..<3 {
                handle = handle.child(el().w(2).h(2).rounded(1).bg(k.c.textMuted.alpha(dotAlpha)))
            }
            return handle
        }

        // Main center column (optional top toolbar + content)
        var mainCol: El<State> = col().key("\(keyId)-main").grow(1).minW(0).hFull()
        var effectiveToolbar = toolbarEl
        if let sidebarCfg, showSidebarToggle, sidebarCfg.state.isCollapsed {
            let toggleBtn = SidebarToggle<State>(
                key: "\(keyId)-sidebar-toggle",
                keyPath: sidebarCfg.keyPath
            ).build(k)
            if let bar = effectiveToolbar {
                effectiveToolbar = row().key("\(keyId)-toolbar-wrap").wFull().itemsCenter()
                    .child(row().pl(8).child(toggleBtn))
                    .child(row().grow(1).minW(0).child(bar))
            } else if toolbarInPanelValue {
                effectiveToolbar = row()
                    .key("\(keyId)-toggle-bar")
                    .wFull()
                    .h(Toolbar<State>.height)
                    .px(12)
                    .itemsCenter()
                    .child(toggleBtn)
                    .borderSides(bottom: 1.0, color: k.c.borderMuted)
            }
        }
        if let effectiveToolbar, !toolbarInPanelValue {
            mainCol = mainCol.child(effectiveToolbar)
        }
        let bodyEl: El<State> = el().key("\(keyId)-content").grow(1).minH(0).wFull().child(contentBuilder(state))
        if let effectiveToolbar, toolbarInPanelValue {
            let panel: El<State> = col()
                .key("\(keyId)-panel")
                .sizeFull()
                .rounded(k.radius.lg)
                .bg(k.c.page)
                .border(1.0, k.c.borderMuted)
                .clip(true)
                .child(effectiveToolbar)
                .child(bodyEl)
            mainCol = mainCol.p(frameInsetValue).child(panel)
        } else {
            mainCol = mainCol.child(bodyEl)
        }

        var rootRow: El<State> = row().key(keyId).sizeFull().bg(k.c.layer01)

        if let sidebarCfg {
            let pane = sidebarCfg.state
            let sbW = pane.shownWidth
            if sbW > 0 {
                var sbPane: El<State> = col()
                    .key("\(keyId)-sidebar-pane")
                    .w(sbW)
                    .hFull()
                    .p(sidebarPaddingValue)
                    .pt(max(sidebarPaddingValue, titlebarInsetValue.top))
                    .clip(true)
                    .child(sidebarCfg.builder(state))
                if let spring, !pane.fromPeek {
                    sbPane = sbPane.animateLayout(spring)
                }
                rootRow = rootRow
                    .child(sbPane)
                    .child(buildGrip(key: "\(keyId)-sidebar-grip", cfg: sidebarCfg, positiveGrows: true))
            } else if sidebarPeekValue.isEnabled {
                let sbKeyPath = sidebarCfg.keyPath
                let edgeTrigger: El<State> = el()
                    .key("\(keyId)-peek-edge")
                    .pin(top: sidebarPeekValue.belowY ?? titlebarInsetValue.top, bottom: 0, left: 0)
                    .w(sidebarPeekValue.edgeWidth)
                    .z(34)
                    .onHover { s, hovering, _ in
                        if hovering {
                            s[keyPath: sbKeyPath].peek()
                        }
                    }
                rootRow = rootRow.child(edgeTrigger)
                if pane.isPeeking {
                    var peekDrawer: El<State> = col()
                        .key("\(keyId)-sidebar-peek")
                        .pin(top: max(8, titlebarInsetValue.top + 8), bottom: 8, left: 8)
                        .w(pane.width)
                        .rounded(k.radius.lg)
                        .bg(k.c.layer01)
                        .border(1.0, k.c.borderBase)
                        .shadows(k.shadowLayers(k.elevation.overlay))
                        .z(35)
                        .clip(true)
                        .onHover { s, hovering, _ in
                            if !hovering {
                                s[keyPath: sbKeyPath].endPeek()
                            }
                        }
                        .child(sidebarCfg.builder(state))
                    if let spring {
                        peekDrawer = peekDrawer.animateLayout(spring)
                    }
                    rootRow = rootRow.child(peekDrawer)
                }
            }
        }

        rootRow = rootRow.child(mainCol)

        if let inspectorCfg {
            let pane = inspectorCfg.state
            let insW = pane.shownWidth
            if insW > 0 {
                var insPane: El<State> = col()
                    .key("\(keyId)-inspector-pane")
                    .w(insW)
                    .hFull()
                    .p(sidebarPaddingValue)
                    .clip(true)
                    .child(inspectorCfg.builder(state))
                if let spring {
                    insPane = insPane.animateLayout(spring)
                }
                rootRow = rootRow
                    .child(buildGrip(key: "\(keyId)-inspector-grip", cfg: inspectorCfg, positiveGrows: false))
                    .child(insPane)
            }
        }

        return rootRow
    }
}

/// Centered / padded workspace page frame (`rune_kit::shell::Page`).
public struct Page<State> {
    private var keyId: String
    private var maxW: Float?
    private var pad: Float = 24.0
    private var gapVal: Float = 20.0
    private var scrollable: Bool = true
    private var headerEl: El<State>?
    private var childrenEls: [El<State>] = []

    public init(key: String = "page") {
        self.keyId = key
    }

    public func maxWidth(_ value: Float) -> Self { var c = self; c.maxW = max(1, value); return c }
    public func padding(_ value: Float) -> Self { var c = self; c.pad = max(0, value); return c }
    public func gap(_ value: Float) -> Self { var c = self; c.gapVal = max(0, value); return c }
    public func scrollable(_ enabled: Bool) -> Self { var c = self; c.scrollable = enabled; return c }
    public func header(_ element: El<State>?) -> Self { var c = self; c.headerEl = element; return c }
    public func child(_ element: El<State>) -> Self { var c = self; c.childrenEls.append(element); return c }
    public func children(_ elements: [El<State>]) -> Self { var c = self; c.childrenEls.append(contentsOf: elements); return c }

    public func build(_ k: Kit) -> El<State> {
        var inner: El<State> = col()
            .key("\(keyId)-inner")
            .wFull()
            .gap(gapVal)
            .p(pad)
        if let maxW {
            inner = inner.maxW(maxW)
        }
        if let headerEl {
            inner = inner.child(headerEl)
        }
        inner = inner.children(childrenEls)

        var outer: El<State> = col()
            .key(keyId)
            .sizeFull()
            .itemsCenter()
            .bg(k.c.page)
        if scrollable {
            outer = outer.scroll()
        }
        return outer.child(inner)
    }
}
