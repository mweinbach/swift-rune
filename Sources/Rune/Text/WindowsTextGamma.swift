import RuneRef

#if os(Windows)
// The native run serializes access to its DirectWrite analysis. Defer its RGB
// texture read until a device can actually draw subpixel coverage.
final class WindowsGlyphMask: @unchecked Sendable {
    let bounds: SIMD4<Int32>
    let rect: SIMD4<Int>
    let phase: SIMD2<Int>
    let columns: Range<Int>?
    let rgb: (() -> [UInt8]?)?
    init(bounds: SIMD4<Int32>, rect: SIMD4<Int>, phase: SIMD2<Int>, columns: Range<Int>?, rgb: (() -> [UInt8]?)?) {
        self.bounds = bounds
        self.rect = rect
        self.phase = phase
        self.columns = columns
        self.rgb = rgb
    }
}
#endif

/// Skia's Windows grayscale mask correction (sRGB device gamma, contrast 1).
enum WindowsTextGamma {
    static func bucket(_ ink: SIMD4<Float>, encoded: Bool) -> UInt8 {
        func byte(_ value: Float) -> Int {
            let v = min(1, max(0, value))
            return Int(((encoded ? v : RefShader.linearToSRGB(v)) * 255).rounded())
        }
        return UInt8((54 * byte(ink.x) + 183 * byte(ink.y) + 19 * byte(ink.z)) >> 13)
    }

    static let tables: [[UInt8]] = (0..<8).map { bucket in
        let base = bucket << 5
        let src = Float(base | base >> 3 | base >> 6) / 255
        let dst = 1 - src
        let linSrc = RefShader.srgbToLinear(src), linDst = RefShader.srgbToLinear(dst)
        return (0..<256).map { i in
            let raw = Float(i) / 255
            let a = raw + (1 - raw) * linDst * raw
            let out = RefShader.linearToSRGB(linSrc * a + (1 - a) * linDst)
            let v = abs(src - dst) < 1 / 256 ? a : (out - dst) / (src - dst)
            return UInt8(clamping: Int((255 * v + 0.5).rounded(.down)))
        }
    }
}
