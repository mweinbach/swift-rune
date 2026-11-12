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
}
