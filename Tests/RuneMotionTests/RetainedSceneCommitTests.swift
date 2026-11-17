import Foundation
import Testing
@testable import RuneMotion

@Suite("Retaining unchanged scene nodes")
struct RetainedSceneCommitTests {
    @Test func restingNodesKeepTheirPresentationAndFollowAMovedParent() throws {
        var scene = Scene()
        var parent = NodeSpec(id: NodeId(1), rect: .fromXYWH(10, 20, 80, 60))
        var child = NodeSpec(id: NodeId(2), parent: parent.id, rect: .fromXYWH(15, 27, 10, 8),
                             opacity: 0.75, corners: .all(2), styleSpring: MotionTokens.SMOOTH)
        scene.commit([parent, child], at: 0)
        let mounted = scene.frame(at: 0)
        var ordinary = scene
        ordinary.commit([parent, child], at: 0.1)
        let reapplied = ordinary.frame(at: 0.1)
        #expect(reapplied.changed.map(\.id) == [parent.id, child.id])

        scene.commit([parent, child], at: 0.1, retainingUnchanged: true)
        let same = scene.frame(at: 0.1)
        #expect(same.changed.isEmpty)
        #expect(same.nodes == mounted.nodes)
        #expect(same.nodes == reapplied.nodes)

        parent.rect = parent.rect.translated(Vec2(20, 4))
        child.rect = child.rect.translated(Vec2(20, 4))
        scene.commit([parent, child], at: 0.2, retainingUnchanged: true)
        let moved = scene.frame(at: 0.2)
        #expect(moved.changed.map(\.id) == [parent.id, child.id])
        let shown = try #require(moved.byId[child.id])
        #expect(shown.rect == child.rect)
        #expect(shown.parent == parent.id)
        #expect(shown.opacity == child.opacity)
        #expect(shown.corners == child.corners)
    }

    @Test func aSleepingExternalTrackReturnsToTheAuthoredValue() throws {
        let spec = NodeSpec(id: NodeId(3), rect: .fromXYWH(5, 7, 25, 30), opacity: 0.9)
        var scene = Scene()
        scene.commit([spec], at: 0)
        _ = scene.frame(at: 0)
        scene.store.set(spec.id, Props.OPACITY, 0.2)
        #expect(scene.store.activeLen == 0)
        #expect(scene.get(spec.id, Props.OPACITY) == 0.2)
        scene.commit([spec], at: 0.1, retainingUnchanged: true)
        let after = scene.frame(at: 0.1)
        #expect(scene.store.target(spec.id, Props.OPACITY) == spec.opacity)
        let shown = try #require(after.changed.first { $0.id == spec.id })
        #expect(shown.opacity == spec.opacity)
    }

    @Test func anActiveOpacityTrackKeepsItsVelocityAndTakesANewTarget() throws {
        var scene = Scene()
        var spec = NodeSpec(id: NodeId(5), rect: .fromXYWH(0, 0, 24, 24))
        scene.commit([spec], at: 0)
        _ = scene.frame(at: 0)
        scene.animate(spec.id, Props.OPACITY, to: 0.4, spring: MotionTokens.SMOOTH)
        _ = scene.frame(at: 0.03)
        scene.keepFlights(true)
        var ordinary = scene

        spec.opacity = 0.4
        ordinary.commit([spec], at: 0.04)
        scene.commit([spec], at: 0.04, retainingUnchanged: true)
        let expected = ordinary.frame(at: 0.06)
        let actual = scene.frame(at: 0.06)
        #expect(actual.nodes == expected.nodes)
        let moving = try #require(actual.byId[spec.id])
        #expect(moving.opacity > 0.4 && moving.opacity < 1)
        #expect(scene.store.isAnimating(spec.id, Props.OPACITY))

        spec.opacity = 0.8
        ordinary.commit([spec], at: 0.07)
        scene.commit([spec], at: 0.07, retainingUnchanged: true)
        let landed = scene.frame(at: 0.07)
        #expect(landed.nodes == ordinary.frame(at: 0.07).nodes)
        #expect(landed.byId[spec.id]?.opacity == spec.opacity)
        #expect(!scene.store.isAnimating(spec.id, Props.OPACITY))
    }

    @Test func changingTheTransitionKeepsOmissionAndRevivalWorking() throws {
        var scene = Scene()
        var spec = NodeSpec(id: NodeId(4), rect: .fromXYWH(5, 7, 25, 30))
        scene.commit([spec], at: 0)
        _ = scene.frame(at: 0)
        spec.transition = .opacity
        scene.commit([spec], at: 0.1, retainingUnchanged: true)
        _ = scene.frame(at: 0.1)
        scene.commit([], at: 0.2, retainingUnchanged: true)
        let leaving = scene.frame(at: 0.23)
        #expect(leaving.byId[spec.id]?.isExiting == true)
        scene.commit([spec], at: 0.24, retainingUnchanged: true)
        #expect(scene.phase(spec.id) == .entering)
        _ = scene.frame(at: 0.24)
        let revived = scene.frame(at: 2)
        let shown = try #require(revived.byId[spec.id])
        #expect(shown.phase == .present)
        #expect(shown.opacity == 1)
        #expect(!revived.exited.contains(spec.id))
    }

    @Test func matchingLocalFramesStillRelinkAndReorder() throws {
        var scene = Scene()
        let left = NodeSpec(id: NodeId(10), rect: .fromXYWH(0, 0, 40, 40))
        let right = NodeSpec(id: NodeId(20), rect: .fromXYWH(50, 0, 40, 40))
        var child = NodeSpec(id: NodeId(11), parent: left.id, rect: .fromXYWH(2, 3, 8, 9))
        let a = NodeSpec(id: NodeId(21), parent: right.id, rect: .fromXYWH(52, 10, 8, 9))
        let b = NodeSpec(id: NodeId(22), parent: right.id, rect: .fromXYWH(52, 20, 8, 9))
        scene.commit([left, child, right, a, b], at: 0)
        _ = scene.frame(at: 0)
        child.parent = right.id
        child.rect = child.rect.translated(Vec2(50, 0))
        scene.commit([left, right, b, child, a], at: 0.1, retainingUnchanged: true)
        let reordered = scene.frame(at: 0.1)
        #expect(reordered.nodes.map(\.id) == [left.id, right.id, b.id, child.id, a.id])
        let moved = try #require(reordered.byId[child.id])
        #expect(moved.parent == right.id)
        #expect(moved.rect == child.rect)
    }

    @Test func transparentPaintAndAbsentPaintAreDistinct() throws {
        var scene = Scene()
        var spec = NodeSpec(id: NodeId(30), rect: .fromXYWH(0, 0, 40, 40))
        scene.commit([spec], at: 0)
        _ = scene.frame(at: 0)
        for step in 1...3 {
            let time = 0.1 * Double(step)
            spec.fill = step == 1 ? .zeroValue : nil
            spec.border = step == 2 ? .zeroValue : nil
            scene.commit([spec], at: time, retainingUnchanged: true)
            let frame = scene.frame(at: time)
            let shown = try #require(frame.changed.first { $0.id == spec.id })
            #expect(shown.fill == spec.fill)
            #expect(shown.border == spec.border)
        }
    }

    private func landProperties(_ scene: inout Scene, spec: NodeSpec, localFrame: MotionRect) {
        scene.landFrame(spec.id, localFrame)
        if let fill = spec.fill { scene.set(spec.id, Props.FILL, fill) }
        if let border = spec.border { scene.set(spec.id, Props.BORDER, border) }
        scene.set(spec.id, Props.OPACITY, spec.opacity)
        scene.set(spec.id, Props.BLUR, Blur(spec.blur))
        scene.set(spec.id, Props.CORNERS, spec.corners)
        scene.set(spec.id, Props.OFFSET, spec.offset)
        scene.set(spec.id, Props.SCALE, spec.scale)
        scene.set(spec.id, Props.ROTATE, spec.rotate)
    }

    @Test func unseenLandingMatchesPublicOperationsForMovingFramesAndColors() throws {
        let parent = NodeSpec(id: NodeId(40), rect: .fromXYWH(50, 30, 100, 100))
        let original = NodeSpec(id: NodeId(41), parent: parent.id, rect: .fromXYWH(52, 34, 16, 18),
                                fill: .rgba(1, 0, 0, 1), border: .rgba(0, 1, 0, 1))
        let finalColor = MotionColor.rgba(0, 0, 1, 1)
        let localFrame = MotionRect.fromXYWH(12, 14, 24, 26)
        for keep in [false, true] {
            var scene = Scene()
            scene.commit([parent, original], at: 0)
            _ = scene.frame(at: 0)
            scene.setFrame(original.id, .fromXYWH(70, 60, 28, 30), MotionTokens.SMOOTH)
            scene.animate(original.id, Props.FILL, to: finalColor, spring: MotionTokens.SMOOTH)
            _ = scene.frame(at: 0.03)
            #expect(scene.store.isAnimating(original.id, Props.FRAME))
            #expect(scene.store.isAnimating(original.id, Props.FILL))
            scene.keepFlights(keep)
            var control = scene
            let target = NodeSpec(id: original.id, parent: parent.id, rect: localFrame.translated(parent.rect.origin),
                                  opacity: 0.8, scale: Vec2(1.1, 0.9), rotate: 0.2, offset: Vec2(3, 4),
                                  corners: .all(2), blur: 1, fill: finalColor, border: .rgba(1, 1, 0, 1))
            landProperties(&control, spec: target, localFrame: localFrame)
            scene.landUnseen(target, localFrame: localFrame)
            #expect(!scene.store.isAnimating(target.id, Props.FRAME))
            #expect(scene.store.isAnimating(target.id, Props.FILL) == keep)
            #expect(scene.get(target.id, Props.FRAME) == localFrame)
            let actual = scene.frame(at: 0.04)
            let expected = control.frame(at: 0.04)
            #expect(actual.nodes == expected.nodes)
            #expect(actual.changed == expected.changed)
            if !keep {
                let fill = try #require(actual.byId[target.id]?.fill)
                #expect(abs(fill.r - finalColor.r) < 0.00001 && abs(fill.g - finalColor.g) < 0.00001)
                #expect(abs(fill.b - finalColor.b) < 0.00001 && abs(fill.a - finalColor.a) < 0.00001)
            }
        }
    }

    @Test func landingAnUnchangedUnseenNodeKeepsItClean() {
        var scene = Scene()
        let spec = NodeSpec(id: NodeId(50), rect: .fromXYWH(5, 7, 25, 30), fill: .rgba(0, 1, 0, 1))
        scene.commit([spec], at: 0)
        let previous = scene.frame(at: 0)
        var control = scene
        landProperties(&control, spec: spec, localFrame: spec.rect)
        scene.landUnseen(spec, localFrame: spec.rect)
        let actual = scene.frame(at: 0.1)
        let expected = control.frame(at: 0.1)
        #expect(actual.nodes == previous.nodes)
        #expect(actual.nodes == expected.nodes)
        #expect(actual.changed.isEmpty && expected.changed.isEmpty)
        #expect(scene.store.trackLen == 0)
    }

    @Test func clearingTheStoreInvalidatesTheLastPresentedProperty() throws {
        let spec = NodeSpec(id: NodeId(51), rect: .fromXYWH(5, 7, 25, 30), opacity: 1)
        for landOnly in [false, true] {
            var scene = Scene()
            scene.commit([spec], at: 0)
            _ = scene.frame(at: 0)
            scene.set(spec.id, Props.OPACITY, 0.25)
            #expect(scene.frame(at: 0.1).byId[spec.id]?.opacity == 0.25)
            scene.store.clear()
            #expect(scene.store.trackLen == 0)
            var control = scene
            if landOnly {
                landProperties(&control, spec: spec, localFrame: spec.rect)
                scene.landUnseen(spec, localFrame: spec.rect)
            } else {
                control.commit([spec], at: 0.2)
                scene.commit([spec], at: 0.2, retainingUnchanged: true)
            }
            let actual = scene.frame(at: 0.2)
            let expected = control.frame(at: 0.2)
            let shown = try #require(expected.byId[spec.id])
            #expect(shown.opacity == spec.opacity)
            #expect(actual.nodes == expected.nodes)
            #expect(actual.changed == expected.changed)
        }
    }

    @Test func tracingPreservesPropertyIntentsOnAnUnchangedCommit() throws {
        func capture(retaining: Bool) -> String {
            var scene = Scene()
            let spec = NodeSpec(id: NodeId(42), rect: .fromXYWH(4, 8, 32, 24),
                                fill: .rgba(1, 0, 0, 1), styleSpring: MotionTokens.SMOOTH)
            scene.commit([spec], at: 0)
            _ = scene.frame(at: 0)
            let trace = MotionTrace(header: TraceHeader(launch: "retained", width: 80, height: 80, hz: 60, scale: 1))
            scene.setTrace(trace)
            _ = scene.frame(at: 0.05)
            if retaining { scene.commit([spec], at: 0.1, retainingUnchanged: true) }
            else { scene.commit([spec], at: 0.1) }
            _ = scene.frame(at: 0.1)
            return trace.contents()
        }

        let original = capture(retaining: false)
        #expect(capture(retaining: true) == original)
        let line = try #require(original.split(separator: "\n").last)
        let frame = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let intents = try #require(frame["ai"] as? [[NSNumber]])
        let properties = Set(intents.compactMap { $0.count == 7 ? $0[5].uint32Value : nil })
        #expect(properties.contains(TraceIntent.opacity))
        #expect(properties.contains(TraceIntent.contents))
        #expect(properties.contains(TraceIntent.shape))
    }
}
