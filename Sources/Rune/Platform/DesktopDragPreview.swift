#if os(Windows) || os(Linux)
import CRuneGL
import Foundation
#if os(Windows)
import CRuneWin32
#else
import CRuneLinux
#endif

enum DesktopDragPreview {
    static func picture(start: DragOutStart, scale: Float, pixelWidth: Int, pixelHeight: Int) -> DragImage? {
        guard scale.isFinite, scale > 0 else { return nil }
        if let image = start.item.dragImage {
            let count = UInt64(image.width) * UInt64(image.height)
            guard count > 0, count <= 16 * 1024 * 1024, count <= UInt64(image.rgba.count) / 4 else { return nil }
            if let backing = start.item.backing { return image.over(backing) ?? image }
            return image
        }
        guard start.rect.x.isFinite, start.rect.y.isFinite,
              start.rect.width.isFinite, start.rect.height.isFinite,
              let framebufferWidth = Int32(exactly: pixelWidth), let framebufferHeight = Int32(exactly: pixelHeight),
              framebufferWidth > 0, framebufferHeight > 0,
              let crop = DragImage.snapshotCrop(rect: start.rect, scale: scale, size: (UInt32(framebufferWidth), UInt32(framebufferHeight))),
              let x = Int32(exactly: crop[0]), let y = Int32(exactly: crop[1]),
              let width = Int32(exactly: crop[2]), let height = Int32(exactly: crop[3]),
              UInt64(crop[2]) * UInt64(crop[3]) <= 16 * 1024 * 1024 else { return nil }

        var rgba = [UInt8](repeating: 0, count: Int(width) * Int(height) * 4)
        #if os(Windows)
        let resolve: RuneGLResolve = rune_win_gl_proc
        #else
        let resolve: RuneGLResolve = rune_linux_gl_proc
        #endif
        let captured = rgba.withUnsafeMutableBufferPointer {
            rune_gl_window_snapshot(resolve, x, y, width, height, framebufferHeight, $0.baseAddress, $0.count)
        }
        guard captured != 0 else { return nil }
        // The GL presentation shader writes straight sRGB to the window back buffer.
        let image = DragImage(width: crop[2], height: crop[3], rgba: Data(rgba))
            .size(Float(width) / scale, Float(height) / scale)
            .at(Vec2(Float(x) / scale, Float(y) / scale))
        return DragImage.picture(for: start.item, snapshot: image)
    }
}
#endif
