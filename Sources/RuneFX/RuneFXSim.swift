import Foundation
import Rune
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

/// Uniforms matching `FireSimUniform` (96 bytes) in `firesim` kernels (`RuneFXShaders.fireSimShader`).
public struct FireSimUniform: Sendable, Equatable {
    public var dims: SIMD4<Float>
    public var origin: SIMD4<Float>
    public var shape: SIMD4<Float>
    public var shape2: SIMD4<Float>
    public var fire: SIMD4<Float>
    public var fire2: SIMD4<Float>

    public init(
        dims: SIMD4<Float> = .zero,
        origin: SIMD4<Float> = .zero,
        shape: SIMD4<Float> = .zero,
        shape2: SIMD4<Float> = .zero,
        fire: SIMD4<Float> = .zero,
        fire2: SIMD4<Float> = .zero
    ) {
        self.dims = dims
        self.origin = origin
        self.shape = shape
        self.shape2 = shape2
        self.fire = fire
        self.fire2 = fire2
    }
}

#if canImport(Metal)
/// The 6 Metal compute pipelines backing the stable-fluids fire solver (`curl`, `forces`, `divergence`, `jacobi`, `project`, `advect`).
public struct FireSimPipelines: @unchecked Sendable {
    public let curl: MTLComputePipelineState
    public let forces: MTLComputePipelineState
    public let divergence: MTLComputePipelineState
    public let jacobi: MTLComputePipelineState
    public let project: MTLComputePipelineState
    public let advect: MTLComputePipelineState

    public init(device: MTLDevice, library: MTLLibrary? = nil) throws {
        let lib: MTLLibrary
        if let library {
            lib = library
        } else {
            lib = try ShaderLibraryCache.load(
                named: "fx_firesim",
                source: RuneFXShaders.fireSimShader,
                requiredFunction: "fx_firesim_step_kernel",
                bundle: .module,
                on: device
            )
        }
        func make(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = lib.makeFunction(name: name) else {
                throw FxRendererError.shaderCompileFailed("Missing firesim kernel '\(name)'")
            }
            return try device.makeComputePipelineState(function: fn)
        }
        self.curl = try make("curl")
        self.forces = try make("forces")
        self.divergence = try make("divergence")
        self.jacobi = try make("jacobi")
        self.project = try make("project")
        self.advect = try make("advect")
    }
}
#endif

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
    public let uniform: FireSimUniform
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
    let scalars: [MTLTexture]
    let uniformBuffer: MTLBuffer?
    #endif
    var currentIndex: Int = 0
    var simTime: Float? = nil
    var phase: FireSimPhase = .idle

    #if canImport(Metal)
    init(
        claim: FireSimClaim,
        size: SIMD2<UInt32>,
        textures: [MTLTexture],
        scalars: [MTLTexture],
        uniformBuffer: MTLBuffer?
    ) {
        self.claim = claim
        self.size = size
        self.textures = textures
        self.scalars = scalars
        self.uniformBuffer = uniformBuffer
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
/// with initial warmup (`1.2s`) on new grids or time rewinds. Supports both full 6-pass Metal compute
/// solving (`record(commandBuffer:pipelines:)`) and headless CPU stepping (`stepCPU()`).
public final class FireSim: @unchecked Sendable {
    public static let dt: Float = 1.0 / 60.0
    public static let jacobiIterations: Int = 14
    public static let maxSteps: Int = 4
    public static let warmupSeconds: Float = 1.2
    public static let maxSlots: Int = 80
    public static let slotStride: Int = 256

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
            let (textures, scalars, uniformBuffer) = allocateResources(size: size)
            grids.append(FireSimGrid(
                claim: claim,
                size: size,
                textures: textures,
                scalars: scalars,
                uniformBuffer: uniformBuffer
            ))
            #else
            grids.append(FireSimGrid(claim: claim, size: size))
            #endif
            idx = grids.count - 1
        }

        let g = grids[idx]
        let (steps, start) = Self.schedule(prev: g.simTime, target: layer.time, frozen: frozen)
        let r = layer.shape.rect
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
            let uniform = FireSimUniform(
                dims: SIMD4<Float>(Float(nx), Float(ny), cell, Self.dt),
                origin: SIMD4<Float>(domain.x, domain.y, 0.0, 0.0),
                shape: SIMD4<Float>(r.x + r.w * 0.5, r.y + r.h * 0.5, r.w * 0.5, r.h * 0.5),
                shape2: SIMD4<Float>(layer.shape.radius, Float(layer.seed % 65_536), rise, max(params.scale, 2.0)),
                fire: SIMD4<Float>(rise * 3.0, cooling, max(params.smoke, 0.0) * 0.6, 0.25 + 0.6 * params.warp),
                fire2: SIMD4<Float>(rise * (0.3 + 1.5 * params.swirl), speed, 1.4, 2.0)
            )
            g.phase = .planned(FireSimPlan(
                steps: steps,
                start: start,
                kernelParams: kp,
                uniform: uniform,
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
    /// Record full 6-pass stable-fluids compute solver (`curl`, `forces`, `divergence`, 14x `jacobi`,
    /// `project`, `advect`) for all planned grids onto `commandBuffer`.
    @discardableResult
    public func record(commandBuffer: MTLCommandBuffer, pipelines: FireSimPipelines) -> Bool {
        guard pending else { return false }

        for g in grids {
            guard case .planned(let plan) = g.phase, let uBuf = g.uniformBuffer else { continue }
            let count = min(plan.steps, Self.maxSlots)
            let ptr = uBuf.contents()
            for k in 0..<count {
                var u = plan.uniform
                u.origin.z = plan.start.t0 + Float(k + 1) * Self.dt
                u.origin.w = (plan.start.isReset && k == 0) ? 1.0 : 0.0
                memcpy(ptr.advanced(by: k * Self.slotStride), &u, MemoryLayout<FireSimUniform>.stride)
            }
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.label = "fx firesim"
        let tpg = MTLSize(width: 8, height: 8, depth: 1)

        for g in grids {
            guard case .planned(let plan) = g.phase else { continue }
            if g.textures.count == 2 && g.scalars.count == 4, let uBuf = g.uniformBuffer {
                let curlTex = g.scalars[0]
                let divTex = g.scalars[1]
                let p0Tex = g.scalars[2]
                let p1Tex = g.scalars[3]
                let wg = MTLSize(
                    width: (Int(g.size.x) + 7) / 8,
                    height: (Int(g.size.y) + 7) / 8,
                    depth: 1
                )
                let count = min(plan.steps, Self.maxSlots)
                for k in 0..<count {
                    let off = k * Self.slotStride
                    let x = g.textures[g.currentIndex]
                    let y = g.textures[g.currentIndex ^ 1]

                    encoder.setBuffer(uBuf, offset: off, index: 0)

                    encoder.setComputePipelineState(pipelines.curl)
                    encoder.setTexture(x, index: 0)
                    encoder.setTexture(curlTex, index: 4)
                    encoder.dispatchThreadgroups(wg, threadsPerThreadgroup: tpg)

                    encoder.setComputePipelineState(pipelines.forces)
                    encoder.setTexture(x, index: 0)
                    encoder.setTexture(y, index: 1)
                    encoder.setTexture(curlTex, index: 2)
                    encoder.dispatchThreadgroups(wg, threadsPerThreadgroup: tpg)

                    encoder.setComputePipelineState(pipelines.divergence)
                    encoder.setTexture(y, index: 0)
                    encoder.setTexture(divTex, index: 4)
                    encoder.dispatchThreadgroups(wg, threadsPerThreadgroup: tpg)

                    encoder.setComputePipelineState(pipelines.jacobi)
                    for j in 0..<Self.jacobiIterations {
                        if (j & 1) == 0 {
                            encoder.setTexture(p0Tex, index: 2)
                            encoder.setTexture(divTex, index: 3)
                            encoder.setTexture(p1Tex, index: 4)
                        } else {
                            encoder.setTexture(p1Tex, index: 2)
                            encoder.setTexture(divTex, index: 3)
                            encoder.setTexture(p0Tex, index: 4)
                        }
                        encoder.dispatchThreadgroups(wg, threadsPerThreadgroup: tpg)
                    }

                    encoder.setComputePipelineState(pipelines.project)
                    encoder.setTexture(y, index: 0)
                    encoder.setTexture(x, index: 1)
                    encoder.setTexture(p0Tex, index: 2)
                    encoder.dispatchThreadgroups(wg, threadsPerThreadgroup: tpg)

                    encoder.setComputePipelineState(pipelines.advect)
                    encoder.setTexture(x, index: 0)
                    encoder.setTexture(y, index: 1)
                    encoder.dispatchThreadgroups(wg, threadsPerThreadgroup: tpg)

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

    /// Record compute passes for all planned grids onto `commandBuffer` using a single custom compute pipeline.
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

    private func allocateResources(size: SIMD2<UInt32>) -> ([MTLTexture], [MTLTexture], MTLBuffer?) {
        guard let device else { return ([], [], nil) }
        func makeTex(_ format: MTLPixelFormat, _ label: String) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format,
                width: Int(size.x),
                height: Int(size.y),
                mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            let tex = device.makeTexture(descriptor: desc)
            tex?.label = label
            return tex
        }
        guard let a = makeTex(.rgba16Float, "fx sim state a"),
              let b = makeTex(.rgba16Float, "fx sim state b"),
              let curl = makeTex(.r32Float, "fx sim curl"),
              let div = makeTex(.r32Float, "fx sim div"),
              let p0 = makeTex(.r32Float, "fx sim p0"),
              let p1 = makeTex(.r32Float, "fx sim p1") else {
            return ([], [], nil)
        }
        let uBuf = device.makeBuffer(
            length: Self.maxSlots * Self.slotStride,
            options: .storageModeShared
        )
        uBuf?.label = "fx sim params"
        return ([a, b], [curl, div, p0, p1], uBuf)
    }
    #endif
}
