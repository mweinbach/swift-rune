import Dispatch
import Foundation
import RuneNotify

guard CommandLine.arguments.count == 4 else { fatalError("Expected operation, AUMID and activation scheme") }
let operation = CommandLine.arguments[1]
if operation == "wait" || operation == "serve" {
    let clsid = CommandLine.arguments[2]
    let ready = URL(fileURLWithPath: CommandLine.arguments[3])
    let check: @Sendable (NotificationClick?) -> Void = { click in
        precondition(click?.id == "one" && click?.action == "reply")
        precondition(click?.get("session") == "chat" && click?.input(for: "reply") == "Réponse 世界")
    }
    if operation == "wait" {
        try Data().write(to: ready)
        check(RuneNotify.waitActivation(clsid, timeout: 20))
    } else {
        let completed = DispatchSemaphore(value: 0)
        RuneNotify.onClick { click in
            check(click)
            completed.signal()
        }
        try RuneNotify.serveActivations(clsid).get()
        try Data().write(to: ready)
        precondition(completed.wait(timeout: .now() + 20) == .success)
    }
} else {
    let identity = NotificationIdentity(id: CommandLine.arguments[2], name: "Rune Toast Test", activationScheme: CommandLine.arguments[3])
    let id = "item/🦦"
    precondition(!RuneNotify.isAvailable)
    if operation == "remove" {
        try RuneNotify.adoptWithResult(identity).get()
        RuneNotify.remove(ids: [id])
    } else {
        try RuneNotify.registerWithResult(identity).get()
        precondition(RuneNotify.isAvailable)
        let note = Notification(id: id, title: operation == "first" ? "First" : "Updated")
            .body("Unicode 🦦 & XML <content>")
            .action(id: "more", label: "Details")
            .reply(id: "reply", placeholder: "Your answer", label: "Reply")
            .urgency(.passive)
        precondition(RuneNotify.post(note))
        let url = "\(identity.activationScheme!)://notification/item%2F%F0%9F%A6%A6?session=a%2Bb"
        let click = RuneNotify.clickFromURL(url)
        precondition(click?.id == id && click?.get("session") == "a+b")
    }
}
print("RuneNotify Swift \(operation) OK")
