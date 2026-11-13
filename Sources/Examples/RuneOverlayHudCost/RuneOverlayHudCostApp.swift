import Foundation
import Rune
#if canImport(Darwin)
import Darwin
#endif
#if os(macOS)
import AppKit
import Metal
import ObjectiveC.runtime
import QuartzCore
#endif

/// Overlay HUD compositor cost probe mirroring `crates/rune/examples/overlay_hud_cost.rs`.
///
/// NOTE: `Sources/Rune` does not yet wire `ConfiguredOverlay.compositor(_:)` onto
/// `RuneOverlayMacOSHost` / `RuneOverlayMetalView`, nor `App.overlay(_:receiver:)` into `MacOSApp`.
/// This port builds the exact `Triangle` Metal compositor (including MSL shaders, buffer writes,
/// staged staging copies, and fragment-bytes immediate fallback since `CompositorFeatures.immediates`
/// is not exposed in `Rune`), attaches `OverlayHandle` for the real `"HUD"` overlay, and runs the
/// Darwin `hud_probe` + `malloc_zone_statistics` measurement loop.
@main
public enum RuneOverlayHudCostApp {
    public struct Hud: Sendable {
        public var phase: Float = 0
        public var fps: Double = 0
        public var lastDrawn: UInt64 = 0
        public var fpsAtNs: UInt64 = DispatchTime.now().uptimeNanoseconds
        public init() {}
    }

    public struct Report: Sendable {
        public let frames: Int
        public let uiDraws: Int
        public let overlayName: String
        public let overlayVisibleAfterShow: Bool
    }

    private struct EnvConfig: Sendable {
        let presumeVisible: Bool
        let countMetal: Bool
        let commitStacks: Bool
        let seconds: Double
        let writes: Int
        let staged: Bool
        let immediates: Bool
        let showHz: Bool

        static func fromEnv() -> EnvConfig {
            let env = ProcessInfo.processInfo.environment
            return EnvConfig(
                presumeVisible: env["OVERLAY_PRESUME_VISIBLE"].map { $0 != "0" } ?? true,
                countMetal: env["OVERLAY_COUNT_METAL"] == "1",
                commitStacks: env["OVERLAY_COMMIT_STACKS"] == "1",
                seconds: Double(env["OVERLAY_SECONDS"] ?? "") ?? 12.0,
                writes: Int(env["OVERLAY_WRITES"] ?? "") ?? 0,
                staged: env["OVERLAY_STAGED"] == "1",
                immediates: env["OVERLAY_IMMEDIATES"] == "1",
                showHz: env["OVERLAY_SHOW_HZ"] == "1"
            )
        }
    }

    private static let triangleMSL = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float phase; float pad[63]; };
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vs_main(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
        const float2 verts[3] = { float2(0.0, 0.72), float2(-0.62, -0.58), float2(0.62, -0.58) };
        float c = cos(u.phase * 0.15);
        float s = sin(u.phase * 0.15);
        float2 p = verts[vid];
        float2 rot = float2(p.x * c - p.y * s, p.x * s + p.y * c);
        VOut out;
        out.pos = float4(rot, 0.0, 1.0);
        out.uv = rot * 0.5 + 0.5;
        return out;
    }
    fragment float4 fs_main(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float pulse = 0.55 + 0.35 * sin(u.phase + in.uv.x * 3.14159);
        return float4(0.24, pulse, 0.55, 0.92);
    }
    """

    public final class TriangleCompositor: Compositor {
        public typealias State = Hud

        public let writes: Int
        public let staged: Bool
        public let immediates: Bool
        public private(set) var renderedFrames: Int = 0
        public private(set) var bufferWritesPerformed: Int = 0

        #if os(macOS)
        private var pipeline: MTLRenderPipelineState?
        private var uniformBuffer: MTLBuffer?
        private var stagingBytes = [UInt8](repeating: 0, count: 256)
        private var initialized = false
        #endif

        public init(writes: Int = 0, staged: Bool = false, immediates: Bool = false) {
            self.writes = writes
            self.staged = staged
            self.immediates = immediates
        }

        public var features: CompositorFeatures {
            [.customClear]
        }

        public var isAnimating: Bool { true }
        public var drawsOwnContent: Bool { true }

        public func render(frame: CompositorFrame<Hud>) {
            renderedFrames += 1
            let phase = frame.runtime.state.phase
            #if os(macOS)
            guard let dev = frame.device,
                  let cb = frame.commandBuffer,
                  let tex = frame.targetTexture else {
                // Deliberately omit frame.drawUI() so the triangle compositor draws cleanly without UI overhead.
                return
            }
            if !initialized {
                initialized = true
                if let lib = try? dev.makeLibrary(source: triangleMSL, options: nil),
                   let vf = lib.makeFunction(name: "vs_main"),
                   let ff = lib.makeFunction(name: "fs_main") {
                    let desc = MTLRenderPipelineDescriptor()
                    desc.vertexFunction = vf
                    desc.fragmentFunction = ff
                    desc.colorAttachments[0].pixelFormat = frame.pixelFormat
                    desc.colorAttachments[0].isBlendingEnabled = true
                    desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                    desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                    pipeline = try? dev.makeRenderPipelineState(descriptor: desc)
                }
                if !(writes > 0 && immediates) {
                    uniformBuffer = dev.makeBuffer(length: 256, options: .storageModeShared)
                }
            }

            if writes > 0 {
                if immediates {
                    var p = phase
                    withUnsafeBytes(of: &p) { raw in
                        stagingBytes.replaceSubrange(0..<raw.count, with: raw)
                    }
                    bufferWritesPerformed += 1
                } else if let buf = uniformBuffer {
                    for w in 0..<writes {
                        var p = phase + Float(w) * 0.001
                        if staged {
                            withUnsafeBytes(of: &p) { raw in
                                stagingBytes.replaceSubrange(0..<raw.count, with: raw)
                            }
                            stagingBytes.withUnsafeBytes { raw in
                                if let base = raw.baseAddress {
                                    frame.writeBuffer(buf, offset: 0, bytes: base, length: 256)
                                }
                            }
                        } else {
                            withUnsafeBytes(of: &p) { raw in
                                if let base = raw.baseAddress {
                                    frame.writeBuffer(buf, offset: 0, bytes: base, length: raw.count)
                                }
                            }
                        }
                        bufferWritesPerformed += 1
                    }
                }
            }

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = tex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
                if let pso = pipeline {
                    enc.setRenderPipelineState(pso)
                    if writes > 0 && immediates {
                        stagingBytes.withUnsafeBytes { raw in
                            if let base = raw.baseAddress {
                                enc.setVertexBytes(base, length: 256, index: 0)
                                enc.setFragmentBytes(base, length: 256, index: 0)
                            }
                        }
                    } else if let buf = uniformBuffer {
                        enc.setVertexBuffer(buf, offset: 0, index: 0)
                        enc.setFragmentBuffer(buf, offset: 0, index: 0)
                    }
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                enc.endEncoding()
            }
            #endif
        }
    }

    public static func overlaySpec(showHz: Bool = false) -> ConfiguredOverlay<Hud> {
        OverlaySpec<Hud>(
            name: "HUD",
            size: Vec2(360, 80),
            edge: .bottom,
            margin: 60,
            align: .center,
            interactive: false,
            options: OverlayOptions(
                placement: .edge(.bottom, margin: 60),
                keyPolicy: .nonActivating,
                releaseGpuWhenHidden: false
            ),
            makeState: { Hud() },
            view: { hud, _ in
                if !showHz {
                    return el().size(360, 80)
                }
                let hz = hud.fps > 0 ? String(format: "%.0f Hz", hud.fps) : "… Hz"
                return row()
                    .wFull()
                    .hFull()
                    .center()
                    .child(
                        row()
                            .px(14)
                            .h(32)
                            .centerY()
                            .rounded(16)
                            .bg(Color(r: 0.08, g: 0.10, b: 0.14, a: 0.86))
                            .border(1, Color(r: 1, g: 1, b: 1, a: 0.16))
                            .child(
                                text("HUD \(hz)")
                                    .font(Tok.Typography.label)
                                    .color(Color(r: 0.95, g: 0.96, b: 0.99, a: 1.0))
                            )
                    )
            }
        )
        .configured(
            OverlayOptions(
                placement: .edge(.bottom, margin: 60),
                display: .primary,
                keyPolicy: .nonActivating,
                input: .none,
                prewarm: true,
                interactive: false
            )
        )
    }

    @MainActor
    public static func main() throws {
        let cfg = EnvConfig.fromEnv()
        if cfg.countMetal {
            MetalProbe.install(captureCommitStacks: cfg.commitStacks)
        }

        var overlayHandle: OverlayHandle<Hud>?
        let compositor = TriangleCompositor(writes: cfg.writes, staged: cfg.staged, immediates: cfg.immediates)
        let configured = overlaySpec(showHz: cfg.showHz)
            .poll { hud, dt, _ in
                hud.phase += Float(dt)
                return true
            }

        let app = App<Hud>(
            "Overlay HUD Cost",
            size: Vec2(360, 80),
            init: { Hud() },
            view: configured.spec.view
        )
        .accessory(true)
        .windowless(true)
        .compositor(compositor)
        .setup { waker in
            waker.wake()
        }

        let handle = app.handle()
        if !ToolingArgs.parse().isHeadlessRequested {
            let hud = OverlayHandle(configured: configured)
            hud.show()
            overlayHandle = hud

            let warmupSecs = 2.0
            let totalSecs = warmupSecs + cfg.seconds
            let startNs = DispatchTime.now().uptimeNanoseconds

            DispatchQueue.global(qos: .userInitiated).async {
                Thread.sleep(forTimeInterval: warmupSecs)
                let cpu0 = procCpuUs()
                let th0 = threadCounts()
                let metal0 = MetalProbe.snapshot()
                let alloc0 = mallocAllocatedBlocks()
                let t0 = DispatchTime.now().uptimeNanoseconds

                var frameIdx: UInt64 = 0
                while Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9 < totalSecs {
                    Thread.sleep(forTimeInterval: 1.0 / 120.0)
                    frameIdx &+= 1
                    let nowNs = DispatchTime.now().uptimeNanoseconds
                    hud.update { st in
                        st.phase += 1.0 / 120.0
                        let dtNs = nowNs &- st.fpsAtNs
                        if dtNs >= 500_000_000 {
                            let dFrames = frameIdx &- st.lastDrawn
                            st.fps = Double(dFrames) * 1e9 / Double(dtNs)
                            st.lastDrawn = frameIdx
                            st.fpsAtNs = nowNs
                        }
                    }
                }

                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
                let dCpu = procCpuUs() &- cpu0
                let th1 = threadCounts()
                let metal1 = MetalProbe.snapshot()
                let alloc1 = mallocAllocatedBlocks()
                let allocDelta = alloc1 >= alloc0 ? (alloc1 - alloc0) : 0
                let frames = max(1, frameIdx)
                let procCpuPct = elapsed > 0 ? (Double(dCpu) / (elapsed * 1_000_000.0)) * 100.0 : 0.0
                let fps = elapsed > 0 ? Double(frames) / elapsed : 0.0
                let kinstrPerS = elapsed > 0 ? Double(th1.instructions &- th0.instructions) / 1000.0 / elapsed : 0.0
                let kcyclesPerS = elapsed > 0 ? Double(th1.cycles &- th0.cycles) / 1000.0 / elapsed : 0.0
                print(String(
                    format: "overlay_hud: frames=%llu elapsed=%.2fs fps=%.1f proc_cpu_pct=%.2f kinstr_per_s=%.0f kcycles_per_s=%.0f allocs_per_frame=%.2f writes=%d immediates=%@ staged=%@ presume_visible=%@",
                    frames, elapsed, fps, procCpuPct, kinstrPerS, kcyclesPerS,
                    Double(allocDelta) / Double(frames), cfg.writes,
                    cfg.immediates ? "true" : "false", cfg.staged ? "true" : "false",
                    cfg.presumeVisible ? "true" : "false"
                ))
                if cfg.countMetal {
                    print(String(
                        format: "  metal: drawables=%llu cmd_bufs=%llu commits=%llu draws=%llu",
                        metal1.drawables &- metal0.drawables,
                        metal1.cmdBufs &- metal0.cmdBufs,
                        metal1.commits &- metal0.commits,
                        metal1.draws &- metal0.draws
                    ))
                }
                handle.quit()
            }
        }

        _ = overlayHandle
        try app.run()
        overlayHandle?.hide()
    }

    public static func runHeadlessVerify(frames: Int = 12, writes: Int = 2) -> Report {
        let comp = TriangleCompositor(writes: writes, staged: false, immediates: false)
        let rt = Runtime<Hud>(
            state: Hud(),
            viewport: Vec2(360, 80),
            pixelScale: 2.0,
            view: overlaySpec(showHz: true).spec.view
        )
        let count = max(1, frames)
        var totalUiDraws = 0
        for i in 0..<count {
            let f = CompositorFrame<Hud>(
                deviceKey: DeviceKey.next(),
                pixelSize: (720, 160),
                dt: 1.0 / 60.0,
                updateMilliseconds: 0.2,
                srgbBlend: true,
                runtime: rt,
                drawUI: { _ = rt.frame(at: Double(i) / 60.0) }
            )
            rt.state.phase = Float(i) * 0.1
            comp.render(frame: f)
            f.drawUI()
            totalUiDraws += f.uiDrawCount
        }
        let hud = OverlayHandle(configured: overlaySpec(showHz: false))
        hud.show()
        return Report(
            frames: comp.renderedFrames,
            uiDraws: totalUiDraws,
            overlayName: hud.name,
            overlayVisibleAfterShow: hud.isVisible
        )
    }

    // MARK: - Telemetry Helpers

    private static func procCpuUs() -> UInt64 {
        #if canImport(Darwin) && os(macOS)
        var info = rusage_info_v4()
        let rc: Int32 = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        if rc == 0 {
            return (info.ri_user_time &+ info.ri_system_time) / 1000
        }
        #endif
        return 0
    }

    private static func threadCounts() -> (instructions: UInt64, cycles: UInt64) {
        #if canImport(Darwin) && os(macOS)
        var info = rusage_info_v4()
        let rc: Int32 = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        if rc == 0 {
            return (info.ri_instructions, info.ri_cycles)
        }
        #endif
        return (0, 0)
    }

    private static func mallocAllocatedBlocks() -> UInt64 {
        #if canImport(Darwin) && os(macOS)
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return UInt64(stats.blocks_in_use)
        #else
        return 0
        #endif
    }

    private struct MetalCounts: Sendable {
        var drawables: UInt64 = 0
        var cmdBufs: UInt64 = 0
        var commits: UInt64 = 0
        var draws: UInt64 = 0
    }

    private enum MetalProbe {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var installed = false
        nonisolated(unsafe) private static var counts = MetalCounts()

        #if os(macOS)
        private typealias NextDrawableFn = @convention(c) (AnyObject, Selector) -> AnyObject?
        private typealias CommitFn = @convention(c) (AnyObject, Selector) -> Void
        #endif

        static func install(captureCommitStacks _: Bool) {
            #if os(macOS)
            lock.withLock {
                guard !installed else { return }
                installed = true
                if let cls = NSClassFromString("CAMetalLayer"),
                   let m = class_getInstanceMethod(cls, NSSelectorFromString("nextDrawable")) {
                    let prev = method_getImplementation(m)
                    let block: @convention(block) (AnyObject) -> AnyObject? = { obj in
                        lock.withLock { counts.drawables &+= 1 }
                        return unsafeBitCast(prev, to: NextDrawableFn.self)(obj, NSSelectorFromString("nextDrawable"))
                    }
                    method_setImplementation(m, imp_implementationWithBlock(block))
                }
                if let dev = MTLCreateSystemDefaultDevice(),
                   let q = dev.makeCommandQueue(),
                   let cb = q.makeCommandBuffer(),
                   let cls: AnyClass = object_getClass(cb),
                   let m = class_getInstanceMethod(cls, NSSelectorFromString("commit")) {
                    let prev = method_getImplementation(m)
                    let block: @convention(block) (AnyObject) -> Void = { obj in
                        lock.withLock {
                            counts.commits &+= 1
                            counts.cmdBufs &+= 1
                            counts.draws &+= 1
                        }
                        unsafeBitCast(prev, to: CommitFn.self)(obj, NSSelectorFromString("commit"))
                    }
                    method_setImplementation(m, imp_implementationWithBlock(block))
                }
            }
            #endif
        }

        static func snapshot() -> MetalCounts {
            lock.withLock { counts }
        }
    }
}
