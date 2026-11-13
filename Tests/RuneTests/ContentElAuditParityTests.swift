import Testing
@testable import Rune
@testable import RuneMotion

@Suite("Content El Audit Parity Tests (L1694, L638, L603, L644)")
@MainActor
struct ContentElAuditParityTests {

    // MARK: - L1694: src/runtime/tests/springs.rs:72 motion_curve_moves_layout_on_a_tween

    @Test("springs.rs: motion_curve moves layout on a tween and yields to Spring")
    func motionCurveMovesLayoutOnATween() {
        func run(_ set: (inout Tx) -> Void) -> [Float] {
            let rt = Runtime<Float>(
                state: 100.0,
                viewport: Vec2(200.0, 300.0),
                pixelScale: 1.0,
                systemDark: true
            ) { h, _ in
                col().size(200.0, 300.0)
                    .child(el().key("card").w(100.0).h(h))
            }
            var t = 0.0
            _ = rt.frame(at: t)
            rt.update(at: t) { x, tx in
                x = 200.0
                set(&tx)
            }
            _ = rt.frame(at: t)
            var hs: [Float] = []
            hs.reserveCapacity(60)
            for _ in 0..<60 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
                let h = rt.element(byKey: "card")?.rect[3] ?? -1.0
                hs.append(h)
            }
            return hs
        }

        let linear = run { tx in tx.motionCurve(Curve.linear(0.4)) }
        #expect(abs(linear[23] - 150.0) < 3.0, "linear midpoint at index 23 was \(linear[23])")
        #expect(abs(linear[47] - 200.0) < 0.01, "linear landing at index 47 was \(linear[47])")

        let spring = run { tx in tx.motion(Spring(duration: 0.4, bounce: 0.0)) }
        #expect(abs(spring[23] - linear[23]) > 3.0, "a spring is not the tween: spring=\(spring[23]), linear=\(linear[23])")

        let curveSpring = run { tx in tx.motionCurve(Anim<Float>(curve: .spring(Spring(duration: 0.4, bounce: 0.0)))) }
        #expect(curveSpring == spring)

        let overridden = run { tx in
            tx.motionCurve(Curve.linear(0.4))
            tx.motion(Spring(duration: 0.4, bounce: 0.0))
        }
        #expect(overridden == spring)
    }

    // MARK: - L638: tests/offset_raise.rs:232 a_live_only_drag_cannot_make_another_handlers_commit_instant

    @Test("offset_raise.rs: a live_only drag cannot make another handler's commit instant")
    func aLiveOnlyDragCannotMakeAnotherHandlersCommitInstant() {
        struct S {
            var shift: Float = 0.0
        }

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200.0, 200.0),
            pixelScale: 1.0,
            systemDark: true,
            onKey: { s, _, tx in
                s.shift = 40.0
                tx.motion(Spring(duration: 0.6, bounce: 0.0))
                return true
            },
            view: { s, _ in
                col().wFull().hFull()
                    .child(el().size(100.0, 40.0).onDrag { _, drag, tx in
                        if drag.delta != .zero { tx.liveOnly() }
                    })
                    .child(el().key("other").size(100.0, 40.0).offset(0.0, s.shift).animateLayout(Spring(duration: 0.3, bounce: 0.0)))
            }
        )
        rt.checkLiveOnly(false)
        _ = rt.frame(at: 0.0)
        rt.pointerDown(at: Vec2(20.0, 20.0), at: 0.0)
        _ = rt.frame(at: 0.0)
        rt.pointerMove(to: Vec2(20.0, 30.0), at: 0.0)
        _ = rt.keyDown(KeyEvent(key: .enter), at: 0.0)
        _ = rt.frame(at: 1.0 / 60.0)

        let other = rt.element(byKey: "other")
        #expect(other != nil)
        let shift = (other?.rect[1] ?? 0.0) - 40.0
        #expect(shift > 0.0 && shift < 10.0, "the key's spring must survive a live-only drag: shift=\(shift)")
        #expect(rt.liveOnlyEvents == 1)
    }

    // MARK: - L603: tests/batch_c.rs:63 features_affect_shaping_and_have_separate_cache_entries

    @Test("batch_c.rs: features affect shaping and have separate cache entries")
    func featuresAffectShapingAndHaveSeparateCacheEntries() {
        let system = TextSystem()
        let style = TextStyle(size: 24.0, weight: 400.0)

        let missesBefore = system.shapeMissCount
        _ = system.shape(text: "111111", spans: nil, style: style, maxWidth: nil, pixelScale: 1.0, emitGlyphs: true)
        let missesAfterPlain = system.shapeMissCount
        #expect(missesAfterPlain == missesBefore + 1)

        // Different OpenType features must take a separate cache entry (`!ptr_eq`)
        _ = system.shape(text: "111111", spans: nil, style: style.features("'tnum' 1"), maxWidth: nil, pixelScale: 1.0, emitGlyphs: true)
        let missesAfterTabular = system.shapeMissCount
        #expect(missesAfterTabular == missesAfterPlain + 1)

        // Calling again with plain style must hit the plain cache entry (`ptr_eq`)
        _ = system.shape(text: "111111", spans: nil, style: style, maxWidth: nil, pixelScale: 1.0, emitGlyphs: true)
        #expect(system.shapeMissCount == missesAfterTabular)

        // Measure widths under tabular vs proportional numerals
        let tnum = style.features("'tnum' 1")
        let tnum1 = system.measure("111111", style: tnum, maxWidth: nil, pixelScale: 1.0)
        let tnum0 = system.measure("000000", style: tnum, maxWidth: nil, pixelScale: 1.0)
        #expect(tnum1.x == tnum0.x, "tnum '111111' (\(tnum1.x)) vs '000000' (\(tnum0.x))")

        let pnum = style.features("'pnum' 1")
        let pnum1 = system.measure("111111", style: pnum, maxWidth: nil, pixelScale: 1.0)
        let pnum0 = system.measure("000000", style: pnum, maxWidth: nil, pixelScale: 1.0)
        #expect(pnum1.x != pnum0.x, "pnum '111111' (\(pnum1.x)) vs '000000' (\(pnum0.x)) must differ")

        // Hashing text + style must distinguish OpenType features
        let ss01Style = style.features("'ss01' 1")
        #expect(ss01Style != style)
        #expect(TextInkCache.key(text: "0", style: ss01Style) != TextInkCache.key(text: "0", style: style))
    }

    // MARK: - L644: tests/row_enter.rs:118 rows_scrolled_into_a_nested_virtual_list_mount_settled

    @Test("row_enter.rs: rows scrolled into a nested virtual list mount settled")
    func rowsScrolledIntoANestedVirtualListMountSettled() throws {
        let rt = Runtime<Void>(
            state: (),
            viewport: Vec2(400.0, 320.0),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            var inner: El<Void> = col().key("inner-stack").wFull().growth(GrowthSpec()).virtualize(40.0)
            for i in 0..<80 {
                let row: El<Void> = col().key("i\(i)").wFull().h(40.0)
                    .transition(Transition.offset(x: 0.0, y: 12.0).combined(with: Transition.opacity))
                    .child(text("inner \(i)"))
                inner = inner.child(row)
            }
            let innerScroll: El<Void> = col().key("inner").wFull().h(150.0)
                .scroll(ScrollSpec(stickBottom: true))
                .child(inner)
            let outer: El<Void> = col().key("outer-stack").wFull().growth(GrowthSpec()).virtualize(100.0)
                .child(col().key("o0").wFull().h(100.0))
                .child(col().key("o1").wFull().h(100.0))
                .child(col().key("o2").wFull().child(innerScroll))
            return col().wFull().hFull().child(
                col().key("outer").wFull().h(300.0)
                    .scroll(ScrollSpec(stickBottom: true))
                    .child(outer)
            )
        }

        var t = 0.0
        _ = rt.frame(at: t)
        for _ in 0..<30 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        #expect(rt.element(byKey: "i0") == nil, "top inner row starts culled under stickBottom")

        let innerBox = try #require(rt.element(byKey: "inner"))
        let r = innerBox.rect
        let pt = Vec2(r[0] + r[2] * 0.5, r[1] + r[3] * 0.5)
        for _ in 0..<6 {
            t += 1.0 / 60.0
            rt.wheel(WheelEvent(dx: 0.0, dy: 1000.0), at: pt, now: t)
            _ = rt.frame(at: t)
        }

        let i0 = try #require(rt.element(byKey: "i0"), "i0 must mount when inner virtual list scrolls to top")
        let stack = try #require(rt.element(byKey: "inner-stack"))
        let opacity = i0.opacity
        let i0Rect = i0.rect
        let stackRect = stack.rect
        #expect(abs(opacity - 1.0) < 0.001, "opacity should be settled at 1.0, got \(opacity)")
        #expect(abs(i0Rect[1] - stackRect[1]) < 0.01 && abs(i0Rect[3] - 40.0) < 0.01,
                "i0 rect \(i0Rect) should be settled at stack top \(stackRect)")
    }
}
