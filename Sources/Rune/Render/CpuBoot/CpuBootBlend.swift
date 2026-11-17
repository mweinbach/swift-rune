import Foundation
#if canImport(simd)
import simd
#endif

/// Premultiplied BGRA8 blending matching `Bgra8Unorm` GPU quantization (`cpu_boot/blend.rs`).
public enum CpuBootBlend {
    /// Adding and subtracting `2^23 * 1.5` rounds IEEE-754 f32 to nearest integer, ties to even.
    private static let magic: Float = 12_582_912.0

    @inline(__always)
    public static func quantize(_ x: Float) -> UInt8 {
        let clamped = min(max(x, 0.0), 255.0)
        return UInt8(((clamped + magic) - magic))
    }

    @inline(__always)
    public static func quantizeColor(_ c: SIMD4<Float>) -> (UInt8, UInt8, UInt8, UInt8) {
        (
            quantize(c.z * 255.0),
            quantize(c.y * 255.0),
            quantize(c.x * 255.0),
            quantize(c.w * 255.0)
        )
    }

    public struct PreSrc: Sendable {
        public let c255: SIMD4<Float>
        public let invA: Float
        public let opaque: (UInt8, UInt8, UInt8, UInt8)?

        @inline(__always)
        public init(_ c: SIMD4<Float>) {
            let bgra = CpuBootBlend.quantizeColor(c)
            self.c255 = SIMD4<Float>(Float(bgra.0), Float(bgra.1), Float(bgra.2), Float(bgra.3))
            self.invA = 1 - c255.w / 255
            self.opaque = bgra.3 == 255 ? bgra : nil
        }
    }

    @inline(__always)
    public static func overRGBA(_ pixels: UnsafeMutablePointer<UInt8>, at offset: Int, c: SIMD4<Float>) {
        overRow(pixels, offset: offset, count: 1, src: PreSrc(c))
    }

    @inline(__always)
    public static func overLCD(_ pixels: UnsafeMutablePointer<UInt8>, at offset: Int, c: SIMD4<Float>, k: SIMD3<Float>) {
        let src = PreSrc(c)
        let keepR = 1 - Float(quantize(k.x * 255)) / 255
        let keepG = 1 - Float(quantize(k.y * 255)) / 255
        let keepB = 1 - Float(quantize(k.z * 255)) / 255
        pixels[offset] = quantize(src.c255.x + Float(pixels[offset]) * keepB)
        pixels[offset + 1] = quantize(src.c255.y + Float(pixels[offset + 1]) * keepG)
        pixels[offset + 2] = quantize(src.c255.z + Float(pixels[offset + 2]) * keepR)
        pixels[offset + 3] = quantize(src.c255.w + Float(pixels[offset + 3]) * src.invA)
    }

    @inline(__always)
    public static func fillRow(_ pixels: UnsafeMutablePointer<UInt8>, offset: Int, count: Int, bgra: (UInt8, UInt8, UInt8, UInt8)) {
        var i = 0
        var p = offset
        while i < count {
            pixels[p + 0] = bgra.0
            pixels[p + 1] = bgra.1
            pixels[p + 2] = bgra.2
            pixels[p + 3] = bgra.3
            p += 4
            i += 1
        }
    }

    @inline(__always)
    public static func overRow(_ pixels: UnsafeMutablePointer<UInt8>, offset: Int, count: Int, src: PreSrc) {
        if let op = src.opaque {
            fillRow(pixels, offset: offset, count: count, bgra: op)
            return
        }
        if src.c255 == .zero { return }
        let inv = src.invA
        let s0 = src.c255.x
        let s1 = src.c255.y
        let s2 = src.c255.z
        let s3 = src.c255.w
        var i = 0
        var p = offset
        while i < count {
            pixels[p + 0] = quantize(s0 + Float(pixels[p + 0]) * inv)
            pixels[p + 1] = quantize(s1 + Float(pixels[p + 1]) * inv)
            pixels[p + 2] = quantize(s2 + Float(pixels[p + 2]) * inv)
            pixels[p + 3] = quantize(s3 + Float(pixels[p + 3]) * inv)
            p += 4
            i += 1
        }
    }

    @inline(__always)
    public static func compositeRowBy(
        _ dst: UnsafeMutablePointer<UInt8>,
        offset: Int,
        src: UnsafePointer<SIMD4<Float>>,
        count: Int,
        opacity: Float
    ) {
        var i = 0
        var p = offset
        while i < count {
            let c = src[i] * opacity
            if c.w > 0 || c.x > 0 || c.y > 0 || c.z > 0 {
                overRGBA(dst, at: p, c: c)
            }
            p += 4
            i += 1
        }
    }
}
