#if os(Linux) || os(Windows)
#if os(Linux)
import CRuneLinux
#else
import CRuneWin32
#endif

/// Windows and Linux apply frame requests immediately. The resulting native resize
/// preserves content motion, while a resize initiated by the user lands it.
@MainActor
final class DesktopWindowFrame {
    private let minimum: (Float, Float)
    private let maximum: (Float, Float)?
    private var move: WindowFrameMove?

    init(limits: ((Float, Float), (Float, Float)?)) {
        (minimum, maximum) = limits
    }

    func apply(_ request: WindowFrameRequest, to window: OpaquePointer) {
        let size = request.size.map { WindowFrame.clampSize($0, min: minimum, max: maximum) }
        // The native resize can synchronously dispatch WM_SIZE.
        let origin = targetOrigin(for: size, center: request.center, of: window)
        if let size { move = .jumped(size) }
        #if os(Windows)
        if size != nil || origin != nil {
            rune_win_place_frame(window, origin == nil ? 0 : 1, origin?.0 ?? 0, origin?.1 ?? 0,
                                 size == nil ? 0 : 1, Double(size?.0 ?? 0), Double(size?.1 ?? 0))
        }
        #else
        if let (w, h) = size { rune_linux_set_size(window, nativeDimension(w), nativeDimension(h)) }
        if let (x, y) = origin { rune_linux_set_position(window, x, y) }
        #endif
    }

    func resized<State>(_ viewport: Vec2, scale: Float, runtime: Runtime<State>) {
        guard viewport.x > 0, viewport.y > 0 else { return }
        let previous = runtime.cxSettings.zoomState
        guard viewport != previous.window || scale != previous.windowScale else { return }
        if WindowFrameMove.takeJump(&move, viewport: (viewport.x, viewport.y)) {
            runtime.stepViewport(viewport, pixelScale: scale)
        } else {
            runtime.setViewport(viewport, pixelScale: scale)
        }
    }

    private func targetOrigin(for size: (Float, Float)?, center: Bool, of window: OpaquePointer) -> (Int32, Int32)? {
        var outerWidth: UInt32 = 0, outerHeight: UInt32 = 0
        #if os(Windows)
        var placement = RuneWinPlacement()
        let available = rune_win_frame_geometry(window, &placement, &outerWidth, &outerHeight)
        #else
        var placement = RuneLinuxPlacement()
        // Wayland leaves positioning of top-level windows to the compositor.
        let available = rune_linux_frame_geometry(window, &placement, &outerWidth, &outerHeight)
        #endif
        guard available != 0, placement.display_width > 0, placement.display_height > 0 else { return nil }
        let current = [Float(placement.x), Float(placement.y), Float(outerWidth), Float(outerHeight)]
        let visible = [Float(placement.display_x), Float(placement.display_y),
                       Float(placement.display_width), Float(placement.display_height)]
        let outer = size.map { width, height in
            (width * Float(placement.scale) + max(0, Float(outerWidth) - Float(placement.width)),
             height * Float(placement.scale) + max(0, Float(outerHeight) - Float(placement.height)))
        }
        let target = WindowFrame.target(current: current, outer: outer, center: center, visible: visible)
        guard target[0] != current[0] || target[1] != current[1] else { return nil }
        func coordinate(_ value: Float) -> Int32 {
            Int32(max(Double(Int32.min), min(Double(Int32.max), Double(value).rounded())))
        }
        return (coordinate(target[0]), coordinate(target[1]))
    }
}
#endif
