import Testing
import Foundation
import RuneRef
@testable import Rune

/// Port of `crates/rune/src/runtime/virtual_selection_tests.rs`: text selection across virtual
/// rows (`El.virtualRows`): pinned anchor and focus rows, identity-based ends across
/// mount/unmount, on-demand copy across unbuilt rows (with `\t` for side-by-side cells and `\n`
/// otherwise), Cmd+A / `Tx.selectAllText` over a virtual list, `Tx.selectText` on an unbuilt row,
/// and bounded offscreen collection.
@Suite("virtual_selection_tests.rs parity", .serialized)
struct VirtualSelectionParityTests {
    static let rows = 55
    static let rowH: Float = 56.0

    /// `BUILT_ROWS`: how many times a row was built.
    final class Built {
        var count = 0
    }

    struct Timeline {
        var count: Int
        var bigBytes: Int = 0
        let built = Built()

        init(count: Int, bigBytes: Int = 0) {
            self.count = count
            self.bigBytes = bigBytes
        }
    }

    static func rowExpected(_ i: Int) -> String {
        if i % 5 == 2 {
            return String(format: "Row %02d header\nleft-%02d\tright-%02d", i, i, i)
        }
        return String(format: "Row %02d header\nMessage body for virtual row %02d with words to select.", i, i)
    }

    static func buildTimelineRow(_ s: Timeline, _ i: Int) -> El<Timeline> {
        s.built.count += 1
        let style = TextStyle(size: 14.0, weight: 400.0).lh(20.0)
        let head: El<Timeline> = text(String(format: "Row %02d header", i))
            .key("head")
            .font(style)
            .wFull()
            .selectable(true)
        let body: El<Timeline>
        if s.bigBytes > 0 {
            let filler = String(repeating: "abcd ", count: s.bigBytes / 5)
            body = text(String(format: "Row %05d ", i) + filler)
                .key("t\(i)")
                .font(style)
                .wFull()
                .selectable(true)
        } else if i % 5 == 2 {
            body = row().key("cells").wFull()
                .child(text(String(format: "left-%02d", i)).key("c0").font(style).w(160.0).selectable(true))
                .child(text(String(format: "right-%02d", i)).key("c1").font(style).w(160.0).selectable(true))
        } else {
            body = text(String(format: "Message body for virtual row %02d with words to select.", i))
                .key("body")
                .font(style)
                .wFull()
                .selectable(true)
        }
        return col().wFull().h(rowH).p(6.0).gap(4.0).child(head).child(body)
    }

    static func timelineView(_ s: Timeline, _: inout Cx<Timeline>) -> El<Timeline> {
        col().wFull().hFull().child(
            col().key("scroll").wFull().grow(1.0).scroll(stickBottom: false).child(
                col()
                    .key("timeline")
                    .wFull()
                    .growth(.default)
                    .selectionGroup(true)
                    .virtualRows(
                        s.count,
                        rowH,
                        key: { _, i in "r\(i)" },
                        build: buildTimelineRow
                    )
            )
        )
    }

    static func headerTimelineView(_ s: Timeline, _: inout Cx<Timeline>) -> El<Timeline> {
        let style = TextStyle(size: 14.0, weight: 400.0).lh(20.0)
        return col().wFull().hFull().child(
            col()
                .key("scroll")
                .wFull()
                .grow(1.0)
                .scroll(stickBottom: false)
                .selectionGroup(true)
                .child(
                    col().key("header").wFull().h(84.0).p(6.0).child(
                        text("Pinned thread header").key("title").font(style).wFull().selectable(true)
                    )
                )
                .child(
                    col()
                        .key("timeline")
                        .wFull()
                        .growth(.default)
                        .virtualRows(
                            s.count,
                            rowH,
                            key: { _, i in "r\(i)" },
                            build: buildTimelineRow
                        )
                )
        )
    }

    /// The runtime, the clock, and `support`'s helpers over them.
    final class Harness {
        let rt: Runtime<Timeline>
        var t = 0.0

        init(_ state: Timeline, view: @escaping (Timeline, inout Cx<Timeline>) -> El<Timeline>) {
            rt = Runtime<Timeline>(state: state, viewport: Vec2(1280.0, 420.0), pixelScale: 2.0, systemDark: true, view: view)
            _ = rt.frame(at: t)
            // `while rt.frame(1.0 / 120.0) {}`
            for _ in 0..<600 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
                if !rt.isAnimating && !rt.needsCommit { break }
            }
        }

        var built: Int {
            get { rt.state.built.count }
            set { rt.state.built.count = newValue }
        }

        var list: String {
            rt.virtualLists.keys.first(where: { $0.hasSuffix("/@timeline") }) ?? ""
        }

        var range: Range<Int> { rt.virtualLists[list]?.lastMountedRange ?? 0..<0 }

        /// `tick`.
        func tick() {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }

        /// `settle`: up to twenty frames, while one asks for another.
        func settle() {
            for _ in 0..<20 {
                tick()
                if !rt.isAnimating && !rt.needsCommit { break }
            }
        }

        /// `command`.
        func command(_ c: Character) {
            _ = rt.keyDown(KeyEvent(key: .command(c), mods: Mods(cmd: true)), at: t)
            tick()
        }

        func wheel(_ x: Float, _ y: Float, _ dy: Float) {
            rt.wheel(WheelEvent(dx: 0, dy: dy), at: Vec2(x, y), now: t)
        }

        func modifiers(_ mods: Mods) {
            _ = rt.physicalInput(.modifiers(mods), at: t)
        }

        /// `find_path`: the element whose path ends in `suffix`.
        func findPath(_ suffix: String) -> ElementInfo? {
            rt.elements().first(where: { $0.path.hasSuffix(suffix) })
        }

        /// `glyphs_at`: centres (points) of the glyphs drawn inside the element at `suffix`, by x.
        func glyphs(at suffix: String) -> [Vec2] {
            guard let e = findPath(suffix) else { return [] }
            let scale = rt.pixelScale
            return rt.renderFrame(at: t).instances
                .filter { $0.params.y == KIND_GLYPH }
                .map { Vec2(($0.rect.x + $0.rect.z / 2.0) / scale, ($0.rect.y + $0.rect.w / 2.0) / scale) }
                .filter { $0.x >= e.rect[0] && $0.x <= e.rect[0] + e.rect[2] && $0.y >= e.rect[1] && $0.y <= e.rect[1] + e.rect[3] }
                .sorted { $0.x < $1.x }
        }
    }

    static func before(_ g: Vec2) -> Vec2 { Vec2(g.x - 3.0, g.y) }

    static func timeline(_ count: Int) -> Harness {
        let h = Harness(Timeline(count: count), view: timelineView)
        h.built = 0
        return h
    }

    // MARK: - virtual_selection_tests.rs:136

    @Test("cmd_a_and_select_all_text_over_55_virtual_rows_copy_every_row")
    func cmdAAndSelectAllTextOver55VirtualRowsCopyEveryRow() {
        let h = Self.timeline(Self.rows)
        let mounted = h.range
        #expect(mounted == 0..<23, "55 rows in 1280x420 mounts 23 rows")

        let expected = (0..<Self.rows).map(Self.rowExpected).joined(separator: "\n")

        // 1. Cmd+A selects from the first row to the last row without mounting the unbuilt middle.
        h.built = 0
        h.command("a")
        #expect(
            h.built <= mounted.count + 3,
            "Cmd+A builds only the mounted window plus offscreen end row(s), built \(h.built)"
        )
        #expect(h.range == 0..<23, "mounted window unchanged")
        #expect(h.findPath("/@r0/@head")?.selected == "Row 00 header")
        #expect(h.findPath("/@r22/@head")?.selected == "Row 22 header")

        h.command("c")
        #expect(h.rt.clipboard.text == expected)
        #expect(h.rt.selectedText() == expected)

        // Clearing the selection releases the pinned rows.
        h.rt.update(at: h.t) { _, tx in tx.clearTextSelection() }
        h.tick()
        #expect(h.rt.virtualSelectionPinnedRows(h.list).isEmpty)

        // 2. Scrolled to the middle (neither r0 nor r54 mounted), Tx.selectAllText("timeline")
        // pins both ends and copies all 55 rows.
        for _ in 0..<6 {
            h.wheel(640.0, 210.0, -160.0)
            h.tick()
        }
        h.settle()
        let midRange = h.range
        #expect(midRange.lowerBound > 0 && midRange.upperBound < Self.rows, "middle window: \(midRange)")

        h.rt.update(at: h.t) { _, tx in tx.selectAllText("timeline") }
        h.tick()
        #expect(h.rt.selectedText() == expected)
    }

    // MARK: - virtual_selection_tests.rs:183

    @Test("selection_from_row_3_to_row_40_copies_all_rows_in_between_in_order")
    func selectionFromRow3ToRow40CopiesAllRowsInBetweenInOrder() throws {
        let h = Self.timeline(Self.rows)

        // Built-only selection (row 1 to row 2, which has side-by-side cells) stays byte-identical.
        // Non-space glyph indices in "Message body for virtual row XX with words to select.":
        // 0..7 = "Message", 7..11 = "body", 11..14 = "for", 14..21 = "virtual", 21..24 = "row", 24..26 = "XX", 26..30 = "with"
        let r1 = h.glyphs(at: "/@r1/@body")
        let r2c1 = h.glyphs(at: "/@r2/@cells/@c1")
        try #require(r1.count > 7 && r2c1.count > 5)
        h.rt.pointerMove(to: Self.before(r1[7]), at: h.t)
        h.rt.pointerDown(at: Self.before(r1[7]), at: h.t)
        h.tick()
        h.rt.pointerMove(to: Self.before(r2c1[5]), at: h.t)
        h.tick()
        h.rt.pointerUp(at: Self.before(r2c1[5]), at: h.t)
        h.tick()
        #expect(h.rt.selectedText() == "body for virtual row 01 with words to select.\nRow 02 header\nleft-02\tright")

        // Click inside row 3 body ("virtual row 03 with words to select.") to place the anchor.
        let r3 = h.glyphs(at: "/@r3/@body")
        try #require(r3.count > 14)
        let startPt = Self.before(r3[14]) // before "virtual"
        h.rt.pointerMove(to: startPt, at: h.t)
        h.rt.pointerDown(at: startPt, at: h.t)
        h.rt.pointerUp(at: startPt, at: h.t)
        h.tick()

        // Scroll down until row 40 is visible inside the 420px viewport (40 * 56 - 1980 = 260) and
        // row 3 is outside the viewport window.
        for _ in 0..<11 {
            h.wheel(640.0, 210.0, -180.0)
            h.tick()
        }
        h.settle()
        let range = h.range
        #expect(!range.contains(3) && range.contains(40), "r3 unmounted, r40 mounted: \(range)")

        // Shift-click in row 40 body right after "40" (glyph 25).
        let r40 = h.glyphs(at: "/@r40/@body")
        try #require(r40.count > 25)
        let endPt = Vec2(r40[25].x + 3.0, r40[25].y)
        #expect(endPt.y > 0.0 && endPt.y < 420.0, "r40/body inside viewport: \(endPt)")
        h.modifiers(Mods(shift: true))
        h.rt.pointerMove(to: endPt, at: h.t)
        h.rt.pointerDown(at: endPt, at: h.t)
        h.rt.pointerUp(at: endPt, at: h.t)
        h.modifiers(.none)
        h.tick()

        var expectedParts = ["virtual row 03 with words to select."]
        for i in 4..<40 {
            expectedParts.append(Self.rowExpected(i))
        }
        expectedParts.append("Row 40 header\nMessage body for virtual row 40")
        let expected = expectedParts.joined(separator: "\n")

        #expect(h.rt.selectedText() == expected)
        h.command("c")
        #expect(h.rt.clipboard.text == expected)
    }

    // MARK: - virtual_selection_tests.rs:246

    @Test("selection_scrolled_far_away_and_back_keeps_highlight")
    func selectionScrolledFarAwayAndBackKeepsHighlight() throws {
        let h = Self.timeline(Self.rows)
        let g = h.glyphs(at: "/@r1/@body")
        try #require(g.count > 10)
        let (p0, p1) = (Self.before(g[0]), Vec2(g[10].x + 3.0, g[10].y))
        h.rt.pointerMove(to: p0, at: h.t)
        h.rt.pointerDown(at: p0, at: h.t)
        h.tick()
        h.rt.pointerMove(to: p1, at: h.t)
        h.tick()
        h.rt.pointerUp(at: p1, at: h.t)
        h.tick()

        #expect(h.rt.selectedText() == "Message body")
        #expect(h.findPath("/@r1/@body")?.selected == "Message body")

        // Scroll to the very bottom so row 1 is far outside the mounted window.
        for _ in 0..<20 {
            h.wheel(640.0, 210.0, -200.0)
            h.tick()
        }
        h.settle()
        #expect(!h.rt.elements().contains(where: { $0.path.hasSuffix("/@r1/@body") }), "r1 is unmounted")
        #expect(h.rt.selectedText() == "Message body", "selection survives offscreen")

        // Scroll all the way back to the top: the highlight on r1/body is still there.
        for _ in 0..<20 {
            h.wheel(640.0, 210.0, 200.0)
            h.tick()
        }
        h.settle()
        #expect(h.findPath("/@r1/@body")?.selected == "Message body")
        #expect(h.rt.selectedText() == "Message body")
    }

    // MARK: - virtual_selection_tests.rs:281

    @Test("dragging_selection_while_scrolling_across_virtual_rows_keeps_working")
    func draggingSelectionWhileScrollingAcrossVirtualRowsKeepsWorking() throws {
        let h = Self.timeline(Self.rows)
        let g3 = h.glyphs(at: "/@r3/@head")
        try #require(!g3.isEmpty)
        let p0 = Self.before(g3[0])
        h.rt.pointerMove(to: p0, at: h.t)
        h.rt.pointerDown(at: p0, at: h.t)
        h.tick()

        // Drag down while the list scrolls until row 3 is unmounted and row 40 is under the pointer.
        for _ in 0..<12 {
            h.wheel(640.0, 210.0, -180.0)
            h.rt.pointerMove(to: Vec2(p0.x + 40.0, 350.0), at: h.t)
            h.tick()
        }
        h.settle()
        #expect(!h.range.contains(3), "anchor row 3 scrolled out")

        let g40 = h.glyphs(at: "/@r40/@head")
        let last = try #require(g40.last)
        let p1 = Vec2(last.x + 4.0, last.y)
        h.rt.pointerMove(to: p1, at: h.t)
        h.tick()
        h.rt.pointerUp(at: p1, at: h.t)
        h.tick()

        var expectedParts = (3..<40).map(Self.rowExpected)
        expectedParts.append("Row 40 header")
        let expected = expectedParts.joined(separator: "\n")
        #expect(h.rt.selectedText() == expected)
    }

    // MARK: - virtual_selection_tests.rs:312

    @Test("tx_select_text_on_unbuilt_row_pins_and_applies_without_scrolling")
    func txSelectTextOnUnbuiltRowPinsAndAppliesWithoutScrolling() {
        let h = Self.timeline(Self.rows)
        #expect(h.range == 0..<23)
        #expect(!h.rt.elements().contains(where: { $0.path.hasSuffix("/@r45/@body") }), "r45 starts unbuilt")

        h.rt.update(at: h.t) { _, tx in tx.selectText("r45/body", range: 0..<12) }
        h.tick()

        // Must not scroll or mount row 45 into the layout window.
        #expect(h.range == 0..<23, "did not scroll")
        #expect(h.rt.selectedText() == "Message body")
        let got = h.rt.textSelection()
        #expect(got?.path == "\(h.list)/@r45/@body" && got?.range == 0..<12)

        // When the user later scrolls down to row 45, its highlight is drawn.
        for _ in 0..<20 {
            h.wheel(640.0, 210.0, -200.0)
            h.tick()
        }
        h.settle()
        #expect(h.findPath("/@r45/@body")?.selected == "Message body")
    }

    @Test("offscreen selection uses the full, resolved virtual row key")
    func offscreenSelectionUsesResolvedRowKey() {
        let h = Harness(Timeline(count: Self.rows)) { state, _ in
            col().wFull().hFull().scroll(stickBottom: false).child(
                col().key("timeline").wFull().selectionGroup(true).virtualRows(
                    state.count,
                    Self.rowH,
                    key: { _, i in
                        if i == 44 || i == 45 { return "repeated" }
                        if i == 46 { return "group/item" }
                        return "r\(i)"
                    },
                    build: Self.buildTimelineRow
                )
            )
        }
        for (row, key) in [(45, "repeated#dup1"), (46, "group/item")] {
            #expect(!h.range.contains(row))
            h.rt.update(at: h.t) { _, tx in tx.selectText("\(key)/head", range: 0..<13) }
            h.tick()
            #expect(h.rt.selectedText() == "Row \(row) header")
            #expect(h.rt.selectionState.coordinator.phase.selection?.anchorEnd?.rowKey == key)
        }
    }

    // MARK: - virtual_selection_tests.rs:338

    @Test("offscreen_collection_is_bounded_in_rows_and_bytes")
    func offscreenCollectionIsBoundedInRowsAndBytes() throws {
        // 1. Row count cap: 50,000 rows builds at most maxVirtualCopyRows unbuilt rows on copy.
        let h = Self.timeline(50_000)
        let mountedLen = h.range.count
        h.built = 0
        h.rt.update(at: h.t) { _, tx in tx.selectAllText("timeline") }
        h.tick()
        let builtOnSelect = h.built
        #expect(
            builtOnSelect <= mountedLen + 3,
            "selecting all builds only mounted window + pinned ends, got \(builtOnSelect)"
        )

        h.built = 0
        let start = Date()
        let copied = try #require(h.rt.selectedText(), "bounded copy returns prefix")
        let elapsed = Date().timeIntervalSince(start)
        let builtOnCopy = h.built
        #expect(
            builtOnCopy <= VirtualCopyLimits.maxRows,
            "built \(builtOnCopy) rows > cap \(VirtualCopyLimits.maxRows)"
        )
        #expect(copied.hasPrefix("Row 00 header\n"), "copied starts \(copied.prefix(80)), selection \(String(describing: h.rt.selectionState.coordinator.phase.selection?.path)) far \(String(describing: h.rt.selectionState.coordinator.phase.selection?.far?.path))")
        #expect(elapsed < 2.0, "bounded collection took \(elapsed)s")

        // 2. Byte cap: large rows stop building as soon as maxVirtualCopyBytes is reached.
        let big = Harness(Timeline(count: 5_000, bigBytes: 4_000), view: Self.timelineView)
        big.settle()
        big.rt.update(at: big.t) { _, tx in tx.selectAllText("timeline") }
        big.tick()
        big.built = 0
        let bigCopied = try #require(big.rt.selectedText(), "byte-capped copy")
        #expect(
            bigCopied.utf8.count <= VirtualCopyLimits.maxBytes,
            "copied \(bigCopied.utf8.count) bytes > cap \(VirtualCopyLimits.maxBytes)"
        )
        #expect(big.built < 1_200, "byte cap stopped building early after \(big.built) rows")
    }

    // MARK: - virtual_selection_tests.rs:418

    @Test("header_before_virtual_list_keeps_pinned_selection_and_copies_across_unbuilt_rows")
    func headerBeforeVirtualListKeepsPinnedSelectionAndCopiesAcrossUnbuiltRows() throws {
        let h = Harness(Timeline(count: Self.rows), view: Self.headerTimelineView)
        #expect(h.rt.virtualLists[h.list]?.top == 84.0)

        // Click in row 3 body before "virtual" (y = 84 + 3 * 56 = 252..308, inside the 420px viewport).
        let r3 = h.glyphs(at: "/@r3/@body")
        try #require(r3.count > 14)
        let startPt = Self.before(r3[14])
        h.rt.pointerMove(to: startPt, at: h.t)
        h.rt.pointerDown(at: startPt, at: h.t)
        h.rt.pointerUp(at: startPt, at: h.t)
        h.tick()

        // Scroll down until row 3 is unmounted and row 40 is visible inside the viewport.
        for _ in 0..<11 {
            h.wheel(640.0, 210.0, -180.0)
            h.tick()
        }
        h.settle()
        let range = h.range
        #expect(!range.contains(3) && range.contains(40), "r3 unmounted, r40 mounted: \(range)")

        let r40 = h.glyphs(at: "/@r40/@body")
        try #require(r40.count > 25)
        let endPt = Vec2(r40[25].x + 3.0, r40[25].y)
        #expect(endPt.y > 0.0 && endPt.y < 420.0, "r40/body inside viewport: \(endPt)")
        h.modifiers(Mods(shift: true))
        h.rt.pointerMove(to: endPt, at: h.t)
        h.rt.pointerDown(at: endPt, at: h.t)
        h.rt.pointerUp(at: endPt, at: h.t)
        h.modifiers(.none)
        h.tick()

        var expectedParts = ["virtual row 03 with words to select."]
        for i in 4..<40 {
            expectedParts.append(Self.rowExpected(i))
        }
        expectedParts.append("Row 40 header\nMessage body for virtual row 40")
        let expected = expectedParts.joined(separator: "\n")
        #expect(h.rt.selectedText() == expected)
        h.command("c")
        #expect(h.rt.clipboard.text == expected)

        // Selecting all of the group from the middle window includes the header and all 55 rows.
        h.rt.update(at: h.t) { _, tx in tx.selectAllText("scroll") }
        h.tick()
        var fullParts = ["Pinned thread header"]
        fullParts.append(contentsOf: (0..<Self.rows).map(Self.rowExpected))
        let fullExpected = fullParts.joined(separator: "\n")
        #expect(h.rt.selectedText() == fullExpected)
    }
}
