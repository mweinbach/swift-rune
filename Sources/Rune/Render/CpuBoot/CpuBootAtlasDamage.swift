import Foundation

/// Fingerprints of the actual mask and image texels read by retained tiles. Keeping each
/// backing array alive lets the common unchanged-page check use Swift's copy-on-write identity.
struct CpuBootAtlasDamage {
    private struct Page {
        var size = SIMD2<Int>.zero
        var pixels: [UInt8] = []
        var generation: UInt64?
        var regions: [SIMD4<Int>: UInt64] = [:]

        mutating func update(size: SIMD2<Int>, pixels: [UInt8], generation: UInt64?,
                             patch: ImageAtlasPatch? = nil, limit: Int) -> Bool {
            if regions.count > limit { regions.removeAll(keepingCapacity: false) }
            let stable = self.size == size && self.generation == generation && self.pixels.count == pixels.count
                && self.pixels.withUnsafeBufferPointer { old in
                    pixels.withUnsafeBufferPointer { $0.baseAddress == old.baseAddress }
                }
            if stable { return false }
            if self.size == size, let patch, self.generation == patch.fromRevision, self.generation != generation {
                let edges = patch.edges
                regions = regions.filter { bounds, _ in
                    bounds.z <= edges.x || bounds.x >= edges.z || bounds.w <= edges.y || bounds.y >= edges.w
                }
            } else {
                regions.removeAll(keepingCapacity: true)
            }
            self.size = size
            self.pixels = pixels
            self.generation = generation
            return true
        }

        mutating func hash(bounds: SIMD4<Int>, channels: Int) -> UInt64 {
            if let cached = regions[bounds] { return cached }
            guard bounds.z > bounds.x, bounds.w > bounds.y else { return 0 }
            var hash = Hasher()
            hash.combine(bounds)
            pixels.withUnsafeBytes { bytes in
                for y in bounds.y..<bounds.w {
                    let start = (y * size.x + bounds.x) * channels
                    let end = (y * size.x + bounds.z) * channels
                    guard end <= bytes.count else { break }
                    hash.combine(bytes: UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
                }
            }
            let value = UInt64(truncatingIfNeeded: hash.finalize())
            regions[bounds] = value
            return value
        }
    }

    private var glyphs: [Page] = []
    private var images: [Page] = []

    /// Returns true if a previously sampled texture could have changed, even for hand-built
    /// snapshots that have no upload receipt or that reuse the default revision.
    mutating func update(_ scene: CpuBootScene) -> Bool {
        var changed = glyphs.count != scene.glyphPages.count || images.count != scene.images.count
        let limit = max(16, scene.instances.count * 2)
        glyphs.resizePages(to: scene.glyphPages.count, empty: Page())
        images.resizePages(to: scene.images.count, empty: Page())
        for (i, bytes) in scene.glyphPages.enumerated() {
            let generation = scene.glyphRevisions.indices.contains(i) ? scene.glyphRevisions[i] : scene.glyphGeneration
            let patch = scene.glyphPatches.indices.contains(i) ? scene.glyphPatches[i] : nil
            if glyphs[i].update(size: scene.glyphSize(at: i), pixels: bytes,
                                generation: generation, patch: patch, limit: limit) {
                changed = true
            }
        }
        for (i, page) in scene.images.enumerated() {
            let revision = scene.imageRevisions.indices.contains(i) ? scene.imageRevisions[i] : nil
            let patch = scene.imagePatches.indices.contains(i) ? scene.imagePatches[i] : nil
            if images[i].update(size: SIMD2(page.width, page.height), pixels: page.data,
                                generation: revision, patch: patch, limit: limit) {
                changed = true
            }
        }
        return changed
    }

    mutating func sample(_ instance: RenderInstance) -> UInt64 {
        if instance.params.y == KIND_IMAGE {
            guard let i = Int(exactly: instance.params.x.rounded(.towardZero)), images.indices.contains(i) else { return 0 }
            let size = images[i].size
            guard size.x > 0, size.y > 0 else { return 0 }
            // The shader clamps bilinear taps to the source slot. A mirrored or fractional crop
            // can read the adjacent texel on either side of the nominal span.
            let explicit = instance.border.z > instance.border.x && instance.border.w > instance.border.y
            let start = SIMD2(instance.uv.x, instance.uv.y)
            let end = start + SIMD2(instance.uv.z, instance.uv.w)
            let lo = SIMD2(min(start.x, end.x), min(start.y, end.y))
            let hi = SIMD2(max(start.x, end.x), max(start.y, end.y))
            let minX = explicit ? instance.border.x : lo.x
            let minY = explicit ? instance.border.y : lo.y
            let maxX = explicit ? instance.border.z : hi.x
            let maxY = explicit ? instance.border.w : hi.y
            let x = Self.imageSpan(minX, maxX, lo.x, hi.x, count: size.x)
            let y = Self.imageSpan(minY, maxY, lo.y, hi.y, count: size.y)
            return images[i].hash(bounds: SIMD4(x.lowerBound, y.lowerBound, x.upperBound, y.upperBound), channels: 4)
        }
        if instance.params.y == KIND_GLYPH, instance.radii.w <= 0 {
            guard let i = Int(exactly: instance.params.z.rounded(.towardZero)), glyphs.indices.contains(i) else { return 0 }
            let size = glyphs[i].size
            let filtered = instance.uv.z > 0 || instance.params.x != 0
            let lcd = !filtered && instance.radii.x > 0.5
            let spanX = instance.uv.z > 0 ? instance.uv.z : instance.rect.z * (lcd ? 3 : 1)
            let spanY = instance.uv.z > 0 ? instance.uv.w : instance.rect.w
            let fringe: Float = filtered ? 1 : 0
            let bounds = SIMD4(Self.edge(instance.uv.x - fringe, count: size.x, up: false),
                               Self.edge(instance.uv.y - fringe, count: size.y, up: false),
                               Self.edge(instance.uv.x + spanX + fringe, count: size.x, up: true),
                               Self.edge(instance.uv.y + spanY + fringe, count: size.y, up: true))
            return glyphs[i].hash(bounds: bounds, channels: 1)
        }
        return 0
    }

    private static func edge(_ value: Float, count: Int, up: Bool) -> Int {
        Int(max(0, min(Float(count), value.rounded(up ? .up : .down))))
    }

    private static func imageSpan(_ minBound: Float, _ maxBound: Float, _ start: Float, _ end: Float,
                                  count: Int) -> Range<Int> {
        let first = min(count - 1, edge(minBound + minBound * Float.ulpOfOne, count: count, up: false))
        let limit = max(first + 1, edge(maxBound - maxBound * Float.ulpOfOne, count: count, up: true))
        let lo = min(limit - 1, max(first, edge(start - 0.5, count: count, up: false)))
        let hi = min(limit, max(lo + 1, edge(end + 0.5, count: count, up: true)))
        return lo..<hi
    }
}

private extension Array {
    mutating func resizePages(to count: Int, empty: Element) {
        if self.count < count { append(contentsOf: repeatElement(empty, count: count - self.count)) }
        if self.count > count { removeLast(self.count - count) }
    }
}
