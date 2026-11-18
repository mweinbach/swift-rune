import Foundation
#if canImport(CRuneDesktopText) && !canImport(CoreText)
import CRuneDesktopText
#endif
import Testing
@testable import Rune

#if canImport(CoreText) || os(Linux) || os(Windows)
@Suite("Text run cluster ink")
struct TextRunClusterInkTests {
    #if os(Linux)
    @Test func missingCJKUsesTheSelectedFacesNotdefAdvanceForMetricsAndCarets() async {
        await #expect(processExitsWith: .success) { try Self.checkMissingCJKMetricsAndCarets() }
    }

    private static func checkMissingCJKMetricsAndCarets() throws {
        // Isolate Fontconfig so locale-specific fallback cannot choose a system
        // face for the same missing scalar.
        let config = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "<fontconfig/>".write(to: config, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: config) }
        try #require(setenv("FONTCONFIG_FILE", config.path, 1) == 0)
        try #require(DefaultFonts.registerIfNeeded())
        let sample = "漢字、かな。 漢字"
        let style = TextStyle(size: 13, lineHeight: 20, family: .monospace, wrap: .wrap)
        let shaped = TextSystem().shape(text: sample, style: style, maxWidth: 72, pixelScale: 1)
        #expect(shaped.lineCount == 1)
        #expect(shaped.size.x == 71.90625)

        // Inter's glyph zero advances 1344 design units at 2048 units per em.
        // Four-byte Han scalars exercise both the native and indexed caret paths.
        let pair = "\u{20000}\u{20001}"
        for repeats in [1, 20] {
            let text = String(repeating: pair, count: repeats)
            let length = Int32(text.utf8.count)
            for size: Float in [13, 26] {
                let line = try #require(rune_desktop_line_create(text, length, "Inter", size, 400, 0, 0, 1))
                defer { rune_desktop_line_destroy(line) }
                let expected = size * 1344 / 2048
                for configured in [false, true] {
                    if configured { rune_desktop_line_configure(line, "ja", "liga=0", nil) }
                    #expect(rune_desktop_line_metrics(line).advance == Float(repeats * 2) * expected)
                    for byte in stride(from: Int32(0), to: length, by: 4) {
                        var left: Float = 0, advance: Float = 0
                        #expect(rune_desktop_line_cell(line, byte, byte + 4, &left, &advance) == 1)
                        #expect(left == Float(byte / 4) * expected && advance == expected)
                        #expect(rune_desktop_line_caret(line, byte + 4) == left + advance)
                    }
                }
            }
        }
    }

    @Test func monoScriptFallbackKeepsArabicMarksAndPreservesThePrimarySpace() throws {
        _ = DefaultFonts.registerIfNeeded()
        func width(_ text: String, family: String, mono: Bool, configured: Bool) throws -> Float {
            let line = try #require(rune_desktop_line_create(text, Int32(text.utf8.count),
                family, 13, 400, 0, mono ? 1 : 0, 2))
            defer { rune_desktop_line_destroy(line) }
            if configured { rune_desktop_line_configure(line, "ar", "liga=0", nil) }
            return rune_desktop_line_metrics(line).advance
        }
        // Inter needs a fallback for these scripts. A requested face that covers
        // the word takes precedence over the extra monospace family.
        for primary in ["Inter", "DejaVu Sans"] {
            for configured in [false, true] {
                let spaces = try width("  ", family: primary, mono: false, configured: configured)
                for word in ["مرحبا", "مَّرحبا", "שָׁלוֹם"] {
                    let letters = try width(word, family: primary + ", DejaVu Sans Mono",
                                            mono: false, configured: configured)
                    let code = try width(word + "  ", family: primary, mono: true, configured: configured)
                    #expect(abs(code - letters - spaces) < 1.0 / 64.0)
                }
            }
        }
    }
    #endif

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
    func preparedAndColdRunsOwnCompleteLigaturesAndCombiningMarks() async throws {
        #if os(macOS) || os(Linux) || os(Windows)
        await #expect(processExitsWith: .success) { try Self.checkPreparedAndColdRunsOwnCompleteLigaturesAndCombiningMarks() }
        #else
        try Self.checkPreparedAndColdRunsOwnCompleteLigaturesAndCombiningMarks()
        #endif
    }

    private static func checkPreparedAndColdRunsOwnCompleteLigaturesAndCombiningMarks() throws {
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
    func isolatedGlyphsPreserveTheWholeNativeMask() async throws {
        #if os(Linux) || os(Windows)
        await #expect(processExitsWith: .success) { try Self.checkIsolatedGlyphsPreserveTheWholeNativeMask() }
        #else
        try Self.checkIsolatedGlyphsPreserveTheWholeNativeMask()
        #endif
    }

    private static func checkIsolatedGlyphsPreserveTheWholeNativeMask() throws {
        HeadlessRunner.registerFonts([try Data(contentsOf: URL(fileURLWithPath: Self.fontPath))])
        for text in ["ffi", "لا", "لَا", "אֱ"] {
            let length = Int32(text.utf8.count)
            let line = try #require(rune_desktop_line_create(text, length, "DejaVu Sans", 32, 400, 0, 0, 0))
            defer { rune_desktop_line_destroy(line) }
            let rect = rune_desktop_line_metrics(line)
            if text == "ffi" || text == "لا" {
                for index in 0..<length {
                    #expect(rune_desktop_line_cluster_owner(line, index) == 0)
                }
                #expect(rune_desktop_line_cluster_owner(line, length) == length)
            }
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
                for index in 0..<length {
                    #expect(rune_desktop_line_cluster_owner(line, index) == index)
                }
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
