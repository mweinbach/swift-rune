import Foundation

/// A point a line selection runs from or to (`rune_kit::line_selection::LinePoint`).
public protocol LinePoint: Hashable, Sendable {
    /// Whether one selection may run from `self` to `other`.
    func joins(with other: Self) -> Bool
}

extension Int: LinePoint {
    public func joins(with other: Int) -> Bool { true }
}

extension UInt32: LinePoint {
    public func joins(with other: UInt32) -> Bool { true }
}

/// Selected lines, from where the gesture started to where it ends (`rune_kit::line_selection::Lines`).
public struct LineRange<P: LinePoint>: Hashable, Sendable {
    public var start: P
    public var end: P

    public init(start: P, end: P) {
        self.start = start
        self.end = end
    }

    public static func line(_ at: P) -> LineRange<P> {
        LineRange(start: at, end: at)
    }
}

/// Where a press landed: the line numbers gutter or the code text (`rune_kit::line_selection::Column`).
public enum LineSelectionColumn: Sendable, Equatable, Hashable {
    case numbers
    case text
}

/// Event fed into `LineSelection.step(...)`.
public enum LineSelectionEvent<P: LinePoint>: Sendable, Equatable {
    case press(at: P, column: LineSelectionColumn, shift: Bool)
    case move(at: P)
    case release
    case cancel
    case set(LineRange<P>?)
}

/// Effect emitted when a line selection gesture completes.
public enum LineSelectionEffect<P: LinePoint>: Sendable, Equatable {
    case ended(LineRange<P>?)
}

/// Line-selection gesture state machine for code and diff views (`rune_kit::line_selection::LineSelection`).
public enum LineSelectionState<P: LinePoint>: Sendable, Equatable {
    case idle(selected: LineRange<P>?)
    case unselecting(line: LineRange<P>)
    case selecting(selected: LineRange<P>, before: LineRange<P>?)
    case pressing(origin: P, before: LineRange<P>?)
    case dragging(selected: LineRange<P>, before: LineRange<P>?)

    public var selected: LineRange<P>? {
        switch self {
        case .idle(let s): s
        case .unselecting(let line): line
        case .selecting(let s, _), .dragging(let s, _): s
        case .pressing(_, let before): before
        }
    }

    public var isTracking: Bool {
        if case .idle = self { return false }
        return true
    }

    @discardableResult
    public mutating func step(
        _ event: LineSelectionEvent<P>,
        rowOf: (P) -> UInt32? = { _ in nil }
    ) -> LineSelectionEffect<P>? {
        switch event {
        case .set(let selected):
            self = .idle(selected: selected)
            return nil

        case let .press(at, column, shift):
            let current = selected
            switch column {
            case .numbers:
                self = Self.pressNumber(current: current, at: at, shift: shift, rowOf: rowOf)
            case .text:
                self = .pressing(origin: at, before: current)
            }
            return nil

        case .move(let at):
            switch self {
            case .unselecting(let line) where line.start != at && line.start.joins(with: at):
                self = .selecting(selected: LineRange(start: line.start, end: at), before: line)
            case .selecting(let sel, let before) where sel.start.joins(with: at):
                self = .selecting(selected: LineRange(start: sel.start, end: at), before: before)
            case .pressing(let origin, let before) where origin != at && origin.joins(with: at):
                self = .dragging(selected: LineRange(start: origin, end: at), before: before)
            case .dragging(let sel, let before) where sel.start.joins(with: at):
                self = .dragging(selected: LineRange(start: sel.start, end: at), before: before)
            default:
                break
            }
            return nil

        case .release:
            let finalSelection: LineRange<P>?
            switch self {
            case .idle:
                return nil
            case .unselecting:
                finalSelection = nil
            case .selecting(let sel, _), .dragging(let sel, _):
                finalSelection = sel
            case .pressing(let origin, let before):
                let click = LineRange.line(origin)
                finalSelection = (before == click) ? nil : click
            }
            self = .idle(selected: finalSelection)
            return .ended(finalSelection)

        case .cancel:
            let before: LineRange<P>?
            switch self {
            case .idle:
                return nil
            case .unselecting(let line):
                before = line
            case .selecting(_, let b), .pressing(_, let b), .dragging(_, let b):
                before = b
            }
            self = .idle(selected: before)
            return nil
        }
    }

    private static func pressNumber(
        current: LineRange<P>?,
        at: P,
        shift: Bool,
        rowOf: (P) -> UInt32?
    ) -> LineSelectionState<P> {
        guard let current else {
            return .selecting(selected: .line(at), before: nil)
        }
        if current.start == at && current.end == at {
            return .unselecting(line: current)
        }
        if shift && current.start.joins(with: at) {
            let start = keepEnd(current: current, at: at, rowOf: rowOf)
            return .selecting(selected: LineRange(start: start, end: at), before: current)
        }
        return .selecting(selected: .line(at), before: current)
    }

    private static func keepEnd(current: LineRange<P>, at: P, rowOf: (P) -> UInt32?) -> P {
        guard let a = rowOf(current.start),
              let b = rowOf(current.end),
              let c = rowOf(at) else {
            return current.start
        }
        let lo = min(a, b)
        let hi = max(a, b)
        if c < lo {
            return a >= b ? current.start : current.end
        }
        if c > hi {
            return a <= b ? current.start : current.end
        }
        return (c - lo <= hi - c)
            ? (a >= b ? current.start : current.end)
            : (a <= b ? current.start : current.end)
    }
}

/// Convenience multi-line / single-range selection helper for `Int` line numbers (1-based).
public struct LineSelection: Sendable, Equatable, Hashable {
    public var ranges: [ClosedRange<Int>]

    public init(ranges: [ClosedRange<Int>] = []) {
        self.ranges = Self.normalize(ranges)
    }

    public init(_ range: ClosedRange<Int>) {
        self.ranges = [range]
    }

    public init(line: Int) {
        self.ranges = [line...line]
    }

    public var isEmpty: Bool { ranges.isEmpty }

    public func contains(_ line: Int) -> Bool {
        ranges.contains { $0.contains(line) }
    }

    public mutating func toggle(_ line: Int) {
        if contains(line) {
            var next: [ClosedRange<Int>] = []
            for r in ranges {
                if !r.contains(line) {
                    next.append(r)
                } else {
                    if r.lowerBound < line { next.append(r.lowerBound...(line - 1)) }
                    if line < r.upperBound { next.append((line + 1)...r.upperBound) }
                }
            }
            ranges = next
        } else {
            ranges = Self.normalize(ranges + [line...line])
        }
    }

    private static func normalize(_ input: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        let sorted = input.sorted { $0.lowerBound < $1.lowerBound }
        var out: [ClosedRange<Int>] = []
        for r in sorted {
            if let last = out.last, r.lowerBound <= last.upperBound + 1 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }
}
