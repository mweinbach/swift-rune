#if os(Windows)
import CRuneWin32
import Foundation

/// A finished BGRA8 frame in a named D3D shared texture on Rune's adapter.
/// D3D11 producers use `D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE`
/// and `IDXGIResource1::CreateSharedHandle`. D3D12 producers use `ID3D12Device::CreateSharedHandle`.
/// Share a single-mip, single-sample `DXGI_FORMAT_B8G8R8A8_UNORM` texture on `adapterLUID`.
/// Finish writing before publication and keep the name live until Rune draws.
public struct SharedTexture: Sendable {
    public let name: String
    public let width: UInt32
    public let height: UInt32
    fileprivate var release: (name: String, value: UInt64)?

    public static func named(_ name: String, width: UInt32, height: UInt32) -> Self {
        Self(name: name, width: width, height: height)
    }

    /// Rune signals this named D3D11/D3D12 fence after it copies the publication.
    /// Values must increase. A publication superseded before its first draw signals nothing.
    public func releaseFence(_ name: String, value: UInt64) -> Self {
        var copy = self
        copy.release = (name, value)
        return copy
    }

    /// The Direct3D adapter selected for the most recently created Rune window.
    public static var adapterLUID: (high: Int32, low: UInt32)? {
        var high: Int32 = 0
        var low: UInt32 = 0
        return rune_win_shared_adapter(&high, &low) != 0 ? (high, low) : nil
    }
}

extension NativeSurface {
    /// Publish a new picture, including when a producer recycles its resource name or frame ID.
    /// Without a release fence the producer must arrange its own synchronization before reusing the texture.
    public func pushShared(_ texture: SharedTexture, frameId: UInt64) throws {
        guard (1...16_384).contains(texture.width), (1...16_384).contains(texture.height) else {
            throw NativeSurfaceError.dimensionsOutOfRange(width: texture.width, height: texture.height)
        }
        for name in [texture.name, texture.release?.name].compactMap({ $0 }) {
            guard !name.isEmpty, !name.utf16.contains(0) else {
                throw NativeSurfaceError.importFailed("shared resource names must be nonempty and contain no NUL")
            }
        }
        replaceFrame(NativeSurfaceVideoFrame(id: frameId, size: (texture.width, texture.height), format: .bgra,
                                             color: .srgb, orient: .up, source: .shared(WindowsSharedFrame(texture))))
    }
}

/// One publication, shared by every placement, renderer, and headless reader.
/// After the producer's fence has been signaled only the owned snapshot may be sampled.
public final class WindowsSharedFrame: @unchecked Sendable {
    public let texture: SharedTexture
    private let lock = NSLock()
    private var captured: Result<OpaquePointer, NativeSurfaceError>?
    private var pixels: Data?

    fileprivate init(_ texture: SharedTexture) { self.texture = texture }

    deinit {
        if case .success(let snapshot) = captured { rune_win_shared_destroy(snapshot) }
    }

    private static func failure(_ message: [CChar]) -> NativeSurfaceError {
        .importFailed(String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    // Called while holding lock. Cache import failures too, since a failed submission can release its slot.
    private func capture(gpuCopy: Bool) throws -> OpaquePointer {
        if let captured { return try captured.get() }
        let name = Array(texture.name.utf16) + [0]
        let fence = texture.release.map { Array($0.name.utf16) + [0] } ?? []
        var message = [CChar](repeating: 0, count: 512)
        let capacity = message.count
        let snapshot = fence.withUnsafeBufferPointer { fence in
            rune_win_shared_capture(name, texture.width, texture.height, fence.isEmpty ? nil : fence.baseAddress,
                                    texture.release?.value ?? 0, gpuCopy ? 1 : 0, &message, capacity)
        }
        let result: Result<OpaquePointer, NativeSurfaceError> = snapshot.map(Result.success) ?? .failure(Self.failure(message))
        captured = result
        return try result.get()
    }

    internal func withSnapshot<T>(gpuCopy: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        try lock.withLock { try body(capture(gpuCopy: gpuCopy)) }
    }

    internal func bytes() throws -> Data {
        try lock.withLock {
            if let pixels { return pixels }
            let snapshot = try capture(gpuCopy: false)
            var data = Data(count: Int(texture.width) * Int(texture.height) * 4)
            var message = [CChar](repeating: 0, count: 512)
            let capacity = message.count
            let ok = data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                rune_win_shared_read(snapshot, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &message, capacity)
            }
            guard ok != 0 else { throw Self.failure(message) }
            pixels = data
            return data
        }
    }
}
#endif
