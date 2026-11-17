import Foundation

/// A Chrome Trace Event Format value.
public enum TraceValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case integer(Int64)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let intVal = try? container.decode(Int64.self) {
            self = .integer(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .number(doubleVal)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try container.encode(s)
        case .number(let d):
            try container.encode(d)
        case .integer(let i):
            try container.encode(i)
        case .bool(let b):
            try container.encode(b)
        }
    }
}

/// A single event in Chrome Trace Event Format (`chrome://tracing` / Perfetto).
public struct TraceEvent: Sendable, Equatable, Codable {
    public enum Phase: String, Sendable, Equatable, Codable {
        case complete = "X"
        case begin = "B"
        case end = "E"
        case instant = "i"
        case counter = "C"
        case metadata = "M"
    }

    public var name: String
    public var cat: String
    public var ph: Phase
    public var ts: UInt64
    public var dur: UInt64?
    public var pid: Int32
    public var tid: UInt64
    public var args: [String: TraceValue]?

    public init(
        name: String,
        cat: String = "default",
        ph: Phase,
        ts: UInt64,
        dur: UInt64? = nil,
        pid: Int32 = ProcessSampler.currentProcessID,
        tid: UInt64 = 1,
        args: [String: TraceValue]? = nil
    ) {
        self.name = name
        self.cat = cat
        self.ph = ph
        self.ts = ts
        self.dur = dur
        self.pid = pid
        self.tid = tid
        self.args = args
    }
}

/// Chrome Trace Event Format JSON document.
public struct ChromeTraceDocument: Sendable, Equatable, Codable {
    public var traceEvents: [TraceEvent]
    public var displayTimeUnit: String

    public init(traceEvents: [TraceEvent], displayTimeUnit: String = "ms") {
        self.traceEvents = traceEvents
        self.displayTimeUnit = displayTimeUnit
    }
}

/// Exports `PerfRecorder` spans, counters, and frames to Chrome Trace Event JSON.
public enum ChromeTraceExporter {
    public static func buildDocument(
        from recorder: PerfRecorder,
        pid: Int32 = ProcessSampler.currentProcessID
    ) -> ChromeTraceDocument {
        var events: [TraceEvent] = []

        for span in recorder.completedSpans {
            let args = span.args.isEmpty ? nil : span.args.mapValues { TraceValue.string($0) }
            events.append(
                TraceEvent(
                    name: span.name,
                    cat: span.category,
                    ph: .complete,
                    ts: span.startUs,
                    dur: span.durationUs,
                    pid: pid,
                    tid: span.tid,
                    args: args
                )
            )
        }

        let counters = recorder.counters
        if !counters.isEmpty {
            let maxTs = events.map { $0.ts + ($0.dur ?? 0) }.max() ?? 0
            for (name, value) in counters.sorted(by: { $0.key < $1.key }) {
                events.append(
                    TraceEvent(
                        name: name,
                        cat: "counter",
                        ph: .counter,
                        ts: maxTs,
                        pid: pid,
                        tid: 0,
                        args: ["value": .integer(value)]
                    )
                )
            }
        }

        for frame in recorder.recentFrames {
            var args: [String: TraceValue] = [
                "outcome": .string(frame.outcome.rawValue),
                "seq": .integer(Int64(frame.seq)),
                "window": .integer(Int64(frame.window)),
            ]
            if let workMs = frame.workMs {
                args["work_ms"] = .number(workMs)
            }
            if let alloc = frame.allocatedBytes {
                args["allocated_bytes"] = .integer(Int64(alloc))
            }
            let durUs = UInt64((frame.workMs ?? 0) * 1000.0)
            events.append(
                TraceEvent(
                    name: "frame",
                    cat: "frame",
                    ph: .complete,
                    ts: frame.timestampMs * 1000,
                    dur: durUs,
                    pid: pid,
                    tid: frame.window,
                    args: args
                )
            )
        }

        return ChromeTraceDocument(traceEvents: events)
    }

    public static func exportData(
        from recorder: PerfRecorder,
        pid: Int32 = ProcessSampler.currentProcessID,
        prettyPrinted: Bool = false
    ) throws -> Data {
        let document = buildDocument(from: recorder, pid: pid)
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
        if prettyPrinted {
            formatting.insert(.prettyPrinted)
        }
        encoder.outputFormatting = formatting
        return try encoder.encode(document)
    }

    public static func exportJSON(
        from recorder: PerfRecorder,
        pid: Int32 = ProcessSampler.currentProcessID,
        prettyPrinted: Bool = false
    ) throws -> String {
        let data = try exportData(from: recorder, pid: pid, prettyPrinted: prettyPrinted)
        return String(decoding: data, as: UTF8.self)
    }
}
