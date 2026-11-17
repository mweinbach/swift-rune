import Foundation
import Rune
#if canImport(Metal) && canImport(QuartzCore)
import Metal
import QuartzCore
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Parity port of `crates/rune/examples/long_note.rs`:
/// Measures editing, IME commit, enter/backspace, undo/paste, wheel scroll, arrow/cmd navigation,
/// pointer hit-testing, and heap/footprint growth in a multi-line `textInput` holding a Markdown note.
@main
public enum RuneLongNoteApp {
    public static let size = Vec2(760, 900)
    public static let lineHeight: Float = 22.0
    public static let bg = Color(r: 0.008, g: 0.008, b: 0.009, a: 1.0)
    public static let metrics = [
        "cpu_ms", "view_ms", "commit_ms", "layout_ms", "text_ms",
        "paint_ms", "shaped", "glyphs", "allocations", "encode_ms",
    ]

    public struct State: Sendable {
        public var note: TextEdit
        public var blocks: [TextEdit]
        public var useBlocks: Bool
        public var focusedBlock: Int?

        public init(note: TextEdit, blocks: [TextEdit] = [], useBlocks: Bool = false, focusedBlock: Int? = nil) {
            self.note = note
            self.blocks = blocks
            self.useBlocks = useBlocks
            self.focusedBlock = focusedBlock
        }
    }

    public struct CaseSummary: Sendable, Equatable {
        public let sizeKB: Int
        public let testCase: String
        public let metric: String
        public let median: Double
        public let p95: Double
        public let max: Double
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

    public static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        col().wFull().hFull().bg(bg).child(
            col().key("viewport").wFull().grow(1).minH(0).scroll(stickBottom: false).child(
                col().wFull().px(32).py(24).child(
                    textInput(key: "editor", \State.note)
                        .font(editorStyle())
                        .wFull()
                        .focused(true)
                        // Return in a field without `onSubmit` goes to the default button; an editor types a newline.
                        .onSubmit { st, _, _ in
                            st.note.insert("\n")
                        }
                )
            )
        )
    }

    /// `--blocks`: one field per blank-line-separated block, as an app that keys its Markdown blocks.
    public static func blockView(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        var fields: [El<State>] = []
        fields.reserveCapacity(s.blocks.count)
        for i in 0..<s.blocks.count {
            fields.append(
                textInput(key: "b\(i)", \State.blocks[i])
                    .font(editorStyle())
                    .wFull()
                    .focused(s.focusedBlock == i)
                    .onSubmit { st, _, _ in
                        st.blocks[i].insert("\n")
                    }
            )
        }
        return col().wFull().hFull().bg(bg).child(
            col().key("viewport").wFull().grow(1).minH(0).scroll(stickBottom: false).child(
                col().key("editor").wFull().px(32).py(24).gap(lineHeight).children(fields)
            )
        )
    }

    /// A deterministic fictional Markdown note of at least `bytes` bytes.
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
            return Int(seed % UInt64(n))
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
                    let n = 25 + next(60)
                    out += makeWords(n)
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
                        let sn = 3 + next(5)
                        out += "  - \(makeWords(sn))\n"
                    }
                }
                out += "\n"
                switch next(3) {
                case 0:
                    out += "```rust\n"
                    let codeLen = 5 + next(6)
                    for i in 0..<codeLen {
                        let indent = String(repeating: "    ", count: next(3))
                        let name = wordsList[next(wordsList.count)]
                        let call = wordsList[next(wordsList.count)]
                        out += "\(indent)let \(name)_\(i) = \(call)(\"\(makeWords(2))\");\n"
                    }
                    out += "```\n\n"
                case 1:
                    let n = 12 + next(20)
                    out += "> \(makeWords(n))\n\n"
                default:
                    for _ in 0..<3 {
                        let n = 3 + next(6)
                        out += "- [ ] \(makeWords(n))\n"
                    }
                    out += "\n"
                }
            }
        }
        return out
    }

    public static func pasteSnippet() -> String {
        var p = ""
        let all = generateNote(bytes: 4096)
        for line in all.split(separator: "\n", omittingEmptySubsequences: false) {
            if p.utf8.count + line.utf8.count + 1 > 2048 { break }
            p += line
            p.append("\n")
        }
        return p
    }

    private final class OffscreenDraw {
        #if canImport(Metal) && canImport(QuartzCore)
        let renderer: MetalRenderer
        let target: MTLTexture

        init() throws {
            let r = try MetalRenderer()
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb,
                width: max(1, Int(size.x * 2.0)),
                height: max(1, Int(size.y * 2.0)),
                mipmapped: false
            )
            desc.usage = [.renderTarget, .shaderRead]
            guard let tex = r.device.makeTexture(descriptor: desc) else {
                throw NSError(domain: "RuneLongNote", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate offscreen Metal texture"])
            }
            self.renderer = r
            self.target = tex
        }

        func draw(scene: RefScene) -> Double {
            let t0 = ContinuousClock.now
            guard let cb = renderer.commandQueue.makeCommandBuffer() else { return 0.0 }
            try? renderer.encode(scene: scene, into: target, commandBuffer: cb)
            cb.commit()
            let dur = t0.duration(to: .now)
            let ms = Double(dur.components.seconds) * 1e3 + Double(dur.components.attoseconds) / 1e15
            cb.waitUntilCompleted()
            return ms
        }
        #else
        init() throws {}
        func draw(scene: RefScene) -> Double { 0.0 }
        #endif
    }

    private static func liveMallocBlocks() -> UInt {
        #if canImport(Darwin)
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return UInt(stats.blocks_in_use)
        #else
        return 0
        #endif
    }

    private static func heapMB() -> Double {
        #if canImport(Darwin)
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Double(stats.size_in_use) / 1_048_576.0
        #else
        return 0.0
        #endif
    }

    private static func footprintMB() -> Double {
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
        var fields: [TextEdit] = []
        var focusedBlock: Int? = nil
        if blocks {
            var start = 0
            for (idx, part) in text.components(separatedBy: "\n\n").enumerated() {
                var b = TextEdit(part, multiline: true)
                let len = part.utf8.count
                if focusedBlock == nil && caret >= start && caret <= start + len {
                    focusedBlock = idx
                    b.setCursor(utf8Offset: caret - start)
                }
                start += len + 2
                fields.append(b)
            }
        } else {
            note.setCursor(utf8Offset: min(caret, note.text.utf8.count))
        }
        let rt = Runtime(
            state: State(note: note, blocks: fields, useBlocks: blocks, focusedBlock: focusedBlock),
            viewport: size,
            pixelScale: 2.0,
            systemDark: true,
            textSystem: ts,
            view: { st, cx in
                st.useBlocks ? blockView(st, &cx) : view(st, &cx)
            }
        )
        _ = rt.frame(at: 0.0)
        return (rt, 0.0)
    }

    private static func fieldKey(_ rt: Runtime<State>) -> String {
        rt.focusedKey ?? "editor"
    }

    private static func caretInView(_ rt: Runtime<State>) -> Float? {
        guard let c = rt.element(byKey: fieldKey(rt))?.caret,
              c.count >= 4,
              let v = rt.element(byKey: "viewport")?.rect,
              v.count >= 4 else {
            return nil
        }
        if c[1] >= v[1] - 0.5 && c[1] + c[3] <= v[1] + v[3] + 0.5 {
            return c[1] - v[1]
        }
        return nil
    }

    private static func editorY(_ rt: Runtime<State>) -> Float {
        guard let rect = rt.element(byKey: "editor")?.rect, rect.count >= 2 else { return 0 }
        return rect[1]
    }

    private static func press(_ rt: Runtime<State>, _ key: Key, at now: Double) {
        _ = rt.keyDown(KeyEvent(key: key, mods: .none), at: now)
    }

    private static func primaryShortcut(_ rt: Runtime<State>, _ key: Key, at now: Double) {
        let command = KeyPlatform.current == .mac
        let mods = Mods(ctrl: !command, cmd: command, logo: command)
        _ = rt.keyDown(KeyEvent(key: key, mods: mods), at: now)
    }

    public static func runReport(
        sizes: [Int] = [5, 50, 200],
        samples: Int = 60,
        only: String? = nil,
        gpu: Bool = false,
        blocks: Bool = false
    ) throws -> Report {
        let drawer = gpu ? try OffscreenDraw() : nil
        let onlySet: Set<String>? = only.map { Set($0.split(separator: ",").map(String.init)) }
        func shouldRun(_ name: String) -> Bool {
            onlySet?.contains(name) ?? true
        }

        var lines: [String] = []
        var summaries: [CaseSummary] = []
        let paste = pasteSnippet()
        var lastBytes = 0
        var lastLines = 0
        var undoDepth = 0
        var scrollFrames = 0
        var hiddenCarets = 0

        func timed(_ rt: Runtime<State>, now: inout Double, _ input: (Runtime<State>, Double) -> Void) -> [Double] {
            _ = takeFramePhases()
            let alloc0 = liveMallocBlocks()
            let cpu0 = threadCpuMs()
            input(rt, now)
            now += 1.0 / 120.0
            let scene = rt.frame(at: now)
            let cpu = threadCpuMs() - cpu0
            let allocations = Double(max(0, Int64(liveMallocBlocks()) - Int64(alloc0)))
            let p = takeFramePhases()
            let encode = drawer?.draw(scene: scene) ?? 0.0
            let q = FRAME_PHASES
            let glyphs = Double(scene.primitives.count(where: { $0.kind == .glyph }))
            // `TextSystem` does not currently expose a `shaped` counter in Swift; reported as 0.
            let shaped = 0.0
            return [cpu, p[q], p[q + 1], p[q + 2], p[q + 3], p[q + 4], shaped, glyphs, allocations, encode]
        }

        func settle(_ rt: Runtime<State>, now: inout Double) {
            var n = 0
            var lastScene: RefScene? = nil
            while n < 240 {
                now += 1.0 / 120.0
                let scene = rt.frame(at: now)
                lastScene = scene
                n += 1
                if !rt.isAnimating { break }
            }
            if let s = lastScene {
                _ = drawer?.draw(scene: s)
            }
        }

        func recordCase(_ kb: Int, _ name: String, _ rows: [[Double]]) {
            guard !rows.isEmpty else { return }
            for (m, metricName) in metrics.enumerated() {
                var v = rows.map { $0[m] }
                v.sort()
                let med = v[v.count / 2]
                let p95 = v[min(v.count - 1, Int((Double(v.count - 1) * 0.95).rounded()))]
                let maxV = v[v.count - 1]
                summaries.append(CaseSummary(
                    sizeKB: kb,
                    testCase: name,
                    metric: metricName,
                    median: med,
                    p95: p95,
                    max: maxV,
                    samples: v.count
                ))
                lines.append(String(
                    format: "METRIC size=%dk case=%@ metric=%@ median=%.4f p95=%.4f max=%.4f n=%d",
                    kb, name, metricName, med, p95, maxV, v.count
                ))
            }
        }

        for kb in sizes {
            let text = generateNote(bytes: kb * 1024)
            let halfCount = text.utf8.count / 2
            let mid = Array(text.utf8.prefix(halfCount)).lastIndex(of: 0x20).map { $0 + 1 } ?? 0
            lastBytes = text.utf8.count
            lastLines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0).count
            lines.append("NOTE size=\(kb)k bytes=\(lastBytes) lines=\(lastLines)")

            if shouldRun("memory") {
                let (heap0, foot0) = (heapMB(), footprintMB())
                var p = makeRuntime(text: text, caret: 0, blocks: blocks)
                settle(p.rt, now: &p.now)
                let (heap1, foot1) = (heapMB(), footprintMB())
                func typed(_ n: Int) -> (Double, Double) {
                    for _ in 0..<n {
                        _ = p.rt.dispatchImeEvent(.commit("x"), at: p.now)
                        p.now += 1.0 / 120.0
                        _ = p.rt.frame(at: p.now)
                    }
                    settle(p.rt, now: &p.now)
                    return (heapMB() - heap0, footprintMB() - foot0)
                }
                let (heap50, foot50) = typed(50)
                let (heap200, foot200) = typed(150)
                lines.append(String(
                    format: "MEMORY size=%dk heap_open_mb=%.2f heap_50_keys_mb=%.2f heap_200_keys_mb=%.2f footprint_open_mb=%.2f footprint_50_keys_mb=%.2f footprint_200_keys_mb=%.2f",
                    kb, heap1 - heap0, heap50, heap200, foot1 - foot0, foot50, foot200
                ))
            }

            let commitChars = ["a", "b", "c", " "]
            for (name, at) in [("type_start", 0), ("type_mid", mid), ("type_end", text.utf8.count)] {
                guard shouldRun(name) else { continue }
                var p = makeRuntime(text: text, caret: at, blocks: blocks)
                for _ in 0..<3 {
                    _ = p.rt.dispatchImeEvent(.commit("w"), at: p.now)
                    p.now += 1.0 / 120.0
                    _ = p.rt.frame(at: p.now)
                }
                settle(p.rt, now: &p.now)
                var rows: [[Double]] = []
                rows.reserveCapacity(samples)
                for i in 0..<samples {
                    let ch = commitChars[i % 4]
                    rows.append(timed(p.rt, now: &p.now) { rt, t in
                        _ = rt.dispatchImeEvent(.commit(ch), at: t)
                    })
                }
                if caretInView(p.rt) == nil {
                    hiddenCarets += 1
                    FileHandle.standardError.write(Data(
                        "long_note warning: \(name) size=\(kb)k caret left viewport (blocked on Runtime follow_caret auto-scroll).\n".utf8
                    ))
                }
                recordCase(kb, name, rows)
            }

            for name in ["enter_mid", "backspace_mid"] {
                guard shouldRun(name) else { continue }
                var p = makeRuntime(text: text, caret: mid, blocks: blocks)
                _ = p.rt.dispatchImeEvent(.commit("w"), at: p.now)
                settle(p.rt, now: &p.now)
                let enter = (name == "enter_mid")
                let before = docLength(p.rt.state)
                var rows: [[Double]] = []
                rows.reserveCapacity(samples)
                for _ in 0..<samples {
                    if !enter {
                        _ = p.rt.dispatchImeEvent(.commit("qz"), at: p.now)
                        p.now += 1.0 / 120.0
                        _ = p.rt.frame(at: p.now)
                    }
                    rows.append(timed(p.rt, now: &p.now) { rt, t in
                        press(rt, enter ? .enter : .backspace, at: t)
                    })
                }
                let after = docLength(p.rt.state)
                precondition(after - before == samples, "\(name): one byte per press")
                recordCase(kb, name, rows)
            }

            if shouldRun("paste_2k") || shouldRun("undo") {
                var p = makeRuntime(text: text, caret: mid, blocks: blocks)
                _ = p.rt.dispatchImeEvent(.commit("w"), at: p.now)
                settle(p.rt, now: &p.now)
                var pastes: [[Double]] = []
                var undos: [[Double]] = []
                let pairs = (samples + 1) / 2
                for i in 0..<pairs {
                    pastes.append(timed(p.rt, now: &p.now) { rt, t in
                        rt.paste(ClipboardContent(String(format: "%03d%@", i, paste)), at: t)
                    })
                    undos.append(timed(p.rt, now: &p.now) { rt, t in
                        primaryShortcut(rt, .command("z"), at: t)
                    })
                }
                precondition(docLength(p.rt.state) == text.utf8.count + 1, "every paste undone")
                recordCase(kb, "paste_2k", pastes)
                recordCase(kb, "undo", undos)
            }

            if shouldRun("undo_depth") {
                var p = makeRuntime(text: text, caret: mid, blocks: blocks)
                settle(p.rt, now: &p.now)
                for i in 0..<100 {
                    p.rt.paste(ClipboardContent(String(format: "edit %03d ", i)), at: p.now)
                    p.now += 1.0 / 120.0
                    _ = p.rt.frame(at: p.now)
                }
                var steps = 0
                while true {
                    let before = docLength(p.rt.state)
                    primaryShortcut(p.rt, .command("z"), at: p.now)
                    p.now += 1.0 / 120.0
                    _ = p.rt.frame(at: p.now)
                    if docLength(p.rt.state) == before { break }
                    steps += 1
                }
                undoDepth = steps
                lines.append("UNDO size=\(kb)k edits=100 undo_steps_kept=\(steps)")
            }

            if shouldRun("scroll") {
                var p = makeRuntime(text: text, caret: 0, blocks: blocks)
                settle(p.rt, now: &p.now)
                var rows: [[Double]] = []
                let top = editorY(p.rt)
                while true {
                    let before = editorY(p.rt)
                    rows.append(timed(p.rt, now: &p.now) { rt, t in
                        rt.wheel(WheelEvent(dx: 0, dy: -120.0), at: Vec2(size.x / 2, size.y / 2), now: t)
                    })
                    if abs(editorY(p.rt) - before) < 0.01 { break }
                }
                scrollFrames = rows.count
                lines.append(String(format: "SCROLL size=%dk frames=%d travel=%.0f", kb, scrollFrames, top - editorY(p.rt)))
                recordCase(kb, "scroll", rows)
            }

            if blocks { continue }

            if shouldRun("down") {
                var p = makeRuntime(text: text, caret: 0, blocks: false)
                settle(p.rt, now: &p.now)
                var rows: [[Double]] = []
                var worstJump: Float = 0.0
                var hidden = 0
                for _ in 0..<max(samples, 120) {
                    let before = editorY(p.rt)
                    rows.append(timed(p.rt, now: &p.now) { rt, t in
                        press(rt, .arrowDown, at: t)
                    })
                    worstJump = max(worstJump, abs(editorY(p.rt) - before))
                    if caretInView(p.rt) == nil { hidden += 1 }
                }
                hiddenCarets += hidden
                lines.append(String(format: "CARET size=%dk case=down moves=%d hidden=%d worst_jump_pt=%.1f", kb, rows.count, hidden, worstJump))
                precondition(hidden == 0, "down: caret left the viewport")
                precondition(worstJump <= 2 * lineHeight, "down: the viewport jumped \(worstJump) points in one press")
                recordCase(kb, "down", rows)
            }

            if shouldRun("cmd_down") {
                var rows: [[Double]] = []
                var visible = true
                for _ in 0..<min(samples, 15) {
                    var p = makeRuntime(text: text, caret: 0, blocks: false)
                    settle(p.rt, now: &p.now)
                    rows.append(timed(p.rt, now: &p.now) { rt, t in
                        let endOfDocument: Key = KeyPlatform.current == .mac ? .arrowDown : .end
                        primaryShortcut(rt, endOfDocument, at: t)
                    })
                    settle(p.rt, now: &p.now)
                    visible = visible && (p.rt.state.note.cursor == p.rt.state.note.text.utf8.count) && (caretInView(p.rt) != nil)
                }
                lines.append("CARET size=\(kb)k case=cmd_down at_end_in_view=\(visible)")
                if !visible {
                    hiddenCarets += 1
                    FileHandle.standardError.write(Data(
                        "long_note warning: cmd_down size=\(kb)k caret outside viewport (blocked on Runtime follow_caret auto-scroll).\n".utf8
                    ))
                }
                recordCase(kb, "cmd_down", rows)
            }

            if shouldRun("click") {
                var p = makeRuntime(text: text, caret: 0, blocks: false)
                settle(p.rt, now: &p.now)
                var rows: [[Double]] = []
                var worstJump: Float = 0.0
                var moved = 0
                let v = p.rt.element(byKey: "viewport")!.rect
                for i in 0..<min(samples, 30) {
                    p.rt.wheel(WheelEvent(dx: 0, dy: -900.0), at: Vec2(size.x / 2, size.y / 2), now: p.now)
                    settle(p.rt, now: &p.now)
                    let beforeY = editorY(p.rt)
                    let beforeCursor = p.rt.state.note.cursor
                    let y = v[1] + v[3] - 40.0 - Float(i % 5) * lineHeight
                    rows.append(timed(p.rt, now: &p.now) { rt, t in
                        rt.pointerDown(at: Vec2(200.0, y), at: t)
                        rt.pointerUp(at: Vec2(200.0, y), at: t)
                    })
                    settle(p.rt, now: &p.now)
                    worstJump = max(worstJump, abs(editorY(p.rt) - beforeY))
                    if p.rt.state.note.cursor != beforeCursor && caretInView(p.rt) != nil {
                        moved += 1
                    }
                }
                lines.append(String(format: "CARET size=%dk case=click clicks=%d caret_landed_in_view=%d worst_jump_pt=%.1f", kb, rows.count, moved, worstJump))
                recordCase(kb, "click", rows)
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
        let samples = Int(arg("--samples") ?? "60") ?? 60
        let sizes = arg("--sizes")?.split(separator: ",").compactMap { Int($0) } ?? [5, 50, 200]
        let only = arg("--only")
        let gpu = args.contains("--gpu")
        let blocks = args.contains("--blocks")
        let report = try runReport(sizes: sizes, samples: samples, only: only, gpu: gpu, blocks: blocks)
        print(report.output)
    }
}
