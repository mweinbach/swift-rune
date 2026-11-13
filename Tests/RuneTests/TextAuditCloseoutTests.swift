import Foundation
import Testing
@testable import Rune
#if canImport(CoreGraphics)
import CoreGraphics
#endif

@Suite("Text Audit Closeout Parity (#558/#560/#562)")
struct TextAuditCloseoutTests {

    // MARK: - 1. Multi-page GlyphAtlas (`src/text/atlas.rs`)

    @Test("GlyphAtlas: 2048 default, 1px zero border, idle reuse, pinnedMask protection, overflow up to 8 pages")
    func glyphAtlasMultiPageAndGutter() {
        let defaultAtlas = GlyphAtlas()
        #expect(!defaultAtlas.hasAllocatedBacking)
        #expect(defaultAtlas.pageCount == 1)
        #expect(defaultAtlas.pageData(0)?.isEmpty == true)
        let firstMask = defaultAtlas.placeMask(width: 4, height: 4, bitmap: Array(repeating: 200, count: 16))
        #expect(firstMask != nil)
        #expect(defaultAtlas.pageData(0)?.count == GlyphAtlas.atlasSize * GlyphAtlas.atlasSize)

        // Small atlas to deterministically fill steady + overflow pages.
        let atlas = GlyphAtlas(width: 16, height: 16)
        // Dirty non-zero border check: mask of 10x10 inside 16x16 fills almost the whole page -> 1 per page.
        let fullMask = Array<UInt8>(repeating: 0xAA, count: 10 * 10)
        let e0 = atlas.placeMask(width: 10, height: 10, bitmap: fullMask)
        #expect(e0?.page == 0)
        // Verify 1px zeroed border around (origin.x ..< origin.x+10, origin.y ..< origin.y+10) on page 0.
        if let origin = e0?.pixelOrigin, let p0 = atlas.pageData(0) {
            let topRow = (origin.y - 1) * 16
            let botRow = (origin.y + 10) * 16
            for col in (origin.x - 1)...(origin.x + 10) {
                #expect(p0[topRow + col] == 0)
                #expect(p0[botRow + col] == 0)
            }
            for row in origin.y..<(origin.y + 10) {
                #expect(p0[row * 16 + origin.x - 1] == 0)
                #expect(p0[row * 16 + origin.x] == 0xAA)
                #expect(p0[row * 16 + origin.x + 10] == 0)
            }
        }

        // Fill pages 0..7 in a single frame without advancing frame boundary.
        var pagesSeen: [UInt16] = [e0?.page ?? 99]
        for _ in 1..<GlyphAtlas.maxOverflowPages {
            let e = atlas.placeMask(width: 10, height: 10, bitmap: fullMask)
            #expect(e != nil)
            if let p = e?.page { pagesSeen.append(p) }
        }
        #expect(atlas.pageCount == GlyphAtlas.maxOverflowPages)
        #expect(pagesSeen == [0, 1, 2, 3, 4, 5, 6, 7])

        // All 8 pages used this frame: a 9th large mask is rejected gracefully.
        #expect(atlas.placeMask(width: 10, height: 10, bitmap: fullMask) == nil)

        // Advance frame with page 0 pinned; unpinned pages recycle on subsequent frames.
        let resetsBefore = atlas.resets
        atlas.beginFrame(pinnedMask: 1) // page 0 stays pinned (ThisFrame); others move to LastFrame
        atlas.beginFrame(pinnedMask: 1) // others move to Idle or overflow evicted
        #expect(atlas.resets > resetsBefore)
        // Even after resets, page 0 remains untouched while another page accepts a mask.
        let afterPin = atlas.placeMask(width: 10, height: 10, bitmap: fullMask)
        #expect(afterPin != nil)
        #expect(afterPin?.page != 0)
    }

    // MARK: - 2. CaretMotion & Word Stepping (`src/edit/caret_motion.rs`)

    @Test("CaretMotion: UAX #29 path splits, ZWNJ Persian word, pill boundaries, platform nextWord, bidi visualIn")
    func caretMotionWordAndVisual() {
        let codeEdit = TextEdit("src/util/format.ts")
        let sIdx = codeEdit.nextWord(0, platform: .mac)
        #expect(String(codeEdit.text.utf8.prefix(sIdx).map { Character(UnicodeScalar($0)) }) == "src")
        let back = codeEdit.prevWord(codeEdit.text.utf8.count)
        #expect(codeEdit.text.dropFirst(back) == "format.ts")
        #expect(codeEdit.prevWord(back) == "src/".utf8.count)

        let persian = TextEdit("می\u{200C}شود next")
        let persianWordBytes = "می\u{200C}شود".utf8.count
        #expect(persian.nextWord(0, platform: .mac) == persianWordBytes)
        #expect(persian.prevWord(persianWordBytes) == 0)

        // Platform word forward difference (macOS stops at word end; Linux/Windows skips trailing spaces).
        let spaced = TextEdit("hello   world")
        #expect(spaced.nextWord(0, platform: .mac) == 5)
        #expect(spaced.nextWord(0, platform: .windows) == 8)

        // Pill stepping: backward over "!" stops at pill's end before taking the whole pill.
        var pilled = TextEdit("hi @noah!").rich()
        let atStart = 3
        let pillEnd = 8
        pilled.setSelectionRaw(anchor: atStart, cursor: pillEnd)
        pilled.setMark(.pill("noah"))
        #expect(pilled.prevWord(pilled.text.utf8.count) == pillEnd)
        #expect(pilled.prevWord(pillEnd) == atStart)
        #expect(pilled.nextWord(atStart, platform: .mac) == pillEnd)

        // CaretMotion.of + visualIn on mixed Latin + Arabic text.
        let ts = TextSystem()
        let ltr = ts.shape(text: "hello world", style: TextStyle(size: 16), maxWidth: nil, pixelScale: 1.0, emitGlyphs: false)
        #expect(CaretMotion.of(ltr, hidden: false) == .logical)
        #expect(CaretVisualStepper.visualIn(ltr, at: 0, side: .downstream, arrow: .right, hidden: false) == nil)

        let bidi = ts.shape(text: "hello مرحبا", style: TextStyle(size: 16), maxWidth: nil, pixelScale: 1.0, emitGlyphs: false)
        #expect(CaretMotion.of(bidi, hidden: false) == .visual)
        #expect(CaretMotion.of(bidi, hidden: true) == .logical)
        let stepRight = CaretVisualStepper.visualIn(bidi, at: 0, side: .downstream, arrow: .right, hidden: false)
        if case let (.at(nextByte, _), flow)? = stepRight {
            #expect(nextByte > 0 && flow == .ltr)
        } else {
            Issue.record("Expected visual stop right of byte 0 in mixed bidi text")
        }
        #expect(CaretVisualStepper.visualIn(bidi, at: 0, side: .downstream, arrow: .left, hidden: false)?.0 == .edge)
    }

    // MARK: - 3. FieldDir & DirChord (`src/edit/direction_keys.rs`)

    @Test("FieldDir & stepDirChord: Ctrl+LeftShift/RightShift arms and disarms off macOS, ignored on macOS")
    func directionKeysParity() {
        // Windows/Linux: Ctrl + Left Shift -> .ltr
        var s = DirChord.idle
        var dir: TextFlow?
        (s, dir) = stepDirChord(s, modifier: .controlLeft, pressed: true, ctrl: true, shift: false, platform: .windows)
        #expect(s == .ctrl && dir == nil)
        (s, dir) = stepDirChord(s, modifier: .shiftLeft, pressed: true, ctrl: true, shift: true, platform: .windows)
        #expect(s == .armed(.left) && dir == nil)
        (s, dir) = stepDirChord(s, modifier: .shiftLeft, pressed: false, ctrl: true, shift: false, platform: .windows)
        #expect(s == .idle && dir == .ltr)

        // Windows/Linux: Ctrl + Right Shift -> .rtl
        (s, dir) = stepDirChord(.idle, modifier: .controlLeft, pressed: true, ctrl: true, shift: false, platform: .linux)
        (s, dir) = stepDirChord(s, modifier: .shiftRight, pressed: true, ctrl: true, shift: true, platform: .linux)
        (s, dir) = stepDirChord(s, modifier: .controlLeft, pressed: false, ctrl: false, shift: true, platform: .linux)
        #expect(s == .idle && dir == .rtl)

        // macOS has no such gesture.
        let macStep = stepDirChord(.idle, modifier: .controlLeft, pressed: true, ctrl: true, shift: false, platform: .mac)
        #expect(macStep.0 == .idle && macStep.1 == nil)

        var edit = TextEdit("hello")
        #expect(edit.forcedDir == nil)
        edit.forceDir(.rtl)
        #expect(edit.forcedDir == .rtl)
        #expect(edit.dir == .forced(.rtl))
    }

    // MARK: - 4. FnKeyMonitor & MacOSKeyboardLayout & Keybind & Shortcut.parseOn

    @Test("FnKeyMonitor, MacOSKeyboardLayout cascade, Keybind.new/.on, and ParsedShortcut.parseOn")
    func inputAndShortcutsParity() throws {
        // FnKeyMonitor (fn_key.rs)
        let fnMon = FnKeyMonitor()
        fnMon.handleFlagsChanged(keyCode: 0x38, modifierFlags: FnKeyMonitor.flagFunction) // Shift key -> ignored
        fnMon.handleFlagsChanged(keyCode: FnKeyMonitor.keyCodeFn, modifierFlags: FnKeyMonitor.flagFunction)
        fnMon.handleFlagsChanged(keyCode: FnKeyMonitor.keyCodeFn, modifierFlags: 0)
        #expect(fnMon.take() == [true, false])
        #expect(fnMon.take().isEmpty)

        // MacOSKeyboardLayout cascade + thread-local force (layout_macos.rs)
        MacOSKeyboardLayout.force { key, mods in
            (key == 11 && (mods & MacOSKeyboardLayout.cmdKeyMask) != 0) ? "b" : "x"
        }
        defer { MacOSKeyboardLayout.force(nil) }
        #expect(MacOSKeyboardLayout.label(key: 11, modifiers: MacOSKeyboardLayout.cmdKeyMask) == "b")
        // Control char rejected in cascade, falling back to non-control or base table:
        let cascaded = MacOSKeyboardLayout.chordLabelCascade(
            key: 40,
            modifiers: MacOSKeyboardLayout.cmdKeyMask | MacOSKeyboardLayout.controlKeyMask
        ) { _, mods in
            if (mods & MacOSKeyboardLayout.controlKeyMask) != 0 { return "\u{000B}" } // control char
            if (mods & MacOSKeyboardLayout.cmdKeyMask) != 0 { return "k" }
            return "v"
        }
        #expect(cascaded == "k")

        // Keybind.new/.on (chord.rs:277)
        let kb = Keybind<Void>.new("mod+b")
            .on(.windows, "alt+home")
            .on(.linux, "ctrl+t, mod+n")
        #expect(kb.label(on: .mac) == "⌘B")
        #expect(kb.label(on: .windows) == "Alt+Home")
        #expect(kb.spec(on: .mac) == "mod+b")
        #expect(kb.spec(on: .linux) == "ctrl+t, mod+n")
        let altHomeEv = KeyEvent(key: .home, mods: Mods(alt: true))
        #expect(kb.matches(altHomeEv, on: .windows))
        #expect(!kb.matches(altHomeEv, on: .mac))
        #expect(Keybind<Void>.new("none").chords(on: .mac).isEmpty)

        // ParsedShortcut.parseOn (shortcuts/parse.rs:29)
        let macModCtrl = try ParsedShortcut.parseOn("mod+ctrl+equal", platform: .mac)
        #expect(macModCtrl.description == "ctrl+super+equal")
        let linuxModCtrl = try ParsedShortcut.parseOn("mod+ctrl+spacebar", platform: .linux)
        #expect(linuxModCtrl.description == "ctrl+space")
        let keyA = try ParsedShortcut.parseOn("ctrl+shift+keya", platform: .windows)
        #expect(keyA.description == "ctrl+shift+a")
        #expect(throws: ShortcutError.self) {
            _ = try ParsedShortcut.parseOn("ctrl+ctrl+a", platform: .mac)
        }
    }

    // MARK: - 5. svg_path::degenerate_arcs_follow_the_spec

    @Test("svg_path.rs:313 degenerate_arcs_follow_the_spec")
    func degenerateArcsFollowSpec() {
        #if canImport(CoreGraphics)
        func elements(_ d: String) -> [(CGPathElementType, CGPoint)] {
            let p = GlyphAtlas.parseSVGPath(d)
            var out: [(CGPathElementType, CGPoint)] = []
            p.applyWithBlock { ptr in
                let el = ptr.pointee
                switch el.type {
                case .moveToPoint, .addLineToPoint:
                    out.append((el.type, el.points[0]))
                case .addQuadCurveToPoint:
                    out.append((el.type, el.points[1]))
                case .addCurveToPoint:
                    out.append((el.type, el.points[2]))
                case .closeSubpath:
                    out.append((el.type, .zero))
                @unknown default:
                    break
                }
            }
            return out
        }

        // Zero radius is a straight line
        let zeroR = elements("M0 0A0 5 0 0 1 4 4")
        #expect(zeroR.count == 2)
        #expect(zeroR[0].0 == .moveToPoint && zeroR[0].1 == .zero)
        #expect(zeroR[1].0 == .addLineToPoint && abs(zeroR[1].1.x - 4) < 0.01 && abs(zeroR[1].1.y - 4) < 0.01)

        // Zero-length arc is omitted
        let zeroLen = elements("M1 1a3 3 0 0 1 0 0L2 2")
        #expect(zeroLen.count == 2)
        #expect(zeroLen[0].0 == .moveToPoint && abs(zeroLen[0].1.x - 1) < 0.01)
        #expect(zeroLen[1].0 == .addLineToPoint && abs(zeroLen[1].1.x - 2) < 0.01)

        // Radii too small for the chord scale up to a half ellipse passing near y = -5.0
        let scaled = GlyphAtlas.parseSVGPath("M0 0A1 1 0 0 1 10 0")
        let bb = scaled.boundingBoxOfPath
        #expect(abs(bb.minY - (-5.0)) < 0.1 || abs(bb.maxY - 5.0) < 0.1)
        #endif
    }

    // MARK: - 6. edit/rich_tests.rs: soft_breaks + rich Runtime copy/paste

    @Test("rich_tests.rs:156 soft_breaks_can_be_set_on_a_rebuilt_draft")
    func softBreaksOnRebuiltDraft() {
        var e = TextEdit.fromRichParts(
            text: "one\ntwo\nthree",
            richMarks: [],
            blocks: [.bullet(0), .bullet(0), .bullet(0)]
        ).withSoftBreaks([5, 1, 0, 1])
        let u0 = e.undo()
        #expect(!u0)
        #expect(e.softBreaks == [1])
        let liCount = e.toHTML().components(separatedBy: "<li>").count - 1
        #expect(liCount == 2)
        e.setSoftBreaks([2])
        let u1 = e.undo()
        #expect(!u1)
        #expect(e.softBreaks == [2])
        let round = TextEdit.fromRichParts(
            text: e.text,
            richMarks: e.richMarks,
            blocks: e.blocks
        ).withSoftBreaks(e.softBreaks)
        #expect(round.toHTML() == e.toHTML())
    }

    @Test("rich_tests.rs:572 copy_from_one_rich_field_pastes_marks_and_blocks_into_another")
    func richFieldRuntimeCopyCutPaste() {
        struct AppState {
            var a: TextEdit
            var b: TextEdit
            var plain: TextEdit
        }
        var a = TextEdit.fromHTML(
            "<p>Hello <b>bold</b> <a href=\"https://example.com\">link</a></p><ul><li>one</li><li><i>two</i></li></ul><blockquote>q</blockquote>"
        )
        a.setSelectionRaw(anchor: 0, cursor: a.text.utf8.count)
        let initState = AppState(a: a, b: TextEdit("").rich(), plain: TextEdit(""))

        let rt = Runtime(
            state: initState,
            viewport: Vec2(320, 360),
            view: { _, _ in
                col().size(320, 360)
                    .child(textInput(key: "a", \AppState.a).size(300, 140))
                    .child(textInput(key: "b", \AppState.b).size(300, 140))
                    .child(textInput(key: "plain", \AppState.plain).size(300, 40))
            }
        )
        func focusField(_ key: String, at t: Double) {
            guard let el = rt.element(byKey: key) else {
                Issue.record("Missing field \(key)")
                return
            }
            let r = el.rect
            rt.pointerDown(at: Vec2(r[0] + 4, r[1] + 4), at: t)
            rt.pointerUp(at: Vec2(r[0] + 4, r[1] + 4), at: t + 0.001)
            _ = rt.frame(at: t + 0.002)
        }

        _ = rt.frame(at: 0)
        focusField("a", at: 0.01)
        rt.update { s, _ in s.a.setSelectionRaw(anchor: 0, cursor: s.a.text.utf8.count) }
        _ = rt.frame(at: 0.02)
        #expect(rt.keyDown(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), at: 0.03))
        _ = rt.frame(at: 0.04)
        #expect(rt.clipboard.text == rt.state.a.text)
        #expect(rt.clipboard.html?.contains("<strong>bold</strong>") == true)
        #expect(rt.clipboard.html?.contains("<ul>") == true)

        focusField("b", at: 0.05)
        #expect(rt.keyDown(KeyEvent(key: .command("v"), mods: Mods(cmd: true)), at: 0.06))
        _ = rt.frame(at: 0.07)
        #expect(rt.state.b.text == rt.state.a.text)
        #expect(rt.state.b.richMarks == rt.state.a.richMarks)
        #expect(rt.state.b.blocks == rt.state.a.blocks)

        // Cut from "b" carries formatting it removes ("bold" at 6..<10).
        rt.update { s, _ in s.b.setSelectionRaw(anchor: 6, cursor: 10) }
        _ = rt.frame(at: 0.08)
        #expect(rt.keyDown(KeyEvent(key: .command("x"), mods: Mods(cmd: true)), at: 0.09))
        _ = rt.frame(at: 0.10)
        #expect(rt.clipboard.text == "bold")
        #expect(rt.clipboard.html?.contains("<strong>bold</strong>") == true)

        // Plain field pastes text only and copies no HTML.
        focusField("plain", at: 0.11)
        #expect(rt.keyDown(KeyEvent(key: .command("v"), mods: Mods(cmd: true)), at: 0.12))
        _ = rt.frame(at: 0.13)
        #expect(rt.state.plain.text == "bold")
        #expect(rt.state.plain.richMarks.isEmpty)
        rt.update { s, _ in s.plain.setSelectionRaw(anchor: 0, cursor: 4) }
        _ = rt.frame(at: 0.14)
        #expect(rt.keyDown(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), at: 0.15))
        #expect(rt.clipboard.text == "bold")
        #expect(rt.clipboard.html == nil)
    }

    // MARK: - 7. edit/tests.rs: history_deletion_cut_and_ime_are_atomic & inline_marks

    @Test("edit/tests.rs:390 history_deletion_cut_and_ime_are_atomic & :563 inline_marks_shift_split_inherit_and_respect_boundaries")
    func editHistoryAtomicAndInlineMarks() {
        // :390 history_deletion_cut_and_ime_are_atomic
        var e = TextEdit("hé🙂")
        _ = e.handleKey(KeyEvent(key: .backspace))
        let undoBackspace = e.undo()
        #expect(undoBackspace)
        #expect(e.text == "hé🙂" && e.anchor == 7 && e.cursor == 7)
        _ = e.handleKey(KeyEvent(key: .home))
        _ = e.handleKey(KeyEvent(key: .delete))
        let undoDelete = e.undo()
        #expect(undoDelete)
        #expect(e.text == "hé🙂" && e.anchor == 0 && e.cursor == 0)
        e.setSelectionRaw(anchor: 3, cursor: 1)
        let cutRes = e.handleKey(KeyEvent(key: .command("x"), mods: Mods(cmd: true)))
        #expect(cutRes == .copy("é"))
        let undoCut = e.undo()
        #expect(undoCut)
        #expect(e.anchor == 3 && e.cursor == 1)

        e.setPreedit("に")
        e.setPreedit("日本")
        e.commitPreedit("日本")
        #expect(e.text == "h日本🙂")
        let undoIme = e.undo()
        #expect(undoIme)
        #expect(e.text == "hé🙂" && e.anchor == 3 && e.cursor == 1)
        #expect(e.preedit == nil)
        let redoIme = e.redo()
        #expect(redoIme)
        #expect(e.text == "h日本🙂")
        e.setPreedit("x")
        let undoPreeditCancel = e.undo()
        #expect(undoPreeditCancel)
        #expect(e.text == "h日本🙂")
        #expect(e.preedit == nil)

        // :563 inline_marks_shift_split_inherit_and_respect_boundaries
        var m = TextEdit("hello world").rich()
        m.setSelectionRaw(anchor: 0, cursor: 5)
        m.toggleMark(.bold)
        #expect(m.hasRichMark(.bold))
        #expect(m.richMarks == [RichMarkRange(0..<5, .bold)])

        m.setCursor(utf8Offset: 5, extendSelection: false)
        #expect(m.hasRichMark(.bold))
        _ = m.handleKey(KeyEvent(key: .text("!")))
        #expect(m.text == "hello! world")
        #expect(m.richMarks == [RichMarkRange(0..<6, .bold)])

        m.setCursor(utf8Offset: 0, extendSelection: false)
        #expect(!m.hasRichMark(.bold))
        _ = m.handleKey(KeyEvent(key: .text(">")))
        #expect(m.text == ">hello! world")
        #expect(m.richMarks == [RichMarkRange(1..<7, .bold)])

        m.setSelectionRaw(anchor: 3, cursor: 5)
        #expect(m.hasRichMark(.bold))
        m.toggleMark(.bold)
        #expect(!m.hasRichMark(.bold))
        #expect(m.richMarks == [RichMarkRange(1..<3, .bold), RichMarkRange(5..<7, .bold)])

        m.setSelectionRaw(anchor: 1, cursor: 7)
        #expect(!m.hasRichMark(.bold))
        m.toggleMark(.bold)
        #expect(m.hasRichMark(.bold))
        #expect(m.richMarks == [RichMarkRange(1..<7, .bold)])

        m.setSelectionRaw(anchor: 8, cursor: 13)
        m.toggleMark(.code)
        m.setLink("https://example.com")
        m.setCursor(utf8Offset: 10, extendSelection: false)
        #expect(m.hasRichMark(.code))
        #expect(m.activeLink == "https://example.com")
        m.setCursor(utf8Offset: 8, extendSelection: false)
        #expect(!m.hasRichMark(.code))
        #expect(m.activeLink == nil)
        _ = m.handleKey(KeyEvent(key: .text("?")))
        #expect(m.text == ">hello! ?world")
        #expect(m.richMarks == [
            RichMarkRange(1..<7, .bold),
            RichMarkRange(9..<14, .code),
            RichMarkRange(9..<14, .link("https://example.com")),
        ])
    }

    // MARK: - 8. input/secure_input.rs:54 & a11y/tests.rs:290

    @Test("secure_input.rs:54 & a11y/tests.rs:290 Runtime secure focus claim and password-input a11y projection")
    func runtimeSecureClaimAndA11y() throws {
        struct PwState {
            var pw: TextEdit = {
                var ed = TextEdit("hunter2")
                ed.isSecure = true
                return ed
            }()
        }
        let rt = Runtime(
            state: PwState(),
            viewport: Vec2(400, 200),
            view: { _, _ in
                col().child(
                    textInput(key: "pw", \PwState.pw)
                        .secure(true)
                        .label("Password")
                        .w(200)
                        .h(40)
                )
            }
        )
        _ = rt.frame(at: 0)
        let r = try #require(rt.element(byKey: "pw")).rect
        rt.pointerDown(at: Vec2(r[0] + 4, r[1] + 4), at: 0.01)
        rt.pointerUp(at: Vec2(r[0] + 4, r[1] + 4), at: 0.02)
        _ = rt.frame(at: 0.03)

        let claim = SecureInputClaim()
        claim.set(rt.hasSecureFocus)
        #expect(claim.isActive)

        rt.dispatchFocus(false, at: 0.04)
        claim.windowFocus(false)
        #expect(rt.hasSecureFocus)
        #expect(!claim.isActive)

        claim.windowFocus(true)
        #expect(!claim.isActive, "focus alone doesn't claim before a frame sees the field")

        // A11y projection never exposes secret text and resolves role = "password-input"
        let snap = rt.accessibilitySnapshot(securePaths: [])
        let jsonStr = AccessibilityDump.jsonString(from: snap)
        #expect(!jsonStr.contains("hunter2"))
        #expect(jsonStr.contains("password-input"))
        func findNode(_ id: String, in node: AccessibilityNode) -> AccessibilityNode? {
            if node.id == id { return node }
            for c in node.children { if let m = findNode(id, in: c) { return m } }
            return nil
        }
        let pwNode = findNode("pw", in: snap)
        #expect(pwNode?.role == .passwordInput)
        #expect(pwNode?.isSecure == true)
        #expect(pwNode?.label == "Password")
    }

    // MARK: - 9. shortcuts/service.rs:377 & machine_tests.rs:278

    @Test("shortcuts/service.rs:377 conflicts_name_the_app & machine_tests.rs:278 Bindings parity")
    func shortcutEngineConflictsAndMachineParity() throws {
        final class AcceptDriver: ShortcutBackendDriver {
            var liveIDs: Set<UInt32> = []
            func register(id: UInt32, shortcut: ParsedShortcut) -> Result<Void, ShortcutError> {
                _ = shortcut
                liveIDs.insert(id)
                return .success(())
            }
            func unregister(id: UInt32) -> Result<Void, ShortcutError> {
                liveIDs.remove(id)
                return .success(())
            }
        }

        let claims = ShortcutProcessClaims()
        let chord = try ParsedShortcut.parseOn("ctrl+alt+shift+f17", platform: .mac)
        var first: ShortcutEngine? = ShortcutEngine(
            title: "First",
            bindings: .connected(native: AcceptDriver(), registrations: [:]),
            claims: claims
        )
        let second = ShortcutEngine(
            title: "Second",
            bindings: .connected(native: AcceptDriver(), registrations: [:]),
            claims: claims
        )
        #expect((try? first!.register(id: 1, shortcut: chord).get()) != nil)
        let dup = second.register(id: 2, shortcut: chord)
        if case let .failure(.alreadyInUse(owner: owner)) = dup {
            #expect(owner == "First")
        } else {
            Issue.record("Expected alreadyInUse(owner: \"First\"), got \(dup)")
        }
        #expect(first?.owner(of: chord) == "First")
        #expect(second.owner(of: chord) == "First")
        first = nil // releasing app drops claim
        #expect(second.owner(of: chord) == nil)
        #expect((try? second.register(id: 2, shortcut: chord).get()) != nil)

        // State machine verification (machine_tests.rs:278, 302)
        final class DummyNative {}
        let s1 = try ParsedShortcut.parseOn("ctrl+alt+shift+f22", platform: .mac)
        var state = ShortcutBindingsState<DummyNative>.connected(native: DummyNative(), registrations: [1: s1])
        let unboundEffects = stepShortcutBindings(&state, event: .unbound(1))
        #expect(unboundEffects.count == 2)
        if case .disconnect = unboundEffects[0], case .disclaim(1) = unboundEffects[1] {
            // Last unregistration closes backend before disclaiming.
        } else {
            Issue.record("Expected disconnect before disclaim")
        }

        var relState = ShortcutBindingsState<DummyNative>.connected(native: DummyNative(), registrations: [1: s1])
        let relEffects = stepShortcutBindings(&relState, event: .release)
        #expect(relEffects.count == 2)
        if case .disconnect = relEffects[0], case .disclaimAll = relEffects[1] {
        } else {
            Issue.record("Expected disconnect before disclaimAll")
        }
    }

    // MARK: - 10. clipboard/hold_tests.rs:109 & :169

    @Test("hold_tests.rs:109 & :169 SecretMachine cancel table + failed replay keeps timeout when wipe no-ops")
    func secretMachineAndFailedReplayTimeout() {
        let reports: [SecretReport] = [
            .said(.pending), .said(.holding), .said(.cleared), .said(.replaced), .said(.failed("x")), .refused
        ]
        for report in reports {
            for holds: UInt32 in [0, 1] {
                for var secret in [
                    SecretMachine.live(report: report, holds: holds),
                    SecretMachine.cancelled(report: report, holds: holds)
                ] {
                    let eff = stepSecret(&secret, event: .cancel)
                    #expect(secret == .cancelled(report: report, holds: holds))
                    let shouldClear = (report == .said(.holding)) || (report.isFailedWrite && holds > 0)
                    #expect(eff == (shouldClear ? [.clear] : []))
                }
            }
        }

        // :169 a_failed_replay_keeps_its_timeout_when_the_wipe_does_nothing
        let host = MemorySecretClipboardHost()
        let hold1 = host.writeSecret("top-secret", clearAfterSeconds: 10.0, now: 0.0)
        #expect(hold1.state == .holding)

        // Failed second replay write while first stays held:
        host.setFailNextWrite("denied 1")
        let hold2 = host.writeSecret("top-secret-2", clearAfterSeconds: 10.0, now: 1.0)
        #expect(hold2.state == .failed("denied 1"))
        #expect(host.rawPlainText == "top-secret")
        #expect(host.isWatching)

        // Wipe does nothing when clear is requested; hold & timeout survive!
        host.setWipeBehavior(.noop)
        _ = hold1.slot.cancelAndRequestClear()
        #expect(host.rawPlainText == "top-secret")
        #expect(host.isWatching)

        // Mend wipe behavior, then secret's own timeout runs and clears it.
        host.setWipeBehavior(.normal)
        host.tick(now: 11.0)
        #expect(host.rawPlainText == nil)
        #expect(hold1.state == .cleared)
        #expect(host.wipeAttempts == 1)
    }

    // MARK: - 11. image.rs:760 drawn_pixels_keep_their_image_cached_after_the_handle_drops

    @Test("image.rs:760 drawn_pixels_keep_their_image_cached_after_the_handle_drops")
    func drawnPixelsKeepImageCachedAfterHandleDrops() {
        let cache = ImageCache()
        weak var weakState: CachedImageState?
        var drawn: Pixels?

        do {
            let image = cache.rgba(width: 1, height: 1, data: [20, 40, 60, 255])
            weakState = image.state
            drawn = image.pixels
            #expect(cache.liveEntryCount == 1)
            #expect(image.isReady)
        }
        // Handle dropped; only drawn Pixels keeps state alive in weak cache.
        #expect(weakState != nil)
        #expect(drawn != nil)

        do {
            let again = cache.rgba(width: 1, height: 1, data: [20, 40, 60, 255])
            #expect(again.state === weakState, "same cached entry, not a new request")
            #expect(again.isReady)
            #expect(cache.liveEntryCount == 1)
        }

        // Now drop the last drawn Pixels as well -> weak cache entry releases.
        drawn = nil
        #expect(weakState == nil)
        #expect(cache.liveEntryCount == 0)
    }

    // MARK: - 12. Runtime host/editor/atlas wiring integration

    @Test("Runtime KeyDiagnostics, bidi layout arrow stepping, toHTML dir=, MacOSKeyboardLayout keycaps, and multi-page GlyphAtlas frame compositing")
    @MainActor
    func runtimeWiringIntegrationParity() throws {
        // 1. KeyDiagnostics auto-runs during Runtime commitTreePass
        struct DiagState: Sendable {}
        let diagRt = Runtime(
            state: DiagState(),
            viewport: Vec2(200, 100),
            view: { _, _ in
                col()
                    .child(text("a").key("dup"))
                    .child(text("b").key("dup"))
            }
        )
        _ = diagRt.frame(at: 0)
        #expect(diagRt.lastKeyDiagnostics.count == 1)
        #expect(diagRt.lastKeyDiagnostics.first?.key == "dup")

        // 2. Bidi forcedDir + toHTML dir="rtl" + handleKey(_:layout:)
        var edit = TextEdit("hi שלום", multiline: true).rich()
        edit.forceDir(.rtl)
        let html = edit.toHTML()
        #expect(html.contains("dir=\"rtl\""))
        let ts = TextSystem()
        let shaped = ts.shape(text: edit.text, style: TextStyle(size: 14, direction: .rtl), maxWidth: 200, pixelScale: 1)
        edit.setCursor(utf8Offset: edit.text.utf8.count)
        let outcome = edit.handleKey(KeyEvent(key: .arrowRight), layout: shaped)
        #expect(outcome == .navigation)

        // 3. ParsedShortcut keycaps honors MacOSKeyboardLayout while menuKeycaps keeps literal letter
        MacOSKeyboardLayout.force { key, _ in key == 11 ? "x" : nil }
        defer { MacOSKeyboardLayout.force(nil) }
        let sc = try ParsedShortcut.parseOn("cmd+b", platform: .mac)
        #expect(sc.keycaps(on: .mac) == ["⌘", "X"])
        #expect(sc.menuKeycaps(on: .mac) == ["⌘", "B"])

        // 4. Multi-page GlyphAtlas compositing in Runtime.frame(at:)
        let smallAtlas = GlyphAtlas(width: 64, height: 64)
        let smallTs = TextSystem(glyphAtlas: smallAtlas)
        struct BigTextState: Sendable {}
        let bigRt = Runtime(
            state: BigTextState(),
            viewport: Vec2(400, 300),
            textSystem: smallTs,
            view: { _, _ in
                text("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()")
                    .size(24)
                    .wrap(.wrap)
            }
        )
        let scene = bigRt.frame(at: 0)
        try scene.validate()
        #expect(smallAtlas.pageCount > 1)
        #expect(scene.glyphs.height == 64 * smallAtlas.pageCount)
    }
}
