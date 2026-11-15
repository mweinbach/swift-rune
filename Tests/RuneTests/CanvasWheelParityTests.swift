import Foundation
import Testing
import RuneMotion
@testable import Rune

/// `crates/rune/tests/canvas_input.rs`: `on_wheel` ahead of the scroll view around it, a declined
/// delta scrolling and keeping the gesture a scroll, and momentum following the handler that took
/// the gesture (`runtime/input/gesture.rs` `wheel_event`, `runtime/scroll/x.rs` `WheelLock`).
struct CanvasWheelState {
    /// The canvas takes wheel deltas (else it declines them).
    var takes = false
    var pan: (Float, Float) = (0, 0)
    var wheels: [WheelEvent] = []
    var edit = TextEdit()
}

@Suite("Canvas wheel parity (canvas_input.rs on_wheel)")
@MainActor
struct CanvasWheelParityTests {
    typealias S = CanvasWheelState

    /// A 300 pt page that scrolls, holding a 200 pt canvas at (50, 50) and 600 pt of rows below.
    nonisolated static func view(_ s: S, _ cx: inout Cx<S>) -> El<S> {
        let canvas: El<S> = el().key("canvas").w(200).h(200).ml(50).mt(50)
            .onWheel { (s: inout S, e: WheelEvent, _: inout Tx) -> Bool in
                s.wheels.append(e)
                if s.takes { s.pan.0 += e.dx; s.pan.1 += e.dy }
                return s.takes
            }
            .child(el().key("shape").w(40).h(40).focusable(true))
            .child(textInput(key: "field", \S.edit).singleLine(true).w(100).h(32))
        let plain: El<S> = el().key("plain").w(100).h(40)
        var rows: El<S> = col().wFull().child(canvas).child(plain)
        for i in 0..<15 { let row: El<S> = el().key("row\(i)").wFull().h(40); rows = rows.child(row) }
        return col().wFull().hFull()
            .child(col().key("page").wFull().h(300).scroll(ScrollSpec(stickBottom: false)).child(rows))
    }

    /// `Runtime::new(s, view, (300.0, 300.0), Env::new(true, 1.0))` and `rt.frame(0.0)`, with the
    /// runtime's clock kept by the test (`frame(dt)` upstream advances it by `dt`).
    final class App {
        let rt: Runtime<S>
        var now: Double = 0
        init(_ s: S) {
            rt = Runtime(state: s, viewport: Vec2(300, 300), pixelScale: 1.0, systemDark: true, view: CanvasWheelParityTests.view)
            _ = rt.frame(at: 0)
        }
        func frame(_ dt: Double) { now += dt; _ = rt.frame(at: now) }
        /// A pause long enough that the next delta starts a new gesture.
        func newGesture() { frame(0.15) }
        func wheelEvent(_ ev: WheelEvent) { rt.wheelEvent(ev, now: now) }
        func wheelXY(_ x: Float, _ y: Float, _ dx: Float, _ dy: Float) { rt.wheelXY(x, y, dx, dy, now: now) }
        func yOf(_ key: String) -> Float {
            guard let e = rt.elements().first(where: { $0.key == key }) else { fatalError(key) }
            return e.rect[1]
        }
    }

    @Test("canvas_input.rs:70 a_wheel_handler_hears_deltas_before_the_scroll_view_around_it")
    func aWheelHandlerHearsDeltasBeforeTheScrollViewAroundIt() {
        let app = App(S(takes: true))
        let cmd = Mods(cmd: true)
        app.wheelEvent(WheelEvent(dx: -10, dy: -20, precise: true, mods: cmd, x: 80, y: 90))
        app.frame(1.0 / 60.0)
        #expect(app.rt.state.pan == (-10, -20))
        let e = app.rt.state.wheels[0]
        #expect(e.x == 30 && e.y == 40 && e.mods == cmd && e.precise == true, "the pointer in the canvas's own points")
        #expect(app.yOf("canvas") == 50, "the page didn't scroll")

        // The gesture stays the canvas's when the pointer leaves it, as a scroll keeps its axis.
        app.wheelXY(150, 280, 0, -30)
        app.frame(1.0 / 60.0)
        #expect(app.rt.state.pan.1 == -50)
        #expect(app.yOf("canvas") == 50)

        // Off the canvas a new gesture scrolls the page, which the canvas never hears.
        app.newGesture()
        let heard = app.rt.state.wheels.count
        app.wheelXY(150, 280, 0, -30)
        app.frame(1.0 / 60.0)
        #expect(app.rt.state.wheels.count == heard)
        #expect(app.yOf("canvas") == 20)
    }

    @Test("canvas_input.rs:94 a_declined_delta_scrolls_and_the_gesture_stays_a_scroll")
    func aDeclinedDeltaScrollsAndTheGestureStaysAScroll() {
        let app = App(S())
        app.wheelXY(150, 150, 0, -30)
        app.frame(1.0 / 60.0)
        #expect(app.yOf("canvas") == 20, "the canvas declined it, so the page scrolled")
        #expect(app.rt.state.wheels.count == 1)
        // `wheel_xy` sends `WheelEvent::new(dx, dy).at(x, y)`: line steps, not precise, no momentum.
        #expect(app.rt.state.wheels[0].precise == false && app.rt.state.wheels[0].momentum == false)
        // The page has the gesture now: the canvas, taking deltas again, doesn't hear the rest.
        app.rt.state.takes = true
        app.wheelXY(150, 150, 0, -10)
        app.frame(1.0 / 60.0)
        #expect(app.rt.state.wheels.count == 1)
        #expect(app.yOf("canvas") == 10)
        // Without phases, a delta wholly on the other axis (Shift + wheel) starts a new gesture.
        app.wheelXY(150, 150, -15, 0)
        app.frame(1.0 / 60.0)
        #expect(app.rt.state.wheels.count == 2)
        #expect(app.rt.state.pan.0 == -15)
    }

    @Test("canvas_input.rs:112 momentum_follows_the_handler_that_took_the_gesture")
    func momentumFollowsTheHandlerThatTookTheGesture() {
        let app = App(S(takes: true))
        app.wheelEvent(WheelEvent(dx: 0, dy: -10, phase: .began, x: 150, y: 150))
        app.wheelEvent(WheelEvent(dx: 0, dy: 0, phase: .ended, x: 150, y: 150))
        // Momentum begins at once, after the pointer moved off the canvas.
        app.wheelEvent(WheelEvent(dx: 0, dy: -5, phase: .began, x: 150, y: 280))
        app.frame(1.0 / 60.0)
        let phases = app.rt.state.wheels.map { "\($0.phase) \($0.momentum) \($0.dy)" }
        #expect(phases == ["began false -10.0", "ended false 0.0", "began true -5.0"])
        #expect(app.rt.state.pan.1 == -15)
        #expect(app.yOf("canvas") == 50)
    }
}
