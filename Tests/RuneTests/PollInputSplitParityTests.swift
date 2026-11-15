import Foundation
import Testing
@testable import Rune
import RuneMotion

// Upstream 56e0306d (#970) "Keep polled content still when input changes the same frame":
// with `motion_needs_cause`, a resting poll's change commits apart from same-frame input, at once,
// and the input's handler keeps its own animation. The commit changed no Rust #[test].
@Suite("Poll change committed apart from input parity (#970)")
@MainActor
struct PollInputSplitParityTests {
    struct S {
        var polledWide = false
        var clickedWide = false
        var pollDue = false
    }

    nonisolated static func view(_ s: S, _: inout Cx<S>) -> El<S> {
        col().size(400, 300).gap(8)
            // The window's paste handler (`El.onPaste` on the root).
            .onPaste { s, _, _ in s.clickedWide = true }
            .child(el().key("polled").size(s.polledWide ? 180 : 40, 20).motion(Spring(duration: 0.4, bounce: 0.0)))
            .child(el().key("btn").size(80, 24).onClick { (s: inout S) in s.clickedWide.toggle() })
            .child(el().key("clicked").size(s.clickedWide ? 180 : 40, 20).motion(Spring(duration: 0.4, bounce: 0.0)))
            // Input that isn't a press or a key down: a hover, a wheel, a key-up, a paste.
            .child(el().key("hov").size(80, 24).onHoverChange { s, on, _ in if on { s.clickedWide = true } })
            .child(el().key("wheel").size(80, 24).onWheel { s, _, _ in s.clickedWide = true; return true })
            .child(
                el().key("field").size(80, 24).focusable()
                    .onKeyUp { s, _, _ in s.clickedWide = true; return true }
            )
    }

    static func runtime(motionNeedsCause: Bool) -> Runtime<S> {
        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 300), pixelScale: 1.0) { s, cx in
            PollInputSplitParityTests.view(s, &cx)
        }
        rt.motionNeedsCause = motionNeedsCause
        rt.poll = { s, _, _ in
            guard s.pollDue else { return false }
            s.pollDue = false
            s.polledWide = true
            return true
        }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 1.0)
        return rt
    }

    static func width(_ rt: Runtime<S>, _ key: String) -> Float {
        rt.presented(key)?.rect[2] ?? -1
    }

    /// A resting poll changes the model, then a press changes it again before the frame.
    static func pollThenPress(_ rt: Runtime<S>) throws {
        rt.state.pollDue = true
        let asked = try #require(rt.restingWake(), "the runtime rests, so the poll runs alone")
        #expect(asked, "the poll changed what shows")
        let btn = try #require(rt.elements().first { $0.key == "btn" })
        let p = Vec2(btn.rect[0] + btn.rect[2] / 2, btn.rect[1] + btn.rect[3] / 2)
        rt.pointerDown(at: p, at: 1.005)
        rt.pointerUp(at: p, at: 1.005)
        #expect(rt.state.clickedWide, "the press reached its handler")
        for i in 1...4 { _ = rt.frame(at: 1.0 + Double(i) / 60.0) }
    }

    @Test("a resting poll's change shows at once when a press changes the view the same frame; the press keeps its motion")
    func pollAndInputSplit() throws {
        let rt = Self.runtime(motionNeedsCause: true)
        try Self.pollThenPress(rt)
        #expect(abs(Self.width(rt, "polled") - 180) < 0.5, "the poll's change committed at once, on its own")
        let clicked = Self.width(rt, "clicked")
        #expect(clicked > 40 && clicked < 180, "the press's change animates: \(clicked)")
    }

    @Test("without motionNeedsCause nothing splits: both changes animate")
    func noSplitWithoutMotionNeedsCause() throws {
        let rt = Self.runtime(motionNeedsCause: false)
        try Self.pollThenPress(rt)
        let polled = Self.width(rt, "polled")
        let clicked = Self.width(rt, "clicked")
        #expect(polled > 40 && polled < 180, "the poll's change animates: \(polled)")
        #expect(clicked > 40 && clicked < 180, "the press's change animates: \(clicked)")
    }

    @Test("a poll's change alone under motionNeedsCause shows at once")
    func pollAloneIsUnprompted() throws {
        let rt = Self.runtime(motionNeedsCause: true)
        rt.state.pollDue = true
        _ = try #require(rt.restingWake())
        _ = rt.frame(at: 1.0 + 1.0 / 60.0)
        #expect(abs(Self.width(rt, "polled") - 180) < 0.5)
        #expect(!rt.polledChange, "the frame spent it")
    }

    static func centre(_ rt: Runtime<S>, _ key: String) throws -> Vec2 {
        let e = try #require(rt.elements().first { $0.key == key })
        return Vec2(e.rect[0] + e.rect[2] / 2, e.rect[1] + e.rect[3] / 2)
    }

    /// The poll's change landed at once, the input's change animates.
    static func expectSplit(_ rt: Runtime<S>, _ what: String) {
        let polled = width(rt, "polled")
        let clicked = width(rt, "clicked")
        #expect(abs(polled - 180) < 0.5, "\(what): the poll's change committed at once, on its own: \(polled)")
        #expect(clicked > 40 && clicked < 180, "\(what): the input's change animates: \(clicked)")
    }

    @Test("the frame's own poll and a press since the last frame: the polled row lands at once, the press animates (frame.rs:532)")
    func framePollAndPressSplit() throws {
        let rt = Self.runtime(motionNeedsCause: true)
        rt.state.pollDue = true
        let p = try Self.centre(rt, "btn")
        rt.pointerDown(at: p, at: 1.005)
        rt.pointerUp(at: p, at: 1.005)
        #expect(!rt.state.polledWide, "the poll runs in the frame")
        for i in 1...4 { _ = rt.frame(at: 1.0 + Double(i) / 60.0) }
        #expect(rt.state.polledWide && rt.state.clickedWide)
        Self.expectSplit(rt, "frame poll + press")
    }

    @Test("the frame's own poll without motionNeedsCause: both changes animate")
    func framePollNoSplitWithoutMotionNeedsCause() throws {
        let rt = Self.runtime(motionNeedsCause: false)
        rt.state.pollDue = true
        let p = try Self.centre(rt, "btn")
        rt.pointerDown(at: p, at: 1.005)
        rt.pointerUp(at: p, at: 1.005)
        for i in 1...4 { _ = rt.frame(at: 1.0 + Double(i) / 60.0) }
        let polled = Self.width(rt, "polled")
        #expect(polled > 40 && polled < 180, "the poll's change animates: \(polled)")
    }

    @Test("a resting poll then a hover, wheel or key-up handler: each splits as an input action (`input || routed`)")
    func restingPollThenOtherInputSplits() throws {
        for kind in ["hover", "wheel", "keyUp"] {
            let rt = Self.runtime(motionNeedsCause: true)
            if kind == "keyUp" {
                rt.update(at: 1.0) { _, tx in tx.focus("field") }
                _ = rt.frame(at: 1.0)
                _ = rt.keyDown(KeyEvent(key: .text("a"), mods: .none), at: 1.001)
                _ = rt.frame(at: 1.002)
            }
            rt.state.pollDue = true
            _ = try #require(rt.restingWake(), "\(kind): the runtime rests, so the poll runs alone")
            switch kind {
            case "hover":
                rt.pointerMove(to: try Self.centre(rt, "hov"), at: 1.005)
            case "wheel":
                let p = try Self.centre(rt, "wheel")
                rt.wheel(WheelEvent(dx: 0, dy: 10, x: p.x, y: p.y), at: p, now: 1.005)
            default:
                _ = rt.keyUp(KeyEvent(key: .text("a"), mods: .none), at: 1.005)
            }
            #expect(rt.state.clickedWide, "\(kind): the handler ran")
            for i in 1...4 { _ = rt.frame(at: 1.0 + Double(i) / 60.0) }
            Self.expectSplit(rt, kind)
        }
    }

    @Test("a paste the frame delivers after its poll splits from it and keeps its motion (routed `Action::Paste`)")
    func framePollThenQueuedPasteSplits() throws {
        let rt = Self.runtime(motionNeedsCause: true)
        rt.state.pollDue = true
        rt.paste("x")
        for i in 1...4 { _ = rt.frame(at: 1.0 + Double(i) / 60.0) }
        #expect(rt.state.clickedWide, "the paste reached the window's handler")
        Self.expectSplit(rt, "frame poll + queued paste")
    }
}
