import Foundation
import Testing
@testable import Rune
import RuneMotion

// Upstream 412aa963 (#1000) + 73b7dec2 (#1006): `Tx::focus_when_shown` (`el/tx.rs`,
// `runtime/input/focus.rs::sync_requested_focus`, `runtime/frame.rs`). The commits changed no
// Rust #[test]; these assert the cases their code and docs specify.
@Suite("Tx.focusWhenShown parity (#1000, #1006)")
@MainActor
struct FocusWhenShownParityTests {
    struct S {
        var loaded = false
        var cardOpacity: Float = 1.0
        var cardSize: Float = 80
        var extra = 0
        var autofocused = false
        var presses = 0
        var wide = false
        var askOnPoll = false
    }

    nonisolated static func view(_ s: S, _: inout Cx<S>) -> El<S> {
        var root: El<S> = col().size(400, 300).gap(8)
            .child(el().key("prompt").size(120, 24).focusable())
            .child(el().key("other").size(120, 24).onClick { (s: inout S) in s.presses += 1 })
            .child(text("\(s.extra)").key("count"))
            .child(el().key("bar").size(s.wide ? 180 : 40, 20).motion(Spring(duration: 0.4, bounce: 0.0)))
            // A press target that takes no focus (upstream's plain `El::on_press`).
            .child(el().key("plain").size(120, 24).onClick { (s: inout S) in s.presses += 1 }.focusable(false))
        if s.autofocused {
            root = root.child(el().key("palette").size(120, 24).focusable().autofocus())
        }
        if s.loaded {
            root = root.child(
                el().key("card").size(s.cardSize, 40).opacity(s.cardOpacity)
                    .child(el().key("allow").size(60, 24).focusable())
            )
        }
        return root
    }

    static func runtime() -> Runtime<S> {
        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 300), pixelScale: 1.0) { s, cx in
            FocusWhenShownParityTests.view(s, &cx)
        }
        _ = rt.frame(at: 0.0)
        return rt
    }

    @Test("waits through any number of commits until its element shows, then focuses its first focusable with the ring")
    func waitsUntilShown() {
        let rt = Self.runtime()
        rt.update(at: 0.01) { _, tx in tx.focusWhenShown("card", ring: true) }
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == nil, "nothing keyed card shows yet")
        #expect(rt.focusWhenShownPending)
        var t = 0.02
        for _ in 0..<5 {
            t += 0.02
            rt.update(at: t) { s, _ in s.extra += 1 }
            _ = rt.frame(at: t)
            #expect(rt.focusedKey == nil)
            #expect(rt.focusWhenShownPending, "still owed across commits")
        }
        t += 0.02
        rt.update(at: t) { s, _ in s.loaded = true }
        _ = rt.frame(at: t)
        #expect(rt.focusedKey == "allow", "the card's first focusable takes it")
        #expect(rt.focusVisible, "ring: true draws the ring")
        #expect(!rt.focusWhenShownPending)
    }

    @Test("without the ring it focuses without it")
    func ringFalse() {
        let rt = Self.runtime()
        rt.update(at: 0.01) { s, tx in
            s.loaded = true
            tx.focusWhenShown("card", ring: false)
        }
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == "allow")
        #expect(!rt.focusVisible)
    }

    @Test("an element that isn't shown (transparent, or without size) doesn't take it until it shows")
    func waitsForShownNotJustMounted() {
        let rt = Self.runtime()
        rt.update(at: 0.01) { s, tx in
            s.loaded = true
            s.cardOpacity = 0
            tx.focusWhenShown("card", ring: true)
        }
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == nil, "a transparent card isn't shown")
        rt.update(at: 0.03) { s, _ in s.cardOpacity = 1; s.cardSize = 0 }
        _ = rt.frame(at: 0.04)
        #expect(rt.focusedKey == nil, "a card without width isn't shown")
        #expect(rt.focusWhenShownPending)
        rt.update(at: 0.05) { s, _ in s.cardSize = 80 }
        _ = rt.frame(at: 0.06)
        #expect(rt.focusedKey == "allow")
    }

    @Test("waits through whatever focus does meanwhile (#1006)")
    func survivesOtherFocusMoves() {
        let rt = Self.runtime()
        rt.update(at: 0.01) { _, tx in tx.focusWhenShown("card", ring: true) }
        _ = rt.frame(at: 0.02)
        // Focus moves by other means: an autofocused palette mounts and takes it, then leaves.
        rt.update(at: 0.03) { s, _ in s.autofocused = true }
        _ = rt.frame(at: 0.04)
        #expect(rt.focusedKey == "palette")
        rt.update(at: 0.05) { s, _ in s.autofocused = false }
        _ = rt.frame(at: 0.06)
        #expect(rt.focusWhenShownPending, "a move that's neither an ask nor the user's input keeps it")
        rt.update(at: 0.07) { s, _ in s.loaded = true }
        _ = rt.frame(at: 0.08)
        #expect(rt.focusedKey == "allow")
    }

    @Test("another focus ask drops it")
    func anotherAskDropsIt() {
        let rt = Self.runtime()
        rt.update(at: 0.01) { _, tx in tx.focusWhenShown("card", ring: true) }
        _ = rt.frame(at: 0.02)
        rt.update(at: 0.03) { _, tx in tx.focus("prompt") }
        _ = rt.frame(at: 0.04)
        #expect(rt.focusedKey == "prompt")
        #expect(!rt.focusWhenShownPending)
        rt.update(at: 0.05) { s, _ in s.loaded = true }
        _ = rt.frame(at: 0.06)
        #expect(rt.focusedKey == "prompt", "the dropped request focuses nothing")
    }

    @Test("the user's key drops it")
    func userKeyDropsIt() {
        let rt = Self.runtime()
        rt.update(at: 0.01) { _, tx in tx.focusWhenShown("card", ring: true) }
        _ = rt.frame(at: 0.02)
        _ = rt.keyDown(KeyEvent(key: .text("a"), mods: .none), at: 0.03)
        #expect(!rt.focusWhenShownPending)
        rt.update(at: 0.04) { s, _ in s.loaded = true }
        _ = rt.frame(at: 0.05)
        #expect(rt.focusedKey != "allow")
    }

    @Test("the user's press drops it")
    func userPressDropsIt() throws {
        let rt = Self.runtime()
        rt.update(at: 0.01) { _, tx in tx.focusWhenShown("card", ring: true) }
        _ = rt.frame(at: 0.02)
        let other = try #require(rt.elements().first { $0.key == "other" })
        let p = Vec2(other.rect[0] + other.rect[2] / 2, other.rect[1] + other.rect[3] / 2)
        rt.pointerDown(at: p, at: 0.03)
        rt.pointerUp(at: p, at: 0.03)
        #expect(rt.state.presses == 1)
        #expect(!rt.focusWhenShownPending)
        rt.update(at: 0.04) { s, _ in s.loaded = true }
        _ = rt.frame(at: 0.05)
        #expect(rt.focusedKey != "allow")
    }

    // Upstream 2e23d0fa (#995): `Runtime::covered_wake`.
    @Test("a covered window a reader reads builds what changed at once; without one it waits")
    func coveredWakeBuildsForReader() {
        for reader in [false, true] {
            let rt = Self.runtime()
            rt.assistiveTechnology = reader
            rt.setLiveVisible(false)
            let commits = rt.viewCommitCount
            rt.update(at: 0.01) { s, _ in s.extra = 7 }
            coveredStep(rt, at: 0.02)
            if reader {
                #expect(rt.viewCommitCount == commits + 1, "built at once for the reader")
                #expect(rt.elements().first { $0.key == "count" }?.text == "7")
                #expect(!rt.isStale)
            } else {
                #expect(rt.viewCommitCount == commits, "nothing built until it uncovers")
                #expect(rt.isStale)
            }
        }
    }

    @Test("focus asked of what a covered window's change shows lands while a reader reads it")
    func coveredWakeLandsAskedFocus() {
        let rt = Self.runtime()
        rt.assistiveTechnology = true
        rt.setLiveVisible(false)
        rt.update(at: 0.01) { s, tx in
            s.loaded = true
            tx.focusWhenShown("card", ring: true)
        }
        rt.coveredWake(at: 0.02)
        #expect(rt.focusedKey == "allow")
    }

    @Test("an ask not yet committed survives a key that arrives before the frame, and becomes owed (frame.rs:565)")
    func pendingAskSurvivesKeyBeforeFrame() {
        let rt = Self.runtime()
        rt.update(at: 0.01) { _, tx in tx.focusWhenShown("card", ring: true) }
        _ = rt.keyDown(KeyEvent(key: .text("a"), mods: .none), at: 0.015)
        _ = rt.frame(at: 0.02)
        #expect(rt.focusWhenShownPending, "the key dropped only what was already owed")
        rt.update(at: 0.03) { s, _ in s.loaded = true }
        _ = rt.frame(at: 0.04)
        #expect(rt.focusedKey == "allow")
    }

    @Test("an owed ask whose element shows in a commit that also blurs still focuses it")
    func owedAskResolvesThroughBlur() {
        let rt = Self.runtime()
        rt.update(at: 0.01) { _, tx in tx.focus("prompt") }
        _ = rt.frame(at: 0.02)
        rt.update(at: 0.03) { _, tx in tx.focusWhenShown("card", ring: true) }
        _ = rt.frame(at: 0.04)
        #expect(rt.focusWhenShownPending)
        rt.update(at: 0.05) { s, tx in
            s.loaded = true
            tx.blur()
        }
        _ = rt.frame(at: 0.06)
        #expect(rt.focusedKey == "allow", "the blur lands first; the owed ask resolves after it")
    }

    @Test("a blur in the same handler as focusWhenShown doesn't cancel it")
    func blurAndAskInOneHandler() {
        let rt = Self.runtime()
        rt.update(at: 0.01) { s, tx in
            tx.focusWhenShown("card", ring: false)
            tx.blur()
            s.loaded = true
        }
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == "allow")
    }

    @Test("a covered window's build for a reader holds motion: it doesn't advance time (`frame(0.0)`)")
    func coveredWakeHoldsMotion() throws {
        let rt = Self.runtime()
        rt.assistiveTechnology = true
        rt.setLiveVisible(false)
        rt.update(at: 0.5) { s, _ in s.wide = true }
        rt.coveredWake(at: 1.0)
        let bar = try #require(rt.elements().first { $0.key == "bar" })
        #expect(bar.target[2] == 180, "the change is built")
        let presented = try #require(rt.presented("bar")).rect[2]
        #expect(abs(presented - 40) < 0.5, "no time passed for its motion: \(presented)")
    }

    @Test("a latched focusWhenShown schedules a commit: from a poll that changed nothing it resolves on the next frame (`latch_requests`)")
    func pollAskWithoutChangeResolves() {
        let rt = Self.runtime()
        rt.update(at: 0.01) { s, _ in s.loaded = true }
        _ = rt.frame(at: 0.02)
        rt.poll = { s, _, tx in
            guard s.askOnPoll else { return false }
            s.askOnPoll = false
            tx.focusWhenShown("card", ring: true)
            return false
        }
        rt.state.askOnPoll = true
        _ = rt.frame(at: 0.03)
        #expect(rt.focusedKey == "allow")
    }

    @Test("a focusWhenShown from an updateIf that reports no change still resolves")
    func updateIfAskWithoutChangeResolves() {
        let rt = Self.runtime()
        rt.update(at: 0.01) { s, _ in s.loaded = true }
        _ = rt.frame(at: 0.02)
        _ = rt.updateIf(at: 0.03) { _, tx in
            tx.focusWhenShown("card", ring: false)
            return false
        }
        _ = rt.frame(at: 0.04)
        #expect(rt.focusedKey == "allow")
    }

    // Review round 3: `focus_owed` vs the poll split across a frame's whole queue (frame.rs:565-596).
    static func pollAsking(_ rt: Runtime<S>) {
        rt.motionNeedsCause = true
        rt.poll = { s, _, tx in
            guard s.askOnPoll else { return false }
            s.askOnPoll = false
            s.extra += 1
            tx.focusWhenShown("card", ring: true)
            return true
        }
    }

    @Test("a click after a resting poll asked keeps the ask: the press drops what was owed before the split made it owed")
    func clickAfterRestingPollKeepsAsk() throws {
        let rt = Self.runtime()
        Self.pollAsking(rt)
        rt.state.askOnPoll = true
        _ = try #require(rt.restingWake(), "the runtime rests, so the poll runs alone")
        let plain = try #require(rt.elements().first { $0.key == "plain" })
        let p = Vec2(plain.rect[0] + plain.rect[2] / 2, plain.rect[1] + plain.rect[3] / 2)
        rt.pointerDown(at: p, at: 0.505)
        rt.pointerUp(at: p, at: 0.506)
        #expect(rt.state.presses == 1)
        _ = rt.frame(at: 0.52)
        #expect(rt.focusWhenShownPending, "Action::Press ran before the split made it owed")
        rt.update(at: 0.53) { s, _ in s.loaded = true }
        _ = rt.frame(at: 0.54)
        #expect(rt.focusedKey == "allow")
    }

    @Test("a second click in the same frame, after the first's press ran, drops the ask the split made owed")
    func secondClickSameFrameDropsAsk() throws {
        let rt = Self.runtime()
        Self.pollAsking(rt)
        rt.state.askOnPoll = true
        _ = try #require(rt.restingWake())
        let plain = try #require(rt.elements().first { $0.key == "plain" })
        let p = Vec2(plain.rect[0] + plain.rect[2] / 2, plain.rect[1] + plain.rect[3] / 2)
        rt.pointerDown(at: p, at: 0.505)
        rt.pointerUp(at: p, at: 0.506)
        rt.pointerDown(at: p, at: 0.507)
        rt.pointerUp(at: p, at: 0.508)
        _ = rt.frame(at: 0.52)
        #expect(!rt.focusWhenShownPending, "the second Action::Press comes after the split")
    }

    @Test("a blur in the same commit as an ask still lets a newly requested text field win (focus.rs `requested` before `asked`)")
    func newlyRequestedFieldBeatsAskThroughBlur() {
        struct F { var ask = false; var field = false }
        let rt = Runtime<F>(state: F(), viewport: Vec2(400, 300), pixelScale: 1.0) { s, _ in
            col().size(400, 300)
                .child(el().key("prompt").size(120, 24).focusable())
                .child(el().key("card").size(80, 40).child(el().key("allow").size(60, 24).focusable()))
                .child(el().key("field").size(120, 24).focusable().focused(s.field))
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { _, tx in tx.focus("prompt") }
        _ = rt.frame(at: 0.02)
        rt.update(at: 0.03) { s, tx in
            tx.focusWhenShown("card", ring: true)
            tx.blur()
            s.field = true
        }
        _ = rt.frame(at: 0.04)
        #expect(rt.focusedKey == "field", "the newly requested field wins over the asked focus")
    }

    @Test("a click on a control that takes focus drops it: its focus move (`Action::FocusControl`) runs after the split, before `Action::Press`")
    func clickOnFocusTakingControlDropsAsk() throws {
        let rt = Self.runtime()
        Self.pollAsking(rt)
        rt.state.askOnPoll = true
        _ = try #require(rt.restingWake())
        // Swift's `onClick` makes its element focusable, as `.focusable()` does upstream.
        let other = try #require(rt.elements().first { $0.key == "other" })
        let p = Vec2(other.rect[0] + other.rect[2] / 2, other.rect[1] + other.rect[3] / 2)
        rt.pointerDown(at: p, at: 0.505)
        rt.pointerUp(at: p, at: 0.506)
        _ = rt.frame(at: 0.52)
        #expect(rt.focusedKey == "other")
        #expect(!rt.focusWhenShownPending, "Action::Press comes after FocusControl, which the split preceded")
    }
}
