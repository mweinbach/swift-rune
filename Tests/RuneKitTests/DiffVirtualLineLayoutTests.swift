@testable import Rune
import RuneKit
import Testing

@Suite("Virtual unified diff line layout")
struct DiffVirtualLineLayoutTests {
    @Test("Entering lines keep their own text, highlights, geometry and selection",
          arguments: [false, true])
    @MainActor
    func enteringLines(wholeRows: Bool) throws {
        let first = Color(r: 0.875, g: 0.25, b: 0.625)
        let second = Color(r: 0.125, g: 0.75, b: 0.875)
        let lines = (1...160).map { number in
            let prefix = number.isMultiple(of: 2) ? "even" : "odd"
            return DiffLine(kind: .context, oldNumber: number, newNumber: number, text: "\(prefix) value_\(number)")
        }
        let hunk = DiffHunk(oldStart: 1, oldCount: lines.count, newStart: 1, newCount: lines.count, lines: lines)
        let file = FileDiff(oldPath: "sample.swift", newPath: "sample.swift", hunks: [hunk])

        func highlighter(swapped: Bool) -> SyntaxHighlighter {
            SyntaxHighlighter(id: "unified-line-layout-\(swapped)") { _, chunk in
                var start = 0
                return chunk.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
                    defer { start += line.utf8.count + 1 }
                    guard !line.isEmpty else { return nil }
                    let even = line.hasPrefix("even")
                    return SyntaxHighlight(range: start..<(start + (even ? 4 : 3)), paint: .color(even == swapped ? first : second))
                }
            }
        }

        // A zero-width layout border keeps the reference list on the ordinary solver.
        func configure(_ el: El<DiffState>, ordinary: Bool) -> El<DiffState> {
            if el.storageKeyId == "diff-rows" {
                return (wholeRows ? el.wholeRows() : el).borderLayout(ordinary)
            }
            var result = el
            for index in result.children.indices {
                result.children[index] = configure(result.children[index], ordinary: ordinary)
            }
            return result
        }
        func make(_ ordinary: Bool) -> Runtime<DiffState> {
            var state = DiffState(diff: file)
            state.setHighlighter(highlighter(swapped: false))
            return Runtime(state: state, viewport: Vec2(400, 160), pixelScale: 2) { state, cx in
                let diff = DiffView<DiffState>(key: "diff", kit: .neutral(dark: true), get: { $0 }, set: { $0 = $1 })
                    .showHeader(false)
                    .lineHeight(wholeRows ? 1.0375 : 1)
                    .build(state: state, cx: cx)
                return col().wFull().hFull().child(configure(diff, ordinary: ordinary))
            }
        }

        let actual = make(false), reference = make(true)
        var now = 0.0
        func compare() {
            now += 1.0 / 60
            let frame = actual.renderFrame(at: now), expected = reference.renderFrame(at: now)
            #expect(frame.instances.map(\.rect) == expected.instances.map(\.rect))
            #expect(frame.instances.map(\.fill) == expected.instances.map(\.fill))
            #expect(actual.elements() == reference.elements())
            #expect(actual.accessibilitySnapshot() == reference.accessibilitySnapshot())
        }
        for _ in 0..<5 { compare() }
        let initial = Set(actual.elements().map(\.path))
        for _ in 0..<8 {
            for runtime in [actual, reference] {
                runtime.wheel(WheelEvent(dx: 0, dy: -160), at: Vec2(220, 90), now: now)
            }
            compare()
        }

        let row = try #require(actual.elements().first {
            $0.key?.hasPrefix("diff-row-") == true && !initial.contains($0.path) && $0.visible[3] >= 20
                && $0.visible[1] > 40 && $0.visible[1] < 120
        })
        let index = try #require(row.key.flatMap { Int($0.dropFirst("diff-row-".count)) })
        #expect(row.rect[3] == (wholeRows ? 20.75 : 20))
        let shell = try #require(actual.flatNodes.first { $0.path == row.path }.flatMap(\.parentIndex))
        #expect(actual.flatNodes[shell].localSize.y == (wholeRows ? 21 : 20))

        func checkLabel(swapped: Bool) throws {
            let leaf = try #require(actual.flatNodes.first { $0.key == "diff-code-\(index)-text" })
            let record = try #require(actual.nodeTextLayouts[leaf.nodeId])
            let authored = lines[index].text
            #expect(record.box.authText == authored)
            #expect(record.box.spans?.first?.color == (authored.hasPrefix("even") == swapped ? first : second))
        }
        try checkLabel(swapped: false)
        for runtime in [actual, reference] {
            runtime.update(at: now) { state, _ in state.setHighlighter(highlighter(swapped: true)) }
        }
        compare()
        try checkLabel(swapped: true)
        let gutter = try #require(actual.element(byKey: "diff-n-\(index)"))
        let point = Vec2(gutter.rect[0] + gutter.rect[2] / 2, gutter.rect[1] + gutter.rect[3] / 2)
        for runtime in [actual, reference] {
            runtime.pointerMove(to: point, at: now)
            _ = runtime.renderFrame(at: now)
            runtime.pointerDown(at: point, at: now)
            runtime.pointerUp(at: point, at: now + 0.001)
        }
        compare()
        #expect(actual.state.selectedRange == .line(DiffLineRef(side: .new, line: UInt32(index + 1))))
        #expect(actual.state.selectedText() == lines[index].text)
    }
}
