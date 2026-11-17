import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("Slice 3 El-Core & Motion Parity Tests")
struct Slice3ElCoreParityTests {

    // MARK: - 1. runtime/font_families, event_log, event_markers, frame

    @Test("runtime/font_families: Runtime.setFontFamilies, fontFamilies, and Tx.setFontFamilies")
    func runtimeAndTxFontFamilies() {
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            el().key("root").size(200, 100)
        }
        _ = rt.frame(at: 0.0)
        // Font families are process-global (`FontFamiliesRegistry`): restore them so later suites
        // (e.g. TextUnblockAllTests' pill wrap widths) measure with the default faces.
        let originalFamilies = FontFamiliesRegistry.currentFamilies()
        defer { _ = FontFamiliesRegistry.setFamilies(sans: originalFamilies.sans, mono: originalFamilies.mono) }
        rt.setFontFamilies("Inter", "JetBrains Mono")
        #expect(rt.fontFamilies == ("Inter", "JetBrains Mono"))

        rt.update(at: 0.01) { _, tx in
            tx.setFontFamilies("Helvetica Neue", "Menlo")
        }
        #expect(rt.fontFamilies == ("Helvetica Neue", "Menlo"))
    }

    @Test("runtime/event_log & event_markers: recording gating, input markers, secure key redaction, and 512/256 ring cap")
    func eventLogRecordingAndBoundedCap() {
        struct S { var edit = TextEdit("secret") }
        let rt = Runtime<S>(state: S(), viewport: Vec2(260, 220), pixelScale: 1.0) { _, _ in
            col().size(260, 220)
                .child(el().key("btn").size(80, 40).onClick { _ in })
                .child(textInput(key: "sec", \S.edit).size(120, 30).secure(true))
                .child(el().key("scroller").size(160, 80).scrollY().child(el().size(160, 300).shrink(0)))
        }
        _ = rt.frame(at: 0.0)
        rt.events.removeAll()

        // Default recordEvents = true captures pointer & wheel & key markers
        rt.pointerDown(at: Vec2(20, 20), at: 0.01)
        rt.pointerUp(at: Vec2(20, 20), at: 0.02)
        rt.pointerDown(at: Vec2(20, 20), button: .secondary, at: 0.03)
        rt.pointerUp(at: Vec2(20, 20), button: .secondary, at: 0.04)
        rt.wheel(WheelEvent(dx: 0, dy: -24, precise: true), at: Vec2(40, 90), now: 0.05)

        // Focus secure field and verify key redaction
        rt.pointerDown(at: Vec2(40, 55), at: 0.06)
        rt.pointerUp(at: Vec2(40, 55), at: 0.07)
        _ = rt.keyDown(KeyEvent(key: .text("a")), at: 0.08)

        #expect(rt.events.contains(where: { $0.hasPrefix("press ") }))
        #expect(rt.events.contains(where: { $0.hasPrefix("secondary press ") }))
        #expect(rt.events.contains(where: { $0.hasPrefix("wheel ") }))
        #expect(rt.events.contains("key [redacted]"))
        #expect(!rt.events.contains("key text(\"a\")"))

        // Gating when recordEvents = false and not tracing
        rt.events.removeAll()
        rt.recordEvents = false
        rt.isTracing = false
        rt.pointerDown(at: Vec2(20, 20), at: 0.10)
        rt.pointerUp(at: Vec2(20, 20), at: 0.11)
        #expect(rt.events.isEmpty)

        // Bounded ring cap: pushing 512 events drains oldest 256 -> count 257 on 512th/513th
        rt.recordEvents = true
        for i in 0..<520 {
            rt.logEvent("ev-\(i)")
        }
        #expect(rt.events.count <= 512)
        #expect(rt.events.last == "ev-519")
        #expect(!rt.events.contains("ev-0"))
    }

    @Test("runtime/frame: isTracing, traceChannel, traceEvent, settleAll, dispatchFocus")
    func runtimeFrameTraceSettleAndFocus() {
        struct S { var x: Float = 0; var focuses: [Bool] = [] }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 120), pixelScale: 1.0) { s, _ in
            el().key("box")
                .size(40, 40)
                .offset(s.x, 0)
                .motion(Spring(duration: 0.4, bounce: 0.0))
                .onWindowFocus { st, focused, _ in st.focuses.append(focused) }
        }
        _ = rt.frame(at: 0.0)
        rt.isTracing = true
        rt.traceChannel("fps", kind: .level, value: 120.0)
        rt.traceEvent("frame-start")
        #expect(rt.traceChannels?["fps"]?.value == 120.0)
        #expect(rt.traceEvents.contains("frame-start"))

        rt.update(at: 0.01) { s, _ in s.x = 100 }
        _ = rt.frame(at: 0.02)
        #expect((rt.presented("box")?.rect[0] ?? 0) < 90)
        rt.settleAll()
        _ = rt.frame(at: 0.03)
        #expect(abs((rt.presented("box")?.rect[0] ?? 0) - 100.0) < 0.5)

        rt.dispatchFocus(false, at: 0.04)
        rt.dispatchFocus(true, at: 0.05)
        #expect(rt.state.focuses == [false, true])
    }

    // MARK: - 2. key_paths, instant_keeps_flight, revive_settle, motion_exports, motion_trace

    @Test("key_paths: scrollIntoView slash + ambiguous first match, scrollToBottom nested, scrollToOffset nested, and offscreen virtual row")
    func keyPathsAllFourCases() {
        struct S {}
        // 1 & 4: slash key path, ambiguous bare key picks first match, and offscreen virtual row
        let rt1 = Runtime<S>(state: S(), viewport: Vec2(220, 100), pixelScale: 1.0) { _, _ in
            row().size(220, 100)
                .child(
                    col().key("a").size(100, 100).scrollY()
                        .child(el().size(100, 220).shrink(0))
                        .child(text("first").key("label").size(100, 30).shrink(0))
                )
                .child(
                    col().key("b").size(100, 100).scrollY()
                        .child(el().size(100, 220).shrink(0))
                        .child(text("second").key("label").size(100, 30).shrink(0))
                )
        }
        _ = rt1.frame(at: 0.0)
        rt1.update(at: 0.05) { _, tx in tx.scrollIntoView("b/label") }
        for i in 1...40 { _ = rt1.frame(at: 0.05 + Double(i) / 60.0) }
        let aPath = rt1.element(byKey: "a")!.path
        let bPath = rt1.element(byKey: "b")!.path
        #expect((rt1.scrollOffsets[aPath]?.y ?? 0) < 1.0)
        #expect((rt1.scrollOffsets[bPath]?.y ?? 0) > 100.0)

        // Reset and scroll bare "label" -> must hit "a" first
        rt1.update(at: 1.0) { _, tx in tx.scrollToInstant("b", x: 0, y: 0); tx.scrollIntoView("label") }
        for i in 1...40 { _ = rt1.frame(at: 1.0 + Double(i) / 60.0) }
        #expect((rt1.scrollOffsets[aPath]?.y ?? 0) > 100.0)

        // 2 & 3: nested wrap/list scrollToBottom and scrollToOffset
        let rt2 = Runtime<S>(state: S(), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col().key("wrap").size(200, 100).child(
                col().key("list").size(200, 100).scrollY()
                    .child(el().key("tall").size(200, 400).shrink(0))
            )
        }
        _ = rt2.frame(at: 0.0)
        let listPath = rt2.element(byKey: "wrap/list")!.path
        rt2.update(at: 0.05) { _, tx in tx.scrollTo("wrap/list", x: 0, y: 120) }
        for i in 1...40 { _ = rt2.frame(at: 0.05 + Double(i) / 60.0) }
        #expect(abs((rt2.scrollOffsets[listPath]?.y ?? 0) - 120.0) < 5.0)

        rt2.update(at: 1.0) { _, tx in tx.scrollToBottom("wrap/list") }
        for i in 1...40 { _ = rt2.frame(at: 1.0 + Double(i) / 60.0) }
        #expect((rt2.scrollOffsets[listPath]?.y ?? 0) > 250.0)

        // 4: offscreen virtual row reveal via multi-segment key path
        let virtRt = Runtime<S>(state: S(), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col().key("root").size(200, 100).child(
                col().key("b").size(200, 100).scrollY().virtualRows(
                    count: 50,
                    estimatedRowHeight: 24,
                    key: { _, i in "r\(i)" },
                    build: { _, i in text("row \(i)").size(200, 24) }
                )
            )
        }
        _ = virtRt.frame(at: 0.0)
        virtRt.update(at: 0.05) { _, tx in tx.scrollIntoView("b/r35") }
        for i in 1...60 { _ = virtRt.frame(at: 0.05 + Double(i) / 60.0) }
        #expect(virtRt.element(byKey: "r35") != nil)
    }

    @Test("instant_keeps_flight: width flight survives instant commit, instant snaps own changes, and settle lands running motion")
    func instantKeepsFlightAllThreeTests() {
        struct S { var wide = false; var label = "A" }
        let rt = Runtime<S>(state: S(), viewport: Vec2(240, 120), pixelScale: 1.0) { s, _ in
            col().size(240, 120)
                .child(el().key("bar").size(s.wide ? 180 : 60, 30).motion(Spring(duration: 0.4, bounce: 0.0)))
                .child(text(s.label).key("lbl").size(s.label == "A" ? 40 : 120, 20).motion(Spring(duration: 0.4, bounce: 0.0)))
        }
        _ = rt.frame(at: 0.0)

        // Start width spring
        rt.update(at: 0.01) { s, _ in s.wide = true }
        for i in 1...4 { _ = rt.frame(at: 0.01 + Double(i) / 60.0) }
        let midBar = rt.presented("bar")!.rect[2]
        #expect(midBar > 62 && midBar < 175)

        // Instant commit changes label width immediately while leaving "bar" in flight
        rt.update(at: 0.09) { s, tx in s.label = "BB"; tx.instant() }
        _ = rt.frame(at: 0.10)
        let afterInstantBar = rt.presented("bar")!.rect[2]
        #expect(afterInstantBar > midBar && afterInstantBar < 179.0, "instant commit preserves existing width flight")
        #expect(abs(rt.presented("lbl")!.rect[2] - 120.0) < 0.5, "instant commit snaps own changes")

        // tx.settle() lands motion already running
        rt.update(at: 0.12) { _, tx in tx.settle() }
        _ = rt.frame(at: 0.13)
        #expect(abs(rt.presented("bar")!.rect[2] - 180.0) < 0.5)
    }

    @Test("revive_settle: settled return mid-exit appears at rest & animated return reverses smoothly")
    func reviveSettleBothTests() {
        struct S { var visible = true }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 120), pixelScale: 1.0) { (s, _) -> El<S> in
            var root: El<S> = col().size(200, 120)
            if s.visible {
                root = root.child(el().key("card").size(80, 40).bg(Color.white).transition(.opacity))
            }
            return root
        }
        _ = rt.frame(at: 0.0)

        // Exit midway
        rt.update(at: 0.01) { s, _ in s.visible = false }
        for i in 1...6 { _ = rt.frame(at: 0.01 + Double(i) / 60.0) }
        let midExitAlpha = rt.presented("card")!.opacity
        #expect(midExitAlpha > 0.05 && midExitAlpha < 0.95)

        // Animated return mid-exit reverses without snapping back to 0 or 1, then settles to 1
        rt.update(at: 0.12) { s, tx in s.visible = true; tx.animated() }
        _ = rt.frame(at: 0.13)
        let revivedAlpha = rt.presented("card")!.opacity
        #expect(revivedAlpha > 0.05 && revivedAlpha < 0.99)
        for i in 1...30 { _ = rt.frame(at: 0.13 + Double(i) / 60.0) }
        #expect((rt.presented("card")?.opacity ?? 0.0) > 0.99)

        // Exit midway again, then settled return -> appears at rest immediately
        rt.update(at: 0.70) { s, _ in s.visible = false }
        for i in 1...6 { _ = rt.frame(at: 0.70 + Double(i) / 60.0) }
        #expect((rt.presented("card")?.opacity ?? 1.0) < 0.95)
        rt.update(at: 0.82) { s, tx in s.visible = true; tx.settle() }
        _ = rt.frame(at: 0.83)
        #expect((rt.presented("card")?.opacity ?? 0.0) > 0.99)
    }

    @Test("motion_exports & motion_trace: Rune re-exports Transition/Anim types and MotionTrace records channels and events")
    func motionExportsAndTraceParity() {
        let _: Reveal = Reveal(edge: .leading)
        let _: StepPosition = .jumpEnd
        let _: Decay = .IOS_NORMAL
        let _: Transition = .opacity
        let _: Anim<Float> = .spring(.default)
        let _: Curve = .easeInOut(0.2)
        let _: MotionEdge = .bottom
        let _: LoopMode = .pingPong

        struct S { var shifted = false }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 100), pixelScale: 1.0) { s, _ in
            el().key("item").size(40, 40).offset(s.shifted ? 60 : 0, 0).motion(Spring(duration: 0.25, bounce: 0.0))
        }
        let sharedBuf = SharedBuffer()
        let trace = MotionTrace(
            header: TraceHeader(launch: "trace-check", width: 200, height: 100, hz: 60, scale: 1),
            sharedBuffer: sharedBuf
        )
        rt.setTrace(trace)
        rt.isTracing = true
        _ = rt.frame(at: 0.0)
        rt.traceChannel("velocity", kind: .position, value: 12.5)
        rt.traceEvent("commit-shift")
        rt.update(at: 0.01) { s, _ in s.shifted = true }
        for i in 1...4 { _ = rt.frame(at: 0.01 + Double(i) / 60.0) }
        #expect(rt.traceChannels?["velocity"]?.kind == .position)
        #expect(rt.traceEvents.contains("commit-shift"))
        let taken = rt.takeTrace()
        #expect(taken != nil)
        #expect(!sharedBuf.contents().isEmpty)
    }

    // MARK: - 3. expressive_motion (all 12 tests)

    @Test("expressive_motion: scale springs + hits, instant/reduced motion, multiply scale*liveScale*pressScale, bottom origin, transition scale origin")
    func expressiveMotionScaleAndOrigin() {
        // 1 & 2. scale springs + hits follow + lands at once under reduced motion / instant tx
        struct S { var k: Float = 1.0; var hits = 0 }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            col().size(200, 200).itemsStart().p(50).child(
                el().key("a").size(100, 40).bg(Color.white)
                    .motion(Spring(duration: 0.3, bounce: 0.0))
                    .scale(s.k)
                    .onClick { st in st.hits += 1 }
            )
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { s, _ in s.k = 1.5 }
        for i in 1...5 { _ = rt.frame(at: 0.01 + Double(i) / 60.0) }
        let midW = rt.presented("a")!.rect[2]
        #expect(midW > 102 && midW < 149)

        for i in 1...60 { _ = rt.frame(at: 0.1 + Double(i) / 60.0) }
        let landed = rt.presented("a")!.rect
        #expect(abs(landed[2] - 150.0) < 1.0)
        // Hit point inside newly scaled right wing [x = 165, y = 70] (original unscaled ends at x = 150)
        rt.pointerDown(at: Vec2(165, 70), at: 1.5)
        rt.pointerUp(at: Vec2(165, 70), at: 1.51)
        #expect(rt.state.hits == 1)

        // Instant tx snaps scale immediately
        rt.update(at: 1.6) { s, tx in s.k = 1.0; tx.instant() }
        _ = rt.frame(at: 1.61)
        #expect(abs(rt.presented("a")!.rect[2] - 100.0) < 0.5)

        // Reduced motion lands scale immediately
        rt.setSystemReducedMotion(true)
        rt.update(at: 1.7) { s, _ in s.k = 1.4 }
        _ = rt.frame(at: 1.71)
        #expect(abs(rt.presented("a")!.rect[2] - 140.0) < 0.5)

        // 3. sprung scale * liveScale * pressScale multiplication
        let liveScaleBinding = Binding(live: Live<Float>(0.5))
        struct MultS { var baseScale: Float = 2.0 }
        let multRt = Runtime<MultS>(state: MultS(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            el().size(200, 200).child(
                el().key("m").pin(top: 50, left: 50).size(100, 40)
                    .scale(s.baseScale)
                    .liveScale(liveScaleBinding)
                    .pressScale(0.5)
            )
        }
        _ = multRt.frame(at: 0.0)
        // base 2.0 * live 0.5 = 1.0 -> width 100; while pressed * 0.5 -> width 50
        #expect(abs(multRt.presented("m")!.rect[2] - 100.0) < 1.0)
        multRt.pointerDown(at: Vec2(100, 70), at: 0.01)
        for i in 1...40 { _ = multRt.frame(at: 0.01 + Double(i) / 60.0) }
        #expect(multRt.presented("m")!.rect[2] < 75.0)
        multRt.pointerUp(at: Vec2(100, 70), at: 1.0)

        // 4. origin(0.5, 1.0) keeps bottom edge fixed while scale springs
        struct OrigS { var k: Float = 1.0 }
        let origRt = Runtime<OrigS>(state: OrigS(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            el().key("o").pin(top: 60, left: 50).size(100, 40)
                .origin(0.5, 1.0)
                .scale(s.k)
                .motion(Spring(duration: 0.3, bounce: 0.0))
        }
        _ = origRt.frame(at: 0.0)
        let bottomRest = origRt.presented("o")!.rect[1] + origRt.presented("o")!.rect[3]
        origRt.update(at: 0.01) { s, _ in s.k = 1.5 }
        for i in 1...10 {
            _ = origRt.frame(at: 0.01 + Double(i) / 60.0)
            let r = origRt.presented("o")!.rect
            #expect(abs((r[1] + r[3]) - bottomRest) < 1.0)
        }

        // 5. transition(.scale(0.5, anchor: Vec2(0.0, 0.5))) scales around left-center origin
        struct TrS { var show = false }
        let trRt = Runtime<TrS>(state: TrS(), viewport: Vec2(200, 200), pixelScale: 1.0) { (s, _) -> El<TrS> in
            var root: El<TrS> = el().size(200, 200)
            if s.show {
                root = root.child(
                    el().key("pop").pin(top: 50, left: 40).size(80, 40)
                        .origin(0.0, 0.5)
                        .transition(.scale(0.5, anchor: Vec2(0.0, 0.5)))
                )
            }
            return root
        }
        _ = trRt.frame(at: 0.0)
        trRt.update(at: 0.01) { s, _ in s.show = true }
        _ = trRt.frame(at: 0.02)
        let popRect = trRt.presented("pop")!.rect
        #expect(abs(popRect[0] - 40.0) < 1.5 && popRect[2] < 78.0)
    }

    @Test("expressive_motion: shadows spring and list changes settle; rotate springs, shares origin, rotated hit, nested clip, and turned exiting press child")
    func expressiveMotionShadowsAndRotation() {
        // 6 & 11. shadow geometry springs with element & shadow list length changes settle cleanly
        struct ShadS { var wide = false; var twoShadows = false }
        let shadRt = Runtime<ShadS>(state: ShadS(), viewport: Vec2(240, 200), pixelScale: 1.0) { (s, _) -> El<ShadS> in
            var node: El<ShadS> = el().key("card").pin(top: 40, left: 40)
                .size(s.wide ? 120 : 60, 40)
                .bg(Color.white)
                .motion(Spring(duration: 0.3, bounce: 0.0))
                .shadow(Shadow(x: 0, y: 4, blur: 8, spread: 0, color: Color(r: 0, g: 0, b: 0, a: 0.5)))
            if s.twoShadows {
                node = node.shadow(Shadow(x: 2, y: 6, blur: 12, spread: 2, color: Color(r: 0, g: 0, b: 0, a: 0.3)))
            }
            return el().size(240, 200).child(node)
        }
        _ = shadRt.frame(at: 0.0)
        shadRt.update(at: 0.01) { s, _ in s.wide = true }
        let midScene = shadRt.frame(at: 0.06)
        let cardMid = shadRt.presented("card")!.rect
        #expect(cardMid[2] > 65 && cardMid[2] < 115)
        if let shadowPrim = midScene.primitives.first(where: { $0.kind == .dropShadow }) {
            #expect(shadowPrim.border.z > 62 && shadowPrim.border.z < 118)
        } else {
            Issue.record("expected dropShadow primitive")
        }

        // Changing shadow list length + instant tx settles cleanly without crash or stray shadow
        shadRt.update(at: 0.2) { s, tx in s.twoShadows = true; tx.instant() }
        let twoScene = shadRt.frame(at: 0.21)
        #expect(twoScene.primitives.filter({ $0.kind == .dropShadow }).count == 2)
        shadRt.update(at: 0.3) { s, tx in s.twoShadows = false; tx.instant() }
        let oneScene = shadRt.frame(at: 0.31)
        #expect(oneScene.primitives.filter({ $0.kind == .dropShadow }).count == 1)

        // 7, 8, 9, 10, 12. rotate springs, layer turn, shares origin, hit testing, rounded clip, exiting press child stays turned
        struct RotS {
            var angle: Float = 0
            var scale: Float = 1.0
            var showChild = true
            var clicks = 0
        }
        let rotRt = Runtime<RotS>(state: RotS(), viewport: Vec2(300, 300), pixelScale: 1.0) { (s, _) -> El<RotS> in
            var card: El<RotS> = el().key("rot")
                .pin(top: 100, left: 100)
                .size(100, 20)
                .bg(Color.black)
                .origin(0.0, 0.5)
                .rotate(s.angle)
                .scale(s.scale)
                .motion(Spring(duration: 0.3, bounce: 0.0))
                .pressScale(0.9)
                .onClick { st in st.clicks += 1 }
            if s.showChild {
                card = card.child(el().key("badge").size(20, 20).bg(Color.white).transition(.opacity))
            }
            return el().size(300, 300)
                .child(
                    el().key("clipper").pin(top: 20, left: 20).size(80, 80).rounded(12).clip(true)
                        .child(el().key("inner-rot").size(60, 20).rotate(.pi * 0.25).bg(Color.white))
                )
                .child(card)
        }
        _ = rotRt.frame(at: 0.0)
        rotRt.update(at: 0.01) { s, _ in s.angle = .pi * 0.5; s.scale = 1.2 }
        let turningScene = rotRt.frame(at: 0.05)
        #expect(turningScene.primitives.contains(where: { abs($0.turn) > 0.01 }), "rotating element emits turned primitive")
        let turningRF = rotRt.renderFrame(at: 0.05)
        #expect(turningRF.instances.contains(where: { $0.params.y == KIND_LAYER && abs($0.border.y) > 0.01 }), "renderFrame opens a turned layer")

        for i in 1...60 { _ = rotRt.frame(at: 0.05 + Double(i) / 60.0) }
        // Origin at (0, 0.5) -> local (0, 10) in screen space is (100, 110); rotating +pi/2 moves box down along x~100, y in [110..230]
        #expect(rotRt.contains("rot", x: 100, y: 150))
        #expect(!rotRt.contains("rot", x: 170, y: 110))

        // Press and exit child inside turned parent keeps turned layer
        rotRt.pointerDown(at: Vec2(100, 150), at: 1.5)
        rotRt.update(at: 1.51) { s, _ in s.showChild = false }
        let exitScene = rotRt.frame(at: 1.54)
        let exitRF = rotRt.renderFrame(at: 1.54)
        #expect(exitRF.instances.contains(where: { $0.params.y == KIND_LAYER && abs($0.border.y) > 1.0 }))
        #expect(exitRF.instances.last?.params.y == KIND_LAYER_END, "exiting child draws before turned layer closes")
        rotRt.pointerUp(at: Vec2(100, 150), at: 1.56)
        #expect(rotRt.state.clicks == 1)

        // Rotated element inside rounded clip retains clip primitive
        #expect(exitScene.primitives.contains(where: { $0.kind == .layerBegin && $0.radii.x > 0 }))
    }
}
