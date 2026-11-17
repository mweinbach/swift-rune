import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
#endif

/// Configuration for `ProcwatchWatcher` (`crates/procwatch/src/lib.rs::Config`).
public struct ProcwatchConfig: Sendable, Equatable {
    public var every: TimeInterval
    public var report: TimeInterval?
    public var warnFootprint: UInt64
    public var warnGrowth: UInt64
    public var growthWindow: TimeInterval
    public var warnCpuCores: Double
    public var cpuWindow: TimeInterval
    public var name: String

    public init(
        every: TimeInterval,
        report: TimeInterval?,
        warnFootprint: UInt64,
        warnGrowth: UInt64,
        growthWindow: TimeInterval,
        warnCpuCores: Double,
        cpuWindow: TimeInterval,
        name: String
    ) {
        self.every = every
        self.report = report
        self.warnFootprint = warnFootprint
        self.warnGrowth = warnGrowth
        self.growthWindow = growthWindow
        self.warnCpuCores = warnCpuCores
        self.cpuWindow = cpuWindow
        self.name = name
    }

    /// Quiet in release builds: one status line an hour, plus warnings.
    public static func release(_ name: String) -> ProcwatchConfig {
        ProcwatchConfig(
            every: 10.0,
            report: 3600.0,
            warnFootprint: 1 << 30,
            warnGrowth: 256 << 20,
            growthWindow: 60.0,
            warnCpuCores: 0.8,
            cpuWindow: 60.0,
            name: name
        )
    }

    /// Chatty in dev builds: one status line a minute, lower thresholds.
    public static func dev(_ name: String) -> ProcwatchConfig {
        ProcwatchConfig(
            every: 2.0,
            report: 60.0,
            warnFootprint: 512 << 20,
            warnGrowth: 64 << 20,
            growthWindow: 20.0,
            warnCpuCores: 0.5,
            cpuWindow: 20.0,
            name: name
        )
    }
}

/// Kind of event emitted by `ProcwatchWatcher` (`crates/procwatch/src/lib.rs::Kind`).
public enum ProcwatchKind: Sendable, Equatable {
    case footprint
    case growth
    case cpu
    case report
}

/// Observation event produced by `ProcwatchWatcher` (`crates/procwatch/src/lib.rs::Event`).
public struct ProcwatchEvent: Sendable, Equatable, CustomStringConvertible {
    public var kind: ProcwatchKind
    public var line: String

    public init(kind: ProcwatchKind, line: String) {
        self.kind = kind
        self.line = line
    }

    public var isWarning: Bool {
        kind != .report
    }

    public var description: String {
        line
    }
}

/// Cooldown gate allowing at most one message per window (`crates/procwatch/src/lib.rs::Gate`).
public struct ProcwatchGate: Sendable {
    public private(set) var lastSeconds: TimeInterval?

    public init(lastSeconds: TimeInterval? = nil) {
        self.lastSeconds = lastSeconds
    }

    /// Returns `true` if `window` has elapsed since `lastSeconds` (or never emitted) and advances `lastSeconds`.
    public mutating func pass(now: TimeInterval, window: TimeInterval) -> Bool {
        let open: Bool
        if let last = lastSeconds {
            open = (now - last) >= window
        } else {
            open = true
        }
        if open {
            lastSeconds = now
        }
        return open
    }
}

/// Sample evaluator matching upstream `procwatch::Watcher`.
public final class ProcwatchWatcher: @unchecked Sendable {
    public var config: ProcwatchConfig
    private var history: [(at: TimeInterval, snapshot: ProcessSnapshot)] = []
    private var warnedFootprint: UInt64 = 0
    private var growthGate = ProcwatchGate()
    private var cpuGate = ProcwatchGate()
    private var reportGate = ProcwatchGate()

    public init(config: ProcwatchConfig) {
        self.config = config
    }

    /// Evaluates `snapshot` sampled at monotonic time `now` (in seconds).
    public func observe(now: TimeInterval, snapshot s: ProcessSnapshot) -> [ProcwatchEvent] {
        var out: [ProcwatchEvent] = []
        let keep = max(config.growthWindow, config.cpuWindow)
        if let edge = history.lastIndex(where: { (now - $0.at) >= keep }) {
            history.removeFirst(edge)
        }
        history.append((at: now, snapshot: s))

        func slice(window: TimeInterval) -> ArraySlice<(at: TimeInterval, snapshot: ProcessSnapshot)> {
            let start = history.lastIndex(where: { (now - $0.at) >= window }) ?? 0
            return history[start...]
        }

        let footprint = s.usage.footprintBytes ?? 0
        let footprintPeak = s.usage.footprintPeakBytes ?? 0

        let doubledThreshold = warnedFootprint > (UInt64.max / 2) ? UInt64.max : warnedFootprint * 2
        if footprint >= config.warnFootprint && footprint >= doubledThreshold {
            warnedFootprint = footprint
            out.append(
                ProcwatchEvent(
                    kind: .footprint,
                    line: "\(config.name): warning: footprint \(Procwatch.mb(footprint)) (peak \(Procwatch.mb(footprintPeak)))\(Self.memoryNote(s))"
                )
            )
        }

        let growthSlice = slice(window: config.growthWindow)
        if let first = growthSlice.first, (now - first.at) >= config.growthWindow * 0.9 {
            let rising = zip(growthSlice, growthSlice.dropFirst()).allSatisfy {
                ($0.1.snapshot.usage.footprintBytes ?? 0) >= ($0.0.snapshot.usage.footprintBytes ?? 0)
            }
            let firstFootprint = first.snapshot.usage.footprintBytes ?? 0
            let grew = footprint >= firstFootprint ? footprint - firstFootprint : 0
            if rising && grew >= config.warnGrowth && growthGate.pass(now: now, window: config.growthWindow) {
                out.append(
                    ProcwatchEvent(
                        kind: .growth,
                        line: String(
                            format: "%@: warning: footprint grew %@ in %.0fs to %@%@",
                            config.name,
                            Procwatch.mb(grew),
                            config.growthWindow,
                            Procwatch.mb(footprint),
                            Self.memoryNote(s)
                        )
                    )
                )
            }
        }

        let cpuSlice = slice(window: config.cpuWindow)
        if let old = cpuSlice.first {
            let span = now - old.at
            let cores = (s.usage.totalCpuSeconds - old.snapshot.usage.totalCpuSeconds) / max(span, 1e-9)
            if span >= config.cpuWindow * 0.9 && cores >= config.warnCpuCores && cpuGate.pass(now: now, window: config.cpuWindow) {
                let busy = Self.busiest(old: old.snapshot, new: s, span: span)
                out.append(
                    ProcwatchEvent(
                        kind: .cpu,
                        line: String(format: "%@: warning: %.0f%% CPU over %.0fs: %@", config.name, cores * 100.0, span, busy)
                    )
                )
            }
        }

        if let every = config.report, reportGate.pass(now: now, window: every) {
            out.append(
                ProcwatchEvent(
                    kind: .report,
                    line: String(
                        format: "%@: footprint %@ (peak %@), resident %@, CPU %.1fs (%.1fs in exited threads), %d threads, %u fds%@",
                        config.name,
                        Procwatch.mb(footprint),
                        Procwatch.mb(footprintPeak),
                        Procwatch.mb(s.usage.residentBytes),
                        s.usage.totalCpuSeconds,
                        s.exitedThreadCpuSeconds,
                        s.threads.count,
                        s.usage.openFDs ?? 0,
                        Self.memoryNote(s)
                    )
                )
            )
        }

        return out
    }

    /// Formats the top 4 busiest threads (and `"exited threads"` when >1% CPU) between `old` and `new`.
    public static func busiest(old: ProcessSnapshot, new: ProcessSnapshot, span: TimeInterval) -> String {
        var used: [(name: String, cpu: Double)] = new.threads.map { t in
            let before = old.threads.first(where: { $0.id == t.id })?.cpuSeconds ?? 0.0
            let name = t.name.isEmpty ? "unnamed" : t.name
            return (name: name, cpu: max(0.0, t.cpuSeconds - before))
        }
        let liveDeltaSum = used.reduce(0.0) { $0 + $1.cpu }
        let exited = (new.usage.totalCpuSeconds - old.usage.totalCpuSeconds) - liveDeltaSum
        if exited > 0.01 * span {
            used.append((name: "exited threads", cpu: exited))
        }
        used.sort { $0.cpu > $1.cpu }
        let safeSpan = max(span, 1e-9)
        return used
            .prefix(4)
            .filter { $0.cpu > 0.0 }
            .map { String(format: "%@ %.0f%%", $0.name, 100.0 * $0.cpu / safeSpan) }
            .joined(separator: ", ")
    }

    static func memoryNote(_ s: ProcessSnapshot) -> String {
        var note = ""
        if let h = s.heap {
            let live = UInt64(max(0, h.liveBytes))
            if h.bigBlocks > 0 {
                let bigLive = UInt64(max(0, h.bigLiveBytes))
                note += "; heap \(Procwatch.mb(live)) live, \(Procwatch.mb(bigLive)) in \(h.bigBlocks) big blocks, largest request \(Procwatch.mb(UInt64(max(0, h.largestBytes))))"
            } else {
                let peak = UInt64(max(0, h.peakBytes))
                note += "; heap \(Procwatch.mb(live)) live (peak \(Procwatch.mb(peak)))"
            }
        }
        let top = s.sortedGauges.filter { $0.bytes > 0 }.prefix(3).map { "\($0.name) \(Procwatch.mb(UInt64($0.bytes)))" }
        if !top.isEmpty {
            note += "; " + top.joined(separator: ", ")
        }
        if let bytes = s.unaccountedBytes {
            note += "; unaccounted \(Procwatch.mb(UInt64(max(0, bytes))))"
        }
        return note
    }
}

/// Top-level `procwatch` runtime helpers (`watch`, `watchWith`, `latest`, `mb`, `serve`).
public enum Procwatch {
    private static let latestLock = PortableLock<ProcessSnapshot?>(initialState: nil)

    /// Formats a byte count matching `procwatch::mb`.
    public static func mb(_ bytes: UInt64) -> String {
        if bytes >= (10 << 30) {
            return String(format: "%.0f GB", Double(bytes) / Double(1 << 30))
        } else if bytes >= (1 << 30) {
            return String(format: "%.1f GB", Double(bytes) / Double(1 << 30))
        } else {
            return String(format: "%.0f MB", Double(bytes) / Double(1 << 20))
        }
    }

    /// The watcher's last sampled snapshot, if `watch` / `watchWith` has started.
    public static func latest() -> ProcessSnapshot? {
        latestLock.withLock { $0 }
    }

    /// The current host process, if this platform exposes one.
    public static func snapshot() -> ProcessSnapshot? {
        ProcessSampler.snapshot()
    }

    /// Starts a background `procwatch` thread sampling every `config.every` and logging to stderr.
    public static func watch(_ config: ProcwatchConfig) {
        watchWith(config) { _, _ in }
    }

    /// Starts a background `procwatch` thread and invokes `onWarning` for every non-report warning.
    public static func watchWith(
        _ config: ProcwatchConfig,
        onWarning: @escaping @Sendable (ProcwatchEvent, ProcessSnapshot) -> Void
    ) {
        #if !os(WASI)
        let initial = ProcessSampler.snapshot()
        guard initial.usage.residentBytes > 0 || initial.usage.footprintBytes != nil else { return }

        let thread = Thread {
            let watcher = ProcwatchWatcher(config: config)
            while true {
                let snap = ProcessSampler.snapshot()
                let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
                for event in watcher.observe(now: now, snapshot: snap) {
                    FileHandle.standardError.write(Data((event.line + "\n").utf8))
                    if event.isWarning {
                        onWarning(event, snap)
                    }
                }
                latestLock.withLock { $0 = snap }
                Thread.sleep(forTimeInterval: max(0.05, watcher.config.every))
            }
        }
        thread.name = "procwatch"
        thread.start()
        #endif
    }

    /// Serves fresh `ProcessSnapshot.toJSON()` HTTP responses on loopback `127.0.0.1:port` (port 0 = ephemeral).
    /// Returns the bound port.
    @discardableResult
    public static func serve(port: UInt16 = 0) throws -> UInt16 {
        #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(Linux) || os(Windows)
        #if os(Windows)
        var winsock = WSADATA()
        let startup = WSAStartup(0x0202, &winsock)
        guard startup == 0 else { throw PerfRecorderError.io("WSAStartup failed with error \(startup)") }
        let sock = WinSDK.socket(AF_INET, SOCK_STREAM, 0)
        #elseif canImport(Darwin)
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #elseif canImport(Glibc)
        let sock = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #elseif canImport(Musl)
        let sock = Musl.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard sock != invalidSocket else {
            #if os(Windows)
            WSACleanup()
            #endif
            throw PerfRecorderError.io("socket creation failed")
        }

        #if os(Windows)
        // The Windows SDK defines SO_EXCLUSIVEADDRUSE as the bitwise complement of SO_REUSEADDR.
        let bindOption = ~Int32(SO_REUSEADDR)
        #else
        let bindOption = SO_REUSEADDR
        #endif
        let optionResult = withUnsafeBytes(of: Int32(1)) { bytes in
            setsockopt(sock, SOL_SOCKET, bindOption, bytes.baseAddress!.assumingMemoryBound(to: CChar.self), SocketLength(bytes.count))
        }
        guard optionResult == 0 else {
            closeListener(sock)
            throw PerfRecorderError.io("setting socket bind option failed")
        }

        var addr = sockaddr_in()
        addr.sin_family = numericCast(AF_INET)
        addr.sin_port = port.bigEndian
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let addressLength = SocketLength(MemoryLayout<sockaddr_in>.size)
        guard inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) == 1 else {
            closeListener(sock)
            throw PerfRecorderError.io("could not initialize loopback address")
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, addressLength) }
        }
        guard bindResult == 0 else {
            closeListener(sock)
            throw PerfRecorderError.io("bind failed on 127.0.0.1:\(port)")
        }

        var boundAddr = sockaddr_in()
        var addrLen = addressLength
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &addrLen) }
        }
        guard nameResult == 0, listen(sock, 16) == 0 else {
            closeListener(sock)
            throw PerfRecorderError.io("listen failed")
        }

        let thread = Thread {
            defer { closeListener(sock) }
            while true {
                var peer = sockaddr_in()
                var peerLen = addressLength
                let client = withUnsafeMutablePointer(to: &peer) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(sock, $0, &peerLen) }
                }
                guard client != invalidSocket else {
                    #if os(Windows)
                    let error = WSAGetLastError()
                    if error == WSAENOTSOCK || error == WSAEINVAL || error == WSANOTINITIALISED { return }
                    #else
                    if errno == EBADF || errno == EINVAL || errno == ENOTSOCK { return }
                    #endif
                    // A transient resource error must leave this process-wide listener available.
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }
                defer { closeSocket(client) }
                if withUnsafeBytes(of: peer.sin_addr, { $0.first == 127 }) {
                    sendSnapshot(to: client)
                }
            }
        }
        thread.name = "procwatch-http"
        thread.start()
        return UInt16(bigEndian: boundAddr.sin_port)
        #else
        throw PerfRecorderError.io("procwatch HTTP server unsupported on this platform")
        #endif
    }

    #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(Linux) || os(Windows)
    #if os(Windows)
    private typealias Socket = SOCKET
    private typealias SocketLength = Int32
    private static let invalidSocket = INVALID_SOCKET
    #else
    private typealias Socket = Int32
    private typealias SocketLength = socklen_t
    private static let invalidSocket: Int32 = -1
    #endif

    private static func closeSocket(_ sock: Socket) {
        #if os(Windows)
        closesocket(sock)
        #else
        close(sock)
        #endif
    }

    private static func closeListener(_ sock: Socket) {
        closeSocket(sock)
        #if os(Windows)
        WSACleanup()
        #endif
    }

    private static func sendSnapshot(to client: Socket) {
        #if os(Windows)
        let timeout: DWORD = 1_000
        #else
        let timeout = timeval(tv_sec: 1, tv_usec: 0)
        #endif
        withUnsafeBytes(of: timeout) { bytes in
            let value = bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
            for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
                _ = setsockopt(client, SOL_SOCKET, option, value, SocketLength(bytes.count))
            }
        }
        var request = [CChar](repeating: 0, count: 1024)
        guard recv(client, &request, 1024, 0) > 0 else { return }

        #if canImport(Darwin)
        var enabled: Int32 = 1
        guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, SocketLength(MemoryLayout<Int32>.size)) == 0 else { return }
        #endif
        #if os(Linux)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        let body = ProcessSampler.snapshot().toJSON()
        let response = "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: \(body.utf8.count)\r\nconnection: close\r\n\r\n\(body)"
        let bytes = response.utf8CString
        bytes.withUnsafeBufferPointer { buffer in
            var offset = 0
            let count = buffer.count - 1 // Exclude the C string terminator.
            while offset < count {
                let length = min(count - offset, Int(Int32.max))
                let written = send(client, buffer.baseAddress!.advanced(by: offset), numericCast(length), flags)
                if written < 0 {
                    #if os(Windows)
                    if WSAGetLastError() == WSAEINTR { continue }
                    #else
                    if errno == EINTR { continue }
                    #endif
                }
                guard written > 0 else { return }
                offset += Int(written)
            }
        }
    }
    #endif
}
