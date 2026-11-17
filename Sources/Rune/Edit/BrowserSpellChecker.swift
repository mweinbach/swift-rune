#if os(WASI) && RUNE_BROWSER_TEXT
import CRuneDesktopText
import Foundation

/// The browser fetches Hunspell dictionaries on the first check. The checker otherwise
/// stays on the rendering thread, like Rune's wasm backend.
final class BrowserSpellChecker: DictionarySpellCheckBackend, @unchecked Sendable {
    private enum Request: Int32 {
        case available, preferred, select, check, suggest, learn, ignore, generation
    }

    private struct Result {
        var source: String
        var generation: Int32
        var ranges: [Range<Int>]
    }
    private let lock = NSLock()
    private var last: Result?

    var installedLanguages: [String] { strings(.available) }
    var preferredLanguages: [String] { strings(.preferred) }

    func selectLanguages(_ tags: [String]) {
        guard let data = try? JSONEncoder().encode(tags) else { return }
        _ = request(.select, String(decoding: data, as: UTF8.self))
    }

    func misspelledUTF8Ranges(in text: String) -> [Range<Int>] {
        guard !text.isEmpty else { return [] }
        let generation = rune_browser_spell_request(Request.generation.rawValue, nil, 0)
        if let cached = lock.withLock({ last }), cached.generation == generation, sameBytes(cached.source, text) {
            return cached.ranges
        }
        let bytes = request(.check, text)
        let length = text.utf8.count
        let result: [Range<Int>] = bytes.withUnsafeBytes { raw in
            guard raw.count.isMultiple(of: 8) else { return [] }
            var ranges: [Range<Int>] = []
            for offset in stride(from: 0, to: raw.count, by: 8) {
                let start = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let end = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                if start < end, end <= length { ranges.append(Int(start)..<Int(end)) }
            }
            return ranges
        }
        lock.withLock { last = Result(source: text, generation: generation, ranges: result) }
        return result
    }

    // Canonically equivalent Strings can have different byte offsets. A retained
    // document already in contiguous storage takes the pointer-equality branch.
    private func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
        var left = lhs, right = rhs
        return left.withUTF8 { a in
            right.withUTF8 { b in
                a.count == b.count && (a.baseAddress == b.baseAddress || a.elementsEqual(b))
            }
        }
    }

    func suggestions(for word: String) -> [String] { strings(.suggest, word) }
    func learnWord(_ word: String) { _ = request(.learn, word) }
    func ignoreWord(_ word: String) { _ = request(.ignore, word) }

    private func strings(_ operation: Request, _ text: String = "") -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(request(operation, text)))) ?? []
    }

    private func request(_ operation: Request, _ text: String) -> [UInt8] {
        var source = text
        let length = source.withUTF8 { bytes -> Int32 in
            guard let count = Int32(exactly: bytes.count) else { return 0 }
            return rune_browser_spell_request(operation.rawValue, bytes.baseAddress, count)
        }
        guard length > 0 else { return [] }
        return [UInt8](unsafeUninitializedCapacity: Int(length)) { buffer, count in
            rune_browser_spell_read(buffer.baseAddress, length)
            count = buffer.count
        }
    }
}
#endif
