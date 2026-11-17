import Rune

struct Fields {
    var draft = TextEdit("")
    var secret = TextEdit("private-value")
}
func makeFields(_ state: Fields, _ cx: inout Cx<Fields>) -> El<Fields> {
    col().sizeFull().center().gap(18)
        .child(textInput(key: "draft", \.draft).label("Draft").size(240, 60))
        .child(textInput(key: "password", \.secret).secure(true).label("Secret").size(240, 60))
        .child(text(state.secret.text == "猫🐈" ? "Password edit confirmed" : "Editing"))
}
@_cdecl("ANativeActivity_onCreate")
public func startEditor(_ activity: UnsafeMutableRawPointer, _ state: UnsafeRawPointer?, _ bytes: Int) {
    let address = UInt(bitPattern: activity)
    MainActor.assumeIsolated {
        AndroidApp.attach(to: UnsafeMutableRawPointer(bitPattern: address)!, spec: AppSpec(title: "Rune IME", size: Vec2(320, 200), state: Fields(), view: makeFields))
    }
}
