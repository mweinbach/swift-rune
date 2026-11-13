import Foundation
import Rune
import RunePerf
import RuneTaffy

/// Parity port of `crates/rune/examples/taffy_adapter_bench.rs`:
/// Paired benchmark & differential harness for `RuneTaffy.LayoutStore` vs `RuneTaffy.TaffyTree`,
/// plus a `KitchenSink` rect digest and runtime eager/virtualized grid swap benchmark.
@main
public enum RuneTaffyAdapterBenchApp {
    public static let size = Vec2(760, 480)
    public static let rowHeight: Float = 44.0
    public static let columns = 10

    private static func liveHeapBytes() -> Int64 {
        if let h = ProcessCountingAllocator.shared.heap() {
            return h.liveBytes
        }
        #if canImport(Darwin)
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int64(stats.size_in_use)
        #else
        return 0
        #endif
    }

    private static func stats(_ v: [Double]) -> (p50: Double, p95: Double) {
        guard !v.isEmpty else { return (0, 0) }
        let sorted = v.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[Int((Double(sorted.count - 1) * 0.95).rounded())]
        return (p50, p95)
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000.0 + Double(d.components.attoseconds) / 1e15
    }

    private static func buildBaselineList(rows: Int) -> (TaffyTree, RuneTaffy.NodeId, [[RuneTaffy.NodeId]]) {
        var tree = TaffyTree()
        tree.roundingEnabled = false
        var iconS = TaffyStyle.default
        iconS.size = Size(width: length(22), height: length(22))
        var titleS = TaffyStyle.default
        titleS.flexShrink = 1
        titleS.size = Size(width: length(140), height: length(18))
        var subS = TaffyStyle.default
        subS.flexGrow = 1
        subS.flexShrink = 1
        subS.size = Size(width: length(220), height: length(18))
        var copyS = TaffyStyle.default
        copyS.display = .flex
        copyS.flexDirection = .row
        copyS.flexGrow = 1
        copyS.flexShrink = 1
        copyS.gap = Size(width: .length(8), height: .zero)
        copyS.alignItems = .center
        var rowS = TaffyStyle.default
        rowS.display = .flex
        rowS.flexDirection = .row
        rowS.size = Size(width: percent(1), height: length(rowHeight))
        rowS.padding = Rect(left: .length(10), right: .length(10), top: .zero, bottom: .zero)
        rowS.gap = Size(width: .length(10), height: .zero)
        rowS.alignItems = .center
        var rootS = TaffyStyle.default
        rootS.display = .flex
        rootS.flexDirection = .column
        rootS.size = Size(width: length(size.x), height: length(size.y))
        rootS.padding = Rect(left: .length(8), right: .length(8), top: .length(6), bottom: .length(6))

        var rowIds: [RuneTaffy.NodeId] = []
        var handles: [[RuneTaffy.NodeId]] = []
        rowIds.reserveCapacity(rows)
        handles.reserveCapacity(rows)
        for _ in 0..<rows {
            let icon = tree.newLeaf(iconS)
            let title = tree.newLeaf(titleS)
            let sub = tree.newLeaf(subS)
            let copy = try! tree.newWithChildren(copyS, children: [title, sub])
            let r = try! tree.newWithChildren(rowS, children: [icon, copy])
            rowIds.append(r)
            handles.append([r, icon, copy, title, sub])
        }
        let root = try! tree.newWithChildren(rootS, children: rowIds)
        return (tree, root, handles)
    }

    private static func syncStoreList(
        _ store: inout LayoutStore,
        rows: Int,
        keyBase: UInt64,
        dirtyRow: Int?
    ) -> SlotId {
        var iconS = CompactStyle.default
        iconS.size = Size(width: length(22), height: length(22))
        var titleS = CompactStyle.default
        titleS.flexShrink = 1
        titleS.size = Size(width: length(140), height: length(18))
        var subS = CompactStyle.default
        subS.flexGrow = 1
        subS.size = Size(width: length(220), height: length(18))
        var copyS = CompactStyle.runeBase(.row)
        copyS.flexGrow = 1
        copyS.gap = Size(width: .length(8), height: .zero)
        copyS.alignItems = .center
        var rowS = CompactStyle.runeBase(.row)
        rowS.size = Size(width: percent(1), height: length(rowHeight))
        rowS.padding = Rect(left: .length(10), right: .length(10), top: .zero, bottom: .zero)
        rowS.gap = Size(width: .length(10), height: .zero)
        rowS.alignItems = .center
        var rootS = CompactStyle.runeBase(.column)
        rootS.size = Size(width: length(size.x), height: length(size.y))
        rootS.padding = Rect(left: .length(8), right: .length(8), top: .length(6), bottom: .length(6))

        store.beginCommit()
        let rootMark = store.beginChildren()
        var rootDirty = false
        var me: UInt32 = 1
        for i in 0..<rows {
            let kb = keyBase + UInt64(i) * 8
            let mIcon = store.beginChildren()
            let (icon, dIcon) = store.syncNode(key: kb + 1, nodeIndex: me, style: iconS, measure: nil, forceMeasureDirty: false, childMark: mIcon, childrenDirty: false)
            me += 1

            let mTitle = store.beginChildren()
            let mHash: UInt64 = dirtyRow == i ? 999_999 : UInt64(i * 2 + 1)
            let (title, dTitle) = store.syncNode(key: kb + 2, nodeIndex: me, style: titleS, measure: mHash, forceMeasureDirty: false, childMark: mTitle, childrenDirty: false)
            me += 1

            let mSub = store.beginChildren()
            let (sub, dSub) = store.syncNode(key: kb + 3, nodeIndex: me, style: subS, measure: UInt64(i * 2 + 2), forceMeasureDirty: false, childMark: mSub, childrenDirty: false)
            me += 1

            let mCopy = store.beginChildren()
            store.pushChild(title)
            store.pushChild(sub)
            let (copy, dCopy) = store.syncNode(key: kb + 4, nodeIndex: me, style: copyS, measure: nil, forceMeasureDirty: false, childMark: mCopy, childrenDirty: dTitle || dSub)
            me += 1

            let mRow = store.beginChildren()
            store.pushChild(icon)
            store.pushChild(copy)
            let (r, dRow) = store.syncNode(key: kb + 5, nodeIndex: me, style: rowS, measure: nil, forceMeasureDirty: false, childMark: mRow, childrenDirty: dIcon || dCopy)
            me += 1

            store.pushChild(r)
            rootDirty = rootDirty || dRow
        }
        var (root, _) = store.syncNode(key: 1, nodeIndex: 0, style: rootS, measure: nil, forceMeasureDirty: false, childMark: rootMark, childrenDirty: rootDirty)
        store.endCommit(root: &root) { _, _ in }
        return root
    }

    private static func solveStore(_ store: inout LayoutStore, root: SlotId, room: Size<AvailableSpace>) {
        store.computeLayout(root: root, availableSpace: room) { input, _, style in
            let w = input.knownDimensions.width ?? style.size.width.maybeResolve(input.availableSpace.width.intoOption()) ?? 0
            let h = input.knownDimensions.height ?? style.size.height.maybeResolve(input.availableSpace.height.intoOption()) ?? 0
            return LayoutOutput.fromOuterSize(Size(width: w, height: h))
        }
    }

    public static func runIsolatedPairedBench(samples: Int = 25, rows: Int = 500) -> [String] {
        let room = Size<AvailableSpace>(width: .definite(size.x), height: .definite(size.y))
        var baseMem500: [Double] = []
        var compMem500: [Double] = []
        var baseMemSwap: [Double] = []
        var compMemSwap: [Double] = []
        var baseAllocs: [Double] = []
        var compAllocs: [Double] = []
        var baseCold: [Double] = []
        var compCold: [Double] = []
        var baseWarm: [Double] = []
        var compWarm: [Double] = []
        var baseDirty: [Double] = []
        var compDirty: [Double] = []

        for iter in 0...samples {
            for which in 0..<2 {
                let runCompact = (iter + which) % 2 == 1
                if !runCompact {
                    let h0 = liveHeapBytes()
                    let a0 = ProcessCountingAllocator.shared.threadAllocations()
                    let t0 = ContinuousClock.now
                    var (tree, root, handles) = buildBaselineList(rows: rows)
                    try! tree.computeLayout(root, availableSpace: room)
                    let cold = ms(t0.duration(to: .now))
                    let allocs = Double(ProcessCountingAllocator.shared.threadAllocations() &- a0)
                    let mem500 = Double(max(0, liveHeapBytes() - h0))

                    let tw = ContinuousClock.now
                    try! tree.computeLayout(root, availableSpace: room)
                    let warm = ms(tw.duration(to: .now))

                    let td = ContinuousClock.now
                    let dirtyIdx = min(rows - 1, rows / 2)
                    try! tree.markDirty(handles[dirtyIdx][3])
                    try! tree.computeLayout(root, availableSpace: room)
                    let dirty = ms(td.duration(to: .now))

                    var newRows: [RuneTaffy.NodeId] = []
                    for _ in 0..<min(12, rows) {
                        let a = tree.newLeaf(.default)
                        let b = tree.newLeaf(.default)
                        newRows.append(try! tree.newWithChildren(.default, children: [a, b]))
                    }
                    try! tree.setChildren(root, children: newRows)
                    for grp in handles {
                        for id in grp.reversed() {
                            _ = try? tree.remove(id)
                        }
                    }
                    try! tree.computeLayout(root, availableSpace: room)
                    let memSwap = Double(max(0, liveHeapBytes() - h0))

                    if iter > 0 {
                        baseMem500.append(mem500)
                        baseMemSwap.append(memSwap)
                        baseAllocs.append(allocs)
                        baseCold.append(cold)
                        baseWarm.append(warm)
                        baseDirty.append(dirty)
                    }
                } else {
                    let h0 = liveHeapBytes()
                    let a0 = ProcessCountingAllocator.shared.threadAllocations()
                    let t0 = ContinuousClock.now
                    var store = LayoutStore()
                    var root = syncStoreList(&store, rows: rows, keyBase: 100, dirtyRow: nil)
                    solveStore(&store, root: root, room: room)
                    let cold = ms(t0.duration(to: .now))
                    let allocs = Double(ProcessCountingAllocator.shared.threadAllocations() &- a0)
                    let mem500 = Double(max(0, liveHeapBytes() - h0))

                    let tw = ContinuousClock.now
                    solveStore(&store, root: root, room: room)
                    let warm = ms(tw.duration(to: .now))

                    let td = ContinuousClock.now
                    root = syncStoreList(&store, rows: rows, keyBase: 100, dirtyRow: min(rows - 1, rows / 2))
                    solveStore(&store, root: root, room: room)
                    let dirty = ms(td.duration(to: .now))

                    root = syncStoreList(&store, rows: min(12, rows), keyBase: 100_000, dirtyRow: nil)
                    solveStore(&store, root: root, room: room)
                    let memSwap = Double(max(0, liveHeapBytes() - h0))

                    if iter > 0 {
                        compMem500.append(mem500)
                        compMemSwap.append(memSwap)
                        compAllocs.append(allocs)
                        compCold.append(cold)
                        compWarm.append(warm)
                        compDirty.append(dirty)
                    }
                }
            }
        }

        let (bTree, _, _) = buildBaselineList(rows: rows)
        var cStore = LayoutStore()
        _ = syncStoreList(&cStore, rows: rows, keyBase: 100, dirtyRow: nil)
        let cStats = cStore.storageStats()
        let baselineNodeCount = max(1, bTree.totalNodeCount)
        let baselineSlotB = MemoryLayout<TaffyStyle>.stride + MemoryLayout<Layout>.stride * 2 + 128
        let baselineRetainedB = baselineNodeCount * baselineSlotB
        let reductionPct = (1.0 - Double(cStats.totalRetainedBytes) / Double(max(1, baselineRetainedB))) * 100.0
        var out = [
            String(
                format: "STRUCTURAL_%d_ROWS baseline_slot_B=%d compact_slot_B=%d baseline_retained_B=%d compact_retained_B=%d reduction_pct=%.2f",
                rows, baselineSlotB, cStats.bytesPerSlot, baselineRetainedB, cStats.totalRetainedBytes, reductionPct
            ),
        ]
        for (name, bVec, cVec) in [
            ("heap_live_500_rows_B", baseMem500, compMem500),
            ("heap_live_after_swap_12_rows_B", baseMemSwap, compMemSwap),
            ("cold_allocations_500_rows", baseAllocs, compAllocs),
            ("cold_build_solve_ms", baseCold, compCold),
            ("warm_solve_ms", baseWarm, compWarm),
            ("single_dirty_solve_ms", baseDirty, compDirty),
        ] {
            let (b50, b95) = stats(bVec)
            let (c50, c95) = stats(cVec)
            let delta = (c50 - b50) / max(b50, 1e-9) * 100.0
            out.append(String(
                format: "ISOLATED metric=%@ n=%d baseline_p50=%.4f baseline_p95=%.4f compact_p50=%.4f compact_p95=%.4f delta_pct=%+.2f",
                name, samples, b50, b95, c50, c95, delta
            ))
        }
        return out
    }

    public enum Mode: Sendable {
        case list
        case grid
        case kitchenSink
    }

    public final class AppState: @unchecked Sendable {
        public var mode: Mode
        public var eagerList: Bool
        public var scaleBump: Bool = false
        public var reordered: Bool = false
        public var removed: Bool = false
        public let titles: [String]
        public let subtitles: [String]
        public let keys: [String]
        public let cells: [String]
        public let rowKeys: [String]
        public let listVirtual = VirtualListState()
        public let gridVirtual = VirtualListState()

        public init(mode: Mode, eagerList: Bool, rowCount: Int = 200, cellCount: Int = 1800) {
            self.mode = mode
            self.eagerList = eagerList
            self.titles = (0..<rowCount).map { String(format: "Demo App %03d", $0) }
            self.subtitles = (0..<rowCount).map { "Application · \(($0 * 37) % 91) uses this week" }
            self.keys = (0..<rowCount).map { "r\($0)" }
            let cells = (0..<cellCount).map { "E\($0 % 90)" }
            self.cells = cells
            let gridRowCount = (cells.count + columns - 1) / columns
            self.rowKeys = (0..<gridRowCount).map { "g\($0)" }
        }
    }

    private static func listRow(_ s: AppState, _ i: Int) -> El<AppState> {
        let ui = TextStyle(size: 14, weight: 400)
        return row()
            .wFull()
            .h(rowHeight)
            .px(10)
            .gap(10)
            .centerY()
            .child(el().size(22, 22).center().child(text("D").font(TextStyle(size: 12, weight: 600))))
            .child(
                col().key("copy").grow(1).shrink(1).gap(2).child(
                    row()
                        .key("line")
                        .wFull()
                        .gap(8)
                        .centerY()
                        .child(text(s.titles[i]).font(ui).ellipsis())
                        .child(text(s.subtitles[i]).font(ui).ellipsis().grow(1))
                )
            )
    }

    private static func gridRow(_ s: AppState, _ r: Int, cell: Float, glyph: Float) -> El<AppState> {
        var line: El<AppState> = row().wFull().h(cell)
        for c in 0..<columns {
            let index = r * columns + c
            guard index < s.cells.count else { break }
            line = line.child(
                el().key("c\(index)").size(cell, cell).center()
                    .child(el().size(glyph, glyph).center().child(text(s.cells[index]).font(TextStyle(size: 14, weight: 400))))
            )
        }
        return line
    }

    private static func kitchenSinkView(_ s: AppState) -> El<AppState> {
        let fs: Float = s.scaleBump ? 18 : 14
        let a: El<AppState> = text("Intrinsic wrapped text with min/max bounds")
            .key("txt_a")
            .font(TextStyle(size: fs, weight: 500))
            .minW(60)
            .maxW(180)
        let b: El<AppState> = text("Second baseline item")
            .key("txt_b")
            .font(TextStyle(size: fs + 4, weight: 400))
        let topRow: El<AppState> = (s.reordered
            ? row().key("baseline_row").wFull().gap(12).itemsCenter().child(b).child(a)
            : row().key("baseline_row").wFull().gap(12).itemsCenter().child(a).child(b))

        var grid: El<AppState> = el()
            .key("css_grid")
            .equalColumns(3)
            .gap(8)
            .wFull()
            .child(el().key("gc_span").gridCell(column: 0).h(32))
            .child(el().key("gc_mid").gridCell(column: 1).h(32))
        if !s.removed {
            grid = grid.child(el().key("gc_single").gridCell(column: 2).h(32))
        }

        let anchorBtn: El<AppState> = el().key("anchor_target").size(120, 34).bg(.white)
        let anchoredPop: El<AppState> = el()
            .key("anchored_pop")
            .anchored("anchor_target", side: .bottom, align: .start, gap: 6)
            .size(160, 48)
        let anchoredFitPop: El<AppState> = col()
            .key("anchored_fit_pop")
            .anchoredFit("anchor_target", side: .bottom, align: .start, gap: 6)
            .w(180)
            .child(el().key("tall_pop_body").wFull().h(600))
        let aspectBox: El<AppState> = el()
            .key("aspect_room")
            .w(240)
            .h(180)
            .child(el().key("aspect_inner").wFull().grow(1).aspectFit(16.0 / 9.0))
        let scrollVp: El<AppState> = col()
            .key("scroll_vp")
            .wFull()
            .grow(1)
            .minH(0)
            .scroll(stickBottom: false)
            .child(
                col().key("scroll_content").wFull().gap(6)
                    .child(el().key("scroll_item_1").wFull().h(220))
                    .child(el().key("scroll_item_2").wFull().h(220))
            )
            .child(el().key("pinned_badge").size(72, 24).pin(right: 10, bottom: 14))

        return col()
            .key("sink_root")
            .wFull()
            .hFull()
            .p(12)
            .gap(10)
            .child(topRow)
            .child(grid)
            .child(anchorBtn)
            .child(aspectBox)
            .child(scrollVp)
            .child(anchoredPop)
            .child(anchoredFitPop)
    }

    public static func appView(_ s: AppState, _ cx: inout Cx<AppState>) -> El<AppState> {
        switch s.mode {
        case .list:
            var rows: El<AppState> = col().key("rows").wFull().px(8).py(6).growth(.default)
            if s.eagerList {
                rows = rows.virtualize(rowHeight)
                    .children((0..<s.titles.count).map { i in listRow(s, i).key(s.keys[i]) })
            } else {
                rows = rows.virtualRows(
                    s.titles.count,
                    rowHeight,
                    key: { st, i in st.keys[i] },
                    build: { st, i in listRow(st, i) }
                )
            }
            return col().key("root").wFull().hFull().child(
                col().key("list").wFull().grow(1).minH(0).scroll(stickBottom: false).child(rows)
            )
        case .grid:
            let cell = (size.x - 16) / Float(columns)
            let glyph = min(cell * 0.5, 34)
            let rows = col()
                .key("rows")
                .wFull()
                .px(8)
                .py(6)
                .growth(.default)
                .virtualize(cell)
                .children((0..<s.rowKeys.count).map { r in
                    gridRow(s, r, cell: cell, glyph: glyph).key(s.rowKeys[r])
                })
            return col().key("root").wFull().hFull().child(
                col().key("grid").wFull().grow(1).shrink(1).scroll(stickBottom: false).child(rows)
            )
        case .kitchenSink:
            return kitchenSinkView(s)
        }
    }

    private static func onKey(_ s: inout AppState, _ k: KeyEvent, _ tx: inout Tx) -> Bool {
        switch k.key {
        case .escape:
            s.mode = .list
            return true
        case .tab:
            s.mode = .grid
            return true
        case .enter:
            s.scaleBump.toggle()
            s.reordered.toggle()
            s.removed.toggle()
            return true
        default:
            return false
        }
    }

    public static func runRuntimeSuite(samples: Int = 25, rowCount: Int = 200, cellCount: Int = 1800, raw: Bool = false) -> [String] {
        var lines: [String] = []
        let ts = TextSystem()
        let sinkRt = Runtime(
            state: AppState(mode: .kitchenSink, eagerList: false, rowCount: rowCount, cellCount: cellCount),
            viewport: size,
            pixelScale: 2.0,
            systemDark: true,
            textSystem: ts,
            onKey: onKey,
            view: appView
        )
        var now = 0.0
        _ = sinkRt.frame(at: now)
        let keys = [
            "sink_root", "baseline_row", "txt_a", "txt_b", "css_grid",
            "gc_span", "gc_mid", "gc_single", "anchor_target",
            "aspect_room", "aspect_inner", "scroll_vp", "pinned_badge",
            "anchored_pop", "anchored_fit_pop",
        ]
        for step in 0..<2 {
            if step == 1 {
                now += 1.0 / 120.0
                _ = sinkRt.keyDown(KeyEvent(key: .enter), at: now)
                for _ in 0..<240 {
                    now += 1.0 / 120.0
                    _ = sinkRt.frame(at: now)
                    if !sinkRt.isAnimating { break }
                }
            }
            var rects: [String] = []
            for k in keys {
                if let r = sinkRt.element(byKey: k)?.rect {
                    rects.append(String(format: "%@:%.2f,%.2f,%.2f,%.2f", k, r[0], r[1], r[2], r[3]))
                }
            }
            lines.append("RECT_DIGEST adapter=compact step=\(step) rects=\(rects.joined(separator: ";"))")
        }

        func makeWarmText() -> TextSystem {
            let t = TextSystem()
            _ = t.shape(text: "Warm Demo App 000 E0", style: TextStyle(size: 14, weight: 400), maxWidth: nil, pixelScale: 2.0, emitGlyphs: false)
            return t
        }

        var memEager: [Double] = []
        var memGrid: [Double] = []
        var memSwap: [Double] = []
        var gridCommit: [Double] = []
        var gridLayout: [Double] = []
        var swapCommit: [Double] = []
        var swapLayout: [Double] = []

        for i in 0...samples {
            do {
                let t = makeWarmText()
                let h0 = liveHeapBytes()
                let rt = Runtime(
                    state: AppState(mode: .list, eagerList: true, rowCount: rowCount, cellCount: cellCount),
                    viewport: size,
                    pixelScale: 2.0,
                    systemDark: true,
                    textSystem: t,
                    view: appView
                )
                _ = rt.frame(at: 0)
                if i > 0 {
                    memEager.append(Double(max(0, liveHeapBytes() - h0)))
                }
            }
            do {
                let t = makeWarmText()
                let h0 = liveHeapBytes()
                _ = takeFramePhases()
                let rt = Runtime(
                    state: AppState(mode: .grid, eagerList: false, rowCount: rowCount, cellCount: cellCount),
                    viewport: size,
                    pixelScale: 2.0,
                    systemDark: true,
                    textSystem: t,
                    onKey: onKey,
                    view: appView
                )
                var tNow = 0.0
                _ = rt.frame(at: tNow)
                let phasesGrid = takeFramePhases()
                let liveGrid = Double(max(0, liveHeapBytes() - h0))
                for _ in 0..<120 {
                    tNow += 1.0 / 120.0
                    _ = rt.frame(at: tNow)
                    if !rt.isAnimating { break }
                }
                _ = takeFramePhases()
                tNow += 1.0 / 120.0
                _ = rt.keyDown(KeyEvent(key: .escape), at: tNow)
                _ = rt.frame(at: tNow)
                let phasesSwap = takeFramePhases()
                for _ in 0..<120 {
                    tNow += 1.0 / 120.0
                    _ = rt.frame(at: tNow)
                    if !rt.isAnimating { break }
                }
                let liveSwap = Double(max(0, liveHeapBytes() - h0))
                if i > 0 {
                    let p = FRAME_PHASES
                    let cIdx = p + FramePhase.commit.rawValue
                    let lIdx = p + FramePhase.layout.rawValue
                    memGrid.append(liveGrid)
                    memSwap.append(liveSwap)
                    gridCommit.append(phasesGrid.count > cIdx ? phasesGrid[cIdx] : 0)
                    gridLayout.append(phasesGrid.count > lIdx ? phasesGrid[lIdx] : 0)
                    swapCommit.append(phasesSwap.count > cIdx ? phasesSwap[cIdx] : 0)
                    swapLayout.append(phasesSwap.count > lIdx ? phasesSwap[lIdx] : 0)
                }
            }
        }

        for (name, vec) in [
            ("combined_retained_eager_list_200_B", memEager),
            ("combined_retained_grid_1800_B", memGrid),
            ("combined_retained_after_grid_to_list_swap_B", memSwap),
            ("grid_1800_commit_ms", gridCommit),
            ("grid_1800_layout_ms", gridLayout),
            ("grid_to_list_swap_commit_ms", swapCommit),
            ("grid_to_list_swap_layout_ms", swapLayout),
        ] {
            if raw {
                for v in vec {
                    lines.append(String(format: "RAW adapter=compact metric=%@ val=%.6f", name, v))
                }
            }
            let (p50, p95) = stats(vec)
            lines.append(String(
                format: "RUNTIME adapter=compact metric=%@ n=%d p50=%.4f p95=%.4f",
                name, samples, p50, p95
            ))
        }
        return lines
    }

    public static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let samples: Int
        if let idx = args.firstIndex(of: "--samples"), idx + 1 < args.count, let v = Int(args[idx + 1]), v > 0 {
            samples = v
        } else {
            samples = 25
        }
        let raw = args.contains("--raw")
        var lines: [String] = []
        if !args.contains("--runtime-only") {
            lines.append(contentsOf: runIsolatedPairedBench(samples: samples))
        }
        lines.append(contentsOf: runRuntimeSuite(samples: samples, raw: raw))
        print(lines.joined(separator: "\n"))
    }
}
