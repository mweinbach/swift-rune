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
        for device in ["mouse", "pen", "touch"] {
            for phase in ["pointerdown", "pointermove", "pointerup"] {
                try verify(phase, ["pointerType": device, "x": phase == "pointerdown" ? 18 : 20, "y": 20],
                           tracksArrival: device != "touch")
            }
        }
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
