import Foundation
import Rune
import RuneMotion

/// Semantic status color bundle (`rune_kit::StateColors`).
public struct StateColors: Sendable, Equatable, Hashable {
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
public struct Palette: Sendable, Equatable, Hashable {
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
    public var raised: [Shadow] = []
    public var floating: [Shadow] = []
    public var overlay: [Shadow] = []
    public var buttonNeutral: [Shadow] = []
    public var buttonContrast: [Shadow] = []
    public var elements: [Shadow] = []
    public var switchOff: [Shadow] = []
    public var switchOn: [Shadow] = []
    public var md: [Shadow] = []
    public var knob: [Shadow] = []
    public var input: [Shadow] = []

    public init(
        raised: [Shadow] = [],
        floating: [Shadow] = [],
        overlay: [Shadow] = [],
        buttonNeutral: [Shadow] = [],
        buttonContrast: [Shadow] = [],
        elements: [Shadow] = [],
        switchOff: [Shadow] = [],
        switchOn: [Shadow] = [],
        md: [Shadow] = [],
        knob: [Shadow] = [],
        input: [Shadow] = []
    ) {
        self.raised = raised
        self.floating = floating
        self.overlay = overlay
        self.buttonNeutral = buttonNeutral
        self.buttonContrast = buttonContrast
        self.elements = elements
        self.switchOff = switchOff
        self.switchOn = switchOn
        self.md = md
        self.knob = knob
        self.input = input
    }

    /// Sets text fields' and field selects' own shadow (`--v2-elevation-input`).
    public func withInput(_ layers: [Shadow]) -> KitElevation {
        var copy = self
        copy.input = layers
        return copy
    }

    /// The shadow text fields and field selects draw (`input`, falling back to `buttonNeutral`).
    public func effectiveInput() -> [Shadow] {
        input.isEmpty ? buttonNeutral : input
    }
}

/// Small glyphs drawn inside components (`rune_kit::Glyphs`).
public struct Glyphs: Sendable, Equatable, Hashable {
    public var check: SVGIcon
    public var checkSmall: SVGIcon
    public var chevronDown: SVGIcon
    public var chevronUp: SVGIcon
    public var caretRight: SVGIcon
    public var triangleDown: SVGIcon
    public var triangleRight: SVGIcon
    public var close: SVGIcon
    public var clear: SVGIcon
    public var copy: SVGIcon
    public var search: SVGIcon
    public var lock: SVGIcon
    public var eye: SVGIcon
    public var eyeOff: SVGIcon
    public var circleX: SVGIcon
    /// A short horizontal rule (card title placeholder).
    public var dash: SVGIcon

    public init(
        check: SVGIcon,
        checkSmall: SVGIcon,
        chevronDown: SVGIcon,
        chevronUp: SVGIcon,
        caretRight: SVGIcon,
        triangleDown: SVGIcon,
        triangleRight: SVGIcon,
        close: SVGIcon,
        clear: SVGIcon,
        copy: SVGIcon,
        search: SVGIcon,
        lock: SVGIcon,
        eye: SVGIcon,
        eyeOff: SVGIcon,
        circleX: SVGIcon,
        dash: SVGIcon
    ) {
        self.check = check
        self.checkSmall = checkSmall
        self.chevronDown = chevronDown
        self.chevronUp = chevronUp
        self.caretRight = caretRight
        self.triangleDown = triangleDown
        self.triangleRight = triangleRight
        self.close = close
        self.clear = clear
        self.copy = copy
        self.search = search
        self.lock = lock
        self.eye = eye
        self.eyeOff = eyeOff
        self.circleX = circleX
        self.dash = dash
    }

    public static let `default` = Glyphs(
        check: KitIcons.check,
        checkSmall: KitIcons.checkSmall,
        chevronDown: KitIcons.chevronDown,
        chevronUp: KitIcons.chevronUp,
        caretRight: KitIcons.caretRight,
        triangleDown: KitIcons.triangleDown,
        triangleRight: KitIcons.triangleRight,
        close: KitIcons.close,
        clear: KitIcons.close,
        copy: KitIcons.copy,
        search: KitIcons.search,
        lock: KitIcons.lock,
        eye: KitIcons.eye,
        eyeOff: KitIcons.eyeOff,
        circleX: KitIcons.circleX,
        dash: KitIcons.dash
    )
}

public struct KitTypography: Sendable, Equatable, Hashable {
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

public struct KitRadius: Sendable, Equatable, Hashable {
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
    public static let check = SVGIcon(viewBox: 12, paths: ["M3 7.17905L5.02703 8.85135L9 3.5"], strokeWidth: 1.5)
    public static let checkSmall = SVGIcon(viewBox: 16, paths: ["M3.53564 8.17857L6.39279 11.75L12.4642 4.25"], strokeWidth: 1.0)
    public static let minus = SVGIcon(viewBox: 16, paths: ["M3.5 8H12.5"], strokeWidth: 2.0)
    public static let plus = SVGIcon(viewBox: 16, paths: ["M8 3.5V12.5", "M3.5 8H12.5"], strokeWidth: 1.8)
    public static let close = SVGIcon(viewBox: 16, paths: ["M4.25 11.75L11.75 4.25", "M11.75 11.75L4.25 4.25"], strokeWidth: 1.0)
    public static let chevronRight = SVGIcon(viewBox: 16, paths: ["M6 3.5L10.5 8L6 12.5"], strokeWidth: 1.8)
    public static let chevronDown = SVGIcon(viewBox: 16, paths: ["M5 6.5L8 9.5L11 6.5"], strokeWidth: 1.0)
    public static let chevronUp = SVGIcon(viewBox: 16, paths: ["M11 9.5L8 6.5L5 9.5"], strokeWidth: 1.0)
    public static let caretRight = SVGIcon(viewBox: 16, paths: ["M6 4L10 8L6 12V4Z"], strokeWidth: nil)
    public static let triangleDown = SVGIcon(viewBox: 16, paths: ["M4 6H12L8 10.5L4 6Z"], strokeWidth: nil)
    public static let triangleRight = SVGIcon(viewBox: 16, paths: ["M6.75194 10.62376C6.41861 10.81816 6 10.57776 6 10.19186V5.8079C6 5.422 6.41861 5.1816 6.75194 5.376L10.5096 7.56797C10.8404 7.76091 10.8404 8.23881 10.5096 8.43175L6.75194 10.62376Z"], strokeWidth: nil)
    public static let copy = SVGIcon(viewBox: 16, paths: ["M4.5 4.5V2.5H13.5V11.5H11.5M2.5 4.5H11.5V13.5H2.5V4.5Z"], strokeWidth: 1.0)
    public static let search = SVGIcon(viewBox: 16, paths: ["M14 14L10.3454 10.3454M6.88889 11.7778C9.58889 11.7778 11.7778 9.58889 11.7778 6.88889C11.7778 4.18889 9.58889 2 6.88889 2C4.18889 2 2 4.18889 2 6.88889C2 9.58889 4.18889 11.7778 6.88889 11.7778Z"], strokeWidth: 1.0)
    public static let circleX = SVGIcon(viewBox: 16, paths: ["M6 6L10 10M10 6L6 10M14.5 8C14.5 11.5899 11.5899 14.5 8 14.5C4.41015 14.5 1.5 11.5899 1.5 8C1.5 4.41015 4.41015 1.5 8 1.5C11.5899 1.5 14.5 4.41015 14.5 8Z"], strokeWidth: 1.0)
    public static let lock = SVGIcon(viewBox: 16, paths: ["M4.5 7H11.5A1 1 0 0 1 12.5 8V13A1 1 0 0 1 11.5 14H4.5A1 1 0 0 1 3.5 13V8A1 1 0 0 1 4.5 7Z", "M5.5 7V4.5a2.5 2.5 0 0 1 5 0V7M8 10v1.5"], strokeWidth: 1.0)
    public static let eye = SVGIcon(viewBox: 16, paths: ["M1 8s2.5-4.5 7-4.5S15 8 15 8s-2.5 4.5-7 4.5S1 8 1 8Z", "M6 8A2 2 0 1 0 10 8A2 2 0 1 0 6 8Z"], strokeWidth: 1.0)
    public static let eyeOff = SVGIcon(viewBox: 16, paths: ["m2 2 12 12M6.2 3.7A8 8 0 0 1 8 3.5C12.5 3.5 15 8 15 8a13 13 0 0 1 -2.4 2.8M10.3 12.1a8 8 0 0 1 -2.3 0.4C3.5 12.5 1 8 1 8a13 13 0 0 1 2.5 -2.9M6.6 6.6a2 2 0 0 0 2.8 2.8"], strokeWidth: 1.0)
    public static let dash = SVGIcon(viewBox: 20, paths: ["M5 9.5H15V10.5H5Z"], strokeWidth: nil)
    public static let arrowRight = SVGIcon(viewBox: 16, paths: ["M2.5 8H13.5M9 3.5L13.5 8L9 12.5"], strokeWidth: 1.0)
    public static let folder = SVGIcon(viewBox: 16, paths: ["M1.5 3.5H6L7.5 5H14.5V13.5H1.5V3.5Z"], strokeWidth: 1.0)
    public static let file = SVGIcon(viewBox: 16, paths: ["M3.5 1.5H9.5L12.5 4.5V14.5H3.5V1.5Z", "M9.5 1.5V4.5H12.5"], strokeWidth: 1.0)
    public static let info = SVGIcon(viewBox: 16, paths: ["M8 7.5V11.5", "M8 4.8V5.1"], strokeWidth: 2.0)
}

/// Themable component kit (`rune_kit::Kit`).
public struct Kit: Sendable, Equatable {
    public var dark: Bool
    public var c: Palette
    public var elevation: KitElevation
    public var glyph: Glyphs = .default
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
            submitFg: t.card,
            submitIcon: t.card,
            textBase: t.text,
            textMuted: t.textSecondary,
            textFaint: t.textSecondary.alpha(0.80),
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
            scrim: Color.black.alpha(0.30),
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
            surfaceRaisedBase: t.card,
            surfaceRaisedHover: t.hover,
            surfaceFloat: t.text,
            surfaceDisabled: t.controlTrack,
            borderWeak: t.separator,
            borderHover: t.cardBorder,
            borderActive: accent,
            borderDisabled: t.separator,
            textStrong: t.text,
            textWeak: t.textSecondary,
            textInvertStrong: t.card,
            iconWeaker: t.textSecondary,
            stdBorder: t.cardBorder,
            stdIcon: t.textSecondary,
            stdIconInvert: t.card,
            stdIconStrong: t.text,
            stdText: t.text
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
                elements: [drop(0.5, 0.5, t.edge)],
                md: [drop(4.0, 8.0, t.shadowSoft)],
                knob: [drop(1.0, 3.0, t.knobShadow)]
            ),
            glyph: .default,
            ty: KitTypography(
                ui: ui,
                uiMedium: ui.medium(),
                uiCompact: ui.lh(16.0),
                small: TextStyle(size: 11.0, weight: 400.0).lh(12.0),
                smallMedium: TextStyle(size: 11.0, weight: 500.0).lh(12.0),
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

    /// Gives `e` the kit's hover and press overlays (`c.hover` and `c.pressed`).
    public func interactive<S>(_ e: El<S>) -> El<S> {
        interactiveWith(e, hover: c.hover, pressed: c.pressed)
    }

    /// Gives `e` custom hover and press overlays; `pressed` replaces `hover` while held.
    public func interactiveWith<S>(_ e: El<S>, hover: Color, pressed: Color) -> El<S> {
        e.hover(hover).press(pressed)
    }

    /// Paints elevation layers on `e` as box shadows (respecting `usePaletteRing`).
    public func elevate<S>(_ e: El<S>, _ layers: [Shadow]) -> El<S> {
        e.shadows(shadowLayers(layers))
    }
}
