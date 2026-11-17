import Foundation
#if os(macOS)
import CoreFoundation
#elseif os(Windows)
import WinSDK
#endif

/// Natural name ordering in Rune's selected interface language (`text::compare_names`).
public enum RuneCollation: Sendable {
    #if os(macOS) || os(Windows)
    private final class CachedOrder {
        var tag: String?
        var compare: ((String, String) -> ComparisonResult)?
    }
    #endif

    public static func compareNames(
        _ a: String,
        _ b: String,
        languageTag: String? = nil
    ) -> ComparisonResult {
        #if os(macOS) || os(Windows)
        let tag = languageTag ?? TextLanguageRegistry.currentLanguageTag()
        let cached = runeExecutionLocal(forKey: "rune.text.collation", create: CachedOrder.init)
        if let compare = cached.compare, tag == cached.tag { return compare(a, b) }
        let compare = nameOrder(languageTag: tag)
        cached.tag = tag
        cached.compare = compare
        return compare(a, b)
        #else
        return total(compareNamesNatural(a, b), a, b)
        #endif
    }

    /// Captures the locale and working storage once for a synchronous sort.
    package static func nameOrder(languageTag: String?) -> (String, String) -> ComparisonResult {
        #if os(macOS)
        let locale = languageTag.flatMap {
            CFLocaleCreate(nil, CFLocaleCreateCanonicalLocaleIdentifierFromString(nil, $0 as CFString))
        }
        let flags: CFStringCompareFlags = [.compareCaseInsensitive, .compareNumerically, .compareLocalized, .compareWidthInsensitive]
        return { a, b in
            let x = a as CFString
            let result = CFStringCompareWithOptionsAndLocale(x, b as CFString, CFRange(location: 0, length: CFStringGetLength(x)), flags, locale)
            switch result {
            case .compareLessThan: return .orderedAscending
            case .compareGreaterThan: return .orderedDescending
            default: return total(.orderedSame, a, b)
            }
        }
        #elseif os(Windows)
        let buffers = WindowsBuffers(languageTag: languageTag)
        return { a, b in total(buffers.compare(a, b), a, b) }
        #else
        return { a, b in total(compareNamesNatural(a, b), a, b) }
        #endif
    }

    private static func total(_ result: ComparisonResult, _ a: String, _ b: String) -> ComparisonResult {
        guard result == .orderedSame else { return result }
        return compareBytes(a.utf8, b.utf8)
    }

    private static func compareBytes(_ a: String.UTF8View, _ b: String.UTF8View) -> ComparisonResult {
        if a.elementsEqual(b) { return .orderedSame }
        return a.lexicographicallyPrecedes(b) ? .orderedAscending : .orderedDescending
    }

    #if os(Windows)
    private final class WindowsBuffers {
        let locale: [UInt16]?
        var left: [UInt16] = []
        var right: [UInt16] = []

        init(languageTag: String?) {
            locale = languageTag.map { Array($0.utf16) + [0] }
        }

        func compare(_ a: String, _ b: String) -> ComparisonResult {
            left.removeAll(keepingCapacity: true)
            right.removeAll(keepingCapacity: true)
            left.append(contentsOf: a.utf16)
            right.append(contentsOf: b.utf16)
            guard let xCount = Int32(exactly: left.count), let yCount = Int32(exactly: right.count) else {
                return compareNamesNatural(a, b)
            }
            // Keep nonnull storage for empty inputs. Explicit counts preserve embedded NULs.
            left.append(0)
            right.append(0)
            let flags = DWORD(LINGUISTIC_IGNORECASE | NORM_LINGUISTIC_CASING | SORT_DIGITSASNUMBERS)
            func compareIn(_ name: UnsafePointer<UInt16>?) -> Int32 {
                left.withUnsafeBufferPointer { x in
                    right.withUnsafeBufferPointer { y in
                        CompareStringEx(name, flags, x.baseAddress!, xCount, y.baseAddress!, yCount, nil, nil, 0)
                    }
                }
            }
            let result = locale.map { $0.withUnsafeBufferPointer { compareIn($0.baseAddress) } } ?? compareIn(nil)
            switch result {
            case CSTR_LESS_THAN: return .orderedAscending
            case CSTR_EQUAL: return .orderedSame
            case CSTR_GREATER_THAN: return .orderedDescending
            default: return compareNamesNatural(a, b)
            }
        }
    }
    #endif

    /// Compares lowercase Unicode scalars and ASCII digit runs by numeric value.
    public static func compareNamesNatural(_ a: String, _ b: String) -> ComparisonResult {
        var x = a.unicodeScalars[...]
        var y = b.unicodeScalars[...]
        while let cx = x.first, let cy = y.first {
            if isDigit(cx) && isDigit(cy) {
                let m = takeDigits(&x), n = takeDigits(&y)
                let mc = m.count, nc = n.count
                if mc != nc { return mc < nc ? .orderedAscending : .orderedDescending }
                if !m.elementsEqual(n) {
                    return m.lexicographicallyPrecedes(n) ? .orderedAscending : .orderedDescending
                }
            } else {
                if cx != cy {
                    let result = compareBytes(cx.properties.lowercaseMapping.utf8, cy.properties.lowercaseMapping.utf8)
                    if result != .orderedSame { return result }
                }
                x = x.dropFirst()
                y = y.dropFirst()
            }
        }
        if x.isEmpty == y.isEmpty { return .orderedSame }
        return x.isEmpty ? .orderedAscending : .orderedDescending
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }

    private static func takeDigits(_ input: inout Substring.UnicodeScalarView) -> Substring.UnicodeScalarView {
        let end = input.firstIndex { !isDigit($0) } ?? input.endIndex
        let run = input[..<end].drop(while: { $0.value == 0x30 })
        input = input[end...]
        return run
    }
}
