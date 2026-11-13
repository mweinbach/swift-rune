import Foundation

/// Delta-encoded motion-lint scalar channels (`trace.rs`).
public struct TraceChannels: Sendable {
    public enum Kind: String, Sendable, Hashable {
        case position
        case level
        case phase
    }

    private struct Channel: Sendable {
        var name: String
        var kind: Kind
        var value: Double?
        var previous: Double?
        var described: Bool
        var owner: (UInt32, String)?

        init(name: String, kind: Kind) {
            self.name = name
            self.kind = kind
            self.value = nil
            self.previous = nil
            self.described = false
            self.owner = nil
        }
    }

    private var ids: [String: Int] = [:]
    private var channels: [Channel] = []

    public init() {}

    /// Records a sample for `name`. Non-finite samples are ignored.
    public mutating func sample(name: String, kind: Kind, value: Float) {
        guard value.isFinite else { return }
        let idx: Int
        if let existing = ids[name] {
            idx = existing
        } else {
            idx = channels.count
            ids[name] = idx
            channels.append(Channel(name: name, kind: kind))
        }
        if channels[idx].kind != kind {
            channels[idx].kind = kind
            channels[idx].described = false
        }
        channels[idx].value = (Double(value) * 1e4).rounded() / 1e4
    }

    public mutating func remove(name: String) {
        if let idx = ids[name] {
            channels[idx].value = nil
        }
    }

    /// Associates an effect channel with its element for visibility gating.
    public mutating func owner(name: String, owner: UInt32, unit: String) {
        guard let idx = ids[name] else { return }
        let existing = channels[idx].owner
        if existing?.0 != owner || existing?.1 != unit {
            channels[idx].owner = (owner, unit)
            channels[idx].described = false
        }
    }

    /// Appends optional `cm`, `c`, and `cg` fields to an open JSON object line.
    public mutating func writeJSON(into line: inout String) {
        var metas: [String] = []
        var values: [String] = []
        var gone: [String] = []

        for i in channels.indices {
            let id = i + 1
            if let value = channels[i].value {
                if !channels[i].described {
                    var meta = "{\"id\":\(id),\"name\":\(jsonEscape(channels[i].name)),\"kind\":\(jsonEscape(channels[i].kind.rawValue))"
                    if let (owner, unit) = channels[i].owner {
                        meta += ",\"owner\":\(owner),\"unit\":\(jsonEscape(unit))"
                    }
                    meta += "}"
                    metas.append(meta)
                    channels[i].described = true
                }
                if channels[i].previous != value {
                    values.append("[\(id),\(value)]")
                }
            } else if channels[i].previous != nil {
                gone.append("\(id)")
            }
            channels[i].previous = channels[i].value
        }

        if !metas.isEmpty { line += ",\"cm\":[\(metas.joined(separator: ","))]" }
        if !values.isEmpty { line += ",\"c\":[\(values.joined(separator: ","))]" }
        if !gone.isEmpty { line += ",\"cg\":[\(gone.joined(separator: ","))]" }
    }
}

/// motion-lint element flag bits (`trace.rs::flags`).
public enum TraceFlags {
    public static let animated: UInt32 = 1
    public static let ancestorAnimated: UInt32 = 2
    public static let scrolling: UInt32 = 4
    public static let clipped: UInt32 = 8
    public static let filtered: UInt32 = 16
    public static let looping: UInt32 = 32
    public static let blank: UInt32 = 64
}

/// motion-lint intent classes (`trace.rs::Intent`).
public enum TraceIntent {
    public static let position: UInt32 = 1
    public static let size: UInt32 = 2
    public static let opacity: UInt32 = 4
    public static let shape: UInt32 = 8
    public static let transition: UInt32 = 16
    public static let reveal: UInt32 = 32
    public static let contents: UInt32 = 64

    /// The intent class a built-in property's animation declares.
    public static func forProp(_ prop: PropId) -> UInt32 {
        switch prop {
        case Props.RECT.id, Props.TRAVEL.id:
            return position | size
        case Props.OFFSET.id, Props.ROTATE.id, Props.SCROLL.id:
            return position
        case Props.OPACITY.id:
            return opacity
        case Props.SCALE.id, Props.UNIFORM_SCALE.id:
            return size | transition
        case Props.BLUR.id, Props.BLUR_SCALAR.id:
            return transition
        case Props.CORNERS.id, Props.MASK.id, Props.SIDES.id:
            return shape
        case Props.FILL.id, Props.BORDER.id, Props.TEXT_COLOR.id:
            return contents
        case Props.PRESENCE.id:
            return transition | opacity
        default:
            return contents
        }
    }
}

/// Trace header line (`trace.rs::TraceHeader`).
public struct TraceHeader: Sendable, Equatable {
    public var launch: String
    public var width: Float
    public var height: Float
    public var hz: Float
    public var scale: Float

    public init(launch: String, width: Float, height: Float, hz: Float, scale: Float) {
        self.launch = launch
        self.width = width
        self.height = height
        self.hz = hz
        self.scale = scale
    }
}

/// Writes one motion-lint JSONL line per frame (`trace.rs::MotionTrace`).
public final class MotionTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: String
    private var fileHandle: FileHandle?
    private var ids: [UInt64: UInt32] = [:]
    private var states: [UInt32: [Float]] = [:]
    private var lastT: Double?
    private let hz: Double
    private var timeScale: Float = 1.0
    private var names: [UInt64: String] = [:]
    private var described: [UInt64: (String?, String?, String?)] = [:]
    private var namespaces: [UInt64: (String, String)] = [:]
    private var traceClass: String = "rune"
    private var traceHost: String = "scene"
    private var channels = TraceChannels()
    private var customEvents: [String] = []

    public init(header: TraceHeader, fileHandle: FileHandle? = nil) {
        self.hz = Double(max(header.hz, 1.0))
        self.fileHandle = fileHandle
        let headerLine =
            "{\"type\":\"header\",\"launch\":\(jsonEscape(header.launch)),\"width\":\(header.width),\"height\":\(header.height),\"hz\":\(header.hz),\"scale\":\(header.scale),\"platform\":\"rune\",\"units\":\"pt\",\"clock\":\"virtual\"}\n"
        self.buffer = headerLine
        if let fileHandle, let data = headerLine.data(using: .utf8) {
            fileHandle.write(data)
        }
    }

    /// Creates an in-memory trace for tests.
    public static func inMemory(header: TraceHeader) -> MotionTrace {
        MotionTrace(header: header, fileHandle: nil)
    }

    /// Opens `$RUNE_MOTION_TRACE` if set.
    public static func fromEnv(header: TraceHeader) -> MotionTrace? {
        guard let path = ProcessInfo.processInfo.environment["RUNE_MOTION_TRACE"], !path.isEmpty else {
            return nil
        }
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        return MotionTrace(header: header, fileHandle: handle)
    }

    public func setTimeScale(_ sc: Float) {
        lock.withLock { timeScale = sc }
    }

    @discardableResult
    public func host(_ host: String) -> MotionTrace {
        lock.withLock { traceHost = host }
        return self
    }

    @discardableResult
    public func `class`(_ cls: String) -> MotionTrace {
        lock.withLock { traceClass = cls }
        return self
    }

    @discardableResult
    public func namespace(_ node: NodeId, _ ns: (String, String)?) -> Bool {
        lock.withLock {
            if let ns {
                let prev = namespaces[node.rawValue]
                namespaces[node.rawValue] = ns
                return prev?.0 != ns.0 || prev?.1 != ns.1
            } else {
                return namespaces.removeValue(forKey: node.rawValue) != nil
            }
        }
    }

    @discardableResult
    public func name(_ node: NodeId, _ name: String?) -> Bool {
        lock.withLock {
            if let name {
                let prev = names[node.rawValue]
                names[node.rawValue] = name
                return prev != name
            } else {
                return names.removeValue(forKey: node.rawValue) != nil
            }
        }
    }

    public func channel(_ name: String, kind: TraceChannels.Kind, value: Float) {
        lock.withLock { channels.sample(name: name, kind: kind, value: value) }
    }

    public func removeChannel(_ name: String) {
        lock.withLock { channels.remove(name: name) }
    }

    public func event(_ event: String) {
        lock.withLock { customEvents.append(event) }
    }

    public func contents() -> String {
        lock.withLock { buffer }
    }

    public func flush() {
        lock.withLock {
            try? fileHandle?.synchronize()
        }
    }

    private func idFor(_ node: NodeId) -> UInt32 {
        if let existing = ids[node.rawValue] { return existing }
        let next = UInt32(ids.count + 1)
        ids[node.rawValue] = next
        return next
    }

    /// Writes one JSONL frame line. `t` is animation time in seconds.
    public func frame(
        at t: Double,
        presented: [Presented],
        gone: [NodeId] = [],
        events: [MotionEvent] = [],
        intents: [(NodeId, UInt32, Float)] = [],
        flagsByNode: [NodeId: UInt32] = [:]
    ) {
        lock.withLock {
            let tMs = t * 1000.0
            let n: UInt64
            if let last = lastT {
                n = UInt64(max(1.0, ((tMs - last) / (1000.0 / hz)).rounded()))
            } else {
                n = 1
            }
            lastT = tMs

            var line = "{\"t\":\(r3(tMs)),\"n\":\(n),\"sc\":\(timeScale)"

            if !events.isEmpty || !customEvents.isEmpty {
                var evList: [String] = []
                for e in events {
                    switch e {
                    case let .settled(_, node, prop):
                        evList.append(jsonEscape("settled \(node.rawValue):\(prop.rawValue)"))
                    case let .completed(token, _, _, finished):
                        evList.append(jsonEscape("completed #\(token)\(finished ? "" : " (replaced)")"))
                    }
                }
                for ce in customEvents {
                    evList.append(jsonEscape(ce))
                }
                customEvents.removeAll(keepingCapacity: true)
                line += ",\"ev\":[\(evList.joined(separator: ","))]"
            }

            var metas: [String] = []
            var elems: [String] = []

            for p in presented {
                let id = idFor(p.id)
                let nodeName = names[p.id.rawValue]
                let ns = namespaces[p.id.rawValue]
                let desc = (nodeName, ns?.0, ns?.1)
                let prev = described[p.id.rawValue]
                if prev == nil || prev?.0 != desc.0 || prev?.1 != desc.1 || prev?.2 != desc.2 {
                    described[p.id.rawValue] = desc
                    let displayName = nodeName ?? String(p.id.rawValue)
                    let cls = ns?.0 ?? traceClass
                    let host = ns?.1 ?? traceHost
                    var meta = "{\"id\":\(id),\"cls\":\(jsonEscape(cls)),\"nm\":\(jsonEscape(displayName)),\"host\":\(jsonEscape(host))"
                    if let parent = p.parent {
                        meta += ",\"pv\":\(idFor(parent))"
                    }
                    meta += "}"
                    metas.append(meta)
                }

                let r = p.rect
                let flags = flagsByNode[p.id] ?? (p.flags != 0 ? p.flags : (p.isMoving ? TraceFlags.animated : 0))
                var s: [Float] = [
                    r.x, r.y, r.width, r.height, p.opacity, p.corners.topLeft, Float(flags),
                    .nan, 0, 0, 0
                ]
                if let clip = p.revealClip {
                    s[7] = clip.x
                    s[8] = clip.y
                    s[9] = max(0, clip.width)
                    s[10] = max(0, clip.height)
                }
                let rounded = s.map { $0.isNaN ? $0 : ($0 * 100.0).rounded() / 100.0 }
                if let old = states[id], sameState(old, rounded) {
                    continue
                }
                states[id] = rounded

                var elem = "[\(id),\(r2(r.x)),\(r2(r.y)),\(r2(r.width)),\(r2(r.height)),\(r3(Double(p.opacity))),\(r2(p.corners.topLeft)),\(flags)"
                if !s[7].isNaN {
                    elem += ",\(r2(s[7])),\(r2(s[8])),\(r2(s[9])),\(r2(s[10]))"
                }
                elem += "]"
                elems.append(elem)
            }

            if !intents.isEmpty {
                var ai: [String] = []
                for (node, bits, secs) in intents {
                    let id = idFor(node)
                    let rect = presented.first(where: { $0.id == node })?.rect ?? .zero
                    ai.append("[\(id),\(r2(rect.x)),\(r2(rect.y)),\(r2(rect.width)),\(r2(rect.height)),\(bits),\((secs * 1000.0).rounded())]")
                }
                line += ",\"ai\":[\(ai.joined(separator: ","))]"
            }

            if !metas.isEmpty { line += ",\"m\":[\(metas.joined(separator: ","))]" }
            if !elems.isEmpty { line += ",\"e\":[\(elems.joined(separator: ","))]" }

            if !gone.isEmpty {
                let goneIds = gone.map { node -> String in
                    let id = idFor(node)
                    states.removeValue(forKey: id)
                    return "\(id)"
                }
                line += ",\"g\":[\(goneIds.joined(separator: ","))]"
            }

            channels.writeJSON(into: &line)
            line += "}\n"

            buffer += line
            if let fileHandle, let data = line.data(using: .utf8) {
                fileHandle.write(data)
            }
        }
    }
}

/// One captured scalar sample for deterministic curve/spring analysis.
public struct MotionSample: Sendable, Equatable {
    public var time: Double
    public var value: Float
    public var velocity: Float

    public init(time: Double, value: Float, velocity: Float = 0) {
        self.time = time
        self.value = value
        self.velocity = velocity
    }
}

/// Captures deterministic frame-by-frame samples of a `Layer`, `Spring`, `Curve`, or `Scene`
/// and provides monotony, overshoot, and settling assertions.
public struct MotionTraceCapture: Sendable {
    public private(set) var samples: [MotionSample] = []

    public init() {}

    /// Samples a `Spring` from `from` to `to` at fixed `hz` for `duration` seconds.
    public static func sampleSpring(
        _ spring: Spring,
        from: Float = 0,
        to: Float = 1,
        initialVelocity: Float = 0,
        hz: Double = 60,
        duration: Double? = nil
    ) -> MotionTraceCapture {
        let total = duration ?? Double(spring.settlingDuration(from: from, velocity: initialVelocity, target: to)) + 0.05
        let dt = 1.0 / max(hz, 1.0)
        var cap = MotionTraceCapture()
        var t = 0.0
        while t <= total + 1e-9 {
            let s = spring.sample(from: from, velocity: initialVelocity, target: to, at: Float(t))
            cap.samples.append(MotionSample(time: t, value: s.position, velocity: s.velocity))
            t += dt
        }
        return cap
    }

    /// Samples a `Layer` at fixed `hz` for `duration` seconds.
    public static func sampleLayer(
        _ layer: Layer,
        target: Float = 0,
        hz: Double = 60,
        duration: Double? = nil
    ) -> MotionTraceCapture {
        let total = duration ?? Double(layer.settleDuration) + 0.05
        let dt = 1.0 / max(hz, 1.0)
        var cap = MotionTraceCapture()
        var t = layer.t0
        while t <= layer.t0 + total + 1e-9 {
            let s = layer.sample(at: t)
            cap.samples.append(MotionSample(time: t, value: target + s.offset, velocity: s.velocity))
            t += dt
        }
        return cap
    }

    public mutating func record(_ sample: MotionSample) {
        samples.append(sample)
    }

    /// True if values move monotonically (non-decreasing when `increasing == true`, non-increasing otherwise).
    public func isMonotonic(increasing: Bool = true, tolerance: Float = 1e-5) -> Bool {
        guard samples.count >= 2 else { return true }
        for i in 1..<samples.count {
            let prev = samples[i - 1].value
            let cur = samples[i].value
            if increasing && cur + tolerance < prev { return false }
            if !increasing && cur - tolerance > prev { return false }
        }
        return true
    }

    /// Maximum overshoot past `target` in the direction of motion from `start`.
    public func maxOvershoot(from start: Float, to target: Float) -> Float {
        let dir: Float = target >= start ? 1.0 : -1.0
        var best: Float = 0
        for s in samples {
            let past = (s.value - target) * dir
            if past > best { best = past }
        }
        return best
    }

    /// First timestamp at which all remaining samples stay within `epsilon` of `target`.
    public func settledTime(target: Float, epsilon: Float = 1e-3) -> Double? {
        guard !samples.isEmpty else { return nil }
        var idx = samples.count
        while idx > 0 {
            if abs(samples[idx - 1].value - target) > epsilon {
                break
            }
            idx -= 1
        }
        return idx < samples.count ? samples[idx].time : nil
    }

    /// Human-readable frame-by-frame text dump.
    public func dumpText() -> String {
        samples.map { s in
            String(format: "t=%.4f v=%.6f vel=%.6f", s.time, s.value, s.velocity)
        }.joined(separator: "\n")
    }
}

private func sameState(_ a: [Float], _ b: [Float]) -> Bool {
    guard a.count == b.count else { return false }
    for i in a.indices {
        if a[i] != b[i] && !(a[i].isNaN && b[i].isNaN) { return false }
    }
    return true
}

private func r2(_ v: Float) -> Double {
    (Double(v) * 100.0).rounded() / 100.0
}

private func r3(_ v: Double) -> Double {
    (v * 1000.0).rounded() / 1000.0
}

private func jsonEscape(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 0x22: out += "\\\""
        case 0x5C: out += "\\\\"
        case 0x0A: out += "\\n"
        case 0x0D: out += "\\r"
        case 0x09: out += "\\t"
        case 0x00..<0x20:
            let hex = String(scalar.value, radix: 16, uppercase: false)
            out += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    out += "\""
    return out
}
