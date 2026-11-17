import Foundation
#if os(Android)
import Android
#endif
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
        settleAt = nodes.reduce(0.0) { max($0, $1.settleAt()) }
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

private extension Array {
    mutating func swapRemove(_ index: Int) -> Element {
        let lastIndex = count - 1
        if index != lastIndex {
            swapAt(index, lastIndex)
        }
        return removeLast()
    }
}

/// A caller can hold an encoded command buffer without submitting it. Resources it references
/// may be reused on the same queue after commit, or on any queue after completion.
private final class MetalLayerSubmission: @unchecked Sendable {
    weak var command: MTLCommandBuffer?
    private let lock = NSLock()
    private var completed = false

    init(_ buffer: MTLCommandBuffer) {
        command = buffer
        buffer.addCompletedHandler { [weak self] finished in
            guard let self else { return }
            lock.lock()
            completed = finished.status == .completed
            lock.unlock()
        }
    }

    func canFollow(on queue: MTLCommandQueue?, command next: MTLCommandBuffer? = nil) -> Bool {
        if let command {
            if command === next { return true }
            switch command.status {
            case .completed: return true
            case .committed, .scheduled: return command.commandQueue === queue
            default: return false
            }
        }
        lock.lock()
        defer { lock.unlock() }
        return completed
    }
}

/// Manages bounded `rgba16Float` layer render targets, 64 MiB LRU layer caching, and `#819` GPU give-back on rest.
public final class LayersPool {
    public struct TargetEntry {
        public var slot: LayerTextureSlot
        public var contentSize: SIMD2<Float>
        public var cache: (UInt64, UInt64)?
        public var blurPasses: Int = 0
    }

    public private(set) var cacheBudgetBytes: Int = Int(DEFAULT_LAYER_CACHE_BUDGET)
    public private(set) var frameNumber: UInt64 = 0
    public private(set) var peakBytes: UInt64 = 0
    public var planner = LayerPlanner()

    public var spareCount: Int { spare.count }
    public var retainedCount: Int { retainedList.count }
    public var inUseCount: Int {
        managedByPlanner
            ? targetSlots.reduce(0) { $0 + ($1 != nil ? 1 : 0) } + inUse.count
            : inUse.count
    }

    private var targetSlots: [TargetEntry?] = []
    private var retainedList: [TargetEntry] = []
    private var spare: [LayerTextureSlot] = []
    private var inUse: [LayerTextureSlot] = []
    private var managedByPlanner: Bool = false
    private var extraInUseBytes: Int = 0
    private final class CacheOwner {}
    private let cacheOwner = CacheOwner()
    private weak var tracker: ResidentLayerTracker?
    private var hasRuntime = false
    private var resident: [UInt64: UInt64] = [:]
    weak var drawingQueue: MTLCommandQueue?
    private var previousSubmission: MetalLayerSubmission?
    private(set) var planRevision: UInt64 = 0
    private var planSlotHeld: [LayerHeld?] = []
    private var lastLayerCount: Int = 0
    private var beginInstanceToScopeIndex: [Int: Int] = [:]

    private var retainedHits: UInt64 = 0
    private var retainedMisses: UInt64 = 0
    private var evictions: UInt64 = 0
    private var allocations: UInt64 = 0
    private var lastFrameExtraPasses: Int = 0

    public init(cacheBudgetBytes: Int = Int(DEFAULT_LAYER_CACHE_BUDGET)) {
        self.cacheBudgetBytes = max(0, cacheBudgetBytes)
    }

    deinit {
        tracker?.release(cacheOwner)
    }

    public func registerTracker(_ next: ResidentLayerTracker?) {
        if tracker !== next || hasRuntime != (next != nil) {
            tracker?.release(cacheOwner)
            giveBack(all: true)
            tracker = next
            hasRuntime = next != nil
        }
        if next?.acquire(for: cacheOwner) == true {
            next?.publish(resident, from: cacheOwner)
            publishAvailability()
        }
    }

    func canUseTextures(in command: MTLCommandBuffer?) -> Bool {
        previousSubmission?.canFollow(on: command?.commandQueue ?? drawingQueue, command: command) != false
    }

    func recordUse(of command: MTLCommandBuffer) {
        guard previousSubmission?.command !== command else { return }
        previousSubmission = MetalLayerSubmission(command)
        publishAvailability()
    }

    func discardUnorderedSubmission() {
        giveBack(all: true)
        previousSubmission = nil
        publishAvailability()
    }

    private func publishAvailability() {
        if let previousSubmission, let queue = drawingQueue {
            tracker?.setAvailability({ previousSubmission.canFollow(on: queue) }, from: cacheOwner)
        } else {
            tracker?.setAvailability(nil, from: cacheOwner)
        }
    }

    /// A prebuilt frame can only omit children that this pool can still draw.
    func missingLayer(in frame: RenderFrame) -> UInt64? {
        frame.elidedLayers.first {
            frame.residentTracker == nil || tracker !== frame.residentTracker || resident[$0.node] != $0.signature
        }?.node
    }

    public func recordExtraPass(_ count: Int = 1) {
        lastFrameExtraPasses += max(0, count)
    }

    public func recordCacheMiss() {
        retainedMisses &+= 1
    }

    public func setCacheBudget(_ bytes: Int) {
        planRevision &+= 1
        cacheBudgetBytes = max(0, bytes)
        let targetCachedBytes = targetSlots.reduce(0) { $0 + (($1?.cache != nil) ? ($1?.slot.byteSize ?? 0) : 0) }
        let retainedBytes = retainedList.reduce(0) { $0 + $1.slot.byteSize }
        if targetCachedBytes + retainedBytes > cacheBudgetBytes {
            for sIdx in targetSlots.indices {
                if let entry = targetSlots[sIdx], entry.cache != nil {
                    retainedList.append(entry)
                    targetSlots[sIdx] = nil
                }
            }
        }
        evictRetainedToBudget()
    }

    private func currentHeldBytes() -> Int {
        let targetsTotal = targetSlots.reduce(0) { $0 + ($1?.slot.byteSize ?? 0) }
        let retainedTotal = retainedList.reduce(0) { $0 + $1.slot.byteSize }
        let spareTotal = spare.reduce(0) { $0 + $1.byteSize }
        let inUseTotal = inUse.reduce(0) { $0 + $1.byteSize }
        if managedByPlanner {
            return targetsTotal + retainedTotal + spareTotal + inUseTotal + extraInUseBytes
        }
        return inUseTotal + retainedTotal + extraInUseBytes
    }

    private func updatePeakBytes() {
        let total = UInt64(max(0, currentHeldBytes()))
        if total > peakBytes {
            peakBytes = total
        }
    }

    public func beginFrame() {
        frameNumber &+= 1
        lastFrameExtraPasses = 0
        releaseInUse()
        if managedByPlanner {
            peakBytes = 0
            updatePeakBytes()
        } else {
            let retainedTotal = retainedList.reduce(0) { $0 + $1.slot.byteSize }
            peakBytes = UInt64(max(0, retainedTotal))
        }
    }

    public func endFrame() {
        releaseInUse()
    }

    public func scopeIndex(forBeginInstance index: Int) -> Int? {
        beginInstanceToScopeIndex[index]
    }

    public func targetEntry(at scopeIndex: Int) -> TargetEntry? {
        guard scopeIndex >= 0 && scopeIndex < targetSlots.count else { return nil }
        return targetSlots[scopeIndex]
    }

    public func updateTargetTexture(at scopeIndex: Int, texture: MTLTexture) {
        guard scopeIndex >= 0 && scopeIndex < targetSlots.count, var entry = targetSlots[scopeIndex] else { return }
        entry.slot = LayerTextureSlot(texture: texture, lastUsedFrame: frameNumber)
        targetSlots[scopeIndex] = entry
        updatePeakBytes()
    }

    public func syncResidentCaches(into tracker: ResidentLayerTracker?) {
        guard self.tracker === tracker else { return }
        resident.removeAll(keepingCapacity: true)
        for entry in retainedList {
            if let (node, sig) = entry.cache {
                resident[node] = sig
            }
        }
        for entry in targetSlots {
            if let (node, sig) = entry?.cache {
                resident[node] = sig
            }
        }
        tracker?.publish(resident, from: cacheOwner)
    }

    func finishCachedLayer(at scopeIndex: Int, node: UInt64, signature: UInt64) {
        guard targetSlots.indices.contains(scopeIndex), targetSlots[scopeIndex] != nil else { return }
        targetSlots[scopeIndex]?.cache = (node, signature)
        resident[node] = signature
        tracker?.markResident(nodeId: node, signature: signature, from: cacheOwner)
    }

    private static func turnedBounds(_ r: SIMD4<Float>, angle: Float, pivot: SIMD2<Float>) -> SIMD4<Float> {
        let sn = sinf(angle)
        let c = cosf(angle)
        var out = SIMD4<Float>(.infinity, .infinity, -.infinity, -.infinity)
        let corners: [(Float, Float)] = [(r.x, r.y), (r.z, r.y), (r.x, r.w), (r.z, r.w)]
        for (x, y) in corners {
            let dx = x - pivot.x
            let dy = y - pivot.y
            let qx = pivot.x + c * dx - sn * dy
            let qy = pivot.y + sn * dx + c * dy
            out.x = min(out.x, qx)
            out.y = min(out.y, qy)
            out.z = max(out.z, qx)
            out.w = max(out.w, qy)
        }
        return out
    }

    private static func unionEdges(_ a: inout SIMD4<Float>, _ b: SIMD4<Float>) {
        if b.z <= b.x || b.w <= b.y { return }
        if a.z <= a.x || a.w <= a.y {
            a = b
            return
        }
        a.x = min(a.x, b.x)
        a.y = min(a.y, b.y)
        a.z = max(a.z, b.z)
        a.w = max(a.w, b.w)
    }

    public func preparePlan(instances: [RenderInstance], viewport: SIMD2<Float>, isolate: Bool = true) {
        prepareLayers(device: nil, instances: instances, viewport: viewport, isolate: isolate, tracker: nil)
    }

    public func prepareLayers(
        device: MTLDevice?,
        instances: [RenderInstance],
        viewport: SIMD2<Float>,
        isolate: Bool = true,
        tracker: ResidentLayerTracker? = nil
    ) {
        // Mirrors `Renderer::prepare_layers` + `commit` + `paint_layers` (`layers.rs:336-634`).
        managedByPlanner = true
        registerTracker(tracker)
        planRevision &+= 1
        releaseInUse()
        frameNumber &+= 1
        lastFrameExtraPasses = 0
        peakBytes = 0
        updatePeakBytes()

        for sIdx in targetSlots.indices {
            if let entry = targetSlots[sIdx], entry.cache != nil {
                retainedList.append(entry)
                targetSlots[sIdx] = nil
            }
        }

        beginInstanceToScopeIndex.removeAll(keepingCapacity: true)
        var scopes: [LayerPlanScope] = []
        var stack: [Int] = []
        for (idx, inst) in instances.enumerated() {
            let kind = Float(Int(inst.params.y.rounded()))
            if kind == KIND_LAYER {
                let parent = stack.last
                let parentCachedHit: Bool = parent.map { pIdx in
                    if let key = scopes[pIdx].cache {
                        return retainedList.contains { entry in
                            entry.cache?.0 == key.0 && entry.cache?.1 == key.1
                        }
                    }
                    return false
                } ?? false
                let opacity = min(max(inst.fill.w, 0.0), 1.0)
                let planned: LayerPlanPlanned
                if opacity <= 0.0 {
                    planned = .hidden
                } else if let pIdx = parent {
                    switch scopes[pIdx].planned {
                    case .hidden: planned = .hidden
                    case .covered: planned = .covered
                    case .inline: planned = parentCachedHit ? .covered : .inline
                    }
                } else {
                    planned = .inline
                }

                let parentFree = parent.map { scopes[$0].free } ?? false
                let rawLimit: SIMD4<Float> = parent.map { pIdx in
                    let p = scopes[pIdx]
                    let grow = ceilf(3.0 * p.blur)
                    return SIMD4<Float>(
                        max(p.clip.x, p.limit.x) - grow,
                        max(p.clip.y, p.limit.y) - grow,
                        min(p.clip.z, p.limit.z) + grow,
                        min(p.clip.w, p.limit.w) + grow
                    )
                } ?? NO_CLIP
                let rawSigma = min(max(inst.params.z, 0.0), LayerBlurConstants.maxSigma)
                let sigma: Float = rawSigma >= 0.05 ? rawSigma : 0.0
                let isCached = inst.params.w >= 0.5
                let cacheKey: (UInt64, UInt64)? = isCached
                    ? (unpackFloat4ToU64(inst.radii), unpackFloat4ToU64(inst.uv))
                    : nil
                let turn: (Float, SIMD2<Float>)? = inst.border.y != 0.0
                    ? (inst.border.y, SIMD2<Float>(inst.border.z, inst.border.w))
                    : nil
                let free = (turn != nil) || parentFree
                let frame: SIMD4<Float>
                if free {
                    let outer: SIMD4<Float>
                    if let pIdx = parent, parentFree {
                        outer = scopes[pIdx].frame
                    } else {
                        let support = parent.map { scopes[$0].support } ?? 0.0
                        outer = SIMD4<Float>(-support, -support, viewport.x + support, viewport.y + support)
                    }
                    let shown = SIMD4<Float>(
                        max(outer.x, inst.clip.x),
                        max(outer.y, inst.clip.y),
                        min(outer.z, inst.clip.z),
                        min(outer.w, inst.clip.w)
                    )
                    if let (angle, pivot) = turn, shown.z > shown.x, shown.w > shown.y {
                        frame = Self.turnedBounds(shown, angle: -angle, pivot: pivot)
                    } else {
                        frame = shown
                    }
                } else {
                    frame = .zero
                }
                let limit = parentFree ? NO_CLIP : rawLimit
                let parentSupport = parent.map { scopes[$0].support } ?? 0.0
                let additive = inst.params.x >= 0.5
                let scope = LayerPlanScope(
                    begin: UInt32(idx),
                    end: UInt32(idx + 1),
                    parent: parent,
                    edges: SIMD4<Float>(inst.rect.x, inst.rect.y, inst.rect.x + inst.rect.z, inst.rect.y + inst.rect.w),
                    vis: .zero,
                    clip: inst.clip,
                    limit: limit,
                    fade: inst.fade,
                    opacity: opacity,
                    blend: additive ? .plusLighter : .sourceOver,
                    blur: sigma,
                    support: parentSupport + ceilf(3.0 * sigma),
                    cache: cacheKey,
                    planned: planned,
                    turn: turn,
                    free: free,
                    frame: frame,
                    hole: isCached ? .zero : inst.radii
                )
                let sIdx = scopes.count
                beginInstanceToScopeIndex[idx] = sIdx
                scopes.append(scope)
                stack.append(sIdx)
            } else if kind == KIND_LAYER_END, let openIdx = stack.popLast() {
                scopes[openIdx].end = UInt32(idx)
                let grow = ceilf(3.0 * scopes[openIdx].blur)
                let e = scopes[openIdx].edges
                let vis: SIMD4<Float>
                if scopes[openIdx].free {
                    let fr = scopes[openIdx].frame
                    vis = SIMD4<Float>(
                        floorf(max(e.x - grow, fr.x - grow)),
                        floorf(max(e.y - grow, fr.y - grow)),
                        ceilf(min(e.z + grow, fr.z + grow)),
                        ceilf(min(e.w + grow, fr.w + grow))
                    )
                } else {
                    let l = scopes[openIdx]
                    vis = SIMD4<Float>(
                        floorf(max(max(e.x - grow, max(l.clip.x, l.limit.x) - grow), -l.support)),
                        floorf(max(max(e.y - grow, max(l.clip.y, l.limit.y) - grow), -l.support)),
                        ceilf(min(min(e.z + grow, min(l.clip.z, l.limit.z) + grow), viewport.x + l.support)),
                        ceilf(min(min(e.w + grow, min(l.clip.w, l.limit.w) + grow), viewport.y + l.support))
                    )
                }
                scopes[openIdx].vis = vis
                if scopes[openIdx].cache != nil {
                    if vis.z <= vis.x || vis.w <= vis.y {
                        scopes[openIdx].planned = .hidden
                    }
                    scopes[openIdx].edges = SIMD4<Float>(floorf(e.x), floorf(e.y), ceilf(e.z), ceilf(e.w))
                } else {
                    scopes[openIdx].edges = vis
                }
                let edges: SIMD4<Float>
                if let (angle, pivot) = scopes[openIdx].turn,
                   scopes[openIdx].edges.z > scopes[openIdx].edges.x,
                   scopes[openIdx].edges.w > scopes[openIdx].edges.y
                {
                    edges = Self.turnedBounds(scopes[openIdx].edges, angle: angle, pivot: pivot)
                } else {
                    edges = scopes[openIdx].edges
                }
                if let pIdx = scopes[openIdx].parent, scopes[pIdx].cache == nil {
                    Self.unionEdges(&scopes[pIdx].edges, edges)
                }
            } else if let at = stack.last, scopes[at].cache == nil {
                var rect = inst.rect
                if kind == KIND_GLYPH && inst.params.x != 0.0 {
                    let s = sinf(inst.params.x)
                    let c = cosf(inst.params.x)
                    let width = abs(c) * rect.z + abs(s) * rect.w
                    let height = abs(s) * rect.z + abs(c) * rect.w
                    rect = SIMD4<Float>(rect.x + (rect.z - width) * 0.5, rect.y + (rect.w - height) * 0.5, width, height)
                }
                let grow: Float
                if kind == KIND_GLYPH {
                    grow = 0.0
                } else if kind == KIND_SHADOW {
                    grow = inst.params.z * 3.0 + 1.0
                } else if kind == KIND_EFFECT {
                    grow = inst.params.z + 1.0
                } else if kind == KIND_RECT || kind == KIND_GRADIENT || kind == KIND_DASHED || kind == KIND_RADIAL {
                    grow = 1.0 + inst.params.z * 2.0
                } else {
                    grow = 1.0
                }
                Self.unionEdges(&scopes[at].edges, SIMD4<Float>(
                    max(rect.x - grow, inst.clip.x),
                    max(rect.y - grow, inst.clip.y),
                    min(rect.x + rect.z + grow, inst.clip.z),
                    min(rect.y + rect.w + grow, inst.clip.w)
                ))
            }
        }

        while targetSlots.count > scopes.count {
            if let entry = targetSlots.popLast() ?? nil {
                var parked = entry.slot
                parked.lastUsedFrame = entry.slot.lastUsedFrame
                spare.append(parked)
                trimSpare(budget: LayerPoolLimits.spareBudgetBytes)
            }
        }
        while targetSlots.count < scopes.count {
            targetSlots.append(nil)
        }

        if scopes.isEmpty {
            trimRetained(activeBytes: 0)
            if lastLayerCount > 0 {
                planner.settle(len: 0, retained: retainedList.count, spare: spare.count)
            }
            planSlotHeld.removeAll(keepingCapacity: true)
            lastLayerCount = 0
            updatePeakBytes()
            syncResidentCaches(into: tracker)
            return
        }

        if device != nil {
            let slotHeld: [LayerHeld?] = targetSlots.map { entry in
                guard let entry else { return nil }
                return LayerHeld(
                    size: SIMD2<UInt32>(UInt32(entry.slot.width), UInt32(entry.slot.height)),
                    bytes: UInt64(entry.slot.byteSize),
                    cache: entry.cache,
                    lastUsed: entry.slot.lastUsedFrame
                )
            }
            let retainedHeld: [LayerHeld] = retainedList.map { entry in
                LayerHeld(
                    size: SIMD2<UInt32>(UInt32(entry.slot.width), UInt32(entry.slot.height)),
                    bytes: UInt64(entry.slot.byteSize),
                    cache: entry.cache,
                    lastUsed: entry.slot.lastUsedFrame
                )
            }
            let spareHeld: [LayerHeld] = spare.map { slot in
                LayerHeld(
                    size: SIMD2<UInt32>(UInt32(slot.width), UInt32(slot.height)),
                    bytes: UInt64(slot.byteSize),
                    cache: nil,
                    lastUsed: slot.lastUsedFrame
                )
            }
            let snap = LayerPoolSnapshot(slots: slotHeld, retained: retainedHeld, spare: spareHeld)
            planner.decide(
                plan: scopes,
                pools: snap,
                budget: UInt64(cacheBudgetBytes),
                isolate: isolate,
                maxDim: UInt32(LayerPoolLimits.maxDimension)
            )
            for move in planner.moves {
                switch move {
                case .park(let slot):
                    if slot < targetSlots.count, var entry = targetSlots[slot] {
                        targetSlots[slot] = nil
                        entry.cache = nil
                        spare.append(entry.slot)
                    }
                case .set(let slot, let from):
                    if slot < targetSlots.count {
                        switch from {
                        case .retained(let at):
                            if at < retainedList.count {
                                targetSlots[slot] = retainedList.swapRemove(at)
                            }
                        case .spare(let at):
                            if at < spare.count {
                                let reused = spare.swapRemove(at)
                                targetSlots[slot] = TargetEntry(
                                    slot: reused,
                                    contentSize: SIMD2<Float>(Float(reused.width), Float(reused.height)),
                                    cache: nil
                                )
                            }
                        }
                    }
                case .create(let slot, let size):
                    if slot < targetSlots.count, let dev = device {
                        let w = min(max(Int(size.x), 1), LayerPoolLimits.maxDimension)
                        let h = min(max(Int(size.y), 1), LayerPoolLimits.maxDimension)
                        let desc = MTLTextureDescriptor.texture2DDescriptor(
                            pixelFormat: .rgba16Float,
                            width: w,
                            height: h,
                            mipmapped: false
                        )
                        desc.usage = [.renderTarget, .shaderRead]
                        desc.storageMode = .private
                        if let tex = dev.makeTexture(descriptor: desc) {
                            tex.label = "rune.layer.target"
                            allocations &+= 1
                            targetSlots[slot] = TargetEntry(
                                slot: LayerTextureSlot(texture: tex, lastUsedFrame: frameNumber),
                                contentSize: SIMD2<Float>(Float(w), Float(h)),
                                cache: nil
                            )
                        }
                    }
                case .unblur(let slot):
                    if slot < targetSlots.count {
                        targetSlots[slot]?.blurPasses = 0
                    }
                case .drop(let kept):
                    switch kept {
                    case .retained(let at):
                        if at < retainedList.count {
                            let dropped = retainedList.swapRemove(at)
                            evictions &+= 1
                            if let (nid, _) = dropped.cache {
                                notifyEvicted(nid)
                            }
                        }
                    case .spare(let at):
                        if at < spare.count {
                            _ = spare.swapRemove(at)
                        }
                    }
                }
                updatePeakBytes()
            }
            for (i, disp) in planner.dispositions.enumerated() where i < targetSlots.count {
                switch disp {
                case .cached(_, let cache):
                    targetSlots[i]?.cache = cache
                    if cache != nil {
                        targetSlots[i]?.slot.lastUsedFrame = frameNumber
                        retainedHits &+= 1
                    }
                case .render(let rect, let cache):
                    // Preparation can reserve a texture without encoding any of its children.
                    targetSlots[i]?.cache = nil
                    targetSlots[i]?.slot.lastUsedFrame = frameNumber
                    targetSlots[i]?.contentSize = SIMD2<Float>(rect.z, rect.w)
                    if cache != nil {
                        retainedMisses &+= 1
                    }
                case .inline, .skip:
                    break
                }
                updatePeakBytes()
            }
        } else {
            for sIdx in planSlotHeld.indices where planSlotHeld[sIdx]?.cache != nil {
                planSlotHeld[sIdx] = nil
            }
            while planSlotHeld.count > scopes.count { planSlotHeld.removeLast() }
            while planSlotHeld.count < scopes.count { planSlotHeld.append(nil) }
            let retainedHeld = retainedList.map {
                LayerHeld(
                    size: SIMD2<UInt32>(UInt32($0.slot.width), UInt32($0.slot.height)),
                    bytes: UInt64($0.slot.byteSize),
                    cache: $0.cache,
                    lastUsed: $0.slot.lastUsedFrame
                )
            }
            let spareHeld = spare.map {
                LayerHeld(
                    size: SIMD2<UInt32>(UInt32($0.width), UInt32($0.height)),
                    bytes: UInt64($0.byteSize),
                    cache: nil,
                    lastUsed: $0.lastUsedFrame
                )
            }
            planner.decide(
                plan: scopes,
                pools: LayerPoolSnapshot(slots: planSlotHeld, retained: retainedHeld, spare: spareHeld),
                budget: UInt64(cacheBudgetBytes),
                isolate: isolate,
                maxDim: UInt32(LayerPoolLimits.maxDimension)
            )
            for (i, disp) in planner.dispositions.enumerated() {
                switch disp {
                case .render(let r, let c), .cached(let r, let c):
                    planSlotHeld[i] = LayerHeld(size: LayerPlannerConstants.bucketOf(r).bucket, cache: c, lastUsed: frameNumber)
                case .inline, .skip:
                    planSlotHeld[i] = nil
                }
            }
        }

        if scopes.count < lastLayerCount {
            planner.settle(len: scopes.count, retained: retainedList.count, spare: spare.count)
        }
        lastLayerCount = scopes.count
        updatePeakBytes()
        syncResidentCaches(into: tracker)
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
        label: String = "rune.layer.target",
        bucketed: Bool = true
    ) -> MTLTexture? {
        let rawW = min(max(width, 1), LayerPoolLimits.maxDimension)
        let rawH = min(max(height, 1), LayerPoolLimits.maxDimension)
        let w = bucketed ? min(((rawW + 63) / 64) * 64, LayerPoolLimits.maxDimension) : rawW
        let h = bucketed ? min(((rawH + 63) / 64) * 64, LayerPoolLimits.maxDimension) : rawH
        let spareMatch: (LayerTextureSlot) -> Bool
        if bucketed {
            let maxArea = 2 * max(rawW, 64) * max(rawH, 64)
            spareMatch = { slot in
                slot.texture.pixelFormat == format &&
                slot.width >= rawW && slot.height >= rawH &&
                slot.width * slot.height <= maxArea
            }
        } else {
            spareMatch = { slot in
                slot.width == w && slot.height == h && slot.texture.pixelFormat == format
            }
        }
        if let idx = spare.firstIndex(where: spareMatch) {
            var slot = spare.remove(at: idx)
            slot.lastUsedFrame = frameNumber
            inUse.append(slot)
            updatePeakBytes()
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
        updatePeakBytes()
        return tex
    }

    /// Acquires a standalone `rgba16Float` render target for retained layer caching (caller owns until stored).
    public func acquireRetainedTarget(
        device: MTLDevice,
        width: Int,
        height: Int,
        format: MTLPixelFormat = .rgba16Float,
        bucketed: Bool = true
    ) -> MTLTexture? {
        let rawW = min(max(width, 1), LayerPoolLimits.maxDimension)
        let rawH = min(max(height, 1), LayerPoolLimits.maxDimension)
        let w = bucketed ? min(((rawW + 63) / 64) * 64, LayerPoolLimits.maxDimension) : rawW
        let h = bucketed ? min(((rawH + 63) / 64) * 64, LayerPoolLimits.maxDimension) : rawH
        let spareMatch: (LayerTextureSlot) -> Bool
        if bucketed {
            let maxArea = 2 * max(rawW, 64) * max(rawH, 64)
            spareMatch = { slot in
                slot.texture.pixelFormat == format &&
                slot.width >= rawW && slot.height >= rawH &&
                slot.width * slot.height <= maxArea
            }
        } else {
            spareMatch = { slot in
                slot.width == w && slot.height == h && slot.texture.pixelFormat == format
            }
        }
        if let idx = spare.firstIndex(where: spareMatch) {
            let slot = spare.remove(at: idx)
            extraInUseBytes += slot.byteSize
            updatePeakBytes()
            extraInUseBytes -= slot.byteSize
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
        tex.label = "rune.layer.retained"
        allocations &+= 1
        extraInUseBytes += w * h * 8
        updatePeakBytes()
        extraInUseBytes -= w * h * 8
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
        guard let idx = retainedList.firstIndex(where: { $0.cache?.0 == key }) else {
            retainedMisses &+= 1
            return nil
        }
        let w = min(max(width, 1), LayerPoolLimits.maxDimension)
        let h = min(max(height, 1), LayerPoolLimits.maxDimension)
        if let sig = signature, retainedList[idx].cache?.1 != sig {
            retainedMisses &+= 1
            return nil
        }
        guard retainedList[idx].slot.width >= w && retainedList[idx].slot.height >= h else {
            retainedMisses &+= 1
            return nil
        }
        retainedList[idx].slot.lastUsedFrame = frameNumber
        retainedHits &+= 1
        return retainedList[idx].slot.texture
    }

    public func claimRetained(key: UInt64, signature: UInt64) -> (texture: MTLTexture, contentSize: SIMD2<Float>)? {
        if let idx = targetSlots.firstIndex(where: { $0?.cache?.0 == key && $0?.cache?.1 == signature }),
           var entry = targetSlots[idx] {
            entry.slot.lastUsedFrame = frameNumber
            targetSlots[idx] = entry
            retainedHits &+= 1
            return (entry.slot.texture, entry.contentSize)
        }
        guard let idx = retainedList.firstIndex(where: { $0.cache?.0 == key && $0.cache?.1 == signature }) else {
            retainedMisses &+= 1
            return nil
        }
        retainedList[idx].slot.lastUsedFrame = frameNumber
        retainedHits &+= 1
        return (retainedList[idx].slot.texture, retainedList[idx].contentSize)
    }

    public func storeRetained(
        key: UInt64,
        signature: UInt64 = 0,
        texture: MTLTexture,
        contentWidth: Int? = nil,
        contentHeight: Int? = nil
    ) {
        let slot = LayerTextureSlot(texture: texture, lastUsedFrame: frameNumber)
        if slot.byteSize > cacheBudgetBytes {
            spare.append(slot)
            trimSpare(budget: LayerPoolLimits.spareBudgetBytes)
            notifyEvicted(key)
            return
        }
        if let prevIdx = retainedList.firstIndex(where: { $0.cache?.0 == key }) {
            let previous = retainedList.swapRemove(prevIdx)
            spare.append(previous.slot)
        }
        let cw = Float(contentWidth ?? texture.width)
        let ch = Float(contentHeight ?? texture.height)
        retainedList.append(
            TargetEntry(
                slot: slot,
                contentSize: SIMD2<Float>(cw, ch),
                cache: (key, signature)
            )
        )
        evictRetainedToBudget()
        syncResidentCaches(into: tracker)
    }

    /// Gives back temporary or cached GPU memory (`#819` GPU give-back on window rest / hide).
    ///
    /// - `all == false` (idle rest): trims spare buffers down to 8 MiB and drops retained caches if `!residentCaches`.
    /// - `all == true` (window occluded/hidden): releases all spare and retained textures immediately.
    public func giveBack(all: Bool = false, residentCaches: Bool = false) {
        planRevision &+= 1
        releaseInUse()
        if all {
            spare.removeAll()
            retainedList.removeAll()
            targetSlots.removeAll()
            notifyCleared()
            return
        }
        if !residentCaches {
            for index in targetSlots.indices {
                if let entry = targetSlots[index], entry.cache != nil {
                    spare.append(entry.slot)
                    targetSlots[index] = nil
                }
            }
            retainedList.removeAll()
            notifyCleared()
        }
        trimSpare(budget: LayerPoolLimits.restingSpareBudgetBytes)
    }

    public func stats() -> LayerStats {
        if managedByPlanner {
            let activeCount = targetSlots.reduce(0) { $0 + ($1 != nil ? 1 : 0) }
            let activeBytes = targetSlots.reduce(0) { $0 + ($1?.slot.byteSize ?? 0) }
            let retainedBytes = retainedList.reduce(0) { $0 + $1.slot.byteSize }
            let inUseBytes = inUse.reduce(0) { $0 + $1.byteSize }
            let liveCachedCount = targetSlots.reduce(0) { $0 + (($1?.cache != nil) ? 1 : 0) }
            let liveCachedBytes = targetSlots.reduce(0) { $0 + (($1?.cache != nil) ? ($1?.slot.byteSize ?? 0) : 0) }
            return LayerStats(
                targets: activeCount + retainedList.count + inUse.count,
                bytes: UInt64(max(0, activeBytes + retainedBytes + inUseBytes)),
                extraPasses: lastFrameExtraPasses,
                allocations: allocations,
                cachedLayers: liveCachedCount + retainedList.count,
                cachedBytes: UInt64(max(0, liveCachedBytes + retainedBytes)),
                hits: retainedHits,
                misses: retainedMisses,
                evictions: evictions
            )
        }
        let cached = retainedList.reduce(0) { $0 + $1.slot.byteSize }
        let spareBytes = spare.reduce(0) { $0 + $1.byteSize }
        let live = inUse.reduce(0) { $0 + $1.byteSize } + spareBytes
        return LayerStats(
            targets: inUse.count + spare.count + retainedList.count,
            bytes: UInt64(max(0, live + cached)),
            extraPasses: lastFrameExtraPasses,
            allocations: allocations,
            cachedLayers: retainedList.count,
            cachedBytes: UInt64(max(0, cached)),
            hits: retainedHits,
            misses: retainedMisses,
            evictions: evictions
        )
    }

    private func trimRetained(activeBytes: Int) {
        let available = max(0, cacheBudgetBytes - max(0, activeBytes))
        var total = retainedList.reduce(0) { $0 + $1.slot.byteSize }
        while total > available, !retainedList.isEmpty {
            let oldestIdx = retainedList.indices.min {
                retainedList[$0].slot.lastUsedFrame < retainedList[$1].slot.lastUsedFrame
            }!
            let removed = retainedList.swapRemove(oldestIdx)
            total -= removed.slot.byteSize
            spare.append(removed.slot)
            evictions &+= 1
            if let (nid, _) = removed.cache {
                notifyEvicted(nid)
            }
        }
        trimSpare(budget: LayerPoolLimits.spareBudgetBytes)
    }

    private func evictRetainedToBudget() {
        trimRetained(activeBytes: 0)
    }

    private func notifyEvicted(_ key: UInt64) {
        resident.removeValue(forKey: key)
        tracker?.evict(nodeId: key, from: cacheOwner)
    }

    private func notifyCleared() {
        resident.removeAll(keepingCapacity: true)
        tracker?.publish([:], from: cacheOwner)
    }

    private func trimSpare(budget: Int) {
        var total = spare.reduce(0) { $0 + $1.byteSize }
        while total > budget && !spare.isEmpty {
            let oldestIdx = spare.indices.min {
                spare[$0].lastUsedFrame < spare[$1].lastUsedFrame
            }!
            let victim = spare.swapRemove(oldestIdx)
            total -= victim.byteSize
        }
    }
}

// MARK: - Shader Library Loader & Precompiled Metallib Lookup

/// Loads precompiled `.metallib` libraries when bundled, otherwise compiles and caches MSL source per `MTLDevice`.
public enum ShaderLibraryCache {
    struct Load: Hashable {
        let bundleURL: URL
        let name: String
        let usedPrecompiled: Bool
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var libs: [Key: MTLLibrary] = [:]
        var observedLoads: Set<Load>?
    }

    private struct Key: Hashable {
        let deviceId: UInt
        let name: String
    }

    private static let sharedCache = Box()
    @TaskLocal private static var testCache: Box?

    /// Exercises the regular loader against a fresh cache and reports the libraries resolved in this scope.
    static func loadsForTesting(_ body: () throws -> Void) rethrows -> Set<Load> {
        let cache = Box()
        cache.observedLoads = []
        try $testCache.withValue(cache, operation: body)
        return cache.lock.withLock { cache.observedLoads ?? [] }
    }

    public static func load(
        named name: String,
        source: String,
        requiredFunction: String,
        bundle: Bundle? = nil,
        on device: MTLDevice
    ) throws -> MTLLibrary {
        let box = testCache ?? sharedCache
        let key = Key(deviceId: UInt(bitPattern: ObjectIdentifier(device)), name: name)
        box.lock.lock()
        if let cached = box.libs[key] {
            box.lock.unlock()
            return cached
        }
        box.lock.unlock()

        let resolved = try PrecompiledMetallib.loadLibraryWithOrigin(
            named: name,
            source: source,
            requiredFunction: requiredFunction,
            bundle: bundle,
            on: device
        )

        box.lock.lock()
        box.libs[key] = resolved.library
        box.observedLoads?.insert(Load(bundleURL: (bundle ?? .module).bundleURL, name: name, usedPrecompiled: resolved.usedPrecompiled))
        box.lock.unlock()
        return resolved.library
    }

    public static func invalidateForTesting(device: MTLDevice? = nil, named: String? = nil) {
        let box = testCache ?? sharedCache
        box.lock.lock()
        defer { box.lock.unlock() }
        if let device, let named {
            box.libs.removeValue(forKey: Key(deviceId: UInt(bitPattern: ObjectIdentifier(device)), name: named))
        } else if let device {
            let id = UInt(bitPattern: ObjectIdentifier(device))
            box.libs = box.libs.filter { $0.key.deviceId != id }
        } else {
            box.libs.removeAll()
        }
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
    private let pixelFormat: MTLPixelFormat

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .rgba16Float) throws {
        self.pixelFormat = pixelFormat
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

        let canWriteSource = source.usage.contains(.renderTarget) && source.pixelFormat == pixelFormat
        var reducedTex: MTLTexture?
        var hInput: MTLTexture = source
        if isReduced {
            guard let reduced = pool.acquireTarget(device: device, width: rw, height: rh, format: source.pixelFormat, label: "rune.lblur.prefilter", bucketed: false) else {
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
            reducedTex = reduced
            hInput = reduced
        }

        guard let ping = pool.acquireTarget(device: device, width: rw, height: rh, format: source.pixelFormat, label: "rune.lblur.ping", bucketed: false) else {
            if let r = reducedTex { pool.recycleTarget(r) }
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
        let pong: MTLTexture
        if let reduced = reducedTex {
            pong = reduced
        } else if canWriteSource {
            pong = source
        } else {
            guard let allocPong = pool.acquireTarget(device: device, width: rw, height: rh, format: source.pixelFormat, label: "rune.lblur.pong", bucketed: false) else {
                pool.recycleTarget(ping)
                return nil
            }
            pong = allocPong
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
        pool.recycleTarget(ping)

        if !isReduced {
            return pong
        }
        let finalTex: MTLTexture
        if canWriteSource {
            finalTex = source
        } else {
            guard let allocFinal = pool.acquireTarget(device: device, width: w, height: h, format: source.pixelFormat, label: "rune.lblur.final", bucketed: false) else {
                pool.recycleTarget(pong)
                return nil
            }
            finalTex = allocFinal
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
        pool.recycleTarget(pong)
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
        encode(device: device, commandBuffer: commandBuffer, source: source, target: target,
               targetFormat: targetFormat, instanceIndex: instanceIndex, instance: instance,
               instanceBuffer: instanceBuffer, viewport: viewport, originOffset: originOffset) {
            $0.setVertexBuffer(globalsBuffer, offset: 0, index: 1)
        }
    }

    func encode(
        device: MTLDevice,
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        target: MTLTexture,
        targetFormat: MTLPixelFormat,
        instanceIndex: Int,
        instance: RenderInstance,
        instanceBuffer: MTLBuffer,
        viewport: SIMD2<Float>,
        originOffset: SIMD2<Float>,
        bindGlobals: (MTLRenderCommandEncoder) -> Void
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
        // Linear filtering at a fractional clamp edge also reads the adjacent texel.
        // Refresh its footprint before sampling the snapshot retained from the last frame.
        let copyX0 = max(0, min(source.width - 1, Int(floorf(rx0 - 0.5))))
        let copyY0 = max(0, min(source.height - 1, Int(floorf(ry0 - 0.5))))
        let copyX1 = max(copyX0 + 1, min(source.width, Int(ceilf(rx1 + 0.5))))
        let copyY1 = max(copyY0 + 1, min(source.height, Int(ceilf(ry1 + 0.5))))
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
            bindGlobals(enc)
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
public enum RenderBatchBind: Equatable, Sendable {
    case image(Int)
    case glyph(Int)
}

public final class AtlasUploader {
    public private(set) var glyphTexture: MTLTexture?
    public private(set) var glyphGeneration: UInt64 = 0
    public private(set) var glyphSize: SIMD2<Int> = .zero

    public private(set) var imageTexture: MTLTexture?
    public private(set) var imageTextures: [MTLTexture] = []
    public private(set) var imageRevision: UInt64 = 0
    public private(set) var imageSize: SIMD2<Int> = .zero
    private(set) var lastImageUploadRegion: MTLRegion?
    private var holdsRuntimeImage = false
    private weak var atlasRuntime: ResidentLayerTracker?
    private var hasAtlasRuntime = false
    private struct AtlasReader {
        weak var command: MTLCommandBuffer?

        var pending: Bool {
            guard let command else { return false }
            return command.status != .completed && command.status != .error
        }

        static func record(_ command: MTLCommandBuffer, in readers: inout [Self]) {
            readers.removeAll { !$0.pending }
            if !readers.contains(where: { $0.command === command }) {
                readers.append(Self(command: command))
            }
        }
    }
    private var glyphReaders: [AtlasReader] = []
    private var imageReaders: [AtlasReader] = []
    private var imagePageSizes: [SIMD2<Int>] = []
    private var imagePageRevisions: [UInt64] = []

    /// Each runtime counts revisions locally. A new runtime may supply different pixels
    /// at the same revision while outstanding commands still use the previous textures.
    func selectRuntime(_ next: ResidentLayerTracker?) {
        guard atlasRuntime !== next || hasAtlasRuntime != (next != nil) else { return }
        atlasRuntime = next
        hasAtlasRuntime = next != nil
        glyphTexture = nil
        imageTexture = nil
        imageTextures.removeAll()
        imagePageSizes.removeAll()
        imagePageRevisions.removeAll()
        glyphReaders.removeAll()
        imageReaders.removeAll()
        lastImageUploadRegion = nil
        holdsRuntimeImage = false
    }

    public private(set) var imageBatches: [(Range<Int>, RenderBatchBind)] = []
    public private(set) var effects: [(Int, RenderInstance)] = []
    public private(set) var batchRuns: UInt64 = 0
    private var lastBatchCount: Int = -1
    private var lastBatchKinds: [UInt32] = []
    private var lastBatchPages: [Float] = []

    private struct InstanceUpload {
        let buffer: MTLBuffer
        var instances: [RenderInstance]
        weak var reader: MTLCommandBuffer?

        var inUse: Bool {
            guard let reader else { return false }
            return reader.status != .completed && reader.status != .error
        }

        func contains(_ other: [RenderInstance]) -> Bool {
            instances.count == other.count && instances.withUnsafeBufferPointer { prior in
                other.withUnsafeBufferPointer { $0.baseAddress == prior.baseAddress }
            }
        }
    }

    private var instanceUploads: [InstanceUpload] = []

    public init() {}

    public func ensureGlobalsBuffer(device: MTLDevice, globals: RenderGlobals) -> MTLBuffer? {
        var g = globals
        let buffer = device.makeBuffer(bytes: &g, length: MemoryLayout<RenderGlobals>.stride, options: .storageModeShared)
        buffer?.label = "rune.render.globals"
        return buffer
    }

    /// Prepares an upload. Supply the reading command buffer when encoding it into a draw.
    public func ensureInstanceBuffer(device: MTLDevice, instances: [RenderInstance]) -> MTLBuffer? {
        ensureInstanceBuffer(device: device, instances: instances, readBy: nil)
    }

    /// Preserve the bytes read by previously encoded ranges, including commands that
    /// callers have not submitted yet. Ranges from the same frame share one upload.
    public func ensureInstanceBuffer(
        device: MTLDevice, instances: [RenderInstance], readBy command: MTLCommandBuffer?
    ) -> MTLBuffer? {
        let available: (InstanceUpload) -> Bool = { $0.buffer.device === device && !$0.inUse }
        if let index = instanceUploads.firstIndex(where: {
            $0.buffer.device === device && ($0.reader === command || !$0.inUse) && $0.contains(instances)
        }) {
            instanceUploads[index].reader = command
            return instanceUploads[index].buffer
        }

        let needed = max(1, instances.count) * MemoryLayout<RenderInstance>.stride
        let reusable = instanceUploads.firstIndex { available($0) && $0.buffer.length >= needed }
        let index = reusable ?? instanceUploads.firstIndex(where: available)
        let buffer: MTLBuffer
        if let reusable {
            buffer = instanceUploads[reusable].buffer
        } else {
            let capacity = max(needed, index.map { instanceUploads[$0].buffer.length * 2 } ?? 0)
            guard let created = device.makeBuffer(length: capacity, options: .storageModeShared) else { return nil }
            created.label = "rune.render.instances"
            buffer = created
        }
        instances.withUnsafeBytes { raw in
            if let base = raw.baseAddress, !raw.isEmpty {
                memcpy(buffer.contents(), base, raw.count)
            }
        }
        let upload = InstanceUpload(buffer: buffer, instances: instances, reader: command)
        if let index {
            instanceUploads[index] = upload
        } else {
            instanceUploads.append(upload)
        }
        return buffer
    }

    /// Keeps the previous glyph mask available to commands already encoded against it.
    public func syncGlyphAtlas(device: MTLDevice, atlas: R8Atlas, generation: UInt64) -> MTLTexture? {
        guard MetalTextureLimits.contains(width: atlas.width, height: atlas.height, on: device) else { return nil }
        let pixels: [UInt8] = atlas.texels.isEmpty && atlas.width == 1 && atlas.height == 1 ? [0] : atlas.texels
        guard pixels.count == atlas.width * atlas.height else { return nil }
        let needsCreate = glyphTexture?.device.registryID != device.registryID || glyphSize != SIMD2(atlas.width, atlas.height)
            || (glyphGeneration != generation && glyphReaders.contains(where: \.pending))
        if needsCreate {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: atlas.width,
                height: atlas.height,
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
            glyphReaders.removeAll(keepingCapacity: true)
        }
        guard let tex = glyphTexture else { return nil }
        if needsCreate || glyphGeneration != generation {
            pixels.withUnsafeBytes { raw in
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
        syncImageAtlas(device: device, atlas: atlas, revision: revision, patch: nil)
    }

    /// A CPU texture replacement must preserve texels already referenced by an unfinished GPU command.
    func atlasesRead(by command: MTLCommandBuffer) {
        AtlasReader.record(command, in: &glyphReaders)
        AtlasReader.record(command, in: &imageReaders)
    }

    private func syncImageAtlas(device: MTLDevice, atlas: RGBA8Atlas, revision: UInt64, patch: ImageAtlasPatch?) -> MTLTexture? {
        guard Self.validImageAtlas(atlas, on: device) else { return nil }
        let isRuntimeImage = patch != nil
        let changed = revision != imageRevision || isRuntimeImage != holdsRuntimeImage
        let needsCreate = imageTexture?.device.registryID != device.registryID || imageSize != SIMD2(atlas.width, atlas.height)
            || (changed && imageReaders.contains(where: \.pending))
        if needsCreate {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm_srgb,
                width: atlas.width,
                height: atlas.height,
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
        }
        guard let tex = imageTexture else { return nil }
        if (needsCreate || changed) && !atlas.texels.isEmpty {
            let region: MTLRegion
            if !needsCreate, holdsRuntimeImage, let patch, patch.fromRevision == imageRevision {
                let e = patch.edges
                region = MTLRegionMake2D(e.x, e.y, e.z - e.x, e.w - e.y)
            } else {
                region = MTLRegionMake2D(0, 0, atlas.width, atlas.height)
            }
            atlas.texels.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    tex.replace(
                        region: region,
                        mipmapLevel: 0,
                        withBytes: base.advanced(by: (region.origin.y * atlas.width + region.origin.x) * 4),
                        bytesPerRow: atlas.width * 4
                    )
                }
            }
            imageRevision = revision
            holdsRuntimeImage = isRuntimeImage
            lastImageUploadRegion = region
        }
        return tex
    }

    public func syncImagePages(
        device: MTLDevice,
        pages: [RGBA8Atlas],
        fallback: RGBA8Atlas,
        revision: UInt64 = 1
    ) -> [MTLTexture] {
        syncImagePages(device: device, pages: pages, fallback: fallback, revision: revision, patch: nil)
    }

    private static func validImageAtlas(_ atlas: RGBA8Atlas, on device: MTLDevice) -> Bool {
        MetalTextureLimits.contains(width: atlas.width, height: atlas.height, on: device)
            && atlas.texels.count == atlas.width * atlas.height * 4
    }

    func syncImagePages(
        device: MTLDevice, pages: [RGBA8Atlas], fallback: RGBA8Atlas, revision: UInt64, patch: ImageAtlasPatch?
    ) -> [MTLTexture] {
        guard !pages.isEmpty else {
            if let tex = syncImageAtlas(device: device, atlas: fallback, revision: revision, patch: patch) {
                imageTextures = [tex]
                return [tex]
            }
            return []
        }
        // Reject a malformed set as a unit, before replacing a previously published page.
        guard pages.allSatisfy({ Self.validImageAtlas($0, on: device) }) else { return [] }
        let pagesInUse = imageReaders.contains(where: \.pending)
        var out: [MTLTexture] = []
        out.reserveCapacity(pages.count)
        if imagePageSizes.count != pages.count {
            imagePageSizes = Array(repeating: .zero, count: pages.count)
            imagePageRevisions = Array(repeating: 0, count: pages.count)
        }
        var rebuiltTextures = imageTextures
        if rebuiltTextures.count > pages.count {
            rebuiltTextures.removeSubrange(pages.count..<rebuiltTextures.count)
        }
        for (idx, page) in pages.enumerated() {
            if idx == 0 {
                if let tex = syncImageAtlas(device: device, atlas: page, revision: revision) {
                    if rebuiltTextures.isEmpty {
                        rebuiltTextures.append(tex)
                    } else {
                        rebuiltTextures[0] = tex
                    }
                    imagePageSizes[0] = SIMD2<Int>(page.width, page.height)
                    imagePageRevisions[0] = revision
                    out.append(tex)
                }
                continue
            }
            let existing: MTLTexture? = idx < rebuiltTextures.count ? rebuiltTextures[idx] : nil
            let needsCreate = existing?.device.registryID != device.registryID
                || imagePageSizes[idx] != SIMD2(page.width, page.height)
                || (pagesInUse && imagePageRevisions[idx] != revision)
            let tex: MTLTexture?
            if needsCreate {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba8Unorm_srgb,
                    width: page.width,
                    height: page.height,
                    mipmapped: false
                )
                desc.usage = [.shaderRead]
                #if os(macOS)
                desc.storageMode = .managed
                #else
                desc.storageMode = .shared
                #endif
                let created = device.makeTexture(descriptor: desc)
                created?.label = "rune.atlas.images.\(idx)"
                tex = created
                if let created {
                    if idx < rebuiltTextures.count {
                        rebuiltTextures[idx] = created
                    } else {
                        rebuiltTextures.append(created)
                    }
                }
                imagePageSizes[idx] = SIMD2<Int>(page.width, page.height)
                imagePageRevisions[idx] = 0
            } else {
                tex = existing
            }
            if let tex {
                if (needsCreate || imagePageRevisions[idx] != revision) && !page.texels.isEmpty {
                    page.texels.withUnsafeBytes { raw in
                        if let base = raw.baseAddress {
                            tex.replace(
                                region: MTLRegionMake2D(0, 0, page.width, page.height),
                                mipmapLevel: 0,
                                withBytes: base,
                                bytesPerRow: page.width * 4
                            )
                        }
                    }
                    imagePageRevisions[idx] = revision
                }
                out.append(tex)
            }
        }
        imageTextures = out
        return out
    }

    /// Shrinks oversized staging buffers back down (`#819` GPU give-back).
    public func trimUploads() {
        var keptBytes = 0
        instanceUploads.removeAll { upload in
            guard !upload.inUse else { return false }
            if upload.buffer.length > 512 * 1024 - keptBytes { return true }
            keptBytes += upload.buffer.length
            return false
        }
    }

    public func forgetInstances() {
        instanceUploads.removeAll { !$0.inUse }
        lastBatchCount = -1
        lastBatchKinds.removeAll(keepingCapacity: true)
        lastBatchPages.removeAll(keepingCapacity: true)
    }

    /// Computes minimal page-binding batch ranges matching `render::upload::Renderer::batch_instances`.
    /// Plain rects/shadows/gradients inherit the active batch; only `KIND_IMAGE` (`params.x`) and
    /// `KIND_GLYPH` (`params.z`) start a new batch when the bound page changes.
    public func prepareBatches(
        instances: [RenderInstance],
        glyphPageCount: Int = 1,
        imagePageCount: Int = 1
    ) {
        let count = instances.count
        var kinds: [UInt32] = []
        var pages: [Float] = []
        kinds.reserveCapacity(count)
        pages.reserveCapacity(count)
        var paramsChanged = (lastBatchCount < 0 || count != lastBatchCount)
        var newEffects: [(Int, RenderInstance)] = []

        for (idx, inst) in instances.enumerated() {
            let k = UInt32(max(0, Int(inst.params.y.rounded())))
            let p: Float = (k == UInt32(KIND_GLYPH)) ? inst.params.z : ((k == UInt32(KIND_IMAGE)) ? inst.params.x : 0.0)
            kinds.append(k)
            pages.append(p)
            if !paramsChanged && (lastBatchKinds[idx] != k || lastBatchPages[idx] != p) {
                paramsChanged = true
            }
            if k == UInt32(KIND_EFFECT) || k == UInt32(KIND_BACKDROP_BLUR) {
                newEffects.append((idx, inst))
            }
        }
        effects = newEffects

        guard paramsChanged else {
            return
        }

        batchRuns &+= 1
        lastBatchCount = count
        lastBatchKinds = kinds
        lastBatchPages = pages

        imageBatches.removeAll(keepingCapacity: true)
        guard count > 0 else { return }

        var curBind: RenderBatchBind = .image(0)
        var batchStart = 0
        for idx in 0..<count {
            let k = kinds[idx]
            let isBatchedKind = (k == UInt32(KIND_GLYPH) || k == UInt32(KIND_IMAGE) || k == UInt32(KIND_LAYER) || k == UInt32(KIND_EFFECT) || k == UInt32(KIND_BACKDROP_BLUR))
            if !isBatchedKind {
                continue
            }
            let wanted: RenderBatchBind?
            if k == UInt32(KIND_IMAGE) {
                let raw = max(0, Int(pages[idx].rounded()))
                let clamped = imagePageCount > 0 ? min(raw, imagePageCount - 1) : raw
                wanted = .image(clamped)
            } else if k == UInt32(KIND_GLYPH) {
                let g = max(0, Int(pages[idx].rounded()))
                if g == 0 {
                    switch curBind {
                    case .image:
                        wanted = nil
                    case .glyph:
                        wanted = .image(0)
                    }
                } else {
                    let clamped = glyphPageCount > 0 ? min(g - 1, glyphPageCount - 1) : (g - 1)
                    wanted = .glyph(clamped)
                }
            } else {
                wanted = nil
            }
            if let wanted, wanted != curBind {
                if idx > batchStart {
                    imageBatches.append((batchStart..<idx, curBind))
                }
                curBind = wanted
                batchStart = idx
            }
        }
        if batchStart < count {
            imageBatches.append((batchStart..<count, curBind))
        }
    }
}
#endif
