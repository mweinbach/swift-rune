// The single-instance transport and the desktop event loop meet here. An accepted
// launch stays pending until a shown app window serves it. If the loop ends first,
// a new process claims the old instance and receives the original arguments.
import Foundation
#if os(Windows) || os(Linux)
import Synchronization
#endif

final class InstanceLaunches: @unchecked Sendable {
    static let shared = InstanceLaunches()

    private struct Launch {
        let at: TimeInterval
        let arguments: [String]
    }

    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private let quitting: @Sendable () -> Bool
    private let restart: @Sendable ([String]) -> Void
    private var pending = [Launch]()
    private var exited = false
    #if os(Windows) || os(Linux)
    private let waiting = Atomic(false)
    #endif

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         quitting: @escaping @Sendable () -> Bool = { QuitLifecycle.isQuitting },
         restart: @escaping @Sendable ([String]) -> Void = { RelaunchController.spawnHanded(arguments: $0) }) {
        self.now = now
        self.quitting = quitting
        self.restart = restart
    }

    var loopExited: Bool { lock.withLock { exited } }
    var launchesWaiting: Bool {
        #if os(Windows) || os(Linux)
        waiting.load(ordering: .acquiring)
        #else
        lock.withLock { !pending.isEmpty }
        #endif
    }

    func started() {
        lock.withLock { exited = false }
    }

    func receive(_ arguments: [String], deliver: ([String]) -> Bool) {
        let shouldRestart = lock.withLock {
            if exited || quitting() { return true }
            let time = now()
            if let oldest = pending.first, time - oldest.at >= 5 {
                pending.removeAll { time - $0.at >= 5 }
            }
            pending.append(Launch(at: time, arguments: arguments))
            #if os(Windows) || os(Linux)
            waiting.store(true, ordering: .releasing)
            #endif
            return false
        }
        if shouldRestart {
            restart(arguments)
        } else if !deliver(arguments) {
            ended()
        }
    }

    func served() {
        lock.withLock { clearPending() }
    }

    private func clearPending() {
        pending.removeAll(keepingCapacity: true)
        #if os(Windows) || os(Linux)
        waiting.store(false, ordering: .releasing)
        #endif
    }

    func ended() {
        let launches = lock.withLock {
            exited = true
            let time = now()
            let recent = pending.filter { time - $0.at < 5 }
            clearPending()
            return recent
        }
        for launch in launches { restart(launch.arguments) }
    }
}
