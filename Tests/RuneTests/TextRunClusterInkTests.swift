import Foundation
#if canImport(CRuneDesktopText) && !canImport(CoreText)
import CRuneDesktopText
#endif
import Testing
@testable import Rune

#if canImport(CoreText) || os(Linux) || os(Windows)
@Suite("Text run cluster ink")
struct TextRunClusterInkTests {
    @Test func authoredOffsetsSurviveShapingAndSliceOffsetsAreLocal() throws {
        let system = TextSystem()
        let run = TextRun("Aאֱe\u{301}Z")
        let style = TextStyle(size: 18)
        let layout = system.runLayout(run, style: style, scale: 2)
        var byte = 0
        for ch in run.text {
            let glyphs = system.glyphsIn(run: layout, at: byte, origin: Vec2(3, 8))
            #expect(!glyphs.isEmpty)
            #expect(glyphs.allSatisfy { $0.utf8Offset == byte })
            let slice = try #require(system.shapeRunSlice(run, at: byte, style: style, pixelScale: 2))
            #expect(!slice.glyphs.isEmpty)
            #expect(slice.glyphs.allSatisfy { $0.utf8Offset == 0 })
            byte += ch.utf8.count
        }
    }

    @Test func preparedClustersKeepExactUTF8OffsetsAndScale() throws {
        let system = TextSystem()
        let style = TextStyle(size: 24)
        let composed = TextRun("éA"), decomposed = TextRun("e\u{301}A")
        let scale: Float = 2.001, nextScale: Float = 2.003
        let ordinary = system.cachedRunCellLayout(composed, style: style, pixelScale: scale)
        let resized = system.cachedRunCellLayout(composed, style: style, pixelScale: nextScale)
        #expect(ordinary !== resized)
        #expect(resized.pixelScale == nextScale)
        let inputs = [(composed, 2, scale), (decomposed, 3, scale), (decomposed, 3, nextScale),
                      (TextRun("a\u{301}\u{323}B"), 5, scale), (TextRun("a\u{323}\u{301}B"), 5, scale)]
        #expect(system.prepareLayouts {
            for (run, _, factor) in inputs {
                _ = system.cachedRunCellLayout(run, style: style, pixelScale: factor)
            }
        } == inputs.count)
        for (run, offset, requestedScale) in inputs {
            let layout = system.runLayout(run, style: style, scale: requestedScale)
            let cells = try #require(layout.cellLayout)
            #expect(cells.pixelScale == requestedScale)
            #expect(cells.text.utf8.elementsEqual(run.text.utf8))
            let glyph = try #require(system.glyphsIn(run: layout, at: offset).first)
            #expect(glyph.utf8Offset == offset)
            #expect(layout.advance(atUTF8Offset: offset) != nil)
            let same = TextSystem().runLayout(run, style: style, scale: requestedScale)
            #expect(layout.graphemes == same.graphemes)
        }
    }

    // Run the same font and shaping-cluster offsets as Rune Rust. On machines
    // without system DejaVu, RUNE_DEJAVU_SANS points to the same unmodified TTF.
    private static let fontPath = ProcessInfo.processInfo.environment["RUNE_DEJAVU_SANS"]
        ?? "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: fontPath), "Requires DejaVu Sans"))
    func preparedAndColdRunsOwnCompleteLigaturesAndCombiningMarks() throws {
        HeadlessRunner.registerFonts([try Data(contentsOf: URL(fileURLWithPath: Self.fontPath))])
        let style = TextStyle(size: 24, family: .custom("DejaVu Sans"))
        let cases: [(String, Set<Int>)] = [
            ("éfi", [0, 2]), ("office", [0, 1, 4, 5]), ("لا", [0]),
            ("لَا", [0]), ("سَلَام", [0, 4, 10]), ("אֱב", [0, 4])
        ]
        for (string, owners) in cases {
            let run = TextRun(string)
            let system = TextSystem()
            let cold = system.runLayout(run, style: style, scale: 2)
            let origin = Vec2(3.25, 12)
            var coldGlyphs: [Int: [PositionedGlyph]] = [:]
            var byte = 0
            for ch in string {
                let glyphs = system.glyphsIn(run: cold, at: byte, origin: origin)
                #expect(!glyphs.isEmpty == owners.contains(byte))
                coldGlyphs[byte] = glyphs
                byte += ch.utf8.count
            }
            #expect(system.prepareLayouts {
                _ = system.cachedRunCellLayout(run, style: style, pixelScale: 2)
            } == 1)
            let prepared = system.runLayout(run, style: style, scale: 2)
            for (offset, glyphs) in coldGlyphs {
                #expect(system.glyphsIn(run: prepared, at: offset, origin: origin) == glyphs)
                let slice = try #require(system.shapeRunSlice(run, at: offset, style: style, pixelScale: 2))
                #expect(!slice.glyphs.isEmpty == owners.contains(offset))
                #expect(slice.size.x == cold.advance(atUTF8Offset: offset))
            }
        }
    }
    #if canImport(CRuneDesktopText) && !canImport(CoreText)
    @Test(.enabled(if: FileManager.default.fileExists(atPath: fontPath), "Requires DejaVu Sans"))
    func isolatedGlyphsPreserveTheWholeNativeMask() throws {
        HeadlessRunner.registerFonts([try Data(contentsOf: URL(fileURLWithPath: Self.fontPath))])
        for text in ["ffi", "لا", "لَا", "אֱ"] {
            let length = Int32(text.utf8.count)
            let line = try #require(rune_desktop_line_create(text, length, "DejaVu Sans", 32, 400, 0, 0, 0))
            defer { rune_desktop_line_destroy(line) }
            let rect = rune_desktop_line_metrics(line)
            func mask(_ native: OpaquePointer) throws -> [UInt8] {
                var pixels = [UInt8](repeating: 0, count: Int(rect.ink_width * rect.ink_height))
                let ok = rune_desktop_line_mask(native, rect.ink_x, rect.ink_y, rect.ink_width, rect.ink_height, &pixels)
                try #require(ok != 0)
                return pixels
            }
            let reference = try mask(line)
            #expect(reference.contains { $0 > 0 })
            var byte: Int32 = 0
            for ch in text {
                let next = byte + Int32(ch.utf8.count)
                let ink = try #require(rune_desktop_line_extract_ink(line, byte, next))
                defer { rune_desktop_line_destroy(ink) }
                let owned = try mask(ink)
                if byte == 0 {
                    #expect(owned == reference)
                } else {
                    #expect(owned.allSatisfy { $0 == 0 })
                    #expect(rune_desktop_line_metrics(ink).ink_width == 0)
                }
                byte = next
            }
            if text == "ffi" {
                let saved = try #require(rune_desktop_line_extract_ink(line, 0, 1))
                defer { rune_desktop_line_destroy(saved) }
                rune_desktop_line_configure(line, nil, "liga=0", nil)
                let middle = try #require(rune_desktop_line_extract_ink(line, 1, 2))
                defer { rune_desktop_line_destroy(middle) }
                #expect(rune_desktop_line_metrics(middle).ink_width > 0)
                #expect(try mask(saved) == reference)
            }
        }
    }
    #endif

}
#endif
