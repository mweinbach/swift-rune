import Foundation
import Testing
@testable import Rune
@testable import RuneMotion

#if os(macOS)
import AppKit
#endif

/// Host-facing runtime APIs (`runtime/input/titlebar.rs` `set_chrome_insets` / `chrome_insets`,
/// `runtime/drag_out_host.rs` `take_drag_out`). The drag-out geometry ports
/// `runtime/tests/pointer_drag.rs:171` and `:361` 1:1; upstream has no `#[test]` for
/// `set_chrome_insets` itself, so those are regression tests of its behaviour.
@Suite("Host Runtime API Parity Tests", .serialized)
struct HostRuntimeApiParityTests {
    // MARK: - pointer_drag.rs ports

    private struct DragOutState {
        var presses = 0
        var drags = 0
        var offer = false
        var ended: [DragOutcome] = []
        var dragging = false
        var starts = 0
        var log: [String] = []
    }

    /// `pointer_drag.rs:152` `drag_out_view`.
    private static func dragOutView(_ s: DragOutState, _ cx: inout Cx<DragOutState>) -> El<DragOutState> {
        col().size(200, 200).child(
            el().key("file").size(100, 40)
                .onClick { s in s.presses += 1 }
                .onDrag { s, _, _ in s.drags += 1 }
                .dragOut { s in s.offer ? DragItem().file(path: "/Applications/Example.app") : nil }
                .onDragStart { s, _ in s.dragging = true; s.starts += 1; s.log.append("start") }
                .onDragOutEnd { s, outcome, _ in s.dragging = false; s.ended.append(outcome); s.log.append("end \(outcome)") }
        )
    }

    /// `pointer_drag.rs:162` `drag_out_rt`.
    private static func dragOutRt(offer: Bool) -> Runtime<DragOutState> {
        let rt = Runtime(state: DragOutState(offer: offer), viewport: Vec2(200, 200), pixelScale: 1.0, view: dragOutView)
        _ = rt.frame(at: 0.0)
        rt.pointerMove(to: Vec2(10, 10), at: 0.0)
        rt.pointerDown(at: Vec2(10, 10), at: 0.0)
        return rt
    }

    /// `pointer_drag.rs:171` `crossing_the_threshold_hands_a_drag_out_to_the_host_and_releases_the_pointer`.
    @Test func crossingTheThresholdHandsADragOutToTheHostAndReleasesThePointer() throws {
        let rt = Self.dragOutRt(offer: true)
        let t = DragItem.defaultThreshold
        #expect(t == 4.0, "DRAG_THRESHOLD on Apple platforms")
        rt.pointerMove(to: Vec2(10 + t, 10), at: 0.0)
        #expect(rt.takeDragOutStart() == nil, "at the threshold it's still a press")
        #expect(rt.pointerCaptured)
        rt.pointerMove(to: Vec2(12 + t, 10), at: 0.0)
        let start = try #require(rt.takeDragOutStart(), "drag-out requested")
        #expect(start.item.files.map(\.path) == ["/Applications/Example.app"])
        #expect(start.press == Vec2(10, 10))
        #expect(start.rect == .fromXYWH(0, 0, 100, 40))
        #expect(rt.events.contains { $0.hasPrefix("drag-out ") && $0.hasSuffix("file") }, "\(rt.events)")
        #expect(!rt.pointerCaptured && rt.pointer() == nil, "nothing stays pressed or hovered")
        rt.pointerMove(to: Vec2(40, 30), at: 0.0)
        #expect(rt.takeDragOutStart() == nil, "one request per press")
        rt.pointerUp(at: Vec2(40, 30), at: 0.0)
        _ = rt.frame(at: 0.0)
        #expect(rt.state.presses == 0 && rt.state.drags == 0, "neither on_press nor on_drag runs")
    }

    /// `pointer_drag.rs:361` `a_drag_image_over_the_element_gets_its_unclipped_bounds`.
    @Test func aDragImageOverTheElementGetsItsUnclippedBounds() throws {
        let rt = Runtime(state: DragOutState(), viewport: Vec2(200, 200), pixelScale: 1.0) { (_: DragOutState, _: inout Cx<DragOutState>) -> El<DragOutState> in
            col().child(
                col().size(200, 100).clipSoft(0.0)
                    .child(el().size(200, 80))
                    .child(el().key("row").size(200, 40).dragOut { _ in DragItem().text("row") })
            )
        }
        _ = rt.frame(at: 0.0)
        rt.pointerMove(to: Vec2(10, 90), at: 0.0)
        rt.pointerDown(at: Vec2(10, 90), at: 0.0)
        rt.pointerMove(to: Vec2(40, 90), at: 0.0)
        let start = try #require(rt.takeDragOutStart())
        #expect(start.rect == .fromXYWH(0, 80, 200, 20), "the visible strip")
        #expect(start.bounds == .fromXYWH(0, 80, 200, 40), "the whole row")
    }

    // MARK: - set_chrome_insets / chrome_insets

    @Test func setChromeInsetsStoresReturnsAndRerunsViewOnlyOnChange() {
        struct S { var zoom: Float = 1.0 }
        let seen = HostChromeRecorder()
        let rt = Runtime(state: S(), viewport: Vec2(400, 300), pixelScale: 2.0) { s, cx in
            if s.zoom != 1.0 { cx.zoom(s.zoom) }
            seen.record(cx.chromeInsets())
            return el().size(10, 10)
        }
        _ = rt.frame(at: 0.0)
        let runsAtRest = seen.runs
        #expect(seen.last == .zero)
        #expect(rt.windowChromeInsets() == .zero)

        // A change dirties the view, which re-runs and reads the new insets.
        let mac = ChromeInsets(leading: 78, trailing: 0, height: 38)
        rt.setChromeInsets(mac)
        #expect(rt.needsCommit)
        _ = rt.frame(at: 0.1)
        #expect(seen.runs == runsAtRest + 1)
        #expect(seen.last == mac)
        #expect(rt.windowChromeInsets() == mac)
        #expect(rt.chromeInsets() == mac)

        // The same insets again (every resize sets them) leave the view alone.
        rt.setChromeInsets(mac)
        #expect(!rt.needsCommit)
        _ = rt.frame(at: 0.2)
        #expect(seen.runs == runsAtRest + 1)

        // Full screen: the traffic lights leave, the band goes; the view re-runs.
        rt.setChromeInsets(.zero)
        #expect(rt.needsCommit)
        _ = rt.frame(at: 0.3)
        #expect(seen.runs == runsAtRest + 2)
        #expect(seen.last == .zero)
        #expect(rt.windowChromeInsets() == .zero)

        // A right-to-left app's traffic lights, as the trailing inset.
        let rtl = ChromeInsets(leading: 0, trailing: 78, height: 38)
        rt.setChromeInsets(rtl)
        _ = rt.frame(at: 0.4)
        #expect(seen.last == rtl)
        #expect(rt.windowChromeInsets() == rtl)
    }

    @Test func hostChromeInsetsAreWindowPointsAndViewReadsThemOverZoom() {
        struct S { var zoom: Float = 1.0 }
        let seen = HostChromeRecorder()
        let rt = Runtime(state: S(), viewport: Vec2(400, 300), pixelScale: 2.0) { s, cx in
            if s.zoom != 1.0 { cx.zoom(s.zoom) }
            seen.record(cx.chromeInsets())
            return el().size(10, 10)
        }
        rt.setChromeInsets(ChromeInsets(leading: 78, trailing: 12, height: 38))
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.05) { s, _ in s.zoom = 2.0 }
        _ = rt.frame(at: 0.1)
        _ = rt.frame(at: 0.2)
        #expect(rt.zoom() == 2.0)
        // `Runtime::chrome_insets` stays in window points ...
        #expect(rt.windowChromeInsets() == ChromeInsets(leading: 78, trailing: 12, height: 38))
        // ... and the view reads them over its zoom (`Measurement::chrome`: `insets.zoomed(k)`).
        #expect(rt.chromeInsets() == ChromeInsets(leading: 39, trailing: 6, height: 19))
        #expect(seen.last == ChromeInsets(leading: 39, trailing: 6, height: 19))
    }

    @Test func hostChromeInsetsOverrideTheHeadlessTitlebarDerivation() {
        let rt = Runtime(state: 0, viewport: Vec2(400, 300), pixelScale: 2.0) { _, _ in
            el().size(10, 10)
        }
        // Without a host, the headless derivation from `App::titlebar` stands in.
        rt.setTitlebarInset(76)
        rt.setBaseTitlebar(Titlebar(height: 38))
        _ = rt.frame(at: 0.0)
        #expect(rt.windowChromeInsets() == ChromeInsets(leading: 76, trailing: 0, height: 38))

        // A native window's controls win from then on, whatever the titlebar says.
        let native = ChromeInsets(leading: 80, trailing: 0, height: 28)
        rt.setChromeInsets(native)
        #expect(rt.windowChromeInsets() == native)
        rt.setBaseTitlebar(Titlebar(height: 52))
        rt.setTitlebarInset(70)
        _ = rt.frame(at: 0.1)
        #expect(rt.windowChromeInsets() == native)
        #expect(rt.chromeInsets() == native)

        // Setting what is already reported (the derivation) does not dirty the view.
        let other = Runtime(state: 0, viewport: Vec2(400, 300), pixelScale: 2.0) { _, _ in
            el().size(10, 10)
        }
        other.setTitlebarInset(76)
        other.setBaseTitlebar(Titlebar(height: 38))
        _ = other.frame(at: 0.0)
        other.setChromeInsets(ChromeInsets(leading: 76, trailing: 0, height: 38))
        #expect(!other.needsCommit)
    }

    // MARK: - take_drag_out

    private struct DragState {
        var zoom: Float = 1.0
        var starts = 0
    }

    private static func dragRuntime() -> Runtime<DragState> {
        Runtime(state: DragState(), viewport: Vec2(400, 300), pixelScale: 2.0) { s, cx in
            if s.zoom != 1.0 { cx.zoom(s.zoom) }
            return col().children([
                col().key("pane").size(100, 50).scroll().children([
                    el().key("card").size(80, 120)
                        .dragThreshold(4)
                        .dragOut { _ in DragItem().text("card") }
                        .onDragStart { s, _ in s.starts += 1 }
                ])
            ])
        }
    }

    @Test func takeDragOutReportsVisibleRectBoundsAndPressInViewPointsAtZoomOne() throws {
        let rt = Self.dragRuntime()
        _ = rt.frame(at: 0.0)
        let card = try #require(rt.element(byKey: "card"))
        #expect(card.rect == [0, 0, 80, 120])

        rt.pointerMove(to: Vec2(10, 10), at: 0.01)
        rt.pointerDown(at: Vec2(10, 10), at: 0.02)
        rt.pointerMove(to: Vec2(20, 10), at: 0.03)
        let start = try #require(rt.takeDragOutStart())
        #expect(rt.state.starts == 1)
        #expect(start.key == "card")
        #expect(start.item.text == "card")
        // The whole drawn rect, before the pane's scroll clip ...
        #expect(start.bounds == .fromXYWH(0, 0, 80, 120))
        // ... and the visible part the pane shows.
        #expect(start.rect == .fromXYWH(0, 0, 80, 50))
        // Where the pointer went down (`held.at`), not where the threshold was crossed.
        #expect(start.press == Vec2(10, 10))
        #expect(rt.takeDragOutStart() == nil)
    }

    @Test func takeDragOutScalesRectBoundsAndPressByZoom() throws {
        let rt = Self.dragRuntime()
        rt.update(at: 0.0) { s, _ in s.zoom = 2.0 }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 0.01)
        #expect(rt.zoom() == 2.0)
        #expect(rt.viewport == Vec2(200, 150))
        let card = try #require(rt.element(byKey: "card"))
        #expect(card.rect == [0, 0, 80, 120])

        // Pointer input is in view points (the window's over the zoom).
        rt.pointerMove(to: Vec2(10, 10), at: 0.02)
        rt.pointerDown(at: Vec2(10, 10), at: 0.03)
        rt.pointerMove(to: Vec2(20, 10), at: 0.04)
        let start = try #require(rt.takeDragOutStart())
        #expect(rt.state.starts == 1)
        // `take_drag_out`: rect, bounds and press times `zoom()`, in window points.
        #expect(start.bounds == .fromXYWH(0, 0, 160, 240))
        #expect(start.rect == .fromXYWH(0, 0, 160, 100))
        #expect(start.press == Vec2(20, 20))
        #expect(start.key == "card")
    }

    @Test func dragOutVisibleRectClampsFullyClippedSidesToZero() {
        typealias R = Runtime<Int>
        let bounds = MotionRect.fromXYWH(10, 60, 80, 40)
        // No clipping ancestor: the whole rect (`NO_CLIP`).
        #expect(R.dragOutVisibleRect(bounds: bounds, clip: nil) == bounds)
        // Partly clipped on every side.
        #expect(R.dragOutVisibleRect(bounds: bounds, clip: .fromXYWH(20, 70, 50, 20)) == .fromXYWH(20, 70, 50, 20))
        // Scrolled out of view: empty, never negative.
        #expect(R.dragOutVisibleRect(bounds: bounds, clip: .fromXYWH(0, 0, 100, 50)) == .fromXYWH(10, 60, 80, 0))
    }

    @Test func dragOutStartZoomedScalesEveryCoordinate() {
        let start = DragOutStart(
            item: DragItem().text("x"),
            rect: .fromXYWH(1, 2, 3, 4),
            bounds: .fromXYWH(1, 2, 3, 10),
            press: Vec2(2, 3),
            key: "k"
        )
        let z = start.zoomed(1.5)
        #expect(z.rect == .fromXYWH(1.5, 3, 4.5, 6))
        #expect(z.bounds == .fromXYWH(1.5, 3, 4.5, 15))
        #expect(z.press == Vec2(3, 4.5))
        #expect(z.key == "k")
        #expect(z.item == start.item)
        // Without a separate visible rect, it is the bounds.
        #expect(DragOutStart(item: DragItem(), bounds: .fromXYWH(0, 0, 5, 5), press: .zero).rect == .fromXYWH(0, 0, 5, 5))
    }

    // MARK: - screen_clip_of (`turn.rs:67`)

    @Test func screenClipOfParentFollowsTurnsLikeUpstream() {
        typealias R = Runtime<Int>
        let clip = MotionRect.fromXYWH(0, 0, 100, 50)
        // No turn: the inherited clip, `NO_CLIP` staying `nil`.
        #expect(R.screenClipOfParent(inheritedClip: clip, ancestorTurn: nil, outerTurnClip: nil, localTurnClip: nil) == clip)
        #expect(R.screenClipOfParent(inheritedClip: nil, ancestorTurn: nil, outerTurnClip: nil, localTurnClip: nil) == nil)
        // Under a quarter turn about (50, 25): the outer clip cut to the turned local clip's bbox.
        let turn = Turn.about(Vec2(50, 25), radians: .pi / 2)
        let bbox = turn.bbox(clip)
        #expect(abs(bbox.left - 25) < 1e-3 && abs(bbox.top - -25) < 1e-3 && abs(bbox.right - 75) < 1e-3 && abs(bbox.bottom - 75) < 1e-3)
        let outer = MotionRect.fromXYWH(0, 0, 60, 60)
        let got = R.screenClipOfParent(inheritedClip: nil, ancestorTurn: turn, outerTurnClip: outer, localTurnClip: clip)
        #expect(got == intersectRects(outer, bbox))
        // `NO_CLIP` inside the turn leaves the outer clip; nothing at all stays `NO_CLIP`.
        #expect(R.screenClipOfParent(inheritedClip: nil, ancestorTurn: turn, outerTurnClip: outer, localTurnClip: nil) == outer)
        #expect(R.screenClipOfParent(inheritedClip: clip, ancestorTurn: turn, outerTurnClip: nil, localTurnClip: nil) == nil)
    }

    // MARK: - take_titlebar_changed + sync_chrome

    @Test func takeTitlebarChangedReportsANewViewTitlebarOnce() {
        struct S { var h: Float? = nil }
        let rt = Runtime(state: S(), viewport: Vec2(400, 300), pixelScale: 2.0) { s, cx in
            if let h = s.h { cx.titlebarHeight(h) }
            return el().size(10, 10)
        }
        _ = rt.frame(at: 0.0)
        #expect(!rt.takeTitlebarChanged())
        rt.update(at: 0.05) { s, _ in s.h = 52 }
        _ = rt.frame(at: 0.1)
        #expect(rt.takeTitlebarChanged())
        #expect(!rt.takeTitlebarChanged(), "taken")
        rt.update(at: 0.15) { s, _ in s.h = 52 }
        _ = rt.frame(at: 0.2)
        #expect(!rt.takeTitlebarChanged(), "the same set is no change")
    }

    #if os(macOS)
    /// `window/chrome.rs::sync_chrome`: the band height follows the view's `titlebar_set()` over
    /// `App::titlebar`, so `cx.titlebarHeight` still reaches `cx.chromeInsets()` in a window.
    @Test @MainActor func syncWindowChromeUsesTheViewsTitlebarSet() {
        struct S { var h: Float? = nil }
        let seen = HostChromeRecorder()
        let rt = Runtime(state: S(), viewport: Vec2(400, 300), pixelScale: 2.0) { s, cx in
            if let h = s.h { cx.titlebarHeight(h) }
            seen.record(cx.chromeInsets())
            return el().size(10, 10)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let app = Titlebar(height: 38)
        _ = rt.frame(at: 0.0)
        rt.syncWindowChrome(window: window, chrome: .standard, titlebar: app)
        let lights = RuneTrafficLights.titlebarInset(window)
        #expect(rt.titlebarInset == lights)
        #expect(rt.windowChromeInsets().height == 38)
        _ = rt.frame(at: 0.1)
        #expect(seen.last.height == 38)

        rt.update(at: 0.15) { s, _ in s.h = 52 }
        _ = rt.frame(at: 0.2)
        #expect(rt.takeTitlebarChanged())
        rt.syncWindowChrome(window: window, chrome: .standard, titlebar: app)
        #expect(rt.windowChromeInsets().height == 52)
        #expect(rt.needsCommit, "the new band re-runs the view")
        _ = rt.frame(at: 0.3)
        #expect(seen.last.height == 52)

        // No titlebar (the native frame stays): no band.
        rt.syncWindowChrome(window: window, chrome: .standard, titlebar: nil)
        #expect(rt.windowChromeInsets().height == 0)
    }
    #endif
}

private final class HostChromeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _last: ChromeInsets = .zero
    private var _runs = 0
    func record(_ insets: ChromeInsets) {
        lock.lock()
        _last = insets
        _runs += 1
        lock.unlock()
    }
    var last: ChromeInsets { lock.lock(); defer { lock.unlock() }; return _last }
    var runs: Int { lock.lock(); defer { lock.unlock() }; return _runs }
}
