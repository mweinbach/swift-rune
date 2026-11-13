import Foundation
import Testing
@testable import Rune

@Suite("Platform Increment 1 Parity")
struct RunePlatformIncrement1Tests {

    // MARK: - OpenUrl (open_url.rs)

    @Test("OpenUrl: allows http/https/mailto/ipv6 and rejects all 26 upstream bad inputs")
    func openUrlValidationParity() throws {
        #expect(try UrlOpener.validate("  https://example.com/a?b=1#c ") == "https://example.com/a?b=1#c")
        #expect(try UrlOpener.validate("HTTP://example.com") == "http://example.com")
        #expect(try UrlOpener.validate("https://[::1]:8080/path") == "https://[::1]:8080/path")
        #expect(try UrlOpener.validate("mailto:someone@example.com?subject=Hi") == "mailto:someone@example.com?subject=Hi")

        #expect(throws: OpenUrlError.unsupportedScheme("file")) {
            _ = try UrlOpener.validate("file:///etc/passwd")
        }
        #expect(throws: OpenUrlError.unsupportedScheme("javascript")) {
            _ = try UrlOpener.validate("JavaScript:alert(1)")
        }
        #expect(throws: OpenUrlError.unsupportedScheme("myapp")) {
            _ = try UrlOpener.validate("myapp://do/thing")
        }
        #expect(throws: OpenUrlError.empty) {
            _ = try UrlOpener.validate("")
        }
        #expect(throws: OpenUrlError.empty) {
            _ = try UrlOpener.validate("  ")
        }

        let badURLs = [
            "example.com", "https:", "https://", "https:///x", "https://a b", "https://a\n.com",
            "mailto:", "mailto://example.com", "1http://x", "://x",
            "https://\\evil.com", "https://example.com/\"--flag", "https://example.com/a\\b",
            "https://example.com/%ZZ", "https://example.com/%00", "https://example.com/%2",
            "https://@/", "https://user@/", "https://:80/", "https://example.com:abc/",
            "https://evil%2f.com/", "https://.example.com", "https://a..b.com",
            "https://example.com/a[0]", "https://[not-ipv6]/", "https://[::1]abc/",
            "https://example.com:+80", "https://[::1]:+80",
        ]
        for bad in badURLs {
            #expect(throws: OpenUrlError.invalid, "Expected invalid for \(bad)") {
                _ = try UrlOpener.validate(bad)
            }
        }
    }

    @Test("OpenUrl: same_tab links relative only on web, native rejects relative")
    func openUrlSameTabRelativeParity() throws {
        let relatives = ["/notes/42", "notes/42?x=1", "?q=a", "#top", "../c", "a/b:c"]
        for rel in relatives {
            #expect(try UrlOpener.checkLink(rel, relative: true) == rel)
            #expect(throws: OpenUrlError.invalid) {
                _ = try UrlOpener.checkLink(rel, relative: false)
            }
            #expect(throws: OpenUrlError.invalid) {
                _ = try UrlOpener.checkSameTab(rel)
            }
        }
        #expect(throws: OpenUrlError.unsupportedScheme("javascript")) {
            _ = try UrlOpener.checkLink("javascript:alert(1)", relative: true)
        }
        #expect(throws: OpenUrlError.invalid) {
            _ = try UrlOpener.checkLink("/a b", relative: true)
        }
        #expect(try UrlOpener.checkLink("HTTPS://example.com/x", relative: true) == "https://example.com/x")
    }

    @Test("OpenUrl: headless Runtime records open_url and open_url_same_tab requests")
    func openUrlHeadlessRuntimeQueue() throws {
        var results: [OpenUrlError?] = []
        let rt = Runtime<[String]>(
            state: [],
            viewport: Vec2(50, 50),
            view: { _, _ in
                row().children([
                    El<[String]>().key("batch").size(10, 10).onClick { _, tx in
                        for (url, sameTab) in [
                            ("https://example.com/docs", false),
                            ("file:///etc/hosts", false),
                            ("mailto:a@example.com", false),
                            ("https://example.com/here", true),
                        ] {
                            do {
                                if sameTab {
                                    try tx.openUrlSameTab(url)
                                } else {
                                    try tx.openUrl(url)
                                }
                                results.append(nil)
                            } catch let err as OpenUrlError {
                                results.append(err)
                            } catch {
                                Issue.record("Unexpected error: \(error)")
                            }
                        }
                    },
                    El<[String]>().key("btn").size(10, 10).onClick { state, tx in
                        state.append("handler")
                        try? tx.openUrl("https://example.com/clicked")
                    },
                ])
            }
        )
        _ = rt.frame(at: 0)
        rt.pointerDown(at: Vec2(5, 5), button: .primary, mods: .none, at: 0)
        rt.pointerUp(at: Vec2(5, 5), button: .primary, mods: .none, at: 0)
        rt.pointerDown(at: Vec2(15, 5), button: .primary, mods: .none, at: 0)
        rt.pointerUp(at: Vec2(15, 5), button: .primary, mods: .none, at: 0)
        _ = rt.frame(at: 0)

        #expect(results == [nil, .unsupportedScheme("file"), nil, nil])
        #expect(rt.takeUrlRequests().map { $0.url } == [
            "https://example.com/docs",
            "mailto:a@example.com",
            "https://example.com/here",
            "https://example.com/clicked",
        ])
        #expect(rt.takeUrlRequests().isEmpty)
    }

    // MARK: - Native Menu KeyEquivalents (native_menu/key_equivalent_tests.rs)

    @Test("MenuKeyEquivalent: matches accelerator characters and AppKit flags")
    func menuKeyEquivalentsMatchAccelerators() {
        let shift = MenuKeyEquivalent.shiftMask
        let ctrl = MenuKeyEquivalent.controlMask
        let opt = MenuKeyEquivalent.optionMask
        let cmd = MenuKeyEquivalent.commandMask

        #expect(MenuKeyEquivalent(parsing: "cmd+b") == MenuKeyEquivalent(key: "b", modifierMask: cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+=") == MenuKeyEquivalent(key: "=", modifierMask: cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+-") == MenuKeyEquivalent(key: "-", modifierMask: cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+r") == MenuKeyEquivalent(key: "r", modifierMask: cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+1") == MenuKeyEquivalent(key: "1", modifierMask: cmd))
        #expect(MenuKeyEquivalent(parsing: "ctrl+cmd+s") == MenuKeyEquivalent(key: "s", modifierMask: ctrl | cmd))
        // Never includes function-key flag (1 << 23).
        #expect(MenuKeyEquivalent(parsing: "ctrl+cmd+f") == MenuKeyEquivalent(key: "f", modifierMask: ctrl | cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+shift+z") == MenuKeyEquivalent(key: "z", modifierMask: shift | cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+shift+=") == MenuKeyEquivalent(key: "=", modifierMask: shift | cmd))
        #expect(MenuKeyEquivalent(parsing: "ctrl+alt+shift+cmd+k") == MenuKeyEquivalent(key: "k", modifierMask: ctrl | opt | shift | cmd))
    }

    @Test("MenuKeyEquivalent: named keys map to AppKit Unicode characters")
    func menuKeyEquivalentsNamedKeys() {
        let shift = MenuKeyEquivalent.shiftMask
        let ctrl = MenuKeyEquivalent.controlMask
        let opt = MenuKeyEquivalent.optionMask
        let cmd = MenuKeyEquivalent.commandMask

        #expect(MenuKeyEquivalent(parsing: "alt+cmd+left") == MenuKeyEquivalent(key: "\u{f702}", modifierMask: opt | cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+up") == MenuKeyEquivalent(key: "\u{f700}", modifierMask: cmd))
        #expect(MenuKeyEquivalent(parsing: "f5") == MenuKeyEquivalent(key: "\u{f708}", modifierMask: 0))
        #expect(MenuKeyEquivalent(parsing: "shift+f24") == MenuKeyEquivalent(key: "\u{f71b}", modifierMask: shift))
        #expect(MenuKeyEquivalent(parsing: "cmd+enter") == MenuKeyEquivalent(key: "\r", modifierMask: cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+backspace") == MenuKeyEquivalent(key: "\u{8}", modifierMask: cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+delete") == MenuKeyEquivalent(key: "\u{f728}", modifierMask: cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+escape") == MenuKeyEquivalent(key: "\u{1b}", modifierMask: cmd))
        #expect(MenuKeyEquivalent(parsing: "ctrl+tab") == MenuKeyEquivalent(key: "\t", modifierMask: ctrl))
        #expect(MenuKeyEquivalent(parsing: "cmd+space") == MenuKeyEquivalent(key: " ", modifierMask: cmd))

        for name in ["a", "z", "0", "9", "f1", "f24", "escape", "enter", "space", "tab",
                     "backspace", "delete", "home", "end", "pageup", "pagedown", "left", "right", "up", "down"] {
            let eq = MenuKeyEquivalent(parsing: "cmd+\(name)")
            #expect(eq != nil)
            #expect(eq?.key.unicodeScalars.count == 1)
            #expect(eq?.key.lowercased() == eq?.key)
        }
    }

    // MARK: - Standard Mac Menus (native_menu/standard.rs)

    @Test("StandardMenuItem: mac standard set, key codes, routing, and top-level ordering")
    func standardMenuItemsAndRouting() throws {
        let plan = StandardMenuItem.items.map { ($0.menu, $0.title, $0.action, $0.key, $0.shift) }
        #expect(plan.count == 8)
        #expect(plan[0] == ("Edit", "Undo", "undo:", Character("z"), false))
        #expect(plan[1] == ("Edit", "Redo", "redo:", Character("z"), true))
        #expect(plan[2] == ("Edit", "Cut", "cut:", Character("x"), false))
        #expect(plan[3] == ("Edit", "Copy", "copy:", Character("c"), false))
        #expect(plan[4] == ("Edit", "Paste", "paste:", Character("v"), false))
        #expect(plan[5] == ("Edit", "Select All", "selectAll:", Character("a"), false))
        #expect(plan[6] == ("Window", "Minimize", "performMiniaturize:", Character("m"), false))
        #expect(plan[7] == ("Window", "Close", "performClose:", Character("w"), false))

        #expect(StandardMenuItem.items.allSatisfy { $0.action != "terminate:" && $0.key != "q" })
        #expect(StandardMenuItem.items.filter(\.separatorBefore).map(\.title) == ["Cut"])
        #expect(StandardMenuItem.byAction("copy:")?.role == .copy)
        #expect(StandardMenuItem.byAction("terminate:") == nil)

        let codes = StandardMenuItem.items.map(\.keyCode)
        #expect(codes == [6, 6, 7, 8, 9, 0, 46, 13])

        let close = try #require(StandardMenuItem.byAction("performClose:"))
        let minimize = try #require(StandardMenuItem.byAction("performMiniaturize:"))
        #expect(close.route(hasButton: true, current: StandardKeyDown(chars: "w", cmd: true)) == StandardMenuRoute(current: true, thenButton: true))
        #expect(minimize.route(hasButton: true, current: nil) == StandardMenuRoute(current: false, thenButton: true))
        #expect(close.route(hasButton: false, current: StandardKeyDown(chars: "w", cmd: true)) == StandardMenuRoute(current: true, thenButton: false))
        #expect(minimize.route(hasButton: false, current: StandardKeyDown(chars: "m", cmd: true)) == StandardMenuRoute(current: true, thenButton: false))

        let copy = try #require(StandardMenuItem.byAction("copy:"))
        let redo = try #require(StandardMenuItem.byAction("redo:"))
        #expect(copy.route(hasButton: true, current: StandardKeyDown(chars: "c", cmd: true)) == StandardMenuRoute(current: true, thenButton: false))
        #expect(copy.route(hasButton: false, current: StandardKeyDown(chars: "C", cmd: true)) == StandardMenuRoute(current: true, thenButton: false))
        #expect(redo.route(hasButton: false, current: StandardKeyDown(chars: "Z", cmd: true, shift: true)) == StandardMenuRoute(current: true, thenButton: false))
        #expect(redo.route(hasButton: false, current: StandardKeyDown(chars: "z", cmd: true)) == StandardMenuRoute(current: false, thenButton: false))
        #expect(copy.route(hasButton: false, current: StandardKeyDown(chars: "c", cmd: true, alt: true)) == StandardMenuRoute(current: false, thenButton: false))

        let standard = ["App", "Edit", "Window"]
        #expect(StandardMenuItem.topIndex(name: "File", tops: standard) == 1)
        #expect(StandardMenuItem.topIndex(name: "View", tops: standard) == 2)
        #expect(StandardMenuItem.topIndex(name: "Help", tops: standard) == 3)
        #expect(StandardMenuItem.topIndex(name: "Tools", tops: ["App", "File", "Edit", "View", "Window", "Help"]) == 4)
        #expect(StandardMenuItem.topIndex(name: "Edit", tops: ["App", "File", "View", "Help"]) == 2)
        #expect(StandardMenuItem.topIndex(name: "Window", tops: ["App", "File", "Edit", "View", "Help"]) == 4)
        #expect(StandardMenuItem.topIndex(name: "View", tops: ["App"]) == 1)
        #expect(StandardMenuItem.topIndex(name: "File", tops: []) == 0)

        #expect(StandardEquivalent(key: "w", cmd: true, shift: false, alt: false, ctrl: false) == close.equivalent)
        #expect(StandardEquivalent(key: "w", cmd: true, shift: true, alt: false, ctrl: false) != close.equivalent)
        #expect(StandardEquivalent(key: "Z", cmd: true, shift: false, alt: false, ctrl: false) == redo.equivalent)
        #expect(StandardEquivalent(key: "", cmd: true, shift: false, alt: false, ctrl: false) == nil)

        let winit: [String?] = [
            "orderFrontStandardAboutPanel:", nil, nil, "hide:", "hideOtherApplications:",
            "unhideAllApplications:", nil, "terminate:",
        ]
        #expect(StandardMenuItem.isWinitDefault(topCount: 1, appMenuActions: winit))
        #expect(!StandardMenuItem.isWinitDefault(topCount: 2, appMenuActions: winit))
        #expect(!StandardMenuItem.isWinitDefault(topCount: 1, appMenuActions: Array(winit.prefix(7))))
        #expect(!StandardMenuItem.isWinitDefault(topCount: 1, appMenuActions: []))
        #expect(!StandardMenuItem.isWinitDefault(topCount: 0, appMenuActions: []))
    }

    // MARK: - NativeMenu Validation & Lookup (native_menu/mod.rs)

    @Test("NativeMenuBar: validates duplicates/empty titles, allows separators, detects ambiguous titles")
    func nativeMenuValidationAndLookup() throws {
        func item(_ id: String, title: String = "Open Quick Panel", location: NativeMenuLocation = .app) -> NativeMenuItem<[Int]> {
            NativeMenuItem(id: id, title: title, location: location) { s, _ in s.append(1) }
        }

        let bar = NativeMenuBar<[Int]>(items: [
            item("first"),
            item("second", location: .named("Tools")),
        ])
        var state: [Int] = []
        var tx = Tx()
        #expect(throws: MenuError.ambiguousTitle("Open Quick Panel")) {
            try bar.dispatch(id: "Open Quick Panel", state: &state, tx: &tx)
        }
        try bar.dispatch(id: "first", state: &state, tx: &tx)
        #expect(state == [1])

        #expect(throws: MenuError.invalid("duplicate id dup")) {
            try bar.setValidatedItems([item("dup"), item("dup")])
        }
        #expect(bar.items.count == 2)

        #expect(throws: MenuError.unknownItem("missing")) {
            try bar.dispatch(id: "missing", state: &state, tx: &tx)
        }
        #expect(throws: MenuError.invalid("empty menu title")) {
            try bar.setValidatedItems([NativeMenuItem.separator(location: .named(" "))])
        }
        try bar.setValidatedItems([
            item("new", title: "New", location: .named("File")),
            NativeMenuItem.separator(location: .named("File")),
            NativeMenuItem.separator(location: .dock),
        ])
        try bar.dispatch(id: "New", state: &state, tx: &tx)
        #expect(state == [1, 1])
    }

    // MARK: - Quit Lifecycle & Fast Exit (quit.rs + #831)

    @Test("QuitMachine & QuitLifecycle: hooks owed re-emit RunHooks, relaunch outranks exit, fast/orderly exit")
    func quitMachineAndLifecycle() {
        let (s1, e1) = QuitMachine.step(.running, event: .start(ending: false, after: .exit))
        #expect(s1 == .quitting(hooks: .owed, after: .exit))
        #expect(e1 == [.runHooks])

        // Re-starting while hooks are still owed must re-emit .runHooks and outrank with .relaunch.
        let (s2, e2) = QuitMachine.step(s1, event: .start(ending: true, after: .relaunch))
        #expect(s2 == .quitting(hooks: .owed, after: .relaunch))
        #expect(e2 == [.runHooks, .closeAndExit])

        let (s3, e3) = QuitMachine.step(s2, event: .hooksRan)
        #expect(s3 == .quitting(hooks: .ran, after: .relaunch))
        #expect(e3.isEmpty)

        // When hooks already ran, another Start doesn't re-emit .runHooks.
        let (s4, e4) = QuitMachine.step(s3, event: .start(ending: true, after: .exit))
        #expect(s4 == .quitting(hooks: .ran, after: .relaunch))
        #expect(e4 == [.closeAndExit])

        let (s5, e5) = QuitMachine.step(s4, event: .exited)
        #expect(s5 == .done)
        #expect(e5 == [.relaunch])

        let (sCancel, eCancel) = QuitMachine.step(.quitting(hooks: .ran, after: .exit), event: .cancel)
        #expect(sCancel == .running)
        #expect(eCancel.isEmpty)

        QuitLifecycle.resetForTesting()
        #expect(!QuitLifecycle.isQuitting)
        #expect(QuitLifecycle.activeFastExitHook() != nil)

        var tx = Tx()
        tx.relaunch()
        #expect(tx.quitRequested)
        #expect((tx.runtimeActions["relaunchRequested"] as? Bool) == true)

        QuitLifecycle.orderlyExit()
        #expect(QuitLifecycle.activeFastExitHook() == nil)
        QuitLifecycle.resetForTesting()
    }

    // MARK: - Preferences (#816 RUNE_CONTRAST) & ScrollBars & ReadySignal

    @Test("SystemContrast: parses RUNE_CONTRAST presets aquatic, desert, dusk, night-sky")
    func runContrastPresets() {
        #expect(SystemContrast.preset(named: "aquatic")?.window == Color.hex("#202020"))
        #expect(SystemContrast.preset(named: "DESERT")?.highlight == Color.hex("#903909"))
        #expect(SystemContrast.preset(named: "dusk")?.link == Color.hex("#70ebde"))
        #expect(SystemContrast.preset(named: "night-sky")?.window == Color.hex("#000000"))
        #expect(SystemContrast.preset(named: "nightsky")?.highlight == Color.hex("#d6b4fd"))
        #expect(SystemContrast.preset(named: "unknown") == nil)
        #expect(SystemContrast.fromEnvironment(["RUNE_CONTRAST": "aquatic"]) != nil)
        #expect(SystemContrast.fromEnvironment([:]) == nil)
    }

    @Test("ScrollBars: defaults, resolution, and AppleShowScrollBars parsing")
    func scrollBarsParity() {
        #expect(ScrollBars.whenScrolling == .whenScrolling)
        #expect(SystemScrollBars.default.isOverlay)
        #expect(ScrollBars.whenScrolling.isOverlay(scrollerOverlay: false))
        #expect(ScrollBars.whenScrolling.isOverlay(scrollerOverlay: true))
        #if !os(iOS) && !os(tvOS) && !os(visionOS)
        #expect(!ScrollBars.always.isOverlay(scrollerOverlay: true))
        #expect(!ScrollBars.always.isOverlay(scrollerOverlay: false))
        #expect(ScrollBars.automatic.isOverlay(scrollerOverlay: true))
        #expect(!ScrollBars.automatic.isOverlay(scrollerOverlay: false))
        #endif

        #expect(ScrollBars.parseAppleShowScrollBars(nil) == .automatic)
        #expect(ScrollBars.parseAppleShowScrollBars("Automatic") == .automatic)
        #expect(ScrollBars.parseAppleShowScrollBars("WhenScrolling") == .whenScrolling)
        #expect(ScrollBars.parseAppleShowScrollBars("Always") == .always)
        #expect(ScrollBars.parseAppleShowScrollBars("Unexpected") == .automatic)
    }

    @Test("ReadySignal: escapes control chars in JSON payload")
    func readySignalEscapesJSON() throws {
        let payload = ReadySignal.SignalPayload(pid: 42, bundleId: "com.test.\"app\"\n\t\\", readyMs: 12)
        let json = payload.jsonLine()
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(obj?["bundle_id"] as? String == "com.test.\"app\"\n\t\\")
        #expect(obj?["pid"] as? Int == 42)
        #expect(obj?["ready_ms"] as? Int == 12)
    }
}
