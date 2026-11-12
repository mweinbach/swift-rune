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

        // Common speed param round-trip
        let okSpeed = params.set("speed", .number(1.75))
        #expect(okSpeed)
        #expect(params.get("speed") == .number(1.75))

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
}
