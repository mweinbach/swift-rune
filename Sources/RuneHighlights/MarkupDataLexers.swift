import Foundation

enum MarkupDataLexers {
    // MARK: - JSON / JSON5 / JSONL
    static func lexJSON(_ scanner: inout LexerScanner, allowComments: Bool) {
        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard let b = scanner.peek() else { break }

            if allowComments && scanner.startsWith("//") {
                scanner.scanLineComment()
                continue
            }
            if allowComments && scanner.startsWith("/*") {
                scanner.scanBlockComment()
                continue
            }
            if b == 0x22 /* " */ {
                let startSpanCount = scanner.spans.count
                scanner.scanQuotedString(quote: 0x22, allowEscapes: true)
                if scanner.nextNonWhitespaceByte(from: scanner.index) == 0x3A /* : */ {
                    for i in startSpanCount..<scanner.spans.count where scanner.spans[i].token.kind == .string {
                        scanner.spans[i].token = HighlightToken(.propertyJSONKey)
                    }
                }
                continue
            }
            if allowComments && b == 0x27 /* ' */ {
                scanner.scanQuotedString(quote: 0x27, allowEscapes: true)
                continue
            }
            if LexerScanner.isDigit(b) || (b == 0x2D && scanner.peek(1).map(LexerScanner.isDigit) == true) {
                if b == 0x2D { scanner.advance(1) }
                let numStart = b == 0x2D ? scanner.index - 1 : scanner.index
                scanner.scanNumber()
                if b == 0x2D, let lastIdx = scanner.spans.indices.last {
                    scanner.spans[lastIdx].utf8Range = numStart..<scanner.spans[lastIdx].utf8Range.upperBound
                }
                continue
            }
            if LexerScanner.isIdentStart(b) {
                let range = scanner.scanIdentifierRange()
                let word = scanner.string(for: range)
                if word == "true" || word == "false" {
                    scanner.emit(range, .boolean)
                } else if word == "null" {
                    scanner.emit(range, .constantBuiltin)
                } else if allowComments && scanner.nextNonWhitespaceByte(from: scanner.index) == 0x3A {
                    scanner.emit(range, .propertyJSONKey)
                }
                continue
            }
            let start = scanner.index
            switch b {
            case 0x7B, 0x7D, 0x5B, 0x5D:
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationBracket)
            case 0x3A, 0x2C:
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationDelimiter)
            default:
                scanner.advanceScalar()
            }
        }
    }

    // MARK: - TOML
    static func lexTOML(_ scanner: inout LexerScanner) {
        var afterEquals = false
        while !scanner.isAtEnd {
            scanner.skipHorizontalWhitespace()
            guard let b = scanner.peek() else { break }

            if b == 0x0A || b == 0x0D {
                scanner.advance(1)
                afterEquals = false
                continue
            }
            if b == 0x23 /* # */ {
                scanner.scanLineComment()
                continue
            }
            if !afterEquals && b == 0x5B /* [ */ {
                let start = scanner.index
                while let cur = scanner.peek(), cur != 0x5D && cur != 0x0A {
                    scanner.advanceScalar()
                }
                while scanner.peek() == 0x5D { scanner.advance(1) }
                scanner.emit(start..<scanner.index, .title)
                continue
            }
            if scanner.startsWith("\"\"\"") {
                scanner.scanTripleQuotedString(quote: 0x22, allowEscapes: true)
                continue
            }
            if scanner.startsWith("'''") {
                scanner.scanTripleQuotedString(quote: 0x27, allowEscapes: false)
                continue
            }
            if b == 0x22 || b == 0x27 {
                let beforeCount = scanner.spans.count
                scanner.scanQuotedString(quote: b, allowEscapes: b == 0x22)
                if !afterEquals {
                    for i in beforeCount..<scanner.spans.count where scanner.spans[i].token.kind == .string {
                        scanner.spans[i].token = HighlightToken(.property)
                    }
                }
                continue
            }
            if b == 0x3D /* = */ {
                let start = scanner.index
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .operator)
                afterEquals = true
                continue
            }
            if afterEquals && (LexerScanner.isDigit(b) || ((b == 0x2B || b == 0x2D) && scanner.peek(1).map(LexerScanner.isDigit) == true)) {
                if b == 0x2B || b == 0x2D { scanner.advance(1) }
                scanner.scanNumber()
                continue
            }
            if LexerScanner.isIdentStart(b) || LexerScanner.isDigit(b) {
                let range = scanner.scanIdentifierRange()
                let word = scanner.string(for: range)
                if !afterEquals {
                    scanner.emit(range, .property)
                } else if word == "true" || word == "false" {
                    scanner.emit(range, .boolean)
                }
                continue
            }
            let start = scanner.index
            if b == 0x5B || b == 0x5D || b == 0x7B || b == 0x7D {
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationBracket)
            } else if b == 0x2C || b == 0x2E {
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationDelimiter)
            } else {
                scanner.advanceScalar()
            }
        }
    }

    // MARK: - YAML
    static func lexYAML(_ scanner: inout LexerScanner) {
        while !scanner.isAtEnd {
            let lineStart = scanner.index
            scanner.skipHorizontalWhitespace()
            guard let b = scanner.peek() else { break }

            if b == 0x0A || b == 0x0D {
                scanner.advance(1)
                continue
            }
            if b == 0x23 /* # */ {
                scanner.scanLineComment()
                continue
            }
            if scanner.index == lineStart && (scanner.startsWith("---") || scanner.startsWith("...")) {
                let start = scanner.index
                scanner.advance(3)
                scanner.emit(start..<scanner.index, .punctuationSpecial)
                continue
            }
            if b == 0x2D /* - */ && (scanner.peek(1) == 0x20 || scanner.peek(1) == 0x0A || scanner.peek(1) == nil) {
                let start = scanner.index
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationListMarker)
                continue
            }
            if b == 0x26 || b == 0x2A /* &anchor / *alias */ {
                let start = scanner.index
                scanner.advance(1)
                _ = scanner.scanIdentifierRange()
                scanner.emit(start..<scanner.index, .label)
                continue
            }
            if b == 0x22 || b == 0x27 {
                let beforeCount = scanner.spans.count
                scanner.scanQuotedString(quote: b, allowEscapes: b == 0x22)
                if scanner.peek() == 0x3A {
                    for i in beforeCount..<scanner.spans.count where scanner.spans[i].token.kind == .string {
                        scanner.spans[i].token = HighlightToken(.property)
                    }
                }
                continue
            }
            // Key detection: `key:`
            if LexerScanner.isIdentStart(b) || LexerScanner.isDigit(b) {
                let start = scanner.index
                while let c = scanner.peek(), c != 0x3A && c != 0x0A && c != 0x0D && c != 0x23 {
                    if c == 0x20 || c == 0x09 { break }
                    scanner.advanceScalar()
                }
                let wordRange = start..<scanner.index
                let word = scanner.string(for: wordRange)
                if scanner.peek() == 0x3A && (scanner.peek(1) == 0x20 || scanner.peek(1) == 0x0A || scanner.peek(1) == 0x0D || scanner.peek(1) == nil) {
                    scanner.emit(wordRange, .property)
                    let colonStart = scanner.index
                    scanner.advance(1)
                    scanner.emit(colonStart..<scanner.index, .punctuationDelimiter)
                } else if word == "true" || word == "false" || word == "yes" || word == "no" {
                    scanner.emit(wordRange, .boolean)
                } else if word == "null" || word == "~" {
                    scanner.emit(wordRange, .constantBuiltin)
                } else if Double(word) != nil {
                    scanner.emit(wordRange, .number)
                }
                continue
            }
            let start = scanner.index
            if b == 0x5B || b == 0x5D || b == 0x7B || b == 0x7D {
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationBracket)
            } else if b == 0x3A || b == 0x2C {
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationDelimiter)
            } else {
                scanner.advanceScalar()
            }
        }
    }

    // MARK: - Markdown / MDX
    static func lexMarkdown(_ scanner: inout LexerScanner) {
        var inFence = false
        var fenceLen = 0
        var fenceChar: UInt8 = 0x60

        while !scanner.isAtEnd {
            let lineStart = scanner.index
            var lineEnd = lineStart
            while lineEnd < scanner.bytes.count && scanner.bytes[lineEnd] != 0x0A {
                lineEnd += 1
            }

            // Check fenced code block
            var trimmed = lineStart
            while trimmed < lineEnd && (scanner.bytes[trimmed] == 0x20 || scanner.bytes[trimmed] == 0x09) {
                trimmed += 1
            }
            if trimmed < lineEnd && (scanner.bytes[trimmed] == 0x60 || scanner.bytes[trimmed] == 0x7E) {
                let ch = scanner.bytes[trimmed]
                var count = 0
                while trimmed + count < lineEnd && scanner.bytes[trimmed + count] == ch {
                    count += 1
                }
                if count >= 3 {
                    scanner.emit(trimmed..<lineEnd, .punctuationMarkup)
                    if !inFence {
                        inFence = true
                        fenceLen = count
                        fenceChar = ch
                    } else if ch == fenceChar && count >= fenceLen {
                        inFence = false
                    }
                    scanner.index = lineEnd < scanner.bytes.count ? lineEnd + 1 : lineEnd
                    continue
                }
            }

            if inFence {
                scanner.emit(lineStart..<lineEnd, .textLiteral)
                scanner.index = lineEnd < scanner.bytes.count ? lineEnd + 1 : lineEnd
                continue
            }

            // ATX Headings: # ...
            if trimmed < lineEnd && scanner.bytes[trimmed] == 0x23 {
                var hashes = 0
                while trimmed + hashes < lineEnd && scanner.bytes[trimmed + hashes] == 0x23 {
                    hashes += 1
                }
                if hashes <= 6 && (trimmed + hashes == lineEnd || scanner.bytes[trimmed + hashes] == 0x20) {
                    scanner.emit(trimmed..<(trimmed + hashes), .punctuationMarkup)
                    if trimmed + hashes < lineEnd {
                        scanner.emit((trimmed + hashes)..<lineEnd, .title)
                    }
                    scanner.index = lineEnd < scanner.bytes.count ? lineEnd + 1 : lineEnd
                    continue
                }
            }

            // Blockquote: >
            if trimmed < lineEnd && scanner.bytes[trimmed] == 0x3E /* > */ {
                scanner.emit(trimmed..<(trimmed + 1), .punctuationMarkup)
                scanner.index = trimmed + 1
            } else if trimmed + 1 < lineEnd
                        && (scanner.bytes[trimmed] == 0x2D || scanner.bytes[trimmed] == 0x2A || scanner.bytes[trimmed] == 0x2B)
                        && scanner.bytes[trimmed + 1] == 0x20 {
                scanner.emit(trimmed..<(trimmed + 1), .punctuationListMarker)
                scanner.index = trimmed + 2
            } else {
                scanner.index = lineStart
            }

            // Inline scanning up to lineEnd
            while scanner.index < lineEnd {
                let b = scanner.bytes[scanner.index]
                if b == 0x60 /* ` */ {
                    let start = scanner.index
                    scanner.advance(1)
                    while scanner.index < lineEnd && scanner.bytes[scanner.index] != 0x60 {
                        scanner.advanceScalar()
                    }
                    if scanner.index < lineEnd && scanner.bytes[scanner.index] == 0x60 {
                        scanner.advance(1)
                    }
                    scanner.emit(start..<scanner.index, .textLiteral)
                    continue
                }
                if b == 0x2A /* * */ && scanner.index + 1 < lineEnd && scanner.bytes[scanner.index + 1] == 0x2A {
                    let start = scanner.index
                    scanner.advance(2)
                    while scanner.index + 1 < lineEnd && !(scanner.bytes[scanner.index] == 0x2A && scanner.bytes[scanner.index + 1] == 0x2A) {
                        scanner.advanceScalar()
                    }
                    if scanner.index + 1 < lineEnd { scanner.advance(2) }
                    scanner.emit(start..<scanner.index, .emphasisStrong)
                    continue
                }
                if b == 0x2A /* * */ || b == 0x5F /* _ */ {
                    let marker = b
                    let start = scanner.index
                    scanner.advance(1)
                    var end = scanner.index
                    while end < lineEnd && scanner.bytes[end] != marker {
                        end += 1
                    }
                    if end < lineEnd && end > start + 1 {
                        scanner.index = end + 1
                        scanner.emit(start..<scanner.index, .emphasis)
                        continue
                    }
                    continue
                }
                if b == 0x5B /* [link](url) */ {
                    let start = scanner.index
                    var closeBracket = start + 1
                    while closeBracket < lineEnd && scanner.bytes[closeBracket] != 0x5D {
                        closeBracket += 1
                    }
                    if closeBracket + 1 < lineEnd && scanner.bytes[closeBracket] == 0x5D && scanner.bytes[closeBracket + 1] == 0x28 {
                        var closeParen = closeBracket + 2
                        while closeParen < lineEnd && scanner.bytes[closeParen] != 0x29 {
                            closeParen += 1
                        }
                        if closeParen < lineEnd && scanner.bytes[closeParen] == 0x29 {
                            scanner.emit(start..<(closeBracket + 1), .linkText)
                            scanner.emit((closeBracket + 2)..<closeParen, .linkURI)
                            scanner.index = closeParen + 1
                            continue
                        }
                    }
                }
                scanner.advanceScalar()
            }
            if scanner.index < scanner.bytes.count && scanner.bytes[scanner.index] == 0x0A {
                scanner.advance(1)
            }
        }
    }

    // MARK: - Bash / Shell
    static func lexBash(_ scanner: inout LexerScanner) {
        let keywords: Set<String> = [
            "if", "then", "elif", "else", "fi", "case", "esac", "for", "select",
            "while", "until", "do", "done", "in", "function", "time", "coproc",
            "local", "export", "readonly", "declare", "typeset", "unset",
            "return", "exit", "break", "continue", "source", "eval", "exec",
        ]
        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard let b = scanner.peek() else { break }

            if b == 0x23 /* # */ {
                let isShebang = scanner.startsWith("#!")
                let start = scanner.index
                scanner.advanceToLineEnd()
                scanner.emit(start..<scanner.index, isShebang ? .preproc : .comment)
                continue
            }
            if b == 0x22 || b == 0x27 {
                scanner.scanQuotedString(quote: b, allowEscapes: b == 0x22, multiline: true)
                continue
            }
            if b == 0x24 /* $ */ {
                let start = scanner.index
                scanner.advance(1)
                if scanner.peek() == 0x7B /* { */ {
                    scanner.advance(1)
                    while !scanner.isAtEnd && scanner.peek() != 0x7D && scanner.peek() != 0x0A {
                        scanner.advanceScalar()
                    }
                    if scanner.peek() == 0x7D { scanner.advance(1) }
                } else if scanner.peek() == 0x28 /* ( */ {
                    scanner.advance(1)
                } else {
                    _ = scanner.scanIdentifierRange()
                }
                scanner.emit(start..<scanner.index, .variableSpecial)
                continue
            }
            if LexerScanner.isDigit(b) {
                scanner.scanNumber()
                continue
            }
            if LexerScanner.isIdentStart(b) {
                let range = scanner.scanIdentifierRange()
                let word = scanner.string(for: range)
                if keywords.contains(word) {
                    scanner.emit(range, .keywordControl)
                } else if word == "true" || word == "false" {
                    scanner.emit(range, .boolean)
                }
                continue
            }
            let start = scanner.index
            if b == 0x7C || b == 0x26 || b == 0x3E || b == 0x3C || b == 0x3D {
                scanner.advance(1)
                if scanner.peek() == b { scanner.advance(1) }
                scanner.emit(start..<scanner.index, .operator)
            } else if b == 0x3B {
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationDelimiter)
            } else {
                scanner.advanceScalar()
            }
        }
    }

    // MARK: - HTML / XML / SVG
    static func lexHTML(_ scanner: inout LexerScanner) {
        while !scanner.isAtEnd {
            guard let b = scanner.peek() else { break }
            if scanner.startsWith("<!--") {
                let start = scanner.index
                scanner.advance(4)
                while !scanner.isAtEnd && !scanner.startsWith("-->") {
                    scanner.advanceScalar()
                }
                if scanner.startsWith("-->") { scanner.advance(3) }
                scanner.emit(start..<scanner.index, .comment)
                continue
            }
            if b == 0x3C /* < */ {
                let bracketStart = scanner.index
                scanner.advance(1)
                if scanner.peek() == 0x21 /* ! */ {
                    let isDoctype = scanner.startsWithASCII("!DOCTYPE") || scanner.startsWithASCII("!doctype")
                    while !scanner.isAtEnd && scanner.peek() != 0x3E {
                        scanner.advanceScalar()
                    }
                    if scanner.peek() == 0x3E { scanner.advance(1) }
                    scanner.emit(bracketStart..<scanner.index, isDoctype ? .tagDoctype : .comment)
                    continue
                }
                if scanner.peek() == 0x2F || scanner.peek() == 0x3F {
                    scanner.advance(1)
                }
                scanner.emit(bracketStart..<scanner.index, .punctuationBracketHTML)

                if let first = scanner.peek(), LexerScanner.isIdentStart(first) {
                    let tagStart = scanner.index
                    while let c = scanner.peek(), LexerScanner.isIdentContinue(c) || c == 0x2D || c == 0x3A {
                        scanner.advance(1)
                    }
                    scanner.emit(tagStart..<scanner.index, .tag)
                }

                // Scan attributes until > or />
                while !scanner.isAtEnd {
                    scanner.skipWhitespace()
                    guard let cur = scanner.peek() else { break }
                    if cur == 0x3E /* > */ {
                        let endStart = scanner.index
                        scanner.advance(1)
                        scanner.emit(endStart..<scanner.index, .punctuationBracketHTML)
                        break
                    }
                    if scanner.startsWith("/>") || scanner.startsWith("?>") {
                        let endStart = scanner.index
                        scanner.advance(2)
                        scanner.emit(endStart..<scanner.index, .punctuationBracketHTML)
                        break
                    }
                    if cur == 0x22 || cur == 0x27 {
                        scanner.scanQuotedString(quote: cur, allowEscapes: false)
                    } else if cur == 0x3D {
                        let eqStart = scanner.index
                        scanner.advance(1)
                        scanner.emit(eqStart..<scanner.index, .operator)
                    } else if LexerScanner.isIdentStart(cur) {
                        let attrStart = scanner.index
                        while let c = scanner.peek(), LexerScanner.isIdentContinue(c) || c == 0x2D || c == 0x3A {
                            scanner.advance(1)
                        }
                        scanner.emit(attrStart..<scanner.index, .attribute)
                    } else {
                        scanner.advanceScalar()
                    }
                }
                continue
            }
            if b == 0x26 /* &entity; */ {
                let start = scanner.index
                var end = start + 1
                while end < scanner.bytes.count && end - start < 12 && scanner.bytes[end] != 0x3B && scanner.bytes[end] != 0x20 && scanner.bytes[end] != 0x0A {
                    end += 1
                }
                if end < scanner.bytes.count && scanner.bytes[end] == 0x3B {
                    scanner.index = end + 1
                    scanner.emit(start..<scanner.index, .stringEscape)
                    continue
                }
            }
            scanner.advanceScalar()
        }
    }

    // MARK: - CSS / SCSS / LESS
    static func lexCSS(_ scanner: inout LexerScanner, allowLineComments: Bool) {
        var braceDepth = 0
        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard let b = scanner.peek() else { break }

            if scanner.startsWith("/*") {
                scanner.scanBlockComment()
                continue
            }
            if allowLineComments && scanner.startsWith("//") {
                scanner.scanLineComment()
                continue
            }
            if b == 0x22 || b == 0x27 {
                scanner.scanQuotedString(quote: b, allowEscapes: true)
                continue
            }
            if b == 0x40 /* @media, @import */ {
                let start = scanner.index
                scanner.advance(1)
                _ = scanner.scanIdentifierRange()
                scanner.emit(start..<scanner.index, .keyword)
                continue
            }
            if b == 0x2E /* .class */ && braceDepth == 0 {
                let start = scanner.index
                scanner.advance(1)
                while let c = scanner.peek(), LexerScanner.isIdentContinue(c) || c == 0x2D {
                    scanner.advance(1)
                }
                scanner.emit(start..<scanner.index, .selectorClass)
                continue
            }
            if b == 0x23 /* #id or #hexcolor */ {
                let start = scanner.index
                scanner.advance(1)
                while let c = scanner.peek(), LexerScanner.isIdentContinue(c) || c == 0x2D {
                    scanner.advance(1)
                }
                scanner.emit(start..<scanner.index, braceDepth == 0 ? .selectorID : .number)
                continue
            }
            if b == 0x3A /* :pseudo or : delimiter */ {
                if braceDepth == 0 {
                    let start = scanner.index
                    scanner.advance(1)
                    if scanner.peek() == 0x3A { scanner.advance(1) }
                    while let c = scanner.peek(), LexerScanner.isIdentContinue(c) || c == 0x2D {
                        scanner.advance(1)
                    }
                    scanner.emit(start..<scanner.index, .selectorPseudo)
                } else {
                    let start = scanner.index
                    scanner.advance(1)
                    scanner.emit(start..<scanner.index, .punctuationDelimiter)
                }
                continue
            }
            if LexerScanner.isDigit(b) {
                let start = scanner.index
                scanner.scanNumber()
                if scanner.peek() == 0x25 /* % */ {
                    scanner.advance(1)
                    if let last = scanner.spans.indices.last {
                        scanner.spans[last].utf8Range = start..<scanner.index
                    }
                }
                continue
            }
            if LexerScanner.isIdentStart(b) || b == 0x2D {
                let start = scanner.index
                scanner.advance(1)
                while let c = scanner.peek(), LexerScanner.isIdentContinue(c) || c == 0x2D {
                    scanner.advance(1)
                }
                let range = start..<scanner.index
                if braceDepth > 0 && scanner.nextNonWhitespaceByte(from: scanner.index) == 0x3A {
                    scanner.emit(range, .property)
                } else if scanner.peek() == 0x28 {
                    scanner.emit(range, .function)
                } else if braceDepth == 0 {
                    scanner.emit(range, .tag)
                }
                continue
            }
            let start = scanner.index
            switch b {
            case 0x7B:
                braceDepth += 1
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationBracket)
            case 0x7D:
                braceDepth = max(0, braceDepth - 1)
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationBracket)
            case 0x28, 0x29, 0x5B, 0x5D:
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationBracket)
            case 0x3B, 0x2C:
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationDelimiter)
            default:
                scanner.advanceScalar()
            }
        }
    }

    // MARK: - SQL
    static func lexSQL(_ scanner: inout LexerScanner) {
        let keywords: Set<String> = [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS",
            "ON", "USING", "GROUP", "BY", "ORDER", "ASC", "DESC", "HAVING", "LIMIT", "OFFSET",
            "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "INDEX",
            "VIEW", "ALTER", "DROP", "ADD", "COLUMN", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
            "UNIQUE", "CHECK", "DEFAULT", "CONSTRAINT", "AS", "AND", "OR", "NOT", "IN", "IS",
            "EXISTS", "BETWEEN", "LIKE", "ILIKE", "CASE", "WHEN", "THEN", "ELSE", "END",
            "DISTINCT", "UNION", "ALL", "WITH", "RECURSIVE", "RETURNING", "BEGIN", "COMMIT", "ROLLBACK",
        ]
        let types: Set<String> = [
            "INT", "INTEGER", "BIGINT", "SMALLINT", "TEXT", "VARCHAR", "CHAR", "BOOLEAN", "BOOL",
            "FLOAT", "DOUBLE", "REAL", "NUMERIC", "DECIMAL", "DATE", "TIME", "TIMESTAMP", "BLOB", "JSON", "JSONB", "UUID",
        ]

        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard let b = scanner.peek() else { break }

            if scanner.startsWith("--") {
                scanner.scanLineComment()
                continue
            }
            if scanner.startsWith("/*") {
                scanner.scanBlockComment()
                continue
            }
            if b == 0x27 /* ' */ {
                scanner.scanQuotedString(quote: 0x27, allowEscapes: false)
                continue
            }
            if b == 0x22 || b == 0x60 {
                scanner.scanQuotedString(quote: b, allowEscapes: true)
                continue
            }
            if LexerScanner.isDigit(b) {
                scanner.scanNumber()
                continue
            }
            if LexerScanner.isIdentStart(b) {
                let range = scanner.scanIdentifierRange()
                let upper = scanner.string(for: range).uppercased()
                if keywords.contains(upper) {
                    scanner.emit(range, .keyword)
                } else if types.contains(upper) {
                    scanner.emit(range, .typeBuiltin)
                } else if upper == "TRUE" || upper == "FALSE" {
                    scanner.emit(range, .boolean)
                } else if upper == "NULL" {
                    scanner.emit(range, .constantBuiltin)
                } else if scanner.nextNonWhitespaceByte(from: scanner.index) == 0x28 {
                    scanner.emit(range, .function)
                }
                continue
            }
            let start = scanner.index
            if b == 0x28 || b == 0x29 {
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationBracket)
            } else if b == 0x2C || b == 0x3B || b == 0x2E {
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationDelimiter)
            } else if b == 0x3D || b == 0x3C || b == 0x3E || b == 0x21 || b == 0x2B || b == 0x2D || b == 0x2A || b == 0x2F {
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .operator)
            } else {
                scanner.advanceScalar()
            }
        }
    }

    // MARK: - Diff / Patch
    static func lexDiff(_ scanner: inout LexerScanner) {
        while !scanner.isAtEnd {
            let lineStart = scanner.index
            scanner.advanceToLineEnd()
            let lineEnd = scanner.index
            if lineStart < lineEnd {
                let first = scanner.bytes[lineStart]
                if scanner.startsWithAt(lineStart, "diff ") || scanner.startsWithAt(lineStart, "index ") {
                    scanner.emit(lineStart..<lineEnd, .keyword)
                } else if scanner.startsWithAt(lineStart, "--- ") || scanner.startsWithAt(lineStart, "+++ ") {
                    scanner.emit(lineStart..<lineEnd, .title)
                } else if scanner.startsWithAt(lineStart, "@@") {
                    scanner.emit(lineStart..<lineEnd, .label)
                } else if first == 0x2B /* + */ {
                    scanner.emit(lineStart..<lineEnd, .diffPlus)
                } else if first == 0x2D /* - */ {
                    scanner.emit(lineStart..<lineEnd, .diffMinus)
                }
            }
            if scanner.peek() == 0x0A {
                scanner.advance(1)
            }
        }
    }
}

private extension LexerScanner {
    func startsWithAt(_ offset: Int, _ ascii: StaticString) -> Bool {
        let count = ascii.utf8CodeUnitCount
        guard offset + count <= bytes.count else { return false }
        return ascii.withUTF8Buffer { buf in
            for i in 0..<count where bytes[offset + i] != buf[i] {
                return false
            }
            return true
        }
    }
}
