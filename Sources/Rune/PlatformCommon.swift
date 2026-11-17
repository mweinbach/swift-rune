import Foundation
import RuneMotion
import RuneRef

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(WinSDK)
import WinSDK
#elseif canImport(WASILibc)
import WASILibc
#endif

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Unified Cross-Platform RuneApp Entry Point

/// Reports invalid CLI arguments with status 2 and other native startup failures with status 1.
public enum RuneStartup {
    @discardableResult
    internal static func handleResult(
        _ result: Result<Void, any Error>,
        writeStderr: (String) -> Void = { message in
            if let data = "\(message)\n".data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        },
        exitProcess: (Int32) -> Void = { code in
            #if os(WASI)
            fatalError("startup failed with exit code \(code)")
            #elseif canImport(WinSDK)
            WinSDK.ExitProcess(UInt32(code))
            #else
            exit(code)
            #endif
        }
    ) -> Bool {
        if case .failure(let error) = result {
            #if os(WASI)
            fatalError("\(error)")
            #else
            if case let ToolingError.invalidArgument(message) = error {
                writeStderr(message)
                exitProcess(2)
            } else {
                writeStderr("\(error)")
                exitProcess(1)
            }
            return false
            #endif
        }
        return true
    }

    public static func started(_ result: Result<Void, any Error>) {
        handleResult(result)
    }

    public static func started(_ body: () throws -> Void) {
        handleResult(Result { try body() })
    }
}

/// Cross-platform entry point for running a `Rune` application (`RuneApp.run(spec)`).
///
/// Checks CLI headless flags (`--snap`, `--tree`, `--script`, `--frames`, `--strip`) first on
/// every platform, then launches the native platform host (`MacOSApp`, `IOSApp`, `Win32App`,
/// `LinuxApp`, `AndroidApp`, or `WebApp`).
public enum RuneApp {
    @MainActor
    public static func run<State>(_ spec: AppSpec<State>, arguments: [String]? = nil) throws {
        let parsed = arguments.map { ToolingArgs.parse($0) } ?? ToolingArgs.parse()
        if parsed.isHeadlessRequested {
            _ = try HeadlessRunner.run(spec, args: parsed)
            return
        }
        try GpuBackendPolicy.checkWindowBackend()
        #if os(Windows) || os(Linux)
        MediaPlaybackGate.enable()
        #endif

        ReadySignal.runStarts()
        defer { ReadySignal.clear() }

        #if os(macOS)
        try MacOSApp.run(spec, parsed: parsed)
        #elseif canImport(UIKit) && !os(watchOS)
        try IOSApp.run(spec, parsed: parsed)
        #elseif os(Windows)
        try Win32App.run(spec, parsed: parsed)
        #elseif os(Linux)
        try LinuxApp.run(spec, parsed: parsed)
        #elseif os(Android)
        try AndroidApp.run(spec, parsed: parsed)
        #elseif os(WASI)
        try WebApp.run(spec, parsed: parsed)
        #else
        _ = try HeadlessRunner.run(spec, args: parsed)
        #endif
    }

    @MainActor
    public static func run<State>(_ app: App<State>, arguments: [String]? = nil) throws {
        let effectiveArgs = arguments ?? app.runOptions.arguments
        let parsed = effectiveArgs.map { ToolingArgs.parse($0) } ?? ToolingArgs.parse()
        if parsed.isHeadlessRequested {
            _ = try HeadlessRunner.run(app, args: parsed)
            return
        }
        try GpuBackendPolicy.checkWindowBackend(app.gpuBackendPreference)
        #if os(Windows) || os(Linux)
        MediaPlaybackGate.enable()
        #endif
        if !app.childWindows.isEmpty {
            var rootApp = app
            rootApp.childWindows = []
            var rootSpec = AppWindowSpec.fromApp("main", rootApp)
            rootSpec.childWindows = app.childWindows
            try RuneMultiWindow.runWindows([rootSpec.boxed()], options: app.runOptions, arguments: effectiveArgs)
            return
        }

        ReadySignal.runStarts()
        defer { ReadySignal.clear() }

        #if os(macOS)
        try MacOSApp.run(app, parsed: parsed)
        #elseif canImport(UIKit) && !os(watchOS)
        try IOSApp.run(app, parsed: parsed)
        #elseif os(Windows)
        try Win32App.run(app, parsed: parsed)
        #elseif os(Linux)
        try LinuxApp.run(app, parsed: parsed)
        #elseif os(Android)
        try AndroidApp.run(app, parsed: parsed)
        #elseif os(WASI)
        try WebApp.run(app, parsed: parsed)
        #else
        _ = try HeadlessRunner.run(app, args: parsed)
        #endif
    }

    /// Runs `spec` and reports failures through `RuneStartup`.
    @MainActor
    public static func runOrExit<State>(_ spec: AppSpec<State>, arguments: [String]? = nil) {
        RuneStartup.started {
            try run(spec, arguments: arguments)
        }
    }

    /// Runs `app` and reports failures through `RuneStartup`.
    @MainActor
    public static func runOrExit<State>(_ app: App<State>, arguments: [String]? = nil) {
        RuneStartup.started {
            try run(app, arguments: arguments)
        }
    }
}

// MARK: - 1. SystemAccent (platform/accent.rs)

/// The user's accent colour and keyboard focus ring colour, each for a light and a dark
/// appearance (`rune::platform::SystemAccent`).
public struct SystemAccent: Sendable, Equatable {
    public let lightAccent: Color
    public let darkAccent: Color
    public let lightFocus: Color
    public let darkFocus: Color

    /// macOS's default blue (`#007AFF` light, `#0A84FF` dark) and its focus ring at 50%.
    public static let `default` = SystemAccent(
        lightAccent: Color(r: 0.0, g: 0.194618, b: 1.0, a: 1.0),
        darkAccent: Color(r: 0.003035, g: 0.23074, b: 1.0, a: 1.0)
    )

    public init(lightAccent: Color, darkAccent: Color) {
        self.lightAccent = lightAccent
        self.darkAccent = darkAccent
        self.lightFocus = Color(r: lightAccent.r, g: lightAccent.g, b: lightAccent.b, a: lightAccent.a * 0.5)
        self.darkFocus = Color(r: darkAccent.r, g: darkAccent.g, b: darkAccent.b, a: darkAccent.a * 0.5)
    }

    public init(lightAccent: Color, darkAccent: Color, lightFocus: Color, darkFocus: Color) {
        self.lightAccent = lightAccent
        self.darkAccent = darkAccent
        self.lightFocus = lightFocus
        self.darkFocus = darkFocus
    }

    public func withFocus(light: Color, dark: Color) -> SystemAccent {
        SystemAccent(lightAccent: lightAccent, darkAccent: darkAccent, lightFocus: light, darkFocus: dark)
    }

    public func accent(dark: Bool) -> Color {
        dark ? darkAccent : lightAccent
    }

    public func focus(dark: Bool) -> Color {
        dark ? darkFocus : lightFocus
    }

    /// Reads the current OS accent colour when available, else returns `.default`.
    public static func systemAccent() -> SystemAccent {
        #if os(macOS)
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                readMacOSAccent() ?? .default
            }
        }
        return .default
        #elseif os(Windows)
        return WindowsPreferences.read().accent
        #else
        return .default
        #endif
    }

    #if os(macOS)
    @MainActor
    private static func readMacOSAccent() -> SystemAccent? {
        func resolve(_ color: NSColor, dark: Bool) -> Color? {
            let name: NSAppearance.Name = dark ? .darkAqua : .aqua
            guard let app = NSAppearance(named: name) else { return nil }
            var out: Color?
            app.performAsCurrentDrawingAppearance {
                if let rgb = color.usingColorSpace(.sRGB) {
                    out = Color.srgb(
                        Float(rgb.redComponent),
                        Float(rgb.greenComponent),
                        Float(rgb.blueComponent),
                        Float(rgb.alphaComponent)
                    )
                }
            }
            return out
        }
        guard let light = resolve(.controlAccentColor, dark: false),
              let dark = resolve(.controlAccentColor, dark: true) else {
            return nil
        }
        let base = SystemAccent(lightAccent: light, darkAccent: dark)
        if let fLight = resolve(.keyboardFocusIndicatorColor, dark: false),
           let fDark = resolve(.keyboardFocusIndicatorColor, dark: true) {
            return base.withFocus(light: fLight, dark: fDark)
        }
        return base
    }
    #endif
}

// MARK: - 2. Activation (platform/activation.rs)

/// Forwarded XDG/desktop activation token for focusing an already-mapped window.
public struct ActivationToken: Sendable, Hashable, Codable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }
}

public protocol WindowActivator: Sendable {
    func activate(token: ActivationToken) -> Bool
}

public final class NoopWindowActivator: WindowActivator, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var receivedTokens: [ActivationToken] = []

    public init() {}

    public func activate(token: ActivationToken) -> Bool {
        lock.lock()
        receivedTokens.append(token)
        lock.unlock()
        return true
    }
}

// MARK: - 3. AppIcon (platform/app_icon.rs)

/// Validated RGBA8 application icon image (`rune::platform::app_icon`).
public struct AppIcon: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgba: Data

    public init?(width: Int, height: Int, rgba: Data) {
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        guard rgba.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

// MARK: - 4. DisplayLink & FramePacer (platform/display_link.rs)

/// Cross-platform frame pacing configuration and tick state (`rune::platform::display_link`).
public struct FramePacer: Sendable, Equatable {
    public var targetFPS: Double
    public private(set) var lastFrameTimestamp: Double?
    public private(set) var frameCount: UInt64 = 0

    public init(targetFPS: Double = 60.0) {
        self.targetFPS = max(1.0, targetFPS)
    }

    public var frameInterval: Double {
        1.0 / targetFPS
    }

    public mutating func step(at timestamp: Double) -> Double {
        let dt: Double
        if let prev = lastFrameTimestamp {
            dt = max(0.0, min(0.25, timestamp - prev))
        } else {
            dt = frameInterval
        }
        lastFrameTimestamp = timestamp
        frameCount &+= 1
        return dt
    }
}

/// When a display-link-paced surface's next frame draws (`platform/display_link.rs::Opportunity`).
public enum DisplayLinkOpportunity: Sendable, Equatable {
    /// On this tick, which presents at its target timestamp (seconds).
    case tick(Double)
    /// At once, aimed at no tick (`rested`).
    case now
    /// On a later tick.
    case wait

    /// The frame's target presentation time if it draws now (`some(nil)` when aimed at no tick),
    /// or `nil` when it waits (`Opportunity::target`).
    public var target: Double?? {
        switch self {
        case .tick(let target): return .some(.some(target))
        case .now: return .some(.none)
        case .wait: return nil
        }
    }
}

/// Deterministic display-link pacing state machine (`platform/display_link.rs`).
public struct DisplayLinkPacer: Sendable, Equatable {
    public private(set) var running: Bool
    public var framePeriod: Double
    public private(set) var lastPresent: Double?
    public private(set) var lastTarget: Double?
    private var pendingTickTarget: Double?

    public init(framePeriod: Double = 1.0 / 60.0, running: Bool = false) {
        self.framePeriod = max(1e-6, framePeriod)
        self.running = running
    }

    public mutating func start() {
        running = true
    }

    public mutating func stop() {
        running = false
        pendingTickTarget = nil
    }

    public mutating func enqueueTick(target: Double) {
        pendingTickTarget = target
    }

    public mutating func presented(at timestamp: Double) {
        lastPresent = timestamp
    }

    public func tickAfter(_ now: Double) -> Double {
        now + framePeriod
    }

    public func defersStart(at now: Double) -> Bool {
        Self.defersStart(
            running: running,
            lastPresent: lastPresent,
            lastTarget: lastTarget,
            now: now,
            period: framePeriod
        )
    }

    public mutating func nextFrame(now: Double) -> DisplayLinkOpportunity {
        start()
        let tick = pendingTickTarget
        pendingTickTarget = nil
        let next = Self.opportunity(
            tick: tick,
            lastPresent: lastPresent,
            lastTarget: lastTarget,
            now: now,
            period: framePeriod
        )
        switch next {
        case .tick(let target):
            lastTarget = target
        case .now:
            lastTarget = now
        case .wait:
            break
        }
        return next
    }

    public static func opportunity(
        tick: Double?,
        lastPresent: Double?,
        lastTarget: Double?,
        now: Double,
        period: Double
    ) -> DisplayLinkOpportunity {
        if let target = tick,
           permits(lastPresent: lastPresent, lastTarget: lastTarget, target: target, now: now, period: period) {
            return .tick(target)
        }
        if rested(lastPresent: lastPresent, lastTarget: lastTarget, now: now, period: period) {
            return .now
        }
        return .wait
    }

    public static func permits(
        lastPresent: Double?,
        lastTarget: Double?,
        target: Double,
        now: Double,
        period: Double
    ) -> Bool {
        let half = period * 0.5
        let eps = 1e-12
        let ahead = now < target
        let targetSpacingOK = lastTarget.map { target + eps >= $0 + period * 0.75 } ?? true
        let submitSpacingOK = lastPresent.map { max(0.0, now - $0) + eps >= half } ?? true
        return ahead && targetSpacingOK && submitSpacingOK
    }

    public static func rested(
        lastPresent: Double?,
        lastTarget: Double?,
        now: Double,
        period: Double
    ) -> Bool {
        let eps = 1e-12
        let targetPassed = lastTarget.map { $0 <= now + eps } ?? true
        let presentRested = lastPresent.map { max(0.0, now - $0) + eps >= period * 1.5 } ?? true
        return targetPassed && presentRested
    }

    public static func defersStart(
        running: Bool,
        lastPresent: Double?,
        lastTarget: Double?,
        now: Double,
        period: Double
    ) -> Bool {
        !running && rested(lastPresent: lastPresent, lastTarget: lastTarget, now: now, period: period)
    }
}

// MARK: - 5. Embed (platform/embed.rs)

/// Configuration for embedding a Rune surface inside a host container view.
public struct EmbedHostConfig: Sendable, Equatable {
    public var transparentBackground: Bool
    public var forwardScrollEvents: Bool
    public var initialSize: Vec2

    public init(
        transparentBackground: Bool = false,
        forwardScrollEvents: Bool = true,
        initialSize: Vec2 = Vec2(640, 480)
    ) {
        self.transparentBackground = transparentBackground
        self.forwardScrollEvents = forwardScrollEvents
        self.initialSize = initialSize
    }
}

// MARK: - 6. IME State & Candidate Window (platform/ime.rs & ime/windows.rs)

/// Clause within an active IME composition string (`rune::edit::Clause`).
public struct ImeClause: Sendable, Equatable, Codable {
    public var utf8Range: Range<Int>
    public var isTarget: Bool

    public init(utf8Range: Range<Int>, isTarget: Bool = false) {
        self.utf8Range = utf8Range
        self.isTarget = isTarget
    }
}

/// Focused field text published to the platform IME for reconversion (`rune::edit::ImeText`).
public struct ImeText: Sendable, Equatable {
    public var startUTF8: Int
    public var text: String
    public var selectionUTF8: Range<Int>

    public init(startUTF8: Int = 0, text: String, selectionUTF8: Range<Int>) {
        self.startUTF8 = startUTF8
        self.text = text
        self.selectionUTF8 = selectionUTF8
    }
}

/// Active IME preedit composition state (`rune::platform::ime::ImePreedit`).
public struct ImePreedit: Sendable, Equatable {
    public var text: String
    public var cursorUTF8: Range<Int>?
    public var clauses: [ImeClause]

    public init(text: String, cursorUTF8: Range<Int>? = nil, clauses: [ImeClause] = []) {
        self.text = text
        self.cursorUTF8 = cursorUTF8
        self.clauses = clauses
    }
}

/// Screen-space anchor rectangle for the OS IME candidate window (`rune::platform::ime`).
public struct ImeCandidateWindow: Sendable, Equatable {
    public var caretRect: MotionRect
    public var isVisible: Bool

    public init(caretRect: MotionRect = .zero, isVisible: Bool = false) {
        self.caretRect = caretRect
        self.isVisible = isVisible
    }
}

/// Cross-platform input method state machine tracking composition, reconversion, and cancellation.
public struct InputMethodState: Sendable, Equatable {
    public private(set) var isEnabled: Bool = false
    public private(set) var preedit: ImePreedit?
    public private(set) var candidateWindow: ImeCandidateWindow = ImeCandidateWindow()
    public private(set) var publishedText: ImeText?

    public init() {}

    public mutating func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            cancelComposition()
        }
    }

    public mutating func updatePreedit(_ preedit: ImePreedit?) {
        self.preedit = preedit
        self.candidateWindow.isVisible = isEnabled && (preedit != nil)
    }

    public mutating func commit(_ committed: String) -> String {
        preedit = nil
        candidateWindow.isVisible = false
        return committed
    }

    public mutating func cancelComposition() {
        preedit = nil
        candidateWindow.isVisible = false
    }

    public mutating func updateCandidateRect(_ rect: MotionRect) {
        candidateWindow.caretRect = rect
    }

    public mutating func syncSurroundingText(_ text: ImeText?) {
        publishedText = text
    }
}

// MARK: - 7. MainQueueDispatcher (platform/main_queue.rs)

/// Thread-safe queue of closures drained on the platform UI thread (`rune::platform::main_queue`).
public final class MainQueueDispatcher: @unchecked Sendable {
    public static let shared = MainQueueDispatcher()

    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []

    public init() {}

    public func enqueue(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        pending.append(work)
        lock.unlock()
        #if os(WASI)
        WASIEventLoop.wake(after: 0)
        #endif
    }

    public func drain() -> Int {
        lock.lock()
        let items = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        for item in items {
            item()
        }
        return items.count
    }

    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }
}

// MARK: - 8. SystemPreferences & ScrollBars (platform/preferences.rs & scroll_bars.rs)

/// System high-contrast / forced-colors palette (`rune::platform::SystemContrast`).
public struct SystemContrast: Sendable, Equatable {
    public var window: Color
    public var text: Color
    public var highlight: Color
    public var highlightText: Color
    public var disabled: Color
    public var button: Color
    public var buttonText: Color
    public var link: Color

    public init(
        window: Color,
        text: Color,
        highlight: Color,
        highlightText: Color,
        disabled: Color,
        button: Color,
        buttonText: Color,
        link: Color
    ) {
        self.window = window
        self.text = text
        self.highlight = highlight
        self.highlightText = highlightText
        self.disabled = disabled
        self.button = button
        self.buttonText = buttonText
        self.link = link
    }

    /// `RUNE_CONTRAST=aquatic|desert|dusk|night-sky`: Windows 11 high-contrast preset colours (#816).
    public static func preset(named name: String) -> SystemContrast? {
        let hexes: [String]
        switch name.lowercased() {
        case "aquatic":
            hexes = ["#202020", "#ffffff", "#8ee3f0", "#263b50", "#a6a6a6", "#75e9fc"]
        case "desert":
            hexes = ["#fffaef", "#3d3d3d", "#903909", "#fff5e3", "#6d6d6d", "#1c5e75"]
        case "dusk":
            hexes = ["#2d3236", "#ffffff", "#a1bfde", "#212d3b", "#a6a6a6", "#70ebde"]
        case "night-sky", "nightsky":
            hexes = ["#000000", "#ffffff", "#d6b4fd", "#2b2b2b", "#a6a6a6", "#8080ff"]
        default:
            return nil
        }
        let c = hexes.map { Color.hex($0) ?? .black }
        return SystemContrast(
            window: c[0],
            text: c[1],
            highlight: c[2],
            highlightText: c[3],
            disabled: c[4],
            button: c[0],
            buttonText: c[1],
            link: c[5]
        )
    }

    /// Reads `RUNE_CONTRAST` from the environment if set and valid.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> SystemContrast? {
        guard let name = env["RUNE_CONTRAST"] else { return nil }
        return preset(named: name)
    }
}

/// Platform scroll bar visibility preference (`rune::platform::scroll_bars`).
public enum ScrollBarStyle: String, Sendable, Equatable, Codable {
    case overlay
    case alwaysVisible
}

/// User's "Show scroll bars" preference (`rune::platform::scroll_bars::ScrollBars`).
public enum ScrollBars: String, Sendable, Equatable, Hashable, Codable {
    case automatic
    case whenScrolling
    case always

    public func isOverlay(scrollerOverlay: Bool) -> Bool {
        #if os(iOS) || os(tvOS) || os(visionOS)
        return true
        #else
        switch self {
        case .automatic:
            return scrollerOverlay
        case .whenScrolling:
            return true
        case .always:
            return false
        }
        #endif
    }

    public static func parseAppleShowScrollBars(_ raw: String?) -> ScrollBars {
        switch raw {
        case "Always": return .always
        case "WhenScrolling": return .whenScrolling
        default: return .automatic
        }
    }
}

/// Resolved scroll-bar settings (`rune::platform::scroll_bars::SystemScrollBars`).
public struct SystemScrollBars: Sendable, Equatable, Hashable {
    public var bars: ScrollBars
    public var scrollerOverlay: Bool
    public var jumpToClick: Bool

    public static let `default` = SystemScrollBars(bars: .whenScrolling, scrollerOverlay: true, jumpToClick: false)

    public init(bars: ScrollBars = .whenScrolling, scrollerOverlay: Bool = true, jumpToClick: Bool = false) {
        self.bars = bars
        self.scrollerOverlay = scrollerOverlay
        self.jumpToClick = jumpToClick
    }

    public var isOverlay: Bool {
        bars.isOverlay(scrollerOverlay: scrollerOverlay)
    }

    public func withOverride(_ bars: ScrollBars?) -> SystemScrollBars {
        guard let bars else { return self }
        var copy = self
        copy.bars = bars
        return copy
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: SystemScrollBars?

    public static func current() -> SystemScrollBars {
        #if os(macOS)
        lock.lock()
        defer { lock.unlock() }
        if let existing = cached {
            return existing
        }
        if Thread.isMainThread {
            let read = MainActor.assumeIsolated { readMacOS() }
            cached = read
            return read
        }
        return .default
        #elseif os(Windows)
        return WindowsPreferences.scrollBars()
        #else
        return .default
        #endif
    }

    public static func reread() -> SystemScrollBars {
        #if os(macOS)
        lock.lock()
        defer { lock.unlock() }
        if Thread.isMainThread {
            let read = MainActor.assumeIsolated { readMacOS() }
            cached = read
            return read
        }
        return cached ?? .default
        #elseif os(Windows)
        return WindowsPreferences.scrollBars()
        #else
        return .default
        #endif
    }

    #if os(macOS)
    @MainActor
    private static func readMacOS() -> SystemScrollBars {
        let defaults = UserDefaults.standard
        let pref = defaults.string(forKey: "AppleShowScrollBars")
        let scrollerOverlay = (NSScroller.preferredScrollerStyle == .overlay)
        let jumpToClick = defaults.bool(forKey: "AppleScrollerPagingBehavior")
        return SystemScrollBars(
            bars: ScrollBars.parseAppleShowScrollBars(pref),
            scrollerOverlay: scrollerOverlay,
            jumpToClick: jumpToClick
        )
    }
    #endif
}

/// Aggregated OS accessibility & appearance preferences (`rune::platform::preferences`).
public struct SystemPreferences: Sendable, Equatable {
    public var darkMode: Bool?
    public var reducedMotion: Bool
    public var fullKeyboardAccess: Bool
    public var contrast: SystemContrast?
    public var accent: SystemAccent
    public var doubleClickInterval: Double
    public var scrollBarStyle: ScrollBarStyle

    public init(
        darkMode: Bool? = nil,
        reducedMotion: Bool = false,
        fullKeyboardAccess: Bool = true,
        contrast: SystemContrast? = nil,
        accent: SystemAccent = .default,
        doubleClickInterval: Double = 0.5,
        scrollBarStyle: ScrollBarStyle = .overlay
    ) {
        self.darkMode = darkMode
        self.reducedMotion = reducedMotion
        self.fullKeyboardAccess = fullKeyboardAccess
        self.contrast = contrast
        self.accent = accent
        self.doubleClickInterval = doubleClickInterval
        self.scrollBarStyle = scrollBarStyle
    }

    public static func current() -> SystemPreferences {
        let envContrast = SystemContrast.fromEnvironment()
        #if os(macOS)
        let rm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fka: Bool
        if Thread.isMainThread {
            fka = MainActor.assumeIsolated { NSApplication.shared.isFullKeyboardAccessEnabled }
        } else {
            fka = true
        }
        let dci = NSEvent.doubleClickInterval
        let sb = SystemScrollBars.current()
        let sbStyle: ScrollBarStyle = sb.isOverlay ? .overlay : .alwaysVisible
        return SystemPreferences(
            darkMode: nil,
            reducedMotion: rm,
            fullKeyboardAccess: fka,
            contrast: envContrast,
            accent: SystemAccent.systemAccent(),
            doubleClickInterval: dci,
            scrollBarStyle: sbStyle
        )
        #elseif canImport(UIKit) && !os(watchOS)
        let rm: Bool
        if Thread.isMainThread {
            rm = MainActor.assumeIsolated { UIAccessibility.isReduceMotionEnabled }
        } else {
            rm = false
        }
        return SystemPreferences(
            darkMode: nil,
            reducedMotion: rm,
            fullKeyboardAccess: true,
            contrast: envContrast,
            accent: .default,
            doubleClickInterval: 0.4,
            scrollBarStyle: .overlay
        )
        #elseif os(Windows)
        return WindowsPreferences.read(contrast: envContrast)
        #else
        return SystemPreferences(contrast: envContrast)
        #endif
    }
}

// MARK: - 9. ReadySignal (platform/ready_signal.rs)

/// Writes `$RUNE_READY_DIR/<bundle_id>.<pid>` when the first window becomes ready, and removes it on exit.
public enum ReadySignal {
    public static let envVar = "RUNE_READY_DIR"
    public static let runeVersion = "0.1.0"

    public enum WrittenState: Sendable, Equatable {
        case notYet
        case noFile
        case at(URL)
    }

    public struct SignalPayload: Sendable, Equatable {
        public let pid: UInt32
        public let bundleId: String
        public let readyMs: UInt64

        public init(pid: UInt32, bundleId: String, readyMs: UInt64) {
            self.pid = pid
            self.bundleId = bundleId
            self.readyMs = readyMs
        }

        private static func escapeJSONString(_ input: String) -> String {
            var out = ""
            out.reserveCapacity(input.count)
            for scalar in input.unicodeScalars {
                switch scalar.value {
                case 0x22: out += "\\\""
                case 0x5C: out += "\\\\"
                case 0x08: out += "\\b"
                case 0x0C: out += "\\f"
                case 0x0A: out += "\\n"
                case 0x0D: out += "\\r"
                case 0x09: out += "\\t"
                case 0x00..<0x20:
                    out += String(format: "\\u%04x", scalar.value)
                default:
                    out.unicodeScalars.append(scalar)
                }
            }
            return out
        }

        public func jsonLine() -> String {
            let escaped = Self.escapeJSONString(bundleId)
            return "{\"pid\":\(pid),\"bundle_id\":\"\(escaped)\",\"ready_ms\":\(readyMs),\"rune\":\"\(runeVersion)\"}"
        }

        public func write(in directory: URL?) -> URL? {
            guard let dir = directory, !dir.path.isEmpty else { return nil }
            do {
                #if os(Windows) || os(WASI)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                #else
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                #endif
                let cleanBundle = bundleId
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "\\", with: "_")
                let fileName = "\(cleanBundle).\(pid)"
                let target = dir.appendingPathComponent(fileName)
                let line = jsonLine() + "\n"
                #if os(WASI)
                // WASI has no global temporary directory. Stage the file in the same preopened directory.
                let staged = dir.appendingPathComponent(".rune-ready-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: staged) }
                try Data(line.utf8).write(to: staged, options: .withoutOverwriting)
                guard rename(staged.path, target.path) == 0 else { return nil }
                #else
                try Data(line.utf8).write(to: target, options: .atomic)
                #endif
                return target
            } catch {
                return nil
            }
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var runStartTimestamp: TimeInterval?
    private nonisolated(unsafe) static var written: WrittenState = .notYet
    private nonisolated(unsafe) static var atExitRegistered: Bool = false

    public static var currentPID: UInt32 {
        #if os(WASI)
        return 1
        #else
        return UInt32(max(0, ProcessInfo.processInfo.processIdentifier))
        #endif
    }

    public static func defaultBundleId() -> String {
        if let id = Bundle.main.bundleIdentifier, !id.isEmpty {
            return id
        }
        if let exe = CommandLine.arguments.first, !exe.isEmpty {
            let base = URL(fileURLWithPath: exe).lastPathComponent
            if !base.isEmpty { return base }
        }
        return "rune-app"
    }

    public static func runStarts() {
        lock.lock()
        if runStartTimestamp == nil {
            runStartTimestamp = Date().timeIntervalSince1970
        }
        lock.unlock()
    }

    public static func ready() {
        let dirPath = ProcessInfo.processInfo.environment[envVar]
        let url = dirPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        _ = readyIn(url)
    }

    @discardableResult
    public static func readyIn(_ directory: URL?, forceResetForTesting: Bool = false) -> WrittenState {
        lock.lock()
        defer { lock.unlock() }
        if forceResetForTesting {
            written = .notYet
        }
        guard written == .notYet else { return written }
        guard let dir = directory, !dir.path.isEmpty else {
            written = .noFile
            return written
        }
        let now = Date().timeIntervalSince1970
        let elapsedMs: UInt64
        if let start = runStartTimestamp {
            elapsedMs = UInt64(max(0.0, (now - start) * 1000.0))
        } else {
            elapsedMs = 0
        }
        let payload = SignalPayload(pid: currentPID, bundleId: defaultBundleId(), readyMs: elapsedMs)
        if let path = payload.write(in: dir) {
            written = .at(path)
            if !atExitRegistered {
                atExitRegistered = true
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                atexit {
                    ReadySignal.clear()
                }
                #endif
            }
        } else {
            written = .noFile
        }
        return written
    }

    public static func clear() {
        lock.lock()
        defer { lock.unlock() }
        if case .at(let url) = written {
            try? FileManager.default.removeItem(at: url)
            written = .noFile
        }
    }
}

// MARK: - 10. ReopenHandler (platform/reopen.rs)

/// Tracks dock/taskbar reopen requests when no window is visible (`rune::platform::reopen`).
public final class ReopenHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable () -> Void] = []

    public init() {}

    public func onReopen(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        callbacks.append(handler)
        lock.unlock()
    }

    public func trigger() {
        lock.lock()
        let copy = callbacks
        lock.unlock()
        for cb in copy {
            cb()
        }
    }
}
