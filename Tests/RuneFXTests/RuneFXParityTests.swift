import Foundation
#if canImport(Metal)
import Metal
#endif
import Testing
@testable import RuneFX

@Suite("RuneFX Parity Tests")
struct RuneFXParityTests {
    @Test func catalogFillStylesAreOrderedUniqueAndComplete() {
        let styles = fillStyles()
        #expect(styles.count == 11)
        let ids = styles.map(\.id)
        #expect(Set(ids).count == 11)

        for info in styles {
            #expect(!info.name.isEmpty)
            #expect(!info.summary.isEmpty)
            #expect(!info.presets.isEmpty)
            #expect(fillStyle(info.id)?.id == info.id)

            for param in info.params {
                #expect(!param.id.isEmpty)
                #expect(!param.name.isEmpty)
            }
            for preset in info.presets {
                #expect(!preset.id.isEmpty)
                #expect(!preset.name.isEmpty)
                let built = preset.fill()
                #expect(built.info.id == info.id)
            }
        }
    }

    @Test func catalogParamGetSetAndValidation() {
        var params = FillParams(.liquidMetal(.gold()))
        #expect(params.info.id == "liquid_metal")
        #expect(params.get("speed") != nil)
        #expect(params.get("nonexistent") == nil)
        #expect(FillParams.commonParams.contains { $0.id == "border" })

        let okScale = params.set("scale", .number(2.25))
        #expect(okScale)
        #expect(params.get("scale") == .number(2.25))

        // Out-of-type or unknown key rejected
        let badType = params.set("scale", .toggle(true))
        let badKey = params.set("nonexistent", .number(1.0))
        #expect(!badType)
        #expect(!badKey)

        // Common speed param + count->number coercion round-trip
        let okSpeed = params.set("speed", .number(1.75))
        #expect(okSpeed)
        #expect(params.get("speed") == .number(1.75))
        let okScaleCount = params.set("scale", .count(48))
        #expect(okScaleCount)
        #expect(params.get("scale") == .number(48.0))
        let okBorderCount = params.set("border", .count(3))
        #expect(okBorderCount)
        #expect(params.get("border") == .number(3.0))
        let okIntensityCount = params.set("intensity", .count(1))
        #expect(okIntensityCount)
        #expect(params.get("intensity") == .number(1.0))

        // Choice param on dither
        var dither = FillParams(.dither(.handheld()))
        let okChoice = dither.set("pattern", .choice(1))
        #expect(okChoice)
        if case .choice(let v)? = dither.get("pattern") {
            #expect(v == 1)
        } else {
            Issue.record("Expected choice value for dither.pattern")
        }
        let badChoice = dither.set("pattern", .choice(999))
        #expect(!badChoice)
    }

    @Test func fireSimPlannerWarmupAndHitchCapping() {
        // Schedule warmup, steady stepping, and hitch capping
        let warmup = FireSim.schedule(prev: nil, target: 10.0, frozen: false)
        #expect(warmup.steps == 72)
        #expect(warmup.start.isReset)

        let steady = FireSim.schedule(prev: 10.0, target: 10.05, frozen: false)
        #expect(steady.steps >= 2 && steady.steps <= 4)
        #expect(!steady.start.isReset)

        let hitch = FireSim.schedule(prev: 10.05, target: 20.0, frozen: false)
        #expect(hitch.steps == FireSim.maxSteps)
        #expect(!hitch.start.isReset)

        let frozen = FireSim.schedule(prev: 20.0, target: 25.0, frozen: true)
        #expect(frozen.steps == 0)

        let sim = FireSim()
        let card = FxShape.rounded(x: 20, y: 20, w: 120, h: 80, radius: 12)
        let params = FireParams()
        let domain = FxRect(x: 20, y: 20, w: 120, h: 80)

        sim.beginFrame()
        let layer0 = Fx.fire(params).on(card).at(10.0)
        let r0 = sim.plan(layer: layer0, params: params, domain: domain)
        #expect(r0.gridIndex == 0)
        #expect(r0.extent.x >= 120 && r0.extent.y >= 80)
        #expect(sim.gridCount == 1)
        #expect(sim.pending)

        sim.stepCPU()
        #expect(!sim.pending)
    }

    #if canImport(Metal)
    @Test func maskPyramidMipLevelsAndMetalBuild() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pyramid = try MaskPyramid(device: device, width: 64, height: 32)
        #expect(pyramid.size == SIMD2<UInt32>(64, 32))
        #expect(pyramid.levels.count >= 6)
        #expect(pyramid.mips == pyramid.levels.count)
        #expect(pyramid.level(0) != nil)
        #expect(pyramid.level(pyramid.levels.count) == nil)
        #expect(MaskPyramid.pixelFormat == .rgba16Float)

        let renderer = try FxRenderer(device: device)
        let queue = try #require(device.makeCommandQueue())
        let cmd = try #require(queue.makeCommandBuffer())
        try renderer.buildMips(commandBuffer: cmd, pyramid: pyramid)
        cmd.commit()
        cmd.waitUntilCompleted()
        #expect(cmd.status == .completed)
    }
    #endif

    @Test func coreFxTableCapsPingZapBurstPoseAndNoiseParity() {
        let card = FxShape.rounded(x: 100, y: 100, w: 240, h: 140, radius: 18)

        // 1. sparkle_cap_and_tables_reach_64_without_regrowing
        let sp100 = SparkleParams(count: 100, life: 10.0, burst: 0.0)
        var sTable: [SIMD4<Float>] = []
        let (_, spCount) = RuneFXCPU.sparkles(sp100, rect: card.rect, t: 0.5, seed: 1, reduced: false, data: &sTable)
        #expect(spCount <= 64)
        #expect(sTable.count <= 128)

        // 2. layers_that_draw_nothing_never_keep_the_loop_awake (all 12 live/silent pairs)
        let glowP = GlowParams(breathe: 0.3)
        let pulseP = PulseParams()
        let electricP = ElectricParams()
        let fireP = FireParams()
        let shimmerP = ShimmerParams()
        let sparkleP = SparkleParams()
        let auroraP = AuroraParams()
        let grainP = GrainParams(fps: 24.0)
        var glowZeroInt = glowP; glowZeroInt.intensity = 0.0
        var glowZeroHeat = glowP; glowZeroHeat.heat = 0.0
        var pulseZero = pulseP; pulseZero.intensity = 0.0
        var electricZero = electricP; electricZero.intensity = 0.0
        var fireZero = fireP; fireZero.intensity = 0.0
        var shimmerZero = shimmerP; shimmerZero.intensity = 0.0; shimmerZero.baseAlpha = 0.0
        var sparkleZeroInt = sparkleP; sparkleZeroInt.intensity = 0.0
        var sparkleZeroCount = sparkleP; sparkleZeroCount.count = 0
        var auroraZero = auroraP; auroraZero.intensity = 0.0
        var grainZero = grainP; grainZero.amount = 0.0

        let pairs: [(Fx, Fx)] = [
            (.glow(glowP), .glow(glowZeroInt)),
            (.glow(glowP), .glow(glowZeroHeat)),
            (.pulse(pulseP), .pulse(pulseZero)),
            (.electric(electricP), .electric(electricZero)),
            (.fire(fireP), .fire(fireZero)),
            (.distort(.heatHaze(height: 40, scale: 14, speed: 2.2, amount: 1.6, wholeShape: false)),
             .distort(.heatHaze(height: 40, scale: 14, speed: 2.2, amount: 0.0, wholeShape: false))),
            (.distort(.chromaSplit(offset: .zero, glitch: 0.5, feather: 0.0)),
             .distort(.chromaSplit(offset: .zero, glitch: 0.0, feather: 0.0))),
            (.shimmer(shimmerP), .shimmer(shimmerZero)),
            (.sparkles(sparkleP), .sparkles(sparkleZeroInt)),
            (.sparkles(sparkleP), .sparkles(sparkleZeroCount)),
            (.aurora(auroraP), .aurora(auroraZero)),
            (.grain(grainP), .grain(grainZero)),
        ]
        for (liveFx, silentFx) in pairs {
            let live = liveFx.on(card).at(1.0)
            #expect(live.isAnimating && live.pack() != nil)
            #expect(!live.opacity(0.0).isAnimating)
            let silent = silentFx.on(card).at(1.0)
            #expect(!silent.isAnimating && silent.pack() == nil)
        }

        // 3. a_ping_ticks_until_its_shot_has_cooled
        let ping = PulseParams(style: .ping(from: .zero, dir: SIMD2<Float>(1, 0), travel: 200.0), t0: 1.0, duration: 0.5)
        let pingLayer = Fx.pulse(ping).on(card)
        #expect(pingLayer.at(1.25).isAnimating)
        #expect(pingLayer.at(1.25).pack() != nil)
        #expect(!pingLayer.at(1.0 + 0.5 + FxPackConstants.pingLife + 0.1).isAnimating)

        // 4. zaps_and_bursts_live_out_their_window_then_cull
        let zap = Fx.electric(ElectricParams(style: .arc(a: .zero, b: SIMD2<Float>(200, 40)), zap: 1.0)).on(card)
        #expect(zap.at(0.5).pack() == nil)
        #expect(zap.at(1.1).pack() != nil)
        #expect(zap.at(1.0 + ElectricParams.zapLife + 0.2).pack() == nil)

        let burst = Fx.sparkles(SparkleParams(burst: 1.0)).on(card)
        #expect(burst.at(0.5).pack() == nil)
        #expect(burst.at(1.2).pack() != nil)
        #expect(burst.at(1.0 + SparkleParams(burst: 1.0).burstLife + 0.5).pack() == nil)

        // 5. pose_inverse_round_trips (via MotionSamples inverse transforms)
        let pose = Pose(x: 25.0, y: -12.0, rotation: 0.35, scale: 1.2, opacity: 0.8)
        let mb = MotionBlurParams(mode: .shutter, frameDt: 1.0 / 60.0, maxSamples: 8, pxPerSample: 1.0)
        let samples = MotionSamples.fromTrack(mb, rest: card.rect, at: 0.0, scale: 1.0) { _ in pose }
        let m0 = samples.xforms[0]
        let m1 = samples.xforms[1]
        for corner in card.rect.corners {
            let moved = pose.apply(rest: card.rect, point: corner)
            let back = SIMD2<Float>(
                m0.x * moved.x + m0.z * moved.y + m1.x,
                m0.y * moved.x + m0.w * moved.y + m1.y
            )
            #expect(hypotf(back.x - corner.x, back.y - corner.y) < 1e-3)
        }

        // 6. cpu_noise_is_bounded_periodic_and_deterministic
        for i in 0..<256 {
            let x = Float(i) * 0.13
            let a = RuneFXCPU.gnoise(x, 1.5, per: 16, seed: 42)
            let b = RuneFXCPU.gnoise(x + 16.0, 1.5, per: 16, seed: 42)
            #expect(a.isFinite && abs(a) <= 1.2)
            #expect(abs(a - b) < 1e-4)
        }

        // 7. electric_tables_have_the_declared_layout & zero_amplitude_electricity_is_a_straight_finite_line
        let arcLayout = ElectricParams(style: .arc(a: .zero, b: SIMD2<Float>(300, 0)), forks: 1.0, strands: 2)
        var layoutData: [SIMD4<Float>] = []
        let xf = RuneFXCPU.electric(arcLayout, shape: card, t: 1.7, seed: 3, reduced: false, data: &layoutData)
        let nSeg = Int(xf.y)
        let nForks = Int(xf.z)
        let nStrands = Int(xf.w)
        #expect(layoutData.count == 2 + 2 * nStrands * nSeg / 4 + nForks * 6)
        #expect(abs(layoutData[2].x) < 1e-3)
        var reducedDiscard: [SIMD4<Float>] = []
        let reducedHdr = RuneFXCPU.electric(arcLayout, shape: card, t: 1.7, seed: 3, reduced: true, data: &reducedDiscard)
        #expect(reducedHdr.z == 0.0)

        for style in [ElectricStyle.arc(a: .zero, b: SIMD2<Float>(300, 0)), .border] {
            let zeroAmp = ElectricParams(style: style, amplitude: 0.0, forks: 1.0)
            for t: Float in [0.0, 0.4, 1.7] {
                var eData: [SIMD4<Float>] = []
                _ = RuneFXCPU.electric(zeroAmp, shape: card, t: t, seed: 3, reduced: false, data: &eData)
                for v in eData {
                    #expect(v.x.isFinite && v.y.isFinite && v.z.isFinite && v.w.isFinite)
                }
            }
        }
    }

    @Test func fillPresetsAndCatalogInvariantsParity() {
        let card = FxShape.rounded(x: 10, y: 10, w: 120, h: 80, radius: 12)
        let zeroShape = FxShape.rounded(x: 0, y: 0, w: 0, h: 40, radius: 0)

        // Every preset: idle culled, invisible !animating, moving deterministic, backdrop/source match FillInput
        for info in fillStyles() {
            #expect(info.presets[0].fill() == info.defaultFill())
            for preset in info.presets {
                let p = preset.fill()
                #expect(Fx.fill(p.intensity(0.0)).on(card).pack() == nil)
                #expect(Fx.fill(p).on(card).opacity(0.0).pack() == nil)
                #expect(Fx.fill(p).on(zeroShape).pack() == nil)
                #expect(!Fx.fill(p.intensity(0.0)).on(card).isAnimating)

                let l = Fx.fill(p).on(card).at(2.5).seed(11)
                #expect(l.pack()?.inst == l.pack()?.inst)
            }
        }

        // Plastic holds still
        for plastic in [PlasticParams.glossy(), .matte(), .dished()] {
            #expect(!Fx.fill(FillParams(.plastic(plastic))).on(card).isAnimating)
        }

        // Mesh points stay bounded around anchors within drift
        let mesh = MeshGradientParams.dusk()
        let pts = RuneFXCPU.meshPoints(mesh, time: 3.7, seed: 5)
        #expect(pts.count == mesh.points.count)
        for (moved, base) in zip(pts, mesh.points) {
            #expect(hypotf(moved.x - base.x, moved.y - base.y) <= mesh.drift * 1.5 + 1e-4)
        }

        // Stops keep order and cap at maxStops; empty input yields 1 stop
        let many = Stops.hex([0xff0000, 0x00ff00, 0x0000ff, 0xffff00, 0x00ffff, 0xff00ff, 0x111111, 0x222222])
        #expect(many.count == maxStops)
        #expect(!many.isEmpty)
        #expect(many.colors[1].hex() == 0x00ff00)
        #expect(Stops([]).count == 1)

        // Backdrop / source flags follow FillInput
        #expect(FillParams(.dither(DitherParams(input: .backdrop))).needsBackdrop)
        #expect(FillParams(.halftone(HalftoneParams(input: .backdrop))).needsBackdrop)
        #expect(FillParams(.flutedGlass(.reeded())).needsBackdrop)
        #expect(FillParams(.dither(DitherParams(input: .image))).needsSource)
        #expect(FillParams(.halftone(HalftoneParams(input: .image))).needsSource)

        // FillStyle builders & LiquidMetalParams.anchor builder
        #expect(FillStyle.plastic(.glossy()).border(4.0).border == 4.0)
        #expect(FillStyle.plastic(.glossy()).intensity(0.5).intensity == 0.5)
        #expect(LiquidMetalParams.chrome().anchor(.element).anchor == .element)

        // Catalog: preset values sit in declared range across ALL param kinds, set rejects non-finite & wrong kind, distinct values round-trip and change pack
        for info in fillStyles() {
            for pr in info.presets {
                let base = pr.fill()
                for param in info.params + FillParams.commonParams {
                    guard let cur = base.get(param.id) else {
                        Issue.record("Missing param \(param.id) on \(info.id)")
                        continue
                    }
                    let alt: FxValue
                    switch (param.kind, cur) {
                    case (.number(let minV, let maxV, _, _), .number(let x)):
                        #expect(x >= minV - 1e-5 && x <= maxV + 1e-5)
                        alt = .number(abs(x - maxV) > 1e-4 ? maxV : minV)
                    case (.count(let minC, let maxC), .count(let n)):
                        #expect(n >= minC && n <= maxC)
                        alt = .count(n != maxC ? maxC : minC)
                    case (.choice(let choices), .choice(let k)):
                        #expect(k >= 0 && k < choices.count)
                        alt = .choice((k + 1) % choices.count)
                    case (.colors(let minS, let maxS), .colors(let c)):
                        #expect(c.count >= minS && c.count <= maxS)
                        let hexes: [UInt32] = [0x112233, 0x445566, 0x778899, 0xaabbcc, 0xddeeff, 0x102030]
                        alt = .colors(Stops.hex(Array(hexes.prefix(maxS))))
                    case (.toggle, .toggle(let b)):
                        alt = .toggle(!b)
                    case (.color, _):
                        alt = .color(rgb(0x123456))
                    case (.point, _):
                        alt = .point(SIMD2<Float>(0.25, 0.75))
                    case (.points, _):
                        alt = .points(Array(repeating: SIMD2<Float>(0.1, 0.2), count: maxStops))
                    default:
                        Issue.record("\(info.id).\(param.id): kind/value mismatch")
                        continue
                    }

                    var g = base
                    let setCur = g.set(param.id, cur)
                    #expect(setCur)
                    #expect(g == base)
                    if case .point = param.kind { } else {
                        let setWrongKind = g.set(param.id, .point(SIMD2<Float>(9.0, 9.0)))
                        #expect(!setWrongKind)
                    }
                    let setNan = g.set(param.id, .number(.nan))
                    let setInf = g.set(param.id, .number(.infinity))
                    #expect(!setNan)
                    #expect(!setInf)

                    #expect(alt != cur)
                    let setAlt = g.set(param.id, alt)
                    #expect(setAlt)
                    #expect(g.get(param.id) == alt)
                    #expect(g != base)
                }
                #expect(base.get("nope") == nil)
            }
            var f = info.defaultFill()
            let before = Fx.fill(f).on(card).pack()!.inst
            if let param = info.params.first(where: { if case .number = $0.kind { return true }; return false }),
               case .number(let minV, let maxV, _, _) = param.kind,
               case .number(let curV)? = f.get(param.id) {
                let alt = abs(curV - maxV) > 1e-4 ? maxV : minV
                _ = f.set(param.id, .number(alt))
                let after = Fx.fill(f).on(card).pack()!.inst
                #expect(before != after)
            }
        }
    }
}
