import Foundation
import Testing
@testable import Rune
#if os(macOS)
import AppKit
#elseif canImport(UIKit) && !os(watchOS)
import UIKit
#endif

@Suite("Accessible wrappers and landmarks")
@MainActor
struct A11yPresentationTests {
    private let viewport = Vec2(280, 200)

    private func layoutInput<S>(_ element: El<S>) -> LayoutInputNode {
        LayoutInputNode(style: element.layout, children: element.children.map(layoutInput))
    }

    private func projections<S>(_ view: El<S>, state: S) throws -> [AccessibilityNode] {
        let runtime = Runtime(state: state, viewport: viewport, systemDark: false) { _, _ in view }
        runtime.frame(at: 0)
        let layout = LayoutEngine.compute(root: layoutInput(view), viewport: viewport)
        return [
            try #require(AccessibilityTreeBuilder.project(element: view, layout: layout, state: state)),
            runtime.accessibilitySnapshot(),
            AccessibilityTreeBuilder.project(elements: runtime.elements(), focusedPath: nil, viewport: viewport)
        ]
    }

    private func wrapperView() -> El<Int> {
        let wrapper: El<Int> = col().key("wrapper").size(180, 80).scrollY().onClick { $0 += 1 }
            .role(.presentation).children([
                text("First").key("first"),
                col().key("hidden").a11yHidden().child(col().child(text("Hidden").key("hidden-child"))),
                col().key("nested").role(.presentation).child(text("Second").key("second")),
                col().key("inert").inert().child(text("Inert").key("inert-child")),
                col().key("transparent").opacity(0).child(text("Invisible").key("invisible-child"))
            ])
        return col().key("root").children([wrapper, text("After").key("after")])
    }

    @Test func disclosureActionsRequireAnEnabledPressHandlerAndExpansionState() throws {
        let view: El<Int> = col().key("root").children([
            el().key("closed").expanded(false).onClick { $0 += 1 },
            el().key("open").expanded(true).onBackgroundPressTx { state, _ in state += 1 },
            el().key("passive").role(.button).expanded(false),
            el().key("plain").onClick { $0 += 1 },
            el().key("disabled").expanded(false).onClick { $0 += 1 }.disabled(true)
        ])
        for root in try projections(view, state: 0) {
            for node in root.children {
                #expect(node.actions.contains(.expand) == (node.id == "closed"))
                #expect(node.actions.contains(.collapse) == (node.id == "open"))
            }
            #expect(root.children.map(\.id) == ["closed", "open", "passive", "plain", "disabled"])
        }
    }

    @Test func presentationPromotesChildrenInOrderAndHiddenSubtreesStayHidden() throws {
        for root in try projections(wrapperView(), state: 0) {
            try #require(root.children.map(\.id) == ["first", "second", "inert", "after"])
            #expect(root.children[0].actions.contains(.scrollIntoView))
            #expect(root.children[1].actions.contains(.scrollIntoView))
            let inert = root.children[2]
            #expect(inert.isDisabled)
            #expect(inert.actions == [.scrollIntoView])
            #expect(inert.children.first?.id == "inert-child")
            #expect(inert.children.first?.isDisabled == true)
            #expect(!root.children[3].actions.contains(.scrollIntoView))
        }
    }

    @Test func implicitRolesKeepInteractiveNodesAndPromoteLayoutChildren() throws {
        let view: El<Int> = col().key("root").children([
            col().child(col().child(text("First").key("first"))),
            el().label("Named group"),
            col().key("group-key"),
            row().focusable().child(text("keyboard group")),
            row().role(.presentation).focusable().child(text("focusable presentation")),
            row().onClick { $0 += 1 }.role(.presentation).child(text("press-only presentation")),
            row().onClick { $0 += 1 }.child(text("press-only group")),
            row().onClick { $0 += 1 }.focusable().child(text("focusable button")),
            el().role(.icon),
            el().role(.icon).key("keyed-icon"),
            el().role(.icon).label("named icon"),
            el().role(.icon).focusable().child(text("focus icon")),
            el().role(.separator).key("silent-rule"),
            el().role(.separator).onClick { $0 += 1 }.key("grip"),
            row().scrollY().size(100, 10).child(text("scroll child").h(20)),
            col().inert().child(text("inert child").key("inert-child"))
        ])
        let expected: [ElementRole] = [
            .text, .group, .group, .group, .group, .text, .button, .button, .image, .image, .group,
            .splitter, .scrollView, .text
        ]
        for tree in try projections(view, state: 0) {
            try #require(tree.children.map(\.role) == expected)
            #expect(tree.children[0].id == "first")
            #expect(tree.children[1].label == "Named group")
            #expect(tree.children[2].id == "group-key")
            #expect(tree.children[3].isFocusable)
            #expect(tree.children[4].isFocusable)
            #expect(tree.children[8].id == "keyed-icon")
            #expect(tree.children[9].label == "named icon")
            #expect(tree.children[10].isFocusable)
            #expect(tree.children[11].id == "grip")
            #expect(tree.children[12].children.first?.actions.contains(.scrollIntoView) == true)
            #expect(tree.children[13].id == "inert-child")
            #expect(tree.children[13].isDisabled)
        }
    }

    @Test func scrolledControlSpeaksItsNameOnceAndKeepsNestedActions() throws {
        let view: El<Int> = col().key("scroll").scrollY().size(100, 20).children([
            col().role(.button).label("Open").key("open").children([
                col().child(text("Open").key("repeat")),
                el().role(.button).label("Options").key("options").onClick { $0 += 1 }
            ])
        ])
        for root in try projections(view, state: 0) {
            let button = try #require(root.children.first)
            #expect(button.label == "Open")
            #expect(button.children.map(\.id) == ["options"])
            #expect(button.children.first?.actions.contains(.press) == true)
        }
    }

    @Test func anonymousApplicationRootAlwaysPreservesWindowBounds() throws {
        let view: El<Int> = col().sizeFull().child(col().child(text("Only child").key("leaf")))
        for root in try projections(view, state: 0) {
            #expect(root.role == .group)
            #expect(root.frame.width == viewport.x && root.frame.height == viewport.y)
            #expect(root.children.map(\.id) == ["leaf"])
        }
    }

    @Test func nativePaintInspectionPreservesTheLiveTree() throws {
        let contents: El<Int> = col().key("root").children([
            col().key("background").child(text("Caption").key("caption")),
            col().key("holder").child(col().key("dialog").modal().children([
                el().key("status").role(.status).labelledBy("caption"),
                row().key("viewport").scrollY().size(100, 20).child(
                    col().role(.presentation).onClick { $0 += 1 }.child(text("Visible").key("visible").h(40))
                )
            ]))
        ])
        let runtime = Runtime(state: 0, viewport: viewport) { _, _ in contents }
        _ = runtime.renderFrame(at: 0)
        #expect(runtime.nativeInspection?.a11yMaterialized == false)
        #expect(runtime.element(byKey: "viewport")?.a11yInput?.scrolls == true)
        #expect(runtime.nativeInspection?.a11yMaterialized == false)
        let live = runtime.accessibilitySnapshot()
        let recorded = AccessibilityTreeBuilder.project(elements: runtime.elements(), focusedPath: nil, viewport: viewport)
        #expect(runtime.nativeInspection?.a11yMaterialized == true)
        for tree in [live, recorded] {
            try #require(tree.children.map(\.id) == ["holder"])
            let dialog = try #require(tree.children.first?.children.first)
            #expect(dialog.isModal)
            #expect(dialog.children.map(\.id) == ["status", "viewport"])
            #expect(dialog.children.first?.label == "Caption")
            #expect(dialog.children.last?.role == .scrollView)
            #expect(dialog.children.last?.children.map(\.id) == ["visible"])
            #expect(dialog.children.last?.children.first?.actions.contains(.scrollIntoView) == true)
        }
    }

    #if os(macOS)
    @Test func appKitKeepsAKeyboardReachableRootGroup() throws {
        let tree: El<Int> = col().key("root").focusable().child(text("Instructions"))
        let view = NSView()
        for root in try projections(tree, state: 0) {
            let host = MacOSAccessibilityHost()
            host.update(tree: root, parentView: view) { _, _ in }
            let target = try #require(host.accessibilityChildren().first as? RuneNSAccessibilityElement)
            #expect(target.nodeId == "root")
            #expect(target.accessibilityRole() == .group)
        }
    }
    #endif

    #if canImport(UIKit) && !os(watchOS)
    private func nativeContents(_ element: RuneUIAccessibilityElement) -> [RuneUIAccessibilityElement] {
        element.accessibilityElements as? [RuneUIAccessibilityElement] ?? []
    }

    @Test func uiKitExposesNamedAndFocusableGroupsInReadingOrder() {
        let root = AccessibilityNode(id: "root", role: .group, children: [
            AccessibilityNode(id: "layout", role: .group, actions: [.scrollIntoView], children: [
                AccessibilityNode(id: "text", role: .text, label: "Child")
            ]),
            AccessibilityNode(id: "named", role: .group, label: "Inspector"),
            AccessibilityNode(id: "keyboard", role: .group, isFocusable: true),
            AccessibilityNode(id: "viewport", role: .scrollView, label: "Items")
        ])
        func stops(_ elements: [RuneUIAccessibilityElement]) -> [RuneUIAccessibilityElement] {
            elements.flatMap { $0.isAccessibilityElement ? [$0] : stops(nativeContents($0)) }
        }
        let readable = stops(UIKitAccessibilityMapper.buildElements(from: root, container: UIView()))
        #expect(readable.map(\.nodeId) == ["text", "named", "keyboard", "viewport"])
        #expect(readable.first { $0.nodeId == "named" }?.accessibilityLabel == "Inspector")
    }

    @Test func uiKitExposesNativeContainersAndReadingOrder() async throws {
        let roles: [(ElementRole, UIAccessibilityContainerType)] = [
            (.list, .list), (.listbox, .list), (.tree, .list),
            (.table, .dataTable), (.grid, .dataTable), (.treeGrid, .dataTable),
            (.group, .semanticGroup), (.main, .landmark), (.region, .landmark)
        ]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let host = UIView(frame: CGRect(x: 20, y: 30, width: 240, height: 160))
        window.addSubview(host)
        try await confirmation(expectedCount: roles.count) { activated in
            for (role, expectedType) in roles {
                let root = AccessibilityNode(id: "container", role: role, label: "Items",
                                             frame: .fromXYWH(10, 15, 200, 120), children: [
                    AccessibilityNode(id: "action", role: .button, label: "Open",
                                      frame: .fromXYWH(48, 67, 80, 24), actions: [.press], children: [
                        AccessibilityNode(id: "caption", role: .text, label: "Open")
                    ]),
                    AccessibilityNode(id: "next", role: .text, label: "Next")
                ])
                let top = UIKitAccessibilityMapper.buildElements(from: root, container: host) { id, action in
                    #expect(id == "action")
                    #expect(action == .press)
                    activated()
                }
                try #require(top.count == 1)
                let container = top[0]
                #expect(container.accessibilityContainerType == expectedType)
                #expect(!container.isAccessibilityElement)
                let children = nativeContents(container)
                try #require(children.map(\.nodeId) == ["action", "next"])
                #expect(children.allSatisfy { ($0.accessibilityContainer as? RuneUIAccessibilityElement) === container })
                #expect(container.accessibilityElementCount() == children.count)
                #expect((container.accessibilityElement(at: 1) as? RuneUIAccessibilityElement) === children[1])
                #expect(container.index(ofAccessibilityElement: children[0]) == 0)
                #expect(children[0].isAccessibilityElement)
                #expect(children[0].accessibilityContainerType == .none)
                #expect(nativeContents(children[0]).isEmpty)
                #expect(children[0].accessibilityActivate())
                #expect(children[0].accessibilityFrameInContainerSpace == CGRect(x: 38, y: 52, width: 80, height: 24))
                let screenFrame = UIAccessibility.convertToScreenCoordinates(CGRect(x: 48, y: 67, width: 80, height: 24), in: host)
                #expect(children[0].accessibilityFrame == screenFrame)
            }
        }
    }

    @Test func uiKitDataTableTracksCellsAcrossUpdates() throws {
        let host = UIView()
        var cache: [AccessibilityIdentity: RuneUIAccessibilityElement] = [:]
        let header = AccessibilityNode(id: "head", role: .columnHeader, label: "Filename")
        let title = AccessibilityNode(id: "title", role: .rowHeader, label: "Folder")
        let cell = AccessibilityNode(id: "cell", role: .gridCell, label: "Projects", children: [
            AccessibilityNode(id: "text", role: .text, label: "Projects")
        ])
        let blankCell = AccessibilityNode(id: "blank", role: .cell)
        let wrapper = AccessibilityNode(id: "layout", role: .group, children: [blankCell])
        func publish(_ cells: [AccessibilityNode]) throws -> RuneUIAccessibilityElement {
            let table = AccessibilityNode(id: "files", role: .treeGrid, children: [
                AccessibilityNode(id: "columns", role: .row, children: [header]),
                AccessibilityNode(id: "folder", role: .row, children: cells)
            ])
            let top = UIKitAccessibilityMapper.updateElements(from: table, container: host, cache: &cache, onAction: nil)
            return try #require(top.first)
        }
        let table = try publish([title, cell, wrapper])
        let data = try #require((table as AnyObject) as? any UIAccessibilityContainerDataTable)
        #expect(data.accessibilityRowCount() == 2)
        #expect(data.accessibilityColumnCount() == 3)
        let row = try #require(nativeContents(table).last)
        let target = try #require(nativeContents(row).first { $0.nodeId == "cell" })
        #expect(target.isAccessibilityElement)
        #expect(nativeContents(target).isEmpty)
        let nativeCell = try #require(data.accessibilityDataTableCellElement(forRow: 1, column: 1))
        let blank = try #require(data.accessibilityDataTableCellElement(forRow: 1, column: 2))
        #expect((blank as? RuneUIAccessibilityElement)?.nodeId == "blank")
        #expect((nativeCell as AnyObject) === target)
        #expect(nativeCell.accessibilityRowRange() == NSRange(location: 1, length: 1))
        #expect(nativeCell.accessibilityColumnRange() == NSRange(location: 1, length: 1))
        #expect(data.accessibilityDataTableCellElement(forRow: 0, column: 1) == nil)
        #expect(data.accessibilityDataTableCellElement(forRow: 2, column: 0) == nil)
        let columnHeaders = try #require(data.accessibilityHeaderElements?(forColumn: 0))
        let rowHeaders = try #require(data.accessibilityHeaderElements?(forRow: 1))
        #expect(columnHeaders.compactMap { ($0 as? RuneUIAccessibilityElement)?.nodeId } == ["head"])
        #expect(rowHeaders.compactMap { ($0 as? RuneUIAccessibilityElement)?.nodeId } == ["title"])
        #expect(try publish([cell, title]) === table)
        #expect((data.accessibilityDataTableCellElement(forRow: 1, column: 0) as AnyObject?) === target)
        #expect(nativeCell.accessibilityColumnRange() == NSRange(location: 0, length: 1))
        _ = try publish([AccessibilityNode(id: "cell", role: .text, label: "Summary")])
        #expect(data.accessibilityDataTableCellElement(forRow: 1, column: 0) == nil)
        #expect(nativeCell.accessibilityRowRange() == NSRange(location: NSNotFound, length: 0))
        #expect(nativeCell.accessibilityColumnRange() == NSRange(location: NSNotFound, length: 0))
    }

    @Test func uiKitDataTablePreservesLogicalRowsOutsideTheViewport() throws {
        let host = UIView()
        func table(_ positions: [Int], size: Int) throws -> any UIAccessibilityContainerDataTable {
            let header = AccessibilityNode(id: "header", role: .row, children: [
                AccessibilityNode(id: "name", role: .columnHeader, label: "Name")
            ])
            let rows = positions.enumerated().map { index, position in
                AccessibilityNode(id: "row-\(index)", role: .row, positionInSet: position, sizeOfSet: size, children: [
                    AccessibilityNode(id: "file-\(index)", role: .cell, label: "File \(index)")
                ])
            }
            let root = AccessibilityNode(id: "files", role: .table, children: [header] + rows)
            let native = try #require(UIKitAccessibilityMapper.buildElements(from: root, container: host).first)
            return try #require((native as AnyObject) as? any UIAccessibilityContainerDataTable)
        }
        let data = try table([24, 25], size: 100_000)
        #expect(data.accessibilityRowCount() == 100_001)
        let header = try #require(data.accessibilityDataTableCellElement(forRow: 0, column: 0))
        #expect((header as? RuneUIAccessibilityElement)?.nodeId == "name")
        let cell = try #require(data.accessibilityDataTableCellElement(forRow: 25, column: 0))
        #expect(cell.accessibilityRowRange() == NSRange(location: 25, length: 1))
        #expect((cell as? RuneUIAccessibilityElement)?.nodeId == "file-0")
        #expect((data.accessibilityDataTableCellElement(forRow: 26, column: 0) as? RuneUIAccessibilityElement)?.nodeId == "file-1")
        #expect(data.accessibilityDataTableCellElement(forRow: 24, column: 0) == nil)
        #expect(data.accessibilityDataTableCellElement(forRow: 99_999, column: 0) == nil)
        for invalid in [try table([24, 24], size: 100_000), try table([1, 2], size: Int.max)] {
            #expect(invalid.accessibilityRowCount() == 3)
            #expect((invalid.accessibilityDataTableCellElement(forRow: 1, column: 0) as? RuneUIAccessibilityElement)?.nodeId == "file-0")
        }
    }
    #endif

    @Test func minimumAuthoredSetPositionClampsToFirstItem() throws {
        let row: El<Int> = el().key("row").role(.row).label("First").positionInSet(.min, size: 2)
        for node in try projections(row, state: 0) {
            #expect(node.positionInSet == 0)
            #expect(node.sizeOfSet == 2)
        }
    }

    @Test func dialogRolesPreserveAuthoredModality() throws {
        for role in [ElementRole.dialog, .alertDialog] {
            for modal in [false, true] {
                let dialog: El<Int> = col().key("dialog").role(role).label("Review")
                let view: El<Int> = col().key("root").child(modal ? dialog.modal() : dialog)
                for root in try projections(view, state: 0) {
                    let node = try #require(root.children.first)
                    #expect(node.role == role)
                    #expect(node.isModal == modal)
                    #if os(macOS)
                    let native = RuneNSAccessibilityElement(node: node, parent: nil, onAction: nil)
                    #expect(native.accessibilityRole() == .window)
                    #expect(native.accessibilitySubrole() == .dialog)
                    #expect(native.isAccessibilityModal() == modal)
                    #elseif canImport(UIKit) && !os(watchOS)
                    let native = RuneUIAccessibilityElement(node: node, container: UIView(), onAction: nil)
                    #expect(native.accessibilityViewIsModal == modal)
                    #endif
                }
            }
        }
    }

    @Test func modalBackgroundIsOmittedAndModalAncestorsKeepTheirRole() throws {
        let view: El<Int> = col().key("root").children([
            col().key("background").child(text("Unavailable").key("background-child")),
            col().key("holder").children([
                text("Sibling").key("sibling"),
                col().key("dialog").modal().labelledBy("background-child").child(text("Ready").key("content"))
            ])
        ])
        for root in try projections(view, state: 0) {
            #expect(!root.isDisabled)
            try #require(root.children.map(\.id) == ["holder"])
            let holder = root.children[0]
            #expect(!holder.isDisabled)
            try #require(holder.children.map(\.id) == ["dialog"])
            #expect(holder.children[0].role == .dialog)
            #expect(holder.children[0].label == "Unavailable")
            #expect(holder.children[0].children.map(\.id) == ["content"])
        }
    }

    @Test func rootWrapperKeepsEveryPeerAndEditorsKeepTheirRole() throws {
        struct State { var value = TextEdit("value") }
        let view: El<State> = col().key("wrapper").role(.presentation).children([
            text("Account").key("caption"),
            textInput(key: "editor", \.value).singleLine().role(.presentation)
        ])
        for root in try projections(view, state: State()) {
            #expect(root.role == .group)
            #expect(root.children.map(\.id) == ["caption", "editor"])
            #expect(root.children.last?.role == .textInput)
            #expect(root.children.last?.value == "value")
        }
    }

    @Test func editorInsidePresentationUsesItsBoundLineMode() throws {
        struct Form { var edit: TextEdit }
        let field = textInput(key: "editor", \Form.edit).role(.presentation)
        for (element, model, role) in [
            (field, TextEdit(), ElementRole.multilineTextInput),
            (field.singleLine(), TextEdit("text", multiline: true), .textInput),
            (field, TextEdit("text", multiline: false), .textInput)
        ] {
            for tree in try projections(col().key("root").child(element), state: Form(edit: model)) {
                #expect(tree.children.first?.role == role)
            }
        }
    }

    @Test func browserProjectionKeepsTargetsInsidePresentationalWrapper() throws {
        let view = wrapperView()
        let spec = AppSpec<Int>(title: "Landmarks", size: viewport, state: 0) { _, _ in view }
        let session = WebBrowserSession(WebAppHost(spec: spec))
        _ = try session.renderFrame(at: 0)
        let packet = try #require(session.takeAccessibility())
        let document = try #require(JSONSerialization.jsonObject(with: packet) as? [String: Any])
        let root = try #require(document["root"] as? [String: Any])
        let children = try #require(root["children"] as? [[String: Any]])
        try #require(children.compactMap { $0["key"] as? String } == ["first", "second", "inert", "after"])
        #expect((children[1]["path"] as? String)?.hasSuffix("/@wrapper/@nested/@second") == true)
    }

    @Test func tableCellsAndHeadersKeepTheirRolesAndNames() throws {
        let roles: [ElementRole] = [.cell, .gridCell, .rowHeader, .columnHeader]
        let view: El<Int> = row().key("row").role(.row).children(roles.map { role in
            el().key(role.rawValue).role(role).child(text("Title"))
        })
        for root in try projections(view, state: 0) {
            #expect(root.children.map(\.role) == roles)
            #expect(root.children.map(\.label) == Array(repeating: "Title", count: roles.count))
        }
        #if os(macOS)
        #expect(roles.allSatisfy { AppKitAccessibilityMapper.nsRole(for: $0) == .cell })
        #endif
    }

    @Test func treeGridKeepsAuthoredRowsAndName() throws {
        let view: El<Int> = col().key("files").role(.treeGrid).label("Files").child(
            row().key("folder").role(.row).child(text("Projects").key("name").role(.gridCell))
        )
        for root in try projections(view, state: 0) {
            #expect(root.role.rawValue == "treegrid")
            #expect(root.label == "Files")
            let row = try #require(root.children.first)
            #expect(row.role == .row)
            #expect(row.children.first?.role == .gridCell)
            #if os(macOS)
            let native = RuneNSAccessibilityElement(node: root, parent: nil, onAction: nil)
            #expect(native.accessibilityRole() == .table)
            #endif
        }
    }

    @Test func landmarksExposeTheirStandardNames() throws {
        let roles: [ElementRole] = [.main, .navigation, .banner, .complementary, .contentInfo, .form, .search, .region]
        let names = ["main", "navigation", "banner", "complementary", "contentinfo", "form", "search", "region"]
        let view: El<Int> = col().key("root").children(roles.map { el().key($0.rawValue).role($0).label($0.rawValue) })
        for root in try projections(view, state: 0) {
            #expect(root.children.map(\.role.rawValue) == names)
        }
        #if os(macOS)
        let inert = RuneNSAccessibilityElement(node: AccessibilityNode(id: "inert", role: .button, isDisabled: true),
                                               parent: nil, onAction: nil)
        #expect(!inert.isAccessibilityEnabled())
        inert.update(node: AccessibilityNode(id: "inert", role: .button), parent: nil, onAction: nil, onSetValue: nil)
        #expect(inert.isAccessibilityEnabled())
        let subroles = ["Main", "Navigation", "Banner", "Complementary", "ContentInfo", "Form", "Search", "Region"]
        for (role, subrole) in zip(roles, subroles) {
            let node = AccessibilityNode(id: "landmark", role: role)
            let native = RuneNSAccessibilityElement(node: node, parent: nil, onAction: nil)
            #expect(native.accessibilityRole() == .group)
            #expect(native.accessibilitySubrole()?.rawValue == "AXLandmark" + subrole)
            native.update(node: AccessibilityNode(id: "landmark", role: .button), parent: nil, onAction: nil, onSetValue: nil)
            #expect(native.accessibilitySubrole() == nil)
        }
        #endif
    }
}
