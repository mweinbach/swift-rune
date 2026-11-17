import Testing
import Foundation
@testable import Rune

@Suite("El & Runtime Increment 1 P0 Parity Tests")
struct ElP0ParityTests {

    // MARK: - Secure Text Leak (`runtime/tests/secure_text.rs`, Item 10)

    @Test("Secure textInput and secure label omit ElementInfo.text and treeJSON text, hidden or revealed")
    func secureFieldDoesNotLeakPlaintext() throws {
        struct State {
            var secretEdit = TextEdit("hunter2", multiline: false)
            var revealed = false
        }
        let rt = Runtime(state: State(), viewport: Vec2(400, 300)) { s, _ in
            col().gap(8)
                .child(
                    textInput(key: "pw", \State.secretEdit)
                        .secure(true)
                        .revealed(s.revealed)
                        .size(200, 32)
                )
                .child(
                    text("top-secret-token")
                        .key("tok")
                        .secure(true)
                        .revealed(s.revealed)
                        .selected("sel-secret")
                        .size(200, 24)
                )
        }
        _ = rt.frame(at: 0.0)

        for k in ["pw", "tok"] {
            let info = try #require(rt.element(byKey: k))
            #expect(info.secure == true)
            #expect(info.text == nil)
            #expect(info.selected == nil)
            #expect(rt.elementIsSecure(info.path) == true)
        }
        #expect(rt.elementIsSecure("/nonexistent") == false)

        let jsonStrHidden = String(decoding: try rt.treeJSONData(pretty: false), as: UTF8.self)
        #expect(!jsonStrHidden.contains("hunter2"))
        #expect(!jsonStrHidden.contains("top-secret-token"))
        #expect(!jsonStrHidden.contains("sel-secret"))
        #expect(jsonStrHidden.contains("\"secure\":true"))

        // Revealed state still never leaks plaintext to ElementInfo, treeJSON, or Cmd+C clipboard!
        rt.state.revealed = true
        _ = rt.frame(at: 0.02)

        for k in ["pw", "tok"] {
            let info = try #require(rt.element(byKey: k))
            #expect(info.secure == true)
            #expect(info.text == nil)
            #expect(info.selected == nil)
            #expect(rt.elementIsSecure(info.path) == true)
        }
        let pwRect = try #require(rt.element(byKey: "pw")).rect
        rt.pointerDown(at: Vec2(pwRect[0] + 5, pwRect[1] + 5), at: 0.03)
        rt.pointerUp(at: Vec2(pwRect[0] + 5, pwRect[1] + 5), at: 0.04)
        rt.clipboard = ClipboardContent("sentinel")
        _ = rt.keyDown(KeyEvent(key: .command("a"), mods: Mods(cmd: true)), at: 0.05)
        _ = rt.keyDown(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), at: 0.06)
        #expect(rt.clipboard.text == "sentinel")
    }

    // MARK: - Focus / onKey Preemption (`runtime/tests/on_key_tests.rs`)

    @Test("Focused textInput keeps its keys and is not preempted by ancestor onKey")
    func focusedTextInputKeepsKeysOverAncestorOnKey() throws {
        struct State {
            var edit = TextEdit("abc", multiline: false)
            var ancestorIntercepts = 0
        }
        let rt = Runtime(state: State(), viewport: Vec2(400, 200)) { _, _ in
            col()
                .onKey { s, _, _ in
                    s.ancestorIntercepts += 1
                    return true
                }
                .child(textInput(key: "field", \State.edit).size(200, 32))
        }
        _ = rt.frame(at: 0.0)
        let r = try #require(rt.element(byKey: "field")).rect
        rt.pointerDown(at: Vec2(r[0] + r[2] - 2, r[1] + 10), at: 0.01)
        rt.pointerUp(at: Vec2(r[0] + r[2] - 2, r[1] + 10), at: 0.02)

        _ = rt.keyDown(KeyEvent(key: .text("x")), at: 0.03)
        #expect(rt.state.ancestorIntercepts == 0)
        #expect(rt.state.edit.text == "abcx")
    }

    @Test("Modal stops keys from bubbling to inert ancestor onKey, while non-input focused control runs innermost-first")
    func modalStopsOnKeyBubblingToAncestor() throws {
        struct State {
            var calls: [String] = []
        }
        let rt = Runtime(state: State(), viewport: Vec2(400, 300)) { _, _ in
            col()
                .onKey { s, _, _ in
                    s.calls.append("root")
                    return true
                }
                .child(
                    col()
                        .key("sheet")
                        .modal(true)
                        .child(
                            el()
                                .key("inner-btn")
                                .focusable(true)
                                .autofocus(true)
                                .size(100, 40)
                        )
                )
        }
        _ = rt.frame(at: 0.0)
        let handled = rt.keyDown(KeyEvent(key: .text("j")), at: 0.01)
        #expect(handled == false)
        #expect(rt.state.calls.isEmpty)
    }

    // MARK: - Hit-Testing: Blockers, Opacity-0, Half-Open Edges, Rotation, Pick/Picked (`pose_hit.rs`, `pointer_hit.rs`)

    @Test("Visual blockers block clicks beneath, opacity-0 nodes do not, and right/bottom edges are half-open")
    func hitTestingBlockersOpacityAndHalfOpenEdges() throws {
        struct State {
            var hits: [String] = []
        }
        let rt = Runtime(state: State(), viewport: Vec2(300, 300)) { _, _ in
            el().size(300, 300)
                // Button at [0, 0, 100, 100] with filled child badge inside it
                .child(
                    el().key("btn-behind").size(100, 100)
                        .onClick { s in s.hits.append("btn-behind") }
                        .child(el().key("badge-inside").size(30, 30).bg(Color(r: 0, g: 0, b: 1, a: 1)))
                )
                // Non-interactive filled card covering right half [50, 0, 50, 100]
                .child(
                    el().key("card-blocker").pin(top: 0, left: 50).size(50, 100).bg(Color(r: 0.5, g: 0.5, b: 0.5, a: 1))
                )
                // Fully transparent overlay covering top-left [0, 0, 40, 40] -> must NOT block!
                .child(
                    el().key("ghost").pin(top: 0, left: 0).size(40, 40).bg(Color(r: 1, g: 0, b: 0, a: 1)).opacity(0)
                )
                // Second adjacent clickable tile [120, 0, 40, 20] + [160, 0, 40, 20] for half-open edge check
                .child(
                    el().key("tile-a").pin(top: 0, left: 120).size(40, 20)
                        .onClick { s in s.hits.append("tile-a") }
                )
                .child(
                    el().key("tile-b").pin(top: 0, left: 160).size(40, 20)
                        .onClick { s in s.hits.append("tile-b") }
                )
        }
        _ = rt.frame(at: 0.0)

        // 1. Clicking inside badge-inside (descendant of btn-behind) under ghost (opacity 0) hits btn-behind!
        rt.pointerDown(at: Vec2(15, 15), at: 0.01)
        rt.pointerUp(at: Vec2(15, 15), at: 0.02)
        #expect(rt.state.hits == ["btn-behind"])

        // 2. Clicking on card-blocker [50..100) is blocked even though card-blocker has no onClick
        rt.pointerDown(at: Vec2(75, 50), at: 0.03)
        rt.pointerUp(at: Vec2(75, 50), at: 0.04)
        #expect(rt.state.hits == ["btn-behind"])

        // 3. Half-open right edge: x=160 is right edge of tile-a [120, 160) and left edge of tile-b [160, 200)
        rt.pointerDown(at: Vec2(160, 10), at: 0.05)
        rt.pointerUp(at: Vec2(160, 10), at: 0.06)
        #expect(rt.state.hits == ["btn-behind", "tile-b"])

        // 4. Pick & elementAt skips opacity-0 unless Pick().transparent(true)
        #expect(rt.elementAt(15, 15)?.key == "badge-inside")
        #expect(rt.elementAtWith(15, 15, pick: Pick().transparent(true))?.key == "ghost")
    }

    @Test("Rotated element unturns hit points around origin, and slash-path selectors find nested keys")
    func rotatedHitTestingAndSlashPathFind() throws {
        struct State {
            var clicks = 0
        }
        // Box [100, 100, 100, 20] centered at (150, 110), rotated 90 deg clockwise -> [140..160, 60..160]
        let rt = Runtime(state: State(), viewport: Vec2(400, 400)) { _, _ in
            el().size(400, 400)
                .child(
                    el().key("bar")
                        .pin(top: 100, left: 100)
                        .size(100, 20)
                        .rotate(.pi * 0.5)
                        .onClick { s in s.clicks += 1 }
                )
                .child(
                    el().key("slider").pin(top: 250, left: 20).size(100, 20)
                        .child(el().child(el().key("knob").size(12, 12)))
                )
        }
        _ = rt.frame(at: 0.0)

        // Point inside rotated footprint [150, 75] -> hits bar!
        #expect(rt.contains("bar", x: 150, y: 75) == true)
        #expect(rt.elementAt(150, 75)?.key == "bar")
        // Point inside original unrotated box [185, 110] -> outside rotated box!
        #expect(rt.contains("bar", x: 185, y: 110) == false)

        rt.pointerDown(at: Vec2(150, 75), at: 0.01)
        rt.pointerUp(at: Vec2(150, 75), at: 0.02)
        rt.pointerDown(at: Vec2(185, 110), at: 0.03)
        rt.pointerUp(at: Vec2(185, 110), at: 0.04)
        #expect(rt.state.clicks == 1)

        // Slash-path selector (`#109`): "slider/knob" skips intermediate unkeyed wrapper
        let knob = rt.element(byKey: "slider/knob")
        #expect(knob?.key == "knob")
        #expect(rt.find("slider/knob") != nil)
    }

    @Test("Hidden secure labels measure and paint fixed 12-bullet mask regardless of wrap or plaintext length")
    func hiddenSecureLabelMaskMatchesLengthAgnosticLayout() throws {
        struct State {
            var revealed = false
        }
        let rt = Runtime(state: State(), viewport: Vec2(400, 200)) { s, _ in
            col().itemsStart().gap(8)
                .child(text("a").key("short").secure(true).revealed(s.revealed))
                .child(text("much-longer-secret-string").key("long").secure(true).revealed(s.revealed))
        }
        _ = rt.frame(at: 0.0)
        let shortInfo = try #require(rt.element(byKey: "short"))
        let longInfo = try #require(rt.element(byKey: "long"))
        #expect(abs(shortInfo.rect[2] - longInfo.rect[2]) < 0.01)
        #expect(abs(shortInfo.rect[3] - longInfo.rect[3]) < 0.01)

        // When revealed, true text lengths determine layout bounds
        rt.state.revealed = true
        rt.markNeedsCommit()
        _ = rt.frame(at: 0.02)
        let shortRev = try #require(rt.element(byKey: "short"))
        let longRev = try #require(rt.element(byKey: "long"))
        #expect(longRev.target[2] > shortRev.target[2] + 20)

        _ = rt.frame(at: 1.02)
        let shortDrawn = try #require(rt.element(byKey: "short"))
        let longDrawn = try #require(rt.element(byKey: "long"))
        #expect(longDrawn.rect[2] > shortDrawn.rect[2] + 20)
    }

    @Test("Nested rotated element folds ancestor rotated clip into outerClip for hit-testing")
    func nestedRotatedClipHitTesting() throws {
        struct State {
            var clicks = 0
        }
        // Outer clipped box [100..200, 100..160] centered at (150, 130), rotated 90 deg -> screen footprint [120..180, 80..180].
        // Inner child at [100..200, 100..120] (top strip in outer's space -> right strip [160..180, 80..180] in screen space),
        // also rotated 90 deg around its own center (150, 110) before outer's turn, extending outside outer's clip.
        let rt = Runtime(state: State(), viewport: Vec2(400, 400)) { _, _ in
            el().size(400, 400)
                .child(
                    el().key("outer")
                        .pin(top: 100, left: 100)
                        .size(100, 60)
                        .clip()
                        .rotate(.pi * 0.5)
                        .child(
                            el().key("inner")
                                .size(100, 20)
                                .rotate(.pi * 0.5)
                                .onClick { s in s.clicks += 1 }
                        )
                )
        }
        _ = rt.frame(at: 0.0)
        // Center of inner's [100..200, 100..120] strip inside outer's clip maps to (170, 130) after outer's 90deg turn;
        // wait: after inner's own 90deg turn around (150,110) + outer's 90deg turn around (150,130), center (150,110) maps to (170, 130), inside outer's rotated bbox [120..180, 80..180].
        #expect(rt.contains("inner", x: 170, y: 130) == true)
        // Point (170, 200) lies along inner's unclipped rotated extent in outer's turned space but OUTSIDE outer's rotated clip bbox [120..180, 80..180] -> must miss!
        #expect(rt.contains("inner", x: 170, y: 200) == false)
    }
}
