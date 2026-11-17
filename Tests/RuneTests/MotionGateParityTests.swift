import Testing
import Foundation
@testable import Rune
import RuneMotion

@Suite("GPU Health & Backend Policy Parity Tests")
struct GpuHealthAndBackendParityTests {
    @Test("GpuErrorLog reports first, deduplicates repeats up to 4 different messages, then quiets")
    func gpuErrorLogDeduplicationAndQuiet() {
        var log = GpuErrorLog()
        #expect(log.note("device lost A") == .first)
        #expect(log.note("device lost A") == .quiet)
        #expect(log.note("swapchain stale B") == .new)
        #expect(log.note("command buffer timeout C") == .new)
        #expect(log.note("fence error D") == .new)
        #expect(log.note("fifth error E") == .mute)
        #expect(log.note("extra noise F") == .quiet)
    }

    @Test("GpuBackendPolicy prioritizes env over app choice over platform default and formats description")
    func gpuBackendPolicyResolution() {
        #expect(GpuBackendPolicy.resolve(env: "metal", chosen: .webGpu) == .metal)
        #expect(GpuBackendPolicy.resolve(env: "wgpu", chosen: .metal) == .webGpu)
        #expect(GpuBackendPolicy.resolve(env: nil, chosen: .webGpu) == .webGpu)
        #expect(GpuBackendPolicy.resolve(env: nil, chosen: nil) == GpuBackendPolicy.defaultBackend)
        #expect(GpuBackendPolicy.resolve(env: "auto", chosen: .vulkan) == GpuBackendPolicy.defaultBackend)
        #expect(GpuBackendPolicy.resolve(env: "gl", chosen: .metal) == .gl)

        #expect(GpuBackendPolicy.defaulted(env: nil, chosen: nil) == true)
        #expect(GpuBackendPolicy.defaulted(env: "metal", chosen: nil) == false)
        #expect(GpuBackendPolicy.defaulted(env: nil, chosen: .metal) == false)

        let desc = GpuBackendPolicy.describe(deviceName: "Apple M3", native: true, env: "metal", chosen: nil)
        #expect(desc.contains("Apple M3"))
        #expect(desc.contains("RUNE_GPU_BACKEND=metal"))
    }
}

@Suite("MotionGate Parity Tests")
struct MotionGateParityTests {
    @Test("Smooth animated transition settles cleanly with zero MotionGate findings")
    func smoothMotionProducesZeroFindings() {
        struct S { var shifted = false }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            view: { s, _ in
                col()
                    .size(200, 100)
                    .child(
                        el()
                            .key("box")
                            .size(40, 40)
                            .bg(Color(r: 0.2, g: 0.5, b: 1.0, a: 1))
                            .offset(s.shifted ? 80 : 0, 0)
                            .motion(Spring(duration: 0.18, bounce: 0))
                    )
            }
        )
        let run = MotionGateRun(rt)
        run.idle(0.1)
        run.actUpdate("shift") { s, _ in s.shifted = true }
        let findings = run.playAndCheck(0.8)
        #expect(findings.isEmpty, "Unexpected findings: \(findings)")
    }

    @Test("Un-animated geometry teleport triggers jump unless exempted by MotionIntent.step; Spring.none/instantChanges exempt painted snaps")
    func jumpDetectionAndSpringNoneExemption() {
        struct S { var shifted = false; var warm = false }

        // 1. Un-animated jump without exemption -> triggers jump finding
        let rtJump = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            view: { s, _ in
                col()
                    .size(200, 100)
                    .child(
                        el()
                            .key("teleporter")
                            .size(40, 40)
                            .bg(.white)
                            .ml(s.shifted ? 80 : 0)
                    )
            }
        )
        let runJump = MotionGateRun(rtJump)
        runJump.stepN(6)
        runJump.actUpdate("teleport") { s, tx in
            s.shifted = true
            tx.instant()
        }
        let jumpFindings = runJump.playAndCheck(0.4)
        #expect(jumpFindings.contains { $0.kind == "jump" && $0.element.contains("teleporter") })

        // 2. MotionIntent.step exempts intentional step jump
        let rtIntent = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            view: { s, _ in
                col()
                    .size(200, 100)
                    .child(
                        el()
                            .key("teleporter")
                            .size(40, 40)
                            .bg(.white)
                            .ml(s.shifted ? 80 : 0)
                            .motionIntent(.step)
                    )
            }
        )
        let runIntent = MotionGateRun(rtIntent)
        runIntent.stepN(6)
        runIntent.actUpdate("teleport") { s, tx in
            s.shifted = true
            tx.instant()
        }
        let intentFindings = runIntent.playAndCheck(0.4)
        #expect(!intentFindings.contains { $0.kind == "jump" })

        // 3. Explicit Spring.none on own element and instantChanges(true) exempt painted snaps
        let rtNone = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            view: { s, _ in
                col()
                    .size(200, 100)
                    .child(
                        el()
                            .key("swatch")
                            .size(80, 60)
                            .bg(s.warm ? Color(r: 1, g: 0.5, b: 0, a: 1) : Color(r: 0, g: 0.4, b: 1, a: 1))
                            .motion(.none)
                    )
            }
        )
        let runNone = MotionGateRun(rtNone)
        runNone.stepN(6)
        runNone.update { s, _ in s.warm = true }
        let noneFindings = runNone.playAndCheck(0.4)
        #expect(!noneFindings.contains { $0.kind == "snap" })

        let rtInstant = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            view: { s, _ in
                col()
                    .size(200, 100)
                    .instantChanges(true)
                    .child(
                        el()
                            .key("swatch")
                            .size(80, 60)
                            .bg(s.warm ? Color(r: 1, g: 0.5, b: 0, a: 1) : Color(r: 0, g: 0.4, b: 1, a: 1))
                    )
            }
        )
        let runInstant = MotionGateRun(rtInstant)
        runInstant.stepN(6)
        runInstant.update { s, _ in s.warm = true }
        let instantFindings = runInstant.playAndCheck(0.4)
        #expect(!instantFindings.contains { $0.kind == "snap" })
    }

    @Test("Paint step without Tx.instant or Spring.none flags snap; Tx.instant allows crisp cut")
    func paintSnapDetectionAndTxInstant() {
        struct S { var lit = false }

        let rtSnap = Runtime<S>(
            state: S(),
            viewport: Vec2(120, 80),
            pixelScale: 1.0,
            view: { s, _ in
                col()
                    .size(120, 80)
                    .child(
                        el()
                            .key("card")
                            .size(80, 60)
                            .bg(s.lit ? Color(r: 1, g: 0, b: 0, a: 1) : Color(r: 0, g: 0, b: 1, a: 1))
                            .tokenMotion(.none)
                    )
            }
        )
        let runSnap = MotionGateRun(rtSnap)
        runSnap.stepN(6)
        // Update without recording input -> sudden unrequested color snap
        runSnap.update { s, _ in s.lit = true }
        let snapFindings = runSnap.playAndCheck(0.3)
        #expect(snapFindings.contains { $0.kind == "snap" && $0.element.contains("card") })

        // Same color cut marked tx.instant() produces no snap
        let rtClean = Runtime<S>(
            state: S(),
            viewport: Vec2(120, 80),
            pixelScale: 1.0,
            view: { s, _ in
                col()
                    .size(120, 80)
                    .child(
                        el()
                            .key("card")
                            .size(80, 60)
                            .bg(s.lit ? Color(r: 1, g: 0, b: 0, a: 1) : Color(r: 0, g: 0, b: 1, a: 1))
                            .tokenMotion(.none)
                    )
            }
        )
        let runClean = MotionGateRun(rtClean)
        runClean.stepN(6)
        runClean.update { s, tx in
            s.lit = true
            tx.instant()
        }
        let cleanFindings = runClean.playAndCheck(0.3)
        #expect(!cleanFindings.contains { $0.kind == "snap" })
    }

    @Test("Looping motion tracks continuous phase cleanly and MotionGateGate.report enforces allowlists")
    func loopingPhaseAndGateAllowlist() {
        struct S {}
        let rtLoop = Runtime<S>(
            state: S(),
            viewport: Vec2(100, 100),
            pixelScale: 1.0,
            view: { _, _ in
                col()
                    .size(100, 100)
                    .child(
                        el()
                            .key("pulse")
                            .size(40, 40)
                            .bg(.white)
                            .looping(LoopSpec.opacity(period: 1.0, low: 0.3, high: 1.0).mode(.pingPong))
                    )
            }
        )
        let run = MotionGateRun(rtLoop, hz: 60)
        run.play(0.8)
        let findings = run.finish()
        #expect(!findings.contains { $0.kind == "loop-jump" || $0.kind == "never-settles" })

        // Verify MotionGateGate.run & allowlist matching
        let cells = MotionGateGate.run([
            ("cell-jump", {
                struct J { var x = false }
                let rt = Runtime<J>(
                    state: J(),
                    viewport: Vec2(120, 60),
                    pixelScale: 1.0,
                    view: { s, _ in
                        col().size(120, 60).child(el().key("box").size(20, 20).bg(.white).ml(s.x ? 50 : 0))
                    }
                )
                let r = MotionGateRun(rt)
                r.stepN(6)
                r.actUpdate("move") { s, tx in
                    s.x = true
                    tx.instant()
                }
                r.play(0.3)
                return r.rec
            }),
        ])
        let strictReport = MotionGateGate.report(cells)
        #expect(strictReport.failing > 0)

        let waivedReport = MotionGateGate.report(
            cells,
            allow: [(kind: "jump", element: "box", cell: "cell-jump", why: "intentional step")]
        )
        #expect(waivedReport.failing == 0)
        #expect(waivedReport.allowed >= 1)
    }
}
