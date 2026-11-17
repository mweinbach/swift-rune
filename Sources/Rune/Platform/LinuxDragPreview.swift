#if os(Linux)
import CRuneDesktopServices
import Foundation

enum LinuxDragPreview {
    /// Called with the Rune window's GL context current, between encoding and presentation.
    static func begin(driver: OpaquePointer, payload: OpaquePointer, operations: UInt32,
                      withinApp: Bool, start: DragOutStart, scale: Float, pixelWidth: Int, pixelHeight: Int) -> Bool {
        func begin(_ preview: UnsafePointer<RuneLinuxDragPreview>?) -> Bool {
            rune_linux_drag_begin_with_preview(driver, payload, operations, withinApp ? 1 : 0, preview) != 0
        }
        guard let image = DesktopDragPreview.picture(start: start, scale: scale, pixelWidth: pixelWidth, pixelHeight: pixelHeight),
              let width = Int32(exactly: image.width), let height = Int32(exactly: image.height) else { return begin(nil) }
        let rect = image.frame(bounds: start.bounds, press: start.press,
                               natural: Vec2(Float(width) / scale, Float(height) / scale))
        guard let displayWidth = Int32(exactly: rect.width.rounded()), let displayHeight = Int32(exactly: rect.height.rounded()),
              displayWidth > 0, displayHeight > 0, rect.left.isFinite, rect.top.isFinite,
              start.press.x.isFinite, start.press.y.isFinite else { return begin(nil) }
        func hotspot(_ position: Float, extent: Int32) -> Int32 {
            Int32(max(0, min(Double(extent - 1), Double(position.rounded()))))
        }
        return image.rgba.withUnsafeBytes { pixels in
            var preview = RuneLinuxDragPreview(rgba: pixels.bindMemory(to: UInt8.self).baseAddress,
                                               size: pixels.count, width: width, height: height,
                                               display_width: displayWidth, display_height: displayHeight,
                                               hotspot_x: hotspot(start.press.x - rect.left, extent: displayWidth),
                                               hotspot_y: hotspot(start.press.y - rect.top, extent: displayHeight))
            return begin(&preview)
        }
    }
}
#endif
