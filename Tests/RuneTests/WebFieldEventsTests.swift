import Foundation
import Testing
@testable import Rune

@Suite @MainActor
struct WebFieldEventsTests {
    private struct InputSample {
        let arrival = InputTime.arrival()
        let lastInput = InputTime.lastInput()
    }

    private struct Form {
        var edit: TextEdit
        var rejected = false
        var changeCount = 0
        var changed: InputSample?
        var keyed: InputSample?
    }

    private func host(_ edit: TextEdit, secure: Bool = false, locked: Bool = false) -> WebAppHost<Form> {
        let app = AppSpec<Form>(title: "Browser editor", size: Vec2(160, 45), state: Form(edit: edit)) { _, _ in
            textInput(key: "draft", \.edit).w(150).h(40).secure(secure).singleLine().withoutEditAccess(locked)
                .onInputKey { state, _, _ in
                    state.keyed = InputSample()
                    return false
                }
                .onInputChange { state, _, _ in
                    state.changed = InputSample()
                    state.changeCount += 1
                    return state.rejected
                }
        }
        let host = WebAppHost(spec: app)
        _ = host.runtime.frame(at: 0)
        _ = host.runtime.accessibilityAction("draft", .press, at: 0.1)
        host.syncField(activate: true)
        return host
    }

    private func send(_ event: [String: Any], to browser: WebBrowserSession, at time: Double) throws -> Bool {
        let encoded = try JSONSerialization.data(withJSONObject: event)
        InputTime.scope(at: 1) {}
        return browser.send(encoded, at: time)
    }

    @Test func canvasKeysAndPointerDevicesReportTheirArrivalToHandlersAndPoll() throws {
        struct Canvas {
            var samples: [String: InputSample] = [:]
            var polls: [Bool] = []
        }
        var app = AppSpec<Canvas>(title: "Input", size: Vec2(60, 50), state: Canvas()) { _, _ in
            el().size(60, 50)
                .onPointerDown { state, _, _ in state.samples["pointerdown"] = InputSample() }
                .onPointerMove { state, _, _ in state.samples["pointermove"] = InputSample() }
                .onPointerUp { state, _, _ in state.samples["pointerup"] = InputSample() }
        }
        app.onKey = { state, _, _ in state.samples["key"] = InputSample(); return true }
        app.poll = { state, _, tx in state.polls.append(tx.inputWaiting()); return false }

        let host = WebAppHost(spec: app)
        let browser = WebBrowserSession(host)
        _ = try browser.frame(at: 0)
        InputTime.scope(at: 1) {}
        host.handlePointerMove(x: 140, y: 90, at: 0.01)
        #expect(InputTime.lastInput() > 1)
        _ = try browser.frame(at: 0.02)
        #expect(host.runtime.state.polls.last == false)

        var time = 0.1
        func verify(_ kind: String, _ payload: [String: Any], tracksArrival: Bool) throws {
            host.runtime.state.polls.removeAll()
            host.runtime.state.samples.removeAll()
            var event = payload
            event["kind"] = kind
            #expect(try send(event, to: browser, at: time))
            let sample = try #require(host.runtime.state.samples[kind])
            #expect((sample.arrival != nil) == tracksArrival)
            #expect((sample.lastInput > 1) == tracksArrival)
            #expect(InputTime.lastInput() == sample.lastInput)
            #expect(InputTime.arrival() == nil)
            _ = try browser.frame(at: time + 0.01)
            #expect(host.runtime.state.polls.first == tracksArrival)
            #expect(host.runtime.state.polls.filter { $0 }.count == (tracksArrival ? 1 : 0))
            time += 0.1
        }

        try verify("key", ["code": "Escape", "key": "Escape"], tracksArrival: true)
        for device in ["mouse", "pen"] {
            for phase in ["pointerdown", "pointermove", "pointerup"] {
                try verify(phase, ["pointerType": device, "x": phase == "pointerdown" ? 18 : 20, "y": 20],
                           tracksArrival: true)
            }
        }
        try verify("pointerdown", ["pointerType": "touch", "x": 18, "y": 20], tracksArrival: false)
        // Small finger motion stays pending until the runtime resolves a tap or drag.
        host.runtime.state.samples.removeAll()
        #expect(try send(["kind": "pointermove", "pointerType": "touch", "x": 20, "y": 20], to: browser, at: time))
        #expect(host.runtime.state.samples["pointermove"] == nil)
        #expect(InputTime.lastInput() == 1)
        try verify("pointerup", ["pointerType": "touch", "x": 20, "y": 20], tracksArrival: false)
    }

    @Test func browserContactIdentityControlsTapCancellationAndPenProvenance() throws {
        let app = AppSpec<[Bool]>(title: "Pointer sources", size: Vec2(60, 50), state: []) { _, _ in
            el().size(60, 50).onClick { taps, tx in taps.append(tx.touchTap()) }
        }
        let host = WebAppHost(spec: app)
        let browser = WebBrowserSession(host)
        _ = try browser.frame(at: 0)
        var time = 0.01
        func pointer(_ kind: String, _ device: String, _ id: Int) throws {
            #expect(try send(["kind": kind, "pointerType": device, "pointerId": id, "x": 18, "y": 20],
                             to: browser, at: time))
            time += 0.01
        }

        try pointer("pointerdown", "touch", 17)
        try pointer("pointerdown", "touch", 23)
        try pointer("pointercancel", "touch", 23)
        try pointer("pointerup", "mouse", 1)
        #expect(host.runtime.touching())
        #expect(host.runtime.state.isEmpty)
        try pointer("pointerup", "touch", 17)
        #expect(host.runtime.state == [true])

        try pointer("pointerdown", "touch", 31)
        try pointer("pointercancel", "touch", 31)
        try pointer("pointerup", "touch", 31)
        #expect(!host.runtime.touching())
        #expect(host.runtime.state == [true])
        for device in ["pen", "mouse"] {
            try pointer("pointerdown", device, 7)
            try pointer("pointerup", device, 7)
        }
        #expect(host.runtime.state == [true, false, false])

        _ = host.handlePrimaryPointer(hover: false, coarse: true)
        host.handlePointerDown(x: 18, y: 20, pointerType: "pen", at: time)
        host.handlePointerUp(x: 18, y: 20, at: time + 0.01)
        #expect(host.runtime.state == [true, false, false, false])
    }

    @Test func idleCanvasMeasuresTheHoldFromTheNewContact() throws {
        struct Activations {
            var taps: [Bool] = []
            var secondary = 0
        }
        let app = AppSpec<Activations>(title: "Touch duration", size: Vec2(80, 60), state: Activations()) { _, _ in
            el().size(80, 60)
                .onClick { state, tx in state.taps.append(tx.touchTap()) }
                .onSecondaryClick { state, _, _ in state.secondary += 1 }
        }
        let host = WebAppHost(spec: app)
        let browser = WebBrowserSession(host)
        _ = try browser.renderFrame(at: 0)
        func finger(_ kind: String, at time: Double) throws {
            #expect(try send(["kind": kind, "pointerType": "touch", "pointerId": 5, "x": 20, "y": 20],
                             to: browser, at: time))
        }

        try finger("pointerdown", at: 3)
        _ = try browser.renderFrame(at: 3.02)
        try finger("pointerup", at: 3.065)
        #expect(!host.runtime.touching())
        #expect(host.runtime.state.taps == [true])
        #expect(host.runtime.state.secondary == 0)

        try finger("pointerdown", at: 8)
        _ = try browser.renderFrame(at: 8.02)
        #expect(host.runtime.state.secondary == 0)
        _ = try browser.renderFrame(at: 8.51)
        #expect(host.runtime.state.secondary == 1)
        try finger("pointerup", at: 8.65)
        #expect(!host.runtime.touching())
        #expect(host.runtime.state.taps == [true])
        #expect(host.runtime.state.secondary == 1)
    }

    @Test func nativeEditSelectionAndKeysUpdateLastInputWithoutQueuedArrivals() throws {
        let host = host(TextEdit("old"))
        let browser = WebBrowserSession(host)
        let mirror = try #require(host.fieldMirror)
        var mirrored: InputSample?
        let publish = host.onFieldChange
        host.onFieldChange = { field, activate in
            mirrored = InputSample()
            publish?(field, activate)
        }
        var polls: [Bool] = []
        host.runtime.poll = { _, _, tx in polls.append(tx.inputWaiting()); return false }
        #expect(try send(["kind": "edit", "key": mirror.key, "base": 0, "expected": "old",
                          "text": "next", "anchor": 4, "focus": 4], to: browser, at: 1))
        let change = try #require(host.runtime.state.changed)
        #expect(change.lastInput > 1 && change.arrival == nil)
        #expect(host.runtime.state.edit.text == "next")
        mirrored = nil
        #expect(try send(["kind": "selection", "key": mirror.key, "base": 0, "expected": "next",
                          "anchor": 0, "focus": 2], to: browser, at: 2))
        let selection = try #require(mirrored)
        #expect(selection.lastInput > 1 && selection.arrival == nil)
        #expect(host.runtime.state.edit.selectedUTF8Range == 0..<2)
        #expect(try send(["kind": "key", "field": true, "code": "ArrowLeft", "key": "ArrowLeft"],
                         to: browser, at: 3))
        let key = try #require(host.runtime.state.keyed)
        #expect(key.lastInput > 1 && key.arrival == nil)
        _ = try browser.frame(at: 3.1)
        #expect(!polls.isEmpty && !polls.contains(true))
    }

    @Test func secureInsertsPreserveLastInputAndPasswordNavigationCountsAsAFieldKey() throws {
        let host = host(TextEdit(""), secure: true)
        let browser = WebBrowserSession(host)
        let mirror = try #require(host.fieldMirror)
        #expect(try send(["kind": "insert", "key": mirror.key, "text": "ab"], to: browser, at: 1))
        let insert = try #require(host.runtime.state.changed)
        #expect(insert.arrival == nil && insert.lastInput == 1)
        #expect(InputTime.lastInput() == 1 && !host.runtime.queuedInputWaiting)
        #expect(host.runtime.state.edit.text == "ab")
        #expect(try send(["kind": "key", "field": true, "code": "ArrowLeft", "key": "ArrowLeft"], to: browser, at: 2))
        let navigation = try #require(host.runtime.state.keyed)
        #expect(navigation.arrival == nil && navigation.lastInput > 1)
        #expect(host.runtime.state.edit.cursor == 1)
    }

    @Test func keyboardShortcutMountsAndActivatesTheFieldDuringTheDOMEvent() throws {
        struct State {
            var open = false
            var draft = TextEdit("prompt")
        }
        var app = AppSpec<State>(title: "Prompt", size: Vec2(200, 50), state: State()) { state, _ in
            state.open ? textInput(key: "prompt", \.draft).label("Search messages").size(180, 40) : el()
        }
        app.onKey = { state, event, tx in
            guard event.key == .command("k") else { return false }
            state.open = true
            tx.focusWhenShown("prompt", ring: true)
            return true
        }
        let host = WebAppHost(spec: app)
        let browser = WebBrowserSession(host)
        _ = try browser.frame(at: 0)
        let shortcut = Data(#"{"kind":"key","key":"k","code":"KeyK","cmd":true}"#.utf8)
        #expect(browser.send(shortcut, at: 0.1))
        let data = try #require(browser.takeField())
        let update = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let field = try #require(update["field"] as? [String: Any])
        #expect(update["activate"] as? Bool == true)
        #expect(field["text"] as? String == "prompt")
        #expect(field["label"] as? String == "Search messages")
    }

    @Test func changedScalarsGoThroughUndoAndChangeCallbacks() throws {
        var edit = TextEdit("a🦀c").rich()
        edit.setSelectionRaw(anchor: 5, cursor: 6)
        edit.setMark(.bold)
        let host = host(edit)
        let mirror = try #require(host.fieldMirror)
        #expect(host.handleFieldEdit(key: mirror.key, base: 0, expected: "a🦀c", text: "aéc", anchor: 2, focus: 2, at: 1))
        #expect(host.runtime.state.edit.text == "aéc")
        #expect(host.runtime.state.edit.cursor == 3)
        #expect(host.runtime.state.edit.richMarks == [RichMarkRange(3..<4, .bold)])
        #expect(host.runtime.state.changeCount == 1)
        #expect(!host.handleFieldEdit(key: mirror.key, base: 0, expected: "a🦀c", text: "axc", anchor: 2, focus: 2, at: 1))
        #expect(host.runtime.state.changeCount == 1)
        let undone = host.runtime.state.edit.undo()
        #expect(undone && host.runtime.state.edit.text == "a🦀c")
    }

    @Test func selectionStaysInTheMirroredWindowAndRespectsScalarBoundaries() throws {
        let prefix = String(repeating: "x", count: 4000)
        var edit = TextEdit(prefix + "a🦀z")
        edit.setSelectionRaw(anchor: edit.text.utf8.count, cursor: edit.text.utf8.count)
        let host = host(edit)
        let mirror = try #require(host.fieldMirror)
        #expect(mirror.base > 0)
        let end = mirror.text.utf16.count
        #expect(host.handleFieldSelection(key: mirror.key, base: mirror.base, expected: mirror.text, anchor: end - 1, focus: end - 3, at: 1))
        #expect(host.runtime.state.edit.anchor == prefix.utf8.count + 5)
        #expect(host.runtime.state.edit.cursor == prefix.utf8.count + 1)
        let moved = try #require(host.fieldMirror)
        let middle = moved.text.utf16.count - 2
        for invalid in [middle, -1, Int.max] {
            #expect(!host.handleFieldSelection(key: moved.key, base: moved.base, expected: moved.text, anchor: invalid, focus: 0, at: 2))
        }
        #expect(!host.handleFieldSelection(key: moved.key, base: moved.base + 1, expected: moved.text, anchor: 0, focus: 0, at: 2))
        #expect(!host.handleFieldSelection(key: "other", base: moved.base, expected: moved.text, anchor: 0, focus: 0, at: 2))
        #expect(host.runtime.state.changeCount == 0)
    }

    @Test func rejectedAndExternallyChangedDraftsKeepTheirModelValue() throws {
        let host = host(TextEdit("old"))
        let mirror = try #require(host.fieldMirror)
        host.runtime.state.rejected = true
        #expect(!host.handleFieldEdit(key: mirror.key, base: 0, expected: "old", text: "new", anchor: 3, focus: 3, at: 1))
        #expect(host.runtime.state.edit.text == "old")
        #expect(host.runtime.state.changeCount == 1)
        host.runtime.state.edit.replaceText("newer")
        #expect(!host.handleFieldEdit(key: mirror.key, base: 0, expected: "old", text: "stale", anchor: 5, focus: 5, at: 2))
        #expect(host.runtime.state.changeCount == 1)
        #expect(host.fieldMirror?.text == "newer")
    }

    @Test func secureAndLockedEditorsDoNotExposeAWindow() throws {
        let secret = host(TextEdit(""), secure: true)
        let mirror = try #require(secret.fieldMirror)
        #expect(mirror.secure && mirror.text.isEmpty)
        #expect(secret.handleSecureFieldInsert(key: mirror.key, text: "🦀", at: 1))
        #expect(secret.runtime.state.edit.text == "🦀")
        #expect(secret.fieldMirror?.text == "")
        #expect(!secret.handleFieldEdit(key: mirror.key, base: 0, expected: "", text: "visible", anchor: 7, focus: 7, at: 2))
        let locked = host(TextEdit("private"), locked: true)
        #expect(locked.fieldMirror == nil)
        #expect(!locked.handleFieldEdit(key: "draft", base: 0, expected: "private", text: "changed", anchor: 0, focus: 0, at: 2))
        #expect(!locked.handleSecureFieldInsert(key: "draft", text: "changed", at: 2))
        #expect(locked.runtime.state.edit.text == "private")
    }
}
