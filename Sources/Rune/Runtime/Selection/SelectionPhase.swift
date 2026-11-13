import Foundation

/// Selection click granularity (`crates/rune/src/runtime/selection/selectable.rs`).
public enum SelectionUnit: Sendable, Equatable {
    case character
    case word
    case paragraph

    public static func forClickCount(_ clicks: Int) -> SelectionUnit {
        switch clicks {
        case ...1: return .character
        case 2: return .word
        default: return .paragraph
        }
    }
}

/// The focus endpoint of a cross-text selection within a `selectionGroup`
/// (`crates/rune/src/runtime/selection/phase.rs`).
public struct SelectionFar: Equatable, Sendable {
    public var path: String
    public var content: String

    public init(path: String, content: String) {
        self.path = path
        self.content = content
    }
}

/// Active anchor + focus range of a selectable-text selection (`phase.rs`).
public struct ActiveSelection: Equatable, Sendable {
    public var path: String
    public var content: String
    public var anchor: Int
    public var focus: Int
    public var originStart: Int
    public var originEnd: Int
    public var far: SelectionFar?
    public var betweenHash: UInt64

    public init(
        path: String,
        content: String,
        anchor: Int,
        focus: Int,
        origin: (Int, Int),
        far: SelectionFar? = nil,
        betweenHash: UInt64 = 0
    ) {
        self.path = path
        self.content = content
        self.anchor = anchor
        self.focus = focus
        self.originStart = origin.0
        self.originEnd = origin.1
        self.far = far
        self.betweenHash = betweenHash
    }

    public var origin: (Int, Int) { (originStart, originEnd) }
}

/// State machine phase for `El.selectable` selection (`crates/rune/src/runtime/selection/phase.rs`).
public enum SelectionPhase: Equatable, Sendable {
    case empty
    case placed(ActiveSelection)
    case dragging(ActiveSelection, unit: SelectionUnit)

    public var selection: ActiveSelection? {
        switch self {
        case .empty:
            return nil
        case .placed(let sel), .dragging(let sel, _):
            return sel
        }
    }

    public var isDragging: Bool {
        if case .dragging = self { return true }
        return false
    }

    public mutating func clear() {
        self = .empty
    }

    public mutating func startDrag(selection: ActiveSelection, unit: SelectionUnit) {
        self = .dragging(selection, unit: unit)
    }

    public mutating func updateDrag(focus: Int, far: SelectionFar? = nil) {
        guard case .dragging(var sel, let unit) = self else { return }
        if far == nil && sel.far == nil {
            let extended = SelectionMath.extendSelection(origin: sel.origin, at: (focus, focus))
            sel.anchor = extended.anchor
            sel.focus = extended.focus
        } else {
            sel.focus = focus
            sel.far = far
        }
        self = .dragging(sel, unit: unit)
    }

    public mutating func endDrag() {
        guard case .dragging(let sel, _) = self else { return }
        if sel.far == nil && sel.anchor == sel.focus {
            self = .empty
        } else {
            self = .placed(sel)
        }
    }

    public mutating func place(_ selection: ActiveSelection) {
        self = .placed(selection)
    }
}

/// Pure UTF-8 / keyed-path helpers ported from `crates/rune/src/runtime/selection/selectable.rs`.
public enum SelectionMath {
    /// True while `now` still matches `then` up to UTF-8 byte `upto` (`selectable.rs:188-191`).
    /// Appended text (e.g. streaming output) keeps an active selection intact.
    public static func kept(then: String, now: String, upto: Int) -> Bool {
        if upto <= 0 {
            return now.hasPrefix(then)
        }
        let tBytes = then.utf8
        let nBytes = now.utf8
        guard tBytes.count >= upto, nBytes.count >= upto else { return false }
        return tBytes.prefix(upto).elementsEqual(nBytes.prefix(upto))
    }

    /// True when paths `a` and `b` share the same keyed ancestry and unkeyed tail (`selectable.rs:211-220`),
    /// allowing keyed text to preserve its selection when an unkeyed sibling shifts index.
    public static func sameKeyedPath(_ a: String, _ b: String) -> Bool {
        func split(_ path: String) -> (keyPrefix: String, tail: String)? {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard let lastKeyIdx = parts.lastIndex(where: { isKeySegment($0) }) else {
                return nil
            }
            let keyPrefix = parts[...lastKeyIdx].joined(separator: "/")
            let tail = lastKeyIdx + 1 < parts.count
                ? "/" + parts[(lastKeyIdx + 1)...].joined(separator: "/")
                : ""
            return (keyPrefix, tail)
        }
        func isKeySegment(_ seg: Substring) -> Bool {
            !seg.isEmpty && seg.first != "#" && Int(seg) == nil
        }
        guard let pa = split(a), let pb = split(b), pa.tail == pb.tail else {
            return false
        }
        let ka = pa.keyPrefix.split(separator: "/").filter(isKeySegment)
        let kb = pb.keyPrefix.split(separator: "/").filter(isKeySegment)
        return ka.elementsEqual(kb)
    }

    /// Largest valid UTF-8 scalar boundary at or before `offset` (`floor_char_boundary`).
    public static func floorCharBoundary(in content: String, offset: Int) -> Int {
        let utf8 = content.utf8
        let len = utf8.count
        var pos = max(0, min(offset, len))
        if pos == 0 || pos == len { return pos }
        var idx = utf8.index(utf8.startIndex, offsetBy: pos)
        while pos > 0 && (utf8[idx] & 0xC0) == 0x80 {
            idx = utf8.index(before: idx)
            pos -= 1
        }
        return pos
    }

    /// Previous valid UTF-8 scalar boundary strictly before `offset` (clamped at 0).
    public static func prevCharBoundary(in content: String, offset: Int) -> Int {
        let i = floorCharBoundary(in: content, offset: offset)
        guard i > 0 else { return 0 }
        return floorCharBoundary(in: content, offset: i - 1)
    }

    /// Returns `(start, end)` UTF-8 byte offsets of the `unit` surrounding UTF-8 offset `at`
    /// (`crates/rune/src/runtime/selection/selectable.rs:67-109`).
    public static func unitRange(in content: String, at utf8Offset: Int, unit: SelectionUnit) -> (Int, Int) {
        let utf8 = content.utf8
        let len = utf8.count
        var i = floorCharBoundary(in: content, offset: utf8Offset)
        if i > 0 && i == len && unit != .character {
            i = prevCharBoundary(in: content, offset: i)
        }
        switch unit {
        case .character:
            return (i, i)
        case .paragraph:
            let bytes = Array(utf8)
            var start = i
            while start > 0 && bytes[start - 1] != UInt8(ascii: "\n") {
                start -= 1
            }
            var end = i
            while end < len && bytes[end] != UInt8(ascii: "\n") {
                end += 1
            }
            if end < len && bytes[end] == UInt8(ascii: "\n") {
                end += 1
            }
            return (start, end)
        case .word:
            guard len > 0 else { return (0, 0) }
            let bytes = Array(utf8)
            if i > 0 && i < len && (bytes[i] == UInt8(ascii: "\n") || bytes[i] == UInt8(ascii: "\r"))
                && bytes[i - 1] != UInt8(ascii: "\n")
            {
                i = prevCharBoundary(in: content, offset: i)
                if i > 0 && i < len && bytes[i] == UInt8(ascii: "\r") && bytes[i - 1] != UInt8(ascii: "\n") {
                    i = prevCharBoundary(in: content, offset: i)
                }
            }

            enum SpanKind { case word, whitespace, newline, punctuation }
            func classify(_ scalar: Unicode.Scalar) -> SpanKind {
                if scalar == "\n" || scalar == "\r" { return .newline }
                if CharacterSet.whitespaces.contains(scalar) { return .whitespace }
                if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" { return .word }
                return .punctuation
            }

            var spanStart = 0
            var spanKind: SpanKind? = nil
            var byteCursor = 0
            var foundTarget = false
            for scalar in content.unicodeScalars {
                let sLen = scalar.utf8.count
                let nextCursor = byteCursor + sLen
                let kind = classify(scalar)
                if foundTarget {
                    if kind != spanKind {
                        return (spanStart, byteCursor)
                    }
                } else {
                    let startsNewSpan: Bool
                    if let current = spanKind {
                        startsNewSpan = (kind != current) || kind == .punctuation || kind == .newline
                    } else {
                        startsNewSpan = false
                    }
                    if startsNewSpan {
                        spanStart = byteCursor
                    }
                    spanKind = kind
                    if i < nextCursor {
                        if kind == .punctuation || kind == .newline {
                            return (byteCursor, nextCursor)
                        }
                        foundTarget = true
                    }
                }
                byteCursor = nextCursor
            }
            return foundTarget ? (spanStart, len) : (len, len)
        }
    }

    /// Extends a single-text selection from `origin` to include `unitRange` while keeping `origin` whole
    /// (`crates/rune/src/runtime/selection/selectable.rs:117-123`).
    public static func extendSelection(origin: (Int, Int), at unitRange: (Int, Int)) -> (anchor: Int, focus: Int) {
        if unitRange.0 < origin.0 {
            return (origin.1, unitRange.0)
        } else {
            return (origin.0, max(unitRange.1, origin.1))
        }
    }
}
