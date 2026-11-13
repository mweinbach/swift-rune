import Foundation
import RuneMotion

#if os(macOS) && canImport(AppKit)
import AppKit
import QuartzCore

/// Shared AppKit NSEvent -> Rune `KeyEvent` / `Mods` / `flagsChanged` mapping (`window/keys.rs`).
public enum MacOSKeyMapper {
    public static func mods(from flags: NSEvent.ModifierFlags) -> Mods {
        Mods(
            shift: flags.contains(.shift),
            ctrl: flags.contains(.control),
            alt: flags.contains(.option),
            cmd: flags.contains(.command),
            logo: flags.contains(.command)
        )
    }

    public static func mods(for event: NSEvent) -> Mods {
        mods(from: event.modifierFlags)
    }

    public static func makeKeyEvent(from event: NSEvent) -> KeyEvent? {
        let m = mods(for: event)
        let key: Key
        switch event.keyCode {
        case 36, 76: key = .enter
        case 48: key = .tab
        case 53: key = .escape
        case 51: key = .backspace
        case 117: key = .delete
        case 114: key = .insert
        case 49: key = .space
        case 123: key = .arrowLeft
        case 124: key = .arrowRight
        case 126: key = .arrowUp
        case 125: key = .arrowDown
        case 115: key = .home
        case 119: key = .end
        case 116: key = .pageUp
        case 121: key = .pageDown
        case 122: key = .f(1)
        case 120: key = .f(2)
        case 99: key = .f(3)
        case 118: key = .f(4)
        case 96: key = .f(5)
        case 97: key = .f(6)
        case 98: key = .f(7)
        case 100: key = .f(8)
        case 101: key = .f(9)
        case 109: key = .f(10)
        case 103: key = .f(11)
        case 111: key = .f(12)
        case 105: key = .f(13)
        case 107: key = .f(14)
        case 113: key = .f(15)
        case 106: key = .f(16)
        case 64: key = .f(17)
        case 79: key = .f(18)
        case 80: key = .f(19)
        case 90: key = .f(20)
        case 110: key = .contextMenu
        default:
            let chars = event.characters ?? ""
            let ign = event.charactersIgnoringModifiers ?? chars
            if m.cmd, ign.count == 1, let ch = ign.lowercased().first {
                key = .command(ch)
            } else if !chars.isEmpty {
                key = .text(chars)
            } else {
                return nil
            }
        }
        return KeyEvent(key: key, mods: m)
    }

    public static func modifierKeyEvent(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) -> (event: KeyEvent, mods: Mods)? {
        let m = mods(from: flags)
        let mapped: (ModifierKey, Bool)?
        switch keyCode {
        case 56: mapped = (.shiftLeft, flags.contains(.shift))
        case 60: mapped = (.shiftRight, flags.contains(.shift))
        case 59: mapped = (.controlLeft, flags.contains(.control))
        case 62: mapped = (.controlRight, flags.contains(.control))
        case 58: mapped = (.altLeft, flags.contains(.option))
        case 61: mapped = (.altRight, flags.contains(.option))
        case 55: mapped = (.superLeft, flags.contains(.command))
        case 54: mapped = (.superRight, flags.contains(.command))
        case 63: mapped = (.fn, flags.contains(.function))
        default: mapped = nil
        }
        guard let (modKey, pressed) = mapped else { return nil }
        return (KeyEvent(key: .modifier(modKey, pressed: pressed), mods: m), m)
    }
}

/// Converts `AppIcon` RGBA8 data to an AppKit `NSImage` and updates the macOS Dock icon (`platform/app_icon.rs`).
@MainActor
public enum MacOSDockIconApplier {
    public static func makeNSImage(from icon: AppIcon) -> NSImage? {
        let w = icon.width
        let h = icon.height
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: w * 4,
            bitsPerPixel: 32
        ), let dst = rep.bitmapData else {
            return nil
        }
        icon.rgba.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = min(raw.count, w * h * 4)
            for i in stride(from: 0, to: count, by: 4) {
                let a = UInt16(src[i + 3])
                dst[i] = UInt8((UInt16(src[i]) * a + 127) / 255)
                dst[i + 1] = UInt8((UInt16(src[i + 1]) * a + 127) / 255)
                dst[i + 2] = UInt8((UInt16(src[i + 2]) * a + 127) / 255)
                dst[i + 3] = src[i + 3]
            }
        }
        let img = NSImage(size: NSSize(width: w, height: h))
        img.addRepresentation(rep)
        return img
    }

    public static func apply(_ icon: AppIcon, to application: NSApplication = .shared) {
        if let image = makeNSImage(from: icon) {
            application.applicationIconImage = image
        }
    }
}

/// Observes macOS scroll-bar, accent color, and reduced-motion notifications (`platform/scroll_bars.rs`, `platform/accent.rs`).
@MainActor
public final class MacOSSystemObserver {
    private nonisolated(unsafe) var defaultTokens: [NSObjectProtocol] = []
    private nonisolated(unsafe) var workspaceTokens: [NSObjectProtocol] = []
    private let onChange: @MainActor () -> Void

    public init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let center = NotificationCenter.default
        let wsCenter = NSWorkspace.shared.notificationCenter

        defaultTokens.append(center.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                _ = SystemScrollBars.reread()
                self?.onChange()
            }
        })

        defaultTokens.append(center.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onChange()
            }
        })

        workspaceTokens.append(wsCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                _ = SystemScrollBars.reread()
                self?.onChange()
            }
        })
    }

    deinit {
        let center = NotificationCenter.default
        for token in defaultTokens {
            center.removeObserver(token)
        }
        let wsCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens {
            wsCenter.removeObserver(token)
        }
    }
}

/// Display-linked vsync animation driver using `NSView.displayLink` (`CADisplayLink`) with `Timer` fallback (`platform/display_link.rs`).
@MainActor
public final class MacOSDisplayLinkDriver: NSObject {
    private var displayLink: CADisplayLink?
    private var fallbackTimer: Timer?
    private let onTick: @MainActor () -> Void

    public init(onTick: @escaping @MainActor () -> Void) {
        self.onTick = onTick
        super.init()
    }

    public var isRunning: Bool {
        displayLink != nil || fallbackTimer != nil
    }

    public func start(in view: NSView) {
        guard !isRunning else { return }
        if view.window != nil {
            let link = view.displayLink(target: self, selector: #selector(handleDisplayLink(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            return
        }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.onTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    @objc private func handleDisplayLink(_ sender: CADisplayLink) {
        _ = sender
        onTick()
    }
}

/// Synchronizes global single-chord `ShortcutRegistry` entries with `MacOSGlobalHotKeyBackend`.
@MainActor
public final class MacOSHostShortcutBridge {
    private var backend: MacOSGlobalHotKeyBackend?
    private var registeredIds: [String] = []

    public init() {}

    public func sync(registry: ShortcutRegistry?) {
        clear()
        guard let registry else { return }
        let globals = registry.registeredEntries(in: .global)
        guard !globals.isEmpty else { return }
        guard let hk = try? MacOSGlobalHotKeyBackend() else { return }
        self.backend = hk
        for entry in globals where entry.sequence.chords.count == 1 {
            let chord = entry.sequence.chords[0]
            if case .success = hk.register(id: entry.id, chord: chord, handler: entry.handler) {
                registeredIds.append(entry.id)
            }
        }
    }

    public func clear() {
        if let backend {
            for id in registeredIds {
                backend.unregister(id: id)
            }
        }
        registeredIds.removeAll()
        backend = nil
    }
}

/// Shared host-view helpers for caret screen rect calculation and cursor application.
public struct MacOSUnsafeSendableBox<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}

@MainActor
public enum MacOSHostViewHelper {
    public static func caretScreenRect(caret: MotionRect?, in view: NSView) -> NSRect {
        guard let caret else { return .zero }
        let viewRect = NSRect(
            x: CGFloat(caret.x),
            y: CGFloat(caret.y),
            width: CGFloat(max(1, caret.width)),
            height: CGFloat(max(1, caret.height))
        )
        guard let window = view.window else { return viewRect }
        let winRect = view.convert(viewRect, to: nil)
        return window.convertToScreen(winRect)
    }

    public static func applyCursor(
        _ next: Cursor,
        previous: inout Cursor,
        in view: NSView
    ) {
        let isImage: Bool
        if case .image = next {
            isImage = true
        } else {
            isImage = false
        }
        if next != previous || isImage {
            if isImage, let win = view.window {
                win.disableCursorRects()
            } else if case .image = previous, let win = view.window {
                win.enableCursorRects()
                win.invalidateCursorRects(for: view)
            }
            MacOSCursorCache.shared.apply(next)
            previous = next
        }
    }

    public nonisolated static func dispatchAccessibilityAction(
        _ id: String,
        action: AccessibilityAction,
        perform: @MainActor @escaping @Sendable (String, AccessibilityAction) -> Void
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                perform(id, action)
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    perform(id, action)
                }
            }
        }
    }
}

/// Manages `NSViewToolTipOwner` tooltip regions derived from `Runtime.helpRegionsList()`
/// without repeating tooltip reconciliation across single- and multi-window host views.
public final class MacOSToolTipOwner: NSObject, NSViewToolTipOwner {
    @MainActor
    private struct Entry: Equatable {
        let rect: NSRect
        let text: String
    }

    @MainActor
    private var entries: [Entry] = []

    @MainActor
    public override init() {
        super.init()
    }

    @MainActor
    public func sync(regions: [(MotionRect, String)], on view: NSView) {
        let next = regions.map { rect, text in
            Entry(
                rect: NSRect(
                    x: CGFloat(rect.x),
                    y: CGFloat(rect.y),
                    width: CGFloat(max(0, rect.width)),
                    height: CGFloat(max(0, rect.height))
                ),
                text: text
            )
        }
        guard next != entries else { return }
        entries = next
        view.removeAllToolTips()
        for (idx, item) in next.enumerated() where item.rect.width > 0 && item.rect.height > 0 {
            view.addToolTip(item.rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: idx + 1))
        }
    }

    @objc public func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard Thread.isMainThread, let raw = data else { return "" }
        let idx = Int(bitPattern: raw) - 1
        return MainActor.assumeIsolated {
            (0..<entries.count).contains(idx) ? entries[idx].text : ""
        }
    }
}

/// Drives AppKit outer-frame spring resize & centering from `WindowFrameRequest` (`window/stepping.rs`).
@MainActor
public final class MacOSWindowFrameDriver {
    private var frameMove: WindowFrameMove?

    public init() {}

    public var isMoving: Bool {
        WindowFrameMove.isMoving(frameMove)
    }

    public func takeJumpIfMatching(viewport: Vec2) -> Bool {
        WindowFrameMove.takeJump(&frameMove, viewport: (viewport.x, viewport.y))
    }

    public static func currentTopDownFrame(of window: NSWindow) -> [Float] {
        let f = window.frame
        let primaryH = Float(NSScreen.screens.first?.frame.height ?? window.screen?.frame.height ?? f.maxY)
        return [Float(f.minX), primaryH - Float(f.maxY), Float(f.width), Float(f.height)]
    }

    public static func visibleTopDownFrame(for window: NSWindow) -> [Float] {
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let primaryH = Float(NSScreen.screens.first?.frame.height ?? vis.maxY)
        return [Float(vis.minX), primaryH - Float(vis.maxY), Float(vis.width), Float(vis.height)]
    }

    public static func cocoaFrame(fromTopDown rect: [Float], on window: NSWindow) -> NSRect {
        let primaryH = CGFloat(NSScreen.screens.first?.frame.height ?? window.screen?.frame.height ?? 0)
        return NSRect(
            x: CGFloat(rect[0]),
            y: primaryH - CGFloat(rect[1]) - CGFloat(rect[3]),
            width: CGFloat(rect[2]),
            height: CGFloat(rect[3])
        )
    }

    public func applyRequest(
        _ req: WindowFrameRequest,
        window: NSWindow,
        now: Double,
        minSize: (Float, Float),
        maxSize: (Float, Float)?,
        scale: Float,
        painting: Bool = true,
        stepViewport: (Vec2, Float) -> Void
    ) {
        let outer: (Float, Float)? = req.size.map { reqSize in
            let clamped = WindowFrame.clampSize(reqSize, min: minSize, max: maxSize)
            let frameSz = window.frameRect(
                forContentRect: NSRect(x: 0, y: 0, width: CGFloat(clamped.0), height: CGFloat(clamped.1))
            ).size
            return (Float(frameSz.width), Float(frameSz.height))
        }
        let current = Self.currentTopDownFrame(of: window)
        // Resizing again mid-flight keeps the edge the first resize keeps (`stepping.rs:165-168`).
        let base: [Float]
        if case .moving(let runningAnim, _, _) = frameMove {
            base = runningAnim.to
        } else {
            base = current
        }
        let visible = Self.visibleTopDownFrame(for: window)
        let target = WindowFrame.snap(
            WindowFrame.target(current: base, outer: outer, center: req.center, visible: visible),
            scale: scale
        )
        // Centering alone carries on with a resize already moving (`stepping.rs:172-176`).
        let activeSpring: Spring?
        if req.size == nil, case .moving(let runningAnim, _, _) = frameMove {
            activeSpring = runningAnim.spring
        } else {
            activeSpring = nil
        }
        let spring = req.spring ?? activeSpring
        if painting, let spring {
            let prev = WindowFrameMove.takeMoving(&frameMove)
            let anim = WindowFrameAnim.retarget(
                previous: prev,
                spring: spring,
                now: now,
                from: current,
                to: target
            )
            frameMove = .moving(anim, origin: (current[0], current[1]))
        } else {
            let nsRect = Self.cocoaFrame(fromTopDown: target, on: window)
            let contentSz = window.contentRect(forFrameRect: nsRect).size
            frameMove = req.size != nil ? .jumped((Float(contentSz.width), Float(contentSz.height))) : nil
            window.setFrame(nsRect, display: true)
            stepViewport(Vec2(Float(max(1, contentSz.width)), Float(max(1, contentSz.height))), scale)
        }
    }

    /// Advances an active spring resize one step; returns `true` while still moving.
    public func step(
        window: NSWindow,
        now: Double,
        scale: Float,
        resting: Bool = false,
        stepViewport: (Vec2, Float) -> Void
    ) -> Bool {
        guard case .moving(var anim, let originX, let originY) = frameMove else { return false }
        // First frame after an idle spell defers the move so the server doesn't show a stale strip (`stepping.rs:231-235`).
        if resting { return true }
        let current = Self.currentTopDownFrame(of: window)
        let dx = current[0] - originX
        let dy = current[1] - originY
        if abs(dx) > 0.5 || abs(dy) > 0.5 {
            anim.shift(dx: dx, dy: dy)
        }
        let (pos, _) = anim.sample(at: now)
        let snapped = WindowFrame.snap(pos, scale: scale)
        let nsRect = Self.cocoaFrame(fromTopDown: snapped, on: window)
        let contentSz = window.contentRect(forFrameRect: nsRect).size
        window.setFrame(nsRect, display: true)
        stepViewport(Vec2(Float(max(1, contentSz.width)), Float(max(1, contentSz.height))), scale)
        if anim.isDone(at: now) {
            frameMove = nil
            return false
        }
        frameMove = .moving(anim, origin: (snapped[0], snapped[1]))
        return true
    }

    /// Snaps a mid-flight window move to its target when painting stops (`stepping.rs:260-267`).
    public func landFrame(window: NSWindow) {
        guard let anim = WindowFrameMove.takeMoving(&frameMove) else { return }
        let nsRect = Self.cocoaFrame(fromTopDown: anim.to, on: window)
        window.setFrame(nsRect, display: true)
    }
}
#endif
