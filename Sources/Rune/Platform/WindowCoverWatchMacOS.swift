#if os(macOS)
import AppKit

/// Watches what covers a shown AppKit window: the occlusion notification (winit's
/// `WindowEvent::Occluded`, `Cover::System`), which on macOS also reports minimising. The host
/// feeds each report to its `CoveredWindowDriver` (`window/sight.rs::Host::set_cover`).
@MainActor
final class WindowCoverWatch {
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    init(window: NSWindow, onOccluded: @escaping @MainActor (Bool) -> Void) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window else { return }
                onOccluded(Self.occluded(window))
            }
        })
    }

    /// winit's `Occluded`: the window's occlusion state no longer includes `.visible`.
    static func occluded(_ window: NSWindow) -> Bool {
        !window.occlusionState.contains(.visible)
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
#endif
