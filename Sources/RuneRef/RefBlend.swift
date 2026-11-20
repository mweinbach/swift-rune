import Foundation

/// W3C separable blending modes for premultiplied RGBA values in the caller's working color space.
///
/// Mirrors upstream `rune-ref/src/blend.rs`.
public enum SeparableBlendMode: Sendable, Hashable, CaseIterable {
    case multiply
    case screen
    case overlay
    case softLight
}

/// Scalar W3C separable blending oracle.
public enum RefBlend {
    /// Composites premultiplied `src` over premultiplied `dst` using `mode`.
    /// Colors with RGB greater than alpha should be normalized by the caller first.
    @inlinable
    public static func composite(
        mode: SeparableBlendMode,
        src: SIMD4<Float>,
        dst: SIMD4<Float>
    ) -> SIMD4<Float> {
        let sa = src.w
        let da = dst.w
        var out = SIMD4<Float>.zero

        for c in 0..<3 {
            let s = sa > 0.0 ? src[c] / sa : 0.0
            let b = da > 0.0 ? dst[c] / da : 0.0
            let blended: Float
            switch mode {
            case .multiply:
                blended = b * s
            case .screen:
                blended = b + s - b * s
            case .overlay:
                if b <= 0.5 {
                    blended = 2.0 * b * s
                } else {
                    blended = 1.0 - 2.0 * (1.0 - b) * (1.0 - s)
                }
            case .softLight:
                if s <= 0.5 {
                    blended = b - (1.0 - 2.0 * s) * b * (1.0 - b)
                } else {
                    let d: Float
                    if b <= 0.25 {
                        d = ((16.0 * b - 12.0) * b + 4.0) * b
                    } else {
                        d = sqrtf(max(b, 0.0))
                    }
                    blended = b + (2.0 * s - 1.0) * (d - b)
                }
            }
            out[c] = src[c] * (1.0 - da) + sa * da * blended + dst[c] * (1.0 - sa)
        }
        out.w = sa + da * (1.0 - sa)
        return out
    }
}
