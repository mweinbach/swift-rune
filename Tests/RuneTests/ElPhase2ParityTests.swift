import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("El & Runtime Phase 2 Parity Tests (P2-48..P2-58)")
struct ElPhase2ParityTests {

    // MARK: - P2-48: TrackedReads / trackedReads

    @Test("trackedReads records Tracked reads, detects writes, and replays reads into surrounding region (#854)")
    func trackedReadsDetectsWritesAndReplaysIntoRegion() {
        let a = Tracked(1)
        let b = Tracked(2)

        let (sum, reads) = trackedReads { a.value + 10 }
        #expect(sum == 11)
        #expect(!reads.changed())

        b.value = 20
        #expect(!reads.changed(), "unrelated Tracked write must not invalidate reads")

        a.value = 2
        #expect(reads.changed(), "writing a recorded Tracked value invalidates reads")

        let (_, outer) = trackedReads {
            let (_, inner) = trackedReads { reads.read() }
            #expect(!inner.changed())
            TrackedReads().read()
        }
        #expect(!outer.changed())
        a.touch()
        #expect(outer.changed())

        // Inside region(_:cache:build:), replaying `reads.read()` subscribes the region without re-running derivation.
        let freshA = Tracked(10)
        var derived = 0
        var derivedReads = TrackedReads()
        var regionBuilds = 0
        let cache = MemoCache()

        func renderOnce() -> (el: El<Int>, builds: Int) {
            if regionBuilds == 0 || derivedReads.changed() {
                let (val, r) = trackedReads { freshA.value * 3 }
                derived = val
                derivedReads = r
            }
            let out: El<Int> = region("tracked-reads-host", cache: cache) {
                regionBuilds += 1
                derivedReads.read()
                return text("v=\(derived)").key("lbl")
            }
            return (out, regionBuilds)
        }

        let first = renderOnce()
        #expect(first.el.plainText == "v=30")
        #expect(first.builds == 1)
        #expect(derived == 30)
        #expect((cache.getRegionIfValid(id: "tracked-reads-host") as El<Int>?) != nil)

        let cached = renderOnce()
        #expect(cached.el.plainText == "v=30")
        // In DEBUG builds, region_with re-runs `build` on a hit to detect un-tracked reads; cache entry remains valid.
        #if DEBUG
        #expect(cached.builds == 2)
        #else
        #expect(cached.builds == 1)
        #endif

        freshA.value = 11
        #expect(derivedReads.changed())
        #expect((cache.getRegionIfValid(id: "tracked-reads-host") as El<Int>?) == nil, "updating freshA invalidates enclosing region via reads.read()")
        let updated = renderOnce()
        #expect(updated.el.plainText == "v=33")
        #expect(derived == 33)
        #if DEBUG
        #expect(updated.builds == 3)
        #else
        #expect(updated.builds == 2)
        #endif

        // Also calling trackedReads { ... } directly inside `region` auto-subscribes the enclosing region.
        let innerTracked = Tracked(5)
        let _ : El<Int> = region("tracked-reads-nested", cache: cache) {
            let (v, _) = trackedReads { innerTracked.value + 1 }
            return text("n=\(v)")
        }
        #expect((cache.getRegionIfValid(id: "tracked-reads-nested") as El<Int>?) != nil)
        innerTracked.value = 6
        #expect((cache.getRegionIfValid(id: "tracked-reads-nested") as El<Int>?) == nil)
    }

    // MARK: - P2-49: El.pressColor

    @Test("El.pressColor tints descendant text, SVG icon, and shape in both renderFrame and frame() (#906)")
    func pressColorTintsIconTextAndShapeAcrossFrameAndRenderFrame() throws {
        struct S { var clicks = 0 }
        let baseInk = Color.srgb(0.9, 0.1, 0.1)
        let targetInk = Color.srgb(0.1, 0.2, 0.95)
        let svg = SVGIcon(viewBox: 16, paths: ["M2 2h12v12H2z"])
        let rectShape = Shape().fill([Vec2(0, 0), Vec2(16, 0), Vec2(16, 16), Vec2(0, 16)], color: baseInk)

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(240, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().size(240, 120).gap(6).children([
                // Ghost button with pressColor ONLY (no .press(bg)): still registers press hit and tints text/icon/shape
                row().key("ghost").size(160, 32).gap(6).pressColor(targetInk).onClick { s, _ in s.clicks += 1 }
                    .children([
                        text("Go").key("ghost-txt").color(baseInk).size(40, 20),
                        icon(svg, size: 16).key("ghost-icon").color(baseInk),
                        el().key("ghost-shape").size(16, 16).shape(rectShape),
                    ]),
                // Hover group + pressColor combo: pressColor mixes over groupColor while pressed
                row().key("grp").size(160, 32).hoverGroup().press(Color.srgb(0, 0, 0, 0.2)).pressColor(targetInk)
                    .child(text("Grp").key("grp-txt").color(baseInk).groupColor(Color.srgb(0.1, 0.9, 0.1)).size(60, 20)),
            ])
        }

        func firstGlyphBlueMinusRed(_ frame: RenderFrame, within rect: [Float]) -> Float? {
            let x0 = rect[0]
            let y0 = rect[1]
            let x1 = rect[0] + rect[2]
            let y1 = rect[1] + rect[3]
            for inst in frame.instances {
                guard PrimitiveKind(rawValue: Int(inst.params.y.rounded())) == .glyph else { continue }
                let r = inst.rect
                if r.x >= x0 - 1 && r.y >= y0 - 1 && r.x + r.z <= x1 + 1 && r.y + r.w <= y1 + 1 {
                    return inst.fill.z - inst.fill.x
                }
            }
            return nil
        }

        func firstTriangleBlueMinusRed(_ frame: RenderFrame, within rect: [Float]) -> Float? {
            for inst in frame.instances {
                guard PrimitiveKind(rawValue: Int(inst.params.y.rounded())) == .triangle else { continue }
                let v0 = Vec2(inst.uv.x, inst.uv.y)
                if v0.x >= rect[0] - 1 && v0.y >= rect[1] - 1 && v0.x <= rect[0] + rect[2] + 1 && v0.y <= rect[1] + rect[3] + 1 {
                    return inst.fill.z - inst.fill.x
                }
            }
            return nil
        }

        func sampleNonZeroPixel(_ frame: Frame, rect: [Float]) -> (r: UInt8, g: UInt8, b: UInt8)? {
            let x0 = max(0, Int(rect[0].rounded(.down)))
            let y0 = max(0, Int(rect[1].rounded(.down)))
            let x1 = min(frame.width, Int((rect[0] + rect[2]).rounded(.up)))
            let y1 = min(frame.height, Int((rect[1] + rect[3]).rounded(.up)))
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let px = frame.pixel(x: x, y: y)
                    if px.w > 20 && (px.x > 10 || px.y > 10 || px.z > 10) {
                        return (px.x, px.y, px.z)
                    }
                }
            }
            return nil
        }

        _ = rt.frame(at: 0.0)
        let rfRest = rt.renderFrame(at: 0.0)
        let cpuRest = try RuneRef.render(rt.frame(at: 0.0))
        let ghostRect = try #require(rt.element(byKey: "ghost")).rect
        let ghostTxtRect = try #require(rt.element(byKey: "ghost-txt")).rect
        let ghostShapeRect = try #require(rt.element(byKey: "ghost-shape")).rect
        let ghostIconRect = try #require(rt.element(byKey: "ghost-icon")).rect

        #expect((try #require(firstGlyphBlueMinusRed(rfRest, within: ghostTxtRect))) < -0.5)
        #expect((try #require(firstTriangleBlueMinusRed(rfRest, within: ghostShapeRect))) < -0.5)
        let iconRestPx = try #require(sampleNonZeroPixel(cpuRest, rect: ghostIconRect))
        #expect(iconRestPx.r > iconRestPx.b)
        let shapeRestPx = try #require(sampleNonZeroPixel(cpuRest, rect: ghostShapeRect))
        #expect(shapeRestPx.r > shapeRestPx.b)

        // Press down on ghost button. The tint rides the node's `P_PRESS` track, which goes down
        // on `INSTANT` (0.1 s) and back up on `SNAPPY` (0.25 s) (`hover.rs::update_interaction`),
        // so each state is sampled once its spring has landed.
        let ghostMid = Vec2(ghostRect[0] + 20, ghostRect[1] + 16)
        rt.pointerDown(at: ghostMid, at: 0.05)
        let rfEarly = rt.renderFrame(at: 0.06)
        let early = try #require(firstGlyphBlueMinusRed(rfEarly, within: ghostTxtRect))
        #expect(early > -0.75 && early < 0.8, "10 ms into INSTANT the tint is on its way, not landed: \(early)")
        let rfDown = rt.renderFrame(at: 0.5)
        let cpuDown = try RuneRef.render(rt.frame(at: 0.5))

        // ElementInfo.textColor preserves authored baseInk; rendered glyphs, shapes, and icon pixels shift to targetInk
        #expect(rt.element(byKey: "ghost-txt")?.textColor == baseInk)
        #expect((try #require(firstGlyphBlueMinusRed(rfDown, within: ghostTxtRect))) > 0.5)
        #expect((try #require(firstTriangleBlueMinusRed(rfDown, within: ghostShapeRect))) > 0.5)
        let iconDownPx = try #require(sampleNonZeroPixel(cpuDown, rect: ghostIconRect))
        #expect(iconDownPx.b > iconDownPx.r)
        let shapeDownPx = try #require(sampleNonZeroPixel(cpuDown, rect: ghostShapeRect))
        #expect(shapeDownPx.b > shapeDownPx.r)

        // Drag outside while pressed -> reverts to baseInk; drag back in -> tints again; release -> baseInk + click
        rt.pointerMove(to: Vec2(220, 100), at: 0.55)
        _ = rt.frame(at: 0.56)
        let rfOut = rt.renderFrame(at: 1.5)
        #expect((try #require(firstGlyphBlueMinusRed(rfOut, within: ghostTxtRect))) < -0.5)

        rt.pointerMove(to: ghostMid, at: 1.55)
        _ = rt.frame(at: 1.56)
        let rfBack = rt.renderFrame(at: 2.0)
        #expect((try #require(firstGlyphBlueMinusRed(rfBack, within: ghostTxtRect))) > 0.5)

        rt.pointerUp(at: ghostMid, at: 2.05)
        _ = rt.frame(at: 2.06)
        let rfUp = rt.renderFrame(at: 3.0)
        #expect((try #require(firstGlyphBlueMinusRed(rfUp, within: ghostTxtRect))) < -0.5)
        #expect(rt.state.clicks == 1)

        // Group hover + pressColor: hovered & pressed blends pressColor on top of groupColor
        let grpRect = try #require(rt.element(byKey: "grp")).rect
        let grpTxtRect = try #require(rt.element(byKey: "grp-txt")).rect
        let grpPt = Vec2(grpRect[0] + 20, grpRect[1] + 16)
        rt.pointerMove(to: grpPt, at: 3.1)
        _ = rt.frame(at: 3.11)
        rt.pointerDown(at: grpPt, at: 3.12)
        _ = rt.frame(at: 3.13)
        let rfGrpDown = rt.renderFrame(at: 3.6)
        #expect((try #require(firstGlyphBlueMinusRed(rfGrpDown, within: grpTxtRect))) > 0.5)
        rt.pointerUp(at: grpPt, at: 3.65)
    }

    // MARK: - P2-50: Middle Clicks, Touch Hold Cancel & Headless open_url

    @Test("onMiddlePress, middle onLink, touch-hold drag cancellation, and headless open_url stderr (#874)")
    func middlePressLinkTouchHoldAndHeadlessOpenUrlParity() throws {
        struct LinkHit: Equatable {
            let id: String
            let button: PointerButton
            let mods: Mods
        }
        struct S {
            var clicks = 0
            var pointerDowns = 0
            var drags = 0
            var dragCancelled = false
            var middleCount = 0
            var middleMods: Mods? = nil
            var optedMiddleClicks = 0
            var ancestorMiddle = 0
            var linkButtons: [LinkHit] = []
        }

        let targetEl: El<S> = el().key("mid-target").size(160, 32).focusable()
            .onPointerDown { (s: inout S, _, _) in s.pointerDowns += 1 }
            .onDrag { (s: inout S, _, _) in s.drags += 1 }
            .onDragEnd { (s: inout S, cancelled, _) in s.dragCancelled = cancelled }
            .onClick { (s: inout S, _) in s.clicks += 1 }
            .onMiddlePress { (s: inout S, tx) in
                s.middleCount += 1
                s.middleMods = tx.mods
            }
        let parentEl: El<S> = row().key("mid-parent").size(160, 32)
            .onMiddlePress { (s: inout S, _) in s.ancestorMiddle += 1 }
            .child(el().key("mid-child").size(120, 28).onClick { (s: inout S, _) in s.clicks += 1 })
        let optedEl: El<S> = el().key("opted").size(160, 32)
            .pointerButtons([.middle])
            .onClick { (s: inout S, tx) in
                if tx.button == .middle { s.optedMiddleClicks += 1 }
            }
            .onMiddlePress { (s: inout S, _) in s.middleCount += 1 }
        let linkEl: El<S> = text("Click link here").key("lnk").size(200, 24)
            .link(TextLink(6..<10, id: "docs", label: "Docs"))
            .onLink { (s: inout S, id, tx) in
                s.linkButtons.append(LinkHit(id: id, button: tx.button, mods: tx.mods))
            }

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(420, 260),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().size(420, 260).gap(6).children([targetEl, parentEl, optedEl, linkEl])
        }

        _ = rt.frame(at: 0.0)
        // Focus target first via Tab
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == "mid-target")

        // Middle press missing everything must NOT clear focus
        rt.pointerDown(at: Vec2(400, 240), button: .middle, mods: .none, at: 0.03)
        rt.pointerUp(at: Vec2(400, 240), button: .middle, mods: .none, at: 0.04)
        #expect(rt.focusedKey == "mid-target")

        // Middle press + release inside "mid-target": fires onMiddlePress with mods; skips onClick/onPointerDown/onDrag
        let mtRect = try #require(rt.element(byKey: "mid-target")).rect
        let mtPt = Vec2(mtRect[0] + 20, mtRect[1] + 16)
        let mods = Mods(shift: true, cmd: true)
        rt.pointerDown(at: mtPt, button: .middle, mods: mods, at: 0.05)
        #expect(rt.state.pointerDowns == 0 && rt.state.drags == 0)
        rt.pointerUp(at: mtPt, button: .middle, mods: mods, at: 0.06)
        #expect(rt.state.middleCount == 1)
        #expect(rt.state.middleMods == mods)
        #expect(rt.state.clicks == 0 && rt.state.pointerDowns == 0 && rt.state.drags == 0)

        // Middle press inside, leave outside before release -> canceled
        rt.pointerDown(at: mtPt, button: .middle, mods: .none, at: 0.07)
        rt.pointerMove(to: Vec2(390, 240), at: 0.08)
        rt.pointerUp(at: Vec2(390, 240), button: .middle, mods: .none, at: 0.09)
        #expect(rt.state.middleCount == 1)

        // Ancestor onMiddlePress catches middle click over non-opted primary-only child
        let childRect = try #require(rt.element(byKey: "mid-child")).rect
        let childPt = Vec2(childRect[0] + 20, childRect[1] + 14)
        rt.pointerDown(at: childPt, button: .middle, at: 0.10)
        rt.pointerUp(at: childPt, button: .middle, at: 0.11)
        #expect(rt.state.ancestorMiddle == 1 && rt.state.clicks == 0)

        // Opted-in pointerButtons([.middle]) + onClick dispatches onClick, NOT onMiddlePress
        let optRect = try #require(rt.element(byKey: "opted")).rect
        let optPt = Vec2(optRect[0] + 20, optRect[1] + 16)
        rt.pointerDown(at: optPt, button: .middle, at: 0.12)
        rt.pointerUp(at: optPt, button: .middle, at: 0.13)
        #expect(rt.state.optedMiddleClicks == 1 && rt.state.middleCount == 1)

        // Link receives middle press with tx.button == .middle and tx.mods
        let lnkRect = try #require(rt.element(byKey: "lnk")).rect
        let lnkPt = Vec2(lnkRect[0] + 45, lnkRect[1] + 12) // hits "link" (6..<10)
        rt.pointerDown(at: lnkPt, button: .middle, mods: Mods(alt: true), at: 0.14)
        rt.pointerUp(at: lnkPt, button: .middle, mods: Mods(alt: true), at: 0.15)
        #expect(rt.state.linkButtons.count == 1)
        #expect(rt.state.linkButtons[0].id == "docs")
        #expect(rt.state.linkButtons[0].button == .middle)
        #expect(rt.state.linkButtons[0].mods == Mods(alt: true))

        // Simultaneous buttons: primary held blocks middle press on "mid-target"
        rt.pointerDown(at: mtPt, button: .primary, at: 0.20)
        rt.pointerDown(at: mtPt, button: .middle, at: 0.21)
        rt.pointerUp(at: mtPt, button: .middle, at: 0.22)
        #expect(rt.state.middleCount == 1)
        rt.pointerUp(at: mtPt, button: .primary, at: 0.23)
        #expect(rt.state.clicks == 1)

        // Touch long-press cancellation: cancelPointerForTouchHold cancels active drag without click
        let clicksBeforeHold = rt.state.clicks
        rt.pointerDown(at: mtPt, button: .primary, at: 0.30)
        #expect(rt.state.drags >= 1)
        rt.cancelPointerForTouchHold(at: 0.80)
        #expect(rt.state.dragCancelled == true)
        #expect(rt.pressedPath == nil)
        #expect(rt.state.clicks == clicksBeforeHold)

        // HeadlessRunner open_url stderr output
        let opener = UrlOpener(headless: true)
        _ = try opener.open("https://example.com/a")
        #expect(opener.takeRequests().map(\.url) == ["https://example.com/a"])
        #expect(opener.takeRequests().isEmpty)

        let pipe = Pipe()
        let openApp = App(title: "OpenUrlStderr", size: Vec2(100, 60), state: 0) { _, _ in
            el().key("btn").size(100, 60).onClick { _, tx in _ = try? tx.openURL("https://rune.dev/headless") }
        }
        _ = try HeadlessRunner.runWithHooks(
            spec: openApp.intoSpec(),
            args: ToolingArgs.parse([
                "--force-cpu", "--scale", "1",
                "--script", "[{\"t\":0.01,\"press\":[20,20],\"frames\":1}]",
            ]),
            standardError: pipe.fileHandleForWriting
        )
        pipe.fileHandleForWriting.closeFile()
        let errText = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(errText.contains("rune: open_url https://rune.dev/headless (headless: not opened)"))
    }

    // MARK: - P2-51: Pressed Look for Middle and Secondary Buttons

    @Test("Middle and secondary presses show press tint on primary target until release or blur (#890)")
    func middleAndSecondaryPressTintTargetUntilReleaseOrFocusLoss() throws {
        struct S { var clicks = 0 }
        let baseBg = Color.srgb(0.2, 0.2, 0.2)
        let pressBg = Color.srgb(0.9, 0.1, 0.1, 0.8)
        let pressInk = Color.srgb(0.1, 0.9, 0.2)

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(240, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            row().size(240, 120)
                .child(
                    el().key("btn").size(100, 40).bg(baseBg).press(pressBg).pressColor(pressInk)
                        .pressScale(0.92)
                        .onClick { s, _ in s.clicks += 1 }
                        .child(text("Tap").key("lbl").color(.white).size(60, 20))
                )
        }

        _ = rt.frame(at: 0.0)
        let btnRect = try #require(rt.element(byKey: "btn")).rect
        let insidePt = Vec2(btnRect[0] + 20, btnRect[1] + 20)
        let outsidePt = Vec2(200, 100)

        // 1. Secondary down shows pressed look on primary target; moving outside hides it; secondary up clears tint
        rt.pointerDown(at: insidePt, button: .secondary, at: 0.02)
        #expect(rt.pressedTint?.button == .secondary)
        #expect(rt.pressedTint?.path.hasSuffix("btn") == true)
        _ = rt.frame(at: 0.03)
        #expect(rt.element(byKey: "btn")?.press == 1.0)
        _ = rt.frame(at: 0.25)
        #expect((rt.element(byKey: "btn")?.fill.r ?? 0) > baseBg.r + 0.1)

        rt.pointerMove(to: outsidePt, at: 0.26)
        _ = rt.frame(at: 0.27)
        #expect(rt.element(byKey: "btn")?.press == 0.0)

        rt.pointerMove(to: insidePt, at: 0.28)
        _ = rt.frame(at: 0.29)
        #expect(rt.element(byKey: "btn")?.press == 1.0)

        rt.pointerUp(at: insidePt, button: .secondary, at: 0.30)
        #expect(rt.pressedTint == nil)
        _ = rt.frame(at: 0.31)
        #expect(rt.element(byKey: "btn")?.press == 0.0)
        #expect(rt.state.clicks == 0, "secondary tint must not click button")

        // 2. Middle down shows pressed tint on primary-only button, without blocking primary when released
        rt.pointerDown(at: insidePt, button: .middle, at: 0.40)
        #expect(rt.pressedTint?.button == .middle)
        _ = rt.frame(at: 0.41)
        #expect(rt.element(byKey: "btn")?.press == 1.0)
        rt.pointerUp(at: insidePt, button: .middle, at: 0.42)
        #expect(rt.pressedTint == nil)
        _ = rt.frame(at: 0.43)
        #expect(rt.element(byKey: "btn")?.press == 0.0)

        // 3. Primary press held + secondary down/up leaves primary held intact
        rt.pointerDown(at: insidePt, button: .primary, at: 0.50)
        rt.pointerDown(at: insidePt, button: .secondary, at: 0.51)
        #expect(rt.pressedTint == nil, "primary hold keeps secondary from taking tint")
        rt.pointerUp(at: insidePt, button: .secondary, at: 0.52)
        #expect(rt.pressedPath != nil && rt.pressedButton == .primary)
        rt.pointerUp(at: insidePt, button: .primary, at: 0.53)
        #expect(rt.state.clicks == 1)

        // 4. Window focus loss clears pressedTint
        rt.pointerDown(at: insidePt, button: .secondary, at: 0.60)
        #expect(rt.pressedTint != nil)
        rt.windowFocus(false, at: 0.61)
        #expect(rt.pressedTint == nil)
    }

    // MARK: - P2-52 & P2-53: Memo Live Reuse & Memo Holding VirtualRows

    @Test("Memo subtree with Live bindings reuses flattened nodes and clears liveSeenSeq on tx.settle() (#843)")
    func memoSubtreeWithLiveReusesAndClearsLatchesOnSettle() throws {
        struct S {
            var tick: Int = 0
            var colorLive: Live<Color>
        }
        var memoBuilds = 0
        let initial = S(tick: 0, colorLive: Live<Color>(Color.srgb(1, 0, 0)))

        let rt = Runtime<S>(
            state: initial,
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().size(200, 100).children([
                text("tick:\(s.tick)").key("hdr"),
                memo("live-card", deps: 0) {
                    memoBuilds += 1
                    return el().key("live-box").size(80, 40)
                        .liveFill(s.colorLive.smooth(Spring(duration: 0.5, bounce: 0.0)))
                },
            ])
        }

        _ = rt.frame(at: 0.0)
        #expect(memoBuilds == 1)

        // Unrelated state commit reuses the flattened memo subtree with its live binding intact.
        rt.state.colorLive.set(Color.srgb(0, 0, 1))
        rt.update(at: 0.02) { s, _ in s.tick = 1 }
        _ = rt.frame(at: 0.03)
        #expect(memoBuilds == 1, "memo with liveFill reuses its cached subtree")
        // `memo` keys its subtree with the memo id, replacing the inner key (upstream `memo.rs::keyed`).
        let midFill = try #require(rt.element(byKey: "live-card")).fill
        #expect(midFill.r > 0.01 && midFill.b < 0.99, "liveFill should still be transitioning midway")

        // tx.settle() clears liveSeenSeq on reused memo nodes so the live value snaps cleanly.
        rt.state.colorLive.set(Color.srgb(0, 1, 0))
        rt.update(at: 0.05) { s, tx in
            s.tick = 2
            tx.settle()
        }
        _ = rt.frame(at: 0.06)
        #expect(memoBuilds == 1)
        let settledFill = try #require(rt.element(byKey: "live-card")).fill
        #expect(settledFill.g > 0.95 && settledFill.r < 0.05 && settledFill.b < 0.05, "tx.settle() clears liveSeenSeq on reused memo node")
    }

    @Test("Memo/region holding virtualRows reuses row cache when window holds and rebuilds on Tracked change (#845)")
    func memoHoldingVirtualRowsReusesCacheAndInvalidatesOnTrackedChange() {
        let row0Tag = Tracked("A")
        var listMemoBuilds = 0
        var rowBuilds = [Int: Int]()
        var rowCardMemoBuilds = [Int: Int]()

        struct S { var dummy = 0 }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 80),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            let listMemo: El<S> = region("vlist-region") {
                listMemoBuilds += 1
                return col().key("scroll").size(200, 80).scrollY()
                    .virtualRows(
                        count: 40,
                        estimatedRowHeight: 40,
                        key: { _, i in "row-\(i)" }
                    ) { _, i in
                        rowBuilds[i, default: 0] += 1
                        let suffix = (i == 0) ? row0Tag.value : "B"
                        return memo("row-\(i)-card", deps: suffix) {
                            rowCardMemoBuilds[i, default: 0] += 1
                            return text("row \(i) \(suffix)").size(200, 40)
                        }.key("row-\(i)")
                    }
            }
            return col().size(200, 80)
                .child(text("dummy \(s.dummy)").key("hdr").size(200, 0))
                .child(listMemo)
        }

        // Settle initial incremental virtual overscan fill passes before checking steady-state reuse.
        var t = 0.0
        for _ in 0..<24 {
            _ = rt.frame(at: t)
            if !rt.lastVirtualFillWanted && !rt.virtualFillNeedsCommit { break }
            t += 0.05
        }
        #expect(!rt.lastVirtualFillWanted)
        let memoBuildsAfterSettle = rt.memo.builds
        let r0BuildsBefore = rowBuilds[0] ?? 0
        let r1BuildsBefore = rowBuilds[1] ?? 0
        let r0CardBefore = rowCardMemoBuilds[0] ?? 0
        #expect(r0BuildsBefore >= 1)
        #expect(r0CardBefore == 1)

        // Real `.rebuild` commit mutating outer State (`dummy += 1`) while `region` hits cache:
        // list + mounted rows + nested row memos all stay cached across multiple rebuilds.
        let viewCalls0 = rt.viewCallCount
        t += 0.05
        rt.update(at: t) { s, _ in s.dummy += 1 }
        _ = rt.frame(at: t)
        #expect(rt.viewCallCount > viewCalls0, "outer state mutation must trigger a real .rebuild view pass")
        #expect(rt.memo.builds == memoBuildsAfterSettle, "region holding virtualRows and nested row memos stay cached on .rebuild")
        #expect(rowBuilds[0] == r0BuildsBefore, "rows stay cached on .rebuild when inside a reused region")
        #expect(rowBuilds[1] == r1BuildsBefore)
        #expect(rowCardMemoBuilds[0] == r0CardBefore, "nested row memo survives .rebuild without eviction")

        // Second consecutive `.rebuild` verifies `touchEntries` kept the nested row memo alive past `keepSince`.
        t += 0.05
        rt.update(at: t) { s, _ in s.dummy += 1 }
        _ = rt.frame(at: t)
        #expect(rt.memo.builds == memoBuildsAfterSettle)
        #expect(rowBuilds[0] == r0BuildsBefore)
        #expect(rowCardMemoBuilds[0] == r0CardBefore)

        // Mutating row0Tag (Tracked read inside row 0 during CachedVirtualRow build) invalidates only row 0 on `.rebuild`.
        row0Tag.value = "A2"
        t += 0.05
        rt.update(at: t) { s, _ in s.dummy += 1 }
        _ = rt.frame(at: t)
        #expect(rt.memo.builds == memoBuildsAfterSettle + 1, "only row 0 nested memo misses; listMemo stays cached")
        #expect((rowBuilds[0] ?? 0) == r0BuildsBefore + 1, "row 0 Tracked write invalidates row 0 cache")
        #expect(rowBuilds[1] == r1BuildsBefore, "sibling row 1 stays cached when only row 0 Tracked changed")
        #expect((rowCardMemoBuilds[0] ?? 0) == r0CardBefore + 1, "row 0 nested memo updates for A2")
        #expect(rt.element(byKey: "row-0")?.text == "row 0 A2")

        // Changing the mounted window (`scrollToBottomInstant`) disables whole-window reuse and builds newly entering rows.
        t += 0.05
        rt.update(at: t) { s, tx in
            s.dummy += 1
            tx.scrollToBottomInstant("scroll")
        }
        _ = rt.frame(at: t)
        #expect((rowBuilds[39] ?? 0) >= 1, "scrolling window mounts new offscreen rows")
        _ = listMemoBuilds
    }

    @Test("Rebuild commit without a reused region rebuilds virtual rows instead of reusing stale row closures (#845)")
    func rebuildWithoutReusableRegionRebuildsMountedVirtualRows() {
        struct S { var label = "v1" }
        var row0Builds = 0
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 80),
            pixelScale: 1.0,
            systemDark: true
        ) { state, _ in
            col().key("scroll").size(200, 80).scrollY()
                .virtualRows(
                    count: 20,
                    estimatedRowHeight: 20,
                    key: { _, i in "row-\(i)" }
                ) { s, i in
                    if i == 0 { row0Builds += 1 }
                    return text("\(s.label)-\(i)").key("row-\(i)").size(200, 20)
                }
        }

        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 0.01)
        let buildsBefore = row0Builds
        #expect(buildsBefore >= 1)
        #expect(rt.element(byKey: "row-0")?.text == "v1-0")

        rt.update(at: 0.02) { s, _ in s.label = "v2" }
        _ = rt.frame(at: 0.02)
        #expect(row0Builds > buildsBefore, "virtualRows outside a reused region must rebuild on .rebuild")
        #expect(rt.element(byKey: "row-0")?.text == "v2-0")
    }

    // MARK: - P2-54 & P2-55: VirtualListState.unfilled Overlap + pinnedRows = 32

    @Test("VirtualListState.unfilled counts only missing overscan rows across ranges and when pinned (#368, #380)")
    func virtualListUnfilledOverlapAndPinnedRows32Parity() {
        #expect(VirtualListState.pinnedRows == 32)

        // P2-54: Non-pinned unfilled across all 0...100 ranges & disjoint windows after jump
        let vl = VirtualListState(defaultEstimate: 20, gap: 0, overscanPixels: 40, overscanCount: 1)
        let keys = (0..<100).map { "r\($0)" }
        vl.setKeys(keys)
        vl.setMountedRangeForTesting(0..<0, viewportHeight: 40.0)
        // offset 1080 with viewport 40 => overscan [1000, 1200) => rows 50..<60
        let offset: Float = 1080.0
        let wanted = 50..<60
        for a in 0...100 {
            for b in a...100 {
                vl.setMountedRangeForTesting(a..<b)
                let mounted = max(0, min(b, wanted.upperBound) - max(a, wanted.lowerBound))
                let missing = wanted.count - mounted
                #expect(vl.unfilled(offset: offset, pinned: false) == missing, "range \(a)..<\(b)")
            }
        }
        vl.setMountedRangeForTesting(0..<10)
        #expect(vl.unfilled(offset: offset, pinned: false) == 10)
        vl.setMountedRangeForTesting(90..<100)
        #expect(vl.unfilled(offset: offset, pinned: false) == 10)

        // P2-55: Pinned unfilled wants overscan at maxOffset or last PINNED_ROWS (32) when fewer
        let cases: [(viewport: Float, wanted: Range<Int>)] = [
            (40.0, 68..<100),   // end overscan [1880, 2000) is 6 rows < 32 => clamped to 68..<100
            (300.0, 55..<100),  // maxOff = 1700 => overscan [1100, 2600) => 55..<100
        ]
        for (vp, want) in cases {
            vl.setMountedRangeForTesting(0..<0, viewportHeight: vp)
            for a in 0...100 {
                for b in a...100 {
                    vl.setMountedRangeForTesting(a..<b)
                    let mounted = max(0, min(b, want.upperBound) - max(a, want.lowerBound))
                    let missing = want.count - mounted
                    #expect(vl.unfilled(offset: 0.0, pinned: true) == missing, "vp=\(vp) range=\(a)..<\(b)")
                }
            }
        }
        vl.setMountedRangeForTesting(0..<10, viewportHeight: 40.0)
        #expect(vl.unfilled(offset: 0.0, pinned: true) == 32)
    }

    // MARK: - P2-56, P2-57, P2-58: Selection Edge Scroll AtEnd, Shrink, and StickBottom

    private struct EdgeListState {
        var rows: Int = 30
        var virtualRows: Bool = false
        var stickBottom: Bool = false
        var shortRow10: Bool = false
    }

    private func makeEdgeListRuntime(_ initial: EdgeListState) -> Runtime<EdgeListState> {
        Runtime<EdgeListState>(
            state: initial,
            viewport: Vec2(300, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            func makeRow(_ i: Int) -> El<EdgeListState> {
                let h: Float = (s.shortRow10 && i == 10) ? 12.0 : 24.0
                return text(String(format: "row %02d", i))
                    .key("r\(i)")
                    .font(TextStyle(size: 14, weight: 400))
                    .wFull()
                    .h(h)
                    .selectable()
            }
            var list: El<EdgeListState> = col().key("list").wFull().selectionGroup()
            if s.virtualRows {
                list = list.virtualRows(count: s.rows, estimatedRowHeight: 24.0, key: { _, i in "r\(i)" }) { _, i in
                    makeRow(i)
                }
            } else {
                list = list.children((0..<s.rows).map { makeRow($0) })
            }
            return col().key("root").size(300, 120)
                .child(col().key("scroll").wFull().h(120).scrollY(stickBottom: s.stickBottom).child(list))
        }
    }

    private func holdBelowEdgeList(_ rt: Runtime<EdgeListState>, atStart startTime: inout Double) {
        for _ in 0..<60 {
            startTime += 1.0 / 60.0
            _ = rt.frame(at: startTime)
            if !rt.needsCommit && !rt.isAnimating { break }
        }
        // Press inside the viewport even when its first mounted row is clipped by sticky scrolling.
        rt.pointerDown(at: Vec2(2, 20), at: startTime)
        startTime += 1.0 / 60.0
        _ = rt.frame(at: startTime)
        rt.pointerMove(to: Vec2(150, 520), at: startTime)
        for _ in 0..<600 {
            if !rt.hasActiveSelectableEdgeScroll { break }
            startTime += 1.0 / 60.0
            _ = rt.frame(at: startTime)
        }
        // Extra settle frames for layout/selection sync
        for _ in 0..<4 {
            startTime += 1.0 / 60.0
            _ = rt.frame(at: startTime)
        }
    }

    @Test("Selection edge scroll rests .atEnd and resumes when rows arrive in plain & virtual lists (r365)")
    func selectionEdgeScrollResumesWhenRowsArriveForPlainAndVirtualLists() throws {
        for useVirtual in [false, true] {
            let rt = makeEdgeListRuntime(EdgeListState(rows: 30, virtualRows: useVirtual))
            var t = 0.0
            holdBelowEdgeList(rt, atStart: &t)

            let scrollPath = try #require(rt.element(byKey: "scroll")).path
            let maxBefore = try #require(rt.scrollMaxExtents[scrollPath]?.y)
            let offBefore = rt.scrollOffsets[scrollPath]?.y ?? 0
            #expect(abs(offBefore - maxBefore) < 0.5)
            if case .atEnd = rt.selectionState.edgeScroll {} else {
                Issue.record("Expected .atEnd after scrolling to bottom (virtual=\(useVirtual)), got \(rt.selectionState.edgeScroll)")
            }
            #expect(rt.nextSelectableEdgeScrollWakeDeadline(after: t) == nil)
            #expect(rt.selectedText()?.contains("row 29") == true)

            // Append 15 rows -> extent grows -> edge scroll wakes & scrolls to new end, extending selection
            rt.update(at: t) { s, _ in s.rows += 15 }
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            for _ in 0..<600 {
                if !rt.hasActiveSelectableEdgeScroll { break }
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
            }
            for _ in 0..<4 {
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
            }

            let maxAfter = try #require(rt.scrollMaxExtents[scrollPath]?.y)
            let offAfter = rt.scrollOffsets[scrollPath]?.y ?? 0
            #expect(maxAfter > maxBefore + 10)
            #expect(abs(offAfter - maxAfter) < 0.5)
            #expect(rt.selectedText()?.contains("row 44") == true, "selection should include newly arrived rows (virtual=\(useVirtual))")
        }
    }

    @Test("Selection edge scroll stays stopped after release, Escape, moving inside, or window blur (r365)")
    func selectionEdgeScrollDoesNotResumeAfterReleaseEscapeInsideOrWindowBlur() throws {
        let stops: [(String, (Runtime<EdgeListState>, Double) -> Void)] = [
            ("release", { rt, t in rt.pointerUp(at: Vec2(150, 520), at: t) }),
            ("escape", { rt, t in _ = rt.keyDown(KeyEvent(key: .escape), at: t) }),
            ("inside", { rt, t in rt.pointerMove(to: Vec2(150, 60), at: t) }),
            ("blur", { rt, t in rt.windowFocus(true, at: t); rt.windowFocus(false, at: t + 0.005) }),
        ]
        for useVirtual in [false, true] {
            for (name, stop) in stops {
                let rt = makeEdgeListRuntime(EdgeListState(rows: 30, virtualRows: useVirtual))
                var t = 0.0
                holdBelowEdgeList(rt, atStart: &t)
                stop(rt, t)
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
                #expect(rt.selectionState.edgeScroll == .idle, "\(name) virtual=\(useVirtual)")

                let scrollPath = try #require(rt.element(byKey: "scroll")).path
                let offsetBefore = rt.scrollOffsets[scrollPath]?.y ?? 0
                let selBefore = rt.selectedText()

                rt.update(at: t) { s, _ in s.rows += 15 }
                for _ in 0..<10 {
                    t += 1.0 / 60.0
                    _ = rt.frame(at: t)
                }
                let offsetAfter = rt.scrollOffsets[scrollPath]?.y ?? 0
                #expect(abs(offsetAfter - offsetBefore) < 0.5, "\(name) virtual=\(useVirtual) must not resume scrolling")
                #expect(rt.selectedText() == selBefore, "\(name) virtual=\(useVirtual) must not extend selection")
            }
        }
    }

    @Test("List shrink ends resting edge-scroll wait; stickBottom extends selection onto new rows (r365, r383)")
    func selectionEdgeScrollShrinkStopsWaitAndStickBottomExtends() throws {
        // P2-57: Shrink ends wait
        do {
            let rt = makeEdgeListRuntime(EdgeListState(rows: 30, virtualRows: false))
            var t = 0.0
            holdBelowEdgeList(rt, atStart: &t)
            let scrollPath = try #require(rt.element(byKey: "scroll")).path
            let maxBefore = try #require(rt.scrollMaxExtents[scrollPath]?.y)

            rt.update(at: t) { s, _ in s.shortRow10 = true }
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            let maxShrunk = try #require(rt.scrollMaxExtents[scrollPath]?.y)
            #expect(maxShrunk < maxBefore)
            #expect(rt.selectionState.edgeScroll == .idle, "shrinking list clears .atEnd wait")

            let offShrunk = rt.scrollOffsets[scrollPath]?.y ?? 0
            let selShrunk = rt.selectedText()
            rt.update(at: t) { s, _ in s.rows += 15 }
            for _ in 0..<10 {
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
            }
            #expect(abs((rt.scrollOffsets[scrollPath]?.y ?? 0) - offShrunk) < 0.5)
            #expect(rt.selectedText() == selShrunk)
        }

        // P2-58: stickBottom follows newly added rows and extends held selection onto them
        do {
            let rt = makeEdgeListRuntime(EdgeListState(rows: 30, virtualRows: true, stickBottom: true))
            var t = 0.0
            holdBelowEdgeList(rt, atStart: &t)
            let scrollPath = try #require(rt.element(byKey: "scroll")).path
            #expect(rt.wasPinnedToBottom.contains(scrollPath))
            let before = try #require(rt.selectionState.coordinator.phase.selection)
            #expect(before.far?.path.hasSuffix("/@r29") == true)
            #expect(rt.selectionState.isDraggingSelection)
            let oldEnd = try #require(rt.scrollMaxExtents[scrollPath]?.y)
            #expect(rt.selectionState.edgeScroll == .atEnd(scrollPath: scrollPath, max: Double(oldEnd)))

            rt.update(at: t) { s, _ in s.rows += 15 }
            for _ in 0..<60 {
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
            }
            let maxAfter = try #require(rt.scrollMaxExtents[scrollPath]?.y)
            let offAfter = rt.scrollOffsets[scrollPath]?.y ?? 0
            #expect(abs(offAfter - maxAfter) < 0.5)
            #expect(rt.selectedText()?.contains("row 44") == true)
            let after = try #require(rt.selectionState.coordinator.phase.selection)
            #expect(after.path == before.path && after.anchor == before.anchor)
            #expect(after.far?.path.hasSuffix("/@r44") == true && after.focus == "row 44".utf8.count)
            #expect(rt.selectionState.isDraggingSelection)
            #expect(rt.nextSelectableEdgeScrollWakeDeadline(after: t) == nil)
        }
    }
}
