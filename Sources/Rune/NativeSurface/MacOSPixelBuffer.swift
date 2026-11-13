import Foundation

#if os(macOS)
import CoreVideo
import IOSurface
import Metal

/// Retained CoreVideo pixel buffer wrapper with Sendable semantics (`macos::PixelBuffer`).
public final class CoreVideoPixelBuffer: @unchecked Sendable {
    public let cvBuffer: CVPixelBuffer

    private init(_ cvBuffer: CVPixelBuffer) {
        self.cvBuffer = cvBuffer
    }

    /// Wraps an already-retained or newly passed `CVPixelBuffer` (`CVPixelBuffer` is CFRetained in Swift ARC).
    public static func fromRaw(_ buffer: CVPixelBuffer) -> CoreVideoPixelBuffer {
        CoreVideoPixelBuffer(buffer)
    }

    /// Creates a `CVPixelBuffer` backed by an `IOSurface` without copying pixel data.
    public static func fromIOSurface(_ ioSurface: IOSurfaceRef) throws -> CoreVideoPixelBuffer {
        var unmanaged: Unmanaged<CVPixelBuffer>?
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            ioSurface,
            attrs as CFDictionary,
            &unmanaged
        )
        guard status == kCVReturnSuccess, let pb = unmanaged?.takeRetainedValue() else {
            throw NativeSurfaceError.importFailed("CVPixelBufferCreateWithIOSurface failed: \(status)")
        }
        return CoreVideoPixelBuffer(pb)
    }

    /// Creates an IOSurface-backed `CVPixelBuffer` from CPU `ByteFrame` (used by headless/unit tests).
    public static func fromBytes(_ frame: ByteFrame) throws -> CoreVideoPixelBuffer {
        let osFmt: OSType
        switch frame.format {
        case .bgra, .rgba:
            osFmt = kCVPixelFormatType_32BGRA
        case .nv12Video:
            osFmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .nv12Full:
            osFmt = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var pbOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(frame.width),
            Int(frame.height),
            osFmt,
            attrs as CFDictionary,
            &pbOut
        )
        guard status == kCVReturnSuccess, let pb = pbOut else {
            throw NativeSurfaceError.importFailed("CVPixelBufferCreate failed: \(status)")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        switch frame.format {
        case .bgra:
            if let dst = CVPixelBufferGetBaseAddress(pb) {
                let dstStride = CVPixelBufferGetBytesPerRow(pb)
                let srcStride = Int(frame.width) * 4
                frame.planes[0].withUnsafeBytes { raw in
                    guard let src = raw.baseAddress else { return }
                    for row in 0..<Int(frame.height) {
                        memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), srcStride)
                    }
                }
            }
        case .rgba:
            if let dst = CVPixelBufferGetBaseAddress(pb) {
                let dstStride = CVPixelBufferGetBytesPerRow(pb)
                frame.planes[0].withUnsafeBytes { raw in
                    guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    let dstU8 = dst.assumingMemoryBound(to: UInt8.self)
                    for row in 0..<Int(frame.height) {
                        let dRow = dstU8.advanced(by: row * dstStride)
                        let sRow = src.advanced(by: row * Int(frame.width) * 4)
                        for x in 0..<Int(frame.width) {
                            let i = x * 4
                            dRow[i + 0] = sRow[i + 2]
                            dRow[i + 1] = sRow[i + 1]
                            dRow[i + 2] = sRow[i + 0]
                            dRow[i + 3] = sRow[i + 3]
                        }
                    }
                }
            }
        case .nv12Video, .nv12Full:
            if let yDst = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
                let yDstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                let ySrcStride = Int(frame.width)
                frame.planes[0].withUnsafeBytes { raw in
                    guard let src = raw.baseAddress else { return }
                    for row in 0..<Int(frame.height) {
                        memcpy(yDst.advanced(by: row * yDstStride), src.advanced(by: row * ySrcStride), ySrcStride)
                    }
                }
            }
            if let uvDst = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
                let uvDstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
                let uvSrcStride = Int(frame.width)
                let uvHeight = Int(frame.height) / 2
                frame.planes[1].withUnsafeBytes { raw in
                    guard let src = raw.baseAddress else { return }
                    for row in 0..<uvHeight {
                        memcpy(uvDst.advanced(by: row * uvDstStride), src.advanced(by: row * uvSrcStride), uvSrcStride)
                    }
                }
            }
        }

        let out = CoreVideoPixelBuffer(pb)
        out.setColor(matrix: frame.color.matrix, transfer: frame.color.transfer)
        return out
    }

    public var size: (UInt32, UInt32) {
        (UInt32(CVPixelBufferGetWidth(cvBuffer)), UInt32(CVPixelBufferGetHeight(cvBuffer)))
    }

    /// Attaches CVBuffer matrix/transfer attachments matching `SurfaceColorInfo`.
    public func setColor(matrix: SurfaceMatrix, transfer: SurfaceTransfer) {
        let matrixVal: CFString = (matrix == .bt601)
            ? kCVImageBufferYCbCrMatrix_ITU_R_601_4
            : kCVImageBufferYCbCrMatrix_ITU_R_709_2
        CVBufferSetAttachment(cvBuffer, kCVImageBufferYCbCrMatrixKey, matrixVal, .shouldPropagate)

        let transferVal: CFString
        switch transfer {
        case .srgb:
            transferVal = kCVImageBufferTransferFunction_sRGB
        case .bt709:
            transferVal = kCVImageBufferTransferFunction_ITU_R_709_2
        case .linear:
            transferVal = kCVImageBufferTransferFunction_Linear
        }
        CVBufferSetAttachment(cvBuffer, kCVImageBufferTransferFunctionKey, transferVal, .shouldPropagate)
    }

    public func surfaceFormat() throws -> SurfacePixelFormat {
        let pf = CVPixelBufferGetPixelFormatType(cvBuffer)
        switch pf {
        case kCVPixelFormatType_32BGRA:
            return .bgra
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return .nv12Video
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return .nv12Full
        default:
            throw NativeSurfaceError.importFailed("unsupported CVPixelFormatType \(pf)")
        }
    }

    public func colorInfo() -> SurfaceColorInfo {
        let w = CVPixelBufferGetWidth(cvBuffer)
        let h = CVPixelBufferGetHeight(cvBuffer)

        var matrix: SurfaceMatrix = (w < 1280 && h < 720) ? .bt601 : .bt709
        if let m = CVBufferCopyAttachment(cvBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String {
            if m == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) {
                matrix = .bt601
            } else if m == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) {
                matrix = .bt709
            }
        }

        var transfer: SurfaceTransfer = .bt709
        if CVPixelBufferGetPixelFormatType(cvBuffer) == kCVPixelFormatType_32BGRA {
            transfer = .srgb
        }
        if let t = CVBufferCopyAttachment(cvBuffer, kCVImageBufferTransferFunctionKey, nil) as? String {
            if t == (kCVImageBufferTransferFunction_sRGB as String) {
                transfer = .srgb
            } else if t == (kCVImageBufferTransferFunction_Linear as String) {
                transfer = .linear
            } else {
                transfer = .bt709
            }
        }
        return SurfaceColorInfo(matrix: matrix, transfer: transfer)
    }
}

/// Retains `CVMetalTexture` and `CoreVideoPixelBuffer` until GPU work reading the imported planes finishes.
internal final class RetainedPlaneToken: @unchecked Sendable {
    private let cvTextures: [CVMetalTexture]
    private let pixelBuffer: CoreVideoPixelBuffer
    private weak var importer: CVPixelBufferImporter?

    init(cvTextures: [CVMetalTexture], pixelBuffer: CoreVideoPixelBuffer, importer: CVPixelBufferImporter) {
        self.cvTextures = cvTextures
        self.pixelBuffer = pixelBuffer
        self.importer = importer
        importer.incrementLivePlanes()
    }

    deinit {
        _ = cvTextures
        _ = pixelBuffer
        importer?.decrementLivePlanes()
    }
}

/// Zero-copy `CVMetalTextureCache` importer for `CoreVideoPixelBuffer` -> Metal textures (`macos::Importer`).
public final class CVPixelBufferImporter: @unchecked Sendable {
    private let cache: CVMetalTextureCache
    private let lock = NSLock()
    private var _livePlanes: Int = 0

    public init(device: MTLDevice) throws {
        var cacheOut: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cacheOut)
        guard status == kCVReturnSuccess, let cacheOut else {
            throw NativeSurfaceError.importFailed("CVMetalTextureCacheCreate failed: \(status)")
        }
        self.cache = cacheOut
    }

    public var livePlanes: Int {
        lock.lock()
        defer { lock.unlock() }
        return _livePlanes
    }

    internal func incrementLivePlanes() {
        lock.lock()
        _livePlanes += 1
        lock.unlock()
    }

    internal func decrementLivePlanes() {
        lock.lock()
        _livePlanes -= 1
        lock.unlock()
    }

    /// Zero-copy import of a BGRA or NV12 `CoreVideoPixelBuffer` into Metal textures + retention token.
    internal func `import`(_ buffer: CoreVideoPixelBuffer, format: SurfacePixelFormat, size: (UInt32, UInt32)) throws -> ([MTLTexture], RetainedPlaneToken) {
        CVMetalTextureCacheFlush(cache, 0)
        switch format {
        case .bgra, .rgba:
            let tex = try createTexture(from: buffer.cvBuffer, pixelFormat: .bgra8Unorm, width: Int(size.0), height: Int(size.1), planeIndex: 0)
            let mtl = CVMetalTextureGetTexture(tex.cvTex)!
            let token = RetainedPlaneToken(cvTextures: [tex.cvTex], pixelBuffer: buffer, importer: self)
            return ([mtl, mtl], token)
        case .nv12Video, .nv12Full:
            let y = try createTexture(from: buffer.cvBuffer, pixelFormat: .r8Unorm, width: Int(size.0), height: Int(size.1), planeIndex: 0)
            let uv = try createTexture(from: buffer.cvBuffer, pixelFormat: .rg8Unorm, width: Int(size.0) / 2, height: Int(size.1) / 2, planeIndex: 1)
            let mtlY = CVMetalTextureGetTexture(y.cvTex)!
            let mtlUV = CVMetalTextureGetTexture(uv.cvTex)!
            let token = RetainedPlaneToken(cvTextures: [y.cvTex, uv.cvTex], pixelBuffer: buffer, importer: self)
            return ([mtlY, mtlUV], token)
        }
    }

    private func createTexture(
        from pb: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        planeIndex: Int
    ) throws -> (cvTex: CVMetalTexture, mtlTex: MTLTexture) {
        var cvTexOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pb,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &cvTexOut
        )
        guard status == kCVReturnSuccess, let cvTex = cvTexOut, let mtlTex = CVMetalTextureGetTexture(cvTex) else {
            throw NativeSurfaceError.importFailed("CVMetalTextureCacheCreateTextureFromImage plane \(planeIndex) failed: \(status)")
        }
        return (cvTex, mtlTex)
    }
}
#endif
