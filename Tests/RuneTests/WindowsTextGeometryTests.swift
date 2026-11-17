import RuneMotion
import Testing
@testable import Rune

@Suite("Windows UI Automation text geometry")
struct WindowsTextGeometryTests {
    @Test func clientPixelsUseVisualPositionsAndLogicalUTF16Ranges() throws {
        let text = "Aאב🙂Z"
        var shaped = ShapedText(size: Vec2(40, 19), lineCount: 1, lineHeight: 16,
                                glyphs: [], underlines: [], backgrounds: [])
        shaped.drawnText = text
        shaped.portableLines = [(0, text, 3, 2, [0, 6, 6, 14, 14, 23, 23, 23, 23, 30, 38])]
        shaped.portableBidiCells[0] = [
            .init(range: 0..<1, left: 0, width: 6, rtl: false, space: false),
            .init(range: 3..<5, left: 6, width: 9, rtl: true, space: false),
            .init(range: 1..<3, left: 15, width: 8, rtl: true, space: false),
            .init(range: 5..<9, left: 23, width: 7, rtl: false, space: false),
            .init(range: 9..<10, left: 30, width: 8, rtl: false, space: false),
        ]

        let cells = try #require(AccessibilityTextGeometry.cells(
            for: text, shaped: shaped, origin: Vec2(10, 4), scale: Vec2(2, 1), pixelScale: 2,
            clip: .fromXYWH(17, 8, 51, 8)))
        let logical = cells.sorted { $0.start < $1.start }
        #expect(logical.map(\.start) == [0, 1, 2, 3, 5])
        #expect(logical.map(\.end) == [1, 2, 3, 5, 6])
        #expect(logical.map(\.line) == [0, 0, 0, 0, 0])
        #expect(logical.map(\.rtl) == [false, true, true, false, false])
        // The first glyph and emoji are clipped on opposite sides. Their original
        // midpoints still decide which insertion edge the pointer is nearest to.
        #expect(logical.map(\.hitMidpoint) == [40, 104, 70, 134, 164])
        let visible = logical.filter { $0.width > 0 }
        #expect(visible.map(\.x) == [34, 88, 52, 120])
        #expect(visible.map(\.width) == [18, 32, 36, 16])
        #expect(visible.map(\.y) == [16, 16, 16, 16])
        #expect(visible.map(\.height) == [16, 16, 16, 16])
        let hidden = try #require(logical.last)
        #expect(hidden.width == 0 && hidden.height == 0)
    }

    @Test func softWrapPreservesGraphemesAndGrownLineBoxes() throws {
        let first = "e\u{301}x"
        let text = first + "🙂B"
        var shaped = ShapedText(size: Vec2(20, 34), lineCount: 2, lineHeight: 16,
                                glyphs: [], underlines: [], backgrounds: [])
        shaped.drawnText = text
        shaped.portableLines = [(0, first, 0, 0, [0, 0, 0, 8, 16]),
                                (first.utf8.count, "🙂B", 16, 0, [0, 0, 0, 0, 12, 18])]
        shaped.grownLineHeightsPt = [16, 18]

        let cells = try #require(AccessibilityTextGeometry.cells(
            for: text, shaped: shaped, origin: .zero, scale: Vec2(1, 1), pixelScale: 1,
            clip: .fromXYWH(0, 0, 100, 100)))
        let logical = cells.sorted { $0.start < $1.start }
        #expect(logical.map(\.start) == [0, 2, 3, 5])
        #expect(logical.map(\.end) == [2, 3, 5, 6])
        #expect(logical.map(\.line) == [0, 0, 1, 1])
        #expect(logical.map(\.x) == [0, 8, 0, 12])
        #expect(logical.map(\.y) == [0, 0, 16, 16])
        #expect(logical.map(\.height) == [16, 16, 18, 18])
    }

    @Test func staleAndTruncatedLayoutCannotPublishRangeCoordinates() {
        var shaped = ShapedText(size: Vec2(10, 16), lineCount: 1, lineHeight: 16,
                                glyphs: [], underlines: [], backgrounds: [])
        shaped.drawnText = "A"
        shaped.portableLines = [(0, "A", 0, 0, [0, 10])]
        let clip = MotionRect.fromXYWH(0, 0, 10, 16)
        #expect(AccessibilityTextGeometry.cells(for: "B", shaped: shaped, origin: .zero,
                                               scale: Vec2(1, 1), pixelScale: 1, clip: clip) == nil)
        shaped.wasTruncated = true
        #expect(AccessibilityTextGeometry.cells(for: "A", shaped: shaped, origin: .zero,
                                               scale: Vec2(1, 1), pixelScale: 1, clip: clip) == nil)
    }

    @Test func hardBreakAndTerminalCaretHaveDistinctRanges() throws {
        let text = "A\r\n"
        var shaped = ShapedText(size: Vec2(10, 32), lineCount: 2, lineHeight: 16,
                                glyphs: [], underlines: [], backgrounds: [])
        shaped.drawnText = text
        shaped.portableLines = [(0, "A", 0, 0, [0, 10]), (3, "", 16, 0, [0])]

        let cells = try #require(AccessibilityTextGeometry.cells(
            for: text, shaped: shaped, origin: .zero, scale: Vec2(1, 1), pixelScale: 1,
            clip: .fromXYWH(0, 0, 40, 40)))
        let logical = cells.sorted { $0.start < $1.start }
        #expect(logical.map(\.start) == [0, 1, 3])
        #expect(logical.map(\.end) == [1, 3, 3])
        #expect(logical.map(\.line) == [0, 0, 1])
        #expect(logical.map(\.x) == [0, 10, 0])
        #expect(logical.map(\.y) == [0, 0, 16])
        #expect(logical.map(\.width) == [10, 0, 0])
        #expect(logical.map(\.height) == [16, 16, 16])
    }

    #if os(Windows)
    @Test(arguments: [Float(480), Float(90)])
    func directWriteGeometryTracksShapedText(atWidth width: Float) throws {
        let text = "Aאב🙂e\u{301} wider word wrapping\nlast"
        let system = TextSystem()
        let style = TextStyle(size: 18, wrap: .wrap, wrapAnywhere: true)
        let pixelScale: Float = 1.5
        let origin = Vec2(8, 3)
        let shaped = system.shape(text: text, style: style, maxWidth: width,
                                  pixelScale: pixelScale, emitGlyphs: false)
        let cells = try #require(AccessibilityTextGeometry.cells(
            for: text, shaped: shaped, origin: origin, scale: Vec2(1, 1), pixelScale: pixelScale,
            clip: .fromXYWH(origin.x, origin.y, width, 600)))
        let logical = cells.sorted { $0.start < $1.start }
        #expect(logical.count == text.count)
        #expect(logical.first?.start == 0)
        #expect(logical.last?.end == Int32(text.utf16.count))
        #expect(zip(logical, logical.dropFirst()).allSatisfy { $0.end == $1.start })
        #expect(Set(logical.map(\.line)).count == shaped.lineCount)
        if width == 90 {
            #expect(shaped.lineCount > 2)
        } else {
            #expect(shaped.lineCount == 2)
        }

        let alef = try #require(logical.first { $0.start == 1 })
        let bet = try #require(logical.first { $0.start == 2 })
        #expect(alef.rtl && bet.rtl && alef.x > bet.x)
        let emoji = try #require(logical.first { $0.start == 3 })
        let combined = try #require(logical.first { $0.start == 5 })
        #expect(emoji.end == 5 && emoji.width > 0)
        #expect(combined.end == 7 && combined.height > 0)

        let measured = try #require(system.selectionRects(in: shaped, utf8Range: 5..<9,
                                                          pixelScale: pixelScale).first)
        #expect(abs(emoji.x - Double((origin.x + measured.x) * pixelScale)) < 0.01)
        #expect(abs(emoji.y - Double((origin.y + measured.y) * pixelScale)) < 0.01)
        #expect(abs(emoji.width - Double(measured.z * pixelScale)) < 0.01)
        #expect(abs(emoji.height - Double(measured.w * pixelScale)) < 0.01)
    }
    #endif
}
