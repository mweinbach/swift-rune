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
}

/// Platform scroll bar visibility preference (`rune::platform::scroll_bars`).
public enum ScrollBarStyle: String, Sendable, Equatable, Codable {
    case overlay
    case alwaysVisible
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
        #if os(macOS)
        let rm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fka: Bool
        if Thread.isMainThread {
            fka = MainActor.assumeIsolated { NSApplication.shared.isFullKeyboardAccessEnabled }
        } else {
            fka = true
        }
        let dci = NSEvent.doubleClickInterval
        let sbStyle: ScrollBarStyle
        if Thread.isMainThread {
            sbStyle = MainActor.assumeIsolated {
                (NSScroller.preferredScrollerStyle == .legacy) ? .alwaysVisible : .overlay
            }
        } else {
            sbStyle = .overlay
        }
        return SystemPreferences(
            darkMode: nil,
            reducedMotion: rm,
            fullKeyboardAccess: fka,
            contrast: nil,
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
            contrast: nil,
            accent: .default,
            doubleClickInterval: 0.4,
            scrollBarStyle: .overlay
        )
        #else
        return SystemPreferences()
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

        public func jsonLine() -> String {
            let escaped = bundleId
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"pid\":\(pid),\"bundle_id\":\"\(escaped)\",\"ready_ms\":\(readyMs),\"rune\":\"\(runeVersion)\"}"
        }

        public func write(in directory: URL?) -> URL? {
            guard let dir = directory, !dir.path.isEmpty else { return nil }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                #if !os(Windows) && !os(WASI)
                try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: dir.path)
                #endif
                let cleanBundle = bundleId
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "\\", with: "_")
                let fileName = "\(cleanBundle).\(pid)"
                let target = dir.appendingPathComponent(fileName)
                let temp = dir.appendingPathComponent(".\(fileName).tmp")
                let line = jsonLine() + "\n"
                try Data(line.utf8).write(to: temp)
                if FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: temp, to: target)
                return target
            } catch {
                return nil
            }
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var runStartTimestamp: TimeInterval?
    private nonisolated(unsafe) static var written: WrittenState = .notYet

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
        let exe = CommandLine.arguments.first ?? "rune"
        let base = URL(fileURLWithPath: exe).lastPathComponent
        return base.isEmpty ? "rune" : base
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
