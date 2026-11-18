import Foundation
#if canImport(CoreText)
import CoreText
#endif

// A text field laid out one paragraph at a time (`text/paragraphs.rs`, upstream 615f06a4): each
// line a newline ends gets its own layout, in the direction of its own first strong character
// (`El.dirByParagraph`, CSS `unicode-bidi: plaintext`) or the field's. The paragraphs stack in
// one field: one editor, one caret, one selection. An edit shapes only the paragraphs it
// changed (`reuseKeys`, `keyParagraphs`); the others keep their layouts from the field's last
// one. A long paste's plain ASCII lines away from its ends wait in runs at their exact heights
// and are shaped a few a frame (`ParagraphsLazy.swift`, `Runtime/TextFill.swift`).
//
// Plain fields reuse individual layouts and can defer offscreen ASCII lines. Fields with spans,
// pills or non-paragraph blocks use one layout; CoreText supplies each paragraph's direction
// and isolates pills while preserving authored byte indices. Selection includes a newline's
// width, and find marks on packed lines prepare the intersecting paragraphs before layout reads
// or paint. Positions here are content UTF-8 bytes and device pixels.

/// What a by-paragraph field asks of `TextSystem.layoutInput`: the field it is (whose last
/// layout an edit starts from, upstream's node slot), the direction every paragraph takes
/// (`TextSpec::paragraphs_flow`, nil when each takes its own) and the flow lines with no strong
/// character start from (`plaintext_flow`).
internal struct ParagraphRequest: Sendable, Hashable {
    var field: UInt64
    var forced: TextFlow?
    var startFlow: TextFlow
    var highlights: [TextHighlight] = []

    static func supports(_ spans: [TextSpan]?) -> Bool {
        spans?.contains(where: \.affectsLayout) != true
    }
}

internal enum ParagraphConstants {
    /// Keeps a by-paragraph layout's cache key apart from a one-layout one of the same text.
    static let paragraphs: UInt64 = 0x3c6e_f372_fe94_f82b
    /// More new paragraphs than this in one layout (a long paste) shape only those near the edit;
    /// the others wait (`LazyFill`).
    static let lazyMin = 64
    /// How many paragraphs before an edit's end a long paste shapes at once (a field's lines above
    /// its caret, which follows the paste's end), and after its start.
    static let eagerEnd = 24
    static let eagerStart = 4
    /// The most lines one run holds: a keystroke inside a long paste keys its run's lines again,
    /// and the other runs keep theirs.
    static let runLines = 512
    /// A line of a `LineScan` is printable ASCII (not empty), and holds a letter.
    static let printable: UInt8 = 1
    static let letter: UInt8 = 2
}

/// One paragraph: content bytes `start..<end` (its newline left out), laid out at `y` (device px).
internal struct Paragraph {
    var start: Int
    var end: Int
    var y: Float
    var height: Float
    /// Its layout's width and full width (device px), so a later edit that keeps it reads
    /// neither from it.
    var widths: SIMD2<Float>
    var flow: TextFlow
    /// What its layout depends on but the width: its words and direction, in the field's style.
    var key: UInt64
    var layout: TextLayoutBox
    /// The text system's raster revision when this paragraph acquired its placed glyphs.
    var glyphRevision: UInt64 = 0
    /// False while it waits for a fill: `layout` is an empty stand-in, its height exact.
    var shaped: Bool
    /// How many lines of the text it holds: more than one for a run of waiting lines.
    var lines: UInt32
    /// A run as keying found it, keyed by its bytes: a fill takes it apart into its lines first.
    var run: Bool
}

/// One paragraph of a by-paragraph field over its stacked lines (`ShapedText.paragraphSpans`):
/// its content bytes, which of the stacked lines are its, and how its line break highlights.
internal struct ParagraphLineSpan: Sendable, Hashable {
    var start: Int
    var end: Int
    var firstLine: Int
    var lineCount: Int
    var rtl: Bool
    /// Its layout holds its lines (not blank, not waiting for a fill).
    var shaped: Bool

    var isBlank: Bool { start == end }
}

/// A plain text's content and the key inputs that aren't per paragraph, so an edit keys only the
/// paragraphs it touched and takes the others' keys as they were.
internal struct ParagraphKeyed {
    var content: [UInt8]
    var styleKey: UInt64
    var startFlow: TextFlow
}

/// One layout of a text and where it sits: one paragraph of a field's (`paragraphs.rs` `Piece`).
internal struct ParagraphPiece {
    var layout: TextLayoutBox
    var start: Int
    var end: Int
    var y: Float
    var height: Float
    var flow: TextFlow
    var index: Int

    var isBlank: Bool { start == end }
}

/// A by-paragraph field's paragraphs, top to bottom, in device px (`ParagraphLayout`).
internal final class ParagraphLayout: @unchecked Sendable {
    private var records: [Paragraph]
    /// Painting replaces a record's measured layout with its glyph-bearing layout.
    /// Give readers a consistent snapshot while paint or the next layout pass is running.
    var paragraphs: [Paragraph] { lock.withLock { records } }
    let width: Float
    let fullWidth: Float
    let height: Float
    /// What its lines were broken at (points, as `layoutKeyed` takes it).
    let maxWidth: Float?
    let align: TextAlign
    /// Its text's shape key, which its layouts at other widths are cached under.
    let whole: UInt64
    let keyed: ParagraphKeyed?
    /// While some of its paragraphs wait to be shaped: what shapes them.
    let lazy: LazyFill?
    let content: [UInt8]
    let style: TextStyle
    let scale: Float
    let forced: TextFlow?
    /// The font an empty paragraph's line carries (a `CTFont` under CoreText).
    let baseFont: AnyObject?
    private let lock = NSLock()
    private var composedCache: ShapedText? = nil

    init(paragraphs: [Paragraph], width: Float, fullWidth: Float, height: Float, maxWidth: Float?, align: TextAlign, whole: UInt64, keyed: ParagraphKeyed?, lazy: LazyFill?, content: [UInt8], style: TextStyle, scale: Float, forced: TextFlow?, baseFont: AnyObject?) {
        self.records = paragraphs
        self.baseFont = baseFont
        self.width = width
        self.fullWidth = fullWidth
        self.height = height
        self.maxWidth = maxWidth
        self.align = align
        self.whole = whole
        self.keyed = keyed
        self.lazy = lazy
        self.content = content
        self.style = style
        self.scale = scale
        self.forced = forced
    }

    /// Whether some of its paragraphs wait to be shaped.
    var waiting: Bool { lazy != nil }

    /// How many of its records wait (a run counts once).
    var waitingCount: Int { paragraphs.reduce(0) { $0 + ($1.shaped ? 0 : 1) } }

    /// Its lines that wait, runs counted by their lines.
    var waitingLines: Int { paragraphs.reduce(0) { $0 + ($1.shaped ? 0 : Int($1.lines)) } }

    /// The paragraph indices shaped, top to bottom.
    var shapedIndices: [Int] {
        let paragraphs = self.paragraphs
        return paragraphs.indices.filter { paragraphs[$0].shaped }
    }

    fileprivate func piece(_ k: Int, _ p: Paragraph) -> ParagraphPiece {
        ParagraphPiece(layout: p.layout, start: p.start, end: paragraphTextEnd(content, p.start, p.end), y: p.y, height: p.height, flow: p.flow, index: k)
    }

    /// Its pieces that meet device rows `top...bottom`, top to bottom (`TextFlow::pieces_in`).
    func pieces(top: Float, bottom: Float) -> [ParagraphPiece] {
        let paragraphs = self.paragraphs
        var from = partitionPoint(paragraphs) { $0.y + $0.height < top }
        from = max(0, from)
        var out: [ParagraphPiece] = []
        var k = from
        while k < paragraphs.count, paragraphs[k].y <= bottom {
            out.append(piece(k, paragraphs[k]))
            k += 1
        }
        return out
    }

    /// Glyphs in the field's coordinate and byte space, limited to the visible device rows.
    func glyphs(top: Float, bottom: Float, using system: TextSystem, inks: TextSpanInkMap = TextSpanInkMap(nil)) -> [PositionedGlyph] {
        var result: [PositionedGlyph] = []
        let revision = system.rasterRevision
        let hasInk = !inks.isEmpty
        var cursor = 0
        for piece in pieces(top: top, bottom: bottom) {
            for var glyph in glyphs(at: piece.index, using: system, revision: revision) {
                glyph.rect.y += piece.y / scale
                glyph.utf8Offset += piece.start
                if hasInk { glyph.color = inks.color(at: glyph.utf8Offset, cursor: &cursor) }
                result.append(glyph)
            }
        }
        return result
    }

    /// The piece holding content byte `at`: a paragraph owns the bytes from its start to its end,
    /// the caret after its last word included (`TextFlow::piece_at`).
    func piece(at: Int) -> ParagraphPiece {
        let paragraphs = self.paragraphs
        let k = min(partitionPoint(paragraphs) { $0.end < at }, paragraphs.count - 1)
        return piece(k, paragraphs[k])
    }

    /// The piece at device row `y`, the first or last past either end (`TextFlow::piece_at_y`).
    func piece(atY y: Float) -> ParagraphPiece {
        let paragraphs = self.paragraphs
        let k = min(partitionPoint(paragraphs) { $0.y + $0.height <= y }, paragraphs.count - 1)
        return piece(k, paragraphs[k])
    }

    /// Paragraph `k`'s glyph quads (points, from its own top-left), shaped with glyphs the
    /// first time it is drawn: a measure lays a field out without them.
    func glyphs(at k: Int, using textSystem: TextSystem, revision: UInt64? = nil) -> [PositionedGlyph] {
        let revision = revision ?? textSystem.rasterRevision
        let p = lock.withLock { records[k] }
        guard p.shaped, !p.layout.authText.isEmpty else { return [] }
        if p.layout.hasGlyphs && p.glyphRevision == revision && p.layout.shaped.canReplayGlyphInks {
            #if canImport(CoreText) && canImport(CoreGraphics)
            return p.layout.shaped.glyphs
            #else
            if textSystem.glyphAtlas.retainPages(p.layout.desktopPages, since: p.layout.desktopAtlasResets) {
                return p.layout.shaped.glyphs
            }
            #endif
        }
        let filled = textSystem.breakParagraph(p.layout, maxWidth: p.layout.maxWidth, emitGlyphs: true)
        lock.withLock {
            records[k].layout = filled
            records[k].glyphRevision = revision
        }
        return filled.shaped.glyphs
    }

    /// Its paragraphs' lines stacked as one `ShapedText` at content byte offsets, for the caret,
    /// selection, hit-test and motion code that reads a field's lines (`TextFlow` caret, hit,
    /// line_edge, move_line, range_boxes). A waiting paragraph is one line at its exact height
    /// whose caret stands at its start, as upstream's empty stand-in layout puts it. It holds no
    /// glyphs: a field draws its paragraphs one by one (`pieces`).
    var composed: ShapedText {
        lock.lock()
        if let c = composedCache { lock.unlock(); return c }
        lock.unlock()
        let c = compose()
        lock.lock()
        composedCache = c
        lock.unlock()
        return c
    }

    private func compose() -> ShapedText {
        let paragraphs = self.paragraphs
        var out = paragraphs.first?.layout.shaped ?? lazy?.ascii.empty.shaped ?? ShapedText(size: .zero, lineCount: 1, lineHeight: style.resolvedLineHeight, glyphs: [], underlines: [], backgrounds: [])
        let invS = 1.0 / max(scale, 1e-4)
        let lhPt = style.resolvedLineHeight
        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        out.desktopParagraph = nil
        out.desktopRestingText = nil
        #endif
        out.glyphs = []
        out.underlines = []
        out.strikethroughs = []
        out.backgrounds = []
        out.pillChips = []
        out.inlineIcons = []
        out.lineHeight = lhPt
        out.wasTruncated = false
        out.elided = nil
        out.forcedDirection = forced
        out.primaryIsRTL = (forced ?? paragraphs.first?.flow) == .rtl
        out.drawnText = String(decoding: content, as: UTF8.self)
        var tops: [Float] = []
        var boxHeights: [Float] = []
        var metricHeights: [Float] = []
        var advances: [(widthPx: Float, trailingWsPx: Float)] = []
        // Each line's baseline (device px from the field's top) and its exact fraction, as one
        // layout records them (#935); kept only when every line has one.
        var baselines: [Float] = []
        var baselinesKnown = true
        func baseline(_ s: ShapedText, _ i: Int, _ yPx: Float) {
            guard baselinesKnown, i < s.lineBaselinesPx.count else { baselinesKnown = false; return }
            baselines.append(yPx + s.lineBaselinesPx[i])
        }
        #if canImport(CoreText) && canImport(CoreGraphics)
        var lines: [(utf8Start: Int, text: String, originY: Float, originX: Float, ctLine: CTLine?)] = []
        #else
        var lines: [(utf8Start: Int, text: String, originY: Float, originX: Float, charOffsets: [Float])] = []
        out.portableBidiCells.removeAll()
        #endif
        var markerLines: [ShapedText.MarkerMap.LineRange] = []
        lines.reserveCapacity(paragraphs.count)
        // Each paragraph's UTF-16 start in the whole text, for the motion code's run indices.
        var u16 = 0
        var at = 0
        func advanceU16(to byte: Int) {
            while at < byte {
                let b = content[at]
                if b & 0xC0 != 0x80 { u16 += b >= 0xF0 ? 2 : 1 }
                at += 1
            }
        }
        #if canImport(CoreText) && canImport(CoreGraphics)
        let emptyLine: CTLine = {
            let font = baseFont as! CTFont
            let attr = CFAttributedStringCreate(kCFAllocatorDefault, "" as CFString, [kCTFontAttributeName: font] as CFDictionary)!
            return CTLineCreateWithAttributedString(attr)
        }()
        #endif
        var spans: [ParagraphLineSpan] = []
        spans.reserveCapacity(paragraphs.count)
        for p in paragraphs {
            advanceU16(to: p.start)
            let firstLine = lines.count
            let yPt = p.y * invS
            let s = p.layout.shaped
            #if canImport(CoreText) && canImport(CoreGraphics)
            let records = s.lineStrings
            #else
            let records = s.portableLines
            #endif
            let end = paragraphTextEnd(content, p.start, p.end)
            let hasText = p.shaped && p.start < end && !records.isEmpty
            defer { spans.append(ParagraphLineSpan(start: p.start, end: end, firstLine: firstLine, lineCount: lines.count - firstLine, rtl: p.flow == .rtl, shaped: hasText)) }
            if !hasText {
                let text = p.start == end ? "" : String(decoding: content[p.start..<end], as: UTF8.self)
                // An empty line's caret stands at its start: the right edge of a right-to-left one.
                let x: Float = (p.start == end && p.flow == .rtl) ? max(0, (maxWidth.map { $0 * scale } ?? width)) * invS : 0
                #if canImport(CoreText) && canImport(CoreGraphics)
                lines.append((p.start, text, yPt, x, (p.shaped || p.start == end) ? emptyLine : nil))
                #else
                out.portableBidiCells[lines.count] = []
                lines.append((p.start, text, yPt, x, [0]))
                #endif
                let u16Len = text.utf16.count
                markerLines.append(.init(shapedU16Start: 0, shapedU16End: u16Len, authU16Start: u16, authU16End: u16 + u16Len, authUTF8Start: p.start))
                tops.append(yPt)
                boxHeights.append(p.height * invS)
                metricHeights.append(p.height * invS)
                advances.append((p.widths.y, 0))
                // A stand-in line sits on an empty line's baseline, as upstream's empty layout does.
                baseline(p.shaped ? p.layout.shaped : (lazy?.ascii.empty.shaped ?? p.layout.shaped), 0, p.y)
                continue
            }
            for (i, rec) in records.enumerated() {
                let byte = p.start + rec.utf8Start
                #if canImport(CoreText) && canImport(CoreGraphics)
                lines.append((byte, rec.text, rec.originY + yPt, rec.originX, rec.ctLine))
                if i < s.markerMap.lines.count {
                    var lr = s.markerMap.lines[i]
                    lr.authU16Start += u16
                    lr.authU16End += u16
                    lr.authUTF8Start += p.start
                    markerLines.append(lr)
                }
                #else
                if let cells = s.portableBidiCells[i] {
                    out.portableBidiCells[lines.count] = cells.map { cell in
                        PortableCaretCell(range: (p.start + cell.range.lowerBound)..<(p.start + cell.range.upperBound),
                                          left: cell.left, width: cell.width, rtl: cell.rtl, space: cell.space,
                                          pillEdge: cell.pillEdge)
                    }
                }
                lines.append((byte, rec.text, rec.originY + yPt, rec.originX, rec.charOffsets))
                advanceU16(to: byte)
                let length = rec.text.utf16.count
                markerLines.append(.init(shapedU16Start: 0, shapedU16End: length, authU16Start: u16,
                                         authU16End: u16 + length, authUTF8Start: byte))
                #endif
                tops.append(yPt + s.lineTopPt(i))
                boxHeights.append(s.lineBoxHeightPt(i))
                metricHeights.append(s.lineMetricHeightPt(i))
                advances.append(i < s.lineAdvancesPx.count ? s.lineAdvancesPx[i] : (0, 0))
                baseline(s, i, p.y)
            }
        }
        #if canImport(CoreText) && canImport(CoreGraphics)
        out.lineStrings = lines
        // `newline`: a quarter of the primary font's ascent and descent, at the field's size.
        if let font = baseFont {
            let f = font as! CTFont
            out.paragraphNewlinePt = 0.25 * Float(CTFontGetAscent(f) + abs(CTFontGetDescent(f))) * invS
        } else {
            out.paragraphNewlinePt = 0.25 * style.size
        }
        #else
        out.portableLines = lines
        out.paragraphNewlinePt = paragraphs.lazy.map { $0.layout.shaped.paragraphNewlinePt }.first { $0 > 0 } ?? 0.25 * style.size
        #endif
        out.paragraphSpans = spans
        out.lineIsRTL = spans.flatMap { Array(repeating: $0.rtl, count: $0.lineCount) }
        var mm = ShapedText.MarkerMap()
        mm.authText = out.drawnText
        mm.lines = markerLines
        out.markerMap = mm
        out.lineCount = max(1, lines.count)
        out.lineAdvancesPx = advances
        out.lineGlyphRanges = Array(repeating: 0..<0, count: advances.count)
        out.grownLineTopsPt = tops
        out.grownLineHeightsPt = boxHeights
        out.grownLineMetricHeightsPt = metricHeights
        out.lineBaselinesPx = baselinesKnown ? baselines : []
        out.underlineLineEndsPt = []
        #if canImport(CoreText) && canImport(CoreGraphics)
        out.glyphPens = []
        #endif
        if let last = paragraphs.last {
            let s = last.layout.shaped
            out.lastLineAdvancePx = last.shaped ? s.lastLineAdvancePx : last.widths.y
            out.hangingAdvancePx = last.shaped ? s.hangingAdvancePx : 0
            out.lastLineWidthPx = last.shaped ? s.lastLineWidthPx : last.widths.y
            out.lastLineTrailingWsPx = last.shaped ? s.lastLineTrailingWsPx : 0
        }
        // `TextFlow::spec_height`: its paragraphs' height, at least a line, snapped as one layout's.
        let hPx = max(height, lhPt * scale)
        let snapped = style.exactLines ? (hPx * 64).rounded() / 64 : ceilf(hPx)
        // As wide as its widest line to a 64th of a device pixel, as one layout is (`text_width`, #934).
        out.size = Vec2(TextBoxGeometry.textWidth(fullWidth) * invS, snapped * invS)
        return out
    }
}

/// The first index of `xs` for which `pred` is false, `xs` being partitioned (`partition_point`).
@inline(__always)
internal func partitionPoint<T>(_ xs: [T], _ pred: (T) -> Bool) -> Int {
    var lo = 0
    var hi = xs.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if pred(xs[mid]) { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

/// A text's lines between two of its bytes as one width's keying read them (`key_paragraphs`):
/// where each ends and what it holds, so the other width's keying of a long paste, in the same
/// layout pass, reads these instead of the bytes. Dropped when a commit ends.
internal struct LineScan {
    var key: [Int]
    var content: [UInt8]
    var ends: [UInt32]
    var flags: [UInt8]
}

/// A by-paragraph layout in the cache and the commit it was last used in, with about how many
/// heap bytes it holds (`layout_cache::Entry`).
internal struct ParagraphCacheEntry {
    var layout: ParagraphLayout
    var used: UInt64
    var cost: Int

    /// `Entry::new`: `textLen` bytes at `LAYOUT_PER_BYTE` each, on top of `LAYOUT_BASE`.
    init(_ layout: ParagraphLayout, used: UInt64, textLen: Int) {
        self.layout = layout
        self.used = used
        self.cost = ParagraphState.layoutCost(textBytes: textLen)
    }
}

/// By-paragraph layouts by key, the field each was last laid out for, printable ASCII's
/// measures per style, and one layout pass's scratch (`TextSystem` fields in `text.rs`).
internal final class ParagraphState: @unchecked Sendable {
    /// Heap bytes a layout holds per byte of its text, and on top of that (`layout_cache.rs`).
    static let layoutPerByte = 64
    static let layoutBase = 2048
    static func layoutCost(textBytes: Int) -> Int {
        let maxCost = Int(clamping: UInt32.max)
        let maxTextLen = (maxCost - layoutBase) / layoutPerByte
        return textBytes > maxTextLen ? maxCost : textBytes * layoutPerByte + layoutBase
    }
    /// Heap bytes of layouts kept after the commits that used them (`STALE_BYTES`).
    static let staleBytes = 3 << 20
    /// `size_of::<Paragraph>()` upstream (64-bit): what a layout's records cost in the cache.
    static let paragraphRecordBytes = 72

    let lock = NSRecursiveLock()
    var generation: UInt64 = 0
    var cache: [UInt64: ParagraphCacheEntry] = [:]
    /// The last by-paragraph layout made this commit, which its text at another width breaks from.
    var lastParagraphs: ParagraphLayout? = nil
    /// Each field's last layout (upstream's node slot `text_layout`), which its next edit keeps
    /// paragraphs of.
    var fields: [UInt64: (layout: ParagraphLayout, used: UInt64)] = [:]
    var ascii: [UInt64: AsciiLine?] = [:]
    var lineScan: LineScan? = nil
    /// The last two texts compared (`last_diff`) and their common start and end.
    var lastDiff: (old: [UInt8], new: [UInt8], prefix: Int, suffix: Int)? = nil
    /// The last text's bytes, so both widths a measure asks for read one copy.
    var lastBytes: (text: String, bytes: [UInt8])? = nil
    /// Paragraphs shaped anew (not kept, not re-broken), for tests.
    var shapedParagraphs: Int = 0

    /// `end_commit`'s by-paragraph half: evicts stale layouts past `STALE_BYTES` and forgets the
    /// commit's last layout and comparisons, then moves the generation on.
    func endCommit() {
        lock.lock()
        defer { lock.unlock() }
        Self.evict(&cache, generation, budget: Self.staleBytes)
        lastParagraphs = nil
        lastDiff = nil
        lineScan = nil
        lastBytes = nil
        // A field's last layout is its node's (upstream keeps it in the node's slot); fields long
        // gone are dropped once more than 64 are held.
        if fields.count > 64 {
            let keep = fields.sorted { $0.value.used > $1.value.used }.prefix(64)
            fields = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        generation &+= 1
    }

    /// `rest`: drops every layout the last two commits didn't use.
    func rest() {
        lock.lock()
        defer { lock.unlock() }
        Self.evict(&cache, generation &- 1, budget: 0)
    }

    /// `evict_to`: drops what `cache` hasn't used in the last two commits once it outgrows
    /// `budget`, least recently used first; a commit's layouts are kept together while the
    /// budget lasts.
    static func evict(_ cache: inout [UInt64: ParagraphCacheEntry], _ g: UInt64, budget: Int) {
        let keys = staleKeys(in: cache, at: g, budget: budget, used: { $0.used }, cost: { $0.cost })
        for key in keys { cache.removeValue(forKey: key) }
    }

    /// Find the first generation that does not fit. Entries in that generation get its
    /// remaining room in cache iteration order, including smaller entries after a miss.
    static func staleKeys<Key, Entry>(in cache: [Key: Entry], at generation: UInt64, budget: Int,
                                       used: (Entry) -> UInt64, cost: (Entry) -> Int) -> [Key] {
        var bytesByAge: [UInt64: UInt64] = [:]
        var total: UInt64 = 0
        for entry in cache.values {
            let age = generation &- used(entry)
            guard age >= 2 else { continue }
            let bytes = UInt64(cost(entry))
            bytesByAge[age, default: 0] += bytes
            total += bytes
        }
        var room = UInt64(budget)
        guard total > room else { return [] }
        var cutoff = UInt64.max
        for age in bytesByAge.keys.sorted() {
            let bytes = bytesByAge[age]!
            if bytes > room {
                cutoff = age
                break
            }
            room -= bytes
        }
        var removed: [Key] = []
        for index in cache.indices {
            let entry = cache.values[index]
            let age = generation &- used(entry)
            guard age >= cutoff else { continue }
            if age == cutoff {
                let bytes = UInt64(cost(entry))
                if bytes <= room {
                    room -= bytes
                    continue
                }
            }
            removed.append(cache.keys[index])
        }
        return removed
    }

    func bytes(of text: String) -> [UInt8] {
        // Bytes, not `==`: canonically equal texts (NFC and NFD) hold different bytes.
        if let (t, b) = lastBytes, HistoryText.sameBytes(t, text) { return b }
        let b = Array(text.utf8)
        lastBytes = (text, b)
        return b
    }
}

/// A paragraph found in a field's text: its bytes, direction, key, and for a run of waiting
/// lines its height, width and line count (`Found`).
internal struct FoundParagraph {
    var start: Int
    var end: Int
    var flow: TextFlow
    var key: UInt64
    var run: (height: Float, width: Float, lines: UInt32)?
}

/// What lets lines wait as runs while they're keyed: printable ASCII's measures at the field's
/// width (device px), and whether the lines are an edit's (whose ends are shaped at once, as
/// the caret's window) or a waiting run's keyed again at another width.
internal struct ParagraphRuns {
    var ascii: AsciiLine
    var maxWidth: Float?
    var edit: Bool
}

/// Paragraph records are split at LF. A preceding CR belongs to the same authored break,
/// so shaping, measuring, and selection must stop before it.
internal func paragraphTextEnd(_ content: [UInt8], _ start: Int, _ end: Int) -> Int {
    end > start && end < content.count && content[end] == 0x0A && content[end - 1] == 0x0D ? end - 1 : end
}

/// `\n` bytes in `s[a..<b]`, counted eight at a time (`count_newlines`).
internal func countNewlines(_ s: [UInt8], _ a: Int, _ b: Int) -> Int {
    var n = 0
    var i = a
    s.withUnsafeBytes { raw in
        while i + 8 <= b {
            let w = raw.loadUnaligned(fromByteOffset: i, as: UInt64.self).littleEndian ^ 0x0a0a_0a0a_0a0a_0a0a
            // Count each matching byte independently. Subtracting 0x01 per byte
            // borrows across adjacent LF/vertical-tab bytes and counts both as LF.
            let lowBits: UInt64 = 0x7f7f_7f7f_7f7f_7f7f
            let nonzero = ((w & lowBits) &+ lowBits) | w | lowBits
            n += (~nonzero).nonzeroBitCount
            i += 8
        }
    }
    while i < b {
        if s[i] == 0x0a { n += 1 }
        i += 1
    }
    return n
}

/// How many bytes two texts share from their start: compared 4 KB at a time, then byte by byte
/// inside the first block that differs (`common_start`).
internal func commonStart(_ a: [UInt8], _ b: [UInt8]) -> Int {
    let n = min(a.count, b.count)
    var at = 0
    a.withUnsafeBytes { ra in
        b.withUnsafeBytes { rb in
            while at + 4096 <= n && memcmp(ra.baseAddress! + at, rb.baseAddress! + at, 4096) == 0 { at += 4096 }
        }
    }
    while at < n && a[at] == b[at] { at += 1 }
    return at
}

/// How many bytes two texts share at their end, as `commonStart` counts (`common_end`).
internal func commonEnd(_ a: [UInt8], _ b: [UInt8]) -> Int {
    let n = min(a.count, b.count)
    var at = 0
    a.withUnsafeBytes { ra in
        b.withUnsafeBytes { rb in
            while at + 4096 <= n && memcmp(ra.baseAddress! + (a.count - at - 4096), rb.baseAddress! + (b.count - at - 4096), 4096) == 0 { at += 4096 }
        }
    }
    while at < n && a[a.count - 1 - at] == b[b.count - 1 - at] { at += 1 }
    return at
}

/// A paragraph's direction: its first strong character's, or nil with none (`flow_of`).
internal func paragraphFlowOf(_ words: String) -> TextFlow? {
    Direction.of(words).map { $0 == .rtl ? .rtl : .ltr }
}

extension TextSystem {

    /// `style` and scale's key without any text (`hash::text_hash("", ..)` with `wrap_anywhere`).
    internal func paragraphStyleKey(_ style: TextStyle, scale: Float) -> UInt64 {
        var h = Hasher()
        h.combine(style)
        if style.fontSmoothing == .systemDefault { h.combine(smoothing) }
        h.combine(scale)
        h.combine(currentFontEpoch)
        h.combine(language)
        return UInt64(bitPattern: Int64(h.finalize()))
    }

    /// A field's layout as a text node shows it (`layout_text`): a by-paragraph field's
    /// paragraphs when `request` asks for them and the text is one (more than one paragraph, no
    /// layout-affecting spans or pills, wrapped), else one layout from `layoutKeyed`.
    internal func layoutInput(
        text: String,
        spans: [TextSpan]?,
        pills: [PillChip],
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool,
        keep: TextKeep = .cached,
        countAsRebreak: Bool = true,
        request: ParagraphRequest?,
        rasterWindow: TextRasterWindow? = nil
    ) -> TextLayoutBox {
        if let request, keep != .secret, pills.isEmpty, style.wrap == .wrap, style.maxLines == 0,
           ParagraphRequest.supports(spans) {
            // A rich field's authored bytes come from its span strings, as in layoutKeyed.
            let authored = spans.flatMap { $0.isEmpty ? nil : $0.map(\.text).joined() } ?? text
            if authored.utf8.contains(0x0a) {
                let laid = layoutParagraphs(text: authored, style: style, maxWidth: maxWidth, pixelScale: pixelScale, request: request)
                let prepared = prepareHighlights(request.highlights, in: laid, field: request.field)
                return paragraphBox(prepared, text: authored, spans: spans, style: style, pixelScale: pixelScale)
            }
        }
        return layoutKeyed(text: text, spans: spans, pills: pills, style: style, maxWidth: maxWidth, pixelScale: pixelScale, emitGlyphs: emitGlyphs, keep: keep, countAsRebreak: countAsRebreak, rasterWindow: rasterWindow)
    }

    /// The `TextLayoutBox` a node holds for `laid`.
    internal func paragraphBox(_ laid: ParagraphLayout, text: String, spans: [TextSpan]? = nil, style: TextStyle, pixelScale: Float) -> TextLayoutBox {
        let scale = max(pixelScale, 1.0)
        let key = TextShapeKey(authText: text, spans: nil, pills: [], style: style, pixelScale: scale, fontEpoch: currentFontEpoch,
                               languageTag: language, maxWidth: laid.maxWidth, defaultSmoothing: smoothing)
        let box = TextLayoutBox(shapeKey: key, authText: text, spans: nil, pills: [], style: style, pixelScale: scale, maxWidth: laid.maxWidth, shaped: laid.composed, hasGlyphs: true, prepared: nil)
        box.paragraphs = laid
        return box.applyingSpanInks(spans)
    }

    /// Break a retained paragraph at a new width or materialize its glyphs for paint.
    fileprivate func breakParagraph(_ box: TextLayoutBox, maxWidth: Float?, emitGlyphs: Bool) -> TextLayoutBox {
        if let retained = rebreakOwned(box, maxWidth: maxWidth, emitGlyphs: emitGlyphs) { return retained }
        return layoutKeyed(text: box.authText, style: box.style, maxWidth: maxWidth, pixelScale: box.pixelScale,
                           emitGlyphs: emitGlyphs, keep: .owned, countAsRebreak: false)
    }

    /// `layout_text`'s by-paragraph half: the cached layout at this width, else one laid out from
    /// the field's last (`prev`) and this text's at the other width a measure asked for (`other`).
    internal func layoutParagraphs(text: String, style: TextStyle, maxWidth: Float?, pixelScale: Float, request: ParagraphRequest) -> ParagraphLayout {
        let st = paragraphState
        st.lock.lock()
        defer { st.lock.unlock() }
        let scale = max(pixelScale, 1.0)
        // Keyed by the text's bytes, as upstream's shape key is: Swift hashes a `String` by
        // canonical equivalence, which would hand NFD text the layout of its NFC form.
        let bytes = st.bytes(of: text)
        var wh = Hasher()
        wh.combine(bytes.count)
        bytes.withUnsafeBytes { wh.combine(bytes: $0) }
        wh.combine(paragraphStyleKey(style, scale: scale))
        wh.combine(request.forced)
        var whole = UInt64(bitPattern: Int64(wh.finalize()))
        // Lines with no strong character take the element's flow, so it keys the whole too.
        if (request.forced ?? request.startFlow) == .rtl { whole ^= ParagraphConstants.paragraphs }
        let key = Self.paragraphBreakKey(whole, maxWidth: maxWidth, align: style.align)
        let g = st.generation
        if var e = st.cache[key] {
            e.used = g
            st.cache[key] = e
            st.fields[request.field] = (e.layout, g)
            return e.layout
        }
        // Measuring asks at more than one width: the last text's layout at this one, when it
        // was laid out there too, keeps its paragraphs without breaking them again.
        let prev: ParagraphLayout? = st.fields[request.field].map { f in
            let p = f.layout
            if p.maxWidth == maxWidth && p.align == style.align { return p }
            let there = Self.paragraphBreakKey(p.whole, maxWidth: maxWidth, align: style.align)
            return st.cache[there]?.layout ?? p
        }
        // This text laid out at another width measuring asked for this commit: a paragraph
        // neither keeps is broken again from it rather than shaped twice.
        let other = st.lastParagraphs.flatMap { o in (o.whole == whole && (o.maxWidth != maxWidth || o.align != style.align)) ? o : nil }
        let (built, fresh) = layOutParagraphs(text: text, style: style, scale: scale, maxWidth: maxWidth, whole: whole, cacheKey: key, request: request, prev: prev, other: other)
        st.lastParagraphs = built
        // It holds what it shaped or broke anew; the paragraphs it kept are its last layout's.
        st.cache[key] = ParagraphCacheEntry(built, used: g, textLen: fresh + built.paragraphs.count * ParagraphState.paragraphRecordBytes / 64)
        st.fields[request.field] = (built, g)
        return built
    }

    internal static func paragraphBreakKey(_ whole: UInt64, maxWidth: Float?, align: TextAlign) -> UInt64 {
        var h = Hasher()
        h.combine(whole ^ ParagraphConstants.paragraphs)
        h.combine(maxWidth.map { $0.bitPattern })
        h.combine(align)
        return UInt64(bitPattern: Int64(h.finalize()))
    }

    /// `style` with `flow` as its paragraph direction.
    fileprivate static func styled(_ style: TextStyle, _ flow: TextFlow) -> TextStyle {
        var s = style
        s.direction = flow
        return s
    }

    /// A paragraph's measures from its layout: height (device px, at least a line when empty)
    /// and width without and with trailing whitespace.
    internal static func measures(_ box: TextLayoutBox, blank: Bool, scale: Float, linePx: Float) -> (Float, SIMD2<Float>) {
        let s = box.shaped
        let n = s.cursorLineCount
        var h: Float = n == 0 ? 0 : (s.lineTopPt(n - 1) + s.lineBoxHeightPt(n - 1)) * scale
        if blank || n == 0 { h = max(h, linePx) }
        var w: Float = 0
        var full: Float = 0
        for a in s.lineAdvancesPx {
            w = max(w, max(0, a.widthPx - a.trailingWsPx))
            full = max(full, a.widthPx)
        }
        return (h, SIMD2(w, full))
    }

    /// Lays out each of the text's paragraphs, keeping `prev`'s layout of each it still has: those
    /// before an edit and after it (`lay_out_paragraphs`).
    private func layOutParagraphs(text: String, style: TextStyle, scale: Float, maxWidth: Float?, whole: UInt64, cacheKey: UInt64, request: ParagraphRequest, prev: ParagraphLayout?, other: ParagraphLayout?) -> (ParagraphLayout, Int) {
        let st = paragraphState
        let content = st.bytes(of: text)
        let styleKey = paragraphStyleKey(style, scale: scale)
        let forced = request.forced
        let startFlow = request.forced ?? request.startFlow
        let maxPx = maxWidth.map { $0 * scale }
        // A plain text's edit keys only the paragraphs it touched (`reuse_keys`).
        let reused = prev.flatMap { reuseKeys($0, content: content, styleKey: styleKey, startFlow: startFlow) }
        var found = reused?.head ?? []
        let tail = reused?.tail ?? []
        let entering = reused?.entering ?? startFlow
        let at = found.last.map { $0.end + 1 } ?? 0
        // A long paste's plain ASCII lines that fit on one line, away from the edit's ends, wait
        // as runs: one record each, at their exact height, for `fillParagraphs`.
        let edited = max(0, (tail.first?.start ?? content.count) - at)
        // A min-content measure of a text whose lines wait keys an edit's lines into runs too.
        let line = style.resolvedLineHeight * scale
        let measuring = (prev?.waiting ?? false) && (maxPx.map { $0 < line } ?? false)
        let wantsAscii = measuring || (edited > ParagraphConstants.lazyMin * 8 && countNewlines(content, at, at + edited) > ParagraphConstants.lazyMin)
        let ascii = wantsAscii ? asciiLine(style: style, scale: scale) : nil
        let runs = ascii.map { ParagraphRuns(ascii: $0, maxWidth: maxPx, edit: true) }
        if let t = tail.first?.start {
            keyParagraphs(content, styleKey: styleKey, a: at, z: t - 1, startFlow: startFlow, forced: forced, runs: runs, found: &found)
            // The paragraphs after the edit keep their keys if they start from the direction
            // they were keyed in (a neutral one takes the one before it).
            if found.last?.flow == entering {
                found.append(contentsOf: tail)
            } else {
                keyParagraphs(content, styleKey: styleKey, a: t, z: content.count, startFlow: startFlow, forced: forced, runs: nil, found: &found)
            }
        } else {
            keyParagraphs(content, styleKey: styleKey, a: at, z: content.count, startFlow: startFlow, forced: forced, runs: runs, found: &found)
        }
        // What the edit left alone: the paragraphs before it, and those after it.
        let old = prev?.paragraphs ?? []
        let n = found.count
        var before = 0
        while before < min(n, old.count), found[before].key == old[before].key { before += 1 }
        var after = 0
        while after < min(n - before, old.count - before), found[n - 1 - after].key == old[old.count - 1 - after].key { after += 1 }
        let rebreak = prev.map { $0.maxWidth != maxWidth || $0.align != style.align } ?? false
        // Each record found with the one the last layout had for it. A waiting one broken at
        // another width is keyed again there: its lines may not all fit any more.
        var items: [(FoundParagraph, Paragraph?)] = []
        items.reserveCapacity(n)
        for (k, f) in found.enumerated() {
            let kept: Paragraph? = k < before ? old[k] : (k >= n - after ? old[old.count - (n - k)] : nil)
            if let o = kept, !o.shaped, rebreak {
                let m = ascii ?? asciiLine(style: style, scale: scale)
                var again: [FoundParagraph] = []
                let from = items.last?.0.flow ?? startFlow
                keyParagraphs(content, styleKey: styleKey, a: f.start, z: f.end, startFlow: from, forced: forced, runs: m.map { ParagraphRuns(ascii: $0, maxWidth: maxPx, edit: false) }, found: &again)
                items.append(contentsOf: again.map { ($0, nil) })
            } else {
                items.append((f, kept))
            }
        }
        var waiting = 0
        var paragraphs: [Paragraph] = []
        paragraphs.reserveCapacity(items.count)
        var y: Double = 0
        var width: Float = 0
        var fullWidth: Float = 0
        var fresh = 0
        for (k, item) in items.enumerated() {
            let (f, kept) = item
            // A waiting record kept at the same width stays as it was; a run found here waits.
            var wait: (Float, Float, UInt32, TextLayoutBox, Bool)? = nil
            if let o = kept, !o.shaped {
                wait = (o.height, o.widths.x, o.lines, o.layout, o.run)
            } else if kept == nil, let r = f.run, let m = ascii ?? asciiLine(style: style, scale: scale) {
                wait = (r.height, r.width, r.lines, m.empty, true)
            }
            if let (height, w, lines, layout, run) = wait {
                waiting += 1
                width = max(width, w)
                fullWidth = max(fullWidth, w)
                paragraphs.append(Paragraph(start: f.start, end: f.end, y: Float(y.rounded()), height: height, widths: SIMD2(w, w), flow: f.flow, key: f.key, layout: layout, shaped: false, lines: lines, run: run))
                y += Double(height)
                continue
            }
            // The same paragraph at the other width (the same text, so the same index).
            let twin: Paragraph? = other.flatMap { o in k < o.paragraphs.count && o.paragraphs[k].key == f.key && o.paragraphs[k].shaped ? o.paragraphs[k] : nil }
            // A kept paragraph broken at another width, or this text's own paragraph at the
            // other width measuring asks for, breaks again here rather than shaping anew.
            let again: Paragraph? = kept != nil ? (rebreak ? kept : nil) : twin
            let pstyle = Self.styled(style, f.flow)
            let textEnd = paragraphTextEnd(content, f.start, f.end)
            let layout: TextLayoutBox
            if let o = again {
                fresh += f.end - f.start
                layout = breakParagraph(o.layout, maxWidth: maxWidth, emitGlyphs: false)
            } else if let o = kept {
                layout = o.layout
            } else {
                st.shapedParagraphs += 1
                fresh += f.end - f.start
                layout = layoutKeyed(text: String(decoding: content[f.start..<textEnd], as: UTF8.self), style: pstyle, maxWidth: maxWidth, pixelScale: scale, emitGlyphs: false, keep: .owned, countAsRebreak: false)
            }
            // A paragraph kept as it was keeps its measures too.
            let (height, widths): (Float, SIMD2<Float>) = (kept != nil && again == nil) ? (kept!.height, kept!.widths) : Self.measures(layout, blank: f.start == textEnd, scale: scale, linePx: line)
            width = max(width, widths.x)
            fullWidth = max(fullWidth, widths.y)
            paragraphs.append(Paragraph(start: f.start, end: f.end, y: Float(y.rounded()), height: height, widths: widths, flow: f.flow, key: f.key, layout: layout, shaped: true, lines: 1, run: false))
            y += Double(height)
        }
        // One copy of a long text for both widths a measure asks for, not one each.
        let keyed = ParagraphKeyed(content: content, styleKey: styleKey, startFlow: startFlow)
        let lazy: LazyFill? = waiting > 0 ? asciiLine(style: style, scale: scale).map {
            LazyFill(content: content, style: style, scale: scale, cacheKey: cacheKey, styleKey: styleKey, forced: forced, startFlow: startFlow, ascii: $0)
        } : nil
        #if canImport(CoreText) && canImport(CoreGraphics)
        let baseFont: AnyObject? = resolveCTFont(style: style, pixelScale: scale)
        #else
        let baseFont: AnyObject? = nil
        #endif
        return (ParagraphLayout(paragraphs: paragraphs, width: width, fullWidth: fullWidth, height: Float(y), maxWidth: maxWidth, align: style.align, whole: whole, keyed: keyed, lazy: lazy, content: content, style: style, scale: scale, forced: forced, baseFont: baseFont), fresh)
    }

    /// The paragraphs an edit left whole, with their keys: those before it (`head`) and after it
    /// (`tail`, moved to their new bytes), and the direction the paragraph before the tail had
    /// (`Reuse`, `reuse_keys`). The edit is what lies between the texts' common start and end.
    private func reuseKeys(_ prev: ParagraphLayout, content: [UInt8], styleKey: UInt64, startFlow: TextFlow) -> (head: [FoundParagraph], tail: [FoundParagraph], entering: TextFlow)? {
        guard let keyed = prev.keyed, keyed.styleKey == styleKey, keyed.startFlow == startFlow else { return nil }
        let st = paragraphState
        let old = keyed.content
        let prefix: Int
        let suffix: Int
        if let d = st.lastDiff, d.old == old, d.new == content {
            (prefix, suffix) = (d.prefix, d.suffix)
        } else {
            prefix = commonStart(old, content)
            suffix = min(commonEnd(old, content), min(old.count, content.count) - prefix)
            st.lastDiff = (old, content, prefix, suffix)
        }
        let ps = prev.paragraphs
        // Before the edit: its newline too. After it: the newline before it too.
        let h = partitionPoint(ps) { $0.end < prefix }
        let t = partitionPoint(ps) { $0.start + suffix <= old.count }
        let shift = content.count - old.count
        let found = { (p: Paragraph, by: Int) in FoundParagraph(start: p.start + by, end: p.end + by, flow: p.flow, key: p.key, run: p.run ? (p.height, p.widths.x, p.lines) : nil) }
        return (
            ps[..<h].map { found($0, 0) },
            ps[t...].map { found($0, shift) },
            t > 0 ? ps[t - 1].flow : startFlow
        )
    }

    /// Keys the paragraphs of content bytes `a..<z` (a paragraph's start to a paragraph's end)
    /// onto `found` (`key_paragraphs`). A paragraph with no strong character reads the way the one
    /// before it does, the first `startFlow`; with `forced`, every paragraph reads that way. With
    /// `runs`, more than `lazyMin` lines of an edit (or any number of a run keyed again) put the
    /// plain ASCII lines that fit on one line, away from the edit's ends, in runs: one record per
    /// run, keyed by its bytes, its height the sum of its lines'.
    internal func keyParagraphs(_ content: [UInt8], styleKey: UInt64, a: Int, z: Int, startFlow: TextFlow, forced: TextFlow?, runs runsIn: ParagraphRuns?, found: inout [FoundParagraph]) {
        let st = paragraphState
        // The other width's keying of these bytes, this layout pass, read them already.
        let scanKey = [content.count, a, z]
        var cache: LineScan? = nil
        if runsIn != nil, let s = st.lineScan, s.key == scanKey, s.content == content {
            cache = s
            st.lineScan = nil
        }
        let lines: Int
        if let c = cache { lines = c.ends.count } else if runsIn != nil { lines = countNewlines(content, a, z) + 1 } else { lines = 0 }
        let runs = runsIn.flatMap { r in (!r.edit || lines > ParagraphConstants.lazyMin || r.ascii.narrow(r.maxWidth)) ? r : nil }
        var record: LineScan? = (runs != nil && cache == nil) ? LineScan(key: scanKey, content: content, ends: [], flags: []) : nil
        record?.ends.reserveCapacity(lines)
        record?.flags.reserveCapacity(lines)
        // The run being gathered: its first byte, last byte, height, width, lines and last flow.
        var run: (a: Int, b: Int, height: Float, w: Float, n: UInt32, flow: TextFlow)? = nil
        func close() {
            if let r = run {
                run = nil
                var h = Hasher()
                content.withUnsafeBytes { h.combine(bytes: UnsafeRawBufferPointer(rebasing: $0[r.a..<r.b])) }
                h.combine(styleKey)
                h.combine(r.flow == .rtl)
                h.combine(r.n)
                h.combine("run")
                found.append(FoundParagraph(start: r.a, end: r.b, flow: r.flow, key: UInt64(bitPattern: Int64(h.finalize())), run: (r.height, r.w, r.n)))
            }
        }
        var start = a
        var j = 0
        while true {
            let b: Int
            var known: UInt8? = nil
            if let c = cache {
                guard j < c.ends.count else { break }
                b = a + Int(c.ends[j])
                known = c.flags[j]
            } else {
                guard start <= z else { break }
                var e = start
                while e < z && content[e] != 0x0a { e += 1 }
                b = e
            }
            let s = start
            let textEnd = paragraphTextEnd(content, s, b)
            start = b + 1
            let lastFlow = run?.flow ?? found.last?.flow ?? startFlow
            if let r = runs {
                // A measure of the narrowest width is never shown: none of its lines needs shaping.
                let near = r.edit && !r.ascii.narrow(r.maxWidth) && (j < ParagraphConstants.eagerStart || j + ParagraphConstants.eagerEnd >= lines)
                let floor = run?.w ?? 0
                let printable = known.map { $0 & ParagraphConstants.printable != 0 }
                var fits: (Float, Float)? = nil
                if !(near || s == textEnd || printable == false) {
                    fits = r.ascii.narrow(r.maxWidth)
                        ? r.ascii.narrowest(content, s, textEnd, floor: floor)
                        : r.ascii.oneLine(content, s, textEnd, maxWidth: r.maxWidth, floor: floor, printableKnown: printable == true)
                }
                // Printable ASCII: its letters are its only strong characters, all left to right.
                let letter: () -> Bool = {
                    if let f = known { return f & ParagraphConstants.letter != 0 }
                    var i = s
                    while i < b { let c = content[i] | 0x20; if c >= 0x61 && c <= 0x7a { return true }; i += 1 }
                    return false
                }
                if record != nil {
                    let shown = fits != nil || (s < textEnd && asciiPrintable(content, s, textEnd))
                    record!.ends.append(UInt32(b - a))
                    record!.flags.append(shown ? (ParagraphConstants.printable | (letter() ? ParagraphConstants.letter : 0)) : 0)
                }
                if let (height, w) = fits {
                    let flow = forced ?? (letter() ? .ltr : lastFlow)
                    if run != nil {
                        run!.b = b
                        run!.height += height
                        run!.w = max(run!.w, w)
                        run!.n += 1
                        run!.flow = flow
                    } else {
                        run = (s, b, height, w, 1, flow)
                    }
                    // A run holds at most `runLines`: an edit inside one keys only its run again.
                    if let rr = run, Int(rr.n) >= ParagraphConstants.runLines { close() }
                    j += 1
                    if cache == nil && b >= z { break }
                    continue
                }
                close()
            }
            let words = String(decoding: content[s..<textEnd], as: UTF8.self)
            let flow = forced ?? paragraphFlowOf(words) ?? lastFlow
            // Its bytes, as a Rust `str` hashes (not Swift's canonical-equivalence `String` hash).
            var h = Hasher()
            content.withUnsafeBytes { h.combine(bytes: UnsafeRawBufferPointer(rebasing: $0[s..<b])) }
            h.combine(styleKey)
            h.combine(flow == .rtl)
            h.combine("p")
            found.append(FoundParagraph(start: s, end: b, flow: flow, key: UInt64(bitPattern: Int64(h.finalize())), run: nil))
            j += 1
            if cache == nil && b >= z { break }
        }
        close()
        st.lineScan = record ?? cache
    }
}

extension TextSystem {
    /// Boxes covering content bytes `utf8Range` of a by-paragraph field (`TextFlow::range_boxes`):
    /// each paragraph boxes the bytes it holds as its own layout does, and a selected line break
    /// between paragraphs shows at the end of the line it ends, `paragraphNewlinePt` wide, on the
    /// side its paragraph ends (the left of a right-to-left one).
    internal func paragraphSelectionRects(in shaped: ShapedText, utf8Range: Range<Int>, pixelScale: Float) -> [SIMD4<Float>] {
        let ps = shaped.paragraphSpans
        let (a, b) = (utf8Range.lowerBound, utf8Range.upperBound)
        var out: [SIMD4<Float>] = []
        guard a < b else { return out }
        let ws = shaped.paragraphNewlinePt
        let invS = 1.0 / (pixelScale > 0 ? max(pixelScale, 0.0625) : 1.0)
        var k = max(0, partitionPoint(ps) { $0.start <= a } - 1)
        while k < ps.count, ps[k].start <= b {
            let p = ps[k]
            let first = out.count
            let lines = p.firstLine..<(p.firstLine + p.lineCount)
            // `Piece::clip`: the bytes it holds, when the range meets its words.
            if p.shaped, a < p.end, p.start < b {
                out.append(contentsOf: selectionRects(in: shaped, lines: lines, utf8Range: max(a, p.start)..<min(b, p.end), pixelScale: pixelScale))
            }
            if k + 1 < ps.count, a < ps[k + 1].start, p.end < b, let last = lines.last {
                #if canImport(CoreText) && canImport(CoreGraphics)
                let rec = shaped.lineStrings[last]
                #else
                let rec = shaped.portableLines[last]
                #endif
                let top = rec.originY
                let height = shaped.lineBoxHeightPt(last)
                // Its last line's start and end; a blank (or waiting) paragraph's caret edge.
                let start = rec.originX
                let end = p.shaped ? start + (last < shaped.lineAdvancesPx.count ? shaped.lineAdvancesPx[last].widthPx : 0) * invS : start
                let onLine = (first..<out.count).filter { abs(out[$0].y - top) < 0.01 }
                if p.rtl {
                    if let i = onLine.min(by: { out[$0].x < out[$1].x }) {
                        out[i].x -= ws
                        out[i].z += ws
                    } else {
                        out.append(SIMD4(start - ws, top, ws, height))
                    }
                } else {
                    if let i = onLine.max(by: { out[$0].x + out[$0].z < out[$1].x + out[$1].z }) {
                        out[i].z += ws
                    } else {
                        out.append(SIMD4(end, top, ws, height))
                    }
                }
            }
            k += 1
        }
        return out
    }
}
