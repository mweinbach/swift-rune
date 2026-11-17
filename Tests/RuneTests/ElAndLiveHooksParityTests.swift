import Foundation
import Testing
import RuneMotion
@testable import Rune

@Suite("El and Live Hook Parity Tests")
struct ElAndLiveHooksParityTests {
    private struct DummyState: Sendable {
        var value = 0
    }

    @Test("wrapScrollArea moves placement, aspectFit, anchor, transition to outer and sets clipToContent")
    func wrapScrollAreaTransfersPlacementAndAttributes() {
        let inner: El<DummyState> = col()
            .w(240)
            .h(120)
            .minW(50)
            .p(8)
            .scrollY()
            .above("anchor-target", gutter: 6)
            .aspectFit(1.5)
            .transition(.opacity)

        let (area, key, outer, viewport) = inner.wrapScrollArea()
        #expect(area == "\(key)-scroll-area")
        #expect(outer.keyId == area)
        #expect(viewport.keyId == key)
        #expect(outer.isClipToContent)
        #expect(!viewport.isClipToContent)

        // Box placement moved onto outer
        #expect(outer.layout.width == .points(240))
        #expect(outer.layout.height == .points(120))
        #expect(outer.layout.minWidth == .points(50))
        #expect(outer.layout.aspectFit == 1.5)
        #expect(outer.layout.clipOverflow)
        #expect(outer.anchor?.key == "anchor-target")
        #expect(outer.transition != nil)

        // Viewport expanded inside wrapper and kept its scroll + padding
        #expect(viewport.layout.width == .auto)
        #expect(viewport.layout.height == .auto)
        #expect(viewport.layout.minWidth == .points(0))
        #expect(viewport.layout.minHeight == .points(0))
        #expect(viewport.layout.flexGrow == 1.0)
        #expect(viewport.layout.flexShrink == 1.0)
        #expect(viewport.layout.padding.left == 8)
        #expect(viewport.layout.scrollAxes.contains(.vertical))
        #expect(viewport.layout.aspectFit == nil)
        #expect(viewport.anchor == nil)
        #expect(viewport.transition == nil)
    }

    @Test("preserveFocusOnPress sets runtime extra on El")
    func preserveFocusOnPressFlag() {
        let a: El<DummyState> = row().preserveFocusOnPress(true)
        let b: El<DummyState> = row().preserveFocusOnPress(false)
        let c: El<DummyState> = row()
        #expect(a.preservesFocusOnPress)
        #expect(!b.preservesFocusOnPress)
        #expect(!c.preservesFocusOnPress)
    }

    @Test("scrollWatchState reflects by-hand moves vs initial/layout offset notifications")
    func scrollWatchStateSemantics() {
        #expect(scrollWatchState() == ScrollWatchState(active: false, scrolled: false))

        let rt = Runtime(
            state: DummyState(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in el() }

        var observed: [ScrollWatchState] = []
        let pos0 = ScrollPos(offset: Vec2(0, 0), max: Vec2(0, 200), viewport: Vec2(200, 100), drawn: Vec2(200, 100))
        let pos1 = ScrollPos(offset: Vec2(0, 40), max: Vec2(0, 200), viewport: Vec2(200, 100), drawn: Vec2(200, 100))

        rt.dispatchScrollOffsetWithWatch(path: "sc", pos: pos0) { _ in
            observed.append(scrollWatchState())
        }
        rt.dispatchScrollOffsetWithWatch(path: "sc", pos: pos1) { _ in
            observed.append(scrollWatchState())
        }
        rt.markScrollMovedByHand(path: "sc")
        let pos2 = ScrollPos(offset: Vec2(0, 80), max: Vec2(0, 200), viewport: Vec2(200, 100), drawn: Vec2(200, 100))
        rt.dispatchScrollOffsetWithWatch(path: "sc", pos: pos2) { _ in
            observed.append(scrollWatchState())
        }

        #expect(observed == [
            ScrollWatchState(active: true, scrolled: false),
            ScrollWatchState(active: true, scrolled: false),
            ScrollWatchState(active: true, scrolled: true),
        ])
        #expect(scrollWatchState() == ScrollWatchState(active: false, scrolled: false))
    }

    @Test("Runtime setLiveWaker and livePending coalesce visible Live updates")
    func liveWakerAndPendingLatch() {
        let liveOp = Live<Float>(1.0)
        let wakeCounter = ManagedCounter()
        let rt = Runtime(
            state: DummyState(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            el().size(40, 40).liveOpacity(liveOp.binding)
        }
        _ = rt.frame(at: 0.0)
        rt.setLiveWaker {
            wakeCounter.increment()
        }
        #expect(!rt.livePending)

        liveOp.set(0.5)
        #expect(rt.livePending)
        #expect(wakeCounter.value == 1)

        // Repeated updates coalesce until taken
        liveOp.set(0.25)
        #expect(wakeCounter.value == 1)
        #expect(rt.takeParityLivePending())
        #expect(!rt.livePending)
    }

    @Test("A publication during frame poll leaves a wake for the following frame")
    func publicationDuringPollSurvivesLatch() {
        let live = Live<Float>(1)
        let rt = Runtime(state: false, viewport: Vec2(32, 32)) { _, _ in
            el().key("card").size(32, 32).liveOpacity(live.binding)
        }
        _ = rt.frame(at: 0)
        rt.poll = { published, _, _ in
            if !published {
                published = true
                live.set(0.25)
            }
            return false
        }
        _ = rt.frame(at: 0.1)
        #expect(rt.livePending)
        #expect(rt.element(byKey: "card")?.opacity == 0.25)
        _ = rt.frame(at: 0.2)
        #expect(!rt.livePending)
    }

    @Test("A different source at the same element and property samples its initial color")
    func replacingLiveColorSourceWithSameSequence() {
        let rt = Runtime(state: Live<Color>(.black), viewport: Vec2(12, 12)) { paint, _ in
            el().key("card").size(12, 12).liveFill(paint.binding)
        }
        _ = rt.renderFrame(at: 0)
        rt.update(at: 0.1) { paint, _ in paint = Live(.white) }
        _ = rt.renderFrame(at: 0.1)
        #expect(rt.element(byKey: "card")?.fill == .white)
    }

    @Test("Falling live opacity uses its release spring")
    func fallingLiveOpacityUsesRestSpring() {
        let alpha = Live<Float>(1)
        let rt = Runtime(state: (), viewport: Vec2(20, 20)) { _, _ in
            el().key("card").size(20, 20).liveOpacity(alpha.smooth(Spring(duration: 1)).rest(.none))
        }
        _ = rt.frame(at: 0)
        alpha.set(0.25)
        _ = rt.frame(at: 0.01)
        #expect(rt.element(byKey: "card")?.opacity == 0.25)
        alpha.set(1)
        _ = rt.frame(at: 0.02)
        let opacity = rt.element(byKey: "card")?.opacity ?? 0
        #expect(opacity >= 0.25 && opacity < 1)
    }

    @Test("Hidden pixel streams carry their pending wake across waker replacement")
    func hiddenPixelsKeepWakeOnReplacement() {
        let pixels = Pixels()
        let rt = Runtime(state: (), viewport: Vec2(12, 12)) { _, _ in
            el().size(12, 12).pixels(pixels)
        }
        _ = rt.frame(at: 0)
        rt.setLiveVisible(false)
        pixels.set(width: 1, height: 1, rgba: [255, 0, 0, 255])
        #expect(!rt.takeParityLivePending())
        let counter = ManagedCounter()
        rt.setLiveWaker { counter.increment() }
        #expect(counter.value == 0)
        rt.setLiveVisible(true)
        #expect(counter.value == 1)
        #expect(rt.takeParityLivePending())
        #expect(!rt.livePending)
    }

    @Test("Animated exits retain children once when mounted nodes reuse their prior indices")
    func exitingSubtreeKeepsItsPresentedParent() throws {
        let rt = Runtime(state: true, viewport: Vec2(120, 100)) { showing, _ in
            let root: El<Bool> = col().size(120, 100)
            if showing {
                return root.child(col().key("departing").size(40, 40).transition(.opacity)
                    .child(el().key("before").size(10, 10).bg(.white)))
            }
            return root.child(col().key("arriving").size(40, 40)
                .child(el().key("after").size(10, 10).bg(.black)))
        }
        _ = rt.renderFrame(at: 0)
        rt.update(at: 0.1) { showing, _ in showing = false }
        _ = rt.renderFrame(at: 0.1)
        let elements = rt.elements()
        for (key, parent, exiting) in [("before", "departing", true), ("after", "arriving", false)] {
            let matches = elements.filter { $0.key == key }
            #expect(matches.count == 1)
            let child = try #require(matches.first)
            #expect(child.exiting == exiting)
            let parentIndex = try #require(child.parentIndex)
            #expect(elements[parentIndex].key == parent)
        }
    }

    @Test("Both frame APIs report inherited exit effects and send input to the live replacement", arguments: [false, true])
    func retainedExitInspection(nativeFrame: Bool) throws {
        struct State {
            var showing = true
            var clicks: [String] = []
        }
        let rt = Runtime(state: State(), viewport: Vec2(120, 80), pixelScale: 1) { state, _ in
            let root: El<State> = col().size(120, 80)
            if !state.showing {
                return root.child(el().key("replacement").size(80, 40).role(.button)
                    .onClick { $0.clicks.append("replacement") })
            }
            let controls: [El<State>] = ["ordinary", "raised"].map { key in
                el().key(key).size(40, 40).role(.button).opacity(0.5).raise(key == "raised")
                    .onClick { $0.clicks.append(key) }
            }
            return root.child(row().key("departing").size(80, 40).label("Departing controls")
                .opacity(0.8).transition(.blur(sigma: 4)).children(controls))
        }
        func draw(_ time: Double) {
            if nativeFrame { _ = rt.renderFrame(at: time) } else { _ = rt.frame(at: time) }
        }
        func accessibleIDs(_ node: AccessibilityNode) -> [String] {
            [node.id] + node.children.flatMap(accessibleIDs)
        }

        draw(0)
        let departingKeys = ["departing", "ordinary", "raised"]
        #expect(Set(departingKeys).isSubset(of: accessibleIDs(rt.accessibilitySnapshot())))
        rt.update(at: 0.01) { state, _ in state.showing = false }
        draw(0.01)
        draw(0.06)

        let parent = try #require(rt.element(byKey: "departing"))
        #expect(parent.exiting && parent.inert)
        #expect(parent.blur > 0)
        #expect(parent.opacity > 0 && parent.opacity < 0.8)
        for key in ["ordinary", "raised"] {
            let child = try #require(rt.element(byKey: key))
            #expect(child.exiting && child.inert)
            #expect(abs(child.blur - parent.blur) < 0.0001)
            #expect(abs(child.opacity - parent.opacity * 0.5) < 0.0001)
        }
        let visibleIDs = Set(accessibleIDs(rt.accessibilitySnapshot()))
        #expect(visibleIDs.isDisjoint(with: departingKeys))
        #expect(visibleIDs.contains("replacement"))
        rt.pointerDown(at: Vec2(60, 20), at: 0.07)
        rt.pointerUp(at: Vec2(60, 20), at: 0.08)
        #expect(rt.state.clicks == ["replacement"])
    }

    @Test("Streaming pixels inside a cached subtree stay drawable on each publication")
    func cachedPixelSourceDrawsNewContents() {
        let pixels = Pixels()
        pixels.set(width: 1, height: 1, rgba: [255, 0, 0, 255])
        let rt = Runtime(state: (), viewport: Vec2(16, 16)) { _, _ in
            el().size(16, 16).cache().child(el().size(16, 16).pixels(pixels))
        }
        let frames: [[UInt8]] = [[0, 255, 0, 255], [0, 0, 255, 255]]
        for (frame, value) in frames.enumerated() {
            pixels.set(width: 1, height: 1, rgba: value)
            let instances = rt.renderFrame(at: Double(frame) / 60).instances
            #expect(instances.contains { $0.params.y == KIND_IMAGE })
            #expect(!instances.contains { $0.params.y == KIND_LAYER && $0.params.w == 1 })
        }
    }

    @Test("ParityLayoutAnimation propagates horizontal layout inside growth rows and suppresses initial child fade")
    func animateLayoutGrowthRowRules() {
        let (r0InRow, r0ChildInRow) = ParityLayoutAnimation.resolveRowLayout(
            parentInRow: .free,
            hasAbove: false,
            hasAnimateLayout: false,
            isStackContainer: true
        )
        #expect(r0InRow == .free)
        #expect(r0ChildInRow == .snaps)

        let (animatedRowInRow, animatedChildInRow) = ParityLayoutAnimation.resolveRowLayout(
            parentInRow: .snaps,
            hasAbove: false,
            hasAnimateLayout: true,
            isStackContainer: false
        )
        #expect(animatedRowInRow == .horizontal)
        #expect(animatedChildInRow == .horizontal)

        let anim = ParityLayoutAnimation.resolveNodeLayoutAnim(
            inRow: .horizontal,
            explicitLayoutAnim: LayoutAnim(spring: MotionTokens.SETTLE),
            nodeSpring: MotionTokens.SETTLE,
            parentHasGrowth: false,
            isInstant: false,
            isSameSceneFrame: false,
            commitLands: false
        )
        #expect(anim.x != .instant)
        #expect(anim.y == .instant)

        let growthChildAnim = ParityLayoutAnimation.resolveNodeLayoutAnim(
            inRow: .snaps,
            explicitLayoutAnim: LayoutAnim(spring: MotionTokens.SETTLE),
            nodeSpring: MotionTokens.SETTLE,
            parentHasGrowth: true,
            isInstant: false,
            isSameSceneFrame: false,
            commitLands: false
        )
        #expect(growthChildAnim.x != .instant)
        #expect(growthChildAnim.y == .instant)

        let snapAnim = ParityLayoutAnimation.resolveNodeLayoutAnim(
            inRow: .snaps,
            explicitLayoutAnim: LayoutAnim(spring: MotionTokens.SETTLE),
            nodeSpring: MotionTokens.SETTLE,
            parentHasGrowth: false,
            isInstant: false,
            isSameSceneFrame: false,
            commitLands: false
        )
        #expect(snapAnim.x == .instant)
        #expect(snapAnim.y == .instant)

        #expect(ParityLayoutAnimation.shouldMountAtInitialOpacity(
            inRow: .horizontal,
            parentHasGrowth: false,
            parentNewlyMounted: true,
            hasExplicitInsertion: false,
            reducedMotion: false
        ))
    }
}

private final class ManagedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}
