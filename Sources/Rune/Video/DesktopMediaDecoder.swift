#if canImport(CRuneMedia)
import CRuneMedia
import Foundation

#if os(Windows)
/// Both immutable Data views retain the same allocation until the last consumer releases its plane.
private final class WindowsSoftwarePicture: @unchecked Sendable {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { rune_media_picture_release(handle) }

    func plane(_ pointer: UnsafePointer<UInt8>, count: Int) -> Data {
        Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer), count: count,
             deallocator: .custom { [self] _, _ in withExtendedLifetime(self) {} })
    }
}
#endif

internal enum DesktopMediaFrame {
    case bytes(ByteFrame)
    #if os(Windows)
    case texture(WindowsDecodedPicture)
    #endif

    /// Returns true once a video plane has independently presented this revision.
    func publish(to surface: NativeSurface, orient: Orient, id: UInt64) throws -> Bool {
        switch self {
        case .bytes(let frame):
            try surface.pushBytesOriented(frame, orient: orient, frameId: id)
            return false
        #if os(Windows)
        case .texture(let picture):
            return surface.pushDecoded(picture, frameId: id)
        #endif
        }
    }
}

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
    #if os(Windows)
    private let nv12: RunePictureInfo
    #endif

    init(source: DesktopMediaSource, kind: MediaKind, headless: Bool, packedRGB: Bool = false) throws {
        var info = RuneMediaInfo()
        var error = [CChar](repeating: 0, count: 512)
        #if os(Windows)
        var picture = RunePictureInfo()
        #endif
        let handle = error.withUnsafeMutableBufferPointer { diagnostic in
            #if os(Windows)
            if kind == .video && !packedRGB {
                if headless {
                    return rune_media_open_still(source.url.absoluteString, &info, &picture,
                                                 diagnostic.baseAddress, diagnostic.count)
                }
                if let luid = SharedTexture.adapterLUID {
                    var adapter = Int64(luid.high) << 32 | Int64(luid.low)
                    return rune_media_open_video(source.url.absoluteString, &adapter, &info, &picture,
                                                 diagnostic.baseAddress, diagnostic.count)
                }
                return rune_media_open_video(source.url.absoluteString, nil, &info, &picture,
                                             diagnostic.baseAddress, diagnostic.count)
            }
            #endif
            return rune_media_open(source.url.absoluteString, kind == .audio ? 1 : 0, headless ? 1 : 0,
                                   &info, diagnostic.baseAddress, diagnostic.count)
        }
        guard let handle else { throw Self.failure(error) }
        guard info.width <= 16_384, info.height <= 16_384, (info.width == 0) == (info.height == 0) else {
            rune_media_close(handle)
            throw NativeSurfaceError.dimensionsOutOfRange(width: info.width, height: info.height)
        }
        #if os(Windows)
        nv12 = picture
        let naturalWidth = picture.natural_width > 0 ? picture.natural_width : info.width
        #else
        let naturalWidth = info.width
        #endif
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
                         size: width > 0 ? orient.upright(width: naturalWidth, height: height) : nil,
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

    #if os(Windows)
    var lastPictureTime: Double? {
        let time = lock.withLock { rune_media_last_picture_time(handle) }
        return time >= 0 ? time : nil
    }

    func nextVideoDelay() -> Double {
        // Dispatch converts its interval to signed nanoseconds. Tiny positive
        // playback rates can put the next sample beyond that representable range.
        lock.withLock { min(rune_media_next_video_delay(handle), Double(Int32.max)) }
    }
    #endif

    func isFrameDue(previousTime: Double?, currentTime: Double) -> Bool {
        #if os(Windows)
        // Media Foundation checks the next sample's PTS against the target
        // refresh and suppresses repeats, including variable-rate sources.
        return true
        #else
        return previousTime.map { floor($0 / meta.frameDuration) } != floor(currentTime / meta.frameDuration)
        #endif
    }

    /// A nil timestamp retrieves a live or paused frame at the native clock.
    func frame(at time: Double?, retaining previousSampleTime: Double? = nil) throws -> DesktopMediaFrame? {
        guard width != 0, height != 0 else { return nil }
        return try lock.withLock {
            #if os(Windows)
            if nv12.width > 0 {
                var picture: OpaquePointer?
                var error = [CChar](repeating: 0, count: 512)
                let result = error.withUnsafeMutableBufferPointer {
                    rune_media_picture(handle, time ?? -1, previousSampleTime ?? -1, &picture, $0.baseAddress, $0.count)
                }
                guard result >= 0 else { throw Self.failure(error) }
                guard let picture else { return nil }
                let format: SurfacePixelFormat = nv12.full_range == 0 ? .nv12Video : .nv12Full
                let color: SurfaceColorInfo = nv12.bt709 == 0 ? .bt601 : .bt709
                if rune_media_picture_texture(picture) != nil {
                    return .texture(WindowsDecodedPicture(handle: picture, width: width, height: height, format: format,
                                                         color: color, orient: orient))
                }
                let owner = WindowsSoftwarePicture(picture)
                guard let packed = rune_media_picture_bytes(picture) else {
                    throw NativeSurfaceError.importFailed("Media Foundation returned an empty NV12 picture")
                }
                let count = Int(width) * Int(height)
                return .bytes(try ByteFrame(width: width, height: height, format: format, color: color,
                                            planes: [owner.plane(packed, count: count),
                                                     owner.plane(packed + count, count: count / 2)]))
            }
            #endif
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
            return .bytes(frame)
        }
    }

    private static func failure(_ diagnostic: [CChar]) -> NativeSurfaceError {
        let message = String(decoding: diagnostic.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return .importFailed(message.isEmpty ? "Native media decoder failed" : message)
    }
}
#endif
