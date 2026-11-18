import Foundation
import RuneMotion

// MARK: - Scroll Spec, Fade & Callbacks (`crates/rune/src/el/scroll.rs`)

/// Vertical scroll viewport configuration (`El::scroll`).
public struct ScrollSpec: Sendable, Hashable {
    public var stickBottom: Bool

    public init(stickBottom: Bool = false) {
        self.stickBottom = stickBottom
    }

    public static let `default` = ScrollSpec(stickBottom: false)
}

/// How the end edge (bottom or right) fades when customized via `ScrollFade.withEnd`.
public struct ScrollFadeEnd: Sendable, Hashable {
    public var width: Float
    public var linear: Bool
    public var fullAt: Float

    public init(width: Float, linear: Bool = false, fullAt: Float = 0) {
        self.width = max(0, width)
        self.linear = linear
        self.fullAt = fullAt
    }
}

/// Internal style bits for `ScrollFade`.
public struct ScrollFadeStyle: Sendable, Hashable {
    public var feather: Bool
    public var linear: Bool
    public var belowSticky: Bool
    public var endOnly: Bool
    public var fullAt: Float
    public var end: ScrollFadeEnd?

    public init(
        feather: Bool = false,
        linear: Bool = false,
        belowSticky: Bool = false,
        endOnly: Bool = false,
        fullAt: Float = 0,
        end: ScrollFadeEnd? = nil
    ) {
        self.feather = feather
        self.linear = linear
        self.belowSticky = belowSticky
        self.endOnly = endOnly
        self.fullAt = fullAt
        self.end = end
    }

    public static let smooth = ScrollFadeStyle()

    public func edge(width: Float, end isEnd: Bool) -> (ScrollFadeStyle, Float) {
        if isEnd, let e = end {
            var next = self
            next.linear = e.linear
            next.fullAt = e.fullAt
            next.end = nil
            return (next, e.width)
        }
        return (self, width)
    }
}

/// How a scroll viewport's edges fade with the content hidden under them (`El.scrollFade`).
public struct ScrollFade: Sendable, Hashable {
    public var width: Float
    public var style: ScrollFadeStyle

    public init(width: Float, style: ScrollFadeStyle = .smooth) {
        self.width = max(0, width)
        self.style = style
    }

    public static func strength(_ width: Float) -> ScrollFade {
        ScrollFade(width: max(0, width), style: .smooth)
    }

    public static func feather(_ maxWidth: Float) -> ScrollFade {
        ScrollFade(width: max(0, maxWidth), style: ScrollFadeStyle(feather: true, linear: true))
    }

    public func fullAt(_ points: Float) -> ScrollFade {
        var copy = self
        copy.style.fullAt = max(0.01, points)
        return copy
    }

    public func endOnly() -> ScrollFade {
        var copy = self
        copy.style.endOnly = true
        return copy
    }

    public func linear() -> ScrollFade {
        var copy = self
        copy.style.linear = true
        return copy
    }

    public func belowSticky() -> ScrollFade {
        var copy = self
        copy.style.belowSticky = true
        return copy
    }

    public func withEnd(_ end: ScrollFade) -> ScrollFade {
        var copy = self
        copy.style.end = ScrollFadeEnd(width: end.width, linear: end.style.linear, fullAt: end.style.fullAt)
        return copy
    }
}

/// Scroll viewport metrics passed to `El.onScrollOffset` (`el/layout_watch.rs::ScrollPos`).
public struct ScrollPos: Sendable, Equatable {
    public var offset: Vec2
    public var max: Vec2
    public var viewport: Vec2
    public var drawn: Vec2
    public var direction: TextBaseDirection

    public init(
        offset: Vec2 = .zero,
        max: Vec2 = .zero,
        viewport: Vec2 = .zero,
        drawn: Vec2 = .zero,
        direction: TextBaseDirection = .ltr
    ) {
        self.offset = offset
        self.max = max
        self.viewport = viewport
        self.drawn = drawn
        self.direction = direction
    }
}

// MARK: - Sticky Element Config (`crates/rune/src/el/sticky.rs`)

internal struct StickyConfig: Sendable, Hashable {
    var edge: StickyEdge? = nil
    var inset: Float = 0
    var tail: Bool = false
    var shadows: [Shadow] = []
    var fade: (lead: Float, span: Float)? = nil
    var reveal: Float? = nil

    static func == (lhs: StickyConfig, rhs: StickyConfig) -> Bool {
        lhs.edge == rhs.edge
            && lhs.inset == rhs.inset
            && lhs.tail == rhs.tail
            && lhs.shadows == rhs.shadows
            && lhs.fade?.lead == rhs.fade?.lead
            && lhs.fade?.span == rhs.fade?.span
            && lhs.reveal == rhs.reveal
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(edge)
        hasher.combine(inset)
        hasher.combine(tail)
        hasher.combine(shadows)
        hasher.combine(fade?.lead)
        hasher.combine(fade?.span)
        hasher.combine(reveal)
    }
}

// MARK: - Growth Spec & Fold Glide (`crates/rune/src/growth.rs`)

/// Growth stack configuration (`El.growth`).
public struct GrowthSpec: Sendable, Hashable {
    public var spring: Spring
    public var edge: StreamEdge

    public init(spring: Spring = GrowthCaps.growthSpring, edge: StreamEdge = .feather) {
        self.spring = spring
        self.edge = edge
    }

    public static let `default` = GrowthSpec()
}

// MARK: - Index-Built Virtual Row Source (`crates/rune/src/el/virtual_rows.rs`)

// A projection retains both the geometry and the exact immutable root that authored it.
struct VirtualRowLayout<State> {
    let children: MemoLayoutChildren<State>
    let owner: AnyObject
}

/// A virtual row returned by its builder. Only a memo that owns the entire element can
/// certify its root across builds. An ordinary El may have new root modifiers each time.
package struct VirtualRowContent<State> {
    let element: El<State>
    let owner: AnyObject?
    let layoutProjection: VirtualRowLayout<State>?

    package init(_ element: El<State>) {
        self.element = element
        owner = nil
        layoutProjection = nil
    }

    init(memoized element: El<State>, owner: AnyObject, layoutProjection: VirtualRowLayout<State>? = nil) {
        self.element = element
        self.owner = owner
        self.layoutProjection = layoutProjection
    }
}

internal final class VirtualRowSource<State> {
    let count: Int
    let byteExactKeys: Bool
    let key: (State, Int) -> String
    let buildContent: (State, Int) -> VirtualRowContent<State>

    convenience init(
        count: Int,
        byteExactKeys: Bool = false,
        key: @escaping (State, Int) -> String,
        build: @escaping (State, Int) -> El<State>
    ) {
        self.init(count: count, byteExactKeys: byteExactKeys, key: key,
                  buildContent: { VirtualRowContent(build($0, $1)) })
    }

    init(count: Int, byteExactKeys: Bool, key: @escaping (State, Int) -> String,
         buildContent: @escaping (State, Int) -> VirtualRowContent<State>) {
        self.count = max(0, count)
        self.byteExactKeys = byteExactKeys
        self.key = key
        self.buildContent = buildContent
    }

    func build(_ state: State, _ index: Int) -> El<State> {
        buildContent(state, index).element
    }

    func keyed(_ row: El<State>, storageKey: String) -> El<State> {
        var keyed = row
        keyed.assignStoredKey(storageKey, authored: VirtualRowKeyEncoding.authoredKey(storageKey))
        return keyed
    }
}
