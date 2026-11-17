import Foundation
import Rune
import RuneFX
import RuneRef

#if canImport(Metal)
import Metal
#endif

/// Port of `crates/rune-fx/examples/first_glow.rs`.
///
/// Measures the cold cost of creating `FxRenderer`, registering `.rgba16Float`,
/// preparing and rendering the first 96x96 glow layer, and reading pixels back.
/// Supports `--snap PATH` to write a PNG snapshot of the glow output.
@main
enum RuneFxFirstGlowApp {
    static func main() throws {
        try run(args: Array(CommandLine.arguments.dropFirst()))
    }

    static func run(args: [String]) throws {
        let snapPath: String? = {
            guard let i = args.firstIndex(of: "--snap"), i + 1 < args.count else { return nil }
            return args[i + 1]
        }()

        let backend = GpuBackendPolicy.resolve(env: ProcessInfo.processInfo.environment["RUNE_GPU_BACKEND"], chosen: nil)
        #if os(macOS) || os(Linux) || os(Windows)
        if backend == .gl {
            try renderGL(snapPath: snapPath)
            return
        }
        #endif

        #if canImport(Metal)
        guard backend == .metal else { throw FxGlowError.unavailableBackend(backend) }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fputs("error: Metal device unavailable\n", stderr)
            Foundation.exit(1)
        }

        let w = 96
        let h = 96
        let format: MTLPixelFormat = .bgra8Unorm_srgb
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: w,
            height: h,
            mipmapped: false
        )
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: texDesc) else {
            fputs("error: failed to allocate 96x96 offscreen target\n", stderr)
            Foundation.exit(1)
        }

        let layers = [
            Fx.glow(GlowParams()).on(FxShape.rounded(x: 24, y: 24, w: 48, h: 48, radius: 8)),
        ]

        let clock = ContinuousClock()
        let tStart = clock.now
        let fx = try FxRenderer(device: device, pixelFormat: format, options: FxOptions())
        let tNew = clock.now - tStart

        fx.addFormat(.rgba16Float)
        let tAdd = (clock.now - tStart) - tNew

        _ = fx.prepare(
            frame: FxFrame(
                viewport: SIMD2<UInt32>(UInt32(w), UInt32(h)),
                scale: 1.0,
                layers: layers,
                backdrop: nil,
                sources: []
            )
        )

        guard let cmd = queue.makeCommandBuffer() else {
            fputs("error: commandBuffer creation failed\n", stderr)
            Foundation.exit(1)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            try fx.drawLayer(encoder: enc, layer: 0)
            enc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()

        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(
            &bgra,
            bytesPerRow: w * 4,
            from: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0
        )
        let tTotal = clock.now - tStart

        let hasGlow = stride(from: 3, to: bgra.count, by: 4).contains { bgra[$0] != 0 }
        precondition(hasGlow, "the glow drew")

        if let snapPath {
            var rgba = [UInt8](repeating: 0, count: bgra.count)
            for i in stride(from: 0, to: bgra.count, by: 4) {
                rgba[i] = bgra[i + 2]
                rgba[i + 1] = bgra[i + 1]
                rgba[i + 2] = bgra[i]
                rgba[i + 3] = bgra[i + 3]
            }
            let url = URL(fileURLWithPath: snapPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Frame(width: w, height: h, rgba: rgba).writePNG(to: url)
        }

        let adapter = DisplayGpuAdapter(backend: .metal, device: device.name)
        try report(adapter: adapter, initialization: tNew, registration: tAdd, total: tTotal)
        #elseif os(Linux) || os(Windows)
        throw FxGlowError.unavailableBackend(backend)
        #else
        throw FxGlowError.noOffscreenContext
        #endif
    }

    #if os(macOS) || os(Linux) || os(Windows)
    private static func renderGL(snapPath: String?) throws {
        let clock = ContinuousClock()
        let start = clock.now
        let context = try OffscreenGLContext()
        defer { context.close() }
        let renderer = try FxGLRenderer(resolve: OffscreenGLContext.resolve)
        defer { renderer.close() }
        let initialized = clock.now
        let layer = Fx.glow(GlowParams()).on(.rounded(x: 24, y: 24, w: 48, h: 48, radius: 8))
        let frame = try renderer.renderOffscreen(viewport: SIMD2(96, 96), layers: [layer])
        let end = clock.now
        guard stride(from: 3, to: frame.rgba.count, by: 4).contains(where: { frame.rgba[$0] != 0 }) else {
            throw FxGlowError.emptyOutput
        }
        if let snapPath { try frame.writePNG(to: URL(fileURLWithPath: snapPath)) }
        let adapter = DisplayGpuAdapter(backend: OffscreenGLContext.isGLES ? .openGLES : .openGL, device: renderer.adapter)
        // GL selects its target format at allocation and needs no format registration step.
        try report(adapter: adapter, initialization: initialized - start, registration: .zero, total: end - start)
    }
    #endif

    private static func report(adapter: DisplayGpuAdapter, initialization: Duration,
                               registration: Duration, total: Duration) throws {
        func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) * 1e-15
        }
        adapter.reportIfRequested()
        let metrics: [String: Any] = [
            "adapter": adapter.device,
            "backend": adapter.backend.rawValue,
            "new": milliseconds(initialization),
            "add_format": milliseconds(registration),
            "first_frame": milliseconds(total - initialization - registration),
            "total": milliseconds(total)
        ]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    enum FxGlowError: Error {
        case emptyOutput
        case noOffscreenContext
        case unavailableBackend(GpuBackend)
    }
}
