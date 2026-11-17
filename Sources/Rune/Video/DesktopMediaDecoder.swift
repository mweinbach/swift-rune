#if canImport(CRuneMedia)
import CRuneMedia
import Foundation

/// A native demuxer and decoder. Control calls and frame copies are serialized
/// because both Media Foundation and GStreamer maintain a cursor per source.
internal final class DesktopMediaDecoder: @unchecked Sendable {
    let meta: VideoMeta
    let orient: Orient
    let headless: Bool
    let source: DesktopMediaSource
    private let handle: OpaquePointer
    private let lock = NSLock()
    private let width: UInt32
    private let height: UInt32
    private var frameBuffer = Data()

    init(source: DesktopMediaSource, kind: MediaKind, headless: Bool) throws {
        var info = RuneMediaInfo()
        var error = [CChar](repeating: 0, count: 512)
        let handle = error.withUnsafeMutableBufferPointer { diagnostic in
            rune_media_open(source.url.absoluteString, kind == .audio ? 1 : 0, headless ? 1 : 0,
                            &info, diagnostic.baseAddress, diagnostic.count)
        }
        guard let handle else { throw Self.failure(error) }
        guard info.width <= 16_384, info.height <= 16_384, (info.width == 0) == (info.height == 0) else {
            rune_media_close(handle)
            throw NativeSurfaceError.dimensionsOutOfRange(width: info.width, height: info.height)
        }
        self.handle = handle
        self.source = source
        self.headless = headless
        width = info.width
        height = info.height
        switch ((info.rotation_clockwise % 360) + 360) % 360 {
        case 90: orient = Orient(m00: 0, m01: 1, m10: -1, m11: 0)
        case 180: orient = Orient(m00: -1, m01: 0, m10: 0, m11: -1)
        case 270: orient = Orient(m00: 0, m01: -1, m10: 1, m11: 0)
        default: orient = .up
        }
        meta = VideoMeta(kind: width > 0 ? .video : .audio,
                         duration: info.duration.isFinite && info.duration >= 0 ? info.duration : nil,
                         size: width > 0 ? orient.upright(width: width, height: height) : nil,
                         hasSound: info.has_audio != 0, frameDuration: info.frame_duration)
    }

    deinit { rune_media_close(handle) }

    func setTransport(_ request: MediaRequest, seek: Double?) throws {
        try lock.withLock {
            var error = [CChar](repeating: 0, count: 512)
            let result = error.withUnsafeMutableBufferPointer {
                rune_media_transport(handle, request.playing ? 1 : 0, seek ?? -1,
                                     Double(request.rate), Double(request.volume), request.muted ? 1 : 0,
                                     $0.baseAddress, $0.count)
            }
            guard result != 0 else { throw Self.failure(error) }
        }
    }

    func status() throws -> (time: Double, ended: Bool) {
        try lock.withLock {
            var time = 0.0
            var ended: Int32 = 0
            var error = [CChar](repeating: 0, count: 512)
            let result = error.withUnsafeMutableBufferPointer {
                rune_media_status(handle, &time, &ended, $0.baseAddress, $0.count)
            }
            guard result != 0 else { throw Self.failure(error) }
            return (time.isFinite ? max(time, 0) : 0, ended != 0)
        }
    }

    /// A nil timestamp retrieves a live or paused frame at the native clock.
    func frame(at time: Double?) throws -> ByteFrame? {
        guard width != 0, height != 0 else { return nil }
        return try lock.withLock {
            let byteCount = Int(width) * Int(height) * 4
            if frameBuffer.isEmpty { frameBuffer = Data(count: byteCount) }
            var error = [CChar](repeating: 0, count: 512)
            let result = error.withUnsafeMutableBufferPointer { diagnostic in
                frameBuffer.withUnsafeMutableBytes { pixels in
                    rune_media_frame(handle, time ?? -1, pixels.bindMemory(to: UInt8.self).baseAddress,
                                     pixels.count, diagnostic.baseAddress, diagnostic.count)
                }
            }
            guard result >= 0 else { throw Self.failure(error) }
            guard result != 0 else { return nil }
            let frame = try ByteFrame(width: width, height: height, format: .bgra, color: .srgb, planes: [frameBuffer])
            frameBuffer = Data()
            return frame
        }
    }

    private static func failure(_ diagnostic: [CChar]) -> NativeSurfaceError {
        let message = String(decoding: diagnostic.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return .importFailed(message.isEmpty ? "Native media decoder failed" : message)
    }
}
#endif
