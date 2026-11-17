import Foundation
#if canImport(CoreText)
import CoreText
import CoreGraphics
#elseif canImport(CRuneDesktopText)
import CRuneDesktopText
#endif

/// The native shaper's glyph ID and device-space pen, including spaces and ligatures.
package struct TextQualityGlyph: Encodable {
    package let id: UInt32
    package let x, y, advance: Float

    private enum CodingKeys: String, CodingKey { case id, x, y, advance }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        // serde_json::json! promotes f32 to f64 before writing its decimal representation.
        try c.encode(Double(advance), forKey: .advance)
    }
}

package struct TextQualityMask {
    package let x, y, width, height: Int
    package let bytes: [UInt8]

    package init(x: Int, y: Int, width: Int, height: Int, bytes: [UInt8]) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    #if canImport(CoreText)
    package static func covering(_ contours: [[SIMD2<Double>]], bounds: (min: SIMD2<Float>, max: SIMD2<Float>)) -> Self? {
        guard let mask = AppleClassicCoverage.mask(contours, shiftY: 0, maximumSide: GlyphAtlas.atlasSize, bounds: bounds) else { return nil }
        return Self(x: Int(mask.bearing.x), y: Int(mask.bearing.y), width: mask.width, height: mask.height, bytes: mask.bytes)
    }
    #endif
}

extension TextSystem {
    /// Install the supplied file into the same process font collection used by normal layouts.
    package func setQualityFont(file: URL, family: String) throws {
        #if canImport(CoreText)
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error) {
            guard let reason = error?.takeRetainedValue() else {
                throw PixelCompareError.message("Failed to register font at \(file.path)")
            }
            guard CFErrorGetCode(reason) == CTFontManagerError.alreadyRegistered.rawValue else { throw reason }
        }
        #elseif os(Linux) || os(Windows)
        guard rune_desktop_register_font_file(file.path) != 0 else {
            throw PixelCompareError.message("Failed to register font at \(file.path)")
        }
        #else
        throw PixelCompareError.message("Text quality requires a desktop native font collection")
        #endif
        _ = setFamilies(sans: family, mono: family)
    }
}

extension ShapedText {
    package var qualityAdvance: Float { lastLineAdvancePx }

    #if canImport(CoreText)
    package func qualityAppleRuns(origin: SIMD2<Float>, scale: Float, _ visit: (CTRun, Float, Float) -> Void) {
        for (record, baseline) in zip(lineStrings, TextBoxGeometry.roundedBaselines(originYPx: origin.y, shaped: self)) {
            guard let line = record.ctLine, let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            let left = origin.x + record.originX * scale
            for run in runs { visit(run, left, baseline) }
        }
    }
    #endif

    package func qualityGlyphs(origin: SIMD2<Float>, scale: Float) throws -> [TextQualityGlyph] {
        #if canImport(CoreText)
        var glyphs = [TextQualityGlyph]()
        qualityAppleRuns(origin: origin, scale: scale) { run, left, baseline in
            let range = CFRange(location: 0, length: CTRunGetGlyphCount(run))
            var ids = [CGGlyph](repeating: 0, count: range.length)
            var positions = [CGPoint](repeating: .zero, count: range.length)
            var advances = [CGSize](repeating: .zero, count: range.length)
            CTRunGetGlyphs(run, range, &ids)
            CTRunGetPositions(run, range, &positions)
            CTRunGetAdvances(run, range, &advances)
            for i in ids.indices {
                let x = left + Float(positions[i].x)
                glyphs.append(TextQualityGlyph(id: UInt32(ids[i]), x: (x * 4).rounded() / 4,
                    y: (baseline - Float(positions[i].y)).rounded(), advance: Float(advances[i].width)))
            }
        }
        return glyphs
        #elseif os(Linux) || os(Windows)
        return try desktopQualityGlyphs(origin: origin)
        #else
        throw PixelCompareError.message("Native glyph metadata is unavailable on this platform")
        #endif
    }

    /// The exact production masks with the upstream example's constant mask gamma and ink.
    package func qualityInstances(origin: SIMD2<Float>, scale: Float, atlas: GlyphAtlas) -> [RenderInstance] {
        #if os(Linux) || os(Windows)
        let placed = desktopQualityPlaced(at: origin, scale: scale, atlas: atlas)
        #else
        let baselines = TextBoxGeometry.roundedBaselines(originYPx: origin.y, shaped: self)
        var line = 0
        let placed = glyphs.enumerated().map { i, source in
            TextBoxGeometry.paintGlyph(source, index: i, shaped: self, origin: origin,
                scale: SIMD2(repeating: 1), pixelScale: scale, restsExact: true,
                baselines: baselines, line: &line, atlas: atlas)
        }
        #endif
        let page = atlas.pagePixelSize
        return placed.compactMap { glyph, rect in
            guard glyph.uv != .zero, rect.z > 0, rect.w > 0 else { return nil }
            return RenderInstance(rect: rect, fill: SIMD4(repeating: 1),
                params: SIMD4(0, KIND_GLYPH, Float(glyph.atlasPage), 1),
                uv: SIMD4((glyph.uv.x * Float(page.x)).rounded(), (glyph.uv.y * Float(page.y)).rounded(), 0, 0))
        }
    }
}
