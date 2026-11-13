import Foundation

/// A growth stack whose width changed: its rows measure at the new width at once,
/// but their new heights wait until the width is stable, and a streaming row
/// shrinks only a while after (`crates/rune/src/runtime/types.rs:472`).
public enum WidthHold: Equatable, Sendable {
    case off
    /// Heights wait until `until`; a streaming row may shrink from `shrinkFrom`.
    case rewrap(until: Double, shrinkFrom: Double)

    /// Seconds new heights wait after a width change (`WidthHold::HOLD`).
    public static let hold: Double = 0.12
    /// Seconds a streaming row keeps its height after a width change before shrinking (`WidthHold::SHRINK`).
    public static let shrink: Double = 0.4

    /// The width changed at `now` (`WidthHold::rewrap`).
    public static func rewrap(at now: Double) -> WidthHold {
        .rewrap(until: now + hold, shrinkFrom: now + shrink)
    }

    /// Whether a height set at `at` waits for the width to settle (`WidthHold::defers`).
    public func defers(at time: Double) -> Bool {
        if case let .rewrap(until, _) = self {
            return time < until
        }
        return false
    }

    /// Whether a streaming row may shrink at `now` (`WidthHold::may_shrink`).
    public func mayShrink(at now: Double) -> Bool {
        if case let .rewrap(_, shrinkFrom) = self {
            return now >= shrinkFrom
        }
        return true
    }
}

/// Per-`growth(...)` stack state for width-change rewrap deferral and content slides (`RowStack` in `types.rs`).
internal struct RuntimeGrowthStackState: Sendable {
    var width: Float
    var widthHold: WidthHold
    var pendingHeights: [String: Float] = [:]
    var slides: ContentSlides = ContentSlides()

    init(
        width: Float,
        widthHold: WidthHold = .off,
        pendingHeights: [String: Float] = [:],
        slides: ContentSlides = ContentSlides()
    ) {
        self.width = width
        self.widthHold = widthHold
        self.pendingHeights = pendingHeights
        self.slides = slides
    }
}
