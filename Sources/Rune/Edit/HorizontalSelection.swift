extension TextEdit {
    /// Collapse to the selection endpoint in the arrow's visual direction.
    internal mutating func collapseHorizontalSelection(
        right: Bool, layout: ShapedText?, textSystem: TextSystem?, pixelScale: Float
    ) {
        let range = selectedUTF8Range
        var towardUpper = right
        if let layout, layout.cursorLineCount > 0, !isSecure || isRevealed {
            let lowerLine = layout.lineIndex(forUTF8Offset: range.lowerBound, affinity: .downstream)
            let upperLine = layout.lineIndex(forUTF8Offset: range.upperBound, affinity: .upstream)
            if lowerLine == upperLine {
                let system = textSystem ?? TextSystem()
                let startX = system.caretRect(in: layout, utf8Offset: range.lowerBound,
                                              affinity: .downstream, pixelScale: pixelScale).x
                let endX = system.caretRect(in: layout, utf8Offset: range.upperBound,
                                            affinity: .upstream, pixelScale: pixelScale).x
                towardUpper = (startX <= endX) == right
            } else {
                let focusLine = layout.lineIndex(forUTF8Offset: cursor)
                let rtl = layout.lineIsRTL.indices.contains(focusLine) ? layout.lineIsRTL[focusLine] : layout.primaryIsRTL
                towardUpper = right != rtl
            }
        }
        if towardUpper {
            collapseSelectionToEnd()
        } else {
            collapseSelectionToStart()
        }
    }
}
