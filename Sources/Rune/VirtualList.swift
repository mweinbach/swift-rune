import Foundation
import RuneMotion

// MARK: - Timeline Growth & Streaming Edge (`rune::growth`)

/// One streaming-edge variant (`rune::growth::StreamEdge`).
public struct StreamEdge: Sendable, Hashable {
    public var name: String
    /// Largest feather height in points.
    public var maskMax: Float
    /// Smallest feather height while growing in points.
    public var floor: Float
    /// How fast the feather shrinks back (points per second).
    public var shrink: Float
    /// Multiplier on the near-target slowdown cap.
    public var catchUp: Float
    /// Multiplier on the growth spring's duration.
    public var duration: Float
    /// Clip the row at its presented height.
    public var clip: Bool
    /// Allow streaming row to overflow into reserved space below.
    public var overflow: Bool
    /// Word fade-in duration in seconds (0 = words appear at once).
    public var wordFade: Float

    public init(
        name: String,
        maskMax: Float,
        floor: Float,
        shrink: Float,
        catchUp: Float,
        duration: Float,
        clip: Bool,
        overflow: Bool,
        wordFade: Float
    ) {
        self.name = name
        self.maskMax = maskMax
        self.floor = floor
        self.shrink = shrink
        self.catchUp = catchUp
        self.duration = duration
        self.clip = clip
        self.overflow = overflow
        self.wordFade = wordFade
    }

    public static let feather = StreamEdge(
        name: "feather",
        maskMax: 28.0,
        floor: 18.0,
        shrink: 1.8 * 60.0,
        catchUp: 1.0,
        duration: 1.0,
        clip: true,
        overflow: false,
        wordFade: 0.18
    )

    public static let fastFeather = StreamEdge(
        name: "fast-feather",
        maskMax: 12.0,
        floor: 6.0,
        shrink: 4.0 * 60.0,
        catchUp: 2.4,
        duration: 0.55,
        clip: true,
        overflow: false,
        wordFade: 0.18
    )

    public static let noMask = StreamEdge(
        name: "no-mask",
        maskMax: 0.0,
        floor: 0.0,
        shrink: 28.0 * 60.0,
        catchUp: 1.0,
        duration: 1.0,
        clip: false,
        overflow: false,
        wordFade: 0.0
    )

    public static let wordFade = StreamEdge(
        name: "word-fade",
        maskMax: 0.0,
        floor: 0.0,
        shrink: 28.0 * 60.0,
        catchUp: 1.0,
        duration: 1.0,
        clip: false,
        overflow: false,
        wordFade: 0.36
    )

    public static let all: [StreamEdge] = [.feather, .fastFeather, .noMask, .wordFade]
}

/// Growth spring constants (`rune::growth::caps` & `GROWTH`).
public enum GrowthCaps {
    public static let growthSpring = Spring(duration: 0.32, bounce: 0.0)
    public static let wholeReach: Float = 300.0
    public static let start: Float = 1.875 * 60.0
    public static let rampPerSecond: Float = 28.2
    public static let max: Float = 11.5 * 60.0
    public static let maxLong: Float = 16.0 * 60.0
    public static let longDistance: Float = 240.0
    public static let carryingTail: Float = 7.5 * 60.0
    public static let near: Float = 36.0
    public static let maskGrow: Float = 5.0 * 60.0
    public static let maxDecel: Float = 1800.0
    public static let approach: Float = 14.0
    public static let approachMin: Float = 3.0
    public static let fixedSubstep: Double = 1.0 / 240.0
}

/// Integrates a growing row's presented height on fixed 1/240s substeps with speed & deceleration caps.
public struct GrowthRowState: Sendable, Equatable {
    public var targetHeight: Float
    public var presentedHeight: Float
    public var velocity: Float
    public var maskHeight: Float
    public var edge: StreamEdge
    public var isStreaming: Bool
    private var accumulator: Double = 0

    public init(
        targetHeight: Float = 0,
        presentedHeight: Float = 0,
        velocity: Float = 0,
        maskHeight: Float = 0,
        edge: StreamEdge = .feather,
        isStreaming: Bool = false
    ) {
        self.targetHeight = targetHeight
        self.presentedHeight = presentedHeight
        self.velocity = velocity
        self.maskHeight = maskHeight
        self.edge = edge
        self.isStreaming = isStreaming
    }

    public var isSettled: Bool {
        abs(targetHeight - presentedHeight) < 0.25 && abs(velocity) < 1.0 && maskHeight <= 0.1
    }

    /// Advances the growth spring by `dt` seconds using fixed `1/240s` substeps.
    public mutating func step(dt: Double) {
        guard dt > 0 else { return }
        accumulator += min(dt, 0.1)
        let h = Float(GrowthCaps.fixedSubstep)
        let dur = max(0.05, Float(GrowthCaps.growthSpring.duration) * edge.duration)
        let omega = 2.0 * Float.pi / dur

        while accumulator >= GrowthCaps.fixedSubstep {
            accumulator -= GrowthCaps.fixedSubstep
            let diff = targetHeight - presentedHeight
            let dist = abs(diff)

            if dist < 0.05 && abs(velocity) < 0.5 {
                presentedHeight = targetHeight
                velocity = 0
            } else {
                // Critically damped spring acceleration: a = omega^2 * diff - 2 * omega * v
                let accel = (omega * omega) * diff - 2.0 * omega * velocity
                var nextV = velocity + accel * h

                // Speed cap based on distance & near-target approach
                let maxCap = dist > GrowthCaps.longDistance ? GrowthCaps.maxLong : GrowthCaps.max
                let approachCap = (dist * GrowthCaps.approach + GrowthCaps.approachMin) * edge.catchUp
                let speedCap = min(maxCap, max(GrowthCaps.start, approachCap))

                if abs(nextV) > speedCap {
                    let sign: Float = nextV >= 0 ? 1 : -1
                    let decel = min(abs(nextV) - speedCap, GrowthCaps.maxDecel * h)
                    nextV = sign * (abs(nextV) - decel)
                }

                velocity = nextV
                presentedHeight = max(0, presentedHeight + velocity * h)
            }

            // Update streaming feather mask height
            if isStreaming && presentedHeight < targetHeight - 0.5 {
                let desiredMask = min(edge.maskMax, max(edge.floor, targetHeight - presentedHeight))
                if maskHeight < desiredMask {
                    maskHeight = min(desiredMask, maskHeight + GrowthCaps.maskGrow * h)
                } else {
                    maskHeight = max(desiredMask, maskHeight - edge.shrink * h)
                }
            } else {
                maskHeight = max(0, maskHeight - edge.shrink * h)
            }
        }
    }

    /// Snap immediately to target (e.g. under Reduce Motion or `Tx.settle()`).
    public mutating func settle() {
        presentedHeight = targetHeight
        velocity = 0
        maskHeight = 0
        isStreaming = false
    }
}

// MARK: - Virtualized List State & Windowing (`rune::el::virtual_list`)

/// Specification for a virtualized item or row.
public struct VirtualItemSpec: Sendable, Hashable {
    public var key: String
    public var estimatedHeight: Float
    public var isStickyHeader: Bool

    public init(key: String, estimatedHeight: Float = 44, isStickyHeader: Bool = false) {
        self.key = key
        self.estimatedHeight = max(1, estimatedHeight)
        self.isStickyHeader = isStickyHeader
    }
}

/// Computed visible window for a virtualized list.
public struct VirtualWindow: Sendable, Equatable {
    /// Index range `[start, end)` to mount (includes overscan).
    public var mountedRange: Range<Int>
    /// Visible range `[start, end)` strictly intersecting the viewport (without overscan).
    public var visibleRange: Range<Int>
    /// Total height of unmounted items before `mountedRange.lowerBound`.
    public var beforeHeight: Float
    /// Total height of unmounted items after `mountedRange.upperBound`.
    public var afterHeight: Float
    /// Total height of all items + gaps.
    public var totalHeight: Float
    /// Active sticky header index above or at the top of the viewport, if any.
    public var activeStickyIndex: Int?

    public init(
        mountedRange: Range<Int> = 0..<0,
        visibleRange: Range<Int> = 0..<0,
        beforeHeight: Float = 0,
        afterHeight: Float = 0,
        totalHeight: Float = 0,
        activeStickyIndex: Int? = nil
    ) {
        self.mountedRange = mountedRange
        self.visibleRange = visibleRange
        self.beforeHeight = beforeHeight
        self.afterHeight = afterHeight
        self.totalHeight = totalHeight
        self.activeStickyIndex = activeStickyIndex
    }
}

/// The ordered keys own their storage. Most reverse lookups need only a hash and an index.
/// Full keys are kept in the secondary table only when two different keys share a hash.
internal struct VirtualRowPlaces<Key: Hashable & Sendable>: Sendable {
    let keys: [Key]
    private var firstByHash: [Int: Int]
    private var collisions: [Key: Int] = [:]
    private(set) var hasDuplicates = false

    init(_ keys: [Key]) {
        self.keys = keys
        firstByHash = Dictionary(minimumCapacity: keys.count)
        for (index, key) in keys.enumerated() {
            let hash = key.hashValue
            if let first = firstByHash[hash] {
                if keys[first] == key {
                    hasDuplicates = true
                    firstByHash[hash] = index
                } else if collisions.updateValue(index, forKey: key) != nil {
                    hasDuplicates = true
                }
            } else {
                firstByHash[hash] = index
            }
        }
    }

    func index(of key: Key) -> Int? {
        guard let first = firstByHash[key.hashValue] else { return nil }
        if keys[first] == key { return first }
        return collisions[key]
    }
}

/// Measurements follow surviving keys when a list reorders. A removed row releases its height.
internal struct VirtualRowMeasurements: Sendable {
    var places = VirtualRowPlaces<String>([])
    private(set) var heights: [Float?] = []

    mutating func replacePlaces(_ next: VirtualRowPlaces<String>) {
        heights = next.keys.map { self[$0] }
        places = next
    }

    subscript(_ key: String) -> Float? {
        get { places.index(of: key).flatMap { heights[$0] } }
        set {
            if let index = places.index(of: key) { heights[index] = newValue }
        }
    }
}

/// Persistent geometry & scroll-anchor state for a virtualized list (`rune::VirtualList`).
public final class VirtualListState: @unchecked Sendable {
    /// The fewest rows a list pinned to its end keeps mounted above the end (`PINNED_ROWS = 32`).
    public static let pinnedRows: Int = 32

    private let lock = NSLock()
    public var keys: [String] { measurements.places.keys }
    private var measurements = VirtualRowMeasurements()
    private var stickyFlags: [Bool] = []
    private var heights: [Float] = []
    private var prefixSums: [Float] = [0]
    private var sumsDirty: Bool = false

    public var defaultEstimate: Float
    public var gap: Float {
        didSet {
            if gap < 0 { gap = 0 }
            lock.lock()
            sumsDirty = true
            lock.unlock()
        }
    }
    public var overscanPixels: Float
    public var overscanCount: Int
    public private(set) var focusedKey: String? = nil
    public private(set) var enteringKeys: Set<String> = []
    public private(set) var shownKeys: Set<String> = []
    private var born: [UInt64] = []
    private var keysFresh: Bool = false
    private var heldKeys: Bool = false
    private var anchorRow: (key: String, top: Float)? = nil
    public var padTop: Float = 0
    public var padBottom: Float = 0
    public private(set) var lastViewportHeight: Float = 0
    private var mountedRangeCached: Range<Int> = 0..<0
    private var beforeHeightCached: Float = 0

    public init(
        defaultEstimate: Float = 44,
        gap: Float = 0,
        overscanPixels: Float = 200,
        overscanCount: Int = 2
    ) {
        self.defaultEstimate = max(1, defaultEstimate)
        self.gap = max(0, gap)
        self.overscanPixels = max(0, overscanPixels)
        self.overscanCount = max(0, overscanCount)
    }

    public func setItems(_ items: [VirtualItemSpec]) {
        lock.lock()
        defer { lock.unlock() }
        let newKeys = items.map(\.key)
        let places = VirtualRowPlaces(newKeys)
        if newKeys != keys {
            keysFresh = true
            heldKeys = keys.contains { places.index(of: $0) != nil }
        }
        replaceKeys(places, commit: 0)
        stickyFlags = items.map(\.isStickyHeader)
        heights = items.enumerated().map { i, item in
            max(1, measurements.heights[i] ?? item.estimatedHeight)
        }
        for key in newKeys where !shownKeys.contains(key) {
            enteringKeys.insert(key)
        }
        sumsDirty = true
    }

    public func setKeys(_ newKeys: [String], estimate: Float? = nil) {
        let est = estimate ?? defaultEstimate
        setItems(newKeys.map { VirtualItemSpec(key: $0, estimatedHeight: est) })
    }

    /// Replaces the row keys on `commit`, preserving prior births and returning an anchor row if one in view remains (`VirtualList::set_keys`).
    @discardableResult
    public func setKeys(
        _ newKeys: [String],
        commit: UInt64,
        offset: Float? = nil,
        viewportHeight: Float? = nil
    ) -> (key: String, top: Float)? {
        lock.lock()
        defer { lock.unlock() }
        if let vp = viewportHeight { lastViewportHeight = vp }
        let places = VirtualRowPlaces(newKeys)
        let anchor: (key: String, top: Float)? = offset.flatMap { off in
            guard let row = firstVisibleLocked(offset: off, where: { places.index(of: $0) != nil }) else {
                return nil
            }
            return (lastViewportHeight <= 0 || row.top < off + lastViewportHeight) ? row : nil
        }
        if newKeys != keys {
            keysFresh = true
            if offset != nil {
                heldKeys = anchor != nil
            } else {
                heldKeys = keys.contains { places.index(of: $0) != nil }
            }
        }
        anchorRow = anchor
        replaceKeys(places, commit: commit)
        stickyFlags = Array(repeating: false, count: newKeys.count)
        heights = measurements.heights.map { max(1, $0 ?? defaultEstimate) }
        sumsDirty = true
        return anchor
    }

    private func replaceKeys(_ places: VirtualRowPlaces<String>, commit: UInt64) {
        born = places.keys.map { key in
            measurements.places.index(of: key).map { born[$0] } ?? commit
        }
        measurements.replacePlaces(places)
    }

    /// Whether row `index` mounting on `commit` skips its insertion transition (`VirtualList::mounts_quietly`).
    public func mountsQuietly(_ index: Int, commit: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard index >= 0 && index < keys.count else { return true }
        let key = keys[index]
        let quiet = born[index] < commit && !(keysFresh && !shownKeys.contains(key))
        if !quiet {
            enteringKeys.insert(key)
        }
        return quiet
    }

    /// Whether the keys changed and no previously visible row remained (`VirtualList::replaced_view`).
    public func replacedView() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keysFresh && !heldKeys
    }

    /// Marks the start of a new rendered frame (`VirtualList::frame_begins`).
    public func frameBegins() {
        lock.lock()
        defer { lock.unlock() }
        keysFresh = false
    }

    /// Returns the first row visible at `offset` accepted by `keep`, with its top offset (`VirtualList::first_visible`).
    public func firstVisible(offset: Float, where keep: (String) -> Bool) -> (key: String, top: Float)? {
        lock.lock()
        defer { lock.unlock() }
        return firstVisibleLocked(offset: offset, where: keep)
    }

    private func firstVisibleLocked(offset: Float, where keep: (String) -> Bool) -> (key: String, top: Float)? {
        rebuildPrefixSumsIfNeeded()
        for i in 0..<keys.count {
            let rowEnd = padTop + prefixSums[i] + heights[i]
            if rowEnd > offset && keep(keys[i]) {
                return (keys[i], padTop + prefixSums[i])
            }
        }
        return nil
    }

    /// Maximum vertical scroll offset (`VirtualList::max_offset`).
    public func maxOffset(viewportHeight: Float? = nil) -> Float {
        lock.lock()
        defer { lock.unlock() }
        if let vp = viewportHeight { lastViewportHeight = vp }
        rebuildPrefixSumsIfNeeded()
        return max(0, padTop + (prefixSums.last ?? 0) + padBottom - lastViewportHeight)
    }

    /// Scroll anchor displacement since the last `setKeys` (`VirtualList::anchor_delta`).
    public func anchorDelta() -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard let anchor = anchorRow, let idx = measurements.places.index(of: anchor.key) else { return 0 }
        rebuildPrefixSumsIfNeeded()
        return padTop + prefixSums[idx] - anchor.top
    }

    /// Whether the mounted window needs refreshing at `offset` (`VirtualList::needs_window`).
    public func needsWindow(offset: Float, viewportHeight: Float? = nil, pinned: Bool = false, indexed: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let vp = viewportHeight { lastViewportHeight = vp }
        guard !keys.isEmpty else { return false }
        if pinned { return mountedRangeCached.upperBound != keys.count }
        rebuildPrefixSumsIfNeeded()
        let edge = lastViewportHeight * (indexed ? 1.75 : 0.5)
        let top = padTop + beforeHeightCached
        let endIdx = min(keys.count, mountedRangeCached.upperBound)
        let mountedEnd = endIdx == 0 ? 0 : (prefixSums[endIdx - 1] + heights[endIdx - 1])
        let bottom = padTop + mountedEnd
        return (mountedRangeCached.lowerBound > 0 && offset < top + edge)
            || (mountedRangeCached.upperBound < keys.count && offset + lastViewportHeight > bottom - edge)
    }

    internal func setMountedRangeForTesting(_ range: Range<Int>, viewportHeight: Float? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let vp = viewportHeight { lastViewportHeight = vp }
        mountedRangeCached = range
    }

    /// How many rows of the overscan around `offset` (or the end window when `pinned`) are still unmounted (`VirtualList::unfilled`).
    internal func unfilled(offset: Float, pinned: Bool = false) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !keys.isEmpty else { return 0 }
        rebuildPrefixSumsIfNeeded()
        let total = padTop + (prefixSums.last ?? 0) + padBottom
        let maxOff = max(0, total - lastViewportHeight)
        let targetOffset = pinned ? maxOff : min(offset, maxOff)
        let lo = targetOffset - lastViewportHeight * 2.0
        let hi = targetOffset + lastViewportHeight * 3.0
        var start = keys.count
        var end = 0
        for i in 0..<keys.count {
            let rowStart = padTop + prefixSums[i]
            let rowEnd = rowStart + heights[i]
            if rowEnd > lo && rowStart < hi {
                start = min(start, i)
                end = max(end, i + 1)
            }
        }
        if start >= end {
            start = 0
            end = min(keys.count, 1)
        }
        if pinned {
            start = min(start, max(0, end - Self.pinnedRows))
            end = max(end, start)
        }
        let mounted = max(0, min(mountedRangeCached.upperBound, end) - max(mountedRangeCached.lowerBound, start))
        return max(0, end - start) - mounted
    }

    /// Records the laid-out height of a mounted row key.
    public func recordMeasuredHeight(_ height: Float, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        let clamped = max(1, height)
        guard let idx = measurements.places.index(of: key) else { return }
        if measurements.heights[idx] != clamped {
            measurements[key] = clamped
            heights[idx] = clamped
            sumsDirty = true
        }
        enteringKeys.remove(key)
        shownKeys.insert(key)
    }

    public func setFocusedKey(_ key: String?) {
        lock.lock()
        defer { lock.unlock() }
        focusedKey = key
    }

    private func rebuildPrefixSumsIfNeeded() {
        guard sumsDirty else { return }
        prefixSums.removeAll(keepingCapacity: true)
        prefixSums.append(0)
        var acc: Float = 0
        for i in 0..<heights.count {
            acc += heights[i]
            if i + 1 < heights.count {
                acc += gap
            }
            prefixSums.append(acc)
        }
        sumsDirty = false
    }

    /// Returns the total content height of all items.
    public var totalHeight: Float {
        lock.lock()
        defer { lock.unlock() }
        rebuildPrefixSumsIfNeeded()
        return prefixSums.last ?? 0
    }

    /// Returns the `(y, height)` offset range for item `index`.
    public func offsetForIndex(_ index: Int) -> (y: Float, height: Float)? {
        lock.lock()
        defer { lock.unlock() }
        guard index >= 0 && index < heights.count else { return nil }
        rebuildPrefixSumsIfNeeded()
        return (prefixSums[index], heights[index])
    }

    /// Computes the scroll `y` offset needed to reveal `index` at `alignment`.
    public func scrollOffset(
        toIndex index: Int,
        viewportHeight: Float,
        currentScrollY: Float = 0,
        alignment: ScrollAlignment = .nearest
    ) -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard !heights.isEmpty else { return 0 }
        let clampedIdx = max(0, min(heights.count - 1, index))
        rebuildPrefixSumsIfNeeded()
        let itemTop = prefixSums[clampedIdx]
        let itemH = heights[clampedIdx]
        let itemBottom = itemTop + itemH
        let total = prefixSums.last ?? 0
        let maxScroll = max(0, total - viewportHeight)

        let target: Float
        switch alignment {
        case .top:
            target = itemTop
        case .center:
            target = itemTop - (viewportHeight - itemH) * 0.5
        case .bottom:
            target = itemBottom - viewportHeight
        case .nearest:
            if itemTop < currentScrollY {
                target = itemTop
            } else if itemBottom > currentScrollY + viewportHeight {
                target = itemBottom - viewportHeight
            } else {
                target = currentScrollY
            }
        }
        return max(0, min(maxScroll, target))
    }

    /// Computes the visible and overscan-mounted window for `(scrollY, viewportHeight)`.
    public func computeWindow(scrollY: Float, viewportHeight: Float) -> VirtualWindow {
        lock.lock()
        defer { lock.unlock() }
        let n = heights.count
        guard n > 0 else { return VirtualWindow() }
        rebuildPrefixSumsIfNeeded()

        let total = prefixSums.last ?? 0
        let viewTop = max(0, scrollY)
        let viewBottom = max(viewTop, viewTop + max(0, viewportHeight))

        let visStart = lowerBound(offset: viewTop)
        let visEnd = upperBound(offset: viewBottom)

        let overTop = max(0, viewTop - overscanPixels)
        let overBottom = min(total, viewBottom + overscanPixels)

        var mountStart = max(0, lowerBound(offset: overTop) - overscanCount)
        var mountEnd = min(n, upperBound(offset: overBottom) + overscanCount)

        // Ensure focused row stays mounted even if offscreen
        if let fKey = focusedKey, let fIdx = measurements.places.index(of: fKey) {
            if fIdx < mountStart { mountStart = fIdx }
            if fIdx >= mountEnd { mountEnd = fIdx + 1 }
        }

        let beforeH = prefixSums[mountStart]
        let mountedBottom = mountEnd == 0 ? 0 : (prefixSums[mountEnd - 1] + heights[mountEnd - 1])
        let afterH = max(0, total - mountedBottom)
        lastViewportHeight = viewportHeight
        mountedRangeCached = mountStart..<mountEnd
        beforeHeightCached = beforeH

        // Find active sticky header at or above viewTop
        var stickyIdx: Int? = nil
        if visStart > 0 || (visStart == 0 && !stickyFlags.isEmpty) {
            let searchLimit = min(n - 1, visStart)
            for i in stride(from: searchLimit, through: 0, by: -1) {
                if stickyFlags[i] {
                    stickyIdx = i
                    break
                }
            }
        }

        return VirtualWindow(
            mountedRange: mountStart..<mountEnd,
            visibleRange: visStart..<visEnd,
            beforeHeight: beforeH,
            afterHeight: afterH,
            totalHeight: total,
            activeStickyIndex: stickyIdx
        )
    }

    private func lowerBound(offset: Float) -> Int {
        var lo = 0
        var hi = heights.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let itemBottom = prefixSums[mid] + heights[mid]
            if itemBottom <= offset {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return min(lo, max(0, heights.count - 1))
    }

    private func upperBound(offset: Float) -> Int {
        var lo = 0
        var hi = heights.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if prefixSums[mid] < offset {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}

public enum ScrollAlignment: Sendable, Hashable {
    case top
    case center
    case bottom
    case nearest
}

// MARK: - Declarative Virtual List Builders (`virtualList` / `virtualRows`)

/// Builds a virtualized scrollable column from an array of keyed items, mounting only the
/// visible window + overscan with exact `before`/`after` spacer boxes and optional sticky header.
public func virtualList<State>(
    key: String,
    state: VirtualListState,
    items: [VirtualItemSpec],
    scrollY: Float,
    viewportHeight: Float,
    buildRow: (Int, VirtualItemSpec) -> El<State>
) -> El<State> {
    state.setItems(items)
    let window = state.computeWindow(scrollY: scrollY, viewportHeight: viewportHeight)

    var container = El<State>(direction: .column)
        .key(key)
        .scrollY()
        .gap(state.gap)

    if window.beforeHeight > 0 {
        container = container.child(
            El<State>(direction: .row)
                .key("\(key)-before-spacer")
                .wFull()
                .h(window.beforeHeight)
                .shrink(0)
        )
    }

    for idx in window.mountedRange {
        let item = items[idx]
        var rowEl = buildRow(idx, item)
        if rowEl.keyId == nil {
            rowEl = rowEl.key(item.key)
        }
        container = container.child(rowEl)
    }

    if window.afterHeight > 0 {
        container = container.child(
            El<State>(direction: .row)
                .key("\(key)-after-spacer")
                .wFull()
                .h(window.afterHeight)
                .shrink(0)
        )
    }

    if let stickyIdx = window.activeStickyIndex,
       stickyIdx < window.mountedRange.lowerBound,
       stickyIdx < items.count {
        var stickyEl = buildRow(stickyIdx, items[stickyIdx])
        stickyEl = stickyEl
            .key("\(key)-sticky-\(items[stickyIdx].key)")
            .pin(top: 0, right: 0, left: 0)
        container = container.child(stickyEl)
    }

    return container
}

/// Index-driven virtualized rows builder (`El::virtual_rows`): builds only the mounted `[start, end)`
/// rows on demand by index, avoiding allocating `El`s for offscreen rows.
public func virtualRows<State>(
    key: String,
    state: VirtualListState,
    count: Int,
    estimatedHeight: Float = 44,
    scrollY: Float,
    viewportHeight: Float,
    rowKey: (Int) -> String = { "row-\($0)" },
    buildRow: (Int) -> El<State>
) -> El<State> {
    let specs = (0..<max(0, count)).map {
        VirtualItemSpec(key: rowKey($0), estimatedHeight: estimatedHeight)
    }
    return virtualList(
        key: key,
        state: state,
        items: specs,
        scrollY: scrollY,
        viewportHeight: viewportHeight
    ) { idx, _ in
        buildRow(idx)
    }
}
