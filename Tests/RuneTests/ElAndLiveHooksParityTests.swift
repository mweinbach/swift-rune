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
