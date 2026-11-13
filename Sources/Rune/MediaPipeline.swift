import Foundation
import RuneMotion
import RuneRef

#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(AVFoundation)
import AVFoundation
import CoreVideo
#endif

// MARK: - 1. Image Pipeline

public struct ImageError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// One mipmap level in straight/premultiplied RGBA8.
public struct ImageMipLevel: Sendable, Equatable {
    public let width: UInt32
    public let height: UInt32
    public let rgba: Data

    public init(width: UInt32, height: UInt32, rgba: Data) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

/// A single frame of an animated image (GIF, APNG, WebP, HEICS).
public struct AnimatedImageFrame: Sendable, Equatable {
    public let width: UInt32
    public let height: UInt32
    public let rgba: Data
    public let durationSeconds: Double

    public init(width: UInt32, height: UInt32, rgba: Data, durationSeconds: Double) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.durationSeconds = max(0.01, durationSeconds)
    }
}

/// Decoded image with full mipmap chain and optional animation frames.
public struct DecodedImage: Sendable, Equatable {
    public let id: String
    public let width: UInt32
    public let height: UInt32
    public let mips: [ImageMipLevel]
    public let frames: [AnimatedImageFrame]
    public let loopCount: Int

    public var isAnimated: Bool { frames.count > 1 }

    public var totalAnimationDuration: Double {
        frames.reduce(0.0) { $0 + $1.durationSeconds }
    }

    public init(
        id: String,
        width: UInt32,
        height: UInt32,
        mips: [ImageMipLevel],
        frames: [AnimatedImageFrame] = [],
        loopCount: Int = 0
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.mips = mips
        self.frames = frames
        self.loopCount = loopCount
    }

    /// Selects the frame corresponding to `elapsedSeconds` in an animated image.
    public func frame(at elapsedSeconds: Double) -> AnimatedImageFrame? {
        guard !frames.isEmpty else { return nil }
        if frames.count == 1 { return frames[0] }
        let total = totalAnimationDuration
        guard total > 0 else { return frames[0] }
        var t = elapsedSeconds.truncatingRemainder(dividingBy: total)
        if t < 0 { t += total }
        var acc = 0.0
        for frame in frames {
            acc += frame.durationSeconds
            if t < acc {
                return frame
            }
        }
        return frames.last
    }

    /// Generates a full linear-light area-resampled mipmap chain from an RGBA8 image.
    public static func generateMipChain(width: UInt32, height: UInt32, rgba: Data) -> [ImageMipLevel] {
        LinearMipGenerator.generateChain(width: width, height: height, straightRGBA: rgba)
    }

    /// Decodes encoded image bytes (PNG, JPEG, WebP, HEIC, AVIF, GIF, APNG) via `CGImageSource`.
    public static func decode(data: Data, id: String = UUID().uuidString, maxDimension: Int? = nil) throws -> DecodedImage {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageError("failed to create CGImageSource")
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            throw ImageError("image contains no frames")
        }

        var loopCount = 0
        if let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] {
            if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any],
               let lc = gif[kCGImagePropertyGIFLoopCount] as? Int {
                loopCount = lc
            } else if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any],
                      let lc = png[kCGImagePropertyAPNGLoopCount] as? Int {
                loopCount = lc
            }
        }

        var frames: [AnimatedImageFrame] = []
        for idx in 0..<count {
            let options: [CFString: Any]
            if let maxDim = maxDimension, maxDim > 0 {
                options = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDim,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
            } else {
                options = [:]
            }
            let cgImg: CGImage?
            if let maxDim = maxDimension, maxDim > 0 {
                cgImg = CGImageSourceCreateThumbnailAtIndex(source, idx, options as CFDictionary)
            } else {
                cgImg = CGImageSourceCreateImageAtIndex(source, idx, nil)
            }
            guard let img = cgImg else {
                throw ImageError("failed to decode frame \(idx)")
            }
            let w = img.width
            let h = img.height
            guard w > 0, h > 0 else { throw ImageError("invalid zero-sized frame") }
            guard w <= LinearMipGenerator.maxDecodeDimension,
                  h <= LinearMipGenerator.maxDecodeDimension else {
                throw ImageError("image dimensions \(w)x\(h) exceed \(LinearMipGenerator.maxDecodeDimension)px cap")
            }
            let (pixelCount, overflow1) = w.multipliedReportingOverflow(by: h)
            let (byteCount, overflow2) = pixelCount.multipliedReportingOverflow(by: 4)
            guard !overflow1, !overflow2, byteCount <= LinearMipGenerator.maxDecodedBytes else {
                throw ImageError("decoded image buffer exceeds 256 MiB cap")
            }

            var rgba = Data(count: byteCount)
            let cs = CGColorSpaceCreateDeviceRGB()
            let bi = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            let drawn = rgba.withUnsafeMutableBytes { ptr -> Bool in
                guard let base = ptr.baseAddress,
                      let ctx = CGContext(
                          data: base,
                          width: w,
                          height: h,
                          bitsPerComponent: 8,
                          bytesPerRow: w * 4,
                          space: cs,
                          bitmapInfo: bi.rawValue
                      ) else {
                    return false
                }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { throw ImageError("failed to rasterize frame \(idx)") }

            let delay = frameDelaySeconds(source: source, index: idx)
            frames.append(AnimatedImageFrame(width: UInt32(w), height: UInt32(h), rgba: rgba, durationSeconds: delay))
        }

        let first = frames[0]
        let mips = generateMipChain(width: first.width, height: first.height, rgba: first.rgba)
        return DecodedImage(
            id: id,
            width: first.width,
            height: first.height,
            mips: mips,
            frames: frames,
            loopCount: loopCount
        )
        #else
        if let decoded = try? PortablePNG.decode(data) {
            guard decoded.width > 0, decoded.height > 0,
                  decoded.width <= LinearMipGenerator.maxDecodeDimension,
                  decoded.height <= LinearMipGenerator.maxDecodeDimension else {
                throw ImageError("image dimensions \(decoded.width)x\(decoded.height) exceed limits")
            }
            let byteCount = decoded.width * decoded.height * 4
            guard byteCount <= LinearMipGenerator.maxDecodedBytes else {
                throw ImageError("decoded image buffer exceeds 256 MiB cap")
            }
            let w = UInt32(decoded.width)
            let h = UInt32(decoded.height)
            let rgbaData = Data(decoded.rgba)
            let mips = generateMipChain(width: w, height: h, rgba: rgbaData)
            return DecodedImage(
                id: id,
                width: w,
                height: h,
                mips: mips,
                frames: [AnimatedImageFrame(width: w, height: h, rgba: rgbaData, durationSeconds: 0.1)],
                loopCount: 0
            )
        }
        throw ImageError("ImageIO unavailable on this platform and data is not a valid PNG")
        #endif
    }

    #if canImport(ImageIO)
    private static func frameDelaySeconds(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.1
        }
        if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0 {
                return unclamped
            }
            if let delay = gif[kCGImagePropertyGIFDelayTime] as? Double, delay > 0 {
                return delay
            }
        }
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            if let unclamped = png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double, unclamped > 0 {
                return unclamped
            }
            if let delay = png[kCGImagePropertyAPNGDelayTime] as? Double, delay > 0 {
                return delay
            }
        }
        if let webp = props[kCGImagePropertyWebPDictionary] as? [CFString: Any],
           let delay = webp[kCGImagePropertyWebPDelayTime] as? Double, delay > 0 {
            return delay
        }
        if let heics = props[kCGImagePropertyHEICSDictionary] as? [CFString: Any],
           let delay = heics[kCGImagePropertyHEICSDelayTime] as? Double, delay > 0 {
            return delay
        }
        return 0.1
    }
    #endif
}

/// Asynchronous background image decode pool with an LRU byte-budgeted cache.
public final class ImageDecodePool: @unchecked Sendable {
    private struct CacheEntry {
        var image: DecodedImage
        var byteCost: Int
        var lastAccessTick: UInt64
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var accessTick: UInt64 = 0
    private var currentBytes: Int = 0
    public let capacityBytes: Int
    public private(set) var hitCount: UInt64 = 0
    public private(set) var missCount: UInt64 = 0

    public init(capacityBytes: Int = 64 * 1024 * 1024) {
        self.capacityBytes = max(1024, capacityBytes)
    }

    public func cached(forKey key: String) -> DecodedImage? {
        lock.lock()
        defer { lock.unlock() }
        if var entry = cache[key] {
            accessTick += 1
            entry.lastAccessTick = accessTick
            cache[key] = entry
            hitCount += 1
            return entry.image
        }
        missCount += 1
        return nil
    }

    public func insert(_ image: DecodedImage, forKey key: String) {
        let cost = image.mips.reduce(0) { $0 + $1.rgba.count }
        lock.lock()
        defer { lock.unlock() }
        if let old = cache.removeValue(forKey: key) {
            currentBytes -= old.byteCost
        }
        accessTick += 1
        cache[key] = CacheEntry(image: image, byteCost: cost, lastAccessTick: accessTick)
        currentBytes += cost
        evictLocked()
    }

    private func evictLocked() {
        while currentBytes > capacityBytes, !cache.isEmpty {
            guard let oldest = cache.min(by: { $0.value.lastAccessTick < $1.value.lastAccessTick })?.key else {
                break
            }
            if let removed = cache.removeValue(forKey: oldest) {
                currentBytes -= removed.byteCost
            }
        }
    }

    public var totalCachedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentBytes
    }

    public var cachedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    public func clear() {
        lock.lock()
        cache.removeAll()
        currentBytes = 0
        lock.unlock()
    }

    public func decode(data: Data, key: String, maxDimension: Int? = nil) async throws -> DecodedImage {
        if let hit = cached(forKey: key) {
            return hit
        }
        let decoded = try await Task.detached(priority: .userInitiated) {
            try DecodedImage.decode(data: data, id: key, maxDimension: maxDimension)
        }.value
        insert(decoded, forKey: key)
        return decoded
    }

    public func loadFile(_ url: URL, maxDimension: Int? = nil) async throws -> DecodedImage {
        let key = "file://\(url.path)#\(maxDimension ?? 0)"
        if let hit = cached(forKey: key) {
            return hit
        }
        let data = try Data(contentsOf: url)
        return try await decode(data: data, key: key, maxDimension: maxDimension)
    }

    public func loadURL(_ url: URL, maxDimension: Int? = nil) async throws -> DecodedImage {
        if url.isFileURL {
            return try await loadFile(url, maxDimension: maxDimension)
        }
        let key = "\(url.absoluteString)#\(maxDimension ?? 0)"
        if let hit = cached(forKey: key) {
            return hit
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try await decode(data: data, key: key, maxDimension: maxDimension)
    }

    #if canImport(Metal)
    public static func makeTexture(device: MTLDevice, image: DecodedImage) -> MTLTexture? {
        guard let base = image.mips.first else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: Int(base.width),
            height: Int(base.height),
            mipmapped: image.mips.count > 1
        )
        desc.usage = [.shaderRead]
        desc.mipmapLevelCount = image.mips.count
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        for (level, mip) in image.mips.enumerated() {
            mip.rgba.withUnsafeBytes { ptr in
                guard let basePtr = ptr.baseAddress else { return }
                tex.replace(
                    region: MTLRegionMake2D(0, 0, Int(mip.width), Int(mip.height)),
                    mipmapLevel: level,
                    withBytes: basePtr,
                    bytesPerRow: Int(mip.width) * 4
                )
            }
        }
        return tex
    }
    #endif
}

// MARK: - 2. Video Pipeline (AVFoundation + Procedural Synthetic Source)

public enum VideoPlayerState: Sendable, Equatable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case ended
    case failed(String)
}

public enum SyntheticVideoPattern: String, Sendable, Equatable, CaseIterable {
    case colorBars
    case movingChecker
    case plasmaWave
    case timecodeGrid
}

public enum VideoSource: Sendable, Equatable {
    case url(URL)
    case synthetic(pattern: SyntheticVideoPattern, width: UInt32, height: UInt32, fps: Double, durationSeconds: Double)

    public static func file(_ url: URL) -> VideoSource {
        .url(url)
    }
}

public struct VideoPixelFrame: Sendable, Equatable {
    public let width: UInt32
    public let height: UInt32
    public let rgba: Data
    public let timeSeconds: Double
    public let frameIndex: UInt64

    public init(width: UInt32, height: UInt32, rgba: Data, timeSeconds: Double, frameIndex: UInt64) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.timeSeconds = timeSeconds
        self.frameIndex = frameIndex
    }
}

/// Media player supporting `AVFoundation` video playback/frame extraction and deterministic
/// procedural synthetic test-pattern sources for headless rendering & examples.
public final class VideoPlayer: @unchecked Sendable {
    private let lock = NSLock()
    public let source: VideoSource

    private var _state: VideoPlayerState = .idle
    private var _currentTime: Double = 0
    private var _duration: Double = 0
    private var _isLooping: Bool = false
    private var _isMuted: Bool = false
    private var _volume: Float = 1.0
    private var _rate: Float = 1.0
    private var _naturalSize: Vec2 = .zero
    private var _fps: Double = 30.0

    #if canImport(AVFoundation)
    private var avAsset: AVURLAsset?
    private var imageGenerator: AVAssetImageGenerator?
    #endif

    public init(source: VideoSource) {
        self.source = source
        switch source {
        case .synthetic(_, let w, let h, let fps, let duration):
            self._naturalSize = Vec2(Float(w), Float(h))
            self._fps = max(1.0, fps)
            self._duration = max(0.0, duration)
            self._state = .ready
        case .url(let url):
            self._state = .loading
            #if canImport(AVFoundation)
            let asset = AVURLAsset(url: url)
            self.avAsset = asset
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            self.imageGenerator = gen
            if FileManager.default.fileExists(atPath: url.path) {
                self._state = .ready
            }
            #else
            _ = url
            self._state = .failed("AVFoundation unavailable")
            #endif
        }
    }

    public var state: VideoPlayerState { lock.withLock { _state } }
    public var currentTime: Double { lock.withLock { _currentTime } }
    public var duration: Double { lock.withLock { _duration } }
    public var isLooping: Bool { lock.withLock { _isLooping } }
    public var isMuted: Bool { lock.withLock { _isMuted } }
    public var volume: Float { lock.withLock { _volume } }
    public var rate: Float { lock.withLock { _rate } }
    public var naturalSize: Vec2 { lock.withLock { _naturalSize } }

    public var timecodeString: String {
        let (t, fps) = lock.withLock { (_currentTime, _fps) }
        let clamped = max(0.0, t)
        let totalSeconds = Int(clamped)
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        let frame = Int((clamped - Double(totalSeconds)) * fps)
        return String(format: "%02d:%02d:%02d:%02d", hours, mins, secs, frame)
    }

    public func play() {
        lock.withLock {
            if case .failed = _state { return }
            if _state == .ended {
                _currentTime = 0
            }
            _state = .playing
        }
    }

    public func pause() {
        lock.withLock {
            if _state == .playing {
                _state = .paused
            }
        }
    }

    public func togglePlayPause() {
        lock.withLock {
            if _state == .playing {
                _state = .paused
            } else if _state == .ready || _state == .paused || _state == .ended {
                if _state == .ended { _currentTime = 0 }
                _state = .playing
            }
        }
    }

    public func seek(toSeconds seconds: Double) {
        lock.withLock {
            let dur = _duration
            _currentTime = dur > 0 ? min(max(0.0, seconds), dur) : max(0.0, seconds)
            if _state == .ended && (_duration == 0 || _currentTime < _duration) {
                _state = .paused
            }
        }
    }

    public func setLooping(_ looping: Bool) {
        lock.withLock { _isLooping = looping }
    }

    public func setMuted(_ muted: Bool) {
        lock.withLock { _isMuted = muted }
    }

    public func setVolume(_ volume: Float) {
        lock.withLock { _volume = volume.clamped(to: 0...1) }
    }

    public func setRate(_ rate: Float) {
        lock.withLock { _rate = max(0.0, rate) }
    }

    /// Advances playback by `deltaSeconds` (if `.playing`) and returns the current video frame.
    @discardableResult
    public func advance(by deltaSeconds: Double) -> VideoPixelFrame? {
        let t: Double = lock.withLock {
            if _state == .playing && deltaSeconds > 0 {
                _currentTime += deltaSeconds * Double(_rate)
                if _duration > 0 && _currentTime >= _duration {
                    if _isLooping {
                        _currentTime = _currentTime.truncatingRemainder(dividingBy: _duration)
                    } else {
                        _currentTime = _duration
                        _state = .ended
                    }
                }
            }
            return _currentTime
        }
        return frame(at: t)
    }

    /// Extracts or synthesizes a video frame at `timeSeconds`.
    public func frame(at timeSeconds: Double) -> VideoPixelFrame? {
        switch source {
        case .synthetic(let pattern, let w, let h, let fps, _):
            return Self.renderSyntheticFrame(pattern: pattern, width: w, height: h, fps: fps, timeSeconds: timeSeconds)
        case .url:
            #if canImport(AVFoundation) && canImport(CoreGraphics)
            guard let gen = imageGenerator else { return nil }
            let cmTime = CMTime(seconds: max(0.0, timeSeconds), preferredTimescale: 600)
            guard let cgImg = try? gen.copyCGImage(at: cmTime, actualTime: nil) else {
                return nil
            }
            let w = cgImg.width
            let h = cgImg.height
            guard w > 0, h > 0 else { return nil }
            var rgba = Data(count: w * h * 4)
            let cs = CGColorSpaceCreateDeviceRGB()
            let bi = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            let ok = rgba.withUnsafeMutableBytes { ptr -> Bool in
                guard let base = ptr.baseAddress,
                      let ctx = CGContext(
                          data: base,
                          width: w,
                          height: h,
                          bitsPerComponent: 8,
                          bytesPerRow: w * 4,
                          space: cs,
                          bitmapInfo: bi.rawValue
                      ) else {
                    return false
                }
                ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            return VideoPixelFrame(
                width: UInt32(w),
                height: UInt32(h),
                rgba: rgba,
                timeSeconds: timeSeconds,
                frameIndex: UInt64(max(0.0, timeSeconds) * _fps)
            )
            #else
            return nil
            #endif
        }
    }

    public static func renderSyntheticFrame(
        pattern: SyntheticVideoPattern,
        width: UInt32,
        height: UInt32,
        fps: Double,
        timeSeconds: Double
    ) -> VideoPixelFrame {
        let w = max(1, Int(width))
        let h = max(1, Int(height))
        let frameIdx = UInt64(max(0.0, timeSeconds) * max(1.0, fps))
        var rgba = Data(count: w * h * 4)
        let phase = timeSeconds * 2.0

        rgba.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt8.self)
            for y in 0..<h {
                let ny = Double(y) / Double(h)
                for x in 0..<w {
                    let nx = Double(x) / Double(w)
                    let idx = (y * w + x) * 4
                    var r: UInt8 = 0
                    var g: UInt8 = 0
                    var b: UInt8 = 0

                    switch pattern {
                    case .colorBars:
                        let shifted = (nx + timeSeconds * 0.25).truncatingRemainder(dividingBy: 1.0)
                        let bar = Int(shifted * 7.0) % 7
                        let palette: [(UInt8, UInt8, UInt8)] = [
                            (235, 235, 235), (235, 235, 16), (16, 235, 235),
                            (16, 235, 16), (235, 16, 235), (235, 16, 16), (16, 16, 235),
                        ]
                        (r, g, b) = palette[bar]
                    case .movingChecker:
                        let cx = Int((Double(x) + timeSeconds * 48.0) / 16.0)
                        let cy = Int((Double(y) + timeSeconds * 24.0) / 16.0)
                        let even = ((cx + cy) & 1) == 0
                        r = even ? 230 : 32
                        g = even ? 235 : 38
                        b = even ? 245 : 48
                    case .plasmaWave:
                        let v1 = sin(nx * 6.0 + phase)
                        let v2 = cos(ny * 6.0 - phase * 0.8)
                        let v3 = sin((nx + ny) * 4.0 + phase * 0.5)
                        let v = (v1 + v2 + v3) / 3.0
                        r = UInt8(clamping: Int((0.5 + 0.5 * sin(v * .pi)) * 255.0))
                        g = UInt8(clamping: Int((0.5 + 0.5 * sin(v * .pi + 2.094)) * 255.0))
                        b = UInt8(clamping: Int((0.5 + 0.5 * sin(v * .pi + 4.188)) * 255.0))
                    case .timecodeGrid:
                        let border = (x % 32 == 0) || (y % 32 == 0)
                        let scanX = Int((timeSeconds * 0.5).truncatingRemainder(dividingBy: 1.0) * Double(w))
                        if abs(x - scanX) <= 1 {
                            r = 255; g = 96; b = 64
                        } else if border {
                            r = 64; g = 180; b = 255
                        } else {
                            r = 18; g = 24; b = 34
                        }
                    }
                    dst[idx] = r
                    dst[idx + 1] = g
                    dst[idx + 2] = b
                    dst[idx + 3] = 255
                }
            }
        }
        return VideoPixelFrame(width: UInt32(w), height: UInt32(h), rgba: rgba, timeSeconds: timeSeconds, frameIndex: frameIdx)
    }

    #if canImport(Metal)
    public static func uploadToTexture(device: MTLDevice, frame: VideoPixelFrame, existing: MTLTexture? = nil) -> MTLTexture? {
        let w = Int(frame.width)
        let h = Int(frame.height)
        let tex: MTLTexture
        if let existing, existing.width == w, existing.height == h {
            tex = existing
        } else {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm_srgb,
                width: w,
                height: h,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            guard let created = device.makeTexture(descriptor: desc) else { return nil }
            tex = created
        }
        frame.rgba.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            tex.replace(
                region: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: w * 4
            )
        }
        return tex
    }
    #endif
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
