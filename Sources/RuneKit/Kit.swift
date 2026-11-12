import Foundation
import Rune
import RuneMotion

/// Semantic status color bundle (`rune_kit::StateColors`).
public struct StateColors: Sendable, Equatable {
    public var bg: Color
    public var fg: Color
    public var border: Color
    public var icon: Color

    public init(bg: Color, fg: Color, border: Color, icon: Color) {
        self.bg = bg
        self.fg = fg
        self.border = border
        self.icon = icon
    }
}

/// Complete semantic color palette (`rune_kit::Palette`).
public struct Palette: Sendable, Equatable {
    public var page: Color
    public var bgBase: Color
    public var bgDeep: Color
    public var layer01: Color
    public var layer02: Color
    public var layer03: Color
    public var layer04: Color
    public var bgInverse: Color
    public var bgContrast: Color
    public var bgButtonNeutral: Color
    public var bgIconButtonContrast: Color
    public var bgAccent: Color
    public var submitHighlight: Color
    public var submitHover: Color
    public var submitFg: Color
    public var submitIcon: Color

    public var textBase: Color
    public var textMuted: Color
    public var textFaint: Color
    public var textInverse: Color
    public var textContrast: Color
    public var textAccent: Color

    public var iconBase: Color
    public var iconMuted: Color
    public var iconFaint: Color
    public var iconInverse: Color
    public var iconContrast: Color
    public var iconAccent: Color

    public var borderMuted: Color
    public var borderBase: Color
    public var borderStrong: Color
    public var borderFocus: Color

    public var hover: Color
    public var pressed: Color
    public var contrastHover: Color
    public var contrastPressed: Color
    public var scrim: Color
    public var depthTop: Color = .white
    public var depthBottom: Color = Color.white.alpha(0.0)
    public var white: Color = .white
    public var black: Color = .black
    public var knob: Color
    public var knobOn: Color

    public var success: StateColors
    public var warning: StateColors
    public var danger: StateColors
    public var info: StateColors

    public var surfaceBase: Color
    public var surfaceWeak: Color
    public var surfaceHover: Color
    public var surfaceRaised: Color
    public var surfaceRaisedBase: Color = .transparent
    public var surfaceRaisedHover: Color = .transparent
    public var surfaceFloat: Color
    public var surfaceDisabled: Color
    public var borderWeak: Color = .transparent
    public var borderHover: Color = .transparent
    public var borderActive: Color = .transparent
    public var borderDisabled: Color = .transparent
    public var textStrong: Color = .transparent
    public var textWeak: Color = .transparent
    public var textInvertStrong: Color = .transparent
    public var iconWeaker: Color = .transparent
    public var stdBorder: Color
    public var stdIcon: Color = .transparent
    public var stdIconInvert: Color = .transparent
    public var stdIconStrong: Color = .transparent
    public var stdText: Color = .transparent
}

/// Three-color seed `(bg, fg, accent)` from which `Kit.fromPalette` derives all 50+ semantic tokens.
public struct PaletteSeed: Sendable, Equatable {
    public var bg: Color
    public var fg: Color
    public var accent: Color

    public init(bg: Color, fg: Color, accent: Color) {
        self.bg = bg
        self.fg = fg
        self.accent = accent
    }
}

public enum PaletteFocus: Sendable, Equatable {
    case blue
    case accent
    case ink
    case custom(Color)
}

public struct KitElevation: Sendable, Equatable {
    public var raised: [Shadow]
    public var floating: [Shadow]
    public var overlay: [Shadow]
    public var buttonNeutral: [Shadow]
    public var buttonContrast: [Shadow]
    public var elements: [Shadow] = []
    public var switchOff: [Shadow] = []
    public var switchOn: [Shadow] = []
    public var md: [Shadow] = []
    public var knob: [Shadow]
    public var input: [Shadow] = []
}

public struct KitTypography: Sendable, Equatable {
    public var ui: TextStyle
    public var uiMedium: TextStyle
    public var uiCompact: TextStyle
    public var small: TextStyle
    public var smallMedium: TextStyle
    public var body: TextStyle
    public var bodyMedium: TextStyle
    public var textSmall: TextStyle = TextStyle(size: 13.0, weight: 400.0).lh(19.5)
    public var textSmallMedium: TextStyle = TextStyle(size: 13.0, weight: 500.0).lh(19.5)
    public var textXsmall: TextStyle = TextStyle(size: 12.0, weight: 400.0).lh(18.0)
    public var textXsmallMedium: TextStyle = TextStyle(size: 12.0, weight: 500.0).lh(18.0)
    public var mono: TextStyle

    /// Secondary text under a control or row (`small` on a 16pt line).
    public func caption() -> TextStyle {
        small.lh(16.0)
    }
}

public struct KitRadius: Sendable, Equatable {
    public var xs: Float
    public var sm: Float
    public var md: Float
    public var lg: Float
    public var xl: Float
}

public struct KitMotion: Sendable, Equatable {
    public var control: Spring
    public var overlay: Spring
    public var disclosure: Spring
}

/// Curated crisp vector SVG icon catalog (`rune_kit::glyphs`).
public enum KitIcons {
    public static let check = SVGIcon(viewBox: 16, paths: ["M3.5 8.5L6.5 11.5L12.5 4.5"], strokeWidth: 2.0)
    public static let checkSmall = SVGIcon(viewBox: 16, paths: ["M3.54 8.18L6.39 11.75L12.46 4.25"], strokeWidth: 1.4)
    public static let minus = SVGIcon(viewBox: 16, paths: ["M3.5 8H12.5"], strokeWidth: 2.0)
    public static let plus = SVGIcon(viewBox: 16, paths: ["M8 3.5V12.5", "M3.5 8H12.5"], strokeWidth: 1.8)
    public static let close = SVGIcon(viewBox: 16, paths: ["M4 4L12 12", "M12 4L4 12"], strokeWidth: 1.8)
    public static let chevronRight = SVGIcon(viewBox: 16, paths: ["M6 3.5L10.5 8L6 12.5"], strokeWidth: 1.8)
    public static let chevronDown = SVGIcon(viewBox: 16, paths: ["M3.5 6L8 10.5L12.5 6"], strokeWidth: 1.8)
    public static let chevronUp = SVGIcon(viewBox: 16, paths: ["M12.5 10L8 5.5L3.5 10"], strokeWidth: 1.8)
    public static let caretRight = SVGIcon(viewBox: 16, paths: ["M6 4L10 8L6 12Z"], strokeWidth: 1.5)
    public static let triangleDown = SVGIcon(viewBox: 16, paths: ["M4 6H12L8 10.5Z"], strokeWidth: 1.5)
    public static let triangleRight = SVGIcon(viewBox: 16, paths: ["M6 4L10.5 8L6 12Z"], strokeWidth: 1.5)
    public static let copy = SVGIcon(viewBox: 16, paths: ["M4.5 4.5V2.5H13.5V11.5H11.5", "M2.5 4.5H11.5V13.5H2.5Z"], strokeWidth: 1.5)
    public static let search = SVGIcon(viewBox: 16, paths: ["M7 3A4 4 0 1 1 6.99 3", "M10.2 10.2L13.2 13.2"], strokeWidth: 1.7)
    public static let circleX = SVGIcon(viewBox: 16, paths: ["M6 6L10 10", "M10 6L6 10", "M8 1.5A6.5 6.5 0 1 1 7.99 1.5"], strokeWidth: 1.5)
    public static let lock = SVGIcon(viewBox: 16, paths: ["M3.5 7H12.5V14H3.5Z", "M5.5 7V4.5A2.5 2.5 0 0 1 10.5 4.5V7"], strokeWidth: 1.5)
    public static let eye = SVGIcon(viewBox: 16, paths: ["M1.5 8C3.5 4.5 12.5 4.5 14.5 8C12.5 11.5 3.5 11.5 1.5 8Z", "M8 6A2 2 0 1 1 7.99 6"], strokeWidth: 1.5)
    public static let eyeOff = SVGIcon(viewBox: 16, paths: ["M2 2L14 14", "M3 5.5C5 3.5 11 3.5 13 5.5", "M3 10.5C5 12.5 11 12.5 13 10.5"], strokeWidth: 1.5)
    public static let dash = SVGIcon(viewBox: 16, paths: ["M4 8H12"], strokeWidth: 1.5)
    public static let arrowRight = SVGIcon(viewBox: 16, paths: ["M2.5 8H13.5", "M9 3.5L13.5 8L9 12.5"], strokeWidth: 1.6)
    public static let folder = SVGIcon(viewBox: 16, paths: ["M2 4.5H6L7.5 6H14V12.5H2Z"], strokeWidth: 1.5)
    public static let file = SVGIcon(viewBox: 16, paths: ["M4 2.5H10L12.5 5V13.5H4Z"], strokeWidth: 1.5)
    public static let info = SVGIcon(viewBox: 16, paths: ["M8 7.5V11.5", "M8 4.8V5.1"], strokeWidth: 2.0)
}

/// Themable component kit (`rune_kit::Kit`).
public struct Kit: Sendable, Equatable {
    public var dark: Bool
    public var c: Palette
    public var elevation: KitElevation
    public var ty: KitTypography
    public var radius: KitRadius
    public var motion: KitMotion
    public var blendOver: Color?
    public var usePaletteRing: Bool = false
    public var invalidText: Bool = false

    private static let darkLayers: [Float] = [0.04, 0.07, 0.10, 0.13]
    private static let lightLayers: [Float] = [0.02, 0.045, 0.065, 0.10]
    private static let darkFloor: Float = 0.145

    /// Constructs the brand-free neutral theme (`Kit::neutral(dark)`).
    public static func neutral(dark: Bool) -> Kit {
        let t = Tok.theme(dark: dark)
        let accent = Tok.accent(0, dark: dark)

        func makeState(_ hue: Float) -> StateColors {
            StateColors(
                bg: oklcha(dark ? 0.30 : 0.95, 0.04, hue, 1.0),
                fg: oklch(dark ? 0.75 : 0.50, 0.15, hue),
                border: oklch(dark ? 0.40 : 0.85, 0.08, hue),
                icon: oklch(dark ? 0.75 : 0.50, 0.15, hue)
            )
        }

        func ring(_ c: Color) -> Shadow {
            Shadow(x: 0, y: 0, blur: 0, spread: 0.5, color: c)
        }

        func drop(_ y: Float, _ blur: Float, _ c: Color) -> Shadow {
            Shadow(x: 0, y: y, blur: blur, spread: 0, color: c)
        }

        let palette = Palette(
            page: t.bg,
            bgBase: t.card,
            bgDeep: t.bg,
            layer01: t.bg,
            layer02: t.controlTrack,
            layer03: t.controlOff,
            layer04: t.indicator,
            bgInverse: t.text,
            bgContrast: t.text,
            bgButtonNeutral: t.card,
            bgIconButtonContrast: t.text,
            bgAccent: accent,
            submitHighlight: Color.white.alpha(0.20),
            submitHover: Color.white.alpha(0.12),
            submitFg: Color.white,
            submitIcon: Color.white,
            textBase: t.text,
            textMuted: t.textSecondary,
            textFaint: t.textSecondary.alpha(0.78),
            textInverse: t.card,
            textContrast: t.card,
            textAccent: accent,
            iconBase: t.text,
            iconMuted: t.textSecondary,
            iconFaint: t.textSecondary.alpha(0.70),
            iconInverse: t.card,
            iconContrast: t.card,
            iconAccent: accent,
            borderMuted: t.separator,
            borderBase: t.cardBorder,
            borderStrong: t.separator,
            borderFocus: accent,
            hover: t.hover,
            pressed: t.press,
            contrastHover: Color.white.alpha(0.10),
            contrastPressed: Color.white.alpha(0.20),
            scrim: Color.black.alpha(0.32),
            knob: t.knob,
            knobOn: t.knob,
            success: makeState(150),
            warning: makeState(80),
            danger: makeState(25),
            info: makeState(256),
            surfaceBase: t.controlTrack,
            surfaceWeak: t.controlTrack,
            surfaceHover: t.hover,
            surfaceRaised: t.card,
            surfaceFloat: t.text,
            surfaceDisabled: t.controlTrack,
            stdBorder: t.cardBorder
        )

        let ui = TextStyle(size: 13.0, weight: 400.0).lh(20.0)
        return Kit(
            dark: dark,
            c: palette,
            elevation: KitElevation(
                raised: [drop(1.0, 2.0, t.shadow), ring(t.cardBorder)],
                floating: [drop(4.0, 8.0, t.shadow), ring(t.cardBorder)],
                overlay: [drop(8.0, 16.0, t.shadow), ring(t.cardBorder)],
                buttonNeutral: [drop(1.0, 1.5, t.shadow), ring(t.cardBorder)],
                buttonContrast: [drop(1.0, 1.5, t.shadow)],
                knob: [drop(1.0, 3.0, t.knobShadow)]
            ),
            ty: KitTypography(
                ui: ui,
                uiMedium: ui.medium(),
                uiCompact: ui.lh(16.0),
                small: TextStyle(size: 11.0, weight: 400.0).lh(14.0),
                smallMedium: TextStyle(size: 11.0, weight: 500.0).lh(14.0),
                body: TextStyle(size: 14.0, weight: 400.0).lh(21.0),
                bodyMedium: TextStyle(size: 14.0, weight: 500.0).lh(21.0),
                mono: TextStyle(size: 12.0, weight: 400.0).mono().lh(18.0)
            ),
            radius: KitRadius(xs: 2.0, sm: 4.0, md: 6.0, lg: 8.0, xl: 10.0),
            motion: KitMotion(
                control: Tok.Motion.SNAPPY,
                overlay: Tok.Motion.SNAPPY,
                disclosure: Tok.Motion.DEFAULT
            ),
            blendOver: nil
        )
    }

    /// Derives a complete accessible semantic `Kit` from three colors `(bg, fg, accent)`,
    /// matching `rune_kit::Kit::from_palette`!
    public static func fromPalette(_ seed: PaletteSeed, focus: PaletteFocus = .blue) -> Kit {
        let bg = seed.bg
        let fg = seed.fg
        let accent = seed.accent
        let dark = fg.luminance > bg.luminance
        var kit = Kit.neutral(dark: dark)

        let labBg = bg.toOKLab()
        let labFg = fg.toOKLab()
        let chromaBg = hypotf(labBg[1], labBg[2])
        let chromaFg = hypotf(labFg[1], labFg[2])
        let tintA = chromaBg >= chromaFg ? labBg[1] : labFg[1]
        let tintB = chromaBg >= chromaFg ? labBg[2] : labFg[2]

        func tone(_ l: Float) -> Color {
            Color.fromOKLab([min(max(l, 0), 1), tintA, tintB, 1.0])
        }

        let baseL = dark ? max(labBg[0], darkFloor) : labBg[0]
        let towardFg: Float = dark ? 1.0 : -1.0
        func lift(_ dl: Float) -> Color {
            tone(baseL + towardFg * dl)
        }

        let steps = dark ? darkLayers : lightLayers
        let l1 = lift(steps[0])
        let l2 = lift(steps[1])
        let l3 = lift(steps[2])
        let l4 = lift(steps[3])
        let surface = lift(0)

        func ink(_ a: Float) -> Color {
            Tok.forBlend(fg.alpha(a), over: bg)
        }

        func secondary(amount: Float, minContrast: Float) -> Color {
            let lb = labBg[0]
            let lf = labFg[0]
            func mixL(_ t: Float) -> Color {
                Color.fromOKLab([lb + (lf - lb) * t, tintA, tintB, 1.0])
            }
            let cand = mixL(amount)
            if bg.contrastRatio(with: cand) >= minContrast {
                return cand
            }
            if bg.contrastRatio(with: fg) < minContrast {
                return fg
            }
            var low = amount
            var high: Float = 1.0
            for _ in 0..<24 {
                let mid = (low + high) * 0.5
                if bg.contrastRatio(with: mixL(mid)) >= minContrast {
                    high = mid
                } else {
                    low = mid
                }
            }
            return mixL(high)
        }

        func mixOKLab(_ a: Color, _ b: Color, _ t: Float) -> Color {
            let la = a.toOKLab()
            let lb = b.toOKLab()
            return Color.fromOKLab([
                la[0] + (lb[0] - la[0]) * t,
                la[1] + (lb[1] - la[1]) * t,
                la[2] + (lb[2] - la[2]) * t,
                la[3] + (lb[3] - la[3]) * t,
            ])
        }

        let muted = secondary(amount: dark ? 0.72 : 0.57, minContrast: 4.5)
        let faint = secondary(amount: dark ? 0.54 : 0.36, minContrast: 3.0)
        let border = ink(dark ? 0.11 : 0.10)
        let solidBorder = lift(dark ? 0.20 : 0.18)
        let hover = ink(dark ? 0.06 : 0.05)
        let pressed = ink(dark ? 0.10 : 0.08)

        let focusColor: Color
        switch focus {
        case .blue:
            focusColor = oklch(dark ? 0.70 : 0.58, 0.15, 264.0)
        case .accent:
            focusColor = accent
        case .ink:
            focusColor = fg
        case .custom(let c):
            focusColor = c
        }

        func adaptState(_ role: StateColors) -> StateColors {
            StateColors(
                bg: mixOKLab(surface, role.fg, 0.12),
                fg: role.fg,
                border: mixOKLab(surface, role.fg, 0.35),
                icon: role.icon
            )
        }

        let submitFg: Color = accent.luminance > 0.42 ? .black : .white

        kit.blendOver = bg
        kit.usePaletteRing = true
        kit.c = Palette(
            page: bg,
            bgBase: bg,
            bgDeep: bg,
            layer01: l1,
            layer02: l2,
            layer03: l3,
            layer04: l4,
            bgInverse: fg,
            bgContrast: fg,
            bgButtonNeutral: l1,
            bgIconButtonContrast: fg,
            bgAccent: accent,
            submitHighlight: Color.white.alpha(0.20),
            submitHover: bg.alpha(0.12),
            submitFg: submitFg,
            submitIcon: submitFg,
            textBase: fg,
            textMuted: muted,
            textFaint: faint,
            textInverse: bg,
            textContrast: bg,
            textAccent: accent,
            iconBase: fg,
            iconMuted: muted,
            iconFaint: faint,
            iconInverse: bg,
            iconContrast: bg,
            iconAccent: accent,
            borderMuted: ink(0.08),
            borderBase: border,
            borderStrong: ink(0.20),
            borderFocus: focusColor,
            hover: hover,
            pressed: pressed,
            contrastHover: bg.alpha(0.10),
            contrastPressed: bg.alpha(0.20),
            scrim: Color.black.alpha(0.30),
            knob: Color.white,
            knobOn: Color.white,
            success: adaptState(kit.c.success),
            warning: adaptState(kit.c.warning),
            danger: adaptState(kit.c.danger),
            info: adaptState(kit.c.info),
            surfaceBase: l2,
            surfaceWeak: l1,
            surfaceHover: hover,
            surfaceRaised: l1,
            surfaceRaisedBase: l1,
            surfaceRaisedHover: l3,
            surfaceFloat: fg,
            surfaceDisabled: l2,
            borderWeak: lift(0.12),
            borderHover: lift(0.26),
            borderActive: lift(0.28),
            borderDisabled: lift(0.10),
            textStrong: fg,
            textWeak: muted,
            textInvertStrong: bg,
            iconWeaker: faint,
            stdBorder: solidBorder,
            stdIcon: muted,
            stdIconInvert: bg,
            stdIconStrong: fg,
            stdText: fg
        )

        let dropColor = Color.black.alpha(dark ? 0.30 : 0.12)
        func adaptShadows(_ shadows: [Shadow]) -> [Shadow] {
            shadows.map { s in
                var copy = s
                copy.color = (s.blur == 0.0) ? border : dropColor
                return copy
            }
        }
        kit.elevation = KitElevation(
            raised: adaptShadows(kit.elevation.raised),
            floating: adaptShadows(kit.elevation.floating),
            overlay: adaptShadows(kit.elevation.overlay),
            buttonNeutral: adaptShadows(kit.elevation.buttonNeutral),
            buttonContrast: adaptShadows(kit.elevation.buttonContrast),
            elements: adaptShadows(kit.elevation.elements),
            switchOff: adaptShadows(kit.elevation.switchOff),
            switchOn: adaptShadows(kit.elevation.switchOn),
            md: adaptShadows(kit.elevation.md),
            knob: adaptShadows(kit.elevation.knob),
            input: adaptShadows(kit.elevation.input)
        )
        return kit
    }

    // MARK: - Color & Elevation Helpers (`rune_kit::Kit`)

    /// `color` at opacity `a`, solved over `blendOver` when present.
    public func alpha(_ color: Color, _ a: Float) -> Color {
        let ca = color.alpha(a)
        guard let bg = blendOver else { return ca }
        return Tok.forBlend(ca, over: bg)
    }

    /// The text selection highlight of the kit's fields.
    public func selection() -> Color {
        alpha(c.textAccent, 0.30)
    }

    /// A straight-alpha color as painted on `backdrop`.
    public func on(_ color: Color, backdrop: Color) -> Color {
        guard blendOver != nil else { return color }
        return Tok.forBlend(color, over: backdrop)
    }

    /// Elevation layers as painted: rings recolored by `c.borderBase` when `usePaletteRing` is set.
    public func shadowLayers(_ layers: [Shadow]) -> [Shadow] {
        guard usePaletteRing else { return layers }
        return layers.map { s in
            if s.blur == 0.0 {
                var copy = s
                copy.color = c.borderBase
                return copy
            }
            return s
        }
    }

    /// White at opacity `a` painted on `backdrop`.
    public func lightOn(_ a: Float, backdrop: Color) -> Color {
        on(c.white.alpha(a), backdrop: backdrop)
    }

    /// White at opacity `a`.
    public func light(_ a: Float) -> Color {
        alpha(c.white, a)
    }

    /// Black at opacity `a`.
    public func darkAlpha(_ a: Float) -> Color {
        alpha(c.black, a)
    }
}
