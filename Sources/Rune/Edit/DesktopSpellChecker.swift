#if os(Windows) || os(Linux)
import CRuneDesktopServices
import Foundation

private final class SpellStrings {
    var values: [String] = []
}

private func collectSpellString(_ context: UnsafeMutableRawPointer?, _ value: UnsafePointer<CChar>?) {
    guard let context, let value, let string = String(validatingCString: value) else { return }
    Unmanaged<SpellStrings>.fromOpaque(context).takeUnretainedValue().values.append(string)
}

private final class SpellRanges {
    let size: Int
    var values: [Range<Int>] = []

    init(size: Int) { self.size = size }
}

private func collectSpellRange(_ context: UnsafeMutableRawPointer?, _ start: Int, _ length: Int) {
    guard let context else { return }
    let result = Unmanaged<SpellRanges>.fromOpaque(context).takeUnretainedValue()
    guard start >= 0, length > 0, length <= result.size, start <= result.size - length else { return }
    result.values.append(start..<(start + length))
}

/// Uses the host dictionaries for spelling and retains their original UTF-8 positions.
final class DesktopSpellChecker: DictionarySpellCheckBackend, @unchecked Sendable {
    let installedLanguages: [String]
    private let lock = NSLock()
    private let fallback = CustomDictionarySpellChecker()
    private var languages: [String] = []
    private var ignored: Set<String> = []
    private var generation: UInt64 = 0

    // Canonically equivalent Swift Strings can have different UTF-8 byte ranges.
    private var cache: [Data: [Range<Int>]] = [:]

    init() {
        let result = SpellStrings()
        _ = rune_spell_languages(Unmanaged.passUnretained(result).toOpaque(), collectSpellString)
        installedLanguages = Array(Set(result.values)).sorted()
    }

    func selectLanguages(_ tags: [String]) {
        lock.lock()
        defer { lock.unlock() }
        if languages != tags {
            languages = tags
            invalidateCache()
        }
    }

    func misspelledUTF8Ranges(in text: String) -> [Range<Int>] {
        // A Windows spell provider can pump messages in the caller's COM apartment.
        // A nested window callback must be able to query or reconfigure the checker.
        let (languages, ignored, generation) = lock.withLock { (self.languages, self.ignored, self.generation) }
        guard !languages.isEmpty else { return fallback.misspelledUTF8Ranges(in: text) }
        let bytes = text.utf8
        var result: [Range<Int>] = []
        // Cache whole lines so an edit only checks the changed line. Splitting at
        // NUL also keeps text following an embedded NUL visible to the C APIs.
        for line in bytes.split(whereSeparator: { $0 == 10 || $0 == 0 }) {
            let offset = bytes.distance(from: bytes.startIndex, to: line.startIndex)
            let ranges = checkLine(Data(line), languages: languages, ignored: ignored, generation: generation)
            result.append(contentsOf: ranges.map { (offset + $0.lowerBound)..<(offset + $0.upperBound) })
        }
        return result
    }

    private func checkLine(_ bytes: Data, languages: [String], ignored: Set<String>, generation: UInt64) -> [Range<Int>] {
        let cacheable = bytes.count <= 4_096
        if cacheable, let cached = lock.withLock({ self.generation == generation ? cache[bytes] : nil }) {
            return cached
        }
        let text = String(decoding: bytes, as: UTF8.self)
        var intersection: Set<Range<Int>>?
        for tag in languages {
            let ranges = SpellRanges(size: bytes.count)
            guard rune_spell_check(tag, text, Unmanaged.passUnretained(ranges).toOpaque(), collectSpellRange) != 0 else { continue }
            if intersection == nil {
                intersection = Set(ranges.values)
            } else {
                intersection?.formIntersection(ranges.values)
            }
            if intersection?.isEmpty == true { break }
        }
        // A service can be absent or temporarily unavailable. Retry on a later call.
        guard let intersection else { return fallback.misspelledUTF8Ranges(in: text) }
        let result = intersection.filter { range in
            ignored.isEmpty || !ignored.contains(String(decoding: bytes[range], as: UTF8.self).lowercased())
        }.sorted { $0.lowerBound < $1.lowerBound }
        if cacheable {
            lock.withLock {
                guard self.generation == generation else { return }
                if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
                cache[bytes] = result
            }
        }
        return result
    }

    func suggestions(for word: String) -> [String] {
        guard !word.isEmpty, !word.utf8.contains(0) else { return [] }
        let (languages, isIgnored) = lock.withLock { (self.languages, ignored.contains(word.lowercased())) }
        if isIgnored { return [] }
        var answered = false
        var unique: [String] = []
        for tag in languages {
            let strings = SpellStrings()
            guard rune_spell_suggest(tag, word, Unmanaged.passUnretained(strings).toOpaque(), collectSpellString) != 0 else { continue }
            answered = true
            for suggestion in strings.values where !unique.contains(suggestion) {
                unique.append(suggestion)
                if unique.count == SpellChecker.maxSuggestions { return unique }
            }
        }
        return answered ? unique : fallback.suggestions(for: word)
    }

    func learnWord(_ word: String) {
        guard !word.isEmpty, !word.utf8.contains(0) else { return }
        let languages = lock.withLock { self.languages }
        fallback.learnWord(word)
        for tag in languages { _ = rune_spell_learn(tag, word) }
        lock.withLock { invalidateCache() }
    }

    func ignoreWord(_ word: String) {
        lock.lock()
        defer { lock.unlock() }
        ignored.insert(word.lowercased())
        fallback.ignoreWord(word)
        invalidateCache()
    }

    private func invalidateCache() {
        generation &+= 1
        cache.removeAll(keepingCapacity: true)
    }
}
#endif
