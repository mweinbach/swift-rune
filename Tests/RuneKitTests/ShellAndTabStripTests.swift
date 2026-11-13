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

        // Rename submit commits updated title
        rt.state.renamingId = "a"
        rt.markNeedsCommit()
        rt.frame(at: 0.20)
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

        // Drag grip to resize, then collapse below 80pt
        let gx = gripRect[0] + gripRect[2] * 0.5
        let gy = gripRect[1] + gripRect[3] * 0.5
        rt.pointerDown(at: Vec2(gx, gy), at: 0.05)
        rt.pointerMove(to: Vec2(gx + 60, gy), at: 0.06)
        rt.frame(at: 0.07)
        #expect(rt.state.sidebar.width == 280)

        rt.pointerMove(to: Vec2(gx - 180, gy), at: 0.08)
        rt.pointerUp(at: Vec2(gx - 180, gy), at: 0.09)
        rt.frame(at: 0.10)
        #expect(rt.state.sidebar.isCollapsed)
        #expect(rt.element(byKey: "sv-sidebar-toggle") != nil)

        // Edge hover peeks sidebar over workspace, then toggle re-opens
        let edgeRect = try #require(rt.element(byKey: "sv-peek-edge")).rect
        rt.pointerMove(to: Vec2(edgeRect[0] + 4, edgeRect[1] + 50), at: 0.12)
        rt.frame(at: 0.13)
        #expect(rt.state.sidebar.isPeeking)
        #expect(rt.element(byKey: "sv-sidebar-peek") != nil)

        // Move into peek drawer then off it to close peek, then toggle re-opens sidebar
        rt.pointerMove(to: Vec2(40, 50), at: 0.135)
        rt.frame(at: 0.136)
        rt.pointerMove(to: Vec2(400, 200), at: 0.14)
        rt.frame(at: 0.145)
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

    @Test(
        "WindowTitlebar emits OS TitlebarAction on pointer down and double-click zoom",
        .disabled("Blocked on @el: Runtime.takeTitlebarAction() / TitlebarAction not in main yet")
    )
    func windowTitlebarPlatformActionsBlockedOnEl() {}

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
        let trackEl = try #require(rt.element(byKey: "fg-strip-track"))
        #expect(trackEl.role == .tabList)
        #expect(trackEl.label == "Workspace tabs")
    }
}
