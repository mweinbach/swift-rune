#if os(macOS)
import AppKit

/// Watches what covers a shown AppKit window and what restores it: the occlusion notification
/// (winit's `WindowEvent::Occluded`, `Cover::System`) and miniaturize / deminiaturize
/// (`Win::minimized`). The host feeds each report to its `CoveredWindowDriver`
/// (`window/sight.rs::Host::set_cover`).
@MainActor
final class WindowCoverWatch {
    enum Report {
        /// The window is or isn't occluded. Only a window ordered in can be covered; an ordered
        /// out one is hidden, which its host's hidden path runs.
        case occluded(Bool)
        case minimized(Bool)
    }

    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    init(window: NSWindow, onReport: @escaping @MainActor (Report) -> Void) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window else { return }
                onReport(.occluded(Self.occluded(window)))
            }
        })
        tokens.append(center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { onReport(.minimized(true)) }
        })
        tokens.append(center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { onReport(.minimized(false)) }
        })
    }

    /// A window ordered in whose occlusion state no longer includes `.visible`.
    static func occluded(_ window: NSWindow) -> Bool {
        window.isVisible && !window.occlusionState.contains(.visible)
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

extension CoveredWindowDriver {
    /// Applies a `WindowCoverWatch` report (`Host::set_cover` / minimise).
    @MainActor
    mutating func apply(_ report: WindowCoverWatch.Report, runtime: any CoveredWindowRuntime, at now: Double? = nil) -> Outcome {
        switch report {
        case .occluded(let occluded):
            return setOccluded(occluded, runtime: runtime, at: now)
        case .minimized(let minimized):
            return setMinimized(minimized, runtime: runtime, at: now)
        }
    }
}
#endif
