import Rune

struct Fields {
    var modalOpen = false
    var editor = TextEdit("A\u{1F680}e\u{0301}Z")
    var password = TextEdit("fixture-only-secret")
    var revision = TextEdit("a\nbefore target after", multiline: true)
    var document = TextEdit("🚀e\u{0301}\n" + String(repeating: String(repeating: "0123456789abcdef", count: 64) + "\n", count: 64) + "End",
                            multiline: true)

    init() {
        editor.moveLeft(extend: true)
        document.setCursor(utf8Offset: 0)
        document.setCursor(utf8Offset: 4, extendSelection: true)
    }
}

func view(_ fields: Fields, _: inout Cx<Fields>) -> El<Fields> {
    if fields.modalOpen {
        return col().key("modal-root").child(
            col().key("modal-dialog").role(.dialog).modal().label("Confirm choices")
        )
    }
    let editor: El<Fields> = textInput(key: "editor", \.editor)
        .label("Editor").wFull().h(48).shrink(0).p(8)
    let password: El<Fields> = textInput(key: "password", \.password)
        .secure().label("Password").wFull().h(48).shrink(0).p(8)
    let document: El<Fields> = textInput(key: "document", \.document)
        .label("Long document").wFull().h(64).shrink(0).p(8)
    let section: El<Fields> = col().key("section").role(.region).label("Document section").h(1000).shrink(0)
        .child(text("Document").key("heading").headingLevel(3))
        .child(textInput(key: "revision", \.revision).label("Revisions").wFull().h(64).shrink(0).p(4))
        .child(col().key("modeless-dialog").role(.dialog).label("Preferences"))
        .child(col().key("alert-dialog").role(.alertDialog).label("Review warning"))
        .child(col().key("scroll-pane").h(20).scrollY().child(text("Scrollable details").h(40)))
        .child(el().key("open-modal").role(.button).label("Confirm").focusable().onClick { $0.modalOpen = true })
    return col().key("scroll").role(.main).sizeFull().scrollY().p(8).gap(8)
        .child(editor).child(password).child(section).child(document)
}

try RuneApp.run(AppSpec(title: "Rune UI Automation text fixture", size: Vec2(400, 160),
                        state: Fields(), view: view))
