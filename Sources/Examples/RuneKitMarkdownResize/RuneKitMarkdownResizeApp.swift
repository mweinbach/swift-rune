import Foundation
import Rune
import RuneKit

/// Parity port of `crates/rune-kit/examples/markdown_resize.rs`:
/// Measures `MarkdownView` live-resize stepping (`900 -> 600 -> 900`), scroll frames,
/// `Rune.memo` subtree caching, source-range highlight overlays, and font-family switching.
@main
public enum RuneKitMarkdownResizeApp {
    public static let height: Float = 900.0
    public static let bg = Color(r: 0.008, g: 0.008, b: 0.009, a: 1.0)

    public struct State: Sendable {
        public var src: String
        public var style: MarkdownStyle
        public var marks: [(ranges: [Range<Int>], style: MarkdownHighlight)]
        public var useMemo: Bool

        public init(
            src: String,
            style: MarkdownStyle,
            marks: [(ranges: [Range<Int>], style: MarkdownHighlight)] = [],
            useMemo: Bool = false
        ) {
            self.src = src
            self.style = style
            self.marks = marks
            self.useMemo = useMemo
        }
    }

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
        let wordsList = [
            "amber", "lantern", "orchard", "quiet", "harbor", "copper", "meadow", "signal", "drift",
            "pebble", "willow", "ember", "tide", "cinder", "fable", "glacier", "hollow", "juniper", "kestrel", "lumen",
        ]
        var seed: UInt64 = 0x9e37_79b9_7f4a_7c15
        func next(_ n: Int) -> Int {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Int(seed % UInt64(max(1, n)))
        }
        func makeWords(_ count: Int, styled: Bool) -> String {
            (0..<count).map { _ in
                let w = wordsList[next(wordsList.count)]
                guard styled else { return w }
                switch next(24) {
                case 0: return "**\(w) \(wordsList[next(wordsList.count)])**"
                case 1: return "*\(w)*"
                case 2: return "`\(w)_\(next(100))`"
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
                    out += "\(makeWords(25 + next(40), styled: true)).\n\n"
                }
                for i in 0..<(4 + next(4)) {
                    let line = makeWords(4 + next(8), styled: true)
                    out += (sub % 2 == 0) ? "- \(line)\n" : "\(i + 1). \(line)\n"
                }
                out += "\n- [x] \(makeWords(4, styled: true))\n- [ ] \(makeWords(5, styled: true))\n\n"
                if next(3) == 0 {
                    out += "> \(makeWords(10 + next(14), styled: true)).\n\n"
                }
                if next(4) == 0 {
                    out += "```swift\nlet value_\(section) = \"\(makeWords(2, styled: false))\"\n```\n\n"
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
        let noteEl: El<State> = s.useMemo
            ? memo("note", "\(s.src.utf8.count)-\(s.marks.count)", build: buildNote)
            : buildNote()

        return col().wFull().hFull().bg(bg).child(
            col().key("viewport").wFull().grow(1).minH(0).scroll(stickBottom: false).child(
                col().wFull().px(32).py(24).child(noteEl)
            )
        )
    }

    public static func runReport(
        sizes: [Int] = [5],
        step: Float = 20.0,
        useMemo: Bool = false,
        highlightCount: Int = 60,
        testFonts: Bool = true
    ) -> Report {
        var rows: [MetricRow] = []
        var lines: [String] = []
        let kit = Kit.neutral(dark: true)
        let style = MarkdownStyle.fromKit(kit)

        func glyphCount(_ rf: RenderFrame) -> Int {
            rf.instances.reduce(0) { $0 + ($1.params.y == KIND_GLYPH ? 1 : 0) }
        }

        for kb in sizes {
            let src = generateNote(bytes: kb * 1024)
            let state = State(src: src, style: style, useMemo: useMemo)
            let rt = Runtime(
                state: state,
                viewport: Vec2(900, height),
                pixelScale: 2.0,
                systemDark: true,
                view: view
            )

            // open
            _ = takeFramePhases()
            let cOpen0 = threadCpuMs()
            let openFrame = rt.renderFrame(at: 0.0)
            let openCpu = threadCpuMs() - cOpen0
            rows.append(MetricRow(sizeKB: kb, testCase: "open", medianCpuMs: openCpu, glyphs: glyphCount(openFrame), instances: openFrame.instances.count))
            lines.append(String(format: "METRIC size=%dk case=open metric=cpu_ms median=%.4f glyphs=%d", kb, openCpu, glyphCount(openFrame)))

            // resize 900 -> 600 -> 900
            var resizeCpus: [Double] = []
            var lastGlyphs = glyphCount(openFrame)
            var lastInstances = openFrame.instances.count
            var now = 0.0
            var widths: [Float] = []
            var w: Float = 900 - step
            while w >= 600 { widths.append(w); w -= step }
            w = 600 + step
            while w <= 900 { widths.append(w); w += step }
            for width in widths {
                rt.setViewport(Vec2(width, height))
                now += 1.0 / 120.0
                let c0 = threadCpuMs()
                let rf = rt.renderFrame(at: now)
                resizeCpus.append(threadCpuMs() - c0)
                lastGlyphs = glyphCount(rf)
                lastInstances = rf.instances.count
            }
            let sortedResize = resizeCpus.sorted()
            let resizeMed = sortedResize.isEmpty ? 0 : sortedResize[sortedResize.count / 2]
            rows.append(MetricRow(sizeKB: kb, testCase: "resize", medianCpuMs: resizeMed, glyphs: lastGlyphs, instances: lastInstances))
            lines.append(String(format: "METRIC size=%dk case=resize metric=cpu_ms median=%.4f n=%d", kb, resizeMed, sortedResize.count))

            // scroll
            var scrollCpus: [Double] = []
            for _ in 0..<12 {
                now += 1.0 / 120.0
                let c0 = threadCpuMs()
                rt.wheel(WheelEvent(dx: 0, dy: -60), at: Vec2(450, 450), now: now)
                let rf = rt.renderFrame(at: now)
                scrollCpus.append(threadCpuMs() - c0)
                lastGlyphs = glyphCount(rf)
                lastInstances = rf.instances.count
            }
            let sortedScroll = scrollCpus.sorted()
            let scrollMed = sortedScroll.isEmpty ? 0 : sortedScroll[sortedScroll.count / 2]
            rows.append(MetricRow(sizeKB: kb, testCase: "scroll", medianCpuMs: scrollMed, glyphs: lastGlyphs, instances: lastInstances))
            lines.append(String(format: "METRIC size=%dk case=scroll metric=cpu_ms median=%.4f n=%d", kb, scrollMed, sortedScroll.count))

            // marks
            if highlightCount > 0 {
                let bytes = Array(src.utf8)
                var hlItems: [(ranges: [Range<Int>], style: MarkdownHighlight)] = []
                var pos = 0
                while hlItems.count < highlightCount && pos + 6 < bytes.count {
                    if bytes[pos] >= 0x61 && bytes[pos] <= 0x7A {
                        hlItems.append(([pos..<(pos + 5)], MarkdownHighlight.match().bg(Color.white.alpha(0.18))))
                        pos += 29
                    } else {
                        pos += 1
                    }
                }
                rt.update(at: now) { st, _ in
                    st.marks = hlItems
                }
                now += 1.0 / 120.0
                let c0 = threadCpuMs()
                let rf = rt.renderFrame(at: now)
                let marksCpu = threadCpuMs() - c0
                rows.append(MetricRow(sizeKB: kb, testCase: "marks", medianCpuMs: marksCpu, glyphs: glyphCount(rf), instances: rf.instances.count))
                lines.append(String(format: "METRIC size=%dk case=marks metric=cpu_ms median=%.4f marks=%d", kb, marksCpu, hlItems.count))
            }

            // fonts
            if testFonts {
                let original = FontFamiliesRegistry.currentFamilies()
                defer { FontFamiliesRegistry.setFamilies(sans: original.sans, mono: original.mono) }
                let c0 = threadCpuMs()
                FontFamiliesRegistry.setFamilies(sans: "Helvetica Neue", mono: "Menlo")
                rt.update(at: now) { _, _ in }
                now += 1.0 / 120.0
                let rf = rt.renderFrame(at: now)
                let fontsCpu = threadCpuMs() - c0
                rows.append(MetricRow(sizeKB: kb, testCase: "fonts", medianCpuMs: fontsCpu, glyphs: glyphCount(rf), instances: rf.instances.count))
                lines.append(String(format: "METRIC size=%dk case=fonts metric=cpu_ms median=%.4f glyphs=%d", kb, fontsCpu, glyphCount(rf)))
            }
        }

        return Report(metrics: rows, output: lines.joined(separator: "\n"))
    }

    public static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let sizes = args.firstIndex(of: "--sizes").flatMap { i in i + 1 < args.count ? args[i + 1].split(separator: ",").compactMap { Int($0) } : nil } ?? [5, 50]
        let memoFlag = args.contains("--memo")
        let report = runReport(sizes: sizes, step: 4.0, useMemo: memoFlag)
        print(report.output)
    }
}
