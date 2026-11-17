import Foundation
import Testing
#if os(macOS) && canImport(AppKit)
import AppKit
#endif
@testable import Rune

/// `El::touch_drags_at_once` (#938) and `Tx::input_waiting` (#945).
@Suite("Touch drags at once and Tx.inputWaiting (#938, #945)", .serialized)
@MainActor
struct TouchAtOnceAndInputWaitingTests {
    private struct S {
        var drags: [Float] = []
        var taps = 0
    }

    /// A knob that drags above a scrolling list (`touch.rs` tests' `view`), the knob optionally
    /// `touchDragsAtOnce`, and a tap target that is `touchDragsAtOnce` without `onDrag`.
    private func rig(atOnce: Bool) -> Runtime<S> {
        let rt = Runtime(
            state: S(),
            viewport: Vec2(200, 300),
            pixelScale: 1.0,
            view: { _, _ in
                var knob: El<S> = el().key("knob").w(200).h(40).onDrag { s, d, _ in
                    if d.phase == .move { s.drags.append(d.delta.x) }
                }
                if atOnce { knob = knob.touchDragsAtOnce() }
                return col().w(200).h(300)
                    .child(knob)
                    .child(el().key("tap").w(200).h(40).touchDragsAtOnce().onClick { s in s.taps += 1 })
                    .child(
                        col().key("list").w(200).h(200).scroll(ScrollSpec(stickBottom: false)).child(
                            col().w(200).child(el().w(200).h(40).touchDragsAtOnce().onDrag { s, d, _ in
                                if d.phase == .move { s.drags.append(d.delta.y) }
                            }).child(el().w(200).h(800))
                        )
                    )
            }
        )
        _ = rt.frame(at: 0.0)
        return rt
    }

    @Test("touch_drags_at_once: a finger drags from where it lands, with no 8-point slop")
    func aFingerDragsFromWhereItLands() {
        let rt = rig(atOnce: true)
        rt.touch(id: 1, phase: .started, at: Vec2(100, 20), time: 0.10)
        #expect(rt.pressDragsAtOnce())
        rt.touch(id: 1, phase: .moved, at: Vec2(103, 20), time: 0.11)
        #expect(rt.state.drags == [3], "the first move drags, inside the slop")
        rt.touch(id: 1, phase: .moved, at: Vec2(105, 20), time: 0.12)
        #expect(rt.state.drags == [3, 5])
        rt.touch(id: 1, phase: .ended, at: Vec2(105, 20), time: 0.13)
        #expect(!rt.touching())

        // Without it, the same finger waits for the slop: a 3-point move drags nothing.
        let plain = rig(atOnce: false)
        plain.touch(id: 1, phase: .started, at: Vec2(100, 20), time: 0.10)
        #expect(!plain.pressDragsAtOnce())
        plain.touch(id: 1, phase: .moved, at: Vec2(103, 20), time: 0.11)
        #expect(plain.state.drags.isEmpty, "a plain on_drag element keeps the 8-point slop")
        plain.touch(id: 1, phase: .ended, at: Vec2(103, 20), time: 0.12)
    }

    @Test("touch_drags_at_once: inside a scroll viewport it drags and never pans the page")
    func aFingerNeverPansThePageUnderIt() {
        let rt = rig(atOnce: true)
        rt.touch(id: 1, phase: .started, at: Vec2(100, 100), time: 0.10)
        #expect(rt.pressDragsAtOnce())
        rt.touch(id: 1, phase: .moved, at: Vec2(100, 70), time: 0.12)
        rt.touch(id: 1, phase: .moved, at: Vec2(100, 40), time: 0.14)
        #expect(rt.state.drags == [-30, -60])
        rt.touch(id: 1, phase: .ended, at: Vec2(100, 40), time: 0.145)
        _ = rt.frame(at: 0.3)
        #expect(rt.scrollOffset(forKey: "list") == .zero, "the list never panned or flung")
    }

    @Test("touch_drags_at_once needs on_drag: without it a touch is still a tap")
    func withoutOnDragATouchIsStillATap() {
        let rt = rig(atOnce: true)
        rt.touch(id: 1, phase: .started, at: Vec2(100, 60), time: 0.10)
        #expect(!rt.pressDragsAtOnce())
        rt.touch(id: 1, phase: .moved, at: Vec2(103, 62), time: 0.11)
        rt.touch(id: 1, phase: .ended, at: Vec2(103, 62), time: 0.12)
        _ = rt.frame(at: 0.13)
        #expect(rt.state.taps == 1)
    }

    @Test("touch_drags_at_once: a mouse is unchanged")
    func aMouseIsUnchanged() {
        var runs: [[Float]] = []
        for atOnce in [false, true] {
            let rt = rig(atOnce: atOnce)
            rt.pointerMove(to: Vec2(100, 20), at: 0.10)
            rt.pointerDown(at: Vec2(100, 20), at: 0.10)
            rt.pointerMove(to: Vec2(103, 20), at: 0.11)
            rt.pointerMove(to: Vec2(140, 20), at: 0.12)
            rt.pointerUp(at: Vec2(140, 20), at: 0.13)
            runs.append(rt.state.drags)
        }
        #expect(runs[0] == runs[1])
        #expect(runs[0].last == 40)
    }

    @Test("touchDragsAtOnce sets Handlers.touchAtOnce, which defaults to false")
    func handlersCarryTheFlag() {
        let knob: El<S> = el().onDrag { _, _, _ in }.touchDragsAtOnce()
        #expect(knob.handlers.touchAtOnce)
        #expect(!el().onDrag { (_: inout S, _, _) in }.handlers.touchAtOnce, "defaults to false")
    }

    private struct W {
        var polls: [Bool] = []
        var inHandler: [Bool] = []
    }

    private func waitingRig() -> Runtime<W> {
        let rt = Runtime(
            state: W(),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            view: { _, _ in
                col().w(200).h(200).child(
                    el().key("btn").w(200).h(50).onClick { s, tx in
                        s.inHandler.append(tx.inputWaiting())
                        tx.sendKey(KeyEvent(key: .escape))
                    }
                ).child(
                    el().key("paste").w(200).h(50).onClick { s, tx in
                        s.inHandler.append(tx.inputWaiting())
                        tx.requestPaste()
                    }
                )
            }
        )
        rt.poll = { s, _, tx in
            s.polls.append(tx.inputWaiting())
            return false
        }
        _ = rt.frame(at: 0.0)
        return rt
    }

    private func click(_ rt: Runtime<W>, at p: Vec2, _ t: Double) {
        rt.pointerMove(to: p, at: t)
        rt.pointerDown(at: p, at: t)
        rt.pointerUp(at: p, at: t)
    }

    private struct Moves {
        var polls: [Bool] = []
        var moves = 0
        var clicks = 0
    }

    /// Plain content, an `onPointerMove` target, a hover target, a button, a plain scroll
    /// viewport and an `onWheel` region, top to bottom, 50 points each.
    private func movesRig() -> Runtime<Moves> {
        let rt = Runtime(
            state: Moves(),
            viewport: Vec2(200, 400),
            pixelScale: 1.0,
            view: { _, _ in
                col().w(200).h(400)
                    .child(el().key("plain").w(200).h(50))
                    .child(el().key("tracker").w(200).h(50).onPointerMove { s, _, _ in s.moves += 1 })
                    .child(el().key("hov").w(200).h(50).hover(Color.white))
                    .child(el().key("btn").w(200).h(50).onClick { s in s.clicks += 1 })
                    .child(col().key("list").w(200).h(100).scroll(ScrollSpec(stickBottom: false)).child(el().w(200).h(600)))
                    .child(col().key("wheeler").w(200).h(100).onWheel { _, _, _ in true })
            }
        )
        rt.poll = { s, _, tx in
            s.polls.append(tx.inputWaiting())
            return false
        }
        _ = rt.frame(at: 0.0)
        return rt
    }

    @Test("input_waiting: in poll, true only for host input that left handler work (`frame.rs:517`)")
    func aHostDispatchedInputWaitsOnlyWhenItLeftHandlerWork() {
        let rt = movesRig()
        var t = 0.0
        /// Dispatches `body` as host input of `kind`, runs the next frame, and returns its poll's answer.
        func waits(_ kind: HostInputKind, _ body: () -> Void) -> Bool {
            t += 0.1
            rt.hostInput(kind) { body() }
            _ = rt.frame(at: t)
            return rt.state.polls.last!
        }
        #expect(rt.state.polls == [false], "nothing queued")

        // A move over content nothing handles queues nothing (`pointer.rs`: `PointerMove` only for
        // an `on_pointer_move` node; `hover.rs`: `Hover` only for a new hovered element).
        #expect(!waits(.pointer) { rt.pointerMove(to: Vec2(100, 20), at: t) })
        #expect(!waits(.pointer) { rt.pointerMove(to: Vec2(110, 25), at: t) })
        // Over an `onPointerMove` element it does.
        #expect(waits(.pointer) { rt.pointerMove(to: Vec2(100, 70), at: t) })
        #expect(rt.state.moves > 0)
        // A hover colour alone is no hover target (`hit.rs::top_target`): nothing is queued.
        #expect(!waits(.pointer) { rt.pointerMove(to: Vec2(100, 120), at: t) })
        // Onto an element that takes a press it does (`hover.rs::apply_hovered` queues `Hover`
        // with no handler to run), and staying on it does not (`hover.rs:101`).
        #expect(waits(.pointer) { rt.pointerMove(to: Vec2(100, 160), at: t) })
        #expect(rt.primaryTargetPath() == rt.flatNodes.first { $0.key == "btn" }?.path)
        #expect(!waits(.pointer) { rt.pointerMove(to: Vec2(105, 165), at: t) })
        #expect(rt.state.clicks == 0)
        // A press does.
        #expect(waits(.pointer) {
            rt.pointerMove(to: Vec2(100, 170), at: t)
            rt.pointerDown(at: Vec2(100, 170), at: t)
            rt.pointerUp(at: Vec2(100, 170), at: t)
        })
        #expect(rt.state.clicks == 1)
        _ = waits(.pointer) { rt.pointerMove(to: Vec2(100, 20), at: t) }
        // A key press always does, handled or not (`keys.rs`: `Action::Key` is always queued).
        #expect(waits(.keyPress) { _ = rt.keyDown(KeyEvent(key: .text("x")), at: t) })
        // A wheel that only scrolls a plain viewport queues nothing (`gesture.rs::offer_wheel`);
        // one an `onWheel` chain hears does.
        #expect(!waits(.wheel) { rt.wheel(WheelEvent(dx: 0, dy: -30, precise: true, mods: .none), at: Vec2(100, 250), now: t) })
        #expect(rt.scrollOffset(forKey: "list").y > 0, "the wheel scrolled the list")
        // Past the wheel gesture's axis lock, so the next wheel starts its own gesture.
        t += 5.0
        #expect(waits(.wheel) { rt.wheel(WheelEvent(dx: 0, dy: -30, precise: true, mods: .none), at: Vec2(100, 350), now: t) })
    }

    @Test("input_waiting: what a host-dispatched press queues carries its stamp, and lastInput is the dispatch")
    func aHostDispatchedPressStampsWhatItQueues() {
        let rt = waitingRig()
        // The host dispatches a press stamped with the event's own time (`window.rs`'s
        // `input::time::arrived`): it waits for the next poll with that stamp, and
        // `InputTime.lastInput` is the moment of dispatch, not the stamp.
        let stamp = ProcessInfo.processInfo.systemUptime - 0.25
        let before = ProcessInfo.processInfo.systemUptime
        rt.hostInput(.pointer, eventTimestamp: stamp) { click(rt, at: Vec2(100, 20), 0.1) }
        #expect(InputTime.lastInput() >= before, "the last input is when it was dispatched (`input::time::last_input`)")
        #expect(InputTime.arrival() == nil, "the arrival scope ends with the dispatch")
        #expect(rt.queuedInputArrivals.dispatched.map { abs($0 - stamp) < 1e-6 } == true, "stamped with the event's time")
        #expect(rt.state.inHandler == [false], "false outside poll")
        #expect(rt.queuedInputArrivals.sentKeys.count == 1 && rt.queuedInputArrivals.sentKeys[0].map { abs($0 - stamp) < 1e-6 } == true,
                "the key the press's handler sent carries the press's stamp")
        _ = rt.frame(at: 0.2)
        #expect(rt.state.polls == [false, true])
        #expect(rt.queuedInputArrivals.sentKeys.isEmpty, "the frame ran the sent key")
        _ = rt.frame(at: 0.3)
        #expect(rt.state.polls == [false, true, false], "the frame took it")

        // A paste the user's press asked for waits the same way: the clipboard's answer is queued
        // under the press's stamp (`flush_memory` -> `paste_result` -> `queue.push`).
        rt.clipboard = ClipboardContent("pasted")
        let pasteStamp = ProcessInfo.processInfo.systemUptime - 0.1
        rt.hostInput(.pointer, eventTimestamp: pasteStamp) { click(rt, at: Vec2(100, 70), 0.4) }
        #expect(rt.clipboardRouting.replies.count == 1)
        #expect(rt.clipboardRouting.replies.first?.at.map { abs($0 - pasteStamp) < 1e-6 } == true,
                "the paste reply carries the press's stamp")
        _ = rt.frame(at: 0.5)
        #expect(rt.clipboardRouting.replies.isEmpty, "the frame ran the paste")
        _ = rt.frame(at: 0.6)
        #expect(rt.state.polls == [false, true, false, true, false])
    }

    @Test("input_waiting: a clipboard reply queued under the user's input counts on its own (`has_input`)")
    func aStampedClipboardReplyAloneWaits() {
        let rt = waitingRig()
        // Queued by no input: it runs, but nothing waits.
        rt.paste("no input")
        #expect(!rt.queuedInputWaiting)
        _ = rt.frame(at: 0.1)
        #expect(rt.state.polls == [false, false])
        // A host delivering a paste inside an input's scope stamps it.
        InputTime.withArrival(5.0) { rt.paste("typed") }
        #expect(rt.queuedInputArrivals.dispatched == nil, "no host input was dispatched")
        #expect(rt.queuedInputWaiting, "the stamped paste alone is input waiting")
        _ = rt.frame(at: 0.2)
        _ = rt.frame(at: 0.3)
        #expect(rt.state.polls == [false, false, true, false])
        // A read answered under the input's scope counts too (`at.is_some()`, whatever `input` says).
        InputTime.withArrival(6.0) { rt.update(at: 0.35) { (_: inout W, tx: inout Tx) in tx.readClipboard { (_: inout W, _, _) in } } }
        #expect(rt.clipboardRouting.replies.contains { $0.at == 6.0 })
        _ = rt.frame(at: 0.4)
        #expect(rt.state.polls.last == true)
    }

    private struct Chain {
        var polls: [Bool] = []
        var keys: [String] = []
    }

    @Test("input_waiting: a key sent for an input-caused sent key keeps the input's stamp")
    func aChainedSentKeyKeepsItsStamp() {
        let rt = Runtime(
            state: Chain(),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            view: { _, _ in
                col().w(200).h(200).child(
                    el().key("field").w(200).h(50).focusable(true)
                        .onClick { _, tx in tx.sendKey(KeyEvent(key: .text("a"))) }
                        .onKey { s, ev, tx in
                            guard case .text(let t) = ev.key else { return false }
                            s.keys.append(t)
                            if t == "a" { tx.sendKey(KeyEvent(key: .text("b"))) }
                            return true
                        }
                )
            }
        )
        rt.poll = { s, _, tx in
            s.polls.append(tx.inputWaiting())
            return false
        }
        _ = rt.frame(at: 0.0)
        rt.hostInput(.pointer) {
            rt.pointerMove(to: Vec2(100, 20), at: 0.1)
            rt.pointerDown(at: Vec2(100, 20), at: 0.1)
            rt.pointerUp(at: Vec2(100, 20), at: 0.1)
        }
        _ = rt.frame(at: 0.2)
        #expect(rt.state.keys == ["a"], "the frame ran the sent key, which sent another")
        #expect(rt.queuedInputArrivals.sentKeys.count == 1 && rt.queuedInputArrivals.sentKeys[0] != nil,
                "a key sent while running an input-caused key keeps that input's stamp")
        _ = rt.frame(at: 0.3)
        #expect(rt.state.keys == ["a", "b"])
        _ = rt.frame(at: 0.4)
        #expect(rt.state.polls == [false, true, true, false])
    }

#if os(macOS) && canImport(AppKit)
    @Test("input_waiting: AppKit events the macOS host view receives wait when they leave handler work")
    func aMacOSHostEventWaitsWhenItLeavesHandlerWork() throws {
        let rt = waitingRig()
        let view = RuneMetalHostView(
            frame: .zero,
            runtime: rt,
            renderer: try MetalRenderer(),
            timeScale: 1.0,
            respectSystemAppearance: false
        )
        let stamp = ProcessInfo.processInfo.systemUptime - 0.5
        // A mouse move over content nothing handles leaves nothing waiting.
        let move = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: 100, y: 150), modifierFlags: [], timestamp: stamp,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        view.mouseMoved(with: move)
        #expect(rt.queuedInputArrivals.dispatched == nil)
        _ = rt.frame(at: 0.2)
        #expect(rt.state.polls == [false, false])

        // A key press does, stamped with the NSEvent's timestamp.
        let key = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: stamp, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        view.keyDown(with: key)
        #expect(rt.queuedInputArrivals.dispatched.map { abs($0 - stamp) < 1e-6 } == true, "stamped with the NSEvent's timestamp")
        _ = rt.frame(at: 0.3)
        _ = rt.frame(at: 0.4)
        #expect(rt.state.polls == [false, false, true, false])
    }

    @Test("input_waiting: a host stamps with AppKit's current event only when it is the kind dispatched")
    func appKitsCurrentEventStampsOnlyItsOwnKind() {
        #expect(MacOSInputEvents.matches(.keyDown, .keyPress))
        #expect(MacOSInputEvents.matches(.flagsChanged, .keyRelease))
        #expect(MacOSInputEvents.matches(.leftMouseDragged, .pointer))
        #expect(MacOSInputEvents.matches(.scrollWheel, .wheel))
        #expect(MacOSInputEvents.matches(.magnify, .magnify))
        #expect(!MacOSInputEvents.matches(.keyDown, .magnify), "a magnify dispatched under a keyDown arrived now")
        #expect(!MacOSInputEvents.matches(.scrollWheel, .pointer))
        #expect(!MacOSInputEvents.matches(.leftMouseDown, .keyPress))
        #expect(!MacOSInputEvents.matches(.rotate, .smartMagnify))
    }

    @Test("input_waiting: a view override's event stamps only input of its own kind (`native(kind)`)")
    func aViewOverridesEventStampsOnlyItsOwnKind() throws {
        let stamp = ProcessInfo.processInfo.systemUptime - 0.5
        let key = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: stamp, windowNumber: 0, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ))
        #expect(MacOSInputEvents.timestamp(.keyPress, key) == stamp, "a key press is stamped with its keyDown")
        // Not a key's kind: AppKit's current event stands in only when it is that kind, and
        // headless there is none, so the input arrived now.
        if NSApp?.currentEvent == nil {
            #expect(MacOSInputEvents.timestamp(.magnify, key) == nil, "a magnify dispatched under a keyDown arrived now")
            #expect(MacOSInputEvents.timestamp(.pointer, nil) == nil)
        }
    }
#endif

    @Test("input_waiting: what no input caused never counts")
    func workNoInputCausedNeverCounts() {
        let rt = waitingRig()
        // The same press outside any input scope, and an update that sends a key.
        click(rt, at: Vec2(100, 20), 0.1)
        rt.update(at: 0.15) { _, tx in tx.sendKey(KeyEvent(key: .escape)) }
        #expect(!rt.queuedInputArrivals.hasInput)
        _ = rt.frame(at: 0.2)
        #expect(rt.state.polls == [false, false])
        #expect(rt.state.inHandler == [false])

        var queued = QueuedInputArrivals()
        #expect(!queued.hasInput)
        queued.sentKeys = [nil, nil]
        #expect(!queued.hasInput)
        queued.sentKeys.append(3.0)
        #expect(queued.hasInput, "any queued action with an arrival time")
        var dispatched = QueuedInputArrivals()
        dispatched.dispatched = 3.0
        #expect(dispatched.hasInput, "input a host dispatched since the last frame")
        #expect(!Tx().inputWaiting(), "defaults to false")
    }
}
