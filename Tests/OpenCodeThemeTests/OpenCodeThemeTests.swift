import Foundation
import Testing
import Rune
import RuneKit
@testable import OpenCodeTheme

@Suite("OpenCodeTheme Tests")
struct OpenCodeThemeTests {
    @Test func bothAppearancesResolveAndBrandIsWarmEmber() {
        for dark in [false, true] {
            let k = OpenCodeTheme.kit(dark: dark)
            #expect(k.dark == dark)
            #expect(!k.elevation.buttonNeutral.isEmpty)
            #expect(!k.elevation.floating.isEmpty)
            #expect(!k.elevation.raised.isEmpty)

            let brand = OpenCodeTheme.brand(dark: dark)
            #expect(brand.a > 0.99)
            #expect(brand.r > brand.g)
            #expect(brand.r > brand.b)
        }
    }

    @Test func darkBorderFocusIsBlue400AndLightStaysBlue500() {
        let darkKit = OpenCodeTheme.kit(dark: true)
        let lightKit = OpenCodeTheme.kit(dark: false)
        let blue400 = OpenCodeTheme.authored("v2-blue-400", dark: true)
        let blue500 = OpenCodeTheme.authored("v2-blue-500", dark: false)

        #expect(blue400 != nil)
        #expect(blue500 != nil)
        #expect(darkKit.c.borderFocus == blue400)
        #expect(OpenCodeTheme.authored("v2-border-border-focus", dark: true) == blue400)
        #expect(OpenCodeTheme.authored("color-v2-border-border-focus", dark: true) == blue400)
        #expect(OpenCodeThemeData.darkColors["v2-border-border-focus"] == "#a2bcffff")
        #expect(OpenCodeThemeData.darkColors["color-v2-border-border-focus"] == "#a2bcffff")

        #expect(lightKit.c.borderFocus == blue500)
        #expect(OpenCodeTheme.authored("v2-border-border-focus", dark: false) == blue500)
        #expect(OpenCodeTheme.authored("color-v2-border-border-focus", dark: false) == blue500)
        #expect(OpenCodeThemeData.lightColors["v2-border-border-focus"] == "#7698fdff")
        #expect(OpenCodeThemeData.lightColors["color-v2-border-border-focus"] == "#7698fdff")
    }

    @Test func scalesAndEmberStepsMatchTokens() {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            for step in 1...12 {
                let emberColor = OpenCodeTheme.ember(dark: dark, step: step)
                let tokenColor = OpenCodeTheme.color("ember-\(mode)-\(step)", dark: dark)
                #expect(emberColor == tokenColor)
            }
            #expect(OpenCodeTheme.brand(dark: dark) == OpenCodeTheme.ember(dark: dark, step: 9))
            #expect(
                OpenCodeTheme.scale(.blue, dark: dark, step: 5)
                == OpenCodeTheme.color("blue-\(mode)-5", dark: dark)
            )
            #expect(
                OpenCodeTheme.scale(.cobalt, dark: dark, step: 9)
                == OpenCodeTheme.color("cobalt-\(mode)-9", dark: dark)
            )
        }
    }

    @Test func translucentTokensFollowBlendMode() {
        for dark in [false, true] {
            let srgb = OpenCodeTheme.kit(dark: dark, srgbBlend: true)
            let linear = OpenCodeTheme.kit(dark: dark, srgbBlend: false)
            let authored = OpenCodeTheme.authored("v2-overlay-simple-overlay-hover", dark: dark)
            #expect(authored != nil)
            #expect(srgb.c.hover == authored)
            if let authored {
                #expect(linear.c.hover == authored.srgbEquivalent(over: linear.c.bgBase))
                #expect(linear.c.hover.a != authored.a)
            }
            if !dark {
                let alphas = srgb.elevation.floating.prefix(3).map { UInt8(($0.color.a * 255.0).rounded()) }
                #expect(alphas == [0x0A, 0x14, 0x1F])
            }
        }
    }

    @Test func syntaxTypographySpacingAndShadowsResolve() {
        let darkSyntax = OpenCodeTheme.syntax(dark: true)
        let lightSyntax = OpenCodeTheme.syntax(dark: false)
        #expect(darkSyntax.keyword.a > 0.9)
        #expect(darkSyntax.string != darkSyntax.keyword)
        #expect(lightSyntax.keyword != darkSyntax.keyword)

        #expect(OpenCodeTheme.families.sans == "Inter")
        #expect(OpenCodeTheme.families.mono == "IBM Plex Mono")
        #expect(OpenCodeTheme.spacing(1) == 4.0)
        #expect(OpenCodeTheme.spacing(3) == 12.0)
        #expect(OpenCodeTheme.spacingTokens.radiusMD == 6.0)
        #expect(OpenCodeTheme.number("container-session") == 744.0)

        let shadows = OpenCodeTheme.shadows("v2-elevation-floating", dark: false, srgbBlend: true)
        #expect(shadows.count >= 3)
        let parsedInset = OpenCodeTheme.parseBoxShadows("inset 0px 1px 2px 0px #00000033")
        #expect(parsedInset.count == 1)
        #expect(parsedInset[0].inset == true)
        #expect(parsedInset[0].y == 1.0)
        #expect(parsedInset[0].blur == 2.0)
    }

    @Test func styledElHelpersBuildValidElements() {
        struct Dummy {}
        let card: El<Dummy> = OpenCodeTheme.card(dark: true, elevated: true)
        let surface: El<Dummy> = OpenCodeTheme.surface(dark: false, level: 2)
        let badge: El<Dummy> = OpenCodeTheme.badge("Beta", dark: true, tone: .accent)
        let div: El<Dummy> = OpenCodeTheme.divider(dark: true)
        let mark: El<Dummy> = OpenCodeTheme.brandMark(dark: true, size: 24)

        #expect(card.shadows.count > 0)
        #expect(surface.background.a > 0)
        #expect(badge.children.count == 1)
        #expect(div.role == .separator)
        #expect(mark.background == OpenCodeTheme.brand(dark: true))
    }

    @Test func bundledThemeJSONFontsAndKitGlyphsMatchUpstream() throws {
        let jsonData = try #require(OpenCodeTheme.themeJSON.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        #expect(parsed?["light"] != nil)
        #expect(parsed?["dark"] != nil)
        #expect(parsed?["numbers"] != nil)

        #expect(OpenCodeTheme.fonts.count == 3)
        #expect(OpenCodeTheme.fonts.map(\.count) == [874_708, 155_940, 156_996])
        for font in OpenCodeTheme.fonts {
            #expect(font.prefix(4) == Data([0x00, 0x01, 0x00, 0x00]))
        }

        for dark in [false, true] {
            let k = OpenCodeTheme.kit(dark: dark)
            #expect(k.glyph == OpenCodeTheme.glyphs)
            #expect(k.glyph.copy == OpenCodeIcons.copy)
            #expect(k.glyph.search == OpenCodeIcons.magnifyingGlass)
            #expect(k.glyph.circleX == OpenCodeIcons.circleX)
            #expect(k.glyph.triangleDown == OpenCodeIcons.fillTriangleDown)
            #expect(k.glyph.clear == OpenCodeIcons.xmarkSmall)
            #expect(k.glyph.close == OpenCodeIcons.close)
        }
    }

    @Test func emberAndScaleRejectInvalidInputs() async {
        await #expect(processExitsWith: .failure) {
            _ = OpenCodeTheme.ember(dark: true, step: 0)
        }
        await #expect(processExitsWith: .failure) {
            _ = OpenCodeTheme.ember(dark: false, step: 13)
        }
        await #expect(processExitsWith: .failure) {
            _ = OpenCodeTheme.scale("unknown", dark: true, step: 5)
        }
    }

    @Test func ambientThemeAndKitFollowThemeWithBlend() throws {
        for dark in [false, true] {
            let defaultKit = OpenCodeTheme.kit(dark: dark)
            let srgbExplicit = OpenCodeTheme.kit(dark: dark, srgbBlend: true)
            #expect(defaultKit == srgbExplicit)
            if Theme.blendsSrgb(), let authored = OpenCodeTheme.authored("v2-overlay-simple-overlay-hover", dark: dark) {
                #expect(defaultKit.c.hover == authored)
            }
            #expect(OpenCodeTheme.theme(dark: dark) == (try Theme.fromJSON(OpenCodeTheme.themeJSON, dark: dark)))
        }
        Theme.withBlend(true) {
            for dark in [false, true] {
                let k = OpenCodeTheme.kit(dark: dark)
                let authored = OpenCodeTheme.authored("v2-overlay-simple-overlay-hover", dark: dark)
                #expect(k.c.hover == authored)
                #expect(OpenCodeTheme.color("v2-overlay-simple-overlay-hover", dark: dark) == authored)
                let sh = OpenCodeTheme.shadows("v2-elevation-floating", dark: dark)
                #expect(sh == OpenCodeTheme.shadows("v2-elevation-floating", dark: dark, srgbBlend: true))
            }
        }
        Theme.withBlend(false) {
            for dark in [false, true] {
                let k = OpenCodeTheme.kit(dark: dark)
                let authored = OpenCodeTheme.authored("v2-overlay-simple-overlay-hover", dark: dark)
                #expect(OpenCodeTheme.theme(dark: dark).authored("v2-overlay-simple-overlay-hover") == authored)
                #expect(OpenCodeTheme.theme(dark: dark, srgbBlend: false).authored("v2-overlay-simple-overlay-hover") == authored)
                if let authored {
                    #expect(k.c.hover == authored.srgbEquivalent(over: k.c.bgBase))
                    #expect(OpenCodeTheme.color("v2-overlay-simple-overlay-hover", dark: dark) == authored.srgbEquivalent(over: k.c.bgBase))
                    #expect(OpenCodeTheme.theme(dark: dark).tryColor("v2-overlay-simple-overlay-hover") == authored.srgbEquivalent(over: k.c.bgBase))
                }
                let sh = OpenCodeTheme.shadows("v2-elevation-floating", dark: dark)
                #expect(sh == OpenCodeTheme.shadows("v2-elevation-floating", dark: dark, srgbBlend: false))
            }
        }
    }
}
