import Foundation
import Testing
@testable import Rune
import RuneMotion

@Suite("Rune Paint Tracks Parity Tests (runtime/paint_tracks_tests.rs)")
struct PaintTracksParityTests {
    private struct ThemeState {
        var dark: Bool
    }

    private static func themeView(_ s: ThemeState, _: inout Cx<ThemeState>) -> El<ThemeState> {
        let bg: Color = s.dark ? .black : .white
        let fg: Color = s.dark ? .white : .black
        return col()
            .wFull()
            .hFull()
            .bg(bg)
            .children((0..<12).map { i -> El<ThemeState> in
                el()
                    .key("row-\(i)")
                    .wFull()
                    .h(20)
                    .bg(bg)
                    .rounded(4)
                    .opacity(0.9)
                    .border(1, fg)
                    .shadow(2, 6, fg)
                    .outline(1, 1, fg)
                    .hover(fg.alpha(0.1))
                    .press(fg.alpha(0.2))
                    .pressScale(0.97)
                    .child(text("row \(i)").color(fg))
                    .child(el().w(8).h(8).gradient(bg, fg))
            })
    }

    private static func settledRuntime(dark: Bool) -> (rt: Runtime<ThemeState>, t: Double) {
        let rt = Runtime<ThemeState>(
            state: ThemeState(dark: dark),
            viewport: Vec2(200, 300),
            pixelScale: 1.0,
            systemDark: true,
            view: themeView
        )
        var t = 0.0
        _ = rt.frame(at: t)
        var n = 0
        while n < 240 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            if !rt.isAnimating { break }
            n += 1
        }
        _ = rt.scene.frame(at: t)
        return (rt, t)
    }

    private static func rowNode(_ rt: Runtime<ThemeState>) throws -> Runtime<ThemeState>.FlatNode {
        try #require(rt.flatNodes.first { $0.key == "row-3" })
    }

    private static func labelNode(_ rt: Runtime<ThemeState>) throws -> Runtime<ThemeState>.FlatNode {
        let rowIdx = try #require(rt.flatNodes.firstIndex { $0.key == "row-3" })
        return try #require(rt.flatNodes.first { $0.parentIndex == rowIdx && $0.el.plainText != nil })
    }

    @Test("a_static_tree_keeps_no_motion_tracks")
    func staticTreeKeepsNoMotionTracks() {
        var (rt, t) = Self.settledRuntime(dark: false)
        #expect(rt.scene.store.trackLen == 0, "nothing here has moved")
        rt.invalidate()
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(rt.scene.store.trackLen == 0, "an unchanged rebuild makes none either")
    }

    @Test("an_unchanged_commit_leaves_the_scene_clean")
    func unchangedCommitLeavesSceneClean() {
        let (rt, t) = Self.settledRuntime(dark: false)
        let tx = Tx()
        rt.commit(tx, at: t)
        #expect(rt.scene.frame(at: t).changed.isEmpty, "no node presents again")
    }

    @Test("a_first_colour_change_still_crossfades_from_the_drawn_colour")
    func firstColourChangeCrossfadesFromDrawnColour() throws {
        var (rt, t) = Self.settledRuntime(dark: false)
        rt.update(at: t) { s, _ in s.dark = true }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)

        let n = try Self.rowNode(rt)
        let fill = rt.color(n.nodeId, Props.FILL, fallback: n.el.background)
        #expect(fill.r < 1.0 && fill.r > 0.0, "the fill is between white and black: \(fill)")

        let l = try Self.labelNode(rt)
        let textCol = rt.color(l.nodeId, Props.TEXT_COLOR, fallback: try #require(l.el.textColor))
        #expect(textCol.r > 0.0 && textCol.r < 1.0, "the text is between black and white: \(textCol)")

        let border = rt.color(n.nodeId, Props.BORDER, fallback: n.el.borderColor)
        #expect(border.r > 0.0 && border.r < 1.0, "the border is between black and white: \(border)")

        let shadow = rt.color(n.nodeId, Props.SHADOW_COLOR, fallback: try #require(n.el.shadows.first).color)
        #expect(shadow.r > 0.0 && shadow.r < 1.0, "the shadow is between black and white: \(shadow)")

        var k = 0
        while k < 240 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            if !rt.isAnimating { break }
            k += 1
        }
        let settledRow = try Self.rowNode(rt)
        #expect(rt.color(settledRow.nodeId, Props.FILL, fallback: settledRow.el.background) == .black)
        #expect(rt.color(settledRow.nodeId, Props.BORDER, fallback: settledRow.el.borderColor) == .white)
    }

    @Test("an_instant_colour_change_lands_without_a_track")
    func instantColourChangeLandsWithoutTrack() throws {
        var (rt, t) = Self.settledRuntime(dark: false)
        rt.update(at: t) { s, tx in
            s.dark = true
            tx.instant()
        }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let n = try Self.rowNode(rt)
        #expect(rt.color(n.nodeId, Props.FILL, fallback: n.el.background) == .black)
        #expect(rt.scene.store.trackLen == 0)
    }

    @Test("rebuilding_reuses_node_paths_and_restores_on_layout_retry")
    func rebuildingReusesNodePathsAndRestoresFocusOnLayoutRetry() throws {
        struct RetryState {
            var open: Bool = true
            var tick: UInt32 = 0
        }
        func retryView(_ s: RetryState, _ cx: inout Cx<RetryState>) -> El<RetryState> {
            let measured = cx.layoutSize(of: "box")?.x ?? 10.0
            let h = cx.layoutSize(of: "box") != nil ? measured * 0.5 : 10.0
            var sheet: El<RetryState> = row().key("sheet").w(60).h(40)
            if s.open {
                sheet = sheet
                    .child(el().key("btn").w(30).h(20).focusable(true))
                    .child(el().size(0, 0).focusReturn("anchor"))
            }
            return col()
                .wFull()
                .hFull()
                .child(
                    el()
                        .key("box")
                        .w(s.tick == 0 ? 80 : 120)
                        .h(h)
                        .child(text("\(s.tick)"))
                )
                .child(el().key("anchor").w(40).h(20).focusable(true))
                .child(sheet)
        }

        let rt = Runtime<RetryState>(
            state: RetryState(open: true, tick: 0),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            systemDark: true,
            view: retryView
        )
        var t = 0.0
        _ = rt.frame(at: t)
        let path0 = try #require(rt.flatNodes.first { $0.key == "anchor" }).path
        rt.invalidate()
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let path1 = try #require(rt.flatNodes.first { $0.key == "anchor" }).path
        #expect(path0 == path1, "steady-state rebuild preserves the node path")

        let btnPath = try #require(rt.flatNodes.first { $0.key == "btn" }).path
        rt.update(at: t) { _, tx in
            tx.focus("btn")
        }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(rt.focusedPath == btnPath)

        rt.update(at: t) { s, _ in
            s.open = false
            s.tick = 1
        }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let anchorPath = try #require(rt.flatNodes.first { $0.key == "anchor" }).path
        #expect(rt.focusedPath == anchorPath)
    }

    @Test("changing_one_sibling_skips_resting_siblings_without_drift")
    func changingOneSiblingSkipsRestingSiblingsWithoutDrift() throws {
        struct SibState {
            var active: Int
        }
        func sibView(_ s: SibState, _: inout Cx<SibState>) -> El<SibState> {
            col()
                .wFull()
                .hFull()
                .children((0..<8).map { i -> El<SibState> in
                    let fg: Color = (i == s.active) ? .white : .black
                    return el()
                        .key("r-\(i)")
                        .wFull()
                        .h(20)
                        .bg(fg)
                        .hover(fg.alpha(0.2))
                        .focusable(true)
                        .child(text("item \(i)").color(fg))
                })
        }

        let rt = Runtime<SibState>(
            state: SibState(active: 0),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            systemDark: true,
            view: sibView
        )
        var t = 0.0
        _ = rt.frame(at: t)
        while t < 2.0 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            if !rt.isAnimating { break }
        }
        rt.pointerMove(to: Vec2(20, 70), at: t) // hover row 3
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        while t < 4.0 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            if !rt.isAnimating { break }
        }

        rt.update(at: t) { s, _ in s.active = 5 }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)

        let r5 = try #require(rt.flatNodes.first { $0.key == "r-5" }).nodeId
        let r2 = try #require(rt.flatNodes.first { $0.key == "r-2" }).nodeId
        #expect(rt.scene.store.isNodeAnimating(r5), "changed sibling animates its colour")
        #expect(!rt.scene.store.isNodeAnimating(r2), "unchanged sibling stays at rest with no track")

        var k = 0
        while k < 240 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            if !rt.isAnimating { break }
            k += 1
        }

        let fresh = Runtime<SibState>(
            state: SibState(active: 5),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            systemDark: true,
            view: sibView
        )
        var ft = 0.0
        _ = fresh.frame(at: ft)
        var fk = 0
        while fk < 240 {
            ft += 1.0 / 120.0
            _ = fresh.frame(at: ft)
            if !fresh.isAnimating { break }
            fk += 1
        }

        for idx in 0..<8 {
            let key = "r-\(idx)"
            let na = try #require(rt.flatNodes.first { $0.key == key })
            let nb = try #require(fresh.flatNodes.first { $0.key == key })
            #expect(
                rt.color(na.nodeId, Props.FILL, fallback: na.el.background)
                    == fresh.color(nb.nodeId, Props.FILL, fallback: nb.el.background)
            )
        }
    }
}
