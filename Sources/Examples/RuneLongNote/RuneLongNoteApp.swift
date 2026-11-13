import Foundation
import Rune
#if canImport(Metal)
import Metal
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Parity port of `crates/rune/examples/long_note.rs`:
/// Measures editing, IME commit, undo/paste, wheel scroll, arrow navigation,
/// pointer hit-testing, and memory growth in a multi-line `textInput` holding a Markdown note.
@main
public enum RuneLongNoteApp {
    public static let size = Vec2(760, 900)
    public static let lineHeight: Float = 22.0
    public static let bg = Color(r: 0.008, g: 0.008, b: 0.009, a: 1.0)

    public struct State: Sendable {
        public var note: TextEdit
        public var blocks: [TextEdit]

        public init(note: TextEdit, blocks: [TextEdit] = []) {
            self.note = note
            self.blocks = blocks
        }
    }

    public struct CaseSummary: Sendable, Equatable {
        public let sizeKB: Int
        public let testCase: String
        public let medianCpuMs: Double
        public let p95CpuMs: Double
        public let maxCpuMs: Double
        public let samples: Int
    }

    public struct Report: Sendable {
        public let noteBytes: Int
        public let noteLines: Int
        public let undoDepth: Int
        public let scrollFrames: Int
        public let caretHiddenCount: Int
        public let cases: [CaseSummary]
        public let output: String
    }

    public static func editorStyle() -> TextStyle {
        TextStyle(size: 15.0, weight: 400).lh(lineHeight)
    }

    public static func singleView(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        col().wFull().hFull().bg(bg).child(
            col().key("viewport").wFull().grow(1).minH(0).scroll(stickBottom: false).child(
                col().wFull().px(32).py(24).child(
                    textInput(key: "editor", \State.note)
                        .font(editorStyle())
                        .wFull()
                        .focused(true)
                        .onSubmit { st, _, _ in
                            st.note.insert("\n")
                        }
                )
            )
        )
    }

    public static func blockView(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        var editorCol: El<State> = col().key("editor").wFull().px(32).py(24).gap(lineHeight)
        for i in 0..<s.blocks.count {
            editorCol = editorCol.child(
                textInput(key: "b\(i)", \State.blocks[i])
                    .font(editorStyle())
                    .wFull()
                    .onSubmit { st, _, _ in
                        st.blocks[i].insert("\n")
                    }
            )
        }
        return col().wFull().hFull().bg(bg).child(
            col().key("viewport").wFull().grow(1).minH(0).scroll(stickBottom: false).child(editorCol)
        )
    }

    public static func generateNote(bytes: Int) -> String {
        let wordsList = [
            "amber", "lantern", "orchard", "quiet", "harbor", "copper", "meadow", "signal", "drift",
            "pebble", "willow", "ember", "tide", "cinder", "fable", "glacier", "hollow", "juniper", "kestrel", "lumen",
            "marrow", "nimbus", "opal", "prism", "quill", "ripple", "sable", "thistle", "umber", "vellum", "wander",
            "yarrow", "zephyr", "bramble", "cobalt", "dune", "fern", "grove", "heron", "isle", "the", "a", "of", "and",
            "to", "in", "with", "under", "over", "before",
        ]
        var seed: UInt64 = 0x9e37_79b9_7f4a_7c15
        func next(_ n: Int) -> Int {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Int(seed % UInt64(max(1, n)))
        }
        func makeWords(_ count: Int) -> String {
            (0..<count).map { _ in wordsList[next(wordsList.count)] }.joined(separator: " ")
        }

        var out = ""
        var section = 0
        while out.utf8.count < bytes {
            section += 1
            out += "# Section \(section): \(makeWords(3))\n\n"
            for sub in 0..<3 {
                out += "## \(makeWords(2)) \(sub)\n\n"
                for _ in 0..<2 {
                    out += makeWords(25 + next(60))
                    out += ".\n\n"
                }
                let listLen = 4 + next(5)
                for i in 0..<listLen {
                    let n = 4 + next(10)
                    if sub % 2 == 0 {
                        out += "- \(makeWords(n))\n"
                    } else {
                        out += "\(i + 1). \(makeWords(n))\n"
                    }
                    if next(4) == 0 {
                        out += "  - \(makeWords(3 + next(5)))\n"
                    }
                }
                out += "\n"
                if next(3) == 0 {
                    out += "> \(makeWords(12 + next(20))).\n\n"
                }
                if next(4) == 0 {
                    out += "```\nlet value_\(section) = \"\(makeWords(3))\";\n```\n\n"
                }
            }
        }
        return out
    }

    public static func pasteSnippet() -> String {
        let base = "Added paragraph on the quiet orchard path and the harbor signal. "
        var out = ""
        while out.utf8.count < 2048 {
            out += base
        }
        return out
    }

    private static func residentMB() -> Double {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            return Double(info.phys_footprint) / 1_048_576.0
        }
        #endif
        return 0.0
    }

    private static func docLength(_ s: State) -> Int {
        if s.blocks.isEmpty {
            return s.note.text.utf8.count
        }
        return max(0, s.blocks.reduce(0) { $0 + $1.text.utf8.count + 2 } - 2)
    }

    private static func makeRuntime(text: String, caret: Int, blocks: Bool) -> (rt: Runtime<State>, now: Double) {
        let ts = TextSystem()
        _ = ts.shape(text: "Warm fonts", style: editorStyle(), maxWidth: nil, pixelScale: 2.0, emitGlyphs: false)
        var note = TextEdit(blocks ? "" : text, multiline: true)
        var blockFields: [TextEdit] = []
        if blocks {
            for part in text.components(separatedBy: "\n\n") {
                blockFields.append(TextEdit(part, multiline: true))
            }
        } else {
            note.setCursor(utf8Offset: min(caret, note.text.utf8.count))
        }
        let rt = Runtime(
            state: State(note: note, blocks: blockFields),
            viewport: size,
            pixelScale: 2.0,
            systemDark: true,
            textSystem: ts,
            view: { st, cx in
                blocks ? blockView(st, &cx) : singleView(st, &cx)
            }
        )
        _ = rt.frame(at: 0.0)
        return (rt, 0.0)
    }

    private static func caretInView(_ rt: Runtime<State>) -> Float? {
        guard let c = rt.focusedCaretRect(),
              let v = rt.element(byKey: "viewport")?.rect,
              v.count >= 4 else {
            return nil
        }
        if c.top >= v[1] - 0.5 && c.bottom <= v[1] + v[3] + 0.5 {
            return c.top - v[1]
        }
        return nil
    }

    private static func editorY(_ rt: Runtime<State>) -> Float {
        guard let rect = rt.element(byKey: "editor")?.rect, rect.count >= 2 else { return 0 }
        return rect[1]
    }

    public static func runReport(
        sizes: [Int] = [5],
        samples: Int = 8,
        blocks: Bool = false
    ) throws -> Report {
        var lines: [String] = []
        var summaries: [CaseSummary] = []
        let paste = pasteSnippet()
        var lastBytes = 0
        var lastLines = 0
        var undoDepth = 0
        var scrollFrames = 0
        var hiddenCarets = 0

        func step(_ rt: Runtime<State>, now: inout Double, _ body: (Double) -> Void) -> Double {
            _ = takeFramePhases()
            let cpu0 = threadCpuMs()
            body(now)
            now += 1.0 / 120.0
            _ = rt.frame(at: now)
            return threadCpuMs() - cpu0
        }

        func recordCase(_ kb: Int, _ name: String, _ cpuSamples: [Double]) {
            guard !cpuSamples.isEmpty else { return }
            let sorted = cpuSamples.sorted()
            let med = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded()))]
            let maxV = sorted[sorted.count - 1]
            summaries.append(CaseSummary(
                sizeKB: kb,
                testCase: name,
                medianCpuMs: med,
                p95CpuMs: p95,
                maxCpuMs: maxV,
                samples: sorted.count
            ))
            lines.append(String(
                format: "METRIC size=%dk case=%@ metric=cpu_ms median=%.4f p95=%.4f max=%.4f n=%d",
                kb, name, med, p95, maxV, sorted.count
            ))
        }

        for kb in sizes {
            let text = generateNote(bytes: kb * 1024)
            lastBytes = text.utf8.count
            lastLines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            let mid = max(0, text.utf8.count / 2)
            lines.append("NOTE size=\(kb)k bytes=\(lastBytes) lines=\(lastLines)")

            let foot0 = residentMB()
            var pair = makeRuntime(text: text, caret: mid, blocks: blocks)
            for _ in 0..<4 {
                pair.now += 1.0 / 120.0
                _ = pair.rt.frame(at: pair.now)
            }
            let footOpen = residentMB()
            lines.append(String(format: "MEMORY size=%dk opened_mb=%.2f delta_mb=%.2f", kb, footOpen, max(0, footOpen - foot0)))

            // Typing cases (IME commit)
            for (name, caret) in [("type_start", 0), ("type_mid", mid), ("type_end", text.utf8.count)] {
                var p = makeRuntime(text: text, caret: caret, blocks: blocks)
                var cpu: [Double] = []
                for _ in 0..<samples {
                    cpu.append(step(p.rt, now: &p.now) { t in
                        _ = p.rt.dispatchIme(.commit("a"), at: t)
                    })
                }
                recordCase(kb, name, cpu)
            }

            // Paste + Undo
            do {
                var p = makeRuntime(text: text, caret: mid, blocks: blocks)
                var pasteCpu: [Double] = []
                var undoCpu: [Double] = []
                for i in 0..<max(1, samples / 2) {
                    pasteCpu.append(step(p.rt, now: &p.now) { t in
                        p.rt.paste(ClipboardContent(String(format: "%03d%@", i, paste)), at: t)
                    })
                    undoCpu.append(step(p.rt, now: &p.now) { t in
                        _ = p.rt.keyDown(KeyEvent(key: .command("z"), mods: Mods(cmd: true)), at: t)
                    })
                }
                precondition(docLength(p.rt.state) == text.utf8.count, "every paste undone")
                recordCase(kb, "paste_2k", pasteCpu)
                recordCase(kb, "undo", undoCpu)
            }

            // Undo depth
            do {
                var p = makeRuntime(text: text, caret: mid, blocks: blocks)
                for i in 0..<30 {
                    p.rt.paste(ClipboardContent(String(format: "edit %03d ", i)), at: p.now)
                    p.now += 1.0 / 120.0
                    _ = p.rt.frame(at: p.now)
                }
                var steps = 0
                while steps < 40 {
                    let before = docLength(p.rt.state)
                    _ = p.rt.keyDown(KeyEvent(key: .command("z"), mods: Mods(cmd: true)), at: p.now)
                    p.now += 1.0 / 120.0
                    _ = p.rt.frame(at: p.now)
                    if docLength(p.rt.state) == before { break }
                    steps += 1
                }
                undoDepth = steps
                lines.append("UNDO size=\(kb)k edits=30 undo_steps_kept=\(steps)")
            }

            // Scroll down
            do {
                var p = makeRuntime(text: text, caret: 0, blocks: blocks)
                var cpu: [Double] = []
                let top = editorY(p.rt)
                for _ in 0..<40 {
                    let before = editorY(p.rt)
                    cpu.append(step(p.rt, now: &p.now) { t in
                        p.rt.wheel(WheelEvent(dx: 0, dy: -120.0), at: Vec2(size.x / 2, size.y / 2), now: t)
                    })
                    if abs(editorY(p.rt) - before) < 0.01 && cpu.count > 2 {
                        break
                    }
                }
                scrollFrames = cpu.count
                lines.append(String(format: "SCROLL size=%dk frames=%d travel=%.0f", kb, scrollFrames, top - editorY(p.rt)))
                recordCase(kb, "scroll", cpu)
            }

            if !blocks {
                // Arrow down + caret tracking
                var p = makeRuntime(text: text, caret: 0, blocks: false)
                var downCpu: [Double] = []
                var hidden = 0
                for _ in 0..<max(8, samples) {
                    downCpu.append(step(p.rt, now: &p.now) { t in
                        _ = p.rt.keyDown(KeyEvent(key: .arrowDown, mods: .none), at: t)
                    })
                    if p.rt.focusedCaretRect() != nil && caretInView(p.rt) == nil {
                        hidden += 1
                    }
                }
                hiddenCarets += hidden
                lines.append("CARET size=\(kb)k case=down moves=\(downCpu.count) hidden=\(hidden)")
                recordCase(kb, "down", downCpu)
            }
        }

        return Report(
            noteBytes: lastBytes,
            noteLines: lastLines,
            undoDepth: undoDepth,
            scrollFrames: scrollFrames,
            caretHiddenCount: hiddenCarets,
            cases: summaries,
            output: lines.joined(separator: "\n")
        )
    }

    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        func arg(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let sizes = arg("--sizes")?.split(separator: ",").compactMap { Int($0) } ?? [5, 50]
        let samples = Int(arg("--samples") ?? "20") ?? 20
        let blocks = args.contains("--blocks")
        let report = try runReport(sizes: sizes, samples: samples, blocks: blocks)
        print(report.output)
    }
}
