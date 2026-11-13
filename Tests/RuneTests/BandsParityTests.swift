import Foundation
import Testing
@testable import Rune
#if canImport(simd)
import simd
#endif

@Suite("Paint Bands Parity (crates/rune/src/runtime/bands_tests.rs)")
struct BandsParityTests {
    private func shadow(_ rect: SIMD4<Float>, sigma: Float) -> RenderInstance {
        RenderInstance(
            rect: rect,
            radii: SIMD4<Float>(repeating: 16.0),
            fill: SIMD4<Float>(0.0, 0.0, 0.0, 0.3),
            border: .zero,
            params: SIMD4<Float>(0.0, KIND_SHADOW, sigma, 1.0),
            uv: .zero,
            clip: NO_CLIP,
            fade: .zero
        )
    }

    private func windows(_ out: [RenderInstance], grow: Float) -> [SIMD4<Float>] {
        out.map { i in
            let x = i.rect.x
            let y = i.rect.y
            let w = i.rect.z
            let h = i.rect.w
            let u0 = i.uv.x
            let v0 = i.uv.y
            let u1 = i.uv.z
            let v1 = i.uv.w
            #expect(u1 < 0.0, "every band carries the mark")
            return SIMD4<Float>(
                max(x - grow, x + u0),
                max(y - grow, y + v0),
                min(x + w + grow, x - u1),
                min(y + h + grow, y + v1)
            )
        }
    }

    private func area(_ r: SIMD4<Float>) -> Float {
        max(0.0, r.z - r.x) * max(0.0, r.w - r.y)
    }

    @Test("a_big_shadow_draws_as_four_bands_around_the_box")
    func bigShadowDrawsAsFourBandsAroundBox() {
        var out: [RenderInstance] = []
        var marks: [UInt32] = []
        let caster = SIMD4<Float>(100.0, 100.0, 1000.0, 600.0)
        PaintBands.pushShadow(
            into: &out,
            marks: &marks,
            inst: shadow(SIMD4<Float>(100.0, 104.0, 1000.0, 600.0), sigma: 4.0),
            caster: caster,
            radii: SIMD4<Float>(repeating: 16.0)
        )
        #expect(out.count == 4)
        let grow: Float = 4.0 * 3.0 + 1.0
        let bands = windows(out, grow: grow)
        let quad = SIMD4<Float>(100.0 - grow, 104.0 - grow, 1100.0 + grow, 704.0 + grow)
        let hole = SIMD4<Float>(117.0, 117.0, 1083.0, 683.0)
        let total = bands.reduce(Float(0)) { $0 + area($1) }
        #expect(total == area(quad) - area(hole), "the bands tile the quad around the hole")
        for k in 0..<bands.count {
            for m in (k + 1)..<bands.count {
                let a = bands[k]
                let b = bands[m]
                let inter = SIMD4<Float>(max(a.x, b.x), max(a.y, b.y), min(a.z, b.z), min(a.w, b.w))
                #expect(area(inter) == 0.0, "bands never overlap")
            }
        }
        let whole = shadow(SIMD4<Float>(100.0, 104.0, 1000.0, 600.0), sigma: 4.0)
        for i in out {
            #expect(i.rect == whole.rect)
            #expect(i.radii == whole.radii)
            #expect(i.fill == whole.fill)
            #expect(i.params == whole.params)
            #expect(i.clip == whole.clip)
        }
    }

    @Test("a_small_shadow_stays_one_quad")
    func smallShadowStaysOneQuad() {
        var out: [RenderInstance] = []
        var marks: [UInt32] = []
        PaintBands.pushShadow(
            into: &out,
            marks: &marks,
            inst: shadow(SIMD4<Float>(0.0, 2.0, 120.0, 80.0), sigma: 4.0),
            caster: SIMD4<Float>(0.0, 0.0, 120.0, 80.0),
            radii: SIMD4<Float>(repeating: 8.0)
        )
        #expect(out.count == 1)
        #expect(out[0].uv == .zero)
    }

    @Test("a_shadow_with_a_hole_already_stays_one_quad")
    func shadowWithHoleAlreadyStaysOneQuad() {
        var out: [RenderInstance] = []
        var marks: [UInt32] = []
        var inst = shadow(SIMD4<Float>(0.0, 0.0, 1000.0, 600.0), sigma: 4.0)
        inst.uv = SIMD4<Float>(0.0, 0.0, 1000.0, 600.0)
        PaintBands.pushShadow(
            into: &out,
            marks: &marks,
            inst: inst,
            caster: SIMD4<Float>(0.0, 0.0, 1000.0, 600.0),
            radii: SIMD4<Float>(repeating: 8.0)
        )
        #expect(out.count == 1)
    }

    @Test("a_big_border_ring_draws_as_bands_and_a_filled_box_never_asks")
    func bigBorderRingDrawsAsBands() {
        var out: [RenderInstance] = []
        var marks: [UInt32] = []
        let ring = RenderInstance(
            rect: SIMD4<Float>(10.0, 10.0, 800.0, 500.0),
            radii: SIMD4<Float>(repeating: -16.0),
            fill: .zero,
            border: SIMD4<Float>(repeating: 1.0),
            params: SIMD4<Float>(1.0, KIND_RECT, 0.0, 1.0),
            uv: .zero,
            clip: NO_CLIP,
            fade: .zero
        )
        PaintBands.pushRing(into: &out, marks: &marks, inst: ring)
        #expect(out.count == 4)
        let bands = windows(out, grow: 1.0)
        let e: Float = 16.0 * CONTINUOUS_K + 1.0 + 0.5 + 1.0
        let hole = SIMD4<Float>(10.0 + e, 10.0 + e, 810.0 - e, 510.0 - e)
        let total = bands.reduce(Float(0)) { $0 + area($1) }
        #expect(abs(total - (area(SIMD4<Float>(9.0, 9.0, 811.0, 511.0)) - area(hole))) < 1.0)
    }
}
