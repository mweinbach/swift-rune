import Testing
import RuneRef
@testable import Rune

@Suite("Spelling marks in rendered fields")
struct FieldSpellingPaintTests {
    private struct State {
        var edit: TextEdit
        var enabled = true
    }

    private func runtime(text: String, width: Float = 170) -> Runtime<State> {
        let rt = Runtime(state: State(edit: TextEdit(text, multiline: true)),
                         viewport: Vec2(width, 120), pixelScale: 2) { state, _ in
            textInput(key: "draft", \State.edit)
                .size(width, 120).p(4).font(TextStyle(size: 16).lh(22))
                .bg(.white).color(.black).spellcheck(state.enabled)
        }
        rt.fieldSpelling.checker = SpellChecker(backend: CustomDictionarySpellChecker(words: ["école", "and", "hello"]))
        return rt
    }

    private func marker(_ fill: SIMD4<Float>) -> Bool {
        fill.x > 0.9 && fill.y < 0.5 && fill.z < 0.5 && fill.w > 0.9
    }

    @Test("both painters align marks to shaped baselines, including multiple lines and multibyte prose")
    func pixelsAndGeometry() throws {
        let rt = runtime(text: "école typpoo\nécole otherr")
        let scene = rt.frame(at: 0)
        let native = rt.renderFrame(at: 0)
        let cpuMarks = scene.primitives.filter { marker($0.fill) }
        let gpuMarks = native.instances.filter { marker($0.fill) }
        #expect(!cpuMarks.isEmpty)
        #expect(cpuMarks.map(\.rect) == gpuMarks.map(\.rect))
        #expect(cpuMarks.map(\.radii) == gpuMarks.map(\.radii))
        let box = try #require(rt.nodeTextLayouts.values.first { $0.isInput }?.box)
        let baseline = try #require(box.shaped.lineBaselinesPx.first)
        let top = try #require(cpuMarks.map { $0.rect.y }.min())
        #expect(abs(top - (8 + baseline + 2)) <= 1)
        #if os(macOS)
        #expect(cpuMarks.allSatisfy { $0.rect.z == 6 && $0.rect.w == 6 && $0.radii.x == 3 })
        #expect(cpuMarks.count > 2 && cpuMarks[1].rect.x - cpuMarks[0].rect.x == 8)
        #else
        // The six 1pt wave phases at DPR 2, sampled once per device column.
        #expect(cpuMarks.allSatisfy { $0.rect.z == 1 && $0.rect.w == 2 && $0.radii.x == 0 })
        #expect(cpuMarks.prefix(12).map { $0.rect.y - top } == [0, 0, 2, 2, 4, 4, 4, 4, 2, 2, 0, 0])
        #endif
        #expect(cpuMarks.contains { $0.rect.y > top + 30 })
        // Every red pixel is to the right of the correctly spelled "école".
        func redPixels(_ frame: Frame) -> Set<Int> {
            var pixels = Set<Int>()
            for y in 0..<frame.height {
                for x in 0..<frame.width {
                    let p = frame.pixel(x: x, y: y)
                    if p.x > 200 && p.y < 110 && p.z < 110 { pixels.insert(y * frame.width + x) }
                }
            }
            return pixels
        }
        let cpu = redPixels(try RuneRef.render(scene))
        #expect(!cpu.isEmpty)
        #expect(cpu.allSatisfy { $0 % scene.width > 60 })
        #if canImport(Metal) || canImport(CRuneOffscreenGL)
        let hardware = try OffscreenGPURenderer()
        let gpu = redPixels(try hardware.renderOffscreen(native))
        #expect(!gpu.isEmpty)
        #expect(cpu.intersection(gpu).count * 100 >= max(cpu.count, gpu.count) * 95)
        #endif
    }

    @Test("a misspelling continues across soft wraps and scrolls with a one-line caret")
    func wrappingAndHorizontalScroll() {
        let bad = String(repeating: "x", count: 24)
        let checker = SpellChecker(backend: CustomDictionarySpellChecker(words: ["hello"]))
        let wrapped = Runtime(state: State(edit: TextEdit(bad, multiline: true)), viewport: Vec2(60, 120)) { _, _ in
            textInput(key: "wrapped", \State.edit).size(60, 120)
                .font(TextStyle(size: 14, family: .monospace, wrapAnywhere: true).lh(20)).spellcheck()
        }
        wrapped.fieldSpelling.checker = checker
        let marks = wrapped.frame(at: 0).primitives.filter { marker($0.fill) }
        #expect(Set(marks.map { Int($0.rect.y / 20) }).count >= 3)

        let single = Runtime(state: State(edit: TextEdit(bad + " " + String(repeating: "hello ", count: 70))),
                             viewport: Vec2(100, 40)) { _, _ in
            textInput(key: "one", \State.edit).size(100, 40).singleLine().spellcheck()
        }
        single.fieldSpelling.checker = checker
        #expect(single.renderFrame(at: 0).instances.contains { marker($0.fill) })
        single.update { _, tx in tx.focus("one") }
        #expect(!single.renderFrame(at: 0.1).instances.contains { marker($0.fill) })
        single.update { state, _ in state.edit.setSelectionRaw(anchor: 1, cursor: 1) }
        #expect(single.renderFrame(at: 0.2).instances.contains { marker($0.fill) })
    }

    #if os(macOS)
    @Test("AppKit cache preserves authored UTF-8 offsets and responds to document-scoped ignoring")
    func nativeDictionaryCache() {
        let checker = MacOSSpellChecker()
        #expect(SpellChecker(backend: checker).availableLanguages().isEmpty)
        let word = "qqzvxxppthk"
        for prefix in ["é ", "e\u{301} ", "é "] {
            let text = prefix + word
            let range = prefix.utf8.count..<text.utf8.count
            #expect(checker.misspelledUTF8Ranges(in: text).contains(range))
        }
        checker.ignoreWord(word)
        #expect(!checker.misspelledUTF8Ranges(in: "é " + word).contains(3..<(3 + word.utf8.count)))
    }
    #endif

    @Test("a newly focused empty field waits to mark its first typed word")
    func emptyFieldFocus() {
        let rt = runtime(text: "")
        _ = rt.frame(at: 0)
        rt.update { _, tx in tx.focus("draft") }
        _ = rt.frame(at: 0.1)
        rt.update { state, _ in state.edit.insert("speling") }
        #expect(rt.frame(at: 0.2).primitives.filter { marker($0.fill) }.isEmpty)
        #expect(rt.frame(at: 1.21).primitives.contains { marker($0.fill) })
    }

    @Test("typing suppresses only the active word until its wake, caret moves restore it, and secure or composing fields have no marks")
    func focusedPauseAndEligibility() throws {
        let rt = runtime(text: "wrng and badd")
        func count(_ t: Double) -> Int { rt.renderFrame(at: t).instances.filter { marker($0.fill) }.count }
        let all = count(0)
        #expect(all > 1)
        rt.update { _, tx in tx.focus("draft") }
        #expect(count(0.1) == all)
        rt.update { state, _ in state.edit.insert("x") }
        let typing = count(0.2)
        #expect(typing > 0 && typing < all)
        #expect(rt.fieldSpelling.watch?.wakeAt == 1.2)
        #expect(rt.nextWakeDeadline(after: 0.2).map { $0 <= 1.2 } == true)
        #expect(count(1.19) == typing)
        #expect(count(1.21) > typing)
        rt.update { state, _ in state.edit.insert("x") }
        #expect(count(1.3) == typing)
        rt.update { state, _ in state.edit.setSelectionRaw(anchor: 0, cursor: 0) }
        #expect(count(1.31) > typing)
        rt.update { state, _ in state.edit.preedit = ("é", nil) }
        #expect(count(1.32) == 0)
        rt.update { state, _ in state.edit.preedit = nil; state.edit.isSecure = true; state.edit.isRevealed = true }
        #expect(count(1.33) == 0)
        rt.update { state, _ in state.edit.isSecure = false; state.enabled = false }
        #expect(count(1.34) == 0)
    }
}
