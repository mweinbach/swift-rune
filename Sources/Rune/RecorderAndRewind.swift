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
    public let id: UInt32
    public let key: String
    public let fromRect: MotionRect?
    public let toRect: MotionRect?
    public let fromOpacity: Float?
    public let toOpacity: Float?
    public let jump: Bool

    public init(
        id: UInt32 = 0,
        key: String,
        fromRect: MotionRect?,
        toRect: MotionRect?,
        fromOpacity: Float?,
        toOpacity: Float?,
        jump: Bool = false
    ) {
        self.id = id
        self.key = key
        self.fromRect = fromRect
        self.toRect = toRect
        self.fromOpacity = fromOpacity
        self.toOpacity = toOpacity
        self.jump = jump
    }

    /// Points moved (largest edge displacement); `0` when appearing or disappearing (`Change::distance`).
    public var distance: Float {
        guard let a = fromRect, let b = toRect else { return 0 }
        return Self.edgeDistance(a, b)
    }

    static func edgeDistance(_ a: MotionRect, _ b: MotionRect) -> Float {
        max(
            abs(a.left - b.left),
            max(
                abs(a.top - b.top),
                max(abs(a.right - b.right), abs(a.bottom - b.bottom))
            )
        )
    }

    /// Short human-readable summary: e.g. `title ↓7.5 pt` (`Change::label`).
    public func label() -> String {
        guard let a = fromRect, let b = toRect else {
            return "\(key) \(toRect != nil ? "appears" : "goes")"
        }
        func fmtDelta(_ x: Float) -> String {
            abs(x) >= 10.0 ? String(format: "%.0f", abs(x)) : String(format: "%.1f", abs(x))
        }
        var parts: [String] = []
        let dx = b.left - a.left
        let dy = b.top - a.top
        let dw = b.width - a.width
        let dh = b.height - a.height
        if abs(dy) >= 0.05 { parts.append("\(dy > 0 ? "↓" : "↑")\(fmtDelta(dy))") }
        if abs(dx) >= 0.05 { parts.append("\(dx > 0 ? "→" : "←")\(fmtDelta(dx))") }
        if abs(dw) >= 0.05 { parts.append("w \(dw > 0 ? "+" : "−")\(fmtDelta(dw))") }
        if abs(dh) >= 0.05 { parts.append("h \(dh > 0 ? "+" : "−")\(fmtDelta(dh))") }
        var out = key
        if !parts.isEmpty {
            out += " \(parts.joined(separator: " ")) pt"
        }
        if let fo = fromOpacity, let to = toOpacity, abs(to - fo) >= 0.005 {
            out += String(format: " %.2f→%.2f", fo, to)
        }
        return out
    }
}

public struct RewindClip: Sendable, Equatable, Codable {
    public let frames: [RewindFrame]
    public let viewportWidth: Float
    public let viewportHeight: Float
    public let names: [String]
    public let activity: [Float]
    public let jumps: [[UInt32]]

    public var viewport: Vec2 { Vec2(viewportWidth, viewportHeight) }
    public var len: Int { frames.count }
    public var isEmpty: Bool { frames.isEmpty }

    public var durationSeconds: Double {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return max(0, last.timeSeconds - first.timeSeconds)
    }

    public var duration: Double { durationSeconds }

    public init(frames: [RewindFrame], viewport: Vec2 = Vec2(800, 600)) {
        self.frames = frames
        self.viewportWidth = viewport.x
        self.viewportHeight = viewport.y
        let indexed = Self.buildIndex(frames: frames)
        self.names = indexed.names
        self.activity = indexed.activity
        self.jumps = indexed.jumps
    }

    private enum CodingKeys: String, CodingKey {
        case frames
        case viewportWidth
        case viewportHeight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let frames = try container.decode([RewindFrame].self, forKey: .frames)
        let vw = try container.decodeIfPresent(Float.self, forKey: .viewportWidth) ?? 800
        let vh = try container.decodeIfPresent(Float.self, forKey: .viewportHeight) ?? 600
        self.init(frames: frames, viewport: Vec2(vw, vh))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frames, forKey: .frames)
        try container.encode(viewportWidth, forKey: .viewportWidth)
        try container.encode(viewportHeight, forKey: .viewportHeight)
    }

    /// Time of frame `k` relative to the clip end (`<= 0.0`, matching `Clip::time`).
    public func time(_ index: Int) -> Double {
        guard index >= 0, index < frames.count, let last = frames.last else { return 0 }
        return frames[index].timeSeconds - last.timeSeconds
    }

    /// Largest move of any element in frame `k` (`0.25` when only opacity changed).
    public func activity(_ index: Int) -> Float {
        guard index >= 0, index < activity.count else { return 0 }
        return activity[index]
    }

    public func hasJump(_ index: Int) -> Bool {
        guard index >= 0, index < jumps.count else { return false }
        return !jumps[index].isEmpty
    }

    public func name(_ id: UInt32) -> String {
        let idx = Int(id)
        return (idx >= 0 && idx < names.count) ? names[idx] : ""
    }

    public func id(forKey key: String) -> UInt32? {
        names.firstIndex(of: key).map { UInt32($0) }
    }

    /// All elements on screen at frame `k` (`Clip::frame`).
    public func frame(_ index: Int) -> [(id: UInt32, snapshot: RewindElementSnapshot)] {
        guard index >= 0, index < frames.count else { return [] }
        var nameToId: [String: UInt32] = [:]
        for (i, n) in names.enumerated() { nameToId[n] = UInt32(i) }
        return frames[index].elements.compactMap { el in
            guard let id = nameToId[el.key] else { return nil }
            return (id, el)
        }
    }

    func frameBefore(_ index: Int) -> [(id: UInt32, snapshot: RewindElementSnapshot)] {
        guard index > 0 else { return [] }
        return frame(index - 1)
    }

    public func changes(atFrame index: Int) -> [RewindChange] {
        guard index > 0, index < frames.count else { return [] }
        let prev = Dictionary(uniqueKeysWithValues: frames[index - 1].elements.map { ($0.key, $0) })
        let curr = Dictionary(uniqueKeysWithValues: frames[index].elements.map { ($0.key, $0) })
        var nameToId: [String: UInt32] = [:]
        for (i, n) in names.enumerated() { nameToId[n] = UInt32(i) }
        let jumpSet = Set(jumps[index])
        let allKeys = Set(prev.keys).union(curr.keys).sorted()
        var out: [RewindChange] = []
        for k in allKeys {
            let p = prev[k]
            let c = curr[k]
            if p?.rect != c?.rect || p?.opacity != c?.opacity {
                let id = nameToId[k] ?? 0
                out.append(RewindChange(
                    id: id,
                    key: k,
                    fromRect: p?.rect,
                    toRect: c?.rect,
                    fromOpacity: p?.opacity,
                    toOpacity: c?.opacity,
                    jump: jumpSet.contains(id)
                ))
            }
        }
        out.sort { lhs, rhs in
            if lhs.jump != rhs.jump { return lhs.jump && !rhs.jump }
            return lhs.distance > rhs.distance
        }
        return out
    }

    /// Convenience upstream alias matching `clip.changes(k)`.
    public func changes(_ index: Int) -> [RewindChange] {
        changes(atFrame: index)
    }

    /// Where element `id` was in each frame of `range` (`Clip::path`).
    public func path(id: UInt32, range: Range<Int>) -> [(frame: Int, snapshot: RewindElementSnapshot)] {
        let key = name(id)
        guard !key.isEmpty else { return [] }
        let start = min(max(0, range.lowerBound), frames.count)
        let end = min(max(start, range.upperBound), frames.count)
        var out: [(Int, RewindElementSnapshot)] = []
        for k in start..<end {
            if let el = frames[k].elements.first(where: { $0.key == key }) {
                out.append((k, el))
            }
        }
        return out
    }

    /// Next frame from `k` in direction `step` (`±1`) where activity > 0 (`Clip::next_active`).
    public func nextActive(from index: Int, step: Int) -> Int? {
        guard step != 0 else { return nil }
        var i = index + step
        while i >= 0 && i < frames.count {
            if activity(i) > 0 { return i }
            i += step
        }
        return nil
    }

    public func track(forKey key: String) -> [(timeSeconds: Double, rect: MotionRect, opacity: Float)] {
        frames.compactMap { frame in
            guard let el = frame.elements.first(where: { $0.key == key }) else { return nil }
            return (frame.timeSeconds, el.rect, el.opacity)
        }
    }

    private static func buildIndex(frames: [RewindFrame]) -> (names: [String], activity: [Float], jumps: [[UInt32]]) {
        var names: [String] = []
        var nameToId: [String: UInt32] = [:]
        for f in frames {
            for el in f.elements where nameToId[el.key] == nil {
                nameToId[el.key] = UInt32(names.count)
                names.append(el.key)
            }
        }

        let n = frames.count
        var activity = [Float](repeating: 0, count: n)
        // Per frame: [(id, dist, before, after)]
        var moved: [[(id: UInt32, dist: Float, before: MotionRect, after: MotionRect)]] = Array(repeating: [], count: n)

        for k in 1..<n {
            let prev = Dictionary(uniqueKeysWithValues: frames[k - 1].elements.map { ($0.key, $0) })
            let curr = Dictionary(uniqueKeysWithValues: frames[k].elements.map { ($0.key, $0) })
            var most: Float = 0
            var faded = false
            for (key, c) in curr {
                guard let p = prev[key], let id = nameToId[key] else { continue }
                let d = RewindChange.edgeDistance(p.rect, c.rect)
                if d > 0 {
                    moved[k].append((id, d, p.rect, c.rect))
                    most = max(most, d)
                }
                if abs(p.opacity - c.opacity) >= 1e-4 {
                    faded = true
                }
            }
            activity[k] = (most == 0 && faded) ? 0.25 : most
        }

        func findMove(_ k: Int, _ id: UInt32) -> (id: UInt32, dist: Float, before: MotionRect, after: MotionRect)? {
            guard k >= 0, k < n else { return nil }
            return moved[k].first { $0.id == id }
        }

        var jumps: [[UInt32]] = Array(repeating: [], count: n)
        for k in 0..<n {
            var frameJumps: [UInt32] = []
            for m in moved[k] {
                let prevD = findMove(k - 1, m.id)?.dist ?? 0
                let nextMove = findMove(k + 1, m.id)
                let nextD = nextMove?.dist ?? 0
                let near = max(prevD, nextD)
                let back = nextMove.map { RewindChange.edgeDistance($0.after, m.before) < 0.5 } ?? false
                if m.dist >= 4.0 && (m.dist > 2.5 * near || back) {
                    frameJumps.append(m.id)
                }
            }
            jumps[k] = frameJumps
        }
        return (names, activity, jumps)
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
    public private(set) var viewport: Vec2 = Vec2(800, 600)
    public private(set) var isPaused: Bool = false

    public init(windowSeconds: Double = 60.0, maxBytes: Int = 24 * 1024 * 1024) {
        self.windowSeconds = max(0, windowSeconds)
        self.maxBytes = max(1024, maxBytes)
    }

    /// Builder-style window duration (`Rewind::seconds`).
    @discardableResult
    public func seconds(_ s: Double) -> Self {
        lock.withLock { windowSeconds = max(0, s) }
        return self
    }

    /// Builder-style memory budget (`Rewind::max_bytes`).
    @discardableResult
    public func maxBytes(_ bytes: Int) -> Self {
        lock.withLock { maxBytes = max(1024, bytes) }
        return self
    }

    public func setViewport(_ viewport: Vec2) {
        lock.withLock { self.viewport = viewport }
    }

    public var frameCount: Int { lock.withLock { frames.count } }

    /// Estimated byte size matching upstream `Rewind::bytes`.
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
        let cutoff = latestTime - windowSeconds - 1e-6
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
        let vp = viewport
        lock.unlock()
        return RewindClip(frames: snap, viewport: vp)
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
    var heldRecorder: RewindRecorder?
    var anchorFrame: Int?
    public var pickedId: UInt32?
    public var noteEdit = TextEdit("")

    public init() {}

    public func open(_ recorder: RewindRecorder) {
        if let prevHeld = heldRecorder, prevHeld !== recorder {
            prevHeld.resume()
        }
        let frozen = recorder.freeze()
        showClip(frozen, holding: recorder)
    }

    /// Shows `clip` while keeping any previously frozen recorder paused until `close()` (`Scrub::show`).
    public func show(_ clip: RewindClip) {
        showClip(clip, holding: heldRecorder)
    }

    private func showClip(_ clip: RewindClip, holding recorder: RewindRecorder?) {
        self.heldRecorder = recorder
        self.clip = clip
        self.isOpen = true
        let last = max(0, clip.frames.count - 1)
        let activeFrame: Int
        if clip.activity(last) > 0 {
            activeFrame = last
        } else {
            activeFrame = clip.nextActive(from: last, step: -1) ?? last
        }
        self.currentFrameIndex = activeFrame
        self.anchorFrame = nil
        self.pickedId = nil
        self.noteEdit = TextEdit("")
        self.selectionStartFrame = activeFrame
        self.selectionEndFrame = activeFrame
    }

    public func close(resuming recorder: RewindRecorder? = nil) {
        let toResume = recorder ?? heldRecorder
        self.heldRecorder = nil
        self.isOpen = false
        self.clip = nil
        self.anchorFrame = nil
        self.pickedId = nil
        toResume?.resume()
    }

    public var currentFrame: RewindFrame? {
        guard let clip, currentFrameIndex >= 0, currentFrameIndex < clip.frames.count else { return nil }
        return clip.frames[currentFrameIndex]
    }

    public func seek(toFrame index: Int) {
        seek(index, extend: false)
    }

    /// Shows frame `index`; with `extend == true`, grows the selection from the anchor (`Scrub::seek`).
    public func seek(_ index: Int, extend: Bool) {
        guard let clip, !clip.frames.isEmpty else { return }
        let clamped = min(max(0, index), clip.frames.count - 1)
        if extend {
            if anchorFrame == nil { anchorFrame = currentFrameIndex }
        } else {
            anchorFrame = nil
        }
        currentFrameIndex = clamped
        let a = anchorFrame ?? clamped
        selectionStartFrame = min(a, clamped)
        selectionEndFrame = max(a, clamped)
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
