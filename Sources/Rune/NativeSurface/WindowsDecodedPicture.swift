#if os(Windows) && canImport(CRuneMedia)
import CRuneMedia
import CRuneWin32
import Foundation

/// One immutable NV12 decoder-ring slot. Its encoded planes stay in D3D memory until requested by a CPU reader.
public final class WindowsDecodedPicture: @unchecked Sendable {
    private let handle: OpaquePointer
    internal let width: UInt32
    internal let height: UInt32
    internal let format: SurfacePixelFormat
    internal let color: SurfaceColorInfo
    internal let orient: Orient
    private let lock = NSLock()
    private var pixels: [Data]?

    internal var texture: UnsafeMutableRawPointer? { rune_media_picture_texture(handle) }

    internal init(handle: OpaquePointer, width: UInt32, height: UInt32,
                  format: SurfacePixelFormat, color: SurfaceColorInfo, orient: Orient) {
        self.handle = handle
        self.width = width
        self.height = height
        self.format = format
        self.color = color
        self.orient = orient
    }

    deinit { rune_media_picture_release(handle) }

    /// Software MF transforms supply their original packed NV12 bytes. The retained
    /// picture owns them, including while an independent layer presents its GPU copy.
    internal func withSoftwarePlanes<T>(_ body: (UnsafeBufferPointer<UInt8>, UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T? {
        try withExtendedLifetime(self) {
            guard let base = rune_media_picture_bytes(handle) else { return nil }
            let count = Int(width) * Int(height)
            return try body(UnsafeBufferPointer(start: base, count: count),
                            UnsafeBufferPointer(start: base.advanced(by: count), count: count / 2))
        }
    }

    internal func bytePlanes() throws -> [Data] {
        try lock.withLock {
            if let pixels { return pixels }
            if let original = withSoftwarePlanes({ [Data($0), Data($1)] }) {
                pixels = original
                return original
            }
            let count = Int(width) * Int(height)
            var luma = Data(count: count)
            var chroma = Data(count: count / 2)
            var error = [CChar](repeating: 0, count: 256)
            let capacity = error.count
            let copied = luma.withUnsafeMutableBytes { (y: UnsafeMutableRawBufferPointer) in
                chroma.withUnsafeMutableBytes { (uv: UnsafeMutableRawBufferPointer) in
                    rune_win_plane_read(texture, width, height, y.bindMemory(to: UInt8.self).baseAddress, y.count,
                                        uv.bindMemory(to: UInt8.self).baseAddress, uv.count, &error, capacity)
                }
            }
            guard copied != 0 else {
                throw NativeSurfaceError.importFailed(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            let planes = [luma, chroma]
            pixels = planes
            return planes
        }
    }
}

internal final class WindowsDecodedUploader {
    let handle: OpaquePointer

    init() throws {
        guard let handle = rune_win_plane_uploader_create() else {
            throw NativeSurfaceError.importFailed("unable to allocate a Windows video plane uploader")
        }
        self.handle = handle
    }

    deinit { rune_win_plane_uploader_destroy(handle) }
}

extension NativeSurface {
    internal func pushDecoded(_ picture: WindowsDecodedPicture, frameId: UInt64) -> Bool {
        let frame = NativeSurfaceVideoFrame(id: frameId, size: (picture.width, picture.height), format: picture.format,
                                            color: picture.color, orient: picture.orient, source: .decoded(picture))
        let presented = windowsVideoLayers?.present(frame) ?? false
        replaceFrame(frame, wake: !presented)
        return presented
    }
}
#endif
