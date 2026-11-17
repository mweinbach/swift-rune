import Foundation
import Testing
@testable import Rune
import RuneMotion
#if canImport(simd)
import simd
#endif

private func premulColor(_ c: Color, _ op: Float = 1.0) -> SIMD4<Float> {
    let a = c.a * op
    return SIMD4<Float>(c.r * a, c.g * a, c.b * a, a)
}

private func mgKinds(_ rec: MotionGateRecording) -> [String] {
    motionGateCheck(rec).map(\.kind)
}

// MARK: - 1. Raster Parity (`motion_gate/check/raster.rs` — 3 tests)

@Suite("MotionGate Raster Parity Tests")
struct MotionGateRasterParityTests {
    private func rectInst(_ r: SIMD4<Float>, _ c: Color, _ op: Float) -> RenderInstance {
        RenderInstance(
            rect: r,
            radii: .zero,
            fill: premulColor(c, op),
            border: .zero,
            params: SIMD4<Float>(0, KIND_RECT, 0, 0),
            uv: .zero,
            clip: SIMD4<Float>(-1e9, -1e9, 1e9, 1e9),
            fade: .zero
        )
    }

    @Test("a_rect_colours_the_cells_it_covers_through_its_layer")
    func aRectColoursTheCellsItCoversThroughItsLayer() {
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let g = MotionGateGrid.rasterize([rectInst(SIMD4<Float>(0, 0, 48, 24), red, 1.0)], size: (48.0, 48.0), scale: 2.0)
        #expect(g.w == 4 && g.h == 4)
        #expect(abs(g.color(0).r - 1.0) < 0.02 && g.color(15).r < 0.01)

        var layer = RenderInstance.beginLayer(
            bounds: .zero,
            clip: SIMD4<Float>(-1e9, -1e9, 1e9, 1e9),
            spec: LayerSpec(opacity: 0.5)
        )
        layer.fill.w = 0.5
        let end = RenderInstance.endLayer()
        let half = MotionGateGrid.rasterize([layer, rectInst(SIMD4<Float>(0, 0, 96, 96), red, 1.0), end], size: (48.0, 48.0), scale: 2.0)
        #expect(abs(half.color(0).r - 0.5) < 0.02, "Unexpected layer color: \(half.color(0))")
    }

    @Test("an_icon_covers_the_same_cells_on_the_pixel_grid_as_off_it")
    func anIconCoversTheSameCellsOnThePixelGridAsOffIt() {
        func glyph(_ r: SIMD4<Float>, _ span: Float) -> RenderInstance {
            RenderInstance(
                rect: r,
                radii: .zero,
                fill: premulColor(.white, 1.0),
                border: .zero,
                params: SIMD4<Float>(0, KIND_GLYPH, 0, 1.0),
                uv: SIMD4<Float>(7.0, 9.0, span, span),
                clip: SIMD4<Float>(-1e9, -1e9, 1e9, 1e9),
                fade: .zero
            )
        }
        let on = glyph(SIMD4<Float>(48, 24, 16, 16), 0.0)
        let off = glyph(SIMD4<Float>(47, 23, 18, 18), 18.0)
        let aprons: Set<MotionGateGrid.ApronKey> = [MotionGateGrid.ApronKey(off)]
        let a = MotionGateGrid.rasterizeWith([on], size: (96.0, 72.0), scale: 1.0, aprons: aprons, shifts: [:])
        let b = MotionGateGrid.rasterizeWith([off], size: (96.0, 72.0), scale: 1.0, aprons: aprons, shifts: [:])
        let ink: (MotionGateGrid) -> [Float] = { g in (0..<(g.w * g.h)).map { g.lab($0).x } }
        let ia = ink(a)
        let ib = ink(b)
        for i in 0..<ia.count {
            #expect(abs(ia[i] - ib[i]) < 0.01, "cell \(i): \(ia[i]) on the grid, \(ib[i]) off it")
        }
        let whole = MotionGateGrid.rasterize([off], size: (96.0, 72.0), scale: 1.0)
        #expect(ink(whole) != ib, "only an icon's apron is left out")
    }

    @Test("a_gpu_frame_averages_into_the_same_cells")
    func aGpuFrameAveragesIntoTheSameCells() {
        var px = Array(repeating: UInt8(0), count: 24 * 24 * 4)
        for i in 0..<(24 * 12) {
            let p = i * 4
            px[p] = 255
            px[p + 1] = 255
            px[p + 2] = 255
            px[p + 3] = 255
        }
        let g = MotionGateGrid.fromPixels(px, pw: 24, ph: 24, size: (24.0, 24.0))
        #expect(g.w == 2 && g.h == 2)
        #expect(g.lab(0).x > 0.99 && g.lab(3).x < 0.01)
    }
}

// MARK: - 2. Series Parity (`motion_gate/check/series.rs` — 10 tests)

@Suite("MotionGate Series Parity Tests")
struct MotionGateSeriesParityTests {
    private static let tune = MotionGateSeries.Tune(snap: 1.0, flash: 0.5, still: 0.01, horizon: 24, rest: (2, 15))

    private func runSeries(_ xs: [Float]) -> [String] {
        let vals: [MotionGateSeries.V6?] = xs.map { ($0, 0, 0, 0, 0, 0) }
        return MotionGateSeries.events(vals, tune: Self.tune) { _ in 1.0 }.map(\.kind)
    }

    private func ease(_ from: Float, _ to: Float, _ frames: Int) -> [Float] {
        (1...frames).map { i in
            let t = Float(i) / Float(frames)
            return from + (to - from) * t * t * (3.0 - 2.0 * t)
        }
    }

    @Test("a_step_between_still_frames_snaps")
    func aStepBetweenStillFramesSnaps() {
        #expect(runSeries([0, 0, 0, 2, 2, 2]) == ["snap"])
    }

    @Test("a_transition_neither_snaps_nor_flashes")
    func aTransitionNeitherSnapsNorFlashes() {
        var xs = Array(repeating: Float(0), count: 4)
        xs.append(contentsOf: ease(0, 2, 12))
        xs.append(contentsOf: Array(repeating: Float(2), count: 6))
        #expect(runSeries(xs).isEmpty)
    }

    @Test("a_cross_fade_through_a_dip_is_no_flash")
    func aCrossFadeThroughADipIsNoFlash() {
        let xs: [Float] = (0..<30).map { k in
            if k < 4 { return 1.0 }
            let s = sin(Float(k - 4) / 20.0 * .pi)
            return 1.0 - 0.3 * max(0.0, s)
        }
        #expect(runSeries(xs).isEmpty)
    }

    @Test("dropping_out_and_fading_back_flashes")
    func droppingOutAndFadingBackFlashes() {
        var xs = Array(repeating: Float(2), count: 4)
        xs.append(0.0)
        xs.append(contentsOf: ease(0, 2, 12))
        xs.append(contentsOf: Array(repeating: Float(2), count: 6))
        #expect(runSeries(xs) == ["flash"])
    }

    @Test("a_one_frame_blink_flashes_once")
    func aOneFrameBlinkFlashesOnce() {
        #expect(runSeries([1, 1, 1, 0, 1, 1, 1]) == ["flash"])
    }

    @Test("drifting_away_and_snapping_back_flashes")
    func driftingAwayAndSnappingBackFlashes() {
        var xs = Array(repeating: Float(0), count: 4)
        xs.append(contentsOf: ease(0, 1.5, 10))
        xs.append(contentsOf: Array(repeating: Float(0), count: 6))
        #expect(runSeries(xs) == ["flash"])
    }

    @Test("two_steps_the_same_way_snap_each_and_no_more")
    func twoStepsTheSameWaySnapEachAndNoMore() {
        #expect(runSeries([0, 0, 1, 1, 1, 1, 2, 2, 2]) == ["snap", "snap"])
    }

    @Test("a_transition_that_rests_and_carries_on_changes_twice")
    func aTransitionThatRestsAndCarriesOnChangesTwice() {
        var xs = Array(repeating: Float(0), count: 3)
        xs.append(contentsOf: ease(0, 1, 8))
        xs.append(contentsOf: Array(repeating: Float(1), count: 4))
        xs.append(contentsOf: ease(1, 2, 8))
        xs.append(contentsOf: Array(repeating: Float(2), count: 4))
        #expect(runSeries(xs) == ["changes-twice"])
    }

    @Test("a_tail_that_creeps_then_lands_changes_once")
    func aTailThatCreepsThenLandsChangesOnce() {
        var xs = Array(repeating: Float(0), count: 3)
        xs.append(contentsOf: ease(0, 1, 8))
        xs.append(contentsOf: (1...14).map { 1.0 + 0.009 * Float($0) })
        let last = xs.last ?? 1.0
        xs.append(contentsOf: Array(repeating: last + 0.4, count: 6))
        #expect(runSeries(xs).isEmpty)
    }

    @Test("going_there_and_back_later_changes_once_each_way")
    func goingThereAndBackLaterChangesOnceEachWay() {
        var xs = Array(repeating: Float(0), count: 3)
        xs.append(contentsOf: ease(0, 1, 8))
        xs.append(contentsOf: Array(repeating: Float(1), count: 4))
        xs.append(contentsOf: ease(1, 0, 8))
        xs.append(contentsOf: Array(repeating: Float(0), count: 4))
        #expect(runSeries(xs).isEmpty)
    }
}

// MARK: - 3. Check Parity (`motion_gate/check_tests.rs` — 13 tests)

@Suite("MotionGate Check Parity Tests")
struct MotionGateCheckParityTests {
    private func makeRec(_ tracks: [(String, [(Int, [Float], Float)])], frames: Int) -> MotionGateRecording {
        let r = MotionGateRecording(size: (1000, 1000), hz: 120.0)
        r.frames = frames
        for (path, fs) in tracks {
            let i = r.track(path)
            r.tracks[i].frames = fs.map { (k, rect, op) in
                (k, MotionGateSnap(rect: rect, vis: rect, op: op, scale: 1.0, flags: MotionGateSnapFlags.ink))
            }
        }
        return r
    }

    @Test("a_spring_passes_and_a_snap_jumps")
    func aSpringPassesAndASnapJumps() {
        let smooth = (0..<60).map { k -> (Int, [Float], Float) in
            let p = 1.0 - exp(-Float(k) / 8.0)
            return (k, [0, 300 - 200 * p, 100, 40], 1.0)
        }
        #expect(mgKinds(makeRec([("a", smooth)], frames: 60)).isEmpty)

        let snap = (0..<60).map { k in
            (k, [0, k < 30 ? Float(300) : Float(100), 100, 40], Float(1))
        }
        #expect(mgKinds(makeRec([("a", snap)], frames: 60)) == ["jump"])

        var y: Float = 0.0
        let lurch = (0..<60).map { k -> (Int, [Float], Float) in
            if k > 0 && k < 40 {
                y += (k < 20) ? 4.0 : 20.0
            }
            return (k, [0, y, 100, 40], 1.0)
        }
        #expect(mgKinds(makeRec([("a", lurch)], frames: 60)) == ["jerk"])
    }

    @Test("a_climb_in_kicks_is_stop_start_and_a_steady_one_passes")
    func aClimbInKicksIsStopStartAndASteadyOnePasses() {
        let n = 600
        func makePath(_ y: (Int) -> Float) -> [(Int, [Float], Float)] {
            (0..<n).map { k in
                (k, [0, ((500.0 - y(k)) * 128.0).rounded() / 128.0, 100, 40], 1.0)
            }
        }
        let kicks = makeRec([("reply", makePath { k in
            3.0 * Float(k / 36) + 3.0 * (1.0 - exp(-Float(k % 36) / 3.0))
        })], frames: n)
        for k in stride(from: 0, to: n, by: 36) {
            kicks.inputs.append((k, "event"))
        }
        #expect(mgKinds(kicks).contains("stop-start"))

        let steady = makeRec([("reply", makePath { k in Float(min(k, 480)) / 12.0 })], frames: n)
        #expect(mgKinds(steady).isEmpty)

        let creep = makeRec([("reply", makePath { k in 3.0 - 3.0 * exp(-Float(k) / 240.0) })], frames: n)
        #expect(!mgKinds(creep).contains("stop-start"))

        for i in kicks.inputs.indices {
            kicks.inputs[i].1 = "tap"
        }
        #expect(!mgKinds(kicks).contains("stop-start"))
    }

    @Test("an_instant_toggle_is_reported_where_the_height_changed")
    func anInstantToggleIsReportedWhereTheHeightChanged() {
        let group = (0..<60).map { k in (k, [Float(0), 100, 100, k < 30 ? 28 : 84], Float(1)) }
        let below = (0..<60).map { k in (k, [Float(0), k < 30 ? 128 : 184, 100, 40], Float(1)) }
        let r = makeRec([("g", group), ("b", below)], frames: 60)
        #expect(mgKinds(r) == ["jump", "jump"])
        r.inputs.append((30, "tap"))
        let f = motionGateCheck(r)
        #expect(f.map { ($0.kind, $0.element) }.elementsEqual([("jump", "g")], by: ==))
    }

    @Test("pops_overshoot_reversal_and_flicker")
    func popsOvershootReversalAndFlicker() {
        let pop = (20..<60).map { k in (k, [Float(0), 0, 100, 40], Float(1)) }
        #expect(mgKinds(makeRec([("a", pop)], frames: 60)) == ["pop-in"])

        let opens = (20..<60).map { k in (k, [Float(0), 0, 100, 0.4 + 0.1 * Float(k - 20)], Float(1)) }
        #expect(mgKinds(makeRec([("a", opens)], frames: 60)).isEmpty)

        let gone = (0..<20).map { k in (k, [Float(0), 0, 100, 40], Float(1)) }
        #expect(mgKinds(makeRec([("a", gone)], frames: 60)) == ["pop-out"])

        let over = (0..<60).map { k -> (Int, [Float], Float) in
            let t = Float(k) / 8.0
            return (k, [0, 100 + 100 * (1.0 - exp(-t) * cos(t * 1.5)), 100, 40], 1.0)
        }
        #expect(mgKinds(makeRec([("a", over)], frames: 60)).contains("overshoot"))

        let dogleg = (0..<60).map { k -> (Int, [Float], Float) in
            let t = Float(k) / 59.0
            return (k, [0, 100 - 40 * min(t * 3.0, 1.0) * (1.0 - t) * 4.0 + 200 * t * t, 100, 40], 1.0)
        }
        #expect(mgKinds(makeRec([("a", dogleg)], frames: 60)).contains("reversal"))

        let blink = (0..<60).map { k in
            (k, [Float(0), 0, 100, 40], (20..<24).contains(k) ? Float(0.3) : Float(1.0))
        }
        #expect(mgKinds(makeRec([("a", blink)], frames: 60)) == ["flicker"])

        let hidden = makeRec([("a", blink)], frames: 60)
        for idx in hidden.tracks[0].frames.indices {
            hidden.tracks[0].frames[idx].1.flags = 0
        }
        #expect(mgKinds(hidden).isEmpty)
    }

    @Test("words_that_swap_in_place_are_a_text_swap_but_a_ticking_count_is_not")
    func wordsThatSwapInPlaceAreATextSwapButATickingCountIsNot() {
        let still: [(Int, [Float], Float)] = (0..<60).map { k in (k, [0, 0, 100, 20], 1.0) }
        func withWords(_ words: [(Int, String)]) -> [String] {
            let r = makeRec([("a", still)], frames: 60)
            r.tracks[0].words = words
            return mgKinds(r)
        }
        #expect(withWords([(0, "Read backoff.ts"), (30, "Grep retryBudget")]) == ["text-swap"])
        #expect(withWords([(0, "9s"), (30, "10s")]).isEmpty)
        #expect(withWords([(0, "Looks"), (30, "Looks right")]).isEmpty)
        #expect(withWords([(0, "run \u{2066}t\u{2069}"), (30, "run \u{2066}th\u{2069}")]).isEmpty)
        #expect(withWords([(0, "run \u{2066}test\u{2069}"), (30, "run \u{2066}build\u{2069}")]) == ["text-swap"])

        let link = (0..<60).map { k in (k, [Float(0), 0, k < 30 ? 40 : 85, 20], Float(1)) }
        let r = makeRec([("a", link)], frames: 60)
        #expect(mgKinds(r) == ["jump"])
        r.tracks[0].words = [(0, "health"), (30, "health check")]
        #expect(mgKinds(r).isEmpty)
    }

    @Test("a_loop_that_restarts_jumps_and_a_finished_run_goes_quiet")
    func aLoopThatRestartsJumpsAndAFinishedRunGoesQuiet() {
        let still: [(Int, [Float], Float)] = (0..<120).map { k in (k, [0, 0, 100, 20], 1.0) }
        func looping(_ restart: Int?) -> MotionGateRecording {
            let r = makeRec([("a", still)], frames: 120)
            for idx in r.tracks[0].frames.indices {
                let k = r.tracks[0].frames[idx].0
                let t = restart.flatMap { at in k >= at ? (k - at) : nil } ?? k
                r.tracks[0].frames[idx].1.phase = (Float(t) / 144.0).truncatingRemainder(dividingBy: 1.0)
            }
            return r
        }
        #expect(mgKinds(looping(nil)).isEmpty)
        #expect(mgKinds(looping(60)) == ["loop-jump"])

        let r = makeRec([("a", (0..<300).map { ($0, [0, 0, 100, 20], 1.0) })], frames: 300)
        r.quietFrom = 100
        r.awake = (0..<300).map { $0 < 180 }
        #expect(mgKinds(r).isEmpty)
        r.awake[260] = true
        #expect(mgKinds(r) == ["wakes-after-end"])
    }

    @Test("a_row_that_loses_its_key_remounts_but_one_that_becomes_another_element_does_not")
    func aRowThatLosesItsKeyRemountsButOneThatBecomesAnotherElementDoesNot() {
        func fade(_ from: Int, _ to: Int, _ out: Bool) -> [(Int, [Float], Float)] {
            (from..<to).map { k in
                let op: Float = if out && k >= 30 {
                    1.0 - Float(k - 29) / 10.0
                } else if !out {
                    min(1.0, Float(k - 29) / 10.0)
                } else {
                    1.0
                }
                return (k, [0, 0, 300, 20], op)
            }
        }
        func found(_ old: String, _ new: String) -> Bool {
            let r = makeRec([(old, fade(0, 40, true)), (new, fade(30, 60, false))], frames: 60)
            for idx in r.tracks[0].frames.indices where r.tracks[0].frames[idx].0 >= 30 {
                r.tracks[0].frames[idx].1.flags |= MotionGateSnapFlags.exiting
            }
            for tr in r.tracks {
                tr.text = "Got it, I'll look."
            }
            return mgKinds(r).contains("remount")
        }
        #expect(found("list/row-0/label", "list/row-1/label"))
        #expect(!found("tray/pending/label", "list/row/text"))
    }

    @Test("a_pinned_scroll_that_stops_following_is_unpinned_unless_someone_scrolled")
    func aPinnedScrollThatStopsFollowingIsUnpinnedUnlessSomeoneScrolled() {
        let view: [(Int, [Float], Float)] = (0..<60).map { ($0, [0, 0, 100, 200], 1.0) }
        func grows(_ follows: Bool) -> [(Int, [Float], Float)] {
            (0..<60).map { k in
                let h = 400.0 + Float(max(0, k - 30))
                return (k, [0, follows ? (200.0 - h) : -200.0, 100, h], 1.0)
            }
        }
        func unpinned(_ follows: Bool, _ input: String?) -> Bool {
            let r = makeRec([("scroll", view), ("scroll/content", grows(follows))], frames: 60)
            r.tracks[1].parent = 0
            for idx in r.tracks[1].frames.indices {
                r.tracks[1].frames[idx].1.vis = [0, 0, 100, 200]
            }
            if let input {
                r.inputs.append((31, input))
            }
            return mgKinds(r).contains("unpinned")
        }
        #expect(!unpinned(true, nil))
        #expect(unpinned(false, nil))
        #expect(unpinned(false, "event (3 left)"))
        #expect(!unpinned(false, "scroll up"))
    }

    @Test("a_second_sibling_under_one_key_shows_twice")
    func aSecondSiblingUnderOneKeyShowsTwice() {
        func row(_ y: Float) -> [(Int, [Float], Float)] {
            (0..<60).map { ($0, [0, y, 100, 20], 1.0) }
        }
        #expect(mgKinds(makeRec([("list/row-7", row(0))], frames: 60)).isEmpty)
        #expect(mgKinds(makeRec([("list/row-7", row(0)), ("list/row-7#dup1", row(20))], frames: 60)) == ["twice"])
    }

    @Test("a_flight_that_lands_under_a_clip_lands_unseen")
    func aFlightThatLandsUnderAClipLandsUnseen() {
        let flight: [(Int, [Float], Float)] = (0..<60).map { k in
            let t = min(1.0, Float(k) / 30.0)
            return (k, [0, 100 + 300 * t * t * (3.0 - 2.0 * t), 100, 40], 1.0)
        }
        func landed(_ clipped: Bool, _ moved: Bool) -> [String] {
            let fs: [(Int, [Float], Float)] = moved ? flight : (0..<60).map { ($0, [0, 400, 100, 40], 1.0) }
            let r = makeRec([("flight", fs)], frames: 60)
            for idx in r.tracks[0].frames.indices where clipped && r.tracks[0].frames[idx].0 >= 40 {
                r.tracks[0].frames[idx].1.vis = [0, 0, 0, 0]
            }
            return mgKinds(r)
        }
        #expect(landed(false, true).isEmpty)
        #expect(landed(true, true) == ["lands-unseen"])
        #expect(landed(true, false).isEmpty)
    }

    @Test("where_counts_roll_a_ticking_count_is_a_text_swap_but_a_rolling_label_is_not")
    func whereCountsRollATickingCountIsATextSwapButARollingLabelIsNot() {
        let still: [(Int, [Float], Float)] = (0..<60).map { ($0, [0, 0, 100, 20], 1.0) }
        let r = makeRec([("count", still)], frames: 60)
        r.tracks[0].words = [(0, "9s"), (30, "10s")]
        #expect(mgKinds(r).isEmpty)
        r.countsRoll = true
        #expect(mgKinds(r) == ["text-swap"])
        let glyph = r.track("count/digit-1", parent: 0)
        r.tracks[glyph].frames = (0..<60).map { k in
            (k, MotionGateSnap(rect: [0, 0, 8, 20], vis: [0, 0, 8, 20], op: 1.0, scale: 1.0, flags: MotionGateSnapFlags.ink))
        }
        #expect(mgKinds(r).isEmpty)
    }

    @Test("motion_inside_a_scroll_is_judged_against_the_scroll")
    func motionInsideAScrollIsJudgedAgainstTheScroll() {
        func offset(_ k: Int) -> Float { 2.0 * Float(k) }
        func runTrack(_ own: (Int) -> Float, _ flags: UInt8, _ told: Bool) -> [String] {
            let fs = (0..<60).map { k in (k, [Float(0), 300.0 + own(k) - offset(k), 100, 40], Float(1)) }
            let r = makeRec([("list/node", fs)], frames: 60)
            for idx in r.tracks[0].frames.indices {
                let k = r.tracks[0].frames[idx].0
                r.tracks[0].frames[idx].1.flags |= flags
                if told {
                    r.tracks[0].frames[idx].1.scrolled = [0, offset(k)]
                }
            }
            return mgKinds(r)
        }
        let glide: (Int) -> Float = { k in 60.0 * (1.0 - exp(-Float(k) / 8.0)) }
        #expect(runTrack(glide, 0, false) == ["reversal"])
        #expect(runTrack(glide, 0, true).isEmpty)
        #expect(runTrack(glide, MotionGateSnapFlags.scrolling, true).isEmpty)

        let wobble: (Int) -> Float = { k in 2.5 * sin(Float(k) * 0.6) }
        #expect(runTrack(wobble, 0, false).isEmpty)
        #expect(runTrack(wobble, 0, true) == ["jiggle"])
        #expect(runTrack(wobble, MotionGateSnapFlags.scrolling, true) == ["jiggle"])
    }

    @Test("a_jump_is_what_shows_jumping")
    func aJumpIsWhatShowsJumping() {
        func scrolledList(_ tracks: [(String, [[Float]])]) -> MotionGateRecording {
            let r = MotionGateRecording(size: (1000, 1000), hz: 120.0)
            r.frames = 60
            for (path, rects) in tracks {
                let parent: Int? = path.split(separator: "/").dropLast().isEmpty ? nil : {
                    let prefix = path.split(separator: "/").dropLast().joined(separator: "/")
                    return r.tracks.firstIndex { $0.path == prefix }
                }()
                let i = r.track(path, parent: parent)
                r.tracks[i].frames = rects.enumerated().map { k, rect in
                    let y0 = max(0.0, rect[1])
                    let y1 = min(400.0, rect[1] + rect[3])
                    let vis: [Float] = [rect[0], y0, rect[2], max(0.0, y1 - y0)]
                    return (k, MotionGateSnap(rect: rect, vis: vis, op: 1.0, scale: 1.0, flags: MotionGateSnapFlags.ink, phase: .nan, scrolled: [0, 600]))
                }
            }
            return r
        }
        func at(_ k: Int, _ a: [Float], _ b: [Float]) -> [Float] { k < 30 ? a : b }
        func still(_ rect: [Float]) -> [[Float]] { Array(repeating: rect, count: 60) }

        let list = still([0, -600, 100, 2000])
        let row = (0..<60).map { at($0, [0, 100, 100, 40], [0, 200, 100, 40]) }
        #expect(mgKinds(scrolledList([("list", list), ("list/row", row)])) == ["jump"])

        let content = (0..<60).map { at($0, [0, -1100, 100, 1500], [0, -200, 100, 600]) }
        let fold = (0..<60).map { at($0, [0, -900, 100, 1200], [0, 0, 100, 300]) }
        let shown: (Float) -> [[Float]] = { y in still([0, y, 100, 40]) }
        let r = scrolledList([
            ("list", content),
            ("list/fold", fold),
            ("list/fold/a", shown(100)),
            ("list/fold/b", shown(200)),
            ("list/c", shown(320))
        ])
        #expect(mgKinds(r).isEmpty)

        let content2 = (0..<60).map { at($0, [0, -600, 100, 2000], [0, -500, 100, 2000]) }
        let rowFn: (Float) -> [[Float]] = { y in (0..<60).map { at($0, [0, y, 100, 40], [0, y + 100, 100, 40]) } }
        #expect(mgKinds(scrolledList([("list", content2), ("list/a", rowFn(0)), ("list/b", rowFn(100)), ("list/c", rowFn(200))])) == ["offset-jump"])
    }
}

// MARK: - 4. Loop Parity (`motion_gate/loop_tests.rs` — 4 tests)

@Suite("MotionGate Loop Parity Tests")
struct MotionGateLoopParityTests {
    @Test("a_one_shot_fade_that_settles_is_not_a_loop")
    func aOneShotFadeThatSettlesIsNotALoop() {
        struct Badge {
            var shown = false
            var right = false
        }
        let fadeIn = MotionSequence(frames: [
            Beat(at: 0.0, opacity: 0.0),
            Beat(at: 0.2, easing: .easeOut)
        ])
        let rt = Runtime<Badge>(state: Badge(), viewport: Vec2(400, 200), pixelScale: 1.0, systemDark: true) { (s: Badge, _: inout Cx<Badge>) -> El<Badge> in
            var c: El<Badge> = col().wFull().hFull()
            if s.shown {
                let b: El<Badge> = el().key("badge").size(100, 40).bg(oklch(0.6, 0.1, 250.0)).sequence(fadeIn)
                c = c.child(s.right ? b.ml(200) : b)
            }
            return c
        }
        let r = MotionGateRun(rt, hz: 120.0)
        r.idle(0.5)
        r.step()
        r.act("show") { $0.update { s, _ in s.shown = true } }
        r.play(1.0)
        #expect(mgKinds(r.rec).isEmpty)

        r.act("move") { $0.update { s, tx in s.right = true; tx.instant() } }
        r.play(0.5)
        #expect(mgKinds(r.rec) == ["jump"])
    }

    @Test("a_spinner_keeps_its_rhythm_unless_it_restarts")
    func aSpinnerKeepsItsRhythmUnlessItRestarts() {
        struct Spinner { var on = true }
        func runSpin(restart: Bool) -> MotionGateRecording {
            let rt = Runtime<Spinner>(state: Spinner(), viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true) { (s: Spinner, _: inout Cx<Spinner>) -> El<Spinner> in
                var c: El<Spinner> = col().wFull().hFull()
                if s.on {
                    c = c.child(
                        el().key("spin").size(20, 20).bg(oklch(0.6, 0.1, 250.0))
                            .looping(LoopSpec.rotation(period: 1.0))
                    )
                }
                return c
            }
            let r = MotionGateRun(rt, hz: 120.0)
            r.idle(0.5)
            r.step()
            r.play(0.6)
            if restart {
                r.act("hide") { $0.update { s, tx in s.on = false; tx.instant() } }
                r.act("show") { $0.update { s, tx in s.on = true; tx.instant() } }
            }
            r.play(0.6)
            return r.rec
        }
        #expect(!mgKinds(runSpin(restart: false)).contains("loop-jump"))
        #expect(mgKinds(runSpin(restart: true)).contains("loop-jump"))
    }

    private struct Timeline {
        var open = false
        var rows = 60
        var tick: UInt32 = 0
    }

    private func runFold(_ toggles: [Double], _ last: ((inout Timeline, inout Tx) -> Void)? = nil) -> MotionGateRecording {
        let rt = Runtime<Timeline>(state: Timeline(), viewport: Vec2(400, 300), pixelScale: 1.0, systemDark: true) { (s: Timeline, _: inout Cx<Timeline>) -> El<Timeline> in
            let ink = oklch(0.6, 0.1, 250.0)
            let rows: El<Timeline> = col()
                .key("rows")
                .wFull()
                .growth()
                .virtualRows(count: s.rows, estimatedRowHeight: 40.0, key: { _, i in "r\(i)" }) { st, i in
                    if i != 55 {
                        return el().wFull().h(40).bg(ink)
                    }
                    var group: El<Timeline> = col().key("group").wFull().child(el().key("hdr").wFull().h(28).bg(ink))
                    if st.open {
                        var steps: El<Timeline> = col().key("steps").wFull()
                        for k in 0..<40 {
                            steps = steps.child(el().key("step-\(k)").wFull().h(28).bg(ink))
                        }
                        group = group.child(steps)
                    }
                    return col().wFull().foldGlide(Spring(duration: 0.18, bounce: 0.0)).child(group)
                }
            return col().key("scroll").size(400, 300).scroll(stickBottom: true).child(rows)
        }
        let r = MotionGateRun(rt, hz: 120.0)
        r.idle(1.0)
        r.step()
        func playTicks(_ secs: Double) {
            let steps = Int((secs * 120.0).rounded())
            for _ in 0..<steps {
                r.rt.update { s, _ in s.tick += 1 }
                r.step()
            }
        }
        for secs in toggles {
            r.act("tap") { $0.update { s, tx in s.open.toggle(); tx.keepOnScreen("hdr") } }
            playTicks(secs)
        }
        if let last {
            r.act("remove") { $0.update(last) }
            playTicks(0.5)
        }
        return r.rec
    }

    @Test("rows_under_a_fold_gliding_open_stay_mounted_while_they_show")
    func rowsUnderAFoldGlidingOpenStayMountedWhileTheyShow() {
        let rec = runFold([1.0])
        #expect(!mgKinds(rec).contains("pop-out"))
    }

    @Test("a_list_toggled_over_and_over_is_not_a_loop")
    func aListToggledOverAndOverIsNotALoop() {
        let rec = runFold([0.3, 0.3, 0.3, 0.3, 0.3, 0.06, 0.5, 0.8]) { s, tx in
            s.rows = 59
            tx.instant()
        }
        let found = motionGateCheck(rec)
        #expect(found.contains { $0.kind == "pop-out" && $0.element.hasSuffix("r59") })
    }
}

// MARK: - 5. Paint Parity (`motion_gate/paint_tests.rs` — 11 tests)

@Suite("MotionGate Paint Parity Tests")
struct MotionGatePaintParityTests {
    private struct S {
        var warm = false
        var thick = false
        var swapped = false
        var carded = false
        var cross = false
        var pulse = false
    }

    private func makeRun(
        start: S = S(),
        input: Bool,
        intent: MotionIntent? = nil,
        change: (inout S, inout Tx) -> Void
    ) -> MotionGateRun<S> {
        let rt = Runtime<S>(state: start, viewport: Vec2(600, 400), pixelScale: 1.0, systemDark: true) { (s: S, _: inout Cx<S>) -> El<S> in
            let blue = oklch(0.6, 0.15, 250.0)
            let orange = oklch(0.7, 0.16, 50.0)
            let card = oklch(0.78, 0.1, 250.0)

            let swatch: El<S> = el().key("swatch").absolute(x: 40, y: 40).size(120, 80)
                .bg(s.warm ? orange : blue)
                .rounded(4.0)
                .border(s.thick ? 4.0 : 1.0, oklch(0.9, 0.02, 250.0))

            let a: El<S> = el().key("a").absolute(x: 300, y: 40).size(120, 80).bg(orange)
            let b: El<S> = el().key("b").absolute(x: 340, y: 70).size(120, 80).bg(blue)
            let first = s.swapped ? b : a
            let second = s.swapped ? a : b

            var page: El<S> = col().wFull().hFull().bg(oklch(0.18, 0.01, 260.0)).child(swatch).child(first).child(second)
            let (ax, ay, aw, ah): (Float, Float, Float, Float) = (40, 200, 200, 80)

            let plateBase: El<S> = el().key("plate").instantChanges().bg(card).transition(.opacity)
            let plate = s.carded ? plateBase.absolute(x: 0, y: 0).size(0, 0) : plateBase.absolute(x: ax, y: ay).size(aw, ah)
            if !s.cross {
                page = page.child(plate)
            } else {
                page = page.child(el().key("old").absolute(x: ax, y: ay).size(aw, ah).bg(card).transition(.opacity))
            }
            if s.carded || s.cross {
                page = page.child(el().key("card").absolute(x: ax, y: ay).size(aw, ah).bg(card).transition(.opacity))
            }
            if s.pulse {
                page = page.child(el().key("blink").absolute(x: 420, y: 200).size(120, 80).bg(orange).instantChanges())
            }
            if let intent {
                page = page.motionIntent(intent)
            }
            return page
        }
        let r = MotionGateRun(rt, hz: 120.0)
        r.idle(0.5)
        r.step()
        if input {
            r.act("tap") { $0.update(change) }
        } else {
            r.update(change)
            r.step()
        }
        return r
    }

    private func found(_ r: MotionGateRun<S>) -> [(String, String)] {
        r.playAndCheck(1.0).map { ($0.kind, $0.element) }
    }

    @Test("a_colour_that_cross_fades_on_its_own_passes")
    func aColourThatCrossFadesOnItsOwnPasses() {
        let r = makeRun(input: false) { s, _ in s.warm = true }
        #expect(found(r).isEmpty)
    }

    @Test("a_border_that_thickens_on_its_own_snaps_unless_a_hand_asked")
    func aBorderThatThickensOnItsOwnSnapsUnlessAHandAsked() {
        let r = makeRun(input: false) { s, _ in s.thick = true }
        let f = r.playAndCheck(1.0)
        #expect(f.map { ($0.kind, $0.element) }.elementsEqual([("snap", "0/@swatch")], by: ==))
        #expect(f.first?.detail.hasPrefix("border-width 1.0 → 4.0") == true)

        let tapped = makeRun(input: true) { s, _ in s.thick = true }
        #expect(found(tapped).isEmpty)

        let instant = makeRun(input: false) { s, tx in s.thick = true; tx.instant() }
        #expect(found(instant).isEmpty)
    }

    @Test("two_surfaces_trading_places_on_their_own_snap_in_the_paint_order")
    func twoSurfacesTradingPlacesOnTheirOwnSnapInThePaintOrder() {
        let r = makeRun(input: false) { s, _ in s.swapped = true }
        let f = r.playAndCheck(1.0)
        #expect(f.contains { $0.kind == "snap" && $0.detail.hasPrefix("z-order") })

        let tapped = makeRun(input: true) { s, _ in s.swapped = true }
        #expect(found(tapped).isEmpty)
    }

    @Test("a_plate_that_drops_out_before_its_card_fades_in_flashes_in_the_pixels")
    func aPlateThatDropsOutBeforeItsCardFadesInFlashesInThePixels() {
        let r = makeRun(input: false) { s, _ in s.carded = true }
        let f = r.playAndCheck(1.0)
        let flash = f.first { $0.kind == "flash" }
        #expect(flash != nil)
        #expect(flash?.element == "0/@plate (pixels)")
        #expect(flash?.detail.contains("(204×96 pt at 36,192)") == true)

        let fixed = makeRun(input: false) { s, tx in s.carded = true; tx.instant() }
        #expect(found(fixed).elementsEqual([("pop-in", "0/@card")], by: ==))
    }

    @Test("a_deliberate_cross_fade_between_two_surfaces_is_no_flash")
    func aDeliberateCrossFadeBetweenTwoSurfacesIsNoFlash() {
        let r = makeRun(input: false) { s, _ in s.cross = true }
        #expect(found(r).isEmpty)
    }

    @Test("a_surface_that_blinks_for_one_frame_flashes_unless_marked_a_pulse")
    func aSurfaceThatBlinksForOneFrameFlashesUnlessMarkedAPulse() {
        func blink(_ r: MotionGateRun<S>) {
            r.stepN(30)
            r.update { s, tx in s.pulse = true; tx.instant() }
            r.step()
            r.update { s, tx in s.pulse = false; tx.instant() }
            r.step()
        }
        let r = makeRun(input: false) { _, _ in }
        blink(r)
        let f = r.playAndCheck(1.0)
        #expect(f.contains { $0.kind == "flash" && $0.element == "0/@blink (pixels)" }, "Findings: \(f)")

        let marked = makeRun(input: false, intent: .pulse) { _, _ in }
        blink(marked)
        let flashes = marked.playAndCheck(1.0).filter { $0.kind == "flash" }.map(\.element)
        #expect(flashes.isEmpty)
    }

    @Test("a_highlight_landing_on_a_row_that_slides_under_a_still_pointer_is_no_snap")
    func aHighlightLandingOnARowThatSlidesUnderAStillPointerIsNoSnap() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(400, 400), pixelScale: 1.0, systemDark: true) { (_: Int, _: inout Cx<Int>) -> El<Int> in
            var rows: El<Int> = col().key("rows").wFull()
            for k in 0..<30 {
                rows = rows.child(
                    el().key("row-\(k)").wFull().h(40).bg(oklch(0.26, 0.015, 250.0)).hover(Color.white.alpha(0.06))
                )
            }
            let board: El<Int> = col().key("board").wFull().h(300).scroll(stickBottom: false).child(rows)
            return col().wFull().hFull().bg(oklch(0.18, 0.01, 250.0)).child(board)
        }
        let r = MotionGateRun(rt, hz: 120.0)
        rt.pointerMove(to: Vec2(200, 150), at: 0.0)
        r.idle(0.5)
        r.step()
        r.update { _, tx in tx.scrollTo("board", offset: Vec2(0, 400), animated: true) }
        r.play(1.0)
        let landed = r.rec.tracks.filter { tr in
            (1..<r.rec.frames).contains { k in
                guard let p = tr.paintAt(k), let q = tr.paintAt(k - 1) else { return false }
                return p.pointer.x == 1.0 && q.pointer.x == 0.0
            }
        }.count
        #expect(landed >= 1, "the highlight never lands")
        let f = r.finish()
        #expect(!f.contains { $0.detail.hasPrefix("fill") })
    }

    @Test("a_list_settling_its_scroll_steps_whole_pixels_and_no_region_snaps")
    func aListSettlingItsScrollStepsWholePixelsAndNoRegionSnaps() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(400, 400), pixelScale: 1.0, systemDark: true) { (_: Int, _: inout Cx<Int>) -> El<Int> in
            var rows: El<Int> = col().key("rows").wFull()
            for k in 0..<60 {
                let shade = (k % 2 == 0) ? oklch(0.3, 0.02, 250.0) : oklch(0.7, 0.02, 250.0)
                rows = rows.child(el().key("row-\(k)").wFull().h(13).bg(shade))
            }
            let board: El<Int> = col().key("board").wFull().h(300).scroll(stickBottom: false).child(rows)
            return col().wFull().hFull().bg(oklch(0.18, 0.01, 250.0)).child(board)
        }
        let r = MotionGateRun(rt, hz: 120.0)
        r.idle(0.5)
        r.step()
        r.update { _, tx in tx.scrollTo("board", offset: Vec2(0, 301.3), animated: true) }
        r.play(1.5)
        let f = r.finish()
        #expect(!f.contains { $0.element.hasSuffix("(pixels)") })
    }

    @Test("a_tooltip_showing_after_its_rest_is_no_region_snap")
    func aTooltipShowingAfterItsRestIsNoRegionSnap() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(400, 400), pixelScale: 1.0, systemDark: true) { (_: Int, _: inout Cx<Int>) -> El<Int> in
            let b: El<Int> = el().key("b").absolute(x: 40, y: 40).size(28, 28).bg(oklch(0.3, 0.02, 250.0)).help("Stop dictation ⇧⌘M")
            return col().wFull().hFull().bg(oklch(0.18, 0.01, 250.0)).child(b)
        }
        let r = MotionGateRun(rt, hz: 120.0)
        r.idle(0.5)
        r.step()
        r.act("point at the button") { rt in rt.pointerMove(to: Vec2(54, 54), at: rt.currentTime) }
        r.play(1.0)
        #expect(rt.helpTooltip() != nil, "the tooltip shows")
        let f = r.finish()
        #expect(!f.contains { $0.element.hasSuffix("(pixels)") })
    }

    @Test("an_icon_gliding_off_the_pixel_grid_marks_its_apron_and_shows_no_region_flash")
    func anIconGlidingOffThePixelGridMarksItsApronAndShowsNoRegionFlash() {
        let dotIcon = SVGIcon(viewBox: 16.0, body: "<rect x=\"2\" y=\"2\" width=\"12\" height=\"12\" fill=\"currentColor\"/>")
        let rt = Runtime<Float>(state: Float(0.0), viewport: Vec2(200, 120), pixelScale: 1.0, systemDark: true) { (x: Float, _: inout Cx<Float>) -> El<Float> in
            let dot: El<Float> = icon(dotIcon, size: 16.0).key("dot").color(.white).absolute(x: 40, y: 40).offset(x, 0).motion(Spring(duration: 1.2, bounce: 0))
            return col().wFull().hFull().bg(oklch(0.18, 0.01, 250.0)).child(dot)
        }
        let r = MotionGateRun(rt, hz: 120.0)
        r.idle(0.5)
        r.step()
        r.update { x, _ in x = 60.0 }
        r.stepN(240)
        let f = r.finish()
        #expect(!f.contains { $0.element.hasSuffix("(pixels)") })
    }

    @Test("words_set_in_a_field_without_a_key_are_no_region_snap")
    func wordsSetInAFieldWithoutAKeyAreNoRegionSnap() {
        struct Form { var edit = TextEdit("") }
        let rt = Runtime<Form>(state: Form(), viewport: Vec2(400, 120), pixelScale: 1.0, systemDark: true) { (_: Form, _: inout Cx<Form>) -> El<Form> in
            let field: El<Form> = textInput(key: "prompt", \Form.edit).size(360, 60)
            return col().wFull().hFull().p(20).bg(oklch(0.18, 0.01, 250.0)).child(field)
        }
        let r = MotionGateRun(rt, hz: 120.0)
        r.idle(0.5)
        r.step()
        r.update { s, _ in s.edit.insert("Can you also check the reconnect jitter?") }
        r.play(0.5)
        r.update { s, _ in s.edit = TextEdit("") }
        r.play(0.5)
        let f = r.finish()
        #expect(!f.contains { $0.element.hasSuffix("(pixels)") })
    }
}

// MARK: - 6. Spring None Parity (`motion_gate/spring_none_tests.rs` — 5 tests)

@Suite("MotionGate SpringNone Parity Tests")
struct MotionGateSpringNoneParityTests {
    private enum Source {
        case own, parent, token, reduced, ownBlur
    }

    private struct S {
        var source: Source = .own
        var warm = false
        var thick = false
        var blurred = false
    }

    private func snaps(from source: Source, change: (inout S) -> Void) -> [String] {
        let rt = Runtime<S>(state: S(source: source), viewport: Vec2(400, 300), pixelScale: 1.0, systemDark: true) { (s: S, cx: inout Cx<S>) -> El<S> in
            let blue = oklch(0.6, 0.15, 250.0)
            let orange = oklch(0.7, 0.16, 50.0)
            var swatch: El<S> = el().key("swatch").absolute(x: 40, y: 40).size(120, 80)
                .bg(s.warm ? orange : blue)
                .rounded(s.warm ? 24.0 : 4.0)
                .border(s.thick ? 4.0 : 1.0, s.warm ? oklch(0.4, 0.1, 50.0) : oklch(0.9, 0.02, 250.0))
                .blur(s.blurred ? 6.0 : 0.0)
            switch s.source {
            case .own: swatch = swatch.motion(.none)
            case .token: swatch = swatch.tokenMotion(.none)
            case .ownBlur: swatch = swatch.blurMotion(.none)
            case .parent, .reduced: break
            }
            if s.source == .reduced {
                cx.reducedMotion(true)
            }
            var page: El<S> = col().key("page").wFull().hFull().bg(oklch(0.18, 0.01, 260.0))
            if s.source == .parent || s.source == .ownBlur {
                page = page.motion(.none)
            }
            return page.child(swatch)
        }
        let r = MotionGateRun(rt, hz: 120.0)
        r.idle(0.5)
        r.step()
        r.update { s, _ in change(&s) }
        r.step()
        r.play(1.0)
        let f = r.finish()
        #expect(f.allSatisfy { $0.kind == "snap" && $0.element == "@page/@swatch" }, "Unexpected findings: \(f)")
        return f.compactMap { $0.detail.split(separator: " ").first.map(String.init) }.sorted()
    }

    @Test("an_explicit_spring_none_on_the_element_is_an_authored_instant_change")
    func anExplicitSpringNoneOnTheElementIsAnAuthoredInstantChange() {
        #expect(snaps(from: .own) { $0.warm = true } == [])
        #expect(snaps(from: .own) { $0.blurred = true } == [])
    }

    @Test("a_spring_none_inherited_from_a_parent_still_snaps")
    func aSpringNoneInheritedFromAParentStillSnaps() {
        #expect(snaps(from: .parent) { $0.warm = true } == ["border", "fill", "radius"])
    }

    @Test("a_spring_none_from_a_theme_token_still_snaps")
    func aSpringNoneFromAThemeTokenStillSnaps() {
        #expect(snaps(from: .token) { $0.warm = true } == ["border", "fill", "radius"])
    }

    @Test("a_change_reduce_motion_lands_at_once_still_snaps")
    func aChangeReduceMotionLandsAtOnceStillSnaps() {
        #expect(snaps(from: .reduced) { $0.warm = true; $0.blurred = true } == ["blur", "radius"])
    }

    @Test("an_explicit_spring_none_excuses_only_what_it_governs")
    func anExplicitSpringNoneExcusesOnlyWhatItGoverns() {
        #expect(snaps(from: .own) { $0.thick = true } == ["border-width"])
        #expect(snaps(from: .ownBlur) { $0.warm = true; $0.blurred = true } == ["border", "fill", "radius"])
    }
}

// MARK: - 7. Integration Parity (`motion_gate/tests.rs` — 7 tests)

@Suite("MotionGate Integration Parity Tests")
struct MotionGateIntegrationParityTests {
    private struct S {
        var right = false
        var shown = false
    }

    private func makeCell(_ change: (inout S, inout Tx) -> Void) -> MotionGateRecording {
        let rt = Runtime<S>(state: S(), viewport: Vec2(600, 400), pixelScale: 1.0, systemDark: true) { (s: S, _: inout Cx<S>) -> El<S> in
            let ink = oklch(0.6, 0.15, 25.0)
            let mover: El<S> = el().key("mover").size(100, 40).bg(ink).motion(Spring(duration: 0.3, bounce: 0.0))
            let moverPlaced = s.right ? mover.ml(300) : mover
            var page: El<S> = col().wFull().hFull().child(moverPlaced)
            if s.shown {
                page = page.child(el().key("box").size(100, 40).bg(ink))
            }
            return page
        }
        let r = MotionGateRun(rt, hz: 120.0)
        r.idle(0.5)
        r.step()
        r.act("change") { $0.update(change) }
        r.play(1.0)
        return r.rec
    }

    @Test("a_run_records_a_spring_as_clean_and_a_snap_as_a_jump")
    func aRunRecordsASpringAsCleanAndASnapAsAJump() {
        let spring = makeCell { s, _ in s.right = true }
        #expect(spring.frames == 122)
        let springFindings = motionGateCheck(spring)
        #expect(springFindings.isEmpty)

        let snap = makeCell { s, tx in s.right = true; tx.instant() }
        #expect(mgKinds(snap) == ["jump"])
    }

    @Test("a_box_that_mounts_with_no_transition_pops_in_unless_allowed")
    func aBoxThatMountsWithNoTransitionPopsInUnlessAllowed() {
        let rec = makeCell { s, tx in s.shown = true; tx.instant() }
        let findings = motionGateCheck(rec)
        #expect(findings.contains { $0.kind == "pop-in" && $0.element.contains("box") })
        let cells = [MotionGateCell(name: "show/wide", findings: findings, frames: rec.frames, skipped: false)]
        let open = MotionGateGate.report(cells, allow: [], listAllowed: false, secs: 0.0)
        #expect(open.failing > 0 && open.text.contains("pop-in") && open.text.contains("mounts at or above"))

        let allow: [MotionGateAllow] = [("pop-in", "box", "show/", "the box appears at once, by design")]
        let allowed = MotionGateGate.report(cells, allow: allow, listAllowed: true, secs: 0.0)
        #expect(allowed.failing == 0 && allowed.allowed == 1)
        #expect(allowed.text.contains("allowed") && allowed.text.contains("by design"))
        #expect(MotionGateGate.report(cells, allow: [("pop-in", "box", "narrow", "")], listAllowed: false, secs: 0.0).failing == 1)
    }

    @Test("allow_rows_cap_what_they_cover_and_report_when_unused")
    func allowRowsCapWhatTheyCoverAndReportWhenUnused() {
        func mkF(_ el: String) -> MotionGateFinding {
            MotionGateFinding(kind: "flash", element: el, frame: 3, detail: "")
        }
        let cells = [
            MotionGateCell(name: "island-auto/dark", findings: [mkF("plate"), mkF("plate")], frames: 10, skipped: false),
            MotionGateCell(name: "parks/dark", findings: [], frames: 10, skipped: false),
        ]
        let one = [MotionGateAllowRow("flash", "plate", "island-auto|island-click", "the plate's hand-off").max(1)]
        let r1 = MotionGateGate.reportRows(cells, rows: one, listAllowed: false, secs: 0.0)
        #expect((r1.failing, r1.allowed, r1.unused) == (1, 1, 0))
        #expect(r1.text.contains("past its allow row's max of 1"))

        let rows = [
            MotionGateAllowRow("", "plate", "island-auto", "any kind"),
            MotionGateAllowRow("jump", "x", "parks", "stale"),
            MotionGateAllowRow("jump", "x", "game", "not run"),
        ]
        let r2 = MotionGateGate.reportRows(cells, rows: rows, listAllowed: false, secs: 0.0)
        #expect((r2.failing, r2.allowed, r2.unused) == (0, 2, 1))
        #expect(r2.text.contains("unused allow row (\"jump\", \"x\", \"parks\")"))
    }

    @Test("run_keeps_the_filtered_cells_in_order_and_flags_one_that_recorded_nothing")
    func runKeepsTheFilteredCellsInOrderAndFlagsOneThatRecordedNothing() {
        let recRight = makeCell { s, _ in s.right = true }
        let recNarrow = makeCell { s, _ in s.right = true }
        let jobs: [(String, MotionGateGate.Job)] = [
            ("move/wide", { recRight }),
            ("move/narrow", { recNarrow }),
            ("empty/wide", { MotionGateRecording(size: (10, 10), hz: 120.0) }),
            ("show/wide", { fatalError("filtered out") }),
        ]
        let cells = MotionGateGate.run(jobs, filter: "m")
        #expect(cells.map(\.name) == ["move/wide", "move/narrow", "empty/wide"])
        #expect(cells[2].skipped && !cells[0].skipped)
        #expect(MotionGateGate.report(cells, allow: [], listAllowed: false, secs: 0.0).failing == 1)
    }

    @Test("an_app_that_runs_its_view_through_a_scroll_fails_the_gate")
    func anAppThatRunsItsViewThroughAScrollFailsTheGate() {
        struct Feed { var pollsChange: Bool }
        func scrollCell(pollsChange: Bool) -> MotionGateRecording {
            let rt = Runtime<Feed>(state: Feed(pollsChange: pollsChange), viewport: Vec2(400, 300), pixelScale: 1.0, systemDark: true) { (_: Feed, _: inout Cx<Feed>) -> El<Feed> in
                var rows: El<Feed> = col().wFull()
                for i in 0..<40 {
                    rows = rows.child(el().key("row\(i)").wFull().h(40).bg(oklch(0.3, 0.02, 250.0)))
                }
                return col().wFull().hFull().child(col().key("feed").wFull().h(300).scroll(stickBottom: false).child(rows))
            }
            rt.poll = { s, _, _ in s.pollsChange }
            let r = MotionGateRun(rt, hz: 120.0)
            r.idle(0.5)
            r.step()
            for _ in 0..<30 {
                r.act("wheel") { rt in rt.wheel(WheelEvent(dx: 0, dy: -12.0), at: Vec2(200, 150), now: rt.currentTime) }
            }
            r.play(0.5)
            return r.rec
        }

        let still = scrollCell(pollsChange: false)
        #expect(!mgKinds(still).contains("scroll-commit"), "Unexpected scroll-commit: \(motionGateCheck(still))")

        let busy = scrollCell(pollsChange: true)
        let f = motionGateCheck(busy).filter { $0.kind == "scroll-commit" }
        #expect(f.count == 1, "Expected 1 scroll-commit, got: \(f)")
        #expect(f.first?.detail.contains("(poll)") == true, "Expected (poll) cause, got: \(f)")
    }

    @Test("motion_inside_a_zoomed_scroll_is_judged_against_the_scroll")
    func motionInsideAZoomedScrollIsJudgedAgainstTheScroll() {
        struct Zoomed {
            var drop: Float
            var spring: Spring
            var down = false
        }
        func zoomedCell(drop: Float, spring: Spring) -> MotionGateRecording {
            let rt = Runtime<Zoomed>(state: Zoomed(drop: drop, spring: spring), viewport: Vec2(600, 600), pixelScale: 1.0, systemDark: true) { (s: Zoomed, _: inout Cx<Zoomed>) -> El<Zoomed> in
                let ink = oklch(0.6, 0.15, 25.0)
                var rows: El<Zoomed> = col().key("rows").wFull()
                for i in 0..<30 {
                    let row: El<Zoomed> = el().key("row\(i)").wFull().h(40).bg(ink).motion(s.spring)
                    rows = rows.child((i == 0 && s.down) ? row.mt(s.drop) : row)
                }
                return col().key("zoom").wFull().hFull().scale(1.6)
                    .child(col().key("feed").wFull().hFull().scroll(stickBottom: false).child(rows))
            }
            let r = MotionGateRun(rt, hz: 120.0)
            r.update { _, tx in tx.scrollTo("feed", offset: Vec2(0, 200), animated: false) }
            r.idle(0.5)
            r.step()
            r.update { s, tx in
                s.down = true
                tx.scrollTo("feed", offset: Vec2(0, 400), animated: true)
            }
            r.play(1.0)
            return r.rec
        }

        func pathFindings(_ rec: MotionGateRecording, kinds: Set<String>) -> [String] {
            motionGateCheck(rec).filter { kinds.contains($0.kind) }.map(\.description)
        }
        let glide = zoomedCell(drop: 60.0, spring: Spring(duration: 0.2, bounce: 0.0))
        let row12 = glide.tracks.first { $0.path.hasSuffix("row12") }
        #expect(row12 != nil)
        if let row12 {
            let onlyRises = zip(row12.frames, row12.frames.dropFirst()).allSatisfy { a, b in
                b.1.rect[1] <= a.1.rect[1] + 0.01
            }
            #expect(onlyRises, "on screen it only rises")
        }
        let turns = pathFindings(glide, kinds: ["reversal", "jiggle", "overshoot"])
        #expect(turns.isEmpty, "Unexpected turns: \(turns)")

        let wobble = zoomedCell(drop: 60.0, spring: Spring(duration: 0.3, bounce: 0.5))
        let wobbleTurns = pathFindings(wobble, kinds: ["reversal", "jiggle", "overshoot"])
        #expect(wobbleTurns.contains { $0.contains("row12") }, "Expected row12 turn, got: \(wobbleTurns)")
    }

    @Test("The motion recording measures the scroll carried through a turned viewport in window coordinates")
    func recordsCarriedScrollThroughTurnedViewport() throws {
        let rt = Runtime(state: (), viewport: Vec2(400, 400), pixelScale: 1) { _, _ in
            col().rotate(0.3).child(
                col().key("viewport").size(200, 200).scroll(stickBottom: false)
                    .child(el().key("content").size(200, 600))
            )
        }
        let run = MotionGateRun(rt)
        run.actUpdate("scroll") { _, tx in
            tx.scrollTo("viewport", offset: Vec2(0, 40), animated: false)
        }
        let content = try #require(rt.element(byKey: "content"))
        let track = try #require(run.rec.tracks.first { $0.path == content.path })
        let snap = try #require(track.frames.last?.1)
        #expect(abs(content.scrolled[0]) > 1)
        #expect(snap.scrolled == content.scrolled)
    }

    @Test("a_scroll_that_teleports_a_row_into_view_with_no_input_jumps")
    func aScrollThatTeleportsARowIntoViewWithNoInputJumps() {
        let jumpKinds: Set<String> = ["jump", "offset-jump", "jerk", "appear-then-jump"]
        func paddedJumps(_ scroll: (MotionGateRun<Int>) -> Void) -> [String] {
            let rt = Runtime<Int>(state: 0, viewport: Vec2(400, 400), pixelScale: 1.0, systemDark: true) { (_: Int, _: inout Cx<Int>) -> El<Int> in
                var rows: El<Int> = col().key("rows").wFull().pt(300)
                for i in 0..<20 {
                    rows = rows.child(el().key("row\(i)").wFull().h(40).bg(oklch(0.3, 0.02, 250.0)))
                }
                return col().wFull().hFull().child(col().key("list").wFull().h(300).scroll(stickBottom: false).child(rows))
            }
            let r = MotionGateRun(rt, hz: 120.0)
            r.idle(0.5)
            r.step()
            scroll(r)
            r.play(1.0)
            return r.finish().filter { jumpKinds.contains($0.kind) }.map(\.description)
        }

        let instant = paddedJumps { r in
            r.update { _, tx in tx.scrollTo("list", offset: Vec2(0, 40), animated: false) }
            r.step()
        }
        #expect(instant.count == 1, "Expected 1 jump, got: \(instant)")
        #expect(instant.first?.hasPrefix("jump") == true && instant.first?.contains("rows") == true, "Unexpected: \(instant)")

        let wheel = paddedJumps { r in
            for _ in 0..<4 {
                r.act("wheel") { rt in rt.wheel(WheelEvent(dx: 0, dy: -10.0), at: Vec2(200, 150), now: rt.currentTime) }
            }
        }
        #expect(wheel.isEmpty, "Unexpected wheel jumps: \(wheel)")

        let tapped = paddedJumps { r in
            r.act("tap") { rt in rt.update(at: rt.currentTime) { _, tx in tx.scrollTo("list", offset: Vec2(0, 40), animated: false) } }
        }
        #expect(tapped.isEmpty, "Unexpected tapped jumps: \(tapped)")

        let glide = paddedJumps { r in
            r.update { _, tx in tx.scrollTo("list", offset: Vec2(0, 40), animated: true) }
            r.step()
        }
        #expect(glide.isEmpty, "Unexpected glide jumps: \(glide)")
    }
}
