import Foundation
import Testing
import Rune
import RuneMotion
@testable import RuneKnobs

@Suite("RuneKnobs Tests")
struct RuneKnobsTests {
    struct TestAppState {
        var knobs = Knobs()
        var filterEdit = TextEdit()
    }

    @Test func typedDescriptorsAndClamping() {
        let f = Knob.float("rim", min: 0, max: 4, default: 1.5, step: 0.5).label("Rim width").about("Outer border width")
        let i = Knob.int("count", min: 1, max: 10, default: 3)
        let b = Knob.bool("glow", default: true)
        let c = Knob.color("tint", default: Color(r: 0.2, g: 0.4, b: 0.8, a: 1.0))
        let t = Knob.text("title", default: "Hello")
        let s = Knob.select("mode", options: ["Tree", "On screen", "Tabs"], default: 0)
            .hints(["Foldable hierarchy", "Visible first", "Tabbed pages"])
        let v = Knob.vec2("offset", default: Vec2(10, 20))
        let sp = Knob.spring("bounce", default: Spring(duration: 0.35, bounce: 0.2))

        var knobs = Knobs()
        #expect(knobs.get(f) == 1.5)
        knobs.set(f, 2.3)
        #expect(knobs.get(f) == 2.5)
        knobs.set(f, 99.0)
        #expect(knobs.get(f) == 4.0)

        #expect(knobs.getInt(i) == 3)
        knobs.setInt(i, 42)
        #expect(knobs.getInt(i) == 10)

        #expect(knobs.getBool(b) == true)
        knobs.setBool(b, false)
        #expect(knobs.getBool(b) == false)

        #expect(knobs.getColor(c) == Color(r: 0.2, g: 0.4, b: 0.8, a: 1.0))
        let nextColor = Color(r: 1.0, g: 0.0, b: 0.5, a: 1.0)
        knobs.setColor(c, nextColor)
        #expect(knobs.getColor(c) == nextColor)

        #expect(knobs.getText(t) == "Hello")
        knobs.setText(t, "Updated")
        #expect(knobs.getText(t) == "Updated")

        #expect(s.hint(at: 1) == "Visible first")
        knobs.set(s, 2)
        #expect(knobs.getInt(s) == 2)

        #expect(knobs.getVec2(v) == Vec2(10, 20))
        knobs.setVec2(v, Vec2(4, 8))
        #expect(knobs.getVec2(v) == Vec2(4, 8))

        #expect(knobs.getSpring(sp) == Spring(duration: 0.35, bounce: 0.2))
        knobs.setSpring(sp, Spring(duration: 0.5, bounce: 0.1))
        #expect(knobs.getSpring(sp) == Spring(duration: 0.5, bounce: 0.1))
    }

    @Test func undoRedoKeepRevertAndReset() {
        let k1 = Knob.float("alpha", min: 0, max: 1, default: 0.5)
        let k2 = Knob.float("radius", min: 0, max: 20, default: 8)
        let group = KnobGroup("Card", region: "card", knobs: [k1, k2])

        var knobs = Knobs()
        knobs.change(k1, 0.8)
        knobs.change(k2, 12)
        #expect(knobs.canUndo)
        #expect(knobs.get(k1) == 0.8)
        #expect(knobs.get(k2) == 12)

        let didUndo = knobs.undo()
        #expect(didUndo)
        #expect(knobs.get(k2) == 8)
        #expect(knobs.canRedo)
        let didRedo = knobs.redo()
        #expect(didRedo)
        #expect(knobs.get(k2) == 12)

        knobs.keep()
        #expect(!knobs.differs(k1))
        knobs.change(k1, 0.2)
        #expect(knobs.differs(k1))
        knobs.revert([k1, k2])
        #expect(knobs.get(k1) == 0.8)

        knobs.reset(group)
        #expect(knobs.get(k1) == 0.5)
        #expect(knobs.get(k2) == 8)
    }

    @Test func presetsSaveDeleteAndCodeExport() {
        let k1 = Knob.float("pad", min: 0, max: 32, default: 10)
        let k2 = Knob.choice("align", labels: ["Left", "Center", "Right"], default: 0)
        let compact = KnobPreset("Compact", values: ["pad": 4, "align": 1])
        let group = KnobGroup("Box", region: "box", knobs: [k1, k2], presets: [compact])

        var knobs = Knobs()
        knobs.apply(group, name: "Compact")
        #expect(knobs.get(k1) == 4)
        #expect(knobs.getInt(k2) == 1)
        #expect(knobs.activePreset(group) == "Compact")
        #expect(!knobs.drifted(group, name: "Compact"))

        knobs.change(k1, 6)
        #expect(knobs.drifted(group, name: "Compact"))

        let savedName = knobs.savePreset(group)
        #expect(savedName == "Saved 1")
        #expect(knobs.activePreset(group) == "Saved 1")

        let code = knobs.code(group)
        #expect(code.contains("pad = 6"))
        #expect(code.contains("align = 1 (Center)"))

        knobs.deletePreset(group, name: savedName)
        #expect(knobs.saved[group.name]?.isEmpty == true)
    }

    @Test func shortcutCmdShiftKAndEscapeToggle() {
        var knobs = Knobs()
        #expect(!knobs.open)

        let cmdShiftK = KeyEvent(key: .command("k"), mods: Mods(shift: true, cmd: true))
        #expect(RuneKnobs.key(&knobs, event: cmdShiftK))
        #expect(knobs.open)

        let esc = KeyEvent(key: .escape)
        #expect(RuneKnobs.key(&knobs, event: esc))
        #expect(!knobs.open)

        // Escape when already closed is not consumed.
        #expect(!RuneKnobs.key(&knobs, event: esc))

        // Text-based Cmd+Shift+K also toggles.
        let textCmdShiftK = KeyEvent(key: .text("K"), mods: Mods(shift: true, cmd: true))
        #expect(RuneKnobs.key(&knobs, event: textCmdShiftK))
        #expect(knobs.open)
    }

    @Test func hierarchicalTreePlanAndSearchFilter() {
        let g1 = KnobGroup("Header", region: "hdr", knobs: [
            Knob.float("Header height", min: 20, max: 100, default: 44),
            Knob.float("Blur", min: 0, max: 30, default: 12),
        ]).under("Home")
        let g2 = KnobGroup("Footer", region: "ftr", knobs: [
            Knob.float("Footer height", min: 20, max: 100, default: 32),
        ]).under("Home")
        let g3 = KnobGroup("Settings", region: "cfg", knobs: [
            Knob.bool("Dark mode", default: true),
        ])

        var knobs = Knobs()
        let treePlan = KnobTree.plan(knobs: knobs, groups: [g1, g2, g3], seen: [0])
        #expect(treePlan.sections.count == 2)
        if case .page(let name) = treePlan.sections[0].head {
            #expect(name == "Home")
        } else {
            Issue.record("Expected Home page section")
        }

        // Filter by "height" matches Header height and Footer height, not Blur or Dark mode.
        knobs.setQuery("height")
        let filteredPlan = KnobTree.plan(knobs: knobs, groups: [g1, g2, g3])
        #expect(filteredPlan.sections.count == 1)
        #expect(filteredPlan.sections[0].subs.count == 2)
        #expect(filteredPlan.sections[0].subs[0].knobs == [0])
        #expect(filteredPlan.sections[0].subs[1].knobs == [0])

        // Tabs layout
        knobs.setQuery("")
        knobs.set(RuneKnobsDefaults.layout, 2)
        let tabsPlan = KnobTree.plan(knobs: knobs, groups: [g1, g2, g3], seen: [2])
        #expect(tabsPlan.tabs.map(\.0) == ["Home", "Settings"])
        #expect(tabsPlan.tab == "Settings")
    }

    @Test func jsonSnapshotExportImportAndFilePersistence() throws {
        let kFloat = Knob.float("exposure", min: -2, max: 2, default: 0)
        let kColor = Knob.color("accent", default: .white)
        let kSpring = Knob.spring("spring", default: Spring(duration: 0.3, bounce: 0.0))

        var original = Knobs()
        original.width = 410
        original.set(kFloat, 1.25)
        original.setColor(kColor, Color(r: 0.1, g: 0.6, b: 0.9, a: 1.0))
        original.setSpring(kSpring, Spring(duration: 0.45, bounce: 0.15))

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-knobs-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try original.save(to: tmpURL)

        var restored = Knobs()
        try restored.load(from: tmpURL)

        #expect(restored.get(kFloat) == 1.25)
        #expect(restored.getColor(kColor) == Color(r: 0.1, g: 0.6, b: 0.9, a: 1.0))
        #expect(restored.getSpring(kSpring) == Spring(duration: 0.45, bounce: 0.15))
        #expect(restored.width == 410)
    }

    @Test func threadSafeRegistryAndReactiveHandle() async {
        let registry = KnobRegistry()
        let speed = Knob.float("speed", min: 0, max: 10, default: 1)
        let handle = registry.handle(speed)

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Float] = []

            func append(_ v: Float) {
                lock.withLock { values.append(v) }
            }

            func count() -> Int {
                lock.withLock { values.count }
            }
        }
        let observed = Box()
        let token = handle.onChange { val in
            if let f = val.floatValue {
                observed.append(f)
            }
        }

        handle.floatValue = 4.5
        #expect(handle.floatValue == 4.5)

        await withTaskGroup(of: Void.self) { group in
            for idx in 1...20 {
                group.addTask {
                    handle.floatValue = Float(idx) * 0.25
                    _ = handle.floatValue
                }
            }
        }

        registry.removeObserver(speed.name, id: token)
        #expect(observed.count() == 21)

        handle.reset()
        #expect(handle.floatValue == 1.0)
    }

    @Test func overlayAndSidePanelElBuilders() {
        let k1 = Knob.float("gap", min: 0, max: 24, default: 8)
        let k2 = Knob.bool("dense", default: false)
        let k3 = Knob.color("bg", default: .black)
        let groups = [KnobGroup("Layout", region: "root", knobs: [k1, k2, k3])]

        var state = TestAppState()
        let closedLayer: El<TestAppState> = RuneKnobs.layer(
            knobs: state.knobs,
            groups: groups,
            style: .dark(),
            keyPath: \.knobs
        )
        #expect(closedLayer.keyId == "knobs-layer")
        #expect(closedLayer.children.isEmpty)

        state.knobs.show()
        let openLayer: El<TestAppState> = RuneKnobs.layer(
            knobs: state.knobs,
            groups: groups,
            style: .light(),
            keyPath: \.knobs
        )
        #expect(openLayer.children.count == 1)
        #expect(openLayer.children[0].keyId == "knobs-floating-panel")

        let sideShell: El<TestAppState> = RuneKnobs.side(
            page: el().key("app-page"),
            knobs: state.knobs,
            groups: groups,
            style: .dark(),
            seen: [0],
            keyPath: \.knobs,
            filterEditKeyPath: \.filterEdit
        )
        #expect(sideShell.keyId == "knobs-side-shell")
        #expect(sideShell.children.count == 2)
    }

    @Test func randomStaysInRangeOnStepsAndSeedsFromClock() {
        let kA = Knob.float("a", min: 0, max: 10, default: 2, step: 0.5)
        let kB = Knob.float("b", min: -5, max: 5, default: 0, step: 0.25)
        let g = KnobGroup("G", region: "g", knobs: [kA, kB])

        var knobs = Knobs()
        for _ in 0..<200 {
            knobs.random(g)
            let va = knobs.get(kA)
            let vb = knobs.get(kB)
            #expect(va >= 0 && va <= 10)
            #expect(vb >= -5 && vb <= 5)
            #expect(abs((va / 0.5) - (va / 0.5).rounded()) < 1e-4)
            #expect(abs((vb / 0.25) - (vb / 0.25).rounded()) < 1e-4)
        }
        let didUndo = knobs.undo()
        #expect(didUndo)
        #expect(knobs.canUndo)

        // Seed is initialized from the clock on first random(), so two instances separated in time can differ.
        var k1 = Knobs()
        k1.random(g)
        let v1 = k1.get(kA)
        var differed = false
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.0005)
            var k2 = Knobs()
            k2.random(g)
            if abs(k2.get(kA) - v1) > 1e-5 {
                differed = true
                break
            }
        }
        #expect(differed)
    }

    @Test func sideKeyLeavesEscapeAndTabAndSettlesTx() {
        let g1 = KnobGroup("Left", region: "left", knobs: [Knob.float("l", min: 0, max: 10, default: 5, step: 0.5)])
        let g2 = KnobGroup("Right", region: "right", knobs: [Knob.float("r", min: 0, max: 10, default: 2, step: 1)])
        let groups = [g1, g2]

        var state = TestAppState()
        state.knobs.show()
        let handler = RuneKnobs.sideKey(groups: groups, keyPath: \TestAppState.knobs)

        var txEsc = Tx()
        #expect(!handler(&state, KeyEvent(key: .escape), &txEsc))
        #expect(state.knobs.open)
        #expect(!txEsc.settleRequested)

        var txTab = Tx()
        #expect(!handler(&state, KeyEvent(key: .tab), &txTab))
        #expect(!txTab.settleRequested)

        var txStep = Tx()
        #expect(handler(&state, KeyEvent(key: .arrowRight), &txStep))
        #expect(abs(state.knobs.get(g1.knobs[0]) - 5.5) < 1e-5)
        #expect(txStep.settleRequested)

        var txSwitch = Tx()
        #expect(handler(&state, KeyEvent(key: .text("]")), &txSwitch))
        #expect(state.knobs.current(in: groups)?.name == "Right")
        #expect(txSwitch.settleRequested)
    }

    @Test func treePlanModesKeyWalkingAndFiltering() {
        let l = Knob.float("left_pad", min: 0, max: 20, default: 4, step: 1).about("Left inner margin")
        let r = Knob.float("right_pad", min: 0, max: 20, default: 8, step: 1)
        let mode = Knob.choice("mode", labels: ["Flat", "Glow", "Glass"], default: 0)
        let groups = [
            KnobGroup("Left", region: "left", knobs: [l, mode]).under("Layout"),
            KnobGroup("Right", region: "right", knobs: [r]).under("Effects"),
        ]

        var knobs = Knobs()
        knobs.show()
        knobs.setFolded("Layout", false)
        knobs.setFolded("Left", false)
        let treePlan = KnobTree.plan(knobs: knobs, groups: groups)
        let treeRows = KnobTree.rows(in: treePlan)
        #expect(treeRows.contains(.page("Layout")))
        #expect(treeRows.contains(.group(0)))

        // Stepping down walks into knobs and arrowRight steps the knob or choice.
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .arrowDown)))
        #expect(knobs.treeAt == .group(0))
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .arrowDown)))
        #expect(knobs.treeAt == .knob(groupIndex: 0, knobIndex: 0))
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .arrowRight)))
        #expect(knobs.get(l) == 5)

        // ArrowLeft on a group header folds it; arrowRight unfolds it.
        knobs.treeAt = .group(0)
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .arrowLeft)))
        #expect(knobs.folded.contains("Left"))
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .arrowRight)))
        #expect(!knobs.folded.contains("Left"))

        // '/' starts filter, Esc stops editing while preserving query, second Esc clears, third Esc closes.
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .text("/"))))
        #expect(knobs.filtering)
        knobs.setQuery("margin")
        let filtered = KnobTree.plan(knobs: knobs, groups: groups)
        #expect(filtered.sections.count == 1)
        #expect(filtered.sections[0].subs[0].knobs == [0])

        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .escape)))
        #expect(!knobs.filtering && knobs.query == "margin")
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .escape)))
        #expect(knobs.query.isEmpty && knobs.open)
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .escape)))
        #expect(!knobs.open)

        // On-screen mode highlights seen region groups first; tabs mode follows selected tab.
        knobs.show()
        knobs.set(RuneKnobsDefaults.layout, 1)
        let onScreen = KnobTree.plan(knobs: knobs, groups: groups, seen: [1])
        #expect(onScreen.sections.first?.subs.first?.groupIndex == 1)
        knobs.set(RuneKnobsDefaults.layout, 2)
        knobs.tab = "Effects"
        let tabbed = KnobTree.plan(knobs: knobs, groups: groups)
        #expect(tabbed.sections.count == 1 && tabbed.sections[0].subs[0].groupIndex == 1)
    }

    @Test func runtimePanelInteractionsAndInlineSizing() {
        let l = Knob.float("rim", min: 0, max: 10, default: 5, step: 0.1)
        let wide = Knob.float("A rather long slider label here", min: 0, max: 100, default: 50, step: 1)
        let many = Knob.choice("Corner style", labels: ["Sharp", "Soft", "Round", "Pill", "Squircle"], default: 0)
        let groups = [
            KnobGroup("Left", region: "left", knobs: [l, wide, many]),
            KnobGroup("Inner", region: "inner", knobs: [Knob.float("inner_pad", min: 0, max: 20, default: 4, step: 1)]),
        ]

        var initial = TestAppState()
        initial.knobs.show()
        let rt = Runtime<TestAppState>(
            state: initial,
            viewport: Vec2(1000, 700),
            pixelScale: 1.0
        ) { state, _ in
            col()
                .key("root")
                .wFull()
                .hFull()
                .child(RuneKnobs.layer(knobs: state.knobs, groups: groups, style: .dark(), keyPath: \TestAppState.knobs))
        }
        for i in 0..<4 {
            _ = rt.frame(at: Double(i) / 60.0)
        }

        if let panel = rt.element(byKey: "knobs-floating-panel") {
            let center = Vec2(panel.rect[0] + panel.rect[2] * 0.5, panel.rect[1] + panel.rect[3] * 0.5)
            rt.pointerMove(to: center, at: 0.1)
            rt.pointerDown(at: center, at: 0.1)
            rt.pointerUp(at: center, at: 0.11)
            _ = rt.frame(at: 0.12)
        }

        // Inline layout stays within a narrow column and wide tracks grow.
        struct InlineState {
            var knobs = Knobs()
            var width: Float
        }
        func renderInline(_ width: Float) -> [ElementInfo] {
            let inlineRt = Runtime<InlineState>(
                state: InlineState(width: width),
                viewport: Vec2(400, 700),
                pixelScale: 1.0
            ) { s, _ in
                El<InlineState>(direction: .row)
                    .wFull()
                    .hFull()
                    .child(
                        col().key("column").w(s.width).child(
                            RuneKnobs.inline(knobs: s.knobs, groups: groups, style: .dark(), showHeader: false, keyPath: \InlineState.knobs)
                        )
                    )
            }
            for i in 0..<4 {
                _ = inlineRt.frame(at: Double(i) / 60.0)
            }
            return inlineRt.elements()
        }

        for w in [Float(200), Float(240), Float(300)] {
            let els = renderInline(w)
            let panel = els.first(where: { $0.key == "knobs-panel" })
            #expect(panel != nil)
            if let p = panel {
                #expect(p.rect[0] >= -0.01 && p.rect[0] + p.rect[2] <= w + 0.01)
            }
        }
    }
}
