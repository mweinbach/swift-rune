import Foundation
import Rune

@main
enum HandoffHost {
    @MainActor
    static func main() throws {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["RUNE_HANDOFF_TEST_ID"], let directory = env["RUNE_HANDOFF_TEST_DIR"] else {
            throw CocoaError(.fileNoSuchFile)
        }
        let args = Array(CommandLine.arguments.dropFirst())
        guard SingleInstance.claim(id: id) else { return }
        defer { SingleInstance.release() }

        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        if let mode = args.first, mode == "relaunch-tx" || mode == "relaunch-handle" {
            try runRelaunch(mode, folder: folder)
            return
        }
        guard args.first == "owner" else { throw CocoaError(.fileReadUnknown) }
        var eventCount = 0
        func record(_ event: String) {
            eventCount += 1
            let name = String(format: "host-%04d.event", eventCount)
            try! Data(event.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
        }
        record("claimed")
        let start = folder.appendingPathComponent("host.start")
        let deadline = ProcessInfo.processInfo.systemUptime + 40
        while !FileManager.default.fileExists(atPath: start.path) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.fileNoSuchFile) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        var window: WindowHandle?
        let app = App(title: "Rune single-instance \(id)", size: Vec2(240, 160), state: 0) { _, _ in
            el().sizeFull()
        }.onWindow { handle in
            window = handle
            record("created")
        }.onReady { _ in
            record("ready")
        }.onOpenUrl { _, url, tx in
            record(url)
            if url == "rune-check://hide" { window?.hide() }
            if url == "rune-check://quit" { tx.quit() }
        }.onReopen { _, visible, _ in
            record("reopen \(visible)")
            return false
        }
        try app.run()
        record("ended")
    }

    @MainActor
    private static func runRelaunch(_ mode: String, folder: URL) throws {
        let env = ProcessInfo.processInfo.environment
        let previous = env[RelaunchController.afterEnvVar].flatMap(UInt32.init)
        let current = ProcessInfo.processInfo.processIdentifier
        var control: AppHandle<Int>?
        let app = App(title: mode, size: Vec2(180, 120), state: 0) { _, _ in el().sizeFull() }.onReady { _ in
            if let previous {
                let text = "\(current) \(previous) \(RelaunchController.isProcessAlive(previous))"
                try! Data(text.utf8).write(to: folder.appendingPathComponent(mode + ".successor"), options: .atomic)
                control?.quit()
            } else if mode == "relaunch-tx" {
                control?.update { _, tx in tx.relaunch() }
            } else {
                control?.relaunch()
            }
        }
        control = app.handle()
        try app.run()
    }
}
