#if canImport(CoreText) && canImport(CoreGraphics)
import Testing
@testable import Rune

@Suite("CoreText caret affinity")
struct AppleCaretAffinityTests {
    @Test func mixedRunsInBothParagraphDirections() {
        let system = TextSystem()
        for direction in [TextFlow.ltr, .rtl] {
            let prefix = "x\n"
            let before = direction == .ltr ? "A" : "אב"
            let inside = direction == .ltr ? "שָׁל" : "AB"
            let after = direction == .ltr ? "B" : "גד"
            let shaped = system.shape(text: prefix + before + inside + after,
                                      style: TextStyle(size: 22, direction: direction),
                                      maxWidth: nil, pixelScale: 2, emitGlyphs: false)
            let first = (prefix + before).utf8.count
            let last = first + inside.utf8.count
            func caret(_ byte: Int, _ affinity: TextAffinity) -> SIMD4<Float> {
                system.caretRect(in: shaped, utf8Offset: byte, affinity: affinity, pixelScale: 2)
            }
            let preceding = caret(first, .upstream)
            let following = caret(first, .downstream)
            #expect(preceding.y > 0)
            #expect(preceding.y == following.y)
            #expect(direction == .ltr ? preceding.x < following.x : preceding.x > following.x)
            #expect(caret(last, .upstream).x == preceding.x)
            #expect(caret(last, .downstream).x == following.x)
            if direction == .ltr {
                // A byte inside the first Hebrew grapheme must use its leading boundary.
                #expect(caret(first + 3, .downstream) == following)
            }
        }
    }

    @Test func lineEndingInsideOppositeDirectionRunUsesItsTrailingEdge() {
        let system = TextSystem()
        for direction in [TextFlow.ltr, .rtl] {
            let prefix = direction == .ltr ? "abc " : "שלום "
            let tail = direction == .ltr ? "שָׁל" : "xyz"
            let text = prefix + tail
            let shaped = system.shape(text: text, style: TextStyle(size: 20, direction: direction),
                                      maxWidth: nil, pixelScale: 1, emitGlyphs: false)
            func x(_ byte: Int, _ affinity: TextAffinity) -> Float {
                system.caretRect(in: shaped, utf8Offset: byte, affinity: affinity, pixelScale: 1).x
            }
            let adjacent = x(prefix.utf8.count, .upstream)
            #expect(x(text.utf8.count, .upstream) == adjacent)
            #expect(x(text.utf8.count, .downstream) == adjacent)
            #expect(x(prefix.utf8.count, .downstream) != adjacent)
        }
    }

    @Test func visualArrowsTraverseMixedGraphemesOnSecondLine() {
        let paragraphStart = "🙂\n".utf8.count
        let prefix = "🙂\ntag "
        let first = prefix.utf8.count
        let inner = first + 1 + "שָׁ".utf8.count
        let after = inner + "ל".utf8.count
        let pill = PillChip(paragraphStart..<(paragraphStart + 3))
        for pills in [[], [pill]] {
            let shaped = TextSystem().shape(text: prefix + "AשָׁלB", pills: pills, style: TextStyle(size: 20),
                                            maxWidth: nil, pixelScale: 2, emitGlyphs: false)
            func move(_ byte: Int, _ side: TextAffinity, _ arrow: CaretArrow) -> CaretLanding? {
                CaretVisualStepper.visualIn(shaped, at: byte, side: side, arrow: arrow, hidden: false)?.0
            }
            #expect(move(first, .downstream, .right) == .at(first + 1, .upstream))
            #expect(move(first + 1, .upstream, .right) == .at(inner, .downstream))
            #expect(move(inner, .downstream, .right) == .at(first + 1, .downstream))
            #expect(move(after, .downstream, .left) == .at(inner, .upstream))
            #expect(move(inner, .upstream, .left) == .at(after, .upstream))
            #expect(move(after, .upstream, .left) == .at(first, .downstream))
            #expect(move(after + 1, .upstream, .right) == .edge)
            var edit = TextEdit(prefix + "AשָׁלB")
            edit.setCursor(utf8Offset: first + 1)
            _ = edit.handleKey(KeyEvent(key: .arrowLeft), layout: shaped)
            #expect(edit.cursor == inner && edit.caretAffinity == .upstream)
            _ = edit.handleKey(KeyEvent(key: .arrowRight, mods: Mods(shift: true)), layout: shaped)
            #expect(edit.anchor == inner && edit.cursor == first + 1 && edit.caretAffinity == .downstream)
        }
    }

    @Test func wordArrowsAndSpaceAheadUseTheDrawnWord() {
        let prefix = "first\n"
        let first = prefix.utf8.count
        let shaped = TextSystem().shape(text: prefix + "word אב", style: TextStyle(size: 18),
                                        maxWidth: nil, pixelScale: 1, emitGlyphs: false)
        #expect(CaretVisualStepper.visualIn(shaped, at: first, side: .downstream,
                                            arrow: .wordRight, hidden: false)?.0 == .at(first + 4, .upstream))
        #expect(CaretVisualStepper.spaceAhead(shaped, at: first + 4, side: .upstream, right: true))
        #expect(!CaretVisualStepper.spaceAhead(shaped, at: first + 5, side: .downstream, right: true))
    }
}
#endif
