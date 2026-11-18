import Testing
@testable import Rune

@Suite("Span ink in shared-run cells and text flights")
struct TextSpanInkConsumerTests {
    @Test("Cells at the same shared-run offset use their own first-byte ink", arguments: [false, true])
    func advancedCellInk(native: Bool) {
        let run = TextRun("éV")
        let red = Color.rgba8(221, 45, 63)
        let blue = Color.rgba8(38, 100, 217)
        let runtime = Runtime<Void>(state: (), viewport: Vec2(200, 100), pixelScale: 1) { _, _ in
            row().child(rich([TextSpan("V", color: red)]).advanceIn(run, at: 2))
                .child(rich([TextSpan("V", color: blue)]).advanceIn(run, at: 2))
        }
        let fills = native ? runtime.renderFrame(at: 0).instances.map(\.fill) : runtime.frame(at: 0).primitives.map(\.fill)
        #expect(fills.contains(red.simd4(srgb: runtime.srgbBlend)))
        #expect(fills.contains(blue.simd4(srgb: runtime.srgbBlend)))
    }

    @Test("A flight from a measured field takes its resolved decoration ink with it")
    func measuredFieldFlightInk() throws {
        struct State { var edit = TextEdit("AB") }
        let ink = Color.rgba8(46, 175, 105)
        let runtime = Runtime<State>(state: State(), viewport: Vec2(200, 100), pixelScale: 1) { _, _ in
            col().size(200, 100)
                .child(textInput(key: "source", \State.edit).size(180, 35)
                    .decorations([RichSpan(1..<2).color(ink)]))
                .child(text("AB").key("destination"))
        }
        _ = runtime.renderFrame(at: 0)
        runtime.update(at: 0.25) { state, tx in
            state.edit.clear()
            tx.flyText("source", to: "destination")
        }
        _ = runtime.frame(at: 0.25)
        let flight = try #require(runtime.activeTextFlights.first)
        let captured = try #require(flight.sourceLayout)
        #expect(!captured.hasGlyphs)
        var inks: [Int: SIMD4<Float>] = [:]
        runtime.forEachTextFlightGlyph(at: flight.state.born) { glyph, _, color, _ in
            inks[glyph.utf8Offset] = color
        }
        #expect(inks[0] != nil && inks[0] != inks[1])
        #expect(inks[1] == ink.simd4(srgb: runtime.srgbBlend))
    }
}
