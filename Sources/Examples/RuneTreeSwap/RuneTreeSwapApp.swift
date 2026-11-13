import Foundation
import Rune
import RunePerf
#if canImport(Metal)
import Metal
#endif

/// Parity port of `crates/rune/examples/tree_swap.rs`:
/// Measures big view tree replacement (200-row list <-> 1,800-cell emoji grid) across
/// `first`, `quick`, `recent`, and `stale` cases in both directions.
@main
public enum RuneTreeSwapApp {
    public static let size = Vec2(760, 480)
    public static let rowHeight: Float = 44.0
    public static let columns = 10
    public static let emoji: [String] = [
        "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "🙃", "😉", "😊", "😇", "🥰", "😍", "🤩", "😘", "😗",
        "😚", "😙", "😋", "😛", "😜", "🤪", "😝", "🤑", "🤗", "🤭", "🤫", "🤔", "🤐", "🤨", "😐", "😑", "😶", "😏",
        "😒", "🙄", "😬", "🤥", "😌", "😔", "😪", "🤤", "😴", "😷", "🤒", "🤕", "🤢", "🤮", "🤧", "🥵", "🥶", "🥴",
        "😵", "🤯", "🤠", "🥳", "😎", "🤓", "🧐", "😕", "😟", "🙁", "😮", "😯", "😲", "😳", "🥺", "😦", "😧", "😨",
        "👋", "🤚", "🖐", "✋", "🖖", "👌", "🤏", "✌️", "🤞", "🤟", "🤘", "🤙", "👈", "👉", "👆", "🖕", "👇", "👍",
        "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔", "🐧", "🐦",
        "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🍈", "🍒", "🍑", "🥭", "🍍", "🥥", "🥝", "🍅", "🍆",
        "⚽", "🏀", "🏈", "⚾", "🥎", "🎾", "🏐", "🏉", "🥏", "🎱", "🪀", "🏓", "🏸", "🏒", "🏑", "🥍", "🏏", "🪃",
        "🚗", "🚕", "🚙", "🚌", "🚎", "🏎", "🚓", "🚑", "🚒", "🚐", "🛻", "🚚", "🚛", "🚜", "🦯", "🦽", "🦼", "🛴",
        "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❣️", "💕", "💞", "💓", "💗", "💖", "💘", "💝",
    ]

    public enum Mode: String, Sendable {
        case list
        case grid
    }

    public final class BuildCounter: @unchecked Sendable {
        public var built: Int = 0
    }

    public struct State: @unchecked Sendable {
        public var mode: Mode
        public var selected: Int = 0
        public let lazyGrid: Bool
        public let eager: Bool
        public let titles: [String]
        public let subtitles: [String]
        public let keys: [String]
        public let cells: [String]
        public let rowKeys: [String]
        public let counter = BuildCounter()
        public let listVirtual = VirtualListState()
        public let gridVirtual = VirtualListState()

        public init(mode: Mode, lazyGrid: Bool = false, eager: Bool = false, cells cellCount: Int = 1800) {
            self.mode = mode
            self.lazyGrid = lazyGrid
            self.eager = eager
            self.titles = (0..<200).map { String(format: "Demo App %03d", $0) }
            self.subtitles = (0..<200).map { "Application · \(($0 * 37) % 91) uses this week" }
            self.keys = (0..<200).map { "r\($0)" }
            self.cells = (0..<cellCount).map { emoji[$0 % emoji.count] }
            let gridRowCount = (cellCount + columns - 1) / columns
            self.rowKeys = (0..<gridRowCount).map { "g\($0)" }
        }
    }

    private static let bg = Color(r: 0.008, g: 0.008, b: 0.009, a: 1.0)
    private static let textColor = Color(r: 0.82, g: 0.82, b: 0.84, a: 1.0)
    private static let faintColor = Color(r: 0.26, g: 0.26, b: 0.29, a: 1.0)
    private static let layerColor = Color(r: 0.022, g: 0.022, b: 0.027, a: 1.0)
    private static let hoverColor = Color(r: 1.0, g: 1.0, b: 1.0, a: 0.06)

    private static func uiFont() -> TextStyle { TextStyle(size: 14, weight: 400) }
    private static func box() -> El<State> { el() }
    private static func hstack() -> El<State> { row() }
    private static func vstack() -> El<State> { col() }

    private static func listRow(_ s: State, _ i: Int) -> El<State> {
        s.counter.built += 1
        let selected = (i == s.selected)
        let letter = String(s.titles[i].prefix(1))
        let copyCol: El<State> = col()
            .key("copy")
            .grow(1)
            .shrink()
            .gap(2)
            .child(
                hstack()
                    .key("line")
                    .wFull()
                    .gap(8)
                    .itemsCenter()
                    .child(text(s.titles[i]).font(selected ? TextStyle(size: 14, weight: 500) : uiFont()).color(textColor).ellipsis())
                    .child(text(s.subtitles[i]).font(uiFont()).color(faintColor).ellipsis().grow(1))
            )
        return hstack()
            .wFull()
            .h(rowHeight)
            .px(10)
            .gap(10)
            .itemsCenter()
            .rounded(8)
            .bg(selected ? layerColor : .transparent)
            .hover(hoverColor)
            .role(.option)
            .label(s.titles[i])
            .onClick { st in st.selected = i }
            .child(
                box()
                    .size(22, 22)
                    .rounded(5)
                    .bg(layerColor)
                    .center()
                    .child(text(letter).font(TextStyle(size: 12, weight: 600)).color(textColor))
            )
            .child(copyCol)
    }

    private static func listView(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        var rowsContainer = vstack().key("rows").wFull().px(8).py(6).growth(.default)
        if s.eager {
            rowsContainer = rowsContainer.virtualize(rowHeight)
                .children((0..<s.titles.count).map { i in listRow(s, i).key(s.keys[i]) })
        } else {
            rowsContainer = rowsContainer.virtualRows(
                s.titles.count,
                rowHeight,
                key: { st, i in st.keys[i] },
                build: { st, i in listRow(st, i) }
            )
        }
        return vstack()
            .key("list")
            .wFull()
            .grow(1)
            .minH(0)
            .scroll(stickBottom: false)
            .clipFadeLinear(top: 12, bottom: 12)
            .child(rowsContainer)
    }

    private static func gridRow(_ s: State, _ r: Int) -> El<State> {
        s.counter.built += 1
        let cell = (size.x - 16.0) / Float(columns)
        let glyph = min(cell * 0.5, 34.0)
        var line: El<State> = hstack().wFull().h(cell)
        for c in 0..<columns {
            let index = r * columns + c
            guard index < s.cells.count else { break }
            let emojiStr = s.cells[index]
            let selected = (index == s.selected)
            line = line.child(
                box()
                    .key("c\(index)")
                    .size(cell, cell)
                    .center()
                    .rounded(10)
                    .bg(selected ? layerColor : .transparent)
                    .border(selected ? 1.0 : 0.0, faintColor)
                    .hover(hoverColor)
                    .role(.option)
                    .label(emojiStr)
                    .onClick { st in st.selected = index }
                    .child(
                        box()
                            .size(glyph, glyph)
                            .center()
                            .child(text(emojiStr).font(TextStyle(size: glyph * 0.78, weight: 400, lineHeight: glyph)).color(textColor))
                    )
            )
        }
        return line
    }

    private static func gridView(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        let cell = (size.x - 16.0) / Float(columns)
        var rowsContainer = vstack().key("rows").wFull().px(8).py(6).growth(.default)
        if s.lazyGrid {
            rowsContainer = rowsContainer.virtualRows(
                s.rowKeys.count,
                cell,
                key: { st, r in st.rowKeys[r] },
                build: { st, r in gridRow(st, r) }
            )
        } else {
            rowsContainer = rowsContainer.virtualize(cell)
                .children((0..<s.rowKeys.count).map { r in gridRow(s, r).key(s.rowKeys[r]) })
        }
        return vstack()
            .key("grid")
            .wFull()
            .grow(1)
            .shrink()
            .scroll(stickBottom: false)
            .clipFadeLinear(top: 12, bottom: 12)
            .child(rowsContainer)
    }

    public static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        let (body, prompt): (El<State>, String) = s.mode == .list
            ? (listView(s, &cx), "Search for apps and commands…")
            : (gridView(s, &cx), "Search emoji…")

        return col()
            .wFull()
            .hFull()
            .bg(bg)
            .child(
                row()
                    .key("search")
                    .wFull()
                    .h(56)
                    .px(16)
                    .gap(10)
                    .itemsCenter()
                    .child(el().size(18, 18).rounded(9).border(1.5, faintColor))
                    .child(text(prompt).font(TextStyle(size: 17, weight: 400)).color(faintColor))
            )
            .child(body)
            .child(
                row()
                    .key("footer")
                    .wFull()
                    .h(36)
                    .px(16)
                    .itemsCenter()
                    .gap(8)
                    .child(text("Open").font(TextStyle(size: 12, weight: 500)).color(faintColor).key("open"))
                    .child(text("Actions ⌘K").font(TextStyle(size: 12, weight: 500)).color(faintColor).key("actions"))
            )
    }

    public static func onKey(_ s: inout State, _ ev: KeyEvent, _ tx: inout Tx) -> Bool {
        switch ev.key {
        case .escape:
            s.mode = .list
            s.selected = 0
            return true
        case .tab:
            s.mode = .grid
            s.selected = 0
            return true
        case .arrowDown:
            s.selected += 1
            return true
        default:
            return false
        }
    }

    public static let metrics: [String] = [
        "cpu_ms", "frame_ms", "encode_ms", "view_ms", "commit_ms", "layout_ms", "text_ms", "paint_ms",
        "apply_ms", "shaped", "layout_nodes", "allocations", "tail_ms", "tail_frames",
        "rows_built", "rows_mounted", "rows_settled",
    ]

    public struct SampleResult: Sendable, Equatable {
        public let direction: String
        public let testCase: String
        public let cpuMs: Double
        public let frameMs: Double
        public let encodeMs: Double
        public let viewMs: Double
        public let commitMs: Double
        public let layoutMs: Double
        public let textMs: Double
        public let paintMs: Double
        public let applyMs: Double
        public let shaped: Int
        public let layoutNodes: Int
        public let allocations: Double
        public let tailMs: Double
        public let tailFrames: Int
        public let rowsBuilt: Int
        public let rowsMounted: Int
        public let rowsSettled: Int
    }

    private static func mountedCount(_ rt: Runtime<State>) -> Int {
        let listKey = (rt.state.mode == .list) ? "list" : "grid"
        let prefix = rt.state.mode == .list ? rt.state.keys : rt.state.rowKeys
        return prefix.filter { k in rt.find("\(listKey)/rows/\(k)") != nil }.count
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15
    }

    public static func runReport(
        samples: Int = 15,
        cells: Int = 1800,
        lazyGrid: Bool = false,
        eagerList: Bool = false,
        only: String? = nil
    ) throws -> (results: [SampleResult], output: String) {
        #if canImport(Metal)
        let renderer = try MetalRenderer()
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: Int(size.x * 2),
            height: Int(size.y * 2),
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        guard let targetTex = renderer.device.makeTexture(descriptor: desc) else {
            throw NSError(domain: "RuneTreeSwap", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate offscreen Metal texture"])
        }
        #endif

        @discardableResult
        func drawSubmit(_ rt: Runtime<State>, at now: Double) -> (rf: RenderFrame, wait: () -> Void) {
            let rf = rt.renderFrame(at: now)
            #if canImport(Metal)
            let cb = renderer.commandQueue.makeCommandBuffer()
            if let cb {
                renderer.drawRange(frame: rf, into: targetTex, commandBuffer: cb)
                cb.commit()
            }
            return (rf, { cb?.waitUntilCompleted() })
            #else
            return (rf, {})
            #endif
        }

        func drawAndWait(_ rt: Runtime<State>, at now: Double) {
            drawSubmit(rt, at: now).wait()
        }

        func settle(_ rt: Runtime<State>, now: inout Double) -> (cpu: Double, frames: Int) {
            let start = threadCpuMs()
            let dt = 1.0 / 120.0
            var frames = 0
            while frames < 240 {
                now += dt
                _ = rt.frame(at: now)
                frames += 1
                if !rt.isAnimating { break }
            }
            let cpu = max(0, threadCpuMs() - start)
            drawAndWait(rt, at: now)
            return (cpu, frames)
        }

        func runSample(direction: String, from: Mode, testCase: String) -> [Double] {
            let to: Mode = (from == .grid) ? .list : .grid
            let keyFor: (Mode) -> Key = { $0 == .list ? .escape : .tab }
            let ts = TextSystem()
            for st in [uiFont(), TextStyle(size: 28, weight: 400)] {
                _ = ts.shape(text: "Warm 😀 fonts", style: st, maxWidth: nil, pixelScale: 2.0, emitGlyphs: false)
            }
            let startMode = (testCase == "first") ? from : to
            let rt = Runtime(
                state: State(mode: startMode, lazyGrid: lazyGrid, eager: eagerList, cells: cells),
                viewport: size,
                pixelScale: 2.0,
                systemDark: true,
                textSystem: ts,
                onKey: onKey,
                view: view
            )
            var now = 0.0
            let dt = 1.0 / 120.0
            _ = rt.frame(at: now)
            _ = settle(rt, now: &now)

            if testCase == "quick" {
                rt.keyDown(KeyEvent(key: keyFor(from), mods: .none), at: now)
                now += dt
                _ = rt.frame(at: now)
                drawAndWait(rt, at: now)
            } else if testCase != "first" {
                rt.keyDown(KeyEvent(key: keyFor(from), mods: .none), at: now)
                _ = settle(rt, now: &now)
                if testCase == "stale" {
                    for _ in 0..<3 {
                        rt.keyDown(KeyEvent(key: .arrowDown, mods: .none), at: now)
                        _ = settle(rt, now: &now)
                    }
                }
            }

            _ = takeFramePhases()
            rt.state.counter.built = 0
            let entriesBefore = rt.textSystem.glyphAtlas.cachedEntryCount
            let alloc0 = ProcessCountingAllocator.shared.threadAllocations()
            let cpu0 = threadCpuMs()
            let t0 = ContinuousClock.now
            rt.keyDown(KeyEvent(key: keyFor(to), mods: .none), at: now)
            now += dt
            _ = rt.frame(at: now)
            let cpu = max(0, threadCpuMs() - cpu0)
            let frameMs = ms(t0.duration(to: .now))
            let allocations = Double(ProcessCountingAllocator.shared.threadAllocations() &- alloc0)
            let phases = takeFramePhases()

            let enc0 = ContinuousClock.now
            let sub = drawSubmit(rt, at: now)
            let encodeMs = ms(enc0.duration(to: .now))
            sub.wait()

            let shaped = Double(max(0, rt.textSystem.glyphAtlas.cachedEntryCount - entriesBefore))
            let layoutNodes = Double(rt.elements().count)
            let built = Double(rt.state.counter.built)
            let mountedNow = Double(mountedCount(rt))
            let (tailCpu, tailFrames) = settle(rt, now: &now)
            let settledCount = Double(mountedCount(rt))

            let p = FRAME_PHASES
            func phase(_ ph: FramePhase) -> Double {
                let idx = p + ph.rawValue
                return phases.count > idx ? phases[idx] : 0
            }
            return [
                cpu, frameMs, encodeMs,
                phase(.view), phase(.commit), phase(.layout), phase(.text), phase(.paint), phase(.apply),
                shaped, layoutNodes, allocations, tailCpu, Double(tailFrames),
                built, mountedNow, settledCount,
            ]
        }

        var results: [SampleResult] = []
        var lines: [String] = []
        for (dir, from) in [("grid-list", Mode.grid), ("list-grid", Mode.list)] {
            if let only, !dir.hasPrefix(only) && !only.contains("\(dir)/") { continue }
            for testCase in ["first", "quick", "recent", "stale"] {
                if let only, only.contains("/"), only != "\(dir)/\(testCase)" { continue }
                var batch: [[Double]] = []
                for s in 0...max(1, samples) {
                    let row = runSample(direction: dir, from: from, testCase: testCase)
                    if s > 0 { batch.append(row) }
                }
                func stat(_ idx: Int) -> (median: Double, p95: Double) {
                    let sorted = batch.map { $0[idx] }.sorted()
                    let med = sorted[sorted.count / 2]
                    let p95 = sorted[Int((Double(sorted.count - 1) * 0.95).rounded())]
                    return (med, p95)
                }
                for (m, name) in metrics.enumerated() {
                    let st = stat(m)
                    lines.append(String(format: "METRIC dir=%@ case=%@ metric=%@ median=%.4f p95=%.4f n=%d", dir, testCase, name, st.median, st.p95, batch.count))
                }
                results.append(SampleResult(
                    direction: dir,
                    testCase: testCase,
                    cpuMs: stat(0).median,
                    frameMs: stat(1).median,
                    encodeMs: stat(2).median,
                    viewMs: stat(3).median,
                    commitMs: stat(4).median,
                    layoutMs: stat(5).median,
                    textMs: stat(6).median,
                    paintMs: stat(7).median,
                    applyMs: stat(8).median,
                    shaped: Int(stat(9).median.rounded()),
                    layoutNodes: Int(stat(10).median.rounded()),
                    allocations: stat(11).median,
                    tailMs: stat(12).median,
                    tailFrames: Int(stat(13).median.rounded()),
                    rowsBuilt: Int(stat(14).median.rounded()),
                    rowsMounted: Int(stat(15).median.rounded()),
                    rowsSettled: Int(stat(16).median.rounded())
                ))
            }
        }
        return (results, lines.joined(separator: "\n"))
    }

    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        func strArg(_ flag: String) -> String? {
            if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] }
            return nil
        }
        func intArg(_ flag: String, default def: Int) -> Int {
            if let v = strArg(flag).flatMap(Int.init), v > 0 { return v }
            return def
        }
        let samples = intArg("--samples", default: 15)
        let only = strArg("--only")
        let lazyGrid = args.contains("--lazy-grid")
        let eagerList = args.contains("--eager-list")
        let cells = intArg("--cells", default: 1800)
        let (_, text) = try runReport(
            samples: samples,
            cells: cells,
            lazyGrid: lazyGrid,
            eagerList: eagerList,
            only: only
        )
        print(text)
    }
}
