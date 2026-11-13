import Foundation
#if canImport(simd)
import simd
#endif

/// Default `truncateFade` edge width, in ems (`el.rs:TRUNCATE_FADE_EM`).
public let TRUNCATE_FADE_EM: Float = 1.5

/// Compatibility helpers over `TextElision` (`Sources/Rune/Layout/TextElision.swift`) for `TextTruncation` and legacy callers.
public extension TextElision {
    /// Drawn byte index immediately after `"…"`.
    @inlinable
    var after: Int { afterEllipsis }

    /// Content byte index corresponding to drawn byte `i`.
    @inlinable
    func contentByte(forDrawn i: Int) -> Int {
        contentOffset(forDrawn: i)
    }

    /// Drawn byte index corresponding to content byte `i`.
    @inlinable
    func drawnByte(forContent i: Int, end: Bool) -> Int {
        drawnOffset(forContent: i, end: end)
    }

    /// Maps selection content range `a..<b` onto drawn UTF-8 bytes, covering `"…"` if the cut intersects.
    @inlinable
    func range(_ a: Int, _ b: Int) -> (Int, Int) {
        (drawnByte(forContent: a, end: false), drawnByte(forContent: b, end: true))
    }

    /// Maps span/link content bytes `a..<b` onto drawn UTF-8 bytes (`Elision::mark`).
    func mark(_ a: Int, _ b: Int, link: Bool) -> (Int, Int) {
        let r = mark(a, b, isLink: link)
        return (r.lowerBound, r.upperBound)
    }

    /// Drawn string UTF-8 length for a content string `len` bytes long.
    @inlinable
    func drawnLength(contentLength len: Int) -> Int {
        drawnLength(contentBytes: len)
    }

    /// Maps rich spans onto the elided string so `"…"` wears the adjacent span's styling when appropriate.
    func mapSpans(_ spans: [TextSpan], original: String) -> [TextSpan] {
        var out: [TextSpan] = []
        var cursor = 0
        var insertedEllipsis = false
        let utf8 = Array(original.utf8)

        for span in spans {
            let sLen = span.text.utf8.count
            let a = cursor
            let b = cursor + sLen
            cursor = b
            guard sLen > 0 else { continue }

            let beforePart: String
            if a < head {
                let lo = a
                let hi = min(b, head)
                beforePart = String(bytes: utf8[lo..<hi], encoding: .utf8) ?? ""
            } else {
                beforePart = ""
            }

            let ellipsisPart: String
            if !insertedEllipsis && a <= head && (a < head || b > tail) && b > head {
                ellipsisPart = Self.ellipsis
                insertedEllipsis = true
            } else {
                ellipsisPart = ""
            }

            let afterPart: String
            if b > tail {
                let lo = max(a, tail)
                let hi = b
                afterPart = String(bytes: utf8[lo..<hi], encoding: .utf8) ?? ""
            } else {
                afterPart = ""
            }

            let combined = beforePart + ellipsisPart + afterPart
            if !combined.isEmpty {
                var copy = span
                copy.text = combined
                out.append(copy)
            }
        }
        return out
    }
}

/// Bounded per-node elision result cache that reuses cuts, evicts superseded entries, and bypasses secure text (`commit/text_layout.rs:ElisionCache`).
public final class ElisionCache: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public var ownerId: UInt64
        public var text: String
        public var elide: TextElide
        public var maxWidthHalfPt: Int
        public var scale100: Int
        public var fontSize100: Int
        public var spanSignature: Int
        public var pillCount: Int
    }

    public struct Entry: Sendable {
        public var drawn: String
        public var spans: [TextSpan]?
        public var elision: TextElision
        public var wasCut: Bool
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var latestKeyByOwner: [UInt64: Key] = [:]
    public private(set) var hits: Int = 0
    public private(set) var misses: Int = 0

    public init() {}

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public func lookup(_ key: Key, secure: Bool) -> Entry? {
        guard !secure else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let hit = entries[key] {
            hits += 1
            return hit
        }
        return nil
    }

    public func record(_ key: Key, entry: Entry, secure: Bool) {
        guard !secure else { return }
        lock.lock()
        defer { lock.unlock() }
        misses += 1
        if let prevKey = latestKeyByOwner[key.ownerId], prevKey != key {
            entries.removeValue(forKey: prevKey)
        }
        if entries.count > 2048 {
            entries.removeAll(keepingCapacity: true)
            latestKeyByOwner.removeAll(keepingCapacity: true)
        }
        entries[key] = entry
        latestKeyByOwner[key.ownerId] = key
    }
}

/// Grapheme-cluster truncation and `truncateFade` edge calculation (`commit/text_layout.rs`, `paint/content.rs`).
public enum TextTruncation {
    /// Truncates `content` (or joined `spans`) to fit `maxWidth` points with `"…"` according to `elide`.
    public static func elide(
        text: String,
        spans: [TextSpan]?,
        pills: [PillChip],
        style: TextStyle,
        maxWidth: Float,
        pixelScale: Float,
        textSystem: TextSystem,
        cache: ElisionCache? = nil,
        ownerId: UInt64 = 0,
        secure: Bool = false
    ) -> (drawn: String, spans: [TextSpan]?, elision: TextElision, wasCut: Bool) {
        let fullText: String
        if let spans, !spans.isEmpty, text.isEmpty {
            fullText = spans.map(\.text).joined()
        } else {
            fullText = text
        }
        let cacheKey: ElisionCache.Key? = cache.map { _ in
            var hasher = Hasher()
            if let spans {
                for sp in spans {
                    hasher.combine(sp)
                }
            }
            return ElisionCache.Key(
                ownerId: ownerId,
                text: fullText,
                elide: style.elide,
                maxWidthHalfPt: Int((maxWidth * 2.0).rounded()),
                scale100: Int((pixelScale * 100.0).rounded()),
                fontSize100: Int((style.size * 100.0).rounded()),
                spanSignature: hasher.finalize(),
                pillCount: pills.count
            )
        }
        if let cache, let cacheKey, let cached = cache.lookup(cacheKey, secure: secure) {
            return (cached.drawn, cached.spans, cached.elision, cached.wasCut)
        }
        let fullLen = fullText.utf8.count

        var measureStyle = style
        measureStyle.wrap = .noWrap
        measureStyle.elide = .end
        measureStyle.graphemeElide = false

        let measureSpanText = { (s: String, sp: [TextSpan]?) -> Float in
            if let sp, !sp.isEmpty {
                return textSystem.shape(
                    text: s,
                    spans: sp,
                    pills: pills,
                    style: measureStyle,
                    maxWidth: nil,
                    pixelScale: pixelScale,
                    emitGlyphs: false
                ).size.x
            } else {
                return textSystem.measure(
                    s,
                    style: measureStyle,
                    maxWidth: nil,
                    pixelScale: pixelScale,
                    pills: pills
                ).x
            }
        }

        let recordResult = { (drawn: String, mappedSpans: [TextSpan]?, elision: TextElision, wasCut: Bool) -> (String, [TextSpan]?, TextElision, Bool) in
            if let cache, let cacheKey {
                cache.record(
                    cacheKey,
                    entry: ElisionCache.Entry(drawn: drawn, spans: mappedSpans, elision: elision, wasCut: wasCut),
                    secure: secure
                )
            }
            return (drawn, mappedSpans, elision, wasCut)
        }

        let fullW = measureSpanText(fullText, spans)
        if fullW <= maxWidth + 0.5 || fullText.isEmpty {
            return recordResult(fullText, spans, TextElision(head: fullLen, tail: fullLen), false)
        }

        // Collect grapheme cluster UTF-8 byte offsets
        var bounds: [Int] = []
        bounds.reserveCapacity(fullText.count + 1)
        var bytePos = 0
        bounds.append(0)
        for ch in fullText {
            bytePos += ch.utf8.count
            bounds.append(bytePos)
        }
        let n = bounds.count - 1
        let utf8 = Array(fullText.utf8)

        let isBlankGrapheme: (Int) -> Bool = { g in
            guard let s = String(bytes: utf8[bounds[g]..<bounds[g + 1]], encoding: .utf8) else { return false }
            return s.allSatisfy(\.isWhitespace)
        }

        let makeCut: (Int) -> TextElision = { k in
            var headCount: Int
            var tailCount: Int
            switch style.elide {
            case .end:
                headCount = k
                tailCount = 0
            case .middle:
                headCount = k - k / 2
                tailCount = k / 2
            case .head:
                headCount = 0
                tailCount = k
            }
            var tailIdx = n - tailCount
            while headCount > 0 && isBlankGrapheme(headCount - 1) { headCount -= 1 }
            while tailIdx < n && isBlankGrapheme(tailIdx) { tailIdx += 1 }
            return TextElision(head: bounds[headCount], tail: bounds[tailIdx])
        }

        let buildDrawn: (TextElision) -> (String, [TextSpan]?) = { e in
            let headStr = String(bytes: utf8[0..<e.head], encoding: .utf8) ?? ""
            let tailStr = String(bytes: utf8[e.tail..<fullLen], encoding: .utf8) ?? ""
            let s = headStr + TextElision.ellipsis + tailStr
            let mappedSpans: [TextSpan]?
            if let spans, !spans.isEmpty {
                var sp = e.mapSpans(spans, original: fullText)
                if sp.map(\.text).joined() != s {
                    // Fallback if no span covered the ellipsis boundary: rebuild spans preserving non-empty parts around plain ellipsis
                    var rebuilt: [TextSpan] = []
                    var cursor = 0
                    var ellipsisAdded = false
                    for item in spans {
                        let len = item.text.utf8.count
                        let a = cursor
                        let b = cursor + len
                        cursor = b
                        guard len > 0 else { continue }
                        if a < e.head {
                            var prefix = item
                            prefix.text = String(bytes: utf8[a..<min(b, e.head)], encoding: .utf8) ?? ""
                            if !prefix.text.isEmpty { rebuilt.append(prefix) }
                        }
                        if !ellipsisAdded && b >= e.head {
                            rebuilt.append(TextSpan(TextElision.ellipsis))
                            ellipsisAdded = true
                        }
                        if b > e.tail {
                            var suffix = item
                            suffix.text = String(bytes: utf8[max(a, e.tail)..<b], encoding: .utf8) ?? ""
                            if !suffix.text.isEmpty { rebuilt.append(suffix) }
                        }
                    }
                    if !ellipsisAdded {
                        rebuilt.append(TextSpan(TextElision.ellipsis))
                    }
                    sp = rebuilt
                }
                mappedSpans = sp
            } else {
                mappedSpans = nil
            }
            return (s, mappedSpans)
        }

        var lo = 0
        var hi = n
        var best: (k: Int, str: String, spans: [TextSpan]?, elision: TextElision)? = nil
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let e = makeCut(mid)
            let (s, sp) = buildDrawn(e)
            let w = measureSpanText(s, sp)
            if w <= maxWidth + 0.5 {
                lo = mid
                best = (mid, s, sp, e)
            } else {
                hi = mid - 1
            }
        }
        if let best, best.k == lo {
            return recordResult(best.str, best.spans, best.elision, true)
        }
        let e = makeCut(lo)
        let (s, sp) = buildDrawn(e)
        return recordResult(s, sp, e, true)
    }

    /// Computes text-only clip + fade mask for `El.truncateFade` (`paint/content.rs:611-672`).
    public static func fadeClip(
        style: TextStyle,
        shaped: ShapedText,
        contentRectPx: SIMD4<Float>,
        laidOutContentWidthPx: Float,
        scaleVec: Vec2,
        pixelScale: Float,
        parentClipPx: SIMD4<Float>
    ) -> (textClipPx: SIMD4<Float>, fadeLTRB: SIMD4<Float>, fadeBoundsPx: SIMD4<Float>, overflows: Bool) {
        let s = max(pixelScale, 0.5)
        let fullWPx = shaped.size.x * s
        let boundsW = max(0, contentRectPx.z - contentRectPx.x)
        let overflows = fullWPx > laidOutContentWidthPx + 0.5
            && fullWPx * scaleVec.x > boundsW + 0.5 * scaleVec.x
        let clipPx = SIMD4<Float>(
            max(parentClipPx.x, contentRectPx.x),
            max(parentClipPx.y, contentRectPx.y),
            min(parentClipPx.z, contentRectPx.z),
            min(parentClipPx.w, contentRectPx.w)
        )
        guard style.truncateFade && overflows else {
            return (clipPx, .zero, contentRectPx, false)
        }
        let fadeWidth = min(style.size * style.truncateFadeEm * scaleVec.x * s, boundsW)
        let firstLineText: String = {
            #if canImport(CoreText) && canImport(CoreGraphics)
            if let t = shaped.lineStrings.first?.text { return t }
            #endif
            return shaped.portableLines.first?.text ?? ""
        }()
        let isRTL: Bool
        if let forced = shaped.forcedDirection {
            isRTL = (forced == .rtl)
        } else {
            isRTL = TextSystem.isRTLParagraph(firstLineText)
        }
        let fadeOnLeft = (style.align == .trailing) != isRTL
        let fadeLTRB = fadeOnLeft
            ? SIMD4<Float>(fadeWidth, 0, 0, 0)
            : SIMD4<Float>(0, 0, fadeWidth, 0)
        return (clipPx, fadeLTRB, contentRectPx, true)
    }
}

public extension El {
    /// One unwrapped line that shrinks with its parent and truncates overflow with `"…"` at the end (`El::truncate`).
    func truncate() -> Self {
        guard handlers.editLens == nil else { return self }
        var c = self
        c.textStyle.wrap = .ellipsis
        c.textStyle.elide = .end
        c.textStyle.maxLines = 0
        c.textStyle.graphemeElide = true
        c.textStyle.truncateFade = false
        c.isTruncateFadeEnabled = false
        c.layout.flexShrink = 1.0
        c.layout.minWidth = .points(0)
        return c
    }
}
