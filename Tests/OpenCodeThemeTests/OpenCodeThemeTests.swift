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
            let authored = OpenCodeTheme.rawTheme(dark: dark)["v2-overlay-simple-overlay-hover"]
            #expect(authored != nil)
            #expect(srgb.c.hover == authored)
            if let authored {
                #expect(linear.c.hover == authored.srgbEquivalent(over: linear.c.bgBase))
                #expect(linear.c.hover.a != authored.a)
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
}
