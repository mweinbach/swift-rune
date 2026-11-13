import Foundation
import Rune
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
        let rowsContainer: El<State>
        if s.eager {
            var r: El<State> = vstack().key("rows").wFull().px(8).py(6)
            for i in 0..<s.titles.count {
                r = r.child(listRow(s, i).key(s.keys[i]))
            }
            rowsContainer = r
        } else {
            rowsContainer = virtualRows(
                key: "rows",
                state: s.listVirtual,
                count: s.titles.count,
                estimatedHeight: rowHeight,
                scrollY: cx.scrollOffset(of: "list").y,
                viewportHeight: max(1, cx.viewport.y - 92),
                rowKey: { s.keys[$0] },
                buildRow: { i in listRow(s, i) }
            )
            .wFull()
            .px(8)
            .py(6)
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
        let rowsContainer: El<State>
        if s.lazyGrid {
            rowsContainer = virtualRows(
                key: "rows",
                state: s.gridVirtual,
                count: s.rowKeys.count,
                estimatedHeight: cell,
                scrollY: cx.scrollOffset(of: "grid").y,
                viewportHeight: max(1, cx.viewport.y - 92),
                rowKey: { s.rowKeys[$0] },
                buildRow: { r in gridRow(s, r) }
            )
            .wFull()
            .px(8)
            .py(6)
        } else {
            var g: El<State> = vstack().key("rows").wFull().px(8).py(6)
            for r in 0..<s.rowKeys.count {
                g = g.child(gridRow(s, r).key(s.rowKeys[r]))
            }
            rowsContainer = g
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

    public struct SampleResult: Sendable, Equatable {
        public let direction: String
        public let testCase: String
        public let cpuMs: Double
        public let frameMs: Double
        public let encodeMs: Double
        public let tailFrames: Int
        public let rowsBuilt: Int
        public let rowsMounted: Int
        public let rowsSettled: Int
    }

    private static func mountedCount(_ rt: Runtime<State>) -> Int {
        let listKey = (rt.state.mode == .list) ? "list" : "grid"
        let prefix = rt.state.mode == .list ? rt.state.keys : rt.state.rowKeys
        let containerExists = rt.element(byKey: listKey) != nil
        guard containerExists else { return 0 }
        let matched = prefix.filter { k in rt.element(byKey: k) != nil }.count
        return matched > 0 ? matched : rt.elements().count
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15
    }

    public static func runReport(
        samples: Int = 15,
        cells: Int = 1800,
        lazyGrid: Bool = false,
        eagerList: Bool = false
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

        func drawAndWait(_ rt: Runtime<State>, at now: Double) {
            let rf = rt.renderFrame(at: now)
            #if canImport(Metal)
            if let cb = renderer.commandQueue.makeCommandBuffer() {
                renderer.drawRange(frame: rf, into: targetTex, commandBuffer: cb)
                cb.commit()
                cb.waitUntilCompleted()
            }
            #else
            _ = rf
            #endif
        }

        func settle(_ rt: Runtime<State>, now: inout Double) -> Int {
            let dt = 1.0 / 120.0
            var frames = 0
            while frames < 240 {
                now += dt
                _ = rt.frame(at: now)
                frames += 1
                if !rt.isAnimating { break }
            }
            drawAndWait(rt, at: now)
            return frames
        }

        func runSample(direction: String, from: Mode, testCase: String) -> SampleResult {
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
            let cpu0 = threadCpuMs()
            let t0 = ContinuousClock.now
            rt.keyDown(KeyEvent(key: keyFor(to), mods: .none), at: now)
            now += dt
            _ = rt.frame(at: now)
            let cpu = threadCpuMs() - cpu0
            let frameMs = ms(t0.duration(to: .now))
            let enc0 = ContinuousClock.now
            drawAndWait(rt, at: now)
            let encodeMs = ms(enc0.duration(to: .now))

            let built = rt.state.counter.built
            let mountedNow = mountedCount(rt)
            let tailFrames = settle(rt, now: &now)
            let settledCount = mountedCount(rt)

            return SampleResult(
                direction: direction,
                testCase: testCase,
                cpuMs: cpu,
                frameMs: frameMs,
                encodeMs: encodeMs,
                tailFrames: tailFrames,
                rowsBuilt: built,
                rowsMounted: mountedNow,
                rowsSettled: settledCount
            )
        }

        var results: [SampleResult] = []
        var lines: [String] = []
        for (dir, from) in [("grid-list", Mode.grid), ("list-grid", Mode.list)] {
            for testCase in ["first", "quick", "recent", "stale"] {
                var batch: [SampleResult] = []
                for _ in 0..<max(1, samples) {
                    batch.append(runSample(direction: dir, from: from, testCase: testCase))
                }
                let sortedCpu = batch.map(\.cpuMs).sorted()
                let sortedFrame = batch.map(\.frameMs).sorted()
                let sortedEncode = batch.map(\.encodeMs).sorted()
                let medCpu = sortedCpu[sortedCpu.count / 2]
                let medFrame = sortedFrame[sortedFrame.count / 2]
                let medEncode = sortedEncode[sortedEncode.count / 2]
                let last = batch[batch.count - 1]
                results.append(last)
                lines.append(String(format: "METRIC dir=%@ case=%@ cpu_ms=%.4f frame_ms=%.4f encode_ms=%.4f rows_built=%d rows_mounted=%d tail_frames=%d", dir, testCase, medCpu, medFrame, medEncode, last.rowsBuilt, last.rowsMounted, last.tailFrames))
            }
        }
        return (results, lines.joined(separator: "\n"))
    }

    public static func main() throws {
        let (_, text) = try runReport()
        print(text)
    }
}
