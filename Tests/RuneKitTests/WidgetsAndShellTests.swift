import Foundation
import Testing
@testable import RuneKit
@testable import Rune

@Suite("RuneKit Widgets, Gestures, Notes & Shell Tests")
struct WidgetsAndShellTests {
    @Test("BudgetCache retains last two commit generations and evicts older LRU entries")
    func budgetCacheRetentionAndEviction() {
        let cache = BudgetCache<String, Int>(limitBytes: 100)
        cache.advanceCommit() // commit 1
        cache.insert("a", value: 1, bytes: 60)
        cache.insert("b", value: 2, bytes: 60)
        cache.insert("c", value: 3, bytes: 60)
        #expect(cache.count == 3)

        cache.advanceCommit() // commit 2
        #expect(cache.get("c") == 3)

        cache.advanceCommit() // commit 3
        cache.insert("d", value: 4, bytes: 60)
        #expect(cache.peek("a") == nil)
        #expect(cache.peek("b") == nil)
        #expect(cache.peek("c") == 3)
        #expect(cache.peek("d") == 4)
    }

    @Test("KitCSS parses box-shadow layers, inset, and drops transparent layers")
    func cssBoxShadows() {
        let shadows = KitCSS.boxShadows(
            "#0000001a 0px 1px 1.5px 0px, #ffffff29 0px 0px 0px 0.5px inset, #00000000 0px 0px 0px 0px"
        )
        #expect(shadows.count == 2)
        #expect(shadows[0].y == 1.0)
        #expect(shadows[0].blur == 1.5)
        #expect(!shadows[0].inset)
        #expect(shadows[1].spread == 0.5)
        #expect(shadows[1].inset)
    }

    @Test("LineSelectionState handles gutter numbers, Shift-extend, text drag, and cancel")
    func lineSelectionGestures() {
        var state = LineSelectionState<Int>.idle(selected: nil)
        state.step(.press(at: 3, column: .numbers, shift: false))
        let eff1 = state.step(.release)
        #expect(eff1 == .ended(LineRange.line(3)))

        // Pressing the single selected number unselects on release
        state.step(.press(at: 3, column: .numbers, shift: false))
        let eff2 = state.step(.release)
        #expect(eff2 == .ended(nil))

        // Dragging on text selects range; cancel restores previous
        state.step(.set(LineRange.line(1)))
        state.step(.press(at: 5, column: .text, shift: false))
        state.step(.move(at: 8))
        #expect(state.selected == LineRange(start: 5, end: 8))
        state.step(.cancel)
        #expect(state.selected == LineRange.line(1))
    }

    @Test("Grip tracks live drag and detects lost release on unobserved pointer moves")
    func gripLostReleaseDetection() {
        var grip = Grip<Int>.idle
        #expect(grip.press(7, at: Vec2(0, 0)) == nil)
        #expect(grip.pointerMoved(to: Vec2(1, 0)) == nil)
        #expect(grip.moved(to: Vec2(1, 0)) == 7)
        #expect(grip.pointerMoved(to: Vec2(2, 0)) == nil)
        #expect(grip.pointerMoved(to: Vec2(3, 0)) == 7)
        #expect(!grip.isHeld)
    }

    @Test("ShortcutRecorderState captures chords, validates modifiers, handles Escape and Backspace")
    func shortcutRecorderLifecycle() {
        var rec = ShortcutRecorderState()
        rec.begin()
        #expect(rec.isRecording)

        // Unmodified key is refused
        rec.handle(.keyDown(key: "k", modifiers: [], isRepeat: false))
        #expect(rec.error == .missingModifier)
        #expect(rec.isRecording)
        rec.handle(.keyUp("k"))

        // Valid chord commits and exits recording
        rec.handle(.keyDown(key: "k", modifiers: [.command, .shift], isRepeat: false))
        #expect(!rec.isRecording)
        #expect(rec.shortcut == ShortcutChord(key: "k", modifiers: [.command, .shift]))
        #expect(rec.shortcut?.keycaps == ["⇧", "⌘", "K"])

        // Backspace clears
        rec.begin()
        rec.handle(.keyDown(key: "backspace", modifiers: [], isRepeat: false))
        #expect(rec.shortcut == nil)
        #expect(!rec.isRecording)
    }

    @Test("PopupListState filters and skips disabled items during keyboard navigation")
    func popupListNavigation() {
        let items = [
            PopupListItem(id: "1", label: "Open File"),
            PopupListItem(id: "2", label: "Disabled Action", disabled: true),
            PopupListItem(id: "3", label: "Open Folder"),
        ]
        var state = PopupListState(open: true, query: "", activeIndex: 0)
        state.moveNext(in: items)
        #expect(state.activeIndex == 2)
        state.query = "folder"
        #expect(state.filtered(items).map(\.id) == ["3"])
    }

    @Test("ImageZoomState zoomAt, clampView, glide convergence, and backdrop close")
    func imageZoomMathAndGestures() {
        let bounds = ZoomBounds(width: 200, height: 100, viewportWidth: 300, viewportHeight: 200, maxScale: 8)
        var zoom = ImageZoomState(bounds: bounds)
        zoom.openLightbox()
        #expect(zoom.isOpen)

        zoom.zoomIn()
        #expect(zoom.isZoomed)
        let stepped = zoom.glide.step(dt: 0.016)
        #expect(stepped)

        zoom.toggleDoubleClick(fitRatio: 0.5) // back to fit
        #expect(!zoom.isZoomed)

        zoom.pointerDown(onBody: false, onBackdrop: true, at: Vec2(10, 10))
        let closed = zoom.pointerUp(onBackdrop: true)
        #expect(closed)
        #expect(!zoom.isOpen)
    }

    @Test("NoteParser parses facts, compare, steps, size, marked code fences, and callouts")
    func notesParsingAndRendering() {
        let src = """
        ```facts
        Status: {built} Ready
        ```

        ```compare
        Before: 120ms
        After: 18ms
        ```

        ```steps
        {done} Lexer · Wired
        {working} Tests · Running
        ```

        ```size
        RuneKit +240 −12 · 3 files
        ```

        ```swift title="App.swift" {1,3-4}
        let a = 1
        let b = 2
        let c = 3
        let d = 4
        ```

        > [!warning] Check bounds carefully.
        """
        let pieces = NoteParser.parse(src)
        #expect(pieces.count == 6)

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(640, 800)) { _, _ in
            kit.note(src)
        }
        #expect(!rt.frame(at: 0).primitives.isEmpty)
    }

    @Test("PaneState, PaneGroup, SplitTree, and Feedback views")
    func shellAndFeedback() {
        var pane = PaneState(width: 240).range(min: 160, max: 480)
        pane.beginResize()
        pane.updateResize(deltaWidth: 60)
        #expect(pane.width == 300)
        pane.updateResize(deltaWidth: -200) // below collapse threshold 80
        #expect(!pane.isOpen)
        pane.cancelResize()
        #expect(pane.isOpen && pane.width == 240)

        let g1 = PaneGroup(id: "g1", tabs: [
            PaneTab(id: "t1", title: "Main.swift", content: "main"),
            PaneTab(id: "t2", title: "Kit.swift", content: "kit"),
        ])
        let g2 = PaneGroup(id: "g2", tabs: [
            PaneTab(id: "t3", title: "Tests.swift", content: "tests"),
        ])
        var tree: SplitTree<String> = .leaf(g1)
        tree.splitLeaf(groupID: "g1", axis: .horizontal, newGroup: g2, ratio: 0.6, splitID: "s1")
        tree.setRatio(splitID: "s1", ratio: 0.55)
        tree.reorderTab(groupID: "g1", tabID: "t2", to: 0)
        tree.selectTab(groupID: "g1", tabID: "t2")

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(800, 500)) { _, _ in
            col().wFull().hFull()
                .child(kit.windowTitlebar(title: "Rune", subtitle: "Workspace"))
                .child(
                    row().wFull().grow(1).minH(0)
                        .child(kit.sidebar(pane: pane, title: "Files", content: text("tree")))
                        .child(
                            kit.splitTree(
                                tree: tree,
                                onSelectTab: { _, _, _ in },
                                renderContent: { name in text(name) }
                            )
                        )
                )
                .child(kit.statusBar(leading: text("Ready"), trailing: text("UTF-8")))
        }
        #expect(!rt.frame(at: 0).primitives.isEmpty)

        let feedbackRt = Runtime<Int>(state: 0, viewport: Vec2(500, 400)) { _, _ in
            col().wFull().gap(8)
                .child(kit.radarSpinner())
                .child(kit.ringLoader())
                .child(kit.progressBar(value: 0.75, label: "Build", showValue: true))
                .child(kit.progressCircle(value: 0.5))
                .child(kit.feedbackBanner(tone: .success, message: "Ready"))
                .child(kit.emptyState(title: "Empty", description: "No items"))
                .child(kit.errorBoundary(title: "Error", error: "Failed"))
        }
        #expect(!feedbackRt.frame(at: 0).primitives.isEmpty)
        #expect(RadarGrid.dots.count == 25)
    }

    @Test("FileTreeBuilder compacts single-child directories and sorts naturally")
    func fileTreeCompactionAndSorting() {
        let items = FileTreeBuilder(compactFolders: true).buildTreeItems([
            ("Sources/RuneKit/Kit.swift", 1),
            ("Sources/RuneKit/FileTree.swift", 2),
            ("README.md", 3),
        ])
        #expect(items.count == 2)
        #expect(items[0].label == "Sources/RuneKit")
        #expect(items[0].isFolder)
        #expect(items[0].children.map(\.label) == ["FileTree.swift", "Kit.swift"])
        #expect(items[1].label == "README.md")
    }
}
