import AppKit
import Rune

// MacOSWindowFrame shell single|grouped regular|borderless|fixed|panel|launcher
@MainActor
enum ShellProbe {
    private static func check(_ passes: Bool, _ message: String) {
        guard passes else {
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
            exit(1)
        }
    }

    private static func wait(_ label: String, until complete: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !complete() {
            check(ContinuousClock.now < deadline, label)
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    static func run(host: String, kind: String) throws {
        check(["single", "grouped"].contains(host), host)
        check(["regular", "borderless", "fixed", "panel", "launcher"].contains(kind), kind)
        DispatchQueue.global().asyncAfter(deadline: .now() + 35) {
            FileHandle.standardError.write(Data("FAIL \(host) \(kind) timed out\n".utf8))
            exit(1)
        }
        let title = "Rune shell \(getpid())"
        var options = WindowOptions()
        options.visible = false
        options.borderless = kind == "borderless"
        options.minimizable = kind != "fixed"
        let base = App(title: title, size: Vec2(170, 96), state: 0) { _, _ in text("Shell requests") }
            .windowOptions(options).openInactive().accessory().keepRunning()
            .macosWindow(MacWindowOptions(nonactivatingPanel: kind == "panel", launcher: kind == "launcher"))
        let shared = base.sharedHandle
        let app = base.onWindow { handle in
            Task { @MainActor in
                guard let native = NSApp.windows.first(where: { $0.title == title }) else {
                    check(false, "Missing native window")
                    return
                }
                shared.update { _, tx in tx.setTitle("Hidden title"); tx.minimize() }
                await wait("Title on initial hidden window") { native.title == "Hidden title" }
                check(!native.isVisible && !native.isMiniaturized, "Hidden minimize changed native visibility")
                handle.show()
                await wait("Native window shown") { native.isVisible }
                for origin in ["Tx", "AppHandle", "WindowHandle"] {
                    switch origin {
                    case "Tx": shared.update { _, tx in tx.minimize() }
                    case "AppHandle": shared.minimize()
                    default: handle.minimize()
                    }
                    if kind == "regular" {
                        await wait("\(origin) minimize") { native.isMiniaturized }
                        shared.update { _, tx in tx.setTitle("Minimized \(origin)") }
                        await wait("Title on minimized window") { native.title == "Minimized \(origin)" }
                        native.deminiaturize(nil)
                        await wait("Native window restored") { !native.isMiniaturized && native.isVisible }
                        print("PASS \(host) \(origin) minimize, covered title and restore")
                    } else {
                        shared.update { _, tx in tx.setTitle("Checked \(origin)") }
                        await wait("Processed \(origin) request") { native.title == "Checked \(origin)" }
                        try? await Task.sleep(for: .milliseconds(70))
                        check(!native.isMiniaturized && native.isVisible, "\(kind) accepted \(origin) minimize")
                    }
                }
                if kind == "regular" {
                    handle.hide()
                    await wait("Window hidden before coalesced show") { !native.isVisible }
                    shared.update { _, tx in shared.show(); tx.minimize() }
                    await wait("Show takes effect before same-turn minimize") { native.isMiniaturized }
                }
                print("PASS \(host) \(kind) hidden title and minimize, Tx/AppHandle/WindowHandle eligibility")
                exit(0)
            }
        }
        if host == "single" {
            try app.run(arguments: [])
        } else {
            try RuneMultiWindow.runWindows([AppWindowSpec(app: app).boxed()], options: RunOptions(accessory: true), arguments: [])
        }
        check(false, "Event loop returned before the shell checks finished")
    }
}
