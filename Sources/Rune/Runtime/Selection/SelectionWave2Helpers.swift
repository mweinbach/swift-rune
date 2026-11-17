import Foundation
import RuneMotion
import RuneRef

// MARK: - Selection Highlight Run Joining (`selectable.rs:151-183`)

internal protocol SelectionPaintRect {
    var rect: SIMD4<Float> { get set }
    var radii: SIMD4<Float> { get }
    var fill: SIMD4<Float> { get }
    var clip: SIMD4<Float> { get }
    var params: SIMD4<Float> { get }
    var selectionIsRect: Bool { get }
    var selectionTurn: Float { get }
}

extension Primitive: SelectionPaintRect {
    var selectionIsRect: Bool { kind == .roundedRect }
    var selectionTurn: Float { turn }
}

extension RenderInstance: SelectionPaintRect {
    var selectionIsRect: Bool { params.y == KIND_RECT }
    var selectionTurn: Float { 0 } // The native renderer rotates an enclosing layer.
}

/// Joins selection highlight rects drawn by adjacent selectable words/chips on the same visual line
/// into seamless horizontal runs (`crates/rune/src/runtime/selection/selectable.rs:151-183`).
public enum SelectionRunExtender {
    /// Appends a selection highlight rect (device pixels) into `primitives`, extending a matching
    /// prior selection rect on the same line within `reach` device pixels if uncovered, or starting at
    /// an enclosing chip background rect.
    public static func appendHighlight(
        into primitives: inout [Primitive],
        rect inputRect: SIMD4<Float>,
        fill: SIMD4<Float>,
        radius: Float,
        clip: SIMD4<Float>,
        fade: SIMD4<Float>,
        fadeOrigin: SIMD2<Float> = .zero,
        turn: Float = 0,
        reach: Float
    ) {
        let radii = SIMD4<Float>(repeating: radius)

        func makePrimitive(_ r: SIMD4<Float>) -> Primitive {
            var prim = Primitive.roundedRect(
                rect: r,
                radii: radii,
                fill: fill,
                clip: clip,
                turn: turn
            )
            prim.fade = fade
            prim.fadeOrigin = fadeOrigin
            return prim
        }

        join(into: &primitives, rect: inputRect, fill: fill, radii: radii, clip: clip, turn: turn, reach: reach,
             makePrimitive: makePrimitive)
    }

    internal static func join<P: SelectionPaintRect>(
        into primitives: inout [P], rect input: SIMD4<Float>, fill: SIMD4<Float>, radii: SIMD4<Float>,
        clip: SIMD4<Float>, turn: Float, reach: Float, makePrimitive: (SIMD4<Float>) -> P
    ) {
        var rect = input
        let from = max(0, primitives.count - 256)
        if turn == 0 {
            var foundIdx: Int? = nil
            for idx in stride(from: primitives.count - 1, through: from, by: -1) {
                let p = primitives[idx]
                guard p.selectionIsRect,
                      p.params.x == 0,
                      p.selectionTurn == 0,
                      p.fill == fill,
                      p.clip == clip,
                      p.radii == radii else { continue }
                let gap = rect.x - (p.rect.x + p.rect.z)
                let overlap = min(p.rect.y + p.rect.w, rect.y + rect.w) - max(p.rect.y, rect.y)
                if gap >= -1.0, gap <= reach, overlap > 0.6 * min(p.rect.w, rect.w) {
                    foundIdx = idx
                    break
                }
            }

            if let at = foundIdx {
                let covered = primitives[(at + 1)...].contains {
                    $0.selectionIsRect && $0.fill != fill && $0.fill.w > 0
                }
                let prevRect = primitives[at].rect
                let top = min(prevRect.y, rect.y)
                let bottom = max(prevRect.y + prevRect.w, rect.y + rect.w)
                if covered {
                    let left = min(prevRect.x + prevRect.z, rect.x)
                    rect = SIMD4<Float>(left, top, max(0, rect.x + rect.z - left), bottom - top)
                    primitives.append(makePrimitive(rect))
                } else {
                    let right = max(prevRect.x, rect.x + rect.z)
                    primitives[at].rect.z = right - prevRect.x
                    primitives[at].rect.y = top
                    primitives[at].rect.w = bottom - top
                }
                return
            }

            // First highlight on its line inside a chip's background: extend left to the chip's edge.
            for idx in stride(from: primitives.count - 1, through: from, by: -1) {
                let p = primitives[idx]
                guard p.selectionIsRect,
                      p.fill != fill,
                      p.fill.w > 0,
                      p.rect.x >= rect.x - reach,
                      p.rect.x < rect.x,
                      p.rect.x + p.rect.z > rect.x,
                      p.rect.w <= 1.8 * rect.w else { continue }
                let overlap = min(p.rect.y + p.rect.w, rect.y + rect.w) - max(p.rect.y, rect.y)
                if overlap > 0.6 * rect.w {
                    let top = min(p.rect.y, rect.y)
                    let bottom = max(p.rect.y + p.rect.w, rect.y + rect.w)
                    rect = SIMD4<Float>(p.rect.x, top, max(0, rect.x + rect.z - p.rect.x), bottom - top)
                    break
                }
            }
        }

        primitives.append(makePrimitive(rect))
    }
}

// MARK: - Semantic Selection HTML Builder (`copy_html.rs`)

/// Builds semantic `text/html` clipboard markup alongside plain text when copying `El.selectable`
/// ranges (`crates/rune/src/runtime/selection/copy_html.rs`).
public enum CopyHTMLBuilder {
    public struct SpanRun: Sendable, Equatable {
        public var byteRange: Range<Int>
        public var weight: Float?
        public var italic: Bool
        public var monospace: Bool
        public var strikethrough: Bool

        public init(
            byteRange: Range<Int>,
            weight: Float? = nil,
            italic: Bool = false,
            monospace: Bool = false,
            strikethrough: Bool = false
        ) {
            self.byteRange = byteRange
            self.weight = weight
            self.italic = italic
            self.monospace = monospace
            self.strikethrough = strikethrough
        }
    }

    public struct LinkRun: Sendable, Equatable {
        public var byteRange: Range<Int>
        public var id: String

        public init(byteRange: Range<Int>, id: String) {
            self.byteRange = byteRange
            self.id = id
        }
    }

    public struct NodeSnapshot: Sendable {
        public var parentIndex: Int?
        public var roleRaw: String
        public var a11yLevel: Int?
        public var a11yHidden: Bool
        public var rect: MotionRect
        public var text: String?
        internal var source: TextCaseMapping?
        public var baseWeight: Float
        public var baseItalic: Bool
        public var baseMonospace: Bool
        public var spans: [SpanRun]
        public var links: [LinkRun]
        public var strikes: [Range<Int>]
        public var uncopied: [Range<Int>]

        public init(
            parentIndex: Int?,
            roleRaw: String,
            a11yLevel: Int? = nil,
            a11yHidden: Bool = false,
            rect: MotionRect = .zero,
            text: String? = nil,
            source: TextCaseMapping? = nil,
            baseWeight: Float = 400,
            baseItalic: Bool = false,
            baseMonospace: Bool = false,
            spans: [SpanRun] = [],
            links: [LinkRun] = [],
            strikes: [Range<Int>] = [],
            uncopied: [Range<Int>] = []
        ) {
            self.parentIndex = parentIndex
            self.roleRaw = roleRaw
            self.a11yLevel = a11yLevel
            self.a11yHidden = a11yHidden
            self.rect = rect
            self.text = text
            self.source = source
            self.baseWeight = baseWeight
            self.baseItalic = baseItalic
            self.baseMonospace = baseMonospace
            self.spans = spans
            self.links = links
            self.strikes = strikes
            self.uncopied = uncopied
        }
    }

    public struct SelectedRange: Sendable {
        public var nodeIndex: Int
        public var range: Range<Int>

        public init(nodeIndex: Int, range: Range<Int>) {
            self.nodeIndex = nodeIndex
            self.range = range
        }
    }

    private enum Block: Equatable {
        case heading(node: Int, level: Int)
        case item(list: Int, item: Int, ordered: Bool)
        case cell(table: Int, row: Int, cell: Int, head: Bool)
        case code(node: Int)
        case paragraph(node: Int)
    }

    public static func build(nodes: [NodeSnapshot], ranges: [SelectedRange]) -> String? {
        guard !ranges.isEmpty else { return nil }
        var out = ""
        var prev: (block: Block, lastNode: Int)? = nil
        var lists: [(list: Int, item: Int, ordered: Bool)] = []

        func isDescendant(_ j: Int, of a: Int) -> Bool {
            var cur = nodes[j].parentIndex
            while let p = cur {
                if p == a { return true }
                cur = nodes[p].parentIndex
            }
            return false
        }

        func blockOf(_ i: Int) -> Block {
            let mono = nodes[i].baseMonospace
            var cur: Int? = i
            while let j = cur {
                let roleLower = nodes[j].roleRaw.lowercased()
                switch roleLower {
                case "heading":
                    let lvl = min(6, max(1, nodes[j].a11yLevel ?? 2))
                    return .heading(node: j, level: lvl)
                case "listitem":
                    var list = j
                    var walk = nodes[j].parentIndex
                    while let p = walk {
                        if nodes[p].roleRaw.lowercased() == "list" {
                            list = p
                            break
                        }
                        walk = nodes[p].parentIndex
                    }
                    let markerText = (j + 1 < nodes.count) ? nodes[j + 1].text : nil
                    let ordered = markerText.map { marker in
                        !marker.isEmpty && marker.utf8.reversed().drop(while: { $0 == 46 }).allSatisfy { (48...57).contains($0) }
                    } ?? false
                    return .item(list: list, item: j, ordered: ordered)
                case "cell", "columnheader", "rowheader":
                    var row = j
                    var table: Int? = nil
                    var walk = nodes[j].parentIndex
                    while let p = walk {
                        let pRoleLower = nodes[p].roleRaw.lowercased()
                        if row == j && pRoleLower == "row" {
                            row = p
                        }
                        if pRoleLower == "table" {
                            table = p
                            break
                        }
                        walk = nodes[p].parentIndex
                    }
                    return .cell(table: table ?? row, row: row, cell: j, head: roleLower != "cell")
                default:
                    cur = nodes[j].parentIndex
                }
            }
            if mono {
                return .code(node: nodes[i].parentIndex ?? i)
            }
            return .paragraph(node: i)
        }

        func closeLists(keep: Int) {
            while lists.count > keep {
                let (_, _, ordered) = lists.removeLast()
                out.append(ordered ? "</li></ol>" : "</li></ul>")
            }
        }

        func openBlock(_ prevBlock: Block?, _ block: Block) {
            switch block {
            case .heading(_, let level):
                out.append("<h\(level)>")
            case .item:
                break
            case .cell(let table, let row, _, let head):
                let sameTable: Bool
                let sameRow: Bool
                if case .cell(let t, let r, _, _)? = prevBlock {
                    sameTable = (t == table)
                    sameRow = (t == table && r == row)
                } else {
                    sameTable = false
                    sameRow = false
                }
                if !sameTable { out.append("<table>") }
                if !sameRow { out.append("<tr>") }
                out.append(head ? "<th>" : "<td>")
            case .code:
                out.append("<pre><code>")
            case .paragraph:
                out.append("<p>")
            }
        }

        func closeBlock(_ block: Block, next nextBlock: Block?) {
            switch block {
            case .heading(_, let level):
                out.append("</h\(level)>")
            case .item:
                break
            case .cell(let table, let row, _, let head):
                out.append(head ? "</th>" : "</td>")
                let sameTable: Bool
                let sameRow: Bool
                if case .cell(let t, let r, _, _)? = nextBlock {
                    sameTable = (t == table)
                    sameRow = (t == table && r == row)
                } else {
                    sameTable = false
                    sameRow = false
                }
                if !sameRow { out.append("</tr>") }
                if !sameTable { out.append("</table>") }
            case .code:
                out.append("</code></pre>")
            case .paragraph:
                out.append("</p>")
            }
        }

        for entry in ranges {
            let i = entry.nodeIndex
            guard i >= 0 && i < nodes.count, let fullText = nodes[i].text else { continue }
            let block = blockOf(i)
            if nodes[i].a11yHidden, case .item = block { continue }
            let inline = inlineHTML(node: nodes[i], text: fullText, range: entry.range)
            if inline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

            if let (p, last) = prev, p == block {
                if CopyJoin.beside(nodes[last].rect, nodes[i].rect) {
                    if !out.hasSuffix(" ") && !inline.hasPrefix(" ") {
                        out.append(" ")
                    }
                } else {
                    out.append("<br>")
                }
            } else {
                if let (p, _) = prev {
                    if case .item = p {} else {
                        closeBlock(p, next: block)
                    }
                }
                switch block {
                case .item(let list, let item, let ordered):
                    var keep = 0
                    for idx in stride(from: lists.count - 1, through: 0, by: -1) {
                        let l = lists[idx]
                        if l.list == list || isDescendant(list, of: l.item) {
                            keep = idx + 1
                            break
                        }
                    }
                    closeLists(keep: keep)
                    if let top = lists.last, top.list == list {
                        out.append("</li><li>")
                        lists[lists.count - 1].item = item
                    } else {
                        out.append(ordered ? "<ol><li>" : "<ul><li>")
                        lists.append((list, item, ordered))
                    }
                default:
                    closeLists(keep: 0)
                    openBlock(prev?.block, block)
                }
            }
            out.append(inline)
            prev = (block, i)
        }

        guard let (p, _) = prev else { return "" }
        if case .item = p {} else {
            closeBlock(p, next: nil)
        }
        closeLists(keep: 0)
        return out
    }

    private static func inlineHTML(node: NodeSnapshot, text: String, range: Range<Int>) -> String {
        let len = text.utf8.count
        let a = max(0, min(len, range.lowerBound))
        let b = max(a, min(len, range.upperBound))
        guard a < b else { return "" }

        var cutSet: Set<Int> = [a, b]
        for s in node.spans {
            cutSet.insert(s.byteRange.lowerBound)
            cutSet.insert(s.byteRange.upperBound)
        }
        for strike in node.strikes {
            cutSet.insert(strike.lowerBound)
            cutSet.insert(strike.upperBound)
        }
        for l in node.links {
            cutSet.insert(l.byteRange.lowerBound)
            cutSet.insert(l.byteRange.upperBound)
        }
        let cuts = cutSet
            .filter { $0 >= a && $0 <= b && SelectionMath.floorCharBoundary(in: text, offset: $0) == $0 }
            .sorted()

        var out = ""
        var activeHref: String? = nil

        for idx in 0..<max(0, cuts.count - 1) {
            let s = cuts[idx]
            let e = cuts[idx + 1]
            guard s < e else { continue }
            let slice = CopyJoin.copySlice(in: text, range: s..<e, uncopied: node.uncopied, source: node.source)
            guard !slice.isEmpty else { continue }

            let inside: (Range<Int>) -> Bool = { $0.lowerBound <= s && e <= $0.upperBound }
            let bold = node.baseWeight >= 600.0
                || node.spans.contains { inside($0.byteRange) && ($0.weight ?? 0) >= 600.0 }
            let italic = !node.baseItalic
                && node.spans.contains { inside($0.byteRange) && $0.italic }
            let code = node.spans.contains { inside($0.byteRange) && $0.monospace }
            let struck = node.strikes.contains(where: inside) || node.spans.contains { inside($0.byteRange) && $0.strikethrough }
            let link = node.links.first { inside($0.byteRange) }.flatMap {
                $0.id.contains("://") || $0.id.hasPrefix("mailto:") ? $0.id : nil
            }

            if activeHref != link {
                if activeHref != nil { out.append("</a>") }
                if let h = link {
                    out.append("<a href=\"")
                    out.append(escapeHTML(h))
                    out.append("\">")
                }
                activeHref = link
            }

            var piece = escapeHTML(slice).replacingOccurrences(of: "\n", with: "<br>")
            if code { piece = "<code>\(piece)</code>" }
            if struck { piece = "<s>\(piece)</s>" }
            if italic { piece = "<em>\(piece)</em>" }
            if bold && node.baseWeight < 600.0 {
                piece = "<strong>\(piece)</strong>"
            }
            out.append(piece)
        }
        if activeHref != nil {
            out.append("</a>")
        }
        return out
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Edge Scroll Attempt Guard (`edge_scroll.rs`)

public struct EdgeScrollAttempt: Sendable, Equatable, Hashable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public struct EdgeScrollSeq: Sendable, Equatable {
    private var nextValue: UInt64 = 0
    public init() {}

    public mutating func next() -> EdgeScrollAttempt {
        nextValue &+= 1
        return EdgeScrollAttempt(rawValue: nextValue)
    }
}

// MARK: - Text Shape Key (`text_keys.rs`)

/// Deterministic content+style+scale shape key (`crates/rune/src/text/mod.rs` / `text_keys.rs`).
extension TextShapeKey {
    private static let fnvOffset: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    @inline(__always)
    private static func mix(_ h: inout UInt64, _ byte: UInt8) {
        h ^= UInt64(byte)
        h &*= fnvPrime
    }

    @inline(__always)
    private static func mixUInt64(_ h: inout UInt64, _ value: UInt64) {
        var v = value
        for _ in 0..<8 {
            mix(&h, UInt8(truncatingIfNeeded: v))
            v >>= 8
        }
    }

    @inline(__always)
    private static func mixString(_ h: inout UInt64, _ s: String) {
        mixUInt64(&h, UInt64(s.utf8.count))
        for b in s.utf8 { mix(&h, b) }
    }

    public static func compute(
        text: String,
        spans: [TextSpan]?,
        pills: [PillChip],
        style: TextStyle,
        pixelScale: Float,
        wrapAnywhere: Bool
    ) -> UInt64 {
        var h = fnvOffset
        mixString(&h, text)
        mixUInt64(&h, UInt64(pixelScale.bitPattern))
        mix(&h, wrapAnywhere ? 1 : 0)
        mixUInt64(&h, UInt64(style.size.bitPattern))
        mixUInt64(&h, UInt64(style.weight.bitPattern))
        mixUInt64(&h, UInt64((style.lineHeight ?? -1).bitPattern))
        mixUInt64(&h, UInt64(style.letterSpacing.bitPattern))
        mix(&h, style.italic ? 1 : 0)
        switch style.family {
        case .systemUI: mix(&h, 0)
        case .monospace: mix(&h, 1)
        case .custom(let n): mix(&h, 2); mixString(&h, n)
        case .systemMono: mix(&h, 3)
        }
        switch style.wrap {
        case .wrap: mix(&h, 0)
        case .noWrap: mix(&h, 1)
        case .ellipsis: mix(&h, 2)
        }
        switch style.align {
        case .leading: mix(&h, 0)
        case .center: mix(&h, 1)
        case .trailing: mix(&h, 2)
        case .justified: mix(&h, 3)
        }
        if let spans {
            mixUInt64(&h, UInt64(spans.count))
            for s in spans {
                mixString(&h, s.text)
                mixUInt64(&h, UInt64((s.weight ?? -1).bitPattern))
                mixUInt64(&h, UInt64((s.size ?? -1).bitPattern))
                mix(&h, (s.italic ? 1 : 0) | (s.monospace ? 2 : 0) | (s.underline ? 4 : 0) | (s.strikethrough ? 8 : 0))
            }
        } else {
            mixUInt64(&h, 0)
        }
        mixUInt64(&h, UInt64(pills.count))
        for p in pills {
            mixUInt64(&h, UInt64(p.range.lowerBound))
            mixUInt64(&h, UInt64(p.range.upperBound))
            mix(&h, p.isBare ? 1 : 0)
        }
        return h
    }
}

// MARK: - Selection Boxes Movement (`rects.rs`)

public enum SelectionRectsMath {
    /// Returns true if the selection line-box list count changed or any box moved by > 0.5 pt (`rects.rs:38`).
    public static func boxesMoved(_ a: [[Float]], _ b: [[Float]]) -> Bool {
        guard a.count == b.count else { return true }
        for (x, y) in zip(a, b) {
            guard x.count >= 4, y.count >= 4 else {
                if x != y { return true }
                continue
            }
            for k in 0..<4 where abs(x[k] - y[k]) > 0.5 {
                return true
            }
        }
        return false
    }
}
