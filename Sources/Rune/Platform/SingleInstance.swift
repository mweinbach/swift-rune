import Foundation

#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
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
    nonisolated(unsafe) private static var claimedSocketPath: String? = nil
    nonisolated(unsafe) private static var listeningFD: Int32 = -1
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

    /// Encodes `arguments` in the upstream `rune-instance 2\0` frame format (`magic + u32_le(len) + nul-joined`).
    public static func encodeHandoffMessage(arguments: [String]) -> [UInt8] {
        let body = Array(arguments.joined(separator: "\0").utf8)
        let len = UInt32(min(body.count, maxMessageBytes)).littleEndian
        var msg = magicPrefix
        withUnsafeBytes(of: len) { msg.append(contentsOf: $0) }
        msg.append(contentsOf: body.prefix(maxMessageBytes))
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
        let links = args.filter(isLink(_:))
        if links.isEmpty {
            lock.lock()
            let fn = relaunchHandler
            lock.unlock()
            _ = fn?()
        } else {
            for link in links {
                IncomingURLInbox.shared.receive(link)
            }
        }
    }

    /// Claims the app's single-instance slot (`id`).
    ///
    /// On macOS/iOS, the OS maintains single-process URL/reopen delivery, so this returns `true`.
    /// On Linux, claims a Unix domain socket under `$XDG_RUNTIME_DIR` (or `baseDirectory` when provided).
    public static func claim(
        id: String,
        arguments: [String]? = nil,
        baseDirectory: String? = nil,
        forceUnixSocket: Bool = false
    ) -> Bool {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        if !forceUnixSocket {
            return true
        }
        #endif

        #if os(Linux) || os(macOS)
        return claimUnixSocket(
            id: id,
            arguments: arguments ?? Array(CommandLine.arguments.dropFirst()),
            baseDirectory: baseDirectory
        )
        #else
        return true
        #endif
    }

    /// Releases any claimed single-instance Unix socket and lock file (`release_instance`).
    public static func release() {
        #if os(Linux) || os(macOS)
        lock.lock()
        let listenFD = listeningFD
        let sockPath = claimedSocketPath
        listeningFD = -1
        claimedSocketPath = nil
        lock.unlock()

        if listenFD >= 0 {
            _ = close(listenFD)
        }
        if let sockPath {
            unlink(sockPath)
            unlink(sockPath + ".lock")
        }
        #endif
    }

    #if os(Linux) || os(macOS)
    private static func socketDirectory(override: String?) -> String {
        if let override, !override.isEmpty {
            return override
        }
        if let xdg = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !xdg.isEmpty {
            return xdg
        }
        return NSTemporaryDirectory()
    }

    private static func sanitizedID(_ id: String) -> String {
        String(id.map { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_")) ? ch : "_"
        })
    }

    private static func claimUnixSocket(id: String, arguments: [String], baseDirectory: String?) -> Bool {
        let dir = socketDirectory(override: baseDirectory)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sockPath = (dir as NSString).appendingPathComponent("rune-instance-\(sanitizedID(id)).sock")
        let lockPath = sockPath + ".lock"

        let lfd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if lfd >= 0 {
            _ = flock(lfd, LOCK_EX)
        }
        defer {
            if lfd >= 0 {
                _ = flock(lfd, LOCK_UN)
                _ = close(lfd)
            }
        }

        // First try connecting to an existing active listener.
        if tryForwardToExisting(socketPath: sockPath, arguments: arguments) {
            return false
        }

        // Clean stale socket if left behind by a crashed process.
        unlink(sockPath)

        #if os(Linux)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return true }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(sockPath.utf8)
        guard pathBytes.count < maxPathLen else {
            _ = close(fd)
            return true
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.initializeMemory(as: UInt8.self, repeating: 0)
            for (i, b) in pathBytes.enumerated() {
                buf[i] = b
            }
        }

        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRes == 0, listen(fd, 16) == 0 else {
            _ = close(fd)
            return true
        }

        lock.lock()
        claimedSocketPath = sockPath
        listeningFD = fd
        lock.unlock()

        Thread.detachNewThread {
            acceptLoop(listenFD: fd)
        }
        return true
    }

    private static func tryForwardToExisting(socketPath: String, arguments: [String]) -> Bool {
        #if os(Linux)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return false }
        defer { _ = close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < maxPathLen else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.initializeMemory(as: UInt8.self, repeating: 0)
            for (i, b) in pathBytes.enumerated() {
                buf[i] = b
            }
        }

        let connRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connRes == 0 else { return false }

        let payload = encodeHandoffMessage(arguments: arguments)
        let wrote = payload.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < payload.count {
                let n = send(fd, base.advanced(by: offset), payload.count - offset, 0)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard wrote else { return false }

        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var ack: UInt8 = 0
        let got = recv(fd, &ack, 1, 0)
        return got == 1 && ack == acceptedByte
    }

    private static func acceptLoop(listenFD: Int32) {
        while true {
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFD, &clientAddr, &clientLen)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            readAndDispatch(clientFD: client)
            _ = close(client)
        }
    }

    private static func readAndDispatch(clientFD: Int32) {
        func readExact(_ count: Int) -> [UInt8]? {
            var buf = [UInt8](repeating: 0, count: count)
            var offset = 0
            while offset < count {
                let n = buf.withUnsafeMutableBytes { raw in
                    recv(clientFD, raw.baseAddress!.advanced(by: offset), count - offset, 0)
                }
                if n <= 0 { return nil }
                offset += n
            }
            return buf
        }

        guard let header = readExact(magicPrefix.count), header == magicPrefix else { return }
        guard let lenBytes = readExact(4) else { return }
        let bodyLen = Int(
            UInt32(lenBytes[0])
                | (UInt32(lenBytes[1]) << 8)
                | (UInt32(lenBytes[2]) << 16)
                | (UInt32(lenBytes[3]) << 24)
        )
        guard bodyLen <= maxMessageBytes else { return }
        let body = bodyLen > 0 ? (readExact(bodyLen) ?? []) : []
        let args = decodeHandoffArguments(body) ?? []
        var ack = acceptedByte
        _ = send(clientFD, &ack, 1, 0)
        handleForwardedArguments(args)
    }
    #endif
}
