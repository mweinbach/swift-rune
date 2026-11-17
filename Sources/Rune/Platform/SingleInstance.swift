import Foundation

#if os(Windows)
import CRuneWin32
#endif

/// Platform adapter for incoming OS get-URL events (`open_url::Glue`).
public protocol IncomingURLGlue: AnyObject, Sendable {
    func handledElsewhere() -> Bool
    func install() -> Bool
    func remove()
}

/// Incoming URL router buffering launch links until the first window listens (`open_url::Inbox`).
public final class IncomingURLInbox: @unchecked Sendable {
    public typealias ListenerSink = @Sendable (String) -> Void

    private enum Funnel {
        case unprepared(kept: [String])
        case launch(kept: [String])
        case listening(listeners: [(id: UInt64, sink: ListenerSink)])
        case closed
    }

    public final class Listening: @unchecked Sendable {
        private weak var inbox: IncomingURLInbox?
        private let id: UInt64
        private var active = true
        private let lock = NSLock()

        fileprivate init(inbox: IncomingURLInbox, id: UInt64) {
            self.inbox = inbox
            self.id = id
        }

        public func cancel() {
            lock.lock()
            let wasActive = active
            active = false
            lock.unlock()
            guard wasActive else { return }
            inbox?.removeListener(id: id)
        }

        deinit {
            cancel()
        }
    }

    private let lock = NSLock()
    private var funnel: Funnel = .unprepared(kept: [])
    private var nextListenerID: UInt64 = 0

    public init() {}

    /// Shared process inbox.
    public static let shared = IncomingURLInbox()

    /// Begins another desktop event loop while preserving links buffered for its first window.
    func beginWindowGroup() {
        lock.withLock {
            switch funnel {
            case .closed:
                funnel = .unprepared(kept: [])
            case .listening(let listeners) where listeners.isEmpty:
                funnel = .unprepared(kept: [])
            default:
                break
            }
        }
    }

    /// Before the event loop starts: installs `glue` and buffers links until a window listens,
    /// unless something else already handles URLs (`handledElsewhere()`).
    public func prepare(glue: IncomingURLGlue) {
        lock.lock()
        switch funnel {
        case .unprepared(let kept):
            if !glue.handledElsewhere() && glue.install() {
                funnel = .launch(kept: kept)
            }
        case .launch, .listening, .closed:
            break
        }
        lock.unlock()
    }

    /// Prepends links the app was launched with ahead of any later arrivals.
    public func launched(_ urls: [String]) {
        guard !urls.isEmpty else { return }
        lock.lock()
        switch funnel {
        case .unprepared(let kept):
            funnel = .unprepared(kept: urls + kept)
        case .launch(let kept):
            funnel = .launch(kept: urls + kept)
        case .listening, .closed:
            break
        }
        lock.unlock()
    }

    /// Registers a listening sink for incoming URLs and replays buffered launch links in order.
    @discardableResult
    public func listen(glue: IncomingURLGlue, sink: @escaping ListenerSink) -> Listening? {
        lock.lock()
        var listeners: [(id: UInt64, sink: ListenerSink)] = []
        var kept: [String] = []

        switch funnel {
        case .listening(let existing):
            listeners = existing
        case .launch(let buffered):
            kept = buffered
        case .unprepared(let buffered):
            guard glue.install() else {
                lock.unlock()
                return nil
            }
            kept = buffered
        case .closed:
            guard glue.install() else {
                lock.unlock()
                return nil
            }
        }

        let id = nextListenerID
        nextListenerID += 1
        listeners.append((id: id, sink: sink))
        funnel = .listening(listeners: listeners)
        lock.unlock()

        for url in kept {
            sink(url)
        }
        return Listening(inbox: self, id: id)
    }

    /// Convenience helper wiring a `Runtime<State>` directly (`App.onOpenUrl` + `waker.wake()`).
    @discardableResult
    public func listen<State>(
        runtime: Runtime<State>,
        glue: IncomingURLGlue,
        enqueueUpdate: @escaping @Sendable (@escaping (inout State, inout Tx) -> Void) -> Void
    ) -> Listening? {
        guard let hook = runtime.onOpenUrl else { return nil }
        nonisolated(unsafe) let cb = hook
        return listen(glue: glue) { url in
            enqueueUpdate { state, tx in
                cb(&state, url, &tx)
            }
        }
    }

    /// Stops keeping links once startup windows exist, removing `glue` if nobody listens.
    public func settle(glue: IncomingURLGlue) {
        lock.lock()
        var shouldRemove = false
        switch funnel {
        case .listening(let listeners) where !listeners.isEmpty:
            break
        case .launch, .listening:
            funnel = .closed
            shouldRemove = true
        case .unprepared, .closed:
            funnel = .closed
        }
        lock.unlock()
        if shouldRemove {
            glue.remove()
        }
    }

    /// Delivers an incoming URL to the active front listener, or buffers it during startup.
    public func receive(_ url: String) {
        lock.lock()
        var targetSink: ListenerSink?
        switch funnel {
        case .unprepared(var kept):
            kept.append(url)
            funnel = .unprepared(kept: kept)
        case .launch(var kept):
            kept.append(url)
            funnel = .launch(kept: kept)
        case .listening(let listeners):
            targetSink = listeners.first?.sink
        case .closed:
            break
        }
        lock.unlock()

        targetSink?(url)
    }

    private func removeListener(id: UInt64) {
        lock.lock()
        if case .listening(var listeners) = funnel {
            listeners.removeAll { $0.id == id }
            funnel = .listening(listeners: listeners)
        }
        lock.unlock()
    }
}

/// Cross-platform single-instance handoff (`rune::single_instance`, `rune::release_instance`).
public enum SingleInstance {
    public static let magicPrefix = Array("rune-instance 2\0".utf8)
    public static let acceptedByte: UInt8 = 0x41 // 'A'
    public static let quittingByte: UInt8 = 0x51 // 'Q'
    public static let maxMessageBytes: Int = 1 << 20

    private static let lock = NSLock()
    nonisolated(unsafe) private static var relaunchHandler: (@Sendable () -> Bool)? = nil

    /// Returns true if `arg` looks like a `scheme://...` link (scheme >= 2 chars, starting with ASCII letter).
    public static func isLink(_ arg: String) -> Bool {
        guard let range = arg.range(of: "://") else { return false }
        let scheme = arg[..<range.lowerBound]
        guard scheme.count >= 2, let first = scheme.first, first.isASCII, first.isLetter else {
            return false
        }
        return scheme.allSatisfy { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "+" || ch == "-" || ch == "."
        }
    }

    /// Links among `arguments` (defaults to `CommandLine.arguments.dropFirst()`).
    public static func launchLinks(from arguments: [String]? = nil) -> [String] {
        let args = arguments ?? Array(CommandLine.arguments.dropFirst())
        return args.filter(isLink(_:))
    }

    /// Encodes the upstream frame. An oversized argument list cannot be handed off.
    public static func encodeHandoffMessage(arguments: [String]) -> [UInt8] {
        let body = Array(arguments.joined(separator: "\0").utf8)
        guard body.count <= maxMessageBytes else { return [] }
        let len = UInt32(body.count).littleEndian
        var msg = magicPrefix
        withUnsafeBytes(of: len) { msg.append(contentsOf: $0) }
        msg.append(contentsOf: body)
        return msg
    }

    /// Decodes a NUL-separated UTF-8 handoff body into non-empty argument strings.
    public static func decodeHandoffArguments(_ body: [UInt8]) -> [String]? {
        guard let str = String(bytes: body, encoding: .utf8) else { return nil }
        return str.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    /// Decodes a full framed handoff packet (`magicPrefix + u32_le(len) + body`).
    public static func decodeHandoffMessage(_ packet: [UInt8]) -> [String]? {
        let headerLen = magicPrefix.count + 4
        guard packet.count >= headerLen, Array(packet.prefix(magicPrefix.count)) == magicPrefix else {
            return nil
        }
        let b = packet[magicPrefix.count..<(magicPrefix.count + 4)]
        let i0 = magicPrefix.count
        let bodyLen = Int(
            UInt32(b[i0])
                | (UInt32(b[i0 + 1]) << 8)
                | (UInt32(b[i0 + 2]) << 16)
                | (UInt32(b[i0 + 3]) << 24)
        )
        guard bodyLen <= maxMessageBytes, packet.count >= headerLen + bodyLen else {
            return nil
        }
        let body = Array(packet[headerLen..<(headerLen + bodyLen)])
        return decodeHandoffArguments(body)
    }

    /// Registers a callback invoked when a secondary process launches without link arguments.
    public static func onRelaunch(_ handler: @escaping @Sendable () -> Bool) {
        lock.lock()
        relaunchHandler = handler
        lock.unlock()
    }

    /// Handles arguments forwarded from a secondary launch.
    public static func handleForwardedArguments(_ args: [String]) {
        #if os(Windows) || os(Linux)
        InstanceLaunches.shared.receive(args, deliver: deliverForwardedArguments)
        #else
        _ = deliverForwardedArguments(args)
        #endif
    }

    private static func deliverForwardedArguments(_ args: [String]) -> Bool {
        let links = args.filter(isLink(_:))
        if links.isEmpty {
            lock.lock()
            let fn = relaunchHandler
            lock.unlock()
            return fn?() ?? false
        } else {
            for link in links {
                IncomingURLInbox.shared.receive(link)
            }
            return true
        }
    }

    /// Claims the app's single-instance slot (`id`).
    ///
    /// On macOS/iOS, the OS maintains single-process URL/reopen delivery, so this returns `true`.
    /// Linux uses a Unix socket in the user's runtime directory. An explicit `baseDirectory`
    /// must be owned by the current user and writable only by that user. Windows uses a named
    /// pipe scoped to the current user and logon session.
    public static func claim(
        id: String,
        arguments: [String]? = nil,
        baseDirectory: String? = nil,
        forceUnixSocket: Bool = false
    ) -> Bool {
        #if os(Windows) || os(Linux)
        RelaunchController.waitForPrevious()
        #endif
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        if !forceUnixSocket {
            return true
        }
        #endif

        #if os(Linux) || os(macOS)
        return UnixInstance.claim(
            id: id,
            arguments: arguments ?? Array(CommandLine.arguments.dropFirst()),
            baseDirectory: baseDirectory
        )
        #elseif os(Windows)
        let packet = encodeHandoffMessage(arguments: arguments ?? Array(CommandLine.arguments.dropFirst()))
        // The native name keeps 256 Unicode scalars including its session and SID prefix.
        return Array(id.utf16.prefix(512)).withUnsafeBufferPointer { name in
            packet.withUnsafeBufferPointer { bytes in
                rune_win_instance_claim(
                    name.baseAddress, name.count, bytes.baseAddress, UInt32(bytes.count),
                    RelaunchController.handedFrom ?? 0,
                    { QuitLifecycle.isQuitting || InstanceLaunches.shared.loopExited ? 1 : 0 },
                    { body, count in
                        let data = UnsafeBufferPointer(start: body, count: Int(count))
                        guard let text = String(bytes: data, encoding: .utf8) else { return }
                        SingleInstance.handleForwardedArguments(text.split(separator: "\0").map(String.init))
                    }
                ) != 0
            }
        }
        #else
        return true
        #endif
    }

    /// Releases the process's claimed socket or named pipe (`release_instance`).
    public static func release() {
        #if os(Linux) || os(macOS)
        UnixInstance.release()
        #elseif os(Windows)
        rune_win_instance_release()
        #endif
    }

}
