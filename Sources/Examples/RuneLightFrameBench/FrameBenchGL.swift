#if canImport(CRuneGL) && canImport(CRuneOffscreenGL)
import CRuneGL
import Foundation
import Rune
import RuneFX
import RuneLight
import RuneRef

private struct StageSamples {
    var host: [Double] = []
    var gpu: [Double] = []

    mutating func append(_ hostMicroseconds: Double, _ gpuMicroseconds: Double?) {
        host.append(hostMicroseconds)
        if let gpuMicroseconds { gpu.append(gpuMicroseconds) }
    }

    func report(_ name: String) {
        let cpuMedian = host.sorted()[host.count / 2]
        let prefix = name + String(format: "  %8.1f us CPU", cpuMedian)
        guard !gpu.isEmpty else {
            print(prefix + "  GPU timing unavailable")
            return
        }
        print(prefix + String(format: "  %8.1f us GPU", gpu.sorted()[gpu.count / 2]))
    }
}

extension RuneLightFrameBenchApp {
    static func runGL(fast: Bool, snapPath: String?) throws {
        let width = 2560, height = 1600
        let viewport = SIMD2(UInt32(width), UInt32(height))
        let context = try OffscreenGLContext()
        defer { context.close() }

        var error = [CChar](repeating: 0, count: 512)
        let capacity = error.count
        func driverError() -> NSError {
            let message = String(decoding: error.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            return NSError(domain: "RuneLightFrameBench", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let resolve = OffscreenGLContext.resolve
        guard let device = rune_gl_pass_open(resolve, &error, capacity) else { throw driverError() }
        defer { rune_gl_pass_close(device) }
        guard let finishAddress = resolve("glFinish") else {
            throw NSError(domain: "RuneLightFrameBench", code: 2, userInfo: [NSLocalizedDescriptionKey: "glFinish unavailable"])
        }
        let finish = unsafeBitCast(finishAddress, to: (@convention(c) () -> Void).self)
        func target(_ format: RuneGLPassFormat) throws -> RuneGLPassTarget {
            var result = RuneGLPassTarget()
            guard rune_gl_pass_target(device, format, Int32(width), Int32(height), 1, &result, &error, capacity) != 0
            else { throw driverError() }
            return result
        }
        var base = try target(RuneGLPassRGBA16F)
        defer { rune_gl_pass_delete_target(device, &base) }
        var text = try target(RuneGLPassRGBA16F)
        defer { rune_gl_pass_delete_target(device, &text) }
        var lit = try target(RuneGLPassRGBA8)
        defer { rune_gl_pass_delete_target(device, &lit) }
        var output = try target(RuneGLPassRGBA8)
        defer { rune_gl_pass_delete_target(device, &output) }
        rune_gl_pass_clear(device, base, 0, 0, 0, 0)
        rune_gl_pass_clear(device, text, 0, 0, 0, 0)
        finish()

        let small = makePrims(16), big = makePrims(300)
        let clock = ContinuousClock()
        func measure(_ work: () throws -> Void) rethrows -> Double {
            let start = clock.now
            try work()
            let duration = (clock.now - start).components
            return Double(duration.seconds) * 1e6 + Double(duration.attoseconds) * 1e-12
        }
        func drawLight(_ renderer: LightGLRenderer, _ prims: [Prim], _ gi: GIParams?) throws {
            try renderer.render(scene: scene(prims, gi: gi), width: width, height: height,
                                baseTexture: base.texture, textTexture: text.texture, framebuffer: lit.framebuffer)
        }

        let adapter = String(cString: rune_gl_pass_adapter(device))
        print("GL command submission and GPU execution (2560x1600), \(adapter)")
        let timer = rune_gl_timer_open(resolve)
        var sampling = false
        defer {
            if sampling { rune_gl_timer_cancel(timer) }
            rune_gl_timer_close(timer)
        }
        func beginSample() {
            sampling = timer.map { rune_gl_timer_begin($0) != 0 } ?? false
        }
        func mark(_ label: UInt32) {
            if sampling, rune_gl_timer_mark(timer, label) == 0 {
                rune_gl_timer_cancel(timer)
                sampling = false
            }
        }
        func finishFrame(stages: Int) -> [UInt32: Double] {
            if sampling { rune_gl_timer_end(timer) }
            // Both backends drain the frame outside the CPU submission measurements.
            finish()
            guard sampling else { return [:] }
            sampling = false
            var samples = [RuneGLTimerInterval](repeating: RuneGLTimerInterval(), count: stages)
            let count = rune_gl_timer_read(timer, 1, &samples, Int32(stages))
            guard count > 0 else { return [:] }
            var microseconds: [UInt32: Double] = [:]
            for sample in samples.prefix(Int(count)) {
                microseconds[sample.label] = sample.milliseconds * 1000
            }
            return microseconds
        }
        var growth = StageSamples()
        for _ in 0..<(fast ? 3 : 30) {
            let renderer = try LightGLRenderer(resolve: resolve)
            defer { renderer.close() }
            try drawLight(renderer, small, nil)
            finish()
            beginSample()
            let elapsed = try measure { try drawLight(renderer, big, nil) }
            mark(0)
            growth.append(elapsed, finishFrame(stages: 1)[0])
        }
        growth.report("grow past 256 prims")

        let light = try LightGLRenderer(resolve: resolve)
        defer { light.close() }
        let glass = try GlassGLRenderer(resolve: resolve)
        defer { glass.close() }
        try drawLight(light, small, nil)
        finish()
        print("gi off textures      \(light.allocatedGITextureCount)")
        func drawGlass(to framebuffer: UInt32?) throws {
            try glass.render(glass: panes, width: width, height: height, backdrop: lit.texture,
                             fluence: light.fluenceTexture, framebuffer: framebuffer)
        }

        let warmup = fast ? 4 : 20, count = fast ? 16 : 320
        for gi in [Optional<GIParams>.none, GIParams()] {
            var lightTimes = StageSamples(), glassTimes = StageSamples()
            for frame in 0..<count {
                beginSample()
                let lightTime = try measure { try drawLight(light, small, gi) }
                mark(0)
                let glassTime = try measure { try drawGlass(to: output.framebuffer) }
                mark(1)
                let execution = finishFrame(stages: 2)
                if frame >= warmup {
                    lightTimes.append(lightTime, execution[0])
                    glassTimes.append(glassTime, execution[1])
                }
            }
            let state = gi == nil ? "gi off" : "gi on"
            lightTimes.report("light steady " + state)
            glassTimes.report("glass steady (" + state + ")")
        }

        if let snapPath {
            let captured = try context.withFramebuffer(width: width, height: height) { try drawGlass(to: nil) }
            let url = URL(fileURLWithPath: snapPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try captured.writePNG(to: url)
        }

        let fx = try FxGLRenderer(resolve: resolve)
        defer { fx.close() }
        let layers = effects()
        var fxTimes = StageSamples()
        for frame in 0..<count {
            beginSample()
            let elapsed = try measure {
                let graph = fx.prepare(viewport: viewport, layers: layers, hasBackdrop: true)
                try fx.encode(graph: graph, viewport: viewport, framebuffer: lit.framebuffer, backdrop: base.texture)
            }
            mark(0)
            let execution = finishFrame(stages: 1)
            if frame >= warmup { fxTimes.append(elapsed, execution[0]) }
        }
        fxTimes.report("fx steady 16 layers")
    }
}
#endif
