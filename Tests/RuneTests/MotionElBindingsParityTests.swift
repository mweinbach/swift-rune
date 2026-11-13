import Testing
import Foundation
@testable import Rune

@Suite("El & Runtime Item 2: RideTrailing, ChildExit, Loops, Stagger & LoopClock")
struct MotionElBindingsParityTests {

    @Test("El.rideTrailing flag and Scene.setRideTrailing trailing-edge locking")
    func rideTrailingAndSceneAlignment() {
        let parentId = NodeId.hash("parent")
        let trailingId = NodeId.hash("trailing")

        let el: El<Int> = row()
            .child(el().key("trailing").rideTrailing())
        #expect(!el.isRideTrailing)
        #expect(el.children[0].isRideTrailing)

        var scene = Scene()
        scene.commit([
            NodeSpec(id: parentId, rect: MotionRect.fromXYWH(0, 0, 100, 40)),
            NodeSpec(id: trailingId, parent: parentId, rect: MotionRect.fromXYWH(70, 5, 20, 30)),
        ], at: 0.0, initialCut: true)
        scene.setRideTrailing(trailingId, true)
        _ = scene.frame(at: 0.0)

        let spring = Spring(duration: 0.3, bounce: 0.0)
        scene.commit([
            NodeSpec(
                id: parentId,
                rect: MotionRect.fromXYWH(0, 0, 220, 40),
                layoutAnim: LayoutAnim(spring: spring)
            ),
            NodeSpec(
                id: trailingId,
                parent: parentId,
                rect: MotionRect.fromXYWH(190, 5, 20, 30),
                layoutAnim: LayoutAnim(spring: spring)
            ),
        ], at: 0.01, initialCut: false)

        let out = scene.frame(at: 0.12)
        guard let pNode = out.nodes.first(where: { $0.id == parentId }),
              let tNode = out.nodes.first(where: { $0.id == trailingId }) else {
            Issue.record("Missing scene nodes")
            return
        }
        // Right gap was 100 - (70 + 20) = 10pt; trailing child rides parent's animated right edge!
        #expect(abs((pNode.rect.right - tNode.rect.right) - 10.0) < 0.5)
    }

    @Test("El.childExit sets transition and ChildExitHook overrides exiting direct child")
    func childExitHookOverridesExitingChild() {
        let fadeSlide = Transition(symmetric: TransitionEffect(zeroOpacity: 0, pointOffset: Vec2(0, 12)))
        let container: El<Int> = col().childExit(fadeSlide)
        #expect(container.childExitTransition == fadeSlide)

        let parentId = NodeId.hash("list")
        let rowId = NodeId.hash("row1")
        var scene = Scene()
        scene.commit([
            NodeSpec(id: parentId, rect: MotionRect.fromXYWH(0, 0, 200, 100)),
            NodeSpec(id: rowId, parent: parentId, rect: MotionRect.fromXYWH(0, 0, 200, 30)),
        ], at: 0.0, initialCut: true)
        _ = scene.frame(at: 0.0)

        ChildExitHook.apply(parentEl: container, childId: rowId, to: &scene)
        scene.remove(rowId)
        let mid = scene.frame(at: 0.05)
        guard let exitingRow = mid.nodes.first(where: { $0.id == rowId }) else {
            Issue.record("Expected exiting row to remain visible during childExit transition")
            return
        }
        #expect(exitingRow.opacity < 1.0)
        #expect(exitingRow.rect.top > 0.0)
    }

    @Test("MotionLoopExtensions cycle/loopOpacity/loopRotation/loopSlide and Stagger cascade")
    func motionLoopExtensionsAndStagger() {
        let stagger = Stagger.cascade(0.06, cap: 0.18)
        let item0: El<Int> = el().enterDelay(stagger, index: 0, count: 5)
        let item4: El<Int> = el().enterDelay(stagger, index: 4, count: 5)
        #expect(stagger.delay(0, of: 5) == 0.0)
        #expect(abs(stagger.delay(4, of: 5) - 0.18) < 1e-5)
        #expect(item0.loopingSpec == nil)
        _ = item4

        let cycEl: El<Int> = el().cycle(
            period: 1.0,
            phase: 0.0,
            stops: [(0.0, 0.0), (0.5, 1.0), (1.0, 0.0)],
            still: 0.4,
            fps: 30.0
        )
        #expect(cycEl.loopingSpec?.period == 1.0)
        if case .opacityCycle(let c) = cycEl.loopingSpec?.kind {
            #expect(c.fps == 30.0)
            #expect(c.still == 0.4)
        } else {
            Issue.record("Expected .opacityCycle LoopKind")
        }

        let opEl: El<Int> = el().loopOpacity(low: 0.2, high: 0.8, period: 2.0, delay: 0.5)
        #expect(opEl.loopingSpec == LoopSpec.opacity(period: 2.0, delay: 0.5, low: 0.2, high: 0.8))

        let rotEl: El<Int> = el().loopRotation(period: 1.5, delay: 0.25)
        #expect(rotEl.loopingSpec == LoopSpec(period: 1.5, delay: 0.25, kind: .rotation))

        let slideEl: El<Int> = el().loopSlide(
            period: 1.0,
            from: Vec2(-1, 0),
            to: Vec2(4, 0),
            easing: .linear
        )
        #expect(slideEl.loopingSpec == LoopSpec.slide(period: 1.0, from: Vec2(-1, 0), to: Vec2(4, 0)).easing(.linear))
    }

    @Test("LoopClock preserves periodic phase across timeScale changes and scales pending wakes")
    func loopClockTimeScaleAndDelayedWake() {
        var clock = LoopClock(scale: 1.0, at: 0.0)
        let id = NodeId.hash("spin")
        var tracks: [NodeId: LoopTrack] = [
            id: LoopTrack(spec: .rotation(period: 2.0), now: 0.0),
        ]

        // Step 0.5s at scale 1.0 -> phase 0.25
        _ = clock.syncTracks(&tracks, to: 0.5, scale: 0.5)
        let phaseBeforeScaleChange = tracks[id]!.phase(at: 0.5)
        #expect(abs(phaseBeforeScaleChange - 0.25) < 1e-6)

        // Advance 1.0s app time at scale 0.5 -> +0.5s scaled (+0.25 phase => 0.50 total)
        _ = clock.syncTracks(&tracks, to: 1.5, scale: 0.5)
        let phaseAfterHalfSpeed = tracks[id]!.phase(at: 1.5)
        #expect(abs(phaseAfterHalfSpeed - 0.50) < 1e-6)

        // Pause with scale 0.0 across 2.0s app time -> phase stays locked at 0.50
        _ = clock.syncTracks(&tracks, to: 1.5, scale: 0.0)
        _ = clock.syncTracks(&tracks, to: 3.5, scale: 0.0)
        #expect(abs(tracks[id]!.phase(at: 3.5) - 0.50) < 1e-6)

        // Delayed loop wakes at 2.0 / timeScale (matches loop_sleep.rs:delayed_loops_sleep_on_the_shared_deadline)
        let delayed = LoopTrack(spec: .opacity(period: 1.0, delay: 2.0, low: 0.0, high: 1.0), now: 0.0)
        #expect(LoopClock.nextPendingStart(tracks: [delayed], at: 0.0, reducedMotion: false, timeScale: 1.0) == 2.0)
        #expect(LoopClock.nextPendingStart(tracks: [delayed], at: 0.0, reducedMotion: false, timeScale: 0.5) == 4.0)
        #expect(LoopClock.nextPendingStart(tracks: [delayed], at: 0.0, reducedMotion: true, timeScale: 1.0) == nil)
        #expect(LoopClock.nextPendingStart(tracks: [delayed], at: 0.0, reducedMotion: false, timeScale: 0.0) == nil)
    }
}
