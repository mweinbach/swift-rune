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

    /// Perceptual OKLab interpolation from `self` toward `other` by `t in [0, 1]`.
    public func mix(with other: Color, t: Float) -> Color {
        let f = t.clamped(to: 0...1)
        let aLanes = toLanes()
        let bLanes = other.toLanes()
        var out = MotionLanes()
        for i in 0..<4 {
            out[i] = aLanes[i] + (bLanes[i] - aLanes[i]) * f
        }
        return Color.fromLanes(out)
    }

    /// Solves for a straight-alpha linear-light color whose linear-light composite over `bg`
    /// reproduces CSS / browser gamma-space sRGB blending of `self` over `bg`!
    public func srgbEquivalent(over bg: Color) -> Color {
        if a <= 0.0001 || a >= 0.9999 { return self }
        let sa = a.clamped(to: 0...1)
        let fgSRGB = SIMD3<Float>(RefShader.linearToSRGB(r), RefShader.linearToSRGB(g), RefShader.linearToSRGB(b))
        let bgSRGB = SIMD3<Float>(RefShader.linearToSRGB(bg.r), RefShader.linearToSRGB(bg.g), RefShader.linearToSRGB(bg.b))
        let targetSRGB = fgSRGB * sa + bgSRGB * (1.0 - sa)
        let targetLin = SIMD3<Float>(
            RefShader.srgbToLinear(targetSRGB.x),
            RefShader.srgbToLinear(targetSRGB.y),
            RefShader.srgbToLinear(targetSRGB.z)
        )
        let bgLin = SIMD3<Float>(bg.r, bg.g, bg.b)
        let fgLin = SIMD3<Float>(r, g, b)
        let delta = fgLin - bgLin
        let denom = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
        if denom < 1e-6 {
            return self
        }
        let diff = targetLin - bgLin
        let solvedA = (diff.x * delta.x + diff.y * delta.y + diff.z * delta.z) / denom
        let clampedA = solvedA.clamped(to: 0.001...1.0)
        let rawRGB = (targetLin - bgLin * (1.0 - clampedA)) / clampedA
        let solvedRGB = SIMD3<Float>(
            rawRGB.x.clamped(to: 0...1),
            rawRGB.y.clamped(to: 0...1),
            rawRGB.z.clamped(to: 0...1)
        )
        return Color(r: solvedRGB.x, g: solvedRGB.y, b: solvedRGB.z, a: clampedA)
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

/// Top-level convenience matching `rune::oklch` and `rune::oklcha`.
@inlinable
public func oklch(_ l: Float, _ c: Float, _ hueDegrees: Float) -> Color {
    Color.oklch(l, c, hueDegrees)
}

@inlinable
public func oklcha(_ l: Float, _ c: Float, _ hueDegrees: Float, _ alpha: Float) -> Color {
    Color.oklcha(l, c, hueDegrees, alpha)
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
    }

    public enum Space {
        public static let xs: Float = 4
        public static let sm: Float = 8
        public static let md: Float = 12
        public static let lg: Float = 16
        public static let xl: Float = 24
        public static let xxl: Float = 32
    }

    public enum Motion {
        public static let INSTANT = MotionTokens.INSTANT
        public static let SNAPPY = MotionTokens.SNAPPY
        public static let DEFAULT = MotionTokens.DEFAULT
        public static let CALM = MotionTokens.CALM
        public static let MORPH = MotionTokens.MORPH
        public static let POP = MotionTokens.POP
    }

    public enum Typography {
        public static let body = TextStyle(size: 13.0, weight: 400.0)
        public static let label = TextStyle(size: 12.0, weight: 500.0)
        public static let section = TextStyle(size: 11.5, weight: 600.0)
        public static let title = TextStyle(size: 13.0, weight: 600.0)
        public static let monoCaption = TextStyle(size: 12.0, weight: 500.0).mono()
    }

    /// Returns the neutral light or dark token set (`tok::theme(dark)`).
    public static func theme(dark: Bool) -> ThemeTokens {
        if dark {
            return ThemeTokens(
                dark: true,
                bg: oklch(0.17, 0.005, 260),
                card: oklch(0.22, 0.006, 260),
                cardBorder: Color.white.alpha(0.10),
                separator: Color.white.alpha(0.08),
                text: oklch(0.94, 0.004, 260),
                textSecondary: oklch(0.68, 0.008, 260),
                controlTrack: oklch(0.27, 0.007, 260),
                controlOff: oklch(0.32, 0.008, 260),
                indicator: oklch(0.36, 0.010, 260),
                knob: oklch(0.97, 0.002, 260),
                knobShadow: Color.black.alpha(0.38),
                hover: Color.white.alpha(0.06),
                press: Color.white.alpha(0.11),
                shadow: Color.black.alpha(0.34),
                shadowSoft: Color.black.alpha(0.22),
                edge: Color.white.alpha(0.07)
            )
        } else {
            return ThemeTokens(
                dark: false,
                bg: oklch(0.965, 0.003, 260),
                card: Color.white,
                cardBorder: Color.black.alpha(0.09),
                separator: Color.black.alpha(0.07),
                text: oklch(0.20, 0.006, 260),
                textSecondary: oklch(0.50, 0.008, 260),
                controlTrack: oklch(0.91, 0.004, 260),
                controlOff: oklch(0.86, 0.005, 260),
                indicator: oklch(0.82, 0.006, 260),
                knob: Color.white,
                knobShadow: Color.black.alpha(0.20),
                hover: Color.black.alpha(0.045),
                press: Color.black.alpha(0.085),
                shadow: Color.black.alpha(0.12),
                shadowSoft: Color.black.alpha(0.07),
                edge: Color.black.alpha(0.06)
            )
        }
    }

    /// Six curated OKLCH accents (`0..<6`: blue, purple, pink, red, orange, green).
    public static func accent(_ index: Int, dark: Bool) -> Color {
        let hues: [Float] = [258, 300, 345, 25, 58, 148]
        let chromas: [Float] = [0.18, 0.18, 0.19, 0.20, 0.18, 0.17]
        let idx = ((index % hues.count) + hues.count) % hues.count
        let l: Float = dark ? 0.67 : 0.56
        return oklch(l, chromas[idx], hues[idx])
    }

    /// Adapts a low-alpha sRGB-authored color for linear-light blending over `bg`.
    public static func forBlend(_ color: Color, over bg: Color, srgbBlend: Bool = false) -> Color {
        srgbBlend ? color : color.srgbEquivalent(over: bg)
    }
}

/// JSON theme loader supporting `"defs"` references and `"theme"` `{ "dark": ..., "light": ... }` maps
/// (compatible with OpenCode / Rune JSON theme files).
public struct JsonTheme: Sendable, Equatable {
    public var name: String
    public var colors: [String: Color]
    public var numbers: [String: Float]

    public init(name: String = "custom", colors: [String: Color] = [:], numbers: [String: Float] = [:]) {
        self.name = name
        self.colors = colors
        self.numbers = numbers
    }

    public subscript(_ key: String) -> Color? {
        colors[key]
    }

    public func num(_ key: String) -> Float? {
        numbers[key]
    }

    public static func fromJSON(_ json: String, dark: Bool) throws -> JsonTheme {
        try parse(data: Data(json.utf8), dark: dark)
    }

    public static func parse(data: Data, dark: Bool) throws -> JsonTheme {
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = raw as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        let name = (root["name"] as? String) ?? "custom"
        let defs = (root["defs"] as? [String: String]) ?? [:]
        let themeDict = (root["theme"] as? [String: Any]) ?? root

        func resolve(_ value: Any?, depth: Int = 0) -> Color? {
            guard depth < 8 else { return nil }
            if let str = value as? String {
                if let hexColor = Color.hex(str) {
                    return hexColor
                }
                let refKey = str.hasPrefix("$") ? String(str.dropFirst()) : str
                if let defVal = defs[refKey] {
                    return resolve(defVal, depth: depth + 1)
                }
                if let sibling = themeDict[refKey] {
                    return resolve(sibling, depth: depth + 1)
                }
                return nil
            } else if let variants = value as? [String: Any] {
                let picked = dark ? (variants["dark"] ?? variants["light"]) : (variants["light"] ?? variants["dark"])
                return resolve(picked, depth: depth + 1)
            }
            return nil
        }

        var resolved: [String: Color] = [:]
        var resolvedNums: [String: Float] = [:]
        for (k, v) in themeDict {
            if k == "defs" || k == "$schema" || k == "name" { continue }
            if let n = v as? NSNumber, !(v is Bool) {
                resolvedNums[k] = n.floatValue
            } else if let c = resolve(v) {
                resolved[k] = c
            }
        }
        return JsonTheme(name: name, colors: resolved, numbers: resolvedNums)
    }
}
