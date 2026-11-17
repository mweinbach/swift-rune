#if os(Windows) || os(Linux)
import Foundation
#if os(Windows)
import CRuneWin32
#else
import CRuneLinux
#endif

/// WindowHandle can outlive its native window or be called off the event-loop thread.
/// Only the owning thread queries the native window, changes its input region, or destroys it.
final class DesktopWindowAccess: @unchecked Sendable {
    private let owner = Thread.current
    private let condition = NSCondition()
    private var window: OpaquePointer?
    private var pending: [() -> Void] = []
    private let wake: @Sendable () -> Void

    init(window: OpaquePointer, wake: @escaping @Sendable () -> Void) {
        self.window = window
        self.wake = wake
    }

    func placement() -> WindowPlacement? {
        withWindow { window in
            guard let window else { return nil }
            #if os(Windows)
            var p = RuneWinPlacement()
            guard rune_win_placement(window, &p) != 0 else { return nil }
            let restore = p.has_restore != 0 ? ((p.restore_x, p.restore_y), (p.restore_width, p.restore_height)) : nil
            #else
            var p = RuneLinuxPlacement()
            guard rune_linux_placement(window, &p) != 0 else { return nil }
            let restore: ((Int32, Int32), (UInt32, UInt32))? = nil
            #endif
            let display = p.display_width != 0 && p.display_height != 0
                ? ((p.display_x, p.display_y), (p.display_width, p.display_height)) : nil
            return WindowPlacement(position: (p.x, p.y), contentPosition: (p.content_x, p.content_y),
                                   contentSize: (p.width, p.height), scale: p.scale,
                                   maximized: p.maximized != 0, minimized: p.minimized != 0,
                                   fullScreen: p.fullscreen != 0, restore: restore, display: display)
        }
    }

    func setClickThrough(_ enabled: Bool) -> Result<Void, any Error> {
        withWindow { window in
            guard let window else { return .failure(DesktopWindowError("Window is closed")) }
            #if os(Windows)
            guard rune_win_click_through(window, enabled ? 1 : 0) != 0 else {
                return .failure(DesktopWindowError("Windows could not change window hit testing"))
            }
            #else
            guard rune_linux_click_through(window, enabled ? 1 : 0) != 0 else {
                return .failure(DesktopWindowError(String(cString: rune_linux_error())))
            }
            #endif
            return .success(())
        }
    }

    private func withWindow<T>(_ work: @escaping (OpaquePointer?) -> T) -> T {
        if Thread.current === owner { return work(window) }
        condition.lock()
        guard window != nil else {
            condition.unlock()
            return work(nil)
        }
        var answer: T?
        pending.append { [self] in
            let value = work(window)
            condition.lock()
            answer = .some(value)
            condition.broadcast()
            condition.unlock()
        }
        condition.unlock()
        wake()
        condition.lock()
        while answer == nil { condition.wait() }
        defer { condition.unlock() }
        return answer!
    }

    /// Completes requests on the native event thread, including waiters racing with teardown.
    func drain(closing: Bool = false) {
        condition.lock()
        if closing { window = nil }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        condition.unlock()
        for call in batch { call() }
    }
}
#endif
