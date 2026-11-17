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

/// Paragraph backgrounds, quote bars and list markers shared by both field paint paths.
internal enum RichTextFieldRender {
    static func emitBlockDecorations(
        blocks: [Block],
        softBreaks: [Int],
        richStyle: RichStyle,
        displayText: String,
        shaped: ShapedText,
        textSystem: TextSystem,
        font: TextStyle,
        textColor: Color,
        innerW: Float,
        textOriginX: Float,
        textOriginY: Float,
        scaleVec: Vec2,
        pxScale: Float,
        shapingScale: Float,
        rect: (SIMD4<Float>, Float, Color) -> Void,
        glyph: (SIMD4<Float>, PositionedGlyph, Color) -> Void
    ) {
        guard blocks.contains(where: { $0 != .paragraph }) else { return }

        let originX = textOriginX * pxScale
        let originY = textOriginY * pxScale
        let sx = pxScale * scaleVec.x
        let sy = pxScale * scaleVec.y
        let contentWidth = displayText.isEmpty ? 0 : shaped.size.x
        let boxWidth = max(innerW * pxScale, max(40, contentWidth) * sx)

        // Backgrounds span every visual line in a consecutive run, including hard breaks.
        var run: (block: Block, top: Float, bottom: Float)?
        func flushRun() {
            guard let r = run else { return }
            switch r.block {
            case .code:
                let pad = scaleVec.y == 1 ? (2 * sy).rounded() : 2 * sy
                rect(SIMD4(originX, r.top - pad, boxWidth, r.bottom - r.top + 2 * pad),
                     6 * sx, richStyle.codeBlockBg)
            case .quote:
                let w = scaleVec.x == 1 ? max(2, (3 * sx).rounded()) : max(3 * sx, 2 * scaleVec.x)
                let x = originX + 2 * sx
                let inset = scaleVec.y == 1 ? (2 * sy).rounded() : 2 * sy
                rect(SIMD4(scaleVec.x == 1 ? x.rounded() : x, r.top + inset,
                           w, max(4 * sy, r.bottom - r.top - 2 * inset)), w * 0.5, richStyle.quoteBar)
            default:
                break
            }
            run = nil
        }

        var starts = [0]
        for (offset, byte) in displayText.utf8.enumerated() where byte == 0x0a {
            starts.append(offset + 1)
        }
        let soft = Set(softBreaks)
        var para = 0
        var previousPara: Int?
        var counts = Array(repeating: 0, count: Int(Block.maxListLevel) + 1)
        var markers: [(block: Block, number: Int, baseline: Float)] = []
        let lines = displayText.isEmpty ? [] : textSystem.visualLines(in: shaped)
        // An empty formatted field still has one line's decoration.
        for index in 0..<max(1, lines.count) {
            let start = lines.isEmpty ? 0 : lines[index].utf8Start
            while para + 1 < starts.count, starts[para + 1] <= start { para += 1 }
            let block = para < blocks.count ? blocks[para] : .paragraph
            let topPt = lines.isEmpty ? 0 : lines[index].originY
            let top = originY + topPt * sy
            let height = lines.isEmpty ? font.resolvedLineHeight : shaped.lineBoxHeightPt(index)
            let bottom = top + height * sy
            if run?.block != block { flushRun() }
            if block == .code || block == .quote {
                run = (block, run?.top ?? top, bottom)
            }

            guard para != previousPara else { continue }
            previousPara = para
            let isSoft = soft.contains(para)
            guard let level = block.listLevel else {
                if !isSoft { counts = Array(repeating: 0, count: counts.count) }
                continue
            }
            let depth = Int(min(level, Block.maxListLevel))
            for i in (depth + 1)..<counts.count { counts[i] = 0 }
            if case .bullet = block { counts[depth] = 0 }
            guard !isSoft else { continue }
            if case .numbered = block { counts[depth] += 1 }
            let baselinePt: Float
            if lines.isEmpty {
                baselinePt = font.size * 0.8
            } else if index < shaped.lineBaselinesPx.count {
                baselinePt = shaped.lineBaselinesPx[index] / shapingScale
            } else {
                // The portable glyph baseline is 78 percent down its line.
                baselinePt = topPt + shaped.lineHeight * 0.78
            }
            markers.append((block, counts[depth], originY + baselinePt * sy))
        }
        flushRun()

        let ink = richStyle.marker ?? textColor.alpha(0.68)
        var labelFont = font
        labelFont.paragraphBlocks = []
        labelFont.byParagraphStart = nil
        labelFont.direction = nil
        labelFont.align = .leading
        for marker in markers {
            let indent = (marker.block.indentPt(fontSize: font.size) * pxScale).rounded()
            switch marker.block {
            case let .bullet(level):
                let width = scaleVec.x == 1 ? max(3, (4.5 * sx).rounded()) : max(3 * scaleVec.x, 4.5 * sx)
                let height = scaleVec.y == 1 ? max(3, (4.5 * sy).rounded()) : max(3 * scaleVec.y, 4.5 * sy)
                let x = originX + (indent - (7 * pxScale).rounded()) * scaleVec.x - width
                let y = marker.baseline - 0.34 * font.size * sy - height * 0.5
                rect(SIMD4(scaleVec.x == 1 ? x.rounded() : x, scaleVec.y == 1 ? y.rounded() : y, width, height),
                     level >= 2 ? sx : width * 0.5, level == 1 ? ink.scaleAlpha(0.65) : ink)
            case .numbered:
                let label = textSystem.shape(text: "\(marker.number).", style: labelFont, maxWidth: nil, pixelScale: shapingScale)
                let baseline = label.lineBaselinesPx.first.map { $0 / shapingScale } ?? label.lineHeight * 0.78
                let width = label.lastLineWidthPx / shapingScale
                let x = originX + (indent - (5 * pxScale).rounded()) * scaleVec.x - width * sx
                let y = marker.baseline - baseline * sy
                let left = scaleVec.x == 1 ? x.rounded() : x
                let top = scaleVec.y == 1 ? y.rounded() : y
                for q in label.glyphs {
                    glyph(SIMD4(left + q.rect.x * sx, top + q.rect.y * sy, q.rect.z * sx, q.rect.w * sy),
                          q, ink)
                }
            default:
                break
            }
        }
    }
}
