import Foundation
import Testing
@testable import Rune
import RuneRef

private func testButton<S>(
    _ key: String,
    onClick: @escaping (inout S) -> Void = { _ in }
) -> El<S> {
    el()
        .key(key)
        .role(.button)
        .focusable(true)
        .size(100, 30)
        .onClick(onClick)
}

@Suite("El Focus & Input Closeout Parity Tests")
struct ElFocusAndInputCloseoutTests {

    // MARK: - el/focus: tabIndex, tab trap, and focus navigation from tabIndex(-1)

    @Test("tabIndex orders positive stops before 0/unset, skips -1, and steps onward from -1")
    func tabIndexOrderingNegativeSkipAndModalEmptyTrap() {
        struct S {
            var showModal = false
            var log: [String] = []
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(400, 300),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            var root: El<S> = col()
                .size(400, 300)
                .child(testButton("zero-a"))
                .child(testButton("two").tabIndex(2))
                .child(testButton("one").tabIndex(1))
                .child(testButton("neg").tabIndex(-1))
                .child(testButton("zero-b").tabIndex(0))
            if s.showModal {
                root = root.child(
                    col()
                        .key("empty-modal")
                        .size(200, 120)
                        .modal(clickOutside: true) { $0.showModal = false }
                        .child(text("Only static text"))
                )
            }
            return root
        }
        rt.setFullKeyboardAccess(true)
        _ = rt.frame(at: 0)

        // Positive tabIndex stops come first in ascending order (1 -> 2), then 0/unset in tree order.
        // tabIndex(-1) ("neg") is skipped on Tab traversal.
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.01))
        #expect(rt.focusedKey == "one")
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.02))
        #expect(rt.focusedKey == "two")
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.03))
        #expect(rt.focusedKey == "zero-a")
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.04))
        #expect(rt.focusedKey == "zero-b")
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.05))
        #expect(rt.focusedKey == "one")

        // Shift+Tab reverses the exact order and still skips "neg".
        #expect(rt.keyDown(KeyEvent(key: .tab, mods: Mods(shift: true)), at: 0.06))
        #expect(rt.focusedKey == "zero-b")

        // Programmatic focus on tabIndex(-1) works, and Tab steps onward into the normal order.
        rt.update(at: 0.07) { _, tx in
            tx.focus("neg")
        }
        _ = rt.frame(at: 0.07)
        #expect(rt.focusedKey == "neg")
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.08))
        #expect(rt.focusedKey == "zero-b")

        // An open modal with zero focusable descendants consumes Tab and traps focus (cannot escape to background).
        rt.update(at: 0.09) { s, _ in
            s.showModal = true
        }
        _ = rt.frame(at: 0.09)
        let beforeTrap = rt.focusedKey
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.10))
        #expect(rt.focusedKey == beforeTrap)
        #expect(rt.focusedKey != "one")
        #expect(rt.focusedKey != "zero-a")
    }

    // MARK: - el/focus: focusFollows + listbox clamping + syncFollows

    @Test("focusFollows activates items on arrows/Home/End, clamps lists, and syncFollows external selection")
    func focusFollowsRovingActivationClampingAndSync() {
        struct S {
            var selected = 0
            var clicks: [Int] = []
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(300, 260),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col()
                .size(300, 260)
                .child(
                    col()
                        .key("list")
                        .role(.listbox)
                        .focusGroup()
                        .focusFollows()
                        .child(
                            col()
                                .key("row-0")
                                .role(.listItem)
                                .size(200, 30)
                                .focusable(true)
                                .focusSelected(s.selected == 0)
                                .onClick {
                                    $0.selected = 0
                                    $0.clicks.append(0)
                                }
                        )
                        .child(
                            col()
                                .key("row-1")
                                .role(.listItem)
                                .size(200, 30)
                                .focusable(true)
                                .focusSelected(s.selected == 1)
                                .onClick {
                                    $0.selected = 1
                                    $0.clicks.append(1)
                                }
                        )
                        .child(
                            col()
                                .key("row-2")
                                .role(.listItem)
                                .size(200, 30)
                                .focusable(true)
                                .focusSelected(s.selected == 2)
                                .onClick {
                                    $0.selected = 2
                                    $0.clicks.append(2)
                                }
                        )
                )
        }
        rt.setFullKeyboardAccess(true)
        _ = rt.frame(at: 0)

        // Focus initial row via Tab -> enters focus-selected row-0, suppressing default focus ring inside listbox.
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.01))
        #expect(rt.focusedKey == "row-0")
        let sListInit = rt.frame(at: 0.01)
        let rfListInit = rt.renderFrame(at: 0.01)
        #expect(sListInit.primitives.filter { $0.params.y == Float(PrimitiveKind.roundedRect.rawValue) && $0.params.x > 0.5 && $0.border.w > 0.1 }.isEmpty)
        #expect(rfListInit.instances.filter { $0.params.y == KIND_RECT && $0.params.x > 0.5 && $0.border.w > 0.1 }.isEmpty)

        // ArrowDown moves focus and fires row-1's onClick.
        #expect(rt.keyDown(KeyEvent(key: .arrowDown), at: 0.02))
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == "row-1")
        #expect(rt.state.selected == 1)
        #expect(rt.state.clicks == [1])

        // End jumps to row-2 and activates it; another ArrowDown clamps at row-2 (listbox never wraps).
        #expect(rt.keyDown(KeyEvent(key: .end), at: 0.03))
        _ = rt.frame(at: 0.03)
        #expect(rt.focusedKey == "row-2")
        #expect(rt.state.selected == 2)
        #expect(rt.state.clicks == [1, 2])

        #expect(rt.keyDown(KeyEvent(key: .arrowDown), at: 0.04))
        _ = rt.frame(at: 0.04)
        #expect(rt.focusedKey == "row-2")
        #expect(rt.state.selected == 2)

        // Home jumps back to row-0 and activates it; ArrowUp clamps at row-0.
        #expect(rt.keyDown(KeyEvent(key: .home), at: 0.05))
        _ = rt.frame(at: 0.05)
        #expect(rt.focusedKey == "row-0")
        #expect(rt.state.selected == 0)
        #expect(rt.keyDown(KeyEvent(key: .arrowUp), at: 0.06))
        _ = rt.frame(at: 0.06)
        #expect(rt.focusedKey == "row-0")

        // App-driven selection change syncs focus inside the active focusFollows group after commit.
        rt.update(at: 0.07) { s, _ in
            s.selected = 2
        }
        _ = rt.frame(at: 0.07)
        #expect(rt.focusedKey == "row-2")
        #expect(rt.focusVisible)
    }

    // MARK: - el/focus: focusHighlight, focusRing, noFocusRing (RefScene + Metal RenderFrame)

    @Test("focusHighlight lights on hover/keyboard, clears on click, and suppresses default focus ring in RefScene & RenderFrame")
    func focusHighlightAndNoFocusRingParity() {
        struct S {
            var count = 0
        }
        let highlight = Color.srgb(0.95, 0.35, 0.15, 1.0)
        let ringColor = Color.srgb(0.1, 0.85, 0.4, 1.0)
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(320, 240),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col()
                .size(320, 240)
                .gap(12)
                .p(16)
                .child(
                    col()
                        .key("hl")
                        .size(160, 40)
                        .bg(Color.srgb(0.15, 0.15, 0.18, 1))
                        .focusable(true)
                        .focusHighlight(highlight)
                        .onClick { $0.count += 1 }
                )
                .child(
                    col()
                        .key("custom-ring")
                        .size(160, 40)
                        .bg(Color.srgb(0.12, 0.12, 0.15, 1))
                        .focusable(true)
                        .focusRing(3.0, offset: 4.0, ringColor)
                )
                .child(
                    col()
                        .key("no-ring")
                        .size(160, 40)
                        .bg(Color.srgb(0.12, 0.12, 0.15, 1))
                        .focusable(true)
                        .noFocusRing()
                )
                .child(
                    text("Docs")
                        .key("link-el")
                        .size(120, 24)
                        .link(TextLink(0..<4, id: "docs-link"))
                        .onLink { _, _ in }
                )
        }
        rt.setFullKeyboardAccess(true)
        _ = rt.frame(at: 0)

        let hlRect = rt.elements().first(where: { $0.key == "hl" })!.rect
        let ringRect = rt.elements().first(where: { $0.key == "custom-ring" })!.rect
        let hl4 = highlight.simd4(srgb: rt.srgbBlend)
        let ring4 = ringColor.simd4(srgb: rt.srgbBlend)

        let expectedRoundedRectKind = Float(PrimitiveKind.roundedRect.rawValue)
        func hasHighlightFill(in scene: RefScene) -> Bool {
            scene.primitives.contains { (p: Primitive) -> Bool in
                guard p.params.y == expectedRoundedRectKind else { return false }
                return abs(p.fill.x - hl4.x) < Float(0.02)
                    && abs(p.fill.y - hl4.y) < Float(0.02)
                    && abs(p.fill.z - hl4.z) < Float(0.02)
            }
        }
        func hasHighlightInstance(in rf: RenderFrame) -> Bool {
            rf.instances.contains { (inst: RenderInstance) -> Bool in
                guard inst.params.y == KIND_RECT else { return false }
                return abs(inst.fill.x - hl4.x) < Float(0.02)
                    && abs(inst.fill.y - hl4.y) < Float(0.02)
                    && abs(inst.fill.z - hl4.z) < Float(0.02)
            }
        }
        func strokeRings(in scene: RefScene) -> [Primitive] {
            scene.primitives.filter { p in
                p.params.y == Float(PrimitiveKind.roundedRect.rawValue)
                    && p.params.x > 0.5
                    && p.border.w > 0.1
            }
        }
        func strokeInstances(in rf: RenderFrame) -> [RenderInstance] {
            rf.instances.filter { inst in
                inst.params.y == KIND_RECT
                    && inst.params.x > 0.5
                    && inst.border.w > 0.1
            }
        }

        // Tab to "hl": focusVisible -> highlight fill lights AND no default focus ring stroke is emitted.
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.01))
        #expect(rt.focusedKey == "hl")
        let sHlKey = rt.frame(at: 0.01)
        let rfHlKey = rt.renderFrame(at: 0.01)
        #expect(hasHighlightFill(in: sHlKey))
        #expect(hasHighlightInstance(in: rfHlKey))
        #expect(strokeRings(in: sHlKey).isEmpty)
        #expect(strokeInstances(in: rfHlKey).isEmpty)

        // Click "hl": clears keyboard focusVisible AND hoveredHighlightActive, so highlight turns off.
        let hlCenter = Vec2(hlRect[0] + hlRect[2] * 0.5, hlRect[1] + hlRect[3] * 0.5)
        rt.pointerDown(at: hlCenter, at: 0.02)
        rt.pointerUp(at: hlCenter, at: 0.03)
        let sHlClick = rt.frame(at: 0.03)
        let rfHlClick = rt.renderFrame(at: 0.03)
        #expect(rt.state.count == 1)
        #expect(!hasHighlightFill(in: sHlClick))
        #expect(!hasHighlightInstance(in: rfHlClick))

        // Move off and re-hover "hl": pointerMove lights focusHighlight without setting focusVisible.
        rt.pointerMove(to: Vec2(2, 2), at: 0.035)
        rt.pointerMove(to: hlCenter, at: 0.04)
        let sHlHover = rt.frame(at: 0.04)
        let rfHlHover = rt.renderFrame(at: 0.04)
        #expect(hasHighlightFill(in: sHlHover))
        #expect(hasHighlightInstance(in: rfHlHover))
        #expect(!rt.focusVisible)

        // Move focus away to "custom-ring" via Tab -> renders custom ring width=3, offset=4 around ringRect.
        rt.pointerMove(to: Vec2(ringRect[0] + 5, ringRect[1] + 5), at: 0.05)
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.06))
        #expect(rt.focusedKey == "custom-ring")
        let sCustom = rt.frame(at: 0.06)
        let rfCustom = rt.renderFrame(at: 0.06)
        let customPrims = strokeRings(in: sCustom)
        let customInsts = strokeInstances(in: rfCustom)
        #expect(customPrims.contains { (p: Primitive) -> Bool in
            abs(p.params.x - Float(3.0)) < Float(0.1)
                && abs(p.border.y - ring4.y) < Float(0.02)
                && p.rect.w > ringRect[3] + Float(6.0)
        })
        #expect(customInsts.contains { (inst: RenderInstance) -> Bool in
            abs(inst.params.x - Float(3.0)) < Float(0.1)
                && abs(inst.border.y - ring4.y) < Float(0.02)
                && inst.rect.w > ringRect[3] + Float(6.0)
        })

        // Tab to "no-ring" -> noFocusRing suppresses even default keyboard focus ring.
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.07))
        #expect(rt.focusedKey == "no-ring")
        let sNoRing = rt.frame(at: 0.07)
        let rfNoRing = rt.renderFrame(at: 0.07)
        #expect(strokeRings(in: sNoRing).isEmpty)
        #expect(strokeInstances(in: rfNoRing).isEmpty)

        // Tab to active text link -> suppresses default keyboard focus ring in both RefScene and Metal RenderFrame.
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.08))
        #expect(rt.focusedKey == "docs-link")
        let sLink = rt.frame(at: 0.08)
        let rfLink = rt.renderFrame(at: 0.08)
        #expect(strokeRings(in: sLink).isEmpty)
        #expect(strokeInstances(in: rfLink).isEmpty)
    }

    // MARK: - el/focus: focusWithinRing & focusWithinFlat

    @Test("focusWithinRing shows on pointer+keyboard focus inside; focusWithinFlat drops shadows and hover fill while keeping focusWithinRing")
    func focusWithinRingAndFocusWithinFlatParity() {
        struct S { var unused = 0 }
        let withinRingColor = Color.srgb(0.2, 0.7, 0.95, 1.0)
        let hoverColor = Color.srgb(0.85, 0.25, 0.55, 1.0)
        let outerShadow = Shadow(x: 0, y: 4, blur: 6, spread: 2, color: Color.srgb(0.1, 0.1, 0.1, 0.6), inset: false)
        let insetShadow = Shadow(x: 0, y: 1, blur: 3, spread: 1, color: Color.srgb(0.9, 0.9, 0.1, 0.5), inset: true)

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(360, 260),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col()
                .size(360, 260)
                .gap(16)
                .p(16)
                .child(
                    col()
                        .key("ring-card")
                        .size(200, 60)
                        .p(8)
                        .focusWithinRing(withinRingColor, width: 2.5, offset: 2.0)
                        .child(
                            testButton("inside-ring")
                                .size(120, 32)
                                .noFocusRing()
                        )
                )
                .child(
                    col()
                        .key("flat-card")
                        .size(200, 60)
                        .p(8)
                        .bg(Color.srgb(0.1, 0.1, 0.12, 1))
                        .hover(hoverColor)
                        .shadows([outerShadow, insetShadow])
                        .focusWithinRing(withinRingColor, width: 2.5, offset: 2.0)
                        .focusWithinFlat()
                        .child(
                            testButton("inside-flat")
                                .size(120, 32)
                                .noFocusRing()
                        )
                )
        }
        rt.setFullKeyboardAccess(true)
        let sUnfocused = rt.frame(at: 0)
        let rfUnfocused = rt.renderFrame(at: 0)

        let ringCardRect = rt.elements().first(where: { $0.key == "ring-card" })!.rect
        let flatCardRect = rt.elements().first(where: { $0.key == "flat-card" })!.rect
        let insideRingRect = rt.elements().first(where: { $0.key == "inside-ring" })!.rect
        let insideFlatRect = rt.elements().first(where: { $0.key == "inside-flat" })!.rect
        let within4 = withinRingColor.simd4(srgb: rt.srgbBlend)

        func countWithinRings(in scene: RefScene) -> Int {
            scene.primitives.filter { p in
                p.params.y == Float(PrimitiveKind.roundedRect.rawValue)
                    && p.params.x > 1.5
                    && abs(p.border.y - within4.y) < 0.03
            }.count
        }
        func countWithinRingInstances(in rf: RenderFrame) -> Int {
            rf.instances.filter { inst in
                inst.params.y == KIND_RECT
                    && inst.params.x > 1.5
                    && abs(inst.border.y - within4.y) < 0.03
            }.count
        }

        // Unfocused: flat-card drops/insets exist, 0 focusWithinRing instances.
        #expect(countWithinRings(in: sUnfocused) == 0)
        #expect(countWithinRingInstances(in: rfUnfocused) == 0)
        #expect(sUnfocused.primitives.contains { $0.params.y == Float(PrimitiveKind.dropShadow.rawValue) })
        #expect(sUnfocused.primitives.contains { $0.params.y == Float(PrimitiveKind.insetShadow.rawValue) })
        #expect(rfUnfocused.instances.contains { $0.params.y == KIND_SHADOW })
        #expect(rfUnfocused.instances.contains { $0.params.y == KIND_INSET })

        // Pointer click inside ring-card -> !focusVisible, yet focusWithinRing STILL shows (:focus-within).
        let pRing = Vec2(insideRingRect[0] + 10, insideRingRect[1] + 10)
        rt.pointerDown(at: pRing, at: 0.01)
        rt.pointerUp(at: pRing, at: 0.02)
        let sRingPointer = rt.frame(at: 0.02)
        let rfRingPointer = rt.renderFrame(at: 0.02)
        #expect(rt.focusedKey == "inside-ring")
        #expect(!rt.focusVisible)
        #expect(countWithinRings(in: sRingPointer) == 1)
        #expect(countWithinRingInstances(in: rfRingPointer) == 1)
        let ringPrim = sRingPointer.primitives.first {
            $0.params.y == Float(PrimitiveKind.roundedRect.rawValue) && $0.params.x > 1.5
        }!
        #expect(ringPrim.rect.w > ringCardRect[3] + 2.0)

        // Hover flat-card padding while focus is elsewhere -> hover background blends in.
        let flatPadPos = Vec2(flatCardRect[0] + 3, flatCardRect[1] + 3)
        let pFlat = Vec2(insideFlatRect[0] + 10, insideFlatRect[1] + 10)
        rt.pointerMove(to: flatPadPos, at: 0.03)
        let sHoveredFlat = rt.frame(at: 0.03)
        #expect(sHoveredFlat.primitives.contains { p in
            p.params.y == Float(PrimitiveKind.roundedRect.rawValue) && p.fill.x > 0.5
        })

        // Click inside flat-card then hover flat-card padding -> focusWithinFlat drops outer shadow,
        // inset shadow, and hover background fill while keeping focusWithinRing standing in for its raised edge!
        rt.pointerDown(at: pFlat, at: 0.04)
        rt.pointerUp(at: pFlat, at: 0.05)
        rt.pointerMove(to: flatPadPos, at: 0.055)
        let sFlatFocused = rt.frame(at: 0.06)
        let rfFlatFocused = rt.renderFrame(at: 0.06)
        #expect(rt.focusedKey == "inside-flat")
        #expect(countWithinRings(in: sFlatFocused) == 1)
        #expect(countWithinRingInstances(in: rfFlatFocused) == 1)
        #expect(!sFlatFocused.primitives.contains { $0.params.y == Float(PrimitiveKind.dropShadow.rawValue) })
        #expect(!sFlatFocused.primitives.contains { $0.params.y == Float(PrimitiveKind.insetShadow.rawValue) })
        #expect(!rfFlatFocused.instances.contains { $0.params.y == KIND_SHADOW || $0.params.y == KIND_INSET })
        #expect(!sFlatFocused.primitives.contains { p in
            p.params.y == Float(PrimitiveKind.roundedRect.rawValue) && p.fill.x > 0.5
        })
        #expect(!rfFlatFocused.instances.contains { inst in
            inst.params.y == KIND_RECT && inst.fill.x > 0.5
        })
    }

    // MARK: - el/focus: modalTx & modalClickOutside

    @Test("modalTx runs Tx effects on outside click and modalClickOutside overrides dismissal")
    func modalTxAndModalClickOutsideParity() {
        struct S {
            var open = true
            var allowOutside = false
            var dismissCount = 0
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(300, 220),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            var root: El<S> = col()
                .size(300, 220)
                .child(testButton("after"))
            if s.open {
                root = root.child(
                    col()
                        .key("sheet")
                        .size(120, 80)
                        .modalTx(clickOutside: true) { state, tx in
                            state.open = false
                            state.dismissCount += 1
                            tx.focus("after")
                            tx.instant()
                        }
                        .modalClickOutside(s.allowOutside)
                        .child(text("Sheet"))
                )
            }
            return root
        }
        _ = rt.frame(at: 0)

        // Outside click is blocked when modalClickOutside(false) overrides modalTx(clickOutside: true).
        rt.pointerDown(at: Vec2(280, 200), at: 0.01)
        rt.pointerUp(at: Vec2(280, 200), at: 0.02)
        _ = rt.frame(at: 0.02)
        #expect(rt.state.open)
        #expect(rt.state.dismissCount == 0)

        // Enable modalClickOutside(true) -> outside click dismisses AND applies tx.focus("after").
        rt.update(at: 0.03) { s, _ in
            s.allowOutside = true
        }
        _ = rt.frame(at: 0.03)
        rt.pointerDown(at: Vec2(280, 200), at: 0.04)
        rt.pointerUp(at: Vec2(280, 200), at: 0.05)
        _ = rt.frame(at: 0.05)
        #expect(!rt.state.open)
        #expect(rt.state.dismissCount == 1)
        #expect(rt.focusedKey == "after")
    }

    // MARK: - el/input: InputSpec, editAccess, onEdit, and FieldMenu + onSpellcheck / onSpellcheckLanguages

    @Test("InputSpec and editAccess bind arbitrary TextEdit storage; FieldMenu drives spelling, clipboard, spellcheck toggle, and languages")
    func inputSpecEditAccessAndFieldMenuParity() throws {
        let testBackend = CustomDictionarySpellChecker(words: ["hello", "world", "swift"])
        let prevLangs = SpellChecker.shared.languages()
        let prevAvail = SpellChecker.shared.availableLanguages()
        SpellChecker.shared.setBackend(testBackend)
        SpellChecker.shared.setAvailableLanguages(["ja-JP", "en-US", "de-DE"])
        SpellChecker.shared.setLanguages(["en-US"])
        defer {
            #if os(macOS)
            SpellChecker.shared.setBackend(MacOSSpellChecker())
            #else
            SpellChecker.shared.setBackend(CustomDictionarySpellChecker())
            #endif
            SpellChecker.shared.setAvailableLanguages(prevAvail)
            SpellChecker.shared.setLanguages(prevLangs)
        }

        var e0 = TextEdit("helo")
        e0.setCursor(utf8Offset: 2, extendSelection: false)
        var e1 = TextEdit("zqxjk")
        e1.setCursor(utf8Offset: 2, extendSelection: false)
        var e2 = TextEdit("zqxjk")
        e2.spellcheckEnabled = true
        e2.setCursor(utf8Offset: 2, extendSelection: false)

        struct S {
            var slots: [TextEdit]
            var spellOn = true
            var secondaryFired = 0
            var spellToggleLog: [Bool] = []
            var languageLog: [[String]] = []
            var focusTargetAfter = false
        }

        let slot0 = editAccess(get: { (s: S) in s.slots[0] }, set: { (s: inout S, e: TextEdit) in s.slots[0] = e })
        let spec = InputSpec(
            animateLayout: true,
            placeholder: "Type here",
            placeholderColor: Color.srgb(0.5, 0.5, 0.5, 1),
            caret: Color.srgb(0.1, 0.9, 0.2, 1),
            selection: Color.srgb(0.2, 0.4, 0.8, 0.4),
            singleLine: true,
            spellcheck: true
        )

        let rt = Runtime<S>(
            state: S(slots: [e0, e1, e2]),
            viewport: Vec2(420, 300),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col()
                .size(420, 300)
                .gap(8)
                .p(12)
                .onSpellcheck(s.spellOn) { state, enabled, tx in
                    state.spellOn = enabled
                    state.spellToggleLog.append(enabled)
                    if !enabled { state.focusTargetAfter = true; tx.instant() }
                }
                .onSpellcheckLanguages { state, langs, _ in
                    state.languageLog.append(langs)
                }
                .onSecondaryClick { state, _, _ in
                    // Must NOT fire when secondary click lands on an editable field (editLens != nil).
                    state.secondaryFired += 1
                }
                .child(
                    textInput(key: "field-0", slot0, spec: spec)
                        .size(280, 32)
                )
                .child(
                    el()
                        .key("field-1")
                        .role(.textInput)
                        .focusable(true)
                        .singleLine(true)
                        .spellcheck(true)
                        .onEdit(
                            get: { (s: S) in s.slots[1] },
                            set: { (s: inout S, e: TextEdit) in s.slots[1] = e }
                        )
                        .size(280, 32)
                )
                .child(
                    el()
                        .key("field-2")
                        .role(.textInput)
                        .focusable(true)
                        .singleLine(true)
                        .spellcheck(false)
                        .onEdit(
                            get: { (s: S) in s.slots[2] },
                            set: { (s: inout S, e: TextEdit) in s.slots[2] = e }
                        )
                        .size(280, 32)
                )
        }
        _ = rt.frame(at: 0)

        let f0Rect = rt.elements().first(where: { $0.key == "field-0" })!.rect
        let f1Rect = rt.elements().first(where: { $0.key == "field-1" })!.rect
        let f2Rect = rt.elements().first(where: { $0.key == "field-2" })!.rect
        let f0Center = Vec2(f0Rect[0] + 8, f0Rect[1] + f0Rect[3] * 0.5)
        let f1Center = Vec2(f1Rect[0] + 8, f1Rect[1] + f1Rect[3] * 0.5)
        let f2Center = Vec2(f2Rect[0] + 8, f2Rect[1] + f2Rect[3] * 0.5)

        // Secondary click outside selection over misspelled word selects the misspelled word & opens suggestions.
        rt.pointerDown(at: f0Center, button: .secondary, at: 0.01)
        rt.pointerUp(at: f0Center, button: .secondary, at: 0.02)
        _ = rt.frame(at: 0.025)
        #expect(rt.state.secondaryFired == 0)
        #expect(rt.focusedKey == "field-0")
        #expect(rt.state.slots[0].selectedUTF8Range == 0..<4)
        let show0 = rt.openPopupHeadless()
        #expect(show0 != nil)

        let topIds0 = show0!.menu.entries.compactMap { entry -> String? in
            if case .item(let item) = entry { return item.id }
            return nil
        }
        #expect(topIds0.contains("suggestion-0"))
        #expect(topIds0.contains("learn-spelling"))
        #expect(topIds0.contains("cut"))
        #expect(topIds0.contains("copy"))
        #expect(topIds0.contains("paste"))
        #expect(topIds0.contains("spellcheck"))
        #if !os(macOS)
        #expect(topIds0.contains("select-all"))
        #endif

        // Submenu contains available languages sorted by locale with "en-US" checked.
        let langSubmenu = show0!.menu.entries.compactMap { entry -> PopupMenu? in
            if case .submenu(_, let sub, _) = entry { return sub }
            return nil
        }.first
        #expect(langSubmenu != nil)
        let langItems = langSubmenu!.entries.compactMap { entry -> PopupMenuItem? in
            if case .item(let item) = entry { return item }
            return nil
        }
        let checkedEn = langItems.first(where: { $0.id == "language-en-US" })
        #expect(checkedEn?.checked == true)

        // Picking "suggestion-0" replaces "helo" -> "hello" in slots[0] via editAccess.
        try rt.resolvePopup("suggestion-0")
        _ = rt.frame(at: 0.03)
        #expect(rt.state.slots[0].text == "hello")

        // singleLine from InputSpec ignores Enter instead of inserting '\n'.
        _ = rt.keyDown(KeyEvent(key: .enter), at: 0.04)
        #expect(!rt.state.slots[0].text.contains("\n"))

        // ContextMenu key on field-1 ("zqxjk", no dictionary guesses) exposes "no-guesses" disabled item + spellcheck toggle.
        rt.pointerDown(at: f1Center, at: 0.05)
        rt.pointerUp(at: f1Center, at: 0.06)
        _ = rt.frame(at: 0.065)
        #expect(rt.focusedKey == "field-1")
        #expect(rt.keyDown(KeyEvent(key: .contextMenu), at: 0.07))
        _ = rt.frame(at: 0.075)
        let show1 = rt.openPopupHeadless()
        #expect(show1 != nil)
        let noGuessItem = show1!.menu.entries.compactMap { entry -> PopupMenuItem? in
            if case .item(let item) = entry, item.id == "no-guesses" { return item }
            return nil
        }.first
        #expect(noGuessItem != nil)
        #expect(noGuessItem?.enabled == false)

        // Pick "spellcheck" -> invokes onSpellcheck closure with toggled false & Tx.
        try rt.resolvePopup("spellcheck")
        _ = rt.frame(at: 0.08)
        #expect(rt.state.spellOn == false)
        #expect(rt.state.spellToggleLog == [false])
        #expect(rt.state.focusTargetAfter)

        // Shift+F10 also opens FieldMenu; selecting "language-de-DE" updates SpellChecker languages & invokes onSpellcheckLanguages.
        #expect(rt.keyDown(KeyEvent(key: .f(10), mods: Mods(shift: true)), at: 0.09))
        _ = rt.frame(at: 0.095)
        #expect(rt.openPopupHeadless() != nil)
        try rt.resolvePopup("language-de-DE")
        _ = rt.frame(at: 0.10)
        #expect(SpellChecker.shared.languages() == ["en-US", "de-DE"])
        #expect(rt.state.languageLog == [["en-US", "de-DE"]])

        // Learn spelling teaches custom dictionary word and suppresses future misspelling hit.
        #expect(rt.keyDown(KeyEvent(key: .contextMenu), at: 0.11))
        _ = rt.frame(at: 0.115)
        #expect(rt.openPopupHeadless() != nil)
        try rt.resolvePopup("learn-spelling")
        _ = rt.frame(at: 0.12)
        #expect(SpellChecker.shared.misspelledUTF8Ranges(in: "zqxjk").isEmpty)

        // Clipboard operations via FieldMenu ("cut", "paste") on field-0.
        rt.pointerDown(at: f0Center, at: 0.13)
        rt.pointerUp(at: f0Center, at: 0.14)
        rt.update(at: 0.15) { s, _ in
            var ed = TextEdit("abcde")
            ed.setCursor(utf8Offset: 1, extendSelection: false)
            ed.setCursor(utf8Offset: 5, extendSelection: true) // "bcde" selected
            s.slots[0] = ed
        }
        _ = rt.frame(at: 0.15)
        #expect(rt.keyDown(KeyEvent(key: .f(10), mods: Mods(shift: true)), at: 0.16))
        _ = rt.frame(at: 0.165)
        #expect(rt.openPopupHeadless() != nil)
        try rt.resolvePopup("cut")
        _ = rt.frame(at: 0.17)
        #expect(rt.state.slots[0].text == "a")
        #expect(rt.copyRequest == "bcde")

        #expect(rt.keyDown(KeyEvent(key: .contextMenu), at: 0.18))
        _ = rt.frame(at: 0.185)
        #expect(rt.openPopupHeadless() != nil)
        try rt.resolvePopup("paste")
        _ = rt.frame(at: 0.19)
        #expect(rt.state.slots[0].text == "abcde")

        // Field with .spellcheck(false) suppresses spelling suggestions & learn-spelling even if TextEdit.spellcheckEnabled == true.
        rt.pointerDown(at: f2Center, button: .secondary, at: 0.20)
        rt.pointerUp(at: f2Center, button: .secondary, at: 0.21)
        _ = rt.frame(at: 0.215)
        let show2 = rt.openPopupHeadless()
        #expect(show2 != nil)
        let ids2 = show2!.menu.entries.compactMap { entry -> String? in
            if case .item(let item) = entry { return item.id }
            return nil
        }
        #expect(!ids2.contains("no-guesses"))
        #expect(!ids2.contains("learn-spelling"))
        #expect(!rt.state.slots[2].hasSelection)
        #expect(rt.state.slots[2].selectedUTF8Range.isEmpty)
        try rt.resolvePopup(nil)
    }
}
