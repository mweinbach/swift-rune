import Foundation
import RuneMotion
#if canImport(simd)
import simd
#endif

// MARK: - GPU Springs (gpu/springs.rs)

/// Splits wall-clock seconds into integer whole seconds and sub-second fraction
/// so `vs_springs` subtracts `(int(time.x) - int(s.start.x))` without float precision loss.
@inlinable
public func splitSpringTime(_ timeSeconds: Double) -> SIMD2<Float> {
    let clamped = max(0.0, timeSeconds)
    let whole = floor(clamped)
    let wholeInt = Int32(min(whole, Double(Int32.max)))
    let frac = Float(clamped - Double(wholeInt))
    return SIMD2<Float>(Float(wholeInt), frac)
}

/// 48-byte GPU spring track matching `SpringTrack` in `RenderShaders.shaderMSL` (`gpu/springs.wgsl`).
///
/// `kind`: `0` = settled/constant, `1` = underdamped, `2` = critically damped, `3` = overdamped.
public struct GPUSpringTrack: Sendable, Equatable {
    public var abcd: SIMD4<Float>
    public var rates: SIMD2<Float>
    public var goal: Float
    public var kind: UInt32
    public var start: SIMD2<Float>
    public var duration: Float
    public var pad: Float

    public init(
        abcd: SIMD4<Float> = .zero,
        rates: SIMD2<Float> = .zero,
        goal: Float = 0,
        kind: UInt32 = 0,
        start: SIMD2<Float> = .zero,
        duration: Float = 0
    ) {
        self.abcd = abcd
        self.rates = rates
        self.goal = goal
        self.kind = kind
        self.start = start
        self.duration = duration
        self.pad = 0
    }

    public static func constant(_ goal: Float) -> GPUSpringTrack {
        GPUSpringTrack(goal: goal, kind: 0)
    }

    /// Compiles closed-form GPU spring coefficients matching `Spring.sample(from:velocity:target:at:)`.
    public init(
        spring: Spring,
        initial: Float,
        velocity: Float = 0,
        goal: Float,
        startSeconds: Double = 0,
        epsilon: Float = 1e-4
    ) {
        let a = initial - goal
        let settle = spring.settlingDuration(from: initial, velocity: velocity, target: goal, epsilon: epsilon)
        if settle <= 0 || (abs(a) < 1e-6 && abs(velocity) < 1e-5) {
            self = .constant(goal)
            return
        }
        let omega = spring.omega
        let zeta = spring.dampingRatio
        let start = splitSpringTime(startSeconds)
        if abs(zeta - 1.0) < 1e-4 {
            let b = velocity + omega * a
            self.init(
                abcd: SIMD4<Float>(a, b, velocity, -omega * b),
                rates: SIMD2<Float>(omega, 0),
                goal: goal,
                kind: 2,
                start: start,
                duration: settle
            )
        } else if zeta < 1.0 {
            let sigma = zeta * omega
            let omegaD = omega * sqrtf(max(1e-8, 1.0 - zeta * zeta))
            let b = (velocity + sigma * a) / omegaD
            self.init(
                abcd: SIMD4<Float>(a, b, b * omegaD - sigma * a, -(a * omegaD + sigma * b)),
                rates: SIMD2<Float>(sigma, omegaD),
                goal: goal,
                kind: 1,
                start: start,
                duration: settle
            )
        } else {
            let s = sqrtf(max(1e-8, zeta * zeta - 1.0))
            let r1 = -omega * (zeta - s)
            let r2 = -omega * (zeta + s)
            let c1 = (velocity - r2 * a) / (r1 - r2)
            let c2 = a - c1
            self.init(
                abcd: SIMD4<Float>(c1, c2, r1, r2),
                rates: .zero,
                goal: goal,
                kind: 3,
                start: start,
                duration: settle
            )
        }
    }

    /// Wall-clock timestamp (`start + duration`) when the track settles (`0` if already constant).
    public func settleAt() -> Double {
        if kind == 0 || duration <= 0 {
            return 0
        }
        return Double(Int32(start.x)) + Double(start.y) + Double(duration)
    }

    /// CPU mirror of `spring_sample` in `gpu/springs.wgsl`.
    public func sample(at timeSeconds: Double) -> (position: Float, velocity: Float) {
        let now = splitSpringTime(timeSeconds)
        let whole = Float(Int32(now.x) - Int32(start.x))
        let t = max(whole + (now.y - start.y), 0.0)
        if kind == 0 || t >= duration {
            return (goal, 0.0)
        }
        if kind == 1 {
            let e = expf(-rates.x * t)
            let co = cosf(rates.y * t)
            let si = sinf(rates.y * t)
            return (
                goal + e * (abcd.x * co + abcd.y * si),
                e * (abcd.z * co + abcd.w * si)
            )
        }
        if kind == 2 {
            let e = expf(-rates.x * t)
            return (
                goal + (abcd.x + abcd.y * t) * e,
                (abcd.z + abcd.w * t) * e
            )
        }
        let e1 = expf(max(-87.0, abcd.z * t))
        let e2 = expf(max(-87.0, abcd.w * t))
        return (
            goal + abcd.x * e1 + abcd.y * e2,
            abcd.x * abcd.z * e1 + abcd.y * abcd.w * e2
        )
    }
}

/// 144-byte GPU spring node (`x`, `y`, `opacity`) evaluated per instance in `vs_springs`.
public struct GPUSpringNode: Sendable, Equatable {
    public var x: GPUSpringTrack
    public var y: GPUSpringTrack
    public var opacity: GPUSpringTrack

    public init(
        x: GPUSpringTrack = GPUSpringTrack(),
        y: GPUSpringTrack = GPUSpringTrack(),
        opacity: GPUSpringTrack = GPUSpringTrack(goal: 1)
    ) {
        self.x = x
        self.y = y
        self.opacity = opacity
    }

    public func settleAt() -> Double {
        max(x.settleAt(), max(y.settleAt(), opacity.settleAt()))
    }
}

// MARK: - Gaussian Layer Blur Math (`render/layer_blur.rs`)

public enum LayerBlurConstants {
    public static let maxSigma: Float = 64.0
    public static let maxTaps: Int = 128
    public static let maxReduction: Int = 8
}

/// Bilinear-reduced symmetric Gaussian tap kernel for `layer_blur_fs`.
public struct LayerBlurKernel: Sendable, Equatable {
    public let reduction: Int
    public let reductionScale: SIMD2<Float>
    public let reducedSize: (width: Int, height: Int)
    /// Pairs `(offsetInWorkTexels, weight)`. Index `0` is center `(0, w0)`.
    public let taps: [SIMD2<Float>]
    public let verticalTaps: [SIMD2<Float>]

    public static func == (lhs: LayerBlurKernel, rhs: LayerBlurKernel) -> Bool {
        lhs.reduction == rhs.reduction
            && lhs.reductionScale == rhs.reductionScale
            && lhs.reducedSize.width == rhs.reducedSize.width
            && lhs.reducedSize.height == rhs.reducedSize.height
            && lhs.taps == rhs.taps
            && lhs.verticalTaps == rhs.verticalTaps
    }

    public init(
        reduction: Int,
        reductionScale: SIMD2<Float> = SIMD2<Float>(1, 1),
        reducedSize: (width: Int, height: Int) = (0, 0),
        taps: [SIMD2<Float>],
        verticalTaps: [SIMD2<Float>]? = nil
    ) {
        self.reduction = reduction
        self.reductionScale = reductionScale
        self.reducedSize = reducedSize
        self.taps = taps
        self.verticalTaps = verticalTaps ?? taps
    }

    public static func make(sigma: Float) -> LayerBlurKernel {
        let clamped = min(max(sigma, 0.001), LayerBlurConstants.maxSigma)
        let reduction = min(max(clamped / 3.0, 1.0), Float(LayerBlurConstants.maxReduction))
        let variance = (reduction * reduction - 1.0) * 0.25
        let eff = sqrt(max(1e-6, clamped * clamped - variance)) / reduction
        let taps = makeAxisTaps(effectiveSigma: eff)
        return LayerBlurKernel(
            reduction: max(1, Int(ceilf(reduction))),
            reductionScale: SIMD2<Float>(reduction, reduction),
            reducedSize: (0, 0),
            taps: taps,
            verticalTaps: taps
        )
    }

    public static func make(sigma: Float, width: Int, height: Int) -> LayerBlurKernel {
        let clamped = min(max(sigma, 0.001), LayerBlurConstants.maxSigma)
        let reduction = min(max(clamped / 3.0, 1.0), Float(LayerBlurConstants.maxReduction))
        let w = max(1, width)
        let h = max(1, height)
        let rw = max(1, Int(ceilf(Float(w) / reduction)))
        let rh = max(1, Int(ceilf(Float(h) / reduction)))
        let sx = Float(w) / Float(rw)
        let sy = Float(h) / Float(rh)
        let vx = (sx * sx - 1.0) * 0.25
        let vy = (sy * sy - 1.0) * 0.25
        let ex = sqrt(max(1e-6, clamped * clamped - vx)) / sx
        let ey = sqrt(max(1e-6, clamped * clamped - vy)) / sy
        return LayerBlurKernel(
            reduction: (rw != w || rh != h) ? max(2, Int(ceilf(max(sx, sy)))) : 1,
            reductionScale: SIMD2<Float>(sx, sy),
            reducedSize: (rw, rh),
            taps: makeAxisTaps(effectiveSigma: ex),
            verticalTaps: makeAxisTaps(effectiveSigma: ey)
        )
    }

    private static func makeAxisTaps(effectiveSigma: Float) -> [SIMD2<Float>] {
        if effectiveSigma < 0.05 {
            return [SIMD2<Float>(0, 1)]
        }
        let radius = min(Int(ceilf(effectiveSigma * 3.0)), LayerBlurConstants.maxTaps * 2 - 2)
        var rawWeights = [Float](repeating: 0, count: radius + 1)
        let invTwoVar = 0.5 / (effectiveSigma * effectiveSigma)
        var total: Float = 1.0
        rawWeights[0] = 1.0
        if radius >= 1 {
            for k in 1...radius {
                let w = expf(-Float(k * k) * invTwoVar)
                rawWeights[k] = w
                total += 2.0 * w
            }
        }
        for k in 0...radius {
            rawWeights[k] /= total
        }
        var taps: [SIMD2<Float>] = [SIMD2<Float>(0, rawWeights[0])]
        var i = 1
        while i <= radius && taps.count < LayerBlurConstants.maxTaps {
            if i + 1 <= radius {
                let w1 = rawWeights[i]
                let w2 = rawWeights[i + 1]
                let w = w1 + w2
                if w > 1e-6 {
                    let offset = Float(i) + w2 / w
                    taps.append(SIMD2<Float>(offset, w))
                }
                i += 2
            } else {
                if rawWeights[i] > 1e-6 {
                    taps.append(SIMD2<Float>(Float(i), rawWeights[i]))
                }
                i += 1
            }
        }
        return taps
    }
}

// MARK: - Backdrop Blur Constants & Level Schedule (`render/backdrop_blur.rs`)

public enum BackdropBlurSchedule {
    public static let mips: Int = 7
    public static let step: Int = 1 << (mips - 1) // 64
    public static let sigmas: [Float] = [1.58, 4.53, 9.62, 19.51, 39.15, 78.36, 156.2]

    /// Packed 64-byte uniform buffer matching `BlurLevel` in `backdrop_blur.wgsl` / `backdrop_composite.wgsl`.
    public struct Uniforms: Sendable, Equatable {
        public var w: SIMD4<Float>
        public var region: SIMD4<Float>
        public var map: SIMD4<Float>
        public var place: SIMD4<Float>

        public init(
            w: SIMD4<Float> = .zero,
            region: SIMD4<Float> = .zero,
            map: SIMD4<Float> = .zero,
            place: SIMD4<Float> = .zero
        ) {
            self.w = w
            self.region = region
            self.map = map
            self.place = place
        }
    }

    public struct LevelStep: Sendable, Equatable {
        public let level: Int
        public let blend: Float
    }

    /// Maps `(sigma, top)` to the up-chain start level `n` (`1...top`, running `n + 1` down passes
    /// and `n` up passes) and the variance-linear crossfade share of level `n` (`render/backdrop_blur.rs`).
    public static func levels(sigma: Float, top: Int = mips - 1) -> (count: Int, topBlend: Float) {
        guard sigma > 0.0, top >= 1 else {
            return (0, 0)
        }
        let maxTop = min(max(top, 1), sigmas.count - 1)
        let s = min(max(sigma, sigmas[0]), sigmas[maxTop])
        let n = (1...maxTop).first(where: { s <= sigmas[$0] }) ?? maxTop
        let a = sigmas[n - 1]
        let b = sigmas[n]
        let share = min(max((s * s - a * a) / (b * b - a * a), 0.0), 1.0)
        return (n, share)
    }
}

#if canImport(Metal)
@preconcurrency import Metal

// MARK: - GPU Spring Bindings

/// Holds device buffers `(spring_nodes, spring_ids)` and tracks active GPU spring settle deadline.
public final class GPUSpringBindings {
    public private(set) var nodes: [GPUSpringNode]
    public private(set) var ids: [UInt32]
    public private(set) var nodesBuffer: MTLBuffer?
    public private(set) var idsBuffer: MTLBuffer?
    public private(set) var settleAt: Double

    public init(device: MTLDevice, nodes: [GPUSpringNode] = [], ids: [UInt32] = []) {
        self.nodes = nodes
        self.ids = ids
        self.settleAt = nodes.reduce(0.0) { max($0, $1.settleAt()) }
        rebuildBuffers(device: device)
    }

    public func hasActiveMotion(at timeSeconds: Double) -> Bool {
        settleAt > timeSeconds
    }

    public func update(device: MTLDevice, nodes: [GPUSpringNode], ids: [UInt32]) {
        self.nodes = nodes
        self.ids = ids
        self.settleAt = nodes.reduce(0.0) { max($0, $1.settleAt()) }
        rebuildBuffers(device: device)
    }

    /// Updates a single spring node in-place without regenerating instance buffers.
    public func updateNode(index: Int, node: GPUSpringNode) {
        guard index >= 0 && index < nodes.count else { return }
        nodes[index] = node
        settleAt = max(settleAt, node.settleAt())
        if let buf = nodesBuffer {
            let offset = index * MemoryLayout<GPUSpringNode>.stride
            if offset + MemoryLayout<GPUSpringNode>.stride <= buf.length {
                let ptr = buf.contents().advanced(by: offset).assumingMemoryBound(to: GPUSpringNode.self)
                ptr.pointee = node
            }
        }
    }

    private func rebuildBuffers(device: MTLDevice) {
        let nodeBytes = max(1, nodes.count) * MemoryLayout<GPUSpringNode>.stride
        if !nodes.isEmpty {
            if let existing = nodesBuffer, existing.length >= nodeBytes {
                nodes.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        memcpy(existing.contents(), base, nodes.count * MemoryLayout<GPUSpringNode>.stride)
                    }
                }
            } else {
                nodesBuffer = nodes.withUnsafeBytes { raw in
                    device.makeBuffer(bytes: raw.baseAddress!, length: nodeBytes, options: .storageModeShared)
                }
            }
        }
        let idBytes = max(1, ids.count) * MemoryLayout<UInt32>.stride
        if !ids.isEmpty {
            if let existing = idsBuffer, existing.length >= idBytes {
                ids.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        memcpy(existing.contents(), base, ids.count * MemoryLayout<UInt32>.stride)
                    }
                }
            } else {
                idsBuffer = ids.withUnsafeBytes { raw in
                    device.makeBuffer(bytes: raw.baseAddress!, length: idBytes, options: .storageModeShared)
                }
            }
        }
    }
}

// MARK: - Layer Target Pool & 64 MiB LRU Cache (`render/layers.rs` + `#819`)

public enum LayerPoolLimits {
    public static let maxDimension: Int = 4096
    public static let spareBudgetBytes: Int = 32 * 1024 * 1024
    public static let restingSpareBudgetBytes: Int = 8 * 1024 * 1024
}

public struct LayerTextureSlot {
    public let texture: MTLTexture
    public let width: Int
    public let height: Int
    public let byteSize: Int
    public var lastUsedFrame: UInt64

    public init(texture: MTLTexture, lastUsedFrame: UInt64 = 0) {
        self.texture = texture
        self.width = texture.width
        self.height = texture.height
        self.byteSize = texture.width * texture.height * 8 // rgba16Float = 8 bytes/pixel
        self.lastUsedFrame = lastUsedFrame
    }
}

public struct LayerDrawPlan: Sendable, Equatable {
    public var targetIndex: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var originX: Float
    public var originY: Float
    public var cacheKey: UInt64
    public var cacheable: Bool
    public var drawIndices: [Int]
}

/// Manages bounded `rgba16Float` layer render targets, 64 MiB LRU layer caching, and `#819` GPU give-back on rest.
public final class LayersPool {
    private struct RetainedEntry {
        var signature: UInt64
        var slot: LayerTextureSlot
    }

    private struct WeakTracker {
        weak var value: ResidentLayerTracker?
    }

    public private(set) var cacheBudgetBytes: Int = Int(DEFAULT_LAYER_CACHE_BUDGET)
    public private(set) var frameNumber: UInt64 = 0

    private var retained: [UInt64: RetainedEntry] = [:]
    private var spare: [LayerTextureSlot] = []
    private var inUse: [LayerTextureSlot] = []
    private var trackers: [WeakTracker] = []

    private var retainedHits: UInt64 = 0
    private var retainedMisses: UInt64 = 0
    private var evictions: UInt64 = 0
    private var allocations: UInt64 = 0
    private var lastFrameExtraPasses: Int = 0

    public init(cacheBudgetBytes: Int = Int(DEFAULT_LAYER_CACHE_BUDGET)) {
        self.cacheBudgetBytes = max(0, cacheBudgetBytes)
    }

    public func registerTracker(_ tracker: ResidentLayerTracker?) {
        guard let tracker else { return }
        trackers.removeAll { $0.value == nil }
        if !trackers.contains(where: { $0.value === tracker }) {
            trackers.append(WeakTracker(value: tracker))
        }
    }

    public func recordExtraPass(_ count: Int = 1) {
        lastFrameExtraPasses += max(0, count)
    }

    public func setCacheBudget(_ bytes: Int) {
        cacheBudgetBytes = max(0, bytes)
        evictRetainedToBudget()
    }

    public func beginFrame() {
        frameNumber &+= 1
        lastFrameExtraPasses = 0
        releaseInUse()
    }

    public func endFrame() {
        releaseInUse()
    }

    public func releaseInUse() {
        guard !inUse.isEmpty else { return }
        for var slot in inUse {
            slot.lastUsedFrame = frameNumber
            spare.append(slot)
        }
        inUse.removeAll(keepingCapacity: true)
        trimSpare(budget: LayerPoolLimits.spareBudgetBytes)
    }

    /// Acquires a bounded `rgba16Float` target (`[1, 4096]`) from the spare pool or allocates a new GPU texture.
    public func acquireTarget(
        device: MTLDevice,
        width: Int,
        height: Int,
        format: MTLPixelFormat = .rgba16Float,
        label: String = "rune.layer.target"
    ) -> MTLTexture? {
        let w = min(max(width, 1), LayerPoolLimits.maxDimension)
        let h = min(max(height, 1), LayerPoolLimits.maxDimension)
        if let idx = spare.firstIndex(where: { $0.width == w && $0.height == h && $0.texture.pixelFormat == format }) {
            var slot = spare.remove(at: idx)
            slot.lastUsedFrame = frameNumber
            inUse.append(slot)
            return slot.texture
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.label = label
        allocations &+= 1
        let slot = LayerTextureSlot(texture: tex, lastUsedFrame: frameNumber)
        inUse.append(slot)
        return tex
    }

    /// Acquires a standalone `rgba16Float` render target for retained layer caching (caller owns until stored).
    public func acquireRetainedTarget(
        device: MTLDevice,
        width: Int,
        height: Int,
        format: MTLPixelFormat = .rgba16Float
    ) -> MTLTexture? {
        let w = min(max(width, 1), LayerPoolLimits.maxDimension)
        let h = min(max(height, 1), LayerPoolLimits.maxDimension)
        if let idx = spare.firstIndex(where: { $0.width == w && $0.height == h && $0.texture.pixelFormat == format }) {
            return spare.remove(at: idx).texture
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.label = "rune.layer.retained"
        allocations &+= 1
        return tex
    }

    public func detachInUse(_ texture: MTLTexture) {
        if let idx = inUse.firstIndex(where: { $0.texture === texture }) {
            inUse.remove(at: idx)
        }
    }

    public func recycleTarget(_ texture: MTLTexture) {
        if let idx = inUse.firstIndex(where: { $0.texture === texture }) {
            inUse.remove(at: idx)
        }
        spare.append(LayerTextureSlot(texture: texture, lastUsedFrame: frameNumber))
        trimSpare(budget: LayerPoolLimits.spareBudgetBytes)
    }

    public func lookupRetained(key: UInt64, signature: UInt64? = nil, width: Int, height: Int) -> MTLTexture? {
        guard var entry = retained[key] else {
            retainedMisses &+= 1
            return nil
        }
        let w = min(max(width, 1), LayerPoolLimits.maxDimension)
        let h = min(max(height, 1), LayerPoolLimits.maxDimension)
        if let sig = signature, entry.signature != sig {
            retainedMisses &+= 1
            return nil
        }
        guard entry.slot.width == w && entry.slot.height == h else {
            retainedMisses &+= 1
            return nil
        }
        entry.slot.lastUsedFrame = frameNumber
        retained[key] = entry
        retainedHits &+= 1
        return entry.slot.texture
    }

    public func storeRetained(key: UInt64, signature: UInt64 = 0, texture: MTLTexture) {
        let slot = LayerTextureSlot(texture: texture, lastUsedFrame: frameNumber)
        if slot.byteSize > cacheBudgetBytes {
            spare.append(slot)
            trimSpare(budget: LayerPoolLimits.spareBudgetBytes)
            notifyEvicted(key)
            return
        }
        if let previous = retained.removeValue(forKey: key) {
            spare.append(previous.slot)
        }
        retained[key] = RetainedEntry(signature: signature, slot: slot)
        evictRetainedToBudget()
    }

    /// Gives back temporary or cached GPU memory (`#819` GPU give-back on window rest / hide).
    ///
    /// - `all == false` (idle rest): trims spare buffers down to 8 MiB and drops retained caches if `!residentCaches`.
    /// - `all == true` (window occluded/hidden): releases all spare and retained textures immediately.
    public func giveBack(all: Bool = false, residentCaches: Bool = false) {
        releaseInUse()
        if all {
            spare.removeAll()
            retained.removeAll()
            notifyCleared()
            return
        }
        trimSpare(budget: LayerPoolLimits.restingSpareBudgetBytes)
        if !residentCaches {
            retained.removeAll()
            notifyCleared()
        }
    }

    public func stats() -> LayerStats {
        let cached = retained.values.reduce(0) { $0 + $1.slot.byteSize }
        let spareBytes = spare.reduce(0) { $0 + $1.byteSize }
        let live = inUse.reduce(0) { $0 + $1.byteSize } + spareBytes
        return LayerStats(
            targets: inUse.count + spare.count + retained.count,
            bytes: UInt64(max(0, live + cached)),
            extraPasses: lastFrameExtraPasses,
            allocations: allocations,
            cachedLayers: retained.count,
            cachedBytes: UInt64(max(0, cached)),
            hits: retainedHits,
            misses: retainedMisses,
            evictions: evictions
        )
    }

    private func evictRetainedToBudget() {
        var total = retained.values.reduce(0) { $0 + $1.slot.byteSize }
        while total > cacheBudgetBytes,
              let oldest = retained.min(by: { $0.value.slot.lastUsedFrame < $1.value.slot.lastUsedFrame })
        {
            if let removed = retained.removeValue(forKey: oldest.key) {
                total -= removed.slot.byteSize
                spare.append(removed.slot)
                evictions &+= 1
                notifyEvicted(oldest.key)
            } else {
                break
            }
        }
        trimSpare(budget: LayerPoolLimits.spareBudgetBytes)
    }

    private func notifyEvicted(_ key: UInt64) {
        trackers.removeAll { $0.value == nil }
        for t in trackers { t.value?.evict(nodeId: key) }
    }

    private func notifyCleared() {
        trackers.removeAll { $0.value == nil }
        for t in trackers { t.value?.clear() }
    }

    private func trimSpare(budget: Int) {
        var total = spare.reduce(0) { $0 + $1.byteSize }
        while total > budget && !spare.isEmpty {
            let victim = spare.removeFirst()
            total -= victim.byteSize
        }
    }
}

// MARK: - Shader Library Loader & Precompiled Metallib Lookup

/// Loads precompiled `.metallib` libraries when bundled, otherwise compiles and caches MSL source per `MTLDevice`.
public enum ShaderLibraryCache {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var libs: [Key: MTLLibrary] = [:]
    }

    private struct Key: Hashable {
        let deviceId: UInt
        let name: String
    }

    private static let box = Box()

    public static func load(
        named name: String,
        source: String,
        requiredFunction: String,
        on device: MTLDevice
    ) throws -> MTLLibrary {
        let key = Key(deviceId: UInt(bitPattern: ObjectIdentifier(device)), name: name)
        box.lock.lock()
        if let cached = box.libs[key] {
            box.lock.unlock()
            return cached
        }
        box.lock.unlock()

        let resolved: MTLLibrary
        if let precompiled = findPrecompiled(named: name, requiredFunction: requiredFunction, on: device) {
            resolved = precompiled
        } else {
            resolved = try device.makeLibrary(source: source, options: nil)
        }

        box.lock.lock()
        box.libs[key] = resolved
        box.lock.unlock()
        return resolved
    }

    private static func findPrecompiled(
        named name: String,
        requiredFunction: String,
        on device: MTLDevice
    ) -> MTLLibrary? {
        let bundles: [Bundle] = [Bundle.main, Bundle(for: LayerBlurPipeline.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: "metallib"),
               let lib = try? device.makeLibrary(URL: url),
               lib.functionNames.contains(requiredFunction) {
                return lib
            }
        }
        if let def = device.makeDefaultLibrary(), def.functionNames.contains(requiredFunction) {
            return def
        }
        return nil
    }
}

// MARK: - Gaussian Layer Blur Pipeline (`render/layer_blur.rs`)

/// Compiles specialized `layerBlurMSL` pipelines (`LBLUR_MODE` 0/1/2/3 x `LBLUR_ADDITIVE`) and runs H/V separable blur.
public final class LayerBlurPipeline {
    private let pipelineBlur: MTLRenderPipelineState
    private let pipelineBlurAdditive: MTLRenderPipelineState
    private let pipelinePrefilter: MTLRenderPipelineState
    private let pipelineResample: MTLRenderPipelineState
    private let pipelinePrefilterAdditive: MTLRenderPipelineState
    private let pipelineResampleAdditive: MTLRenderPipelineState
    private let linearSampler: MTLSamplerState

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .rgba16Float) throws {
        let library = try ShaderLibraryCache.load(
            named: "layer_blur",
            source: RenderShaders.layerBlurMSL,
            requiredFunction: "layer_blur_vs",
            on: device
        )
        let vs = library.makeFunction(name: "layer_blur_vs")!

        func makeSpecialized(mode: UInt32, additive: Bool) throws -> MTLRenderPipelineState {
            let constants = MTLFunctionConstantValues()
            var modeVar = mode
            var addVar = additive
            constants.setConstantValue(&modeVar, type: .uint, index: 0)
            constants.setConstantValue(&addVar, type: .bool, index: 1)
            let fs = try library.makeFunction(name: "layer_blur_fs", constantValues: constants)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vs
            desc.fragmentFunction = fs
            desc.colorAttachments[0].pixelFormat = pixelFormat
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        self.pipelineBlur = try makeSpecialized(mode: 0, additive: false)
        self.pipelineBlurAdditive = try makeSpecialized(mode: 0, additive: true)
        self.pipelinePrefilter = try makeSpecialized(mode: 2, additive: false)
        self.pipelinePrefilterAdditive = try makeSpecialized(mode: 2, additive: true)
        self.pipelineResample = try makeSpecialized(mode: 3, additive: false)
        self.pipelineResampleAdditive = try makeSpecialized(mode: 3, additive: true)

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.sAddressMode = .clampToEdge
        sampDesc.tAddressMode = .clampToEdge
        self.linearSampler = device.makeSamplerState(descriptor: sampDesc)!
    }

    /// Blurs `source` (`width x height` `.rgba16Float`) using Gaussian `sigma` and returns the output texture.
    /// When `additive == true`, negative/overshoot channels are clamped to `[0, 1]` before tapping (matches `layer_blur.rs`).
    public func encode(
        device: MTLDevice,
        commandBuffer: MTLCommandBuffer,
        pool: LayersPool,
        source: MTLTexture,
        sigma: Float,
        additive: Bool = false
    ) -> MTLTexture? {
        if sigma < 0.05 {
            return source
        }
        let w = source.width
        let h = source.height
        let kernel = LayerBlurKernel.make(sigma: sigma, width: w, height: h)
        let rw = kernel.reducedSize.width
        let rh = kernel.reducedSize.height
        let isReduced = (rw != w || rh != h)
        if !isReduced && kernel.taps.count <= 1 && kernel.verticalTaps.count <= 1 {
            return source
        }

        var uniforms = [SIMD4<Float>](repeating: .zero, count: 130)
        for (idx, tap) in kernel.taps.prefix(LayerBlurConstants.maxTaps).enumerated() {
            uniforms[2 + idx] = SIMD4<Float>(tap.x, tap.y, 0, 0)
        }

        var hInput: MTLTexture = source
        if isReduced {
            guard let reduced = pool.acquireTarget(device: device, width: rw, height: rh, format: source.pixelFormat, label: "rune.lblur.prefilter") else {
                return nil
            }
            uniforms[0] = SIMD4<Float>(Float(w), Float(h), 2, 0)
            uniforms[1] = SIMD4<Float>(kernel.reductionScale.x, kernel.reductionScale.y, 0, 0)
            encodePass(
                commandBuffer: commandBuffer,
                pipeline: additive ? pipelinePrefilterAdditive : pipelinePrefilter,
                source: source,
                target: reduced,
                uniforms: &uniforms
            )
            hInput = reduced
        }

        guard let ping = pool.acquireTarget(device: device, width: rw, height: rh, format: source.pixelFormat, label: "rune.lblur.ping") else {
            return nil
        }
        uniforms[0] = SIMD4<Float>(Float(rw), Float(rh), 0, Float(kernel.taps.count))
        uniforms[1] = SIMD4<Float>(1, 1, 0, 0)
        encodePass(
            commandBuffer: commandBuffer,
            pipeline: additive ? pipelineBlurAdditive : pipelineBlur,
            source: hInput,
            target: ping,
            uniforms: &uniforms
        )

        for (idx, tap) in kernel.verticalTaps.prefix(LayerBlurConstants.maxTaps).enumerated() {
            uniforms[2 + idx] = SIMD4<Float>(tap.x, tap.y, 0, 0)
        }
        guard let pong = pool.acquireTarget(device: device, width: rw, height: rh, format: source.pixelFormat, label: "rune.lblur.pong") else {
            return nil
        }
        uniforms[0] = SIMD4<Float>(Float(rw), Float(rh), 1, Float(kernel.verticalTaps.count))
        uniforms[1] = SIMD4<Float>(1, 1, 0, 0)
        encodePass(
            commandBuffer: commandBuffer,
            pipeline: additive ? pipelineBlurAdditive : pipelineBlur,
            source: ping,
            target: pong,
            uniforms: &uniforms
        )

        if !isReduced {
            return pong
        }
        guard let finalTex = pool.acquireTarget(device: device, width: w, height: h, format: source.pixelFormat, label: "rune.lblur.final") else {
            return nil
        }
        uniforms[0] = SIMD4<Float>(Float(rw), Float(rh), 3, 0)
        uniforms[1] = SIMD4<Float>(1.0 / kernel.reductionScale.x, 1.0 / kernel.reductionScale.y, 0, 0)
        encodePass(
            commandBuffer: commandBuffer,
            pipeline: additive ? pipelineResampleAdditive : pipelineResample,
            source: pong,
            target: finalTex,
            uniforms: &uniforms
        )
        return finalTex
    }

    private func encodePass(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        source: MTLTexture,
        target: MTLTexture,
        uniforms: inout [SIMD4<Float>]
    ) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentSamplerState(linearSampler, index: 0)
        uniforms.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                enc.setFragmentBytes(base, length: raw.count, index: 0)
            }
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}

// MARK: - Backdrop Dual-Kawase Pyramid & Composite (`render/backdrop_blur.rs`)

/// 7-mip Jimenez/tent backdrop blur pass + masked rounded composite (`MAX_BACKDROP_BLURS = 4`).
public final class BackdropBlurPass {
    private let pipelineDown: MTLRenderPipelineState
    private let pipelineUp: MTLRenderPipelineState
    private let compositeStraight: MTLRenderPipelineState
    private let compositeSRGB: MTLRenderPipelineState
    private let compositeFloat: MTLRenderPipelineState
    private let samplerLinear: MTLSamplerState

    private var downMips: [MTLTexture] = []
    private var upMips: [MTLTexture] = []
    private var pyramidWidth: Int = 0
    private var pyramidHeight: Int = 0
    private var backdropCopy: MTLTexture?

    public init(device: MTLDevice) throws {
        let blurLib = try ShaderLibraryCache.load(
            named: "backdrop_blur",
            source: RenderShaders.backdropBlurMSL,
            requiredFunction: "backdrop_blur_vs",
            on: device
        )
        let blurVS = blurLib.makeFunction(name: "backdrop_blur_vs")!
        let downFS = blurLib.makeFunction(name: "backdrop_blur_down")!
        let upFS = blurLib.makeFunction(name: "backdrop_blur_up")!

        let downDesc = MTLRenderPipelineDescriptor()
        downDesc.vertexFunction = blurVS
        downDesc.fragmentFunction = downFS
        downDesc.colorAttachments[0].pixelFormat = .rgba16Float
        self.pipelineDown = try device.makeRenderPipelineState(descriptor: downDesc)

        let upDesc = MTLRenderPipelineDescriptor()
        upDesc.vertexFunction = blurVS
        upDesc.fragmentFunction = upFS
        upDesc.colorAttachments[0].pixelFormat = .rgba16Float
        self.pipelineUp = try device.makeRenderPipelineState(descriptor: upDesc)

        let compLib = try ShaderLibraryCache.load(
            named: "backdrop_composite",
            source: RenderShaders.backdropCompositeMSL,
            requiredFunction: "backdrop_composite_vs",
            on: device
        )
        let compVS = compLib.makeFunction(name: "backdrop_composite_vs")!
        let compFS = compLib.makeFunction(name: "backdrop_composite_fs")!

        func makeCompositePipeline(_ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = compVS
            desc.fragmentFunction = compFS
            let att = desc.colorAttachments[0]!
            att.pixelFormat = format
            att.isBlendingEnabled = true
            att.sourceRGBBlendFactor = .one
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.rgbBlendOperation = .add
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            att.alphaBlendOperation = .add
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        self.compositeStraight = try makeCompositePipeline(.bgra8Unorm)
        self.compositeSRGB = try makeCompositePipeline(.bgra8Unorm_srgb)
        self.compositeFloat = try makeCompositePipeline(.rgba16Float)

        let samp = MTLSamplerDescriptor()
        samp.minFilter = .linear
        samp.magFilter = .linear
        samp.sAddressMode = .clampToEdge
        samp.tAddressMode = .clampToEdge
        self.samplerLinear = device.makeSamplerState(descriptor: samp)!
    }

    /// Drops retained pyramid mip textures (`#819` give-back on window rest/occlusion).
    public func giveBack() {
        downMips.removeAll()
        upMips.removeAll()
        pyramidWidth = 0
        pyramidHeight = 0
        backdropCopy = nil
    }

    private static func nextMultiple(_ v: Int, of step: Int) -> Int {
        guard v > 0 else { return step }
        return ((v + step - 1) / step) * step
    }

    private func ensureBackdropCopy(device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
        if let existing = backdropCopy,
           existing.width == width,
           existing.height == height,
           existing.pixelFormat == format {
            return existing
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: max(1, width),
            height: max(1, height),
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .private
        let tex = device.makeTexture(descriptor: desc)
        tex?.label = "rune.backdrop.copy"
        backdropCopy = tex
        return tex
    }

    private func ensurePyramid(device: MTLDevice, needWidth: Int, needHeight: Int, capWidth: Int, capHeight: Int) {
        let step = BackdropBlurSchedule.step
        let clampedNeedW = max(step, needWidth)
        let clampedNeedH = max(step, needHeight)
        let w = max(clampedNeedW, min(pyramidWidth, capWidth))
        let h = max(clampedNeedH, min(pyramidHeight, capHeight))
        if w == pyramidWidth && h == pyramidHeight && downMips.count == BackdropBlurSchedule.mips {
            return
        }
        downMips.removeAll(keepingCapacity: true)
        upMips.removeAll(keepingCapacity: true)
        pyramidWidth = w
        pyramidHeight = h
        for level in 0..<BackdropBlurSchedule.mips {
            let mw = max(1, w >> level)
            let mh = max(1, h >> level)
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: mw,
                height: mh,
                mipmapped: false
            )
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            if let tex = device.makeTexture(descriptor: desc) {
                tex.label = "rune.backdrop.down.\(level)"
                downMips.append(tex)
            }
            if level < BackdropBlurSchedule.mips - 1, let upTex = device.makeTexture(descriptor: desc) {
                upTex.label = "rune.backdrop.up.\(level)"
                upMips.append(upTex)
            }
        }
    }

    /// Encodes a single `KIND_BACKDROP_BLUR` instance: copies the bounded region from `source`, runs the
    /// `(n + 1)` down / `n` up pyramid passes with `(2 << n)` origin alignment, and composites with rounded SDF clip.
    public func encode(
        device: MTLDevice,
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        target: MTLTexture,
        targetFormat: MTLPixelFormat,
        instanceIndex: Int,
        instance: RenderInstance,
        instanceBuffer: MTLBuffer,
        globalsBuffer: MTLBuffer,
        viewport: SIMD2<Float>,
        originOffset: SIMD2<Float>
    ) {
        let sigma = max(instance.params.x, 0.0)
        if sigma <= 0.0 || instance.fill.w <= 0.0 {
            return
        }
        let (n, share) = BackdropBlurSchedule.levels(sigma: sigma, top: BackdropBlurSchedule.mips - 1)
        guard n >= 1 else { return }

        let srcW = Float(source.width)
        let srcH = Float(source.height)
        guard srcW > 0, srcH > 0 else { return }

        let reach = min(sigma, BackdropBlurSchedule.sigmas[n]) * 3.0 + 2.0
        let rx0 = max(0.0, instance.rect.x - originOffset.x - reach)
        let ry0 = max(0.0, instance.rect.y - originOffset.y - reach)
        let rx1 = min(srcW, instance.rect.x - originOffset.x + instance.rect.z + reach)
        let ry1 = min(srcH, instance.rect.y - originOffset.y + instance.rect.w + reach)
        if rx1 <= rx0 || ry1 <= ry0 { return }

        let clipEdge: (Float, Float, Int) -> Int = { v, o, maxV in
            min(max(Int(v - o), 0), maxV)
        }
        let compX0 = clipEdge(floorf(max(instance.rect.x, instance.clip.x)), originOffset.x, target.width)
        let compY0 = clipEdge(floorf(max(instance.rect.y, instance.clip.y)), originOffset.y, target.height)
        let compX1 = clipEdge(ceilf(min(instance.rect.x + instance.rect.z, instance.clip.z)), originOffset.x, target.width)
        let compY1 = clipEdge(ceilf(min(instance.rect.y + instance.rect.w, instance.clip.w)), originOffset.y, target.height)
        if compX1 <= compX0 || compY1 <= compY0 { return }

        let align = Float(2 << n)
        let origin = SIMD2<Float>(floorf(rx0 / align) * align, floorf(ry0 / align) * align)
        let step = BackdropBlurSchedule.step
        let needW = Self.nextMultiple(Int(ceilf((rx1 - origin.x) / 2.0)), of: step)
        let needH = Self.nextMultiple(Int(ceilf((ry1 - origin.y) / 2.0)), of: step)
        let capW = Self.nextMultiple(((source.width + 1) / 2) + step, of: step)
        let capH = Self.nextMultiple(((source.height + 1) / 2) + step, of: step)
        ensurePyramid(device: device, needWidth: needW, needHeight: needH, capWidth: capW, capHeight: capH)
        guard downMips.count > n, !upMips.isEmpty else { return }

        guard let snapshot = ensureBackdropCopy(device: device, width: source.width, height: source.height, format: source.pixelFormat) else {
            return
        }
        let copyX0 = max(0, min(source.width - 1, Int(floorf(rx0))))
        let copyY0 = max(0, min(source.height - 1, Int(floorf(ry0))))
        let copyX1 = max(copyX0 + 1, min(source.width, Int(ceilf(rx1))))
        let copyY1 = max(copyY0 + 1, min(source.height, Int(ceilf(ry1))))
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: source,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: copyX0, y: copyY0, z: 0),
                sourceSize: MTLSize(width: copyX1 - copyX0, height: copyY1 - copyY0, depth: 1),
                to: snapshot,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: copyX0, y: copyY0, z: 0)
            )
            blit.endEncoding()
        }

        let extent = SIMD2<Float>(Float(pyramidWidth) * 2.0, Float(pyramidHeight) * 2.0)
        let inside = SIMD4<Float>(
            (rx0 - origin.x) / extent.x,
            (ry0 - origin.y) / extent.y,
            (rx1 - origin.x) / extent.x,
            (ry1 - origin.y) / extent.y
        )
        let place = SIMD4<Float>(originOffset.x + origin.x, originOffset.y + origin.y, extent.x, extent.y)
        let firstRegionUV = SIMD4<Float>(rx0 / srcW, ry0 / srcH, rx1 / srcW, ry1 / srcH)
        let firstMapUV = SIMD4<Float>(extent.x / srcW, extent.y / srcH, origin.x / srcW, origin.y / srcH)

        func scissorForMip(_ m: Int) -> MTLScissorRect {
            let k = Float(2 << m)
            let mw = max(1, pyramidWidth >> m)
            let mh = max(1, pyramidHeight >> m)
            let sx = min(max(Int(floorf((rx0 - origin.x) / k)) - 2, 0), mw - 1)
            let sy = min(max(Int(floorf((ry0 - origin.y) / k)) - 2, 0), mh - 1)
            let sr = min(max(Int(ceilf((rx1 - origin.x) / k)) + 2, sx + 1), mw)
            let sb = min(max(Int(ceilf((ry1 - origin.y) / k)) + 2, sy + 1), mh)
            return MTLScissorRect(x: sx, y: sy, width: sr - sx, height: sb - sy)
        }

        for m in 0...n {
            let dst = downMips[m]
            let srcTex = (m == 0) ? snapshot : downMips[m - 1]
            var u = BackdropBlurSchedule.Uniforms(
                w: SIMD4<Float>((m + 1 == n) ? share : 1.0, 0, 0, 0),
                region: (m == 0) ? firstRegionUV : inside,
                map: (m == 0) ? firstMapUV : SIMD4<Float>(1, 1, 0, 0),
                place: place
            )
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = dst
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                enc.setScissorRect(scissorForMip(m))
                enc.setRenderPipelineState(pipelineDown)
                enc.setFragmentTexture(srcTex, index: 0)
                enc.setFragmentTexture(downMips[0], index: 1)
                enc.setFragmentSamplerState(samplerLinear, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<BackdropBlurSchedule.Uniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        for m in stride(from: n - 1, through: 0, by: -1) {
            let coarse = (m + 1 == n) ? downMips[m + 1] : upMips[m + 1]
            let fine = downMips[m]
            let dst = upMips[m]
            let blend = (m + 1 == n) ? share : 1.0
            var u = BackdropBlurSchedule.Uniforms(
                w: SIMD4<Float>(blend, 0, 0, 0),
                region: inside,
                map: SIMD4<Float>(1, 1, 0, 0),
                place: place
            )
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = dst
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                enc.setScissorRect(scissorForMip(m))
                enc.setRenderPipelineState(pipelineUp)
                enc.setFragmentTexture(coarse, index: 0)
                enc.setFragmentTexture(fine, index: 1)
                enc.setFragmentSamplerState(samplerLinear, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<BackdropBlurSchedule.Uniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        let _ = viewport
        let compPipeline: MTLRenderPipelineState
        switch targetFormat {
        case .rgba16Float:
            compPipeline = compositeFloat
        case .bgra8Unorm_srgb:
            compPipeline = compositeSRGB
        default:
            compPipeline = compositeStraight
        }

        var compUniform = BackdropBlurSchedule.Uniforms(
            w: SIMD4<Float>(1.0, 0, 0, 0),
            region: inside,
            map: SIMD4<Float>(1, 1, 0, 0),
            place: place
        )
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setScissorRect(MTLScissorRect(x: compX0, y: compY0, width: compX1 - compX0, height: compY1 - compY0))
            enc.setRenderPipelineState(compPipeline)
            enc.setVertexBuffer(instanceBuffer, offset: instanceIndex * MemoryLayout<RenderInstance>.stride, index: 0)
            enc.setVertexBuffer(globalsBuffer, offset: 0, index: 1)
            enc.setFragmentTexture(upMips[0], index: 0)
            enc.setFragmentSamplerState(samplerLinear, index: 0)
            enc.setFragmentBytes(&compUniform, length: MemoryLayout<BackdropBlurSchedule.Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }
    }
}

// MARK: - Reused GPU Staging & Atlas Uploader (`render/upload.rs` + `#830`)

/// Reuses Metal staging/instance buffers and skips redundant atlas uploads by tracking `glyphGeneration` and `RGBA8Atlas.revision`.
public final class AtlasUploader {
    public private(set) var glyphTexture: MTLTexture?
    public private(set) var glyphGeneration: UInt64 = 0
    public private(set) var glyphSize: SIMD2<Int> = .zero

    public private(set) var imageTexture: MTLTexture?
    public private(set) var imageRevision: UInt64 = 0
    public private(set) var imageSize: SIMD2<Int> = .zero

    private var instanceBuffer: MTLBuffer?
    private var globalsBuffer: MTLBuffer?

    public init() {}

    public func ensureGlobalsBuffer(device: MTLDevice, globals: RenderGlobals) -> MTLBuffer? {
        let size = MemoryLayout<RenderGlobals>.stride
        if globalsBuffer == nil || (globalsBuffer?.length ?? 0) < size {
            globalsBuffer = device.makeBuffer(length: size, options: .storageModeShared)
            globalsBuffer?.label = "rune.render.globals"
        }
        guard let buf = globalsBuffer else { return nil }
        var g = globals
        memcpy(buf.contents(), &g, size)
        return buf
    }

    public func ensureInstanceBuffer(device: MTLDevice, instances: [RenderInstance]) -> MTLBuffer? {
        let needed = max(1, instances.count) * MemoryLayout<RenderInstance>.stride
        if let buf = instanceBuffer, buf.length >= needed {
            if !instances.isEmpty {
                instances.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        memcpy(buf.contents(), base, instances.count * MemoryLayout<RenderInstance>.stride)
                    }
                }
            }
            return buf
        }
        // Grow geometrically (`max(needed, old * 2)`) to avoid per-frame reallocations.
        let allocSize = max(needed, (instanceBuffer?.length ?? 0) * 2)
        guard let newBuf = device.makeBuffer(length: allocSize, options: .storageModeShared) else {
            return nil
        }
        newBuf.label = "rune.render.instances"
        if !instances.isEmpty {
            instances.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    memcpy(newBuf.contents(), base, instances.count * MemoryLayout<RenderInstance>.stride)
                }
            }
        }
        instanceBuffer = newBuf
        return newBuf
    }

    /// Uploads the R8 glyph atlas only when `generation` changes or dimensions grow.
    /// Avoids GPU allocation when the atlas is empty (`1x1` sentinel).
    public func syncGlyphAtlas(device: MTLDevice, atlas: R8Atlas, generation: UInt64) -> MTLTexture? {
        if atlas.width <= 1 && atlas.height <= 1 && (atlas.texels.isEmpty || atlas.texels == [0]) {
            if let existing = glyphTexture {
                return existing
            }
        }
        let needsCreate = glyphTexture == nil || glyphSize.x != atlas.width || glyphSize.y != atlas.height
        if needsCreate {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: max(1, atlas.width),
                height: max(1, atlas.height),
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            #if os(macOS)
            desc.storageMode = .managed
            #else
            desc.storageMode = .shared
            #endif
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            tex.label = "rune.atlas.glyphs"
            glyphTexture = tex
            glyphSize = SIMD2<Int>(atlas.width, atlas.height)
            glyphGeneration = 0
        }
        guard let tex = glyphTexture else { return nil }
        if glyphGeneration != generation && !atlas.texels.isEmpty {
            atlas.texels.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    tex.replace(
                        region: MTLRegionMake2D(0, 0, atlas.width, atlas.height),
                        mipmapLevel: 0,
                        withBytes: base,
                        bytesPerRow: atlas.width
                    )
                }
            }
            glyphGeneration = generation
        }
        return tex
    }

    public func syncImageAtlas(device: MTLDevice, atlas: RGBA8Atlas, revision: UInt64 = 1) -> MTLTexture? {
        let needsCreate = imageTexture == nil || imageSize.x != atlas.width || imageSize.y != atlas.height
        if needsCreate {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: max(1, atlas.width),
                height: max(1, atlas.height),
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            #if os(macOS)
            desc.storageMode = .managed
            #else
            desc.storageMode = .shared
            #endif
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            tex.label = "rune.atlas.images"
            imageTexture = tex
            imageSize = SIMD2<Int>(atlas.width, atlas.height)
            imageRevision = 0
        }
        guard let tex = imageTexture else { return nil }
        if imageRevision != revision && !atlas.texels.isEmpty {
            atlas.texels.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    tex.replace(
                        region: MTLRegionMake2D(0, 0, atlas.width, atlas.height),
                        mipmapLevel: 0,
                        withBytes: base,
                        bytesPerRow: atlas.width * 4
                    )
                }
            }
            imageRevision = revision
        }
        return tex
    }

    /// Shrinks oversized staging buffers back down (`#819` GPU give-back).
    public func trimUploads() {
        if let buf = instanceBuffer, buf.length > 512 * 1024 {
            instanceBuffer = nil
        }
    }
}
#endif
