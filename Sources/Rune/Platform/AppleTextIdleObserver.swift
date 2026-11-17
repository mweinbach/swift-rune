#if os(macOS) || (canImport(UIKit) && !os(watchOS))
import CoreFoundation
import Foundation
#if os(macOS)
import AppKit
#endif

/// A window can prepare offscreen text after its first present, when its UI run loop is going to sleep.
@MainActor
internal final class AppleTextIdleObserver {
    private let observer: CFRunLoopObserver

    init<State>(runtime: Runtime<State>, canPrepare: @escaping @MainActor () -> Bool = { true }) {
        observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { [weak runtime] _, _ in
            MainActor.assumeIsolated {
                guard let runtime, runtime.textIdleOwed, !runtime.isStale, canPrepare() else { return }
                #if os(macOS)
                // AppKit can already hold another event outside the run loop's sources.
                guard NSApp?.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: false) == nil else { return }
                #endif
                if runtime.textIdleTurn() {
                    // The prepared view requested another turn. Let input run between them.
                    DispatchQueue.main.async {}
                }
            }
        }
        // Tracking and modal loops keep ownership of input until the default mode resumes.
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
    }

    isolated deinit {
        CFRunLoopObserverInvalidate(observer)
    }
}
#endif
