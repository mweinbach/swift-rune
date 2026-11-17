#if os(macOS) || os(Linux) || os(Windows) || (canImport(UIKit) && !os(watchOS))
import Foundation
import Dispatch
#if canImport(QuartzCore)
import QuartzCore
#endif

/// Type-erased sampling for a window group containing different app state types.
internal protocol NativeTraceRuntime: AnyObject {
    var viewport: Vec2 { get }
    var pixelScale: Float { get }
    var surfaceMeter: SurfaceMeter? { get }
    func enableNativeTrace() -> () -> Void
    func writeNativeTrace(_ writer: ToolingTraceWriter, tMs: Double, cpuMs: Double, timing: TraceFrameTiming)
}

extension Runtime: NativeTraceRuntime {
    func enableNativeTrace() -> () -> Void {
        let enabledChannels = traceChannels == nil
        let previousLinkPolicy = urlOpener.headless
        if enabledChannels { traceChannels = [:] }
        urlOpener.headless = true
        return { [weak self] in
            guard let self else { return }
            if enabledChannels && !isTracing { traceChannels = nil }
            urlOpener.headless = previousLinkPolicy
        }
    }
    func writeNativeTrace(_ writer: ToolingTraceWriter, tMs: Double, cpuMs: Double, timing: TraceFrameTiming) {
        writer.frameTimed(runtime: self, tMs: tMs, cpuMs: cpuMs, timing: timing)
    }
}

/// The native GPU thread only publishes a drawable ID and timestamp. Element sampling,
/// JSON encoding and file I/O run elsewhere.
internal final class DrawablePresentLog: TracePresentSource, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(seq: UInt64, atNs: UInt64?)] = []

    func presented(_ sequence: UInt64, hostTime: Double) {
        let timestamp = hostTime > 0 ? UInt64(exactly: (hostTime * 1e9).rounded()) : nil
        lock.withLock { entries.append((sequence, timestamp)) }
    }

    func take() -> [(seq: UInt64, atNs: UInt64?)] {
        lock.withLock {
            let ready = entries
            entries = []
            return ready
        }
    }
}

/// AppKit terminates directly from its delegate. Keep the trace on disk while the window
/// is alive and drain the last submitted drawables while the window is still visible.
internal final class NativeWindowTrace {
    private let path: String
    private let all: Bool
    private let limit: Int?
    private let file: TraceFile
    private var writer: ToolingTraceWriter?
    private weak var runtime: (any NativeTraceRuntime)?
    private var restoreRuntime: (() -> Void)?
    private var start = 0.0
    private var frames = 0
    private var nextSequence: UInt64 = 0
    private var closed = false
    private var previousRequestedFrame = false

    let presents: DrawablePresentLog?
    var keepsDrawing: Bool { !closed && limit != nil }
    var reachedLimit: Bool { limit.map { frames >= $0 } ?? false }

    init?(args: ToolingArgs, recordsDrawables: Bool) throws {
        guard let path = args.tracePath else { return nil }
        self.path = path
        all = args.traceAll
        limit = args.frameCount
        presents = recordsDrawables ? DrawablePresentLog() : nil
        file = try TraceFile(path: path)
    }

    func begin(_ runtime: any NativeTraceRuntime, now: Double, refreshHz: @autoclosure () -> Double) {
        guard writer == nil, !closed else { return }
        start = now
        let hz = refreshHz()
        let trace = ToolingTraceWriter.openClock(path: path, viewport: runtime.viewport, fps: hz > 0 ? hz : 60,
                                                scale: runtime.pixelScale, traceAll: all, clock: .wall)
        if let presents { trace.recordPresents(source: presents, startNs: UInt64((now * 1e9).rounded())) }
        trace.streamLines(to: file.write)
        self.runtime = runtime
        restoreRuntime = runtime.enableNativeTrace()
        writer = trace
    }

    #if canImport(Metal) && canImport(QuartzCore) && !targetEnvironment(simulator)
    func track(_ drawable: CAMetalDrawable) -> UInt64? {
        guard let presents, !closed, !reachedLimit else { return nil }
        nextSequence &+= 1
        let sequence = nextSequence
        drawable.addPresentedHandler { drawable in
            presents.presented(sequence, hostTime: drawable.presentedTime)
        }
        return sequence
    }
    #endif

    func submitted(_ runtime: any NativeTraceRuntime, at time: Double, started: Double,
                   target: Double?, sequence: UInt64?, continuous: Bool) {
        guard let writer, !closed, !reachedLimit else { return }
        // A user event can restart animation after a long idle. The previous frame's
        // request determines whether the gap leading into this submit is cadence.
        let timing = TraceFrameTiming(targetMs: target.map { ($0 - start) * 1000 },
                                      drawable: sequence, continuous: previousRequestedFrame || keepsDrawing)
        previousRequestedFrame = continuous
        runtime.writeNativeTrace(writer, tMs: (time - start) * 1000,
                                 cpuMs: (time - started) * 1000, timing: timing)
        frames += 1
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Let Core Animation commit the final frame while an embedded app keeps servicing its run loop.
    @MainActor func finishAfterDisplay() async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(150))
        while writer?.awaitingPresentations == true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try finish(waitForPresents: 0)
    }
    #endif

    func stopSampling() {
        restoreRuntime?()
        restoreRuntime = nil
    }

    func finish(waitForPresents: Double = 0.150) throws {
        guard !closed else { return }
        closed = true
        stopSampling()
        try writer?.finish(waitForPresents: waitForPresents)
        try file.finish()
        var report = ""
        if let stats = runtime?.surfaceMeter?.currentStats() { report += "rune: frames \(stats.summary())\n" }
        if let summary = writer?.presentSummary { report += "\(summary.displayDescription)\n" }
        if !report.isEmpty { try? FileHandle.standardError.write(contentsOf: Data(report.utf8)) }
    }
}

/// Enqueue file writes off the rendering thread. The bound limits pending batches if
/// storage is slower than the trace producer for an extended period.
private final class TraceFile: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "rune.trace.output", qos: .utility)
    private let outstanding = DispatchSemaphore(value: 32)
    private var failure: Error? // Accessed only on queue.

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            try Data().write(to: url)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
    }

    func write(_ lines: [String]) {
        outstanding.wait()
        queue.async { [self] in
            defer { outstanding.signal() }
            guard failure == nil else { return }
            do { try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8)) }
            catch { failure = error }
        }
    }

    func finish() throws {
        try queue.sync {
            try handle.close()
            if let failure { throw failure }
        }
    }
}
#endif
