import Testing
@testable import Rune

@Suite("Android native event dispatch")
@MainActor
struct AndroidInputHostTests {
    @Test("A density-scaled touch keeps its pointer ID through cancel and release")
    func touchCapture() {
        let runtime = Runtime(state: 0, viewport: Vec2(80, 80), pixelScale: 2, systemDark: false) { _, _ in
            el().size(25, 25).onClick { $0 += 1 }
        }
        _ = runtime.frame(at: 0)
        func touch(_ action: AndroidMotionAction, _ id: Int32, _ time: Double) {
            AndroidMotionTranslator.dispatch(.init(action: action, pointerId: id, xPx: 40, yPx: 40),
                                             to: runtime, density: 2, at: time)
        }
        touch(.down, 4, 0.1)
        touch(.up, 5, 0.11)
        #expect(runtime.state == 0)
        touch(.cancel, 4, 0.12)
        touch(.up, 4, 0.13)
        #expect(runtime.state == 0)
        touch(.down, 7, 0.14)
        touch(.up, 7, 0.16)
        #expect(runtime.state == 1)
    }

    @Test("A held finger keeps its press when the mouse moves, clicks, or cancels")
    func mouseDuringTouch() {
        struct State {
            var taps: [Bool] = []
            var wheels = 0
        }
        let runtime = Runtime(state: State(), viewport: Vec2(80, 80), pixelScale: 1) { _, _ in
            el().size(80, 80).pressOnDown()
                .onClick { state, tx in state.taps.append(tx.touchTap()) }
                .onWheel { state, _, _ in state.wheels += 1; return true }
        }
        _ = runtime.frame(at: 0)
        var time = 0.0
        func send(_ action: AndroidMotionAction, mouse: Bool) {
            time += 0.01
            let point: Float = mouse ? 60 : 20
            AndroidMotionTranslator.dispatch(.init(action: action, pointerId: mouse ? 9 : 4, isMouse: mouse,
                                                   xPx: point, yPx: point, vScroll: 1),
                                             to: runtime, density: 1, at: time)
        }
        send(.down, mouse: false)
        for action in [AndroidMotionAction.hoverEnter, .hoverMove, .down, .move, .up, .cancel, .hoverExit, .scroll] {
            send(action, mouse: true)
        }
        #expect(runtime.state.taps.isEmpty)
        #expect(runtime.state.wheels == 1)
        #expect(runtime.pointer() == Vec2(20, 20))
        send(.up, mouse: false)
        #expect(runtime.state.taps == [true])
        send(.down, mouse: true)
        send(.up, mouse: true)
        #expect(runtime.state.taps == [true, false])
    }

    @Test("Hardware dead keys compose once and keep a matching release")
    func deadKey() {
        var keyboard = AndroidHardwareKeyboard()
        func stroke(_ action: Int32, _ code: Int32, _ scalar: UInt32) -> AndroidHardwareKeyboard.Stroke {
            keyboard.translate(action: action, code: code, character: scalar) { accent, key in
                accent == 0x00b4 && key == 0x65 ? 0x00e9 : 0
            }
        }
        #expect(stroke(0, 75, 0x8000_00b4) == .consumed)
        #expect(stroke(1, 75, 0) == .consumed)
        #expect(stroke(0, 33, 0x65) == .key(.text("é")))
        #expect(stroke(1, 33, 0) == .key(.text("é")))
        #expect(stroke(0, 75, 0x8000_00b4) == .consumed)
        #expect(stroke(1, 75, 0) == .consumed)
        #expect(stroke(0, 45, 0x71) == .key(.text("´q")))
    }

    @Test("Android mouse-wheel axes reach the hovered Rune element")
    func wheelAxes() {
        let runtime = Runtime(state: Vec2.zero, viewport: Vec2(80, 80), pixelScale: 2, systemDark: false) { _, _ in
            el().size(80, 80).onWheel { delta, event, _ in
                delta = Vec2(event.dx, event.dy)
                return true
            }
        }
        _ = runtime.frame(at: 0)
        AndroidMotionTranslator.dispatch(.init(action: .scroll, isMouse: true, xPx: 20, yPx: 20,
                                              hScroll: 1, vScroll: -2), to: runtime, density: 2, at: 0.1)
        #expect(runtime.state == Vec2(WheelDistance.linePoints, -2 * WheelDistance.linePoints))
    }
}
