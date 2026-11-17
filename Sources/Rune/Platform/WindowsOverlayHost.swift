#if os(Windows)
import CRuneWin32
import Foundation
import RuneMotion

@MainActor
private enum WindowsOverlayLevels {
    static var levels: [(window: OpaquePointer, level: OverlayLevel)] = []
    static func order(_ window: OpaquePointer, _ level: OverlayLevel) {
        levels.removeAll { $0.window == window }
        levels.append((window, level))
        for priority in [OverlayLevel.status, .aboveStatus, .aboveOverlays] {
            for item in levels where item.level == priority { rune_win_overlay_raise(item.window) }
        }
    }
}

@MainActor
final class RuneWindowsOverlayHost<State>: Win32Callback, DesktopOverlayHost {
    private weak var handle: OverlayHandle<State>?
    private let window: OpaquePointer
    private let renderer: PortableGLRenderer
    private let popups: WindowsPopup<State>
    private let accessibility: WindowsAccessibilityHost
    private let dragSource = Win32DragSource()
    private var appliedCursor: Cursor?
    private var cursorDPI: UInt32 = 0
    private let observer: PointerObserver
    private var watch: OpaquePointer?
    private var monitors = [DisplayInfo]()
    private var bounds = [PointerIntRect]()
    private var placement = RuneWinPlacement()
    private var mode = OverlayInput.none
    private var options: OverlayOptions
    private var layout: OverlayGeometry.Placement
    private var regions = [MotionRect]()
    private var buttons: Set<UInt32> = []
    private var last = Vec2.zero
    private var currentMonitor: Int?
    private var refollowAway: Int?
    private var capabilities = OverlayCapabilities(nonactivatingKeys: .unsupported, globalPointer: .supported)
    private var visible = false
    private var fade: (start: Double, end: Double, from: Double, to: Double)?
    private var alpha = 1.0
    private var closed = false

    init(handle: OverlayHandle<State>) throws {
        self.handle = handle
        let configuration = handle.desktopConfiguration()
        layout = configuration.placement
        options = configuration.options
        var error = [CChar](repeating: 0, count: 512)
        guard let window = (Array(handle.name.utf16) + [0]).withUnsafeBufferPointer({
            rune_win_create($0.baseAddress, 1, 1, 1, 1, 0, &error, 512)
        }) else { throw DesktopWindowError(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
        self.window = window
        do {
            var style = RuneWinOptions()
            style.borderless = 1
            rune_win_configure(window, style)
            guard rune_win_overlay_setup(window) != 0 else { throw DesktopWindowError("Could not compose the Windows RGBA overlay") }
            renderer = try PortableGLRenderer(resolve: rune_win_gl_proc, isGLES: false)
        } catch { rune_win_destroy(window); throw error }
        popups = handle.windowsPopups(window: window)
        accessibility = WindowsAccessibilityHost(window: rune_win_hwnd(window))
        // Unregistering joins in-flight callbacks before destroying the HWND.
        let address = UInt(bitPattern: window)
        observer = PointerObserver { rune_win_overlay_observed(OpaquePointer(bitPattern: address)) }
        super.init()
        rune_win_start(window, Unmanaged.passUnretained(self).toOpaque(), dispatchWin32, 1, 0)
        configure()
        handle.desktopCreated(windowNumber: nil, capabilities: capabilities, description: renderer.adapter.description)
    }

    private func cursor() -> (Int32, Int32)? {
        var x: Int32 = 0, y: Int32 = 0
        return rune_win_overlay_pointer(&x, &y) != 0 ? (x, y) : nil
    }

    private func configure() {
        guard let handle else { return }
        let previous = options
        let config = handle.desktopConfiguration()
        options = config.options
        layout = config.placement
        mode = options.input.resolved(interactive: options.interactive)
        monitors = (try? DesktopDisplays.connected()) ?? []
        bounds = monitors.map { d in
            PointerIntRect(d.position.0, d.position.1, Int32(clamping: Int64(d.position.0) + Int64(d.size.0)),
                           Int32(clamping: Int64(d.position.1) + Int64(d.size.1)))
        }
        let target: Int?
        switch options.display {
        case .primary: target = monitors.firstIndex(where: \.primary)
        case .index(let i): target = i
        case .named(let name): target = monitors.firstIndex { $0.name == name }
        case .id(let id): target = monitors.firstIndex { $0.id == id }
        case .native(let id): target = monitors.firstIndex { $0.nativeId == id }
        case .underPointer: target = cursor().flatMap { p in bounds.firstIndex { $0.contains(p) } }
        }
        if let target, monitors.indices.contains(target) { place(on: target) }
        else if let fallback = monitors.firstIndex(where: \.primary) ?? monitors.indices.first { place(on: fallback) }
        if previous.excludeFromCapture != options.excludeFromCapture || options.excludeFromCapture && capabilities.captureExclusion == .unknown {
            let applied = rune_win_overlay_exclude(window, options.excludeFromCapture ? 1 : 0) != 0
            capabilities.captureExclusion = options.excludeFromCapture ? (applied ? .requested : .failed) : .unknown
        }
        refreshWatch()
        if visible { WindowsOverlayLevels.order(window, options.level); refreshHit(); rune_win_wake(window) }
    }

    private func place(on index: Int) {
        let d = monitors[index], factor = Float(d.scale)
        var top = d.position.1
        var bottom = bounds[index].y1
        if options.legacyPlacement == nil {
            _ = rune_win_overlay_work_area(d.position.0, d.position.1, &top, &bottom)
        }
        let rect = OverlayGeometry.localRect(at: layout, placement: options.legacyPlacement,
            area: Vec2(Float(d.size.0) / factor, Float(Int64(bottom) - Int64(top)) / factor))
        func pixels(_ value: Float, from origin: Int32 = 0) -> Int32 {
            let position = Double(origin) + (Double(value) * Double(factor)).rounded()
            guard !position.isNaN else { return origin }
            return Int32(max(Double(Int32.min), min(Double(Int32.max), position)))
        }
        currentMonitor = index
        rune_win_overlay_place(window, pixels(rect[0], from: d.position.0), pixels(rect[1], from: top),
                               max(1, pixels(rect[2])), max(1, pixels(rect[3])))
        refreshGeometry()
    }

    private func refreshGeometry() {
        guard rune_win_placement(window, &placement) != 0 else { return }
        let x = placement.content_x, y = placement.content_y
        handle?.withLockedRuntime { runtime in
            runtime.setWindowPixels((x, y))
            runtime.setWindowOrigin(Vec2(Float(x) / scale, Float(y) / scale), at: Date().timeIntervalSinceReferenceDate)
        }
        let canvas = PointerIntRect(x, y, Int32(clamping: Int64(x) + Int64(placement.width)),
                                    Int32(clamping: Int64(y) + Int64(placement.height)))
        observer.configure(canvas: canvas, displays: options.followPointer ? bounds : [], follow: options.followPointer)
        if watch != nil, let point = cursor() { observer.observe(point) }
    }

    private func refreshWatch() {
        let wanted = acceptsInput && (mode == .regions || options.followPointer)
        if wanted && watch == nil {
            watch = rune_win_mouse_watch(Unmanaged.passUnretained(observer).toOpaque()) { context, x, y in
                guard let context else { return }
                Unmanaged<PointerObserver>.fromOpaque(context).takeUnretainedValue().observe((x, y))
            }
        } else if !wanted && watch != nil {
            rune_win_mouse_unwatch(watch)
            watch = nil
            _ = observer.take()
        }
        if watch != nil, let point = cursor() { observer.observe(point) }
        capabilities.globalPointer = wanted && watch == nil ? .failed : .supported
        handle?.desktopCapabilities(capabilities)
    }

    private var scale: Float { max(0.5, Float(placement.scale)) }
    private func local(_ p: (Int32, Int32)) -> Vec2 {
        Vec2(Float(Int64(p.0) - Int64(placement.content_x)) / scale, Float(Int64(p.1) - Int64(placement.content_y)) / scale)
    }
    private var acceptsInput: Bool { visible && fade?.to != 0 }

    private func hit(_ pt: Vec2) -> Bool {
        guard acceptsInput else { return false }
        return !buttons.isEmpty || mode == .all || mode == .regions && regions.contains {
            pt.x >= $0.x && pt.y >= $0.y && pt.x < $0.right && pt.y < $0.bottom
        }
    }
    private func refreshHit() {
        _ = rune_win_click_through(window, hit(cursor().map(local) ?? last) ? 0 : 1)
    }

    func apply(_ command: DesktopOverlayCommand) {
        guard !closed else { return }
        let now = Date().timeIntervalSinceReferenceDate
        switch command {
        case .prewarm:
            guard let handle, rune_win_make_current(window) != 0 else { break }
            let viewport = Vec2(Float(placement.width) / scale, Float(placement.height) / scale)
            do { try handle.desktopPrewarm(at: now, viewport: viewport, scale: scale, renderer: renderer) }
            catch { handle.desktopFailure(String(describing: error)) }
        case .show(let duration):
            let wasHidden = !visible
            visible = true
            if wasHidden { alpha = duration > 0 ? 0 : 1 }
            animate(to: 1, duration: duration, now: now)
            configure()
            rune_win_show(window, 1)
            WindowsOverlayLevels.order(window, options.level)
            rune_win_wake(window)
        case .hide(let duration):
            handle?.withLockedRuntime { _ in popups.cancel() }
            rune_win_overlay_release_pointer(window)
            if duration > 0 && visible && alpha > 0 {
                animate(to: 0, duration: duration, now: now)
                refreshWatch()
                refreshHit()
            } else { hide(at: now) }
        case .configure: configure()
        case .refollow:
            let away = cursor().flatMap { point in bounds.firstIndex { $0.contains(point) } }.flatMap { $0 == currentMonitor ? nil : $0 }
            if let away, away == refollowAway { refollowAway = nil; place(on: away) } else { refollowAway = away }
        case .focus: break // Windows has no nonactivating overlay key acquisition.
        case .wake:
            if visible { rune_win_wake(window) }
            else { handle?.withLockedRuntime { if $0.hasPopup { popups.cancel() } } }
        case .release: close()
        }
    }

    private func animate(to target: Double, duration: Double, now: Double) {
        fade = duration > 0 && alpha != target ? (now, now + duration, alpha, target) : nil
        if fade == nil { alpha = target }
        rune_win_overlay_alpha(window, UInt8((alpha * 255).rounded()))
        rune_win_overlay_due(window, fade == nil ? 0 : 10)
    }

    private func hide(at now: Double) {
        visible = false
        fade = nil
        buttons.removeAll()
        WindowsOverlayLevels.levels.removeAll { $0.window == window }
        rune_win_show(window, 0)
        refreshWatch()
        handle?.advanceDue(at: now)
        let release = handle?.desktopPresence().releaseAt
        rune_win_overlay_due(window, release.map { UInt32(min(Double(Int32.max), max(1, ceil(($0 - now) * 1000)))) } ?? 0)
    }

    private func tick(at now: Double) {
        guard let fade else { handle?.advanceDue(at: now); return }
        let t = min(1, max(0, (now - fade.start) / (fade.end - fade.start)))
        alpha = fade.from + (fade.to - fade.from) * t
        rune_win_overlay_alpha(window, UInt8((alpha * 255).rounded()))
        if t < 1 { rune_win_overlay_due(window, 10) }
        else if fade.to == 0 { hide(at: now) }
        else { self.fade = nil }
    }

    /// Post OLE's drag while the native move still owns its press. A preview reads
    /// this overlay's framebuffer even if a different Rune window presented last.
    private func observe(_ point: Vec2, mods: Mods = .none, at now: Double, handle: OverlayHandle<State>) -> Bool {
        let (dirty, start) = handle.withLockedRuntime { runtime in
            let dirty = runtime.overlayObservePointer(at: runtime.inputPoint(fromWindow: point), mods: mods, at: now)
            return (dirty, dragSource.pending ? nil : runtime.takeDragOutStart())
        }
        guard let start else { return dirty }
        var binding = RuneOverlayGLBinding()
        let bound = rune_win_overlay_bind(window, &binding) != 0
        let picture = (bound || start.item.dragImage != nil) ? DesktopDragPreview.picture(
            start: start, scale: scale, pixelWidth: Int(placement.width), pixelHeight: Int(placement.height)) : nil
        if bound { rune_win_overlay_restore(binding) }
        dragSource.begin(window: window, start: start, picture: picture, scale: scale) { [weak handle] outcome in
            handle?.withLockedRuntime { runtime in
                runtime.finishDragOut(outcome, at: Date().timeIntervalSinceReferenceDate)
                runtime.waker.wake()
            }
        }
        _ = handle.applyInput()
        return true
    }

    override func receive(_ event: RuneWinEvent) -> Int32 {
        guard let handle, !closed else { return -1 }
        let now = Date().timeIntervalSinceReferenceDate
        let point = Vec2(Float(event.x) / scale, Float(event.y) / scale)
        let mods = Win32KeyMap.modifiers(event.mods)
        switch event.kind {
        case RUNE_WIN_FRAME:
            guard visible else { return -1 }
            handle.withLockedRuntime { _ = accessibility.drainActions($0, at: now) }
            let viewport = Vec2(Float(placement.width) / scale, Float(placement.height) / scale)
            guard let result = handle.desktopRenderFrame(at: now, viewport: viewport, scale: scale, renderer: renderer) else { return -1 }
            do {
                try handle.desktopDraw(result.frame, at: now, renderer: renderer)
                guard rune_win_swap(window) != 0 else { throw DesktopWindowError("The Windows overlay swap failed") }
            } catch { handle.desktopFailure(String(describing: error)); return -2 }
            handle.desktopSubmitted(result.frame, scale: scale)
            handle.withLockedRuntime { runtime in
                accessibility.update(runtime)
                if acceptsInput { popups.pump() }
                else if runtime.hasPopup { popups.cancel() }
                let nextCursor = runtime.currentCursor()
                let dpi = UInt32((scale * 96).rounded())
                if appliedCursor != nextCursor || cursorDPI != dpi {
                    Win32Cursor.apply(nextCursor, dpi: dpi, window: window)
                    appliedCursor = nextCursor
                    cursorDPI = dpi
                }
            }
            if regions != result.regions { regions = result.regions; refreshHit() }
            if result.isAnimating { return RUNE_WIN_CONTINUE_MOTION }
            return result.nextWake.map { Int32(min(Double(Int32.max), max(1, ceil(($0 - now) * 1000)))) } ?? -1
        case RUNE_WIN_OVERLAY_DUE: tick(at: now)
        case RUNE_WIN_OVERLAY_HIT: return hit(point) ? 1 : 0
        case RUNE_WIN_OVERLAY_POINTER:
            guard acceptsInput, watch != nil, let p = observer.take() else { break }
            if options.followPointer, let target = bounds.firstIndex(where: { $0.contains(p) }), target != currentMonitor { place(on: target) }
            last = local(p)
            _ = rune_win_click_through(window, hit(last) ? 0 : 1)
            if observe(last, at: now, handle: handle) { rune_win_wake(window) }
        case RUNE_WIN_SIZE, RUNE_WIN_POSITION: refreshGeometry()
        case RUNE_WIN_SETTINGS: configure()
        case RUNE_WIN_MOVE:
            guard acceptsInput else { return 0 }
            last = point
            return observe(point, mods: mods, at: now, handle: handle) ? 1 : 0
        case RUNE_WIN_LEAVE: handle.withLockedRuntime { $0.pointerExit(at: now) }
        case RUNE_WIN_DOWN, RUNE_WIN_UP:
            guard acceptsInput else { break }
            let mapping: [PointerButton] = [.primary, .secondary, .middle, .back, .forward]
            guard Int(event.value) < mapping.count else { break }
            let button = mapping[Int(event.value)]
            last = point
            if event.kind == RUNE_WIN_DOWN {
                buttons.insert(event.value)
                handle.withLockedRuntime { $0.pointerDown(at: $0.inputPoint(fromWindow: point), button: button, mods: mods, at: now) }
            } else {
                buttons.remove(event.value)
                handle.withLockedRuntime { $0.pointerUp(at: $0.inputPoint(fromWindow: point), button: button, mods: mods, at: now) }
                _ = handle.applyInput()
            }
            refreshHit()
        case RUNE_WIN_CAPTURE_LOST:
            buttons.removeAll()
            handle.withLockedRuntime { $0.pointerReleaseLost(at: $0.inputPoint(fromWindow: last), at: now) }
            _ = handle.applyInput()
            refreshHit()
        case RUNE_WIN_WHEEL:
            guard acceptsInput else { break }
            let horizontal = event.horizontal != 0 || mods.shift
            handle.withLockedRuntime { runtime in
                let position = runtime.inputPoint(fromWindow: point)
                let step = runtime.windowsWheelLinePoints(count: event.count, ticks: event.ticks,
                    horizontal: event.horizontal != 0, shift: mods.shift, at: position)
                let delta = event.ticks * step
                runtime.desktopWheel(dx: horizontal ? delta : 0, dy: horizontal ? 0 : delta, at: position, mods: mods, now: now)
            }
        case RUNE_WIN_CLOSE: handle.hide()
        case RUNE_WIN_FOCUS:
            let focused = event.value != 0
            let changed = handle.withLockedRuntime { runtime in
                guard runtime.windowFocused != focused else { return false }
                runtime.dispatchFocus(focused, at: now)
                return true
            }
            if changed { handle.deliverFocus(focused) }
        default: break
        }
        return 0
    }

    func close() {
        guard !closed else { return }
        closed = true
        WindowsOverlayLevels.levels.removeAll { $0.window == window }
        rune_win_mouse_unwatch(watch)
        watch = nil
        handle?.withLockedRuntime { _ in popups.close() }
        accessibility.close()
        rune_win_drag_cancel(rune_win_hwnd(window))
        if rune_win_make_current(window) != 0 { renderer.close() } else { renderer.abandon() }
        rune_win_destroy(window)
        handle?.desktopClosed()
    }
}
#endif
