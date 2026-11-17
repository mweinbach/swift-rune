import Testing
@testable import Rune

@Suite("Editable field pointer affinity")
@MainActor
struct EditablePointerAffinityTests {
    @Test func pressShiftClickAndDragAcrossASoftWrap() throws {
        let text = "one two three four five six seven"
        let style = TextStyle(size: 16).lh(24)
        let runtime = Runtime(state: TextEdit(text, multiline: true), viewport: Vec2(80, 120), pixelScale: 1) { _, _ in
            textInput(key: "field", \TextEdit.self).font(style).size(80, 120)
        }
        _ = runtime.frame(at: 0)
        let rect = try #require(runtime.element(byKey: "field")?.rect)
        let left = rect[0] + 0.25
        let firstStart = Vec2(left, rect[1] + 12)
        let firstEnd = Vec2(rect[0] + rect[2] - 0.25, firstStart.y)
        let secondStart = Vec2(left, firstStart.y + 24)

        runtime.pointerDown(at: firstEnd, at: 1)
        runtime.pointerUp(at: firstEnd, at: 1.01)
        let boundary = runtime.state.cursor
        #expect(boundary > 0 && boundary < text.utf8.count)
        #expect(text.utf8.prefix(boundary).last == 0x20)
        #expect(runtime.state.caretAffinity == .upstream)
        _ = runtime.frame(at: 1.02)
        let firstCaret = try #require(runtime.element(byKey: "field")?.caret)
        #expect(firstCaret[1] <= firstStart.y && firstCaret[1] + firstCaret[3] > firstStart.y)

        runtime.pointerDown(at: secondStart, at: 2)
        runtime.pointerUp(at: secondStart, at: 2.01)
        #expect(runtime.state.cursor == boundary && runtime.state.anchor == boundary)
        #expect(runtime.state.caretAffinity == .downstream)
        _ = runtime.frame(at: 2.02)
        let secondCaret = try #require(runtime.element(byKey: "field")?.caret)
        #expect(secondCaret[1] == firstCaret[1] + 24)

        runtime.pointerDown(at: firstStart, at: 3)
        runtime.pointerUp(at: firstStart, at: 3.01)
        runtime.pointerDown(at: firstEnd, mods: Mods(shift: true), at: 4)
        #expect(runtime.state.anchor == 0 && runtime.state.cursor == boundary)
        #expect(runtime.state.caretAffinity == .upstream)
        runtime.pointerMove(to: secondStart, mods: Mods(shift: true), at: 4.01)
        #expect(runtime.state.anchor == 0 && runtime.state.cursor == boundary)
        #expect(runtime.state.caretAffinity == .downstream)
        runtime.pointerMove(to: firstEnd, mods: Mods(shift: true), at: 4.02)
        runtime.pointerUp(at: firstEnd, mods: Mods(shift: true), at: 4.03)
        #expect(runtime.state.anchor == 0 && runtime.state.cursor == boundary)
        #expect(runtime.state.caretAffinity == .upstream)
    }

    @Test(arguments: [false, true])
    func secureFieldUsesTheDisplayedGraphemePositions(revealed: Bool) throws {
        let prefix = "A👩🏽‍💻"
        let text = prefix + "éZ"
        let style = TextStyle(size: 20).lh(28)
        let runtime = Runtime(state: TextEdit(text), viewport: Vec2(240, 42), pixelScale: 1) { _, _ in
            textInput(key: "field", \TextEdit.self).singleLine(true).font(style)
                .secure().revealed(revealed).size(240, 42)
        }
        _ = runtime.frame(at: 0)
        let rect = try #require(runtime.element(byKey: "field")?.rect)
        let display = revealed ? text : String(repeating: "•", count: text.unicodeScalars.count)
        let end = revealed ? prefix.utf8.count : prefix.unicodeScalars.count * "•".utf8.count
        let shaped = runtime.textSystem.shape(text: display, style: style, maxWidth: nil, pixelScale: 1, emitGlyphs: false)
        let caret = runtime.textSystem.caretRect(in: shaped, utf8Offset: end, affinity: .downstream, pixelScale: 1)
        let point = Vec2(rect[0] + caret.x + 0.25, rect[1] + caret.y + caret.w * 0.5)
        runtime.pointerDown(at: point, at: 1)
        runtime.pointerUp(at: point, at: 1.01)
        #expect(runtime.state.cursor == prefix.utf8.count)
        #expect(runtime.state.anchor == prefix.utf8.count)
        _ = runtime.frame(at: 1.02)
        let painted = try #require(runtime.element(byKey: "field")?.caret)
        #expect(abs(painted[0] - (rect[0] + caret.x)) < 1)
    }

    #if canImport(CoreText) || os(Linux) || os(Windows)
    @Test func clickBothVisualPositionsOfABidirectionalCaret() throws {
        let text = "AאבB"
        let style = TextStyle(size: 24).lh(32)
        let runtime = Runtime(state: TextEdit(text), viewport: Vec2(200, 48), pixelScale: 1) { _, _ in
            textInput(key: "field", \TextEdit.self).font(style).singleLine(true).size(200, 48)
        }
        _ = runtime.frame(at: 0)
        let rect = try #require(runtime.element(byKey: "field")?.rect)
        let shaped = runtime.textSystem.shape(text: text, style: style, maxWidth: nil, pixelScale: 1, emitGlyphs: false)
        let upstream = runtime.textSystem.caretRect(in: shaped, utf8Offset: 1, affinity: .upstream, pixelScale: 1)
        let downstream = runtime.textSystem.caretRect(in: shaped, utf8Offset: 1, affinity: .downstream, pixelScale: 1)
        #expect(upstream.x < downstream.x)
        for (time, caret, side) in [(1.0, upstream, TextAffinity.upstream), (2.0, downstream, .downstream)] {
            // Approach the left seam from inside the A and the right seam from inside the Alef.
            let point = Vec2(rect[0] + caret.x - 0.5, rect[1] + caret.y + caret.w * 0.5)
            runtime.pointerDown(at: point, at: time)
            runtime.pointerUp(at: point, at: time + 0.01)
            #expect(runtime.state.cursor == 1 && runtime.state.anchor == 1)
            #expect(runtime.state.caretAffinity == side)
            _ = runtime.frame(at: time + 0.02)
            let painted = try #require(runtime.element(byKey: "field")?.caret)
            #expect(abs(painted[0] - (rect[0] + caret.x)) < 1)
        }
    }
    #endif
}
