import Foundation
#if canImport(CoreVideo) && canImport(IOSurface) && canImport(Metal)
import CoreVideo
#endif

extension NativeSurfaceVideoFrame {
    /// Returns immutable, tightly packed source planes in their original encoding.
    internal func bytePlanes() throws -> [Data] {
        switch source {
        case .bytes(let bytes):
            guard size == (bytes.width, bytes.height), format == bytes.format else {
                throw NativeSurfaceError.importFailed("byte surface size or format differs from its frame")
            }
            return bytes.planes
        #if os(Windows)
        case .shared(let frame):
            guard size == (frame.texture.width, frame.texture.height), format == .bgra else {
                throw NativeSurfaceError.importFailed("shared surface size or format differs from its frame")
            }
            return [try frame.bytes()]
        #if canImport(CRuneMedia)
        case .decoded(let picture):
            guard size == (picture.width, picture.height), format == picture.format else {
                throw NativeSurfaceError.importFailed("decoded surface size or format differs from its frame")
            }
            return try picture.bytePlanes()
        #endif
        #endif
        #if canImport(CoreVideo) && canImport(IOSurface) && canImport(Metal)
        case .pixelBuffer(let source):
            let buffer = source.cvBuffer
            let planar = format == .nv12Video || format == .nv12Full
            guard size == source.size, format == (try source.surfaceFormat()),
                  CVPixelBufferGetPlaneCount(buffer) == (planar ? 2 : 0) else {
                throw NativeSurfaceError.importFailed("CoreVideo surface size or format differs from its frame")
            }
            if planar && (size.0 % 2 != 0 || size.1 % 2 != 0) {
                throw NativeSurfaceError.oddNv12Dimensions(width: size.0, height: size.1)
            }
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
                throw NativeSurfaceError.importFailed("CoreVideo surface could not be mapped")
            }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            return try (0..<(planar ? 2 : 1)).map { index in
                let ptr = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, index) : CVPixelBufferGetBaseAddress(buffer)
                guard let ptr else { throw NativeSurfaceError.importFailed("CoreVideo surface plane is unavailable") }
                let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, index) : CVPixelBufferGetBytesPerRow(buffer)
                let rowBytes = Int(size.0) * (planar ? 1 : 4)
                let height = Int(size.1) / (index == 0 ? 1 : 2)
                let rows = planar ? CVPixelBufferGetHeightOfPlane(buffer, index) : CVPixelBufferGetHeight(buffer)
                guard rowBytes <= stride, height <= rows else {
                    throw NativeSurfaceError.importFailed("undersized CoreVideo surface plane")
                }
                if rowBytes == stride { return Data(bytes: ptr, count: rowBytes * height) }
                var result = Data(count: rowBytes * height)
                result.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                    for row in 0..<height {
                        dst.baseAddress!.advanced(by: row * rowBytes).copyMemory(from: ptr.advanced(by: row * stride), byteCount: rowBytes)
                    }
                }
                return result
            }
        #endif
        }
    }
}

/// Samples the original planes with the same texel centers and transfer order as surface.frag.
internal struct SurfacePlaneSampler: Sendable {
    private struct Plane: Sendable {
        let data: Data
        let width: Int
        let height: Int
        let channels: Int

        func texel(x: Int, y: Int) -> SIMD4<Float> {
            let index = data.startIndex + (y * width + x) * channels
            let r = Float(data[index])
            if channels == 1 { return SIMD4(r, 0, 0, 255) }
            let g = Float(data[index + 1])
            if channels == 2 { return SIMD4(r, g, 0, 255) }
            return SIMD4(r, g, Float(data[index + 2]), Float(data[index + 3]))
        }

        func bilinear(_ uv: SIMD2<Float>) -> SIMD4<Float> {
            let fx = min(max(uv.x * Float(width) - 0.5, 0), Float(width - 1))
            let fy = min(max(uv.y * Float(height) - 0.5, 0), Float(height - 1))
            let x = Int(fx), y = Int(fy)
            let nextX = min(x + 1, width - 1), nextY = min(y + 1, height - 1)
            let tx = fx - Float(x), ty = fy - Float(y)
            let a = texel(x: x, y: y), b = texel(x: x, y: nextY)
            let top = a + (texel(x: nextX, y: y) - a) * tx
            let bottom = b + (texel(x: nextX, y: nextY) - b) * tx
            return top + (bottom - top) * ty
        }
    }

    private let first: Plane
    private let chroma: Plane?
    private let format: SurfacePixelFormat
    private let matrix: SurfaceMatrix
    private let transfer: SurfaceTransfer

    init(frame: NativeSurfaceVideoFrame, srgbBlend: Bool) throws {
        let planes = try frame.bytePlanes()
        let width = Int(frame.size.0), height = Int(frame.size.1)
        let planar = frame.format == .nv12Video || frame.format == .nv12Full
        first = Plane(data: planes[0], width: width, height: height, channels: planar ? 1 : 4)
        chroma = planar ? Plane(data: planes[1], width: width / 2, height: height / 2, channels: 2) : nil
        format = frame.format
        matrix = frame.color.matrix
        transfer = srgbBlend ? .linear : frame.color.transfer
    }

    private func convert(_ primary: SIMD4<Float>, chroma: SIMD4<Float>?) -> SIMD4<Float> {
        if let chroma {
            return ByteFrame.nv12Sample(y: primary.x, cb: chroma.x, cr: chroma.y, fullRange: format == .nv12Full,
                                        matrix: matrix, transfer: transfer)
        }
        let alpha = primary.w / 255
        let red = format == .bgra ? primary.z : primary.x
        let blue = format == .bgra ? primary.x : primary.z
        return SIMD4(ByteFrame.transferToLinear(red / 255, transfer) * alpha,
                     ByteFrame.transferToLinear(primary.y / 255, transfer) * alpha,
                     ByteFrame.transferToLinear(blue / 255, transfer) * alpha, alpha)
    }

    /// Coordinates and display size are in buffer orientation, after applying the frame rotation and mirror.
    func sample(bufferPixel: SIMD2<Float>, displaySize: SIMD2<Float>, exact: Bool) -> SIMD4<Float> {
        guard bufferPixel.x.isFinite, bufferPixel.y.isFinite, displaySize.x.isFinite, displaySize.y.isFinite else { return .zero }
        if exact {
            let x = Int(min(max(bufferPixel.x, 0), Float(first.width - 1)))
            let y = Int(min(max(bufferPixel.y, 0), Float(first.height - 1)))
            return convert(first.texel(x: x, y: y), chroma: chroma?.texel(x: x / 2, y: y / 2))
        }
        let divisor = SIMD2(max(1, displaySize.x), max(1, displaySize.y))
        let tapsX = Int(min(8, max(1, (Float(first.width) / divisor.x).rounded(.up))))
        let tapsY = Int(min(8, max(1, (Float(first.height) / divisor.y).rounded(.up))))
        let uv = bufferPixel / divisor
        var sum = SIMD4<Float>.zero
        for y in 0..<tapsY {
            for x in 0..<tapsX {
                let offset = SIMD2((Float(x) + 0.5) / Float(tapsX) - 0.5, (Float(y) + 0.5) / Float(tapsY) - 0.5)
                let coord = uv + offset / divisor
                sum += convert(first.bilinear(coord), chroma: chroma?.bilinear(coord))
            }
        }
        return sum / Float(tapsX * tapsY)
    }
}
