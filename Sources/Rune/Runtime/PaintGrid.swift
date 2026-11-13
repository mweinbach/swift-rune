import Foundation
import RuneMotion
#if canImport(simd)
import simd
#endif

/// Painting a terminal's cell grid (`El.terminalGrid`, `crates/rune/src/runtime/paint/grid.rs`).
internal enum PaintGrid {
    /// Emits vector stroke segments and triangulated fills for `shape` at device-pixel `origin`.
    static func pushShape(
        _ shape: Shape,
        originPx: SIMD2<Float>,
        scaleXY: SIMD2<Float>,
        strokeScale: Float,
        opacity: Float,
        srgbBlend: Bool,
        clip: SIMD4<Float>,
        fade: SIMD4<UInt32>,
        into instances: inout [RenderInstance],
        marks: inout [UInt32]
    ) {
        let sx = scaleXY.x
        let sy = scaleXY.y
        let swScale = strokeScale
        let ox = originPx.x
        let oy = originPx.y
        for op in shape.ops {
            switch op {
            case let .stroke(points, closed, strokeWidth, cap, color):
                guard points.count >= 2 else { continue }
                let hw = max(0.25, strokeWidth * 0.5 * swScale)
                let pad = hw + 1.5
                let col = premulSIMD4(color, opacity: opacity, srgb: srgbBlend)
                let capFlag: Float = cap == .round ? 1.0 : 0.0
                let segCount = closed ? points.count : (points.count - 1)
                for sIdx in 0..<segCount {
                    let pa = points[sIdx]
                    let pb = points[(sIdx + 1) % points.count]
                    let ax = ox + pa.x * sx
                    let ay = oy + pa.y * sy
                    let bx = ox + pb.x * sx
                    let by = oy + pb.y * sy
                    let minX = min(ax, bx) - pad
                    let minY = min(ay, by) - pad
                    let maxX = max(ax, bx) + pad
                    let maxY = max(ay, by) + pad
                    instances.append(RenderInstance(
                        rect: SIMD4<Float>(minX, minY, maxX - minX, maxY - minY),
                        radii: SIMD4<Float>(ax, ay, bx, by),
                        fill: col,
                        border: .zero,
                        params: SIMD4<Float>(hw, KIND_SEGMENT, capFlag, 1.0),
                        uv: .zero,
                        clip: clip,
                        fade: fade
                    ))
                    marks.append(0)
                }
            case let .fill(points, color):
                let tris = Shape.triangulate(points)
                let col = premulSIMD4(color, opacity: opacity, srgb: srgbBlend)
                for (indices, aaMask) in tris {
                    let p0 = points[indices[0]]
                    let p1 = points[indices[1]]
                    let p2 = points[indices[2]]
                    let v0 = SIMD2<Float>(ox + p0.x * sx, oy + p0.y * sy)
                    let v1 = SIMD2<Float>(ox + p1.x * sx, oy + p1.y * sy)
                    let v2 = SIMD2<Float>(ox + p2.x * sx, oy + p2.y * sy)
                    let minX = min(v0.x, min(v1.x, v2.x)) - 1.5
                    let minY = min(v0.y, min(v1.y, v2.y)) - 1.5
                    let maxX = max(v0.x, max(v1.x, v2.x)) + 1.5
                    let maxY = max(v0.y, max(v1.y, v2.y)) + 1.5
                    instances.append(RenderInstance(
                        rect: SIMD4<Float>(minX, minY, maxX - minX, maxY - minY),
                        radii: SIMD4<Float>(v0.x, v0.y, v1.x, v1.y),
                        fill: col,
                        border: .zero,
                        params: SIMD4<Float>(Float(aaMask), KIND_TRIANGLE, 0, 1.0),
                        uv: SIMD4<Float>(v2.x, v2.y, 0, 0),
                        clip: clip,
                        fade: fade
                    ))
                    marks.append(0)
                }
            }
        }
    }

    /// Paints `grid` inside snapped device-pixel box `rectPx` (`x, y, w, h`), matching each
    /// row's cell alignment, fills, pinned wide cells, overflow clip, overlay shape, and row cache.
    static func paint(
        _ grid: TerminalGrid,
        rectPx: SIMD4<Float>,
        rExactPx: SIMD4<Float>,
        clip: SIMD4<Float>,
        fade: SIMD4<UInt32>,
        opacity: Float,
        scale: Float,
        srgbBlend: Bool,
        fontSmoothing: FontSmoothing,
        textSystem: TextSystem,
        defaultTextColor: Color,
        into instances: inout [RenderInstance],
        marks: inout [UInt32],
        glyphFixups: inout [(index: Int, normUV: SIMD4<Float>, texW: Float, texH: Float, page: UInt16, forceScaled: Bool)]
    ) {
        let roundPx: (Float) -> Float = { floorf($0 + 0.5) }
        let shift = SIMD2<Float>(roundPx(rectPx.x) - roundPx(rExactPx.x), roundPx(rectPx.y) - roundPx(rExactPx.y))
        let originPt = SIMD2<Float>(rExactPx.x / max(scale, 1e-4), rExactPx.y / max(scale, 1e-4))
        let px: (Float) -> Float = { Snap.grid($0, scale: scale) * scale }
        let cw = grid.cellSize.x
        let ch = grid.cellSize.y
        let cols = Float(grid.columns)
        let emitGen = textSystem.glyphAtlas.generation
        let edge: (Float, Float, Float, Float) -> SIMD4<Float> = { ax, ay, bx, by in
            let rx0 = roundPx(ax)
            let ry0 = roundPx(ay)
            let rx1 = max(roundPx(bx), rx0 + 1.0)
            let ry1 = max(roundPx(by), ry0 + 1.0)
            return SIMD4<Float>(rx0 + shift.x, ry0 + shift.y, rx1 + shift.x, ry1 + shift.y)
        }

        for (k, row) in grid.rows.enumerated() {
            let y0 = px(originPt.y + Float(k) * ch)
            let y1 = px(originPt.y + Float(k + 1) * ch)
            if roundPx(y0) + shift.y > clip.w || roundPx(y1) + shift.y < clip.y {
                continue
            }
            let x0 = px(originPt.x)
            let x1 = px(originPt.x + cols * cw)
            let rowR = edge(x0, y0, x1, y1)
            let key = rowCacheKey(
                rowRect: rowR,
                clip: clip,
                fade: fade,
                opacity: opacity,
                scale: scale,
                srgbBlend: srgbBlend,
                smoothing: fontSmoothing,
                emitGeneration: emitGen
            )

            if let drawn = row._cache.getDrawn(key: key) {
                let baseIdx = instances.count
                instances.append(contentsOf: drawn.instances)
                marks.append(contentsOf: repeatElement(UInt32(0), count: drawn.instances.count))
                for fix in drawn.glyphFixups {
                    glyphFixups.append((baseIdx + fix.offset, fix.normUV, fix.texW, fix.texH, fix.page, false))
                }
                continue
            }

            let rowStartIdx = instances.count
            let rowFixupStartIdx = glyphFixups.count
            let laid = laidRow(row, widthPt: cols * cw, scale: scale, textSystem: textSystem)

            // 1. Background and selection runs
            for f in row.fills {
                let fx0 = px(originPt.x + Float(f.startColumn) * cw)
                let fx1 = px(originPt.x + Float(f.endColumn) * cw)
                let b = edge(fx0, y0, fx1, y1)
                let fill = premulSIMD4(f.color, opacity: opacity, srgb: srgbBlend)
                if fill.w > 0.0005 {
                    instances.append(RenderInstance(
                        rect: SIMD4<Float>(b.x, b.y, b.z - b.x, b.w - b.y),
                        radii: .zero,
                        fill: fill,
                        border: .zero,
                        params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
                        uv: .zero,
                        clip: clip,
                        fade: fade
                    ))
                    marks.append(0)
                }
            }

            // 2. Narrow-cell text line (clipped to row when overflowing)
            let lineShaped = laid.line
            let lineWidthPx = ceilf(lineShaped.size.x * scale)
            let exactW = x1 - x0
            let overflows = lineWidthPx > cols * cw * scale + 0.5 && lineWidthPx > max(rowR.z - rowR.x, exactW) + 0.5
            var bounds = rowR
            if !overflows {
                bounds.z = max(bounds.z, bounds.x + max(exactW, lineWidthPx))
            }
            let textClip = intersectClipRects(clip, bounds)
            var glyphsEmitted = 0
            glyphsEmitted += emitGridText(
                shaped: lineShaped,
                originPx: SIMD2<Float>(rowR.x, rowR.y),
                baseColor: defaultTextColor,
                opacity: opacity,
                scale: scale,
                srgbBlend: srgbBlend,
                cullClip: clip,
                glyphClip: textClip,
                fade: fade,
                into: &instances,
                marks: &marks,
                glyphFixups: &glyphFixups
            )

            // 3. Pinned wide/fallback cells
            for (cell, cellShaped) in zip(row.cells, laid.cells) {
                let cx = roundPx(px(originPt.x + Float(cell.column) * cw)) + shift.x
                glyphsEmitted += emitGridText(
                    shaped: cellShaped,
                    originPx: SIMD2<Float>(cx, rowR.y),
                    baseColor: cell.color,
                    opacity: opacity,
                    scale: scale,
                    srgbBlend: srgbBlend,
                    cullClip: clip,
                    glyphClip: clip,
                    fade: fade,
                    into: &instances,
                    marks: &marks,
                    glyphFixups: &glyphFixups
                )
            }

            // 4. Overlay vector layer (`row.shape(...)`)
            if let shape = row.overlayShape {
                let at = SIMD2<Float>(roundPx(x0) + shift.x, roundPx(y0) + shift.y)
                pushShape(
                    shape,
                    originPx: at,
                    scaleXY: SIMD2<Float>(scale, scale),
                    strokeScale: scale,
                    opacity: opacity,
                    srgbBlend: srgbBlend,
                    clip: clip,
                    fade: fade,
                    into: &instances,
                    marks: &marks
                )
            }

            let rowInstances = Array(instances[rowStartIdx..<instances.count])
            let relFixups = glyphFixups[rowFixupStartIdx..<glyphFixups.count].map { fix in
                (fix.index - rowStartIdx, fix.normUV, fix.texW, fix.texH, fix.page)
            }
            row._cache.setDrawn(TerminalGridRowCache.Drawn(
                key: key,
                instances: rowInstances,
                glyphFixups: relFixups,
                glyphCount: glyphsEmitted
            ))
        }
    }

    private static func laidRow(
        _ row: TerminalGridRow,
        widthPt: Float,
        scale: Float,
        textSystem: TextSystem
    ) -> (line: ShapedText, cells: [ShapedText]) {
        let scaleBits = scale.bitPattern
        let widthBits = widthPt.bitPattern
        if let cached = row._cache.getLaid(scaleBits: scaleBits, widthBits: widthBits) {
            return cached
        }
        let wrapWidth: Float? = row.style.wrap == .wrap ? widthPt : nil
        let line = textSystem.shape(
            text: row.text,
            spans: row.spans.isEmpty ? nil : row.spans,
            pills: [],
            style: row.style,
            maxWidth: wrapWidth,
            pixelScale: scale,
            glidePx: .zero
        )
        let cells = row.cells.map { cell in
            textSystem.shape(
                text: cell.text,
                spans: nil,
                pills: [],
                style: cell.style,
                maxWidth: nil,
                pixelScale: scale,
                glidePx: .zero
            )
        }
        row._cache.setLaid(scaleBits: scaleBits, widthBits: widthBits, line: line, cells: cells)
        return (line, cells)
    }

    /// Emits text backgrounds, rounded pill chips, underlines, and strikethroughs for `shaped` text.
    static func emitTextDecorations(
        shaped: ShapedText,
        originPt: SIMD2<Float>,
        scaleVec: Vec2 = Vec2(1, 1),
        baseColor: Color,
        opacity: Float,
        scale: Float,
        srgbBlend: Bool,
        clip: SIMD4<Float>,
        fade: SIMD4<UInt32>,
        textSystem: TextSystem? = nil,
        forceScaled: Bool = false,
        emitBackgrounds: Bool = true,
        into instances: inout [RenderInstance],
        marks: inout [UInt32],
        glyphFixups: inout [(index: Int, normUV: SIMD4<Float>, texW: Float, texH: Float, page: UInt16, forceScaled: Bool)]
    ) {
        if emitBackgrounds {
            for (bgRect, bgColor) in shaped.backgrounds {
                let fill = premulSIMD4(bgColor, opacity: opacity, srgb: srgbBlend)
                if fill.w <= 0.0005 { continue }
                instances.append(RenderInstance(
                    rect: SIMD4<Float>(
                        (originPt.x + bgRect.x * scaleVec.x) * scale,
                        (originPt.y + bgRect.y * scaleVec.y) * scale,
                        bgRect.z * scaleVec.x * scale,
                        bgRect.w * scaleVec.y * scale
                    ),
                    radii: SIMD4<Float>(repeating: min(4.0, bgRect.w * 0.3) * scale),
                    fill: fill,
                    border: .zero,
                    params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
                    uv: .zero,
                    clip: clip,
                    fade: fade
                ))
                marks.append(0)
            }
        }
        for chip in shaped.pillChips {
            let chipCol = premulSIMD4(chip.background ?? Color(r: 0.22, g: 0.25, b: 0.32, a: 0.22), opacity: opacity, srgb: srgbBlend)
            let ringCol = chip.ring.map { premulSIMD4($0.color, opacity: opacity, srgb: srgbBlend) } ?? .zero
            let ringW = (chip.ring?.width ?? 0) * scale
            instances.append(RenderInstance(
                rect: SIMD4<Float>(
                    (originPt.x + chip.rect.x * scaleVec.x) * scale,
                    (originPt.y + chip.rect.y * scaleVec.y) * scale,
                    chip.rect.z * scaleVec.x * scale,
                    chip.rect.w * scaleVec.y * scale
                ),
                radii: SIMD4<Float>(repeating: chip.cornerRadius * scale),
                fill: chipCol,
                border: ringCol,
                params: SIMD4<Float>(ringW, KIND_RECT, 0.5, 1.0),
                uv: .zero,
                clip: clip,
                fade: fade
            ))
            marks.append(0)
            if let textSystem, let svg = chip.icon, let ir = chip.iconRect {
                let pxSize = max(4, Int((min(ir.z, ir.w) * scale).rounded()))
                let entry = textSystem.glyphAtlas.rasterizeIcon(svg, pixelSize: pxSize)
                let tint = premulSIMD4(chip.iconColor ?? baseColor, opacity: opacity, srgb: srgbBlend)
                let iw = ir.z * scaleVec.x * scale
                let ih = ir.w * scaleVec.y * scale
                let idx = instances.count
                instances.append(RenderInstance(
                    rect: SIMD4<Float>(
                        (originPt.x + ir.x * scaleVec.x) * scale,
                        (originPt.y + ir.y * scaleVec.y) * scale,
                        iw,
                        ih
                    ),
                    radii: .zero,
                    fill: tint,
                    border: .zero,
                    params: SIMD4<Float>(0, KIND_GLYPH, 0, 1.0),
                    uv: entry.uv,
                    clip: clip,
                    fade: fade
                ))
                marks.append(0)
                glyphFixups.append((idx, entry.uv, iw, ih, entry.page, forceScaled))
            }
        }
        let lineColor = premulSIMD4(baseColor, opacity: opacity, srgb: srgbBlend)
        if lineColor.w > 0.0005 {
            for u in shaped.underlines {
                instances.append(RenderInstance(
                    rect: SIMD4<Float>(
                        (originPt.x + u.x * scaleVec.x) * scale,
                        (originPt.y + u.y * scaleVec.y) * scale,
                        u.z * scaleVec.x * scale,
                        max(1.0, u.w * scaleVec.y * scale)
                    ),
                    radii: .zero,
                    fill: lineColor,
                    border: .zero,
                    params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
                    uv: .zero,
                    clip: clip,
                    fade: fade
                ))
                marks.append(0)
            }
            for st in shaped.strikethroughs {
                instances.append(RenderInstance(
                    rect: SIMD4<Float>(
                        (originPt.x + st.x * scaleVec.x) * scale,
                        (originPt.y + st.y * scaleVec.y) * scale,
                        st.z * scaleVec.x * scale,
                        max(1.0, st.w * scaleVec.y * scale)
                    ),
                    radii: .zero,
                    fill: lineColor,
                    border: .zero,
                    params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
                    uv: .zero,
                    clip: clip,
                    fade: fade
                ))
                marks.append(0)
            }
        }
    }

    private static func emitGridText(
        shaped: ShapedText,
        originPx: SIMD2<Float>,
        baseColor: Color,
        opacity: Float,
        scale: Float,
        srgbBlend: Bool,
        cullClip: SIMD4<Float>,
        glyphClip: SIMD4<Float>,
        fade: SIMD4<UInt32>,
        into instances: inout [RenderInstance],
        marks: inout [UInt32],
        glyphFixups: inout [(index: Int, normUV: SIMD4<Float>, texW: Float, texH: Float, page: UInt16, forceScaled: Bool)]
    ) -> Int {
        emitTextDecorations(
            shaped: shaped,
            originPt: SIMD2<Float>(originPx.x / max(scale, 1e-4), originPx.y / max(scale, 1e-4)),
            baseColor: baseColor,
            opacity: opacity,
            scale: scale,
            srgbBlend: srgbBlend,
            clip: cullClip,
            fade: fade,
            into: &instances,
            marks: &marks,
            glyphFixups: &glyphFixups
        )
        var count = 0
        for gq in shaped.glyphs {
            let gx = originPx.x + gq.rect.x * scale
            let gy = originPx.y + gq.rect.y * scale
            let gw = max(1.0, gq.rect.z * scale)
            let gh = max(1.0, gq.rect.w * scale)
            if gy > cullClip.w || gy + gh < cullClip.y || gx > cullClip.z || gx + gw < cullClip.x {
                continue
            }
            let gcol = premulSIMD4(gq.color ?? baseColor, opacity: opacity, srgb: srgbBlend)
            let idx = instances.count
            instances.append(RenderInstance(
                rect: SIMD4<Float>(gx, gy, gw, gh),
                radii: .zero,
                fill: gcol,
                border: .zero,
                params: SIMD4<Float>(0, KIND_GLYPH, 0, 1.0),
                uv: gq.uv,
                clip: glyphClip,
                fade: fade
            ))
            marks.append(0)
            glyphFixups.append((idx, gq.uv, gw, gh, gq.atlasPage, false))
            count += 1
        }
        return count
    }

    private static func rowCacheKey(
        rowRect: SIMD4<Float>,
        clip: SIMD4<Float>,
        fade: SIMD4<UInt32>,
        opacity: Float,
        scale: Float,
        srgbBlend: Bool,
        smoothing: FontSmoothing,
        emitGeneration: UInt64
    ) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        fnvMixFloat4(&h, rowRect)
        fnvMixFloat4(&h, clip)
        fnvMix(&h, UInt64(fade.x))
        fnvMix(&h, UInt64(fade.y))
        fnvMix(&h, UInt64(fade.z))
        fnvMix(&h, UInt64(fade.w))
        fnvMixFloat(&h, opacity)
        fnvMixFloat(&h, scale)
        fnvMix(&h, srgbBlend ? 1 : 0)
        for byte in smoothing.rawValue.utf8 {
            fnvMix(&h, UInt64(byte))
        }
        fnvMix(&h, emitGeneration)
        return h
    }
}
