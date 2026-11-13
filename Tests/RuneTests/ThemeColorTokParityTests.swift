import Foundation
import Testing
@testable import Rune
@testable import RuneMotion
@testable import RuneRef

@Suite("Theme, Color & Tok Parity Tests")
struct ThemeColorTokParityTests {
    private static let blendThemeJSON = """
    {
      "name": "Test",
      "blend": { "mode": "srgb", "over": "bg" },
      "light": { "bg": "#f8f8f8", "border": "#0000001f" },
      "dark":  { "bg": "#161616", "border": "#ffffff1a" }
    }
    """

    @Test("Color equality, -0.0/NaN Hashable parity, mix linear-light, premul, over, and hex")
    func colorParity() {
        var h1 = Hasher()
        var h2 = Hasher()
        let a = oklcha(0.6, 0.1, 250.0, 0.5)
        let b = oklcha(0.6, 0.1, 250.0, 0.5)
        a.hash(into: &h1)
        b.hash(into: &h2)
        #expect(h1.finalize() == h2.finalize())

        let zero = Color(r: 0.0, g: 0.0, b: 0.0, a: 1.0)
        let negZero = Color(r: -0.0, g: 0.0, b: 0.0, a: 1.0)
        #expect(zero == negZero)
        #expect(zero.hashValue == negZero.hashValue)

        let nanA = Color(r: a.r, g: a.g, b: a.b, a: .nan)
        let nanB = Color(r: a.r, g: a.g, b: a.b, a: -.nan)
        #expect(Color.hashBits(nanA.a) == Color.hashBits(nanB.a))
        #expect(nanA.hashValue == nanB.hashValue)

        #expect(a.hashValue != a.alpha(0.6).hashValue)

        // Straight linear-light mix (`color.rs:46-49`)
        let mid = Color.black.mix(with: .white, t: 0.25)
        #expect(abs(mid.r - 0.25) < 1e-6)
        #expect(abs(mid.g - 0.25) < 1e-6)
        #expect(abs(mid.b - 0.25) < 1e-6)
        #expect(abs(mid.a - 1.0) < 1e-6)

        // Premul, premulSRGB, over, and #rrggbbaa hex()
        let pLin = Color(r: 0.25, g: 0.5, b: 1.0, a: 0.5).premul(0.5)
        #expect(abs(pLin.w - 0.25) < 1e-6)
        #expect(abs(pLin.x - 0.0625) < 1e-6)
        let pSrgb = Color(r: 0.25, g: 0.5, b: 1.0, a: 0.5).premulSRGB(0.5)
        #expect(abs(pSrgb.w - 0.25) < 1e-6)
        #expect(abs(pSrgb.x - RefShader.linearToSRGB(0.25) * 0.25) < 1e-6)
        #expect(abs(pSrgb.z - 0.25) < 1e-6)
        #expect(Color.white.hex() == "#ffffffff")
        #expect(hex("#f0a") == Color.hex("#ff00aa"))
        #expect(hex("#1234") == nil) // #rgb, #rrggbb, #rrggbbaa only for top-level hex()

        let ov = Color.over(SIMD4<Float>(0.2, 0.0, 0.0, 0.5), SIMD4<Float>(0.0, 0.4, 0.0, 1.0))
        #expect(abs(ov.x - 0.2) < 1e-6)
        #expect(abs(ov.y - 0.2) < 1e-6)
        #expect(abs(ov.w - 1.0) < 1e-6)
    }

    @Test("Tok neutral tokens (32/32), accents (6/6), motion LEAD, space/radius, and typography")
    func tokNeutralAndAccentsParity() {
        let dark = Tok.theme(dark: true)
        #expect(dark.bg == oklch(0.185, 0.004, 265.0))
        #expect(dark.card == oklch(0.232, 0.005, 265.0))
        #expect(dark.cardBorder == oklcha(1.0, 0.0, 0.0, 0.05))
        #expect(dark.text == oklch(0.955, 0.003, 265.0))
        #expect(dark.textSecondary == oklch(0.72, 0.008, 265.0))
        #expect(dark.separator == oklcha(1.0, 0.0, 0.0, 0.055))
        #expect(dark.controlTrack == oklcha(1.0, 0.0, 0.0, 0.05))
        #expect(dark.controlOff == oklcha(1.0, 0.0, 0.0, 0.085))
        #expect(dark.indicator == oklch(0.43, 0.006, 265.0))
        #expect(dark.knob == oklch(0.985, 0.0, 0.0))
        #expect(dark.hover == oklcha(1.0, 0.0, 0.0, 0.016))
        #expect(dark.press == oklcha(1.0, 0.0, 0.0, 0.03))
        #expect(dark.shadow == oklcha(0.0, 0.0, 0.0, 0.42))
        #expect(dark.shadowSoft == oklcha(0.0, 0.0, 0.0, 0.28))
        #expect(dark.edge == oklcha(0.0, 0.0, 0.0, 0.3))
        #expect(dark.knobShadow == oklcha(0.0, 0.0, 0.0, 0.3))

        let light = Tok.theme(dark: false)
        #expect(light.bg == oklch(0.958, 0.004, 265.0))
        #expect(light.card == oklch(1.0, 0.0, 0.0))
        #expect(light.cardBorder == oklcha(0.0, 0.0, 0.0, 0.1))
        #expect(light.text == oklch(0.225, 0.006, 265.0))
        #expect(light.textSecondary == oklch(0.5, 0.01, 265.0))
        #expect(light.separator == oklcha(0.0, 0.0, 0.0, 0.13))
        #expect(light.controlTrack == oklcha(0.2, 0.01, 265.0, 0.13))
        #expect(light.controlOff == oklcha(0.2, 0.01, 265.0, 0.24))
        #expect(light.indicator == oklch(1.0, 0.0, 0.0))
        #expect(light.knob == oklch(1.0, 0.0, 0.0))
        #expect(light.hover == oklcha(0.2, 0.01, 265.0, 0.07))
        #expect(light.press == oklcha(0.2, 0.01, 265.0, 0.12))
        #expect(light.shadow == oklcha(0.2, 0.02, 265.0, 0.16))
        #expect(light.shadowSoft == oklcha(0.2, 0.02, 265.0, 0.07))
        #expect(light.edge == oklcha(0.2, 0.02, 265.0, 0.2))
        #expect(light.knobShadow == oklcha(0.2, 0.02, 265.0, 0.3))

        func approx(_ c1: Color, _ c2: Color, tol: Float = 1e-5) -> Bool {
            abs(c1.r - c2.r) <= tol
                && abs(c1.g - c2.g) <= tol
                && abs(c1.b - c2.b) <= tol
                && abs(c1.a - c2.a) <= tol
        }
        #expect(Tok.accentNames == ["blue", "purple", "pink", "orange", "green", "graphite"])
        #expect(approx(Tok.accent(0, dark: true), oklch(0.66, 0.17, 256.0)))
        #expect(approx(Tok.accent(1, dark: true), oklch(0.66, 0.18, 300.0)))
        #expect(approx(Tok.accent(2, dark: true), oklch(0.68, 0.19, 357.0)))
        #expect(approx(Tok.accent(3, dark: true), oklch(0.74, 0.16, 58.0)))
        #expect(approx(Tok.accent(4, dark: true), oklch(0.70, 0.16, 152.0)))
        #expect(approx(Tok.accent(5, dark: true), oklch(0.64, 0.012, 265.0)))
        #expect(approx(Tok.accent(5, dark: false), oklch(0.58, 0.012, 265.0)))
        #expect(Tok.accent(-1, dark: true) == Tok.accent(5, dark: true))

        #expect(Tok.Motion.LEAD == Spring(duration: 0.2, bounce: 0.0))
        #expect(Tok.Space.S1 == 4 && Tok.Space.S2 == 8 && Tok.Space.S3 == 12 && Tok.Space.S6 == 24)
        #expect(Tok.Radius.SM == 6 && Tok.Radius.MD == 8 && Tok.Radius.LG == 12)
        #expect(Tok.Typography.monoCaption == TextStyle(size: 12.0, weight: 500.0))
    }

    @Test("Theme palette + light/dark + numbers + rgba() + $ref schema")
    func themeJsonSchemaParity() throws {
        let json = """
        {
          "name": "LabTheme",
          "blend": { "mode": "srgb", "over": "bg-base" },
          "palette": {
            "grey-1100": "#161616",
            "tint": "rgba(255, 255, 255, 0.1)",
            "accent-hex": "#3b82f6"
          },
          "dark": {
            "bg-base": "grey-1100",
            "border": "tint",
            "accent": "$accent-hex",
            "alias": "accent"
          },
          "light": {
            "bg-base": "#f8f8f8",
            "border": "rgba(0, 0, 0, 0.12)",
            "accent": "accent-hex"
          },
          "numbers": {
            "radius-panel": 10,
            "container-session": 744
          }
        }
        """
        let dark = try Theme.fromJSON(json, dark: true)
        #expect(dark.name == "LabTheme")
        #expect(dark.color("bg-base") == Color.hex("#161616"))
        #expect(dark.color("accent") == Color.hex("#3b82f6"))
        #expect(dark.color("alias") == Color.hex("#3b82f6"))
        #expect(dark.num("radius-panel") == 10.0)
        #expect(dark.num("container-session") == 744.0)
        #expect(abs(dark.color("border").a - 0.1) < 1e-5)

        let light = try Theme.fromJSON(json, dark: false)
        #expect(light.color("bg-base") == Color.hex("#f8f8f8"))
        #expect(abs(light.color("border").a - 0.12) < 1e-5)
    }

    @Test("Outside a runtime, Theme.blendsSrgb defaults true and tokens resolve as authored (`theme_blend.rs`)")
    func outsideRuntimeTokensResolveAsAuthored() throws {
        let t = try Theme.fromJSON(Self.blendThemeJSON, dark: true)
        #expect(Theme.blendsSrgb() == true)
        #expect(abs(t.color("border").a - Float(0x1a) / 255.0) < 1e-6)
        let linear = Theme.withBlend(false) { t.color("border") }
        #expect(linear.a < t.color("border").a)
        #expect(Theme.blendsSrgb() == true)
    }

    @Test("Translucent theme token composites to browser pixel in both blend modes (`theme_blend.rs`)")
    func translucentTokenCompositesToBrowserPixel() throws {
        func browser(_ fg: UInt8, _ bg: UInt8, _ a: UInt8) -> Float {
            let alpha = Float(a) / 255.0
            return alpha * Float(fg) + (1.0 - alpha) * Float(bg)
        }

        func makeRuntime(dark: Bool, srgb: Bool, cache: MemoCache) throws -> Runtime<Theme> {
            let theme = try Theme.fromJSON(Self.blendThemeJSON, dark: dark)
            let rt = Runtime<Theme>(
                state: theme,
                viewport: Vec2(40, 40),
                pixelScale: 1.0,
                systemDark: dark
            ) { t, _ in
                el().size(40, 40).bg(t.color("bg"))
                    .child(el().size(20, 20).bg(t.color("border")))
                    .child(memo("row-\(dark)", deps: 0, cache: cache) {
                        el().size(10, 10).bg(t.color("border"))
                    })
            }
            rt.setSrgbBlend(srgb)
            _ = rt.frame(at: 0.0)
            return rt
        }

        func composited(scene: RefScene, side: Float) -> [Float] {
            func findPremulFill(width: Float) -> SIMD4<Float> {
                for p in scene.primitives {
                    if p.kind == .roundedRect,
                       abs(p.rect.z - width) < 0.01,
                       p.fill.w > 0 {
                        // RefPrimitive.fill stores straight alpha; convert to premul for Color.over.
                        let a = p.fill.w
                        return SIMD4<Float>(p.fill.x * a, p.fill.y * a, p.fill.z * a, a)
                    }
                }
                fatalError("missing \(width)-point box")
            }
            let px = Color.over(findPremulFill(width: side), findPremulFill(width: 40.0))
            let encode: (Float) -> Float = { v in
                scene.srgbBlend ? v : RefShader.linearToSRGB(v)
            }
            return [encode(px.x) * 255.0, encode(px.y) * 255.0, encode(px.z) * 255.0]
        }

        for (dark, want) in [(true, browser(0xff, 0x16, 0x1a)), (false, browser(0x00, 0xf8, 0x1f))] {
            for srgb in [true, false] {
                let rt = try makeRuntime(dark: dark, srgb: srgb, cache: MemoCache())
                let scene = rt.frame(at: 0.0)
                for side: Float in [20, 10] {
                    let got = composited(scene: scene, side: side)
                    #expect(got.allSatisfy { abs($0 - want) < 0.5 })
                }
            }
        }

        // Live switch re-evaluates memoized rows too
        let cache = MemoCache()
        let theme = try Theme.fromJSON(Self.blendThemeJSON, dark: true)
        let rt = Runtime<Theme>(state: theme, viewport: Vec2(40, 40), pixelScale: 1.0, systemDark: true) { t, _ in
            el().size(40, 40).bg(t.color("bg"))
                .child(el().size(20, 20).bg(t.color("border")))
                .child(memo("live-row", deps: 0, cache: cache) {
                    el().size(10, 10).bg(t.color("border"))
                })
        }
        rt.setSrgbBlend(false)
        _ = rt.frame(at: 0.0)
        let want = browser(0xff, 0x16, 0x1a)
        for srgb in [true, false] {
            rt.update { _, tx in tx.setSrgbBlend(srgb) }
            _ = rt.frame(at: 1.0 / 60.0)
            let scene = rt.frame(at: 1.0)
            for side: Float in [20, 10] {
                let got = composited(scene: scene, side: side)
                #expect(got.allSatisfy { abs($0 - want) < 0.5 })
            }
        }
    }

    @Test func srgbEquivalentChromaticAndThemePaletteErrorAlphaParity() throws {
        // Chromatic translucent color keeps linear RGB unchanged and fits luminance-weighted alpha.
        let fg = Color.hex("#40c08040")!
        let bg = Color.hex("#182030")!
        let eq = fg.srgbEquivalent(over: bg)
        #expect(eq.r == fg.r && eq.g == fg.g && eq.b == fg.b)
        #expect(eq.a >= 0.0 && eq.a <= 1.0 && eq.a != fg.a)
        let opaque = Color.hex("#40c080ff")!
        #expect(opaque.srgbEquivalent(over: bg) == opaque)

        // Theme keeps dark flag, exposes unused palette hex colors, provides alpha(_:_:), and throws on invalid colors.
        let json = """
        {
          "name": "test",
          "palette": { "unused-ink": "#336699", "bg": "#161616", "fg": "#ffffff" },
          "blend": { "mode": "srgb", "over": "bg" },
          "dark": { "bg": "bg", "fg": "fg" },
          "light": { "bg": "fg", "fg": "bg" }
        }
        """
        let darkTheme = try Theme.fromJSON(json, dark: true)
        #expect(darkTheme.dark == true)
        #expect(darkTheme.tryColor("unused-ink") == Color.hex("#336699"))
        let lightTheme = try Theme.fromJSON(json, dark: false)
        #expect(lightTheme.dark == false)

        let alphaLinear = Theme.withBlend(false) { darkTheme.alpha(Color.hex("#ffffff")!, 0.1) }
        let alphaSRGB = Theme.withBlend(true) { darkTheme.alpha(Color.hex("#ffffff")!, 0.1) }
        #expect(abs(alphaSRGB.a - 0.1) < 1e-4)
        #expect(alphaLinear.a < alphaSRGB.a)

        let badJSON = """
        {
          "dark": { "bad-token": "not-a-color-or-palette-key" }
        }
        """
        do {
            _ = try Theme.fromJSON(badJSON, dark: true)
            Issue.record("Expected ThemeError.invalidColor for unknown color reference")
        } catch let err as ThemeError {
            #expect(err == .invalidColor(token: "bad-token", value: "not-a-color-or-palette-key"))
        }
    }

    @Test("Theme.fromJSON throws missingMode instead of falling back to opposite mode")
    func missingModeThrowsThemeError() throws {
        let lightOnlyJSON = """
        {
          "name": "light-only",
          "light": { "bg": "#ffffff" }
        }
        """
        do {
            _ = try Theme.fromJSON(lightOnlyJSON, dark: true)
            Issue.record("Expected ThemeError.missingMode(dark)")
        } catch let err as ThemeError {
            #expect(err == .missingMode("dark"))
        }

        let darkOnlyJSON = """
        {
          "name": "dark-only",
          "dark": { "bg": "#111111" }
        }
        """
        do {
            _ = try Theme.fromJSON(darkOnlyJSON, dark: false)
            Issue.record("Expected ThemeError.missingMode(light)")
        } catch let err as ThemeError {
            #expect(err == .missingMode("light"))
        }
    }

    @Test func colorMixOklabMatchesEndpointsAndPerceptualMidpoint() {
        let red = Color(r: 1, g: 0, b: 0, a: 1)
        let blue = Color(r: 0, g: 0, b: 1, a: 0.2)

        let atZero = red.mixOklab(with: blue, t: 0)
        let atUnder = red.mixOklab(with: blue, t: -0.5)
        #expect(abs(atZero.r - red.r) < 1e-5)
        #expect(abs(atZero.g - red.g) < 1e-5)
        #expect(abs(atZero.b - red.b) < 1e-5)
        #expect(abs(atZero.a - red.a) < 1e-5)
        #expect(abs(atUnder.r - red.r) < 1e-5)
        #expect(abs(atUnder.a - red.a) < 1e-5)

        let atOne = red.mixOklab(with: blue, t: 1)
        let atOver = red.mixOklab(with: blue, t: 1.5)
        #expect(abs(atOne.r - blue.r) < 1e-5)
        #expect(abs(atOne.g - blue.g) < 1e-5)
        #expect(abs(atOne.b - blue.b) < 1e-5)
        #expect(abs(atOne.a - blue.a) < 1e-5)
        #expect(abs(atOver.b - blue.b) < 1e-5)
        #expect(abs(atOver.a - blue.a) < 1e-5)

        // OKLab midpoint between pure red and translucent blue respects premultiplied OKLab alpha weighting
        // (`mid.a == 0.6`), while equal-alpha red <-> blue mixes through perceptual purple without a muddy shift.
        let mid = red.mixOklab(with: blue, t: 0.5)
        let linearMid = red.mix(with: blue, t: 0.5)
        #expect(abs(mid.a - 0.6) < 1e-5)
        #expect(mid.r > 0.25)
        #expect(mid.g < 0.05)
        #expect(mid != linearMid)

        let opaqueBlue = Color(r: 0, g: 0, b: 1, a: 1)
        let opaqueMid = red.mixOklab(with: opaqueBlue, t: 0.5)
        let opaqueLinearMid = red.mix(with: opaqueBlue, t: 0.5)
        #expect(abs(opaqueMid.a - 1.0) < 1e-5)
        #expect(opaqueMid.r > 0.25 && opaqueMid.b > 0.15)
        #expect(opaqueMid.g < 0.12)
        #expect(opaqueMid != opaqueLinearMid)
    }
}
