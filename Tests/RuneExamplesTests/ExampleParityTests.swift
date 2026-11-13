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
@testable import RuneSettings
@testable import RuneTodo

@Suite("Example Parity Tests (Phase 1)", .serialized)
@MainActor
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
    @Test("matched: enter zooms the picked tile from its grid cell")
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

    // Upstream: examples/knobs/src/main.rs:95 in_the_playground_arrows_pick_and_step_the_side_columns_knobs
    @Test("knobs: in the playground, arrows pick and step the side column's knobs")
    func knobsPlaygroundArrowsPickAndStepSideColumnKnobs() throws {
        let rt = RuneKnobsDemoApp.makeApp()
            .headlessRuntime(size: Vec2(820, 520), env: Env(systemDark: true, scale: 1.0))
        try rt.openPlayground(at: "card-knobs")

        func press(_ key: Key, shift: Bool = false) {
            _ = rt.keyDown(KeyEvent(key: key, mods: Mods(shift: shift)), at: 0.0)
            rt.frame(at: 1.0 / 60.0)
        }
        func knob(_ d: Knob) throws -> Float {
            let pg = try #require(rt.playgroundState(as: KnobsDemoState.self))
            return pg.knobs.get(d)
        }

        press(.arrowRight)
        press(.arrowRight)
        #expect(abs(try knob(radiusKnob) - 14.32) < 1e-4, "→ steps the first knob, the radius")
        press(.arrowDown)
        press(.arrowRight, shift: true)
        #expect(try knob(padKnob) == 34.0, "↓ picks the padding, and ⇧→ steps it ten")
        press(.arrowLeft)
        #expect(try knob(padKnob) == 33.0, "← steps back rather than leaving")
        #expect(rt.elements().contains(where: { ($0.key?.hasPrefix("playground-slot-") == true) && $0.focused }), "the keyboard is on the knobs")
        press(.escape)
        press(.arrowDown)
        #expect(try knob(padKnob) == 33.0, "after Esc, ↓ moves in the list again")
        #expect(rt.state.knobs.get(radiusKnob) == radiusKnob.default, "the real state is untouched")
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

    // Upstream: examples/settings/src/main.rs:46 cancelling_the_speed_slider_restores_its_value_before_a_track_press
    @Test("settings: cancelling the speed slider restores its value before a track press")
    func settingsCancellingSpeedSliderRestoresValue() {
        let rt = Runtime<SettingsState>(
            state: SettingsState(),
            viewport: Vec2(620, 520),
            pixelScale: 1.0,
            systemDark: true,
            view: settingsView
        )
        rt.frame(at: 0.0)
        let slider = center(of: rt.element(byKey: "slider")!)
        rt.pointerDown(at: Vec2(slider.x + 60.0, slider.y), at: 0.0)
        rt.pointerMove(to: Vec2(slider.x + 70.0, slider.y), at: 1.0 / 60.0)
        rt.frame(at: 1.0 / 60.0)
        #expect(rt.state.speed > 0.5)
        rt.keyDown(KeyEvent(key: .escape), at: 1.0 / 60.0)
        rt.frame(at: 2.0 / 60.0)
        #expect(rt.state.speed == 0.5)
        rt.pointerUp(at: Vec2(slider.x + 70.0, slider.y), at: 2.0 / 60.0)
        rt.frame(at: 2.0 / 60.0)
        #expect(rt.state.speed == 0.5)
    }

    @Test("settings: headless scenes and script replay cover all 7 scenes, toggles, accent, and speed")
    func settingsScenesAndScriptReplay() throws {
        let spec = RuneSettingsApp.makeSpec()
        for (sceneName, expectedText) in [
            ("default", "Launch at login"),
            ("light", "Appearance"),
            ("dark", "Appearance"),
            ("reduced-motion", "Reduce motion"),
            ("toggles-off", "Play sounds"),
            ("accent-pink", "Accent colour"),
            ("slow", "0.50×"),
        ] {
            let out = try HeadlessRunner.run(spec, args: ToolingArgs.parse(["--scene", sceneName]))
            let tree = String(decoding: out.treeJSON, as: UTF8.self)
            #expect(tree.contains(expectedText), "Missing \(expectedText) in settings scene \(sceneName)")
        }

        var scriptArgs = ToolingArgs()
        scriptArgs.scriptArg = """
        [
          {"t": 0.05, "type": "tap", "key": "Light"},
          {"t": 0.15, "type": "tap", "key": "green"},
          {"t": 0.25, "type": "tap", "key": "login"},
          {"t": 0.35, "type": "tap", "key": "sounds"},
          {"t": 0.45, "type": "drag", "key": "slider/knob", "dx": 40, "dy": 0, "dur": 0.2}
        ]
        """
        let scripted = try HeadlessRunner.run(spec, args: scriptArgs)
        let scriptedTree = String(decoding: scripted.treeJSON, as: UTF8.self)
        #expect(!scriptedTree.contains("1.00×"))
    }
}
