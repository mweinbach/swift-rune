import Foundation
import RuneMotion

/// Document-only additions to the shared accessibility tree. The DOM uses actual Rune paths for
/// events; HTML anchor ids use the authored key and are limited to valid fragment identifiers.
struct WebDocumentAccessibilityNode: Equatable, Sendable {
    var anchor: String?
    var role: String?
    var selectable = false
    var scrollX: Float?
    var contentWidth: Float?
    var font: Font?
    var text: String?
    var inlineRange: Range<Int>?

    struct Font: Equatable, Sendable {
        var family: String
        var size: Float
        var weight: Float
        var lineHeight: Float
        var tracking: Float
        var italic: Bool
        var align: String

        func write<Fields: AccessibilityDumpFields>(to fields: inout Fields) throws(Fields.Failure) {
            try fields.set(.family, family)
            try fields.set(.size, size)
            try fields.set(.weight, weight)
            try fields.set(.lineHeight, lineHeight)
            try fields.set(.tracking, tracking)
            try fields.set(.italic, italic)
            try fields.set(.align, align)
        }
    }

    func write<Fields: AccessibilityDumpFields>(to fields: inout Fields) throws(Fields.Failure) {
        if let anchor { try fields.set(.anchor, anchor) }
        if selectable { try fields.set(.selectable, true) }
        if let text { try fields.set(.documentText, text) }
        if let inlineRange {
            try fields.set(.inlineStart, inlineRange.lowerBound)
            try fields.set(.inlineEnd, inlineRange.upperBound)
        }
        if let scrollX, let contentWidth {
            try fields.set(.pageScrollX, scrollX)
            try fields.set(.pageContentWidth, contentWidth)
        }
        if let font { try fields.setFont(font) }
    }
}

func webAnchorID(_ key: String?) -> String? {
    guard let key, let first = key.utf8.first else { return nil }
    func letter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) }
    guard letter(first), key.utf8.allSatisfy({ letter($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
    return key
}

/// Native scrolling and canvas rendering have different coordinate origins. Keep positions in
/// document space, including the content inside nested horizontal DOM scrolling elements.
struct WebAccessibilityDocument<State> {
    private let runtime: Runtime<State>
    var width: Float { runtime.viewport.x }
    var height: Float { runtime.pageHeight }

    init?(_ runtime: Runtime<State>) {
        guard runtime.isPageMode else { return nil }
        self.runtime = runtime
    }

    func project(_ root: inout AccessibilityNode) {
        let nodes = runtime.flatNodes
        let families = runtime.textSystem.families()
        var childShift = [Double](repeating: 0, count: nodes.count)
        var inheritedSelection = [Bool](repeating: false, count: nodes.count)
        for (i, node) in nodes.enumerated() {
            let parentX = node.parentIndex.map { childShift[$0] } ?? 0
            let ownsHorizontalScroll = node.el.layout.scrollAxes == [.horizontal]
            childShift[i] = parentX + Double(ownsHorizontalScroll ? runtime.scrollOffsets[node.path]?.x ?? 0 : 0)
            let selects = node.parentIndex.map { inheritedSelection[$0] } ?? true
            inheritedSelection[i] = selects && webPageTextSelects(node.el)
        }
        let dy = Double(runtime.pageOffset)
        func visit(_ item: inout AccessibilityNode, inheritedX: Double, ownerBox: MotionRect? = nil) {
            let index = item.runtimePath.flatMap { runtime.nodeByPath[$0] }
            var x = inheritedX
            var descendantX = x
            var metadata = item.webDocument ?? WebDocumentAccessibilityNode()
            var layoutBox = item.webDocument?.inlineRange == nil ? nil : ownerBox
            var padding = Sides.all(0)
            if let index {
                let model = nodes[index]
                let el = model.el
                layoutBox = model.unscrolledRect
                x = model.parentIndex.map { childShift[$0] } ?? 0
                descendantX = childShift[index]
                let htmlRole = el.runtimeExtras["htmlRole"] as? String
                if htmlRole == "article" || htmlRole == "alertdialog" { metadata.role = htmlRole }
                if Self.carriesAnchor(item, htmlRole: htmlRole) {
                    metadata.anchor = webAnchorID(model.key)
                }
                if el.layout.scrollAxes == [.horizontal] {
                    metadata.scrollX = runtime.scrollOffsets[model.path]?.x ?? 0
                    metadata.contentWidth = max(model.localSize.x, model.contentSize.x)
                }
                if !item.isSecure, el.handlers.editLens == nil,
                   let text = el.plainText ?? el.richSpans?.map(\.text).joined() {
                    metadata.selectable = el.isSelectable || inheritedSelection[index]
                    if item.role == .text || item.role == .heading { padding = el.layout.padding }
                    let printable = projectText(text, el: el, path: model.path, item: &item)
                    if printable != item.label { metadata.text = printable }
                    let s = el.textStyle
                    let align: String = switch s.align {
                    case .leading: "left"
                    case .center: "center"
                    case .trailing: "right"
                    case .justified: "justify"
                    }
                    metadata.font = .init(family: s.family.stack(sans: families.sans, mono: families.mono), size: s.size,
                                          weight: s.weight, lineHeight: s.lineHeight ?? s.size * 1.25,
                                          tracking: s.letterSpacing, italic: s.italic, align: align)
                }
            }
            if index == nil, item.runtimePath == nil, item.id == "root" {
                item.frame = .fromXYWH(0, 0, width, height)
            } else {
                let r = item.frame
                let left = Self.coordinate(r.left, offset: x, layout: layoutBox?.left)
                let top = Self.coordinate(r.top, offset: dy, layout: layoutBox?.top)
                let right = Self.coordinate(r.right, offset: x, layout: layoutBox?.right)
                let bottom = Self.coordinate(r.bottom, offset: dy, layout: layoutBox?.bottom)
                func rounded(_ v: Float) -> Float { (v * 10).rounded() / 10 }
                item.frame = .fromXYWH(rounded(left + padding.left), rounded(top + padding.top),
                                       rounded(max(0, right - left - padding.left - padding.right)),
                                       rounded(max(0, bottom - top - padding.top - padding.bottom)))
            }
            item.webDocument = metadata == WebDocumentAccessibilityNode() ? nil : metadata
            for i in item.children.indices { visit(&item.children[i], inheritedX: descendantX, ownerBox: layoutBox) }
        }
        visit(&root, inheritedX: 0)
        WebDocumentInlineFlow.project(&root, runtime: runtime)
    }

    /// When subtracting the band origin loses a low bit of a layout edge, restore the original
    /// edge before rounding. Animated, scaled and internally scrolled boxes keep their drawn pose.
    private static func coordinate(_ drawn: Float, offset: Double, layout: Float?) -> Float {
        let restored = Double(drawn) + offset
        if let layout, abs(restored - Double(layout)) <= Double(drawn.ulp + Float(offset).ulp + layout.ulp) {
            return layout
        }
        return Float(restored)
    }

    /// HTML ranges address UTF-16 units after noncopyable UTF-8 ranges are removed. Split at link
    /// boundaries once so a paragraph with many links does not repeatedly scan its entire prefix.
    private func projectText(_ text: String, el: El<State>, path: String, item: inout AccessibilityNode) -> String {
        let excluded = el.uncopiedRanges
        let length = text.utf8.count
        let links = el.textLinks
        guard !links.isEmpty else {
            return excluded.isEmpty ? text : CopyJoin.copySlice(in: text, range: 0..<length, uncopied: excluded)
        }
        let ranges = links.map { link in
            SelectionMath.floorCharBoundary(in: text, offset: link.byteRange.lowerBound)..<SelectionMath.floorCharBoundary(in: text, offset: link.byteRange.upperBound)
        }
        var boundaries: Set<Int> = [0, length]
        for range in ranges {
            boundaries.insert(range.lowerBound)
            boundaries.insert(range.upperBound)
        }
        var units: [Int: Int] = [0: 0]
        var previous = 0, count = 0
        var printable = ""
        for bound in boundaries.sorted() where bound > previous {
            let part = CopyJoin.copySlice(in: text, range: previous..<bound, uncopied: excluded)
            printable += part
            count += part.utf16.count
            units[bound] = count
            previous = bound
        }
        let prefix = path + "#link-"
        // Glyph hit boxes only exist inside the painted band. Native inline HTML anchors belong
        // to the whole document and the browser lays them out directly in the parent's text.
        item.children.removeAll { $0.runtimePath?.hasPrefix(prefix) == true }
        let focused = runtime.focusedPath == path ? runtime.focusedLinkIndex ?? 0 : nil
        for (k, link) in links.enumerated() {
            guard let start = units[ranges[k].lowerBound], let end = units[ranges[k].upperBound], end > start else { continue }
            let focusable = el.focusable && !item.isDisabled
            var actions: [AccessibilityAction] = item.isDisabled ? [] : [.press]
            if focusable { actions.append(.focus) }
            let label = link.label ?? CopyJoin.copySlice(in: text, range: ranges[k], uncopied: excluded)
            var child = AccessibilityNode(id: link.id, role: link.role, label: label, help: link.help.map(runeHelpWords),
                                          frame: item.frame, isFocused: focused == k, isFocusable: focusable,
                                          url: link.id, isDisabled: item.isDisabled, actions: actions)
            child.runtimePath = prefix + String(k)
            child.webDocument = .init(inlineRange: start..<end)
            item.children.append(child)
        }
        return printable
    }

    /// Document anchors can be focused and activated before the browser scrolls their glyphs
    /// into the canvas. All other semantic actions use the shared native accessibility routing.
    func performLinkAction(_ path: String, action: AccessibilityAction, at now: Double) -> Bool? {
        guard runtime.nodeByPath[path] == nil, let marker = path.range(of: "#link-", options: .backwards),
              let k = Int(path[marker.upperBound...]), let index = runtime.nodeByPath[String(path[..<marker.lowerBound])] else { return nil }
        let model = runtime.flatNodes[index]
        let el = model.el
        guard runtime.hasActiveTextLinks(el), el.textLinks.indices.contains(k),
              runtime.a11yAllowed(index), !el.a11yDisabled else { return false }
        var ancestor: Int? = index
        while let i = ancestor {
            let n = runtime.flatNodes[i]
            if n.el.isA11yHidden || n.el.opacity <= 0.01 { return false }
            ancestor = n.parentIndex
        }
        let link = el.textLinks[k]
        guard let text = el.plainText ?? el.richSpans?.map(\.text).joined(),
              !CopyJoin.copySlice(in: text, range: link.byteRange, uncopied: el.uncopiedRanges).isEmpty else { return false }
        switch action {
        case .focus where el.focusable && runtime.canFocusIndex(index):
            runtime.setFocus(path: model.path, keyboard: true, at: now)
            runtime.focusedLinkIndex = k
            runtime.focusedKey = link.id
            runtime.dirtyCommit(at: now)
        case .press:
            guard let onLink = el.handlers.onLink else { return false }
            var tx = runtime.makeTx(at: now)
            onLink(&runtime.state, link.id, &tx)
            runtime.applyTx(tx, at: now)
            runtime.dirtyCommit(at: now, why: CommitWhy.input)
        default: return false
        }
        return true
    }

    private static func carriesAnchor(_ node: AccessibilityNode, htmlRole: String?) -> Bool {
        if node.url != nil { return true }
        if htmlRole == "article" || htmlRole == "alertdialog" { return true }
        switch node.role {
        case .main, .navigation, .banner, .contentInfo, .region, .complementary, .figure,
             .list, .listItem, .listbox, .dialog, .alertDialog, .table, .row, .cell, .gridCell, .columnHeader, .rowHeader, .heading:
            return true
        case .group: return node.label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        default: return false
        }
    }
}

/// Passive hover feedback leaves text selectable. Pointer handlers and controls need to
/// receive the press in the canvas. Explicitly selectable text overrides an enclosing control.
func webPageTextSelects<State>(_ el: El<State>) -> Bool {
    if el.isSecure || (el.runtimeExtras[El<State>.selectableExtraKey] as? Bool) == false ||
        (el.runtimeExtras["htmlUnselectable"] as? Bool) == true { return false }
    let h = el.handlers
    if h.onClick != nil || h.onClickPress != nil || h.onDoubleClick != nil || h.onSecondaryClick != nil ||
        h.onMiddlePress != nil || h.onPointerDown != nil || h.onPointerUp != nil || h.onPointerMove != nil ||
        h.onDrag != nil || h.onDragStart != nil || h.dragOut != nil || h.editLens != nil || el.isWindowDrag ||
        el.a11yHref != nil || h.onMagnify != nil || h.onRotate != nil || h.onSmartMagnify != nil { return false }
    if let role = el.runtimeExtras["htmlRole"] as? String,
       ["spinbutton", "scrollbar", "searchbox", "textbox", "slider", "checkbox", "switch", "radio", "tab",
        "combobox", "option", "menuitem", "menuitemcheckbox", "menuitemradio"].contains(role) { return false }
    switch el.role {
    case .button, .link, .tab, .checkbox, .switchControl, .radio, .combobox, .option, .menuItem, .menuItemCheckbox,
         .menuItemRadio, .slider, .textInput, .passwordInput, .multilineTextInput: return false
    default: return true
    }
}
