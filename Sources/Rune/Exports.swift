@_exported import RuneMotion
@_exported import RuneRef
import Foundation
#if canImport(simd)
import simd
#endif

/// Linear-light sRGB color with straight alpha (`[0, 1]`), matching `rune::Color`.
public struct Color: Animatable, Hashable, Codable, Sendable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public static let laneCount = 4
    public static let zeroValue = Color.transparent

    public static let transparent = Color(r: 0, g: 0, b: 0, a: 0)
    public static let black = Color(r: 0, g: 0, b: 0, a: 1)
    public static let white = Color(r: 1, g: 1, b: 1, a: 1)

    @inlinable
    public init(r: Float, g: Float, b: Float, a: Float = 1.0) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Creates a `Color` from gamma-encoded sRGB components in `[0, 1]`.
    @inlinable
    public static func srgb(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1.0) -> Color {
        Color(
            r: RefShader.srgbToLinear(r),
            g: RefShader.srgbToLinear(g),
            b: RefShader.srgbToLinear(b),
            a: a.clamped(to: 0...1)
        )
    }

    /// Creates a `Color` from 8-bit sRGB channels `0...255`.
    @inlinable
    public static func rgba8(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> Color {
        srgb(Float(r) / 255.0, Float(g) / 255.0, Float(b) / 255.0, Float(a) / 255.0)
    }

    /// Parses `#rgb`, `#rgba`, `#rrggbb`, or `#rrggbbaa` (with or without leading `#`).
    public static func hex(_ str: String) -> Color? {
        var s = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        let chars = Array(s)
        func hexByte(_ hi: Character, _ lo: Character) -> UInt8? {
            guard let h = hi.hexDigitValue, let l = lo.hexDigitValue else { return nil }
            return UInt8(h * 16 + l)
        }
        switch chars.count {
        case 3:
            guard let r = hexByte(chars[0], chars[0]),
                  let g = hexByte(chars[1], chars[1]),
                  let b = hexByte(chars[2], chars[2]) else { return nil }
            return rgba8(r, g, b, 255)
        case 4:
            guard let r = hexByte(chars[0], chars[0]),
                  let g = hexByte(chars[1], chars[1]),
                  let b = hexByte(chars[2], chars[2]),
                  let a = hexByte(chars[3], chars[3]) else { return nil }
            return rgba8(r, g, b, a)
        case 6:
            guard let r = hexByte(chars[0], chars[1]),
                  let g = hexByte(chars[2], chars[3]),
                  let b = hexByte(chars[4], chars[5]) else { return nil }
            return rgba8(r, g, b, 255)
        case 8:
            guard let r = hexByte(chars[0], chars[1]),
                  let g = hexByte(chars[2], chars[3]),
                  let b = hexByte(chars[4], chars[5]),
                  let a = hexByte(chars[6], chars[7]) else { return nil }
            return rgba8(r, g, b, a)
        default:
            return nil
        }
    }

    /// Formats the color as `#rrggbb` (when `a >= 0.999`) or `#rrggbbaa` in sRGB space.
    public func hexString() -> String {
        let sr = UInt8((RefShader.linearToSRGB(r) * 255.0).rounded())
        let sg = UInt8((RefShader.linearToSRGB(g) * 255.0).rounded())
        let sb = UInt8((RefShader.linearToSRGB(b) * 255.0).rounded())
        let sa = UInt8((a.clamped(to: 0...1) * 255.0).rounded())
        if sa == 255 {
            return String(format: "#%02x%02x%02x", sr, sg, sb)
        } else {
            return String(format: "#%02x%02x%02x%02x", sr, sg, sb, sa)
        }
    }

    /// Formats the color as `#rrggbbaa` in sRGB space, matching `rune::Color::hex()`.
    public func hex() -> String {
        let sr = UInt8((RefShader.linearToSRGB(r) * 255.0).clamped(to: 0...255).rounded())
        let sg = UInt8((RefShader.linearToSRGB(g) * 255.0).clamped(to: 0...255).rounded())
        let sb = UInt8((RefShader.linearToSRGB(b) * 255.0).clamped(to: 0...255).rounded())
        let sa = UInt8((a.clamped(to: 0...1) * 255.0).rounded())
        return String(format: "#%02x%02x%02x%02x", sr, sg, sb, sa)
    }

    /// Normalizes float bit patterns for hashing (`-0.0` hashes as `0.0`, all NaNs hash alike).
    @inlinable
    public static func hashBits(_ x: Float) -> UInt32 {
        if x == 0.0 { return 0 }
        if x.isNaN { return Float.nan.bitPattern }
        return x.bitPattern
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Self.hashBits(r))
        hasher.combine(Self.hashBits(g))
        hasher.combine(Self.hashBits(b))
        hasher.combine(Self.hashBits(a))
    }

    /// Perceptual OKLCH constructor (`L in [0, 1]`, `C >= 0`, `hueDegrees in [0, 360)`).
    public static func oklch(_ l: Float, _ c: Float, _ hueDegrees: Float) -> Color {
        oklcha(l, c, hueDegrees, 1.0)
    }

    /// Perceptual OKLCH + alpha constructor.
    public static func oklcha(_ l: Float, _ c: Float, _ hueDegrees: Float, _ alpha: Float) -> Color {
        let rad = hueDegrees * (.pi / 180.0)
        let okA = c * cosf(rad)
        let okB = c * sinf(rad)
        return fromOKLab([l, okA, okB, alpha])
    }

    public func toOKLab() -> [Float] {
        let mc = motionColor
        let lab = mc.toOKLab()
        return [lab.L, lab.a, lab.b, a]
    }

    public static func fromOKLab(_ lab: [Float]) -> Color {
        guard lab.count >= 4 else { return .transparent }
        let mc = MotionColor.fromOKLab(L: lab[0], a: lab[1], b: lab[2], alpha: lab[3])
        return Color(r: mc.r, g: mc.g, b: mc.b, a: mc.a)
    }

    /// Relative WCAG luminance `Y` in linear light.
    @inlinable
    public var luminance: Float {
        0.2126 * max(0, r) + 0.7152 * max(0, g) + 0.0722 * max(0, b)
    }

    /// WCAG 2.x contrast ratio `(L_max + 0.05) / (L_min + 0.05)` in `[1, 21]`.
    @inlinable
    public func contrastRatio(with other: Color) -> Float {
        let l1 = luminance
        let l2 = other.luminance
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @inlinable
    public func alpha(_ newAlpha: Float) -> Color {
        Color(r: r, g: g, b: b, a: newAlpha.clamped(to: 0...1))
    }

    @inlinable
    public func scaleAlpha(_ factor: Float) -> Color {
        Color(r: r, g: g, b: b, a: (a * factor).clamped(to: 0...1))
    }

    /// `t` of the way from `self` to `other`, straight in linear light (`rune::Color::mix`).
    @inlinable
    public func mix(with other: Color, t: Float) -> Color {
        Color(
            r: r + (other.r - r) * t,
            g: g + (other.g - g) * t,
            b: b + (other.b - b) * t,
            a: a + (other.a - a) * t
        )
    }

    /// Perceptual OKLab interpolation from `self` toward `other` by `t in [0, 1]`.
    public func mixOklab(with other: Color, t: Float) -> Color {
        let f = t.clamped(to: 0...1)
        let aLanes = toLanes()
        let bLanes = other.toLanes()
        var out = MotionLanes()
        for i in 0..<4 {
            out[i] = aLanes[i] + (bLanes[i] - aLanes[i]) * f
        }
        return Color.fromLanes(out)
    }

    /// Premultiplied linear RGBA (`rune::Color::premul`).
    @inlinable
    public func premul(_ opacity: Float = 1.0) -> SIMD4<Float> {
        let alpha = a * opacity
        return SIMD4<Float>(r * alpha, g * alpha, b * alpha, alpha)
    }

    /// Premultiplied sRGB-encoded RGBA for gamma-space (`srgbBlend`) targets (`rune::Color::premul_srgb`).
    @inlinable
    public func premulSRGB(_ opacity: Float = 1.0) -> SIMD4<Float> {
        let alpha = a * opacity
        return SIMD4<Float>(
            RefShader.linearToSRGB(r) * alpha,
            RefShader.linearToSRGB(g) * alpha,
            RefShader.linearToSRGB(b) * alpha,
            alpha
        )
    }

    /// Source-over composite of premultiplied `top` onto premultiplied `bottom` (`rune::color::over`).
    @inlinable
    public static func over(_ top: SIMD4<Float>, _ bottom: SIMD4<Float>) -> SIMD4<Float> {
        let k = 1.0 - top.w
        return SIMD4<Float>(
            top.x + bottom.x * k,
            top.y + bottom.y * k,
            top.z + bottom.z * k,
            top.w + bottom.w * k
        )
    }

    /// Solves for a straight-alpha linear-light color whose linear-light composite over `bg`
    /// reproduces CSS / browser gamma-space sRGB blending of `self` over `bg`!
    ///
    /// Matches `rune::theme::srgb_equivalent`: ITU-R BT.709 luminance-weighted least-squares
    /// fit keeping linear RGB unchanged (`theme.rs:86-104`).
    public func srgbEquivalent(over bg: Color) -> Color {
        if a >= 0.999 || a <= 0.0 { return self }
        @inline(__always)
        func ch(_ cv: Float, _ bv: Float) -> (Float, Float, Float) {
            let t = a * RefShader.linearToSRGB(cv) + (1.0 - a) * RefShader.linearToSRGB(bv)
            return (RefShader.srgbToLinear(t), cv, bv)
        }
        let parts = [ch(r, bg.r), ch(g, bg.g), ch(b, bg.b)]
        let w: (Float, Float, Float) = (0.2126, 0.7152, 0.0722)
        let weights = [w.0, w.1, w.2]
        var num: Float = 0.0
        var den: Float = 0.0
        for (i, part) in parts.enumerated() {
            let d = part.1 - part.2
            num += weights[i] * d * (part.0 - part.2)
            den += weights[i] * d * d
        }
        let solvedA = den > 1e-9 ? (num / den).clamped(to: 0...1) : a
        return Color(r: r, g: g, b: b, a: solvedA)
    }

    @inlinable
    public var motionColor: MotionColor {
        MotionColor(r: r, g: g, b: b, a: a)
    }

    @inlinable
    public init(_ mc: MotionColor) {
        self.init(r: mc.r, g: mc.g, b: mc.b, a: mc.a)
    }

    @inlinable
    public func simd4(srgb: Bool) -> SIMD4<Float> {
        if srgb {
            return SIMD4<Float>(
                RefShader.linearToSRGB(r),
                RefShader.linearToSRGB(g),
                RefShader.linearToSRGB(b),
                a.clamped(to: 0...1)
            )
        }
        return SIMD4<Float>(r, g, b, a.clamped(to: 0...1))
    }

    public func toLanes() -> MotionLanes { motionColor.toLanes() }
    public static func fromLanes(_ lanes: MotionLanes) -> Color { Color(MotionColor.fromLanes(lanes)) }
}

/// Top-level convenience matching `rune::oklch`, `rune::oklcha`, and `rune::color::hex`.
@inlinable
public func oklch(_ l: Float, _ c: Float, _ hueDegrees: Float) -> Color {
    Color.oklch(l, c, hueDegrees)
}

@inlinable
public func oklcha(_ l: Float, _ c: Float, _ hueDegrees: Float, _ alpha: Float) -> Color {
    Color.oklcha(l, c, hueDegrees, alpha)
}

/// Parses `#rgb`, `#rrggbb`, or `#rrggbbaa` (sRGB) to linear `Color` (`rune::color::hex`).
public func hex(_ s: String) -> Color? {
    guard s.hasPrefix("#") else { return nil }
    let n = s.dropFirst().count
    guard n == 3 || n == 6 || n == 8 else { return nil }
    return Color.hex(s)
}

/// Box shadow specification (drop or inset).
public struct Shadow: Sendable, Hashable, Codable {
    public var x: Float
    public var y: Float
    public var blur: Float
    public var spread: Float
    public var color: Color
    public var inset: Bool

    public init(
        x: Float = 0,
        y: Float = 2,
        blur: Float = 6,
        spread: Float = 0,
        color: Color = Color.black.alpha(0.18),
        inset: Bool = false
    ) {
        self.x = x
        self.y = y
        self.blur = max(0, blur)
        self.spread = spread
        self.color = color
        self.inset = inset
    }
}

/// Gradient fill specification.
public enum Gradient: Sendable, Hashable {
    case linear(top: Color, bottom: Color, angleRadians: Float = .pi * 0.5)
    case radial(inner: Color, outer: Color)
}

/// Neutral semantic design tokens matching `rune::tok`.
public struct ThemeTokens: Sendable, Equatable {
    public var dark: Bool
    public var bg: Color
    public var card: Color
    public var cardBorder: Color
    public var separator: Color
    public var text: Color
    public var textSecondary: Color
    public var controlTrack: Color
    public var controlOff: Color
    public var indicator: Color
    public var knob: Color
    public var knobShadow: Color
    public var hover: Color
    public var press: Color
    public var shadow: Color
    public var shadowSoft: Color
    public var edge: Color
}

public enum Tok {
    public enum Radius {
        public static let xs: Float = 4
        public static let sm: Float = 6
        public static let md: Float = 8
        public static let lg: Float = 12
        public static let xl: Float = 16
        public static let pill: Float = 9999
        public static let SM: Float = 6
        public static let MD: Float = 8
        public static let LG: Float = 12
    }

    public enum Space {
        public static let xs: Float = 4
        public static let sm: Float = 8
        public static let md: Float = 12
        public static let lg: Float = 16
        public static let xl: Float = 24
        public static let xxl: Float = 32
        public static let S1: Float = 4
        public static let S2: Float = 8
        public static let S3: Float = 12
        public static let S6: Float = 24
    }

    public enum Motion {
        public static let INSTANT = MotionTokens.INSTANT
        public static let SNAPPY = MotionTokens.SNAPPY
        public static let DEFAULT = MotionTokens.DEFAULT
        public static let CALM = MotionTokens.CALM
        public static let MORPH = MotionTokens.MORPH
        public static let POP = MotionTokens.POP
        /// The leading edge of something travelling (`tok::motion::LEAD`).
        public static let LEAD = Spring(duration: 0.2, bounce: 0.0)
    }

    public enum Typography {
        public static let body = TextStyle(size: 13.0, weight: 400.0)
        public static let label = TextStyle(size: 12.0, weight: 500.0)
        public static let section = TextStyle(size: 11.5, weight: 600.0)
        public static let title = TextStyle(size: 13.0, weight: 600.0)
        public static let monoCaption = TextStyle(size: 12.0, weight: 500.0)
    }

    /// Returns the neutral light or dark token set (`tok::theme(dark)`).
    public static func theme(dark: Bool) -> ThemeTokens {
        if dark {
            return ThemeTokens(
                dark: true,
                bg: oklch(0.185, 0.004, 265.0),
                card: oklch(0.232, 0.005, 265.0),
                cardBorder: oklcha(1.0, 0.0, 0.0, 0.05),
                separator: oklcha(1.0, 0.0, 0.0, 0.055),
                text: oklch(0.955, 0.003, 265.0),
                textSecondary: oklch(0.72, 0.008, 265.0),
                controlTrack: oklcha(1.0, 0.0, 0.0, 0.05),
                controlOff: oklcha(1.0, 0.0, 0.0, 0.085),
                indicator: oklch(0.43, 0.006, 265.0),
                knob: oklch(0.985, 0.0, 0.0),
                knobShadow: oklcha(0.0, 0.0, 0.0, 0.3),
                hover: oklcha(1.0, 0.0, 0.0, 0.016),
                press: oklcha(1.0, 0.0, 0.0, 0.03),
                shadow: oklcha(0.0, 0.0, 0.0, 0.42),
                shadowSoft: oklcha(0.0, 0.0, 0.0, 0.28),
                edge: oklcha(0.0, 0.0, 0.0, 0.3)
            )
        } else {
            return ThemeTokens(
                dark: false,
                bg: oklch(0.958, 0.004, 265.0),
                card: oklch(1.0, 0.0, 0.0),
                cardBorder: oklcha(0.0, 0.0, 0.0, 0.1),
                separator: oklcha(0.0, 0.0, 0.0, 0.13),
                text: oklch(0.225, 0.006, 265.0),
                textSecondary: oklch(0.5, 0.01, 265.0),
                controlTrack: oklcha(0.2, 0.01, 265.0, 0.13),
                controlOff: oklcha(0.2, 0.01, 265.0, 0.24),
                indicator: oklch(1.0, 0.0, 0.0),
                knob: oklch(1.0, 0.0, 0.0),
                knobShadow: oklcha(0.2, 0.02, 265.0, 0.3),
                hover: oklcha(0.2, 0.01, 265.0, 0.07),
                press: oklcha(0.2, 0.01, 265.0, 0.12),
                shadow: oklcha(0.2, 0.02, 265.0, 0.16),
                shadowSoft: oklcha(0.2, 0.02, 265.0, 0.07),
                edge: oklcha(0.2, 0.02, 265.0, 0.2)
            )
        }
    }

    /// Names for the six curated accents (`tok::ACCENT_NAMES`).
    public static let accentNames: [String] = ["blue", "purple", "pink", "orange", "green", "graphite"]

    /// Six curated OKLCH accents (`0..<6`: blue, purple, pink, orange, green, graphite; `tok::accent`).
    public static func accent(_ index: Int, dark: Bool) -> Color {
        let l: Float = dark ? 0.66 : 0.6
        let idx = ((index % 6) + 6) % 6
        switch idx {
        case 0: return oklch(l, 0.17, 256.0)
        case 1: return oklch(l, 0.18, 300.0)
        case 2: return oklch(l + 0.02, 0.19, 357.0)
        case 3: return oklch(l + 0.08, 0.16, 58.0)
        case 4: return oklch(l + 0.04, 0.16, 152.0)
        default: return oklch(l - 0.02, 0.012, 265.0)
        }
    }

    /// Whether the active view/runtime blends in sRGB (`Theme.blendsSrgb()`).
    public static func blendsSrgb() -> Bool {
        Theme.blendsSrgb()
    }

    /// Runs `body` under the given `srgbBlend` mode (`Theme.withBlend`).
    public static func withBlend<R>(_ srgbBlend: Bool, _ body: () throws -> R) rethrows -> R {
        try Theme.withBlend(srgbBlend, body)
    }

    /// Adapts `color` over `bg` for the current `Theme.blendsSrgb()` mode.
    public static func forBlend(_ color: Color, over bg: Color) -> Color {
        Theme.forBlend(color, over: bg)
    }

    /// Adapts a low-alpha sRGB-authored color for linear-light blending over `bg`.
    public static func forBlend(_ color: Color, over bg: Color, srgbBlend: Bool) -> Color {
        srgbBlend ? color : color.srgbEquivalent(over: bg)
    }
}

/// JSON theme loader supporting upstream `"palette"` + `"light"`/`"dark"` + `"blend"` + `"numbers"`
/// as well as `"defs"` + `"theme"` `{ "dark": ..., "light": ... }` maps (`rune::theme::Theme`).
public struct JsonTheme: Sendable, Equatable {
    public var name: String
    public var dark: Bool
    public var colors: [String: Color]
    public var numbers: [String: Float]
    public var blendBg: Color?

    public init(
        name: String = "custom",
        dark: Bool = true,
        colors: [String: Color] = [:],
        numbers: [String: Float] = [:],
        blendBg: Color? = nil
    ) {
        self.name = name
        self.dark = dark
        self.colors = colors
        self.numbers = numbers
        self.blendBg = blendBg
    }

    public subscript(_ key: String) -> Color? {
        tryColor(key)
    }

    public func num(_ key: String) -> Float? {
        numbers[key]
    }

    public static func fromJSON(_ json: String, dark: Bool) throws -> JsonTheme {
        try parse(data: Data(json.utf8), dark: dark)
    }

    public static func parse(data: Data, dark: Bool) throws -> JsonTheme {
        try JsonThemeParser.parse(data: data, dark: dark)
    }
}
