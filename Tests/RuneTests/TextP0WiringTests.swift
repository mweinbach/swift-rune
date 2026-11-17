import Foundation
import Testing
@testable import Rune

#if canImport(AppKit)
import AppKit
#endif

@Suite("Text, IME, A11y, SpellPause & Shortcuts P0 Wiring Tests")
struct TextP0WiringTests {

    @Test("ImeUTF16Bridge converts surrogate pairs, multi-byte UTF-8, paragraphs, and reconversion ranges")
    func imeUTF16ConversionsAndSlice() {
        let sample = "first para\n😀あいう test\nthird para"
        // "😀" is at UTF-8 byte 11 (4 bytes), "あ" at 15 (3 bytes)
        let u16EmojiEnd = ImeUTF16Bridge.utf16Offset(in: sample, fromUTF8Offset: 15)
        // "first para\n" = 11 UTF-16 units, "😀" = 2 UTF-16 units => 13
        #expect(u16EmojiEnd == 13)
        #expect(ImeUTF16Bridge.utf8Offset(in: sample, fromUTF16Offset: 13) == 15)
        // Surrogate-pair interior snaps cleanly to scalar boundary
        #expect(ImeUTF16Bridge.utf8Offset(in: sample, fromUTF16Offset: 12) == 11)

        // Paragraph slice around "あいう" (starts at byte 15, len 9 -> 15..<24)
        let slice = ImeUTF16Bridge.imeTextSlice(text: sample, selectionUTF8: 15..<24, maxContextBytes: 1024)
        #expect(slice.startUTF8 == 11)
        #expect(slice.text == "😀あいう test")
        #expect(slice.selectionUTF8 == 4..<13)

        // Reconversion replacement range (UTF-16 2..<5 -> "あいう") maps to document UTF-8 15..<24
        let resolved = ImeUTF16Bridge.resolveReplacement(NSRange(location: 2, length: 3), in: slice)
        #expect(resolved == 15..<24)
    }

    @Test("ImeUTF16Bridge extracts target vs non-target marked clauses and clamps long slices to 1KiB")
    func imeClausesAndParagraphBudget() {
        let preedit = "きょうは"
        let attr = NSMutableAttributedString(string: preedit)
        #if canImport(AppKit)
        attr.addAttribute(.markedClauseSegment, value: 0, range: NSRange(location: 0, length: 3))
        attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 3))
        attr.addAttribute(.markedClauseSegment, value: 1, range: NSRange(location: 3, length: 1))
        attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: NSRange(location: 3, length: 1))
        let clauses = ImeUTF16Bridge.clauses(from: attr, preedit: preedit)
        #expect(clauses.count == 2)
        #expect(clauses[0] == ImeClause(utf8Range: 0..<9, isTarget: false))
        #expect(clauses[1] == ImeClause(utf8Range: 9..<12, isTarget: true))
        #endif

        // 3000-byte single paragraph gets bounded cleanly around selection
        let longText = String(repeating: "a", count: 3000)
        let bounded = ImeUTF16Bridge.imeTextSlice(text: longText, selectionUTF8: 1500..<1500, maxContextBytes: 1024)
        #expect(bounded.text.utf8.count <= 2048)
        #expect(bounded.startUTF8 >= 476)
    }

    @Test("TextEdit applyIme handles preedit, clauses, reconversion select, commit, and secure blocks")
    func textEditApplyIme() {
        var edit = TextEdit("hello world")
        // Reconversion select on "world" (6..<11)
        #expect(edit.applyIme(.select(6..<11)) == .navigation)
        #expect(edit.selectedUTF8Range == 6..<11)

        // Preedit with empty clauses derives target clause from non-empty cursor selection
        #expect(edit.applyIme(.preedit("せかい", cursorUTF8: 0..<6, clauses: [])) == .navigation)
        let derived = edit.effectivePreeditClauses()
        #expect(derived == [
            ImeClause(utf8Range: 0..<6, isTarget: true),
            ImeClause(utf8Range: 6..<9, isTarget: false),
        ])

        // Reconversion .select is ignored mid-composition
        #expect(edit.applyIme(.select(0..<5)) == .ignored)

        // Commit replaces selection & clears preedit/clauses
        #expect(edit.applyIme(.commit("世界")) == .modified)
        #expect(edit.text == "hello 世界")
        #expect(edit.preedit == nil)
        #expect(edit.preeditClauses.isEmpty)

        // finishPreedit commits active marked text
        edit.setPreedit("!", cursor: nil, clauses: [])
        #expect(edit.finishPreedit() == true)
        #expect(edit.text == "hello 世界!")

        // Secure field never exposes imeTextSnapshot
        edit.isSecure = true
        #expect(edit.imeTextSnapshot() == nil)
    }

    @Test("AccessibilityTreeBuilder projects Runtime elements, protects secure fields, and emits live announcements")
    @MainActor
    func accessibilityRuntimeProjectionAndActions() {
        struct S {
            var count = 0
            var secret = "hunter2"
        }
        let rt = Runtime(state: S(), viewport: Vec2(400, 300)) { state, _ in
            El<S>(direction: .column)
                .child(
                    el()
                        .w(160)
                        .h(40)
                        .role(.button)
                        .key("inc-btn")
                        .onClick { st, _ in
                            st.count += 1
                        }
                        .child(text("Increment \(state.count)"))
                )
                .child(
                    El<S>()
                        .w(160)
                        .h(40)
                        .role(.textInput)
                        .key("pass-field")
                        .label("PIN")
                )
        }
        _ = rt.frame(at: 0.0)
        let snapshot = rt.accessibilitySnapshot(securePaths: [])
        // Locate pass-field (role == .textInput && text == nil)
        func find(id: String, in node: AccessibilityNode) -> AccessibilityNode? {
            if node.id == id { return node }
            for c in node.children {
                if let f = find(id: id, in: c) { return f }
            }
            return nil
        }
        let passNode = find(id: "pass-field", in: snapshot)
        #expect(passNode?.isSecure == true)
        #expect(passNode?.value == nil)
        #expect(passNode?.label == "PIN")

        // Perform accessibility press action on inc-btn
        #expect(rt.performAccessibilityAction("inc-btn", action: .press, at: 0.1) == true)
        #expect(rt.state.count == 1)

        // Live announcements announce new dialogs but never secure nodes
        let dlg = AccessibilityNode(
            id: "dlg",
            role: .dialog,
            label: "Session Saved",
            isModal: true
        )
        let secureDlg = AccessibilityNode(
            id: "sec",
            role: .dialog,
            label: "Secret",
            value: "hunter2",
            isModal: true,
            isSecure: true
        )
        let root = AccessibilityNode(id: "root", role: .group, children: [dlg, secureDlg])
        let anns = AccessibilityTreeBuilder.liveAnnouncements(previous: nil, current: root)
        #expect(anns.count == 1)
        #expect(anns[0].text == "Session Saved")
        #expect(anns[0].politeness == .assertive)
    }

    @Test("SpellPause hides squiggle under active word while typing for 1.0s then reveals after pause or caret move")
    func spellPauseBehavior() {
        let checker = SpellChecker(backend: CustomDictionarySpellChecker(words: ["hello", "world"]))
        var watch = SpellPauseWatch(path: "field", text: "")

        // User types "helloo" at caret=6 (misspelled, but actively typing under caret)
        let activeMisspelled = checker.misspelledUTF8Ranges(
            in: "helloo wrld",
            caretUTF8: 6,
            watch: &watch,
            path: "field",
            now: 1.0
        )
        // "wrld" (7..<11) is flagged, while "helloo" (0..<6) under caret=6 is suppressed!
        #expect(activeMisspelled == [7..<11])
        #expect(watch.wakeAt == 2.0)

        // Before 1.0s elapses, timer still pending
        let earlyTick = watch.tick(now: 1.5)
        #expect(earlyTick.needsRepaint == false)
        #expect(earlyTick.wakeAt == 2.0)

        // Moving caret to another word settles immediately and requests repaint
        let movedPause = watch.observe(path: "field", text: "helloo wrld", caret: 9, now: 1.6)
        #expect(movedPause == nil)

        // Typing again resets timer, and ticking at +1.0s settles and requests repaint
        _ = watch.observe(path: "field", text: "helloo wrldx", caret: 12, now: 2.0)
        let expiredTick = watch.tick(now: 3.0)
        #expect(expiredTick.needsRepaint == true)
        #expect(expiredTick.wakeAt == nil)

        // Squiggle wave points fit rect bounds
        let wave = SpellSquiggle.wavePoints(rect: MotionRect.fromXYWH(10, 20, 40, 4))
        #expect(wave.count >= 4)
        #expect(wave.first?.x == 10)
        #expect(wave.last?.x == 50)
    }

    @Test("ShortcutRegistry ignores bare modifier events and matches physical Super sequences")
    func shortcutRegistryWithPhysicalSuperModifiers() {
        final class Box: @unchecked Sendable { var fired = 0 }
        let box = Box()
        let registry = ShortcutRegistry()
        let reg = registry.register(id: "chord.test", accelerator: "cmd+k, cmd+b", scope: .global) {
            box.fired += 1
        }
        guard case .success = reg else {
            Issue.record("Expected chord registration to succeed")
            return
        }

        let superMods = Mods(cmd: KeyPlatform.current == .mac, logo: true)
        // Bare modifier event between chords must not break or advance sequence
        #expect(registry.dispatch(KeyEvent(key: .modifier(.superLeft, pressed: true), mods: superMods)) == .unhandled)

        // On macOS the physical Command key is also the primary modifier.
        #expect(registry.dispatch(KeyEvent(key: .text("k"), mods: superMods)) == .pendingChord)
        #expect(registry.dispatch(KeyEvent(key: .modifier(.superLeft, pressed: true), mods: superMods)) == .unhandled)

        // Second chord completes sequence
        #expect(registry.dispatch(KeyEvent(key: .text("b"), mods: superMods)) == .handled(id: "chord.test"))
        #expect(box.fired == 1)
    }

    @Test("MacOSCarbonKeyMap maps ANSI keycodes, NSEvent masks, and symbolic hotkey remaps")
    func carbonKeyMapAndRemaps() {
        #expect(MacOSCarbonKeyMap.keycode(forKeyName: "a") == 0)
        #expect(MacOSCarbonKeyMap.keycode(forKeyName: "space") == 49)
        #expect(MacOSCarbonKeyMap.keycode(forKeyName: "left") == 123)
        #expect(MacOSCarbonKeyMap.keycode(forKeyName: "f12") == 111)

        let carbon = MacOSCarbonKeyMap.carbonModifiers(for: Mods(shift: true, cmd: true, logo: true))
        #expect(carbon == (MacOSCarbonKeyMap.cmdMask | MacOSCarbonKeyMap.shiftMask))

        // Spotlight (id 64) remapped to Ctrl+Opt+Cmd+K
        let moved = MacOSCarbonKeyMap.parseRemap(enabled: true, keycode: 40, flags: 1_835_008)
        let remapped: [String: (keycode: UInt32, mods: UInt32)?] = ["64": moved ?? nil]
        let newMods = MacOSCarbonKeyMap.cmdMask | MacOSCarbonKeyMap.optionMask | MacOSCarbonKeyMap.controlMask
        #expect(MacOSCarbonKeyMap.namedSystemShortcut(keycode: 40, mods: newMods, remapped: remapped) == "Spotlight")
        #expect(MacOSCarbonKeyMap.namedSystemShortcut(keycode: 49, mods: MacOSCarbonKeyMap.cmdMask, remapped: remapped) == nil)
    }
}
