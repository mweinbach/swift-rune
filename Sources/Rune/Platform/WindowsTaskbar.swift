#if os(Windows)
import CRuneWin32
import Dispatch
import Foundation

/// Explorer can be slow to initialize its taskbar object. Keep shell calls off the window thread.
final class WindowsTaskbar: @unchecked Sendable {
    private static let worker = DispatchQueue(label: "rune.windows.taskbar")
    private let lock = NSLock()
    private var window: UnsafeMutableRawPointer?
    private var lastState = TaskbarState()
    private var revision: UInt64 = 0

    init(window: UnsafeMutableRawPointer?) {
        self.window = window
    }

    func set(_ state: TaskbarState) {
        let next = lock.withLock { () -> UInt64? in
            guard window != nil, lastState != state else { return nil }
            lastState = state
            revision &+= 1
            return revision
        }
        if let next { enqueue(state, revision: next) }
    }

    func reapply() {
        let (state, revision) = lock.withLock { (lastState, self.revision) }
        if state != TaskbarState() { enqueue(state, revision: revision) }
    }

    func close() {
        lock.withLock { window = nil }
    }

    private func enqueue(_ state: TaskbarState, revision: UInt64) {
        Self.worker.async { [weak self] in
            guard let self, let window = self.lock.withLock({ self.revision == revision ? self.window : nil }) else { return }
            let flag: Int32 = switch state.progress {
            case .none: 0
            case .busy: 1
            case .paused: 2
            case .error: 3
            }
            _ = (Array(state.badgeDescription.utf16) + [0]).withUnsafeBufferPointer {
                rune_win_taskbar(window, flag, state.badgeCount, $0.baseAddress)
            }
        }
    }
}
#endif
