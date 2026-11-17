import Testing
import Rune
@testable import RuneLuau

@Suite("Detached Luau virtual lists")
struct DetachedVirtualListTests {
    @Test func uniformGeometryMatchesTheMeasuredList() {
        for count in [0, 1, 23, 145] {
            for (height, gap): (Float, Float) in [(1, -3), (17.25, 0), (17.25, 3.5), (8, 45)] {
                let list = VirtualListState()
                list.gap = gap
                list.setItems((0..<count).map { VirtualItemSpec(key: String($0), estimatedHeight: height) })
                let stride = height + max(0, gap)
                let offset = stride * Float(count / 2)
                let offsets = [-10, 0, height, stride, offset - 0.25, offset, offset + height, offset + stride, list.totalHeight + 600]
                for scroll in offsets {
                    for viewport: Float in [0, 0.25, 20, 300] {
                        let window = detachedListWindow(count: count, estimate: height, gap: gap, scrollY: scroll, viewportHeight: viewport)
                        #expect(window == list.computeWindow(scrollY: scroll, viewportHeight: viewport))
                    }
                }
            }
        }
    }

    @Test func scrollingAndShrinkingLargeListsOnlyBuildTheMountedRows() throws {
        let script = Script(name: "detached", sources: .single("""
            local ui = require("@rune/ui")
            local count, keys, visible = 100000, 0, {}
            return {
                resize = function(size) count = size end,
                stats = function() return {keys = keys, first = visible.first, last = visible.last} end,
                render = function()
                    return ui.virtualList({
                        key = "rows", count = count, estimatedRowHeight = 16, gap = 4,
                        rowKey = function(i) keys += 1; return i end,
                        renderRow = function(i) return ui.text(i) end,
                        onVisibleRows = function(e) visible = e end,
                    })
                end,
            }
            """))
        func render(_ offset: Float) -> El<Int> {
            script.renderUncached(name: "render", dark: false, viewport: Vec2(80, 40),
                                  scrollLookup: { _ in Vec2(0, offset) }, Int.self)
        }
        let mid = render(1_000_000)
        let rows = mid.children.compactMap(\.plainText)
        #expect(rows == (49_989...50_014).map(String.init))
        #expect(mid.children.first?.layout.height == .points(999_760))
        #expect(mid.children.last?.layout.height == .points(999_720))
        let stats = try script.query("stats")
        #expect(stats.get("keys").asInt64 == Int64(rows.count))
        #expect(stats.get("first").asInt64 == 50_001)
        #expect(stats.get("last").asInt64 == 50_002)

        try script.call("resize", args: [.integer(4)])
        let truncated = render(1_000_000)
        #expect(truncated.children.compactMap(\.plainText) == ["2", "3", "4"])
        #expect(truncated.children.first?.layout.height == .points(20))
        #expect(try script.query("stats").get("first").asInt64 == 4)

        try script.call("resize", args: [.integer(0)])
        #expect(render(1_000_000).children.isEmpty)
        let empty = try script.query("stats")
        #expect(empty.get("first").asInt64 == 0)
        #expect(empty.get("last").asInt64 == 0)
    }
}
