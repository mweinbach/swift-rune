import Foundation
import Rune

private func report(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

// A tray-only app. No window or GLib main loop is required to deliver native callbacks.
private final class Probe: @unchecked Sendable {
    let resumeCallback = DispatchSemaphore(value: 0)
    lazy var tray: SystemTray = SystemTray(spec: TraySpec(
        id: "org.rune.TrayProbe", title: "Rune tray probe", tooltip: "First tooltip",
        iconName: "rune-test-symbolic",
        icon: TrayIcon(width: 2, height: 1, rgba: Data([1, 2, 3, 4, 16, 32, 48, 255])),
        menu: [.action(id: "open", label: "Open"), .separator, .action(id: "blocked", label: "Disabled").enabled(false)]
    )) { [weak self] event in
        switch event {
        case .activate(let token):
            report("ACTIVATE " + (token ?? "<nil>"))
        case .menu(let id):
            report("MENU " + id)
            guard let self else { return }
            if id == "order" {
                precondition(self.resumeCallback.wait(timeout: .now() + 5) == .success)
                self.tray.setTooltip("Callback last")
                report("CALLBACK UPDATED")
            } else if id == "hide" {
                self.tray.removeNative()
                report(self.tray.isVisible ? "STILL VISIBLE" : "HIDDEN FROM CALLBACK")
            }
        }
    }

    func show() throws {
        try tray.showNative().get()
        precondition(tray.isVisible)
        report("VISIBLE")
    }

    func replaceMenu() {
        let menu: [TrayItem] = [.action(id: "hide", label: "Hide from callback"),
                                .action(id: "next", label: "Next"), .action(id: "order", label: "Order")]
        tray.setMenu(menu)
        precondition(tray.spec.menu == menu)
        report("MENU UPDATED")
    }

    func changePixels(_ icon: TrayIcon?) {
        var spec = tray.spec
        spec.icon = icon
        tray.update(spec)
        precondition(tray.spec.icon == icon)
        report("ICON UPDATED")
    }
}

if CommandLine.arguments.contains("--expect-open-failure") {
    let probe = Probe()
    switch probe.tray.showNative() {
    case .success: fatalError("Opened a tray without an authenticated session bus")
    case .failure(.backend(let reason)):
        precondition(!reason.isEmpty && !probe.tray.isVisible)
    case .failure(.unsupported): fatalError("The Linux backend was unavailable")
    }
    report("OPEN FAILED")
    exit(0)
}

private var probe: Probe? = Probe()
try probe!.show()
while let command = readLine() {
    switch command {
    case "menu": probe!.replaceMenu()
    case "tooltip":
        probe!.tray.setTooltip("Updated tooltip")
        report("TOOLTIP UPDATED")
    case "replace-icon": probe!.changePixels(TrayIcon(width: 1, height: 1, rgba: Data([6, 10, 80, 100])))
    case "clear-icon": probe!.changePixels(nil)
    case "queue-tooltip":
        probe!.tray.setTooltip("External first")
        report("QUEUED")
        probe!.resumeCallback.signal()
    case "show": try probe!.show()
    case "remove":
        probe!.tray.removeNative()
        precondition(!probe!.tray.isVisible)
        report("REMOVED")
    case "drop":
        probe = nil
        report("DROPPED")
    case "ping": report("PONG")
    default: fatalError("Unexpected command " + command)
    }
}
