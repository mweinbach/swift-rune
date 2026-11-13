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
        for _ in 0..<6 {
            let target = rng.range(-300.0, 300.0)
            merged.setTime(t)
            added.setTime(t)
            merged.animate(N, X, to: target, anim: Anim.spring(s).merge())
            added.animate(N, X, to: target, anim: Anim.spring(s).additive())
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
        var s = AnimationStore()
        let red = MotionColor(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let blue = MotionColor(r: 0.0, g: 0.0, b: 1.0, a: 1.0)
        s.set(N, Props.FILL, red)
        s.animate(N, Props.FILL, to: blue, anim: .spring(MotionTokens.SETTLE))
        s.tickAt(0.15)
        let mid = s.get(N, Props.FILL)!
        let p = MotionTokens.SETTLE.sample(from: 0.0, velocity: 0.0, target: 1.0, at: 0.15).position
        let a = red.toOKLab()
        let b = blue.toOKLab()
        let want = MotionColor.fromOKLab(
            L: a.L + (b.L - a.L) * p,
            a: a.a + (b.a - a.a) * p,
            b: a.b + (b.b - a.b) * p,
            alpha: 1.0
        )
        #expect(abs(mid.r - want.r) < 2e-3)
        #expect(abs(mid.g - want.g) < 2e-3)
        #expect(abs(mid.b - want.b) < 2e-3)
        #expect(abs(mid.a - want.a) < 2e-3)
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
}
