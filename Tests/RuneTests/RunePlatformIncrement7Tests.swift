import Foundation
import Testing
@testable import Rune

#if os(macOS) && canImport(AppKit)
import AppKit
import CoreGraphics
import Metal
#endif

@Suite("Platform Increment 7: MacOS Bridges, Cursor, IME, KeyMap, Popup & Tray Parity")
struct RunePlatformIncrement7Tests {

    @Test("Runtime currentCursor resolves inheritance, textInput/editLens, links, pressed hold, and viewport bounds")
    @MainActor
    func runtimeCurrentCursorResolution() {
        struct S {
            var edit = TextEdit("hello")
        }
        let rt = Runtime(state: S(), viewport: Vec2(400, 300)) { _, _ in
            El<S>(direction: .column)
                .cursor(.grab)
                .child(
                    el().w(100).h(40).key("inherited")
                )
                .child(
                    el().w(100).h(40).cursor(.pointer).onClick { _, _ in }.key("explicit")
                )
                .child(
                    El<S>().w(100).h(40).role(.textInput).key("input")
                )
                .child(
                    el().w(100).h(40).href("https://example.com").key("lnk")
                )
        }
        _ = rt.frame(at: 0.0)

        // Outside viewport -> default
        rt.pointerMove(to: Vec2(-5, 10), mods: .none, at: 0.01)
        #expect(rt.currentCursor() == .default)

        // Inherited from ancestor (.grab)
        if let p = rt.find("inherited") {
            rt.pointerMove(to: p, mods: .none, at: 0.02)
            #expect(rt.currentCursor() == .grab)
        }

        // Explicit child override (.pointer)
        if let p = rt.find("explicit") {
            rt.pointerMove(to: p, mods: .none, at: 0.03)
            #expect(rt.currentCursor() == .pointer)
        }

        // Text input -> .text
        if let p = rt.find("input") {
            rt.pointerMove(to: p, mods: .none, at: 0.04)
            #expect(rt.currentCursor() == .text)
        }

        // Link -> .pointer
        if let p = rt.find("lnk") {
            rt.pointerMove(to: p, mods: .none, at: 0.05)
            #expect(rt.currentCursor() == .pointer)
        }

        // Pressed element holds cursor while moving across other targets
        if let explicitPos = rt.find("explicit"), let inputPos = rt.find("input") {
            rt.pointerDown(at: explicitPos, button: .primary, mods: .none, at: 0.06)
            rt.pointerMove(to: inputPos, mods: .none, at: 0.07)
            #expect(rt.currentCursor() == .pointer)
            rt.pointerUp(at: inputPos, button: .primary, mods: .none, at: 0.08)
        }
    }

    @Test("Runtime IME wiring updates focused TextEdit, fires onIme/onTextChange, protects secure fields, and finishes composition on blur")
    @MainActor
    func runtimeImeWiringAndFinishComposition() {
        struct S {
            var edit = TextEdit("hi ")
            var secret = TextEdit("pass")
            var changes: [String] = []
            var imeEvents: [Ime] = []
        }
        let rt = Runtime(state: S(), viewport: Vec2(400, 300)) { _, _ in
            El<S>(direction: .column)
                .child(
                    textInput(key: "field", \S.edit)
                        .w(200)
                        .h(40)
                        .onChange { st, newVal, _ in
                            st.changes.append(newVal)
                        }
                )
                .child(
                    textInput(key: "secret", \S.secret)
                        .w(200)
                        .h(40)
                        .secure()
                )
        }
        rt.onIme = { (st: inout S, ime: Ime, _: inout Tx) -> Bool in
            st.imeEvents.append(ime)
            return true
        }
        _ = rt.frame(at: 0.0)

        // Focus regular field
        if let p = rt.find("field") {
            rt.pointerDown(at: p, button: .primary, mods: .none, at: 0.01)
            rt.pointerUp(at: p, button: .primary, mods: .none, at: 0.02)
        }
        _ = rt.frame(at: 0.03)
        #expect(rt.hasFocusedTextInput == true)
        #expect(rt.hasSecureFocus == false)
        #expect(rt.focusedImeSnapshot()?.text == "hi ")
        #expect(rt.focusedCaretRect() != nil)

        // Preedit + finishComposition on window blur commits marked text and sets imeReset
        #expect(rt.dispatchImeEvent(.preedit("せか", cursorUTF8: 0..<6, clauses: []), at: 0.04) == true)
        #expect(rt.state.edit.preedit?.text == "せか")
        rt.dispatchFocus(false, at: 0.05)
        #expect(rt.state.edit.preedit == nil)
        #expect(rt.state.edit.text.contains("せか"))
        #expect(rt.consumeImeReset() == true)
        #expect(rt.consumeImeReset() == false)
        #expect(!rt.state.changes.isEmpty)
        #expect(!rt.state.imeEvents.isEmpty)

        // Focus secure field -> snapshot suppressed & hasSecureFocus true
        rt.dispatchFocus(true, at: 0.06)
        if let p = rt.find("secret") {
            rt.pointerDown(at: p, button: .primary, mods: .none, at: 0.07)
            rt.pointerUp(at: p, button: .primary, mods: .none, at: 0.08)
        }
        _ = rt.frame(at: 0.09)
        #expect(rt.hasSecureFocus == true)
        #expect(rt.focusedImeSnapshot() == nil)
    }

    @Test("Runtime keyDown dispatches ShortcutRegistry when unhandled and blocks under modal")
    @MainActor
    func runtimeShortcutRegistryDispatch() {
        final class Hit: @unchecked Sendable { var count = 0 }
        struct S { var modal = false }
        let hit = Hit()
        let registry = ShortcutRegistry()
        _ = registry.register(id: "open.palette", accelerator: "cmd+p", scope: .global) {
            hit.count += 1
        }
        let rt = Runtime(state: S(), viewport: Vec2(200, 120)) { s, _ in
            El<S>().w(200).h(120).child(
                s.modal ? el().w(100).h(80).modal(true) : el().w(10).h(10)
            )
        }
        rt.shortcutRegistry = registry
        _ = rt.frame(at: 0.0)

        let handled = rt.keyDown(KeyEvent(key: .command("p"), mods: Mods(cmd: true, logo: true)), at: 0.1)
        #expect(handled == true)
        #expect(hit.count == 1)

        // Under active modal, global shortcuts are blocked
        rt.state.modal = true
        rt.markNeedsCommit()
        _ = rt.frame(at: 0.2)
        let underModal = rt.keyDown(KeyEvent(key: .command("p"), mods: Mods(cmd: true, logo: true)), at: 0.3)
        #expect(underModal == false)
        #expect(hit.count == 1)
    }

    @Test("PopupMenu selected positions only without setting checked, TrayIcon validates RGBA, and FileDialog error casing matches upstream")
    func popupTrayAndFileDialogParity() {
        let positioned = PopupMenu()
            .item("a", "Alpha")
            .item("b", "Beta")
            .selected("b")
        #expect(positioned.selectedId == "b")
        #expect(positioned.findItem(id: "b")?.checked == false)

        let picked = PopupMenu.picker([("a", "Alpha"), ("b", "Beta")], selected: "b")
        #expect(picked.selectedId == "b")
        #expect(picked.findItem(id: "b")?.checked == true)

        let badTray = TrayIcon(width: 2, height: 2, rgba: Data([0, 1, 2]))
        #expect(!badTray.isValid)
        #expect(throws: TrayError.self) {
            _ = try badTray.validated()
        }
        let goodTray = TrayIcon(width: 2, height: 2, rgba: Data(repeating: 255, count: 16))
        #expect(goodTray.isValid)

        let fd = FileDialog.scripted([
            ScriptedFileDialog(kind: .open, url: URL(fileURLWithPath: "/tmp/a.txt"))
        ])
        do {
            _ = try fd.runScripted(kind: .save)
            Issue.record("Expected FileDialog mismatch error")
        } catch let err as FileDialogError {
            #expect(err.message == "expected Open dialog, received Save")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    #if os(macOS) && canImport(AppKit)
    @Test("MacOSKeyMapper, MacOSDockIconApplier, MacOSCursorCache, and MacOSAccessibilityHost integrate cleanly")
    @MainActor
    func macOSBridgesIntegration() {
        _ = NSApplication.shared
        // Modifier flagsChanged mapping
        let shiftDown = MacOSKeyMapper.modifierKeyEvent(keyCode: 56, flags: [.shift])
        #expect(shiftDown?.event.key == .modifier(.shiftLeft, pressed: true))
        #expect(shiftDown?.mods.shift == true)

        let cmdUp = MacOSKeyMapper.modifierKeyEvent(keyCode: 55, flags: [])
        #expect(cmdUp?.event.key == .modifier(.superLeft, pressed: false))
        #expect(cmdUp?.mods.cmd == false)

        let fnDown = MacOSKeyMapper.modifierKeyEvent(keyCode: 63, flags: [.function])
        #expect(fnDown?.event.key == .modifier(.fn, pressed: true))

        // Valid RGBA8 AppIcon -> NSImage
        let icon = AppIcon(width: 2, height: 2, rgba: Data(repeating: 255, count: 16))!
        let nsImg = MacOSDockIconApplier.makeNSImage(from: icon)
        #expect(nsImg != nil)
        #expect(nsImg?.size == NSSize(width: 2, height: 2))

        // MacOSCursorCache resolves standard & custom cursors
        #expect(MacOSCursorCache.shared.cursor(for: .pointer) == NSCursor.pointingHand)
        #expect(MacOSCursorCache.shared.cursor(for: .text) == NSCursor.iBeam)

        // MacOSHostViewHelper caretScreenRect + MacOSAccessibilityHost projection
        let dummyView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let screenRect = MacOSHostViewHelper.caretScreenRect(
            caret: MotionRect.fromXYWH(10, 20, 2, 16),
            in: dummyView
        )
        #expect(screenRect.origin.x == 10)
        #expect(screenRect.size.height == 16)

        let a11yHost = MacOSAccessibilityHost()
        let node = AccessibilityNode(
            id: "btn",
            role: .button,
            label: "Save",
            frame: MotionRect.fromXYWH(10, 10, 80, 30),
            isFocused: true,
            actions: [.press]
        )
        a11yHost.update(tree: node, parentView: dummyView) { _, _ in }
        #expect(a11yHost.accessibilityChildren().count == 1)
        #expect(a11yHost.accessibilityFocusedUIElement() != nil)
    }

    @Test("RuneMetalHostView forwards otherMouse, keyUp (with IME guard), gestures, clipboard, and syncPlatformBridges (#497)")
    @MainActor
    func runeMetalHostViewForwardingHooks() throws {
        _ = NSApplication.shared
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = try MetalRenderer()

        struct S {
            var edit = TextEdit("hello")
            var downButtons: [PointerButton] = []
            var clickButtons: [PointerButton] = []
            var keyUps: [String] = []
            var magnifyDeltas: [(Float, GesturePhase)] = []
            var rotateDegrees: [(Float, GesturePhase)] = []
            var smartMagnifyPts: [Vec2] = []
        }

        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 200)) { _, _ in
            El<S>(direction: .column)
                .key("root")
                .w(200).h(200)
                .pointerButtons([PointerButton.middle, .back, .forward])
                .onPointerDown { st, _, tx in st.downButtons.append(tx.button) }
                .onClick { st, tx in st.clickButtons.append(tx.button) }
                .onKeyUp { st, ev, _ in
                    if case .text(let s) = ev.key { st.keyUps.append(s) }
                    return true
                }
                .onMagnify { st, ev, _ in
                    st.magnifyDeltas.append((ev.delta, ev.phase))
                    return true
                }
                .onRotate { st, ev, _ in
                    st.rotateDegrees.append((ev.degrees, ev.phase))
                    return true
                }
                .onSmartMagnify { st, x, y, _ in
                    st.smartMagnifyPts.append(Vec2(x, y))
                    return true
                }
                .children([
                    textInput(key: "input", \S.edit)
                        .w(180).h(40)
                ])
        }
        _ = rt.frame(at: 0.0)

        let hostView = RuneMetalHostView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 200),
            runtime: rt,
            renderer: renderer,
            timeScale: 1.0,
            respectSystemAppearance: false
        )
        #expect(rt.boundClipboard === Clipboard.shared)

        // 1. otherMouseDown / otherMouseUp map buttonNumber -> PointerButton (.middle=2, .back=3, .forward=4)
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        let cgPt = CGPoint(x: 100, y: max(0, mainDisplayHeight - 100))
        for btnNum in [2, 3, 4] {
            if let cgDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .otherMouseDown,
                mouseCursorPosition: cgPt,
                mouseButton: CGMouseButton(rawValue: UInt32(btnNum))!
            ), let nsDown = NSEvent(cgEvent: cgDown),
               let cgUp = CGEvent(
                   mouseEventSource: nil,
                   mouseType: .otherMouseUp,
                   mouseCursorPosition: cgPt,
                   mouseButton: CGMouseButton(rawValue: UInt32(btnNum))!
               ), let nsUp = NSEvent(cgEvent: cgUp) {
                hostView.otherMouseDown(with: nsDown)
                hostView.otherMouseUp(with: nsUp)
            }
        }
        #expect(rt.state.downButtons == [.middle, .back, .forward])
        #expect(rt.state.clickButtons == [.middle, .back, .forward])

        // 2. keyUp forwards when IME has no marked text, and is suppressed while marked text is open
        rt.update(at: 0.1) { _, tx in tx.focus("input") }
        _ = rt.frame(at: 0.1)
        let keyUpEvent = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!
        hostView.setMarkedText("ka", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        hostView.keyUp(with: keyUpEvent)
        #expect(rt.state.keyUps.isEmpty)

        hostView.unmarkText()
        hostView.keyUp(with: keyUpEvent)
        #expect(rt.state.keyUps == ["a"])

        // 3. Gesture forwarding & phase mapping
        #expect(RuneMetalHostView<S>.gesturePhase(from: .began) == .began)
        #expect(RuneMetalHostView<S>.gesturePhase(from: .mayBegin) == .began)
        #expect(RuneMetalHostView<S>.gesturePhase(from: .changed) == .changed)
        #expect(RuneMetalHostView<S>.gesturePhase(from: .ended) == .ended)
        #expect(RuneMetalHostView<S>.gesturePhase(from: .cancelled) == .cancelled)

        #expect(hostView.dispatchMagnify(delta: 0.25, at: Vec2(100, 120), phase: .changed))
        #expect(hostView.dispatchRotate(degrees: 30.0, at: Vec2(100, 120), phase: .ended))
        #expect(hostView.dispatchSmartMagnify(at: Vec2(100, 120)))
        #expect(rt.state.magnifyDeltas.count == 1)
        #expect(rt.state.magnifyDeltas[0].0 == 0.25)
        #expect(rt.state.magnifyDeltas[0].1 == .changed)
        #expect(rt.state.rotateDegrees.count == 1)
        #expect(rt.state.rotateDegrees[0].0 == 30.0)
        #expect(rt.state.rotateDegrees[0].1 == .ended)
        #expect(rt.state.smartMagnifyPts == [Vec2(100, 120)])

        // 4. syncPlatformBridges updates spellWatch and keeps detached secureInputClaim inactive
        hostView.syncPlatformBridges(treeCommitted: true)
        #expect(hostView.spellWatch.path == "/@root/@input")
        #expect(hostView.secureInputClaim.isActive == false)
    }
    #endif
}
