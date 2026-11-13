import Foundation

/// Settle-window duration during scale changes before a cached layer rasterizes (`STATIC_SCALE_SETTLE`).
public let STATIC_SCALE_SETTLE: Double = 0.1

/// Scale stabilization tracker for cached layers (`runtime/paint/cache_layer.rs`).
public enum ScaleSettle: Sendable {
    case still(Float)
    case settling(scale: Float, since: Double)

    public var fields: (scale: Float, since: Double) {
        switch self {
        case .still(let s):
            return (s, -.infinity)
        case .settling(let s, let since):
            return (s, since)
        }
    }

    /// Strict bit-pattern tuple matching `cache_layer_tests::bits` (including NaN/Inf identity).
    public var bitFields: (scaleBits: UInt32, sinceBits: UInt64) {
        let (s, since) = fields
        return (s.bitPattern, since.bitPattern)
    }

    /// Advances scale settling against animation clock `now`. Returns `true` when another frame is required.
    @discardableResult
    public mutating func step(scale: Float, now: Double, reset: Bool, epsilon: Float, poll: Bool) -> Bool {
        let (seen, existingSince) = fields
        // Use strict `abs(scale - seen) > epsilon` so NaN or Infinity - Infinity does not restart the settle window.
        let changed = !reset && abs(scale - seen) > epsilon
        let since: Double
        if reset {
            self = .still(scale)
            since = -.infinity
        } else if changed {
            self = .settling(scale: scale, since: now)
            since = now
        } else {
            since = existingSince
        }
        return poll && (now - since) < STATIC_SCALE_SETTLE
    }
}

public enum RasterPhase: Equatable, Sendable {
    case live
    case raster(paintHash: UInt64)

    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }
}

public enum RasterPass: Equatable, Sendable {
    case paint(glyphStart: Int)
    case elide(glyphs: Int)
}

public struct NodeCacheState: Sendable {
    public var signature: UInt64
    public var rasterScale: Float
    public var scale: ScaleSettle
    public var envScale: Float
    public var phase: RasterPhase
    public var glyphs: Int
    public var commitGen: UInt64

    public init(
        signature: UInt64 = 1,
        rasterScale: Float,
        scale: ScaleSettle,
        envScale: Float = 1.0,
        phase: RasterPhase,
        glyphs: Int = 0,
        commitGen: UInt64
    ) {
        self.signature = signature
        self.rasterScale = rasterScale
        self.scale = scale
        self.envScale = envScale
        self.phase = phase
        self.glyphs = glyphs
        self.commitGen = commitGen
    }

    @discardableResult
    public mutating func committedScale(_ scale: Float, now: Double) -> Bool {
        if abs(scale - rasterScale) > 1e-4 && self.scale.step(scale: scale, now: now, reset: false, epsilon: 1e-4, poll: true) {
            phase = .live
            return true
        }
        return false
    }
}

/// Evaluates `cache_layer`'s paint-time cache reuse & scale-settling state machine, matching `cache_layer.rs`.
public struct CacheLayerStepMachine: Sendable {
    public var entry: NodeCacheState?
    public var staticScale: ScaleSettle?
    public private(set) var scaleFrameRequested: Bool = false

    public init(entry: NodeCacheState? = nil, staticScale: ScaleSettle? = nil) {
        self.entry = entry
        self.staticScale = staticScale
    }

    /// Mirrors `Runtime::paint_node` cache open + seal logic for `baseSizePx` box under `effScale`.
    @discardableResult
    public mutating func step(
        baseSizePt: Float = 32.0,
        effScale: Float,
        envScale: Float = 1.0,
        now: Double,
        commitGen: UInt64,
        settled: Bool,
        isResident: Bool,
        paintHash: UInt64 = 0
    ) -> Bool {
        scaleFrameRequested = false

        // Track non-unit static scale settle window (or any prior static_scale tracking).
        let staticMoving: Bool
        if effScale != 1.0 || staticScale != nil {
            var ss = staticScale ?? .still(effScale)
            let moving = ss.step(scale: effScale, now: now, reset: settled, epsilon: 1e-5, poll: true)
            staticScale = ss
            if moving {
                scaleFrameRequested = true
            }
            staticMoving = moving
        } else {
            staticMoving = false
        }

        // Handle committed scale changes on an existing cache entry before checking bounds.
        if var existing = entry, existing.commitGen != commitGen {
            if existing.committedScale(effScale, now: now) {
                entry = existing
                scaleFrameRequested = true
                return scaleFrameRequested
            }
            entry = existing
        }

        // Only open/reuse a cache when raster size fits within the 4096 px hardware limit.
        let est = ceilf(baseSizePt * effScale)
        guard est.isFinite && est <= Float(LayerPoolLimits.maxDimension) else {
            return scaleFrameRequested
        }

        if var existing = entry {
            let envSame = abs(envScale - existing.envScale) <= 1e-4 && !settled
            var ss = existing.scale
            let localSettling = ss.step(
                scale: effScale,
                now: now,
                reset: !envSame,
                epsilon: 1e-4,
                poll: envSame && isResident && !existing.phase.isLive
            )
            let scaleDiff = abs(effScale - existing.rasterScale) > 1e-4
            let sameCommit = (commitGen == existing.commitGen)
            let scaleSettling = sameCommit
                && scaleDiff
                && envSame
                && isResident
                && !existing.phase.isLive
                && (localSettling || staticMoving)
            if scaleSettling {
                scaleFrameRequested = true
            }
            let contentSame = sameCommit && (!scaleDiff || scaleSettling)
            let canElide: Bool
            if case .raster(let h) = existing.phase {
                canElide = isResident && contentSame && (h == paintHash)
            } else {
                canElide = false
            }

            if canElide {
                existing.scale = ss
                entry = existing
                return scaleFrameRequested
            }

            existing.rasterScale = effScale
            existing.scale = ss
            existing.envScale = envScale
            existing.phase = .raster(paintHash: paintHash)
            existing.commitGen = commitGen
            entry = existing
        } else {
            var ss = ScaleSettle.still(effScale)
            _ = ss.step(scale: effScale, now: now, reset: true, epsilon: 1e-4, poll: false)
            entry = NodeCacheState(
                signature: 1,
                rasterScale: effScale,
                scale: ss,
                envScale: envScale,
                phase: .raster(paintHash: paintHash),
                glyphs: 0,
                commitGen: commitGen
            )
        }

        return scaleFrameRequested
    }
}
