import Foundation
import Testing
@testable import Rune
#if os(macOS)
import AppKit
#endif

@Suite("Platform Delta 2 Parity Tests (P2-30..P2-39)")
struct PlatformDelta2Tests {

    // MARK: - Helpers

    private static func findNode(id: String, in node: AccessibilityNode) -> AccessibilityNode? {
        if node.id == id { return node }
        for child in node.children {
            if let hit = findNode(id: id, in: child) { return hit }
        }
        return nil
    }

    private static func textRuns(in node: AccessibilityNode) -> [AccessibilityNode] {
        var runs: [AccessibilityNode] = []
        if node.role == .text {
            runs.append(node)
        }
        for child in node.children {
            runs.append(contentsOf: textRuns(in: child))
        }
        return runs
    }

    // MARK: - P2-30: c4eda058 (#905) + #819 Window Rest & Cache Eviction

    @Test("ImageAtlas.rest forgets unshown images including page 0 and empties page buffers (#905)")
    func imageAtlasRestForgetsUnshownAndPrunesPages() {
        var atlas = ImageAtlas()
        let px0 = Pixels()
        px0.set(width: 4, height: 4, rgba: [UInt8](repeating: 255, count: 4 * 4 * 4))
        let placed0 = atlas.place(px0, drawnSize: SIMD2<Float>(4, 4), at: 0.0)
        #expect(placed0 != nil)
        #expect(!atlas.pages.isEmpty)
        #expect(atlas.pages[0].data.isEmpty == false)

        // Frame 1 ends after showing px0 on page 0 -> shown == true, so rest keeps it.
        atlas.endFrame()
        atlas.rest()
        #expect(atlas.pages.count == 1)
        #expect(atlas.pages[0].data.isEmpty == false)

        // Frame 2 draws nothing -> endFrame marks page 0 shown == false; rest drops page 0 too.
        atlas.endFrame()
        atlas.rest()
        #expect(atlas.pages.isEmpty)

        // Re-placing re-populates cleanly after rest.
        let replanted = atlas.place(px0, drawnSize: SIMD2<Float>(4, 4), at: 1.0)
        #expect(replanted != nil)
        #expect(atlas.pages.count == 1)
    }

    @Test("TextSystem.endCommit + rest drops layouts untouched >=2 commits and keeps recent (#905)")
    func textSystemEndCommitAndRestEviction() {
        let ts = TextSystem()
        let style = TextStyle(size: 14, weight: 400)

        // Commit 0: measure & shape both strings.
        _ = ts.measure("keep-text", style: style, maxWidth: nil, pixelScale: 1.0)
        _ = ts.shape(text: "keep-text", style: style, maxWidth: nil, pixelScale: 1.0)
        _ = ts.measure("stale-text", style: style, maxWidth: nil, pixelScale: 1.0)
        _ = ts.shape(text: "stale-text", style: style, maxWidth: nil, pixelScale: 1.0)
        ts.endCommit() // commit 1

        // Commit 1: only "keep-text" stays hot.
        _ = ts.measure("keep-text", style: style, maxWidth: nil, pixelScale: 1.0)
        _ = ts.shape(text: "keep-text", style: style, maxWidth: nil, pixelScale: 1.0)
        ts.endCommit() // commit 2

        // Commit 2: "keep-text" touched again; "stale-text" is now 2 commits behind.
        _ = ts.measure("keep-text", style: style, maxWidth: nil, pixelScale: 1.0)
        _ = ts.shape(text: "keep-text", style: style, maxWidth: nil, pixelScale: 1.0)
        ts.endCommit() // commit 3 -> last commit g == 2, stale age = 2 >= 2

        #expect(ts.cachedMeasureCount == 2)
        // Each text string has both an unglyph-emitted shape (from measure) and a full shape.
        #expect(ts.cachedShapedTextCount == 4)

        ts.rest()

        #expect(ts.cachedMeasureCount == 1)
        // Commits 1-2 hit measureCache without re-touching the emitGlyphs:false shapeCache entry,
        // so only keep-text's emitGlyphs:true shapeCache entry remains live after rest().
        #expect(ts.cachedShapedTextCount == 1)
    }

    @Test("GlyphAtlas.dropOrphans drops glyphs/icons older than 1 frame and keeps current (#905)")
    func glyphAtlasDropOrphans() {
        let atlas = GlyphAtlas(width: 128, height: 128)
        let iconA = SVGIcon(viewBox: 16, paths: ["M0 0 L16 0 L16 16 L0 16 Z"])
        let iconB = SVGIcon(viewBox: 16, paths: ["M2 2 L14 2 L14 14 L2 14 Z"])

        // Frame 1: rasterize both icons.
        atlas.beginFrame()
        #expect(atlas.rasterizeIconIfPlaced(iconA, pixelSize: 16) != nil)
        #expect(atlas.rasterizeIconIfPlaced(iconB, pixelSize: 16) != nil)
        #expect(atlas.cachedIconCount == 2)

        // Frame 2: advance without touching iconA.
        atlas.beginFrame()
        // Frame 3: keep iconB alive, leave iconA 2 frames old.
        atlas.beginFrame()
        #expect(atlas.rasterizeIconIfPlaced(iconB, pixelSize: 16) != nil)

        atlas.dropOrphans()
        #expect(atlas.cachedIconCount == 1)
    }

    @Test("App.onRest + Runtime.rest invokes hook and dirties commit only when returning true (#905)")
    func appOnRestAndRuntimeRest() {
        struct S {
            var trimCount = 0
            var dirtyNext = false
        }
        let app = App(state: S()) { s, _ in
            el().key("root").size(100, 40).child(text("\(s.trimCount)"))
        }.onRest { s, _ in
            s.trimCount += 1
            return s.dirtyNext
        }

        let rt = app.makeRuntime(viewport: Vec2(200, 100), pixelScale: 1.0)
        _ = rt.frame(at: 0.0)
        let baseCommits = rt.viewCommitCount

        // Hook returns false -> runs hook, updates state, does not dirty commit.
        rt.rest(at: 10.0)
        #expect(rt.state.trimCount == 1)
        #expect(!rt.hasExternalDirtyCommit)
        _ = rt.frame(at: 10.1)
        #expect(rt.viewCommitCount == baseCommits)

        // Hook returns true -> dirties commit for next frame.
        rt.update(at: 11.0) { s, _ in s.dirtyNext = true }
        _ = rt.frame(at: 11.0)
        let beforeDirtyRest = rt.viewCommitCount

        rt.rest(at: 21.0)
        #expect(rt.state.trimCount == 2)
        #expect(rt.hasExternalDirtyCommit)
        _ = rt.frame(at: 21.1)
        #expect(rt.viewCommitCount == beforeDirtyRest + 1)
    }

    @Test("WindowRestMachine state transitions for drew, woke, and unseen (#819/#905)")
    func windowRestMachineTransitions() {
        var machine = WindowRestMachine()
        #expect(machine.state == .rested)
        #expect(machine.step(.unseen).isEmpty)

        // Normal drew -> due in 10s
        #expect(machine.step(.drew(now: 5.0, lowMemory: false)).isEmpty)
        #expect(machine.deadline == 15.0)

        // Early wake emits nothing
        #expect(machine.step(.woke(now: 14.9)).isEmpty)
        #expect(machine.state == .drawing(due: 15.0))

        // Due wake -> idle + giveBackUnused
        #expect(machine.step(.woke(now: 15.0)) == [.giveBackUnused])
        #expect(machine.state == .idle)
        #expect(machine.deadline == nil)

        // Low-memory drew uses 1s deadline; unseen triggers giveBackAll
        #expect(machine.step(.drew(now: 20.0, lowMemory: true)).isEmpty)
        #expect(machine.deadline == 21.0)
        #expect(machine.step(.unseen) == [.giveBackAll])
        #expect(machine.state == .rested)
    }

    // MARK: - P2-31: d80c872f (#837) El.imeOptionAsAlt & MacOS Option-as-Alt

    @Test("El.imeOptionAsAlt tracks runtime state per focused imeCursor and resets off target (#837)")
    func imeOptionAsAltRuntimeTracking() {
        struct S {
            var mode: Int = 0 // 0: imeCursor+optAlt, 1: imeCursor only, 2: focused textInput
            var edit = TextEdit("hello")
        }

        let rt = Runtime<S>(state: S(), viewport: Vec2(240, 120), pixelScale: 1.0) { s, _ in
            switch s.mode {
            case 0:
                return col().size(240, 120).child(
                    el().key("term").size(200, 40).imeCursor().imeOptionAsAlt()
                )
            case 1:
                return col().size(240, 120).child(
                    el().key("term2").size(200, 40).imeCursor().imeOptionAsAlt(false)
                )
            default:
                return col().size(240, 120).child(
                    el()
                        .key("field")
                        .role(.textInput)
                        .focusable(true)
                        .singleLine(true)
                        .onEdit(
                            get: { (st: S) in st.edit },
                            set: { (st: inout S, e: TextEdit) in st.edit = e }
                        )
                        .size(200, 40)
                )
            }
        }

        _ = rt.frame(at: 0.0)
        #expect(rt.hasImeTarget == true)
        #expect(rt.imeOptionAsAlt == true)
        #expect(rt.effectiveImeOptionAsAlt == true)

        rt.update(at: 0.01) { s, _ in s.mode = 1 }
        _ = rt.frame(at: 0.01)
        #expect(rt.hasImeTarget == true)
        #expect(rt.imeOptionAsAlt == false)
        #expect(rt.effectiveImeOptionAsAlt == false)

        // Switching to a standard textInput clears imeOptionAsAlt from the previous imeCursor.
        rt.update(at: 0.02) { s, tx in
            s.mode = 2
            tx.focus("field")
        }
        _ = rt.frame(at: 0.02)
        #expect(rt.hasFocusedTextInput == true)
        #expect(rt.effectiveImeOptionAsAlt == false)
    }

    #if os(macOS)
    @MainActor
    @Test("MacOSKeyMapper & MacOSTextInputBridge forward Option+key as Alt when optionAsAlt is true (#837)")
    func macosOptionAsAltKeyMapperAndBridge() {
        let optionB = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "∫",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 11
        )
        #expect(optionB != nil)

        if let ev = optionB {
            let normal = MacOSKeyMapper.makeKeyEvent(from: ev, optionAsAlt: false)
            #expect(normal?.mods.alt == true)
            #expect(normal?.key == .text("∫"))

            let optAlt = MacOSKeyMapper.makeKeyEvent(from: ev, optionAsAlt: true)
            #expect(optAlt?.mods.alt == true)
            #expect(optAlt?.key == .text("b"))

            let bridge = MacOSTextInputBridge()
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
            let result = bridge.processKeyDown(ev, in: view, optionAsAlt: true)
            #expect(result == .forwardKeyDown)
        }

        // Command+Option keeps normal Cmd chord mapping without Option-as-Alt stripping.
        let cmdOptionB = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "∫",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 11
        )
        if let cmdEv = cmdOptionB {
            let normalCmd = MacOSKeyMapper.makeKeyEvent(from: cmdEv, optionAsAlt: false)
            let mapped = MacOSKeyMapper.makeKeyEvent(from: cmdEv, optionAsAlt: true)
            #expect(mapped?.mods.cmd == true)
            #expect(mapped?.mods.alt == true)
            #expect(mapped == normalCmd)
            #expect(mapped?.key == .command("b"))
        }
    }
    #endif

    // MARK: - P2-32..P2-35: TerminalGrid Caret, Line Breaks, Wrapped Trailing Spaces, Static Labels

    @Test("Upstream grid_tests::a_reader_gets_a_line_per_row_and_the_cursor_as_its_caret (#835/#894)")
    func terminalGridCaretAndRowBreaks() {
        let style = TextStyle(size: 14, weight: 400, lineHeight: 18, wrap: .noWrap)
        let rows = [
            TerminalGridRow(text: "$ ls", style: style),
            TerminalGridRow(text: "ab", style: style)
                .cell(column: 3, width: 2, text: "日", style: style, color: .white),
            TerminalGridRow(text: "", style: style),
        ]
        let rt = Runtime<Void>(state: (), viewport: Vec2(240, 100), pixelScale: 1.0) { _, _ in
            col().itemsStart().child(
                terminalGrid(columns: 24, cellWidth: 8, cellHeight: 18, rows: rows)
                    .key("screen")
                    .size(192, 54)
                    .gridCaret(4, 1)
            )
        }
        _ = rt.frame(at: 0.0)
        let snap = rt.accessibilitySnapshot()
        let screen = Self.findNode(id: "screen", in: snap)
        #expect(screen != nil)

        let runs = Self.textRuns(in: screen ?? snap)
        #expect(runs.map { $0.value ?? "" } == ["$ ls\n", "ab 日\n", ""])
        #expect(runs[0].characterWidths?.last == 0)
        #expect(runs[1].characterWidths?.last == 0)

        // Caret at column 4 sits on the wide character "日" (columns 3..4 -> index 3 in "ab 日\n").
        #expect(screen?.textSelection == [1, 3, 1, 3])
    }

    @Test("Wrapped grid row omits line break, preserves trailing spaces to columns, and clamps caret before break (#894/#899)")
    func terminalGridWrappedTrailingSpacesAndCaretClamp() {
        let style = TextStyle(size: 14, weight: 400, lineHeight: 18, wrap: .noWrap)
        let row0 = TerminalGridRow(text: "echo", style: style).wraps(true)
        let row1 = TerminalGridRow(text: "ab", style: style)
        let row2 = TerminalGridRow(text: "tail", style: style)

        let rt = Runtime<Void>(state: (), viewport: Vec2(240, 100), pixelScale: 1.0) { _, _ in
            col().itemsStart().child(
                terminalGrid(columns: 8, cellWidth: 8, cellHeight: 18, rows: [row0, row1, row2])
                    .key("screen")
                    .size(64, 54)
                    .gridCaret(7, 1) // past "ab" (columns 0..1) -> clamps before "\n" at index 2
            )
        }
        _ = rt.frame(at: 0.0)
        let snap = rt.accessibilitySnapshot()
        let screen = Self.findNode(id: "screen", in: snap)
        let runs = Self.textRuns(in: screen ?? snap)

        // Row 0 wraps: keeps trailing spaces to 8 columns ("echo    "), no "\n".
        // Row 1 doesn't wrap and isn't last: ends in "\n" with width 0.
        // Row 2 is last visible: no "\n".
        #expect(runs.map { $0.value ?? "" } == ["echo    ", "ab\n", "tail"])
        #expect(runs[0].characterWidths?.count == 8)
        #expect(runs[0].characterWidths?.allSatisfy { $0 == 8 } == true)
        #expect(runs[1].characterWidths == [8, 8, 0])
        #expect(screen?.textSelection == [1, 2, 1, 2])
    }

    @Test("TerminalGridRow.charAt handles wide glyphs and trailing bounds (#835)")
    func terminalGridRowCharAt() {
        let places: [(column: Int, width: Int)] = [
            (0, 1), (1, 1), (2, 1), (3, 2)
        ]
        #expect(TerminalGridRow.charAt(columnPlaces: places, column: 0) == 0)
        #expect(TerminalGridRow.charAt(columnPlaces: places, column: 3) == 3)
        #expect(TerminalGridRow.charAt(columnPlaces: places, column: 4) == 3)
        #expect(TerminalGridRow.charAt(columnPlaces: places, column: 5) == 4)
    }

    @Test("El.labelStatic and El.descriptionStatic borrow StaticString without losing equality (#860)")
    func elLabelAndDescriptionStatic() {
        let staticEl: El<Void> = el()
            .labelStatic("Save File")
            .descriptionStatic("Writes changes to disk")
        let ownedEl: El<Void> = el()
            .label("Save File")
            .description("Writes changes to disk")

        #expect(staticEl.a11yLabel == "Save File")
        #expect(staticEl.a11yDescription == "Writes changes to disk")
        #expect(staticEl.a11yLabelCow == .staticString("Save File"))
        #expect(ownedEl.a11yLabelCow == .owned("Save File"))
        #expect(staticEl.a11yLabelCow == ownedEl.a11yLabelCow)
        #expect(staticEl.a11yDescriptionCow == ownedEl.a11yDescriptionCow)

        let empty: El<Void> = el().labelStatic("").descriptionStatic("")
        #expect(empty.a11yLabel == "")
        #expect(empty.a11yDescription == "")
    }

    // MARK: - P2-36..P2-39: Focus Fallback, Hand-off, Collapsed Guard, and Tx.blur

    private struct FieldsState {
        var open: Bool = true
        var zero: Bool = false
        var a = TextEdit("")
        var b = TextEdit("")
        var c = TextEdit("")
    }

    private func makeFieldsRuntime(open: Bool = true) -> Runtime<FieldsState> {
        let rt = Runtime<FieldsState>(
            state: FieldsState(open: open),
            viewport: Vec2(200, 150),
            pixelScale: 1.0
        ) { s, _ in
            var root: El<FieldsState> = col().size(200, 150)
            if s.open {
                let fieldA: El<FieldsState> = el()
                    .key("a")
                    .role(.textInput)
                    .focusable(true)
                    .singleLine(true)
                    .onEdit(
                        get: { (st: FieldsState) in st.a },
                        set: { (st: inout FieldsState, e: TextEdit) in st.a = e }
                    )
                    .size(200, 35)
                root = root.child(fieldA)
            }
            let fieldB: El<FieldsState> = el()
                .key("b")
                .role(.textInput)
                .focusable(true)
                .singleLine(true)
                .onEdit(
                    get: { (st: FieldsState) in st.b },
                    set: { (st: inout FieldsState, e: TextEdit) in st.b = e }
                )
                .size(200, s.zero ? 0 : 35)
            let fieldC: El<FieldsState> = el()
                .key("c")
                .role(.textInput)
                .focusable(true)
                .singleLine(true)
                .onEdit(
                    get: { (st: FieldsState) in st.c },
                    set: { (st: inout FieldsState, e: TextEdit) in st.c = e }
                )
                .size(200, 35)
            return root.child(fieldB).child(fieldC)
        }
        rt.tabVisitsControls = true
        _ = rt.frame(at: 0.0)
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.01))
        #expect(rt.focusedKey == "a")
        return rt
    }

    @Test("Upstream focus::a_blurred_field_that_leaves_hands_focus_to_the_button_after_it (#842/r376)")
    func blurredFieldThatLeavesHandsFocusToButtonAfterIt() {
        struct Form {
            var open = true
            var field = TextEdit("")
        }
        let rt = Runtime<Form>(state: Form(), viewport: Vec2(200, 100), pixelScale: 1.0) { s, _ in
            var root: El<Form> = col().size(200, 100)
            if s.open {
                let f: El<Form> = el()
                    .key("field")
                    .role(.textInput)
                    .focusable(true)
                    .singleLine(true)
                    .onEdit(
                        get: { (st: Form) in st.field },
                        set: { (st: inout Form, e: TextEdit) in st.field = e }
                    )
                    .size(200, 40)
                root = root.child(f)
            }
            let nextBtn: El<Form> = el().key("next").role(.button).focusable(true).size(100, 30)
            return root.child(nextBtn)
        }
        rt.tabVisitsControls = true
        _ = rt.frame(at: 0.0)
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.01))
        #expect(rt.focusedKey == "field")

        #expect(rt.keyDown(KeyEvent(key: .escape), at: 0.02))
        #expect(rt.focusedKey == nil)

        rt.update(at: 0.03) { s, _ in s.open = false }
        _ = rt.frame(at: 0.03)
        #expect(rt.focusedKey == "next")
    }

    @Test("Upstream focus::a_field_that_blurs_while_staying_in_tree_hands_no_focus_on (r376)")
    func fieldBlursWhileStayingHandsNoFocusOn() {
        let rt = makeFieldsRuntime(open: true)
        rt.update(at: 0.02) { _, tx in tx.blur() }
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == nil)
        #expect(!rt.hasFocusedTextInput)
    }

    @Test("Upstream focus::a_fallback_skips_a_candidate_the_commit_collapsed (r376)")
    func fallbackSkipsCandidateCollapsedByCommit() {
        let rt = makeFieldsRuntime(open: true)
        rt.update(at: 0.02) { s, tx in
            tx.instant()
            s.open = false
            s.zero = true
        }
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == "c")
    }

    @Test("Upstream focus::an_explicit_blur_hands_no_focus_on_when_its_field_goes (r376)")
    func explicitBlurHandsNoFocusOnWhenFieldGoes() {
        let rt = makeFieldsRuntime(open: true)
        rt.update(at: 0.02) { s, tx in
            tx.blur()
            s.open = false
        }
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == nil)
        #expect(!rt.hasFocusedTextInput)

        // Tab still starts from after where focus had been -> lands on "b".
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.03))
        #expect(rt.focusedKey == "b")
    }

    @Test("Escape blur that leaves after intermediate commit still hands focus onward (#842/r376)")
    func escapeBlurLeavingOnLaterCommitHandsOff() {
        let rt = makeFieldsRuntime(open: true)
        #expect(rt.keyDown(KeyEvent(key: .escape), at: 0.02))
        #expect(rt.focusedKey == nil)

        // Intermediate settled commit where "a" still exists -> focus remains nil.
        rt.update(at: 0.03) { _, tx in tx.commit() }
        _ = rt.frame(at: 0.03)
        #expect(rt.focusedKey == nil)

        // Later commit removes "a" -> Escape's handoff is still eligible and advances to "b".
        rt.update(at: 0.04) { s, _ in s.open = false }
        _ = rt.frame(at: 0.04)
        #expect(rt.focusedKey == "b")
    }

    @Test("Focused field moving between containers retains focus and does not hand off (#842/r376)")
    func movedFocusedFieldRetainsFocus() {
        struct MoveState {
            var moved = false
            var field = TextEdit("hi")
        }
        let rt = Runtime<MoveState>(state: MoveState(), viewport: Vec2(240, 120), pixelScale: 1.0) { s, _ in
            let fieldEl: El<MoveState> = el()
                .key("field")
                .role(.textInput)
                .focusable(true)
                .singleLine(true)
                .onEdit(
                    get: { (st: MoveState) in st.field },
                    set: { (st: inout MoveState, e: TextEdit) in st.field = e }
                )
                .size(160, 35)
            let other: El<MoveState> = el().key("other").role(.button).focusable(true).size(100, 30)
            let root: El<MoveState> = col().size(240, 120)
            if !s.moved {
                return root
                    .child(row().key("box-1").size(240, 50).child(fieldEl))
                    .child(row().key("box-2").size(240, 50).child(other))
            } else {
                return root
                    .child(row().key("box-1").size(240, 50))
                    .child(row().key("box-2").size(240, 50).child(other).child(fieldEl))
            }
        }
        rt.tabVisitsControls = true
        _ = rt.frame(at: 0.0)
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.01))
        #expect(rt.focusedKey == "field")

        rt.update(at: 0.02) { s, _ in s.moved = true }
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == "field")
        #expect(rt.hasFocusedTextInput)
    }
}
