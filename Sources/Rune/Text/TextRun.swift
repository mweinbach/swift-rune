import Foundation
#if canImport(CoreText) && canImport(CoreGraphics)
import CoreText
import CoreGraphics
#endif

private final class RunCellLayoutCache: @unchecked Sendable {
    struct Key: Hashable {
        var runHash: UInt64
        var text: String
        var style: TextStyle
        var scale100: Int
        var portable: Bool
    }

    static let shared = RunCellLayoutCache()
    private let lock = NSLock()
    private var entries: [Key: TextRunCellLayout] = [:]

    func getOrCreate(
        run: TextRun,
        textSystem: TextSystem,
        style: TextStyle,
        pixelScale: Float
    ) -> TextRunCellLayout {
        var singleStyle = style
        singleStyle.wrap = .noWrap
        singleStyle.maxLines = 0
        if singleStyle.fontSmoothing == .systemDefault {
            singleStyle.fontSmoothing = textSystem.smoothing
        }
        let scale = max(1.0, pixelScale)
        let isPortable: Bool = {
            #if canImport(CoreText) && canImport(CoreGraphics)
            return false
            #else
            return true
            #endif
        }()
        let key = Key(
            runHash: run.hash,
            text: run.text,
            style: singleStyle,
            scale100: Int((scale * 100.0).rounded()),
            portable: isPortable
        )
        lock.lock()
        if let hit = entries[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let built = TextRunCellLayout(text: run.text, textSystem: textSystem, style: singleStyle, pixelScale: scale)
        lock.lock()
        if entries.count > 256 {
            entries.removeAll(keepingCapacity: true)
        }
        entries[key] = built
        lock.unlock()
        return built
    }
}

/// Cached single-line shaping of a `TextRun` with per-grapheme byte offsets, `1/64` px positions,
/// and kerned glyph slices (`rune::text::RunLayout`).
internal final class TextRunCellLayout: @unchecked Sendable {
    let text: String
    let pixelScale: Float
    let style: TextStyle
    let utf8Starts: [Int]
    let xsPx: [Float]

    #if canImport(CoreText) && canImport(CoreGraphics)
    private struct CapturedGlyph: @unchecked Sendable {
        var graphemeIndex: Int
        var font: CTFont
        var fontSizePx: Float
        var isColor: Bool
        var glyph: CGGlyph
        var runPosXPx: Float
        var runPosYPx: Float
    }
    private let capturedGlyphs: [CapturedGlyph]
    private let baselineYPx: Float
    #endif

    private struct PortableCapturedChar: Sendable {
        var graphemeIndex: Int
        var char: Character
    }
    private let portableChars: [PortableCapturedChar]

    init(text: String, textSystem: TextSystem, style: TextStyle, pixelScale: Float) {
        self.text = text
        let scale = max(1.0, pixelScale)
        self.pixelScale = scale
        self.style = style

        var u8Starts: [Int] = []
        var u16Starts: [Int] = []
        var chars: [Character] = []
        u8Starts.reserveCapacity(text.count + 1)
        u16Starts.reserveCapacity(text.count + 1)
        chars.reserveCapacity(text.count)
        var u8Cursor = 0
        var u16Cursor = 0
        for ch in text {
            chars.append(ch)
            u8Starts.append(u8Cursor)
            u16Starts.append(u16Cursor)
            let s = String(ch)
            u8Cursor += s.utf8.count
            u16Cursor += s.utf16.count
        }
        u8Starts.append(u8Cursor)
        u16Starts.append(u16Cursor)
        self.utf8Starts = u8Starts

        #if canImport(CoreText) && canImport(CoreGraphics)
        if text.isEmpty {
            self.xsPx = [0]
            self.capturedGlyphs = []
            self.baselineYPx = 0
            self.portableChars = []
            return
        }
        let baseFont = textSystem.resolveCTFont(style: style, pixelScale: scale)
        var attrs: [CFString: Any] = [kCTFontAttributeName: baseFont]
        if style.letterSpacing != 0 {
            attrs[kCTKernAttributeName] = NSNumber(value: style.letterSpacing * scale)
        }
        let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
        let ctLine = CTLineCreateWithAttributedString(attrStr)
        let fullWPx = Float(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        let ascPx = Float(CTFontGetAscent(baseFont))
        let descPx = Float(CTFontGetDescent(baseFont))
        let lhPx = style.resolvedLineHeight * scale
        let halfLeadingPx = (lhPx - (ascPx + descPx)) * 0.5
        self.baselineYPx = (halfLeadingPx + ascPx).rounded()

        var xs: [Float] = []
        xs.reserveCapacity(chars.count + 1)
        var prevX: Float = 0
        for i in 0..<chars.count {
            let off = Float(CTLineGetOffsetForStringIndex(ctLine, u16Starts[i], nil))
            let snapped = off.isFinite ? (off * 64.0).rounded() / 64.0 : prevX
            xs.append(snapped)
            prevX = snapped
        }
        // The run ends at its width in 64ths of a pixel, as a text box does (`text_width`, #934).
        xs.append(TextBoxGeometry.textWidth(fullWPx))
        self.xsPx = xs

        var captured: [CapturedGlyph] = []
        let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []
        for run in runs {
            let gCount = CTRunGetGlyphCount(run)
            if gCount == 0 { continue }
            let rAttrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = rAttrs[kCTFontAttributeName] as! CTFont
            let runFontSizePx = Float(CTFontGetSize(runFont))
            let isColor = GlyphAtlas.isColorFont(runFont)
            var glyphs = [CGGlyph](repeating: 0, count: gCount)
            var positions = [CGPoint](repeating: .zero, count: gCount)
            var indices = [CFIndex](repeating: 0, count: gCount)
            CTRunGetGlyphs(run, CFRangeMake(0, gCount), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, gCount), &positions)
            CTRunGetStringIndices(run, CFRangeMake(0, gCount), &indices)
            for j in 0..<gCount {
                let gi = Self.graphemeIndex(forU16: Int(indices[j]), in: u16Starts)
                captured.append(CapturedGlyph(
                    graphemeIndex: gi,
                    font: runFont,
                    fontSizePx: runFontSizePx,
                    isColor: isColor,
                    glyph: glyphs[j],
                    runPosXPx: Float(positions[j].x),
                    runPosYPx: Float(positions[j].y)
                ))
            }
        }
        captured.sort { $0.graphemeIndex < $1.graphemeIndex }
        self.capturedGlyphs = captured
        self.portableChars = []
        #else
        var xs: [Float] = []
        var pChars: [PortableCapturedChar] = []
        xs.reserveCapacity(chars.count + 1)
        pChars.reserveCapacity(chars.count)
        let isMono = style.family == .monospace
        var penPt: Float = 0
        for (i, ch) in chars.enumerated() {
            let xPx = (penPt * scale * 64.0).rounded() / 64.0
            xs.append(xPx)
            pChars.append(PortableCapturedChar(graphemeIndex: i, char: ch))
            let scalarSum = ch.unicodeScalars.reduce(Float(0)) { acc, sc in
                acc + PortableGlyphFont.advanceRatio(for: sc, mono: isMono) * style.size
            }
            let adv = scalarSum + (ch.unicodeScalars.isEmpty ? 0 : style.letterSpacing)
            penPt += adv
        }
        xs.append(TextBoxGeometry.textWidth(penPt * scale))
        self.xsPx = xs
        self.portableChars = pChars
        #endif
    }

    private static func graphemeIndex(forU16 u16: Int, in starts: [Int]) -> Int {
        let count = max(0, starts.count - 1)
        guard count > 0 else { return 0 }
        var lo = 0
        var hi = count - 1
        var best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= u16 {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }

    func graphemeIndex(atByte byteOffset: Int) -> Int? {
        guard utf8Starts.count > 1 else { return nil }
        var lo = 0
        var hi = utf8Starts.count - 2
        while lo <= hi {
            let mid = (lo + hi) / 2
            let v = utf8Starts[mid]
            if v == byteOffset { return mid }
            if v < byteOffset { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    func advance(atByte byteOffset: Int, scale: Float? = nil) -> Float? {
        guard let i = graphemeIndex(atByte: byteOffset) else { return nil }
        let s = max(1.0, scale ?? pixelScale)
        return max(0.0, (xsPx[i + 1] - xsPx[i]) / s)
    }

    func shapeCell(
        atByte byteOffset: Int,
        using textSystem: TextSystem,
        emitGlyphs: Bool
    ) -> ShapedText? {
        guard let gi = graphemeIndex(atByte: byteOffset) else { return nil }
        let s = pixelScale
        let invS = 1.0 / s
        let lhPt = style.resolvedLineHeight
        let hPt = TextSystem.specLineHeight(lineCount: 1, lineHeightPt: lhPt, scale: s, exact: style.exactLines)
        let wPt = max(0.0, (xsPx[gi + 1] - xsPx[gi]) * invS)
        let b0 = text.utf8.index(text.utf8.startIndex, offsetBy: utf8Starts[gi])
        let b1 = text.utf8.index(text.utf8.startIndex, offsetBy: utf8Starts[gi + 1])
        let cellStr = String(text[b0..<b1])

        let glyphsOut: [PositionedGlyph]
        #if canImport(CoreText) && canImport(CoreGraphics)
        glyphsOut = emitGlyphs
            ? emitCapturedGlyphs(graphemeIndex: gi, using: textSystem, originXPx: -xsPx[gi], baselineYPx: baselineYPx)
            : []
        return ShapedText(
            size: Vec2(wPt, hPt),
            lineCount: 1,
            lineHeight: lhPt,
            glyphs: glyphsOut,
            underlines: [],
            backgrounds: [],
            lineStrings: [(0, cellStr, 0, 0, nil)],
            forcedDirection: style.direction
        )
        #else
        glyphsOut = emitGlyphs
            ? emitPortableGlyphs(graphemeIndex: gi, using: textSystem, startXPt: 0, baselineYPt: lhPt * 0.78)
            : []
        return ShapedText(
            size: Vec2(wPt, hPt),
            lineCount: 1,
            lineHeight: lhPt,
            glyphs: glyphsOut,
            underlines: [],
            backgrounds: [],
            portableLines: [(0, cellStr, 0, 0, [0, wPt])],
            forcedDirection: style.direction
        )
        #endif
    }

    /// Emits `PositionedGlyph` quads for the grapheme starting at `byteOffset`,
    /// with the run's top-left positioned at `originPt` in logical points (`glyph_emit.rs:104`).
    func glyphsIn(
        atByte byteOffset: Int,
        using textSystem: TextSystem,
        originPt: Vec2
    ) -> [PositionedGlyph] {
        guard let gi = graphemeIndex(atByte: byteOffset) else { return [] }
        #if canImport(CoreText) && canImport(CoreGraphics)
        let originXPx = originPt.x * pixelScale
        let originBaselinePx = (originPt.y * pixelScale + baselineYPx).rounded()
        return emitCapturedGlyphs(
            graphemeIndex: gi,
            using: textSystem,
            originXPx: originXPx,
            baselineYPx: originBaselinePx
        )
        #else
        let startXPt = originPt.x + xsPx[gi] / pixelScale
        let baselinePt = originPt.y + style.resolvedLineHeight * 0.78
        return emitPortableGlyphs(
            graphemeIndex: gi,
            using: textSystem,
            startXPt: startXPt,
            baselineYPt: baselinePt
        )
        #endif
    }

    #if canImport(CoreText) && canImport(CoreGraphics)
    private func emitCapturedGlyphs(
        graphemeIndex gi: Int,
        using textSystem: TextSystem,
        originXPx: Float,
        baselineYPx targetBaselinePx: Float
    ) -> [PositionedGlyph] {
        let invS = 1.0 / pixelScale
        var glyphsOut: [PositionedGlyph] = []
        for cg in capturedGlyphs where cg.graphemeIndex == gi {
            let gxPx = originXPx + cg.runPosXPx
            let gyPx = targetBaselinePx - cg.runPosYPx
            if cg.isColor, let colorEntry = textSystem.glyphAtlas.rasterizeColorGlyph(
                font: cg.font,
                glyph: cg.glyph,
                fontSizePx: cg.fontSizePx
            ), colorEntry.pixelSize.x > 0 && colorEntry.pixelSize.y > 0 {
                let quadXPx = roundf(gxPx) + colorEntry.bearingPx.x
                let quadYPx = roundf(gyPx) + colorEntry.bearingPx.y
                glyphsOut.append(PositionedGlyph(
                    rect: SIMD4<Float>(
                        quadXPx * invS,
                        quadYPx * invS,
                        Float(colorEntry.pixelSize.x) * invS,
                        Float(colorEntry.pixelSize.y) * invS
                    ),
                    uv: .zero,
                    color: nil,
                    colorGlyphIndex: colorEntry.index
                ))
                continue
            }
            let floorX = floorf(gxPx)
            let subX = gxPx - floorX
            let floorY = floorf(gyPx)
            let subY = gyPx - floorY
            let binY = UInt8((Int((subY * 4.0).rounded())) % 4)
            guard let entry = textSystem.glyphAtlas.rasterizeGlyph(
                font: cg.font,
                glyph: cg.glyph,
                fontSizePx: cg.fontSizePx,
                subpixelX: subX,
                subpixelYBin: binY,
                smoothing: style.fontSmoothing
            ), entry.pixelSize.x > 0 && entry.pixelSize.y > 0 else {
                continue
            }
            let quadXPx = floorX + entry.bearingPx.x
            let quadYPx = floorY + entry.bearingPx.y
            glyphsOut.append(PositionedGlyph(
                rect: SIMD4<Float>(
                    quadXPx * invS,
                    quadYPx * invS,
                    Float(entry.pixelSize.x) * invS,
                    Float(entry.pixelSize.y) * invS
                ),
                uv: entry.uv,
                color: nil,
                atlasPage: entry.page
            ))
        }
        return glyphsOut
    }
    #else
    private func emitPortableGlyphs(
        graphemeIndex gi: Int,
        using textSystem: TextSystem,
        startXPt: Float,
        baselineYPt: Float
    ) -> [PositionedGlyph] {
        let s = pixelScale
        let invS = 1.0 / s
        let isMono = style.family == .monospace
        var glyphsOut: [PositionedGlyph] = []
        var xPt = startXPt
        for pc in portableChars where pc.graphemeIndex == gi {
            for sc in pc.char.unicodeScalars {
                let adv = PortableGlyphFont.advanceRatio(for: sc, mono: isMono) * style.size
                let entry = textSystem.glyphAtlas.rasterizePortableGlyph(
                    scalar: sc,
                    fontSize: style.size,
                    weight: style.weight,
                    italic: style.italic,
                    monospace: isMono,
                    scale: s
                )
                if entry.pixelSize.x > 0 && entry.pixelSize.y > 0 {
                    glyphsOut.append(PositionedGlyph(
                        rect: SIMD4<Float>(
                            xPt + entry.bearingPx.x * invS,
                            baselineYPt + entry.bearingPx.y * invS,
                            Float(entry.pixelSize.x) * invS,
                            Float(entry.pixelSize.y) * invS
                        ),
                        uv: entry.uv,
                        color: nil,
                        atlasPage: entry.page
                    ))
                }
                xPt += adv
            }
        }
        return glyphsOut
    }
    #endif
}

extension TextSystem {
    /// Measures one grapheme cell in `run` at UTF-8 byte `byteOffset`, preserving run kerning.
    public func measureRunSlice(
        _ run: TextRun,
        at byteOffset: Int,
        style: TextStyle,
        pixelScale: Float
    ) -> Vec2? {
        let rl = RunCellLayoutCache.shared.getOrCreate(run: run, textSystem: self, style: style, pixelScale: pixelScale)
        guard let adv = rl.advance(atByte: byteOffset, scale: pixelScale) else { return nil }
        let h = Self.specLineHeight(lineCount: 1, lineHeightPt: style.resolvedLineHeight, scale: pixelScale, exact: style.exactLines)
        return Vec2(adv, h)
    }

    /// Shapes one grapheme cell in `run` at UTF-8 byte `byteOffset`, shifted so the grapheme starts at `x = 0`.
    public func shapeRunSlice(
        _ run: TextRun,
        at byteOffset: Int,
        style: TextStyle,
        pixelScale: Float,
        emitGlyphs: Bool = true
    ) -> ShapedText? {
        let rl = RunCellLayoutCache.shared.getOrCreate(run: run, textSystem: self, style: style, pixelScale: pixelScale)
        return rl.shapeCell(atByte: byteOffset, using: self, emitGlyphs: emitGlyphs)
    }

    internal func cachedRunCellLayout(
        _ run: TextRun,
        style: TextStyle,
        pixelScale: Float
    ) -> TextRunCellLayout {
        RunCellLayoutCache.shared.getOrCreate(run: run, textSystem: self, style: style, pixelScale: pixelScale)
    }
}
