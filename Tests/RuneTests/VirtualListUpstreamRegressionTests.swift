import Testing
@testable import Rune

@Suite
struct VirtualListUpstreamRegressionTests {
    private struct PagingState {
        let windowed: Bool
        var keys = Array(0..<600)
    }

    private struct VisibleRow: Equatable {
        let key: String
        let rect: [Float]
    }

    private static func pagingView(_ state: PagingState, _: inout Cx<PagingState>) -> El<PagingState> {
        var rows: El<PagingState> = col().key("rows").wFull().pt(8).pb(24).growth()
        if state.windowed { rows = rows.virtualize(80) }
        for key in state.keys {
            let suffix = String(repeating: "variable height héllo naïve ", count: key % 7 + 1)
            rows = rows.child(col().key("r\(key)").wFull().pb(9).child(
                text("Row \(key): \(suffix)").wrap(.wrap).wFull()
            ))
        }
        return col().key("scroll").wFull().hFull().clipFade(top: 8, bottom: 8)
            .scrollY(stickBottom: true).child(rows)
    }

    private static func visibleRows(_ runtime: Runtime<PagingState>) -> [VisibleRow] {
        runtime.elements().compactMap { element in
            guard let key = element.key, key.hasPrefix("r"), key != "rows", element.visible[3] > 0 else {
                return nil
            }
            return VisibleRow(key: key, rect: element.rect)
        }
    }

    @Test("Virtual rows match full layout while paging and keep a keyed anchor")
    func virtualRowsMatchFullLayoutWhilePagingAndKeepAKeyedAnchor() throws {
        let viewport = Vec2(240, 300)
        let full = Runtime(state: PagingState(windowed: false), viewport: viewport,
                           pixelScale: 2, systemDark: true, view: Self.pagingView)
        let window = Runtime(state: PagingState(windowed: true), viewport: viewport,
                             pixelScale: 2, systemDark: true, view: Self.pagingView)
        var time = 0.0
        let tick = 1.0 / 120.0
        _ = full.frame(at: time)
        _ = window.frame(at: time)
        #expect(window.flatNodes.count < 100)
        #expect(window.textSystem.shapedCount < full.textSystem.shapedCount / 5)

        for step in 0..<135 {
            let expected = Self.visibleRows(full)
            let actual = Self.visibleRows(window)
            try #require(actual.map(\.key) == expected.map(\.key), "visible rows at paging step \(step)")
            for (got, want) in zip(actual, expected) {
                let matches = zip(got.rect, want.rect).allSatisfy { abs($0 - $1) < 0.05 }
                try #require(matches, "step \(step), \(got.key): \(got.rect) versus \(want.rect)")
            }
            let wheel = WheelEvent(dx: 0, dy: step < 90 ? 137.25 : -137.25, precise: true)
            full.wheel(wheel, at: Vec2(120, 150), now: time)
            window.wheel(wheel, at: Vec2(120, 150), now: time)
            time += tick
            _ = full.frame(at: time)
            _ = window.frame(at: time)
        }

        let before = Self.visibleRows(window)
        window.update(at: time) { state, _ in state.keys.insert(9000, at: 0) }
        time += tick
        _ = window.frame(at: time)
        let after = Self.visibleRows(window)
        try #require(after == before, "prepended offscreen content changed a visible row")
        #expect(window.flatNodes.count < 150)
        #expect(window.growthRows.count < 70)
        let anchor = try #require(after.first)

        window.setViewport(Vec2(320, 300))
        _ = window.frame(at: time)
        for step in 0..<60 {
            let row = try #require(Self.visibleRows(window).first { $0.key == anchor.key })
            try #require(abs(row.rect[1] - anchor.rect[1]) < 0.05,
                         "resize step \(step), \(row.key): y=\(row.rect[1]) versus \(anchor.rect[1])")
            time += tick
            _ = window.frame(at: time)
        }
        window.settleAll()
        _ = window.frame(at: time)
        let last = try #require(Self.visibleRows(window).last)
        #expect(last.key == "r599")
        #expect(abs(last.rect[1] + last.rect[3] - 276) < 0.05)
        #expect(!window.isAnimating)
    }

    @Test("Stored rows drop before their replacement builders run")
    func storedRowsDropBeforeTheRowBuildersRun() throws {
        final class Token {}
        final class Probe {
            weak var token: Token?
            var builds = 0
            var buildsWithOldRow = 0
        }
        struct State {
            let probe: Probe
            var indexed = false
        }
        let probe = Probe()
        let runtime = Runtime(state: State(probe: probe), viewport: Vec2(400, 200), pixelScale: 2,
                              systemDark: true) { state, _ in
            var stack: El<State> = col().key("stack").wFull().growth()
            if state.indexed {
                stack = stack.virtualRows(count: 30, estimatedRowHeight: 40, key: { _, i in "r\(i)" }) { s, i in
                    s.probe.builds += 1
                    if s.probe.token != nil { s.probe.buildsWithOldRow += 1 }
                    return el().key("r\(i)").wFull().h(40).bg(.white)
                }
            } else {
                stack = stack.virtualize(40).children((0..<30).map { i in
                    let row: El<State> = el().key("r\(i)").wFull().h(40).bg(.white)
                    guard i == 25 else { return row }
                    let token = Token()
                    state.probe.token = token
                    return row.onClick { _, _ in withExtendedLifetime(token) {} }
                })
            }
            return col().wFull().hFull().child(col().key("scroll").wFull().h(200).scrollY().child(stack))
        }
        var time = 0.0
        func runUntilIdle() {
            for _ in 0..<1200 {
                time += 1.0 / 120.0
                _ = runtime.frame(at: time)
                if !runtime.isAnimating && !runtime.needsCommit { return }
            }
            Issue.record("the virtual list did not settle")
        }
        _ = runtime.frame(at: time)
        runUntilIdle()
        try #require(probe.token != nil, "the stored offscreen row must still own the token")
        #expect(runtime.element(byKey: "r25") == nil)
        try #require(runtime.virtualSelectionSources.values.contains { $0.storedChildren.contains { $0.keyId == "r25" } })

        runtime.update(at: time) { state, _ in state.indexed = true }
        runUntilIdle()
        #expect(probe.builds > 0)
        #expect(probe.buildsWithOldRow == 0)
        #expect(probe.token == nil)
    }
}
