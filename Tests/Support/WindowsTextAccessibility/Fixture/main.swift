import Rune

struct Fields {
    var editor = TextEdit("A\u{1F680}e\u{0301}Z")
    var password = TextEdit("fixture-only-secret")

    init() {
        editor.moveLeft(extend: true)
    }
}

func view(_: Fields, _: inout Cx<Fields>) -> El<Fields> {
    let editor: El<Fields> = textInput(key: "editor", \.editor)
        .label("Editor").wFull().h(48).p(8)
    let password: El<Fields> = textInput(key: "password", \.password)
        .secure().label("Password").wFull().h(48).p(8)
    return col().sizeFull().p(8).gap(8).child(editor).child(password)
}

try RuneApp.run(AppSpec(title: "Rune UI Automation text fixture", size: Vec2(400, 160),
                        state: Fields(), view: view))
