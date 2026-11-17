import Foundation
import Rune

#if os(WASI) && RUNE_BROWSER_TEXT
private struct SpellState {
    var edit = TextEdit("café cafés Kinder walking 🤖 teh       züber https://teh.example/a SOME foo_bar")

    init() {
        edit.spellcheckEnabled = true
    }

    var spelling: (ranges: [Range<Int>], replacements: [String]) {
        let ranges = edit.misspelledUTF8Ranges()
        guard let first = ranges.first,
              let result = edit.spellingSuggestions(atUTF8Offset: first.lowerBound) else { return (ranges, []) }
        return (ranges, result.suggestions)
    }
}

private struct Report: Encodable {
    let ranges: [[Int]]
    let replacements: [String]
    let text: String
    let languages: [String]
}

SpellChecker.shared.setWebDictionaries(["en-US", "de", "fr"])
SpellChecker.shared.setLanguages(["en-US", "de", "fr"])
private let app = AppSpec(title: "Rune browser spelling", size: Vec2(640, 112), state: SpellState()) { state, _ in
    let (ranges, replacements) = state.spelling
    let report = Report(ranges: ranges.map { [$0.lowerBound, $0.upperBound] }, replacements: replacements,
                        text: state.edit.text, languages: SpellChecker.shared.languages())
    if let data = try? JSONEncoder().encode(report) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
    let field = textInput(key: "document", \SpellState.edit)
        .spellcheck().label("Document").color(.black).wFull().h(40)
    return col().sizeFull().bg(.white).child(field).child(menuProbe())
}
try RuneApp.run(app)
#else
print("Build rune-spell-probe for WASI and open the spell-wasi browser fixture.")
#endif
