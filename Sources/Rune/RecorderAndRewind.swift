import Foundation
import RuneMotion

// MARK: - 1. Audio Recorder Backwards-Compatible Wrapper

extension RecordFormat {
    public var fileExtension: String {
        switch self {
        case .aac: return "m4a"
        case .wav: return "wav"
        }
    }
}

public struct AudioLevel: Sendable, Equatable {
    public var rms: Float
    public var peak: Float
    public var smoothed: Float

    public init(rms: Float = 0, peak: Float = 0, smoothed: Float = 0) {
        self.rms = rms
        self.peak = peak
        self.smoothed = smoothed
    }

    public init(level: Level) {
        let rmsLin = level.rmsDB() > RecorderMeterConstants.floorDB ? powf(10.0, level.rmsDB() / 20.0) : 0.0
        let peakLin = level.peakDB() > RecorderMeterConstants.floorDB ? powf(10.0, level.peakDB() / 20.0) : 0.0
        self.rms = rmsLin
        self.peak = peakLin
        self.smoothed = level.meter()
    }
}

public struct RecordingResult: Sendable, Equatable {
    public let url: URL
    public let durationSeconds: Double
    public let format: RecordFormat
    public let sizeBytes: UInt64

    public init(url: URL, durationSeconds: Double, format: RecordFormat, sizeBytes: UInt64) {
        self.url = url
        self.durationSeconds = durationSeconds
        self.format = format
        self.sizeBytes = sizeBytes
    }
}

/// Convenience wrapper around `Recorder` preserving legacy `AudioRecorder` callers.
public final class AudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: Recorder?
    private var _format: RecordFormat = .wav
    private var _headlessClock: Double = 0.0
    private var fakeMic: FakeMicrophone?

    public init(fakeMicrophone: FakeMicrophone? = nil) {
        self.fakeMic = fakeMicrophone
    }

    public var state: RecorderState {
        lock.withLock { recorder }?.state() ?? .idle
    }

    public var level: AudioLevel {
        guard let rec = lock.withLock({ recorder }) else { return AudioLevel() }
        return AudioLevel(level: rec.level())
    }

    public var elapsedSeconds: Double {
        lock.withLock { recorder }?.elapsed() ?? 0.0
    }

    public func start(outputURL: URL, format: RecordFormat = .wav) {
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var rec = Recorder.toFile(outputURL).format(format)
        if let mic = fakeMic {
            rec = rec.fake(mic)
        }
        lock.withLock {
            _format = format
            _headlessClock = 0.0
            recorder = rec
        }
        if fakeMic != nil || !MediaPlaybackGate.isEnabled {
            HeadlessClock.set(0.0)
            Recorder.headlessReset()
        }
        rec.start()
    }

    public func advanceHeadless(deltaSeconds: Double) {
        guard deltaSeconds > 0 else { return }
        let rec = lock.withLock { () -> Recorder? in
            _headlessClock += deltaSeconds
            return recorder
        }
        HeadlessClock.set(lock.withLock { _headlessClock })
        Recorder.headlessFrame(clock: lock.withLock { _headlessClock })
        _ = rec?.level()
    }

    public func pause() {
        lock.withLock { recorder }?.pause()
    }

    public func resume() {
        lock.withLock { recorder }?.resume()
    }

    public func stop() throws -> RecordingResult {
        guard let rec = lock.withLock({ recorder }) else {
            throw NSError(domain: "RuneRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "not recording"])
        }
        let fmt = lock.withLock { _format }
        switch rec.stop() {
        case .success(let recording):
            let attrs = try? FileManager.default.attributesOfItem(atPath: recording.url.path)
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            return RecordingResult(url: recording.url, durationSeconds: recording.duration, format: fmt, sizeBytes: size)
        case .failure(let msg):
            throw NSError(domain: "RuneRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: msg.message])
        }
    }

    public func cancel() {
        lock.withLock { recorder }?.cancel()
    }
}

// MARK: - 2. Deterministic Flight Event Recorder & Replay

public struct FlightEventRecord: Sendable, Equatable, Codable {
    public var timestampSeconds: Double
    public var kind: String
    public var payload: [String: String]

    public init(timestampSeconds: Double, kind: String, payload: [String: String] = [:]) {
        self.timestampSeconds = timestampSeconds
        self.kind = kind
        self.payload = payload
    }
}

/// Deterministic event + timestamp flight recorder with JSON serialization & replay.
public final class FlightRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [FlightEventRecord] = []
    public var isRecording: Bool = true

    public init() {}

    public func record(kind: String, at timestampSeconds: Double, payload: [String: String] = [:]) {
        lock.withLock {
            guard isRecording else { return }
            _events.append(FlightEventRecord(timestampSeconds: timestampSeconds, kind: kind, payload: payload))
        }
    }

    public var events: [FlightEventRecord] {
        lock.withLock { _events }
    }

    public func clear() {
        lock.withLock { _events.removeAll() }
    }

    public func exportJSON() throws -> Data {
        let snap = lock.withLock { _events }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snap)
    }

    public static func importJSON(_ data: Data) throws -> FlightRecorder {
        let decoded = try JSONDecoder().decode([FlightEventRecord].self, from: data)
        let rec = FlightRecorder()
        rec._events = decoded
        return rec
    }

    public func replay(_ handler: (FlightEventRecord) -> Void) {
        let snap = lock.withLock { _events.sorted { $0.timestampSeconds < $1.timestampSeconds } }
        for ev in snap {
            handler(ev)
        }
    }
}

// MARK: - 3. Rewind Frame/State Recorder & Scrubber

public struct RewindElementSnapshot: Sendable, Equatable, Codable {
    public var key: String
    public var left: Float
    public var top: Float
    public var right: Float
    public var bottom: Float
    public var opacity: Float

    public var rect: MotionRect {
        MotionRect(left: left, top: top, right: right, bottom: bottom)
    }

    public init(key: String, rect: MotionRect, opacity: Float) {
        self.key = key
        self.left = rect.left
        self.top = rect.top
        self.right = rect.right
        self.bottom = rect.bottom
        self.opacity = opacity
    }
}

public struct RewindFrame: Sendable, Equatable, Codable {
    public var index: Int
    public var timeSeconds: Double
    public var elements: [RewindElementSnapshot]

    public init(index: Int, timeSeconds: Double, elements: [RewindElementSnapshot]) {
        self.index = index
        self.timeSeconds = timeSeconds
        self.elements = elements
    }
}

public struct RewindChange: Sendable, Equatable {
    public let key: String
    public let fromRect: MotionRect?
    public let toRect: MotionRect?
    public let fromOpacity: Float?
    public let toOpacity: Float?
}

public struct RewindClip: Sendable, Equatable, Codable {
    public let frames: [RewindFrame]

    public var durationSeconds: Double {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return max(0, last.timeSeconds - first.timeSeconds)
    }

    public init(frames: [RewindFrame]) {
        self.frames = frames
    }

    public func changes(atFrame index: Int) -> [RewindChange] {
        guard index > 0, index < frames.count else { return [] }
        let prev = Dictionary(uniqueKeysWithValues: frames[index - 1].elements.map { ($0.key, $0) })
        let curr = Dictionary(uniqueKeysWithValues: frames[index].elements.map { ($0.key, $0) })
        let allKeys = Set(prev.keys).union(curr.keys).sorted()
        var out: [RewindChange] = []
        for k in allKeys {
            let p = prev[k]
            let c = curr[k]
            if p?.rect != c?.rect || p?.opacity != c?.opacity {
                out.append(RewindChange(
                    key: k,
                    fromRect: p?.rect,
                    toRect: c?.rect,
                    fromOpacity: p?.opacity,
                    toOpacity: c?.opacity
                ))
            }
        }
        return out
    }

    public func track(forKey key: String) -> [(timeSeconds: Double, rect: MotionRect, opacity: Float)] {
        frames.compactMap { frame in
            guard let el = frame.elements.first(where: { $0.key == key }) else { return nil }
            return (frame.timeSeconds, el.rect, el.opacity)
        }
    }

    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func importJSON(_ data: Data) throws -> RewindClip {
        try JSONDecoder().decode(RewindClip.self, from: data)
    }
}

/// Ring-buffered frame/state recorder (`rune::rewind::Rewind`).
public final class RewindRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [RewindFrame] = []
    private var nextIndex: Int = 0
    public var windowSeconds: Double
    public var maxBytes: Int
    public private(set) var isPaused: Bool = false

    public init(windowSeconds: Double = 60.0, maxBytes: Int = 24 * 1024 * 1024) {
        self.windowSeconds = max(0, windowSeconds)
        self.maxBytes = max(1024, maxBytes)
    }

    public var frameCount: Int { lock.withLock { frames.count } }

    public var estimatedBytes: Int {
        lock.withLock {
            frames.reduce(0) { $0 + 32 + $1.elements.count * 64 }
        }
    }

    public func recordFrame(at timeSeconds: Double, elements: [RewindElementSnapshot]) {
        lock.lock()
        defer { lock.unlock() }
        guard !isPaused else { return }
        frames.append(RewindFrame(index: nextIndex, timeSeconds: timeSeconds, elements: elements))
        nextIndex += 1
        pruneLocked(latestTime: timeSeconds)
    }

    private func pruneLocked(latestTime: Double) {
        let cutoff = latestTime - windowSeconds
        while frames.count > 1, let first = frames.first, first.timeSeconds < cutoff {
            frames.removeFirst()
        }
        while frames.count > 1, frames.reduce(0, { $0 + 32 + $1.elements.count * 64 }) > maxBytes {
            frames.removeFirst()
        }
    }

    public func freeze() -> RewindClip {
        lock.lock()
        isPaused = true
        let snap = frames
        lock.unlock()
        return RewindClip(frames: snap)
    }

    public func resume() {
        lock.withLock { isPaused = false }
    }
}

/// Interactive scrubber over a frozen `RewindClip` (`rune::rewind::Scrub`).
public final class RewindScrubber: @unchecked Sendable {
    public private(set) var isOpen: Bool = false
    public private(set) var clip: RewindClip?
    public private(set) var currentFrameIndex: Int = 0
    public var selectionStartFrame: Int = 0
    public var selectionEndFrame: Int = 0

    public init() {}

    public func open(_ recorder: RewindRecorder) {
        let frozen = recorder.freeze()
        self.clip = frozen
        self.isOpen = true
        let last = max(0, frozen.frames.count - 1)
        self.currentFrameIndex = last
        self.selectionStartFrame = 0
        self.selectionEndFrame = last
    }

    public func close(resuming recorder: RewindRecorder? = nil) {
        self.isOpen = false
        self.clip = nil
        recorder?.resume()
    }

    public var currentFrame: RewindFrame? {
        guard let clip, currentFrameIndex >= 0, currentFrameIndex < clip.frames.count else { return nil }
        return clip.frames[currentFrameIndex]
    }

    public func seek(toFrame index: Int) {
        guard let clip, !clip.frames.isEmpty else { return }
        currentFrameIndex = min(max(0, index), clip.frames.count - 1)
    }

    public func seek(toFraction fraction: Double) {
        guard let clip, !clip.frames.isEmpty else { return }
        let f = fraction.clamped(to: 0...1)
        let idx = Int((f * Double(clip.frames.count - 1)).rounded())
        seek(toFrame: idx)
    }

    public func stepForward() {
        seek(toFrame: currentFrameIndex + 1)
    }

    public func stepBackward() {
        seek(toFrame: currentFrameIndex - 1)
    }
}

// MARK: - 4. Hot Reload Watcher & ColdBox

/// Live file/directory watcher using `DispatchSourceFileSystemObject` (`rune::hot`).
public final class HotWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fileDescriptors: [Int32] = []
    private let queue = DispatchQueue(label: "rune.hot.watcher", qos: .utility)

    public init() {}

    deinit {
        stop()
    }

    public func watch(path: URL, onChange: @escaping @Sendable (URL) -> Void) -> Bool {
        let fd = open(path.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: queue
        )
        source.setEventHandler {
            onChange(path)
        }
        source.setCancelHandler {
            close(fd)
        }
        lock.withLock {
            fileDescriptors.append(fd)
            sources.append(source)
        }
        source.resume()
        return true
    }

    public func stop() {
        let toCancel = lock.withLock { () -> [DispatchSourceFileSystemObject] in
            let s = sources
            sources.removeAll()
            fileDescriptors.removeAll()
            return s
        }
        for s in toCancel {
            s.cancel()
        }
    }
}

/// Copy-on-write lazy storage box (`rune::cold::Cold<T>`).
public struct ColdBox<T: Sendable>: Sendable {
    private final class Storage: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private var storage: Storage?
    private let defaultValue: @Sendable () -> T

    public init(defaultValue: @escaping @Sendable () -> T) {
        self.defaultValue = defaultValue
    }

    public var isEmpty: Bool { storage == nil }

    public var value: T {
        storage?.value ?? defaultValue()
    }

    public mutating func mutate(_ body: (inout T) -> Void) {
        if storage == nil {
            storage = Storage(defaultValue())
        } else if !isKnownUniquelyReferenced(&storage) {
            storage = Storage(storage!.value)
        }
        body(&storage!.value)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
