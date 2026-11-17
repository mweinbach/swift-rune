import Testing
@testable import Rune

@Suite("Bidirectional text run cells")
struct TextRunBidiTests {
    @Test(arguments: ["אבג", "Aא\u{05B7}בגB"])
    func measuresAndPaintsEachVisualCell(_ string: String) throws {
        let system = TextSystem()
        let style = TextStyle(size: 24)
        let scale: Float = 2
        let run = TextRun(string)
        let layout = system.runLayout(run, style: style, scale: scale)
        var byte = 0
        var sum: Float = 0
        for character in string {
            let measured = try #require(system.measureRunSlice(run, at: byte, style: style, pixelScale: scale))
            let slice = try #require(system.shapeRunSlice(run, at: byte, style: style, pixelScale: scale))
            let advance = try #require(layout.advance(atUTF8Offset: byte))
            #expect(measured.x > 0)
            #expect(slice.size.x == measured.x)
            #expect(advance == measured.x)
            // Each cell's ink must overlap its local box, including at a direction switch.
            #expect(slice.glyphs.contains { $0.rect.x < measured.x && $0.rect.x + $0.rect.z > 0 })
            let rtl = !character.isASCII
            let end = character.utf8.count
            let leadingX: Float = rtl ? measured.x : 0
            let trailingX: Float = rtl ? 0 : measured.x
            #expect(system.caretRect(in: slice, utf8Offset: 0, pixelScale: scale).x == leadingX)
            #expect(system.caretRect(in: slice, utf8Offset: end, affinity: .upstream,
                                     pixelScale: scale).x == trailingX)
            #expect(system.hitTestUTF8Offset(in: slice, localX: leadingX, localY: 0, pixelScale: scale) == 0)
            #expect(system.hitTestUTF8Offset(in: slice, localX: trailingX, localY: 0, pixelScale: scale) == end)
            #expect(system.selectionRects(in: slice, utf8Range: 0..<end, pixelScale: scale).first?.z == measured.x)
            sum += measured.x
            byte += character.utf8.count
        }
        #expect(abs(sum * scale - layout.totalWidthPx) <= 1.0 / 64)
    }
}
