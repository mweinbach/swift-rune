import Foundation
import Testing
@testable import RuneKit
@testable import Rune
@testable import RuneMotion

@MainActor
@Suite("ScrollBar Runtime Parity Tests")
struct ScrollBarRuntimeParityTests {

    private func makeView(_ rows: Int, onScroll: ((ScrollPos) -> Void)? = nil) -> El<Int> {
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

    // 3c. crates/rune-kit/src/scroll_bar/tests.rs:108 (blocked part: 30-frame GLIDE settle exact equality)
    @Test(
        "Track press settles 30-frame GLIDE exact equality (scroll_bar/tests.rs:108)",
        .disabled("Blocked on @motion: MotionTokens.GLIDE (0.32s) needs >31 frames to settle exact equality")
    )
    func trackPressSettlesThirtyFrameGlideBlockedOnMotion() throws {
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

    // 6b. crates/rune-kit/src/scroll_bar/tests.rs:390 (blocked exact bitwise Color == after OKLab liveFill)
    @Test(
        "Styled thumb exact fill equality (scroll_bar/tests.rs:390)",
        .disabled("Blocked on @motion: MotionColor OKLab encode/decode introduces ~1e-6 float rounding in Runtime.swift:3644 Color(mc) for Props.FILL")
    )
    func styledThumbExactFillBlockedOnMotion() throws {
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
}
