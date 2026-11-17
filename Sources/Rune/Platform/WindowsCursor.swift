#if os(Windows)
import CRuneWin32
import Foundation
import RuneRef

enum Win32Cursor {
    static func apply(_ cursor: Cursor, dpi: UInt32, window: OpaquePointer) {
        let native: RuneWinCursor
        switch cursor {
        case .default: native = RUNE_CURSOR_ARROW
        case .text: native = RUNE_CURSOR_TEXT
        case .pointer, .grab: native = RUNE_CURSOR_HAND
        case .move, .grabbing: native = RUNE_CURSOR_MOVE
        case .notAllowed: native = RUNE_CURSOR_DENIED
        case .resizeColumn: native = RUNE_CURSOR_COLUMN
        case .resizeRow: native = RUNE_CURSOR_ROW
        case .crosshair, .cell, .zoomIn, .zoomOut: native = RUNE_CURSOR_CROSS
        case .hidden: native = RUNE_CURSOR_HIDDEN
        case let .image(spec):
            if applyImage(spec, dpi: dpi, window: window) { return }
            native = RUNE_CURSOR_ARROW
        }
        rune_win_cursor(window, native)
    }

    private static func applyImage(_ spec: CursorImage, dpi: UInt32, window: OpaquePointer) -> Bool {
        guard let size = spec.pngSize(), (1...256).contains(size.width), (1...256).contains(size.height),
              let pixels = try? PortablePNG.decode(Data(spec.bytes)) else { return false }
        let scale = Win32DpiScale.scaleFactor(forDPI: dpi)
        // Cursor image assets are authored at 2x, and their hotspot is in logical points.
        let width = max(1, Int32((Float(pixels.width) * scale / 2).rounded()))
        let height = max(1, Int32((Float(pixels.height) * scale / 2).rounded()))
        let hx = CursorImage.clampedHotInt(spec.hot.x * scale, limit: Int(width - 1))
        let hy = CursorImage.clampedHotInt(spec.hot.y * scale, limit: Int(height - 1))
        return pixels.rgba.withUnsafeBufferPointer {
            rune_win_cursor_image(window, $0.baseAddress, Int32(pixels.width), Int32(pixels.height),
                                  width, height, Int32(hx), Int32(hy), spec.crisp ? 1 : 0) != 0
        }
    }
}
#endif
