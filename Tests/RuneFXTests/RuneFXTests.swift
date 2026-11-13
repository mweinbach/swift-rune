import Foundation
#if canImport(Metal)
import Metal
#endif
import RuneMotion
import Testing
@testable import RuneFX

@Suite("RuneFX Tests")
struct RuneFXTests {
    private let card = FxShape.rounded(x: 100, y: 100, w: 240, h: 140, radius: 18)

    @Test func gpuStructLayoutsMatchMetalAlignment() {
        #expect(MemoryLayout<FxGlobals>.stride == 16)
        #expect(MemoryLayout<FxGlobals>.alignment == 8)
        #expect(MemoryLayout<FxBackdropEncoding>.stride == 16)
        #expect(MemoryLayout<FxInstRaw>.stride == 256)
        #expect(MemoryLayout<FxInstRaw>.alignment == 16)
    }

    @Test func phaseSetSpeedHasNoPhaseJump() {
        var phase = Phase(speed: 1.0)
        let before = phase.at(3.5)
        phase.setSpeed(at: 3.5, speed: 2.75)
        let after = phase.at(3.5)
        #expect(abs(before - after) < 1e-6)
        #expect(abs(phase.at(4.5) - (before + 2.75)) < 1e-5)
    }

    @Test func heatAttackAndCoolEnvelope() {
        var heat = Heat(attack: 0.2, cool: 0.4)
        #expect(!heat.isActive(at: 0.0))
        heat.set(at: 1.0, on: true)
        #expect(heat.isActive(at: 1.05))
        #expect(heat.at(1.1) > 0.5)
        #expect(abs(heat.at(1.25) - 1.0) < 1e-5)
        #expect(!heat.isActive(at: 1.25))

        // Continuity on switch-off and 100-step monotonic decay + continuity on mid-cool switch-on
        let beforeOff = heat.at(2.0)
        heat.set(at: 2.0, on: false)
        #expect(abs(heat.at(2.0) - beforeOff) < 1e-5)
        var prev = beforeOff
        for i in 1...100 {
            let cur = heat.at(2.0 + Float(i) * 0.01)
            #expect(cur <= prev + 1e-6)
            prev = cur
        }
        #expect(heat.isActive(at: 2.1))
        #expect(heat.at(2.4) < 0.5)
        #expect(!heat.isActive(at: 10.0))

        var midHeat = Heat(attack: 0.2, cool: 0.4)
        midHeat.set(at: 0.0, on: true)
        midHeat.set(at: 0.5, on: false)
        let mid = midHeat.at(0.65)
        midHeat.set(at: 0.65, on: true)
        #expect(abs(midHeat.at(0.65) - mid) < 1e-5)
    }

    @Test func oneShotsPoolAndRetireSmoothly() {
        var shots = OneShots<Int>(cap: 2)
        shots.trigger(at: 0.0, data: 1)
        shots.trigger(at: 0.1, data: 2)
        shots.trigger(at: 0.2, data: 3)
        let live = shots.live(at: 0.25, life: 1.0)
        #expect(live.count == 3)
        #expect(live[0].opacity < 1.0 && live[0].opacity > 0.0)
        #expect(live[1].opacity == 1.0)
        #expect(live[2].opacity == 1.0)

        shots.prune(at: 2.0, life: 1.0)
        #expect(!shots.isAnimating(at: 2.0, life: 1.0))
    }

    @Test func idleAndFinishedLayersAreCulled() {
        let zeroGlow = Fx.glow(GlowParams(intensity: 0.0)).on(card)
        #expect(zeroGlow.isSilent)
        #expect(zeroGlow.pack() == nil)

        let zeroHeatGlow = Fx.glow(GlowParams(intensity: 1.0, heat: 0.0)).on(card)
        #expect(zeroHeatGlow.isSilent)
        #expect(zeroHeatGlow.pack() == nil)

        let ripple = Fx.pulse(PulseParams(style: .ripple(at: SIMD2<Float>(220, 170)), t0: 1.0, duration: 0.5)).on(card)
        #expect(ripple.at(0.5).pack() == nil)
        #expect(ripple.at(1.2).isAnimating && ripple.at(1.2).pack() != nil)
        #expect(!ripple.at(1.6).isAnimating && ripple.at(1.6).pack() == nil)

        let zeroOpacity = Fx.glow(GlowParams()).on(card).opacity(0.0)
        #expect(zeroOpacity.isSilent)
        #expect(zeroOpacity.pack() == nil)
        let partialOpacity = Fx.glow(GlowParams()).on(card).opacity(0.4).pack()
        #expect(partialOpacity?.inst.shape.z == 0.4)

        let zeroSize = Fx.fill(FillParams(.liquidMetal(.gold()))).on(.rounded(x: 0, y: 0, w: 0, h: 40, radius: 0))
        #expect(zeroSize.pack() == nil)

        let expiredShockwave = Fx.distort(.shockwave(at: SIMD2<Float>(10, 10), t0: 0.0)).on(card).at(2.0)
        #expect(expiredShockwave.pack() == nil)
    }

    @Test func reducedMotionHoldsSingleDeterministicPose() {
        let fills: [FillStyle] = [
            .liquidMetal(.chrome()),
            .meshGradient(.dusk()),
            .dither(.handheld()),
            .grainGradient(.ember()),
            .flutedGlass(.frosted()),
            .metaballs(.lava()),
            .swirl(.ink()),
            .voronoi(.cells()),
            .waves(.sea()),
            .halftone(.print()),
            .plastic(.glossy()),
        ]
        for style in fills {
            let layer = Fx.fill(FillParams(style)).on(card).seed(7).reduced(true)
            #expect(!layer.isAnimating)
            let p0 = layer.at(0.5).pack()!
            let p1 = layer.at(9.5).pack()!
            #expect(p0.inst == p1.inst)
        }
    }

    @Test func foldTPreservesPrecisionAtLargeTimes() {
        #expect(RuneFXCPU.foldT(0.0) == 0.0)
        #expect(RuneFXCPU.foldT(512.0) == 512.0)
        let a = RuneFXCPU.foldT(1e5)
        let b = RuneFXCPU.foldT(1e5 + 1.0 / 60.0)
        #expect(a >= 0.0 && a <= 512.0)
        #expect(abs(b - a) > 1e-3 && abs(b - a) < 0.05)
    }

    @Test func motionSamplesIntegrateWithRuneMotion() {
        let params = MotionBlurParams(mode: .shutter, shutterAngle: 180.0, frameDt: 1.0 / 60.0, maxSamples: 32, pxPerSample: 1.5)
        let resting = MotionSamples.fromMotion(params, rest: card.rect, at: 1.0, scale: 2.0) { _ in
            Transform2D.identity
        }
        #expect(!resting.isMoving)
        #expect(resting.count == 1)

        let slow = MotionSamples.fromMotion(params, rest: card.rect, at: 1.0, scale: 2.0) { t in
            Transform2D(tx: t * 180.0, ty: 0, sx: 1, sy: 1, rot: 0)
        }
        let fast = MotionSamples.fromMotion(params, rest: card.rect, at: 1.0, scale: 2.0) { t in
            Transform2D(tx: t * 600.0, ty: 0, sx: 1, sy: 1, rot: t * 0.5)
        }
        #expect(fast.isMoving)
        #expect(fast.count > slow.count)
        #expect(fast.bounds.w > card.rect.w)
        let weightSum = (0..<Int(fast.count)).reduce(Float(0)) { $0 + fast.xforms[$1 * 2 + 1].z }
        #expect(abs(weightSum - 1.0) < 1e-4)
    }

    @Test func blueNoiseAndOklabProperties() {
        let tile = RuneFXCPU.blueNoiseTile
        #expect(tile.count * 4 == RuneFXCPU.blueN * RuneFXCPU.blueN)
        let flat = tile.flatMap { [$0.x, $0.y, $0.z, $0.w] }.sorted()
        for (idx, val) in flat.enumerated() {
            #expect(abs(val - (Float(idx) + 0.5) / Float(flat.count)) < 1e-5)
        }

        let whiteLab = oklab(Rgb(1.0, 1.0, 1.0))
        #expect(abs(whiteLab.x - 1.0) < 1e-3)
        #expect(abs(whiteLab.y) < 1e-3)
        #expect(abs(whiteLab.z) < 1e-3)
    }

    @Test func renderPassGraphBuildsPassesAndCullsOffscreen() {
        let offscreen = FxShape.rounded(x: 5000, y: 5000, w: 100, h: 100, radius: 10)
        let layers = [
            Fx.glow(GlowParams()).on(card),
            Fx.lens(LensParams(frost: 0.5)).on(card),
            Fx.glow(GlowParams()).on(offscreen),
            Fx.glow(GlowParams(intensity: 0.0)).on(card),
        ]
        let graph = FxRenderPassGraph.build(viewport: SIMD2<UInt32>(1280, 720), scale: 2.0, layers: layers)
        #expect(graph.stats.drawn == 2)
        #expect(graph.stats.culledOffscreen == 1)
        #expect(graph.stats.culledIdle == 1)
        #expect(graph.stats.needsBackdrop)
        #expect(graph.passes.count == 3)
    }

    #if canImport(Metal)
    @Test func metalShadersCompileOnHostDevice() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = try FxRenderer()
        try renderer.warmAll()
        #expect(renderer.device.name.isEmpty == false)
    }
    #endif
}
