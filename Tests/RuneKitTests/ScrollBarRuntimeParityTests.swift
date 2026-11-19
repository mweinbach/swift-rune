import Foundation
import Testing
@testable import RuneKit
@testable import Rune
@testable import RuneMotion

@MainActor
@Suite("ScrollBar Runtime Parity Tests")
struct ScrollBarRuntimeParityTests {

    private nonisolated func makeView(_ rows: Int, onScroll: ((ScrollPos) -> Void)? = nil) -> El<Int> {
        let k = Kit.neutral(dark: true)
        var vp: El<Int> = col()
            .key("scroll")
            .wFull()
            .h(100.0)
            .scroll(stickBottom: false)
        if let onScroll {
            vp = vp.onScrollOffset(onScroll)
        }
        return col()
            .size(200.0, 100.0)
            .child(
                vp
                    .child(col().children((0..<rows).map { i in el().key("row\(i)").wFull().h(20.0) }))
                    .scrollBar(k)
            )
    }

    private func info<S>(_ rt: Runtime<S>, _ key: String) throws -> ElementInfo {
        try #require(rt.elements().first { !$0.exiting && $0.key == key }, "Missing element \(key)")
    }

    private func rect<S>(_ rt: Runtime<S>, _ key: String) throws -> [Float] {
        try info(rt, key).rect
    }

    private func opacity<S>(_ rt: Runtime<S>, _ key: String) throws -> Float {
        try info(rt, key).opacity
    }

    private func top<S>(_ rt: Runtime<S>) throws -> Float {
        try rect(rt, "row0")[1]
    }

    private func frames<S>(_ rt: Runtime<S>, _ n: Int, now: inout Double) {
        for _ in 0..<n {
            now += 1.0 / 60.0
            _ = rt.frame(at: now)
        }
    }

    private func colorApproxEqual(_ a: Color, _ b: Color, eps: Float = 1e-4) -> Bool {
        abs(a.r - b.r) < eps && abs(a.g - b.g) < eps && abs(a.b - b.b) < eps && abs(a.a - b.a) < eps
    }

    // 1. crates/rune-kit/src/scroll_bar/tests.rs:51
    @Test("Wrapped viewport lays out identically to bare viewport in a grow column without minH (scroll_bar/tests.rs:51)")
    func wrappedViewportLaysOutAsBareOneInGrowColumnWithoutMinH() throws {
        func pane(_ wrapped: Bool) -> El<Bool> {
            let k = Kit.neutral(dark: true)
            let viewport: El<Bool> = col()
                .key("scroll")
                .wFull()
                .grow(1.0)
                .scroll(stickBottom: false)
                .child(col().children((0..<2000).map { i in el().key("row\(i)").wFull().h(20.0) }))
            return col().size(200.0, 100.0).child(
                col()
                    .key("pane")
                    .wFull()
                    .grow(1.0)
                    .child(el().key("header").wFull().h(20.0))
                    .child(wrapped ? viewport.scrollBar(k) : viewport)
            )
        }
        func measure(wrapped: Bool) throws -> [[Float]] {
            let rt = Runtime(state: wrapped, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { w, _ in
                pane(w)
            }
            _ = rt.frame(at: 0.0)
            _ = rt.frame(at: 1.0 / 60.0)
            return try ["pane", "header", "scroll", "row0"].map { try rect(rt, $0) }
        }
        let bare = try measure(wrapped: false)
        #expect(bare[2][3] == 80.0)
        #expect(try measure(wrapped: true) == bare)
    }

    // 2. crates/rune-kit/src/scroll_bar/tests.rs:81
    @Test("Dragging the thumb and pressing the track scroll the viewport (scroll_bar/tests.rs:81)")
    func draggingThumbAndPressingTrackScrollViewport() throws {
        let rt = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            makeView(rows)
        }
        rt.setSystemScrollBars(.always)
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 1.0 / 60.0)
        let thumbRect = try rect(rt, "thumb")
        #expect(thumbRect[1] == 2.0 && thumbRect[3] == 24.0)
        let x = thumbRect[0] + 3.0
        var now = 1.0 / 60.0
        rt.pointerMove(to: Vec2(x, 10.0), at: now)
        rt.pointerDown(at: Vec2(x, 10.0), at: now)
        rt.pointerMove(to: Vec2(x, 46.0), at: now)
        now += 1.0 / 60.0
        _ = rt.frame(at: now)
        rt.pointerMove(to: Vec2(x, 82.0), at: now)
        rt.pointerUp(at: Vec2(x, 82.0), at: now)
        now += 1.0 / 60.0
        _ = rt.frame(at: now)
        #expect(try top(rt) == -300.0)

        rt.setSystemScrollerJumps(true)
        now += 1.0 / 60.0
        _ = rt.frame(at: now)
        rt.pointerMove(to: Vec2(x, 5.0), at: now)
        rt.pointerDown(at: Vec2(x, 5.0), at: now)
        rt.pointerUp(at: Vec2(x, 5.0), at: now)
        now += 1.0 / 60.0
        _ = rt.frame(at: now)
        #expect(try top(rt) == 0.0)
    }

    // 3a. crates/rune-kit/src/scroll_bar/tests.rs:108 (unblocked single-page & Option/system-jump cases)
    @Test("Track press pages 90% viewport and Option/jump preference jumps immediately (scroll_bar/tests.rs:108)")
    func trackPressPagesOnceAndOptionJumps() throws {
        func press(jumps: Bool, option: Bool, hold: Int, settleFrames: Int = 30) throws -> Float {
            let rt = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
                makeView(rows)
            }
            rt.setSystemScrollBars(.always)
            rt.setSystemScrollerJumps(jumps)
            rt.checkLiveOnly(false)
            var now = 0.0
            _ = rt.frame(at: now)
            frames(rt, 2, now: &now)
            let mods = Mods(alt: option)
            rt.pointerMove(to: Vec2(195.0, 95.0), mods: mods, at: now)
            rt.pointerDown(at: Vec2(195.0, 95.0), mods: mods, at: now)
            frames(rt, hold, now: &now)
            rt.pointerUp(at: Vec2(195.0, 95.0), mods: mods, at: now)
            frames(rt, settleFrames, now: &now)
            return try top(rt)
        }
        // Single page glide settles completely to -90.0 once MotionTokens.GLIDE completes.
        #expect(try press(jumps: false, option: false, hold: 1, settleFrames: 42) == -90.0)
        #expect(try press(jumps: false, option: false, hold: 12) == -90.0)
        #expect(try press(jumps: false, option: true, hold: 1) == -300.0)
        #expect(try press(jumps: true, option: false, hold: 1) == -300.0)
        #expect(try press(jumps: true, option: true, hold: 1, settleFrames: 42) == -90.0)
    }

    // 3b. crates/rune-kit/src/scroll_bar/tests.rs:108 (unblocked held track repeat & live-only no-view-run)
    @Test("Track press repeats while held and never runs view (scroll_bar/tests.rs:108)")
    func trackPressRepeatsWhileHeldAndNeverRunsView() throws {
        func press(jumps: Bool, option: Bool, hold: Int, settleFrames: Int = 42) throws -> Float {
            final class Runs: @unchecked Sendable { var count = 0 }
            let runs = Runs()
            let rt = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
                runs.count += 1
                return makeView(rows)
            }
            rt.setSystemScrollBars(.always)
            rt.setSystemScrollerJumps(jumps)
            rt.checkLiveOnly(false)
            var now = 0.0
            _ = rt.frame(at: now)
            frames(rt, 2, now: &now)
            let baseRuns = runs.count
            let baseCommits = rt.viewCommitCount
            let mods = Mods(alt: option)
            rt.pointerMove(to: Vec2(195.0, 95.0), mods: mods, at: now)
            rt.pointerDown(at: Vec2(195.0, 95.0), mods: mods, at: now)
            frames(rt, hold, now: &now)
            rt.pointerUp(at: Vec2(195.0, 95.0), mods: mods, at: now)
            frames(rt, settleFrames, now: &now)
            #expect(runs.count == baseRuns && rt.viewCommitCount == baseCommits)
            return try top(rt)
        }
        #expect(try press(jumps: false, option: false, hold: 1) == -90.0)
        #expect(try press(jumps: false, option: false, hold: 60) == -300.0)
        #expect(try press(jumps: true, option: true, hold: 1) == -90.0)

        let rt = Runtime(state: 40, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            makeView(rows)
        }
        rt.setSystemScrollBars(.always)
        var now = 0.0
        _ = rt.frame(at: now)
        frames(rt, 2, now: &now)
        rt.wheel(WheelEvent(dy: -10_000.0), at: Vec2(100.0, 50.0), now: now)
        frames(rt, 60, now: &now)
        #expect(try top(rt) == -700.0)
        rt.pointerMove(to: Vec2(195.0, 40.0), at: now)
        rt.pointerDown(at: Vec2(195.0, 40.0), at: now)
        frames(rt, 120, now: &now)
        let thumbRect = try rect(rt, "thumb")
        #expect(thumbRect[1] <= 40.0 && 40.0 <= thumbRect[1] + thumbRect[3])
        rt.pointerUp(at: Vec2(195.0, 40.0), at: now)
    }

    // 3c. crates/rune-kit/src/scroll_bar/tests.rs:108 (30-frame GLIDE settle exact equality)
    @Test("Track press settles 30-frame GLIDE exact equality (scroll_bar/tests.rs:108)")
    func trackPressSettlesThirtyFrameGlide() throws {
        func press(jumps: Bool, option: Bool, hold: Int) throws -> Float {
            let rt = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
                makeView(rows)
            }
            rt.setSystemScrollBars(.always)
            rt.setSystemScrollerJumps(jumps)
            rt.checkLiveOnly(false)
            var now = 0.0
            _ = rt.frame(at: now)
            frames(rt, 2, now: &now)
            let mods = Mods(alt: option)
            rt.pointerMove(to: Vec2(195.0, 95.0), mods: mods, at: now)
            rt.pointerDown(at: Vec2(195.0, 95.0), mods: mods, at: now)
            frames(rt, hold, now: &now)
            rt.pointerUp(at: Vec2(195.0, 95.0), mods: mods, at: now)
            frames(rt, 30, now: &now)
            return try top(rt)
        }
        #expect(try press(jumps: false, option: false, hold: 1) == -90.0)
        #expect(try press(jumps: true, option: true, hold: 1) == -90.0)
    }

    // 4. crates/rune-kit/src/scroll_bar/tests.rs:153
    @Test("Every scroll bar setting and automatic device style behave as specified (scroll_bar/tests.rs:153)")
    func everyScrollBarSettingAndAutomaticDeviceStyleBehaveAsSpecified() throws {
        let always = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            makeView(rows)
        }
        always.setSystemScrollBars(.always)
        var now = 0.0
        _ = always.frame(at: now)
        #expect(try opacity(always, "thumb") == 1.0)
        frames(always, 120, now: &now)
        #expect(try opacity(always, "thumb") == 1.0)

        let overlay = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            makeView(rows)
        }
        overlay.setSystemScrollBars(.whenScrolling)
        now = 0.0
        _ = overlay.frame(at: now)
        #expect(try opacity(overlay, "thumb") == 0.0)
        overlay.wheel(WheelEvent(dy: -60.0), at: Vec2(100.0, 50.0), now: now)
        frames(overlay, 20, now: &now)
        #expect(try opacity(overlay, "thumb") > 0.95)
        frames(overlay, 90, now: &now)
        #expect(try opacity(overlay, "thumb") == 0.0)

        let autoMouse = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            makeView(rows)
        }
        autoMouse.setSystemScrollBars(.automatic)
        autoMouse.setSystemScrollerOverlay(false)
        _ = autoMouse.frame(at: 0.0)
        #expect(try opacity(autoMouse, "thumb") == 1.0)

        let autoPad = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            makeView(rows)
        }
        autoPad.setSystemScrollBars(.automatic)
        autoPad.setSystemScrollerOverlay(true)
        now = 0.0
        _ = autoPad.frame(at: now)
        #expect(try opacity(autoPad, "thumb") == 0.0)
        autoPad.wheel(WheelEvent(dy: -40.0), at: Vec2(100.0, 50.0), now: now)
        frames(autoPad, 20, now: &now)
        #expect(try opacity(autoPad, "thumb") > 0.95)
        frames(autoPad, 90, now: &now)
        #expect(try opacity(autoPad, "thumb") == 0.0)
    }

    // 5a. crates/rune-kit/src/scroll_bar/tests.rs:320 (width widen/shrink/hold geometry)
    @Test("Thumb widens under pointer and stays wide while held (scroll_bar/tests.rs:320)")
    func thumbWidensUnderPointerAndWhileHeld() throws {
        let rt = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            makeView(rows)
        }
        rt.setSystemScrollBars(.always)
        var now = 0.0
        _ = rt.frame(at: now)
        frames(rt, 2, now: &now)
        let rest = try rect(rt, "thumb")
        #expect(rest[0] == 192.0 && rest[2] == ScrollBarMetrics.thumbWidth)

        rt.pointerMove(to: Vec2(195.0, 10.0), at: now)
        frames(rt, 30, now: &now)
        let wide = try rect(rt, "thumb")
        #expect(wide[0] == 188.0 && wide[2] == ScrollBarMetrics.thumbHoverWidth)
        #expect(wide[1] == rest[1] && wide[3] == rest[3])
        rt.pointerMove(to: Vec2(170.0, 10.0), at: now)
        frames(rt, 30, now: &now)
        #expect(try rect(rt, "thumb")[2] == ScrollBarMetrics.thumbWidth)

        rt.pointerMove(to: Vec2(195.0, 10.0), at: now)
        rt.pointerDown(at: Vec2(195.0, 10.0), at: now)
        rt.pointerMove(to: Vec2(100.0, 30.0), at: now)
        frames(rt, 30, now: &now)
        #expect(try rect(rt, "thumb")[2] == ScrollBarMetrics.thumbHoverWidth)
        rt.pointerUp(at: Vec2(100.0, 30.0), at: now)
        frames(rt, 30, now: &now)
        #expect(try rect(rt, "thumb")[2] == ScrollBarMetrics.thumbWidth)

        rt.pointerMove(to: Vec2(195.0, 10.0), at: now)
        frames(rt, 30, now: &now)
        rt.pointerExit(at: now)
        frames(rt, 30, now: &now)
        #expect(try rect(rt, "thumb")[2] == ScrollBarMetrics.thumbWidth)
    }

    // 5b. crates/rune-kit/src/scroll_bar/tests.rs:320 (blocked no-view-run check)
    @Test("Thumb widens under pointer without a view run (scroll_bar/tests.rs:320)")
    func thumbWidensWithoutViewRun() throws {
        final class Runs: @unchecked Sendable { var count = 0 }
        let runs = Runs()
        let rt = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            runs.count += 1
            return makeView(rows)
        }
        rt.setSystemScrollBars(.always)
        rt.checkLiveOnly(false)
        var now = 0.0
        _ = rt.frame(at: now)
        frames(rt, 2, now: &now)
        let baseRuns = runs.count
        let baseCommits = rt.viewCommitCount
        rt.pointerMove(to: Vec2(195.0, 10.0), at: now)
        frames(rt, 30, now: &now)
        rt.pointerMove(to: Vec2(170.0, 10.0), at: now)
        frames(rt, 30, now: &now)
        #expect(runs.count == baseRuns && rt.viewCommitCount == baseCommits)
    }

    // 6a. crates/rune-kit/src/scroll_bar/tests.rs:390 (strip width, rest/hover widths, OKLab-decoded colors, and no-view-run hover)
    @Test("Styled thumb takes its colours and widths at rest and under pointer without a view run (scroll_bar/tests.rs:390)")
    func styledThumbTakesColoursAndWidthsAtRestAndUnderPointer() throws {
        final class Runs: @unchecked Sendable { var count = 0 }
        let runs = Runs()
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let blue = Color(r: 0.0, g: 0.0, b: 1.0, a: 1.0)
        let rt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { _, _ in
            runs.count += 1
            let style = KitScrollBarStyle.neutral(dark: true)
                .thumb(red)
                .thumbHover(blue)
                .width(4.0)
                .hoverWidth(12.0)
            return col().size(200.0, 100.0).child(
                col()
                    .key("scroll")
                    .wFull()
                    .h(100.0)
                    .scroll(stickBottom: false)
                    .child(col().children((0..<20).map { i in el().key("row\(i)").wFull().h(20.0) }))
                    .scrollBarStyled(style)
            )
        }
        rt.setSystemScrollBars(.always)
        rt.checkLiveOnly(false)
        var now = 0.0
        _ = rt.frame(at: now)
        frames(rt, 2, now: &now)
        let baseRuns = runs.count
        let rest = try info(rt, "thumb")
        #expect(rest.rect[0] == 194.0 && rest.rect[2] == 4.0 && colorApproxEqual(rest.fill, red))
        #expect(try rect(rt, "scroll-bar")[2] == 16.0)

        rt.pointerMove(to: Vec2(185.0, 10.0), at: now)
        frames(rt, 30, now: &now)
        let hovered = try info(rt, "thumb")
        #expect(hovered.rect[0] == 186.0 && hovered.rect[2] == 12.0 && colorApproxEqual(hovered.fill, blue))
        rt.pointerMove(to: Vec2(150.0, 10.0), at: now)
        frames(rt, 30, now: &now)
        #expect(colorApproxEqual(try info(rt, "thumb").fill, red))
        #expect(runs.count == baseRuns)
    }

    // 6b. crates/rune-kit/src/scroll_bar/tests.rs:390 (exact bitwise Color == after OKLab liveFill)
    @Test("Styled thumb exact fill equality (scroll_bar/tests.rs:390)")
    func styledThumbExactFill() throws {
        final class Runs: @unchecked Sendable { var count = 0 }
        let runs = Runs()
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let blue = Color(r: 0.0, g: 0.0, b: 1.0, a: 1.0)
        let rt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { _, _ in
            runs.count += 1
            let style = KitScrollBarStyle.neutral(dark: true)
                .thumb(red)
                .thumbHover(blue)
                .width(4.0)
                .hoverWidth(12.0)
            return col().size(200.0, 100.0).child(
                col()
                    .key("scroll")
                    .wFull()
                    .h(100.0)
                    .scroll(stickBottom: false)
                    .child(col().children((0..<20).map { i in el().key("row\(i)").wFull().h(20.0) }))
                    .scrollBarStyled(style)
            )
        }
        rt.setSystemScrollBars(.always)
        rt.checkLiveOnly(false)
        var now = 0.0
        _ = rt.frame(at: now)
        frames(rt, 2, now: &now)
        let baseRuns = runs.count
        #expect(try info(rt, "thumb").fill == red)
        rt.pointerMove(to: Vec2(185.0, 10.0), at: now)
        frames(rt, 30, now: &now)
        #expect(try info(rt, "thumb").fill == blue)
        #expect(runs.count == baseRuns)
    }

    // 7. crates/rune-kit/src/scroll_bar/tests.rs:463
    @Test("Hidden overlay bar passes presses through to right-edge content (scroll_bar/tests.rs:463)")
    func hiddenOverlayBarPassesPressesThroughToRightEdgeContent() throws {
        let rt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { _, _ in
            let k = Kit.neutral(dark: true)
            return col()
                .key("list")
                .w(200.0)
                .h(100.0)
                .scroll(stickBottom: false)
                .child(
                    col().children((0..<10).map { i in
                        el().key("row\(i)")
                            .wFull()
                            .h(24.0)
                            .onClick { s, _ in s += 1 }
                    })
                )
                .scrollBar(k)
        }
        rt.setSystemScrollBars(.whenScrolling)
        _ = rt.frame(at: 0.0)
        #expect(try opacity(rt, "scroll-bar") == 0.0)
        rt.pointerMove(to: Vec2(196.0, 12.0), at: 0.0)
        rt.pointerDown(at: Vec2(196.0, 12.0), at: 0.0)
        rt.pointerUp(at: Vec2(196.0, 12.0), at: 0.0)
        _ = rt.frame(at: 1.0 / 60.0)
        #expect(rt.state == 1)
    }

    // 8. crates/rune-kit/src/scroll_bar/tests.rs:683
    @Test("Content that fits shows no bar and presses through (scroll_bar/tests.rs:683)")
    func contentThatFitsShowsNoBarAndPressesThrough() throws {
        let rt = Runtime(state: 3, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            makeView(rows)
        }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 1.0 / 60.0)
        #expect(try rect(rt, "scroll-bar")[3] == 0.0)
        #expect(try rect(rt, "thumb")[3] == 0.0)
    }

    // 9. crates/rune-kit/src/scroll_bar/tests.rs:205
    @Test("Live preference and pointing device changes update mounted scroll bars (scroll_bar/tests.rs:205)")
    func livePreferenceAndPointingDeviceChangesUpdateMountedScrollBars() throws {
        let rt = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            memo("pane", rows) {
                let k = Kit.neutral(dark: true)
                return col().size(200.0, 100.0).child(
                    col()
                        .key("memo-scroll")
                        .w(200.0)
                        .h(100.0)
                        .scroll(stickBottom: false)
                        .child(col().children((0..<rows).map { i in el().key("row\(i)").wFull().h(20.0) }))
                        .scrollBar(k)
                )
            }
        }
        var now = 0.0
        _ = rt.frame(at: now)
        #expect(try opacity(rt, "thumb") == 0.0)

        rt.setSystemScrollBars(.always)
        frames(rt, 30, now: &now)
        #expect(try opacity(rt, "thumb") == 1.0)

        rt.setSystemScrollBars(.automatic)
        rt.setSystemScrollerOverlay(true)
        frames(rt, 45, now: &now)
        #expect(try opacity(rt, "thumb") == 0.0)

        rt.setSystemScrollerOverlay(false)
        frames(rt, 30, now: &now)
        #expect(try opacity(rt, "thumb") == 1.0)
    }

    // 10. crates/rune-kit/src/scroll_bar/tests.rs:247
    @Test("Scrolling and dragging the bar run zero view commits and chain existing watchers (scroll_bar/tests.rs:247)")
    func scrollingAndDraggingRunZeroViewCommitsAndChainWatchers() throws {
        var viewRuns = 0
        var userOffset: Float = -1.0
        let rt = Runtime(state: (), viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { _, _ in
            viewRuns += 1
            let k = Kit.neutral(dark: true)
            return col()
                .w(200.0)
                .h(100.0)
                .scroll(stickBottom: false)
                .onScrollOffset { at in userOffset = at.offset.y }
                .child(col().children((0..<30).map { i in el().key("row\(i)").wFull().h(20.0) }))
                .scrollBar(k)
        }
        rt.checkLiveOnly(false)
        var now = 0.0
        _ = rt.frame(at: now)
        #expect(viewRuns == 1)
        #expect(userOffset == 0.0)
        let gen0 = rt.viewCommitCount

        for step in 0..<20 {
            rt.wheel(WheelEvent(dy: -10.0), at: Vec2(100.0, 50.0), now: now)
            now += 1.0 / 60.0
            _ = rt.frame(at: now)
            #expect(userOffset == Float((step + 1) * 10))
        }

        let thumbR = try rect(rt, "thumb")
        let x = thumbR[0] + 3.0
        let y0 = thumbR[1] + 4.0
        rt.pointerMove(to: Vec2(x, y0), at: now)
        rt.pointerDown(at: Vec2(x, y0), at: now)
        for dy: Float in [12.0, 24.0, 36.0] {
            rt.pointerMove(to: Vec2(x, y0 + dy), at: now)
            now += 1.0 / 60.0
            _ = rt.frame(at: now)
        }
        frames(rt, 70, now: &now)
        #expect(try opacity(rt, "thumb") > 0.99)
        rt.pointerUp(at: Vec2(x, y0 + 36.0), at: now)
        rt.pointerMove(to: Vec2(100.0, y0 + 36.0), at: now)
        frames(rt, 90, now: &now)
        #expect(try opacity(rt, "thumb") == 0.0)
        #expect(viewRuns == 1)
        #expect(rt.viewCommitCount == gen0)
    }

    // 11. crates/rune-kit/src/scroll_bar/tests.rs:358
    @Test("Held thumb whose release is lost narrows once pointer moves on (scroll_bar/tests.rs:358)")
    func heldThumbWhoseReleaseIsLostNarrowsOncePointerMovesOn() throws {
        let rt = Runtime(state: (20, true), viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { s, _ in
            let k = Kit.neutral(dark: true)
            let area: El<(Int, Bool)> = col()
                .key("scroll")
                .wFull()
                .h(100.0)
                .scroll(stickBottom: false)
                .child(col().children((0..<s.0).map { i in el().key("row\(i)").wFull().h(20.0) }))
                .scrollBar(k)
            return col().size(200.0, 100.0).children(s.1 ? [area] : [])
        }
        rt.setSystemScrollBars(.always)
        var now = 0.0
        _ = rt.frame(at: now)
        frames(rt, 2, now: &now)
        rt.pointerMove(to: Vec2(195.0, 10.0), at: now)
        rt.pointerDown(at: Vec2(195.0, 10.0), at: now)
        rt.pointerMove(to: Vec2(100.0, 30.0), at: now)
        frames(rt, 30, now: &now)
        #expect(try rect(rt, "thumb")[2] == ScrollBarMetrics.thumbHoverWidth)

        rt.update(at: now) { s, _ in s.1 = false }
        frames(rt, 2, now: &now)
        rt.pointerUp(at: Vec2(100.0, 30.0), at: now)
        rt.update(at: now) { s, _ in s.1 = true }
        frames(rt, 30, now: &now)
        rt.pointerMove(to: Vec2(110.0, 40.0), at: now)
        rt.pointerMove(to: Vec2(120.0, 50.0), at: now)
        frames(rt, 30, now: &now)
        #expect(try rect(rt, "thumb")[2] == ScrollBarMetrics.thumbWidth)
    }

    // 12. crates/rune-kit/src/scroll_bar/tests.rs:430
    @Test("Pointer at right edge brings up overlay bar (scroll_bar/tests.rs:430)")
    func pointerAtRightEdgeBringsUpOverlayBar() throws {
        var hoverRuns = 0
        let rt = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            hoverRuns += 1
            return makeView(rows)
        }
        rt.checkLiveOnly(false)
        var now = 0.0
        _ = rt.frame(at: now)
        frames(rt, 2, now: &now)
        let runs = hoverRuns
        let generation = rt.viewCommitCount
        #expect(try opacity(rt, "thumb") == 0.0)

        rt.pointerMove(to: Vec2(150.0, 50.0), at: now)
        frames(rt, 20, now: &now)
        #expect(try opacity(rt, "thumb") == 0.0)

        rt.pointerMove(to: Vec2(184.0, 50.0), at: now)
        frames(rt, 20, now: &now)
        #expect(try opacity(rt, "thumb") > 0.95)
        #expect(try rect(rt, "thumb")[2] == ScrollBarMetrics.thumbWidth)
        rt.wheel(WheelEvent(dy: -20.0), at: Vec2(100.0, 50.0), now: now)
        frames(rt, 150, now: &now)
        #expect(try opacity(rt, "thumb") > 0.99)

        rt.pointerMove(to: Vec2(150.0, 50.0), at: now)
        frames(rt, 20, now: &now)
        #expect(try opacity(rt, "thumb") > 0.99)
        frames(rt, 120, now: &now)
        #expect(try opacity(rt, "thumb") == 0.0)

        rt.pointerMove(to: Vec2(196.0, 50.0), at: now)
        frames(rt, 20, now: &now)
        rt.pointerExit(at: now)
        frames(rt, 150, now: &now)
        #expect(try opacity(rt, "thumb") == 0.0)
        #expect(hoverRuns == runs)
        #expect(rt.viewCommitCount == generation)
    }

    // 13. crates/rune-kit/src/scroll_bar/tests.rs:494
    @Test("Still view stops asking for frames (scroll_bar/tests.rs:494)")
    func stillViewStopsAskingForFrames() {
        let rt = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            makeView(rows)
        }
        rt.setLiveWaker {}
        var now = 0.0
        frames(rt, 60, now: &now)
        rt.wheel(WheelEvent(dy: -40.0), at: Vec2(100.0, 50.0), now: now)
        frames(rt, 90, now: &now)
        rt.invalidate()
        frames(rt, 60, now: &now)
        let wants = (0..<5).map { _ -> (Bool, Bool) in
            now += 1.0 / 60.0
            _ = rt.frame(at: now)
            return (rt.isAnimating, rt.livePending)
        }
        #expect(wants.allSatisfy { !$0.0 && !$0.1 })
    }

    // 14. crates/rune-kit/src/scroll_bar/tests.rs:513
    @Test("New content moves thumb at once (scroll_bar/tests.rs:513)")
    func newContentMovesThumbAtOnce() throws {
        let rt = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            makeView(rows)
        }
        rt.setSystemScrollBars(.always)
        rt.setLiveWaker {}
        var now = 0.0
        frames(rt, 60, now: &now)
        rt.update(at: now) { rows, tx in
            rows = 40
            tx.instant()
        }
        now += 1.0 / 120.0
        _ = rt.frame(at: now)
        let moving = rt.elements().filter(\.moving).map(\.key)
        #expect(moving.isEmpty)
        #expect(try rect(rt, "thumb")[3] == max(24.0, 96.0 * 100.0 / 800.0))
    }

    // 15. crates/rune-kit/src/scroll_bar/tests.rs:531
    @Test("Thumb glides to new length without view run (scroll_bar/tests.rs:531)")
    func thumbGlidesToNewLengthWithoutViewRun() throws {
        var hoverRuns = 0
        let rt = Runtime(state: 10, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            hoverRuns += 1
            return makeView(rows)
        }
        rt.setSystemScrollBars(.always)
        var now = 0.0
        frames(rt, 30, now: &now)
        #expect(try rect(rt, "thumb")[3] == 48.0)

        rt.update(at: now) { rows, _ in rows = 20 }
        frames(rt, 3, now: &now)
        let runs = hoverRuns
        let drawn = try rect(rt, "thumb")
        let slot = try rect(rt, "thumb-slot")
        #expect(24.0 < drawn[3] && drawn[3] < 48.0)
        #expect(drawn[3] == slot[3])
        #expect(try info(rt, "thumb").moving)

        frames(rt, 60, now: &now)
        #expect(try rect(rt, "thumb")[3] == 24.0)
        #expect(hoverRuns == runs)

        func thumbAt(_ rt: Runtime<Int>) throws -> Float {
            let offset = try -top(rt)
            return ScrollBarMetrics.inset + ScrollBarMath.thumbAlong(
                ScrollAxisMetrics(offset: offset, content: 200.0, viewport: 100.0),
                trackLength: 96.0
            ).start
        }

        rt.update(at: now) { rows, _ in rows = 10 }
        frames(rt, 3, now: &now)
        rt.wheel(WheelEvent(dy: -40.0), at: Vec2(100.0, 50.0), now: now)
        now += 1.0 / 60.0
        _ = rt.frame(at: now)
        let snapped = try rect(rt, "thumb")
        let expectedThumbY = try thumbAt(rt)
        #expect(abs(snapped[1] - expectedThumbY) < 0.01)
        #expect(abs(snapped[3] - 48.0) < 1e-4)

        frames(rt, 60, now: &now)
        rt.wheel(WheelEvent(dy: -10.0), at: Vec2(100.0, 50.0), now: now)
        for _ in 0..<30 {
            now += 1.0 / 60.0
            _ = rt.frame(at: now)
            let yDrawn = try rect(rt, "thumb")[1]
            let yShown = try thumbAt(rt)
            #expect(abs(yDrawn - yShown) < 0.01)
        }
    }

    // 16. crates/rune-kit/src/scroll_bar/tests.rs:564
    @Test("Hidden overlay thumb lands new length at once (scroll_bar/tests.rs:564)")
    func hiddenOverlayThumbLandsNewLengthAtOnce() throws {
        let rt = Runtime(state: 10, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            makeView(rows)
        }
        rt.setLiveWaker {}
        var now = 0.0
        frames(rt, 30, now: &now)
        #expect(try opacity(rt, "scroll-bar") == 0.0)
        rt.update(at: now) { rows, _ in rows = 20 }
        frames(rt, 2, now: &now)
        #expect(try rect(rt, "thumb")[3] == 24.0)
        #expect(try !info(rt, "thumb").moving && !info(rt, "thumb-slot").moving)
    }

    // 17. crates/rune-kit/src/scroll_bar/tests.rs:581
    @Test("Pulse is due at hold and fade summed before now (scroll_bar/tests.rs:581)")
    func pulseDueAtHoldAndFadeSummedBeforeNow() {
        let hold = 0.750
        func follow(
            _ state: inout ScrollBarVisibilityMachine.BarState,
            now: Double,
            scrolled: Bool,
            instant: Bool,
            extentChanged: Bool
        ) -> [ScrollBarVisibilityMachine.Effect] {
            ScrollBarVisibilityMachine.step(
                &state,
                .follow(.init(
                    shows: true,
                    overlay: true,
                    scrolled: scrolled,
                    instant: instant,
                    resized: false,
                    lengthened: false,
                    extentChanged: extentChanged,
                    pressed: false,
                    revealed: false,
                    now: now,
                    holdSeconds: hold
                ))
            )
        }
        var state: ScrollBarVisibilityMachine.BarState = .overlay(phase: .hidden, glide: .idle)
        _ = follow(&state, now: 0.3, scrolled: true, instant: false, extentChanged: false)
        #expect(state.pulseUntil == 1.4000000000000001)

        let effects = follow(&state, now: 1.4, scrolled: false, instant: true, extentChanged: true)
        #expect(effects.contains { effect in
            if case .opacity(.pulse) = effect { return true }
            return false
        })

        var held: ScrollBarVisibilityMachine.BarState = .overlay(phase: .held, glide: .idle)
        _ = ScrollBarVisibilityMachine.step(
            &held,
            .letGo(pressed: false, revealed: false, areaReveals: false, now: 0.3, holdSeconds: hold)
        )
        #expect(held.pulseUntil == 1.4000000000000001)
    }

    // 18. crates/rune-kit/src/scroll_bar/tests.rs:620
    @Test("New bar lands at once (scroll_bar/tests.rs:620)")
    func newBarLandsAtOnce() throws {
        let rt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            rows == 0 ? col().size(200.0, 100.0) : makeView(rows)
        }
        rt.setSystemScrollBars(.always)
        rt.setLiveWaker {}
        var now = 0.0
        frames(rt, 60, now: &now)
        rt.update(at: now) { rows, tx in
            rows = 40
            tx.instant()
        }
        now += 1.0 / 120.0
        _ = rt.frame(at: now)
        let moving = rt.elements().filter(\.moving).map(\.key)
        #expect(moving.isEmpty)
        #expect(try rect(rt, "thumb")[3] == 24.0)
    }

    // 19. crates/rune-kit/src/scroll_bar/tests.rs:641
    @Test("Following the end and gliding to it don't show overlay bar (scroll_bar/tests.rs:641)")
    func followingEndAndGlidingToItDontShowOverlayBar() throws {
        let rt = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            let k = Kit.neutral(dark: true)
            return col().size(200.0, 100.0).child(
                col()
                    .key("feed")
                    .wFull()
                    .h(100.0)
                    .scroll(stickBottom: true)
                    .child(col().children((0..<rows).map { i in el().key("row\(i)").wFull().h(20.0) }))
                    .scrollBar(k)
            )
        }
        rt.setLiveWaker {}
        var now = 0.0
        frames(rt, 60, now: &now)
        for _ in 0..<30 {
            rt.update(at: now) { rows, _ in rows += 1 }
            for _ in 0..<4 {
                now += 1.0 / 60.0
                _ = rt.frame(at: now)
                #expect(try opacity(rt, "thumb") == 0.0)
            }
        }
        rt.wheel(WheelEvent(dy: 400.0), at: Vec2(100.0, 50.0), now: now)
        frames(rt, 150, now: &now)
        #expect(try opacity(rt, "thumb") == 0.0)

        rt.update(at: now) { _, tx in tx.scrollToBottom("feed") }
        for _ in 0..<90 {
            now += 1.0 / 60.0
            _ = rt.frame(at: now)
            #expect(try opacity(rt, "thumb") == 0.0)
        }
        rt.update(at: now) { _, tx in tx.scrollPage("feed", -1) }
        frames(rt, 20, now: &now)
        #expect(try opacity(rt, "thumb") > 0.95)
    }

    // 20. crates/rune-kit/src/scroll_bar/tests.rs:701
    @Test("ScrollBar motion gate (scroll_bar/tests.rs:701)")
    func scrollBarMotionGate() throws {
        let cells = MotionGateGate.run([
            (
                "scroll-bar/when-scrolling-pulse-and-preference-switch",
                {
                    let rt = Runtime(state: 24, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
                        makeView(rows)
                    }
                    let r = MotionGateRun(rt, hz: 120.0)
                    r.idle(0.3)
                    for _ in 0..<12 {
                        r.act("wheel") { rt in rt.wheel(WheelEvent(dy: -12.0), at: Vec2(100.0, 50.0), now: rt.currentTime) }
                    }
                    r.play(1.6)
                    r.act("always") { rt in rt.setSystemScrollBars(.always) }
                    r.play(0.6)
                    r.act("when-scrolling") { rt in rt.setSystemScrollBars(.whenScrolling) }
                    r.play(1.2)
                    return r.rec
                }
            ),
            (
                "scroll-bar/hover-widen-and-edge-reveal",
                {
                    let rt = Runtime(state: 24, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
                        makeView(rows)
                    }
                    let r = MotionGateRun(rt, hz: 120.0)
                    r.idle(0.3)
                    r.act("near-edge") { rt in rt.pointerMove(to: Vec2(184.0, 50.0), at: rt.currentTime) }
                    r.play(0.5)
                    r.act("over-bar") { rt in rt.pointerMove(to: Vec2(195.0, 10.0), at: rt.currentTime) }
                    r.play(0.4)
                    r.act("off-bar") { rt in rt.pointerMove(to: Vec2(170.0, 10.0), at: rt.currentTime) }
                    r.play(0.4)
                    r.act("away") { rt in rt.pointerMove(to: Vec2(100.0, 50.0), at: rt.currentTime) }
                    r.play(1.6)
                    r.act("always") { rt in rt.setSystemScrollBars(.always) }
                    r.play(0.4)
                    r.act("over-always") { rt in rt.pointerMove(to: Vec2(195.0, 10.0), at: rt.currentTime) }
                    r.play(0.4)
                    r.act("away-always") { rt in rt.pointerMove(to: Vec2(100.0, 50.0), at: rt.currentTime) }
                    r.play(0.4)
                    return r.rec
                }
            ),
            (
                "scroll-bar/length-glide",
                {
                    let rt = Runtime(state: 10, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
                        makeView(rows)
                    }
                    rt.setSystemScrollBars(.always)
                    let r = MotionGateRun(rt, hz: 120.0)
                    r.idle(0.3)
                    r.act("grow") { rt in rt.update(at: rt.currentTime) { rows, _ in rows = 20 } }
                    r.play(0.6)
                    r.act("shrink") { rt in rt.update(at: rt.currentTime) { rows, _ in rows = 12 } }
                    r.play(0.6)
                    return r.rec
                }
            ),
        ])
        let report = MotionGateGate.report(cells)
        #expect(report.failing == 0, Comment(rawValue: report.text))
    }

    // 21. crates/rune-kit/src/scroll_bar/tests.rs:785
    @Test("Bar follows viewport while its height animates (scroll_bar/tests.rs:785)")
    func barFollowsViewportWhileHeightAnimates() throws {
        var paneRuns = 0
        let rt = Runtime(state: Float(40.0), viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true) { composer, _ in
            paneRuns += 1
            let k = Kit.neutral(dark: true)
            return col()
                .size(200.0, 200.0)
                .child(
                    col()
                        .key("scroll")
                        .wFull()
                        .grow(1.0)
                        .minH(0.0)
                        .scroll(stickBottom: false)
                        .animateLayout(MotionTokens.SETTLE)
                        .child(col().children((0..<40).map { i in el().key("row\(i)").wFull().h(20.0) }))
                        .scrollBar(k)
                )
                .child(el().key("composer").wFull().h(composer).animateLayout(MotionTokens.SETTLE))
        }
        rt.setSystemScrollBars(.always)
        rt.setLiveWaker {}
        var now = 0.0
        frames(rt, 30, now: &now)
        rt.wheel(WheelEvent(dy: -10_000.0), at: Vec2(100.0, 50.0), now: now)
        frames(rt, 60, now: &now)
        rt.update(at: now) { h, _ in h = 95.0 }
        var runs = 0
        var between = 0
        for i in 0..<60 {
            now += 1.0 / 60.0
            _ = rt.frame(at: now)
            if i == 0 {
                runs = paneRuns
            }
            let vp = try rect(rt, "scroll")
            let track = try rect(rt, "scroll-bar")
            let thumb = try rect(rt, "thumb")
            let bottom = vp[1] + vp[3]
            #expect(abs(track[1] + track[3] - (bottom - ScrollBarMetrics.inset)) < 0.05)
            #expect(thumb[1] + thumb[3] <= bottom - ScrollBarMetrics.inset + 0.05)
            if 105.0 < vp[3] && vp[3] < 160.0 {
                between += 1
            }
        }
        #expect(between > 5)
        frames(rt, 120, now: &now)
        #expect(try rect(rt, "scroll-bar")[3] == 105.0 - 2.0 * ScrollBarMetrics.inset)
        #expect(paneRuns == runs)
    }

    // 22. P2-16 (14eb362e / #871): ScrollView & MenuScroll only take drags on thumb; empty track passes presses through.
    @Test("ScrollView & MenuScroll thumbOnly leaves empty track to viewport while dragging thumb scrolls accurately (#871)")
    func thumbOnlyLeavesEmptyTrackToViewportAndDragsThumb() throws {
        struct App {
            var clicks: [Int] = []
        }
        let kit = Kit.neutral(dark: true)
        #expect(KitScrollBarStyle.scrollView(kit).thumbOnly == true)
        #expect(KitScrollBarStyle.menuScroll(kit).thumbOnly == true)
        #expect(KitScrollBarStyle.fromKit(kit).thumbOnly == false)
        #expect(KitScrollBarStyle.native(kit).thumbOnly == false)

        let style = KitScrollBarStyle.scrollView(kit).alwaysVisible(true)
        let rt = Runtime(state: App(), viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { _, _ in
            col().size(200.0, 100.0).child(
                col()
                    .key("scroll")
                    .wFull()
                    .h(100.0)
                    .scroll(stickBottom: false)
                    .child(col().children((0..<25).map { i in
                        el().key("row\(i)")
                            .wFull()
                            .h(20.0)
                            .onClick { st, _ in st.clicks.append(i) }
                    }))
                    .scrollBarStyled(style)
            )
        }
        rt.setSystemScrollBars(.always)
        var now = 0.0
        _ = rt.frame(at: now)
        frames(rt, 2, now: &now)

        let slotRect = try rect(rt, "thumb-slot")
        let thumbRect = try rect(rt, "thumb")
        #expect(slotRect[2] == style.resolvedStripWidth)
        #expect(thumbRect[2] == 4.0)

        // Pressing empty track well below the thumb hits the row behind it and does not page/jump.
        let emptyTrackPt = Vec2(194.0, 90.0) // row4 (y = 80..100)
        #expect(emptyTrackPt.y > slotRect[1] + slotRect[3] + 2.0)
        rt.pointerMove(to: emptyTrackPt, at: now)
        rt.pointerDown(at: emptyTrackPt, at: now)
        rt.pointerUp(at: emptyTrackPt, at: now)
        frames(rt, 2, now: &now)
        #expect(rt.state.clicks == [4])
        #expect(try top(rt) == 0.0)

        // Pressing thumb-slot does not fire row click and does not jump on down; dragging scrolls smoothly.
        let grabPt = Vec2(slotRect[0] + 2.0, slotRect[1] + 6.0) // 12pt wide strip beside the 4pt pill
        rt.pointerMove(to: grabPt, at: now)
        rt.pointerDown(at: grabPt, at: now)
        frames(rt, 1, now: &now)
        #expect(rt.state.clicks == [4])
        #expect(try top(rt) == 0.0)

        let trackLen: Float = 100.0 - style.trackStartInset - style.trackEndInset // 84
        let travel = trackLen - slotRect[3] // 84 - 32 = 52
        rt.pointerMove(to: Vec2(grabPt.x, grabPt.y + travel * 0.5), at: now)
        frames(rt, 1, now: &now)
        let midTop = try top(rt)
        #expect(abs(midTop - (-200.0)) < 1.0)

        rt.pointerMove(to: Vec2(grabPt.x, grabPt.y + travel), at: now)
        rt.pointerUp(at: Vec2(grabPt.x, grabPt.y + travel), at: now)
        frames(rt, 2, now: &now)
        #expect(try top(rt) == -400.0)
        #expect(rt.state.clicks == [4])
    }

    // 23. crates/rune-kit/src/scroll_bar/tests.rs (`#1214`): wheel over bar/thumb scrolls viewport it follows.
    @Test("Wheel over scroll bar track and thumb scrolls the viewport it follows (#1214, scroll_bar/tests.rs)")
    func wheelOverBarScrollsViewportItFollows() throws {
        let rt = Runtime(state: 20, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { rows, _ in
            makeView(rows)
        }
        rt.setSystemScrollBars(.always)
        var now = 0.0
        _ = rt.frame(at: now)
        frames(rt, 2, now: &now)

        let track = try rect(rt, "scroll-bar")
        #expect(track[0] == 186.0 && track[2] == 14.0)

        rt.wheel(WheelEvent(dy: -40.0), at: Vec2(track[0] + track[2] / 2.0, 50.0), now: now)
        now += 1.0 / 60.0
        _ = rt.frame(at: now)
        #expect(try top(rt) == -40.0)

        let thumb = try rect(rt, "thumb")
        rt.wheel(WheelEvent(dy: -40.0), at: Vec2(thumb[0] + thumb[2] / 2.0, thumb[1] + thumb[3] / 2.0), now: now)
        now += 1.0 / 60.0
        _ = rt.frame(at: now)
        #expect(try top(rt) == -80.0)

        rt.wheel(WheelEvent(dy: -40.0), at: Vec2(60.0, 50.0), now: now)
        now += 1.0 / 60.0
        _ = rt.frame(at: now)
        #expect(try top(rt) == -120.0)
    }

    // 24. `#1214` thumbOnly bar + two identically-keyed vertical panes resolve wheel to their own viewport.
    @Test("Wheel over thumbOnly scroll bar and identically-keyed sibling panes scrolls only its own viewport (#1214)")
    func wheelOverThumbOnlyAndSiblingPanesScrollsOwnViewport() throws {
        // Part A: thumbOnly (ScrollView style) handles wheel over both thumb and empty track while keeping click passthrough.
        struct ClickState {
            var clicks: [Int] = []
        }
        let kit = Kit.neutral(dark: true)
        let thumbOnlyStyle = KitScrollBarStyle.scrollView(kit).alwaysVisible(true)
        let thumbOnlyRT = Runtime(state: ClickState(), viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { _, _ in
            col().size(200.0, 100.0).child(
                col()
                    .key("scroll")
                    .wFull()
                    .h(100.0)
                    .scroll(stickBottom: false)
                    .child(col().children((0..<25).map { i in
                        el().key("row\(i)")
                            .wFull()
                            .h(20.0)
                            .onClick { st, _ in st.clicks.append(i) }
                    }))
                    .scrollBarStyled(thumbOnlyStyle)
            )
        }
        thumbOnlyRT.setSystemScrollBars(.always)
        var now = 0.0
        _ = thumbOnlyRT.frame(at: now)
        frames(thumbOnlyRT, 2, now: &now)

        let slotR = try rect(thumbOnlyRT, "thumb-slot")
        let emptyTrackPt = Vec2(194.0, 88.0)
        #expect(emptyTrackPt.y > slotR[1] + slotR[3] + 2.0)

        // Wheel over empty track scrolls the viewport.
        thumbOnlyRT.wheel(WheelEvent(dy: -30.0), at: emptyTrackPt, now: now)
        now += 1.0 / 60.0
        _ = thumbOnlyRT.frame(at: now)
        #expect(try top(thumbOnlyRT) == -30.0)

        // Wheel over thumb-slot also scrolls the viewport.
        let updatedSlot = try rect(thumbOnlyRT, "thumb-slot")
        thumbOnlyRT.wheel(WheelEvent(dy: -25.0), at: Vec2(updatedSlot[0] + updatedSlot[2] / 2.0, updatedSlot[1] + updatedSlot[3] / 2.0), now: now)
        now += 1.0 / 60.0
        _ = thumbOnlyRT.frame(at: now)
        #expect(try top(thumbOnlyRT) == -55.0)

        // Click on empty track still passes through to the row behind it.
        thumbOnlyRT.pointerMove(to: emptyTrackPt, at: now)
        thumbOnlyRT.pointerDown(at: emptyTrackPt, at: now)
        thumbOnlyRT.pointerUp(at: emptyTrackPt, at: now)
        frames(thumbOnlyRT, 2, now: &now)
        #expect(!thumbOnlyRT.state.clicks.isEmpty)

        // Part B: two side-by-side panes keying their viewports identically ("scroll") each take their own bar's wheel.
        final class PaneOffsets: @unchecked Sendable {
            var left: Float = 0.0
            var right: Float = 0.0
        }
        let offsets = PaneOffsets()
        let panesRT = Runtime(state: (), viewport: Vec2(400, 100), pixelScale: 1.0, systemDark: true) { _, _ in
            let k = Kit.neutral(dark: true)
            func makePane(_ key: String, onScroll: @escaping @Sendable (ScrollPos) -> Void) -> El<Void> {
                col().key(key).size(200.0, 100.0).child(
                    col()
                        .key("scroll")
                        .wFull()
                        .h(100.0)
                        .scroll(stickBottom: false)
                        .onScrollOffset(onScroll)
                        .child(col().children((0..<20).map { i in el().key("row\(i)").wFull().h(20.0) }))
                        .scrollBar(k)
                )
            }
            return row().key("root").wFull().hFull()
                .child(makePane("left") { offsets.left = $0.offset.y })
                .child(makePane("right") { offsets.right = $0.offset.y })
        }
        panesRT.setSystemScrollBars(.always)
        now = 0.0
        _ = panesRT.frame(at: now)
        frames(panesRT, 2, now: &now)

        let tracks = panesRT.elements().filter { !$0.exiting && $0.key == "scroll-bar" }.map(\.rect)
        let leftBar = try #require(tracks.first { $0[0] < 200.0 })
        let rightBar = try #require(tracks.first { $0[0] >= 200.0 })

        panesRT.wheel(WheelEvent(dy: -40.0), at: Vec2(rightBar[0] + rightBar[2] / 2.0, 50.0), now: now)
        now += 1.0 / 60.0
        _ = panesRT.frame(at: now)
        #expect(offsets.right == 40.0)
        #expect(offsets.left == 0.0)

        panesRT.wheel(WheelEvent(dy: -25.0), at: Vec2(leftBar[0] + leftBar[2] / 2.0, 50.0), now: now)
        now += 1.0 / 60.0
        _ = panesRT.frame(at: now)
        #expect(offsets.left == 25.0)
        #expect(offsets.right == 40.0)
    }
}
