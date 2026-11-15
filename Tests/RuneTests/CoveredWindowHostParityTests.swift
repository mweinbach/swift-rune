import Foundation
import Testing
@testable import Rune
import RuneMotion

// Upstream 2e23d0fa (#995), host side: `window/sight.rs::Host::set_cover` and `window::covered_step`
// as the AppKit hosts run them through `CoveredWindowDriver` (`MacOSApp.swift`,
// `WindowHostingMacOS.swift`). The upstream commit changed no Rust #[test]; its host paths are
// `window/covered_tests.rs`'s (ported in `WindowLifecycleParityTests`) with `covered_step` now
// running `Runtime::covered_wake`. These drive the driver exactly as the hosts' occlusion,
// miniaturize, wake and accessibility callbacks do.
@Suite("Covered window host parity (#995)")
@MainActor
struct CoveredWindowHostParityTests {
    struct S {
        var extra = 0
        var loaded = false
        var visibility: [Bool] = []
        var permission = false
    }

    static func runtime() -> Runtime<S> {
        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 300), pixelScale: 1.0) { s, _ in
            var root: El<S> = col().size(400, 300).gap(8)
                .child(el().key("prompt").size(120, 24).focusable())
                .child(text("\(s.extra)").key("count"))
            if s.loaded {
                root = root.child(
                    el().key("card").size(80, 40)
                        .child(el().key("allow").size(60, 24).focusable())
                )
            }
            return root
        }
        rt.onVisibility = { s, visible, _ in s.visibility.append(visible) }
        _ = rt.frame(at: 0.0)
        return rt
    }

    static func shownCount(_ rt: Runtime<S>) -> String? {
        rt.elements().first { $0.key == "count" }?.text
    }

    @Test("an occlusion report covers the window: not live, wakes run covered_step, nothing builds without a reader")
    func occlusionCoversAndWakesRunCovered() {
        let rt = Self.runtime()
        var driver = CoveredWindowDriver()
        #expect(driver.canDraw)
        #expect(driver.setOccluded(true, runtime: rt, at: 0.01) == .rest, "covered: stop pacing and rest")
        #expect(!driver.canDraw)
        #expect(!rt.liveVisible, "set_live_visible(uncovered && !minimized)")
        #expect(rt.state.visibility == [false], "App::on_visibility hears it go")

        let commits = rt.commitCount
        rt.update(at: 0.02) { s, _ in s.extra = 3 }
        #expect(!driver.step(rt, at: 0.03), "no reader: the view waits for the frame that uncovers it")
        #expect(rt.commitCount == commits)
        #expect(rt.isStale)
        #expect(Self.shownCount(rt) == "0")

        #expect(driver.setOccluded(false, runtime: rt, at: 0.04) == .redraw, "uncovered: its first frame draws what it owed")
        #expect(driver.canDraw)
        #expect(rt.liveVisible)
        #expect(rt.state.visibility == [false, true], "and hears it come back")
        _ = rt.frame(at: 0.05)
        #expect(Self.shownCount(rt) == "3")
    }

    @Test("once an assistive client reads the window, a covered wake builds what changed at once, without drawing")
    func readerGetsCoveredChangesAtOnce() {
        let rt = Self.runtime()
        var driver = CoveredWindowDriver()
        _ = driver.setOccluded(true, runtime: rt, at: 0.01)
        // The host's `accessibilityChildren` asks for the tree (AccessKit's activation).
        driver.assistiveClientAttached(rt)
        #expect(rt.assistiveTechnology, "a11y.is_some()")
        let commits = rt.commitCount
        rt.update(at: 0.02) { s, _ in s.extra = 7 }
        #expect(driver.step(rt, at: 0.03), "the host hands the reader the new tree")
        #expect(rt.commitCount == commits + 1)
        #expect(Self.shownCount(rt) == "7")
        #expect(!rt.isStale)
        #expect(!driver.step(rt, at: 0.04), "nothing more to build")
        #expect(!rt.liveVisible, "still covered: not live")
    }

    @Test("focus a poll asks of what a covered window's change shows (a permission's card) lands while a reader reads it")
    func readerGetsAskedFocusWhileCovered() {
        let rt = Self.runtime()
        rt.poll = { s, _, tx in
            guard s.permission, !s.loaded else { return false }
            s.loaded = true
            tx.focusWhenShown("card", ring: true)
            return true
        }
        var driver = CoveredWindowDriver()
        _ = driver.setOccluded(true, runtime: rt, at: 0.01)
        driver.assistiveClientAttached(rt)
        rt.state.permission = true
        driver.step(rt, at: 0.02)
        #expect(rt.focusedKey == "allow", "the reader hears the card take focus without waiting for a draw")
        #expect(rt.focusVisible)
    }

    @Test("without a reader, focus asked while covered waits and lands on the frame that uncovers it")
    func askedFocusWaitsForUncoverWithoutReader() {
        let rt = Self.runtime()
        var driver = CoveredWindowDriver()
        _ = driver.setOccluded(true, runtime: rt, at: 0.01)
        rt.update(at: 0.02) { s, tx in
            s.loaded = true
            tx.focusWhenShown("card", ring: false)
        }
        driver.step(rt, at: 0.03)
        #expect(rt.focusedKey == nil)
        #expect(driver.setOccluded(false, runtime: rt, at: 0.04) == .redraw)
        _ = rt.frame(at: 0.05)
        #expect(rt.focusedKey == "allow")
    }

    @Test("a minimised window can't draw until it's restored, whatever occlusion says meanwhile")
    func minimizedWindowIsCovered() {
        let rt = Self.runtime()
        var driver = CoveredWindowDriver()
        #expect(driver.setMinimized(true, runtime: rt, at: 0.01) == .rest)
        #expect(!driver.canDraw)
        #expect(!rt.liveVisible)
        #expect(driver.setOccluded(false, runtime: rt, at: 0.02) == .rest, "uncovered but still minimised")
        #expect(!rt.liveVisible)
        driver.assistiveClientAttached(rt)
        rt.update(at: 0.03) { s, _ in s.extra = 5 }
        #expect(driver.step(rt, at: 0.04), "a minimised window a reader reads builds at once too")
        #expect(Self.shownCount(rt) == "5")
        #expect(driver.setMinimized(false, runtime: rt, at: 0.05) == .redraw, "restored: it settles and draws")
        #expect(driver.canDraw)
        #expect(rt.liveVisible)
    }

    @Test("uncovering settles what changed while covered, so its first frame paints where motion ends")
    func uncoverSettles() throws {
        struct M { var wide = false }
        let rt = Runtime<M>(state: M(), viewport: Vec2(400, 300), pixelScale: 1.0) { s, _ in
            col().size(400, 300).child(el().key("bar").size(s.wide ? 180 : 40, 20).motion(Spring(duration: 0.4, bounce: 0.0)))
        }
        _ = rt.frame(at: 0.0)
        var driver = CoveredWindowDriver()
        _ = driver.setOccluded(true, runtime: rt, at: 0.01)
        rt.update(at: 0.02) { s, _ in s.wide = true }
        driver.step(rt, at: 0.03)
        #expect(driver.setOccluded(false, runtime: rt, at: 0.04) == .redraw)
        _ = rt.frame(at: 0.04 + 1.0 / 120.0)
        let bar = try #require(rt.presented("bar")).rect[2]
        #expect(abs(bar - 180) < 0.5, "landed, nothing left to play: \(bar)")
    }

    @Test("an uncover report for a window that was never covered and is current asks for nothing")
    func uncoverWhenSeenAndCurrentIsNone() {
        let rt = Self.runtime()
        var driver = CoveredWindowDriver()
        #expect(driver.setOccluded(false, runtime: rt, at: 0.01) == .none)
        rt.update(at: 0.02) { s, _ in s.extra = 1 }
        #expect(driver.setOccluded(false, runtime: rt, at: 0.03) == .redraw, "a stale window still draws (`else if rt.stale()`)")
    }
}
