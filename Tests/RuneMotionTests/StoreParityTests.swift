import Foundation
import Testing
@testable import RuneMotion

private struct TestRng {
    private var state: UInt64

    init(_ seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(UInt64(1) << 24)
    }

    mutating func range(_ a: Float, _ b: Float) -> Float {
        a + (b - a) * next()
    }
}

@Suite("Store Parity Tests")
struct StoreParityTests {
    private let X = Prop<Float>.custom(64, .spatial, name: "x")
    private let N = NodeId(7)

    private func state(_ store: AnimationStore) -> (Float, Float) {
        (store.sample(N, X)!, store.sampleVelocity(N, X)!)
    }

    @Test("randomized_retargets_are_c1_continuous")
    func randomizedRetargetsAreC1Continuous() {
        for seed in UInt64(1)...8 {
            var rng = TestRng(seed)
            var store = AnimationStore()
            store.set(N, X, 0.0)
            var t: Double = 0.0
            for step in 0..<1500 {
                t += Double(rng.range(0.001, 0.06))
                store.setTime(t)
                if step % 3 == 0 {
                    store.tick()
                    let (x, v) = state(store)
                    #expect(abs(store.get(N, X)! - x) < 1e-3)
                    let gv: Float = store.velocity(N, X)!
                    #expect(abs(gv - v) < 1e-2)
                }
                let (x0, v0) = state(store)
                let target = rng.range(-500.0, 500.0)
                let kind = rng.next()
                let anim: Anim<Float>
                if kind < 0.6 {
                    anim = Anim(curve: .spring(Spring(duration: rng.range(0.1, 0.8), bounce: rng.range(-0.6, 0.7))))
                } else if kind < 0.85 {
                    anim = Anim(curve: .tween(duration: rng.range(0.05, 0.5), easing: .easeInOut))
                } else if kind < 0.93 {
                    anim = Anim(curve: .decay(.IOS_FAST))
                } else {
                    anim = Anim(curve: .spring(Spring(duration: rng.range(0.1, 0.8), bounce: 0.0))).additive()
                }
                store.animate(N, X, to: target, anim: anim)
                let (x1, v1) = state(store)
                let scale = 1.0 + max(abs(x0), abs(v0)) * 1e-5
                #expect(abs(x1 - x0) < 2e-3 * scale, "seed \(seed) step \(step): position jumped \(x0) -> \(x1)")
                #expect(
                    abs(v1 - v0) < 2e-2 * max(scale, 1.0 + abs(v0) * 1e-4),
                    "seed \(seed) step \(step): velocity jumped \(v0) -> \(v1)"
                )
            }
            store.tickAt(t + 200.0)
            store.tickAt(t + 200.1)
            #expect(store.activeLen == 0)
            let finalVel: Float? = store.velocity(N, X)
            #expect(finalVel == 0.0)
        }
    }

    @Test("additive_springs_equal_merged_springs")
    func additiveSpringsEqualMergedSprings() {
        let s = MotionTokens.REFLOW
        var merged = AnimationStore()
        var added = AnimationStore()
        merged.set(N, X, 0.0)
        added.set(N, X, 0.0)
        var rng = TestRng(42)
        var t: Double = 0.0
        for step in 0..<12 {
            let target = rng.range(-300.0, 300.0)
            merged.setTime(t)
            added.setTime(t)
            let before = state(added)
            merged.animate(N, X, to: target, anim: Anim.spring(s).merge())
            added.animate(N, X, to: target, anim: Anim.spring(s).additive())
            let afterRetarget = state(added)
            if step >= 8 {
                #expect(abs(afterRetarget.0 - before.0) < 1e-4)
                #expect(abs(afterRetarget.1 - before.1) < 1e-4)
            }
            for k in 0..<40 {
                let tt = t + Double(k) * 0.002
                merged.setTime(tt)
                added.setTime(tt)
                let a = state(merged)
                let b = state(added)
                #expect(abs(a.0 - b.0) < 2e-3)
                #expect(abs(a.1 - b.1) < 5e-2)
            }
            t += Double(rng.range(0.03, 0.2))
        }
    }

    @Test("unchanged_target_keeps_the_trajectory")
    func unchangedTargetKeepsTheTrajectory() {
        var a = AnimationStore()
        var b = AnimationStore()
        a.set(N, X, 0.0)
        a.animate(N, X, to: 100.0, anim: .spring(MotionTokens.SETTLE))
        b.set(N, X, 0.0)
        b.animate(N, X, to: 100.0, anim: .spring(MotionTokens.SETTLE))

        let idB = b.trackId(N, X)!
        let epochBefore = b.epoch(idB)
        b.setTime(0.1)
        b.animate(N, X, to: 100.0, anim: .spring(MotionTokens.DRIFT))
        #expect(b.epoch(idB) == epochBefore)

        for k in 1..<60 {
            let t = Double(k) / 120.0
            a.setTime(t)
            b.setTime(t)
            let sa = state(a)
            let sb = state(b)
            #expect(sa.0 == sb.0 && sa.1 == sb.1)
        }
    }

    @Test("delays_hold_then_start_exactly_and_newer_animations_cancel_them")
    func delaysHoldThenStartExactlyAndNewerCancelThem() {
        var s = AnimationStore()
        s.set(N, X, 0.0)
        s.animate(N, X, to: 100.0, anim: Anim.spring(MotionTokens.SETTLE).delay(0.1))
        s.tickAt(0.05)
        #expect(s.get(N, X) == 0.0)
        let fv: Float? = s.velocity(N, X)
        #expect(fv == 0.0)
        s.tickAt(0.1 + 0.15)
        let expect = MotionTokens.SETTLE.sample(from: 0.0, velocity: 0.0, target: 100.0, at: 0.15).position
        #expect(abs(s.get(N, X)! - expect) < 1e-3)

        s.animate(N, X, to: -100.0, anim: Anim.spring(MotionTokens.SETTLE).delay(0.2))
        s.setTime(0.3)
        s.animate(N, X, to: 50.0, anim: .spring(MotionTokens.SETTLE))
        s.tickAt(10.0)
        #expect(s.get(N, X) == 50.0)
        #expect(s.target(N, X) == 50.0)
    }

    @Test("a_due_delayed_start_keeps_its_immediate_wake_until_ticked")
    func dueDelayedStartKeepsImmediateWakeUntilTicked() {
        var s = AnimationStore()
        s.set(N, X, 0.0)
        s.animate(N, X, to: 100.0, anim: Anim.spring(MotionTokens.SETTLE).delay(1.0))
        s.setTime(1.0)
        #expect(s.running)
        #expect(s.waitingUntil() == 1.0)
        s.setTime(1.25)
        #expect(s.waitingUntil() == 1.25)
        #expect(s.get(N, X) == 0.0)
        s.tick()
        #expect(s.get(N, X)! > 0.0)
    }

    @Test("set_is_immediate_and_first_animate_doesnt_animate")
    func setIsImmediateAndFirstAnimateDoesntAnimate() {
        var s = AnimationStore()
        s.animate(N, X, to: 40.0, anim: .spring(MotionTokens.SETTLE))
        s.tickAt(0.0)
        #expect(s.get(N, X) == 40.0)
        #expect(!s.isAnimating(N, X))
        s.animate(N, X, to: 80.0, anim: .spring(MotionTokens.SETTLE))
        s.tickAt(0.05)
        #expect(s.isAnimating(N, X))
        s.set(N, X, 10.0)
        s.tickAt(0.06)
        #expect(s.get(N, X) == 10.0)
        #expect(!s.isAnimating(N, X))
    }

    @Test("settle_and_completion_events")
    func settleAndCompletionEvents() {
        var s = AnimationStore()
        s.set(N, X, 0.0)
        s.animate(N, X, to: 1.0, anim: Anim.spring(MotionTokens.SNAP).completion(11))
        s.setTime(0.05)
        s.animate(N, X, to: 2.0, anim: Anim.spring(MotionTokens.SNAP).completion(12))
        var events: [MotionEvent] = []
        for k in 0..<400 {
            s.tickAt(0.05 + Double(k) / 120.0)
            events.append(contentsOf: s.events)
        }
        let completed: [(UInt64, Bool)] = events.compactMap {
            if case let .completed(token, _, _, finished) = $0 { return (token, finished) }
            return nil
        }
        #expect(completed.count == 2)
        #expect(completed[0] == (11, false))
        #expect(completed[1] == (12, true))
        let settles = events.filter {
            if case .settled = $0 { return true }
            return false
        }.count
        #expect(settles == 1)
        #expect(s.get(N, X) == 2.0)
        #expect(s.activeLen == 0)
    }

    @Test("removing_an_animating_track_completes_it_unfinished")
    func removingAnimatingTrackCompletesUnfinished() {
        func completions(_ s: AnimationStore) -> [(UInt64, Bool)] {
            s.events.compactMap {
                if case let .completed(token, _, _, finished) = $0 { return (token, finished) }
                return nil
            }
        }
        var s = AnimationStore()
        s.set(N, X, 0.0)
        s.animate(N, X, to: 1.0, anim: Anim.spring(MotionTokens.SNAP).completion(21))
        s.tickAt(0.02)
        #expect(s.isAnimating(N, X))
        s.removeNode(N)
        s.tickAt(0.03)
        let c1 = completions(s)
        #expect(c1.count == 1 && c1[0] == (21, false))

        s.set(N, X, 0.0)
        s.animate(N, X, to: 1.0, anim: Anim.spring(MotionTokens.SNAP).completion(22))
        s.tickAt(0.04)
        s.remove(N, X)
        s.tickAt(0.05)
        let c2 = completions(s)
        #expect(c2.count == 1 && c2[0] == (22, false))

        s.set(N, X, 0.0)
        s.animate(N, X, to: 1.0, anim: Anim.spring(MotionTokens.SNAP).completion(23))
        var done: [(UInt64, Bool)] = []
        for k in 0..<400 {
            s.tickAt(0.06 + Double(k) / 120.0)
            done.append(contentsOf: completions(s))
        }
        s.removeNode(N)
        s.tickAt(10.0)
        done.append(contentsOf: completions(s))
        #expect(done.count == 1 && done[0] == (23, true))
    }

    @Test("fling_into_a_bound_hands_off_velocity_smoothly")
    func flingIntoBoundHandsOffVelocitySmoothly() {
        var s = AnimationStore()
        s.set(N, X, 0.0)
        s.release(N, X, velocity: 3000.0, how: .decayClamped(decay: .IOS_NORMAL, min: 0.0, max: 500.0, spring: MotionTokens.GLIDE))
        var prev = state(s)
        var maxDv: Float = 0.0
        let dt = 1.0 / 2000.0
        for k in 1..<8000 {
            s.tickAt(Double(k) * dt)
            let curV: Float = s.velocity(N, X)!
            let cur = (s.get(N, X)!, curV)
            maxDv = max(maxDv, abs(cur.1 - prev.1))
            prev = cur
        }
        #expect(maxDv < 60.0)
        #expect(s.get(N, X) == 500.0)
    }

    @Test("rubber_band_then_spring_back")
    func rubberBandThenSpringBack() {
        var s = AnimationStore()
        let over = Gesture.rubberBandClamp(-120.0, min: 0.0, max: 500.0, dimension: 800.0)
        #expect(over < 0.0 && over > -120.0 * 0.55)
        s.set(N, X, over)
        s.release(N, X, velocity: 0.0, how: .decayClamped(decay: .IOS_NORMAL, min: 0.0, max: 500.0, spring: MotionTokens.GLIDE))
        s.tickAt(5.0)
        s.tickAt(5.1)
        #expect(s.get(N, X) == 0.0)
    }

    @Test("reduced_motion_maps_by_property_class")
    func reducedMotionMapsByPropertyClass() {
        var s = AnimationStore()
        s.setReducedMotion(true)
        s.set(N, Props.OFFSET, .zero)
        s.set(N, Props.OPACITY, 0.0)
        s.set(N, Props.BLUR_SCALAR, 4.0)
        s.animate(N, Props.OFFSET, to: Vec2(100.0, 0.0), anim: .spring(MotionTokens.GLIDE))
        s.animate(N, Props.OPACITY, to: 1.0, anim: .spring(MotionTokens.GLIDE))
        s.animate(N, Props.BLUR_SCALAR, to: 0.0, anim: .spring(MotionTokens.GLIDE))
        s.tickAt(0.0)
        #expect(s.get(N, Props.OFFSET) == Vec2(100.0, 0.0))
        #expect(s.get(N, Props.BLUR_SCALAR) == 0.0)
        s.tickAt(0.09)
        let o = s.get(N, Props.OPACITY)!
        #expect(o > 0.3 && o < 0.7)
        s.tickAt(0.18)
        #expect(s.get(N, Props.OPACITY) == 1.0)

        s.set(N, Props.SCROLL, .zero)
        s.release(N, Props.SCROLL, velocity: Vec2(0.0, 1000.0), how: .decay(.IOS_NORMAL))
        s.tickAt(0.3)
        #expect(s.get(N, Props.SCROLL)!.y > 50.0)
    }

    @Test("multi_lane_values_share_timing")
    func multiLaneValuesShareTiming() {
        func refDecode(_ c: Float) -> Float {
            c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        func refEncode(_ c: Float) -> Float {
            let x = max(0, min(1, c))
            return x <= 0.0031308 ? x * 12.92 : 1.055 * powf(x, 1.0 / 2.4) - 0.055
        }
        func refToOKLab(_ col: MotionColor) -> (Float, Float, Float) {
            let r = refDecode(col.r)
            let g = refDecode(col.g)
            let b = refDecode(col.b)
            let l = cbrtf(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrtf(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrtf(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            return (
                0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
            )
        }
        func refFromOKLab(_ L: Float, _ a: Float, _ b: Float) -> (Float, Float, Float) {
            let l_ = L + 0.3963377774 * a + 0.2158037573 * b
            let m_ = L - 0.1055613458 * a - 0.0638541728 * b
            let s_ = L - 0.0894841775 * a - 1.2914855480 * b
            let l = l_ * l_ * l_
            let m = m_ * m_ * m_
            let s = s_ * s_ * s_
            return (
                refEncode(+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                refEncode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                refEncode(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
            )
        }

        // Verify sRGB->OKLab on mid-grey (#808080 -> L ~ 0.60, not linear 0.795) and 1e-6 alpha cutoff.
        let grayLab = MotionColor.hex(0x808080).toOKLab()
        #expect(abs(grayLab.L - 0.5999) < 2e-3)
        let cut = MotionColor.fromLanes(MotionLanes(0.5e-6, 0, 0, 0.5e-6))
        #expect(cut == MotionColor(r: 0, g: 0, b: 0, a: 0))
        let aboveCut = MotionColor.fromLanes(MotionLanes(2e-6, 0, 0, 2e-6))
        #expect(aboveCut.a > 0)

        // Verify Sides toLanes/fromLanes follows LTRB [left, top, right, bottom].
        let sides = Sides(top: 1, right: 2, bottom: 3, left: 4)
        #expect(sides.toLanes() == MotionLanes(4, 1, 2, 3))
        #expect(Sides.fromLanes(sides.toLanes()) == sides)

        var s = AnimationStore()
        let red = MotionColor(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let blue = MotionColor(r: 0.0, g: 0.0, b: 1.0, a: 1.0)
        s.set(N, Props.FILL, red)
        s.animate(N, Props.FILL, to: blue, anim: .spring(MotionTokens.SETTLE))
        s.tickAt(0.15)
        let mid = s.get(N, Props.FILL)!
        let p = MotionTokens.SETTLE.sample(from: 0.0, velocity: 0.0, target: 1.0, at: 0.15).position
        let a = refToOKLab(red)
        let b = refToOKLab(blue)
        let wantRGB = refFromOKLab(
            a.0 + (b.0 - a.0) * p,
            a.1 + (b.1 - a.1) * p,
            a.2 + (b.2 - a.2) * p
        )
        #expect(abs(mid.r - wantRGB.0) < 2e-3)
        #expect(abs(mid.g - wantRGB.1) < 2e-3)
        #expect(abs(mid.b - wantRGB.2) < 2e-3)
        #expect(abs(mid.a - 1.0) < 2e-3)
        s.tickAt(5.0)
        let end = s.get(N, Props.FILL)!
        #expect(abs(end.b - 1.0) < 1e-3 && end.r < 1e-3)
    }

    @Test("retune_respring_keeps_position_and_velocity")
    func retuneRespringKeepsPositionAndVelocity() {
        var s = AnimationStore()
        s.set(N, X, 0.0)
        s.animate(N, X, to: 100.0, anim: .spring(MotionTokens.DRIFT))
        s.setTime(0.2)
        let before = state(s)
        s.tick()
        s.retune(old: MotionTokens.DRIFT, new: MotionTokens.SNAP)
        let after = state(s)
        #expect(abs(before.0 - after.0) < 1e-3 && abs(before.1 - after.1) < 1e-2)
        s.tickAt(0.2 + Double(MotionTokens.SNAP.settlingDuration(epsilon: 1e-4)) + 0.1)
        #expect(s.get(N, X) == 100.0)
    }

    @Test("removing_and_reusing_tracks_is_generational")
    func removingAndReusingTracksIsGenerational() {
        var s = AnimationStore()
        let a = s.set(NodeId(1), X, 1.0)
        s.removeNode(NodeId(1))
        #expect(!s.contains(a))
        let b = s.set(NodeId(2), X, 2.0)
        #expect(s.contains(b) && !s.contains(a))
        #expect(s.get(NodeId(2), X) == 2.0)
        #expect(s.get(NodeId(1), X) == nil)
    }

    @Test("a_removed_track_leaves_touched_even_when_its_slot_is_reused")
    func removedTrackLeavesTouchedEvenWhenSlotIsReused() {
        var s = AnimationStore()
        s.set(NodeId(1), X, 1.0)
        s.set(NodeId(3), X, 3.0)
        s.tick()
        #expect(s.touched().map { $0.0.rawValue } == [1, 3])
        s.removeNode(NodeId(1))
        #expect(s.touched().map { $0.0.rawValue } == [3])
        s.set(NodeId(1), X, 1.0)
        s.removeNode(NodeId(1))
        s.set(NodeId(2), X, 2.0)
        s.tick()
        #expect(s.touched().map { $0.0.rawValue } == [2])
    }

    @Test("node_time_scale_holds_slows_and_resumes_in_place")
    func nodeTimeScaleHoldsSlowsAndResumesInPlace() {
        let M = NodeId(8)
        var s = AnimationStore()
        s.set(N, X, 0.0)
        s.set(M, X, 0.0)
        s.setNodeTimeScale(M, 0.5)
        s.animate(N, X, to: 100.0, anim: .spring(MotionTokens.SETTLE))
        s.animate(M, X, to: 100.0, anim: Anim.spring(MotionTokens.SETTLE).delay(0.1))
        s.tickAt(0.1)
        let reference = s.get(N, X)!
        #expect(s.get(M, X) == 0.0)
        s.tickAt(0.4)
        #expect(abs(s.get(M, X)! - reference) < 1e-3)

        s.setNodeTimeScale(N, 0.0)
        s.setNodeTimeScale(M, 0.0)
        let held = (s.get(N, X)!, s.get(M, X)!)
        s.tickAt(5.0)
        #expect(s.get(N, X) == held.0 && s.get(M, X) == held.1)
        #expect(!s.running && s.activeLen == 2)

        s.setNodeTimeScale(M, 1.0)
        s.tick()
        #expect(s.get(M, X) == held.1)
        #expect(s.running)
        s.tickAt(5.15)
        let expect = MotionTokens.SETTLE.sample(from: 0.0, velocity: 0.0, target: 100.0, at: 0.25).position
        #expect(abs(s.get(M, X)! - expect) < 1e-3)
        #expect(s.nodeTimeScale(N) == 0.0)
        #expect(s.nodeTimeScale(M) == 1.0)
    }

    @Test("a_delayed_start_holds_its_first_pose_for_the_delay_and_running_motion_keeps_time")
    func delayedStartHoldsFirstPoseAndRunningKeepsTime() {
        let spring = Spring(duration: 0.4, bounce: 0.0)
        let old = NodeId(1)
        let new = NodeId(2)
        var s = AnimationStore()
        s.set(old, X, 0.0)
        s.set(new, X, 0.0)
        s.animate(old, X, to: 100.0, anim: .spring(spring))
        s.tickAt(0.1)
        s.animate(new, X, to: 100.0, anim: .spring(spring))
        s.tickAt(0.11)
        let first = s.get(new, X)!
        var started = s.started()
        #expect(started.count == 1)
        started.append(contentsOf: started)
        s.delay(&started, by: 0.05)
        s.tickAt(0.17)
        #expect(s.started().isEmpty)

        var reference = AnimationStore()
        reference.set(new, X, 0.0)
        reference.setTime(0.1)
        reference.animate(new, X, to: 100.0, anim: .spring(spring))
        reference.tickAt(0.12)
        #expect(abs(s.get(new, X)! - reference.get(new, X)!) < 1e-4, "held first pose \(first)")

        var steady = AnimationStore()
        steady.set(old, X, 0.0)
        steady.animate(old, X, to: 100.0, anim: .spring(spring))
        steady.tickAt(0.17)
        #expect(abs(s.get(old, X)! - steady.get(old, X)!) < 1e-4)
    }

    @Test("keyframes_hit_values_and_keep_velocity_through_cubics")
    func keyframesHitValuesAndKeepVelocityThroughCubics() {
        var s = AnimationStore()
        s.set(N, X, 0.0)
        let kf = Keyframes<Float>()
            .linear(10.0, duration: 0.1)
            .cubic(30.0, duration: 0.2)
            .cubic(20.0, duration: 0.2)
            .cubic(40.0, duration: 0.2)
            .spring(0.0, MotionTokens.SETTLE)
        s.playKeyframes(N, X, kf)

        func at(_ t: Double) -> (Float, Float) {
            s.tickAt(t)
            return (s.get(N, X)!, s.velocity(N, X)!)
        }

        #expect(abs(at(0.05).0 - 5.0) < 1e-3)
        #expect(abs(at(0.1).0 - 10.0) < 1e-3)
        #expect(abs(at(0.3).0 - 30.0) < 1e-3)
        let before = at(0.5 - 1e-4).1
        let after = at(0.5 + 1e-4).1
        #expect(abs(before - after) < 0.5)
        #expect(abs(at(0.7).0 - 40.0) < 1e-3)
        _ = at(3.0)
        #expect(at(3.1).0 == 0.0)
    }

    @Test("unchanged_target_keeps_the_trajectory")
    func unchangedTargetKeepsTrajectory() {
        var a = AnimationStore()
        var b = AnimationStore()
        a.set(N, X, 0.0)
        b.set(N, X, 0.0)
        a.animate(N, X, to: 100.0, anim: .spring(MotionTokens.SETTLE))
        b.animate(N, X, to: 100.0, anim: .spring(MotionTokens.SETTLE))
        b.setTime(0.1)
        b.animate(N, X, to: 100.0, anim: .spring(MotionTokens.DRIFT))
        for k in 1..<60 {
            let t = Double(k) / 120.0
            a.setTime(t)
            b.setTime(t)
            #expect(a.sample(N, X) == b.sample(N, X))
            #expect(a.sampleVelocity(N, X) == b.sampleVelocity(N, X))
        }
    }

    @Test("set_is_immediate_and_first_animate_doesnt_animate")
    func setIsImmediateAndFirstAnimateDoesNotAnimate() {
        var s = AnimationStore()
        s.animate(N, X, to: 40.0, anim: .spring(MotionTokens.SETTLE))
        s.tickAt(0.0)
        #expect(s.get(N, X) == 40.0)
        #expect(!s.isAnimating(N, X))
        s.animate(N, X, to: 80.0, anim: .spring(MotionTokens.SETTLE))
        s.tickAt(0.05)
        #expect(s.isAnimating(N, X))
        s.set(N, X, 10.0)
        s.tickAt(0.06)
        #expect(s.get(N, X) == 10.0)
        #expect(!s.isAnimating(N, X))
    }

    @Test("a_removed_track_leaves_touched_even_when_its_slot_is_reused")
    func removedTrackLeavesTouchedWhenSlotReused() {
        var s = AnimationStore()
        s.set(NodeId(1), X, 1.0)
        s.set(NodeId(3), X, 3.0)
        s.tick()
        func touchedNodes(_ store: AnimationStore) -> [UInt64] {
            store.touchedTracks().map { $0.1.rawValue }
        }
        #expect(touchedNodes(s) == [1, 3])
        s.removeNode(NodeId(1))
        #expect(touchedNodes(s) == [3])
        s.set(NodeId(1), X, 1.0)
        s.removeNode(NodeId(1))
        s.set(NodeId(2), X, 2.0)
        s.tick()
        #expect(touchedNodes(s) == [2])
    }

    @Test("a_cue_on_a_frozen_step_waits_and_scaled_steps_keep_one_clock")
    func cueOnFrozenStepWaitsAndScaledStepsKeepOneClock() {
        let a = NodeId(1)
        let b = NodeId(2)
        var store = AnimationStore()
        store.set(a, Props.OPACITY, 0.0)
        store.set(b, Props.OPACITY, 0.0)
        store.setNodeTimeScale(a, 0.0)
        var ch = Choreography()
        let s1 = ch.step(.now()) { s in
            s.animate(a, Props.OPACITY, to: 1.0, anim: .spring(MotionTokens.SETTLE))
        }
        let s2 = ch.step(.arrived(s1)) { s in
            s.animate(b, Props.OPACITY, to: 1.0, anim: .spring(MotionTokens.SETTLE))
        }
        for i in 0...240 {
            store.setTime(Double(i) / 120.0)
            if i == 120 { store.setNodeTimeScale(a, 1.0) }
            ch.tick(store: &store)
            store.tick()
            if i == 119 {
                #expect(ch.startTime(of: s2) == nil)
            }
        }
        #expect(abs((ch.startTime(of: s2) ?? -99) - 1.3) < 1e-3)
        #expect(store.get(b, Props.OPACITY) == 1.0)

        var store2 = AnimationStore()
        for n in [a, b] {
            store2.set(n, Props.OPACITY, 0.0)
            store2.setNodeTimeScale(n, 0.5)
        }
        var ch2 = Choreography()
        let ss1 = ch2.step(.now()) { s in
            s.animate(a, Props.OPACITY, to: 1.0, anim: .spring(MotionTokens.SETTLE))
        }
        _ = ch2.step(.arrived(ss1)) { s in
            s.animate(b, Props.OPACITY, to: 1.0, anim: .spring(MotionTokens.SETTLE))
        }
        var aAt: Float = 0
        var bAt: Float = 0
        for i in 0...120 {
            store2.setTime(Double(i) / 120.0)
            ch2.tick(store: &store2)
            store2.tick()
            if i == 24 { aAt = store2.get(a, Props.OPACITY)! }
            if i == 96 { bAt = store2.get(b, Props.OPACITY)! }
        }
        #expect(aAt > 0.05 && abs(aAt - bAt) < 1e-3)
    }

    @Test("a_once_phase_animator_waits_for_rest_and_stops_on_its_last_phase")
    func oncePhaseAnimatorWaitsForRestAndStopsOnLastPhase() {
        let n = NodeId(1)
        var store = AnimationStore()
        var ph = ChoreographyPhaseAnimator()
            .phase { $0.animate(n, Props.UNIFORM_SCALE, to: 1.0, anim: .spring(MotionTokens.SETTLE)) }
            .phase { $0.animate(n, Props.UNIFORM_SCALE, to: 1.04, anim: .spring(MotionTokens.SETTLE)) }
            .phase { $0.animate(n, Props.UNIFORM_SCALE, to: 0.98, anim: .spring(MotionTokens.SETTLE)) }
            .advanceOn(.settled)
            .hold(0.1)
            .once()
        var phases: [Int] = []
        var moving: [Bool] = []
        for i in 0...600 {
            store.setTime(Double(i) / 120.0)
            ph.tick(store: &store)
            store.tick()
            phases.append(ph.currentIndex)
            moving.append(store.isAnimating(n, Props.UNIFORM_SCALE))
        }
        let switches = (1..<phases.count).filter { phases[$0] != phases[$0 - 1] }
        #expect(switches.count == 1)
        let k = switches[0]
        #expect(phases[k] == 2)
        #expect(moving[..<(k - 12)].contains(true) && moving[(k - 12)..<k].allSatisfy { !$0 })
        #expect(store.get(n, Props.UNIFORM_SCALE) == 0.98)
        #expect(store.activeLen == 0)
    }

    @Test("a_phase_started_frozen_advances_after_resuming")
    func phaseStartedFrozenAdvancesAfterResuming() {
        var store = AnimationStore()
        let n = NodeId(1)
        store.setNodeTimeScale(n, 0.0)
        var ph = ChoreographyPhaseAnimator()
            .phase { $0.animate(n, Props.UNIFORM_SCALE, to: 1.0, anim: .spring(MotionTokens.SETTLE)) }
            .phase { $0.animate(n, Props.UNIFORM_SCALE, to: 1.04, anim: .spring(MotionTokens.SETTLE)) }
        var phases: [Int] = []
        for i in 0...480 {
            store.setTime(Double(i) / 120.0)
            if i == 120 { store.setNodeTimeScale(n, 1.0) }
            ph.tick(store: &store)
            store.tick()
            phases.append(ph.currentIndex)
        }
        func countSwitches(_ slice: ArraySlice<Int>) -> Int {
            zip(slice, slice.dropFirst()).filter { $0 != $1 }.count
        }
        #expect(countSwitches(phases[1..<120]) == 0)
        #expect(countSwitches(phases[120...]) >= 8)
    }

    @Test("the_none_spring_is_an_instant_curve_everywhere_a_spring_converts")
    func noneSpringIsInstantEverywhere() {
        #expect(Curve.from(Spring.none) == .instant)
        #expect(Anim<Float>(spring: .none).curve == .instant)
        #expect(Anim<Float>(SpringPair.none).curve == .instant)
        #expect(PropClass.presence.forReducedMotion(Curve.from(Spring.none)) == .instant)
        let t = Transition.none
        #expect(t.insertion == .identity && t.removal == .identity && t.springs == .none)
        #expect(Curve.from(Spring(duration: 0.001, bounce: 0.0)) == .spring(Spring(duration: 0.001, bounce: 0.0)))
    }

    @Test("animated_retarget_golden")
    func animatedRetargetGolden() {
        let anchors = [0, 1, 3, 9, 21, 39]
        let samples: [[[Float]]] = [
            [
                [30.078003, 7.5296297, -800.0, 400.0],
                [15.205883, 12.992083, -426.75085, 80.23154],
                [3.2957265, 11.149232, -112.73632, -93.2812],
                [-0.20551914, 1.577376, 1.509766, -24.364733],
                [-0.0026638499, 0.009844182, 0.045319706, -0.1750176],
                [0.0, 0.0, 0.0, 0.0],
            ],
            [
                [56.422695, -0.41329098, -800.0, 400.0],
                [38.957146, 7.563013, -600.40234, 244.27997],
                [17.499737, 14.067252, -277.22702, 37.680252],
                [11.163436, 5.5244317, 65.7598, -71.8772],
                [20.527206, -0.43597618, -1.4065659, 3.7947469],
                [19.988346, 0.0052623716, 0.1345897, -0.10417824],
            ],
            [
                [48.35736, 7.3219295, -800.0, 400.0],
                [30.425076, 14.737576, -593.33307, 237.03568],
                [11.4471245, 21.428228, -188.11761, 41.604954],
                [29.531113, 6.3093452, 231.20714, -141.46454],
                [40.0, 0.0, 0.0, -0.0],
                [40.0, 0.0, 0.0, -0.0],
            ],
            [
                [111.8616, -21.43715, -800.0, 400.0],
                [92.35385, -11.683273, -760.94543, 380.47272],
                [56.148865, 6.41922, -688.46295, 344.23148],
                [-33.05693, 51.022118, -509.8728, 254.9364],
                [-148.05019, 108.518745, -279.6561, 139.82805],
                [-230.99655, 149.99193, -113.5973, 56.79865],
            ],
            [
                [80.0, 0.0, 0.0, 0.0],
                [80.0, 0.0, 0.0, 0.0],
                [80.0, 0.0, 0.0, 0.0],
                [80.0, 0.0, 0.0, 0.0],
                [80.0, 0.0, 0.0, 0.0],
                [80.0, 0.0, 0.0, 0.0],
            ],
        ]
        let targets: [[Float]] = [[0.0, 0.0], [20.0, 0.0], [40.0, 0.0], [-287.7384, 178.36285], [80.0, 0.0]]
        func close(_ got: Float, _ want: Float) -> Bool {
            // `MotionMath` deterministic polynomials have ~3e-7 error vs libm over ~60pt jumps (~6e-6 at zero crossings).
            abs(got - want) <= 1e-5 + 1e-6 * abs(want)
        }
        let tween = Curve.tween(duration: 0.3, easing: .easeOut)
        let curves: [Curve] = [
            .spring(MotionTokens.GLIDE),
            .spring(Spring(duration: 0.5, bounce: 0.3)),
            tween,
            .decay(.IOS_NORMAL),
            .instant,
        ]
        for (n, c) in curves.enumerated() {
            var a = Animated<Vec2>(Vec2(0.0, 10.0), propClass: .other, pixelScale: 2.0)
            a.animateTo(Vec2(100.0, -40.0), anim: .spring(MotionTokens.SNAP), at: 0.0)
            a.animateTo(Vec2(-30.0, 60.0), anim: Anim(curve: c), at: 0.07)
            a.animateTo(Vec2(5.0, 5.0), anim: Anim(curve: c).velocity(.uniform(250.0)), at: 0.13)
            a.release(velocity: Vec2(-800.0, 400.0), target: Vec2(Float(20 * n), 0.0), curve: c, at: 0.2)
            for (i, k) in anchors.enumerated() {
                let t = 0.2 + Double(k) * 0.025
                let x = a.sample(at: t)
                let v = a.velocity(at: t)
                let got = [x.x, x.y, v.x, v.y]
                for j in 0..<4 {
                    #expect(close(got[j], samples[n][i][j]), "curve \(n) sample \(k) field \(j): \(got[j]) vs \(samples[n][i][j])")
                }
            }
            let tg = a.target
            #expect(close(tg.x, targets[n][0]) && close(tg.y, targets[n][1]))
        }
    }

    @Test("clock_parity_display_seek_and_manual")
    func clockParityDisplaySeekAndManual() {
        var c = Clock.display()
        #expect(c.frame(host: 100.0) == 0.0)
        #expect(abs(c.frame(host: 101.0) - 1.0) < 1e-12)
        c.setScale(0.5, realNow: 101.0)
        #expect(abs(c.frame(host: 101.0) - 1.0) < 1e-12)
        #expect(abs(c.frame(host: 103.0) - 2.0) < 1e-12)
        c.pause(realNow: 103.0)
        #expect(abs(c.frame(host: 110.0) - 2.0) < 1e-12)
        c.resume(realNow: 110.0)
        #expect(abs(c.frame(host: 112.0) - 3.0) < 1e-12)

        var c2 = Clock.display()
        c2.pause(realNow: 5.0)
        #expect(c2.frame(host: 7.0) == 0.0)
        c2.resume(realNow: 9.0)
        #expect(abs(c2.frame(host: 10.0) - 1.0) < 1e-12)
        c2.seek(to: 4.0)
        #expect(c2.timeAt(realNow: 50.0) == 4.0)
        #expect(c2.frame(host: 50.0) == 4.0)
        #expect(abs(c2.frame(host: 50.5) - 4.5) < 1e-12)
        c2.pause(realNow: 50.5)
        c2.seek(to: 2.0)
        #expect(c2.frame(host: 60.0) == 2.0)
        c2.resume(realNow: 60.0)
        #expect(abs(c2.frame(host: 61.0) - 3.0) < 1e-12)

        var m = Clock.manual(hz: 60.0)
        #expect(m.frame(host: 100.0) == 0.0)
        #expect(m.frame(host: 101.0) == 0.0)
        m.setScale(0.5, realNow: 102.0)
        m.pause(realNow: 103.0)
        m.resume(realNow: 200.0)
        #expect(abs(m.step() - 0.5 / 60.0) < 1e-12)
        #expect(m.timeAt(realNow: 300.0) == m.now)

        var m2 = Clock.manual(hz: 120.0)
        for _ in 0..<120 { _ = m2.step() }
        #expect(abs(m2.now - 1.0) < 1e-9)
    }

    @Test("quality_jittered_sampling_and_retarget_audit_stay_bounded")
    func qualityJitteredSamplingAndRetargetAuditStayBounded() {
        var scene = Scene()
        scene.store.auditRetargets(true)
        scene.insert(NodeId(1), NodeSpec(MotionRect.fromXYWH(0, 0, 200, 200)), .initial)
        scene.insert(NodeId(2), NodeSpec(MotionRect.fromXYWH(10, 10, 50, 50)).parent(NodeId(1)), .initial)
        _ = scene.frameAt(0.0)
        var now = 0.0
        var seed: UInt32 = 7
        for i in 0..<300 {
            seed = seed &* 1664525 &+ 1013904223
            now += 1.0 / 120.0 + Double(seed % 12000) / 1e6
            scene.setTime(now)
            if i % 7 == 0 {
                let x = Float(seed % 300)
                scene.setFrame(NodeId(1), MotionRect.fromXYWH(x, x / 2.0, 200, 200), Spring(duration: 0.4, bounce: 0.0))
                scene.setFrame(NodeId(2), MotionRect.fromXYWH(x / 4.0, x / 3.0, 50, 50), Spring(duration: 0.3, bounce: 0.0))
            }
            _ = scene.frame()
            let (samples, err) = scene.samplingError()
            #expect(samples == 8)
            #expect(err < 0.016)
        }
        let audit = scene.store.takeRetargetAudit()
        #expect(audit.lanes > 100)
        #expect(audit.maxVelocityError < 0.001)
    }

    @Test("math_full_range_exp_and_sin_cos_match_std")
    func mathFullRangeExpAndSinCosMatchStd() {
        var x: Float = -87.0
        while x < 88.0 {
            let ours = Double(MotionMath.exp(x))
            let theirs = Foundation.exp(Double(x))
            #expect(abs((ours - theirs) / theirs) < 4e-7)
            x += 0.0137
        }
        #expect(MotionMath.exp(0.0) == 1.0)
        #expect(MotionMath.exp(-100.0) == 0.0)
        #expect(MotionMath.exp(100.0) == .infinity)

        var angle: Float = -2000.0
        while angle < 2000.0 {
            let (s, c) = MotionMath.sinCos(angle)
            let xd = Double(angle)
            #expect(abs(Double(s) - Foundation.sin(xd)) < 4e-7)
            #expect(abs(Double(c) - Foundation.cos(xd)) < 4e-7)
            angle += 0.0731
        }
    }

    @Test("easing_bezier_monotone_exact_solve_and_piecewise")
    func easingBezierMonotoneExactSolveAndPiecewise() {
        let b = CubicBezier(0.2, 0.8, 0.2, 1.0)
        for i in 1..<1000 {
            let x = Float(i) / 1000.0
            let t = b.solveCurveX(x)
            let back = b.sampleCurveX(t)
            #expect(abs(back - x) < 1e-5)
        }

        let pw = Easing.piecewise([Vec2(0, 0), Vec2(0.5, 0.8), Vec2(1.0, 1.0)])
        #expect(abs(pw.sample(0.25) - 0.4) < 1e-6)
        #expect(abs(pw.sample(0.75) - 0.9) < 1e-6)
        let (y, slope) = pw.evalWithSlope(0.25)
        #expect(abs(y - 0.4) < 1e-6 && abs(slope - 1.6) < 1e-6)
    }

    @Test("value_affine_anchor_hex_srgb_and_oklab_helpers")
    func valueAffineAnchorHexSrgbAndOklabHelpers() {
        let r = MotionRect.fromXYWH(10, 20, 100, 50)
        let lanes = r.toLanes()
        #expect(lanes.l0 == 10 && lanes.l1 == 20 && lanes.l2 == 110 && lanes.l3 == 70)
        #expect(MotionRect.fromLanes(lanes) == r)

        let t = Transform2D(tx: 0, ty: 0, sx: 1, sy: 1, rot: .pi / 2)
        let m = t.toAffine(anchor: Vec2(10, 10))
        let x = m[0] * 10 + m[2] * 10 + m[4]
        let y = m[1] * 10 + m[3] * 10 + m[5]
        #expect(abs(x - 10) < 1e-4 && abs(y - 10) < 1e-4)

        for c in [MotionColor.hex(0xff3b30), MotionColor.hex(0x34c759), MotionColor.hex(0x007aff), .white] {
            let lab = MotionColor.linearToOKLab(
                r: MotionColor.srgbDecode(c.r),
                g: MotionColor.srgbDecode(c.g),
                b: MotionColor.srgbDecode(c.b)
            )
            let lin = MotionColor.oklabToLinear(L: lab.L, a: lab.a, b: lab.b)
            let br = MotionColor.srgbEncode(lin.r.clamped(to: 0...1))
            let bg = MotionColor.srgbEncode(lin.g.clamped(to: 0...1))
            let bb = MotionColor.srgbEncode(lin.b.clamped(to: 0...1))
            #expect(abs(c.r - br) < 1e-3 && abs(c.g - bg) < 1e-3 && abs(c.b - bb) < 1e-3)
        }
        #expect(MotionColor.transparent.a == 0 && MotionColor.black.r == 0 && MotionColor.white.withAlpha(0.5).a == 0.5)
    }

    @Test("looping_delayed_cooling_linear_slide_and_clock_reference")
    func loopingDelayedCoolingLinearSlideAndClockReference() {
        // sequence_delays_interpolates_holds_and_finishes_without_restarting (looping.rs:195-218)
        let seq4Beats = [
            Beat(at: 0.0, opacity: 0.0, scale: 0.8),
            Beat(at: 0.3, easing: .linear),
            Beat(at: 0.6, opacity: 0.5, scale: 1.1, easing: .linear),
            Beat(at: 0.9, easing: .linear),
        ]
        let seq4Spec = LoopSpec.sequence(MotionSequence(frames: seq4Beats, delay: 0.2))
        var seq4 = LoopTrack(spec: seq4Spec, now: 4.0)
        #expect(seq4.pendingStart(at: 4.0) == 4.2)
        #expect(!seq4.isActive(at: 4.1))
        let pose = seq4.pose(at: 4.35, reduced: false)!
        #expect(abs(pose.opacity - 0.5) < 1e-5 && abs(pose.scale - 0.9) < 1e-5)
        seq4.retime(spec: seq4Spec, at: 4.35)
        #expect(seq4.pose(at: 4.35, reduced: false) == pose)
        #expect(seq4.isActive(at: 4.35))
        #expect(!seq4.isActive(at: 5.2))
        #expect(seq4.pose(at: 5.2, reduced: false)?.opacity == 1.0)
        #expect(seq4.pose(at: 4.35, reduced: true)?.scale == 1.0)
        seq4.finish()
        #expect(!seq4.isActive(at: 4.35))
        #expect(seq4.pendingStart(at: 4.0) == nil)
        #expect(seq4.pose(at: 4.35, reduced: false)?.scale == 1.0)

        let beats = [Beat(at: 0.0, opacity: 0.0), Beat(at: 0.5, opacity: 1.0)]
        let seqSpec = LoopSpec.sequence(MotionSequence(frames: beats, delay: 0.2))
        var seqTrack = LoopTrack(spec: seqSpec, now: 0.0)
        seqTrack.finish()
        #expect(!seqTrack.isActive(at: 0.3))
        #expect(seqTrack.pendingStart(at: 0.3) == nil)
        #expect(seqTrack.pose(at: 0.3, reduced: false)?.opacity == 1.0)
        seqTrack.advance(by: 1.0)
        #expect(seqTrack.pose(at: 0.3, reduced: false)?.opacity == 1.0)
        seqTrack.setEnabled(false, at: 1.0)
        #expect(!seqTrack.isActive(at: 10.0))
        seqTrack.setEnabled(true, at: 2.0)
        #expect(seqTrack.pendingStart(at: 2.0) == 2.2)
        #expect(!seqTrack.isActive(at: 2.1))
        #expect(seqTrack.pose(at: 2.1, reduced: false)?.opacity == 0.0)

        // delay_has_one_wake_and_no_active_frames (looping.rs:260-268)
        let wakeTrack = LoopTrack(spec: LoopSpec.opacity(period: 1.0, delay: 2.0, low: 0.0, high: 1.0), now: 3.0)
        #expect(wakeTrack.pendingStart(at: 3.0) == 5.0)
        #expect(!wakeTrack.isActive(at: 4.999))
        #expect(wakeTrack.sample(at: 4.999, reduced: false) == 0.0)
        #expect(wakeTrack.pendingStart(at: 5.0) == nil)
        #expect(wakeTrack.isActive(at: 5.0))
        #expect(wakeTrack.phase(at: 5.0) == 0.0)

        var delayed = LoopTrack(spec: LoopSpec.opacity(period: 1.0, delay: 2.0, low: 0.0, high: 1.0), now: 3.0)
        #expect(delayed.pendingStart(at: 3.0) == 5.0)
        delayed.shift(by: 0.5)
        #expect(delayed.pendingStart(at: 3.0) == 5.5)
        delayed.shift(by: -0.25)
        #expect(delayed.pendingStart(at: 3.0) == 5.25)
        #expect(!delayed.isActive(at: 5.0))
        #expect(delayed.isActive(at: 5.25))

        let slide = LoopTrack(spec: LoopSpec.slide(period: 2.0, from: Vec2(-1, 0), to: Vec2(3, 0)).easing(.linear), now: 0.0)
        let xs = (0..<240).map { slide.offset(at: Double($0) / 120.0, reduced: false)!.x }
        #expect(xs[0] == -1.0)
        for i in 1..<xs.count {
            #expect(abs((xs[i] - xs[i - 1]) - (4.0 / 240.0)) < 1e-4)
        }
        #expect(slide.offset(at: 2.0, reduced: false) == Vec2(-1, 0))
        #expect(slide.offset(at: 0.37, reduced: true) == Vec2(1, 0))
        #expect(slide.sample(at: 0.37, reduced: false) == 1.0)

        let rot = LoopTrack(spec: LoopSpec.rotation(period: 0.9), now: 0.0)
        var clk = Clock.manual(hz: 120.0)
        for _ in 0..<17 { _ = clk.step() }
        let first = rot.sample(at: clk.now, reduced: false)
        clk.pause(realNow: 0.0)
        for _ in 0..<40 { _ = clk.step() }
        #expect(rot.sample(at: clk.now, reduced: false) == first)
        clk.resume(realNow: 0.0)
        clk.setScale(0.25, realNow: 0.0)
        _ = clk.step()
        let reference = Float((17.0 / 120.0 + 0.25 / 120.0) / 0.9) * (.pi * 2.0)
        #expect(abs(rot.sample(at: clk.now, reduced: false) - reference) < 1e-6)
        clk.seek(to: 0.45)
        #expect(abs(rot.sample(at: clk.now, reduced: false) - .pi) < 1e-6)
    }

    @Test("anim_ext_with_class_shared_buffer_and_composite_values")
    func animExtWithClassSharedBufferAndCompositeValues() {
        var animVal = Animated(Float(0)).withClass(.scale, pixelScale: 2.0)
        animVal.animateTo(1.0, anim: MotionTokens.SETTLE.delay(0.0, as: Float.self), at: 0.0)
        #expect(!animVal.isSettled(at: 0.05))
        #expect(animVal.isSettled(at: 2.0))

        let built: Anim<Float> = MotionTokens.SETTLE.additive(as: Float.self).completion(42)
        #expect(built.blend == .additive && built.token == 42)
        let paired: Anim<Vec2> = MotionTokens.SNAP_PAIR.delay(0.1, as: Vec2.self).velocity(.zero)
        #expect(abs(paired.delay - 0.1) < 1e-6 && paired.velocityRule == .zero)
        let curved: Anim<Float> = Curve.linear(0.25).merge(as: Float.self)
        #expect(curved.blend == .merge)

        let snapped = Snap.snapEdges([0.001, 0.001, 10.001, 20.001], scale: 2.0)
        #expect(abs(snapped.width - 10.0) < 0.02 && abs(snapped.height - 20.0) < 0.02)

        let fxOp = TransitionEffect.opacity(0.25)
        let fxSc = TransitionEffect.scale(0.8, anchor: Vec2(0.0, 1.0))
        let fxBl = TransitionEffect.blur(3.0)
        #expect(fxOp.zeroOpacity == 0.25 && fxSc.zeroScale == Vec2(0.8, 0.8) && fxBl.zeroBlur == 3.0)

        let buf = SharedBuffer()
        let trace = MotionTrace.inMemory(
            header: TraceHeader(launch: "shared-buf", width: 200, height: 100, hz: 60, scale: 1),
            buffer: buf
        )
        var scene = Scene()
        scene.trace = trace
        let n = NodeId(101)
        scene.insert(n, NodeSpec(MotionRect.fromXYWH(0, 0, 50, 20)), .initial)
        _ = scene.frame(at: 0.0)
        scene.setFrame(n, MotionRect.fromXYWH(20, 0, 50, 20), MotionTokens.SNAP)
        _ = scene.frame(at: 1.0 / 60.0)
        #expect(buf.contents().contains("\"launch\":\"shared-buf\""))
        #expect(buf.contents().contains("\"t\":16.667") && buf.contents().contains("\"e\":"))

        let rgba = MotionColor.rgba(0.2, 0.4, 0.6, 0.8)
        #expect(abs(rgba.r - 0.2) < 1e-6 && abs(rgba.a - 0.8) < 1e-6)

        let sides = Sides.fromEdges(left: 1, top: 2, right: 3, bottom: 4)
        #expect(sides.edges == [1, 2, 3, 4])

        let pair = AnimatablePair<Float, Vec2>(2.0, Vec2(4.0, 6.0))
        #expect(AnimatablePair<Float, Vec2>.laneCount == 3)
        #expect(AnimatablePair<Float, Vec2>.fromLanes(pair.toLanes()) == pair)

        let triple = AnimatableTriple<Float, Vec2, Float>(1.0, Vec2(2.0, 3.0), 4.0)
        #expect(AnimatableTriple<Float, Vec2, Float>.laneCount == 4)
        #expect(AnimatableTriple<Float, Vec2, Float>.fromLanes(triple.toLanes()) == triple)
    }

    @Test("choreography_stagger_and_phase_animator_reduced_motion")
    func choreographyStaggerAndPhaseAnimatorReducedMotion() {
        // choreography_stagger_cascades_items (choreo.rs:53)
        var store = AnimationStore()
        let items = [NodeId(1), NodeId(2), NodeId(3), NodeId(4)]
        for id in items { store.snap(id, Props.OPACITY, to: 0.0) }
        var ch = Choreography()
        let steps = ch.stagger(.now(), Stagger(step: 0.05), items: items) { ops, id in
            ops.animate(id, Props.OPACITY, to: 1.0, anim: Anim.spring(MotionTokens.SNAP))
        }
        store.tickAt(0.0)
        ch.tick(store: &store, at: 0.0)
        for (i, stepId) in steps.enumerated() {
            #expect(abs((ch.startTime(of: stepId) ?? -1.0) - Double(i) * 0.05) < 1e-6)
        }
        store.tickAt(0.06)
        ch.tick(store: &store, at: 0.06)
        #expect((store.get(items[0], Props.OPACITY) ?? 0) > 0.0)
        #expect((store.get(items[1], Props.OPACITY) ?? 0) > 0.0)
        #expect(store.get(items[2], Props.OPACITY) == 0.0)

        // phase_animator_cycles_and_holds_under_reduced_motion (choreo.rs:74)
        func pulse(_ store: inout AnimationStore, reduced: Bool) -> [Int] {
            store.setReducedMotion(reduced)
            let n = NodeId(1)
            var ph = ChoreographyPhaseAnimator()
                .phase { $0.animate(n, Props.SCALE, to: Vec2(1.0, 1.0), anim: Anim.spring(MotionTokens.SETTLE)) }
                .phase { $0.animate(n, Props.SCALE, to: Vec2(1.04, 1.04), anim: Anim.spring(MotionTokens.SETTLE)) }
                .advanceOn(.arrived)
            var phases: [Int] = []
            var t = 0.0
            while t < 2.0 {
                store.setTime(t)
                ph.tick(store: &store, at: t)
                store.tick()
                phases.append(ph.currentIndex)
                t += 1.0 / 120.0
            }
            return phases
        }
        var normalStore = AnimationStore()
        let phases = pulse(&normalStore, reduced: false)
        let switches = zip(phases, phases.dropFirst()).filter { $0.0 != $0.1 }.count
        #expect((5...7).contains(switches))
        var reducedStore = AnimationStore()
        let held = pulse(&reducedStore, reduced: true)
        #expect(held.allSatisfy { $0 == 0 })
    }
}
