import Foundation
import RuneMotion

/// Layout and reading direction for a subtree (`crates/rune/src/el/direction.rs`), matching HTML's `dir` attribute.
public enum Direction: Int, Sendable, Hashable, Codable {
    /// Left to right (or an LTR island inside an RTL subtree).
    case ltr = 0
    /// Right to left: Arabic, Hebrew, Persian, Urdu.
    case rtl = 1
    /// Resolved from the first strong character of the element's text (or descendants without their own `dir`).
    case auto = 2

    /// Whether this direction is `.rtl`.
    public var isRtl: Bool { self == .rtl }

    /// Direction of `text`'s first strong character outside UAX #9 directional isolates (rules P2 & P3),
    /// stopping at paragraph separators, or `nil` when none exists.
    public static func of(_ text: String) -> Direction? {
        firstStrongDirection(in: text, acrossParagraphs: false)
    }
}

/// Resolved concrete flow direction for an element after `Direction.auto` and inheritance settle.
internal enum Flow: Int, Sendable, Hashable {
    case ltr = 0
    case rtl = 1

    var textFlow: TextFlow { self == .rtl ? .rtl : .ltr }
    var baseDirection: TextBaseDirection { self == .rtl ? .rtl : .ltr }
}

/// Physical vs flowing child placement inside an RTL parent (`El.unmirrored()`).
internal enum DirPin: Int, Sendable, Hashable {
    case flowing = 0
    case physical = 1

    static func of<State>(_ el: El<State>) -> DirPin {
        el.isUnmirrored ? .physical : .flowing
    }
}

/// Per-element direction specification (`El.dir`, `TextEdit.forcedDir`).
internal enum DirEvent<State> {
    case inherit
    case set(Flow)
    case auto(El<State>)

    static func of(_ el: El<State>, state: State?) -> DirEvent<State> {
        if let s = state, let lens = el.handlers.editLens, let forced = lens.get(s).forcedDir {
            return .set(forced == .rtl ? .rtl : .ltr)
        }
        switch el.explicitDir {
        case nil: return .inherit
        case .ltr?: return .set(.ltr)
        case .rtl?: return .set(.rtl)
        case .auto?: return .auto(el)
        }
    }
}

/// Steps parent `Flow` + `DirEvent` into the element's resolved `(flow, mirror)`.
internal func stepDirection<State>(
    parent: Flow,
    event: DirEvent<State>,
    state: State?
) -> (flow: Flow, mirror: Bool) {
    let flow: Flow
    switch event {
    case .inherit:
        flow = parent
    case .set(let f):
        flow = f
    case .auto(let el):
        switch firstStrongDirection(in: el, state: state) {
        case .rtl?: flow = .rtl
        case .ltr?, .auto?: flow = .ltr
        case nil: flow = parent
        }
    }
    return (flow, flow == .rtl)
}

private enum BidiStrongClass {
    case lriOrRliOrFsi
    case pdi
    case paragraphSeparator
    case strongL
    case strongR
    case neutral
}

internal func containsStrongRTL(_ text: String) -> Bool {
    text.unicodeScalars.contains { bidiClass(of: $0) == .strongR }
}

private func bidiClass(of scalar: Unicode.Scalar) -> BidiStrongClass {
    let v = scalar.value
    switch v {
    case 0x2066, 0x2067, 0x2068:
        return .lriOrRliOrFsi
    case 0x2069:
        return .pdi
    case 0x000A, 0x000D, 0x001C...0x001E, 0x0085, 0x2029:
        return .paragraphSeparator
    case 0x0590...0x08FF,
         0x200F,
         0xFB1D...0xFDFF,
         0xFE70...0xFEFF,
         0x10800...0x10FFF,
         0x1E800...0x1EEFF:
        // Distinguish Eastern Arabic/Indo-Arabic digits inside 0x0660...0x0669 / 0x06F0...0x06F9 & punctuation which are weak/AN/EN
        switch v {
        case 0x0600...0x0605, 0x060C, 0x061B, 0x061F, 0x0640,
             0x064B...0x065F, 0x0660...0x066D, 0x0670,
             0x06D6...0x06ED, 0x06F0...0x06F9, 0x0591...0x05C7:
            return .neutral
        default:
            return .strongR
        }
    default:
        // Common strong LTR scripts & letters (ASCII letters, Latin, Greek, Cyrillic, Armenian, Georgian, CJK, Hangul, Kana, Indic, SE Asian, etc.)
        if (v >= 0x0041 && v <= 0x005A) || (v >= 0x0061 && v <= 0x007A) {
            return .strongL
        }
        if (v >= 0x00C0 && v <= 0x058F) && v != 0x00D7 && v != 0x00F7 {
            return .strongL
        }
        if (v >= 0x0900 && v <= 0x1FFF) || (v >= 0x2C00 && v <= 0xD7FF) || (v >= 0xF900 && v <= 0xFAFF) || (v >= 0x1F000 && v <= 0x1FFFF && (v < 0x1E800 || v > 0x1EEFF)) {
            if v >= 0x1F000 { return .neutral } // emoji are neutral ON
            return .strongL
        }
        if v == 0x200E || (v >= 0x2100 && v <= 0x218F && (v == 0x2102 || v == 0x2107 || (v >= 0x210A && v <= 0x2113) || v == 0x2115 || (v >= 0x2119 && v <= 0x211D) || v == 0x2124 || v == 0x2126 || v == 0x2128 || (v >= 0x212A && v <= 0x2139))) {
            return .strongL
        }
        if (v >= 0xFF21 && v <= 0xFF3A) || (v >= 0xFF41 && v <= 0xFF5A) || (v >= 0xFF66 && v <= 0xFFDC) {
            return .strongL
        }
        return .neutral
    }
}

internal func firstStrongDirection(in text: String, acrossParagraphs: Bool) -> Direction? {
    var isolates: UInt32 = 0
    for scalar in text.unicodeScalars {
        switch bidiClass(of: scalar) {
        case .lriOrRliOrFsi:
            isolates += 1
        case .pdi:
            if isolates > 0 { isolates -= 1 }
        case .paragraphSeparator:
            if acrossParagraphs {
                isolates = 0
            } else if isolates == 0 {
                return nil
            }
        case .strongL where isolates == 0:
            return .ltr
        case .strongR where isolates == 0:
            return .rtl
        default:
            break
        }
    }
    return nil
}

internal func firstStrongDirection<State>(in el: El<State>, state: State?) -> Direction? {
    if let content = el.plainText ?? el.liveText?.get(),
       let d = Direction.of(content) {
        return d
    }
    if let spans = el.richSpans {
        let joined = spans.map(\.text).joined()
        if el.textDirByParagraph {
            if let d = firstStrongDirection(in: joined, acrossParagraphs: true) {
                return d
            }
        } else if let d = Direction.of(joined) {
            return d
        }
    }
    if let s = state, let lens = el.handlers.editLens {
        let edit = lens.get(s)
        if !edit.isSecure {
            let source = edit.text.isEmpty ? (el.placeholder ?? "") : edit.text
            if el.textDirByParagraph {
                // Plaintext input skips mentions when empty? In Swift placeholder applies if empty.
                if let d = firstStrongDirection(in: edit.text.isEmpty ? "" : source, acrossParagraphs: true) {
                    return d
                }
            } else if let d = Direction.of(source) {
                return d
            }
        }
    }
    for child in el.children where child.explicitDir == nil {
        if let d = firstStrongDirection(in: child, state: state) {
            return d
        }
    }
    return nil
}

/// Splits `text` into UTF-8 byte ranges for paragraphs separated by newline (`\r\n`, `\n`, `\r`, `\u{2029}`).
internal func splitParagraphUTF8Ranges(_ text: String) -> [Range<Int>] {
    let bytes = Array(text.utf8)
    var out: [Range<Int>] = []
    var start = 0
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        if b == 0x0D { // \r or \r\n
            out.append(start..<i)
            i += 1
            if i < bytes.count && bytes[i] == 0x0A {
                i += 1
            }
            start = i
        } else if b == 0x0A { // \n
            out.append(start..<i)
            i += 1
            start = i
        } else if i + 2 < bytes.count && b == 0xE2 && bytes[i + 1] == 0x80 && bytes[i + 2] == 0xA9 { // U+2029
            out.append(start..<i)
            i += 3
            start = i
        } else {
            i += 1
        }
    }
    out.append(start..<bytes.count)
    return out
}

/// Mirrors `El`'s own horizontal visuals in RTL (`mirror_visual` in `direction.rs:232-266`):
/// corner radii, `borderSides`, `clipCorners`, `clipFade`, `linearGradient`, and `mirrorInRtl` rotation.
internal func mirrorElVisual<State>(_ el: inout El<State>) {
    if el.layout.padding.left != el.layout.padding.right {
        swap(&el.layout.padding.left, &el.layout.padding.right)
    }
    let c = el.corners
    if c.topLeft != c.topRight || c.bottomLeft != c.bottomRight {
        el.corners = Corners(c.topRight, c.topLeft, c.bottomLeft, c.bottomRight)
    }
    if el.mirrorInRtl {
        if el.rotate != 0 {
            el.rotate = -el.rotate
        }
        if el.iconRotation != 0 {
            el.iconRotation = -el.iconRotation
        }
    }
    if let grad = el.gradient, case let .linear(top, bottom, angle) = grad {
        // Flip horizontal gradient axis while keeping vertical orientation (`pi/2 -> pi/2`, `0 -> pi`).
        el.gradient = .linear(top: top, bottom: bottom, angleRadians: .pi - angle)
    }
    if let b = el.borderSides, b.left != b.right {
        el.borderSides = Sides(top: b.top, right: b.left, bottom: b.bottom, left: b.right)
    }
    if let cf = el.clipFade, cf.x != cf.z {
        el.clipFade = SIMD4<Float>(cf.z, cf.y, cf.x, cf.w)
    }
    if let cc = el.clipCorners, cc.topLeft != cc.topRight || cc.bottomLeft != cc.bottomRight {
        el.clipCorners = Corners(cc.topRight, cc.topLeft, cc.bottomLeft, cc.bottomRight)
    }
}

/// Mirrors an anchored overlay's side/align for RTL (`mirror_anchor` in `direction.rs:269-282`).
internal func mirrorAnchor(_ anchor: Anchor) -> Anchor {
    var out = anchor
    switch anchor.side {
    case .left: out.side = .right
    case .right: out.side = .left
    case .top, .bottom: break
    }
    if out.side == .top || out.side == .bottom {
        switch anchor.align {
        case .start: out.align = .end
        case .end: out.align = .start
        case .center: break
        }
    }
    return out
}

/// Splits `spans` on paragraph breaks (`\r\n`, `\n`, `\r`, `\u{2029}`) into per-paragraph span arrays.
internal func splitRichSpansIntoParagraphs(_ spans: [TextSpan]) -> [[TextSpan]] {
    let joined = spans.map(\.text).joined()
    let ranges = splitParagraphUTF8Ranges(joined)
    guard ranges.count >= 2 else { return [spans] }
    var paragraphs: [[TextSpan]] = Array(repeating: [], count: ranges.count)
    var spanIdx = 0
    var spanOffset = 0
    let spanBytesList = spans.map { Array($0.text.utf8) }
    var globalCursor = 0

    for (pIdx, pRange) in ranges.enumerated() {
        // Advance past separator between previous paragraph and pRange.lowerBound
        while globalCursor < pRange.lowerBound, spanIdx < spans.count {
            let avail = spanBytesList[spanIdx].count - spanOffset
            let take = min(avail, pRange.lowerBound - globalCursor)
            spanOffset += take
            globalCursor += take
            if spanOffset >= spanBytesList[spanIdx].count {
                spanIdx += 1
                spanOffset = 0
            }
        }
        while globalCursor < pRange.upperBound, spanIdx < spans.count {
            let avail = spanBytesList[spanIdx].count - spanOffset
            let take = min(avail, pRange.upperBound - globalCursor)
            if take > 0 {
                let sliceBytes = spanBytesList[spanIdx][spanOffset..<(spanOffset + take)]
                var subSpan = spans[spanIdx]
                subSpan.text = String(decoding: sliceBytes, as: UTF8.self)
                paragraphs[pIdx].append(subSpan)
            }
            spanOffset += take
            globalCursor += take
            if spanOffset >= spanBytesList[spanIdx].count {
                spanIdx += 1
                spanOffset = 0
            }
        }
        if paragraphs[pIdx].isEmpty, let first = spans.first {
            var emptySpan = first
            emptySpan.text = ""
            paragraphs[pIdx].append(emptySpan)
        }
    }
    return paragraphs
}
