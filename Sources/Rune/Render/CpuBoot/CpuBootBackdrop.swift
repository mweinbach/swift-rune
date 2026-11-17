import Foundation
import RuneRef

/// Executes the shared CPU backdrop pyramid on the startup painter's workers.
public enum CpuBootBackdrop {
    public static let mips = BackdropPyramid.mips
    public static let step = BackdropPyramid.step
    public static let sigmas = BackdropPyramid.sigmas
    public typealias Record = BackdropPyramid.Record
    public typealias Blurred = BackdropPyramid.Blurred

    public static func plan(_ inst: RenderInstance, viewport: (UInt32, UInt32)) -> Record? {
        BackdropPyramid.plan(rect: inst.rect, sigma: inst.params.x, viewport: viewport)
    }

    public static func blur(
        record: Record, viewport: (UInt32, UInt32), half: HalfRounding, exec: any CpuBootExec,
        window: @escaping @Sendable (UInt32, UInt32) -> SIMD4<Float>
    ) -> Blurred {
        BackdropPyramid.blur(record: record, viewport: viewport, nearestEven: half == .nearestEven, run: exec.run, window: window)
    }

    public static func bounds(_ inst: RenderInstance, viewport: (UInt32, UInt32)) -> SIMD4<Int32> {
        let r = inst.rect
        let c = inst.clip
        let vw = Float(viewport.0)
        let vh = Float(viewport.1)
        let x0 = min(max(floorf(max(r.x, c.x)), 0.0), vw)
        let y0 = min(max(floorf(max(r.y, c.y)), 0.0), vh)
        let x1 = min(max(ceilf(min(r.x + r.z, c.z)), 0.0), vw)
        let y1 = min(max(ceilf(min(r.y + r.w, c.w)), 0.0), vh)
        if x1 <= x0 || y1 <= y0 { return .zero }
        return SIMD4<Int32>(Int32(x0), Int32(y0), Int32(x1), Int32(y1))
    }

    public static func composite(
        _ blurred: Blurred,
        inst: RenderInstance,
        clip: CpuBootShade.Clip,
        p: SIMD2<Float>
    ) -> SIMD4<Float> {
        let half = SIMD2<Float>(inst.rect.z * 0.5, inst.rect.w * 0.5)
        let d = CpuBootShade.sdRounded(
            SIMD2<Float>(p.x - inst.rect.x - half.x, p.y - inst.rect.y - half.y),
            half: half,
            radii: inst.radii
        )
        let cov = min(max(0.5 - d, 0.0), 1.0) * clip.alpha(p) * inst.fill.w
        return blurred.sample(at: p) * cov
    }
}
