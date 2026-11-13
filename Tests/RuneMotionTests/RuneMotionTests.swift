import Foundation
import Testing
@testable import RuneMotion

@Suite("RuneMotion Tests")
struct RuneMotionTests {
    @Test("Critically, under-, and over-damped springs start exact and converge")
    func springRegimesConverge() {
        for bounce: Float in [0.0, 0.25, -0.35] {
            let sp = Spring(duration: 0.35, bounce: bounce)
            guard let layer = Layer.make(
                curve: .spring(sp),
                offset: -100.0,
                velocity: 50.0,
                t0: 0.0,
                posEps: 1e-3,
                velEps: 1e-2
            ) else {
                Issue.record("Expected active spring layer for bounce=\(bounce)")
                continue
            }

            let s0 = layer.sample(at: 0.0)
            #expect(abs(s0.offset - (-100.0)) < 1e-4)
            #expect(abs(s0.velocity - 50.0) < 1e-3)

            if bounce > 0.1 {
                // Underdamped spring must overshoot past 0 at some point
                var maxOvershoot: Float = 0
                for step in 1...60 {
                    let t = Double(step) * Double(layer.settleDuration) / 60.0
                    maxOvershoot = max(maxOvershoot, layer.sample(at: t).offset)
                }
                #expect(maxOvershoot > 0.5)
            }

            let endSample = layer.sample(at: Double(layer.settleDuration))
            #expect(abs(endSample.offset) <= 1e-3)
            #expect(abs(endSample.velocity) <= 1e-2)
        }
    }

    @Test("Mid-flight retargeting preserves instantaneous velocity without discontinuity")
    func midFlightRetargetPreservesVelocity() {
        var store = AnimationStore(pixelScale: 2.0)
        let node = NodeId.hash("box")
        store.snap(node, Props.OPACITY, to: 0.0)
        store.set(node, Props.OPACITY, to: 100.0, anim: .spring(.snappy), at: 0.0)

        store.sample(at: 0.12)
        let posBefore = store.get(node, Props.OPACITY)!
        let velBefore = store.velocity(node, Props.OPACITY).lanes.l0
        #expect(velBefore > 10.0)

        // Retarget audit defaults to disabled (opt-in matching store.rs:246).
        store.set(node, Props.OPACITY, to: 20.0, anim: .spring(.snappy, blend: .merge), at: 0.12)
        #expect(store.takeRetargetAudit().lanes == 0)

        let posAfter = store.get(node, Props.OPACITY)!
        let velAfter = store.velocity(node, Props.OPACITY).lanes.l0
        #expect(abs(posAfter - posBefore) < 1e-4)
        #expect(abs(velAfter - velBefore) < 1e-2)

        // Opting in audits spatial springs only (`store.rs:288-294,733-734`).
        store.auditRetargets(true)
        store.set(node, Props.OPACITY, to: 80.0, anim: .spring(.snappy, blend: .merge), at: 0.14)
        #expect(store.takeRetargetAudit().lanes == 0)

        store.snap(node, Props.OFFSET, to: Vec2(0, 0))
        store.set(node, Props.OFFSET, to: Vec2(100, 50), anim: .spring(.snappy), at: 0.15)
        store.sample(at: 0.25)
        let offBefore = store.get(node, Props.OFFSET)!
        let offVelBefore = store.velocity(node, Props.OFFSET)
        store.set(node, Props.OFFSET, to: Vec2(20, 10), anim: .spring(.snappy, blend: .merge), at: 0.25)
        let audit = store.takeRetargetAudit()
        #expect(audit.lanes == 2)
        #expect(audit.maxVelocityError < 1e-2)

        let offAfter = store.get(node, Props.OFFSET)!
        let offVelAfter = store.velocity(node, Props.OFFSET)!
        #expect(abs(offAfter.x - offBefore.x) < 1e-4 && abs(offAfter.y - offBefore.y) < 1e-4)
        #expect(abs(offVelAfter.x - offVelBefore!.x) < 1e-2 && abs(offVelAfter.y - offVelBefore!.y) < 1e-2)
    }

    @Test("Additive blending superposes offsets without jumping")
    func additiveBlendSuperposition() {
        var store = AnimationStore(pixelScale: 2.0)
        let node = NodeId.hash("pill")
        store.snap(node, Props.OFFSET, to: Vec2(0, 0))
        store.set(node, Props.OFFSET, to: Vec2(100, 0), anim: .spring(.smooth, blend: .additive), at: 0.0)
        store.sample(at: 0.1)
        let midX = store.get(node, Props.OFFSET)!.x

        store.set(node, Props.OFFSET, to: Vec2(150, 0), anim: .spring(.smooth, blend: .additive), at: 0.1)
        let postX = store.get(node, Props.OFFSET)!.x
        #expect(abs(postX - midX) < 1e-3)

        store.sample(at: 5.0)
        #expect(!store.isAnimating)
        #expect(store.get(node, Props.OFFSET) == Vec2(150, 0))
    }

    @Test("Inertial decay fling lands at exact v0 / rate distance")
    func inertialDecayFling() {
        var store = AnimationStore(pixelScale: 2.0)
        let node = NodeId.hash("scroll")
        let rest = store.fling(
            node,
            Props.SCROLL,
            from: Vec2(0, 10),
            velocity: Velocity(Vec2(0, 400)),
            decay: .IOS_NORMAL,
            at: 0.0
        )
        let expectedY = 10.0 + 400.0 / Decay.IOS_NORMAL.rate
        #expect(abs(rest.y - expectedY) < 1e-3)

        store.sample(at: 10.0)
        #expect(!store.isAnimating)
        #expect(abs(store.get(node, Props.SCROLL)!.y - expectedY) < 1e-2)
    }

    @Test("CubicBezier Newton/bisection and Easing variants")
    func cubicBezierAndEasings() {
        #expect(Easing.easeInOut.sample(0) == 0)
        #expect(Easing.easeInOut.sample(1) == 1)
        #expect(abs(Easing.ease.sample(0.5) - 0.8024) < 1e-3)
        #expect(abs(Easing.easeInOut.sample(0.5) - 0.5) < 1e-5)
        #expect(Easing.easeOut.sample(0.0) == 0.0)
        #expect(Easing.easeOut.sample(1.0) == 1.0)
        #expect((0..<100).contains { Easing.overshoot.sample(Float($0) / 100.0) > 1.05 })
        #expect(Easing.steps(4, .jumpEnd).sample(0.5) == 0.5)
        #expect(Easing.steps(4, .jumpStart).sample(0.01) == 0.25)
    }

    @Test("Premultiplied OKLab color fade never darkens RGB through black")
    func premultipliedOKLabFade() {
        var store = AnimationStore(pixelScale: 2.0)
        let node = NodeId.hash("swatch")
        let bright = MotionColor(r: 0.9, g: 0.2, b: 0.1, a: 1.0)
        let clear = MotionColor(r: 0.0, g: 0.0, b: 0.0, a: 0.0)

        store.snap(node, Props.FILL, to: bright)
        store.set(node, Props.FILL, to: clear, anim: .tween(duration: 1.0, easing: .linear), at: 0.0)
        store.sample(at: 0.5)

        let mid = store.get(node, Props.FILL)!
        #expect(abs(mid.a - 0.5) < 1e-3)
        // Straight RGB of premultiplied OKLab midpoint must preserve the original red hue & brightness!
        #expect(abs(mid.r - bright.r) < 0.02)
        #expect(abs(mid.g - bright.g) < 0.02)
    }

    @Test("Clock slow-motion re-anchoring and pause/resume")
    func clockScalingAndPause() {
        var clock = Clock.display(now: 10.0)
        #expect(clock.sample(realNow: 11.0) == 1.0)
        clock.setScale(0.25, realNow: 11.0)
        #expect(abs(clock.sample(realNow: 13.0) - 1.5) < 1e-6)

        clock.pause(realNow: 13.0)
        #expect(abs(clock.sample(realNow: 20.0) - 1.5) < 1e-6)
        clock.resume(realNow: 20.0)
        #expect(abs(clock.sample(realNow: 24.0) - 2.5) < 1e-6)
    }

    @Test("Scene 4-edge layout morphing, exiting node retention, revival, and reducedMotion")
    func sceneLifecycleAndEdgeMorphing() {
        var scene = Scene(pixelScale: 2.0)
        let cardId = NodeId.hash("card")
        let badgeId = NodeId.hash("badge")

        // Initial commit lands immediately without spring
        scene.commit([
            NodeSpec(
                id: cardId,
                rect: .fromXYWH(20, 30, 100, 50),
                layoutAnim: LayoutAnim(spring: MotionTokens.SETTLE)
            ),
            NodeSpec(
                id: badgeId,
                parent: cardId,
                rect: .fromXYWH(30, 40, 20, 20),
                transition: .opacity.spring(MotionTokens.SNAP)
            ),
        ], at: 0.0)

        let f0 = scene.frame(at: 0.0)
        #expect(!f0.isAnimating)
        #expect(f0.byId[cardId]?.rect == .fromXYWH(20, 30, 100, 50))

        // Resize right edge 120 -> 220 while keeping left=20, top=30, bottom=80 stationary, and unmount badge!
        scene.commit([
            NodeSpec(
                id: cardId,
                rect: .fromXYWH(20, 30, 200, 50),
                layoutAnim: LayoutAnim(spring: MotionTokens.SETTLE)
            ),
        ], at: 0.1)

        let fMid = scene.frame(at: 0.18)
        #expect(fMid.isAnimating)
        let midCard = fMid.byId[cardId]!
        // Stationary edges MUST NEVER jiggle!
        #expect(midCard.rect.left == 20.0)
        #expect(midCard.rect.top == 30.0)
        #expect(midCard.rect.bottom == 80.0)
        #expect(midCard.rect.right > 120.0 && midCard.rect.right < 220.0)

        // Exiting badge stays mounted while fading out!
        let midBadge = fMid.byId[badgeId]
        #expect(midBadge != nil)
        #expect(midBadge!.isExiting)
        #expect(midBadge!.opacity > 0.0 && midBadge!.opacity < 1.0)

        // Revive badge mid-exit!
        scene.commit([
            NodeSpec(
                id: cardId,
                rect: .fromXYWH(20, 30, 200, 50),
                layoutAnim: LayoutAnim(spring: MotionTokens.SETTLE)
            ),
            NodeSpec(
                id: badgeId,
                parent: cardId,
                rect: .fromXYWH(30, 40, 20, 20),
                transition: .opacity.spring(MotionTokens.SNAP)
            ),
        ], at: 0.20)
        let revived = scene.frame(at: 0.22).byId[badgeId]!
        #expect(!revived.isExiting)

        // Once settled, unmount badge again and verify it cleans up completely after settle
        _ = scene.frame(at: 3.0)
        scene.commit([
            NodeSpec(id: cardId, rect: .fromXYWH(20, 30, 200, 50), layoutAnim: LayoutAnim(spring: MotionTokens.SETTLE))
        ], at: 3.0)
        let settled = scene.frame(at: 5.0)
        #expect(!settled.isAnimating)
        #expect(settled.byId[badgeId] == nil)

        // Reduced motion cuts spatial layout instantly while fading opacity
        scene.reducedMotion = true
        scene.commit([
            NodeSpec(
                id: cardId,
                rect: .fromXYWH(80, 90, 240, 60),
                opacity: 0.4,
                layoutAnim: LayoutAnim(spring: MotionTokens.SETTLE),
                styleSpring: MotionTokens.SETTLE
            )
        ], at: 5.1)
        let rmFrame = scene.frame(at: 5.15)
        #expect(rmFrame.byId[cardId]?.rect == .fromXYWH(80, 90, 240, 60))
        #expect(rmFrame.byId[cardId]!.opacity > 0.4 && rmFrame.byId[cardId]!.opacity < 1.0)
    }

    // MARK: - Upstream Spring & ODE Parity Tests

    private func integrateODE(spring s: Spring, x0: Double, v0: Double, target: Double, tEnd: Double) -> (Double, Double) {
        let k = Double(s.stiffness)
        let c = Double(s.damping)
        func f(_ x: Double, _ v: Double) -> (Double, Double) {
            (v, -k * (x - target) - c * v)
        }
        let dt = 1e-5
        var x = x0
        var v = v0
        let steps = Int((tEnd / dt).rounded())
        for _ in 0..<steps {
            let (a1, b1) = f(x, v)
            let (a2, b2) = f(x + 0.5 * dt * a1, v + 0.5 * dt * b1)
            let (a3, b3) = f(x + 0.5 * dt * a2, v + 0.5 * dt * b2)
            let (a4, b4) = f(x + dt * a3, v + dt * b3)
            x += dt / 6.0 * (a1 + 2.0 * a2 + 2.0 * a3 + a4)
            v += dt / 6.0 * (b1 + 2.0 * b2 + 2.0 * b3 + b4)
        }
        return (x, v)
    }

    @Test("Closed-form Spring.sample matches RK4 ODE integration in every damping regime")
    func closedFormMatchesODE() {
        let springs = [
            Spring(duration: 0.3, bounce: 0.0),
            Spring(duration: 0.5, bounce: 0.3),
            Spring(duration: 0.4, bounce: 0.7),
            Spring(duration: 0.35, bounce: -0.5),
            Spring(duration: 0.6, bounce: 0.0005),
            Spring(duration: 0.25, bounce: -0.0005),
        ]
        let starts: [(Float, Float)] = [(0.0, 0.0), (0.0, 25.0), (0.7, -8.0)]
        for s in springs {
            for (x0, v0) in starts {
                for t: Float in [0.01, 0.05, 0.13, 0.3, 0.71] {
                    let (x, v) = s.sample(from: x0, velocity: v0, target: 1.0, at: t)
                    let (rx, rv) = integrateODE(spring: s, x0: Double(x0), v0: Double(v0), target: 1.0, tEnd: Double(t))
                    #expect(abs(Double(x) - rx) < 1e-4)
                    let vtol = 1e-4 * Double(s.omega) + 1e-4 * Double(abs(v0))
                    #expect(abs(Double(v) - rv) < vtol)
                }
            }
        }
    }

    @Test("SwiftUI spring parameter mappings and round trips")
    func swiftUIParameterMapping() {
        let s = Spring(duration: 0.5, bounce: 0.0)
        #expect(abs(s.stiffness - 157.91367) < 1e-2)
        #expect(abs(s.damping - 25.13274) < 1e-3)
        #expect(Spring.bouncy.dampingRatio == 0.7)
        #expect(abs(Spring.snappy.dampingRatio - 0.85) < 1e-6)
        #expect(Spring(duration: 0.4, bounce: -0.5).dampingRatio == 2.0)

        let back = Spring.fromStiffnessDamping(stiffness: s.stiffness, damping: s.damping, mass: 1.0)
        #expect(abs(back.duration - 0.5) < 1e-5 && abs(back.bounce) < 1e-5)

        let r = Spring.fromResponse(0.55, dampingFraction: 0.825)
        #expect(abs(r.duration - 0.55) < 1e-6 && abs(r.dampingRatio - 0.825) < 1e-6)

        let over = Spring.fromOmegaZeta(omega: 10.0, zeta: 2.0)
        #expect(abs(over.bounce + 0.5) < 1e-6 && abs(over.dampingRatio - 2.0) < 1e-5)

        let m = Spring.fromStiffnessDamping(stiffness: 400.0, damping: 20.0, mass: 2.0)
        #expect(abs(m.omega - sqrtf(200.0)) < 1e-4)

        #expect(abs(Spring.fromMotion(visualDuration: 0.45, bounce: 0.0).duration - 0.54) < 1e-6)
        #expect(abs(MotionTokens.GLIDE.motionVisualDuration - 0.32 / 1.2) < 1e-6)

        let (css, ms) = Spring.smooth.cssLinear()
        #expect(css.hasPrefix("linear(0,") && css.hasSuffix(",1)"))
        #expect(ms > 200 && ms < 2000)
    }

    @Test("MotionTokens pairs match upstream kit_motion specs")
    func motionTokensMatchUpstream() {
        let expect: [(String, Float, Float, Float, Float)] = [
            ("instant", 0.10, 0.0, 0.10, 0.0),
            ("snap", 0.25, 0.0, 0.20, 0.0),
            ("settle", 0.30, 0.0, 0.24, 0.0),
            ("reflow", 0.40, 0.0, 0.32, 0.0),
            ("glide", 0.32, 0.0, 0.26, 0.0),
            ("morph", 0.30, 0.16, 0.27, 0.08),
            ("pop", 0.25, 0.15, 0.20, 0.05),
            ("drift", 0.85, 0.0, 0.60, 0.0),
        ]
        for (idx, exp) in expect.enumerated() {
            let got = MotionTokens.ALL[idx]
            #expect(got.name == exp.0)
            #expect(got.pair.enter.duration == exp.1 && got.pair.enter.bounce == exp.2)
            #expect(got.pair.exit.duration == exp.3 && got.pair.exit.bounce == exp.4)
        }
        #expect(MotionTokens.INSTANT_PAIR == SpringPair(enter: MotionTokens.INSTANT, exit: MotionTokens.INSTANT_EXIT))
        #expect(MotionTokens.INSTANT_PAIR.enter.duration == 0.10 && MotionTokens.INSTANT_PAIR.exit.duration == 0.10)
    }

    @Test("Spring.settlingDuration bounds the entire tail and critical spring is monotonic")
    func springSettlingDurationAndMonotonicity() {
        for s in [Spring(duration: 0.3, bounce: 0.0), Spring(duration: 0.5, bounce: 0.3), Spring(duration: 0.4, bounce: -0.4)] {
            let ts = s.settlingDuration(epsilon: 1e-3)
            #expect(ts > 0.0 && ts < 20.0)
            for i in 0..<200 {
                let t = ts + Float(i) * 0.05
                let (x, v) = s.sample(from: 0.0, velocity: 0.0, target: 1.0, at: t)
                #expect(abs(x - 1.0) <= 1.01e-3)
                #expect(abs(v) <= 1.01e-2)
            }
        }
        let nonZeroSettle = Spring(duration: 0.4, bounce: 0.2).settlingDuration(
            from: 100.0,
            velocity: -50.0,
            target: 25.0,
            epsilon: 1e-2
        )
        #expect(nonZeroSettle > 0.1 && nonZeroSettle < 20.0)
        for i in 0..<100 {
            let t = nonZeroSettle + Float(i) * 0.05
            let (x, v) = Spring(duration: 0.4, bounce: 0.2).sample(from: 100.0, velocity: -50.0, target: 25.0, at: t)
            #expect(abs(x - 25.0) <= 1.01e-2)
            #expect(abs(v) <= 0.11)
        }
        var prev: Float = 0
        for i in 1...400 {
            let (x, _) = MotionTokens.SETTLE.sample(from: 0.0, velocity: 0.0, target: 1.0, at: Float(i) / 400.0)
            #expect(x >= prev && x <= 1.0)
            prev = x
        }
    }

    @Test("CSS steps() at u=0 for jumpStart/jumpBoth and tween velocity carry")
    func stepsZeroAndTweenCarry() {
        #expect(Easing.steps(4, .jumpEnd).sample(0.0) == 0.0)
        #expect(Easing.steps(4, .jumpEnd).sample(0.3) == 0.25)
        #expect(Easing.steps(4, .jumpStart).sample(0.0) == 0.25)
        #expect(Easing.steps(4, .jumpStart).sample(0.3) == 0.5)
        #expect(abs(Easing.steps(2, .jumpBoth).sample(0.0) - (1.0 / 3.0)) < 1e-6)
        #expect(abs(Easing.steps(2, .jumpBoth).sample(0.4) - (1.0 / 3.0)) < 1e-6)
        #expect(Easing.steps(3, .jumpBoth).sample(1.0) == 1.0)
        #expect(Easing.steps(2, .jumpNone).sample(0.5) == 1.0)

        // Tween retarget carries initial velocity smoothly without discontinuity
        var store = AnimationStore(pixelScale: 2.0)
        let node = NodeId.hash("tweenCarry")
        store.snap(node, Props.OPACITY, to: 0.0)
        store.set(node, Props.OPACITY, to: 100.0, anim: .tween(duration: 0.5, easing: .easeOut), at: 0.0)
        store.sample(at: 0.1)
        let vBefore = store.velocity(node, Props.OPACITY).lanes.l0
        #expect(vBefore > 0)
        store.set(node, Props.OPACITY, to: 100.0, anim: .tween(duration: 0.4, easing: .easeInOut, blend: .merge), at: 0.1)
        let vAfter = store.velocity(node, Props.OPACITY).lanes.l0
        #expect(abs(vAfter - vBefore) < 1e-2)
    }

    @Test("Animated standalone value retargets keeping velocity")
    func animatedStandaloneValue() {
        var a = Animated<Float>(0.0)
        a.animateTo(100.0, anim: .spring(MotionTokens.GLIDE), at: 0.0)
        let x1 = a.sample(at: 0.1)
        let v1 = a.velocity(at: 0.1)
        a.animateTo(-50.0, anim: .spring(MotionTokens.GLIDE), at: 0.1)
        #expect(abs(a.sample(at: 0.1) - x1) < 1e-4)
        #expect(abs(a.velocity(at: 0.1) - v1) < 1e-2)
        a.retarget(-50.0, at: 0.2)
        #expect(a.isSettled(at: 5.0))
        #expect(abs(a.sample(at: 5.0) + 50.0) < 1e-3)
    }

    @Test("Gesture projection, rubberBand, and VelocityTracker")
    func gestureHelpers() {
        #expect(abs(Gesture.project(x: 0.0, velocity: 1000.0, rate: DecelerationRate.normal) - 499.0) < 0.01)
        let d: Float = 800.0
        #expect(Gesture.rubberBand(overshoot: 100.0, dimension: d) < 55.0 + 1e-3)
        #expect(Gesture.rubberBand(overshoot: 100.0, dimension: d) > 0.0)
        #expect(Gesture.rubberBand(overshoot: -100.0, dimension: d) == -Gesture.rubberBand(overshoot: 100.0, dimension: d))
        #expect(abs(Gesture.rubberBand(overshoot: 1.0, dimension: d) - 0.55) < 1e-3)
        #expect(Gesture.rubberBandClamp(50.0, min: 0.0, max: 100.0, dimension: d) == 50.0)

        var tracker = VelocityTracker<Float>()
        for i in 0..<30 {
            let t = Double(i) / 120.0
            tracker.add(at: t, value: 300.0 * Float(t))
        }
        #expect(abs(tracker.velocity() - 300.0) < 0.5)
        tracker.add(at: 30.0 / 120.0 + 0.2, value: 75.0)
        #expect(tracker.velocity() == 0.0)

        var xformTracker = VelocityTracker<Transform2D>()
        for i in 0..<10 {
            let t = Double(i) / 120.0
            let tf = Float(t)
            xformTracker.add(at: t, value: Transform2D(tx: 10 * tf, ty: 20 * tf, sx: 1, sy: 1, rot: 2 * tf))
        }
        let xformVel = xformTracker.velocity()
        #expect(abs(xformVel.tx - 10.0) < 0.2 && abs(xformVel.ty - 20.0) < 0.2 && abs(xformVel.rot - 2.0) < 0.05)
    }

    @Test("MotionSequence, Cycle, StaggerFrom, PhaseAnimator, and Release")
    func sequenceCycleStaggerAndRelease() {
        let seq = MotionSequence(frames: [
            Beat(at: 0.0, opacity: 0.0, scale: 0.9),
            Beat(at: 0.5, opacity: 1.0, scale: 1.0, easing: .linear),
        ])
        let mid = seq.sample(elapsed: 0.25)
        #expect(abs(mid.opacity - 0.5) < 1e-5)
        #expect(abs(mid.scale - 0.95) < 1e-5)

        let cycle = Cycle(period: 2.0, stops: [(0.0, 0.2), (0.5, 1.0), (1.0, 0.2)])
        #expect(abs(cycle.sample(at: 0.5) - 0.6) < 1e-5)
        #expect(Cycle(period: 2.0, stops: []).sample(at: 0.5) == 1.0)

        let stag = Stagger(step: 0.05, maxDelay: 0.0, from: .center)
        #expect(stag.delay(index: 1, count: 3) == 0.0)
        #expect(abs(stag.delay(index: 0, count: 3) - 0.05) < 1e-6)
        #expect(abs(stag.delay(index: 2, count: 3) - 0.05) < 1e-6)
        #expect(stag.delay(index: 0, count: 1) == 0.0)
        // stagger_delays_ripple_from_the_origin (choreo.rs:5-16)
        let dFirst = (0..<5).map { stagger(index: $0, count: 5, gap: 0.1, from: .start) }
        #expect(dFirst == [0.0, 0.1, 0.2, 0.3, 0.4])
        let dLast = (0..<5).map { stagger(index: $0, count: 5, gap: 0.1, from: .end) }
        #expect(dLast == [0.4, 0.3, 0.2, 0.1, 0.0])
        let dCenter = (0..<5).map { stagger(index: $0, count: 5, gap: 0.1, from: .center) }
        #expect(abs(dCenter[0] - 0.2) < 1e-6 && dCenter[2] == 0.0 && abs(dCenter[4] - 0.2) < 1e-6)
        let eased = Stagger(step: 0.1).ease(.easeIn)
        #expect(eased.delay(index: 0, count: 5) == 0.0 && abs(eased.delay(index: 4, count: 5) - 0.4) < 1e-5)
        #expect(eased.delay(index: 1, count: 5) < 0.1)
        let uncapped = Stagger(step: 0.05)
        #expect(uncapped.maxDelay == 0.0)
        #expect(abs(uncapped.delay(index: 10, count: 12) - 0.50) < 1e-6)
        var defaultAnimated = Animated<Float>(0.0)
        defaultAnimated.animateTo(1.0, anim: .spring(MotionTokens.SETTLE), at: 0.0)
        var spatialAnimated = Animated<Float>(0.0, propClass: .spatial)
        spatialAnimated.animateTo(1.0, anim: .spring(MotionTokens.SETTLE), at: 0.0)
        #expect(spatialAnimated.isSettled(at: 0.55) && !defaultAnimated.isSettled(at: 0.55))
        #expect(NodeSpec(MotionRect.fromXYWH(0, 0, 10, 10)).transition == .opacity)

        var pa = PhaseAnimator(["a", "b", "c"])
        #expect(pa.step(at: 0.0) { _ in 0.5 }.phase == "a")
        #expect(pa.step(at: 0.6) { _ in 0.5 }.phase == "b")

        var store = AnimationStore(pixelScale: 2.0)
        let scroll = NodeId.hash("scrollClamp")
        store.snap(scroll, Props.SCROLL, to: Vec2(0, 10))
        let clamped = store.release(
            scroll,
            Props.SCROLL,
            .decayClamped(decay: .IOS_NORMAL, min: Vec2(0, 0), max: Vec2(0, 100), spring: MotionTokens.SETTLE),
            velocity: Velocity(Vec2(0, 1000)),
            at: 0.0
        )
        #expect(clamped == Vec2(0, 100))
        store.sample(at: 5.0)
        let events = store.takeEvents()
        #expect(events.contains {
            if case .settled(_, scroll, Props.SCROLL.id) = $0 { return true }
            return false
        })

        // Transition.kitRules clears blur on travelling transitions and caps blur <= 4
        let travelBlur = Transition.move(edge: .bottom).combined(with: Transition.blur(sigma: 8.0)).kitRules()
        #expect(travelBlur.insertion.zeroBlur == 0.0)
        let staticBlur = Transition.blur(sigma: 8.0).kitRules()
        #expect(staticBlur.insertion.zeroBlur == 4.0)
    }

    @Test("Choreography cues, stagger, and ChoreographyPhaseAnimator")
    func choreographyCuesAndPhaseAnimator() {
        var store = AnimationStore(pixelScale: 2.0)
        let n1 = NodeId(101)
        let n2 = NodeId(102)
        store.snap(n1, Props.OPACITY, to: 0.0)
        store.snap(n2, Props.OPACITY, to: 0.0)

        var choreo = Choreography()
        let first = choreo.step(.now()) { ops in
            ops.animate(n1, Props.OPACITY, to: 1.0, anim: Anim(curve: .linear(0.2)))
        }
        let second = choreo.step(.arrived(first).after(0.05).notBefore(0.1)) { ops in
            ops.animate(n2, Props.OPACITY, to: 1.0, anim: Anim(curve: .linear(0.2)))
        }

        store.sample(at: 0.0)
        choreo.tick(store: &store, at: 0.0)
        #expect(choreo.startTime(of: first) == 0.0)
        #expect(abs((choreo.startTime(of: second) ?? -1) - 0.25) < 1e-4)
        #expect(!choreo.isDone(in: store))

        store.sample(at: 0.5)
        choreo.tick(store: &store, at: 0.5)
        #expect(choreo.isDone(in: store))
        #expect(store.get(n2, Props.OPACITY) == 1.0)

        // sequence_starts_on_arrival_not_on_physical_rest (choreo.rs:19-50)
        var arrStore = AnimationStore()
        let (a, b, c) = (NodeId(1), NodeId(2), NodeId(3))
        for n in [a, b, c] { arrStore.snap(n, Props.OPACITY, to: 0.0) }
        var chArr = Choreography()
        let s1 = chArr.step(.now()) { $0.animate(a, Props.OPACITY, to: 1.0, anim: Anim.spring(MotionTokens.SETTLE)) }
        let s2 = chArr.step(.arrived(s1).after(0.05)) { $0.animate(b, Props.OPACITY, to: 1.0, anim: Anim.spring(MotionTokens.SETTLE)) }
        let s3 = chArr.step(.settled(s2).notBefore(1.5)) { $0.animate(c, Props.OPACITY, to: 1.0, anim: Anim.spring(MotionTokens.SNAP)) }
        var ct = 0.0
        while ct < 4.0 {
            arrStore.setTime(ct)
            chArr.tick(store: &arrStore, at: ct)
            arrStore.tick()
            ct += 1.0 / 120.0
        }
        #expect(abs((chArr.startTime(of: s2) ?? -1.0) - 0.35) < 1e-6)
        #expect((chArr.startTime(of: s3) ?? 0.0) >= 1.5)
        #expect(chArr.isDone(in: arrStore))
        for n in [a, b, c] {
            #expect(arrStore.get(n, Props.OPACITY) == 1.0)
        }

        // ChoreographyPhaseAnimator
        var store2 = AnimationStore(pixelScale: 2.0)
        let box = NodeId(103)
        var pa = ChoreographyPhaseAnimator()
            .phase { $0.animate(box, Props.OPACITY, to: 0.2, anim: Anim(curve: .linear(0.1))) }
            .phase { $0.animate(box, Props.OPACITY, to: 1.0, anim: Anim(curve: .linear(0.1))) }
            .once()

        store2.sample(at: 0.0)
        pa.tick(store: &store2, at: 0.0)
        #expect(pa.currentIndex == 1)
        store2.sample(at: 0.2)
        pa.tick(store: &store2, at: 0.2)
        #expect(store2.get(box, Props.OPACITY) == 1.0)
    }

    @Test("Looping LoopSpec, LoopTrack, LoopMode, retime, and cooling")
    func loopingTrackAndModes() {
        var rot = LoopTrack(spec: .rotation(period: 1.0), now: 0.0)
        #expect(abs(rot.phase(at: 0.25) - 0.25) < 1e-6)
        rot.retime(spec: .rotation(period: 2.0), at: 0.25)
        #expect(abs(rot.phase(at: 0.25) - 0.25) < 1e-6)
        #expect(abs(rot.phase(at: 1.25) - 0.75) < 1e-6)

        // phase_continuity_and_clock_sampling (looping.rs:270-280)
        var rotSweep = LoopTrack(spec: .rotation(period: 0.9), now: 4.0)
        for i in 0..<200 {
            let now = 4.0 + Double(i) * 0.037
            let before = rotSweep.phase(at: now)
            rotSweep.retime(spec: .rotation(period: 0.2 + Double(i % 9) * 0.1), at: now)
            #expect(abs(before - rotSweep.phase(at: now)) < 1e-12)
            #expect(rotSweep.sample(at: now, reduced: false) == rotSweep.sample(at: now, reduced: false))
        }
        #expect(rotSweep.sample(at: 100.0, reduced: true) == 0.0)

        // cycle_preserves_wall_phase_stops_still_and_cadence (looping.rs:249-258)
        let cyc = Cycle(
            period: 1.7,
            phase: 0.3,
            stops: [(0.0, 0.2), (0.2, 1.0), (0.7, 0.1), (1.0, 0.2)],
            still: 0.4,
            fps: 30.0
        )
        let cycTrack = LoopTrack(spec: .cycle(cyc), now: 4.0)
        for i in 0..<200 {
            let wall = Double(i) * 0.037
            #expect(cycTrack.sampleAt(now: 4.0, wall: wall, reduced: false) == cyc.sample(at: wall))
            #expect(cycTrack.sampleAt(now: 4.0, wall: wall, reduced: true) == cyc.still)
        }
        #expect(cycTrack.frameInterval() == 1.0 / Double(Float(30.0)))

        // Ping-pong & count modes
        let pp = LoopSpec.opacity(period: 1.0, low: 0.0, high: 1.0).mode(.pingPong)
        let ppTrack = LoopTrack(spec: pp, now: 0.0)
        #expect(abs(ppTrack.phase(at: 0.25) - 0.25) < 1e-6)
        #expect(abs(ppTrack.phase(at: 1.25) - 0.75) < 1e-6)

        let counted = LoopSpec.rotation(period: 1.0).mode(.count(2))
        let countedTrack = LoopTrack(spec: counted, now: 0.0)
        #expect(countedTrack.isActive(at: 1.5))
        #expect(!countedTrack.isActive(at: 2.1))
        #expect(countedTrack.phase(at: 2.5) == 1.0)

        // Slide & cooling
        var slide = LoopTrack(
            spec: LoopSpec.slide(period: 2.0, from: Vec2(-1, 0), to: Vec2(3, 0)).easing(.linear),
            now: 0.0
        )
        #expect(slide.offset(at: 0.0, reduced: false) == Vec2(-1, 0))
        #expect(slide.offset(at: 1.0, reduced: false) == Vec2(1, 0))
        #expect(slide.offset(at: 0.37, reduced: true) == Vec2(1, 0))
        slide.setEnabled(false, at: 1.0)
        #expect(slide.isActive(at: 1.01))
        #expect(!slide.isActive(at: 10.0))
        #expect(slide.offset(at: 10.0, reduced: false) == Vec2(0, 0))
    }

    @Test("Snap 1/64 px two-edge snapping, SnapPoints detents, MotionMath, and Carry")
    func snapMathAndCarry() {
        // Stationary bottom edge never wobbles across 1000 frames
        let bottom: Float = 200.3
        let fixed = Snap.grid(bottom, scale: 2.0)
        for i in 0..<200 {
            let top: Float = 10.0 + Float(i) * 0.0137
            let r = Snap.rect(MotionRect(left: 0, top: top, right: 10, bottom: bottom), scale: 2.0)
            #expect(r.y + r.height == fixed)
        }

        // Detents & velocity-projected target selection
        let detents = SnapPoints([
            SnapDetent(id: "collapsed", position: 100, radius: 20),
            SnapDetent(id: "half", position: 400, radius: 20),
            SnapDetent(id: "full", position: 800, radius: 20),
        ])
        #expect(detents.nearest(to: 350)?.id == "half")
        #expect(detents.projectTarget(from: 120, velocity: 1500)?.id == "full")
        #expect(detents.magneticPull(108, strength: 0.5) == 104)
        #expect(detents.rubberBandClamp(900, dimension: 500) < 900)

        // Deterministic MotionMath exp & sinCos
        #expect(abs(MotionMath.exp(0) - 1.0) < 1e-6)
        #expect(abs(MotionMath.exp(1) - Float(Darwin.exp(1.0))) < 1e-5)
        let (s, c) = MotionMath.sinCos(.pi / 4.0)
        #expect(abs(s - Float(Darwin.sin(Double.pi / 4.0))) < 1e-6)
        #expect(abs(c - Float(Darwin.cos(Double.pi / 4.0))) < 1e-6)

        // Carry frame-to-frame retention
        var carry = Carry<Int>()
        carry.push(1)
        carry.begin()
        carry.push(2)
        carry.end()
        #expect(carry.items == [1, 2])
        carry.push(3)
        #expect(carry.items == [1, 2, 3])
        carry.begin()
        #expect(carry.items == [3])
        carry.end()
        carry.begin()
        carry.end()
        #expect(carry.items.isEmpty)
    }

    @Test("MotionTrace JSONL emission, channels, and MotionTraceCapture assertions")
    func motionTraceAndAssertions() {
        let header = TraceHeader(launch: "unit", width: 800, height: 600, hz: 120, scale: 2)
        let trace = MotionTrace.inMemory(header: header).host("test").class("rune")
        let node = NodeId(42)
        trace.name(node, "card")
        trace.channel("scroll", kind: .position, value: 12.5)
        let p = Presented(
            id: node,
            parent: nil,
            rect: MotionRect(left: 10, top: 20, right: 110, bottom: 60),
            targetRect: MotionRect(left: 10, top: 20, right: 110, bottom: 60),
            revealClip: nil,
            opacity: 1.0,
            scale: Vec2(1, 1),
            rotate: 0,
            corners: Corners(8, 8, 8, 8),
            blur: 0,
            fill: nil,
            border: nil,
            presence: 1,
            isExiting: false,
            isMoving: true
        )
        trace.frame(at: 0.0, presented: [p], intents: [(node, TraceIntent.forProp(Props.OPACITY.id), 0.2)])
        var masked = p
        masked.mask = Mask(inset: Sides(top: 1, right: 0, bottom: 0, left: 2), feather: .zeroValue)
        trace.frame(at: 0.008, presented: [masked], intents: [(node, TraceIntent.forProp(Props.MASK.id), 0.1)])
        trace.frame(at: 0.016, presented: [], gone: [node])
        let jsonl = trace.contents()
        #expect(jsonl.contains("\"type\":\"header\""))
        #expect(jsonl.contains("\"nm\":\"card\""))
        #expect(jsonl.contains("\"cm\":["))
        #expect(jsonl.contains("\"g\":[1]"))
        #expect(TraceIntent.forProp(Props.MASK.id) == TraceIntent.reveal && TraceIntent.reveal == 32)
        // mask.inset [left:2, top:1, right:0, bottom:0] clips rect [10,20,110,60] -> [12,21,100,40] -> xywh [12,21,98,39]
        #expect(jsonl.contains("12.0,21.0,98.0,39.0"))

        // Critical spring is monotonic with zero overshoot
        let critical = MotionTraceCapture.sampleSpring(Spring(duration: 0.3, bounce: 0.0), from: 0, to: 100)
        #expect(critical.isMonotonic(increasing: true))
        #expect(critical.maxOvershoot(from: 0, to: 100) < 1e-3)
        #expect(critical.settledTime(target: 100) != nil)
        #expect(!critical.dumpText().isEmpty)

        // Bouncy spring overshoots
        let bouncy = MotionTraceCapture.sampleSpring(Spring(duration: 0.3, bounce: 0.4), from: 0, to: 100)
        #expect(bouncy.maxOvershoot(from: 0, to: 100) > 1.0)
    }

    @Test("Scene.commit honors authored layoutAnim over REFLOW and preserves same-parent sibling reorder")
    func sceneCommitLayoutAnimAndSiblingReorder() {
        var scene = Scene(pixelScale: 2.0)
        let fastId = NodeId.hash("fast-mover")
        let reflowId = NodeId.hash("reflow-mover")
        let slowId = NodeId.hash("slow-mover")

        // Initial cut
        scene.commit([
            NodeSpec(id: fastId, rect: .fromXYWH(0, 0, 80, 30)),
            NodeSpec(id: reflowId, rect: .fromXYWH(0, 40, 80, 30)),
            NodeSpec(id: slowId, rect: .fromXYWH(0, 80, 80, 30)),
        ], at: 0.0)
        _ = scene.frame(at: 0.0)

        // Move with faster-than-REFLOW (0.12s), REFLOW (0.40s), and slower-than-REFLOW (0.90s) springs
        scene.commit([
            NodeSpec(id: fastId, rect: .fromXYWH(200, 0, 80, 30), layoutAnim: LayoutAnim(spring: Spring(duration: 0.12, bounce: 0.0))),
            NodeSpec(id: reflowId, rect: .fromXYWH(200, 40, 80, 30), layoutAnim: LayoutAnim(spring: MotionTokens.REFLOW)),
            NodeSpec(id: slowId, rect: .fromXYWH(200, 80, 80, 30), layoutAnim: LayoutAnim(spring: Spring(duration: 0.90, bounce: 0.0))),
        ], at: 0.1)

        // At t = 0.50 (0.40s elapsed), fastId (0.12s) must already be settled while REFLOW (0.40s) is still moving.
        let fFast = scene.frame(at: 0.50)
        #expect(abs((fFast.byId[fastId]?.rect.left ?? 0) - 200.0) < 0.05)
        #expect(fFast.byId[fastId]?.isMoving == false, "fast 0.12s layoutAnim must be settled by 0.40s elapsed")
        #expect(fFast.byId[reflowId]?.isMoving == true, "0.40s REFLOW control must still be moving at 0.40s elapsed")

        // At t = 1.25 (1.15s elapsed), REFLOW (0.40s) has settled while slowId (0.90s) is still in flight.
        let fSlow = scene.frame(at: 1.25)
        #expect(fSlow.byId[reflowId]?.isMoving == false, "0.40s REFLOW control should have settled by 1.15s elapsed")
        #expect((fSlow.byId[slowId]?.rect.left ?? 200.0) < 199.5, "slow 0.90s layoutAnim must still be in flight past REFLOW")
        #expect(fSlow.byId[slowId]?.isMoving == true)

        // Same-parent sibling reorder (`[a, b] -> [b, a]`) and root reorder updates FrameOutput.nodes order
        var orderScene = Scene(pixelScale: 2.0)
        let parentId = NodeId.hash("parent")
        let childA = NodeId.hash("a")
        let childB = NodeId.hash("b")
        let otherRoot = NodeId.hash("other")

        orderScene.commit([
            NodeSpec(id: parentId, rect: .fromXYWH(0, 0, 200, 200)),
            NodeSpec(id: childA, parent: parentId, rect: .fromXYWH(0, 0, 100, 40)),
            NodeSpec(id: childB, parent: parentId, rect: .fromXYWH(20, 20, 100, 40)),
            NodeSpec(id: otherRoot, rect: .fromXYWH(0, 0, 50, 50)),
        ], at: 0.0)
        let f0 = orderScene.frame(at: 0.0)
        #expect(f0.nodes.map(\.id) == [parentId, otherRoot, childA, childB])

        // Swap children `[a, b] -> [b, a]` and roots `[parent, otherRoot] -> [otherRoot, parent]`
        orderScene.commit([
            NodeSpec(id: otherRoot, rect: .fromXYWH(0, 0, 50, 50)),
            NodeSpec(id: parentId, rect: .fromXYWH(0, 0, 200, 200)),
            NodeSpec(id: childB, parent: parentId, rect: .fromXYWH(20, 20, 100, 40)),
            NodeSpec(id: childA, parent: parentId, rect: .fromXYWH(0, 0, 100, 40)),
        ], at: 0.1)
        let f1 = orderScene.frame(at: 0.1)
        #expect(f1.nodes.map(\.id) == [otherRoot, parentId, childB, childA])
    }

    @Test("Layer regimes match batch sampling and settle bounds (layer.rs:263)")
    func layerKindsSampleAndSettleParity() {
        let eps = Eps(pos: 1e-3, vel: 1e-2)
        let springs = [
            Spring(duration: 0.35, bounce: 0.3), // under
            Spring(duration: 0.35, bounce: 0.0), // critical
            Spring.fromDurationDampingRatio(duration: 0.4, dampingRatio: 1.4), // over
        ]
        for s in springs {
            let layer = Layer.spring(s, at: 0.0, offset: -100.0, v0: 25.0, eps: eps)
            let (p0, v0) = layer.sample(at: 0.0)
            #expect(abs(p0 - (-100.0)) < 1e-3 && abs(v0 - 25.0) < 1e-2)
            let (pend, vend) = layer.sample(at: layer.end + 0.01)
            #expect(abs(pend) <= eps.pos && abs(vend) <= eps.vel)
        }
        let dec = Layer.start(curve: .decay(Decay(rate: 4.0)), at: 0.0, offset: 0.0, velocity: 400.0, eps: eps)
        let tw = Layer.start(curve: .tween(duration: 0.25, easing: .easeInOut), at: 0.0, offset: -50.0, velocity: 10.0, eps: eps)
        let hm = Layer.start(curve: .hermite(duration: 0.3, endVelocity: 0.0), at: 0.0, offset: -40.0, velocity: 20.0, eps: eps)
        #expect(dec.sample(at: dec.end + 0.01).0 == 0 && dec.sample(at: dec.end + 0.01).1 == 0)
        #expect(tw.sample(at: 0.26) == (0, 0))
        #expect(hm.isSettled(at: 0.31) && abs(hm.sample(at: 0.31).0) < 1e-4 && abs(hm.sample(at: 0.31).1) < 1e-3)
    }
}
