#if os(Linux) || os(macOS)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
import Darwin
#endif

/// The Unix transport for Rune's instance handoff. Only a socket's current owner removes its name.
final class UnixInstance: @unchecked Sendable {
    private static let ownersLock = NSLock()
    nonisolated(unsafe) private static var owners: [UnixInstance] = []
    private static let answerWithin = 0.05
    private static let reachFor = 5.0
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64

        init?(at path: String) {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
                  info.st_uid == getuid() else { return nil }
            device = UInt64(truncatingIfNeeded: info.st_dev)
            inode = UInt64(info.st_ino)
        }
    }

    private struct Endpoint {
        let path: String
        private let claimLock: String
        private let ownerLock: String
        private let address: sockaddr_un

        init?(id: String, directory: String?) {
            let clean = id.unicodeScalars.map { scalar -> String in
                let allowed = scalar.isASCII && (Character(scalar).isLetter || Character(scalar).isNumber ||
                    scalar == "." || scalar == "-" || scalar == "_")
                return allowed ? String(scalar) : "-"
            }.joined()
            let dir: String
            if let directory, !directory.isEmpty {
                dir = directory
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
            } else if let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"],
                      runtime.hasPrefix("/"), Self.privateDirectory(runtime) {
                dir = runtime
            } else {
                dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rune-\(getuid())").path
                guard mkdir(dir, 0o700) == 0 || errno == EEXIST,
                      Self.privateDirectory(dir, disallowed: 0o077) else { return nil }
            }
            guard Self.privateDirectory(dir) else { return nil }
            let base = URL(fileURLWithPath: dir).appendingPathComponent("rune-instance-\(clean)")
            path = base.appendingPathExtension("sock").path
            claimLock = base.appendingPathExtension("lock").path
            ownerLock = base.appendingPathExtension("owner-lock").path
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = path.utf8
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
            withUnsafeMutableBytes(of: &addr.sun_path) { destination in
                destination.copyBytes(from: bytes)
            }
            address = addr
        }

        private static func privateDirectory(_ path: String, disallowed: mode_t = 0o022) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR &&
                info.st_uid == getuid() && info.st_mode & disallowed == 0
        }

        func withAddress(_ perform: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
            withUnsafePointer(to: address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    perform($0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }

        // Never unlink the lock file. A waiter already holding its descriptor must
        // exclude a third process that opens it after the previous owner exits.
        func whileClaiming<T>(_ body: () -> T) -> T? {
            underLock(at: claimLock) { underLock(at: ownerLock, body) } ?? nil
        }

        func release(_ identity: Identity) {
            // A Rust successor keeps the shared claim lock while waiting for this
            // pathname to disappear. Serialize Swift pathname changes separately.
            _ = underLock(at: ownerLock) {
                if Identity(at: path) == identity { _ = unlink(path) }
            }
        }

        private func underLock<T>(at name: String, _ body: () -> T) -> T? {
            let lockFD = open(name, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard lockFD >= 0 else { return nil }
            defer { _ = close(lockFD) }
            while flock(lockFD, LOCK_EX) != 0 {
                if errno != EINTR { return nil }
            }
            return body()
        }
    }

    private enum Claim { case owner, delivered, retry, waitForPrevious, quitting(Identity) }
    private enum Forward { case delivered, quitting, unavailable }

    static func claim(id: String, arguments: [String], baseDirectory: String?) -> Bool {
        guard let endpoint = Endpoint(id: id, directory: baseDirectory) else { return true }
        let packet = SingleInstance.encodeHandoffMessage(arguments: arguments)
        let deadline = now + reachFor
        let handedDeadline = now + RelaunchController.maxWaitSeconds
        var abandoned: Identity?
        while true {
            let result = endpoint.whileClaiming { () -> Claim in
                let fd = socketFD()
                guard fd >= 0 else { return .owner }
                if endpoint.withAddress({ bind(fd, $0, $1) }) == 0 {
                    guard listen(fd, 16) == 0, let identity = Identity(at: endpoint.path),
                          let owner = UnixInstance(endpoint: endpoint, identity: identity, fd: fd) else {
                        _ = close(fd)
                        _ = unlink(endpoint.path)
                        return .owner
                    }
                    ownersLock.withLock { owners.append(owner) }
                    owner.start()
                    return .owner
                }
                let occupied = errno == EADDRINUSE
                _ = close(fd)
                guard occupied, !packet.isEmpty else { return .owner }
                guard let identity = Identity(at: endpoint.path) else {
                    // A dead listener can vanish between bind and stat. Leave unrelated files alone.
                    return access(endpoint.path, F_OK) == 0 || now >= deadline ? .owner : .retry
                }
                if let pid = RelaunchController.handedFrom, now < handedDeadline,
                   RelaunchController.isProcessAlive(pid) { return .waitForPrevious }
                if abandoned != identity {
                    switch forward(packet, to: endpoint) {
                    case .delivered: return .delivered
                    case .quitting: return .quitting(identity)
                    case .unavailable: break
                    }
                }
                // Refused (the owner died) or unresponsive. Claims and releases
                // hold the same advisory lock while comparing and removing the pathname.
                if Identity(at: endpoint.path) == identity, unlink(endpoint.path) != 0 { return .owner }
                return .retry
            }
            switch result {
            case .none, .owner: return true
            case .delivered: return false
            case .retry: continue
            case .waitForPrevious: Thread.sleep(forTimeInterval: 0.001)
            case .quitting(let identity):
                // The old owner must be able to acquire the lock and release its socket.
                let until = now + RelaunchController.maxWaitSeconds
                while Identity(at: endpoint.path) == identity && now < until {
                    let probe = socketFD()
                    guard probe >= 0 else { break }
                    setTimeout(probe, option: SO_SNDTIMEO, seconds: answerWithin)
                    let gone = endpoint.withAddress { connect(probe, $0, $1) } != 0 &&
                        (errno == ENOENT || errno == ECONNREFUSED)
                    _ = close(probe)
                    if gone { break }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                abandoned = identity
            }
        }
    }

    static func release() {
        let active = ownersLock.withLock {
            let active = owners
            owners.removeAll()
            return active
        }
        for server in active { server.stop() }
    }

    private static func socketFD() -> Int32 {
        #if os(Linux)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        if fd >= 0 { configure(fd) }
        return fd
    }

    private static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        #if os(macOS)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout.size(ofValue: on)))
        #endif
    }

    private static func setTimeout(_ fd: Int32, option: Int32, seconds: TimeInterval) {
        let micros = Int(max(0.001, seconds) * 1_000_000)
        var tv = timeval(tv_sec: micros / 1_000_000, tv_usec: numericCast(micros % 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func writeBytes(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        #if os(Linux)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        return bytes.withUnsafeBytes { buf in
            guard let start = buf.baseAddress else { return false }
            var offset = 0
            while offset < buf.count {
                let n = send(fd, start.advanced(by: offset), buf.count - offset, flags)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    private static func readBytes(_ fd: Int32, count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let complete = bytes.withUnsafeMutableBytes { buf in
            var offset = 0
            while offset < count {
                let n = recv(fd, buf.baseAddress!.advanced(by: offset), count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        return complete ? bytes : nil
    }

    private static func forward(_ packet: [UInt8], to endpoint: Endpoint) -> Forward {
        let fd = socketFD()
        guard fd >= 0 else { return .unavailable }
        defer { _ = close(fd) }
        let deadline = now + answerWithin
        setTimeout(fd, option: SO_SNDTIMEO, seconds: answerWithin)
        guard !packet.isEmpty, endpoint.withAddress({ connect(fd, $0, $1) }) == 0,
              writeBytes(fd, packet) else { return .unavailable }
        setTimeout(fd, option: SO_RCVTIMEO, seconds: deadline - now)
        switch readBytes(fd, count: 1)?.first {
        case SingleInstance.acceptedByte: return .delivered
        case SingleInstance.quittingByte: return .quitting
        default: return .unavailable
        }
    }

    private let endpoint: Endpoint
    private let identity: Identity
    private let listenFD: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let lifecycle = NSCondition()
    private var worker: Thread?
    private var activeClient: Int32 = -1
    private var stopping = false

    private init?(endpoint: Endpoint, identity: Identity, fd: Int32) {
        var wake = [Int32](repeating: -1, count: 2)
        guard pipe(&wake) == 0 else { return nil }
        self.endpoint = endpoint
        self.identity = identity
        self.listenFD = fd
        wakeRead = wake[0]
        wakeWrite = wake[1]
        _ = fcntl(wakeRead, F_SETFD, FD_CLOEXEC)
        _ = fcntl(wakeWrite, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    deinit {
        _ = close(listenFD)
        _ = close(wakeRead)
        _ = close(wakeWrite)
    }

    private func start() {
        lifecycle.lock()
        let thread = Thread { self.serve() }
        thread.name = "rune-instance"
        worker = thread
        thread.start()
        lifecycle.unlock()
    }

    private func stop() {
        lifecycle.lock()
        stopping = true
        var wake: UInt8 = 1
        _ = write(wakeWrite, &wake, 1)
        if activeClient >= 0 { _ = shutdown(activeClient, Int32(SHUT_RDWR)) }
        let fromWorker = worker === Thread.current
        lifecycle.unlock()
        endpoint.release(identity)
        if !fromWorker {
            lifecycle.lock()
            while worker != nil { lifecycle.wait() }
            lifecycle.unlock()
        }
    }

    private func serve() {
        defer {
            lifecycle.lock()
            worker = nil
            lifecycle.broadcast()
            lifecycle.unlock()
        }
        var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
        while true {
            if poll(&fds, 2, -1) < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 { return }
            let client = accept(listenFD, nil, nil)
            if client < 0 { continue }
            Self.configure(client)
            Self.setTimeout(client, option: SO_RCVTIMEO, seconds: 1)
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            lifecycle.lock()
            if stopping {
                lifecycle.unlock()
                _ = close(client)
                return
            }
            activeClient = client
            lifecycle.unlock()

            readAndDispatch(client)

            lifecycle.lock()
            activeClient = -1
            _ = close(client)
            lifecycle.unlock()
        }
    }

    private func readAndDispatch(_ fd: Int32) {
        let magic = SingleInstance.magicPrefix
        guard let header = Self.readBytes(fd, count: magic.count + 4), header.starts(with: magic) else { return }
        let size = header.suffix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard size <= SingleInstance.maxMessageBytes, let body = Self.readBytes(fd, count: Int(size)),
              let args = SingleInstance.decodeHandoffArguments(body) else { return }
        let quitting = QuitLifecycle.isQuitting || InstanceLaunches.shared.loopExited
        let answered = Self.writeBytes(fd, [quitting ? SingleInstance.quittingByte : SingleInstance.acceptedByte])
        if answered && !quitting { SingleInstance.handleForwardedArguments(args) }
    }
}
#endif
