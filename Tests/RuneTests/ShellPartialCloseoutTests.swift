import Foundation
import Testing
@testable import Rune
@testable import RuneMotion
@testable import RuneRef

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int = 0

    func inc() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }

    var value: Int {
        lock.withLock { storage }
    }
}

private final class LogBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) {
        lock.withLock { items.append(item) }
    }

    var snapshot: [T] {
        lock.withLock { items }
    }
}

@Suite("Shell Partial Closeout Parity Tests", .serialized)
struct ShellPartialCloseoutTests {

    // MARK: - 1. Effects.drain() (machine.rs)

    @Test("Effects.drain returns emitted effects in FIFO order and clears queue")
    func effectsDrainParity() {
        enum Eff: Equatable {
            case ping(Int)
            case stop
        }

        var effects = Effects<Eff>()
        #expect(effects.drain().isEmpty)

        effects.push(.ping(1))
        effects.push(.ping(2))
        effects.push(.stop)

        #expect(effects.drain() == [.ping(1), .ping(2), .stop])
        #expect(effects.drain().isEmpty)

        effects.push(.ping(9))
        #expect(effects.drain() == [.ping(9)])
        #expect(effects.drain().isEmpty)
    }

    // MARK: - 2. measure_scope.rs (3/3): concurrent font-family scopes, nested restore, epoch cache invalidation

    @Test("withFontFamilies isolates concurrent threads, restores across throws, and bumps MeasureKey epoch")
    func measureScopeParity() throws {
        let baseEpoch = fontEpoch()
        struct Boom: Error {}

        // 1. Nested scope + throwing unwind restores exact outer scope and epoch
        var innerMono = ""
        var midSans = ""
        do {
            try withFontFamilies(sans: "RuneOuterSans", mono: "RuneOuterMono") {
                #expect(fontEpoch() != baseEpoch)
                do {
                    try withFontFamilies(sans: "RuneInnerSans", mono: "RuneInnerMono") {
                        let current = FontFamiliesRegistry.currentFamilies()
                        innerMono = current.mono
                        throw Boom()
                    }
                } catch is Boom {
                    midSans = FontFamiliesRegistry.currentFamilies().sans
                }
            }
        } catch {
            Issue.record("Unexpected outer error: \(error)")
        }
        #expect(innerMono == "RuneInnerMono")
        #expect(midSans == "RuneOuterSans")

        // Clean nested restore verification
        let beforeNested = FontFamiliesRegistry.currentFamilies()
        try withFontFamilies(sans: "OuterS", mono: "OuterM") {
            let outerSnap = FontFamiliesRegistry.currentFamilies()
            #expect(outerSnap.sans == "OuterS" && outerSnap.mono == "OuterM")
            do {
                try withFontFamilies(sans: "InnerS", mono: "InnerM") {
                    #expect(FontFamiliesRegistry.currentFamilies().sans == "InnerS")
                    throw Boom()
                }
            } catch is Boom {}
            #expect(FontFamiliesRegistry.currentFamilies().sans == "OuterS")
            #expect(FontFamiliesRegistry.currentFamilies().mono == "OuterM")
        }
        #expect(FontFamiliesRegistry.currentFamilies().sans == beforeNested.sans)
        #expect(FontFamiliesRegistry.currentFamilies().mono == beforeNested.mono)

        // 2. Concurrent threads running distinct withFontFamilies never overwrite each other
        let group = DispatchGroup()
        let mismatches = CounterBox()
        for t in 0..<4 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let expectedSans = "ConcurrentSans-\(t)"
                let expectedMono = "ConcurrentMono-\(t)"
                for _ in 0..<50 {
                    withFontFamilies(sans: expectedSans, mono: expectedMono) {
                        let cur = FontFamiliesRegistry.currentFamilies()
                        if cur.sans != expectedSans || cur.mono != expectedMono {
                            _ = mismatches.inc()
                        }
                        let m = TextMeasure.measure("Hello Rune", style: TextStyle(size: 14))
                        if !(m.x > 0 && m.y > 0) {
                            _ = mismatches.inc()
                        }
                    }
                }
                group.leave()
            }
        }
        group.wait()
        #expect(mismatches.value == 0)

        // 3. Font epoch bumps on family switch and cleanly invalidates TextSystem / TextMeasure cache
        let textSystem = TextSystem()
        let style = TextStyle(size: 16)
        var narrowWidth: Float = 0
        var courierWidth: Float = 0
        withFontFamilies(sans: "Helvetica", mono: "Menlo") {
            let s1 = textSystem.shape(text: "iiiiiiiiii", style: style, maxWidth: nil, pixelScale: 2.0)
            let m1 = TextMeasure.measure("iiiiiiiiii", style: style)
            narrowWidth = m1.x
            #expect(s1.size.x > 0)
        }
        withFontFamilies(sans: "Courier", mono: "Courier") {
            let epochInside = fontEpoch()
            #expect(epochInside != baseEpoch)
            let s2 = textSystem.shape(text: "iiiiiiiiii", style: style, maxWidth: nil, pixelScale: 2.0)
            let m2 = TextMeasure.measure("iiiiiiiiii", style: style)
            courierWidth = m2.x
            #expect(s2.size.x > 0)
            #expect(courierWidth != narrowWidth, "epoch switch must invalidate cached width for identical text+style")
        }
    }

    // MARK: - 3. MemoBuildScope scrollerOverlay & offscreen focused TextEdit in virtual/memo row

    @Test("MemoBuildScope.environmentHash tracks scrollerOverlay and offscreen focused virtual memo TextEdit keeps focus and typing")
    func scrollerOverlayEnvHashAndOffscreenFocusedMemoTyping() {
        // 1. environmentHash parity for scrollerOverlay
        let hOverlay = MemoScope.environmentHash(
            systemDark: true,
            pixelScale: 2.0,
            reducedMotion: false,
            srgbBlend: true,
            scrollerOverlay: true
        )
        let hClassic = MemoScope.environmentHash(
            systemDark: true,
            pixelScale: 2.0,
            reducedMotion: false,
            srgbBlend: true,
            scrollerOverlay: false
        )
        #expect(hOverlay != hClassic)

        // Live runtime invalidates memo when systemScrollerOverlay changes
        var memoBuilds = 0
        let sbRt = Runtime<Bool>(
            state: true,
            viewport: Vec2(300, 200),
            pixelScale: 1.0
        ) { overlay, cx in
            el().size(300, 200).child(
                memo("sb-memo", overlay) {
                    memoBuilds += 1
                    return text("overlay:\(cx.overlayScrollBars())").key("sb-text")
                }
            )
        }
        sbRt.setSystemScrollBars(.automatic)
        sbRt.setSystemScrollerOverlay(true)
        _ = sbRt.frame(at: 0.0)
        let b1 = memoBuilds
        _ = sbRt.frame(at: 0.01)
        #expect(memoBuilds == b1)
        sbRt.setSystemScrollerOverlay(false)
        _ = sbRt.frame(at: 0.02)
        #expect(memoBuilds > b1)
        #expect(sbRt.element(byKey: "sb-text")?.text == "overlay:false")

        // 2. a_focused_field_in_an_offscreen_memo_row_keeps_focus_and_typing
        struct ListState {
            var edits: [TextEdit] = (0..<60).map { TextEdit("row-\($0):") }
        }
        let rt = Runtime<ListState>(
            state: ListState(),
            viewport: Vec2(320, 180),
            pixelScale: 1.0
        ) { _, _ in
            col().key("scroller").size(320, 180).scroll()
                .virtualRows(60, 40, key: { _, i in "row-\(i)" }) { s, i in
                    let edit = s.edits[i]
                    return memo("memo-row-\(i)", edit.text) {
                        el().key("wrap-\(i)").size(300, 40)
                            .child(
                                textInput(key: "input-\(i)", \ListState.edits[i])
                                    .size(280, 32)
                            )
                    }
                }
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.element(byKey: "input-0") != nil)

        // Focus row 0 input at its right end so caret lands at the end of "row-0:"
        rt.pointerDown(at: Vec2(200, 16), at: 0.01)
        rt.pointerUp(at: Vec2(200, 16), at: 0.02)
        _ = rt.frame(at: 0.03)
        #expect(rt.focusedKey == "input-0")

        // Scroll far down (negative dy scrolls down) so row-0 is completely offscreen (virtual row unmounted)
        for step in 1...20 {
            rt.wheel(WheelEvent(dx: 0, dy: -120), at: Vec2(100, 90), now: 0.04 + Double(step) * 0.01)
            _ = rt.frame(at: 0.04 + Double(step) * 0.01)
        }
        #expect(rt.element(byKey: "input-0") == nil, "row-0 must be offscreen/unmounted")
        #expect(rt.focusedKey == "input-0", "offscreen focused field keeps logical focus")

        // Type & paste while row-0 is offscreen
        let typedA = rt.keyDown(KeyEvent(key: .text("a")), at: 0.30)
        let typedB = rt.keyDown(KeyEvent(key: .text("b")), at: 0.31)
        let pastedCD = rt.deliverPaste(ClipboardContent("CD"), at: 0.32)
        #expect(typedA)
        #expect(typedB)
        #expect(pastedCD)
        _ = rt.frame(at: 0.33)
        #expect(rt.state.edits[0].text == "row-0:abCD")
        #expect(rt.focusedKey == "input-0")

        // Scroll back to top (positive dy scrolls up): row-0 remounts with typed+pasted text and keeps focus
        for step in 1...25 {
            rt.wheel(WheelEvent(dx: 0, dy: 120), at: Vec2(100, 90), now: 0.40 + Double(step) * 0.01)
            _ = rt.frame(at: 0.40 + Double(step) * 0.01)
        }
        #expect(rt.element(byKey: "input-0") != nil)
        #expect(rt.focusedKey == "input-0")
        #expect(rt.state.edits[0].text == "row-0:abCD")
    }

    // MARK: - 4. prefs.rs (6/6), dirs.rs (3/3), taskbar.rs badge, jump_list.rs

    @Test("Prefs, AppDirs, TaskbarState, and JumpList full closeout parity")
    func prefsDirsTaskbarAndJumpListParity() throws {
        // dirs.rs (3/3)
        let explicit = AppDirs.fromEnv(appId: "com.rune/test:app") { key in
            key == "RUNE_DIRS_ROOT" ? "/tmp/rune-dirs-root" : nil
        }
        #expect(explicit != nil)
        #expect(explicit?.home == nil, "no HOME in lookup -> home must be nil")
        #expect(explicit?.data.path.contains("/tmp/rune-dirs-root") == true)
        #expect(explicit?.config.path.contains("/tmp/rune-dirs-root") == true)
        #expect(explicit?.cache.path.contains("/tmp/rune-dirs-root") == true)
        let sib = explicit?.sibling("other.app")
        #expect(sib?.data.lastPathComponent != explicit?.data.lastPathComponent)

        let noHomeOrRoot = AppDirs.fromEnv(appId: "demo") { _ in nil }
        #expect(noHomeOrRoot == nil)

        // prefs.rs (6/6)
        #expect(Prefs.configDir { _ in nil } == nil)
        let mem = Prefs.open(appId: "no-home-app", environment: [:])
        #expect(!mem.isPersistent)
        try mem.set("count", value: 7)
        #expect(mem.get("count", as: Int.self) == 7)

        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory.appendingPathComponent("rune-prefs-closeout-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmpRoot) }

        let env = ["RUNE_PREFS_DIR": tmpRoot.path]
        let rootedEnv = ["RUNE_DIRS_ROOT": tmpRoot.appendingPathComponent("rooted").path]
        let rootedPrefs = Prefs.open(appId: "rooted-app", environment: rootedEnv)
        #expect(rootedPrefs.isPersistent)
        #expect(rootedPrefs.path?.path == tmpRoot.appendingPathComponent("rooted/config/rooted-app/prefs.json").path)
        try rootedPrefs.set("theme", value: "dark")
        #expect(Prefs.open(appId: "rooted-app", environment: rootedEnv).get("theme", as: String.self) == "dark")

        let p = Prefs.open(appId: "../bad/app:name", environment: env)
        #expect(p.isPersistent)
        #expect(p.path?.lastPathComponent.contains("..") == false)
        try p.set("greeting", value: "hello")
        try p.set("flag", value: true)
        #expect(p.contains("greeting"))
        #expect(Set(p.keys) == Set(["greeting", "flag"]))

        let reloaded = Prefs.open(appId: "../bad/app:name", environment: env)
        #expect(reloaded.get("greeting", as: String.self) == "hello")
        #expect(reloaded.get("flag", as: Bool.self) == true)
        try reloaded.remove("flag")
        #expect(!reloaded.contains("flag"))

        // Corrupt JSON recovers by quarantining to .bad
        if let prefsFile = p.path {
            try Data("{not valid json".utf8).write(to: prefsFile)
            let recovered = Prefs.open(appId: "../bad/app:name", environment: env)
            #expect(recovered.get("greeting", as: String.self) == nil)
            let badFile = prefsFile.appendingPathExtension("bad")
            #expect(fm.fileExists(atPath: badFile.path))
        }

        // Concurrent writers with atomic POSIX rename never corrupt JSON on disk
        let concGroup = DispatchGroup()
        let errCount = CounterBox()
        for w in 0..<4 {
            concGroup.enter()
            DispatchQueue.global().async {
                let writer = Prefs.open(appId: "concurrent-app", environment: env)
                for i in 0..<25 {
                    do {
                        try writer.set("k-\(w)", value: i)
                    } catch {
                        _ = errCount.inc()
                    }
                }
                concGroup.leave()
            }
        }
        concGroup.wait()
        #expect(errCount.value == 0)
        let afterConc = Prefs.open(appId: "concurrent-app", environment: env)
        #expect(afterConc.isPersistent)
        #expect(!afterConc.keys.isEmpty)
        if let path = afterConc.path {
            #expect(!fm.fileExists(atPath: path.appendingPathExtension("bad").path))
        }
        var values: [Int] = []
        for key in afterConc.keys {
            let val = afterConc.get(key, as: Int.self)
            #expect(val.map { (0..<25).contains($0) } == true)
            if let val { values.append(val) }
        }
        #expect(values.contains(24))

        // taskbar.rs badge
        let emptyBadge = TaskbarState().badge(3, "3 unread").badge(0, "should clear")
        #expect(emptyBadge.count == 0)
        #expect(emptyBadge.badgeDescription.isEmpty)
        let overNine = TaskbarState().badge(14, "14 unread").progress(.busy)
        #expect(overNine.count == 14)
        #expect(overNine.badgeDescription == "14 unread")
        #expect(overNine.shownProgress == .busy)

        // jump_list.rs
        JumpListStore.resetForTests()
        defer { JumpListStore.resetForTests() }
        let jl = JumpList()
            .task(JumpItem(title: "New Window", argument: "--new-window", description: "Opens a window"))
            .category("Recent", items: [JumpItem(title: "Notes", argument: "notes.md")])
            .lead("--open")
        #expect(jl.tasks.count == 1)
        #expect(jl.categories.count == 1)
        #expect(jl.lead == "--open")
        setJumpList(jl)
        #expect(JumpListStore.committedListForTests() == jl)
        JumpListStore.setHeadlessForTests(true)
        let jl2 = JumpList().lead("--other")
        setJumpList(jl2)
        #expect(JumpListStore.committedListForTests() == jl, "headless mode suppresses updates")
    }

    // MARK: - 5. RewindTape quantization, unattached RewindRecorder, maxBytes eviction

    @Test("RewindTape quantize round-trips, enforces maxBytes eviction, and unattached RewindRecorder freezes RewindClip")
    func rewindTapeAndRecorderParity() {
        // Quantize / dequantize round-trip
        let rect = MotionRect.fromXYWH(12.25, 44.5, 180.75, 64.25)
        let q = RewindTape.quantize(rect: rect, opacity: 0.75)
        let dq = RewindTape.dequantize(q)
        #expect(abs(dq.rect.left - rect.left) < 0.2)
        #expect(abs(dq.rect.top - rect.top) < 0.2)
        #expect(abs(dq.rect.right - rect.right) < 0.2)
        #expect(abs(dq.rect.bottom - rect.bottom) < 0.2)
        #expect(abs(dq.opacity - 0.75) < 0.01)

        // Unattached RewindRecorder records snapshots and freezes a valid RewindClip
        let rec = RewindRecorder().seconds(10.0).maxBytes(1024 * 64)
        rec.setViewport(Vec2(640, 480))
        rec.recordFrame(at: 0.0, elements: [
            RewindElementSnapshot(key: "panel", rect: rect, opacity: 1.0),
        ])
        rec.recordFrame(at: 0.5, elements: [
            RewindElementSnapshot(key: "panel", rect: MotionRect.fromXYWH(30, 50, 180, 64), opacity: 0.5),
        ])
        #expect(rec.frameCount == 2)
        #expect(rec.estimatedBytes > 0)
        let clip = rec.freeze()
        #expect(clip.len == 2)
        #expect(clip.viewport == Vec2(640, 480))
        #expect(clip.names.contains("panel"))
        #expect(abs(clip.duration - 0.5) < 1e-6)
        #expect(abs(clip.frames[1].elements[0].rect.left - 30.0) < 0.2)

        // maxBytes budget evicts oldest frames while retaining newest without 1024 floor
        let tight = RewindRecorder().seconds(120.0).maxBytes(250)
        #expect(tight.maxBytes == 250)
        for i in 0..<20 {
            tight.recordFrame(at: Double(i) * 0.1, elements: [
                RewindElementSnapshot(key: "item", rect: MotionRect.fromXYWH(Float(i * 4), 10, 40, 20), opacity: 1.0),
            ])
        }
        #expect(tight.frameCount > 1 && tight.frameCount < 20)
        #expect(tight.estimatedBytes <= 250)
    }

    // MARK: - 6. FrameReports (6/6) & HeadlessRunner multi-frame Compositor.render

    @Test("FrameReports inspects callbacks/refresh/wanted and HeadlessRunner drives multi-frame Compositor")
    func frameReportsAndMultiFrameCompositorParity() throws {
        // FrameReports (encoded_tests.rs 6/6)
        let emptyReports = FrameReports<Int>()
        #expect(emptyReports.wanted == false)
        #expect(emptyReports.stamp() == nil)

        var encodedCount = 0
        var inspectedTicks: [Int] = []
        let reports = FrameReports<Int>(onFrameEncoded: { _ in
            encodedCount += 1
        }).inspecting { rt in
            inspectedTicks.append(rt.state)
        }
        #expect(reports.wanted == true)
        #expect(reports.stamp() != nil)

        reports.setRefresh(120.0)
        let stampT = reports.stamp()
        reports.drawn(at: stampT, presentsAt: (stampT ?? 0) + 1.0 / 120.0, started: (stampT ?? 0) - 0.001, updateMs: 0.5)
        reports.unchanged(presentsAt: (stampT ?? 0) + 2.0 / 120.0)
        reports.skipped()
        #expect(encodedCount == 3)

        let sampleRt = Runtime<Int>(state: 42, viewport: Vec2(100, 100), pixelScale: 1.0) { s, _ in
            text("\(s)")
        }
        reports.inspect(sampleRt)
        #expect(inspectedTicks == [42])

        // HeadlessRunner multi-frame Compositor.render & onFrameDrawn
        final class CountingCompositor: Compositor {
            typealias State = Int
            var renderCount = 0
            func render(frame: CompositorFrame<Int>) {
                renderCount += 1
                frame.drawUI()
            }
        }

        let comp = CountingCompositor()
        var drawnFrames = 0
        let app = App<Int>(title: "MultiFrame", size: Vec2(120, 80), state: 1) { s, _ in
            el().size(120, 80).bg(.black).child(text("frame-\(s)"))
        }
        .compositor(comp)
        .onFrameDrawn { _ in
            drawnFrames += 1
        }

        var args = ToolingArgs()
        args.frameCount = 4
        args.fps = 60.0
        _ = try HeadlessRunner.run(app, args: args)
        #expect(comp.renderCount >= 4)
        #expect(drawnFrames >= 4)
    }

    // MARK: - 7. Remaining 5/10 launch.rs parity scenarios

    @Test("launch.rs remaining 5 scenarios: other commit, reorder, reaim under scroll, gap at pinned end, and judged against scroll")
    func launchRemainingFiveParity() {
        struct LaunchState {
            var draft = TextEdit("third")
            var sent: [String] = ["first", "second"]
            var ticks: Int = 0
            var swap: Bool = false
            var intoBody: Bool = false
            var tail: Bool = false
            var gap: Bool = false
            var zoom: Float = 1.0
        }

        func makeLaunchRt(zoom: Float = 1.0, intoBody: Bool = false, earlierCount: Int = 0) -> Runtime<LaunchState> {
            var st = LaunchState(intoBody: intoBody, zoom: zoom)
            for k in (0..<earlierCount).reversed() {
                st.sent.insert("earlier \(k)", at: 0)
            }
            let rt = Runtime<LaunchState>(
                state: st,
                viewport: Vec2(400, 300),
                pixelScale: 2.0,
                systemDark: true
            ) { s, _ in
                var rows: El<LaunchState> = col().wFull().growth(GrowthSpec())
                var order = Array(0..<s.sent.count)
                if s.swap && order.count > 1 {
                    order.swapAt(order.count - 2, order.count - 1)
                }
                for i in order {
                    let m = s.sent[i]
                    var row: El<LaunchState> = col().key("msg-\(i)").wFull().py(8).itemsEnd()
                        .child(text(m).key("body"))
                    if s.gap && i + 1 == s.sent.count {
                        row = row.pt(20)
                    }
                    rows = rows.child(row)
                }
                rows = rows.child(text(s.tail ? "\(s.ticks)\nand\nthe\nrest" : "\(s.ticks)").key("ticks"))
                let page = col().wFull().hFull()
                    .child(col().key("scroll").wFull().grow(1).shrink().scroll(ScrollSpec(stickBottom: true)).child(rows))
                    .child(
                        textInput(key: "composer", \LaunchState.draft)
                            .wFull()
                            .h(60)
                            .onSubmit { st, _, tx in
                                let last = st.sent.count
                                st.sent.append(st.draft.text)
                                st.draft.clear()
                                tx.launch("composer", to: st.intoBody ? "msg-\(last)/body" : "msg-\(last)")
                            }
                    )
                if s.zoom == 1.0 { return page }
                return col().wFull().hFull().center()
                    .child(col().w(400.0 / s.zoom).h(300.0 / s.zoom).scale(s.zoom).child(page))
            }
            _ = rt.frame(at: 0.0)
            if let comp = rt.element(byKey: "composer") {
                let p = Vec2(comp.rect[0] + 10, comp.rect[1] + 10)
                rt.pointerDown(at: p, at: 0.001)
                rt.pointerUp(at: p, at: 0.002)
                _ = rt.frame(at: 0.003)
            }
            return rt
        }

        func bodyInfo(_ rt: Runtime<LaunchState>) -> ElementInfo {
            rt.elements().first(where: { $0.key == "body" && $0.text == "third" })!
        }

        // 1. a_launch_after_another_commit_in_its_frame_still_leaves_from_the_source
        do {
            let zoom: Float = 1.6
            let rt = makeLaunchRt(zoom: zoom)
            let composer = rt.element(byKey: "composer")!.rect
            rt.update(at: 0.004) { s, _ in s.ticks += 1 }
            _ = rt.keyDown(KeyEvent(key: .enter), at: 1.0 / 120.0)
            let frames = (1...120).map { f -> [Float] in
                _ = rt.frame(at: Double(f) / 120.0)
                return bodyInfo(rt).rect
            }
            let first = frames[0]
            #expect(abs(first[0] - composer[0]) < 6.0 * zoom)
            #expect(first[1] >= composer[1] - 3.0 && first[1] + first[3] <= composer[1] + composer[3] + 3.0)
            for axis in 0..<2 {
                let at = frames.map { $0[axis] }
                let total = at.last! - at.first!
                let dir: Float = total >= 0 ? 1 : -1
                for k in 1..<at.count {
                    #expect((at[k] - at[k - 1]) * dir >= -0.05)
                }
            }
        }

        // 2. a_launch_whose_row_reorders_mid_flight_slides_and_lands_without_a_lurch
        for intoBody in [false, true] {
            let rt = makeLaunchRt(intoBody: intoBody)
            let t0 = 1.0 / 120.0
            _ = rt.keyDown(KeyEvent(key: .enter), at: t0)
            _ = rt.frame(at: t0)
            let frames = (1...180).map { f -> ([Float], [Float]) in
                let t = t0 + Double(f) / 120.0
                if f == 16 {
                    rt.update(at: t) { s, _ in s.swap = true }
                }
                _ = rt.frame(at: t)
                let b = bodyInfo(rt)
                return (b.rect, b.target)
            }
            #expect(abs(frames.last!.0[0] - frames.last!.1[0]) < 0.05)
            #expect(abs(frames.last!.0[1] - frames.last!.1[1]) < 0.05)
            for axis in 0..<2 {
                let at = frames.map { $0.0[axis] }
                let steps = zip(at, at.dropFirst()).map { $1 - $0 }
                for k in 1..<steps.count {
                    #expect(abs(steps[k] - steps[k - 1]) <= 4.0)
                }
            }
        }

        // 3. a_launch_reaimed_while_the_scroll_view_corrects_under_it_keeps_its_speed
        for (atFrame, intoBody) in [(6, false), (12, false), (8, true)] {
            let rt = makeLaunchRt(intoBody: intoBody, earlierCount: 12)
            for f in 1...60 { _ = rt.frame(at: Double(f) / 120.0) }
            _ = rt.keyDown(KeyEvent(key: .enter), at: 61.0 / 120.0)
            let bodyRects = (0..<40).map { f -> [Float] in
                let t = Double(62 + f) / 120.0
                if f == 1 { rt.update(at: t) { s, _ in s.tail = true } }
                if f == atFrame { rt.update(at: t) { s, _ in s.swap = true } }
                _ = rt.frame(at: t)
                return bodyInfo(rt).rect
            }
            for axis in 0..<2 {
                let steps = zip(bodyRects, bodyRects.dropFirst()).map { $1[axis] - $0[axis] }
                let change = zip(steps, steps.dropFirst()).map { $1 - $0 }
                let (before, reaim, after) = (change[atFrame - 3], change[atFrame - 2], change[atFrame - 1])
                #expect(reaim >= min(before, after) - 0.15 && reaim <= max(before, after) + 0.15)
            }
        }

        // 4. a_landed_launch_whose_row_grows_a_gap_over_it_at_a_pinned_end_holds_still
        for (atFrame, intoBody) in [(80, false), (160, true)] {
            let rt = makeLaunchRt(intoBody: intoBody, earlierCount: 12)
            for f in 1...60 { _ = rt.frame(at: Double(f) / 120.0) }
            _ = rt.keyDown(KeyEvent(key: .enter), at: 61.0 / 120.0)
            for f in 1...atFrame { _ = rt.frame(at: Double(61 + f) / 120.0) }
            let y0 = bodyInfo(rt).rect[1]
            let row0 = rt.element(byKey: "msg-14")!.rect[1]
            let tGap = Double(62 + atFrame) / 120.0
            rt.update(at: tGap) { s, _ in s.gap = true }
            let ys = (1...120).map { f -> Float in
                _ = rt.frame(at: tGap + Double(f) / 120.0)
                return bodyInfo(rt).rect[1]
            }
            #expect(ys.allSatisfy { abs($0 - y0) <= 0.1 })
            #expect(abs(rt.element(byKey: "msg-14")!.rect[1] - (row0 - 12.0)) < 0.05)
        }

        // 5. a_launch_is_judged_against_the_scroll_it_rides
        for reaim in [nil, 8] as [Int?] {
            let rt = makeLaunchRt(earlierCount: 12)
            for f in 1...60 { _ = rt.frame(at: Double(f) / 120.0) }
            _ = rt.keyDown(KeyEvent(key: .enter), at: 61.0 / 120.0)
            let ys = (0..<120).map { f -> Float in
                let t = Double(62 + f) / 120.0
                if f == 1 { rt.update(at: t) { s, _ in s.tail = true } }
                if reaim == f { rt.update(at: t) { s, _ in s.swap = true } }
                _ = rt.frame(at: t)
                let b = bodyInfo(rt)
                let sy = b.scrolled.count >= 2 ? b.scrolled[1] : 0
                return b.rect[1] + sy
            }
            let steps = zip(ys, ys.dropFirst()).map { $1 - $0 }
            #expect(steps.allSatisfy { $0 <= 0.05 })
            #expect(zip(steps, steps.dropFirst()).allSatisfy { abs($1 - $0) < 3.0 })
            #expect(ys.first! - ys.last! > 4.0)
            let landed = bodyInfo(rt)
            #expect((landed.scrolled.count >= 2 ? landed.scrolled[1] : 0) > 0.0)
        }
    }

    // MARK: - 8. live.rs remaining & tests/live_only.rs & Runtime.pollHidden

    @Test("Live Runtime wake/visibility/Pixels, liveOnly zero-commit drag/pointerMove/follow, checkLiveOnly warnings, and pollHidden")
    func liveRuntimeAndLiveOnlyParity() {
        // 1. Live waker + visibility + Pixels.set waking runtime with zero view commits
        let px = Pixels()
        px.set(width: 2, height: 2, rgba: [UInt8](repeating: 255, count: 16))
        let wakes = CounterBox()
        let sharedVal = Live<Float>(1.0)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ in
            el().size(200, 120)
                .child(el().key("box").size(40, 20).bg(.white).liveOpacity(sharedVal.binding))
                .child(el().key("pix").size(16, 16).pixels(px))
        }
        rt.setLiveWaker(Waker { _ = wakes.inc() })
        _ = rt.frame(at: 0.0)
        let commitsAtStart = rt.viewCommitCount

        // Changing live value wakes runtime and sets livePending
        #expect(sharedVal.set(0.5))
        #expect(wakes.value == 1)
        #expect(rt.livePending)
        _ = rt.frame(at: 0.01)
        #expect(!rt.livePending)
        #expect(rt.viewCommitCount == commitsAtStart)

        // Updating Pixels triggers live wakeup too and coalesces while hidden
        px.set(width: 2, height: 2, rgba: [UInt8](repeating: 128, count: 16))
        #expect(wakes.value == 2)
        #expect(rt.livePending)
        _ = rt.frame(at: 0.02)
        #expect(!rt.livePending)

        rt.setLiveVisible(false)
        #expect(sharedVal.set(0.25))
        #expect(wakes.value == 2, "hidden runtime suppresses wake until visible")
        rt.setLiveVisible(true)
        #expect(wakes.value == 3, "becoming visible flushes pending wake")
        _ = rt.frame(at: 0.03)
        #expect(rt.viewCommitCount == commitsAtStart)

        // 2. liveOnly pointerMove triggers zero commits (when no non-liveOnly onHover hits), while normal pointerMove or hover commits
        let moveOffset = Live<Vec2>(.zero)
        let rtMove = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            el().size(200, 200).child(
                el().key("target").size(100, 100).liveOffset(moveOffset.binding)
                    .onPointerMove { _, ev, tx in
                        tx.liveOnly()
                        moveOffset.set(Vec2(ev.window.x, ev.window.y))
                    }
            )
        }
        rtMove.checkLiveOnly(false)
        _ = rtMove.frame(at: 0.0)
        let moveStartCommits = rtMove.viewCommitCount
        for step in 1...40 {
            let t = Double(step) / 120.0
            rtMove.pointerMove(to: Vec2(10 + Float(step), 15), at: t)
            _ = rtMove.frame(at: t)
        }
        #expect(rtMove.viewCommitCount == moveStartCommits, "liveOnly pointerMove must not commit")
        #expect(abs(moveOffset.get().x - 50) < 0.01)

        // Same handler WITH an onHover still commits on enter/leave
        var hoverCalls = 0
        let rtHover = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            el().size(200, 200).child(
                el().key("target").size(100, 100)
                    .onHover { _, _, _ in hoverCalls += 1 }
                    .onPointerMove { _, _, tx in tx.liveOnly() }
            )
        }
        rtHover.checkLiveOnly(false)
        _ = rtHover.frame(at: 0.0)
        let hoverStartCommits = rtHover.viewCommitCount
        rtHover.pointerMove(to: Vec2(20, 20), at: 0.01)
        _ = rtHover.frame(at: 0.01)
        #expect(hoverCalls == 1)
        #expect(rtHover.viewCommitCount > hoverStartCommits)

        // 3. follow onLayoutTx across scrolled list: with tx.liveOnly() -> 0 commits; without -> >= 30 commits
        let followOffset = Live<Vec2>(.zero)
        let rtFollowLiveOnly = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            el().size(200, 200).child(
                col().key("follow-scroll").size(200, 200).scroll().child(
                    el().size(200, 1000).child(
                        el().key("leader").size(40, 40).liveOffset(followOffset.binding)
                            .onLayoutTx { _, rect, tx in
                                tx.liveOnly()
                                followOffset.set(Vec2(0, rect[1]))
                            }
                    )
                )
            )
        }
        rtFollowLiveOnly.checkLiveOnly(false)
        _ = rtFollowLiveOnly.frame(at: 0.0)
        let followCommits0 = rtFollowLiveOnly.viewCommitCount
        for f in 1...35 {
            let t = Double(f) / 60.0
            rtFollowLiveOnly.wheel(WheelEvent(dx: 0, dy: -4), at: Vec2(50, 50), now: t)
            _ = rtFollowLiveOnly.frame(at: t)
        }
        #expect(rtFollowLiveOnly.viewCommitCount == followCommits0)

        var layoutCallbacks = 0
        let rtFollowCommit = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            el().size(200, 200).child(
                col().key("follow-scroll").size(200, 200).scroll().child(
                    el().size(200, 1000).child(
                        el().key("leader").size(40, 40)
                            .onLayoutTx { st, _, _ in
                                layoutCallbacks += 1
                                st += 1
                            }
                    )
                )
            )
        }
        _ = rtFollowCommit.frame(at: 0.0)
        for f in 1...35 {
            let t = Double(f) / 60.0
            rtFollowCommit.wheel(WheelEvent(dx: 0, dy: -4), at: Vec2(50, 50), now: t)
            _ = rtFollowCommit.frame(at: t)
        }
        #expect(layoutCallbacks >= 30)
        #expect(rtFollowCommit.viewCommitCount >= 30)

        // 4. checkLiveOnly(true) warns when high-frequency liveOnly path actually mutates state (forces commit)
        let rtWarn = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            el().size(200, 200).child(
                el().key("warn-box-\(s % 2)").size(120, 120)
                    .onPointerMove { st, _, tx in
                        tx.liveOnly()
                        st += 1
                    }
            )
        }
        rtWarn.checkLiveOnly(true)
        _ = rtWarn.frame(at: 0.0)
        for f in 1...35 {
            let t = Double(f) * 0.02 // 0.70s total > 0.25s debug spot-check window
            rtWarn.pointerMove(to: Vec2(20 + Float(f % 10), 20), at: t)
            _ = rtWarn.frame(at: t)
        }
        #expect(rtWarn.liveOnlyEvents > 0)
        #expect(!rtWarn.liveOnlyWarnings.isEmpty)

        // 5. Runtime.pollHidden(at:) runs poll hook while hidden without building frames
        var hiddenPolls = 0
        var pollResult = false
        let rtHidden = Runtime<Int>(state: 0, viewport: Vec2(100, 100), pixelScale: 1.0) { s, _ in
            el().size(100, 100).child(text("\(s)"))
        }
        _ = rtHidden.frame(at: 0.0)
        rtHidden.poll = { st, _, _ in
            hiddenPolls += 1
            st += 1
            return pollResult
        }
        let commitsBeforeHidden = rtHidden.viewCommitCount
        #expect(rtHidden.pollHidden(at: 0.1) == false)
        pollResult = true
        #expect(rtHidden.pollHidden(at: 0.2) == true)
        #expect(hiddenPolls == 2)
        #expect(rtHidden.state == 2)
        #expect(rtHidden.viewCommitCount == commitsBeforeHidden)
    }
}
