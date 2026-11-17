import Foundation
import Testing
@testable import RuneKit
@testable import Rune

@MainActor
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

    @Test("Popover close restores trigger focus before exit finishes")
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

    @Test("Popover anchored mounts beside its trigger (`popover_tests.rs:32`)")
    func anchoredMountsBesideTrigger() throws {
        struct Empty {}
        let k = Kit.neutral(dark: true)
        let rt = Runtime(state: Empty(), viewport: Vec2(400, 300), systemDark: true) { _, _ -> El<Empty> in
            let content: El<Empty> = col().w(120).h(60).child(text("Menu"))
            let surface = PopoverAnchor.raised(k, content, radius: k.radius.md)
            let layer = [PopoverAnchor.anchored(k, surface, anchor: "t", placement: .bottomStart, gap: 4.0)]
            return RuneKit.root(col().p(40).child(el().key("t").w(50).h(20)), layer)
        }
        rt.frame(at: 0.0)
        for i in 1...30 { rt.frame(at: Double(i)) }
        let trigger = try #require(rt.elements().first { $0.key == "t" }).rect
        let word = try #require(rt.elements().first { $0.text == "Menu" }).rect
        #expect(abs(word[0] - trigger[0]) < 8.0)
        #expect(word[1] >= trigger[1] + trigger[3] + 4.0)
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

    private func makeTableRuntime(_ app: TableApp, size: Vec2 = Vec2(500, 300), tableHeight: Float? = nil) -> Runtime<TableApp> {
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
                .h(tableHeight ?? size.y)
            )
        }
        rt.frame(at: 0.0)
        rt.frame(at: 1.0 / 60.0)
        return rt
    }

    private func tableHeader(_ rt: Runtime<TableApp>, _ id: String) -> ElementInfo {
        rt.elements().first { !$0.exiting && $0.key == id && $0.label != nil }!
    }

    @Test("Table state keeps distinct UTF-8 row and column IDs after reordering")
    func distinctUnicodeTableState() {
        let composed = "\u{e9}", decomposed = "e\u{301}"
        let rows = [composed, decomposed, "end"]
        var state = TableState(multi: true)
        var tx = Tx()
        _ = state.handleKey(KeyEvent(key: .command("a")), len: rows.count, idAt: { rows[$0] }, tx: &tx)
        #expect(state.selectedCount == 3 && state.selected.count == 2)
        #expect(Set(state.exactSelectedIDs.map { Array($0.utf8) }) == Set(rows.map { Array($0.utf8) }))
        state.click(row: 0, len: rows.count, mods: RuneKitTestKey.primaryMods(), idAt: { rows[$0] })
        #expect(!state.isSelected(composed) && state.isSelected(decomposed))
        state.click(row: 0, len: rows.count, mods: RuneKitTestKey.primaryMods(), idAt: { rows[$0] })
        #expect(state.selectedCount == 3)
        let reordered = [decomposed, composed, "end"]
        _ = state.handleKey(KeyEvent(key: .arrowDown), len: rows.count, idAt: { reordered[$0] }, tx: &tx)
        #expect(state.cursor == "end")
        state.reveal(decomposed, len: rows.count, idAt: { reordered[$0] }, tx: &tx)
        _ = state.handleKey(KeyEvent(key: .arrowDown, mods: Mods(shift: true)), len: rows.count,
                            idAt: { reordered[$0] }, tx: &tx)
        #expect(state.selectedCount == 2 && state.isSelected(composed) && state.isSelected(decomposed))

        state.setSort(composed, .ascending)
        #expect(state.nextSort(composed) == .descending && state.nextSort(decomposed) == .ascending)
        state.setColumnWidth(composed, 71)
        state.setColumnWidth(decomposed, 139)
        state.widths["other"] = 89
        let columns = [TableCol(composed, "A"), TableCol(decomposed, "B"), TableCol("other", "C")]
        #expect(state.resolvedColumnWidths(columns: columns, totalWidth: 500) == [71, 139, 89])
        state.resetColumnWidth(decomposed)
        #expect(state.columnWidth(composed) == 71 && state.columnWidth(decomposed) == nil)
        state.setColumnWidth(decomposed, 139)
        state.widths.removeAll()
        #expect(state.columnWidth(composed) == nil && state.columnWidth(decomposed) == nil)
        state.laidOut = [decomposed: 139]
        state.laidOut = ["other": 89]
        #expect(state.laidOut == ["other": 89])

        let kelvin = ["K", "\u{212a}"]
        state.select(kelvin[0])
        #expect(!state.isSelected(kelvin[1]))
        state.click(row: 1, len: kelvin.count, mods: RuneKitTestKey.primaryMods(), idAt: { kelvin[$0] })
        #expect(state.selectedCount == 2 && state.isSelected(kelvin[1]))
    }

    @Test("Table click, keyboard, sort, and resize callbacks retain authored UTF-8 IDs")
    func distinctUnicodeTableEvents() throws {
        let rowA = "row-\u{e9}", rowB = "row-e\u{301}"
        let colA = "col-\u{e9}", colB = "col-e\u{301}"
        let ids = [rowA, rowB]
        struct App {
            var table = TableState(multi: true)
            var picks: [String] = []
            var opened: [String] = []
            var sorts: [String] = []
        }
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(state: App(), viewport: Vec2(400, 140)) { s, cx in
            TableView<App>(\.table, len: { _ in ids.count }, rowID: { _, i in ids[i] })
                .column(TableCol(colA, "A").width(90).sortable())
                .column(TableCol(colB, "B").width(130).sortable())
                .cell { _, _, id in .text(id) }
                .onSelect { s, id, _ in s.picks.append(id) }
                .onOpen { s, id, _ in s.opened.append(id) }
                .onSort { s, id, _, _ in s.sorts.append(id) }
                .build(s, cx: cx, kit: kit).size(400, 140)
        }
        rt.frame(at: 0)
        rt.frame(at: 0.016)
        func bounds(_ id: String, _ role: ElementRole) throws -> [Float] {
            let element = try #require(rt.elements().first {
                !$0.exiting && $0.role == role && $0.key?.utf8.elementsEqual(id.utf8) == true
            })
            return element.rect
        }
        func semantic(_ id: String, _ role: ElementRole) -> AccessibilityNode? {
            var pending = [rt.accessibilitySnapshot()]
            while let node = pending.popLast() {
                if node.role == role && node.id.utf8.elementsEqual(id.utf8) { return node }
                pending.append(contentsOf: node.children)
            }
            return nil
        }
        func click(_ id: String, _ role: ElementRole, at time: Double, mods: Mods = .none) throws {
            let r = try bounds(id, role)
            let point = Vec2(r[0] + 12, r[1] + r[3] / 2)
            rt.pointerDown(at: point, mods: mods, at: time)
            rt.pointerUp(at: point, mods: mods, at: time + 0.01)
            rt.frame(at: time + 0.02)
        }
        try click(rowA, .row, at: 0.10)
        _ = rt.keyDown(KeyEvent(key: .arrowDown), at: 0.2)
        _ = rt.keyDown(KeyEvent(key: .enter), at: 0.21)
        rt.frame(at: 0.22)
        #expect(rt.state.picks.map { Array($0.utf8) } == ids.map { Array($0.utf8) })
        #expect(rt.state.opened.map { Array($0.utf8) } == [Array(rowB.utf8)])
        #expect(rt.element(byKey: rowA)?.itemSelected == false)
        #expect(rt.element(byKey: rowB)?.itemSelected == true)
        #expect(semantic("table", .grid)?.activeDescendant?.utf8.elementsEqual(rowB.utf8) == true)
        #expect(semantic(rowB, .row)?.isSelected == true)
        try click(rowA, .row, at: 0.4, mods: RuneKitTestKey.primaryMods())
        #expect(rt.state.table.selectedCount == 2)
        try click(colA, .columnHeader, at: 0.6)
        try click(colB, .columnHeader, at: 0.8)
        #expect(rt.state.sorts.map { Array($0.utf8) } == [Array(colA.utf8), Array(colB.utf8)])
        #expect(rt.state.table.sort?.1 == .ascending)
        #expect(semantic(colA, .columnHeader)?.sortAscending == nil)
        #expect(semantic(colB, .columnHeader)?.sortAscending == true)
        #expect(semantic(colA, .gridCell) != nil && semantic(colB, .gridCell) != nil)
        let handle = try bounds(colB + "-resize", .splitter)
        let start = Vec2(handle[0] + handle[2] / 2, handle[1] + handle[3] / 2)
        rt.pointerDown(at: start, at: 1.0)
        rt.pointerMove(to: Vec2(start.x + 20, start.y), at: 1.05)
        rt.frame(at: 1.06)
        rt.pointerUp(at: Vec2(start.x + 20, start.y), at: 1.1)
        rt.frame(at: 1.11)
        #expect(rt.state.table.columnWidth(colA) == nil)
        #expect(rt.state.table.columnWidth(colB) == 150)
        let a = try bounds(colA, .columnHeader), b = try bounds(colB, .columnHeader)
        #expect(a[2] == 90 && b[2] == 150)
    }

    @Test("A horizontally scrolling parent keeps the header aligned with virtual rows")
    func tableHeaderTracksHorizontalParent() throws {
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(state: TableApp(n: 500, multi: false), viewport: Vec2(220, 170)) { s, cx in
            col().key("outer").size(220, 170).scrollX().child(
                TableView<TableApp>(\.table, len: { $0.files.count }, rowID: { $0.files[$1].id })
                    .column(TableCol("name", "Name").width(280))
                    .column(TableCol("size", "Size").width(100))
                    .cell { _, _, _ in .text("X") }
                    .build(s, cx: cx, kit: kit)
                    .size(380, 170)
            )
        }
        rt.frame(at: 0)
        rt.update(at: 0.05) { _, tx in tx.scrollTo("outer", offset: Vec2(160, 0), animated: false) }
        rt.frame(at: 0.06)
        let header = tableHeader(rt, "size")
        let cell = try #require(rt.elements().first { $0.role == .gridCell && $0.key == "size" })
        #expect(rt.scrollOffset(forKey: "outer").x == 160)
        #expect(header.rect[0] == 120)
        #expect(cell.rect[0] == header.rect[0])
        #expect(cell.rect[2] == header.rect[2])
    }

    @Test("Scrolling an unchanged table builds only newly mounted cells")
    func tableReusesRowsDuringWheelScroll() {
        let kit = Kit.neutral(dark: true)
        var viewBuilds = 0
        var cellBuilds = 0
        let rt = Runtime(state: TableApp(n: 1_000, multi: false), viewport: Vec2(500, 300)) { state, cx in
            viewBuilds += 1
            return TableView<TableApp>(\.table, len: { $0.files.count }, rowID: { $0.files[$1].id })
                .column(TableCol("name", "Name"))
                .cell { state, index, _ in
                    cellBuilds += 1
                    return .text(state.files[index].name)
                }
                .zebra(true)
                .build(state, cx: cx, kit: kit)
                .size(500, 300)
        }
        for frame in 0..<12 { rt.frame(at: Double(frame) / 60) }
        viewBuilds = 0
        cellBuilds = 0
        for frame in 12..<24 {
            let time = Double(frame) / 60
            rt.wheel(WheelEvent(dx: 0, dy: -48), at: Vec2(170, 140), now: time)
            rt.frame(at: time)
        }
        #expect(viewBuilds == 0)
        // Twelve wheel ticks advance just over twenty rows. Allow an extra half viewport to fill.
        #expect((1...30).contains(cellBuilds))
        #expect((rt.element(byKey: "f21")?.visible[3] ?? 0) == 28)
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
            !$0.exiting && $0.key == "size" && $0.role == .gridCell
        }
        #expect(!bodySizeCells.isEmpty)
        for c in bodySizeCells {
            #expect(abs(c.rect[0] - size.rect[0]) < 0.5)
            #expect(abs(c.rect[2] - size.rect[2]) < 0.5)
        }

        // Column min/max clamping (`table.rs:804`)
        let c = TableCol("a", "A").min(60).max(200)
        #expect(c.clamp(10) == 60)
        #expect(c.clamp(120) == 120)
        #expect(c.clamp(900) == 200)
        let odd = TableCol("b", "B").min(80).max(40)
        #expect(odd.clamp(10) == 80)
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
        func sortAscending(_ column: String) -> Bool? {
            var nodes = [rt.accessibilitySnapshot()]
            while let node = nodes.popLast() {
                if node.role == .columnHeader && node.id == column { return node.sortAscending }
                nodes.append(contentsOf: node.children)
            }
            return nil
        }
        let sizeRect = tableHeader(rt, "size").rect
        let cx = sizeRect[0] + 20.0
        let cy = sizeRect[1] + sizeRect[3] * 0.5
        rt.pointerDown(at: Vec2(cx, cy), at: 0.1)
        rt.pointerUp(at: Vec2(cx, cy), at: 0.11)
        rt.frame(at: 0.12)

        #expect(rt.state.sorts.count == 1)
        #expect(rt.state.sorts[0].0 == "size" && rt.state.sorts[0].1 == .ascending)
        #expect(rt.state.table.sort?.0 == "size" && rt.state.table.sort?.1 == .ascending)
        #expect(sortAscending("size") == true)
        for i in 1..<rt.state.files.count {
            #expect(rt.state.files[i - 1].size <= rt.state.files[i].size)
        }

        rt.pointerDown(at: Vec2(cx, cy), at: 0.2)
        rt.pointerUp(at: Vec2(cx, cy), at: 0.21)
        rt.frame(at: 0.22)
        #expect(rt.state.table.sort?.0 == "size" && rt.state.table.sort?.1 == .descending)
        #expect(sortAscending("size") == false)
        #expect(sortAscending("name") == nil)

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
        _ = rt.keyDown(KeyEvent(key: .enter, mods: .none), isRepeat: true, at: 1.05)
        rt.frame(at: 1.06)
        #expect(rt.state.opened == ["f199"])
        send(.home, at: 1.1)
        #expect(rt.state.table.selected == ["f0"])
    }

    @Test("A short table pages by its body height and reveals an unmounted ID after a same-count reorder")
    func tablePagesInsideItsViewportAndRevealsReorderedID() throws {
        let rt = makeTableRuntime(TableApp(n: 500, multi: false), size: Vec2(500, 900), tableHeight: 170)
        let viewport = try #require(rt.element(byKey: "table-viewport"))
        #expect(rt.state.table.viewport == viewport.rect[3])
        #expect(viewport.rect[3] == 140)
        _ = rt.keyDown(KeyEvent(key: .tab, mods: .none), at: 0.1)
        _ = rt.keyDown(KeyEvent(key: .home, mods: .none), at: 0.11)
        _ = rt.keyDown(KeyEvent(key: .pageDown, mods: .none), at: 0.12)
        rt.frame(at: 0.13)
        #expect(rt.state.table.cursor == "f4")

        rt.update(at: 0.2) { state, _ in state.files.reverse() }
        rt.frame(at: 0.21)
        #expect(rt.element(byKey: "f0") == nil)
        rt.update(at: 0.25) { state, tx in state.table.reveal("f0", tx: &tx) }
        for i in 1...60 { rt.frame(at: 0.25 + Double(i) / 60) }
        let selected = try #require(rt.element(byKey: "f0"))
        #expect(selected.itemSelected)
        #expect(selected.visible[3] > 27)
        #expect(rt.element(byKey: "header")?.rect[1] == 0)
    }

    @Test("Multi-select table extends with Shift, toggles rows and selects all with the primary modifier")
    func multiSelectShiftExtendsAndCmdASelectsAll() throws {
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

        let row = try #require(rt.element(byKey: "f1")).rect
        let point = Vec2(row[0] + 12, row[1] + row[3] * 0.5)
        let primary = RuneKitTestKey.primaryMods()
        rt.pointerDown(at: point, mods: primary, at: 0.18)
        rt.pointerUp(at: point, mods: primary, at: 0.19)
        rt.frame(at: 0.20)
        #expect(rt.state.table.selected.sorted() == ["f0", "f2"])
        _ = rt.keyDown(KeyEvent(key: .text("a"), mods: primary), at: 0.21)
        rt.frame(at: 0.22)
        #expect(rt.state.table.selectedCount == 30)
        rt.update(at: 0.23) { state, _ in state.table.select("f0") }
        #expect(rt.keyDown(KeyEvent(key: .command("a"), mods: .none), at: 0.24))
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
        let builtRows = rt100k.elements().filter { !$0.exiting && $0.role == .row }.count
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
            onKey: { state, ev, _ in
                if ev.key == .tab { return false }
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

    @Test("Combobox opening takes focus and reveals offscreen selection")
    func comboboxOpeningTakesFocusAndRevealsOffscreenSelection() throws {
        var s = ComboApp()
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
        rt.frame(at: 0.13)

        #expect(rt.state.combo.isOpen)
        #expect(rt.elements().first(where: \.focused)?.key == "models-search")

        let last = rt.elements().first { $0.key == "models-option-item-199" }
        #expect((last?.visible[3] ?? 0) > 0)

        _ = rt.keyDown(KeyEvent(key: .text("099"), mods: .none), at: 0.2)
        rt.frame(at: 0.21)
        #expect(rt.state.combo.search.text == "099")
    }

    @Test("Combobox opening commits and clears prior TextEdit preedit on intra-window focus transfer")
    func comboboxOpeningClearsPriorPreedit() throws {
        var s = ComboApp()
        s.chosen = "item-199"
        let rt = makeComboRuntime(s, open: false)

        _ = rt.keyDown(KeyEvent(key: .tab, mods: .none), at: 0.05)
        rt.frame(at: 0.06)
        #expect(rt.elements().first(where: \.focused)?.key == "other")

        _ = rt.dispatchImeEvent(.preedit("pending", cursorUTF8: 7..<7, clauses: []), at: 0.08)
        rt.frame(at: 0.09)
        #expect(rt.state.other.preedit?.text == "pending")

        let trig = try #require(rt.elements().first { $0.key == "models-value-trigger" }).rect
        let cx = trig[0] + trig[2] * 0.5
        let cy = trig[1] + trig[3] * 0.5
        rt.pointerDown(at: Vec2(cx, cy), at: 0.1)
        rt.pointerUp(at: Vec2(cx, cy), at: 0.11)
        rt.frame(at: 0.12)
        rt.frame(at: 0.13)

        #expect(rt.state.combo.isOpen)
        #expect(rt.elements().first(where: \.focused)?.key == "models-search")
        #expect(rt.state.other.preedit == nil)

        _ = rt.keyDown(KeyEvent(key: .text("099"), mods: .none), at: 0.2)
        rt.frame(at: 0.21)
        #expect(rt.state.combo.search.text == "099")
        #expect(rt.state.other.text == "pending")
    }

    @Test("Combobox loops skipping disabled, virtualizes rows, and handles IME/Escape/Scrim focus")
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
        // Alt+ArrowDown preserves editor modifier and does not change combo selection
        let prevActive = rt.state.combo.active
        send(.arrowDown, mods: Mods(alt: true))
        #expect(rt.state.combo.active == prevActive)
        send(.arrowUp)
        send(.arrowUp)
        rt.frame(at: 0.22)
        #expect(rt.state.combo.active == "item-199")
        let last = rt.elements().first { $0.key == "models-option-item-199" }
        #expect((last?.visible[3] ?? 0) > 0)

        send(.enter)
        #expect(rt.state.chosen == "item-199")
        #expect(!rt.state.combo.isOpen)
        let triggerAfterEnter = try #require(rt.elements().first(where: { $0.focused }))
        #expect(triggerAfterEnter.key == "models-value-trigger")

        send(.space)
        #expect(rt.state.combo.isOpen)
        #expect(rt.elements().first(where: { $0.focused })?.key == "models-search")
        send(.escape)
        #expect(!rt.state.combo.isOpen)
        #expect(rt.state.appKeys == 0, "Enter/Space/arrows/Escape belong to the control")
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
        let triggerAfterScrim = try #require(rt.elements().first(where: { $0.focused }))
        #expect(triggerAfterScrim.key == "models-value-trigger")

        // Upstream `tests/combobox.rs:91`: Up to scroll end, filter "099", Alt+Down leaves active nil, preedit Enter stays open, Escape closes.
        let rt2 = makeComboRuntime()
        _ = rt2.keyDown(KeyEvent(key: .arrowUp, mods: .none), at: 0.1)
        rt2.frame(at: 0.11)
        _ = rt2.keyDown(KeyEvent(key: .text("099"), mods: .none), at: 0.15)
        rt2.frame(at: 0.16)
        #expect(rt2.elements().contains { $0.key == "models-option-item-99" })
        #expect(rt2.state.combo.search.text == "099")
        _ = rt2.keyDown(KeyEvent(key: .arrowDown, mods: Mods(alt: true)), at: 0.2)
        rt2.frame(at: 0.21)
        #expect(rt2.state.combo.active == nil)
        _ = rt2.dispatchImeEvent(.preedit("x", cursorUTF8: 1..<1, clauses: []), at: 0.25)
        rt2.frame(at: 0.26)
        _ = rt2.keyDown(KeyEvent(key: .enter, mods: .none), at: 0.3)
        rt2.frame(at: 0.31)
        #expect(rt2.state.combo.isOpen && rt2.state.chosen == nil)
        _ = rt2.dispatchImeEvent(.preedit("", cursorUTF8: 0..<0, clauses: []), at: 0.35)
        rt2.frame(at: 0.36)
        _ = rt2.keyDown(KeyEvent(key: .escape, mods: .none), at: 0.4)
        rt2.frame(at: 0.41)
        #expect(!rt2.state.combo.isOpen)
    }

    @Test("Combobox unhandled key modal bubbling & focusVisible return (tests/combobox.rs:108)")
    func comboboxModalKeyBubblingAndFocusVisible() throws {
        let rt = makeComboRuntime()
        func send(_ key: Key, mods: Mods = .none, at t: Double = 0.2) {
            _ = rt.keyDown(KeyEvent(key: key, mods: mods), at: t)
            rt.frame(at: t + 0.01)
        }
        send(.f(5))
        #expect(rt.state.appKeys == 1)
        send(.enter, at: 0.25)
        let triggerAfterEnter = try #require(rt.elements().first(where: { $0.focused }))
        #expect(triggerAfterEnter.focusVisible)
        send(.space, at: 0.3)
        rt.pointerDown(at: Vec2(390, 390), at: 0.35)
        rt.pointerUp(at: Vec2(390, 390), at: 0.36)
        rt.frame(at: 0.37)
        let triggerAfterScrim = try #require(rt.elements().first(where: { $0.focused }))
        #expect(!triggerAfterScrim.focusVisible)
    }

    @Test("Closing a scrolled virtual Combobox keeps rows in place while fading (tests/combobox.rs:61)")
    func comboboxClosingScrolledPopupKeepsRowsInPlaceWhileFading() throws {
        let rt = makeComboRuntime()
        let searchRect = try #require(rt.elements().first { $0.key == "models-search" }).rect
        rt.pointerDown(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.05)
        rt.pointerUp(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.06)
        rt.frame(at: 0.07)

        var t = 0.1
        _ = rt.keyDown(KeyEvent(key: .arrowUp), at: t)
        for _ in 0..<60 {
            t += 1.0 / 60.0
            rt.frame(at: t)
        }
        let before = try #require(rt.elements().first { $0.key == "models-option-item-199" })
        _ = rt.keyDown(KeyEvent(key: .escape), at: t + 0.01)
        rt.frame(at: t + 1.0 / 60.0)
        let after = try #require(rt.elements().first { $0.key == before.key })
        #expect(abs(after.rect[1] - before.rect[1]) < 5.0)
        #expect(after.opacity > 0.0 && after.opacity < before.opacity)
        #expect(after.visible[3] > 0.0)
    }

    @Test("Combobox animateFiltering springs popup height, fades leaving rows, and crossfades rows in view (tests/combobox.rs:202,259)")
    func comboboxAnimateFilteringSpringsHeightAndCrossfades() throws {
        var s = ComboApp()
        s.animate = true
        let rt = makeComboRuntime(s)
        let searchRect = try #require(rt.elements().first { $0.key == "models-search" }).rect
        rt.pointerDown(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.01)
        rt.pointerUp(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.02)
        var t = 0.03
        for _ in 0..<60 {
            t += 1.0 / 60.0
            rt.frame(at: t)
        }
        let openH = try #require(rt.elements().first { $0.key == "models-content" }).rect[3]
        _ = rt.keyDown(KeyEvent(key: .text("199")), at: t)
        t += 1.0 / 60.0
        rt.frame(at: t)
        let gone = try #require(rt.elements().first { $0.key == "models-option-item-0" })
        #expect(gone.opacity > 0.0 && gone.opacity < 1.0)

        _ = rt.keyDown(KeyEvent(key: .text("zz")), at: t)
        var last = try #require(rt.elements().first { $0.key == "models-content" }).rect[3]
        for _ in 0..<120 {
            t += 1.0 / 120.0
            rt.frame(at: t)
            let h = try #require(rt.elements().first { $0.key == "models-content" }).rect[3]
            #expect(abs(h - last) < 20.0)
            last = h
        }
        #expect(last < openH - 100.0)
        #expect(rt.elements().first { $0.key == "empty" }?.opacity == 1.0)
    }

    @Test("Typing while scrolled to end crossfades Combobox rows in view (tests/combobox.rs:259)")
    func comboboxTypingCrossfadesRowsInView() throws {
        var s = ComboApp()
        s.animate = true
        let rt = makeComboRuntime(s)
        let searchRect = try #require(rt.elements().first { $0.key == "models-search" }).rect
        rt.pointerDown(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.01)
        rt.pointerUp(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.02)
        var t = 0.03
        for _ in 0..<60 { t += 1.0 / 60.0; rt.frame(at: t) }
        _ = rt.keyDown(KeyEvent(key: .arrowUp), at: t)
        for _ in 0..<60 { t += 1.0 / 60.0; rt.frame(at: t) }

        func rowInfo(_ id: String) -> (top: Float, opacity: Float, exiting: Bool)? {
            guard let vp = rt.elements().first(where: { $0.key == "models-viewport" })?.rect,
                  let e = rt.elements().first(where: { $0.key == "models-option-\(id)" })
            else { return nil }
            return (e.rect[1] - vp[1], e.opacity, e.exiting)
        }

        _ = rt.keyDown(KeyEvent(key: .text("0")), at: t)
        rt.frame(at: t)
        let first = try #require(rowInfo("item-0"))
        #expect(abs(first.top) < 0.5 && first.opacity < 0.05)
        for _ in 0..<4 { t += 1.0 / 120.0; rt.frame(at: t) }
        let below = try #require(rowInfo("item-7"))
        #expect(below.top > 190.0)

        let stood = try #require(rowInfo("item-2")).top
        _ = rt.keyDown(KeyEvent(key: .text("9")), at: t)
        rt.frame(at: t)
        let dropped = try #require(rowInfo("item-2"))
        #expect(dropped.exiting && abs(dropped.top - stood) < 0.5)
        let nextFirst = try #require(rowInfo("item-90"))
        #expect(abs(nextFirst.top) < 0.5 && nextFirst.opacity < 0.05)
        for _ in 0..<4 { t += 1.0 / 120.0; rt.frame(at: t) }
        _ = rt.keyDown(KeyEvent(key: .text("9")), at: t)
        rt.frame(at: t)
        let movedUp = try #require(rowInfo("item-99"))
        #expect(abs(movedUp.top) < 0.5)
    }

    @Test("Offscreen Combobox matches skip enter fade & entering matches re-fade on scroll/filter (tests/combobox.rs:259)")
    func comboboxUnseenPresenceCrossfade() throws {
        var s = ComboApp()
        s.animate = true
        let rt = makeComboRuntime(s)
        let searchRect = try #require(rt.elements().first { $0.key == "models-search" }).rect
        rt.pointerDown(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.01)
        rt.pointerUp(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.02)
        var t = 0.03
        for _ in 0..<60 { t += 1.0 / 60.0; rt.frame(at: t) }
        _ = rt.keyDown(KeyEvent(key: .arrowUp), at: t)
        for _ in 0..<60 { t += 1.0 / 60.0; rt.frame(at: t) }
        func rowInfo(_ id: String) -> (top: Float, opacity: Float, exiting: Bool)? {
            guard let vp = rt.elements().first(where: { $0.key == "models-viewport" })?.rect,
                  let e = rt.elements().first(where: { $0.key == "models-option-\(id)" })
            else { return nil }
            return (e.rect[1] - vp[1], e.opacity, e.exiting)
        }
        _ = rt.keyDown(KeyEvent(key: .text("0")), at: t)
        rt.frame(at: t)
        for _ in 0..<4 { t += 1.0 / 120.0; rt.frame(at: t) }
        let below = try #require(rowInfo("item-7"))
        #expect(below.top > 190.0 && below.opacity == 1.0)
        _ = rt.keyDown(KeyEvent(key: .text("9")), at: t)
        rt.frame(at: t)
        for _ in 0..<4 { t += 1.0 / 120.0; rt.frame(at: t) }
        _ = rt.keyDown(KeyEvent(key: .text("9")), at: t)
        rt.frame(at: t)
        let movedUp = try #require(rowInfo("item-99"))
        #expect(abs(movedUp.top) < 0.5 && movedUp.opacity < 0.05)
    }

    @Test("Combobox keystroke filter shrinks empty state, restores on backspace, and fits custom trigger inside viewport (tests/combobox.rs)")
    func comboboxKeystrokeFilterAndCustomTriggerFit() throws {
        // Keystroke filtering -> empty shrink -> backspace restore
        let rt = makeComboRuntime()
        let searchRect = try #require(rt.elements().first { $0.key == "models-search" }).rect
        rt.pointerDown(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.05)
        rt.pointerUp(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.06)
        rt.frame(at: 0.07)

        let openH = try #require(rt.elements().first { $0.key == "models-content" }).rect[3]
        _ = rt.keyDown(KeyEvent(key: .text("zz"), mods: .none), at: 0.1)
        for i in 1...60 { rt.frame(at: 0.1 + Double(i) / 60.0) }
        let emptyH = try #require(rt.elements().first { $0.key == "models-content" }).rect[3]
        #expect(emptyH < openH - 100.0)
        #expect(rt.elements().contains { $0.key == "empty" && $0.opacity == 1.0 })

        _ = rt.keyDown(KeyEvent(key: .backspace, mods: .none), at: 1.2)
        _ = rt.keyDown(KeyEvent(key: .backspace, mods: .none), at: 1.21)
        for i in 1...60 { rt.frame(at: 1.21 + Double(i) / 60.0) }
        let restoredH = try #require(rt.elements().first { $0.key == "models-content" }).rect[3]
        #expect(abs(restoredH - openH) < 1.0)

        // Custom trigger + maxHeight(2000) fits window viewport and opens search + reveals item-199
        let options = (0..<200).map { ComboboxItem(id: "item-\($0)", label: String(format: "Model %03d", $0)) }
        let kit = Kit.neutral(dark: true)
        let rtCustom = Runtime(state: ComboApp(), viewport: Vec2(400, 300), systemDark: true) { s, cx in
            var layer: [El<ComboApp>] = []
            let trigger: El<ComboApp> = row().key("custom").size(120, 28).focusable(true).child(text("Pick"))
            let cb = Combobox<ComboApp>("models", state: \.combo, options: options)
                .trigger(trigger)
                .maxHeight(2000)
                .build(s, kit: kit, layer: &layer, cx: cx)
            return RuneKit.root(col().pt(40).child(row().child(cb)), layer)
        }
        rtCustom.frame(at: 0.0)
        let cust = try #require(rtCustom.elements().first { $0.key == "custom" }?.rect)
        rtCustom.pointerDown(at: Vec2(cust[0] + 10, cust[1] + 10), at: 0.05)
        rtCustom.pointerUp(at: Vec2(cust[0] + 10, cust[1] + 10), at: 0.06)
        rtCustom.frame(at: 0.07)
        rtCustom.frame(at: 0.08)
        #expect(rtCustom.state.combo.isOpen)
        #expect(rtCustom.elements().first(where: \.focused)?.key == "models-search")
        let content = try #require(rtCustom.elements().first { $0.key == "models-content" }?.rect)
        #expect(content[1] + content[3] <= 300.01)

        _ = rtCustom.keyDown(KeyEvent(key: .arrowUp, mods: .none), at: 0.1)
        rtCustom.frame(at: 0.11)
        rtCustom.frame(at: 0.12)
        #expect(rtCustom.state.combo.active == "item-199")
        let last = rtCustom.elements().first { $0.key == "models-option-item-199" }
        #expect((last?.visible[3] ?? 0) > 0)
    }

    @Test("Held Enter chooses once and repeats do not reopen from trigger (tests/combobox.rs:138)")
    func comboboxHeldEnterChoosesOnceAndDoesNotReopenFromTrigger() throws {
        let rt = makeComboRuntime()
        rt.globalOnKey = { s, _, _ in s.appKeys += 1; return false }
        let searchRect = try #require(rt.elements().first { $0.key == "models-search" }).rect
        rt.pointerDown(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.01)
        rt.pointerUp(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.02)
        rt.frame(at: 0.03)

        _ = rt.keyDown(KeyEvent(key: .arrowDown), at: 0.04)
        rt.frame(at: 0.05)
        _ = rt.keyDown(KeyEvent(key: .enter), isRepeat: false, at: 0.06)
        rt.frame(at: 0.07)
        for i in 1...2 {
            _ = rt.keyDown(KeyEvent(key: .enter), isRepeat: true, at: 0.08 + Double(i) * 0.01)
            rt.frame(at: 0.085 + Double(i) * 0.01)
        }
        #expect(rt.state.chosen == "item-2")
        #expect(rt.state.chooses == 1)
        #expect(!rt.state.combo.isOpen)
        #expect(rt.state.appKeys == 0)
    }

    @Test("Repeats after an IME composition neither choose nor close (tests/combobox.rs:152)")
    func comboboxRepeatsAfterImeCompositionNeitherChooseNorClose() throws {
        for held in [Key.enter, Key.escape] {
            let rt = makeComboRuntime()
            let searchRect = try #require(rt.elements().first { $0.key == "models-search" }).rect
            rt.pointerDown(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.01)
            rt.pointerUp(at: Vec2(searchRect[0] + 10, searchRect[1] + 10), at: 0.02)
            rt.frame(at: 0.03)
            _ = rt.keyDown(KeyEvent(key: .arrowDown), at: 0.04)
            rt.frame(at: 0.05)

            _ = rt.dispatchImeEvent(.preedit("ka", cursorUTF8: nil, clauses: []), at: 0.06)
            rt.frame(at: 0.07)
            _ = rt.keyDown(KeyEvent(key: held), at: 0.08)
            rt.frame(at: 0.09)
            #expect(rt.state.combo.isOpen)

            _ = rt.dispatchImeEvent(.commit("か"), at: 0.10)
            rt.frame(at: 0.11)
            for i in 1...2 {
                _ = rt.keyDown(KeyEvent(key: held), isRepeat: true, at: 0.12 + Double(i) * 0.01)
                rt.frame(at: 0.125 + Double(i) * 0.01)
            }
            #expect(rt.state.combo.isOpen)
            #expect(rt.state.chooses == 0)
        }
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

    @Test("PopupList composer intercepts ArrowUp/ArrowDown via El.onInputKey without losing focus")
    func popupListComposerInterceptsArrowKeys() {
        struct PState {
            var active: Int? = 0
            var composer = TextEdit()
            var chosen: String? = nil
        }
        let k = Kit.neutral(dark: true)
        let rt = Runtime(state: PState(), viewport: Vec2(480, 480), systemDark: true) { s, cx in
            var layer: [El<PState>] = []
            let input: El<PState> = Rune.textInput(key: "composer", \PState.composer)
                .size(240, 32)
                .onInputKey { st, ev, tx in
                    if ev.key == .arrowDown {
                        st.active = min(3, (st.active ?? 0) + 1)
                        return true
                    }
                    if ev.key == .arrowUp {
                        st.active = max(0, (st.active ?? 0) - 1)
                        return true
                    }
                    if ev.key == .enter {
                        st.chosen = "cmd-\(st.active ?? 0)"
                        tx.instant()
                        return true
                    }
                    return false
                }
            PopupList<PState>("commands", anchor: "composer")
                .open(true)
                .items((0..<4).map { PopupItem<PState>("cmd-\($0)", "Command \($0)") })
                .active(s.active)
                .build(kit: k, layer: &layer, cx: cx)
            return RuneKit.root(col().pt(300).px(24).child(input), layer)
        }
        rt.frame(at: 0.0)
        _ = rt.keyDown(KeyEvent(key: .tab, mods: .none), at: 0.01)
        rt.frame(at: 0.02)
        #expect(rt.elements().first(where: \.focused)?.key == "composer")

        _ = rt.keyDown(KeyEvent(key: .arrowDown, mods: .none), at: 0.05)
        rt.frame(at: 0.06)
        #expect(rt.state.active == 1)
        #expect(rt.elements().first(where: \.focused)?.key == "composer")

        _ = rt.keyDown(KeyEvent(key: .enter, mods: .none), at: 0.08)
        rt.frame(at: 0.09)
        #expect(rt.state.chosen == "cmd-1")
        #expect(rt.elements().first(where: \.focused)?.key == "composer")
    }

    @Test("PopupList reveals offscreen active option inside scrollable viewport")
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
                .onInputKey { st, ev, _ in
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
        for i in 0..<30 {
            rt.frame(at: 0.06 + Double(i) * (1.0 / 60.0))
        }
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

    @Test("Select portal inside Dialog accepts an option outside the panel (tests/dialog_select.rs)")
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

    @Test("Context menu opens at pointer inside viewport and closes on item click")
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

    @Test("Shift+F10 and ContextMenu key open focused row menu at bottom-left and Escape returns focus (tests/context_menu.rs:83)")
    func contextMenuShiftF10AndMenuKeyOpenAtBottomLeftAndEscapeReturnsFocus() throws {
        struct S { var point: PointerPress? = nil; var rowKeys = false }
        let k = Kit.neutral(dark: true)
        let rt = Runtime(state: S(), viewport: Vec2(400, 300), systemDark: true) { s, cx in
            let rowEl: El<S> = row()
                .key("row")
                .focusable(true)
                .size(200, 32)
                .onKey { st, _, _ in st.rowKeys }
                .onSecondaryClick { st, p, _ in st.point = p }
            var layer: [El<S>] = []
            let body = contextMenu("context", trigger: rowEl, at: s.point)
                .item(MenuItem<S>("Copy").onSelect { st in st.point = nil })
                .onClose { st in st.point = nil }
                .build(kit: k, layer: &layer, cx: cx)
            return RuneKit.root(col().p(20).child(body), layer)
        }
        var now = 0.0
        func settle() {
            rt.frame(at: now)
            for _ in 0..<60 {
                now += 1.0 / 60.0
                rt.frame(at: now)
            }
        }
        settle()
        _ = rt.keyDown(KeyEvent(key: .tab), at: now)
        settle()
        #expect(rt.elements().first(where: \.focused)?.key == "row")

        _ = rt.keyDown(KeyEvent(key: .f(10), mods: Mods(shift: true)), at: now)
        settle()
        let p = try #require(rt.state.point)
        let rowEl = try #require(rt.elements().first { $0.key == "row" })
        #expect(abs(p.window.x - rowEl.rect[0]) < 1e-4)
        #expect(abs(p.window.y - (rowEl.rect[1] + rowEl.rect[3])) < 1e-4)
        #expect(rt.elements().contains { $0.key == "context-menu" })

        _ = rt.keyDown(KeyEvent(key: .escape), at: now)
        settle()
        #expect(rt.state.point == nil)
        #expect(!rt.elements().contains { $0.key == "context-menu" })
        #expect(rt.elements().first(where: \.focused)?.key == "row")

        _ = rt.keyDown(KeyEvent(key: .contextMenu), at: now)
        settle()
        #expect(rt.state.point != nil)
        #expect(rt.elements().contains { $0.key == "context-menu" })
    }

    @Test("Focused onKey taking Shift+F10 keeps it, plain F10 does not open, and nothing focused is a no-op (tests/context_menu.rs:99)")
    func contextMenuKeyHandlerTakesShiftF10AndNothingFocusedIsNoOp() {
        struct S { var point: PointerPress? = nil; var rowKeys = false }
        let k = Kit.neutral(dark: true)
        let rt = Runtime(state: S(), viewport: Vec2(400, 300), systemDark: true) { s, cx in
            let rowEl: El<S> = row()
                .key("row")
                .focusable(true)
                .size(200, 32)
                .onKey { st, _, _ in st.rowKeys }
                .onSecondaryClick { st, p, _ in st.point = p }
            var layer: [El<S>] = []
            let body = contextMenu("context", trigger: rowEl, at: s.point)
                .item(MenuItem<S>("Copy").onSelect { st in st.point = nil })
                .onClose { st in st.point = nil }
                .build(kit: k, layer: &layer, cx: cx)
            return RuneKit.root(col().p(20).child(body), layer)
        }
        rt.frame(at: 0.0)
        _ = rt.keyDown(KeyEvent(key: .contextMenu), at: 0.01)
        rt.frame(at: 0.02)
        #expect(rt.state.point == nil && !rt.elements().contains(where: \.focused))

        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.03)
        rt.frame(at: 0.04)
        rt.state.rowKeys = true
        _ = rt.keyDown(KeyEvent(key: .f(10), mods: Mods(shift: true)), at: 0.05)
        rt.frame(at: 0.06)
        #expect(rt.state.point == nil)

        rt.state.rowKeys = false
        _ = rt.keyDown(KeyEvent(key: .f(10)), at: 0.07)
        rt.frame(at: 0.08)
        #expect(rt.state.point == nil)
    }

    @Test("Menus and submenus open on the next frame and fade only on close (tests/menu_open.rs)")
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

    @Test("Menu open, submenu open, and close pass MotionGate (tests/menu_open.rs)")
    func menuOpenMotionGate() throws {
        // #204: Nested menu + submenu MotionGate exceeds Swift Testing's 512KB Debug worker stack.
        final class ReportBox: @unchecked Sendable { var report: MotionGateReport? }
        let box = ReportBox()
        let sem = DispatchSemaphore(value: 0)
        let thread = Thread {
            defer { sem.signal() }
            struct MState { var open = false; var sub = false }
            let cells = MotionGateGate.run([(
                "menu/open-submenu-close",
                {
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
                    let run = MotionGateRun(rt, hz: 120.0)
                    run.idle(0.5)
                    run.step()
                    run.act("open") { rt in rt.update { s, _ in s.open = true } }
                    run.play(0.1)
                    run.act("submenu") { rt in rt.update { s, _ in s.sub = true } }
                    run.play(0.1)
                    run.act("close") { rt in rt.update { s, _ in s.open = false; s.sub = false } }
                    run.play(1.0)
                    return run.rec
                }
            )])
            box.report = MotionGateGate.report(cells)
        }
        thread.stackSize = 4 * 1024 * 1024
        thread.start()
        sem.wait()
        let report = try #require(box.report)
        #expect(report.failing == 0, "\(report.text)")
    }

    @Test("Described MenuItem grows to show second description line and Menu opens submenus")
    func menuDescriptionAndSubmenu() throws {
        try Self.runMenuDescriptionAndSubmenu()
    }

    private static func runMenuDescriptionAndSubmenu() throws {
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

    @Test("List focusGroup acts as one tab stop and re-enters on selected item")
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

    @Test("Tooltip wraps labels inside maxWidth and leaves short labels and nowrap chips unshrunk (tests/tooltip.rs)")
    func tooltipLabelWrapsInsideMaxWidth() throws {
        let long = "PR #123 · Open · CI passing · Move the sidebar search into the toolbar and keep its results"
        func makeRt(_ which: UInt8) -> Runtime<UInt8> {
            let rt = Runtime(state: which, viewport: Vec2(800, 400), systemDark: true) { s, _ in
                var layer: [El<UInt8>] = []
                let tipBase = Tooltip<UInt8>("t").trigger(text("?")).open(true)
                let trigger: El<UInt8> = {
                    switch s {
                    case 0:
                        return tipBase
                            .label(long)
                            .render(style: TooltipStyle.neutral(dark: true).maxWidth(160.0).padding(8.0, 5.0), layer: &layer)
                    case 1:
                        let k = Kit.neutral(dark: true)
                        return tipBase
                            .appearance(.standard)
                            .text(k, "\(long) \(long)")
                            .build(kit: k, layer: &layer)
                    case 3:
                        return tipBase
                            .child(text(long).wrapText())
                            .child(text("⌘K").noWrap().key("chip"))
                            .render(style: TooltipStyle.neutral(dark: true).maxWidth(160.0).padding(8.0, 5.0), layer: &layer)
                    default:
                        return tipBase
                            .label("Help")
                            .render(style: TooltipStyle.neutral(dark: true).maxWidth(160.0).padding(8.0, 5.0), layer: &layer)
                    }
                }()
                return RuneKit.root(col().wFull().pt(200.0).itemsCenter().child(trigger), layer)
            }
            rt.frame(at: 0.0)
            for _ in 0..<60 { rt.frame(at: 1.0) }
            return rt
        }

        let rt0 = makeRt(0)
        let tip0 = try #require(rt0.elements().first { $0.key == "t-tooltip" }).rect
        let w0 = try #require(rt0.elements().first { $0.text == long }).rect
        #expect(abs(tip0[2] - 160.0) < 0.01)
        #expect(w0[0] >= tip0[0] + 8.0 && w0[0] + w0[2] <= tip0[0] + tip0[2] - 8.0)
        #expect(w0[3] > 30.0 && tip0[3] >= w0[3] + 10.0)

        let rt1 = makeRt(1)
        let tip1 = try #require(rt1.elements().first { $0.key == "t-tooltip" }).rect
        let w1 = try #require(rt1.elements().first { $0.text == "\(long) \(long)" }).rect
        #expect(abs(tip1[2] - 320.0) < 0.01)
        #expect(w1[0] + w1[2] <= tip1[0] + tip1[2] && w1[3] > 20.0)

        let rt3 = makeRt(3)
        let tip3 = try #require(rt3.elements().first { $0.key == "t-tooltip" }).rect
        let w3 = try #require(rt3.elements().first { $0.text == long }).rect
        let chip3 = try #require(rt3.elements().first { $0.key == "chip" }).rect
        #expect(abs(tip3[2] - 160.0) < 0.01)
        #expect(w3[2] <= tip3[2] - 16.0 && w3[0] + w3[2] <= chip3[0])
        #expect(chip3[0] + chip3[2] <= tip3[0] + tip3[2] - 8.0 + 0.01 && chip3[2] > 10.0)
        #expect(w3[3] > 30.0)

        let rt2 = makeRt(2)
        let tip2 = try #require(rt2.elements().first { $0.key == "t-tooltip" }).rect
        let w2 = try #require(rt2.elements().first { $0.text == "Help" }).rect
        #expect(tip2[2] < 60.0 && abs(tip2[2] - (w2[2] + 16.0)) < 0.5)
    }

    @Test("TooltipStyle.helpLook, Kit.windowTitlebar 44pt height, and HoverCard parity")
    func tooltipStyleHelpLookAndHoverCardParity() throws {
        struct S { var open = true }
        let k = Kit.neutral(dark: true)
        let look = TooltipStyle.fromKit(k, .standard).helpLook()
        #expect(look.maxW == 320.0)
        #expect(look.delaySeconds == 0.4)
        #expect(look.skipSeconds == 0.3)
        #expect(abs(look.fadeEnter - 0.12) < 1e-6)
        #expect(abs(look.fadeExit - 0.08) < 1e-6)
        #expect(abs(look.fadeScale - 0.96) < 1e-6)
        #expect(look.key.upper)
        #expect(look.key.height == 14.0 && look.rowGap == 6.0)

        let rt = Runtime(state: S(), viewport: Vec2(480, 320), systemDark: true) { s, _ in
            var layer: [El<S>] = []
            let bar: El<S> = k.windowTitlebar(key: "win-bar", title: "App")
            let hc = HoverCard<S>("hc")
                .trigger(text("Hover me"))
                .child(text("Preview details"))
                .open(s.open)
                .build(kit: k, layer: &layer)
            return RuneKit.root(col().wFull().child(bar).child(hc), layer)
        }
        rt.frame(at: 0.0)
        let barInfo = try #require(rt.elements().first { $0.key == "win-bar" })
        #expect(abs(barInfo.rect[3] - 44.0) < 0.01)
        let cardInfo = try #require(rt.elements().first { $0.key == "hc-card" })
        #expect(cardInfo.rect[2] >= 200.0 && cardInfo.rect[2] <= 320.0)
    }

    @Test("PopupList padding/rowRadius defaults and animated filtering motion (tests/popup_list_motion.rs)")
    func popupListMotionParity() throws {
        struct S {
            var ids: [String]
            var padding: Float? = nil
            var rowRadius: Float? = nil
            var animate: Bool = true
        }
        let six = ["a0", "a1", "a2", "a3", "a4", "a5"]
        let ten = ["a1", "b0", "b1", "b2", "b3", "b4", "b5", "b6", "b7", "b8"]
        let kit = Kit.neutral(dark: true)

        func makeRt(_ s: S) -> Runtime<S> {
            Runtime(state: s, viewport: Vec2(600, 600), systemDark: true) { st, cx in
                var layer: [El<S>] = []
                var list = PopupList<S>("p", anchor: "field")
                    .anchored("field", side: .top, align: .start, gap: 8.0)
                    .maxHeight(300.0)
                    .items(st.ids.map { PopupItem<S>($0, $0) })
                    .animateFiltering(st.animate)
                    .active(0)
                if let p = st.padding { list = list.padding(p) }
                if let r = st.rowRadius { list = list.rowRadius(r) }
                list.build(kit: kit, layer: &layer, cx: cx)
                return RuneKit.root(col().pt(400.0).pl(40.0).child(el().key("field").w(300.0).h(60.0)), layer)
            }
        }
        func settled(_ items: [String], animate: Bool = true, time: inout Double) -> Runtime<S> {
            let rt = makeRt(S(ids: items, animate: animate))
            rt.frame(at: time)
            for _ in 0..<60 { time += 1.0 / 120.0; rt.frame(at: time) }
            return rt
        }
        func y(_ rt: Runtime<S>, _ key: String) throws -> Float {
            try #require(rt.elements().first { $0.key == key }).rect[1]
        }

        // 1. padding and row_radius default to 4 and follow builders
        do {
            var t = 0.0
            let rt1 = settled(six, time: &t)
            let c1 = try #require(rt1.elements().first { $0.key == "p-content" }).rect
            let r1 = try #require(rt1.elements().first { $0.key == "p-option-a0" })
            #expect(r1.radius == 4.0)
            #expect(abs(r1.rect[0] - c1[0] - 4.0) < 0.05 && abs(r1.rect[1] - c1[1] - 4.0) < 0.05)
            #expect(abs(c1[3] - (6.0 * 28.0 + 8.0)) < 0.05)

            let rt2 = makeRt(S(ids: six, padding: 6.0, rowRadius: 6.0, animate: false))
            rt2.frame(at: 0.0)
            let c2 = try #require(rt2.elements().first { $0.key == "p-content" }).rect
            let r2 = try #require(rt2.elements().first { $0.key == "p-option-a0" })
            #expect(r2.radius == 6.0)
            #expect(abs(r2.rect[0] - c2[0] - 6.0) < 0.05 && abs(r2.rect[1] - c2[1] - 6.0) < 0.05)
            #expect(abs(r2.rect[2] - (c2[2] - 12.0)) < 0.05)
            #expect(abs(c2[3] - (6.0 * 28.0 + 12.0)) < 0.05)
            #expect(abs(c2[1] + c2[3] - 392.0) < 0.05)
        }

        // 2. default non-animated swap rows and height at once (tx.instant() covered in dedicated test below)
        do {
            var t = 0.0
            let rt = settled(six, animate: false, time: &t)
            rt.update { s, _ in s.ids = ["a1"] }
            t += 1.0 / 120.0
            rt.frame(at: t)
            for id in ["a0", "a2", "a3", "a4", "a5"] {
                #expect(rt.elements().first { $0.key == "p-option-\(id)" } == nil)
            }
            #expect(abs(try y(rt, "p-content") - 356.0) < 0.05)
            #expect(abs(try y(rt, "p-option-a1") - 360.0) < 0.05)

            rt.update { s, _ in s.ids = ten }
            t += 1.0 / 120.0
            rt.frame(at: t)
            #expect(abs(try y(rt, "p-content") - 104.0) < 0.05)
            for (i, id) in ten.enumerated() {
                #expect(abs(try y(rt, "p-option-\(id)") - (108.0 + 28.0 * Float(i))) < 0.05)
            }
        }

        // 3. growing back while leaving vs settled: rows rise without overshoot
        func checkGrowsWithoutOvershoot(_ rt: Runtime<S>, time: inout Double) throws {
            rt.update { s, _ in s.ids = ten }
            let keys = ten.map { "p-option-\($0)" } + ["p-content"]
            var tracks = Array(repeating: [Float](), count: keys.count)
            for _ in 0..<90 {
                time += 1.0 / 120.0
                rt.frame(at: time)
                for (idx, k) in keys.enumerated() {
                    tracks[idx].append(try y(rt, k))
                }
            }
            for track in tracks {
                let lowest = track.min() ?? 0
                let end = track.last ?? 0
                for f in 1..<track.count {
                    #expect(track[f] <= track[f - 1] + 0.05)
                }
                #expect(end - lowest < 0.05)
            }
            #expect(abs(try y(rt, "p-content") - 104.0) < 0.5)
            for (i, id) in ten.enumerated() {
                #expect(abs(try y(rt, "p-option-\(id)") - (108.0 + 28.0 * Float(i))) < 0.5)
            }
        }
        do {
            var t = 0.0
            let rt = settled(six, time: &t)
            rt.update { s, _ in s.ids = ["a1"] }
            for _ in 0..<20 {
                t += 1.0 / 120.0
                rt.frame(at: t)
            }
            #expect(rt.elements().first { $0.key == "p-option-a2" } != nil)
            try checkGrowsWithoutOvershoot(rt, time: &t)
        }
        do {
            var t = 0.0
            let rt = settled(six, time: &t)
            rt.update { s, _ in s.ids = ["a1"] }
            for _ in 0..<120 { t += 1.0 / 120.0; rt.frame(at: t) }
            #expect(rt.elements().first { $0.key == "p-option-a2" } == nil)
            try checkGrowsWithoutOvershoot(rt, time: &t)
        }

        // 4. clipped away rows leave at once, visible filtered rows fade, newly brought-in rows fade in
        do {
            var t = 0.0
            let sixty = (0..<60).map { "a\($0)" }
            let rt1 = settled(sixty, time: &t)
            #expect(rt1.elements().first { $0.key == "p-option-a20" } != nil)
            rt1.update { s, _ in s.ids = ["a0"] }
            t += 1.0 / 120.0
            rt1.frame(at: t)
            #expect(rt1.elements().first { $0.key == "p-option-a20" && $0.visible[3] > 0 && $0.visible[2] > 0 } == nil)
            for _ in 0..<4 { t += 1.0 / 120.0; rt1.frame(at: t) }
            let leaving = try #require(rt1.elements().first { $0.key == "p-option-a5" })
            #expect(leaving.opacity > 0.05 && leaving.opacity < 1.0)

            var t2 = 0.0
            let rt2 = settled(sixty, time: &t2)
            #expect(rt2.elements().first { $0.key == "p-option-a50" } == nil)
            rt2.update { s, _ in s.ids = ["a50", "a51"] }
            t2 += 1.0 / 120.0
            rt2.frame(at: t2)
            let entering = try #require(rt2.elements().first { $0.key == "p-option-a50" })
            #expect(entering.opacity < 0.9)
            for _ in 0..<60 { t2 += 1.0 / 120.0; rt2.frame(at: t2) }
            let settledA50 = try #require(rt2.elements().first { $0.key == "p-option-a50" })
            #expect(settledA50.opacity > 0.99)
        }
    }

    @Test("PopupList animated filtering snaps rows on tx.instant() (tests/popup_list_motion.rs)")
    func popupListMotionInstantCommit() throws {
        struct S {
            var ids: [String]
            var animate: Bool = true
        }
        let six = ["a0", "a1", "a2", "a3", "a4", "a5"]
        let ten = ["a1", "b0", "b1", "b2", "b3", "b4", "b5", "b6", "b7", "b8"]
        let kit = Kit.neutral(dark: true)

        func makeRt(_ s: S) -> Runtime<S> {
            Runtime(state: s, viewport: Vec2(600, 600), systemDark: true) { st, cx in
                var layer: [El<S>] = []
                PopupList<S>("p", anchor: "field")
                    .anchored("field", side: .top, align: .start, gap: 8.0)
                    .maxHeight(300.0)
                    .items(st.ids.map { PopupItem<S>($0, $0) })
                    .animateFiltering(st.animate)
                    .active(0)
                    .build(kit: kit, layer: &layer, cx: cx)
                return RuneKit.root(col().pt(400.0).pl(40.0).child(el().key("field").w(300.0).h(60.0)), layer)
            }
        }
        func y(_ rt: Runtime<S>, _ key: String) throws -> Float {
            try #require(rt.elements().first { $0.key == key }).rect[1]
        }

        var t = 0.0
        let rt = makeRt(S(ids: six, animate: true))
        rt.frame(at: t)
        for _ in 0..<60 { t += 1.0 / 120.0; rt.frame(at: t) }

        rt.update { s, tx in
            s.ids = ["a1"]
            tx.instant()
        }
        t += 1.0 / 120.0
        rt.frame(at: t)
        for id in ["a0", "a2", "a3", "a4", "a5"] {
            #expect(rt.elements().first { $0.key == "p-option-\(id)" } == nil)
        }
        #expect(abs(try y(rt, "p-content") - 356.0) < 0.05)
        #expect(abs(try y(rt, "p-option-a1") - 360.0) < 0.05)

        rt.update { s, tx in
            s.ids = ten
            tx.instant()
        }
        t += 1.0 / 120.0
        rt.frame(at: t)
        #expect(abs(try y(rt, "p-content") - 104.0) < 0.05)
        for (i, id) in ten.enumerated() {
            #expect(abs(try y(rt, "p-option-\(id)") - (108.0 + 28.0 * Float(i))) < 0.05)
        }
    }

    @Test("PopupList 5 -> 2 -> 0 -> 3 springs height, fades removed rows, and toggles empty state (`tests/popup_list.rs:82`)")
    func popupList5203SpringHeightAndEmptyToggle() throws {
        struct PState {
            var count = 5
            var active: Int? = 0
            var open = true
            var animate = false
            var composer = TextEdit()
        }
        let k = Kit.neutral(dark: true)
        let rt = Runtime(state: PState(), viewport: Vec2(480, 480), systemDark: true) { s, cx in
            var layer: [El<PState>] = []
            let input: El<PState> = Rune.textInput(key: "composer", \PState.composer).size(240, 32)
            let items = (0..<s.count).map { i in
                PopupItem<PState>("cmd-\(i)", "Command \(i)")
            }
            PopupList<PState>("commands", anchor: "composer")
                .open(s.open)
                .items(items)
                .active(s.active)
                .animateFiltering(s.animate)
                .emptyMessage("No matching commands")
                .onClose { st in st.open = false }
                .build(kit: k, layer: &layer, cx: cx)
            return RuneKit.root(col().pt(300).px(24).child(input), layer)
        }
        var t = 0.0
        func step() { t += 1.0 / 60.0; rt.frame(at: t) }
        rt.frame(at: t)
        rt.update { s, _ in s.animate = true }
        for _ in 0..<60 { step() }

        let h5 = try #require(rt.element(byKey: "commands-content")).rect[3]
        let empty5 = try #require(rt.element(byKey: "empty"))
        #expect(empty5.opacity == 0.0)
        #expect(empty5.rect[3] == 0.0)

        // 5 -> 2 items: height springs down and removed rows fade out.
        rt.update { s, _ in s.count = 2 }
        step()
        let fading = try #require(rt.element(byKey: "commands-option-cmd-4"))
        #expect(fading.opacity > 0.0 && fading.opacity < 1.0)
        let mid5to2 = try #require(rt.element(byKey: "commands-content")).rect[3]
        #expect(mid5to2 < h5 && mid5to2 > 64.0)
        var last = mid5to2
        for _ in 0..<60 {
            step()
            let h = try #require(rt.element(byKey: "commands-content")).rect[3]
            #expect(abs(h - last) < 25.0)
            last = h
        }
        let h2 = last
        #expect(abs(h2 - 64.0) < 1.0)
        #expect(try #require(rt.element(byKey: "empty")).opacity == 0.0)

        // 2 -> 0 items: height springs to empty state and empty message becomes visible.
        rt.update { s, _ in s.count = 0 }
        step()
        #expect(try #require(rt.element(byKey: "empty")).opacity > 0.0)
        let mid2to0 = try #require(rt.element(byKey: "commands-content")).rect[3]
        #expect(mid2to0 < h2 && mid2to0 > 36.0)
        for _ in 0..<60 { step() }
        let h0 = try #require(rt.element(byKey: "commands-content")).rect[3]
        #expect(abs(h0 - 36.0) < 1.0)
        let empty0 = try #require(rt.element(byKey: "empty"))
        #expect(empty0.opacity == 1.0)
        #expect(abs(empty0.rect[3] - 28.0) < 1.0)

        // 0 -> 3 items: height springs back up and empty state hides.
        rt.update { s, _ in
            s.count = 3
            s.active = 0
        }
        step()
        #expect(try #require(rt.element(byKey: "empty")).opacity < 1.0)
        let mid0to3 = try #require(rt.element(byKey: "commands-content")).rect[3]
        #expect(mid0to3 > h0 && mid0to3 < 92.0)
        for _ in 0..<60 { step() }
        let h3 = try #require(rt.element(byKey: "commands-content")).rect[3]
        #expect(abs(h3 - 92.0) < 1.0)
        #expect(try #require(rt.element(byKey: "empty")).opacity == 0.0)
    }

    @Test("UnseenPresence honors stuck header shift and RTL horizontal scroll clamping slack")
    func unseenPresenceStuckHeaderAndRtlScrollSlack() throws {
        struct S {
            var showBadge = false
            var wideContent = true
            var showRtlChip = false
        }
        let rt = Runtime(state: S(), viewport: Vec2(240, 140), systemDark: true) { s, _ in
            var header: El<S> = row()
                .key("stuck-hdr")
                .wFull()
                .h(30.0)
                .stickyTop(0.0)
                .child(el().key("hdr-title").size(80.0, 20.0))
            if s.showBadge {
                header = header.child(
                    el().key("hdr-badge")
                        .size(24.0, 16.0)
                        .transition(.opacity)
                )
            }
            let scroll = col()
                .key("stuck-scroll")
                .size(200.0, 100.0)
                .scrollY()
                .child(el().key("lead-spacer").wFull().h(80.0))
                .child(header)
                .child(el().key("tail-spacer").wFull().h(400.0))

            var rtlChildren: [El<S>] = [el().key("rtl-a").size(80.0, 24.0)]
            if s.wideContent {
                rtlChildren.append(el().key("rtl-b").size(320.0, 24.0))
            }
            if s.showRtlChip {
                rtlChildren.append(
                    el().key("rtl-chip")
                        .size(40.0, 24.0)
                        .transition(.opacity)
                )
            }
            let rtlScroll = row()
                .key("rtl-scroll")
                .dir(.rtl)
                .size(200.0, 32.0)
                .scrollX()
                .children(rtlChildren)

            return col().size(240.0, 140.0).children([scroll, rtlScroll])
        }

        var t = 0.0
        _ = rt.frame(at: t)
        // Scroll down past lead spacer + header (80 + 30 = 110) so header targetRect is above viewport yet held stuck at top.
        rt.wheel(WheelEvent(dx: 0, dy: -180), at: Vec2(100, 50), now: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        for _ in 0..<20 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let stuckRect = rt.element(byKey: "stuck-hdr")!.rect
        #expect(stuckRect[1] >= 0.0 && stuckRect[1] < 5.0)

        // Scroll RTL horizontal container toward the end (`ox0 > 150`) and then shrink content while mounting a chip in sight.
        rt.wheel(WheelEvent(dx: 180, dy: 0), at: Vec2(100, 115), now: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        if rt.scrollOffset(forKey: "rtl-scroll").x == 0 {
            rt.wheel(WheelEvent(dx: -180, dy: 0), at: Vec2(100, 115), now: t)
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        #expect(rt.scrollOffset(forKey: "rtl-scroll").x > 100.0)

        rt.update(at: t) { s, _ in
            s.showBadge = true
            s.wideContent = false
            s.showRtlChip = true
        }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        let badge = try #require(rt.element(byKey: "hdr-badge"))
        #expect(badge.opacity > 0.0 && badge.opacity < 1.0, "Child mounted in stuck header must fade in instead of snapping unseen")
        let rtlChip = try #require(rt.element(byKey: "rtl-chip"))
        #expect(rtlChip.opacity > 0.0 && rtlChip.opacity < 1.0, "Child mounted inside clamped RTL horizontal scroll must fade in")
    }
}
