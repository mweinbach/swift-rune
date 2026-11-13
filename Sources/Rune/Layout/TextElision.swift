import Foundation

/// Where truncation cut a text: it draws `content[..<head]`, `"…"`, then `content[tail...]`
/// (`crates/rune/src/runtime/commit/text_layout.rs::Elision`).
public struct TextElision: Sendable, Equatable, Hashable {
    public static let ellipsis = "…"

    /// UTF-8 byte offset in original text where the cut begins.
    public var head: Int
    /// UTF-8 byte offset in original text where the kept suffix begins.
    public var tail: Int

    public init(head: Int, tail: Int) {
        self.head = max(0, head)
        self.tail = max(self.head, tail)
    }

    /// Drawn UTF-8 byte index immediately past the inserted `"…"`.
    public var afterEllipsis: Int { head + Self.ellipsis.utf8.count }

    /// Content byte offset corresponding to drawn byte `drawnIndex`.
    public func contentOffset(forDrawn drawnIndex: Int) -> Int {
        if drawnIndex <= head { return drawnIndex }
        if drawnIndex < afterEllipsis { return tail }
        return tail + (drawnIndex - afterEllipsis)
    }

    /// Drawn byte offset corresponding to content byte `contentIndex`.
    /// When `contentIndex` lies inside the cut, `end: true` lands past `"…"` so a
    /// selection reaching into the cut highlights the ellipsis.
    public func drawnOffset(forContent contentIndex: Int, end: Bool) -> Int {
        if contentIndex <= head { return contentIndex }
        if contentIndex < tail { return end ? afterEllipsis : head }
        return afterEllipsis + (contentIndex - tail)
    }

    /// Maps an original UTF-8 selection range onto drawn UTF-8 bytes.
    public func selectionRange(_ range: Range<Int>) -> Range<Int> {
        let a = drawnOffset(forContent: range.lowerBound, end: false)
        let b = drawnOffset(forContent: max(range.lowerBound, range.upperBound), end: true)
        return a..<max(a, b)
    }

    /// Maps a span's, highlight's, or link's UTF-8 byte range `[a..<b)` onto drawn bytes.
    /// Ranges wholly inside the cut map to empty. A link takes `"…"` only when visible on
    /// both sides; a span/highlight also takes `"…"` when touching the start of the cut.
    public func mark(_ a: Int, _ b: Int, isLink: Bool) -> Range<Int> {
        let h = head
        let t = tail
        let after = afterEllipsis
        if b <= h { return a..<b }
        if a >= t { return (after + a - t)..<(after + b - t) }
        let before = a < h
        let beyond = b > t
        let takesEllipsis = isLink ? (before && beyond) : (a <= h && (before || beyond))
        let start = before ? a : (takesEllipsis ? h : after)
        let end = beyond ? (after + b - t) : (takesEllipsis ? after : h)
        return start < end ? (start..<end) : (start..<start)
    }

    /// Drawn string length for a content string `contentBytes` bytes long.
    public func drawnLength(contentBytes: Int) -> Int {
        drawnOffset(forContent: contentBytes, end: true)
    }

    /// Returns the drawn UTF-8 string (`content[..<head] + "…" + content[tail...]`).
    public func drawnString(from content: String) -> String {
        let utf8 = content.utf8
        let len = utf8.count
        let h = min(head, len)
        let t = max(h, min(tail, len))
        let hIdx = utf8.index(utf8.startIndex, offsetBy: h)
        let tIdx = utf8.index(utf8.startIndex, offsetBy: t)
        return String(content[..<hIdx]) + Self.ellipsis + String(content[tIdx...])
    }

    /// Maps contiguous `TextSpan` segments onto `drawn` (keeping only visible spans, dropping empty ones).
    public func mapSpans(_ spans: [TextSpan], originalLength: Int, drawn: String) -> [TextSpan] {
        guard !spans.isEmpty else { return [] }
        let drawnLen = drawn.utf8.count
        var out: [TextSpan] = []
        out.reserveCapacity(spans.count)
        var cursor = 0
        for sp in spans {
            let len = sp.text.utf8.count
            let r = mark(cursor, min(originalLength, cursor + len), isLink: false)
            cursor += len
            guard !r.isEmpty else { continue }
            let lo = min(r.lowerBound, drawnLen)
            let hi = max(lo, min(r.upperBound, drawnLen))
            guard lo < hi else { continue }
            var copy = sp
            let sIdx = drawn.utf8.index(drawn.utf8.startIndex, offsetBy: lo)
            let eIdx = drawn.utf8.index(drawn.utf8.startIndex, offsetBy: hi)
            copy.text = String(drawn[sIdx..<eIdx])
            out.append(copy)
        }
        return out
    }

    /// Maps pill chips onto drawn UTF-8 byte coordinates, keeping only pills whose full label remains visible.
    public func mapPills(_ pills: [PillChip]) -> [PillChip] {
        guard !pills.isEmpty else { return [] }
        var out: [PillChip] = []
        out.reserveCapacity(pills.count)
        for p in pills {
            let r = mark(p.range.lowerBound, p.range.upperBound, isLink: true)
            guard !r.isEmpty else { continue }
            var copy = p
            copy.range = r
            out.append(copy)
        }
        return out
    }

    /// Maps `TextLink` byte ranges onto drawn bytes, dropping links wholly inside the cut.
    public func mapLinks(_ links: [TextLink], contentLength: Int) -> [(origIndex: Int, link: TextLink)] {
        guard !links.isEmpty else { return [] }
        var out: [(origIndex: Int, link: TextLink)] = []
        out.reserveCapacity(links.count)
        for (idx, link) in links.enumerated() {
            let a = max(0, min(link.byteRange.lowerBound, contentLength))
            let b = max(a, min(link.byteRange.upperBound, contentLength))
            guard a < b else { continue }
            let r = mark(a, b, isLink: true)
            guard !r.isEmpty else { continue }
            var copy = link
            copy.byteRange = r
            out.append((idx, copy))
        }
        return out
    }

    /// Maps `TextHighlight` byte ranges onto drawn bytes, dropping highlights wholly inside the cut.
    public func mapHighlights(_ highlights: [TextHighlight], contentLength: Int) -> [TextHighlight] {
        guard !highlights.isEmpty else { return [] }
        var out: [TextHighlight] = []
        out.reserveCapacity(highlights.count)
        for h in highlights {
            let a = max(0, min(h.byteRange.lowerBound, contentLength))
            let b = max(a, min(h.byteRange.upperBound, contentLength))
            guard a < b else { continue }
            let r = mark(a, b, isLink: false)
            guard !r.isEmpty else { continue }
            var copy = h
            copy.byteRange = r
            out.append(copy)
        }
        return out
    }

    /// Returns grapheme-cluster UTF-8 byte boundary offsets in `slice` relative to `baseOffset`
    /// (`[baseOffset, ..., baseOffset + slice.utf8.count]`).
    internal static func graphemeByteBounds<S: StringProtocol>(in slice: S, baseOffset: Int = 0) -> [Int] {
        var bounds: [Int] = []
        var pos = baseOffset
        bounds.reserveCapacity(slice.count + 1)
        bounds.append(pos)
        for ch in slice {
            pos += ch.utf8.count
            bounds.append(pos)
        }
        return bounds
    }

    internal static func isBlankSlice(in content: String, byteRange: Range<Int>) -> Bool {
        let utf8 = content.utf8
        let s = utf8.index(utf8.startIndex, offsetBy: byteRange.lowerBound)
        let e = utf8.index(utf8.startIndex, offsetBy: byteRange.upperBound)
        return content[s..<e].unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
