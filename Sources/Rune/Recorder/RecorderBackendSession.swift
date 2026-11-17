#if (os(macOS) && canImport(AVFoundation) && canImport(CoreAudio)) || (canImport(CRuneMedia) && (os(Windows) || os(Linux)))
import Foundation
import Dispatch

internal final class RecorderBackendSession: @unchecked Sendable {
    enum Command {
        case pause
        case resume
        case stop(CheckedReply<Result<Double, RecorderError>>)
        case cancel(CheckedReply<Void>)
    }

    final class CheckedReply<T: Sendable>: @unchecked Sendable {
        private let sem = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: T?

        func send(_ v: T) {
            lock.withLock { value = v }
            sem.signal()
        }

        func wait(timeout: TimeInterval) -> T? {
            let result = sem.wait(timeout: .now() + timeout)
            guard result == .success else { return nil }
            return lock.withLock { value }
        }

        func wait() -> T {
            sem.wait()
            return lock.withLock { value! }
        }
    }

    private let lock = NSLock()
    private var queue: [Command] = []
    private var terminal: Result<Double, RecorderError>?
    private let sem = DispatchSemaphore(value: 0)

    init() {}

    func send(_ cmd: Command) {
        if let result = lock.withLock({ () -> Result<Double, RecorderError>? in
            if let terminal { return terminal }
            queue.append(cmd)
            return nil
        }) {
            Self.reply(to: cmd, with: result)
            return
        }
        sem.signal()
    }

    /// A device can disappear while another thread is submitting a stop or cancel.
    func complete(_ result: Result<Double, RecorderError>) {
        let remaining = lock.withLock {
            terminal = result
            let pending = queue
            queue.removeAll()
            return pending
        }
        for cmd in remaining { Self.reply(to: cmd, with: result) }
    }

    private static func reply(to cmd: Command, with result: Result<Double, RecorderError>) {
        switch cmd {
        case .stop(let reply): reply.send(result)
        case .cancel(let reply): reply.send(())
        case .pause, .resume: break
        }
    }

    func pop(timeout: TimeInterval) -> Command? {
        if let first = lock.withLock({ queue.isEmpty ? nil : queue.removeFirst() }) {
            return first
        }
        _ = sem.wait(timeout: .now() + timeout)
        return lock.withLock { queue.isEmpty ? nil : queue.removeFirst() }
    }

    func tryPopAll() -> [Command] {
        lock.withLock {
            let all = queue
            queue.removeAll()
            return all
        }
    }
}

extension RecorderBackend {
    static let replyPatience: TimeInterval = 5.0
    private static let onRecorderThreadKey = "rune.onRecorderThread"

    static func pause(_ session: RecorderBackendSession) {
        session.send(.pause)
    }

    static func resume(_ session: RecorderBackendSession) {
        session.send(.resume)
    }

    static func stop(_ session: RecorderBackendSession) -> Result<Double, RecorderError> {
        let reply = RecorderBackendSession.CheckedReply<Result<Double, RecorderError>>()
        session.send(.stop(reply))
        #if os(Windows) || os(Linux)
        // The desktop worker acknowledges every exit, including failed initialization.
        // Wait for the encoder to publish the final file before reporting its result.
        return reply.wait()
        #else
        return reply.wait(timeout: replyPatience) ?? .failure("the recorder didn't stop")
        #endif
    }

    static func finish(_ session: RecorderBackendSession) {
        let onThread = (Thread.current.threadDictionary[onRecorderThreadKey] as? Bool) ?? false
        if !onThread {
            _ = stop(session)
        }
    }

    static func cancel(_ session: RecorderBackendSession) {
        let reply = RecorderBackendSession.CheckedReply<Void>()
        session.send(.cancel(reply))
        #if os(Windows) || os(Linux)
        reply.wait()
        #else
        _ = reply.wait(timeout: replyPatience)
        #endif
    }

    static func markRecorderThread() {
        Thread.current.threadDictionary[onRecorderThreadKey] = true
    }

    static func idleSession() -> RecorderBackendSession {
        RecorderBackendSession()
    }

}
#endif
