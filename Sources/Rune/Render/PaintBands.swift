import Foundation
#if canImport(simd)
import simd
#endif

/// Splits large blurred shadows and hollow border rings into four perimeter bands
/// around their hidden interior (`crates/rune/src/runtime/paint/bands.rs`).
internal enum PaintBands {
    /// Minimum hole width and height (device pixels) before splitting into 4 bands pays.
    static let minHole: Float = 96.0

    /// Pushes the outer shadow `inst` of an opaque box at `caster` (device px `[x, y, w, h]`)
    /// with corner `radii` (negative for Apple continuous corners).
    static func pushShadow(
        into instances: inout [RenderInstance],
        marks: inout [UInt32],
        inst: RenderInstance,
        caster: SIMD4<Float>,
        radii: SIMD4<Float>
    ) {
        let e = max(
            max(cornerExtent(radii.x), cornerExtent(radii.y)),
            max(cornerExtent(radii.z), cornerExtent(radii.w))
        ) + 1.0
        let x = caster.x - inst.rect.x
        let y = caster.y - inst.rect.y
        push(
            into: &instances,
            marks: &marks,
            inst: inst,
            hole: SIMD4<Float>(x + e, y + e, x + caster.z - e, y + caster.w - e),
            grow: inst.params.z * 3.0 + 1.0
        )
    }

    /// Pushes a border-only `inst` (clear fill): nothing draws past its ring (`paint/bands.rs:20`).
    static func pushRing(
        into instances: inout [RenderInstance],
        marks: inout [UInt32],
        inst: RenderInstance
    ) {
        let e = max(
            max(cornerExtent(inst.radii.x), cornerExtent(inst.radii.y)),
            max(cornerExtent(inst.radii.z), cornerExtent(inst.radii.w))
        ) + inst.params.x + max(inst.params.z, 0.5) + 1.0
        push(
            into: &instances,
            marks: &marks,
            inst: inst,
            hole: SIMD4<Float>(e, e, inst.rect.z - e, inst.rect.w - e),
            grow: 1.0 + inst.params.z * 2.0
        )
    }

    /// Emits `inst` whole, or as 4 non-overlapping perimeter bands around `hole` `[x0, y0, x1, y1]`
    /// relative to `inst.rect` when `hole` is large enough (`paint/bands.rs:28`).
    static func push(
        into instances: inout [RenderInstance],
        marks: inout [UInt32],
        inst: RenderInstance,
        hole: SIMD4<Float>,
        grow: Float
    ) {
        let hx0 = hole.x
        let hy0 = hole.y
        let hx1 = hole.z
        let hy1 = hole.w
        let qx0 = -grow
        let qy0 = -grow
        let qx1 = inst.rect.z + grow
        let qy1 = inst.rect.w + grow
        if (hx1 - hx0) < minHole
            || (hy1 - hy0) < minHole
            || hx0 < 1.0
            || hy0 <= qy0
            || hx1 >= qx1
            || hy1 >= qy1
            || inst.uv != .zero
        {
            instances.append(inst)
            marks.append(0)
            return
        }
        let bands: [(Float, Float, Float, Float)] = [
            (qx0, qy0, qx1, hy0),
            (qx0, hy0, hx0, hy1),
            (hx1, hy0, qx1, hy1),
            (qx0, hy1, qx1, qy1),
        ]
        for (bx0, by0, bx1, by1) in bands {
            var band = inst
            band.uv = SIMD4<Float>(bx0, by0, -bx1, by1)
            instances.append(band)
            marks.append(0)
        }
    }
}
