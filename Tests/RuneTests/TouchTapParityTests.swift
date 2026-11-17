import Testing
import Rune

@Suite("Press transaction input source")
struct TouchTapParityTests {
    @Test func onlyThePressFromTheCapturedFingerReportsATouchTap() {
        struct State {
            var presses: [Bool] = []
            var pointerDowns: [Bool] = []
            var extendedPresses: [Bool] = []
        }
        let rt = Runtime(state: State(), viewport: Vec2(100, 80), pixelScale: 1) { _, _ in
            el().key("target").size(100, 80).focusable()
                .onPointerDown { state, _, tx in state.pointerDowns.append(tx.touchTap()) }
                .onClick { state, tx in state.presses.append(tx.touchTap()) }
                .onClickPress { state, _, tx in state.extendedPresses.append(tx.touchTap()) }
        }
        let p = Vec2(24, 20)
        _ = rt.frame(at: 0)
        rt.touch(id: 7, phase: .started, at: p, time: 0.1)
        rt.touch(id: 8, phase: .ended, at: p, time: 0.12)
        #expect(rt.state.presses.isEmpty)
        #expect(rt.accessibilityAction("target", .press, at: 0.15))
        rt.touch(id: 7, phase: .ended, at: p, time: 0.2)
        rt.pointerDown(at: p, at: 1)
        rt.pointerUp(at: p, at: 1.05)
        #expect(rt.accessibilityAction("target", .focus, at: 1.1))
        #expect(rt.keyDown(KeyEvent(key: .space), at: 1.2))
        rt.touch(id: 9, phase: .started, at: p, time: 2)
        rt.touch(id: 9, phase: .cancelled, at: p, time: 2.1)
        rt.pointerDown(at: p, at: 3)
        rt.pointerUp(at: p, at: 3.05)
        #expect(rt.state.presses == [false, true, false, false, false])
        #expect(rt.state.extendedPresses == [false, true, false, false])
        #expect(rt.state.pointerDowns == [false, false, false, false])
        #expect(!Tx().touchTap())
    }

    @Test func backgroundPressOnDownWaitsForFingerRelease() {
        let rt = Runtime(state: [Bool](), viewport: Vec2(120, 80), pixelScale: 1) { _, _ in
            el().key("pane").size(120, 80)
                .onBackgroundPressTx { presses, tx in presses.append(tx.touchTap()) }.pressOnDown()
        }
        let p = Vec2(20, 20)
        _ = rt.frame(at: 0)
        rt.pointerDown(at: p, at: 0.1)
        #expect(rt.state == [false])
        rt.pointerUp(at: p, at: 0.2)
        rt.touch(id: 1, phase: .started, at: p, time: 1)
        #expect(rt.state == [false])
        rt.touch(id: 1, phase: .ended, at: p, time: 1.1)
        #expect(rt.state == [false, true])
        #expect(rt.accessibilityAction("pane", .press, at: 2))
        #expect(rt.state == [false, true, false])
    }

    @Test func backgroundPressAcceptsKeyboardWhenTheAuthorOptsIntoFocus() throws {
        struct State {
            var targets: [String] = []
            var touchTaps: [Bool] = []
        }
        let rt = Runtime(state: State(), viewport: Vec2(100, 100), pixelScale: 1) { _, _ in
            col().sizeFull().children([
                el().key("earlier").size(60, 15).defaultButton().onClick { state, _ in state.targets.append("earlier") },
                el().key("pane").size(60, 15).onBackgroundPressTx { state, tx in
                    state.targets.append("pane")
                    state.touchTaps.append(tx.touchTap())
                }.focusable().defaultButton(),
                el().key("passive").size(60, 15).focusable().defaultButton()
            ])
        }
        _ = rt.frame(at: 0)
        let pane = try #require(rt.accessibilitySnapshot().children.first(where: { $0.id == "pane" }))
        #expect(pane.role == .button)
        #expect(pane.actions.contains(.focus) && pane.actions.contains(.press))
        #expect(rt.accessibilityAction("pane", .focus, at: 0.1))
        #expect(rt.keyDown(KeyEvent(key: .space), at: 0.2))
        #expect(rt.accessibilityAction("passive", .focus, at: 0.3))
        #expect(rt.keyDown(KeyEvent(key: .enter), at: 0.4))
        #expect(rt.state.targets == ["pane", "pane"])
        #expect(rt.state.touchTaps == [false, false])
    }
}
