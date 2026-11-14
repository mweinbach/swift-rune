import Foundation

extension El {
    /// Attaches ephemeral display decorations (such as syntax highlights or lint underlines) to a text field
    /// without storing them in `TextEdit` history, or sets display spans on static text (`rune::El::decorations`).
    public func decorations(_ spans: [RichSpan]) -> Self {
        if handlers.editLens != nil {
            var copy = self
            copy.runtimeExtras["inputDecorations"] = spans
            return copy
        }
        return self.spans(spans)
    }

    internal var inputDecorations: [RichSpan] {
        runtimeExtras["inputDecorations"] as? [RichSpan] ?? []
    }
}

/// Emits block-level decorations (code block backgrounds and quote bars) for rich `TextEdit` fields.
internal enum RichTextFieldRender {
    static func emitBlockDecorations(
        blocks: [Block],
        richStyle: RichStyle,
        displayText: String,
        shaped: ShapedText,
        innerW: Float,
        textOriginX: Float,
        textOriginY: Float,
        scaleVec: Vec2,
        pxScale: Float,
        localAlpha: Float,
        srgbBlend: Bool,
        devClip: SIMD4<Float>,
        into primitives: inout [Primitive]
    ) {
        guard !blocks.isEmpty else { return }
        let lineCount = max(shaped.lineCount, shaped.markerMap.lines.count)
        guard lineCount > 0 else { return }
        let codeBg = richStyle.codeBlockBg.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
        let quoteCol = richStyle.quoteBar.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)

        var paraStarts: [Int] = [0]
        for (i, b) in displayText.utf8.enumerated() where b == 0x0A {
            paraStarts.append(i + 1)
        }

        var paraIdx = 0
        for lineIdx in 0..<lineCount {
            let lineUTF8Start = lineIdx < shaped.markerMap.lines.count
                ? shaped.markerMap.lines[lineIdx].authUTF8Start
                : (lineIdx < paraStarts.count ? paraStarts[lineIdx] : displayText.utf8.count)
            while paraIdx + 1 < paraStarts.count && paraStarts[paraIdx + 1] <= lineUTF8Start {
                paraIdx += 1
            }
            let block = paraIdx < blocks.count ? blocks[paraIdx] : .paragraph
            let lineY = shaped.lineTopPt(lineIdx)
            switch block {
            case .code:
                if codeBg.w > 0.0005 {
                    primitives.append(.roundedRect(
                        rect: SIMD4<Float>(
                            (textOriginX - 4) * pxScale,
                            (textOriginY + lineY) * pxScale,
                            (innerW + 8) * scaleVec.x * pxScale,
                            shaped.lineBoxHeightPt(lineIdx) * scaleVec.y * pxScale
                        ),
                        radii: SIMD4<Float>(repeating: 3.0 * pxScale),
                        fill: codeBg,
                        clip: devClip
                    ))
                }
            case .quote:
                if quoteCol.w > 0.0005 {
                    primitives.append(.roundedRect(
                        rect: SIMD4<Float>(
                            (textOriginX - 5) * pxScale,
                            (textOriginY + lineY + 1) * pxScale,
                            2.5 * scaleVec.x * pxScale,
                            max(2, shaped.lineBoxHeightPt(lineIdx) - 2) * scaleVec.y * pxScale
                        ),
                        radii: SIMD4<Float>(repeating: 1.25 * pxScale),
                        fill: quoteCol,
                        clip: devClip
                    ))
                }
            case .paragraph, .bullet, .numbered:
                break
            }
        }
    }
}
