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
}
