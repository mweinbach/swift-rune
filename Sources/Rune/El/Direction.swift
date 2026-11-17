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

    /// Strong direction of an individual scalar, before paragraph and isolate handling.
    package static func ofStrongScalar(_ scalar: Unicode.Scalar) -> Direction? {
        switch BidiStrongClass.of(scalar) {
        case .strongL: return .ltr
        case .strongR: return .rtl
        default: return nil
        }
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

/// Resolve an inherited flow, explicit direction, or input's forced direction for this node.
internal func stepDirection<State>(parent: Flow, el: El<State>, state: State?) -> (flow: Flow, mirror: Bool) {
    let direction: Direction?
    if el.hasAuthoredHandlers, let state, let forced = el.handlers.editLens?.get(state).forcedDir {
        direction = forced == .rtl ? .rtl : .ltr
    } else {
        direction = el.explicitDir
    }
    let flow: Flow
    switch direction {
    case nil: flow = parent
    case .ltr?: flow = .ltr
    case .rtl?: flow = .rtl
    case .auto?:
        switch firstStrongDirection(in: el, state: state) {
        case .rtl?: flow = .rtl
        case .ltr?, .auto?: flow = .ltr
        case nil: flow = parent
        }
    }
    return (flow, flow == .rtl)
}

internal func containsStrongRTL(_ text: String) -> Bool {
    text.unicodeScalars.contains { !$0.isASCII && BidiStrongClass.isStrongRTL($0) }
}

internal func firstStrongDirection(in text: String, acrossParagraphs: Bool) -> Direction? {
    firstStrongDirection(in: text.unicodeScalars[...], acrossParagraphs: acrossParagraphs)
}

private func firstStrongDirection(in scalars: Substring.UnicodeScalarView, acrossParagraphs: Bool) -> Direction? {
    var isolates: UInt32 = 0
    for scalar in scalars {
        switch BidiStrongClass.of(scalar) {
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

/// A plaintext field reads its displayed paragraphs in order, skipping the labels of mention pills.
private func plaintextDirection(_ edit: TextEdit) -> Direction? {
    let text = edit.displayWithRichPreedit().text
    let bytes = text.utf8
    let scalars = text.unicodeScalars
    var at = scalars.startIndex
    for pill in edit.displayPills() {
        let start = bytes.index(bytes.startIndex, offsetBy: pill.range.lowerBound)
        let end = bytes.index(bytes.startIndex, offsetBy: pill.range.upperBound)
        guard start.samePosition(in: scalars) != nil, end.samePosition(in: scalars) != nil else { continue }
        if at < start, let dir = firstStrongDirection(in: scalars[at..<start], acrossParagraphs: true) {
            return dir
        }
        at = max(at, end)
    }
    return firstStrongDirection(in: scalars[at...], acrossParagraphs: true)
}

internal func firstStrongDirection<State>(in el: El<State>, state: State?) -> Direction? {
    if el.textDirByParagraph, let state, let edit = el.handlers.editLens?.get(state) {
        guard !el.isSecure, !edit.isSecure else { return nil }
        return plaintextDirection(edit)
    }
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
    if let state, let edit = el.handlers.editLens?.get(state), !edit.isSecure {
        let source = edit.text.isEmpty ? (el.placeholder ?? "") : edit.text
        if let d = Direction.of(source) {
            return d
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
