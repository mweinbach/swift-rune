#if (os(Linux) || os(Windows)) && canImport(CRuneDesktopText)
import CRuneDesktopText

private struct NativeQualityGlyph {
    let id: UInt32
    let owner: Int32
    let x, y, advance: Float
}

private func capturedGlyphs(_ native: OpaquePointer) throws -> [NativeQualityGlyph] {
    var glyphs: [NativeQualityGlyph] = []
    let success = withUnsafeMutablePointer(to: &glyphs) { pointer in
        rune_desktop_line_quality_glyphs(native, pointer) { context, id, owner, x, y, advance in
            context!.assumingMemoryBound(to: [NativeQualityGlyph].self).pointee.append(
                .init(id: id, owner: owner, x: x, y: y, advance: advance))
        }
    }
    guard success != 0 else { throw PixelCompareError.message("The native text layout could not report its glyph positions") }
    return glyphs
}

extension ShapedText {
    func forEachDesktopQualityLine(_ visit: (DesktopTextLine, [DesktopTextLine.Cell], Float, Float) throws -> Void) rethrows {
        for (index, record) in portableLines.enumerated() {
            let resting = desktopRestingText?.qualityLine(at: index)
            let fragment = desktopParagraph.flatMap { $0.fragments.indices.contains(index) ? $0.fragments[index] : nil }
            guard let line = resting?.native ?? fragment, lineBaselinesPx.indices.contains(index) else { continue }
            let start = record.utf8Start + (resting?.sourceByteOffset ?? 0)
            let range = start..<(start + record.text.utf8.count)
            let cells = line.cells.values.filter { range.contains($0.byte) }.sorted {
                $0.left == $1.left ? $0.byte < $1.byte : $0.left < $1.left
            }
            try visit(line, cells, resting?.originX ?? record.originX, lineBaselinesPx[index])
        }
    }

    package func desktopQualityGlyphs(origin: SIMD2<Float>) throws -> [TextQualityGlyph] {
        var output: [TextQualityGlyph] = []
        try forEachDesktopQualityLine { line, cells, originX, lineBaseline in
            let runs = Dictionary(grouping: cells.indices) { cells[$0].qualityGlyphSource.handle }
            let baseline = (origin.y + lineBaseline).rounded()
            var perCell = Array(repeating: [TextQualityGlyph](), count: cells.count)
            for (handle, indices) in runs {
                let byByte = indices.sorted { cells[$0].qualityGlyphSource.bytes.lowerBound < cells[$1].qualityGlyphSource.bytes.lowerBound }
                for glyph in try capturedGlyphs(handle) {
                    let position = partitionPoint(byByte) { cells[$0].qualityGlyphSource.bytes.upperBound <= glyph.owner }
                    guard position < byByte.count else { continue }
                    let slot = byByte[position]
                    let cell = cells[slot]
                    let source = cell.qualityGlyphSource
                    guard source.bytes.contains(glyph.owner) else { continue }
                    let x = origin.x + line.runOriginPx(for: cell, originX: originX) + glyph.x
                    let offsetY = glyph.y - source.ascent
                    perCell[slot].append(.init(id: glyph.id, x: (x * 4).rounded() / 4,
                                               y: (baseline + offsetY).rounded(), advance: glyph.advance))
                }
            }
            output.append(contentsOf: perCell.joined())
        }
        return output
    }

    package func desktopQualityPlaced(at origin: SIMD2<Float>, scale: Float, atlas: GlyphAtlas) -> [(PositionedGlyph, SIMD4<Float>)] {
        var shaped = self
        _ = desktopRestingText?.place(&shaped, at: origin.x, atlas: atlas)
        let baselines = TextBoxGeometry.roundedBaselines(originYPx: origin.y, shaped: shaped)
        var line = 0
        return shaped.glyphs.enumerated().map { index, glyph in
            TextBoxGeometry.paintGlyph(glyph, index: index, shaped: shaped, origin: origin,
                                       scale: SIMD2(repeating: 1), pixelScale: scale, restsExact: true,
                                       baselines: baselines, line: &line, atlas: atlas)
        }
    }
}
#endif
