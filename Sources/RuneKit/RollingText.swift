import Foundation
import Rune
import RuneMotion

// MARK: - RollingText (`rune_kit::rolling_text`)

public enum RollingTextLimits {
    public static let lcsBudget: Int = 48 * 48
    public static let staggerSeconds: Double = 0.03
    public static let staggerCap: Int = 6
    public static let maxLabels: Int = 512
    public static let maxBytes: Int = 256 * 1024
}

/// Direction from which entering glyphs slide in.
public enum RollingSlideEdge: Sendable, Equatable {
    case bottom
    case top

    var transitionEdge: MotionEdge {
        switch self {
        case .bottom: return .bottom
        case .top: return .top
        }
    }
}

/// A single rendered grapheme slot produced by `RollingTextStore` / `RollingTextDiff`.
public struct RollingSlot: Sendable, Equatable {
    public let key: String
    public let glyph: String
    public let retained: Bool
    public let enterDelay: Double

    public init(key: String, glyph: String, retained: Bool, enterDelay: Double) {
        self.key = key
        self.glyph = glyph
        self.retained = retained
        self.enterDelay = enterDelay
    }
}

/// Pure per-grapheme weighted-LCS + odometer diff engine (`rune_kit::rolling_text::diff`).
public enum RollingTextDiff {
    /// Computes next slot identities from a previous `(glyph, key)` array into `newValue`.
    public static func transition(
        labelKey: String,
        previous: [(glyph: String, key: String)],
        to newValue: String,
        trailing: Bool = false,
        nextSeq: inout UInt64
    ) -> [RollingSlot] {
        let newGlyphs = newValue.map { String($0) }
        guard !newGlyphs.isEmpty else { return [] }

        @inline(__always)
        func freshKey() -> String {
            let id = nextSeq
            nextSeq &+= 1
            return "\(labelKey)#\(id)"
        }

        if previous.isEmpty {
            return newGlyphs.enumerated().map { idx, glyph in
                let step = min(idx, RollingTextLimits.staggerCap)
                return RollingSlot(
                    key: freshKey(),
                    glyph: glyph,
                    retained: false,
                    enterDelay: Double(step) * RollingTextLimits.staggerSeconds
                )
            }
        }

        // Fast path for identical text
        if previous.count == newGlyphs.count && zip(previous, newGlyphs).allSatisfy({ $0.glyph == $1 }) {
            return previous.map { RollingSlot(key: $0.key, glyph: $0.glyph, retained: true, enterDelay: 0) }
        }

        let oldGlyphs = previous.map(\.glyph)
        let matchedOldIndex: [Int?] = matchIndices(
            old: oldGlyphs,
            new: newGlyphs,
            trailing: trailing
        )

        var insertRank = 0
        var result: [RollingSlot] = []
        result.reserveCapacity(newGlyphs.count)

        for (j, glyph) in newGlyphs.enumerated() {
            if let oldIdx = matchedOldIndex[j] {
                result.append(RollingSlot(
                    key: previous[oldIdx].key,
                    glyph: glyph,
                    retained: true,
                    enterDelay: 0
                ))
            } else {
                let step = min(insertRank, RollingTextLimits.staggerCap)
                insertRank += 1
                result.append(RollingSlot(
                    key: freshKey(),
                    glyph: glyph,
                    retained: false,
                    enterDelay: Double(step) * RollingTextLimits.staggerSeconds
                ))
            }
        }
        return result
    }

    /// Maps each index in `new` to the matched index in `old` (or `nil` if newly inserted).
    static func matchIndices(old: [String], new: [String], trailing: Bool) -> [Int?] {
        let n = old.count
        let m = new.count
        var mapping: [Int?] = Array(repeating: nil, count: m)
        if n == 0 || m == 0 { return mapping }

        // Trim common prefix (when not odometer-trailing, prefix is maximally preferred)
        // or common suffix when trailing is enabled, then solve DP on the interior within budget.
        var prefix = 0
        if !trailing {
            while prefix < n && prefix < m && old[prefix] == new[prefix] {
                mapping[prefix] = prefix
                prefix += 1
            }
        }

        var suffix = 0
        while prefix + suffix < n && prefix + suffix < m
            && old[n - 1 - suffix] == new[m - 1 - suffix]
        {
            mapping[m - 1 - suffix] = n - 1 - suffix
            suffix += 1
        }

        if trailing {
            while prefix + suffix < n && prefix + suffix < m && old[prefix] == new[prefix] {
                mapping[prefix] = prefix
                prefix += 1
            }
        }

        let subOldStart = prefix
        let subOldEnd = n - suffix
        let subNewStart = prefix
        let subNewEnd = m - suffix
        let sn = subOldEnd - subOldStart
        let sm = subNewEnd - subNewStart
        if sn <= 0 || sm <= 0 {
            return mapping
        }

        // Budget guard: skip O(sn*sm) DP above budget (2304 cells); prefix/suffix trim above is already kept!
        if sn * sm > RollingTextLimits.lcsBudget {
            return mapping
        }

        // Weighted DP maximizing match count first, with subtle position bias:
        // - normal: prefer earlier (left) matches
        // - trailing (odometer): prefer rightmost alignment so tail digits match in place
        let cols = sm + 1
        var dp = Array(repeating: Int64(0), count: (sn + 1) * cols)
        let baseWeight: Int64 = 1_000_000

        for i in (0..<sn).reversed() {
            for j in (0..<sm).reversed() {
                let down = dp[(i + 1) * cols + j]
                let right = dp[i * cols + (j + 1)]
                var best = max(down, right)
                if old[subOldStart + i] == new[subNewStart + j] {
                    let posBonus: Int64 = trailing
                        ? Int64(j + 1) * 16 + Int64(i + 1)
                        : Int64(sm - j) * 16 + Int64(sn - i)
                    let diag = dp[(i + 1) * cols + (j + 1)] + baseWeight + posBonus
                    if diag >= best {
                        best = diag
                    }
                }
                dp[i * cols + j] = best
            }
        }

        var i = 0
        var j = 0
        while i < sn && j < sm {
            let cur = dp[i * cols + j]
            if old[subOldStart + i] == new[subNewStart + j] {
                let posBonus: Int64 = trailing
                    ? Int64(j + 1) * 16 + Int64(i + 1)
                    : Int64(sm - j) * 16 + Int64(sn - i)
                let diag = dp[(i + 1) * cols + (j + 1)] + baseWeight + posBonus
                if cur == diag {
                    mapping[subNewStart + j] = subOldStart + i
                    i += 1
                    j += 1
                    continue
                }
            }
            if dp[(i + 1) * cols + j] >= dp[i * cols + (j + 1)] {
                i += 1
            } else {
                j += 1
            }
        }

        return mapping
    }
}

/// Bounded LRU-style label history store (`MAX_LABELS = 512`, `MAX_BYTES = 256 KiB`).
public final class RollingTextStore: @unchecked Sendable {
    public static let shared = RollingTextStore()

    struct Entry {
        var value: String
        var slots: [RollingSlot]
        var byteCost: Int
    }

    private let lock = NSLock()
    private let maxLabels: Int
    private let maxBytes: Int
    private var entries: [String: Entry] = [:]
    private var lruOrder: [String] = []
    private var totalBytes: Int = 0
    private var nextSeq: UInt64 = 1

    public init(maxLabels: Int = RollingTextLimits.maxLabels, maxBytes: Int = RollingTextLimits.maxBytes) {
        self.maxLabels = max(1, maxLabels)
        self.maxBytes = max(64, maxBytes)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public var storedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        lruOrder.removeAll()
        totalBytes = 0
    }

    public func contains(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[key] != nil
    }

    /// Computes and stores the next slot layout for `key`, evicting oldest entries when over bounds.
    public func update(key: String, value: String, trailing: Bool = false) -> [RollingSlot] {
        lock.lock()
        defer { lock.unlock() }

        let previous = entries[key]?.slots.map { (glyph: $0.glyph, key: $0.key) } ?? []
        let slots = RollingTextDiff.transition(
            labelKey: key,
            previous: previous,
            to: value,
            trailing: trailing,
            nextSeq: &nextSeq
        )

        let entryBytes = estimateBytes(key: key, value: value, slots: slots)
        if let existing = entries[key] {
            totalBytes -= existing.byteCost
        }
        entries[key] = Entry(value: value, slots: slots, byteCost: entryBytes)
        totalBytes += entryBytes
        touchLRU(key)
        evictIfNeeded(keeping: key)
        return slots
    }

    private func estimateBytes(key: String, value: String, slots: [RollingSlot]) -> Int {
        var bytes = key.utf8.count + value.utf8.count
        for slot in slots {
            bytes += slot.key.utf8.count + slot.glyph.utf8.count + 24
        }
        return max(1, bytes)
    }

    private func touchLRU(_ key: String) {
        if let idx = lruOrder.firstIndex(of: key) {
            lruOrder.remove(at: idx)
        }
        lruOrder.append(key)
    }

    private func evictIfNeeded(keeping activeKey: String) {
        while (entries.count > maxLabels || totalBytes > maxBytes), lruOrder.count > 1 {
            guard let oldest = lruOrder.first else { break }
            if oldest == activeKey {
                // Keep the just-inserted entry; evict the next oldest if any.
                if lruOrder.count > 1 {
                    let second = lruOrder.remove(at: 1)
                    if let removed = entries.removeValue(forKey: second) {
                        totalBytes -= removed.byteCost
                    }
                    continue
                }
                break
            }
            lruOrder.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                totalBytes -= removed.byteCost
            }
        }
    }
}

/// Fluent animated rolling text builder (`rune_kit::rolling_text::RollingText`).
public struct RollingText<State> {
    public var key: String
    public var value: String
    public var font: TextStyle?
    public var color: Color?
    public var trailing: Bool
    public var slideFrom: RollingSlideEdge
    public var spring: Spring
    public var store: RollingTextStore

    public init(
        key: String,
        value: String,
        font: TextStyle? = nil,
        color: Color? = nil,
        trailing: Bool = false,
        slideFrom: RollingSlideEdge = .bottom,
        spring: Spring? = nil,
        kit: Kit = Kit.neutral(dark: true),
        store: RollingTextStore = .shared
    ) {
        self.key = key
        self.value = value
        self.font = font ?? kit.ty.uiMedium
        self.color = color ?? kit.c.textBase
        self.trailing = trailing
        self.slideFrom = slideFrom
        self.spring = spring ?? kit.motion.control
        self.store = store
    }

    public func font(_ value: TextStyle) -> Self {
        var copy = self; copy.font = value; return copy
    }

    public func color(_ value: Color) -> Self {
        var copy = self; copy.color = value; return copy
    }

    public func trailing(_ enabled: Bool = true) -> Self {
        var copy = self; copy.trailing = enabled; return copy
    }

    public func from(_ edge: RollingSlideEdge) -> Self {
        var copy = self; copy.slideFrom = edge; return copy
    }

    public func spring(_ value: Spring) -> Self {
        var copy = self; copy.spring = value; return copy
    }

    public func store(_ value: RollingTextStore) -> Self {
        var copy = self; copy.store = value; return copy
    }

    public func build() -> El<State> {
        let slots = store.update(key: key, value: value, trailing: trailing)
        var container: El<State> = row()
            .key(key)
            .clip(true)
            .animateLayout(spring)

        for slot in slots {
            var glyphEl: El<State> = text(slot.glyph)
                .key(slot.key)
                .noWrap()
                .transition(Transition.push(from: slideFrom.transitionEdge).spring(spring))
            if let font {
                glyphEl = glyphEl.font(font)
            }
            if let color {
                glyphEl = glyphEl.color(color)
            }
            container = container.child(glyphEl)
        }
        return container
    }
}

extension Kit {
    /// Builder overload supporting odometer trailing alignment and slide direction.
    public func rollingText<State>(
        key: String,
        _ value: String,
        font: TextStyle? = nil,
        color: Color? = nil,
        trailing: Bool,
        from edge: RollingSlideEdge = .bottom
    ) -> El<State> {
        RollingText<State>(
            key: key,
            value: value,
            font: font,
            color: color,
            trailing: trailing,
            slideFrom: edge,
            kit: self
        ).build()
    }
}
