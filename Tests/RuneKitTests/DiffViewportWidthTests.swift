import Rune
import RuneKit
import Testing

@Suite("Unwrapped diff viewport")
struct DiffViewportWidthTests {
    @Test("Scrolled rows fill the measured view, keep the gutter width and preserve horizontal overflow")
    @MainActor
    func rowWidthAndFarEdgeHover() throws {
        let old = (1...300).map { "let value_\($0) = compute(\($0));" }
        let new = old.enumerated().map { i, line in
            (i + 1).isMultiple(of: 7) ? String(line.dropLast()) + " + 1;" : line
        }
        let longestLine = new.map(\.utf8.count).max() ?? 0
        let file = FileDiff.fromTexts(path: "big.rs", old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        let rt = Runtime(state: DiffState(diff: file), viewport: Vec2(1200, 480), pixelScale: 2) { state, cx in
            let diff = DiffView<DiffState>(key: "dv", kit: .neutral(dark: true), get: { $0 }, set: { $0 = $1 })
                .onComment { _, _, _ in }
                .build(state: state, cx: cx)
            return col().wFull().maxW(900).hFull().child(diff)
        }
        var t = 0.0
        func settle() {
            for _ in 0..<8 {
                t += 1.0 / 30
                _ = rt.frame(at: t)
            }
        }
        settle()
        rt.wheel(WheelEvent(dx: 0, dy: -3200), at: Vec2(150, 240), now: t)
        settle()
        #expect(rt.scrollOffset(forKey: "dv-body").y > 1000)

        for (viewport, bodyWidth): (Float, Float) in [(1200, 900), (270, 270), (700, 700)] {
            rt.setViewport(Vec2(viewport, 480))
            settle()
            let elements = rt.elements()
            let body = try #require(rt.element(byKey: "dv-body"))
            let list = try #require(rt.element(byKey: "dv-rows"))
            let row = try #require(elements.first {
                $0.key?.hasPrefix("dv-df0.n") == true && $0.rect[1] > 60 && $0.rect[1] < 440
            })
            let children = elements.filter { $0.path.hasPrefix(row.path + "/") }
            let line = try #require(children.first { $0.key?.hasPrefix("dv-row-") == true })
            let gutter = try #require(children.first { $0.key?.hasPrefix("dv-gutter-") == true })
            let code = try #require(children.first { $0.key?.hasPrefix("dv-code-") == true })
            let plusKey = try #require(children.compactMap(\.key).first { $0.hasSuffix("-plus") })
            // Upstream reserves two 40-point number columns, a 3-point bar and 12/24 code insets.
            let expected = max(bodyWidth, 83 + 36 + Float(longestLine) * 7.8)
            #expect(body.rect[2] == bodyWidth)
            #expect(abs(list.rect[2] - expected) <= 0.5)
            #expect(abs(row.rect[2] - expected) <= 0.5)
            #expect(line.rect == row.rect)
            #expect(gutter.rect[2] == 83)
            #expect(code.rect[1] == row.rect[1] && code.rect[3] == row.rect[3])
            #expect(abs(code.rect[0] + code.rect[2] - (row.rect[0] + expected)) <= 0.5)
            let point = Vec2(body.rect[0] + bodyWidth - 48, row.rect[1] + 19)
            #expect(rt.elementAt(point.x, point.y)?.path.hasPrefix(code.path) == true)
            rt.pointerMove(to: point, at: t)
            settle()
            #expect(try #require(rt.element(byKey: plusKey)).opacity > 0.99)
            rt.pointerMove(to: Vec2(0, 0), at: t)
            settle()
            #expect(try #require(rt.element(byKey: plusKey)).opacity < 0.01)

            if bodyWidth < expected {
                rt.wheel(WheelEvent(dx: -1000, dy: 0), at: point, now: t)
                settle()
                #expect(abs(rt.scrollOffset(forKey: "dv-body").x - (expected - bodyWidth)) <= 1)
                rt.wheel(WheelEvent(dx: 1000, dy: 0), at: point, now: t)
                settle()
            }
        }
    }
}
