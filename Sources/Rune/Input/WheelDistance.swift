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
    internal func desktopWheel(dx: Float, dy: Float, at point: Vec2, mods: Mods, now: Double, precise: Bool = false) {
        if mods.ctrl && pinchWheel(dy: dy, at: point, now: now) { return }
        wheelFromWindow(WheelEvent(dx: dx, dy: dy, precise: precise, mods: mods), at: point, now: now)
    }

    /// Native deltas arrive in window points. The host has already converted the hit point to view coordinates.
    internal func wheelFromWindow(_ event: WheelEvent, at point: Vec2, now: Double) {
        let zoom = zoom()
        var viewEvent = event
        viewEvent.dx /= zoom
        viewEvent.dy /= zoom
        wheel(viewEvent, at: point, now: now)
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
    /// winit gives momentum boundaries precedence over touch boundaries. A plain mouse wheel
    /// and a trackpad's intermediate phases both supply changed deltas.
    static func appKitPhase(touch: NSEvent.Phase, momentum: NSEvent.Phase) -> GesturePhase {
        func boundary(_ phase: NSEvent.Phase) -> GesturePhase? {
            switch phase {
            case .mayBegin, .began: .began
            case .ended, .cancelled: .ended
            default: nil
            }
        }
        return boundary(momentum) ?? boundary(touch) ?? .changed
    }

    @MainActor
    static func appKitEvent(_ event: NSEvent) -> WheelEvent {
        let x = Float(event.scrollingDeltaX)
        let y = Float(event.scrollingDeltaY)
        let precise = event.hasPreciseScrollingDeltas
        // AppKit reports precise deltas in points and already applies Shift.
        let delta: MouseScrollDelta = precise ? .pixel(x: x, y: y) : .line(x: x, y: y)
        let (dx, dy) = wheelDelta(delta, scale: 1, shift: false, linePoints: linePoints)
        return WheelEvent(dx: dx, dy: dy, precise: precise,
                          phase: appKitPhase(touch: event.phase, momentum: event.momentumPhase),
                          mods: MacOSKeyMapper.mods(for: event))
    }
    #endif
}
