import Testing
import Foundation
@testable import Rune
import RuneMotion

@Suite("Direction and RTL Parity")
struct DirectionAndRtlParityTests {
    private struct EmptyState {}

    @Test("Direction.of respects UAX #9 isolates, paragraph breaks, and neutrals")
    func directionOfBidiIsolates() {
        #expect(Direction.of("Hello") == .ltr)
        #expect(Direction.of("שלום") == .rtl)
        #expect(Direction.of("مرحبا") == .rtl)
        #expect(Direction.of("12345 !@#") == nil)
        #expect(Direction.of("") == nil)

        // UAX #9 rules P2/P3: strong characters inside LRI/RLI/FSI..PDI are skipped
        #expect(Direction.of("\u{2066}Hello\u{2069} שלום") == .rtl)
        #expect(Direction.of("\u{2067}שלום\u{2069} Hello") == .ltr)
        #expect(Direction.of("\u{2068}שלום\u{2069} 123") == nil)

        // Paragraph separator terminates P2/P3 scan for the first paragraph
        #expect(Direction.of("123\nשלום") == nil)
        #expect(Direction.of("123\u{2029}שלום") == nil)
    }

    @Test("dir(.ltr/.rtl/.auto) layout mirroring, islands, and unmirrored()")
    func dirSubtreeAndUnmirrored() {
        let rt = Runtime<EmptyState>(state: EmptyState(), viewport: Vec2(200, 120)) { _, _ in
            El<EmptyState>(direction: .column).w(200)
                .child(
                    El<EmptyState>(direction: .row).key("rtlRow").w(200).h(24).dir(.rtl).pl(10).pr(2)
                        .child(el().key("first").w(40).h(20))
                        .child(el().key("second").w(60).h(20))
                )
                .child(
                    El<EmptyState>(direction: .row).key("autoRtl").w(200).h(24).dir(.auto)
                        .child(text("مرحبا").w(50).h(20).key("ar"))
                        .child(el().key("tail").w(30).h(20))
                )
                .child(
                    El<EmptyState>(direction: .row).key("islandHost").w(200).h(24).dir(.rtl)
                        .child(
                            El<EmptyState>(direction: .row).key("ltrIsland").w(100).h(20).dir(.ltr)
                                .child(el().key("i1").w(20).h(20))
                                .child(el().key("i2").w(30).h(20))
                        )
                )
                .child(
                    El<EmptyState>(direction: .row).key("unmirroredHost").w(200).h(24).dir(.rtl)
                        .child(
                            El<EmptyState>(direction: .row).key("pin").w(100).h(20).unmirrored().pl(12).pr(2)
                                .child(el().key("u1").w(20).h(20))
                                .child(el().key("u2").w(30).h(20))
                        )
                )
        }
        _ = rt.frame(at: 0)

        let first = rt.flatNodes.first { $0.key == "first" }!
        let second = rt.flatNodes.first { $0.key == "second" }!
        // RTL swaps pl(10)/pr(2) -> 10pt on right edge: first sits at [150, 190], second at [90, 150]
        #expect(abs(first.targetRect.x - 150) < 0.5)
        #expect(abs(second.targetRect.x - 90) < 0.5)
        #expect(first.flow == .rtl)

        // dir(.auto) inspects descendant strong char ("مرحبا" -> .rtl)
        let ar = rt.flatNodes.first { $0.key == "ar" }!
        let tail = rt.flatNodes.first { $0.key == "tail" }!
        #expect(ar.flow == .rtl)
        #expect(ar.el.textStyle.direction == .rtl)
        #expect(abs(ar.targetRect.x - 150) < 0.5)
        #expect(abs(tail.targetRect.x - 120) < 0.5)

        // LTR island inside RTL host: island itself mirrors in RTL host ([100, 200]),
        // while its own children stay LTR ([100, 120] and [120, 150])
        let island = rt.flatNodes.first { $0.key == "ltrIsland" }!
        let i1 = rt.flatNodes.first { $0.key == "i1" }!
        let i2 = rt.flatNodes.first { $0.key == "i2" }!
        #expect(abs(island.targetRect.x - 100) < 0.5)
        #expect(island.flow == .ltr)
        #expect(abs(i1.targetRect.x - 100) < 0.5)
        #expect(abs(i2.targetRect.x - 120) < 0.5)

        // unmirrored() stays unmirrored inside RTL host ([0, 100]) and keeps children LTR with pl=12
        let pin = rt.flatNodes.first { $0.key == "pin" }!
        let u1 = rt.flatNodes.first { $0.key == "u1" }!
        let u2 = rt.flatNodes.first { $0.key == "u2" }!
        #expect(abs(pin.targetRect.x - 0) < 0.5)
        #expect(pin.flow == .ltr)
        #expect(abs(u1.targetRect.x - 12) < 0.5)
        #expect(abs(u2.targetRect.x - 32) < 0.5)
    }

    @Test("Visuals, mirrorInRtl rotation/bitmap flip, and anchored placement mirror in RTL")
    func visualsAndAnchoredMirror() {
        let arrowSvg = SVGIcon(viewBox: 24, paths: ["M4 12 H18 M13 6 L19 12 L13 18"], strokeWidth: 2)
        let rt = Runtime<EmptyState>(state: EmptyState(), viewport: Vec2(300, 200)) { _, _ in
            El<EmptyState>(direction: .column).w(300).h(200).dir(.rtl)
                .child(
                    el().key("card")
                        .w(120).h(40)
                        .pl(14).pr(4)
                        .corners(8, 2, 4, 12)
                        .borderSides(top: 1, right: 2, bottom: 3, left: 6, color: .white)
                        .clipCorners(Corners(6, 1, 3, 9))
                        .clipFade(left: 10, top: 0, right: 2, bottom: 0)
                        .linearGradient(top: Color(r: 1, g: 0, b: 0), bottom: Color(r: 0, g: 0, b: 1), angleRadians: 0)
                )
                .child(
                    icon(arrowSvg, size: 16).key("arrow").mirrorInRtl().rotate(0.5).iconRotation(0.25)
                )
                .child(
                    el().key("trigger").w(40).h(20).ml(20)
                )
                .child(
                    el().key("tipRight").w(50).h(20).anchored("trigger", side: .right, align: .start, gap: 4)
                )
                .child(
                    el().key("tipTopStart").w(20).h(16).anchored("trigger", side: .top, align: .start, gap: 2)
                )
        }
        _ = rt.frame(at: 0)

        let card = rt.flatNodes.first { $0.key == "card" }!
        #expect(card.el.layout.padding.left == 4)
        #expect(card.el.layout.padding.right == 14)
        #expect(card.el.corners == Corners(2, 8, 12, 4))
        #expect(card.el.borderSides == Sides(top: 1, right: 6, bottom: 3, left: 2))
        #expect(card.el.clipCorners == Corners(1, 6, 9, 3))
        #expect(card.el.clipFade == SIMD4<Float>(2, 0, 10, 0))
        if case let .linear(_, _, angle)? = card.el.gradient {
            #expect(abs(angle - Float.pi) < 1e-4)
        } else {
            Issue.record("Expected linear gradient")
        }

        let arrow = rt.flatNodes.first { $0.key == "arrow" }!
        #expect(arrow.mirroredInRtl)
        #expect(abs(arrow.el.rotate - (-0.5)) < 1e-4)
        #expect(abs(arrow.el.iconRotation - (-0.25)) < 1e-4)
        #expect(abs((rt.scene.get(arrow.nodeId, Props.ICON_TURN) ?? 0) - (-0.25)) < 1e-4)

        // Anchored side .right mirrors to .left of trigger (trigger is at [260, 300] in RTL)
        let trigger = rt.flatNodes.first { $0.key == "trigger" }!
        let tipRight = rt.flatNodes.first { $0.key == "tipRight" }!
        let tipTopStart = rt.flatNodes.first { $0.key == "tipTopStart" }!
        #expect(tipRight.el.anchor?.side == Side.left)
        #expect(abs(tipRight.targetRect.right - (trigger.targetRect.x - 4)) < 0.5)
        // Top anchor with .start mirrors to .end (right-aligned with trigger's right edge)
        #expect(tipTopStart.el.anchor?.align == Align.end)
        #expect(abs(tipTopStart.targetRect.right - trigger.targetRect.right) < 0.5)

        // Rasterized bitmap horizontally flipped when mirrored: true
        let atlas = GlyphAtlas()
        let asymSvg = SVGIcon(viewBox: 16, paths: ["M1 2 L5 2 L5 14 L1 14 Z"], strokeWidth: nil)
        let ltrIcon = atlas.rasterizeIcon(asymSvg, pixelSize: 16, mirrored: false)
        let rtlIcon = atlas.rasterizeIcon(asymSvg, pixelSize: 16, mirrored: true)
        let stride = atlas.atlas.width
        let pageL = atlas.pageData(Int(ltrIcon.page))!
        let pageR = atlas.pageData(Int(rtlIcon.page))!
        let lx = ltrIcon.pixelOrigin.x, ly = ltrIcon.pixelOrigin.y, lw = ltrIcon.pixelSize.x
        let rx = rtlIcon.pixelOrigin.x, ry = rtlIcon.pixelOrigin.y, rw = rtlIcon.pixelSize.x
        #expect(lw == rw && lw >= 8)
        let row = ltrIcon.pixelSize.y / 2
        let ltrLeftSample = pageL[(ly + row) * stride + lx + 2]
        let rtlRightSample = pageR[(ry + row) * stride + rx + (rw - 1 - 2)]
        let rtlLeftSample = pageR[(ry + row) * stride + rx + 2]
        #expect(ltrLeftSample > 0)
        #expect(rtlRightSample == ltrLeftSample)
        #expect(rtlLeftSample == 0)

        // Color icon horizontal mirroring and centered square RefScene geometry in non-square box
        let colorRaster = ColorIconRasterizer()
        let asymColorSvg = SVGIcon(viewBox: 16, body: "<rect x=\"1\" y=\"2\" width=\"4\" height=\"12\" fill=\"#ff0000\"/>")
        let colorL = colorRaster.rasterize(asymColorSvg, pixelSize: 16, mirrored: false)!
        let colorR = colorRaster.rasterize(asymColorSvg, pixelSize: 16, mirrored: true)!
        let cRow = 8
        let cLeftIdx = (cRow * 16 + 2) * 4
        let cRightIdx = (cRow * 16 + (16 - 1 - 2)) * 4
        #expect(colorL.mips[0].rgba[cLeftIdx] > 200)
        #expect(colorR.mips[0].rgba[cRightIdx] > 200)
        #expect(colorR.mips[0].rgba[cLeftIdx + 3] == 0)

        let iconRt = Runtime<EmptyState>(state: EmptyState(), viewport: Vec2(200, 100)) { _, _ in
            El<EmptyState>(direction: .row).w(200).h(100).dir(.rtl)
                .child(icon(asymColorSvg, size: 16).key("cicon").w(40).h(20).mirrorInRtl())
        }
        let iconScene = iconRt.frame(at: 0)
        let imgPrims = iconScene.primitives.filter { Int($0.params.y) == PrimitiveKind.image.rawValue }
        #expect(imgPrims.count == 1)
        if let ip = imgPrims.first {
            // Centered square [posX, posY, drawn, drawn] inside 40x20 box -> 20x20 scaled by pixelScale
            #expect(abs(ip.rect.z - ip.rect.w) < 0.01)
            #expect(abs(ip.rect.z - 20 * iconRt.pixelScale) < 0.5)
        }
        let iconRf = iconRt.renderFrame(at: 0)
        #expect(iconRf.instances.contains { $0.params.y == KIND_IMAGE })
    }

    @Test("RTL horizontal scroll starts at right edge and swaps scrollEdgeFade left/right")
    func rtlHorizontalScrollAndFades() {
        let rt = Runtime<EmptyState>(state: EmptyState(), viewport: Vec2(100, 40)) { _, _ in
            El<EmptyState>(direction: .row).key("hscroll").w(100).h(40).dir(.rtl).scrollX().scrollEdgeFade(12)
                .child(el().key("item0").w(80).h(40))
                .child(el().key("item1").w(80).h(40))
                .child(el().key("item2").w(80).h(40))
        }
        _ = rt.frame(at: 0)

        let item0 = rt.flatNodes.first { $0.key == "item0" }!
        let item2 = rt.flatNodes.first { $0.key == "item2" }!
        // item0 sits flush at the right edge [20, 100]; item2 starts off the left edge [-140, -60]
        #expect(abs(item0.targetRect.x - 20) < 0.5)
        #expect(abs(item2.targetRect.x - (-140)) < 0.5)

        let scroller = rt.flatNodes.first { $0.key == "hscroll" }!
        // At curScroll.x == 0 in RTL: left edge has hidden content (width > 0), right edge has 0 hidden
        let initialFade = scroller.ownScrollFade!
        #expect(initialFade.widths.x > 0.5)
        #expect(abs(initialFade.widths.z) < 0.01)

        // Wheel rightward (dx > 0 moves RTL content rightward to reveal item2 off the left edge)
        rt.wheel(WheelEvent(dx: 140, dy: 0), at: Vec2(50, 20), now: 0.1)
        _ = rt.frame(at: 0.11)
        let scrolledItem2 = rt.flatNodes.first { $0.key == "item2" }!
        #expect(abs(scrolledItem2.targetRect.x - 0) < 0.5)
        let scrolledScroller = rt.flatNodes.first { $0.key == "hscroll" }!
        let endFade = scrolledScroller.ownScrollFade!
        #expect(abs(endFade.widths.x) < 0.01)
        #expect(endFade.widths.z > 0.5)
    }

    @Test("dirByParagraph splits mixed-direction paragraphs into keyed auto-directed column children")
    func dirByParagraphSplitsMixedText() {
        let plain: El<EmptyState> = text("Hello world\nשלום עולם").dirByParagraph().w(160)
        #expect(plain.layout.direction == .column)
        #expect(plain.plainText == nil)
        #expect(plain.children.count == 2)
        #expect(plain.children[0].keyId == "p0")
        #expect(plain.children[0].plainText == "Hello world")
        #expect(plain.children[0].explicitDir == .auto)
        #expect(plain.children[1].keyId == "p1")
        #expect(plain.children[1].plainText == "שלום עולם")
        #expect(plain.children[1].explicitDir == .auto)

        // Rich spans split cleanly too
        let mixedRich: El<EmptyState> = rich([
            TextSpan("Hello "),
            TextSpan("world\nשלום"),
        ]).dirByParagraph()
        #expect(mixedRich.children.count == 2)
        #expect(mixedRich.children[0].richSpans?.map(\.text).joined() == "Hello world")
        #expect(mixedRich.children[1].richSpans?.map(\.text).joined() == "שלום")

        // Same-direction paragraphs do not split unnecessarily
        let uniform: El<EmptyState> = text("Hello\nWorld").dirByParagraph()
        #expect(uniform.children.isEmpty)
        #expect(uniform.plainText == "Hello\nWorld")
    }

    @Test("RTL focusGroup reverses horizontal ArrowLeft/ArrowRight roving")
    func rtlFocusGroupReversesHorizontalArrows() {
        let rt = Runtime<EmptyState>(state: EmptyState(), viewport: Vec2(200, 60)) { _, _ in
            row()
                .dir(.rtl)
                .focusGroup()
                .size(200, 40)
                .children([
                    el().key("a").size(40, 30).focusable(),
                    el().key("b").size(40, 30).focusable(),
                    el().key("c").size(40, 30).focusable(),
                ])
        }
        _ = rt.frame(at: 0)
        // Focus first item ("a") by Tab
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.05))
        #expect(rt.focusedKey == "a")

        // In RTL, ArrowLeft advances forward visually (right-to-left: a -> b -> c)
        #expect(rt.keyDown(KeyEvent(key: .arrowLeft), at: 0.1))
        #expect(rt.focusedKey == "b")
        #expect(rt.keyDown(KeyEvent(key: .arrowLeft), at: 0.15))
        #expect(rt.focusedKey == "c")

        // In RTL, ArrowRight goes backward (c -> b)
        #expect(rt.keyDown(KeyEvent(key: .arrowRight), at: 0.2))
        #expect(rt.focusedKey == "b")
    }
}
