import Foundation
import Rune

// MARK: - Lazy TabStrip band (`rune_kit::shell::tab_strip`, #1020)

/// What a strip knows of a tab it may not build (`TabStrip.lazyTabs`): its id, and what sets its
/// length along the strip and keeps it built (`rune_kit::shell::TabSlot`).
public struct TabSlot: Sendable, Equatable, Hashable {
    public var id: String
    public var pinned: Bool
    /// It has a subtitle (`StripTabItem.subtitle`): a vertical row of 45 points.
    public var twoLine: Bool
    /// Built wherever the strip has scrolled: its menu is open, or it's being renamed.
    public var keep: Bool

    public init(id: String, pinned: Bool = false, twoLine: Bool = false, keep: Bool = false) {
        self.id = id
        self.pinned = pinned
        self.twoLine = twoLine
        self.keep = keep
    }
}

/// Past this many tabs a strip builds only those near what it shows (`TabStrip.lazyTabs`,
/// `rune_kit::shell::BAND_PAST`).
public let BAND_PAST: Int = 40

enum TabStripBand {
    /// A vertical row with a subtitle (`two_line_height`).
    static let twoLineHeight: Float = 45.0
    /// The smallest step the band reads the scroll position in (`along.max(64.0)`).
    static let minStep: Float = 64.0
    /// Tab pitches per step: 4 across a horizontal strip, 6 rows down a vertical one.
    static let horizontalStepTabs: Float = 4.0
    static let verticalStepRows: Float = 6.0
    /// Band length before the first layout: a vertical strip's, and a horizontal strip's when it
    /// was given no viewport width.
    static let verticalFallback: Float = 1200.0
    static let horizontalFallback: Float = 2000.0

    /// Rust's saturating `f32 as i32`: NaN is 0 and out-of-range values clamp.
    static func saturatingInt(_ x: Float) -> Int {
        if x.isNaN { return 0 }
        if x >= Float(Int32.max) { return Int(Int32.max) }
        if x <= Float(Int32.min) { return Int(Int32.min) }
        return Int(x)
    }

    /// The stretch of the strip whose tabs are built, in points along it from its first tab: what
    /// the scroll viewport shows, rounded out to whole steps of `step` and a step more each side.
    /// The view reads where the list is scrolled to in those steps, so a scroll runs it once a
    /// step, not every frame; before the first layout it's the strip's start and `fallback` long
    /// (`tab_strip::band`).
    static func band(listKey: String, scrollKey: String, vertical: Bool, step: Float, fallback: Float) -> (lo: Float, hi: Float) {
        let a = vertical ? 1 : 0
        let start: Float? = Rune.layoutWith(listKey) { r in r[a] }
        let at: Int = start.flatMap { start in
            Rune.windowLayoutWith(listKey) { w in saturatingInt(((start - w[a]) / step).rounded(.down)) }
        } ?? 0
        let shows: Int = Rune.layoutWith(scrollKey) { r in saturatingInt((r[2 + a] / step).rounded(.up)) }
            ?? saturatingInt((fallback / step).rounded(.up))
        return (Float(at - 1) * step, Float(at + 2 + shows) * step)
    }

    /// Which tabs are built: past `BAND_PAST`, those whose stretch (`pitches`) meets `band`, and
    /// the ones a gesture, a key or a menu is on wherever they are: the first, the last, the
    /// active and dragged tabs, those either side of the incoming tab's landing slot, and every
    /// `keep` or pinned slot. `nil` when every tab is built.
    static func built(
        slots: [TabSlot],
        pitches: [Float],
        band: (lo: Float, hi: Float),
        active: String?,
        dragging: Int?,
        landing: Int?
    ) -> [Bool] {
        let count = slots.count
        var start: Float = 0
        var built: [Bool] = pitches.map { p in
            let near = start < band.hi && start + p > band.lo
            start += p
            return near
        }
        var keep: [Int?] = [0, count - 1, slots.firstIndex { active == $0.id }, dragging]
        if let s = landing {
            keep.append(s > 0 ? s - 1 : nil)
            keep.append(s)
        }
        for case let i? in keep where built.indices.contains(i) {
            built[i] = true
        }
        for (i, t) in slots.enumerated() where t.keep || t.pinned {
            built[i] = true
        }
        return built
    }
}
