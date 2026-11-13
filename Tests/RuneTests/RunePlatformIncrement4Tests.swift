import Foundation
import Testing
import RuneMotion
import RuneRef
@testable import Rune

#if os(macOS)
import AppKit
#endif

@Suite("Platform Increment 4 Parity — Drop, DragOut, PopupMenu, FileDialog")
struct RunePlatformIncrement4Tests {

    // MARK: - 1. Per-Element File Drop & AppSpec Hook (`drop_tests.rs`)

    struct DropState {
        var showZone = true
        var showModal = false
        var dropped: [URL] = []
        var rejected: [URL] = []
        var outerDropped: [URL] = []
        var appDropped: [URL] = []
        var hoverEvents: [Bool] = []
        var rejectedHoverEvents: [Bool] = []
        var movePoints: [Vec2] = []
        var pointerHoverEvents: [Bool] = []
        var secondaryClicks = 0
    }

    @Test("Innermost drop zone wins, splits extensions case-insensitively, and leaves pointer hover/right-click intact")
    func innermostDropZoneAndExtensionSplit() {
        let rt = Runtime<DropState>(
            state: DropState(),
            viewport: Vec2(300, 200),
            view: { _, _ in
                el()
                    .w(300)
                    .h(200)
                    .child(
                        el()
                            .key("outer")
                            .w(200)
                            .h(120)
                            .onDropFiles { s, urls, _ in s.outerDropped.append(contentsOf: urls) }
                            .child(
                                el()
                                    .key("inner")
                                    .w(120)
                                    .h(80)
                                    .acceptsExtensions(["PNG", ".jpg"])
                                    .onDropFiles { s, urls, _ in s.dropped.append(contentsOf: urls) }
                                    .onDropRejected { s, urls, _ in s.rejected.append(contentsOf: urls) }
                                    .onDropHover { s, inside, _ in s.hoverEvents.append(inside) }
                                    .onDropRejectedHover { s, inside, _ in s.rejectedHoverEvents.append(inside) }
                                    .onHover { s, inside, _ in s.pointerHoverEvents.append(inside) }
                                    .onSecondaryClick { s, _, _ in s.secondaryClicks += 1 }
                            )
                    )
            }
        )
        _ = rt.frame(at: 0.0)

        let png = URL(fileURLWithPath: "/tmp/pic.PnG")
        let txt = URL(fileURLWithPath: "/tmp/note.txt")

        // Hover rejected only
        rt.dragFiles([txt], at: Vec2(20, 20), at: 0.1)
        #expect(rt.dropRejectedHovered == true)
        #expect(rt.dropHoveredAccepted == false)
        #expect(rt.state.rejectedHoverEvents == [true])

        // Move outside to leave rejected hover
        rt.dragFilesTo(Vec2(250, 180), at: 0.2)
        #expect(rt.state.rejectedHoverEvents == [true, false])
        #expect(rt.dropHovered == nil)

        // Hover mixed files -> accepted hover wins
        rt.dragFiles([png, txt], at: Vec2(20, 20), at: 0.3)
        #expect(rt.dropHoveredAccepted == true)
        #expect(rt.state.hoverEvents == [true])

        // Pointer hover and right click still reach element despite drop handlers
        rt.pointerMove(to: Vec2(20, 20), at: 0.35)
        rt.pointerDown(at: Vec2(20, 20), button: .secondary, at: 0.36)
        #expect(rt.state.pointerHoverEvents == [true])
        #expect(rt.state.secondaryClicks == 1)

        // Drop splits accepted & rejected cleanly and does not leak to outer
        rt.dropFiles([png, txt], at: Vec2(20, 20), at: 0.4)
        #expect(rt.state.dropped == [png])
        #expect(rt.state.rejected == [txt])
        #expect(rt.state.outerDropped.isEmpty)
        #expect(rt.state.hoverEvents == [true, false])
    }

    @Test("onDropMove coalesces once per frame with tx.dropPoint and unmount/modal/holdFiles end hover")
    func dropMoveCoalescingModalUnmountAndHold() {
        let rt = Runtime<DropState>(
            state: DropState(),
            viewport: Vec2(300, 200),
            view: { state, _ in
                var kids: [El<DropState>] = []
                if state.showZone {
                    kids.append(
                        el()
                            .key("zone")
                            .absolute(x: 0, y: 0)
                            .w(200)
                            .h(100)
                            .onDropHover { s, inside, _ in s.hoverEvents.append(inside) }
                            .onDropMove { s, _, tx in
                                if let pt = tx.dropPoint {
                                    s.movePoints.append(pt.local)
                                }
                            }
                            .onDropFiles { s, urls, _ in s.dropped.append(contentsOf: urls) }
                    )
                }
                if state.showModal {
                    kids.append(
                        el()
                            .key("modal")
                            .absolute(x: 0, y: 0)
                            .w(100)
                            .h(100)
                            .modal()
                    )
                }
                return el().w(300).h(200).children(kids)
            }
        )
        _ = rt.frame(at: 0.0)

        let f = URL(fileURLWithPath: "/tmp/a.txt")
        rt.dragFiles([f], at: Vec2(10, 10), at: 0.01)
        rt.dragFilesTo(Vec2(25, 30), at: 0.02)
        rt.dragFilesTo(Vec2(60, 40), at: 0.03)
        // Multiple moves before frame coalesce to the last coordinate
        _ = rt.frame(at: 0.04)
        #expect(rt.state.movePoints == [Vec2(60, 40)])

        // Covered-window holdFiles ends hover, releaseFiles restores it
        rt.holdFiles(at: 0.05)
        #expect(rt.state.hoverEvents == [true, false])
        #expect(rt.dropHovered == nil)
        rt.releaseFiles(at: 0.06)
        #expect(rt.state.hoverEvents == [true, false, true])

        // Unmounting hovered drop zone ends hover cleanly on commit
        rt.update(at: 0.07) { s, _ in s.showZone = false }
        _ = rt.frame(at: 0.08)
        #expect(rt.state.hoverEvents == [true, false, true, false])

        // Re-mount + modal isolation blocks drops on inert background zone
        rt.update(at: 0.09) { s, _ in
            s.showZone = true
            s.showModal = true
        }
        _ = rt.frame(at: 0.10)
        let accepted = rt.dropFiles([f], at: Vec2(10, 10), at: 0.11)
        #expect(accepted == false)
        #expect(rt.state.dropped.isEmpty)
    }

    @Test("AppSpec.onFileDrop fires when dropping outside per-element drop targets")
    func appSpecOnFileDropFallback() throws {
        var dropped: [URL] = []
        let spec = AppSpec<DropState>(
            size: Vec2(200, 100),
            state: DropState(),
            view: { _, _ in el().w(200).h(100) }
        ).onFileDrop { state, urls, _ in
            state.appDropped.append(contentsOf: urls)
            dropped.append(contentsOf: urls)
        }
        let rt = Runtime<DropState>(state: spec.makeState(), viewport: spec.size, view: spec.view)
        rt.onAppFileDrop = spec.onFileDrop
        _ = rt.frame(at: 0.0)
        let file = URL(fileURLWithPath: "/tmp/doc.md")
        rt.fileDrop(.dropped([DroppedFile(url: file)], at: Vec2(50, 50)), at: 0.1)
        #expect(rt.state.appDropped == [file])
        #expect(dropped == [file])
    }

    // MARK: - 2. Popup Menu Queue (`popup_menu/tests.rs`)

    struct PopupTestState {
        var theme = "system"
        var extra = false
        var picks: [String?] = []
        var hovers: [Bool] = []
        var anchorOverride: PopupAnchor? = nil
    }

    private func themeMenu(_ selected: String) -> PopupMenu {
        PopupMenu.picker([("system", "System"), ("light", "Light"), ("dark", "Dark")], selected: selected)
    }

    @Test("Popup menu picker anchor, validation, submenu selection, and --tree JSON")
    func popupMenuPickerValidationAndTreeJSON() throws {
        let rt = Runtime<PopupTestState>(
            state: PopupTestState(),
            viewport: Vec2(200, 100),
            view: { _, _ in
                el()
                    .w(200)
                    .h(100)
                    .child(
                        el()
                            .key("theme")
                            .absolute(x: 40, y: 30)
                            .w(80)
                            .h(24)
                            .onHover { s, inside, _ in s.hovers.append(inside) }
                            .onClick { (s: inout PopupTestState, tx: inout Tx) in
                                let anchor = s.anchorOverride ?? .key("theme")
                                tx.popupMenu(
                                    PopupMenu.picker([("system", "System"), ("light", "Light"), ("dark", "Dark")], selected: s.theme),
                                    at: anchor
                                ) { (st: inout PopupTestState, picked, _) in
                                    st.picks.append(picked)
                                    if let p = picked { st.theme = p }
                                }
                            }
                    )
            }
        )
        _ = rt.frame(at: 0.0)

        // Missing tree key initially
        #expect(rt.treeJSON()["popupMenu"] == nil)

        // Click theme button to enqueue menu
        rt.pointerDown(at: Vec2(50, 35), at: 0.1)
        rt.pointerUp(at: Vec2(50, 35), at: 0.11)
        _ = rt.frame(at: 0.12)

        guard case .success(let show) = rt.takePopup() else {
            Issue.record("expected PopupShow")
            return
        }
        let place = show.placement()
        #expect(place.positionedId == "system")
        #expect(place.at == Vec2(40, 30))
        #expect(place.minWidth == 80)
        #expect(rt.takePopup() == nil, "only one open menu at a time")

        try rt.resolvePopup("dark")
        #expect(rt.state.picks == ["dark"])
        #expect(rt.state.theme == "dark")
        #expect(rt.popupMenu == nil)

        // Submenu validation, disabled rejection, unknown item error
        let ctxMenu = PopupMenu()
            .item("copy", "Copy", checked: true, keyEquivalent: "super+c", symbolName: "doc.on.doc")
            .item("paste", "Paste", enabled: false)
            .separator()
            .submenu("More", PopupMenu().item("share", "Share"))
        rt.update(at: 0.2) { _, tx in
            tx.popupMenu(ctxMenu, at: Vec2(3, 4)) { (s: inout PopupTestState, picked, _) in
                s.picks.append(picked)
            }
            tx.popupMenu(PopupMenu.picker([("light", "Light")], selected: "light"), at: "theme") { (s: inout PopupTestState, picked, _) in
                s.picks.append(picked)
            }
        }
        _ = rt.frame(at: 0.21)
        let shownCtx = rt.openPopupHeadless()
        #expect(shownCtx != nil)
        let tree = rt.treeJSON()
        let pm = tree["popupMenu"] as? [String: Any]
        let isOpen = pm?["open"] as? Bool
        let queuedCount = pm?["queued"] as? Int
        let anchorDict = pm?["anchor"] as? [String: Any]
        let anchorX = anchorDict?["x"] as? Float
        let anchorY = anchorDict?["y"] as? Float
        #expect(isOpen == true)
        #expect(queuedCount == 1)
        #expect(anchorX == 3.0)
        #expect(anchorY == 4.0)

        #expect(throws: PopupMenuError.disabled("paste")) {
            try rt.resolvePopup("paste")
        }
        #expect(throws: PopupMenuError.unknownItem("missing")) {
            try rt.resolvePopup("missing")
        }
        #expect(rt.popupIsOpen == true)
        try rt.resolvePopup("share")
        #expect(rt.state.picks.last == "share")
        #expect(rt.popupIsOpen == false, "next queued menu waits to open")
        _ = rt.openPopupHeadless()
        try rt.resolvePopup(nil)
        #expect(throws: PopupMenuError.notOpen) {
            try rt.resolvePopup(nil)
        }
    }

    @Test("Invalid/missing-anchor popups answer nil, layout waits for new elements, hover ends, cancelPopups bounded at 64")
    func popupInvalidAnchorWaitHoverAndCancelBound() throws {
        let rt = Runtime<PopupTestState>(
            state: PopupTestState(),
            viewport: Vec2(200, 100),
            view: { state, _ in
                var items: [El<PopupTestState>] = [
                    el()
                        .key("theme")
                        .w(80)
                        .h(24)
                        .onHover { s, inside, _ in s.hovers.append(inside) },
                ]
                if state.extra {
                    items.append(el().key("extra").w(30).h(20))
                }
                return row().w(200).h(100).children(items)
            }
        )
        _ = rt.frame(at: 0.0)

        // Hover theme then open popup -> hover leaves on frame
        rt.pointerMove(to: Vec2(10, 10), at: 0.05)
        _ = rt.frame(at: 0.06)

        rt.update(at: 0.07) { _, tx in
            tx.popupMenu(themeMenu("system"), at: "missing") { (s: inout PopupTestState, p, _) in s.picks.append(p) }
            tx.popupMenu(PopupMenu().item("a", "A").item("a", "B"), at: "theme") { (s: inout PopupTestState, p, _) in s.picks.append(p) }
            tx.popupMenu(PopupMenu().item("", "Blank"), at: "theme") { (s: inout PopupTestState, p, _) in s.picks.append(p) }
            tx.popupMenu(themeMenu("light"), at: "theme") { (s: inout PopupTestState, p, tx2) in
                s.picks.append(p)
                s.extra = true
                tx2.popupMenu(PopupMenu().item("x", "X"), at: "extra") { (s2: inout PopupTestState, p2, _) in
                    s2.picks.append(p2)
                }
            }
        }
        _ = rt.frame(at: 0.08)
        let valid = rt.openPopupHeadless()
        #expect(valid != nil)
        #expect(rt.state.picks == [nil, nil, nil])
        _ = rt.frame(at: 0.09)
        #expect(rt.state.hovers == [true, false])

        // Resolve valid -> mounts "extra" and requests queued popup on "extra", waiting for layout
        try rt.resolvePopup("light")
        #expect(rt.popupWaitsForLayout == true)
        #expect(rt.takePopup() == nil)
        _ = rt.frame(at: 0.10)
        #expect(rt.popupWaitsForLayout == false)
        let extraShow = rt.openPopupHeadless()
        #expect(extraShow?.placement().minWidth == 30)
        try rt.resolvePopup("x")

        // Infinite re-ask loop stops at 64 in cancelPopups()
        func endlesslyReask(_ s: inout PopupTestState, _ picked: String?, _ tx: inout Tx) {
            s.picks.append(picked)
            tx.popupMenu(PopupMenu().item("loop", "Loop"), at: "theme", endlesslyReask)
        }
        rt.update(at: 0.2) { _, tx in
            tx.popupMenu(PopupMenu().item("loop", "Loop"), at: "theme", endlesslyReask)
        }
        _ = rt.frame(at: 0.21)
        rt.cancelPopups()
        #expect(rt.popupMenu == nil)

        // PopupSession single resolution
        var resolved: [String?] = []
        let session = PopupSession { resolved.append($0) }
        #expect(session.resolve("one") == true)
        #expect(session.resolve("two") == false)
        session.cancel()
        #expect(resolved == ["one"])
    }

    // MARK: - 3. Async File Dialog (`file_dialog.rs`)

    struct DialogState {
        var answers: [Result<URL?, FileDialogError>] = []
    }

    @Test("File dialog lifecycle: open/folder/save, tree JSON, busy & overlay refusal, stale ID, bounded cancel")
    func fileDialogStateMachine() throws {
        let rt = Runtime<DialogState>(
            state: DialogState(),
            viewport: Vec2(200, 100),
            view: { _, _ in el().w(200).h(100) }
        )
        _ = rt.frame(at: 0.0)

        let openOpts = FileDialogOptions(title: "Import", directory: URL(fileURLWithPath: "/work"))
            .filter("Export", extensions: ["json"])
        rt.update(at: 0.1) { _, tx in
            tx.openFile(openOpts) { (s: inout DialogState, res, _) in s.answers.append(res) }
            tx.saveFile(FileDialogOptions()) { (s: inout DialogState, res, _) in s.answers.append(res) }
        }
        _ = rt.frame(at: 0.11)
        // Second simultaneous request was refused on frame while first remained pending
        #expect(rt.state.answers == [.failure(FileDialogError("a file dialog is already open"))])
        let pending = rt.takeFileDialog()
        #expect(pending?.kind == .open)
        #expect(rt.takeFileDialog() == nil, "already showing; not taken twice")

        let treeFD = rt.treeJSON()["fileDialog"] as? [String: Any]
        let fdKind = treeFD?["kind"] as? String
        let fdTitle = treeFD?["title"] as? String
        let fdDir = treeFD?["directory"] as? String
        #expect(fdKind == "open")
        #expect(fdTitle == "Import")
        #expect(fdDir == "/work")

        // Stale ID ignored
        rt.answerFileDialog(999_999, .success(URL(fileURLWithPath: "/tmp/wrong.json")))
        #expect(rt.fileDialog != nil)

        // Real answer arrives on next frame
        let chosen = URL(fileURLWithPath: "/exports/out.json")
        rt.answerFileDialog(pending!.id, .success(chosen))
        #expect(rt.fileDialog == nil)
        #expect(rt.state.answers.count == 1)
        _ = rt.frame(at: 0.12)
        #expect(rt.state.answers.last == .success(chosen))

        // Folder + cancel
        rt.update(at: 0.2) { _, tx in
            tx.openFolder(FileDialogOptions(title: "Project")) { (s: inout DialogState, res, _) in
                s.answers.append(res)
            }
        }
        _ = rt.frame(at: 0.21)
        #expect(rt.fileDialog?.kind == .folder)
        rt.cancelFileDialogs(at: 0.22)
        #expect(rt.state.answers.last == .success(nil))
        #expect(rt.fileDialog == nil)

        // Overlay refuses file dialogs immediately
        rt.nativeOverlay = true
        rt.update(at: 0.3) { _, tx in
            tx.openFile { (s: inout DialogState, res, _) in s.answers.append(res) }
        }
        _ = rt.frame(at: 0.31)
        #expect(rt.state.answers.last == .failure(FileDialogError("overlays cannot open file dialogs")))
    }

    // MARK: - 4. Outbound Drag-Out, DragImage, & Drop Naming (`drag_out/mod.rs`, `drag_out/macos.rs`)

    struct DragOutTestState {
        var events: [String] = []
        var hovered: [Bool] = []
        var showSource = true
    }

    @Test("DragImage linear sRGB compositing, frame placement, DragItem & MacOSDragOutLogic")
    func dragImageAndMacOSDragOutLogic() throws {
        // Semi-transparent pure red over opaque black -> straight sRGB composited alpha 255
        let srcRGBA = Data([255, 0, 0, 128])
        let img = try #require(DragImage.rgba(width: 1, height: 1, pixels: srcRGBA))
        let overBlack = try #require(img.over(.black))
        let png = try #require(overBlack.resolvedPNGData())
        let decoded = try PortablePNG.decode(png)
        #expect(decoded.width == 1 && decoded.height == 1)
        #expect(decoded.rgba[3] == 255)
        #expect(decoded.rgba[0] > 150 && decoded.rgba[1] == 0 && decoded.rgba[2] == 0)

        let bounds = MotionRect.fromXYWH(100, 50, 80, 40)
        #expect(img.size(20, 10).frame(bounds: bounds, press: Vec2(120, 70), natural: Vec2(4, 4)) == .fromXYWH(110, 65, 20, 10))
        #expect(img.overElement().frame(bounds: bounds, press: Vec2(120, 70), natural: Vec2(4, 4)) == bounds)
        #expect(img.size(30, 12).at(Vec2(9, 8)).frame(bounds: bounds, press: .zero, natural: .zero) == .fromXYWH(9, 8, 30, 12))

        let copyOnly = DragItem().file(path: "/tmp/a.txt").opaque(.white)
        #expect(MacOSDragOutLogic.dragOperationMask(for: copyOnly) == MacOSDragOutLogic.nsCopyMask)
        #expect(MacOSDragOutLogic.ignoreModifierKeys(for: copyOnly) == true)

        let copyOrMove = copyOnly.allowMove().withinApp()
        #expect(MacOSDragOutLogic.dragOperationMask(for: copyOrMove) == (MacOSDragOutLogic.nsCopyMask | MacOSDragOutLogic.nsMoveMask))
        #expect(MacOSDragOutLogic.ignoreModifierKeys(for: copyOrMove) == false)
        #expect(copyOrMove.dropsWithinApp == true)
        #expect(MacOSDragOutLogic.outcome(from: MacOSDragOutLogic.nsMoveMask) == .moved)
        #expect(MacOSDragOutLogic.outcome(from: 0) == .cancelled)
        #expect(MacOSDragOutLogic.stackOffset(index: 10) == Vec2(12, 12))

        // DropTempNaming helpers
        #expect(DropTempNaming.freeName(stem: "Photo", ext: "png", existing: ["Photo.png", "Photo-2.png"]) == "Photo-3.png")
        #expect(DropTempNaming.hoverStandInURL(prefix: "Image", extension: "jpg").lastPathComponent == "Image.jpg")
        let tiffExt = DropTempNaming.imageExtension(forUTI: "public.tiff")
        #expect(tiffExt?.ext == "png" && tiffExt?.needsPNGConversion == true)
    }

    @Test("Runtime dragOut threshold arming, onDragStart + onDragOutEnd 1:1 pairing across unmount")
    func runtimeDragOutArmingAndPairing() {
        let rt = Runtime<DragOutTestState>(
            state: DragOutTestState(),
            viewport: Vec2(200, 100),
            view: { state, _ in
                if !state.showSource {
                    return el().w(200).h(100)
                }
                return el()
                    .key("card")
                    .w(80)
                    .h(40)
                    .dragThreshold(6)
                    .onHover { s, inside, _ in s.hovered.append(inside) }
                    .dragOut { _ in DragItem().file(path: "/tmp/card.pdf").allowMove() }
                    .onDragStart { s, _ in s.events.append("start") }
                    .onDragOutEnd { s, outcome, _ in s.events.append("end:\(outcome)") }
            }
        )
        _ = rt.frame(at: 0.0)

        rt.pointerMove(to: Vec2(20, 20), at: 0.05)
        rt.pointerDown(at: Vec2(20, 20), at: 0.06)
        // Within 6pt threshold -> does not start drag-out
        rt.pointerMove(to: Vec2(23, 22), at: 0.07)
        #expect(rt.takeDragOutStart() == nil)
        #expect(rt.state.events.isEmpty)

        // Past 6pt threshold -> starts drag-out, fires onDragStart, releases hover
        rt.pointerMove(to: Vec2(30, 20), at: 0.08)
        let started = rt.takeDragOutStart()
        #expect(started?.item.files.first?.path == "/tmp/card.pdf")
        #expect(started?.key == "card")
        #expect(rt.isDraggingOut == true)
        #expect(rt.state.events == ["start"])
        #expect(rt.state.hovered == [true, false])

        // Even if the source element unmounts before the OS drag ends, onDragOutEnd still fires 1:1
        rt.update(at: 0.09) { s, _ in s.showSource = false }
        _ = rt.frame(at: 0.10)
        rt.finishDragOut(.moved, at: 0.11)
        #expect(rt.isDraggingOut == false)
        #expect(rt.state.events == ["start", "end:moved"])
    }

    #if os(macOS)
    @Test("macOS drop pasteboard types, popup NSMenu tags/symbols, and host presenters construct")
    @MainActor
    func macOSDropAndPopupHostSmoke() {
        let types = MacOSDropReader.draggedTypes
        #expect(types.contains(.fileURL))
        #expect(types.contains(.png))
        #expect(types.contains(.tiff))

        let menu = PopupMenu()
            .item("a", "Alpha", checked: true, symbolName: "star")
            .separator()
            .submenu("Sub", PopupMenu().item("b", "Beta", enabled: false))
        let nsMenu = menu.buildNSMenu()
        #expect(nsMenu.items.count == 3)
        #expect(nsMenu.items[0].state == .on)
        #expect(nsMenu.items[2].submenu?.items.first?.isEnabled == false)

        let popupPresenter = MacOSPopupMenuPresenter()
        let fileDialogPresenter = MacOSFileDialogPresenter()
        let dragOutCoordinator = MacOSDragOutCoordinator()
        #expect(!popupPresenter.isPresenting)
        #expect(!fileDialogPresenter.isPresenting)
        _ = dragOutCoordinator
    }

    @Test("MacOSDragOutLogic outcome handles Copy/Move/Delete/Generic/Link precedence and withinApp mask")
    func macOSDragOutOutcomePrecedenceAndWithinAppMask() {
        #expect(MacOSDragOutLogic.outcome(from: 0, ended: true) == .cancelled)
        #expect(MacOSDragOutLogic.outcome(from: MacOSDragOutLogic.nsCopyMask, ended: false) == .cancelled)
        #expect(MacOSDragOutLogic.outcome(from: MacOSDragOutLogic.nsCopyMask, ended: true) == .copied)
        #expect(MacOSDragOutLogic.outcome(from: MacOSDragOutLogic.nsMoveMask, ended: true) == .moved)
        #expect(MacOSDragOutLogic.outcome(from: MacOSDragOutLogic.nsDeleteMask, ended: true) == .moved)
        #expect(MacOSDragOutLogic.outcome(from: MacOSDragOutLogic.nsGenericMask, ended: true) == .moved)
        #expect(MacOSDragOutLogic.outcome(from: MacOSDragOutLogic.nsLinkMask, ended: true) == .linked)

        // Precedence: Copy beats Move|Delete|Generic|Link; Move|Delete|Generic beats Link.
        let allOps = MacOSDragOutLogic.nsCopyMask
            | MacOSDragOutLogic.nsMoveMask
            | MacOSDragOutLogic.nsDeleteMask
            | MacOSDragOutLogic.nsGenericMask
            | MacOSDragOutLogic.nsLinkMask
        #expect(MacOSDragOutLogic.outcome(from: allOps, ended: true) == .copied)
        #expect(MacOSDragOutLogic.outcome(from: MacOSDragOutLogic.nsGenericMask | MacOSDragOutLogic.nsLinkMask, ended: true) == .moved)
        #expect(MacOSDragOutLogic.outcome(from: MacOSDragOutLogic.nsDeleteMask | MacOSDragOutLogic.nsLinkMask, ended: true) == .moved)

        // dropsWithinApp == false returns 0 inside app and preserves mask outside app.
        let mask = MacOSDragOutLogic.nsCopyMask | MacOSDragOutLogic.nsMoveMask
        #expect(MacOSDragOutLogic.operationMask(for: mask, withinApplication: true, dropsWithinApp: false) == 0)
        #expect(MacOSDragOutLogic.operationMask(for: mask, withinApplication: false, dropsWithinApp: false) == mask)
        #expect(MacOSDragOutLogic.operationMask(for: mask, withinApplication: true, dropsWithinApp: true) == mask)
    }
    #endif

    @Test("Drop pass-through skips inner target that accepts zero URLs without reject handlers")
    func dropPassThroughToOuterTarget() {
        let rt = Runtime<DropState>(
            state: DropState(),
            viewport: Vec2(300, 200),
            view: { _, _ in
                el()
                    .key("outer")
                    .w(200)
                    .h(120)
                    .acceptsExtensions(["txt"])
                    .onDropFiles { s, urls, _ in s.outerDropped.append(contentsOf: urls) }
                    .child(
                        el()
                            .key("inner")
                            .w(120)
                            .h(80)
                            .acceptsExtensions(["png"])
                            .onDropFiles { s, urls, _ in s.dropped.append(contentsOf: urls) }
                    )
            }
        )
        _ = rt.frame(at: 0.0)

        let txt = URL(fileURLWithPath: "/tmp/readme.txt")
        let png = URL(fileURLWithPath: "/tmp/icon.png")

        // Inner accepts .png only and claims NO reject handlers, so .txt passes through to outer.
        #expect(rt.acceptsDrop([txt], at: Vec2(20, 20)) == true)
        rt.dragFiles([txt], at: Vec2(20, 20), at: 0.1)
        #expect(rt.dropHovered == "outer")
        #expect(rt.dropHoveredAccepted == true)
        rt.dropFiles([txt], at: Vec2(20, 20), at: 0.2)
        #expect(rt.state.outerDropped == [txt])
        #expect(rt.state.dropped.isEmpty)

        // .png matches inner directly.
        rt.dropFiles([png], at: Vec2(20, 20), at: 0.3)
        #expect(rt.state.dropped == [png])
    }
}
