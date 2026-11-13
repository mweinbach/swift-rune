import Foundation
import CryptoKit
#if canImport(simd)
import simd
#endif

// MARK: - 1. Image Constants, ImageId, Animation Loop Bound & URL Set (`image.rs`, `from_url.rs`, `animated.rs`)

/// Default shelf atlas page dimension (`rune::image::pixels::IMAGE_ATLAS_SIZE`).
public let IMAGE_ATLAS_SIZE: UInt32 = 1024

/// Maximum image dimension supported by mip generation and image atlas placement (`8192`).
public let IMAGE_MAX_SIDE: UInt32 = 8192

/// SHA-256 content-addressable image identity (`rune::ImageId`, 32-byte digest).
public struct ImageId: Hashable, Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32, "ImageId requires 32 bytes")
        self.bytes = bytes
    }

    public static func contentHash(_ data: Data) -> ImageId {
        let digest = SHA256.hash(data: data)
        return ImageId(bytes: Array(digest))
    }

    public static func forURL(_ url: String, pixelSize: UInt32) -> ImageId {
        var payload = Data("rune-url\0".utf8)
        payload.append(Data(url.utf8))
        payload.append(0)
        var le = pixelSize.littleEndian
        withUnsafeBytes(of: &le) { payload.append(contentsOf: $0) }
        return contentHash(payload)
    }

    public static func forURLSet(selectedURL: String, srcset: String) -> ImageId {
        var payload = Data("rune-url-set\0".utf8)
        payload.append(Data(selectedURL.utf8))
        payload.append(0)
        payload.append(Data(srcset.utf8))
        return contentHash(payload)
    }
}

/// Source entry for responsive `ImageCache.urlSet` selection (`rune::image::from_url`).
public enum ImageURLSet {
    public struct Source: Equatable, Sendable {
        public var url: String
        public var widthPixels: UInt32

        public init(url: String, widthPixels: UInt32) {
            self.url = url
            self.widthPixels = widthPixels
        }
    }

    /// Selects the narrowest source `>= ceil(sizePt * scale)`, or the widest available (`from_url::url_set`).
    public static func select(
        sources: [Source],
        sizePt: Float,
        scale: Float
    ) -> (selected: Source, srcset: String, id: ImageId)? {
        guard !sources.isEmpty else { return nil }
        let sorted = sources.sorted { $0.widthPixels < $1.widthPixels }
        let needed = (sizePt * max(1.0, scale)).rounded(.up)
        let chosen = sorted.first { Float($0.widthPixels) >= needed } ?? sorted.last!
        let srcset = sorted.map { "\($0.url) \($0.widthPixels)w" }.joined(separator: ", ")
        let id = ImageId.forURLSet(selectedURL: chosen.url, srcset: srcset)
        return (chosen, srcset, id)
    }
}

extension DecodedImage {
    /// Selects the animated frame at `elapsedSeconds`, honoring `loopCount > 0` (`D-G2`, `animated::Motion::at`).
    public func frameStoppingAfterLoops(at elapsedSeconds: Double) -> AnimatedImageFrame? {
        guard !frames.isEmpty else { return nil }
        if frames.count == 1 { return frames[0] }
        let total = totalAnimationDuration
        guard total > 0 else { return frames[0] }
        if elapsedSeconds <= 0 { return frames[0] }
        if loopCount > 0 && elapsedSeconds >= total * Double(loopCount) {
            return frames.last
        }
        var t = elapsedSeconds.truncatingRemainder(dividingBy: total)
        if t < 0 { t += total }
        var acc = 0.0
        for f in frames {
            acc += f.durationSeconds
            if t < acc { return f }
        }
        return frames.last
    }
}

// MARK: - 2. Streaming Pixel Buffer & Shelf ImageAtlas (`rune::image::pixels`)

/// Streamable per-frame RGBA8 image buffer (`rune::Pixels`).
public final class Pixels: @unchecked Sendable {
    private final class IDGenerator: @unchecked Sendable {
        let lock = NSLock()
        var next: UInt64 = 1
        func take() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            let value = next
            next &+= 1
            return value
        }
    }
    private static let idGenerator = IDGenerator()

    public let id: UInt64
    private let lock = NSLock()
    private var widthValue: UInt32 = 0
    private var heightValue: UInt32 = 0
    private var rgbaData: [UInt8] = []
    private var decodedMips: DecodedImage?
    private var generationValue: UInt64 = 0
    private var wakers: [WeakWaker] = []
    private var subscriptions: [LiveSubscription] = []
    internal var cacheRetainOwner: AnyObject?
    public private(set) var sourceURLString: String?
    public private(set) var sourceSetString: String?

    private struct WeakWaker {
        weak var ref: Waker?
    }

    public init() {
        self.id = Self.idGenerator.take()
    }

    public func setSourceURL(_ url: String) {
        lock.lock()
        sourceURLString = url
        lock.unlock()
    }

    public func setSourceSet(_ srcset: String) {
        lock.lock()
        sourceSetString = srcset
        lock.unlock()
    }

    /// Replaces the frame contents with straight-alpha RGBA8 pixels (`Pixels::set`).
    /// Ignores payloads shorter than `width * height * 4` or oversized frames (`> 8192`).
    public func set(width: UInt32, height: UInt32, rgba: [UInt8]) {
        let needed = Int(width) * Int(height) * 4
        guard width > 0, height > 0, width <= IMAGE_MAX_SIDE, height <= IMAGE_MAX_SIDE, rgba.count >= needed else {
            return
        }
        var toWake: [Waker] = []
        var wakesToNotify: [LiveWake] = []
        lock.lock()
        widthValue = width
        heightValue = height
        rgbaData = rgba.count == needed ? rgba : Array(rgba.prefix(needed))
        decodedMips = nil
        generationValue &+= 1
        wakers.removeAll { $0.ref == nil }
        toWake = wakers.compactMap(\.ref)
        subscriptions.removeAll { $0.wake == nil }
        wakesToNotify = subscriptions.compactMap { sub in
            guard sub.isActive, let w = sub.wake else { return nil }
            return w
        }
        lock.unlock()
        for w in toWake { w.wake() }
        for w in wakesToNotify { w.notify() }
    }

    public func setDecoded(_ image: DecodedImage) {
        guard let base = image.mips.first else { return }
        var toWake: [Waker] = []
        var wakesToNotify: [LiveWake] = []
        lock.lock()
        widthValue = base.width
        heightValue = base.height
        rgbaData = Array(base.rgba)
        decodedMips = image
        generationValue &+= 1
        wakers.removeAll { $0.ref == nil }
        toWake = wakers.compactMap(\.ref)
        subscriptions.removeAll { $0.wake == nil }
        wakesToNotify = subscriptions.compactMap { sub in
            guard sub.isActive, let w = sub.wake else { return nil }
            return w
        }
        lock.unlock()
        for w in toWake { w.wake() }
        for w in wakesToNotify { w.notify() }
    }

    public func subscribe(_ waker: Waker) {
        lock.lock()
        wakers.removeAll { $0.ref == nil }
        if !wakers.contains(where: { $0.ref === waker }) {
            wakers.append(WeakWaker(ref: waker))
        }
        lock.unlock()
    }

    public func subscribe(_ wake: LiveWake) -> LiveSubscription {
        lock.lock()
        subscriptions.removeAll { !$0.isActive || $0.wake == nil }
        if let existing = subscriptions.first(where: { $0.wake === wake }) {
            lock.unlock()
            return existing
        }
        let sub = LiveSubscription(sourceId: id, wake: wake)
        subscriptions.append(sub)
        lock.unlock()
        return sub
    }

    public var size: (width: UInt32, height: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        return (widthValue, heightValue)
    }

    public var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generationValue
    }

    public func rgbaBytes() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return rgbaData
    }

    public var isPremultiplied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return decodedMips != nil
    }

    fileprivate func snapshot() -> (width: UInt32, height: UInt32, rgba: [UInt8], mips: DecodedImage?, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (widthValue, heightValue, rgbaData, decodedMips, generationValue)
    }
}

/// One shelf-packed or standalone RGBA8 atlas page (`rune::image::pixels::ImagePage`).
public struct ImagePage: Sendable {
    public var width: UInt32
    public var height: UInt32
    public var data: [UInt8]
    public var dirty: Range<UInt32>?
    var shelfX: UInt32 = 0
    var shelfY: UInt32 = 0
    var shelfH: UInt32 = 0
    var shown: Bool = false
    var touched: Bool = false

    public init(width: UInt32, height: UInt32) {
        let w = (width > IMAGE_ATLAS_SIZE || height > IMAGE_ATLAS_SIZE) ? width : IMAGE_ATLAS_SIZE
        let h = (width > IMAGE_ATLAS_SIZE || height > IMAGE_ATLAS_SIZE) ? height : IMAGE_ATLAS_SIZE
        self.width = w
        self.height = h
        self.data = [UInt8](repeating: 0, count: Int(w) * Int(h) * 4)
        self.dirty = nil
    }

    mutating func allocate(width w: UInt32, height h: UInt32) -> (UInt32, UInt32)? {
        guard w <= width, h <= height else { return nil }
        if shelfX + w > width {
            shelfY += shelfH
            shelfX = 0
            shelfH = 0
        }
        guard shelfY + h <= height else { return nil }
        let at = (shelfX, shelfY)
        shelfX += w
        shelfH = max(shelfH, h)
        return at
    }
}

/// Placement result inside `ImageAtlas` (`rune::image::pixels::Placed`).
public struct PlacedImage: Equatable, Sendable {
    public var rect: SIMD4<UInt32>
    public var page: Int
    public var premultiplied: Bool

    public init(rect: SIMD4<UInt32>, page: Int, premultiplied: Bool) {
        self.rect = rect
        self.page = page
        self.premultiplied = premultiplied
    }
}

/// Multi-page shelf-packed GPU upload atlas for `Pixels` and decoded mipmaps (`rune::image::pixels::ImageAtlas`).
public struct ImageAtlas: Sendable {
    private struct SlotKey: Hashable, Sendable {
        var pixelsID: UInt64
        var level: Int
    }

    private struct Slot: Sendable {
        var page: Int
        var x: UInt32
        var y: UInt32
        var w: UInt32
        var h: UInt32
        var generation: UInt64
        var frameIndex: Int
    }

    public var pages: [ImagePage] = []
    private var slots: [SlotKey: Slot] = [:]
    private var starts: [UInt64: Double] = [:]
    public private(set) var copies: UInt64 = 0

    public init() {}

    /// Places `pixels` for `drawnSize` (device pixels), copying bytes on first use or generation change.
    public mutating func place(_ pixels: Pixels, drawnSize: SIMD2<Float>, at now: Double? = nil) -> PlacedImage? {
        let snap = pixels.snapshot()
        var w = snap.width
        var h = snap.height
        guard w > 0, h > 0, w <= IMAGE_MAX_SIDE, h <= IMAGE_MAX_SIDE else { return nil }

        var level = 0
        let sourceBytes: [UInt8]
        let isPremultiplied: Bool
        if let decoded = snap.mips, !decoded.mips.isEmpty {
            isPremultiplied = true
            while level + 1 < decoded.mips.count {
                let next = decoded.mips[level + 1]
                let minW = min(max(1.0, drawnSize.x), Float(snap.width))
                let minH = min(max(1.0, drawnSize.y), Float(snap.height))
                if Float(next.width) < minW || Float(next.height) < minH { break }
                level += 1
            }
            let mip = decoded.mips[level]
            w = mip.width
            h = mip.height
            sourceBytes = Array(mip.rgba)
        } else {
            isPremultiplied = false
            sourceBytes = snap.rgba
        }
        guard sourceBytes.count >= Int(w) * Int(h) * 4 else { return nil }

        let key = SlotKey(pixelsID: pixels.id, level: level)
        if let existing = slots[key], existing.w != w || existing.h != h {
            slots.removeValue(forKey: key)
        }
        if slots[key] == nil {
            let (pageIdx, sx, sy) = allocate(width: w, height: h)
            slots[key] = Slot(page: pageIdx, x: sx, y: sy, w: w, h: h, generation: 0, frameIndex: -1)
        }
        guard var slot = slots[key] else { return nil }
        pages[slot.page].touched = true

        if slot.generation != snap.generation {
            slot.generation = snap.generation
            slot.frameIndex = 0
            slots[key] = slot
            copies &+= 1
            let pageRowBytes = Int(pages[slot.page].width) * 4
            let copyRowBytes = Int(w) * 4
            for line in 0..<Int(h) {
                let dstStart = (Int(slot.y) + line) * pageRowBytes + Int(slot.x) * 4
                let srcStart = line * copyRowBytes
                pages[slot.page].data[dstStart..<(dstStart + copyRowBytes)] = sourceBytes[srcStart..<(srcStart + copyRowBytes)]
            }
            let y0 = slot.y
            let y1 = slot.y + h
            if let old = pages[slot.page].dirty {
                pages[slot.page].dirty = min(old.lowerBound, y0)..<max(old.upperBound, y1)
            } else {
                pages[slot.page].dirty = y0..<y1
            }
        }
        _ = now
        return PlacedImage(rect: SIMD4<UInt32>(slot.x, slot.y, w, h), page: slot.page, premultiplied: isPremultiplied)
    }

    public mutating func endFrame() {
        let firstKept = pages.first.map { $0.width <= IMAGE_ATLAS_SIZE && $0.height <= IMAGE_ATLAS_SIZE } ?? false
        slots = slots.filter { _, slot in
            pages[slot.page].touched || (slot.page == 0 && firstKept)
        }
        for i in pages.indices {
            pages[i].shown = pages[i].touched
            pages[i].touched = false
            let hasSlot = slots.values.contains { $0.page == i }
            if !hasSlot {
                pages[i].shelfX = 0
                pages[i].shelfY = 0
                pages[i].shelfH = 0
                pages[i].dirty = nil
                if pages[i].width > IMAGE_ATLAS_SIZE || pages[i].height > IMAGE_ATLAS_SIZE {
                    pages[i].data = []
                }
            }
        }
        let keepCount = (slots.values.map { $0.page + 1 }.max()) ?? 0
        if keepCount < pages.count {
            pages.removeSubrange(keepCount..<pages.count)
        }
    }

    public mutating func invalidate() {
        for i in pages.indices {
            pages[i].dirty = 0..<pages[i].height
        }
    }

    private mutating func allocate(width w: UInt32, height h: UInt32) -> (Int, UInt32, UInt32) {
        for i in pages.indices {
            if pages[i].data.isEmpty {
                pages[i] = ImagePage(width: w, height: h)
            }
            if let (x, y) = pages[i].allocate(width: w, height: h) {
                return (i, x, y)
            }
        }
        if w <= IMAGE_ATLAS_SIZE && h <= IMAGE_ATLAS_SIZE,
           let reuseIdx = pages.firstIndex(where: { !$0.shown && !$0.touched && $0.width <= IMAGE_ATLAS_SIZE && $0.height <= IMAGE_ATLAS_SIZE && $0.shelfY + $0.shelfH > 0 }) {
            slots = slots.filter { $0.value.page != reuseIdx }
            pages[reuseIdx].shelfX = 0
            pages[reuseIdx].shelfY = 0
            pages[reuseIdx].shelfH = 0
            if let (x, y) = pages[reuseIdx].allocate(width: w, height: h) {
                return (reuseIdx, x, y)
            }
        }
        var page = ImagePage(width: w, height: h)
        let (x, y) = page.allocate(width: w, height: h) ?? (0, 0)
        pages.append(page)
        return (pages.count - 1, x, y)
    }
}

private struct WeakPixelsWaker {
    weak var waker: Waker?
}
