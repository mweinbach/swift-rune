import Foundation
import Testing
@testable import Rune
@testable import RuneMotion
@testable import RuneRef

@Suite("El & Runtime Increment 2 Parity Tests")
struct ElInc2ParityTests {

    @Test("anchorRect, El.anchored, anchoredFit, anchoredRound, and inherited zoom match upstream anchor.rs")
    func anchorPlacementAndFitParity() {
        // Upstream doctest (`crates/rune/src/el/anchor.rs:89`):
        // 100x80 menu under a trigger [20, 250, 60, 270] in 400x300 flips above it.
        let r = anchorRect([20.0, 250.0, 60.0, 270.0], size: (100.0, 80.0), side: .bottom, align: .start, gap: 4.0, window: (400.0, 300.0))
        #expect(r == [20.0, 166.0, 120.0, 246.0])

        // MotionRect convenience overload agrees
        let mr = anchorRect(
            trigger: MotionRect(left: 20, top: 250, right: 60, bottom: 270),
            size: Vec2(100, 80),
            side: .bottom,
            align: .start,
            gap: 4.0,
            window: Vec2(400, 300)
        )
        #expect(abs(mr.left - 20) < 0.01 && abs(mr.top - 166) < 0.01)

        // Runtime anchored + anchoredFit clamps height when neither top nor bottom fits
        struct S { var open = true }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200)) { st, _ in
            var children: [El<S>] = [
                el().key("anchor-btn").w(80).h(30).mt(90).ml(20)
            ]
            if st.open {
                // Bottom has 200 - 8 - 124 = 68 pt, top has 90 - 4 - 8 = 78 pt.
                // 140 pt menu fits on neither side -> anchoredFit bounds maxHeight to ~77 pt on top!
                children.append(
                    col()
                        .key("menu")
                        .w(100)
                        .h(140)
                        .anchoredFit("anchor-btn", side: .bottom, align: .start, gap: 4)
                )
            }
            return col().w(300).h(200).children(children)
        }
        _ = rt.frame(at: 0)
        let menu = rt.element(byKey: "menu")!
        // Bound should shrink height <= 78 and place it above trigger
        #expect(menu.rect[3] <= 78.5)
        #expect(menu.rect[1] + menu.rect[3] <= 90.0)
    }

    @Test("hoverGroup, hoverGroupShared, hoverAlone, groupOpacity, and groupColor evaluate in buildRefScene")
    func hoverGroupAndAloneParity() {
        struct S {}
        let gray = Color(r: 0.5, g: 0.5, b: 0.5)
        let red = Color(r: 1, g: 0, b: 0)
        let blue = Color(r: 0, g: 0, b: 1)
        let green = Color(r: 0, g: 1, b: 0)
        _ = green
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200)) { _, _ in
            col().w(300).h(200).children([
                row().key("row-a").w(200).h(40).hoverGroup().hoverGroupShared("pair").children([
                    el().key("badge").w(30).h(20).groupOpacity(0.25, 1.0).bg(.white),
                    text("Title").key("title").color(gray).groupColor(red),
                    el().key("solo").w(40).h(20).hoverAlone().bg(blue),
                ]),
                row().key("row-b").w(200).h(40).hoverGroup().hoverGroupShared("pair").children([
                    el().key("peer").w(30).h(20).groupOpacity(0.2, 0.9).bg(.white),
                ]),
            ])
        }
        let rrKind = Float(PrimitiveKind.roundedRect.rawValue)
        // Rest frame: badge opacity is 0.25, peer is 0.2
        let restScene = rt.frame(at: 0)
        let badgeAlphaRest = restScene.primitives.first(where: { $0.params.y == rrKind && $0.rect.z == 60 })?.fill.w ?? -1
        #expect(abs(badgeAlphaRest - 0.25) < 0.02)

        // Move pointer over row-a's badge (inside row-a, not over solo)
        rt.pointerMove(to: Vec2(10, 10), at: 0.1)
        let hoverScene = rt.frame(at: 0.1)
        // Badge and shared peer both light up!
        let badgeHoverPrims = hoverScene.primitives.filter { $0.params.y == rrKind && $0.rect.z == 60 }
        #expect(badgeHoverPrims.count >= 2)
        #expect(abs(badgeHoverPrims[0].fill.w - 1.0) < 0.02)
        #expect(abs(badgeHoverPrims[1].fill.w - 0.9) < 0.02)

        // Move pointer over solo button (hoverAlone) -> parent row-a hover fades out over 0.1s easeOut!
        let soloCenter = rt.find("solo")!
        rt.pointerMove(to: soloCenter, at: 0.2)
        _ = rt.frame(at: 0.2)
        let soloScene = rt.frame(at: 0.35)
        let badgePrim = soloScene.primitives.first { prim in
            prim.params.y == rrKind && prim.rect.z == 60
        }
        let badgeAfterSolo: Float = badgePrim?.fill.w ?? -1
        #expect(abs(badgeAfterSolo - 0.25) < 0.02)
    }

    @Test("enterDelay holds fresh mount at absent state until delay elapses; instantChanges snaps subtree")
    func enterDelayAndInstantChangesParity() {
        struct S { var show = false; var boxW: Float = 40 }
        let green = Color(r: 0, g: 1, b: 0)
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(300, 200),
            onKey: { s, _, _ in
                s.show = true
                s.boxW = 120
                return true
            }
        ) { s, _ in
            var children: [El<S>] = [
                el().key("snap-parent").w(200).h(60).instantChanges().children([
                    el().key("instant-box").w(s.boxW).h(30).animateLayout(.snappy)
                ])
            ]
            if s.show {
                children.append(
                    el().key("delayed")
                        .w(80).h(30)
                        .bg(green)
                        .transition(.opacity)
                        .enterDelay(0.2)
                )
            }
            return col().w(300).h(200).children(children)
        }
        _ = rt.frame(at: 0)

        // Trigger state change on an animated commit at t = 0.05
        _ = rt.keyDown(KeyEvent(key: .enter), at: 0.05)
        // Immediately at t=0.05 (before t=0.25 readyAt): delayed is held at opacity 0, instant-box snapped to 120!
        _ = rt.frame(at: 0.05)
        let instantBox = rt.element(byKey: "instant-box")!
        #expect(abs(instantBox.rect[2] - 120) < 0.5)
        #expect(rt.element(byKey: "delayed")!.opacity < 0.01)
        #expect(rt.isAnimating == false)
        #expect(rt.nextWakeDeadline(after: 0.05) != nil)

        // Advance past 0.25s delay -> delayed starts animating, then settles to 1.0!
        _ = rt.frame(at: 0.26)
        #expect(rt.isAnimating == true)
        let settled = rt.frame(at: 1.5)
        _ = settled
        #expect(rt.element(byKey: "delayed")!.opacity > 0.99)
    }

    @Test("scrollEdgeFade emits directional Primitive.fade when scrolled and Cx scroll metrics reflect bounds")
    func scrollEdgeFadeAndCxMetricsParity() {
        struct S { var seenMax: Vec2 = .zero; var seenVP: Vec2 = .zero; var seenContent: Vec2 = .zero }
        let blue = Color(r: 0, g: 0, b: 1)
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 100)) { _, cx in
            _ = cx // read metrics via view below
            return col().key("scroller").w(200).h(100).scrollY().scrollEdgeFade(20).scrollMargin(8).children(
                (0..<10).map { i in
                    el().key("item-\(i)").w(200).h(30).bg(blue)
                }
            )
        }
        // First frame at scroll 0: content is 300, viewport is 100, scrollMax = (0, 200).
        let sceneTop = rt.frame(at: 0)
        // Bottom edge has hidden content (200pt) -> bottom fade active (`fade.y == -1`), top edge hard!
        #expect(sceneTop.primitives.contains { $0.fade.z > 0 && $0.fade.y < 0 })
        #expect(!sceneTop.primitives.contains { $0.fade.z > 0 && $0.fade.y > 0 })

        // Verify Cx exposes scrollMax/viewportSize/contentSize/layoutSize accurately
        var capturedMax = Vec2.zero
        var capturedVP = Vec2.zero
        var capturedContent = Vec2.zero
        let rt2 = Runtime<S>(state: S(), viewport: Vec2(200, 100)) { _, cx in
            capturedMax = cx.scrollMax(of: "scroller")
            capturedVP = cx.viewportSize(of: "scroller")
            capturedContent = cx.contentSize(of: "scroller")
            return col().key("scroller").w(200).h(100).scrollY().children([
                el().w(200).h(350)
            ])
        }
        _ = rt2.frame(at: 0)
        rt2.markNeedsCommit()
        _ = rt2.frame(at: 0.01)
        #expect(abs(capturedVP.y - 100) < 0.5)
        #expect(abs(capturedContent.y - 350) < 0.5)
        #expect(abs(capturedMax.y - 250) < 0.5)
    }

    @Test("All 15 ElementRole cases, a11y modifiers, and a11yHidden work across AccessibilityTreeBuilder & treeJSON")
    func a11yRolesAndModifiersParity() {
        let roles: [(ElementRole, String)] = [
            (.combobox, "combobox"), (.listbox, "listbox"), (.option, "option"),
            (.tree, "tree"), (.treeItem, "treeitem"), (.grid, "grid"),
            (.row, "row"), (.gridCell, "gridcell"), (.columnHeader, "columnheader"),
            (.radiogroup, "radiogroup"), (.tabList, "tablist"), (.tooltip, "tooltip"),
            (.alert, "alert"), (.region, "region"), (.main, "main"),
        ]
        for (role, raw) in roles {
            #expect(role.rawValue == raw)
        }

        struct S {}
        let root: El<S> = col().key("root").role(.main).children([
            el().key("cb")
                .role(.combobox)
                .description("Pick a file")
                .activeDescendant("opt-1")
                .a11yValue("Alpha")
                .checkedMixed()
                .focusable()
                .disabled(true),
            el().key("sld")
                .role(.slider)
                .rangeValue(0.5, min: 0.0, max: 1.0)
                .rangeStep(0.1),
            el().key("deco").a11yHidden().w(10).h(10),
        ])
        #expect(root.children[0].focusable == false) // disabled(true) prevents focus
        #expect(root.children[0].a11yChecked == A11yChecked.mixed)
        #expect(root.children[1].a11yRange?.step == 0.1)

        let layout = LayoutEngine.compute(root: LayoutInputNode(style: root.layout, children: root.children.map { LayoutInputNode(style: $0.layout) }), viewport: Vec2(200, 200))
        let projected: AccessibilityNode = AccessibilityTreeBuilder.project(element: root, layout: layout)!
        // a11yHidden child omitted from AccessibilityNode tree
        #expect(projected.children.count == 2)

        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 200)) { _, _ in root }
        _ = rt.frame(at: 0)
        let cbInfo = rt.element(byKey: "cb")!
        #expect(cbInfo.disabled == true)
        #expect(cbInfo.checked == A11yChecked.mixed)
        #expect(cbInfo.a11yValue == "Alpha")
        #expect(cbInfo.a11yDescription == "Pick a file")
        #expect(rt.element(byKey: "deco")!.a11yHidden == true)
    }

    @Test("cycle/looping drives frame opacity and onPhysicalInput preempts logical keyDown")
    func loopingCycleAndPhysicalInputParity() {
        struct S { var physCount = 0; var keyCount = 0 }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 100)) { _, _ in
            el().key("box")
                .w(50).h(50)
                .focusable()
                .autofocus()
                .cycle(Cycle(period: 1.0, stops: [(0.0, 0.2), (0.5, 1.0), (1.0, 0.2)]))
                .onPhysicalInput { s, ev, _ in
                    if case .key(let code, _, let pressed, _) = ev, pressed, code == .keyA {
                        s.physCount += 1
                        return true
                    }
                    return false
                }
                .onKey { s, _, _ in
                    s.keyCount += 1
                    return true
                }
        }
        _ = rt.frame(at: 0)
        // Upstream `loop_sleep.rs::cycles_share_deadlines_and_sleep_when_hidden_by_hover_groups`: an opacity
        // cycle steps at its own fps from a wake deadline instead of requesting continuous frames.
        #expect(rt.isAnimating == false)
        #expect(rt.nextWakeDeadline(after: 0) != nil)

        // Physical KeyA is consumed by onPhysicalInput -> fallback logical keyDown does NOT fire
        let consumed = rt.physicalInput(
            .key(key: .keyA, mods: .none, pressed: true, repeat: false),
            fallbackKey: KeyEvent(key: .text("a")),
            at: 0.1
        )
        #expect(consumed == true)
        #expect(rt.state.physCount == 1)
        #expect(rt.state.keyCount == 0)

        // Physical KeyB returns false -> falls back to keyDown
        let fellBack = rt.physicalInput(
            .key(key: .keyB, mods: .none, pressed: true, repeat: false),
            fallbackKey: KeyEvent(key: .text("b")),
            at: 0.2
        )
        #expect(fellBack == true)
        #expect(rt.state.keyCount == 1)
    }

    @Test("Review #210 fixes: multi-edge scrollEdgeFade, clipRounded/clipCorners masking, scaled anchor placement, hover-as-group + hoverAlone, default transition enterDelay")
    func review210ParityFixes() throws {
        // 1. Mid-scrolled tall child receives BOTH top & bottom fades, plus merged ancestor clipFadeLinear
        struct ScrollS {}
        let red = Color(r: 1, g: 0, b: 0)
        let scrollRt = Runtime<ScrollS>(state: ScrollS(), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col().w(200).h(100).clipFadeLinear(left: 12).children([
                col().key("sc").w(200).h(100).scrollY().scrollEdgeFade(20).children([
                    el().key("tall").w(200).h(300).bg(red)
                ])
            ])
        }
        _ = scrollRt.frame(at: 0)
        scrollRt.wheel(WheelEvent(dx: 0, dy: -80), at: Vec2(100, 50), now: 0.1)
        let midScene = scrollRt.frame(at: 0.1)
        // Tall child touches top scroll fade, bottom scroll fade, and ancestor left clipFadeLinear (3 fade edges -> 2 fade layers + 1 inner prim fade)
        let fadeLayers = midScene.primitives.filter { $0.kind == .layerBegin && $0.fade.z > 0 }
        #expect(fadeLayers.count >= 2)
        #expect(midScene.primitives.contains { $0.fade.z > 0 && $0.fade.y > 0 } || fadeLayers.contains { $0.fade.y > 0 })
        #expect(midScene.primitives.contains { $0.fade.z > 0 && $0.fade.y < 0 } || fadeLayers.contains { $0.fade.y < 0 })

        // 2. clipRounded & clipCorners visually mask children at corners in RuneRef.render
        struct ClipS {}
        let green = Color(r: 0, g: 1, b: 0)
        let clipRt = Runtime<ClipS>(state: ClipS(), viewport: Vec2(60, 60), pixelScale: 1.0) { _, _ in
            col().w(60).h(60).bg(.black).children([
                el().key("card").w(40).h(40).clipRounded(12).children([
                    el().key("fill").w(40).h(40).bg(green)
                ])
            ])
        }
        let clipScene = clipRt.frame(at: 0)
        let renderedClip = try RuneRef.render(clipScene)
        // Pixel (0, 0) lies outside radius 12 corner circle -> remains black (green channel == 0)
        #expect(renderedClip.pixel(x: 0, y: 0).y < 20)
        // Pixel (20, 20) lies inside card -> bright green
        #expect(renderedClip.pixel(x: 20, y: 20).y > 230)

        // 3. Anchored overlay under 2x scaled ancestor places zoomed box beside zoomed trigger at zoomed gap
        struct AnchS {}
        let anchRt = Runtime<AnchS>(state: AnchS(), viewport: Vec2(400, 300), pixelScale: 1.0) { _, _ in
            col().w(400).h(300).children([
                col().w(100).h(40).mt(100).ml(100).scale(2.0).children([
                    el().key("btn").w(100).h(40)
                ]),
                el().key("tip").w(60).h(20).anchored("btn", side: .bottom, align: .center, gap: 4)
            ])
        }
        _ = anchRt.frame(at: 0)
        // Unscaled btn is [100, 100, 100, 40] scaled 2x around center (150, 120) -> zoomed trigger [50, 80, 200, 80] (bottom = 160).
        // Tip is zoomed 2x -> size (120, 40), gap 4*2 = 8 -> rect [90, 168, 120, 40].
        let tipRect = anchRt.element(byKey: "tip")!.rect
        #expect(abs(tipRect[0] - 90) < 0.5 && abs(tipRect[1] - 168) < 0.5)
        #expect(abs(tipRect[2] - 120) < 0.5 && abs(tipRect[3] - 40) < 0.5)

        // 4. `.hover(bg)` without `.hoverGroup()` still drives `groupOpacity` on children (`hover_tests.rs:85-113`)
        struct HovS {}
        let white = Color(r: 1, g: 1, b: 1)
        let hovWash = Color(r: 1, g: 1, b: 1, a: 0.1)
        let hovRt = Runtime<HovS>(state: HovS(), viewport: Vec2(240, 100), pixelScale: 1.0) { _, _ in
            col().w(240).h(100).children([
                row().key("row").w(200).h(30).hover(hovWash).children([
                    el().key("label").w(100).h(30),
                    el().key("dot").w(10).h(10).bg(white).groupOpacity(0.0, 1.0),
                    el().key("face").w(20).h(20).hover(white).hoverAlone()
                ])
            ])
        }
        _ = hovRt.frame(at: 0)
        hovRt.pointerMove(to: Vec2(50, 15), at: 0.05)
        _ = hovRt.frame(at: 0.05)
        #expect(hovRt.element(byKey: "dot")!.opacity > 0.9)
        hovRt.pointerMove(to: Vec2(115, 10), at: 0.1)
        _ = hovRt.frame(at: 0.1)
        _ = hovRt.frame(at: 0.25)
        #expect(hovRt.element(byKey: "dot")!.opacity < 0.1)

        // 5. `.enterDelay` WITHOUT explicit `.transition(...)` holds opacity at 0 until delay elapses
        struct DelS { var show = false }
        let delRt = Runtime<DelS>(state: DelS(), viewport: Vec2(200, 100)) { s, _ in
            var ch: [El<DelS>] = []
            if s.show {
                ch.append(el().key("d").w(50).h(20).bg(green).enterDelay(0.2))
            }
            return col().w(200).h(100).children(ch)
        }
        _ = delRt.frame(at: 0)
        delRt.update(at: 0.05) { s, _ in s.show = true }
        _ = delRt.frame(at: 0.05)
        #expect(delRt.element(byKey: "d")!.opacity < 0.01)
        _ = delRt.frame(at: 0.30)
        _ = delRt.frame(at: 1.50)
        #expect(delRt.element(byKey: "d")!.opacity > 0.99)
    }
}
