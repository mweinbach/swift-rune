import Foundation
import RuneMotion

/// Shared rendering & timing helpers for Slice 1 `el/` builders (`Runtime` and `RenderElAndRuntime`).
internal enum ShellSliceRenderHelpers {
    /// Resolves strikethrough quads `[rectPx, colorVec4]` for `El.strike` / `El.strikes`
    /// matching `rune::text::decorations::strike_decorations`.
    static func strikeQuads(
        strikes: [ElStrikeSpec],
        richSpans: [TextSpan]?,
        text: String,
        shaped: ShapedText,
        textSystem: TextSystem,
        styleSize: Float,
        defaultTextColor: Color,
        textOriginX: Float,
        textOriginY: Float,
        scaleVec: Vec2,
        pxScale: Float,
        localAlpha: Float,
        srgbBlend: Bool
    ) -> [(rect: SIMD4<Float>, color: SIMD4<Float>)] {
        guard !strikes.isEmpty, !text.isEmpty, localAlpha > 0.0005 else { return [] }
        let spanRanges = buildRichSpanRanges(richSpans)
        let textLen = text.utf8.count
        let thicknessPt = max(1.0, styleSize * 0.06)
        var out: [(rect: SIMD4<Float>, color: SIMD4<Float>)] = []
        out.reserveCapacity(strikes.count)

        for spec in strikes {
            let a = clampToUTF8Boundary(max(0, min(spec.byteRange.lowerBound, textLen)), in: text)
            let b = clampToUTF8Boundary(max(a, min(spec.byteRange.upperBound, textLen)), in: text)
            guard a < b else { continue }

            let strikeColor = spec.color
                ?? overlappingRichSpanColor(range: a..<b, spanRanges: spanRanges)
                ?? defaultTextColor
            let c4 = strikeColor.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
            guard c4.w > 0.0005 else { continue }

            for r in textSystem.selectionRects(in: shaped, utf8Range: a..<b, pixelScale: pxScale) {
                guard r.z > 0.01 else { continue }
                let syPt = r.y + r.w * 0.52
                let quad = SIMD4<Float>(
                    (textOriginX + r.x * scaleVec.x) * pxScale,
                    (textOriginY + syPt * scaleVec.y) * pxScale,
                    r.z * scaleVec.x * pxScale,
                    thicknessPt * scaleVec.y * pxScale
                )
                out.append((quad, c4))
            }
        }
        return out
    }

    private static func buildRichSpanRanges(_ spans: [TextSpan]?) -> [(Range<Int>, Color)] {
        guard let spans, !spans.isEmpty else { return [] }
        var out: [(Range<Int>, Color)] = []
        out.reserveCapacity(spans.count)
        var cursor = 0
        for s in spans {
            let len = s.text.utf8.count
            if len > 0, let col = s.color {
                out.append((cursor..<(cursor + len), col))
            }
            cursor += len
        }
        return out
    }

    private static func overlappingRichSpanColor(range: Range<Int>, spanRanges: [(Range<Int>, Color)]) -> Color? {
        for (sr, col) in spanRanges {
            if max(range.lowerBound, sr.lowerBound) < min(range.upperBound, sr.upperBound) {
                return col
            }
        }
        return nil
    }

    private static func clampToUTF8Boundary(_ offset: Int, in string: String) -> Int {
        let utf8 = string.utf8
        if offset <= 0 { return 0 }
        if offset >= utf8.count { return utf8.count }
        let idx = utf8.index(utf8.startIndex, offsetBy: offset)
        if let valid = idx.samePosition(in: string) {
            return utf8.distance(from: utf8.startIndex, to: valid)
        }
        var cur = idx
        while cur > utf8.startIndex {
            cur = utf8.index(before: cur)
            if cur.samePosition(in: string) != nil {
                return utf8.distance(from: utf8.startIndex, to: cur)
            }
        }
        return 0
    }

    /// Computes crisp pixel-snapped outline box geometry matching `runtime/paint/build.rs:1090-1106`.
    static func resolvedOutlineGeometry(
        outline: Outline,
        devRect: SIMD4<Float>,
        devRadii: SIMD4<Float>,
        pxScale: Float,
        avgScale: Float
    ) -> (rect: SIMD4<Float>, radii: SIMD4<Float>, widthPx: Float)? {
        guard outline.width > 0, outline.color.a > 0.0005 else { return nil }
        let ow = snapBorderWidthPx(outline.width, scale: pxScale) * avgScale
        let offPx: Float
        if outline.offset > 0 {
            offPx = snapBorderWidthPx(outline.offset, scale: pxScale)
        } else if outline.offset < 0 {
            offPx = -snapBorderWidthPx(-outline.offset, scale: pxScale)
        } else {
            offPx = 0
        }
        let g = ow + offPx * avgScale
        let rect = SIMD4<Float>(
            devRect.x - g,
            devRect.y - g,
            max(0, devRect.z + 2.0 * g),
            max(0, devRect.w + 2.0 * g)
        )
        let radii = SIMD4<Float>(
            devRadii.x != 0 ? max(0, devRadii.x + (devRadii.x >= 0 ? g : -g)) : 0,
            devRadii.y != 0 ? max(0, devRadii.y + (devRadii.y >= 0 ? g : -g)) : 0,
            devRadii.z != 0 ? max(0, devRadii.z + (devRadii.z >= 0 ? g : -g)) : 0,
            devRadii.w != 0 ? max(0, devRadii.w + (devRadii.w >= 0 ? g : -g)) : 0
        )
        return (rect, radii, ow)
    }

    /// Counts distinct paint leaves directly attached to `el` (used by `El.layerOpacity`).
    static func countOwnPaints<State>(_ el: El<State>, hasText: Bool, totalShapePieces: Int) -> Int {
        var count = totalShapePieces
        if el.background.a > 0.001 || el.gradient != nil { count += 1 }
        if el.borderColor.a > 0.001 && (el.borderWidth > 0 || el.borderSides != nil) { count += 1 }
        if !el.shadows.isEmpty { count += 1 }
        if el.elOutline != nil { count += 1 }
        if el.imagePayload != nil || el.pixelsPayload != nil || el.surfacePayload != nil { count += 1 }
        if el.iconPayload != nil { count += 1 }
        if hasText { count += 1 }
        return count
    }
}
