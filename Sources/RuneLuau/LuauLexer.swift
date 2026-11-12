import Foundation

internal enum LuauTokenKind: Equatable {
    case eof
    case identifier(String)
    case number(Double)
    case string(String)
    /// Backtick interpolated string broken into literal parts and expression tokens:
    /// `lit0 { expr1 } lit1 { expr2 } lit2`
    case interpString(parts: [String], expressions: [[LuauToken]])

    // Keywords
    case kwAnd, kwBreak, kwDo, kwElse, kwElseif, kwEnd
    case kwFalse, kwFor, kwFunction, kwIf, kwIn, kwLocal
    case kwNil, kwNot, kwOr, kwRepeat, kwReturn, kwThen
    case kwTrue, kwUntil, kwWhile

    // Operators & Punctuation
    case plus, minus, star, slash, doubleSlash, percent, caret, hash
    case eq, neq, lt, le, gt, ge
    case assign
    case plusAssign, minusAssign, starAssign, slashAssign, doubleSlashAssign, percentAssign, caretAssign, dotDotAssign
    case lparen, rparen, lbrace, rbrace, lbracket, rbracket
    case semicolon, colon, doubleColon, comma, dot, dotDot, dotDotDot
    case arrow // ->
    case pipe, amp, question
}

internal struct LuauToken: Equatable {
    let kind: LuauTokenKind
    let line: Int
    let column: Int
}

internal final class LuauLexer {
    private let sourceName: String
    private let chars: [UnicodeScalar]
    private var pos: Int = 0
    private var line: Int = 1
    private var column: Int = 1

    init(source: String, name: String = "chunk") {
        self.sourceName = name
        self.chars = Array(source.unicodeScalars)
    }

    func tokenize() throws -> [LuauToken] {
        var tokens: [LuauToken] = []
        while true {
            skipWhitespaceAndComments()
            let tokLine = line
            let tokCol = column
            guard let ch = peek() else {
                tokens.append(LuauToken(kind: .eof, line: tokLine, column: tokCol))
                break
            }

            if isIdentStart(ch) {
                let ident = readIdentifier()
                let kind = keywordOrIdent(ident)
                tokens.append(LuauToken(kind: kind, line: tokLine, column: tokCol))
                continue
            }

            if isDigit(ch) || (ch == "." && peek(1).map(isDigit) == true) {
                let num = try readNumber(line: tokLine)
                tokens.append(LuauToken(kind: .number(num), line: tokLine, column: tokCol))
                continue
            }

            if ch == "\"" || ch == "'" {
                let str = try readQuotedString(quote: ch, line: tokLine)
                tokens.append(LuauToken(kind: .string(str), line: tokLine, column: tokCol))
                continue
            }

            if ch == "`" {
                let (parts, exprs) = try readInterpolatedString(line: tokLine)
                tokens.append(LuauToken(kind: .interpString(parts: parts, expressions: exprs), line: tokLine, column: tokCol))
                continue
            }

            if ch == "[" {
                if let level = checkLongBracket() {
                    let str = try readLongString(level: level, startLine: tokLine)
                    tokens.append(LuauToken(kind: .string(str), line: tokLine, column: tokCol))
                    continue
                }
            }

            advance()
            let kind: LuauTokenKind
            switch ch {
            case "+":
                if match("=") { kind = .plusAssign } else { kind = .plus }
            case "-":
                if match("=") { kind = .minusAssign }
                else if match(">") { kind = .arrow }
                else { kind = .minus }
            case "*":
                if match("=") { kind = .starAssign } else { kind = .star }
            case "/":
                if match("/") {
                    if match("=") { kind = .doubleSlashAssign } else { kind = .doubleSlash }
                } else if match("=") {
                    kind = .slashAssign
                } else {
                    kind = .slash
                }
            case "%":
                if match("=") { kind = .percentAssign } else { kind = .percent }
            case "^":
                if match("=") { kind = .caretAssign } else { kind = .caret }
            case "#": kind = .hash
            case "=":
                if match("=") { kind = .eq } else { kind = .assign }
            case "~":
                if match("=") { kind = .neq }
                else { throw syntaxError("unexpected character '~'", line: tokLine) }
            case "<":
                if match("=") { kind = .le } else { kind = .lt }
            case ">":
                if match("=") { kind = .ge } else { kind = .gt }
            case "(": kind = .lparen
            case ")": kind = .rparen
            case "{": kind = .lbrace
            case "}": kind = .rbrace
            case "[": kind = .lbracket
            case "]": kind = .rbracket
            case ";": kind = .semicolon
            case ",": kind = .comma
            case "|": kind = .pipe
            case "&": kind = .amp
            case "?": kind = .question
            case ":":
                if match(":") { kind = .doubleColon } else { kind = .colon }
            case ".":
                if match(".") {
                    if match(".") { kind = .dotDotDot }
                    else if match("=") { kind = .dotDotAssign }
                    else { kind = .dotDot }
                } else {
                    kind = .dot
                }
            default:
                throw syntaxError("unexpected character '\(ch)'", line: tokLine)
            }
            tokens.append(LuauToken(kind: kind, line: tokLine, column: tokCol))
        }
        return tokens
    }

    // MARK: - Helpers

    private func peek(_ offset: Int = 0) -> UnicodeScalar? {
        let i = pos + offset
        guard i < chars.count else { return nil }
        return chars[i]
    }

    @discardableResult
    private func advance() -> UnicodeScalar? {
        guard pos < chars.count else { return nil }
        let ch = chars[pos]
        pos += 1
        if ch == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        return ch
    }

    private func match(_ expected: UnicodeScalar) -> Bool {
        if peek() == expected {
            advance()
            return true
        }
        return false
    }

    private func syntaxError(_ msg: String, line: Int) -> ScriptError {
        ScriptError(kind: .syntax, message: "\(sourceName):\(line): \(msg)")
    }

    private func skipWhitespaceAndComments() {
        while let ch = peek() {
            if ch == " " || ch == "\t" || ch == "\r" || ch == "\n" || ch == "\u{0B}" || ch == "\u{0C}" {
                advance()
            } else if ch == "-" && peek(1) == "-" {
                advance()
                advance()
                if peek() == "[" {
                    if let level = checkLongBracket() {
                        _ = try? readLongString(level: level, startLine: line)
                        continue
                    }
                }
                while let c = peek(), c != "\n" {
                    advance()
                }
            } else {
                break
            }
        }
    }

    private func checkLongBracket() -> Int? {
        guard peek() == "[" else { return nil }
        var offset = 1
        while peek(offset) == "=" {
            offset += 1
        }
        if peek(offset) == "[" {
            return offset - 1
        }
        return nil
    }

    private func readLongString(level: Int, startLine: Int) throws -> String {
        // Consume opening [=*[
        advance()
        for _ in 0..<level { advance() }
        advance()
        // Skip immediate newline
        if peek() == "\r" && peek(1) == "\n" {
            advance(); advance()
        } else if peek() == "\n" || peek() == "\r" {
            advance()
        }
        var out = ""
        while let ch = peek() {
            if ch == "]" {
                var offset = 1
                var eqs = 0
                while eqs < level && peek(offset) == "=" {
                    eqs += 1
                    offset += 1
                }
                if eqs == level && peek(offset) == "]" {
                    for _ in 0..<(offset + 1) { advance() }
                    return out
                }
            }
            out.unicodeScalars.append(ch)
            advance()
        }
        throw syntaxError("unfinished long string", line: startLine)
    }

    private func readQuotedString(quote: UnicodeScalar, line startLine: Int) throws -> String {
        advance() // opening quote
        var out = ""
        while let ch = peek() {
            if ch == quote {
                advance()
                return out
            }
            if ch == "\n" || ch == "\r" {
                throw syntaxError("unfinished string", line: startLine)
            }
            if ch == "\\" {
                advance()
                try readEscape(into: &out, startLine: startLine)
            } else {
                out.unicodeScalars.append(ch)
                advance()
            }
        }
        throw syntaxError("unfinished string", line: startLine)
    }

    private func readEscape(into out: inout String, startLine: Int) throws {
        guard let esc = advance() else {
            throw syntaxError("unfinished escape sequence", line: startLine)
        }
        switch esc {
        case "a": out.append("\u{07}")
        case "b": out.append("\u{08}")
        case "f": out.append("\u{0C}")
        case "n": out.append("\n")
        case "r": out.append("\r")
        case "t": out.append("\t")
        case "v": out.append("\u{0B}")
        case "\\": out.append("\\")
        case "\"": out.append("\"")
        case "'": out.append("'")
        case "`": out.append("`")
        case "{": out.append("{")
        case "\n": out.append("\n")
        case "\r":
            if peek() == "\n" { advance() }
            out.append("\n")
        case "z":
            while let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" {
                advance()
            }
        case "x":
            var hex = ""
            for _ in 0..<2 {
                guard let h = advance(), isHexDigit(h) else {
                    throw syntaxError("hexadecimal digit expected", line: startLine)
                }
                hex.unicodeScalars.append(h)
            }
            if let v = UInt8(hex, radix: 16) {
                out.unicodeScalars.append(UnicodeScalar(v))
            }
        case "u":
            guard match("{") else {
                throw syntaxError("missing '{' in \\u escape", line: startLine)
            }
            var hex = ""
            while let c = peek(), c != "}" {
                guard isHexDigit(c) else {
                    throw syntaxError("hexadecimal digit expected", line: startLine)
                }
                hex.unicodeScalars.append(c)
                advance()
            }
            guard match("}"), let code = UInt32(hex, radix: 16), let scalar = UnicodeScalar(code) else {
                throw syntaxError("invalid UTF-8 codepoint in \\u escape", line: startLine)
            }
            out.unicodeScalars.append(scalar)
        default:
            if isDigit(esc) {
                var dec = String(esc)
                for _ in 0..<2 {
                    if let d = peek(), isDigit(d) {
                        dec.unicodeScalars.append(d)
                        advance()
                    } else {
                        break
                    }
                }
                guard let code = UInt32(dec), code <= 255 else {
                    throw syntaxError("decimal escape too large", line: startLine)
                }
                out.unicodeScalars.append(UnicodeScalar(code)!)
            } else {
                out.unicodeScalars.append(esc)
            }
        }
    }

    private func readInterpolatedString(line startLine: Int) throws -> ([String], [[LuauToken]]) {
        advance() // opening `
        var parts: [String] = []
        var exprs: [[LuauToken]] = []
        var currentLiteral = ""

        while let ch = peek() {
            if ch == "`" {
                advance()
                parts.append(currentLiteral)
                return (parts, exprs)
            }
            if ch == "\n" || ch == "\r" {
                throw syntaxError("unfinished interpolated string", line: startLine)
            }
            if ch == "\\" {
                advance()
                try readEscape(into: &currentLiteral, startLine: startLine)
                continue
            }
            if ch == "{" {
                advance()
                parts.append(currentLiteral)
                currentLiteral = ""
                // Read expression source up to matching '}'
                var braceDepth = 1
                var exprSource = ""
                let exprLine = line
                while let ec = peek() {
                    if ec == "{" {
                        braceDepth += 1
                        exprSource.unicodeScalars.append(ec)
                        advance()
                    } else if ec == "}" {
                        braceDepth -= 1
                        if braceDepth == 0 {
                            advance()
                            break
                        }
                        exprSource.unicodeScalars.append(ec)
                        advance()
                    } else if ec == "\"" || ec == "'" {
                        let q = ec
                        exprSource.unicodeScalars.append(q)
                        advance()
                        while let sc = peek() {
                            exprSource.unicodeScalars.append(sc)
                            advance()
                            if sc == "\\" {
                                if let nxt = peek() {
                                    exprSource.unicodeScalars.append(nxt)
                                    advance()
                                }
                            } else if sc == q {
                                break
                            }
                        }
                    } else {
                        exprSource.unicodeScalars.append(ec)
                        advance()
                    }
                }
                if braceDepth != 0 {
                    throw syntaxError("unfinished interpolation expression", line: exprLine)
                }
                let subLexer = LuauLexer(source: exprSource, name: sourceName)
                subLexer.line = exprLine
                let subTokens = try subLexer.tokenize()
                exprs.append(subTokens)
                continue
            }
            currentLiteral.unicodeScalars.append(ch)
            advance()
        }
        throw syntaxError("unfinished interpolated string", line: startLine)
    }

    private func readIdentifier() -> String {
        var s = ""
        while let ch = peek(), isIdentPart(ch) {
            s.unicodeScalars.append(ch)
            advance()
        }
        return s
    }

    private func readNumber(line startLine: Int) throws -> Double {
        var raw = ""
        if peek() == "0" && (peek(1) == "x" || peek(1) == "X") {
            raw.append("0x")
            advance(); advance()
            while let ch = peek(), isHexDigit(ch) || ch == "_" {
                if ch != "_" { raw.unicodeScalars.append(ch) }
                advance()
            }
            if peek() == "." {
                raw.append(".")
                advance()
                while let ch = peek(), isHexDigit(ch) || ch == "_" {
                    if ch != "_" { raw.unicodeScalars.append(ch) }
                    advance()
                }
            }
            if peek() == "p" || peek() == "P" {
                raw.unicodeScalars.append(peek()!)
                advance()
                if peek() == "+" || peek() == "-" {
                    raw.unicodeScalars.append(peek()!)
                    advance()
                }
                while let ch = peek(), isDigit(ch) || ch == "_" {
                    if ch != "_" { raw.unicodeScalars.append(ch) }
                    advance()
                }
            }
            if let d = Double(raw) { return d }
            let hexPart = String(raw.dropFirst(2))
            if let u = UInt64(hexPart, radix: 16) { return Double(u) }
            throw syntaxError("malformed number '\(raw)'", line: startLine)
        }

        if peek() == "0" && (peek(1) == "b" || peek(1) == "B") {
            advance(); advance()
            var bin = ""
            while let ch = peek(), ch == "0" || ch == "1" || ch == "_" {
                if ch != "_" { bin.unicodeScalars.append(ch) }
                advance()
            }
            guard !bin.isEmpty, let u = UInt64(bin, radix: 2) else {
                throw syntaxError("malformed binary number", line: startLine)
            }
            return Double(u)
        }

        while let ch = peek(), isDigit(ch) || ch == "_" {
            if ch != "_" { raw.unicodeScalars.append(ch) }
            advance()
        }
        if peek() == "." && peek(1) != "." {
            raw.append(".")
            advance()
            while let ch = peek(), isDigit(ch) || ch == "_" {
                if ch != "_" { raw.unicodeScalars.append(ch) }
                advance()
            }
        }
        if peek() == "e" || peek() == "E" {
            raw.unicodeScalars.append(peek()!)
            advance()
            if peek() == "+" || peek() == "-" {
                raw.unicodeScalars.append(peek()!)
                advance()
            }
            while let ch = peek(), isDigit(ch) || ch == "_" {
                if ch != "_" { raw.unicodeScalars.append(ch) }
                advance()
            }
        }
        guard let d = Double(raw) else {
            throw syntaxError("malformed number '\(raw)'", line: startLine)
        }
        return d
    }

    private func isIdentStart(_ c: UnicodeScalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_"
    }

    private func isIdentPart(_ c: UnicodeScalar) -> Bool {
        isIdentStart(c) || isDigit(c)
    }

    private func isDigit(_ c: UnicodeScalar) -> Bool {
        c >= "0" && c <= "9"
    }

    private func isHexDigit(_ c: UnicodeScalar) -> Bool {
        isDigit(c) || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
    }

    private func keywordOrIdent(_ s: String) -> LuauTokenKind {
        switch s {
        case "and": return .kwAnd
        case "break": return .kwBreak
        case "do": return .kwDo
        case "else": return .kwElse
        case "elseif": return .kwElseif
        case "end": return .kwEnd
        case "false": return .kwFalse
        case "for": return .kwFor
        case "function": return .kwFunction
        case "if": return .kwIf
        case "in": return .kwIn
        case "local": return .kwLocal
        case "nil": return .kwNil
        case "not": return .kwNot
        case "or": return .kwOr
        case "repeat": return .kwRepeat
        case "return": return .kwReturn
        case "then": return .kwThen
        case "true": return .kwTrue
        case "until": return .kwUntil
        case "while": return .kwWhile
        default: return .identifier(s)
        }
    }
}
