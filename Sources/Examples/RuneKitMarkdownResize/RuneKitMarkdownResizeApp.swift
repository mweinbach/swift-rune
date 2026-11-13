import Foundation
import Rune
import RuneKit

/// Parity port of `crates/rune-kit/examples/markdown_resize.rs`:
/// Measures `MarkdownView` cold open, live resize (`900 -> 600 -> 900` by step),
/// font-family switching, scroll frames (`w=760`), and 2000-range highlight marks,
/// with optional `--memo` subtree caching.
@main
public enum RuneKitMarkdownResizeApp {
    public static let width: Float = 900.0
    public static let scrollWidth: Float = 760.0
    public static let height: Float = 900.0
    public static let bg = Color(r: 0.008, g: 0.008, b: 0.009, a: 1.0)

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

    private struct MemoDeps: Equatable, Sendable {
        let utf8Count: Int
        let markRangesCount: Int
        let styleKey: String
    }

    public struct State: Sendable {
        public var src: String
        public var style: MarkdownStyle
        public var marks: [(ranges: [Range<Int>], style: MarkdownHighlight)]
        public var useMemo: Bool
        public var fontTag: String

        public init(
            src: String,
            style: MarkdownStyle,
            marks: [(ranges: [Range<Int>], style: MarkdownHighlight)] = [],
            useMemo: Bool = false,
            fontTag: String = "default"
        ) {
            self.src = src
            self.style = style
            self.marks = marks
            self.useMemo = useMemo
            self.fontTag = fontTag
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
        let shaped: Double
        let rebroken: Double
        let nodes: Double
        let glyphs: Double
    }

    // Compatibility types retained for Tests/RuneExamplesTests/ContentExamplesParityTests.swift.
    public struct MetricRow: Sendable, Equatable {
        public let sizeKB: Int
        public let testCase: String
        public let medianCpuMs: Double
        public let glyphs: Int
        public let instances: Int
    }

    public struct Report: Sendable {
        public let metrics: [MetricRow]
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
                    if sub % 2 == 0 {
                        out += "- \(line)\n"
                        if i == 0 {
                            out += "  - \(makeWords(4 + rng.next(5), styled: true))\n"
                        }
                    } else {
                        out += "\(i + 1). \(line)\n"
                    }
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

    private static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        let buildNote: () -> El<State> = {
            var v = MarkdownView<State>(s.src)
            if !s.marks.isEmpty {
                v = v.highlights(s.marks)
            }
            return v.render(s.style)
        }
        let markCount = s.marks.reduce(0) { $0 + $1.ranges.count }
        let noteEl: El<State> = s.useMemo
            ? memo(
                "note",
                MemoDeps(utf8Count: s.src.utf8.count, markRangesCount: markCount, styleKey: s.fontTag),
                build: buildNote
            )
            : buildNote()

        return col()
            .wFull()
            .hFull()
            .bg(bg)
            .child(
                col()
                    .key("viewport")
                    .wFull()
                    .grow(1)
                    .minH(0)
                    .scroll(stickBottom: false)
                    .child(
                        col()
                            .wFull()
                            .px(32)
                            .py(24)
                            .child(noteEl)
                    )
            )
    }

    private static func sampleFrame(
        rt: Runtime<State>,
        at now: Double,
        computeNodes: Bool = true
    ) -> FrameSample {
        _ = takeFramePhases()
        let c0 = threadCpuMs()
        let scene = rt.frame(at: now)
        let cpuMs = max(0, threadCpuMs() - c0)
        let phases = takeFramePhases()

        func phase(_ idx: Int) -> Double {
            phases.count > idx ? phases[idx] : 0.0
        }

        let glyphCount = scene.primitives.reduce(0) { $0 + ($1.kind == .glyph ? 1 : 0) }
        let nodeCount = computeNodes ? rt.elements().count : 0

        return FrameSample(
            cpuMs: cpuMs,
            viewMs: phase(6),
            commitMs: phase(7),
            layoutMs: phase(8),
            textMs: phase(9),
            paintMs: phase(10),
            applyMs: phase(11),
            shaped: 0.0,
            rebroken: 0.0,
            nodes: Double(nodeCount),
            glyphs: Double(glyphCount)
        )
    }

    private static func settledRuntime(
        src: String,
        style: MarkdownStyle,
        viewportWidth: Float,
        useMemo: Bool
    ) -> (Runtime<State>, Double) {
        let rt = Runtime(
            state: State(src: src, style: style, useMemo: useMemo),
            viewport: Vec2(viewportWidth, height),
            pixelScale: 2.0,
            systemDark: true,
            view: view
        )
        var now = 0.0
        _ = rt.frame(at: now)
        for _ in 0..<2 {
            now += 1.0 / 120.0
            _ = rt.frame(at: now)
        }
        return (rt, now)
    }

    private static func firstWordRanges(in src: String, limit: Int) -> [Range<Int>] {
        let bytes = Array(src.utf8)
        var ranges: [Range<Int>] = []
        var i = 0
        func isAsciiAlpha(_ b: UInt8) -> Bool {
            (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }
        while i < bytes.count && ranges.count < limit {
            while i < bytes.count && !isAsciiAlpha(bytes[i]) {
                i += 1
            }
            let start = i
            while i < bytes.count && isAsciiAlpha(bytes[i]) {
                i += 1
            }
            if i > start {
                ranges.append(start..<i)
            }
        }
        return ranges
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

    private static func emitMetrics(
        sizeKB: Int,
        caseName: String,
        samples: [FrameSample],
        into lines: inout [String]
    ) {
        let metrics: [(String, (FrameSample) -> Double)] = [
            ("cpu_ms", { $0.cpuMs }),
            ("view_ms", { $0.viewMs }),
            ("commit_ms", { $0.commitMs }),
            ("layout_ms", { $0.layoutMs }),
            ("text_ms", { $0.textMs }),
            ("paint_ms", { $0.paintMs }),
            ("apply_ms", { $0.applyMs }),
            ("shaped", { $0.shaped }),
            ("rebroken", { $0.rebroken }),
            ("nodes", { $0.nodes }),
            ("glyphs", { $0.glyphs }),
        ]
        for (metric, extract) in metrics {
            let vals = samples.map(extract)
            let s = stats(vals)
            lines.append(String(
                format: "METRIC size=%dk case=%@ metric=%@ median=%.4f p95=%.4f mean=%.4f n=%d",
                sizeKB, caseName, metric, s.median, s.p95, s.mean, vals.count
            ))
        }
    }

    public static func runParity(
        sizes: [Int],
        step: Float,
        only: Set<String>?,
        useMemo: Bool
    ) -> [String] {
        let style = MarkdownStyle.neutral(dark: true)
        var lines: [String] = []

        // Warm font catalog once prior to `open` without inflating `open` runtime state.
        let warmTs = TextSystem()
        _ = warmTs.shape(
            text: "Warm fonts",
            style: TextStyle(size: 14, weight: 400),
            maxWidth: 400,
            pixelScale: 2.0,
            emitGlyphs: true
        )

        func shouldRun(_ name: String) -> Bool {
            only == nil || only!.contains(name)
        }

        for kb in sizes {
            let src = generateNote(bytes: kb * 1024)
            let wordCount = src.split(whereSeparator: { $0.isWhitespace }).count
            let lineCount = src.split(separator: "\n", omittingEmptySubsequences: false).count
            lines.append("NOTE size=\(kb)k bytes=\(src.utf8.count) words=\(wordCount) lines=\(lineCount)")

            if shouldRun("marks") {
                let (rt, baseNow) = settledRuntime(src: src, style: style, viewportWidth: width, useMemo: useMemo)
                let wordRanges = firstWordRanges(in: src, limit: 2000)
                let hl = [(ranges: wordRanges, style: MarkdownHighlight.match())]
                let now = baseNow + 1.0 / 120.0
                rt.update(at: now) { st, _ in
                    st.marks = hl
                }
                let sample = sampleFrame(rt: rt, at: now, computeNodes: false)
                let tElem0 = ContinuousClock.now
                let elems = rt.elements()
                let elemDur = tElem0.duration(to: .now)
                let elementsMs = Double(elemDur.components.seconds) * 1e3 + Double(elemDur.components.attoseconds) / 1e15
                // Rune's ElementRole has no `.mark` case and MarkdownView bakes highlights into rich text spans.
                let reported = 0
                lines.append(String(
                    format: "MARKS requested=%d reported=%d nodes=%d elements=%d elements_ms=%.3f",
                    wordRanges.count, reported, elems.count, elems.count, elementsMs
                ))
                let withNodes = FrameSample(
                    cpuMs: sample.cpuMs,
                    viewMs: sample.viewMs,
                    commitMs: sample.commitMs,
                    layoutMs: sample.layoutMs,
                    textMs: sample.textMs,
                    paintMs: sample.paintMs,
                    applyMs: sample.applyMs,
                    shaped: sample.shaped,
                    rebroken: sample.rebroken,
                    nodes: Double(elems.count),
                    glyphs: sample.glyphs
                )
                emitMetrics(sizeKB: kb, caseName: "marks", samples: [withNodes], into: &lines)
            }

            if shouldRun("open") {
                var openSamples: [FrameSample] = []
                for _ in 0..<10 {
                    let rt = Runtime(
                        state: State(src: src, style: style, useMemo: useMemo),
                        viewport: Vec2(width, height),
                        pixelScale: 2.0,
                        systemDark: true,
                        view: view
                    )
                    openSamples.append(sampleFrame(rt: rt, at: 0.0))
                }
                emitMetrics(sizeKB: kb, caseName: "open", samples: openSamples, into: &lines)
            }

            if shouldRun("resize") {
                let (rt, baseNow) = settledRuntime(src: src, style: style, viewportWidth: width, useMemo: useMemo)
                var now = baseNow
                var resizeSamples: [FrameSample] = []
                let safeStep = max(1.0, step)
                var w: Float = width - safeStep
                while w >= 600.0 {
                    now += 1.0 / 120.0
                    rt.setViewport(Vec2(w, height))
                    resizeSamples.append(sampleFrame(rt: rt, at: now))
                    w -= safeStep
                }
                w = 600.0 + safeStep
                while w <= width {
                    now += 1.0 / 120.0
                    rt.setViewport(Vec2(w, height))
                    resizeSamples.append(sampleFrame(rt: rt, at: now))
                    w += safeStep
                }
                emitMetrics(sizeKB: kb, caseName: "resize", samples: resizeSamples, into: &lines)
            }

            if shouldRun("fonts") {
                let (rt, baseNow) = settledRuntime(src: src, style: style, viewportWidth: width, useMemo: useMemo)
                let original = FontFamiliesRegistry.currentFamilies()
                defer { FontFamiliesRegistry.setFamilies(sans: original.sans, mono: original.mono) }
                var now = baseNow
                var fontSamples: [FrameSample] = []
                for i in 0..<40 {
                    now += 1.0 / 120.0
                    let (sans, mono) = (i % 2 == 0) ? ("Helvetica Neue", "Menlo") : ("Inter", "Inter")
                    _ = rt.textSystem.setFamilies(sans: sans, mono: mono)
                    rt.update(at: now) { st, _ in
                        st.fontTag = "\(sans)/\(mono)"
                    }
                    fontSamples.append(sampleFrame(rt: rt, at: now))
                }
                emitMetrics(sizeKB: kb, caseName: "fonts", samples: fontSamples, into: &lines)
            }

            if shouldRun("scroll") {
                let (rt, baseNow) = settledRuntime(src: src, style: style, viewportWidth: scrollWidth, useMemo: useMemo)
                var now = baseNow
                var scrollSamples: [FrameSample] = []
                for _ in 0..<120 {
                    now += 1.0 / 120.0
                    rt.wheel(WheelEvent(dx: 0, dy: -120.0), at: Vec2(380, 450), now: now)
                    scrollSamples.append(sampleFrame(rt: rt, at: now))
                }
                emitMetrics(sizeKB: kb, caseName: "scroll", samples: scrollSamples, into: &lines)
            }
        }

        return lines
    }

    // Compatibility shim retained for Tests/RuneExamplesTests/ContentExamplesParityTests.swift.
    public static func runReport(
        sizes: [Int] = [5],
        step: Float = 20.0,
        useMemo: Bool = false,
        highlightCount: Int = 60,
        testFonts: Bool = true
    ) -> Report {
        var rows: [MetricRow] = []
        var lines: [String] = []
        let style = MarkdownStyle.neutral(dark: true)

        func glyphCount(_ scene: RefScene) -> Int {
            scene.primitives.reduce(0) { $0 + ($1.kind == .glyph ? 1 : 0) }
        }

        for kb in sizes {
            let src = generateNote(bytes: kb * 1024)
            let rt = Runtime(
                state: State(src: src, style: style, useMemo: useMemo),
                viewport: Vec2(width, height),
                pixelScale: 2.0,
                systemDark: true,
                view: view
            )

            _ = takeFramePhases()
            let cOpen0 = threadCpuMs()
            let openScene = rt.frame(at: 0.0)
            let openCpu = max(0, threadCpuMs() - cOpen0)
            rows.append(MetricRow(
                sizeKB: kb,
                testCase: "open",
                medianCpuMs: openCpu,
                glyphs: glyphCount(openScene),
                instances: openScene.primitives.count
            ))
            lines.append(String(
                format: "METRIC size=%dk case=open metric=cpu_ms median=%.4f glyphs=%d",
                kb, openCpu, glyphCount(openScene)
            ))

            var resizeCpus: [Double] = []
            var lastGlyphs = glyphCount(openScene)
            var lastInstances = openScene.primitives.count
            var now = 0.0
            var w: Float = width - step
            while w >= 600.0 {
                rt.setViewport(Vec2(w, height))
                now += 1.0 / 120.0
                let c0 = threadCpuMs()
                let sc = rt.frame(at: now)
                resizeCpus.append(max(0, threadCpuMs() - c0))
                lastGlyphs = glyphCount(sc)
                lastInstances = sc.primitives.count
                w -= step
            }
            w = 600.0 + step
            while w <= width {
                rt.setViewport(Vec2(w, height))
                now += 1.0 / 120.0
                let c0 = threadCpuMs()
                let sc = rt.frame(at: now)
                resizeCpus.append(max(0, threadCpuMs() - c0))
                lastGlyphs = glyphCount(sc)
                lastInstances = sc.primitives.count
                w += step
            }
            let resizeMed = stats(resizeCpus).median
            rows.append(MetricRow(
                sizeKB: kb,
                testCase: "resize",
                medianCpuMs: resizeMed,
                glyphs: lastGlyphs,
                instances: lastInstances
            ))
            lines.append(String(
                format: "METRIC size=%dk case=resize metric=cpu_ms median=%.4f n=%d",
                kb, resizeMed, resizeCpus.count
            ))

            var scrollCpus: [Double] = []
            for _ in 0..<12 {
                now += 1.0 / 120.0
                rt.wheel(WheelEvent(dx: 0, dy: -60), at: Vec2(380, 450), now: now)
                let c0 = threadCpuMs()
                let sc = rt.frame(at: now)
                scrollCpus.append(max(0, threadCpuMs() - c0))
                lastGlyphs = glyphCount(sc)
                lastInstances = sc.primitives.count
            }
            let scrollMed = stats(scrollCpus).median
            rows.append(MetricRow(
                sizeKB: kb,
                testCase: "scroll",
                medianCpuMs: scrollMed,
                glyphs: lastGlyphs,
                instances: lastInstances
            ))
            lines.append(String(
                format: "METRIC size=%dk case=scroll metric=cpu_ms median=%.4f n=%d",
                kb, scrollMed, scrollCpus.count
            ))

            if highlightCount > 0 {
                let ranges = firstWordRanges(in: src, limit: highlightCount)
                let hl = [(ranges: ranges, style: MarkdownHighlight.match())]
                now += 1.0 / 120.0
                rt.update(at: now) { st, _ in
                    st.marks = hl
                }
                let c0 = threadCpuMs()
                let sc = rt.frame(at: now)
                let marksCpu = max(0, threadCpuMs() - c0)
                rows.append(MetricRow(
                    sizeKB: kb,
                    testCase: "marks",
                    medianCpuMs: marksCpu,
                    glyphs: glyphCount(sc),
                    instances: sc.primitives.count
                ))
                lines.append(String(
                    format: "METRIC size=%dk case=marks metric=cpu_ms median=%.4f marks=%d",
                    kb, marksCpu, ranges.count
                ))
            }

            if testFonts {
                let original = FontFamiliesRegistry.currentFamilies()
                defer { FontFamiliesRegistry.setFamilies(sans: original.sans, mono: original.mono) }
                now += 1.0 / 120.0
                _ = rt.textSystem.setFamilies(sans: "Helvetica Neue", mono: "Menlo")
                rt.update(at: now) { st, _ in
                    st.fontTag = "Helvetica Neue/Menlo"
                }
                let c0 = threadCpuMs()
                let sc = rt.frame(at: now)
                let fontsCpu = max(0, threadCpuMs() - c0)
                rows.append(MetricRow(
                    sizeKB: kb,
                    testCase: "fonts",
                    medianCpuMs: fontsCpu,
                    glyphs: glyphCount(sc),
                    instances: sc.primitives.count
                ))
                lines.append(String(
                    format: "METRIC size=%dk case=fonts metric=cpu_ms median=%.4f glyphs=%d",
                    kb, fontsCpu, glyphCount(sc)
                ))
            }
        }

        return Report(metrics: rows, output: lines.joined(separator: "\n"))
    }

    private struct CliArgs {
        var sizes: [Int] = [5, 50]
        var step: Float = 1.0
        var only: Set<String>? = nil
        var memo: Bool = false
    }

    private static func parseArgs(_ args: [String]) -> CliArgs {
        var parsed = CliArgs()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--sizes":
                i += 1
                if i < args.count {
                    let vals = args[i].split(separator: ",").compactMap { Int($0) }
                    if !vals.isEmpty { parsed.sizes = vals }
                }
            case "--step":
                i += 1
                if i < args.count, let v = Float(args[i]) {
                    parsed.step = max(1.0, v)
                }
            case "--only":
                i += 1
                if i < args.count {
                    let parts = Set(args[i].split(separator: ",").map(String.init))
                    if !parts.isEmpty { parsed.only = parts }
                }
            case "--memo":
                parsed.memo = true
            default:
                break
            }
            i += 1
        }
        return parsed
    }

    public static func main() {
        let cli = parseArgs(Array(CommandLine.arguments.dropFirst()))
        FileHandle.standardError.write(Data(
            "markdown_resize note: TextSystem.shaped/rebroken, Runtime.layoutNodes, Runtime.setFontFamilies (layout cache invalidation), and ElementRole.mark are not exposed by Rune; reporting 0 for shaped/rebroken/marks-reported and elements().count for nodes.\n".utf8
        ))
        let lines = runParity(sizes: cli.sizes, step: cli.step, only: cli.only, useMemo: cli.memo)
        print(lines.joined(separator: "\n"))
    }
}
