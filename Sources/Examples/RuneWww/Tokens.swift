import Foundation
import Rune

/// Page design tokens matching `www/app/src/tokens.rs`: black ground, neutral foreground at
/// four strengths, translucent white hairlines, and Rune's blue ink accent.
public enum WwwTokens {
    public static let bg: Color = .black
    public static let fg: Color = Color.hex("#ededed") ?? .white
    public static let fg2: Color = Color.white.alpha(0.62)
    public static let fg3: Color = Color.white.alpha(0.5)
    public static let surface1: Color = Color.white.alpha(0.03)
    public static let surface2: Color = Color.white.alpha(0.06)
    public static let surface3: Color = Color.white.alpha(0.1)
    public static let line: Color = Color.white.alpha(0.09)
    public static let line2: Color = Color.white.alpha(0.16)
    public static let ink: Color = oklch(0.74, 0.14, 245.0)
    public static let glint: Color = oklch(0.97, 0.035, 245.0)
    public static let codeKeyword: Color = oklch(0.74, 0.12, 25.0)
    public static let codeString: Color = oklch(0.84, 0.06, 80.0)
    public static let codeCall: Color = oklch(0.84, 0.045, 235.0)

    public static let r2: Float = 8.0
    public static let contentWidth: Float = 1120.0
    public static let measureWidth: Float = 576.0
    public static let topbarHeight: Float = 52.0

    public static let text12Medium = TextStyle(size: 12.0, weight: 500.0).lh(16.0)
    public static let text13 = TextStyle(size: 13.0, weight: 400.0).lh(20.0)
    public static let text14 = TextStyle(size: 14.0, weight: 400.0).lh(22.0)
    public static let text14Medium = TextStyle(size: 14.0, weight: 500.0).lh(22.0)
    public static let text16 = TextStyle(size: 16.0, weight: 400.0).lh(26.0)
    public static let text16Medium = TextStyle(size: 16.0, weight: 500.0).lh(26.0)
    public static let mono12 = TextStyle(size: 12.0, weight: 400.0).lh(16.0).mono()
    public static let mono13 = TextStyle(size: 13.0, weight: 400.0).lh(20.0).mono()
    public static let code = TextStyle(size: 12.0, weight: 400.0).lh(20.0).mono()
}

/// Responsive width breakpoints (`www/app/src/tokens.rs`).
public struct WwwBreakpoint: Equatable, Hashable, Sendable {
    public static let steps: [UInt16] = [0, 400, 560, 760, 860, 1000]
    public var at: UInt16

    public init(at: UInt16) {
        self.at = at
    }

    public static func of(_ width: Float) -> WwwBreakpoint {
        let chosen = steps.reversed().first { width >= Float($0) } ?? 0
        return WwwBreakpoint(at: chosen)
    }

    public var narrow: Bool { at < 400 }
    public var phone: Bool { at < 560 }
    public var stackGallery: Bool { at < 760 }
    public var stackSplit: Bool { at < 860 }
    public var stackHero: Bool { at < 1000 }

    public var gutter: Float { narrow ? 16.0 : 24.0 }

    public var h1: TextStyle {
        phone
            ? TextStyle(size: 36.0, weight: 500.0).lh(44.0).letterSpacing(-0.9)
            : TextStyle(size: 40.0, weight: 500.0).lh(48.0).letterSpacing(-1.0)
    }

    public var h2: TextStyle {
        phone
            ? TextStyle(size: 24.0, weight: 500.0).lh(32.0).letterSpacing(-0.48)
            : TextStyle(size: 28.0, weight: 500.0).lh(36.0).letterSpacing(-0.56)
    }

    public var lede: TextStyle {
        phone ? WwwTokens.text16 : TextStyle(size: 18.0, weight: 400.0).lh(28.0)
    }
}
