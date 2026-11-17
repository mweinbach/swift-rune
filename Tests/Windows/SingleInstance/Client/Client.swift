import Foundation
import Rune

private final class Glue: IncomingURLGlue {
    func install() -> Bool { true }
    func handledElsewhere() -> Bool { false }
    func remove() {}
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [String] = []

    func append(_ event: String) {
        lock.lock()
        received.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

@main
enum HandoffClient {
    static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = CommandLine.arguments.dropFirst().first,
              let identifier = environment["RUNE_HANDOFF_TEST_ID"],
              let folder = environment["RUNE_HANDOFF_TEST_DIR"] else {
            throw FixtureError("Run this client with Tests/Windows/SingleInstance/Run.ps1")
        }
        let directory = URL(fileURLWithPath: folder)
        func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func mark(_ suffix: String) throws { try Data().write(to: file(mode + "." + suffix)) }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name).path) }
        func waitFor(_ name: String) throws {
            let end = ProcessInfo.processInfo.systemUptime + 30
            while !exists(name) {
                guard ProcessInfo.processInfo.systemUptime < end else {
                    throw FixtureError("Timed out waiting for " + name)
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        try mark("started")
        let primary = SingleInstance.claim(id: identifier)
        if mode == "send" {
            guard !primary else {
                SingleInstance.release()
                throw FixtureError("The launch opened a second owner")
            }
            return
        }

        guard primary, ["owner", "successor"].contains(mode) else {
            throw FixtureError("Expected to claim the instance as " + mode)
        }
        defer { SingleInstance.release() }
        let events = Events()
        let reopened = file(mode + ".reopened")
        SingleInstance.onRelaunch {
            events.append("reopen")
            try? Data().write(to: reopened)
            return true
        }
        let glue = Glue()
        IncomingURLInbox.shared.prepare(glue: glue)
        try mark("ready")
        if mode == "owner" { try waitFor("owner.listen") }
        guard let listener = IncomingURLInbox.shared.listen(glue: glue, sink: { events.append($0) }) else {
            throw FixtureError("Failed to install launch receiver")
        }
        defer { listener.cancel() }
        let required = mode == "owner" ? 4 : 1
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while events.snapshot().count < required {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw FixtureError("Missing launches: " + events.snapshot().description)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try mark("received")
        if mode == "owner" {
            try waitFor("owner.begin-quit")
            _ = QuitLifecycle.send(.start(ending: true, after: .exit))
            try mark("quitting")
        }
        try waitFor(mode + ".release")
        SingleInstance.release()
        try JSONEncoder().encode(events.snapshot()).write(to: file(mode + ".json"))
        try mark("released")
        try waitFor(mode + ".finish")
    }
}
