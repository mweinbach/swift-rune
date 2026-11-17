#if canImport(CoreText)
import CoreText
#endif
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

    @MainActor
    @Test("fonts arriving after a browser frame rebuild committed text at a new font epoch")
    func lateFacesInvalidateCommittedText() throws {
        let content = "Tiếng Việt ἀρχή Әліппе"
        let host = WebAppHost(spec: AppSpec(title: "Fonts", size: Vec2(300, 100), state: 0) { _, _ in
            text(content)
        })
        let browser = WebBrowserSession(host)
        let first = try browser.renderFrame(at: 0)
        _ = try #require(first)
        let before = try #require(host.runtime.textSystem.layoutKeys().first { $0.authText == content })
        let commits = host.runtime.viewCommitCount
        let otherHost = WebAppHost(spec: AppSpec(title: "Another document", size: Vec2(300, 100), state: 0) { _, _ in
            text(content)
        })
        _ = try WebBrowserSession(otherHost).renderFrame(at: 0)
        let otherEpoch = otherHost.runtime.textSystem.currentFontEpoch
        browser.fontsChanged()
        #expect(host.runtime.hasPendingCommit)
        #expect(otherHost.runtime.textSystem.currentFontEpoch == otherEpoch)
        #expect(!otherHost.runtime.hasPendingCommit)
        let next = try browser.renderFrame(at: 1)
        _ = try #require(next)
        let after = try #require(host.runtime.textSystem.layoutKeys().first { $0.authText == content })
        #expect(after.fontEpoch != before.fontEpoch)
        #expect(host.runtime.viewCommitCount > commits)
    }

    #if !os(WASI)
    @Test("fontUrl and fontUrlLater accept native paths and file URLs")
    func nativeFontURLsLoadAppData() throws {
        let url = try #require(DefaultFonts.fontURL(named: "IBMPlexMono-Regular"))
        let data = try Data(contentsOf: url)
        let app = App(title: "Fonts", state: 0) { _, _ in text("Fonts") }
        #expect(app.fontUrl(url.path).fontData == [data])
        #expect(app.fontUrlLater(url.absoluteString).intoSpec().fonts == [data])
    }
    #endif

    #if canImport(CoreText)
    @Test("native default slots both resolve to Inter, including intermediate CSS weights")
    func nativeDefaultFamiliesMatchRust() throws {
        let ts = TextSystem()
        let cases: [(Float, String)] = [(350, "Regular"), (399.75, "Regular"), (400, "Regular"), (400.25, "Medium"), (401, "Medium"),
                                        (440, "Medium"), (499.75, "Medium"), (500, "Medium"), (500.25, "SemiBold"), (501, "SemiBold"),
                                        (550, "SemiBold"), (600, "SemiBold"), (900, "SemiBold")]
        for (weight, face) in cases {
            let style = TextStyle(size: 13, weight: weight)
            for selected in [style, style.mono()] {
                let font = ts.resolveCTFont(style: selected, pixelScale: 1)
                #expect(CTFontCopyPostScriptName(font) as String == "Inter-\(face)")
            }
        }
        withFontFamilies(sans: "Inter", mono: "IBM Plex Mono") {
            let configured = TextSystem().resolveCTFont(style: TextStyle(size: 13).mono(), pixelScale: 1)
            #expect(CTFontCopyPostScriptName(configured) as String == "IBMPlexMono")
        }
    }
    #endif

    #if os(Linux) && canImport(CRuneDesktopText)
    @Test("Linux static faces follow CSS directional matching between bundled Inter cuts")
    func linuxStaticWeightsMatchRust() {
        let text = TextSystem()
        func width(_ weight: Float) -> Float {
            text.measure("Rust", style: TextStyle(size: 18, weight: weight, family: .named("Rune Missing Font, Inter")),
                         maxWidth: nil, pixelScale: 1).x
        }
        let regular = width(400), medium = width(500), semibold = width(600)
        #expect(regular < medium && medium < semibold)
        #expect(width(350) == regular && width(399.75) == regular)
        #expect(width(400.25) == medium && width(401) == medium && width(440) == medium && width(499.75) == medium)
        #expect(width(500.25) == semibold && width(501) == semibold && width(550) == semibold && width(900) == semibold)
    }
    #endif

    #if canImport(CoreText) || os(Linux)
    @Test("fractional CSS weights reach a variable face and an authored wght coordinate takes precedence")
    func variableWeightsAndExplicitAxes() async throws {
        #if os(macOS) || os(Linux) || os(Windows)
        await #expect(processExitsWith: .success) { try Self.checkVariableWeightsAndExplicitAxes() }
        #else
        try Self.checkVariableWeightsAndExplicitAxes()
        #endif
    }

    private static func checkVariableWeightsAndExplicitAxes() throws {
        let url = try #require(Bundle.module.url(forResource: "RuneFractionalWeight", withExtension: "ttf", subdirectory: "Fixtures"))
        HeadlessRunner.registerFonts([try Data(contentsOf: url)])
        let system = TextSystem()
        let family = FontFamily.named("Rune Fractional Weight Fixture")
        func width(_ weight: Float, _ axis: Float? = nil) -> Float {
            let style = TextStyle(size: 32, weight: weight, family: family)
            return system.measure("R", style: axis.map { style.variations("'wght' \($0)") } ?? style, maxWidth: nil, pixelScale: 1).x
        }
        // This two-glyph fixture's R advances by ten design units for each unit of wght.
        for weight: Float in [399.75, 400.25, 499.75, 500.25] {
            #expect(width(weight) == width(400, weight))
        }
        #expect(width(399.75) < width(400) && width(400) < width(400.25))
        #expect(width(499.75) < width(500) && width(500) < width(500.25))
        #expect(width(400.25, 500.25) == width(500.25))
        #expect(width(500.25, 399.75) == width(399.75))
    }
    #endif

    @Test("named font stacks prefer available faces and fall back to the active sans family")
    func namedFontsFallBackToTheActiveSansFamily() {
        withFontFamilies(sans: DefaultFonts.monoFamily, mono: DefaultFonts.monoFamily) {
            let text = TextSystem()
            let missing = "Rune Unavailable Typeface"
            func width(_ family: FontFamily) -> Float {
                text.measure("iiii W0", style: TextStyle(size: 18, family: family),
                             maxWidth: nil, pixelScale: 2).x
            }
            let sans = width(.systemUI)
            let inter = width(.named(DefaultFonts.sansFamily))
            #expect(width(.named(missing)) == sans)
            #expect(inter != sans)
            #expect(width(.named("\(missing), 'Inter', \"IBM Plex Mono\"")) == inter)
            #expect(width(.named("'\(missing), Inter'")) == sans)
        }
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
