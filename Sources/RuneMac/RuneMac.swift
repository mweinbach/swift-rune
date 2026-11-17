@_exported import RuneNotify
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Top-level convenience namespace matching upstream `rune-mac`.
public enum RuneMac {
    public typealias Notify = RuneNotify

    public static func savedSize(
        named name: String,
        userDefaults: UserDefaults = .standard
    ) -> WindowFrameSize? {
        WindowFramePersistence.savedSize(named: name, userDefaults: userDefaults)
    }

    public static func clampFrame(
        _ frame: CGRect,
        toVisibleFrames visibleFrames: [CGRect],
        minimumSize: CGSize = CGSize(width: 100, height: 100)
    ) -> CGRect {
        WindowFramePersistence.clampFrame(frame, toVisibleFrames: visibleFrames, minimumSize: minimumSize)
    }

    public static func setBusy(
        _ on: Bool,
        pid: Int32 = AppLifecycleHelpers.busyMarkerProcessID,
        homeDirectory: URL? = nil
    ) {
        AppLifecycleHelpers.setBusy(on, pid: pid, homeDirectory: homeDirectory)
    }

    #if os(macOS)
    @MainActor
    @discardableResult
    public static func rememberFrame(named name: String) -> Bool {
        WindowFramePersistence.rememberFrame(named: name)
    }

    @MainActor
    public static func toggleFullScreen() {
        WindowFramePersistence.toggleFullScreen()
    }

    @MainActor
    public static var isFullScreen: Bool {
        WindowFramePersistence.isFullScreen
    }

    @MainActor
    public static func quietLaunchIfNeeded() {
        AppLifecycleHelpers.quietLaunchIfNeeded()
    }

    @MainActor
    @discardableResult
    public static func setActivationPolicy(_ policy: ActivationPolicy) -> Bool {
        AppLifecycleHelpers.setActivationPolicy(policy)
    }
    #else
    @discardableResult
    public static func rememberFrame(named name: String) -> Bool {
        _ = name
        return true
    }

    public static func toggleFullScreen() {}

    public static var isFullScreen: Bool { false }

    public static func quietLaunchIfNeeded() {}

    @discardableResult
    public static func setActivationPolicy(_ policy: ActivationPolicy) -> Bool {
        _ = policy
        return true
    }
    #endif
}
