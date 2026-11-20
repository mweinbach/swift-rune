#if os(Linux)
import CRuneLinux
import CRuneLinuxA11y
import Foundation
import RuneMotion

@MainActor private protocol LinuxOverlayEvents: AnyObject {
    func receive(_ event: RuneOverlayEvent) -> Bool
}

private func linuxOverlayEvent(_ context: UnsafeMutableRawPointer?, _ event: UnsafePointer<RuneOverlayEvent>?) -> Int32 {
    guard let context, let event else { return 0 }
    let address = UInt(bitPattern: context)
    let value = event.pointee
    return MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return 0 }
        let owner = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
        return (owner as? any LinuxOverlayEvents)?.receive(value) == true ? 1 : 0
    }
}

// Invoked on the descriptor watcher's GLib worker thread.
private func wakeLinuxOverlayLoop(_ context: UnsafeMutableRawPointer?) {
    if let context { rune_linux_wake(0, UInt32(UInt(bitPattern: context))) }
}

/// The GLib poll descriptors and frame-clock deadlines wake SDL while its native
/// queue sleeps, including an accessory app with only layer-shell surfaces.
@MainActor enum LinuxOverlayPump {
    private static var users = 0
    private static var watch: OpaquePointer?
    private static var wakeType: UInt32 = 0

    static func begin(_ type: UInt32) { wakeType = type }
    static func retain() {
        users += 1
        guard users == 1, wakeType != 0 else { return }
        watch = rune_glib_watch_new(wakeLinuxOverlayLoop, UnsafeMutableRawPointer(bitPattern: UInt(wakeType)))
    }
    static func release() {
        users -= 1
        if users == 0, let watch { rune_glib_watch_free(watch); self.watch = nil }
    }
    static func pump() {
        guard users > 0 else { return }
        rune_overlay_pump()
        if let watch { rune_glib_watch_arm(watch) }
    }
}

@MainActor final class RuneLinuxOverlayHost<State>: DesktopOverlayHost, LinuxOverlayEvents {
    private weak var handle: OverlayHandle<State>?
    private var window: OpaquePointer?
    private var renderer: PortableGLRenderer?
    private var backend = RuneOverlayX11
    private var accessibility: LinuxAccessibilityHost?
    private var nativeOrigin: (x: Int32, y: Int32) = (0, 0)
    private var logicalSize = Vec2(1, 1)
    private var lost = false
    private var regions: [MotionRect] = []
    private var lastCursor: Cursor?
    private var lastPoint = Vec2.zero
    private var modifiers = Mods.none

    init(handle: OverlayHandle<State>) throws { self.handle = handle }

    private var now: Double { Date().timeIntervalSinceReferenceDate }
    private func open(warmGPU: Bool) throws {
        guard let handle, window == nil else { return }
        let options = handle.desktopConfiguration().options
        let acceptsFallback = allowsXWayland(options)
        guard let window = rune_overlay_new(handle.name, acceptsFallback ? 1 : 0,
                                            Unmanaged.passUnretained(self).toOpaque(), linuxOverlayEvent) else {
            throw DesktopWindowError(String(cString: rune_overlay_error()))
        }
        self.window = window
        lost = false
        LinuxOverlayPump.retain()
        backend = rune_overlay_backend(window)
        if warmGPU {
            do { try makeRenderer() } catch { close(); throw error }
        }
        accessibility = LinuxAccessibilityHost(title: handle.name, waker: handle.withLockedRuntime { $0.waker },
                                                isVisible: false, overlay: true) { [weak handle] host in
            handle?.withLockedRuntime { host.serviceDemand(runtime: $0) }
        }
        configure()
        let xid = rune_overlay_xid(window)
        let name = backend == RuneOverlayLayer ? "Wayland layer-shell" : backend == RuneOverlayXWayland ? "XWayland" : "X11"
        handle.desktopCreated(windowNumber: xid == 0 ? nil : xid, capabilities: OverlayCapabilities(
            captureExclusion: .unsupported,
            nonactivatingKeys: OverlayKeys.keysSupport(options.keyPolicy, focuser: rune_overlay_has_keys(window) != 0),
            globalPointer: backend == RuneOverlayX11 ? .supported : .unsupported
        ), description: "\(name) OpenGL overlay" + (renderer.map { " (\($0.adapter.device))" } ?? ""))
    }

    private func allowsXWayland(_ options: OverlayOptions) -> Bool {
        OverlayKeys.xwaylandAllowed(
            input: options.input.resolved(interactive: options.interactive),
            keyPolicy: options.keyPolicy,
            optIn: options.xwaylandInput
        )
    }

    private func makeRenderer() throws {
        guard let window, renderer == nil else { return }
        guard rune_overlay_make_current(window) != 0 else { throw DesktopWindowError(String(cString: rune_overlay_error())) }
        renderer = try PortableGLRenderer(resolve: rune_overlay_gl_proc, isGLES: rune_overlay_uses_gles(window) != 0)
    }

    func apply(_ command: DesktopOverlayCommand) {
        guard let handle else { close(); return }
        let options = handle.desktopConfiguration().options
        let deferGPU = options.releaseGpuWhenHidden || options.releaseGpuAfter != nil
        if case .prewarm = command, deferGPU, rune_overlay_wayland_session() != 0 { return }
        // Layer surfaces may be closed by the compositor. Recreate on an explicit show.
        if window == nil || lost {
            switch command {
            case .show, .prewarm:
                if lost { close() }
                let warmGPU: Bool
                if case .prewarm = command { warmGPU = !deferGPU } else { warmGPU = true }
                do { try open(warmGPU: warmGPU) } catch { handle.desktopFailure(String(describing: error)); return }
            default: return
            }
        }
        guard let window else { return }
        if backend == RuneOverlayXWayland, !allowsXWayland(handle.desktopConfiguration().options) {
            close()
            handle.desktopFailure("Interactive XWayland overlays require opt-in and cannot request keyboard focus")
            return
        }
        switch command {
        case .prewarm:
            guard !deferGPU, let renderer, rune_overlay_make_current(window) != 0 else { return }
            do { try handle.desktopPrewarm(at: now, viewport: logicalSize, scale: Float(max(1, rune_overlay_scale(window))), renderer: renderer) }
            catch { handle.desktopFailure(String(describing: error)) }
        case let .show(duration):
            do { try makeRenderer() } catch { handle.desktopFailure(String(describing: error)); return }
            accessibility?.setVisible(true)
            configure()
            rune_overlay_schedule(window, -1)
            rune_overlay_show(window, 1, duration)
            syncOrigin()
        case let .hide(duration):
            _ = answerShellRequests(handle, at: now)
            accessibility?.setVisible(false)
            applyInput(handle.desktopConfiguration().options)
            rune_overlay_show(window, 0, duration)
            schedule(nil)
        case .configure, .refollow:
            configure()
            rune_overlay_redraw(window)
        case .focus:
            if handle.desktopPresence().isShown && OverlayKeys.canTakeKeys(handle.desktopConfiguration().options.keyPolicy) {
                rune_overlay_focus(window)
            }
        case .wake:
            if let accessibility {
                var focus = false
                handle.withLockedRuntime { rt in
                    _ = accessibility.pump(runtime: rt, at: now) { focus = true }
                }
                if focus && handle.desktopPresence().isShown && OverlayKeys.canTakeKeys(handle.desktopConfiguration().options.keyPolicy) {
                    rune_overlay_focus(window)
                }
            }
            rune_overlay_redraw(window)
        case .release: close()
        }
    }

    private func configure() {
        guard let handle, let window else { return }
        let (placement, options, _) = handle.desktopConfiguration()
        var index: Int32 = -1, underPointer = false, name: String?
        switch options.display {
        case .primary: break
        case .underPointer: underPointer = true
        case .index(let i): index = Int32(exactly: i) ?? -1
        case .named(let n): name = n
        case .id, .native:
            let native: NativeDisplayId?
            if case .native(let id) = options.display { native = id }
            else if case .id(let id) = options.display { native = id.native }
            else { native = nil }
            switch native {
            case .other(let n): index = Int32(exactly: n) ?? -1
            case .wayland(let n): name = n
            default: break
            }
        }
        var monitor = RuneOverlayRect()
        rune_overlay_monitor(window, index, underPointer ? 1 : 0, name, &monitor)
        let target = options.legacyPlacement
        let r = OverlayGeometry.localRect(at: placement, placement: target, area: Vec2(Float(monitor.width), Float(monitor.height)))
        let rect = RuneOverlayRect(x: coordinate(r[0].rounded()), y: coordinate(r[1].rounded()),
                                  width: max(1, coordinate(r[2].rounded(.up))), height: max(1, coordinate(r[3].rounded(.up))))
        logicalSize = Vec2(Float(rect.width), Float(rect.height))
        rune_overlay_level(window, Int32(options.level.rawValue))
        rune_overlay_place(window, rect, target == .fullDisplay ? 1 : 0, underPointer && options.followPointer ? 1 : 0)
        applyInput(options)
        handle.desktopCapabilities(OverlayCapabilities(
            captureExclusion: .unsupported,
            nonactivatingKeys: OverlayKeys.keysSupport(options.keyPolicy, focuser: rune_overlay_has_keys(window) != 0),
            globalPointer: backend == RuneOverlayX11 ? .supported : .unsupported
        ))
    }

    private func syncOrigin() {
        guard let handle, let window else { return }
        var x: Int32 = 0, y: Int32 = 0, px: Int32 = 0, py: Int32 = 0
        let known = rune_overlay_origin(window, &x, &y, &px, &py) != 0
        nativeOrigin = (x, y)
        let scale = Float(max(1, rune_overlay_scale(window)))
        let origin = known ? Vec2(Float(Int64(x) - Int64(px)) / scale, Float(Int64(y) - Int64(py)) / scale) : .zero
        handle.withLockedRuntime { runtime in
            runtime.setWindowOrigin(origin, at: now)
            runtime.setWindowPixels(known ? (x, y) : nil)
        }
    }

    private func coordinate(_ x: Float) -> Int32 {
        guard x.isFinite else { return 0 }
        return Int32(max(Double(Int32.min), min(Double(Int32.max), Double(x))))
    }

    private func applyInput(_ options: OverlayOptions) {
        guard let window else { return }
        let mode = options.input.resolved(interactive: options.interactive)
        let enabled = handle?.desktopPresence().isShown == true
        rune_overlay_observe_regions(window, enabled && mode == .regions ? 1 : 0)
        guard enabled else { rune_overlay_input(window, 0, nil, 0); return }
        let shape = mode == .regions ? regions.compactMap { r -> RuneOverlayRect? in
            let x = coordinate(r.left.rounded(.down)), y = coordinate(r.top.rounded(.down))
            let w = Int64(coordinate(r.right.rounded(.up))) - Int64(x)
            let h = Int64(coordinate(r.bottom.rounded(.up))) - Int64(y)
            guard w > 0 && h > 0 else { return nil }
            return RuneOverlayRect(x: x, y: y, width: Int32(clamping: w), height: Int32(clamping: h))
        } : []
        rune_overlay_input(window, mode == .all ? 1 : 0, shape, Int32(clamping: shape.count))
    }

    private func schedule(_ deadline: Double?) {
        guard let window, let handle else { return }
        let next = [deadline, handle.desktopPresence().deadline].compactMap { $0 }.min()
        rune_overlay_schedule(window, next.map { max(0, $0 - now) } ?? -1)
    }

    func receive(_ event: RuneOverlayEvent) -> Bool {
        guard let window, let handle else { return false }
        let time = now
        switch event.kind {
        case RuneOverlayDraw:
            do {
                try makeRenderer()
                guard let renderer, let batch = handle.desktopRenderFrame(at: time,
                    viewport: Vec2(Float(event.width), Float(event.height)), scale: Float(max(1, event.scale)), renderer: renderer)
                else { return true }
                try handle.desktopDraw(batch.frame, at: time, renderer: renderer)
                handle.desktopSubmitted(batch.frame, scale: Float(max(1, event.scale)))
                if renderer.needsSurfaceCompletionPoll && renderer.pollSurfaceCompletions() {
                    rune_overlay_schedule_gpu_poll(window)
                }
                handle.withLockedRuntime { accessibility?.update(runtime: $0, windowX: nativeOrigin.x, windowY: nativeOrigin.y) }
                if regions != batch.regions { regions = batch.regions; applyInput(handle.desktopConfiguration().options) }
                let answered = answerShellRequests(handle, at: time)
                schedule(batch.isAnimating || answered ? time : batch.nextWake)
            } catch {
                rune_overlay_show(window, 0, 0)
                handle.desktopFailure(String(describing: error))
            }
        case RuneOverlayPollGPU:
            if let renderer, renderer.needsSurfaceCompletionPoll {
                if rune_overlay_make_current(window) == 0 {
                    renderer.abandon()
                    self.renderer = nil
                } else if renderer.pollSurfaceCompletions() {
                    rune_overlay_schedule_gpu_poll(window)
                }
            }
        case RuneOverlayDue:
            handle.advanceDue(at: time)
            if handle.desktopPresence().isDrawing { rune_overlay_redraw(window) }
            schedule(nil)
        case RuneOverlayGLGone:
            if event.active != 0 { renderer?.close() } else { renderer?.abandon() }
            renderer = nil
        case RuneOverlayClosed:
            lost = true
            accessibility?.setVisible(false)
            rune_overlay_show(window, 0, 0)
            handle.desktopFailure("The compositor closed the Linux overlay")
        case RuneOverlayMonitor: configure()
        case RuneOverlayGeometry: syncOrigin()
        case RuneOverlayFocus:
            handle.withLockedRuntime { $0.dispatchFocus(event.active != 0, at: time) }
            handle.deliverFocus(event.active != 0)
            if event.active == 0 { modifiers = .none }
            rune_overlay_redraw(window)
        default: return input(event, handle: handle, window: window, at: time)
        }
        return true
    }

    private func input(_ event: RuneOverlayEvent, handle: OverlayHandle<State>, window: OpaquePointer, at time: Double) -> Bool {
        let mods = Mods(shift: event.modifiers & UInt32(RuneLinuxShift) != 0, ctrl: event.modifiers & UInt32(RuneLinuxControl) != 0,
                        alt: event.modifiers & UInt32(RuneLinuxAlt) != 0, logo: event.modifiers & UInt32(RuneLinuxSuper) != 0)
        let windowPoint = Vec2(Float(event.x), Float(event.y))
        let drew = handle.withLockedRuntime { runtime -> Bool in
            let point = runtime.inputPoint(fromWindow: windowPoint)
            switch event.kind {
            case RuneOverlayMotion:
                lastPoint = windowPoint
                return runtime.overlayObservePointer(at: point, mods: mods, at: time)
            case RuneOverlayLeave: runtime.pointerExit(at: time)
            case RuneOverlayLost: runtime.pointerReleaseLost(at: runtime.inputPoint(fromWindow: lastPoint), at: time)
            case RuneOverlayWheel:
                // GDK positive Y scrolls the viewport down. Rune takes content motion.
                let x = -Float(event.dx), y = -Float(event.dy)
                let delta: MouseScrollDelta = event.active != 0 ? .pixel(x: x, y: y) : .line(x: x, y: y)
                let (dx, dy) = WheelDistance.wheelDelta(delta, scale: 1, shift: mods.shift, linePoints: WheelDistance.linePoints)
                if mods.ctrl && runtime.pinchWheel(dy: dy, at: point, now: time) { return true }
                let zoom = runtime.zoom()
                runtime.wheel(WheelEvent(dx: dx / zoom, dy: dy / zoom,
                                         precise: event.active != 0, mods: mods), at: point, now: time)
            case RuneOverlayButton:
                let button: PointerButton
                switch event.code {
                case 1: button = .primary
                case 2: button = .middle
                case 3: button = .secondary
                case 8: button = .back
                case 9: button = .forward
                default: return false
                }
                lastPoint = windowPoint
                if event.active != 0 {
                    // A click gives an X11 override-redirect overlay that may take keys the focus,
                    // as it does the macOS panel; the window manager gives an override-redirect window none (#1240).
                    if backend == RuneOverlayX11 && OverlayKeys.canTakeKeys(handle.desktopConfiguration().options.keyPolicy) {
                        rune_overlay_focus(window)
                    }
                    runtime.pointerDown(at: point, button: button, mods: mods, at: time)
                }
                else { runtime.pointerUp(at: point, button: button, mods: mods, at: time) }
            case RuneOverlayKey:
                if mods != modifiers { runtime.dispatchModifiers(mods, at: time); modifiers = mods }
                let key = LinuxKeyMap.namedKeysym(UInt32(bitPattern: event.code)) ??
                    LinuxDesktopKey.logical(Int32(bitPattern: event.unicode), mods: mods)
                guard let key else { return false }
                let ev = KeyEvent(key: key, mods: mods)
                return event.active != 0 ? runtime.keyDown(ev, at: time) : runtime.keyUp(ev, at: time)
            default: return false
            }
            return true
        }
        if event.kind == RuneOverlayButton && event.active == 0 || event.kind == RuneOverlayLost { _ = handle.applyInput() }
        if event.kind == RuneOverlayMotion || event.kind == RuneOverlayButton {
            let cursor = handle.withLockedRuntime { $0.currentCursor() }
            if cursor != lastCursor { lastCursor = cursor; applyCursor(cursor, window: window) }
        }
        let answered = answerShellRequests(handle, at: time)
        if answered || drew { rune_overlay_redraw(window) }
        return drew
    }

    // Rust's Linux overlay shell resolves these operations without a native
    // popup or drag session. Deliver the result while the requestor is alive.
    private func answerShellRequests(_ handle: OverlayHandle<State>, at time: Double) -> Bool {
        handle.withLockedRuntime { rt in
            let drag = rt.takeDragOutStart() != nil
            if drag { rt.finishDragOut(.cancelled, at: time) }
            let popup = rt.hasPopup
            if popup { rt.cancelPopups() }
            return drag || popup
        }
    }

    private func applyCursor(_ cursor: Cursor, window: OpaquePointer) {
        let name: String
        switch cursor {
        case .default: name = "default"
        case .image(let image):
            guard let metrics = try? image.decodedMetrics(), let frame = try? Frame.fromPNG(data: Data(image.bytes)) else {
                rune_overlay_cursor(window, nil); return
            }
            frame.rgba.withUnsafeBufferPointer { pixels in
                rune_overlay_image_cursor(window, pixels.baseAddress, Int32(frame.width), Int32(frame.height),
                                          Int32(metrics.width), Int32(metrics.height), Int32(metrics.hot.x), Int32(metrics.hot.y))
            }
            return
        case .pointer: name = "pointer"
        case .text: name = "text"
        case .grab: name = "grab"
        case .grabbing: name = "grabbing"
        case .notAllowed: name = "not-allowed"
        case .move: name = "move"
        case .resizeColumn: name = "col-resize"
        case .resizeRow: name = "row-resize"
        case .crosshair: name = "crosshair"
        case .cell: name = "cell"
        case .zoomIn: name = "zoom-in"
        case .zoomOut: name = "zoom-out"
        case .hidden: name = "none"
        }
        rune_overlay_cursor(window, name)
    }

    func releaseGPUOnHide() -> Bool {
        guard let window, backend == RuneOverlayX11 else { return false }
        releaseRenderer(window)
        rune_overlay_park(window)
        return true
    }

    private func releaseRenderer(_ window: OpaquePointer) {
        if let renderer {
            if rune_overlay_make_current(window) != 0 { renderer.close() } else { renderer.abandon() }
        }
        renderer = nil
    }

    func close() {
        guard let window else { return }
        if let handle { _ = answerShellRequests(handle, at: now) }
        releaseRenderer(window)
        accessibility = nil
        self.window = nil
        rune_overlay_free(window)
        LinuxOverlayPump.release()
        handle?.desktopClosed()
    }
}
#endif
