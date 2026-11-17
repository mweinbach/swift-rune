#if os(Windows)
import CRuneWin32
import RuneMotion

/// UIA requests word units on the client thread. Leave shaping and publication free of segmentation work.
internal func windowsAccessibilityWordBreaks(_ text: UnsafePointer<UInt16>?, _ length: Int32,
                                            _ flags: UnsafeMutablePointer<UInt8>?) {
    guard let text, let flags, length > 0 else { return }
    let value = String(decoding: UnsafeBufferPointer(start: text, count: Int(length)), as: UTF16.self)
    let standard = Set(value.ranges(of: #/\b/#.wordBoundaryKind(.default)).map {
        value.utf8.distance(from: value.startIndex, to: $0.lowerBound)
    })
    let breaks = WindowsWordSegmenter.visualWordBreaks(standard, in: value)
    var byte = 0, offset = 0
    for scalar in value.unicodeScalars {
        if breaks.contains(byte) { flags[offset] = 1 }
        byte += scalar.utf8.count
        offset += scalar.utf16.count
    }
}

extension Runtime {
    internal func windowsTextGeometry(target: String, clip: MotionRect) -> [RuneUiaTextCell]? {
        guard let layout = accessibilityTextLayout(target: target, clip: clip),
              let cells = layout.cells(unit: .utf16, pixelScale: pixelScale) else { return nil }
        return cells.map { cell in
            RuneUiaTextCell(start: cell.start, end: cell.end, line: cell.line,
                            x: cell.x, y: cell.y, width: cell.width, height: cell.height, rtl: cell.rtl ? 1 : 0,
                            hit_midpoint: cell.hitMidpoint, has_hit_midpoint: 1)
        }
    }
}
#endif
