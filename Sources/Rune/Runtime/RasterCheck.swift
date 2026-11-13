import Foundation
import simd

/// Diagnostic glyph snapshot used by `Runtime.checkRestingRaster` (`runtime/paint/raster_check.rs`).
public struct RasterCheckGlyph: Equatable, Sendable {
    public let rect: SIMD4<Float>
    public let radii: SIMD4<Float>
    public let border: SIMD4<Float>
    public let params: SIMD4<Float>
    public let uvSize: SIMD2<Float>

    public init(
        rect: SIMD4<Float>,
        radii: SIMD4<Float>,
        border: SIMD4<Float>,
        params: SIMD4<Float>,
        uvSize: SIMD2<Float>
    ) {
        self.rect = rect
        self.radii = radii
        self.border = border
        self.params = params
        self.uvSize = uvSize
    }
}

public enum RasterCheck {
    /// Mirrors `cfg!(debug_assertions) && env("RUNE_RASTER_CHECK") != "0"`.
    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        #if DEBUG
        guard let v = environment["RUNE_RASTER_CHECK"] else { return false }
        return v != "0"
        #else
        return false
        #endif
    }

    /// Extracts all `KIND_GLYPH` instances in draw order for comparison against a cold paint.
    public static func glyphs(in instances: [RenderInstance]) -> [RasterCheckGlyph] {
        instances.compactMap { inst in
            guard Int(inst.params.y.rounded()) == Int(KIND_GLYPH) else { return nil }
            return RasterCheckGlyph(
                rect: inst.rect,
                radii: inst.radii,
                border: inst.border,
                params: inst.params,
                uvSize: SIMD2<Float>(inst.uv.z, inst.uv.w)
            )
        }
    }

    /// An unturned glyph or icon drawn larger or smaller than its atlas mask by more than 1/256.
    public static func magnifies(_ inst: RenderInstance) -> Bool {
        guard Int(inst.params.y.rounded()) == Int(KIND_GLYPH),
              inst.params.x == 0.0,
              inst.uv.z > 0.0
        else {
            return false
        }
        let texels: Float = inst.radii.x > 0.5 ? 3.0 : 1.0
        return abs(inst.rect.z * texels / inst.uv.z - 1.0) > (1.0 / 256.0)
    }
}

public struct RasterCheckReport: Equatable, Sendable {
    public let settledGlyphCount: Int
    public let freshGlyphCount: Int
    public let differCount: Int
    public let magnifiedCount: Int
    public let isClean: Bool
}

extension Runtime {
    /// Re-paints a resting frame cleanly and checks whether any resting glyph differs from a cold paint
    /// or draws its atlas mask magnified/shrunk (`runtime/paint/raster_check.rs`).
    @discardableResult
    public func checkRestingRaster(at t: Double? = nil) -> RasterCheckReport {
        let sampleTime = t ?? lastScaledAnimNow
        let settledFrame = renderFrame(at: sampleTime)
        let settled = RasterCheck.glyphs(in: settledFrame.instances)

        // Forget cached glyph-run shaping/elision state and re-build cold (`text.forget_raster_state()`).
        textSystem.forgetRasterState()
        let freshFrame = renderFrame(at: sampleTime)
        let fresh = RasterCheck.glyphs(in: freshFrame.instances)

        let pairCount = min(settled.count, fresh.count)
        var differCount = abs(settled.count - fresh.count)
        for i in 0..<pairCount where settled[i] != fresh[i] {
            differCount += 1
        }

        let magnified = settledFrame.instances.filter { RasterCheck.magnifies($0) }
        if differCount > 0 {
            let msg = "rune: raster check at \(String(format: "%.3f", sampleTime)) s: \(differCount) of \(settled.count) resting glyphs differ\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
        if !magnified.isEmpty {
            let msg = "rune: raster check at \(String(format: "%.3f", sampleTime)) s: \(magnified.count) resting glyphs or icons draw a mask stretched\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }

        return RasterCheckReport(
            settledGlyphCount: settled.count,
            freshGlyphCount: fresh.count,
            differCount: differCount,
            magnifiedCount: magnified.count,
            isClean: differCount == 0 && magnified.isEmpty
        )
    }
}
