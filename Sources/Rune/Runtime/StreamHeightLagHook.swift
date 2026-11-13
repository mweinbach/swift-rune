import Foundation
import RuneMotion
#if canImport(CoreText)
import CoreText
#endif

extension Runtime {
    /// Computes the height held back while a streaming wrapped reveal text fills its final line
    /// (`apply.rs:221-231` / `text/line_metrics.rs:stream_height_lag`).
    internal func streamingRowHeightLag(
        rowEl: El<State>,
        rowRes: LayoutEngine.ResultNode,
        scale: Float
    ) -> Float {
        func findRevealText(_ el: El<State>, _ res: LayoutEngine.ResultNode) -> (El<State>, LayoutEngine.ResultNode)? {
            for (i, ch) in el.children.enumerated().reversed() where i < res.children.count {
                if let found = findRevealText(ch, res.children[i]) {
                    return found
                }
            }
            if el.revealDuration >= 0.0,
               el.textStyle.wrap == .wrap,
               (el.liveText?.get() ?? el.plainText) != nil || el.richSpans != nil {
                return (el, res)
            }
            return nil
        }

        guard let (textEl, textRes) = findRevealText(rowEl, rowRes) else { return 0.0 }
        let content = textEl.liveText?.get() ?? textEl.plainText ?? ""
        let availW = max(1.0, textRes.layout.localRect.width - textEl.layout.padding.left - textEl.layout.padding.right)
        let shaped = textSystem.shape(
            text: content,
            spans: textEl.richSpans,
            pills: textEl.pillChips,
            style: textEl.textStyle,
            maxWidth: availW,
            pixelScale: scale,
            emitGlyphs: false
        )
        let lineCount = shaped.lineCount
        guard lineCount > 0 else { return 0.0 }
        let lineHeightPx = shaped.lineHeight * scale
        let widthPx = availW * scale
        var lineAdvancePx: Float = 0.0
        var hangingAdvancePx: Float = 0.0

        #if canImport(CoreText)
        if let lastLine = shaped.lineStrings.last, let ctLine = lastLine.ctLine {
            lineAdvancePx = Float(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            hangingAdvancePx = Float(CTLineGetTrailingWhitespaceWidth(ctLine))
        }
        #endif
        if lineAdvancePx == 0.0, let lastPortable = shaped.portableLines.last {
            lineAdvancePx = (lastPortable.charOffsets.last ?? 0.0) * scale
        }

        return TextLineMetrics.streamHeightLag(
            lineCount: lineCount,
            lineHeightPx: lineHeightPx,
            lineAdvancePx: lineAdvancePx,
            hangingAdvancePx: hangingAdvancePx,
            widthPx: widthPx,
            scale: scale
        )
    }
}
