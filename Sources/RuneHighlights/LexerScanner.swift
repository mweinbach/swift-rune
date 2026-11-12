import Foundation

/// Fast UTF-8 byte scanner for zero-dependency syntax lexing.
struct LexerScanner {
    let bytes: [UInt8]
    var index: Int = 0
    var spans: [HighlightSpan] = []

    init(_ source: String) {
        self.bytes = Array(source.utf8)
        self.spans.reserveCapacity(max(16, bytes.count / 8))
    }

    var isAtEnd: Bool {
        index >= bytes.count
    }

    func peek(_ offset: Int = 0) -> UInt8? {
        let target = index + offset
        guard target >= 0, target < bytes.count else { return nil }
        return bytes[target]
    }

    func startsWith(_ ascii: StaticString) -> Bool {
        let count = ascii.utf8CodeUnitCount
        guard index + count <= bytes.count else { return false }
        return ascii.withUTF8Buffer { buf in
            for i in 0..<count where bytes[index + i] != buf[i] {
                return false
            }
            return true
        }
    }

    func startsWithASCII(_ string: String) -> Bool {
        let utf8 = Array(string.utf8)
        guard index + utf8.count <= bytes.count else { return false }
        for i in 0..<utf8.count where bytes[index + i] != utf8[i] {
            return false
        }
        return true
    }

    @discardableResult
    mutating func advance(_ count: Int = 1) -> UInt8? {
        guard !isAtEnd else { return nil }
        let b = bytes[index]
        index = min(bytes.count, index + count)
        return b
    }

    /// Advances past one UTF-8 scalar if not at end.
    mutating func advanceScalar() {
        guard index < bytes.count else { return }
        let b = bytes[index]
        let step: Int
        if b < 0x80 {
            step = 1
        } else if (b & 0xE0) == 0xC0 {
            step = 2
        } else if (b & 0xF0) == 0xE0 {
            step = 3
        } else {
            step = 4
        }
        index = min(bytes.count, index + step)
    }

    mutating func emit(_ range: Range<Int>, _ kind: HighlightToken.Kind) {
        guard kind != .none, range.lowerBound < range.upperBound else { return }
        spans.append(HighlightSpan(utf8Range: range, token: HighlightToken(kind)))
    }

    mutating func skipWhitespace() {
        while let b = peek(), b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A {
            index += 1
        }
    }

    mutating func skipHorizontalWhitespace() {
        while let b = peek(), b == 0x20 || b == 0x09 {
            index += 1
        }
    }

    mutating func advanceToLineEnd() {
        while let b = peek(), b != 0x0A {
            index += 1
        }
    }

    mutating func scanLineComment(isDoc: Bool = false) {
        let start = index
        advanceToLineEnd()
        emit(start..<index, isDoc ? .commentDoc : .comment)
    }

    mutating func scanBlockComment(nested: Bool = false) {
        let start = index
        let isDoc = startsWith("/**") && !startsWith("/**/")
        advance(2)
        var depth = 1
        while !isAtEnd && depth > 0 {
            if nested && startsWith("/*") {
                depth += 1
                advance(2)
            } else if startsWith("*/") {
                depth -= 1
                advance(2)
            } else {
                advanceScalar()
            }
        }
        emit(start..<index, isDoc ? .commentDoc : .comment)
    }

    mutating func scanQuotedString(
        quote: UInt8,
        allowEscapes: Bool = true,
        multiline: Bool = false,
        emitEscapes: Bool = true
    ) {
        var segStart = index
        advance(1)
        while let b = peek() {
            if !multiline && b == 0x0A {
                break
            }
            if allowEscapes && b == 0x5C /* \ */ {
                if emitEscapes {
                    emit(segStart..<index, .string)
                    let escStart = index
                    advance(1)
                    if !isAtEnd {
                        advanceScalar()
                    }
                    emit(escStart..<index, .stringEscape)
                    segStart = index
                } else {
                    advance(1)
                    if !isAtEnd { advanceScalar() }
                }
                continue
            }
            if b == quote {
                advance(1)
                break
            }
            advanceScalar()
        }
        emit(segStart..<index, .string)
    }

    mutating func scanTripleQuotedString(quote: UInt8, allowEscapes: Bool = true) {
        var segStart = index
        advance(3)
        while !isAtEnd {
            if bytes[index] == quote && peek(1) == quote && peek(2) == quote {
                advance(3)
                break
            }
            if allowEscapes && bytes[index] == 0x5C {
                emit(segStart..<index, .string)
                let escStart = index
                advance(1)
                if !isAtEnd { advanceScalar() }
                emit(escStart..<index, .stringEscape)
                segStart = index
                continue
            }
            advanceScalar()
        }
        emit(segStart..<index, .string)
    }

    mutating func scanNumber() {
        let start = index
        if peek() == 0x30 /* 0 */, let next = peek(1) {
            if next == 0x78 || next == 0x58 /* x/X */ {
                advance(2)
                while let b = peek(), Self.isHexDigit(b) || b == 0x5F {
                    index += 1
                }
                scanNumberSuffix()
                emit(start..<index, .number)
                return
            } else if next == 0x62 || next == 0x42 /* b/B */ {
                advance(2)
                while let b = peek(), b == 0x30 || b == 0x31 || b == 0x5F {
                    index += 1
                }
                scanNumberSuffix()
                emit(start..<index, .number)
                return
            } else if next == 0x6F || next == 0x4F /* o/O */ {
                advance(2)
                while let b = peek(), (b >= 0x30 && b <= 0x37) || b == 0x5F {
                    index += 1
                }
                scanNumberSuffix()
                emit(start..<index, .number)
                return
            }
        }

        while let b = peek(), Self.isDigit(b) || b == 0x5F {
            index += 1
        }
        if peek() == 0x2E /* . */, let afterDot = peek(1), Self.isDigit(afterDot) {
            index += 1
            while let b = peek(), Self.isDigit(b) || b == 0x5F {
                index += 1
            }
        }
        if let e = peek(), e == 0x65 || e == 0x45 /* e/E */ {
            if let afterE = peek(1), Self.isDigit(afterE) || afterE == 0x2B || afterE == 0x2D {
                index += 1
                if peek() == 0x2B || peek() == 0x2D { index += 1 }
                while let b = peek(), Self.isDigit(b) || b == 0x5F {
                    index += 1
                }
            }
        }
        scanNumberSuffix()
        emit(start..<index, .number)
    }

    private mutating func scanNumberSuffix() {
        while let b = peek(), Self.isIdentContinue(b) {
            index += 1
        }
    }

    mutating func scanIdentifierRange() -> Range<Int> {
        let start = index
        while let b = peek(), Self.isIdentContinue(b) {
            index += 1
        }
        return start..<index
    }

    func string(for range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    func nextNonWhitespaceByte(from start: Int) -> UInt8? {
        var i = start
        while i < bytes.count {
            let b = bytes[i]
            if b != 0x20 && b != 0x09 && b != 0x0D && b != 0x0A {
                return b
            }
            i += 1
        }
        return nil
    }

    static func isDigit(_ b: UInt8) -> Bool {
        b >= 0x30 && b <= 0x39
    }

    static func isHexDigit(_ b: UInt8) -> Bool {
        isDigit(b) || (b >= 0x61 && b <= 0x66) || (b >= 0x41 && b <= 0x46)
    }

    static func isAlpha(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A)
    }

    static func isUpperASCII(_ b: UInt8) -> Bool {
        b >= 0x41 && b <= 0x5A
    }

    static func isIdentStart(_ b: UInt8) -> Bool {
        isAlpha(b) || b == 0x5F /* _ */ || b == 0x24 /* $ */
    }

    static func isIdentContinue(_ b: UInt8) -> Bool {
        isIdentStart(b) || isDigit(b)
    }
}
