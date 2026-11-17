import Foundation
import Testing
@testable import Rune

#if canImport(Metal)
import Metal

@Suite("PipelineBreakers, GpuEvents, GpuLoss & Warmup Parity", .serialized)
struct BreakerAndWarmTests {
    private func solidRect(_ bounds: SIMD4<Float>, fill: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)) -> RenderInstance {
        RenderInstance(
            rect: bounds,
            radii: .zero,
            fill: fill,
            border: .zero,
            params: SIMD4<Float>(0, KIND_RECT, 0, 1),
            uv: .zero,
            clip: NO_CLIP,
            fade: .zero
        )
    }

    private func layerGroup(
        bounds: SIMD4<Float> = SIMD4<Float>(4, 4, 24, 8),
        spec: LayerSpec
    ) -> [RenderInstance] {
        [
            .beginLayer(bounds: bounds, clip: NO_CLIP, spec: spec),
            solidRect(bounds),
            .endLayer(),
        ]
    }

    /// Renders `instances` into an offscreen `.bgra8Unorm_srgb` target and returns raw premultiplied RGBA bytes
    /// (matching `Offscreen::read` in `breaker_tests.rs`).
    private func drawRawSRGB(
        renderer: MetalRenderer,
        instances: [RenderInstance],
        width: Int = 32,
        height: Int = 16
    ) throws -> [UInt8] {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let tex = renderer.device.makeTexture(descriptor: desc),
              let cmdBuf = renderer.commandQueue.makeCommandBuffer() else {
            throw MetalRenderer.RendererError.metalUnavailable
        }
        let frame = RenderFrame(
            width: width,
            height: height,
            srgbBlend: false,
            clearColor: .zero,
            instances: instances
        )
        renderer.drawRange(frame: frame, into: tex, commandBuffer: cmdBuf)
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        #expect(cmdBuf.error == nil)

        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        tex.getBytes(&bgra, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: bgra.count, by: 4) {
            rgba[i] = bgra[i + 2]
            rgba[i + 1] = bgra[i + 1]
            rgba[i + 2] = bgra[i]
            rgba[i + 3] = bgra[i + 3]
        }
        return rgba
    }

    // MARK: - Breaker State Machine (`breaker_tests.rs`)

    @Test("a_build_the_device_takes_works_and_one_it_refuses_is_dropped_for_good")
    func breakerBuildWorksAndRefusalDropsForGood() {
        let breakers = PipelineBreakers()
        #expect(breakers.health(for: .isolation) == .untried)
        #expect(breakers.isUsable(.isolation))

        // Successful check transitions untried -> working, and stays built.
        let res = breakers.checkingGpu(.isolation) { 42 }
        #expect(res == 42)
        #expect(breakers.health(for: .isolation) == .working)
        #expect(!breakers.isBroken(.isolation))
        #expect(!breakers.featuresNeedingCheck().contains(where: { $0.feature == .isolation }))

        // Refused check marks broken, drops, and never rebuilds until shaderChanged().
        enum ProbeErr: Error { case invalid }
        let refused: Int? = breakers.checkingGpu(.layerBlur) { throw ProbeErr.invalid }
        #expect(refused == nil)
        #expect(breakers.health(for: .layerBlur) == .broken)
        #expect(breakers.isBroken(.layerBlur))
        #expect(!breakers.isUsable(.layerBlur))
        #expect(breakers.checkingGpu(.layerBlur) { 99 } == nil)

        // Shader change resets every feature to untried so it gets one more check.
        breakers.shaderChanged()
        #expect(breakers.health(for: .layerBlur) == .untried)
        #expect(!breakers.isBroken(.layerBlur))
        let retry = breakers.checkingGpu(.layerBlur) { 7 }
        #expect(retry == 7)
        #expect(breakers.health(for: .layerBlur) == .working)
    }

    @Test("a_late_answer_settles_only_its_own_check")
    func lateAnswerSettlesOnlyOwnCheck() {
        let breakers = PipelineBreakers()
        let gen1 = breakers.beginCheck(.plusLighter)
        #expect(breakers.health(for: .plusLighter) == .checking(generation: gen1))
        #expect(breakers.isUsable(.plusLighter))

        // Shader update invalidates gen1 cleanly.
        breakers.shaderChanged()
        #expect(breakers.health(for: .plusLighter) == .untried)

        // Stale answer from gen1 changes nothing.
        #expect(!breakers.settle(.plusLighter, generation: gen1, working: false))
        #expect(breakers.health(for: .plusLighter) == .untried)

        // Current generation check settles accurately.
        let gen2 = breakers.beginCheck(.plusLighter)
        #expect(gen2 != gen1)
        #expect(breakers.settle(.plusLighter, generation: gen2, working: false))
        #expect(breakers.health(for: .plusLighter) == .broken)
        #expect(breakers.isBroken(.plusLighter))
    }

    // MARK: - Metal Fallback Under Refusal (`breaker_tests.rs`)

    @Test("a_refused_layer_pipeline_draws_the_group_in_its_parent")
    func refusedIsolationDrawsInParent() throws {
        let renderer = try MetalRenderer()
        renderer.pipelineBreakers.setForcedRefusalForTesting(.isolation, refused: true)
        let instances = layerGroup(spec: LayerSpec(opacity: 0.5))

        var center: [UInt8] = []
        for _ in 0..<3 {
            let out = try drawRawSRGB(renderer: renderer, instances: instances)
            let at = (8 * 32 + 16) * 4
            center = Array(out[at..<(at + 4)])
        }
        // Draws child rect directly at full opacity into parent instead of isolating with opacity 0.5
        #expect(center == [255, 255, 255, 255])
        #expect(renderer.layerStats().targets == 0)
        #expect(renderer.pipelineBreakers.isBroken(.isolation))
    }

    @Test("a_refused_plus_lighter_pipeline_draws_source_over")
    func refusedPlusLighterDrawsSourceOver() throws {
        let renderer = try MetalRenderer()
        renderer.pipelineBreakers.setForcedRefusalForTesting(.plusLighter, refused: true)
        let instances = layerGroup(spec: LayerSpec(opacity: 0.5, blend: .plusLighter))

        var center: [UInt8] = []
        for _ in 0..<3 {
            let out = try drawRawSRGB(renderer: renderer, instances: instances)
            let at = (8 * 32 + 16) * 4
            center = Array(out[at..<(at + 4)])
        }
        // Half-white isolated source-over into premul sRGB: want [188, 188, 188, 128]
        let want: [UInt8] = [188, 188, 188, 128]
        for (a, b) in zip(center, want) {
            #expect(abs(Int(a) - Int(b)) <= 1, "center=\(center) want=\(want)")
        }
        #expect(renderer.pipelineBreakers.isBroken(.plusLighter))
    }

    @Test("a_refused_blur_pipeline_draws_unblurred")
    func refusedLayerBlurDrawsUnblurred() throws {
        let renderer = try MetalRenderer()
        renderer.pipelineBreakers.setForcedRefusalForTesting(.layerBlur, refused: true)
        let instances = layerGroup(spec: LayerSpec(blur: 4.0))

        var center: [UInt8] = []
        for _ in 0..<3 {
            let out = try drawRawSRGB(renderer: renderer, instances: instances)
            let at = (8 * 32 + 16) * 4
            center = Array(out[at..<(at + 4)])
        }
        #expect(center == [255, 255, 255, 255])
        #expect(renderer.pipelineBreakers.isBroken(.layerBlur))
    }

    @Test("Real Metal pipeline build failures trip PipelineBreakers to broken and fall back")
    func realPipelineBuildRefusalTripsBreakerAndFallsBack() throws {
        do {
            let renderer = try MetalRenderer()
            renderer.pipelineBreakers.setForcedBuildFailureForTesting(.isolation, failed: true)
            let out = try drawRawSRGB(renderer: renderer, instances: layerGroup(spec: LayerSpec(opacity: 0.5)))
            let at = (8 * 32 + 16) * 4
            #expect(Array(out[at..<(at + 4)]) == [255, 255, 255, 255])
            #expect(renderer.pipelineBreakers.isBroken(.isolation))
        }
        do {
            let renderer = try MetalRenderer()
            renderer.pipelineBreakers.setForcedBuildFailureForTesting(.plusLighter, failed: true)
            let out = try drawRawSRGB(renderer: renderer, instances: layerGroup(spec: LayerSpec(opacity: 0.5, blend: .plusLighter)))
            let at = (8 * 32 + 16) * 4
            let center = Array(out[at..<(at + 4)])
            let want: [UInt8] = [188, 188, 188, 128]
            for (a, b) in zip(center, want) {
                #expect(abs(Int(a) - Int(b)) <= 1, "center=\(center) want=\(want)")
            }
            #expect(renderer.pipelineBreakers.isBroken(.plusLighter))
        }
        do {
            let renderer = try MetalRenderer()
            renderer.pipelineBreakers.setForcedBuildFailureForTesting(.layerBlur, failed: true)
            let out = try drawRawSRGB(renderer: renderer, instances: layerGroup(spec: LayerSpec(blur: 4.0)))
            let at = (8 * 32 + 16) * 4
            #expect(Array(out[at..<(at + 4)]) == [255, 255, 255, 255])
            #expect(renderer.pipelineBreakers.isBroken(.layerBlur))
        }
    }

    // MARK: - GpuEvents (`gpu_events.rs`)

    @Test("the_first_present_after_a_device_starts_reports_drew")
    func gpuEventsReportsOneDrewPerStarting() {
        GpuEvents.resetForTesting()
        defer { GpuEvents.resetForTesting() }

        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var events: [GpuEvent] = []
            func append(_ e: GpuEvent) {
                lock.lock()
                events.append(e)
                lock.unlock()
            }
        }
        let collector = Collector()
        let token = onGpu { collector.append($0) }
        defer { GpuEvents.removeListener(token) }

        GpuEvents.presented()
        GpuEvents.starting()
        GpuEvents.presented()
        GpuEvents.presented()
        GpuEvents.starting()
        GpuEvents.presented()

        #expect(collector.events == [.starting, .drew, .starting, .drew])
    }

    // MARK: - GpuLoss (`gpu_loss.rs`)

    @Test("GpuDeviceTracker bounds printed errors at 16 and records command buffer loss")
    func gpuLossBoundsErrors() {
        #expect(GpuLossConstants.printedLimit == 16)
        let tracker = GpuDeviceTracker()
        #expect(!tracker.isLost)
        #expect(!tracker.isMuted)

        for k in 0..<20 {
            let printed = tracker.recordUncapturedError(kind: "test", message: "err \(k)", marksLost: false)
            #expect(printed == (k < 16))
        }
        #expect(tracker.uncapturedErrorCount == 20)
        #expect(tracker.printedErrorCount == 16)
        #expect(tracker.isMuted)
        #expect(tracker.lastErrorDescription == "err 19")

        tracker.markLost(reason: "driver reset")
        #expect(tracker.isLost)
        #expect(tracker.lossReason == "driver reset")
    }

    // MARK: - Warmup / Prewarm (`warm_tests.rs` + `prewarm.rs` + `warmup.rs`)

    @Test("a_parked_device_that_died_is_not_handed_to_the_next_surface")
    func parkedLostDeviceIsNotHandedOut() throws {
        let renderer = try MetalRenderer()
        let coord = WarmGpuCoordinator()
        coord.resetForTesting()

        let now = Date()
        let tracker = GpuDeviceTracker(device: renderer.device)
        #expect(!tracker.isLost)
        tracker.markLost(reason: "simulated standby reset")
        #expect(tracker.isLost)

        let handle = WarmedGpuHandle(
            device: renderer.device,
            commandQueue: renderer.commandQueue,
            tracker: tracker,
            pixelFormat: .bgra8Unorm_srgb,
            warmedAt: now
        )
        #expect(!handle.isAlive)

        coord.parkGpu(handle, at: now)
        #expect(coord.surfaceGpu(at: now.addingTimeInterval(1.0)) == nil)
    }

    @Test("WarmGpuCoordinator warms synchronously, surfaces alive handle within TTL, and sweeps expired handles")
    func warmGpuCoordinatorLifecycleAndPrewarmSlot() async throws {
        func warmHandle(
            _ phase: String,
            sourceLocation: SourceLocation = #_sourceLocation,
            _ start: (@escaping @Sendable (WarmedGpuHandle?) -> Void) -> Void
        ) async throws -> WarmedGpuHandle {
            let (handles, completion) = AsyncStream<WarmedGpuHandle>.makeStream()
            let timeout = Task {
                try await Task.sleep(for: .seconds(30))
                completion.finish()
            }
            defer { timeout.cancel() }
            start { handle in
                if let handle { completion.yield(handle) }
                completion.finish()
            }
            var iterator = handles.makeAsyncIterator()
            return try #require(await iterator.next(), "Missing handle from \(phase)", sourceLocation: sourceLocation)
        }

        #expect(GpuWarmPolicy.lingerDuration == 30.0)
        #expect(GpuWarmPolicy.parkedDuration == 300.0)

        let coord = WarmGpuCoordinator()
        coord.resetForTesting()

        let base = Date(timeIntervalSince1970: 1_000)
        let slot = PrewarmSlot()
        #expect(slot.state == .idle)

        defer {
            slot.discard()
            coord.resetForTesting()
        }

        let handle = try await warmHandle("synchronous warm-up") { finish in
            Thread.detachNewThread {
                finish(WarmGpuCoordinator.warmSynchronously(pixelFormat: .bgra8Unorm_srgb))
            }
        }
        #expect(handle.isAlive)
        #expect(handle.librariesWarmed >= 1)
        coord.parkGpu(handle, at: base)

        let retrieved = try #require(coord.surfaceGpu(at: base.addingTimeInterval(60.0)))
        coord.parkGpu(retrieved, at: base)
        #expect(coord.surfaceGpu(at: base.addingTimeInterval(GpuWarmPolicy.parkedDuration + 1.0)) == nil)

        slot.start(pixelFormat: .bgra8Unorm_srgb)
        for _ in 0..<300 {
            if slot.waitUntilSettled(timeout: 0) != .running { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(slot.state == .done)
        #expect(slot.take() != nil)
        #expect(slot.state == .idle)

        // A caller that takes a running slot waits for its original warm-up.
        _ = try await warmHandle("taking a running prewarm slot") { finish in
            Thread.detachNewThread {
                slot.start(pixelFormat: .bgra8Unorm_srgb)
                finish(slot.take())
            }
        }
        #expect(slot.state == .idle)

        slot.restart(pixelFormat: .bgra8Unorm_srgb)
        slot.discard()
        #expect(slot.state == .idle)

        // WarmGpuCoordinator.warmGpuWith enforces lingerDuration (30s) rather than parkedDuration (300s)
        _ = try await warmHandle("coordinator completion") { finish in
            coord.warmGpuWith(pixelFormat: .bgra8Unorm_srgb, emitEvents: false, at: base, completion: finish)
        }
        // Expired after lingerDuration (30s) even though < parkedDuration (300s)
        #expect(coord.surfaceGpu(at: base.addingTimeInterval(GpuWarmPolicy.lingerDuration + 1.0)) == nil)
    }
}
#endif
