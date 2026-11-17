import Foundation
import Testing
@testable import Rune

#if canImport(CoreVideo) && canImport(IOSurface) && canImport(Metal)
import CoreVideo
#endif

@Suite("Native surface plane sampling")
struct SurfacePlaneSamplerTests {
    private func frame(_ bytes: ByteFrame) -> NativeSurfaceVideoFrame {
        NativeSurfaceVideoFrame(id: 0, size: (bytes.width, bytes.height), format: bytes.format,
                                color: bytes.color, orient: .up, source: .bytes(bytes))
    }

    private func expectColor(_ actual: SIMD4<Float>, _ expected: SIMD4<Float>) {
        for channel in 0..<4 {
            #expect(abs(actual[channel] - expected[channel]) < 0.00001)
        }
    }

    @Test("RGBA interpolation precedes transfer conversion and premultiplication")
    func translucentBilinearRGBA() throws {
        let bytes = try ByteFrame(width: 2, height: 1, format: .rgba, color: .srgb,
                                  planes: [Data([0, 0, 0, 255, 255, 0, 0, 0])])
        let pixel = SIMD2<Float>(1, 0.5)
        let size = SIMD2<Float>(2, 1)
        let linear = try SurfacePlaneSampler(frame: frame(bytes), srgbBlend: false)
        let encoded = try SurfacePlaneSampler(frame: frame(bytes), srgbBlend: true)
        // Between the texels both encoded red and alpha are 0.5.
        expectColor(linear.sample(bufferPixel: pixel, displaySize: size, exact: false),
                    SIMD4(0.10702057, 0, 0, 0.5))
        expectColor(encoded.sample(bufferPixel: pixel, displaySize: size, exact: false),
                    SIMD4(0.25, 0, 0, 0.5))
    }

    @Test("Minification averages converted taps and caps each axis at eight")
    func adaptiveMinification() throws {
        var rgba = Data()
        for y in 0..<4 {
            for x in 0..<16 {
                rgba.append(contentsOf: [x.isMultiple(of: 2) ? 0 : 255, x == 0 && y == 0 ? 255 : 0, 0, 255])
            }
        }
        let bytes = try ByteFrame(width: 16, height: 4, format: .rgba, color: .srgb, planes: [rgba])
        let sampler = try SurfacePlaneSampler(frame: frame(bytes), srgbBlend: false)
        // Each horizontal tap sits between a black and a red texel. One of the 32 taps
        // also sees half the green texel in the upper-left corner.
        expectColor(sampler.sample(bufferPixel: SIMD2(0.5, 0.5), displaySize: SIMD2(1, 1), exact: false),
                    SIMD4(0.21404114, 0.006688786, 0, 1))
    }

    @Test("Exact NV12 reads subsampled chroma from sliced planes and applies the declared color space")
    func nv12MatrixRangeAndTransfer() throws {
        let luma = Data([99, 16, 16, 16, 16, 16, 16, 16, 110]).dropFirst()
        let chroma = Data([5, 9, 128, 128, 100, 162]).dropFirst(2)
        let cases: [(SurfacePixelFormat, SurfaceColorInfo, SIMD4<Float>)] = [
            (.nv12Video, .bt601, SIMD4(0.41652083, 0.14635843, 0.05865873, 1)),
            (.nv12Full, SurfaceColorInfo(matrix: .bt709, transfer: .linear),
             SIMD4(0.64134588, 0.38952493, 0.22762039, 1))
        ]
        for (format, color, expected) in cases {
            let bytes = try ByteFrame(width: 4, height: 2, format: format, color: color, planes: [luma, chroma])
            let sampler = try SurfacePlaneSampler(frame: frame(bytes), srgbBlend: false)
            expectColor(sampler.sample(bufferPixel: SIMD2(3.5, 1.5), displaySize: SIMD2(4, 2), exact: true), expected)
        }
    }

    @Test("Scaled NV12 interpolates chroma at chroma resolution and preserves fractional values")
    func bilinearNV12() throws {
        let luma = Data([20, 40, 140, 200, 20, 40, 140, 200])
        let chroma = Data([82, 190, 158, 55])
        let color = SurfaceColorInfo(matrix: .bt709, transfer: .linear)
        let bytes = try ByteFrame(width: 4, height: 2, format: .nv12Video, color: color, planes: [luma, chroma])
        let sampler = try SurfacePlaneSampler(frame: frame(bytes), srgbBlend: false)
        // u = 0.5 yields Y = 90, Cb = 120 and Cr = 122.5 across the two chroma texels.
        expectColor(sampler.sample(bufferPixel: SIMD2(4, 1), displaySize: SIMD2(8, 4), exact: false),
                    SIMD4(0.29923258, 0.35608380, 0.27162811, 1))
    }

    #if canImport(CoreVideo) && canImport(IOSurface) && canImport(Metal)
    @Test("CoreVideo snapshots preserve pixels across source reuse and padded BGRA rows")
    func immutableCoreVideoSnapshot() throws {
        let pixels = Data([0, 0, 255, 255, 255, 0, 0, 255])
        let bytes = try ByteFrame(width: 1, height: 2, format: .bgra, color: .srgb, planes: [pixels])
        let source = try CoreVideoPixelBuffer.fromBytes(bytes)
        let buffer = source.cvBuffer
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        try #require(stride > 4)
        let frame = NativeSurfaceVideoFrame(id: 0, size: source.size, format: .bgra,
                                            color: .srgb, orient: .up, source: .pixelBuffer(source))
        let snapshot = try SurfacePlaneSampler(frame: frame, srgbBlend: false)
        do {
            try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            for row in 0..<2 {
                base.advanced(by: row * stride).initializeMemory(as: UInt8.self, repeating: 0, count: 4)
            }
        }
        let size = SIMD2<Float>(1, 2)
        expectColor(snapshot.sample(bufferPixel: SIMD2(0.5, 0.5), displaySize: size, exact: true), SIMD4(1, 0, 0, 1))
        expectColor(snapshot.sample(bufferPixel: SIMD2(0.5, 1.5), displaySize: size, exact: true), SIMD4(0, 0, 1, 1))
        let updated = try SurfacePlaneSampler(frame: frame, srgbBlend: false)
        expectColor(updated.sample(bufferPixel: SIMD2(0.5, 1.5), displaySize: size, exact: true), .zero)
    }
    #endif
}
