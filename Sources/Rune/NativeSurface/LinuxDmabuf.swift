import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Single memory plane of a Linux DMA-BUF frame (`rune::native_surface::linux::DmabufPlane`, `#862`).
public struct DmabufPlane: Sendable, Equatable {
    /// File descriptor referring to the DMA-BUF backing object (non-negative).
    public var fd: Int32
    /// Byte offset of this plane within the DMA-BUF.
    public var offset: UInt32
    /// Row stride in bytes (must be at least `width * 4` for linear ARGB8888).
    public var stride: UInt32

    public init(fd: Int32, offset: UInt32 = 0, stride: UInt32) {
        self.fd = fd
        self.offset = offset
        self.stride = stride
    }
}

/// Cross-process Linux DMA-BUF frame descriptor (`rune::native_surface::linux::Dmabuf`, `#862`).
///
/// Supports linear ARGB8888 (`DRM_FORMAT_ARGB8888`, `0x34325241`) and XRGB8888 (`0x34325258`)
/// single-plane buffers. Fires `onRelease` exactly once when the frame is dropped or rejected
/// so the producer never hangs waiting for a frame completion.
public final class Dmabuf: @unchecked Sendable {
    /// `DRM_FORMAT_ARGB8888` (`'A','R','2','4'`).
    public static let formatARGB8888: UInt32 = 0x3432_5241
    /// `DRM_FORMAT_XRGB8888` (`'X','R','2','4'`).
    public static let formatXRGB8888: UInt32 = 0x3432_5258
    /// `DRM_FORMAT_MOD_LINEAR`.
    public static let modifierLinear: UInt64 = 0

    public let width: UInt32
    public let height: UInt32
    public let drmFormat: UInt32
    public let modifier: UInt64
    public let plane: DmabufPlane
    private let ownsFd: Bool
    private let lock = NSLock()
    private var released = false
    private var onRelease: (@Sendable () -> Void)?

    public init(
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32 = Dmabuf.formatARGB8888,
        modifier: UInt64 = Dmabuf.modifierLinear,
        plane: DmabufPlane,
        ownsFd: Bool = false,
        onRelease: (@Sendable () -> Void)? = nil
    ) throws {
        guard width >= 1 && height >= 1 && width <= 16_384 && height <= 16_384 else {
            onRelease?()
            throw NativeSurfaceError.dimensionsOutOfRange(width: width, height: height)
        }
        guard drmFormat == Self.formatARGB8888 || drmFormat == Self.formatXRGB8888 else {
            onRelease?()
            throw NativeSurfaceError.importFailed("dmabuf supports linear ARGB8888/XRGB8888 only")
        }
        guard modifier == Self.modifierLinear else {
            onRelease?()
            throw NativeSurfaceError.importFailed("dmabuf modifier must be linear (0)")
        }
        guard plane.fd >= 0 else {
            onRelease?()
            throw NativeSurfaceError.importFailed("dmabuf plane fd must be non-negative")
        }
        let minStride = UInt64(width) * 4
        guard UInt64(plane.stride) >= minStride else {
            onRelease?()
            throw NativeSurfaceError.importFailed("dmabuf stride \(plane.stride) is smaller than row bytes \(minStride)")
        }
        let total = UInt64(plane.offset) + UInt64(plane.stride) * UInt64(height)
        guard total <= UInt64(Int.max) else {
            onRelease?()
            throw NativeSurfaceError.importFailed("dmabuf plane byte range overflows")
        }
        self.width = width
        self.height = height
        self.drmFormat = drmFormat
        self.modifier = modifier
        self.plane = plane
        self.ownsFd = ownsFd
        self.onRelease = onRelease
    }

    public var size: (UInt32, UInt32) { (width, height) }

    /// Notifies the producer once that Rune is finished reading (or rejected) this dmabuf.
    public func notifyReleased() {
        let cb: (@Sendable () -> Void)? = lock.withLock {
            guard !released else { return nil }
            released = true
            let fn = onRelease
            onRelease = nil
            return fn
        }
        cb?()
    }

    /// Reads tightly packed BGRA8 bytes from a linear CPU-mappable dmabuf fd (fallback / reference).
    public func readLinearBGRA() throws -> Data {
        #if os(Linux) || os(macOS)
        let rowBytes = Int(width) * 4
        let strideBytes = Int(plane.stride)
        let totalSize = Int(plane.offset) + strideBytes * Int(height)
        guard totalSize > 0 else {
            throw NativeSurfaceError.importFailed("dmabuf size is empty")
        }
        let ptr = mmap(nil, totalSize, PROT_READ, MAP_SHARED, plane.fd, 0)
        guard ptr != MAP_FAILED, let base = ptr else {
            throw NativeSurfaceError.importFailed("dmabuf mmap failed (errno \(errno))")
        }
        defer { munmap(base, totalSize) }
        var out = Data(count: rowBytes * Int(height))
        let srcStart = base.advanced(by: Int(plane.offset))
        out.withUnsafeMutableBytes { dstRaw in
            guard let dst = dstRaw.baseAddress else { return }
            for y in 0..<Int(height) {
                memcpy(dst.advanced(by: y * rowBytes), srcStart.advanced(by: y * strideBytes), rowBytes)
                if drmFormat == Self.formatXRGB8888 {
                    let row = dst.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<Int(width) {
                        row[x * 4 + 3] = 255
                    }
                }
            }
        }
        return out
        #else
        throw NativeSurfaceError.importFailed("dmabuf readback requires POSIX mmap")
        #endif
    }

    deinit {
        notifyReleased()
        #if os(Linux) || os(macOS)
        if ownsFd && plane.fd >= 0 {
            _ = close(plane.fd)
        }
        #endif
    }
}

public extension NativeSurface {
    /// Pushes a cross-process Linux DMA-BUF frame (`NativeSurface::push_dmabuf`, `#862`).
    func pushDmabuf(_ frame: Dmabuf, frameId: UInt64) throws {
        let size = frame.size
        guard size.0 >= 1 && size.1 >= 1 && size.0 <= 16_384 && size.1 <= 16_384 else {
            frame.notifyReleased()
            throw NativeSurfaceError.dimensionsOutOfRange(width: size.0, height: size.1)
        }
        let videoFrame = NativeSurfaceVideoFrame(
            id: frameId,
            size: size,
            format: .bgra,
            color: .srgb,
            orient: .up,
            source: .dmabuf(frame)
        )
        replaceFrame(videoFrame)
    }
}
