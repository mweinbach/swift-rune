import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Frame update phase indices matching `tooling::interaction::PHASE_NAMES`.
public enum InteractionPhase: Int, CaseIterable, Sendable {
    case view = 0
    case commit = 1
    case layout = 2
    case text = 3
    case paint = 4
    case apply = 5

    public static let attributeNames: [String] = [
        "rune.view_ms",
        "rune.commit_ms",
        "rune.layout_ms",
        "rune.text_ms",
        "rune.paint_ms",
        "rune.apply_ms",
    ]
}

// MARK: - Cause (tooling/interaction/cause.rs)

/// Root-cause classification for a slow frame or interaction.
public enum InteractionCause: String, Sendable, Equatable {
    case cpu
    case blocked
    case schedulerWait = "scheduler_wait"
    case queued

    /// Classifies why a frame took `workMs` (> `slowMs`), using thread CPU share, watchdog samples,
    /// and system run-queue load.
    public static func classify(
        workMs: Double,
        slowMs: Double,
        cpuMs: Double?,
        stacks: InteractionStacks?,
        overloaded: Bool
    ) -> InteractionCause {
        if workMs <= slowMs { return .queued }
        let sampled = stacks.flatMap { $0.taken > 0 ? $0 : nil }
        if let s = sampled, 2 * s.waiting > s.taken {
            return .blocked
        }
        let share = cpuMs.map { $0 / workMs } ?? sampled?.cpuShare
        if let share, share >= 0.5 {
            return .cpu
        }
        if share == nil && !overloaded {
            return .cpu
        }
        if overloaded || (sampled?.taken ?? 0) >= 2 {
            return .schedulerWait
        }
        return .blocked
    }
}

// MARK: - Names (tooling/interaction/names.rs)

/// Privacy-preserving, interned path normalizer (`tooling::interaction::Names`).
public final class InteractionNames {
    public static let controlSegments: Int = 4
    public static let pageSegments: Int = 3
    public static let segmentChars: Int = 32

    public struct Name: Hashable, Sendable {
        public var hash: UInt64
        public var text: String
    }

    private var table: [UInt64: String] = [:]

    public init() {}

    public func control(path: String) -> Name {
        intern(Self.normalize(path: path, keep: Self.controlSegments))
    }

    public func route(page: String?, modal: String?) -> Name {
        var out: String
        if let page {
            out = Self.normalize(path: page, keep: Self.pageSegments)
        } else {
            out = "root"
        }
        if out.isEmpty { out = "root" }
        if let modal {
            out += "+modal:"
            let norm = Self.normalize(path: modal, keep: 1)
            out += norm.isEmpty ? "*" : norm
        }
        return intern(out)
    }

    public func fixed(_ name: String) -> Name {
        intern(name)
    }

    private func intern(_ value: String) -> Name {
        let h = Self.fxHash(value)
        let stored = table[h] ?? {
            table[h] = value
            return value
        }()
        return Name(hash: h, text: stored)
    }

    public static func fxHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash &*= 0x0100_0000_01b3
        }
        return hash
    }

    /// Writes `path`'s last `keep` keyed segments, normalized, joined by `/`.
    public static func normalize(path: String, keep: Int) -> String {
        let keyed = path.split(separator: "/").filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let dropCount = max(0, keyed.count - keep)
        var parts: [String] = []
        for seg in keyed.dropFirst(dropCount) {
            parts.append(normalizeSegment(String(seg)))
        }
        return parts.joined(separator: "/")
    }

    private static func normalizeSegment(_ seg: String) -> String {
        if seg.contains(where: \.isWhitespace) { return "~" }
        var out = ""
        var i = seg.startIndex
        while i < seg.endIndex {
            let ch = seg[i]
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                var end = seg.index(after: i)
                while end < seg.endIndex, seg[end].isASCII && (seg[end].isLetter || seg[end].isNumber) {
                    end = seg.index(after: end)
                }
                let word = seg[i..<end]
                let hasDigit = word.contains { $0.isASCII && $0.isNumber }
                if hasDigit && word.count >= 8 {
                    if !out.hasSuffix("*") { out.append("*") }
                } else {
                    for c in word {
                        if c.isASCII && c.isNumber {
                            if !out.hasSuffix("*") { out.append("*") }
                        } else {
                            out.append(c)
                        }
                    }
                }
                i = end
            } else {
                out.append(["-", "_", ".", ":"].contains(ch) ? ch : "_")
                i = seg.index(after: i)
            }
            if out.count >= segmentChars {
                return String(out.prefix(segmentChars))
            }
        }
        return out
    }
}

// MARK: - Rollup (tooling/interaction/rollup.rs)

/// Per-signature 64-bucket logarithmic latency histogram (`0.1 ms` * `1.15^i`).
public final class InteractionRollup {
    public static let bucketCount: Int = 64
    public static let firstMs: Double = 0.1
    public static let stepFactor: Double = 1.15

    public struct Roll: Sendable, Equatable {
        public var route: InteractionNames.Name
        public var control: InteractionNames.Name
        public var action: String
        public var count: UInt32
        public var slow: UInt32
        public var contended: UInt32
        public var maxMs: Double
        public var buckets: [UInt32]

        public func quantile(_ q: Double) -> Double {
            let clampedCount = max(1, count)
            let rank = UInt32(max(1, min(Int(clampedCount), Int(ceil(q * Double(count))))))
            var seen: UInt32 = 0
            for (i, n) in buckets.enumerated() {
                seen += n
                if seen >= rank {
                    return min(Self.upperBound(for: i), maxMs)
                }
            }
            return maxMs
        }

        public static func upperBound(for bucket: Int) -> Double {
            firstMs * pow(stepFactor, Double(bucket))
        }
    }

    private var rolls: [UInt64: Roll] = [:]

    public init() {}

    public static func signature(route: InteractionNames.Name, control: InteractionNames.Name, action: String) -> UInt64 {
        let cRot = (control.hash << 21) | (control.hash >> (64 - 21))
        let aHash = InteractionNames.fxHash(action)
        let aRot = (aHash << 42) | (aHash >> (64 - 42))
        return route.hash ^ cRot ^ aRot
    }

    public static func bucket(forMs ms: Double) -> Int {
        if ms <= firstMs { return 0 }
        let raw = ceil(log(ms / firstMs) / log(stepFactor))
        return Int(max(0.0, min(Double(bucketCount - 1), raw)))
    }

    public var isEmpty: Bool { rolls.isEmpty }

    public func add(
        route: InteractionNames.Name,
        control: InteractionNames.Name,
        action: String,
        ms: Double,
        slow: Bool,
        contended: Bool
    ) {
        let sig = Self.signature(route: route, control: control, action: action)
        var roll = rolls[sig] ?? Roll(
            route: route,
            control: control,
            action: action,
            count: 0,
            slow: 0,
            contended: 0,
            maxMs: 0,
            buckets: [UInt32](repeating: 0, count: Self.bucketCount)
        )
        roll.count += 1
        if slow { roll.slow += 1 }
        if contended { roll.contended += 1 }
        roll.maxMs = max(roll.maxMs, ms)
        roll.buckets[Self.bucket(forMs: ms)] += 1
        rolls[sig] = roll
    }

    public func takeAll() -> [Roll] {
        let values = Array(rolls.values)
        rolls.removeAll(keepingCapacity: true)
        return values
    }
}

// MARK: - Stack & Watchdog (tooling/interaction/stack.rs, watchdog.rs)

public struct InteractionStackFrame: Sendable, Equatable {
    public var name: String
    public var isApp: Bool

    public init(name: String, isApp: Bool) {
        self.name = name
        self.isApp = isApp
    }
}

public struct InteractionRawStack: Sendable, Equatable {
    public var pcs: [UInt]
    public var waiting: Bool
    public var cpuUs: UInt64
    public var imagesGeneration: UInt64

    public init(pcs: [UInt], waiting: Bool, cpuUs: UInt64, imagesGeneration: UInt64 = 0) {
        self.pcs = pcs
        self.waiting = waiting
        self.cpuUs = cpuUs
        self.imagesGeneration = imagesGeneration
    }
}

public final class InteractionSymbolCache {
    private var generation: UInt64 = 0
    private var known: [UInt: InteractionStackFrame] = [:]

    public init() {}

    public func frames(
        for raw: InteractionRawStack,
        generation nowGen: () -> UInt64,
        lookup: (UInt) -> InteractionStackFrame
    ) -> [InteractionStackFrame] {
        let now = nowGen()
        if now != generation {
            known.removeAll()
            generation = now
        }
        if now != raw.imagesGeneration {
            return raw.pcs.map { InteractionStackFrame(name: String(format: "0x%lx", $0), isApp: false) }
        }
        var out: [InteractionStackFrame] = []
        out.reserveCapacity(raw.pcs.count)
        for (i, pc) in raw.pcs.enumerated() {
            let addr = (i == 0) ? pc : (pc > 0 ? pc - 1 : 0)
            if let cached = known[addr] {
                out.append(cached)
            } else {
                let resolved = lookup(addr)
                known[addr] = resolved
                out.append(resolved)
            }
        }
        if nowGen() != now {
            return raw.pcs.map { InteractionStackFrame(name: String(format: "0x%lx", $0), isApp: false) }
        }
        return out
    }
}

/// Demangling & frame classification helpers (`tooling/interaction/stack.rs`).
public enum InteractionDemangle {
    private typealias SwiftDemangleFn = @convention(c) (
        UnsafePointer<CChar>?,
        Int,
        UnsafeMutablePointer<CChar>?,
        UnsafeMutablePointer<Int>?,
        UInt32
    ) -> UnsafeMutablePointer<CChar>?

    #if canImport(Darwin)
    private static let swiftDemangleFn: SwiftDemangleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { // RTLD_DEFAULT
            return nil
        }
        return unsafeBitCast(sym, to: SwiftDemangleFn.self)
    }()
    #endif

    /// Demangles a symbol name (Swift `$s...`, Darwin leading `_`, or Rust hash suffix).
    public static func demangled(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var name = raw
        #if canImport(Darwin)
        let checkSwift = name.hasPrefix("_$s") || name.hasPrefix("$s") || name.hasPrefix("_$S") || name.hasPrefix("$S") || name.hasPrefix("_T")
        if checkSwift, let fn = swiftDemangleFn {
            let result = name.withCString { cstr -> String? in
                let len = strlen(cstr)
                guard let out = fn(cstr, len, nil, nil, 0) else { return nil }
                defer { free(out) }
                return String(cString: out)
            }
            if let result, !result.isEmpty {
                return result
            }
        }
        if name.hasPrefix("_") && !name.hasPrefix("__") {
            name.removeFirst()
        }
        #endif
        // Strip Rust trailing `::h<16-hex>` hash suffix when present.
        if let range = name.range(of: "::h"), name.distance(from: range.upperBound, to: name.endIndex) == 16 {
            let suffix = name[range.upperBound...]
            if suffix.allSatisfy({ $0.isHexDigit }) {
                name = String(name[..<range.lowerBound])
            }
        }
        return name
    }

    /// Returns `true` when `name` belongs to Rune, Swift/Rust stdlib, or system libraries rather than app code.
    public static func isLibrary(_ name: String) -> Bool {
        let prefixes = [
            "rune::", "rune_scene::", "rune_text::", "rune_layout::",
            "Rune.", "RuneScene.", "RuneText.", "RuneLayout.", "RuneMotion.", "RuneMac.",
            "std::", "core::", "alloc::", "Swift.", "Foundation.", "AppKit.", "UIKit.",
            "CoreFoundation", "CoreGraphics", "QuartzCore", "Metal", "Dispatch",
            "libsystem_", "libdyld", "dyld", "libobjc", "libswift",
            "_pthread", "pthread_", "mach_msg", "start", "main",
        ]
        if prefixes.contains(where: { name.hasPrefix($0) || name.contains(" \($0)") }) {
            return true
        }
        // Swift closure/thunk wrappers inside Rune modules: e.g. `closure #1 in Rune.`
        if name.contains("in Rune.") || name.contains("in RuneScene.") || name.contains("in RuneMac.") {
            return true
        }
        return false
    }
}

/// Bounded caught-sample store for the watchdog thread (`MOST = 64`, `watchdog.rs` / `watchdog_tests.rs`).
public final class InteractionCaughtSamples: @unchecked Sendable {
    public static let maxSamples: Int = InteractionWatchdog.maxSamples

    public struct Entry: Sendable, Equatable {
        public var seq: UInt64
        public var sample: InteractionSampledStack
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var currentSeq: UInt64 = 0

    public init() {
        entries.reserveCapacity(Self.maxSamples)
    }

    /// Publishes one sample for `seq` and sets `taken` before returning (`watchdog.rs::Caught::publish`).
    public func publish(
        taken: InteractionWatchdogTakenFlag,
        seq: UInt64,
        atNs: UInt64,
        raw: InteractionRawStack
    ) {
        lock.lock()
        if seq != currentSeq {
            entries.removeAll(keepingCapacity: true)
            currentSeq = seq
        }
        guard entries.count < Self.maxSamples else {
            lock.unlock()
            return
        }
        entries.append(Entry(seq: seq, sample: InteractionSampledStack(raw: raw, atNs: atNs)))
        lock.unlock()
        taken.store(true)
    }

    /// Summarizes frame `seq`'s samples without draining them (`watchdog.rs::Caught::collect`).
    public func collect(for seq: UInt64) -> InteractionStacks? {
        lock.lock()
        guard seq == currentSeq else {
            lock.unlock()
            return nil
        }
        let samples = entries.map(\.sample)
        lock.unlock()
        return InteractionStacks.from(samples: samples)
    }

    public func push(seq: UInt64, sample: InteractionSampledStack) {
        lock.lock()
        defer { lock.unlock() }
        if seq != currentSeq {
            entries.removeAll(keepingCapacity: true)
            currentSeq = seq
        }
        if entries.count < Self.maxSamples {
            entries.append(Entry(seq: seq, sample: sample))
        }
    }

    public func take(for seq: UInt64) -> [InteractionSampledStack] {
        lock.lock()
        defer { lock.unlock() }
        guard seq == currentSeq else { return [] }
        let out = entries.map(\.sample)
        entries.removeAll(keepingCapacity: true)
        return out
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}

/// Live target thread handle for cross-thread sampling (`tooling/interaction/stack.rs`).
public final class InteractionThreadSamplerTarget: @unchecked Sendable {
    public static let maxCapturedFrames: Int = 48

    #if os(macOS) && arch(arm64)
    private let machThread: thread_t
    private let stackLow: UInt
    private let stackHigh: UInt
    #endif

    #if os(macOS) && arch(arm64)
    private init(machThread: thread_t, stackLow: UInt, stackHigh: UInt) {
        self.machThread = machThread
        self.stackLow = stackLow
        self.stackHigh = stackHigh
    }
    #else
    private init() {}
    #endif

    /// Captures the calling thread so the watchdog can suspend and walk its stack from another thread.
    public static func current() -> InteractionThreadSamplerTarget? {
        #if os(macOS) && arch(arm64)
        let selfPthread = pthread_self()
        let machThread = pthread_mach_thread_np(selfPthread)
        guard machThread != MACH_PORT_NULL else {
            return nil
        }
        let stackTopPtr = pthread_get_stackaddr_np(selfPthread)
        let stackSize = UInt(pthread_get_stacksize_np(selfPthread))
        let stackHigh = UInt(bitPattern: stackTopPtr)
        let stackLow = stackHigh >= stackSize ? stackHigh - stackSize : 0
        return InteractionThreadSamplerTarget(machThread: machThread, stackLow: stackLow, stackHigh: stackHigh)
        #else
        return nil
        #endif
    }

    /// Samples this target thread's call stack and CPU usage from a background watchdog thread.
    /// Returns `nil` if called on the target thread itself or if `still()` returns `false`.
    public func sample(still: () -> Bool) -> InteractionRawStack? {
        sampleImpl(still: still, onStopped: nil)
    }

    public func sample(still: () -> Bool, onStopped: (InteractionRawStack) -> Void) -> InteractionRawStack? {
        withoutActuallyEscaping(onStopped) { escapingStopped in
            sampleImpl(still: still, onStopped: escapingStopped)
        }
    }

    private func sampleImpl(still: () -> Bool, onStopped: ((InteractionRawStack) -> Void)?) -> InteractionRawStack? {
        #if os(macOS) && arch(arm64)
        let callerMach = pthread_mach_thread_np(pthread_self())
        guard callerMach != machThread else { return nil }

        // Read thread CPU time & run state via THREAD_BASIC_INFO BEFORE suspending the thread
        // (`stack.rs:168-214`) so we observe real wait state and perform zero Mach/heap calls while suspended.
        var basic = thread_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let basicKr = withUnsafeMutablePointer(to: &basic) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { intPtr in
                thread_info(machThread, thread_flavor_t(THREAD_BASIC_INFO), intPtr, &basicCount)
            }
        }
        let cpuUs: UInt64
        let waiting: Bool
        if basicKr == KERN_SUCCESS {
            cpuUs = UInt64(basic.user_time.seconds) * 1_000_000 + UInt64(basic.user_time.microseconds)
                + UInt64(basic.system_time.seconds) * 1_000_000 + UInt64(basic.system_time.microseconds)
            waiting = (basic.run_state == TH_STATE_WAITING || basic.run_state == TH_STATE_UNINTERRUPTIBLE)
        } else {
            cpuUs = 0
            waiting = false
        }

        // Pre-allocate fixed PC buffer before suspending the target thread so zero heap
        // allocations or locks occur between `thread_suspend` and `thread_resume`.
        let maxFrames = Self.maxCapturedFrames
        let rawPCs = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
        defer { rawPCs.deallocate() }
        var pcCount = 0
        var pcs: [UInt] = []
        pcs.reserveCapacity(maxFrames)

        guard thread_suspend(machThread) == KERN_SUCCESS else { return nil }
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.stride / MemoryLayout<natural_t>.stride)
        let stateKr: kern_return_t
        if still() {
            stateKr = withUnsafeMutablePointer(to: &state) { ptr in
                ptr.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) { natPtr in
                    thread_get_state(machThread, ARM_THREAD_STATE64, natPtr, &stateCount)
                }
            }
            if stateKr == KERN_SUCCESS {
                let pc0 = UInt(state.__pc) & 0x0000_7fff_ffff_ffff
                if pc0 != 0 && pcCount < maxFrames {
                    rawPCs[pcCount] = pc0
                    pcCount += 1
                }
                var fp = UInt(state.__fp)
                var prevFp: UInt = 0
                while pcCount < maxFrames,
                      fp > prevFp,
                      (fp & 0x7) == 0,
                      fp >= stackLow,
                      fp + UInt(MemoryLayout<UInt>.stride * 2) <= stackHigh,
                      let fpPtr = UnsafePointer<UInt>(bitPattern: fp) {
                    let nextFp = fpPtr[0]
                    let lr = fpPtr[1] & 0x0000_7fff_ffff_ffff
                    if lr != 0 {
                        rawPCs[pcCount] = lr
                        pcCount += 1
                    }
                    if nextFp == 0 { break }
                    prevFp = fp
                    fp = nextFp
                }
            }
        } else {
            stateKr = KERN_ABORTED
        }
        var capturedRaw: InteractionRawStack? = nil
        if stateKr == KERN_SUCCESS {
            for i in 0..<pcCount {
                pcs.append(rawPCs[i])
            }
            let raw = InteractionRawStack(pcs: pcs, waiting: waiting, cpuUs: cpuUs, imagesGeneration: 0)
            onStopped?(raw)
            capturedRaw = raw
        }
        _ = thread_resume(machThread)

        return capturedRaw
        #else
        return nil
        #endif
    }

    /// Resolves a raw stack using `dladdr` + `InteractionDemangle` and caches resolved frames.
    public static func resolveFrames(
        for raw: InteractionRawStack,
        cache: InteractionSymbolCache
    ) -> [InteractionStackFrame] {
        cache.frames(for: raw, generation: { 0 }) { addr in
            #if canImport(Darwin)
            var info = Dl_info()
            if let ptr = UnsafeRawPointer(bitPattern: addr),
               dladdr(ptr, &info) != 0,
               let sname = info.dli_sname {
                let rawName = String(cString: sname)
                let demangled = InteractionDemangle.demangled(rawName)
                return InteractionStackFrame(name: demangled, isApp: !InteractionDemangle.isLibrary(demangled))
            }
            #endif
            return InteractionStackFrame(name: String(format: "0x%lx", addr), isApp: false)
        }
    }
}

public struct InteractionSampledStack: Sendable, Equatable {
    public var raw: InteractionRawStack
    public var atNs: UInt64

    public init(raw: InteractionRawStack, atNs: UInt64) {
        self.raw = raw
        self.atNs = atNs
    }
}

public struct InteractionStacks: Sendable, Equatable {
    public struct NamedSummary: Sendable, Equatable {
        public var hot: [(name: String, count: UInt32)]
        public var stack: [String]

        public static func == (lhs: NamedSummary, rhs: NamedSummary) -> Bool {
            lhs.stack == rhs.stack
                && lhs.hot.count == rhs.hot.count
                && zip(lhs.hot, rhs.hot).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }
    }

    public var taken: UInt32
    public var waiting: UInt32
    public var cpuShare: Double?
    public var raw: [InteractionRawStack]

    public init(taken: UInt32, waiting: UInt32, cpuShare: Double?, raw: [InteractionRawStack]) {
        self.taken = taken
        self.waiting = waiting
        self.cpuShare = cpuShare
        self.raw = raw
    }

    public static func from(samples: [InteractionSampledStack]) -> InteractionStacks? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let wallUs = last.atNs >= first.atNs ? (last.atNs - first.atNs) / 1000 : 0
        let cpuShare: Double? = (samples.count >= 2 && wallUs > 0)
            ? Double(last.raw.cpuUs >= first.raw.cpuUs ? last.raw.cpuUs - first.raw.cpuUs : 0) / Double(wallUs)
            : nil
        return InteractionStacks(
            taken: UInt32(samples.count),
            waiting: UInt32(samples.filter(\.raw.waiting).count),
            cpuShare: cpuShare,
            raw: samples.map(\.raw)
        )
    }

    public func names(resolver: (InteractionRawStack) -> [InteractionStackFrame]) -> NamedSummary {
        let named = raw.map(resolver)
        func spot(_ frames: [InteractionStackFrame]) -> String? {
            (frames.first(where: \.isApp) ?? frames.first)?.name
        }
        var counts: [String: UInt32] = [:]
        var order: [String] = []
        for frames in named {
            guard let name = spot(frames) else { continue }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        var hot: [(name: String, count: UInt32)] = order.map { ($0, counts[$0] ?? 0) }
        hot.sort { $0.count > $1.count }
        let top = hot.first?.name
        let stack = named.first(where: { spot($0) == top })?.prefix(16).map(\.name) ?? []
        if hot.count > 3 { hot = Array(hot.prefix(3)) }
        return NamedSummary(hot: hot, stack: stack)
    }
}

/// Deterministic watchdog state machine (`tooling/interaction/watchdog.rs`).
public enum InteractionWatchdog {
    public static let afterMs: UInt32 = 12
    public static let hurryMs: UInt32 = 4
    public static let maxSamples: Int = 64
    public static let sampleIntervalNs: UInt64 = 4_000_000
    public static let idlePollNs: UInt64 = 8_000_000
    public static let restNs: UInt64 = 1_000_000_000

    public struct RunningFrame: Sendable, Equatable {
        public var seq: UInt64
        public var startNs: UInt64
        public var afterUs: UInt32

        public init(seq: UInt64, startNs: UInt64, afterUs: UInt32) {
            self.seq = seq
            self.startNs = startNs
            self.afterUs = afterUs
        }
    }

    public struct Progress: Sendable, Equatable {
        public var seq: UInt64
        public var taken: Int
        public var dueNs: UInt64

        public init(seq: UInt64, taken: Int, dueNs: UInt64) {
            self.seq = seq
            self.taken = taken
            self.dueNs = dueNs
        }
    }

    public enum WatchState: Sendable, Equatable {
        case unarmed
        case waiting(seq: UInt64, dueNs: UInt64)
        case sampling(Progress)
        case quiet(sinceNs: UInt64, left: Progress?)
        case parked(left: Progress?)

        public func progress(for seq: UInt64) -> Progress? {
            switch self {
            case .sampling(let p) where p.seq == seq: return p
            case .quiet(_, let p?) where p.seq == seq: return p
            case .parked(let p?) where p.seq == seq: return p
            default: return nil
            }
        }
    }

    public enum Event: Sendable, Equatable {
        case look(frame: RunningFrame?, nowNs: UInt64)
        case taken(seq: UInt64, nowNs: UInt64)
    }

    public enum Effect: Sendable, Equatable {
        case sleepNs(UInt64)
        case park
        case sample(seq: UInt64, startNs: UInt64, atNs: UInt64)
    }

    public static func step(_ watch: inout WatchState, event: Event) -> [Effect] {
        switch event {
        case let .look(frame: nil, nowNs: now):
            let since: UInt64
            let left: Progress?
            switch watch {
            case .parked:
                return [.park]
            case .quiet(let s, let l):
                since = s
                left = l
            case .sampling(let p):
                since = now
                left = p
            case .unarmed, .waiting:
                since = now
                left = nil
            }
            if now >= since && (now - since) < restNs {
                watch = .quiet(sinceNs: since, left: left)
                return [.sleepNs(idlePollNs)]
            } else {
                watch = .parked(left: left)
                return [.park]
            }

        case let .look(frame: .some(running), nowNs: now):
            let progress = watch.progress(for: running.seq)
                ?? Progress(seq: running.seq, taken: 0, dueNs: running.startNs + UInt64(running.afterUs) * 1000)
            watch = (progress.taken == 0)
                ? .waiting(seq: running.seq, dueNs: progress.dueNs)
                : .sampling(progress)
            if progress.taken >= maxSamples {
                return [.sleepNs(idlePollNs)]
            } else if now < progress.dueNs {
                return [.sleepNs(progress.dueNs - now)]
            } else {
                return [.sample(seq: running.seq, startNs: running.startNs, atNs: now)]
            }

        case let .taken(seq: seq, nowNs: now):
            let takenCount: Int
            switch watch {
            case .waiting(let held, _) where held == seq:
                takenCount = 0
            case .sampling(let p) where p.seq == seq:
                takenCount = p.taken
            default:
                return []
            }
            watch = .sampling(Progress(seq: seq, taken: takenCount + 1, dueNs: now + sampleIntervalNs))
            return []
        }
    }

    public static func look(frames: any InteractionWatchdogFrames) -> RunningFrame? {
        let start = frames.readStart()
        if start == 0 { return nil }
        let seq = frames.readSeq()
        return RunningFrame(seq: seq, startNs: start, afterUs: frames.readAfterUs())
    }

    public static func begin(frames: any InteractionWatchdogFrames, now: () -> UInt64) {
        frames.nextSeq()
        frames.setAfterUs(afterMs * 1000)
        frames.setStart(now())
    }

    public static func capture(
        samples: InteractionCaughtSamples,
        taken: InteractionWatchdogTakenFlag,
        seq: UInt64,
        atNs: UInt64,
        sample: ((InteractionRawStack) -> Void) -> InteractionRawStack?
    ) {
        _ = sample { raw in
            samples.publish(taken: taken, seq: seq, atNs: atNs, raw: raw)
        }
    }

    public static func collected(
        samples: InteractionCaughtSamples,
        taken: InteractionWatchdogTakenFlag,
        seq: () -> UInt64
    ) -> InteractionStacks? {
        if !taken.swap(false) { return nil }
        return samples.collect(for: seq())
    }
}

/// Abstract frame state reads/writes for `InteractionWatchdog.look` / `begin` parity tests (`watchdog.rs::Frames`).
public protocol InteractionWatchdogFrames {
    func readStart() -> UInt64
    func readSeq() -> UInt64
    func readAfterUs() -> UInt32
    func nextSeq()
    func setAfterUs(_ us: UInt32)
    func setStart(_ ns: UInt64)
}

/// Thread-safe taken flag paired with `InteractionCaughtSamples.publish`/`collect` (`watchdog.rs::TAKEN`).
public final class InteractionWatchdogTakenFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool

    public init(_ initial: Bool = false) {
        self.flag = initial
    }

    public func load() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    public func store(_ value: Bool) {
        lock.lock()
        flag = value
        lock.unlock()
    }

    public func swap(_ value: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let prev = flag
        flag = value
        return prev
    }
}

// MARK: - Frame Machine (tooling/interaction/frame.rs)

public struct InteractionNote: Sendable {
    public var route: InteractionNames.Name
    public var control: InteractionNames.Name
    public var action: String
    public var rank: UInt8

    public init(route: InteractionNames.Name, control: InteractionNames.Name, action: String, rank: UInt8) {
        self.route = route
        self.control = control
        self.action = action
        self.rank = rank
    }
}

public struct InteractionTimed: Sendable {
    public var arrivedNs: UInt64
    public var frameStartNs: UInt64
    public var handlerMs: Double
    public var note: InteractionNote
    public var why: UInt16
    public var commits: UInt32
}

public struct InteractionBuilt: Sendable {
    public var timed: InteractionTimed
    public var atNs: UInt64
    public var phases: [Double]
    public var shaped: UInt32
    public var cpuMs: Double?
    public var stacks: InteractionStacks?
}

public enum InteractionFrameState: Sendable {
    case idle
    case begun(atNs: UInt64, queued: Bool, cpuMs: Double?, why: UInt16)
    case open(timed: InteractionTimed, inputStartNs: UInt64?, cpuMs: Double?)
    case built(InteractionBuilt)
}

public enum InteractionFrameEvent: Sendable {
    case begin(atNs: UInt64, queued: Bool, cpuMs: Double?)
    case note(note: InteractionNote, arrivedNs: UInt64?, startedNs: UInt64, handlerMs: Double)
    case commit(UInt16)
    case buildUntimed
    case buildTimed(atNs: UInt64, phases: [Double], shaped: UInt32, cpuMs: Double?, stacks: InteractionStacks?)
    case finish
}

public enum InteractionFrameEffect: Sendable {
    case startPhases
    case stopPhases
    case checkFrame(startNs: UInt64, why: UInt16)
    case count(InteractionBuilt)
}

public enum InteractionFrameMachine {
    public static func step(_ state: inout InteractionFrameState, event: InteractionFrameEvent) -> [InteractionFrameEffect] {
        switch event {
        case let .begin(atNs, queued, cpuMs):
            if case .open(let timed, _, let oldCpu) = state {
                state = .open(timed: timed, inputStartNs: queued ? atNs : nil, cpuMs: oldCpu)
            } else {
                state = .begun(atNs: atNs, queued: queued, cpuMs: cpuMs, why: 0)
            }
            return []

        case let .note(note, arrivedNs, startedNs, handlerMs):
            if case .open(var timed, var inputStartNs, let cpuMs) = state {
                let start = inputStartNs ?? startedNs
                inputStartNs = start
                timed.arrivedNs = min(timed.arrivedNs, min(arrivedNs ?? start, start))
                timed.handlerMs += handlerMs
                if note.rank > timed.note.rank {
                    timed.note = note
                }
                state = .open(timed: timed, inputStartNs: inputStartNs, cpuMs: cpuMs)
                return []
            } else {
                let frameStart: UInt64
                let cpu: Double?
                if case let .begun(atNs, queued, c, _) = state {
                    frameStart = queued ? atNs : startedNs
                    cpu = c
                } else {
                    frameStart = startedNs
                    cpu = nil
                }
                let arrived = min(arrivedNs ?? frameStart, frameStart)
                let timed = InteractionTimed(
                    arrivedNs: arrived,
                    frameStartNs: frameStart,
                    handlerMs: handlerMs,
                    note: note,
                    why: 0,
                    commits: 0
                )
                state = .open(timed: timed, inputStartNs: frameStart, cpuMs: cpu)
                return [.startPhases]
            }

        case .commit(let bits):
            switch state {
            case let .begun(atNs, queued, cpu, why):
                state = .begun(atNs: atNs, queued: queued, cpuMs: cpu, why: why | bits)
            case .open(var timed, let inputStartNs, let cpu):
                timed.why |= bits
                timed.commits += 1
                state = .open(timed: timed, inputStartNs: inputStartNs, cpuMs: cpu)
            case .idle, .built:
                break
            }
            return []

        case .buildUntimed:
            guard case let .begun(startNs, _, _, why) = state else { return [] }
            state = .idle
            return [.checkFrame(startNs: startNs, why: why)]

        case let .buildTimed(atNs, phases, shaped, cpu, stacks):
            guard case let .open(timed, _, fromCpu) = state else { return [] }
            let deltaCpu = fromCpu.flatMap { f in cpu.map { max(0, $0 - f) } }
            state = .built(InteractionBuilt(
                timed: timed,
                atNs: atNs,
                phases: phases,
                shaped: shaped,
                cpuMs: deltaCpu,
                stacks: stacks
            ))
            return [.stopPhases]

        case .finish:
            guard case let .built(built) = state else { return [] }
            state = .idle
            return [.count(built)]
        }
    }
}

// MARK: - Gate & Exporter (tooling/interaction/gate.rs, export.rs)

public enum InteractionGate {
    public static let defaultEndpoint = "127.0.0.1:27686"

    public static func wanted(perfEnv: String?, otelEnv: String?, headless: Bool) -> Bool {
        switch perfEnv?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "0": return false
        case "1": return true
        default: return !headless && otelEnv.flatMap(loopback) != nil
        }
    }

    /// Parses `"http://host:port[/path]"` or `"host:port"` when pointing at loopback (`127.0.0.1`, `localhost`, `[::1]`).
    public static func loopback(_ setting: String) -> (host: String, port: UInt16)? {
        var rest = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.hasPrefix("http://") {
            rest = String(rest.dropFirst("http://".count))
        }
        guard let hostPort = rest.split(separator: "/").first.map(String.init), !hostPort.isEmpty else {
            return nil
        }
        let normalized = hostPort.replacingOccurrences(of: "localhost", with: "127.0.0.1")
        if normalized.hasPrefix("[::1]:") {
            let portStr = String(normalized.dropFirst("[::1]:".count))
            guard let port = UInt16(portStr) else { return nil }
            return ("::1", port)
        }
        let parts = normalized.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        let host = String(parts[0])
        if host == "127.0.0.1" || host.hasPrefix("127.") {
            return (host, port)
        }
        return nil
    }

    public static func endpoint(otelEnv: String?) -> (host: String, port: UInt16) {
        otelEnv.flatMap(loopback) ?? ("127.0.0.1", 27686)
    }

    nonisolated(unsafe) public static var forceOnForTesting: Bool? = nil

    public static var isOn: Bool {
        if let forced = forceOnForTesting { return forced }
        return isEnabled()
    }

    public static func isEnabled(headless: Bool = false) -> Bool {
        let env = ProcessInfo.processInfo.environment
        return wanted(perfEnv: env["RUNE_PERF"], otelEnv: env["OTEL_EXPORTER_OTLP_ENDPOINT"], headless: headless)
    }
}

public struct SlowInteractionReport: Sendable {
    public var route: String
    public var control: String
    public var action: String
    public var arrivedNs: UInt64
    public var frameStartNs: UInt64
    public var builtNs: UInt64
    public var submittedNs: UInt64
    public var presentNs: UInt64
    public var handlerMs: Double
    public var phases: [Double]
    public var why: UInt16
    public var commits: UInt32
    public var shaped: UInt32
    public var nodes: Int
    public var reused: Int
    public var rebuilt: [(String, Int)]
    public var cpuMs: Double?
    public var cause: InteractionCause
    public var stacks: InteractionStacks?
}

public struct SlowFrameReport: Sendable {
    public var startNs: UInt64
    public var builtNs: UInt64
    public var why: UInt16
    public var nodes: Int
    public var cause: InteractionCause
    public var stacks: InteractionStacks
}

public enum InteractionExporter {
    public static func kv(_ key: String, string value: String) -> [String: Any] {
        ["key": key, "value": ["stringValue": value]]
    }

    public static func kv(_ key: String, int value: Int64) -> [String: Any] {
        ["key": key, "value": ["intValue": String(value)]]
    }

    public static func kv(_ key: String, double value: Double) -> [String: Any] {
        ["key": key, "value": ["doubleValue": value]]
    }

    private static func roundMs(_ ms: Double) -> Double {
        (ms * 1000.0).rounded() / 1000.0
    }

    private static func nextID() -> UInt64 {
        max(1, UInt64.random(in: 1...UInt64.max))
    }

    private static func spanDict(
        traceId: String,
        spanId: UInt64,
        parentSpanId: UInt64?,
        name: String,
        startUnixNs: UInt64,
        endUnixNs: UInt64,
        attrs: [[String: Any]]
    ) -> [String: Any] {
        var out: [String: Any] = [
            "traceId": traceId,
            "spanId": String(format: "%016llx", spanId),
            "name": name,
            "kind": 1,
            "startTimeUnixNano": String(startUnixNs),
            "endTimeUnixNano": String(max(startUnixNs, endUnixNs)),
            "attributes": attrs,
        ]
        if let parentSpanId {
            out["parentSpanId"] = String(format: "%016llx", parentSpanId)
        }
        return out
    }

    public static func slowSpans(_ s: SlowInteractionReport, resolver: (InteractionRawStack) -> [InteractionStackFrame] = { _ in [] }) -> [[String: Any]] {
        let traceId = String(format: "%016llx%016llx", nextID(), nextID())
        let rootId = nextID()
        let totalMs = roundMs(Double(max(s.arrivedNs, s.presentNs) - s.arrivedNs) / 1_000_000.0)
        let workMs = roundMs(Double(max(s.frameStartNs, s.submittedNs) - s.frameStartNs) / 1_000_000.0)

        var attrs: [[String: Any]] = [
            kv("rune.route", string: s.route),
            kv("rune.control", string: s.control),
            kv("rune.action", string: s.action),
            kv("rune.signature", string: "\(s.route) \(s.control) \(s.action)"),
            kv("rune.input_to_present_ms", double: totalMs),
            kv("rune.work_ms", double: workMs),
            kv("rune.nodes", int: Int64(s.nodes)),
            kv("rune.reused_nodes", int: Int64(s.reused)),
            kv("rune.commits", int: Int64(s.commits)),
            kv("rune.shaped", int: Int64(s.shaped)),
        ]
        let why = CommitWhy.names(s.why)
        if !why.isEmpty {
            attrs.append(kv("rune.commit_why", string: why.joined(separator: ",")))
        }
        let rebuiltKeys = ["rune.rebuilt.0", "rune.rebuilt.1", "rune.rebuilt.2"]
        for (i, pair) in s.rebuilt.prefix(3).enumerated() {
            attrs.append(kv(rebuiltKeys[i], string: "\(pair.0) (\(pair.1))"))
        }
        attrs.append(kv("rune.cause", string: s.cause.rawValue))
        if let cpu = s.cpuMs {
            attrs.append(kv("rune.cpu_ms", double: roundMs(cpu)))
        }
        if let stacks = s.stacks {
            appendStackAttrs(stacks, to: &attrs, resolver: resolver)
        }

        var out = [spanDict(
            traceId: traceId,
            spanId: rootId,
            parentSpanId: nil,
            name: "ui.interaction",
            startUnixNs: s.arrivedNs,
            endUnixNs: s.presentNs,
            attrs: attrs
        )]

        var updateAttrs = [kv("rune.handler_ms", double: roundMs(s.handlerMs))]
        for (i, attrName) in InteractionPhase.attributeNames.enumerated() where i < s.phases.count && s.phases[i] > 0 {
            updateAttrs.append(kv(attrName, double: roundMs(s.phases[i])))
        }

        let stretches: [(String, UInt64, UInt64, [[String: Any]])] = [
            ("queue_wait", s.arrivedNs, s.frameStartNs, []),
            ("update", s.frameStartNs, s.builtNs, updateAttrs),
            ("encode", s.builtNs, s.submittedNs, []),
            ("present_wait", s.submittedNs, s.presentNs, []),
        ]
        for (name, from, to, stretchAttrs) in stretches where to > from {
            out.append(spanDict(
                traceId: traceId,
                spanId: nextID(),
                parentSpanId: rootId,
                name: name,
                startUnixNs: from,
                endUnixNs: to,
                attrs: stretchAttrs
            ))
        }
        return out
    }

    public static func frameSpan(_ f: SlowFrameReport, resolver: (InteractionRawStack) -> [InteractionStackFrame] = { _ in [] }) -> [String: Any] {
        let traceId = String(format: "%016llx%016llx", nextID(), nextID())
        let workMs = roundMs(Double(max(f.startNs, f.builtNs) - f.startNs) / 1_000_000.0)
        var attrs: [[String: Any]] = [
            kv("rune.work_ms", double: workMs),
            kv("rune.nodes", int: Int64(f.nodes)),
            kv("rune.cause", string: f.cause.rawValue),
        ]
        let why = CommitWhy.names(f.why)
        if !why.isEmpty {
            attrs.append(kv("rune.commit_why", string: why.joined(separator: ",")))
        }
        appendStackAttrs(f.stacks, to: &attrs, resolver: resolver)
        return spanDict(
            traceId: traceId,
            spanId: nextID(),
            parentSpanId: nil,
            name: "ui.frame",
            startUnixNs: f.startNs,
            endUnixNs: f.builtNs,
            attrs: attrs
        )
    }

    public static func rollSpan(_ r: InteractionRollup.Roll, fromNs: UInt64, toNs: UInt64) -> [String: Any] {
        let traceId = String(format: "%016llx%016llx", nextID(), nextID())
        let attrs: [[String: Any]] = [
            kv("rune.route", string: r.route.text),
            kv("rune.control", string: r.control.text),
            kv("rune.action", string: r.action),
            kv("rune.count", int: Int64(r.count)),
            kv("rune.slow", int: Int64(r.slow)),
            kv("rune.scheduler_wait", int: Int64(r.contended)),
            kv("rune.p50_ms", double: roundMs(r.quantile(0.5))),
            kv("rune.p98_ms", double: roundMs(r.quantile(0.98))),
            kv("rune.max_ms", double: roundMs(r.maxMs)),
        ]
        return spanDict(
            traceId: traceId,
            spanId: nextID(),
            parentSpanId: nil,
            name: "ui.rollup",
            startUnixNs: fromNs,
            endUnixNs: toNs,
            attrs: attrs
        )
    }

    public static func encodeOTLPBody(serviceName: String = "rune-app", spans: [[String: Any]]) throws -> String {
        let resource: [String: Any] = [
            "attributes": [
                kv("service.name", string: serviceName),
                kv("process.pid", int: Int64(ProcessInfo.processInfo.processIdentifier)),
            ]
        ]
        let payload: [String: Any] = [
            "resourceSpans": [[
                "resource": resource,
                "scopeSpans": [[
                    "scope": ["name": "rune.interaction"],
                    "spans": spans,
                ]],
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func appendStackAttrs(
        _ s: InteractionStacks,
        to attrs: inout [[String: Any]],
        resolver: (InteractionRawStack) -> [InteractionStackFrame]
    ) {
        attrs.append(kv("rune.samples", int: Int64(s.taken)))
        attrs.append(kv("rune.samples_waiting", int: Int64(s.waiting)))
        let names = s.names(resolver: resolver)
        let keys = ["rune.hot.0", "rune.hot.1", "rune.hot.2"]
        for (i, item) in names.hot.prefix(3).enumerated() {
            attrs.append(kv(keys[i], string: "\(item.name) (\(item.count)/\(s.taken))"))
        }
        if !names.stack.isEmpty {
            attrs.append(kv("rune.stack", string: names.stack.joined(separator: "\n")))
        }
    }
}

// MARK: - InteractionTracker (tooling/interaction.rs)

/// Window-level interaction timing coordinator (`tooling::interaction::Tracker`).
public final class InteractionTracker {
    public static let defaultSlowMs: Double = 1000.0 / 60.0
    public static let rollupEveryNs: UInt64 = 60_000_000_000
    public static let slowPerSecond: UInt32 = 10

    public struct Finished: Sendable {
        public var timed: InteractionTimed
        public var cpuMs: Double?
        public var stacks: InteractionStacks?
        public var builtNs: UInt64
        public var phases: [Double]
        public var shaped: UInt32
        public var submittedNs: UInt64
        public var presentNs: UInt64
        public var cause: InteractionCause?
        public var slow: Bool
    }

    public let names = InteractionNames()
    public let rollup = InteractionRollup()
    private var rolledSinceNs: UInt64?
    private var frameState: InteractionFrameState = .idle
    private var breachedSignatures: Set<UInt64> = []
    private var sentWindowStartNs: UInt64?
    private var sentCountInWindow: UInt32 = 0
    private var activePhases = false
    private var phaseTimes = [Double](repeating: 0, count: InteractionPhase.allCases.count)

    private static let phaseDictKey = "rune.interaction.activePhases"

    public static func recordActiveThreadPhase(_ index: Int, ms: Double) {
        guard index >= 0, index < InteractionPhase.allCases.count else { return }
        guard let box = Thread.current.threadDictionary[phaseDictKey] as? ActivePhaseBox else { return }
        box.times[index] += ms
    }

    private final class ActivePhaseBox {
        var times = [Double](repeating: 0, count: InteractionPhase.allCases.count)
    }

    nonisolated(unsafe) public static var testSlowReports: [SlowInteractionReport] = []
    nonisolated(unsafe) public static var testSlowFrameReports: [SlowFrameReport] = []
    nonisolated(unsafe) public static var testRollups: [(rolls: [InteractionRollup.Roll], fromNs: UInt64, toNs: UInt64)] = []

    public static func resetForTesting() {
        InteractionGate.forceOnForTesting = nil
        testSlowReports.removeAll()
        testSlowFrameReports.removeAll()
        testRollups.removeAll()
        Thread.current.threadDictionary.removeObject(forKey: phaseDictKey)
    }

    public init() {}

    public var currentFrameState: InteractionFrameState { frameState }
    public var isPhaseCollectionActive: Bool { activePhases }
    public var currentPhaseTimes: [Double] { phaseTimes }

    public func clearPendingRollupForTesting() {
        rolledSinceNs = nil
    }

    public func isBreached(_ note: InteractionNote) -> Bool {
        !breachedSignatures.isEmpty
            && breachedSignatures.contains(InteractionRollup.signature(route: note.route, control: note.control, action: note.action))
    }

    public func addPhase(_ phase: InteractionPhase, ms: Double) {
        guard activePhases else { return }
        phaseTimes[phase.rawValue] += ms
    }

    public func frameBegins(
        queued: Bool,
        nowNs: UInt64,
        cpuMs: Double? = nil,
        slowMs: Double = InteractionTracker.defaultSlowMs,
        overloaded: Bool = false
    ) -> Finished? {
        var finished: Finished? = nil
        if case .built(let b) = frameState {
            finished = finishWith(submittedNs: b.atNs, presentsAtNs: nil, slowMs: slowMs, overloaded: overloaded)
        }
        _ = InteractionFrameMachine.step(&frameState, event: .begin(atNs: nowNs, queued: queued, cpuMs: queued ? cpuMs : nil))
        return finished
    }

    public func noted(note: InteractionNote, arrivedNs: UInt64?, startedNs: UInt64, handlerMs: Double) {
        let fx = InteractionFrameMachine.step(
            &frameState,
            event: .note(note: note, arrivedNs: arrivedNs, startedNs: startedNs, handlerMs: handlerMs)
        )
        if fx.contains(where: { if case .startPhases = $0 { return true }; return false }) {
            phaseTimes = [Double](repeating: 0, count: InteractionPhase.allCases.count)
            activePhases = true
            Thread.current.threadDictionary[Self.phaseDictKey] = ActivePhaseBox()
        }
    }

    public func committed(why: UInt16) {
        _ = InteractionFrameMachine.step(&frameState, event: .commit(why))
    }

    public func built(
        shaped: UInt32,
        nodes: Int,
        nowNs: UInt64,
        cpuMs: Double? = nil,
        stacks: InteractionStacks? = nil,
        slowMs: Double = InteractionTracker.defaultSlowMs,
        overloaded: Bool = false
    ) -> SlowFrameReport? {
        if case .open = frameState {
            var captured = phaseTimes
            if let box = Thread.current.threadDictionary[Self.phaseDictKey] as? ActivePhaseBox {
                for i in 0..<captured.count {
                    captured[i] += box.times[i]
                }
            }
            phaseTimes = [Double](repeating: 0, count: InteractionPhase.allCases.count)
            let fx = InteractionFrameMachine.step(
                &frameState,
                event: .buildTimed(atNs: nowNs, phases: captured, shaped: shaped, cpuMs: cpuMs, stacks: stacks)
            )
            if fx.contains(where: { if case .stopPhases = $0 { return true }; return false }) {
                activePhases = false
                Thread.current.threadDictionary.removeObject(forKey: Self.phaseDictKey)
            }
            return nil
        }

        let fx = InteractionFrameMachine.step(&frameState, event: .buildUntimed)
        for effect in fx {
            if case let .checkFrame(startNs, why) = effect, let stacks {
                let workMs = Double(nowNs >= startNs ? nowNs - startNs : 0) / 1_000_000.0
                if workMs > slowMs {
                    let cause = InteractionCause.classify(
                        workMs: workMs,
                        slowMs: slowMs,
                        cpuMs: nil,
                        stacks: stacks,
                        overloaded: overloaded
                    )
                    return SlowFrameReport(
                        startNs: startNs,
                        builtNs: nowNs,
                        why: why,
                        nodes: nodes,
                        cause: cause,
                        stacks: stacks
                    )
                }
            }
        }
        return nil
    }

    public func finish(
        submittedNs: UInt64,
        presentsAtNs: UInt64? = nil,
        slowMs: Double = InteractionTracker.defaultSlowMs,
        overloaded: Bool = false
    ) -> Finished? {
        finishWith(submittedNs: submittedNs, presentsAtNs: presentsAtNs, slowMs: slowMs, overloaded: overloaded)
    }

    private func finishWith(
        submittedNs: UInt64,
        presentsAtNs: UInt64?,
        slowMs: Double,
        overloaded: Bool
    ) -> Finished? {
        let fx = InteractionFrameMachine.step(&frameState, event: .finish)
        guard let built = fx.compactMap({ effect -> InteractionBuilt? in
            if case .count(let b) = effect { return b }
            return nil
        }).first else {
            return nil
        }

        let sub = max(submittedNs, built.atNs)
        let present = presentsAtNs.map { max($0, sub) } ?? sub
        let totalMs = Double(present >= built.timed.arrivedNs ? present - built.timed.arrivedNs : 0) / 1_000_000.0
        let workMs = Double(sub >= built.timed.frameStartNs ? sub - built.timed.frameStartNs : 0) / 1_000_000.0
        let over = totalMs > slowMs || workMs > slowMs
        let cause: InteractionCause? = over
            ? InteractionCause.classify(
                workMs: workMs,
                slowMs: slowMs,
                cpuMs: built.cpuMs,
                stacks: built.stacks,
                overloaded: overloaded
            )
            : nil
        let contended = (cause == .schedulerWait)
        let note = built.timed.note
        rollup.add(
            route: note.route,
            control: note.control,
            action: note.action,
            ms: totalMs,
            slow: over && !contended,
            contended: contended
        )
        if over && !contended {
            breachedSignatures.insert(InteractionRollup.signature(route: note.route, control: note.control, action: note.action))
        }
        let slow = over && allowSlow(atNs: present)
        if rolledSinceNs == nil {
            rolledSinceNs = built.timed.arrivedNs
        }
        return Finished(
            timed: built.timed,
            cpuMs: built.cpuMs,
            stacks: built.stacks,
            builtNs: built.atNs,
            phases: built.phases,
            shaped: built.shaped,
            submittedNs: sub,
            presentNs: present,
            cause: cause,
            slow: slow
        )
    }

    private func allowSlow(atNs now: UInt64) -> Bool {
        if let start = sentWindowStartNs, now >= start && (now - start) < 1_000_000_000 {
            let count = sentCountInWindow
            sentCountInWindow += 1
            return count < Self.slowPerSecond
        }
        sentWindowStartNs = now
        sentCountInWindow = 1
        return true
    }

    public func takeRollupIfDue(nowNs: UInt64, force: Bool = false) -> (rolls: [InteractionRollup.Roll], fromNs: UInt64, toNs: UInt64)? {
        guard let from = rolledSinceNs, !rollup.isEmpty else { return nil }
        if !force && nowNs >= from && (nowNs - from) < Self.rollupEveryNs {
            return nil
        }
        rolledSinceNs = nil
        return (rollup.takeAll(), from, nowNs)
    }
}
