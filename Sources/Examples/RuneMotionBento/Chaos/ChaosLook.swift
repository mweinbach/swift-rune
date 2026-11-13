import Foundation

/// An OKLCH colour with alpha.
public struct Lch: Equatable, Sendable {
    public var l: Float
    public var c: Float
    public var h: Float
    public var a: Float

    public init(l: Float, c: Float, h: Float, a: Float = 1.0) {
        self.l = l
        self.c = c
        self.h = h
        self.a = a
    }

    public func alpha(_ a: Float) -> Lch {
        Lch(l: l, c: c, h: h, a: a)
    }

    /// OKLab (L, a, b): the space both builds interpolate colour in.
    public func lab() -> (Float, Float, Float) {
        let rad = h * .pi / 180.0
        return (l, c * cosf(rad), c * sinf(rad))
    }

    /// Gamma-encoded sRGB, clamped to the gamut, with alpha.
    public func srgb() -> (Float, Float, Float, Float) {
        let (r, g, b) = Self.labToLinear(lab())
        return (Self.encode(r), Self.encode(g), Self.encode(b), a)
    }

    public static func labToLinear(_ lab: (Float, Float, Float)) -> (Float, Float, Float) {
        let (l, a, b) = lab
        let l_ = l + 0.396_337_78 * a + 0.215_803_76 * b
        let m_ = l - 0.105_561_346 * a - 0.063_854_17 * b
        let s_ = l - 0.089_484_18 * a - 1.291_485_5 * b
        let l3 = l_ * l_ * l_
        let m3 = m_ * m_ * m_
        let s3 = s_ * s_ * s_
        return (
            4.076_741_7 * l3 - 3.307_711_6 * m3 + 0.230_969_94 * s3,
            -1.268_438 * l3 + 2.609_757_4 * m3 - 0.341_319_38 * s3,
            -0.004_196_086_3 * l3 - 0.703_418_6 * m3 + 1.707_614_7 * s3
        )
    }

    /// Linear to gamma-encoded sRGB, clamped to 0..1.
    public static func encode(_ x: Float) -> Float {
        let clamped = min(max(x, 0.0), 1.0)
        if clamped <= 0.003_130_8 {
            return 12.92 * clamped
        }
        return 1.055 * powf(clamped, 1.0 / 2.4) - 0.055
    }
}

public func lch(_ l: Float, _ c: Float, _ h: Float) -> Lch {
    Lch(l: l, c: c, h: h, a: 1.0)
}

public enum ChaosColor {
    public static let accentHue: Float = 245.0
    public static let bg = lch(0.155, 0.012, 260.0)
    public static let tile = lch(0.205, 0.014, 258.0)
    public static let tileFocus = lch(0.235, 0.022, 252.0)
    public static let edge = lch(1.0, 0.0, 0.0).alpha(0.07)
    public static let well = lch(0.255, 0.014, 258.0)
    public static let wellHi = lch(0.31, 0.016, 258.0)
    public static let text = lch(0.96, 0.005, 258.0)
    public static let text2 = lch(0.72, 0.012, 258.0)
    public static let text3 = lch(0.54, 0.014, 258.0)
    public static let accent = lch(0.66, 0.17, accentHue)
    public static let accentDim = lch(0.66, 0.17, accentHue).alpha(0.18)
    public static let onAccent = lch(0.99, 0.0, 0.0)
    public static let good = lch(0.74, 0.15, 155.0)
    public static let warm = lch(0.78, 0.14, 70.0)

    /// Each scene's mood: its swatch, and the glow it casts on the header.
    public static let scene: [Lch] = [
        lch(0.66, 0.17, accentHue),
        lch(0.74, 0.13, 175.0),
        lch(0.78, 0.14, 70.0),
        lch(0.6, 0.17, 295.0),
    ]
}

/// The window and the grid, in points.
public enum ChaosGrid {
    public static let width: Float = 1440.0
    public static let height: Float = 900.0
    public static let pad: Float = 28.0
    public static let gap: Float = 14.0
    public static let header: Float = 64.0
    public static let radius: Float = 18.0
    public static let tilePad: Float = 18.0
    /// Row heights below the header; the dock row takes what's left.
    public static let row1: Float = 236.0
    public static let row2: Float = 262.0
    /// The focused dock tile's share of the row against 1 for each other tile.
    public static let dockFocus: Float = 2.4
}

/// A spring as perceptual duration (seconds) and bounce, mass 1.
public struct ChaosSpring: Equatable, Sendable {
    public var duration: Float
    public var bounce: Float

    public init(duration: Float, bounce: Float) {
        self.duration = duration
        self.bounce = bounce
    }

    /// ω = 2π / duration.
    public func omega() -> Float {
        (2.0 * Float.pi) / duration
    }

    /// ζ = 1 − bounce (≥ 0), 1 / (1 + bounce) below.
    public func zeta() -> Float {
        if bounce >= 0.0 { 1.0 - bounce } else { 1.0 / (1.0 + bounce) }
    }

    /// k = ω².
    public func stiffness() -> Float {
        let w = omega()
        return w * w
    }

    /// c = 2ζω.
    public func damping() -> Float {
        2.0 * zeta() * omega()
    }
}

/// The springs each kind of motion uses.
public struct ChaosSprings: Equatable, Sendable {
    public var layout: ChaosSpring
    public var snap: ChaosSpring
    public var morph: ChaosSpring
    public var pop: ChaosSpring
    public var travel: ChaosSpring

    public static func variant(_ name: String) -> ChaosSprings {
        let base = ChaosSprings(
            layout: ChaosSpring(duration: 0.4, bounce: 0.0),
            snap: ChaosSpring(duration: 0.25, bounce: 0.0),
            morph: ChaosSpring(duration: 0.3, bounce: 0.16),
            pop: ChaosSpring(duration: 0.25, bounce: 0.15),
            travel: ChaosSpring(duration: 0.35, bounce: 0.12)
        )
        switch name {
        case "bouncy":
            return ChaosSprings(
                layout: ChaosSpring(duration: 0.5, bounce: 0.28),
                snap: ChaosSpring(duration: 0.3, bounce: 0.22),
                morph: ChaosSpring(duration: 0.45, bounce: 0.35),
                pop: ChaosSpring(duration: 0.35, bounce: 0.35),
                travel: ChaosSpring(duration: 0.5, bounce: 0.35)
            )
        case "stiff":
            return ChaosSprings(
                layout: ChaosSpring(duration: 0.22, bounce: 0.0),
                snap: ChaosSpring(duration: 0.15, bounce: 0.0),
                morph: ChaosSpring(duration: 0.18, bounce: 0.0),
                pop: ChaosSpring(duration: 0.15, bounce: 0.0),
                travel: ChaosSpring(duration: 0.2, bounce: 0.0)
            )
        default:
            return base
        }
    }
}
