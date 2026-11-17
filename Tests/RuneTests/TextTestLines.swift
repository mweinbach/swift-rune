@testable import Rune

extension ShapedText {
    /// Inspect the same authored text and visual line origins across shaping backends.
    var textTestLines: [(utf8Start: Int, text: String, originY: Float, originX: Float)] {
        #if canImport(CoreText) && canImport(CoreGraphics)
        if !lineStrings.isEmpty {
            return lineStrings.map { ($0.utf8Start, $0.text, $0.originY, $0.originX) }
        }
        #endif
        return portableLines.map { ($0.utf8Start, $0.text, $0.originY, $0.originX) }
    }
}
