import Foundation
import Rune

/// Text direction detected for a Markdown paragraph (`rune_kit::markdown::bidi`).
public enum MarkdownDirection: Sendable, Equatable, Hashable {
    case ltr
    case rtl
}

/// Bidirectional paragraph direction detection (`rune_kit::markdown::bidi`).
public enum MarkdownBidi {
    /// Detects the base paragraph direction from the first strong directional Unicode scalar.
    public static func direction(of text: String) -> MarkdownDirection {
        for scalar in text.unicodeScalars {
            if isStrongRTL(scalar.value) {
                return .rtl
            }
            if isStrongLTR(scalar.value) {
                return .ltr
            }
        }
        return .ltr
    }

    private static func isStrongRTL(_ v: UInt32) -> Bool {
        switch v {
        case 0x0590...0x05FF, // Hebrew
             0x0600...0x06FF, // Arabic
             0x0700...0x074F, // Syriac
             0x0750...0x077F, // Arabic Supplement
             0x0780...0x07BF, // Thaana
             0x07C0...0x07FF, // NKo
             0x0800...0x085F, // Samaritan, Mandaic
             0x08A0...0x08FF, // Arabic Extended-A
             0xFB1D...0xFDFF, // Hebrew/Arabic Presentation Forms-A
             0xFE70...0xFEFF: // Arabic Presentation Forms-B
            return true
        default:
            return false
        }
    }

    private static func isStrongLTR(_ v: UInt32) -> Bool {
        if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) { return true } // ASCII letters
        if (0x00C0...0x02AF).contains(v) { return true } // Latin Extended
        if (0x0370...0x058F).contains(v) { return true } // Greek, Cyrillic, Armenian
        if (0x0900...0x1FFF).contains(v) { return true } // Indic, SE Asian, Georgian, etc.
        if (0x3040...0xD7AF).contains(v) { return true } // CJK, Hangul
        return false
    }
}

/// URL and email autolink scanner (`rune_kit::markdown::autolink`).
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

    /// Scans `text` for bare `http(s)://...`, `mailto:...`, angle-bracketed `<url>`, and email autolinks.
    public static func scan(_ text: String) -> [Match] {
        var matches: [Match] = []
        var idx = text.startIndex

        while idx < text.endIndex {
            let rest = text[idx...]

            // Angle-bracketed autolink `<https://...>` or `<user@host.com>`
            if rest.hasPrefix("<"), let close = text[text.index(after: idx)...].firstIndex(of: ">") {
                let innerStart = text.index(after: idx)
                let inner = String(text[innerStart..<close])
                if !inner.contains(where: \.isWhitespace) {
                    if inner.hasPrefix("https://") || inner.hasPrefix("http://") {
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

            // Bare URL `https://` or `http://`
            if rest.hasPrefix("https://") || rest.hasPrefix("http://") {
                let end = scanURLTokenEnd(in: text, from: idx)
                let raw = String(text[idx..<end])
                let trimmed = trimTrailingPunctuation(raw)
                if trimmed.count > 8 {
                    let trimmedEnd = text.index(idx, offsetBy: trimmed.count)
                    matches.append(Match(range: idx..<trimmedEnd, url: trimmed, display: trimmed, isEmail: false))
                    idx = trimmedEnd
                    continue
                }
            }

            // Bare email `local@domain.tld`
            if isBoundaryBefore(text, at: idx), text[idx].isLetter || text[idx].isNumber {
                let tokenEnd = scanEmailTokenEnd(in: text, from: idx)
                let raw = String(text[idx..<tokenEnd])
                let candidate = trimTrailingPunctuation(raw)
                if isLikelyEmail(candidate) {
                    let trimmedEnd = text.index(idx, offsetBy: candidate.count)
                    matches.append(Match(range: idx..<trimmedEnd, url: "mailto:\(candidate)", display: candidate, isEmail: true))
                    idx = trimmedEnd
                    continue
                }
            }

            idx = text.index(after: idx)
        }
        return matches
    }

    private static func isBoundaryBefore(_ text: String, at idx: String.Index) -> Bool {
        guard idx > text.startIndex else { return true }
        let prev = text[text.index(before: idx)]
        return prev.isWhitespace || prev == "(" || prev == "[" || prev == "\"" || prev == "'"
    }

    private static func scanURLTokenEnd(in text: String, from start: String.Index) -> String.Index {
        var i = start
        while i < text.endIndex, !text[i].isWhitespace && text[i] != "<" && text[i] != ">" {
            i = text.index(after: i)
        }
        return i
    }

    private static func scanEmailTokenEnd(in text: String, from start: String.Index) -> String.Index {
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if c.isLetter || c.isNumber || c == "." || c == "_" || c == "-" || c == "+" || c == "@" {
                i = text.index(after: i)
            } else {
                break
            }
        }
        return i
    }

    private static func trimTrailingPunctuation(_ s: String) -> String {
        var out = s
        while let last = out.last, [".", ",", ";", ":", "!", "?", ")", "]"].contains(last) {
            if last == ")" && out.filter({ $0 == "(" }).count >= out.filter({ $0 == ")" }).count {
                break
            }
            out.removeLast()
        }
        return out
    }

    private static func isLikelyEmail(_ s: String) -> Bool {
        guard let at = s.firstIndex(of: "@") else { return false }
        let local = s[..<at]
        let domain = s[s.index(after: at)...]
        return !local.isEmpty && domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
}

/// Task-list item state for Markdown `- [ ]` / `- [x]` items.
public struct MarkdownTaskItem: Sendable, Equatable {
    public var checked: Bool
    public var text: String

    public init(checked: Bool, text: String) {
        self.checked = checked
        self.text = text
    }
}

/// Parsed Markdown AST block (`rune_kit::markdown`).
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

    /// Parses the stabilized streaming Markdown into blocks.
    public func parseBlocks() -> [MarkdownBlock] {
        MarkdownParser.parse(stabilizedSource)
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
                openFence = "```"
            } else if trimmed.hasPrefix("~~~") {
                openFence = "~~~"
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

        // Repair unclosed inline code backtick on the final line
        if let lastLine = lines.last {
            let tickCount = lastLine.filter { $0 == "`" }.count
            if tickCount % 2 == 1 {
                out.append("`")
            }
        }
        return out
    }
}

/// Streaming-friendly CommonMark + GFM Table + Task List + Footnote + Syntax Highlighting parser and Rune renderer.
public enum MarkdownParser {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            // 1. Fenced code block (``` or ~~~), resilient to unclosed fences
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let langRaw = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let lang = langRaw.isEmpty ? nil : langRaw
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(language: lang, code: codeLines.joined(separator: "\n")))
                continue
            }

            // 2. Thematic break (`---`, `***`, `___`)
            if isThematicBreak(trimmed) {
                blocks.append(.thematicBreak)
                i += 1
                continue
            }

            // 3. ATX Heading (`#` .. `######`)
            if trimmed.hasPrefix("#") {
                var hashes = 0
                for ch in trimmed {
                    if ch == "#" { hashes += 1 } else { break }
                }
                if (1...6).contains(hashes) {
                    let rest = trimmed.dropFirst(hashes)
                    if rest.isEmpty || rest.first == " " {
                        blocks.append(.heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces)))
                        i += 1
                        continue
                    }
                }
            }

            // 4. Footnote definition (`[^id]: text`)
            if let (fnID, fnText) = parseFootnoteDefinition(trimmed) {
                var bodyLines = [fnText]
                i += 1
                while i < lines.count {
                    let nextRaw = lines[i]
                    if nextRaw.hasPrefix("  ") || nextRaw.hasPrefix("\t") {
                        bodyLines.append(nextRaw.trimmingCharacters(in: .whitespaces))
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.footnoteDefinition(id: fnID, text: bodyLines.joined(separator: " ")))
                continue
            }

            // 5. GFM Pipe Table (`| a | b |` followed by `| --- | --- |`)
            if trimmed.contains("|"),
               i + 1 < lines.count,
               isTableDelimiterRow(lines[i + 1]) {
                let headers = splitPipeRow(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let rLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if rLine.isEmpty || !rLine.contains("|") { break }
                    rows.append(splitPipeRow(rLine))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            // 6. Blockquote (`> ...`)
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let ql = lines[i].trimmingCharacters(in: .whitespaces)
                    guard ql.hasPrefix(">") else { break }
                    var content = String(ql.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoteLines.append(content)
                    i += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            // 7. Task list (`- [ ] ...` / `- [x] ...`) or Unordered list (`- `, `* `, `+ `)
            if isUnorderedListItem(trimmed) {
                if parseTaskListItem(trimmed) != nil {
                    var tasks: [MarkdownTaskItem] = []
                    while i < lines.count {
                        let ll = lines[i].trimmingCharacters(in: .whitespaces)
                        guard let item = parseTaskListItem(ll) else { break }
                        tasks.append(item)
                        i += 1
                    }
                    blocks.append(.taskList(tasks))
                    continue
                } else {
                    var items: [String] = []
                    while i < lines.count {
                        let ll = lines[i].trimmingCharacters(in: .whitespaces)
                        guard isUnorderedListItem(ll), parseTaskListItem(ll) == nil else { break }
                        items.append(String(ll.dropFirst(2)))
                        i += 1
                    }
                    blocks.append(.unorderedList(items))
                    continue
                }
            }

            // 8. Ordered list (`1. `, `2. `)
            if isOrderedListItem(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let ll = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isOrderedListItem(ll), let d = ll.firstIndex(of: ".") else { break }
                    let afterSpace = ll.index(d, offsetBy: 2)
                    items.append(String(ll[afterSpace...]))
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            // 9. Paragraph
            var paraLines: [String] = []
            while i < lines.count {
                let pl = lines[i].trimmingCharacters(in: .whitespaces)
                let isTableStart = pl.contains("|") && i + 1 < lines.count && isTableDelimiterRow(lines[i + 1])
                if pl.isEmpty || pl.hasPrefix("#") || pl.hasPrefix("```") || pl.hasPrefix("~~~") ||
                   pl.hasPrefix(">") || isUnorderedListItem(pl) || isOrderedListItem(pl) ||
                   isThematicBreak(pl) || isTableStart || parseFootnoteDefinition(pl) != nil {
                    break
                }
                paraLines.append(pl)
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(paraLines.joined(separator: " ")))
            } else {
                i += 1
            }
        }

        return blocks
    }

    /// Parses inline formatting (`**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, `[label](url)`, `[^fn]`, autolinks) into `TextSpan`s.
    public static func inlineSpans(_ source: String, kit: Kit) -> [TextSpan] {
        inlineSpans(source, kit: kit, searchQuery: nil, activeMatch: nil)
    }

    /// Parses inline formatting with optional search match highlighting (`rune_kit::markdown::find`).
    public static func inlineSpans(
        _ source: String,
        kit: Kit,
        searchQuery: String?,
        activeMatch: Int? = nil
    ) -> [TextSpan] {
        var spans: [TextSpan] = []
        var buffer = ""
        var idx = source.startIndex

        func flushPlain() {
            if !buffer.isEmpty {
                appendAutolinkedPlain(buffer, kit: kit, into: &spans)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        while idx < source.endIndex {
            let rest = source[idx...]

            // Inline code
            if rest.hasPrefix("`") {
                let afterTick = source.index(after: idx)
                if let endTick = source[afterTick...].firstIndex(of: "`") {
                    flushPlain()
                    let codeStr = String(source[afterTick..<endTick])
                    spans.append(TextSpan(codeStr, color: kit.c.textAccent, monospace: true))
                    idx = source.index(after: endTick)
                    continue
                }
            }

            // Bold
            if rest.hasPrefix("**") || rest.hasPrefix("__") {
                let delim = String(rest.prefix(2))
                let afterStars = source.index(idx, offsetBy: 2)
                if let endRange = source[afterStars...].range(of: delim) {
                    flushPlain()
                    let boldStr = String(source[afterStars..<endRange.lowerBound])
                    spans.append(TextSpan(boldStr, color: kit.c.textBase, weight: 700))
                    idx = endRange.upperBound
                    continue
                }
            }

            // Strikethrough
            if rest.hasPrefix("~~") {
                let afterTildes = source.index(idx, offsetBy: 2)
                if let endRange = source[afterTildes...].range(of: "~~") {
                    flushPlain()
                    let strikeStr = String(source[afterTildes..<endRange.lowerBound])
                    spans.append(TextSpan(strikeStr, color: kit.c.textMuted, strikethrough: true))
                    idx = endRange.upperBound
                    continue
                }
            }

            // Italic
            if (rest.hasPrefix("*") && !rest.hasPrefix("**")) || (rest.hasPrefix("_") && !rest.hasPrefix("__")) {
                let delimChar = source[idx]
                let afterStar = source.index(after: idx)
                if let endStar = source[afterStar...].firstIndex(of: delimChar) {
                    flushPlain()
                    let italStr = String(source[afterStar..<endStar])
                    spans.append(TextSpan(italStr, color: kit.c.textBase, italic: true))
                    idx = source.index(after: endStar)
                    continue
                }
            }

            // Footnote reference `[^id]`
            if rest.hasPrefix("[^") {
                let afterPrefix = source.index(idx, offsetBy: 2)
                if let closeBracket = source[afterPrefix...].firstIndex(of: "]") {
                    let fnID = String(source[afterPrefix..<closeBracket])
                    if !fnID.isEmpty && !fnID.contains(where: \.isWhitespace) {
                        flushPlain()
                        spans.append(TextSpan("[\(fnID)]", color: kit.c.textAccent, weight: 600))
                        idx = source.index(after: closeBracket)
                        continue
                    }
                }
            }

            // Markdown link `[label](url)`
            if rest.hasPrefix("[") {
                let afterBracket = source.index(after: idx)
                if let closeBracket = source[afterBracket...].firstIndex(of: "]") {
                    let afterClose = source.index(after: closeBracket)
                    if afterClose < source.endIndex && source[afterClose] == "(",
                       let closeParen = source[afterClose...].firstIndex(of: ")") {
                        flushPlain()
                        let linkLabel = String(source[afterBracket..<closeBracket])
                        spans.append(TextSpan(linkLabel, color: kit.c.textAccent, weight: 500, underline: true))
                        idx = source.index(after: closeParen)
                        continue
                    }
                }
            }

            buffer.append(source[idx])
            idx = source.index(after: idx)
        }
        flushPlain()

        let baseSpans = spans.isEmpty ? [TextSpan(source, color: kit.c.textBase)] : spans
        guard let searchQuery, !searchQuery.isEmpty else {
            return baseSpans
        }
        return applySearchHighlight(to: baseSpans, query: searchQuery, activeMatch: activeMatch, kit: kit)
    }

    /// Lightweight token syntax highlighter for code blocks.
    public static func highlightCode(_ code: String, kit: Kit) -> [TextSpan] {
        highlightCode(code, language: nil, kit: kit)
    }

    /// Language-aware token syntax highlighter powered by `RuneHighlights` when the language is known.
    public static func highlightCode(_ code: String, language: String?, kit: Kit) -> [TextSpan] {
        if let language, Syntax.known(language) {
            let highlights = SyntaxHighlighter.builtin.highlight(language: language, code: code)
            let theme = SyntaxTheme.fromKit(kit)
            let spans = theme.spans(for: code, highlights: highlights, defaultColor: kit.c.textBase, monospace: true)
            if !spans.isEmpty {
                return spans
            }
        }
        return [TextSpan(code, color: kit.c.textBase, monospace: true)]
    }

    /// Finds case-insensitive substring match ranges in Markdown source (`rune_kit::markdown::find`).
    public static func findMatches(in source: String, query: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = source.startIndex
        while searchStart < source.endIndex,
              let range = source.range(of: query, options: .caseInsensitive, range: searchStart..<source.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }

    // MARK: - Private Helpers

    private static func appendAutolinkedPlain(_ plain: String, kit: Kit, into spans: inout [TextSpan]) {
        let links = MarkdownAutolink.scan(plain)
        guard !links.isEmpty else {
            spans.append(TextSpan(plain, color: kit.c.textBase))
            return
        }
        var cursor = plain.startIndex
        for link in links {
            if link.range.lowerBound > cursor {
                spans.append(TextSpan(String(plain[cursor..<link.range.lowerBound]), color: kit.c.textBase))
            }
            spans.append(TextSpan(link.display, color: kit.c.textAccent, underline: true))
            cursor = link.range.upperBound
        }
        if cursor < plain.endIndex {
            spans.append(TextSpan(String(plain[cursor...]), color: kit.c.textBase))
        }
    }

    private static func applySearchHighlight(
        to spans: [TextSpan],
        query: String,
        activeMatch: Int?,
        kit: Kit
    ) -> [TextSpan] {
        var result: [TextSpan] = []
        var matchCounter = 0
        let normalBg = kit.c.warning.bg.alpha(0.65)
        let activeBg = kit.c.warning.border

        for span in spans {
            let matches = findMatches(in: span.text, query: query)
            if matches.isEmpty {
                result.append(span)
                continue
            }
            var cursor = span.text.startIndex
            for match in matches {
                if match.lowerBound > cursor {
                    var prefix = span
                    prefix.text = String(span.text[cursor..<match.lowerBound])
                    result.append(prefix)
                }
                var highlighted = span
                highlighted.text = String(span.text[match])
                highlighted.background = (activeMatch == matchCounter) ? activeBg : normalBg
                result.append(highlighted)
                matchCounter += 1
                cursor = match.upperBound
            }
            if cursor < span.text.endIndex {
                var suffix = span
                suffix.text = String(span.text[cursor...])
                result.append(suffix)
            }
        }
        return result
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        return (trimmed.allSatisfy({ $0 == "-" || $0 == " " }) && trimmed.filter({ $0 == "-" }).count >= 3) ||
               (trimmed.allSatisfy({ $0 == "*" || $0 == " " }) && trimmed.filter({ $0 == "*" }).count >= 3) ||
               (trimmed.allSatisfy({ $0 == "_" || $0 == " " }) && trimmed.filter({ $0 == "_" }).count >= 3)
    }

    private static func isUnorderedListItem(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
    }

    private static func isOrderedListItem(_ trimmed: String) -> Bool {
        guard let d = trimmed.firstIndex(of: "."),
              !trimmed[..<d].isEmpty,
              trimmed[..<d].allSatisfy(\.isNumber),
              trimmed.index(after: d) < trimmed.endIndex else { return false }
        return trimmed[trimmed.index(after: d)] == " "
    }

    private static func parseTaskListItem(_ trimmed: String) -> MarkdownTaskItem? {
        guard isUnorderedListItem(trimmed) else { return nil }
        let afterBullet = trimmed.dropFirst(2)
        if afterBullet.hasPrefix("[ ] ") {
            return MarkdownTaskItem(checked: false, text: String(afterBullet.dropFirst(4)))
        }
        if afterBullet.hasPrefix("[x] ") || afterBullet.hasPrefix("[X] ") {
            return MarkdownTaskItem(checked: true, text: String(afterBullet.dropFirst(4)))
        }
        if afterBullet == "[ ]" {
            return MarkdownTaskItem(checked: false, text: "")
        }
        if afterBullet == "[x]" || afterBullet == "[X]" {
            return MarkdownTaskItem(checked: true, text: "")
        }
        return nil
    }

    private static func parseFootnoteDefinition(_ trimmed: String) -> (String, String)? {
        guard trimmed.hasPrefix("[^"),
              let close = trimmed.firstIndex(of: "]") else { return nil }
        let afterClose = trimmed.index(after: close)
        guard afterClose < trimmed.endIndex, trimmed[afterClose] == ":" else { return nil }
        let id = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close])
        guard !id.isEmpty, !id.contains(where: \.isWhitespace) else { return nil }
        let body = String(trimmed[trimmed.index(after: afterClose)...]).trimmingCharacters(in: .whitespaces)
        return (id, body)
    }

    private static func splitPipeRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableDelimiterRow(_ line: String) -> Bool {
        let cells = splitPipeRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
    }
}

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
        let normalized = streaming ? MarkdownStream.stabilize(source) : source
        let blocks = MarkdownParser.parse(normalized)
        var doc: El<State> = col().key(key).wFull().gap(12)

        for (idx, block) in blocks.enumerated() {
            doc = doc.child(
                renderMarkdownBlock(
                    block,
                    idx: idx,
                    key: key,
                    searchQuery: searchQuery,
                    activeMatch: activeMatch
                )
            )
        }
        return doc
    }

    @inline(never)
    private func renderMarkdownBlock<State>(
        _ block: MarkdownBlock,
        idx: Int,
        key: String,
        searchQuery: String?,
        activeMatch: Int?
    ) -> El<State> {
        switch block {
        case let .heading(level, headingText):
            let sizes: [Float] = [22, 18, 16, 14, 13, 12]
            let sz = sizes[min(max(level - 1, 0), sizes.count - 1)]
            return rich(MarkdownParser.inlineSpans(headingText, kit: self, searchQuery: searchQuery, activeMatch: activeMatch))
                .key("\(key)-h-\(idx)")
                .headingLevel(level)
                .size(sz)
                .semibold()
                .lineHeight(sz * 1.3)
                .wFull()

        case .paragraph(let para):
            let dir = MarkdownBidi.direction(of: para)
            var pEl: El<State> = rich(MarkdownParser.inlineSpans(para, kit: self, searchQuery: searchQuery, activeMatch: activeMatch))
                .key("\(key)-p-\(idx)")
                .font(ty.body)
                .wFull()
            if dir == .rtl {
                pEl = pEl.textAlign(.trailing)
            }
            return pEl

        case let .codeBlock(lang, code):
            return renderMarkdownCodeBlock(lang: lang, code: code, idx: idx, key: key)

        case .blockquote(let quote):
            return row()
                .key("\(key)-q-\(idx)")
                .wFull()
                .pl(12)
                .py(4)
                .borderSides(left: 3.0, color: c.borderStrong)
                .child(rich(MarkdownParser.inlineSpans(quote, kit: self, searchQuery: searchQuery, activeMatch: activeMatch)).font(ty.body).italic().color(c.textMuted).wFull())

        case .unorderedList(let items):
            var listEl: El<State> = col().key("\(key)-ul-\(idx)").wFull().gap(6)
            for item in items {
                listEl = listEl.child(
                    row()
                        .wFull()
                        .gap(8)
                        .itemsStart()
                        .child(text("•").font(ty.bodyMedium).color(c.textMuted))
                        .child(rich(MarkdownParser.inlineSpans(item, kit: self, searchQuery: searchQuery, activeMatch: activeMatch)).font(ty.body).grow(1).minW(0))
                )
            }
            return listEl

        case .orderedList(let items):
            var listEl: El<State> = col().key("\(key)-ol-\(idx)").wFull().gap(6)
            for (numIdx, item) in items.enumerated() {
                listEl = listEl.child(
                    row()
                        .wFull()
                        .gap(8)
                        .itemsStart()
                        .child(text("\(numIdx + 1).").font(ty.bodyMedium).color(c.textMuted).minW(18))
                        .child(rich(MarkdownParser.inlineSpans(item, kit: self, searchQuery: searchQuery, activeMatch: activeMatch)).font(ty.body).grow(1).minW(0))
                )
            }
            return listEl

        case .taskList(let tasks):
            return renderMarkdownTaskList(tasks, idx: idx, key: key, searchQuery: searchQuery, activeMatch: activeMatch)

        case let .table(headers, rows):
            let cols: [TableColumn<[String]>] = headers.enumerated().map { colIdx, h in
                TableColumn(title: h) { r in
                    colIdx < r.count ? r[colIdx] : ""
                }
            }
            return table(key: "\(key)-tbl-\(idx)", columns: cols, rows: rows)

        case let .footnoteDefinition(fnID, fnText):
            return row()
                .key("\(key)-fn-\(idx)")
                .wFull()
                .gap(8)
                .itemsStart()
                .child(text("[\(fnID)]").font(ty.smallMedium).color(c.textAccent))
                .child(rich(MarkdownParser.inlineSpans(fnText, kit: self, searchQuery: searchQuery, activeMatch: activeMatch)).font(ty.small).color(c.textMuted).grow(1).minW(0))

        case .thematicBreak:
            return divider()
        }
    }

    @inline(never)
    private func renderMarkdownCodeBlock<State>(
        lang: String?,
        code: String,
        idx: Int,
        key: String
    ) -> El<State> {
        if lang?.lowercased() == "mermaid",
           let diagram: El<State> = mermaid(code) {
            return diagram.key("\(key)-mermaid-\(idx)")
        }
        var box: El<State> = col()
            .key("\(key)-code-\(idx)")
            .wFull()
            .rounded(radius.lg)
            .bg(c.layer02)
            .border(1.0, c.borderMuted)
            .clip(true)

        if let lang, !lang.isEmpty {
            box = box.child(
                row()
                    .wFull()
                    .px(12)
                    .py(6)
                    .bg(c.layer01)
                    .borderSides(bottom: 1.0, color: c.borderMuted)
                    .child(text(lang).font(ty.smallMedium).color(c.textFaint))
            )
        }
        return box.child(
            row()
                .wFull()
                .p(12)
                .child(rich(MarkdownParser.highlightCode(code, language: lang, kit: self)).font(ty.mono).wFull())
        )
    }

    @inline(never)
    private func renderMarkdownTaskList<State>(
        _ tasks: [MarkdownTaskItem],
        idx: Int,
        key: String,
        searchQuery: String?,
        activeMatch: Int?
    ) -> El<State> {
        var listEl: El<State> = col().key("\(key)-tl-\(idx)").wFull().gap(6)
        for (tIdx, item) in tasks.enumerated() {
            let boxEl: El<State> = el()
                .key("\(key)-tl-\(idx)-\(tIdx)-box")
                .size(16)
                .mt(2)
                .rounded(radius.xs)
                .bg(item.checked ? c.bgAccent : c.surfaceBase)
                .border(1.0, item.checked ? c.bgAccent : c.borderBase)
                .center()
                .child(
                    item.checked
                        ? icon(KitIcons.checkSmall, size: 11).color(c.textContrast)
                        : el()
                )
            listEl = listEl.child(
                row()
                    .wFull()
                    .gap(8)
                    .itemsStart()
                    .child(boxEl)
                    .child(rich(MarkdownParser.inlineSpans(item.text, kit: self, searchQuery: searchQuery, activeMatch: activeMatch)).font(ty.body).color(item.checked ? c.textMuted : c.textBase).grow(1).minW(0))
            )
        }
        return listEl
    }
}
