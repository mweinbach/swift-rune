import Foundation
import Testing
@testable import Rune
#if canImport(CoreText)
import CoreText
#endif

@Suite("System monospace font selection")
struct SystemMonoParityTests {
    @Test func distinctFamiliesSurviveEncoding() throws {
        #expect(FontFamily.systemMono != .monospace)
        #expect(try JSONDecoder().decode(FontFamily.self, from: Data(#"{"monospace":{}}"#.utf8)) == .monospace)
        let encoded = try JSONEncoder().encode(FontFamily.systemMono)
        #expect(try JSONDecoder().decode(FontFamily.self, from: encoded) == .systemMono)
        #expect(PixelCompare.cases(for: .mono).allSatisfy { $0.family == .systemMono })
    }

    @Test func expandsGenericInPlaceAndPreservesQuotedNames() {
        func expand(_ stack: String, _ installed: [String] = []) -> String {
            FontFamily.expandingSystemMono(in: stack, fallback: "Inter, sans-serif", system: installed)
        }
        #expect(expand("ui-monospace") == "Inter, sans-serif")
        #expect(expand("ui-monospace", ["Menlo"]) == "Menlo")
        #expect(expand("ui-monospace, Iosevka") == "Iosevka")
        #expect(expand("monospace") == "monospace")
        #expect(expand("'ui-monospace'", ["Menlo"]) == "'ui-monospace'")
        #expect(expand(#""A, B", UI-MONOSPACE, C\,D"#, ["Menlo"]) == #""A, B", Menlo, C\,D"#)
    }

    @Test func systemFaceAndSlotWidths() {
        withFontFamilies(sans: "Inter", mono: "Inter") {
            let ts = TextSystem()
            let system = TextStyle(size: 16).family(.systemMono)
            func width(_ text: String, _ style: TextStyle) -> Float {
                ts.measure(text, style: style, maxWidth: nil, pixelScale: 2).x
            }
            #if canImport(CoreText) || os(Linux) || os(Windows)
            #expect(abs(width("iiiiiiii", system) - width("MMMMMMMM", system)) < 0.5)
            #expect(abs(width("iiiiiiii", system.mono()) - width("MMMMMMMM", system.mono())) > 10)
            let block = width("iiWW", system)
            _ = ts.setFamilies(sans: "Inter", mono: "ui-monospace, Inter")
            #expect(abs(width("iiWW", system.mono()) - block) < 0.01)
            #else
            #expect(width("iiWW", system) == width("iiWW", system.mono()))
            #endif
        }
    }

    #if canImport(CoreText)
    @Test func appleBlockInlineAndCodeFeatures() {
        withFontFamilies(sans: "Inter", mono: "ui-monospace, Inter") {
            let ts = TextSystem()
            let plain = TextStyle(size: 16)
            let system = plain.family(.systemMono)
            func runs(_ text: String, _ style: TextStyle, _ spans: [TextSpan]? = nil) -> [CTRun] {
                let shaped = ts.shape(text: text, spans: spans, style: style, maxWidth: nil, pixelScale: 1)
                return shaped.lineStrings.flatMap { $0.ctLine.map { CTLineGetGlyphRuns($0) as! [CTRun] } ?? [] }
            }
            func name(_ run: CTRun?) -> String? {
                guard let run else { return nil }
                let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                return CTFontCopyPostScriptName(font) as String
            }
            let block = name(runs("code", system).first)
            #expect(block?.localizedCaseInsensitiveContains("mono") == true)
            #expect(name(runs("see code", plain, [TextSpan("see "), TextSpan("code", monospace: true)]).last) == block)
            _ = ts.setFamilies(sans: "Inter", mono: "Inter")
            func glyphs(_ text: String, _ style: TextStyle, _ spans: [TextSpan]? = nil) -> [CGGlyph] {
                runs(text, style, spans).flatMap { run -> [CGGlyph] in
                    var ids = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                    CTRunGetGlyphs(run, CFRangeMake(0, 0), &ids)
                    return ids
                }
            }
            let mono = plain.mono().features("'calt' 1")
            let separate = ["a", "-", ">", "b"].flatMap { glyphs($0, mono) }
            #expect(glyphs("a->b", mono) == separate)
            #expect(glyphs("a->b", plain, [TextSpan("a->b", monospace: true)]) == separate)
            #expect(glyphs("a->b", plain) != separate)
            #expect(glyphs("a->b", system) == ["a", "-", ">", "b"].flatMap { glyphs($0, system) })
        }
    }
    #endif
}
