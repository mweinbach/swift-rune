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

        public init(_ c: SIMD4<Float>) {
            let clamped = SIMD4<Float>(
                min(max(c.x, 0.0), 1.0),
                min(max(c.y, 0.0), 1.0),
                min(max(c.z, 0.0), 1.0),
                min(max(c.w, 0.0), 1.0)
            )
            self.c255 = SIMD4<Float>(clamped.z, clamped.y, clamped.x, clamped.w) * 255.0
            self.invA = 1.0 - clamped.w
            if clamped.w >= 1.0 {
                self.opaque = (
                    CpuBootBlend.quantize(self.c255.x),
                    CpuBootBlend.quantize(self.c255.y),
                    CpuBootBlend.quantize(self.c255.z),
                    255
                )
            } else {
                self.opaque = nil
            }
        }
    }

    @inline(__always)
    public static func overRGBA(_ pixels: UnsafeMutablePointer<UInt8>, at offset: Int, c: SIMD4<Float>) {
        if c.w <= 0 && c.x <= 0 && c.y <= 0 && c.z <= 0 { return }
        if c.w >= 1.0 {
            pixels[offset + 0] = quantize(min(max(c.z, 0), 1) * 255.0)
            pixels[offset + 1] = quantize(min(max(c.y, 0), 1) * 255.0)
            pixels[offset + 2] = quantize(min(max(c.x, 0), 1) * 255.0)
            pixels[offset + 3] = 255
            return
        }
        let inv = 1.0 - min(max(c.w, 0), 1)
        let b = c.z * 255.0 + Float(pixels[offset + 0]) * inv
        let g = c.y * 255.0 + Float(pixels[offset + 1]) * inv
        let r = c.x * 255.0 + Float(pixels[offset + 2]) * inv
        let a = c.w * 255.0 + Float(pixels[offset + 3]) * inv
        pixels[offset + 0] = quantize(b)
        pixels[offset + 1] = quantize(g)
        pixels[offset + 2] = quantize(r)
        pixels[offset + 3] = quantize(a)
    }

    @inline(__always)
    public static func overLCD(_ pixels: UnsafeMutablePointer<UInt8>, at offset: Int, c: SIMD4<Float>, k: SIMD3<Float>) {
        let r = c.x * 255.0 + Float(pixels[offset + 2]) * (1.0 - k.x)
        let g = c.y * 255.0 + Float(pixels[offset + 1]) * (1.0 - k.y)
        let b = c.z * 255.0 + Float(pixels[offset + 0]) * (1.0 - k.z)
        let a = c.w * 255.0 + Float(pixels[offset + 3]) * (1.0 - c.w)
        pixels[offset + 0] = quantize(b)
        pixels[offset + 1] = quantize(g)
        pixels[offset + 2] = quantize(r)
        pixels[offset + 3] = quantize(a)
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
