import Foundation
import Testing
@testable import Rune
import RuneMotion

@Suite("El Slice Group 1 & 4 Non-Blocked Parity Tests")
struct ElSliceGroup1And4ParityTests {
    // MARK: - Group 1: types (`AnimSource.NAMES`, `FrameStats`)

    @Test("AnimSource.NAMES and FrameStats match upstream types.rs")
    func animSourceAndFrameStats() {
        #expect(AnimSource.tracks == 1 << 0)
        #expect(AnimSource.growth == 1 << 1)
        #expect(AnimSource.scroll == 1 << 2)
        #expect(AnimSource.reveal == 1 << 3)
        #expect(AnimSource.loop == 1 << 4)
        #expect(AnimSource.scaleSettle == 1 << 5)
        #expect(AnimSource.video == 1 << 6)
        #expect(AnimSource.textFlight == 1 << 7)
        #expect(AnimSource.live == 1 << 8)
        #expect(AnimSource.virtualFill == 1 << 9)
        #expect(AnimSource.NAMES == [
            "tracks", "growth", "scroll", "reveal", "loop",
            "scale-settle", "video", "text-flight", "live", "virtual-fill",
        ])
        #expect(AnimSource.names(AnimSource.tracks | AnimSource.virtualFill) == ["tracks", "virtual-fill"])
        #expect(AnimSource.names(0).isEmpty)

        let empty = FrameStats()
        #expect(empty.commits == 0)
        #expect(empty.layoutNodes == 0)
        #expect(empty.glyphs == 0)
        #expect(empty.shaped == 0)

        let rt = Runtime(state: (), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            row().key("box").size(50, 20).child(text("hi"))
        }
        _ = rt.frame(at: 0.0)
        let s = rt.stats
        #expect(s.commits >= 1)
        #expect(s.layoutNodes >= 2)
        #expect(s.glyphs >= 2)
        #expect(s.shaped >= 1)
    }

    // MARK: - Group 1: `tests/multi_state_windows.rs`

    private struct ReviewState {
        var count: UInt32 = 0
    }

    private struct SettingsState {
        var name: String = "default"
    }

    private func makeReviewApp() -> App<ReviewState> {
        App(title: "Review", size: Vec2(400, 300), state: ReviewState()) { s, _ in
            text("review \(s.count)").key("out")
        }
    }

    private func makeSettingsWindow() -> AppWindowSpec<SettingsState> {
        AppWindowSpec(
            key: "settings",
            app: AppSpec(
                title: "Settings",
                size: Vec2(320, 200),
                state: SettingsState()
            ) { s, _ in
                text("settings \(s.name)").key("out")
            }
        )
    }

    private func renderWindowTree(name: String, runWithTree: ([String]) throws -> Void) throws -> (String, [Double]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-multi-state-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let treeURL = dir.appendingPathComponent("tree.json")
        try runWithTree(["--tree", treeURL.path])
        let data = try Data(contentsOf: treeURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let elements = json?["elements"] as? [[String: Any]] ?? []
        let out = elements.first { ($0["key"] as? String) == "out" }
        let textVal = try #require(out?["text"] as? String)
        let vp = try #require(json?["viewport"] as? [Double])
        return (textVal, vp)
    }

    @MainActor
    @Test("multi_state_windows: factory mixes state types and tools render the selected one")
    func factoryMixesStateTypes() throws {
        let cases: [(String, String, [Double])] = [
            ("review", "review 7", [400.0, 300.0]),
            ("settings", "settings Kit", [320.0, 200.0]),
        ]
        for (key, expectedText, expectedVP) in cases {
            let (out, vp) = try renderWindowTree(name: "factory-\(key)") { treeArgs in
                let args = treeArgs + ["--window", key]
                try runWindowsWithArgs(arguments: args) { _ in
                    let review = makeReviewApp()
                    review.handle().update { s, _ in s.count = 7 }
                    let settings = makeSettingsWindow()
                    settings.appHandle.update { s, _ in s.name = "Kit" }
                    return [AppWindowSpec.fromApp("review", review).boxed(), settings.boxed()]
                }
            }
            #expect(out == expectedText)
            #expect(vp == expectedVP)
        }
    }

    @MainActor
    @Test("multi_state_windows: app.window is selectable with its own state and hidden until opened")
    func appWindowSelectableAndHiddenUntilOpened() throws {
        let cases: [(String, String, [Double])] = [
            ("main", "review 7", [400.0, 300.0]),
            ("settings", "settings Kit", [320.0, 200.0]),
        ]
        for (key, expectedText, expectedVP) in cases {
            let (out, vp) = try renderWindowTree(name: "app-\(key)") { treeArgs in
                let args = treeArgs + ["--window", key]
                var app = makeReviewApp()
                let hidden = WindowOptions(visible: false)
                let (settings, window) = app.window(makeSettingsWindow().options(hidden))
                #expect(window.key == "settings")
                #expect(!settings.isVisible && !window.isReady)
                window.open()
                settings.update { s, _ in s.name = "Kit" }
                app.handle().update { s, _ in s.count = 7 }
                try app.args(args).run()
            }
            #expect(out == expectedText)
            #expect(vp == expectedVP)
        }
    }

    @MainActor
    @Test("multi_state_windows: factory windows can add their own secondary windows")
    func factoryWindowsSecondaryWindows() throws {
        let (out, _) = try renderWindowTree(name: "nested") { treeArgs in
            let args = treeArgs + ["--window", "settings"]
            try runWindowsWithArgs(arguments: args) { _ in
                var review = makeReviewApp()
                let (settings, _) = review.window(makeSettingsWindow())
                settings.update { s, _ in s.name = "nested" }
                return [AppWindowSpec.fromApp("review", review).boxed()]
            }
        }
        #expect(out == "settings nested")
    }

    // MARK: - Group 1: `tests/batch_c.rs:119`

    @Test("window_focus delivers ordered transitions including before first frame")
    func windowFocusOrderedTransitions() {
        let rt = Runtime<[Bool]>(state: [], viewport: Vec2(100, 100), pixelScale: 1.0) { _, _ in
            el().onWindowFocus { s, focused, tx in
                s.append(focused)
                tx.copyText("focus")
            }
        }
        rt.windowFocus(true)
        rt.windowFocus(true)
        rt.windowFocus(false)
        _ = rt.frame(at: 0.0)
        #expect(rt.state == [true, false])
        #expect(rt.copyRequest == "focus")
        let commits = rt.stats.commits
        rt.windowFocus(false)
        _ = rt.frame(at: 0.0)
        #expect(rt.stats.commits == commits)
        rt.windowFocus(true)
        _ = rt.frame(at: 0.0)
        #expect(rt.state == [true, false, true])
    }

    // MARK: - Group 3: `hot_state.rs` & Group 4: `deco_api.rs`, `drop.rs`, `TerminalGrid`

    @Test("Deco literal compatibility and SPAN_RADIUS")
    func decoCompatibility() {
        let d = Deco(rect: [0, 0, 0, 0], color: .black, radius: 4.0)
        #expect(d.radius == 4.0)
        #expect(SPAN_RADIUS == 4.0)
    }

    @Test("acceptsFiles filters child target and falls back to accepting ancestor")
    func acceptsFilesRouting() {
        struct DropState {
            var parentFiles: [URL] = []
            var childFiles: [URL] = []
        }
        let rt = Runtime<DropState>(state: DropState(), viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            col()
                .key("parent")
                .size(200, 200)
                .acceptsFiles { $0.pathExtension.lowercased() == "txt" }
                .onDropFiles { s, urls, _ in s.parentFiles = urls }
                .child(
                    el()
                        .key("child")
                        .size(100, 100)
                        .acceptsFiles { $0.pathExtension.lowercased() == "png" }
                        .onDropFiles { s, urls, _ in s.childFiles = urls }
                )
        }
        _ = rt.frame(at: 0.0)
        let txtURL = URL(fileURLWithPath: "/tmp/note.txt")
        let accepted = rt.dropFiles([txtURL], at: Vec2(25, 25), at: 0.1)
        #expect(accepted)
        _ = rt.frame(at: 0.1)
        #expect(rt.state.childFiles.isEmpty)
        #expect(rt.state.parentFiles == [txtURL])
    }

    @Test("hotScrolls and hotMotion report active scroll offsets and animating frames")
    func hotScrollsAndHotMotion() {
        struct HotState {
            var moved: Bool = false
        }
        let rt = Runtime<HotState>(state: HotState(), viewport: Vec2(200, 120), pixelScale: 1.0) { s, _ in
            col().size(200, 120).children([
                col().key("scroll").size(200, 60).scroll(ScrollSpec(stickBottom: false)).children(
                    (0..<10).map { i in el().key("i\(i)").size(200, 30) }
                ),
                el().key("mover")
                    .size(s.moved ? 80 : 40, 20)
                    .animateLayout(),
            ])
        }
        _ = rt.frame(at: 0.0)
        rt.wheel(WheelEvent(dy: -40), at: Vec2(50, 30), now: 0.05)
        rt.update(at: 0.05) { s, _ in s.moved = true }
        _ = rt.frame(at: 0.05)
        let scrolls = rt.hotScrolls()
        #expect(!scrolls.isEmpty)
        #expect(scrolls.contains { $0.offset > 0 })
        let motions = rt.hotMotion()
        #expect(motions.contains { $0.path.hasSuffix("mover") })
    }

    @Test("TerminalGrid layout sizing, readingText, and accessibility row runs")
    func terminalGridLayoutAndAccessibility() {
        let style = TextStyle(size: 12, weight: 400, lineHeight: 16, wrap: .noWrap)
        let row0 = TerminalGridRow(text: "ls -la", style: style)
            .fill(start: 0, end: 2, color: Color(r: 0, g: 0, b: 1, a: 1))
            .cell(column: 8, width: 2, text: "🚀", style: style, color: .white)
        let row1 = TerminalGridRow(text: "done   ", style: style)

        let rt = Runtime<Void>(state: (), viewport: Vec2(300, 200), pixelScale: 2.0) { _, _ in
            col().itemsStart().child(
                terminalGrid(columns: 12, cellWidth: 8, cellHeight: 16, rows: [row0, row1])
                    .key("term")
            )
        }
        _ = rt.frame(at: 0.0)
        let term = rt.element(byKey: "term")
        #expect(term != nil)
        #expect(term?.rect[2] == 96)
        #expect(term?.rect[3] == 32)

        let snapshot = rt.accessibilitySnapshot()
        func findNode(id: String, in node: AccessibilityNode) -> AccessibilityNode? {
            if node.id == id { return node }
            for c in node.children {
                if let hit = findNode(id: id, in: c) { return hit }
            }
            return nil
        }
        let termA11y = findNode(id: "term", in: snapshot)
        #expect(termA11y?.children.count == 2)
        if let line0 = termA11y?.children.first {
            #expect(line0.value == "ls -la  🚀\n")
            #expect(line0.wordStarts == [0, 3, 8])
            #expect(line0.characterWidths?.dropLast().last == 16)
            #expect(line0.characterWidths?.last == 0)
        }
        if let line1 = termA11y?.children.last {
            #expect(line1.value == "done")
            #expect(line1.wordStarts == [0])
        }
    }
}
