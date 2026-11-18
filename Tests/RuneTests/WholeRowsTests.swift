import Foundation
import RuneMotion
import Testing
@testable import Rune

@Suite
struct WholeRowsTests {
    @Test("Whole-row estimates follow the final flex style and leave the authored estimate intact")
    func virtualEstimate() {
        let list: El<Void> = col().virtualize(20.5)
        #expect(!list.layout.wholeRows)
        #expect(list.effectiveVirtualEstimate == 20.5)
        #expect(list.wholeRows().layout.wholeRows)
        #expect(list.wholeRows().virtualEstimate == 20.5)
        #expect(list.wholeRows().effectiveVirtualEstimate == 21)
        #expect(list.wholeRows().virtualize(20.25).effectiveVirtualEstimate == 20)
        #expect(list.wholeRows().flexWrap().effectiveVirtualEstimate == 20.5)
        #expect(list.wholeRows().flexWrapReverse().effectiveVirtualEstimate == 20.5)
        #expect(list.wholeRows().colReverse().effectiveVirtualEstimate == 20.5)
    }

    @Test("Virtual row geometry, spacers and visible ranges agree after a distant jump and resize",
          arguments: [false, true])
    func virtualScrollAndResize(wholeRows: Bool) throws {
        let count = 500
        let height: Float = wholeRows ? 21 : 20.5
        let runtime = Runtime(state: (), viewport: Vec2(160, 84), pixelScale: 1.25) { _, _ in
            let rows: El<Void> = col().key("rows").wFull().shrink(0)
                .virtualRows(count: count, estimatedRowHeight: 20.5, key: { _, i in "r\(i)" }) { _, _ in
                    el().wFull().h(20.5).shrink(0)
                }
                .onVisibleRows { _, _ in false }
            return col().key("scroll").sizeFull().dir(.rtl).scrollY().child(wholeRows ? rows.wholeRows() : rows)
        }
        func checkWindow(firstVisible: Int) throws {
            let list = try #require(runtime.virtualLists.values.first)
            let window = try #require(list.lastMountedSnapshot)
            let index = window.range.lowerBound
            let row = try #require(runtime.flatNodes.first { $0.key == "r\(index)" })
            #expect(window.range.contains(firstVisible))
            #expect(window.range.count < count)
            #expect(row.localRect.top == Float(index) * height)
            #expect(row.localRect.height == height)
            #expect(list.measuredByKey["r\(index)"] == height)
            #expect(window.topSpacerH == Float(index) * height)
            #expect(window.botSpacerH == Float(count - window.range.upperBound) * height)
            #expect(runtime.scrollMaxExtents[list.scrollPath]?.y == Float(count) * height - runtime.viewport.y)
            let visibleCount = Int((runtime.viewport.y / height).rounded(.up))
            #expect(list.reportedVisibleRange == firstVisible..<(firstVisible + visibleCount))
            #expect(runtime.scrollOffset(forKey: "scroll").y == Float(firstVisible) * height)
        }

        _ = runtime.frame(at: 0)
        try checkWindow(firstVisible: 0)
        #expect(runtime.element(byKey: "r240") == nil)
        runtime.update(at: 0.01) { _, tx in tx.scrollKeyTo("r240", at: 0) }
        _ = runtime.frame(at: 0.02)
        try checkWindow(firstVisible: 240)
        #expect(runtime.element(byKey: "r240")?.rect[1] == 0)
        runtime.setViewport(Vec2(220, 126), pixelScale: 1.5)
        _ = runtime.frame(at: 0.03)
        try checkWindow(firstVisible: 240)
    }

    #if DEBUG
    @Test("Whole-row debug diagnostics identify containers that cannot stack whole rows")
    func invalidContainers() {
        let site = UUID().uuidString
        let runtime = Runtime(state: (), viewport: Vec2(160, 120), pixelScale: 1) { _, _ in
            col().key(site).sizeFull().children([
                row().key("horizontal"),
                col().key("wrapping").flexWrap(),
                col().key("scroll-x").scrollX().children([el().size(10, 8), el().size(10, 8)]),
                col().key("vertical"),
            ])
        }
        _ = runtime.frame(at: 0)
        var nodes = runtime.flatNodes
        for index in nodes.indices where nodes[index].key != nil {
            nodes[index].el = nodes[index].el.wholeRows()
        }
        var messages: [String] = []
        LayoutDiagnostics.checkCollapsedScrolls(nodes: nodes) { messages.append($0) }
        LayoutDiagnostics.checkCollapsedScrolls(nodes: nodes) { messages.append($0) }
        #expect(messages.count == 3)
        for key in ["horizontal", "wrapping", "scroll-x"] {
            #expect(messages.contains { $0.contains("@\(key)") })
        }
    }
    #endif
}
