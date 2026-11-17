import Rune
import Testing

@Suite("Unwrapped label alignment")
struct UnwrappedLabelAlignmentTests {
    @Test("An unwrapped label aligns its intrinsic text in its padded box, including overflow")
    @MainActor
    func paintOrigins() throws {
        for scale: Float in [1, 1.25, 2] {
            for (value, direction): (String, TextFlow) in [("abc", .ltr), ("שלום", .rtl)] {
                for width: Float in [150, 22] {
                    func paint(_ align: TextAlign) -> (reference: Float?, native: Float?) {
                        let rt = Runtime(state: (), viewport: Vec2(260, 60), pixelScale: scale) { _, _ in
                            let font = TextStyle(size: 14, direction: direction).mono().lh(20)
                            return row().size(260, 60).pl(50)
                                .child(text(value).font(font).noWrap().textAlign(align).size(width, 26).px(5))
                        }
                        let ref = rt.frame(at: 0).primitives.filter { $0.kind == .glyph }.map(\.rect.x).min()
                        let native = rt.renderFrame(at: 0.01).instances.filter { $0.params.y == KIND_GLYPH }.map(\.rect.x).min()
                        return (ref, native)
                    }
                    let l = paint(direction == .ltr ? .leading : .trailing)
                    let r = paint(direction == .ltr ? .trailing : .leading)
                    let center = paint(.center)
                    let left = try #require(l.reference)
                    let right = try #require(r.reference)
                    #expect((width > 100 ? right - left : left - right) > 4 * scale)
                    #expect(abs(try #require(center.reference) - (left + right) * 0.5) <= 1)
                    #expect(l.native == l.reference && r.native == r.reference && center.native == center.reference)
                }
            }
        }
    }

    @Test("Drag hit testing follows the painted glyphs inside a trailing-aligned label")
    @MainActor
    func dragAtPaintedOrigin() throws {
        final class Report: @unchecked Sendable { var boxes: [[Float]] = [] }
        let report = Report()
        let rt = Runtime(state: (), viewport: Vec2(240, 75), pixelScale: 2) { _, cx in
            report.boxes = cx.selectionRects()
            return col().size(240, 75).selectionGroup()
                .child(text("ABCDE").key("abc").font(TextStyle(size: 16).mono().lh(24))
                    .noWrap().textAlign(.trailing).size(200, 24).px(10).selectable())
        }
        let glyphs = rt.renderFrame(at: 0).instances.filter { $0.params.y == KIND_GLYPH }.map(\.rect)
        #expect(glyphs.count == 5)
        let a = try #require(glyphs.first)
        let d = try #require(glyphs.dropFirst(3).first)
        let start = Vec2((a.x - 2) / 2, 12)
        let end = Vec2((d.x - 1) / 2, 12)
        #expect(start.x > 125)
        rt.pointerDown(at: start, at: 0.1)
        rt.pointerMove(to: end, at: 0.12)
        rt.pointerUp(at: end, at: 0.14)
        #expect(rt.selectedText() == "ABC")
        _ = rt.frame(at: 0.16)
        _ = rt.frame(at: 0.18)
        let selection = try #require(report.boxes.first)
        #expect(abs(selection[0] - start.x) < 3)
        #expect(abs(selection[0] + selection[2] - end.x) < 3)
    }
}
