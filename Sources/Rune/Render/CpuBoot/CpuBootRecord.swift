import Foundation
#if canImport(simd)
import simd
#endif

/// Binary frame recording for `CpuBoot` (`RCB1` magic, little-endian, `cpu_boot/record.rs`).
public enum CpuBootRecord {
    public static let magic: [UInt8] = Array("RCB1".utf8)

    public struct Recording: Sendable {
        public let instances: [RenderInstance]
        public let glyphPages: [[UInt8]]
        public let glyphPageWidth: Int
        public let glyphPageHeight: Int
        public let images: [(Int, [UInt8])]
        public let size: (Int, Int)
        public let clear: SIMD4<Float>
        public let lcd: Bool

        public func scene() -> CpuBootScene {
            CpuBootScene(
                instances: instances,
                glyphPages: glyphPages,
                glyphPageWidth: glyphPageWidth,
                glyphPageHeight: glyphPageHeight,
                images: images.map { CpuBootImage(width: $0.0, data: $0.1) },
                size: size,
                clear: clear,
                lcd: lcd,
                srgbBlend: true,
                nativeSurfaces: false,
                compositor: false,
                smoothing: nil,
                outlines: nil,
                atlasResets: 0,
                half: .towardZero
            )
        }
    }

    private static func appendU32LE(_ v: UInt32, to out: inout [UInt8]) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }

    /// RCB1 has fixed-size glyph pages. Older Swift recordings stored variable page dimensions
    /// immediately after the page count. Preserve that representation only for custom masks
    /// whose sampling footprint cannot fit a Rune glyph page.
    public static func encode(_ scene: CpuBootScene) -> [UInt8] {
        do { return try encodeForReplay(scene) }
        catch EncodingError.oversizedMask { return write(scene, legacy: true) }
        catch { return [] }
    }

    enum EncodingError: Error, CustomStringConvertible {
        case invalidScene, oversizedMask

        var description: String {
            switch self {
            case .invalidScene: return "Invalid dimensions or atlas data in CPU boot frame"
            case .oversizedMask: return "Glyph mask exceeds the \(GlyphAtlas.atlasSize)-texel RCB1 page"
            }
        }
    }

    /// Emits exactly the wire format accepted by Rust's `cpu_boot::Recording::decode`.
    public static func encodeForReplay(_ scene: CpuBootScene) throws -> [UInt8] {
        let width = scene.glyphPageWidth
        let height = scene.glyphPageHeight
        guard UInt32(exactly: scene.size.0) != nil, UInt32(exactly: scene.size.1) != nil,
              UInt32(exactly: scene.instances.count) != nil, UInt32(exactly: scene.images.count) != nil,
              UInt32(exactly: scene.glyphPages.count) != nil,
              width > 0, height > 0, UInt32(exactly: width) != nil, UInt32(exactly: height) != nil,
              height <= Int.max / width,
              scene.glyphPages.allSatisfy({ $0.count == width * height }),
              scene.images.allSatisfy({ image in
                  guard image.width > 0 else { return image.width == 0 && image.data.isEmpty }
                  let n = image.data.count
                  return UInt32(exactly: image.width) != nil && image.width <= Int.max / 4 && n % (image.width * 4) == 0
                      && UInt32(exactly: n / (image.width * 4)) != nil
              }) else { throw EncodingError.invalidScene }

        let side = GlyphAtlas.atlasSize
        if scene.glyphPages.isEmpty || (width == side && height == side) { return write(scene, legacy: false) }
        let cols = 1 + (width - 1) / side
        let rows = 1 + (height - 1) / side
        let tiles = cols * rows
        guard tiles <= Int.max / scene.glyphPages.count,
              UInt32(exactly: tiles * scene.glyphPages.count) != nil else { throw EncodingError.invalidScene }
        var fixed = scene
        fixed.glyphPageWidth = side
        fixed.glyphPageHeight = side
        fixed.glyphPages = []
        for bytes in scene.glyphPages {
            for row in 0..<rows {
                for col in 0..<cols {
                    let x = col * side, y = row * side
                    let w = min(side, width - x), h = min(side, height - y)
                    if w == width && w == side && h == side {
                        fixed.glyphPages.append(Array(bytes[y * width..<(y + h) * width]))
                    } else {
                        var page = [UInt8](repeating: 0, count: side * side)
                        for n in 0..<h {
                            let src = (y + n) * width + x
                            let dst = n * side
                            page.replaceSubrange(dst..<dst + w, with: bytes[src..<src + w])
                        }
                        fixed.glyphPages.append(page)
                    }
                }
            }
        }

        // Native frames stack all 2048-square glyph pages vertically for the GPU. RCB1
        // samples page params.z at texel-space uv.xy; restore that addressing here.
        if tiles > 1 {
            var missingPages: [Int] = []
            for idx in fixed.instances.indices {
                var i = fixed.instances[idx]
                guard i.params.y == KIND_GLYPH, i.radii.w <= 0 else { continue }
                guard let page = Int(exactly: i.params.z.rounded(.towardZero)), scene.glyphPages.indices.contains(page) else {
                    missingPages.append(idx)
                    continue
                }
                guard i.uv.x.isFinite, i.uv.y.isFinite,
                      let sx = Int(exactly: i.uv.x.rounded(.down)), let sy = Int(exactly: i.uv.y.rounded(.down)) else {
                    throw EncodingError.invalidScene
                }
                let col = max(0, min(cols - 1, sx / side))
                let row = max(0, min(rows - 1, sy / side))
                var ox = col * side, oy = row * side
                var targetPage = page * tiles + row * cols + col

                // A user-supplied atlas can place an individual glyph across a tile seam.
                // Preserve its bilinear sampling gutter in a standalone page in that case.
                let filtered = i.uv.z > 0 || i.params.x != 0
                let span = i.uv.z > 0 ? SIMD2(i.uv.z, i.uv.w) : SIMD2(i.rect.z, i.rect.w)
                let lcd = i.radii.x > 0.5 && !filtered
                let gutter = filtered ? 1 : 0
                guard let sw = Int(exactly: (span.x * (lcd ? 3 : 1)).rounded(.up)),
                      let sh = Int(exactly: span.y.rounded(.up)), sw >= 0, sh >= 0,
                      sx >= -side, sy >= -side, sx <= Int.max - max(1, sw) - gutter,
                      sy <= Int.max - max(1, sh) - gutter else { throw EncodingError.invalidScene }
                let x0 = max(0, sx - gutter), y0 = max(0, sy - gutter)
                let x1 = min(width, sx + sw + gutter), y1 = min(height, sy + sh + gutter)
                if x1 > x0, y1 > y0, x0 < ox || y0 < oy || x1 - ox > side || y1 - oy > side {
                    guard x1 - x0 <= side, y1 - y0 <= side else { throw EncodingError.oversizedMask }
                    var texels = [UInt8](repeating: 0, count: side * side)
                    let bytes = scene.glyphPages[page]
                    for y in y0..<y1 {
                        let src = y * width + x0, dst = (y - y0) * side
                        let n = x1 - x0
                        texels.replaceSubrange(dst..<dst + n, with: bytes[src..<src + n])
                    }
                    ox = x0
                    oy = y0
                    targetPage = fixed.glyphPages.count
                    fixed.glyphPages.append(texels)
                }
                i.params.z = Float(targetPage)
                i.uv.x -= Float(ox)
                i.uv.y -= Float(oy)
                fixed.instances[idx] = i
            }
            for idx in missingPages { fixed.instances[idx].params.z = Float(fixed.glyphPages.count) }
        }
        return write(fixed, legacy: false)
    }

    private static func write(_ scene: CpuBootScene, legacy: Bool) -> [UInt8] {
        var out = magic
        for n in [UInt32(scene.size.0), UInt32(scene.size.1), scene.clear.x.bitPattern,
                  scene.clear.y.bitPattern, scene.clear.z.bitPattern, scene.clear.w.bitPattern,
                  scene.lcd ? 1 : 0, UInt32(scene.instances.count)] {
            appendU32LE(n, to: &out)
        }
        scene.instances.withUnsafeBytes { out.append(contentsOf: $0) }
        appendU32LE(UInt32(scene.glyphPages.count), to: &out)
        if legacy {
            appendU32LE(UInt32(scene.glyphPageWidth), to: &out)
            appendU32LE(UInt32(scene.glyphPageHeight), to: &out)
        }
        for page in scene.glyphPages { out.append(contentsOf: page) }
        appendU32LE(UInt32(scene.images.count), to: &out)
        for img in scene.images {
            appendU32LE(UInt32(img.width), to: &out)
            appendU32LE(UInt32(img.data.count / max(1, img.width * 4)), to: &out)
            out.append(contentsOf: img.data)
        }
        return out
    }

    private struct Reader {
        let bytes: [UInt8]
        var at = 0
        var remaining: Int { bytes.count - at }

        mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard n >= 0, n <= remaining else { return nil }
            let start = at
            at += n
            return bytes[start..<at]
        }

        mutating func u32() -> UInt32? {
            guard let s = take(4) else { return nil }
            return s.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }

        mutating func count() -> Int? { u32().flatMap(Int.init(exactly:)) }

        mutating func tail(pages: Int, width: Int, height: Int) -> ([[UInt8]], [(Int, [UInt8])])? {
            guard width > 0, height > 0, height <= Int.max / width else { return nil }
            let length = width * height
            guard pages <= remaining / length else { return nil }
            var masks: [[UInt8]] = []
            for _ in 0..<pages {
                guard let page = take(length) else { return nil }
                masks.append(Array(page))
            }
            guard let imagesCount = count(), imagesCount <= remaining / 8 else { return nil }
            var images: [(Int, [UInt8])] = []
            for _ in 0..<imagesCount {
                guard let w = count(), let h = count(), w <= Int.max / 4,
                      h == 0 || w * 4 <= remaining / h,
                      let texels = take(w * 4 * h) else { return nil }
                images.append((w, Array(texels)))
            }
            return remaining == 0 ? (masks, images) : nil
        }
    }

    public static func decode(_ bytes: [UInt8]) -> Recording? {
        var r = Reader(bytes: bytes)
        guard let header = r.take(4), header.elementsEqual(magic), let w = r.count(), let h = r.count(),
              let c0 = r.u32(), let c1 = r.u32(), let c2 = r.u32(), let c3 = r.u32(),
              let flags = r.u32(), let count = r.count() else { return nil }
        let stride = MemoryLayout<RenderInstance>.stride
        guard count <= r.remaining / stride, let raw = r.take(count * stride), let pages = r.count() else { return nil }

        let side = GlyphAtlas.atlasSize
        var canonical = r
        var legacy = r
        var instances = [RenderInstance](repeating: .zero, count: count)
        instances.withUnsafeMutableBytes { $0.copyBytes(from: raw) }
        let payload: ([[UInt8]], [(Int, [UInt8])])
        let pageWidth: Int, pageHeight: Int
        if let tail = canonical.tail(pages: pages, width: side, height: side) {
            payload = tail
            (pageWidth, pageHeight) = (side, side)
        } else if let pw = legacy.count(), let ph = legacy.count(),
                  let tail = legacy.tail(pages: pages, width: pw, height: ph) {
            payload = tail
            (pageWidth, pageHeight) = (pw, ph)
        } else if pages == 1, !instances.contains(where: { $0.params.y == KIND_GLYPH }),
                  let tail = r.tail(pages: 0, width: side, height: side) {
            // Some Rust captures count their lazily unallocated primary page but write no
            // bytes for it. A frame with no glyph draws is unambiguous in this case.
            payload = tail
            (pageWidth, pageHeight) = (side, side)
        } else {
            return nil
        }
        return Recording(instances: instances, glyphPages: payload.0, glyphPageWidth: pageWidth,
                         glyphPageHeight: pageHeight, images: payload.1, size: (w, h),
                         clear: SIMD4(Float(bitPattern: c0), Float(bitPattern: c1), Float(bitPattern: c2), Float(bitPattern: c3)),
                         lcd: flags & 1 != 0)
    }
}
