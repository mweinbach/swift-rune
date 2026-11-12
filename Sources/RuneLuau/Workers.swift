import Foundation
import Rune

/// Thread-safe shared state between background workers and a `Script` VM.
internal final class SharedScriptState: @unchecked Sendable {
    private let lock = NSLock()
    private var dirty: Bool = false
    private var completions: [(UInt64, LuauData)] = []
    private var waker: Waker?
    private var nextJobID: UInt64 = 0

    func setWaker(_ waker: Waker) {
        lock.lock()
        self.waker = waker
        lock.unlock()
    }

    func wake() {
        lock.lock()
        let w = waker
        lock.unlock()
        w?.wake()
    }

    func mark() {
        lock.lock()
        dirty = true
        lock.unlock()
    }

    func takeDirty() -> Bool {
        lock.lock()
        let was = dirty
        dirty = false
        lock.unlock()
        return was
    }

    func takeCompletions() -> [(UInt64, LuauData)] {
        lock.lock()
        let list = completions
        completions.removeAll(keepingCapacity: true)
        lock.unlock()
        return list
    }

    func makeJob() -> Completer {
        lock.lock()
        nextJobID += 1
        let id = nextJobID
        lock.unlock()
        return Completer(id: id, shared: self)
    }

    fileprivate func complete(id: UInt64, value: LuauData) {
        lock.lock()
        completions.append((id, value))
        dirty = true
        let w = waker
        lock.unlock()
        w?.wake()
    }
}

/// Completes a host async call from any thread, resuming the waiting Luau task on the next poll.
public final class Completer: @unchecked Sendable {
    internal let id: UInt64
    private let shared: SharedScriptState
    private let lock = NSLock()
    private var finished: Bool = false

    internal init(id: UInt64, shared: SharedScriptState) {
        self.id = id
        self.shared = shared
    }

    public func complete(_ value: LuauData = .nil) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        shared.complete(id: id, value: value)
    }

    deinit {
        complete(.nil)
    }
}

/// Runs `job` off the UI thread on a shared background queue.
public func spawnBlocking(_ job: @escaping @Sendable () -> Void) {
    LuauWorkerPool.queue.async(execute: job)
}

private enum LuauWorkerPool {
    static let queue = DispatchQueue(label: "rune.luau.workers", qos: .userInitiated, attributes: .concurrent)
}
