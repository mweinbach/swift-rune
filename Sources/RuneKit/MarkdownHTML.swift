/// CommonMark raw HTML events. Rune ignores their contents while retaining source offsets.
enum MarkdownHTML {
    enum BlockEnd {
        case blankLine
        case marker(String)
    }

    private static let namedBlocks: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption",
        "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1",
        "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend",
        "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup",
        "option", "p", "param", "search", "section", "summary", "table", "tbody", "td",
        "tfoot", "th", "thead", "title", "tr", "track", "ul",
    ]

    static func blockStart(in line: String, interruptsParagraph: Bool = false) -> BlockEnd? {
        let text = line.utf8.drop(while: { $0 == 32 })
        guard text.first == 60, line.utf8.distance(from: line.utf8.startIndex, to: text.startIndex) <= 3 else { return nil }
        let bytes = Array(text)[...]
        let body = bytes.dropFirst()
        if body.starts(with: "!--".utf8) { return .marker("-->") }
        if body.first == 63 { return .marker("?>") }
        if body.starts(with: "![CDATA[".utf8) { return .marker("]]>") }
        if body.first == 33, let next = body.dropFirst().first, isLetter(next) { return .marker(">") }
        let closing = body.first == 47
        let nameBytes = (closing ? body.dropFirst() : body).prefix(while: { isLetter($0) || isDigit($0) })
        guard !nameBytes.isEmpty else { return nil }
        let name = String(decoding: nameBytes, as: UTF8.self).lowercased()
        let rest = bytes[nameBytes.endIndex...]
        if !closing, ["pre", "style", "script", "textarea"].contains(name),
           rest.first.map({ isSpace($0) || $0 == 62 }) ?? true {
            return .marker("</" + name + ">")
        }
        if namedBlocks.contains(name), rest.isEmpty || rest.first == 32 || rest.first == 9
            || rest.first == 62 || rest.starts(with: "/>".utf8) { return .blankLine }
        if !interruptsParagraph, let end = tagEnd(bytes), bytes[end...].allSatisfy(isSpace) { return .blankLine }
        return nil
    }

    /// CommonMark gives an explicit URI or email autolink priority over an HTML tag.
    static func autolinkEnd(_ bytes: ArraySlice<UInt8>) -> Int? {
        let body = bytes.dropFirst()
        let value = body.prefix(while: { $0 > 32 && $0 != 60 && $0 != 62 })
        guard !value.isEmpty, bytes[value.endIndex...].first == 62 else { return nil }
        if let colon = value.firstIndex(of: 58), (2...32).contains(colon - value.startIndex),
           isLetter(value[value.startIndex]),
           value[..<colon].allSatisfy({ isLetter($0) || isDigit($0) || $0 == 43 || $0 == 45 || $0 == 46 }) {
            return value.endIndex + 1
        }
        guard let at = value.firstIndex(of: 64), at > value.startIndex else { return nil }
        let localSymbols = ".!#$%&'*+/=?^_`{|}~-".utf8
        guard value[..<at].allSatisfy({ isLetter($0) || isDigit($0) || localSymbols.contains($0) }) else { return nil }
        let labels = value[(at + 1)...].split(separator: 46, omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != 45 && $0.last != 45
            && $0.allSatisfy({ isLetter($0) || isDigit($0) || $0 == 45 }) }) else { return nil }
        return value.endIndex + 1
    }

    /// Index just after the event. Incomplete or malformed tags remain ordinary Markdown.
    static func inlineEnd(_ bytes: ArraySlice<UInt8>) -> Int? {
        let body = bytes.dropFirst()
        if body.first == 63 { return end(of: "?>", in: body.dropFirst()) }
        guard body.first == 33 else { return tagEnd(bytes) }
        let rest = body.dropFirst()
        if rest.starts(with: "--".utf8) { return end(of: "-->", in: rest) }
        if rest.starts(with: "[CDATA[".utf8) {
            // pulldown-cmark accepts the first run of right brackets followed by '>'.
            let brackets = rest.drop(while: { $0 != 93 })
            let after = brackets.drop(while: { $0 == 93 })
            return after.first == 62 ? after.startIndex + 1 : nil
        }
        if let first = rest.first, isLetter(first) { return rest.firstIndex(of: 62).map { $0 + 1 } }
        return nil
    }

    private static func tagEnd(_ bytes: ArraySlice<UInt8>) -> Int? {
        var rest = bytes.dropFirst()
        let closing = rest.first == 47
        if closing { rest = rest.dropFirst() }
        guard let first = rest.first, isLetter(first) else { return nil }
        rest = rest.drop(while: { isLetter($0) || isDigit($0) || $0 == 45 })
        if closing {
            rest = rest.drop(while: isSpace)
            return rest.first == 62 ? rest.startIndex + 1 : nil
        }
        while !rest.isEmpty {
            let afterSpace = rest.drop(while: isSpace)
            if afterSpace.first == 62 { return afterSpace.startIndex + 1 }
            if afterSpace.starts(with: "/>".utf8) { return afterSpace.startIndex + 2 }
            guard afterSpace.startIndex > rest.startIndex, let first = afterSpace.first,
                  isLetter(first) || first == 58 || first == 95 else { return nil }
            rest = afterSpace.drop(while: { isLetter($0) || isDigit($0) || $0 == 58 || $0 == 95 || $0 == 45 || $0 == 46 })
            let assignment = rest.drop(while: isSpace)
            if assignment.first == 61 {
                let value = assignment.dropFirst().drop(while: isSpace)
                guard let lead = value.first else { return nil }
                if lead == 39 || lead == 34 {
                    guard let quote = value.dropFirst().firstIndex(of: lead) else { return nil }
                    rest = bytes[(quote + 1)...]
                } else {
                    rest = value.drop(while: { !isSpace($0) && $0 != 34 && $0 != 39 && $0 != 61 && $0 != 60 && $0 != 62 && $0 != 96 })
                    if rest.startIndex == value.startIndex { return nil }
                }
            }
        }
        return nil
    }

    private static func end(of marker: String, in bytes: ArraySlice<UInt8>) -> Int? {
        let needle = marker.utf8
        for i in bytes.indices where bytes[i] == needle.first && bytes[i...].starts(with: needle) {
            return i + needle.count
        }
        return nil
    }

    private static func isLetter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) }
    private static func isDigit(_ b: UInt8) -> Bool { (48...57).contains(b) }
    private static func isSpace(_ b: UInt8) -> Bool { b == 32 || (9...13).contains(b) }
}
