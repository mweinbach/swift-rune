import Foundation
#if os(macOS)
import AppKit
#elseif os(Linux)
import CRuneLinux
#elseif os(Windows)
import CRuneWin32
#endif

#if os(macOS) || os(Linux) || os(Windows)
enum DesktopDisplays {
    /// The bounds match Rune's top-left, physical-pixel desktop coordinates.
    @MainActor
    static func connected() throws -> [DisplayInfo] {
        #if os(macOS)
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let origin = CGDisplayBounds(id).origin
            let scale = Double(screen.backingScaleFactor)
            return DisplayInfo(id: RuneDisplayId(native: .macOS(id)), name: screen.localizedName,
                               position: (Int32((origin.x * scale).rounded()), Int32((origin.y * scale).rounded())),
                               size: (UInt32((screen.frame.width * scale).rounded()),
                                      UInt32((screen.frame.height * scale).rounded())),
                               scale: scale, primary: CGDisplayIsMain(id) != 0)
        }
        #else
        var displays: [DisplayInfo] = []
        let success = withUnsafeMutablePointer(to: &displays) { buffer in
            #if os(Linux)
            rune_linux_displays(buffer, { buffer, id, name, x, y, w, h, scale, primary in
                DesktopDisplays.record(buffer, UInt64(id), name, x, y, w, h, scale, primary)
            }) >= 0
            #else
            rune_win_displays(buffer, { buffer, id, name, x, y, w, h, scale, primary in
                DesktopDisplays.record(buffer, id, name, x, y, w, h, scale, primary)
            }) != 0
            #endif
        }
        guard success else { throw DesktopWindowError("Enumerating connected desktop displays failed") }
        return displays
        #endif
    }

    #if os(Linux) || os(Windows)
    private static func record(_ buffer: UnsafeMutableRawPointer?, _ id: UInt64, _ name: UnsafePointer<CChar>?,
                               _ x: Int32, _ y: Int32, _ w: UInt32, _ h: UInt32, _ scale: Double, _ primary: Int32) {
        let info = DisplayInfo(id: RuneDisplayId(native: .other(id)), name: name.map { String(cString: $0) },
                               position: (x, y), size: (w, h), scale: scale, primary: primary != 0)
        buffer?.assumingMemoryBound(to: [DisplayInfo].self).pointee.append(info)
    }
    #endif
}
#endif
