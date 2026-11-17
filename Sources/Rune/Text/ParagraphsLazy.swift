import Foundation
#if canImport(CoreText)
import CoreText
#endif

// A long paste's lines that wait to be shaped (`text/paragraphs/lazy.rs`): printable ASCII
// measured once per style, the records that wait at their exact heights, and the fill that
// shapes them a few a frame, taking a run apart where it shapes.

/// What shapes the paragraphs a long paste left waiting (`TextSystem.fillParagraphs`, `Lazy`).
/// A waiting paragraph is plain printable ASCII that fits on one line, so its height is the
/// style's one line exactly and nothing moves when its layout lands.
internal struct LazyFill {
    var content: [UInt8]
    var style: TextStyle
    var scale: Float
    /// Its layout's entry in the cache, which a fill replaces.
    var cacheKey: UInt64
    /// What keys a run's lines when a fill takes it apart (`keyParagraphs`).
    var styleKey: UInt64
    var forced: TextFlow?
    var startFlow: TextFlow
    var ascii: AsciiLine
}

/// One line of printable ASCII in a style: each character's advance and the line's height
/// (device px), read from one shaped line, and an empty layout to stand in for a paragraph not
/// shaped yet (`AsciiLine`).
internal final class AsciiLine: @unchecked Sendable {
    let advance: [Float]
    /// The widest character's advance: a line this many times its length that fits needs no sum.
    let widest: Float
    let height: Float
    let empty: TextLayoutBox

    init(advance: [Float], widest: Float, height: Float, empty: TextLayoutBox) {
        self.advance = advance
        self.widest = widest
        self.height = height
        self.empty = empty
    }

    /// `s[a..<b]`'s height and width when it's printable ASCII that fits on one line at
    /// `maxWidth`, with room to spare for what kerning and ligatures do to the sum. A line no
    /// wider than `floor` however wide its characters reports `floor`, summing none of them.
    /// With `printableKnown`, the bytes are known to be printable ASCII already (`one_line`).
    func oneLine(_ s: [UInt8], _ a: Int, _ b: Int, maxWidth: Float?, floor: Float, printableKnown: Bool) -> (Float, Float)? {
        let bound = Float(b - a) * widest
        if bound <= floor && (maxWidth.map { bound * 1.03 + 2.0 <= $0 } ?? true) && (printableKnown || asciiPrintable(s, a, b)) {
            return (height, floor)
        }
        var w: Float = 0
        var i = a
        while i < b {
            let c = s[i]
            if !(0x20..<0x7f).contains(c) { return nil }
            w += advance[Int(c - 0x20)]
            i += 1
        }
        return (maxWidth.map { w * 1.03 + 2.0 <= $0 } ?? true) ? (height, w) : nil
    }

    /// Whether `maxWidth` is a measure of the narrowest the text can be (Taffy's min-content
    /// size, under a line's height wide): no line it breaks there is shown (`narrow`).
    func narrow(_ maxWidth: Float?) -> Bool {
        maxWidth.map { $0 < height } ?? false
    }

    /// `s[a..<b]` broken at its narrowest, estimated: a line per space-separated word, as wide as
    /// the widest. Only a min-content measure asks, for the width. A word no wider than `floor`
    /// however wide its characters isn't summed, as `oneLine` doesn't (`narrowest`).
    func narrowest(_ s: [UInt8], _ a: Int, _ b: Int, floor: Float) -> (Float, Float)? {
        var lines = 0
        var widestW = floor
        var start = a
        func word(_ ws: Int, _ we: Int) {
            if we == ws { return }
            lines += 1
            if Float(we - ws) * widest > widestW {
                var sum: Float = 0
                for k in ws..<we { sum += advance[Int(s[k] - 0x20)] }
                widestW = max(widestW, sum)
            }
        }
        var at = a
        var bad = false
        // Eight bytes at a time: whether all are printable, and where the spaces are.
        s.withUnsafeBytes { raw in
            while at + 8 <= b {
                let w = raw.loadUnaligned(fromByteOffset: at, as: UInt64.self).littleEndian
                let low = (w &- 0x2020_2020_2020_2020) & ~w
                let high = (w &+ 0x0101_0101_0101_0101) | w
                if (low | high) & 0x8080_8080_8080_8080 != 0 { bad = true; return }
                // A space is a zero byte of `w ^ 0x20..`, flagged exactly (no borrow between bytes).
                let x = w ^ 0x2020_2020_2020_2020
                var spaces = ~(((x & 0x7f7f_7f7f_7f7f_7f7f) &+ 0x7f7f_7f7f_7f7f_7f7f) | x | 0x7f7f_7f7f_7f7f_7f7f)
                while spaces != 0 {
                    let j = at + spaces.trailingZeroBitCount / 8
                    word(start, j)
                    start = j + 1
                    spaces &= spaces &- 1
                }
                at += 8
            }
        }
        if bad { return nil }
        while at < b {
            let c = s[at]
            if !(0x20..<0x7f).contains(c) { return nil }
            if c == 0x20 {
                word(start, at)
                start = at + 1
            }
            at += 1
        }
        word(start, b)
        return (height * Float(max(lines, 1)), widestW)
    }
}

/// Whether every byte of `s[a..<b]` is printable ASCII (`0x20..<0x7f`), eight at a time (`printable`).
internal func asciiPrintable(_ s: [UInt8], _ a: Int, _ b: Int) -> Bool {
    var i = a
    var ok = true
    s.withUnsafeBytes { raw in
        while i + 8 <= b {
            let w = raw.loadUnaligned(fromByteOffset: i, as: UInt64.self).littleEndian
            // A byte under 0x20 borrows when 0x20 is taken from it; one at or over 0x7f has its top
            // bit set once 1 is added to it.
            let low = (w &- 0x2020_2020_2020_2020) & ~w
            let high = (w &+ 0x0101_0101_0101_0101) | w
            if (low | high) & 0x8080_8080_8080_8080 != 0 { ok = false; return }
            i += 8
        }
    }
    if !ok { return false }
    while i < b {
        if !(0x20..<0x7f).contains(s[i]) { return false }
        i += 1
    }
    return true
}

/// How many lines a fill takes out of a run at once, at least: those it shapes next and the rows
/// around them. The rest stay runs, so the frames after a long paste hold a few records, not one
/// per line (`SPLIT_LINES`).
internal let paragraphSplitLines = 64

extension TextSystem {
    /// Printable ASCII in `style` at `scale`, measured once in the active text backend.
    internal func asciiLine(style: TextStyle, scale: Float) -> AsciiLine? {
        let st = paragraphState
        // Reached directly too (not only through `layoutParagraphs`/`fillParagraphs`): it takes
        // the state's lock itself (recursive, so a caller holding it is fine).
        st.lock.lock()
        defer { st.lock.unlock() }
        let key = paragraphStyleKey(style, scale: scale)
        if let m = st.ascii[key] { return m }
        var sample = ""
        for b in UInt8(0x21)..<UInt8(0x7f) {
            sample.unicodeScalars.append(Unicode.Scalar(b))
            sample.append(" ")
        }
        var ltr = style
        ltr.direction = .ltr
        let l = layoutKeyed(text: sample, style: ltr, maxWidth: nil, pixelScale: scale, emitGlyphs: false, keep: .owned, countAsRebreak: false)
        let empty = layoutKeyed(text: "", style: ltr, maxWidth: nil, pixelScale: scale, emitGlyphs: false, keep: .owned, countAsRebreak: false)
        let measured: AsciiLine? = {
            let bytes = Array(sample.utf8)
            #if canImport(CoreText) && canImport(CoreGraphics)
            guard l.shaped.lineStrings.count == 1, let line = l.shaped.lineStrings[0].ctLine else { return nil }
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], runs.count == 1 else { return nil }
            func offsetPx(_ index: Int) -> Float { Float(CTLineGetOffsetForStringIndex(line, index, nil)) }
            #else
            guard l.shaped.portableLines.count == 1, let line = l.shaped.portableLines.first,
                  line.charOffsets.count == bytes.count + 1 else { return nil }
            // Native and bitmap lines store caret edges in points. Unstyled portable lines
            // keep the primary font's line box even when a glyph needs a fallback face.
            func offsetPx(_ index: Int) -> Float { line.charOffsets[index] * scale }
            #endif
            var advance = [Float](repeating: .nan, count: 95)
            for i in bytes.indices {
                advance[Int(bytes[i] - 0x20)] = offsetPx(i + 1) - offsetPx(i)
            }
            guard advance.allSatisfy({ $0.isFinite }) else { return nil }
            let height = (l.shaped.lineTopPt(0) + l.shaped.lineBoxHeightPt(0)) * scale
            return AsciiLine(advance: advance, widest: advance.max() ?? 0, height: height, empty: empty)
        }()
        st.ascii[key] = measured
        return measured
    }

    /// Resolve a find result before layout reads or paint ask for its boxes. A waiting
    /// record can cover hundreds of lines, so fill the intersecting rows within each run.
    internal func prepareHighlights(_ marks: [TextHighlight], in initial: ParagraphLayout, field: UInt64) -> ParagraphLayout {
        var laid = initial
        for mark in marks {
            guard let lazy = laid.lazy else { break }
            let start = max(0, mark.byteRange.lowerBound)
            let end = min(lazy.content.count, mark.byteRange.upperBound)
            guard start < end else { continue }
            let from = partitionPoint(laid.paragraphs) { $0.end < start }
            let intersecting = laid.paragraphs[from...].prefix { $0.start < end }
            guard let first = intersecting.first(where: { !$0.shaped }),
                  let last = intersecting.last(where: { !$0.shaped }) else { continue }
            func row(in paragraph: Paragraph, at byte: Int) -> Float {
                let offset = min(max(byte, paragraph.start), paragraph.end)
                let lines = countNewlines(lazy.content, paragraph.start, offset)
                return paragraph.y + (Float(lines) + 0.5) * lazy.ascii.height
            }
            let rows = (row(in: first, at: start), row(in: last, at: end - 1))
            if let (filled, moved) = fillParagraphs(laid, budget: .infinity, rows: rows, reach: 0, field: field) {
                laid = filled
                if moved, let (exact, _) = fillParagraphs(laid, budget: .infinity, rows: rows, reach: .infinity, field: field) {
                    laid = exact
                }
            }
        }
        return laid
    }

    /// Shapes waiting paragraphs of `laid` for up to `budget` seconds, those meeting device rows
    /// `rows` first, then the nearest, none further than `reach` from them: the layout with them
    /// shaped (cached in its place), and whether a height moved (it shouldn't: a waiting height
    /// is exact). A run is taken apart into its lines, each keyed as keying would, before its
    /// first line is shaped. Nil when none were waiting (`fill_paragraphs`).
    internal func fillParagraphs(_ laid: ParagraphLayout, budget: Double, rows: (Float, Float), reach: Float, field: UInt64? = nil) -> (ParagraphLayout, Bool)? {
        guard let lazy = laid.lazy else { return nil }
        let st = paragraphState
        st.lock.lock()
        defer { st.lock.unlock() }
        let clock = ContinuousClock()
        let start = clock.now
        let limit = budget.isFinite ? Duration.seconds(max(0, budget)) : nil
        func distance(_ p: Paragraph) -> Float {
            (p.y + p.height >= rows.0 && p.y <= rows.1) ? 0 : max(rows.0 - p.y - p.height, p.y - rows.1)
        }
        var paragraphs = laid.paragraphs
        var moved = false
        var shapedAny = false
        while true {
            if shapedAny, let limit, start.duration(to: clock.now) >= limit { break }
            // The nearest waiting record: out from where the rows start, both ways.
            let mid = partitionPoint(paragraphs) { $0.y + $0.height < rows.0 }
            let up = paragraphs[mid...].firstIndex { !$0.shaped }
            let down = paragraphs[..<mid].lastIndex { !$0.shaped }
            let k: Int
            switch (up, down) {
            case let (u?, d?): k = distance(paragraphs[u]) <= distance(paragraphs[d]) ? u : d
            case let (u?, nil): k = u
            case let (nil, d?): k = d
            case (nil, nil): k = -1
            }
            if k < 0 { break }
            if distance(paragraphs[k]) > reach { break }
            if paragraphs[k].run {
                let lines = splitRun(lazy, maxWidth: laid.maxWidth.map { $0 * laid.scale }, paragraphs: paragraphs, k: k, rows: rows)
                paragraphs.replaceSubrange(k...k, with: lines)
                continue
            }
            let p = paragraphs[k]
            var pstyle = lazy.style
            pstyle.direction = p.flow
            st.shapedParagraphs += 1
            let textEnd = paragraphTextEnd(lazy.content, p.start, p.end)
            let l = layoutKeyed(text: String(decoding: lazy.content[p.start..<textEnd], as: UTF8.self), style: pstyle, maxWidth: laid.maxWidth, pixelScale: lazy.scale, emitGlyphs: false, keep: .owned, countAsRebreak: false)
            let (h, widths) = Self.measures(l, blank: p.start == textEnd, scale: lazy.scale, linePx: l.shaped.lineHeight * lazy.scale)
            moved = moved || h != p.height
            paragraphs[k].height = h
            paragraphs[k].widths = widths
            paragraphs[k].layout = l
            paragraphs[k].shaped = true
            shapedAny = true
        }
        var y: Double = 0
        var width: Float = 0
        var fullWidth: Float = 0
        for i in paragraphs.indices {
            paragraphs[i].y = Float(y.rounded())
            y += Double(paragraphs[i].height)
            width = max(width, paragraphs[i].widths.x)
            fullWidth = max(fullWidth, paragraphs[i].widths.y)
        }
        let left = paragraphs.contains { !$0.shaped }
        let built = ParagraphLayout(paragraphs: paragraphs, width: width, fullWidth: fullWidth, height: Float(y), maxWidth: laid.maxWidth, align: laid.align, whole: laid.whole, keyed: laid.keyed, lazy: left ? lazy : nil, content: laid.content, style: laid.style, scale: laid.scale, forced: laid.forced, baseFont: laid.baseFont)
        let g = st.generation
        st.cache[lazy.cacheKey] = ParagraphCacheEntry(built, used: g, textLen: built.paragraphs.count * ParagraphState.paragraphRecordBytes / 64)
        if let l = st.lastParagraphs, l === laid { st.lastParagraphs = built }
        if let field, let f = st.fields[field], f.layout === laid { st.fields[field] = (built, g) }
        return (built, moved)
    }

}

/// Run `k` taken apart where `rows` meet it, or at its end nearest them: its lines there as
/// waiting paragraphs of their own, keyed as `keyParagraphs` keys a line, between the runs its
/// lines before and after them stay, each as wide as its widest line (`split_run`).
internal func splitRun(_ lazy: LazyFill, maxWidth: Float?, paragraphs: [Paragraph], k: Int, rows: (Float, Float)) -> [Paragraph] {
    let r = paragraphs[k]
    let n = Int(r.lines)
    let h = lazy.ascii.height
    func pick(_ y: Float) -> Int {
        Int(((Double(y) - Double(r.y)) / Double(h)).rounded(.down).clamped(to: 0...Double(n)))
    }
    let top = pick(rows.0)
    let bottom = min(pick(rows.1) + 1, n)
    let room = (max(0, paragraphSplitLines - max(0, bottom - top)) + 1) / 2
    let a = min(max(0, top - room), max(0, n - paragraphSplitLines))
    let b = min(max(bottom + room, a + paragraphSplitLines), n)
    var out: [Paragraph] = []
    out.reserveCapacity(b - a + 2)
    var flow = k > 0 ? paragraphs[k - 1].flow : lazy.startFlow
    var y = Double(r.y)
    // The run gathered before `a` or after `b`: its first byte, its lines and its widest line's width.
    var run: (start: Int, lines: UInt32, widest: Float)? = nil
    var at = r.start
    var j = 0
    let content = lazy.content
    while at <= r.end {
        var e = at
        while e < r.end && content[e] != 0x0a { e += 1 }
        let s = at
        let textEnd = paragraphTextEnd(content, s, e)
        at = e + 1
        // Printable ASCII, as every line of a run is: its letters are its strong characters.
        var hasLetter = false
        for i in s..<e { let c = content[i] | 0x20; if c >= 0x61 && c <= 0x7a { hasLetter = true; break } }
        flow = lazy.forced ?? (hasLetter ? .ltr : flow)
        if j < a || j >= b {
            let floor = run?.widest ?? 0
            let w = lazy.ascii.oneLine(content, s, textEnd, maxWidth: maxWidth, floor: floor, printableKnown: true).map { $0.1 } ?? floor
            let (start, lines, widest) = run.map { ($0.start, $0.lines + 1, max($0.widest, w)) } ?? (s, 1, w)
            run = (start, lines, widest)
            if j + 1 == a || j + 1 == n {
                run = nil
                var hs = Hasher()
                content.withUnsafeBytes { hs.combine(bytes: UnsafeRawBufferPointer(rebasing: $0[start..<e])) }
                hs.combine(lazy.styleKey)
                hs.combine(flow == .rtl)
                hs.combine(lines)
                hs.combine("run")
                let height = Float(Double(lines) * Double(h))
                out.append(Paragraph(start: start, end: e, y: Float(y.rounded()), height: height, widths: SIMD2(widest, widest), flow: flow, key: UInt64(bitPattern: Int64(hs.finalize())), layout: r.layout, shaped: false, lines: lines, run: true))
                y += Double(height)
            }
            j += 1
            continue
        }
        var hs = Hasher()
        // Keyed as `keyParagraphs` keys a line: by its bytes.
        content.withUnsafeBytes { hs.combine(bytes: UnsafeRawBufferPointer(rebasing: $0[s..<e])) }
        hs.combine(lazy.styleKey)
        hs.combine(flow == .rtl)
        hs.combine("p")
        let (height, w) = lazy.ascii.oneLine(content, s, textEnd, maxWidth: maxWidth, floor: 0, printableKnown: true) ?? (h, 0)
        out.append(Paragraph(start: s, end: e, y: Float(y.rounded()), height: height, widths: SIMD2(w, w), flow: flow, key: UInt64(bitPattern: Int64(hs.finalize())), layout: r.layout, shaped: false, lines: 1, run: false))
        y += Double(height)
        j += 1
    }
    return out
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
