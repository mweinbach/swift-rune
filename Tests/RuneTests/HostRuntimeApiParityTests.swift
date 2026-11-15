import Foundation
import Testing
@testable import Rune
@testable import RuneMotion

/// Host-facing runtime APIs (`runtime/input/titlebar.rs` `set_chrome_insets` / `chrome_insets`,
/// `runtime/drag_out_host.rs` `take_drag_out`). Upstream has no `#[test]` for these; these are
/// regression tests for the upstream behaviour.
@Suite("Host Runtime API Parity Tests", .serialized)
struct HostRuntimeApiParityTests {
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
