import Foundation

/// Where text's ink sits inside its layout box, rasterized at 8x oversampling so
/// measurements are accurate within 1/8 pt (`rune::text::measure::ink`).
public struct TextInk: Equatable, Hashable, Sendable {
    /// The ink's bounds as `[x, y, w, h]` in points from the top-left of its box.
    public var bounds: SIMD4<Float>
    /// The ink's centre of mass `[cx, cy]`, weighting each pixel by its coverage.
    public var mass: SIMD2<Float>

    public init(bounds: SIMD4<Float>, mass: SIMD2<Float>) {
        self.bounds = bounds
        self.mass = mass
    }

    public init(bounds: [Float], mass: [Float]) {
        precondition(bounds.count == 4 && mass.count == 2)
        self.bounds = SIMD4<Float>(bounds[0], bounds[1], bounds[2], bounds[3])
        self.mass = SIMD2<Float>(mass[0], mass[1])
    }

    /// The middle of the ink's bounds.
    public func centre() -> SIMD2<Float> {
        SIMD2<Float>(bounds[0] + bounds[2] * 0.5, bounds[1] + bounds[3] * 0.5)
    }

    /// The point that looks like the middle: `pull` of the way from the bounds' centre
    /// to the centre of mass (around `0.3` suits keyboard symbols).
    public func optical(pull: Float) -> SIMD2<Float> {
        let c = centre()
        return SIMD2<Float>(
            c[0] + (mass[0] - c[0]) * pull,
            c[1] + (mass[1] - c[1]) * pull
        )
    }
}

/// Pixel coverage accumulator in oversampled device pixels.
internal struct TextInkAccumulator {
    static let oversample: Float = 8.0

    private var minPt: SIMD2<Float> = .zero
    private var maxPt: SIMD2<Float> = .zero
    private var sumPt: SIMD2<Float> = .zero
    private var weight: Float = 0

    mutating func add(x: Float, y: Float, alpha: Float) {
        guard alpha > 0 else { return }
        if weight == 0 {
            minPt = SIMD2<Float>(x, y)
            maxPt = SIMD2<Float>(x + 1, y + 1)
        } else {
            minPt = SIMD2<Float>(min(minPt.x, x), min(minPt.y, y))
            maxPt = SIMD2<Float>(max(maxPt.x, x + 1), max(maxPt.y, y + 1))
        }
        sumPt += SIMD2<Float>((x + 0.5) * alpha, (y + 0.5) * alpha)
        weight += alpha
    }

    func finish() -> TextInk? {
        guard weight > 0 else { return nil }
        let k = Self.oversample
        return TextInk(
            bounds: SIMD4<Float>(
                minPt.x / k,
                minPt.y / k,
                (maxPt.x - minPt.x) / k,
                (maxPt.y - minPt.y) / k
            ),
            mass: SIMD2<Float>(
                sumPt.x / weight / k,
                sumPt.y / weight / k
            )
        )
    }
}

/// Bounded FIFO/byte cache for `TextInk` measurements (`rune::text::measure::ink::Cache`),
/// checking both `text` and `style` on lookup so hash collisions never alias.
internal struct TextInkCache: Sendable {
    static let maxEntries: Int = 1024
    static let maxBytes: Int = 256 << 10

    struct Entry: Sendable, Equatable {
        let text: String
        let style: TextStyle
        let ink: TextInk?

        var bytes: Int {
            MemoryLayout<Entry>.size + text.utf8.count
        }
    }

    private(set) var entries: [UInt64: Entry] = [:]
    private(set) var order: [UInt64] = []
    private(set) var bytes: Int = 0
    var epoch: UInt64 = 0

    static func key(text: String, style: TextStyle) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(style)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    func get(key: UInt64, text: String, style: TextStyle) -> TextInk?? {
        guard let entry = entries[key], entry.text == text, entry.style == style else {
            return nil
        }
        return .some(entry.ink)
    }

    mutating func insert(key: UInt64, text: String, style: TextStyle, ink: TextInk?) {
        let entry = Entry(text: text, style: style, ink: ink)
        let entryBytes = entry.bytes
        if entryBytes > Self.maxBytes {
            return
        }
        bytes += entryBytes
        if let old = entries.updateValue(entry, forKey: key) {
            bytes -= old.bytes
        } else {
            order.append(key)
        }
        while entries.count > Self.maxEntries || bytes > Self.maxBytes {
            guard !order.isEmpty else { break }
            let oldest = order.removeFirst()
            if let old = entries.removeValue(forKey: oldest) {
                bytes -= old.bytes
            }
        }
    }
}

/// Where `text` set in `style` puts its ink, or `nil` when it draws nothing (spaces, empty).
/// Cached by text and style for the thread and the families it measured with.
public func ink(_ text: String, style: TextStyle) -> TextInk? {
    let measurer = ThreadTextMeasurer.current
    return measurer.withSystem { system in
        let key = TextInkCache.key(text: text, style: style)
        let epoch = system.currentFontEpoch
        if measurer.inkCache.epoch != epoch {
            measurer.inkCache = TextInkCache(epoch: epoch)
        }
        if let hit = measurer.inkCache.get(key: key, text: text, style: style) {
            return hit
        }
        let found = system.computeInk(text, style: style)
        measurer.inkCache.insert(key: key, text: text, style: style, ink: found)
        return found
    }
}

extension TextSystem {
    /// Measures exact rasterized ink bounds and center of mass for `text` in `style`.
    public func ink(_ text: String, style: TextStyle) -> TextInk? {
        computeInk(text, style: style)
    }
}
