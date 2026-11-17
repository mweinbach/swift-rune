import Foundation
import Rune

private final class Glue: IncomingURLGlue {
    func handledElsewhere() -> Bool { false }
    func install() -> Bool { true }
    func remove() {}
}

private func event(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

guard let id = ProcessInfo.processInfo.environment["RUNE_INSTANCE_TEST_ID"] else {
    fatalError("Run through verify.py with a private runtime directory")
}

event("claiming")
if ProcessInfo.processInfo.environment["RUNE_INSTANCE_TEST_GATE"] == "1" {
    precondition(readLine() == "begin")
}
if SingleInstance.claim(id: id) {
    defer { SingleInstance.release() }
    let glue = Glue()
    var listener: IncomingURLInbox.Listening?
    SingleInstance.onRelaunch {
        event("reopen")
        return true
    }
    IncomingURLInbox.shared.prepare(glue: glue)
    event("owner")
    while let command = readLine(), command != "exit" {
        switch command {
        case "listen":
            listener = IncomingURLInbox.shared.listen(glue: glue) { url in event("url " + url) }
            precondition(listener != nil)
            event("listening")
        case "quit":
            _ = QuitLifecycle.send(.start(ending: true, after: .exit))
            event("quitting")
        case "release":
            SingleInstance.release()
            event("released")
        default:
            fatalError("Unknown command")
        }
    }
    listener?.cancel()
} else {
    event("delivered")
}
