import Foundation
import Testing
@testable import Rune
import RuneMotion
#if os(macOS)
import AppKit
#endif

@Suite("Rune Wave 2 Core Subsystems Tests")
struct RuneWave2CoreTests {

    @Test("CSS Grid: fr, minmax, span, templateAreas, and dense auto-flow")
    func cssGridLayout() {
        // 3 columns: 100px, minmax(50px, 1fr), 2fr with columnGap = 10
        // Available width = 420 -> gaps = 20 -> 400 remaining -> 100px + 100px (1fr) + 200px (2fr)
        var gridStyle = LayoutStyle()
        gridStyle.displayMode = .grid
        gridStyle.width = .points(420)
        gridStyle.columnGap = 10
        gridStyle.rowGap = 8
        gridStyle.grid = GridContainerStyle(
            templateColumns: [.px(100), .minmax(.px(50), .fr(1)), .fr(2)],
            autoRows: [.px(40)],
            autoFlow: .rowDense
        )

        var spanChild = LayoutStyle()
        spanChild.gridItem = GridItemStyle(column: .lineSpan(2, 2), row: .line(1)) // cols 2..3 (100 + 10 + 200 = 310)

        let autoChild1 = LayoutStyle() // backfills col 1, row 1 (100px) in rowDense
        let autoChild2 = LayoutStyle() // goes to col 1, row 2 (100px)

        let root = LayoutInputNode(
            style: gridStyle,
            children: [
                LayoutInputNode(style: spanChild),
                LayoutInputNode(style: autoChild1),
                LayoutInputNode(style: autoChild2),
            ]
        )

        let result = LayoutEngine.compute(root: root, viewport: Vec2(800, 600))
        #expect(result.children.count == 3)

        let spanRect = result.children[0].layout.localRect
        #expect(abs(spanRect.x - 110) < 0.5)
        #expect(abs(spanRect.y - 0) < 0.5)
        #expect(abs(spanRect.width - 310) < 0.5)
        #expect(abs(spanRect.height - 40) < 0.5)

        let denseRect1 = result.children[1].layout.localRect
        #expect(abs(denseRect1.x - 0) < 0.5)
        #expect(abs(denseRect1.y - 0) < 0.5)
        #expect(abs(denseRect1.width - 100) < 0.5)

        let denseRect2 = result.children[2].layout.localRect
        #expect(abs(denseRect2.x - 0) < 0.5)
        #expect(abs(denseRect2.y - 48) < 0.5)
        #expect(abs(denseRect2.width - 100) < 0.5)

        // Named templateAreas via El builder
        struct DummyState {}
        let view: El<DummyState> = grid(columns: GridTrack.repeatCount(2, .fr(1)))
            .w(200)
            .gridTemplateAreas([
                ["header", "header"],
                ["nav", "main"]
            ])
            .child(el().gridArea("header").h(30))
            .child(el().gridArea("nav").h(50))
            .child(el().gridArea("main").h(50))

        #expect(view.layout.displayMode == .grid)
        #expect(view.layout.grid?.templateAreas.count == 2)
    }

    @Test("CSS Block layout: vertical stacking and margin collapsing")
    func cssBlockLayout() {
        var blockStyle = LayoutStyle()
        blockStyle.displayMode = .block
        blockStyle.width = .points(300)

        var c1 = LayoutStyle()
        c1.displayMode = .block
        c1.height = .points(40)
        c1.margin = Sides(top: 10, right: 0, bottom: 20, left: 0)

        var c2 = LayoutStyle()
        c2.displayMode = .block
        c2.height = .points(30)
        c2.margin = Sides(top: 15, right: 0, bottom: 10, left: 0)

        var rootStyle = LayoutStyle(direction: .column)
        rootStyle.alignItems = .start
        let blockNode = LayoutInputNode(
            style: blockStyle,
            children: [LayoutInputNode(style: c1), LayoutInputNode(style: c2)]
        )
        let result = LayoutEngine.compute(
            root: LayoutInputNode(style: rootStyle, children: [blockNode]),
            viewport: Vec2(800, 600)
        )
        let blockResult = result.children[0]
        let r1 = blockResult.children[0].layout.localRect
        let r2 = blockResult.children[1].layout.localRect

        #expect(abs(r1.y - 10) < 0.5)
        #expect(abs(r1.width - 300) < 0.5)
        // Margin collapse: max(20, 15) = 20 -> r2.y = 10 + 40 + 20 = 70
        #expect(abs(r2.y - 70) < 0.5)
        // Total height: 10 + 40 + 20 + 30 + 10 = 110
        #expect(abs(blockResult.layout.localRect.height - 110) < 0.5)
    }

    @Test("VirtualListState windowing, dynamic heights, scroll-to-index, sticky headers, and GrowthRowState")
    func virtualListAndGrowth() {
        let state = VirtualListState(defaultEstimate: 40, gap: 0, overscanPixels: 40, overscanCount: 1)
        let items = (0..<100).map { idx in
            VirtualItemSpec(
                key: "row-\(idx)",
                estimatedHeight: 40,
                isStickyHeader: idx % 10 == 0
            )
        }
        state.setItems(items)
        #expect(abs(state.totalHeight - 4000) < 0.5)

        state.recordMeasuredHeight(80, forKey: "row-1")
        #expect(abs(state.totalHeight - 4040) < 0.5)

        let win = state.computeWindow(scrollY: 500, viewportHeight: 200)
        #expect(win.visibleRange.lowerBound > 0)
        #expect(win.mountedRange.lowerBound <= win.visibleRange.lowerBound)
        #expect(win.mountedRange.upperBound >= win.visibleRange.upperBound)
        #expect(win.activeStickyIndex == 10)
        #expect(win.beforeHeight > 0)
        #expect(win.afterHeight > 0)

        let scrollTarget = state.scrollOffset(toIndex: 20, viewportHeight: 200, alignment: .top)
        #expect(abs(scrollTarget - 840) < 0.5)

        struct DummyState {}
        let built: El<DummyState> = virtualRows(
            key: "list",
            state: state,
            count: 100,
            estimatedHeight: 40,
            scrollY: 500,
            viewportHeight: 200
        ) { idx in
            text("Item \(idx)").h(40)
        }
        #expect(built.children.count < 25)

        var growth = GrowthRowState(targetHeight: 120, presentedHeight: 0, edge: .feather, isStreaming: true)
        for _ in 0..<20 {
            growth.step(dt: 1.0 / 60.0)
        }
        #expect(growth.presentedHeight > 20)
        #expect(growth.presentedHeight <= 120)
        #expect(growth.maskHeight > 0)
        growth.settle()
        #expect(growth.isSettled)
        #expect(growth.presentedHeight == 120)
    }

    @Test("Flight, MemoCache, Tracked/region, Latest, LaunchMarks, and RuneLabels")
    func flightMemoAndTracking() async throws {
        // Flight selector & MatchedFlightRegistry
        #expect(FlightSelector.selects("msg-42/body", path: "root/msg-42/#0/body", key: "body"))
        #expect(!FlightSelector.selects("msg-99/body", path: "root/msg-42/#0/body", key: "body"))

        let flights = MatchedFlightRegistry()
        let startRect = MotionRect.fromXYWH(10, 10, 100, 40)
        let endRect = MotionRect.fromXYWH(210, 110, 200, 80)
        _ = flights.stepFlight(flightId: "card", targetRect: startRect, now: 0.0, reducedMotion: false)
        let midRect = flights.stepFlight(flightId: "card", targetRect: endRect, now: 0.1, reducedMotion: false)
        #expect(flights.hasActiveFlights)
        #expect(midRect.x >= startRect.x && midRect.x <= endRect.x)

        // MemoCache & Tracked/region
        struct DummyState {}
        let cache = MemoCache()
        var buildCount = 0
        let _: El<DummyState> = memo("row-1", deps: 1, cache: cache) {
            buildCount += 1
            return text("v1")
        }
        let cachedEl: El<DummyState> = memo("row-1", deps: 1, cache: cache) {
            buildCount += 1
            return text("v1-again")
        }
        #expect(buildCount == 1)
        #expect(cachedEl.plainText == "v1")

        let _: El<DummyState> = memo("row-1", deps: 2, cache: cache) {
            buildCount += 1
            return text("v2")
        }
        #expect(buildCount == 2)

        let tracked = Tracked("alpha")
        var regionBuilds = 0
        let _: El<DummyState> = region("r1", cache: cache) {
            regionBuilds += 1
            return text(tracked.value)
        }
        let _: El<DummyState> = region("r1", cache: cache) {
            regionBuilds += 1
            return text(tracked.value)
        }
        #expect(regionBuilds == 1)
        tracked.value = "beta"
        let r2: El<DummyState> = region("r1", cache: cache) {
            regionBuilds += 1
            return text(tracked.value)
        }
        #expect(regionBuilds == 2)
        #expect(r2.plainText == "beta")

        // Latest-wins
        let latest = Latest<Int>(debounceSeconds: 0)
        latest.request(10) { $0 * 2 }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(latest.take() == 20)
        #expect(latest.take() == nil)

        // LaunchMarks & RuneLabels
        let marks = LaunchMarks()
        marks.mark("app.start")
        marks.addMetric("text.glyphs", amount: 12)
        #expect(marks.marks().count == 1)
        #expect(marks.metrics().first?.value == 12)

        let labels = RuneLabels()
        labels.setLabels { key in
            if case .copy = key { return "Kopieren" }
            return nil
        }
        #expect(labels.label(for: .copy) == "Kopieren")
        #expect(labels.label(for: .paste) == "Paste")
    }

    @Test("Accessibility projection, Spellcheck, and ShortcutRegistry")
    @MainActor
    func a11ySpellcheckAndShortcuts() {
        struct AppState {
            var count: Int = 0
            var edit = TextEdit("hello wrld")
        }
        var state = AppState()
        state.edit.spellcheckEnabled = true

        let tree: El<AppState> = col()
            .key("root")
            .w(300)
            .h(200)
            .child(
                El<AppState>(direction: .row)
                    .key("btn")
                    .role(.button)
                    .label("Increment")
                    .help("Adds one")
                    .focusable(true)
                    .size(120, 40)
                    .onClick { s, _ in s.count += 1 }
            )
            .child(
                El<AppState>(direction: .row)
                    .key("hidden")
                    .inert(true)
                    .size(50, 20)
            )

        func toLayoutInput<S>(_ e: El<S>) -> LayoutInputNode {
            LayoutInputNode(style: e.layout, children: e.children.map(toLayoutInput))
        }
        let layout = LayoutEngine.compute(root: toLayoutInput(tree), viewport: Vec2(300, 200))
        let a11yRoot = AccessibilityTreeBuilder.project(
            element: tree,
            layout: layout,
            state: state,
            focusedKey: "btn"
        )
        #expect(a11yRoot != nil)
        #expect(a11yRoot?.children.count == 1) // inert child omitted
        let btnNode = a11yRoot?.children.first
        #expect(btnNode?.role == .button)
        #expect(btnNode?.label == "Increment")
        #expect(btnNode?.help == "Adds one")
        #expect(btnNode?.isFocused == true)
        #expect(btnNode?.actions.contains(.press) == true)

        #if os(macOS)
        let nsTree = AppKitAccessibilityMapper.buildElement(from: a11yRoot!) { _, _ in }
        #expect(nsTree.accessibilityRole() == .group)
        let nsBtn = nsTree.accessibilityChildren()?.first as? RuneNSAccessibilityElement
        #expect(nsBtn?.accessibilityRole() == .button)
        #expect(nsBtn?.accessibilityLabel() == "Increment")
        #expect(nsBtn?.accessibilityPerformPress() == true)
        #endif

        // Deterministic Spellcheck + TextEdit integration
        let checker = SpellChecker(backend: CustomDictionarySpellChecker())
        let misspelled = state.edit.misspelledUTF8Ranges(using: checker)
        #expect(misspelled.count == 1)
        let suggestion = state.edit.spellingSuggestions(atUTF8Offset: misspelled[0].lowerBound, using: checker)
        #expect(suggestion?.word == "wrld")
        #expect(suggestion?.suggestions.contains("world") == true)

        state.edit.replaceUTF8Range(misspelled[0], with: "world")
        #expect(state.edit.text == "hello world")
        #expect(state.edit.misspelledUTF8Ranges(using: checker).isEmpty)

        checker.learnWord("swiftrune")
        var learnedEdit = TextEdit("swiftrune")
        learnedEdit.spellcheckEnabled = true
        #expect(learnedEdit.misspelledUTF8Ranges(using: checker).isEmpty)

        // ShortcutRegistry
        final class FiredBox: @unchecked Sendable {
            var items: [String] = []
        }
        let registry = ShortcutRegistry()
        let fired = FiredBox()
        let r1 = registry.register(id: "palette", accelerator: "cmd+shift+p", label: "Command Palette") {
            fired.items.append("palette")
        }
        #expect(r1 == .success("palette"))

        let conflict = registry.register(id: "dup", accelerator: "cmd+shift+p") {}
        #expect(conflict == .failure(.conflict(existingId: "palette")))

        let chordRes = registry.register(id: "save-all", accelerator: "cmd+k, cmd+s") {
            fired.items.append("save-all")
        }
        #expect(chordRes == .success("save-all"))

        if let seq = ShortcutSequence(parsing: "cmd+shift+p") {
            #expect(ShortcutSequence.formatDisplay(seq, macOSSymbols: true) == "⇧⌘P")
        }

        let d1 = registry.dispatch(KeyEvent(key: .command("p"), mods: Mods(shift: true, cmd: true)))
        #expect(d1 == .handled(id: "palette"))

        let d2 = registry.dispatch(KeyEvent(key: .command("k"), mods: Mods(cmd: true)))
        #expect(d2 == .pendingChord)
        let d3 = registry.dispatch(KeyEvent(key: .command("s"), mods: Mods(cmd: true)))
        #expect(d3 == .handled(id: "save-all"))
        #expect(fired.items == ["palette", "save-all"])
    }
}
