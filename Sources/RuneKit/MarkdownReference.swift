import Foundation

/// A CommonMark reference definition at the start of a block. Offsets address
/// container-stripped UTF-8 lines. Destinations and titles retain their escapes.
struct MarkdownReference {
    let key: String
    let rawDestination: String
    let rawTitle: String?
    let lineCount: Int
    let endByte: Int

    /// The caller supplies continuation lines that belong to the same container and
    /// can continue a paragraph. Each line excludes its terminating newline.
    static func scan(firstLine: String, continuation: (Int) -> String?) -> Self? {
        var cursor = Cursor(bytes: Array(firstLine.utf8))
        while cursor.byte == 0x20 && cursor.offset < 3 { cursor.offset += 1 }
        guard cursor.take(0x5B) else { return nil }

        var label: [UInt8] = []
        while cursor.byte != 0x5D {
            guard cursor.byte != 0x5B else { return nil }
            if cursor.byte == nil {
                guard cursor.nextLine(continuation) else { return nil }
                label.append(0x0A)
            } else if cursor.escapedPunctuation {
                label.append(contentsOf: cursor.bytes[cursor.offset..<(cursor.offset + 2)])
                cursor.offset += 2
            } else {
                label.append(cursor.bytes[cursor.offset])
                cursor.offset += 1
            }
        }
        cursor.offset += 1
        guard cursor.take(0x3A), let key = normalized(label) else { return nil }
        cursor.skipSpace()
        if cursor.byte == nil {
            guard cursor.nextLine(continuation) else { return nil }
            cursor.skipSpace()
        }
        guard let url = cursor.destination() else { return nil }
        let bare = Self(key: key, rawDestination: url, rawTitle: nil, lineCount: cursor.line + 1, endByte: cursor.offset)

        let endOfURL = cursor.offset
        cursor.skipSpace()
        let titleOnNextLine = cursor.byte == nil
        if titleOnNextLine {
            guard cursor.nextLine(continuation) else { return bare }
            cursor.skipSpace()
        } else if cursor.offset == endOfURL {
            return nil
        }
        guard let title = cursor.title(continuation) else { return titleOnNextLine ? bare : nil }
        let endOfTitle = cursor.offset
        cursor.skipSpace()
        guard cursor.byte == nil else { return titleOnNextLine ? bare : nil }
        return Self(key: key, rawDestination: url, rawTitle: title, lineCount: cursor.line + 1, endByte: endOfTitle)
    }

    /// The same folded key is used for a definition and an inline reference to it.
    static func key(_ label: String) -> String? { normalized(Array(label.utf8)) }

    private static func normalized(_ bytes: [UInt8]) -> String? {
        var out: [UInt8] = []
        var index = 0
        var weight = 0
        var needsSpace = false
        var ascii = true
        while index < bytes.count {
            let byte = bytes[index]
            if isSpace(byte) || byte == 0x0A || byte == 0x0D {
                let start = index
                var hasBreak = false
                repeat {
                    let c = bytes[index]
                    if c == 0x0A || c == 0x0D {
                        guard !hasBreak else { return nil }
                        hasBreak = true
                        if c == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 1 }
                    }
                    index += 1
                } while index < bytes.count && (isSpace(bytes[index]) || bytes[index] == 0x0A || bytes[index] == 0x0D)
                weight += index - start
                needsSpace = !out.isEmpty
            } else {
                if needsSpace { out.append(0x20); needsSpace = false }
                if byte == 0x5C, index + 1 < bytes.count, isPunctuation(bytes[index + 1]) {
                    out.append(contentsOf: bytes[index..<(index + 2)])
                    weight += 2
                    index += 2
                } else {
                    guard byte != 0x5B && byte != 0x5D else { return nil }
                    if byte >= 0x80 { ascii = false; weight += 1 }
                    out.append((0x41...0x5A).contains(byte) ? byte + 0x20 : byte)
                    index += 1
                }
            }
            // Match pulldown-cmark 0.13's label scanner, including how it counts UTF-8.
            guard weight < 1000 else { return nil }
        }
        guard !out.isEmpty else { return nil }
        let label = String(decoding: out, as: UTF8.self)
        return ascii ? label : label.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0B || byte == 0x0C
    }

    private static func isPunctuation(_ byte: UInt8) -> Bool {
        (0x21...0x2F).contains(byte) || (0x3A...0x40).contains(byte)
            || (0x5B...0x60).contains(byte) || (0x7B...0x7E).contains(byte)
    }

    private struct Cursor {
        var bytes: [UInt8]
        var line = 0
        var offset = 0
        var byte: UInt8? { offset < bytes.count ? bytes[offset] : nil }
        var escapedPunctuation: Bool {
            byte == 0x5C && offset + 1 < bytes.count && isPunctuation(bytes[offset + 1])
        }

        mutating func take(_ expected: UInt8) -> Bool {
            guard byte == expected else { return false }
            offset += 1
            return true
        }

        mutating func skipSpace() {
            while let byte, isSpace(byte) { offset += 1 }
        }

        mutating func nextLine(_ continuation: (Int) -> String?) -> Bool {
            guard let next = continuation(line + 1), next.utf8.contains(where: { !isSpace($0) }) else { return false }
            bytes = Array(next.utf8)
            offset = 0
            line += 1
            return true
        }

        mutating func destination() -> String? {
            let pointy = take(0x3C)
            let start = offset
            var parentheses = 0
            while let byte {
                if escapedPunctuation { offset += 2; continue }
                if pointy {
                    if byte == 0x3C { return nil }
                    if byte == 0x3E {
                        let url = String(decoding: bytes[start..<offset], as: UTF8.self)
                        offset += 1
                        return url
                    }
                } else {
                    if byte <= 0x20 { break }
                    if byte == 0x28 {
                        guard parentheses <= 32 else { return nil }
                        parentheses += 1
                    } else if byte == 0x29 {
                        guard parentheses > 0 else { break }
                        parentheses -= 1
                    }
                }
                offset += 1
            }
            guard !pointy, start < offset, parentheses == 0 else { return nil }
            return String(decoding: bytes[start..<offset], as: UTF8.self)
        }

        mutating func title(_ continuation: (Int) -> String?) -> String? {
            guard let opener = byte, opener == 0x22 || opener == 0x27 || opener == 0x28 else { return nil }
            let closer: UInt8 = opener == 0x28 ? 0x29 : opener
            offset += 1
            var result: [UInt8] = []
            var start = offset
            while true {
                if let byte {
                    if byte == closer {
                        result.append(contentsOf: bytes[start..<offset])
                        offset += 1
                        return String(decoding: result, as: UTF8.self)
                    }
                    if opener == 0x28 && byte == 0x28 { return nil }
                    offset += (byte == 0x5C && offset + 1 < bytes.count) ? 2 : 1
                } else {
                    result.append(contentsOf: bytes[start..<offset])
                    guard nextLine(continuation) else { return nil }
                    result.append(0x0A)
                    skipSpace()
                    start = offset
                }
            }
        }
    }
}
