import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

// MARK: - Untrusted Clipboard HTML Sanitizer (crates/rune/src/clipboard/html.rs)

/// Sanitizes untrusted HTML fragments from the OS clipboard and packs/unpacks Windows `CF_HTML`.
public enum ClipboardHTMLSanitizer: Sendable {
    /// Maximum untrusted clipboard HTML payload processed (4 MiB, matching upstream `MAX_HTML_BYTES`).
    public static let maxInputBytes = 4 * 1024 * 1024

    private static let dropWithContentTags: Set<String> = [
        "script", "style", "noscript", "template", "iframe", "frame", "frameset",
        "object", "embed", "applet", "svg", "math", "title", "textarea", "select",
        "xmp", "plaintext", "noembed", "noframes"
    ]

    private static let unwrapOnlyTags: Set<String> = [
        "html", "head", "body", "meta", "link", "base", "form", "input", "button",
        "fieldset", "legend", "label", "canvas", "video", "audio", "source", "track",
        "picture", "portal", "slot", "marquee", "blink", "details", "summary", "dialog",
        "optgroup", "option"
    ]

    private static let voidTags: Set<String> = ["br", "hr", "img", "wbr"]

    private static let keepTags: Set<String> = [
        "p", "div", "span", "h1", "h2", "h3", "h4", "h5", "h6",
        "b", "strong", "i", "em", "u", "s", "strike", "del", "ins", "mark",
        "code", "pre", "kbd", "samp", "var", "sub", "sup", "small", "big",
        "blockquote", "q", "cite", "ul", "ol", "li", "dl", "dt", "dd",
        "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption", "colgroup", "col",
        "a", "img", "br", "hr", "wbr", "font"
    ]

    private static let safeCSSProperties: Set<String> = [
        "color", "background-color", "background", "font-weight", "font-style",
        "font-family", "font-size", "text-decoration", "text-decoration-line",
        "text-align", "white-space", "vertical-align", "list-style-type",
        "margin", "margin-top", "margin-right", "margin-bottom", "margin-left",
        "padding", "padding-top", "padding-right", "padding-bottom", "padding-left"
    ]

    /// Strips active content, unsafe URLs, unsafe CSS, and disallowed elements from untrusted HTML.
    public static func sanitize(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let bounded = truncateUTF8Prefix(raw, maxBytes: maxInputBytes)
        let strippedNul = bounded.replacingOccurrences(of: "\0", with: "")
        let bytes = Array(strippedNul.utf8)
        let count = bytes.count

        var out = ""
        out.reserveCapacity(min(count, 64 * 1024))
        var i = 0
        var openStack: [String] = []

        while i < count {
            if bytes[i] != 0x3C { // '<'
                let start = i
                while i < count && bytes[i] != 0x3C {
                    i += 1
                }
                let textChunk = String(decoding: bytes[start..<i], as: UTF8.self)
                out.append(escapeText(decodeEntities(textChunk)))
                continue
            }

            // Comment: <!-- ... -->, <!-->, <!--->, or --!>
            if startsWithASCII(bytes, at: i, pattern: [0x3C, 0x21, 0x2D, 0x2D]) {
                i = skipHTMLComment(bytes, from: i + 4)
                continue
            }

            // Declaration / PI: <!...> or <?...>
            if i + 1 < count && (bytes[i + 1] == 0x21 || bytes[i + 1] == 0x3F) {
                i = skipUntilGreaterThan(bytes, from: i + 2)
                continue
            }

            guard let parsed = parseTag(bytes, at: i) else {
                // Lone '<' not starting a valid tag name or closing tag.
                out.append("&lt;")
                i += 1
                continue
            }
            i = parsed.nextIndex
            let tag = parsed.name

            if parsed.isClosing {
                if dropWithContentTags.contains(tag) || unwrapOnlyTags.contains(tag) || voidTags.contains(tag) {
                    continue
                }
                if keepTags.contains(tag), let idx = openStack.lastIndex(of: tag) {
                    while openStack.count > idx {
                        let closing = openStack.removeLast()
                        out.append("</\(closing)>")
                    }
                }
                continue
            }

            if dropWithContentTags.contains(tag) {
                if !parsed.isSelfClosing {
                    i = skipRawElementContent(bytes, from: i, tagName: tag)
                }
                continue
            }

            if unwrapOnlyTags.contains(tag) || !keepTags.contains(tag) {
                continue
            }

            var attrsOut = ""
            for (rawKey, rawVal) in parsed.attributes {
                guard let sanitizedAttr = sanitizeAttribute(tag: tag, name: rawKey, rawValue: rawVal) else {
                    continue
                }
                attrsOut.append(" \(sanitizedAttr.0)=\"\(escapeAttribute(sanitizedAttr.1))\"")
            }

            out.append("<\(tag)\(attrsOut)>")
            if !voidTags.contains(tag) && !parsed.isSelfClosing {
                openStack.append(tag)
            }
        }

        while let remaining = openStack.popLast() {
            out.append("</\(remaining)>")
        }
        return out
    }

    /// Returns true if `raw` resolves to an allowed URL scheme (`http`, `https`, `mailto`, `tel`) or relative URL.
    public static func isSafeURL(_ raw: String) -> Bool {
        let decoded = decodeEntities(raw)
        var cleanedScalars = ""
        for scalar in decoded.unicodeScalars {
            // HTML URL parser ignores ASCII tabs/newlines and leading/trailing C0 controls.
            if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D {
                continue
            }
            cleanedScalars.unicodeScalars.append(scalar)
        }
        let trimmedScalars = Array(cleanedScalars.unicodeScalars)
        var lo = 0
        while lo < trimmedScalars.count && (trimmedScalars[lo].value <= 0x20 || trimmedScalars[lo].value == 0x7F) {
            lo += 1
        }
        var hi = trimmedScalars.count
        while hi > lo && (trimmedScalars[hi - 1].value <= 0x20 || trimmedScalars[hi - 1].value == 0x7F) {
            hi -= 1
        }
        let trimmed = String(String.UnicodeScalarView(trimmedScalars[lo..<hi]))
        guard !trimmed.isEmpty, !trimmed.contains("\\") else { return false }

        // Check scheme prefix before ':', '/', '?', '#'
        for (idx, scalar) in trimmed.unicodeScalars.enumerated() {
            if scalar == ":" {
                if idx == 0 { return false }
                let scheme = String(trimmed.unicodeScalars.prefix(idx)).lowercased()
                return scheme == "http" || scheme == "https" || scheme == "mailto" || scheme == "tel"
            }
            if scalar == "/" || scalar == "?" || scalar == "#" {
                return true
            }
            let validSchemeChar = (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || (idx > 0 && ((scalar.value >= 0x30 && scalar.value <= 0x39) || scalar == "+" || scalar == "-" || scalar == "."))
            if !validSchemeChar {
                return false
            }
        }
        return true
    }

    /// Packs an HTML fragment into the Windows `CF_HTML` clipboard payload format.
    public static func packCFHTML(_ fragment: String) -> Data {
        let prefix = "<!DOCTYPE html><html><body><!--StartFragment-->"
        let suffix = "<!--EndFragment--></body></html>"
        let template =
            "Version:0.9\r\n" +
            "StartHTML:0000000000\r\n" +
            "EndHTML:0000000000\r\n" +
            "StartFragment:0000000000\r\n" +
            "EndFragment:0000000000\r\n"
        let headerLen = template.utf8.count
        let startHTML = headerLen
        let startFragment = startHTML + prefix.utf8.count
        let endFragment = startFragment + fragment.utf8.count
        let endHTML = endFragment + suffix.utf8.count
        let header = String(
            format: "Version:0.9\r\nStartHTML:%010d\r\nEndHTML:%010d\r\nStartFragment:%010d\r\nEndFragment:%010d\r\n",
            startHTML, endHTML, startFragment, endFragment
        )
        return Data((header + prefix + fragment + suffix).utf8)
    }

    /// Extracts the fragment (or HTML body) from a Windows `CF_HTML` clipboard payload.
    public static func unpackCFHTML(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        let headerLimit = min(bytes.count, 512)
        let headerString = String(decoding: bytes[0..<headerLimit], as: UTF8.self)

        func parseOffset(_ key: String) -> Int? {
            guard let range = headerString.range(of: key) else { return nil }
            let rest = headerString[range.upperBound...]
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            return Int(digits)
        }

        if let sf = parseOffset("StartFragment:"),
           let ef = parseOffset("EndFragment:"),
           sf >= 0, ef >= sf, ef <= bytes.count {
            return String(decoding: bytes[sf..<ef], as: UTF8.self)
        }
        if let sh = parseOffset("StartHTML:"),
           let eh = parseOffset("EndHTML:"),
           sh >= 0, eh >= sh, eh <= bytes.count {
            return String(decoding: bytes[sh..<eh], as: UTF8.self)
        }
        let full = String(decoding: bytes, as: UTF8.self)
        if let sRange = full.range(of: "<!--StartFragment-->"),
           let eRange = full.range(of: "<!--EndFragment-->", range: sRange.upperBound..<full.endIndex) {
            return String(full[sRange.upperBound..<eRange.lowerBound])
        }
        return nil
    }

    // MARK: - Internal Scanner Helpers

    private struct ParsedTag {
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
        let attributes: [(String, String)]
        let nextIndex: Int
    }

    private static func truncateUTF8Prefix(_ string: String, maxBytes: Int) -> String {
        if string.utf8.count <= maxBytes { return string }
        var end = string.startIndex
        var count = 0
        for ch in string {
            let len = ch.utf8.count
            if count + len > maxBytes { break }
            count += len
            end = string.index(after: end)
        }
        return String(string[..<end])
    }

    private static func startsWithASCII(_ bytes: [UInt8], at index: Int, pattern: [UInt8]) -> Bool {
        guard index + pattern.count <= bytes.count else { return false }
        for k in 0..<pattern.count where bytes[index + k] != pattern[k] {
            return false
        }
        return true
    }

    private static func skipHTMLComment(_ bytes: [UInt8], from start: Int) -> Int {
        // Immediate close: <!--> or <!--->
        if start < bytes.count && bytes[start] == 0x3E { return start + 1 }
        if startsWithASCII(bytes, at: start, pattern: [0x2D, 0x3E]) { return start + 2 }
        var i = start
        while i < bytes.count {
            if startsWithASCII(bytes, at: i, pattern: [0x2D, 0x2D, 0x3E]) { // -->
                return i + 3
            }
            if startsWithASCII(bytes, at: i, pattern: [0x2D, 0x2D, 0x21, 0x3E]) { // --!>
                return i + 4
            }
            i += 1
        }
        return bytes.count
    }

    private static func skipUntilGreaterThan(_ bytes: [UInt8], from start: Int) -> Int {
        var i = start
        var quote: UInt8 = 0
        while i < bytes.count {
            let b = bytes[i]
            if quote != 0 {
                if b == quote { quote = 0 }
            } else if b == 0x22 || b == 0x27 {
                quote = b
            } else if b == 0x3E {
                return i + 1
            }
            i += 1
        }
        return bytes.count
    }

    private static func isASCIILetter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    private static func isTagNameChar(_ b: UInt8) -> Bool {
        isASCIILetter(b) || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x5F || b == 0x3A
    }

    private static func isWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C
    }

    private static func parseTag(_ bytes: [UInt8], at start: Int) -> ParsedTag? {
        let n = bytes.count
        var i = start + 1
        guard i < n else { return nil }
        var isClosing = false
        if bytes[i] == 0x2F { // '/'
            isClosing = true
            i += 1
        }
        guard i < n, isASCIILetter(bytes[i]) else { return nil }
        let nameStart = i
        while i < n && isTagNameChar(bytes[i]) { i += 1 }
        let name = String(decoding: bytes[nameStart..<i], as: UTF8.self).lowercased()

        var attributes: [(String, String)] = []
        var isSelfClosing = false
        while i < n {
            while i < n && isWhitespace(bytes[i]) { i += 1 }
            guard i < n else { break }
            if bytes[i] == 0x3E { // '>'
                i += 1
                break
            }
            if bytes[i] == 0x2F { // '/'
                i += 1
                if i < n && bytes[i] == 0x3E {
                    isSelfClosing = true
                    i += 1
                    break
                }
                continue
            }

            let keyStart = i
            while i < n && !isWhitespace(bytes[i]) && bytes[i] != 0x3D && bytes[i] != 0x3E && bytes[i] != 0x2F {
                i += 1
            }
            if i == keyStart {
                i += 1
                continue
            }
            let attrName = String(decoding: bytes[keyStart..<i], as: UTF8.self).lowercased()
            while i < n && isWhitespace(bytes[i]) { i += 1 }
            var attrVal = ""
            if i < n && bytes[i] == 0x3D { // '='
                i += 1
                while i < n && isWhitespace(bytes[i]) { i += 1 }
                if i < n && (bytes[i] == 0x22 || bytes[i] == 0x27) {
                    let q = bytes[i]
                    i += 1
                    let vStart = i
                    while i < n && bytes[i] != q { i += 1 }
                    attrVal = String(decoding: bytes[vStart..<i], as: UTF8.self)
                    if i < n && bytes[i] == q { i += 1 }
                } else {
                    let vStart = i
                    while i < n && !isWhitespace(bytes[i]) && bytes[i] != 0x3E { i += 1 }
                    attrVal = String(decoding: bytes[vStart..<i], as: UTF8.self)
                }
            }
            if !isClosing {
                attributes.append((attrName, attrVal))
            }
        }
        return ParsedTag(
            name: name,
            isClosing: isClosing,
            isSelfClosing: isSelfClosing,
            attributes: attributes,
            nextIndex: i
        )
    }

    private static func skipRawElementContent(_ bytes: [UInt8], from start: Int, tagName: String) -> Int {
        let needle = Array(("</" + tagName).utf8)
        var i = start
        while i + needle.count <= bytes.count {
            if bytes[i] == 0x3C && bytes[i + 1] == 0x2F {
                var match = true
                for k in 2..<needle.count {
                    let b = bytes[i + k]
                    let lower = (b >= 0x41 && b <= 0x5A) ? (b + 32) : b
                    if lower != needle[k] {
                        match = false
                        break
                    }
                }
                if match {
                    let after = i + needle.count
                    if after == bytes.count || isWhitespace(bytes[after]) || bytes[after] == 0x3E || bytes[after] == 0x2F {
                        return skipUntilGreaterThan(bytes, from: after)
                    }
                }
            }
            i += 1
        }
        return bytes.count
    }

    private static func sanitizeAttribute(tag: String, name: String, rawValue: String) -> (String, String)? {
        if name.hasPrefix("on") { return nil }
        let decoded = decodeEntities(rawValue)

        switch name {
        case "dir":
            let lower = decoded.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard lower == "ltr" || lower == "rtl" || lower == "auto" else { return nil }
            return ("dir", lower)
        case "style":
            guard let css = sanitizeInlineCSS(decoded) else { return nil }
            return ("style", css)
        case "href":
            guard tag == "a", isSafeURL(decoded) else { return nil }
            return ("href", decoded.trimmingCharacters(in: .whitespacesAndNewlines))
        case "src":
            guard tag == "img", isSafeURL(decoded) else { return nil }
            return ("src", decoded.trimmingCharacters(in: .whitespacesAndNewlines))
        case "srcset":
            guard tag == "img" else { return nil }
            let filtered = sanitizeSrcSet(decoded)
            return filtered.isEmpty ? nil : ("srcset", filtered)
        case "alt", "title":
            return (name, decoded)
        case "width", "height", "colspan", "rowspan", "start", "value":
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "%" || $0 == "p" || $0 == "x") }) else {
                return nil
            }
            return (name, trimmed)
        case "type":
            guard tag == "ol" || tag == "ul" || tag == "li" else { return nil }
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                return nil
            }
            return ("type", trimmed)
        case "color", "face", "size":
            guard tag == "font" else { return nil }
            let lower = decoded.lowercased()
            if lower.contains("url(") || lower.contains("expression(") || lower.contains("javascript:") {
                return nil
            }
            return (name, decoded)
        default:
            return nil
        }
    }

    private static func sanitizeSrcSet(_ raw: String) -> String {
        let candidates = raw.split(separator: ",", omittingEmptySubsequences: true)
        var kept: [String] = []
        for cand in candidates {
            let trimmed = cand.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard let urlPart = parts.first else { continue }
            let urlStr = String(urlPart)
            guard isSafeURL(urlStr) else { continue }
            if parts.count == 2 {
                let desc = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                if desc.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "w" || $0 == "x") }) {
                    kept.append("\(urlStr) \(desc)")
                    continue
                }
            }
            kept.append(urlStr)
        }
        return kept.joined(separator: ", ")
    }

    private static func sanitizeInlineCSS(_ raw: String) -> String? {
        // Reject CSS escapes or comments so active tokens cannot hide across boundaries.
        let lower = raw.lowercased()
        if lower.contains("\\") || lower.contains("/*") || lower.contains("url(")
            || lower.contains("expression(") || lower.contains("-moz-binding")
            || lower.contains("behavior") || lower.contains("@import")
            || lower.contains("javascript:") || lower.contains("vbscript:")
            || lower.contains("data:") {
            return nil
        }
        var kept: [String] = []
        for decl in raw.split(separator: ";", omittingEmptySubsequences: true) {
            let parts = decl.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let prop = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard safeCSSProperties.contains(prop), !val.isEmpty else { continue }
            kept.append("\(prop): \(val)")
        }
        return kept.isEmpty ? nil : kept.joined(separator: "; ")
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if scalars[i] == "&" {
                if let (decoded, next) = parseEntity(scalars, from: i + 1) {
                    out.unicodeScalars.append(decoded)
                    i = next
                    continue
                }
            }
            out.unicodeScalars.append(scalars[i])
            i += 1
        }
        return out
    }

    private static func parseEntity(_ scalars: [UnicodeScalar], from start: Int) -> (UnicodeScalar, Int)? {
        guard start < scalars.count else { return nil }
        if scalars[start] == "#" {
            var i = start + 1
            guard i < scalars.count else { return nil }
            let isHex = scalars[i] == "x" || scalars[i] == "X"
            if isHex { i += 1 }
            let digitStart = i
            var value: UInt32 = 0
            while i < scalars.count && i - digitStart < 8 {
                let v = scalars[i].value
                let digit: UInt32?
                if v >= 0x30 && v <= 0x39 {
                    digit = v - 0x30
                } else if isHex && v >= 0x41 && v <= 0x46 {
                    digit = 10 + (v - 0x41)
                } else if isHex && v >= 0x61 && v <= 0x66 {
                    digit = 10 + (v - 0x61)
                } else {
                    digit = nil
                }
                guard let d = digit else { break }
                value = value &* (isHex ? 16 : 10) &+ d
                i += 1
            }
            guard i > digitStart else { return nil }
            if i < scalars.count && scalars[i] == ";" { i += 1 }
            if value == 0 || value > 0x10FFFF {
                return (UnicodeScalar(0xFFFD)!, i)
            }
            return (UnicodeScalar(value) ?? UnicodeScalar(0xFFFD)!, i)
        }

        var end = start
        while end < scalars.count && end - start < 16 {
            let v = scalars[end].value
            if !((v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39)) {
                break
            }
            end += 1
        }
        guard end > start, end < scalars.count, scalars[end] == ";" else { return nil }
        let name = String(String.UnicodeScalarView(scalars[start..<end]))
        let mapped: UnicodeScalar?
        switch name.lowercased() {
        case "amp": mapped = "&"
        case "lt": mapped = "<"
        case "gt": mapped = ">"
        case "quot": mapped = "\""
        case "apos": mapped = "'"
        case "nbsp": mapped = UnicodeScalar(0x00A0)
        case "colon": mapped = ":"
        case "tab": mapped = "\t"
        case "newline": mapped = "\n"
        default: mapped = nil
        }
        guard let scalar = mapped else { return nil }
        return (scalar, end + 1)
    }

    private static func escapeText(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            default: out.append(ch)
            }
        }
        return out
    }

    private static func escapeAttribute(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&#39;")
            default: out.append(ch)
            }
        }
        return out
    }
}

// MARK: - Secret Clipboard Hold State Machine (crates/rune/src/clipboard/secret.rs)

/// Routing sink used by `SecretSlot` to ask a clipboard backend to clear a held secret.
public protocol SecretClipboardRoute: AnyObject, Sendable {
    func requestClear(slot: SecretSlot)
}

/// Shared synchronization slot backing a `SecretClipboardHold`. Never retains secret text.
public final class SecretSlot: @unchecked Sendable {
    public static let refusedWipeMessage = "the clipboard refused the wipe"

    private let lock = NSLock()
    private var _state: SecretState = .pending
    private var holdsCount: UInt32 = 0
    private var _cancelled = false
    private var wroteRefused = false
    public weak var route: (any SecretClipboardRoute)?

    public init() {}

    public var state: SecretState {
        lock.lock()
        defer { lock.unlock() }
        return wroteRefused ? .failed(Self.refusedWipeMessage) : _state
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }

    public func markHeld() {
        lock.lock()
        wroteRefused = false
        _state = .holding
        holdsCount &+= 1
        lock.unlock()
    }

    public func markReleased(_ next: SecretState, wipeRefused: Bool = false) {
        lock.lock()
        wroteRefused = wipeRefused
        _state = wipeRefused ? .failed(Self.refusedWipeMessage) : next
        if holdsCount > 0 { holdsCount -= 1 }
        lock.unlock()
    }

    public func report(_ next: SecretState) {
        lock.lock()
        wroteRefused = false
        _state = next
        lock.unlock()
    }

    public func settleDroppedUnwritten() {
        lock.lock()
        if _state == .pending && !wroteRefused {
            _state = _cancelled ? .cleared : .replaced
        }
        lock.unlock()
    }

    /// Cancels future writes and, if still holding (or replay failed while holding earlier write), requests a wipe.
    @discardableResult
    public func cancelAndRequestClear() -> Bool {
        lock.lock()
        let wasFailedWriteWithHold: Bool
        if case .failed = _state, !wroteRefused, holdsCount > 0 {
            wasFailedWriteWithHold = true
        } else {
            wasFailedWriteWithHold = false
        }
        let shouldClear = (!wroteRefused && _state == .holding) || wasFailedWriteWithHold
        _cancelled = true
        let targetRoute = route
        lock.unlock()

        if shouldClear, let targetRoute {
            targetRoute.requestClear(slot: self)
            return true
        }
        return false
    }
}

/// Handle to a secret clipboard copy (`rune::clipboard::SecretCopy`), safe to log/debug without leaking text.
public struct SecretClipboardHold: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let slot: SecretSlot

    public init(slot: SecretSlot = SecretSlot()) {
        self.slot = slot
    }

    public static func pending() -> SecretClipboardHold {
        SecretClipboardHold(slot: SecretSlot())
    }

    public var state: SecretState { slot.state }
    public var holds: Bool { slot.state == .holding }

    @discardableResult
    public func clearNow() -> Bool {
        slot.cancelAndRequestClear()
    }

    public var description: String { "SecretClipboardHold(\(state))" }
    public var debugDescription: String { description }
}

/// Testable in-memory clipboard host implementing weak-slot `Hold` semantics (`crates/rune/src/clipboard/secret.rs`, `r131`).
public final class MemorySecretClipboardHost: SecretClipboardRoute, @unchecked Sendable {
    private let lock = NSLock()
    private var currentText: String?
    private var revision: UInt64 = 0
    private var heldAttempt: UInt64 = 0
    private weak var heldSlot: SecretSlot?
    private var heldRevision: UInt64?
    private var heldFingerprint: UInt64 = 0
    private var heldDueTime: Double?
    private var refuseNextWipe = false

    public init() {}

    public var changeCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    /// Reads current plain text (for test assertions only; `SecretClipboardHold` never stores or exposes text).
    public var rawPlainText: String? {
        lock.lock()
        defer { lock.unlock() }
        return currentText
    }

    public func setRefuseNextWipe(_ refuse: Bool) {
        lock.lock()
        refuseNextWipe = refuse
        lock.unlock()
    }

    /// Writes `secret` onto the clipboard unless already cancelled before reaching the worker.
    @discardableResult
    public func writeSecret(
        _ secret: String,
        clearAfterSeconds: Double? = 30.0,
        now: Double = 0.0
    ) -> SecretClipboardHold {
        let slot = SecretSlot()
        slot.route = self
        return submitSecret(secret, slot: slot, clearAfterSeconds: clearAfterSeconds, now: now)
    }

    @discardableResult
    public func submitSecret(
        _ secret: String,
        slot: SecretSlot,
        clearAfterSeconds: Double? = 30.0,
        now: Double = 0.0
    ) -> SecretClipboardHold {
        if slot.isCancelled {
            slot.settleDroppedUnwritten()
            return SecretClipboardHold(slot: slot)
        }

        lock.lock()
        let prevSlot = heldSlot
        heldSlot = nil

        revision &+= 1
        currentText = secret
        heldAttempt &+= 1
        heldSlot = slot
        heldRevision = revision
        heldFingerprint = fingerprint(secret)
        heldDueTime = clearAfterSeconds.map { now + max(0, $0) }
        lock.unlock()

        prevSlot?.markReleased(.replaced)
        slot.markHeld()
        return SecretClipboardHold(slot: slot)
    }

    /// Simulates another app (or non-secret copy) overwriting the clipboard.
    public func writeExternal(_ text: String) {
        lock.lock()
        let prevSlot = heldSlot
        heldSlot = nil
        heldRevision = nil
        heldDueTime = nil
        revision &+= 1
        currentText = text
        lock.unlock()
        prevSlot?.markReleased(.replaced)
    }

    /// Advances time and fires due expiration if the current hold is still intact on the clipboard.
    public func tick(now: Double) {
        lock.lock()
        guard let due = heldDueTime, now >= due else {
            lock.unlock()
            return
        }
        let target = heldSlot
        let stillOurs = isOursLocked()
        let refused = refuseNextWipe
        if stillOurs && !refused {
            currentText = nil
            revision &+= 1
        }
        heldSlot = nil
        heldRevision = nil
        heldDueTime = nil
        refuseNextWipe = false
        lock.unlock()

        if !stillOurs {
            target?.markReleased(.replaced)
        } else if refused {
            target?.markReleased(.failed(SecretSlot.refusedWipeMessage), wipeRefused: true)
        } else {
            target?.markReleased(.cleared)
        }
    }

    public func requestClear(slot: SecretSlot) {
        lock.lock()
        guard let active = heldSlot, active === slot else {
            lock.unlock()
            return
        }
        let stillOurs = isOursLocked()
        let refused = refuseNextWipe
        if stillOurs && !refused {
            currentText = nil
            revision &+= 1
        }
        heldSlot = nil
        heldRevision = nil
        heldDueTime = nil
        refuseNextWipe = false
        lock.unlock()

        if !stillOurs {
            slot.markReleased(.replaced)
        } else if refused {
            slot.markReleased(.failed(SecretSlot.refusedWipeMessage), wipeRefused: true)
        } else {
            slot.markReleased(.cleared)
        }
    }

    private func isOursLocked() -> Bool {
        guard heldRevision == revision, let text = currentText else { return false }
        return fingerprint(text) == heldFingerprint
    }

    private func fingerprint(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h &*= 0x100000001b3
        }
        return h
    }
}

// MARK: - Locale-Aware & Numeric Collation (crates/rune/src/text/collate.rs, #810)

/// Human-friendly localized name collation (`file2` < `file10`, total tie-breaker by code points).
public enum RuneCollation: Sendable {
    public static func compareNames(
        _ a: String,
        _ b: String,
        languageTag: String? = nil
    ) -> ComparisonResult {
        let primary = collate(a, b, languageTag: languageTag)
        if primary != .orderedSame { return primary }
        if a < b { return .orderedAscending }
        if a > b { return .orderedDescending }
        return .orderedSame
    }

    private static func collate(_ a: String, _ b: String, languageTag: String?) -> ComparisonResult {
        #if canImport(CoreFoundation)
        let cfA = a as CFString
        let cfB = b as CFString
        let flags: CFStringCompareFlags = [
            .compareCaseInsensitive,
            .compareNumerically,
            .compareLocalized,
            .compareWidthInsensitive
        ]
        let tag = languageTag ?? SpellChecker.shared.languages().first
        let locale: CFLocale? = tag.flatMap { rawTag in
            let ident = CFLocaleCreateCanonicalLocaleIdentifierFromString(nil, rawTag as CFString)
            return CFLocaleCreate(nil, ident)
        }
        switch CFStringCompareWithOptionsAndLocale(
            cfA,
            cfB,
            CFRange(location: 0, length: CFStringGetLength(cfA)),
            flags,
            locale
        ) {
        case .compareLessThan: return .orderedAscending
        case .compareGreaterThan: return .orderedDescending
        default: return .orderedSame
        }
        #else
        return compareNamesNatural(a, b)
        #endif
    }

    /// Portable natural ordering fallback: case-folded scalars with numeric comparison on ASCII digit runs.
    public static func compareNamesNatural(_ a: String, _ b: String) -> ComparisonResult {
        let xs = Array(a.unicodeScalars)
        let ys = Array(b.unicodeScalars)
        var i = 0
        var j = 0

        while i < xs.count || j < ys.count {
            if i == xs.count { return .orderedAscending }
            if j == ys.count { return .orderedDescending }

            let cx = xs[i]
            let cy = ys[j]
            if isASCIIDigit(cx) && isASCIIDigit(cy) {
                var iEnd = i
                while iEnd < xs.count && isASCIIDigit(xs[iEnd]) { iEnd += 1 }
                var jEnd = j
                while jEnd < ys.count && isASCIIDigit(ys[jEnd]) { jEnd += 1 }

                let dx = trimLeadingZeros(xs[i..<iEnd])
                let dy = trimLeadingZeros(ys[j..<jEnd])
                if dx.count != dy.count {
                    return dx.count < dy.count ? .orderedAscending : .orderedDescending
                }
                for k in 0..<dx.count where dx[k].value != dy[k].value {
                    return dx[k].value < dy[k].value ? .orderedAscending : .orderedDescending
                }
                i = iEnd
                j = jEnd
            } else {
                let lx = String(cx).lowercased()
                let ly = String(cy).lowercased()
                if lx != ly {
                    return lx < ly ? .orderedAscending : .orderedDescending
                }
                i += 1
                j += 1
            }
        }
        return .orderedSame
    }

    private static func isASCIIDigit(_ s: UnicodeScalar) -> Bool {
        s.value >= 0x30 && s.value <= 0x39
    }

    private static func trimLeadingZeros(_ slice: ArraySlice<UnicodeScalar>) -> [UnicodeScalar] {
        var idx = slice.startIndex
        while idx < slice.endIndex && slice[idx].value == 0x30 {
            idx = slice.index(after: idx)
        }
        return Array(slice[idx..<slice.endIndex])
    }
}
