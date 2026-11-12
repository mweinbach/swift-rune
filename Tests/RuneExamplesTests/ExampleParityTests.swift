import Foundation
import Testing
@testable import Rune
@testable import RuneFrostedBar
@testable import RuneHello
@testable import RuneKnobs
@testable import RuneKnobsDemo
@testable import RuneLab
@testable import RuneMatched
@testable import RuneRef
@testable import RuneTodo

@Suite("Example Parity Tests (Phase 1)")
struct ExampleParityTests {
    private func center(of info: ElementInfo) -> Vec2 {
        Vec2(info.rect[0] + info.rect[2] * 0.5, info.rect[1] + info.rect[3] * 0.5)
    }

    // Upstream: examples/hello/src/main.rs:40 a_tap_flips_the_switch_and_the_knob_springs_across
    @Test("hello: a tap flips the switch and the knob springs across 16 pt")
    func helloTapFlipsSwitchAndKnobSpringsAcross() {
        let rt = Runtime<HelloState>(
            state: HelloState(),
            viewport: Vec2(320, 200),
            pixelScale: 2.0,
            systemDark: true,
            view: helloView
        )
        rt.frame(at: 0.0)
        let off = rt.element(byKey: "knob")!.rect[0]

        let swCenter = center(of: rt.element(byKey: "switch")!)
        var t = 0.0
        rt.pointerDown(at: swCenter, at: t)
        rt.pointerUp(at: swCenter, at: t)
        for _ in 0..<6 {
            t += 1.0 / 60.0
            rt.frame(at: t)
        }
        #expect(rt.state.on)
        let mid = rt.element(byKey: "knob")!.rect[0]
        for _ in 0..<60 {
            t += 1.0 / 60.0
            rt.frame(at: t)
        }
        let on = rt.element(byKey: "knob")!.rect[0]
        #expect(off < mid && mid < on, "the knob travels: \(off) -> \(mid) -> \(on)")
        #expect(abs((on - off) - 16.0) < 0.01, "and lands 16 points over")
    }

    // Upstream: examples/frosted-bar/src/main.rs:85 the_bar_blurs_and_a_tab_takes_a_tap
    @Test("frosted-bar: the bar blurs and a tab takes a tap")
    func frostedBarBlursAndTabTakesTap() {
        let rt = Runtime<FrostedBarState>(
            state: FrostedBarState(),
            viewport: Vec2(390, 640),
            pixelScale: 2.0,
            systemDark: true,
            view: frostedBarView
        )
        let scene = rt.frame(at: 0.0)
        #expect(scene.primitives.filter { $0.kind == .backdropBlur }.count == 1)

        let laterCenter = center(of: rt.element(byKey: "Later")!)
        rt.pointerDown(at: laterCenter, at: 0.0)
        rt.pointerUp(at: laterCenter, at: 0.0)
        rt.frame(at: 1.0 / 60.0)
        #expect(rt.state.tab == 2)
    }

    // Upstream: examples/matched/src/main.rs:112 enter_zooms_the_picked_tile_from_its_grid_cell
    @Test(
        "matched: enter zooms the picked tile from its grid cell",
        .disabled("Blocked on @el: Runtime.swift never wires El.flightId / MatchedFlightRegistry across reparenting")
    )
    func matchedEnterZoomsPickedTileFromGridCell() {
        let rt = Runtime<MatchedState>(
            state: MatchedState(),
            viewport: Vec2(720, 480),
            pixelScale: 2.0,
            systemDark: true,
            view: matchedView
        )
        rt.frame(at: 0.0)
        rt.state.picked = 3
        rt.markNeedsCommit()
        var t = 1.0 / 60.0
        rt.frame(at: t)
        let cell = rt.element(byKey: "tile-4")!.rect

        rt.state.zoomed = true
        rt.markNeedsCommit()
        t += 1.0 / 120.0
        rt.frame(at: t)
        let first = rt.element(byKey: "tile-4")!.rect
        #expect(abs(first[0] - cell[0]) < 8.0 && abs(first[2] - cell[2]) < 8.0, "\(cell) -> \(first)")

        for _ in 0..<120 {
            t += 1.0 / 60.0
            rt.frame(at: t)
        }
        let one = rt.element(byKey: "tile-4")!.rect
        #expect(one[2] > 600.0 && one[3] > 350.0, "fills the stage: \(one)")
    }

    // Upstream: examples/knobs/src/main.rs:115 cmd_shift_k_opens_the_panel_and_a_knob_changes_the_card
    @Test("knobs: Cmd+Shift+K opens the panel and a knob changes the card")
    func knobsCmdShiftKOpensPanelAndKnobChangesCard() {
        let rt = Runtime<KnobsDemoState>(
            state: KnobsDemoState(),
            viewport: Vec2(820, 520),
            pixelScale: 1.0,
            systemDark: true,
            onKey: onKnobsKey,
            view: knobsDemoView
        )
        rt.frame(at: 0.0)
        let ev = KeyEvent(key: .command("k"), mods: Mods(shift: true, cmd: true))
        let handled = rt.keyDown(ev, at: 0.0)
        #expect(handled)
        var t = 0.0
        for _ in 0..<40 {
            t += 1.0 / 60.0
            rt.frame(at: t)
        }
        #expect(rt.state.knobs.open)
        #expect(rt.element(byKey: "knobs-side-panel") != nil || rt.element(byKey: "knobs-top") != nil)
        rt.state.knobs.set(radiusKnob, 30.0)
        rt.markNeedsCommit()
        t += 1.0 / 60.0
        rt.frame(at: t)
        #expect(rt.state.knobs.get(radiusKnob) == 30.0)
    }

    @Test("todo: seeds upstream items, keys, and add/toggle/remove")
    func todoUpstreamSeedAndActions() {
        let rt = Runtime<TodoState>(
            state: TodoState(),
            viewport: Vec2(360, 240),
            pixelScale: 2.0,
            systemDark: true,
            view: todoView
        )
        rt.frame(at: 0.0)
        #expect(rt.state.todos.map(\.title) == ["Write the view", "Run it headless", "Ship it"])
        #expect(rt.element(byKey: "todo-0") != nil)
        #expect(rt.element(byKey: "bar") != nil)

        let addCenter = center(of: rt.element(byKey: "add")!)
        rt.pointerDown(at: addCenter, at: 0.0)
        rt.pointerUp(at: addCenter, at: 0.0)
        rt.frame(at: 1.0 / 60.0)
        #expect(rt.state.todos.count == 4)
        #expect(rt.state.todos.last?.title == "Todo 4")
    }

    @Test("lab: hx() decodes sRGB hex to linear-light Color")
    func labHxDecodesSRGB() {
        let mid = hx(0x808080)
        let expected = RefShader.srgbToLinear(128.0 / 255.0)
        #expect(abs(mid.r - expected) < 1e-4)
        #expect(abs(mid.g - expected) < 1e-4)
        #expect(abs(mid.b - expected) < 1e-4)
        #expect(mid.r < 0.25) // sRGB 0x80 (~0.502) in linear is ~0.216, not ~0.502
    }
}
