import Foundation
import RuneRef

/// A frame owns the complete list of live deferred glyphs. The GPU normally
/// fills each placement once. A capture, another device or a replay can still
/// reconstruct the same masks after the original atlas recycles its shelf.
internal final class OutlineMaskPlan: @unchecked Sendable {
    let base: R8Atlas
    let curves: RenderOutlineAtlas
    let fills: [QueuedOutlineFill]
    let baseGeneration: UInt64
    let epoch: UInt64
    private let lock = NSLock()
    private var materialized: R8Atlas?

    init(base: R8Atlas, curves: RenderOutlineAtlas, fills: [QueuedOutlineFill],
         baseGeneration: UInt64, epoch: UInt64) {
        self.base = base
        self.curves = curves
        self.fills = fills
        self.baseGeneration = baseGeneration
        self.epoch = epoch
    }

    func cpuAtlas() -> R8Atlas {
        lock.withLock {
            if let materialized { return materialized }
            let store = curves.makeStore()
            var result = base
            for item in fills {
                let r = item.rect
                let x = Int(r.x), y = Int(r.y), w = Int(r.z), h = Int(r.w)
                // Allocations reserve one transparent texel around the mask.
                let bytes = item.mask(in: store)
                let stride = result.width
                let top = (y - 1) * stride + x - 1, bottom = (y + h) * stride + x - 1
                for col in 0..<(w + 2) {
                    result.texels[top + col] = 0
                    result.texels[bottom + col] = 0
                }
                for row in 0..<h {
                    let dest = (y + row) * stride + x
                    result.texels[dest - 1] = 0
                    result.texels[dest + w] = 0
                    result.texels.replaceSubrange(dest..<(dest + w), with: bytes[row * w..<(row + 1) * w])
                }
            }
            materialized = result
            return result
        }
    }

}

extension QueuedOutlineFill {
    func mask(in store: OutlineStore) -> [UInt8] {
        guard let crop else {
            return OutlineMaskFiller.fillMask(store: store, fill: fill, atX: rect.x, atY: rect.y, width: rect.z, height: rect.w)
        }
        var source = fill
        source.pen -= SIMD2(Float(crop.x), Float(crop.y))
        let clipped = OutlineMaskFiller.fillMask(store: store, fill: source, atX: 0, atY: 0,
                                                width: UInt32(crop.z), height: UInt32(crop.w))
        let width = Int(rect.z)
        var result = [UInt8](repeating: 0, count: width * Int(rect.w))
        for row in 0..<crop.w {
            let dest = (crop.y + row) * width + crop.x
            result.replaceSubrange(dest..<(dest + crop.z), with: clipped[(row * crop.z)..<((row + 1) * crop.z)])
        }
        return result
    }

    /// A CPU mask and its neighbor can share a transparent gutter. Restore a touched
    /// gutter only when the raw bitmap actually wrote nonzero bytes into it.
    func overlaps(_ bounds: SIMD4<Int>, in base: R8Atlas? = nil) -> Bool {
        let x = Int(rect.x), y = Int(rect.y)
        let right = x + Int(rect.z), bottom = y + Int(rect.w)
        let x0 = max(x - 1, bounds.x), x1 = min(right + 1, bounds.z)
        let y0 = max(y - 1, bounds.y), y1 = min(bottom + 1, bounds.w)
        guard x0 < x1 && y0 < y1 else { return false }
        if x0 < right && x1 > x && y0 < bottom && y1 > y { return true }
        guard let base else { return true }
        return (y0..<y1).contains { row in
            let start = row * base.width
            return base.texels[(start + x0)..<(start + x1)].contains { $0 != 0 }
        }
    }

    /// The atlas pass uses the same Rune glyph shader as a directly drawn
    /// outline. A negative exponent requests R8 coverage with byte rounding.
    var instance: RenderInstance {
        let x = Float(rect.x), y = Float(rect.y)
        let ink = crop ?? SIMD4(0, 0, Int(rect.z), Int(rect.w))
        return RenderInstance(rect: SIMD4(x - 1, y - 1, Float(rect.z) + 2, Float(rect.w) + 2),
                              radii: SIMD4(x + fill.pen.x, y + fill.pen.y, fill.scale, 1),
                              fill: SIMD4(repeating: 1),
                              border: SIMD4(Float(fill.record), Float(fill.hint), fill.radius, Float(fill.coverage)),
                              params: SIMD4(0, KIND_GLYPH, 0, -1),
                              clip: SIMD4(x + Float(ink.x), y + Float(ink.y), x + Float(ink.x + ink.z), y + Float(ink.y + ink.w)))
    }
}
