import Foundation
import Rune
import RuneKit
#if canImport(Darwin)
import Darwin
#endif

/// Parity port of `crates/rune-kit/examples/layout_text_cost/{main,probe}.rs`:
/// Benchmarks all 14 layout/text/markdown/virtual-list/memo cases across 13 per-frame
/// phase and census metrics (`stack`, `stack-same`, `list`, `edit`, `md-resize`,
/// `md-resize-live`, `md-same`, `md-open`, `md-virtual`, `md-beside`, `tree`,
/// `vlist-resize`, `vlist-resize-live`, `memo-chat`).
@main
public enum RuneKitLayoutTextCostApp {
    public static let allCases: [String] = [
        "stack",
        "stack-same",
        "list",
        "edit",
        "md-resize",
        "md-resize-live",
        "md-same",
        "md-open",
        "md-virtual",
        "md-beside",
        "tree",
        "vlist-resize",
        "vlist-resize-live",
        "memo-chat",
    ]

    public static let defaultViewport = Vec2(960, 800)

    private static let words: [String] = [
        "amber", "anchor", "apple", "apron", "atlas", "autumn", "badge", "bamboo", "beacon", "berry",
        "birch", "bison", "bloom", "breeze", "bridge", "brook", "canyon", "cedar", "chalk", "cinder",
        "cliff", "cloud", "clover", "cobalt", "copper", "coral", "crane", "creek", "crest", "crown",
        "daisy", "delta", "drift", "dune", "eagle", "ember", "falcon", "fern", "field", "flint",
        "flora", "forest", "frost", "garden", "glade", "grain", "granite", "grove", "harbor", "hazel",
    ]

    private struct Rng {
        var state: UInt64

        init(seed: UInt64 = 0x9e37_79b9_7f4a_7c15) {
            self.state = seed == 0 ? 1 : seed
        }

        mutating func nextU64() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }

        mutating func next(_ upperBound: Int) -> Int {
            guard upperBound > 0 else { return 0 }
            return Int(nextU64() % UInt64(upperBound))
        }
    }

    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func get() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private struct MemoDeps: Equatable, Sendable {
        let version: Int
        let picked: Bool
    }

    private struct ChatDeps: Equatable, Sendable {
        let version: Int
        let selected: Bool
    }

    public struct State: Sendable {
        public var kind: String
        public var note: String
        public var sections: [String]
        public var listItems: [String]
        public var listText: String
        public var treeDepth: Int
        public var editCursor: Int
        public var version: Int
        public var activeRow: Int
        public var toggle: Bool
        public var style: MarkdownStyle
        public var kit: Kit
        public var liveOffset: Live<Vec2>

        public init(
            kind: String,
            note: String,
            sections: [String],
            listItems: [String],
            listText: String,
            dark: Bool = true
        ) {
            self.kind = kind
            self.note = note
            self.sections = sections
            self.listItems = listItems
            self.listText = listText
            self.treeDepth = 5
            self.editCursor = min(note.count / 2, max(0, note.count))
            self.version = 0
            self.activeRow = 0
            self.toggle = true
            let kit = Kit.neutral(dark: dark)
            self.kit = kit
            self.style = MarkdownStyle.fromKit(kit)
            self.liveOffset = Live(Vec2(0, 0))
        }
    }

    private struct FrameSample {
        let cpuMs: Double
        let viewMs: Double
        let commitMs: Double
        let layoutMs: Double
        let textMs: Double
        let paintMs: Double
        let applyMs: Double
        let allocs: Double
        let allocBytes: Double
        let shaped: Double
        let rebroken: Double
        let nodes: Double
        let viewRuns: Double
    }

    private struct Census {
        let nodes: Int
        let texts: Int
        let heapBytes: UInt64
    }

    // Compatibility types retained for Tests/RuneExamplesTests/ContentExamplesParityTests.swift.
    public struct CaseMetric: Sendable, Equatable {
        public let name: String
        public let wallMs: Double
        public let cpuMs: Double
        public let layoutMs: Double
        public let textMs: Double
        public let instances: Int
        public let glyphs: Int
    }

    public struct Report: Sendable {
        public let cases: [CaseMetric]
        public let footprintMB: Double
        public let output: String
    }

    public static func generateNote(bytes: Int) -> String {
        var rng = Rng()
        func word() -> String {
            words[rng.next(words.count)]
        }
        func makeWords(_ count: Int, styled: Bool) -> String {
            (0..<count).map { _ in
                let w = word()
                guard styled else { return w }
                switch rng.next(24) {
                case 0: return "**\(w) \(word())**"
                case 1: return "*\(w)*"
                case 2: return "`\(w)_\(rng.next(100))`"
                case 3: return "[\(w)](https://example.com/\(w))"
                default: return w
                }
            }.joined(separator: " ")
        }

        var out = ""
        var section = 0
        while out.utf8.count < bytes {
            section += 1
            out += "# Section \(section): \(makeWords(3, styled: false))\n\n"
            for sub in 0..<3 {
                out += "## \(makeWords(2, styled: false)) \(sub)\n\n"
                for _ in 0..<2 {
                    out += "\(makeWords(25 + rng.next(40), styled: true)).\n\n"
                }
                for i in 0..<(4 + rng.next(4)) {
                    let line = makeWords(4 + rng.next(8), styled: true)
                    out += (sub % 2 == 0) ? "- \(line)\n" : "\(i + 1). \(line)\n"
                }
                out += "\n"
                switch rng.next(3) {
                case 0:
                    out += "```rust\nlet \(word())_\(section) = \(rng.next(1000));\n```\n\n"
                case 1:
                    out += "> \(makeWords(10 + rng.next(14), styled: true)).\n\n"
                default:
                    for _ in 0..<3 {
                        out += "- [ ] \(makeWords(5, styled: true))\n"
                    }
                    out += "\n"
                }
            }
        }
        return out
    }

    public static func generateDocument(bytes: Int) -> String {
        generateNote(bytes: bytes)
    }

    private static func splitMarkdownSections(_ markdown: String) -> [String] {
        var sections: [String] = []
        var current = ""
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# ") && !current.isEmpty {
                sections.append(current)
                current = String(line) + "\n"
            } else {
                current += String(line) + "\n"
            }
        }
        if !current.isEmpty {
            sections.append(current)
        }
        return sections.isEmpty ? [markdown] : sections
    }

    private static func generateListItems(count: Int) -> [String] {
        var rng = Rng(seed: 0x517c_c1b7_2722_0a95)
        return (0..<count).map { i in
            let w0 = words[rng.next(words.count)]
            let w1 = words[rng.next(words.count)]
            let w2 = words[rng.next(words.count)]
            return "Row \(i): \(w0) \(w1) \(w2) item-\(rng.next(10_000))"
        }
    }

    private static func wordStats(_ text: String) -> (tokens: Int, distinct: Int) {
        var total = 0
        var unique = Set<Substring>()
        for tok in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            total += 1
            unique.insert(tok)
        }
        return (total, unique.count)
    }

    private static func liveHeapStats() -> (blocks: Int64, bytes: Int64) {
        #if canImport(Darwin)
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (Int64(stats.blocks_in_use), Int64(stats.size_in_use))
        #else
        return (0, 0)
        #endif
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15
    }

    private static func treeNode(_ depth: Int, _ breadth: Int, _ path: String, _ k: Kit) -> El<State> {
        let label: El<State> = text("node-\(path)").font(TextStyle(size: 12, weight: depth == 0 ? 600 : 400)).color(k.c.textBase)
        if depth <= 0 {
            return row()
                .key("leaf-\(path)")
                .wFull()
                .px(8)
                .py(3)
                .gap(6)
                .itemsCenter()
                .child(el().size(6, 6).rounded(3).bg(k.c.bgAccent))
                .child(label)
        }
        return col()
            .key("branch-\(path)")
            .wFull()
            .pl(12)
            .gap(2)
            .child(
                row()
                    .wFull()
                    .px(6)
                    .py(3)
                    .gap(6)
                    .itemsCenter()
                    .child(Badge("D\(depth)").build(k))
                    .child(label)
            )
            .children((0..<breadth).map { idx in
                treeNode(depth - 1, max(2, breadth - 1), "\(path).\(idx)", k)
            })
    }

    private static func makeView(counter: AtomicCounter) -> (State, inout Cx<State>) -> El<State> {
        { (s: State, _: inout Cx<State>) -> El<State> in
            counter.increment()
            let k = s.kit
            switch s.kind {
            case "stack", "stack-same":
                return col()
                    .wFull()
                    .hFull()
                    .bg(k.c.bgBase)
                    .p(16)
                    .gap(6)
                    .scroll(stickBottom: false)
                    .children(s.listItems.prefix(250).enumerated().map { idx, line in
                        row()
                            .key("stack-\(idx)")
                            .wFull()
                            .px(10)
                            .py(6)
                            .gap(8)
                            .itemsCenter()
                            .rounded(6)
                            .bg(k.c.layer01)
                            .child(Badge("#\(idx)").build(k))
                            .child(text(line).font(TextStyle(size: 13, weight: 400)).color(k.c.textBase))
                    })

            case "list":
                return col()
                    .wFull()
                    .hFull()
                    .bg(k.c.bgBase)
                    .p(16)
                    .gap(4)
                    .scroll(stickBottom: false)
                    .children(s.listItems.enumerated().map { idx, line in
                        row()
                            .key("list-\(idx)")
                            .wFull()
                            .h(28)
                            .px(10)
                            .itemsCenter()
                            .hover(Color.white.alpha(0.06))
                            .child(text(line).font(TextStyle(size: 13, weight: 400)).color(k.c.textBase))
                    })

            case "edit", "md-resize", "md-same", "md-open":
                return col()
                    .wFull()
                    .hFull()
                    .bg(k.c.bgBase)
                    .child(
                        col()
                            .key("md-scroll")
                            .wFull()
                            .grow(1)
                            .minH(0)
                            .scroll(stickBottom: false)
                            .px(24)
                            .py(18)
                            .child(MarkdownView<State>(s.note).render(s.style))
                    )

            case "md-resize-live":
                return col()
                    .wFull()
                    .hFull()
                    .bg(k.c.bgBase)
                    .child(
                        col()
                            .key("md-scroll-live")
                            .wFull()
                            .grow(1)
                            .minH(0)
                            .liveOffset(s.liveOffset.binding)
                            .scroll(stickBottom: false)
                            .px(24)
                            .py(18)
                            .child(MarkdownView<State>(s.note).render(s.style))
                    )

            case "md-virtual":
                return col()
                    .wFull()
                    .hFull()
                    .bg(k.c.bgBase)
                    .child(
                        col()
                            .key("md-vlist")
                            .wFull()
                            .grow(1)
                            .minH(0)
                            .px(24)
                            .py(18)
                            .virtualRowsVersion(s.version)
                            .virtualRows(
                                s.sections.count,
                                280,
                                key: { _, idx in "sec-\(idx)" },
                                build: { state, idx in
                                    col()
                                        .wFull()
                                        .pb(12)
                                        .child(MarkdownView<State>(state.sections[idx]).render(state.style))
                                }
                            )
                    )

            case "md-beside":
                let sidebar = col()
                    .key("sidebar")
                    .w(240)
                    .hFull()
                    .shrink(0)
                    .p(12)
                    .gap(8)
                    .bg(k.c.layer01)
                    .child(
                        Card<State>()
                            .title("Outline")
                            .description("\(s.sections.count) sections")
                            .child(
                                Switch<State>(checked: s.toggle)
                                    .label("Sync")
                                    .onToggle { $0.toggle.toggle() }
                                    .build(k)
                            )
                            .build(k)
                    )
                    .children(s.sections.prefix(24).enumerated().map { idx, _ in
                        text("Section \(idx + 1)")
                            .font(TextStyle(size: 12, weight: idx == s.activeRow ? 600 : 400))
                            .color(k.c.textBase)
                    })

                let mainPane = col()
                    .key("main-pane")
                    .grow(1)
                    .minH(0)
                    .hFull()
                    .scroll(stickBottom: false)
                    .px(24)
                    .py(18)
                    .child(MarkdownView<State>(s.note).render(s.style))

                return row()
                    .wFull()
                    .hFull()
                    .bg(k.c.bgBase)
                    .child(sidebar)
                    .child(mainPane)

            case "tree":
                return col()
                    .wFull()
                    .hFull()
                    .bg(k.c.bgBase)
                    .p(12)
                    .scroll(stickBottom: false)
                    .child(treeNode(4, 3, "0", k))

            case "vlist-resize":
                return col()
                    .wFull()
                    .hFull()
                    .bg(k.c.bgBase)
                    .child(
                        col()
                            .key("vlist")
                            .wFull()
                            .grow(1)
                            .minH(0)
                            .virtualRowsVersion(s.version)
                            .virtualRows(
                                s.listItems.count,
                                30,
                                key: { _, idx in "vrow-\(idx)" },
                                build: { state, idx in
                                    row()
                                        .wFull()
                                        .h(30)
                                        .px(12)
                                        .itemsCenter()
                                        .child(
                                            text(state.listItems[idx])
                                                .font(TextStyle(size: 13, weight: 400))
                                                .color(state.kit.c.textBase)
                                        )
                                }
                            )
                    )

            case "vlist-resize-live":
                return col()
                    .wFull()
                    .hFull()
                    .bg(k.c.bgBase)
                    .child(
                        col()
                            .key("vlist-live")
                            .wFull()
                            .grow(1)
                            .minH(0)
                            .liveOffset(s.liveOffset.binding)
                            .virtualRowsVersion(s.version)
                            .virtualRows(
                                s.listItems.count,
                                30,
                                key: { _, idx in "vlrow-\(idx)" },
                                build: { state, idx in
                                    row()
                                        .wFull()
                                        .h(30)
                                        .px(12)
                                        .itemsCenter()
                                        .child(
                                            text(state.listItems[idx])
                                                .font(TextStyle(size: 13, weight: 400))
                                                .color(state.kit.c.textBase)
                                        )
                                }
                            )
                    )

            case "memo-chat":
                return col()
                    .wFull()
                    .hFull()
                    .bg(k.c.bgBase)
                    .p(16)
                    .gap(8)
                    .scroll(stickBottom: true)
                    .children((0..<80).map { idx in
                        let selected = idx == s.activeRow
                        let ver = selected ? s.version : 0
                        let body = s.sections[idx % max(1, s.sections.count)]
                        return memo("chat-\(idx)", ChatDeps(version: ver, selected: selected)) {
                            Card<State>()
                                .title("Message \(idx)")
                                .description(selected ? "active v\(ver)" : "settled")
                                .action(Badge(selected ? "ACTIVE" : "OK").build(k))
                                .child(MarkdownView<State>(body).render(s.style))
                                .build(k)
                        }
                    })

            default:
                return col()
                    .wFull()
                    .hFull()
                    .bg(k.c.bgBase)
                    .child(text("Unknown case \(s.kind)"))
            }
        }
    }

    private static func sampleFrame(
        rt: Runtime<State>,
        counter: AtomicCounter,
        at now: Double
    ) -> FrameSample {
        _ = takeFramePhases()
        let viewsBefore = counter.get()
        let heapBefore = liveHeapStats()
        let cpuBefore = threadCpuMs()
        _ = rt.frame(at: now)
        let cpuMs = max(0, threadCpuMs() - cpuBefore)
        let heapAfter = liveHeapStats()
        let viewsAfter = counter.get()
        let phases = takeFramePhases()

        func phase(_ idx: Int) -> Double {
            phases.count > idx ? phases[idx] : 0.0
        }

        return FrameSample(
            cpuMs: cpuMs,
            viewMs: phase(6),
            commitMs: phase(7),
            layoutMs: phase(8),
            textMs: phase(9),
            paintMs: phase(10),
            applyMs: phase(11),
            allocs: Double(max(0, heapAfter.blocks - heapBefore.blocks)),
            allocBytes: Double(max(0, heapAfter.bytes - heapBefore.bytes)),
            shaped: 0.0,
            rebroken: 0.0,
            nodes: Double(rt.elements().count),
            viewRuns: Double(viewsAfter - viewsBefore)
        )
    }

    private static func runCase(
        _ name: String,
        note: String,
        sections: [String],
        listItems: [String],
        listText: String,
        repeatCount: Int,
        iterations: Int = 30
    ) -> (samples: [FrameSample], census: Census, probeLines: [String]) {
        var samples: [FrameSample] = []
        var lastCensus = Census(nodes: 0, texts: 0, heapBytes: 0)
        var probeLines: [String] = []
        let dt = 1.0 / 120.0

        for rep in 0..<max(1, repeatCount) {
            let counter = AtomicCounter()
            let initialState = State(
                kind: name,
                note: note,
                sections: sections,
                listItems: listItems,
                listText: listText
            )

            if name == "md-open" {
                for iter in 0..<10 {
                    let heapBefore = liveHeapStats()
                    let rt = Runtime(
                        state: initialState,
                        viewport: defaultViewport,
                        pixelScale: 2.0,
                        systemDark: true,
                        view: makeView(counter: counter)
                    )
                    let sample = sampleFrame(rt: rt, counter: counter, at: Double(iter) * dt)
                    samples.append(sample)
                    let heapAfter = liveHeapStats()
                    if rep == 0 && iter == 9 {
                        let elems = rt.elements()
                        lastCensus = Census(
                            nodes: elems.count,
                            texts: elems.reduce(0) { $0 + ($1.text != nil ? 1 : 0) },
                            heapBytes: UInt64(max(0, heapAfter.bytes - heapBefore.bytes))
                        )
                    }
                    probeLines.append("ALLOC case=\(name) rep=\(rep) iter=\(iter) live_blocks=\(heapAfter.blocks) live_bytes=\(heapAfter.bytes)")
                }
                continue
            }

            let heapBefore = liveHeapStats()
            let rt = Runtime(
                state: initialState,
                viewport: defaultViewport,
                pixelScale: 2.0,
                systemDark: true,
                view: makeView(counter: counter)
            )
            var now = 0.0
            _ = rt.frame(at: now)
            for _ in 0..<3 {
                now += dt
                _ = rt.frame(at: now)
            }

            let iterations = max(1, iterations)
            for i in 0..<iterations {
                now += dt
                switch name {
                case "stack", "list", "md-virtual", "tree":
                    rt.wheel(WheelEvent(dx: 0, dy: -60), at: Vec2(480, 400), now: now)
                case "stack-same", "md-same":
                    rt.invalidate()
                case "edit":
                    rt.update(at: now) { s, _ in
                        let idx = s.note.index(s.note.startIndex, offsetBy: min(s.editCursor, s.note.count))
                        s.note.insert("x", at: idx)
                        s.editCursor += 1
                    }
                case "md-resize", "md-resize-live", "md-beside", "vlist-resize", "vlist-resize-live":
                    let w: Float = 960.0 - Float((i % 15) * 20)
                    rt.setViewport(Vec2(w, defaultViewport.y))
                case "memo-chat":
                    rt.update(at: now) { s, _ in
                        s.activeRow = (s.activeRow + 1) % 80
                        s.version += 1
                    }
                default:
                    rt.invalidate()
                }
                let sample = sampleFrame(rt: rt, counter: counter, at: now)
                samples.append(sample)
            }

            if rep == 0 {
                let elems = rt.elements()
                let heapAfter = liveHeapStats()
                lastCensus = Census(
                    nodes: elems.count,
                    texts: elems.reduce(0) { $0 + ($1.text != nil ? 1 : 0) },
                    heapBytes: UInt64(max(0, heapAfter.bytes - heapBefore.bytes))
                )
                probeLines.append("LIVE case=\(name) blocks=\(heapAfter.blocks) bytes=\(heapAfter.bytes)")
            }
        }

        return (samples, lastCensus, probeLines)
    }

    private static func stats(_ values: [Double]) -> (median: Double, p95: Double, mean: Double) {
        guard !values.isEmpty else { return (0, 0, 0) }
        let sorted = values.sorted()
        let n = sorted.count
        let median: Double = n % 2 == 1
            ? sorted[n / 2]
            : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
        let p95Idx = min(n - 1, Int(Double(n - 1) * 0.95))
        let mean = values.reduce(0, +) / Double(n)
        return (median, sorted[p95Idx], mean)
    }

    private static func emitMetric(
        _ caseName: String,
        _ metric: String,
        _ values: [Double],
        into lines: inout [String]
    ) {
        let s = stats(values)
        lines.append(String(
            format: "METRIC case=%@ metric=%@ median=%.4f p95=%.4f mean=%.4f n=%d",
            caseName, metric, s.median, s.p95, s.mean, values.count
        ))
    }

    private static func formatCase(
        _ name: String,
        _ samples: [FrameSample],
        _ census: Census,
        into lines: inout [String]
    ) {
        lines.append("CENSUS case=\(name) nodes=\(census.nodes) texts=\(census.texts) heap=\(census.heapBytes)")

        let metrics: [(String, (FrameSample) -> Double)] = [
            ("cpu_ms", { $0.cpuMs }),
            ("view_ms", { $0.viewMs }),
            ("commit_ms", { $0.commitMs }),
            ("layout_ms", { $0.layoutMs }),
            ("text_ms", { $0.textMs }),
            ("paint_ms", { $0.paintMs }),
            ("apply_ms", { $0.applyMs }),
            ("allocs", { $0.allocs }),
            ("alloc_bytes", { $0.allocBytes }),
            ("shaped", { $0.shaped }),
            ("rebroken", { $0.rebroken }),
            ("nodes", { $0.nodes }),
            ("view_runs", { $0.viewRuns }),
        ]

        for (metric, extract) in metrics {
            emitMetric(name, metric, samples.map(extract), into: &lines)
        }

        let commits = samples.filter { $0.commitMs > 0.0 }
        if !commits.isEmpty && commits.count < samples.count {
            let commitCase = "\(name):commit"
            for (metric, extract) in metrics {
                emitMetric(commitCase, metric, commits.map(extract), into: &lines)
            }
        }
    }

    // Compatibility shim retained for Tests/RuneExamplesTests/ContentExamplesParityTests.swift.
    public static func runReport(bytes: Int = 16_000, resizeSteps: Int = 8, scrollFrames: Int = 10) -> Report {
        let doc = generateNote(bytes: bytes)
        let sections = splitMarkdownSections(doc)
        let listItems = generateListItems(count: 200)
        let listText = listItems.joined(separator: "\n")
        var cases: [CaseMetric] = []
        var lines: [String] = []
        let counter = AtomicCounter()

        func measureCase(_ name: String, _ work: () -> (instances: Int, glyphs: Int)) {
            _ = takeFramePhases()
            let t0 = ContinuousClock.now
            let c0 = threadCpuMs()
            let counts = work()
            let cpu = max(0, threadCpuMs() - c0)
            let wall = ms(t0.duration(to: .now))
            let phases = takeFramePhases()
            let layoutMs = phases.count > 8 ? phases[8] : 0
            let textMs = phases.count > 9 ? phases[9] : 0
            cases.append(CaseMetric(
                name: name,
                wallMs: wall,
                cpuMs: cpu,
                layoutMs: layoutMs,
                textMs: textMs,
                instances: counts.instances,
                glyphs: counts.glyphs
            ))
            lines.append(String(
                format: "CASE name=%@ wall_ms=%.3f cpu_ms=%.3f layout_ms=%.3f text_ms=%.3f instances=%d glyphs=%d",
                name, wall, cpu, layoutMs, textMs, counts.instances, counts.glyphs
            ))
        }

        let rt = Runtime(
            state: State(kind: "md-resize", note: doc, sections: sections, listItems: listItems, listText: listText),
            viewport: Vec2(960, 720),
            pixelScale: 2.0,
            systemDark: true,
            view: makeView(counter: counter)
        )
        var now = 0.0

        func counts(of scene: RefScene) -> (instances: Int, glyphs: Int) {
            (scene.primitives.count, scene.primitives.reduce(0) { $0 + ($1.kind == .glyph ? 1 : 0) })
        }

        measureCase("open_cold") {
            counts(of: rt.frame(at: now))
        }
        measureCase("resize_sweep") {
            var last = (0, 0)
            for i in 0..<resizeSteps {
                rt.setViewport(Vec2(960 - Float(i * 25), 720))
                now += 1.0 / 120.0
                last = counts(of: rt.frame(at: now))
            }
            return last
        }
        measureCase("scroll_sweep") {
            var last = (0, 0)
            for _ in 0..<scrollFrames {
                rt.wheel(WheelEvent(dx: 0, dy: -80), at: Vec2(480, 360), now: now)
                now += 1.0 / 120.0
                last = counts(of: rt.frame(at: now))
            }
            return last
        }

        let mb = Double(liveHeapStats().bytes) / 1_048_576.0
        lines.append(String(format: "MEMORY footprint_mb=%.2f", mb))
        return Report(cases: cases, footprintMB: mb, output: lines.joined(separator: "\n"))
    }

    private struct CliArgs {
        var mode: String = "time"
        var repeatCount: Int = 1
        var kb: Int = 50
        var cases: [String] = []
        var outPath: String? = nil
    }

    private static func parseArgs(_ args: [String]) -> CliArgs {
        var parsed = CliArgs()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--mode":
                i += 1
                if i < args.count { parsed.mode = args[i] }
            case "--repeat":
                i += 1
                if i < args.count, let v = Int(args[i]) { parsed.repeatCount = max(1, v) }
            case "--kb":
                i += 1
                if i < args.count, let v = Int(args[i]) { parsed.kb = max(1, v) }
            case "--case":
                i += 1
                if i < args.count {
                    parsed.cases.append(contentsOf: args[i].split(separator: ",").map(String.init))
                }
            case "--out":
                i += 1
                if i < args.count { parsed.outPath = args[i] }
            default:
                break
            }
            i += 1
        }
        if parsed.cases.isEmpty {
            parsed.cases = allCases
        }
        return parsed
    }

    public static func runParity(
        mode: String = "time",
        repeatCount: Int = 1,
        kb: Int = 50,
        cases: [String] = allCases,
        iterations: Int = 30
    ) -> (output: String, probeRecords: [String]) {
        let note = generateNote(bytes: kb * 1024)
        let sections = splitMarkdownSections(note)
        let listItems = generateListItems(count: 1000)
        let listText = listItems.joined(separator: "\n")

        let noteWords = wordStats(note)
        let listWords = wordStats(listText)

        var lines: [String] = [
            "WORDS note_tokens=\(noteWords.tokens) note_distinct=\(noteWords.distinct) list_tokens=\(listWords.tokens) list_distinct=\(listWords.distinct)"
        ]
        var probeRecords: [String] = [
            "META mode=\(mode) kb=\(kb) repeat=\(repeatCount)"
        ]

        for caseName in cases {
            let res = runCase(
                caseName,
                note: note,
                sections: sections,
                listItems: listItems,
                listText: listText,
                repeatCount: repeatCount,
                iterations: iterations
            )
            formatCase(caseName, res.samples, res.census, into: &lines)
            probeRecords.append("CASE \(caseName)")
            probeRecords.append(contentsOf: res.probeLines)
        }
        return (lines.joined(separator: "\n"), probeRecords)
    }

    public static func main() {
        let cli = parseArgs(Array(CommandLine.arguments.dropFirst()))

        FileHandle.standardError.write(Data(
            "layout_text_cost note: TextSystem.shaped/rebroken, Runtime.layoutNodes, and Rust GlobalAlloc/x29 sampler probe are not exposed by Rune; reporting 0 for shaped/rebroken, elements().count for nodes, and malloc_zone_statistics live deltas for allocs/alloc_bytes.\n".utf8
        ))
        if cli.mode == "sample" || cli.mode == "heap" {
            FileHandle.standardError.write(Data(
                "layout_text_cost warning: --mode \(cli.mode) cannot capture per-alloc x29 stack traces or async thread_get_state(ARM_THREAD_STATE64) without a C/GlobalAlloc shim; writing Darwin malloc_zone_statistics probe records.\n".utf8
            ))
        }

        let res = runParity(mode: cli.mode, repeatCount: cli.repeatCount, kb: cli.kb, cases: cli.cases)

        if let outPath = cli.outPath {
            let content = res.probeRecords.joined(separator: "\n") + "\n"
            do {
                try content.write(toFile: outPath, atomically: true, encoding: .utf8)
            } catch {
                FileHandle.standardError.write(Data("Failed to write --out \(outPath): \(error)\n".utf8))
            }
        }

        print(res.output)
    }
}
