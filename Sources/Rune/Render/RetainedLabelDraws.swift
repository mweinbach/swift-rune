/// A mask draw keeps its page-local UVs until every glyph page in this frame is known.
internal typealias GlyphUVFixup = (
    index: Int, normUV: SIMD4<Float>, texW: Float, texH: Float, page: UInt16, forceScaled: Bool
)

/// Rasterized, fully visible label runs can move by whole device pixels without changing mask placement.
/// Shaping and hit geometry still run before this point. Retain the source buffers so changing
/// the glyphs or their exact resting pens invalidates a replay through copy-on-write.
internal struct RetainedLabelDraws {
    struct Draw {
        var instance: RenderInstance
        var page: UInt16
    }

    struct Source {
        private let glyphs: [PositionedGlyph]
        #if canImport(CoreText) && canImport(CoreGraphics)
        private let pens: [GlyphPen]
        private let placements: TextBoxGeometry.GlyphPlacements?
        #endif

        init(_ shape: ShapedText) {
            glyphs = shape.glyphs
            #if canImport(CoreText) && canImport(CoreGraphics)
            pens = shape.glyphPens
            placements = shape.glyphPlacements
            #endif
        }

        func matches(_ shape: ShapedText) -> Bool {
            #if canImport(CoreText) && canImport(CoreGraphics)
            guard placements === shape.glyphPlacements, sameStorage(pens, shape.glyphPens) else { return false }
            #endif
            return sameStorage(glyphs, shape.glyphs)
        }

        private func sameStorage<T>(_ a: [T], _ b: [T]) -> Bool {
            a.count == b.count && a.withUnsafeBufferPointer { lhs in
                b.withUnsafeBufferPointer { $0.baseAddress == lhs.baseAddress }
            }
        }
    }

    var source: Source
    var origin: SIMD2<Float>
    var bounds: SIMD4<Float>
    var ink: SIMD4<Float>
    // Span colors come from the retained glyphs. Their alpha can change even if default ink is clear.
    var opacity: Float
    var baseline: Float?
    var scale: Float
    var smoothing: FontSmoothing
    var srgb: Bool
    var pages: Set<UInt16>
    var resets: UInt64
    var draws: [Draw]

    func replay(
        shaped: ShapedText, at origin: SIMD2<Float>, clip: SIMD4<Float>, fade: SIMD4<UInt32>,
        visible: SIMD4<Float>, ink: SIMD4<Float>, opacity: Float, baseline: Float?, scale: Float, smoothing: FontSmoothing, srgb: Bool,
        atlas: GlyphAtlas, into instances: inout [RenderInstance], marks: inout [UInt32], fixups: inout [GlyphUVFixup]
    ) -> Bool {
        guard self.ink == ink, self.opacity == opacity, self.baseline == baseline, self.scale == scale, self.smoothing == smoothing, self.srgb == srgb,
              source.matches(shaped) else { return false }
        let dx = origin.x - self.origin.x, dy = origin.y - self.origin.y
        guard dx == 0, origin.y >= 0, self.origin.y >= 0, dy.rounded() == dy,
              origin.y - origin.y.rounded(.down) == self.origin.y - self.origin.y.rounded(.down),
              bounds.x + dx >= visible.x, bounds.y + dy >= visible.y,
              bounds.z + dx <= visible.z, bounds.w + dy <= visible.w,
              atlas.retainPages(pages, since: resets) else { return false }
        for draw in draws {
            var glyph = draw.instance
            glyph.rect.x += dx
            glyph.rect.y += dy
            glyph.clip = clip
            glyph.fade = fade
            fixups.append((instances.count, glyph.uv, glyph.rect.z, glyph.rect.w, draw.page, false))
            instances.append(glyph)
            marks.append(0)
        }
        return true
    }
}
