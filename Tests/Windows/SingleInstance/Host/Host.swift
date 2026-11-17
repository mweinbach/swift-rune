import Foundation
import Rune
#if os(Windows)
import WinSDK
#endif

@main
enum HandoffHost {
    @MainActor
    static func main() throws {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["RUNE_HANDOFF_TEST_ID"], let directory = env["RUNE_HANDOFF_TEST_DIR"] else {
            throw CocoaError(.fileNoSuchFile)
        }
        let args = Array(CommandLine.arguments.dropFirst())
        let claimStarted = ProcessInfo.processInfo.systemUptime
        guard SingleInstance.claim(id: id) else { return }
        defer { SingleInstance.release() }

        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        if let mode = args.first, mode == "relaunch-tx" || mode == "relaunch-handle" {
            try runRelaunch(mode, folder: folder)
            return
        }
        guard args.first == "owner" else {
            let duration = (ProcessInfo.processInfo.systemUptime - claimStarted) * 1000
            let message = "Unexpected owner: \(id) pid=\(ProcessInfo.processInfo.processIdentifier) claim_ms=\(duration)\n"
            FileHandle.standardError.write(Data(message.utf8))
            #if os(Windows)
            let matching = pipeNames(for: id).joined(separator: ", ")
            FileHandle.standardError.write(Data("Matching pipes: \(matching)\n".utf8))
            SingleInstance.release()
            ExitProcess(42)
            #else
            throw CocoaError(.fileReadUnknown)
            #endif
        }
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

    #if os(Windows)
    private static func pipeNames(for id: String) -> [String] {
        var data = WIN32_FIND_DATAW()
        let search = Array("\\\\.\\pipe\\*".utf16) + [0]
        let handle = search.withUnsafeBufferPointer { FindFirstFileW($0.baseAddress, &data) }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return [] }
        defer { FindClose(handle) }
        var matches: [String] = []
        repeat {
            let name = withUnsafeBytes(of: &data.cFileName) {
                String(decodingCString: $0.bindMemory(to: UInt16.self).baseAddress!, as: UTF16.self)
            }
            if name.contains(id) { matches.append(name) }
        } while FindNextFileW(handle, &data)
        return matches
    }
    #endif

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
