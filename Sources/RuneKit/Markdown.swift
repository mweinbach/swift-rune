import Foundation
import Rune
import RuneMermaid

// MARK: - Bidirectional Text Direction (`rune_kit::markdown::bidi`)

/// Text direction detected for a Markdown paragraph or document block (`rune_kit::markdown::bidi`).
public enum MarkdownDirection: Sendable, Equatable, Hashable {
    case ltr
    case rtl

    public var textAlign: TextAlign {
        switch self {
        case .ltr: .leading
        case .rtl: .trailing
        }
    }
}

/// Bidirectional paragraph & document direction detection and embedding isolation (`rune_kit::markdown::bidi`).
public enum MarkdownBidi {
    private static let lri = "\u{2066}"
    private static let rli = "\u{2067}"
    private static let pdi = "\u{2069}"

    /// Detects the base paragraph direction from the first strong directional Unicode scalar.
    public static func direction(of text: String) -> MarkdownDirection {
        firstStrongDirection(in: text) ?? .ltr
    }

    /// Returns first strong direction in `text`, or `nil` if neutral.
    public static func firstStrongDirection(in text: String) -> MarkdownDirection? {
        for scalar in text.unicodeScalars {
            if isStrongRTL(scalar.value) { return .rtl }
            if isStrongLTR(scalar.value) { return .ltr }
        }
        return nil
    }

    /// Detects inline direction skipping isolated code spans (`\u{2066}...\u{2069}`) first,
    /// falling back to the full text only if non-code text is neutral.
    public static func inlineDirection(_ inline: MarkdownInline) -> MarkdownDirection? {
        let outside = stripIsolatedCode(inline.text)
        if let dir = firstStrongDirection(in: outside) {
            return dir
        }
        return firstStrongDirection(in: inline.text)
    }

    /// Detects the first strong direction across a sequence of `MarkdownDocBlock` values.
    public static func blocksDirection(_ blocks: [MarkdownDocBlock]) -> MarkdownDirection? {
        for b in blocks {
            switch b {
            case let .para(inl), let .heading(_, inl):
                if let d = inlineDirection(inl) { return d }
            case let .quote(inner):
                if let d = blocksDirection(inner) { return d }
            case let .list(_, items):
                for item in items {
                    if let d = blocksDirection(item) { return d }
                }
            case let .table(t):
                if let d = tableDirection(t) { return d }
            case let .image(_, alt, _):
                if let d = firstStrongDirection(in: alt) { return d }
            case .code, .diff, .mermaid, .rule:
                continue
            }
        }
        return nil
    }

    /// Detects table base direction from its header cells, then body cells.
    public static func tableDirection(_ table: MarkdownTableAST) -> MarkdownDirection? {
        for cell in table.head {
            if let d = inlineDirection(cell) { return d }
        }
        for row in table.rows {
            for cell in row {
                if let d = inlineDirection(cell) { return d }
            }
        }
        return nil
    }

    /// Isolates strong opposite-direction embedded prose runs outside isolated code spans.
    public static func isolateEmbeddedRuns(_ text: String, base: MarkdownDirection?) -> String {
        guard let base else { return text }
        var out = ""
        out.reserveCapacity(text.count + 8)
        let opposite = (base == .ltr) ? MarkdownDirection.rtl : .ltr
        var inIsolate = 0
        var run = ""

        func flushRun() {
            guard !run.isEmpty else { return }
            if firstStrongDirection(in: run) == opposite {
                out.append(opposite == .rtl ? rli : lri)
                out.append(run)
                out.append(pdi)
            } else {
                out.append(run)
            }
            run.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            if scalar.value == 0x2066 || scalar.value == 0x2067 {
                flushRun()
                inIsolate += 1
                out.unicodeScalars.append(scalar)
                continue
            }
            if scalar.value == 0x2069 && inIsolate > 0 {
                flushRun()
                inIsolate -= 1
                out.unicodeScalars.append(scalar)
                continue
            }
            if inIsolate > 0 {
                out.unicodeScalars.append(scalar)
                continue
            }
            if isStrongRTL(scalar.value) {
                if let d = firstStrongDirection(in: run), d != .rtl {
                    flushRun()
                }
                run.unicodeScalars.append(scalar)
            } else if isStrongLTR(scalar.value) {
                if let d = firstStrongDirection(in: run), d != .ltr {
                    flushRun()
                }
                run.unicodeScalars.append(scalar)
            } else {
                run.unicodeScalars.append(scalar)
            }
        }
        flushRun()
        return out
    }

    private static func stripIsolatedCode(_ text: String) -> String {
        var out = ""
        var depth = 0
        for s in text.unicodeScalars {
            if s.value == 0x2066 {
                depth += 1
                continue
            }
            if s.value == 0x2069 && depth > 0 {
                depth -= 1
                continue
            }
            if depth == 0 {
                out.unicodeScalars.append(s)
            }
        }
        return out
    }

    private static func isStrongRTL(_ v: UInt32) -> Bool {
        switch v {
        case 0x0590...0x05FF,
             0x0600...0x06FF,
             0x0700...0x074F,
             0x0750...0x077F,
             0x0780...0x07BF,
             0x07C0...0x07FF,
             0x0800...0x085F,
             0x08A0...0x08FF,
             0x200F,
             0xFB1D...0xFDFF,
             0xFE70...0xFEFF,
             0x10800...0x10FFF,
             0x1E800...0x1EFFF:
            true
        default:
            false
        }
    }

    private static func isStrongLTR(_ v: UInt32) -> Bool {
        if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) { return true }
        if (0x00C0...0x02AF).contains(v) { return true }
        if (0x0370...0x058F).contains(v) { return true }
        if (0x0900...0x1FFF).contains(v) { return true }
        if v == 0x200E { return true }
        if (0x2C00...0xD7AF).contains(v) { return true }
        if (0xF900...0xFAFF).contains(v) { return true }
        return false
    }
}

// MARK: - GFM Autolink Scanner (`rune_kit::markdown::autolink`)

/// GFM 6.9 URL, www-domain, angle-bracketed, and email autolink scanner (`rune_kit::markdown::autolink`).
public enum MarkdownAutolink {
    public struct Match: Sendable, Equatable {
        public var range: Range<String.Index>
        public var url: String
        public var display: String
        public var isEmail: Bool

        public init(range: Range<String.Index>, url: String, display: String, isEmail: Bool) {
            self.range = range
            self.url = url
            self.display = display
            self.isEmail = isEmail
        }
    }

    /// Scans `text` for bare `https://`, `http://`, `www.`, angle-bracketed `<url>`, and email autolinks.
    public static func scan(_ text: String) -> [Match] {
        var matches: [Match] = []
        var idx = text.startIndex

        while idx < text.endIndex {
            let rest = text[idx...]

            // Angle-bracketed autolink `<https://...>` or `<user@host.com>`
            if rest.hasPrefix("<"), let close = text[text.index(after: idx)...].firstIndex(of: ">") {
                let innerStart = text.index(after: idx)
                let inner = String(text[innerStart..<close])
                if !inner.isEmpty && !inner.contains(where: \.isWhitespace) {
                    let lowerInner = inner.lowercased()
                    if lowerInner.hasPrefix("https://") || lowerInner.hasPrefix("http://") {
                        let end = text.index(after: close)
                        matches.append(Match(range: idx..<end, url: inner, display: inner, isEmail: false))
                        idx = end
                        continue
                    } else if isLikelyEmail(inner) {
                        let end = text.index(after: close)
                        matches.append(Match(range: idx..<end, url: "mailto:\(inner)", display: inner, isEmail: true))
                        idx = end
                        continue
                    }
                }
            }

            // Bare URLs (`https://`, `http://`, `www.`)
            if let prefixInfo = matchSchemePrefix(rest) {
                let prevChar = idx > text.startIndex ? text[text.index(before: idx)] : nil
                if prevChar == nil || prevChar!.isWhitespace || "(*_~<[".contains(prevChar!) {
                    var scanIdx = text.index(idx, offsetBy: prefixInfo.prefixLen)
                    while scanIdx < text.endIndex && !text[scanIdx].isWhitespace && text[scanIdx] != "<" && text[scanIdx] != ">" {
                        scanIdx = text.index(after: scanIdx)
                    }
                    let trimmedEnd = trimTrailingURLPunctuation(text, start: idx, end: scanIdx, prefixLen: prefixInfo.prefixLen)
                    let display = String(text[idx..<trimmedEnd])
                    if display.count > prefixInfo.prefixLen {
                        let afterPrefix = String(display.dropFirst(prefixInfo.prefixLen))
                        if isValidDomain(afterPrefix, isWWW: prefixInfo.isWWW) {
                            let url = prefixInfo.isWWW ? "https://\(display)" : display
                            matches.append(Match(range: idx..<trimmedEnd, url: url, display: display, isEmail: false))
                            idx = trimmedEnd
                            continue
                        }
                    }
                }
            }

            // Bare email autolink `user@host.tld` (when not preceded by word char)
            let prevChar = idx > text.startIndex ? text[text.index(before: idx)] : nil
            if prevChar == nil || prevChar!.isWhitespace || "(*_~<[".contains(prevChar!),
               isEmailLocalStart(text[idx]) {
                var end = idx
                while end < text.endIndex && !text[end].isWhitespace && !"<>)[]\"'".contains(text[end]) {
                    end = text.index(after: end)
                }
                while end > idx && ".,!?:;".contains(text[text.index(before: end)]) {
                    end = text.index(before: end)
                }
                let candidate = String(text[idx..<end])
                if isLikelyEmail(candidate) {
                    matches.append(Match(range: idx..<end, url: "mailto:\(candidate)", display: candidate, isEmail: true))
                    idx = end
                    continue
                }
            }

            idx = text.index(after: idx)
        }
        return matches
    }

    private static func matchSchemePrefix(_ slice: Substring) -> (prefixLen: Int, isWWW: Bool)? {
        let lower = slice.prefix(8).lowercased()
        if lower.hasPrefix("https://") { return (8, false) }
        if lower.hasPrefix("http://") { return (7, false) }
        if lower.hasPrefix("www.") { return (4, true) }
        return nil
    }

    private static func trimTrailingURLPunctuation(
        _ text: String,
        start: String.Index,
        end initialEnd: String.Index,
        prefixLen: Int
    ) -> String.Index {
        var end = initialEnd
        while text.distance(from: start, to: end) > prefixLen {
            let before = text.index(before: end)
            let last = text[before]
            if "?!.,:*_~'\"".contains(last) {
                end = before
                continue
            }
            let slice = text[start..<end]
            let body = slice.dropFirst(prefixLen)
            if last == ")" {
                let opens = body.filter { $0 == "(" }.count
                let closes = body.filter { $0 == ")" }.count
                if closes > opens {
                    end = before
                    continue
                }
                break
            }
            if last == "]" {
                let opens = body.filter { $0 == "[" }.count
                let closes = body.filter { $0 == "]" }.count
                if closes > opens {
                    end = before
                    continue
                }
                break
            }
            if last == ";" {
                let withoutSemi = slice.dropLast()
                if let amp = withoutSemi.lastIndex(of: "&") {
                    let entity = withoutSemi[withoutSemi.index(after: amp)...]
                    if !entity.isEmpty && entity.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                        end = amp
                        continue
                    }
                }
                end = before
                continue
            }
            break
        }
        return end
    }

    static func isValidDomain(_ afterPrefix: String, isWWW: Bool) -> Bool {
        let hostEnd = afterPrefix.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterPrefix.endIndex
        var host = afterPrefix[..<hostEnd]
        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            if !port.isEmpty && port.allSatisfy({ $0.isASCII && $0.isNumber }) {
                host = host[..<colon]
            }
        }
        guard !host.isEmpty,
              let first = host.first, first.isASCII && (first.isLetter || first.isNumber),
              !host.hasSuffix("."), !host.hasSuffix("-"),
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }) else {
            return false
        }
        if isWWW && !host.contains(".") {
            return false
        }
        let segments = host.split(separator: ".", omittingEmptySubsequences: false)
        if segments.contains(where: \.isEmpty) { return false }
        if segments.count >= 2 && segments.suffix(2).contains(where: { $0.contains("_") }) {
            return false
        }
        return true
    }

    private static func isEmailLocalStart(_ ch: Character) -> Bool {
        ch.isASCII && (ch.isLetter || ch.isNumber)
    }

    private static func isLikelyEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0]
        let domain = parts[1]
        guard !local.isEmpty, !domain.isEmpty, domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else {
            return false
        }
        let localOK = local.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) }
        let domainOK = domain.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }
        return localOK && domainOK
    }
}

// MARK: - Inline, SpanMap & AST Types (`rune_kit::markdown`)

/// Inline styling tag (`rune_kit::markdown::Style`).
public enum MarkdownInlineStyle: Sendable, Equatable, Hashable {
    case code
    case codePad
    case strong
    case em
    case strike
    case link
}

/// Styled UTF-8 byte span inside `MarkdownInline.text`.
public struct MarkdownStyleSpan: Sendable, Equatable, Hashable {
    public var start: Int
    public var end: Int
    public var style: MarkdownInlineStyle

    public init(start: Int, end: Int, style: MarkdownInlineStyle) {
        self.start = start
        self.end = end
        self.style = style
    }
}

/// Link destination attached to a UTF-8 byte range inside `MarkdownInline.text`.
public struct MarkdownLinkSpan: Sendable, Equatable, Hashable {
    public var start: Int
    public var end: Int
    public var url: String

    public init(start: Int, end: Int, url: String) {
        self.start = start
        self.end = end
        self.url = url
    }
}

/// Rich inline text with formatting spans and resolved link URLs (`rune_kit::markdown::Inline`).
public struct MarkdownInline: Sendable, Equatable, Hashable {
    public static let pad = "\u{202f}\u{202f}"
    public static let openPad = "\u{202f}\u{202f}\u{2066}"
    public static let closePad = "\u{2069}\u{202f}\u{202f}"

    public var text: String
    public var spans: [MarkdownStyleSpan]
    public var links: [MarkdownLinkSpan]

    public init(text: String = "", spans: [MarkdownStyleSpan] = [], links: [MarkdownLinkSpan] = []) {
        self.text = text
        self.spans = spans
        self.links = links
    }

    public static func unpadded(_ text: String) -> String {
        text.replacingOccurrences(of: openPad, with: "")
            .replacingOccurrences(of: closePad, with: "")
    }

    public var unpaddedText: String {
        Self.unpadded(text)
    }
}

/// Monotonic source-byte -> rendered-byte mapping (`rune_kit::markdown::find::SpanMap`).
public struct MarkdownSpanMap: Sendable, Equatable, Hashable {
    public struct Segment: Sendable, Equatable, Hashable {
        public var src: Range<Int>
        public var out: Range<Int>

        public init(src: Range<Int>, out: Range<Int>) {
            self.src = src
            self.out = out
        }
    }

    public var segments: [Segment]

    public init(_ segments: [Segment] = []) {
        self.segments = segments
    }

    public mutating func push(src: Range<Int>, out: Range<Int>) {
        guard !out.isEmpty else { return }
        if let last = segments.last,
           last.src.upperBound == src.lowerBound,
           last.out.upperBound == out.lowerBound,
           last.src.count == last.out.count,
           src.count == out.count {
            segments[segments.count - 1].src = last.src.lowerBound..<src.upperBound
            segments[segments.count - 1].out = last.out.lowerBound..<out.upperBound
        } else {
            segments.append(Segment(src: src, out: out))
        }
    }

    public mutating func truncateOut(_ limit: Int) {
        segments.removeAll { seg in seg.out.lowerBound >= limit }
        for i in segments.indices {
            if segments[i].out.upperBound > limit {
                let oldOutLen = max(1, segments[i].out.count)
                let newOutLen = max(0, limit - segments[i].out.lowerBound)
                let newSrcEnd = if segments[i].src.count == oldOutLen {
                    segments[i].src.lowerBound + newOutLen
                } else {
                    segments[i].src.lowerBound + (segments[i].src.count * newOutLen) / oldOutLen
                }
                segments[i].out = segments[i].out.lowerBound..<limit
                segments[i].src = segments[i].src.lowerBound..<max(segments[i].src.lowerBound, newSrcEnd)
            }
        }
        segments.removeAll { $0.out.isEmpty }
    }

    public mutating func shiftSrc(_ offset: Int) {
        guard offset != 0 else { return }
        for i in segments.indices {
            segments[i].src = (segments[i].src.lowerBound + offset)..<(segments[i].src.upperBound + offset)
        }
    }

    public func shiftedSrc(_ offset: Int) -> MarkdownSpanMap {
        var copy = self
        copy.shiftSrc(offset)
        return copy
    }

    /// Maps source UTF-8 byte ranges into UTF-8 byte ranges inside `outText`.
    public func mapRanges(_ queries: [Range<Int>], in outText: String) -> [Range<Int>] {
        guard !queries.isEmpty, !segments.isEmpty, !outText.isEmpty else { return [] }
        let qs = MarkdownFind.normalizeRanges(queries)
        guard !qs.isEmpty else { return [] }
        if qs[qs.count - 1].upperBound <= segments[0].src.lowerBound ||
            segments[segments.count - 1].src.upperBound <= qs[0].lowerBound {
            return []
        }

        var mapped: [Range<Int>] = []
        var idx = 0
        for q in qs {
            while idx < segments.count && segments[idx].src.upperBound <= q.lowerBound {
                idx += 1
            }
            if idx >= segments.count { break }
            var j = idx
            while j < segments.count && segments[j].src.lowerBound < q.upperBound {
                let seg = segments[j]
                if let r = Self.mapSegment(query: q, src: seg.src, out: seg.out, outText: outText) {
                    if let last = mapped.last,
                       last.upperBound >= r.lowerBound || Self.isPadOnly(utf8Slice(outText, range: last.upperBound..<r.lowerBound)) {
                        mapped[mapped.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
                    } else {
                        mapped.append(r)
                    }
                }
                if seg.src.upperBound <= q.upperBound {
                    idx = j + 1
                } else {
                    idx = j
                }
                j += 1
            }
        }
        return mapped
    }

    private static func mapSegment(query: Range<Int>, src: Range<Int>, out: Range<Int>, outText: String) -> Range<Int>? {
        let s0 = max(query.lowerBound, src.lowerBound)
        let s1 = min(query.upperBound, src.upperBound)
        guard s0 < s1, !src.isEmpty, !out.isEmpty else { return nil }
        let (raw0, raw1): (Int, Int)
        if src.count == out.count {
            raw0 = out.lowerBound + (s0 - src.lowerBound)
            raw1 = out.lowerBound + (s1 - src.lowerBound)
        } else {
            let a = s0 <= src.lowerBound ? out.lowerBound : out.lowerBound + ((s0 - src.lowerBound) * out.count) / src.count
            let b = s1 >= src.upperBound ? out.upperBound : max(a + 1, out.lowerBound + ((s1 - src.lowerBound) * out.count + src.count - 1) / src.count)
            raw0 = a
            raw1 = b
        }
        let maxLen = outText.utf8.count
        let clamped0 = floorUTF8Boundary(outText, byte: min(maxLen, max(out.lowerBound, min(out.upperBound, raw0))))
        let clamped1 = ceilUTF8Boundary(outText, byte: min(maxLen, max(out.lowerBound, min(out.upperBound, raw1))))
        return clamped0 < clamped1 ? (clamped0..<clamped1) : nil
    }

    private static func isPadOnly(_ slice: String?) -> Bool {
        guard let slice, !slice.isEmpty else { return false }
        return slice.unicodeScalars.allSatisfy { $0.value == 0x202F || $0.value == 0x2066 || $0.value == 0x2069 }
    }
}

/// Source-to-output mapping tree matching `MarkdownDocBlock` (`rune_kit::markdown::find::BlockMap`).
public indirect enum MarkdownBlockMap: Sendable, Equatable, Hashable {
    case none
    case inline(MarkdownSpanMap)
    case code(MarkdownSpanMap)
    case quote([MarkdownBlockMap])
    case list([[MarkdownBlockMap]])
    case table(head: [MarkdownSpanMap], rows: [[MarkdownSpanMap]])

    public func shiftedSrc(_ offset: Int) -> MarkdownBlockMap {
        guard offset != 0 else { return self }
        switch self {
        case .none: return .none
        case .inline(let m): return .inline(m.shiftedSrc(offset))
        case .code(let m): return .code(m.shiftedSrc(offset))
        case .quote(let inner): return .quote(inner.map { $0.shiftedSrc(offset) })
        case .list(let items): return .list(items.map { $0.map { $0.shiftedSrc(offset) } })
        case let .table(head, rows):
            return .table(head: head.map { $0.shiftedSrc(offset) }, rows: rows.map { $0.map { $0.shiftedSrc(offset) } })
        }
    }
}

/// Table column alignment (`rune_kit::markdown::Align`).
public enum MarkdownTableAlign: Sendable, Equatable, Hashable {
    case start
    case center
    case end

    public var textAlign: TextAlign {
        switch self {
        case .start: .leading
        case .center: .center
        case .end: .trailing
        }
    }
}

/// Parsed GFM table (`rune_kit::markdown::Table`).
public struct MarkdownTableAST: Sendable, Equatable, Hashable {
    public var align: [MarkdownTableAlign]
    public var head: [MarkdownInline]
    public var rows: [[MarkdownInline]]
    public var open: Bool

    public init(align: [MarkdownTableAlign] = [], head: [MarkdownInline] = [], rows: [[MarkdownInline]] = [], open: Bool = false) {
        self.align = align
        self.head = head
        self.rows = rows
        self.open = open
    }
}

/// Metadata tracked per code/mermaid block during parsing (`rune_kit::markdown::Source`).
public struct MarkdownCodeSource: Sendable, Equatable, Hashable {
    public var language: String?
    public var open: Bool
    public var colouredBytes: Int
    public var length: Int

    public init(language: String?, open: Bool, colouredBytes: Int, length: Int) {
        self.language = language
        self.open = open
        self.colouredBytes = colouredBytes
        self.length = length
    }
}

/// Safe cut point for incremental document caching (`rune_kit::markdown::cache::Cut`).
public struct MarkdownCut: Sendable, Equatable, Hashable {
    public var at: Int
    public var blocks: Int
    public var sources: Int
    public var tasks: Int

    public init(at: Int, blocks: Int, sources: Int, tasks: Int) {
        self.at = at
        self.blocks = blocks
        self.sources = sources
        self.tasks = tasks
    }
}

/// Task list checkbox state + source UTF-8 offset of `[` (`(checked, markerOffset)`).
public struct MarkdownTaskState: Sendable, Equatable, Hashable {
    public var checked: Bool
    public var markerOffset: Int

    public init(checked: Bool, markerOffset: Int) {
        self.checked = checked
        self.markerOffset = markerOffset
    }
}

/// Full CommonMark + GFM nested AST (`rune_kit::markdown::Block`).
public indirect enum MarkdownDocBlock: Sendable, Equatable, Hashable {
    case para(MarkdownInline)
    case heading(level: Int, MarkdownInline)
    case code(String)
    case diff(String)
    case mermaid(String)
    case list(start: UInt64?, items: [[MarkdownDocBlock]])
    case quote([MarkdownDocBlock])
    case table(MarkdownTableAST)
    case image(src: String, alt: String, title: String)
    case rule
}

/// Complete parse output including blocks, fence metadata, tasks, incremental cuts, block byte starts, and span maps.
public struct MarkdownParsedDoc: Sendable, Equatable {
    public var blocks: [MarkdownDocBlock]
    public var sources: [MarkdownCodeSource]
    public var tasks: [MarkdownTaskState?]
    public var cuts: [MarkdownCut]
    public var blockStarts: [Int]
    public var maps: [MarkdownBlockMap]

    public init(
        blocks: [MarkdownDocBlock] = [],
        sources: [MarkdownCodeSource] = [],
        tasks: [MarkdownTaskState?] = [],
        cuts: [MarkdownCut] = [],
        blockStarts: [Int] = [],
        maps: [MarkdownBlockMap] = []
    ) {
        self.blocks = blocks
        self.sources = sources
        self.tasks = tasks
        self.cuts = cuts
        self.blockStarts = blockStarts
        self.maps = maps
    }
}

// MARK: - Legacy Compatibility AST Types (preserved for existing callers & tests)

/// Parsed task list item (`- [ ]` / `- [x]`) for legacy `MarkdownBlock.taskList`.
public struct MarkdownTaskItem: Sendable, Equatable {
    public var checked: Bool
    public var text: String

    public init(checked: Bool, text: String) {
        self.checked = checked
        self.text = text
    }
}

/// Parsed Markdown AST block (existing Swift-friendly enum kept compatible alongside `MarkdownDocBlock`).
public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case codeBlock(language: String?, code: String)
    case blockquote(String)
    case unorderedList([String])
    case orderedList([String])
    case taskList([MarkdownTaskItem])
    case table(headers: [String], rows: [[String]])
    case footnoteDefinition(id: String, text: String)
    case thematicBreak
}

// MARK: - Search / Highlight / Case (`rune_kit::markdown::find`)

/// Case sensitivity for `Markdown.find` (`rune_kit::markdown::Case`).
public enum MarkdownCase: Sendable, Equatable, Hashable {
    case sensitive
    case insensitive
}

/// Paint overrides for highlighted search / citation ranges (`rune_kit::markdown::Highlight`).
public struct MarkdownHighlight: Sendable, Equatable, Hashable {
    public var bg: Color?
    public var fg: Color?
    public var ringColor: Color?
    public var ringWidth: Float?
    public var current: Bool
    public var key: String?

    public init(
        bg: Color? = nil,
        fg: Color? = nil,
        ringColor: Color? = nil,
        ringWidth: Float? = nil,
        current: Bool = false,
        key: String? = nil
    ) {
        self.bg = bg
        self.fg = fg
        self.ringColor = ringColor
        self.ringWidth = ringWidth
        self.current = current
        self.key = key
    }

    public static func match() -> MarkdownHighlight { MarkdownHighlight() }
    public func current(_ isCurrent: Bool) -> MarkdownHighlight { var c = self; c.current = isCurrent; return c }
    public func bg(_ color: Color) -> MarkdownHighlight { var c = self; c.bg = color; return c }
    public func fg(_ color: Color) -> MarkdownHighlight { var c = self; c.fg = color; return c }
    public func ring(_ color: Color, _ width: Float = 1.0) -> MarkdownHighlight {
        var c = self
        c.ringColor = color
        c.ringWidth = max(0, width)
        return c
    }
    public func key(_ k: String) -> MarkdownHighlight { var c = self; c.key = k; return c }
}

/// Rendered-text search mapping visible characters back to UTF-8 byte ranges in Markdown source (`rune_kit::markdown::find`).
public enum MarkdownFind {
    private struct Seg {
        var src: Range<Int>
        var out: Range<Int>
        var linear: Bool
    }

    public static func normalizeRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let nonEmpty = ranges.filter { $0.lowerBound < $0.upperBound }
        guard !nonEmpty.isEmpty else { return [] }
        if nonEmpty.count > 1 && zip(nonEmpty, nonEmpty.dropFirst()).allSatisfy({ $0.upperBound < $1.lowerBound }) {
            return nonEmpty
        }
        let sorted = nonEmpty.sorted { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) }
        var merged: [Range<Int>] = []
        for r in sorted {
            if let last = merged.last, last.upperBound >= r.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// Searches rendered text across `doc` and returns disjoint merged source UTF-8 byte ranges for each match.
    public static func findAll(
        in src: String,
        doc: MarkdownParsedDoc,
        query: String,
        caseSensitivity: MarkdownCase = .insensitive
    ) -> [[Range<Int>]] {
        guard !query.isEmpty, !src.isEmpty else { return [] }
        var out: [[Range<Int>]] = []
        findInBlocks(src: src, blocks: doc.blocks, maps: doc.maps, query: query, caseSensitivity: caseSensitivity, out: &out)
        return out
    }

    /// Flattens each match into its encompassing `start..<end` UTF-8 range in `src`.
    public static func findBounds(
        in src: String,
        doc: MarkdownParsedDoc,
        query: String,
        caseSensitivity: MarkdownCase = .insensitive
    ) -> [Range<Int>] {
        findAll(in: src, doc: doc, query: query, caseSensitivity: caseSensitivity).compactMap { segs in
            guard let lo = segs.map(\.lowerBound).min(), let hi = segs.map(\.upperBound).max(), lo < hi else { return nil }
            return lo..<hi
        }
    }

    private static func findInBlocks(
        src: String,
        blocks: [MarkdownDocBlock],
        maps: [MarkdownBlockMap],
        query: String,
        caseSensitivity: MarkdownCase,
        out: inout [[Range<Int>]]
    ) {
        for (i, b) in blocks.enumerated() {
            let map = i < maps.count ? maps[i] : .none
            switch (b, map) {
            case let (.para(inl), .inline(m)), let (.heading(_, inl), .inline(m)):
                findInText(src: src, text: inl.text, map: m, query: query, caseSensitivity: caseSensitivity, out: &out)
            case let (.image(_, alt, _), .inline(m)):
                findInText(src: src, text: alt, map: m, query: query, caseSensitivity: caseSensitivity, out: &out)
            case let (.code(code), .code(m)), let (.diff(code), .code(m)):
                findInText(src: src, text: code, map: m, query: query, caseSensitivity: caseSensitivity, out: &out)
            case let (.mermaid(code), .code(m)):
                if KitMermaid.supported(code) { continue }
                findInText(src: src, text: code, map: m, query: query, caseSensitivity: caseSensitivity, out: &out)
            case let (.table(t), .table(head, rows)):
                for (j, cell) in t.head.enumerated() where j < head.count {
                    findInText(src: src, text: cell.text, map: head[j], query: query, caseSensitivity: caseSensitivity, out: &out)
                }
                for (ri, row) in t.rows.enumerated() where ri < rows.count {
                    let rmaps = rows[ri]
                    for (j, cell) in row.enumerated() where j < rmaps.count {
                        findInText(src: src, text: cell.text, map: rmaps[j], query: query, caseSensitivity: caseSensitivity, out: &out)
                    }
                }
            case let (.list(_, items), .list(itemMaps)):
                for (idx, item) in items.enumerated() {
                    let imap = idx < itemMaps.count ? itemMaps[idx] : []
                    findInBlocks(src: src, blocks: item, maps: imap, query: query, caseSensitivity: caseSensitivity, out: &out)
                }
            case let (.quote(inner), .quote(innerMaps)):
                findInBlocks(src: src, blocks: inner, maps: innerMaps, query: query, caseSensitivity: caseSensitivity, out: &out)
            default:
                continue
            }
        }
    }

    private static func findInText(
        src: String,
        text: String,
        map: MarkdownSpanMap,
        query: String,
        caseSensitivity: MarkdownCase,
        out: inout [[Range<Int>]]
    ) {
        guard !text.isEmpty, !map.segments.isEmpty else { return }

        let contiguous = map.segments[0].out.lowerBound == 0 &&
            map.segments[map.segments.count - 1].out.upperBound == text.utf8.count &&
            zip(map.segments, map.segments.dropFirst()).allSatisfy { $0.out.upperBound == $1.out.lowerBound }

        var vis: String
        var segs: [Seg] = []
        segs.reserveCapacity(map.segments.count)

        if contiguous {
            vis = text
            for s in map.segments {
                let linear = isLinearSeg(src: src, vis: text, sSeg: s.src, oSeg: s.out)
                segs.append(Seg(src: s.src, out: s.out, linear: linear))
            }
        } else {
            vis = ""
            for s in map.segments {
                if let slice = utf8Slice(text, range: s.out), !slice.isEmpty {
                    let start = vis.utf8.count
                    vis.append(slice)
                    let newOut = start..<vis.utf8.count
                    let linear = isLinearSeg(src: src, vis: vis, sSeg: s.src, oSeg: newOut)
                    segs.append(Seg(src: s.src, out: newOut, linear: linear))
                }
            }
        }
        guard !vis.isEmpty else { return }

        var segIdx = 0
        switch caseSensitivity {
        case .sensitive:
            var searchStart = vis.startIndex
            while let r = vis.range(of: query, range: searchStart..<vis.endIndex) {
                let b0 = vis.utf8.distance(from: vis.startIndex, to: r.lowerBound)
                let b1 = vis.utf8.distance(from: vis.startIndex, to: r.upperBound)
                let ranges = mapVisRange(src: src, segs: segs, segIdx: &segIdx, vRange: b0..<b1)
                if !ranges.isEmpty { out.append(ranges) }
                searchStart = r.upperBound
            }
        case .insensitive:
            let foldedQ = foldQuery(query)
            guard !foldedQ.isEmpty else { return }
            // Case-fold scalar by scalar keeping byte index mapping (handles sigma 'ς'/'σ' + multi-char lowercase)
            var folded = ""
            var fToV: [Int] = []
            var curVByte = 0
            for ch in vis {
                let chBytes = String(ch).utf8.count
                if ch == "ς" {
                    fToV.append(curVByte)
                    folded.append("σ")
                } else {
                    var first = true
                    for fc in String(ch).lowercased() {
                        let fcBytes = String(fc).utf8.count
                        fToV.append(first ? curVByte : Int.max)
                        first = false
                        folded.append(fc)
                        for _ in 1..<fcBytes { fToV.append(Int.max) }
                    }
                }
                while fToV.count < folded.utf8.count { fToV.append(Int.max) }
                curVByte += chBytes
            }
            fToV.append(vis.utf8.count)

            let qBytes = Array(foldedQ.utf8)
            let fBytes = Array(folded.utf8)
            guard !qBytes.isEmpty, fBytes.count >= qBytes.count else { return }
            var i = 0
            while i <= fBytes.count - qBytes.count {
                if fBytes[i..<(i + qBytes.count)].elementsEqual(qBytes) {
                    let v0 = fToV[i]
                    let v1 = fToV[i + qBytes.count]
                    if v0 != Int.max && v1 != Int.max && v0 < v1 {
                        let ranges = mapVisRange(src: src, segs: segs, segIdx: &segIdx, vRange: v0..<v1)
                        if !ranges.isEmpty { out.append(ranges) }
                        i += qBytes.count
                        continue
                    }
                }
                i += 1
            }
        }
    }

    private static func foldQuery(_ q: String) -> String {
        var out = ""
        for ch in q {
            if ch == "ς" {
                out.append("σ")
            } else {
                out.append(String(ch).lowercased())
            }
        }
        return out
    }

    private static func isLinearSeg(src: String, vis: String, sSeg: Range<Int>, oSeg: Range<Int>) -> Bool {
        guard sSeg.count == oSeg.count else { return false }
        let sSlice = utf8Slice(src, range: sSeg)
        let oSlice = utf8Slice(vis, range: oSeg)
        return sSlice == oSlice || !(sSlice?.hasPrefix("&") ?? false)
    }

    private static func mapVisRange(src: String, segs: [Seg], segIdx: inout Int, vRange: Range<Int>) -> [Range<Int>] {
        while segIdx < segs.count && segs[segIdx].out.upperBound <= vRange.lowerBound {
            segIdx += 1
        }
        var ranges: [Range<Int>] = []
        var j = segIdx
        let srcLen = src.utf8.count
        while j < segs.count && segs[j].out.lowerBound < vRange.upperBound {
            let seg = segs[j]
            let o0 = max(vRange.lowerBound, seg.out.lowerBound)
            let o1 = min(vRange.upperBound, seg.out.upperBound)
            if o0 < o1 {
                let rel0 = o0 - seg.out.lowerBound
                let rel1 = o1 - seg.out.lowerBound
                var s0: Int
                var s1: Int
                if seg.linear && isUTF8Boundary(src, seg.src.lowerBound + rel0) && isUTF8Boundary(src, seg.src.lowerBound + rel1) {
                    s0 = seg.src.lowerBound + rel0
                    s1 = seg.src.lowerBound + rel1
                } else {
                    s0 = seg.src.lowerBound
                    s1 = seg.src.upperBound
                }
                s0 = floorUTF8Boundary(src, byte: min(srcLen, max(seg.src.lowerBound, min(seg.src.upperBound, s0))))
                s1 = ceilUTF8Boundary(src, byte: min(srcLen, max(seg.src.lowerBound, min(seg.src.upperBound, s1))))
                if s0 < s1 {
                    if let last = ranges.last, last.upperBound == s0 {
                        ranges[ranges.count - 1] = last.lowerBound..<s1
                    } else if ranges.last.map({ $0.upperBound < s0 }) ?? true {
                        ranges.append(s0..<s1)
                    }
                }
            }
            segIdx = (seg.out.upperBound <= vRange.upperBound) ? (j + 1) : j
            j += 1
        }
        return ranges
    }
}

// MARK: - Plain Text Formatter (`rune_kit::markdown::plain`)

/// Renders a `MarkdownParsedDoc` to clean copyable plain text (`rune_kit::markdown::plain`).
public enum MarkdownPlain {
    public static func render(
        blocks: [MarkdownDocBlock],
        tasks: [MarkdownTaskState?] = [],
        nextTask: inout Int
    ) -> String {
        var out = ""
        writeBlocks(blocks, into: &out, tasks: tasks, nextTask: &nextTask, indentCols: 0, quotePrefix: false)
        return out
    }

    public static func render(_ doc: MarkdownParsedDoc) -> String {
        var next = 0
        return render(blocks: doc.blocks, tasks: doc.tasks, nextTask: &next)
    }

    private static func writeBlocks(
        _ blocks: [MarkdownDocBlock],
        into out: inout String,
        tasks: [MarkdownTaskState?],
        nextTask: inout Int,
        indentCols: Int,
        quotePrefix: Bool
    ) {
        for (i, b) in blocks.enumerated() {
            if i > 0 { out.append("\n\n") }
            switch b {
            case let .para(inl), let .heading(_, inl):
                let clean = MarkdownInline.unpadded(inl.text)
                if quotePrefix {
                    out.append(clean.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n"))
                } else {
                    out.append(clean)
                }
            case let .code(s), let .diff(s), let .mermaid(s):
                out.append(s)
            case let .image(_, alt, _):
                out.append(alt)
            case .rule:
                out.append("---")
            case let .quote(inner):
                writeBlocks(inner, into: &out, tasks: tasks, nextTask: &nextTask, indentCols: indentCols, quotePrefix: true)
            case let .list(start, items):
                for (k, item) in items.enumerated() {
                    if k > 0 { out.append("\n") }
                    let task = nextTask < tasks.count ? tasks[nextTask] : nil
                    nextTask += 1
                    let marker: String
                    if let task {
                        marker = task.checked ? "- [x] " : "- [ ] "
                    } else if let s = start {
                        marker = "\(s + UInt64(k)). "
                    } else {
                        marker = "- "
                    }
                    let pad = String(repeating: " ", count: indentCols)
                    out.append(pad)
                    out.append(marker)
                    var itemOut = ""
                    writeBlocks(item, into: &itemOut, tasks: tasks, nextTask: &nextTask, indentCols: indentCols + marker.count, quotePrefix: quotePrefix)
                    // Strip extra indent on the very first line (marker already wrote it)
                    let trimFirst = String(repeating: " ", count: indentCols + marker.count)
                    if itemOut.hasPrefix(trimFirst) {
                        out.append(String(itemOut.dropFirst(trimFirst.count)))
                    } else {
                        out.append(itemOut)
                    }
                }
            case let .table(t):
                let h = t.head.map { MarkdownInline.unpadded($0.text) }.joined(separator: "\t")
                out.append(h)
                for row in t.rows {
                    out.append("\n")
                    out.append(row.map { MarkdownInline.unpadded($0.text) }.joined(separator: "\t"))
                }
            }
        }
    }
}

// MARK: - Cache (`rune_kit::markdown::cache`)

/// Thread-safe LRU cache for parsed Markdown documents with incremental cut reuse (`rune_kit::markdown::cache`).
public final class MarkdownDocCache: @unchecked Sendable {
    public static let shared = MarkdownDocCache(capacity: 24)

    private struct Entry {
        var source: String
        var autolink: Bool
        var doc: MarkdownParsedDoc
        var stamp: UInt64
    }

    private let lock = NSLock()
    private let capacity: Int
    private var entries: [Entry] = []
    private var clock: UInt64 = 0

    public init(capacity: Int = 24) {
        self.capacity = max(1, capacity)
    }

    public func docCached(_ source: String, autolink: Bool = true) -> MarkdownParsedDoc {
        lock.lock()
        clock += 1
        let now = clock
        if let idx = entries.firstIndex(where: { $0.autolink == autolink && $0.source == source }) {
            entries[idx].stamp = now
            let hit = entries[idx].doc
            lock.unlock()
            return hit
        }

        // Incremental prefix cut reuse when streaming appends onto an existing cached prefix
        var incremental: MarkdownParsedDoc?
        if let bestIdx = entries.indices
            .filter({ entries[$0].autolink == autolink && source.utf8.count > entries[$0].source.utf8.count && source.hasPrefix(entries[$0].source) })
            .max(by: { entries[$0].source.utf8.count < entries[$1].source.utf8.count }) {
            let base = entries[bestIdx].doc
            incremental = Self.incrementalExtend(base: base, source: source, autolink: autolink)
        }
        lock.unlock()

        let parsed = incremental ?? MarkdownParser.parseDocument(source, autolink: autolink)

        lock.lock()
        clock += 1
        let putStamp = clock
        if entries.count >= capacity, let evict = entries.indices.min(by: { entries[$0].stamp < entries[$1].stamp }) {
            entries.remove(at: evict)
        }
        entries.append(Entry(source: source, autolink: autolink, doc: parsed, stamp: putStamp))
        lock.unlock()
        return parsed
    }

    private static func incrementalExtend(base: MarkdownParsedDoc, source: String, autolink: Bool) -> MarkdownParsedDoc? {
        // Keep everything strictly before the last safe cut (avoid merging into the cut block)
        guard base.cuts.count >= 2 else { return nil }
        let cutIdx = base.cuts.count - 2
        let cut = base.cuts[cutIdx]
        guard cut.at > 0, cut.at < source.utf8.count, let tailStr = utf8Slice(source, range: cut.at..<source.utf8.count) else {
            return nil
        }
        let tail = MarkdownParser.parseDocument(tailStr, autolink: autolink)
        var out = MarkdownParsedDoc()
        out.blocks = Array(base.blocks.prefix(cut.blocks)) + tail.blocks
        out.sources = Array(base.sources.prefix(cut.sources)) + tail.sources
        let shiftedTailTasks = tail.tasks.map { task in
            task.map { MarkdownTaskState(checked: $0.checked, markerOffset: $0.markerOffset + cut.at) }
        }
        out.tasks = Array(base.tasks.prefix(cut.tasks)) + shiftedTailTasks
        out.blockStarts = Array(base.blockStarts.prefix(cut.blocks)) + tail.blockStarts.map { $0 + cut.at }
        out.maps = Array(base.maps.prefix(cut.blocks)) + tail.maps.map { $0.shiftedSrc(cut.at) }
        out.cuts = Array(base.cuts.prefix(cutIdx + 1)) + tail.cuts.map {
            MarkdownCut(at: $0.at + cut.at, blocks: $0.blocks + cut.blocks, sources: $0.sources + cut.sources, tasks: $0.tasks + cut.tasks)
        }
        return out
    }
}

// MARK: - Streaming Stabilizer & Tail Stream (`rune_kit::markdown::stream`)

/// Streaming-friendly Markdown accumulator that repairs unclosed fences and inline spans (`rune_kit::markdown::stream`).
public struct MarkdownStream: Sendable, Equatable {
    public private(set) var raw: String = ""

    public init(_ initial: String = "") {
        self.raw = initial
    }

    public mutating func append(_ chunk: String) {
        raw.append(chunk)
    }

    public mutating func reset(_ text: String = "") {
        raw = text
    }

    /// Returns a normalized snapshot safe to parse mid-stream (closing open fences and trailing inline markers).
    public var stabilizedSource: String {
        Self.stabilize(raw)
    }

    /// Parses the stabilized streaming Markdown into legacy `MarkdownBlock` values.
    public func parseBlocks() -> [MarkdownBlock] {
        MarkdownParser.parse(stabilizedSource)
    }

    /// Parses the stabilized streaming Markdown into full `MarkdownParsedDoc`.
    public func parseDocument(autolink: Bool = true) -> MarkdownParsedDoc {
        MarkdownParser.parseDocument(stabilizedSource, autolink: autolink)
    }

    /// Repairs unclosed fenced code blocks and unclosed inline delimiters at the tail of an incomplete Markdown stream.
    public static func stabilize(_ source: String) -> String {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var openFence: String? = nil

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = openFence {
                if trimmed.hasPrefix(fence) && trimmed.dropFirst(fence.count).allSatisfy({ $0 == fence.first || $0.isWhitespace }) {
                    openFence = nil
                }
            } else if trimmed.hasPrefix("```") {
                let n = trimmed.prefix(while: { $0 == "`" }).count
                openFence = String(repeating: "`", count: n)
            } else if trimmed.hasPrefix("~~~") {
                let n = trimmed.prefix(while: { $0 == "~" }).count
                openFence = String(repeating: "~", count: n)
            }
        }

        var out = source
        if let fence = openFence {
            if !out.hasSuffix("\n") {
                out.append("\n")
            }
            out.append(fence)
            return out
        }

        if let patch = MarkdownTailStream.closeTail(source) {
            let prefixEnd = source.utf8.index(source.utf8.startIndex, offsetBy: min(patch.cut, source.utf8.count))
            return String(source[..<prefixEnd]) + patch.closers
        }
        return out
    }
}

/// Tail stabilization & marker holding matching `rune_kit::markdown::stream`.
public struct MarkdownTailStream: Sendable, Equatable {
    public struct Patch: Sendable, Equatable {
        public var cut: Int
        public var closers: String
        public var markers: [Range<Int>]
        public var inCode: Bool
    }

    private struct OpenDelimiter {
        var at: Int
        var ch: UInt8
        var count: Int
    }

    public private(set) var source: String = ""
    public var autolink: Bool

    public init(autolink: Bool = true) {
        self.autolink = autolink
    }

    public mutating func push(_ chunk: String) {
        source.append(chunk)
    }

    public mutating func reset(_ text: String = "") {
        source = text
    }

    /// Stabilized source string closing incomplete trailing inline markers/spans cleanly.
    public var stabilizedSource: String {
        MarkdownStream.stabilize(source)
    }

    public func document(streaming: Bool = true) -> MarkdownParsedDoc {
        if !streaming {
            return MarkdownDocCache.shared.docCached(source, autolink: autolink)
        }
        let s = stabilizedSource
        var doc = MarkdownDocCache.shared.docCached(s, autolink: autolink)
        if let patch = Self.closeTail(source), patch.inCode {
            Self.dropClosingPad(in: &doc)
        }
        return doc
    }

    /// Computes tail stabilization patch on the last line/paragraph of `source`.
    public static func closeTail(_ source: String) -> Patch? {
        // Operate on the last paragraph (after last blank line) so completed earlier blocks never shift.
        let bytes = Array(source.utf8)
        var base = 0
        var idx = bytes.count
        while idx > 1 {
            if bytes[idx - 1] == 0x0A {
                // Check previous line emptiness
                var j = idx - 2
                while j > 0 && (bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0D) {
                    j -= 1
                }
                if bytes[j] == 0x0A || (j == 0 && (bytes[0] == 0x20 || bytes[0] == 0x09 || bytes[0] == 0x0D || bytes[0] == 0x0A)) {
                    base = idx
                    break
                }
            }
            idx -= 1
        }
        let runBytes = Array(bytes[base...])
        guard let runStr = String(bytes: runBytes, encoding: .utf8) else { return nil }
        return scanRun(runStr, runBytes: runBytes, base: base)
    }

    private static func scanRun(_ run: String, runBytes b: [UInt8], base: Int) -> Patch? {
        var stack: [OpenDelimiter] = []
        var code: (at: Int, n: Int)?
        var cut = b.count
        var i = 0

        func charBefore(_ offset: Int) -> Character? {
            guard offset > 0, let prefix = String(bytes: b[..<offset], encoding: .utf8) else { return nil }
            return prefix.last
        }
        func charAt(_ offset: Int) -> Character? {
            guard offset < b.count, let suffix = String(bytes: b[offset...], encoding: .utf8) else { return nil }
            return suffix.first
        }

        while i < b.count {
            switch b[i] {
            case 0x5C: // '\\'
                i += 2
            case 0x60: // '`'
                let n = runLen(b, i)
                if let closeIdx = closingTicks(b, from: i + n, n: n) {
                    i = closeIdx + n
                } else {
                    code = (i, n)
                    i = b.count
                }
            case 0x21 where i + 1 == b.count && isWordStart(charBefore(i)): // '!'
                cut = i
                i = b.count
            case 0x5B where isWordStart(charBefore(i)): // '['
                let at = (i > 0 && b[i - 1] == 0x21) ? (i - 1) : i
                stack.append(OpenDelimiter(at: at, ch: 0x5B, count: i + 1 - at))
                i += 1
            case 0x5D: // ']'
                guard let p = stack.lastIndex(where: { $0.ch == 0x5B }) else {
                    i += 1
                    continue
                }
                if i + 1 >= b.count {
                    cut = i
                    i = b.count
                } else if b[i + 1] == 0x28 { // '('
                    let afterParen = b[(i + 2)...]
                    if let relClose = afterParen.firstIndex(of: 0x29) {
                        stack.removeSubrange(p...)
                        i = relClose + 1
                    } else {
                        stack.removeSubrange((p + 1)...)
                        stack[p].ch = 0x28
                        i = b.count
                    }
                } else {
                    stack.remove(at: p)
                    i += 1
                }
            case 0x2A, 0x5F, 0x7E: // '*', '_', '~'
                let ch = b[i]
                let n = runLen(b, i)
                let before = charBefore(i)
                guard let after = charAt(i + n) else {
                    let mayClose = !(before?.isWhitespace ?? true) && stack.contains(where: { $0.ch == ch })
                    if isWordStart(before) || mayClose {
                        cut = i
                    }
                    i = b.count
                    break
                }
                if ch == 0x7E && n != 2 {
                    i += n
                    continue
                }
                let (opens, closes) = flanks(ch, before: before, after: after)
                var left = n
                if closes {
                    while left > 0 {
                        guard let p = stack.lastIndex(where: { $0.ch == ch }) else { break }
                        let used = min(stack[p].count, left)
                        stack[p].count -= used
                        left -= used
                        if stack[p].count == 0 {
                            stack.removeSubrange(p...)
                        } else {
                            stack.removeSubrange((p + 1)...)
                        }
                    }
                }
                if left > 0 && opens {
                    stack.append(OpenDelimiter(at: i + n - left, ch: ch, count: left))
                }
                i += n
            default:
                i += 1
            }
        }

        if let (at, n) = code {
            var trimmed = cut
            while trimmed > at + n && (b[trimmed - 1] == 0x60 || b[trimmed - 1] == 0x20 || b[trimmed - 1] == 0x09) {
                trimmed -= 1
            }
            if trimmed <= at + n {
                cut = at
                code = nil
            } else {
                cut = trimmed
            }
        } else {
            while let last = stack.last {
                let start = min(cut, last.at + last.count)
                let slice = String(bytes: b[start..<cut], encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if slice.isEmpty || (last.ch == 0x5B && last.count == 1 && (slice == "x" || slice == "X")) {
                    cut = last.at
                    stack.removeLast()
                } else {
                    break
                }
            }
        }

        var closers = ""
        var markers: [Range<Int>] = []
        if let (at, n) = code {
            if at + n < cut && b[at + n] == 0x20 {
                closers.append(" ")
            }
            closers.append(String(repeating: "`", count: n))
            markers.append((base + at)..<(base + at + n))
        }
        for o in stack.reversed() {
            switch o.ch {
            case 0x5B:
                closers.append("](#)")
            case 0x28:
                let tailSlice = b[min(cut, o.at)..<cut]
                let hasEmptyDest = tailSlice.lastIndex(of: 0x28).map { parenIdx in
                    tailSlice[(parenIdx + 1)...].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
                } ?? false
                closers.append(hasEmptyDest ? "#)" : ")")
            default:
                closers.append(String(repeating: Character(UnicodeScalar(o.ch)), count: o.count))
            }
            markers.append((base + o.at)..<(base + o.at + o.count))
        }
        guard cut < b.count || !closers.isEmpty else { return nil }
        return Patch(cut: base + cut, closers: closers, markers: markers, inCode: code != nil)
    }

    private static func runLen(_ b: [UInt8], _ i: Int) -> Int {
        var j = i
        while j < b.count && b[j] == b[i] { j += 1 }
        return j - i
    }

    private static func closingTicks(_ b: [UInt8], from start: Int, n: Int) -> Int? {
        var i = start
        while i < b.count {
            if b[i] != 0x60 {
                i += 1
                continue
            }
            let len = runLen(b, i)
            if len == n { return i }
            i += len
        }
        return nil
    }

    private static func isSpace(_ c: Character?) -> Bool {
        c?.isWhitespace ?? true
    }

    private static func isPunct(_ c: Character?) -> Bool {
        guard let c else { return false }
        return !c.isLetter && !c.isNumber && !c.isWhitespace
    }

    private static func isWordStart(_ before: Character?) -> Bool {
        isSpace(before) || isPunct(before)
    }

    private static func flanks(_ ch: UInt8, before: Character?, after: Character) -> (opens: Bool, closes: Bool) {
        let left = !isSpace(after) && (!isPunct(after) || isWordStart(before))
        let right = !isSpace(before) && (!isPunct(before) || isWordStart(after))
        if ch == 0x5F { // '_'
            return (left && (!right || isPunct(before)), right && (!left || isPunct(after)))
        }
        return (left && isWordStart(before), right)
    }

    private static func dropClosingPad(in doc: inout MarkdownParsedDoc) {
        guard !doc.blocks.isEmpty, !doc.maps.isEmpty else { return }
        func stripPad(_ inl: inout MarkdownInline, _ map: inout MarkdownSpanMap) {
            let len = inl.text.utf8.count
            let closeLen = MarkdownInline.closePad.utf8.count
            guard let k = inl.spans.firstIndex(where: { $0.style == .codePad && $0.end == len && $0.start + closeLen == len }) else { return }
            inl.spans.remove(at: k)
            let cut = len - closeLen
            inl.text = utf8Slice(inl.text, range: 0..<cut) ?? inl.text
            inl.spans = inl.spans.compactMap { s in
                let hi = min(s.end, cut)
                return s.start < hi ? MarkdownStyleSpan(start: s.start, end: hi, style: s.style) : nil
            }
            inl.links = inl.links.compactMap { l in
                let hi = min(l.end, cut)
                return l.start < hi ? MarkdownLinkSpan(start: l.start, end: hi, url: l.url) : nil
            }
            map.truncateOut(cut)
        }
        func walk(_ block: inout MarkdownDocBlock, _ map: inout MarkdownBlockMap) {
            switch (block, map) {
            case (var .para(inl), var .inline(m)):
                stripPad(&inl, &m)
                block = .para(inl)
                map = .inline(m)
            case (let .heading(lvl, inlVal), var .inline(m)):
                var inl = inlVal
                stripPad(&inl, &m)
                block = .heading(level: lvl, inl)
                map = .inline(m)
            case (var .quote(inner), var .quote(im)):
                if !inner.isEmpty && !im.isEmpty {
                    walk(&inner[inner.count - 1], &im[im.count - 1])
                    block = .quote(inner)
                    map = .quote(im)
                }
            case (let .list(start, itemsVal), var .list(lm)):
                var items = itemsVal
                if let li = items.indices.last, let bi = items[li].indices.last,
                   li < lm.count, bi < lm[li].count {
                    walk(&items[li][bi], &lm[li][bi])
                    block = .list(start: start, items: items)
                    map = .list(lm)
                }
            case (var .table(t), .table(var head, var rows)):
                if let ri = t.rows.indices.last, let ci = t.rows[ri].indices.last,
                   ri < rows.count, ci < rows[ri].count {
                    stripPad(&t.rows[ri][ci], &rows[ri][ci])
                } else if let hi = t.head.indices.last, hi < head.count {
                    stripPad(&t.head[hi], &head[hi])
                }
                block = .table(t)
                map = .table(head: head, rows: rows)
            default:
                break
            }
        }
        let last = doc.blocks.count - 1
        if last < doc.maps.count {
            walk(&doc.blocks[last], &doc.maps[last])
        }
    }
}

// MARK: - Parser (`rune_kit::markdown::parser` + `interrupt`)

/// Streaming-friendly CommonMark + GFM Table + Task List + Footnote + Syntax Highlighting parser (`rune_kit::markdown::parser`).
public enum MarkdownParser {
    /// Structured inline token (legacy API upgraded to retain `url`!).
    public struct InlineToken: Sendable, Equatable {
        public var text: String
        public var url: String?
        public var isCode: Bool
        public var isBold: Bool
        public var isItalic: Bool
        public var isStrikethrough: Bool
        public var isLink: Bool

        public init(
            text: String,
            url: String? = nil,
            isCode: Bool = false,
            isBold: Bool = false,
            isItalic: Bool = false,
            isStrikethrough: Bool = false,
            isLink: Bool = false
        ) {
            self.text = text
            self.url = url
            self.isCode = isCode
            self.isBold = isBold
            self.isItalic = isItalic
            self.isStrikethrough = isStrikethrough
            self.isLink = isLink
        }
    }

    // MARK: Full Upstream AST Parse (`parseDocument` / `parseAST`)

    public static func parseAST(_ source: String, autolink: Bool = true) -> [MarkdownDocBlock] {
        parseDocument(source, autolink: autolink).blocks
    }

    public static func parseDocument(_ source: String, autolink: Bool = true) -> MarkdownParsedDoc {
        let defs = collectLinkDefinitions(in: source)
        var parser = DocumentParser(source: source, baseOffset: 0, definitions: defs, autolink: autolink)
        return parser.parseRoot()
    }

    private struct LinkDefinition {
        var url: String
        var title: String
    }

    private struct LineSlice {
        var contentRange: Range<Int> // excludes trailing \r\n / \n
        var lineEnd: Int             // includes trailing newline if any
    }

    private static func splitLineSlices(_ src: String) -> [LineSlice] {
        let bytes = Array(src.utf8)
        var out: [LineSlice] = []
        var start = 0
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A { // '\n'
                let contentEnd = (i > start && bytes[i - 1] == 0x0D) ? (i - 1) : i
                out.append(LineSlice(contentRange: start..<contentEnd, lineEnd: i + 1))
                start = i + 1
            }
            i += 1
        }
        if start < bytes.count {
            let contentEnd = (bytes[bytes.count - 1] == 0x0D) ? (bytes.count - 1) : bytes.count
            out.append(LineSlice(contentRange: start..<contentEnd, lineEnd: bytes.count))
        }
        return out
    }

    private static func collectLinkDefinitions(in source: String) -> [String: LinkDefinition] {
        var defs: [String: LinkDefinition] = [:]
        let lines = splitLineSlices(source)
        for line in lines {
            guard let raw = utf8Slice(source, range: line.contentRange) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["),
                  let closeBracket = trimmed.dropFirst().firstIndex(of: "]") else { continue }
            let id = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeBracket])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let afterBracket = trimmed[trimmed.index(after: closeBracket)...]
            guard afterBracket.hasPrefix(":"), !id.isEmpty else { continue }
            var destPart = afterBracket.dropFirst().trimmingCharacters(in: .whitespaces)
            var url = ""
            var title = ""
            if destPart.hasPrefix("<"), let gt = destPart.dropFirst().firstIndex(of: ">") {
                url = String(destPart[destPart.index(after: destPart.startIndex)..<gt])
                destPart = destPart[destPart.index(after: gt)...].trimmingCharacters(in: .whitespaces)
            } else {
                let parts = destPart.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                url = parts.first.map(String.init) ?? ""
                destPart = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            }
            if (destPart.hasPrefix("\"") && destPart.hasSuffix("\"") && destPart.count >= 2) ||
                (destPart.hasPrefix("'") && destPart.hasSuffix("'") && destPart.count >= 2) {
                title = String(destPart.dropFirst().dropLast())
            }
            if !url.isEmpty && defs[id] == nil {
                defs[id] = LinkDefinition(url: url, title: title)
            }
        }
        return defs
    }

    private struct DocumentParser {
        let source: String
        let baseOffset: Int
        let definitions: [String: LinkDefinition]
        let autolink: Bool

        mutating func parseRoot() -> MarkdownParsedDoc {
            let lines = splitLineSlices(source)
            var doc = MarkdownParsedDoc()
            parseBlockSequence(
                lines: lines,
                into: &doc.blocks,
                maps: &doc.maps,
                sources: &doc.sources,
                tasks: &doc.tasks,
                blockStarts: &doc.blockStarts,
                cuts: &doc.cuts,
                trackRootCuts: true
            )
            // Stream-tolerant pending table at end of root document
            if let last = doc.blocks.last, case .para = last,
               let startByte = doc.blockStarts.last,
               let tailSrc = utf8Slice(source, range: startByte..<source.utf8.count),
               let (table, tableMap) = parsePendingTable(tailSrc, baseOffset: baseOffset + startByte, autolink: autolink, definitions: definitions) {
                doc.blocks[doc.blocks.count - 1] = .table(table)
                doc.maps[doc.maps.count - 1] = tableMap
            }
            return doc
        }

        private mutating func parseBlockSequence(
            lines: [LineSlice],
            into blocks: inout [MarkdownDocBlock],
            maps: inout [MarkdownBlockMap],
            sources: inout [MarkdownCodeSource],
            tasks: inout [MarkdownTaskState?],
            blockStarts: inout [Int],
            cuts: inout [MarkdownCut],
            trackRootCuts: Bool
        ) {
            var i = 0
            while i < lines.count {
                let raw = utf8Slice(source, range: lines[i].contentRange) ?? ""
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    i += 1
                    continue
                }

                // Skip standalone reference link definitions `[id]: url`
                if isReferenceDefinitionLine(trimmed) {
                    i += 1
                    continue
                }

                let blockStartByte = lines[i].contentRange.lowerBound
                if trackRootCuts {
                    cuts.append(MarkdownCut(
                        at: blockStartByte,
                        blocks: blocks.count,
                        sources: sources.count,
                        tasks: tasks.count
                    ))
                }

                // 1. Fenced code block (``` or ~~~)
                if let fence = parseFenceHeader(raw) {
                    var codeRanges: [Range<Int>] = []
                    var j = i + 1
                    var closed = false
                    while j < lines.count {
                        let lineRaw = utf8Slice(source, range: lines[j].contentRange) ?? ""
                        if isFenceCloser(lineRaw, fenceChar: fence.char, minLen: fence.count) {
                            closed = true
                            j += 1
                            break
                        }
                        codeRanges.append(lines[j].contentRange)
                        j += 1
                    }
                    let (codeText, codeMap) = buildCodeTextAndMap(source: source, baseOffset: baseOffset, lineRanges: codeRanges, closed: closed, hasTrailingNewline: j <= lines.count && !closed && lines.last.map { $0.lineEnd > $0.contentRange.upperBound } == true)
                    let langLower = fence.lang?.lowercased()
                    if langLower == "diff" || langLower == "patch" {
                        appendBlock(.diff(codeText), map: .code(codeMap), start: blockStartByte, to: &blocks, maps: &maps, starts: &blockStarts)
                    } else if langLower == "mermaid" {
                        let coloured = closed ? codeText.utf8.count : lastNewlineCut(codeText)
                        sources.append(MarkdownCodeSource(language: fence.lang, open: !closed, colouredBytes: coloured, length: codeText.utf8.count))
                        appendBlock(.mermaid(codeText), map: .code(codeMap), start: blockStartByte, to: &blocks, maps: &maps, starts: &blockStarts)
                    } else {
                        let coloured = closed ? codeText.utf8.count : lastNewlineCut(codeText)
                        sources.append(MarkdownCodeSource(language: fence.lang, open: !closed, colouredBytes: coloured, length: codeText.utf8.count))
                        appendBlock(.code(codeText), map: .code(codeMap), start: blockStartByte, to: &blocks, maps: &maps, starts: &blockStarts)
                    }
                    i = j
                    continue
                }

                // 2. Thematic break (---, ***, ___) — must precede heading/list check
                if isHorizontalRule(trimmed) {
                    appendBlock(.rule, map: .none, start: blockStartByte, to: &blocks, maps: &maps, starts: &blockStarts)
                    i += 1
                    continue
                }

                // 3. ATX Heading (# ... ######)
                if let (level, headingContentRange) = parseATXHeading(source: source, lineRange: lines[i].contentRange) {
                    let headingStr = utf8Slice(source, range: headingContentRange) ?? ""
                    let (inl, spanMap, _) = parseInline(
                        headingStr,
                        baseOffset: baseOffset + headingContentRange.lowerBound,
                        autolink: autolink,
                        definitions: definitions,
                        trimTrailingCodePad: true
                    )
                    appendBlock(.heading(level: level, inl), map: .inline(spanMap), start: blockStartByte, to: &blocks, maps: &maps, starts: &blockStarts)
                    i += 1
                    continue
                }

                // 4. Indented code block (4 spaces or leading tab)
                if isIndentedCodeLine(raw) {
                    var ranges: [Range<Int>] = []
                    var j = i
                    while j < lines.count {
                        let rStr = utf8Slice(source, range: lines[j].contentRange) ?? ""
                        if rStr.trimmingCharacters(in: .whitespaces).isEmpty {
                            // Include blank lines only if another indented line follows
                            var look = j + 1
                            while look < lines.count && (utf8Slice(source, range: lines[look].contentRange) ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                                look += 1
                            }
                            if look < lines.count && isIndentedCodeLine(utf8Slice(source, range: lines[look].contentRange) ?? "") {
                                ranges.append(lines[j].contentRange)
                                j += 1
                                continue
                            }
                            break
                        }
                        if isIndentedCodeLine(rStr) {
                            let drop = stripCodeIndentBytes(rStr)
                            ranges.append((lines[j].contentRange.lowerBound + drop)..<lines[j].contentRange.upperBound)
                            j += 1
                        } else {
                            break
                        }
                    }
                    let (codeText, codeMap) = buildCodeTextAndMap(source: source, baseOffset: baseOffset, lineRanges: ranges, closed: true, hasTrailingNewline: false)
                    sources.append(MarkdownCodeSource(language: nil, open: false, colouredBytes: codeText.utf8.count, length: codeText.utf8.count))
                    appendBlock(.code(codeText), map: .code(codeMap), start: blockStartByte, to: &blocks, maps: &maps, starts: &blockStarts)
                    i = j
                    continue
                }

                // 5. Blockquote (> ...)
                if trimmed.hasPrefix(">") {
                    var innerLines: [LineSlice] = []
                    var j = i
                    while j < lines.count {
                        let lStr = utf8Slice(source, range: lines[j].contentRange) ?? ""
                        let lTrim = lStr.drop(while: { $0 == " " })
                        if lTrim.hasPrefix(">") {
                            let leadSpaces = lStr.utf8.count - String(lTrim).utf8.count
                            var dropBytes = leadSpaces + 1 // '>'
                            if lTrim.dropFirst().first == " " { dropBytes += 1 }
                            let cStart = min(lines[j].contentRange.upperBound, lines[j].contentRange.lowerBound + dropBytes)
                            innerLines.append(LineSlice(contentRange: cStart..<lines[j].contentRange.upperBound, lineEnd: lines[j].lineEnd))
                            j += 1
                        } else if lStr.trimmingCharacters(in: .whitespaces).isEmpty {
                            break
                        } else if !innerLines.isEmpty && !isFenceHeaderBool(lStr) && !isHorizontalRule(lStr.trimmingCharacters(in: .whitespaces)) && parseATXHeading(source: source, lineRange: lines[j].contentRange) == nil && parseListMarker(lStr) == nil {
                            // Lazy continuation line
                            innerLines.append(lines[j])
                            j += 1
                        } else {
                            break
                        }
                    }
                    var qBlocks: [MarkdownDocBlock] = []
                    var qMaps: [MarkdownBlockMap] = []
                    var qStarts: [Int] = []
                    var qCuts: [MarkdownCut] = []
                    parseBlockSequence(lines: innerLines, into: &qBlocks, maps: &qMaps, sources: &sources, tasks: &tasks, blockStarts: &qStarts, cuts: &qCuts, trackRootCuts: false)
                    appendBlock(.quote(qBlocks), map: .quote(qMaps), start: blockStartByte, to: &blocks, maps: &maps, starts: &blockStarts)
                    i = j
                    continue
                }

                // 6. List (- / * / + / 1. / 1))
                if let firstMarker = parseListMarker(raw) {
                    let isOrdered = firstMarker.ordered
                    let startNum = firstMarker.start
                    var itemSlices: [[LineSlice]] = []
                    var itemTasks: [MarkdownTaskState?] = []
                    var j = i

                    while j < lines.count {
                        let lStr = utf8Slice(source, range: lines[j].contentRange) ?? ""
                        if lStr.trimmingCharacters(in: .whitespaces).isEmpty {
                            // Consume blank lines between items only if the next non-blank line continues the same list
                            var peek = j + 1
                            while peek < lines.count && (utf8Slice(source, range: lines[peek].contentRange) ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                                peek += 1
                            }
                            if peek < lines.count {
                                let peekStr = utf8Slice(source, range: lines[peek].contentRange) ?? ""
                                if let pm = parseListMarker(peekStr), pm.ordered == isOrdered, pm.indent <= firstMarker.contentIndent {
                                    j = peek
                                    continue
                                }
                                if indentWidth(peekStr) >= firstMarker.contentIndent {
                                    itemSlices[itemSlices.count - 1].append(lines[j])
                                    j += 1
                                    continue
                                }
                            }
                            break
                        }

                        if let m = parseListMarker(lStr), m.ordered == isOrdered, m.indent < firstMarker.contentIndent {
                            // New item in this list
                            var cStart = lines[j].contentRange.lowerBound + m.contentOffsetBytes
                            var taskState: MarkdownTaskState?
                            if let rest = utf8Slice(source, range: cStart..<lines[j].contentRange.upperBound),
                               let task = parseTaskCheckboxPrefix(rest) {
                                taskState = MarkdownTaskState(checked: task.checked, markerOffset: baseOffset + cStart)
                                cStart += task.dropBytes
                            }
                            itemTasks.append(taskState)
                            itemSlices.append([LineSlice(contentRange: min(cStart, lines[j].contentRange.upperBound)..<lines[j].contentRange.upperBound, lineEnd: lines[j].lineEnd)])
                            j += 1
                        } else if !itemSlices.isEmpty {
                            let ind = indentWidth(lStr)
                            if ind >= firstMarker.contentIndent {
                                let stripped = stripLeadingIndent(lStr, targetCols: firstMarker.contentIndent)
                                let cStart = lines[j].contentRange.lowerBound + stripped
                                itemSlices[itemSlices.count - 1].append(LineSlice(contentRange: min(cStart, lines[j].contentRange.upperBound)..<lines[j].contentRange.upperBound, lineEnd: lines[j].lineEnd))
                                j += 1
                            } else if parseListMarker(lStr) == nil && !isHorizontalRule(lStr.trimmingCharacters(in: .whitespaces)) && parseATXHeading(source: source, lineRange: lines[j].contentRange) == nil && !isFenceHeaderBool(lStr) && !lStr.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                                // Lazy paragraph continuation inside list item
                                itemSlices[itemSlices.count - 1].append(lines[j])
                                j += 1
                            } else {
                                break
                            }
                        } else {
                            break
                        }
                    }

                    var renderedItems: [[MarkdownDocBlock]] = []
                    var itemMaps: [[MarkdownBlockMap]] = []
                    for (idx, subLines) in itemSlices.enumerated() {
                        tasks.append(itemTasks[idx])
                        var ib: [MarkdownDocBlock] = []
                        var im: [MarkdownBlockMap] = []
                        var isrcStarts: [Int] = []
                        var icuts: [MarkdownCut] = []
                        parseBlockSequence(lines: subLines, into: &ib, maps: &im, sources: &sources, tasks: &tasks, blockStarts: &isrcStarts, cuts: &icuts, trackRootCuts: false)
                        renderedItems.append(ib)
                        itemMaps.append(im)
                    }
                    appendBlock(.list(start: isOrdered ? startNum : nil, items: renderedItems), map: .list(itemMaps), start: blockStartByte, to: &blocks, maps: &maps, starts: &blockStarts)
                    i = j
                    continue
                }

                // 7. GFM Table (header + delimiter row)
                if i + 1 < lines.count,
                   let nextRaw = utf8Slice(source, range: lines[i + 1].contentRange),
                   let aligns = parseTableDelimiterAlignments(nextRaw),
                   raw.contains("|") {
                    let headCells = splitTableRow(raw, baseOffset: baseOffset + lines[i].contentRange.lowerBound)
                    if headCells.count == aligns.count || (!headCells.isEmpty && raw.trimmingCharacters(in: .whitespaces).hasPrefix("|")) {
                        var headInlines: [MarkdownInline] = []
                        var headMaps: [MarkdownSpanMap] = []
                        for cell in headCells {
                            let (inl, sm, _) = parseInline(cell.text, baseOffset: cell.offset, autolink: autolink, definitions: definitions, trimTrailingCodePad: true)
                            headInlines.append(inl)
                            headMaps.append(sm)
                        }
                        var bodyRows: [[MarkdownInline]] = []
                        var rowMaps: [[MarkdownSpanMap]] = []
                        var j = i + 2
                        var lastOpen = false
                        while j < lines.count {
                            let rowRaw = utf8Slice(source, range: lines[j].contentRange) ?? ""
                            let rTrim = rowRaw.trimmingCharacters(in: .whitespaces)
                            if rTrim.isEmpty || !rTrim.contains("|") || isFenceHeaderBool(rowRaw) || parseATXHeading(source: source, lineRange: lines[j].contentRange) != nil {
                                break
                            }
                            lastOpen = (lines[j].lineEnd == lines[j].contentRange.upperBound)
                            let cells = splitTableRow(rowRaw, baseOffset: baseOffset + lines[j].contentRange.lowerBound)
                            var rInl: [MarkdownInline] = []
                            var rMap: [MarkdownSpanMap] = []
                            for cell in cells {
                                let (inl, sm, _) = parseInline(cell.text, baseOffset: cell.offset, autolink: autolink, definitions: definitions, trimTrailingCodePad: true)
                                rInl.append(inl)
                                rMap.append(sm)
                            }
                            bodyRows.append(rInl)
                            rowMaps.append(rMap)
                            j += 1
                        }
                        let table = MarkdownTableAST(align: aligns, head: headInlines, rows: bodyRows, open: lastOpen)
                        appendBlock(.table(table), map: .table(head: headMaps, rows: rowMaps), start: blockStartByte, to: &blocks, maps: &maps, starts: &blockStarts)
                        i = j
                        continue
                    }
                }

                // 8. Setext Heading (para line followed by === or ---)
                if i + 1 < lines.count {
                    let nextTrim = (utf8Slice(source, range: lines[i + 1].contentRange) ?? "").trimmingCharacters(in: .whitespaces)
                    if !nextTrim.isEmpty && (nextTrim.allSatisfy { $0 == "=" } || nextTrim.allSatisfy { $0 == "-" }) {
                        let lvl = nextTrim.first == "=" ? 1 : 2
                        let pStr = raw.trimmingCharacters(in: .whitespaces)
                        let leadOff = raw.utf8.count - String(raw.drop(while: \.isWhitespace)).utf8.count
                        let (inl, sm, _) = parseInline(pStr, baseOffset: baseOffset + lines[i].contentRange.lowerBound + leadOff, autolink: autolink, definitions: definitions, trimTrailingCodePad: true)
                        appendBlock(.heading(level: lvl, inl), map: .inline(sm), start: blockStartByte, to: &blocks, maps: &maps, starts: &blockStarts)
                        i += 2
                        continue
                    }
                }

                // 9. Paragraph (joining soft lines, breaking on container starts or interrupt-numbered continuations, lifting standalone images on root)
                var paraRanges: [Range<Int>] = [lines[i].contentRange]
                var j = i + 1
                while j < lines.count {
                    let nextRaw = utf8Slice(source, range: lines[j].contentRange) ?? ""
                    let nextTrim = nextRaw.trimmingCharacters(in: .whitespaces)
                    if nextTrim.isEmpty ||
                        isReferenceDefinitionLine(nextTrim) ||
                        isFenceHeaderBool(nextRaw) ||
                        isHorizontalRule(nextTrim) ||
                        parseATXHeading(source: source, lineRange: lines[j].contentRange) != nil ||
                        nextTrim.hasPrefix(">") {
                        break
                    }
                    // Interrupt on unordered list or numbered item unless paragraph already has unclosed **/__/~~/` across lines.
                    if let lm = parseListMarker(nextRaw) {
                        let itemTail = utf8Slice(source, range: (lines[j].contentRange.lowerBound + lm.contentOffsetBytes)..<lines[j].contentRange.upperBound)?
                            .trimmingCharacters(in: .whitespaces) ?? ""
                        if !lm.ordered || (!itemTail.isEmpty && !hasUnclosedParagraphSpan(paraRanges, source: source)) {
                            break
                        }
                    }
                    paraRanges.append(lines[j].contentRange)
                    j += 1
                }
                emitParagraphLines(
                    paraRanges,
                    blockStart: blockStartByte,
                    allowImageLift: trackRootCuts,
                    into: &blocks,
                    maps: &maps,
                    starts: &blockStarts
                )
                i = j
            }
        }

        private func hasUnclosedParagraphSpan(_ lineRanges: [Range<Int>], source: String) -> Bool {
            let joined = lineRanges.compactMap { utf8Slice(source, range: $0) }.joined(separator: "\n")
            let b = Array(joined.utf8)
            var i = 0
            var openTicks: Int? = nil
            var star2 = false
            var under2 = false
            var tilde2 = false
            while i < b.count {
                let ch = b[i]
                if openTicks == nil && ch == 0x5C && i + 1 < b.count {
                    i += 2
                    continue
                }
                if ch == 0x60 {
                    var run = 0
                    while i + run < b.count && b[i + run] == 0x60 { run += 1 }
                    if let target = openTicks {
                        if run == target { openTicks = nil }
                    } else {
                        openTicks = run
                    }
                    i += run
                    continue
                }
                if openTicks == nil && i + 1 < b.count && b[i + 1] == ch {
                    if ch == 0x2A { star2.toggle(); i += 2; continue }
                    if ch == 0x5F { under2.toggle(); i += 2; continue }
                    if ch == 0x7E { tilde2.toggle(); i += 2; continue }
                }
                i += 1
            }
            return openTicks != nil || star2 || under2 || tilde2
        }

        private mutating func emitParagraphLines(
            _ lineRanges: [Range<Int>],
            blockStart: Int,
            allowImageLift: Bool,
            into blocks: inout [MarkdownDocBlock],
            maps: inout [MarkdownBlockMap],
            starts: inout [Int]
        ) {
            // Reconstruct combined text + exact byte mapping from line slices while handling hard breaks (`  \n` / `\\\n`)
            var joined = ""
            var srcSegments: [(src: Range<Int>, out: Range<Int>)] = []
            for (idx, lr) in lineRanges.enumerated() {
                var lineStr = utf8Slice(source, range: lr) ?? ""
                var hardBreak = false
                if idx + 1 < lineRanges.count {
                    if lineStr.hasSuffix("\\") {
                        lineStr.removeLast()
                        hardBreak = true
                    } else if lineStr.hasSuffix("  ") {
                        while lineStr.hasSuffix(" ") { lineStr.removeLast() }
                        hardBreak = true
                    }
                }
                let trimLead = (idx > 0) ? lineStr.prefix(while: { $0 == " " || $0 == "\t" }).count : 0
                let cleanStr = trimLead > 0 ? String(lineStr.dropFirst(trimLead)) : lineStr
                let cleanByteStart = baseOffset + lr.lowerBound + (trimLead > 0 ? String(lineStr.prefix(trimLead)).utf8.count : 0)
                let cleanByteEnd = cleanByteStart + cleanStr.utf8.count
                let outStart = joined.utf8.count
                joined.append(cleanStr)
                let outEnd = joined.utf8.count
                if outStart < outEnd {
                    srcSegments.append((cleanByteStart..<cleanByteEnd, outStart..<outEnd))
                }
                if idx + 1 < lineRanges.count {
                    let brStart = joined.utf8.count
                    joined.append(hardBreak ? "\n" : " ")
                    let brEnd = joined.utf8.count
                    let nlByte = baseOffset + lr.upperBound
                    srcSegments.append((nlByte..<min(baseOffset + lineRanges[idx + 1].lowerBound, nlByte + 1), brStart..<brEnd))
                }
            }

            let (inl, rawMap, liftedImages) = parseInline(
                joined,
                baseOffset: baseOffset + blockStart,
                customSrcMap: srcSegments,
                autolink: autolink,
                definitions: definitions,
                trimTrailingCodePad: true,
                collectLiftableImages: allowImageLift
            )

            if allowImageLift && !liftedImages.isEmpty {
                // Split paragraph around top-level lifted images
                var cursor = 0
                for img in liftedImages {
                    if img.start > cursor {
                        let sub = sliceInline(inl, map: rawMap, range: cursor..<img.start, trimCodePad: true)
                        if !sub.inline.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            appendBlock(.para(sub.inline), map: .inline(sub.map), start: blockStart, to: &blocks, maps: &maps, starts: &starts)
                        }
                    }
                    let altMap = sliceSpanMap(rawMap, range: img.start..<img.end, shiftOut: -img.start)
                    appendBlock(.image(src: img.src, alt: img.alt, title: img.title), map: .inline(altMap), start: blockStart, to: &blocks, maps: &maps, starts: &starts)
                    cursor = img.end
                }
                if cursor < inl.text.utf8.count {
                    let sub = sliceInline(inl, map: rawMap, range: cursor..<inl.text.utf8.count, trimCodePad: true)
                    if !sub.inline.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        appendBlock(.para(sub.inline), map: .inline(sub.map), start: blockStart, to: &blocks, maps: &maps, starts: &starts)
                    }
                }
            } else {
                appendBlock(.para(inl), map: .inline(rawMap), start: blockStart, to: &blocks, maps: &maps, starts: &starts)
            }
        }
    }

    // MARK: Inline Parser (CommonMark spans, backtick pads, links with URL, GFM autolinks)

    private struct LiftedImage {
        var start: Int
        var end: Int
        var src: String
        var alt: String
        var title: String
    }

    private static func parseInline(
        _ input: String,
        baseOffset: Int,
        customSrcMap: [(src: Range<Int>, out: Range<Int>)]? = nil,
        autolink: Bool,
        definitions: [String: LinkDefinition],
        trimTrailingCodePad: Bool,
        collectLiftableImages: Bool = false
    ) -> (MarkdownInline, MarkdownSpanMap, [LiftedImage]) {
        let bytes = Array(input.utf8)
        var text = ""
        var spans: [MarkdownStyleSpan] = []
        var links: [MarkdownLinkSpan] = []
        var map = MarkdownSpanMap()
        var lifted: [LiftedImage] = []
        var excludedAutolinkRanges: [Range<Int>] = []

        func mapInputRange(_ lo: Int, _ hi: Int) -> Range<Int> {
            guard let customSrcMap else {
                return (baseOffset + lo)..<(baseOffset + hi)
            }
            var s0 = Int.max
            var s1 = 0
            for seg in customSrcMap where seg.out.upperBound > lo && seg.out.lowerBound < hi {
                let overlap0 = max(lo, seg.out.lowerBound)
                let overlap1 = min(hi, seg.out.upperBound)
                let rel0 = overlap0 - seg.out.lowerBound
                let rel1 = overlap1 - seg.out.lowerBound
                s0 = min(s0, seg.src.lowerBound + min(rel0, seg.src.count))
                s1 = max(s1, seg.src.lowerBound + min(rel1, seg.src.count))
            }
            if s0 == Int.max { return (baseOffset + lo)..<(baseOffset + hi) }
            return s0..<max(s0, s1)
        }

        func appendRaw(_ s: String, srcLo: Int, srcHi: Int) {
            guard !s.isEmpty else { return }
            let out0 = text.utf8.count
            text.append(s)
            let out1 = text.utf8.count
            map.push(src: mapInputRange(srcLo, srcHi), out: out0..<out1)
        }

        func parseRange(_ lo: Int, _ hi: Int, linkDepth: Int, emDepth: Int) {
            var i = lo
            while i < hi {
                let b = bytes[i]

                // 1. Backslash escape
                if b == 0x5C && i + 1 < hi {
                    let next = bytes[i + 1]
                    if next == 0x0A { // '\\\n' already normalized to '\n' or skip
                        let out0 = text.utf8.count
                        text.append("\n")
                        map.push(src: mapInputRange(i, i + 2), out: out0..<text.utf8.count)
                        i += 2
                        continue
                    }
                    if isASCIIPunctuation(next) {
                        let ch = String(UnicodeScalar(next))
                        appendRaw(ch, srcLo: i, srcHi: i + 2)
                        i += 2
                        continue
                    }
                }

                // 2. Code span (`...` / ``...``)
                if b == 0x60 {
                    var tickCount = 0
                    while i + tickCount < hi && bytes[i + tickCount] == 0x60 { tickCount += 1 }
                    if let closeStart = findClosingTicks(bytes, from: i + tickCount, limit: hi, count: tickCount) {
                        let innerLo = i + tickCount
                        let innerHi = closeStart
                        var inner = String(bytes: bytes[innerLo..<innerHi], encoding: .utf8) ?? ""
                        inner = inner.replacingOccurrences(of: "\r\n", with: " ")
                            .replacingOccurrences(of: "\r", with: " ")
                            .replacingOccurrences(of: "\n", with: " ")
                        var trimmedInner = inner
                        var contentLo = innerLo
                        var contentHi = innerHi
                        if !trimmedInner.allSatisfy({ $0 == " " }) && trimmedInner.hasPrefix(" ") && trimmedInner.hasSuffix(" ") && trimmedInner.count >= 2 {
                            trimmedInner.removeFirst()
                            trimmedInner.removeLast()
                            contentLo += 1
                            contentHi -= 1
                        }
                        let padOpenStart = text.utf8.count
                        text.append(MarkdownInline.openPad)
                        let codeStart = text.utf8.count
                        text.append(trimmedInner)
                        let codeEnd = text.utf8.count
                        text.append(MarkdownInline.closePad)
                        let padCloseEnd = text.utf8.count

                        spans.append(MarkdownStyleSpan(start: padOpenStart, end: codeStart, style: .codePad))
                        spans.append(MarkdownStyleSpan(start: codeStart, end: codeEnd, style: .code))
                        spans.append(MarkdownStyleSpan(start: codeEnd, end: padCloseEnd, style: .codePad))
                        if codeStart < codeEnd {
                            map.push(src: mapInputRange(contentLo, contentHi), out: codeStart..<codeEnd)
                        }
                        i = closeStart + tickCount
                        continue
                    } else {
                        appendRaw(String(repeating: "`", count: tickCount), srcLo: i, srcHi: i + tickCount)
                        i += tickCount
                        continue
                    }
                }

                // 3. Image `![alt](src "title")`
                if b == 0x21 && i + 1 < hi && bytes[i + 1] == 0x5B,
                   let linkMatch = matchBracketLink(bytes: bytes, openBracket: i + 1, limit: hi, definitions: definitions) {
                    let altStart = text.utf8.count
                    parseRange(i + 2, linkMatch.closeBracket, linkDepth: linkDepth + 1, emDepth: emDepth + 1)
                    let altEnd = text.utf8.count
                    if altStart < altEnd {
                        excludedAutolinkRanges.append(altStart..<altEnd)
                    }
                    if collectLiftableImages && linkDepth == 0 && emDepth == 0 && !linkMatch.url.isEmpty {
                        let altStr = utf8Slice(text, range: altStart..<altEnd) ?? ""
                        lifted.append(LiftedImage(start: altStart, end: altEnd, src: linkMatch.url, alt: altStr, title: linkMatch.title))
                    }
                    i = linkMatch.afterClose
                    continue
                }

                // 4. Link `[label](url "title")` or `[label][ref]`
                if b == 0x5B,
                   let linkMatch = matchBracketLink(bytes: bytes, openBracket: i, limit: hi, definitions: definitions) {
                    let lStart = text.utf8.count
                    parseRange(i + 1, linkMatch.closeBracket, linkDepth: linkDepth + 1, emDepth: emDepth)
                    let lEnd = text.utf8.count
                    if lStart < lEnd && !linkMatch.url.isEmpty {
                        spans.append(MarkdownStyleSpan(start: lStart, end: lEnd, style: .link))
                        links.append(MarkdownLinkSpan(start: lStart, end: lEnd, url: linkMatch.url))
                    }
                    i = linkMatch.afterClose
                    continue
                }

                // 5. Angle-bracket autolink `<https://...>` / `<mailto:...>` / `<a@b.c>`
                if b == 0x3C, let gt = bytes[(i + 1)..<hi].firstIndex(of: 0x3E),
                   let inner = String(bytes: bytes[(i + 1)..<gt], encoding: .utf8),
                   !inner.contains(where: \.isWhitespace) {
                    let lowerInner = inner.lowercased()
                    if lowerInner.hasPrefix("https://") || lowerInner.hasPrefix("http://") || lowerInner.hasPrefix("mailto:") {
                        let outStart = text.utf8.count
                        appendRaw(inner, srcLo: i + 1, srcHi: gt)
                        let outEnd = text.utf8.count
                        spans.append(MarkdownStyleSpan(start: outStart, end: outEnd, style: .link))
                        links.append(MarkdownLinkSpan(start: outStart, end: outEnd, url: inner))
                        i = gt + 1
                        continue
                    } else if inner.contains("@") && inner.contains(".") {
                        let outStart = text.utf8.count
                        appendRaw(inner, srcLo: i + 1, srcHi: gt)
                        let outEnd = text.utf8.count
                        spans.append(MarkdownStyleSpan(start: outStart, end: outEnd, style: .link))
                        links.append(MarkdownLinkSpan(start: outStart, end: outEnd, url: "mailto:\(inner)"))
                        i = gt + 1
                        continue
                    }
                }

                // 6. Strikethrough `~~...~~`
                if b == 0x7E && i + 1 < hi && bytes[i + 1] == 0x7E,
                   let closeIdx = findClosingDouble(bytes, char: 0x7E, from: i + 2, limit: hi) {
                    let s0 = text.utf8.count
                    parseRange(i + 2, closeIdx, linkDepth: linkDepth, emDepth: emDepth + 1)
                    let s1 = text.utf8.count
                    if s0 < s1 {
                        spans.append(MarkdownStyleSpan(start: s0, end: s1, style: .strike))
                    }
                    i = closeIdx + 2
                    continue
                }

                // 7. Strong / Emphasis (`***`, `**`, `*`, `___`, `__`, `_`)
                if b == 0x2A || b == 0x5F {
                    var run = 0
                    while i + run < hi && bytes[i + run] == b { run += 1 }
                    if run >= 3, let closeIdx = findClosingTriple(bytes, char: b, from: i + 3, limit: hi) {
                        let s0 = text.utf8.count
                        parseRange(i + 3, closeIdx, linkDepth: linkDepth, emDepth: emDepth + 1)
                        let s1 = text.utf8.count
                        if s0 < s1 {
                            spans.append(MarkdownStyleSpan(start: s0, end: s1, style: .strong))
                            spans.append(MarkdownStyleSpan(start: s0, end: s1, style: .em))
                        }
                        i = closeIdx + 3
                        continue
                    } else if run >= 2, let closeIdx = findClosingDouble(bytes, char: b, from: i + 2, limit: hi) {
                        let s0 = text.utf8.count
                        parseRange(i + 2, closeIdx, linkDepth: linkDepth, emDepth: emDepth + 1)
                        let s1 = text.utf8.count
                        if s0 < s1 {
                            spans.append(MarkdownStyleSpan(start: s0, end: s1, style: .strong))
                        }
                        i = closeIdx + 2
                        continue
                    } else if run == 1, canOpenSingleEmphasis(bytes, at: i, limit: hi),
                              let closeIdx = findClosingSingle(bytes, char: b, from: i + 1, limit: hi) {
                        let s0 = text.utf8.count
                        parseRange(i + 1, closeIdx, linkDepth: linkDepth, emDepth: emDepth + 1)
                        let s1 = text.utf8.count
                        if s0 < s1 {
                            spans.append(MarkdownStyleSpan(start: s0, end: s1, style: .em))
                        }
                        i = closeIdx + 1
                        continue
                    }
                }

                // 8. HTML entity `&...;`
                if b == 0x26, let (decoded, nextIdx) = decodeHTMLEntity(bytes, at: i, limit: hi) {
                    appendRaw(decoded, srcLo: i, srcHi: nextIdx)
                    i = nextIdx
                    continue
                }

                // 9. Plain UTF-8 codepoint run
                let cpLen = utf8CharLen(bytes[i])
                let nextIdx = min(hi, i + cpLen)
                let ch = String(bytes: bytes[i..<nextIdx], encoding: .utf8) ?? ""
                appendRaw(ch, srcLo: i, srcHi: nextIdx)
                i = nextIdx
            }
        }

        parseRange(0, bytes.count, linkDepth: 0, emDepth: 0)

        var inline = MarkdownInline(text: text, spans: spans, links: links)
        if trimTrailingCodePad {
            trimEndingCodePadding(&inline, map: &map)
        }
        if autolink {
            applyGFMAutolinks(to: &inline, excluding: excludedAutolinkRanges)
        }
        return (inline, map, lifted)
    }

    private static func trimEndingCodePadding(_ inl: inout MarkdownInline, map: inout MarkdownSpanMap) {
        let len = inl.text.utf8.count
        let trimmedStr = inl.text.trimmingTrailingWhitespaceOnly()
        let trimmedLen = trimmedStr.utf8.count
        var cutTo: Int?
        if trimmedStr.hasSuffix("\u{2069}") {
            let withoutIsolate = String(trimmedStr.dropLast())
            let wLen = withoutIsolate.utf8.count
            if inl.spans.contains(where: { $0.style == .codePad && $0.start == wLen }) {
                cutTo = withoutIsolate.trimmingTrailingWhitespaceOnly().utf8.count
            }
        } else if trimmedLen < len {
            cutTo = trimmedLen
        }
        guard let cut = cutTo, cut < len else { return }
        inl.text = utf8Slice(inl.text, range: 0..<cut) ?? inl.text
        inl.spans = inl.spans.compactMap { s in
            let hi = min(s.end, cut)
            return s.start < hi ? MarkdownStyleSpan(start: s.start, end: hi, style: s.style) : nil
        }
        inl.links = inl.links.compactMap { l in
            let hi = min(l.end, cut)
            return l.start < hi ? MarkdownLinkSpan(start: l.start, end: hi, url: l.url) : nil
        }
        map.truncateOut(cut)
    }

    private static func applyGFMAutolinks(to inl: inout MarkdownInline, excluding: [Range<Int>] = []) {
        let scans = MarkdownAutolink.scan(inl.text)
        guard !scans.isEmpty else { return }
        for m in scans {
            let b0 = inl.text.utf8.distance(from: inl.text.startIndex, to: m.range.lowerBound)
            let b1 = inl.text.utf8.distance(from: inl.text.startIndex, to: m.range.upperBound)
            // Skip if inside an existing link, image alt, or code span
            let overlaps = inl.links.contains(where: { $0.start < b1 && b0 < $0.end }) ||
                excluding.contains(where: { $0.lowerBound < b1 && b0 < $0.upperBound }) ||
                inl.spans.contains(where: { ($0.style == .code || $0.style == .codePad || $0.style == .link) && $0.start < b1 && b0 < $0.end })
            if overlaps { continue }
            inl.spans.append(MarkdownStyleSpan(start: b0, end: b1, style: .link))
            inl.links.append(MarkdownLinkSpan(start: b0, end: b1, url: m.url))
        }
        inl.spans.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        inl.links.sort { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    private static func sliceInline(
        _ inl: MarkdownInline,
        map: MarkdownSpanMap,
        range: Range<Int>,
        trimCodePad: Bool
    ) -> (inline: MarkdownInline, map: MarkdownSpanMap) {
        guard let subStr = utf8Slice(inl.text, range: range) else {
            return (MarkdownInline(), MarkdownSpanMap())
        }
        let leadWS = subStr.prefix(while: \.isWhitespace).utf8.count
        let trimmed = subStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let adjLo = range.lowerBound + leadWS
        let adjHi = adjLo + trimmed.utf8.count
        let spans = inl.spans.compactMap { s -> MarkdownStyleSpan? in
            let lo = max(s.start, adjLo) - adjLo
            let hi = min(s.end, adjHi) - adjLo
            return lo < hi ? MarkdownStyleSpan(start: lo, end: hi, style: s.style) : nil
        }
        let links = inl.links.compactMap { l -> MarkdownLinkSpan? in
            let lo = max(l.start, adjLo) - adjLo
            let hi = min(l.end, adjHi) - adjLo
            return lo < hi ? MarkdownLinkSpan(start: lo, end: hi, url: l.url) : nil
        }
        var out = MarkdownInline(text: trimmed, spans: spans, links: links)
        var subMap = sliceSpanMap(map, range: adjLo..<adjHi, shiftOut: -adjLo)
        if trimCodePad {
            trimEndingCodePadding(&out, map: &subMap)
        }
        return (out, subMap)
    }

    private static func sliceSpanMap(_ map: MarkdownSpanMap, range: Range<Int>, shiftOut: Int) -> MarkdownSpanMap {
        var out = MarkdownSpanMap()
        for seg in map.segments where seg.out.upperBound > range.lowerBound && seg.out.lowerBound < range.upperBound {
            let o0 = max(seg.out.lowerBound, range.lowerBound)
            let o1 = min(seg.out.upperBound, range.upperBound)
            if o0 < o1 {
                let s0 = seg.src.lowerBound + min(o0 - seg.out.lowerBound, seg.src.count)
                let s1 = seg.src.lowerBound + min(o1 - seg.out.lowerBound, seg.src.count)
                out.push(src: s0..<max(s0, s1), out: (o0 + shiftOut)..<(o1 + shiftOut))
            }
        }
        return out
    }

    // MARK: Inline Scanner Helpers

    private struct BracketLinkMatch {
        var closeBracket: Int
        var url: String
        var title: String
        var afterClose: Int
    }

    private static func matchBracketLink(
        bytes: [UInt8],
        openBracket: Int,
        limit: Int,
        definitions: [String: LinkDefinition]
    ) -> BracketLinkMatch? {
        var i = openBracket + 1
        var depth = 1
        while i < limit {
            if bytes[i] == 0x5C && i + 1 < limit { i += 2; continue }
            if bytes[i] == 0x60 {
                var ticks = 0
                while i + ticks < limit && bytes[i + ticks] == 0x60 { ticks += 1 }
                if let closeT = findClosingTicks(bytes, from: i + ticks, limit: limit, count: ticks) {
                    i = closeT + ticks
                    continue
                }
            }
            if bytes[i] == 0x5B { depth += 1 }
            if bytes[i] == 0x5D {
                depth -= 1
                if depth == 0 { break }
            }
            i += 1
        }
        guard depth == 0, i < limit else { return nil }
        let closeBracket = i

        // 1) Inline destination `[label](url "title")`
        if closeBracket + 1 < limit && bytes[closeBracket + 1] == 0x28 {
            var p = closeBracket + 2
            while p < limit && (bytes[p] == 0x20 || bytes[p] == 0x09 || bytes[p] == 0x0A) { p += 1 }
            var url = ""
            var title = ""
            if p < limit && bytes[p] == 0x3C { // <url>
                p += 1
                let uStart = p
                while p < limit && bytes[p] != 0x3E && bytes[p] != 0x0A { p += 1 }
                guard p < limit && bytes[p] == 0x3E else { return nil }
                url = String(bytes: bytes[uStart..<p], encoding: .utf8) ?? ""
                p += 1
            } else {
                let uStart = p
                var pDepth = 0
                while p < limit {
                    let c = bytes[p]
                    if c == 0x5C && p + 1 < limit { p += 2; continue }
                    if c == 0x28 { pDepth += 1 }
                    else if c == 0x29 {
                        if pDepth == 0 { break }
                        pDepth -= 1
                    } else if c == 0x20 || c == 0x09 || c == 0x0A {
                        break
                    }
                    p += 1
                }
                url = unescapeASCII(String(bytes: bytes[uStart..<p], encoding: .utf8) ?? "")
            }
            while p < limit && (bytes[p] == 0x20 || bytes[p] == 0x09 || bytes[p] == 0x0A) { p += 1 }
            if p < limit && (bytes[p] == 0x22 || bytes[p] == 0x27) { // title
                let quote = bytes[p]
                p += 1
                let tStart = p
                while p < limit && bytes[p] != quote {
                    if bytes[p] == 0x5C && p + 1 < limit { p += 2; continue }
                    p += 1
                }
                if p < limit {
                    title = String(bytes: bytes[tStart..<p], encoding: .utf8) ?? ""
                    p += 1
                }
                while p < limit && (bytes[p] == 0x20 || bytes[p] == 0x09 || bytes[p] == 0x0A) { p += 1 }
            }
            guard p < limit && bytes[p] == 0x29 else { return nil }
            return BracketLinkMatch(closeBracket: closeBracket, url: url, title: title, afterClose: p + 1)
        }

        // 2) Full reference `[label][id]`
        if closeBracket + 1 < limit && bytes[closeBracket + 1] == 0x5B {
            if let refEnd = bytes[(closeBracket + 2)..<limit].firstIndex(of: 0x5D) {
                let rawId = String(bytes: bytes[(closeBracket + 2)..<refEnd], encoding: .utf8) ?? ""
                let labelStr = String(bytes: bytes[(openBracket + 1)..<closeBracket], encoding: .utf8) ?? ""
                let key = (rawId.isEmpty ? labelStr : rawId).trimmingCharacters(in: .whitespaces).lowercased()
                if let def = definitions[key] {
                    return BracketLinkMatch(closeBracket: closeBracket, url: def.url, title: def.title, afterClose: refEnd + 1)
                }
            }
        }

        // 3) Shortcut reference `[id]`
        let labelKey = (String(bytes: bytes[(openBracket + 1)..<closeBracket], encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if let def = definitions[labelKey] {
            return BracketLinkMatch(closeBracket: closeBracket, url: def.url, title: def.title, afterClose: closeBracket + 1)
        }
        return nil
    }

    private static func findClosingTicks(_ bytes: [UInt8], from start: Int, limit: Int, count: Int) -> Int? {
        var i = start
        while i < limit {
            if bytes[i] == 0x60 {
                var len = 0
                while i + len < limit && bytes[i + len] == 0x60 { len += 1 }
                if len == count { return i }
                i += len
                continue
            }
            i += 1
        }
        return nil
    }

    private static func findClosingDouble(_ bytes: [UInt8], char: UInt8, from start: Int, limit: Int) -> Int? {
        var i = start
        while i + 1 < limit {
            if bytes[i] == 0x5C && i + 1 < limit { i += 2; continue }
            if bytes[i] == 0x60 {
                var ticks = 0
                while i + ticks < limit && bytes[i + ticks] == 0x60 { ticks += 1 }
                if let c = findClosingTicks(bytes, from: i + ticks, limit: limit, count: ticks) {
                    i = c + ticks
                    continue
                }
            }
            if bytes[i] == char && bytes[i + 1] == char {
                if char == 0x5F && i + 2 < limit && isASCIIAlphaNum(bytes[i + 2]) {
                    i += 2
                    continue
                }
                return i
            }
            i += 1
        }
        return nil
    }

    private static func findClosingTriple(_ bytes: [UInt8], char: UInt8, from start: Int, limit: Int) -> Int? {
        var i = start
        while i + 2 < limit {
            if bytes[i] == 0x5C && i + 1 < limit { i += 2; continue }
            if bytes[i] == char && bytes[i + 1] == char && bytes[i + 2] == char { return i }
            i += 1
        }
        return nil
    }

    private static func canOpenSingleEmphasis(_ bytes: [UInt8], at i: Int, limit: Int) -> Bool {
        guard i + 1 < limit else { return false }
        let after = bytes[i + 1]
        if after == 0x20 || after == 0x09 || after == 0x0A { return false }
        if bytes[i] == 0x5F && i > 0 && isASCIIAlphaNum(bytes[i - 1]) { return false }
        return true
    }

    private static func findClosingSingle(_ bytes: [UInt8], char: UInt8, from start: Int, limit: Int) -> Int? {
        var i = start
        while i < limit {
            if bytes[i] == 0x5C && i + 1 < limit { i += 2; continue }
            if bytes[i] == 0x60 {
                var ticks = 0
                while i + ticks < limit && bytes[i + ticks] == 0x60 { ticks += 1 }
                if let c = findClosingTicks(bytes, from: i + ticks, limit: limit, count: ticks) {
                    i = c + ticks
                    continue
                }
            }
            if bytes[i] == char {
                if i + 1 < limit && bytes[i + 1] == char {
                    // Jump past nested ** or __
                    if let c = findClosingDouble(bytes, char: char, from: i + 2, limit: limit) {
                        i = c + 2
                        continue
                    }
                    i += 2
                    continue
                }
                let prev = bytes[i - 1]
                if prev == 0x20 || prev == 0x09 || prev == 0x0A {
                    i += 1
                    continue
                }
                if char == 0x5F && i + 1 < limit && isASCIIAlphaNum(bytes[i + 1]) {
                    i += 1
                    continue
                }
                return i
            }
            i += 1
        }
        return nil
    }

    private static func decodeHTMLEntity(_ bytes: [UInt8], at start: Int, limit: Int) -> (String, Int)? {
        guard let semi = bytes[(start + 1)..<min(limit, start + 14)].firstIndex(of: 0x3B) else { return nil }
        guard let name = String(bytes: bytes[(start + 1)..<semi], encoding: .utf8) else { return nil }
        switch name {
        case "amp": return ("&", semi + 1)
        case "lt": return ("<", semi + 1)
        case "gt": return (">", semi + 1)
        case "quot": return ("\"", semi + 1)
        case "apos": return ("'", semi + 1)
        case "nbsp": return ("\u{00A0}", semi + 1)
        case "mdash": return ("\u{2014}", semi + 1)
        case "ndash": return ("\u{2013}", semi + 1)
        case "hellip": return ("\u{2026}", semi + 1)
        case "lsquo": return ("\u{2018}", semi + 1)
        case "rsquo": return ("\u{2019}", semi + 1)
        case "ldquo": return ("\u{201C}", semi + 1)
        case "rdquo": return ("\u{201D}", semi + 1)
        case "copy": return ("\u{00A9}", semi + 1)
        case "reg": return ("\u{00AE}", semi + 1)
        case "trade": return ("\u{2122}", semi + 1)
        default:
            if name.hasPrefix("#x") || name.hasPrefix("#X"), let code = UInt32(name.dropFirst(2), radix: 16), let scalar = UnicodeScalar(code) {
                return (String(scalar), semi + 1)
            }
            if name.hasPrefix("#"), let code = UInt32(name.dropFirst(1), radix: 10), let scalar = UnicodeScalar(code) {
                return (String(scalar), semi + 1)
            }
            return nil
        }
    }

    private static func unescapeASCII(_ s: String) -> String {
        var out = ""
        var iter = s.unicodeScalars.makeIterator()
        while let sc = iter.next() {
            if sc == "\\" {
                if let next = iter.next() {
                    if next.value < 128 && isASCIIPunctuation(UInt8(next.value)) {
                        out.unicodeScalars.append(next)
                    } else {
                        out.append("\\")
                        out.unicodeScalars.append(next)
                    }
                } else {
                    out.append("\\")
                }
            } else {
                out.unicodeScalars.append(sc)
            }
        }
        return out
    }

    private static func isASCIIPunctuation(_ b: UInt8) -> Bool {
        (b >= 0x21 && b <= 0x2F) || (b >= 0x3A && b <= 0x40) || (b >= 0x5B && b <= 0x60) || (b >= 0x7B && b <= 0x7E)
    }

    private static func isASCIIAlphaNum(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    private static func utf8CharLen(_ lead: UInt8) -> Int {
        if lead & 0x80 == 0 { return 1 }
        if lead & 0xE0 == 0xC0 { return 2 }
        if lead & 0xF0 == 0xE0 { return 3 }
        if lead & 0xF8 == 0xF0 { return 4 }
        return 1
    }

    // MARK: Block Scanner Helpers

    private static func appendBlock(
        _ b: MarkdownDocBlock,
        map: MarkdownBlockMap,
        start: Int,
        to blocks: inout [MarkdownDocBlock],
        maps: inout [MarkdownBlockMap],
        starts: inout [Int]
    ) {
        blocks.append(b)
        maps.append(map)
        starts.append(start)
    }

    private static func lastNewlineCut(_ text: String) -> Int {
        guard let idx = text.lastIndex(of: "\n") else { return 0 }
        return text.utf8.distance(from: text.startIndex, to: idx)
    }

    private static func buildCodeTextAndMap(
        source: String,
        baseOffset: Int,
        lineRanges: [Range<Int>],
        closed: Bool,
        hasTrailingNewline: Bool
    ) -> (String, MarkdownSpanMap) {
        _ = hasTrailingNewline
        _ = closed
        var text = ""
        var map = MarkdownSpanMap()
        for (idx, lr) in lineRanges.enumerated() {
            let line = utf8Slice(source, range: lr) ?? ""
            let out0 = text.utf8.count
            text.append(line)
            let out1 = text.utf8.count
            if out0 < out1 {
                map.push(src: (baseOffset + lr.lowerBound)..<(baseOffset + lr.upperBound), out: out0..<out1)
            }
            if idx + 1 < lineRanges.count {
                let nl0 = text.utf8.count
                text.append("\n")
                map.push(src: (baseOffset + lr.upperBound)..<(baseOffset + lr.upperBound + 1), out: nl0..<(nl0 + 1))
            }
        }
        return (text, map)
    }

    private static func isReferenceDefinitionLine(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("["), let close = trimmed.dropFirst().firstIndex(of: "]") else { return false }
        let after = trimmed[trimmed.index(after: close)...]
        guard after.hasPrefix(":") else { return false }
        return !after.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func parseFenceHeader(_ raw: String) -> (char: Character, count: Int, lang: String?)? {
        let stripped = raw.drop(while: { $0 == " " })
        let leadSpaces = raw.count - stripped.count
        guard leadSpaces <= 3, let first = stripped.first, first == "`" || first == "~" else { return nil }
        let count = stripped.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        let info = String(stripped.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        if first == "`" && info.contains("`") { return nil }
        let word = info.split(whereSeparator: { $0.isWhitespace || $0 == "," }).first.map(String.init)
        return (first, count, (word?.isEmpty == false) ? word : nil)
    }

    private static func isFenceHeaderBool(_ raw: String) -> Bool {
        parseFenceHeader(raw) != nil
    }

    private static func isFenceCloser(_ raw: String, fenceChar: Character, minLen: Int) -> Bool {
        let stripped = raw.drop(while: { $0 == " " })
        guard raw.count - stripped.count <= 3 else { return false }
        let count = stripped.prefix(while: { $0 == fenceChar }).count
        guard count >= minLen else { return false }
        return stripped.dropFirst(count).allSatisfy { $0.isWhitespace }
    }

    private static func isIndentedCodeLine(_ raw: String) -> Bool {
        raw.hasPrefix("    ") || raw.hasPrefix("\t")
    }

    private static func stripCodeIndentBytes(_ raw: String) -> Int {
        if raw.hasPrefix("\t") { return 1 }
        if raw.hasPrefix("    ") { return 4 }
        return 0
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first else { return false }
        return (first == "-" || first == "*" || first == "_") && compact.allSatisfy { $0 == first }
    }

    private static func parseATXHeading(source: String, lineRange: Range<Int>) -> (level: Int, contentRange: Range<Int>)? {
        guard let raw = utf8Slice(source, range: lineRange) else { return nil }
        let trimmedLead = raw.drop(while: { $0 == " " })
        let leadBytes = raw.utf8.count - String(trimmedLead).utf8.count
        guard leadBytes <= 3, trimmedLead.hasPrefix("#") else { return nil }
        let hashes = trimmedLead.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let afterHashes = trimmedLead.dropFirst(hashes.count)
        guard afterHashes.isEmpty || afterHashes.first == " " || afterHashes.first == "\t" else { return nil }
        var content = afterHashes.trimmingCharacters(in: .whitespaces)
        var innerStart = lineRange.lowerBound + leadBytes + hashes.count + (afterHashes.utf8.count - String(afterHashes.drop(while: { $0 == " " || $0 == "\t" })).utf8.count)
        // Strip optional closing ### sequence preceded by whitespace
        if let lastSpace = content.lastIndex(where: { $0.isWhitespace }),
           content[content.index(after: lastSpace)...].allSatisfy({ $0 == "#" }) {
            content = String(content[..<lastSpace]).trimmingCharacters(in: .whitespaces)
        } else if content.allSatisfy({ $0 == "#" }) {
            content = ""
        }
        innerStart = min(innerStart, lineRange.upperBound)
        let innerEnd = min(lineRange.upperBound, innerStart + content.utf8.count)
        return (hashes.count, innerStart..<innerEnd)
    }

    private struct ListMarkerInfo {
        var indent: Int
        var ordered: Bool
        var start: UInt64
        var contentIndent: Int
        var contentOffsetBytes: Int
    }

    private static func parseListMarker(_ raw: String) -> ListMarkerInfo? {
        let indent = indentWidth(raw)
        let trimmed = raw.drop(while: { $0 == " " || $0 == "\t" })
        let leadBytes = raw.utf8.count - String(trimmed).utf8.count
        if let first = trimmed.first, (first == "-" || first == "*" || first == "+") {
            let after = trimmed.dropFirst()
            if after.isEmpty || after.first == " " || after.first == "\t" {
                let sp = after.first != nil ? 1 : 0
                return ListMarkerInfo(indent: indent, ordered: false, start: 1, contentIndent: indent + 1 + sp, contentOffsetBytes: leadBytes + 1 + sp)
            }
        }
        let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty && digits.count <= 9, let num = UInt64(digits) {
            let afterDigits = trimmed.dropFirst(digits.count)
            if let delim = afterDigits.first, delim == "." || delim == ")" {
                let afterDelim = afterDigits.dropFirst()
                if afterDelim.isEmpty || afterDelim.first == " " || afterDelim.first == "\t" {
                    let sp = afterDelim.first != nil ? 1 : 0
                    return ListMarkerInfo(indent: indent, ordered: true, start: num, contentIndent: indent + digits.count + 1 + sp, contentOffsetBytes: leadBytes + digits.count + 1 + sp)
                }
            }
        }
        return nil
    }

    private static func parseTaskCheckboxPrefix(_ rest: String) -> (checked: Bool, dropBytes: Int)? {
        if rest.hasPrefix("[ ] ") { return (false, 4) }
        if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { return (true, 4) }
        if rest == "[ ]" { return (false, 3) }
        if rest == "[x]" || rest == "[X]" { return (true, 3) }
        return nil
    }

    private static func indentWidth(_ s: String) -> Int {
        var w = 0
        for c in s {
            if c == " " { w += 1 }
            else if c == "\t" { w += 4 - (w % 4) }
            else { break }
        }
        return w
    }

    private static func stripLeadingIndent(_ s: String, targetCols: Int) -> Int {
        var cols = 0
        var bytes = 0
        for sc in s.unicodeScalars {
            if cols >= targetCols { break }
            if sc == " " {
                cols += 1
                bytes += 1
            } else if sc == "\t" {
                cols += 4 - (cols % 4)
                bytes += 1
            } else {
                break
            }
        }
        return bytes
    }

    private static func parseTableDelimiterAlignments(_ raw: String) -> [MarkdownTableAlign]? {
        let cells = splitPipeCellsPlain(raw)
        guard !cells.isEmpty else { return nil }
        var out: [MarkdownTableAlign] = []
        for c in cells {
            let t = c.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.contains("-"), t.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
            let left = t.hasPrefix(":")
            let right = t.hasSuffix(":") && t.count > 1
            switch (left, right) {
            case (true, true): out.append(.center)
            case (false, true): out.append(.end)
            default: out.append(.start)
            }
        }
        return out
    }

    private static func parsePendingTable(
        _ src: String,
        baseOffset: Int,
        autolink: Bool,
        definitions: [String: LinkDefinition]
    ) -> (MarkdownTableAST, MarkdownBlockMap)? {
        let rawLines = src.trimmingTrailingWhitespaceOnly().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !rawLines.isEmpty, rawLines.count <= 2 else { return nil }
        let leadWS = rawLines[0].prefix(while: \.isWhitespace).utf8.count
        let head = rawLines[0].trimmingCharacters(in: .whitespaces)
        guard head.hasPrefix("|") else { return nil }
        let headCells = splitTableRow(head, baseOffset: baseOffset + leadWS)
        guard headCells.count >= 2 else { return nil }
        var aligns = Array(repeating: MarkdownTableAlign.start, count: headCells.count)
        if rawLines.count == 2 {
            let delim = rawLines[1].trimmingCharacters(in: .whitespaces)
            guard delim.hasPrefix("|"), delim.allSatisfy({ "|:- ".contains($0) }) else { return nil }
            let specs = splitTableRow(delim, baseOffset: 0)
            for (i, sp) in specs.enumerated() where i < aligns.count {
                let s = sp.text
                if s.hasPrefix(":") && s.count > 1 && s.hasSuffix(":") { aligns[i] = .center }
                else if s.count > 1 && s.hasSuffix(":") { aligns[i] = .end }
                else { aligns[i] = .start }
            }
        }
        var headInlines: [MarkdownInline] = []
        var headMaps: [MarkdownSpanMap] = []
        for c in headCells {
            let (inl, sm, _) = parseInline(c.text, baseOffset: c.offset, autolink: autolink, definitions: definitions, trimTrailingCodePad: true)
            headInlines.append(inl)
            headMaps.append(sm)
        }
        return (MarkdownTableAST(align: aligns, head: headInlines, rows: [], open: true), .table(head: headMaps, rows: []))
    }

    private static func splitTableRow(_ line: String, baseOffset: Int) -> [(offset: Int, text: String)] {
        let bytes = Array(line.utf8)
        let pipeOff = (bytes.first == 0x7C) ? 1 : 0
        var cells: [(offset: Int, raw: [UInt8])] = [(baseOffset + pipeOff, [])]
        var i = pipeOff
        while i < bytes.count {
            if bytes[i] == 0x5C && i + 1 < bytes.count && bytes[i + 1] == 0x7C {
                cells[cells.count - 1].raw.append(0x7C)
                i += 2
                continue
            }
            if bytes[i] == 0x7C {
                cells.append((baseOffset + i + 1, []))
                i += 1
                continue
            }
            cells[cells.count - 1].raw.append(bytes[i])
            i += 1
        }
        let trimmedEnd = line.trimmingTrailingWhitespaceOnly()
        if let last = cells.last,
           (String(bytes: last.raw, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
           trimmedEnd.hasSuffix("|") && !trimmedEnd.hasSuffix("\\|") {
            cells.removeLast()
        }
        return cells.map { cell in
            let str = String(bytes: cell.raw, encoding: .utf8) ?? ""
            let lead = str.prefix(while: \.isWhitespace).utf8.count
            return (cell.offset + lead, str.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func splitPipeCellsPlain(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Legacy `MarkdownParser.parse` / `inlineTokens` / `inlineSpans` / `highlightCode` (kept compatible + fixed URLs!)

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        // Parse footnotes if present, plus clean AST conversion so legacy tests pass 100%
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            // Fenced code
            if let fence = parseFenceHeader(raw) {
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if isFenceCloser(lines[i], fenceChar: fence.char, minLen: fence.count) {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(language: fence.lang, code: codeLines.joined(separator: "\n")))
                continue
            }

            // Footnote definition `[^id]: ...`
            if trimmed.hasPrefix("[^"),
               let closeBracket = trimmed.dropFirst(2).firstIndex(of: "]") {
                let fnID = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<closeBracket])
                let afterBracket = trimmed[trimmed.index(after: closeBracket)...]
                if afterBracket.hasPrefix(":") && !fnID.isEmpty {
                    var bodyLines = [String(afterBracket.dropFirst()).trimmingCharacters(in: .whitespaces)]
                    i += 1
                    while i < lines.count {
                        let next = lines[i]
                        if next.hasPrefix("  ") || next.hasPrefix("\t") {
                            bodyLines.append(next.trimmingCharacters(in: .whitespaces))
                            i += 1
                        } else {
                            break
                        }
                    }
                    blocks.append(.footnoteDefinition(id: fnID, text: bodyLines.joined(separator: " ")))
                    continue
                }
            }

            // Thematic break
            if isHorizontalRule(trimmed) {
                blocks.append(.thematicBreak)
                i += 1
                continue
            }

            // Heading
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if (1...6).contains(level) && trimmed.dropFirst(level).first?.isWhitespace == true {
                    blocks.append(.heading(level: level, text: trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)))
                    i += 1
                    continue
                }
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var q: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var line = String(t.dropFirst())
                        if line.hasPrefix(" ") { line.removeFirst() }
                        q.append(line)
                        i += 1
                    } else if t.isEmpty {
                        break
                    } else {
                        break
                    }
                }
                blocks.append(.blockquote(q.joined(separator: "\n")))
                continue
            }

            // Task list
            if parseLegacyTaskItem(trimmed) != nil {
                var items: [MarkdownTaskItem] = []
                while i < lines.count, let task = parseLegacyTaskItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(task)
                    i += 1
                }
                blocks.append(.taskList(items))
                continue
            }

            // GFM Table
            if trimmed.contains("|") && i + 1 < lines.count && parseTableDelimiterAlignments(lines[i + 1]) != nil {
                let headers = splitPipeCellsPlain(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let rt = lines[i].trimmingCharacters(in: .whitespaces)
                    if rt.isEmpty || !rt.contains("|") { break }
                    rows.append(splitPipeCellsPlain(rt))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            // Unordered list
            if let firstItem = parseUnorderedBullet(trimmed) {
                var items = [firstItem]
                i += 1
                while i < lines.count, let next = parseUnorderedBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    i += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            // Ordered list
            if let firstOrd = parseOrderedBullet(trimmed) {
                var items = [firstOrd]
                i += 1
                while i < lines.count, let next = parseOrderedBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            // Paragraph
            var para: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || isFenceHeaderBool(lines[i]) || t.hasPrefix(">") ||
                    isHorizontalRule(t) || parseLegacyTaskItem(t) != nil || parseUnorderedBullet(t) != nil || parseOrderedBullet(t) != nil || t.hasPrefix("[^") {
                    break
                }
                para.append(t)
                i += 1
            }
            if !para.isEmpty {
                blocks.append(.paragraph(para.joined(separator: " ")))
            }
        }
        return blocks
    }

    /// Parses inline formatting tokens including destination URLs (`[label](url)` and autolinks).
    public static func inlineTokens(_ source: String) -> [InlineToken] {
        let defs = collectLinkDefinitions(in: source)
        let (inl, _, _) = parseInline(source, baseOffset: 0, autolink: true, definitions: defs, trimTrailingCodePad: false)
        let cleanText = MarkdownInline.unpadded(inl.text)
        guard !cleanText.isEmpty else { return [] }
        // Build clean byte offsets mapping back to spans/links
        var cuts: Set<Int> = [0, inl.text.utf8.count]
        for s in inl.spans where s.style != .codePad {
            cuts.insert(s.start)
            cuts.insert(s.end)
        }
        for l in inl.links {
            cuts.insert(l.start)
            cuts.insert(l.end)
        }
        let sorted = cuts.sorted()
        var tokens: [InlineToken] = []
        for k in 0..<(sorted.count - 1) {
            let a = sorted[k]
            let b = sorted[k + 1]
            guard a < b, let seg = utf8Slice(inl.text, range: a..<b) else { continue }
            let cleanSeg = MarkdownInline.unpadded(seg)
            guard !cleanSeg.isEmpty else { continue }
            let isCode = inl.spans.contains { $0.style == .code && $0.start <= a && b <= $0.end }
            let isBold = inl.spans.contains { $0.style == .strong && $0.start <= a && b <= $0.end }
            let isItalic = inl.spans.contains { $0.style == .em && $0.start <= a && b <= $0.end }
            let isStrike = inl.spans.contains { $0.style == .strike && $0.start <= a && b <= $0.end }
            let link = inl.links.first { $0.start <= a && b <= $0.end }
            tokens.append(InlineToken(
                text: cleanSeg,
                url: link?.url,
                isCode: isCode,
                isBold: isBold,
                isItalic: isItalic,
                isStrikethrough: isStrike,
                isLink: link != nil
            ))
        }
        return tokens
    }

    public static func inlineSpans(
        _ source: String,
        kit: Kit,
        baseColor: Color? = nil,
        searchQuery: String? = nil,
        activeMatch: Int? = nil
    ) -> [TextSpan] {
        let fg = baseColor ?? kit.c.textBase
        let tokens = inlineTokens(source)
        var spans = tokens.map { tok -> TextSpan in
            TextSpan(
                tok.text,
                color: tok.isLink || tok.isCode ? kit.c.textAccent : (tok.isStrikethrough ? kit.c.textMuted : fg),
                background: tok.isCode ? kit.alpha(kit.c.textBase, 0.08) : nil,
                weight: tok.isBold ? 670 : (tok.isLink ? 500 : nil),
                italic: tok.isItalic,
                monospace: tok.isCode,
                underline: tok.isLink,
                strikethrough: tok.isStrikethrough
            )
        }
        if let query = searchQuery, !query.isEmpty {
            spans = applySearchHighlight(
                spans: spans,
                query: query,
                activeMatch: activeMatch,
                highlightColor: kit.alpha(kit.c.warning.icon, 0.24),
                activeColor: kit.alpha(kit.c.warning.icon, 0.45)
            )
        }
        return spans
    }

    public static func highlightCode(_ code: String, language: String?, kit: Kit) -> [TextSpan] {
        let highlights = SyntaxHighlighter.builtin.highlight(language: language, code: code)
        return SyntaxTheme.fromKit(kit).spans(for: code, highlights: highlights, defaultColor: kit.c.textBase)
    }

    public static func findMatches(in source: String, query: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        let doc = MarkdownParser.parseDocument(source)
        let matches = MarkdownFind.findBounds(in: source, doc: doc, query: query, caseSensitivity: .insensitive)
        return matches.compactMap { m -> Range<String.Index>? in
            let utf8 = source.utf8
            guard let lo = utf8.index(utf8.startIndex, offsetBy: m.lowerBound, limitedBy: utf8.endIndex),
                  let hi = utf8.index(utf8.startIndex, offsetBy: m.upperBound, limitedBy: utf8.endIndex),
                  let s = String.Index(lo, within: source),
                  let e = String.Index(hi, within: source) else {
                return nil
            }
            return s..<e
        }
    }

    private static func parseLegacyTaskItem(_ trimmed: String) -> MarkdownTaskItem? {
        guard trimmed.hasPrefix("- [") || trimmed.hasPrefix("* [") || trimmed.hasPrefix("+ [") else { return nil }
        let rest = String(trimmed.dropFirst(2))
        if rest.hasPrefix("[ ] ") { return MarkdownTaskItem(checked: false, text: String(rest.dropFirst(4))) }
        if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { return MarkdownTaskItem(checked: true, text: String(rest.dropFirst(4))) }
        return nil
    }

    private static func parseUnorderedBullet(_ trimmed: String) -> String? {
        if (trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")) && parseLegacyTaskItem(trimmed) == nil {
            return String(trimmed.dropFirst(2))
        }
        return nil
    }

    private static func parseOrderedBullet(_ trimmed: String) -> String? {
        let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let after = trimmed.dropFirst(digits.count)
        if after.hasPrefix(". ") { return String(after.dropFirst(2)) }
        if after.hasPrefix(") ") { return String(after.dropFirst(2)) }
        return nil
    }
}

// MARK: - Search Highlight Splitting Helper

private func applySearchHighlight(
    spans: [TextSpan],
    query: String,
    activeMatch: Int?,
    highlightColor: Color,
    activeColor: Color
) -> [TextSpan] {
    guard !query.isEmpty else { return spans }
    let fullText = spans.map(\.text).joined()
    let lowerFull = fullText.lowercased()
    let lowerQuery = query.lowercased()
    var matchRanges: [Range<Int>] = []
    var searchStart = lowerFull.startIndex
    while let range = lowerFull.range(of: lowerQuery, range: searchStart..<lowerFull.endIndex) {
        let startByte = fullText.utf8.distance(from: fullText.startIndex, to: range.lowerBound)
        let endByte = fullText.utf8.distance(from: fullText.startIndex, to: range.upperBound)
        matchRanges.append(startByte..<endByte)
        searchStart = range.upperBound
    }
    guard !matchRanges.isEmpty else { return spans }
    return applyUTF8Highlights(spans: spans, ranges: matchRanges.map { ($0, false) }, activeIndex: activeMatch, bg: highlightColor, activeBg: activeColor, fg: nil, activeFg: nil)
}

private func applyUTF8Highlights(
    spans: [TextSpan],
    ranges: [(range: Range<Int>, isCurrent: Bool)],
    activeIndex: Int?,
    bg: Color,
    activeBg: Color,
    fg: Color?,
    activeFg: Color?
) -> [TextSpan] {
    guard !ranges.isEmpty else { return spans }
    var out: [TextSpan] = []
    var cursor = 0
    for span in spans {
        let len = span.text.utf8.count
        let sStart = cursor
        let sEnd = cursor + len
        cursor = sEnd
        guard len > 0 else { continue }

        let overlapping = ranges.enumerated().filter { $0.element.range.lowerBound < sEnd && $0.element.range.upperBound > sStart }
        if overlapping.isEmpty {
            out.append(span)
            continue
        }

        var localCuts: Set<Int> = [0, len]
        for (_, item) in overlapping {
            localCuts.insert(max(0, min(len, item.range.lowerBound - sStart)))
            localCuts.insert(max(0, min(len, item.range.upperBound - sStart)))
        }
        let sorted = localCuts.sorted()
        for idx in 0..<(sorted.count - 1) {
            let a = sorted[idx]
            let b = sorted[idx + 1]
            guard a < b, let sub = utf8Slice(span.text, range: a..<b) else { continue }
            var piece = span
            piece.text = sub
            let absRange = (sStart + a)..<(sStart + b)
            if let hit = overlapping.first(where: { $0.element.range.lowerBound <= absRange.lowerBound && $0.element.range.upperBound >= absRange.upperBound }) {
                let isCur = hit.element.isCurrent || (activeIndex == hit.offset)
                piece.background = isCur ? activeBg : bg
                if let c = isCur ? activeFg : fg { piece.color = c }
            }
            out.append(piece)
        }
    }
    return out
}

// MARK: - MarkdownStyle & Sub-Styles (`rune_kit::markdown::style`)

public struct MarkdownTaskPaint: Sendable, Equatable {
    public var fillOn: Color
    public var borderOn: Color
    public var borderOff: Color
    public var fillOff: Color
    public var hover: Color
    public var focusRing: Color
    public var mark: Color
    public var check: SVGIcon
    public var radius: Float
    public var motion: Spring
    public var size: Float
    public var left: Float
    public var top: Float?
}

public struct MarkdownQuoteLook: Sendable, Equatable, Hashable {
    public var width: Float
    public var pad: Float
    public var text: Color?

    public init(width: Float = 2.0, pad: Float = 12.0, text: Color? = nil) {
        self.width = width
        self.pad = pad
        self.text = text
    }
}

public struct MarkdownShellLook: Sendable, Equatable, Hashable {
    public var fill: Color
    public var border: Color
    public var text: Color

    public init(fill: Color, border: Color, text: Color) {
        self.fill = fill
        self.border = border
        self.text = text
    }
}

public struct MarkdownTableFrame: Sendable, Equatable, Hashable {
    public var fill: Color
    public var ring: Color
    public var pad: Float

    public init(fill: Color, ring: Color, pad: Float) {
        self.fill = fill
        self.ring = ring
        self.pad = pad
    }
}

public struct MarkdownTableBody: Sendable, Equatable {
    public var fill: Color
    public var radius: Float
    public var shadows: [Shadow]

    public init(fill: Color, radius: Float, shadows: [Shadow]) {
        self.fill = fill
        self.radius = radius
        self.shadows = shadows
    }
}

public struct MarkdownDiagramPaint: Sendable, Equatable, Hashable {
    public var text: Color
    public var muted: Color
    public var surface: Color
    public var surfaceBorder: Color
    public var nodeFill: Color
    public var nodeBorder: Color
    public var line: Color
    public var clusterFill: Color
    public var noteFill: Color
    public var noteBorder: Color
    public var font: TextStyle
    public var maxWidth: Float
    public var minScale: Float
    public var hover: Color
    public var hoverNeighbours: Bool
}

public enum MarkdownLinkIconPosition: Sendable, Equatable, Hashable {
    case leading(gap: Float, size: Float)
    case trailing(gap: Float, size: Float)
}

/// Visual tokens for a rendered Markdown document (`rune_kit::markdown::MarkdownStyle`).
public struct MarkdownStyle: Sendable, Equatable {
    public var text: Color
    public var muted: Color
    public var accent: Color
    public var linkUnderline: Color
    public var codeBg: Color
    public var codeBlockFill: Color
    public var codeBlockBorder: Color
    public var quoteRule: Color
    public var quote: MarkdownQuoteLook
    public var rule: Color
    public var body: TextStyle
    public var headings: [TextStyle]
    public var codeBlock: TextStyle
    public var codeText: Color?
    public var plainCodeText: Color?
    public var shell: MarkdownShellLook?
    public var linkHover: Color?
    public var listOutside: Bool
    public var listNested: [Float]?
    public var tableAlign: Bool
    public var inlineCodeScale: Float
    public var inlineCodeWeight: Float
    public var inlineCodePad: Float
    public var codeBlockPad: [Float]
    public var listIndent: Float
    public var listGap: Float
    public var strongWeight: Float
    public var tableOutline: Color?
    public var tableRule: Color
    public var tableHeadFill: Color
    public var tableHeadText: Color
    public var tableHeadRule: Color?
    public var tableHeadWeight: Float?
    public var tableMinColumn: Float
    public var tableTabular: Bool
    public var tableFont: TextStyle?
    public var tablePad: [Float]
    public var tableFlushLeft: Bool
    public var tableFrame: MarkdownTableFrame?
    public var tableBody: MarkdownTableBody?
    public var tableHeadPad: [Float]?
    public var tableFullWidth: Bool
    public var tableMargin: [Float]
    public var codeMargin: [Float]
    public var tableBar: [Color]?
    public var textWidth: Float?
    public var wideFade: Float
    public var linkIcon: MarkdownLinkIconPosition?
    public var diffAdd: Color
    public var diffRemove: Color
    public var diffAddText: Color
    public var diffRemoveText: Color
    public var diffHues: [Color]
    public var diffHunk: Color
    public var syntax: SyntaxTheme
    public var highlight: Bool
    public var selection: Color
    public var highlightBg: Color
    public var highlightFg: Color?
    public var highlightRing: (Color, Float)?
    public var highlightCurrentBg: Color
    public var highlightCurrentFg: Color?
    public var highlightCurrentRing: (Color, Float)?
    public var task: MarkdownTaskPaint
    public var diagram: MarkdownDiagramPaint

    public static func == (lhs: MarkdownStyle, rhs: MarkdownStyle) -> Bool {
        lhs.text == rhs.text && lhs.muted == rhs.muted && lhs.accent == rhs.accent &&
        lhs.codeBlockFill == rhs.codeBlockFill && lhs.codeBlockBorder == rhs.codeBlockBorder &&
        lhs.quote == rhs.quote && lhs.rule == rhs.rule && lhs.body == rhs.body &&
        lhs.headings == rhs.headings && lhs.codeBlock == rhs.codeBlock &&
        lhs.tableMargin == rhs.tableMargin && lhs.codeMargin == rhs.codeMargin &&
        lhs.tableFullWidth == rhs.tableFullWidth && lhs.textWidth == rhs.textWidth &&
        lhs.highlight == rhs.highlight && lhs.syntax == rhs.syntax && lhs.diagram == rhs.diagram
    }

    public static func fromKit(_ k: Kit) -> MarkdownStyle {
        let c = k.c
        let body = TextStyle(size: k.ty.body.size, weight: k.ty.body.weight, lineHeight: 22.4, family: k.ty.body.family)
        func heading(_ size: Float, _ lh: Float) -> TextStyle {
            TextStyle(size: size, weight: 600, lineHeight: lh, family: body.family)
        }
        return MarkdownStyle(
            text: c.textBase,
            muted: c.textMuted,
            accent: c.textAccent,
            linkUnderline: k.alpha(c.textAccent, 0.4),
            codeBg: k.alpha(c.textBase, 0.08),
            codeBlockFill: c.layer01,
            codeBlockBorder: c.borderMuted,
            quoteRule: c.layer03,
            quote: MarkdownQuoteLook(width: 2.0, pad: 12.0, text: nil),
            rule: c.borderBase,
            body: body,
            headings: [heading(17, 24), heading(15, 24), heading(13, 20), heading(13, 20)],
            codeBlock: TextStyle(size: 13, weight: k.ty.mono.weight, lineHeight: 20, family: k.ty.mono.family),
            codeText: nil,
            plainCodeText: nil,
            shell: nil,
            linkHover: nil,
            listOutside: false,
            listNested: nil,
            tableAlign: true,
            inlineCodeScale: 0.9,
            inlineCodeWeight: 400,
            inlineCodePad: 3.5,
            codeBlockPad: [12, 12],
            listIndent: 32,
            listGap: 4,
            strongWeight: 670,
            tableOutline: c.borderMuted,
            tableRule: c.borderMuted,
            tableHeadFill: c.layer01,
            tableHeadText: c.textBase,
            tableHeadRule: nil,
            tableHeadWeight: nil,
            tableMinColumn: 120,
            tableTabular: true,
            tableFont: nil,
            tablePad: [10, 6],
            tableFlushLeft: false,
            tableFrame: nil,
            tableBody: nil,
            tableHeadPad: nil,
            tableFullWidth: false,
            tableMargin: [12, 16],
            codeMargin: [12, 24],
            tableBar: nil,
            textWidth: nil,
            wideFade: 12,
            linkIcon: nil,
            diffAdd: c.layer01.mix(with: c.success.icon, t: k.dark ? 0.11 : 0.14),
            diffRemove: c.layer01.mix(with: c.danger.icon, t: k.dark ? 0.11 : 0.14),
            diffAddText: c.textBase,
            diffRemoveText: c.textBase,
            diffHues: [c.success.icon, c.danger.icon],
            diffHunk: c.textMuted,
            syntax: SyntaxTheme.fromKit(k),
            highlight: true,
            selection: k.selection(),
            highlightBg: k.dark ? k.alpha(c.warning.icon, 0.24) : oklcha(0.86, 0.15, 85, 0.42),
            highlightFg: nil,
            highlightRing: nil,
            highlightCurrentBg: k.dark ? k.alpha(c.warning.icon, 0.40) : oklcha(0.82, 0.17, 75, 0.58),
            highlightCurrentFg: nil,
            highlightCurrentRing: (k.dark ? c.warning.icon : oklch(0.66, 0.16, 70), 1.0),
            task: MarkdownTaskPaint(
                fillOn: c.surfaceWeak,
                borderOn: c.stdBorder,
                borderOff: c.borderWeak,
                fillOff: .transparent,
                hover: c.surfaceHover,
                focusRing: c.borderActive,
                mark: c.stdIcon,
                check: k.glyph.check,
                radius: k.radius.sm,
                motion: k.motion.control,
                size: 16,
                left: 8,
                top: nil
            ),
            diagram: MarkdownDiagramPaint(
                text: c.textBase,
                muted: c.textMuted,
                surface: c.bgBase,
                surfaceBorder: c.borderMuted,
                nodeFill: c.layer01,
                nodeBorder: k.alpha(c.textBase, 0.2),
                line: k.alpha(c.textBase, 0.42),
                clusterFill: k.alpha(c.textBase, k.dark ? 0.04 : 0.025),
                noteFill: c.warning.bg,
                noteBorder: c.warning.border,
                font: TextStyle(size: 13, weight: 400, lineHeight: 18, family: k.ty.body.family),
                maxWidth: 680,
                minScale: 0.6,
                hover: k.alpha(c.textBase, 0.9),
                hoverNeighbours: false
            )
        )
    }

    public static func neutral(dark: Bool) -> MarkdownStyle {
        fromKit(Kit.neutral(dark: dark))
    }

    // MARK: Style Builders

    private static func pts(_ v: Float) -> Float { (v.isFinite && v > 0) ? v : 0 }

    public func text(_ color: Color) -> MarkdownStyle { var s = self; s.text = color; return s }
    public func muted(_ color: Color) -> MarkdownStyle { var s = self; s.muted = color; return s }
    public func link(_ color: Color) -> MarkdownStyle { var s = self; s.accent = color; s.linkUnderline = color.alpha(0.4); return s }
    public func linkUnderline(_ color: Color) -> MarkdownStyle { var s = self; s.linkUnderline = color; return s }
    public func inlineCodeBg(_ color: Color) -> MarkdownStyle { var s = self; s.codeBg = color; return s }
    public func codeBlock(_ fill: Color, _ border: Color) -> MarkdownStyle { var s = self; s.codeBlockFill = fill; s.codeBlockBorder = border; return s }
    public func codeBlockPadding(_ x: Float, _ y: Float) -> MarkdownStyle { var s = self; s.codeBlockPad = [x, y]; return s }
    public func list(_ indent: Float, _ gap: Float) -> MarkdownStyle { var s = self; s.listIndent = indent; s.listGap = gap; return s }
    public func quoteRule(_ color: Color) -> MarkdownStyle { var s = self; s.quoteRule = color; return s }
    public func quote(_ rule: Color, width: Float, pad: Float, text: Color) -> MarkdownStyle {
        var s = self
        s.quoteRule = rule
        s.quote = MarkdownQuoteLook(width: max(0, width), pad: max(0, pad), text: text)
        return s
    }
    public func linkHover(_ color: Color) -> MarkdownStyle { var s = self; s.linkHover = color; return s }
    public func codeBlockText(_ color: Color) -> MarkdownStyle { var s = self; s.codeText = color; return s }
    public func plainCodeText(_ color: Color) -> MarkdownStyle { var s = self; s.plainCodeText = color; return s }
    public func shellCode(fill: Color, border: Color, text: Color) -> MarkdownStyle {
        var s = self
        s.shell = MarkdownShellLook(fill: fill, border: border, text: text)
        return s
    }
    public func listMarkersOutside(_ on: Bool) -> MarkdownStyle { var s = self; s.listOutside = on; return s }
    public func listNestedIndent(bullets: Float, numbers: Float) -> MarkdownStyle {
        var s = self
        s.listNested = [max(0, bullets), max(0, numbers)]
        return s
    }
    public func taskCheckbox(
        size: Float,
        radius: Float,
        left: Float,
        top: Float? = nil,
        fillOn: Color,
        mark: Color,
        fillOff: Color,
        borderOff: Color
    ) -> MarkdownStyle {
        var s = self
        s.task.size = max(0, size)
        s.task.radius = max(0, radius)
        s.task.left = max(0, left)
        s.task.top = top
        s.task.fillOn = fillOn
        s.task.borderOn = fillOn
        s.task.mark = mark
        s.task.fillOff = fillOff
        s.task.borderOff = borderOff
        return s
    }
    public func rule(_ color: Color) -> MarkdownStyle { var s = self; s.rule = color; return s }
    public func bodyFont(_ f: TextStyle) -> MarkdownStyle { var s = self; s.body = f; return s }
    public func headingFont(_ level: Int, _ f: TextStyle) -> MarkdownStyle {
        var s = self
        let idx = min(max(level, 1), 4) - 1
        s.headings[idx] = f
        if idx == 2 { s.headings[3] = f }
        return s
    }
    public func codeBlockFont(_ f: TextStyle) -> MarkdownStyle { var s = self; s.codeBlock = f; return s }
    public func inlineCodeFont(scale: Float, weight: Float) -> MarkdownStyle {
        var s = self
        s.inlineCodeScale = scale
        s.inlineCodeWeight = weight
        return s
    }
    public func inlineCodePad(_ pad: Float) -> MarkdownStyle { var s = self; s.inlineCodePad = pad; return s }
    public func strongWeight(_ w: Float) -> MarkdownStyle { var s = self; s.strongWeight = w; return s }
    public func textWidth(_ points: Float) -> MarkdownStyle {
        var s = self
        s.textWidth = (points.isFinite && points > 0) ? points : nil
        return s
    }
    public func wideFade(_ points: Float) -> MarkdownStyle {
        var s = self
        s.wideFade = points.isFinite ? max(0, points) : 0
        return s
    }
    public func codeMargin(top: Float, bottom: Float) -> MarkdownStyle {
        var s = self
        s.codeMargin = [Self.pts(top), Self.pts(bottom)]
        return s
    }
    public func diff(added: Color, removed: Color) -> MarkdownStyle {
        var s = self
        s.diffAdd = added
        s.diffRemove = removed
        return s
    }
    public func diffText(added: Color, removed: Color) -> MarkdownStyle {
        var s = self
        s.diffAddText = added
        s.diffRemoveText = removed
        return s
    }
    public func diffTextTint(_ amount: Float) -> MarkdownStyle {
        var s = self
        let t = max(0, min(1, amount))
        s.diffAddText = s.text.mix(with: s.diffHues[0], t: t)
        s.diffRemoveText = s.text.mix(with: s.diffHues[1], t: t)
        return s
    }
    public func diffHunk(_ color: Color) -> MarkdownStyle { var s = self; s.diffHunk = color; return s }
    public func syntax(_ kind: Syntax, _ color: Color) -> MarkdownStyle { var s = self; s.syntax = s.syntax.with(kind, color); return s }
    public func syntaxTheme(_ theme: SyntaxTheme) -> MarkdownStyle { var s = self; s.syntax = theme; return s }
    public func syntaxHighlight(_ on: Bool) -> MarkdownStyle { var s = self; s.highlight = on; return s }
    public func selection(_ color: Color) -> MarkdownStyle { var s = self; s.selection = color; return s }
    public func diagram(nodeFill: Color, nodeBorder: Color, line: Color) -> MarkdownStyle {
        var s = self
        s.diagram.nodeFill = nodeFill
        s.diagram.nodeBorder = nodeBorder
        s.diagram.line = line
        return s
    }
    public func diagramSurface(fill: Color, border: Color, subgraph: Color) -> MarkdownStyle {
        var s = self
        s.diagram.surface = fill
        s.diagram.surfaceBorder = border
        s.diagram.clusterFill = subgraph
        return s
    }
    public func diagramTypography(font: TextStyle, maxWidth: Float, minScale: Float) -> MarkdownStyle {
        var s = self
        s.diagram.font = font
        s.diagram.maxWidth = maxWidth
        s.diagram.minScale = minScale
        return s
    }
    public func diagramHover(_ color: Color, neighbours: Bool = false) -> MarkdownStyle {
        var s = self
        s.diagram.hover = color
        s.diagram.hoverNeighbours = neighbours
        return s
    }
    public func highlightBg(_ color: Color) -> MarkdownStyle { var s = self; s.highlightBg = color; return s }
    public func highlightFg(_ color: Color?) -> MarkdownStyle { var s = self; s.highlightFg = color; return s }
    public func highlightRing(_ color: Color, _ width: Float = 1.0) -> MarkdownStyle {
        var s = self
        s.highlightRing = (color, max(0, width))
        return s
    }
    public func highlightCurrent(bg: Color, fg: Color? = nil, ring: (Color, Float)? = nil) -> MarkdownStyle {
        var s = self
        s.highlightCurrentBg = bg
        s.highlightCurrentFg = fg
        s.highlightCurrentRing = ring.map { ($0.0, max(0, $0.1)) }
        return s
    }
    public func linkIcon(_ position: MarkdownLinkIconPosition?) -> MarkdownStyle { var s = self; s.linkIcon = position; return s }

    // Table styles
    public func tableOutline(_ color: Color?) -> MarkdownStyle { var s = self; s.tableOutline = color; return s }
    public func tableRules(_ color: Color) -> MarkdownStyle { var s = self; s.tableRule = color; return s }
    public func tableHeader(fill: Color, text: Color) -> MarkdownStyle {
        var s = self
        s.tableHeadFill = fill
        s.tableHeadText = text
        return s
    }
    public func tableHeaderText(_ color: Color) -> MarkdownStyle { var s = self; s.tableHeadText = color; return s }
    public func tableHeaderRule(_ color: Color) -> MarkdownStyle { var s = self; s.tableHeadRule = color; return s }
    public func tableHeaderWeight(_ w: Float) -> MarkdownStyle { var s = self; s.tableHeadWeight = w; return s }
    public func tableTabularFigures(_ on: Bool) -> MarkdownStyle { var s = self; s.tableTabular = on; return s }
    public func tableMinColumn(_ points: Float) -> MarkdownStyle { var s = self; s.tableMinColumn = Self.pts(points); return s }
    public func tableFont(_ f: TextStyle) -> MarkdownStyle { var s = self; s.tableFont = f; return s }
    public func tableCellPadding(x: Float, y: Float) -> MarkdownStyle { var s = self; s.tablePad = [Self.pts(x), Self.pts(y)]; return s }
    public func tableFlushLeft(_ on: Bool) -> MarkdownStyle { var s = self; s.tableFlushLeft = on; return s }
    public func tableFrame(fill: Color, ring: Color, pad: Float) -> MarkdownStyle {
        var s = self
        s.tableFrame = MarkdownTableFrame(fill: fill, ring: ring, pad: Self.pts(pad))
        return s
    }
    public func tableBody(fill: Color, radius: Float, shadows: [Shadow]) -> MarkdownStyle {
        var s = self
        s.tableBody = MarkdownTableBody(fill: fill, radius: Self.pts(radius), shadows: shadows)
        return s
    }
    public func tableHeaderPad(x: Float, y: Float) -> MarkdownStyle { var s = self; s.tableHeadPad = [Self.pts(x), Self.pts(y)]; return s }
    public func tableFullWidth(_ on: Bool) -> MarkdownStyle { var s = self; s.tableFullWidth = on; return s }
    public func tableColumnAlign(_ on: Bool) -> MarkdownStyle { var s = self; s.tableAlign = on; return s }
    public func tableMargin(top: Float, bottom: Float) -> MarkdownStyle { var s = self; s.tableMargin = [Self.pts(top), Self.pts(bottom)]; return s }
    public func tableScrollBar(thumb: Color, thumbHover: Color) -> MarkdownStyle { var s = self; s.tableBar = [thumb, thumbHover]; return s }

    public func tableCard(_ k: Kit) -> MarkdownStyle {
        let c = k.c
        let raised = k.shadowLayers(k.elevation.raised)
        return tableFrame(fill: c.layer01, ring: c.borderMuted, pad: 2.0)
            .tableBody(fill: c.bgBase, radius: 4.0, shadows: raised)
            .tableRules(c.borderMuted)
            .tableHeaderText(c.textFaint)
            .tableHeaderWeight(500)
            .tableHeaderPad(x: 12, y: 8)
            .tableCellPadding(x: 12, y: 10)
            .tableFont(TextStyle(size: k.ty.uiCompact.size, weight: 440, lineHeight: k.ty.uiCompact.lineHeight, letterSpacing: -0.04, family: k.ty.uiCompact.family))
            .tableTabularFigures(true)
            .tableFullWidth(true)
            .tableMargin(top: 16, bottom: 16)
    }

    func mermaidTheme() -> MermaidTheme {
        var t = MermaidTheme.neutral(dark: text.luminance > diagram.surface.luminance).minScale(diagram.minScale)
        t.text = diagram.text
        t.muted = diagram.muted
        t.surface = diagram.surface
        t.surfaceBorder = diagram.surfaceBorder
        t.nodeFill = diagram.nodeFill
        t.nodeBorder = diagram.nodeBorder
        t.line = diagram.line
        t.clusterFill = diagram.clusterFill
        t.noteFill = diagram.noteFill
        t.noteBorder = diagram.noteBorder
        t.maxWidth = diagram.maxWidth
        return t
    }
}

// MARK: - Frame Contexts & Callbacks (`rune_kit::markdown`)

public struct MarkdownDiagramFrameContext: Sendable, Equatable {
    public var index: Int
    public var source: String
    public var open: Bool

    public init(index: Int, source: String, open: Bool) {
        self.index = index
        self.source = source
        self.open = open
    }
}

public struct MarkdownCodeFrameContext: Sendable, Equatable {
    public var index: Int
    public var source: String
    public var language: String?
    public var open: Bool

    public init(index: Int, source: String, language: String?, open: Bool) {
        self.index = index
        self.source = source
        self.language = language
        self.open = open
    }
}

public struct MarkdownQuoteFrameContext: Sendable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct MarkdownImageFrameContext: Sendable, Equatable {
    public var src: String
    public var alt: String
    public var title: String

    public init(src: String, alt: String, title: String) {
        self.src = src
        self.alt = alt
        self.title = title
    }
}

// MARK: - Fluent `Markdown` Document & `MarkdownView<State>` Builder (`rune_kit::markdown::Markdown`)

/// Fluent, full-parity CommonMark + GFM Markdown component (`rune_kit::markdown::Markdown`).
public struct Markdown: Sendable {
    public var source: String
    public var customStyle: MarkdownStyle?
    public var revealDelay: Float = -1.0
    public var isStreaming: Bool = false
    public var callerBlockKeys: [(offset: Int, key: String)] = []
    public var highlightsList: [(ranges: [Range<Int>], style: MarkdownHighlight)] = []
    public var isAutolinkEnabled: Bool = true
    public var isSelectable: Bool = false
    public var copySourceMode: Bool = false
    public var tentativeDirection: MarkdownDirection?
    public var isScrollWide: Bool = false
    public var areTasksReadOnly: Bool = false
    public var syntaxHighlighter: SyntaxHighlighter = .builtin
    public var linkLookFn: (@Sendable (String) -> (color: Color?, underline: Bool, weight: Float?, hoverColor: Color?)?)?
    public var linkRingFn: (@Sendable (String) -> (Color, Float)?)?
    public var linkHelpFn: (@Sendable (String) -> String?)?
    public var codeLinkMatchFn: (@Sendable (String) -> (url: String, color: Color)?)?
    public var imageAltVisible: Bool = false

    public init(_ source: String) {
        self.source = source
    }

    public func style(_ style: MarkdownStyle) -> Markdown { var c = self; c.customStyle = style; return c }
    public func reveal(_ seconds: Float) -> Markdown { var c = self; c.revealDelay = seconds; return c }
    public func streaming(_ on: Bool = true) -> Markdown { var c = self; c.isStreaming = on; return c }
    public func blockKeys(_ keys: [(offset: Int, key: String)]) -> Markdown { var c = self; c.callerBlockKeys = keys; return c }
    public func highlights(_ items: [(ranges: [Range<Int>], style: MarkdownHighlight)]) -> Markdown { var c = self; c.highlightsList.append(contentsOf: items); return c }
    public func highlight(_ range: Range<Int>, _ style: MarkdownHighlight = .match()) -> Markdown { var c = self; c.highlightsList.append(([range], style)); return c }
    public func highlight(_ ranges: [Range<Int>], _ style: MarkdownHighlight = .match()) -> Markdown { var c = self; c.highlightsList.append((ranges, style)); return c }
    public func autolink(_ on: Bool) -> Markdown { var c = self; c.isAutolinkEnabled = on; return c }
    public func selectable(_ on: Bool = true) -> Markdown { var c = self; c.isSelectable = on; return c }
    public func copySource(_ on: Bool = true) -> Markdown { var c = self; c.copySourceMode = on; return c }
    public func dirTentative(_ dir: MarkdownDirection?) -> Markdown { var c = self; c.tentativeDirection = dir; return c }
    public func scrollWide(_ on: Bool = true) -> Markdown { var c = self; c.isScrollWide = on; return c }
    public func tasksReadOnly(_ on: Bool = true) -> Markdown { var c = self; c.areTasksReadOnly = on; return c }
    public func highlighter(_ hl: SyntaxHighlighter) -> Markdown { var c = self; c.syntaxHighlighter = hl; return c }
    public func codeLink(match: @escaping @Sendable (String) -> String?, color: Color) -> Markdown {
        var c = self
        c.codeLinkMatchFn = { code in match(code).map { ($0, color) } }
        return c
    }
    public func linkStyle(_ fn: @escaping @Sendable (String) -> (color: Color?, underline: Bool, weight: Float?, hoverColor: Color?)?) -> Markdown {
        var c = self; c.linkLookFn = fn; return c
    }
    public func linkRing(_ fn: @escaping @Sendable (String) -> (Color, Float)?) -> Markdown {
        var c = self; c.linkRingFn = fn; return c
    }
    public func linkHelp(_ fn: @escaping @Sendable (String) -> String?) -> Markdown {
        var c = self; c.linkHelpFn = fn; return c
    }
    public func images(_ showAlt: Bool = true) -> Markdown {
        var c = self; c.imageAltVisible = showAlt; return c
    }

    // State-bound view elevation helpers
    public func view<State>(for _: State.Type = State.self) -> MarkdownView<State> {
        MarkdownView<State>(config: self)
    }

    public func onLink<State>(_ fn: @escaping @Sendable (inout State, String, inout Tx) -> Void) -> MarkdownView<State> {
        MarkdownView<State>(config: self).onLink(fn)
    }
    public func onLinkSecondary<State>(_ fn: @escaping @Sendable (inout State, String, inout Tx) -> Void) -> MarkdownView<State> {
        MarkdownView<State>(config: self).onLinkSecondary(fn)
    }
    public func onTask<State>(_ fn: @escaping @Sendable (inout State, String, Int, Bool, inout Tx) -> Void) -> MarkdownView<State> {
        MarkdownView<State>(config: self).onTask(fn)
    }
    public func diagramFrame<State>(_ fn: @escaping @Sendable (El<State>, MarkdownDiagramFrameContext) -> El<State>) -> MarkdownView<State> {
        MarkdownView<State>(config: self).diagramFrame(fn)
    }
    public func codeFrame<State>(_ fn: @escaping @Sendable (El<State>, MarkdownCodeFrameContext) -> El<State>) -> MarkdownView<State> {
        MarkdownView<State>(config: self).codeFrame(fn)
    }
    public func quoteFrame<State>(_ fn: @escaping @Sendable (El<State>, MarkdownQuoteFrameContext) -> El<State>) -> MarkdownView<State> {
        MarkdownView<State>(config: self).quoteFrame(fn)
    }
    public func imageFrame<State>(_ fn: @escaping @Sendable (El<State>, MarkdownImageFrameContext) -> El<State>) -> MarkdownView<State> {
        MarkdownView<State>(config: self).imageFrame(fn)
    }

    // Pure document operations (no State needed)
    public func document() -> MarkdownParsedDoc {
        let stream = MarkdownTailStream(autolink: isAutolinkEnabled)
        var s = stream
        s.reset(source)
        return s.document(streaming: isStreaming)
    }

    public func blocks() -> [MarkdownDocBlock] {
        document().blocks
    }

    public func plainText() -> String {
        MarkdownPlain.render(document())
    }

    public func find(_ query: String, caseSensitivity: MarkdownCase = .insensitive) -> [Range<Int>] {
        let doc = MarkdownDocCache.shared.docCached(source, autolink: isAutolinkEnabled)
        return MarkdownFind.findBounds(in: source, doc: doc, query: query, caseSensitivity: caseSensitivity)
    }

    public func findRanges(_ query: String, caseSensitivity: MarkdownCase = .insensitive) -> [[Range<Int>]] {
        let doc = MarkdownDocCache.shared.docCached(source, autolink: isAutolinkEnabled)
        return MarkdownFind.findAll(in: source, doc: doc, query: query, caseSensitivity: caseSensitivity)
    }

    public static func highlightKey(_ index: Int) -> String {
        "h\(index)"
    }

    public func build<State>(_ kit: Kit) -> El<State> {
        MarkdownView<State>(config: self).build(kit)
    }

    public func render<State>(_ style: MarkdownStyle) -> El<State> {
        MarkdownView<State>(config: self).render(style)
    }
}

/// Stateful interactive `MarkdownView<State>` holding link, task, and frame callbacks (`rune_kit::markdown::Markdown`).
public struct MarkdownView<State>: Sendable {
    public var config: Markdown
    public var onLinkHandler: (@Sendable (inout State, String, inout Tx) -> Void)?
    public var onLinkSecondaryHandler: (@Sendable (inout State, String, inout Tx) -> Void)?
    public var onTaskHandler: (@Sendable (inout State, String, Int, Bool, inout Tx) -> Void)?
    public var diagramFrameHandler: (@Sendable (El<State>, MarkdownDiagramFrameContext) -> El<State>)?
    public var codeFrameHandler: (@Sendable (El<State>, MarkdownCodeFrameContext) -> El<State>)?
    public var quoteFrameHandler: (@Sendable (El<State>, MarkdownQuoteFrameContext) -> El<State>)?
    public var imageFrameHandler: (@Sendable (El<State>, MarkdownImageFrameContext) -> El<State>)?

    public init(_ source: String) {
        self.config = Markdown(source)
    }

    public init(config: Markdown) {
        self.config = config
    }

    public func style(_ style: MarkdownStyle) -> Self { var c = self; c.config.customStyle = style; return c }
    public func reveal(_ seconds: Float) -> Self { var c = self; c.config.revealDelay = seconds; return c }
    public func streaming(_ on: Bool = true) -> Self { var c = self; c.config.isStreaming = on; return c }
    public func blockKeys(_ keys: [(offset: Int, key: String)]) -> Self { var c = self; c.config.callerBlockKeys = keys; return c }
    public func highlights(_ items: [(ranges: [Range<Int>], style: MarkdownHighlight)]) -> Self { var c = self; c.config.highlightsList.append(contentsOf: items); return c }
    public func highlight(_ range: Range<Int>, _ style: MarkdownHighlight = .match()) -> Self { var c = self; c.config.highlightsList.append(([range], style)); return c }
    public func autolink(_ on: Bool) -> Self { var c = self; c.config.isAutolinkEnabled = on; return c }
    public func selectable(_ on: Bool = true) -> Self { var c = self; c.config.isSelectable = on; return c }
    public func copySource(_ on: Bool = true) -> Self { var c = self; c.config.copySourceMode = on; return c }
    public func dirTentative(_ dir: MarkdownDirection?) -> Self { var c = self; c.config.tentativeDirection = dir; return c }
    public func scrollWide(_ on: Bool = true) -> Self { var c = self; c.config.isScrollWide = on; return c }
    public func tasksReadOnly(_ on: Bool = true) -> Self { var c = self; c.config.areTasksReadOnly = on; return c }
    public func highlighter(_ hl: SyntaxHighlighter) -> Self { var c = self; c.config.syntaxHighlighter = hl; return c }
    public func codeLink(match: @escaping @Sendable (String) -> String?, color: Color) -> Self {
        var c = self; c.config = c.config.codeLink(match: match, color: color); return c
    }
    public func linkStyle(_ fn: @escaping @Sendable (String) -> (color: Color?, underline: Bool, weight: Float?, hoverColor: Color?)?) -> Self {
        var c = self; c.config.linkLookFn = fn; return c
    }
    public func linkRing(_ fn: @escaping @Sendable (String) -> (Color, Float)?) -> Self {
        var c = self; c.config.linkRingFn = fn; return c
    }
    public func linkHelp(_ fn: @escaping @Sendable (String) -> String?) -> Self {
        var c = self; c.config.linkHelpFn = fn; return c
    }
    public func onLink(_ fn: @escaping @Sendable (inout State, String, inout Tx) -> Void) -> Self {
        var c = self; c.onLinkHandler = fn; return c
    }
    public func onLinkSecondary(_ fn: @escaping @Sendable (inout State, String, inout Tx) -> Void) -> Self {
        var c = self; c.onLinkSecondaryHandler = fn; return c
    }
    public func onTask(_ fn: @escaping @Sendable (inout State, String, Int, Bool, inout Tx) -> Void) -> Self {
        var c = self; c.onTaskHandler = fn; return c
    }
    public func diagramFrame(_ fn: @escaping @Sendable (El<State>, MarkdownDiagramFrameContext) -> El<State>) -> Self {
        var c = self; c.diagramFrameHandler = fn; return c
    }
    public func codeFrame(_ fn: @escaping @Sendable (El<State>, MarkdownCodeFrameContext) -> El<State>) -> Self {
        var c = self; c.codeFrameHandler = fn; return c
    }
    public func quoteFrame(_ fn: @escaping @Sendable (El<State>, MarkdownQuoteFrameContext) -> El<State>) -> Self {
        var c = self; c.quoteFrameHandler = fn; return c
    }
    public func imageFrame(_ fn: @escaping @Sendable (El<State>, MarkdownImageFrameContext) -> El<State>) -> Self {
        var c = self; c.imageFrameHandler = fn; return c
    }

    public func build(_ kit: Kit) -> El<State> {
        render(config.customStyle ?? MarkdownStyle.fromKit(kit))
    }

    public func render(_ style: MarkdownStyle) -> El<State> {
        let doc = config.document()
        let keys = matchBlockKeys(starts: doc.blockStarts, callerKeys: config.callerBlockKeys)
        let renderer = MarkdownRenderer<State>(view: self, style: style, doc: doc)
        return renderer.renderRoot(keys: keys)
    }

    private func matchBlockKeys(starts: [Int], callerKeys: [(offset: Int, key: String)]) -> [String] {
        guard !callerKeys.isEmpty else { return [] }
        return starts.map { s in
            callerKeys.first(where: { $0.offset == s })?.key ?? ""
        }
    }
}

// MARK: - Internal Renderer (`rune_kit::markdown::render` + `table`)

private final class MarkdownRenderer<State> {
    let view: MarkdownView<State>
    let s: MarkdownStyle
    let doc: MarkdownParsedDoc
    var nextSource = 0
    var nextTask = 0
    var currentBlockKey = "b0"
    var flow = FlowState()

    struct FlowState {
        var lists = 0
        var inset: Float = 0
        var ink: Color? = nil
    }

    init(view: MarkdownView<State>, style: MarkdownStyle, doc: MarkdownParsedDoc) {
        self.view = view
        self.s = style
        self.doc = doc
    }

    func renderRoot(keys: [String]) -> El<State> {
        blocksIn(doc.blocks, maps: doc.maps, keys: keys, topLevel: true, inItem: false)
    }

    private func renderedKeys(count: Int, keys: [String]) -> [String] {
        var used: [String] = []
        var out: [String] = []
        for i in 0..<count {
            if i < keys.count, !keys[i].isEmpty, !used.contains(keys[i]) {
                used.append(keys[i])
                out.append(keys[i])
            } else {
                var cand = "b\(i)"
                var n = 0
                let rest = i + 1 < keys.count ? Array(keys[(i + 1)...]) : []
                while used.contains(cand) || rest.contains(cand) {
                    cand = "b\(n)"
                    n += 1
                }
                used.append(cand)
                out.append(cand)
            }
        }
        return out
    }

    private func margins(_ b: MarkdownDocBlock) -> (top: Float, bottom: Float) {
        switch b {
        case .para: return (0, 12)
        case .heading(1, _): return (28, 12)
        case .heading(2, _): return (24, 10)
        case .heading: return (20, 8)
        case .code, .diff, .mermaid: return (s.codeMargin[0], s.codeMargin[1])
        case .list: return (8, 12)
        case .quote: return (16, 16)
        case .rule: return (32, 32)
        case .table: return (s.tableMargin[0], s.tableMargin[1])
        case .image: return (24, 24)
        }
    }

    private func collapsed(_ b: MarkdownDocBlock, index i: Int, inItem: Bool) -> (top: Float, bottom: Float) {
        let base: (Float, Float)
        switch b {
        case .para where inItem:
            base = (i == 0 ? 0 : 8, i == 0 ? 0 : 12)
        case .list where inItem:
            base = (4, 4)
        default:
            base = margins(b)
        }
        let first: Float?
        let last: Float?
        switch b {
        case let .quote(inner):
            first = inner.first.map { collapsed($0, index: 0, inItem: false).top }
            last = inner.last.map { collapsed($0, index: inner.count - 1, inItem: false).bottom }
        case let .list(_, items):
            first = items.first?.first.map { collapsed($0, index: 0, inItem: true).top }
            last = items.last.map { item in
                let tail = item.last.map { collapsed($0, index: item.count - 1, inItem: true).bottom } ?? 0
                return max(tail, s.listGap)
            }
        default:
            first = nil
            last = nil
        }
        return (max(first ?? 0, base.0), max(last ?? 0, base.1))
    }

    private func blocksIn(
        _ blocks: [MarkdownDocBlock],
        maps: [MarkdownBlockMap],
        keys: [String],
        topLevel: Bool,
        inItem: Bool
    ) -> El<State> {
        var c: El<State> = col().wFull()
        var prevMb: Float = 0
        var afterHeading = false
        let names = renderedKeys(count: blocks.count, keys: keys)
        var lastDir: MarkdownDirection? = topLevel ? view.config.tentativeDirection : nil

        for (i, b) in blocks.enumerated() {
            let key = names[i]
            let map = i < maps.count ? maps[i] : .none

            if view.config.isStreaming, case let .code(codeStr) = b, codeStr.isEmpty {
                if nextSource < doc.sources.count, doc.sources[nextSource].open, doc.sources[nextSource].length == 0 {
                    nextSource += 1
                    continue
                }
            }

            let (mt, mb) = collapsed(b, index: i, inItem: inItem)
            let top: Float
            if i == 0 {
                top = 0
            } else {
                switch b {
                case .heading, .rule, .image: top = max(mt, prevMb)
                default: top = afterHeading ? prevMb : max(mt, prevMb)
                }
            }

            if topLevel {
                currentBlockKey = key
            }

            let ownDir = MarkdownBidi.blocksDirection([b])
            let resolvedDir = ownDir ?? lastDir
            if let ownDir { lastDir = ownDir }

            var drawn = renderBlock(b, map: map, dir: resolvedDir)
            drawn = drawn.key(key)
            if top > 0 { drawn = drawn.mt(top) }
            c = c.child(drawn)
            prevMb = mb
            if case .heading = b { afterHeading = true } else { afterHeading = false }
        }
        return c
    }

    private func renderBlock(_ b: MarkdownDocBlock, map: MarkdownBlockMap, dir: MarkdownDirection?) -> El<State> {
        let inlMap: MarkdownSpanMap? = if case let .inline(m) = map { m } else { nil }
        let codeMap: MarkdownSpanMap? = if case let .code(m) = map { m } else { nil }

        switch b {
        case let .para(inl):
            return renderPara(inl, map: inlMap, font: s.body, color: flow.ink ?? s.text, dir: dir)

        case let .heading(lvl, inl):
            let clamped = min(max(lvl, 1), 4) - 1
            let hFont = s.headings[clamped]
            let hColor = lvl >= 4 ? s.muted : s.text
            return renderPara(inl, map: inlMap, font: hFont, color: hColor, dir: dir)
                .headingLevel(lvl)

        case let .code(code):
            let idx = nextSource
            nextSource += 1
            let srcMeta = (idx < doc.sources.count && doc.sources[idx].length == code.utf8.count) ? doc.sources[idx] : nil
            let card = renderCode(code, source: srcMeta, map: codeMap)
            if let frameFn = view.codeFrameHandler {
                return col().wFull().child(frameFn(card.key("card"), MarkdownCodeFrameContext(index: idx, source: code, language: srcMeta?.language, open: srcMeta?.open ?? false)))
            }
            return card

        case let .diff(src):
            return renderDiff(src, map: codeMap)

        case let .mermaid(src):
            let idx = nextSource
            nextSource += 1
            let srcMeta = (idx < doc.sources.count && doc.sources[idx].length == src.utf8.count) ? doc.sources[idx] : nil
            return renderMermaidBlock(src, source: srcMeta, map: codeMap, index: idx)

        case let .table(t):
            let (hm, rm): ([MarkdownSpanMap], [[MarkdownSpanMap]]) = if case let .table(head, rows) = map { (head, rows) } else { ([], []) }
            return renderTable(t, headMaps: hm, rowMaps: rm)

        case let .list(start, items):
            return renderList(start: start, items: items, itemMaps: (map.listMaps ?? []))

        case let .quote(inner):
            let savedFlow = flow
            let savedTaskIdx = nextTask
            flow = FlowState(lists: savedFlow.lists, inset: savedFlow.inset + s.quote.width + s.quote.pad, ink: s.quote.text ?? savedFlow.ink)
            let innerMaps = map.quoteMaps ?? []
            let drawn = blocksIn(inner, maps: innerMaps, keys: [], topLevel: false, inItem: false)
            flow = savedFlow
            let qEl: El<State> = row()
                .wFull()
                .child(el().w(s.quote.width).hFull().rounded(min(s.quote.width / 2.0, 1.0)).bg(s.quoteRule))
                .child(drawn.grow(1).shrink(1).pl(s.quote.pad))
            if let qFrame = view.quoteFrameHandler {
                var tIdx = savedTaskIdx
                let plain = MarkdownPlain.render(blocks: inner, tasks: doc.tasks, nextTask: &tIdx)
                return col().wFull().child(qFrame(qEl, MarkdownQuoteFrameContext(text: plain)))
            }
            return qEl

        case let .image(src, alt, title):
            let imgBox: El<State> = col()
                .role(.image)
                .label(alt.isEmpty ? src : alt)
                .wFull()
                .p(8)
                .rounded(6)
                .bg(s.codeBlockFill)
                .border(0.5, s.codeBlockBorder)
                .child(text(alt.isEmpty ? src : alt).font(s.body).color(s.muted))
            if let imgFrame = view.imageFrameHandler {
                return col().wFull().child(imgFrame(imgBox, MarkdownImageFrameContext(src: src, alt: alt, title: title)))
            }
            return imgBox

        case .rule:
            return s.rule.a <= 0 ? el().wFull().h(0) : el().wFull().h(0.5).bg(s.rule).role(.separator)
        }
    }

    private func withCodeLinks(_ inl: MarkdownInline) -> MarkdownInline {
        guard let matcher = view.config.codeLinkMatchFn else { return inl }
        var out = inl
        for sp in inl.spans where sp.style == .code {
            guard !out.links.contains(where: { $0.start <= sp.start && sp.end <= $0.end }),
                  let code = utf8Slice(inl.text, range: sp.start..<sp.end),
                  let (url, _) = matcher(code) else { continue }
            out.links.append(MarkdownLinkSpan(start: sp.start, end: sp.end, url: url))
            out.spans.append(MarkdownStyleSpan(start: sp.start, end: sp.end, style: .link))
        }
        return out
    }

    private func buildTextSpans(_ rawInl: MarkdownInline, font: TextStyle, baseColor: Color) -> [TextSpan] {
        let inl = withCodeLinks(rawInl)
        let bytes = Array(inl.text.utf8)
        guard !bytes.isEmpty else { return [TextSpan("", color: baseColor)] }

        var cuts: Set<Int> = [0, bytes.count]
        for s in inl.spans {
            cuts.insert(max(0, min(bytes.count, s.start)))
            cuts.insert(max(0, min(bytes.count, s.end)))
        }
        for l in inl.links {
            cuts.insert(max(0, min(bytes.count, l.start)))
            cuts.insert(max(0, min(bytes.count, l.end)))
        }
        let sorted = cuts.sorted()
        var spans: [TextSpan] = []

        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            guard a < b, let seg = utf8Slice(inl.text, range: a..<b) else { continue }
            let isCodePad = inl.spans.contains { $0.style == .codePad && $0.start <= a && b <= $0.end }
            let isCode = inl.spans.contains { $0.style == .code && $0.start <= a && b <= $0.end }
            let isStrong = inl.spans.contains { $0.style == .strong && $0.start <= a && b <= $0.end }
            let isEm = inl.spans.contains { $0.style == .em && $0.start <= a && b <= $0.end }
            let isStrike = inl.spans.contains { $0.style == .strike && $0.start <= a && b <= $0.end }
            let link = inl.links.first { $0.start <= a && b <= $0.end }

            var fg: Color = baseColor
            var bg: Color? = nil
            var weight: Float? = isStrong ? s.strongWeight : nil
            var underline = false

            if isCode {
                if let matcher = view.config.codeLinkMatchFn, let codeMatch = matcher(seg) {
                    fg = codeMatch.color
                    weight = s.inlineCodeWeight
                } else {
                    weight = s.inlineCodeWeight
                    if link == nil { bg = s.codeBg }
                }
            } else if isCodePad {
                if link == nil { bg = s.codeBg }
            }

            if let link {
                if let custom = view.config.linkLookFn?(link.url) {
                    fg = custom.color ?? s.accent
                    underline = custom.underline
                    if let w = custom.weight { weight = w }
                } else if !isCode {
                    fg = s.accent
                    underline = true
                }
            }

            spans.append(TextSpan(
                seg,
                color: fg,
                background: bg,
                weight: weight,
                italic: isEm,
                monospace: isCode,
                underline: underline,
                strikethrough: isStrike
            ))
        }
        return spans
    }

    private func textHighlights(for renderedText: String, map: MarkdownSpanMap?) -> [(range: Range<Int>, isCurrent: Bool)] {
        guard let map, !view.config.highlightsList.isEmpty else { return [] }
        var out: [(Range<Int>, Bool)] = []
        for item in view.config.highlightsList {
            for r in map.mapRanges(item.ranges, in: renderedText) {
                out.append((r, item.style.current))
            }
        }
        return out
    }

    private func renderPara(_ rawInl: MarkdownInline, map: MarkdownSpanMap?, font: TextStyle, color: Color, dir: MarkdownDirection?) -> El<State> {
        let inl = withCodeLinks(rawInl)
        var spans = buildTextSpans(inl, font: font, baseColor: color)
        let hlRanges = textHighlights(for: inl.text, map: map)
        if !hlRanges.isEmpty {
            spans = applyUTF8Highlights(
                spans: spans,
                ranges: hlRanges,
                activeIndex: nil,
                bg: s.highlightBg,
                activeBg: s.highlightCurrentBg,
                fg: s.highlightFg,
                activeFg: s.highlightCurrentFg
            )
        }
        var elNode: El<State> = rich(spans).font(font).color(color).wFull()
        if let dir {
            elNode = elNode.textAlign(dir.textAlign)
        }
        if !inl.links.isEmpty && (view.onLinkHandler != nil || view.onLinkSecondaryHandler != nil || view.config.linkHelpFn != nil) {
            if let helpFn = view.config.linkHelpFn, let first = inl.links.first, let h = helpFn(first.url) {
                elNode = elNode.help(h)
            }
            if let onLink = view.onLinkHandler {
                let capturedLinks = inl.links
                let fullText = inl.text
                let totalLen = max(1, fullText.utf8.count)
                elNode = elNode.onClickPress { state, press, tx in
                    if capturedLinks.count == 1 {
                        onLink(&state, capturedLinks[0].url, &tx)
                    } else {
                        let frac = max(0, min(1, press.local.x / max(1, press.elementSize.x)))
                        let byteGuess = Int(frac * Float(totalLen))
                        let hit = capturedLinks.min(by: {
                            let d0 = byteGuess < $0.start ? ($0.start - byteGuess) : (byteGuess > $0.end ? (byteGuess - $0.end) : 0)
                            let d1 = byteGuess < $1.start ? ($1.start - byteGuess) : (byteGuess > $1.end ? (byteGuess - $1.end) : 0)
                            return d0 < d1
                        }) ?? capturedLinks[0]
                        onLink(&state, hit.url, &tx)
                    }
                }
            }
            if let onSec = view.onLinkSecondaryHandler {
                let capturedLinks = inl.links
                elNode = elNode.onSecondaryClick { state, press, tx in
                    let frac = max(0, min(1, press.local.x / max(1, press.elementSize.x)))
                    let byteGuess = Int(frac * Float(max(1, inl.text.utf8.count)))
                    let hit = capturedLinks.min(by: {
                        let d0 = byteGuess < $0.start ? ($0.start - byteGuess) : (byteGuess > $0.end ? (byteGuess - $0.end) : 0)
                        let d1 = byteGuess < $1.start ? ($1.start - byteGuess) : (byteGuess > $1.end ? (byteGuess - $1.end) : 0)
                        return d0 < d1
                    }) ?? capturedLinks[0]
                    onSec(&state, hit.url, &tx)
                }
            }
        }
        return elNode
    }

    private func renderCode(_ code: String, source: MarkdownCodeSource?, map: MarkdownSpanMap?) -> El<State> {
        let lang = source?.language
        let langLower = lang?.lowercased()
        let isShell = langLower.map { MarkdownRendererShared.shells.contains($0) } ?? false
        let isPlain = langLower.map { MarkdownRendererShared.plainLangs.contains($0) } ?? true

        let fill: Color
        let border: Color
        let ink: Color
        if let sh = s.shell, isShell {
            fill = sh.fill
            border = sh.border
            ink = sh.text
        } else if isPlain {
            fill = s.codeBlockFill
            border = s.codeBlockBorder
            ink = s.plainCodeText ?? s.codeText ?? s.text
        } else {
            fill = s.codeBlockFill
            border = s.codeBlockBorder
            ink = s.codeText ?? s.text
        }

        let expanded = expandTabs(code)
        let syntaxPrefix: String
        if let source, source.open {
            syntaxPrefix = utf8Slice(expanded, range: 0..<min(source.colouredBytes, expanded.utf8.count)) ?? ""
        } else {
            syntaxPrefix = expanded
        }

        var spans: [TextSpan]
        if s.highlight && !isShell && (!view.config.syntaxHighlighter.isBuiltin || (lang.map { Syntax.known($0) } ?? false)) {
            let colouredCount = syntaxPrefix.utf8.count
            let highlights = view.config.syntaxHighlighter.highlight(language: lang, code: syntaxPrefix)
            spans = s.syntax.spans(for: syntaxPrefix, highlights: highlights, defaultColor: ink)
            if colouredCount < expanded.utf8.count,
               let tail = utf8Slice(expanded, range: colouredCount..<expanded.utf8.count), !tail.isEmpty {
                spans.append(TextSpan(tail, color: ink, monospace: true))
            }
        } else {
            spans = [TextSpan(expanded.isEmpty ? " " : expanded, color: ink, monospace: true)]
        }

        let hls = textHighlights(for: code, map: map)
        if !hls.isEmpty && expanded == code {
            spans = applyUTF8Highlights(
                spans: spans,
                ranges: hls,
                activeIndex: nil,
                bg: s.highlightBg,
                activeBg: s.highlightCurrentBg,
                fg: s.highlightFg,
                activeFg: s.highlightCurrentFg
            )
        }

        let body: El<State> = rich(spans).font(s.codeBlock).color(ink).wFull()
        let frame: El<State> = col()
            .wFull()
            .rounded(6)
            .bg(fill)
            .border(0.5, border)

        if view.config.isScrollWide {
            let viewport: El<State> = col().key("scroll").wFull().scrollX()
                .child(col().px(s.codeBlockPad[0]).py(s.codeBlockPad[1]).child(body))
            return frame.child(viewport)
        }
        return frame.px(s.codeBlockPad[0]).py(s.codeBlockPad[1]).child(body)
    }

    private func renderDiff(_ src: String, map: MarkdownSpanMap?) -> El<State> {
        let hls = textHighlights(for: src, map: map)
        var c: El<State> = col().wFull().py(s.codeBlockPad[1]).rounded(6).bg(s.codeBlockFill).border(0.5, s.codeBlockBorder)
        var offset = 0
        let rawLines = src.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (n, rawLine) in rawLines.enumerated() {
            let lineEnd = offset + rawLine.utf8.count
            let lineHLs = hls.compactMap { item -> (Range<Int>, Bool)? in
                let a = max(item.range.lowerBound, offset)
                let b = min(item.range.upperBound, lineEnd)
                return a < b ? ((a - offset)..<(b - offset), item.isCurrent) : nil
            }
            offset = lineEnd + 1
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let isHeader = ["@@", "diff ", "index ", "--- ", "+++ "].contains { line.hasPrefix($0) }
            let tint: Color?
            let color: Color
            if isHeader {
                tint = nil
                color = s.diffHunk
            } else if line.hasPrefix("+") {
                tint = s.diffAdd
                color = s.diffAddText
            } else if line.hasPrefix("-") {
                tint = s.diffRemove
                color = s.diffRemoveText
            } else {
                tint = nil
                color = s.text
            }
            let shown = line.isEmpty ? " " : line
            var spans = [TextSpan(shown, color: color, monospace: true)]
            if !lineHLs.isEmpty {
                spans = applyUTF8Highlights(spans: spans, ranges: lineHLs, activeIndex: nil, bg: s.highlightBg, activeBg: s.highlightCurrentBg, fg: s.highlightFg, activeFg: s.highlightCurrentFg)
            }
            var r: El<State> = row().key("l\(n)").wFull().px(s.codeBlockPad[0]).child(rich(spans).font(s.codeBlock).color(color).wFull())
            if let tint { r = r.bg(tint) }
            c = c.child(r)
        }
        return c
    }

    private func renderMermaidBlock(_ src: String, source: MarkdownCodeSource?, map: MarkdownSpanMap?, index: Int) -> El<State> {
        let open = source?.open ?? false
        let lines = open ? (utf8Slice(src, range: 0..<min(source?.colouredBytes ?? src.utf8.count, src.utf8.count)) ?? src) : src
        let theme = s.mermaidTheme()
        let hover: (MermaidHover, Color) = (s.diagram.hoverNeighbours ? .neighbours : .edges, s.diagram.hover)
        let diagram: El<State>? = view.config.isStreaming
            ? (open ? renderMermaidStreaming(lines, theme: theme, hover: hover) : renderMermaidStreamed(lines, theme: theme, hover: hover))
            : renderMermaid(lines, theme: theme, hover: hover)
        if let d = diagram {
            let labeled = d.label(KitMermaid.kindLabel(lines)).key("card")
            let framed = view.diagramFrameHandler?(labeled, MarkdownDiagramFrameContext(index: index, source: lines, open: open)) ?? labeled
            return col().wFull().child(framed)
        }
        if open && view.config.isStreaming && mayDrawMermaid(lines) {
            return col().wFull()
        }
        return col().wFull().child(renderCode(src, source: source, map: map).key("source"))
    }

    private func renderList(start: UInt64?, items: [[MarkdownDocBlock]], itemMaps: [[MarkdownBlockMap]]) -> El<State> {
        let indent: Float
        if let nested = s.listNested, flow.lists > 0 {
            indent = start != nil ? nested[1] : nested[0]
        } else {
            indent = s.listIndent
        }

        var c: El<State> = col().wFull()
        let n = items.count
        for (k, item) in items.enumerated() {
            let imap = k < itemMaps.count ? itemMaps[k] : []
            let task = nextTask < doc.tasks.count ? doc.tasks[nextTask] : nil
            nextTask += 1
            let saved = flow
            flow = FlowState(lists: saved.lists + 1, inset: saved.inset + indent, ink: saved.ink)

            let topGap: Float = k == 0 ? 0 : s.listGap
            let rowEl: El<State>
            if let task {
                rowEl = renderTaskItem(k: k, n: n, indent: indent, item: item, itemMaps: imap, markerOffset: task.markerOffset, checked: task.checked)
            } else {
                let markerStr = start.map { "\($0 + UInt64(k))." } ?? "•"
                var marker: El<State> = text(markerStr).font(s.body).color(s.muted).w(indent)
                if s.listOutside {
                    marker = marker.textAlign(.trailing).pr(4)
                } else {
                    marker = marker.textAlign(.center)
                }
                rowEl = row()
                    .key("i\(k)")
                    .role(.listItem)
                    .wFull()
                    .child(marker)
                    .child(blocksIn(item, maps: imap, keys: [], topLevel: false, inItem: true).grow(1).shrink(1))
            }
            flow = saved
            c = c.child(topGap > 0 ? rowEl.mt(topGap) : rowEl)
        }
        return c
    }

    private func renderTaskItem(
        k: Int,
        n: Int,
        indent: Float,
        item: [MarkdownDocBlock],
        itemMaps: [MarkdownBlockMap],
        markerOffset: Int,
        checked: Bool
    ) -> El<State> {
        _ = n
        let t = s.task
        let interactive = view.onTaskHandler != nil && !view.config.areTasksReadOnly
        let fill = checked ? t.fillOn : t.fillOff
        let border = checked ? t.borderOn : t.borderOff
        let topPad = t.top ?? max(0, ((s.body.lineHeight ?? 22.4) - t.size) * 0.5)
        var control: El<State> = el()
            .key("control")
            .size(t.size, t.size)
            .ml(t.left)
            .mr(max(0, indent - t.left - t.size))
            .mt(topPad)
            .center()
            .rounded(t.radius)
            .bg(fill)
            .border(1, border)
            .child(icon(t.check, size: t.size * 0.625).key("mark").color(t.mark).opacity(checked ? 1 : 0))
        if interactive {
            control = control.hover(t.hover)
        }
        let bodyText = item.compactMap { block -> String? in
            if case let .para(inl) = block { return inl.unpaddedText }
            if case let .heading(_, inl) = block { return inl.unpaddedText }
            return nil
        }.joined(separator: "\n")

        var r: El<State> = row()
            .key("i\(k)")
            .role(.checkbox)
            .label(bodyText)
            .selected(checked ? "true" : "false")
            .focusable(interactive)
            .wFull()
            .child(control)
            .child(blocksIn(item, maps: itemMaps, keys: [], topLevel: false, inItem: true).grow(1).shrink(1))
        if let onTask = view.onTaskHandler, interactive {
            let bKey = currentBlockKey
            r = r.onClick { state, tx in
                onTask(&state, bKey, markerOffset, !checked, &tx)
            }
        }
        return r
    }

    private func renderTable(_ t: MarkdownTableAST, headMaps: [MarkdownSpanMap], rowMaps: [[MarkdownSpanMap]]) -> El<State> {
        let n = max(t.align.count, max(t.head.count, 1))
        let settledRows = (t.open && view.config.isStreaming) ? Array(t.rows.dropLast()) : t.rows
        let colWidths = measureTableColumns(t, colCount: n, settledRows: settledRows)
        let total = colWidths.natural.reduce(0, +)

        let ring: Color? = s.tableFrame?.ring ?? s.tableOutline
        let fill: Color? = s.tableFrame?.fill
        let inset: Float = s.tableFrame.map { max(0.5, $0.pad) } ?? (s.tableOutline != nil ? 0.5 : 0)

        let fixedWidths: [Float]? = (s.textWidth.flatMap { view.config.isScrollWide ? $0 : nil }).map { w in
            let avail = max(0, w - flow.inset - 2 * inset)
            return autoLayoutColumns(natural: colWidths.natural, fit: colWidths.fit, avail: avail, fullWidth: s.tableFullWidth)
        }

        var frame: El<State> = col().wFull().p(inset)
        if !s.tableFullWidth {
            frame = frame.maxW(total + 2 * inset)
        }
        if let fill { frame = frame.rounded(6).bg(fill) }
        if let ring { frame = frame.rounded(6).border(0.5, ring) }

        let headPad = s.tableHeadPad ?? s.tablePad
        let headFont = TextStyle(size: (s.tableFont ?? s.body).size, weight: s.tableHeadWeight ?? s.strongWeight, lineHeight: (s.tableFont ?? s.body).lineHeight, family: (s.tableFont ?? s.body).family)
        let bodyFont = s.tableFont ?? s.body
        let headRow = renderTableRow(cells: t.head, maps: headMaps, table: t, widths: fixedWidths, natural: colWidths.natural, minWidths: colWidths.min, font: headFont, color: s.tableHeadText, pad: headPad).key("th")

        if let bodyLook = s.tableBody {
            frame = frame.child(headRow)
            if !t.rows.isEmpty {
                var rowsCol: El<State> = col().key("tbc").wFull()
                for (i, cells) in t.rows.enumerated() {
                    let rmap = i < rowMaps.count ? rowMaps[i] : []
                    var rowEl = renderTableRow(cells: cells, maps: rmap, table: t, widths: fixedWidths, natural: colWidths.natural, minWidths: colWidths.min, font: bodyFont, color: s.text, pad: s.tablePad).key("r\(i)")
                    if i + 1 < t.rows.count {
                        rowEl = rowEl.borderSides(bottom: 0.5, color: s.tableRule)
                    }
                    rowsCol = rowsCol.child(rowEl)
                }
                let card = col().key("tb").wFull().rounded(bodyLook.radius).bg(bodyLook.fill).shadows(bodyLook.shadows).child(rowsCol)
                frame = frame.child(card)
            }
        } else {
            frame = frame.child(headRow.bg(s.tableHeadFill))
            for (i, cells) in t.rows.enumerated() {
                let sepColor = (i == 0 ? s.tableHeadRule : nil) ?? s.tableRule
                frame = frame.child(el().key("s\(i)").wFull().h(0.5).bg(sepColor))
                let rmap = i < rowMaps.count ? rowMaps[i] : []
                frame = frame.child(renderTableRow(cells: cells, maps: rmap, table: t, widths: fixedWidths, natural: colWidths.natural, minWidths: colWidths.min, font: bodyFont, color: s.text, pad: s.tablePad).key("r\(i)"))
            }
            if ring == nil {
                frame = frame.child(el().key("s-end").wFull().h(0.5).bg((t.rows.isEmpty ? s.tableHeadRule : nil) ?? s.tableRule))
            }
        }

        if view.config.isScrollWide {
            if let fixedWidths {
                let wTotal = fixedWidths.reduce(0, +)
                frame = frame.w(wTotal + 2 * inset)
            } else {
                frame = s.tableFullWidth ? frame.maxW(total + 2 * inset) : frame.w(total + 2 * inset)
            }
            return col().wFull().child(col().key("scroll").wFull().scrollX().child(frame))
        }
        return frame
    }

    private func renderTableRow(
        cells: [MarkdownInline],
        maps: [MarkdownSpanMap],
        table: MarkdownTableAST,
        widths: [Float]?,
        natural: [Float],
        minWidths: [Float],
        font: TextStyle,
        color: Color,
        pad: [Float]
    ) -> El<State> {
        let total = natural.reduce(0, +)
        var r: El<State> = row().wFull()
        let tableDir = MarkdownBidi.tableDirection(table)
        for j in 0..<natural.count {
            let inl = j < cells.count ? cells[j] : MarkdownInline()
            let m = j < maps.count ? maps[j] : nil
            var align = (s.tableAlign && j < table.align.count) ? table.align[j] : .start
            let dir = MarkdownBidi.inlineDirection(inl)
            if let dir, dir != tableDir {
                if align == .start { align = .end }
                else if align == .end { align = .start }
            }
            var spans = buildTextSpans(inl, font: font, baseColor: color)
            let hl = textHighlights(for: inl.text, map: m)
            if !hl.isEmpty {
                spans = applyUTF8Highlights(spans: spans, ranges: hl, activeIndex: nil, bg: s.highlightBg, activeBg: s.highlightCurrentBg, fg: s.highlightFg, activeFg: s.highlightCurrentFg)
            }
            let content: El<State> = rich(spans).font(font).color(color).textAlign(align.textAlign).wFull()
            var cell: El<State> = col().key("c\(j)")
            if let fixed = widths, j < fixed.count {
                cell = cell.w(fixed[j])
            } else if s.tableFullWidth && total > 0 {
                cell = cell.wFrac(natural[j] / total).shrink(1).minW(view.config.isScrollWide ? natural[j] : minWidths[j])
            } else {
                cell = cell.w(natural[j]).shrink(1).minW(minWidths[j])
            }
            let leftPad = (j == 0 && s.tableFlushLeft) ? 0 : pad[0]
            r = r.child(cell.pl(leftPad).pr(pad[0]).py(pad[1]).clip(true).child(content))
        }
        return r
    }

    private func measureTableColumns(
        _ t: MarkdownTableAST,
        colCount n: Int,
        settledRows: [[MarkdownInline]]
    ) -> (natural: [Float], min: [Float], fit: [Float]) {
        func measureLines(_ rows: [[MarkdownInline]], font: TextStyle) -> ([Float], [Float], [Float]) {
            var natural = Array(repeating: Float(0), count: n)
            var fit = Array(repeating: Float(0), count: n)
            for row in rows {
                for j in 0..<min(n, row.count) {
                    let inl = row[j]
                    if inl.text.isEmpty { continue }
                    let clean = MarkdownInline.unpadded(inl.text)
                    MarkdownRendererShared.measureLock.lock()
                    let fullSize = MarkdownRendererShared.measureSystem.measure(clean, style: font, maxWidth: nil, pixelScale: 1)
                    let maxWord = clean.split(whereSeparator: \.isWhitespace)
                        .map { MarkdownRendererShared.measureSystem.measure(String($0), style: font, maxWidth: nil, pixelScale: 1).x }
                        .max() ?? fullSize.x
                    MarkdownRendererShared.measureLock.unlock()
                    let padExtra: Float = inl.spans.contains(where: { $0.style == .code }) ? s.inlineCodePad : 0
                    natural[j] = max(natural[j], fullSize.x + padExtra + 0.01)
                    fit[j] = max(fit[j], maxWord + padExtra + 0.01)
                }
            }
            let mins = fit.map { min($0, s.tableMinColumn) }
            return (natural, mins, fit)
        }

        let baseFont = s.tableFont ?? s.body
        let headFont = TextStyle(size: baseFont.size, weight: s.tableHeadWeight ?? s.strongWeight, lineHeight: baseFont.lineHeight, family: baseFont.family)
        let (hn, hm, hf) = measureLines([t.head], font: headFont)
        let (bn, bm, bf) = measureLines(settledRows, font: baseFont)
        let headPadX = (s.tableHeadPad ?? s.tablePad)[0]
        let bodyPadX = s.tablePad[0]
        let hasBody = !settledRows.isEmpty

        func pad(_ j: Int, _ x: Float) -> Float {
            ((j == 0 && s.tableFlushLeft) ? 0 : x) + x
        }

        var nat: [Float] = []
        var mins: [Float] = []
        var fits: [Float] = []
        for j in 0..<n {
            let hp = pad(j, headPadX)
            let bp = pad(j, bodyPadX)
            nat.append(hasBody ? max(hn[j] + hp, bn[j] + bp) : (hn[j] + hp))
            mins.append(hasBody ? max(hm[j] + hp, bm[j] + bp) : (hm[j] + hp))
            fits.append(hasBody ? max(hf[j] + hp, bf[j] + bp) : (hf[j] + hp))
        }
        return (nat, mins, fits)
    }

    private func autoLayoutColumns(natural: [Float], fit: [Float], avail: Float, fullWidth: Bool) -> [Float] {
        let sumNat = natural.reduce(0, +)
        if sumNat <= avail {
            guard fullWidth && sumNat > 0 else { return natural }
            let scale = avail / sumNat
            return natural.map { $0 * scale }
        }
        let sumFit = fit.reduce(0, +)
        if sumFit >= avail {
            return fit
        }
        let slack = avail - sumFit
        let excess = max(0.001, sumNat - sumFit)
        return zip(fit, natural).map { f, n in
            f + slack * ((n - f) / excess)
        }
    }

    private func expandTabs(_ code: String) -> String {
        guard code.contains("\t") else { return code }
        var out = ""
        var col = 0
        for ch in code {
            if ch == "\t" {
                let pad = 4 - (col % 4)
                out.append(String(repeating: " ", count: pad))
                col += pad
            } else if ch == "\n" {
                out.append(ch)
                col = 0
            } else {
                out.append(ch)
                col += 1
            }
        }
        return out
    }
}

private extension MarkdownBlockMap {
    var listMaps: [[MarkdownBlockMap]]? {
        if case let .list(m) = self { return m }
        return nil
    }
    var quoteMaps: [MarkdownBlockMap]? {
        if case let .quote(m) = self { return m }
        return nil
    }
}

// MARK: - Kit.markdown Legacy + Convenience Entry Points

extension Kit {
    /// Renders a CommonMark + GFM Markdown document into a native `Rune` element tree (`Kit::markdown`).
    public func markdown<State>(_ source: String, key: String = "md") -> El<State> {
        markdown(source, key: key, searchQuery: nil, activeMatch: nil, streaming: false)
    }

    /// Renders Markdown with optional search highlighting and streaming stabilization.
    public func markdown<State>(
        _ source: String,
        key: String = "md",
        searchQuery: String?,
        activeMatch: Int? = nil,
        streaming: Bool = false
    ) -> El<State> {
        var md = Markdown(source).streaming(streaming)
        if let q = searchQuery, !q.isEmpty {
            let matches = md.find(q, caseSensitivity: .insensitive)
            let items: [(ranges: [Range<Int>], style: MarkdownHighlight)] = matches.enumerated().map { idx, range in
                ([range], MarkdownHighlight.match().current(activeMatch == idx))
            }
            md = md.highlights(items)
        }
        return md.build(self).key(key)
    }
}

// MARK: - UTF-8 Helpers

private func utf8Slice(_ str: String, range: Range<Int>) -> String? {
    let total = str.utf8.count
    let lo = max(0, min(total, range.lowerBound))
    let hi = max(lo, min(total, range.upperBound))
    let sIdx = str.utf8.index(str.startIndex, offsetBy: lo)
    let eIdx = str.utf8.index(str.startIndex, offsetBy: hi)
    return String(str[sIdx..<eIdx])
}

private func isUTF8Boundary(_ str: String, _ byteOffset: Int) -> Bool {
    guard byteOffset >= 0 && byteOffset <= str.utf8.count else { return false }
    if byteOffset == 0 || byteOffset == str.utf8.count { return true }
    let idx = str.utf8.index(str.startIndex, offsetBy: byteOffset)
    return str.unicodeScalars.indices.contains(idx) || String.Index(idx, within: str) != nil
}

private func floorUTF8Boundary(_ str: String, byte: Int) -> Int {
    var b = max(0, min(str.utf8.count, byte))
    while b > 0 && !isUTF8Boundary(str, b) { b -= 1 }
    return b
}

private func ceilUTF8Boundary(_ str: String, byte: Int) -> Int {
    let maxB = str.utf8.count
    var b = max(0, min(maxB, byte))
    while b < maxB && !isUTF8Boundary(str, b) { b += 1 }
    return b
}

private extension String {
    func trimmingTrailingWhitespaceOnly() -> String {
        var copy = self
        while let last = copy.last, last.isWhitespace {
            copy.removeLast()
        }
        return copy
    }
}

private enum MarkdownRendererShared {
    static let measureSystem = TextSystem()
    static let measureLock = NSLock()
    static let shells: Set<String> = ["bash", "sh", "shell", "zsh", "fish", "console", "terminal"]
    static let plainLangs: Set<String> = ["text", "txt", "plain", "plaintext"]
}
