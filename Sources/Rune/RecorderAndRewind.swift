import Foundation
import RuneMotion
#if !canImport(Darwin) && canImport(Dispatch)
import Synchronization
#endif

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
    /// Stable scene identity when the sample came from a Rune window.
    public var nodeID: UInt64?
    public var left: Float
    public var top: Float
    public var right: Float
    public var bottom: Float
    public var opacity: Float

    public var rect: MotionRect {
        MotionRect(left: left, top: top, right: right, bottom: bottom)
    }

    public init(key: String, rect: MotionRect, opacity: Float, nodeID: UInt64? = nil) {
        self.key = key
        self.nodeID = nodeID
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
    private typealias Q = RewindTape.Quantized
    private typealias Entry = (id: UInt32, value: Q)
    private static let stride = 64

    private let marks: ArraySlice<RewindTape.Mark>
    private let words: ArraySlice<UInt32>
    private let starts: [Int]
    private let checkpoints: [[Entry]]
    private let nodeIDs: [UInt64?]
    // Caller-provided frames can contain unquantized coordinates and arbitrary element order.
    private let authored: (frames: [RewindFrame], ids: [[UInt32]])?
    public let viewportWidth: Float
    public let viewportHeight: Float
    public let names: [String]
    public let activity: [Float]
    public let jumps: [[UInt32]]

    public var viewport: Vec2 { Vec2(viewportWidth, viewportHeight) }
    public var len: Int { marks.count }
    public var isEmpty: Bool { marks.isEmpty }
    public var durationSeconds: Double { max(0, -time(0)) }
    public var duration: Double { durationSeconds }

    /// Materializes every frame for compatibility. A single scrub or export range reads its own deltas.
    public var frames: [RewindFrame] {
        if let authored { return authored.frames }
        var result: [RewindFrame] = []
        result.reserveCapacity(len)
        var state = checkpoint(before: 0)
        for k in 0..<len {
            apply(k, to: &state)
            result.append(makeFrame(k, state: state))
        }
        return result
    }

    private enum LegacyIdentity: Hashable {
        case node(UInt64)
        case label(String, Int)
    }

    public init(frames: [RewindFrame], viewport: Vec2 = Vec2(800, 600)) {
        var tape = RewindTape(window: .infinity, maxBytes: .max)
        var indices: [LegacyIdentity: UInt32] = [:]
        var nodeIDs: [UInt64?] = []
        var frameIDs: [[UInt32]] = []
        for frame in frames {
            tape.begin(at: frame.timeSeconds, viewport: viewport)
            var occurrences: [String: Int] = [:]
            var ids: [UInt32] = []
            ids.reserveCapacity(frame.elements.count)
            for shot in frame.elements {
                let identity: LegacyIdentity
                if let node = shot.nodeID {
                    identity = .node(node)
                } else {
                    let ordinal = occurrences[shot.key, default: 0]
                    occurrences[shot.key] = ordinal + 1
                    identity = .label(shot.key, ordinal)
                }
                let id = indices[identity] ?? UInt32(nodeIDs.count)
                if Int(id) == nodeIDs.count {
                    indices[identity] = id
                    nodeIDs.append(shot.nodeID)
                }
                ids.append(id)
                // The same sparse tape can store the original float bits, including subpixel differences.
                let q: Q = (Int32(bitPattern: shot.left.bitPattern), Int32(bitPattern: shot.top.bitPattern),
                            Int32(bitPattern: shot.right.bitPattern), Int32(bitPattern: shot.bottom.bitPattern),
                            Int32(bitPattern: shot.opacity.bitPattern))
                tape.sample(nodeID: UInt64(id), name: shot.key, q: q)
            }
            tape.end()
            frameIDs.append(ids)
        }
        let frozen = tape.frozen()
        self.init(frozen, viewport: viewport, nodeIDs: nodeIDs, authored: (frames, frameIDs))
    }

    internal init(_ frozen: RewindTape.Frozen) {
        self.init(frozen, viewport: frozen.viewport, nodeIDs: frozen.nodeIDs, authored: nil)
    }

    private init(_ frozen: RewindTape.Frozen, viewport: Vec2, nodeIDs: [UInt64?],
                 authored: (frames: [RewindFrame], ids: [[UInt32]])?) {
        self.names = frozen.names
        self.nodeIDs = nodeIDs
        self.viewportWidth = viewport.x
        self.viewportHeight = viewport.y
        self.authored = authored
        // A trimmed clip should release the discarded prefix when the live recorder is released.
        let marks = frozen.marks.startIndex == 0 ? frozen.marks : Array(frozen.marks)[...]
        let words = frozen.words.startIndex == 0 ? frozen.words : Array(frozen.words)[...]
        self.marks = marks
        self.words = words
        var starts = [words.startIndex]
        var checkpoints: [[Entry]] = []
        var state = frozen.base
        var activity: [Float] = []
        var jumps: [[UInt32]] = []
        var previousDistances: [UInt32: Move] = [:]
        var previous = FrameMotion()
        var changedSinceCheckpoint = true
        activity.reserveCapacity(frozen.marks.count)
        jumps.reserveCapacity(frozen.marks.count)
        starts.reserveCapacity(frozen.marks.count + 1)
        for (k, mark) in marks.enumerated() {
            if k.isMultiple(of: Self.stride) {
                if !changedSinceCheckpoint, let previous = checkpoints.last {
                    checkpoints.append(previous)
                } else {
                    checkpoints.append(state.enumerated().compactMap { (i, q) in q.map { (UInt32(i), $0) } })
                }
                changedSinceCheckpoint = false
            }
            if mark.len > 0 { changedSinceCheckpoint = true }
            let start = starts[k]
            let end = start + Int(mark.len)
            starts.append(end)
            var motion = FrameMotion()
            Self.apply(words[start..<end], to: &state) { id, before, after in
                guard let before, let after else { return }
                if before.4 != after.4 {
                    if authored == nil {
                        motion.faded = true
                    } else {
                        let a = Float(bitPattern: UInt32(bitPattern: before.4))
                        let b = Float(bitPattern: UInt32(bitPattern: after.4))
                        motion.faded = motion.faded || abs(a - b) >= 0.0001
                    }
                }
                guard (before.0, before.1, before.2, before.3) != (after.0, after.1, after.2, after.3) else { return }
                let a = Self.geometry(before, exact: authored != nil)
                let b = Self.geometry(after, exact: authored != nil)
                let d = RewindChange.edgeDistance(a.rect, b.rect)
                if d > 0 {
                    motion.order.append(id)
                    motion.moves[id] = Move(distance: d, before: a.rect, after: b.rect)
                    motion.most = max(motion.most, d)
                }
            }
            activity.append(motion.most == 0 && motion.faded ? 0.25 : motion.most)
            if k > 0 { jumps.append(previous.jumps(between: previousDistances, and: motion.moves)) }
            previousDistances = previous.moves
            previous = motion
        }
        if !frozen.marks.isEmpty { jumps.append(previous.jumps(between: previousDistances, and: [:])) }
        self.starts = starts
        self.checkpoints = checkpoints
        self.activity = activity
        self.jumps = jumps
    }

    private struct Move {
        var distance: Float
        var before: MotionRect
        var after: MotionRect
    }

    private struct FrameMotion {
        var order: [UInt32] = []
        var moves: [UInt32: Move] = [:]
        var most: Float = 0
        var faded = false

        func jumps(between prior: [UInt32: Move], and next: [UInt32: Move]) -> [UInt32] {
            order.filter { id in
                guard let move = moves[id], move.distance >= 4 else { return false }
                let near = max(prior[id]?.distance ?? 0, next[id]?.distance ?? 0)
                let returned = next[id].map { RewindChange.edgeDistance($0.after, move.before) < 0.5 } ?? false
                return move.distance > 2.5 * near || returned
            }
        }
    }

    private static func geometry(_ q: Q, exact: Bool) -> (rect: MotionRect, opacity: Float) {
        if !exact { return RewindTape.dequantize(q) }
        func value(_ bits: Int32) -> Float { Float(bitPattern: UInt32(bitPattern: bits)) }
        return (MotionRect(left: value(q.0), top: value(q.1), right: value(q.2), bottom: value(q.3)), value(q.4))
    }

    private func snapshot(_ id: UInt32, _ q: Q) -> RewindElementSnapshot {
        let value = Self.geometry(q, exact: authored != nil)
        return RewindElementSnapshot(key: names[Int(id)], rect: value.rect, opacity: value.opacity, nodeID: nodeIDs[Int(id)])
    }

    private static func apply(_ words: ArraySlice<UInt32>, to state: inout [Q?],
                              change: (UInt32, Q?, Q?) -> Void = { _, _, _ in }) {
        RewindTape.decode(words) { id, mask, values in
            let i = Int(id)
            let before = state[i]
            if mask == 0 {
                state[i] = nil
            } else {
                var q = before ?? (0, 0, 0, 0, 0)
                if mask & 1 != 0 { q.0 = values.0 }
                if mask & 2 != 0 { q.1 = values.1 }
                if mask & 4 != 0 { q.2 = values.2 }
                if mask & 8 != 0 { q.3 = values.3 }
                if mask & 16 != 0 { q.4 = values.4 }
                state[i] = q
            }
            change(id, before, state[i])
        }
    }

    private func apply(_ k: Int, to state: inout [Q?], change: (UInt32, Q?, Q?) -> Void = { _, _, _ in }) {
        Self.apply(words[starts[k]..<starts[k + 1]], to: &state, change: change)
    }

    private func checkpoint(before k: Int) -> [Q?] {
        var state = [Q?](repeating: nil, count: names.count)
        guard !isEmpty else { return state }
        for (id, value) in checkpoints[k / Self.stride] { state[Int(id)] = value }
        let start = k - k % Self.stride
        for frame in start..<k { apply(frame, to: &state) }
        return state
    }

    private func makeFrame(_ index: Int, state: [Q?]) -> RewindFrame {
        let mark = marks[marks.startIndex + index]
        let elements = state.enumerated().compactMap { (i, q) in q.map { snapshot(UInt32(i), $0) } }
        return RewindFrame(index: mark.index, timeSeconds: mark.t, elements: elements)
    }

    /// Replays one frame by its position in the clip, preserving its original recording index and timestamp.
    public func recordedFrame(_ index: Int) -> RewindFrame? {
        guard index >= 0, index < len else { return nil }
        if let authored { return authored.frames[index] }
        var state = checkpoint(before: index)
        apply(index, to: &state)
        return makeFrame(index, state: state)
    }

    internal func absoluteTime(_ index: Int) -> Double {
        guard index >= 0, index < len else { return 0 }
        return marks[marks.startIndex + index].t
    }

    public func time(_ index: Int) -> Double {
        guard index >= 0, index < len else { return 0 }
        return absoluteTime(index) - absoluteTime(len - 1)
    }

    public func activity(_ index: Int) -> Float { activity.indices.contains(index) ? activity[index] : 0 }
    public func hasJump(_ index: Int) -> Bool { jumps.indices.contains(index) && !jumps[index].isEmpty }
    public func name(_ id: UInt32) -> String {
        guard let index = Int(exactly: id), names.indices.contains(index) else { return "" }
        return names[index]
    }
    public func id(forKey key: String) -> UInt32? { names.firstIndex(of: key).map(UInt32.init) }

    public func frame(_ index: Int) -> [(id: UInt32, snapshot: RewindElementSnapshot)] {
        guard index >= 0, index < len else { return [] }
        if let authored { return Array(zip(authored.ids[index], authored.frames[index].elements)) }
        var state = checkpoint(before: index)
        apply(index, to: &state)
        return state.enumerated().compactMap { (i, q) in q.map { (UInt32(i), snapshot(UInt32(i), $0)) } }
    }

    internal func frameBefore(_ index: Int) -> [(id: UInt32, snapshot: RewindElementSnapshot)] {
        if index > 0 { return frame(index - 1) }
        guard index == 0, let first = checkpoints.first else { return [] }
        return first.map { ($0.id, snapshot($0.id, $0.value)) }
    }

    internal func forEachFrameChanges(in range: Range<Int>, _ body: (Int, [RewindChange]) throws -> Void) rethrows {
        let start = max(0, range.lowerBound), end = min(len, range.upperBound)
        guard start < end else { return }
        var state = checkpoint(before: start)
        for k in start..<end {
            var changes: [RewindChange] = []
            let jumped = Set(jumps[k])
            apply(k, to: &state) { id, before, after in
                let a = before.map { Self.geometry($0, exact: authored != nil) }
                let b = after.map { Self.geometry($0, exact: authored != nil) }
                changes.append(RewindChange(id: id, key: name(id), fromRect: a?.rect, toRect: b?.rect,
                                            fromOpacity: a?.opacity, toOpacity: b?.opacity, jump: jumped.contains(id)))
            }
            changes.sort { a, b in a.jump == b.jump ? a.distance > b.distance : a.jump }
            try body(k, changes)
        }
    }

    public func changes(atFrame index: Int) -> [RewindChange] {
        guard index >= 0, index < len, starts[index] != starts[index + 1] else { return [] }
        var changes: [RewindChange] = []
        forEachFrameChanges(in: index..<(index + 1)) { _, frame in changes = frame }
        return changes
    }

    public func changes(_ index: Int) -> [RewindChange] { changes(atFrame: index) }

    public func path(id: UInt32, range: Range<Int>) -> [(frame: Int, snapshot: RewindElementSnapshot)] {
        let start = max(0, range.lowerBound), end = min(range.upperBound, len)
        guard let index = Int(exactly: id), names.indices.contains(index), start < end else { return [] }
        var state = checkpoint(before: start)
        var out: [(Int, RewindElementSnapshot)] = []
        for k in start..<end {
            apply(k, to: &state)
            if let q = state[index] { out.append((k, snapshot(id, q))) }
        }
        return out
    }

    public func nextActive(from index: Int, step: Int) -> Int? {
        guard step != 0 else { return nil }
        var (i, overflow) = index.addingReportingOverflow(step)
        while !overflow && activity.indices.contains(i) {
            if activity[i] > 0 { return i }
            (i, overflow) = i.addingReportingOverflow(step)
        }
        return nil
    }

    public func track(forKey key: String) -> [(timeSeconds: Double, rect: MotionRect, opacity: Float)] {
        guard let id = id(forKey: key) else { return [] }
        return path(id: id, range: 0..<len).map { (absoluteTime($0.frame), $0.snapshot.rect, $0.snapshot.opacity) }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.viewport == rhs.viewport, lhs.len == rhs.len, lhs.names == rhs.names,
              lhs.nodeIDs == rhs.nodeIDs, lhs.activity == rhs.activity, lhs.jumps == rhs.jumps else { return false }
        if let a = lhs.authored, let b = rhs.authored { return a.frames == b.frames }
        guard lhs.frameBefore(0).elementsEqual(rhs.frameBefore(0), by: { $0.id == $1.id && $0.snapshot == $1.snapshot }) else { return false }
        if lhs.authored == nil, rhs.authored == nil, lhs.marks.elementsEqual(rhs.marks),
           lhs.words.elementsEqual(rhs.words) { return true }
        return (0..<lhs.len).allSatisfy { lhs.recordedFrame($0) == rhs.recordedFrame($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case frames, viewportWidth, viewportHeight, recording
    }

    // Recorded JSON retains the state before the first kept frame and the dense identity table.
    // Both matter after eviction, even when a previously seen node is absent in the first frame.
    private struct Recording: Codable {
        var version: Int
        var names: [String]
        var nodeIDs: [UInt64?]
        var indices: [Int]
        var times: [Double]
        var counts: [UInt32]
        var base: [UInt32]
        var words: [UInt32]

        func isValidStream(_ words: [UInt32], range: Range<Int>, absolute: Bool = false) -> Bool {
            var cursor = range.lowerBound
            var seen: Set<UInt32> = []
            while cursor < range.upperBound {
                let header = words[cursor]
                let id = header >> 5, mask = header & 31
                let count = mask.nonzeroBitCount
                guard Int(id) < names.count, !absolute || mask == 31, seen.insert(id).inserted,
                      count <= range.upperBound - cursor - 1 else { return false }
                cursor += 1 + count
            }
            return true
        }

        func frozen(viewport: Vec2, at path: [CodingKey]) throws -> RewindTape.Frozen {
            let invalid = DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "Invalid rewind recording"))
            guard version == 1, names.count == nodeIDs.count, times.count == indices.count,
                  times.count == counts.count, isValidStream(base, range: base.indices, absolute: true) else { throw invalid }
            var offset = 0
            var marks: [RewindTape.Mark] = []
            marks.reserveCapacity(times.count)
            for k in times.indices {
                guard let count = Int(exactly: counts[k]), count <= words.count - offset, times[k].isFinite,
                      isValidStream(words, range: offset..<(offset + count)) else { throw invalid }
                marks.append(.init(index: indices[k], t: times[k], len: counts[k]))
                offset += count
            }
            guard offset == words.count else { throw invalid }
            var state = [Q?](repeating: nil, count: names.count)
            RewindClip.apply(base[...], to: &state)
            return RewindTape.Frozen(names: names, nodeIDs: nodeIDs, marks: marks[...],
                                     words: words[...], base: state, viewport: viewport)
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let width = try values.decodeIfPresent(Float.self, forKey: .viewportWidth) ?? 800
        let height = try values.decodeIfPresent(Float.self, forKey: .viewportHeight) ?? 600
        let viewport = Vec2(width, height)
        if values.contains(.recording) {
            let recording = try values.decode(Recording.self, forKey: .recording)
            self.init(try recording.frozen(viewport: viewport, at: decoder.codingPath))
        } else {
            self.init(frames: try values.decode([RewindFrame].self, forKey: .frames), viewport: viewport)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(viewportWidth, forKey: .viewportWidth)
        try values.encode(viewportHeight, forKey: .viewportHeight)
        if let authored {
            try values.encode(authored.frames, forKey: .frames)
        } else {
            var base: [UInt32] = []
            if let first = checkpoints.first {
                base.reserveCapacity(first.count * 6)
                for (id, q) in first {
                    base.append((id << 5) | 31)
                    base.append(UInt32(bitPattern: q.0))
                    base.append(UInt32(bitPattern: q.1))
                    base.append(UInt32(bitPattern: q.2))
                    base.append(UInt32(bitPattern: q.3))
                    base.append(UInt32(bitPattern: q.4))
                }
            }
            let recording = Recording(version: 1, names: names, nodeIDs: nodeIDs, indices: marks.map(\.index),
                                      times: marks.map(\.t), counts: marks.map(\.len), base: base, words: Array(words))
            try values.encode(recording, forKey: .recording)
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

/// Quantized delta ring buffer backing `RewindRecorder` (`crates/rune/src/rewind/tape.rs`).
public struct RewindTape: Sendable {
    public typealias Quantized = (Int32, Int32, Int32, Int32, Int32)

    public struct Mark: Sendable, Equatable {
        public var index: Int
        public var t: Double
        public var len: UInt32
    }

    private static let fields = 5
    private static let maskBits: UInt32 = 5

    public var window: Double
    public var maxBytes: Int
    public var paused: Bool = false
    public var viewport: Vec2 = Vec2(800, 600)

    /// Copy-on-write views of kept deltas. Indexing runs after the recorder releases its lock.
    internal struct Frozen: Sendable {
        let names: [String]
        let nodeIDs: [UInt64?]
        let marks: ArraySlice<Mark>
        let words: ArraySlice<UInt32>
        let base: [Quantized?]
        let viewport: Vec2
    }

    private var sceneIDs: [UInt64: UInt32] = [:]
    private var legacyIDs: [String: UInt32] = [:]
    private var nodeIDs: [UInt64?] = []
    public private(set) var names: [String] = []
    private var nameBytes: Int = 0
    private var compactAt = 4096
    private var last: [Quantized] = []
    private var seen: [UInt32] = []
    private var present: [UInt32] = []
    private var nextPresent: [UInt32] = []
    private var serial: UInt32 = 0
    private var nextFrameIndex: Int = 0
    private var openFrame: (t: Double, start: Int)? = nil
    private var markBuffer: [Mark] = []
    private var wordBuffer: [UInt32] = []
    private var firstMark = 0
    private var firstWord = 0
    public var frames: [Mark] { firstMark == 0 ? markBuffer : Array(markBuffer[firstMark...]) }
    public var words: [UInt32] { firstWord == 0 ? wordBuffer : Array(wordBuffer[firstWord...]) }
    public private(set) var base: [Quantized?] = []
    internal var frameCount: Int { markBuffer.count - firstMark }

    internal func frozen() -> Frozen {
        Frozen(names: names, nodeIDs: nodeIDs, marks: markBuffer[firstMark...],
               words: wordBuffer[firstWord...], base: base, viewport: viewport)
    }

    public init(window: Double = 60.0, maxBytes: Int = 24 << 20) {
        self.window = max(0.0, window)
        self.maxBytes = max(0, maxBytes)
    }

    public static func quantize(rect: MotionRect, opacity: Float) -> Quantized {
        func q(_ v: Float, _ k: Float) -> Int32 {
            let scaled = (v * k).rounded()
            if scaled.isNaN { return 0 }
            if scaled >= Float(Int32.max) { return .max }
            if scaled <= Float(Int32.min) { return .min }
            return Int32(scaled)
        }
        return (
            q(rect.left, 100.0),
            q(rect.top, 100.0),
            q(rect.width, 100.0),
            q(rect.height, 100.0),
            q(opacity, 1000.0)
        )
    }

    public static func dequantize(_ q: Quantized) -> (rect: MotionRect, opacity: Float) {
        let r = MotionRect.fromXYWH(
            Float(q.0) / 100.0,
            Float(q.1) / 100.0,
            Float(q.2) / 100.0,
            Float(q.3) / 100.0
        )
        return (r, Float(q.4) / 1000.0)
    }

    private static func field(_ q: Quantized, at i: Int) -> Int32 {
        switch i {
        case 0: return q.0
        case 1: return q.1
        case 2: return q.2
        case 3: return q.3
        default: return q.4
        }
    }

    private static func setField(_ q: inout Quantized, at i: Int, value: Int32) {
        switch i {
        case 0: q.0 = value
        case 1: q.1 = value
        case 2: q.2 = value
        case 3: q.3 = value
        default: q.4 = value
        }
    }

    public mutating func begin(at t: Double, viewport: Vec2) {
        serial = max(1, serial &+ 1)
        self.viewport = viewport
        openFrame = (t, wordBuffer.count)
        nextPresent.removeAll(keepingCapacity: true)
    }

    public mutating func sample(key: String, q: Quantized) {
        if nextPresent.count < present.count {
            let previous = present[nextPresent.count]
            let i = Int(previous)
            if nodeIDs[i] == nil && names[i] == key {
                sample(id: previous, q: q)
                return
            }
        }
        let id: UInt32
        if let existing = legacyIDs[key] { id = existing }
        else {
            id = addIdentity(name: key, nodeID: nil)
            legacyIDs[key] = id
        }
        sample(id: id, q: q)
    }

    public mutating func sample(nodeID: UInt64, name: String, q: Quantized) {
        if nextPresent.count < present.count {
            let previous = present[nextPresent.count]
            if nodeIDs[Int(previous)] == nodeID {
                sample(id: previous, q: q)
                return
            }
        }
        let id: UInt32
        if let existing = sceneIDs[nodeID] { id = existing }
        else {
            id = addIdentity(name: name, nodeID: nodeID)
            sceneIDs[nodeID] = id
        }
        sample(id: id, q: q)
    }

    private mutating func addIdentity(name: String, nodeID: UInt64?) -> UInt32 {
        let id = UInt32(names.count)
        names.append(name)
        nameBytes += name.utf8.count
        nodeIDs.append(nodeID)
        last.append((0, 0, 0, 0, 0))
        seen.append(0)
        base.append(nil)
        return id
    }

    private mutating func sample(id: UInt32, q: Quantized) {
        let i = Int(id)
        if seen[i] == serial { return }
        let was = seen[i] != 0 && seen[i] == (serial &- 1)
        seen[i] = serial
        nextPresent.append(id)
        let old = last[i]
        if was && old == q { return }
        var mask: UInt32 = 0
        for f in 0..<Self.fields {
            if !was || Self.field(old, at: f) != Self.field(q, at: f) {
                mask |= (1 << f)
            }
        }
        wordBuffer.append((id << Self.maskBits) | mask)
        for f in 0..<Self.fields where (mask & (1 << f)) != 0 {
            wordBuffer.append(UInt32(bitPattern: Self.field(q, at: f)))
        }
        last[i] = q
    }

    public mutating func end() {
        guard let open = openFrame else { return }
        openFrame = nil
        for id in present where seen[Int(id)] != serial {
            wordBuffer.append(id << Self.maskBits)
        }
        swap(&present, &nextPresent)
        let len = UInt32(wordBuffer.count - open.start)
        markBuffer.append(Mark(index: nextFrameIndex, t: open.t, len: len))
        nextFrameIndex += 1
        evict(now: open.t)
        if names.count >= compactAt { rest() }
    }

    mutating func rest() {
        guard !paused, openFrame == nil else { return }
        var kept = base.map { $0 != nil }
        for id in present { kept[Int(id)] = true }
        Self.decode(wordBuffer[firstWord...]) { id, _, _ in kept[Int(id)] = true }
        let indices = kept.indices.filter { kept[$0] }
        if indices.count < names.count {
            var newID = [UInt32](repeating: 0, count: names.count)
            for (new, old) in indices.enumerated() { newID[old] = UInt32(new) }
            names = indices.map { names[$0] }
            nodeIDs = indices.map { nodeIDs[$0] }
            seen = indices.map { seen[$0] }
            last = indices.map { last[$0] }
            base = indices.map { base[$0] }
            nameBytes = names.reduce(0) { $0 + $1.utf8.count }
            sceneIDs = sceneIDs.compactMapValues { old in kept[Int(old)] ? newID[Int(old)] : nil }
            legacyIDs = legacyIDs.compactMapValues { old in kept[Int(old)] ? newID[Int(old)] : nil }
            present = present.map { newID[Int($0)] }
            var cursor = firstWord
            while cursor < wordBuffer.count {
                let header = wordBuffer[cursor]
                let mask = header & ((1 << Self.maskBits) - 1)
                wordBuffer[cursor] = (newID[Int(header >> Self.maskBits)] << Self.maskBits) | mask
                cursor += 1 + mask.nonzeroBitCount
            }
        }
        compactAt = max(4096, names.count * 2)
        nextPresent = []
        if firstMark > 0 || markBuffer.capacity > frameCount * 2 {
            markBuffer = Array(markBuffer[firstMark...])
            firstMark = 0
        }
        if firstWord > 0 || wordBuffer.capacity > (wordBuffer.count - firstWord) * 2 {
            wordBuffer = Array(wordBuffer[firstWord...])
            firstWord = 0
        }
    }

    private mutating func evict(now: Double) {
        let cutoff = now - window
        while frameCount > 1, markBuffer[firstMark].t < cutoff || bytes > maxBytes {
            let end = firstWord + Int(markBuffer[firstMark].len)
            firstMark += 1
            var k = firstWord
            while k < end {
                let head = wordBuffer[k]
                let id = Int(head >> Self.maskBits)
                let mask = head & ((1 << Self.maskBits) - 1)
                k += 1
                if mask == 0 {
                    if id < base.count { base[id] = nil }
                    continue
                }
                var q: Quantized = (id < base.count ? base[id] : nil) ?? (0, 0, 0, 0, 0)
                for f in 0..<Self.fields where (mask & (1 << f)) != 0 {
                    Self.setField(&q, at: f, value: Int32(bitPattern: wordBuffer[k]))
                    k += 1
                }
                if id < base.count { base[id] = q }
            }
            firstWord = end
        }
        // Amortize prefix reclamation across the many frames that evicted them.
        if firstMark >= 64 && firstMark >= frameCount {
            markBuffer.removeFirst(firstMark)
            firstMark = 0
        }
        if firstWord >= 256 && firstWord >= wordBuffer.count - firstWord {
            wordBuffer.removeFirst(firstWord)
            firstWord = 0
        }
    }

    /// Approximate memory footprint matching `Tape::bytes` (`crates/rune/src/rewind/tape.rs:138`).
    public var bytes: Int {
        (wordBuffer.count - firstWord) * 4
            + frameCount * 16  // Rust Mark contains an f64 time and u32 word count.
            + nameBytes
            + names.count * (24 + 2 * 20 + 16)
    }

    public static func decode(_ slice: ArraySlice<UInt32>, _ body: (UInt32, UInt32, Quantized) -> Void) {
        var k = slice.startIndex
        while k < slice.endIndex {
            let head = slice[k]
            let id = head >> maskBits
            let mask = head & ((1 << maskBits) - 1)
            k = slice.index(after: k)
            var q: Quantized = (0, 0, 0, 0, 0)
            for f in 0..<fields where (mask & (1 << f)) != 0 {
                if k < slice.endIndex {
                    setField(&q, at: f, value: Int32(bitPattern: slice[k]))
                    k = slice.index(after: k)
                }
            }
            body(id, mask, q)
        }
    }

    public func toFrames() -> [RewindFrame] {
        RewindClip(frozen()).frames
    }
}

/// Ring-buffered frame/state recorder (`rune::rewind::Rewind`).
public final class RewindRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var tape: RewindTape
    public var windowSeconds: Double {
        get { lock.withLock { tape.window } }
        set { lock.withLock { tape.window = max(0, newValue) } }
    }
    public var maxBytes: Int {
        get { lock.withLock { tape.maxBytes } }
        set { lock.withLock { tape.maxBytes = max(0, newValue) } }
    }
    public var viewport: Vec2 { lock.withLock { tape.viewport } }
    public var isPaused: Bool { lock.withLock { tape.paused } }

    public init(windowSeconds: Double = 60.0, maxBytes: Int = 24 * 1024 * 1024) {
        self.tape = RewindTape(window: windowSeconds, maxBytes: maxBytes)
    }

    /// Builder-style window duration (`Rewind::seconds`).
    @discardableResult
    public func seconds(_ s: Double) -> Self {
        lock.withLock { tape.window = max(0, s) }
        return self
    }

    /// Builder-style memory budget (`Rewind::max_bytes`).
    @discardableResult
    public func maxBytes(_ bytes: Int) -> Self {
        lock.withLock { tape.maxBytes = max(0, bytes) }
        return self
    }

    public func setViewport(_ viewport: Vec2) {
        lock.withLock { tape.viewport = viewport }
    }

    public var frameCount: Int { lock.withLock { tape.frameCount } }

    /// Estimated byte size matching upstream `Rewind::bytes` (`Tape::bytes`).
    public var estimatedBytes: Int { lock.withLock { tape.bytes } }

    /// Records the presented elements directly into the tape. Frozen recordings skip the inspection.
    internal func recordFrame(at timeSeconds: Double, viewport: Vec2, sample: (inout RewindTape) -> Void) {
        lock.withLock {
            guard !tape.paused else { return }
            tape.begin(at: timeSeconds, viewport: viewport)
            sample(&tape)
            tape.end()
        }
    }

    public func recordFrame(at timeSeconds: Double, elements: [RewindElementSnapshot]) {
        lock.withLock {
            guard !tape.paused else { return }
            tape.begin(at: timeSeconds, viewport: tape.viewport)
            for el in elements {
                let q = RewindTape.quantize(rect: el.rect, opacity: el.opacity)
                if let nodeID = el.nodeID { tape.sample(nodeID: nodeID, name: el.key, q: q) }
                else { tape.sample(key: el.key, q: q) }
            }
            tape.end()
        }
    }

    public func freeze() -> RewindClip {
        let snapshot = lock.withLock {
            tape.paused = true
            return tape.frozen()
        }
        return RewindClip(snapshot)
    }

    func rest() {
        lock.withLock { tape.rest() }
    }

    public func resume() {
        lock.withLock { tape.paused = false }
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
        let last = max(0, clip.len - 1)
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
        let held = heldRecorder
        self.heldRecorder = nil
        self.isOpen = false
        self.clip = nil
        self.anchorFrame = nil
        self.pickedId = nil
        held?.resume()
        if recorder !== held { recorder?.resume() }
    }

    public var currentFrame: RewindFrame? {
        clip?.recordedFrame(currentFrameIndex)
    }

    public func seek(toFrame index: Int) {
        seek(index, extend: false)
    }

    /// Shows frame `index`; with `extend == true`, grows the selection from the anchor (`Scrub::seek`).
    public func seek(_ index: Int, extend: Bool) {
        guard let clip, !clip.isEmpty else { return }
        let clamped = min(max(0, index), clip.len - 1)
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
        guard let clip, !clip.isEmpty else { return }
        let f = fraction.clamped(to: 0...1)
        let idx = Int((f * Double(clip.len - 1)).rounded())
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

/// Watches files and directories for edits, replacements, and removal (`rune::hot`).
public final class HotWatcher: @unchecked Sendable {
    #if canImport(Dispatch)
    private let lock = NSLock()
    private var sources: [any DispatchSourceProtocol] = []
    private let queue = DispatchQueue(label: "rune.hot.watcher", qos: .utility)
    #endif

    public init() {}

    deinit {
        stop()
    }

    public func watch(path: URL, onChange: @escaping @Sendable (URL) -> Void) -> Bool {
        #if canImport(Darwin)
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
        #elseif canImport(Dispatch)
        guard let initial = FileStamp(path) else { return false }
        let last = Mutex<FileStamp?>(initial)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        source.setEventHandler {
            let next = FileStamp(path)
            let changed = last.withLock { previous in
                guard previous != next else { return false }
                previous = next
                return true
            }
            if changed { onChange(path) }
        }
        #endif
        #if canImport(Dispatch)
        lock.withLock {
            sources.append(source)
            source.activate()
        }
        return true
        #else
        return false
        #endif
    }

    public func stop() {
        #if canImport(Dispatch)
        let toCancel = lock.withLock { () -> [any DispatchSourceProtocol] in
            let s = sources
            sources.removeAll()
            return s
        }
        for s in toCancel {
            s.cancel()
        }
        #endif
    }

    #if !canImport(Darwin) && canImport(Dispatch)
    private struct FileStamp: Equatable {
        let modified: Date?
        let size: UInt64?
        let fileNumber: UInt64?
        let permissions: UInt16?

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            modified = attributes[.modificationDate] as? Date
            size = (attributes[.size] as? NSNumber)?.uint64Value
            fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        }
    }
    #endif
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
