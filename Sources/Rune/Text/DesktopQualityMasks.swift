#if (os(Linux) || os(Windows)) && canImport(CRuneDesktopText)
import CRuneDesktopText

extension ShapedText {
    package func qualityDesktopExperiment(origin: SIMD2<Float>, scale: Float, hint: Bool,
                                          embolden: Float) throws -> [TextQualityMask] {
        #if os(Windows)
        guard embolden == 0 else {
            throw PixelCompareError.message("DirectWrite text-quality masks support embolden 0. Arbitrary outline emboldening is unavailable on Windows.")
        }
        #endif
        var masks: [TextQualityMask] = []
        try forEachDesktopQualityLine { line, cells, originX, baselinePx in
            for cell in cells {
                let source = cell.qualityGlyphSource
                let x = origin.x + line.runOriginPx(for: cell, originX: originX)
                let success = withUnsafeMutablePointer(to: &masks) { result in
                    rune_desktop_line_quality_masks(source.handle, source.bytes.lowerBound, source.bytes.upperBound,
                        x, origin.y + baselinePx, hint ? 1 : 0, embolden, result) {
                        context, left, top, width, height, stride, pixels in
                        guard let pixels, let context else { return }
                        let w = Int(width), h = Int(height)
                        var bytes: [UInt8] = []
                        bytes.reserveCapacity(w * h)
                        for row in 0..<h {
                            let start = pixels.advanced(by: row * Int(stride))
                            bytes.append(contentsOf: UnsafeBufferPointer(start: start, count: w))
                        }
                        context.assumingMemoryBound(to: [TextQualityMask].self).pointee.append(
                            .init(x: Int(left), y: Int(top), width: w, height: h, bytes: bytes))
                    }
                }
                guard success != 0 else {
                    throw PixelCompareError.message("The native rasterizer could not render this font with hint=\(hint), embolden=\(embolden) at UTF-8 byte \(cell.byte)")
                }
            }
        }
        return masks
    }
}
#endif
