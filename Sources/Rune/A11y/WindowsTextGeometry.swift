#if os(Windows)
import CRuneWin32
import RuneMotion

extension Runtime {
    internal func publishWindowsTextGeometry(target: String, host: OpaquePointer, id: Int32, clip: MotionRect) {
        guard let layout = accessibilityTextLayout(target: target, clip: clip),
              let cells = layout.cells(unit: .utf16, pixelScale: pixelScale) else { return }
        let native = cells.map { cell in
            RuneUiaTextCell(start: cell.start, end: cell.end, line: cell.line,
                            x: cell.x, y: cell.y, width: cell.width, height: cell.height, rtl: cell.rtl ? 1 : 0,
                            hit_midpoint: cell.hitMidpoint, has_hit_midpoint: 1)
        }
        native.withUnsafeBufferPointer { buffer in
            rune_uia_text_geometry(host, id, buffer.baseAddress, Int32(buffer.count))
        }
    }
}
#endif
