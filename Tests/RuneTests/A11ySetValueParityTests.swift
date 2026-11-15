import Foundation
import Testing
@testable import Rune

/// Ports of upstream `crates/rune/src/a11y/roles.rs` and `a11y/tests.rs` cases covering
/// `Action::SetValue` and `Role::MultilineTextInput`.
@Suite("A11y SetValue & multiline text input parity", .serialized)
@MainActor
struct A11ySetValueParityTests {
    private func parse(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    private func find(_ v: [String: Any], _ key: String) -> [String: Any]? {
        if v["key"] as? String == key { return v }
        for c in (v["children"] as? [[String: Any]]) ?? [] {
            if let hit = find(c, key) { return hit }
        }
        return nil
    }

    private func states(_ v: [String: Any]?) -> [String] { (v?["states"] as? [String]) ?? [] }
    private func actions(_ v: [String: Any]?) -> [String] { (v?["actions"] as? [String]) ?? [] }

    // MARK: - `a11y/roles.rs:181` text_fields_take_their_kind_from_the_editor

    @Test("text fields take their kind from the editor (`a11y/roles.rs:181`)")
    func textFieldsTakeTheirKindFromTheEditor() {
        #expect(AccessibilityTreeBuilder.textFieldRole(secure: false, multiline: false) == .textInput)
        #expect(AccessibilityTreeBuilder.textFieldRole(secure: false, multiline: true) == .multilineTextInput)
        #expect(AccessibilityTreeBuilder.textFieldRole(secure: true, multiline: false) == .passwordInput)
        #expect(AccessibilityTreeBuilder.textFieldRole(secure: true, multiline: true) == .passwordInput)
        #expect(ElementRole.multilineTextInput.rawValue == "multiline-text-input")
        #expect(AccessibilityAction.setValue.rawValue == "set-value")
    }

    // MARK: - `a11y/tests.rs` form fixture

    struct Form {
        var presses = 0
        var level = 0
        var name = TextEdit()
    }

    private func formRuntime() -> Runtime<Form> {
        let rt = Runtime(state: Form(), viewport: Vec2(400, 500), systemDark: true) { s, _ in
            col().wFull().gap(8).children([
                row().key("save").role(.button).focusable(true)
                    .onClick { st, _ in st.presses += 1 }
                    .child(text("Save")),
                el().key("volume").role(.slider)
                    .rangeValue(Double(s.level), min: 0.0, max: 10.0).rangeStep(1.0)
                    .label("Volume").size(100, 12)
                    .onStep { st, d, _ in st.level = min(max(st.level + d, 0), 10) },
                textInput(key: "name", \Form.name).singleLine().w(200),
                row().key("off").role(.button).disabled(true).child(text("Unavailable")),
            ])
        }
        rt.frame(at: 0.0)
        return rt
    }

    @Test("controls report set-value on editable fields and stepped ranges (`a11y/tests.rs:91-96`)")
    func controlsReportSetValue() {
        let rt = formRuntime()
        let tree = parse(rt.accessibilityJSON())
        let volume = find(tree, "volume")
        #expect(volume?["role"] as? String == "slider")
        #expect(actions(volume).contains("increment"))
        #expect(actions(volume).contains("set-value"), "a slider with a stated step takes a number")
        let name = find(tree, "name")
        #expect(name?["role"] as? String == "textbox", "a single-line field is a text input")
        #expect(actions(name).contains("set-value"))
        let off = find(tree, "off")
        #expect(states(off).contains("disabled") && actions(off).isEmpty)
    }

    @Test("actions run the same handlers as pointer and keys: SetValue (`a11y/tests.rs:103-145`)")
    func actionsRunTheSameHandlersAsPointerAndKeys() {
        let rt = formRuntime()
        for i in 0..<3 {
            rt.accessibilityAction("volume", .increment, at: 0.01 * Double(i + 1))
            rt.frame(at: 0.01 * Double(i + 1))
        }
        #expect(rt.state.level == 3)
        #expect(rt.accessibilityAction("volume", .setValue, value: .number(7.2), at: 0.1), "a slider with a step takes a number")
        rt.frame(at: 0.1)
        #expect(rt.state.level == 7, "set as steps through onStep, rounded to a step")
        #expect(!rt.accessibilityAction("volume", .setValue, value: .number(7.2), at: 0.11), "no movement runs nothing")
        #expect(!rt.accessibilityAction("volume", .setValue, value: .text("7"), at: 0.11), "a range takes a number")

        #expect(rt.accessibilityAction("name", .setValue, value: .text("Ada"), at: 0.2))
        rt.frame(at: 0.2)
        #expect(rt.state.name.text == "Ada")
        let tree = parse(rt.accessibilityJSON())
        let name = find(tree, "name")
        #expect(name?["value"] as? String == "Ada")
        #expect(states(name).contains("focused"), "editing focuses the field")
        #expect(!rt.accessibilityAction("name", .setValue, at: 0.3), "SetValue without a value does nothing")
        #expect(!rt.accessibilityAction("off", .setValue, value: .text("x"), at: 0.3), "a disabled control takes no action")
    }

    @Test("SetValue steps clamp into the range and round to whole steps (`a11y/actions.rs:73-82`)")
    func setValueStepsClampAndRound() {
        let r = A11yRange(value: 3, min: 0, max: 10, step: 1)
        #expect(AccessibilityTreeBuilder.setValueSteps(target: 7.2, range: r) == 4)
        #expect(AccessibilityTreeBuilder.setValueSteps(target: 99, range: r) == 7)
        #expect(AccessibilityTreeBuilder.setValueSteps(target: -5, range: r) == -3)
        #expect(AccessibilityTreeBuilder.setValueSteps(target: 3.4, range: r) == nil)
        #expect(AccessibilityTreeBuilder.setValueSteps(target: 5, range: A11yRange(value: 3, min: 0, max: 10)) == nil)
        #expect(AccessibilityTreeBuilder.setValueSteps(target: 5, range: A11yRange(value: 3, min: 0, max: 10, step: 0)) == nil)
        #expect(AccessibilityTreeBuilder.setValueSteps(target: 0.5, range: A11yRange(value: 0, min: 0, max: 1, step: 0.25)) == 2)
    }

    // MARK: - `a11y/tests.rs:258` text_fields_expose_lines_caret_and_selection (role)

    struct Field {
        var edit: TextEdit
    }

    @Test("a field that is not single-line is a multi-line text input (`a11y/tests.rs:267`)")
    func multilineFieldRole() {
        // Swift's `TextEdit` is single-line unless built multi-line; upstream's `text_input` editor
        // is multi-line until `El::single_line` (the El below stays not single-line, as upstream's).
        let edit = TextEdit("hello world", multiline: true)
        let rt = Runtime(state: Field(edit: edit), viewport: Vec2(400, 200), systemDark: true) { _, _ in
            col().child(textInput(key: "note", \Field.edit).w(300))
        }
        rt.frame(at: 0.0)
        let note = find(parse(rt.accessibilityJSON()), "note")
        #expect(note?["role"] as? String == "multiline-text-input")

        let single = Runtime(state: Field(edit: edit), viewport: Vec2(400, 200), systemDark: true) { _, _ in
            col().child(textInput(key: "note", \Field.edit).singleLine().w(300))
        }
        single.frame(at: 0.0)
        #expect(find(parse(single.accessibilityJSON()), "note")?["role"] as? String == "textbox")
    }
}
