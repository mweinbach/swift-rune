import Foundation
#if canImport(Metal)
import Metal
#endif

/// Uniforms matching `fx_firesim_step_kernel` in `RuneFXShaders.swift`.
public struct FireSimKernelParams: Sendable, Equatable {
    public var dt: Float
    public var buoyancy: Float
    public var cooling: Float
    public var smoke: Float

    public init(dt: Float, buoyancy: Float, cooling: Float, smoke: Float) {
        self.dt = dt
        self.buoyancy = buoyancy
        self.cooling = cooling
        self.smoke = smoke
    }
}

/// Claim key identifying a fire simulation grid across frames.
public struct FireSimKey: Sendable, Equatable, Hashable {
    public let seed: UInt32
    public let style: UInt32
    public let width: UInt32
    public let height: UInt32

    public init(seed: UInt32, style: UInt32, width: UInt32, height: UInt32) {
        self.seed = seed
        self.style = style
        self.width = width
        self.height = height
    }
}

/// Which fire a grid serves: matched by `(seed, style, size)` and claimed once per frame.
public struct FireSimClaim: Sendable, Equatable {
    public var key: FireSimKey
    public var origin: SIMD2<Float>
    public var usedFrame: UInt64

    public init(key: FireSimKey, origin: SIMD2<Float>, usedFrame: UInt64) {
        self.key = key
        self.origin = origin
        self.usedFrame = usedFrame
    }

    /// A grid whose fire wasn't drawn last frame is expired.
    public func isAlive(at frame: UInt64) -> Bool {
        usedFrame + 1 >= frame
    }
}

/// Where a planned simulation run starts.
public enum FireSimStart: Sendable, Equatable {
    case `continue`(t0: Float)
    case reset(t0: Float)

    public var t0: Float {
        switch self {
        case .continue(let t0), .reset(let t0): return t0
        }
    }

    public var isReset: Bool {
        if case .reset = self { return true }
        return false
    }
}

/// Planned simulation steps for one grid in the current frame.
public struct FireSimPlan: Sendable, Equatable {
    public let steps: Int
    public let start: FireSimStart
    public let kernelParams: FireSimKernelParams
    public let gridSize: SIMD2<UInt32>
    public let cellSize: Float
}

/// Current lifecycle phase of a fire simulation grid in a frame.
public enum FireSimPhase: Sendable, Equatable {
    case idle
    case planned(FireSimPlan)
    case stepped
}

private final class FireSimGrid: @unchecked Sendable {
    var claim: FireSimClaim
    let size: SIMD2<UInt32>
    #if canImport(Metal)
    let textures: [MTLTexture]
    #endif
    var currentIndex: Int = 0
    var simTime: Float? = nil
    var phase: FireSimPhase = .idle

    #if canImport(Metal)
    init(claim: FireSimClaim, size: SIMD2<UInt32>, textures: [MTLTexture]) {
        self.claim = claim
        self.size = size
        self.textures = textures
    }
    #else
    init(claim: FireSimClaim, size: SIMD2<UInt32>) {
        self.claim = claim
        self.size = size
    }
    #endif
}

/// Fire and smoke simulation planner & ping-pong state manager.
///
/// Matches upstream `crates/rune-fx/src/sim.rs`: fixed `1/60s` steps, capped per frame (`maxSteps = 4`)
/// with initial warmup (`1.2s`) on new grids or time rewinds. Supports both Metal compute dispatch
/// (`record(commandBuffer:pipeline:)`) and headless CPU stepping (`stepCPU()`).
public final class FireSim: @unchecked Sendable {
    public static let dt: Float = 1.0 / 60.0
    public static let jacobiIterations: Int = 14
    public static let maxSteps: Int = 4
    public static let warmupSeconds: Float = 1.2
    public static let maxSlots: Int = 80

    #if canImport(Metal)
    private let device: MTLDevice?
    #endif
    private var grids: [FireSimGrid] = []
    public private(set) var frame: UInt64 = 0

    #if canImport(Metal)
    public init(device: MTLDevice? = nil) {
        self.device = device
    }
    #else
    public init() {}
    #endif

    public var gridCount: Int {
        grids.count
    }

    public var pending: Bool {
        grids.contains {
            if case .planned = $0.phase { return true }
            return false
        }
    }

    /// Advance to a new frame, dropping grids not claimed in the previous frame.
    public func beginFrame() {
        frame += 1
        let f = frame
        grids.removeAll { !$0.claim.isAlive(at: f) }
        for g in grids {
            g.phase = .idle
        }
    }

    /// Compute `(steps, start)` for a grid last stepped to `prev` (`nil` if never) to reach `target`.
    public static func schedule(prev: Float?, target: Float, frozen: Bool) -> (steps: Int, start: FireSimStart) {
        if let t = prev {
            if frozen {
                return (0, .continue(t0: t))
            }
            if target >= t - 1e-4 {
                let due = Int(floor((target - t) / dt + 1e-3))
                let steps = min(max(due, 0), maxSteps)
                return (steps, .continue(t0: target - Float(steps) * dt))
            }
        }
        let steps = min(Int((warmupSeconds / dt).rounded()), maxSlots)
        return (steps, .reset(t0: target - Float(steps) * dt))
    }

    /// Pick the nearest unclaimed grid matching `key` to `origin`.
    public static func pickGrid(
        claims: [FireSimClaim],
        key: FireSimKey,
        origin: SIMD2<Float>,
        frame: UInt64
    ) -> Int? {
        var bestIdx: Int?
        var bestDist = Float.greatestFiniteMagnitude
        for (i, c) in claims.enumerated() where c.key == key && c.usedFrame != frame {
            let dx = c.origin.x - origin.x
            let dy = c.origin.y - origin.y
            let d2 = dx * dx + dy * dy
            if d2 < bestDist {
                bestDist = d2
                bestIdx = i
            }
        }
        return bestIdx
    }

    /// Find or allocate the grid for a fire layer covering `domain` (pt) and plan this frame's steps.
    /// Returns `(gridIndex, extentInPt)`.
    public func plan(
        layer: FxLayer,
        params: FireParams,
        domain: FxRect,
        frozen: Bool = false
    ) -> (gridIndex: Int, extent: SIMD2<Float>) {
        let area = max(domain.w * domain.h, 1.0)
        let cell = min(max(sqrt(area / 16_000.0), 1.0), 3.0)
        let nx = max(UInt32(ceil(domain.w / cell)), 8)
        let ny = max(UInt32(ceil(domain.h / cell)), 8)
        let size = SIMD2<UInt32>(nx, ny)
        let styleCode: UInt32 = {
            switch params.style {
            case .top: return 0
            case .border: return 1
            case .heat: return 2
            case .embers: return 3
            }
        }()
        let key = FireSimKey(seed: layer.seed, style: styleCode, width: nx, height: ny)
        let origin = SIMD2<Float>(domain.x, domain.y)
        let claim = FireSimClaim(key: key, origin: origin, usedFrame: frame)

        let idx: Int
        if let found = Self.pickGrid(claims: grids.map(\.claim), key: key, origin: origin, frame: frame) {
            idx = found
            grids[idx].claim = claim
        } else {
            #if canImport(Metal)
            let textures = allocateTextures(size: size)
            grids.append(FireSimGrid(claim: claim, size: size, textures: textures))
            #else
            grids.append(FireSimGrid(claim: claim, size: size))
            #endif
            idx = grids.count - 1
        }

        let g = grids[idx]
        let (steps, start) = Self.schedule(prev: g.simTime, target: layer.time, frozen: frozen)
        let speed = max(params.speed / 1.5, 0.05)
        let rise = min(max(params.height * 2.2, 20.0), 140.0) * sqrt(speed)
        let cooling = 1.15 * rise / max(params.height, 4.0)

        if steps == 0 {
            g.phase = .idle
        } else {
            let kp = FireSimKernelParams(
                dt: Self.dt,
                buoyancy: rise,
                cooling: cooling,
                smoke: max(params.smoke, 0.0) * 0.6
            )
            g.phase = .planned(FireSimPlan(
                steps: steps,
                start: start,
                kernelParams: kp,
                gridSize: size,
                cellSize: cell
            ))
        }

        return (idx, SIMD2<Float>(Float(nx) * cell, Float(ny) * cell))
    }

    public func plannedSteps(at index: Int) -> Int {
        guard index >= 0 && index < grids.count else { return 0 }
        if case .planned(let p) = grids[index].phase { return p.steps }
        return 0
    }

    public func simTime(at index: Int) -> Float? {
        guard index >= 0 && index < grids.count else { return nil }
        return grids[index].simTime
    }

    public func phase(at index: Int) -> FireSimPhase? {
        guard index >= 0 && index < grids.count else { return nil }
        return grids[index].phase
    }

    /// The ping-pong texture index (`0` or `1`) that will hold the final state for this frame.
    public func finalPingPongIndex(at index: Int) -> Int {
        guard index >= 0 && index < grids.count else { return 0 }
        let g = grids[index]
        let steps: Int
        switch g.phase {
        case .planned(let p): steps = p.steps
        case .idle, .stepped: steps = 0
        }
        return g.currentIndex ^ (steps & 1)
    }

    #if canImport(Metal)
    /// The state texture a fire layer should sample this frame (after its planned steps).
    public func finalTexture(at index: Int) -> MTLTexture? {
        guard index >= 0 && index < grids.count else { return nil }
        let g = grids[index]
        guard !g.textures.isEmpty else { return nil }
        return g.textures[finalPingPongIndex(at: index)]
    }
    #endif

    /// Advance planned grids on CPU (updates ping-pong state, `simTime`, and `phase`) without GPU encoding.
    @discardableResult
    public func stepCPU() -> Bool {
        guard pending else { return false }
        for g in grids {
            guard case .planned(let plan) = g.phase else { continue }
            g.currentIndex ^= (plan.steps & 1)
            g.simTime = plan.start.t0 + Float(plan.steps) * Self.dt
            g.phase = .stepped
        }
        return true
    }

    #if canImport(Metal)
    /// Record compute passes for all planned grids onto `commandBuffer`.
    @discardableResult
    public func record(commandBuffer: MTLCommandBuffer, pipeline: MTLComputePipelineState) -> Bool {
        guard pending else { return false }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.label = "fx firesim"
        encoder.setComputePipelineState(pipeline)

        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)

        for g in grids {
            guard case .planned(let plan) = g.phase else { continue }
            if g.textures.count == 2 {
                var kp = plan.kernelParams
                let gridThreads = MTLSize(width: Int(g.size.x), height: Int(g.size.y), depth: 1)
                for _ in 0..<plan.steps {
                    let src = g.textures[g.currentIndex]
                    let dst = g.textures[g.currentIndex ^ 1]
                    encoder.setTexture(src, index: 0)
                    encoder.setTexture(dst, index: 1)
                    encoder.setBytes(&kp, length: MemoryLayout<FireSimKernelParams>.stride, index: 0)
                    encoder.dispatchThreads(gridThreads, threadsPerThreadgroup: threadsPerGroup)
                    g.currentIndex ^= 1
                }
            } else {
                g.currentIndex ^= (plan.steps & 1)
            }
            g.simTime = plan.start.t0 + Float(plan.steps) * Self.dt
            g.phase = .stepped
        }

        encoder.endEncoding()
        return true
    }

    private func allocateTextures(size: SIMD2<UInt32>) -> [MTLTexture] {
        guard let device else { return [] }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: Int(size.x),
            height: Int(size.y),
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let a = device.makeTexture(descriptor: desc),
              let b = device.makeTexture(descriptor: desc) else {
            return []
        }
        a.label = "fx sim state a"
        b.label = "fx sim state b"
        return [a, b]
    }
    #endif
}
