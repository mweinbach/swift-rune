#if os(Windows) || os(Linux)
import Testing
@testable import Rune

@Suite struct DesktopSpellCheckerTests {
    @Test func nativeDictionaryPreservesByteOffsetsAndSessionIgnores() {
        let backend = DesktopSpellChecker()
        let checker = SpellChecker(backend: backend)
        #expect(checker.availableLanguages() == backend.installedLanguages)
        guard let english = backend.installedLanguages.first(where: { $0 == "en-US" })
            ?? backend.installedLanguages.first(where: { $0.hasPrefix("en") }) else {
            // A machine with no dictionaries still has the deterministic backend.
            if backend.installedLanguages.isEmpty {
                #expect(checker.misspelledUTF8Ranges(in: "hello qzzjxvv") == [6..<13])
            }
            return
        }
        checker.setLanguages([english.uppercased()])
        #expect(checker.languages() == [english])
        let text = "dictionary 🦦 qzzjxvv\nqzzjxvv\u{0}qzzjxvv"
        #expect(checker.misspelledUTF8Ranges(in: text) == [16..<23, 24..<31, 32..<39])
        #expect(!checker.suggestions(for: "speling").isEmpty)
        checker.ignoreWord("qzzjxvv")
        #expect(checker.misspelledUTF8Ranges(in: text).isEmpty)
    }
}
#endif
