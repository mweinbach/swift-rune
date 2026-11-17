import Foundation

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
    internal static let enabled = isEnabled()

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
            guard inst.params.y == KIND_GLYPH else { return nil }
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
        guard inst.params.y == KIND_GLYPH,
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

extension RasterCheck {
    internal static func compare(_ settledFrame: RenderFrame, _ freshFrame: RenderFrame, at time: Double) -> RasterCheckReport {
        let settled = glyphs(in: settledFrame.instances)
        let fresh = glyphs(in: freshFrame.instances)
        let differences = zip(settled, fresh).filter { $0 != $1 }
        let differCount = differences.count + abs(settled.count - fresh.count)
        let magnified = freshFrame.instances.filter(magnifies)
        if differCount > 0 {
            var details = "rune: raster check at \(String(format: "%.3f", time)) s: \(differCount) of \(settled.count) resting glyphs differ\n"
            for (rest, cold) in differences.prefix(3) {
                details += "  resting \(rest)\n  fresh   \(cold)\n"
            }
            FileHandle.standardError.write(Data(details.utf8))
        }
        if !magnified.isEmpty {
            let examples = magnified.prefix(3).map { "\($0.rect) \($0.uv)" }.joined(separator: ", ")
            let msg = "rune: raster check at \(String(format: "%.3f", time)) s: \(magnified.count) stretched masks (rect, atlas uv): \(examples)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
        return RasterCheckReport(settledGlyphCount: settled.count, freshGlyphCount: fresh.count,
                                 differCount: differCount, magnifiedCount: magnified.count,
                                 isClean: differCount == 0 && magnified.isEmpty)
    }
}
