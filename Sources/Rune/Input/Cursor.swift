import Foundation
#if os(macOS)
import AppKit
import ImageIO
#elseif canImport(ImageIO)
import ImageIO
#endif

/// The picture for `Cursor.image`: a PNG drawn at 2x scale (`CursorImage::png`, `input/cursor.rs:60`).
public struct CursorImage: Sendable, Hashable {
    public let bytes: [UInt8]
    public let hot: SIMD2<Float>
    internal let crisp: Bool

    public init(png bytes: [UInt8], hot: SIMD2<Float>, crisp: Bool = false) {
        self.bytes = bytes
        self.hot = hot
        self.crisp = crisp
    }

    public init(png data: Data, hot: SIMD2<Float>, crisp: Bool = false) {
        self.init(png: [UInt8](data), hot: hot, crisp: crisp)
    }

    public static func == (lhs: CursorImage, rhs: CursorImage) -> Bool {
        lhs.hot.x.bitPattern == rhs.hot.x.bitPattern
            && lhs.hot.y.bitPattern == rhs.hot.y.bitPattern
            && lhs.crisp == rhs.crisp
            && lhs.bytes == rhs.bytes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bytes)
        hasher.combine(hot.x.bitPattern)
        hasher.combine(hot.y.bitPattern)
        hasher.combine(crisp)
    }

    /// Reads PNG pixel dimensions from an IHDR header, or `nil` if malformed.
    public func pngSize() -> (width: Int, height: Int)? {
        guard bytes.count >= 24 else { return nil }
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard Array(bytes[0..<8]) == sig,
              bytes[12] == 0x49, bytes[13] == 0x48, bytes[14] == 0x44, bytes[15] == 0x52 else {
            return nil
        }
        func u32BE(_ offset: Int) -> Int {
            (Int(bytes[offset]) << 24)
                | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8)
                | Int(bytes[offset + 3])
        }
        return (u32BE(16), u32BE(20))
    }

    /// Validates that `bytes` holds complete PNG chunks (`IHDR`, `IDAT`, `IEND`) and decodes cleanly via ImageIO when available.
    public func isValidPNG() -> Bool {
        guard bytes.count >= 33, pngSize() != nil else { return false }
        var offset = 8
        var sawIDAT = false
        var sawIEND = false
        while offset + 12 <= bytes.count {
            let chunkLen = (Int(bytes[offset]) << 24)
                | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8)
                | Int(bytes[offset + 3])
            guard chunkLen >= 0, offset + 12 + chunkLen <= bytes.count else {
                return false
            }
            let t0 = bytes[offset + 4], t1 = bytes[offset + 5], t2 = bytes[offset + 6], t3 = bytes[offset + 7]
            if t0 == 0x49 && t1 == 0x44 && t2 == 0x41 && t3 == 0x54 { // IDAT
                sawIDAT = true
            } else if t0 == 0x49 && t1 == 0x45 && t2 == 0x4E && t3 == 0x44 { // IEND
                sawIEND = true
                break
            }
            offset += 12 + chunkLen
        }
        guard sawIDAT && sawIEND else { return false }
        #if canImport(ImageIO)
        let data = Data(bytes)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            return false
        }
        #endif
        return true
    }

    internal static func clampedHotInt(_ value: Float, limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        if value.isNaN { return 0 }
        if !value.isFinite { return value > 0 ? limit : 0 }
        let floored = floorf(max(0, value))
        if floored >= Float(limit) { return limit }
        return max(0, Int(floored))
    }

    internal static func clampedHotFloat(_ value: Float, limit: Float) -> Float {
        guard limit > 0 else { return 0 }
        if value.isNaN { return 0 }
        if !value.isFinite { return value > 0 ? limit : 0 }
        return min(max(0, value), limit)
    }

    /// Decodes dimensions (divided by 2x scale, min 1) and clamped hotspot (`image.rs:14`).
    public func decodedMetrics() throws -> (width: Int, height: Int, hot: SIMD2<Int>) {
        guard let (w, h) = pngSize(), isValidPNG() else {
            throw CursorImageError.notPNG
        }
        let maxSide = 256
        guard w > 0, h > 0, w <= maxSide, h <= maxSide else {
            throw CursorImageError.invalidDimensions(width: w, height: h, maxSide: maxSide)
        }
        let ptW = max(1, (w + 1) / 2)
        let ptH = max(1, (h + 1) / 2)
        let hx = Self.clampedHotInt(hot.x, limit: max(0, ptW - 1))
        let hy = Self.clampedHotInt(hot.y, limit: max(0, ptH - 1))
        return (ptW, ptH, SIMD2<Int>(hx, hy))
    }

    /// Clamps a hot spot in 2x-source points to `[0, sidePt - 1]` and formats a CSS `cursor` string.
    public func cssCursor(url: String) throws -> String {
        guard let (w, h) = pngSize() else {
            throw CursorImageError.notPNG
        }
        let maxSide = 256
        guard w > 0, h > 0, w <= maxSide, h <= maxSide else {
            throw CursorImageError.invalidDimensions(width: w, height: h, maxSide: maxSide)
        }
        let maxX = max(0, Int(ceil(Float(w) / 2.0)) - 1)
        let maxY = max(0, Int(ceil(Float(h) / 2.0)) - 1)
        let hx = Self.clampedHotInt(hot.x, limit: maxX)
        let hy = Self.clampedHotInt(hot.y, limit: maxY)
        return "image-set(url(\"\(url)\") 2x) \(hx) \(hy), auto"
    }
}

public enum CursorImageError: Error, Sendable, Equatable {
    case notPNG
    case invalidDimensions(width: Int, height: Int, maxSide: Int)
}

/// The pointer shape over an element (`rune::Cursor`, CSS `cursor`).
public enum Cursor: Sendable, Hashable {
    case `default`
    case pointer
    case text
    case grab
    case grabbing
    case notAllowed
    case move
    case resizeColumn
    case resizeRow
    case crosshair
    case cell
    case zoomIn
    case zoomOut
    case hidden
    case image(CursorImage)
}

#if os(macOS)
/// Resolves `Cursor` values into AppKit `NSCursor` instances (caching custom cursor images up to 32 entries).
@MainActor
public final class MacOSCursorCache {
    public static let shared = MacOSCursorCache()
    private static let maxEntries = 32
    private var cache: [CursorImage: NSCursor] = [:]
    private var order: [CursorImage] = []

    private init() {}

    public func cursor(for spec: Cursor) -> NSCursor {
        switch spec {
        case .default:
            return .arrow
        case .pointer:
            return .pointingHand
        case .text:
            return .iBeam
        case .grab:
            return .openHand
        case .grabbing:
            return .closedHand
        case .notAllowed:
            return .operationNotAllowed
        case .move:
            return .openHand
        case .resizeColumn:
            return .resizeLeftRight
        case .resizeRow:
            return .resizeUpDown
        case .crosshair:
            return .crosshair
        case .cell:
            return .crosshair
        case .zoomIn:
            if #available(macOS 10.15, *), let sel = NSSelectorFromString("_zoomInCursor") as Selector?,
               NSCursor.responds(to: sel),
               let cur = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor {
                return cur
            }
            return .arrow
        case .zoomOut:
            if #available(macOS 10.15, *), let sel = NSSelectorFromString("_zoomOutCursor") as Selector?,
               NSCursor.responds(to: sel),
               let cur = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor {
                return cur
            }
            return .arrow
        case .hidden:
            return transparentCursor()
        case .image(let img):
            return customCursor(for: img) ?? .arrow
        }
    }

    public func apply(_ spec: Cursor) {
        cursor(for: spec).set()
    }

    private func transparentCursor() -> NSCursor {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4,
            bitsPerPixel: 32
        )
        let img = NSImage(size: NSSize(width: 1, height: 1))
        if let rep {
            memset(rep.bitmapData, 0, 4)
            img.addRepresentation(rep)
        }
        return NSCursor(image: img, hotSpot: .zero)
    }

    private func customCursor(for spec: CursorImage) -> NSCursor? {
        if let cached = cache[spec] {
            return cached
        }
        guard let (w, h) = spec.pngSize(), w > 0, h > 0, w <= 256, h <= 256 else {
            return nil
        }
        let data = Data(spec.bytes)
        guard let nsImage = NSImage(data: data) else {
            return nil
        }
        let ptW = max(1.0, CGFloat(w) / 2.0)
        let ptH = max(1.0, CGFloat(h) / 2.0)
        nsImage.size = NSSize(width: ptW, height: ptH)
        let hx = CGFloat(CursorImage.clampedHotFloat(spec.hot.x, limit: Float(ptW - 1.0)))
        let hy = CGFloat(CursorImage.clampedHotFloat(spec.hot.y, limit: Float(ptH - 1.0)))
        let cur = NSCursor(image: nsImage, hotSpot: NSPoint(x: hx, y: hy))
        if cache.count >= Self.maxEntries, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        cache[spec] = cur
        order.append(spec)
        return cur
    }
}
#endif
