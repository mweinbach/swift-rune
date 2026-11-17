import Foundation
import Rune
#if canImport(Darwin)
import Darwin
#endif
#if os(macOS)
import AppKit
import Metal
import ObjectiveC.runtime
import QuartzCore
#endif

/// Windowed scrolling cost probe mirroring `crates/rune/examples/window_scroll_cost.rs` + `hud_probe/mod.rs`.
@main
public enum RuneWindowScrollCostApp {
    public struct State: Sendable {
        public var tick: UInt64 = 0
        public var scrollPhase: Float = 0
        public init() {}
    }

    public struct Report: Sendable {
        public let frames: Int
        public let instances: Int
        public let scrollOffset: Float
        public let usPerFrame: Double
    }

    private struct MetalCounts: Sendable {
        var drawables: UInt64 = 0
        var cmdBufs: UInt64 = 0
        var commits: UInt64 = 0
        var draws: UInt64 = 0
    }

    private struct ThreadSample: Sendable {
        var id: UInt64
        var name: String
        var cpuUs: UInt64
    }

    private final class BenchTracker: @unchecked Sendable {
        let lock = NSLock()
        let presumeVisible: Bool
        let seconds: Double
        let warmupSecs: Double = 2.0

        var startedAt: Double?
        var warmupDone = false
        var warmupFrames: UInt64 = 0
        var recordStart: Double = 0
        var frames: UInt64 = 0
        var cpu0Us: UInt64 = 0
        var instr0: UInt64 = 0
        var wakeups0: UInt64 = 0
        var metal0 = MetalCounts()
        var threads0: [ThreadSample] = []
        var finished = false

        init(presumeVisible: Bool, seconds: Double) {
            self.presumeVisible = presumeVisible
            self.seconds = seconds
        }
    }

    private static let clock = ContinuousClock()
    private static let tOrigin = ContinuousClock.now

    private static func nowSeconds() -> Double {
        let c = tOrigin.duration(to: .now).components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    private static func buildScrollTree(sectionCount: Int = 60, rowsPerSection: Int = 6) -> El<State> {
        var sections: [El<State>] = []
        sections.reserveCapacity(sectionCount)
        for sec in 0..<sectionCount {
            var rows: [El<State>] = [
                text("Section \(sec)")
                    .font(Tok.Typography.title)
                    .color(Color(r: 0.75, g: 0.78, b: 0.85, a: 1.0))
            ]
            rows.reserveCapacity(rowsPerSection + 1)
            for r in 0..<rowsPerSection {
                let hue = Float((sec * 23 + r * 37) % 360)
                rows.append(
                    row()
                        .wFull()
                        .h(36.0)
                        .centerY()
                        .px(12.0)
                        .gap(10.0)
                        .bg(Color(r: 0.14, g: 0.16, b: 0.20, a: 1.0))
                        .rounded(8.0)
                        .border(1.0, Color(r: 0.24, g: 0.26, b: 0.32, a: 1.0))
                        .children([
                            el()
                                .size(20.0, 20.0)
                                .rounded(10.0)
                                .bg(oklch(0.68, 0.14, hue)),
                            text("Row \(sec).\(r) — scrolling window cost probe")
                                .font(Tok.Typography.body)
                                .color(Color(r: 0.92, g: 0.93, b: 0.96, a: 1.0)),
                            el().grow(1.0),
                        ])
                )
            }
            sections.append(
                col()
                    .key("sec-\(sec)")
                    .wFull()
                    .gap(6.0)
                    .pb(12.0)
                    .children(rows)
            )
        }
        return col()
            .wFull()
            .hFull()
            .bg(Color(r: 0.08, g: 0.09, b: 0.11, a: 1.0))
            .key("sections")
            .scroll(ScrollSpec.default)
            .children(sections)
    }

    @MainActor
    public static func main() throws {
        let env = ProcessInfo.processInfo.environment
        let presumeVisible = env["SCROLL_PRESUME_VISIBLE"].map { $0 != "0" } ?? true
        let seconds = Double(env["SCROLL_SECONDS"] ?? "") ?? 12.0

        MetalSwizzleProbe.install()

        let tracker = BenchTracker(presumeVisible: presumeVisible, seconds: seconds)

        let timeoutSecs = UInt32(max(10.0, seconds + 20.0))
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: TimeInterval(timeoutSecs))
            let finished = tracker.lock.withLock { tracker.finished }
            if !finished {
                RuneStandardIO.error("scroll_window: timed out before completing\n")
                #if canImport(Darwin)
                Darwin.exit(1)
                #endif
            }
        }

        let app = App(
            "Window Scroll Cost",
            size: Vec2(800, 600),
            init: { State() },
            view: { _, _ in buildScrollTree() }
        )
        .poll { s, dt, tx in
            s.tick &+= 1
            s.scrollPhase += Float(dt) * 0.5
            let maxY: Float = 2400.0
            let targetY = (sin(Float(s.tick) * 0.08) * 0.5 + 0.5) * maxY
            tx.scrollToY("sections", targetY)
            tx.wakeAfter(0.0)
            return true
        }
        .onFrameDrawn { _, _, tx in
            let now = nowSeconds()
            enum Action {
                case none
                case finish(
                    elapsed: Double,
                    frames: UInt64,
                    cpuUs: UInt64,
                    instr: UInt64,
                    wakeups: UInt64,
                    metal: MetalCounts,
                    threads: [(String, Double)]
                )
            }
            let action: Action = tracker.lock.withLock {
                if tracker.finished { return .none }
                let started: Double
                if let existing = tracker.startedAt {
                    started = existing
                } else {
                    tracker.startedAt = now
                    started = now
                }
                if !tracker.warmupDone {
                    tracker.warmupFrames &+= 1
                    if now - started >= tracker.warmupSecs {
                        tracker.warmupDone = true
                        tracker.recordStart = now
                        tracker.cpu0Us = procCpuUs()
                        tracker.instr0 = procInstructions()
                        tracker.wakeups0 = procWakeups()
                        tracker.metal0 = MetalSwizzleProbe.snapshot()
                        tracker.threads0 = sampleAllThreads()
                    }
                    return .none
                }
                tracker.frames &+= 1
                let elapsed = now - tracker.recordStart
                if elapsed >= tracker.seconds {
                    tracker.finished = true
                    let dCpu = procCpuUs() &- tracker.cpu0Us
                    let dInstr = procInstructions() &- tracker.instr0
                    let dWake = procWakeups() &- tracker.wakeups0
                    let m1 = MetalSwizzleProbe.snapshot()
                    let dMetal = MetalCounts(
                        drawables: m1.drawables &- tracker.metal0.drawables,
                        cmdBufs: m1.cmdBufs &- tracker.metal0.cmdBufs,
                        commits: m1.commits &- tracker.metal0.commits,
                        draws: m1.draws &- tracker.metal0.draws
                    )
                    let t1 = sampleAllThreads()
                    var prevById: [UInt64: UInt64] = [:]
                    for sample in tracker.threads0 { prevById[sample.id] = sample.cpuUs }
                    var ranked: [(String, Double)] = t1.compactMap { cur in
                        let before = prevById[cur.id] ?? 0
                        let delta = cur.cpuUs >= before ? (cur.cpuUs - before) : 0
                        let pct = elapsed > 0 ? (Double(delta) / (elapsed * 1_000_000.0)) * 100.0 : 0.0
                        return pct >= 0.05 ? (cur.name, pct) : nil
                    }
                    ranked.sort { $0.1 > $1.1 }
                    return .finish(
                        elapsed: elapsed,
                        frames: tracker.frames,
                        cpuUs: dCpu,
                        instr: dInstr,
                        wakeups: dWake,
                        metal: dMetal,
                        threads: ranked
                    )
                }
                return .none
            }

            if case let .finish(elapsed, frames, cpuUs, instr, wakeups, metal, threads) = action {
                let fps = elapsed > 0 ? Double(frames) / elapsed : 0.0
                let procCpuPct = elapsed > 0 ? (Double(cpuUs) / (elapsed * 1_000_000.0)) * 100.0 : 0.0
                let kinstrPerS = elapsed > 0 ? Double(instr) / 1000.0 / elapsed : 0.0
                let wakePerS = elapsed > 0 ? Double(wakeups) / elapsed : 0.0
                print(String(
                    format: "scroll_window: drew=%llu elapsed=%.2fs fps=%.1f proc_cpu_pct=%.2f kinstr_per_s=%.0f wakeups_per_s=%.1f presume_visible=%@",
                    frames, elapsed, fps, procCpuPct, kinstrPerS, wakePerS,
                    tracker.presumeVisible ? "true" : "false"
                ))
                let avgDraws = frames > 0 ? Double(metal.draws) / Double(frames) : 0.0
                print(String(
                    format: "  metal: drawables=%llu cmd_bufs=%llu commits=%llu draws=%llu avg_draws=%.2f",
                    metal.drawables, metal.cmdBufs, metal.commits, metal.draws, avgDraws
                ))
                for (name, pct) in threads.prefix(8) {
                    print(String(format: "  thread %@: cpu=%.2f%%", name, pct))
                }
                tx.quit()
                #if canImport(Darwin)
                if !ToolingArgs.parse().isHeadlessRequested {
                    Darwin.exit(0)
                }
                #endif
            }
        }

        try app.run()
    }

    /// Deterministic headless micro-bench preserved for test suite compatibility.
    public static func runBench(rows: Int = 120, frames: Int = 24) -> Report {
        let sectionsCount = max(1, (rows + 5) / 6)
        let rt = Runtime<State>(
            state: State(),
            viewport: Vec2(800, 600),
            pixelScale: 2.0,
            view: { _, _ in buildScrollTree(sectionCount: sectionsCount, rowsPerSection: 6) }
        )
        rt.poll = { s, dt, tx in
            s.tick &+= 1
            s.scrollPhase += Float(dt) * 0.5
            let maxY: Float = 2400.0
            let targetY = (sin(Float(s.tick) * 0.08) * 0.5 + 0.5) * maxY
            tx.scrollToY("sections", targetY)
            return true
        }

        let t0 = clock.now
        var t = 0.0
        var lastInstances = 0
        for _ in 0..<max(1, frames) {
            t += 1.0 / 120.0
            let scene = rt.frame(at: t)
            lastInstances = scene.primitives.count
        }
        let c = t0.duration(to: .now).components
        let totalUs = Double(c.seconds) * 1_000_000.0 + Double(c.attoseconds) / 1e12
        return Report(
            frames: max(1, frames),
            instances: lastInstances,
            scrollOffset: rt.element(byKey: "sections")?.scrolled.dropFirst().first ?? 0,
            usPerFrame: totalUs / Double(max(1, frames))
        )
    }

    // MARK: - Darwin `hud_probe` Telemetry

    private static func procCpuUs() -> UInt64 {
        #if canImport(Darwin) && os(macOS)
        var info = rusage_info_v4()
        let rc: Int32 = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        if rc == 0 {
            return (info.ri_user_time &+ info.ri_system_time) / 1000
        }
        #endif
        return 0
    }

    private static func procInstructions() -> UInt64 {
        #if canImport(Darwin) && os(macOS)
        var info = rusage_info_v4()
        let rc: Int32 = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        if rc == 0 {
            return info.ri_instructions
        }
        #endif
        return 0
    }

    private static func procWakeups() -> UInt64 {
        #if canImport(Darwin) && os(macOS)
        var info = rusage_info_v4()
        let rc: Int32 = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        if rc == 0 {
            return info.ri_interrupt_wkups &+ info.ri_pkg_idle_wkups
        }
        #endif
        return 0
    }

    private static func sampleAllThreads() -> [ThreadSample] {
        #if canImport(Darwin) && os(macOS)
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else {
            return []
        }
        defer {
            let bytes = vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), bytes)
        }
        var out: [ThreadSample] = []
        out.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let th = list[i]
            var basic = thread_basic_info_data_t()
            var bCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let kr = withUnsafeMutablePointer(to: &basic) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(bCount)) {
                    thread_info(th, thread_flavor_t(THREAD_BASIC_INFO), $0, &bCount)
                }
            }
            guard kr == KERN_SUCCESS else { continue }
            var idInfo = thread_identifier_info_data_t()
            var idCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.stride / MemoryLayout<integer_t>.stride)
            let idKr = withUnsafeMutablePointer(to: &idInfo) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(idCount)) {
                    thread_info(th, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &idCount)
                }
            }
            let tid = idKr == KERN_SUCCESS ? idInfo.thread_id : UInt64(th)
            var nameBuf = [CChar](repeating: 0, count: 64)
            if let pt = pthread_from_mach_thread_np(th) {
                pthread_getname_np(pt, &nameBuf, nameBuf.count)
            }
            let name = String(decoding: nameBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let cpuUs = UInt64(basic.user_time.seconds) * 1_000_000
                &+ UInt64(basic.user_time.microseconds)
                &+ UInt64(basic.system_time.seconds) * 1_000_000
                &+ UInt64(basic.system_time.microseconds)
            out.append(ThreadSample(id: tid, name: name.isEmpty ? "thread-\(tid)" : name, cpuUs: cpuUs))
        }
        return out
        #else
        return []
        #endif
    }

    private enum MetalSwizzleProbe {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var installed = false
        nonisolated(unsafe) private static var counts = MetalCounts()

        #if os(macOS)
        nonisolated(unsafe) private static var origNextDrawable: IMP?
        nonisolated(unsafe) private static var origCmdBuf: IMP?
        nonisolated(unsafe) private static var origCommit: IMP?
        nonisolated(unsafe) private static var hookedClasses = Set<ObjectIdentifier>()

        private typealias NextDrawableFn = @convention(c) (AnyObject, Selector) -> AnyObject?
        private typealias CmdBufFn = @convention(c) (AnyObject, Selector) -> AnyObject?
        private typealias CommitFn = @convention(c) (AnyObject, Selector) -> Void
        #endif

        static func install() {
            #if os(macOS)
            lock.withLock {
                guard !installed else { return }
                installed = true
                if let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() {
                    if let cls: AnyClass = object_getClass(q),
                       let m = class_getInstanceMethod(cls, NSSelectorFromString("commandBuffer")) {
                        origCmdBuf = method_getImplementation(m)
                        let block: @convention(block) (AnyObject) -> AnyObject? = { obj in
                            lock.withLock { counts.cmdBufs &+= 1 }
                            guard let orig = origCmdBuf else { return nil }
                            let f = unsafeBitCast(orig, to: CmdBufFn.self)
                            let cb = f(obj, NSSelectorFromString("commandBuffer"))
                            if let cb {
                                hookCommandBufferClass(object_getClass(cb))
                            }
                            return cb
                        }
                        method_setImplementation(m, imp_implementationWithBlock(block))
                    }
                    if let cb = q.makeCommandBuffer() {
                        hookCommandBufferClass(object_getClass(cb))
                    }
                }
                if let cls = NSClassFromString("CAMetalLayer"),
                   let m = class_getInstanceMethod(cls, NSSelectorFromString("nextDrawable")) {
                    origNextDrawable = method_getImplementation(m)
                    let block: @convention(block) (AnyObject) -> AnyObject? = { obj in
                        lock.withLock { counts.drawables &+= 1 }
                        guard let orig = origNextDrawable else { return nil }
                        let f = unsafeBitCast(orig, to: NextDrawableFn.self)
                        return f(obj, NSSelectorFromString("nextDrawable"))
                    }
                    method_setImplementation(m, imp_implementationWithBlock(block))
                }
            }
            #endif
        }

        #if os(macOS)
        private static func hookCommandBufferClass(_ cls: AnyClass?) {
            guard let cls else { return }
            let oid = ObjectIdentifier(cls)
            let shouldHook = lock.withLock { hookedClasses.insert(oid).inserted }
            guard shouldHook else { return }
            if let m = class_getInstanceMethod(cls, NSSelectorFromString("commit")) {
                let prev = method_getImplementation(m)
                if origCommit == nil { origCommit = prev }
                let block: @convention(block) (AnyObject) -> Void = { obj in
                    lock.withLock {
                        counts.commits &+= 1
                        counts.draws &+= 1
                    }
                    let f = unsafeBitCast(prev, to: CommitFn.self)
                    f(obj, NSSelectorFromString("commit"))
                }
                method_setImplementation(m, imp_implementationWithBlock(block))
            }
        }
        #endif

        static func snapshot() -> MetalCounts {
            lock.withLock { counts }
        }
    }
}
