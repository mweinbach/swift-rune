import Foundation
import RuneMotion
#if canImport(AppKit) && os(macOS)
import AppKit
#endif

// MARK: - Native Wheel Distance (`runtime/scroll/x.rs` `wheel_delta` / `LINE_POINTS`, #856)

/// A platform wheel delta before it becomes points (winit's `MouseScrollDelta`): whole or
/// fractional scroll lines from a notched mouse wheel, or pixels from a precise device.
public enum MouseScrollDelta: Sendable, Equatable {
    /// Lines on (x, y), positive moving content right and down.
    case line(x: Float, y: Float)
    /// Physical pixels on (x, y), positive moving content right and down.
    case pixel(x: Float, y: Float)
}

extension Runtime {
    /// Delivers a desktop wheel in window points. Ctrl+wheel magnification uses
    /// its native distance, and ordinary wheel handlers receive view points.
    internal func desktopWheel(dx: Float, dy: Float, at point: Vec2, mods: Mods, now: Double) {
        if mods.ctrl && pinchWheel(dy: dy, at: point, now: now) { return }
        let zoom = zoom()
        wheel(WheelEvent(dx: dx / zoom, dy: dy / zoom, precise: false, mods: mods), at: point, now: now)
    }

    /// Resolves Windows' per-device line/page setting in window points before page zoom.
    internal func windowsWheelLinePoints(count: UInt32, ticks: Float, horizontal: Bool, shift: Bool, at point: Vec2) -> Float {
        guard !horizontal && count == UInt32.max else { return Float(count) * (100 / 3) }
        guard ticks != 0 else { return 0 }
        let window = shift ? viewport.x : viewport.y
        let scroller = scrollAtAxis(point.x, point.y, horizontal: shift)
            .flatMap { nodeByPath[$0] }
            .map { shift ? flatNodes[$0].localRect.width : flatNodes[$0].localRect.height }
        return max(min(scroller ?? window, window) * zoom() * 0.875, 1 / abs(ticks))
    }
}

/// Native wheel scroll distances matched to Chromium (`scroll/x.rs`, upstream #856).
public enum WheelDistance {
    /// Points one wheel line scrolls. Chromium 152: `ui/events/event.cc` (`kWheelDelta` on
    /// Linux), `ui/events/x/events_x_utils.cc` (XI2 scroll increments),
    /// `ui/events/cocoa/cocoa_event_utils.h` (`kScrollbarPixelsPerCocoaTick`) and
    /// `cc/input/scroll_utils.h` (`kPixelsPerLineStep` for browser line units).
    /// Windows reads `SPI_GETWHEELSCROLLLINES` per event instead (`windows_wheel_points`).
    #if os(Linux)
    public static let linePoints: Float = 120.0
    #else
    public static let linePoints: Float = 40.0
    #endif

    /// Whether Shift turns the wheel on this platform (macOS does it before the app sees the
    /// event) (`SHIFT_TURNS_WHEEL`).
    #if os(macOS)
    public static let shiftTurnsWheel: Bool = false
    #else
    public static let shiftTurnsWheel: Bool = true
    #endif

    /// A wheel event's delta in points, positive moving content right and down
    /// (`scroll/x.rs` `wheel_delta`). Pixels divide by `scale`; lines scale by `linePoints`.
    /// With Shift, a delta with no horizontal part turns horizontal, as browsers and Windows and
    /// Linux apps do for a mouse wheel. macOS turns it itself (`shift` is false there), and a
    /// delta that already has a horizontal part was turned by the system or comes from a
    /// trackpad.
    public static func wheelDelta(_ delta: MouseScrollDelta, scale: Float, shift: Bool, linePoints: Float) -> (Float, Float) {
        let dx: Float
        let dy: Float
        switch delta {
        case .pixel(let x, let y):
            dx = x / scale
            dy = y / scale
        case .line(let x, let y):
            dx = x * linePoints
            dy = y * linePoints
        }
        if shift && dx == 0 { return (dy, 0) }
        return (dx, dy)
    }

    #if canImport(AppKit) && os(macOS)
    /// An AppKit scroll event's delta in window points, as winit reads it (`PixelDelta` when the
    /// device has precise deltas, else `LineDelta` of `scrollingDeltaX/Y`) and the window host
    /// converts it (`window/events.rs`): `LINE_POINTS` per line, Shift left to AppKit.
    @MainActor
    static func points(for event: NSEvent) -> (Float, Float) {
        let x = Float(event.scrollingDeltaX)
        let y = Float(event.scrollingDeltaY)
        // AppKit reports precise deltas in points already, so the scale is 1.
        let delta: MouseScrollDelta = event.hasPreciseScrollingDeltas ? .pixel(x: x, y: y) : .line(x: x, y: y)
        let shift = shiftTurnsWheel && event.modifierFlags.contains(.shift)
        return wheelDelta(delta, scale: 1, shift: shift, linePoints: linePoints)
    }
    #endif
}
