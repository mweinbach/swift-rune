import Foundation
import Rune

/// Visual metrics and colours for `Tree` and `TreeRowItem` (`rune_kit::tree::TreeStyle`).
public struct TreeStyle: Sendable, Equatable {
    public var rowHeight: Float
    /// Points each level indents.
    public var indent: Float
    /// Horizontal padding at the row's ends.
    public var padding: Float
    /// Hairlines down each indent level.
    public var guides: Bool
    public var guide: Color
    public var selected: Color
    public var hover: Color
    public var gap: Float
    public var radius: Float
    public var labelFont: TextStyle
    public var labelRest: Color
    public var labelSelected: Color
    public var labelFade: Float?
    public var chevronOnly: Bool
    public var chevron: SVGIcon?
    public var chevronNudge: Float
    public var chevronRest: Color
    public var chevronSelected: Color
    public var guidesHover: Float?

    public init(
        rowHeight: Float = 24.0,
        indent: Float = 14.0,
        padding: Float = 6.0,
        guides: Bool = true,
        guide: Color,
        selected: Color,
        hover: Color,
        gap: Float = 4.0,
        radius: Float,
        labelFont: TextStyle,
        labelRest: Color,
        labelSelected: Color,
        labelFade: Float? = nil,
        chevronOnly: Bool = false,
        chevron: SVGIcon? = nil,
        chevronNudge: Float = 0.0,
        chevronRest: Color,
        chevronSelected: Color,
        guidesHover: Float? = nil
    ) {
        self.rowHeight = rowHeight
        self.indent = indent
        self.padding = padding
        self.guides = guides
        self.guide = guide
        self.selected = selected
        self.hover = hover
        self.gap = gap
        self.radius = radius
        self.labelFont = labelFont
        self.labelRest = labelRest
        self.labelSelected = labelSelected
        self.labelFade = labelFade
        self.chevronOnly = chevronOnly
        self.chevron = chevron
        self.chevronNudge = chevronNudge
        self.chevronRest = chevronRest
        self.chevronSelected = chevronSelected
        self.guidesHover = guidesHover
    }

    public static func fromKit(_ k: Kit) -> TreeStyle {
        TreeStyle(
            rowHeight: 24.0,
            indent: 14.0,
            padding: 6.0,
            guides: true,
            guide: k.c.borderMuted,
            selected: k.alpha(k.c.textAccent, k.dark ? 0.24 : 0.2),
            hover: k.c.hover,
            gap: 4.0,
            radius: k.radius.sm,
            labelFont: k.ty.ui,
            labelRest: k.c.textBase,
            labelSelected: k.c.textBase,
            labelFade: nil,
            chevronOnly: false,
            chevron: nil,
            chevronNudge: 0.0,
            chevronRest: k.c.iconMuted,
            chevronSelected: k.c.iconMuted,
            guidesHover: nil
        )
    }

    public func hover(_ c: Color) -> TreeStyle {
        var copy = self
        copy.hover = c
        return copy
    }

    public func gap(_ gap: Float) -> TreeStyle {
        var copy = self
        copy.gap = gap
        return copy
    }

    public func radius(_ r: Float) -> TreeStyle {
        var copy = self
        copy.radius = r
        return copy
    }

    public func label(_ font: TextStyle, rest: Color, selected: Color) -> TreeStyle {
        var copy = self
        copy.labelFont = font
        copy.labelRest = rest
        copy.labelSelected = selected
        return copy
    }

    public func fadeLongLabels(_ width: Float) -> TreeStyle {
        var copy = self
        copy.labelFade = max(0.0, width)
        return copy
    }

    public func chevronOnlyFolders(_ on: Bool) -> TreeStyle {
        var copy = self
        copy.chevronOnly = on
        return copy
    }

    public func chevron(_ glyph: SVGIcon) -> TreeStyle {
        var copy = self
        copy.chevron = glyph
        return copy
    }

    public func chevronColors(rest: Color, selected: Color) -> TreeStyle {
        var copy = self
        copy.chevronRest = rest
        copy.chevronSelected = selected
        return copy
    }

    public func chevronNudge(_ dy: Float) -> TreeStyle {
        var copy = self
        copy.chevronNudge = dy
        return copy
    }

    public func guidesOnHover(_ opacity: Float) -> TreeStyle {
        var copy = self
        copy.guidesHover = min(1.0, max(0.0, opacity))
        return copy
    }
}

/// Builder for a standard tree row after its indent and chevron (`rune_kit::tree::TreeItem`).
/// Named `TreeRowItem` in Swift because `TreeItem<ID>` is kept for legacy callers.
public struct TreeRowItem<State> {
    public var labelText: String
    public var iconSVG: SVGIcon?
    public var iconColorValue: Color?
    public var labelColorValue: Color?
    public var highlightQuery: String?
    public var changesPair: (UInt32, UInt32)?
    public var dotColor: Color?
    public var badgeText: String?
    public var trailingElements: [El<State>] = []

    public init(_ label: String) {
        self.labelText = label
    }

    /// A file tree's row: the node's name and its folder or file icon (`FileNode.icon(isOpen:)`).
    public static func file<D>(_ node: FileNode<D>, row: TreeRow) -> TreeRowItem<State> {
        TreeRowItem(node.name).icon(node.icon(isOpen: row.expanded == true))
    }

    public func icon(_ i: SVGIcon) -> TreeRowItem<State> {
        var copy = self
        copy.iconSVG = i
        return copy
    }

    public func iconColor(_ c: Color) -> TreeRowItem<State> {
        var copy = self
        copy.iconColorValue = c
        return copy
    }

    public func labelColor(_ c: Color) -> TreeRowItem<State> {
        var copy = self
        copy.labelColorValue = c
        return copy
    }

    public func highlight(_ query: String) -> TreeRowItem<State> {
        var copy = self
        copy.highlightQuery = query.isEmpty ? nil : query
        return copy
    }

    public func changes(added: UInt32, removed: UInt32) -> TreeRowItem<State> {
        var copy = self
        copy.changesPair = (added > 0 || removed > 0) ? (added, removed) : nil
        return copy
    }

    public func dot(_ c: Color) -> TreeRowItem<State> {
        var copy = self
        copy.dotColor = c
        return copy
    }

    public func badge(_ b: String) -> TreeRowItem<State> {
        var copy = self
        copy.badgeText = b
        return copy
    }

    public func trailing(_ e: El<State>) -> TreeRowItem<State> {
        var copy = self
        copy.trailingElements.append(e)
        return copy
    }

    /// Builds the row element without interaction handlers (reusable by `SidebarRow` etc.).
    public func build(kit k: Kit, row r: TreeRow, style: TreeStyle) -> El<State> {
        let c = k.c
        let pad = style.padding
        let chevronW: Float = 16.0

        var e: El<State> = row()
            .role(.treeItem)
            .label(labelText)
            .itemSelected(r.selected)
            .focusSelected(r.selected)
            .wFull()
            .h(style.rowHeight)
            .shrink(0.0)
            .pl(pad + Float(r.depth) * style.indent)
            .pr(pad)
            .gap(style.gap)
            .itemsCenter()
            .rounded(style.radius)
            .animate(k.motion.control)

        e.a11yLevel = Int(r.depth) + 1
        if let open = r.expanded {
            e = e.expanded(open)
        }

        var said: [String] = []
        if let (add, del) = changesPair {
            if add > 0 { said.append("\(add) added") }
            if del > 0 { said.append("\(del) removed") }
        }
        if let badgeText {
            said.append(badgeText)
        }
        e = e.description(said.joined(separator: ", "))

        e = r.selected ? e.bg(style.selected) : e.hover(style.hover)
        if r.cursor && r.multi {
            e = e.outline(width: 1.0, offset: -1.0, color: c.borderFocus)
        }

        if style.guides {
            for level in 0..<r.depth {
                let x = pad + Float(level) * style.indent + chevronW * 0.5 - 0.5
                var guide: El<State> = el()
                    .key("guide\(level)")
                    .pin(top: 0.0, bottom: 0.0, left: x)
                    .w(1.0)
                    .bg(style.guide)
                    .a11yHidden()
                if let opacity = style.guidesHover { guide = guide.groupOpacity(0, opacity) }
                e = e.child(guide)
            }
        }

        let isFolder = r.expanded != nil
        let iconInLane = style.chevronOnly && !isFolder && iconSVG != nil
        let chevronBox: El<State> = el().key("chevron").size(chevronW, chevronW).itemsCenter().justifyCenter().a11yHidden()
        if let open = r.expanded {
            let chevronColor = r.selected ? style.chevronSelected : style.chevronRest
            let chevronGlyph: El<State> = Rune.icon(style.chevron ?? k.glyph.chevronDown, size: 16.0)
                .key("glyph")
                .color(chevronColor)
                .iconRotation(open ? 0.0 : -.pi * 0.5)
                .mirrorInRtl()
                .animate(k.motion.control)
                .offset(0.0, style.chevronNudge)
            e = e.child(chevronBox.child(chevronGlyph))
        } else if !iconInLane {
            e = e.child(chevronBox)
        }

        if let svg = iconSVG, !(style.chevronOnly && isFolder) {
            e = e.child(
                Rune.icon(svg, size: 16.0)
                    .key("icon")
                    .color(iconColorValue ?? c.iconMuted)
                    .a11yHidden()
            )
        }

        let labelColor = labelColorValue ?? (r.selected ? style.labelSelected : style.labelRest)
        let labelFont = style.labelFont
        let labelEl: El<State>
        if let query = highlightQuery, let range = Self.findCI(labelText, query) {
            let prefix = String(labelText[..<range.lowerBound])
            let match = String(labelText[range])
            let suffix = String(labelText[range.upperBound...])
            var spans: [TextSpan] = []
            if !prefix.isEmpty {
                spans.append(TextSpan(prefix, color: labelColor))
            }
            spans.append(TextSpan(
                match,
                color: c.textBase,
                background: k.alpha(c.textAccent, 0.22),
                weight: 650.0,
                pad: 1.0
            ))
            if !suffix.isEmpty {
                spans.append(TextSpan(suffix, color: labelColor))
            }
            labelEl = rich(spans)
        } else {
            labelEl = text(labelText)
        }

        var label = labelEl
            .key("label")
            .font(labelFont)
            .color(labelColor)
            .grow(1.0)
            .shrink(1.0)
            .minW(0.0)
        if let width = style.labelFade {
            label = label.truncateFadeWidth(width / max(1, labelFont.size))
        } else {
            label = label.truncate()
        }
        e = e.child(label.helpWhenTruncated(labelText).a11yHidden())

        if let (add, del) = changesPair {
            var counts: El<State> = row().key("changes").gap(4.0).itemsCenter().a11yHidden()
            let f = k.ty.textXsmall.features("'tnum' 1")
            if add > 0 {
                counts = counts.child(text("+\(add)").key("added").font(f).color(c.success.icon))
            }
            if del > 0 {
                counts = counts.child(text("\u{2212}\(del)").key("removed").font(f).color(c.danger.icon))
            }
            e = e.child(counts)
        }

        if let b = badgeText {
            e = e.child(text(b).key("badge").font(k.ty.textXsmallMedium).color(c.textMuted).a11yHidden())
        }
        if let d = dotColor {
            e = e.child(el().key("dot").size(6.0, 6.0).rounded(3.0).bg(d).ml(5.0).mr(5.0).a11yHidden())
        }
        for t in trailingElements {
            e = e.child(t)
        }
        return e
    }

    private static func findCI(_ s: String, _ q: String) -> Range<String.Index>? {
        let folded = s.lowercased()
        guard folded.utf8.count == s.utf8.count else { return s.range(of: q, options: .literal) }
        guard let range = folded.range(of: q.lowercased(), options: .literal) else { return nil }
        let bytes = s.utf8
        let start = bytes.index(bytes.startIndex, offsetBy: folded.utf8.distance(from: folded.startIndex, to: range.lowerBound))
        let end = bytes.index(start, offsetBy: folded.utf8.distance(from: range.lowerBound, to: range.upperBound))
        guard let lo = start.samePosition(in: s), let hi = end.samePosition(in: s) else { return nil }
        return lo..<hi
    }
}

/// A virtualised tree over a `TreeModel` stored in `State` (`rune_kit::tree::Tree`).
public struct Tree<State, T: Sendable> {
    private let get: (State) -> TreeModel<T>
    private let update: (inout State, (inout TreeModel<T>) -> Void) -> Void
    private let label: (T) -> String
    private var rowBuilder: ((T, TreeRow) -> TreeRowItem<State>)?
    private var onSelectHandler: ((inout State, String, inout Tx) -> Void)?
    private var onOpenHandler: ((inout State, String, inout Tx) -> Void)?
    private var styleOverride: TreeStyle?
    private var a11yName: String?
    private var rtl: Bool = false

    public init(
        _ keyPath: WritableKeyPath<State, TreeModel<T>>,
        label: @escaping (T) -> String
    ) {
        self.get = { $0[keyPath: keyPath] }
        self.update = { state, body in body(&state[keyPath: keyPath]) }
        self.label = label
    }

    public init(
        get: @escaping (State) -> TreeModel<T>,
        update: @escaping (inout State, (inout TreeModel<T>) -> Void) -> Void,
        label: @escaping (T) -> String
    ) {
        self.get = get
        self.update = update
        self.label = label
    }

    public func row(_ f: @escaping (T, TreeRow) -> TreeRowItem<State>) -> Tree<State, T> {
        var copy = self
        copy.rowBuilder = f
        return copy
    }

    public func onSelect(_ f: @escaping (inout State, String, inout Tx) -> Void) -> Tree<State, T> {
        var copy = self
        copy.onSelectHandler = f
        return copy
    }

    public func onOpen(_ f: @escaping (inout State, String, inout Tx) -> Void) -> Tree<State, T> {
        var copy = self
        copy.onOpenHandler = f
        return copy
    }

    public func style(_ s: TreeStyle) -> Tree<State, T> {
        var copy = self
        copy.styleOverride = s
        return copy
    }

    public func name(_ n: String) -> Tree<State, T> {
        var copy = self
        copy.a11yName = n
        return copy
    }

    public func rightToLeft(_ on: Bool) -> Tree<State, T> {
        var copy = self
        copy.rtl = on
        return copy
    }

    public func build(_ state: State, cx: Cx<State>? = nil, kit k: Kit) -> El<State> {
        let style = styleOverride ?? TreeStyle.fromKit(k)
        let get = self.get
        let model = get(state)
        let count = model.visibleCount
        let treeKey = model.key
        let rh = max(1.0, style.rowHeight)
        let upd = update
        let makeItem = rowBuilder
        let rowLabel = label
        let selectRow = onSelectHandler
        let openRow = onOpenHandler

        let rows: El<State> = col()
            .key("\(treeKey)-rows", byteExact: true)
            .wFull()
            .growth()
            .virtualRows(count: count, estimatedRowHeight: rh, byteExactKeys: true, key: { state, index in
                get(state).visibleID(at: index) ?? ""
            }, build: { state, index in
                guard let (data, row) = get(state).row(at: index) else { return el() }
                let item = makeItem?(data, row) ?? TreeRowItem(rowLabel(data))
                let id = row.id
                let isFolder = row.expanded != nil
                var element = item.build(kit: k, row: row, style: style)
                    .key(id)
                    .onClickPress { state, press, tx in
                        tx.focus(treeKey)
                        upd(&state) { model in
                            let plain = model.click(id, mods: press.mods)
                            if isFolder && plain { model.toggle(id) }
                        }
                        selectRow?(&state, id, &tx)
                    }
                    .focusable(false)
                if !isFolder, let openRow {
                    element = element.onDoubleClick { state, tx in openRow(&state, id, &tx) }
                }
                return element
            })
            .virtualRowsVersion(model.visibleOrderVersion)

        let viewport = col()
            .key("\(treeKey)-viewport", byteExact: true)
            .wFull()
            .grow(1.0)
            .minH(0.0)
            .scrollY()
            .onLayoutTx { state, rect, tx in
                upd(&state) { model in
                    if model.viewport == rect[3] && model.rowHeight == rh { tx.liveOnly() }
                    model.viewport = rect[3]
                    model.rowHeight = rh
                }
            }
            .child(rows)

        let isRtl = rtl

        var root: El<State> = col()
            .key(treeKey, byteExact: true)
            .role(.tree)
            .focusable(true)
            .wFull()
            .child(viewport)
            .onKey { s, ev, tx in
                var before: String?
                var after: String?
                var outcome: TreeKey = .ignored
                upd(&s) { m in
                    m.setRightToLeft(isRtl)
                    before = m.cursorID
                    outcome = m.handleKey(ev, label: rowLabel, tx: &tx)
                    after = m.cursorID
                }
                switch outcome {
                case .ignored:
                    return false
                case .handled:
                    if let after, before?.utf8.elementsEqual(after.utf8) != true {
                        selectRow?(&s, after, &tx)
                    }
                    return true
                case .open(let id):
                    openRow?(&s, id, &tx)
                    return true
                }
            }

        if let a11yName { root = root.label(a11yName) }
        if let cursor = model.cursorID { root = root.activeDescendant(cursor) }
        if style.guidesHover != nil { root = root.hoverGroup() }
        return root
    }
}

extension Kit {
    /// Renders a `Tree` view bound to a `TreeModel` in `State`.
    public func tree<State, T: Sendable>(
        _ keyPath: WritableKeyPath<State, TreeModel<T>>,
        state: State,
        cx: Cx<State>? = nil,
        label: @escaping (T) -> String,
        row: ((T, TreeRow) -> TreeRowItem<State>)? = nil,
        onSelect: ((inout State, String, inout Tx) -> Void)? = nil,
        onOpen: ((inout State, String, inout Tx) -> Void)? = nil,
        style: TreeStyle? = nil,
        name: String? = nil,
        rightToLeft: Bool = false
    ) -> El<State> {
        var builder = Tree(keyPath, label: label)
        if let row { builder = builder.row(row) }
        if let onSelect { builder = builder.onSelect(onSelect) }
        if let onOpen { builder = builder.onOpen(onOpen) }
        if let style { builder = builder.style(style) }
        if let name { builder = builder.name(name) }
        if rightToLeft { builder = builder.rightToLeft(true) }
        return builder.build(state, cx: cx, kit: self)
    }
}
