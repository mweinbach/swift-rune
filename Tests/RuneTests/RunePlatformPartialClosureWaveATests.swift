import Foundation
import Testing
@testable import Rune
import RuneMotion
#if os(macOS) && canImport(AppKit)
import AppKit
#endif

@Suite("Platform Closeout Wave A Parity")
struct RunePlatformPartialClosureWaveATests {
    private static let macOnly: Bool = {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }()

    // MARK: - window/keys_tests.rs (2/2 Dvorak physical_with_fallback integration)

    @Test("window/keys_tests.rs:13 - Dvorak logical fallback key fires shortcut over focused TextEdit without typing")
    @MainActor
    func dvorakLogicalFallbackFiresShortcut() throws {
        struct State: Equatable {
            var field = TextEdit("")
            var physicalSeen: [PhysicalKeyCode] = []
        }
        final class Hit: @unchecked Sendable { var opened = false }
        let hit = Hit()
        let registry = ShortcutRegistry()
        _ = registry.register(id: "open.file", accelerator: "cmd+shift+o", scope: .global) {
            hit.opened = true
        }
        let rt = Runtime(
            state: State(),
            viewport: Vec2(240, 100),
            view: { s, _ in
                El<State>().size(240, 100)
                    .onPhysicalInput { s, ev, _ in
                        if case .key(let code, _, true, false) = ev {
                            s.physicalSeen.append(code)
                        }
                        return false
                    }
                    .child(
                        textInput(key: "field", \State.field)
                            .size(200, 40)
                            .child(text(s.field.text))
                    )
            }
        )
        rt.shortcutRegistry = registry
        _ = rt.frame(at: 0.0)
        rt.pointerDown(at: Vec2(20, 20), at: 0.005)
        rt.pointerUp(at: Vec2(20, 20), at: 0.006)
        // On Dvorak, physical QWERTY key `S` produces logical `O` (Cmd+Shift+O).
        let handled = rt.physicalInput(
            PhysicalInput.key(key: .keyS, mods: Mods(shift: true, cmd: true, logo: true), pressed: true, repeat: false),
            fallbackKey: KeyEvent(key: .text("O"), mods: Mods(shift: true, cmd: true, logo: true)),
            at: 0.01
        )
        #expect(handled)
        #expect(rt.state.physicalSeen == [.keyS])
        #expect(hit.opened == true)
        #expect(rt.state.field.text.isEmpty)
    }

    @Test("window/keys_tests.rs: Dvorak Cmd-V on physical Period pastes into focused field")
    func dvorakCmdVPastesIntoFocusedField() {
        struct State: Equatable {
            var field = TextEdit("")
        }
        let rt = Runtime(
            state: State(),
            viewport: Vec2(240, 80),
            view: { state, _ in
                El<State>().size(240, 80).children([
                    textInput(key: "field", \State.field)
                        .size(200, 40)
                        .child(text(state.field.text))
                ])
            }
        )
        rt.update { _, tx in
            tx.copyText("pasted-dvorak")
            tx.focus("field")
        }
        _ = rt.frame(at: 0.01)
        // On Dvorak, physical `.period` produces logical `v` (Cmd+V).
        let handled = rt.physicalInput(
            PhysicalInput.key(key: .period, mods: Mods(cmd: true, logo: true), pressed: true, repeat: false),
            fallbackKey: KeyEvent(key: .text("v"), mods: Mods(cmd: true, logo: true)),
            at: 0.02
        )
        #expect(handled)
        #expect(rt.state.field.text == "pasted-dvorak")
    }

    // MARK: - platform/macos/pointer_tests.rs:155,178 (OverlayPointerState + Runtime.pointerReleaseLost)

    @Test("pointer_tests.rs:155 - sample beating next press cancels old drag where button rose")
    func sampleBeatingNextPressCancelsDragWhereButtonRose() {
        struct State: Equatable {
            var endedCancelled: [Bool] = []
        }
        let rt = Runtime(
            state: State(),
            viewport: Vec2(100, 100),
            view: { _, _ in
                El<State>().size(100, 100)
                    .onDrag { _, _, _ in }
                    .onDragEnd { s, cancelled, _ in s.endedCancelled.append(cancelled) }
            }
        )
        _ = rt.frame(at: 0.0)

        let pointer = OverlayPointerState(input: .all)
        let t0 = 1.0
        pointer.recordClick(down: true, at: Vec2(10, 10))
        _ = pointer.takeEdge(down: true)
        rt.pointerDown(at: Vec2(10, 10), at: 0.01)

        pointer.observeRelease(buttons: 0, now: t0, at: Vec2(50, 50))
        pointer.observeRelease(buttons: 1, now: t0 + 0.01, at: Vec2(70, 70))
        pointer.recordClick(down: true, at: Vec2(70, 70))
        let edge = pointer.takeEdge(down: true)
        #expect(edge.lostRelease == Vec2(50, 50))

        rt.pointerReleaseLost(at: edge.lostRelease!, at: 0.02)
        _ = rt.frame(at: 0.03)
        #expect(rt.state.endedCancelled == [true])
        #expect(rt.pointerPosition == Vec2(50, 50))
        #expect(rt.hasActivePointerDrag == false)
    }

    @Test("pointer_tests.rs:178 - press lost before sample cancels at own down and keeps click run")
    func pressLostBeforeSampleCancelsAtOwnDownAndKeepsRun() {
        struct State: Equatable {
            var events: [String] = []
        }
        let rt = Runtime(
            state: State(),
            viewport: Vec2(100, 100),
            view: { _, _ in
                El<State>().size(100, 100)
                    .onDrag { s, d, _ in
                        s.events.append("down:\(Int(d.window.x)),\(d.clicks)")
                    }
                    .onDragEnd { s, cancelled, _ in
                        s.events.append("up:\(cancelled)")
                    }
            }
        )
        _ = rt.frame(at: 0.0)

        let pointer = OverlayPointerState(input: .all)
        pointer.read(buttons: 0, now: 1.0, at: Vec2(5, 5), inside: true)
        pointer.recordClick(down: true, at: Vec2(50, 10))
        let first = pointer.takeEdge(down: true)
        #expect(first.point == Vec2(50, 10))
        rt.pointerDown(at: first.point!, at: 0.05)

        pointer.recordClick(down: true, at: Vec2(51, 10))
        let second = pointer.takeEdge(down: true)
        #expect(second.lostRelease == Vec2(50, 10))
        #expect(second.point == Vec2(51, 10))

        rt.pointerReleaseLost(at: second.lostRelease!, at: 0.06)
        rt.pointerDown(at: second.point!, at: 0.07)
        _ = rt.frame(at: 0.08)
        #expect(rt.state.events == ["down:50,1", "up:true", "down:51,2"])
    }

    // MARK: - native_menu/key_equivalent_tests.rs:71 (Dvorak keycaps vs menuKeycaps)

    @Test("native_menu/key_equivalent_tests.rs:71 - Dvorak moves keycaps but not menuKeycaps")
    func dvorakMovesKeycapsButNotMenuKeycaps() throws {
        let dvorakMap: [UInt32: String] = [
            11: "x", 45: "b", 3: "u", 16: "f", 15: "p", 1: "o", 6: ";", 24: "]", 27: "[",
        ]
        MacOSKeyboardLayout.force { key, _ in dvorakMap[key] }
        defer { MacOSKeyboardLayout.force(nil) }

        #expect(try ParsedShortcut.parseOn("cmd+b", platform: .mac).keycaps(on: .mac) == ["⌘", "X"])
        #expect(try ParsedShortcut.parseOn("cmd+=", platform: .mac).keycaps(on: .mac) == ["⌘", "]"])

        let cases: [(accel: String, eqKey: String, mask: UInt, label: String)] = [
            ("cmd+b", "b", MenuKeyEquivalent.commandMask, "B"),
            ("cmd+=", "=", MenuKeyEquivalent.commandMask, "="),
            ("cmd+-", "-", MenuKeyEquivalent.commandMask, "-"),
            ("cmd+r", "r", MenuKeyEquivalent.commandMask, "R"),
            ("ctrl+cmd+s", "s", MenuKeyEquivalent.controlMask | MenuKeyEquivalent.commandMask, "S"),
            ("ctrl+cmd+f", "f", MenuKeyEquivalent.controlMask | MenuKeyEquivalent.commandMask, "F"),
            ("cmd+shift+z", "z", MenuKeyEquivalent.shiftMask | MenuKeyEquivalent.commandMask, "Z"),
            ("cmd+left", "\u{f702}", MenuKeyEquivalent.commandMask, "←"),
            ("f5", "\u{f708}", 0, "F5"),
        ]
        for c in cases {
            let chord = try Chord.parse(c.accel)
            let equiv = MenuKeyEquivalent(chord: chord)
            #expect(equiv == MenuKeyEquivalent(key: c.eqKey, modifierMask: c.mask))
            let caps = try ParsedShortcut.parseOn(c.accel, platform: .mac).menuKeycaps(on: .mac)
            #expect(caps.last == c.label)
            #expect(chord.menuKeycaps(on: .mac).last == c.label)
        }
    }

    // MARK: - native_menu/mod.rs (6/6 parity: reentrant callback, stale cancel, non-Sendable, unsupported noop)

    @Test("native_menu/mod.rs:378 - setting menu inside item callback updates on next frame")
    func settingMenuInsideItemCallbackUpdatesOnNextFrame() throws {
        let app = App(title: "ReentrantMenu", state: [String]()) { _, _ in El<[String]>().size(100, 100) }
        let handle = app.sharedHandle
        AppMenuBridge.markRunning(handle.shared, running: true, headless: true)
        defer { AppMenuBridge.markRunning(handle.shared, running: false, headless: false) }

        func stepTwoItems(handle: AppHandle<[String]>) -> [NativeMenuItem<[String]>] {
            [NativeMenuItem(id: "swap", title: "Swap") { state, _ in
                state.append("step1")
                try? handle.setMenu([NativeMenuItem(id: "second", title: "Second") { s, _ in
                    s.append("step2")
                }])
            }]
        }

        try handle.setMenu(stepTwoItems(handle: handle))
        try handle.fireMenu("swap")

        let rt = Runtime(state: [String](), viewport: Vec2(100, 100)) { _, _ in El<[String]>().size(100, 100) }
        _ = handle.shared.applyStateUpdates(to: rt, at: 0.01)
        #expect(rt.state == ["step1"])
        #expect(AppMenuBridge.snapshot(for: handle.shared).items.map(\.id) == ["second"])

        try handle.fireMenu("second")
        _ = handle.shared.applyStateUpdates(to: rt, at: 0.02)
        #expect(rt.state == ["step1", "step2"])
    }

    @Test("native_menu/mod.rs:398 - replacing, disabling, or shutting down cancels stale fired actions")
    func replacingDisablingOrShutdownCancelsStaleMenuActions() throws {
        let app = App(title: "StaleMenu", state: [String]()) { _, _ in El<[String]>().size(100, 100) }
        let handle = app.sharedHandle
        AppMenuBridge.markRunning(handle.shared, running: true, headless: true)
        defer { AppMenuBridge.markRunning(handle.shared, running: false, headless: false) }

        let rt = Runtime(state: [String](), viewport: Vec2(100, 100)) { _, _ in El<[String]>().size(100, 100) }

        // 1. Replacement before drain cancels queued fire.
        try handle.setMenu([NativeMenuItem(id: "a", title: "Alpha") { s, _ in s.append("stale-a") }])
        try handle.fireMenu("a")
        try handle.setMenu([NativeMenuItem(id: "a", title: "Alpha") { s, _ in s.append("new-a") }])
        _ = handle.shared.applyStateUpdates(to: rt, at: 0.01)
        #expect(rt.state.isEmpty)

        // 2. Disabling before drain cancels queued fire.
        try handle.fireMenu("a")
        try handle.setMenu([NativeMenuItem(id: "a", title: "Alpha", enabled: false) { s, _ in s.append("disabled-a") }])
        _ = handle.shared.applyStateUpdates(to: rt, at: 0.02)
        #expect(rt.state.isEmpty)

        // 3. Shutdown before drain cancels queued fire.
        try handle.setMenu([NativeMenuItem(id: "b", title: "Beta") { s, _ in s.append("shutdown-b") }])
        try handle.fireMenu("b")
        AppMenuBridge.markRunning(handle.shared, running: false, headless: false)
        _ = handle.shared.applyStateUpdates(to: rt, at: 0.03)
        #expect(rt.state.isEmpty)
    }

    @Test("native_menu/mod.rs:448 - non-Sendable state and keyEquivalent/keysFirst remain builder compatible")
    func nonSendableStateAndBuilderCompatibility() {
        final class NonSendableCounter {
            var count = 0
        }
        let app = App(title: "NonSendableMenu", state: NonSendableCounter()) { _, _ in
            El<NonSendableCounter>().size(100, 100)
        }
        let sendableHandle: any Sendable = app.sharedHandle
        _ = sendableHandle
        let plain = NativeMenuItem<NonSendableCounter>(id: "quick", title: "Quick", keyEquivalent: "cmd+shift+k") { s, _ in
            s.count += 1
        }
        let keysFirst = NativeMenuItem<NonSendableCounter>(id: "kf", title: "KF", keyEquivalent: "cmd+shift+k", keysFirst: true) { _, _ in }
        #expect(plain.keyEquivalent == "cmd+shift+k")
        #expect(plain.keysFirst == false)
        #expect(keysFirst.keysFirst == true)
    }

    @Test("native_menu/mod.rs:458 - unsupported native platform records .unsupported and acts as noop while headless works")
    func unsupportedNativePlatformNoopButHeadlessWorks() throws {
        let initial = [NativeMenuItem<Int>(id: "quick", title: "Quick") { s, _ in s += 1 }]
        let app = App(title: "UnsupportedMenu", state: 0) { _, _ in El<Int>().size(100, 100) }
            .menuItem(initial[0])
        let handle = app.sharedHandle

        AppMenuBridge.attach(app.menuItems, to: handle.shared, headless: false, nativeSupported: false)
        defer { AppMenuBridge.markRunning(handle.shared, running: false, headless: false) }

        #expect(handle.takeMenuErrors() == [.unsupported])
        #expect(throws: MenuError.unsupported) {
            try handle.setMenu([NativeMenuItem<Int>(id: "other", title: "Other") { _, _ in }])
        }
        #expect(AppMenuBridge.snapshot(for: handle.shared).items.map(\.id) == ["quick"])

        // Headless still works even when native platform is marked unsupported.
        AppMenuBridge.markRunning(handle.shared, running: true, headless: true, nativeSupported: false)
        try handle.setMenu([NativeMenuItem<Int>(id: "other", title: "Other") { _, _ in }])
        #expect(AppMenuBridge.snapshot(for: handle.shared).items.map(\.id) == ["other"])
    }

    // MARK: - popup_menu/tests.rs:139,262,271 (Tx share + PopupSession lifecycle)

    @Test("popup_menu/tests.rs:139 - copies of Tx share one popup request")
    func copiesOfTxShareOnePopupRequest() {
        var tx = Tx()
        tx.popupMenu(PopupMenu().item("dark", "Dark"), at: "theme") { (_: inout Int, _, _) in }
        let clone = tx
        let cloneActions = clone.runtimeActions["erasedActions"] as? [ErasedRuntimeAction]
        let origActions = tx.runtimeActions["erasedActions"] as? [ErasedRuntimeAction]
        guard case .popup(let cloneReq)? = cloneActions?.first,
              case .popup(let origReq)? = origActions?.first else {
            Issue.record("Expected popup request in cloned Tx")
            return
        }
        #expect(cloneReq.take() != nil)
        #expect(origReq.take() == nil)
    }

    @Test("popup_menu/tests.rs:262,271 - PopupSession cancelled before open and resolved once with pointer")
    func popupSessionCancelledBeforeOpenAndResolvedOnce() {
        let cancelled = PopupSession()
        #expect(cancelled.cancelTracking() == nil)
        #expect(cancelled.isCancelled == true)
        #expect(cancelled.begin() == false)
        #expect(cancelled.resolve("dark", at: Vec2(1, 2)) == false)
        #expect(cancelled.takeAnswer() == nil)

        let session = PopupSession()
        #expect(session.begin() == true)
        #expect(session.begin() == false)
        session.tracking(nil)
        #expect(session.resolve("dark", at: Vec2(3, 4)) == true)
        #expect(session.resolve(nil, at: nil) == false)
        let ans = session.takeAnswer()
        #expect(ans?.pickedId == "dark")
        #expect(ans?.pointer == Vec2(3, 4))
        #expect(session.takeAnswer() == nil)
        #expect(session.isCancelled == true)
        #expect(session.cancelTracking() == nil)
    }

    // MARK: - drop_tests.rs:117,154,168,241,284

    @Test("drop_tests.rs:117 - covered window takes drop on current tree on hiddenWake and blocks behind fading modal")
    func coveredWindowDropAndModalOnHiddenWake() {
        struct DropEntry: Equatable {
            var zone: String
            var files: [String]
        }
        struct HoverEntry: Equatable {
            var zone: String
            var over: Bool
        }
        struct State: Equatable {
            var noInner = false
            var modal = false
            var dropped: [DropEntry] = []
            var hover: [HoverEntry] = []
        }
        let png = URL(fileURLWithPath: "/tmp/a.png")
        let png2 = URL(fileURLWithPath: "/tmp/b.png")
        let rt = Runtime(
            state: State(),
            viewport: Vec2(300, 200),
            view: { s, _ in
                var children: [El<State>] = [
                    El<State>().key("outer").absolute(x: 0, y: 0).w(200).h(200)
                        .onDropHover { st, over, _ in st.hover.append(HoverEntry(zone: "outer", over: over)) }
                        .onDropFiles { st, urls, _ in st.dropped.append(DropEntry(zone: "outer", files: urls.map(\.lastPathComponent))) }
                        .children(s.noInner ? [] : [
                            El<State>().key("inner").absolute(x: 10, y: 10).w(100).h(100)
                                .onDropHover { st, over, _ in st.hover.append(HoverEntry(zone: "inner", over: over)) }
                                .onDropFiles { st, urls, _ in st.dropped.append(DropEntry(zone: "inner", files: urls.map(\.lastPathComponent))) }
                        ])
                ]
                if s.modal {
                    children.append(
                        El<State>().key("modal")
                            .modal()
                            .transition(.opacity)
                            .absolute(x: 100, y: 100).w(100).h(100)
                            .onDropFiles { st, urls, _ in st.dropped.append(DropEntry(zone: "modal", files: urls.map(\.lastPathComponent))) }
                    )
                }
                return El<State>().w(300).h(200).children(children)
            }
        )
        _ = rt.frame(at: 0.0)
        rt.setLiveVisible(false)
        rt.update(at: 0.01) { s, _ in s.noInner = true }
        rt.dragFiles([png], at: Vec2(50, 50), at: 0.02)
        _ = rt.dropFiles([png], at: Vec2(50, 50), at: 0.03)
        #expect(rt.hasPendingInput == true)
        _ = rt.hiddenWake()
        #expect(rt.state.dropped == [DropEntry(zone: "outer", files: ["a.png"])])
        #expect(rt.state.hover == [
            HoverEntry(zone: "outer", over: true),
            HoverEntry(zone: "outer", over: false),
        ])

        // Fading-in modal mounted while covered does not accept drop at commit frame.
        rt.update(at: 0.04) { s, _ in s.modal = true }
        _ = rt.dropFiles([png2], at: Vec2(150, 150), at: 0.05)
        _ = rt.hiddenWake()
        #expect(rt.state.dropped.count == 1)
    }

    @Test("drop_tests.rs:154,168 - unmount swaps hover cleanly and plain target queues zero frames on move")
    func unmountHoverSwapAndNoMovePendingFrames() {
        struct HoverEntry: Equatable {
            var zone: String
            var over: Bool
        }
        struct State: Equatable {
            var noInner = false
            var hover: [HoverEntry] = []
        }
        let f = URL(fileURLWithPath: "/tmp/a.png")
        let rt = Runtime(
            state: State(),
            viewport: Vec2(300, 200),
            view: { s, _ in
                El<State>().key("outer").w(200).h(200)
                    .onDropHover { st, over, _ in st.hover.append(HoverEntry(zone: "outer", over: over)) }
                    .onDropFiles { _, _, _ in }
                    .children(s.noInner ? [] : [
                        El<State>().key("inner").w(100).h(100)
                            .onDropHover { st, over, _ in st.hover.append(HoverEntry(zone: "inner", over: over)) }
                            .onDropFiles { _, _, _ in }
                    ])
            }
        )
        _ = rt.frame(at: 0.0)
        rt.dragFiles([f], at: Vec2(50, 50), at: 0.01)
        _ = rt.frame(at: 0.02)

        for x in 51..<90 {
            #expect(rt.dragFilesTo(Vec2(Float(x), 50), at: 0.03) == false)
        }
        #expect(rt.hasPendingInput == false)

        rt.update(at: 0.04) { s, _ in s.noInner = true }
        _ = rt.frame(at: 0.05)
        #expect(rt.dragFilesTo(Vec2(50, 50), at: 0.06) == true)
        _ = rt.frame(at: 0.07)
        #expect(rt.state.hover == [
            HoverEntry(zone: "inner", over: true),
            HoverEntry(zone: "inner", over: false),
            HoverEntry(zone: "outer", over: true),
        ])
        #expect(rt.dropHovered == "outer")
    }

    @Test("drop_tests.rs:284 - onDropMove tracks element-local coordinates, deduplicates stationary moves, and fires on immediate drop")
    func dropMovePointLocalCoordsAndImmediateDropOrder() {
        struct State: Equatable {
            var seen: [String] = []
        }
        let f = URL(fileURLWithPath: "/tmp/a.txt")
        let rt = Runtime(
            state: State(),
            viewport: Vec2(400, 300),
            view: { _, _ in
                col().w(400).h(300).children([
                    El<State>().size(200, 20),
                    El<State>().key("doc").size(200, 100)
                        .onDropFiles { s, _, tx in
                            let pt = tx.dropPoint?.local ?? Vec2(-1, -1)
                            s.seen.append("drop:\(Int(pt.x)),\(Int(pt.y))")
                        }
                        .onDropHover { s, over, tx in
                            if over, let pt = tx.dropPoint?.local {
                                s.seen.append("over:\(Int(pt.x)),\(Int(pt.y))")
                            } else {
                                s.seen.append("off")
                            }
                        }
                        .onDropMove { s, _, tx in
                            let pt = tx.dropPoint?.local ?? Vec2(-1, -1)
                            s.seen.append("move:\(Int(pt.x)),\(Int(pt.y))")
                        },
                    El<State>().key("plain").size(200, 100).onDropFiles { _, _, _ in },
                ])
            }
        )
        _ = rt.frame(at: 0.0)

        rt.dragFiles([f], at: Vec2(30, 40), at: 0.01)
        _ = rt.frame(at: 0.02)
        #expect(rt.state.seen == ["over:30,20", "move:30,20"])
        rt.state.seen.removeAll()

        #expect(rt.dragFilesTo(Vec2(30, 40), at: 0.03) == false)
        #expect(rt.dragFilesTo(Vec2(50, 60), at: 0.04) == true)
        #expect(rt.dragFilesTo(Vec2(60, 70), at: 0.05) == false)
        _ = rt.frame(at: 0.06)
        #expect(rt.state.seen == ["move:60,50"])
        rt.state.seen.removeAll()

        #expect(rt.dragFilesTo(Vec2(60, 150), at: 0.07) == true)
        _ = rt.frame(at: 0.08)
        #expect(rt.state.seen == ["off"])
        rt.state.seen.removeAll()
        #expect(rt.dragFilesTo(Vec2(70, 160), at: 0.09) == false)

        rt.dragFiles([f], at: Vec2(70, 80), at: 0.10)
        _ = rt.dropFiles([f], at: Vec2(70, 80), at: 0.11)
        _ = rt.frame(at: 0.12)
        #expect(rt.state.seen == ["over:70,60", "move:70,60", "off", "drop:70,60"])
    }

    // MARK: - open_url/incoming_tests.rs:144 (NSAppleEventDescriptor direct object extraction)

    @Test("open_url/incoming_tests.rs:144 - NSAppleEventDescriptor direct object URL extraction")
    func appleEventDirectObjectUrlExtraction() {
        #if os(macOS) && canImport(AppKit)
        let empty = NSAppleEventDescriptor(
            eventClass: AEEventClass(0x4755524c), // 'GURL'
            eventID: AEEventID(0x4755524c),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        #expect(MacOSAppleEventHelper.url(from: empty) == nil)

        empty.setDescriptor(
            NSAppleEventDescriptor(string: "rune://open/doc"),
            forKeyword: AEKeyword(keyDirectObject)
        )
        #expect(MacOSAppleEventHelper.url(from: empty) == "rune://open/doc")
        #else
        #expect(!Self.macOnly)
        #endif
    }
}
