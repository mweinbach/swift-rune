import Foundation
import Testing
@testable import RuneKit
@testable import Rune

@MainActor
@Suite("RuneKit Widget Accessibility Parity Tests (tests/a11y/{controls,overlays,data,shell}.rs)")
struct WidgetA11yParityTests {

    // MARK: - Helpers

    private func findEl<S>(_ root: El<S>, key: String) -> El<S>? {
        if root.keyId == key { return root }
        for child in root.children {
            if let found = findEl(child, key: key) {
                return found
            }
        }
        return nil
    }

    private func allEls<S>(_ root: El<S>, where predicate: (El<S>) -> Bool) -> [El<S>] {
        var out: [El<S>] = []
        func walk(_ node: El<S>) {
            if predicate(node) { out.append(node) }
            for child in node.children { walk(child) }
        }
        walk(root)
        return out
    }

    /// Mirrors upstream `tests/a11y/support.rs::no_echo`:
    /// no non-hidden text descendant under a labelled control echoes its ancestor's label.
    private func assertNoEcho<S>(_ node: El<S>, sourceLocation: SourceLocation = #_sourceLocation) {
        if node.isA11yHidden { return }
        let name = node.a11yLabel ?? ""
        func checkChildren(_ children: [El<S>]) {
            for c in children {
                if c.isA11yHidden { continue }
                if !name.isEmpty, c.role == .text {
                    let spoken = c.a11yLabel ?? c.plainText
                    #expect(
                        spoken != name,
                        "\(node.role) \(name) echoes its label in child \(c.keyId ?? "<unnamed>")",
                        sourceLocation: sourceLocation
                    )
                }
                assertNoEcho(c, sourceLocation: sourceLocation)
            }
        }
        checkChildren(node.children)
    }

    private func info(_ rt: Runtime<some Any>, _ key: String) -> ElementInfo? {
        rt.elements().first { !$0.exiting && $0.key == key }
    }

    private func testButton<S>(key: String, _ title: String, onClick: @escaping (inout S, inout Tx) -> Void) -> El<S> {
        row()
            .key(key)
            .role(.button)
            .label(title)
            .focusable()
            .onClick(onClick)
            .child(text(title).a11yHidden())
    }

    // MARK: - Controls (`tests/a11y/controls.rs`)

    @Test("ShortcutRecorder reads label, value, disabled state, hides internal caps, and announces recording")
    func shortcutRecorderA11y() {
        struct S {
            var recorder = ShortcutRecorderState()
        }
        let k = Kit.neutral(dark: false)
        var capturedRoot: El<S>?
        let rt = Runtime(state: S(), viewport: Vec2(500, 200), systemDark: false) { s, _ in
            let elTree: El<S> = col().child(
                ShortcutRecorder<S>(key: "show", \.recorder)
                    .label("Show window")
                    .build(using: k, in: s)
            ).child(
                ShortcutRecorder<S>(key: "plain", \.recorder)
                    .disabled(true)
                    .build(using: k, in: s)
            )
            capturedRoot = elTree
            return elTree
        }
        rt.frame(at: 0.0)

        let show = info(rt, "show")
        #expect(show?.role == .button)
        #expect(show?.label == "Show window")
        #expect(show?.a11yValue == "Record shortcut")
        #expect(show?.disabled == false)

        let plain = info(rt, "plain")
        #expect(plain?.role == .button)
        #expect(plain?.label == "Record shortcut")
        #expect(plain?.disabled == true)

        if let root = capturedRoot {
            assertNoEcho(root)
            if let showEl = findEl(root, key: "show") {
                #expect(showEl.children.allSatisfy { $0.isA11yHidden })
            }
        }

        // Entering recording updates a11yValue + a11yDescription
        rt.state.recorder.begin()
        rt.markNeedsCommit()
        rt.frame(at: 0.05)

        let recording = info(rt, "show")
        #expect(recording?.a11yValue == "Press shortcut")
        #expect(recording?.a11yDescription == "Press a shortcut, or Escape to cancel")
    }

    @Test("RollingText exposes role .text with whole label and hides per-glyph children")
    func rollingTextA11y() {
        let k = Kit.neutral(dark: false)
        let el: El<Int> = k.rollingText(key: "count", "12 files")
        #expect(el.role == .text)
        #expect(el.a11yLabel == "12 files")
        #expect(el.children.allSatisfy { $0.isA11yHidden })
        assertNoEcho(el)
    }

    // MARK: - Overlays (`tests/a11y/overlays.rs`)

    @Test("Dialog is modal, named, described, hides internal header/scrim, and closes on Escape")
    func dialogA11y() {
        struct S { var open = false }
        let k = Kit.neutral(dark: false)
        var capturedRoot: El<S>?
        let rt = Runtime(state: S(), viewport: Vec2(640, 480), systemDark: false) { s, _ in
            var layer: [El<S>] = []
            let behind: El<S> = testButton(key: "delete", "Delete") { st, _ in st.open = true }
            Dialog<S>("confirm", "Delete file?")
                .description("This can't be undone.")
                .open(s.open)
                .onClose { st in st.open = false }
                .fit()
                .child(testButton(key: "confirm-delete", "Delete") { st, _ in st.open = false })
                .build(kit: k, layer: &layer)
            let rootEl: El<S> = el().wFull().hFull().child(col().child(behind)).children(layer)
            capturedRoot = rootEl
            return rootEl
        }
        rt.frame(at: 0.0)

        rt.state.open = true
        rt.markNeedsCommit()
        rt.frame(at: 0.05)

        let panelInfo = info(rt, "confirm-dialog")
        #expect(panelInfo?.role == .dialog)
        #expect(panelInfo?.label == "Delete file?")
        #expect(panelInfo?.a11yDescription == "This can't be undone.")

        let closeInfo = info(rt, "close")
        #expect(closeInfo?.role == .button)
        #expect(closeInfo?.label == "Close")

        if let root = capturedRoot {
            assertNoEcho(root)
            #expect(findEl(root, key: "confirm-dialog")?.isModal == true)
            #expect(findEl(root, key: "confirm-scrim")?.isA11yHidden == true)
        }

        _ = rt.keyDown(KeyEvent(key: .escape, mods: .none), at: 0.1)
        rt.frame(at: 0.12)
        #expect(!rt.state.open)
    }

    @Test("Menu reads items, checked state, shortcuts, descriptions, submenus, and hides decorations")
    func menuA11y() {
        struct S {
            var open = true
            var wrap = false
            var count = 0
        }
        let k = Kit.neutral(dark: false)
        var capturedRoot: El<S>?
        let rt = Runtime(state: S(), viewport: Vec2(640, 480), systemDark: false) { s, cx in
            var layer: [El<S>] = []
            let trigger: El<S> = Menu<S>("file")
                .trigger(testButton(key: "file-button", "File") { st, _ in st.open.toggle() })
                .item(MenuItem<S>("New").shortcut("Ctrl+N").onSelect { st in
                    st.count += 1
                    st.open = false
                })
                .item(MenuItem<S>("Word wrap").checked(s.wrap).onSelect { st in
                    st.wrap.toggle()
                })
                .item(MenuItem<S>("Revert").disabled(true))
                .separator()
                .groupLabel("Share")
                .item(MenuItem<S>("Publish").badge("New"))
                .item(MenuItem<S>("Export").submenu([.item(MenuItem<S>("PDF"))], open: false))
                .open(s.open)
                .onClose { st in st.open = false }
                .build(kit: k, layer: &layer, cx: cx)
            let rootEl: El<S> = el().wFull().hFull().child(col().child(trigger)).children(layer)
            capturedRoot = rootEl
            return rootEl
        }
        rt.frame(at: 0.0)

        let menuInfo = info(rt, "file-menu")
        #expect(menuInfo?.role == .menu)

        if let root = capturedRoot {
            assertNoEcho(root)
            let newEl = findEl(root, key: "file-item0")
            #expect(newEl?.role == .menuItem)
            #expect(newEl?.a11yLabel == "New")
            #expect(newEl?.a11yShortcutHint == "Ctrl+N")

            let wrapEl = findEl(root, key: "file-item1")
            #expect(wrapEl?.role == .menuItemCheckbox)
            #expect(wrapEl?.a11yChecked == A11yChecked.falseState)

            let revertEl = findEl(root, key: "file-item2")
            #expect(revertEl?.a11yDisabled == true)

            let publishEl = findEl(root, key: "file-item5")
            #expect(publishEl?.a11yDescription == "New")

            let exportEl = findEl(root, key: "file-item6")
            #expect(exportEl?.a11yExpanded == false)

            let separators = allEls(root) { ($0.keyId ?? "").hasPrefix("sep") }
            #expect(separators.allSatisfy { $0.isA11yHidden })
        }

        _ = rt.keyDown(KeyEvent(key: .escape, mods: .none), at: 0.05)
        rt.frame(at: 0.07)
        #expect(!rt.state.open)
    }

    @Test("Popover and Tooltip read dialog/tooltip roles, label, description, trigger description, and hidden scrim")
    func popoverAndTooltipA11y() {
        struct S { var open = true }
        let k = Kit.neutral(dark: false)
        var capturedRoot: El<S>?
        let rt = Runtime(state: S(), viewport: Vec2(640, 480), systemDark: false) { s, cx in
            var layer: [El<S>] = []
            let pop = Popover<S>("share")
                .trigger(testButton(key: "share-button", "Share") { st, _ in st.open.toggle() })
                .title("Share")
                .description("Anyone with the link can view")
                .child(text("example.com/f/1").key("link"))
                .open(s.open)
                .onClose { st in st.open = false }
                .build(kit: k, layer: &layer, cx: cx)
            let tip = Tooltip<S>("tip")
                .trigger(testButton(key: "save", "Save") { _, _ in })
                .label("Saves to disk")
                .open(true)
                .build(kit: k, layer: &layer)
            let rootEl: El<S> = el().wFull().hFull().child(col().gap(8).child(pop).child(tip)).children(layer)
            capturedRoot = rootEl
            return rootEl
        }
        rt.frame(at: 0.0)

        let tipInfo = info(rt, "tip-tooltip")
        #expect(tipInfo?.role == .tooltip)
        #expect(tipInfo?.label == "Saves to disk")
        #expect(info(rt, "save")?.a11yDescription == "Saves to disk")

        let panelInfo = info(rt, "share-content")
        #expect(panelInfo?.role == .dialog)
        #expect(panelInfo?.label == "Share")
        #expect(panelInfo?.a11yDescription == "Anyone with the link can view")

        if let root = capturedRoot {
            assertNoEcho(root)
            #expect(findEl(root, key: "share-scrim")?.isA11yHidden == true)
        }
    }

    @Test("Select reads combobox trigger/value/disabled, open dialog/listbox/options, selection and positionInSet")
    func selectA11y() {
        struct S {
            var open = false
            var chosen: String? = "Pear"
        }
        let k = Kit.neutral(dark: false)
        let fruit = ["Apple", "Pear", "Plum"]
        var capturedRoot: El<S>?
        let rt = Runtime(state: S(), viewport: Vec2(640, 480), systemDark: false) { s, cx in
            var layer: [El<S>] = []
            let activeSelect = Select<S>("fruit", options: fruit)
                .label("Fruit")
                .placeholder("Choose")
                .current(s.chosen)
                .open(s.open)
                .onToggle { st in st.open.toggle() }
                .onClose { st in st.open = false }
                .onChoose { st, val, _ in
                    st.chosen = val
                    st.open = false
                }
                .build(kit: k, layer: &layer, cx: cx)
            let offSelect = Select<S>("size", options: fruit)
                .placeholder("Size")
                .disabled(true)
                .build(kit: k, layer: &layer, cx: cx)
            let rootEl: El<S> = el().wFull().hFull().child(col().gap(8).child(activeSelect).child(offSelect)).children(layer)
            capturedRoot = rootEl
            return rootEl
        }
        rt.frame(at: 0.0)

        let field = info(rt, "fruit-trigger")
        #expect(field?.role == .combobox)
        #expect(field?.label == "Fruit")
        #expect(field?.a11yValue == "Pear")
        #expect(field?.expanded == false)

        let off = info(rt, "size-trigger")
        #expect(off?.role == .combobox)
        #expect(off?.label == "Size")
        #expect(off?.disabled == true)

        rt.state.open = true
        rt.markNeedsCommit()
        rt.frame(at: 0.05)

        let content = info(rt, "fruit-content")
        #expect(content?.role == .dialog)
        #expect(content?.label == "Fruit")

        let listbox = info(rt, "listbox")
        #expect(listbox?.role == .listbox)
        #expect(listbox?.label == "Fruit")

        let pear = info(rt, "option1")
        #expect(pear?.role == .option)
        #expect(pear?.label == "Pear")
        #expect(pear?.itemSelected == true)

        if let root = capturedRoot {
            assertNoEcho(root)
            #expect(findEl(root, key: "option1")?.a11yPosInSet?.position == 2)
            #expect(findEl(root, key: "option1")?.a11yPosInSet?.size == 3)
            #expect(findEl(root, key: "option0")?.itemSelected == false)
            #expect(findEl(root, key: "fruit-scrim")?.isA11yHidden == true)
        }
    }

    @Test("Combobox reads trigger, value, search activeDescendant, listbox options, positionInSet, and disabled items")
    func comboboxA11y() {
        struct S {
            var combo = ComboboxState()
            var chosen: String? = "fast"
        }
        let k = Kit.neutral(dark: false)
        let options = [
            ComboboxItem(id: "fast", label: "Fast"),
            ComboboxItem(id: "smart", label: "Smart"),
            ComboboxItem(id: "late", label: "Retired model", disabled: true),
        ]
        var capturedRoot: El<S>?
        let rt = Runtime(state: S(), viewport: Vec2(640, 480), systemDark: false) { s, cx in
            var layer: [El<S>] = []
            let picker = Combobox<S>("model", state: \.combo, options: options)
                .label("Model")
                .placeholder("Pick a model")
                .current(s.chosen)
                .onChoose { st, id, _ in st.chosen = id }
                .build(s, kit: k, layer: &layer, cx: cx)
            let rootEl: El<S> = el().wFull().hFull().child(col().child(picker)).children(layer)
            capturedRoot = rootEl
            return rootEl
        }
        rt.frame(at: 0.0)

        let closedTrigger = info(rt, "model-value-trigger")
        #expect(closedTrigger?.role == .combobox)
        #expect(closedTrigger?.label == "Model")
        #expect(closedTrigger?.a11yValue == "Fast")
        #expect(closedTrigger?.expanded == false)

        _ = rt.state.combo.step(.toggle(current: rt.state.chosen))
        rt.markNeedsCommit()
        rt.frame(at: 0.05)

        #expect(info(rt, "model-value-trigger")?.expanded == true)
        let searchInfo = info(rt, "model-search")
        #expect(searchInfo?.role == .textInput)
        #expect(searchInfo?.label == "Search Model")

        let viewportInfo = info(rt, "model-viewport")
        #expect(viewportInfo?.role == .listbox)
        #expect(viewportInfo?.label == "Model")

        let fastInfo = info(rt, "model-option-fast")
        #expect(fastInfo?.role == .option)
        #expect(fastInfo?.itemSelected == true)
        #expect(info(rt, "model-option-late")?.disabled == true)

        if let root = capturedRoot {
            assertNoEcho(root)
            #expect(findEl(root, key: "model-option-fast")?.a11yPosInSet?.position == 1)
            #expect(findEl(root, key: "model-option-fast")?.a11yPosInSet?.size == 3)
            #expect(findEl(root, key: "model-search")?.a11yActiveDescendant == "model-option-fast")
        }
    }

    @Test("ToastRegion and Toast announce politely, hide decorations, and keep close/action buttons focusable")
    func toastA11y() {
        struct S { var clicks = 0 }
        let k = Kit.neutral(dark: false)
        var capturedRoot: El<S>?
        let rt = Runtime(state: S(), viewport: Vec2(640, 480), systemDark: false) { _, _ in
            let region = ToastRegion<S>(key: "toast-region")
                .toast(
                    Toast<S>(key: "saved", title: "Saved")
                        .description("3 files written")
                        .icon(k.glyph.check)
                        .action("Undo", primary: true) { st, _ in st.clicks += 1 }
                        .onClose { st, _ in st.clicks += 10 }
                        .build(using: k)
                )
                .build()
            capturedRoot = region
            return el().wFull().hFull().child(region)
        }
        rt.frame(at: 0.0)

        let regionInfo = info(rt, "toast-region")
        #expect(regionInfo?.role == .region)
        #expect(regionInfo?.label == "Notifications")

        let toastInfo = info(rt, "saved")
        #expect(toastInfo?.role == .status)
        #expect(toastInfo?.label == "Saved")
        #expect(toastInfo?.a11yDescription == "3 files written")

        let closeInfo = info(rt, "saved-dismiss")
        #expect(closeInfo?.role == .button)
        #expect(closeInfo?.label == "Close")
        #expect(closeInfo?.focusable == true)

        let undoInfo = rt.elements().first { !$0.exiting && $0.label == "Undo" }
        #expect(undoInfo?.role == .button)

        if let root = capturedRoot {
            // Check Toast top/content/icon/close no-echo; Toast action buttons delegate to @libs Kit.button
            if let topEl = findEl(root, key: "saved-top") {
                assertNoEcho(topEl)
            }
            let savedEl = findEl(root, key: "saved")
            #expect(savedEl?.a11yLive == .polite)
            #expect(findEl(root, key: "saved-title")?.isA11yHidden == true)
            #expect(findEl(root, key: "saved-description")?.isA11yHidden == true)
            #expect(findEl(root, key: "saved-icon")?.isA11yHidden == true)
        }
    }

    // MARK: - Collections (`tests/a11y/data.rs`)

    @Test("List reads listbox/listItem, group headings, selection, positionInSet, and no-echo")
    func listA11y() {
        struct S { var picked: Int? = 1 }
        let k = Kit.neutral(dark: false)
        var capturedRoot: El<S>?
        let rt = Runtime(state: S(), viewport: Vec2(500, 400), systemDark: false) { s, _ in
            var picker = List<S>().active(nil)
            for (i, name) in ["Inbox", "Drafts", "Sent"].enumerated() {
                picker = picker.item(
                    ListItem<S>(name)
                        .group(i < 2 ? "Mail" : "Other")
                        .selected(s.picked == i)
                        .onSelect { st, _ in st.picked = i }
                )
            }
            let plain = List<S>()
                .item(ListItem<S>("Read only"))
                .item(ListItem<S>("Rows"))
                .build(kit: k)
                .key("plain")
            let rootEl: El<S> = col().gap(8).child(picker.build(kit: k).key("mail")).child(plain)
            capturedRoot = rootEl
            return rootEl
        }
        rt.frame(at: 0.0)

        let inbox = info(rt, "item0")
        #expect(inbox?.role == .option)
        #expect(inbox?.label == "Inbox")
        #expect(inbox?.itemSelected == false)

        let drafts = info(rt, "item1")
        #expect(drafts?.itemSelected == true)

        if let root = capturedRoot {
            assertNoEcho(root)
            if let mailEl = findEl(root, key: "mail") {
                #expect(findEl(mailEl, key: "scroll")?.role == .listbox)
                #expect(findEl(mailEl, key: "group0")?.role == .group)
                #expect(findEl(mailEl, key: "group0")?.a11yLabel == "Mail")
                #expect(findEl(mailEl, key: "item0")?.a11yPosInSet?.position == 1)
                #expect(findEl(mailEl, key: "item0")?.a11yPosInSet?.size == 2)
                #expect(findEl(mailEl, key: "item2")?.a11yPosInSet?.position == 1)
                #expect(findEl(mailEl, key: "item2")?.a11yPosInSet?.size == 1)
            }
            if let plainEl = findEl(root, key: "plain") {
                #expect(findEl(plainEl, key: "scroll")?.role == .list)
                #expect(findEl(plainEl, key: "item1")?.role == .listItem)
                #expect(findEl(plainEl, key: "item1")?.a11yPosInSet?.position == 2)
                #expect(findEl(plainEl, key: "item1")?.a11yPosInSet?.size == 2)
            }
        }
    }

    @Test("TableView reads grid, columnHeader sort state, row position/selection, gridCell, and activeDescendant")
    func tableA11y() throws {
        struct S {
            var table = TableState()
            var names = ["alpha.rs", "beta.rs", "gamma.rs", "delta.rs"]
            var chosen: String?
        }
        let k = Kit.neutral(dark: false)
        var capturedRoot: El<S>?
        let rt = Runtime(state: S(), viewport: Vec2(500, 300), systemDark: false) { s, cx in
            let tbl = TableView<S>(
                \.table,
                len: { $0.names.count },
                rowID: { _, i in "f\(i)" }
            )
            .name("Files")
            .column(TableCol("name", "Name").flex(1.0).sortable())
            .column(TableCol("size", "Size").width(90.0).align(.end).resizable(false))
            .cell { st, i, colId in
                switch colId {
                case "name": return .text(st.names[i])
                default: return .text("\(i + 1) KB").mono()
                }
            }
            .onOpen { st, id, _ in st.chosen = id }
            .build(s, cx: cx, kit: k)
            .h(300.0)
            capturedRoot = tbl
            return col().size(500, 300).child(tbl)
        }
        rt.state.table.select("f1")
        rt.markNeedsCommit()
        rt.frame(at: 0.0)

        let gridInfo = info(rt, "table")
        #expect(gridInfo?.role == .grid)
        #expect(gridInfo?.label == "Files")
        #expect(gridInfo?.focusable == true)

        let rowInfo = info(rt, "f1")
        #expect(rowInfo?.role == .row)
        #expect(rowInfo?.label == "beta.rs 2 KB")
        #expect(rowInfo?.itemSelected == true)
        #expect(info(rt, "f0")?.itemSelected == false)

        if let root = capturedRoot {
            assertNoEcho(root)
            #expect(root.a11yActiveDescendant == "f1")
            if let header = findEl(root, key: "header"), let nameCol = findEl(header, key: "name") {
                #expect(nameCol.role == .columnHeader)
                #expect(nameCol.a11yLabel == "Name")
                #expect(nameCol.handlers.onClick != nil)
                let resizer = findEl(header, key: "name-resize")
                #expect(resizer?.role == .splitter)
                #expect(resizer?.a11yLabel == "Resize Name")
            }
            if let f1El = findEl(root, key: "f1") {
                #expect(f1El.a11yPosInSet?.position == 2)
                #expect(f1El.a11yPosInSet?.size == 4)
                #expect(findEl(f1El, key: "size")?.role == .gridCell)
                #expect(findEl(f1El, key: "size")?.a11yLabel == "2 KB")
            }
        }

        // Assistive click on sortable header sorts ascending, click row selects, focus + Up + Enter opens cursor row
        #expect(rt.accessibilityAction("name", .press, at: 0.02))
        rt.frame(at: 0.03)
        #expect(rt.state.table.sort?.0 == "name" && rt.state.table.sort?.1 == .ascending)
        #expect(rt.accessibilityJSON(pretty: false).contains("\"ascending\""))

        #expect(rt.accessibilityAction("f3", .press, at: 0.04))
        rt.frame(at: 0.05)
        #expect(rt.state.table.selected.contains("f3"))

        #expect(rt.accessibilityAction("table", .focus, at: 0.06))
        rt.frame(at: 0.07)
        #expect(rt.keyDown(KeyEvent(key: .arrowUp, mods: .none), at: 0.08))
        rt.frame(at: 0.09)
        #expect(rt.state.table.selected.contains("f2"))
        #expect(capturedRoot?.a11yActiveDescendant == "f2")
        #expect(rt.keyDown(KeyEvent(key: .enter, mods: .none), at: 0.10))
        rt.frame(at: 0.11)
        #expect(rt.state.chosen == "f2")
    }

    // MARK: - Shell & TabStrip (`tests/a11y/shell.rs`)

    @Test("SplitView, Toolbar, SidebarSection, SidebarRow, SidebarToggle & Page read landmarks, range, and no-echo")
    func shellA11y() {
        struct S {
            var sidebar = PaneState(width: 240).range(180, 420)
            var collapsed = false
            var picked: Int? = 1
        }
        let k = Kit.neutral(dark: false)
        let names = ["Alpha", "Bravo", "Charlie"]
        var capturedRoot: El<S>?
        let rt = Runtime(state: S(), viewport: Vec2(720, 480), systemDark: false) { s, _ in
            var rows: [El<S>] = []
            for i in 0..<names.count {
                var r = SidebarRow<S>(key: "row\(i)", title: names[i])
                    .selected(s.picked == i)
                    .onClick { st, _ in st.picked = i }
                switch i {
                case 0: r = r.status(.badge("3"))
                case 1: r = r.subtitle("bravo@example.com").status(.spinner(label: "Working"))
                default: r = r.status(.dot(k.c.textAccent))
                }
                rows.append(r.build(k))
            }
            let sidebar = Sidebar<S>(key: "sidebar")
                .section(
                    SidebarSection<S>(key: "sec", title: "Today")
                        .collapsible(true, collapsed: s.collapsed)
                        .onToggle { st, _ in st.collapsed.toggle() }
                        .children(rows)
                        .build(k)
                )
                .build(k)
            let split = SplitView<S>(key: "split") { _ in
                col().key("body").child(testButton(key: "run", "Run") { _, _ in })
            }
            .sidebar(\.sidebar, current: s.sidebar) { _ in sidebar }
            .toolbar(
                Toolbar<S>(key: "toolbar", title: "Project")
                    .subtitle("Main workspace")
                    .trailing(k.iconButton(key: "share", svg: k.glyph.copy, label: "Share") { _, _ in })
                    .build(k)
            )
            .build(s, kit: k)
            capturedRoot = split
            return split
        }
        rt.frame(at: 0.0)

        #expect(info(rt, "split-sidebar-pane")?.role == .region)
        #expect(info(rt, "split-sidebar-pane")?.label == "Sidebar")
        #expect(info(rt, "split-main")?.role == .main)
        #expect(info(rt, "toolbar")?.role == .toolbar)
        #expect(info(rt, "toolbar")?.label == "Project")
        #expect(info(rt, "sidebar-body")?.role == .list)
        #expect(info(rt, "sec")?.role == .group)
        #expect(info(rt, "sec")?.label == "Today")
        #expect(info(rt, "sec-header")?.role == .button)
        #expect(info(rt, "sec-header")?.expanded == true)

        let row0 = info(rt, "row0")
        #expect(row0?.role == .listItem)
        #expect(row0?.label == "Alpha")
        #expect(row0?.a11yDescription == "3")
        #expect(row0?.itemSelected == false)

        let row1 = info(rt, "row1")
        #expect(row1?.label == "Bravo, bravo@example.com")
        #expect(row1?.a11yDescription == "Working")
        #expect(row1?.itemSelected == true)

        if let root = capturedRoot {
            assertNoEcho(root)
            let grip = findEl(root, key: "split-sidebar-grip")
            #expect(grip?.role == .splitter)
            #expect(grip?.a11yLabel == "Resize sidebar")
            #expect(grip?.a11yRange?.value == 240.0)
            #expect(grip?.a11yRange?.min == 180.0)
            #expect(grip?.a11yRange?.max == 420.0)
            #expect(grip?.a11yRange?.step == 8.0)
        }

        // Collapsing sidebar renders SidebarToggle with "Show sidebar" + expanded=false
        rt.state.sidebar.setOpen(false)
        rt.markNeedsCommit()
        rt.frame(at: 0.05)

        let toggle = info(rt, "split-sidebar-toggle")
        #expect(toggle?.role == .button)
        #expect(toggle?.label == "Show sidebar")
        #expect(toggle?.expanded == false)
    }

    @Test("TabStrip exposes tabList/tab roles, selection, positionInSet, disabled, and hides internal labels")
    func tabStripA11y() {
        let k = Kit.neutral(dark: false)
        var selected: String? = "b"
        let items: [StripTabItem<Int>] = [
            StripTabItem(id: "a", title: "One").badge("2"),
            StripTabItem(id: "b", title: "Two").subtitle("sub"),
            StripTabItem(id: "c", title: "Three").disabled(true),
        ]
        let elTree: El<Int> = TabStrip<Int>(key: "tabs", tabs: items, selected: selected)
            .onSelect { _, id, _ in selected = id }
            .build(0, kit: k)

        assertNoEcho(elTree)
        let track = findEl(elTree, key: "tabs-track")
        #expect(track?.role == .tabList)
        #expect(track?.a11yLabel == "Tabs")

        let tabB = findEl(elTree, key: "tabs-tab-b")
        #expect(tabB?.role == .tab)
        #expect(tabB?.a11yLabel == "Two")
        #expect(tabB?.itemSelected == true)
        #expect(tabB?.a11yPosInSet?.position == 2)
        #expect(tabB?.a11yPosInSet?.size == 3)

        let tabC = findEl(elTree, key: "tabs-tab-c")
        #expect(tabC?.a11yDisabled == true)
    }

    // MARK: - FileTree (`tests/a11y/disclosure.rs`)

    @Test("Tree and FileTree expose level, expanded state, selection, description, and no-echo")
    func fileTreeA11y() {
        struct S {
            var files: TreeModel<FileNode<(UInt32, UInt32)>>
        }
        var model = FileTree().build([
            ("src/main.rs", (UInt32(3), UInt32(1))),
            ("src/lib.rs", (UInt32(0), UInt32(0))),
            ("README.md", (UInt32(3), UInt32(1))),
        ])
        model.select("README.md")

        let k = Kit.neutral(dark: false)
        var capturedRoot: El<S>?
        let rt = Runtime(state: S(files: model), viewport: Vec2(400, 300), systemDark: false) { s, cx in
            let treeEl = Tree<S, FileNode<(UInt32, UInt32)>>(\.files, label: { $0.name })
                .name("Files")
                .row { node, r in
                    var item = TreeRowItem<S>.file(node, row: r)
                    if r.expanded == nil, let (add, del) = node.data, (add > 0 || del > 0) {
                        item = item.changes(added: add, removed: del).badge("M")
                    }
                    return item
                }
                .build(s, cx: cx, kit: k)
                .h(300)
            capturedRoot = treeEl
            return col().size(400, 300).child(treeEl)
        }
        rt.frame(at: 0.0)

        let src = info(rt, "src")
        #expect(src?.role == .treeItem)
        #expect(src?.label == "src")
        #expect(src?.level == 1)
        #expect(src?.expanded == false)
        #expect(src?.itemSelected == false)

        let readme = info(rt, "README.md")
        #expect(readme?.role == .treeItem)
        #expect(readme?.itemSelected == true)
        #expect(readme?.a11yDescription == "3 added, 1 removed, M")

        if let root = capturedRoot {
            assertNoEcho(root)
            #expect(root.role == .tree)
            #expect(root.a11yLabel == "Files")
        }

        rt.state.files.setExpanded("src", true)
        rt.markNeedsCommit()
        rt.frame(at: 0.05)

        #expect(info(rt, "src")?.expanded == true)
        let main = info(rt, "src/main.rs")
        #expect(main?.label == "main.rs")
        #expect(main?.level == 2)
    }

    // MARK: - Full AccessKit JSON & Assistive Action Parity (`#387`)

    @Test("Full AccessKit JSON tree + assistive Action dispatch + #387 ElementRole cases")
    func fullAccessKitJSONAndActionParity() {
        struct S {
            var sidebar = PaneState(width: 240).range(180, 420)
            var wrap = false
            var clicks = 0
            var accOpen = false
            var search = TextEdit()
            var email = TextEdit("a@b.c")
            var notes = TextEdit("hi")
            var token = TextEdit("tok")
            var username = TextEdit("ada")
        }
        let k = Kit.neutral(dark: false)
        let rt = Runtime(state: S(), viewport: Vec2(800, 560), systemDark: false) { s, cx in
            var layer: [El<S>] = []
            let menuEl = Menu<S>("menu")
                .trigger(testButton(key: "menu-trig", "Menu") { _, _ in })
                .item(
                    MenuItem<S>("Wrap")
                        .checked(s.wrap)
                        .onSelect { st in st.wrap.toggle() }
                )
                .open(true)
                .build(kit: k, layer: &layer, cx: cx)
            let body = col().key("content").gap(8).children([
                TextInput<S>(key: "search", \.search)
                    .placeholder("Search files")
                    .clearButton()
                    .build(k),
                TextInput<S>(key: "email", \.email)
                    .label("Email")
                    .placeholder("you@example.com")
                    .disabled(true)
                    .build(k),
                TextArea<S>(key: "notes", \.notes)
                    .label("Notes")
                    .build(k),
                Field<S>()
                    .label("API Token")
                    .prefix("From your account")
                    .suffix("Kept in keychain")
                    .control(TextInput(key: "tok", \.token).label("API Token").build(k))
                    .build(k)
                    .key("tok-field"),
                TextField<S>(key: "tf", "Username", \.username)
                    .error("Name is taken")
                    .build(k),
                Accordion<S>()
                    .item(
                        AccordionSection("Details")
                            .expanded(s.accOpen)
                            .onToggle { st, _ in st.accOpen.toggle() }
                            .child(text("Inner detail").key("acc-body"))
                    )
                    .build(k)
                    .key("acc"),
                menuEl,
                Toast<S>(key: "toast", title: "Saved").build(using: k),
                testButton(key: "act-btn", "Run") { st, _ in st.clicks += 1 }
            ])
            let split = SplitView<S>(key: "split") { _ in body }
                .sidebar(\.sidebar, current: s.sidebar) { _ in
                    Sidebar<S>(key: "sb")
                        .section(SidebarSection<S>(key: "sec", title: "Nav").build(k))
                        .build(k)
                }
                .toolbar(Toolbar<S>(key: "tb", title: "Workspace").build(k))
                .build(s, kit: k)
            return col().wFull().hFull().child(split).children(layer)
        }
        rt.frame(at: 0.0)

        let json = rt.accessibilityJSON(pretty: false)
        #expect(json.contains("\"toolbar\""))
        #expect(json.contains("\"splitter\""))
        #expect(json.contains("\"status\""))
        #expect(json.contains("\"list\""))
        #expect(json.contains("\"menu-item-check-box\""))
        #expect(json.contains("\"textbox\""))
        #expect(json.contains("\"API Token\""))
        #expect(json.contains("\"From your account. Kept in keychain\""))
        #expect(json.contains("\"Name is taken\""))
        #expect(json.contains("\"invalid\""))
        #expect(json.contains("\"live-assertive\""))
        #expect(json.contains("\"Search files\""))
        #expect(json.contains("\"Notes\""))
        #expect(info(rt, "search-input")?.label == "Search files")
        #expect(info(rt, "email-input")?.disabled == true)
        #expect(info(rt, "notes-input")?.label == "Notes")

        // `tests/a11y/controls.rs:222` fields_name_their_editor_and_describe_their_help_and_errors:
        // an enabled field can take a new value, a disabled one can't, and a text area reads multi-line.
        func node(_ v: [String: Any], _ key: String) -> [String: Any]? {
            if v["key"] as? String == key { return v }
            for c in (v["children"] as? [[String: Any]]) ?? [] {
                if let hit = node(c, key) { return hit }
            }
            return nil
        }
        func tree() -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(rt.accessibilityJSON().utf8))) as? [String: Any] ?? [:]
        }
        let fields = tree()
        let search = node(fields, "search-input")
        #expect(search?["role"] as? String == "textbox")
        #expect(search?["name"] as? String == "Search files")
        let searchActions = (search?["actions"] as? [String]) ?? []
        #expect(searchActions.contains("set-value") && searchActions.contains("focus"))
        let email = node(fields, "email-input")
        let emailStates = (email?["states"] as? [String]) ?? []
        let emailActions = (email?["actions"] as? [String]) ?? []
        #expect(emailStates.contains("disabled"))
        #expect(!emailActions.contains("set-value"))
        let notes = node(fields, "notes-input")
        #expect(notes?["role"] as? String == "multiline-text-input")
        #expect(notes?["name"] as? String == "Notes")
        #expect(json.contains("\"multiline-text-input\""))
        #expect(rt.accessibilityAction("search-input", .setValue, value: .text("Ada"), at: 0.01))
        rt.frame(at: 0.02)
        #expect(rt.state.search.text == "Ada")
        #expect(node(tree(), "search-input")?["value"] as? String == "Ada")
        #expect(!rt.accessibilityAction("email-input", .setValue, value: .text("x"), at: 0.03), "a disabled field takes no value")
        #expect(rt.state.email.text == "a@b.c")
        rt.frame(at: 0.03)

        #expect(rt.accessibilityAction("menu-item0", .press, at: 0.04))
        rt.frame(at: 0.05)
        #expect(rt.state.wrap)

        // When menu modal overlay is closed via a second toggle/press or modal check: test act-btn & acc trigger
        let triggerPath = rt.elements().first { $0.path.contains("item0") && $0.key == "trigger" }?.path
        if let triggerPath {
            #expect(rt.accessibilityAction(triggerPath, .press, at: 0.07))
            rt.frame(at: 0.08)
            #expect(rt.state.accOpen)
        }
        #expect(rt.accessibilityAction("act-btn", .press, at: 0.09))
        rt.frame(at: 0.10)
        #expect(rt.state.clicks == 1)
    }

    @Test("Page names its Toolbar and exposes main landmark and Back button (`tests/a11y/shell.rs:87`)")
    func aPageNamesItsToolbar() {
        struct App {}
        let k = Kit.neutral(dark: false)
        let rt = Runtime(state: App(), viewport: Vec2(640, 480), systemDark: false) { _, _ in
            Page<App>(key: "page")
                .title("Settings")
                .leading(k.iconButton(key: "back", svg: k.glyph.close, label: "Back") { _, _ in })
                .child(col().key("settings"))
                .build(k)
        }
        rt.frame(at: 0.0)
        let toolbar = rt.elements().first { $0.role == .toolbar }
        #expect(toolbar?.label == "Settings")
        let mainPane = rt.elements().first { $0.key == "page-panel" || $0.role == .main }
        #expect(mainPane?.role == .main)
        let json = rt.accessibilityJSON(pretty: false)
        #expect(json.contains("\"toolbar\""))
        #expect(json.contains("\"Settings\""))
        #expect(json.contains("\"Back\""))
    }
}
