import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ChaosMeterFrame: Sendable {
    public var start: Double
    public var workMs: Float
    public var buildMs: Float
    public var show: Float
    public var load: UInt32
    public var cpuMs: Float
    public var procMs: Float
}

public struct ChaosMeterSummary: Equatable, Sendable {
    public var frames: Int = 0
    public var seconds: Double = 0.0
    public var fps: Double = 0.0
    public var intervalMs: [Double] = [0, 0, 0, 0]
    public var workMs: [Double] = [0, 0, 0, 0]
    public var buildMs: [Double]? = nil
    public var late: Int = 0
    public var dropped: Int = 0
    public var idleGaps: Int = 0
    public var cpuPercent: Double = 0.0
    public var footprintMb: Double = 0.0
    public var footprintPeakMb: Double = 0.0
    public var residentMb: Double = 0.0
}

private let idleGapSeconds: Double = 0.1

private func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0.0 }
    let i = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[i]
}

private func spread(_ values: [Double]) -> [Double] {
    let s = values.sorted()
    return [percentile(s, 0.5), percentile(s, 0.95), percentile(s, 0.99), s.last ?? 0.0]
}

private func cpuNow() -> (Double, Double) {
    #if canImport(Darwin)
    var ts = timespec(tv_sec: 0, tv_nsec: 0)
    let thread = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) == 0
        ? Double(ts.tv_sec) + Double(ts.tv_nsec) * 1e-9
        : Double.nan
    var ru = rusage()
    let process: Double
    if getrusage(RUSAGE_SELF, &ru) == 0 {
        let utime = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) * 1e-6
        let stime = Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) * 1e-6
        process = utime + stime
    } else {
        process = Double.nan
    }
    return (thread, process)
    #else
    return (0.0, 0.0)
    #endif
}

private func memoryUsageBytes() -> (footprint: UInt64, resident: UInt64) {
    #if canImport(Darwin)
    var ru = rusage()
    let resident = getrusage(RUSAGE_SELF, &ru) == 0 ? UInt64(max(0, ru.ru_maxrss)) : 0
    return (resident, resident)
    #else
    return (0, 0)
    #endif
}

private func durationSeconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
    let d = start.duration(to: end)
    return max(0.0, Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18)
}

public struct ChaosMeter: Sendable {
    private let framework: String
    private var refreshHz: Double
    public let t0: ContinuousClock.Instant
    private var cpu0: Double
    public private(set) var frames: [ChaosMeterFrame] = []
    private var footprintPeak: UInt64 = 0
    private var footprintLast: UInt64 = 0
    private var footprintAt: Double = -1.0
    private var residentLast: UInt64 = 0
    private var window: (Double, Double)?
    private var extra: [(String, String)] = []
    private var tagState: (Float, UInt32) = (.nan, 0)
    private var cpuLast: (Double, Double)

    public init(framework: String, refreshHz: Double) {
        self.framework = framework
        self.refreshHz = refreshHz
        self.t0 = ContinuousClock.now
        let cpu = cpuNow()
        self.cpu0 = cpu.1.isNaN ? 0.0 : cpu.1
        self.cpuLast = cpu
        self.frames.reserveCapacity(8192)
        self.sampleMemory(at: 0.0)
    }

    public mutating func setRefresh(_ hz: Double) {
        if hz > 1.0 {
            refreshHz = hz
        }
    }

    public var currentRefreshHz: Double { refreshHz }

    public var now: Double {
        durationSeconds(t0, ContinuousClock.now)
    }

    public func seconds(at instant: ContinuousClock.Instant) -> Double {
        durationSeconds(t0, instant)
    }

    public mutating func begin() {
        let n = now
        let cpu = cpuNow().1
        cpu0 = cpu.isNaN ? 0.0 : cpu
        window = (n, .infinity)
    }

    public mutating func end() {
        let n = now
        if let (from, _) = window {
            window = (from, n)
        }
    }

    public mutating func note(_ key: String, _ value: String) {
        extra.append((key, value))
    }

    public mutating func frame(at start: ContinuousClock.Instant, workMs: Double) {
        push(at: start, workMs: workMs, buildMs: .nan)
    }

    public mutating func frameWithBuild(at start: ContinuousClock.Instant, workMs: Double, buildMs: Double) {
        push(at: start, workMs: workMs, buildMs: Float(buildMs))
    }

    public mutating func tag(show: Double, load: Int) {
        tagState = (Float(show), UInt32(max(0, load)))
    }

    private mutating func push(at start: ContinuousClock.Instant, workMs: Double, buildMs: Float) {
        let s = seconds(at: start)
        let (show, load) = tagState
        let cpu = cpuNow()
        let cpuMs = Float((cpu.0 - cpuLast.0) * 1000.0)
        let procMs = Float((cpu.1 - cpuLast.1) * 1000.0)
        cpuLast = cpu
        frames.append(ChaosMeterFrame(
            start: s,
            workMs: Float(workMs),
            buildMs: buildMs,
            show: show,
            load: load,
            cpuMs: cpuMs,
            procMs: procMs
        ))
        if s - footprintAt >= 0.5 {
            sampleMemory(at: s)
        }
    }

    private mutating func sampleMemory(at t: Double) {
        let usage = memoryUsageBytes()
        footprintLast = usage.footprint
        residentLast = usage.resident
        footprintPeak = max(footprintPeak, footprintLast)
        footprintAt = t
    }

    private func counted() -> ArraySlice<ChaosMeterFrame> {
        guard let (from, to) = window else { return frames[...] }
        let startIdx = frames.firstIndex(where: { $0.start >= from }) ?? frames.endIndex
        let endIdx = frames[startIdx...].firstIndex(where: { $0.start > to }) ?? frames.endIndex
        return frames[startIdx..<endIdx]
    }

    public func summarise(_ slice: ArraySlice<ChaosMeterFrame>, seconds: Double, cpuSeconds: Double) -> ChaosMeterSummary {
        let period = 1.0 / refreshHz
        var intervals: [Double] = []
        intervals.reserveCapacity(slice.count)
        var late = 0
        var dropped = 0
        var idleGaps = 0
        var idx = slice.startIndex
        if idx < slice.endIndex {
            var next = slice.index(after: idx)
            while next < slice.endIndex {
                let iv = slice[next].start - slice[idx].start
                if iv > idleGapSeconds {
                    idleGaps += 1
                } else {
                    intervals.append(iv * 1000.0)
                    if iv > 1.5 * period {
                        late += 1
                        dropped += max(Int((iv / period).rounded()) - 1, 0)
                    }
                }
                idx = next
                next = slice.index(after: next)
            }
        }
        func mb(_ b: UInt64) -> Double { Double(b) / 1_048_576.0 }
        let builds = slice.filter { !$0.buildMs.isNaN }.map { Double($0.buildMs) }
        return ChaosMeterSummary(
            frames: slice.count,
            seconds: seconds,
            fps: seconds > 0.0 ? Double(slice.count) / seconds : 0.0,
            intervalMs: spread(intervals),
            workMs: spread(slice.map { Double($0.workMs) }),
            buildMs: builds.isEmpty ? nil : spread(builds),
            late: late,
            dropped: dropped,
            idleGaps: idleGaps,
            cpuPercent: seconds > 0.0 ? 100.0 * cpuSeconds / seconds : 0.0,
            footprintMb: mb(footprintLast),
            footprintPeakMb: mb(footprintPeak),
            residentMb: mb(residentLast)
        )
    }

    public mutating func summary() -> ChaosMeterSummary {
        let n = now
        sampleMemory(at: n)
        let (from, to) = window ?? (0.0, n)
        let seconds = min(to, n) - from
        let cpuProc = cpuNow().1
        let cpu = (cpuProc.isNaN ? 0.0 : cpuProc) - cpu0
        return summarise(counted(), seconds: seconds, cpuSeconds: cpu)
    }

    public func recent() -> ChaosMeterSummary {
        let n = now
        let a = frames.firstIndex(where: { $0.start >= n - 1.0 }) ?? frames.endIndex
        var s = summarise(frames[a...], seconds: 1.0, cpuSeconds: 0.0)
        let total = summarise(counted(), seconds: 1.0, cpuSeconds: 0.0)
        s.late = total.late
        s.dropped = total.dropped
        return s
    }

    public mutating func json() -> String {
        let s = summary()
        func arr(_ v: [Double]) -> String {
            String(format: "{\"p50\": %.3f, \"p95\": %.3f, \"p99\": %.3f, \"max\": %.3f}", v[0], v[1], v[2], v[3])
        }
        var out = "{\n"
        out += "  \"framework\": \"\(framework)\",\n"
        out += String(format: "  \"refresh_hz\": %.2f,\n", refreshHz)
        out += String(format: "  \"seconds\": %.3f,\n", s.seconds)
        out += "  \"frames\": \(s.frames),\n"
        out += String(format: "  \"fps\": %.2f,\n", s.fps)
        out += "  \"interval_ms\": \(arr(s.intervalMs)),\n"
        out += "  \"work_ms\": \(arr(s.workMs)),\n"
        if let b = s.buildMs {
            out += "  \"build_ms\": \(arr(b)),\n"
        }
        out += "  \"late_intervals\": \(s.late),\n"
        out += "  \"dropped_frames\": \(s.dropped),\n"
        out += "  \"idle_gaps\": \(s.idleGaps),\n"
        out += String(format: "  \"cpu_percent\": %.2f,\n", s.cpuPercent)
        out += String(format: "  \"footprint_mb\": %.2f,\n", s.footprintMb)
        out += String(format: "  \"footprint_peak_mb\": %.2f,\n", s.footprintPeakMb)
        out += String(format: "  \"resident_mb\": %.2f", s.residentMb)
        for (k, v) in extra {
            let escaped = v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            out += ",\n  \"\(k)\": \"\(escaped)\""
        }
        out += "\n}\n"
        return out
    }

    public func tail(_ n: Int) -> [(Float, Float)] {
        let startIdx = max(0, frames.count - n)
        return frames[startIdx...].map { ($0.show, $0.buildMs.isNaN ? $0.workMs : $0.buildMs) }
    }

    public func framesCSV() -> String {
        var out = "show_s,load,build_ms,work_ms,start_s,cpu_ms,proc_ms\n"
        for f in frames {
            out += String(
                format: "%.4f,%u,%.4f,%.4f,%.4f,%.4f,%.4f\n",
                f.show, f.load, f.buildMs, f.workMs, f.start, f.cpuMs, f.procMs
            )
        }
        return out
    }
}
