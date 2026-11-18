import Foundation
#if canImport(CRuneMedia)
import Dispatch
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
#if os(visionOS)
import os
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
        self.durationSeconds = durationSeconds.isFinite ? max(0.01, durationSeconds) : 0.1
    }

    /// Browsers present an encoded delay of 10 ms or less for 100 ms.
    internal init(decodedWidth width: UInt32, height: UInt32, rgba: Data, durationSeconds: Double) {
        self.init(width: width, height: height, rgba: rgba,
                  durationSeconds: durationSeconds <= 0.01 ? 0.1 : durationSeconds)
    }
}

/// Decoded image with full mipmap chain and optional animation frames.
public struct DecodedImage: Sendable, Equatable {
    public let id: String
    public let width: UInt32
    public let height: UInt32
    public let mips: [ImageMipLevel]
    public let frames: [AnimatedImageFrame]
    /// Total plays, with zero denoting continuous playback.
    public let loopCount: Int
    private let frameEnds: [Double]
    private let laterMips: [[ImageMipLevel]]

    public var isAnimated: Bool { frames.count > 1 }

    public var totalAnimationDuration: Double {
        frameEnds.last ?? 0
    }

    fileprivate var cacheByteCost: Int {
        let mipBytes = mips.reduce(0) { $0 + $1.rgba.count }
        let frameBytes = frames.reduce(0) { $0 + $1.rgba.count }
        return laterMips.reduce(mipBytes + frameBytes) { total, chain in
            chain.reduce(total) { $0 + $1.rgba.count }
        }
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
        // Hold the composited straight frames for UI clients and the prefiltered
        // chains for the atlas. Large animations retain just their first frame.
        var bytes: UInt64 = 0
        let canAnimate = frames.count > 1 && frames.allSatisfy { frame in
            guard let cost = Self.animationStorage(width: frame.width, height: frame.height),
                  UInt64(frame.rgba.count) == UInt64(frame.width) * UInt64(frame.height) * 4 else { return false }
            bytes += cost
            return bytes <= UInt64(LinearMipGenerator.maxDecodedBytes)
        }
        self.frames = canAnimate || frames.count <= 1 ? frames : Array(frames.prefix(1))
        if mips.isEmpty, let first = self.frames.first,
           first.width <= IMAGE_MAX_SIDE, first.height <= IMAGE_MAX_SIDE {
            self.mips = Self.generateMipChain(width: first.width, height: first.height, rgba: first.rgba)
        } else {
            self.mips = mips
        }
        self.laterMips = self.frames.dropFirst().map {
            Self.generateMipChain(width: $0.width, height: $0.height, rgba: $0.rgba)
        }
        var end = 0.0
        self.frameEnds = self.frames.map {
            end += $0.durationSeconds
            return end
        }
        self.loopCount = loopCount
    }

    /// The raw RGBA canvas and its premultiplied mip chain, including level zero.
    internal static func animationStorage(width: UInt32, height: UInt32) -> UInt64? {
        guard width > 0, height > 0, width <= IMAGE_MAX_SIDE, height <= IMAGE_MAX_SIDE else { return nil }
        var w = UInt64(width), h = UInt64(height)
        var bytes = w * h * 4
        while true {
            bytes += w * h * 4
            if w == 1 && h == 1 { return bytes }
            w = max(1, w / 2)
            h = max(1, h / 2)
        }
    }

    internal func mips(forFrame index: Int) -> [ImageMipLevel] {
        index == 0 ? mips : laterMips[index - 1]
    }

    internal func framePosition(at now: Double, startingAt origin: Double) -> (index: Int, next: Double?) {
        guard frames.count > 1 else { return (0, nil) }
        let last = frames.count - 1
        let period = totalAnimationDuration
        guard now.isFinite, origin.isFinite, period.isFinite, period > 0 else { return (0, nil) }
        let time = max(now, origin)
        var cycle = ((time - origin) / period).rounded(.down)
        // Compare absolute timestamps; subtracting the origin can round a
        // just-delivered frame deadline back into the previous frame.
        if origin + cycle * period > time { cycle -= 1 }
        else if origin + (cycle + 1) * period <= time { cycle += 1 }
        if loopCount > 0 && cycle >= Double(loopCount) { return (last, nil) }
        let base = origin + cycle * period
        var lo = 0, hi = last
        while lo < hi {
            let mid = (lo + hi) / 2
            if base + frameEnds[mid] <= time { lo = mid + 1 }
            else { hi = mid }
        }
        if lo == last && loopCount > 0 && cycle + 1 >= Double(loopCount) { return (last, nil) }
        let next = lo == last ? origin + (cycle + 1) * period : base + frameEnds[lo]
        return (lo, next > time ? next : nil)
    }

    /// Selects a frame on the playback timeline. Negative times wrap within one play.
    public func frame(at elapsedSeconds: Double) -> AnimatedImageFrame? {
        guard !frames.isEmpty else { return nil }
        guard elapsedSeconds.isFinite else { return frames.last }
        var time = elapsedSeconds
        if time < 0, totalAnimationDuration > 0 {
            time = time.truncatingRemainder(dividingBy: totalAnimationDuration)
            if time < 0 { time += totalAnimationDuration }
        }
        return frames[framePosition(at: time, startingAt: 0).index]
    }

    /// Generates a full linear-light area-resampled mipmap chain from an RGBA8 image.
    public static func generateMipChain(width: UInt32, height: UInt32, rgba: Data) -> [ImageMipLevel] {
        LinearMipGenerator.generateChain(width: width, height: height, straightRGBA: rgba)
    }

    /// Decodes an image using the host's codecs and builds its GPU mip chain.
    public static func decode(data: Data, id: String = UUID().uuidString, maxDimension: Int? = nil) throws -> DecodedImage {
        // Rune's native SVG renderer reads vector shapes from the supplied bytes. The
        // platform's general-purpose image loader may resolve additional image resources.
        if ImageCache.isSVGContent(data) {
            do {
                return try ImageCache.decodeSVGThumbnail(data, id: id, maxDimension: maxDimension)
            } catch let error as ImageLoadError {
                throw ImageError(error.message)
            }
        }
        #if !canImport(ImageIO) || !canImport(CoreGraphics)
        if let animation = try AnimatedPNG.decodeIfAnimated(data, id: id, maxDimension: maxDimension) {
            return animation
        }
        #endif
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
            if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                loopCount = gif[kCGImagePropertyGIFLoopCount] as? Int ?? 1
            } else if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any],
                      let lc = png[kCGImagePropertyAPNGLoopCount] as? Int {
                loopCount = lc
            } else if let webp = props[kCGImagePropertyWebPDictionary] as? [CFString: Any],
                      let lc = webp[kCGImagePropertyWebPLoopCount] as? Int {
                loopCount = lc
            } else if let heics = props[kCGImagePropertyHEICSDictionary] as? [CFString: Any],
                      let lc = heics[kCGImagePropertyHEICSLoopCount] as? Int {
                loopCount = lc
            }
        }

        var frames: [AnimatedImageFrame] = []
        var animationBytes: UInt64 = 0
        var thumbnailLimit = maxDimension.flatMap { $0 > 0 ? $0 : nil }
        if thumbnailLimit == nil, count == 1,
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let orientation = props[kCGImagePropertyOrientation] as? Int, (2...8).contains(orientation),
           let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int {
            // ImageIO's thumbnail transform also applies EXIF rotations and
            // reflections when the requested size is the original size.
            thumbnailLimit = max(width, height)
        }
        for idx in 0..<count {
            let cgImg: CGImage?
            if let limit = thumbnailLimit {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: limit,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
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
            if count > 1, let cost = animationStorage(width: UInt32(w), height: UInt32(h)) {
                animationBytes += cost
                if animationBytes > UInt64(LinearMipGenerator.maxDecodedBytes), let first = frames.first {
                    frames = [first]
                    break
                }
            }

            let rgba = try straightRGBA(img, byteCount: byteCount)
            let delay = frameDelaySeconds(source: source, index: idx)
            frames.append(AnimatedImageFrame(decodedWidth: UInt32(w), height: UInt32(h), rgba: rgba, durationSeconds: delay))
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
        #elseif canImport(CRuneDesktopImages) && !os(Android)
        return try DesktopImageCodec.decode(data, id: id, maxDimension: maxDimension)
        #else
        #if os(Android) && canImport(CRuneDesktopImages)
        do {
            return try DesktopImageCodec.decode(data, id: id, maxDimension: maxDimension)
        } catch where data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
            // Android 24–29 can decode a portable PNG before a Java activity attaches.
        }
        #endif
        let decoded: PortablePNG.DecodedImage
        do {
            decoded = try PortablePNG.decode(data, maxDimension: LinearMipGenerator.maxDecodeDimension)
        } catch {
            throw ImageError("Could not decode image: \(error)")
        }
        let size = ImageThumbnail.size(width: decoded.width, height: decoded.height, maxDimension: maxDimension)
        let rgba = ImageThumbnail.resize(Data(decoded.rgba), width: decoded.width, height: decoded.height, to: size)
        let w = UInt32(size.width), h = UInt32(size.height)
        return DecodedImage(id: id, width: w, height: h, mips: generateMipChain(width: w, height: h, rgba: rgba),
                            frames: [AnimatedImageFrame(width: w, height: h, rgba: rgba, durationSeconds: 0.1)])
        #endif
    }

    #if canImport(ImageIO)
    private static func straightRGBA(_ img: CGImage, byteCount: Int) throws -> Data {
        let w = img.width, h = img.height
        let byteOrder = img.bitmapInfo.intersection(.byteOrderMask)
        // ImageIO supplies many GIF, PNG, and WebP frames as straight sRGB.
        // Keep those bytes intact, including color at very low alpha.
        if img.bitsPerComponent == 8, img.bitsPerPixel == 32, img.alphaInfo == .last,
           img.bytesPerRow == w * 4, byteOrder.isEmpty || byteOrder == .byteOrder32Big,
           img.colorSpace?.name == CGColorSpace.sRGB, img.decode == nil,
           let bytes = img.dataProvider?.data, CFDataGetLength(bytes) == byteCount {
            return bytes as Data
        }
        var rgba = Data(count: byteCount)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
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
        guard drawn else { throw ImageError("failed to rasterize frame") }

        // CGContext writes premultiplied bytes. The public frames and the
        // input of the linear-light mip generator both use straight RGBA.
        rgba.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let alpha = Int(bytes[offset + 3])
                if alpha == 0 || alpha == 255 { continue }
                for channel in offset..<(offset + 3) {
                    bytes[channel] = UInt8(clamping: (Int(bytes[channel]) * 255 + alpha / 2) / alpha)
                }
            }
        }
        return rgba
    }

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
        if let webp = props[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            if let delay = webp[kCGImagePropertyWebPUnclampedDelayTime] as? Double, delay > 0 { return delay }
            if let delay = webp[kCGImagePropertyWebPDelayTime] as? Double, delay > 0 { return delay }
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
        let cost = image.cacheByteCost
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
        #if os(WASI)
        let decoded: DecodedImage
        if BrowserImageCodec.enabled {
            decoded = try await withCheckedThrowingContinuation { continuation in
                BrowserImageCodec.submit(.bytes(data), name: key, limit: maxDimension) {
                    continuation.resume(with: $0)
                }
            }
        } else {
            decoded = try DecodedImage.decode(data: data, id: key, maxDimension: maxDimension)
        }
        #else
        let decoded = try await Task.detached(priority: .userInitiated) {
            try DecodedImage.decode(data: data, id: key, maxDimension: maxDimension)
        }.value
        #endif
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
        #if os(WASI)
        guard BrowserImageCodec.enabled else { throw ImageLoadError("URL loading requires a browser host") }
        let image: DecodedImage = try await withCheckedThrowingContinuation { continuation in
            BrowserImageCodec.submit(.thumbnailURL(url.absoluteString), name: key, limit: maxDimension) {
                continuation.resume(with: $0)
            }
        }
        insert(image, forKey: key)
        return image
        #else
        let (data, _) = try await URLSession.shared.data(from: url)
        return try await decode(data: data, key: key, maxDimension: maxDimension)
        #endif
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

/// A clock-driven video source for frame extraction and procedural test patterns.
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
    #elseif canImport(CRuneMedia)
    private var desktopDecoder: DesktopMediaDecoder?
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
            #elseif canImport(CRuneMedia)
            if url.isFileURL {
                openDesktopDecoder(url)
            } else {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.openDesktopDecoder(url)
                }
            }
            #else
            _ = url
            self._state = .failed("Native video decoding is unavailable in this build")
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
            #if os(visionOS)
            // The synchronous frame API waits for the image generator's individual
            // completion. Each simultaneous request owns its result and signal.
            let result = OSAllocatedUnfairLock(initialState: CGImage?.none)
            let completed = DispatchSemaphore(value: 0)
            gen.generateCGImageAsynchronously(for: cmTime) { image, _, _ in
                result.withLock { $0 = image }
                completed.signal()
            }
            completed.wait()
            guard let cgImg = result.withLock({ $0 }) else { return nil }
            #else
            guard let cgImg = try? gen.copyCGImage(at: cmTime, actualTime: nil) else {
                return nil
            }
            #endif
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
            #elseif canImport(CRuneMedia)
            guard let decoder = lock.withLock({ desktopDecoder }), timeSeconds.isFinite else { return nil }
            let seconds = max(0, min(timeSeconds, decoder.meta.duration ?? timeSeconds))
            do {
                guard case .bytes(let frame)? = try decoder.frame(at: seconds) else { return nil }
                let index = UInt64(clamping: decoder.meta.frameIndex(at: seconds))
                return Self.uprightFrame(frame, orientation: decoder.orient, time: seconds, index: index)
            } catch {
                lock.withLock { _state = .failed(String(describing: error)) }
                return nil
            }
            #else
            return nil
            #endif
        }
    }

    #if canImport(CRuneMedia)
    private func openDesktopDecoder(_ url: URL) {
        do {
            let asset = try DesktopMediaSource(request: MediaRequest(source: .url(url)))
            let decoder = try DesktopMediaDecoder(source: asset, kind: .video, headless: true, packedRGB: true)
            guard let (width, height) = decoder.meta.size else {
                lock.withLock { _state = .failed("Media has no playable video track") }
                return
            }
            lock.withLock {
                desktopDecoder = decoder
                _naturalSize = Vec2(Float(width), Float(height))
                _duration = decoder.meta.duration ?? 0
                _fps = 1 / decoder.meta.frameDuration
                if _duration > 0 { _currentTime = min(_currentTime, _duration) }
                if _state == .loading { _state = .ready }
            }
        } catch {
            lock.withLock { _state = .failed(String(describing: error)) }
        }
    }

    /// The decoder supplies tightly packed BGRA and its remaining rotation. The public
    /// VideoPixelFrame contract uses upright RGBA, as does AVAssetImageGenerator.
    private static func uprightFrame(_ frame: ByteFrame, orientation o: Orient,
                                     time: Double, index: UInt64) -> VideoPixelFrame {
        let (width, height) = o.upright(width: frame.width, height: frame.height)
        let sourceWidth = Int(frame.width)
        let originX = min(o.m00, o.m01) < 0 ? sourceWidth - 1 : 0
        let originY = min(o.m10, o.m11) < 0 ? Int(frame.height) - 1 : 0
        let origin = 4 * (originY * sourceWidth + originX)
        let stepX = 4 * (Int(o.m00) + Int(o.m10) * sourceWidth)
        let stepY = 4 * (Int(o.m01) + Int(o.m11) * sourceWidth)
        var rgba = Data(count: frame.planes[0].count)
        frame.planes[0].withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            rgba.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                var dst = 0
                for y in 0..<Int(height) {
                    var src = origin + y * stepY
                    for _ in 0..<width {
                        output[dst] = source[src + 2]
                        output[dst + 1] = source[src + 1]
                        output[dst + 2] = source[src]
                        output[dst + 3] = source[src + 3]
                        src += stepX
                        dst += 4
                    }
                }
            }
        }
        return VideoPixelFrame(width: width, height: height, rgba: rgba, timeSeconds: time, frameIndex: index)
    }
    #endif

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
