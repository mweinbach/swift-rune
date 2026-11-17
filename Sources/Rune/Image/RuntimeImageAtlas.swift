import Foundation
import RuneRef

/// Stable page and texel edges of an image, independent of later shelf growth.
internal struct ImageAtlasRegion: Hashable {
    struct Origin: Hashable {
        let page: Int
        let x: Int
        let y: Int
    }
    let page: Int
    let edges: SIMD4<Float>
    var origin: Origin { Origin(page: page, x: Int(edges.x), y: Int(edges.y)) }
}

private let emptyRuntimeImageAtlas = RGBA8Atlas(width: 64, height: 64)

extension Runtime {
    internal struct ImageAtlasPacker {
        private struct Page {
            var pixels: ImagePage
            var revision: UInt64
            var patch: ImageAtlasPatch?
            var published = false

            var atlas: RGBA8Atlas {
                guard !pixels.data.isEmpty else { return RGBA8Atlas() }
                return RGBA8Atlas(width: Int(pixels.width), height: Int(pixels.height), texels: pixels.data)
            }
        }

        private struct Snapshot {
            var atlases: [RGBA8Atlas]
            var revisions: [UInt64]
            var patches: [ImageAtlasPatch?]
        }

        private var pages: [Page] = []
        private var snapshot: Snapshot?
        private var published = false
        private(set) var revision: UInt64 = ImageAtlasRevisionSeed.allocate()
        private var globalPatch: ImageAtlasPatch?
        private var globalPublished = false
        var pageCount: Int { pages.count }
        var atlas: RGBA8Atlas { pages.first?.atlas ?? emptyRuntimeImageAtlas }
        var atlases: [RGBA8Atlas] { mutating get { tables().atlases } }
        func atlas(at page: Int) -> RGBA8Atlas { pages.indices.contains(page) ? pages[page].atlas : emptyRuntimeImageAtlas }

        private mutating func tables() -> Snapshot {
            if let snapshot { return snapshot }
            let result = Snapshot(atlases: pages.map(\.atlas), revisions: pages.map(\.revision), patches: pages.map(\.patch))
            snapshot = result
            return result
        }

        mutating func publish(into frame: inout RenderFrame) {
            let snapshot = tables()
            if pages.count > 1 { frame.imagePages = snapshot.atlases }
            frame.imagePageRevisions = snapshot.revisions
            frame.imagePagePatches = snapshot.patches
            frame.imagePatch = globalPatch
            if !published {
                for index in pages.indices {
                    pages[index].published = true
                    pages[index].pixels.dirty = nil
                }
                published = true
                globalPublished = true
            }
        }

        private struct BitmapStorage: Hashable {
            let address: UInt
            let width: Int
            let height: Int

            init(_ bytes: [UInt8], width: Int, height: Int) {
                address = bytes.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
                self.width = width
                self.height = height
            }
        }

        private enum BitmapKey: Hashable {
            case image(Int, Int, [UInt8])
            case colorGlyph(Int, Int, Data)

            func hash(into hasher: inout Hasher) {
                // Equality still checks all pixels, including images with identical transparent borders.
                switch self {
                case let .image(w, h, bytes):
                    hasher.combine(0)
                    hasher.combine(w)
                    hasher.combine(h)
                    // Artwork often has transparent outer rows. Sample the interior as well
                    // before the exact byte comparison used to deduplicate separate allocations.
                    bytes.withUnsafeBytes { buffer in
                        for row in [0, h / 4, h / 2, 3 * h / 4, h - 1] {
                            let start = max(0, (row * w + w / 2) * 4 - 32)
                            let end = min(buffer.count, start + 64)
                            hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: buffer[start..<end]))
                        }
                    }
                case let .colorGlyph(w, h, bytes):
                    hasher.combine(1)
                    hasher.combine(w)
                    hasher.combine(h)
                    hasher.combine(bytes)
                }
            }
        }

        private var cache: [BitmapKey: ImageAtlasRegion] = [:]
        // The content cache holds the canonical byte array strongly. Its address therefore
        // identifies immutable storage until the corresponding cache entry is removed.
        private var bitmapStorage: [BitmapStorage: ImageAtlasRegion] = [:]
        private var placedBitmaps: Set<ImageAtlasRegion> = []
        private struct PixelSlot {
            var edges: ImageAtlasRegion
            var generation: UInt64
            var frame: Int
        }
        private struct PixelKey: Hashable {
            var id: UInt64
            var level: Int
        }
        private var pixelSlots: [PixelKey: PixelSlot] = [:]
        private var freeSlots: [SIMD2<Int>: [ImageAtlasRegion]] = [:]
        private var placedSlots: Set<PixelKey> = []
        private var retiredDuringPaint: [ImageAtlasRegion] = []
        private var allocatedArea = 0
        private var freeArea = 0
        private var compactBeforePaint = false
        private var contentVersions: [ImageAtlasRegion.Origin: UInt64] = [:]

        mutating func beginPaint() {
            // Previous RenderFrames retain their own backing pixels. Repack between paints
            // when changing image dimensions leave mostly unusable rectangles behind.
            if compactBeforePaint { self = Self() }
        }

        mutating func rest() {
            // finishPixelPaint removes every unused bitmap. Once the last one is gone
            // the backing page can shrink immediately without invalidating live UVs.
            if cache.isEmpty && pixelSlots.isEmpty && allocatedArea > 0 { self = Self() }
        }

        func version(at region: ImageAtlasRegion) -> UInt64 {
            contentVersions[region.origin] ?? 0
        }

        /// Streaming pixels and decoded animations overwrite their own atlas rectangle.
        mutating func insert(_ sample: PixelsPresentation, for id: UInt64, drawnSize: SIMD2<Float>) -> ImageAtlasRegion {
            let selection = sample.selectedMip(for: drawnSize)
            let key = PixelKey(id: id, level: selection?.level ?? 0)
            let firstDraw = placedSlots.insert(key).inserted
            // Keep original straight RGBA at natural size, and linear-light area samples when shrinking.
            let mip = key.level > 0 ? selection?.mip : nil
            let w = Int(mip?.width ?? sample.width)
            let h = Int(mip?.height ?? sample.height)
            let size = SIMD2(w, h)
            let edges: ImageAtlasRegion
            if let slot = pixelSlots[key], dimensions(slot.edges) == size {
                if slot.generation == sample.generation && slot.frame == sample.frameIndex { return slot.edges }
                edges = slot.edges
            } else {
                if let old = pixelSlots[key] {
                    // This paint may still sample the old size before another image requests it.
                    if firstDraw { recycle(old.edges) } else { retiredDuringPaint.append(old.edges) }
                }
                edges = allocate(width: w, height: h)
            }
            var bytes = mip.map { Array($0.rgba) } ?? sample.rgba
            if mip != nil || sample.premultiplied {
                // Mip-only sources store sRGB-encoded, premultiplied linear color. Both
                // the reference scene and legacy GPU hosts expect straight sRGB images.
                for i in stride(from: 0, to: bytes.count, by: 4) {
                    let alpha = bytes[i + 3]
                    guard alpha > 0, alpha < 255 else { continue }
                    let divisor = Float(alpha) / 255
                    for c in i..<(i + 3) {
                        bytes[c] = LinearMipGenerator.linearToSrgb(LinearMipGenerator.srgbToLinear(bytes[c]) / divisor)
                    }
                }
            }
            write(bytes, width: w, height: h, at: edges)
            pixelSlots[key] = PixelSlot(edges: edges, generation: sample.generation, frame: sample.frameIndex)
            return edges
        }

        private func dimensions(_ region: ImageAtlasRegion) -> SIMD2<Int> {
            let edges = region.edges
            return SIMD2(Int(edges.z - edges.x), Int(edges.w - edges.y))
        }

        private mutating func recycle(_ edges: ImageAtlasRegion) {
            let size = dimensions(edges)
            freeSlots[size, default: []].append(edges)
            freeArea += size.x * size.y
        }

        mutating func finishPixelPaint() {
            for region in retiredDuringPaint { recycle(region) }
            let updatedSlots = !retiredDuringPaint.isEmpty || placedSlots.count < pixelSlots.count || placedBitmaps.count < cache.count
            if placedSlots.count < pixelSlots.count {
                for (key, slot) in pixelSlots where !placedSlots.contains(key) {
                    recycle(slot.edges)
                    pixelSlots.removeValue(forKey: key)
                }
            }
            if placedBitmaps.count < cache.count {
                for (key, edges) in cache where !placedBitmaps.contains(edges) {
                    if case let .image(w, h, bytes) = key {
                        bitmapStorage.removeValue(forKey: BitmapStorage(bytes, width: w, height: h))
                    }
                    recycle(edges)
                    cache.removeValue(forKey: key)
                }
            }
            retiredDuringPaint.removeAll(keepingCapacity: true)
            placedSlots.removeAll(keepingCapacity: true)
            placedBitmaps.removeAll(keepingCapacity: true)
            if updatedSlots { reclaimEmptyPages() }
            let liveArea = allocatedArea - freeArea
            compactBeforePaint = freeArea > max(64 * 64, 2 * liveArea)
        }

        mutating func insert(_ img: RGBA8Atlas) -> ImageAtlasRegion {
            guard Self.validSize(img.width, img.height), img.texels.count / 4 / img.height >= img.width else {
                return insert(RGBA8Atlas())
            }
            let storage = BitmapStorage(img.texels, width: img.width, height: img.height)
            if let cached = bitmapStorage[storage] {
                placedBitmaps.insert(cached)
                return cached
            }
            let key = BitmapKey.image(img.width, img.height, img.texels)
            if let cached = cache[key] {
                placedBitmaps.insert(cached)
                return cached
            }
            let region = place(img.texels, width: img.width, height: img.height, key: key)
            bitmapStorage[storage] = region
            return region
        }

        mutating func insert(_ glyph: GlyphAtlas.ColorGlyphEntry) -> ImageAtlasRegion {
            guard Self.validSize(glyph.pixelSize.x, glyph.pixelSize.y), glyph.rgba.count % 4 == 0,
                  glyph.rgba.count / 4 / glyph.pixelSize.y >= glyph.pixelSize.x else { return insert(RGBA8Atlas()) }
            let key = BitmapKey.colorGlyph(glyph.pixelSize.x, glyph.pixelSize.y, glyph.rgba)
            if let cached = cache[key] {
                placedBitmaps.insert(cached)
                return cached
            }
            // Font rasterizers supply premultiplied sRGB. Both Rune image shaders consume straight sRGB.
            var pixels = Array(glyph.rgba)
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let a = Int(pixels[offset + 3])
                if a == 255 || a == 0 { continue }
                for channel in offset..<(offset + 3) {
                    pixels[channel] = UInt8(clamping: (Int(pixels[channel]) * 255 + a / 2) / a)
                }
            }
            return place(pixels, width: glyph.pixelSize.x, height: glyph.pixelSize.y, key: key)
        }

        /// Returns texel edges, which remain stable when later inserts enlarge the backing texture.
        private mutating func place(_ pixels: [UInt8], width bw: Int, height bh: Int, key: BitmapKey) -> ImageAtlasRegion {
            let edges = allocate(width: bw, height: bh)
            write(pixels, width: bw, height: bh, at: edges)
            cache[key] = edges
            placedBitmaps.insert(edges)
            return edges
        }

        private static func validSize(_ width: Int, _ height: Int) -> Bool {
            // Passthrough Swift atlas images may occupy a full backend texture. Streamed Pixels
            // are already bounded to Rune's smaller IMAGE_MAX_SIDE by their setter.
            (1...16_384).contains(width) && (1...16_384).contains(height)
        }

        private mutating func reclaimEmptyPages() {
            guard !pages.isEmpty else { return }
            let live = Set(cache.values.map(\.page)).union(pixelSlots.values.map { $0.edges.page })
            let firstSpare = pages[0].pixels.width <= IMAGE_ATLAS_SIZE && pages[0].pixels.height <= IMAGE_ATLAS_SIZE
            let kept = max(firstSpare ? 1 : 0, (live.max() ?? -1) + 1)
            var discarded = Set<Int>()
            for i in pages.indices where !live.contains(i) && !(i == 0 && firstSpare) && !pages[i].pixels.data.isEmpty {
                discarded.insert(i)
                pages[i].pixels.data = []
                pages[i].patch = nil
                pages[i].revision = ImageAtlasRevisionSeed.allocate()
            }
            if kept < pages.count { pages.removeLast(pages.count - kept) }
            guard !discarded.isEmpty else { return }
            snapshot = nil
            published = false
            revision &+= 1
            globalPatch = nil
            contentVersions = contentVersions.filter { !discarded.contains($0.key.page) }
            for size in Array(freeSlots.keys) {
                let previous = freeSlots[size]?.count ?? 0
                freeSlots[size]?.removeAll { discarded.contains($0.page) }
                let left = freeSlots[size]?.count ?? 0
                if left == 0 { freeSlots.removeValue(forKey: size) }
                let area = (previous - left) * size.x * size.y
                freeArea -= area
                allocatedArea -= area
            }
        }

        private mutating func allocate(width bw: Int, height bh: Int) -> ImageAtlasRegion {
            let size = SIMD2(bw, bh)
            if let recycled = freeSlots[size]?.popLast() {
                freeArea -= bw * bh
                if freeSlots[size]?.isEmpty == true { freeSlots.removeValue(forKey: size) }
                return recycled
            }
            // A bitmap shown last frame may appear later in this traversal. Only slots retired
            // at the end of a paint can be reused; a new leading row never displaces live images.
            snapshot = nil
            allocatedArea += bw * bh
            let w = UInt32(bw), h = UInt32(bh)
            func region(_ page: Int, _ x: UInt32, _ y: UInt32) -> ImageAtlasRegion {
                ImageAtlasRegion(page: page, edges: SIMD4(Float(x), Float(y), Float(x + w), Float(y + h)))
            }
            for page in pages.indices {
                if pages[page].pixels.data.isEmpty {
                    pages[page] = Page(pixels: ImagePage(width: w, height: h), revision: ImageAtlasRevisionSeed.allocate())
                }
                if let (x, y) = pages[page].pixels.allocate(width: w, height: h) {
                    return region(page, x, y)
                }
            }
            var page = ImagePage(width: w, height: h)
            _ = page.allocate(width: w, height: h)
            let index = pages.count
            pages.append(Page(pixels: page, revision: ImageAtlasRevisionSeed.allocate()))
            return region(index, 0, 0)
        }

        private mutating func write(_ bytes: [UInt8], width: Int, height: Int, at region: ImageAtlasRegion) {
            snapshot = nil
            published = false
            let page = region.page
            let rect = SIMD4<Int>(region.edges)
            pages[page].pixels.write(bytes, x: UInt32(rect.x), y: UInt32(rect.y), w: UInt32(width), h: UInt32(height))
            if pages[page].published || pages[page].patch == nil {
                pages[page].patch = ImageAtlasPatch(fromRevision: pages[page].revision, edges: rect)
                pages[page].published = false
            } else {
                pages[page].patch?.include(rect)
            }
            pages[page].revision &+= 1
            if page == 0 {
                if globalPublished || globalPatch == nil {
                    globalPatch = ImageAtlasPatch(fromRevision: revision, edges: rect)
                    globalPublished = false
                } else {
                    globalPatch?.include(rect)
                }
            }
            revision &+= 1
            contentVersions[region.origin] = revision
        }
    }
}
