import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Rune

@Suite("Phase 2 Text Parity Tests (#895, #882, #919, #896, #880, #853)", .serialized)
struct Phase2TextParityTests {

    // MARK: - #895: MacOSHinter post-table glyph lookup and autohinting

    private static func makePostHeader(version: UInt32, extra: [UInt8] = []) -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = UInt8((version >> 24) & 0xFF)
        bytes[1] = UInt8((version >> 16) & 0xFF)
        bytes[2] = UInt8((version >> 8) & 0xFF)
        bytes[3] = UInt8(version & 0xFF)
        bytes.append(contentsOf: extra)
        return Data(bytes)
    }

    private static func encodePostFormat2(indices: [UInt16], customNames: [String]) -> Data {
        var extra: [UInt8] = []
        let n = UInt16(indices.count)
        extra.append(UInt8(n >> 8))
        extra.append(UInt8(n & 0xFF))
        for idx in indices {
            extra.append(UInt8(idx >> 8))
            extra.append(UInt8(idx & 0xFF))
        }
        for name in customNames {
            let utf8 = Array(name.utf8)
            extra.append(UInt8(utf8.count))
            extra.append(contentsOf: utf8)
        }
        return makePostHeader(version: 0x00020000, extra: extra)
    }

    @Test("#895: postGlyph resolves format 1.0, format 2.0 standard & custom names, and rejects format 3.0")
    func postTableGlyphLookup() {
        // Format 1.0 uses standard Macintosh ordering directly ('o' = 82, 'X' = 59).
        let fmt1 = Self.makePostHeader(version: 0x00010000)
        #expect(MacOSHinter.postGlyph(inPostTable: fmt1, standard: MacOSHinter.standardGlyphO.standard, name: "o") == 82)
        #expect(MacOSHinter.postGlyph(inPostTable: fmt1, standard: MacOSHinter.standardGlyphX.standard, name: "X") == 59)

        // Format 2.0 with standard MacRoman slot (82 at glyph 5) and custom Pascal name ("X" at slot 258 -> glyph 7).
        let fmt2 = Self.encodePostFormat2(
            indices: [0, 1, 2, 3, 4, 82, 6, 258],
            customNames: ["X"]
        )
        #expect(MacOSHinter.postGlyph(inPostTable: fmt2, standard: MacOSHinter.standardGlyphO.standard, name: "o") == 5)
        #expect(MacOSHinter.postGlyph(inPostTable: fmt2, standard: MacOSHinter.standardGlyphX.standard, name: "X") == 7)

        // Format 2.0 custom Pascal names for both 'o' and 'X'.
        let fmt2Custom = Self.encodePostFormat2(
            indices: [0, 259, 258],
            customNames: ["o", "X"]
        )
        #expect(MacOSHinter.postGlyph(inPostTable: fmt2Custom, standard: 82, name: "o") == 2)
        #expect(MacOSHinter.postGlyph(inPostTable: fmt2Custom, standard: 59, name: "X") == 1)

        // Format 3.0 has no glyph names -> must return nil (no cmap fallback).
        let fmt3 = Self.makePostHeader(version: 0x00030000)
        #expect(MacOSHinter.postGlyph(inPostTable: fmt3, standard: 82, name: "o") == nil)
        #expect(MacOSHinter.postGlyph(inPostTable: fmt3, standard: 59, name: "X") == nil)
    }

    @Test("#895: trueTypeMetrics and autohint evaluate bundled Inter TrueType font")
    func trueTypeMetricsAndAutohint() throws {
        #expect(DefaultFonts.registerIfNeeded())
        #expect(MacOSHinter.eligible(ppem: 7.0))
        #expect(MacOSHinter.eligible(ppem: 18.0))
        #expect(!MacOSHinter.eligible(ppem: 6.0))
        #expect(!MacOSHinter.eligible(ppem: 19.0))
        #expect(!MacOSHinter.eligible(ppem: 12.5))

        let ts = TextSystem()
        let ctFont = ts.resolveCTFont(style: TextStyle(size: 13, weight: 400), pixelScale: 1)
        let metrics = try #require(MacOSHinter.trueTypeMetrics(font: ctFont))
        #expect(metrics.upem > 0)
        #expect(metrics.xHeight > 0)
        #expect(metrics.capHeight > metrics.xHeight)

        let tx = try #require(MacOSHinter.autohint(metrics, ppem: 14.0, d: 0.25))
        #expect(tx.values.count == 11)
        #expect(tx.apply(0) == 0)

        var flatMetrics = metrics
        flatMetrics.capHeight = flatMetrics.xHeight
        #expect(MacOSHinter.autohint(flatMetrics, ppem: 14.0, d: 0.25) == nil)
        #expect(MacOSHinter.autohint(metrics, ppem: 20.0, d: 0.25) == nil)
    }

    // MARK: - #882 & #919: Pretty wrapping + isolate guard + El.wrapGreedy

    /// Finds a width where greedy breaking leaves only the final short word alone on the last line.
    private static func findOrphanWidth(ts: TextSystem, paragraph: String, style: TextStyle) -> Float? {
        for wInt in stride(from: 130, through: 340, by: 2) {
            let w = Float(wInt)
            let s = ts.shape(text: paragraph, style: style, maxWidth: w, pixelScale: 1.0, emitGlyphs: false, pretty: false)
            if s.lineCount >= 3, let lastStr = s.lineStrings.last?.text {
                let lastText = lastStr.trimmingCharacters(in: .whitespacesAndNewlines)
                let lastW = s.lineAdvancePx(at: s.lineCount - 1)
                if !lastText.contains(" "), !lastText.isEmpty, lastW < (w / 3.0) {
                    return w
                }
            }
        }
        return nil
    }

    @Test("#882 & #919: prettyWrap eliminates orphan last words, preserves line count, and keeps trailing isolates greedy")
    func prettyWrapAndIsolateGuard() throws {
        defer { TextSystem.setPrettyWrap(false) }

        let ts = TextSystem()
        let style = TextStyle(size: 14, weight: 400).wrapped()
        let paragraph = "Careful typography avoids leaving a single short trailing word alone at the bottom of a long paragraph."
        let width = try #require(Self.findOrphanWidth(ts: ts, paragraph: paragraph, style: style))

        let greedy = ts.shape(text: paragraph, style: style, maxWidth: width, pixelScale: 1.0, emitGlyphs: false, pretty: false)
        let lastGreedyWords = (greedy.lineStrings.last?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        #expect(lastGreedyWords.count == 1)

        TextSystem.setPrettyWrap(true)
        let pretty = ts.shape(text: paragraph, style: style, maxWidth: width, pixelScale: 1.0, emitGlyphs: false, pretty: true)
        #expect(pretty.lineCount == greedy.lineCount)
        let lastPrettyWords = (pretty.lineStrings.last?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        #expect(lastPrettyWords.count >= 2, "Expected pretty wrap to pull another word down onto last line, got: \(pretty.lineStrings.map(\.text))")

        // Trailing bidi isolate (\u{2066}...\u{2069}) keeps the paragraph greedy (#919).
        let isolateTailPara = "Careful typography avoids leaving a single short trailing word alone at the bottom of a long \u{2066}end.\u{2069}"
        let isoW = try #require(Self.findOrphanWidth(ts: ts, paragraph: isolateTailPara, style: style))
        let isoGreedy = ts.shape(text: isolateTailPara, style: style, maxWidth: isoW, pixelScale: 1.0, emitGlyphs: false, pretty: false)
        let isoPretty = ts.shape(text: isolateTailPara, style: style, maxWidth: isoW, pixelScale: 1.0, emitGlyphs: false, pretty: true)
        #expect(isoPretty.lineCount == isoGreedy.lineCount)
        #expect(isoPretty.lineStrings.map(\.text) == isoGreedy.lineStrings.map(\.text))

        // Isolate on an earlier line (NOT the last line) still allows pretty wrap.
        let isolateEarlyPara = "Careful \u{2066}typesetting\u{2069} avoids leaving a single short trailing word alone at the bottom of a long paragraph."
        let earlyW = try #require(Self.findOrphanWidth(ts: ts, paragraph: isolateEarlyPara, style: style))
        let earlyGreedy = ts.shape(text: isolateEarlyPara, style: style, maxWidth: earlyW, pixelScale: 1.0, emitGlyphs: false, pretty: false)
        let earlyPretty = ts.shape(text: isolateEarlyPara, style: style, maxWidth: earlyW, pixelScale: 1.0, emitGlyphs: false, pretty: true)
        #expect(earlyPretty.lineCount == earlyGreedy.lineCount)
        let earlyLastWords = (earlyPretty.lineStrings.last?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        #expect(earlyLastWords.count >= 2)
    }

    @Test("#882: El.wrapGreedy opts text elements out of global setPrettyWrap(true)")
    @MainActor
    func elWrapGreedyOptOut() throws {
        defer { TextSystem.setPrettyWrap(false) }

        let ts = TextSystem()
        let style = TextStyle(size: 14, weight: 400).wrapped()
        let paragraph = "Careful typography avoids leaving a single short trailing word alone at the bottom of a long paragraph."
        let width = try #require(Self.findOrphanWidth(ts: ts, paragraph: paragraph, style: style))

        TextSystem.setPrettyWrap(true)
        let baseEl: El<Int> = Rune.text(paragraph)
        let prettyEl = baseEl.font(style).w(width)
        let greedyEl = baseEl.font(style).wrapGreedy().w(width)

        let resPretty = ElDisplayResolver.resolveText(el: prettyEl, rawText: paragraph, isSecure: false)
        let resGreedy = ElDisplayResolver.resolveText(el: greedyEl, rawText: paragraph, isSecure: false)
        #expect(resPretty.pretty == true)
        #expect(resGreedy.pretty == false)

        let shapedPretty = resPretty.shape(using: ts, maxWidth: width, pixelScale: 1.0, emitGlyphs: false)
        let shapedGreedy = resGreedy.shape(using: ts, maxWidth: width, pixelScale: 1.0, emitGlyphs: false)
        #expect(shapedPretty.lineCount == shapedGreedy.lineCount)
        let greedyWords = (shapedGreedy.lineStrings.last?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        let prettyWords = (shapedPretty.lineStrings.last?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        #expect(greedyWords.count == 1)
        #expect(prettyWords.count >= 2)
    }

    @Test("#882 x text_rebreak: layoutKeyed breaks pretty, keeps pretty and greedy layouts in separate cache entries, and re-breaks pretty")
    func prettyWrapThroughRetainedLayoutCache() throws {
        let ts = TextSystem()
        let style = TextStyle(size: 14, weight: 400).wrapped()
        let paragraph = "Careful typography avoids leaving a single short trailing word alone at the bottom of a long paragraph."
        let width = try #require(Self.findOrphanWidth(ts: ts, paragraph: paragraph, style: style))

        let greedyBox = ts.layoutKeyed(text: paragraph, style: style, maxWidth: width, pixelScale: 1.0, emitGlyphs: false, pretty: false)
        let prettyBox = ts.layoutKeyed(text: paragraph, style: style, maxWidth: width, pixelScale: 1.0, emitGlyphs: false, pretty: true)
        #expect(greedyBox.shapeKey != prettyBox.shapeKey)
        #expect(prettyBox.shapeKey.pretty)
        #expect(ts.cachedLayoutBox(for: greedyBox.shapeKey) === greedyBox)
        #expect(ts.cachedLayoutBox(for: prettyBox.shapeKey) === prettyBox)

        let greedyLast = (greedyBox.shaped.lineStrings.last?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        let prettyLast = (prettyBox.shaped.lineStrings.last?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        #expect(greedyLast.count == 1)
        #expect(prettyLast.count >= 2)
        #expect(prettyBox.shaped.lineCount == greedyBox.shaped.lineCount)

        // The retained pretty layout matches the one-shot pretty shape/measure paths.
        let shapedPretty = ts.shape(text: paragraph, style: style, maxWidth: width, pixelScale: 1.0, emitGlyphs: false, pretty: true)
        #expect(shapedPretty.lineStrings.map(\.text) == prettyBox.shaped.lineStrings.map(\.text))
        #expect(ts.measure(paragraph, style: style, maxWidth: width, pixelScale: 1.0, pretty: true) == prettyBox.shaped.size)

        // A glyph fill of the cached pretty layout stays pretty.
        let filled = ts.layoutKeyed(text: paragraph, style: style, maxWidth: width, pixelScale: 1.0, emitGlyphs: true, pretty: true)
        #expect(filled.shaped.lineStrings.map(\.text) == prettyBox.shaped.lineStrings.map(\.text))

        // Re-breaking the retained pretty layout at another width stays pretty.
        let width2 = width + 1
        let rebroken = ts.layoutKeyed(text: paragraph, style: style, maxWidth: width2, pixelScale: 1.0, emitGlyphs: false, pretty: true)
        let freshPretty = TextSystem().shape(text: paragraph, style: style, maxWidth: width2, pixelScale: 1.0, emitGlyphs: false, pretty: true)
        #expect(rebroken.shapeKey.pretty)
        #expect(rebroken.shaped.lineStrings.map(\.text) == freshPretty.lineStrings.map(\.text))
    }

    // MARK: - #896: El.placeholderFont & InputSpec.placeholderStyle

    @Test("#896: El.placeholderFont and InputSpec.placeholderStyle lay placeholders out in their own style")
    @MainActor
    func placeholderFontLayoutAndRender() {
        struct State {
            var edit: TextEdit
        }
        let fieldFont = TextStyle(size: 12, weight: 400)
        let phFont = TextStyle(size: 28, weight: 600)

        let rt = Runtime(state: State(edit: TextEdit("", multiline: false)), viewport: Vec2(400, 120)) { _, _ in
            El<State>(direction: .column).child(
                textInput(
                    key: "fld",
                    \State.edit,
                    spec: InputSpec(
                        placeholder: "Ask",
                        placeholderColor: Color.srgb(0.6, 0.6, 0.6),
                        placeholderStyle: phFont,
                        singleLine: true
                    )
                )
                .font(fieldFont)
                .placeholderFont(phFont)
                .w(240)
            )
        }
        let phScene = rt.frame(at: 0)
        let phGlyphHeights = phScene.primitives.filter { $0.kind == .glyph }.map { $0.rect.w }
        let maxPhGlyphH = phGlyphHeights.max() ?? 0
        #expect(!phGlyphHeights.isEmpty)

        rt.state.edit = TextEdit("Ask", multiline: false)
        let txtScene = rt.frame(at: 1.0 / 60.0)
        let txtGlyphHeights = txtScene.primitives.filter { $0.kind == .glyph }.map { $0.rect.w }
        let maxTxtGlyphH = txtGlyphHeights.max() ?? 0
        #expect(!txtGlyphHeights.isEmpty)
        #expect(maxPhGlyphH > maxTxtGlyphH * 1.6, "Expected 28pt placeholder glyphs (\(maxPhGlyphH)) significantly taller than 12pt text glyphs (\(maxTxtGlyphH))")
    }

    // MARK: - #880: TextEdit persistent JSON undo/redo history

    @Test("#880: TextEdit historyJson and restoreHistoryJson roundtrip, catchup, budgets, and safety rejections")
    func historyJsonPersistence() throws {
        // Empty and secure fields produce/accept nothing.
        var emptyEdit = TextEdit("")
        #expect(emptyEdit.historyLen() == (0, 0))
        #expect(emptyEdit.historyJson(maxSteps: 16, maxBytes: 4096) == nil)
        let emptyRestore = emptyEdit.restoreHistoryJson(Data("{\"v\":1,\"undo\":[],\"redo\":[]}".utf8))
        #expect(!emptyRestore)

        var sec = TextEdit("s")
        sec.isSecure = true
        sec.insert("ecret")
        #expect(sec.historyLen() == (0, 0))
        #expect(sec.historyJson(maxSteps: 16, maxBytes: 4096) == nil)
        let secRestore = sec.restoreHistoryJson(Data("{\"v\":1,\"undo\":[],\"redo\":[]}".utf8))
        #expect(!secRestore)

        // Build rich + multi-block history with both undo & redo steps.
        var a = TextEdit("", multiline: true).rich()
        a.insert("hello")
        a.breakHistoryGroup()
        a.setSelectionRaw(anchor: 0, cursor: 5)
        a.toggleMark(.bold)
        a.breakHistoryGroup()
        a.setBlock(.bullet(0))
        a.breakHistoryGroup()
        a.setCursor(utf8Offset: 5)
        a.insert(" world")
        a.breakHistoryGroup()
        a.insertPill(id: "p1", label: "@doc")
        a.breakHistoryGroup()
        let didUndoPill = a.undo()
        #expect(didUndoPill)
        let (uCount, rCount) = a.historyLen()
        #expect(uCount >= 3 && rCount == 1)

        let saved = try #require(a.historyJson(maxSteps: 32, maxBytes: 64 * 1024))

        // Restore into a cold field holding the matching saved draft (with empty history).
        var b = TextEdit(a.text, multiline: true).rich()
        b.setSelectionRaw(anchor: 0, cursor: a.text.utf8.count)
        b.toggleMark(.bold)
        b.setBlock(.bullet(0))
        b.clearHistory()
        b.setSelectionRaw(anchor: a.anchor, cursor: a.cursor)
        let bRestored = b.restoreHistoryJson(saved)
        #expect(bRestored)
        #expect(b.historyLen() == (uCount, rCount))

        // Redo restores the pill; undo steps cleanly back through blocks & marks.
        let bRedid = b.redo()
        #expect(bRedid)
        #expect(b.pills.count == 1)
        #expect(b.text == "hello world@doc")
        while b.undo() {}
        #expect(b.text.isEmpty)

        // All-undone (redo-only) roundtrip also restores cleanly via `parsedRedo.last?.before`.
        let redoOnlySaved = try #require(b.historyJson(maxSteps: 32, maxBytes: 64 * 1024))
        var redoOnlyTarget = TextEdit("", multiline: true).rich()
        let redoOnlyOk = redoOnlyTarget.restoreHistoryJson(redoOnlySaved)
        #expect(redoOnlyOk)
        #expect(redoOnlyTarget.historyLen().undo == 0 && redoOnlyTarget.historyLen().redo == uCount + rCount)
        let redoStepOk = redoOnlyTarget.redo()
        #expect(redoStepOk)
        #expect(!redoOnlyTarget.text.isEmpty)

        // Saved-early catchup: history ended at "hello world" (a.text), current draft moved to "hello world!".
        var c = TextEdit(a.text, multiline: true).rich()
        c.setSelectionRaw(anchor: 0, cursor: a.text.utf8.count)
        c.toggleMark(.bold)
        c.setBlock(.bullet(0))
        c.clearHistory()
        c.setCursor(utf8Offset: a.text.utf8.count)
        c.insert("!")
        let cRestored = c.restoreHistoryJson(saved)
        #expect(cRestored)
        #expect(c.historyLen().redo == 0)
        let cUndid = c.undo()
        #expect(cUndid)
        #expect(c.text == "hello world")

        // Same text with mismatched formatting must be rejected (`last.text == now.text`).
        var sameTextPlain = TextEdit(a.text, multiline: true).rich()
        let plainMismatch = sameTextPlain.restoreHistoryJson(saved)
        #expect(!plainMismatch)

        // Wrong version, bad UTF-8 boundary, and open undo group are strictly rejected.
        let badVersion = Data("{\"v\":2,\"undo\":[],\"redo\":[]}".utf8)
        let badVersionOk = b.restoreHistoryJson(badVersion)
        #expect(!badVersionOk)

        let badOffset = Data("{\"v\":1,\"undo\":[{\"b\":{\"t\":\"é\",\"a\":1,\"f\":1,\"m\":[],\"k\":[\"p\"],\"s\":[]},\"a\":{\"t\":\"ab\",\"a\":2,\"f\":2,\"m\":[],\"k\":[\"p\"],\"s\":[]}}],\"redo\":[]}".utf8)
        var offsetTarget = TextEdit("ab")
        let badOffsetOk = offsetTarget.restoreHistoryJson(badOffset)
        #expect(!badOffsetOk)

        // Open undo group refuses restore.
        var openGroupOk = true
        b.undoGroup { ed in
            openGroupOk = ed.restoreHistoryJson(saved)
        }
        #expect(!openGroupOk)

        // Budget capping via maxSteps & maxBytes retains newest steps closest to cursor (redo first).
        let cappedData = try #require(a.historyJson(maxSteps: 2, maxBytes: 64 * 1024))
        var capped = TextEdit(a.text, multiline: true).rich()
        capped.setSelectionRaw(anchor: 0, cursor: a.text.utf8.count)
        capped.toggleMark(.bold)
        capped.setBlock(.bullet(0))
        capped.clearHistory()
        capped.setSelectionRaw(anchor: a.anchor, cursor: a.cursor)
        let cappedRestored = capped.restoreHistoryJson(cappedData)
        #expect(cappedRestored)
        let cappedLen = capped.historyLen()
        #expect(cappedLen.undo + cappedLen.redo <= 2)
    }

    // MARK: - #853: FaceWeights declared weight ranges & TextSystem.setFaceWeights

    @Test("#853: TextSystem.setFaceWeights steers font weight matching across declared ranges")
    func faceWeightsRangeMatching() {
        defer { TextSystem.setFaceWeights([]) }
        #expect(DefaultFonts.registerIfNeeded())

        let beforeEpoch = FontFamiliesRegistry.currentEpoch()
        TextSystem.setFaceWeights([
            FaceWeights(family: "Inter", weight: 400, range: (100, 599)),
            FaceWeights(family: "Inter", weight: 600, range: (600, 900)),
        ])
        let afterEpoch = FontFamiliesRegistry.currentEpoch()
        #expect(afterEpoch > beforeEpoch)

        let ts = TextSystem()
        // Weight 530 falls inside [100, 599] declared at 400 -> resolves to Inter-Regular (400), not Medium/SemiBold.
        let mid = ts.resolveCTFont(style: TextStyle(size: 13, weight: 530), pixelScale: 1)
        #expect((CTFontCopyPostScriptName(mid) as String) == "Inter-Regular")

        // Weight 650 falls inside [600, 900] declared at 600 -> resolves to Inter-SemiBold.
        let heavy = ts.resolveCTFont(style: TextStyle(size: 13, weight: 650), pixelScale: 1)
        #expect((CTFontCopyPostScriptName(heavy) as String) == "Inter-SemiBold")
    }
}
