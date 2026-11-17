#if os(macOS)
import AppKit
import RuneMotion

/// AppKit's global points grow upwards. Rune reports a content origin in points
/// from the primary screen's top left, and winit reports desktop positions in
/// physical pixels using the window's own backing scale.
struct MacOSWindowOrigin {
    let points: Vec2?
    let pixels: (Int32, Int32)

    @MainActor init(window: NSWindow) {
        let content = window.contentRect(forFrameRect: window.frame)
        points = NSScreen.screens.first.map { Vec2(Float(content.minX), Float($0.frame.height - content.maxY)) }
        pixels = Self.physicalTopLeft(of: content, scale: window.backingScaleFactor)
    }

    static func physicalTopLeft(of frame: CGRect, scale: CGFloat) -> (Int32, Int32) {
        let top = CGDisplayBounds(CGMainDisplayID()).height - frame.maxY
        return (Int32((frame.minX * scale).rounded()), Int32((top * scale).rounded()))
    }

    @MainActor static func setPosition(of window: NSWindow?, x: CGFloat, y: CGFloat) {
        guard let window, x.isFinite, y.isFinite else { return }
        let scale = window.backingScaleFactor
        let top = CGDisplayBounds(CGMainDisplayID()).height - y / scale
        window.setFrameTopLeftPoint(NSPoint(x: x / scale, y: top))
    }
}

extension Runtime {
    @discardableResult
    func updateMacOSOrigin(_ origin: MacOSWindowOrigin?) -> Bool {
        setWindowPixels(origin?.pixels)
        return origin?.points.map { setWindowOrigin($0) } ?? false
    }
}

/// Tracks the native content location without querying window geometry on display ticks.
@MainActor
final class MacOSWindowOriginWatch {
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    init?(window: NSWindow?, update: @escaping @MainActor (MacOSWindowOrigin?) -> Void) {
        guard let window else { update(nil); return nil }
        let sync = { @MainActor [weak window] in update(window.map(MacOSWindowOrigin.init)) }
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeBackingPropertiesNotification, NSWindow.didChangeScreenNotification,
                     NSApplication.didChangeScreenParametersNotification] {
            let object: AnyObject? = name == NSApplication.didChangeScreenParametersNotification ? nil : window
            tokens.append(center.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { sync() }
            })
        }
        sync()
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
#endif
