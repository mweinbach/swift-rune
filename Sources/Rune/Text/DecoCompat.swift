import Foundation
#if canImport(simd)
import simd
#endif

/// Corner radius in points for rounded inline span backgrounds (`rune::text::SPAN_RADIUS`).
public let SPAN_RADIUS: Float = TextDecorations.spanRadius

/// Underline, strikethrough, or background rectangle produced during text shaping (`rune::text::Deco`).
public struct Deco: Sendable, Equatable {
    public var rect: SIMD4<Float>
    public var color: Color
    public var radius: Float

    public init(rect: SIMD4<Float>, color: Color, radius: Float = 0) {
        self.rect = rect
        self.color = color
        self.radius = radius
    }

    public init(rect: [Float], color: Color, radius: Float = 0) {
        let r0 = rect.count > 0 ? rect[0] : 0
        let r1 = rect.count > 1 ? rect[1] : 0
        let r2 = rect.count > 2 ? rect[2] : 0
        let r3 = rect.count > 3 ? rect[3] : 0
        self.rect = SIMD4<Float>(r0, r1, r2, r3)
        self.color = color
        self.radius = radius
    }
}
