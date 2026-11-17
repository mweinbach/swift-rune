import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("Kitc Secure Text Parity (#229-#238)")
struct ElKitcSecureTextParityTests {

    @Test("secure_text (#229 & #230): exiting secure field (hidden or revealed) paints dots without plaintext")
    func exitingSecureFieldPaintsDotsWithoutSecret() {
        struct Card {
            var pw: TextEdit
            var open: Bool
        }
        let view: (Card, inout Cx<Card>) -> El<Card> = { s, _ in
            var root: El<Card> = (col() as El<Card>).key("root").size(200, 100)
            if s.open {
                root = root.child(
                    textInput(key: "pw", \Card.pw)
                        .placeholder("Enter your password", color: .white)
                        .size(200, 40)
                        .transition(.blurReplace())
                )
            }
            return root
        }

        // Case A: Hidden field cleared on exit still draws 7 dots and never leaks "hunter2".
        var pwHidden = TextEdit("hunter2", multiline: false)
        pwHidden.isSecure = true
        let rtHidden = Runtime<Card>(
            state: Card(pw: pwHidden, open: true),
            viewport: Vec2(200, 100),
            pixelScale: 2.0,
            systemDark: true,
            view: view
        )
        let scene0 = rtHidden.frame(at: 0.0)
        let dotsCount0 = scene0.primitives.filter { $0.kind == .glyph }.count
        #expect(dotsCount0 == 7)

        rtHidden.update { s, _ in
            s.pw.clear()
            s.open = false
        }
        let sceneExitHidden = rtHidden.frame(at: 1.0 / 60.0)
        let pwNode = rtHidden.exitingSnapshots.values.first(where: { $0.key == "pw" })
        #expect(pwNode != nil, "exiting field snapshot must stay present during exit")
        #expect(pwNode?.el.plainText == String(repeating: "•", count: 7))
        #expect(pwNode?.el.handlers.editLens == nil)
        #expect(sceneExitHidden.primitives.filter { $0.kind == .glyph }.count == dotsCount0)
        #expect(!String(describing: rtHidden.elements()).contains("hunter2"))

        // Case B: Revealed field conceals to bullets on the very first exit frame.
        var pwRev = TextEdit("hunter2", multiline: false)
        pwRev.isSecure = true
        pwRev.isRevealed = true
        let rtRev = Runtime<Card>(
            state: Card(pw: pwRev, open: true),
            viewport: Vec2(200, 100),
            pixelScale: 2.0,
            systemDark: true,
            view: view
        )
        _ = rtRev.frame(at: 0.0)
        rtRev.update { s, _ in
            s.pw.clear()
            s.open = false
        }
        let sceneExitRev = rtRev.frame(at: 1.0 / 60.0)
        let revSnap = rtRev.exitingSnapshots.values.first(where: { $0.key == "pw" })
        #expect(revSnap != nil)
        #expect(revSnap?.el.isRevealed == false)
        #expect(revSnap?.el.plainText == String(repeating: "•", count: 7))
        #expect(sceneExitRev.primitives.filter { $0.kind == .glyph }.count == dotsCount0)
        #expect(!String(describing: rtRev.elements()).contains("hunter2"))
        #expect(!String(describing: revSnap).contains("hunter2"))
    }

    @Test("secure_text (#231): revealed display never survives in layout, glyph, or raster caches, and redacts key-up events")
    func revealedDisplayDoesNotSurviveInCachesOrEvents() {
        struct S {
            var secret: TextEdit = {
                var e = TextEdit("sensitive fixture", multiline: false)
                e.isSecure = true
                e.isRevealed = true
                return e
            }()
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(240, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().key("cache").cache(true).size(240, 100).onKeyUp { _, _, _ in true }.child(
                textInput(key: "secret", \S.secret)
                    .size(220, 40)
                    .selectable(true)
            )
        }

        let cachedLayouts0 = rt.textSystem.cachedLayoutCount
        let cachedShapes0 = rt.textSystem.cachedShapeCount
        _ = rt.frame(at: 0.0)

        let secretIdx = rt.flatNodes.firstIndex(where: { $0.key == "secret" })!
        let secretNode = rt.flatNodes[secretIdx]
        #expect(!secretNode.el.isSelectable)
        #expect(rt.selectableNodeText(secretNode) == nil)
        #expect(rt.nodeTextLayouts[secretNode.nodeId] == nil)
        #expect(rt.textSystem.cachedLayoutCount == cachedLayouts0)
        #expect(rt.textSystem.cachedShapeCount == cachedShapes0)
        #expect(rt.textSystem.glyphCache.len == 0)
        #expect(rt.residentCacheTracker.isEmpty, "secure child must disable ancestor El.cache raster")

        rt.update { _, tx in tx.focus("secret") }
        _ = rt.frame(at: 1.0 / 60.0)
        #expect(rt.textSystem.cachedLayoutCount == cachedLayouts0)

        rt.events.removeAll()
        #expect(rt.keyUp(KeyEvent(key: .text("private fixture")), at: 2.0 / 60.0))
        #expect(rt.events.contains("key-up [redacted]"))
        #expect(!String(describing: rt.events).contains("private fixture"))

        rt.update { s, _ in s.secret.isRevealed = false }
        _ = rt.frame(at: 3.0 / 60.0)
        #expect(rt.textSystem.cachedLayoutCount == cachedLayouts0)

        rt.update { s, _ in s.secret.clear() }
        let sceneCleared = rt.frame(at: 4.0 / 60.0)
        #expect(rt.state.secret.text.isEmpty)
        #expect(sceneCleared.primitives.filter { $0.kind == .glyph }.isEmpty)
        #expect(rt.textSystem.cachedLayoutCount == cachedLayouts0)
    }

    @Test("secure_text (#232): revealed secure input preserves IME/clipboard/history protections")
    func revealedSecureInputKeepsProtections() {
        var secret = TextEdit("hé🙂 world", multiline: false)
        secret.isSecure = true
        secret.isRevealed = true
        secret.setCursor(utf8Offset: 7, extendSelection: false)
        #expect(secret.copy() == nil)
        #expect(secret.cut() == nil)
        #expect(secret.undo() == false)
        #expect(secret.redo() == false)
        #expect(secret.imeTextSnapshot() == nil)
        #expect(secret.applyIme(.preedit("かんじ", cursorUTF8: 0..<0, clauses: [])) == .navigation)
        #expect(secret.preedit == nil)
        #expect(secret.applyIme(.commit("漢字")) == .ignored)
        #expect(secret.text == "hé🙂 world", "IME commit on secure input must be ignored")
    }

    @Test("secure_text (#233): multiline secure input hides length and lines, wraps anywhere when revealed, and conceals on exit")
    func multilineSecureInputHidesLengthWrapsAnywhereAndConcealsOnExit() {
        struct State {
            var secret: TextEdit
            var open: Bool = true
        }
        let view: (State, inout Cx<State>) -> El<State> = { s, _ in
            var root: El<State> = (col() as El<State>).size(240, 200)
            if s.open {
                root = root.child(
                    textInput(key: "secret", \State.secret)
                        .w(180)
                        .transition(.blurReplace())
                )
            }
            return root
        }

        let shortSecret = "k1"
        let longSecret = String(repeating: "FAKEPEMLINE0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ\n", count: 20)
        var shortEdit = TextEdit(shortSecret, multiline: true)
        shortEdit.isSecure = true
        var longEdit = TextEdit(longSecret, multiline: true)
        longEdit.isSecure = true

        let rtShort = Runtime(state: State(secret: shortEdit), viewport: Vec2(240, 200), pixelScale: 1.0, systemDark: true, view: view)
        let sceneShort = rtShort.frame(at: 0.0)
        let rtLong = Runtime(state: State(secret: longEdit), viewport: Vec2(240, 200), pixelScale: 1.0, systemDark: true, view: view)
        let sceneLong = rtLong.frame(at: 0.0)

        let elShort = rtShort.elements().first(where: { $0.key == "secret" })!
        let elLong = rtLong.elements().first(where: { $0.key == "secret" })!
        #expect(elShort.text == nil && elLong.text == nil)
        #expect(elShort.rect == elLong.rect, "hidden multi-line rect must not leak length or line count")
        #expect(sceneShort.primitives.filter { $0.kind == .glyph }.count == 12)
        #expect(sceneLong.primitives.filter { $0.kind == .glyph }.count == 12)

        // Clicking inside hidden multiline pins caret to text.utf8.count, never leaking an interior offset.
        rtLong.pointerDown(at: Vec2(elLong.rect[0] + 4, elLong.rect[1] + 4), at: 0.0)
        rtLong.pointerUp(at: Vec2(elLong.rect[0] + 4, elLong.rect[1] + 4), at: 0.0)
        _ = rtLong.frame(at: 1.0 / 60.0)
        #expect(rtLong.state.secret.cursor == longSecret.utf8.count)

        // Revealing wraps unbroken lines at character boundaries within 180pt width.
        rtLong.update { s, _ in s.secret.isRevealed = true }
        _ = rtLong.frame(at: 2.0 / 60.0)
        let elRev = rtLong.elements().first(where: { $0.key == "secret" })!
        #expect(elRev.rect[3] > elShort.rect[3] * 10, "revealed long lines must wrap anywhere across many lines")
        #expect(elRev.rect[2] <= 180.5)

        // Exiting while revealed conceals back to the fixed mask on the first exit frame.
        rtLong.update { s, _ in s.open = false }
        let exitScene = rtLong.frame(at: 3.0 / 60.0)
        let exitSnap = rtLong.exitingSnapshots.values.first(where: { $0.key == "secret" })
        #expect(exitSnap != nil)
        #expect(exitSnap?.el.isRevealed == false)
        #expect(exitSnap?.el.plainText == TextEdit.multilineSecureMask)
        #expect(exitScene.primitives.filter { $0.kind == .glyph }.count == 12)
        #expect(!String(describing: exitSnap).contains("FAKEPEMLINE"))
    }

    @Test("secure_text (#234): multiline conceal snaps height and ancestor scroll immediately and bypasses caches")
    func secureMultilineConcealSnapsGeometryScrollAndBypassesCaches() {
        struct S {
            var edit: TextEdit
        }
        var initEdit = TextEdit(String(repeating: "fictional line\n", count: 60), multiline: true)
        initEdit.isSecure = true
        initEdit.isRevealed = true

        let rt = Runtime<S>(
            state: S(edit: initEdit),
            viewport: Vec2(180, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().key("cache").cache(true).w(120).child(
                autoGrow(
                    textInput(key: "secret", \S.edit)
                        .font(TextStyle(size: 14, weight: 400))
                        .wFull()
                        .autofocus(),
                    minLines: 1,
                    maxLines: 3
                )
            )
        }

        _ = rt.frame(at: 0.0)
        #expect(rt.textSystem.cachedLayoutCount == 0)
        #expect(rt.residentCacheTracker.isEmpty)
        let scrollNode = rt.flatNodes.first(where: { $0.key == "scroll" })!
        #expect((rt.scrollMaxExtents[scrollNode.path]?.y ?? 0) > 100.0)
        rt.scrollOffsets[scrollNode.path] = Vec2(0, 300)
        rt.scrollStore.snap(RuneMotion.NodeId.hash("scroll:" + scrollNode.path), Props.SCROLL, to: Vec2(0, 300))

        // Conceal without tx.instant(): must snap height & ancestor scroll immediately.
        rt.update { s, _ in s.edit.isRevealed = false }
        _ = rt.frame(at: 1.0 / 60.0)
        #expect(rt.scrollMaxExtents[scrollNode.path] == .zero)
        #expect(rt.scrollOffsets[scrollNode.path] == .zero)
        for el in rt.elements() {
            #expect(abs(el.rect[3] - el.target[3]) < 0.01, "concealed height must snap without spring: \(el.path)")
        }
        let secretEl = rt.element(byKey: "secret")!
        let lineH = TextStyle(size: 14, weight: 400).resolvedLineHeight
        #expect(abs(secretEl.rect[3] - lineH) <= 1.0, "concealed multiline mask must collapse to 1 line")
        #expect(secretEl.text == nil && secretEl.selected == nil)
        #expect(rt.textSystem.cachedLayoutCount == 0)
        #expect(rt.imeArea == nil)

        // Even a narrow hidden field (w=12, wrapAnywhere) keeps one mask line.
        let narrow = Runtime<S>(
            state: rt.state,
            viewport: Vec2(50, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().size(50, 100).child(
                textInput(key: "secret", \S.edit)
                    .font(TextStyle(size: 14, weight: 400))
                    .wrapAnywhere()
                    .w(12)
            )
        }
        _ = narrow.frame(at: 0.0)
        let narrowEl = narrow.element(byKey: "secret")!
        #expect(abs(narrowEl.rect[3] - lineH) <= 1.0, "w=12 wrapAnywhere hidden mask must stay 1 line")
        let narrowNode = narrow.flatNodes.first(where: { $0.key == "secret" })!
        let narrowResolved = ElDisplayResolver.resolveInput(el: narrowNode.el, edit: narrow.state.edit, innerWidth: 12)
        let narrowShaped = narrow.textSystem.shape(
            text: narrowResolved.renderedString,
            style: narrowResolved.style,
            maxWidth: narrowResolved.maxWidthForShape,
            pixelScale: 1.0,
            emitGlyphs: false
        )
        #expect(narrowShaped.lineCount == 1)
    }

    @Test("secure_text (#236): secure labels mask, reveal, conceal cleanly, and never leak plaintext")
    func secureLabelMasksRevealsConcealsAndNeverLeaksPlaintext() throws {
        let singleSecret = "sk-fictional-token-987654"
        let multiSecret = "-----BEGIN FAKE KEY-----\nAAAAB3NzaC1yc2EAAAADAQABAAABAQDfakebase64payload0123456789ABCDEFGH==\n-----END FAKE KEY-----"
        struct State {
            var revealed: Bool = false
            var open: Bool = true
        }
        let view: (State, inout Cx<State>) -> El<State> = { s, _ in
            var root: El<State> = (col() as El<State>).cache(true).size(240, 240)
            if s.open {
                let singleEl: El<State> = text(singleSecret)
                    .secure(true)
                    .revealed(s.revealed)
                    .selectable(true)
                    .textCase(.uppercase)
                    .transition(.blurReplace())
                    .key("single")
                let truncEl: El<State> = (text(singleSecret) as El<State>)
                    .selectable(true)
                    .secure(true)
                    .revealed(s.revealed)
                    .wrap(.ellipsis)
                    .w(60)
                    .key("trunc")
                let multiEl: El<State> = (col() as El<State>)
                    .w(140)
                    .maxH(44)
                    .scrollY()
                    .key("scroll")
                    .child(
                        text(multiSecret)
                            .wrapAnywhere()
                            .secure(true)
                            .revealed(s.revealed)
                            .transition(.blurReplace())
                            .key("multi")
                    )
                let clampedEl: El<State> = (col() as El<State>).w(140).child(
                    text(multiSecret)
                        .secure(true)
                        .maxLines(2)
                        .revealed(s.revealed)
                        .key("clamped")
                )
                root = root
                    .child(singleEl)
                    .child(truncEl)
                    .child(multiEl)
                    .child(clampedEl)
            }
            return root
        }

        let rt = Runtime(state: State(), viewport: Vec2(240, 240), pixelScale: 1.0, systemDark: true, view: view)
        let cached0 = rt.textSystem.cachedLayoutCount
        _ = rt.frame(at: 0.0)

        func checkNoLeak() throws {
            let treeStr = String(decoding: try rt.treeJSONData(pretty: false), as: UTF8.self)
            let elsStr = String(describing: rt.elements())
            for needle in ["sk-fictional", "987654", "SK-FICTIONAL", "BEGIN FAKE KEY", "AAAAB3Nza"] {
                #expect(!treeStr.contains(needle), "treeJSON leaked \(needle)")
                #expect(!elsStr.contains(needle), "elements leaked \(needle)")
            }
            #expect(rt.textSystem.cachedLayoutCount == cached0, "secure labels must bypass TextSystem layout cache")
            #expect(rt.residentCacheTracker.isEmpty, "secure labels must disable ancestor El.cache raster")
            #expect(rt.textSystem.glyphCache.len == 0)
            for key in ["single", "trunc", "multi", "clamped"] {
                let node = rt.flatNodes.first(where: { $0.key == key })!
                #expect(rt.nodeTextLayouts[node.nodeId] == nil)
                #expect(!node.el.isSelectable)
                #expect(rt.selectableNodeText(node) == nil)
                let info = rt.element(byKey: key)!
                #expect(info.role == .text)
                #expect(rt.elementIsSecure(info.path))
                #expect(info.text == nil)
                #expect(info.selected == nil)
            }
            #expect(treeStr.contains("\"secure\":true"))
        }

        try checkNoLeak()
        let lineH = TextStyle().resolvedLineHeight
        for key in ["single", "multi", "clamped"] {
            let r = rt.element(byKey: key)!.rect
            #expect(abs(r[3] - lineH) <= 1.0, "hidden secure label \(key) must render 1 mask line")
        }

        // Selection + Cmd+C must stay blocked while hidden.
        let singleRect = rt.element(byKey: "single")!.rect
        rt.pointerDown(at: Vec2(singleRect[0] + 2, singleRect[1] + 4), at: 0.0)
        rt.pointerMove(to: Vec2(singleRect[0] + 60, singleRect[1] + 4), at: 0.01)
        rt.pointerUp(at: Vec2(singleRect[0] + 60, singleRect[1] + 4), at: 0.02)
        _ = rt.keyDown(KeyEvent(key: .text("c"), mods: Mods(cmd: true)), at: 0.03)
        #expect(rt.selectedText() == nil)
        #expect(rt.copyRequest == nil)

        // Revealed state lays out plaintext without leaking to caches/tree/clipboard.
        rt.update { s, _ in s.revealed = true }
        _ = rt.frame(at: 0.04)
        try checkNoLeak()
        let truncNode = rt.flatNodes.first(where: { $0.key == "trunc" })!
        let clampedNode = rt.flatNodes.first(where: { $0.key == "clamped" })!
        let multiNode = rt.flatNodes.first(where: { $0.key == "multi" })!
        #expect(truncNode.elided != nil, "truncate elides overflowing revealed label")
        #expect(clampedNode.elided != nil, "maxLines(2) clamps revealed label")
        #expect(abs(clampedNode.targetRect.height - lineH * 2) <= 1.5, "clamped height should be 2 lines")
        #expect(multiNode.targetRect.height >= lineH * 4 - 1.0, "wrapAnywhere wraps revealed multi-line label")

        rt.pointerDown(at: Vec2(singleRect[0] + 2, singleRect[1] + 4), at: 0.05)
        rt.pointerMove(to: Vec2(singleRect[0] + 60, singleRect[1] + 4), at: 0.06)
        rt.pointerUp(at: Vec2(singleRect[0] + 60, singleRect[1] + 4), at: 0.07)
        _ = rt.keyDown(KeyEvent(key: .text("c"), mods: Mods(cmd: true)), at: 0.08)
        #expect(rt.selectedText() == nil)
        #expect(rt.copyRequest == nil)

        // Concealing snaps geometry & ancestor scroll immediately.
        let scrollPath = rt.flatNodes.first(where: { $0.key == "scroll" })!.path
        #expect((rt.scrollMaxExtents[scrollPath]?.y ?? 0) > 10.0)
        rt.scrollOffsets[scrollPath] = Vec2(0, 24)
        rt.scrollStore.snap(RuneMotion.NodeId.hash("scroll:" + scrollPath), Props.SCROLL, to: Vec2(0, 24))
        rt.update { s, _ in s.revealed = false }
        _ = rt.frame(at: 0.09)
        try checkNoLeak()
        #expect(rt.scrollMaxExtents[scrollPath] == .zero)
        #expect(rt.scrollOffsets[scrollPath] == .zero)
        for el in rt.elements() {
            #expect(abs(el.rect[3] - el.target[3]) < 0.01, "concealed label height must not spring: \(el.path)")
        }

        // Exiting while revealed conceals to MULTILINE_SECURE_MASK on first exit frame.
        rt.update { s, tx in
            s.revealed = true
            tx.instant()
        }
        _ = rt.frame(at: 0.10)
        rt.update { s, _ in s.open = false }
        _ = rt.frame(at: 0.11)
        let exSingle = rt.exitingSnapshots.values.first(where: { $0.key == "single" })
        #expect(exSingle != nil)
        #expect(exSingle?.el.isRevealed == false)
        #expect(exSingle?.el.plainText == TextEdit.multilineSecureMask)
        #expect(!String(describing: exSingle).contains("sk-fictional"))
    }

    @Test("secure_text (#235): wrapAnywhere wraps unbroken tokens, keeps word breaks, and lowers min-content width")
    func wrapAnywhereWrapsUnbrokenTokensAndLowersMinContentWidth() {
        let longBase64 = "AAAAB3NzaC1yc2EAAAADAQABAAABAQDfakebase64publickeymaterialwithoutspaces0123456789ABCDEF=="
        let words = "alpha beta gamma delta epsilon zeta eta theta"

        var explicit: El<()> = text("token")
        explicit.layout.flexShrink = 0.25
        #expect(explicit.wrapAnywhere().layout.flexShrink == 0.25)

        let rt = Runtime<()>(
            state: (),
            viewport: Vec2(400, 500),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().size(400, 500)
                .child(col().w(160).child(text(longBase64).wrapText().key("default_wrap")))
                .child(col().w(160).child(text(longBase64).wrapAnywhere().key("anywhere_wrap")))
                .child(row().w(160).child(text(longBase64).wrapAnywhere().shrink(1).key("row_anywhere")))
                .child(col().w(160).child(text(words).wrapText().key("words_default")))
                .child(col().w(160).child(text(words).wrapAnywhere().key("words_anywhere")))
                .child(col().w(160).child(rich([TextSpan(longBase64, weight: 700)]).wrapAnywhere().key("rich_anywhere")))
        }
        _ = rt.frame(at: 0.0)

        let defNode = rt.flatNodes.first(where: { $0.key == "default_wrap" })!
        let anyNode = rt.flatNodes.first(where: { $0.key == "anywhere_wrap" })!
        let defBox = rt.nodeTextLayouts[defNode.nodeId]!.box
        let anyBox = rt.nodeTextLayouts[anyNode.nodeId]!.box
        #expect(defBox.shaped.lineCount == 1, "default wrap keeps unbroken base64 on 1 line")
        #expect(defBox.shaped.size.x > 400.0)
        #expect(anyBox.shaped.lineCount >= 4)
        #expect(anyBox.shaped.size.x <= 160.5)

        let elAny = rt.elements().first(where: { $0.key == "anywhere_wrap" })!
        let elRowAny = rt.elements().first(where: { $0.key == "row_anywhere" })!
        #expect(elAny.rect[2] <= 160.5)
        #expect(elRowAny.rect[2] <= 160.5)

        let minDef = rt.textSystem.measure(longBase64, style: defNode.el.textStyle, maxWidth: 0, pixelScale: 1.0)
        let minAny = rt.textSystem.measure(longBase64, style: anyNode.el.textStyle, maxWidth: 0, pixelScale: 1.0)
        #expect(minDef.x > 400.0)
        #expect(minAny.x < 20.0)

        let wDefNode = rt.flatNodes.first(where: { $0.key == "words_default" })!
        let wAnyNode = rt.flatNodes.first(where: { $0.key == "words_anywhere" })!
        #if canImport(CoreText) && canImport(CoreGraphics)
        let wDefLines = rt.nodeTextLayouts[wDefNode.nodeId]!.box.shaped.lineStrings.map(\.text)
        let wAnyLines = rt.nodeTextLayouts[wAnyNode.nodeId]!.box.shaped.lineStrings.map(\.text)
        #expect(wDefLines == wAnyLines)
        #else
        #expect(rt.nodeTextLayouts[wDefNode.nodeId]!.box.shaped.lineCount == rt.nodeTextLayouts[wAnyNode.nodeId]!.box.shaped.lineCount)
        #endif

        let richNode = rt.flatNodes.first(where: { $0.key == "rich_anywhere" })!
        let richBox = rt.nodeTextLayouts[richNode.nodeId]!.box
        #expect(richBox.shaped.lineCount >= 4 && richBox.shaped.size.x <= 160.5)
    }

    @Test("secure_text (#237): secure rich labels strip links, block flights, and redact tree/measure hashes")
    func secureRichLabelsHaveNoLinksFlightsOrRetainedMeasureHashes() {
        let rt = Runtime<Bool>(
            state: true,
            viewport: Vec2(300, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { revealed, _ in
            col()
                .child(
                    rich([TextSpan("fictional-secret")])
                        .link(TextLink(0..<9, id: "fictional-url-secret", label: "fictional-link-secret"))
                        .secure(true)
                        .revealed(revealed)
                        .key("secret")
                )
                .child(text("destination").key("target"))
        }

        _ = rt.frame(at: 0.0)
        let secNode = rt.flatNodes.first(where: { $0.key == "secret" })!
        #expect(secNode.el.textLinks.isEmpty)
        #expect(rt.elementIsSecure(secNode.path))
        #expect(!rt.elementIsSecure("missing"))
        #expect((try? String(data: rt.treeJSONData(), encoding: .utf8))?.contains("fictional-") == false)

        rt.update { _, tx in
            tx.flyText("secret", to: "target")
        }
        _ = rt.frame(at: 1.0 / 60.0)
        #expect(rt.activeTextFlights.isEmpty, "revealed secret must not survive as flying glyphs")

        rt.update { revealed, _ in revealed = false }
        let sceneMasked = rt.frame(at: 2.0 / 60.0)
        let secMaskedEl = rt.element(byKey: "secret")!
        let secGlyphs = sceneMasked.primitives.filter {
            let cy = $0.rect.y + $0.rect.w * 0.5
            let cx = $0.rect.x + $0.rect.z * 0.5
            return $0.kind == .glyph
                && cx >= secMaskedEl.rect[0]
                && cx <= secMaskedEl.rect[0] + secMaskedEl.rect[2]
                && cy >= secMaskedEl.rect[1]
                && cy <= secMaskedEl.rect[1] + secMaskedEl.rect[3]
        }
        #expect(secGlyphs.count == 12)
        #expect(sceneMasked.primitives.filter { $0.kind == .glyph }.count == 23)
    }

    @Test("secure_text (#238): hidden multiline pristine composes with runtime and app onChange")
    func hiddenMultilinePristineComposesWithRuntimeAndAppOnChange() {
        struct App {
            var secret: TextEdit
            var saved: String
            var appPristine: Bool
            var revealed: Bool = false

            init(saved: String) {
                self.secret = TextEdit(saved, multiline: true)
                self.saved = saved
                self.appPristine = !saved.isEmpty
            }

            mutating func onSecretChange() {
                if appPristine && !revealed && !saved.isEmpty {
                    appPristine = false
                    if secret.text.count > saved.count, secret.text.hasPrefix(saved) {
                        let inserted = String(secret.text.dropFirst(saved.count))
                        secret.replaceText(inserted)
                    } else if !secret.text.isEmpty, secret.text.count == saved.count - 1, saved.hasPrefix(secret.text) {
                        secret.clear()
                    }
                }
            }
        }

        let view: (App, inout Cx<App>) -> El<App> = { s, _ in
            col().size(240, 120).child(
                textInput(key: "secret", \App.secret)
                    .secure(true)
                    .revealed(s.revealed)
                    .w(200)
                    .onChange { app, _, _ in app.onSecretChange() }
            )
        }
        let focusByClick: (Runtime<App>) -> Void = { rt in
            let r = rt.elements().first(where: { $0.key == "secret" })!.rect
            rt.pointerDown(at: Vec2(r[0] + 6, r[1] + 6), at: 0.0)
            rt.pointerUp(at: Vec2(r[0] + 6, r[1] + 6), at: 0.0)
            _ = rt.frame(at: 1.0 / 60.0)
        }

        // Case 1: Typing after clicking and pressing arrows replaces the whole value, then appends.
        let rt1 = Runtime(state: App(saved: "old-fictional-private-key\nsecond-line"), viewport: Vec2(240, 120), pixelScale: 1.0, systemDark: true, view: view)
        _ = rt1.frame(at: 0.0)
        focusByClick(rt1)
        _ = rt1.keyDown(KeyEvent(key: .arrowLeft), at: 2.0 / 60.0)
        _ = rt1.keyDown(KeyEvent(key: .home), at: 3.0 / 60.0)
        #expect(rt1.state.secret.isPristine)
        _ = rt1.keyDown(KeyEvent(key: .text("x")), at: 4.0 / 60.0)
        _ = rt1.frame(at: 5.0 / 60.0)
        #expect(rt1.state.secret.text == "x")
        #expect(!rt1.state.secret.isPristine)
        _ = rt1.keyDown(KeyEvent(key: .text("y")), at: 6.0 / 60.0)
        _ = rt1.frame(at: 7.0 / 60.0)
        #expect(rt1.state.secret.text == "xy")

        // Tab focus also preserves pristine state.
        let rtTab = Runtime(state: App(saved: "fictional-key"), viewport: Vec2(240, 120), pixelScale: 1.0, systemDark: true, view: view)
        _ = rtTab.frame(at: 0.0)
        _ = rtTab.keyDown(KeyEvent(key: .tab), at: 1.0 / 60.0)
        _ = rtTab.frame(at: 2.0 / 60.0)
        #expect(rtTab.elements().contains(where: { $0.key == "secret" && $0.focused }))
        #expect(rtTab.state.secret.isPristine)
        _ = rtTab.keyDown(KeyEvent(key: .text("t")), at: 3.0 / 60.0)
        _ = rtTab.frame(at: 4.0 / 60.0)
        #expect(rtTab.state.secret.text == "t")

        // Case 2: Pasting after Show -> Hide without editing replaces the whole value, then appends.
        let rt2 = Runtime(state: App(saved: "old-fictional-private-key\nsecond-line"), viewport: Vec2(240, 120), pixelScale: 1.0, systemDark: true, view: view)
        _ = rt2.frame(at: 0.0)
        focusByClick(rt2)
        rt2.update { s, _ in s.revealed = true }
        _ = rt2.frame(at: 2.0 / 60.0)
        rt2.update { s, _ in s.revealed = false }
        _ = rt2.frame(at: 3.0 / 60.0)
        #expect(rt2.state.secret.isPristine)
        rt2.paste(ClipboardContent("pasted-key\nline-2"), at: 4.0 / 60.0)
        _ = rt2.frame(at: 5.0 / 60.0)
        #expect(rt2.state.secret.text == "pasted-key\nline-2")
        rt2.paste(ClipboardContent("\nline-3"), at: 6.0 / 60.0)
        _ = rt2.frame(at: 7.0 / 60.0)
        #expect(rt2.state.secret.text == "pasted-key\nline-2\nline-3")

        // Case 3: Backspace while pristine empties the field; subsequent typing starts from "".
        let rt3 = Runtime(state: App(saved: "old-fictional-private-key\nsecond-line"), viewport: Vec2(240, 120), pixelScale: 1.0, systemDark: true, view: view)
        _ = rt3.frame(at: 0.0)
        focusByClick(rt3)
        _ = rt3.keyDown(KeyEvent(key: .backspace), at: 2.0 / 60.0)
        _ = rt3.frame(at: 3.0 / 60.0)
        #expect(rt3.state.secret.text == "")
        #expect(!rt3.state.secret.isPristine)
        _ = rt3.keyDown(KeyEvent(key: .text("n")), at: 4.0 / 60.0)
        _ = rt3.frame(at: 5.0 / 60.0)
        #expect(rt3.state.secret.text == "n")

        // Case 4: Enter (.lineBreak) while pristine replaces the whole secret instead of appending.
        let rt4 = Runtime(state: App(saved: "old-fictional-private-key\nsecond-line"), viewport: Vec2(240, 120), pixelScale: 1.0, systemDark: true, view: view)
        _ = rt4.frame(at: 0.0)
        focusByClick(rt4)
        _ = rt4.keyDown(KeyEvent(key: .enter), at: 2.0 / 60.0)
        _ = rt4.frame(at: 3.0 / 60.0)
        #expect(rt4.state.secret.text == "\n")
        #expect(!rt4.state.secret.isPristine)
    }
}
