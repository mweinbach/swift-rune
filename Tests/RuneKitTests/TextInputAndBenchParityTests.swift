import Foundation
import Testing
@testable import RuneKit
@testable import Rune

@MainActor
@Suite("TextInput, PopupList & Benchmark Parity Tests")
struct TextInputAndBenchParityTests {

    // MARK: - 1. crates/rune-kit/tests/text_input_press.rs:62

    @Test("Padding focus reaches an editor inside an auto-grow scroll (tests/text_input_press.rs:62)")
    func paddingFocusReachesEditorInsideAutoGrowScroll() throws {
        struct S {
            var edit = TextEdit("one\ntwo\nthree\nfour", multiline: true)
        }
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(state: S(), viewport: Vec2(400, 200), pixelScale: 1.0, systemDark: true) { _, cx in
            TextArea<S>(key: "area", \.edit)
                .autoGrow(2, 2)
                .build(kit, cx: cx)
        }
        rt.frame(at: 0.0)
        rt.pointerDown(at: Vec2(2.0, 2.0), at: 0.01)
        rt.pointerUp(at: Vec2(2.0, 2.0), at: 0.02)
        rt.frame(at: 0.03)

        let focused = rt.elements().contains { !$0.exiting && $0.focused }
        #expect(focused)
        #expect(rt.state.edit.cursor == 0 && rt.state.edit.anchor == 0)
    }

    // MARK: - 2. crates/rune-kit/tests/text_input_press.rs:287

    @Test("Any unfocusable element can keep outside field focused and still press (tests/text_input_press.rs:287)")
    func anyUnfocusableElementCanKeepOutsideFieldFocusedAndStillPress() throws {
        struct P {
            var field = TextEdit("x")
            var pressed: Int = 0
        }
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(state: P(), viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true) { _, cx in
            col().gap(8.0)
                .child(TextInput<P>(key: "field", \.field).build(kit, cx: cx))
                .child(row().key("plain").size(100.0, 30.0).onClick { s, _ in s.pressed += 1 }.focusable(false))
                .child(row().key("keeper").size(100.0, 30.0).preserveFocusOnPress(true).onClick { s, _ in s.pressed += 10 }.focusable(false))
        }
        rt.frame(at: 0.0)
        let fieldFocusedNow: () -> Bool = {
            rt.elements().contains { !$0.exiting && $0.key == "field-input" && $0.focused }
        }
        let fieldRect = try #require(rt.element(byKey: "field")).rect
        let fPt = Vec2(fieldRect[0] + fieldRect[2] * 0.5, fieldRect[1] + fieldRect[3] * 0.5)
        rt.pointerDown(at: fPt, at: 0.005)
        rt.pointerUp(at: fPt, at: 0.01)
        rt.frame(at: 0.015)
        #expect(fieldFocusedNow())

        let keeperRect = try #require(rt.element(byKey: "keeper")).rect
        let kPt = Vec2(keeperRect[0] + keeperRect[2] * 0.5, keeperRect[1] + keeperRect[3] * 0.5)
        rt.pointerDown(at: kPt, at: 0.02)
        rt.pointerUp(at: kPt, at: 0.03)
        rt.frame(at: 0.04)
        #expect(rt.state.pressed == 10, "the press still reaches onClick")
        #expect(fieldFocusedNow(), "the field keeps focus")

        let plainRect = try #require(rt.element(byKey: "plain")).rect
        let pPt = Vec2(plainRect[0] + plainRect[2] * 0.5, plainRect[1] + plainRect[3] * 0.5)
        rt.pointerDown(at: pPt, at: 0.05)
        rt.pointerUp(at: pPt, at: 0.06)
        rt.frame(at: 0.07)
        #expect(rt.state.pressed == 11)
        #expect(!fieldFocusedNow(), "without the flag a press blurs, as before")
    }

    // MARK: - 3. crates/rune-kit/tests/popup_list.rs:288

    @Test("Ordinary listbox selection does not reveal and press still blurs (tests/popup_list.rs:288)")
    func ordinaryListboxSelectionDoesNotRevealAndPressStillBlurs() throws {
        struct S {
            var composer = TextEdit("")
            var active: Int? = 39
        }
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(state: S(), viewport: Vec2(480, 480), pixelScale: 1.0, systemDark: true) { s, cx in
            col()
                .child(TextInput<S>(key: "composer", \.composer).build(kit, cx: cx))
                .child(
                    col()
                        .key("ordinary-list")
                        .role(.list)
                        .h(100.0)
                        .scroll(stickBottom: false)
                        .child(
                            col()
                                .growth(GrowthSpec())
                                .virtualize(28.0)
                                .children((0..<40).map { i in
                                    el()
                                        .key("row-\(i)")
                                        .role(.listItem)
                                        .h(28.0)
                                        .focusSelected(s.active == i)
                                        .onClick { _, _ in }
                                })
                        )
                )
        }
        rt.frame(at: 0.0)

        // Focus composer by clicking inside it.
        let composerRect = try #require(rt.element(byKey: "composer")).rect
        let cPt = Vec2(composerRect[0] + composerRect[2] * 0.5, composerRect[1] + composerRect[3] * 0.5)
        rt.pointerDown(at: cPt, at: 0.01)
        rt.pointerUp(at: cPt, at: 0.02)
        rt.frame(at: 0.03)
        let composerFocusedNow: () -> Bool = {
            rt.elements().contains { !$0.exiting && $0.key == "composer-input" && $0.focused }
        }
        #expect(composerFocusedNow())

        let firstRow = { () -> ElementInfo? in
            rt.elements().first { !$0.exiting && $0.key == "row-0" }
        }
        #expect(try #require(firstRow()).visible[3] > 0.0)

        rt.update { s, _ in s.active = 38 }
        rt.frame(at: 0.04)
        #expect(try #require(firstRow()).visible[3] > 0.0)

        let row0 = try #require(firstRow()).rect
        let rPt = Vec2(row0[0] + row0[2] * 0.5, row0[1] + row0[3] * 0.5)
        rt.pointerDown(at: rPt, at: 0.05)
        rt.pointerUp(at: rPt, at: 0.06)
        rt.frame(at: 0.07)
        #expect(!composerFocusedNow())
    }

    // MARK: - 4. crates/rune-kit/tests/table.rs:298

    private struct BenchFile {
        var id: String
        var name: String
        var size: UInt64
    }

    private struct BenchTableApp {
        var files: [BenchFile]
        var table: TableState
        var sorts: [(String, SortDir)] = []
        var opened: [String] = []

        init(n: Int, multi: Bool) {
            self.files = (0..<n).map { i in
                BenchFile(
                    id: "f\(i)",
                    name: "file \(i) with a name long enough to cut short.rs",
                    size: UInt64((i * 7919) % 100_000)
                )
            }
            self.table = TableState().multiSelect(multi)
        }
    }

    private static func percentile(_ values: inout [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0.0 }
        values.sort()
        let idx = Int((Double(values.count - 1) * p).rounded())
        return values[min(max(0, idx), values.count - 1)]
    }

    @Test("Table 100,000 rows scroll, rebuild, sort, and column resize performance (tests/table.rs:298)")
    func tableTime() throws {
        let kit = Kit.neutral(dark: true)
        let ms: (ContinuousClock.Instant) -> Double = { start in
            let d = ContinuousClock.now - start
            return Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) * 1e-15
        }

        let app = BenchTableApp(n: 100_000, multi: true)
        let t0 = ContinuousClock.now
        let rt = Runtime(state: app, viewport: Vec2(900, 900), pixelScale: 2.0, systemDark: true) { s, cx in
            col().size(900.0, 900.0).child(
                TableView<BenchTableApp>(
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
                .build(s, cx: cx, kit: kit)
                .h(900.0)
            )
        }
        rt.frame(at: 0.0)
        let firstMs = ms(t0)

        var frames: [Double] = []
        var withCommit: [Double] = []
        let c0 = rt.viewCommitCount
        frames.reserveCapacity(600)
        for f in 1...600 {
            let now = Double(f) / 120.0
            rt.wheel(WheelEvent(dx: 0, dy: -48.0), at: Vec2(450.0, 450.0), now: now)
            let c = rt.viewCommitCount
            let tf = ContinuousClock.now
            rt.frame(at: now)
            let dt = ms(tf)
            frames.append(dt)
            if rt.viewCommitCount > c {
                withCommit.append(dt)
            }
        }
        let builtRows = rt.elements().filter { !$0.exiting && $0.role == .row }.count
        #expect((10..<120).contains(builtRows))
        #expect(rt.viewCommitCount >= c0)

        let commitsBeforeRebuild = rt.viewCommitCount
        var rebuild: [Double] = []
        rebuild.reserveCapacity(30)
        for _ in 0..<30 {
            rt.markNeedsCommit()
            let tr = ContinuousClock.now
            rt.frame(at: 5.0)
            rebuild.append(ms(tr))
        }
        #expect(rt.viewCommitCount - commitsBeforeRebuild == 30)

        let sizeHeader = try #require(rt.elements().first { !$0.exiting && $0.role == .columnHeader && $0.key == "size" }).rect
        let ts = ContinuousClock.now
        let sx = sizeHeader[0] + 20.0
        let sy = sizeHeader[1] + sizeHeader[3] * 0.5
        rt.pointerDown(at: Vec2(sx, sy), at: 5.1)
        rt.pointerUp(at: Vec2(sx, sy), at: 5.11)
        rt.frame(at: 5.12)
        let sortMs = ms(ts)
        #expect(rt.state.table.sort?.0 == "size")

        let handle = try #require(rt.elements().first { !$0.exiting && $0.label == "Resize Size" }).rect
        let hx = handle[0] + handle[2] * 0.5
        let hy = handle[1] + handle[3] * 0.5
        rt.pointerDown(at: Vec2(hx, hy), at: 5.2)
        rt.frame(at: 5.21)
        var drag: [Double] = []
        drag.reserveCapacity(60)
        for k in 1...60 {
            rt.pointerMove(to: Vec2(hx + Float(k), hy), at: 5.21 + Double(k) / 120.0)
            let td = ContinuousClock.now
            rt.frame(at: 5.21 + Double(k) / 120.0)
            drag.append(ms(td))
        }
        rt.pointerUp(at: Vec2(hx + 60.0, hy), at: 6.0)
        rt.frame(at: 6.01)
        #expect(abs((rt.state.table.columnWidth("size") ?? 0.0) - 160.0) < 1.0)

        let scrollP50 = Self.percentile(&frames, 0.5)
        let scrollP95 = Self.percentile(&frames, 0.95)
        let commitP50 = Self.percentile(&withCommit, 0.5)
        let rebuildP50 = Self.percentile(&rebuild, 0.5)
        let dragP50 = Self.percentile(&drag, 0.5)
        #expect(firstMs >= 0.0 && sortMs >= 0.0)
        #expect(scrollP50 < 200.0 && scrollP95 < 500.0 && commitP50 < 500.0 && rebuildP50 < 500.0 && dragP50 < 500.0)
    }

    // MARK: - 5. crates/rune-kit/tests/tree.rs:350

    private struct BenchTreeApp {
        var files: TreeModel<FileNode<(UInt32, UInt32)>>
        var picked: [String] = []
        var opened: [String] = []
    }

    @Test("Tree 50,000 files build, scroll, reveal last, and filter performance (tests/tree.rs:350)")
    func treeTime() throws {
        let kit = Kit.neutral(dark: true)
        let ms: (ContinuousClock.Instant) -> Double = { start in
            let d = ContinuousClock.now - start
            return Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) * 1e-15
        }

        let tm = ContinuousClock.now
        var paths: [(String, (UInt32, UInt32))] = []
        paths.reserveCapacity(50_000)
        for d in 0..<500 {
            for f in 0..<100 {
                paths.append(("pkg\(d)/file\(f).rs", (1, 0)))
            }
        }
        var model = FileTree().build(paths)
        model.expandAll()
        let modelMs = ms(tm)
        #expect(model.visibleCount == 50_500)

        let t0 = ContinuousClock.now
        let rt = Runtime(state: BenchTreeApp(files: model), viewport: Vec2(360, 900), pixelScale: 2.0, systemDark: true) { state, cx in
            col().size(360.0, 900.0).child(
                Tree(\BenchTreeApp.files, label: { $0.name })
                    .name("Files")
                    .row { node, row in
                        TreeRowItem.file(node, row: row)
                            .changes(added: node.data?.0 ?? 0, removed: 0)
                    }
                    .onSelect { s, id, _ in s.picked.append(id) }
                    .onOpen { s, id, _ in s.opened.append(id) }
                    .build(state, cx: cx, kit: kit)
                    .h(900.0)
            )
        }
        rt.frame(at: 0.0)
        let firstMs = ms(t0)

        var frames: [Double] = []
        frames.reserveCapacity(600)
        for f in 1...600 {
            let now = Double(f) / 120.0
            rt.wheel(WheelEvent(dx: 0, dy: -48.0), at: Vec2(180.0, 450.0), now: now)
            let tf = ContinuousClock.now
            rt.frame(at: now)
            frames.append(ms(tf))
        }
        let builtRows = rt.elements().filter { ($0.level ?? 0) >= 1 && !$0.exiting && $0.label != nil }.count
        #expect((10..<120).contains(builtRows))

        let te = ContinuousClock.now
        rt.update { s, tx in
            _ = s.files.reveal("pkg499/file99.rs", tx: &tx)
        }
        rt.frame(at: 5.1)
        let endMs = ms(te)
        #expect(rt.state.files.cursorID == "pkg499/file99.rs")

        let tf = ContinuousClock.now
        rt.update { s, _ in
            s.files.filter { $0.name.hasSuffix("7.rs") }
        }
        rt.frame(at: 5.2)
        let filterMs = ms(tf)
        #expect(rt.state.files.visibleCount > 0 && rt.state.files.visibleCount < 50_500)

        let p50 = Self.percentile(&frames, 0.5)
        let p95 = Self.percentile(&frames, 0.95)
        #expect(modelMs >= 0.0 && firstMs >= 0.0 && endMs >= 0.0 && filterMs >= 0.0)
        #expect(p50 < 200.0 && p95 < 500.0)
    }
}
