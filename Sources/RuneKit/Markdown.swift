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

    /// The first strong character outside Unicode directional isolates in this paragraph.
    public static func firstStrongDirection(in text: String) -> MarkdownDirection? {
        switch Direction.of(text) {
        case .ltr: return .ltr
        case .rtl: return .rtl
        default: return nil
        }
    }

    /// Code chips, addresses and technical tokens keep their own reading order.
    /// An inline containing only those units inherits the surrounding direction.
    public static func inlineDirection(_ inline: MarkdownInline) -> MarkdownDirection? {
        inline.bidi.direction
    }

    public static func blocksDirection(_ blocks: [MarkdownDocBlock]) -> MarkdownDirection? {
        var stack: [MarkdownDocBlock] = []
        stack.reserveCapacity(blocks.count)
        for b in blocks.reversed() { stack.append(b) }
        while let block = stack.popLast() {
            switch block {
            case let .para(inline), let .heading(_, inline):
                if let d = inlineDirection(inline) { return d }
            case let .quote(inner):
                for c in inner.reversed() { stack.append(c) }
            case let .list(_, items):
                for item in items.reversed() {
                    for c in item.reversed() { stack.append(c) }
                }
            case let .table(table):
                if let d = tableDirection(table) { return d }
            case .image, .code, .diff, .mermaid, .rule:
                break
            }
        }
        return nil
    }

    fileprivate static func blockDirection(_ block: MarkdownDocBlock) -> MarkdownDirection? {
        blocksDirection([block])
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
        guard let base, !text.isEmpty else { return text }
        let opposite: Direction = base == .ltr ? .rtl : .ltr
        let scalars = text.unicodeScalars
        var output = ""
        var copied = scalars.startIndex
        var runStart = copied
        var runDirection: Direction?
        var depth = 0

        func finishRun(at end: String.Index) {
            if runDirection == opposite {
                output.unicodeScalars.append(contentsOf: scalars[copied..<runStart])
                output += opposite == .rtl ? rli : lri
                output.unicodeScalars.append(contentsOf: scalars[runStart..<end])
                output += pdi
                copied = end
            }
            runStart = end
            runDirection = nil
        }

        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            let next = scalars.index(after: index)
            switch scalar.value {
            case 0x2066...0x2068:
                if depth == 0 { finishRun(at: index) }
                depth += 1
            case 0x2069 where depth > 0:
                depth -= 1
                if depth == 0 { runStart = next }
            default:
                if depth == 0, let direction = Direction.ofStrongScalar(scalar) {
                    if let runDirection, runDirection != direction { finishRun(at: index) }
                    runDirection = direction
                }
            }
            index = next
        }
        finishRun(at: scalars.endIndex)
        if output.isEmpty { return text }
        output.unicodeScalars.append(contentsOf: scalars[copied...])
        return output
    }
}

/// Derived from one parsed inline, in the same UTF-8 coordinates as its styles and links.
fileprivate struct MarkdownInlineBidi: Sendable {
    let units: [Range<Int>]
    let direction: MarkdownDirection?

    init(_ inline: MarkdownInline) {
        let text = inline.text
        let bytes = text.utf8
        func valid(_ start: Int, _ end: Int) -> Bool {
            start >= 0 && start < end && end <= bytes.count &&
                isUTF8Boundary(text, start) && isUTF8Boundary(text, end)
        }
        func string(_ range: Range<Int>) -> String {
            if range.count == bytes.count { return text }
            let start = bytes.index(bytes.startIndex, offsetBy: range.lowerBound)
            let end = bytes.index(start, offsetBy: range.count)
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        var marked: [Range<Int>] = []
        let code = inline.spans.compactMap { span -> Range<Int>? in
            guard span.style == .code || span.style == .codePad, valid(span.start, span.end) else { return nil }
            return span.start..<span.end
        }.sorted { $0.lowerBound < $1.lowerBound }
        for range in code {
            if let last = marked.last, range.lowerBound <= last.upperBound {
                marked[marked.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                marked.append(range)
            }
        }

        var addresses: [Range<Int>] = []
        var ordered = true
        for link in inline.links where valid(link.start, link.end) {
            let range = link.start..<link.end
            let shown = string(range).trimmingCharacters(in: .whitespacesAndNewlines)
            if shown.utf8.elementsEqual(link.url.utf8) || ["http://", "https://", "www.", "file://", "mailto:"].contains(where: shown.hasPrefix) {
                if let previous = addresses.last, previous.upperBound > range.lowerBound { ordered = false }
                addresses.append(range)
            }
        }
        if ordered {
            marked = Self.merging(marked, with: addresses)
        } else {
            // Manually constructed inlines can supply overlapping or out-of-order links.
            // The first link wins when no code chip already owns its bytes.
            for range in addresses where !marked.contains(where: { $0.overlaps(range) }) { marked.append(range) }
            marked.sort { $0.lowerBound < $1.lowerBound }
        }
        units = Self.merging(marked, with: TextBidiUnits.ltrUnits(in: text))
        let hasStrongCandidate = bytes.contains { b in
            (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b >= 0x80
        }
        guard hasStrongCandidate else {
            direction = nil
            return
        }
        var at = 0
        for range in units {
            if at < range.lowerBound, let found = MarkdownBidi.firstStrongDirection(in: string(at..<range.lowerBound)) {
                direction = found
                return
            }
            at = range.upperBound
        }
        direction = at < bytes.count ? MarkdownBidi.firstStrongDirection(in: string(at..<bytes.count)) : nil
    }

    /// Both inputs are disjoint and in source order. Explicit code and links win
    /// when a lower-priority lexer token overlaps them.
    private static func merging(_ primary: [Range<Int>], with candidates: [Range<Int>]) -> [Range<Int>] {
        if primary.isEmpty { return candidates }
        if candidates.isEmpty { return primary }
        var combined: [Range<Int>] = []
        combined.reserveCapacity(primary.count + candidates.count)
        var next = 0
        for range in candidates {
            while next < primary.count && primary[next].upperBound <= range.lowerBound {
                combined.append(primary[next])
                next += 1
            }
            if next == primary.count || range.upperBound <= primary[next].lowerBound {
                combined.append(range)
            }
        }
        combined.append(contentsOf: primary[next...])
        return combined
    }

    func isolate<State>(_ element: El<State>) -> El<State> {
        guard !units.isEmpty else { return element }
        var result = element
        // The freshly built rich element has precisely this inline's text. Install the
        // validated, ordered ranges together so each unit needn't rejoin the rich spans.
        result.isolatesSpec = units.map { ($0, Direction.ltr) }
        return result
    }
}

private extension El {
    mutating func setMarkdownDirection(_ direction: MarkdownDirection?) {
        guard let direction else { return }
        let resolved = direction == .rtl ? Direction.rtl : .ltr
        if explicitDir != resolved { explicitDir = resolved }
    }

    consuming func markdownDirection(_ direction: MarkdownDirection?) -> Self {
        var result = self
        result.setMarkdownDirection(direction)
        return result
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
                            let url = prefixInfo.isWWW ? "http://\(display)" : display
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

    public var text: String { didSet { preparedBidi = nil } }
    public var spans: [MarkdownStyleSpan] { didSet { preparedBidi = nil } }
    public var links: [MarkdownLinkSpan] { didSet { preparedBidi = nil } }

    fileprivate var preparedBidi: MarkdownInlineBidi?
    fileprivate var bidi: MarkdownInlineBidi { preparedBidi ?? MarkdownInlineBidi(self) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.spans == rhs.spans && lhs.links == rhs.links
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(spans)
        hasher.combine(links)
    }

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

        let outBytes = Array(outText.utf8)
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
                if let r = Self.mapSegment(query: q, src: seg.src, out: seg.out, outBytes: outBytes) {
                    if let last = mapped.last,
                       last.upperBound >= r.lowerBound || Self.isPadOnlyBytes(outBytes, range: last.upperBound..<r.lowerBound) {
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

    private static func mapSegment(query: Range<Int>, src: Range<Int>, out: Range<Int>, outBytes: [UInt8]) -> Range<Int>? {
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
        let maxLen = outBytes.count
        var clamped0 = min(maxLen, max(out.lowerBound, min(out.upperBound, raw0)))
        while clamped0 > 0 && clamped0 < maxLen && (outBytes[clamped0] & 0xC0) == 0x80 {
            clamped0 -= 1
        }
        var clamped1 = min(maxLen, max(out.lowerBound, min(out.upperBound, raw1)))
        while clamped1 < maxLen && (outBytes[clamped1] & 0xC0) == 0x80 {
            clamped1 += 1
        }
        return clamped0 < clamped1 ? (clamped0..<clamped1) : nil
    }

    private static func isPadOnlyBytes(_ bytes: [UInt8], range: Range<Int>) -> Bool {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count, !range.isEmpty else { return false }
        var i = range.lowerBound
        while i + 2 < range.upperBound {
            // U+202F = E2 80 AF, U+2066 = E2 81 A6, U+2069 = E2 81 A9
            if bytes[i] == 0xE2 && ((bytes[i + 1] == 0x80 && bytes[i + 2] == 0xAF) || (bytes[i + 1] == 0x81 && (bytes[i + 2] == 0xA6 || bytes[i + 2] == 0xA9))) {
                i += 3
            } else {
                return false
            }
        }
        return i == range.upperBound
    }
}

/// Source-to-output mapping tree matching `MarkdownDocBlock` (`rune_kit::markdown::find::BlockMap`).
public indirect enum MarkdownBlockMap: Sendable, Equatable, Hashable {
    case none
    case inline(MarkdownSpanMap)
    case code(MarkdownSpanMap)
    case deepTail(lines: Int, map: MarkdownSpanMap)
    case quote([MarkdownBlockMap])
    case list([[MarkdownBlockMap]])
    case table(head: [MarkdownSpanMap], rows: [[MarkdownSpanMap]])

    public func shiftedSrc(_ offset: Int) -> MarkdownBlockMap {
        guard offset != 0 else { return self }
        enum Step {
            case enter(MarkdownBlockMap)
            case finishQuote(Int)
            case finishItem(Int)
            case finishList(Int)
        }
        var vals: [MarkdownBlockMap] = []
        var itemsVals: [[MarkdownBlockMap]] = []
        var stack: [Step] = [.enter(self)]
        while let step = stack.popLast() {
            switch step {
            case .enter(let m):
                switch m {
                case .none:
                    vals.append(.none)
                case .inline(let sm):
                    vals.append(.inline(sm.shiftedSrc(offset)))
                case .code(let sm):
                    vals.append(.code(sm.shiftedSrc(offset)))
                case let .deepTail(lines, sm):
                    vals.append(.deepTail(lines: lines, map: sm.shiftedSrc(offset)))
                case let .table(head, rows):
                    vals.append(.table(
                        head: head.map { $0.shiftedSrc(offset) },
                        rows: rows.map { $0.map { $0.shiftedSrc(offset) } }
                    ))
                case .quote(let inner):
                    stack.append(.finishQuote(inner.count))
                    for c in inner.reversed() { stack.append(.enter(c)) }
                case .list(let items):
                    stack.append(.finishList(items.count))
                    for item in items.reversed() {
                        stack.append(.finishItem(item.count))
                        for c in item.reversed() { stack.append(.enter(c)) }
                    }
                }
            case .finishQuote(let n):
                let start = vals.count - n
                let children = Array(vals[start...])
                vals.removeSubrange(start...)
                vals.append(.quote(children))
            case .finishItem(let n):
                let start = vals.count - n
                let children = Array(vals[start...])
                vals.removeSubrange(start...)
                itemsVals.append(children)
            case .finishList(let n):
                let start = itemsVals.count - n
                let items = Array(itemsVals[start...])
                itemsVals.removeSubrange(start...)
                vals.append(.list(items))
            }
        }
        return vals.popLast() ?? .none
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
    /// One piece of a block's visible text and the source bytes it shows (`find.rs` `Seg`).
    struct Seg: Sendable, Hashable {
        var src: Range<Int>
        var out: Range<Int>
        var linear: Bool
    }

    /// A block's visible text, its UTF-8 bytes, and the segments mapping it back to the source.
    struct Visible: Sendable, Hashable {
        var text: String
        var bytes: [UInt8]
        var segs: [Seg]
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
        let srcBytes = Array(src.utf8)
        var out: [[Range<Int>]] = []
        findInBlocks(srcBytes: srcBytes, blocks: doc.blocks, maps: doc.maps, query: query, caseSensitivity: caseSensitivity, out: &out)
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

    /// `rune_kit::markdown::find`: matches of `query` in `src`'s rendered text, from the cached parse.
    public static func find(_ src: String, _ query: String, _ caseSensitivity: MarkdownCase = .insensitive) -> [[Range<Int>]] {
        guard !src.isEmpty, !query.isEmpty else { return [] }
        return findAll(in: src, doc: MarkdownDocCache.shared.docCached(src, autolink: true), query: query, caseSensitivity: caseSensitivity)
    }

    /// Calls `f` with each searchable text of `blocks` and its map back to the source, in
    /// document order (`find.rs` `each_text`): paragraphs, headings, image alt text, code and
    /// diff blocks, Mermaid sources a diagram doesn't draw, table head and body cells, and the
    /// blocks of list items and quotes.
    static func eachText(blocks: [MarkdownDocBlock], maps: [MarkdownBlockMap], _ f: (String, MarkdownSpanMap) -> Void) {
        var stack: [([MarkdownDocBlock], [MarkdownBlockMap], Int)] = [(blocks, maps, 0)]
        while !stack.isEmpty {
            let topIdx = stack.count - 1
            let i = stack[topIdx].2
            if i >= stack[topIdx].0.count {
                stack.removeLast()
                continue
            }
            let b = stack[topIdx].0[i]
            let map = i < stack[topIdx].1.count ? stack[topIdx].1[i] : .none
            stack[topIdx].2 = i + 1
            switch (b, map) {
            case let (.para(inl), .inline(m)), let (.heading(_, inl), .inline(m)):
                f(inl.text, m)
            case let (.para(inl), .deepTail(_, m)):
                f(inl.text, m)
            case let (.image(_, alt, _), .inline(m)):
                f(alt, m)
            case let (.code(code), .code(m)), let (.diff(code), .code(m)):
                f(code, m)
            case let (.mermaid(code), .code(m)):
                if KitMermaid.supported(code) { continue }
                f(code, m)
            case let (.table(t), .table(head, rows)):
                for (j, cell) in t.head.enumerated() where j < head.count {
                    f(cell.text, head[j])
                }
                for (ri, row) in t.rows.enumerated() where ri < rows.count {
                    let rmaps = rows[ri]
                    for (j, cell) in row.enumerated() where j < rmaps.count {
                        f(cell.text, rmaps[j])
                    }
                }
            case let (.list(_, items), .list(itemMaps)):
                let limit = min(items.count, itemMaps.count)
                for idx in stride(from: limit - 1, through: 0, by: -1) {
                    stack.append((items[idx], itemMaps[idx], 0))
                }
            case let (.quote(inner), .quote(innerMaps)):
                stack.append((inner, innerMaps, 0))
            default:
                continue
            }
        }
    }

    private static func findInBlocks(
        srcBytes: [UInt8],
        blocks: [MarkdownDocBlock],
        maps: [MarkdownBlockMap],
        query: String,
        caseSensitivity: MarkdownCase,
        out: inout [[Range<Int>]]
    ) {
        eachText(blocks: blocks, maps: maps) { text, map in
            if let vis = visible(srcBytes: srcBytes, text: text, map: map) {
                findInVisible(srcBytes: srcBytes, vis: vis, query: query, caseSensitivity: caseSensitivity, out: &out)
            }
        }
    }

    /// A text's visible characters and the segments mapping them to the source: the text itself
    /// when its map covers it end to end, else the pieces the map names, joined (`find.rs` `visible`).
    static func visible(srcBytes: [UInt8], text: String, map: MarkdownSpanMap) -> Visible? {
        guard !text.isEmpty, !map.segments.isEmpty else { return nil }

        let textBytes = Array(text.utf8)
        let contiguous = map.segments[0].out.lowerBound == 0 &&
            map.segments[map.segments.count - 1].out.upperBound == textBytes.count &&
            zip(map.segments, map.segments.dropFirst()).allSatisfy { $0.out.upperBound == $1.out.lowerBound }

        var vis: String
        var visBytes: [UInt8]
        var segs: [Seg] = []
        segs.reserveCapacity(map.segments.count)

        if contiguous {
            vis = text
            visBytes = textBytes
            for s in map.segments {
                let linear = isLinearSeg(srcBytes: srcBytes, visBytes: visBytes, sSeg: s.src, oSeg: s.out)
                segs.append(Seg(src: s.src, out: s.out, linear: linear))
            }
        } else {
            vis = ""
            for s in map.segments {
                let o0 = max(0, min(s.out.lowerBound, textBytes.count))
                let o1 = max(o0, min(s.out.upperBound, textBytes.count))
                if o0 < o1 {
                    let slice = String(decoding: textBytes[o0..<o1], as: UTF8.self)
                    let start = vis.utf8.count
                    vis.append(slice)
                    let newOut = start..<vis.utf8.count
                    segs.append(Seg(src: s.src, out: newOut, linear: false))
                }
            }
            visBytes = Array(vis.utf8)
            for idx in segs.indices {
                segs[idx].linear = isLinearSeg(srcBytes: srcBytes, visBytes: visBytes, sSeg: segs[idx].src, oSeg: segs[idx].out)
            }
        }
        guard !vis.isEmpty else { return nil }
        return Visible(text: vis, bytes: visBytes, segs: segs)
    }

    /// Matches of `query` in one block's visible text, mapped back to source ranges (`find.rs` `find_in_visible`).
    static func findInVisible(
        srcBytes: [UInt8],
        vis visible: Visible,
        query: String,
        caseSensitivity: MarkdownCase,
        out: inout [[Range<Int>]]
    ) {
        let vis = visible.text
        let visBytes = visible.bytes
        let segs = visible.segs
        var segIdx = 0
        switch caseSensitivity {
        case .sensitive:
            var searchStart = vis.startIndex
            while let r = vis.range(of: query, range: searchStart..<vis.endIndex) {
                let b0 = vis.utf8.distance(from: vis.startIndex, to: r.lowerBound)
                let b1 = vis.utf8.distance(from: vis.startIndex, to: r.upperBound)
                let ranges = mapVisRange(srcBytes: srcBytes, segs: segs, segIdx: &segIdx, vRange: b0..<b1)
                if !ranges.isEmpty { out.append(ranges) }
                searchStart = r.upperBound
            }
        case .insensitive:
            let foldedQ = foldQuery(query)
            guard !foldedQ.isEmpty else { return }
            // Case-fold scalar by scalar keeping byte index mapping (handles sigma 'ς'/'σ' + multi-char lowercase)
            var fBytes: [UInt8] = []
            var fToV: [Int] = []
            fBytes.reserveCapacity(visBytes.count)
            fToV.reserveCapacity(visBytes.count + 1)
            var curVByte = 0
            for ch in vis {
                if let ascii = ch.asciiValue {
                    fToV.append(curVByte)
                    fBytes.append((ascii >= 65 && ascii <= 90) ? (ascii + 32) : ascii)
                    curVByte += 1
                    continue
                }
                let chBytes = String(ch).utf8.count
                if ch == "ς" {
                    fToV.append(curVByte)
                    fBytes.append(contentsOf: "σ".utf8)
                } else {
                    var first = true
                    for fc in String(ch).lowercased() {
                        let fcUtf8 = String(fc).utf8
                        fToV.append(first ? curVByte : Int.max)
                        first = false
                        fBytes.append(contentsOf: fcUtf8)
                        for _ in 1..<fcUtf8.count { fToV.append(Int.max) }
                    }
                }
                while fToV.count < fBytes.count { fToV.append(Int.max) }
                curVByte += chBytes
            }
            fToV.append(visBytes.count)

            let qBytes = Array(foldedQ.utf8)
            let qLen = qBytes.count
            guard !qBytes.isEmpty, fBytes.count >= qLen else { return }
            // KMP prefix table keeps periodic rejected candidates (e.g. #133) strict O(N + M)
            var lps = [Int](repeating: 0, count: qLen)
            var lpsLen = 0
            var k = 1
            while k < qLen {
                if qBytes[k] == qBytes[lpsLen] {
                    lpsLen += 1
                    lps[k] = lpsLen
                    k += 1
                } else if lpsLen != 0 {
                    lpsLen = lps[lpsLen - 1]
                } else {
                    lps[k] = 0
                    k += 1
                }
            }
            var j = 0
            var i = 0
            while i < fBytes.count {
                if fBytes[i] == qBytes[j] {
                    i += 1
                    j += 1
                    if j == qLen {
                        let start = i - qLen
                        let v0 = fToV[start]
                        let v1 = fToV[i]
                        if v0 != Int.max && v1 != Int.max && v0 < v1 {
                            let ranges = mapVisRange(srcBytes: srcBytes, segs: segs, segIdx: &segIdx, vRange: v0..<v1)
                            if !ranges.isEmpty { out.append(ranges) }
                            j = 0
                        } else {
                            j = lps[j - 1]
                        }
                    }
                } else if j != 0 {
                    j = lps[j - 1]
                } else {
                    i += 1
                }
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

    private static func isLinearSeg(srcBytes: [UInt8], visBytes: [UInt8], sSeg: Range<Int>, oSeg: Range<Int>) -> Bool {
        guard sSeg.count == oSeg.count,
              sSeg.lowerBound >= 0, sSeg.upperBound <= srcBytes.count,
              oSeg.lowerBound >= 0, oSeg.upperBound <= visBytes.count else {
            return false
        }
        if srcBytes[sSeg].elementsEqual(visBytes[oSeg]) {
            return true
        }
        return !sSeg.isEmpty && srcBytes[sSeg.lowerBound] != 0x26
    }

    private static func isUTF8BoundaryBytes(_ bytes: [UInt8], _ byte: Int) -> Bool {
        byte <= 0 || byte >= bytes.count || (bytes[byte] & 0xC0) != 0x80
    }

    static func mapVisRange(srcBytes: [UInt8], segs: [Seg], segIdx: inout Int, vRange: Range<Int>) -> [Range<Int>] {
        while segIdx < segs.count && segs[segIdx].out.upperBound <= vRange.lowerBound {
            segIdx += 1
        }
        var ranges: [Range<Int>] = []
        var j = segIdx
        let srcLen = srcBytes.count
        while j < segs.count && segs[j].out.lowerBound < vRange.upperBound {
            let seg = segs[j]
            let o0 = max(vRange.lowerBound, seg.out.lowerBound)
            let o1 = min(vRange.upperBound, seg.out.upperBound)
            if o0 < o1 {
                let rel0 = o0 - seg.out.lowerBound
                let rel1 = o1 - seg.out.lowerBound
                var s0: Int
                var s1: Int
                if seg.linear && isUTF8BoundaryBytes(srcBytes, seg.src.lowerBound + rel0) && isUTF8BoundaryBytes(srcBytes, seg.src.lowerBound + rel1) {
                    s0 = seg.src.lowerBound + rel0
                    s1 = seg.src.lowerBound + rel1
                } else {
                    s0 = seg.src.lowerBound
                    s1 = seg.src.upperBound
                }
                s0 = min(srcLen, max(seg.src.lowerBound, min(seg.src.upperBound, s0)))
                while s0 > 0 && s0 < srcLen && (srcBytes[s0] & 0xC0) == 0x80 { s0 -= 1 }
                s1 = min(srcLen, max(seg.src.lowerBound, min(seg.src.upperBound, s1)))
                while s1 < srcLen && (srcBytes[s1] & 0xC0) == 0x80 { s1 += 1 }
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

/// Renders a `MarkdownParsedDoc` to clean copyable plain text iteratively (`rune_kit::markdown::plain`, #1122).
public enum MarkdownPlain {
    internal struct QuotePlainKey: Hashable {
        let id: ObjectIdentifier
        let firstTask: Int
        let cols: Int
        let lists: Int
    }

    internal struct QuotePlainEntry {
        let taskDelta: Int
        let breaks: (UInt8, UInt8)
        let text: String
    }

    internal typealias QuotePlainCache = [QuotePlainKey: QuotePlainEntry]

    private struct Piece {
        let breaks: (UInt8, UInt8)
        let text: String
    }

    private enum PlainFrame {
        case blocks(
            blocks: [MarkdownDocBlock],
            maps: [MarkdownBlockMap],
            pre: [MarkdownPreBlock]?,
            idx: Int,
            cols: Int,
            lists: Int,
            lead: (String, UInt8)?
        )
        case list(
            start: UInt64?,
            items: [[MarkdownDocBlock]],
            itemMaps: [[MarkdownBlockMap]],
            preItems: [MarkdownPreItem]?,
            idx: Int,
            cols: Int,
            lists: Int
        )
    }

    public static func render(
        blocks: [MarkdownDocBlock],
        tasks: [MarkdownTaskState?] = [],
        nextTask: inout Int
    ) -> String {
        var cache: QuotePlainCache = [:]
        return renderCached(
            quotePre: nil,
            blocks: blocks,
            maps: [],
            pre: nil,
            tasks: tasks,
            nextTask: &nextTask,
            cols: 0,
            lists: 0,
            cache: &cache
        )
    }

    public static func render(_ doc: MarkdownParsedDoc) -> String {
        var next = 0
        var cache: QuotePlainCache = [:]
        return renderCached(
            quotePre: nil,
            blocks: doc.blocks,
            maps: doc.maps,
            pre: nil,
            tasks: doc.tasks,
            nextTask: &next,
            cols: 0,
            lists: 0,
            cache: &cache
        )
    }

    internal static func renderCached(
        quotePre: MarkdownPreBlock?,
        blocks: [MarkdownDocBlock],
        maps: [MarkdownBlockMap],
        pre: [MarkdownPreBlock]?,
        tasks: [MarkdownTaskState?],
        nextTask: inout Int,
        cols: Int,
        lists: Int,
        cache: inout QuotePlainCache
    ) -> String {
        guard !blocks.isEmpty else { return "" }
        let firstTask = nextTask
        let cacheKey = quotePre.map { QuotePlainKey(id: ObjectIdentifier($0), firstTask: firstTask, cols: cols, lists: lists) }
        if let key = cacheKey, let hit = cache[key] {
            nextTask = firstTask + hit.taskDelta
            return hit.text
        }
        if blocks.count == 1, case let .quote(grand) = blocks[0] {
            if grand.isEmpty { return "" }
            if let childPre = pre?.first,
               let hit = cache[QuotePlainKey(id: ObjectIdentifier(childPre), firstTask: firstTask, cols: cols, lists: lists)] {
                if let key = cacheKey { cache[key] = hit }
                nextTask = firstTask + hit.taskDelta
                return hit.text
            }
        }

        var pieces: [Piece] = []
        plainIter(
            rootBlocks: blocks,
            rootMaps: maps,
            rootPre: pre,
            tasks: tasks,
            task: &nextTask,
            rootCols: cols,
            rootLists: lists,
            rootLead: nil,
            cache: cache,
            out: &pieces
        )
        let bounds: (UInt8, UInt8) = if let f = pieces.first, let l = pieces.last {
            (f.breaks.0, l.breaks.1)
        } else {
            (0, 0)
        }
        var out = ""
        let cap = pieces.reduce(0) { $0 + $1.text.utf8.count + 2 }
        out.reserveCapacity(cap)
        var after: UInt8 = 0
        for (i, p) in pieces.enumerated() {
            if i > 0 {
                let n = Int(max(after, p.breaks.0))
                if n > 0 { out.append(String(repeating: "\n", count: n)) }
            }
            out.append(p.text)
            after = p.breaks.1
        }
        if let key = cacheKey {
            let delta = max(0, nextTask - firstTask)
            cache[key] = QuotePlainEntry(taskDelta: delta, breaks: bounds, text: out)
        }
        return out
    }

    private static func plainIter(
        rootBlocks: [MarkdownDocBlock],
        rootMaps: [MarkdownBlockMap],
        rootPre: [MarkdownPreBlock]?,
        tasks: [MarkdownTaskState?],
        task: inout Int,
        rootCols: Int,
        rootLists: Int,
        rootLead: (String, UInt8)?,
        cache: QuotePlainCache,
        out: inout [Piece]
    ) {
        var stack: [PlainFrame] = [
            .blocks(blocks: rootBlocks, maps: rootMaps, pre: rootPre, idx: 0, cols: rootCols, lists: rootLists, lead: rootLead)
        ]
        while !stack.isEmpty {
            let topIdx = stack.count - 1
            switch stack[topIdx] {
            case let .blocks(blocks, maps, pre, idx, cols, lists, lead):
                if idx >= blocks.count {
                    stack.removeLast()
                    continue
                }
                let b = blocks[idx]
                let m: MarkdownBlockMap? = idx < maps.count ? maps[idx] : nil
                let p: MarkdownPreBlock? = pre.flatMap { idx < $0.count ? $0[idx] : nil }
                stack[topIdx] = .blocks(blocks: blocks, maps: maps, pre: pre, idx: idx + 1, cols: cols, lists: lists, lead: nil)
                let here = lead

                switch (b, m) {
                case let (.para(inl), .deepTail):
                    let pad = String(repeating: " ", count: cols)
                    var text = ""
                    text.reserveCapacity(inl.text.utf8.count + 16)
                    let lines = inl.text.split(separator: "\n", omittingEmptySubsequences: false)
                    for (j, line) in lines.enumerated() {
                        if j > 0 { text.append("\n") }
                        text.append(pad)
                        text.append(contentsOf: line)
                    }
                    out.append(Piece(breaks: (2, 2), text: text))
                case let (.para(inl), _), let (.heading(_, inl), _):
                    let text = MarkdownInline.unpadded(inl.text)
                    if let (marker, before) = here {
                        out.append(Piece(breaks: (before, 1), text: marker + text))
                    } else {
                        out.append(Piece(breaks: (2, 2), text: text))
                    }
                case let (.code(s), _), let (.diff(s), _), let (.mermaid(s), _):
                    var trimmed = s
                    while trimmed.hasSuffix("\n") { trimmed.removeLast() }
                    out.append(Piece(breaks: (2, 2), text: trimmed))
                case let (.quote(inner), mapOpt):
                    if inner.isEmpty { continue }
                    if here == nil, let p,
                       let hit = cache[QuotePlainKey(id: ObjectIdentifier(p), firstTask: task, cols: cols, lists: lists)] {
                        task += hit.taskDelta
                        if !hit.text.isEmpty {
                            out.append(Piece(breaks: hit.breaks, text: hit.text))
                        }
                        continue
                    }
                    let innerMaps: [MarkdownBlockMap] = if case let .quote(im) = mapOpt { im } else { [] }
                    stack.append(.blocks(blocks: inner, maps: innerMaps, pre: p?.inner, idx: 0, cols: cols, lists: lists, lead: here))
                case let (.list(start, items), mapOpt):
                    let itemMaps: [[MarkdownBlockMap]] = if case let .list(im) = mapOpt { im } else { [] }
                    stack.append(.list(start: start, items: items, itemMaps: itemMaps, preItems: p?.items, idx: 0, cols: cols, lists: lists))
                case let (.table(t), _):
                    func formatRow(_ cells: [MarkdownInline]) -> String {
                        cells.map { MarkdownInline.unpadded($0.text) }.joined(separator: "\t")
                    }
                    var rows = [formatRow(t.head)]
                    rows.reserveCapacity(t.rows.count + 1)
                    for r in t.rows { rows.append(formatRow(r)) }
                    out.append(Piece(breaks: (1, 1), text: rows.joined(separator: "\n")))
                case (.image, _), (.rule, _):
                    break
                }

            case let .list(start, items, itemMaps, preItems, idx, cols, lists):
                if idx >= items.count {
                    stack.removeLast()
                    continue
                }
                let k = idx
                stack[topIdx] = .list(start: start, items: items, itemMaps: itemMaps, preItems: preItems, idx: k + 1, cols: cols, lists: lists)
                let itemBlocks = items[k]
                let imap = k < itemMaps.count ? itemMaps[k] : []
                let ipre = preItems.flatMap { k < $0.count ? $0[k].inner : nil }
                if imap.count == 1, case .deepTail = imap[0] {
                    task += 1
                    stack.append(.blocks(blocks: itemBlocks, maps: imap, pre: ipre, idx: 0, cols: cols, lists: lists + 1, lead: nil))
                    continue
                }
                let checked: Bool? = task < tasks.count ? tasks[task]?.checked : nil
                task += 1
                let markText: String
                let markWidth: Int
                if let done = checked {
                    markText = done ? "- [x] " : "- [ ] "
                    markWidth = 2
                } else if let n = start {
                    let num = n + UInt64(k)
                    markText = "\(num). "
                    markWidth = String(num).count + 2
                } else {
                    markText = "- "
                    markWidth = 2
                }
                let marker = String(repeating: " ", count: cols) + markText
                let before: UInt8 = (k == 0 && lists == 0) ? 2 : 1
                stack.append(.blocks(
                    blocks: itemBlocks,
                    maps: imap,
                    pre: ipre,
                    idx: 0,
                    cols: cols + markWidth,
                    lists: lists + 1,
                    lead: (marker, before)
                ))
            }
        }
    }
}

// MARK: - Cache (`rune_kit::markdown::cache`)

private func markdownMayDefineReferences(in bytes: Substring.UTF8View) -> Bool {
    var bracket = false
    for byte in bytes {
        if bracket && byte == 0x3A { return true }
        bracket = byte == 0x5D
    }
    return false
}

/// Thread-safe LRU cache for parsed Markdown documents with incremental cut reuse, precomputed
/// 128-bit block digests (`PreBlock`), and streaming EOF deep-tail extension (`rune_kit::markdown::cache`).
public final class MarkdownDocCache: @unchecked Sendable {
    public static var shared: MarkdownDocCache {
        runeExecutionLocal(forKey: "rune.kit.markdown", create: { MarkdownDocCache() })
    }

    public static var sharedStream: MarkdownDocCache {
        runeExecutionLocal(forKey: "rune.kit.streamingMarkdown", create: { MarkdownDocCache(budgetBytes: 4 << 20) })
    }

    private struct Mode: Hashable, Sendable {
        let autolink: Bool
        let streaming: Bool
    }

    private struct Key: Hashable, Sendable {
        let text: KitSourceKey
        let mode: Mode
    }

    private struct ParsedEntry: Sendable {
        var doc: MarkdownParsedDoc
        var meta: [MarkdownPreBlock]
        /// When `src` ended inside an active `MarkdownBlockMap.deepTail` at EOF, holds
        /// `(cutStart, minCols)` so streamed tokens extending that tail update only the leaf.
        var eofDeepTail: (cutStart: Int, minCols: Int)?
    }

    private let lock = NSLock()
    private let docs: BudgetCache<Key, ParsedEntry>
    private struct Previous {
        let key: Key
        let mayDefineReferences: Bool
    }

    private var last: [Mode: Previous] = [:]
    private var fullParses = 0
    private var extensions = 0

    public convenience init(capacity: Int = .max, budgetBytes: Int = 16 << 20) {
        self.init(capacity: capacity, budgetBytes: budgetBytes, frameGeneration: Rune.commitGeneration)
    }

    init(capacity: Int = .max, budgetBytes: Int, frameGeneration: @escaping @Sendable () -> UInt64) {
        docs = BudgetCache(limitBytes: budgetBytes, entryLimit: capacity, frameGeneration: frameGeneration)
    }

    public var currentEntryCount: Int { docs.count }
    public var estimatedBytes: Int { docs.bytes }
    public var fullParseCount: Int { lock.withLock { fullParses } }
    public var incrementalExtendCount: Int { lock.withLock { extensions } }

    public func reset() {
        lock.withLock {
            docs.clear()
            last.removeAll()
            fullParses = 0
            extensions = 0
        }
    }

    public func peek(_ source: String, autolink: Bool = true, streaming: Bool? = nil) -> MarkdownParsedDoc? {
        let text = KitSourceKey(source)
        if let streaming {
            return docs.peek(Key(text: text, mode: Mode(autolink: autolink, streaming: streaming)))?.doc
        }
        return docs.peek(Key(text: text, mode: Mode(autolink: autolink, streaming: false)))?.doc
            ?? docs.peek(Key(text: text, mode: Mode(autolink: autolink, streaming: true)))?.doc
    }

    public func streamCached(_ source: String, autolink: Bool = true) -> MarkdownParsedDoc {
        cachedWithMeta(source, autolink: autolink, streaming: true).doc
    }

    public func docCached(_ source: String, autolink: Bool = true) -> MarkdownParsedDoc {
        cachedWithMeta(source, autolink: autolink, streaming: false).doc
    }

    internal func streamCachedWithMeta(_ source: String, autolink: Bool = true) -> (doc: MarkdownParsedDoc, meta: [MarkdownPreBlock]) {
        cachedWithMeta(source, autolink: autolink, streaming: true)
    }

    internal func docCachedWithMeta(_ source: String, autolink: Bool = true) -> (doc: MarkdownParsedDoc, meta: [MarkdownPreBlock]) {
        cachedWithMeta(source, autolink: autolink, streaming: false)
    }

    private func cachedWithMeta(_ source: String, autolink: Bool, streaming: Bool) -> (doc: MarkdownParsedDoc, meta: [MarkdownPreBlock]) {
        let mode = Mode(autolink: autolink, streaming: streaming)
        let key = Key(text: KitSourceKey(source), mode: mode)
        lock.lock()
        defer { lock.unlock() }
        if let hit = docs.get(key) { return (hit.doc, hit.meta) }

        let parse = streaming ? MarkdownTailStream.parseStreaming : MarkdownParser.parseDocument
        let grown = last[mode].flatMap { candidate in
            let old = candidate.key.text
            return source.utf8.count > old.source.utf8.count && key.text.starts(with: old) ? candidate : nil
        }
        // A reference definition can affect already-parsed links. Check the new bytes
        // and the one overlapping byte so an append split between "]" and ":" counts.
        let oldLength = grown?.key.text.source.utf8.count ?? 0
        let checkFrom = max(0, oldLength - 1)
        let bytes = source.utf8
        let checkAt = bytes.index(bytes.startIndex, offsetBy: checkFrom)
        let mayDefineReferences = grown?.mayDefineReferences == true || markdownMayDefineReferences(in: bytes[checkAt...])
        let entry: ParsedEntry
        if let grown, var base = docs.usedNow(grown.key) ? docs.peek(grown.key) : docs.take(grown.key),
           !mayDefineReferences,
           Self.tryExtend(base: &base, baseLen: oldLength, source: source, autolink: autolink, streaming: streaming, parse: parse) {
            entry = base
            extensions += 1
        } else {
            let parsed = parse(source, autolink)
            let meta = MarkdownMemoMeta.precomputeBlocks(parsed.blocks, maps: parsed.maps)
            let eofDeepTail = Self.detectEofDeepTail(source: source, blocks: parsed.blocks, maps: parsed.maps)
            entry = ParsedEntry(doc: parsed, meta: meta, eofDeepTail: eofDeepTail)
            fullParses += 1
        }
        let metaBytes = entry.meta.reduce(0) { $0 + $1.heapBytes() }
        docs.insert(key, value: entry, bytes: 2 * source.utf8.count + 64 * entry.doc.cuts.count + metaBytes + 128)
        last[mode] = Previous(key: key, mayDefineReferences: mayDefineReferences)
        return (entry.doc, entry.meta)
    }

    private static func detectEofDeepTail(
        source: String,
        blocks: [MarkdownDocBlock],
        maps: [MarkdownBlockMap]
    ) -> (cutStart: Int, minCols: Int)? {
        guard var b = blocks.last, var m = maps.last else { return nil }
        while true {
            switch (b, m) {
            case let (.list(_, items), .list(imaps)):
                guard let nb = items.last?.last, let nm = imaps.last?.last else { return nil }
                b = nb
                m = nm
            case let (.quote(inner), .quote(imaps)):
                guard let nb = inner.last, let nm = imaps.last else { return nil }
                b = nb
                m = nm
            case let (.para, .deepTail(_, spanMap)):
                guard let firstSrc = spanMap.segments.first?.src,
                      let lastSrc = spanMap.segments.last?.src else { return nil }
                let bytes = Array(source.utf8)
                guard lastSrc.upperBound <= bytes.count else { return nil }
                for k in lastSrc.upperBound..<bytes.count {
                    let ch = bytes[k]
                    if ch != 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D && ch != 0x0C {
                        return nil
                    }
                }
                var cutStart = 0
                if firstSrc.lowerBound > 0 {
                    var p = min(firstSrc.lowerBound, bytes.count)
                    while p > 0 {
                        if bytes[p - 1] == 0x0A {
                            cutStart = p
                            break
                        }
                        p -= 1
                    }
                }
                var nl = cutStart
                while nl < bytes.count && bytes[nl] != 0x0A { nl += 1 }
                let (cols, blank, fence) = MarkdownParser.lineIndentCols(bytes[cutStart..<nl])
                return (!blank && !fence && cols >= 4) ? (cutStart, cols) : nil
            default:
                return nil
            }
        }
    }

    /// Replaces the trailing `DeepTail` leaf iteratively (`O(1)` call stack).
    private static func replaceEofDeepTail(
        blocks: inout [MarkdownDocBlock],
        maps: inout [MarkdownBlockMap],
        newBlock: MarkdownDocBlock,
        newMap: MarkdownBlockMap
    ) -> Bool {
        enum SpineStep {
            case quote(blocks: [MarkdownDocBlock], maps: [MarkdownBlockMap])
            case list(start: UInt64?, items: [[MarkdownDocBlock]], itemMaps: [[MarkdownBlockMap]], lastItemBlocks: [MarkdownDocBlock], lastItemMaps: [MarkdownBlockMap])
        }
        guard !blocks.isEmpty, blocks.count == maps.count else { return false }
        var curBlock = blocks[blocks.count - 1]
        var curMap = maps[maps.count - 1]
        var spine: [SpineStep] = []
        while true {
            switch (curBlock, curMap) {
            case let (.list(start, items), .list(imaps)):
                guard let lastItem = items.last, let lastItemMap = imaps.last,
                      !lastItem.isEmpty, lastItem.count == lastItemMap.count else { return false }
                spine.append(.list(start: start, items: items, itemMaps: imaps, lastItemBlocks: lastItem, lastItemMaps: lastItemMap))
                curBlock = lastItem[lastItem.count - 1]
                curMap = lastItemMap[lastItemMap.count - 1]
            case let (.quote(inner), .quote(imaps)):
                guard !inner.isEmpty, inner.count == imaps.count else { return false }
                spine.append(.quote(blocks: inner, maps: imaps))
                curBlock = inner[inner.count - 1]
                curMap = imaps[imaps.count - 1]
            case (.para, .deepTail):
                curBlock = newBlock
                curMap = newMap
                while let step = spine.popLast() {
                    switch step {
                    case var .quote(qBlocks, qMaps):
                        qBlocks[qBlocks.count - 1] = curBlock
                        qMaps[qMaps.count - 1] = curMap
                        curBlock = .quote(qBlocks)
                        curMap = .quote(qMaps)
                    case let .list(start, itemsVal, imapsVal, lastItemBlocksVal, lastItemMapsVal):
                        var items = itemsVal
                        var imaps = imapsVal
                        var lastItemBlocks = lastItemBlocksVal
                        var lastItemMaps = lastItemMapsVal
                        lastItemBlocks[lastItemBlocks.count - 1] = curBlock
                        lastItemMaps[lastItemMaps.count - 1] = curMap
                        items[items.count - 1] = lastItemBlocks
                        imaps[imaps.count - 1] = lastItemMaps
                        curBlock = .list(start: start, items: items)
                        curMap = .list(imaps)
                    }
                }
                blocks[blocks.count - 1] = curBlock
                maps[maps.count - 1] = curMap
                return true
            default:
                return false
            }
        }
    }

    private static func replaceEofDeepTailMeta(
        baseMeta: [MarkdownPreBlock],
        blocks: [MarkdownDocBlock],
        maps: [MarkdownBlockMap]
    ) -> [MarkdownPreBlock]? {
        enum Spine {
            case quote(MarkdownPreBlock)
            case list(UInt64?, MarkdownPreBlock, MarkdownPreItem)
        }
        guard !blocks.isEmpty, baseMeta.count == blocks.count, maps.count == blocks.count else { return nil }
        let last = blocks.count - 1
        var b = blocks[last]
        var m = maps[last]
        var pb = baseMeta[last]
        var spine: [Spine] = []
        var cur: MarkdownPreBlock
        while true {
            switch (b, m) {
            case let (.list(start, items), .list(imaps)):
                guard pb.items.count == items.count,
                      let itemPb = pb.items.last,
                      let itemBlocks = items.last,
                      let itemMaps = imaps.last,
                      itemPb.inner.count == itemBlocks.count,
                      let nb = itemBlocks.last,
                      let nm = itemMaps.last,
                      let npb = itemPb.inner.last else { return nil }
                spine.append(.list(start, pb, itemPb))
                b = nb
                m = nm
                pb = npb
            case let (.quote(inner), .quote(imaps)):
                guard pb.inner.count == inner.count,
                      let nb = inner.last,
                      let nm = imaps.last,
                      let npb = pb.inner.last else { return nil }
                spine.append(.quote(pb))
                b = nb
                m = nm
                pb = npb
            case (.para, .deepTail):
                cur = MarkdownMemoMeta.precomputeBlock(b, map: m)
                while let step = spine.popLast() {
                    switch step {
                    case .quote(let oldQ):
                        var children = Array(oldQ.inner.dropLast())
                        children.append(cur)
                        cur = MarkdownMemoMeta.rebuildQuoteMeta(children)
                    case let .list(start, oldL, oldIt):
                        var itemChildren = Array(oldIt.inner.dropLast())
                        itemChildren.append(cur)
                        let newItem = MarkdownMemoMeta.rebuildItemMeta(itemChildren)
                        var items = Array(oldL.items.dropLast())
                        items.append(newItem)
                        cur = MarkdownMemoMeta.rebuildListMeta(start: start, items: items)
                    }
                }
                var out = Array(baseMeta.dropLast())
                out.append(cur)
                return out
            default:
                return nil
            }
        }
    }

    private static func extendEofDeepTail(
        base: inout ParsedEntry,
        baseLen: Int,
        source: String
    ) -> Bool {
        guard let (cutStart, minCols) = base.eofDeepTail else { return false }
        let bytes = Array(source.utf8)
        guard cutStart <= baseLen, baseLen <= bytes.count else { return false }
        var checkFrom = cutStart
        if baseLen > 0 {
            var p = baseLen
            while p > 0 {
                if bytes[p - 1] == 0x0A {
                    checkFrom = max(p, cutStart)
                    break
                }
                p -= 1
            }
        }
        // Check for "]:" reference definitions inside the appended tail
        if checkFrom + 1 < bytes.count {
            for k in checkFrom..<(bytes.count - 1) {
                if bytes[k] == 0x5D && bytes[k + 1] == 0x3A { return false }
            }
        }
        var pos = checkFrom
        while pos < bytes.count {
            var nl = pos
            while nl < bytes.count && bytes[nl] != 0x0A { nl += 1 }
            if nl < bytes.count {
                let (cols, _, fence) = MarkdownParser.lineIndentCols(bytes[pos..<nl])
                if fence || cols < minCols { return false }
                pos = nl + 1
            } else {
                let (cols, blank, fence) = MarkdownParser.lineIndentCols(bytes[pos..<bytes.count])
                if !blank && (fence || cols < minCols) { return false }
                break
            }
        }
        let (nb, nm) = MarkdownParser.buildDeepTail(source: source, range: cutStart..<bytes.count)
        guard replaceEofDeepTail(blocks: &base.doc.blocks, maps: &base.doc.maps, newBlock: nb, newMap: nm) else {
            return false
        }
        base.meta = replaceEofDeepTailMeta(baseMeta: base.meta, blocks: base.doc.blocks, maps: base.doc.maps)
            ?? MarkdownMemoMeta.precomputeBlocks(base.doc.blocks, maps: base.doc.maps)
        base.eofDeepTail = (cutStart, minCols)
        return true
    }

    private static func tryExtend(
        base: inout ParsedEntry,
        baseLen: Int,
        source: String,
        autolink: Bool,
        streaming: Bool,
        parse: (String, Bool) -> MarkdownParsedDoc
    ) -> Bool {
        if streaming && extendEofDeepTail(base: &base, baseLen: baseLen, source: source) {
            return true
        }
        return incrementalExtend(base: &base, baseLen: baseLen, source: source, autolink: autolink, parse: parse)
    }

    private static func incrementalExtend(
        base: inout ParsedEntry, baseLen: Int, source: String, autolink: Bool,
        parse: (String, Bool) -> MarkdownParsedDoc
    ) -> Bool {
        // A new reference definition changes links throughout the document. Only the
        // final block starting on a completed raw line is safe to rebuild independently.
        let bytes = source.utf8
        let oldEnd = bytes.index(bytes.startIndex, offsetBy: baseLen)
        guard let lastNewline = bytes[..<oldEnd].lastIndex(of: 0x0A) else { return false }
        let newlineOffset = bytes.distance(from: bytes.startIndex, to: lastNewline)
        guard let cutIdx = base.doc.cuts.lastIndex(where: { $0.at <= newlineOffset }) else { return false }
        let cut = base.doc.cuts[cutIdx]
        guard cut.at > 0, cut.blocks < base.doc.blocks.count,
              let tailStr = utf8Slice(source, range: cut.at..<bytes.count) else { return false }
        let tail = parse(tailStr, autolink)
        let shiftedMaps = tail.maps.map { $0.shiftedSrc(cut.at) }
        let tailMeta = MarkdownMemoMeta.precomputeBlocks(tail.blocks, maps: shiftedMaps)
        // Reuse the old arrays when the grown prefix was the sole owner. Array COW
        // keeps earlier snapshots and documents also drawn in this commit intact.
        base.doc.blocks.replaceSubrange(cut.blocks..., with: tail.blocks)
        base.meta.replaceSubrange(cut.blocks..., with: tailMeta)
        base.doc.sources.replaceSubrange(cut.sources..., with: tail.sources)
        base.doc.tasks.replaceSubrange(cut.tasks..., with: tail.tasks.map { task in
            task.map { MarkdownTaskState(checked: $0.checked, markerOffset: $0.markerOffset + cut.at) }
        })
        base.doc.blockStarts.replaceSubrange(cut.blocks..., with: tail.blockStarts.map { $0 + cut.at })
        base.doc.maps.replaceSubrange(cut.blocks..., with: shiftedMaps)
        base.doc.cuts.replaceSubrange(cutIdx..., with: tail.cuts.map {
            MarkdownCut(at: $0.at + cut.at, blocks: $0.blocks + cut.blocks, sources: $0.sources + cut.sources, tasks: $0.tasks + cut.tasks)
        })
        base.eofDeepTail = detectEofDeepTail(source: source, blocks: base.doc.blocks, maps: base.doc.maps)
        return true
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

    /// Returns the opening fence marker if `source` ends inside an unclosed fenced code block.
    static func unclosedFence(in source: String) -> String? {
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
        return openFence
    }

    /// Repairs unclosed fenced code blocks and unclosed inline delimiters at the tail of an incomplete Markdown stream.
    public static func stabilize(_ source: String) -> String {
        if let fence = unclosedFence(in: source) {
            var out = source
            if !out.hasSuffix("\n") {
                out.append("\n")
            }
            out.append(fence)
            return out
        }

        let work: String
        if let end = MarkdownTailStream.heldTableEndByte(in: source, parseLastBlock: {
            MarkdownParser.parseDocument(source, autolink: true).blocks.last
        }) {
            work = utf8Slice(source, range: 0..<end) ?? source
        } else {
            work = source
        }

        if let patch = MarkdownTailStream.closeTail(work) {
            let prefixEnd = work.utf8.index(work.utf8.startIndex, offsetBy: min(patch.cut, work.utf8.count))
            let rawKept = String(work[..<prefixEnd])
            let kept = patch.closers.isEmpty ? rawKept : rawKept.trimmingTrailingWhitespaceOnly()
            return kept + patch.closers
        }
        return work
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
        streaming
            ? MarkdownDocCache.sharedStream.streamCached(source, autolink: autolink)
            : MarkdownDocCache.shared.docCached(source, autolink: autolink)
    }

    static func parseStreaming(_ source: String, autolink: Bool) -> MarkdownParsedDoc {
        let (rawDoc, tail) = MarkdownParser.documentWithTail(source, autolink: autolink)
        if case .code = tail { return rawDoc }
        let end = Self.heldTableEndByte(in: source, parseLastBlock: { rawDoc.blocks.last }) ?? source.utf8.count
        let work = (end == source.utf8.count) ? source : (utf8Slice(source, range: 0..<end) ?? source)
        guard case let .inline(start, scope) = tail, start < end,
              let run = utf8Slice(source, range: start..<end),
              let patch = Self.scanRun(run, base: start, scope: scope) else {
            return (end == source.utf8.count) ? rawDoc : MarkdownParser.parseDocument(work, autolink: autolink)
        }
        if !patch.closers.isEmpty {
            let rawKept = utf8Slice(work, range: 0..<patch.cut) ?? work
            let kept = rawKept.trimmingTrailingWhitespaceOnly()
            let view = kept + patch.closers
            var doc = MarkdownParser.parseDocument(view, autolink: autolink)
            let added = kept.utf8.count..<view.utf8.count
            let anyMarkerShown = (patch.markers + [added]).contains { r in
                doc.maps.contains { Self.blockMap($0, shows: r) }
            }
            if !anyMarkerShown {
                if patch.inCode {
                    Self.dropClosingPad(in: &doc)
                }
                return doc
            }
        }
        let cutSrc = utf8Slice(work, range: 0..<patch.cut) ?? work
        let cutDoc = MarkdownParser.parseDocument(cutSrc, autolink: autolink)
        let rawCols = Self.tableColumns(in: rawDoc)
        if Self.tableColumns(in: cutDoc) >= rawCols {
            return cutDoc
        }
        // Leaving markers out of a header's last cell (`| a | *`) drops that column; keep it empty.
        let paddedDoc = MarkdownParser.parseDocument(cutSrc + "|", autolink: autolink)
        return Self.tableColumns(in: paddedDoc) >= rawCols ? paddedDoc : rawDoc
    }

    private static func tableColumns(in doc: MarkdownParsedDoc) -> Int {
        guard case let .table(t) = doc.blocks.last else { return 0 }
        return max(t.align.count, t.head.count)
    }

    private static func blockMap(_ map: MarkdownBlockMap, shows range: Range<Int>) -> Bool {
        func hit(_ spanMap: MarkdownSpanMap) -> Bool {
            spanMap.segments.contains { $0.src.lowerBound < range.upperBound && range.lowerBound < $0.src.upperBound }
        }
        var stack: [MarkdownBlockMap] = [map]
        while let m = stack.popLast() {
            switch m {
            case let .inline(sm), let .code(sm), let .deepTail(_, sm):
                if hit(sm) { return true }
            case let .list(items):
                for item in items { stack.append(contentsOf: item) }
            case let .quote(inner):
                stack.append(contentsOf: inner)
            case let .table(head, rows):
                if head.contains(where: hit) || rows.contains(where: { $0.contains(where: hit) }) {
                    return true
                }
            case .none:
                break
            }
        }
        return false
    }

    static func heldTableEndByte(in source: String, parseLastBlock: () -> MarkdownDocBlock?) -> Int? {
        var source = source
        return source.withUTF8 { heldTableEndByte(in: $0, parseLastBlock: parseLastBlock) }
    }

    private static func heldTableEndByte(in b: UnsafeBufferPointer<UInt8>, parseLastBlock: () -> MarkdownDocBlock?) -> Int? {
        let bodyEnd = (b.last == 0x0A) ? (b.count - 1) : b.count
        let open = (bodyEnd == b.count)
        func lineStart(before end: Int) -> Int {
            var p = end
            while p > 0 && b[p - 1] != 0x0A { p -= 1 }
            return p
        }
        func lineSlice(_ start: Int, _ end: Int) -> String {
            String(decoding: b[start..<end], as: UTF8.self)
        }
        func isPiped(_ s: String) -> Bool {
            s.drop(while: \.isWhitespace).hasPrefix("|")
        }
        func isDelim(_ s: String) -> Bool {
            s.trimmingCharacters(in: .whitespacesAndNewlines).allSatisfy { "|:- ".contains($0) }
        }
        func headerStart(at lineAt: Int) -> Int? {
            guard lineAt >= 1 else { return nil }
            let prevEnd = lineAt - 1
            let s = lineStart(before: prevEnd)
            let prevStr = lineSlice(s, prevEnd)
            guard isPiped(prevStr) && !isDelim(prevStr) else { return nil }
            if s > 0 {
                let aboveEnd = s - 1
                let aboveStart = lineStart(before: aboveEnd)
                if isPiped(lineSlice(aboveStart, aboveEnd)) { return nil }
            }
            return s
        }
        let lineAt = lineStart(before: bodyEnd)
        let curStr = lineSlice(lineAt, bodyEnd)
        guard isPiped(curStr) else { return nil }
        if case .table = parseLastBlock() {
            return nil
        }
        if open {
            if isDelim(curStr), let h = headerStart(at: lineAt) {
                return h
            }
            return lineAt
        }
        if lineAt == 0 { return lineAt }
        let prevEnd = lineAt - 1
        let prevStart = lineStart(before: prevEnd)
        return isPiped(lineSlice(prevStart, prevEnd)) ? nil : lineAt
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
        return scanRun(runStr, base: base, scope: .paragraph)
    }

    private static func scanRun(_ run: String, base: Int, scope: MarkdownTailScope) -> Patch? {
        if scope == .paragraph,
           run.split(separator: "\n", omittingEmptySubsequences: false).dropLast().contains(where: { $0.allSatisfy(\.isWhitespace) }) {
            return nil
        }
        let b = Array(run.utf8)
        var stack: [OpenDelimiter] = []
        var code: (at: Int, n: Int)?
        var cut = b.count
        var i = 0

        func charBefore(_ offset: Int) -> Character? {
            guard offset > 0 else { return nil }
            let index = run.utf8.index(run.utf8.startIndex, offsetBy: offset)
            return Character(run.unicodeScalars[run.unicodeScalars.index(before: index)])
        }
        func charAt(_ offset: Int) -> Character? {
            guard offset < b.count, b[offset] & 0xC0 != 0x80 else { return nil }
            let index = run.utf8.index(run.utf8.startIndex, offsetBy: offset)
            return Character(run.unicodeScalars[index])
        }

        while i < b.count {
            switch b[i] {
            case 0x5C: // '\\'
                i += 2
            case 0x0A where scope != .paragraph, 0x7C where scope == .cell:
                stack.removeAll(keepingCapacity: true)
                i += 1
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
                        var destCh: UInt8 = 0x28
                        let destination = String(decoding: afterParen, as: UTF8.self)
                        let title = destination.firstIndex(where: \.isWhitespace).map {
                            destination[$0...].drop(while: \.isWhitespace)
                        }
                        if let title, let quote = title.utf8.first, quote == 0x22 || quote == 0x27,
                           !(title.utf8.count > 1 && title.utf8.last == quote) {
                            destCh = quote
                        }
                        stack[p].ch = destCh
                        i = b.count
                    }
                } else {
                    stack.remove(at: p)
                    i += 1
                }
            case 0x68 where urlAt(runBytes: b, at: i, before: charBefore(i)), 0x77 where urlAt(runBytes: b, at: i, before: charBefore(i)): // 'h', 'w' bare URL
                var k = i
                while k < b.count {
                    if let c = charAt(k), c.isWhitespace { break }
                    k += 1
                }
                i = k
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
            while trimmed > 0 && b[trimmed - 1] == 0x60 { trimmed -= 1 }
            while trimmed > 0, let char = charBefore(trimmed), char.isWhitespace { trimmed -= char.utf8.count }
            if trimmed <= at + n {
                cut = at
                code = nil
            } else {
                cut = trimmed
            }
        }
        if code == nil {
            while let last = stack.last {
                let start = min(cut, last.at + last.count)
                let slice = String(decoding: b[start..<cut], as: UTF8.self).trimmingTrailingWhitespaceOnly()
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
                closers.append("]()")
            case 0x28:
                closers.append(")")
            case 0x22, 0x27:
                closers.append(String(UnicodeScalar(o.ch)))
                closers.append(")")
            default:
                closers.append(String(repeating: Character(UnicodeScalar(o.ch)), count: o.count))
            }
            markers.append((base + o.at)..<(base + o.at + o.count))
        }
        guard cut < b.count || !closers.isEmpty else { return nil }
        return Patch(cut: base + cut, closers: closers, markers: markers, inCode: code != nil)
    }

    private static func urlAt(runBytes b: [UInt8], at i: Int, before: Character?) -> Bool {
        let rest = b[i...]
        let matchesPrefix = rest.starts(with: "https://".utf8)
            || rest.starts(with: "http://".utf8)
            || rest.starts(with: "www.".utf8)
        guard matchesPrefix else { return false }
        guard let prev = before else { return true }
        return prev.isWhitespace || "(<[".contains(prev)
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
            inl.preparedBidi = MarkdownInlineBidi(inl)
        }
        enum WalkStep {
            case quote([MarkdownDocBlock], [MarkdownBlockMap])
            case list(UInt64?, [[MarkdownDocBlock]], [[MarkdownBlockMap]], [MarkdownDocBlock], [MarkdownBlockMap])
        }
        let last = doc.blocks.count - 1
        guard last < doc.maps.count else { return }
        var curBlock = doc.blocks[last]
        var curMap = doc.maps[last]
        var spine: [WalkStep] = []
        var modified = false
        while true {
            switch (curBlock, curMap) {
            case (var .para(inl), var .inline(m)):
                stripPad(&inl, &m)
                curBlock = .para(inl)
                curMap = .inline(m)
                modified = true
            case (let .heading(lvl, inlVal), var .inline(m)):
                var inl = inlVal
                stripPad(&inl, &m)
                curBlock = .heading(level: lvl, inl)
                curMap = .inline(m)
                modified = true
            case let (.quote(inner), .quote(im)) where !inner.isEmpty && !im.isEmpty:
                spine.append(.quote(inner, im))
                curBlock = inner[inner.count - 1]
                curMap = im[im.count - 1]
                continue
            case let (.list(start, items), .list(lm)) where !items.isEmpty && !lm.isEmpty:
                let lastItem = items[items.count - 1]
                let lastMap = lm[lm.count - 1]
                if !lastItem.isEmpty && !lastMap.isEmpty {
                    spine.append(.list(start, items, lm, lastItem, lastMap))
                    curBlock = lastItem[lastItem.count - 1]
                    curMap = lastMap[lastMap.count - 1]
                    continue
                }
            case (var .table(t), .table(var head, var rows)):
                if let ri = t.rows.indices.last, let ci = t.rows[ri].indices.last,
                   ri < rows.count, ci < rows[ri].count {
                    stripPad(&t.rows[ri][ci], &rows[ri][ci])
                } else if let hi = t.head.indices.last, hi < head.count {
                    stripPad(&t.head[hi], &head[hi])
                }
                curBlock = .table(t)
                curMap = .table(head: head, rows: rows)
                modified = true
            default:
                break
            }
            break
        }
        guard modified else { return }
        while let step = spine.popLast() {
            switch step {
            case var .quote(inner, im):
                inner[inner.count - 1] = curBlock
                im[im.count - 1] = curMap
                curBlock = .quote(inner)
                curMap = .quote(im)
            case let .list(start, itemsVal, lmVal, lastItemVal, lastMapVal):
                var items = itemsVal
                var lm = lmVal
                var lastItem = lastItemVal
                var lastMap = lastMapVal
                lastItem[lastItem.count - 1] = curBlock
                lastMap[lastMap.count - 1] = curMap
                items[items.count - 1] = lastItem
                lm[lm.count - 1] = lastMap
                curBlock = .list(start: start, items: items)
                curMap = .list(lm)
            }
        }
        doc.blocks[last] = curBlock
        doc.maps[last] = curMap
    }
}

// MARK: - Parser (`rune_kit::markdown::parser` + `interrupt`)

/// Streaming-friendly CommonMark + GFM Table + Task List + Footnote + Syntax Highlighting parser (`rune_kit::markdown::parser`).
fileprivate enum MarkdownTailScope { case paragraph, line, cell }

fileprivate enum MarkdownParseTail {
    case none, code
    case inline(Int, MarkdownTailScope)
}

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

    // MARK: Nesting Bounds (`crates/rune-kit/src/markdown/parser.rs`, #1122)

    /// Maximum open container elements under `<body>` matching Blink's 512-element HTML parser cap:
    /// 255 nested lists, 1 quote + 255 nested lists, or 510 non-empty block quotes on desktop.
    public static let maxElementDepth: Int = 511

    /// Maximum flattened items/blocks rendered individually inside a past-bound container before
    /// grouping remaining lines into one selectable, searchable plain block with a count marker.
    public static let maxFlattenedTailItems: Int = 64

    /// Maximum nested flex containers on targets without stack continuation (`wasm32`/`iOS`/`Android`):
    /// preserves all 255 nested lists (765), 1 quote + 255 lists (767), and caps pure block quotes at 385 (770).
    public static let maxUnguardedLayoutDepth: Int = 770

    #if os(Windows) || os(macOS) || os(Linux)
    internal static let defaultUnguardedLayoutLimit: Int? = nil
    #else
    internal static let defaultUnguardedLayoutLimit: Int? = maxUnguardedLayoutDepth
    #endif

    // MARK: Full Upstream AST Parse (`parseDocument` / `parseAST`)

    public static func parseAST(_ source: String, autolink: Bool = true) -> [MarkdownDocBlock] {
        parseDocument(source, autolink: autolink).blocks
    }

    public static func parseDocument(_ source: String, autolink: Bool = true) -> MarkdownParsedDoc {
        documentWithTail(source, autolink: autolink, unguardedLayoutLimit: defaultUnguardedLayoutLimit).0
    }

    internal static func parseDocument(
        _ source: String,
        autolink: Bool = true,
        unguardedLayoutLimit: Int?
    ) -> MarkdownParsedDoc {
        documentWithTail(source, autolink: autolink, unguardedLayoutLimit: unguardedLayoutLimit).0
    }

    /// Builds a single plain `.para` + `.deepTail` covering `source[range]`, stripping each line's
    /// outer container indentation (`' '`, `'\t'`, `'>'`) while mapping every kept byte 1-to-1 back
    /// to `source` so Find, highlights, selection and copy preserve all lines (`parser::build_deep_tail`).
    internal static func buildDeepTail(source: String, range: Range<Int>) -> (MarkdownDocBlock, MarkdownBlockMap) {
        let bytes = Array(source.utf8)
        var pos = max(0, min(range.lowerBound, bytes.count))
        let end = max(pos, min(range.upperBound, bytes.count))
        var out = ""
        out.reserveCapacity(end - pos)
        var map = MarkdownSpanMap()
        var lines = 0

        while pos < end {
            var nl = pos
            while nl < end && bytes[nl] != 0x0A { nl += 1 }
            let lineEnd = (nl > pos && bytes[nl - 1] == 0x0D) ? (nl - 1) : nl
            var k = pos
            while k < lineEnd {
                switch bytes[k] {
                case 0x20, 0x09:
                    k += 1
                case 0x3E: // '>'
                    k += 1
                    if k < lineEnd && bytes[k] == 0x20 { k += 1 }
                default:
                    break
                }
                if k < lineEnd && bytes[k] != 0x20 && bytes[k] != 0x09 && bytes[k] != 0x3E {
                    break
                }
            }
            if k < lineEnd {
                lines += 1
                if !out.isEmpty {
                    let nlOut = out.utf8.count
                    out.append("\n")
                    if pos > range.lowerBound && bytes[pos - 1] == 0x0A {
                        map.push(src: (pos - 1)..<pos, out: nlOut..<(nlOut + 1))
                    }
                }
                let o0 = out.utf8.count
                out.append(String(decoding: bytes[k..<lineEnd], as: UTF8.self))
                map.push(src: k..<lineEnd, out: o0..<out.utf8.count)
            }
            pos = nl < end ? (nl + 1) : end
        }
        var inl = MarkdownInline(text: out)
        inl.preparedBidi = MarkdownInlineBidi(inl)
        return (.para(inl), .deepTail(lines: max(1, lines), map: map))
    }

    internal static func lineIndentCols(_ line: ArraySlice<UInt8>) -> (cols: Int, blank: Bool, fence: Bool) {
        var i = line.startIndex
        let end = line.endIndex
        var cols = 0
        while i < end {
            switch line[i] {
            case 0x20:
                cols += 1
                i += 1
            case 0x09:
                cols += 4
                i += 1
            case 0x3E: // '>'
                cols += 2
                i += 1
                if i < end && line[i] == 0x20 { i += 1 }
            case 0x0D:
                i += 1
            default:
                let rest = line[i..<end]
                let fence = rest.starts(with: [0x60, 0x60, 0x60]) || rest.starts(with: [0x7E, 0x7E, 0x7E])
                return (cols, false, fence)
            }
        }
        return (cols, true, false)
    }

    fileprivate static func documentWithTail(
        _ source: String,
        autolink: Bool,
        unguardedLayoutLimit: Int? = defaultUnguardedLayoutLimit
    ) -> (MarkdownParsedDoc, MarkdownParseTail) {
        let lines = splitLineSlices(source)
        var parser = DocumentParser(
            source: source,
            baseOffset: 0,
            autolink: autolink,
            unguardedLayoutLimit: unguardedLayoutLimit
        )
        let first = parser.parseRoot(lines: lines)
        // A later definition can resolve an earlier link or lift an earlier image into a block.
        guard let firstBlock = first.blockStarts.first, let lastDefinition = parser.lastNewDefinition,
              firstBlock < lastDefinition else { return (first, parser.tail) }
        let resolved = parser.parseRoot(lines: lines)
        return (resolved, parser.tail)
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

    private static func collectLinkDefinitions(in source: String) -> [KitSourceKey: LinkDefinition] {
        guard markdownMayDefineReferences(in: source.utf8[...]) else { return [:] }
        var parser = DocumentParser(source: source, baseOffset: 0, autolink: false, unguardedLayoutLimit: defaultUnguardedLayoutLimit)
        _ = parser.parseRoot(lines: splitLineSlices(source))
        return parser.definitions
    }

    /// Raw blocks inside a list or quote require the container prefix on every line.
    private struct ContainerHTMLTail {
        private var active: MarkdownHTML.BlockEnd?
        private var fence: (char: Character, count: Int)?
        private var paragraph = false
        private(set) var followsHTML = false

        mutating func append(_ line: String) {
            if let fence {
                if isFenceCloser(line, fenceChar: fence.char, minLen: fence.count) { self.fence = nil }
                return
            }
            if let active {
                if case .blankLine = active, line.utf8.allSatisfy({ $0 == 9 || $0 == 32 }) {
                    self.active = nil
                } else {
                    if case let .marker(marker) = active, line.contains(marker) { self.active = nil }
                    return
                }
            }
            if let start = MarkdownHTML.blockStart(in: line, interruptsParagraph: paragraph) {
                active = start
                if case let .marker(marker) = start, line.contains(marker) { active = nil }
                followsHTML = true
                paragraph = false
            } else {
                followsHTML = false
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                if let first = trimmed.first, first == "`" || first == "~", let header = parseFenceHeader(line) {
                    fence = (header.char, header.count)
                    paragraph = false
                } else if trimmed.first == "#",
                          parseATXHeading(source: line, lineRange: 0..<line.utf8.count) != nil {
                    paragraph = false
                } else if let first = trimmed.first, first == "-" || first == "*" || first == "_" {
                    paragraph = !isHorizontalRule(String(trimmed))
                } else {
                    paragraph = !trimmed.isEmpty
                }
            }
        }
    }

    private struct DocumentParser {
        let source: String
        let baseOffset: Int
        var definitions: [KitSourceKey: LinkDefinition] = [:]
        var lastNewDefinition: Int?
        var mayDefineReferences: Bool?
        let autolink: Bool
        let unguardedLayoutLimit: Int?
        var tail: MarkdownParseTail = .none

        private struct PendingListItem {
            var slices: [LineSlice]
            var task: MarkdownTaskState?
            var rawStart: Int
        }

        private enum ParseFrame {
            case root(lines: [LineSlice], index: Int, blocks: [MarkdownDocBlock], maps: [MarkdownBlockMap], starts: [Int])
            case quote(lines: [LineSlice], index: Int, blockStart: Int, blocks: [MarkdownDocBlock], maps: [MarkdownBlockMap])
            case mergedQuote(lines: [LineSlice], index: Int, rangeEnd: Int)
            case list(blockStart: Int, start: UInt64?, pendingItems: [PendingListItem], nextItem: Int, items: [[MarkdownDocBlock]], itemMaps: [[MarkdownBlockMap]])
            case siblingList(pendingItems: [PendingListItem], nextItem: Int, rangeEnd: Int)
            case item(lines: [LineSlice], index: Int, blocks: [MarkdownDocBlock], maps: [MarkdownBlockMap])
            case tailLines(lines: [LineSlice], index: Int)

            var elementCost: Int {
                switch self {
                case .quote, .list, .item: return 1
                case .root, .mergedQuote, .siblingList, .tailLines: return 0
                }
            }

            var layoutCost: Int {
                switch self {
                case .quote, .item: return 2
                case .list: return 1
                case .root, .mergedQuote, .siblingList, .tailLines: return 0
                }
            }
        }

        mutating func parseRoot(lines: [LineSlice]) -> MarkdownParsedDoc {
            var doc = MarkdownParsedDoc()
            parseIterative(
                rootLines: lines,
                into: &doc.blocks,
                maps: &doc.maps,
                sources: &doc.sources,
                tasks: &doc.tasks,
                blockStarts: &doc.blockStarts,
                cuts: &doc.cuts
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

        private mutating func referenceDefinition(firstLine: String, lines: [LineSlice], at start: Int) -> MarkdownReference? {
            if mayDefineReferences == nil { mayDefineReferences = markdownMayDefineReferences(in: source.utf8[...]) }
            guard mayDefineReferences == true else { return nil }
            return MarkdownReference.scan(firstLine: firstLine) { relative in
                let index = start + relative
                guard index < lines.count, let line = utf8Slice(source, range: lines[index].contentRange) else { return nil }
                // Four spaces after a definition's opening line permit a destination or
                // title even when the same text at the margin would begin a new block.
                if indentWidth(line) >= 4 { return line }
                let text = line.trimmingCharacters(in: .whitespaces)
                guard let first = text.first, first != ">",
                      !isHorizontalRule(text), !isFenceHeaderBool(line),
                      parseATXHeading(source: line, lineRange: 0..<line.utf8.count) == nil,
                      MarkdownHTML.blockStart(in: line, interruptsParagraph: true) == nil else { return nil }
                if (first == "-" || first == "=") && text.allSatisfy({ $0 == first }) { return nil }
                if let item = parseListMarker(line), !item.ordered || item.start == 1,
                   !line.utf8.dropFirst(item.contentOffsetBytes).allSatisfy({ $0 == 32 || $0 == 9 }) { return nil }
                if first == "|", index + 1 < lines.count,
                   let delimiter = utf8Slice(source, range: lines[index + 1].contentRange),
                   let align = parseTableDelimiterAlignments(delimiter),
                   align.count == splitTableRow(text, baseOffset: 0).count { return nil }
                return line
            }
        }

        /// Iterative CommonMark + GFM parser enforcing the 511-element nesting bound, optional
        /// 770 flex-container cap on unguarded platforms, and lossless 64-item deep-tail grouping
        /// (`crates/rune-kit/src/markdown/parser.rs`, #1122).
        private mutating func parseIterative(
            rootLines: [LineSlice],
            into outBlocks: inout [MarkdownDocBlock],
            maps outMaps: inout [MarkdownBlockMap],
            sources: inout [MarkdownCodeSource],
            tasks: inout [MarkdownTaskState?],
            blockStarts outStarts: inout [Int],
            cuts: inout [MarkdownCut]
        ) {
            let sourceBytes = Array(source.utf8)
            var frames: [ParseFrame] = [.root(lines: rootLines, index: 0, blocks: [], maps: [], starts: [])]
            var elementDepth = 0
            var layoutCost = 0
            var pastBoundItems = 0

            func layoutFits(_ add: Int) -> Bool {
                guard let limit = unguardedLayoutLimit else { return true }
                return layoutCost + add <= limit
            }

            func pushFrame(_ frame: ParseFrame) {
                elementDepth += frame.elementCost
                layoutCost += frame.layoutCost
                frames.append(frame)
            }

            func popFrame() -> ParseFrame {
                let frame = frames.removeLast()
                elementDepth -= frame.elementCost
                layoutCost -= frame.layoutCost
                return frame
            }

            func firstMergedQuoteIndex() -> Int? {
                for idx in frames.indices {
                    if case .mergedQuote = frames[idx] { return idx }
                }
                return nil
            }

            func firstSiblingListIndex() -> Int? {
                for idx in frames.indices {
                    if case .siblingList = frames[idx] { return idx }
                }
                return nil
            }

            func nearestRealContainerIndex() -> Int {
                for idx in stride(from: frames.count - 1, through: 0, by: -1) {
                    switch frames[idx] {
                    case .root, .quote, .list, .item: return idx
                    case .mergedQuote, .siblingList, .tailLines: continue
                    }
                }
                return 0
            }

            func topRealIsListOrItem() -> Bool {
                let idx = nearestRealContainerIndex()
                switch frames[idx] {
                case .list, .item: return true
                default: return false
                }
            }

            func appendToNearestRealContainer(_ block: MarkdownDocBlock, map: MarkdownBlockMap, blockStart: Int) {
                switch block {
                case let .para(inline), let .heading(_, inline):
                    if inline.text.isEmpty { return }
                default:
                    break
                }
                let idx = nearestRealContainerIndex()
                switch frames[idx] {
                case .root(let lines, let cursor, var blocks, var maps, var starts):
                    blocks.append(block)
                    maps.append(map)
                    starts.append(blockStart)
                    frames[idx] = .root(lines: lines, index: cursor, blocks: blocks, maps: maps, starts: starts)
                case .quote(let lines, let cursor, let bs, var blocks, var maps):
                    blocks.append(block)
                    maps.append(map)
                    frames[idx] = .quote(lines: lines, index: cursor, blockStart: bs, blocks: blocks, maps: maps)
                case .item(let lines, let cursor, var blocks, var maps):
                    blocks.append(block)
                    maps.append(map)
                    frames[idx] = .item(lines: lines, index: cursor, blocks: blocks, maps: maps)
                case .list(let bs, let start, let pending, let nextIt, var items, var itemMaps):
                    if !items.isEmpty {
                        items[items.count - 1].append(block)
                        itemMaps[itemMaps.count - 1].append(map)
                    } else {
                        tasks.append(nil)
                        items.append([block])
                        itemMaps.append([map])
                    }
                    frames[idx] = .list(blockStart: bs, start: start, pendingItems: pending, nextItem: nextIt, items: items, itemMaps: itemMaps)
                case .mergedQuote, .siblingList, .tailLines:
                    preconditionFailure("nearestRealContainerIndex returned non-real frame")
                }
            }

            func appendCompletedItem(blocks: [MarkdownDocBlock], maps: [MarkdownBlockMap]) {
                for idx in stride(from: frames.count - 1, through: 0, by: -1) {
                    if case .list(let bs, let start, let pending, let nextIt, var items, var itemMaps) = frames[idx] {
                        items.append(blocks)
                        itemMaps.append(maps)
                        frames[idx] = .list(blockStart: bs, start: start, pendingItems: pending, nextItem: nextIt, items: items, itemMaps: itemMaps)
                        return
                    }
                }
            }

            func emitDeepTail(range: Range<Int>) {
                guard range.lowerBound < range.upperBound else { return }
                let (block, bmap) = MarkdownParser.buildDeepTail(source: source, range: range)
                let idx = nearestRealContainerIndex()
                if case .list(let bs, let start, let pending, let nextIt, var items, var itemMaps) = frames[idx] {
                    tasks.append(nil)
                    items.append([block])
                    itemMaps.append([bmap])
                    frames[idx] = .list(blockStart: bs, start: start, pendingItems: pending, nextItem: nextIt, items: items, itemMaps: itemMaps)
                } else {
                    appendToNearestRealContainer(block, map: bmap, blockStart: range.lowerBound)
                }
            }

            func deepTailCutStart(at byteOffset: Int) -> Int {
                let clamped = max(0, min(byteOffset, sourceBytes.count))
                var lineStart = 0
                if clamped > 0 {
                    var p = clamped
                    while p > 0 {
                        if sourceBytes[p - 1] == 0x0A {
                            lineStart = p
                            break
                        }
                        p -= 1
                    }
                }
                // Only rewind to line start if everything between lineStart and clamped is container indentation.
                var k = lineStart
                while k < clamped {
                    let ch = sourceBytes[k]
                    if ch == 0x20 || ch == 0x09 || ch == 0x3E {
                        k += 1
                    } else {
                        return clamped
                    }
                }
                return lineStart
            }

            func unwindAbove(_ targetIdx: Int) {
                while frames.count > targetIdx + 1 {
                    let popped = popFrame()
                    switch popped {
                    case let .quote(_, _, bs, blocks, maps):
                        appendToNearestRealContainer(.quote(blocks), map: .quote(maps), blockStart: bs)
                    case let .list(bs, start, _, _, items, itemMaps):
                        if !items.isEmpty {
                            appendToNearestRealContainer(.list(start: start, items: items), map: .list(itemMaps), blockStart: bs)
                        }
                    case let .item(_, _, blocks, maps):
                        appendCompletedItem(blocks: blocks, maps: maps)
                    case .mergedQuote, .siblingList, .tailLines, .root:
                        break
                    }
                }
            }

            func isInFreshItem() -> Bool {
                if case let .item(_, _, blocks, _) = frames.last {
                    return blocks.isEmpty
                }
                return false
            }

            func triggerDeepTailIfMergedQuoteExceeded(blockStartByte: Int) -> Bool {
                guard !isInFreshItem(), let mqIdx = firstMergedQuoteIndex() else { return false }
                pastBoundItems += 1
                guard pastBoundItems > MarkdownParser.maxFlattenedTailItems else { return false }
                let ce: Int = if case let .mergedQuote(_, _, rangeEnd) = frames[mqIdx] { rangeEnd } else { sourceBytes.count }
                let cs = deepTailCutStart(at: blockStartByte)
                unwindAbove(mqIdx)
                _ = popFrame()
                pastBoundItems = 0
                tail = .none
                emitDeepTail(range: cs..<ce)
                return true
            }

            func advanceLineCursor(to newIndex: Int) {
                let topIdx = frames.count - 1
                switch frames[topIdx] {
                case let .root(lines, _, blocks, maps, starts):
                    frames[topIdx] = .root(lines: lines, index: newIndex, blocks: blocks, maps: maps, starts: starts)
                case let .quote(lines, _, bs, blocks, maps):
                    frames[topIdx] = .quote(lines: lines, index: newIndex, blockStart: bs, blocks: blocks, maps: maps)
                case let .mergedQuote(lines, _, rangeEnd):
                    frames[topIdx] = .mergedQuote(lines: lines, index: newIndex, rangeEnd: rangeEnd)
                case let .item(lines, _, blocks, maps):
                    frames[topIdx] = .item(lines: lines, index: newIndex, blocks: blocks, maps: maps)
                case let .tailLines(lines, _):
                    frames[topIdx] = .tailLines(lines: lines, index: newIndex)
                case .list, .siblingList:
                    break
                }
            }

            while !frames.isEmpty {
                let topIdx = frames.count - 1
                switch frames[topIdx] {
                case let .list(bs, start, pendingItems, nextItem, items, itemMaps):
                    if nextItem >= pendingItems.count {
                        _ = popFrame()
                        appendToNearestRealContainer(.list(start: start, items: items), map: .list(itemMaps), blockStart: bs)
                        continue
                    }
                    let next = pendingItems[nextItem]
                    frames[topIdx] = .list(blockStart: bs, start: start, pendingItems: pendingItems, nextItem: nextItem + 1, items: items, itemMaps: itemMaps)

                    if firstMergedQuoteIndex() != nil || firstSiblingListIndex() != nil {
                        pastBoundItems += 1
                        if pastBoundItems > MarkdownParser.maxFlattenedTailItems {
                            let cs = deepTailCutStart(at: next.rawStart)
                            if let mqIdx = firstMergedQuoteIndex() {
                                let ce: Int = if case let .mergedQuote(_, _, rangeEnd) = frames[mqIdx] { rangeEnd } else { sourceBytes.count }
                                unwindAbove(mqIdx)
                                _ = popFrame()
                                pastBoundItems = 0
                                tail = .none
                                emitDeepTail(range: cs..<ce)
                            } else if let slIdx = firstSiblingListIndex() {
                                let ce: Int = if case let .siblingList(_, _, rangeEnd) = frames[slIdx] { rangeEnd } else { sourceBytes.count }
                                unwindAbove(slIdx)
                                _ = popFrame()
                                pastBoundItems = 0
                                tail = .none
                                emitDeepTail(range: cs..<ce)
                            }
                            continue
                        }
                    }

                    if let startByte = next.slices.first?.contentRange.lowerBound {
                        tail = .inline(startByte, .paragraph)
                    }
                    tasks.append(next.task)
                    pushFrame(.item(lines: next.slices, index: 0, blocks: [], maps: []))
                    continue

                case let .siblingList(pendingItems, nextItem, rangeEnd):
                    if nextItem >= pendingItems.count {
                        _ = popFrame()
                        if firstSiblingListIndex() == nil && firstMergedQuoteIndex() == nil {
                            pastBoundItems = 0
                        }
                        continue
                    }
                    let next = pendingItems[nextItem]
                    frames[topIdx] = .siblingList(pendingItems: pendingItems, nextItem: nextItem + 1, rangeEnd: rangeEnd)

                    pastBoundItems += 1
                    if pastBoundItems > MarkdownParser.maxFlattenedTailItems {
                        let cs = deepTailCutStart(at: next.rawStart)
                        if let mqIdx = firstMergedQuoteIndex() {
                            let ce: Int = if case let .mergedQuote(_, _, qEnd) = frames[mqIdx] { qEnd } else { sourceBytes.count }
                            unwindAbove(mqIdx)
                            _ = popFrame()
                            pastBoundItems = 0
                            tail = .none
                            emitDeepTail(range: cs..<ce)
                        } else if let slIdx = firstSiblingListIndex() {
                            let ce: Int = if case let .siblingList(_, _, sEnd) = frames[slIdx] { sEnd } else { sourceBytes.count }
                            unwindAbove(slIdx)
                            _ = popFrame()
                            pastBoundItems = 0
                            tail = .none
                            emitDeepTail(range: cs..<ce)
                        }
                        continue
                    }

                    if let startByte = next.slices.first?.contentRange.lowerBound {
                        tail = .inline(startByte, .paragraph)
                    }
                    tasks.append(next.task)
                    pushFrame(.item(lines: next.slices, index: 0, blocks: [], maps: []))
                    continue

                case .root, .quote, .mergedQuote, .item, .tailLines:
                    break
                }

                let lines: [LineSlice]
                let i: Int
                let isRoot: Bool
                let rootBlockCount: Int
                switch frames[topIdx] {
                case let .root(l, idx, blocks, _, _):
                    lines = l; i = idx; isRoot = true; rootBlockCount = blocks.count
                case let .quote(l, idx, _, _, _):
                    lines = l; i = idx; isRoot = false; rootBlockCount = 0
                case let .mergedQuote(l, idx, _):
                    lines = l; i = idx; isRoot = false; rootBlockCount = 0
                case let .item(l, idx, _, _):
                    lines = l; i = idx; isRoot = false; rootBlockCount = 0
                case let .tailLines(l, idx):
                    lines = l; i = idx; isRoot = false; rootBlockCount = 0
                case .list, .siblingList:
                    continue
                }

                if i >= lines.count {
                    let finished = popFrame()
                    switch finished {
                    case let .root(_, _, blocks, maps, starts):
                        outBlocks = blocks
                        outMaps = maps
                        outStarts = starts
                    case let .quote(_, _, bs, blocks, maps):
                        appendToNearestRealContainer(.quote(blocks), map: .quote(maps), blockStart: bs)
                    case .mergedQuote:
                        if firstMergedQuoteIndex() == nil && firstSiblingListIndex() == nil {
                            pastBoundItems = 0
                        }
                    case let .item(_, _, blocks, maps):
                        appendCompletedItem(blocks: blocks, maps: maps)
                    case .tailLines, .list, .siblingList:
                        break
                    }
                    continue
                }

                let raw = utf8Slice(source, range: lines[i].contentRange) ?? ""
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    advanceLineCursor(to: i + 1)
                    continue
                }

                // A reference is defined at a block start, including inside a list item or quote.
                if trimmed.hasPrefix("["), indentWidth(raw) < 4,
                   let reference = referenceDefinition(firstLine: raw, lines: lines, at: i) {
                    let key = KitSourceKey(reference.key)
                    if definitions[key] == nil {
                        definitions[key] = LinkDefinition(url: unescapeMarkdown(reference.rawDestination),
                                                          title: reference.rawTitle.map(unescapeMarkdown) ?? "")
                        lastNewDefinition = lines[i].contentRange.lowerBound
                    }
                    advanceLineCursor(to: i + reference.lineCount)
                    continue
                }

                let blockStartByte = lines[i].contentRange.lowerBound
                if isRoot {
                    pastBoundItems = 0
                    cuts.append(MarkdownCut(
                        at: blockStartByte,
                        blocks: rootBlockCount,
                        sources: sources.count,
                        tasks: tasks.count
                    ))
                }

                if let end = MarkdownHTML.blockStart(in: raw) {
                    tail = .code
                    var line = raw
                    var nextI = i
                    while true {
                        nextI += 1
                        if case let .marker(marker) = end, line.contains(marker) { break }
                        guard nextI < lines.count else { break }
                        line = utf8Slice(source, range: lines[nextI].contentRange) ?? ""
                        if case .blankLine = end, line.utf8.allSatisfy({ $0 == 32 || $0 == 9 }) { break }
                    }
                    advanceLineCursor(to: nextI)
                    continue
                }

                // 1. Fenced code block (``` or ~~~)
                if let fence = parseFenceHeader(raw) {
                    if triggerDeepTailIfMergedQuoteExceeded(blockStartByte: blockStartByte) { continue }
                    tail = .code
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
                    let hasTrailing = j <= lines.count && !closed && lines.last.map { $0.lineEnd > $0.contentRange.upperBound } == true
                    let (codeText, codeMap) = buildCodeTextAndMap(source: source, baseOffset: baseOffset, lineRanges: codeRanges, closed: closed, hasTrailingNewline: hasTrailing)
                    let langLower = fence.lang?.lowercased()
                    if langLower == "diff" || langLower == "patch" {
                        appendToNearestRealContainer(.diff(codeText), map: .code(codeMap), blockStart: blockStartByte)
                    } else if langLower == "mermaid" {
                        let coloured = (closed || hasTrailing) ? codeText.utf8.count : lastNewlineCut(codeText)
                        sources.append(MarkdownCodeSource(language: fence.lang, open: !closed, colouredBytes: coloured, length: codeText.utf8.count))
                        appendToNearestRealContainer(.mermaid(codeText), map: .code(codeMap), blockStart: blockStartByte)
                    } else {
                        let coloured = (closed || hasTrailing) ? codeText.utf8.count : lastNewlineCut(codeText)
                        sources.append(MarkdownCodeSource(language: fence.lang, open: !closed, colouredBytes: coloured, length: codeText.utf8.count))
                        appendToNearestRealContainer(.code(codeText), map: .code(codeMap), blockStart: blockStartByte)
                    }
                    advanceLineCursor(to: j)
                    continue
                }

                // 2. Thematic break (---, ***, ___) — must precede heading/list check
                if isHorizontalRule(trimmed) {
                    tail = .none
                    appendToNearestRealContainer(.rule, map: .none, blockStart: blockStartByte)
                    advanceLineCursor(to: i + 1)
                    continue
                }

                // 3. ATX Heading (# ... ######)
                if let (level, headingContentRange) = parseATXHeading(source: source, lineRange: lines[i].contentRange) {
                    if triggerDeepTailIfMergedQuoteExceeded(blockStartByte: blockStartByte) { continue }
                    tail = .inline(blockStartByte, .line)
                    let headingStr = utf8Slice(source, range: headingContentRange) ?? ""
                    let (inl, spanMap, _) = parseInline(
                        headingStr,
                        baseOffset: baseOffset + headingContentRange.lowerBound,
                        autolink: autolink,
                        definitions: definitions,
                        trimTrailingCodePad: true
                    )
                    appendToNearestRealContainer(.heading(level: level, inl), map: .inline(spanMap), blockStart: blockStartByte)
                    advanceLineCursor(to: i + 1)
                    continue
                }

                // 4. Indented code block (4 spaces or leading tab)
                if isIndentedCodeLine(raw) {
                    if triggerDeepTailIfMergedQuoteExceeded(blockStartByte: blockStartByte) { continue }
                    tail = .code
                    var ranges: [Range<Int>] = []
                    var j = i
                    while j < lines.count {
                        let rStr = utf8Slice(source, range: lines[j].contentRange) ?? ""
                        if rStr.trimmingCharacters(in: .whitespaces).isEmpty {
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
                    appendToNearestRealContainer(.code(codeText), map: .code(codeMap), blockStart: blockStartByte)
                    advanceLineCursor(to: j)
                    continue
                }

                // 5. Blockquote (> ...)
                if trimmed.hasPrefix(">") {
                    var innerLines: [LineSlice] = []
                    var html = ContainerHTMLTail()
                    var j = i
                    while j < lines.count {
                        let lStr = utf8Slice(source, range: lines[j].contentRange) ?? ""
                        let lTrim = lStr.drop(while: { $0 == " " })
                        if lTrim.hasPrefix(">") {
                            let leadSpaces = lStr.utf8.count - String(lTrim).utf8.count
                            var dropBytes = leadSpaces + 1 // '>'
                            if lTrim.dropFirst().first == " " { dropBytes += 1 }
                            let cStart = min(lines[j].contentRange.upperBound, lines[j].contentRange.lowerBound + dropBytes)
                            let slice = LineSlice(contentRange: cStart..<lines[j].contentRange.upperBound, lineEnd: lines[j].lineEnd)
                            html.append(utf8Slice(source, range: slice.contentRange) ?? "")
                            innerLines.append(slice)
                            j += 1
                        } else if lStr.trimmingCharacters(in: .whitespaces).isEmpty {
                            break
                        } else if !innerLines.isEmpty && !html.followsHTML && MarkdownHTML.blockStart(in: lStr, interruptsParagraph: true) == nil && !isFenceHeaderBool(lStr) && !isHorizontalRule(lStr.trimmingCharacters(in: .whitespaces)) && parseATXHeading(source: source, lineRange: lines[j].contentRange) == nil && parseListMarker(lStr) == nil {
                            // Lazy continuation line
                            innerLines.append(lines[j])
                            j += 1
                        } else {
                            break
                        }
                    }
                    let quoteRangeEnd = (j > i ? lines[j - 1].lineEnd : lines[i].lineEnd)
                    advanceLineCursor(to: j)
                    if elementDepth + 2 <= MarkdownParser.maxElementDepth && layoutFits(2) {
                        pushFrame(.quote(lines: innerLines, index: 0, blockStart: blockStartByte, blocks: [], maps: []))
                    } else {
                        pushFrame(.mergedQuote(lines: innerLines, index: 0, rangeEnd: quoteRangeEnd))
                    }
                    continue
                }

                // 6. List (- / * / + / 1. / 1))
                if let firstMarker = parseListMarker(raw) {
                    let isOrdered = firstMarker.ordered
                    let startNum = firstMarker.start
                    var pendingItems: [PendingListItem] = []
                    var html = ContainerHTMLTail()
                    var j = i

                    while j < lines.count {
                        let lStr = utf8Slice(source, range: lines[j].contentRange) ?? ""
                        if lStr.trimmingCharacters(in: .whitespaces).isEmpty {
                            var peek = j + 1
                            while peek < lines.count && (utf8Slice(source, range: lines[peek].contentRange) ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                                peek += 1
                            }
                            if peek < lines.count {
                                let peekStr = utf8Slice(source, range: lines[peek].contentRange) ?? ""
                                if let pm = parseListMarker(peekStr), pm.ordered == isOrdered, pm.marker == firstMarker.marker, pm.indent <= firstMarker.contentIndent {
                                    j = peek
                                    continue
                                }
                                if indentWidth(peekStr) >= firstMarker.contentIndent {
                                    html.append("")
                                    pendingItems[pendingItems.count - 1].slices.append(lines[j])
                                    j += 1
                                    continue
                                }
                            }
                            break
                        }

                        if let m = parseListMarker(lStr), m.ordered == isOrdered, m.marker == firstMarker.marker, m.indent < firstMarker.contentIndent {
                            var cStart = lines[j].contentRange.lowerBound + m.contentOffsetBytes
                            var taskState: MarkdownTaskState?
                            if let rest = utf8Slice(source, range: cStart..<lines[j].contentRange.upperBound),
                               let task = parseTaskCheckboxPrefix(rest) {
                                taskState = MarkdownTaskState(checked: task.checked, markerOffset: baseOffset + cStart)
                                cStart += task.dropBytes
                            }
                            let slice = LineSlice(contentRange: min(cStart, lines[j].contentRange.upperBound)..<lines[j].contentRange.upperBound, lineEnd: lines[j].lineEnd)
                            html = ContainerHTMLTail()
                            html.append(utf8Slice(source, range: slice.contentRange) ?? "")
                            pendingItems.append(PendingListItem(slices: [slice], task: taskState, rawStart: lines[j].contentRange.lowerBound))
                            j += 1
                        } else if !pendingItems.isEmpty {
                            let ind = indentWidth(lStr)
                            if ind >= firstMarker.contentIndent {
                                let stripped = stripLeadingIndent(lStr, targetCols: firstMarker.contentIndent)
                                let cStart = lines[j].contentRange.lowerBound + stripped
                                let slice = LineSlice(contentRange: min(cStart, lines[j].contentRange.upperBound)..<lines[j].contentRange.upperBound, lineEnd: lines[j].lineEnd)
                                html.append(utf8Slice(source, range: slice.contentRange) ?? "")
                                pendingItems[pendingItems.count - 1].slices.append(slice)
                                j += 1
                            } else if !html.followsHTML && MarkdownHTML.blockStart(in: lStr, interruptsParagraph: true) == nil && parseListMarker(lStr) == nil && !isHorizontalRule(lStr.trimmingCharacters(in: .whitespaces)) && parseATXHeading(source: source, lineRange: lines[j].contentRange) == nil && !isFenceHeaderBool(lStr) && !lStr.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                                pendingItems[pendingItems.count - 1].slices.append(lines[j])
                                j += 1
                            } else {
                                break
                            }
                        } else {
                            break
                        }
                    }

                    let listRangeEnd = (j > i ? lines[j - 1].lineEnd : lines[i].lineEnd)
                    advanceLineCursor(to: j)

                    if (elementDepth + 2 <= MarkdownParser.maxElementDepth && layoutFits(3)) || !topRealIsListOrItem() {
                        pushFrame(.list(
                            blockStart: blockStartByte,
                            start: isOrdered ? startNum : nil,
                            pendingItems: pendingItems,
                            nextItem: 0,
                            items: [],
                            itemMaps: []
                        ))
                    } else {
                        // Flatten deeper list items as siblings in the enclosing list (`ListSlot::SiblingItems`).
                        if case let .item(itemLines, itemNext, itemBlocks, itemMaps) = frames.last {
                            _ = popFrame()
                            appendCompletedItem(blocks: itemBlocks, maps: itemMaps)
                            if itemNext < itemLines.count {
                                pushFrame(.tailLines(lines: itemLines, index: itemNext))
                            }
                        }
                        pushFrame(.siblingList(pendingItems: pendingItems, nextItem: 0, rangeEnd: listRangeEnd))
                    }
                    continue
                }

                // 7. GFM Table (header + delimiter row)
                if i + 1 < lines.count,
                   let nextRaw = utf8Slice(source, range: lines[i + 1].contentRange),
                   let aligns = parseTableDelimiterAlignments(nextRaw),
                   raw.contains("|") {
                    let headCells = splitTableRow(raw, baseOffset: baseOffset + lines[i].contentRange.lowerBound)
                    if headCells.count == aligns.count || (!headCells.isEmpty && raw.trimmingCharacters(in: .whitespaces).hasPrefix("|")) {
                        if triggerDeepTailIfMergedQuoteExceeded(blockStartByte: blockStartByte) { continue }
                        tail = .none
                        var headInlines: [MarkdownInline] = []
                        var headMaps: [MarkdownSpanMap] = []
                        for cell in headCells {
                            tail = .inline(cell.offset, .cell)
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
                                tail = .inline(cell.offset, .cell)
                                let (inl, sm, _) = parseInline(cell.text, baseOffset: cell.offset, autolink: autolink, definitions: definitions, trimTrailingCodePad: true)
                                rInl.append(inl)
                                rMap.append(sm)
                            }
                            bodyRows.append(rInl)
                            rowMaps.append(rMap)
                            j += 1
                        }
                        let table = MarkdownTableAST(align: aligns, head: headInlines, rows: bodyRows, open: lastOpen)
                        appendToNearestRealContainer(.table(table), map: .table(head: headMaps, rows: rowMaps), blockStart: blockStartByte)
                        advanceLineCursor(to: j)
                        continue
                    }
                }

                // 8. Setext Heading (para line followed by === or ---)
                if i + 1 < lines.count {
                    let nextTrim = (utf8Slice(source, range: lines[i + 1].contentRange) ?? "").trimmingCharacters(in: .whitespaces)
                    if !nextTrim.isEmpty && (nextTrim.allSatisfy { $0 == "=" } || nextTrim.allSatisfy { $0 == "-" }) {
                        if triggerDeepTailIfMergedQuoteExceeded(blockStartByte: blockStartByte) { continue }
                        tail = .inline(blockStartByte, .line)
                        let lvl = nextTrim.first == "=" ? 1 : 2
                        let pStr = raw.trimmingCharacters(in: .whitespaces)
                        let leadOff = raw.utf8.count - String(raw.drop(while: \.isWhitespace)).utf8.count
                        let (inl, sm, _) = parseInline(pStr, baseOffset: baseOffset + lines[i].contentRange.lowerBound + leadOff, autolink: autolink, definitions: definitions, trimTrailingCodePad: true)
                        appendToNearestRealContainer(.heading(level: lvl, inl), map: .inline(sm), blockStart: blockStartByte)
                        advanceLineCursor(to: i + 2)
                        continue
                    }
                }

                // 9. Paragraph (joining soft lines, breaking on container starts or interrupt-numbered continuations, lifting standalone images on root)
                if triggerDeepTailIfMergedQuoteExceeded(blockStartByte: blockStartByte) { continue }
                tail = .inline(blockStartByte, .paragraph)
                var paraRanges: [Range<Int>] = [lines[i].contentRange]
                var j = i + 1
                while j < lines.count {
                    let nextRaw = utf8Slice(source, range: lines[j].contentRange) ?? ""
                    let nextTrim = nextRaw.trimmingCharacters(in: .whitespaces)
                    if nextTrim.isEmpty ||
                        MarkdownHTML.blockStart(in: nextRaw, interruptsParagraph: true) != nil ||
                        isFenceHeaderBool(nextRaw) ||
                        isHorizontalRule(nextTrim) ||
                        parseATXHeading(source: source, lineRange: lines[j].contentRange) != nil ||
                        nextTrim.hasPrefix(">") {
                        break
                    }
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
                var pBlocks: [MarkdownDocBlock] = []
                var pMaps: [MarkdownBlockMap] = []
                var pStarts: [Int] = []
                emitParagraphLines(
                    paraRanges,
                    blockStart: blockStartByte,
                    allowImageLift: isRoot,
                    into: &pBlocks,
                    maps: &pMaps,
                    starts: &pStarts
                )
                for idx in pBlocks.indices {
                    appendToNearestRealContainer(pBlocks[idx], map: pMaps[idx], blockStart: pStarts[idx])
                }
                advanceLineCursor(to: j)
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
            var softBreaks: Set<Int> = []
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
                    if !hardBreak { softBreaks.insert(brStart) }
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
                softBreaks: softBreaks,
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
        softBreaks: Set<Int> = [],
        autolink: Bool,
        definitions: [KitSourceKey: LinkDefinition],
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

        func pushMappedRanges(inputLo: Int, inputHi: Int, outLo: Int, outHi: Int) {
            guard outLo < outHi, inputLo < inputHi else { return }
            guard let customSrcMap, !customSrcMap.isEmpty, (outHi - outLo) == (inputHi - inputLo) else {
                map.push(src: mapInputRange(inputLo, inputHi), out: outLo..<outHi)
                return
            }
            var curOut = outLo
            var pushed = false
            for seg in customSrcMap where seg.out.upperBound > inputLo && seg.out.lowerBound < inputHi {
                let overlap0 = max(inputLo, seg.out.lowerBound)
                let overlap1 = min(inputHi, seg.out.upperBound)
                guard overlap0 < overlap1 else { continue }
                pushed = true
                let rel0 = overlap0 - seg.out.lowerBound
                let rel1 = overlap1 - seg.out.lowerBound
                let s0 = seg.src.lowerBound + min(rel0, seg.src.count)
                let s1 = seg.src.lowerBound + min(rel1, seg.src.count)
                let segLen = overlap1 - overlap0
                if s0 < s1 {
                    map.push(src: s0..<s1, out: curOut..<(curOut + segLen))
                }
                curOut += segLen
            }
            if !pushed {
                map.push(src: (baseOffset + inputLo)..<(baseOffset + inputHi), out: outLo..<outHi)
            }
        }

        func appendRaw(_ s: String, srcLo: Int, srcHi: Int) {
            guard !s.isEmpty else { return }
            let out0 = text.utf8.count
            text.append(s)
            let out1 = text.utf8.count
            pushMappedRanges(inputLo: srcLo, inputHi: srcHi, outLo: out0, outHi: out1)
        }

        func parseRange(_ lo: Int, _ hi: Int, linkDepth: Int, emDepth: Int) {
            var i = lo
            while i < hi {
                let b = bytes[i]
                if b == 32, text.isEmpty, softBreaks.contains(i) {
                    i += 1
                    continue
                }

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
                            pushMappedRanges(inputLo: contentLo, inputHi: contentHi, outLo: codeStart, outHi: codeEnd)
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
                    if lStart < lEnd {
                        spans.append(MarkdownStyleSpan(start: lStart, end: lEnd, style: .link))
                        links.append(MarkdownLinkSpan(start: lStart, end: lEnd, url: linkMatch.url))
                    }
                    i = linkMatch.afterClose
                    continue
                }

                if b == 0x3C {
                    let rest = bytes[i..<hi]
                    if let end = MarkdownHTML.autolinkEnd(rest) {
                        let destination = String(decoding: bytes[(i + 1)..<(end - 1)], as: UTF8.self)
                        let start = text.utf8.count
                        appendRaw(destination, srcLo: i + 1, srcHi: end - 1)
                        spans.append(MarkdownStyleSpan(start: start, end: text.utf8.count, style: .link))
                        links.append(MarkdownLinkSpan(start: start, end: text.utf8.count, url: destination))
                        i = end
                        continue
                    }
                    if let end = MarkdownHTML.inlineEnd(rest) {
                        i = end
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
        inline.preparedBidi = MarkdownInlineBidi(inline)
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
        out.preparedBidi = MarkdownInlineBidi(out)
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
        definitions: [KitSourceKey: LinkDefinition]
    ) -> BracketLinkMatch? {
        var i = openBracket + 1
        var depth = 1
        while i < limit {
            if bytes[i] == 0x3C, let end = MarkdownHTML.inlineEnd(bytes[i..<limit]) {
                i = end
                continue
            }
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
                url = unescapeMarkdown(String(bytes: bytes[uStart..<p], encoding: .utf8) ?? "")
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

        guard !definitions.isEmpty else { return nil }
        // Full and collapsed references. A well-formed second label suppresses the
        // shortcut even when its destination is missing.
        let label = String(decoding: bytes[(openBracket + 1)..<closeBracket], as: UTF8.self)
        if closeBracket + 1 < limit && bytes[closeBracket + 1] == 0x5B {
            let start = closeBracket + 2
            var end = start
            while end < limit {
                if bytes[end] == 0x5C && end + 1 < limit && isASCIIPunctuation(bytes[end + 1]) { end += 2; continue }
                if bytes[end] == 0x5B || bytes[end] == 0x5D { break }
                end += 1
            }
            if end < limit && bytes[end] == 0x5D {
                let raw = end == start ? label : String(decoding: bytes[start..<end], as: UTF8.self)
                if let key = MarkdownReference.key(raw) {
                    guard let def = definitions[KitSourceKey(key)] else { return nil }
                    return BracketLinkMatch(closeBracket: closeBracket, url: def.url, title: def.title, afterClose: end + 1)
                }
            }
        }

        if let key = MarkdownReference.key(label), let def = definitions[KitSourceKey(key)] {
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
            if bytes[i] == 0x3C, let end = MarkdownHTML.inlineEnd(bytes[i..<limit]) {
                i = end
                continue
            }
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
            if bytes[i] == 0x3C, let end = MarkdownHTML.inlineEnd(bytes[i..<limit]) {
                i = end
                continue
            }
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
            if bytes[i] == 0x3C, let end = MarkdownHTML.inlineEnd(bytes[i..<limit]) {
                i = end
                continue
            }
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

    private static func unescapeMarkdown(_ raw: String) -> String {
        guard raw.utf8.contains(92) || raw.utf8.contains(38) else { return raw }
        let bytes = Array(raw.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 92, i + 1 < bytes.count, isASCIIPunctuation(bytes[i + 1]) {
                out.append(bytes[i + 1])
                i += 2
            } else if bytes[i] == 38, let (text, next) = decodeHTMLEntity(bytes, at: i, limit: bytes.count) {
                out.append(contentsOf: text.utf8)
                i = next
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
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
        switch b {
        case let .para(inline), let .heading(_, inline):
            if inline.text.isEmpty { return }
        default: break
        }
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
        var marker: Character
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
                return ListMarkerInfo(indent: indent, ordered: false, marker: first, start: 1, contentIndent: indent + 1 + sp, contentOffsetBytes: leadBytes + 1 + sp)
            }
        }
        let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty && digits.count <= 9, let num = UInt64(digits) {
            let afterDigits = trimmed.dropFirst(digits.count)
            if let delim = afterDigits.first, delim == "." || delim == ")" {
                let afterDelim = afterDigits.dropFirst()
                if afterDelim.isEmpty || afterDelim.first == " " || afterDelim.first == "\t" {
                    let sp = afterDelim.first != nil ? 1 : 0
                    return ListMarkerInfo(indent: indent, ordered: true, marker: delim, start: num, contentIndent: indent + digits.count + 1 + sp, contentOffsetBytes: leadBytes + digits.count + 1 + sp)
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
        definitions: [KitSourceKey: LinkDefinition]
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
    let indexed = ranges.enumerated()
        .map { (offset: $0.offset, range: $0.element.range, isCurrent: $0.element.isCurrent) }
        .sorted { ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound) }

    var out: [TextSpan] = []
    out.reserveCapacity(spans.count)
    var cursor = 0
    var rCursor = 0
    for span in spans {
        let len = span.text.utf8.count
        let sStart = cursor
        let sEnd = cursor + len
        cursor = sEnd
        guard len > 0 else { continue }

        while rCursor < indexed.count && indexed[rCursor].range.upperBound <= sStart {
            rCursor += 1
        }
        if rCursor >= indexed.count || indexed[rCursor].range.lowerBound >= sEnd {
            out.append(span)
            continue
        }

        var localCuts: [Int] = [0, len]
        var overlappingEnd = rCursor
        while overlappingEnd < indexed.count && indexed[overlappingEnd].range.lowerBound < sEnd {
            let r = indexed[overlappingEnd].range
            if r.upperBound > sStart {
                localCuts.append(max(0, min(len, r.lowerBound - sStart)))
                localCuts.append(max(0, min(len, r.upperBound - sStart)))
            }
            overlappingEnd += 1
        }
        localCuts.sort()

        let spanBytes = Array(span.text.utf8)
        var hitPos = rCursor
        var prevCut = -1
        for idx in 0..<(localCuts.count - 1) {
            let a = localCuts[idx]
            let b = localCuts[idx + 1]
            if a == b || a == prevCut { continue }
            prevCut = a
            let absStart = sStart + a
            let absEnd = sStart + b
            var piece = span
            piece.text = String(decoding: spanBytes[a..<b], as: UTF8.self)
            while hitPos < overlappingEnd && indexed[hitPos].range.upperBound <= absStart {
                hitPos += 1
            }
            var scan = hitPos
            while scan < overlappingEnd && indexed[scan].range.lowerBound <= absStart {
                if indexed[scan].range.upperBound >= absEnd {
                    let hit = indexed[scan]
                    let isCur = hit.isCurrent || (activeIndex == hit.offset)
                    piece.background = isCur ? activeBg : bg
                    if let c = isCur ? activeFg : fg { piece.color = c }
                    break
                }
                scan += 1
            }
            out.append(piece)
        }
    }
    return out
}

// MARK: - MarkdownStyle & Sub-Styles (`rune_kit::markdown::style`)

public struct MarkdownTaskPaint: Sendable, Equatable, Hashable {
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

public struct MarkdownTableBody: Sendable, Equatable, Hashable {
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
public struct MarkdownStyle: Sendable, Equatable, Hashable {
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
        lhs.linkUnderline == rhs.linkUnderline && lhs.codeBg == rhs.codeBg &&
        lhs.codeBlockFill == rhs.codeBlockFill && lhs.codeBlockBorder == rhs.codeBlockBorder &&
        lhs.quoteRule == rhs.quoteRule && lhs.quote == rhs.quote && lhs.rule == rhs.rule &&
        lhs.body == rhs.body && lhs.headings == rhs.headings && lhs.codeBlock == rhs.codeBlock &&
        lhs.codeText == rhs.codeText && lhs.plainCodeText == rhs.plainCodeText &&
        lhs.shell == rhs.shell && lhs.linkHover == rhs.linkHover &&
        lhs.listOutside == rhs.listOutside && lhs.listNested == rhs.listNested &&
        lhs.tableAlign == rhs.tableAlign && lhs.inlineCodeScale == rhs.inlineCodeScale &&
        lhs.inlineCodeWeight == rhs.inlineCodeWeight && lhs.inlineCodePad == rhs.inlineCodePad &&
        lhs.codeBlockPad == rhs.codeBlockPad && lhs.listIndent == rhs.listIndent &&
        lhs.listGap == rhs.listGap && lhs.strongWeight == rhs.strongWeight &&
        lhs.tableOutline == rhs.tableOutline && lhs.tableRule == rhs.tableRule &&
        lhs.tableHeadFill == rhs.tableHeadFill && lhs.tableHeadText == rhs.tableHeadText &&
        lhs.tableHeadRule == rhs.tableHeadRule && lhs.tableHeadWeight == rhs.tableHeadWeight &&
        lhs.tableMinColumn == rhs.tableMinColumn && lhs.tableTabular == rhs.tableTabular &&
        lhs.tableFont == rhs.tableFont && lhs.tablePad == rhs.tablePad &&
        lhs.tableFlushLeft == rhs.tableFlushLeft && lhs.tableFrame == rhs.tableFrame &&
        lhs.tableBody == rhs.tableBody && lhs.tableHeadPad == rhs.tableHeadPad &&
        lhs.tableFullWidth == rhs.tableFullWidth && lhs.tableMargin == rhs.tableMargin &&
        lhs.codeMargin == rhs.codeMargin && lhs.tableBar == rhs.tableBar &&
        lhs.textWidth == rhs.textWidth && lhs.wideFade == rhs.wideFade &&
        lhs.linkIcon == rhs.linkIcon && lhs.diffAdd == rhs.diffAdd &&
        lhs.diffRemove == rhs.diffRemove && lhs.diffAddText == rhs.diffAddText &&
        lhs.diffRemoveText == rhs.diffRemoveText && lhs.diffHues == rhs.diffHues &&
        lhs.diffHunk == rhs.diffHunk && lhs.syntax == rhs.syntax &&
        lhs.highlight == rhs.highlight && lhs.selection == rhs.selection &&
        lhs.highlightBg == rhs.highlightBg && lhs.highlightFg == rhs.highlightFg &&
        lhs.highlightRing?.0 == rhs.highlightRing?.0 && lhs.highlightRing?.1 == rhs.highlightRing?.1 &&
        lhs.highlightCurrentBg == rhs.highlightCurrentBg && lhs.highlightCurrentFg == rhs.highlightCurrentFg &&
        lhs.highlightCurrentRing?.0 == rhs.highlightCurrentRing?.0 && lhs.highlightCurrentRing?.1 == rhs.highlightCurrentRing?.1 &&
        lhs.task == rhs.task && lhs.diagram == rhs.diagram
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(muted)
        hasher.combine(accent)
        hasher.combine(linkUnderline)
        hasher.combine(codeBg)
        hasher.combine(codeBlockFill)
        hasher.combine(codeBlockBorder)
        hasher.combine(quoteRule)
        hasher.combine(quote)
        hasher.combine(rule)
        hasher.combine(body)
        hasher.combine(headings)
        hasher.combine(codeBlock)
        hasher.combine(codeText)
        hasher.combine(plainCodeText)
        hasher.combine(shell)
        hasher.combine(linkHover)
        hasher.combine(listOutside)
        hasher.combine(listNested)
        hasher.combine(tableAlign)
        hasher.combine(inlineCodeScale)
        hasher.combine(inlineCodeWeight)
        hasher.combine(inlineCodePad)
        hasher.combine(codeBlockPad)
        hasher.combine(listIndent)
        hasher.combine(listGap)
        hasher.combine(strongWeight)
        hasher.combine(tableOutline)
        hasher.combine(tableRule)
        hasher.combine(tableHeadFill)
        hasher.combine(tableHeadText)
        hasher.combine(tableHeadRule)
        hasher.combine(tableHeadWeight)
        hasher.combine(tableMinColumn)
        hasher.combine(tableTabular)
        hasher.combine(tableFont)
        hasher.combine(tablePad)
        hasher.combine(tableFlushLeft)
        hasher.combine(tableFrame)
        hasher.combine(tableBody)
        hasher.combine(tableHeadPad)
        hasher.combine(tableFullWidth)
        hasher.combine(tableMargin)
        hasher.combine(codeMargin)
        hasher.combine(tableBar)
        hasher.combine(textWidth)
        hasher.combine(wideFade)
        hasher.combine(linkIcon)
        hasher.combine(diffAdd)
        hasher.combine(diffRemove)
        hasher.combine(diffAddText)
        hasher.combine(diffRemoveText)
        hasher.combine(diffHues)
        hasher.combine(diffHunk)
        hasher.combine(syntax)
        hasher.combine(highlight)
        hasher.combine(selection)
        hasher.combine(highlightBg)
        hasher.combine(highlightFg)
        hasher.combine(highlightRing?.0)
        hasher.combine(highlightRing?.1)
        hasher.combine(highlightCurrentBg)
        hasher.combine(highlightCurrentFg)
        hasher.combine(highlightCurrentRing?.0)
        hasher.combine(highlightCurrentRing?.1)
        hasher.combine(task)
        hasher.combine(diagram)
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
    /// Sets sequence diagram note fill and border colors (`MarkdownStyle::diagram_note`).
    public func diagramNote(_ fill: Color, _ border: Color) -> MarkdownStyle {
        var s = self
        s.diagram.noteFill = fill
        s.diagram.noteBorder = border
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
    /// Shows an inline globe (or GitHub / favicon) icon before external `http`/`https` links (`size` pt square, `gap` pt before text).
    public func linkIcons(_ size: Float, _ gap: Float) -> MarkdownStyle {
        var s = self
        s.linkIcon = .leading(gap: max(0, gap), size: max(0, size))
        return s
    }

    // Table styles
    public func tableOutline(_ color: Color?) -> MarkdownStyle { var s = self; s.tableOutline = color; s.tableFrame = nil; return s }
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
    public func tableLike(_ t: TableStyle) -> MarkdownStyle {
        var s = self
        s.tableFont = t.font
        s.tablePad = [t.cellPad, max(0, (t.rowHeight - (t.font.lineHeight ?? 20)) / 2)]
        s.tableRule = t.rule
        s.tableHeadText = t.headerText
        if s.tableOutline != nil { s.tableOutline = t.rule }
        s.tableFrame = nil
        s.tableBody = nil
        s.tableHeadPad = nil
        return s
    }
    public func tableFrame(fill: Color, ring: Color, pad: Float) -> MarkdownStyle {
        var s = self
        s.tableOutline = nil
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
        t.font = diagram.font
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

/// Built-in icons placed before external links when `MarkdownStyle.linkIcons` is set (`link_icon.rs`).
public enum MarkdownLinkIcons {
    public static let globe = SVGIcon(
        viewBox: 16.0,
        body: #"<circle cx="8" cy="8" r="6" stroke="currentColor"/><ellipse cx="8" cy="8" rx="2.5" ry="6" stroke="currentColor"/><path d="M2 8h12" stroke="currentColor"/>"#
    )
    public static let github = SVGIcon(
        viewBox: 16.0,
        body: #"<path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.23.49-2.69-.94-2.69-.94-.36-.92-.89-1.17-.89-1.17-.73-.5.06-.49.06-.49.8.06 1.22.82 1.22.82.71 1.21 1.87.86 2.33.66.07-.51.28-.86.51-1.06-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.19 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z" fill="currentColor"/>"#
    )

    static func linkHost(_ url: String) -> String? {
        let rest: Substring
        if url.hasPrefix("https://") {
            rest = url.dropFirst(8)
        } else if url.hasPrefix("http://") {
            rest = url.dropFirst(7)
        } else if let idx = url.range(of: "://") {
            let scheme = url[..<idx.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            rest = url[idx.upperBound...]
        } else {
            return nil
        }
        let authority = rest.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first ?? rest
        let hostPart: Substring
        if let atIdx = authority.lastIndex(of: "@") {
            hostPart = authority[authority.index(after: atIdx)...]
        } else {
            hostPart = authority
        }
        let host: Substring
        if hostPart.hasPrefix("[") {
            if let close = hostPart.firstIndex(of: "]") {
                host = hostPart[...close]
            } else {
                host = hostPart
            }
        } else if let colon = hostPart.firstIndex(of: ":") {
            host = hostPart[..<colon]
        } else {
            host = hostPart
        }
        return host.isEmpty ? nil : host.lowercased()
    }
}

/// Rich per-link paint configuration for `Markdown.linkStyle` (`rune::LinkPaint`).
public struct MarkdownLinkStyle: Sendable, Equatable {
    public var color: Color?
    public var underline: Bool
    public var weight: Float?
    public var bg: Color?
    public var hoverColor: Color?
    public var hoverBg: Color?

    public init(
        color: Color? = nil,
        underline: Bool = true,
        weight: Float? = nil,
        bg: Color? = nil,
        hoverColor: Color? = nil,
        hoverBg: Color? = nil
    ) {
        self.color = color
        self.underline = underline
        self.weight = weight
        self.bg = bg
        self.hoverColor = hoverColor
        self.hoverBg = hoverBg
    }
}

/// Fluent, full-parity CommonMark + GFM Markdown component (`rune_kit::markdown::Markdown`).
public struct Markdown: Sendable {
    final class UncachedRenderCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        func take() -> Int { lock.lock(); defer { value = 0; lock.unlock() }; return value }
    }

    @TaskLocal static var activeRenderCounter: UncachedRenderCounter?

    static func withRenderCounter<T>(_ body: (UncachedRenderCounter) -> T) -> T {
        let box = UncachedRenderCounter()
        return $activeRenderCounter.withValue(box) { body(box) }
    }

    static func recordUncachedRender() {
        activeRenderCounter?.increment()
    }

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
    public var linkPaintFn: (@Sendable (String) -> MarkdownLinkStyle?)?
    public var linkRingFn: (@Sendable (String) -> (Color, Float)?)?
    public var linkHelpFn: (@Sendable (String) -> String?)?
    public var linkFaviconFn: (@Sendable (String) -> RGBA8Atlas?)?
    public var codeLinkMatchFn: (@Sendable (String) -> (url: String, color: Color)?)?
    public var imageAltVisible: Bool = false

    public init(_ source: String) {
        self.source = source
    }

    public func style(_ style: MarkdownStyle) -> Markdown { var c = self; c.customStyle = style; return c }
    public func reveal(_ seconds: Float) -> Markdown { var c = self; c.revealDelay = max(0, seconds); return c }
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
    public func highlight(
        file: StaticString = #fileID, line: UInt = #line, column: UInt = #column,
        _ fn: @escaping @Sendable (String?, String) -> [SyntaxHighlight]
    ) -> Markdown {
        highlighter(SyntaxHighlighter(file: file, line: line, column: column, fn))
    }
    public func highlighter(_ hl: SyntaxHighlighter) -> Markdown { var c = self; c.syntaxHighlighter = hl; return c }
    public func codeLink(match: @escaping @Sendable (String) -> String?, color: Color) -> Markdown {
        var c = self
        c.codeLinkMatchFn = { code in match(code).map { ($0, color) } }
        return c
    }
    public func linkStyle(_ fn: @escaping @Sendable (String) -> (color: Color?, underline: Bool, weight: Float?, hoverColor: Color?)?) -> Markdown {
        var c = self; c.linkLookFn = fn; c.linkPaintFn = nil; return c
    }
    public func linkStyle(_ fn: @escaping @Sendable (String) -> MarkdownLinkStyle?) -> Markdown {
        var c = self; c.linkPaintFn = fn; c.linkLookFn = nil; return c
    }
    public func linkRing(_ fn: @escaping @Sendable (String) -> (Color, Float)?) -> Markdown {
        var c = self; c.linkRingFn = fn; return c
    }
    public func linkHelp(_ fn: @escaping @Sendable (String) -> String?) -> Markdown {
        var c = self; c.linkHelpFn = fn; return c
    }
    public func linkFavicon(_ fn: @escaping @Sendable (String) -> RGBA8Atlas?) -> Markdown {
        var c = self; c.linkFaviconFn = fn; return c
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
    public func onLinkSecondary<State>(_ fn: @escaping @Sendable (inout State, String, PointerPress, inout Tx) -> Void) -> MarkdownView<State> {
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
        isStreaming
            ? MarkdownDocCache.sharedStream.streamCached(source, autolink: isAutolinkEnabled)
            : MarkdownDocCache.shared.docCached(source, autolink: isAutolinkEnabled)
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

    /// Resolves the raw Markdown source copied for `selection` when `Markdown.copySource(true)`
    /// is active (`crates/rune-kit/src/markdown/render.rs:source_copy`).
    public static func sourceCopy(
        source: String,
        blockStarts: [Int],
        blockKeys: [String],
        selection: TextSelection
    ) -> String? {
        var byKey: [String: Int] = [:]
        for (index, key) in blockKeys.enumerated() where !key.isEmpty && byKey[key] == nil {
            byKey[key] = index
        }
        func blockIndex(for path: String) -> Int? {
            // Caller keys may include slashes. Prefer the earliest matching path
            // component and then the longest key, including Rune's keyed "@" paths.
            var start = path.startIndex
            while start < path.endIndex {
                var end = path.endIndex
                while start < end {
                    let candidate = path[start..<end]
                    if let index = byKey[String(candidate)] { return index }
                    if candidate.first == "@", let index = byKey[String(candidate.dropFirst())] { return index }
                    guard let slash = candidate.lastIndex(of: "/") else { break }
                    end = slash
                }
                guard let next = path[start...].firstIndex(of: "/") else { break }
                start = path.index(after: next)
            }
            return nil
        }

        var touched: (first: Int, last: Int)? = nil
        for t in selection.texts where !t.range.isEmpty {
            guard let b = blockIndex(for: t.path) else { continue }
            if let cur = touched {
                touched = (min(cur.first, b), max(cur.last, b))
            } else {
                touched = (b, b)
            }
        }
        guard let (first, last) = touched else { return nil }
        if first == last {
            let blockTexts = selection.texts.filter { blockIndex(for: $0.path) == first }
            if !blockTexts.allSatisfy({ $0.whole || $0.len == 0 }) {
                return nil
            }
        }
        if (first == 0 && last + 1 >= blockStarts.count)
            || selection.texts.allSatisfy({ $0.whole || $0.len == 0 }) {
            return source
        }
        guard first < blockStarts.count else { return nil }
        let startByte = blockStarts[first]
        let endByte = (last + 1 < blockStarts.count) ? blockStarts[last + 1] : source.utf8.count
        guard let slice = utf8Slice(source, range: startByte..<endByte) else { return nil }
        var scalars = slice.unicodeScalars
        while let lastScalar = scalars.last, lastScalar.properties.isWhitespace {
            scalars.removeLast()
        }
        return String(scalars)
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
    public var onLinkSecondaryHandler: (@Sendable (inout State, String, PointerPress, inout Tx) -> Void)?
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
    public func reveal(_ seconds: Float) -> Self { var c = self; c.config.revealDelay = max(0, seconds); return c }
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
    public func highlight(
        file: StaticString = #fileID, line: UInt = #line, column: UInt = #column,
        _ fn: @escaping @Sendable (String?, String) -> [SyntaxHighlight]
    ) -> Self {
        highlighter(SyntaxHighlighter(file: file, line: line, column: column, fn))
    }
    public func highlighter(_ hl: SyntaxHighlighter) -> Self { var c = self; c.config.syntaxHighlighter = hl; return c }
    public func codeLink(match: @escaping @Sendable (String) -> String?, color: Color) -> Self {
        var c = self; c.config = c.config.codeLink(match: match, color: color); return c
    }
    public func linkStyle(_ fn: @escaping @Sendable (String) -> (color: Color?, underline: Bool, weight: Float?, hoverColor: Color?)?) -> Self {
        var c = self; c.config.linkLookFn = fn; c.config.linkPaintFn = nil; return c
    }
    public func linkStyle(_ fn: @escaping @Sendable (String) -> MarkdownLinkStyle?) -> Self {
        var c = self; c.config.linkPaintFn = fn; c.config.linkLookFn = nil; return c
    }
    public func linkRing(_ fn: @escaping @Sendable (String) -> (Color, Float)?) -> Self {
        var c = self; c.config.linkRingFn = fn; return c
    }
    public func linkHelp(_ fn: @escaping @Sendable (String) -> String?) -> Self {
        var c = self; c.config.linkHelpFn = fn; return c
    }
    public func linkFavicon(_ fn: @escaping @Sendable (String) -> RGBA8Atlas?) -> Self {
        var c = self; c.config.linkFaviconFn = fn; return c
    }
    public func onLink(_ fn: @escaping @Sendable (inout State, String, inout Tx) -> Void) -> Self {
        var c = self; c.onLinkHandler = fn; return c
    }
    public func onLinkSecondary(_ fn: @escaping @Sendable (inout State, String, inout Tx) -> Void) -> Self {
        var c = self
        c.onLinkSecondaryHandler = { state, url, _, tx in fn(&state, url, &tx) }
        return c
    }
    public func onLinkSecondary(_ fn: @escaping @Sendable (inout State, String, PointerPress, inout Tx) -> Void) -> Self {
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
        guard let digest = cacheDigest(style) else { return renderUncached(style) }
        return Rune.cached(digest) { self.renderUncached(style) }
    }

    // Release the cache-key temporaries before recursively building the block tree.
    private func cacheDigest(_ style: MarkdownStyle) -> UInt64? {
        let canCache = !config.isStreaming
            && onLinkHandler == nil
            && onLinkSecondaryHandler == nil
            && config.linkLookFn == nil
            && config.linkPaintFn == nil
            && config.linkHelpFn == nil
            && config.linkRingFn == nil
            && config.codeLinkMatchFn == nil
            && onTaskHandler == nil
            && !(config.isSelectable && config.copySourceMode)
            && config.syntaxHighlighter.id == SyntaxHighlighter.builtin.id
            && diagramFrameHandler == nil
            && codeFrameHandler == nil
            && quoteFrameHandler == nil
            && imageFrameHandler == nil
            && config.linkFaviconFn == nil
            && !config.source.contains("mermaid")
        guard canCache else { return nil }

        var h = Hasher()
        h.combine(KitSourceKey(config.source))
        h.combine(style)
        for item in config.callerBlockKeys {
            h.combine(item.offset)
            h.combine(item.key)
        }
        for item in config.highlightsList {
            h.combine(item.ranges)
            h.combine(item.style)
        }
        h.combine(config.isAutolinkEnabled)
        h.combine(config.revealDelay.bitPattern)
        h.combine(config.areTasksReadOnly)
        h.combine(config.isSelectable)
        h.combine(config.isScrollWide)
        h.combine(config.tentativeDirection)
        h.combine(config.imageAltVisible)
        return UInt64(bitPattern: Int64(h.finalize()))
    }

    private func renderUncached(_ style: MarkdownStyle) -> El<State> {
        Markdown.recordUncachedRender()
        let doc: MarkdownParsedDoc
        let meta: [MarkdownPreBlock]
        if config.isAutolinkEnabled {
            (doc, meta) = config.isStreaming
                ? MarkdownDocCache.sharedStream.streamCachedWithMeta(config.source, autolink: true)
                : MarkdownDocCache.shared.docCachedWithMeta(config.source, autolink: true)
        } else {
            doc = config.isStreaming
                ? MarkdownTailStream.parseStreaming(config.source, autolink: false)
                : MarkdownParser.parseDocument(config.source, autolink: false)
            meta = MarkdownMemoMeta.precomputeBlocks(doc.blocks, maps: doc.maps)
        }
        let keys = matchBlockKeys(starts: doc.blockStarts, callerKeys: config.callerBlockKeys)
        let renderer = MarkdownRenderer<State>(view: self, style: style, doc: doc, meta: meta)
        return renderer.renderRoot(keys: keys)
    }

    private func matchBlockKeys(starts: [Int], callerKeys: [(offset: Int, key: String)]) -> [String] {
        guard !callerKeys.isEmpty else { return [] }
        var byOffset: [Int: String] = [:]
        for (offset, key) in callerKeys where byOffset[offset] == nil { byOffset[offset] = key }
        return starts.map { byOffset[$0] ?? "" }
    }
}

// MARK: - Internal Renderer (`rune_kit::markdown::render` + `table`)

private final class MarkdownRenderer<State> {
    let view: MarkdownView<State>
    let s: MarkdownStyle
    let doc: MarkdownParsedDoc
    let meta: [MarkdownPreBlock]
    let baseDigest: MarkdownDigest128
    var nextSource = 0
    var nextTask = 0
    var currentBlockKey = "b0"
    var flow = FlowState()
    private var localMemoSlots: [MarkdownDigest128: Int] = [:]

    enum Lead {
        case bullet
        case number(UInt64)
        case task(Bool)

        var marker: String {
            switch self {
            case .bullet: return "- "
            case let .number(n): return "\(n). "
            case let .task(done): return done ? "- [x] " : "- [ ] "
            }
        }

        var width: Int {
            switch self {
            case let .number(n): return String(n).count + 2
            case .bullet, .task: return 2
            }
        }
    }

    struct FlowState {
        var lists = 0
        var inset: Float = 0
        var ink: Color? = nil
        var cols: Int = 0
        var lead: (cols: Int, lead: Lead, before: UInt8)? = nil
    }

    private final class BlocksFrame {
        let blocks: [MarkdownDocBlock]
        let pre: [MarkdownPreBlock]?
        let maps: [MarkdownBlockMap]
        let names: [String]
        let topLevel: Bool
        let inItem: Bool
        let openTail: Bool
        let allowMemo: Bool
        var idx: Int = 0
        var prevMb: Float = 0
        var afterHeading: Bool = false
        var lastDir: MarkdownDirection?
        var curCol: El<State>
        var pending: (key: String, top: Float, prose: Bool, own: MarkdownDirection?)? = nil

        init(
            blocks: [MarkdownDocBlock],
            pre: [MarkdownPreBlock]?,
            maps: [MarkdownBlockMap],
            names: [String],
            topLevel: Bool,
            inItem: Bool,
            openTail: Bool,
            allowMemo: Bool,
            lastDir: MarkdownDirection?,
            curCol: El<State>
        ) {
            self.blocks = blocks
            self.pre = pre
            self.maps = maps
            self.names = names
            self.topLevel = topLevel
            self.inItem = inItem
            self.openTail = openTail
            self.allowMemo = allowMemo
            self.lastDir = lastDir
            self.curCol = curCol
        }
    }

    private final class QuoteFrame {
        let quotePre: MarkdownPreBlock?
        let inner: [MarkdownDocBlock]
        let innerPre: [MarkdownPreBlock]?
        let innerMaps: [MarkdownBlockMap]
        let savedFlow: FlowState
        let firstTask: Int
        let quoteDir: MarkdownDirection?

        init(
            quotePre: MarkdownPreBlock?,
            inner: [MarkdownDocBlock],
            innerPre: [MarkdownPreBlock]?,
            innerMaps: [MarkdownBlockMap],
            savedFlow: FlowState,
            firstTask: Int,
            quoteDir: MarkdownDirection?
        ) {
            self.quotePre = quotePre
            self.inner = inner
            self.innerPre = innerPre
            self.innerMaps = innerMaps
            self.savedFlow = savedFlow
            self.firstTask = firstTask
            self.quoteDir = quoteDir
        }
    }

    private final class ListFrame {
        let start: UInt64?
        let items: [[MarkdownDocBlock]]
        let preItems: [MarkdownPreItem]?
        let itemMaps: [[MarkdownBlockMap]]
        let savedFlow: FlowState
        let indent: Float
        let space: Float
        let openTail: Bool
        let allowMemo: Bool
        let listDir: MarkdownDirection?
        let realN: Int
        var idx: Int = 0
        var listCol: El<State>
        var pendingItem: (k: Int, gapMt: Float, task: MarkdownTaskState?, isDeepTail: Bool)? = nil

        init(
            start: UInt64?,
            items: [[MarkdownDocBlock]],
            preItems: [MarkdownPreItem]?,
            itemMaps: [[MarkdownBlockMap]],
            savedFlow: FlowState,
            indent: Float,
            space: Float,
            openTail: Bool,
            allowMemo: Bool,
            listDir: MarkdownDirection?,
            listCol: El<State>
        ) {
            self.start = start
            self.items = items
            self.preItems = preItems
            self.itemMaps = itemMaps
            self.savedFlow = savedFlow
            self.indent = indent
            self.space = space
            self.openTail = openTail
            self.allowMemo = allowMemo
            self.listDir = listDir
            let hasTrailingDeepTail: Bool = {
                guard !items.isEmpty, let lastMap = itemMaps.last, lastMap.count == 1, case .deepTail = lastMap[0] else { return false }
                return true
            }()
            self.realN = items.count - (hasTrailingDeepTail ? 1 : 0)
            self.listCol = listCol
        }
    }

    private enum RenderFrame {
        case blocks(BlocksFrame)
        case quote(QuoteFrame)
        case list(ListFrame)
    }

    init(view: MarkdownView<State>, style: MarkdownStyle, doc: MarkdownParsedDoc, meta: [MarkdownPreBlock]) {
        self.view = view
        self.s = style
        self.doc = doc
        self.meta = meta
        self.baseDigest = Self.computeBaseDigest(view: view, style: style)
    }

    private static func computeBaseDigest(view: MarkdownView<State>, style: MarkdownStyle) -> MarkdownDigest128 {
        var h = MarkdownPairHasher()
        h.writeStyle(style)
        h.writeInt(view.config.highlightsList.count)
        for item in view.config.highlightsList {
            h.writeInt(item.ranges.count)
            for r in item.ranges {
                h.writeInt(r.lowerBound)
                h.writeInt(r.upperBound)
            }
            h.writeHighlight(item.style)
        }
        h.writeFloat(view.config.revealDelay)
        h.writeBool(view.config.isStreaming)
        h.writeBool(view.config.areTasksReadOnly)
        h.writeBool(view.config.isSelectable)
        h.writeBool(view.config.isScrollWide)
        h.writeBool(view.config.imageAltVisible)
        h.writeBool(view.onLinkHandler != nil)
        h.writeBool(view.onLinkSecondaryHandler != nil)
        return h.finish128()
    }

    private func cachedSubtree(_ digest: MarkdownDigest128, build: () -> El<State>) -> El<State> {
        let slot = localMemoSlots[digest, default: 0]
        localMemoSlots[digest] = slot + 1
        let rawId = "cached:md:\(String(digest.lo, radix: 16))-\(String(digest.hi, radix: 16)):\(slot)"
        return Rune.memo(rawId, deps: digest, build: build)
    }

    private func blockDir(_ b: MarkdownDocBlock, pre: MarkdownPreBlock?) -> MarkdownDirection? {
        if let pre { return pre.dir }
        return MarkdownBidi.blockDirection(b)
    }

    func renderRoot(keys: [String]) -> El<State> {
        let rootDir = meta.first(where: { $0.dir != nil })?.dir
            ?? (meta.isEmpty ? MarkdownBidi.blocksDirection(doc.blocks) : nil)
            ?? view.config.tentativeDirection
        var quotePlainCache: MarkdownPlain.QuotePlainCache = [:]
        let rootFrame = BlocksFrame(
            blocks: doc.blocks,
            pre: meta,
            maps: doc.maps,
            names: renderedKeys(count: doc.blocks.count, keys: keys),
            topLevel: true,
            inItem: false,
            openTail: view.config.isStreaming,
            allowMemo: true,
            lastDir: view.config.tentativeDirection,
            curCol: col().wFull()
        )
        let drawn = runFrames(initial: [.blocks(rootFrame)], quotePlainCache: &quotePlainCache)
        let root = drawn
            .markdownDirection(rootDir)
            .selectionGroup(view.config.isSelectable)
        guard view.config.isSelectable && view.config.copySourceMode else {
            return root
        }
        let names = renderedKeys(count: doc.blocks.count, keys: keys)
        let src = view.config.source
        let starts = doc.blockStarts
        return root.selectionCopy { selection in
            Markdown.sourceCopy(source: src, blockStarts: starts, blockKeys: names, selection: selection)
        }
    }

    private func applySelect(_ node: El<State>) -> El<State> {
        view.config.isSelectable
            ? node.selectable(true).selectionStyle(SelectionStyle(highlight: s.selection)).cursor(.text)
            : node
    }

    private func renderedKeys(count: Int, keys: [String]) -> [String] {
        guard !keys.isEmpty else { return (0..<count).map { "b\($0)" } }
        let reserved = Set(keys)
        var used: Set<String> = []
        var nextFree = 0
        return (0..<count).map { index in
            if index < keys.count, !keys[index].isEmpty, used.insert(keys[index]).inserted {
                return keys[index]
            }
            var key = "b\(index)"
            while used.contains(key) || reserved.contains(key) {
                key = "b\(nextFree)"
                nextFree += 1
            }
            used.insert(key)
            return key
        }
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

    private func ownMargins(_ b: MarkdownDocBlock, index i: Int, inItem: Bool) -> (top: Float, bottom: Float) {
        switch b {
        case .para where inItem:
            return (i == 0 ? 0 : 8, i == 0 ? 0 : 12)
        case .list where inItem:
            return (4, 4)
        default:
            return margins(b)
        }
    }

    private func collapsedTop(_ startBlock: MarkdownDocBlock, index startIndex: Int, inItem startInItem: Bool) -> Float {
        var b = startBlock
        var i = startIndex
        var inItem = startInItem
        var top: Float = 0
        while true {
            top = max(top, ownMargins(b, index: i, inItem: inItem).top)
            switch b {
            case let .quote(inner):
                guard let first = inner.first else { return top }
                b = first; i = 0; inItem = false
            case let .list(_, items):
                guard let first = items.first?.first else { return top }
                b = first; i = 0; inItem = true
            default:
                return top
            }
        }
    }

    private func collapsedBottom(_ startBlock: MarkdownDocBlock, index startIndex: Int, inItem startInItem: Bool) -> Float {
        var b = startBlock
        var i = startIndex
        var inItem = startInItem
        var bot: Float = 0
        while true {
            bot = max(bot, ownMargins(b, index: i, inItem: inItem).bottom)
            switch b {
            case let .quote(inner):
                guard let last = inner.last else { return bot }
                b = last; i = inner.count - 1; inItem = false
            case let .list(_, items):
                guard let item = items.last else { return bot }
                bot = max(bot, s.listGap)
                guard let last = item.last else { return bot }
                b = last; i = item.count - 1; inItem = true
            default:
                return bot
            }
        }
    }

    private func collapsed(_ b: MarkdownDocBlock, index i: Int, inItem: Bool) -> (top: Float, bottom: Float) {
        (collapsedTop(b, index: i, inItem: inItem), collapsedBottom(b, index: i, inItem: inItem))
    }

    private func listItemGap(items: [[MarkdownDocBlock]], k: Int) -> Float {
        guard k > 0 else { return 0 }
        let prevEdge: Float = items[k - 1].last.map { collapsedBottom($0, index: items[k - 1].count - 1, inItem: true) } ?? 0
        let curEdge: Float = items[k].first.map { collapsedTop($0, index: 0, inItem: true) } ?? 0
        return max(s.listGap, max(prevEdge, curEdge))
    }

    // MARK: Settled Block / Item / Code-Card / Table-Row Memo Digests (`memo.rs`, #1130)

    private func hashFlow(_ f: FlowState, into h: inout MarkdownPairHasher) {
        h.writeInt(f.lists)
        h.writeOptionalColor(f.ink)
        h.writeFloat(f.inset)
        h.writeInt(f.cols)
        if let lead = f.lead {
            h.writeByte(1)
            h.writeInt(lead.cols)
            h.writeByte(lead.before)
            switch lead.lead {
            case .bullet: h.writeByte(0)
            case .number(let n):
                h.writeByte(1)
                h.writeUInt64(n)
            case .task(let done):
                h.writeByte(2)
                h.writeBool(done)
            }
        } else {
            h.writeByte(0)
        }
    }

    private func canMemoLinks(hasLinks: Bool) -> Bool {
        !hasLinks || (view.onLinkHandler == nil && view.onLinkSecondaryHandler == nil)
    }

    private func canMemoFlags(_ flags: UInt8) -> Bool {
        if (flags & MarkdownPreFlags.hasCode) != 0 && (!view.config.syntaxHighlighter.isBuiltin || view.codeFrameHandler != nil) {
            return false
        }
        if (flags & MarkdownPreFlags.hasMermaid) != 0 && (view.diagramFrameHandler != nil || !view.config.syntaxHighlighter.isBuiltin) {
            return false
        }
        if (flags & MarkdownPreFlags.hasImage) != 0 && view.imageFrameHandler != nil {
            return false
        }
        if (flags & MarkdownPreFlags.hasQuote) != 0 && view.quoteFrameHandler != nil {
            return false
        }
        if (flags & MarkdownPreFlags.hasOpenTable) != 0 && view.config.isStreaming {
            return false
        }
        return true
    }

    private func hashLinkURL(_ url: String, into h: inout MarkdownPairHasher) {
        if view.config.linkPaintFn != nil || view.config.linkLookFn != nil {
            h.writeLinkStyle(resolvedLinkStyle(url))
        }
        if let ringFn = view.config.linkRingFn {
            if let ring = ringFn(url) {
                h.writeByte(1)
                h.writeColor(ring.0)
                h.writeFloat(ring.1)
            } else {
                h.writeByte(0)
            }
        }
        if let helpFn = view.config.linkHelpFn {
            h.writeOptionalString(helpFn(url))
        }
        if s.linkIcon != nil,
           let host = MarkdownLinkIcons.linkHost(url),
           host != "github.com",
           let favFn = view.config.linkFaviconFn {
            h.writeRGBA8Atlas(favFn(url))
        }
    }

    private func hashInlineDirect(_ inl: MarkdownInline, into h: inout MarkdownPairHasher) -> Bool {
        let resolved = withCodeLinks(inl)
        guard canMemoLinks(hasLinks: !resolved.links.isEmpty) else { return false }
        h.writeByte(1)
        h.writeInline(resolved)
        for lk in resolved.links {
            if let matcher = view.config.codeLinkMatchFn,
               let slice = utf8Slice(resolved.text, range: lk.start..<lk.end),
               let m = matcher(slice) {
                h.writeByte(1)
                h.writeColor(m.color)
            } else {
                h.writeByte(0)
            }
            hashLinkURL(lk.url, into: &h)
        }
        return true
    }

    private enum HashBlockStep {
        case block(MarkdownDocBlock, MarkdownBlockMap?)
        case len(Int)
    }

    private func hashBlockDirect(_ rootBlock: MarkdownDocBlock, map rootMap: MarkdownBlockMap?, into h: inout MarkdownPairHasher) -> Bool {
        var stack: [HashBlockStep] = [.block(rootBlock, rootMap)]
        while let step = stack.popLast() {
            switch step {
            case .len(let n):
                h.writeInt(n)
            case let .block(b, mapOpt):
                switch (b, mapOpt) {
                case let (.para(inl), .deepTail(lines, _)):
                    h.writeByte(11)
                    h.writeInt(lines)
                    h.writeString(inl.text)
                case let (.para(inl), _):
                    h.writeByte(1)
                    if !hashInlineDirect(inl, into: &h) { return false }
                case let (.heading(level, inl), _):
                    h.writeByte(2)
                    h.writeInt(level)
                    if !hashInlineDirect(inl, into: &h) { return false }
                case let (.code(code), _):
                    guard canMemoFlags(MarkdownPreFlags.hasCode) else { return false }
                    h.writeByte(3)
                    h.writeString(code)
                case let (.diff(src), _):
                    h.writeByte(4)
                    h.writeString(src)
                case let (.mermaid(src), _):
                    guard canMemoFlags(MarkdownPreFlags.hasMermaid) else { return false }
                    h.writeByte(5)
                    h.writeString(src)
                case (.rule, _):
                    h.writeByte(6)
                case let (.image(src, alt, title), _):
                    guard canMemoFlags(MarkdownPreFlags.hasImage) else { return false }
                    h.writeByte(7)
                    h.writeString(src)
                    h.writeString(alt)
                    h.writeString(title)
                case let (.quote(inner), mapVal):
                    guard canMemoFlags(MarkdownPreFlags.hasQuote) else { return false }
                    let innerMaps: [MarkdownBlockMap] = if case let .quote(m) = mapVal { m } else { [] }
                    h.writeByte(8)
                    h.writeInt(inner.count)
                    for i in stride(from: inner.count - 1, through: 0, by: -1) {
                        stack.append(.block(inner[i], i < innerMaps.count ? innerMaps[i] : nil))
                    }
                case let (.list(start, items), mapVal):
                    let itemMaps: [[MarkdownBlockMap]] = if case let .list(m) = mapVal { m } else { [] }
                    h.writeByte(9)
                    if let st = start { h.writeByte(1); h.writeUInt64(st) } else { h.writeByte(0) }
                    h.writeInt(items.count)
                    for k in stride(from: items.count - 1, through: 0, by: -1) {
                        let item = items[k]
                        let imap = k < itemMaps.count ? itemMaps[k] : []
                        for j in stride(from: item.count - 1, through: 0, by: -1) {
                            stack.append(.block(item[j], j < imap.count ? imap[j] : nil))
                        }
                        stack.append(.len(item.count))
                    }
                case let (.table(t), _):
                    if t.open && view.config.isStreaming { return false }
                    h.writeByte(10)
                    h.writeBool(t.open)
                    h.writeInt(t.align.count)
                    h.writeInt(t.head.count)
                    h.writeInt(t.rows.count)
                    for a in t.align { h.writeAlign(a) }
                    for c in t.head { if !hashInlineDirect(c, into: &h) { return false } }
                    for row in t.rows {
                        h.writeInt(row.count)
                        for c in row { if !hashInlineDirect(c, into: &h) { return false } }
                    }
                }
            }
        }
        return true
    }

    private func hashSources(_ srcs: ArraySlice<MarkdownCodeSource>, into h: inout MarkdownPairHasher) {
        h.writeInt(srcs.count)
        for src in srcs {
            h.writeOptionalString(src.language)
            h.writeInt(src.length)
            h.writeInt(src.colouredBytes)
            h.writeBool(src.open)
        }
    }

    private func hashTasks(_ tasks: ArraySlice<MarkdownTaskState?>, into h: inout MarkdownPairHasher) {
        h.writeInt(tasks.count)
        for t in tasks {
            if let t {
                h.writeByte(1)
                h.writeBool(t.checked)
                h.writeInt(t.markerOffset)
            } else {
                h.writeByte(0)
            }
        }
    }

    private func settledBlockDigest(
        _ b: MarkdownDocBlock,
        pre: MarkdownPreBlock?,
        map: MarkdownBlockMap,
        key: String,
        top: Float,
        dir: MarkdownDirection?,
        srcRange: (at: Int, count: Int),
        taskRange: (at: Int, count: Int)
    ) -> MarkdownDigest128? {
        guard srcRange.at >= 0, srcRange.at + srcRange.count <= doc.sources.count,
              taskRange.at >= 0, taskRange.at + taskRange.count <= doc.tasks.count else { return nil }
        let srcs = doc.sources[srcRange.at..<(srcRange.at + srcRange.count)]
        if srcs.contains(where: \.open) { return nil }
        let tasks = doc.tasks[taskRange.at..<(taskRange.at + taskRange.count)]
        if view.onTaskHandler != nil && !view.config.areTasksReadOnly && tasks.contains(where: { $0 != nil }) {
            return nil
        }
        var h = MarkdownPairHasher()
        h.writeByte(1)
        h.writeDigest(baseDigest)
        h.writeString(key)
        h.writeFloat(top)
        h.writeDirection(dir)
        if let p = pre, view.config.codeLinkMatchFn == nil || (p.flags & MarkdownPreFlags.hasInlineCode) == 0 {
            guard canMemoFlags(p.flags), canMemoLinks(hasLinks: !p.links.isEmpty) else { return nil }
            h.writeDigest(p.digest)
            for url in p.links { hashLinkURL(url, into: &h) }
        } else {
            guard hashBlockDirect(b, map: map, into: &h) else { return nil }
        }
        hashFlow(flow, into: &h)
        hashSources(srcs, into: &h)
        hashTasks(tasks, into: &h)
        if !view.config.highlightsList.isEmpty {
            h.writeBlockMap(map)
        }
        return h.finish128()
    }

    private func settledItemDigest(
        _ item: [MarkdownDocBlock],
        pre: MarkdownPreItem?,
        imap: [MarkdownBlockMap],
        srcRange: (at: Int, count: Int),
        taskRange: (at: Int, count: Int)
    ) -> MarkdownDigest128? {
        guard srcRange.at >= 0, srcRange.at + srcRange.count <= doc.sources.count,
              taskRange.at >= 0, taskRange.at + taskRange.count <= doc.tasks.count else { return nil }
        let srcs = doc.sources[srcRange.at..<(srcRange.at + srcRange.count)]
        if srcs.contains(where: \.open) { return nil }
        let tasks = doc.tasks[taskRange.at..<(taskRange.at + taskRange.count)]
        if view.onTaskHandler != nil && !view.config.areTasksReadOnly && tasks.contains(where: { $0 != nil }) {
            return nil
        }
        var h = MarkdownPairHasher()
        h.writeByte(2)
        h.writeDigest(baseDigest)
        if let p = pre, view.config.codeLinkMatchFn == nil || (p.flags & MarkdownPreFlags.hasInlineCode) == 0 {
            guard canMemoFlags(p.flags), canMemoLinks(hasLinks: !p.links.isEmpty) else { return nil }
            h.writeDigest(p.digest)
            for url in p.links { hashLinkURL(url, into: &h) }
        } else {
            h.writeInt(item.count)
            for (j, b) in item.enumerated() {
                guard hashBlockDirect(b, map: j < imap.count ? imap[j] : nil, into: &h) else { return nil }
            }
        }
        hashFlow(flow, into: &h)
        hashSources(srcs, into: &h)
        hashTasks(tasks, into: &h)
        if !view.config.highlightsList.isEmpty {
            h.writeInt(imap.count)
            for m in imap { h.writeBlockMap(m) }
        }
        return h.finish128()
    }

    private func settledCodeCardDigest(_ code: String, source: MarkdownCodeSource?, map: MarkdownSpanMap?) -> MarkdownDigest128? {
        guard view.config.syntaxHighlighter.isBuiltin, source?.open != true else { return nil }
        var h = MarkdownPairHasher()
        h.writeByte(3)
        h.writeDigest(baseDigest)
        h.writeString(code)
        if let src = source {
            h.writeByte(1)
            h.writeOptionalString(src.language)
            h.writeInt(src.length)
            h.writeInt(src.colouredBytes)
            h.writeBool(src.open)
        } else {
            h.writeByte(0)
        }
        if !view.config.highlightsList.isEmpty, let m = map {
            h.writeSpanMap(m)
        }
        return h.finish128()
    }

    private func settledTableRowDigest(
        cells: [MarkdownInline],
        pre: MarkdownPreRow?,
        maps: [MarkdownSpanMap],
        align: [MarkdownTableAlign],
        tableDir: MarkdownDirection?,
        natural: [Float],
        minWidths: [Float],
        widths: [Float]?,
        font: TextStyle,
        color: Color,
        pad: [Float],
        cellRoleTag: UInt8,
        key: String,
        extraTag: UInt8,
        extraBool: Bool = false,
        extraA: Float = 0,
        extraB: Float = 0
    ) -> MarkdownDigest128? {
        var h = MarkdownPairHasher()
        h.writeByte(4)
        h.writeDigest(baseDigest)
        h.writeByte(cellRoleTag)
        h.writeString(key)
        h.writeByte(extraTag)
        h.writeBool(extraBool)
        h.writeFloat(extraA)
        h.writeFloat(extraB)
        h.writeTextStyle(font)
        h.writeColor(color)
        h.writeInt(pad.count)
        for p in pad { h.writeFloat(p) }
        h.writeDirection(tableDir)
        if let p = pre, view.config.codeLinkMatchFn == nil || (p.flags & MarkdownPreFlags.hasInlineCode) == 0 {
            guard canMemoLinks(hasLinks: !p.links.isEmpty) else { return nil }
            h.writeDigest(p.digest)
            for url in p.links { hashLinkURL(url, into: &h) }
        } else {
            h.writeInt(cells.count)
            for c in cells {
                guard hashInlineDirect(c, into: &h) else { return nil }
            }
        }
        h.writeInt(align.count)
        for a in align { h.writeAlign(a) }
        h.writeInt(natural.count)
        for w in natural { h.writeFloat(w) }
        h.writeInt(minWidths.count)
        for w in minWidths { h.writeFloat(w) }
        if let ws = widths {
            h.writeByte(1)
            h.writeInt(ws.count)
            for w in ws { h.writeFloat(w) }
        } else {
            h.writeByte(0)
        }
        if !view.config.highlightsList.isEmpty {
            h.writeInt(maps.count)
            for m in maps { h.writeSpanMap(m) }
        }
        return h.finish128()
    }

    private func tableRowWidthKey(
        cells: [MarkdownInline],
        pre: MarkdownPreRow?,
        colCount n: Int,
        font: TextStyle,
        epoch: UInt64
    ) -> MarkdownDigest128 {
        var h = MarkdownPairHasher()
        h.writeInt(n)
        h.writeTextStyle(font)
        h.writeFloat(s.inlineCodeScale)
        h.writeFloat(s.inlineCodeWeight)
        h.writeFloat(s.inlineCodePad)
        h.writeFloat(s.strongWeight)
        h.writeUInt64(epoch)
        h.writeInt(min(cells.count, n))
        if let p = pre, cells.count <= n,
           view.config.codeLinkMatchFn == nil || (p.flags & MarkdownPreFlags.hasInlineCode) == 0 {
            h.writeDigest(p.digest)
            if view.config.linkPaintFn != nil || view.config.linkLookFn != nil {
                for url in p.links {
                    let st = resolvedLinkStyle(url)
                    h.writeOptionalFloat(st?.weight)
                }
            }
        } else {
            for j in 0..<min(cells.count, n) {
                let resolved = withCodeLinks(cells[j])
                h.writeInline(resolved)
                if view.config.linkPaintFn != nil || view.config.linkLookFn != nil {
                    for lk in resolved.links {
                        let st = resolvedLinkStyle(lk.url)
                        h.writeOptionalFloat(st?.weight)
                    }
                }
            }
        }
        return h.finish128()
    }

    // MARK: Iterative Frame-Stack Block / Quote / List Renderer (`render.rs`, #1122 + #1130)

    @inline(never)
    private func unmemoisedBlock(
        _ b: MarkdownDocBlock,
        pre: MarkdownPreBlock?,
        map: MarkdownBlockMap,
        quotePlainCache: inout MarkdownPlain.QuotePlainCache
    ) -> El<State> {
        switch b {
        case let .quote(inner):
            let innerMaps = map.quoteMaps ?? []
            let saved = flow
            let firstTask = nextTask
            flow = FlowState(
                lists: saved.lists,
                inset: saved.inset + s.quote.width + s.quote.pad,
                ink: s.quote.text ?? saved.ink,
                cols: saved.cols,
                lead: saved.lead
            )
            let qFrame = QuoteFrame(
                quotePre: pre,
                inner: inner,
                innerPre: pre?.inner,
                innerMaps: innerMaps,
                savedFlow: saved,
                firstTask: firstTask,
                quoteDir: blockDir(b, pre: pre)
            )
            let bFrame = BlocksFrame(
                blocks: inner,
                pre: pre?.inner,
                maps: innerMaps,
                names: renderedKeys(count: inner.count, keys: []),
                topLevel: false,
                inItem: false,
                openTail: false,
                allowMemo: false,
                lastDir: nil,
                curCol: col().wFull()
            )
            return runFrames(initial: [.quote(qFrame), .blocks(bFrame)], quotePlainCache: &quotePlainCache)
        case let .list(start, items):
            let itemMaps = map.listMaps ?? []
            let saved = flow
            let indent = listIndent(start: start, listsDepth: saved.lists)
            let space = listOutsideSpace(start: start)
            let lFrame = ListFrame(
                start: start,
                items: items,
                preItems: pre?.items,
                itemMaps: itemMaps,
                savedFlow: saved,
                indent: indent,
                space: space,
                openTail: false,
                allowMemo: false,
                listDir: blockDir(b, pre: pre),
                listCol: col().role(.list).wFull()
            )
            return runFrames(initial: [.list(lFrame)], quotePlainCache: &quotePlainCache)
        default:
            return leafBlock(b, pre: pre, map: map)
        }
    }

    private func listIndent(start: UInt64?, listsDepth: Int) -> Float {
        if let nested = s.listNested, listsDepth > 0 {
            return start != nil ? nested[1] : nested[0]
        }
        return s.listIndent
    }

    private func listOutsideSpace(start: UInt64?) -> Float {
        if start != nil && s.listOutside {
            return TextMeasure.measure("x x", style: s.body).x - TextMeasure.measure("xx", style: s.body).x
        }
        return 0
    }

    @inline(never)
    private func runFrames(
        initial: [RenderFrame],
        quotePlainCache: inout MarkdownPlain.QuotePlainCache
    ) -> El<State> {
        var stack = initial
        var ret: El<State>? = nil

        while let top = stack.last {
            switch top {
            case .blocks(let frame):
                stepBlocksFrame(frame, stack: &stack, ret: &ret)
            case .quote(let frame):
                stack.removeLast()
                ret = finishQuoteFrame(frame, drawn: ret ?? col().wFull(), quotePlainCache: &quotePlainCache)
            case .list(let frame):
                stepListFrame(frame, stack: &stack, ret: &ret)
            }
        }
        return ret ?? col().wFull()
    }

    @inline(never)
    private func buildMemoisedBlock(
        _ b: MarkdownDocBlock,
        pre pb: MarkdownPreBlock?,
        map: MarkdownBlockMap,
        key: String,
        top: Float,
        prose: Bool,
        dir: MarkdownDirection?,
        srcAt: Int,
        srcN: Int,
        taskAt: Int,
        taskN: Int,
        digest: MarkdownDigest128
    ) -> El<State> {
        let cachedEl = cachedSubtree(digest) {
            Markdown.noteBlockBuild()
            self.nextSource = srcAt
            self.nextTask = taskAt
            var subQpc: MarkdownPlain.QuotePlainCache = [:]
            var childEl = self.unmemoisedBlock(b, pre: pb, map: map, quotePlainCache: &subQpc)
            assert(self.nextSource == srcAt + srcN)
            assert(self.nextTask == taskAt + taskN)
            if prose { childEl.setMarkdownDirection(dir) }
            childEl = childEl.key(key)
            return top > 0 ? childEl.mt(top) : childEl
        }
        nextSource = srcAt + srcN
        nextTask = taskAt + taskN
        return cachedEl
    }

    @inline(never)
    private func stepBlocksFrame(
        _ frame: BlocksFrame,
        stack: inout [RenderFrame],
        ret: inout El<State>?
    ) {
        if let childEl = ret {
            ret = nil
            if let p = frame.pending {
                frame.pending = nil
                var drawn = childEl
                if p.prose { drawn.setMarkdownDirection(p.own ?? frame.lastDir) }
                if let own = p.own { frame.lastDir = own }
                drawn = drawn.key(p.key)
                if p.top > 0 { drawn = drawn.mt(p.top) }
                frame.curCol.children.append(drawn)
            }
            return
        }

        while frame.idx < frame.blocks.count {
            let i = frame.idx
            frame.idx += 1
            let b = frame.blocks[i]
            if view.config.isStreaming, case let .code(codeStr) = b, codeStr.isEmpty {
                if nextSource < doc.sources.count, doc.sources[nextSource].open, doc.sources[nextSource].length == 0 {
                    nextSource += 1
                    continue
                }
            }

            let (mt, mb) = collapsed(b, index: i, inItem: frame.inItem)
            let top: Float
            if i == 0 {
                top = 0
            } else {
                switch b {
                case .heading, .rule, .image: top = max(mt, frame.prevMb)
                default: top = frame.afterHeading ? frame.prevMb : max(mt, frame.prevMb)
                }
            }
            frame.prevMb = mb
            if case .heading = b { frame.afterHeading = true } else { frame.afterHeading = false }

            let key = frame.names[i]
            if frame.topLevel { currentBlockKey = key }
            if i > 0 { flow.lead = nil }

            let pb: MarkdownPreBlock? = frame.pre.flatMap { i < $0.count ? $0[i] : nil }
            let own = blockDir(b, pre: pb)
            let prose: Bool = switch b {
            case .code, .diff, .mermaid, .image, .rule: false
            default: true
            }
            let dir: MarkdownDirection? = prose ? (own ?? frame.lastDir) : nil
            let map: MarkdownBlockMap = i < frame.maps.count ? frame.maps[i] : .none
            let childOpenTail = frame.openTail && (i + 1 == frame.blocks.count)
            let isDeepTail: Bool = if case .para = b, case .deepTail = map { true } else { false }
            let canMemoHere = frame.allowMemo && !childOpenTail && !(view.config.isStreaming && isDeepTail)

            if canMemoHere {
                let srcAt = nextSource
                let srcN = pb.map { Int($0.srcN) } ?? MarkdownMemoMeta.sourceCount(b)
                let taskAt = nextTask
                let taskN = pb.map { Int($0.taskN) } ?? MarkdownMemoMeta.taskCount(b)
                if let digest = settledBlockDigest(
                    b, pre: pb, map: map, key: key, top: top, dir: dir,
                    srcRange: (srcAt, srcN), taskRange: (taskAt, taskN)
                ) {
                    let cachedEl = buildMemoisedBlock(
                        b, pre: pb, map: map, key: key, top: top, prose: prose, dir: dir,
                        srcAt: srcAt, srcN: srcN, taskAt: taskAt, taskN: taskN, digest: digest
                    )
                    if let own { frame.lastDir = own }
                    frame.curCol.children.append(cachedEl)
                    continue
                }
            }

            switch b {
            case let .quote(inner):
                frame.pending = (key: key, top: top, prose: prose, own: own)
                let innerMaps = map.quoteMaps ?? []
                let saved = flow
                let firstTask = nextTask
                flow = FlowState(
                    lists: saved.lists,
                    inset: saved.inset + s.quote.width + s.quote.pad,
                    ink: s.quote.text ?? saved.ink,
                    cols: saved.cols,
                    lead: saved.lead
                )
                stack.append(.quote(QuoteFrame(
                    quotePre: pb,
                    inner: inner,
                    innerPre: pb?.inner,
                    innerMaps: innerMaps,
                    savedFlow: saved,
                    firstTask: firstTask,
                    quoteDir: own
                )))
                stack.append(.blocks(BlocksFrame(
                    blocks: inner,
                    pre: pb?.inner,
                    maps: innerMaps,
                    names: renderedKeys(count: inner.count, keys: []),
                    topLevel: false,
                    inItem: false,
                    openTail: childOpenTail,
                    allowMemo: frame.allowMemo,
                    lastDir: nil,
                    curCol: col().wFull()
                )))
                return
            case let .list(start, items):
                frame.pending = (key: key, top: top, prose: prose, own: own)
                let itemMaps = map.listMaps ?? []
                let saved = flow
                let indent = listIndent(start: start, listsDepth: saved.lists)
                let space = listOutsideSpace(start: start)
                stack.append(.list(ListFrame(
                    start: start,
                    items: items,
                    preItems: pb?.items,
                    itemMaps: itemMaps,
                    savedFlow: saved,
                    indent: indent,
                    space: space,
                    openTail: childOpenTail,
                    allowMemo: frame.allowMemo,
                    listDir: own,
                    listCol: col().role(.list).wFull()
                )))
                return
            default:
                var drawn = leafBlock(b, pre: pb, map: map)
                if prose { drawn.setMarkdownDirection(dir) }
                if let own { frame.lastDir = own }
                drawn = drawn.key(key)
                if top > 0 { drawn = drawn.mt(top) }
                frame.curCol.children.append(drawn)
            }
        }

        stack.removeLast()
        ret = frame.curCol
    }

    @inline(never)
    private func finishQuoteFrame(
        _ frame: QuoteFrame,
        drawn: El<State>,
        quotePlainCache: inout MarkdownPlain.QuotePlainCache
    ) -> El<State> {
        flow = frame.savedFlow
        let qEl: El<State> = row()
            .role(.blockquote)
            .wFull()
            .child(el().w(s.quote.width).hFull().rounded(min(s.quote.width / 2.0, 1.0)).bg(s.quoteRule))
            .child(drawn.grow(1).shrink(1).pl(s.quote.pad))
            .markdownDirection(frame.quoteDir)
        if let qFrame = view.quoteFrameHandler {
            var tIdx = frame.firstTask
            let plain = MarkdownPlain.renderCached(
                quotePre: frame.quotePre,
                blocks: frame.inner,
                maps: frame.innerMaps,
                pre: frame.innerPre,
                tasks: doc.tasks,
                nextTask: &tIdx,
                cols: frame.savedFlow.cols,
                lists: frame.savedFlow.lists,
                cache: &quotePlainCache
            )
            return qFrame(qEl, MarkdownQuoteFrameContext(text: plain))
        }
        return qEl
    }

    @inline(never)
    private func buildMemoisedItemBody(
        item: [MarkdownDocBlock],
        ipre: MarkdownPreItem?,
        imap: [MarkdownBlockMap],
        srcAt: Int,
        srcN: Int,
        taskAt: Int,
        taskN: Int,
        digest: MarkdownDigest128
    ) -> El<State> {
        let body = cachedSubtree(digest) {
            Markdown.noteBlockBuild()
            self.nextSource = srcAt
            self.nextTask = taskAt
            var subQpc: MarkdownPlain.QuotePlainCache = [:]
            let itemFrame = BlocksFrame(
                blocks: item,
                pre: ipre?.inner,
                maps: imap,
                names: self.renderedKeys(count: item.count, keys: []),
                topLevel: false,
                inItem: true,
                openTail: false,
                allowMemo: false,
                lastDir: nil,
                curCol: col().wFull()
            )
            let b = self.runFrames(initial: [.blocks(itemFrame)], quotePlainCache: &subQpc).grow(1).shrink(1)
            assert(self.nextSource == srcAt + srcN)
            assert(self.nextTask == taskAt + taskN)
            return b
        }
        nextSource = srcAt + srcN
        nextTask = taskAt + taskN
        return body
    }

    @inline(never)
    private func stepListFrame(
        _ frame: ListFrame,
        stack: inout [RenderFrame],
        ret: inout El<State>?
    ) {
        if let itemBody = ret {
            ret = nil
            if let p = frame.pendingItem {
                frame.pendingItem = nil
                let rowEl: El<State>
                if p.isDeepTail {
                    rowEl = row().key("i\(p.k)").wFull().pl(frame.indent).child(itemBody.grow(1).shrink(1))
                } else if let task = p.task {
                    rowEl = renderTaskItemBody(
                        k: p.k, n: frame.realN, indent: frame.indent, item: frame.items[p.k],
                        itemBody: itemBody, markerOffset: task.markerOffset, checked: task.checked
                    )
                } else {
                    let marker = renderListMarker(start: frame.start, k: p.k, indent: frame.indent, space: frame.space)
                    rowEl = row()
                        .key("i\(p.k)")
                        .role(.listItem)
                        .positionInSet(p.k + 1, size: frame.realN)
                        .wFull()
                        .child(withReveal(marker).a11yHidden())
                        .child(itemBody.grow(1).shrink(1))
                }
                frame.listCol.children.append(p.gapMt > 0 ? rowEl.mt(p.gapMt) : rowEl)
            }
            return
        }

        while frame.idx < frame.items.count {
            let k = frame.idx
            frame.idx += 1
            let item = frame.items[k]
            let ipre: MarkdownPreItem? = frame.preItems.flatMap { k < $0.count ? $0[k] : nil }
            let imap = k < frame.itemMaps.count ? frame.itemMaps[k] : []
            let isDeepTail: Bool = imap.count == 1 && ({ if case .deepTail = imap[0] { return true }; return false }())
            let itemOpenTail = frame.openTail && (k + 1 == frame.items.count)
            let gapMt = listItemGap(items: frame.items, k: k)
            let taskIdx = nextTask
            nextTask = taskIdx + 1

            if isDeepTail {
                flow = FlowState(
                    lists: frame.savedFlow.lists + 1,
                    inset: frame.savedFlow.inset + frame.indent,
                    ink: frame.savedFlow.ink,
                    cols: frame.savedFlow.cols,
                    lead: nil
                )
                frame.pendingItem = (k: k, gapMt: gapMt, task: nil, isDeepTail: true)
                stack.append(.blocks(BlocksFrame(
                    blocks: item,
                    pre: ipre?.inner,
                    maps: imap,
                    names: renderedKeys(count: item.count, keys: []),
                    topLevel: false,
                    inItem: true,
                    openTail: itemOpenTail,
                    allowMemo: false,
                    lastDir: nil,
                    curCol: col().wFull()
                )))
                return
            }

            let task: MarkdownTaskState? = taskIdx < doc.tasks.count ? doc.tasks[taskIdx] : nil
            let lead: Lead
            if let task {
                lead = .task(task.checked)
            } else if let start = frame.start {
                lead = .number(start + UInt64(k))
            } else {
                lead = .bullet
            }
            let beforeBreaks: UInt8 = (k == 0 && frame.savedFlow.lists == 0) ? 2 : 1
            flow = FlowState(
                lists: frame.savedFlow.lists + 1,
                inset: frame.savedFlow.inset + frame.indent,
                ink: frame.savedFlow.ink,
                cols: frame.savedFlow.cols + lead.width,
                lead: (frame.savedFlow.cols, lead, beforeBreaks)
            )

            if task == nil && frame.allowMemo && !itemOpenTail {
                let srcAt = nextSource
                let srcN = ipre.map { Int($0.srcN) } ?? item.reduce(0) { $0 + MarkdownMemoMeta.sourceCount($1) }
                let taskAt = nextTask
                let taskN = ipre.map { Int($0.taskN) } ?? item.reduce(0) { $0 + MarkdownMemoMeta.taskCount($1) }
                if let digest = settledItemDigest(
                    item, pre: ipre, imap: imap,
                    srcRange: (srcAt, srcN), taskRange: (taskAt, taskN)
                ) {
                    let body = buildMemoisedItemBody(
                        item: item, ipre: ipre, imap: imap,
                        srcAt: srcAt, srcN: srcN, taskAt: taskAt, taskN: taskN, digest: digest
                    )
                    let marker = renderListMarker(start: frame.start, k: k, indent: frame.indent, space: frame.space)
                    let rowEl: El<State> = row()
                        .key("i\(k)")
                        .role(.listItem)
                        .positionInSet(k + 1, size: frame.realN)
                        .wFull()
                        .child(withReveal(marker).a11yHidden())
                        .child(body)
                    frame.listCol.children.append(gapMt > 0 ? rowEl.mt(gapMt) : rowEl)
                    continue
                }
            }

            frame.pendingItem = (k: k, gapMt: gapMt, task: task, isDeepTail: false)
            stack.append(.blocks(BlocksFrame(
                blocks: item,
                pre: ipre?.inner,
                maps: imap,
                names: renderedKeys(count: item.count, keys: []),
                topLevel: false,
                inItem: true,
                openTail: itemOpenTail,
                allowMemo: frame.allowMemo,
                lastDir: nil,
                curCol: col().wFull()
            )))
            return
        }

        stack.removeLast()
        flow = frame.savedFlow
        ret = frame.listCol.markdownDirection(frame.listDir)
    }

    private func renderListMarker(start: UInt64?, k: Int, indent: Float, space: Float) -> El<State> {
        if start == nil && s.listOutside {
            return el().w(indent).h(s.body.linePx()).child(el().outsideListDisc(s.body).bg(s.muted))
        }
        let label = start.map { "\($0 + UInt64(k))." } ?? "•"
        let words: El<State> = text(label).font(s.body).color(s.muted).exactLines().w(indent)
        return s.listOutside ? words.textAlign(.trailing).pr(space) : words.textAlign(.center)
    }

    /// Renders a past-bound deep-tail block as one selectable, searchable, copyable plain card
    /// preceded by a visible, unselectable `RuneLabel.moreNestedLines(lines)` marker (`#1122`).
    private func renderDeepTail(_ inl: MarkdownInline, lines: Int, map: MarkdownSpanMap) -> El<State> {
        let chunkCap = 32 * 1024
        let pad = String(repeating: " ", count: flow.cols)
        let label = RuneLabels.shared.label(for: .moreNestedLines(lines))
        let header: El<State> = el()
            .key("more")
            .role(.group)
            .label(label)
            .wFull()
            .child(withReveal(text(label)).font(s.codeBlock).color(s.muted).wFull().a11yHidden())
        let allHl = makeTextHighlights(for: inl.text, map: map)
        let ink = flow.ink ?? s.text
        var card: El<State> = col()
            .key("deep-tail")
            .wFull()
            .gap(4)
            .px(10)
            .py(8)
            .rounded(6)
            .bg(s.codeBlockFill)
            .border(0.5, s.codeBlockBorder)
            .borderLayout()
            .child(header)

        let full = inl.text
        let fullBytes = Array(full.utf8)
        var start = 0
        var chunkIdx = 0
        while start < fullBytes.count || chunkIdx == 0 {
            let maxEnd = min(start + chunkCap, fullBytes.count)
            let end: Int
            if maxEnd == fullBytes.count {
                end = fullBytes.count
            } else if let relNl = fullBytes[start..<maxEnd].lastIndex(of: 0x0A) {
                end = relNl
            } else {
                let floored = floorUTF8Boundary(full, byte: maxEnd)
                end = floored > start ? floored : ceilUTF8Boundary(full, byte: maxEnd + 1)
            }
            let slice = utf8Slice(full, range: start..<end) ?? ""
            let chunkHl: [TextHighlight] = allHl.compactMap { h in
                let a = max(h.byteRange.lowerBound, start)
                let b = min(h.byteRange.upperBound, end)
                guard a < b else { return nil }
                var copy = h
                copy.byteRange = (a - start)..<(b - start)
                return copy
            }
            let isLast = end >= fullBytes.count
            let rawNode = withReveal(
                tabbedRich(slice, spans: [TextSpan(slice, color: ink)], highlights: chunkHl, style: s.codeBlock, color: ink)
            )
                .wFull()
                .copyPrefix(pad)
                .copyBreaks(chunkIdx == 0 ? 2 : 1, isLast ? 2 : 1)
            let node = applySelect(rawNode).key("c\(chunkIdx)")
            card.children.append(node)
            chunkIdx += 1
            if isLast { break }
            start = (end < fullBytes.count && fullBytes[end] == 0x0A) ? (end + 1) : end
        }
        return card
    }

    private func leafBlock(_ b: MarkdownDocBlock, pre: MarkdownPreBlock?, map: MarkdownBlockMap) -> El<State> {
        if case let .para(inl) = b, case let .deepTail(lines, tailMap) = map {
            return renderDeepTail(inl, lines: lines, map: tailMap)
        }
        let inlMap: MarkdownSpanMap? = if case let .inline(m) = map { m } else { nil }
        let codeMap: MarkdownSpanMap? = if case let .code(m) = map { m } else { nil }

        switch b {
        case let .para(inl):
            return renderPara(inl, map: inlMap, font: s.body, color: flow.ink ?? s.text)

        case let .heading(lvl, inl):
            let clamped = min(max(lvl, 1), 4) - 1
            let hFont = s.headings[clamped]
            let hColor = lvl >= 4 ? s.muted : s.text
            return renderPara(inl, map: inlMap, font: hFont, color: hColor)
                .headingLevel(lvl)

        case let .code(code):
            let idx = nextSource
            nextSource += 1
            let srcMeta = (idx < doc.sources.count && doc.sources[idx].length == code.utf8.count) ? doc.sources[idx] : nil
            if let frameFn = view.codeFrameHandler {
                let card: El<State>
                if let digest = settledCodeCardDigest(code, source: srcMeta, map: codeMap) {
                    card = cachedSubtree(digest) {
                        Markdown.noteBlockBuild()
                        return self.renderCode(code, source: srcMeta, map: codeMap).key("card")
                    }
                } else {
                    card = renderCode(code, source: srcMeta, map: codeMap).key("card")
                }
                return col().wFull().child(frameFn(card, MarkdownCodeFrameContext(index: idx, source: code, language: srcMeta?.language, open: srcMeta?.open ?? false)))
            }
            return renderCode(code, source: srcMeta, map: codeMap)

        case let .diff(src):
            return renderDiff(src, map: codeMap)

        case let .mermaid(src):
            let idx = nextSource
            nextSource += 1
            let srcMeta = (idx < doc.sources.count && doc.sources[idx].length == src.utf8.count) ? doc.sources[idx] : nil
            return renderMermaidBlock(src, source: srcMeta, map: codeMap, index: idx)

        case let .table(t):
            let (hm, rm): ([MarkdownSpanMap], [[MarkdownSpanMap]]) = if case let .table(head, rows) = map { (head, rows) } else { ([], []) }
            return renderTable(t, pre: pre?.table, headMaps: hm, rowMaps: rm)

        case let .image(src, alt, title):
            return renderImage(src: src, alt: alt, title: title)

        case .rule:
            return s.rule.a <= 0 ? el().wFull().h(0) : el().wFull().h(0.5).bg(s.rule)

        case .list, .quote:
            preconditionFailure("Containers handled iteratively in runFrames")
        }
    }

    private func renderImage(src: String, alt: String, title: String) -> El<State> {
        let imgBox: El<State> = col()
            .role(.image)
            .label(alt.isEmpty ? src : alt)
            .cursor(.zoomIn)
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
        if inl.spans.isEmpty && inl.links.isEmpty { return [TextSpan(inl.text, color: baseColor)] }
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
        let spansByStart = inl.spans.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        let linksByStart = inl.links.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var sIdx = 0
        var lIdx = 0
        var activeSpans: [MarkdownStyleSpan] = []
        var activeLinks: [MarkdownLinkSpan] = []

        var spans: [TextSpan] = []
        spans.reserveCapacity(max(1, sorted.count - 1))

        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            guard a < b else { continue }
            let seg = String(decoding: bytes[a..<b], as: UTF8.self)

            while sIdx < spansByStart.count && spansByStart[sIdx].start <= a {
                activeSpans.append(spansByStart[sIdx])
                sIdx += 1
            }
            activeSpans.removeAll(where: { $0.end <= a })

            while lIdx < linksByStart.count && linksByStart[lIdx].start <= a {
                activeLinks.append(linksByStart[lIdx])
                lIdx += 1
            }
            activeLinks.removeAll(where: { $0.end <= a })

            var isCodePad = false
            var isCode = false
            var isStrong = false
            var isEm = false
            var isStrike = false
            for sp in activeSpans where sp.start <= a && b <= sp.end {
                switch sp.style {
                case .codePad: isCodePad = true
                case .code: isCode = true
                case .strong: isStrong = true
                case .em: isEm = true
                case .strike: isStrike = true
                case .link: break
                }
            }
            let link = activeLinks.first(where: { $0.start <= a && b <= $0.end })

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
                if let custom = resolvedLinkStyle(link.url) {
                    fg = custom.color ?? s.accent
                    underline = custom.underline
                    if !isStrong && !isCode, let w = custom.weight { weight = w }
                    if !isCode, let lbg = custom.bg { bg = lbg }
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

    /// A block's text as drawn (`render.rs` `with_reveal`). A source still streaming in wraps
    /// prettily too (#941): the block that grows keeps `text-wrap-style: pretty`, as a page does,
    /// so a word moves, if it does, as the text that moves it arrives, not when the stream ends.
    private func withReveal(_ node: El<State>) -> El<State> {
        if view.config.revealDelay >= 0 { return node.reveal(view.config.revealDelay) }
        return view.config.isStreaming ? node.reveal(0) : node
    }

    private func makeTextHighlights(for renderedText: String, map: MarkdownSpanMap?) -> [TextHighlight] {
        guard let map, !view.config.highlightsList.isEmpty else { return [] }
        var out: [TextHighlight] = []
        for (idx, item) in view.config.highlightsList.enumerated() {
            let hl = item.style
            let bg = hl.bg ?? (hl.current ? s.highlightCurrentBg : s.highlightBg)
            let fg = hl.fg ?? (hl.current ? s.highlightCurrentFg : s.highlightFg)
            let ringTuple = (hl.ringColor != nil && hl.ringWidth != nil)
                ? (hl.ringColor!, hl.ringWidth!)
                : (hl.current ? s.highlightCurrentRing : s.highlightRing)
            let key = hl.key ?? Markdown.highlightKey(idx)
            for r in map.mapRanges(item.ranges, in: renderedText) {
                var th = TextHighlight(r, bg: bg, fg: fg, ring: ringTuple.map { TextRing(color: $0.0, width: $0.1) }, key: key)
                if hl.key == nil && key.isEmpty {
                    th.key = Markdown.highlightKey(idx)
                }
                out.append(th)
            }
        }
        return out
    }

    private func applyLinkIcons(_ node: El<State>, inl: MarkdownInline) -> El<State> {
        guard let pos = s.linkIcon else { return node }
        let size: Float
        let gap: Float
        switch pos {
        case let .leading(g, sz), let .trailing(g, sz):
            size = sz
            gap = g
        }
        var out = node
        for link in inl.links {
            guard let host = MarkdownLinkIcons.linkHost(link.url),
                  let slice = utf8Slice(inl.text, range: link.start..<link.end),
                  !slice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let icon: InlineIcon
            if host != "github.com", let px = view.config.linkFaviconFn?(link.url) {
                icon = InlineIcon.image(px).radius(2.0).size(size).gap(gap)
            } else {
                let glyph = (host == "github.com") ? MarkdownLinkIcons.github : MarkdownLinkIcons.globe
                icon = InlineIcon.glyph(glyph).color(s.accent).size(size).gap(gap)
            }
            out = out.inlineIcon(at: link.start, icon)
        }
        return out
    }

    private func resolvedLinkStyle(_ url: String) -> MarkdownLinkStyle? {
        if let p = view.config.linkPaintFn?(url) {
            return p
        }
        if let legacy = view.config.linkLookFn?(url) {
            return MarkdownLinkStyle(
                color: legacy.color,
                underline: legacy.underline,
                weight: legacy.weight,
                bg: nil,
                hoverColor: legacy.hoverColor,
                hoverBg: nil
            )
        }
        return nil
    }

    private func wireLinks(_ node: inout El<State>, inl: MarkdownInline) {
        guard !inl.links.isEmpty else { return }
        let interactive = view.onLinkHandler != nil || view.onLinkSecondaryHandler != nil || view.config.linkHelpFn != nil || view.config.linkLookFn != nil || view.config.linkPaintFn != nil || view.config.linkRingFn != nil || s.linkHover != nil
        guard interactive else { return }
        // selectInline only decorates rich-text leaves created by this renderer.
        var links = node.textLinks
        links.reserveCapacity(links.count + inl.links.count)
        for link in inl.links {
            let look = resolvedLinkStyle(link.url)
            let hoverInk = look?.hoverColor ?? s.linkHover
            let underlineOn = look?.underline ?? true
            let ringTuple = view.config.linkRingFn?(link.url)
            var paint = LinkPaint()
            if let hoverInk {
                paint = paint.color(hoverInk)
            }
            if let hoverBg = look?.hoverBg {
                paint = paint.bg(hoverBg)
            }
            paint = paint.underline(underlineOn)
            if let ringTuple {
                paint = paint.ring(ringTuple.0, width: ringTuple.1)
            }
            let help = view.config.linkHelpFn?(link.url)
            links.append(TextLink(link.start..<link.end, id: link.url, hover: paint, help: help))
        }
        node.textLinks = links
        node.focusable = true
        if let onLink = view.onLinkHandler {
            node.handlers.onLink = onLink
        }
        if let onSec = view.onLinkSecondaryHandler {
            node.handlers.onLinkSecondary = onSec
        }
    }

    private func selectInline(_ node: consuming El<State>, inl: MarkdownInline, map: MarkdownSpanMap?) -> El<State> {
        var out = applyLinkIcons(node, inl: inl)
        out.textHighlights = makeTextHighlights(for: inl.text, map: map)
        wireLinks(&out, inl: inl)
        out = applySelect(out)
        if view.config.isSelectable {
            for sp in inl.spans where sp.style == .codePad {
                out = out.uncopied(sp.start..<sp.end)
            }
        }
        return out
    }

    private func renderPara(_ rawInl: MarkdownInline, map: MarkdownSpanMap?, font: TextStyle, color: Color) -> El<State> {
        let inl = withCodeLinks(rawInl)
        let spans = buildTextSpans(inl, font: font, baseColor: color)
        var elNode: El<State> = rawInl.bidi.isolate(withReveal(rich(spans).font(font).color(color).wrap(.wrap)).wFull())
        if let lead = flow.lead {
            elNode = elNode.copyPrefix(String(repeating: " ", count: lead.cols) + lead.lead.marker).copyBreaks(lead.before, 1)
        } else {
            elNode = elNode.copyBreaks(2, 2)
        }
        return selectInline(elNode, inl: inl, map: map)
    }

    private func tabbedRich(_ code: String, spans: [TextSpan], highlights: [TextHighlight], style: TextStyle, color: Color) -> El<State> {
        if !code.contains("\t") || style.family.isMonospace {
            return rich(spans).font(style).color(color).wrap(.wrap).textHighlights(highlights)
        }
        // Expand tabs visually to 4-column stops while keeping tab characters and uncopied spaces for selection copy
        var shown = ""
        shown.reserveCapacity(code.utf8.count + code.utf8.count / 8)
        var tabs: [(srcByte: Int, shownByte: Int, pad: Int, totalPad: Int)] = []
        var col = 0
        var srcByte = 0
        for ch in code {
            let utf8Len = ch.utf8.count
            if ch == "\t" {
                let pad = 3 - (col % 4)
                let total = (tabs.last?.totalPad ?? 0) + pad
                tabs.append((srcByte, shown.utf8.count, pad, total))
                shown.append("\t")
                shown.append(String(repeating: " ", count: pad))
                col += pad + 1
            } else {
                col = (ch == "\n") ? 0 : (col + 1)
                shown.append(ch)
            }
            srcByte += utf8Len
        }
        func shiftByte(_ b: Int) -> Int {
            var lo = 0
            var hi = tabs.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if tabs[mid].srcByte < b {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            return lo == 0 ? b : (b + tabs[lo - 1].totalPad)
        }
        // Rebuild TextSpans cleanly onto `shown` by re-slicing original `spans` offsets
        var outSpans: [TextSpan] = []
        outSpans.reserveCapacity(spans.count + tabs.count)
        var origCursor = 0
        for sp in spans {
            let origLen = sp.text.utf8.count
            let s0 = shiftByte(origCursor)
            let s1 = shiftByte(origCursor + origLen)
            origCursor += origLen
            if let slice = utf8Slice(shown, range: s0..<s1) {
                var copy = sp
                copy.text = slice
                outSpans.append(copy)
            }
        }
        let shiftedHighlights = highlights.map { h -> TextHighlight in
            var c = h
            c.byteRange = shiftByte(h.byteRange.lowerBound)..<shiftByte(h.byteRange.upperBound)
            return c
        }
        var elNode: El<State> = rich(outSpans).font(style).color(color).wrap(.wrap).textHighlights(shiftedHighlights)
        for t in tabs where t.pad > 0 {
            elNode = elNode.uncopied((t.shownByte + 1)..<(t.shownByte + 1 + t.pad))
        }
        return elNode
    }

    private func renderCode(_ code: String, source: MarkdownCodeSource?, map: MarkdownSpanMap?) -> El<State> {
        let lang = source?.language
        let langLower = lang?.lowercased()
        let shell = langLower.flatMap { MarkdownRendererShared.shells.contains($0) ? s.shell : nil }
        let isPlain = langLower.map { MarkdownRendererShared.plainLangs.contains($0) } ?? true

        let fill: Color
        let border: Color
        let ink: Color
        if let shell {
            fill = shell.fill
            border = shell.border
            ink = shell.text
        } else if isPlain {
            fill = s.codeBlockFill
            border = s.codeBlockBorder
            ink = s.plainCodeText ?? s.codeText ?? s.text
        } else {
            fill = s.codeBlockFill
            border = s.codeBlockBorder
            ink = s.codeText ?? s.text
        }

        let syntaxPrefix: String
        if let source, source.open {
            syntaxPrefix = utf8Slice(code, range: 0..<min(source.colouredBytes, code.utf8.count)) ?? ""
        } else {
            syntaxPrefix = code
        }

        var spans: [TextSpan]
        if s.highlight && shell == nil && (!view.config.syntaxHighlighter.isBuiltin || (lang.map { Syntax.known($0) } ?? false)) {
            let colouredCount = syntaxPrefix.utf8.count
            let highlights = view.config.syntaxHighlighter.highlight(language: lang, code: syntaxPrefix)
            spans = s.syntax.spans(for: syntaxPrefix, highlights: highlights, defaultColor: ink, monospace: false)
            if colouredCount < code.utf8.count,
               let tail = utf8Slice(code, range: colouredCount..<code.utf8.count), !tail.isEmpty {
                spans.append(TextSpan(tail, color: ink))
            }
        } else {
            spans = [TextSpan(code.isEmpty ? " " : code, color: ink)]
        }

        let hls = makeTextHighlights(for: code, map: map)
        let richCode = withReveal(
            tabbedRich(code, spans: spans, highlights: hls, style: s.codeBlock, color: ink).byLine()
        ).copyBreaks(2, 2)
        let frame: El<State> = col()
            .role(.code)
            .dir(.ltr)
            .wFull()
            .rounded(6)
            .bg(fill)
            .border(0.5, border)
            .borderLayout()

        if view.config.isScrollWide {
            var viewport: El<State> = col().key("scroll").wFull().scrollX()
            if s.wideFade > 0 {
                viewport = viewport.scrollEdgeFade(s.wideFade)
            }
            return frame.child(viewport.child(col().px(s.codeBlockPad[0]).py(s.codeBlockPad[1]).child(applySelect(richCode))))
        }
        return frame.px(s.codeBlockPad[0]).py(s.codeBlockPad[1]).child(applySelect(richCode.wFull()))
    }

    private func renderDiff(_ src: String, map: MarkdownSpanMap?) -> El<State> {
        let hls = makeTextHighlights(for: src, map: map)
        var c: El<State> = col().role(.code).dir(.ltr).wFull().py(s.codeBlockPad[1]).rounded(6).bg(s.codeBlockFill).border(0.5, s.codeBlockBorder).borderLayout()
        var offset = 0
        let rawLines = src.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let last = max(0, rawLines.count - 1)
        for (n, rawLine) in rawLines.enumerated() {
            let lineEnd = offset + rawLine.utf8.count
            let lineHLs: [TextHighlight] = hls.compactMap { hl in
                let a = max(hl.byteRange.lowerBound, offset)
                let b = min(hl.byteRange.upperBound, lineEnd)
                guard a < b else { return nil }
                var shifted = hl
                shifted.byteRange = (a - offset)..<(b - offset)
                return shifted
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
            let spans = [TextSpan(shown, color: color)]
            let lineNode = applySelect(
                withReveal(tabbedRich(shown, spans: spans, highlights: lineHLs, style: s.codeBlock, color: color))
                    .wFull()
                    .copyBreaks(n == 0 ? 2 : 1, n == last ? 2 : 1)
            )
            var r: El<State> = row().key("l\(n)").wFull().px(s.codeBlockPad[0]).child(lineNode)
            if let tint { r = r.bg(tint) }
            c = c.child(r)
        }
        return c
    }

    private func renderMermaidBlock(_ src: String, source: MarkdownCodeSource?, map: MarkdownSpanMap?, index: Int) -> El<State> {
        let open = source?.open ?? false
        let lines = open ? (utf8Slice(src, range: 0..<min(source?.colouredBytes ?? src.utf8.count, src.utf8.count)) ?? src) : src
        if let diagram: El<State> = KitMermaid.diagram(lines, style: s, streaming: view.config.isStreaming, open: open) {
            let labeled = diagram.key("card")
            let framed = view.diagramFrameHandler?(labeled, MarkdownDiagramFrameContext(index: index, source: lines, open: open)) ?? labeled
            return col().wFull().transition(.none).child(framed)
        }
        if open && view.config.isStreaming && mayDrawMermaid(lines) {
            return col().wFull().transition(.none)
        }
        return col().wFull().child(renderCode(src, source: source, map: map).key("source"))
    }

    private func renderTaskItemBody(
        k: Int,
        n: Int,
        indent: Float,
        item: [MarkdownDocBlock],
        itemBody: El<State>,
        markerOffset: Int,
        checked: Bool
    ) -> El<State> {
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
            .a11yHidden()
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
            .checked(checked)
            .readOnly(!interactive)
            .positionInSet(k + 1, size: n)
            .selected(checked ? "true" : "false")
            .focusable(interactive)
            .wFull()
            .child(control)
            .child(itemBody.grow(1).shrink(1))
        if let onTask = view.onTaskHandler, interactive {
            let bKey = currentBlockKey
            r = r.onClick { state, tx in
                onTask(&state, bKey, markerOffset, !checked, &tx)
            }
        }
        return r
    }

    private func renderTable(
        _ t: MarkdownTableAST,
        pre: MarkdownPreTable?,
        headMaps: [MarkdownSpanMap],
        rowMaps: [[MarkdownSpanMap]]
    ) -> El<State> {
        let n = max(t.align.count, max(t.head.count, 1))
        let settledCount = (t.open && view.config.isStreaming) ? max(0, t.rows.count - 1) : t.rows.count
        let settledRows = Array(t.rows.prefix(settledCount))
        let colWidths = measureTableColumns(t, pre: pre, colCount: n, settledRows: settledRows)
        let total = colWidths.natural.reduce(0, +)

        let ring: Color? = s.tableFrame?.ring ?? s.tableOutline
        let fill: Color? = s.tableFrame?.fill
        let inset: Float = s.tableFrame.map { max(0.5, $0.pad) } ?? (s.tableOutline != nil ? 0.5 : 0)

        let fixedWidths: [Float]? = (s.textWidth.flatMap { view.config.isScrollWide ? $0 : nil }).map { w in
            let avail = max(0, w - flow.inset - 2 * inset)
            return autoLayoutColumns(natural: colWidths.natural, fit: colWidths.fit, avail: avail, fullWidth: s.tableFullWidth)
        }

        var frame: El<State> = col().wFull().p(inset)
        if !view.config.isScrollWide {
            frame = frame.role(.table)
        }
        if !s.tableFullWidth {
            frame = frame.maxW(total + 2 * inset)
        }
        if let fill { frame = frame.rounded(6).bg(fill) }
        if let ring { frame = frame.rounded(6).border(0.5, ring) }

        let headPad = s.tableHeadPad ?? s.tablePad
        let baseTableFont = s.tableFont ?? s.body
        let tableFeatures = s.tableTabular ? "tnum" : baseTableFont.features
        let headFont = TextStyle(size: baseTableFont.size, weight: s.tableHeadWeight ?? s.strongWeight, lineHeight: baseTableFont.lineHeight, family: baseTableFont.family, features: tableFeatures)
        let bodyFont = TextStyle(size: baseTableFont.size, weight: baseTableFont.weight, lineHeight: baseTableFont.lineHeight, letterSpacing: baseTableFont.letterSpacing, italic: baseTableFont.italic, family: baseTableFont.family, features: tableFeatures)
        let tableDir = MarkdownBidi.tableDirection(t)

        func buildHead() -> El<State> {
            renderTableRow(cells: t.head, maps: headMaps, table: t, widths: fixedWidths, natural: colWidths.natural, minWidths: colWidths.min, font: headFont, color: s.tableHeadText, pad: headPad, cellRole: .columnHeader).key("th")
        }

        func buildRow(_ i: Int, _ cells: [MarkdownInline]) -> El<State> {
            let rmap = i < rowMaps.count ? rowMaps[i] : []
            return renderTableRow(cells: cells, maps: rmap, table: t, widths: fixedWidths, natural: colWidths.natural, minWidths: colWidths.min, font: bodyFont, color: s.text, pad: s.tablePad, cellRole: .gridCell).key("r\(i)")
        }

        if let bodyLook = s.tableBody {
            let round = ring != nil || fill != nil
            let r = max(0, 6.0 - inset)
            let headRow: El<State>
            if let digest = settledTableRowDigest(
                cells: t.head, pre: pre?.head, maps: headMaps, align: t.align, tableDir: tableDir,
                natural: colWidths.natural, minWidths: colWidths.min, widths: fixedWidths,
                font: headFont, color: s.tableHeadText, pad: headPad, cellRoleTag: 1, key: "th",
                extraTag: 1, extraBool: round, extraA: r
            ) {
                headRow = cachedSubtree(digest) {
                    Markdown.noteBlockBuild()
                    return buildHead()
                }
            } else {
                headRow = buildHead()
            }
            frame = frame.child(headRow)
            if !t.rows.isEmpty {
                var rowsCol: El<State> = col().key("tbc").wFull()
                for (i, cells) in t.rows.enumerated() {
                    let bordered = i + 1 < t.rows.count
                    let settled = !view.config.isStreaming || !t.open || bordered
                    let rmap = i < rowMaps.count ? rowMaps[i] : []
                    let rpre: MarkdownPreRow? = pre.flatMap { i < $0.rows.count ? $0.rows[i] : nil }
                    let rkey = "r\(i)"
                    func styledRow() -> El<State> {
                        let rowEl = buildRow(i, cells)
                        return bordered ? rowEl.borderSides(bottom: 0.5, color: s.tableRule).borderLayout() : rowEl
                    }
                    let rowEl: El<State>
                    if settled, let digest = settledTableRowDigest(
                        cells: cells, pre: rpre, maps: rmap, align: t.align, tableDir: tableDir,
                        natural: colWidths.natural, minWidths: colWidths.min, widths: fixedWidths,
                        font: bodyFont, color: s.text, pad: s.tablePad, cellRoleTag: 2, key: rkey,
                        extraTag: 2, extraBool: bordered
                    ) {
                        rowEl = cachedSubtree(digest) {
                            Markdown.noteBlockBuild()
                            return styledRow()
                        }
                    } else {
                        rowEl = styledRow()
                    }
                    rowsCol = rowsCol.child(rowEl)
                }
                let card = col().key("tb").wFull().rounded(bodyLook.radius).bg(bodyLook.fill).shadows(bodyLook.shadows).child(rowsCol)
                frame = frame.child(card)
            }
        } else {
            let r = max(0, 6.0 - inset)
            let b = t.rows.isEmpty ? r : 0.0
            let headRow: El<State>
            if let digest = settledTableRowDigest(
                cells: t.head, pre: pre?.head, maps: headMaps, align: t.align, tableDir: tableDir,
                natural: colWidths.natural, minWidths: colWidths.min, widths: fixedWidths,
                font: headFont, color: s.tableHeadText, pad: headPad, cellRoleTag: 1, key: "th",
                extraTag: 3, extraBool: ring != nil, extraA: r, extraB: b
            ) {
                headRow = cachedSubtree(digest) {
                    Markdown.noteBlockBuild()
                    return buildHead().bg(self.s.tableHeadFill)
                }
            } else {
                headRow = buildHead().bg(s.tableHeadFill)
            }
            frame = frame.child(headRow)
            for (i, cells) in t.rows.enumerated() {
                let sepColor = (i == 0 ? s.tableHeadRule : nil) ?? s.tableRule
                frame = frame.child(el().key("s\(i)").wFull().h(0.5).bg(sepColor).a11yHidden())
                let settled = !view.config.isStreaming || !t.open || i + 1 < t.rows.count
                let rmap = i < rowMaps.count ? rowMaps[i] : []
                let rpre: MarkdownPreRow? = pre.flatMap { i < $0.rows.count ? $0.rows[i] : nil }
                let rkey = "r\(i)"
                let rowEl: El<State>
                if settled, let digest = settledTableRowDigest(
                    cells: cells, pre: rpre, maps: rmap, align: t.align, tableDir: tableDir,
                    natural: colWidths.natural, minWidths: colWidths.min, widths: fixedWidths,
                    font: bodyFont, color: s.text, pad: s.tablePad, cellRoleTag: 2, key: rkey,
                    extraTag: 4
                ) {
                    rowEl = cachedSubtree(digest) {
                        Markdown.noteBlockBuild()
                        return buildRow(i, cells)
                    }
                } else {
                    rowEl = buildRow(i, cells)
                }
                frame = frame.child(rowEl)
            }
            if ring == nil {
                frame = frame.child(el().key("s-end").wFull().h(0.5).bg((t.rows.isEmpty ? s.tableHeadRule : nil) ?? s.tableRule).a11yHidden())
            }
        }

        if view.config.isScrollWide {
            if let fixedWidths {
                let wTotal = fixedWidths.reduce(0, +)
                frame = frame.w(wTotal + 2 * inset)
            } else {
                frame = s.tableFullWidth ? frame.maxW(total + 2 * inset) : frame.w(total + 2 * inset)
            }
            return col().role(.table).wFull().child(col().key("scroll").wFull().scrollX().child(frame))
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
        pad: [Float],
        cellRole: ElementRole
    ) -> El<State> {
        let total = natural.reduce(0, +)
        var r: El<State> = row().role(.row).wFull()
        let tableDir = MarkdownBidi.tableDirection(table)
        for j in 0..<natural.count {
            let rawInl = j < cells.count ? cells[j] : MarkdownInline()
            let inl = withCodeLinks(rawInl)
            let m = j < maps.count ? maps[j] : nil
            var align = (s.tableAlign && j < table.align.count) ? table.align[j] : .start
            let bidi = rawInl.bidi
            let dir = bidi.direction
            if let dir, dir != tableDir {
                if align == .start { align = .end }
                else if align == .end { align = .start }
            }
            let spans = buildTextSpans(inl, font: font, baseColor: color)
            let rawContent: El<State> = withReveal(rich(spans).font(font).color(color).textAlign(align.textAlign).wrap(view.config.isScrollWide ? .noWrap : .wrap)).wFull()
            let content = selectInline(bidi.isolate(rawContent).markdownDirection(dir), inl: inl, map: m)
            var cell: El<State> = col().key("c\(j)").role(cellRole)
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

    /// Column widths from the header and every settled row, backed by 128-bit `WIDTHS` and per-row
    /// `ROW_WIDTHS` caches so streaming appends measure only the newly settled row (`O(1)` per row, #1130).
    private func measureTableColumns(
        _ t: MarkdownTableAST,
        pre: MarkdownPreTable?,
        colCount n: Int,
        settledRows: [[MarkdownInline]]
    ) -> MarkdownTableColumns {
        let rawTableFont = s.tableFont ?? s.body
        let tableFeatures = s.tableTabular ? "tnum" : rawTableFont.features
        let baseFont = TextStyle(size: rawTableFont.size, weight: rawTableFont.weight, lineHeight: rawTableFont.lineHeight, letterSpacing: rawTableFont.letterSpacing, italic: rawTableFont.italic, family: rawTableFont.family, features: tableFeatures)
        let headFont = TextStyle(size: baseFont.size, weight: s.tableHeadWeight ?? s.strongWeight, lineHeight: baseFont.lineHeight, family: baseFont.family, features: tableFeatures)
        let epoch = Rune.fontEpoch()
        let headPad = s.tableHeadPad ?? s.tablePad

        let headRKey = tableRowWidthKey(cells: t.head, pre: pre?.head, colCount: n, font: headFont, epoch: epoch)
        var bodyRKeys: [MarkdownDigest128] = []
        bodyRKeys.reserveCapacity(settledRows.count)
        for (i, row) in settledRows.enumerated() {
            let rpre: MarkdownPreRow? = pre.flatMap { i < $0.rows.count ? $0.rows[i] : nil }
            bodyRKeys.append(tableRowWidthKey(cells: row, pre: rpre, colCount: n, font: baseFont, epoch: epoch))
        }

        var kh = MarkdownPairHasher()
        kh.writeInt(n)
        kh.writeDigest(headRKey)
        kh.writeInt(bodyRKeys.count)
        for rk in bodyRKeys { kh.writeDigest(rk) }
        kh.writeFloat(s.tableMinColumn)
        kh.writeInt(s.tablePad.count)
        for p in s.tablePad { kh.writeFloat(p) }
        kh.writeInt(headPad.count)
        for p in headPad { kh.writeFloat(p) }
        kh.writeBool(s.tableFlushLeft)
        let tableKey = kh.finish128()

        let caches = MarkdownTableWidthCaches.shared
        if let hit = caches.widths.get(tableKey),
           hit.natural.count == n && hit.min.count == n && hit.fit.count == n {
            return hit
        }

        func measureRow(_ cells: [MarkdownInline], rkey: MarkdownDigest128, font: TextStyle) -> MarkdownTableRowWidths {
            if let hit = caches.rowWidths.get(rkey),
               hit.natural.count == n && hit.fit.count == n {
                return hit
            }
            Markdown.noteTableRowMeasurement()
            var natural = Array(repeating: Float(0), count: n)
            var fit = Array(repeating: Float(0), count: n)
            for j in 0..<min(n, cells.count) {
                let inl = cells[j]
                if inl.text.isEmpty { continue }
                let spans = buildTextSpans(inl, font: font, baseColor: s.text)
                let (minW, maxW) = TextMeasure.contentWidths(inl.text, spans: spans, style: font)
                let hits = MarkdownTableCodePad.hits(inl)
                let padVal: (Bool) -> Float = { $0 ? self.s.inlineCodePad : 0 }
                natural[j] = maxW + padVal(hits.last) + 0.01
                fit[j] = minW + padVal(hits.word) + 0.01
            }
            let rw = MarkdownTableRowWidths(natural: natural, fit: fit)
            caches.rowWidths.insert(rkey, value: rw, bytes: 8 * n + 48)
            return rw
        }

        func foldRows(_ keys: [MarkdownDigest128], _ rows: [[MarkdownInline]], font: TextStyle) -> ([Float], [Float], [Float]) {
            var natural = Array(repeating: Float(0), count: n)
            var fit = Array(repeating: Float(0), count: n)
            for idx in 0..<min(keys.count, rows.count) {
                let rw = measureRow(rows[idx], rkey: keys[idx], font: font)
                if rw.natural.count == n && rw.fit.count == n {
                    for j in 0..<n {
                        natural[j] = max(natural[j], rw.natural[j])
                        fit[j] = max(fit[j], rw.fit[j])
                    }
                }
            }
            let mins = fit.map { min($0, s.tableMinColumn) }
            return (natural, mins, fit)
        }

        let (hn, hm, hf) = foldRows([headRKey], [t.head], font: headFont)
        let (bn, bm, bf) = foldRows(bodyRKeys, settledRows, font: baseFont)
        let headPadX = headPad[0]
        let bodyPadX = s.tablePad[0]
        let hasBody = !settledRows.isEmpty

        func pad(_ j: Int, _ x: Float) -> Float {
            ((j == 0 && s.tableFlushLeft) ? 0 : x) + x
        }

        var nat: [Float] = []
        var mins: [Float] = []
        var fits: [Float] = []
        nat.reserveCapacity(n)
        mins.reserveCapacity(n)
        fits.reserveCapacity(n)
        for j in 0..<n {
            let hp = pad(j, headPadX)
            let bp = pad(j, bodyPadX)
            nat.append(hasBody ? max(hn[j] + hp, bn[j] + bp) : (hn[j] + hp))
            mins.append(hasBody ? max(hm[j] + hp, bm[j] + bp) : (hm[j] + hp))
            fits.append(hasBody ? max(hf[j] + hp, bf[j] + bp) : (hf[j] + hp))
        }
        let cols = MarkdownTableColumns(natural: nat, min: mins, fit: fits)
        caches.widths.insert(tableKey, value: cols, bytes: 12 * n + 64)
        return cols
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
    if let isBoundary = str.utf8.withContiguousStorageIfAvailable({ buf -> Bool in
        guard byteOffset >= 0 && byteOffset <= buf.count else { return false }
        if byteOffset == 0 || byteOffset == buf.count { return true }
        return (buf[byteOffset] & 0xC0) != 0x80
    }) {
        return isBoundary
    }
    guard byteOffset >= 0 && byteOffset <= str.utf8.count else { return false }
    if byteOffset == 0 || byteOffset == str.utf8.count { return true }
    let idx = str.utf8.index(str.startIndex, offsetBy: byteOffset)
    return idx.samePosition(in: str.unicodeScalars) != nil
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
    static let shells: Set<String> = ["bash", "sh", "shell", "zsh", "fish", "console", "terminal"]
    static let plainLangs: Set<String> = ["text", "txt", "plain", "plaintext"]
}
