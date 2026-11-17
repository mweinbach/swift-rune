import Testing
@testable import Rune

// Upstream: crates/rune/tests/help_tooltip.rs
//
// `El.help` tooltips where Rune draws them: the pointer resting on an element for
// `helpDelay` shows its tooltip under it; a press, scroll or key hides it until the pointer
// leaves; leaving hides it; it follows its element; and it takes no hover or press.
@Suite("help_tooltip.rs parity")
@MainActor
struct HelpTooltipParityTests {
    struct S {
        var presses: UInt32 = 0
        var hovered = false
        var inset: Float = 0
    }

    /// `help_tooltip.rs::view`.
    nonisolated static func view(_ s: S, _: inout Cx<S>) -> El<S> {
        col().wFull().hFull().p(20.0).gap(10.0)
            .child(
                row().pl(s.inset)
                    .child(
                        el().key("copy").size(28.0, 28.0)
                            .help("Copy the command")
                            .onClick { (s: inout S) in s.presses += 1 }
                            .onHoverChange { s, on, _ in s.hovered = on }
                    )
            )
            .child(el().key("plain").size(100.0, 28.0))
            // Help at the window's bottom edge flips its tooltip above it.
            .child(el().wFull().grow(1.0))
            .child(el().key("low").size(60.0, 24.0).help("Near the bottom"))
    }

    /// Rust's `Runtime::frame(dt)` advances a clock; Swift's `frame(at:)` takes absolute time,
    /// so the harness carries the clock and feeds input at the current instant.
    final class Harness {
        let rt: Runtime<S>
        var t: Double = 0.0

        init(inset: Float = 0.0) {
            // `Env::new(true, 2.0)`: system dark, scale 2.
            rt = Runtime<S>(state: S(inset: inset), viewport: Vec2(400.0, 300.0), pixelScale: 2.0, systemDark: true) { s, cx in
                HelpTooltipParityTests.view(s, &cx)
            }
            rt.frame(at: 0.0)
        }

        func frame(_ dt: Double) {
            t += dt
            rt.frame(at: t)
        }

        func find(_ key: String) -> ElementInfo {
            guard let e = rt.elements().first(where: { $0.key == key }) else {
                Issue.record("no element \(key)")
                return rt.elements()[0]
            }
            return e
        }

        func centre(_ key: String) -> Vec2 {
            let e = find(key)
            return Vec2(e.rect[0] + e.rect[2] / 2.0, e.rect[1] + e.rect[3] / 2.0)
        }

        func hover(_ key: String) {
            rt.pointerMove(to: centre(key), at: t)
            frame(1.0 / 60.0)
        }

        var tip: String? { rt.helpTooltip()?.text }
    }

    // help_tooltip.rs:43
    @Test("shows_after_the_delay_and_hides_on_exit")
    func showsAfterTheDelayAndHidesOnExit() throws {
        let h = Harness()
        let rt = h.rt
        #expect(h.find("copy").help == "Copy the command", "tools read the help text")
        h.hover("copy")
        #expect(rt.state.hovered, "the element keeps its own hover")
        h.frame(rt.helpDelay - 0.1)
        #expect(h.tip == nil, "not before the delay")
        h.frame(0.15)
        #expect(h.tip == "Copy the command")

        // Under the element, centred on it, inside the window.
        let r = try #require(rt.helpTooltip()).rect
        let e = h.find("copy")
        #expect(r[1] >= e.rect[1] + e.rect[3], "below: \(r) \(e.rect)")
        #expect(r[0] >= 4.0 && r[0] + r[2] <= 396.0, "\(r)")
        #expect(abs((r[0] + r[2] / 2.0) - (e.rect[0] + e.rect[2] / 2.0)) < 1.0 || r[0] == 4.0, "centred: \(r)")

        // Moving within the element keeps it; leaving hides it.
        rt.pointerMove(to: Vec2(e.rect[0] + 3.0, e.rect[1] + 3.0), at: h.t)
        h.frame(1.0 / 60.0)
        #expect(h.tip != nil)
        h.hover("plain")
        #expect(h.tip == nil)
        h.frame(1.0)
        #expect(h.tip == nil, "no help on plain")

        // Leaving the window hides it too, and coming back waits the delay again.
        h.hover("copy")
        h.frame(1.0)
        #expect(h.tip != nil)
        rt.pointerLeave(at: h.t)
        h.frame(1.0 / 60.0)
        #expect(h.tip == nil)
        h.hover("copy")
        #expect(h.tip == nil)

        // The tree reports it.
        h.frame(1.0)
        let tree = rt.elements()
        #expect(tree.contains { $0.help != nil })
    }

    // help_tooltip.rs:86
    @Test("press_scroll_and_key_hide_it_until_the_pointer_leaves")
    func pressScrollAndKeyHideItUntilThePointerLeaves() {
        let h = Harness()
        let rt = h.rt
        for hide in 0..<3 {
            h.hover("copy")
            h.frame(1.0)
            #expect(h.tip != nil, "shown (\(hide))")
            let p = h.centre("copy")
            switch hide {
            case 0:
                rt.pointerDown(at: p, at: h.t)
                rt.pointerUp(at: p, at: h.t)
            case 1:
                // `rt.wheel(x, y, 10.0)`: a vertical delta of 10 at the pointer.
                rt.wheel(WheelEvent(dx: 0.0, dy: 10.0, x: p.x, y: p.y), at: p, now: h.t)
            default:
                _ = rt.keyDown(KeyEvent(key: .escape, mods: .none), at: h.t)
            }
            h.frame(1.0 / 60.0)
            #expect(h.tip == nil, "hidden (\(hide))")
            h.frame(2.0)
            #expect(h.tip == nil, "stays hidden while the pointer rests (\(hide))")
            h.hover("plain")
        }
        #expect(rt.state.presses == 1, "the press went to the element, not the tooltip")
        h.hover("copy")
        h.frame(1.0)
        #expect(h.tip != nil, "back after leaving")
    }

    // Upstream 38e3535b (#1013): `press_help` is gone. Every press dismisses the tooltip, a press
    // on the open tooltip's own trigger too, whether Rune draws it with its default look or a
    // `HelpLook` the view set (the case `press_help` used to keep it open for).
    @Test("a press on the open tooltip's own trigger dismisses it, with a view HelpLook too")
    func pressOnOwnTriggerDismissesWithCustomLook() {
        let rt = Runtime<S>(state: S(), viewport: Vec2(400.0, 300.0), pixelScale: 2.0, systemDark: true) { s, cx in
            cx.setHelpLook(HelpLook.system(dark: true))
            return HelpTooltipParityTests.view(s, &cx)
        }
        var t = 0.0
        rt.frame(at: t)
        let e = rt.elements().first { $0.key == "copy" }!
        let p = Vec2(e.rect[0] + e.rect[2] / 2.0, e.rect[1] + e.rect[3] / 2.0)
        rt.pointerMove(to: p, at: t)
        t += 1.0 / 60.0; rt.frame(at: t)
        t += 1.0; rt.frame(at: t)
        #expect(rt.helpTooltip()?.text == "Copy the command", "shown")
        rt.pointerDown(at: p, at: t)
        rt.pointerUp(at: p, at: t)
        t += 1.0 / 60.0; rt.frame(at: t)
        #expect(rt.helpTooltip() == nil, "the trigger's own press dismisses it")
        t += 2.0; rt.frame(at: t)
        #expect(rt.helpTooltip() == nil, "stays hidden while the pointer rests on the trigger")
        #expect(rt.state.presses == 1, "the press went to the trigger")
    }

    // help_tooltip.rs:111
    @Test("follows_its_element_and_flips_above_at_the_bottom")
    func followsItsElementAndFlipsAboveAtTheBottom() throws {
        let h = Harness()
        let rt = h.rt
        h.hover("copy")
        h.frame(1.0)
        let x0 = try #require(rt.helpTooltip()).rect[0]
        // The element moves a little under the resting pointer: the tooltip goes with it.
        rt.state.inset = 6.0
        rt.invalidate(at: h.t)
        h.frame(1.0 / 60.0)
        let r = try #require(rt.helpTooltip(), "still shown").rect
        #expect(abs(r[0] - (x0 + 6.0)) < 1.0 || x0 == 4.0, "\(x0) -> \(r)")

        h.hover("low")
        h.frame(1.0)
        let shown = try #require(rt.helpTooltip())
        let e = h.find("low")
        #expect(shown.text == "Near the bottom")
        #expect(shown.rect[1] + shown.rect[3] <= e.rect[1], "above: \(shown.rect) \(e.rect)")
    }

    // Supplement to help_tooltip.rs:111: in the upstream view the tip for "copy" is wider than
    // twice the element's left offset, so it clamps to the window margin (x0 == 4) and the
    // follow assertion takes its `|| x0 == 4.0` escape. Start the row further in so the tip is
    // centred unclamped, and check it really follows (`update_help` re-anchors on the live
    // element's drawn box every frame).
    @Test("follows its element when not clamped to the window margin")
    func followsItsElementUnclamped() throws {
        let h = Harness(inset: 150)
        let rt = h.rt
        h.hover("copy")
        h.frame(1.0)
        let r0 = try #require(rt.helpTooltip()).rect
        let e0 = h.find("copy")
        #expect(r0[0] > 4.0, "unclamped: \(r0)")
        #expect(abs((r0[0] + r0[2] / 2.0) - (e0.rect[0] + e0.rect[2] / 2.0)) < 1.0, "centred: \(r0) \(e0.rect)")

        rt.state.inset = 156.0
        rt.invalidate(at: h.t)
        for _ in 0..<4 { h.frame(1.0 / 60.0) }
        let moving = try #require(rt.helpTooltip(), "shown during the move").rect
        let dx = h.find("copy").rect[0] - e0.rect[0]
        #expect(dx > 0 && dx < 6)
        #expect(abs((moving[0] - r0[0]) - dx) < 1.0, "the tooltip tracks the drawn element")

        h.frame(1.0)
        let landed = try #require(rt.helpTooltip(), "shown after landing").rect
        #expect(abs(h.find("copy").rect[0] - (e0.rect[0] + 6.0)) < 0.01)
        #expect(abs(landed[0] - (r0[0] + 6.0)) < 1.0)
        #expect(landed[1] == r0[1] && landed[2] == r0[2] && landed[3] == r0[3])
    }
}
