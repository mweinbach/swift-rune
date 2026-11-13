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
        var prevA = knobs.get(kA)
        var prevB = knobs.get(kB)
        for _ in 0..<200 {
            prevA = knobs.get(kA)
            prevB = knobs.get(kB)
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
        #expect(knobs.get(kA) == prevA && knobs.get(kB) == prevB)

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
        #expect(txEsc.commitKind == .animate)

        var txTab = Tx()
        #expect(!handler(&state, KeyEvent(key: .tab), &txTab))
        #expect(txTab.commitKind == .animate)

        var txStep = Tx()
        #expect(handler(&state, KeyEvent(key: .arrowRight), &txStep))
        #expect(abs(state.knobs.get(g1.knobs[0]) - 5.5) < 1e-5)
        #expect(txStep.commitKind == .instant)

        var txSwitch = Tx()
        #expect(handler(&state, KeyEvent(key: .text("]")), &txSwitch))
        #expect(state.knobs.current(in: groups)?.name == "Right")
        #expect(txSwitch.commitKind == .instant)
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

        // Stepping down walks page -> group -> knob and arrowRight steps the knob or choice (`tree.rs:364`).
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .arrowDown)))
        #expect(knobs.treeAt == .page("Layout"))
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .arrowDown)))
        #expect(knobs.treeAt == .group(0))
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .arrowDown)))
        #expect(knobs.treeAt == .knob(groupIndex: 0, knobIndex: 0))
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .arrowRight)))
        #expect(knobs.get(l) == 5)

        // ArrowLeft on a group header folds it; arrowRight unfolds it; Enter toggles fold; walk-in/walk-up & '['/']' tabs.
        knobs.treeAt = .group(0)
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .arrowLeft)))
        #expect(knobs.folded.contains("Left"))
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .arrowRight)))
        #expect(!knobs.folded.contains("Left"))
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .enter)))
        #expect(knobs.folded.contains("Left"))
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .enter)))
        #expect(!knobs.folded.contains("Left"))
        // ArrowRight on open group enters first knob; ArrowLeft on knob walks up to group.
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .arrowRight)))
        #expect(knobs.treeAt == .knob(groupIndex: 0, knobIndex: 0))
        // Note: on a scalar knob ArrowLeft steps down rather than leaving the knob; test on page -> group -> page or header.
        knobs.treeAt = .page("Layout")
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .arrowLeft)))
        #expect(knobs.folded.contains("Layout"))
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .arrowRight)))
        #expect(!knobs.folded.contains("Layout"))
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .arrowRight)))
        #expect(knobs.treeAt == .group(0))

        // '/' starts filter, Esc stops editing while preserving query, Backspace pops query char, second Esc clears, third Esc closes.
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .text("/"))))
        #expect(knobs.filtering)
        knobs.setQuery("margin")
        let filtered = KnobTree.plan(knobs: knobs, groups: groups)
        #expect(filtered.sections.count == 1)
        #expect(filtered.sections[0].subs[0].knobs == [0])

        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .escape)))
        #expect(!knobs.filtering && knobs.query == "margin")
        #expect(KnobTree.handleKey(&knobs, groups: groups, event: KeyEvent(key: .backspace)))
        #expect(knobs.query == "margi")
        knobs.setQuery("margin")
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

    @Test @MainActor func runtimePanelInteractionsAndInlineSizing() {
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

    @Test func treeReopenLastGroupTabsAndNumberKeyOptionPick() {
        let a = Knob.float("Header fade", min: 0, max: 10, default: 5).about("How tall the fade under the header is")
        let b = Knob.choice("Table look", labels: ["Lines", "Zebra"], default: 0)
        let c = Knob.float("Row gap", min: 0, max: 8, default: 2, step: 0.08)
        let d = Knob.float("Dock radius", min: 0, max: 24, default: 14)
        let groups = [
            KnobGroup("Header", region: "hdr", knobs: [a]).under("Item page"),
            KnobGroup("Tables", region: "table", knobs: [b]).under("Item page"),
            KnobGroup("Rows", region: "list", knobs: [c]).under("Sidebar"),
            KnobGroup("Dock", region: "dock", knobs: [d]),
        ]

        // Everything starts folded with seen dots onItem page + Dock.
        var k = Knobs()
        let p0 = KnobTree.plan(knobs: k, groups: groups, seen: [0, 3])
        #expect(p0.sections.count == 3)
        #expect(p0.sections[0].seen && !p0.sections[1].seen)
        #expect(KnobTree.rows(in: p0) == [.page("Item page"), .page("Sidebar"), .group(3)])

        // Explicit folds win.
        k.setFolded("Header", false)
        k.setFolded("Item page", true)
        k.setFolded("Sidebar", false)
        let p1 = KnobTree.plan(knobs: k, groups: groups, seen: [0, 3])
        #expect(p1.sections[0].subs[0].open && !p1.sections[0].open && p1.sections[1].open)

        // Reopening folds all except the group last left open.
        var k2 = Knobs()
        k2.show()
        k2.setFolded("Sidebar", false)
        k2.setFolded("Rows", false)
        k2.setFolded("Item page", false)
        k2.setFolded("Tables", false)
        k2.group = "Tables"
        k2.close()
        k2.show()
        let p2 = KnobTree.plan(knobs: k2, groups: groups)
        #expect(p2.sections[0].open && p2.sections[0].subs[1].open)
        #expect(!p2.sections[0].subs[0].open && !p2.sections[1].open)

        // Number keys pick choice options when tree cursor is on a choice knob, undoably.
        k2.treeAt = .knob(groupIndex: 1, knobIndex: 0)
        #expect(KnobTree.handleKey(&k2, groups: groups, event: KeyEvent(key: .text("2"))))
        #expect(k2.get(b) == 1)
        #expect(KnobTree.handleKey(&k2, groups: groups, event: KeyEvent(key: .text("3"))))
        #expect(k2.get(b) == 1)
        let didUndoChoice = k2.undo()
        #expect(didUndoChoice)
        #expect(k2.get(b) == 0)

        // Arrow navigation walks headers, opens folded groups, and steps knobs.
        var k3 = Knobs()
        k3.show()
        k3.treeAt = .page("Item page")
        #expect(KnobTree.handleKey(&k3, groups: groups, event: KeyEvent(key: .arrowRight)))
        #expect(k3.unfolded.contains("Item page"))
        #expect(KnobTree.handleKey(&k3, groups: groups, event: KeyEvent(key: .arrowLeft)))
        #expect(k3.folded.contains("Item page"))
        #expect(KnobTree.handleKey(&k3, groups: groups, event: KeyEvent(key: .arrowDown)))
        #expect(k3.treeAt == .page("Sidebar"))
    }

    @Test @MainActor func sidePanelRuntimePagePushFilterTypingAndFloatingTabClick() {
        let l = Knob.float("Left size", min: 0, max: 10, default: 5, step: 0.5)
        let c = Knob.choice("Style", labels: ["One", "Two", "Three"], default: 0).hints(["The first", "The second", ""])
        let r = Knob.float("Right pad", min: 0, max: 40, default: 20, step: 1)
        let g = Knob.float("Right gap", min: 0, max: 40, default: 10, step: 1)
        let groups = [
            KnobGroup("Left", region: "left", knobs: [l, c]),
            KnobGroup("Right", region: "right", knobs: [r, g]),
        ]

        let state = TestAppState()
        let rt = Runtime<TestAppState>(
            state: state,
            viewport: Vec2(1000, 700),
            pixelScale: 1.0
        ) { s, _ in
            let left: El<TestAppState> = col().key("left").w(300).hFull()
            let right: El<TestAppState> = col().key("right").grow(1).hFull()
            let page: El<TestAppState> = row().key("cols").wFull().hFull()
                .child(left)
                .child(right)
            return RuneKnobs.side(
                page: page,
                knobs: s.knobs,
                groups: groups,
                style: .dark(),
                seen: [0, 1],
                keyPath: \TestAppState.knobs,
                filterEditKeyPath: \TestAppState.filterEdit
            )
        }
        for i in 0..<10 { _ = rt.frame(at: Double(i) / 60.0) }
        let closedW = rt.element(byKey: "cols")?.rect[2] ?? 0
        #expect(abs(closedW - 1000) < 1.0)

        rt.state.knobs.show()
        rt.markNeedsCommit()
        for i in 10..<55 { _ = rt.frame(at: Double(i) / 60.0) }
        #expect(rt.element(byKey: "knobs-side-panel") != nil)
        let openColsW = rt.element(byKey: "cols")?.rect[2] ?? 1000
        #expect(openColsW < 1000 - 200)

        // Clicking a sub-header unfolds Right and expands its rows.
        let head = rt.element(byKey: "knobs-sub-head-1")
        #expect(head != nil)
        if let head {
            let pt = Vec2(head.rect[0] + head.rect[2] * 0.5, head.rect[1] + head.rect[3] * 0.5)
            rt.pointerMove(to: pt, at: 1.0)
            rt.pointerDown(at: pt, at: 1.01)
            rt.pointerUp(at: pt, at: 1.02)
            for i in 0..<10 { _ = rt.frame(at: 1.05 + Double(i) / 60.0) }
            #expect(!rt.state.knobs.isFolded("Right", byDefault: true))
        }

        // Clicking filter pill starts filtering and focuses knobs-filter-input; typing narrows sections; Escape stops/clears/closes.
        let pill = rt.element(byKey: "knobs-filter-pill")
        #expect(pill != nil)
        if let pill {
            let pt = Vec2(pill.rect[0] + pill.rect[2] * 0.5, pill.rect[1] + pill.rect[3] * 0.5)
            rt.pointerMove(to: pt, at: 1.3)
            rt.pointerDown(at: pt, at: 1.31)
            rt.pointerUp(at: pt, at: 1.32)
            _ = rt.frame(at: 1.35)
            #expect(rt.state.knobs.filtering)
            #expect(rt.element(byKey: "knobs-filter-input") != nil)
            _ = rt.keyDown(KeyEvent(key: .text("pad")), at: 1.36)
            _ = rt.frame(at: 1.40)
            #expect(rt.state.knobs.query == "pad")
            #expect(rt.element(byKey: "knob-Left size") == nil)
            #expect(rt.element(byKey: "knob-Right pad") != nil)
            _ = rt.keyDown(KeyEvent(key: .escape), at: 1.41)
            _ = rt.frame(at: 1.45)
            #expect(!rt.state.knobs.filtering && rt.state.knobs.query == "pad")
            #expect(rt.element(byKey: "knobs-filter-pill") != nil)
        }

        // Edge drag resizes side panel within sideMin...sideMax and double-click resets width to 0 (default sideW).
        let edge = rt.element(byKey: "knobs-edge")
        #expect(edge != nil)
        if let edge {
            let ex = edge.rect[0] + edge.rect[2] * 0.5
            let ey = edge.rect[1] + edge.rect[3] * 0.5
            rt.pointerMove(to: Vec2(ex, ey), at: 1.50)
            rt.pointerDown(at: Vec2(ex, ey), at: 1.51)
            rt.pointerMove(to: Vec2(ex - 60, ey), at: 1.52)
            rt.pointerUp(at: Vec2(ex - 60, ey), at: 1.53)
            _ = rt.frame(at: 1.55)
            #expect(abs(rt.state.knobs.sideW() - (RuneKnobsDefaults.sideW + 60)) < 2.0)

            let edge2 = rt.element(byKey: "knobs-edge")!
            let e2x = edge2.rect[0] + edge2.rect[2] * 0.5
            let e2y = edge2.rect[1] + edge2.rect[3] * 0.5
            rt.pointerDown(at: Vec2(e2x, e2y), at: 1.60)
            rt.pointerUp(at: Vec2(e2x, e2y), at: 1.61)
            rt.pointerDown(at: Vec2(e2x, e2y), at: 1.62)
            rt.pointerUp(at: Vec2(e2x, e2y), at: 1.63)
            _ = rt.frame(at: 1.65)
            #expect(rt.state.knobs.width == 0 && rt.state.knobs.sideW() == RuneKnobsDefaults.sideW)
        }

        // Floating panel width is 300 (`view.rs:10`), tab clicks switch active group, and target pick highlights/selects region (`view.rs:48-65`).
        var layerState = TestAppState()
        layerState.knobs.show()
        let layerRt = Runtime<TestAppState>(
            state: layerState,
            viewport: Vec2(1000, 700),
            pixelScale: 1.0
        ) { s, _ in
            let root: El<TestAppState> = el().key("root").wFull().hFull()
                .child(el().key("left").absolute(x: 400, y: 40).size(300, 300))
                .child(el().key("right").absolute(x: 450, y: 80).size(120, 120))
            return root.child(
                RuneKnobs.layer(knobs: s.knobs, groups: groups, style: .dark(), keyPath: \TestAppState.knobs)
            )
        }
        for i in 0..<6 { _ = layerRt.frame(at: Double(i) / 60.0) }
        let floating = layerRt.element(byKey: "knobs-floating-panel")
        #expect(floating != nil)
        if let floating {
            #expect(abs(floating.rect[2] - 300) < 1.0)
        }
        let tab1 = layerRt.element(byKey: "knobs-group-tab-1")
        #expect(tab1 != nil)
        if let tab1 {
            let pt = Vec2(tab1.rect[0] + tab1.rect[2] * 0.5, tab1.rect[1] + tab1.rect[3] * 0.5)
            layerRt.pointerMove(to: pt, at: 0.2)
            layerRt.pointerDown(at: pt, at: 0.21)
            layerRt.pointerUp(at: pt, at: 0.22)
            _ = layerRt.frame(at: 0.25)
            #expect(layerRt.state.knobs.group == "Right")
        }
        // Enable picking -> hover overlapping smallest-area region ("Right") -> knobs-outline + knobs-tag appear -> click selects "Right".
        let targetBtn = layerRt.element(byKey: "knobs-btn-target")
        #expect(targetBtn != nil)
        if let targetBtn {
            let pt = Vec2(targetBtn.rect[0] + targetBtn.rect[2] * 0.5, targetBtn.rect[1] + targetBtn.rect[3] * 0.5)
            layerRt.pointerMove(to: pt, at: 0.3)
            layerRt.pointerDown(at: pt, at: 0.31)
            layerRt.pointerUp(at: pt, at: 0.32)
            _ = layerRt.frame(at: 0.35)
            #expect(layerRt.state.knobs.picking)
            #expect(layerRt.element(byKey: "knobs-pick") != nil)

            layerRt.pointerMove(to: Vec2(480, 110), at: 0.36)
            _ = layerRt.frame(at: 0.38)
            #expect(layerRt.state.knobs.hoverGroup == "Right")
            #expect(layerRt.element(byKey: "knobs-outline") != nil)
            #expect(layerRt.element(byKey: "knobs-tag") != nil)

            layerRt.pointerDown(at: Vec2(480, 110), at: 0.39)
            layerRt.pointerUp(at: Vec2(480, 110), at: 0.40)
            _ = layerRt.frame(at: 0.42)
            #expect(!layerRt.state.knobs.picking && layerRt.state.knobs.group == "Right")
        }
    }

    @Test @MainActor func choiceShapeResponsiveGridSliderTrackAndDisabledButtons() {
        // choices_fit_the_width (`side_tests.rs:122`)
        let few = Knob.choice("Edge", labels: ["Fade", "Line", "Tint"], default: 0)
        let six = Knob.choice("Question glyph", labels: ["Disc", "? disc", "? mark", "? square", "? ring", "Bang"], default: 0)
        let many = Knob.choice("Theme picker style", labels: ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"], default: 0)
        #expect(RuneKnobs.choiceShape(few, cardWidth: 316) == .inline)
        #expect(RuneKnobs.choiceShape(six, cardWidth: 316) == .grid(cols: 3))
        #expect(RuneKnobs.choiceShape(six, cardWidth: 600) == .inline)
        if case .long = RuneKnobs.choiceShape(many, cardWidth: 316) {
            #expect(true)
        } else {
            Issue.record("Expected .long choice shape for >10 options")
        }

        // undo_and_reset_are_disabled_until_there_is_something_to_undo (`view_tests.rs:127`)
        let l = Knob.float("Left size", min: 0, max: 10, default: 5, step: 0.5)
        let wide = Knob.float("A rather long slider label here", min: 0, max: 100, default: 50, step: 1)
        let pick = Knob.choice("Tint", labels: ["Plain", "Accent", "Raised"], default: 1)
        let corner = Knob.choice("Corner style", labels: ["Sharp", "Soft", "Round", "Pill", "Squircle"], default: 0)
        let groups = [KnobGroup("Card", region: "card", knobs: [l, wide, pick, corner])]

        var s0 = TestAppState()
        s0.knobs.show()
        #expect(!s0.knobs.canUndo && !s0.knobs.canReset(groups[0]))
        let rt = Runtime<TestAppState>(state: s0, viewport: Vec2(1000, 700), pixelScale: 1.0) { s, _ in
            col().key("root").wFull().hFull().child(
                RuneKnobs.layer(knobs: s.knobs, groups: groups, style: .dark(), keyPath: \TestAppState.knobs)
            )
        }
        for i in 0..<4 { _ = rt.frame(at: Double(i) / 60.0) }
        func clickKey(_ key: String, at t: Double) {
            let el = rt.element(byKey: key)!
            let pt = Vec2(el.rect[0] + el.rect[2] * 0.5, el.rect[1] + el.rect[3] * 0.5)
            rt.pointerMove(to: pt, at: t)
            rt.pointerDown(at: pt, at: t + 0.01)
            rt.pointerUp(at: pt, at: t + 0.02)
            _ = rt.frame(at: t + 0.04)
        }
        clickKey("knobs-btn-undo", at: 0.2)
        clickKey("knobs-btn-reset", at: 0.3)
        #expect(rt.state.knobs.values.isEmpty)
        clickKey("knobs-btn-random", at: 0.4)
        #expect(rt.state.knobs.canUndo && rt.state.knobs.canReset(groups[0]))
        clickKey("knobs-btn-reset", at: 0.5)
        #expect(!rt.state.knobs.canReset(groups[0]))

        // Inline column widths [200, 240, 300] (`view_tests.rs:197,220,241`)
        struct InlineState {
            var knobs = Knobs()
        }
        func inspectInline(_ w: Float) -> [ElementInfo] {
            let inlineRt = Runtime<InlineState>(state: InlineState(), viewport: Vec2(400, 700), pixelScale: 1.0) { s, _ in
                row().key("root").wFull().hFull().child(
                    col().key("column").w(w).child(
                        RuneKnobs.inline(knobs: s.knobs, groups: groups, style: .dark(), keyPath: \InlineState.knobs)
                    )
                )
            }
            for i in 0..<6 { _ = inlineRt.frame(at: Double(i) / 60.0) }
            return inlineRt.elements()
        }

        var lastTrackW: Float = 0
        for w in [Float(200), Float(240), Float(300)] {
            let els = inspectInline(w)
            let card = els.first(where: { $0.key == "knobs-card" })!
            #expect(card.rect[0] >= -0.01 && card.rect[0] + card.rect[2] <= w + 0.01)
            for e in els where e.path.contains("knobs-card") && e.key != nil {
                #expect(e.rect[0] >= card.rect[0] - 0.01 && e.rect[0] + e.rect[2] <= card.rect[0] + card.rect[2] + 0.01)
            }
            let track = els.first(where: { $0.key == "knob-Left size" })!
            #expect(track.rect[2] > 100.0 && track.rect[2] > lastTrackW)
            lastTrackW = track.rect[2]
            let fill = els.first(where: { $0.path.contains("knob-Left size") && $0.key == "fill" })!
            #expect(abs(fill.rect[2] - track.rect[2] * 0.5) < 0.6)
        }

        let wideEls = inspectInline(300)
        let narrowEls = inspectInline(200)
        let wideCorner = wideEls.first(where: { $0.key == "knob-Corner style" })!
        let narrowCorner = narrowEls.first(where: { $0.key == "knob-Corner style" })!
        #expect(narrowCorner.rect[3] > wideCorner.rect[3] - 0.01)
        #expect(narrowCorner.rect[3] > 40.0)
    }

    @Test @MainActor func sidePanelFoldSpringHoverHintsHeaderToolsRightClickAndPointerHighlight() {
        let l = Knob.float("Left size", min: 0, max: 10, default: 5, step: 0.5)
        let c = Knob.choice("Style", labels: ["One", "Two", "Three"], default: 0).hints(["The first", "The second", ""])
        let r = Knob.float("Right pad", min: 0, max: 40, default: 20, step: 1)
        let g = Knob.float("Right gap", min: 0, max: 40, default: 10, step: 1)
        let groups = [
            KnobGroup("Left", region: "left", knobs: [l, c]),
            KnobGroup("Right", region: "right", knobs: [r, g]),
        ]

        var s0 = TestAppState()
        s0.knobs.show()
        s0.knobs.setFolded("Left", false)
        var t = 0.0
        let rt = Runtime<TestAppState>(state: s0, viewport: Vec2(1000, 700), pixelScale: 1.0) { s, _ in
            let page: El<TestAppState> = row().key("cols").wFull().hFull()
                .child(col().key("left").w(300).hFull())
                .child(col().key("right").grow(1).hFull())
            return RuneKnobs.side(page: page, knobs: s.knobs, groups: groups, style: .dark(), seen: [0, 1], keyPath: \TestAppState.knobs)
        }
        func settle() {
            for _ in 0..<24 { t += 1.0 / 60.0; _ = rt.frame(at: t) }
        }
        func rect(_ key: String) -> [Float] {
            rt.element(byKey: key)!.rect
        }
        settle()

        // hovering_an_option_says_what_it_does_under_the_list (`side_tests.rs:157`)
        #expect(rt.element(byKey: "knobs-about-option") == nil)
        let opt1 = rect("knob-Style-opt-1")
        rt.pointerMove(to: Vec2(opt1[0] + opt1[2] * 0.5, opt1[1] + opt1[3] * 0.5), at: t)
        settle()
        #expect(rt.element(byKey: "knobs-about-option") != nil)
        #expect(c.hint(at: 1) == "The second" && c.hint(at: 2).isEmpty)

        // right_clicking_a_knob_puts_only_it_back (`side_tests.rs:199`)
        rt.state.knobs.set(l, 8)
        rt.state.knobs.set(c, 2)
        rt.markNeedsCommit()
        settle()
        let lr = rect("knob-Left size")
        let lpt = Vec2(lr[0] + 40, lr[1] + lr[3] * 0.5)
        rt.pointerMove(to: lpt, at: t)
        settle()
        rt.pointerDown(at: lpt, button: .secondary, at: t + 0.01)
        rt.pointerUp(at: lpt, button: .secondary, at: t + 0.02)
        settle()
        #expect(rt.state.knobs.get(l) == 5 && rt.state.knobs.get(c) == 2)
        _ = rt.state.knobs.undo()
        #expect(rt.state.knobs.get(l) == 8)

        // a_hovered_group_header_offers_random_and_reset (`side_tests.rs:212`)
        rt.state.knobs.set(r, 30)
        rt.markNeedsCommit()
        settle()
        #expect(rt.element(byKey: "knobs-sec-0-reset") == nil)
        let hr = rect("knobs-sub-head-0")
        let hpt = Vec2(hr[0] + 40, hr[1] + hr[3] * 0.5)
        rt.pointerMove(to: hpt, at: t)
        settle()
        let resetBtn = rect("knobs-sec-0-reset")
        let rpt = Vec2(resetBtn[0] + resetBtn[2] * 0.5, resetBtn[1] + resetBtn[3] * 0.5)
        rt.pointerDown(at: rpt, at: t + 0.01)
        rt.pointerUp(at: rpt, at: t + 0.02)
        settle()
        #expect(rt.state.knobs.get(l) == 5 && rt.state.knobs.get(r) == 30)
        #expect(!rt.state.knobs.isFolded("Left", byDefault: true))
        let randBtn = rect("knobs-sec-0-random")
        let randPt = Vec2(randBtn[0] + randBtn[2] * 0.5, randBtn[1] + randBtn[3] * 0.5)
        rt.pointerDown(at: randPt, at: t + 0.01)
        rt.pointerUp(at: randPt, at: t + 0.02)
        settle()
        #expect(rt.state.knobs.values["Left size"] != nil)
        rt.pointerDown(at: hpt, button: .secondary, at: t + 0.01)
        rt.pointerUp(at: hpt, button: .secondary, at: t + 0.02)
        settle()
        #expect(rt.state.knobs.values["Left size"] == nil)

        // clicking_a_choice_row_puts_the_arrows_on_its_options (`side_tests.rs:231`) + moving_the_pointer_takes_the_highlight_from_the_keyboard (`side_tests.rs:252`)
        rt.state.knobs.treeAt = .group(0)
        rt.state.knobs.kbd = true
        rt.markNeedsCommit()
        settle()
        let cr = rect("knob-Style")
        let cpt = Vec2(cr[0] + 15, cr[1] + cr[3] * 0.5)
        rt.pointerMove(to: cpt, at: t)
        settle()
        rt.pointerDown(at: cpt, at: t + 0.01)
        rt.pointerUp(at: cpt, at: t + 0.02)
        settle()
        _ = rt.keyDown(KeyEvent(key: .arrowRight), at: t + 0.03)
        settle()
        #expect(rt.state.knobs.get(c) == 1)
        let bodyRect = rect("knobs-sec-0-body")
        rt.pointerMove(to: Vec2(bodyRect[0] + 30, bodyRect[1] + 5), at: t + 0.05)
        settle()
        #expect(!rt.state.knobs.kbd)
        _ = rt.keyDown(KeyEvent(key: .arrowDown), at: t + 0.06)
        settle()
        #expect(rt.state.knobs.kbd)

        // folding_rolls_the_rows_up_on_the_fold_spring (`side_tests.rs:134`)
        let openH = rect("knobs-sec-0-body")[3]
        let foldHead = rect("knobs-sub-head-0")
        let fpt = Vec2(foldHead[0] + 40, foldHead[1] + foldHead[3] * 0.5)
        rt.pointerMove(to: fpt, at: t + 0.07)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        rt.pointerDown(at: fpt, at: t + 0.005)
        rt.pointerUp(at: fpt, at: t + 0.01)
        for _ in 0..<4 { t += 1.0 / 60.0; _ = rt.frame(at: t) }
        let midH = rect("knobs-sec-0-body")[3]
        #expect(midH > 1.0 && midH < openH - 1.0)
        settle()
        #expect(rect("knobs-sec-0-body")[3] < 0.5)
    }

    @Test @MainActor func sidePanelFilterEditingFullKeyboardCaretPasteAndBlurCases() {
        let l = Knob.float("Left size", min: 0, max: 10, default: 5, step: 0.5)
        let r = Knob.float("Right pad", min: 0, max: 40, default: 20, step: 1)
        let g = Knob.float("Right gap", min: 0, max: 40, default: 10, step: 1)
        let groups = [
            KnobGroup("Left", region: "left", knobs: [l]),
            KnobGroup("Right", region: "right", knobs: [r, g]),
        ]

        func makeRt() -> (Runtime<TestAppState>, () -> Void) {
            var s0 = TestAppState()
            s0.knobs.show()
            s0.knobs.filter("")
            var now = 0.0
            let rt = Runtime<TestAppState>(state: s0, viewport: Vec2(1000, 700), pixelScale: 1.0) { s, _ in
                RuneKnobs.side(page: col().key("page").wFull().hFull(), knobs: s.knobs, groups: groups, style: .dark(), keyPath: \TestAppState.knobs)
            }
            let tick = {
                for _ in 0..<6 { now += 1.0 / 60.0; _ = rt.frame(at: now) }
            }
            tick()
            if let pill = rt.element(byKey: "knobs-filter-input") ?? rt.element(byKey: "knobs-filter-pill") {
                let pt = Vec2(pill.rect[0] + pill.rect[2] * 0.5, pill.rect[1] + pill.rect[3] * 0.5)
                rt.pointerDown(at: pt, at: now + 0.01)
                rt.pointerUp(at: pt, at: now + 0.02)
                tick()
            }
            return (rt, tick)
        }

        // typing_filters_and_the_caret_moves_without_stepping_a_knob + select_all_then_typing_replaces_the_query (`filter_tests.rs:73,94`)
        let (rt1, tick1) = makeRt()
        #expect(rt1.state.knobs.filtering && rt1.focusedKey == "knobs-filter-input")
        _ = rt1.keyDown(KeyEvent(key: .text("rigt")), at: 1.0); tick1()
        #expect(rt1.state.knobs.query == "rigt")
        _ = rt1.keyDown(KeyEvent(key: .arrowLeft), at: 1.1); tick1()
        #expect(rt1.state.knobs.edit.selectedUTF8Range == 3..<3)
        _ = rt1.keyDown(KeyEvent(key: .text("h")), at: 1.2); tick1()
        #expect(rt1.state.knobs.query == "right")
        #expect(rt1.state.knobs.treeAt == .knob(groupIndex: 1, knobIndex: 0))
        let valsBefore = rt1.state.knobs.values
        _ = rt1.keyDown(KeyEvent(key: .arrowRight), at: 1.3); tick1()
        _ = rt1.keyDown(KeyEvent(key: .arrowLeft), at: 1.4); tick1()
        _ = rt1.keyDown(KeyEvent(key: .arrowLeft), at: 1.45); tick1()
        #expect(rt1.state.knobs.values == valsBefore)
        _ = rt1.keyDown(KeyEvent(key: .arrowLeft, mods: Mods(shift: true)), at: 1.5); tick1()
        #expect(rt1.state.knobs.edit.selectedUTF8Range == 2..<3)
        _ = rt1.keyDown(KeyEvent(key: .text("a"), mods: Mods(cmd: true)), at: 1.6); tick1()
        #expect(rt1.state.knobs.edit.selectedUTF8Range == 0..<5)
        _ = rt1.keyDown(KeyEvent(key: .text("left")), at: 1.7); tick1()
        #expect(rt1.state.knobs.query == "left")

        // word_and_line_deletes_and_paste_work (`filter_tests.rs:105`)
        let (rt2, tick2) = makeRt()
        _ = rt2.keyDown(KeyEvent(key: .text("right pad")), at: 1.0); tick2()
        _ = rt2.keyDown(KeyEvent(key: .backspace, mods: Mods(alt: true)), at: 1.1); tick2()
        #expect(rt2.state.knobs.query == "right ")
        _ = rt2.keyDown(KeyEvent(key: .arrowLeft, mods: Mods(alt: true)), at: 1.2); tick2()
        #expect(rt2.state.knobs.edit.selectedUTF8Range == 0..<0)
        _ = rt2.keyDown(KeyEvent(key: .arrowRight, mods: Mods(cmd: true)), at: 1.3); tick2()
        #expect(rt2.state.knobs.edit.selectedUTF8Range == 6..<6)
        _ = rt2.keyDown(KeyEvent(key: .backspace, mods: Mods(cmd: true)), at: 1.4); tick2()
        #expect(rt2.state.knobs.query.isEmpty)
        rt2.paste(ClipboardContent("gap"), at: 1.5); tick2()
        #expect(rt2.state.knobs.query == "gap")
        _ = rt2.keyDown(KeyEvent(key: .text("/")), at: 1.6); tick2()
        #expect(rt2.state.knobs.query == "gap/" && rt2.state.knobs.filtering)

        // down_while_typing_moves_the_row + escape_and_return + with_the_field_idle + clicking_away + query_set_by_app (`filter_tests.rs:125..191`)
        let (rt3, tick3) = makeRt()
        _ = rt3.keyDown(KeyEvent(key: .text("right")), at: 1.0); tick3()
        #expect(rt3.state.knobs.treeAt == .knob(groupIndex: 1, knobIndex: 0))
        _ = rt3.keyDown(KeyEvent(key: .arrowDown), at: 1.1); tick3()
        #expect(rt3.state.knobs.treeAt == .knob(groupIndex: 1, knobIndex: 1))
        #expect(rt3.state.knobs.filtering && rt3.focusedKey == "knobs-filter-input")
        _ = rt3.keyDown(KeyEvent(key: .arrowUp), at: 1.2); tick3()
        #expect(rt3.state.knobs.treeAt == .knob(groupIndex: 1, knobIndex: 0))
        _ = rt3.keyDown(KeyEvent(key: .enter), at: 1.3); tick3()
        #expect(!rt3.state.knobs.filtering && rt3.state.knobs.query == "right")
        #expect(rt3.element(byKey: "knobs-filter-input") == nil)

        // Idle arrows step and fold
        _ = rt3.keyDown(KeyEvent(key: .arrowRight), at: 1.4); tick3()
        #expect(rt3.state.knobs.get(r) == 21)
        _ = rt3.keyDown(KeyEvent(key: .arrowLeft), at: 1.5); tick3()
        #expect(rt3.state.knobs.get(r) == 20)
        _ = rt3.keyDown(KeyEvent(key: .text("/")), at: 1.6); tick3()
        #expect(rt3.state.knobs.filtering)
        _ = rt3.keyDown(KeyEvent(key: .escape), at: 1.7); tick3()
        #expect(!rt3.state.knobs.filtering && rt3.state.knobs.query == "right")
        _ = rt3.keyDown(KeyEvent(key: .escape), at: 1.8); tick3()
        #expect(rt3.state.knobs.query.isEmpty && rt3.state.knobs.open)
        _ = rt3.keyDown(KeyEvent(key: .escape), at: 1.9); tick3()
        #expect(!rt3.state.knobs.open)

        // clicking_away_ends_editing + query_set_by_the_app_shows_in_the_field
        let (rt4, tick4) = makeRt()
        _ = rt4.keyDown(KeyEvent(key: .text("gap")), at: 1.0); tick4()
        let about = rt4.element(byKey: "knobs-about")!
        let apt = Vec2(about.rect[0] + about.rect[2] * 0.5, about.rect[1] + about.rect[3] * 0.5)
        rt4.pointerMove(to: apt, at: 1.1); tick4()
        rt4.pointerDown(at: apt, at: 1.2)
        rt4.pointerUp(at: apt, at: 1.25); tick4()
        _ = rt4.keyDown(KeyEvent(key: .arrowRight), at: 1.3); tick4()
        #expect(!rt4.state.knobs.filtering)

        let (rt5, tick5) = makeRt()
        rt5.state.knobs.setQuery("pad")
        rt5.markNeedsCommit(); tick5()
        _ = rt5.keyDown(KeyEvent(key: .text("s")), at: 1.5); tick5()
        #expect(rt5.state.knobs.query == "pads")
    }
}
