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
        var shots = OneShots<Int>(cap: 3)
        for k in 0..<3 {
            shots.trigger(at: Float(k) * 0.1, data: k)
        }
        let live = shots.live(at: 0.25, life: 1.0)
        #expect(live.map { $0.shot.data } == [0, 1, 2])
        #expect(live.map { $0.opacity } == [1.0, 1.0, 1.0])

        // Retiring the oldest shot fades smoothly over fadeDuration and keeps remaining at 1.0.
        shots.trigger(at: 0.3, data: 3)
        func opacityOf(_ t: Float) -> Float {
            shots.live(at: t, life: 1.0).first(where: { $0.shot.data == 0 })?.opacity ?? 0.0
        }
        #expect(opacityOf(0.3) == 1.0)
        var prev: Float = 1.0
        for i in 1...20 {
            let v = opacityOf(0.3 + Float(i) * OneShots<Int>.fadeDuration / 20.0)
            #expect(v <= prev && prev - v < 0.2)
            prev = v
        }
        #expect(prev == 0.0)
        #expect(shots.live(at: 0.31, life: 1.0).filter { $0.opacity == 1.0 }.count == 3)

        // A storm of 100 triggers stays bounded at <= cap * 2 and issues distinct seeds.
        for k in 0..<100 {
            shots.trigger(at: 0.4 + Float(k) * 0.001, data: k)
        }
        let storm = shots.live(at: 0.5, life: 1.0)
        #expect(storm.count <= 6)
        let seeds = Set(storm.map(\.shot.seed))
        #expect(seeds.count > 1)

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
        for info in fillStyles() {
            for preset in info.presets {
                let layer = Fx.fill(preset.fill()).on(card).seed(3).reduced(true)
                #expect(!layer.isAnimating, "\(info.id) \(preset.id)")
                var p0 = layer.at(0.5).pack()!
                var p1 = layer.at(7.25).pack()!
                var t0: [SIMD4<Float>] = []
                var t1: [SIMD4<Float>] = []
                layer.at(0.5).fillTables(into: &p0.inst, data: &t0)
                layer.at(7.25).fillTables(into: &p1.inst, data: &t1)
                #expect(p0.inst == p1.inst, "\(info.id) \(preset.id)")
                #expect(t0 == t1, "\(info.id) \(preset.id)")
            }
        }
    }

    @Test func foldTPreservesPrecisionAtLargeTimes() {
        #expect(RuneFXCPU.foldT(0.0) == 0.0)
        #expect(RuneFXCPU.foldT(1.2) == 1.2)
        #expect(RuneFXCPU.foldT(512.0) == 512.0)
        for t: Float in [1e4, 1e5, -1e5] {
            let a = RuneFXCPU.foldT(t)
            let b = RuneFXCPU.foldT(t + 1.0 / 60.0)
            #expect(a >= 0.0 && a <= 512.0 && b >= 0.0 && b <= 512.0)
            #expect(abs(b - a) > 1e-3 && abs(b - a) < 0.05)
        }
        for info in fillStyles() {
            for preset in info.presets {
                let p = preset.fill()
                let layer = Fx.fill(p).on(card).seed(7)
                var i0 = layer.at(1e5).pack()!.inst
                var i1 = layer.at(1e5 + 0.25).pack()!.inst
                var d0: [SIMD4<Float>] = []
                var d1: [SIMD4<Float>] = []
                layer.at(1e5).fillTables(into: &i0, data: &d0)
                layer.at(1e5 + 0.25).fillTables(into: &i1, data: &d1)
                #expect(i0.t.x >= 0.0 && i0.t.x <= 512.0, "\(info.id) \(preset.id)")
                #expect(d0.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }, "\(info.id) \(preset.id)")
                if p.animates {
                    #expect(i0.t.x != i1.t.x || d0 != d1, "\(info.id) \(preset.id) still moves at t = 1e5")
                }
            }
        }
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
        let n = RuneFXCPU.blueN
        func noiseAt(_ x: Int, _ y: Int) -> Float {
            let idx = (y % n) * n + (x % n)
            return tile[idx / 4][idx % 4]
        }
        var worst: Float = 0.0
        for y in 0..<n {
            for x in 0..<n {
                let mean = (noiseAt(x, y) + noiseAt(x + 1, y) + noiseAt(x, y + 1) + noiseAt(x + 1, y + 1)) / 4.0
                worst = max(worst, abs(mean - 0.5))
            }
        }
        #expect(worst < 0.36)

        let whiteLab = oklab(Rgb(1.0, 1.0, 1.0))
        #expect(abs(whiteLab.x - 1.0) < 1e-3)
        #expect(abs(whiteLab.y) < 1e-3)
        #expect(abs(whiteLab.z) < 1e-3)
        let greyLab = oklab(rgb(0x777777))
        #expect(abs(greyLab.y) < 1e-3)
        #expect(abs(greyLab.z) < 1e-3)
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
