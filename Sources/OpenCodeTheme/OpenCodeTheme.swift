import Foundation
import Rune
import RuneKit
import RuneMotion

/// Named OpenCode Radix-style 12-step color scales.
public enum OpenCodeColorScale: String, CaseIterable, Sendable, Hashable {
    case amber
    case apple
    case blue
    case cobalt
    case coral
    case ember
    case gray
    case ink
    case lilac
    case mint
    case smoke
    case solaris
    case yuzu
}

/// Semantic status tone for OpenCode styled helpers.
public enum OpenCodeTone: Sendable, Hashable {
    case neutral
    case accent
    case success
    case warning
    case danger
    case info
}

/// Syntax highlighting palette from OpenCode's `syntax-*` tokens.
public struct OpenCodeSyntaxPalette: Sendable, Equatable {
    public var comment: Color
    public var constant: Color
    public var critical: Color
    public var diffAdd: Color
    public var diffDelete: Color
    public var diffUnknown: Color
    public var info: Color
    public var keyword: Color
    public var object: Color
    public var operatorToken: Color
    public var primitive: Color
    public var property: Color
    public var punctuation: Color
    public var regexp: Color
    public var string: Color
    public var success: Color
    public var type: Color
    public var variable: Color
    public var warning: Color
}

/// Spacing, container, and breakpoint metrics from OpenCode's `numbers` table.
public struct OpenCodeSpacingTokens: Sendable, Equatable {
    public var unit: Float
    public var radiusXS: Float
    public var radiusSM: Float
    public var radiusMD: Float
    public var radiusLG: Float
    public var radiusXL: Float
    public var containerSession: Float
    public var breakpointSM: Float
    public var breakpointMD: Float
    public var breakpointLG: Float
    public var breakpointXL: Float
    public var breakpoint2XL: Float

    public func step(_ multiplier: Float) -> Float {
        unit * multiplier
    }
}

/// OpenCode SVG icon catalog (`themes/opencode/src/icons.rs`).
public enum OpenCodeIcons {
    public static let magnifyingGlass = SVGIcon(
        viewBox: 16,
        paths: [
            "M14 14L10.3454 10.3454M6.88889 11.7778C9.58889 11.7778 11.7778 9.58889 11.7778 6.88889C11.7778 4.18889 9.58889 2 6.88889 2C4.18889 2 2 4.18889 2 6.88889C2 9.58889 4.18889 11.7778 6.88889 11.7778Z"
        ],
        strokeWidth: 1.5
    )

    public static let close = SVGIcon(
        viewBox: 20,
        paths: ["M14.4446 5.55566L5.55566 14.4446M5.55566 5.55566L14.4446 14.4446"],
        strokeWidth: 1.5
    )

    public static let xmarkSmall = SVGIcon(
        viewBox: 16,
        paths: ["M4.25 11.75L11.75 4.25M11.75 11.75L4.25 4.25"],
        strokeWidth: 1.5
    )

    public static let fillTriangleDown = SVGIcon(
        viewBox: 16,
        paths: ["M5.37624 6.75194C5.18184 6.41861 5.42224 6 5.80814 6H10.1921C10.578 6 10.8184 6.41861 10.624 6.75194L8.43203 10.5096C8.23909 10.8404 7.76119 10.8404 7.56825 10.5096L5.37624 6.75194Z"]
    )

    public static let circleX = SVGIcon(
        viewBox: 20,
        paths: [
            "M1.6665 10.0003C1.6665 5.39795 5.39746 1.66699 9.99984 1.66699C14.6022 1.66699 18.3332 5.39795 18.3332 10.0003C18.3332 14.6027 14.6022 18.3337 9.99984 18.3337C5.39746 18.3337 1.6665 14.6027 1.6665 10.0003ZM7.49984 6.91107L6.91058 7.50033L9.41058 10.0003L6.91058 12.5003L7.49984 13.0896L9.99984 10.5896L12.4998 13.0896L13.0891 12.5003L10.5891 10.0003L13.0891 7.50033L12.4998 6.91107L9.99984 9.41107L7.49984 6.91107Z"
        ]
    )

    public static let copy = SVGIcon(
        viewBox: 20,
        paths: ["M6.2513 6.24935V2.91602H17.0846V13.7493H13.7513M13.7513 6.24935V17.0827H2.91797V6.24935H13.7513Z"],
        strokeWidth: 1.5
    )
}

/// OpenCode's design language as a Rune / RuneKit theme (`themes/opencode`).
public enum OpenCodeTheme {
    /// Font families (`sans`: Inter, `mono`: IBM Plex Mono).
    public static let families: (sans: String, mono: String) = ("Inter", "IBM Plex Mono")

    /// Spacing and layout numbers from `theme.json`.
    public static let spacingTokens = OpenCodeSpacingTokens(
        unit: OpenCodeThemeData.numbers["spacing"] ?? 4.0,
        radiusXS: OpenCodeThemeData.numbers["radius-xs"] ?? 2.0,
        radiusSM: OpenCodeThemeData.numbers["radius-sm"] ?? 4.0,
        radiusMD: OpenCodeThemeData.numbers["radius-md"] ?? 6.0,
        radiusLG: OpenCodeThemeData.numbers["radius-lg"] ?? 8.0,
        radiusXL: OpenCodeThemeData.numbers["radius-xl"] ?? 10.0,
        containerSession: OpenCodeThemeData.numbers["container-session"] ?? 744.0,
        breakpointSM: OpenCodeThemeData.numbers["breakpoint-sm"] ?? 640.0,
        breakpointMD: OpenCodeThemeData.numbers["breakpoint-md"] ?? 768.0,
        breakpointLG: OpenCodeThemeData.numbers["breakpoint-lg"] ?? 1024.0,
        breakpointXL: OpenCodeThemeData.numbers["breakpoint-xl"] ?? 1280.0,
        breakpoint2XL: OpenCodeThemeData.numbers["breakpoint-2xl"] ?? 1536.0
    )

    private static let rawDarkTheme = buildJsonTheme(dark: true, srgbBlend: true)
    private static let rawLightTheme = buildJsonTheme(dark: false, srgbBlend: true)
    private static let linearDarkTheme = buildJsonTheme(dark: true, srgbBlend: false)
    private static let linearLightTheme = buildJsonTheme(dark: false, srgbBlend: false)

    private static let srgbDarkKit = buildKit(dark: true, srgbBlend: true)
    private static let srgbLightKit = buildKit(dark: false, srgbBlend: true)
    private static let linearDarkKit = buildKit(dark: true, srgbBlend: false)
    private static let linearLightKit = buildKit(dark: false, srgbBlend: false)

    /// Returns the resolved `JsonTheme` for `dark` or light appearance.
    /// When `srgbBlend` is `false`, translucent tokens are adapted for linear-light blending over `v2-background-bg-base`.
    public static func theme(dark: Bool, srgbBlend: Bool = true) -> JsonTheme {
        if srgbBlend {
            return dark ? rawDarkTheme : rawLightTheme
        } else {
            return dark ? linearDarkTheme : linearLightTheme
        }
    }

    /// Returns the raw `JsonTheme` preserving authored alpha values.
    public static func rawTheme(dark: Bool) -> JsonTheme {
        dark ? rawDarkTheme : rawLightTheme
    }

    /// Returns a `RuneKit.Kit` configured with OpenCode's palette, elevation, typography, radius, and motion.
    public static func kit(dark: Bool, srgbBlend: Bool = true) -> Kit {
        if srgbBlend {
            return dark ? srgbDarkKit : srgbLightKit
        } else {
            return dark ? linearDarkKit : linearLightKit
        }
    }

    /// Looks up a single token color by name (without leading `--`).
    public static func color(_ name: String, dark: Bool, srgbBlend: Bool = true) -> Color? {
        theme(dark: dark, srgbBlend: srgbBlend)[name]
    }

    /// Looks up a numeric token from `theme.json`.
    public static func number(_ name: String) -> Float? {
        OpenCodeThemeData.numbers[name]
    }

    /// Returns `spacing * multiplier` (base unit is 4pt).
    public static func spacing(_ multiplier: Float = 1.0) -> Float {
        spacingTokens.step(multiplier)
    }

    /// The brand's hot color for one appearance (`ember` step 9).
    public static func brand(dark: Bool) -> Color {
        ember(dark: dark, step: 9)
    }

    /// One step (`1...12`) of the `ember` scale.
    public static func ember(dark: Bool, step: Int) -> Color {
        scale(.ember, dark: dark, step: step)
    }

    /// One step (`1...12`) of a named OpenCode color scale.
    public static func scale(_ name: String, dark: Bool, step: Int) -> Color {
        precondition((1...12).contains(step), "Color scale steps run 1 to 12, got \(step)")
        let mode = dark ? "dark" : "light"
        return theme(dark: dark)["\(name)-\(mode)-\(step)"] ?? .transparent
    }

    /// One step (`1...12`) of a strongly-typed `OpenCodeColorScale`.
    public static func scale(_ scale: OpenCodeColorScale, dark: Bool, step: Int) -> Color {
        self.scale(scale.rawValue, dark: dark, step: step)
    }

    /// Syntax highlighting color palette for `dark` or light mode.
    public static func syntax(dark: Bool) -> OpenCodeSyntaxPalette {
        let t = theme(dark: dark)
        func c(_ key: String) -> Color { t[key] ?? .transparent }
        return OpenCodeSyntaxPalette(
            comment: c("syntax-comment"),
            constant: c("syntax-constant"),
            critical: c("syntax-critical"),
            diffAdd: c("syntax-diff-add"),
            diffDelete: c("syntax-diff-delete"),
            diffUnknown: c("syntax-diff-unknown"),
            info: c("syntax-info"),
            keyword: c("syntax-keyword"),
            object: c("syntax-object"),
            operatorToken: c("syntax-operator"),
            primitive: c("syntax-primitive"),
            property: c("syntax-property"),
            punctuation: c("syntax-punctuation"),
            regexp: c("syntax-regexp"),
            string: c("syntax-string"),
            success: c("syntax-success"),
            type: c("syntax-type"),
            variable: c("syntax-variable"),
            warning: c("syntax-warning")
        )
    }

    /// Parses a named CSS shadow token from `theme.json`.
    public static func shadows(_ name: String, dark: Bool, srgbBlend: Bool = true) -> [Shadow] {
        let map = dark ? OpenCodeThemeData.darkShadows : OpenCodeThemeData.lightShadows
        guard let raw = map[name] else { return [] }
        let bg = rawTheme(dark: dark)["v2-background-bg-base"] ?? (dark ? .black : .white)
        return parseBoxShadows(raw) { color in
            Tok.forBlend(color, over: bg, srgbBlend: srgbBlend)
        }
    }

    /// Parses CSS `box-shadow` comma-separated layers into `[Rune.Shadow]`.
    public static func parseBoxShadows(_ css: String, solve: (Color) -> Color = { $0 }) -> [Shadow] {
        let layers = splitShadowLayers(css)
        var out: [Shadow] = []
        for layer in layers {
            let trimmed = layer.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "none" { continue }

            var inset = false
            var color: Color? = nil
            var lengths: [Float] = []

            for token in tokenizeShadowLayer(trimmed) {
                let lower = token.lowercased()
                if lower == "inset" {
                    inset = true
                } else if let parsedColor = parseCSSColor(token) {
                    color = solve(parsedColor)
                } else if let px = parseCSSLength(token) {
                    lengths.append(px)
                }
            }

            guard lengths.count >= 2 else { continue }
            let x = lengths[0]
            let y = lengths[1]
            let blur = lengths.count >= 3 ? lengths[2] : 0
            let spread = lengths.count >= 4 ? lengths[3] : 0
            out.append(Shadow(
                x: x,
                y: y,
                blur: blur,
                spread: spread,
                color: color ?? solve(Color.black.alpha(0.18)),
                inset: inset
            ))
        }
        return out
    }

    // MARK: - Styled El Helpers

    /// Builds a surface container styled with OpenCode's layered background tokens.
    public static func surface<State>(dark: Bool, level: Int = 1) -> El<State> {
        let k = kit(dark: dark)
        let fill: Color = switch level {
        case ...0: k.c.bgDeep
        case 1: k.c.layer01
        case 2: k.c.layer02
        case 3: k.c.layer03
        default: k.c.layer04
        }
        return El<State>(direction: .column).bg(fill).border(1, k.c.borderMuted).rounded(k.radius.md)
    }

    /// Builds a card container with OpenCode surface, border, radius, and elevation.
    public static func card<State>(dark: Bool, elevated: Bool = false) -> El<State> {
        let k = kit(dark: dark)
        var node: El<State> = El<State>(direction: .column)
            .bg(k.c.bgBase)
            .border(1, k.c.borderBase)
            .rounded(k.radius.lg)
            .p(spacing(3))
        if elevated {
            node = node.shadows(k.elevation.raised)
        }
        return node
    }

    /// Builds a semantic status badge (`neutral`, `accent`, `success`, `warning`, `danger`, `info`).
    public static func badge<State>(_ label: String, dark: Bool, tone: OpenCodeTone = .neutral) -> El<State> {
        let k = kit(dark: dark)
        let (bg, fg, border): (Color, Color, Color) = switch tone {
        case .neutral: (k.c.layer02, k.c.textMuted, k.c.borderMuted)
        case .accent: (k.alpha(k.c.bgAccent, 0.16), k.c.textAccent, k.alpha(k.c.borderFocus, 0.5))
        case .success: (k.c.success.bg, k.c.success.fg, k.c.success.border)
        case .warning: (k.c.warning.bg, k.c.warning.fg, k.c.warning.border)
        case .danger: (k.c.danger.bg, k.c.danger.fg, k.c.danger.border)
        case .info: (k.c.info.bg, k.c.info.fg, k.c.info.border)
        }
        let labelEl: El<State> = text(label).font(k.ty.smallMedium).color(fg)
        return El<State>(direction: .row)
            .px(8)
            .py(3)
            .rounded(k.radius.sm)
            .bg(bg)
            .border(1, border)
            .center()
            .child(labelEl)
    }

    /// Builds a 1pt horizontal divider using OpenCode's muted border token.
    public static func divider<State>(dark: Bool) -> El<State> {
        rule(1, kit(dark: dark).c.borderMuted)
    }

    /// Builds an OpenCode ember brand swatch / mark.
    public static func brandMark<State>(dark: Bool, size: Float = 20.0) -> El<State> {
        El<State>(direction: .row)
            .size(size, size)
            .rounded(spacingTokens.radiusSM)
            .bg(brand(dark: dark))
    }

    // MARK: - Private Builders

    private static func buildJsonTheme(dark: Bool, srgbBlend: Bool) -> JsonTheme {
        let rawMap = dark ? OpenCodeThemeData.darkColors : OpenCodeThemeData.lightColors
        var rawColors: [String: Color] = [:]
        rawColors.reserveCapacity(rawMap.count)
        for (k, hex) in rawMap {
            if let c = Color.hex(hex) {
                rawColors[k] = c
            }
        }
        let blendBase = rawColors["v2-background-bg-base"] ?? (dark ? .black : .white)
        if !srgbBlend {
            for (k, c) in rawColors where c.a < 0.999 && k != "v2-background-bg-base" {
                rawColors[k] = c.srgbEquivalent(over: blendBase)
            }
        }
        return JsonTheme(name: "OpenCode", colors: rawColors, numbers: OpenCodeThemeData.numbers)
    }

    private static func buildKit(dark: Bool, srgbBlend: Bool) -> Kit {
        let t = theme(dark: dark, srgbBlend: srgbBlend)
        let raw = rawTheme(dark: dark)

        func c(_ n: String) -> Color { t[n] ?? .transparent }
        func v(_ n: String) -> Color { t["v2-\(n)"] ?? .transparent }
        func rawV(_ n: String) -> Color { raw["v2-\(n)"] ?? .transparent }
        func orColor(_ n: String, _ fallback: Color) -> Color { t[n] ?? fallback }
        func state(_ n: String, icon: Color) -> StateColors {
            StateColors(
                bg: v("state-bg-\(n)"),
                fg: v("state-fg-\(n)"),
                border: v("state-border-\(n)"),
                icon: icon
            )
        }

        let blend = v("background-bg-base")
        func solve(_ x: Color) -> Color {
            Tok.forBlend(x, over: blend, srgbBlend: srgbBlend)
        }

        let shadowMap = dark ? OpenCodeThemeData.darkShadows : OpenCodeThemeData.lightShadows
        func sh(_ n: String) -> [Shadow] {
            guard let src = shadowMap[n] else { return [] }
            return parseBoxShadows(src, solve: solve)
        }

        var k = Kit.neutral(dark: dark)
        k.c.page = c("background-base")
        k.c.bgBase = blend
        k.c.bgDeep = v("background-bg-deep")
        k.c.layer01 = v("background-bg-layer-01")
        k.c.layer02 = v("background-bg-layer-02")
        k.c.layer03 = v("background-bg-layer-03")
        k.c.layer04 = v("background-bg-layer-04")
        k.c.bgInverse = v("background-bg-inverse")
        k.c.bgContrast = v("background-bg-contrast")
        k.c.bgButtonNeutral = v("background-bg-button-neutral")
        k.c.bgIconButtonContrast = v("background-bg-icon-button-contrast")
        k.c.bgAccent = v("background-bg-accent")
        k.c.submitHighlight = dark ? rawV("alpha-light-60") : rawV("alpha-light-20")
        k.c.submitHover = dark ? rawV("alpha-dark-8") : rawV("overlay-simple-overlay-contrast-hover")
        k.c.submitFg = dark ? v("text-text-inverse") : v("text-text-contrast")
        k.c.submitIcon = dark ? v("icon-icon-inverse") : v("text-text-contrast")
        k.c.textBase = v("text-text-base")
        k.c.textMuted = v("text-text-muted")
        k.c.textFaint = v("text-text-faint")
        k.c.textInverse = v("text-text-inverse")
        k.c.textContrast = v("text-text-contrast")
        k.c.textAccent = v("text-text-accent")
        k.c.iconBase = v("icon-icon-base")
        k.c.iconMuted = v("icon-icon-muted")
        k.c.iconFaint = v("icon-icon-faint")
        k.c.iconInverse = v("icon-icon-inverse")
        k.c.iconContrast = v("icon-icon-contrast")
        k.c.iconAccent = v("icon-icon-accent")
        k.c.borderMuted = v("border-border-muted")
        k.c.borderBase = v("border-border-base")
        k.c.borderStrong = v("border-border-strong")
        k.c.borderFocus = v("border-border-focus")
        k.c.hover = v("overlay-simple-overlay-hover")
        k.c.pressed = v("overlay-simple-overlay-pressed")
        k.c.contrastHover = rawV("overlay-simple-overlay-contrast-hover")
        k.c.contrastPressed = rawV("overlay-simple-overlay-contrast-pressed")
        k.c.scrim = v("overlay-simple-overlay-scrim")
        k.c.depthTop = rawV("overlay-gradient-depth-overlay-depth-top")
        k.c.depthBottom = rawV("overlay-gradient-depth-overlay-depth-bot")
        k.c.white = v("alpha-light-100").alpha(1.0)
        k.c.black = v("alpha-dark-100").alpha(1.0)
        k.c.knob = v("grey-200")
        k.c.knobOn = v("grey-300")
        k.c.success = state("success", icon: c("icon-success-active"))
        k.c.warning = state("warning", icon: c("icon-warning-active"))
        k.c.danger = state("danger", icon: v("state-fg-danger"))
        k.c.info = state("info", icon: c("icon-info-active"))
        k.c.surfaceBase = c("surface-base")
        k.c.surfaceWeak = c("surface-weak")
        k.c.surfaceHover = orColor("surface-hover", .transparent)
        k.c.surfaceRaised = c("surface-raised-stronger-non-alpha")
        k.c.surfaceRaisedBase = c("surface-raised-base")
        k.c.surfaceRaisedHover = c("surface-raised-base-hover")
        k.c.surfaceFloat = c("surface-float-base")
        k.c.surfaceDisabled = orColor("surface-disabled", .transparent)
        k.c.borderWeak = c("border-weak-base")
        k.c.borderHover = c("border-hover")
        k.c.borderActive = c("border-active")
        k.c.borderDisabled = c("border-disabled")
        k.c.textStrong = c("text-strong")
        k.c.textWeak = c("text-weak")
        k.c.textInvertStrong = c("text-invert-strong")
        k.c.iconWeaker = orColor("icon-weaker", c("text-base"))
        k.c.stdBorder = c("border-base")
        k.c.stdIcon = c("icon-base")
        k.c.stdIconInvert = c("icon-invert-base")
        k.c.stdIconStrong = c("icon-strong-base")
        k.c.stdText = c("text-base")

        k.elevation.raised = sh("v2-elevation-raised")
        k.elevation.floating = sh("v2-elevation-floating")
        k.elevation.overlay = sh("v2-elevation-overlay")
        k.elevation.buttonNeutral = sh("v2-elevation-button-neutral")
        k.elevation.buttonContrast = sh("v2-elevation-button-contrast")
        k.elevation.elements = sh("v2-elevation-elements")
        k.elevation.switchOff = sh("v2-elevation-switch-off")
        k.elevation.switchOn = sh("v2-elevation-switch-on")
        k.elevation.md = sh("shadow-md")
        k.elevation.knob = parseBoxShadows("#1310100a 0px 1px 2px -1px, #1310100f 0px 1px 2px 0px, #13101014 0px 1px 3px 0px", solve: solve)
        k.elevation.input = sh("v2-elevation-input")

        func inter(_ size: Float, _ weight: Float, _ line: Float, _ tracking: Float) -> TextStyle {
            TextStyle(size: size, weight: weight).lh(line).letterSpacing(tracking)
        }

        k.ty.ui = inter(13.0, 440.0, 20.0, -0.04)
        k.ty.uiMedium = inter(13.0, 530.0, 20.0, -0.04)
        k.ty.uiCompact = inter(13.0, 440.0, 16.0, -0.04)
        k.ty.small = inter(11.0, 440.0, 12.0, 0.05)
        k.ty.smallMedium = inter(11.0, 530.0, 12.0, 0.05)
        k.ty.body = inter(14.0, 400.0, 21.0, 0.0)
        k.ty.bodyMedium = inter(14.0, 500.0, 21.0, 0.0)
        k.ty.textSmall = inter(13.0, 400.0, 19.5, 0.0)
        k.ty.textSmallMedium = inter(13.0, 500.0, 19.5, 0.0)
        k.ty.textXsmall = inter(12.0, 400.0, 18.0, 0.0)
        k.ty.textXsmallMedium = inter(12.0, 500.0, 18.0, 0.0)
        k.ty.mono = TextStyle(size: 12.0, weight: 400.0).mono().lh(18.0)

        k.radius.xs = spacingTokens.radiusXS
        k.radius.sm = spacingTokens.radiusSM
        k.radius.md = spacingTokens.radiusMD
        k.radius.lg = spacingTokens.radiusLG
        k.radius.xl = spacingTokens.radiusXL

        k.motion.control = Spring(duration: 0.2, bounce: 0.0)
        k.motion.overlay = Spring(duration: 0.24, bounce: 0.0)
        k.motion.disclosure = Spring(duration: 0.3, bounce: 0.0)

        k.blendOver = blend
        k.usePaletteRing = false
        k.invalidText = true
        return k
    }

    private static func splitShadowLayers(_ css: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        for ch in css {
            if ch == "(" { depth += 1 }
            else if ch == ")" { depth = max(0, depth - 1) }
            if ch == "," && depth == 0 {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func tokenizeShadowLayer(_ layer: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        for ch in layer {
            if ch == "(" { depth += 1 }
            else if ch == ")" { depth = max(0, depth - 1) }
            if ch.isWhitespace && depth == 0 {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func parseCSSLength(_ token: String) -> Float? {
        let lower = token.lowercased()
        if lower == "0" { return 0 }
        if lower.hasSuffix("px") {
            return Float(lower.dropLast(2))
        }
        return Float(lower)
    }

    private static func parseCSSColor(_ token: String) -> Color? {
        if token.hasPrefix("#") {
            return Color.hex(token)
        }
        let lower = token.lowercased()
        if lower.hasPrefix("rgba(") && lower.hasSuffix(")") {
            let inner = lower.dropFirst(5).dropLast()
            let parts = inner.split(separator: ",").map { Float($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 4, let r = parts[0], let g = parts[1], let b = parts[2], let a = parts[3] {
                return Color(r: r / 255.0, g: g / 255.0, b: b / 255.0, a: a)
            }
        } else if lower.hasPrefix("rgb(") && lower.hasSuffix(")") {
            let inner = lower.dropFirst(4).dropLast()
            let parts = inner.split(separator: ",").map { Float($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 3, let r = parts[0], let g = parts[1], let b = parts[2] {
                return Color(r: r / 255.0, g: g / 255.0, b: b / 255.0, a: 1.0)
            }
        }
        return nil
    }
}
