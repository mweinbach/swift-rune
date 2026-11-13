import Foundation
import Testing
@testable import Rune
@testable import RuneMotion

@Suite("Rune Layout Parity Tests (aspect_fit, alignment, absolute, margin, scroll_x)")
struct LayoutParityTests {
    private func targetRect<S>(_ rt: Runtime<S>, _ key: String) -> [Float] {
        rt.elements().first(where: { $0.key == key })!.target
    }

    private func rect<S>(_ rt: Runtime<S>, _ key: String) -> [Float] {
        rt.elements().first(where: { $0.key == key })!.rect
    }

    private func approx(_ a: Float, _ b: Float, eps: Float = 0.05) -> Bool {
        abs(a - b) <= eps
    }

    private func approxRect(_ a: [Float], _ b: [Float], eps: Float = 0.05) -> Bool {
        a.count == 4 && b.count == 4
            && approx(a[0], b[0], eps: eps)
            && approx(a[1], b[1], eps: eps)
            && approx(a[2], b[2], eps: eps)
            && approx(a[3], b[3], eps: eps)
    }

    // MARK: - aspect_fit_tests.rs

    @Test("aspect_fit: picture fits its cell less the caption")
    func aspectFitFitsCellLessCaption() {
        func cell(_ ratio: Float) -> El<Float> {
            col().size(300, 200).itemsCenter()
                .child(el().key("pic").aspectFit(ratio))
                .child(text("caption").key("cap").h(20))
        }

        let wide = Runtime<Float>(state: 2.0, viewport: Vec2(800, 600), pixelScale: 1.0) { r, _ in
            col().child(cell(r))
        }
        _ = wide.frame(at: 0)
        #expect(approxRect(targetRect(wide, "pic"), [0, 0, 300, 150]))
        #expect(approx(targetRect(wide, "cap")[1], 150))

        let tall = Runtime<Float>(state: 0.5, viewport: Vec2(800, 600), pixelScale: 1.0) { r, _ in
            col().child(cell(r))
        }
        _ = tall.frame(at: 0)
        #expect(approxRect(targetRect(tall, "pic"), [105, 0, 90, 180]))
    }

    @Test("aspect_fit: new ratio or viewport refits")
    func aspectFitRefitsOnRatioAndViewportChange() {
        let rt = Runtime<Float>(state: 2.0, viewport: Vec2(800, 600), pixelScale: 1.0) { r, _ in
            col().wFull().hFull().itemsCenter()
                .child(el().key("pic").aspectFit(r))
        }
        _ = rt.frame(at: 0)
        #expect(approx(targetRect(rt, "pic")[2], 800))
        #expect(approx(targetRect(rt, "pic")[3], 400))

        rt.state = 0.5
        rt.markNeedsCommit()
        _ = rt.frame(at: 1.0)
        #expect(approx(targetRect(rt, "pic")[2], 300))
        #expect(approx(targetRect(rt, "pic")[3], 600))

        rt.viewport = Vec2(400, 400)
        _ = rt.frame(at: 2.0)
        #expect(approx(targetRect(rt, "pic")[2], 200))
        #expect(approx(targetRect(rt, "pic")[3], 400))
    }

    @Test("aspect_fit: cells in a row each fit their own")
    func aspectFitCellsInRow() {
        let rt = Runtime<Float>(state: 3.0, viewport: Vec2(800, 600), pixelScale: 1.0) { r, _ in
            func cell(_ k: String, _ ratio: Float) -> El<Float> {
                col().grow(1).hFull().itemsCenter().child(el().key(k).aspectFit(ratio))
            }
            return col().child(
                row().size(610, 200).gap(10)
                    .child(cell("a", r))
                    .child(cell("b", 0.5))
            )
        }
        _ = rt.frame(at: 0)
        #expect(approxRect(targetRect(rt, "a"), [0, 0, 300, 100]))
        #expect(approxRect(targetRect(rt, "b"), [410, 0, 100, 200]))
    }

    @Test("aspect_fit: max sizes bound it in an auto-height column")
    func aspectFitMaxSizesBoundWhereNothingElseDoes() {
        let rt = Runtime<Float>(state: 2.0, viewport: Vec2(800, 600), pixelScale: 1.0) { r, _ in
            col().child(
                col().w(300)
                    .child(el().key("pic").maxH(80).aspectFit(r))
                    .child(text("caption").key("cap").h(20))
            )
        }
        _ = rt.frame(at: 0)
        #expect(approxRect(targetRect(rt, "pic"), [0, 0, 160, 80]))
        #expect(approx(targetRect(rt, "cap")[1], 80))
    }

    @Test("aspect_fit: grow and content do not size the fitted box")
    func aspectFitGrowAndContentDoNotSizeFittedBox() {
        let rt = Runtime<Float>(state: 2.0, viewport: Vec2(800, 600), pixelScale: 1.0) { r, _ in
            col()
                .child(col().size(300, 200).child(el().key("grown").grow(1).aspectFit(r)))
                .child(
                    row().size(600, 200)
                        .child(el().key("a").aspectFit(r).child(el().w(200).h(10)))
                        .child(el().key("b").aspectFit(r))
                )
        }
        _ = rt.frame(at: 0)
        #expect(approx(targetRect(rt, "grown")[2], 300))
        #expect(approx(targetRect(rt, "grown")[3], 150))
        #expect(approx(targetRect(rt, "a")[2], 300))
        #expect(approx(targetRect(rt, "a")[3], 150))
        #expect(approx(targetRect(rt, "b")[2], 300))
        #expect(approx(targetRect(rt, "b")[3], 150))
    }

    // MARK: - alignment.rs

    @Test("alignment: CSS flex alignment builders match upstream")
    func alignmentBuildersMatchCSS() {
        let expect: [(name: String, a: (Float, Float), b: (Float, Float))] = [
            ("items_end", (0, 50), (20, 30)),
            ("items_center", (0, 25), (20, 15)),
            ("self_end / self_stretch", (0, 50), (20, 0)),
            ("justify_center", (80, 0), (100, 0)),
            ("justify_around", (40, 0), (140, 0)),
            ("justify_evenly", (53.333, 0), (126.667, 0)),
            ("column items_end + justify_start", (180, 0), (180, 10)),
        ]

        for (caseIdx, item) in expect.enumerated() {
            let rt = Runtime<Int>(state: caseIdx, viewport: Vec2(200, 60), pixelScale: 1.0) { c, _ in
                let k1: El<Int> = el().key("a").size(20, 10)
                let k2: El<Int> = el().key("b").size(20, 30)
                let parent: El<Int> = row().key("parent").size(200, 60)
                switch c {
                case 0: return parent.itemsEnd().child(k1).child(k2)
                case 1: return parent.itemsCenter().child(k1).child(k2)
                case 2:
                    return parent
                        .child(el().key("a").size(20, 10).selfEnd())
                        .child(el().key("b").w(20).selfStretch())
                case 3: return parent.justifyCenter().child(k1).child(k2)
                case 4: return parent.justifyAround().child(k1).child(k2)
                case 5: return parent.justifyEvenly().child(k1).child(k2)
                default:
                    return col().key("parent").size(200, 60).itemsEnd().justifyCenter().justifyStart().child(k1).child(k2)
                }
            }
            _ = rt.frame(at: 0)
            let ra = targetRect(rt, "a")
            let rb = targetRect(rt, "b")
            #expect(approx(ra[0], item.a.0, eps: 0.02) && approx(ra[1], item.a.1, eps: 0.02), "\(item.name) a: \(ra)")
            #expect(approx(rb[0], item.b.0, eps: 0.02) && approx(rb[1], item.b.1, eps: 0.02), "\(item.name) b: \(rb)")
            if caseIdx == 2 {
                #expect(approx(rb[3], 60), "selfStretch fills cross axis")
            }
        }
    }

    // MARK: - absolute_frac.rs & absolute_in_rows.rs

    @Test("absolute_frac: wFrac on absolute child resolves against parent's padding box")
    func absoluteFractionsSpanParentsPaddingBox() {
        func bar(_ key: String) -> El<Int> {
            el().key(key).absolute(x: 0, y: 0).wFrac(1.0).h(4)
        }
        let rt = Runtime<Int>(state: 0, viewport: Vec2(400, 400), pixelScale: 2.0) { _, _ in
            col().wFull().hFull().p(6).gap(10)
                .child(col().key("card").wFull().h(60).p(6).border(1, .black).child(bar("card-bar")))
                .child(
                    row().wFull().h(40).child(
                        col().key("cell").w(200).hFull().px(12)
                            .child(bar("cell-bar"))
                            .child(el().key("cell-half").absolute(x: 0, y: 10).wFrac(0.5).h(4))
                    )
                )
                .child(
                    col().key("scroll").w(240).h(100).p(6).scroll(stickBottom: false)
                        .child(col().key("content").wFull().h(300).child(bar("content-bar")))
                )
        }
        _ = rt.frame(at: 0)

        let card = rect(rt, "card")
        #expect(approx(card[2], 388))
        #expect(approxRect(rect(rt, "card-bar"), [card[0], card[1], card[2], 4]))

        let cell = rect(rt, "cell")
        #expect(approxRect(rect(rt, "cell-bar"), [cell[0], cell[1], 200, 4]))
        #expect(approxRect(rect(rt, "cell-half"), [cell[0], cell[1] + 10, 100, 4]))

        let scroll = rect(rt, "scroll")
        let content = rect(rt, "content")
        #expect(approx(content[2], 228))
        #expect(approxRect(rect(rt, "content-bar"), [content[0], content[1], 228, 4]))
        #expect(approx(content[0], scroll[0] + 6))
    }

    @Test("absolute_in_rows: absolute children of rows size against the row padding box")
    func absoluteChildrenOfRowsSizeAgainstRow() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(400, 300), pixelScale: 1.0) { _, _ in
            func makeRow(_ i: Int) -> El<Int> {
                row().key("row\(i)").wFull().h(40).p(4)
                    .child(text("hello"))
                    .child(el().key("cover\(i)").pin(top: 0, right: 0, bottom: 0, left: 0))
                    .child(el().key("full\(i)").absolute(x: 0, y: 0).wFull().hFull())
                    .child(el().key("half\(i)").absolute(x: 10, y: 2).wFrac(0.5).h(4))
                    .child(el().key("badge\(i)").pin(right: 6, bottom: 5).size(10, 10))
                    .child(
                        row().key("nest\(i)").absolute(x: 0, y: 0).w(100).h(20)
                            .child(el().key("inner\(i)").pin(right: 0, left: 0).h(2))
                    )
            }
            var stack: El<Int> = col().key("stack").wFull()
            for i in 0..<3 {
                stack = stack.child(makeRow(i))
            }
            return col().wFull().hFull().p(20)
                .child(col().key("scroll").wFull().h(200).scroll(stickBottom: false).child(stack))
                .child(el().key("scrim").absolute(x: 0, y: 0).wFull().hFull())
        }
        _ = rt.frame(at: 0)

        for i in 0..<3 {
            let y: Float = 20 + 40 * Float(i)
            #expect(approxRect(targetRect(rt, "row\(i)"), [20, y, 360, 40]))
            #expect(approxRect(targetRect(rt, "cover\(i)"), [20, y, 360, 40]))
            #expect(approxRect(targetRect(rt, "full\(i)"), [20, y, 360, 40]))
            #expect(approxRect(targetRect(rt, "half\(i)"), [30, y + 2, 180, 4]))
            #expect(approxRect(targetRect(rt, "badge\(i)"), [380 - 6 - 10, y + 40 - 5 - 10, 10, 10]))
            #expect(approxRect(targetRect(rt, "inner\(i)"), [20, y, 100, 2]))
        }
        #expect(approxRect(targetRect(rt, "scrim"), [0, 0, 400, 300]))
    }

    // MARK: - margin_axes.rs & scroll_children.rs

    @Test("margin_axes: mx and my apply to both sides")
    func mxAndMyApplyToBothSides() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            col().w(200).h(200).itemsStart()
                .child(
                    row()
                        .child(el().key("x").size(20, 10).mx(7))
                        .child(el().key("after_x").size(10, 10))
                )
                .child(el().key("y").size(20, 10).my(5))
                .child(el().key("after_y").size(10, 10))
        }
        _ = rt.frame(at: 0)
        let x = rect(rt, "x")
        let afterX = rect(rt, "after_x")
        let y = rect(rt, "y")
        let afterY = rect(rt, "after_y")
        #expect(approx(x[0], 7) && approx(x[1], 0))
        #expect(approx(afterX[0], 7 + 20 + 7))
        #expect(approx(y[0], 0) && approx(y[1], 10 + 5))
        #expect(approx(afterY[1], 10 + 5 + 10 + 5))
    }

    @Test("scroll_x: unwrapped horizontal children scroll cleanly to last child")
    func scrollXWithFiftyDirectChildren() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 60), pixelScale: 1.0) { _, _ in
            var strip: El<Int> = row().key("strip").size(200, 60).scrollX()
            for i in 0..<50 {
                strip = strip.child(el().key("c\(i)").w(40).h(60))
            }
            return strip
        }
        _ = rt.frame(at: 0)
        #expect(approx(rect(rt, "c49")[0], 1960))

        rt.wheel(WheelEvent(dx: -10_000, dy: 0), at: Vec2(100, 30), now: 1.0 / 60.0)
        _ = rt.frame(at: 1.0 / 60.0)
        let last = rect(rt, "c49")
        #expect(approx(last[0] + last[2], 200))
    }

    // MARK: - ElLayoutExtensions (rowReverse, colReverse, wrapReverse, displayNone, contentBox, borderLayout, shrink)

    @Test("ElLayoutExtensions: rowReverse, colReverse, wrapReverse, displayNone, contentBox, borderLayout, shrink")
    func layoutExtensionsParity() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 2.0) { _, _ in
            col().w(200).h(200)
                .child(
                    row().w(100).h(20).rowReverse()
                        .child(el().key("rr1").size(20, 10))
                        .child(el().key("rr2").size(30, 10))
                )
                .child(
                    col().w(100).h(40).colReverse()
                        .child(el().key("cr1").size(20, 10))
                        .child(el().key("cr2").size(20, 15))
                )
                .child(
                    row().w(50).h(40).flexWrapReverse()
                        .child(el().key("wr1").size(30, 10))
                        .child(el().key("wr2").size(30, 10))
                )
                .child(el().key("hidden").size(40, 40).displayNone())
                .child(el().key("cbox").size(50, 20).p(5).contentBox())
                .child(
                    row().key("bordered").w(100).h(30).border(2, .white).borderLayout()
                        .child(el().key("bchild").wFull().hFull())
                )
                .child(
                    row().w(80).h(20)
                        .child(el().key("fixed").size(60, 20).shrink(0))
                        .child(el().key("shrunk").minW(40).w(60).h(20).shrink())
                )
        }
        _ = rt.frame(at: 0)

        // rowReverse: rr1 sits flush right (x=80), rr2 to its left (x=50)
        #expect(approx(targetRect(rt, "rr1")[0], 80))
        #expect(approx(targetRect(rt, "rr2")[0], 50))
        // colReverse: cr1 sits at bottom of 40pt col (rel y=30 -> world y=50), cr2 above (rel y=15 -> world y=35)
        #expect(approx(targetRect(rt, "cr1")[1], 50))
        #expect(approx(targetRect(rt, "cr2")[1], 35))
        // wrapReverse: wr1 wraps onto bottom line, wr2 onto line above it
        #expect(targetRect(rt, "wr1")[1] > targetRect(rt, "wr2")[1])
        // displayNone collapses to 0x0
        #expect(approx(targetRect(rt, "hidden")[2], 0))
        #expect(approx(targetRect(rt, "hidden")[3], 0))
        // contentBox: 50 + 5 + 5 = 60 width, 20 + 5 + 5 = 30 height
        #expect(approx(targetRect(rt, "cbox")[2], 60))
        #expect(approx(targetRect(rt, "cbox")[3], 30))
        // borderLayout: inner child is inset by border 2 -> 96x26 at +2,+2 inside parent
        let bParent = targetRect(rt, "bordered")
        let bChild = targetRect(rt, "bchild")
        #expect(approx(bChild[0] - bParent[0], 2))
        #expect(approx(bChild[1] - bParent[1], 2))
        #expect(approx(bChild[2], 96))
        #expect(approx(bChild[3], 26))
        // shrink() overrides minW(40) to 0 and shrinks shrunk to 20pt beside 60pt fixed
        #expect(approx(targetRect(rt, "fixed")[2], 60))
        #expect(approx(targetRect(rt, "shrunk")[2], 20))
    }

    @Test("scroll_x: multiple auto-width siblings keep intrinsic widths")
    func scrollXMultipleAutoWidthSiblingsKeepIntrinsicWidths() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 60), pixelScale: 1.0) { _, _ in
            row().key("strip").size(200, 60).scrollX()
                .child(row().key("a").child(el().size(30, 20)))
                .child(row().key("b").child(el().size(45, 20)))
        }
        _ = rt.frame(at: 0)
        let a = targetRect(rt, "a")
        let b = targetRect(rt, "b")
        #expect(approx(a[0], 0) && approx(a[2], 30))
        #expect(approx(b[0], 30) && approx(b[2], 45))
    }

    @Test("aspect_fit: non-stretching parent preserves both maxW and maxH room bounds")
    func aspectFitNonStretchingPreservesBothMaxBounds() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            col().wFull().hFull().itemsStart()
                .child(el().key("fit").maxW(100).maxH(80).aspectFit(2))
        }
        _ = rt.frame(at: 0)
        let r = targetRect(rt, "fit")
        #expect(approx(r[2], 100) && approx(r[3], 50))
    }
}
