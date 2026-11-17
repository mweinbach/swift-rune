#if os(macOS) || (canImport(UIKit) && !os(watchOS))
import CoreFoundation

/// Counts host run-loop turns, including turns that process input without requesting a frame.
@MainActor
final class AppleSurfaceLoopObserver {
    private var observer: CFRunLoopObserver?

    init(meter: SurfaceMeter) {
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeSources.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            if activity == .afterWaiting {
                // The source that woke the loop can draw before its next beforeSources notification.
                meter.noteWaited()
            } else {
                meter.turn(woke: false, waited: false)
            }
        }!
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    isolated deinit {
        if let observer { CFRunLoopObserverInvalidate(observer) }
    }
}
#endif
