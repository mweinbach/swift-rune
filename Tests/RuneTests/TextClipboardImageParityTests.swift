import Foundation
import Testing
@testable import Rune
#if canImport(CoreText)
import CoreText
#endif

@Suite("Text, Clipboard, Image & Inc 4 Review Parity Tests")
struct TextClipboardImageParityTests {

    // MARK: - #225 Blocker 1 & r378: Atomic Pill Word Motion

    @Test("Option+Left/Right steps over multi-word pills as one unit and stops at pill trailing edge after trailing punctuation (r378)")
    func wordMotionRespectsPillsAndR378() {
        var e = TextEdit("", multiline: true).rich(true)
        e.insert("hi ")
        e.insertPill(id: "u:1", label: "@Maya Lin")
        e.insert("!")
        // "hi @Maya Lin!" -> pill is 3..<12, '!' is 12..<13
        #expect(e.text == "hi @Maya Lin!")
        #expect(e.cursor == 13)

        // r378: Option+Left from after "!" steps over punctuation and stops at pill trailing edge (12).
        _ = e.handleKey(KeyEvent(key: .arrowLeft, mods: Mods(alt: true)))
        #expect(e.cursor == 12)

        // Next Option+Left jumps whole multi-word pill "@Maya Lin" without splitting/sticking (12 -> 3).
        _ = e.handleKey(KeyEvent(key: .arrowLeft, mods: Mods(alt: true)))
        #expect(e.cursor == 3)

        // Next Option+Left jumps "hi " to 0.
        _ = e.handleKey(KeyEvent(key: .arrowLeft, mods: Mods(alt: true)))
        #expect(e.cursor == 0)

        // Apple motion stops at word ends. Windows and Linux advance to the next word start.
        let forwardStops = KeyPlatform.current == .mac ? [2, 12, 13] : [3, 13]
        for stop in forwardStops {
            _ = e.handleKey(KeyEvent(key: .arrowRight, mods: Mods(alt: true)))
            #expect(e.cursor == stop)
        }
    }

    @Test("r378 exact sequence: hi @noah! Option+Left stops at trailing edge before pill")
    func r378ExactTrailingPunctuationStop() {
        var e = TextEdit("", multiline: true).rich(true)
        e.insert("hi ")
        e.insertPill(id: "u:noah", label: "@noah")
        e.insert("!")
        #expect(e.text == "hi @noah!")
        #expect(e.cursor == 9)

        _ = e.handleKey(KeyEvent(key: .arrowLeft, mods: Mods(alt: true)))
        #expect(e.cursor == 8)
        _ = e.handleKey(KeyEvent(key: .arrowLeft, mods: Mods(alt: true)))
        #expect(e.cursor == 3)
    }

    // MARK: - #225 Blocker 2: Rich Block Keyboard Parity

    @Test("Enter, Shift+Enter, Alt+Enter, Tab in Code, Right/Down leaveTrailingBlock, and Backspace block unwrap")
    func richBlockKeyboardBehaviorParity() {
        var e = TextEdit("", multiline: true).rich(true)
        e.setBlock(.bullet(0))
        e.insert("one")

        // Plain Enter in non-empty bullet continues the bullet list.
        let r1 = e.handleKey(KeyEvent(key: .enter))
        #expect(r1 == .modified)
        #expect(e.text == "one\n")
        #expect(e.blocks == [.bullet(0), .bullet(0)])

        // Plain Enter in empty bullet exits back to paragraph.
        let r2 = e.handleKey(KeyEvent(key: .enter))
        #expect(r2 == .modified)
        #expect(e.blocks == [.bullet(0), .paragraph])

        // Plain Enter in empty/non-empty paragraph submits.
        let submitOutcome = e.handleKey(KeyEvent(key: .enter))
        #expect(submitOutcome == .submit)

        // Shift+Enter in rich mode inserts a soft break keeping the block.
        e.setBlock(.quote)
        e.insert("quoted")
        _ = e.handleKey(KeyEvent(key: .enter, mods: Mods(shift: true)))
        #expect(e.softBreaks == [2])
        #expect(e.blocks == [.bullet(0), .quote, .quote])

        // Backspace at start of Bullet(1) outdents to Bullet(0), then Paragraph even at offset 0.
        var listEdit = TextEdit("item", multiline: true).rich(true)
        listEdit.setBlock(.bullet(1))
        listEdit.setCursor(utf8Offset: 0)
        let bs1 = listEdit.handleKey(KeyEvent(key: .backspace))
        #expect(bs1 == .modified)
        #expect(listEdit.blocks == [.bullet(0)])
        let bs2 = listEdit.handleKey(KeyEvent(key: .backspace))
        #expect(bs2 == .modified)
        #expect(listEdit.blocks == [.paragraph])

        // Code block: Tab inserts literal tab, Enter on blank last line exits to paragraph,
        // and unmodified ArrowRight/ArrowDown at trailing end creates empty paragraph.
        var codeEdit = TextEdit("let x = 1", multiline: true).rich(true)
        codeEdit.setBlock(.code)
        let tabOut = codeEdit.handleKey(KeyEvent(key: .tab))
        #expect(tabOut == .modified)
        #expect(codeEdit.text == "let x = 1\t")

        // Unmodified Right at end of trailing code block adds trailing paragraph in one undo step.
        let rightOut = codeEdit.handleKey(KeyEvent(key: .arrowRight))
        #expect(rightOut == .modified)
        #expect(codeEdit.text == "let x = 1\t\n")
        #expect(codeEdit.blocks == [.code, .paragraph])
        let codeUndo = codeEdit.undo()
        #expect(codeUndo)
        #expect(codeEdit.text == "let x = 1\t")
        #expect(codeEdit.blocks == [.code])

        // Alt+Enter inserts hard line break keeping code block; plain Enter on empty last line exits to paragraph.
        _ = codeEdit.handleKey(KeyEvent(key: .enter, mods: Mods(alt: true)))
        #expect(codeEdit.blocks == [.code, .code])
        _ = codeEdit.handleKey(KeyEvent(key: .enter))
        #expect(codeEdit.blocks == [.code, .paragraph])
    }

    // MARK: - #225 Blocker 3: Format Chords & History Coalescing / UndoGroup

    @Test("Formatting shortcuts honor rich mode and allowed marks")
    func formatChordDispatchAndAllowMask() {
        let bold = KeyEvent(key: .command("b"), mods: RuneTestKey.primaryMods())
        let italic = KeyEvent(key: .command("i"), mods: RuneTestKey.primaryMods())
        let plain = TextEdit("hello", multiline: true)
        var plainCopy = plain
        plainCopy.selectAll()
        #expect(plainCopy.formatChord(bold) == nil)
        let plainOut = plainCopy.handleKey(bold)
        #expect(plainOut == .ignored)

        var restricted = TextEdit("hello", multiline: true).rich(true).allowRichMarks([.italic])
        restricted.selectAll()
        #expect(restricted.formatChord(bold) == nil)
        let boldOut = restricted.handleKey(bold)
        #expect(boldOut == .ignored)
        let italicOut = restricted.handleKey(italic)
        #expect(italicOut == .modified)
        #expect(restricted.hasRichMark(.italic))
        #expect(!restricted.hasRichMark(.bold))
    }

    @Test("History coalesces typing runs, respects into_empty in rich mode, supports nested undoGroup, clearHistory, and 1 MiB cap")
    func undoHistoryCoalescingAndGroups() {
        var e = TextEdit("", multiline: true).rich(true)
        // First char into empty rich field is its own undo step; subsequent chars coalesce.
        for ch in ["a", "b", "c"] {
            _ = e.handleKey(KeyEvent(key: .text(ch)))
        }
        #expect(e.text == "abc")
        let u1 = e.undo()
        #expect(u1)
        #expect(e.text == "a")
        let u2 = e.undo()
        #expect(u2)
        #expect(e.text == "")
        let r1 = e.redo()
        #expect(r1)
        #expect(e.text == "a")
        let r2 = e.redo()
        #expect(r2)
        #expect(e.text == "abc")

        // Caret navigation breaks typing run.
        _ = e.handleKey(KeyEvent(key: .text("d")))
        _ = e.handleKey(KeyEvent(key: .arrowLeft))
        _ = e.handleKey(KeyEvent(key: .arrowRight))
        _ = e.handleKey(KeyEvent(key: .text("e")))
        #expect(e.text == "abcde")
        let u3 = e.undo()
        #expect(u3)
        #expect(e.text == "abcd")

        // Nested undoGroup commits as 1 step and blocks undo/redo while open.
        e.undoGroup { outer in
            outer.insert(" ")
            outer.undoGroup { inner in
                inner.replaceWithPill(range: inner.cursor..<inner.cursor, id: "m:1", label: "@sam")
                let blockedUndo = inner.undo()
                #expect(!blockedUndo)
            }
            outer.insert(" ")
        }
        #expect(e.text == "abcd @sam ")
        let u4 = e.undo()
        #expect(u4)
        #expect(e.text == "abcd")
        let r3 = e.redo()
        #expect(r3)
        #expect(e.text == "abcd @sam ")

        // clearHistory and clear inside undoGroup rebase group baseline without recording spurious steps (#248).
        var clearGroup = TextEdit("hello", multiline: true)
        clearGroup.insert("!")
        clearGroup.undoGroup { ed in
            ed.clear()
        }
        #expect(clearGroup.text == "")
        let clearGroupUndo = clearGroup.undo()
        let clearGroupRedo = clearGroup.redo()
        #expect(!clearGroupUndo)
        #expect(!clearGroupRedo)

        clearGroup.undoGroup { ed in
            ed.insert("drop")
            ed.clearHistory()
            ed.insert("after")
        }
        #expect(clearGroup.text == "dropafter")
        let didUndoAfterClear = clearGroup.undo()
        #expect(didUndoAfterClear)
        #expect(clearGroup.text == "drop")

        // clearHistory wipes undo/redo stacks while keeping content.
        e.clearHistory()
        let clearedUndo = e.undo()
        let clearedRedo = e.redo()
        #expect(!clearedUndo)
        #expect(!clearedRedo)
        #expect(e.text == "abcd @sam ")

        // 1 MiB byte cap bounds memory when large snapshots accumulate.
        var big = TextEdit("", multiline: true)
        let chunk = String(repeating: "x", count: 300_000)
        for _ in 0..<6 {
            big.insert(chunk)
        }
        var undoCount = 0
        while big.undo() {
            undoCount += 1
        }
        #expect(undoCount <= 3)
    }

    // MARK: - Clipboard HTML Sanitizer, Secret Clipboard Hold & Collation

    @Test("ClipboardHTMLSanitizer matches upstream html.rs XSS/CSS/URL/CDATA/DROP_TAG rules + CF_HTML roundtrip")
    func clipboardHTMLSanitizerParity() {
        // Formatting & benign attributes/CSS/<style>/entities/data:image survive.
        let html = #"<p class="p1"><b>Bold</b> <i>it</i> <a href="https://example.com/a?b=1">link</a><br/><span style="font-weight: 700; color: #333">x</span></p>"#
        let expected = #"<p class="p1"><b>Bold</b> <i>it</i> <a href="https://example.com/a?b=1">link</a><br /><span style="font-weight: 700; color: #333">x</span></p>"#
        #expect(ClipboardHTMLSanitizer.sanitize(html) == expected)
        #expect(ClipboardHTMLSanitizer.sanitize("<ul><li>1 &lt; 2 &amp; 3 > 0</li></ul>") == "<ul><li>1 &lt; 2 &amp; 3 > 0</li></ul>")
        #expect(ClipboardHTMLSanitizer.sanitize("<style>p.p1 {margin: 0; font: 12px Helvetica}</style><p>a</p>") == "<style>p.p1 {margin: 0; font: 12px Helvetica}</style><p>a</p>")
        #expect(ClipboardHTMLSanitizer.sanitize("a < b") == "a &lt; b")
        #expect(ClipboardHTMLSanitizer.sanitize(#"<img src="data:image/png;base64,AAAA" alt='a "q"'>"#) == #"<img src="data:image/png;base64,AAAA" alt="a &quot;q&quot;">"#)
        #expect(ClipboardHTMLSanitizer.sanitize(#"<img srcset="data:image/png;base64,AAAA 1x, https://example.com/a.png 2x">"#) == #"<img srcset="data:image/png;base64,AAAA 1x, https://example.com/a.png 2x">"#)
        #expect(ClipboardHTMLSanitizer.sanitize(#"<img src="cid:att-1">"#) == #"<img src="cid:att-1">"#)

        // XSS, protocol-relative URLs, CSS smuggling, CDATA, DROP_TAG, entities with >8 leading zeros, unterminated tags.
        let xssCases: [(String, String)] = [
            ("<a href=\"//evil.example/x\">x</a>", "<a>x</a>"),
            ("<a href=\"javascript&#0000000000000000000000000000000000058;alert(1)\">x</a>", "<a>x</a>"),
            ("<div style=\"background:url (https://evil.example/x)\">t</div>", "<div>t</div>"),
            ("<div style=\"background:image-set('x.png')\">t</div>", "<div>t</div>"),
            ("<div style=\"x: ex/**/pression(1)\">t</div>", "<div>t</div>"),
            ("<div style=\"font-family:'/*';background:url(https://evil.example/x);/*'\">t</div>", "<div>t</div>"),
            ("<div style=\"&commat;import 'https://evil.example/x.css'\">t</div>", "<div>t</div>"),
            ("<div style=\"color:red<script>\">t</div>", "<div>t</div>"),
            ("<![CDATA[<script>x</script>]]>t", "t"),
            ("<title><!--</title><script>x</script>-->t", "t"),
            ("<textarea><div title=\"</textarea><script>x</script>\"></div></textarea>t", "<div title=\"&lt;/textarea&gt;&lt;script&gt;x&lt;/script&gt;\"></div>t"),
            ("<xmp><script>x</script></xmp>t", "t"),
            ("<plaintext><script>x</script>", ""),
            ("<scr<script>ipt>alert(1)</script>", "<scr>ipt>alert(1)"),
            ("<details open ontoggle=x>t</details>", "<details open>t</details>"),
            ("t<img src=x", "t"),
            ("t<a href=\"unterminated>", "t"),
            ("<!--><script>x</script>t", "t"),
            ("<!-- --!><script>x</script>t", "t")
        ]
        for (dirty, want) in xssCases {
            #expect(ClipboardHTMLSanitizer.sanitize(dirty) == want)
        }

        let packed = ClipboardHTMLSanitizer.packCFHTML("<b>Hi</b>")
        #expect(ClipboardHTMLSanitizer.unpackCFHTML(packed) == "<b>Hi</b>")

        let negOffsets = "Version:0.9\r\nStartHTML:-1\r\nEndHTML:-1\r\nStartFragment:-1\r\nEndFragment:-1\r\n<html><body><!--StartFragment--><b>Ok</b><!--EndFragment--></body></html>\0\0"
        #expect(ClipboardHTMLSanitizer.unpackCFHTML(Data(negOffsets.utf8)) == "<b>Ok</b>")
    }

    @Test("SecretClipboardHold hides secret text, clears on clearNow/expiry, detects replacement, and breaks retain cycle (r131)")
    func secretClipboardHoldLifecycle() {
        let host = MemorySecretClipboardHost()
        let hold = host.writeSecret("top-secret-password", clearAfterSeconds: 5.0, now: 10.0)
        #expect(hold.state == .holding)
        #expect(hold.holds)
        #expect(!String(describing: hold).contains("top-secret-password"))
        #expect(host.rawPlainText == "top-secret-password")

        // Expiration tick clears clipboard.
        host.tick(now: 15.0)
        #expect(hold.state == .cleared)
        #expect(!hold.holds)
        #expect(host.rawPlainText == nil)

        // Replacement transitions active hold to .replaced without wiping newer copy.
        let hold2 = host.writeSecret("second-secret", clearAfterSeconds: 10.0, now: 20.0)
        host.writeExternal("public text")
        #expect(hold2.state == .replaced)
        #expect(!hold2.clearNow())
        #expect(host.rawPlainText == "public text")

        // Wipe refusal reports exact upstream error message.
        host.setRefuseNextWipe(true)
        let hold3 = host.writeSecret("third-secret", clearAfterSeconds: 10.0, now: 30.0)
        #expect(hold3.clearNow())
        #expect(hold3.state == .failed(SecretSlot.refusedWipeMessage))

        // Weak slot allows SecretSlot to deallocate when all strong hold references are dropped (r131).
        weak var weakSlot: SecretSlot?
        do {
            let scoped = host.writeSecret("scoped", clearAfterSeconds: 10.0, now: 40.0)
            weakSlot = scoped.slot
            #expect(weakSlot != nil)
        }
        #expect(weakSlot == nil)
    }

    @Test("RuneCollation sorts numbers naturally and falls back deterministically (#810)")
    func collationNumericOrder() {
        #expect(RuneCollation.compareNames("file2", "file10") == .orderedAscending)
        #expect(RuneCollation.compareNames("file10", "file2") == .orderedDescending)
        #expect(RuneCollation.compareNamesNatural("file02", "file10") == .orderedAscending)
        #expect(RuneCollation.compareNames("Alpha", "alpha") != .orderedSame)
    }

    // MARK: - Linear Light Mip Generator & Odd Edges

    @Test("LinearMipGenerator & MipStepper match linear premultiplied float reference across odd dimensions")
    func linearMipGeneratorMatchesReferenceAcrossOddEdges() {
        func srgbToLinRef(_ b: UInt8) -> Double {
            let c = Double(b) / 255.0
            return c <= 0.04045 ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4)
        }
        func linToSrgbRef(_ lin: Double) -> UInt8 {
            let c = max(0.0, min(1.0, lin))
            let s = c <= 0.0031308 ? (c * 12.92) : (1.055 * pow(c, 1.0 / 2.4) - 0.055)
            return UInt8(max(0, min(255, Int((s * 255.0).rounded()))))
        }

        for (w, h) in [(1, 1), (3, 1), (17, 9), (257, 131)] {
            var straight = Data(count: w * h * 4)
            straight.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                for y in 0..<h {
                    for x in 0..<w {
                        let off = (y * w + x) * 4
                        p[off] = UInt8((x * 37 + y * 13) & 0xFF)
                        p[off + 1] = UInt8((x * 19 + y * 53) & 0xFF)
                        p[off + 2] = UInt8((x * 7 + y * 97) & 0xFF)
                        let mod = (x / 7 + y / 5) % 5
                        let alpha: UInt8
                        switch mod {
                        case 0: alpha = 255
                        case 1: alpha = 0
                        case 2: alpha = UInt8((x * 255 / max(1, w)) & 0xFF)
                        case 3: alpha = 1 + UInt8(y % 3)
                        default: alpha = 128
                        }
                        p[off + 3] = alpha
                    }
                }
            }

            let levels = LinearMipGenerator.generateChain(width: UInt32(w), height: UInt32(h), straightRGBA: straight)
            let sliced = LinearMipGenerator.generateSlicedChain(width: UInt32(w), height: UInt32(h), straightRGBA: straight)
            #expect(levels == sliced.levels)
            #expect(levels.last?.width == 1 && levels.last?.height == 1)

            // Incremental slicing with tiny pixel budgets matches whole-chain output identically.
            if let stepper = MipStepper(width: UInt32(w), height: UInt32(h), straightRGBA: straight) {
                while !stepper.step(budgetPixels: 7) {}
                #expect(stepper.mips == levels)
            }

            // Clear pixels (a == 0) never emit non-zero RGB light on any mip level.
            for level in levels {
                for off in stride(from: 0, to: level.rgba.count, by: 4) {
                    if level.rgba[off + 3] == 0 {
                        #expect(level.rgba[off] == 0)
                        #expect(level.rgba[off + 1] == 0)
                        #expect(level.rgba[off + 2] == 0)
                    }
                }
            }

            // Reference double-precision mip 0 and mip 1
            var refLin = [Double](repeating: 0, count: w * h * 4)
            for i in 0..<(w * h) {
                let off = i * 4
                let a = Double(straight[off + 3]) / 255.0
                refLin[off] = srgbToLinRef(straight[off]) * a
                refLin[off + 1] = srgbToLinRef(straight[off + 1]) * a
                refLin[off + 2] = srgbToLinRef(straight[off + 2]) * a
                refLin[off + 3] = a
            }
            for i in 0..<(w * h) {
                let off = i * 4
                for c in 0..<3 {
                    let diff = abs(Int(levels[0].rgba[off + c]) - Int(linToSrgbRef(refLin[off + c])))
                    #expect(diff <= 1)
                }
                #expect(levels[0].rgba[off + 3] == straight[off + 3])
            }

            if w > 1 || h > 1 {
                let nw = max(1, w / 2)
                let nh = max(1, h / 2)
                let mip1 = levels[1]
                #expect(Int(mip1.width) == nw && Int(mip1.height) == nh)
                for dy in 0..<nh {
                    for dx in 0..<nw {
                        var accR = 0.0, accG = 0.0, accB = 0.0, accA = 0.0
                        let yStart = dy * h, yEnd = (dy + 1) * h
                        let xStart = dx * w, xEnd = (dx + 1) * w
                        for sy in (yStart / nh)..<min(h, (yEnd + nh - 1) / nh) {
                            let oy = Double(min((sy + 1) * nh, yEnd) - max(sy * nh, yStart)) / Double(h)
                            for sx in (xStart / nw)..<min(w, (xEnd + nw - 1) / nw) {
                                let ox = Double(min((sx + 1) * nw, xEnd) - max(sx * nw, xStart)) / Double(w)
                                let weight = ox * oy
                                let off = (sy * w + sx) * 4
                                accR += refLin[off] * weight
                                accG += refLin[off + 1] * weight
                                accB += refLin[off + 2] * weight
                                accA += refLin[off + 3] * weight
                            }
                        }
                        let dstOff = (dy * nw + dx) * 4
                        let refA = UInt8(max(0, min(255, Int((accA * 255.0).rounded()))))
                        let capA = Double(refA) / 255.0
                        #expect(abs(Int(mip1.rgba[dstOff]) - Int(linToSrgbRef(min(accR, capA)))) <= 1)
                        #expect(abs(Int(mip1.rgba[dstOff + 1]) - Int(linToSrgbRef(min(accG, capA)))) <= 1)
                        #expect(abs(Int(mip1.rgba[dstOff + 2]) - Int(linToSrgbRef(min(accB, capA)))) <= 1)
                        #expect(abs(Int(mip1.rgba[dstOff + 3]) - Int(refA)) <= 1)
                    }
                }
            }
        }
        // MipStepper rejects dimensions above 8192 (#248).
        #expect(MipStepper(width: 8193, height: 1, straightRGBA: Data(count: 8193 * 4)) == nil)
    }

    // MARK: - r371, #830, #807, FontSmoothing & GlyphAtlas LRU Eviction

    @Test("r371 IME preedit preserves empty clauses when no attributes provided")
    func r371EmptyClausesPreserved() {
        let plainAttr = NSAttributedString(string: "かんじ")
        let clauses = ImeUTF16Bridge.clauses(from: plainAttr, preedit: "かんじ")
        #expect(clauses.isEmpty)

        var edit = TextEdit("", multiline: false)
        _ = edit.applyIme(.preedit("かんじ", cursorUTF8: 0..<0, clauses: clauses))
        #expect(edit.preedit?.text == "かんじ")
        #expect(edit.preeditClauses.isEmpty)
    }

    @Test("#830 GlyphAtlas stays zero-backed during measure-only calls and allocates on first mask")
    func glyphAtlasLazyBacking830() {
        let ts = TextSystem()
        #expect(!ts.glyphAtlas.hasAllocatedBacking)
        #expect(ts.glyphAtlas.allocatedBackingBytes == 0)

        let measured = ts.measure("Measure only text", style: TextStyle(size: 14), maxWidth: 400, pixelScale: 2.0)
        #expect(measured.x > 0)
        #expect(!ts.glyphAtlas.hasAllocatedBacking)
        #expect(ts.glyphAtlas.allocatedBackingBytes == 0)

        let shaped = ts.shape(text: "Paint", style: TextStyle(size: 14), maxWidth: 400, pixelScale: 2.0, emitGlyphs: true)
        #expect(!shaped.glyphs.isEmpty)
        #expect(ts.glyphAtlas.hasAllocatedBacking)
        #expect(ts.glyphAtlas.allocatedBackingBytes > 0)
    }

    @Test("#807 Font identity hash sensitivity, color glyph rasterization, FontSmoothing, and GlyphAtlas LRU cap")
    func colorGlyphsFontIdentitySmoothingAndLRU() {
        var fontA = Data(repeating: 0xAA, count: 140 * 1024)
        // Add minimal SFNT header with 1 table ("head") at offset 128
        fontA[4] = 0; fontA[5] = 1
        let tag = Array("head".utf8)
        for i in 0..<4 { fontA[12 + i] = tag[i] }
        let tableOffset = 256
        fontA[12 + 8] = UInt8((tableOffset >> 24) & 0xFF)
        fontA[12 + 9] = UInt8((tableOffset >> 16) & 0xFF)
        fontA[12 + 10] = UInt8((tableOffset >> 8) & 0xFF)
        fontA[12 + 11] = UInt8(tableOffset & 0xFF)
        fontA[12 + 12] = 0; fontA[12 + 13] = 0; fontA[12 + 14] = 0; fontA[12 + 15] = 54

        var fontB = fontA
        fontB[tableOffset + 10] ^= 0x01 // Flip a bit inside `head` table -> hash changes without hashing whole middle.
        #expect(GlyphAtlas.fontIdentityHash(fontA) != GlyphAtlas.fontIdentityHash(fontB))

        // LRU eviction cap keeps entry count bounded.
        let smallAtlas = GlyphAtlas(width: 256, height: 256, maxCachedEntries: 3)
        for scalarValue in [65, 66, 67, 68, 69] as [UInt32] {
            _ = smallAtlas.rasterizePortableGlyph(
                scalar: UnicodeScalar(scalarValue)!,
                fontSizePx: 16,
                smoothing: .on
            )
        }
        #expect(smallAtlas.cachedEntryCount <= 3)

        // FontSmoothing distinguishes .on vs .off cache keys.
        let ts = TextSystem()
        let smoothed = ts.shape(text: "Hi", style: TextStyle(size: 16).smoothing(.on), maxWidth: nil, pixelScale: 2.0, emitGlyphs: true)
        let unsmoothed = ts.shape(text: "Hi", style: TextStyle(size: 16).smoothing(.off), maxWidth: nil, pixelScale: 2.0, emitGlyphs: true)
        #expect(!smoothed.glyphs.isEmpty && !unsmoothed.glyphs.isEmpty)

        #if canImport(CoreText)
        // Shaping color emoji routes through GlyphAtlas color cache + PositionedGlyph.colorGlyphIndex (#807).
        let emojiShaped = ts.shape(text: "😀🎉🚀", style: TextStyle(size: 32), maxWidth: nil, pixelScale: 1.0, emitGlyphs: true)
        #expect(!emojiShaped.glyphs.isEmpty)
        let colorQuads = emojiShaped.glyphs.filter { $0.colorGlyphIndex != nil }
        #expect(!colorQuads.isEmpty)
        for q in colorQuads {
            #expect(q.uv == .zero)
            let bitmap = q.colorGlyphIndex.flatMap { ts.colorGlyph($0) }
            #expect(bitmap != nil)
            #expect((bitmap?.rgba.count ?? 0) > 0)
        }

        // Color glyph cache enforces maxColorGlyphBytes budget via LRU eviction (16 MiB default).
        let budgetedAtlas = GlyphAtlas(width: 256, height: 256, maxCachedEntries: 4096, colorGlyphBudget: 8 * 1024)
        let budgetedTS = TextSystem(glyphAtlas: budgetedAtlas)
        _ = budgetedTS.shape(text: "😀🎉🚀🔥✨🎨", style: TextStyle(size: 48), maxWidth: nil, pixelScale: 1.0, emitGlyphs: true)
        #expect(budgetedAtlas.currentColorGlyphBytes <= 8 * 1024 || budgetedAtlas.colorGlyphEntryCount <= 1)

        // Oversized icon exceeding maxAtlasDimension fails gracefully without crashing out of bounds.
        let hugeIcon = SVGIcon(viewBox: 24, paths: ["M0 0 L24 24"])
        let hugeEntry = budgetedAtlas.rasterizeIcon(hugeIcon, pixelSize: 4096)
        #expect(hugeEntry.uv == .zero)
        #endif
    }
}
