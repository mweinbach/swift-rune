import Foundation

/// Text shaping, Markdown, and syntax highlighting all address the original UTF-8
/// bytes. Swift String considers canonically equivalent spellings equal even when
/// the next grapheme starts at a different byte offset.
package struct TextUTF8Key: Hashable, Sendable {
    package let source: String
    private let fingerprint: Int

    package init(_ source: String) {
        var text = source
        var hasher = Hasher()
        text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        self.source = text
        self.fingerprint = hasher.finalize()
    }

    package func hash(into hasher: inout Hasher) { hasher.combine(fingerprint) }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fingerprint == rhs.fingerprint && equalBytes(lhs.source, rhs.source)
    }

    /// Compares the original bytes without allocating a key or calculating a hash.
    @inlinable
    package static func equalBytes(_ lhs: String, _ rhs: String) -> Bool {
        var left = lhs, right = rhs
        return left.withUTF8 { a in
            right.withUTF8 { b in
                guard a.count == b.count else { return false }
                guard a.count > 0, let x = a.baseAddress, let y = b.baseAddress else { return true }
                return x == y || memcmp(x, y, a.count) == 0
            }
        }
    }

    package func starts(with prefix: Self) -> Bool {
        var text = source
        var prefixText = prefix.source
        return text.withUTF8 { bytes in
            prefixText.withUTF8 { head in
                guard bytes.count >= head.count else { return false }
                guard head.count > 0, let a = bytes.baseAddress, let b = head.baseAddress else { return true }
                return a == b || memcmp(a, b, head.count) == 0
            }
        }
    }
}
