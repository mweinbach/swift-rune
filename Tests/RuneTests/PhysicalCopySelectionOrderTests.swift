import Testing
@testable import Rune

@Suite("Physical copy after programmatic selection")
struct PhysicalCopySelectionOrderTests {
    @Test func sameFrameCopyReadsTheSelection() {
        struct State { var seen: String? }
        let runtime = Runtime(state: State(), viewport: Vec2(320, 120), pixelScale: 2) { _, _ in
            col().key("root").w(300).p(10).focusable()
                .onPhysicalInput { state, _, tx in
                    state.seen = tx.textSelection()?.text
                    return false
                }
                .child(text("lone text here").key("lone").font(TextStyle(size: 14, weight: 400)).wFull().selectable())
        }
        _ = runtime.frame(at: 0)
        let clipboard = Clipboard(kind: .memory)
        runtime.useClipboard(clipboard)
        runtime.update { _, tx in tx.focus("root") }
        runtime.update { _, tx in tx.selectText("lone", range: 5..<9) }
        let mods = RuneTestKey.primaryMods()
        _ = runtime.physicalWithFallback(
            .key(key: .keyC, mods: mods, pressed: true, repeat: false),
            fallbackKey: KeyEvent(key: .command("c"), mods: mods), at: 0
        )
        _ = runtime.frame(at: 1.0 / 60)
        #expect(runtime.state.seen == "text")
        #expect(clipboard.readRich().content.text == "text")
    }
}
