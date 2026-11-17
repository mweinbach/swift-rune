// The macOS shell's side of `window/chrome.rs::sync_chrome`: place the traffic lights for the
// window's chrome and titlebar as the view set them, then tell the runtime what the window's
// controls take of the titlebar (`set_titlebar_inset`, `set_chrome_insets`).

#if os(macOS)
import AppKit
import Foundation
import RuneMotion

extension Runtime {
    /// `window/chrome.rs::sync_chrome`: the frame chrome and band height follow the view's
    /// `Cx::set_titlebar` / `Cx::titlebar_height` (`titlebar_set()`) over `App::titlebar`.
    /// Shells call it on creation, resize, scale change, full screen, uncovering and
    /// `takeTitlebarChanged()`; an unchanged result does not re-run the view.
    @MainActor
    public func syncWindowChrome(window: NSWindow, chrome: Chrome, titlebar: Titlebar?) {
        let insets = RuneMacWindowConfig.syncChrome(
            window: window,
            chrome: chrome,
            titlebar: titlebar,
            titlebarSet: viewTitlebarOverride
        )
        setTitlebarInset(RuneTrafficLights.titlebarInset(window))
        setChromeInsets(insets)
    }

    /// `syncWindowChrome(window:chrome:titlebar:)` for a type-erased `NSWindow`.
    @MainActor
    internal func syncWindowChrome(windowObject: AnyObject, chrome: Chrome, titlebar: Titlebar?) {
        guard let window = windowObject as? NSWindow else { return }
        syncWindowChrome(window: window, chrome: chrome, titlebar: titlebar)
    }
}

/// Watches the window events after which upstream re-syncs its chrome outside a resize:
/// entering or leaving full screen, and uncovering (`window/sight.rs`).
@MainActor
final class WindowChromeWatch {
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    init(window: NSWindow, onChange: @escaping @MainActor () -> Void) {
        let center = NotificationCenter.default
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            })
        }
        tokens.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window, window.occlusionState.contains(.visible) else { return }
                onChange()
            }
        })
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
#endif
