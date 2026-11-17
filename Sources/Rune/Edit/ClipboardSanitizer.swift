import Foundation

// MARK: - Untrusted Clipboard HTML Sanitizer (crates/rune/src/clipboard/html.rs)

/// Sanitizes untrusted HTML fragments from the OS clipboard and packs/unpacks Windows `CF_HTML`.
public enum ClipboardHTMLSanitizer: Sendable {
    /// Maximum untrusted clipboard HTML payload processed (4 MiB, matching upstream `MAX_RICH_BYTES`).
    public static let maxInputBytes = 4 * 1024 * 1024

    /// Elements dropped with everything inside them (`DROP_WITH_CONTENT`).
    private static let dropWithContentTags: Set<String> = [
        "script", "iframe", "object", "applet", "noscript", "noembed", "noframes", "template", "frameset",
        "svg", "math", "xml", "portal", "fencedframe"
    ]

    /// Elements dropped on their own; their content (if any) is sanitized as ordinary markup (`DROP_TAG`).
    private static let dropTag: Set<String> = [
        "base", "link", "meta", "embed", "frame", "param", "form",
        "title", "textarea", "xmp", "plaintext", "listing"
    ]

    /// Attributes that hold a URL (or, for `srcset`, a list of them) (`URL_ATTRIBUTES`).
    private static let urlAttributes: Set<String> = [
        "href", "src", "xlink:href", "background", "poster", "cite", "longdesc", "lowsrc",
        "dynsrc", "data", "codebase", "ping", "srcset", "manifest", "icon", "profile", "classid", "archive"
    ]

    private static let dropAttributes: Set<String> = [
        "srcdoc", "http-equiv", "action", "formaction"
    ]

    /// Named entities decoded during URL / CSS / `srcset` checks (`decode_entities`).
    private static let namedEntities: [String: UnicodeScalar] = [
        "colon": ":", "tab": "\t", "newline": "\n", "lpar": "(", "rpar": ")",
        "sol": "/", "bsol": "\\", "amp": "&", "lt": "<", "nvlt": "<", "gt": ">", "nvgt": ">",
        "quot": "\"", "apos": "'", "nbsp": " ", "num": "#", "period": ".",
        "commat": "@", "semi": ";", "equals": "=", "grave": "`",
        "plus": "+", "comma": ",", "dollar": "$"
    ]

    private static let unsafeCSSTokens: [String] = [
        "expression(", "javascript:", "vbscript:", "data:", "@import",
        "url(", "image-set(", "behavior:", "-moz-binding", "</", "\\", "<"
    ]

    private static let allowedRasterDataTypes: [String] = [
        "png", "jpeg", "jpg", "gif", "webp"
    ]

    /// Strips active content, unsafe URLs, unsafe CSS, comments, CDATA, PIs, and raw-text tags while keeping ordinary text, attributes (`class`, `style`), and inert `<style>...</style>`.
    public static func sanitize(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let bounded = truncateUTF8Prefix(raw, maxBytes: maxInputBytes)
        let html = bounded.contains("\0") ? bounded.replacingOccurrences(of: "\0", with: "") : bounded
        let bytes = Array(html.utf8)
        let count = bytes.count

        var out = ""
        out.reserveCapacity(min(count, 64 * 1024))
        var i = 0

        while let lt = findByte(0x3C, in: bytes, from: i) { // '<'
            if lt > i {
                out.append(String(decoding: bytes[i..<lt], as: UTF8.self))
            }

            let next1 = lt + 1 < count ? bytes[lt + 1] : 0
            let next2 = lt + 2 < count ? bytes[lt + 2] : 0

            if startsWithASCII(bytes, at: lt, pattern: [0x3C, 0x21, 0x2D, 0x2D]) { // <!--
                guard let end = commentEnd(bytes, from: lt) else { return out }
                i = end
            } else if startsWithASCIICaseInsensitive(bytes, at: lt, lowerPattern: [0x3C, 0x21, 0x5B, 0x63, 0x64, 0x61, 0x74, 0x61, 0x5B]) { // <![cdata[
                guard let end = findPattern([0x5D, 0x5D, 0x3E], in: bytes, from: lt + 9) else { return out }
                i = end + 3
            } else if next1 == 0x21 || next1 == 0x3F || (next1 == 0x2F && !isASCIILetter(next2)) {
                guard let end = findByte(0x3E, in: bytes, from: lt) else { return out }
                i = end + 1
            } else if next1 == 0x2F {
                guard let tag = parseTag(bytes, nameStart: lt + 2) else { return out }
                i = lt + 2 + tag.len
                if !isDroppedTag(tag.name) && tag.name != "style" {
                    out.append("</\(tag.name)>")
                }
            } else if isASCIILetter(next1) {
                guard let tag = parseTag(bytes, nameStart: lt + 1) else { return out }
                i = lt + 1 + tag.len
                if dropWithContentTags.contains(tag.name) || tag.name == "style" {
                    guard let close = untilClose(bytes, from: i, tagName: tag.name) else { return out }
                    if tag.name == "style" && !tag.closed {
                        let inner = String(decoding: bytes[i..<close.innerEnd], as: UTF8.self)
                        if cssIsInert(inner) && cssIsInert(decodeEntities(inner)) {
                            writeTag(tag, into: &out)
                            out.append(inner)
                            out.append("</style>")
                        }
                    }
                    i = close.afterCloseTag
                } else if !dropTag.contains(tag.name) {
                    writeTag(tag, into: &out)
                }
            } else {
                out.append("&lt;")
                i = lt + 1
            }
        }
        if i < count {
            out.append(String(decoding: bytes[i..<count], as: UTF8.self))
        }
        return out
    }

    /// Returns true if `raw` is a relative URL (excluding protocol-relative `//` / `\\` and `&` entities),
    /// an allowed web/mail/phone/attachment scheme (`http`, `https`, `mailto`, `tel`, `cid`),
    /// or (when `image == true`) a raster `data:image/{png,jpeg,jpg,gif,webp}` URL.
    public static func isSafeURL(_ raw: String, image: Bool = false) -> Bool {
        let decoded = decodeEntities(raw)
        var filtered = ""
        filtered.reserveCapacity(decoded.unicodeScalars.count)
        for scalar in decoded.unicodeScalars where !isRustControl(scalar) && !isRustWhitespace(scalar) {
            filtered.unicodeScalars.append(scalar)
        }
        let url = filtered.lowercased()
        guard let colon = url.firstIndex(of: ":") else {
            return !url.hasPrefix("//") && !url.hasPrefix("\\\\") && !url.contains("&")
        }
        let beforeColon = url[..<colon]
        if beforeColon.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" || $0 == "&" }) {
            return !url.hasPrefix("//") && !url.hasPrefix("\\\\") && !beforeColon.contains("&")
        }
        switch beforeColon {
        case "http", "https", "mailto", "tel", "cid":
            return true
        case "data":
            guard image else { return false }
            let urlBytes = Array(url.utf8)
            for ext in allowedRasterDataTypes {
                let prefix = "data:image/\(ext)"
                let pCount = prefix.utf8.count
                if url.hasPrefix(prefix), urlBytes.count > pCount {
                    let delim = urlBytes[pCount]
                    if delim == 0x3B || delim == 0x2C { // ';' or ','
                        return true
                    }
                }
            }
            return false
        default:
            return false
        }
    }

    /// Packs an HTML fragment into the Windows `CF_HTML` clipboard payload format.
    public static func packCFHTML(_ fragment: String) -> Data {
        let prefix = "<html>\r\n<body>\r\n<!--StartFragment-->"
        let suffix = "<!--EndFragment-->\r\n</body>\r\n</html>"
        let startHTML = 105
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
        let rawBytes = [UInt8](data)
        let nulIdx = rawBytes.firstIndex(of: 0) ?? rawBytes.count
        let cappedLen = min(nulIdx, maxInputBytes)
        guard cappedLen > 0 else { return nil }
        let sliceBytes = Array(rawBytes[..<cappedLen])
        guard let text = String(bytes: sliceBytes, encoding: .utf8) else { return nil }

        var startHTML: Int?
        var endHTML: Int?
        var startFrag: Int?
        var endFrag: Int?
        var headerEnd = 0
        var sawHeader = false

        var lineStart = 0
        while lineStart < sliceBytes.count {
            let lineEnd: Int
            if let nl = sliceBytes[lineStart...].firstIndex(of: 0x0A) {
                lineEnd = nl + 1
            } else {
                lineEnd = sliceBytes.count
            }
            var trimmedEnd = lineEnd
            while trimmedEnd > lineStart && (sliceBytes[trimmedEnd - 1] == 0x0A || sliceBytes[trimmedEnd - 1] == 0x0D) {
                trimmedEnd -= 1
            }
            if trimmedEnd > lineStart && sliceBytes[lineStart] == 0x3C { // '<'
                break
            }
            let lineStr = String(decoding: sliceBytes[lineStart..<trimmedEnd], as: UTF8.self)
            guard let colon = lineStr.firstIndex(of: ":") else { break }
            sawHeader = true
            headerEnd += (lineEnd - lineStart)
            let key = lineStr[..<colon].trimmingCharacters(in: .whitespaces)
            let val = lineStr[lineStr.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let parsedOffset = Int64(val).flatMap { $0 >= 0 && $0 <= Int64(Int.max) ? Int($0) : nil }
            switch key {
            case "StartHTML": startHTML = parsedOffset
            case "EndHTML": endHTML = parsedOffset
            case "StartFragment": startFrag = parsedOffset
            case "EndFragment": endFrag = parsedOffset
            default: break
            }
            lineStart = lineEnd
        }

        func utf8Slice(_ s: Int, _ e: Int) -> String? {
            guard s >= headerEnd, s <= e, e <= sliceBytes.count else { return nil }
            let startIdx = text.utf8.index(text.startIndex, offsetBy: s)
            let endIdx = text.utf8.index(text.startIndex, offsetBy: e)
            guard startIdx.samePosition(in: text) != nil, endIdx.samePosition(in: text) != nil else { return nil }
            return String(text[startIdx..<endIdx])
        }

        if let s = startFrag, let e = endFrag, let frag = utf8Slice(s, e), !frag.isEmpty {
            return frag
        }
        let startMark = "<!--StartFragment-->"
        let endMark = "<!--EndFragment-->"
        if let sRange = text.range(of: startMark),
           let eRange = text.range(of: endMark, range: sRange.upperBound..<text.endIndex) {
            return String(text[sRange.upperBound..<eRange.lowerBound])
        }
        if let s = startHTML, let e = endHTML, let doc = utf8Slice(s, e), !doc.isEmpty {
            return doc
        }
        let bodyBytes = sawHeader ? sliceBytes[headerEnd...] : sliceBytes[...]
        let body = String(decoding: bodyBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    // MARK: - Internal Scanner Helpers

    private struct ParsedTag {
        let name: String
        let attributes: [(String, String?)]
        let closed: Bool
        let len: Int
    }

    private static func isDroppedTag(_ name: String) -> Bool {
        dropWithContentTags.contains(name) || dropTag.contains(name)
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

    private static func findByte(_ target: UInt8, in bytes: [UInt8], from start: Int) -> Int? {
        var i = start
        while i < bytes.count {
            if bytes[i] == target { return i }
            i += 1
        }
        return nil
    }

    private static func findPattern(_ pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard !pattern.isEmpty, start + pattern.count <= bytes.count else { return nil }
        let limit = bytes.count - pattern.count
        var i = start
        while i <= limit {
            var matched = true
            for k in 0..<pattern.count where bytes[i + k] != pattern[k] {
                matched = false
                break
            }
            if matched { return i }
            i += 1
        }
        return nil
    }

    private static func startsWithASCII(_ bytes: [UInt8], at index: Int, pattern: [UInt8]) -> Bool {
        guard index + pattern.count <= bytes.count else { return false }
        for k in 0..<pattern.count where bytes[index + k] != pattern[k] {
            return false
        }
        return true
    }

    private static func startsWithASCIICaseInsensitive(_ bytes: [UInt8], at index: Int, lowerPattern: [UInt8]) -> Bool {
        guard index + lowerPattern.count <= bytes.count else { return false }
        for k in 0..<lowerPattern.count {
            let b = bytes[index + k]
            let lower = (b >= 0x41 && b <= 0x5A) ? (b + 32) : b
            if lower != lowerPattern[k] { return false }
        }
        return true
    }

    private static func commentEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        if startsWithASCII(bytes, at: start, pattern: [0x3C, 0x21, 0x2D, 0x2D, 0x3E]) { return start + 5 } // <!-->
        if startsWithASCII(bytes, at: start, pattern: [0x3C, 0x21, 0x2D, 0x2D, 0x2D, 0x3E]) { return start + 6 } // <!--->
        var j = start + 4
        while j + 2 < bytes.count {
            if bytes[j] == 0x2D && bytes[j + 1] == 0x2D {
                if bytes[j + 2] == 0x3E { return j + 3 } // -->
                if bytes[j + 2] == 0x21 && j + 3 < bytes.count && bytes[j + 3] == 0x3E { return j + 4 } // --!>
            }
            j += 1
        }
        return nil
    }

    private static func untilClose(_ bytes: [UInt8], from start: Int, tagName: String) -> (innerEnd: Int, afterCloseTag: Int)? {
        let needle = Array(tagName.utf8)
        var i = start
        while let rel = findByte(0x3C, in: bytes, from: i) {
            let afterName = rel + 2 + needle.count
            if rel + 1 < bytes.count && bytes[rel + 1] == 0x2F && afterName <= bytes.count {
                var matched = true
                for k in 0..<needle.count {
                    let b = bytes[rel + 2 + k]
                    let lower = (b >= 0x41 && b <= 0x5A) ? (b + 32) : b
                    if lower != needle[k] {
                        matched = false
                        break
                    }
                }
                if matched {
                    let boundary = afterName < bytes.count ? bytes[afterName] : 0x3E
                    if !isTagNameChar(boundary) {
                        guard let gt = findByte(0x3E, in: bytes, from: afterName) else { return nil }
                        return (rel, gt + 1)
                    }
                }
            }
            i = rel + 1
        }
        return nil
    }

    private static func isASCIILetter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    private static func isASCIIAlnum(_ b: UInt8) -> Bool {
        isASCIILetter(b) || (b >= 0x30 && b <= 0x39)
    }

    private static func isTagNameChar(_ b: UInt8) -> Bool {
        isASCIIAlnum(b) || b == 0x2D || b == 0x5F || b == 0x3A
    }

    private static func isAttrNameChar(_ b: UInt8) -> Bool {
        isTagNameChar(b) || b == 0x2E
    }

    private static func isASCIIWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C
    }

    private static func parseTag(_ bytes: [UInt8], nameStart: Int) -> ParsedTag? {
        let n = bytes.count
        var i = nameStart
        while i < n && isTagNameChar(bytes[i]) { i += 1 }
        let name = String(decoding: bytes[nameStart..<i], as: UTF8.self).lowercased()
        var attributes: [(String, String?)] = []
        var closed = false

        while true {
            while i < n && (isASCIIWhitespace(bytes[i]) || bytes[i] == 0x2F) {
                closed = (bytes[i] == 0x2F)
                i += 1
            }
            guard i < n else { return nil }
            if bytes[i] == 0x3E { // '>'
                return ParsedTag(name: name, attributes: attributes, closed: closed, len: (i + 1) - nameStart)
            }
            closed = false

            let attrStart = i
            while i < n && !isASCIIWhitespace(bytes[i]) && bytes[i] != 0x2F && bytes[i] != 0x3E && bytes[i] != 0x3D {
                i += 1
            }
            if i == attrStart { i += 1 } // A stray '='
            let attr = String(decoding: bytes[attrStart..<i], as: UTF8.self).lowercased()
            while i < n && isASCIIWhitespace(bytes[i]) { i += 1 }
            var value: String? = nil
            if i < n && bytes[i] == 0x3D { // '='
                i += 1
                while i < n && isASCIIWhitespace(bytes[i]) { i += 1 }
                if i < n && (bytes[i] == 0x22 || bytes[i] == 0x27) {
                    let q = bytes[i]
                    guard let end = findByte(q, in: bytes, from: i + 1) else { return nil }
                    value = String(decoding: bytes[(i + 1)..<end], as: UTF8.self)
                    i = end + 1
                } else {
                    let vStart = i
                    while i < n && !isASCIIWhitespace(bytes[i]) && bytes[i] != 0x3E { i += 1 }
                    value = String(decoding: bytes[vStart..<i], as: UTF8.self)
                }
            }
            if keepAttribute(name: attr, value: value) {
                attributes.append((attr, value))
            }
        }
    }

    private static func writeTag(_ tag: ParsedTag, into out: inout String) {
        out.append("<")
        out.append(tag.name)
        for (name, value) in tag.attributes {
            out.append(" ")
            out.append(name)
            if let value {
                out.append("=\"")
                for c in value {
                    switch c {
                    case "\"": out.append("&quot;")
                    case "<": out.append("&lt;")
                    case ">": out.append("&gt;")
                    default: out.append(c)
                    }
                }
                out.append("\"")
            }
        }
        if tag.closed { out.append(" /") }
        out.append(">")
    }

    private static func keepAttribute(name: String, value: String?) -> Bool {
        guard !name.isEmpty, name.utf8.allSatisfy(isAttrNameChar) else { return false }
        if name.hasPrefix("on") || dropAttributes.contains(name) { return false }
        let val = value ?? ""
        if name == "style" { return cssIsInert(val) && cssIsInert(decodeEntities(val)) }
        if name == "srcset" { return srcsetIsSafe(val) }
        if urlAttributes.contains(name) { return isSafeURL(val, image: name == "src") }
        return true
    }

    private static func srcsetIsSafe(_ raw: String) -> Bool {
        let decoded = decodeEntities(raw)
        var rest = decoded.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        guard !rest.isEmpty else { return false }
        while !rest.isEmpty {
            rest = rest.drop { $0.isWhitespace || $0 == "," }
            guard !rest.isEmpty else { break }
            let urlEnd: Substring.Index
            if rest.count >= 5 && rest.prefix(5).lowercased() == "data:" {
                let afterComma = rest.firstIndex(of: ",").map { rest.index(after: $0) } ?? rest.startIndex
                urlEnd = rest[afterComma...].firstIndex(where: { $0.isWhitespace || $0 == "," }) ?? rest.endIndex
            } else {
                urlEnd = rest.firstIndex(where: { $0.isWhitespace || $0 == "," }) ?? rest.endIndex
            }
            if !isSafeURL(String(rest[..<urlEnd]), image: true) { return false }
            rest = rest[urlEnd...]
            if let comma = rest.firstIndex(of: ",") {
                rest = rest[rest.index(after: comma)...]
            } else {
                break
            }
        }
        return true
    }

    private static func cssIsInert(_ css: String) -> Bool {
        var stripped = ""
        stripped.reserveCapacity(css.count)
        var rest = css[...]
        while let start = rest.range(of: "/*") {
            stripped.append(contentsOf: rest[..<start.lowerBound])
            let afterCommentStart = rest[start.upperBound...]
            guard let end = afterCommentStart.range(of: "*/") else { return false }
            rest = afterCommentStart[end.upperBound...]
        }
        stripped.append(contentsOf: rest)
        return cssTokensClean(css) && cssTokensClean(stripped)
    }

    private static func cssTokensClean(_ css: String) -> Bool {
        var compact = ""
        compact.reserveCapacity(css.unicodeScalars.count)
        for scalar in css.unicodeScalars where !isRustWhitespace(scalar) && !isRustControl(scalar) {
            compact.unicodeScalars.append(scalar)
        }
        let plain = compact.lowercased()
        for bad in unsafeCSSTokens where plain.contains(bad) {
            return false
        }
        return true
    }

    private static func isRustControl(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        return v <= 0x1F || (v >= 0x7F && v <= 0x9F)
    }

    private static func isRustWhitespace(_ scalar: UnicodeScalar) -> Bool {
        Character(scalar).isWhitespace
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        let bytes = Array(text.utf8)
        let n = bytes.count
        var i = 0

        while let amp = findByte(0x26, in: bytes, from: i) {
            if amp > i {
                out.append(String(decoding: bytes[i..<amp], as: UTF8.self))
            }
            var bodyEnd = amp + 1
            while bodyEnd < n && (isASCIIAlnum(bytes[bodyEnd]) || bytes[bodyEnd] == 0x23) {
                bodyEnd += 1
            }
            let bodyStart = amp + 1
            var matched: (UnicodeScalar, Int)? = nil

            if bodyStart < bodyEnd && bytes[bodyStart] == 0x23 { // '#'
                var cursor = bodyStart + 1
                var radix: UInt32 = 10
                var prefixLen = 1
                if cursor < bodyEnd && (bytes[cursor] == 0x78 || bytes[cursor] == 0x58) { // 'x'/'X'
                    radix = 16
                    prefixLen = 2
                    cursor += 1
                }
                let digitsStart = cursor
                while cursor < bodyEnd && isDigit(bytes[cursor], radix: radix) {
                    cursor += 1
                }
                if cursor > digitsStart {
                    var nonZeroStart = digitsStart
                    while nonZeroStart < cursor && bytes[nonZeroStart] == 0x30 {
                        nonZeroStart += 1
                    }
                    let scalar: UnicodeScalar
                    if nonZeroStart == cursor {
                        scalar = UnicodeScalar(0xFFFD)!
                    } else {
                        let digitStr = String(decoding: bytes[nonZeroStart..<cursor], as: UTF8.self)
                        if let val = UInt32(digitStr, radix: Int(radix)), val != 0, let valid = UnicodeScalar(val) {
                            scalar = valid
                        } else {
                            scalar = UnicodeScalar(0xFFFD)!
                        }
                    }
                    matched = (scalar, prefixLen + (cursor - digitsStart))
                }
            } else if bodyStart < bodyEnd {
                let name = String(decoding: bytes[bodyStart..<bodyEnd], as: UTF8.self).lowercased()
                if let c = namedEntities[name] {
                    matched = (c, bodyEnd - bodyStart)
                }
            }

            if let (ch, used) = matched {
                out.unicodeScalars.append(ch)
                i = amp + 1 + used
                if i < n && bytes[i] == 0x3B { // ';'
                    i += 1
                }
            } else {
                out.append("&")
                i = amp + 1
            }
        }

        if i < n {
            out.append(String(decoding: bytes[i..<n], as: UTF8.self))
        }
        return out
    }

    private static func isDigit(_ b: UInt8, radix: UInt32) -> Bool {
        if b >= 0x30 && b <= 0x39 { return true }
        if radix == 16 {
            return (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
        }
        return false
    }
}

// MARK: - Secret Clipboard Hold State Machine (crates/rune/src/clipboard/secret.rs)

/// Report stored inside `SecretMachine` distinguishing normal states from wipe refusal (`secret.rs:49`).
public enum SecretReport: Sendable, Equatable {
    case said(SecretState)
    case refused

    public var shown: SecretState {
        switch self {
        case .said(let state): return state
        case .refused: return .failed(SecretSlot.refusedWipeMessage)
        }
    }

    public var isFailedWrite: Bool {
        if case .said(.failed) = self { return true }
        return false
    }
}

/// Pure `Secret` state machine (`secret.rs:31`): tracks live vs cancelled status, latest report, and active hold count.
public enum SecretMachine: Sendable, Equatable {
    case live(report: SecretReport, holds: UInt32)
    case cancelled(report: SecretReport, holds: UInt32)

    public static var `default`: SecretMachine { .live(report: .said(.pending), holds: 0) }

    public var report: SecretReport {
        switch self {
        case .live(let report, _), .cancelled(let report, _): return report
        }
    }

    public var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

/// Event processed by `stepSecret(_:event:)` (`secret.rs:69`).
public enum SecretMachineEvent: Sendable, Equatable {
    case cancel
    case held
    case released(SecretReport)
    case report(SecretState)
    case dropped
}

/// Effect emitted by `stepSecret(_:event:)` (`secret.rs:83`).
public enum SecretMachineEffect: Sendable, Equatable {
    case clear
}

/// Pure transition function for `SecretMachine` (`secret.rs:88`).
public func stepSecret(_ secret: inout SecretMachine, event: SecretMachineEvent) -> [SecretMachineEffect] {
    switch event {
    case .cancel:
        let currentReport = secret.report
        let holds: UInt32
        switch secret {
        case .live(_, let h), .cancelled(_, let h): holds = h
        }
        let held = (currentReport == .said(.holding)) || (currentReport.isFailedWrite && holds > 0)
        secret = .cancelled(report: currentReport, holds: holds)
        return held ? [.clear] : []
    case .held:
        switch secret {
        case .live(_, let h):
            secret = .live(report: .said(.holding), holds: h &+ 1)
        case .cancelled(_, let h):
            secret = .cancelled(report: .said(.holding), holds: h &+ 1)
        }
        return []
    case .released(let next):
        switch secret {
        case .live(_, let h):
            secret = .live(report: next, holds: h > 0 ? h - 1 : 0)
        case .cancelled(_, let h):
            secret = .cancelled(report: next, holds: h > 0 ? h - 1 : 0)
        }
        return []
    case .report(let next):
        switch secret {
        case .live(_, let h):
            secret = .live(report: .said(next), holds: h)
        case .cancelled(_, let h):
            secret = .cancelled(report: .said(next), holds: h)
        }
        return []
    case .dropped:
        switch secret {
        case .live(.said(.pending), let h):
            secret = .live(report: .said(.replaced), holds: h)
        case .cancelled(.said(.pending), let h):
            secret = .cancelled(report: .said(.cleared), holds: h)
        default:
            break
        }
        return []
    }
}

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
    public enum WipeBehavior: Sendable, Equatable {
        case normal
        case refuse
        case noop
    }

    private let lock = NSLock()
    private var currentText: String?
    private var revision: UInt64 = 0
    private var heldAttempt: UInt64 = 0
    private weak var heldSlot: SecretSlot?
    private var heldRevision: UInt64?
    private var heldFingerprint: UInt64 = 0
    private var heldDueTime: Double?
    private var wipeBehavior: WipeBehavior = .normal
    private var unreadable: Bool = false
    private var failNextWriteMessage: String?
    public private(set) var wipeAttempts: Int = 0

    public init() {}

    /// True while a held copy is still watched for its scheduled timeout or external replacement.
    public var isWatching: Bool {
        lock.lock()
        defer { lock.unlock() }
        return heldSlot != nil && heldDueTime != nil
    }

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
        wipeBehavior = refuse ? .refuse : .normal
        lock.unlock()
    }

    public func setWipeBehavior(_ behavior: WipeBehavior) {
        lock.lock()
        wipeBehavior = behavior
        lock.unlock()
    }

    /// Simulates a temporarily unreadable clipboard so ownership checks fail and preserve the hold timeout.
    public func setUnreadable(_ unreadable: Bool) {
        lock.lock()
        self.unreadable = unreadable
        lock.unlock()
    }

    public func setFailNextWrite(_ message: String?) {
        lock.lock()
        failNextWriteMessage = message
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
        if let err = failNextWriteMessage {
            failNextWriteMessage = nil
            lock.unlock()
            slot.report(.failed(err))
            return SecretClipboardHold(slot: slot)
        }
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

        if prevSlot !== slot {
            prevSlot?.markReleased(.replaced)
        }
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
        if unreadable {
            lock.unlock()
            return
        }
        let target = heldSlot
        let stillOurs = isOursLocked()
        let behavior = wipeBehavior
        if behavior == .noop && stillOurs {
            // Wipe did nothing: hold and its timeout remain alive until a subsequent clear succeeds.
            lock.unlock()
            return
        }
        if stillOurs && behavior == .normal {
            currentText = nil
            revision &+= 1
            wipeAttempts &+= 1
        }
        heldSlot = nil
        heldRevision = nil
        heldDueTime = nil
        wipeBehavior = .normal
        lock.unlock()

        if !stillOurs {
            target?.markReleased(.replaced)
        } else if behavior == .refuse {
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
        if unreadable {
            lock.unlock()
            return
        }
        let stillOurs = isOursLocked()
        let behavior = wipeBehavior
        if behavior == .noop && stillOurs {
            // Failed/no-op clear leaves the hold & scheduled expiry intact (`hold_tests.rs:169`).
            lock.unlock()
            return
        }
        if stillOurs && behavior == .normal {
            currentText = nil
            revision &+= 1
            wipeAttempts &+= 1
        }
        heldSlot = nil
        heldRevision = nil
        heldDueTime = nil
        wipeBehavior = .normal
        lock.unlock()

        if !stillOurs {
            slot.markReleased(.replaced)
        } else if behavior == .refuse {
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
