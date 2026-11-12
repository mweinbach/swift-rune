import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#else
public typealias CGFloat = Double

public struct CGPoint: Sendable, Equatable, Hashable {
    public var x: CGFloat
    public var y: CGFloat
    public init(x: CGFloat = 0, y: CGFloat = 0) {
        self.x = x
        self.y = y
    }
}

public struct CGSize: Sendable, Equatable, Hashable {
    public var width: CGFloat
    public var height: CGFloat
    public init(width: CGFloat = 0, height: CGFloat = 0) {
        self.width = width
        self.height = height
    }
}

public struct CGRect: Sendable, Equatable, Hashable {
    public var origin: CGPoint
    public var size: CGSize

    public static let null = CGRect(x: .infinity, y: .infinity, width: 0, height: 0)

    public init(origin: CGPoint = CGPoint(), size: CGSize = CGSize()) {
        self.origin = origin
        self.size = size
    }

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.origin = CGPoint(x: x, y: y)
        self.size = CGSize(width: width, height: height)
    }

    public var minX: CGFloat { origin.x }
    public var minY: CGFloat { origin.y }
    public var maxX: CGFloat { origin.x + size.width }
    public var maxY: CGFloat { origin.y + size.height }
    public var width: CGFloat { size.width }
    public var height: CGFloat { size.height }
    public var isNull: Bool { origin.x.isInfinite || origin.y.isInfinite }
    public var isEmpty: Bool { isNull || size.width <= 0 || size.height <= 0 }

    public func intersection(_ r2: CGRect) -> CGRect {
        if isNull || r2.isNull { return .null }
        let x0 = max(minX, r2.minX)
        let y0 = max(minY, r2.minY)
        let x1 = min(maxX, r2.maxX)
        let y1 = min(maxY, r2.maxY)
        if x1 <= x0 || y1 <= y0 { return .null }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func contains(_ rect: CGRect) -> Bool {
        guard !isNull, !rect.isNull, !isEmpty, !rect.isEmpty else { return false }
        return rect.minX >= minX && rect.minY >= minY && rect.maxX <= maxX && rect.maxY <= maxY
    }
}
#endif
#if os(macOS)
import AppKit
#endif

/// Window size in points, parsed from AppKit's frame autosave string.
public struct WindowFrameSize: Sendable, Equatable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Utilities for AppKit `NSWindow` frame persistence, parsing, and multi-display clamping.
public enum WindowFramePersistence {
    /// Parses AppKit's `"x y width height screenX screenY screenW screenH"` string into a size.
    public static func parseSize(from frameString: String) -> WindowFrameSize? {
        let parts = frameString.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 4,
              let width = Double(parts[2]),
              let height = Double(parts[3]),
              width >= 1.0,
              height >= 1.0
        else {
            return nil
        }
        return WindowFrameSize(width: width, height: height)
    }

    /// Parses AppKit's `"x y width height ..."` string into a `CGRect`.
    public static func parseRect(from frameString: String) -> CGRect? {
        let parts = frameString.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 4,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let width = Double(parts[2]),
              let height = Double(parts[3]),
              width >= 1.0,
              height >= 1.0
        else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Reads the saved window size for `name` from `UserDefaults`.
    public static func savedSize(
        named name: String,
        userDefaults: UserDefaults = .standard
    ) -> WindowFrameSize? {
        guard let frameString = userDefaults.string(forKey: "NSWindow Frame \(name)") else {
            return nil
        }
        return parseSize(from: frameString)
    }

    /// Reads the saved window rect for `name` from `UserDefaults`.
    public static func savedRect(
        named name: String,
        userDefaults: UserDefaults = .standard
    ) -> CGRect? {
        guard let frameString = userDefaults.string(forKey: "NSWindow Frame \(name)") else {
            return nil
        }
        return parseRect(from: frameString)
    }

    /// Clamps `frame` so it stays visible within the best-matching display in `visibleFrames`.
    ///
    /// Selects the screen with the largest intersection area (or the first screen if none
    /// intersect), shrinks width/height if larger than the target screen's visible frame,
    /// and shifts origin so the frame fits within the target screen's bounds.
    public static func clampFrame(
        _ frame: CGRect,
        toVisibleFrames visibleFrames: [CGRect],
        minimumSize: CGSize = CGSize(width: 100, height: 100)
    ) -> CGRect {
        guard let fallback = visibleFrames.first else {
            return frame
        }

        let target = visibleFrames.max { lhs, rhs in
            let leftArea = frame.intersection(lhs).area
            let rightArea = frame.intersection(rhs).area
            return leftArea < rightArea
        } ?? fallback

        let chosen = frame.intersection(target).isNull ? fallback : target

        let clampedWidth = min(max(frame.width, min(minimumSize.width, chosen.width)), chosen.width)
        let clampedHeight = min(max(frame.height, min(minimumSize.height, chosen.height)), chosen.height)

        let maxX = chosen.maxX - clampedWidth
        let maxY = chosen.maxY - clampedHeight

        let clampedX = min(max(frame.origin.x, chosen.minX), maxX)
        let clampedY = min(max(frame.origin.y, chosen.minY), maxY)

        return CGRect(x: clampedX, y: clampedY, width: clampedWidth, height: clampedHeight)
    }

    #if os(macOS)
    /// Associates `name` as the frame autosave name on all current `NSApplication` windows.
    /// Returns `true` when at least one window exists.
    @MainActor
    @discardableResult
    public static func rememberFrame(named name: String) -> Bool {
        let windows = NSApplication.shared.windows
        for window in windows {
            window.setFrameAutosaveName(name)
        }
        return !windows.isEmpty
    }

    /// Clamps `window` to the visible frames of the provided `screens`.
    @MainActor
    public static func clampWindow(
        _ window: NSWindow,
        screens: [NSScreen] = NSScreen.screens
    ) {
        let visibleFrames = screens.map(\.visibleFrame)
        guard !visibleFrames.isEmpty else { return }
        let clamped = clampFrame(window.frame, toVisibleFrames: visibleFrames)
        if clamped != window.frame {
            window.setFrame(clamped, display: true)
        }
    }

    /// Clamps all windows of `NSApplication.shared` to `NSScreen.screens`.
    @MainActor
    public static func clampAllWindows() {
        let screens = NSScreen.screens
        for window in NSApplication.shared.windows {
            clampWindow(window, screens: screens)
        }
    }

    /// Returns the key window, falling back to the main window.
    @MainActor
    public static var keyOrMainWindow: NSWindow? {
        let app = NSApplication.shared
        return app.keyWindow ?? app.mainWindow
    }

    /// Toggles macOS native full screen on the key/main window.
    @MainActor
    public static func toggleFullScreen() {
        keyOrMainWindow?.toggleFullScreen(nil)
    }

    /// Whether the key/main window is currently in macOS full screen.
    @MainActor
    public static var isFullScreen: Bool {
        keyOrMainWindow?.styleMask.contains(.fullScreen) ?? false
    }
    #endif
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
