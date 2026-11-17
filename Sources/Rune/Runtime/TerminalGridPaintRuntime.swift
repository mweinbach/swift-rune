import Foundation
#if os(Android)
import Android
#endif
import RuneMotion
import RuneRef
#if canImport(simd)
import simd
#endif

// MARK: - Terminal Grid Painting (`src/runtime/paint/grid.rs`)

private final class TerminalGridDrawnRowBox {
    let key: UInt64
    let primitives: [Primitive]
    let glyphPrimOffsets: [Int]
    let glyphPages: [Int: UInt16]
    let touchedPages: [(UInt16, UInt32)]
    let glyphCount: Int

    init(
        key: UInt64,
        primitives: [Primitive],
        glyphPrimOffsets: [Int],
        glyphPages: [Int: UInt16],
        touchedPages: [(UInt16, UInt32)],
        glyphCount: Int
    ) {
        self.key = key
        self.primitives = primitives
        self.glyphPrimOffsets = glyphPrimOffsets
        self.glyphPages = glyphPages
        self.touchedPages = touchedPages
        self.glyphCount = glyphCount
    }
}

private extension TerminalGridRowCacheBox {
    func getDrawnIfMatch(_ key: UInt64) -> TerminalGridDrawnRowBox? {
        lock.lock()
        let existing = (drawnStorage as? TerminalGridDrawnRowBox).flatMap { $0.key == key ? $0 : nil }
        lock.unlock()
        return existing
    }

    func storeDrawn(_ drawn: TerminalGridDrawnRowBox) {
        lock.lock()
        drawnStorage = drawn
        lock.unlock()
    }
}

extension Runtime {
    /// Paints a `TerminalGrid` node's rows into `primitives`, reusing per-row cached instances when unchanged.
    internal func paintTerminalGrid(
        _ grid: TerminalGrid,
        devRect: SIMD4<Float>,
        exactRectPx rExact: SIMD4<Float>,
        devClip: SIMD4<Float>,
        localAlpha: Float,
        defaultColor: Color = .white,
        effRotate: Float,
        useLayer: Bool,
        lcdAvailable: (() -> Bool)? = nil,
        primitives: inout [Primitive],
        glyphPageEntries: inout [(index: Int, page: UInt16)],
        usedGlyphMask: inout UInt32,
        glyphCount: inout Int
    ) {
        let s = max(pixelScale, 0.5)
        let srgb = srgbBlend
        let cw = grid.cellSize.x
        let ch = grid.cellSize.y
        let cols = Float(grid.columns)
        let widthPt = cols * cw
        let rot: Float = useLayer ? 0 : effRotate

        @inline(__always)
        func roundEdge(_ v: Float) -> Float {
            floor(v + 0.5)
        }

        @inline(__always)
        func pxGrid(_ pt: Float) -> Float {
            // 1/64 px device grid alignment matching `rune_motion::snap::grid(pt, s) * s`.
            ((pt * s * 64.0).rounded() / 64.0)
        }

        let shiftX = devRect.x - roundEdge(rExact.x)
        let shiftY = devRect.y - roundEdge(rExact.y)
        let originPtX = rExact.x / s
        let originPtY = rExact.y / s

        @inline(__always)
        func edgeRect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> SIMD4<Float> {
            let rx0 = roundEdge(x0) + shiftX
            let ry0 = roundEdge(y0) + shiftY
            let rx1 = max(roundEdge(x1), roundEdge(x0) + 1.0) + shiftX
            let ry1 = max(roundEdge(y1), roundEdge(y0) + 1.0) + shiftY
            return SIMD4<Float>(rx0, ry0, rx1, ry1)
        }

        @inline(__always)
        func intersectClip(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
            SIMD4<Float>(max(a.x, b.x), max(a.y, b.y), min(a.z, b.z), min(a.w, b.w))
        }

        var environment = Hasher()
        environment.combine(runtimeId)
        environment.combine(textSystem.currentFontEpoch)
        environment.combine(textSystem.language)
        environment.combine(textSystem.smoothing)
        environment.combine(textSystem.rasterRevision)
        for (k, row) in grid.rows.enumerated() {
            let y0 = pxGrid(originPtY + Float(k) * ch)
            let y1 = pxGrid(originPtY + Float(k + 1) * ch)
            if roundEdge(y0) + shiftY > devClip.w || roundEdge(y1) + shiftY < devClip.y {
                continue
            }
            let x0 = pxGrid(originPtX)
            let x1 = pxGrid(originPtX + cols * cw)
            let rowR = edgeRect(x0, y0, x1, y1)

            // The row holds shaped glyph UVs. A new atlas or a recycled page requires reshaping.
            var shapeKey = environment
            shapeKey.combine(row.contentFingerprint)
            shapeKey.combine(textSystem.glyphAtlas.placementClock)
            let contentHash = UInt64(bitPattern: Int64(shapeKey.finalize()))
            let nativeLCD: Bool
            #if os(Windows)
            func wantsLCD(_ mode: FontSmoothing) -> Bool { (mode == .systemDefault ? textSystem.smoothing : mode) == .clearType }
            nativeLCD = lcdAvailable != nil && (wantsLCD(row.style.fontSmoothing) || row.cells.contains { wantsLCD($0.style.fontSmoothing) })
                && lcdAvailable?() == true
            #else
            nativeLCD = false
            #endif
            var hasher = Hasher()
            hasher.combine(contentHash)
            hasher.combine(nativeLCD)
            hasher.combine(rowR.x.bitPattern)
            hasher.combine(rowR.y.bitPattern)
            hasher.combine(rowR.z.bitPattern)
            hasher.combine(rowR.w.bitPattern)
            hasher.combine(devClip.x.bitPattern)
            hasher.combine(devClip.y.bitPattern)
            hasher.combine(devClip.z.bitPattern)
            hasher.combine(devClip.w.bitPattern)
            hasher.combine(localAlpha.bitPattern)
            hasher.combine(defaultColor.r.bitPattern)
            hasher.combine(defaultColor.g.bitPattern)
            hasher.combine(defaultColor.b.bitPattern)
            hasher.combine(defaultColor.a.bitPattern)
            hasher.combine(s.bitPattern)
            hasher.combine(srgb)
            hasher.combine(systemDark)
            hasher.combine(rot.bitPattern)
            let cacheKey = UInt64(bitPattern: Int64(hasher.finalize()))

            if let cached = row.cache.getDrawnIfMatch(cacheKey) {
                let baseIdx = primitives.count
                primitives.append(contentsOf: cached.primitives)
                for relIdx in cached.glyphPrimOffsets {
                    let absIdx = baseIdx + relIdx
                    guard let page = cached.glyphPages[relIdx] else { continue }
                    if page != 0 { glyphPageEntries.append((absIdx, page)) }
                    usedGlyphMask |= UInt32(1) << min(UInt32(page), 31)
                }
                for (page, texels) in cached.touchedPages {
                    textSystem.glyphAtlas.touch(page: page, texels: texels)
                }
                glyphCount += cached.glyphCount
                continue
            }

            let laid = row.cache.laidRow(pixelScale: s, widthPt: widthPt, contentHash: contentHash) {
                let lineMaxW: Float? = (row.style.wrap == .noWrap) ? nil : widthPt
                let lineShaped = textSystem.shape(
                    text: row.text,
                    spans: row.spans.isEmpty ? nil : row.spans,
                    style: row.style,
                    maxWidth: lineMaxW,
                    pixelScale: s,
                    emitGlyphs: true
                )
                let cellShapes = row.cells.map { cell in
                    textSystem.shape(
                        text: cell.text,
                        spans: nil,
                        style: cell.style,
                        maxWidth: nil,
                        pixelScale: s,
                        emitGlyphs: true
                    )
                }
                return (lineShaped, cellShapes)
            }

            let rowStartIdx = primitives.count
            let startGlyphCount = glyphCount
            var touchedPages: [(UInt16, UInt32)] = []
            var rowGlyphOffsets: [Int] = []
            var rowGlyphPages: [Int: UInt16] = [:]
            var cacheable = true

            // 1. Background fill runs (`row.fills`).
            for f in row.fills {
                let fx0 = pxGrid(originPtX + Float(f.startColumn) * cw)
                let fx1 = pxGrid(originPtX + Float(f.endColumn) * cw)
                let b = edgeRect(fx0, y0, fx1, y1)
                let fill4 = f.color.scaleAlpha(localAlpha).simd4(srgb: srgb)
                if fill4.w > 0.0005 {
                    primitives.append(.roundedRect(
                        rect: SIMD4<Float>(b.x, b.y, b.z - b.x, b.w - b.y),
                        radii: .zero,
                        fill: fill4,
                        clip: devClip,
                        turn: rot
                    ))
                }
            }

            // Helper emitting shaped row/cell text.
            func emitShapedText(
                _ shaped: ShapedText,
                originPtX textOrigX: Float,
                originPtY textOrigY: Float,
                baseColor: Color,
                glyphClip: SIMD4<Float>
            ) {
                let origin = SIMD2<Float>(textOrigX * s, textOrigY * s)
                let baselines = TextBoxGeometry.roundedBaselines(originYPx: origin.y, shaped: shaped)
                textSystem.emitTextDecorationsAndPills(
                    shaped: shaped,
                    textOriginX: textOrigX,
                    textOriginY: textOrigY,
                    scaleVec: Vec2(1, 1),
                    pxScale: s,
                    defaultTextColor: baseColor,
                    localAlpha: localAlpha,
                    srgbBlend: srgb,
                    devClip: devClip,
                    rot: rot,
                    roundedBaselines: baselines,
                    insertImage: { self.imagePacker.insert($0) },
                    glyphPage: { index, page in
                        if page != 0 { glyphPageEntries.append((index, page)) }
                        usedGlyphMask |= UInt32(1) << min(UInt32(page), 31)
                    },
                    into: &primitives
                )
                // Image UVs belong to the current image atlas. Reinsert them on each draw.
                if !shaped.inlineIcons.isEmpty || !shaped.pillChips.isEmpty { cacheable = false }
                var line = 0
                for (index, glyph) in shaped.glyphs.enumerated() {
                    let (g, rect) = TextBoxGeometry.paintGlyph(
                        glyph, index: index, shaped: shaped, origin: origin, scale: SIMD2(repeating: 1),
                        pixelScale: s, restsExact: true, baselines: baselines, line: &line, atlas: textSystem.glyphAtlas
                    )
                    let gx0 = rect.x, gy0 = rect.y, gw = rect.z, gh = rect.w
                    if gy0 > devClip.w || gy0 + gh < devClip.y || gx0 > devClip.z || gx0 + gw < devClip.x {
                        continue
                    }
                    let gc = (g.color ?? baseColor).scaleAlpha(localAlpha).simd4(srgb: srgb)
                    let absIdx = primitives.count
                    let relIdx = absIdx - rowStartIdx
                    let (primitive, page) = referenceTextPrimitive(g, rect: rect, ink: gc, clip: glyphClip, turn: rot, nativeLCD: nativeLCD)
                    primitives.append(primitive)
                    if primitive.kind == .image {
                        glyphCount += 1
                        cacheable = false
                        continue
                    }
                    let texels = UInt32(max(0, gw * gh))
                    if let existingIdx = touchedPages.firstIndex(where: { $0.0 == page }) {
                        touchedPages[existingIdx].1 &+= texels
                    } else {
                        touchedPages.append((page, texels))
                    }
                    if page != 0 { glyphPageEntries.append((absIdx, page)) }
                    usedGlyphMask |= UInt32(1) << min(UInt32(page), 31)
                    rowGlyphOffsets.append(relIdx)
                    rowGlyphPages[relIdx] = page
                    glyphCount += 1
                }
            }

            // 2. Main row text clipped to row bounds if overflowing.
            let lineFullPx = laid.line.size.x * s
            let exactW = x1 - x0
            let overflows = lineFullPx > widthPt * s + 0.5 && lineFullPx > max(rowR.z - rowR.x, exactW) + 0.5
            var bounds = rowR
            let rtl = laid.line.forcedDirection.map { $0 == .rtl } ?? laid.line.primaryIsRTL
            if !overflows {
                if rtl {
                    bounds.x = min(bounds.x, bounds.z - max(exactW, lineFullPx))
                } else {
                    bounds.z = max(bounds.z, bounds.x + max(exactW, lineFullPx))
                }
            }
            // Wrapped lines already align within widthPt in the shaper.
            var lineX = rowR.x
            if row.style.wrap == .noWrap {
                let extra = rowR.z - rowR.x - TextBoxGeometry.textWidth(lineFullPx)
                switch row.style.align {
                case .center: lineX += extra * 0.5
                case .leading, .justified: if rtl { lineX += extra }
                case .trailing: if !rtl { lineX += extra }
                }
            }
            let textClip = intersectClip(devClip, bounds)
            emitShapedText(
                laid.line,
                originPtX: lineX / s,
                originPtY: rowR.y / s,
                baseColor: defaultColor,
                glyphClip: textClip
            )

            // 3. Pinned wide/fallback cells (`row.cells`).
            for (cell, cellShaped) in zip(row.cells, laid.cells) {
                let cx = roundEdge(pxGrid(originPtX + Float(cell.column) * cw)) + shiftX
                emitShapedText(
                    cellShaped,
                    originPtX: cx / s,
                    originPtY: rowR.y / s,
                    baseColor: cell.color,
                    glyphClip: devClip
                )
            }

            // 4. Optional vector overlay shape (`row.overlayShape`).
            if let shape = row.overlayShape {
                let atX = roundEdge(x0) + shiftX
                let atY = roundEdge(y0) + shiftY
                for op in shape.ops {
                    switch op {
                    case let .fill(points, col):
                        let c4 = col.scaleAlpha(localAlpha).simd4(srgb: srgb)
                        if c4.w <= 0.0005 { continue }
                        for (indices, aaMask) in Shape.triangulate(points) {
                            let p0 = points[indices[0]]
                            let p1 = points[indices[1]]
                            let p2 = points[indices[2]]
                            primitives.append(.triangle(
                                v0: SIMD2<Float>(atX + p0.x * s, atY + p0.y * s),
                                v1: SIMD2<Float>(atX + p1.x * s, atY + p1.y * s),
                                v2: SIMD2<Float>(atX + p2.x * s, atY + p2.y * s),
                                aaMask: aaMask,
                                color: c4,
                                clip: devClip
                            ))
                        }
                    case let .stroke(points, closed, width, cap, col):
                        let c4 = col.scaleAlpha(localAlpha).simd4(srgb: srgb)
                        if c4.w <= 0.0005 { continue }
                        let strokeW = width * s
                        let roundCap = (cap == .round)
                        let n = points.count
                        guard n >= 2 else { continue }
                        let count = closed ? n : (n - 1)
                        for i in 0..<count {
                            let p0 = points[i]
                            let p1 = points[(i + 1) % n]
                            primitives.append(.segment(
                                from: SIMD2<Float>(atX + p0.x * s, atY + p0.y * s),
                                to: SIMD2<Float>(atX + p1.x * s, atY + p1.y * s),
                                width: strokeW,
                                color: c4,
                                roundCap: roundCap,
                                clip: devClip
                            ))
                        }
                    }
                }
            }

            if cacheable {
                let rowPrims = Array(primitives[rowStartIdx...])
                row.cache.storeDrawn(TerminalGridDrawnRowBox(
                    key: cacheKey,
                    primitives: rowPrims,
                    glyphPrimOffsets: rowGlyphOffsets,
                    glyphPages: rowGlyphPages,
                    touchedPages: touchedPages,
                    glyphCount: glyphCount - startGlyphCount
                ))
            }
        }
    }

    /// Encode the same snapped rows, shaped text and decorations used by the reference paint path.
    internal func paintTerminalGridInstances(
        _ grid: TerminalGrid, snappedRect: SIMD4<Float>, exactRect: SIMD4<Float>,
        clip: SIMD4<Float>, fade: SIMD4<UInt32>,
        opacity: Float, defaultColor: Color,
        into instances: inout [RenderInstance], marks: inout [UInt32],
        glyphFixups: inout [(index: Int, normUV: SIMD4<Float>, texW: Float, texH: Float, page: UInt16, forceScaled: Bool)],
        imageFixups: inout [(index: Int, texelEdges: SIMD4<Float>, imgW: Float, imgH: Float)],
        lcdAvailable: @escaping () -> Bool, usedLCD: inout Bool
    ) {
        var primitives: [Primitive] = []
        var glyphPages: [(index: Int, page: UInt16)] = []
        var mask: UInt32 = 0
        var count = 0
        paintTerminalGrid(grid, devRect: snappedRect, exactRectPx: exactRect, devClip: clip,
                          localAlpha: opacity, defaultColor: defaultColor, effRotate: 0, useLayer: false,
                          lcdAvailable: lcdAvailable,
                          primitives: &primitives, glyphPageEntries: &glyphPages, usedGlyphMask: &mask, glyphCount: &count)
        let pages = Dictionary(uniqueKeysWithValues: glyphPages.map { ($0.index, $0.page) })
        func premultiply(_ c: SIMD4<Float>) -> SIMD4<Float> {
            SIMD4<Float>(c.x * c.w, c.y * c.w, c.z * c.w, c.w)
        }
        for (index, p) in primitives.enumerated() {
            var i = RenderInstance(rect: p.rect, radii: p.radii, fill: premultiply(p.fill), border: premultiply(p.border),
                                   params: SIMD4<Float>(p.params.x, KIND_RECT, 0, 1), uv: p.uv, clip: p.clip, fade: fade)
            switch p.kind {
            case .roundedRect:
                break
            case .glyph:
                usedLCD = usedLCD || p.radii.x == 1
                i.params = SIMD4<Float>(0, KIND_GLYPH, 0, p.params.w)
                glyphFixups.append((instances.count, p.uv, p.rect.z, p.rect.w, pages[index] ?? 0, false))
            case .image:
                i.params = SIMD4<Float>(Float(p.imagePage), KIND_IMAGE, 0, 1)
                imageFixups.append((instances.count, p.uv, p.rect.z, p.rect.w))
            case .segment:
                i.radii = p.uv
                i.params = SIMD4<Float>(max(0.25, p.params.x * 0.5), KIND_SEGMENT, p.params.z, 1)
                i.uv = .zero
            case .triangle:
                i.radii = p.uv
                i.params = SIMD4<Float>(p.params.x, KIND_TRIANGLE, 0, 1)
                i.uv = SIMD4<Float>(p.fadeOrigin.x, p.fadeOrigin.y, 0, 0)
            default:
                assertionFailure("Unexpected terminal row primitive")
                continue
            }
            instances.append(i)
            marks.append(0)
        }
    }
}
