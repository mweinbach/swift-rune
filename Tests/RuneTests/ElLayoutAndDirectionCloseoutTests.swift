import Testing
@testable import Rune

@Suite("El Layout and Direction Closeout Parity")
struct ElLayoutAndDirectionCloseoutTests {

    @Test func keyedElementsPreserveTheirOriginalSourceLocationWhenCopied() {
        let source = El<Int>().key("row", file: "ui:🧪.swift", line: .max, column: 0)
        #expect(source.keyLocation == "ui:🧪.swift:\(UInt.max):0")
        var edited = source
        edited.keyLocation = "generated"
        #expect(edited.keyLocation == "generated")
        edited.keyLocation = ""
        #expect(edited.keyLocation.isEmpty)
        #expect(source.keyLocation == "ui:🧪.swift:\(UInt.max):0")
    }

    @Test("Copied grid styles retain independent placement and compare by value")
    func gridStyleCopies() {
        func style() -> LayoutStyle {
            var result = LayoutStyle()
            result.grid = GridContainerStyle(templateColumns: [.fr(1)])
            result.gridItem = GridItemStyle(column: .line(2))
            return result
        }

        let original = style()
        #expect(Set([original, style()]).count == 1)
        var copy = original
        copy.grid?.templateColumns.append(.px(10))
        copy.gridItem?.column = .span(2)
        #expect(original.grid?.templateColumns == [.fr(1)])
        #expect(original.gridItem?.column == .line(2))
        #expect(copy != original)
        copy.grid = nil
        copy.gridItem = nil
        #expect(copy == LayoutStyle())
    }

    @Test("Direction.isRtl and Direction.of resolve bidi directions")
    func directionHelpers() {
        #expect(Direction.ltr.isRtl == false)
        #expect(Direction.rtl.isRtl == true)
        #expect(Direction.auto.isRtl == false)

        #expect(Direction.of("hello") == .ltr)
        #expect(Direction.of("שלום") == .rtl)
        #expect(Direction.of("   123!  ") == nil)
    }

    @Test("El pb, pr, mb, and mr affect computed layout bounds")
    func paddingAndMarginEdgesAffectLayout() {
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 160), pixelScale: 1.0) { _, _ in
            col().w(200).h(160)
                .child(
                    row().key("pad-box").w(100).h(80).pt(4).pb(12).pl(6).pr(14)
                        .child(el().key("padded").grow().selfStretch())
                )
                .child(
                    col().key("margin-col").w(100)
                        .child(el().key("top-item").w(40).h(20).mb(10))
                        .child(el().key("bot-item").w(40).h(20))
                )
                .child(
                    row().key("margin-row").w(100).h(30)
                        .child(el().key("left-item").w(20).h(20).mr(15))
                        .child(el().key("right-item").w(20).h(20))
                )
        }
        _ = rt.frame(at: 0.0)

        let padded = rt.element(byKey: "padded")!
        #expect(abs(padded.rect[0] - 6.0) < 0.5)
        #expect(abs(padded.rect[1] - 4.0) < 0.5)
        #expect(abs(padded.rect[2] - 80.0) < 0.5)
        #expect(abs(padded.rect[3] - 64.0) < 0.5)

        let topItem = rt.element(byKey: "top-item")!
        let botItem = rt.element(byKey: "bot-item")!
        #expect(abs((botItem.rect[1] - topItem.rect[1]) - 30.0) < 0.5)

        let leftItem = rt.element(byKey: "left-item")!
        let rightItem = rt.element(byKey: "right-item")!
        #expect(abs((rightItem.rect[0] - leftItem.rect[0]) - 35.0) < 0.5)
    }

    @Test("El itemsStretch, selfStart, and selfCenter align cross-axis geometry")
    func crossAxisStretchAndSelfAlignments() {
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(160, 80), pixelScale: 1.0) { _, _ in
            row().key("container").w(120).h(60).itemsStretch()
                .child(el().key("stretched").w(20))
                .child(el().key("s-start").w(20).h(12).selfStart())
                .child(el().key("s-center").w(20).h(12).selfCenter())
        }
        _ = rt.frame(at: 0.0)

        let stretched = rt.element(byKey: "stretched")!
        #expect(abs(stretched.rect[3] - 60.0) < 0.5)

        let sStart = rt.element(byKey: "s-start")!
        #expect(abs(sStart.rect[1] - 0.0) < 0.5)
        #expect(abs(sStart.rect[3] - 12.0) < 0.5)

        let sCenter = rt.element(byKey: "s-center")!
        #expect(abs(sCenter.rect[1] - 24.0) < 0.5)
        #expect(abs(sCenter.rect[3] - 12.0) < 0.5)
    }

    @Test("El.hoverDelays(enter:leave:) delays enter/leave reporting and supports zero reset")
    func hoverDelaysFloatOverload() {
        struct S {
            var delayed: [Bool] = []
            var instant: [Bool] = []
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ in
            col().w(200).h(120)
                .child(
                    el().key("delayed").size(80, 40)
                        .onHoverChange { s, inside, _ in s.delayed.append(inside) }
                        .hoverDelays(enter: Float(0.2), leave: Float(0.1))
                )
                .child(
                    el().key("instant").size(80, 40)
                        .onHoverChange { s, inside, _ in s.instant.append(inside) }
                        .hoverDelays(enter: Float(0.0), leave: Float(0.0))
                )
        }
        _ = rt.frame(at: 0.0)

        rt.pointerMove(to: Vec2(20, 20), at: 1.0)
        #expect(rt.state.delayed.isEmpty)
        let dueEnter = rt.nextWakeDeadline(after: 1.0)
        #expect(dueEnter != nil && abs((dueEnter ?? 0) - 1.2) < 1e-4)
        _ = rt.frame(at: 1.2)
        #expect(rt.state.delayed == [true])

        rt.pointerMove(to: Vec2(20, 60), at: 2.0)
        #expect(rt.state.delayed == [true])
        #expect(rt.state.instant == [true])
        let dueLeave = rt.nextWakeDeadline(after: 2.0)
        #expect(dueLeave != nil && abs((dueLeave ?? 0) - 2.1) < 1e-4)
        _ = rt.frame(at: 2.1)
        #expect(rt.state.delayed == [true, false])

        rt.pointerMove(to: Vec2(160, 100), at: 3.0)
        #expect(rt.state.instant == [true, false])
    }
}
