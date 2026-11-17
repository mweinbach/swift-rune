import Foundation
#if os(macOS)
import AppKit
#endif

/// Cross-platform representation of `NSApplication.ActivationPolicy`.
public enum ActivationPolicy: Int, Sendable, Equatable, Hashable {
    case regular = 0
    case accessory = 1
    case prohibited = 2
}

/// Relaunch configuration computed without side effects for deterministic testing.
public struct RelaunchPlan: Sendable, Equatable {
    public var executablePath: String
    public var arguments: [String]
    public var environmentOverrides: [String: String]

    public init(
        executablePath: String,
        arguments: [String],
        environmentOverrides: [String: String]
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environmentOverrides = environmentOverrides
    }
}

/// Helpers for macOS activation policy, quiet background relaunches, and busy markers.
public enum AppLifecycleHelpers {
    public static let quietEnvVar = "MAC_APP_QUIET"

    /// Computes the relaunch command and environment for an executable or `.app` bundle.
    public static func relaunchPlan(
        bundlePath: String? = Bundle.main.bundlePath,
        executablePath: String? = Bundle.main.executablePath,
        arguments: [String] = [],
        quiet: Bool = false
    ) -> RelaunchPlan? {
        var env: [String: String] = [:]
        if quiet {
            env[quietEnvVar] = "1"
        }

        if let bundlePath, bundlePath.hasSuffix(".app") {
            var args = ["-n"]
            if quiet {
                args.append("-g")
            }
            args.append(bundlePath)
            if !arguments.isEmpty {
                args.append("--args")
                args.append(contentsOf: arguments)
            }
            return RelaunchPlan(
                executablePath: "/usr/bin/open",
                arguments: args,
                environmentOverrides: env
            )
        }

        guard let executablePath, !executablePath.isEmpty else {
            return nil
        }
        return RelaunchPlan(
            executablePath: executablePath,
            arguments: arguments,
            environmentOverrides: env
        )
    }

    #if os(macOS)
    /// Spawns a relaunched instance using `relaunchPlan`.
    @discardableResult
    public static func relaunch(
        bundlePath: String? = Bundle.main.bundlePath,
        executablePath: String? = Bundle.main.executablePath,
        arguments: [String] = [],
        quiet: Bool = false,
        terminateCurrent: Bool = false
    ) throws -> Process? {
        guard let plan = relaunchPlan(
            bundlePath: bundlePath,
            executablePath: executablePath,
            arguments: arguments,
            quiet: quiet
        ) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        if !plan.environmentOverrides.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in plan.environmentOverrides {
                env[k] = v
            }
            process.environment = env
        }
        try process.run()

        if terminateCurrent {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        return process
    }

    /// Sets the `NSApplication` activation policy.
    @MainActor
    @discardableResult
    public static func setActivationPolicy(_ policy: ActivationPolicy) -> Bool {
        let nsPolicy: NSApplication.ActivationPolicy
        switch policy {
        case .regular:
            nsPolicy = .regular
        case .accessory:
            nsPolicy = .accessory
        case .prohibited:
            nsPolicy = .prohibited
        }
        return NSApplication.shared.setActivationPolicy(nsPolicy)
    }

    /// Returns the current `NSApplication` activation policy.
    @MainActor
    public static func currentActivationPolicy() -> ActivationPolicy {
        switch NSApplication.shared.activationPolicy() {
        case .regular:
            return .regular
        case .accessory:
            return .accessory
        case .prohibited:
            return .prohibited
        @unknown default:
            return .regular
        }
    }

    /// Call early at launch before the event loop starts when `MAC_APP_QUIET` may be set.
    /// Temporarily switches to `.prohibited` so the app does not steal focus, then restores
    /// `.regular` and unhides without activating once macOS hides it (or after 5 seconds).
    @MainActor
    public static func quietLaunchIfNeeded(
        environment: [String: String]? = nil
    ) {
        let resolvedEnv = environment ?? ProcessInfo.processInfo.environment
        guard resolvedEnv[quietEnvVar] != nil else { return }
        if environment == nil {
            unsetenv(quietEnvVar)
        }
        _ = setActivationPolicy(.prohibited)
        scheduleQuietRestore(attempt: 0)
    }

    @MainActor
    private static func scheduleQuietRestore(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                if !app.isHidden && attempt < 20 {
                    scheduleQuietRestore(attempt: attempt + 1)
                    return
                }
                _ = setActivationPolicy(.regular)
                app.unhideWithoutActivation()
            }
        }
    }
    #endif

    /// Resolves the home directory preferring explicit `homeDirectory` and `$HOME` over `FileManager`.
    public static func resolvedHomeDirectory(
        explicit: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicit { return explicit }
        if let envHome = environment["HOME"], !envHome.isEmpty {
            return URL(fileURLWithPath: envHome, isDirectory: true)
        }
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    @usableFromInline
    static var busyMarkerProcessID: Int32 {
        #if os(macOS)
        return ProcessInfo.processInfo.processIdentifier
        #else
        return 0
        #endif
    }

    /// Marks this process as busy in `~/Library/Caches/mac-app/busy/<pid>` so external
    /// relaunch scripts wait before swapping the app.
    public static func setBusy(
        _ on: Bool,
        pid: Int32 = AppLifecycleHelpers.busyMarkerProcessID,
        homeDirectory: URL? = nil
    ) {
        #if os(macOS)
        let baseHome = resolvedHomeDirectory(explicit: homeDirectory)
        let dir = baseHome
            .appendingPathComponent("Library/Caches/mac-app/busy", isDirectory: true)
        let marker = dir.appendingPathComponent(String(pid), isDirectory: false)
        if on {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data().write(to: marker)
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
        #endif
    }

    /// Returns whether a busy marker currently exists for `pid`.
    public static func isBusy(
        pid: Int32 = AppLifecycleHelpers.busyMarkerProcessID,
        homeDirectory: URL? = nil
    ) -> Bool {
        #if os(macOS)
        let baseHome = resolvedHomeDirectory(explicit: homeDirectory)
        let marker = baseHome
            .appendingPathComponent("Library/Caches/mac-app/busy/\(pid)", isDirectory: false)
        return FileManager.default.fileExists(atPath: marker.path)
        #else
        return false
        #endif
    }
}
