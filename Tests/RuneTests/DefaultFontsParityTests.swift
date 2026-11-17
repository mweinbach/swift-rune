import CoreText
import Foundation
import Testing
@testable import Rune

@Suite("DefaultFonts parity")
struct DefaultFontsParityTests {
    @Test("bundled Inter and IBM Plex Mono font assets and licenses exist in Bundle.module")
    func bundledAssetsPresentAndRegistered() throws {
        for name in DefaultFonts.bundledFontNames {
            let url = DefaultFonts.fontURL(named: name)
            #expect(url != nil, "Missing bundled font \(name).ttf")
        }
        for license in ["Inter-LICENSE", "IBMPlexMono-LICENSE"] {
            let url = DefaultFonts.resourceBundle.url(
                forResource: license,
                withExtension: "txt",
                subdirectory: "Fonts"
            )
            #expect(url != nil, "Missing license \(license).txt")
        }
        #expect(DefaultFonts.registerIfNeeded())
    }

    @Test("default systemUI resolves to Inter across weights and monospace resolves to IBM Plex Mono")
    func defaultFamiliesResolveToBundledInterAndPlex() throws {
        let ts = TextSystem()
        let regular = ts.resolveCTFont(style: TextStyle(size: 13, weight: 400), pixelScale: 1)
        let medium = ts.resolveCTFont(style: TextStyle(size: 15, weight: 500), pixelScale: 1)
        let semibold = ts.resolveCTFont(style: TextStyle(size: 24, weight: 600), pixelScale: 1)
        let mono = ts.resolveCTFont(style: TextStyle(size: 13, weight: 400).mono(), pixelScale: 1)

        #expect((CTFontCopyFamilyName(regular) as String) == "Inter")
        #expect((CTFontCopyFamilyName(medium) as String) == "Inter")
        #expect((CTFontCopyFamilyName(semibold) as String) == "Inter")
        #expect((CTFontCopyFamilyName(mono) as String) == "IBM Plex Mono")

        #expect((CTFontCopyPostScriptName(regular) as String) == "Inter-Regular")
        #expect((CTFontCopyPostScriptName(medium) as String) == "Inter-Medium")
        #expect((CTFontCopyPostScriptName(semibold) as String) == "Inter-SemiBold")
        #expect((CTFontCopyPostScriptName(mono) as String) == "IBMPlexMono")
    }

    @Test("default fonts shape representative Latin/Unicode/code strings deterministically")
    func defaultFontsShapeDeterministically() throws {
        let texts = [
            "Rune → office “quotes” fi ffl AVAWAY 1/2 ½ €100",
            "Ýüñçø Ωμέγα Привет",
            "fn main() { let x = a != b; } // -> =>",
        ]
        let styles = [
            TextStyle(size: 13, weight: 400),
            TextStyle(size: 15, weight: 500),
            TextStyle(size: 24, weight: 600),
            TextStyle(size: 13, weight: 400).mono(),
        ]

        func shapeAll() -> [SIMD4<Float>] {
            let ts = TextSystem()
            var out: [SIMD4<Float>] = []
            for text in texts {
                for style in styles {
                    let shaped = ts.shape(
                        text: text,
                        spans: nil,
                        pills: [],
                        style: style,
                        maxWidth: nil,
                        pixelScale: 2.0,
                        emitGlyphs: true
                    )
                    #expect(shaped.size.x > 0)
                    for g in shaped.glyphs {
                        out.append(g.rect)
                    }
                }
            }
            return out
        }

        let first = shapeAll()
        let second = shapeAll()
        #expect(first.count > 250)
        #expect(first == second)
    }

    @Test("a family switch updates measured text and cached run cells only within its scope")
    func scopedFamilySwitchSeparatesRunCells() throws {
        let ts = TextSystem()
        let run = TextRun("iiiiiiii")
        let mono = TextStyle(size: 14, weight: 400).mono()
        try withFontFamilies(sans: "Inter", mono: "IBM Plex Mono") {
            let original = ts.runLayout(run, style: mono)
            let epoch = ts.currentFontEpoch
            try withFontFamilies(sans: "Inter", mono: "IBM Plex Mono") {
                #expect(ts.setFamilies(sans: "Inter", mono: "Inter"))
                #expect(ts.families().mono == "Inter")
                let switched = ts.runLayout(run, style: mono)
                let cellWidth = try #require(switched.cellLayout?.advance(atByte: 0))
                #expect(cellWidth == switched.advance(atUTF8Offset: 0))
                #expect(switched.totalWidthPx < original.totalWidthPx)
                #expect(TextMeasure.advance(run.text, style: mono) == switched.totalWidthPx)
                #expect(ts.currentFontEpoch == fontEpoch() && ts.currentFontEpoch != epoch)
            }
            #expect(ts.families().mono == "IBM Plex Mono")
            #expect(ts.currentFontEpoch == epoch)
            #expect(ts.runLayout(run, style: mono).totalWidthPx == original.totalWidthPx)
        }
    }

    @Test("OpenType tnum feature equalizes digit widths in bundled Inter")
    func openTypeTabularFiguresEqualizeDigitWidths() throws {
        let ts = TextSystem()
        let tnumStyle = TextStyle(size: 12.0, weight: 440.0).features("'tnum' 1")
        let propStyle = TextStyle(size: 12.0, weight: 440.0)
        let tnum0 = ts.shape(text: "0", spans: nil, pills: [], style: tnumStyle, maxWidth: nil, pixelScale: 2.0, emitGlyphs: false).size.x
        let tnum1 = ts.shape(text: "1", spans: nil, pills: [], style: tnumStyle, maxWidth: nil, pixelScale: 2.0, emitGlyphs: false).size.x
        let prop0 = ts.shape(text: "0", spans: nil, pills: [], style: propStyle, maxWidth: nil, pixelScale: 2.0, emitGlyphs: false).size.x
        let prop1 = ts.shape(text: "1", spans: nil, pills: [], style: propStyle, maxWidth: nil, pixelScale: 2.0, emitGlyphs: false).size.x
        #expect(abs(tnum0 - tnum1) < 0.01, "tnum '0' (\(tnum0)) and '1' (\(tnum1)) must have equal advance")
        #expect(tnum1 > prop1, "tabular '1' (\(tnum1)) is wider than proportional '1' (\(prop1))")
        #expect(prop0 > prop1)
    }
}
