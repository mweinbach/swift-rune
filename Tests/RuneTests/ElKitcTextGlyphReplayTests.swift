import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("Kitc Text Rebreak & Glyph Replay Parity")
struct ElKitcTextGlyphReplayTests {

    private static let sampleProse =
        "The quick brown fox jumps over the lazy dog while keeping line breaking deterministic across multiple viewport widths and leaving transitions."

    private static let altProse =
        "Another distinct body of prose whose words begin differently so switching back and forth preserves both kept layout boxes across commits."

    // MARK: - text_rebreak.rs (7 tests, #269-#275)

    @Test("text_rebreak (#269): resizing rebreaks kept texts in place and leaving ones keep their layout")
    func resizingRebreaksKeptTextsInPlaceAndLeavingOnesKeepTheirLayout() {
        struct S {
            var showLeaving = true
        }
        let leavingText = "Leaving text that should retain its original break width while animating out during resize."
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(420, 400),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            var c: El<S> = col().wFull().hFull().gap(8)
                .child(text(Self.sampleProse).key("kept").wrap(.wrap).wFull())
            if s.showLeaving {
                c = c.child(text(leavingText).key("leaving").wrap(.wrap).wFull().transition(.opacity))
            }
            return c
        }
        _ = rt.frame(at: 0.0)
        let shapedAfterFirst = rt.textSystem.shapedCount
        let rebrokenAfterFirst = rt.textSystem.rebrokenCount
        #expect(shapedAfterFirst >= 2)
        #expect(rebrokenAfterFirst == 0)

        let leavingNodeId: RuneMotion.NodeId? = rt.nodeByPath.values.compactMap { idx -> RuneMotion.NodeId? in
            let n = rt.flatNodes[idx]
            return n.key == "leaving" ? n.nodeId : nil
        }.first
        let leavingBoxBefore: TextLayoutBox? = leavingNodeId.flatMap { rt.nodeTextLayouts[$0]?.box }
        let leavingWidthBefore = leavingBoxBefore?.maxWidth
        let leavingLinesBefore = leavingBoxBefore?.shaped.lineCount

        rt.update { s, _ in s.showLeaving = false }
        rt.setViewport(Vec2(180, 400))
        _ = rt.frame(at: 1.0 / 60.0)

        #expect(rt.textSystem.shapedCount == shapedAfterFirst, "resize must re-break without re-shaping")
        #expect(rt.textSystem.rebrokenCount > rebrokenAfterFirst, "resize must re-break kept text")

        if let lid = leavingNodeId, let exitRec = rt.exitingTextLayouts[lid] {
            #expect(exitRec.box.maxWidth == leavingWidthBefore)
            #expect(exitRec.box.shaped.lineCount == leavingLinesBefore)
        } else {
            Issue.record("Expected leaving node to keep its exiting layout box")
        }
    }

    @Test("text_rebreak (#270): measuring contentHeight keeps the drawn layouts")
    func measuringContentHeightKeepsDrawnLayouts() {
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(360, 300),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().w(360).child(text(Self.sampleProse).key("body").wrap(.wrap).wFull())
        }
        _ = rt.frame(at: 0.0)

        let bodyId: RuneMotion.NodeId = rt.nodeByPath.values.compactMap { idx -> RuneMotion.NodeId? in
            let n = rt.flatNodes[idx]
            return n.key == "body" ? n.nodeId : nil
        }.first!
        let drawnBox = rt.nodeTextLayouts[bodyId]!.box
        let drawnLines = drawnBox.shaped.lineCount
        let drawnMaxW = drawnBox.maxWidth
        let shapedBefore = rt.textSystem.shapedCount
        let rebrokenBefore = rt.textSystem.rebrokenCount

        let measuredH = rt.contentHeight()
        #expect(measuredH > 0)
        #expect(rt.textSystem.shapedCount == shapedBefore)
        #expect(rt.textSystem.rebrokenCount == rebrokenBefore)
        #expect(rt.nodeTextLayouts[bodyId]?.box.shaped.lineCount == drawnLines)
        #expect(rt.nodeTextLayouts[bodyId]?.box.maxWidth == drawnMaxW)
    }

    @Test("text_rebreak (#271): typing keeps no layout of each edit")
    func typingKeepsNoLayoutOfEachEdit() {
        struct S {
            var typed = "a"
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(320, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().size(320, 200).child(text(s.typed).key("live-label").wrap(.wrap).wFull())
        }
        _ = rt.frame(at: 0.0)
        var t = 0.0
        for ch in ["b", "c", "d", "e", "f"] {
            rt.update { s, _ in s.typed.append(ch) }
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            #expect(rt.textSystem.cachedLayoutCount == 1, "superseded edit layouts must be evicted immediately")
            #expect(rt.textSystem.cachedShapeCount == 1, "superseded edit shapes must be evicted immediately")
        }
    }

    @Test("text_rebreak (#272): typing into a field keeps no layout of each edit")
    func typingIntoFieldKeepsNoLayoutOfEachEdit() {
        struct S {
            var draft = TextEdit("x", multiline: true)
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(320, 240),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().size(320, 240)
                .child(textInput(key: "field", \S.draft).wFull().autofocus())
        }
        _ = rt.frame(at: 0.0)
        var t = 0.0
        for ch in ["y", "z", "1", "2"] {
            t += 1.0 / 60.0
            _ = rt.keyDown(KeyEvent(key: .text(ch)), at: t)
            _ = rt.frame(at: t + 0.001)
            #expect(rt.textSystem.cachedLayoutCount == 1, "superseded field edit layouts must be evicted")
            #expect(rt.textSystem.cachedShapeCount == 1, "superseded field edit shapes must be evicted")
        }
        #expect(rt.state.draft.text == "xyz12")
    }

    @Test("text_rebreak (#273): a text shown again after another keeps its layout")
    func textShownAgainAfterAnotherKeepsItsLayout() {
        struct S {
            var showAlt = false
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(340, 240),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().size(340, 240)
                .child(text(s.showAlt ? Self.altProse : Self.sampleProse).key("doc").wrap(.wrap).wFull())
        }
        _ = rt.frame(at: 0.0)
        let shapedAfterFirst = rt.textSystem.shapedCount
        #expect(shapedAfterFirst == 1)

        rt.update { s, _ in s.showAlt = true }
        _ = rt.frame(at: 1.0 / 60.0)
        let shapedAfterSecond = rt.textSystem.shapedCount
        #expect(shapedAfterSecond == 2)
        #expect(rt.textSystem.cachedLayoutCount == 2)

        rt.update { s, _ in s.showAlt = false }
        _ = rt.frame(at: 2.0 / 60.0)
        #expect(rt.textSystem.shapedCount == shapedAfterSecond, "returning to first text must reuse kept layout")
        #expect(rt.textSystem.rebrokenCount == 0)
    }

    @Test("text_rebreak (#274): an edited text shown elsewhere keeps its layout")
    func editedTextShownElsewhereKeepsItsLayout() {
        struct S {
            var primary = ElKitcTextGlyphReplayTests.sampleProse
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(340, 320),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().size(340, 320).gap(8)
                .child(text(s.primary).key("primary").wrap(.wrap).wFull())
                .child(text(Self.sampleProse).key("secondary").wrap(.wrap).wFull())
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.textSystem.shapedCount == 1)

        rt.update { s, _ in s.primary += " extended." }
        _ = rt.frame(at: 1.0 / 60.0)
        #expect(rt.textSystem.shapedCount == 2)
        #expect(rt.textSystem.cachedLayoutCount == 2, "original text still shown in secondary must remain cached")
    }

    @Test("text_rebreak (#275): an edit shares most of its text and a replacement does not")
    func editSharesMostTextAndReplacementDoesNot() {
        let base = "The quick brown fox jumps"
        #expect(TextLayoutRebreak.edited(was: base, now: base) == .unchanged)
        #expect(TextLayoutRebreak.edited(was: base, now: base + " over the dog") == .prefixAppend(commonUTF8Bytes: base.utf8.count))
        #expect(TextLayoutRebreak.edited(was: base, now: "Completely different string") == .fullReplace)
        #expect(TextLayoutRebreak.edited(was: "", now: base) == .fullReplace)

        // Exact upstream edited(was, now) assertions (text_rebreak.rs:116-124):
        // 2 * (prefix + suffix) >= max(was.utf8.count, now.utf8.count)
        #expect(TextLayoutRebreak.edited(was: "hello world", now: "hello world!").isEdit)
        #expect(TextLayoutRebreak.edited(was: "hello world", now: "hello, world").isEdit)
        #expect(TextLayoutRebreak.edited(was: "12", now: "13").isEdit)
        #expect(!TextLayoutRebreak.edited(was: "same", now: "same").isEdit)
        #expect(!TextLayoutRebreak.edited(was: "Show", now: "Hide").isEdit)
        #expect(!TextLayoutRebreak.edited(was: "The first note", now: "Another one").isEdit)
        #expect(!TextLayoutRebreak.edited(was: "a", now: "abcdefghij").isEdit)
    }

    // MARK: - glyph_replay.rs (2 tests, #143-#144)

    @Test("glyph_replay (#143): scrolling replays glyphs it has drawn")
    func scrollingReplaysGlyphsItHasDrawn() {
        struct S {}
        let prose = "Amber lantern orchard quiet harbor, copper meadow signal drift. Pebble willow ember tide under a juniper kestrel; nimbus opal prism and a quiet harbor beneath the lantern. "
        let view: (S, inout Cx<S>) -> El<S> = { _, _ in
            var c: El<S> = col().key("scroll").size(320, 240).scrollY()
            for i in 0..<40 {
                let repeated = String(repeating: prose, count: 1 + (i % 3))
                c = c.child(
                    text("\(i). \(repeated)")
                        .key("p\(i)")
                        .font(TextStyle(size: 13, weight: 400))
                        .color(.white)
                        .wFull()
                        .wrap(.wrap)
                )
            }
            return c
        }

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(320, 240),
            pixelScale: 2.0,
            systemDark: true,
            view: view
        )
        var t = 0.0
        _ = rt.frame(at: t)
        for _ in 0..<12 {
            t += 1.0 / 120.0
            rt.wheel(WheelEvent(dx: 0, dy: -7, precise: true), at: Vec2(160, 120), now: t)
            _ = rt.frame(at: t)
        }
        let flattened = rt.textSystem.glyphCache.flattened
        let shapedAfterScrollDown = rt.textSystem.shapedCount
        #expect(flattened > 0)

        for _ in 0..<12 {
            t += 1.0 / 120.0
            rt.wheel(WheelEvent(dx: 0, dy: 7, precise: true), at: Vec2(160, 120), now: t)
            _ = rt.frame(at: t)
        }
        #expect(rt.textSystem.glyphCache.flattened == flattened, "scrolling back walks no lines")
        #expect(rt.textSystem.shapedCount == shapedAfterScrollDown)

        for _ in 0..<12 {
            t += 1.0 / 120.0
            rt.wheel(WheelEvent(dx: 0, dy: -7, precise: true), at: Vec2(160, 120), now: t)
            _ = rt.frame(at: t)
        }
        #expect(rt.textSystem.glyphCache.flattened == flattened)
        var finalScene = rt.frame(at: t)
        for _ in 0..<29 {
            t += 1.0 / 120.0
            finalScene = rt.frame(at: t)
        }

        let fresh = Runtime<S>(
            state: S(),
            viewport: Vec2(320, 240),
            pixelScale: 2.0,
            systemDark: true,
            view: view
        )
        var ft = 0.0
        _ = fresh.frame(at: ft)
        ft += 1.0 / 120.0
        fresh.wheel(WheelEvent(dx: 0, dy: -84, precise: true), at: Vec2(160, 120), now: ft)
        var freshScene = fresh.frame(at: ft)
        for _ in 0..<29 {
            ft += 1.0 / 120.0
            freshScene = fresh.frame(at: ft)
        }

        let scrollPath = rt.flatNodes.first(where: { $0.key == "scroll" })!.path
        let freshScrollPath = fresh.flatNodes.first(where: { $0.key == "scroll" })!.path
        #expect(rt.scrollOffsets[scrollPath] == fresh.scrollOffsets[freshScrollPath])

        let glyphsRt = finalScene.primitives.filter { $0.kind == .glyph }
        let glyphsFresh = freshScene.primitives.filter { $0.kind == .glyph }
        #expect(glyphsRt.count > 200)
        #expect(glyphsRt == glyphsFresh, "replayed glyphs must match freshly walked glyphs")
    }

    @Test("glyph_replay (#144): secure fields keep no glyphs")
    func secureFieldsKeepNoGlyphs() {
        struct S {
            var secret: TextEdit = {
                var e = TextEdit("hunter2-secret-value")
                e.isSecure = true
                return e
            }()
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(320, 180),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().size(320, 180).gap(8)
                .child(text("secret-label-value").key("sec-lbl").secure(true).revealed(true))
                .child(textInput(key: "sec-inp", \S.secret).secure(true).revealed(true).wFull())
        }
        let scene = rt.frame(at: 0.0)
        #expect(!scene.primitives.filter { $0.kind == PrimitiveKind.glyph }.isEmpty)
        #expect(rt.textSystem.glyphCache.len == 0, "secure text/fields must keep zero cached glyph entries")
        #expect(rt.textSystem.glyphCache.flattened == 0, "secure text/fields must never flatten into GlyphCache")
        #expect(rt.textSystem.cachedLayoutCount == 0, "secure text/fields must keep zero cached layouts")
        #expect(rt.textSystem.cachedShapeCount == 0, "secure text/fields must keep zero cached shapes")
    }
}
