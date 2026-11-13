import Foundation
import Testing
@testable import Rune
import RuneMotionBento
@testable import RuneSketch

@Suite("Motion Bento Chaos & Sketch Tests (Phase 1)", .serialized)
@MainActor
struct MotionBentoAndSmallTests {
    // MARK: - chaos/src/rng.rs

    @Test("motion-bento/chaos/rng::a_seed_names_one_sequence")
    func aSeedNamesOneSequence() {
        var ra = ChaosRng(seed: 7)
        let a = (0..<4).map { _ in ra.nextU64() }
        var rb = ChaosRng(seed: 7)
        let b = (0..<4).map { _ in rb.nextU64() }
        #expect(a == b)
        var r8 = ChaosRng(seed: 8)
        #expect(r8.nextU64() != a[0])
    }

    // MARK: - chaos/src/look.rs

    @Test("motion-bento/chaos/look::accent_is_rune_blue")
    func accentIsRuneBlue() {
        let (r, g, b, _) = ChaosColor.accent.srgb()
        #expect(b > r && b > g && r < 0.4)
    }

    @Test("motion-bento/chaos/look::spring_constants_match_swiftui")
    func springConstantsMatchSwiftUI() {
        let s = ChaosSpring(duration: 0.5, bounce: 0.0)
        let fourPi = 4.0 * Float.pi
        #expect(abs(s.stiffness() - fourPi * fourPi) < 1e-3)
        #expect(abs(s.damping() - 2.0 * fourPi) < 1e-3)
    }

    // MARK: - chaos/src/config.rs

    private func splitArgs(_ s: String) -> [String] {
        s.split(separator: " ").map(String.init)
    }

    @Test("motion-bento/chaos/config::takes_its_own_flags_and_keeps_the_rest")
    func takesItsOwnFlagsAndKeepsTheRest() throws {
        let (c, rest) = try ChaosConfig.parse(
            splitArgs("bento --seed 9 --snap a.png --intensity=2 --duration 4 --hud --naive --at 1")
        )
        #expect(c.seed == 9)
        #expect(c.naive)
        #expect(c.intensity == 2.0)
        #expect(c.duration == 4.0)
        #expect(c.hud)
        #expect(rest == splitArgs("bento --snap a.png --duration 4 --at 1"))
    }

    @Test("motion-bento/chaos/config::a_ramp_sets_the_duration_unless_given")
    func aRampSetsTheDurationUnlessGiven() throws {
        let (c, rest) = try ChaosConfig.parse(splitArgs("bento --ramp 16:64 --hold 2"))
        #expect(c.load?.levels == [16, 23, 32, 45, 64])
        #expect(c.duration == 10.6)
        #expect(rest == splitArgs("bento --duration 10.6"))

        let (c2, _) = try ChaosConfig.parse(splitArgs("bento --load 40 --duration 3"))
        #expect(c2.load == .fixed(40))
        #expect(c2.duration == 3.0)

        #expect(throws: ChaosError.self) {
            _ = try ChaosConfig.parse(splitArgs("bento --load 4 --ramp 1:2"))
        }
    }

    @Test("motion-bento/chaos/config::rejects_a_bad_number")
    func rejectsABadNumber() {
        #expect(throws: ChaosError.self) {
            _ = try ChaosConfig.parse(splitArgs("bento --seed x"))
        }
        #expect(throws: ChaosError.self) {
            _ = try ChaosConfig.parse(splitArgs("bento --intensity 0"))
        }
    }

    // MARK: - chaos/src/model.rs

    @Test("motion-bento/chaos/model::the_same_actions_give_the_same_state")
    func theSameActionsGiveTheSameState() {
        let actions: [ChaosAction] = [.fader(2), .puck, .queue, .feed, .orb, .energy]
        func run(seed: UInt64) -> ChaosModel {
            var m = ChaosModel(seed: seed)
            for a in actions + actions {
                m.apply(a)
            }
            return m
        }
        let m3a = run(seed: 3)
        let m3b = run(seed: 3)
        let m4 = run(seed: 4)
        #expect(m3a.faders == m3b.faders)
        #expect(m3a.puck == m3b.puck)
        #expect(m3a.queue == m3b.queue)
        #expect(m3a.feed == m3b.feed)
        #expect(m3a.orb == m3b.orb)
        #expect(m3a.energy == m3b.energy)
        #expect(m3a.kwhTenths == m3b.kwhTenths)
        #expect(m3a != m4)
    }

    @Test("motion-bento/chaos/model::lists_keep_their_length")
    func listsKeepTheirLength() {
        var m = ChaosModel(seed: 1)
        for _ in 0..<20 {
            m.apply(.queue)
            m.apply(.feed)
            m.apply(.visitors)
        }
        #expect(m.visits.count == ChaosConstants.visits)
        #expect(m.queue.count == ChaosConstants.queueLen)
        #expect(m.feed.count == ChaosConstants.feedLen)
        let ids = Set(m.queue.map(\.id) + m.feed.map(\.id))
        #expect(ids.count == ChaosConstants.queueLen + ChaosConstants.feedLen)
    }

    // MARK: - chaos/src/schedule.rs

    private func schedConfig(_ seed: UInt64, _ duration: Double, _ intensity: Double) -> ChaosConfig {
        ChaosConfig(seed: seed, duration: duration, intensity: intensity)
    }

    @Test("motion-bento/chaos/schedule::a_seed_names_one_schedule")
    func aSeedNamesOneSchedule() {
        #expect(ChaosSchedule.schedule(schedConfig(5, 10.0, 1.0)) == ChaosSchedule.schedule(schedConfig(5, 10.0, 1.0)))
        #expect(ChaosSchedule.schedule(schedConfig(5, 10.0, 1.0)) != ChaosSchedule.schedule(schedConfig(6, 10.0, 1.0)))
    }

    @Test("motion-bento/chaos/schedule::intensity_scales_the_rate_and_bursts_happen")
    func intensityScalesTheRateAndBurstsHappen() {
        let calm = ChaosSchedule.schedule(schedConfig(1, 20.0, 1.0))
        let busy = ChaosSchedule.schedule(schedConfig(1, 20.0, 2.0))
        #expect(Double(busy.count) > Double(calm.count) * 1.4)
        let tight = zip(calm, calm.dropFirst()).filter { $0.1.t - $0.0.t < 0.07 }.count
        #expect(tight >= 30)
        #expect(zip(calm, calm.dropFirst()).allSatisfy { $0.1.t > $0.0.t && $0.1.t - $0.0.t >= 0.03 - 1e-9 })
        #expect(calm.allSatisfy { $0.t >= ChaosSchedule.start && $0.t < 20.0 })
    }

    @Test("motion-bento/chaos/schedule::every_action_is_takeable")
    func everyActionIsTakeable() {
        var m = ChaosModel(seed: 2)
        for e in ChaosSchedule.schedule(schedConfig(2, 30.0, 3.0)) {
            switch e.action {
            case .scene(let i): #expect(Int(i) != m.scene)
            case .focus(let i): #expect(Int(i) != m.focus)
            case .chip(let i): #expect(Int(i) < m.chipsShown())
            default: break
            }
            m.apply(e.action)
        }
    }

    @Test("motion-bento/chaos/schedule::the_player_hands_out_each_action_once")
    func thePlayerHandsOutEachActionOnce() {
        let c = schedConfig(3, 6.0, 1.0)
        var p = ChaosPlayer(config: c)
        var seen = 0
        var t = 0.0
        while !p.isDone {
            t += 1.0 / 120.0
            seen += p.due(at: t).count
        }
        #expect(seen == ChaosSchedule.schedule(c).count)
        #expect(ChaosSchedule.scriptJSON(c).contains("\"key\": \""))
    }

    // MARK: - chaos/src/stress.rs

    @Test("motion-bento/chaos/stress::a_ramp_steps_by_root_two_and_ends_on_its_target")
    func aRampStepsByRootTwoAndEndsOnItsTarget() throws {
        let l = try ChaosLoad.parseRamp("16:256", hold: 2.5)
        #expect(l.levels == [16, 23, 32, 45, 64, 91, 128, 181, 256])
        #expect(l.at(0.0) == 16)
        #expect(l.at(ChaosSchedule.start + 2.5) == 23)
        #expect(l.at(1e6) == 256)
        #expect(l.duration == ChaosSchedule.start + 9.0 * 2.5)
        #expect(throws: ChaosError.self) {
            _ = try ChaosLoad.parseRamp("8", hold: 1.0)
        }
    }

    @Test("motion-bento/chaos/stress::the_wall_is_a_function_of_time_and_fits_its_area")
    func theWallIsAFunctionOfTimeAndFitsItsArea() {
        let (ax, ay, aw, ah) = ChaosStress.area()
        for n in [1, 16, 91, 512] {
            var a = ChaosWall(seed: 7)
            var b = ChaosWall(seed: 7)
            for t in [0.0, 1.3, 2.71, 6.05] {
                a.update(t: t, n: n)
            }
            b.update(t: 6.05, n: n)
            #expect(a.cells == b.cells)
            for c in a.cells {
                let x = c.rect[0], y = c.rect[1], w = c.rect[2], h = c.rect[3]
                #expect(x >= ax - 0.01 && y >= ay - 0.01 && x + w <= ax + aw + 0.01 && y + h <= ay + ah + 0.01)
            }
            #expect(a.cells.filter(\.wide).count == n / ChaosStress.wideShare)
        }
    }

    @Test("motion-bento/chaos/stress::readings_change_every_frame")
    func readingsChangeEveryFrame() {
        var w = ChaosWall(seed: 3)
        w.update(t: 1.0, n: 32)
        let before = w.cells.map(\.reading)
        w.update(t: 1.0 + 1.0 / 120.0, n: 32)
        #expect(zip(w.cells, before).allSatisfy { $0.0.reading != $0.1 })
    }

    // MARK: - chaos/src/hud.rs

    @Test("motion-bento/chaos/hud::a_replay_counts_the_refreshes_slow_frames_miss")
    func aReplayCountsTheRefreshesSlowFramesMiss() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-hud-\(ProcessInfo.processInfo.processIdentifier).csv")
        var csv = "show_s,load,build_ms,work_ms,start_s\n"
        for i in 0..<240 {
            let ms = i % 2 == 0 ? 4.0 : 12.0
            csv += "\(Float(i) / 120.0),16,\(ms),0,0\n"
        }
        try csv.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try ChaosReplay.load(path: url.path)
        #expect(r.until(0.5).count == 61)
        let out = ChaosReadout.replay(r, at: 10.0)
        #expect(out.graph.count == ChaosHudConstants.graph)
        #expect(out.missed == 60)
        #expect(abs(out.fps - 80.0) < 0.01)
        #expect((chaosGrade(4.0), chaosGrade(12.0), chaosGrade(20.0)) == (0, 1, 2))
    }

    // MARK: - chaos/src/meter.rs

    @Test("motion-bento/chaos/meter::counts_late_frames_against_the_refresh")
    func countsLateFramesAgainstTheRefresh() {
        var m = ChaosMeter(framework: "test", refreshHz: 120.0)
        let t0 = m.t0
        let periodNs = Int64((1_000_000_000.0 / 120.0).rounded())
        let period = Duration.nanoseconds(periodNs)
        var at = t0
        for i in 0..<240 {
            at = at.advanced(by: i % 60 == 59 ? period * 3 : period)
            m.frameWithBuild(at: at, workMs: 2.0, buildMs: 1.5)
        }
        m.frame(at: at.advanced(by: .milliseconds(400)), workMs: 2.0)
        let s = m.summarise(m.frames[...], seconds: 2.0, cpuSeconds: 0.0)
        #expect(s.late == 4)
        #expect(s.dropped == 8)
        #expect(s.idleGaps == 1)
        #expect(abs(s.intervalMs[0] - 1000.0 / 120.0) < 0.01)
        #expect(s.buildMs?[0] == 1.5)
        #expect(m.json().contains("\"dropped_frames\""))
    }

    // MARK: - motion-bento/src/dock.rs

    @Test("motion-bento/dock::thousands_groups_digits")
    func thousandsGroupsDigits() {
        #expect(thousands(1284) == "1,284")
        #expect(thousands(999) == "999")
        #expect(thousands(1_000_000) == "1,000,000")
    }

    // MARK: - sketch/src/main.rs

    @Test("sketch::the_paper_takes_strokes")
    func sketchTakesStrokes() {
        let rt = Runtime(state: SketchState(), viewport: Vec2(560, 420), pixelScale: 2.0, systemDark: false, view: sketchView)
        rt.frame(at: 0.0)
        let info = rt.element(byKey: "paper")
        #expect(info != nil)
        guard let info else { return }
        let pos = Vec2(info.rect[0] + info.rect[2] * 0.5, info.rect[1] + info.rect[3] * 0.5)
        rt.pointerMove(to: pos, at: 0.0)
        rt.pointerDown(at: pos, at: 0.0)
        rt.pointerMove(to: Vec2(pos.x + 30.0, pos.y + 10.0), at: 0.01)
        rt.pointerUp(at: Vec2(pos.x + 30.0, pos.y + 10.0), at: 0.02)
        rt.frame(at: 0.03)
        #expect(rt.state.strokes.count == 1)
        #expect(rt.state.strokes[0].count >= 2)
    }

    @Test("sketch::the_paper_shows_the_pencil_cursor")
    func sketchShowsPencilCursor() {
        let rt = Runtime(state: SketchState(), viewport: Vec2(560, 420), pixelScale: 2.0, systemDark: false, view: sketchView)
        rt.frame(at: 0.0)
        let info = rt.element(byKey: "paper")
        #expect(info != nil)
        guard let info else { return }
        let pos = Vec2(info.rect[0] + info.rect[2] * 0.5, info.rect[1] + info.rect[3] * 0.5)
        rt.pointerMove(to: pos, at: 0.01)
        rt.frame(at: 0.02)
        #expect(rt.currentCursor() == .image(pencilCursorImage))
    }
}
