import Foundation
import Testing
import Rune
@testable import RuneKit

@Suite("RuneKit Increment 4: Shell, SplitView, Sidebar, Reorder & TabStrip Tests")
struct ShellAndTabStripTests {

    // MARK: - PaneState, PaneMotion, SidebarPeek & isSidebarToggle (`shell/pane.rs`, `tests/shell.rs`)

    @Test("PaneState supports range clamping, grip drag collapse, peek phases, and resetWidth")
    func paneStateLifecycle() {
        var pane = PaneState(width: 240).range(160, 480)
        #expect(pane.isOpen && !pane.isCollapsed)
        #expect(pane.shownWidth == 240)
        #expect(pane.defaultWidth == 240)

        // Grip resize grows/shrinks and collapses below 80pt
        pane.pressGrip(at: Vec2(240, 100))
        #expect(pane.isResizing)
        pane.dragGrip(deltaX: 80, at: Vec2(320, 100), positiveGrows: true)
        #expect(pane.width == 320)
        pane.dragGrip(deltaX: -180, at: Vec2(60, 100), positiveGrows: true)
        #expect(pane.isCollapsed && pane.shownWidth == 0)
        pane.releaseGrip()
        #expect(!pane.isResizing)

        // Reset restores defaultWidth without forcing collapsed pane open
        pane.resetWidth()
        #expect(pane.isCollapsed && pane.width == 240)

        // Negative growth (inspector on trailing side)
        var inspector = PaneState(width: 300).range(min: 200, max: 500)
        inspector.pressGrip(at: Vec2(700, 100))
        inspector.dragGrip(deltaX: -50, at: Vec2(650, 100), positiveGrows: false)
        #expect(inspector.width == 350)
        // Pointer lost-release detection drops grip on two unheard moves
        let firstMoveLost = inspector.pointerGrip(movedTo: Vec2(400, 100))
        let secondMoveLost = inspector.pointerGrip(movedTo: Vec2(410, 110))
        #expect(!firstMoveLost)
        #expect(secondMoveLost)
        #expect(!inspector.isResizing)

        // Peek phase transitions & fromPeek distinction
        pane.setOpen(false)
        #expect(pane.peekPhase == .rest)
        pane.peek()
        #expect(pane.isPeeking && pane.peekPhase == .shown)
        pane.endPeek()
        #expect(!pane.isPeeking && pane.peekPhase == .left)
        pane.peek()
        pane.setOpen(true)
        #expect(pane.isOpen && pane.fromPeek)
        pane.setOpen(false)
        pane.setOpen(true)
        #expect(!pane.fromPeek)
    }

    @Test("PaneMotion, SidebarPeek, KitIcons.sidebar/inspector & isSidebarToggle parity")
    func motionPeekIconsAndShortcut() {
        #expect(KitIcons.sidebar.paths.count == 2)
        #expect(KitIcons.inspector.paths.count == 2)
        let customMotion = PaneMotion().scaleWithWidth(reference: 240, min: 0.1, max: 0.4).fadeTail(0.3).reducedMotionFade(0.12)
        #expect(customMotion.spring(forWidth: 240, kit: Kit.neutral(dark: false)).duration >= 0.1)
        #expect(PaneMotion.slide.spring(reducedMotion: false) != nil)
        #expect(PaneMotion.instant.spring(reducedMotion: false) == nil)
        #expect(PaneMotion.slide.spring(reducedMotion: true) == nil)
        #expect(SidebarPeek.off.isEnabled == false)
        let customPeek = SidebarPeek().edge(20, delay: 0.04).toggleDelay(0.08).below(38).hold(margin: 14, grace: 0.2)
        #expect(customPeek.isEnabled && customPeek.edgeWidth == 20 && customPeek.belowY == 38 && customPeek.holdMargin == 14)
        #expect(SidebarPeek.hover.isEnabled && SidebarPeek.hover.edgeWidth == 16)

        #expect(!isSidebarToggle(.text("b"), mods: Mods(cmd: true), macOS: true))
        #expect(isSidebarToggle(.text("b"), mods: Mods(shift: true, cmd: true), macOS: true))
        #expect(!isSidebarToggle(.text("b"), mods: Mods(ctrl: true), macOS: true))
        #expect(isSidebarToggle(.text("b"), mods: Mods(shift: true, ctrl: true), macOS: false))
        #expect(isSidebarToggle(.text("s"), mods: Mods(ctrl: true, cmd: true), macOS: true))
        #expect(!isSidebarToggle(.text("s"), mods: Mods(ctrl: true, cmd: true), macOS: false))
    }

    // MARK: - Reorder (`shell/reorder.rs`, `tests/reorder.rs`)

    @Test("Reorder enforces 4pt slop, tracks pitch/shifts, emits on drop, and catches lost release")
    func reorderStateMachine() {
        var reorder = Reorder<String>().gap(4.0)
        reorder.press(id: "a", index: 0, at: Vec2(40, 10))
        #expect(reorder.isHeld && !reorder.isDragging)
        #expect(reorder.dragging() == nil && reorder.target() == nil)

        // Movement within 4pt slop stays not-dragging
        #expect(reorder.drag(to: Vec2(40, 13), rowHeight: 28, count: 4) == nil)
        #expect(!reorder.isDragging && reorder.offsetY == 0)

        // Crossing slop starts drag; pitch = 28 + 4 = 32; 20pt moves target 0 -> 1 and shifts sibling 1 by -32
        _ = reorder.drag(to: Vec2(40, 30), rowHeight: 28, count: 4)
        #expect(reorder.isDragging && reorder.draggingId == "a")
        #expect(reorder.dragging() == 0 && reorder.target() == 1)
        #expect(reorder.shift(forIndex: 0) == 20)
        #expect(reorder.shift(forIndex: 1) == -32)
        #expect(reorder.shift(forIndex: 2) == 0)

        // Drop commits (0, 1)
        var dropReorder = Reorder<String>().gap(4.0)
        dropReorder.press(id: "a", index: 0, at: Vec2(40, 10))
        _ = dropReorder.drag(to: Vec2(40, 42), rowHeight: 28, count: 4)
        let committed = dropReorder.end(cancelled: false)
        #expect(committed?.from == 0 && committed?.to == 1)

        // Cancelled drop emits nil
        var cancelReorder = Reorder<String>().gap(4.0)
        cancelReorder.press(id: "a", index: 0, at: Vec2(40, 10))
        _ = cancelReorder.drag(to: Vec2(40, 42), rowHeight: 28, count: 4)
        #expect(cancelReorder.end(cancelled: true) == nil)

        // Pointer lost-release cancels cleanly
        let firstReorderMoveLost = reorder.pointerMoved(to: Vec2(90, 90))
        let secondReorderMoveLost = reorder.pointerMoved(to: Vec2(95, 95))
        #expect(!firstReorderMoveLost)
        #expect(secondReorderMoveLost)
        #expect(!reorder.isHeld && !reorder.isDragging)
    }

    // MARK: - WindowTitlebar, Toolbar, Sidebar, SidebarRow & SplitView (`shell.rs`, `shell_desktop.rs`)

    @Test("WindowTitlebar.fromInsets and Toolbar render exact heights in Runtime")
    func titlebarAndToolbarRuntime() throws {
        struct Dummy {}
        let kit = Kit.neutral(dark: false)
        let insets = ChromeInsets(leading: 72, trailing: 14, top: 44)
        let rt = Runtime(state: Dummy(), viewport: Vec2(640, 240), systemDark: false) { _, _ in
            col().sizeFull()
                .child(WindowTitlebar<Dummy>.fromInsets(insets, title: "Workspace").build(kit))
                .child(Toolbar<Dummy>(title: "Session").build(kit))
        }
        rt.frame(at: 0.0)
        let tbRect = try #require(rt.element(byKey: "window-titlebar")).rect
        let barRect = try #require(rt.element(byKey: "toolbar")).rect
        let leadRect = try #require(rt.element(byKey: "window-titlebar-leading")).rect
        #expect(abs(tbRect[3] - 44.0) < 0.5)
        #expect(abs(barRect[3] - 48.0) < 0.5)
        #expect(leadRect[2] >= 72.0)
    }

    @Test("Sidebar section collapse, SidebarRow close/rename/drag reorder work interactively in Runtime")
    func sidebarAndRowRuntime() throws {
        struct RowItem { var id: String; var title: String }
        struct S {
            var collapsed = false
            var selected = "a"
            var renamingId: String? = nil
            var renameEdit = TextEdit("Renamed A")
            var items = [
                RowItem(id: "a", title: "Alpha"),
                RowItem(id: "b", title: "Beta"),
                RowItem(id: "c", title: "Gamma"),
            ]
            var reorder = Reorder<String>()
            var closed: [String] = []
        }

        let kit = Kit.neutral(dark: false)
        let rt = Runtime(state: S(), viewport: Vec2(260, 320), systemDark: false) { s, _ in
            var section = SidebarSection<S>(key: "sec", title: "Files")
                .collapsible(true, collapsed: s.collapsed)
                .onToggle { st, _ in st.collapsed.toggle() }

            for (idx, item) in s.items.enumerated() {
                let id = item.id
                var rowBuilder = SidebarRow<S>(key: "row-\(id)", title: item.title)
                    .selected(s.selected == id)
                    .status(.badge("1"))
                    .onClick { st, _ in st.selected = id }
                    .onClose { st, _ in
                        st.closed.append(id)
                        st.items.removeAll { $0.id == id }
                    }
                    .reorder(\.reorder, id: id, index: idx, count: s.items.count) { st, from, to in
                        let moved = st.items.remove(at: from)
                        st.items.insert(moved, at: to)
                    }
                    .reorderState(s.reorder, id: id)
                if s.renamingId == id {
                    rowBuilder = rowBuilder.renaming(\.renameEdit, onCommit: { st, value, _ in
                        if let i = st.items.firstIndex(where: { $0.id == id }) {
                            st.items[i].title = value
                        }
                        st.renamingId = nil
                    }, onCancel: { st, _ in
                        st.renamingId = nil
                    })
                }
                section = section.child(rowBuilder.build(kit))
            }

            return Sidebar<S>(key: "sb")
                .header(SidebarHeader<S>(title: "Repo").subtitle("main").build(kit))
                .section(section.build(kit))
                .build(kit)
        }

        rt.frame(at: 0.0)
        // Row close button closes item
        let closeB = try #require(rt.element(byKey: "row-b-close")).rect
        rt.pointerDown(at: Vec2(closeB[0] + closeB[2] * 0.5, closeB[1] + closeB[3] * 0.5), at: 0.05)
        rt.pointerUp(at: Vec2(closeB[0] + closeB[2] * 0.5, closeB[1] + closeB[3] * 0.5), at: 0.06)
        rt.frame(at: 0.07)
        #expect(rt.state.closed == ["b"])
        #expect(rt.state.items.map(\.id) == ["a", "c"])

        // Drag row-a down past row-c midpoint -> swaps items ["c", "a"]
        let rowARect = try #require(rt.element(byKey: "row-a")).rect
        let startPt = Vec2(rowARect[0] + 24, rowARect[1] + rowARect[3] * 0.5)
        rt.pointerDown(at: startPt, at: 0.1)
        rt.pointerMove(to: Vec2(startPt.x, startPt.y + 30), at: 0.12)
        rt.pointerUp(at: Vec2(startPt.x, startPt.y + 30), at: 0.14)
        rt.frame(at: 0.15)
        #expect(rt.state.items.map(\.id) == ["c", "a"])

        // Escape mid-drag cancels reorder cleanly without changing items; a subsequent press starts fresh
        let rowCRect = try #require(rt.element(byKey: "row-c")).rect
        let cStart = Vec2(rowCRect[0] + 24, rowCRect[1] + rowCRect[3] * 0.5)
        rt.pointerDown(at: cStart, at: 0.16)
        rt.pointerMove(to: Vec2(cStart.x, cStart.y + 30), at: 0.17)
        rt.frame(at: 0.18)
        #expect(rt.state.reorder.isDragging)
        _ = rt.keyDown(KeyEvent(key: .escape), at: 0.185)
        rt.frame(at: 0.19)
        #expect(!rt.state.reorder.isDragging)
        #expect(rt.state.items.map(\.id) == ["c", "a"])
        for i in 1...30 {
            rt.frame(at: 0.19 + Double(i) * (1.0 / 60.0))
        }

        // Lost pointer release (another press without pointerUp) lets go and drags the new row
        rt.pointerDown(at: cStart, at: 0.71)
        rt.pointerMove(to: Vec2(cStart.x, cStart.y + 10), at: 0.72)
        rt.frame(at: 0.73)
        let rowA2 = try #require(rt.element(byKey: "row-a")).rect
        let a2Start = Vec2(rowA2[0] + 24, rowA2[1] + rowA2[3] * 0.5)
        rt.pointerDown(at: a2Start, at: 0.74)
        rt.pointerMove(to: Vec2(a2Start.x, a2Start.y - 30), at: 0.75)
        rt.pointerUp(at: Vec2(a2Start.x, a2Start.y - 30), at: 0.76)
        rt.frame(at: 0.77)
        #expect(rt.state.items.map(\.id) == ["a", "c"])
        // Swap back to ["c", "a"] so rename index stays untouched below
        rt.state.items.swapAt(0, 1)
        rt.markNeedsCommit()
        rt.frame(at: 0.78)

        // Rename submit commits updated title
        rt.state.renamingId = "a"
        rt.markNeedsCommit()
        rt.frame(at: 0.80)
        _ = rt.keyDown(KeyEvent(key: .enter, mods: .none), at: 0.22)
        rt.frame(at: 0.23)
        #expect(rt.state.renamingId == nil)
        #expect(rt.state.items.first(where: { $0.id == "a" })?.title == "Renamed A")

        // Collapsible section header toggles rows off
        let hdr = try #require(rt.element(byKey: "sec-header")).rect
        rt.pointerDown(at: Vec2(hdr[0] + 16, hdr[1] + hdr[3] * 0.5), at: 0.30)
        rt.pointerUp(at: Vec2(hdr[0] + 16, hdr[1] + hdr[3] * 0.5), at: 0.31)
        rt.frame(at: 0.32)
        #expect(rt.state.collapsed)
        #expect(rt.element(byKey: "row-a") == nil)
    }

    @Test("SplitView resizes, collapses, toggles via SidebarToggle, and shows peek drawer in Runtime")
    func splitViewRuntime() throws {
        struct S {
            var sidebar = PaneState(width: 220).range(140, 360)
        }
        let kit = Kit.neutral(dark: false)
        let rt = Runtime(state: S(), viewport: Vec2(800, 400), systemDark: false) { s, _ in
            SplitView<S>(key: "sv") { _ in
                Page<S>().child(text("Body")).build(kit)
            }
            .sidebar(\.sidebar, current: s.sidebar) { _ in
                Sidebar<S>().section(SidebarSection<S>(title: "Nav").build(kit)).build(kit)
            }
            .toolbarInPanel(true)
            .sidebarPeek(.hover)
            .paneMotion(.instant)
            .build(s, kit: kit)
        }

        rt.frame(at: 0.0)
        let sbRect = try #require(rt.element(byKey: "sv-sidebar-pane")).rect
        let gripRect = try #require(rt.element(byKey: "sv-sidebar-grip")).rect
        #expect(abs(sbRect[2] - 220.0) < 0.5)
        #expect(abs(gripRect[2] - SplitView<S>.gripWidth) < 0.5)

        // Drag grip to max clamp (360), min clamp (140), collapse (<70), drag back out to reopen, then double-click to reset (220)
        let gx = gripRect[0] + gripRect[2] * 0.5
        let gy = gripRect[1] + gripRect[3] * 0.5
        rt.pointerDown(at: Vec2(gx, gy), at: 0.05)
        rt.pointerMove(to: Vec2(gx + 60, gy), at: 0.06)
        rt.frame(at: 0.07)
        #expect(rt.state.sidebar.width == 280)

        rt.pointerMove(to: Vec2(gx + 400, gy), at: 0.072)
        rt.frame(at: 0.073)
        #expect(rt.state.sidebar.width == 360)

        rt.pointerMove(to: Vec2(gx - 100, gy), at: 0.075)
        rt.frame(at: 0.076)
        #expect(rt.state.sidebar.isOpen && rt.state.sidebar.width == 140)

        rt.pointerMove(to: Vec2(gx - 180, gy), at: 0.08)
        rt.frame(at: 0.085)
        #expect(rt.state.sidebar.isCollapsed)

        // Drag back out reopens sidebar before releasing
        rt.pointerMove(to: Vec2(gx - 20, gy), at: 0.088)
        rt.frame(at: 0.09)
        #expect(rt.state.sidebar.isOpen && rt.state.sidebar.width == 200)
        rt.pointerUp(at: Vec2(gx - 20, gy), at: 0.092)
        rt.frame(at: 0.094)

        // Double-click grip resets width back to 220
        let resetGrip = try #require(rt.element(byKey: "sv-sidebar-grip")).rect
        let rgx = resetGrip[0] + resetGrip[2] * 0.5
        let rgy = resetGrip[1] + resetGrip[3] * 0.5
        for i in 0..<2 {
            let tClick = 0.095 + Double(i) * 0.005
            rt.pointerDown(at: Vec2(rgx, rgy), at: tClick)
            rt.pointerUp(at: Vec2(rgx, rgy), at: tClick + 0.001)
            rt.frame(at: tClick + 0.002)
        }
        #expect(rt.state.sidebar.width == 220)

        // Collapse below threshold for peek check
        let g2 = try #require(rt.element(byKey: "sv-sidebar-grip")).rect
        let g2x = g2[0] + g2[2] * 0.5
        let g2y = g2[1] + g2[3] * 0.5
        rt.pointerDown(at: Vec2(g2x, g2y), at: 0.105)
        rt.pointerMove(to: Vec2(g2x - 180, g2y), at: 0.107)
        rt.pointerUp(at: Vec2(g2x - 180, g2y), at: 0.108)
        rt.frame(at: 0.11)
        #expect(rt.state.sidebar.isCollapsed)
        #expect(rt.element(byKey: "sv-sidebar-toggle") != nil)

        // Edge hover peeks sidebar over workspace, then toggle re-opens
        let edgeRect = try #require(rt.element(byKey: "sv-peek-edge")).rect
        rt.pointerMove(to: Vec2(edgeRect[0] + 4, edgeRect[1] + 50), at: 0.12)
        rt.frame(at: 0.18)
        #expect(rt.state.sidebar.isPeeking)
        #expect(rt.element(byKey: "sv-sidebar-peek") != nil)

        // Move into peek drawer then off it past grace to close peek, then toggle re-opens sidebar
        rt.pointerMove(to: Vec2(40, 50), at: 0.19)
        rt.frame(at: 0.20)
        rt.pointerMove(to: Vec2(400, 200), at: 0.21)
        rt.frame(at: 0.37)
        #expect(!rt.state.sidebar.isPeeking)

        let togRect = try #require(rt.element(byKey: "sv-sidebar-toggle")).rect
        rt.pointerDown(at: Vec2(togRect[0] + togRect[2] * 0.5, togRect[1] + togRect[3] * 0.5), at: 0.15)
        rt.pointerUp(at: Vec2(togRect[0] + togRect[2] * 0.5, togRect[1] + togRect[3] * 0.5), at: 0.16)
        rt.frame(at: 0.17)
        #expect(rt.state.sidebar.isOpen)
    }

    // MARK: - TabStrip, TabDragState & TabAutoScroll (`shell/tab_strip.rs`, `drag.rs`, `auto_scroll.rs`)

    @Test("TabOverflow, TabDragState slop/tearOut/widthLock/shift & TabAutoScroll match upstream")
    func tabDragStateAndOverflowUnit() {
        #expect(TabDensity.default(for: .horizontal) == .full)
        #expect(TabDensity.default(for: .vertical) == .compact)
        #expect(TabOverflow.densityFor(44) == .iconOnly)
        #expect(TabOverflow.densityFor(64) == .compact)
        #expect(TabOverflow.densityFor(65) == .full)

        let shrinkW = TabOverflow.horizontalDefault.tabWidth(available: 500, unpinnedCount: 2, pinnedCount: 1)
        #expect(shrinkW == 224) // (500 - 36 - 4)/2 = 230 clamped to maxWidth 224

        let scrollFloorW = TabOverflow.horizontalDefault.tabWidth(available: 200, unpinnedCount: 8, pinnedCount: 0)
        #expect(scrollFloorW == 28) // (200 - 14)/8 = 23.25 clamped to minWidth 28

        var drag = TabDragState()
        drag.press(id: "t1", index: 0, at: Vec2(50, 20), tabWidth: 140)
        #expect(drag.widthLock == 140)

        // Sub-slop move produces .none
        let sub = drag.follow(to: Vec2(52, 20), tabSize: 140, count: 3)
        #expect(sub == .none && !drag.isDragging)

        // Crossing horizontal slot midpoint reorders 0 -> 1
        let move1 = drag.follow(
            to: Vec2(160, 20),
            orientation: .horizontal,
            tabCenters: [50, 150, 250],
            tabSize: 100,
            count: 3
        )
        #expect(move1 == .moved(TabReorder(from: 0, to: 1)))
        #expect(drag.shift(forIndex: 1, itemExtent: 100) == -100)

        // Perpendicular tear-out fires past threshold for unpinned tab, respects pinned guard
        var tearDrag = TabDragState()
        tearDrag.press(id: "pin", index: 0, at: Vec2(20, 15))
        let pinnedOut = tearDrag.follow(
            to: Vec2(20, 80),
            count: 3,
            tearOut: TearOutSpec(threshold: 36, allowPinned: false, stripBounds: MotionRect.fromXYWH(0, 0, 400, 34)),
            isPinned: true
        )
        #expect(!tearDrag.isTornOut && pinnedOut != .tornOut(TabTearOut(id: "pin", index: 0, windowPoint: Vec2(20, 80))))

        var freeDrag = TabDragState()
        freeDrag.press(id: "t2", index: 1, at: Vec2(150, 15))
        let torn = freeDrag.follow(
            to: Vec2(150, 90),
            count: 3,
            tearOut: TearOutSpec(threshold: 36, allowPinned: false, stripBounds: MotionRect.fromXYWH(0, 0, 400, 34)),
            isPinned: false
        )
        #expect(freeDrag.isTornOut)
        #expect(torn == .tornOut(TabTearOut(id: "t2", index: 1, windowPoint: Vec2(150, 90))))
        freeDrag.handOff()
        #expect(freeDrag.handedOff && !freeDrag.isTornOut && freeDrag.widthLock == nil)

        // Lone tab cannot tear out unless TearOutSpec.lone == true
        var loneBlocked = TabDragState()
        loneBlocked.press(id: "only", index: 0, at: Vec2(50, 15))
        _ = loneBlocked.follow(
            to: Vec2(50, 90),
            count: 1,
            tearOut: TearOutSpec(threshold: 36, allowPinned: false, lone: false, stripBounds: MotionRect.fromXYWH(0, 0, 400, 34)),
            isPinned: false
        )
        #expect(!loneBlocked.isTornOut)

        var loneAllowed = TabDragState()
        loneAllowed.press(id: "only", index: 0, at: Vec2(50, 15))
        _ = loneAllowed.follow(
            to: Vec2(50, 90),
            count: 1,
            tearOut: TearOutSpec(threshold: 36, allowPinned: false, lone: true, stripBounds: MotionRect.fromXYWH(0, 0, 400, 34)),
            isPinned: false
        )
        #expect(loneAllowed.isTornOut)

        // TabAutoScroll scrolls smoothly near edge zones and stays clamped
        let nextScroll = TabAutoScroll.step(pointerAlong: 295, viewportStart: 0, viewportEnd: 300, scrollOffset: 10, maxScroll: 200, dt: 0.05)
        #expect(nextScroll > 10 && nextScroll <= 200)
        let centerHold = TabAutoScroll.step(pointerAlong: 150, viewportStart: 0, viewportEnd: 300, scrollOffset: 50, maxScroll: 200, dt: 0.05)
        #expect(centerHold == 50)
    }

    @Test("A tab selects once on mouse down and a squeezed inactive tab has no close target")
    func tabSelectsWhenPressed() throws {
        struct S {
            var selected = "a"
            var calls: [String] = []
            var drag = TabDragState()
        }
        for orientation in [TabOrientation.horizontal, .vertical] {
            let kit = Kit.neutral(dark: false)
            let rt = Runtime(state: S(), viewport: Vec2(180, 160)) { s, _ in
                let items = ["a", "b", "c"].map { StripTabItem<S>(id: $0, title: $0) }
                return TabStrip<S>(key: "tabs", tabs: items, selected: s.selected)
                    .orientation(orientation)
                    .availableWidth(100)
                    .dragState(\.drag, current: s.drag)
                    .onSelect { state, id, _ in state.selected = id; state.calls.append(id) }
                    .onClose { state, id, _ in state.calls.append("close-" + id) }
                    .buildLayered(s, kit: kit)
            }
            _ = rt.frame(at: 0)
            if orientation == .horizontal {
                #expect(rt.element(byKey: "tabs-close-b") == nil)
                #expect(rt.element(byKey: "tabs-close-a") != nil)
            }
            let tab = try #require(rt.element(byKey: "tabs-tab-b")).rect
            let p = Vec2(tab[0] + 2, tab[1] + 2)
            rt.pointerMove(to: p, at: 0.06)
            _ = rt.frame(at: 0.06)
            rt.pointerDown(at: p, at: 0.1)
            #expect(rt.state.selected == "b")
            #expect(rt.state.calls == ["b"])
            _ = rt.frame(at: 0.12)
            let beforeRelease = rt.commitCount
            rt.pointerUp(at: p, at: 0.2)
            _ = rt.frame(at: 0.2)
            #expect(rt.state.calls == ["b"])
            #expect(rt.commitCount == beforeRelease, "\(orientation)")
        }
    }

    @Test("TabStrip enforces pinned partition, suppresses active separators, and handles select/close in Runtime")
    func tabStripRuntime() throws {
        struct TabModel {
            var id: String
            var title: String
            var pinned: Bool = false
        }
        struct S {
            var tabs = [
                TabModel(id: "p1", title: "Pin", pinned: true),
                TabModel(id: "a", title: "One"),
                TabModel(id: "b", title: "Two"),
                TabModel(id: "c", title: "Three"),
            ]
            var selected: String = "a"
            var drag = TabDragState()
            var closed: [String] = []
        }

        // Pinned guard prevents unpinned->pinned reorder and vice versa
        var arr = [TabModel(id: "p", title: "P", pinned: true), TabModel(id: "u1", title: "1"), TabModel(id: "u2", title: "2")]
        #expect(!TabStrip<S>.applyReorder(&arr, from: 1, to: 0, isPinned: \.pinned))
        #expect(TabStrip<S>.applyReorder(&arr, from: 1, to: 2, isPinned: \.pinned))
        #expect(arr.map(\.id) == ["p", "u2", "u1"])

        let kit = Kit.neutral(dark: false)
        let rt = Runtime(state: S(), viewport: Vec2(560, 80), systemDark: false) { s, _ in
            let items = s.tabs.map {
                StripTabItem<S>(id: $0.id, title: $0.title).pinned($0.pinned)
            }
            return col().sizeFull().child(
                TabStrip<S>(key: "ts", tabs: items, selected: s.selected)
                    .dragState(\.drag, current: s.drag)
                    .availableWidth(540)
                    .onSelect { st, id, _ in st.selected = id }
                    .onClose { st, id, _ in
                        st.closed.append(id)
                        st.tabs.removeAll { $0.id == id }
                    }
                    .buildLayered(s, kit: kit)
            )
        }

        rt.frame(at: 0.0)
        // Separator between selected tab 'a' (index 1) and 'b' (index 2) is suppressed, while sep after 'b' (index 2) renders
        #expect(rt.element(byKey: "ts-sep-0") == nil) // adjacent to selected 'a'
        #expect(rt.element(byKey: "ts-sep-1") == nil) // adjacent to selected 'a'
        #expect(rt.element(byKey: "ts-sep-2") != nil) // between 'b' and 'c'

        // Clicking tab 'c' selects it
        let tabC = try #require(rt.element(byKey: "ts-tab-c")).rect
        rt.pointerDown(at: Vec2(tabC[0] + 12, tabC[1] + 12), at: 0.05)
        rt.pointerUp(at: Vec2(tabC[0] + 12, tabC[1] + 12), at: 0.06)
        rt.frame(at: 0.07)
        #expect(rt.state.selected == "c")

        // Middle-clicking tab 'b' closes it
        let tabB = try #require(rt.element(byKey: "ts-tab-b")).rect
        // Moving pointer outside before middle release does NOT close tab 'a' (.onMiddlePress semantics)
        let tabA = try #require(rt.element(byKey: "ts-tab-a")).rect
        rt.pointerDown(at: Vec2(tabA[0] + 12, tabA[1] + 12), button: .middle, at: 0.08)
        rt.pointerMove(to: Vec2(460, 110), at: 0.085)
        rt.pointerUp(at: Vec2(460, 110), button: .middle, at: 0.09)
        rt.frame(at: 0.095)
        #expect(rt.state.closed.isEmpty)

        rt.pointerDown(at: Vec2(tabB[0] + 12, tabB[1] + 12), button: .middle, at: 0.10)
        rt.pointerUp(at: Vec2(tabB[0] + 12, tabB[1] + 12), button: .middle, at: 0.11)
        rt.frame(at: 0.12)
        #expect(rt.state.closed == ["b"])
        #expect(rt.state.tabs.map(\.id) == ["p1", "a", "c"])
    }

    @Test("WindowTitlebar and Toolbar expose windowDrag bare regions with Cx.titlebarInset")
    func windowTitlebarAndToolbarWindowDragRegions() {
        struct S { var tapped = 0 }
        let kit = Kit.neutral(dark: false)
        let rt = Runtime(state: S(), viewport: Vec2(640, 240), systemDark: false) { _, cx in
            let inset = cx.titlebarInset()
            return col().sizeFull()
                .child(
                    WindowTitlebar<S>.fromInsets(ChromeInsets(leading: inset, trailing: 12, top: 44), title: "Work")
                        .trailing(el().key("btn").size(28, 24).onClick { s, _ in s.tapped += 1 })
                        .build(kit)
                )
                .child(Toolbar<S>(title: "Session").build(kit))
        }
        rt.setTitlebarInset(74)
        rt.frame(at: 0.0)
        #expect(rt.isBareTitlebarDragRegion(at: Vec2(320, 20)))
        #expect(rt.isBareTitlebarDragRegion(at: Vec2(320, 68)))
        #expect(!rt.isBareTitlebarDragRegion(at: Vec2(605, 22)))
    }

    @Test("WindowTitlebar emits OS TitlebarAction on pointer down and double-click zoom")
    func windowTitlebarPlatformActions() throws {
        struct S {}
        let k = Kit.neutral(dark: false)
        let rt = Runtime(state: S(), viewport: Vec2(640, 240), systemDark: false) { _, _ in
            WindowTitlebar<S>(key: "tb", title: "Docs")
                .leading(k.button(key: "tb-btn", "Home") { _, _ in })
                .build(k)
        }
        rt.frame(at: 0.0)
        rt.pointerDown(at: Vec2(320, 14), at: 0.05)
        #expect(rt.takeTitlebarAction() == .drag)
        rt.pointerUp(at: Vec2(320, 14), at: 0.06)
        rt.pointerDown(at: Vec2(320, 14), at: 0.15)
        #expect(rt.takeTitlebarAction() == .doubleClick)
        rt.pointerUp(at: Vec2(320, 14), at: 0.16)

        // Pressing interactive child does not trigger bare titlebar drag
        let btnRect = try #require(rt.element(byKey: "tb-btn")).rect
        rt.pointerDown(at: Vec2(btnRect[0] + btnRect[2] * 0.5, btnRect[1] + btnRect[3] * 0.5), at: 0.25)
        #expect(rt.takeTitlebarAction() == nil)
        rt.pointerUp(at: Vec2(btnRect[0] + btnRect[2] * 0.5, btnRect[1] + btnRect[3] * 0.5), at: 0.26)
    }

    @Test("WindowTitlebar.direction(.rtl) mirrors bands while preserving physical chrome insets")
    func windowTitlebarDirectionRtlMirrorsBandsWhileKeepingChromeInsets() throws {
        struct S {}
        let kit = Kit.neutral(dark: true)
        let insets = ChromeInsets(leading: 76, trailing: 18, top: 44)
        let rt = Runtime(state: S(), viewport: Vec2(640, 80), systemDark: true) { _, _ in
            col().dir(.rtl).wFull().child(
                WindowTitlebar<S>.fromInsets(insets, key: "rtl-tb", title: "Workspace")
                    .direction(.rtl)
                    .leading(text("L").key("lead-lbl"))
                    .trailing(text("R").key("trail-lbl"))
                    .build(kit)
            )
        }
        rt.frame(at: 0.0)
        let lead = try #require(rt.element(byKey: "lead-lbl")?.rect)
        let trail = try #require(rt.element(byKey: "trail-lbl")?.rect)
        // Under RTL, leading sits on the right clearing trailing chrome inset (18) + leadingPadding (14) = 32,
        // and trailing sits on the left clearing leading chrome inset (76) + trailingPadding (12) = 88.
        #expect(lead[0] > trail[0])
        #expect(640.0 - (lead[0] + lead[2]) >= 31.0)
        #expect(trail[0] >= 87.0)
    }

    @Test("TabStrip exposes Tab role group, single Tab stop re-entry, and ArrowLeft/Right focus roving")
    func tabStripFocusGroup() throws {
        struct S { var selected = "b" }
        let kit = Kit.neutral(dark: false)
        let rt = Runtime(state: S(), viewport: Vec2(480, 120), systemDark: false) { s, _ in
            col().gap(8).children([
                TabStrip<S>(
                    key: "fg-strip",
                    tabs: [
                        StripTabItem(id: "a", title: "One"),
                        StripTabItem(id: "b", title: "Two"),
                        StripTabItem(id: "c", title: "Three"),
                    ],
                    selected: s.selected
                )
                .label("Workspace tabs")
                .onSelect { st, id, _ in st.selected = id }
                .build(s, kit: kit),
                kit.button(key: "after-tabs", "After") { _, _ in },
            ])
        }
        rt.frame(at: 0.0)
        rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        rt.frame(at: 0.02)
        #expect(rt.focusedKey == "fg-strip-tab-b")
        rt.keyDown(KeyEvent(key: .arrowRight), at: 0.03)
        rt.frame(at: 0.04)
        #expect(rt.focusedKey == "fg-strip-tab-c")
        rt.keyDown(KeyEvent(key: .arrowLeft), at: 0.05)
        rt.frame(at: 0.06)
        #expect(rt.focusedKey == "fg-strip-tab-b")
        rt.keyDown(KeyEvent(key: .tab), at: 0.07)
        rt.frame(at: 0.08)
        #expect(rt.focusedKey == "after-tabs")
        let trackEl = try #require(rt.element(byKey: "fg-strip-list"))
        #expect(trackEl.role == .tabList)
        #expect(trackEl.label == "Workspace tabs")
    }

    // MARK: - Additional `src/shell/pane.rs`, `reorder.rs`, `tab_strip/tests.rs`, `tests/shell.rs`, `tests/shell_desktop.rs` parity

    @Test("PaneState unit parity: range bounds, tailFade curve, width-scaled spring, collapse threshold, NaN guard")
    func paneStateUnitParity() {
        // `a_peek_docks_where_it_floats_and_ends_when_closed`
        var peekPane = PaneState(width: 276).collapsed()
        peekPane.peek()
        #expect(peekPane.isPeeking && peekPane.peekPhase == .shown)
        peekPane.endPeek()
        #expect(!peekPane.isPeeking && peekPane.peekPhase == .left)
        peekPane.peek()
        peekPane.toggle()
        #expect(peekPane.isOpen && !peekPane.isPeeking && peekPane.fromPeek)
        peekPane.peek()
        #expect(peekPane.fromPeek)
        peekPane.toggle()
        #expect(!peekPane.fromPeek)
        peekPane.toggle()
        #expect(!peekPane.fromPeek)

        // `the_default_follows_the_range_from_the_width_it_was_made_with`
        let pDefault = PaneState(width: 640.4).withWidth(500.0)
        #expect(pDefault.width == 480.0 && pDefault.defaultWidth == 480.0)
        let pWider = pDefault.range(360.0, 960.0)
        #expect(pWider.width == 500.0 && pWider.defaultWidth == 640.0)
        var pNonAccum = pWider.range(100.0, 200.0).range(360.0, 960.0)
        #expect(pNonAccum.width == 500.0 && pNonAccum.defaultWidth == 640.0)
        pNonAccum.setWidth(400.0)
        pNonAccum.resetWidth()
        #expect(pNonAccum.width == 640.0)

        // `a_wider_range_keeps_the_width_new_was_given`
        let pw = PaneState(width: 640.0).range(360.0, 960.0)
        #expect(pw.width == 640.0 && pw.defaultWidth == 640.0)
        var pw2 = pw.withWidth(700.0)
        #expect(pw2.width == 700.0 && pw2.defaultWidth == 640.0)
        pw2.resetWidth()
        #expect(pw2.width == 640.0)
        let pwClamp = PaneState(width: 900.0).range(360.0, 600.0)
        #expect(pwClamp.width == 600.0 && pwClamp.defaultWidth == 600.0)
        #expect(PaneState(width: 640.0).width == PaneState.defaultMax)

        // `the_tail_fade_follows_the_spring_across_the_last_fraction`
        let tailSpring = Spring(duration: 0.3, bounce: 0.0)
        let closeFade = PaneMotion().fadeTail(0.15).fade(spring: tailSpring, open: false, reducedMotion: false)
        // tailFade sets delay & non-empty uniform velocity; verify open fade is fast tween
        #expect(closeFade.delay > 0.0)
        let openFade = PaneMotion().fadeTail(0.15).fade(spring: tailSpring, open: true, reducedMotion: false)
        if case .tween(let dur, _) = openFade.curve {
            #expect(dur > 0.01 && dur < 0.06)
        } else {
            Issue.record("Expected open tailFade tween curve")
        }

        // `the_motion_scales_with_width_within_its_bounds`
        let k = Kit.neutral(dark: true)
        let motion = PaneMotion().spring(Spring(duration: 0.3, bounce: 0.0)).scaleWithWidth(reference: 480.0, min: 0.15, max: 0.3)
        let expected276: Float = 0.3 * sqrt(276.0 / 480.0)
        #expect(abs(motion.spring(forWidth: 276.0, kit: k).duration - expected276) < 1e-4)
        #expect(motion.spring(forWidth: 1000.0, kit: k).duration == 0.3)
        #expect(motion.spring(forWidth: 50.0, kit: k).duration == 0.15)
        #expect(PaneMotion().spring(forWidth: 50.0, kit: k) == k.motion.disclosure)

        // `widths_clamp_round_and_collapse_past_half_the_minimum`
        var pc = PaneState(width: 276.0).range(136.0, 640.0)
        pc.setWidth(1000.0)
        #expect(pc.width == 640.0)
        pc.setWidth(100.4)
        #expect(pc.width == 136.0)
        pc.setWidth(300.6)
        #expect(pc.width == 301.0)
        setWidthCheck: do {
            pc.dragTo(80.0 - pc.width, collapseThreshold: pc.minWidth * 0.5)
            #expect(pc.isOpen && pc.width == 136.0)
            pc.dragTo(60.0 - pc.width, collapseThreshold: pc.minWidth * 0.5)
            #expect(!pc.isOpen && pc.width == 136.0 && pc.shownWidth == 0.0)
            pc.dragTo(200.0, collapseThreshold: pc.minWidth * 0.5)
            #expect(pc.isOpen && pc.width == 200.0)
        }
        pc.resetWidth()
        #expect(pc.width == 276.0)
        #expect(PaneState(width: 20.0).width == PaneState.defaultMin)
        pc.setWidth(.nan)
        #expect(pc.width == 276.0)
    }

    @Test("Reorder unit parity: slot stepping forward/back, press after lost release, unheard moves")
    func reorderUnitParity() {
        // `rows_between_the_place_and_the_target_step_aside`
        var r = Reorder<Int>().gap(4.0)
        r.press(id: 1, index: 1, at: Vec2(0, 0))
        _ = r.drag(to: Vec2(0, 3.0), rowHeight: 45.0, count: 5)
        #expect(r.dragging() == nil)
        _ = r.drag(to: Vec2(0, 100.0), rowHeight: 45.0, count: 5)
        #expect(r.dragging() == 1 && r.target() == 3)
        let shifts = (0..<5).map { r.shift(forIndex: $0) }
        #expect(shifts == [0.0, 100.0, -49.0, -49.0, 0.0])
        _ = r.drag(to: Vec2(0, -500.0), rowHeight: 45.0, count: 5)
        #expect(r.target() == 0)
        #expect(r.shift(forIndex: 0) == 49.0)
        let moved = r.end(cancelled: false)
        #expect(moved?.from == 1 && moved?.to == 0)
        #expect(r.shift(forIndex: 0) == 0.0)
        r.press(id: 2, index: 2, at: Vec2(0, 0))
        _ = r.drag(to: Vec2(0, 60.0), rowHeight: 45.0, count: 5)
        #expect(r.end(cancelled: true) == nil)

        // `a_press_after_a_lost_release_drags_its_own_row`
        var r2 = Reorder<Int>()
        r2.press(id: 1, index: 1, at: Vec2(0, 0))
        _ = r2.drag(to: Vec2(0, 100.0), rowHeight: 45.0, count: 5)
        #expect(r2.dragging() == 1)
        r2.press(id: 3, index: 3, at: Vec2(0, 200.0))
        #expect(r2.dragging() == nil)
        _ = r2.drag(to: Vec2(0, 250.0), rowHeight: 45.0, count: 5)
        let m2 = r2.end(cancelled: false)
        #expect(m2?.from == 3 && m2?.to == 4)

        // `moves_the_drag_never_hears_put_the_row_back`
        var r3 = Reorder<Int>()
        r3.press(id: 1, index: 1, at: Vec2(0, 0))
        _ = r3.drag(to: Vec2(0, 100.0), rowHeight: 45.0, count: 5)
        let p0 = r3.pointerMoved(to: Vec2(0, 100.0))
        let p1 = r3.pointerMoved(to: Vec2(0, 110.0))
        let p2 = r3.pointerMoved(to: Vec2(0, 120.0))
        #expect(!p0)
        #expect(!p1)
        #expect(p2)
        #expect(r3.dragging() == nil && r3.shift(forIndex: 2) == 0.0 && r3.end(cancelled: false) == nil)
    }

    @Test("TabStrip tear-out respects lone spec in Runtime (`src/shell/tab_strip/tests.rs`)")
    func tabStripLoneAndMultiTearOutRuntime() throws {
        struct App {
            var count: Int
            var lone: Bool
            var drag = TabDragState()
            var tornCount = 0
        }
        let kit = Kit.neutral(dark: true)
        func runTear(_ tabs: Int, lone: Bool) throws -> Runtime<App> {
            let rt = Runtime(state: App(count: tabs, lone: lone), viewport: Vec2(600, 300), systemDark: true) { s, _ in
                let items = (0..<s.count).map { StripTabItem<App>(id: "tab\($0)", title: "Tab \($0)") }
                return col().size(600, 300).child(
                    TabStrip<App>(key: "strip", tabs: items, selected: "tab0")
                        .dragState(\.drag, current: s.drag)
                        .availableWidth(600)
                        .tearOut(TearOutSpec(lone: s.lone))
                        .onTearOut { st, _, _ in st.tornCount += 1 }
                        .build(s, kit: kit)
                )
            }
            rt.frame(at: 0.0)
            rt.frame(at: 1.0 / 60.0)
            guard let tab0 = rt.element(byKey: "strip-tab-tab0") else {
                Issue.record("Missing strip-tab-tab0")
                return rt
            }
            let r = tab0.rect
            let x = r[0] + r[2] * 0.5
            let y = r[1] + r[3] * 0.5
            rt.pointerMove(to: Vec2(x, y), at: 0.02)
            rt.pointerDown(at: Vec2(x, y), at: 0.03)
            for (i, dy) in [Float(10), 40, 80].enumerated() {
                rt.pointerMove(to: Vec2(x, y + dy), at: 0.04 + Double(i) * 0.016)
                rt.frame(at: 0.045 + Double(i) * 0.016)
            }
            return rt
        }

        // `a_lone_tab_tears_out_only_when_the_spec_lets_it`
        let rtLoneBlocked = try runTear(1, lone: false)
        #expect(!rtLoneBlocked.state.drag.isTornOut && rtLoneBlocked.state.tornCount == 0)
        let rtLoneAllowed = try runTear(1, lone: true)
        #expect(rtLoneAllowed.state.drag.isTornOut)

        // `a_tab_among_others_tears_out_either_way`
        for lone in [false, true] {
            #expect(try runTear(2, lone: lone).state.drag.isTornOut)
        }
    }

    @MainActor
    @Test("SidebarRow height/styles/subtitleColor, two-line label, selectOnly Tab skip, and SplitView cancelResize")
    func sidebarRowBuildersSelectOnlyAndResizeCancel() throws {
        struct S {
            var sidebar = PaneState(width: 240).range(180, 420)
            var field = TextEdit()
            var picked = 1
            var presses = 0
        }
        let kit = Kit.neutral(dark: true)

        // Builder order equivalence + custom styles + subtitleColor + accessible name
        struct Empty {}
        let styleTitle = TextStyle(size: 15, weight: 600).lh(22)
        let styleSub = TextStyle(size: 10, weight: 400).lh(12)
        let rtRows = Runtime(state: Empty(), viewport: Vec2(240, 300), systemDark: true) { _, _ in
            col().w(240)
                .child(SidebarRow<Empty>(key: "h1", title: "First").height(45).subtitle("Detail").build(kit))
                .child(SidebarRow<Empty>(key: "h2", title: "Second").subtitle("Detail").height(45).build(kit))
                .child(SidebarRow<Empty>(key: "plain", title: "Name").build(kit))
                .child(SidebarRow<Empty>(key: "two", title: "Name").subtitle("Detail").build(kit))
                .child(SidebarRow<Empty>(key: "styled", title: "Name").subtitle("Detail").titleStyle(styleTitle).subtitleStyle(styleSub).subtitleColor(kit.c.textMuted).build(kit))
        }
        rtRows.frame(at: 0.0)
        #expect(try #require(rtRows.element(byKey: "h1")).rect[3] == 45.0)
        #expect(try #require(rtRows.element(byKey: "h2")).rect[3] == 45.0)
        #expect(try #require(rtRows.element(byKey: "plain")).label == "Name")
        #expect(try #require(rtRows.element(byKey: "two")).label == "Name, Detail")
        let twoEl = try #require(rtRows.element(byKey: "two"))
        let twoLbl = try #require(rtRows.element(byKey: "two-label"))
        let twoSub = try #require(rtRows.element(byKey: "two-subtitle"))
        #expect(twoEl.rect[3] == 40.0)
        #expect(twoLbl.rect[1] + twoLbl.rect[3] <= twoSub.rect[1] + 0.01)
        #expect(twoSub.rect[1] + twoSub.rect[3] <= twoEl.rect[1] + twoEl.rect[3] + 0.01)
        #expect(try #require(rtRows.element(byKey: "styled-label")).rect[3] == 22.0)
        #expect(try #require(rtRows.element(byKey: "styled-subtitle")).rect[3] == 12.0)
        #expect(try #require(rtRows.element(byKey: "styled-subtitle")).textColor == kit.c.textMuted)

        // `select_only_rows_skip_tab_and_keep_an_outside_field_focused` + `cancelling_a_resize_restores_the_width_and_open_state_without_peeking`
        let rt = Runtime(state: S(), viewport: Vec2(800, 400), systemDark: true) { s, _ in
            SplitView<S>(key: "sv") { st in
                col().p(12).child(Rune.textInput(key: "field", \.field).size(160, 28))
            }
            .sidebar(\.sidebar, current: s.sidebar) { st in
                var sec = SidebarSection<S>(key: "sec", title: "Results")
                for i in 0..<3 {
                    sec = sec.child(
                        SidebarRow<S>(key: "sel-\(i)", title: "Row \(i)")
                            .selectOnly()
                            .selected(st.picked == i)
                            .onClick { inner, _ in inner.picked = i; inner.presses += 1 }
                            .build(kit)
                    )
                }
                return Sidebar<S>(key: "sb").section(sec.build(kit)).build(kit)
            }
            .sidebarPeek(.hover)
            .paneMotion(.instant)
            .build(s, kit: kit)
        }
        rt.frame(at: 0.0)
        for i in 0..<3 {
            #expect(try #require(rt.element(byKey: "sel-\(i)")).focusable == false)
        }
        #expect(try #require(rt.element(byKey: "sel-1")).itemSelected)
        #expect((try #require(rt.element(byKey: "sel-0"))).itemSelected == false)

        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        rt.frame(at: 0.02)
        #expect(rt.focusedKey == "field")

        let row2 = try #require(rt.element(byKey: "sel-2")).rect
        rt.pointerDown(at: Vec2(row2[0] + 20, row2[1] + row2[3] * 0.5), at: 0.05)
        rt.pointerUp(at: Vec2(row2[0] + 20, row2[1] + row2[3] * 0.5), at: 0.06)
        rt.frame(at: 0.07)
        #expect(rt.state.picked == 2 && rt.state.presses == 1)
        #expect(rt.focusedKey == "field")

        // Cancelling a resize via Escape restores width/open state without peeking.
        // (Window-blur drag cancellation requires Runtime.dispatchFocus(false) to cancel activeDrag in core El.)
        let grip = try #require(rt.element(byKey: "sv-sidebar-grip")).rect
        let gx = grip[0] + grip[2] * 0.5
        let gy = grip[1] + grip[3] * 0.5
        rt.pointerDown(at: Vec2(gx, gy), at: 0.2)
        rt.pointerMove(to: Vec2(12, gy), at: 0.22)
        rt.frame(at: 0.25)
        #expect(!rt.state.sidebar.isPeeking)
        _ = rt.keyDown(KeyEvent(key: .escape), at: 0.3)
        rt.frame(at: 0.31)
        #expect(rt.state.sidebar.width == 240.0)
        #expect(rt.state.sidebar.isOpen && !rt.state.sidebar.isResizing)
        #expect(!rt.state.sidebar.isPeeking)
    }

    @Test("Hiding sidebar keeps focus in toolbar search or main pane field (tests/shell.rs:352,369)")
    func hidingSidebarKeepsFocusInToolbarSearchAndMainField() throws {
        struct S {
            var sidebar = PaneState(width: 220).range(140, 360)
            var search = TextEdit()
            var mainEdit = TextEdit()
        }
        let kit = Kit.neutral(dark: false)
        let rt = Runtime(state: S(), viewport: Vec2(800, 400), systemDark: false) { s, _ in
            SplitView<S>(key: "sv") { _ in
                Page<S>()
                    .header(
                        Toolbar<S>(key: "tb")
                            .trailing(Rune.textInput(key: "toolbar-search", \.search).size(160, 28))
                            .build(kit)
                    )
                    .child(Rune.textInput(key: "main-field", \.mainEdit).size(200, 28))
                    .build(kit)
            }
            .sidebar(\.sidebar, current: s.sidebar) { _ in
                Sidebar<S>(key: "sb").section(SidebarSection<S>(title: "Nav").build(kit)).build(kit)
            }
            .paneMotion(.instant)
            .build(s, kit: kit)
        }

        rt.frame(at: 0.0)
        let searchRect = try #require(rt.element(byKey: "toolbar-search")).rect
        rt.pointerDown(at: Vec2(searchRect[0] + 12, searchRect[1] + searchRect[3] * 0.5), at: 0.02)
        rt.pointerUp(at: Vec2(searchRect[0] + 12, searchRect[1] + searchRect[3] * 0.5), at: 0.03)
        rt.frame(at: 0.04)
        #expect(rt.focusedKey == "toolbar-search")

        rt.update { st, _ in st.sidebar.toggle() }
        rt.frame(at: 0.06)
        #expect(!rt.state.sidebar.isOpen)
        #expect(rt.focusedKey == "toolbar-search")
        _ = rt.keyDown(KeyEvent(key: .text("search")), at: 0.07)
        rt.frame(at: 0.08)
        #expect(rt.state.search.text == "search")

        // Re-open sidebar, focus main-field, collapse sidebar, verify main-field keeps focus & spaces
        rt.update { st, _ in st.sidebar.toggle() }
        rt.frame(at: 0.11)
        #expect(rt.state.sidebar.isOpen)

        let mainRect = try #require(rt.element(byKey: "main-field")).rect
        rt.pointerDown(at: Vec2(mainRect[0] + 12, mainRect[1] + mainRect[3] * 0.5), at: 0.12)
        rt.pointerUp(at: Vec2(mainRect[0] + 12, mainRect[1] + mainRect[3] * 0.5), at: 0.13)
        rt.frame(at: 0.14)
        #expect(rt.focusedKey == "main-field")

        rt.update { st, _ in st.sidebar.toggle() }
        rt.frame(at: 0.16)
        #expect(!rt.state.sidebar.isOpen)
        #expect(rt.focusedKey == "main-field")
        _ = rt.keyDown(KeyEvent(key: .text("a")), at: 0.17)
        _ = rt.keyDown(KeyEvent(key: .space), at: 0.18)
        _ = rt.keyDown(KeyEvent(key: .text("b")), at: 0.19)
        rt.frame(at: 0.20)
        #expect(rt.state.mainEdit.text == "a b")
        #expect(!rt.state.sidebar.isOpen)
    }

    @Test("PaneState.dragTo(width:), StripTabItem avatar/editor/decorate, and full TabStrip builder/handler parity")
    func paneStateDragToWidthAndTabStripBuilderParity() throws {
        var pane = PaneState(width: 240).range(160, 400)
        pane.dragTo(width: 70) // below half minWidth (80) collapses
        #expect(!pane.isOpen)
        pane.dragTo(width: 280) // >= half minWidth opens and sets width
        #expect(pane.isOpen)
        #expect(pane.width == 280)

        struct App {
            var tabs: [String] = ["a", "b"]
            var selected: String = "a"
            var drag = TabDragState()
            var edit = TextEdit("Renamed")
            var editingId: String? = nil
            var doubled: [String] = []
            var hovered: [(String, Bool)] = []
            var tornMoves: [TabTearMove] = []
            var closed: [String] = []
        }

        let kit = Kit.neutral(dark: false)
        let customCloseSvg = SVGIcon(viewBox: 16, paths: ["M3 3l10 10"])

        let rt = Runtime(state: App(), viewport: Vec2(560, 120), systemDark: false) { s, _ in
            let items = s.tabs.enumerated().map { idx, id in
                var item = StripTabItem<App>(id: id, title: "Tab \(id.uppercased())")
                    .avatar(el().key("av-\(id)").size(10, 10).bg(kit.c.bgAccent))
                    .decorate { e, _ in e.description("decorated-\(id)") }
                if idx == 0 {
                    item = item.status(.spinner)
                }
                if s.editingId == id {
                    item = item.editor(textInput(key: "ed-\(id)", \.edit))
                }
                return item
            }
            return col().sizeFull().gap(8).children([
                TabStrip<App>(key: "bstrip", orientation: .horizontal)
                    .tabs(items)
                    .active(s.selected)
                    .dragState(\.drag, current: s.drag)
                    .tearOut(TearOutSpec(threshold: 24, lone: true))
                    .availableWidth(500)
                    .gap(8)
                    .selectOnDragStart(false)
                    .matchedPrefix("tab-flight")
                    .reorderSpring(MotionTokens.REFLOW)
                    .trailing(kit.iconButton(key: "new-tab", svg: KitIcons.plus, label: "New") { _, _ in })
                    .trailingWidth(32)
                    .fill(kit.c.bgBase)
                    .closeIcon(customCloseSvg)
                    .closeTabStop(true)
                    .busyIndicator { _ in el().key("custom-busy").size(8, 8) }
                    .onSelect { st, id, _ in st.selected = id }
                    .onClose { st, id, _ in st.closed.append(id) }
                    .onDoubleClick { st, id, _ in st.doubled.append(id) }
                    .onHover { st, id, inside, _ in st.hovered.append((id, inside)) }
                    .onTearMove { st, mv, _ in st.tornMoves.append(mv) }
                    .buildLayered(s, kit: kit),
                kit.button(key: "after-bstrip", "After") { _, _ in },
            ])
        }

        rt.frame(at: 0.0)
        // Verify avatar, custom busy indicator, decorate, custom fill, trailingWidth width math, closeTabStop
        #expect(rt.element(byKey: "av-a") != nil)
        #expect(rt.element(byKey: "custom-busy") != nil)
        #expect(rt.element(byKey: "bstrip-tab-a")?.a11yDescription == "decorated-a")
        let stripEl = try #require(rt.element(byKey: "bstrip"))
        #expect(stripEl.fill == kit.c.bgBase)
        let tabA = try #require(rt.element(byKey: "bstrip-tab-a")).rect
        let tabB = try #require(rt.element(byKey: "bstrip-tab-b")).rect
        // Two unpinned tabs share (500 - (32 + 8)) = 460 with 8pt gap -> clamped to maxWidth 224
        #expect(abs(tabB[0] - (tabA[0] + tabA[2] + 8.0)) < 1.5)
        #expect(abs(tabA[2] - 224.0) < 1.5)

        // closeTabStop(true) keeps close button as a focus stop inside the tab list focusGroup
        rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        rt.frame(at: 0.02)
        #expect(rt.focusedKey == "bstrip-tab-a")
        rt.keyDown(KeyEvent(key: .arrowRight), at: 0.03)
        rt.frame(at: 0.04)
        #expect(rt.focusedKey == "bstrip-close-a")
        rt.keyDown(KeyEvent(key: .tab), at: 0.042)
        rt.frame(at: 0.045)
        #expect(rt.focusedKey == "new-tab")

        // Hover and double click on tab b
        let bPt = Vec2(tabB[0] + 30, tabB[1] + 12)
        rt.pointerMove(to: bPt, at: 0.05)
        rt.frame(at: 0.06)
        #expect(rt.state.hovered.contains { $0.0 == "b" && $0.1 == true })

        rt.pointerDown(at: bPt, at: 0.07)
        rt.pointerUp(at: bPt, at: 0.08)
        rt.pointerDown(at: bPt, at: 0.12)
        rt.pointerUp(at: bPt, at: 0.13)
        rt.frame(at: 0.14)
        #expect(rt.state.doubled.contains("b"))

        // Drag vertically past threshold triggers onTearMove
        rt.pointerDown(at: bPt, at: 0.20)
        rt.pointerMove(to: Vec2(bPt.x, bPt.y + 40), at: 0.22)
        rt.pointerMove(to: Vec2(bPt.x, bPt.y + 48), at: 0.24)
        rt.pointerUp(at: Vec2(bPt.x, bPt.y + 48), at: 0.26)
        rt.frame(at: 0.27)
        #expect(!rt.state.tornMoves.isEmpty)

        // Editor mounts inline text input in tab title slot
        rt.update { st, _ in st.editingId = "b" }
        rt.frame(at: 0.30)
        #expect(rt.element(byKey: "bstrip-editor-b") != nil)
        #expect(rt.element(byKey: "ed-b") != nil)
        #expect(rt.element(byKey: "bstrip-close-b") == nil)
    }

    @Test("Toolbar material, SidebarHeader/Section count/toggle, Sidebar virtualRows, SidebarToggle spec, Page frame, and reduced-motion peek")
    func toolbarHeaderVirtualSidebarTogglePageAndReducedPeek() throws {
        struct S {
            var sidebar = PaneState(width: 240).range(160, 360)
            var headerCollapsed = true
            var actionClicks = 0
            var useVirtual = false
            var showPage = false
        }
        let kit = Kit.neutral(dark: false)
        let rt = Runtime(state: S(), viewport: Vec2(900, 500), systemDark: false) { s, _ in
            if s.showPage {
                return Page<S>(key: "pg", content: text("Settings body"))
                    .title("Settings")
                    .leading(kit.button(key: "pg-back", "Back") { _, _ in })
                    .trailing(kit.button(key: "pg-done", "Done") { _, _ in })
                    .titlebarInset(74)
                    .pastLights(16, edge: 18)
                    .frameInset(8)
                    .toolbarInPanel(true)
                    .build(kit)
            }
            let sbEl: El<S> = if s.useVirtual {
                Sidebar<S>(key: "vsb")
                    .label("History")
                    .inset(0)
                    .headerGap(4)
                    .headerPadding(top: 8, bottom: 16)
                    .rowGap(4)
                    .rowHeight(28)
                    .header(el().key("vsb-hdr").h(20))
                    .virtualRows(count: 200, key: { _, i in "vrow-\(i)" }) { _, i in
                        SidebarRow<S>(key: "vrow-\(i)", title: "Row \(i)").build(kit)
                    }
                    .build(kit)
            } else {
                Sidebar<S>(key: "sb")
                    .label("Workspace")
                    .inset(4)
                    .section(
                        SidebarSection<S>(key: "s1", title: "Pinned")
                            .count(3)
                            .action(kit.iconButton(key: "s1-add", svg: KitIcons.plus, label: "Add") { st, _ in st.actionClicks += 1 })
                            .child(SidebarRow<S>(key: "r0", title: "Item 0").build(kit))
                            .build(kit)
                    )
                    .child(
                        SidebarHeader<S>(key: "hdr", title: "Sessions")
                            .collapsed(s.headerCollapsed)
                            .count(5)
                            .action(kit.iconButton(key: "hdr-act", svg: KitIcons.plus, label: "New") { st, _ in st.actionClicks += 1 })
                            .onToggle { st, _ in st.headerCollapsed.toggle() }
                            .build(kit)
                    )
                    .build(kit)
            }
            return SplitView<S>(key: "sv") { _ in
                el().key("ws-body").sizeFull()
            }
            .sidebar(\.sidebar, current: s.sidebar) { _ in sbEl }
            .toolbar(Toolbar<S>(key: "tb", title: "Main").material(.underWindowBackground).build(kit))
            .titlebarInset(ChromeInsets(leading: 74, trailing: 0, top: 0))
            .frameInset(8)
            .toolbarInPanel(true)
            .sidebarPadding(12)
            .sidebarToggle(
                SidebarToggle<S>()
                    .size(.large)
                    .pastLights(16)
                    .edge(18)
                    .gap(4)
                    .inHeader(true)
                    .unread(true)
                    .shortcut("⌥⌘S")
            )
            .paneMotion(.instant)
            .sidebarPeek(SidebarPeek.hover.reducedMotionFade(0.15))
            .reducedMotion(true)
            .build(s, kit: kit)
        }

        rt.frame(at: 0.0)
        // Toolbar material & SidebarToggle in header
        let tb = try #require(rt.element(byKey: "tb"))
        #expect(tb.fill == kit.c.bgBase)
        #expect(rt.element(byKey: "sv-sidebar-toggle-slot") != nil)
        let openToggle = try #require(rt.element(byKey: "sv-sidebar-toggle"))
        #expect(abs(openToggle.rect[2] - 28.0) < 0.5)
        #expect(openToggle.help?.contains("⌥⌘S") == true)
        let unreadDot = try #require(rt.element(byKey: "sv-sidebar-toggle-unread"))
        #expect(unreadDot.opacity == 0.0)

        // SidebarSection count/action + SidebarHeader collapsed/count/action/onToggle
        #expect(rt.element(byKey: "s1-count") != nil)
        #expect(rt.element(byKey: "s1-add") != nil)
        let hdr = try #require(rt.element(byKey: "hdr"))
        #expect(hdr.role == .button)
        #expect(hdr.expanded == false)
        #expect(hdr.a11yDescription == "5 items")
        #expect(rt.element(byKey: "hdr-count") != nil)
        #expect(rt.element(byKey: "hdr-disclosure") != nil)
        let hdrPt = Vec2(hdr.rect[0] + 16, hdr.rect[1] + 12)
        rt.pointerDown(at: hdrPt, at: 0.02)
        rt.pointerUp(at: hdrPt, at: 0.03)
        rt.frame(at: 0.04)
        #expect(rt.state.headerCollapsed == false)

        // Collapsed toggle shows unread dot & peek works with pane-surface + Escape
        rt.update { st, _ in st.sidebar.setOpen(false) }
        rt.frame(at: 0.06)
        #expect(try #require(rt.element(byKey: "sv-sidebar-toggle-unread")).opacity > 0.5)

        let edgeRect = try #require(rt.element(byKey: "sv-peek-edge")).rect
        rt.pointerMove(to: Vec2(edgeRect[0] + 4, edgeRect[1] + 40), at: 0.08)
        rt.frame(at: 0.14)
        #expect(rt.state.sidebar.isPeeking)
        #expect(rt.element(byKey: "sv-pane-surface") != nil)
        let peekEl = try #require(rt.element(byKey: "sv-sidebar-peek"))
        #expect(peekEl.rect[0] == 8.0)

        rt.update { st, _ in st.sidebar.endPeek() }
        rt.frame(at: 0.11)
        #expect(!rt.state.sidebar.isPeeking)

        // Virtualized Sidebar mounts near viewport instead of all 200 rows
        rt.update { st, _ in
            st.sidebar.setOpen(true)
            st.useVirtual = true
        }
        rt.frame(at: 0.12)
        #expect(rt.element(byKey: "vrow-0") != nil)
        #expect(rt.element(byKey: "vrow-199") == nil)

        // Page shell chrome matches SplitView panel + toolbar height
        rt.update { st, _ in st.showPage = true }
        rt.frame(at: 0.14)
        #expect(try #require(rt.element(byKey: "pg-titlebar-strip")).rect[3] == 8.0)
        #expect(try #require(rt.element(byKey: "pg-main-pane")).rect[0] == 8.0)
        #expect(try #require(rt.element(byKey: "pg-toolbar")).rect[3] == 48.0)
    }

    @Test("SidebarPeek dwell delays, hold margin/grace, toggle dock, and window-blur cancel (shell_desktop.rs:200-296)")
    func sidebarPeekDwellAndBlur() throws {
        struct S {
            var sidebar = PaneState(width: 276).range(180, 420).collapsed()
            var picked = 0
        }
        let k = Kit.neutral(dark: false)
        let peekCfg = SidebarPeek()
            .edge(16, delay: 0.04)
            .toggleDelay(0.08)
            .hold(margin: 15, grace: 0.10)
        func makeRt() -> Runtime<S> {
            let rt = Runtime(state: S(), viewport: Vec2(1000, 600), systemDark: false) { s, _ in
                SplitView<S>(key: "sv") { _ in el().key("workspace").sizeFull() }
                    .frameInset(8)
                    .sidebar(\.sidebar, current: s.sidebar) { _ in
                        col().child(
                            k.button(key: "row2", "Row 2") { st, _ in st.picked = 2 }
                        )
                    }
                    .sidebarToggle(SidebarToggle<S>().edge(16))
                    .sidebarPeek(peekCfg)
                    .toolbar(Toolbar<S>(title: "Main").build(k))
                    .build(s, kit: k)
            }
            var now = 0.0
            rt.frame(at: now)
            for _ in 0..<60 { now += 1.0 / 60.0; rt.frame(at: now) }
            return rt
        }

        // 1. Edge dwell (40ms) -> peeks; titlebar band & quick pass don't peek; hold margin & 100ms grace
        let rt1 = makeRt()
        var t = 2.0
        rt1.pointerMove(to: Vec2(12, 40), at: t)
        t += 0.2; rt1.frame(at: t)
        #expect(!rt1.state.sidebar.isPeeking, "titlebar band does not peek")

        rt1.pointerMove(to: Vec2(12, 300), at: t)
        t += 0.02; rt1.frame(at: t)
        rt1.pointerMove(to: Vec2(400, 300), at: t)
        t += 0.2; rt1.frame(at: t)
        #expect(!rt1.state.sidebar.isPeeking, "quick pass shorter than 40ms does not peek")

        rt1.pointerMove(to: Vec2(12, 300), at: t)
        t += 0.03; rt1.frame(at: t)
        #expect(!rt1.state.sidebar.isPeeking, "not before 40ms")
        t += 0.02; rt1.frame(at: t)
        #expect(rt1.state.sidebar.isPeeking, "after resting 40ms")
        t += 0.5; rt1.frame(at: t)

        let rowRect = try #require(rt1.element(byKey: "row2")).rect
        let rx = rowRect[0] + rowRect[2] * 0.5
        let ry = rowRect[1] + rowRect[3] * 0.5
        rt1.pointerMove(to: Vec2(rx, ry), at: t)
        rt1.pointerDown(at: Vec2(rx, ry), at: t + 0.005)
        rt1.pointerUp(at: Vec2(rx, ry), at: t + 0.01)
        t += 0.02; rt1.frame(at: t)
        #expect(rt1.state.picked == 2)
        #expect(rt1.state.sidebar.isPeeking)

        rt1.pointerMove(to: Vec2(276 + 10, 300), at: t)
        t += 0.2; rt1.frame(at: t)
        #expect(rt1.state.sidebar.isPeeking, "kept within 15pt hold margin")

        rt1.pointerMove(to: Vec2(600, 300), at: t)
        t += 0.09; rt1.frame(at: t)
        #expect(rt1.state.sidebar.isPeeking, "kept within 100ms leave grace")
        t += 0.02; rt1.frame(at: t)
        #expect(!rt1.state.sidebar.isPeeking && !rt1.state.sidebar.isOpen)

        // 2. Toggle dwell (80ms) peeks & clicking docks
        let rt2 = makeRt()
        var t2 = 2.0
        let tog = try #require(rt2.element(byKey: "sv-sidebar-toggle")).rect
        let tx = tog[0] + tog[2] * 0.5
        let ty = tog[1] + tog[3] * 0.5
        rt2.pointerMove(to: Vec2(tx, ty), at: t2)
        t2 += 0.07; rt2.frame(at: t2)
        #expect(!rt2.state.sidebar.isPeeking, "not before 80ms")
        t2 += 0.02; rt2.frame(at: t2)
        #expect(rt2.state.sidebar.isPeeking, "after resting 80ms on toggle")

        // 3. Window blur cancels peek
        rt2.windowFocus(false, at: t2 + 0.01)
        rt2.frame(at: t2 + 0.02)
        #expect(!rt2.state.sidebar.isPeeking, "window losing focus ends peek")
    }

    @Test("Shell keyboard navigation, focus-out on collapse, rename preservation, and stuck-resize blur (`tests/shell.rs`)")
    func shellKeyboardCollapseRenameAndResizeBlurParity() throws {
        // 1. `a_wider_range_keeps_the_width_new_was_given`
        var wider = PaneState(width: 640).range(360, 960)
        #expect(wider.width == 640 && wider.defaultWidth == 640)
        wider = wider.withWidth(700)
        #expect(wider.width == 700 && wider.defaultWidth == 640)
        wider.resetWidth()
        #expect(wider.width == 640)
        let clamped = PaneState(width: 900).range(360, 600)
        #expect(clamped.width == 600 && clamped.defaultWidth == 600)
        #expect(PaneState(width: 640).width == PaneState.defaultMax)

        // 2. Multi-section sidebar single tab stop, collapse focus-out/rename blur, arrow preservation during rename, and stuck resize blur
        struct S {
            var sidebar = PaneState(width: 240).range(160, 420)
            var picked = 1
            var twoLines = false
            var renaming: Int? = nil
            var edit = TextEdit()
            var committed: String? = nil
        }
        let kit = Kit.neutral(dark: true)
        let names = ["Alpha", "Bravo", "Charlie", "Delta"]
        let rt = Runtime(
            state: S(),
            viewport: Vec2(800, 500),
            systemDark: true,
            onKey: { st, ev, _ in
                if isSidebarToggle(ev.key, mods: ev.mods) {
                    st.sidebar.toggle()
                    return true
                }
                return false
            }
        ) { s, _ in
            let rowEls: [El<S>] = names.enumerated().map { i, name in
                var r = SidebarRow<S>(key: "row\(i)", title: name)
                    .selected(s.picked == i)
                    .onClick { st, _ in st.picked = i }
                if s.twoLines {
                    r = r.subtitle("user\(i)@example.com")
                }
                if s.renaming == i {
                    r = r.renaming(
                        \S.edit,
                        onCommit: { st, text, _ in
                            st.committed = text
                            st.renaming = nil
                        },
                        onCancel: { st, _ in
                            st.renaming = nil
                        }
                    )
                }
                return r.build(kit)
            }
            let sb = Sidebar<S>(key: "sb")
                .section(SidebarSection<S>(key: "sec0", title: "Primary").children(Array(rowEls[0..<2])).build(kit))
                .section(SidebarSection<S>(key: "sec1", title: "Secondary").children(Array(rowEls[2..<4])).build(kit))
                .build(kit)
            return SplitView<S>(key: "sv") { _ in
                Page<S>().child(kit.button(key: "after-main", "Action") { _, _ in }).build(kit)
            }
            .sidebar(\.sidebar, current: s.sidebar) { _ in sb }
            .paneMotion(.instant)
            .build(s, kit: kit)
        }
        var t = 0.0
        func step() { t += 1.0 / 60.0; rt.frame(at: t) }
        func press(_ key: Key, mods: Mods = .none) {
            _ = rt.keyDown(KeyEvent(key: key, mods: mods), at: t + 0.005)
            step()
        }
        func focusedKey() -> String? { rt.elements().first(where: { $0.focused })?.key }
        func focusKey(_ key: String) {
            if let r = rt.element(byKey: key)?.rect {
                let pt = Vec2(r[0] + r[2] * 0.5, r[1] + r[3] * 0.5)
                rt.pointerDown(at: pt, at: t + 0.002)
                rt.pointerUp(at: pt, at: t + 0.004)
                step()
            }
        }

        rt.frame(at: t)
        press(.tab)
        #expect(focusedKey() == "row1")
        press(.arrowDown)
        #expect(focusedKey() == "row2" && rt.state.picked == 2)
        for _ in 0..<4 { press(.arrowDown) }
        #expect(rt.state.picked == 3)
        press(.home)
        #expect(rt.state.picked == 0)
        press(.text("c"))
        #expect(rt.state.picked == 2)
        // Upstream `tests/shell.rs:210` sets `rt.state.picked = 0` without a commit: a routed key
        // commits pending state first (`frame.rs` "Resolve the new tree before routing"), so an
        // `update` here would move the selection (and focus) before Return.
        rt.state.picked = 0
        press(.enter)
        #expect(rt.state.picked == 2)

        // Two-line rows keep keyboard nav and Return/Escape rename behavior
        rt.update { s, tx in tx.instant(); s.twoLines = true; s.picked = 1 }
        step()
        let r2 = try #require(rt.element(byKey: "row2"))
        #expect(r2.role == .listItem && r2.label == "Charlie, user2@example.com" && abs(r2.rect[3] - 40.0) < 0.5)

        // Rename keeps letters and arrows without type-selecting another row, then Escape returns focus to row1
        rt.update { s, _ in
            s.renaming = 1
            s.edit = TextEdit("Bravo")
            s.edit.selectAll()
        }
        step()
        focusKey("row1-rename")
        rt.update { s, _ in s.edit.selectAll() }
        step()
        #expect(focusedKey() == "row1-rename")
        for ch in ["D", "e", "l"] { press(.text(ch)) }
        for k in [Key.arrowDown, .arrowUp, .home, .end] { press(k) }
        #expect(rt.state.edit.text == "Del")
        #expect(rt.state.picked == 1 && focusedKey() == "row1-rename")
        press(.escape)
        #expect(rt.state.renaming == nil && rt.state.committed == nil)
        #expect(focusedKey() == "row1")

        // Return commits rename
        rt.update { s, _ in
            s.renaming = 1
            s.edit = TextEdit("Bravo")
        }
        step()
        focusKey("row1-rename")
        rt.update { s, _ in s.edit.selectAll() }
        step()
        press(.text("Beta"))
        press(.enter)
        #expect(rt.state.renaming == nil && rt.state.committed == "Beta")

        // Collapsing sidebar moves focus to sidebar-toggle and blurs active rename field
        rt.update { s, _ in
            s.renaming = 1
            s.edit = TextEdit("Bravo")
        }
        step()
        focusKey("row1-rename")
        #expect(focusedKey() == "row1-rename")
        _ = rt.keyDown(KeyEvent(key: .text("b"), mods: Mods(shift: true, cmd: true)), at: t + 0.005)
        step()
        #expect(!rt.state.sidebar.isOpen)
        #expect(focusedKey() == "sv-sidebar-toggle")
        press(.arrowDown)
        #expect(rt.state.picked == 1)
        press(.text("X"))
        #expect(rt.state.edit.text == "Bravo")

        // Stuck resize clears on window blur
        rt.update { s, _ in s.sidebar.setOpen(true) }
        step()
        let grip = try #require(rt.element(byKey: "sv-sidebar-grip")).rect
        let gx = grip[0] + grip[2] * 0.5
        let gy = grip[1] + grip[3] * 0.5
        rt.pointerMove(to: Vec2(gx, gy), at: t + 0.01)
        rt.pointerDown(at: Vec2(gx, gy), at: t + 0.02)
        rt.pointerMove(to: Vec2(gx - 180, gy), at: t + 0.03)
        step()
        #expect(!rt.state.sidebar.isOpen && rt.state.sidebar.isResizing)
        rt.windowFocus(false, at: t + 0.04)
        step()
        #expect(!rt.state.sidebar.isResizing)
    }

    @Test("Toolbar truncation & two-line rename preserve geometry (`tests/shell.rs:699,766`)")
    func toolbarTruncationAndTwoLineRenameGeometry() throws {
        struct T {}
        let k = Kit.neutral(dark: true)
        let tbRt = Runtime(state: T(), viewport: Vec2(400, 200), systemDark: true) { _, _ in
            let longEl: El<T> = text(String(repeating: "a", count: 400)).key("long").ellipsis().shrink().minW(0)
            let trailEl: El<T> = el().key("trail").size(24, 24)
            return Toolbar<T>(key: "tb")
                .leading(longEl)
                .trailing(trailEl)
                .build(k)
        }
        tbRt.frame(at: 0.0)
        let long = try #require(tbRt.element(byKey: "long")).rect
        let trail = try #require(tbRt.element(byKey: "trail")).rect
        #expect(trail[0] + trail[2] <= 400.5)
        #expect(long[0] + long[2] <= trail[0] + 0.5)

        struct Ren {
            var renaming = false
            var custom = false
            var edit = TextEdit()
        }
        for custom in [false, true] {
            let rt = Runtime(state: Ren(custom: custom), viewport: Vec2(240, 200), systemDark: true) { s, _ in
                var r = SidebarRow<Ren>(key: "r", title: "Name").subtitle("Detail")
                if s.custom {
                    r = r.titleStyle(TextStyle(size: 15, weight: 600, lineHeight: 22))
                }
                if s.renaming {
                    r = r.renaming(\Ren.edit, onCommit: { _, _, _ in }, onCancel: { _, _ in })
                }
                return col().w(240).child(r.build(Kit.neutral(dark: true)))
            }
            rt.frame(at: 0.0)
            let labelRect = try #require(rt.element(byKey: "r-label")).rect
            let subRect = try #require(rt.element(byKey: "r-subtitle")).rect
            var t = 0.0
            for text in ["Name", ""] {
                rt.update { s, _ in
                    s.renaming = true
                    s.edit = TextEdit(text)
                }
                t += 1.0 / 60.0
                rt.frame(at: t)
                let renRect = try #require(rt.element(byKey: "r-rename")).rect
                let subNow = try #require(rt.element(byKey: "r-subtitle")).rect
                #expect(abs(renRect[1] - labelRect[1]) < 0.5 && abs(renRect[3] - labelRect[3]) < 0.5)
                #expect(abs(subNow[1] - subRect[1]) < 0.5 && abs(subNow[3] - subRect[3]) < 0.5)
            }
        }
    }

    @Test("Desktop SplitView framing, lockstep fade/slide, hidden peek width, live row drag, and resize cancel (`tests/shell_desktop.rs`)")
    func desktopSplitViewFramingLockstepPeekWidthAndLiveRowDrag() throws {
        struct S {
            var sidebar = PaneState(width: 276).range(180, 480)
            var inspector = PaneState(width: 300).range(180, 480)
            var order = [0, 1, 2, 3, 4]
            var reorder = Reorder<Int>().gap(4)
            var picked = 0
        }
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(state: S(), viewport: Vec2(1000, 600), systemDark: true) { s, _ in
            let rowEls: [El<S>] = s.order.enumerated().map { idx, id in
                SidebarRow<S>(key: "row\(id)", title: "Item \(id)")
                    .subtitle("Sub \(id)")
                    .height(45)
                    .selected(s.picked == id)
                    .reorder(\S.reorder, id: id, index: idx, count: s.order.count) { st, from, to in
                        let moving = st.order.remove(at: from)
                        st.order.insert(moving, at: to)
                    }
                    .reorderState(s.reorder, id: id, index: idx)
                    .onClick { st, _ in st.picked = id }
                    .build(kit)
            }
            let sb = Sidebar<S>(key: "sb")
                .rowGap(4)
                .sections(rowEls)
                .build(kit)
            let motion = PaneMotion()
                .spring(Spring(duration: 0.3, bounce: 0.0))
                .scaleWithWidth(reference: 480, min: 0.15, max: 0.3)
                .fadeTail(0.15)
            return SplitView<S>(key: "sv") { _ in col().key("main-body").sizeFull() }
                .sidebar(\.sidebar, current: s.sidebar) { _ in sb }
                .inspector(\.inspector, current: s.inspector) { _ in col().key("insp-body").sizeFull() }
                .toolbar(Toolbar<S>(key: "tb", title: "App").build(kit))
                .frameInset(8)
                .toolbarInPanel()
                .sidebarPadding(10)
                .sidebarPeek(SidebarPeek())
                .paneMotion(motion)
                .build(s, kit: kit)
        }
        var t = 0.0
        func step(_ dt: Double = 1.0 / 60.0) { t += dt; rt.frame(at: t) }
        rt.frame(at: 0.0)
        step()

        // 1. Framed main panel (`8pt` inset) + toolbar inside panel + drag strip above
        let card = try #require(rt.element(byKey: "sv-panel")).rect
        let insp = try #require(rt.element(byKey: "sv-inspector-pane")).rect
        #expect(abs(card[0] - 276.0) < 0.5 && abs(card[1] - 8.0) < 0.5)
        #expect(abs(card[1] + card[3] - 592.0) < 0.5)
        #expect(abs(card[0] + card[2] - insp[0]) < 0.5)
        let tb = try #require(rt.element(byKey: "tb")).rect
        #expect(abs(tb[1] - 8.0) < 0.5 && abs(tb[3] - 48.0) < 0.5)
        rt.pointerDown(at: Vec2(500, 4), at: t + 0.005)
        #expect(rt.takeTitlebarAction() == .drag)
        rt.pointerUp(at: Vec2(500, 4), at: t + 0.01)

        // 2. Hidden peek surface takes width immediately while content springs
        rt.update { s, _ in s.sidebar.setWidth(400) }
        step(1.0 / 120.0)
        step(1.0 / 120.0)
        let contentW = try #require(rt.element(byKey: "sv-pane-content")).rect[2]
        #expect(contentW < 399.0)
        let surface = try #require(rt.element(byKey: "sv-pane-surface"))
        #expect(surface.opacity == 0.0)
        #expect(abs(surface.rect[2] - 400.0) < 0.5)
        rt.update { s, _ in s.sidebar.setWidth(276) }
        for _ in 0..<60 { step(1.0 / 60.0) }

        // 3. Sidebar + main + inspector share width-scaled spring & late fade, with pane-content pinned to edge
        rt.update { s, _ in
            s.sidebar.setOpen(false)
            s.inspector.setOpen(false)
        }
        var frames = 0
        var fadedEarly = false
        while frames <= 120 {
            step(1.0 / 120.0)
            frames += 1
            let sidePane = try #require(rt.element(byKey: "sv-sidebar-pane")).rect
            let mainPane = try #require(rt.element(byKey: "sv-main")).rect
            let paneContent = try #require(rt.element(byKey: "sv-pane-content"))
            let contentRight = paneContent.rect[0] + paneContent.rect[2]
            let sideRight = sidePane[0] + sidePane[2]
            #expect(abs(sidePane[2] - mainPane[0]) < 0.05)
            #expect(abs(contentRight - sideRight) < 0.5)
            let sideRatio = sidePane[2] / 276.0
            let inspRatio = try #require(rt.element(byKey: "sv-inspector-pane")).rect[2] / 300.0
            #expect(abs(sideRatio - inspRatio) < 0.02)
            let expectedOp = min(sideRatio / 0.15, 1.0)
            #expect(abs(paneContent.opacity - expectedOp) < 0.08)
            if sideRatio > 0.3 && paneContent.opacity < 0.99 { fadedEarly = true }
            if sideRatio < 0.001 { break }
        }
        #expect(!fadedEarly && frames < 60)

        // Instant open & collapse with both panes closed gives 8..992 framed width
        rt.update { s, tx in
            tx.instant()
            s.sidebar.setOpen(false)
            s.inspector.setOpen(false)
        }
        step()
        let closedPanel = try #require(rt.element(byKey: "sv-panel")).rect
        let closedRight = closedPanel[0] + closedPanel[2]
        #expect(abs(closedPanel[0] - 8.0) < 0.5 && abs(closedPanel[1] - 8.0) < 0.5 && abs(closedRight - 992.0) < 0.5)

        // Reopen both cleanly and test resize cancel (both Escape and window blur) without peeking
        rt.update { s, tx in
            tx.instant()
            s.sidebar.setOpen(true)
            s.inspector.setOpen(true)
        }
        for _ in 0..<5 { step() }
        for blur in [false, true] {
            let grip = try #require(rt.element(byKey: "sv-sidebar-grip")).rect
            let gx = grip[0] + grip[2] * 0.5
            let gy = grip[1] + grip[3] * 0.5
            rt.pointerDown(at: Vec2(gx, gy), at: t + 0.005)
            rt.pointerMove(to: Vec2(12, gy), at: t + 0.01)
            step(0.1)
            #expect(!rt.state.sidebar.isPeeking)
            if blur {
                rt.windowFocus(false, at: t + 0.01)
            } else {
                _ = rt.keyDown(KeyEvent(key: .escape), at: t + 0.01)
            }
            step()
            #expect(rt.state.sidebar.width == 276.0)
            #expect(rt.state.sidebar.isOpen && !rt.state.sidebar.isResizing)
            if blur {
                rt.windowFocus(true, at: t + 0.02)
                step()
            }
        }

        // 4. Live row drag: reflows other rows smoothly and Escape cancels back in place, drop commits [1, 2, 0, 3, 4]
        for _ in 0..<60 { step() }
        let r0 = try #require(rt.element(byKey: "row0")).rect
        let r1 = try #require(rt.element(byKey: "row1")).rect
        let r2 = try #require(rt.element(byKey: "row2")).rect
        let pitch = r1[1] - r0[1]
        #expect(abs(pitch - 49.0) < 0.5)
        let rx = r0[0] + r0[2] * 0.5
        let ry = r0[1] + r0[3] * 0.5
        rt.pointerMove(to: Vec2(rx, ry), at: t + 0.005)
        rt.pointerDown(at: Vec2(rx, ry), at: t + 0.01)
        rt.pointerMove(to: Vec2(rx, ry + 2 * pitch + 4), at: t + 0.02)
        step()
        #expect(rt.state.reorder.target() == 2)
        let r0LiveY = try #require(rt.element(byKey: "row0")).rect[1]
        let expectedLiveY = r0[1] + 2 * pitch + 4
        #expect(abs(r0LiveY - expectedLiveY) < 0.5)
        step()
        let mid1 = try #require(rt.element(byKey: "row1")).rect[1]
        #expect(mid1 < r1[1] && mid1 > r0[1])
        for _ in 0..<60 { step() }
        let settledR1 = try #require(rt.element(byKey: "row1")).rect[1]
        #expect(abs(settledR1 - r0[1]) < 0.5)
        _ = rt.keyDown(KeyEvent(key: .escape), at: t + 0.005)
        step()
        #expect(rt.state.reorder.dragging() == nil && rt.state.order == [0, 1, 2, 3, 4])
        for _ in 0..<60 { step() }
        let restoredR0 = try #require(rt.element(byKey: "row0")).rect[1]
        #expect(abs(restoredR0 - r0[1]) < 0.5)
        rt.pointerUp(at: Vec2(rx, ry), at: t + 0.005)

        rt.pointerMove(to: Vec2(rx, ry), at: t + 0.01)
        rt.pointerDown(at: Vec2(rx, ry), at: t + 0.015)
        rt.pointerMove(to: Vec2(rx, ry + 2 * pitch), at: t + 0.02)
        step()
        rt.pointerUp(at: Vec2(rx, ry + 2 * pitch), at: t + 0.025)
        step()
        #expect(rt.state.order == [1, 2, 0, 3, 4])
        for _ in 0..<60 { step() }
        let droppedR0 = try #require(rt.element(byKey: "row0")).rect[1]
        #expect(abs(droppedR0 - r2[1]) < 0.5)
        #expect(rt.state.picked == 0)
    }

    @Test("Page matches SplitView toolbar and frame pixel for pixel (`tests/shell.rs:578`)")
    func pageMatchesSplitViewToolbarAndFramePixelForPixel() throws {
        struct P {
            var page = false
            var sidebar = PaneState(width: 240).collapsed()
            var backs = 0
        }
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(state: P(), viewport: Vec2(960, 600), pixelScale: 2.0, systemDark: true) { s, cx -> El<P> in
            let lead: El<P> = el().key("lead").size(24, 24).role(.button).focusable(true).onClick { st, _ in st.backs += 1 }
            let trail: El<P> = el().key("trail").size(24, 24).role(.button).focusable(true)
            let body: El<P> = col().key("content").sizeFull()
            if s.page {
                return Page<P>(key: "pg", content: body)
                    .title("Settings")
                    .leading(lead)
                    .trailing(trail)
                    .titlebarInset(cx.chromeInsets().leading)
                    .frameInset(8)
                    .toolbarInPanel(true)
                    .build(kit)
            } else {
                return SplitView<P>(key: "sv") { _ in body }
                    .sidebar(\.sidebar, current: s.sidebar) { _ in col() }
                    .hideSidebarToggle()
                    .toolbar(Toolbar<P>(key: "tb", title: "Settings").leading(lead).trailing(trail))
                    .titlebarInset(cx.chromeInsets())
                    .frameInset(8)
                    .toolbarInPanel(true)
                    .build(s, kit: kit)
            }
        }
        rt.setTitlebarInset(78)
        rt.frame(at: 0.0)

        func rectIn(_ key: String) throws -> [Float] {
            try #require(rt.elements().first { !$0.exiting && $0.key == key }).rect
        }
        let splitLead = try rectIn("lead")
        let splitTrail = try rectIn("trail")
        let splitToolbar = try rectIn("tb")
        let splitPane = try rectIn("sv-panel")

        rt.update { st, _ in st.page = true }
        rt.frame(at: 1.0 / 60.0)
        #expect(try rectIn("pg-toolbar") == splitToolbar)
        #expect(try rectIn("lead") == splitLead)
        #expect(try rectIn("trail") == splitTrail)
        #expect(try rectIn("pg-main-pane") == splitPane)

        let titleEl = try #require(rt.elements().first { $0.text == "Settings" }).rect
        let tx = titleEl[0] + titleEl[2] * 0.5
        let ty = titleEl[1] + titleEl[3] * 0.5
        rt.pointerDown(at: Vec2(tx, ty), at: 0.1)
        #expect(rt.takeTitlebarAction() == .drag)
        rt.pointerUp(at: Vec2(tx, ty), at: 0.11)

        let lr = try rectIn("lead")
        let lx = lr[0] + lr[2] * 0.5
        let ly = lr[1] + lr[3] * 0.5
        rt.pointerDown(at: Vec2(lx, ly), at: 0.12)
        #expect(rt.takeTitlebarAction() == nil)
        rt.pointerUp(at: Vec2(lx, ly), at: 0.13)
        rt.frame(at: 0.14)
        #expect(rt.state.backs == 1)
    }

    @Test("Dragged reorder row whose release is lost lets go and next press drags its own row (`tests/reorder.rs:63`)")
    func aRowWhoseReleaseIsLostLetsGoAndNextPressDragsItsOwnRow() throws {
        struct R {
            var ids = [0, 1, 2, 3, 4]
            var reorder = Reorder<Int>()
            var dropped: [(Int, Int)] = []
        }
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(state: R(), viewport: Vec2(200, 200), systemDark: true) { s, _ -> El<R> in
            col().w(200).children(
                s.ids.enumerated().map { idx, id in
                    SidebarRow<R>(key: "row-\(id)", title: "Row \(id)")
                        .height(30)
                        .reorder(\R.reorder, id: id, index: idx, count: s.ids.count) { st, from, to in
                            st.dropped.append((from, to))
                        }
                        .reorderState(s.reorder, id: id, index: idx)
                        .build(kit)
                }
            )
        }
        var t = 0.0
        func step(_ dt: Double = 1.0 / 60.0) { t += dt; rt.frame(at: t) }
        rt.frame(at: 0.0)

        let r1 = try #require(rt.element(byKey: "row-1")).rect
        let x1 = r1[0] + r1[2] * 0.5
        let y1 = r1[1] + r1[3] * 0.5
        rt.pointerMove(to: Vec2(x1, y1), at: t + 0.005)
        rt.pointerDown(at: Vec2(x1, y1), at: t + 0.01)
        rt.pointerMove(to: Vec2(x1, y1 + 60), at: t + 0.015)
        step()
        #expect(rt.state.reorder.dragging() == 1)

        // Dragged row vanishes mid-drag so release never reaches it
        rt.update { st, _ in st.ids.removeAll { $0 == 1 } }
        step()
        rt.pointerUp(at: Vec2(x1, y1 + 60), at: t + 0.005)
        step()
        rt.pointerMove(to: Vec2(x1, 10), at: t + 0.005)
        rt.pointerMove(to: Vec2(x1, 20), at: t + 0.01)
        step()
        #expect(rt.state.reorder.dragging() == nil)

        // Row 3 (now index 2) drags down one place
        for _ in 0..<60 { step() }
        let r3 = try #require(rt.element(byKey: "row-3")).rect
        let x3 = r3[0] + r3[2] * 0.5
        let y3 = r3[1] + r3[3] * 0.5
        rt.pointerMove(to: Vec2(x3, y3), at: t + 0.005)
        rt.pointerDown(at: Vec2(x3, y3), at: t + 0.01)
        rt.pointerMove(to: Vec2(x3, y3 + 30), at: t + 0.015)
        rt.pointerUp(at: Vec2(x3, y3 + 30), at: t + 0.02)
        step()
        #expect(rt.state.dropped.count == 1 && rt.state.dropped[0] == (2, 3))
    }

    // MARK: - Phase 2 TabStrip Parity (`P2-17` #883, `P2-18` #922, `P2-19` #925)

    @Test("TabStrip draws titles with zero tracking and maps TabWords to close label & status descriptions (#883, #922)")
    func tabStripZeroTrackingAndWordsParity() throws {
        struct App {}
        var kit = Kit.neutral(dark: false)
        kit.ty.uiCompact.letterSpacing = -0.04

        func findEl(_ node: El<App>, key: String) -> El<App>? {
            if node.keyId == key { return node }
            for child in node.children {
                if let hit = findEl(child, key: key) { return hit }
            }
            return nil
        }

        let defaults = TabWords.default
        #expect(defaults.close == "Close tab")
        #expect(defaults.busy == "Working")
        #expect(defaults.attention == "Needs attention")
        #expect(defaults.unread == "Unread")
        #expect(defaults.failed == "Failed")

        let customWords = TabWords(
            close: "Schliessen",
            busy: "Arbeitet",
            attention: "Achtung",
            unread: "Ungelesen",
            failed: "Fehlgeschlagen"
        )
        let built = TabStrip<App>(
            key: "ts",
            tabs: [
                StripTabItem(id: "a", title: "Alpha").status(.spinner),
                StripTabItem(id: "b", title: "Beta").status(.dirty),
                StripTabItem(id: "c", title: "Gamma").status(.dot(kit.c.textAccent)),
                StripTabItem(id: "d", title: "Delta").status(.badge("ERR", tone: .danger)),
            ],
            selected: "a"
        )
        .words(customWords)
        .onClose { _, _, _ in }
        .build(App(), kit: kit)

        let titleA = try #require(findEl(built, key: "ts-title-a"))
        #expect(titleA.textStyle.letterSpacing == 0.0)
        #expect(titleA.textStyle.weight == kit.ty.uiMedium.weight)

        let closeA = try #require(findEl(built, key: "ts-close-a"))
        #expect(closeA.a11yLabel == "Schliessen")

        #expect(findEl(built, key: "ts-tab-a")?.a11yDescription == "Arbeitet")
        #expect(findEl(built, key: "ts-tab-b")?.a11yDescription == "Achtung")
        #expect(findEl(built, key: "ts-tab-c")?.a11yDescription == "Ungelesen")
        #expect(findEl(built, key: "ts-tab-d")?.a11yDescription == "Fehlgeschlagen")
    }

    @Test("TabStrip.hoverNone shows every closable non-icon-only tab's close button at rest beside status marks (#925)")
    func tabStripHoverNoneParity() throws {
        struct App {
            var hoverNone: Bool
            var density: TabDensity = .full
            var closed: [String] = []
        }
        let kit = Kit.neutral(dark: false)

        func makeRt(hoverNone: Bool, density: TabDensity = .full) -> Runtime<App> {
            let rt = Runtime(state: App(hoverNone: hoverNone, density: density), viewport: Vec2(560, 100), systemDark: false) { s, _ in
                TabStrip<App>(
                    key: "ht",
                    tabs: [
                        StripTabItem(id: "pin", title: "Pin").pinned(true),
                        StripTabItem(id: "plain", title: "Plain tab"),
                        StripTabItem(id: "busy", title: "Busy tab").status(.spinner),
                        StripTabItem(id: "fixed", title: "Locked").closable(false),
                    ],
                    selected: "plain"
                )
                .density(s.density)
                .availableWidth(540)
                .hoverNone(s.hoverNone)
                .onClose { st, id, _ in st.closed.append(id) }
                .build(s, kit: kit)
            }
            rt.frame(at: 0.0)
            rt.frame(at: 0.2)
            return rt
        }

        // Hover-capable strip: close button stays hidden at rest and appears when the tab is hovered.
        let desktop = makeRt(hoverNone: false)
        let desktopClose = try #require(desktop.element(byKey: "ht-close-plain"))
        #expect(desktopClose.opacity == 0.0)
        let plainRect = try #require(desktop.element(byKey: "ht-tab-plain")).rect
        desktop.pointerMove(to: Vec2(plainRect[0] + 20, plainRect[1] + 12), at: 0.25)
        desktop.frame(at: 0.3)
        desktop.frame(at: 0.6)
        #expect(try #require(desktop.element(byKey: "ht-close-plain")).opacity > 0.99)

        // Touch / hoverNone strip: every closable non-icon-only tab shows its close button at rest,
        // beside any status mark without overlap; pinned / non-closable / iconOnly tabs do not.
        let touch = makeRt(hoverNone: true)
        #expect(touch.element(byKey: "ht-close-pin") == nil)
        #expect(touch.element(byKey: "ht-close-fixed") == nil)
        let plainClose = try #require(touch.element(byKey: "ht-close-plain"))
        let busyClose = try #require(touch.element(byKey: "ht-close-busy"))
        let busySpin = try #require(touch.element(byKey: "ht-spin-busy"))
        let busyTitle = try #require(touch.element(byKey: "ht-title-busy"))
        #expect(plainClose.opacity == 1.0)
        #expect(busyClose.opacity == 1.0)
        #expect(busySpin.opacity == 1.0)
        #expect(busyTitle.rect[0] + busyTitle.rect[2] <= busySpin.rect[0] + 0.5)
        #expect(busySpin.rect[0] + busySpin.rect[2] <= busyClose.rect[0] + 0.5)

        let iconOnlyTouch = makeRt(hoverNone: true, density: .iconOnly)
        #expect(iconOnlyTouch.element(byKey: "ht-close-plain") == nil)
        #expect(iconOnlyTouch.element(byKey: "ht-title-plain") == nil)
    }
}
