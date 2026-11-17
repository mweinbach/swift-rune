import Rune

@main
enum PopupSpelling {
    struct State {
        var edit = TextEdit("wrold")
    }

    @MainActor
    static func main() throws {
        SpellChecker.shared.setLanguages(["en-US"])
        let word = CommandLine.arguments.dropFirst().first ?? "wrold"
        try App(title: "Popup spelling probe", size: Vec2(360, 300), state: State(edit: TextEdit(word))) { _, _ in
            col().p(22).child(
                textInput(key: "word", \State.edit).label("Word").size(72, 36).spellcheck()
            )
        }.run(arguments: [])
    }
}
