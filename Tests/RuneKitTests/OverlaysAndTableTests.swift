import Foundation
import Testing
@testable import RuneKit
@testable import Rune

@Suite("RuneKit Overlays, Table, Combobox, PopupList, Select, Dialog, Menu & List Tests")
struct OverlaysAndTableTests {

    // MARK: - Popover & Anchor Geometry (popover_tests.rs, popover_focus.rs)

    @Test("PopoverAnchor flips above near bottom edge and stays below when roomy")
    func flipsAboveNearBottomEdge() {
        let win: (Float, Float) = (400, 300)
        let flipped = PopoverAnchor.anchorRect(
            trigger: [20, 250, 60, 270],
            size: (100, 80),
            placement: .bottomStart,
            gap: 4,
            window: win
        )
        #expect(flipped == [20, 166, 120, 246])

        let roomy = PopoverAnchor.anchorRect(
            trigger: [20, 20, 60, 40],
            size: (100, 80),
            placement: .bottomStart,
            gap: 4,
            window: win
        )
        #expect(roomy == [20, 44, 120, 124])
    }

    @Test("PopoverAnchor flips left near right edge")
    func flipsLeftNearRightEdge() {
        let r = PopoverAnchor.anchorRect(
            trigger: [340, 100, 380, 120],
            size: (100, 80),
            placement: .right,
            gap: 4,
            window: (400, 300)
        )
        #expect(r[0] == 236)
        #expect(r[2] == 336)
    }

    @Test("PopoverAnchor clamps inside window viewport margin")
    func clampsInsideTheWindow() {
        let win: (Float, Float) = (400, 300)
        let leftFlipped = PopoverAnchor.anchorRect(
            trigger: [10, 20, 30, 40],
            size: (100, 40),
            placement: .bottomEnd,
            gap: 4,
            window: win
        )
        #expect(leftFlipped[0] == 10)

        let rightClamped = PopoverAnchor.anchorRect(
            trigger: [380, 100, 398, 120],
            size: (100, 40),
            placement: .bottom,
            gap: 4,
            window: win
        )
        #expect(rightClamped[2] == 392)
    }

    @Test(
        "Popover close restores trigger focus before exit finishes",
        .disabled("Blocked on @el: El.focusReturn(_:) restore trigger focus when inner button closes Popover")
    )
    func popoverCloseRestoresTriggerFocus() {
        struct S { var open = false }
        let k = Kit.neutral(dark: true)
        let rt = Runtime(state: S(), viewport: Vec2(400, 400), systemDark: true) { s, cx in
            var layer: [El<S>] = []
            let trigger: El<S> = k.button(key: "open", "Open") { s, _ in s.open = true }
            let body = Popover<S>("details")
                .trigger(trigger)
                .open(s.open)
                .onClose { s in s.open = false }
                .child(k.button(key: "close", "Close") { s, _ in s.open = false })
                .build(kit: k, layer: &layer, cx: cx)
            return RuneKit.root(body, layer)
        }
        var t = 0.0
        rt.frame(at: t)
        for key in [Key.tab, .space, .tab] {
            _ = rt.keyDown(KeyEvent(key: key, mods: .none), at: t)
            t += 1.0 / 60.0
            rt.frame(at: t)
        }
        #expect(rt.elements().first(where: { $0.focused })?.key == "close")
        _ = rt.keyDown(KeyEvent(key: .space, mods: .none), at: t)
        t += 1.0 / 60.0
        rt.frame(at: t)
        #expect(!rt.state.open)
        #expect(rt.elements().first(where: { $0.focused })?.key == "open")
        for _ in 0..<60 {
            t += 1.0 / 60.0
            rt.frame(at: t)
        }
        #expect(rt.elements().first(where: { $0.focused })?.key == "open")
    }

    // MARK: - Table & TableState (table.rs)

    private struct TableFile {
        var id: String
        var name: String
        var size: UInt64
    }

    private struct TableApp {
        var files: [TableFile]
        var table: TableState
        var sorts: [(String, SortDir)] = []
        var opened: [String] = []

        init(n: Int, multi: Bool) {
            self.files = (0..<n).map { i in
                TableFile(
                    id: "f\(i)",
                    name: "file \(i) with a name long enough to cut short.rs",
                    size: UInt64((i * 7919) % 100_000)
                )
            }
            self.table = TableState().multiSelect(multi)
        }
    }

    private func makeTableRuntime(_ app: TableApp, size: Vec2 = Vec2(500, 300)) -> Runtime<TableApp> {
        let k = Kit.neutral(dark: true)
        let rt = Runtime(state: app, viewport: size, systemDark: true) { s, cx in
            col().size(size.x, size.y).child(
                TableView<TableApp>(
                    \.table,
                    len: { $0.files.count },
                    rowID: { $0.files[$1].id }
                )
                .name("Files")
                .column(TableCol("name", "Name").flex(1.0).min(120.0).sortable())
                .column(TableCol("size", "Size").width(100.0).min(60.0).max(180.0).align(.end).sortable())
                .column(TableCol("kind", "Kind").width(80.0).resizable(false))
                .cell { s, i, colId in
                    switch colId {
                    case "name": return .text(s.files[i].name)
                    case "size": return .text("\(s.files[i].size)").mono()
                    default: return .text("Rust").muted()
                    }
                }
                .onSort { s, colId, dir, _ in
                    s.sorts.append((colId, dir))
                    if colId == "size" {
                        s.files.sort {
                            if dir == .ascending { return $0.size < $1.size }
                            return $0.size > $1.size
                        }
                    }
                }
                .onOpen { s, id, _ in s.opened.append(id) }
                .zebra(true)
                .build(s, cx: cx, kit: k)
                .h(size.y)
            )
        }
        rt.frame(at: 0.0)
        rt.frame(at: 1.0 / 60.0)
        return rt
    }

    private func tableHeader(_ rt: Runtime<TableApp>, _ id: String) -> ElementInfo {
        rt.elements().first { !$0.exiting && $0.key == id && $0.label != nil }!
    }

    @Test("Fixed table columns keep their width and flex takes the rest in header and body")
    func fixedColumnsKeepWidthAndFlexTakesRest() {
        let rt = makeTableRuntime(TableApp(n: 20, multi: false))
        let name = tableHeader(rt, "name")
        let size = tableHeader(rt, "size")
        let kind = tableHeader(rt, "kind")
        #expect(abs(size.rect[2] - 100.0) < 0.5)
        #expect(abs(kind.rect[2] - 80.0) < 0.5)
        #expect(abs(name.rect[2] - (500.0 - 180.0)) < 0.5)

        let bodySizeCells = rt.elements().filter {
            !$0.exiting && $0.key == "size" && $0.label == nil
        }
        #expect(!bodySizeCells.isEmpty)
        for c in bodySizeCells {
            #expect(abs(c.rect[0] - size.rect[0]) < 0.5)
            #expect(abs(c.rect[2] - size.rect[2]) < 0.5)
        }
    }

    @Test("Dragging a table header edge resizes within column bounds and fixed column has no handle")
    func draggingHeaderEdgeResizesWithinColumnBounds() {
        let rt = makeTableRuntime(TableApp(n: 20, multi: false))
        let initialSize = tableHeader(rt, "size")
        #expect(abs(initialSize.rect[2] - 100.0) < 0.5)
        #expect(rt.elements().filter { $0.label == "Resize Kind" }.isEmpty)

        func resizeSizeColumn(dx: Float) {
            let handle = rt.elements().first { !$0.exiting && $0.label == "Resize Size" }!.rect
            let x = handle[0] + handle[2] * 0.5
            let y = handle[1] + handle[3] * 0.5
            rt.pointerDown(at: Vec2(x, y), at: 0.1)
            rt.frame(at: 0.11)
            for k in 1...4 {
                rt.pointerMove(to: Vec2(x + dx * Float(k) / 4.0, y), at: 0.12 + Double(k) * 0.01)
                rt.frame(at: 0.12 + Double(k) * 0.01)
            }
            rt.pointerUp(at: Vec2(x + dx, y), at: 0.2)
            rt.frame(at: 0.21)
            rt.frame(at: 0.22)
        }

        resizeSizeColumn(dx: 30.0)
        #expect(rt.state.table.columnWidth("size") == 130.0)
        #expect(abs(tableHeader(rt, "size").rect[2] - 130.0) < 0.5)
        #expect(abs(tableHeader(rt, "name").rect[2] - (500.0 - 210.0)) < 0.5)

        resizeSizeColumn(dx: 400.0)
        #expect(rt.state.table.columnWidth("size") == 180.0)

        resizeSizeColumn(dx: -400.0)
        #expect(rt.state.table.columnWidth("size") == 60.0)
    }

    @Test("Table header click sorts ascending/descending and ignores non-sortable column")
    func headerClickSortsAndShowsDirection() {
        let rt = makeTableRuntime(TableApp(n: 50, multi: false))
        let sizeRect = tableHeader(rt, "size").rect
        let cx = sizeRect[0] + 20.0
        let cy = sizeRect[1] + sizeRect[3] * 0.5
        rt.pointerDown(at: Vec2(cx, cy), at: 0.1)
        rt.pointerUp(at: Vec2(cx, cy), at: 0.11)
        rt.frame(at: 0.12)

        #expect(rt.state.sorts.count == 1)
        #expect(rt.state.sorts[0].0 == "size" && rt.state.sorts[0].1 == .ascending)
        #expect(rt.state.table.sort?.0 == "size" && rt.state.table.sort?.1 == .ascending)
        #expect(tableHeader(rt, "size").help == "ascending")
        for i in 1..<rt.state.files.count {
            #expect(rt.state.files[i - 1].size <= rt.state.files[i].size)
        }

        rt.pointerDown(at: Vec2(cx, cy), at: 0.2)
        rt.pointerUp(at: Vec2(cx, cy), at: 0.21)
        rt.frame(at: 0.22)
        #expect(rt.state.table.sort?.0 == "size" && rt.state.table.sort?.1 == .descending)
        #expect(tableHeader(rt, "size").help == "descending")
        #expect(tableHeader(rt, "name").help == nil)

        let kindRect = tableHeader(rt, "kind").rect
        rt.pointerDown(at: Vec2(kindRect[0] + 20.0, kindRect[1] + kindRect[3] * 0.5), at: 0.3)
        rt.pointerUp(at: Vec2(kindRect[0] + 20.0, kindRect[1] + kindRect[3] * 0.5), at: 0.31)
        rt.frame(at: 0.32)
        #expect(rt.state.sorts.count == 2)
    }

    @Test("Cancelling table column resize with Escape restores original width policy")
    func cancellingColumnResizeRestoresOriginalWidthPolicy() {
        for initial in [Float?.none, Float?.some(110.0)] {
            let rt = makeTableRuntime(TableApp(n: 20, multi: false))
            if let w = initial {
                rt.state.table.setColumnWidth("size", w)
                rt.markNeedsCommit()
                rt.frame(at: 0.05)
            }
            let handle = rt.elements().first { !$0.exiting && $0.label == "Resize Size" }!.rect
            let x = handle[0] + handle[2] * 0.5
            let y = handle[1] + handle[3] * 0.5
            rt.pointerDown(at: Vec2(x, y), at: 0.1)
            rt.frame(at: 0.11)
            rt.pointerMove(to: Vec2(x + 40.0, y), at: 0.12)
            rt.frame(at: 0.13)
            #expect(rt.state.table.columnWidth("size") != initial)

            _ = rt.keyDown(KeyEvent(key: .escape, mods: .none), at: 0.14)
            rt.frame(at: 0.15)
            #expect(rt.state.table.columnWidth("size") == initial)

            rt.pointerUp(at: Vec2(x + 40.0, y), at: 0.16)
            rt.frame(at: 0.17)
            #expect(rt.state.table.columnWidth("size") == initial)
        }
    }

    @Test("Table keys move selection, PageDown/End/Home scroll into view, and Return opens")
    func tableKeysMoveSelectionAndReturnOpens() {
        let rt = makeTableRuntime(TableApp(n: 200, multi: false))
        _ = rt.keyDown(KeyEvent(key: .tab, mods: .none), at: 0.1)
        rt.frame(at: 0.11)
        #expect(rt.elements().first(where: { $0.focused })?.key == "table")

        func send(_ key: Key, mods: Mods = .none, at t: Double = 0.2) {
            _ = rt.keyDown(KeyEvent(key: key, mods: mods), at: t)
            rt.frame(at: t + 0.01)
        }

        send(.arrowDown)
        #expect(rt.state.table.cursor == "f0")
        send(.arrowDown)
        send(.arrowDown)
        #expect(rt.state.table.cursor == "f2")

        send(.pageDown)
        let page = Int(rt.state.table.cursor!.dropFirst())! - 2
        #expect((5...12).contains(page))

        send(.end)
        #expect(rt.state.table.cursor == "f199")
        for f in 1..<30 {
            rt.frame(at: 0.3 + Double(f) / 60.0)
        }
        let selectedRow = rt.elements().first { !$0.exiting && $0.key == "f199" && $0.itemSelected }
        #expect(selectedRow != nil)
        #expect((selectedRow?.visible[3] ?? 0) > 20.0)

        send(.enter, at: 1.0)
        #expect(rt.state.opened == ["f199"])
        send(.home, at: 1.1)
        #expect(rt.state.table.selected == ["f0"])
    }

    @Test("Multi-select table extends with Shift and selects all with Cmd-A")
    func multiSelectShiftExtendsAndCmdASelectsAll() {
        let rt = makeTableRuntime(TableApp(n: 30, multi: true))
        _ = rt.keyDown(KeyEvent(key: .tab, mods: .none), at: 0.1)
        rt.frame(at: 0.11)
        _ = rt.keyDown(KeyEvent(key: .arrowDown, mods: .none), at: 0.12)
        rt.frame(at: 0.13)
        _ = rt.keyDown(KeyEvent(key: .arrowDown, mods: Mods(shift: true)), at: 0.14)
        rt.frame(at: 0.15)
        _ = rt.keyDown(KeyEvent(key: .arrowDown, mods: Mods(shift: true)), at: 0.16)
        rt.frame(at: 0.17)
        #expect(rt.state.table.selected.sorted() == ["f0", "f1", "f2"])

        _ = rt.keyDown(KeyEvent(key: .text("a"), mods: Mods(cmd: true)), at: 0.18)
        rt.frame(at: 0.19)
        #expect(rt.state.table.selectedCount == 30)
    }

    @Test("Table selection follows its row through a sort and 100k rows virtualize")
    func selectionFollowsSortAnd100kVirtualizes() {
        let rt = makeTableRuntime(TableApp(n: 50, multi: false))
        var tx = Tx()
        rt.state.table.reveal("f7", rowIndex: 7, tx: &tx)
        rt.markNeedsCommit()
        rt.frame(at: 0.1)
        let sizeRect = tableHeader(rt, "size").rect
        rt.pointerDown(at: Vec2(sizeRect[0] + 20, sizeRect[1] + sizeRect[3] * 0.5), at: 0.2)
        rt.pointerUp(at: Vec2(sizeRect[0] + 20, sizeRect[1] + sizeRect[3] * 0.5), at: 0.21)
        rt.frame(at: 0.22)
        #expect(rt.state.table.selected == ["f7"])

        let rt100k = makeTableRuntime(TableApp(n: 100_000, multi: false))
        let builtRows = rt100k.elements().filter { !$0.exiting && $0.role == .listItem }.count
        #expect((5..<60).contains(builtRows))
    }

    @Test("Table cut-short text offers full help tooltip and shrinking rows stays consistent")
    func tableTruncationTooltipAndShrinkingRows() {
        var app = TableApp(n: 5, multi: false)
        app.files[1].name = "short.rs"
        let rt = makeTableRuntime(app)
        rt.state.table.setColumnWidth("name", 120.0)
        rt.state.table.select("f0")
        rt.markNeedsCommit()
        rt.frame(at: 0.1)

        let helps = rt.elements().compactMap(\.help)
        #expect(helps.contains("file 0 with a name long enough to cut short.rs"))
        #expect(!helps.contains("short.rs"))

        let rt2 = makeTableRuntime(TableApp(n: 20, multi: true))
        _ = rt2.keyDown(KeyEvent(key: .tab, mods: .none), at: 0.1)
        rt2.frame(at: 0.11)
        _ = rt2.keyDown(KeyEvent(key: .end, mods: .none), at: 0.12)
        rt2.frame(at: 0.13)
        #expect(rt2.state.table.cursor == "f19")

        rt2.state.files = Array(rt2.state.files.prefix(5))
        rt2.markNeedsCommit()
        rt2.frame(at: 0.2)
        _ = rt2.keyDown(KeyEvent(key: .arrowDown, mods: .none), at: 0.21)
        rt2.frame(at: 0.22)
        #expect(rt2.state.table.cursor == "f0")
        _ = rt2.keyDown(KeyEvent(key: .end, mods: Mods(shift: true)), at: 0.23)
        rt2.frame(at: 0.24)
        #expect(rt2.state.table.selectedCount == 5)
    }

    // MARK: - Combobox & ComboboxState (combobox.rs)

    @Test("ComboboxState fuzzy score, filtered order, and phase transitions")
    func comboboxStateUnitTests() {
        let items = [
            ComboboxItem(id: "a", label: "Claude Opus", detail: "anthropic"),
            ComboboxItem(id: "b", label: "Claude Sonnet", detail: "anthropic", disabled: true),
            ComboboxItem(id: "c", label: "GPT-4o", detail: "openai"),
        ]
        var st = ComboboxState()
        #expect(!st.isOpen)
        let revealEffects = st.step(.toggle(current: "c"))
        #expect(st.isOpen)
        #expect(revealEffects == [.reveal("c")])
        #expect(st.active == "c")

        st.search.setText("son")
        _ = st.step(.edited)
        let onlyDisabled = ComboboxState.filtered(items, query: st.search.text)
        #expect(onlyDisabled == [1])
        #expect(st.activeIndex(in: items, filtered: onlyDisabled) == nil)

        st.search.setText("opus")
        _ = st.step(.edited)
        let opMatches = ComboboxState.filtered(items, query: st.search.text)
        #expect(opMatches == [0])
        #expect(st.activeIndex(in: items, filtered: opMatches) == 0)

        let hiEffects = st.step(.highlight(id: "a", reveal: true))
        #expect(hiEffects == [.reveal("a")])
        #expect(st.active == "a")

        let closed = st.step(.close)
        #expect(closed.isEmpty)
        #expect(!st.isOpen)
    }

    private struct ComboApp {
        var combo = ComboboxState()
        var chosen: String? = nil
        var chooses = 0
        var other = TextEdit()
        var appKeys = 0
        var animate = false
    }

    private func makeComboRuntime(_ initial: ComboApp = ComboApp(), open: Bool = true) -> Runtime<ComboApp> {
        var s = initial
        if open {
            _ = s.combo.step(.toggle(current: nil))
        }
        let k = Kit.neutral(dark: true)
        let items = (0..<200).map { i in
            ComboboxItem(
                id: "item-\(i)",
                label: String(format: "Model %03d", i),
                disabled: i == 1
            )
        }
        let rt = Runtime(
            state: s,
            viewport: Vec2(400, 400),
            systemDark: true,
            onKey: { state, _, _ in
                state.appKeys += 1
                return true
            }
        ) { state, cx in
            var layer: [El<ComboApp>] = []
            let cb = Combobox<ComboApp>(
                "models",
                state: \.combo,
                options: items
            )
            .current(state.chosen)
            .animateFiltering(state.animate)
            .onChoose { st, id, _ in
                st.chosen = id
                st.chooses += 1
            }
            .build(state, kit: k, layer: &layer, cx: cx)

            let body = col()
                .child(
                    Rune.textInput(key: "other", \ComboApp.other)
                        .size(200, 32)
                )
                .child(cb)
            return RuneKit.root(body, layer)
        }
        rt.frame(at: 0.0)
        return rt
    }

    @Test(
        "Combobox opening takes focus, clears prior preedit, and reveals offscreen selection",
        .disabled("Blocked on @el: 512KB worker-thread SIGBUS in Runtime.walk fixed in gap/el (#204)")
    )
    func comboboxOpeningTakesFocusAndRevealsOffscreenSelection() throws {
        var s = ComboApp()
        s.other.setPreedit("pending")
        s.chosen = "item-199"
        let rt = makeComboRuntime(s, open: false)

        // Focus "other" first via Tab, then click trigger to open combobox
        _ = rt.keyDown(KeyEvent(key: .tab, mods: .none), at: 0.05)
        rt.frame(at: 0.06)
        #expect(rt.elements().first(where: \.focused)?.key == "other")

        let trig = try #require(rt.elements().first { $0.key == "models-value-trigger" }).rect
        let cx = trig[0] + trig[2] * 0.5
        let cy = trig[1] + trig[3] * 0.5
        rt.pointerDown(at: Vec2(cx, cy), at: 0.1)
        rt.pointerUp(at: Vec2(cx, cy), at: 0.11)
        rt.frame(at: 0.12)

        #expect(rt.state.combo.isOpen)
        #expect(rt.elements().first(where: \.focused)?.key == "models-search")
        #expect(rt.state.other.preedit == nil)

        let last = rt.elements().first { $0.key == "models-option-item-199" }
        #expect((last?.visible[3] ?? 0) > 0)

        _ = rt.keyDown(KeyEvent(key: .text("099"), mods: .none), at: 0.2)
        rt.frame(at: 0.21)
        #expect(rt.state.combo.search.text == "099")
    }

    @Test(
        "Combobox loops skipping disabled, virtualizes rows, and handles IME/Escape/Scrim focus",
        .disabled("Blocked on @el: 512KB worker-thread SIGBUS in Runtime.walk fixed in gap/el (#204)")
    )
    func comboboxLoopsSkipsDisabledAndReturnsFocus() throws {
        let rt = makeComboRuntime()
        let optionCount = rt.elements().filter { $0.key?.hasPrefix("models-option-") == true }.count
        #expect(optionCount < 50)

        // Ensure search input is focused before driving keyboard events
        let searchRect = try #require(rt.elements().first { $0.key == "models-search" }).rect
        rt.pointerDown(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.05)
        rt.pointerUp(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.06)
        rt.frame(at: 0.07)

        func send(_ key: Key, mods: Mods = .none, at t: Double = 0.2) {
            _ = rt.keyDown(KeyEvent(key: key, mods: mods), at: t)
            rt.frame(at: t + 0.01)
        }

        send(.arrowDown)
        #expect(rt.state.combo.active == "item-2")
        send(.arrowUp)
        send(.arrowUp)
        #expect(rt.state.combo.active == "item-199")
        let last = rt.elements().first { $0.key == "models-option-item-199" }
        #expect((last?.visible[3] ?? 0) > 0)

        send(.enter)
        #expect(rt.state.chosen == "item-199")
        #expect(!rt.state.combo.isOpen)
        #expect(rt.elements().first(where: { $0.focused })?.key == "models-value-trigger")

        send(.space)
        #expect(rt.state.combo.isOpen)
        #expect(rt.elements().first(where: { $0.focused })?.key == "models-search")
        send(.escape)
        #expect(!rt.state.combo.isOpen)
        #expect(rt.elements().first(where: { $0.focused })?.key == "models-value-trigger")

        send(.space)
        #expect(rt.state.combo.isOpen)
        rt.state.combo.search.setPreedit("x")
        rt.markNeedsCommit()
        rt.frame(at: 0.5)
        send(.enter, at: 0.55)
        #expect(rt.state.combo.isOpen, "Preedit protects Enter from choosing")

        rt.state.combo.search.cancelPreedit()
        rt.markNeedsCommit()
        rt.frame(at: 0.6)
        rt.pointerDown(at: Vec2(390, 390), at: 0.65)
        rt.pointerUp(at: Vec2(390, 390), at: 0.66)
        rt.frame(at: 0.67)
        #expect(!rt.state.combo.isOpen)
        #expect(rt.elements().first(where: { $0.focused })?.key == "models-value-trigger")
    }

    // MARK: - PopupList (popup_list.rs)

    @Test("PopupList virtualizes, reveals active, handles hover/click without blurring composer")
    func popupListBehavior() {
        struct PState {
            var count = 40
            var active: Int? = 0
            var open = true
            var chosen: [String] = []
            var hovered: [Int] = []
            var composer = TextEdit()
        }
        let k = Kit.neutral(dark: true)

        let rt = Runtime(state: PState(), viewport: Vec2(480, 480), systemDark: true) { s, cx in
            var layer: [El<PState>] = []
            let input: El<PState> = Rune.textInput(key: "composer", \PState.composer)
                .size(240, 32)
                .onKey { st, ev, _ in
                    if ev.key == .arrowUp && st.count > 0 {
                        st.active = ((st.active ?? 0) + st.count - 1) % st.count
                        return true
                    }
                    return false
                }

            let pop = PopupList<PState>("commands", anchor: "composer")
                .open(s.open)
                .label("Commands")
                .items((0..<s.count).map { i in
                    PopupItem<PState>("cmd-\(i)", "Command \(i)").disabled(i == 1)
                })
                .active(s.active)
                .emptyMessage("No matches")
                .onActive { st, idx in st.hovered.append(idx) }
                .onChoose { st, id, _ in st.chosen.append(id) }
            pop.build(kit: k, layer: &layer, cx: cx)

            let body = col().pt(300).px(24).child(input)
            return RuneKit.root(body, layer)
        }
        rt.frame(at: 0.0)
        // Focus composer
        _ = rt.keyDown(KeyEvent(key: .tab, mods: .none), at: 0.01)
        for _ in 0..<10 { rt.frame(at: 0.02) }
        #expect(rt.elements().first(where: { $0.focused })?.key == "composer")

        #expect(rt.elements().filter { !$0.exiting && $0.key?.hasPrefix("commands-option-") == true }.count < 20)

        _ = rt.keyDown(KeyEvent(key: .arrowUp, mods: .none), at: 0.1)
        rt.frame(at: 0.11)
        #expect(rt.state.active == 39)

        rt.state.count = 5
        rt.state.active = 0
        rt.markNeedsCommit()
        rt.frame(at: 0.2)
        for _ in 0..<20 { rt.frame(at: 0.25) }

        let row2 = rt.elements().first { $0.key == "commands-option-cmd-2" }!.rect
        rt.pointerMove(to: Vec2(row2[0] + 10, row2[1] + 10), at: 0.3)
        rt.frame(at: 0.31)
        #expect(rt.state.hovered.contains(2))

        let row1 = rt.elements().first { $0.key == "commands-option-cmd-1" }!.rect
        rt.pointerDown(at: Vec2(row1[0] + 10, row1[1] + 10), at: 0.32)
        rt.pointerUp(at: Vec2(row1[0] + 10, row1[1] + 10), at: 0.33)
        rt.frame(at: 0.34)
        #expect(rt.state.chosen.isEmpty)
        #expect(rt.elements().first(where: { $0.focused })?.key == "composer")

        rt.pointerDown(at: Vec2(row2[0] + 10, row2[1] + 10), at: 0.35)
        rt.pointerUp(at: Vec2(row2[0] + 10, row2[1] + 10), at: 0.36)
        rt.frame(at: 0.37)
        #expect(rt.state.chosen == ["cmd-2"])
        #expect(rt.elements().first(where: { $0.focused })?.key == "composer")
    }

    @Test(
        "PopupList reveals offscreen active option inside scrollable viewport",
        .disabled("Blocked on @el: El.revealSelected / El.focusSelected in Runtime")
    )
    func popupListRevealsOffscreenActive() {
        struct PState {
            var active: Int? = 0
            var composer = TextEdit()
        }
        let k = Kit.neutral(dark: true)
        let rt = Runtime(state: PState(), viewport: Vec2(480, 480), systemDark: true) { s, cx in
            var layer: [El<PState>] = []
            let input: El<PState> = Rune.textInput(key: "composer", \PState.composer)
                .size(240, 32)
                .onKey { st, ev, _ in
                    if ev.key == .arrowUp { st.active = 39; return true }
                    return false
                }
            PopupList<PState>("commands", anchor: "composer")
                .open(true)
                .items((0..<40).map { PopupItem<PState>("cmd-\($0)", "Command \($0)") })
                .active(s.active)
                .build(kit: k, layer: &layer, cx: cx)
            return RuneKit.root(col().pt(300).px(24).child(input), layer)
        }
        rt.frame(at: 0.0)
        _ = rt.keyDown(KeyEvent(key: .tab, mods: .none), at: 0.01)
        rt.frame(at: 0.02)
        _ = rt.keyDown(KeyEvent(key: .arrowUp, mods: .none), at: 0.05)
        rt.frame(at: 0.06)
        let last = rt.elements().first { $0.key == "commands-option-cmd-39" }
        #expect((last?.visible[3] ?? 0) > 0)
    }

    @Test("PopupList hover changes do not scroll now or on the next frame (tests/popup_list.rs)")
    func popupListHoverDoesNotScrollNowOrNextFrame() throws {
        struct PState {
            var active: Int? = 0
            var hovered: [Int] = []
            var composer = TextEdit()
        }
        let k = Kit.neutral(dark: true)
        let rt = Runtime(state: PState(), viewport: Vec2(480, 480), systemDark: true) { s, cx in
            var layer: [El<PState>] = []
            let input: El<PState> = Rune.textInput(key: "composer", \PState.composer).size(240, 32)
            PopupList<PState>("commands", anchor: "composer")
                .open(true)
                .items((0..<40).map { PopupItem<PState>("cmd-\($0)", "Command \($0)") })
                .active(s.active)
                .onActive { st, idx in st.hovered.append(idx) }
                .build(kit: k, layer: &layer, cx: cx)
            return RuneKit.root(col().pt(300).px(24).child(input), layer)
        }
        for i in 0..<60 { rt.frame(at: Double(i) / 60.0) }
        let row7 = try #require(rt.elements().first { $0.key == "commands-option-cmd-7" })
        let targetX = row7.visible[0] + 10
        let targetY = row7.visible[1] + 2
        let before = row7.rect
        rt.pointerMove(to: Vec2(targetX, targetY), at: 1.0)
        rt.frame(at: 1.01)
        #expect(rt.state.active == nil || rt.state.hovered.contains(7))
        for j in 1...3 { rt.frame(at: 1.01 + Double(j) / 60.0) }
        let after = try #require(rt.elements().first { $0.key == "commands-option-cmd-7" }).rect
        #expect(before == after)
        #expect(rt.state.hovered == [7])
    }

    @Test("Pressing PopupList padding or empty state keeps composer focused (tests/popup_list.rs)")
    func popupListPaddingAndEmptyStateKeepComposerFocused() throws {
        for count in [0, 3] {
            struct PState { var composer = TextEdit(); var active: Int? = 0 }
            let k = Kit.neutral(dark: true)
            let rt = Runtime(state: PState(), viewport: Vec2(480, 480), systemDark: true) { s, cx in
                var layer: [El<PState>] = []
                let input: El<PState> = Rune.textInput(key: "composer", \PState.composer).size(240, 32)
                PopupList<PState>("commands", anchor: "composer")
                    .open(true)
                    .items((0..<count).map { PopupItem<PState>("cmd-\($0)", "Command \($0)") })
                    .active(s.active)
                    .emptyMessage("No matches")
                    .build(kit: k, layer: &layer, cx: cx)
                return RuneKit.root(col().pt(300).px(24).child(input), layer)
            }
            for i in 0..<30 { rt.frame(at: Double(i) / 60.0) }
            _ = rt.keyDown(KeyEvent(key: .tab, mods: .none), at: 0.5)
            rt.frame(at: 0.52)
            #expect(rt.elements().first(where: { $0.focused })?.key == "composer")

            let popup = try #require(rt.elements().first { $0.key == "commands-content" }).rect
            rt.pointerDown(at: Vec2(popup[0] + 1, popup[1] + 1), at: 0.6)
            rt.pointerUp(at: Vec2(popup[0] + 1, popup[1] + 1), at: 0.61)
            rt.frame(at: 0.62)
            #expect(rt.elements().first(where: { $0.focused })?.key == "composer")

            if count == 0 {
                let emptyRect = try #require(rt.elements().first { $0.key == "empty" }).rect
                rt.pointerDown(at: Vec2(emptyRect[0] + emptyRect[2] * 0.5, emptyRect[1] + emptyRect[3] * 0.5), at: 0.7)
                rt.pointerUp(at: Vec2(emptyRect[0] + emptyRect[2] * 0.5, emptyRect[1] + emptyRect[3] * 0.5), at: 0.71)
                rt.frame(at: 0.72)
                #expect(rt.elements().first(where: { $0.focused })?.key == "composer")
            }
        }
    }

    @Test(
        "Select portal inside Dialog accepts an option outside the panel (tests/dialog_select.rs)",
        .disabled("Blocked on @el: 512KB worker-thread SIGBUS in Runtime.walk fixed in gap/el (#204)")
    )
    func selectPortalInsideDialogAcceptsOptionOutsidePanel() throws {
        struct S { var dialog = true; var select = false; var value = "First" }
        let k = Kit.neutral(dark: true)
        let rt = Runtime(state: S(), viewport: Vec2(1400, 800), systemDark: true) { s, cx in
            var layer: [El<S>] = []
            let sel = Select<S>("choice", options: ["First", "Second"])
                .current(s.value)
                .appearance(.field)
                .width(100)
                .placement(.rightStart)
                .open(s.select)
                .onToggle { st in st.select.toggle() }
                .onClose { st in st.select = false }
                .onChoose { st, v, _ in
                    st.value = v
                    st.select = false
                }
                .build(kit: k, layer: &layer, cx: cx)
            Dialog<S>("dialog", "Choose")
                .open(s.dialog)
                .onClose { st in st.dialog = false }
                .child(row().wFull().justifyEnd().child(sel))
                .build(kit: k, layer: &layer)
            return RuneKit.root(el().wFull().hFull(), layer)
        }
        rt.frame(at: 0.0)
        let trig = try #require(rt.elements().first { $0.key == "choice-trigger" } as ElementInfo?).rect
        rt.pointerDown(at: Vec2(trig[0] + trig[2] * 0.5, trig[1] + trig[3] * 0.5), at: 0.05)
        rt.pointerUp(at: Vec2(trig[0] + trig[2] * 0.5, trig[1] + trig[3] * 0.5), at: 0.06)
        for i in 1...60 { rt.frame(at: 0.06 + Double(i) / 60.0) }
        #expect(rt.state.select && rt.state.dialog)

        let panel = try #require(rt.elements().first { $0.key == "dialog-dialog" } as ElementInfo?).rect
        let opt = try #require(rt.elements().first { $0.key == "option1" } as ElementInfo?)
        #expect(!opt.inert)
        let ox = opt.rect[0] + opt.rect[2] * 0.5
        let oy = opt.rect[1] + opt.rect[3] * 0.5
        let outsideX = ox < panel[0] || ox > (panel[0] + panel[2])
        let outsideY = oy < panel[1] || oy > (panel[1] + panel[3])
        #expect(outsideX || outsideY)
        rt.pointerDown(at: Vec2(ox, oy), at: 1.1)
        rt.pointerUp(at: Vec2(ox, oy), at: 1.11)
        rt.frame(at: 1.12)
        #expect(rt.state.value == "Second")
        #expect(rt.state.dialog && !rt.state.select)
    }

    // MARK: - Select & Dialog (select_keyboard.rs, dialog_select.rs)

    @Test("Select opens on current value and chooses or dismisses from keyboard and scrim")
    func selectKeyboardAndScrim() {
        struct S { var open = false; var value = "Banana" }
        let k = Kit.neutral(dark: true)
        let rt = Runtime(state: S(), viewport: Vec2(400, 300), systemDark: true) { s, cx in
            var layer: [El<S>] = []
            let sel = Select<S>("fruit", options: ["Apple", "Banana", "Cherry"])
                .current(s.value)
                .appearance(.field)
                .width(120)
                .open(s.open)
                .onToggle { s in s.open.toggle() }
                .onClose { s in s.open = false }
                .onChoose { s, v, _ in
                    s.value = v
                    s.open = false
                }
                .build(kit: k, layer: &layer, cx: cx)
            return RuneKit.root(col().wFull().hFull().child(sel), layer)
        }
        rt.frame(at: 0.0)

        func press(_ key: Key, at t: Double = 0.1) {
            _ = rt.keyDown(KeyEvent(key: key, mods: .none), at: t)
            rt.frame(at: t + 1.0 / 60.0)
        }
        func focusedKey() -> String? { rt.elements().first(where: \.focused)?.key }

        press(.tab)
        #expect(focusedKey() == "fruit-trigger")
        press(.arrowDown)
        #expect(rt.state.open)
        #expect(focusedKey() == "option1")

        press(.arrowDown)
        press(.tab)
        #expect(focusedKey() == "option2")

        press(.escape)
        #expect(!rt.state.open)
        #expect(rt.state.value == "Banana")
        #expect(focusedKey() == "fruit-trigger")

        press(.space)
        #expect(rt.state.open)
        press(.text("c"))
        press(.enter)
        #expect(rt.state.value == "Cherry")
        #expect(!rt.state.open)
        #expect(focusedKey() == "fruit-trigger")

        press(.arrowUp)
        #expect(rt.state.open)
        rt.pointerDown(at: Vec2(390, 290), at: 0.5)
        rt.pointerUp(at: Vec2(390, 290), at: 0.51)
        rt.frame(at: 0.55)
        #expect(!rt.state.open)
        #expect(rt.state.value == "Cherry")
    }

    @Test("Fit dialog sizes to its content while standard dialog uses 368pt and dismisses")
    func dialogFitAndStandardAndDismiss() {
        struct DState { var fit: Bool; var open = true }
        let k = Kit.neutral(dark: true)

        func rect(fit: Bool, key: String) -> [Float] {
            let rt = Runtime(state: DState(fit: fit), viewport: Vec2(1000, 800), systemDark: true) { s, _ in
                var layer: [El<DState>] = []
                let buttons: El<DState> = row().key("buttons").wFull().p(16).justifyEnd().child(el().size(80, 28))
                var d = Dialog<DState>("delete", "Delete session")
                    .description("Delete session \"x\"?")
                    .width(400)
                    .open(s.open)
                    .onClose { s in s.open = false }
                    .child(buttons)
                if s.fit { d = d.fit() }
                d.build(kit: k, layer: &layer)
                return RuneKit.root(el().wFull().hFull(), layer)
            }
            for i in 0..<60 { rt.frame(at: Double(i) / 60.0) }
            return rt.elements().first { $0.key == key }!.rect
        }

        let stdRect = rect(fit: false, key: "delete-dialog")
        #expect(abs(stdRect[3] - 368.0) < 0.5)

        let fitPanel = rect(fit: true, key: "delete-dialog")
        let buttons = rect(fit: true, key: "buttons")
        #expect(fitPanel[3] < 200.0)
        #expect(abs(fitPanel[0] - (1000.0 - 400.0) / 2.0) < 0.5)
        #expect(abs(fitPanel[1] - (800.0 - fitPanel[3]) / 2.0) < 0.5)
        #expect(abs((buttons[1] + buttons[3]) - (fitPanel[1] + fitPanel[3])) < 0.5)

        // Outside scrim dismisses when clickOutside is true and ignores when false
        for allowOutside in [true, false] {
            let rt = Runtime(state: DState(fit: true), viewport: Vec2(1000, 800), systemDark: true) { s, _ in
                var layer: [El<DState>] = []
                Dialog<DState>("delete", "Delete session")
                    .open(s.open)
                    .clickOutside(allowOutside)
                    .onClose { s in s.open = false }
                    .build(kit: k, layer: &layer)
                return RuneKit.root(el().wFull().hFull(), layer)
            }
            rt.frame(at: 0.0)
            rt.pointerDown(at: Vec2(20, 20), at: 0.1)
            rt.pointerUp(at: Vec2(20, 20), at: 0.11)
            rt.frame(at: 0.12)
            #expect(rt.state.open == !allowOutside)
            _ = rt.keyDown(KeyEvent(key: .escape, mods: .none), at: 0.2)
            rt.frame(at: 0.21)
            #expect(!rt.state.open)
        }
    }

    // MARK: - Menu, ContextMenu & List (context_menu.rs, menu_description.rs, menu_open.rs, list_keyboard.rs)

    @Test(
        "Context menu opens at pointer inside viewport and closes on item click",
        .disabled("Blocked on @el: 512KB worker-thread SIGBUS in Runtime.walk fixed in gap/el (#204)")
    )
    func contextMenuOpensAtPointerAndStaysInsideViewport() {
        struct S { var point: PointerPress? = nil }
        let k = Kit.neutral(dark: true)
        let rt = Runtime(state: S(), viewport: Vec2(300, 200), systemDark: true) { s, cx in
            let trigger: El<S> = el().size(300, 200).onSecondaryClick { st, p, _ in st.point = p }
            var layer: [El<S>] = []
            let body = contextMenu("context", trigger: trigger, at: s.point)
                .item(MenuItem<S>("Copy").onSelect { st in st.point = nil })
                .onClose { st in st.point = nil }
                .build(kit: k, layer: &layer, cx: cx)
            return RuneKit.root(body, layer)
        }
        rt.frame(at: 0.0)
        rt.pointerDown(at: Vec2(290, 190), button: .secondary, at: 0.1)
        rt.pointerUp(at: Vec2(290, 190), button: .secondary, at: 0.11)
        rt.frame(at: 0.12)
        for i in 1...60 { rt.frame(at: 0.12 + Double(i) / 120.0) }

        let menu = rt.elements().first { $0.key == "context-menu" }!
        #expect(menu.rect[0] >= 0 && menu.rect[1] >= 0)
        #expect(menu.rect[0] + menu.rect[2] <= 300.01)
        #expect(menu.rect[1] + menu.rect[3] <= 200.01)

        let item = rt.elements().first { $0.key == "context-item0" }!.rect
        rt.pointerDown(at: Vec2(item[0] + item[2] * 0.5, item[1] + item[3] * 0.5), at: 1.0)
        rt.pointerUp(at: Vec2(item[0] + item[2] * 0.5, item[1] + item[3] * 0.5), at: 1.01)
        rt.frame(at: 1.02)
        #expect(rt.state.point == nil)
    }

    @Test(
        "Menus and submenus open on the next frame and fade only on close (tests/menu_open.rs)",
        .disabled("Blocked on @el: 512KB worker-thread SIGBUS in Runtime.walk fixed in gap/el (#204)")
    )
    func menusAndSubmenusOpenOnNextFrameAndFadeOnlyOnClose() throws {
        struct MState { var open = false; var sub = false }
        let k = Kit.neutral(dark: true)
        let rt = Runtime(state: MState(), viewport: Vec2(400, 300), systemDark: true) { s, cx in
            var layer: [El<MState>] = []
            let body = Menu<MState>("file")
                .trigger(text("File"))
                .item(MenuItem<MState>("Copy"))
                .item(MenuItem<MState>("More").submenu([.item(MenuItem<MState>("Deeper"))], open: s.sub))
                .open(s.open)
                .build(kit: k, layer: &layer, cx: cx)
            return RuneKit.root(col().wFull().hFull().child(body), layer)
        }
        rt.frame(at: 0.0)
        rt.state.open = true
        rt.markNeedsCommit()
        rt.frame(at: 1.0 / 120.0)
        let menu = try #require(rt.elements().first { $0.key == "file-menu" })
        #expect(menu.opacity > 0.9)

        rt.state.open = false
        rt.state.sub = false
        rt.markNeedsCommit()
        rt.frame(at: 0.02)
        rt.frame(at: 0.12)
        for i in 1...60 { rt.frame(at: 0.12 + Double(i) / 60.0) }
        #expect(rt.elements().first { $0.key == "file-menu" } == nil)
    }

    @Test(
        "Described MenuItem grows to show second description line and Menu opens submenus",
        .disabled("Blocked on @el: 512KB worker-thread SIGBUS in Runtime.walk fixed in gap/el (#204)")
    )
    func menuDescriptionAndSubmenu() throws {
        struct S { var open = true; var sub = false }
        let k = Kit.neutral(dark: true)
        let rt = Runtime(state: S(), viewport: Vec2(480, 320), systemDark: true) { s, cx in
            var layer: [El<S>] = []
            let body = Menu<S>("pick")
                .trigger(text("Pick"))
                .item(MenuItem<S>("Off").checked(false))
                .item(MenuItem<S>("Here").description("Nothing leaves this computer").checked(true))
                .item(MenuItem<S>("More").submenu([.item(MenuItem<S>("Deeper"))], open: s.sub))
                .open(s.open)
                .onClose { st in st.open = false; st.sub = false }
                .build(kit: k, layer: &layer, cx: cx)
            return RuneKit.root(col().wFull().hFull().child(body), layer)
        }
        rt.frame(at: 0.0)
        let plain = try #require(rt.elements().first { $0.key == "pick-item0" })
        let described = try #require(rt.elements().first { $0.key == "pick-item1" })
        #expect(abs(plain.rect[3] - 28.0) < 0.5)
        #expect(described.rect[3] > plain.rect[3])
        let descLine = try #require(rt.elements().first {
            $0.path.hasPrefix(described.path + "/") && $0.key == "description"
        })
        let lbl = try #require(rt.elements().first {
            $0.path.hasPrefix(described.path + "/") && $0.key == "label"
        })
        #expect(descLine.rect[1] >= lbl.rect[1] + lbl.rect[3])
        #expect(descLine.rect[1] + descLine.rect[3] <= described.rect[1] + described.rect[3])

        rt.state.sub = true
        rt.markNeedsCommit()
        rt.frame(at: 0.1)
        #expect(rt.elements().contains { $0.key == "pick-item2-sub-menu" })
        _ = rt.keyDown(KeyEvent(key: .escape, mods: .none), at: 0.2)
        rt.frame(at: 0.21)
        #expect(!rt.state.open)
    }

    @Test("List rows navigate with arrows, activate with Enter, and plain rows stay out of focus")
    func listKeyboardAndPlain() {
        struct S { var picked: Int? = nil }
        let k = Kit.neutral(dark: true)

        let rt = Runtime(state: S(), viewport: Vec2(400, 400), systemDark: true) { s, _ in
            var list = List<S>().active(nil)
            for (i, name) in ["One", "Two", "Three"].enumerated() {
                list = list.item(
                    ListItem<S>(name)
                        .selected(s.picked == i)
                        .onSelect { st, _ in st.picked = i }
                )
            }
            return col().wFull().child(
                row().key("before").role(.button).label("Before").size(40, 20).focusable(true).onClick { _, _ in }
            ).child(list.build(kit: k))
        }
        rt.frame(at: 0.0)

        func press(_ key: Key, at t: Double = 0.1) {
            _ = rt.keyDown(KeyEvent(key: key, mods: .none), at: t)
            rt.frame(at: t + 1.0 / 60.0)
        }
        func focusedKey() -> String? { rt.elements().first(where: \.focused)?.key }

        press(.tab)
        #expect(focusedKey() == "before")
        press(.tab)
        #expect(focusedKey() == "item0")
        press(.arrowDown)
        press(.arrowDown)
        #expect(focusedKey() == "item2")
        press(.enter)
        #expect(rt.state.picked == 2)

        let plainRt = Runtime(state: S(), viewport: Vec2(400, 400), systemDark: true) { _, _ in
            List<S>().item(ListItem<S>("Only")).build(kit: k)
        }
        plainRt.frame(at: 0.0)
        _ = plainRt.keyDown(KeyEvent(key: .tab, mods: .none), at: 0.1)
        plainRt.frame(at: 0.12)
        #expect(plainRt.elements().first(where: \.focused) == nil)
    }

    @Test(
        "List focusGroup acts as one tab stop and re-enters on selected item",
        .disabled("Blocked on @el: focusGroup single-tab-stop and .itemSelected re-entry in Runtime.advanceTabFocus")
    )
    func listFocusGroupSingleTabStopReentry() {
        struct S { var picked: Int? = nil }
        let k = Kit.neutral(dark: true)

        let rt = Runtime(state: S(), viewport: Vec2(400, 400), systemDark: true) { s, _ in
            var list = List<S>().active(nil)
            for (i, name) in ["One", "Two", "Three"].enumerated() {
                list = list.item(
                    ListItem<S>(name)
                        .selected(s.picked == i)
                        .onSelect { st, _ in st.picked = i }
                )
            }
            return col().wFull().child(
                row().key("before").role(.button).label("Before").size(40, 20).focusable(true).onClick { _, _ in }
            ).child(list.build(kit: k))
        }
        rt.frame(at: 0.0)

        func press(_ key: Key, at t: Double = 0.1) {
            _ = rt.keyDown(KeyEvent(key: key, mods: .none), at: t)
            rt.frame(at: t + 1.0 / 60.0)
        }
        func focusedKey() -> String? { rt.elements().first(where: \.focused)?.key }

        press(.tab)
        press(.tab)
        press(.arrowDown)
        press(.arrowDown)
        press(.enter)
        press(.tab)
        #expect(focusedKey()?.hasPrefix("item") != true)
        press(.tab)
        #expect(focusedKey() == "item2")
    }
}
