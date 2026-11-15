// Port of `crates/rune/src/task/queue.rs` (upstream 4529c6c1, #1026):
// a serial service that borrows a task worker only while it has messages.

import Foundation

/// Whether a served handler keeps taking messages (`std::ops::ControlFlow<()>`).
public enum ControlFlow: Sendable, Equatable {
    case `continue`
    case `break`

    public var isBreak: Bool { self == .break }
    public var isContinue: Bool { self == .continue }
}

/// A message a stopped service refused (`std::sync::mpsc::SendError<T>`): the value comes back.
public struct SendError<T: Sendable>: Error, Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}

extension SendError: Equatable where T: Equatable {}

extension RuneTask {
    /// Like `serve`, with a sender that schedules the drain instead of keeping a thread
    /// waiting for a message. Messages run in send order, one at a time. Use `serve` for an
    /// existing stream or a service that needs a dedicated thread (`task::queue`).
    ///
    /// `each` returning `.break` (or throwing, the Swift stand-in for a panic) stops the service:
    /// queued messages are dropped and every later `send` fails.
    public static func queue<T: Sendable>(
        name: String,
        each: @escaping @Sendable (T) throws -> ControlFlow
    ) -> Queue<T> {
        queue(name: name, each: each, spawner: { name, work in
            RuneTask.spawn(name: name, work: work)
            return true
        })
    }

    /// `queue` with the worker spawner injected. The spawner returns `false` when no worker
    /// could start the drain (upstream `task::spawn` returning `Err`). It must run `work`
    /// asynchronously: `send` holds the queue lock while scheduling, as upstream does.
    static func queue<T: Sendable>(
        name: String,
        each: @escaping @Sendable (T) throws -> ControlFlow,
        spawner: @escaping QueueSpawner
    ) -> Queue<T> {
        Queue(inner: QueueInner(name: name, each: each, spawner: spawner))
    }
}

typealias QueueSpawner = @Sendable (String, @escaping @Sendable () -> Void) -> Bool

/// Sender returned by `RuneTask.queue`. Copies share one service; dropping the last copy lets
/// pending work finish (`task::Queue`).
public struct Queue<T: Sendable>: Sendable {
    let inner: QueueInner<T>

    /// Sends without waiting for previous work. Returns the message if the service stopped
    /// or no worker could start its drain (`Queue::send`).
    @discardableResult
    public func send(_ value: T) -> Result<Void, SendError<T>> {
        inner.send(value)
    }
}

/// Native inner state (`queue::native::Inner`): the inbox behind one lock.
final class QueueInner<T: Sendable>: @unchecked Sendable {
    typealias Handler = @Sendable (T) throws -> ControlFlow

    /// `Inbox`: pending messages in send order, the handler and whether a drain is scheduled.
    /// The drain takes the handler to call it and puts it back when idle. When it stops,
    /// neither a handler nor a scheduled drain remains.
    private struct Inbox {
        var pending = QueueDeque<T>()
        var each: Handler?
        var draining = false
    }

    let name: String
    private let spawner: QueueSpawner
    private let lock = NSLock()
    private var state: Inbox

    init(name: String, each: @escaping Handler, spawner: @escaping QueueSpawner) {
        self.name = name
        self.spawner = spawner
        self.state = Inbox(pending: QueueDeque(), each: each, draining: false)
    }

    func send(_ value: T) -> Result<Void, SendError<T>> {
        lock.lock()
        defer { lock.unlock() }
        if !state.draining {
            if state.each == nil { return .failure(SendError(value)) }
            if !spawner(name, { [self] in self.drain() }) { return .failure(SendError(value)) }
            state.draining = true
        }
        state.pending.pushBack(value)
        return .success(())
    }

    private func drain() {
        lock.lock()
        let taken = state.each
        state.each = nil
        lock.unlock()
        guard let each = taken else { preconditionFailure("one drain per service") }
        while true {
            lock.lock()
            guard let value = state.pending.popFront() else {
                state.each = each
                state.draining = false
                lock.unlock()
                return
            }
            lock.unlock()
            // No queue lock across user work. As with a disconnected channel, a handler
            // that breaks or throws drops queued messages and all later sends fail.
            let flow = (try? each(value)) ?? .break
            if flow != .continue {
                lock.lock()
                state.draining = false
                var pending = state.pending
                state.pending = QueueDeque()
                lock.unlock()
                pending.removeAll() // a message's deinit may itself try to send
                return
            }
        }
    }

    // MARK: Test observation

    var isDraining: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.draining
    }

    var hasHandler: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.each != nil
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return state.pending.count
    }
}

/// Minimal FIFO standing in for `VecDeque`: amortised O(1) push/pop.
struct QueueDeque<Element> {
    private var storage: [Element?] = []
    private var head = 0

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }

    mutating func pushBack(_ element: Element) {
        storage.append(element)
    }

    mutating func popFront() -> Element? {
        guard head < storage.count else { return nil }
        let element = storage[head]
        storage[head] = nil
        head += 1
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 32 && head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return element
    }

    mutating func removeAll() {
        storage.removeAll()
        head = 0
    }
}
