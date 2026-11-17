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

    public static func makeKeyEvent(from event: NSEvent, optionAsAlt: Bool = false) -> KeyEvent? {
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
            let rawChars = event.characters ?? ""
            let ign = event.charactersIgnoringModifiers ?? rawChars
            let chars: String
            if optionAsAlt, m.alt, !m.cmd, !ign.isEmpty {
                if !m.shift && !m.ctrl {
                    chars = ign
                } else if let applied = event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.option)), !applied.isEmpty {
                    chars = applied
                } else {
                    chars = ign
                }
            } else {
                chars = rawChars
            }
            if ign.unicodeScalars.count == 1, let s = ign.unicodeScalars.first {
                switch s.value {
                case 0xF727: key = .insert; return KeyEvent(key: key, mods: m)
                case 0xF72E, 0xF731: key = .printScreen; return KeyEvent(key: key, mods: m)
                case 0xF72F: key = .scrollLock; return KeyEvent(key: key, mods: m)
                case 0xF730, 0xF732: key = .pause; return KeyEvent(key: key, mods: m)
                default: break
                }
            }
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
    private var deadlineTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var powerObserver: NSObjectProtocol?
    private var pacer = DisplayLinkPacer()
    private var lowPowerCap = false
    private weak var lastScreen: NSScreen?
    private var rendering = false
    private(set) var isDeadlineTick = false
    private var requestedDuringFrame = false
    private let onTick: @MainActor () -> Void

    var deadlineWoke: (() -> Void)?
    private var tickRetry: DispatchWorkItem?
    private var deferredSubmission: DispatchWorkItem?
    private var cancelSubmission: (@MainActor () -> Void)?
    private var earlyTickDeadline: Double?
    private var preparation = MacOSFramePreparation()

    public init(onTick: @escaping @MainActor () -> Void) {
        self.onTick = onTick
        super.init()
    }

    public var isRunning: Bool {
        displayLink != nil || fallbackTimer != nil
    }

    var pacing: Pacing { displayLink != nil ? .paced : fallbackTimer != nil ? .unpaced : .idle }

    var refreshHz: Double { 1 / pacer.framePeriod }

    /// Claims one opportunity for all redraw sources, including input and runtime wakes.
    /// A first frame after rest can draw immediately. When a frame is already in flight
    /// AppKit may reenter the view, for instance while applying its window size.
    func beginFrame(in view: NSView, paced: Bool) -> DisplayLinkOpportunity {
        guard !rendering else {
            requestedDuringFrame = true
            return .wait
        }
        if !isRunning, let screen = view.window?.screen, lastScreen !== screen {
            updateRate(for: screen)
        }
        if fallbackTimer != nil, view.window != nil { start(in: view) }
        let now = CACurrentMediaTime()
        let deadline = earlyTickDeadline
        earlyTickDeadline = nil
        // An early tick has already passed the target checks. Claim this target once,
        // then enforce the actual submission deadline after preparing its pixels.
        let opportunity = paced ? pacer.nextFrame(now: max(now, deadline ?? now)) : .now
        guard opportunity != .wait else {
            start(in: view)
            return .wait
        }
        rendering = true
        preparation.begin(at: now, earliestSubmission: paced ? deadline : nil)
        return opportunity
    }

    /// Acquire and submit the drawable once ready. A shorter-than-predicted update
    /// leaves the main thread available to receive input until submission is permitted.
    func finishPreparation(onCancel: (@MainActor () -> Void)? = nil, _ submit: @escaping @MainActor () -> Void) {
        let now = CACurrentMediaTime()
        guard let deadline = preparation.finished(at: now) else {
            submit()
            return
        }
        cancelSubmission = onCancel
        scheduleSubmission(submit, at: deadline, now: now)
    }

    private func scheduleSubmission(_ submit: @escaping @MainActor () -> Void, at deadline: Double, now: Double) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if now < deadline {
                self.scheduleSubmission(submit, at: deadline, now: now)
                return
            }
            self.deferredSubmission = nil
            self.cancelSubmission = nil
            defer { self.endFrame() }
            submit()
        }
        deferredSubmission = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (deadline - now), execute: work)
    }

    /// A drawable has not yet been acquired. Resizing or closing may discard this prepared frame.
    func cancelPreparedFrame() {
        guard let deferredSubmission else { return }
        deferredSubmission.cancel()
        self.deferredSubmission = nil
        rendering = false
        requestedDuringFrame = false
        let cleanup = cancelSubmission
        cancelSubmission = nil
        cleanup?()
    }

    func submitted(at timestamp: CFTimeInterval = CACurrentMediaTime()) {
        pacer.presented(at: timestamp)
    }

    func endFrame() {
        guard deferredSubmission == nil else { return }
        rendering = false
        if requestedDuringFrame {
            requestedDuringFrame = false
            DispatchQueue.main.async { [weak self] in self?.onTick() }
        }
    }

    public func start(in view: NSView) {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        if let fallbackTimer, view.window != nil {
            // An animated app can request its first frame before AppKit attaches its host view.
            fallbackTimer.invalidate()
            self.fallbackTimer = nil
        }
        guard !isRunning else { return }
        pacer.start()
        if let window = view.window {
            let link = view.displayLink(target: self, selector: #selector(handleDisplayLink(_:)))
            displayLink = link
            configure(link: link, screen: window.screen)
            let center = NotificationCenter.default
            screenObserver = center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window,
                                                queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated { self?.screenChanged(window) }
            }
            powerObserver = center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                               queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated { self?.screenChanged(window) }
            }
            link.add(to: .main, forMode: .common)
            return
        }
        let interval = pacer.framePeriod
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deadlineWoke?()
                self.pacer.enqueueTick(target: CACurrentMediaTime() + interval)
                self.onTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func screenChanged(_ window: NSWindow?) {
        tickRetry?.cancel()
        tickRetry = nil
        cancelPreparedFrame()
        if let displayLink { configure(link: displayLink, screen: window?.screen) }
    }

    @discardableResult
    private func updateRate(for screen: NSScreen?) -> Float {
        lastScreen = screen
        let display = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        lowPowerCap = display.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } == true &&
            ProcessInfo.processInfo.isLowPowerModeEnabled
        let advertised = screen?.maximumFramesPerSecond ?? 0
        let nativeRate = advertised > 0 ? advertised : 60
        let rate = Float(lowPowerCap ? min(60, nativeRate) : nativeRate)
        pacer.framePeriod = 1 / Double(rate)
        return rate
    }

    private func configure(link: CADisplayLink, screen: NSScreen?) {
        let rate = updateRate(for: screen)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
    }

    public func stop() {
        cancelPreparedFrame()
        tickRetry?.cancel()
        tickRetry = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        screenObserver = nil
        powerObserver = nil
        displayLink?.invalidate()
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        pacer.stop()
    }

    /// Sleeps between discrete frames on a host clock measured in `timeScale` seconds per real second.
    func sleep(until deadline: Double?, now: Double, timeScale: Double) {
        stop()
        guard let deadline, deadline.isFinite, timeScale > 0 else { return }
        let delay = max(0, (deadline - now) / timeScale)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deadlineTimer = nil
                self.isDeadlineTick = true
                defer { self.isDeadlineTick = false }
                self.deadlineWoke?()
                self.onTick()
            }
        }
        deadlineTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handleDisplayLink(_ sender: CADisplayLink) {
        guard sender === displayLink else { return }
        let period = sender.targetTimestamp - sender.timestamp
        if period.isFinite && period > 0 {
            pacer.framePeriod = lowPowerCap ? max(period, 1.0 / 60) : period
        }
        tickRetry?.cancel()
        tickRetry = nil
        let target = sender.targetTimestamp
        let now = CACurrentMediaTime()
        if let retryAt = Self.retryTime(for: target, lastPresent: pacer.lastPresent, lastTarget: pacer.lastTarget,
                                        now: now, period: pacer.framePeriod) {
            if preparation.canStart(at: now, submissionAfter: retryAt) {
                earlyTickDeadline = retryAt
                defer { earlyTickDeadline = nil }
                pacer.enqueueTick(target: target)
                onTick()
                return
            }
            // A frame can finish inside its budget yet submit too recently for this callback.
            // The same target is still usable once the minimum spacing has elapsed.
            let retry = DispatchWorkItem { [weak self, weak sender] in
                guard let self, let sender, self.displayLink === sender else { return }
                self.tickRetry = nil
                self.pacer.enqueueTick(target: target)
                self.onTick()
            }
            tickRetry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + (retryAt - now), execute: retry)
            return
        }
        pacer.enqueueTick(target: target)
        onTick()
    }

    static func retryTime(for target: Double, lastPresent: Double?, lastTarget: Double?,
                          now: Double, period: Double) -> Double? {
        guard let lastPresent else { return nil }
        let earliest = (lastPresent + period / 2).nextUp
        guard earliest > now, DisplayLinkPacer.permits(lastPresent: lastPresent, lastTarget: lastTarget,
            target: target, now: earliest, period: period) else { return nil }
        return earliest
    }
}

/// Preparation may run ahead of the submit guard when recent work is expected to fill
/// the interval. Finishing early still observes the original minimum spacing.
struct MacOSFramePreparation {
    private var began = 0.0
    private var lastDuration = 0.0
    private var earliestSubmission: Double?

    func canStart(at now: Double, submissionAfter deadline: Double) -> Bool {
        now + lastDuration >= deadline
    }

    mutating func begin(at time: Double, earliestSubmission: Double?) {
        began = time
        self.earliestSubmission = earliestSubmission
    }

    mutating func finished(at time: Double) -> Double? {
        lastDuration = max(0, time - began)
        guard let earliestSubmission, time < earliestSubmission else { return nil }
        return earliestSubmission
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

    /// AppKit makes this superclass query on its own AX thread (#1040). Swift imports
    /// NSView's children as MainActor-isolated, so call that specific ObjC getter directly
    /// without entering a Rune override or synchronously dispatching to a busy main thread.
    nonisolated static func superclassAccessibilityChildren(of view: NSView) -> [Any]? {
        let selector = #selector(NSAccessibilityElement.accessibilityChildren)
        guard let method = class_getInstanceMethod(NSView.self, selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<NSArray>?
        let get = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return get(view, selector)?.takeUnretainedValue() as? [Any]
    }

    nonisolated static func dispatchAccessibilityRequest(_ perform: @MainActor @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { perform() }
        } else {
            DispatchQueue.main.async { perform() }
        }
    }

    /// Runs an assistive `SetValue` request on the main actor, as `dispatchAccessibilityAction` does.
    public nonisolated static func dispatchAccessibilitySetValue(
        _ id: String,
        value: AccessibilityActionValue,
        perform: @MainActor @escaping @Sendable (String, AccessibilityActionValue) -> Void
    ) {
        dispatchAccessibilityRequest { perform(id, value) }
    }

    public nonisolated static func dispatchAccessibilityAction(
        _ id: String,
        action: AccessibilityAction,
        perform: @MainActor @escaping @Sendable (String, AccessibilityAction) -> Void
    ) {
        dispatchAccessibilityRequest { perform(id, action) }
    }
}

/// Manages `NSViewToolTipOwner` tooltip regions derived from `Runtime.helpRegionsList()`
/// snapping to device pixels and diffing incrementally (`platform/macos/help.rs`).
public final class MacOSToolTipOwner: NSObject, NSViewToolTipOwner {
    @MainActor
    private struct Region {
        let rect: [Float]
        let text: String
        let tag: NSView.ToolTipTag
        let token: Int
    }

    @MainActor
    private var regions: [Region] = []
    @MainActor
    private var nextToken: Int = 1

    @MainActor
    public override init() {
        super.init()
    }

    /// Snaps `rect` (`[x0, y0, x1, y1]`) to the device pixel grid at `scale` (`help.rs::snap`).
    public static func snap(_ rect: [Float], scale: Float) -> [Float] {
        let s = max(1.0, scale)
        return rect.map { ($0 * s).rounded() / s }
    }

    /// Computes which existing `have` tooltip entries stay and which `want` entries are already covered (`help.rs::diff`).
    public static func diff(
        have: [([Float], String)],
        want: [([Float], String)]
    ) -> (stays: [Bool], covered: [Bool]) {
        var covered = [Bool](repeating: false, count: want.count)
        let stays: [Bool] = have.map { h in
            if let k = want.indices.first(where: { !covered[$0] && want[$0].0 == h.0 && want[$0].1 == h.1 }) {
                covered[k] = true
                return true
            }
            return false
        }
        return (stays, covered)
    }

    @MainActor
    public func sync(regions newRegions: [(MotionRect, String)], on view: NSView, scale: Float? = nil) {
        let effectiveScale = max(
            1.0,
            scale ?? Float(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        )
        let want: [([Float], String)] = newRegions.compactMap { rect, text in
            let snapped = Self.snap([rect.x, rect.y, rect.x + rect.width, rect.y + rect.height], scale: effectiveScale)
            guard snapped[2] > snapped[0], snapped[3] > snapped[1] else { return nil }
            return (snapped, text)
        }
        let have: [([Float], String)] = regions.map { ($0.rect, $0.text) }
        let (stays, covered) = Self.diff(have: have, want: want)
        if stays.allSatisfy({ $0 }) && covered.allSatisfy({ $0 }) {
            return
        }

        var kept: [Region] = []
        for (idx, region) in regions.enumerated() {
            if stays[idx] {
                kept.append(region)
            } else {
                view.removeToolTip(region.tag)
            }
        }
        regions = kept

        for (idx, item) in want.enumerated() where !covered[idx] {
            let r = item.0
            let nsRect = NSRect(
                x: CGFloat(r[0]),
                y: CGFloat(r[1]),
                width: CGFloat(r[2] - r[0]),
                height: CGFloat(r[3] - r[1])
            )
            let token = nextToken
            nextToken &+= 1
            let tag = view.addToolTip(nsRect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: token))
            regions.append(Region(rect: r, text: item.1, tag: tag, token: token))
        }
    }

    @objc public func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard Thread.isMainThread, let raw = data else { return "" }
        let token = Int(bitPattern: raw)
        return MainActor.assumeIsolated {
            regions.first { $0.token == token }?.text ?? ""
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

    /// AppKit's live resize takes over at the window's current size.
    func userStartedResizing() {
        _ = WindowFrameMove.takeMoving(&frameMove)
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

/// A new window can fill two drawable slots before WindowServer shows it.
@MainActor
struct MacOSLaunchDrawables {
    private var steadyCount: Int?
    private var firstVisibleSubmit: CFTimeInterval?

    mutating func cap(_ layer: CAMetalLayer) {
        if layer.maximumDrawableCount > 2 {
            steadyCount = layer.maximumDrawableCount
            layer.maximumDrawableCount = 2
        }
    }

    mutating func submitted(to layer: CAMetalLayer, visible: Bool, idle: Bool, at now: CFTimeInterval) {
        guard visible, let steadyCount else { return }
        let first = firstVisibleSubmit ?? now
        firstVisibleSubmit = first
        guard idle || now - first >= 1 else { return }
        layer.maximumDrawableCount = steadyCount
        self.steadyCount = nil
    }
}

/// Pins a `CAMetalLayer`'s contents gravity and sRGB color space (`platform/macos/surface.rs`).
public enum MacOSMetalLayerSurface {
    @MainActor
    public static func pinContentsTopLeft(_ layer: CAMetalLayer) {
        let flipped = layer.superlayer?.isGeometryFlipped ?? false
        layer.contentsGravity = flipped ? .bottomLeft : .topLeft
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            layer.colorspace = srgb
        }
    }
}

/// AppleEvent descriptor helpers for incoming macOS get-URL events (`open_url/incoming_tests.rs`).
public enum MacOSAppleEventHelper {
    public static func url(from descriptor: NSAppleEventDescriptor) -> String? {
        descriptor.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue
    }
}
#endif
