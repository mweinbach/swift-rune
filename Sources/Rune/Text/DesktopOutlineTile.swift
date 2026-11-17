import Foundation

/// Shaped glyphs share one shelf placement, but each cell reports the exact
/// covered rows of its own column slice (including marks and overhangs).
final class DesktopOutlineTile: @unchecked Sendable {
    struct Component: Sendable {
        let rect: SIMD4<Int>
        let fill: OutlineFillParams
    }

    let generation: UInt64
    let components: [Component]
    private let lock = NSLock()
    private var rowBounds: [Range<Int>: Range<Int>] = [:]

    init?(group: TextOutlineGroup, width: Int, height: Int) {
        generation = group.generation
        components = group.glyphs.compactMap { glyph in
            let b = glyph.rect
            let x = max(0, Int(floorf(b.x))), y = max(0, Int(floorf(b.y)))
            let right = min(width, Int(ceilf(b.x + b.z))), bottom = min(height, Int(ceilf(b.y + b.w)))
            guard right > x && bottom > y else { return nil }
            let g = glyph.outline
            let fill = OutlineFillParams(record: g.record, hint: g.hint, scale: g.scale, radius: g.radius,
                pen: g.pen - SIMD2(Float(x), Float(y)), coverage: g.coverage == 2 ? 0 : g.coverage)
            return Component(rect: SIMD4(x, y, right - x, bottom - y), fill: fill)
        }
        if components.isEmpty { return nil }
    }

    func coveredRows(columns: Range<Int>, store: OutlineStore) -> Range<Int>? {
        guard !columns.isEmpty, generation == store.generation else { return nil }
        let rows = lock.withLock {
            if let cached = rowBounds[columns] { return cached }
            let candidates = components.filter { part in
                part.rect.x < columns.upperBound && part.rect.x + part.rect.z > columns.lowerBound
            }
            let top = candidates.map(\.rect.y).min() ?? 0
            let bottom = candidates.map { $0.rect.y + $0.rect.w }.max() ?? top
            func containsInk(_ y: Int) -> Bool {
                candidates.contains { part in
                    let b = part.rect
                    guard y >= b.y && y < b.y + b.w else { return false }
                    let slice = max(0, columns.lowerBound - b.x)..<min(b.z, columns.upperBound - b.x)
                    return OutlineMaskFiller.hasInk(store: store, fill: part.fill, columns: slice, row: y - b.y)
                }
            }
            var covered = 0..<0
            if let first = (top..<bottom).first(where: containsInk) {
                let last = ((first + 1)..<bottom).last(where: containsInk) ?? first
                covered = first..<(last + 1)
            }
            rowBounds[columns] = covered
            return covered
        }
        return rows.isEmpty ? nil : rows
    }

}
