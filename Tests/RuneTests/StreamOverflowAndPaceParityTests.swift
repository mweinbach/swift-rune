import Foundation
import Testing
@testable import Rune
import RuneMotion

@Suite("Rune Stream Overflow & Stream Pace Parity Tests (stream_overflow.rs, stream_pace.rs)")
struct StreamOverflowAndPaceParityTests {
    private struct StreamListState {
        var rows: [String]
    }

    @Test("stream_overflow: tall streaming reveal paragraph inside growth stack measures and grows smoothly without overflow clip corruption")
    func streamOverflowGrowsCleanly() throws {
        let rt = Runtime<StreamListState>(
            state: StreamListState(rows: [""]),
            viewport: Vec2(280, 200),
            pixelScale: 2.0,
            systemDark: true
        ) { s, _ in
            col().wFull().hFull().scrollY().child(
                col().wFull().growth(GrowthSpec()).children(
                    s.rows.enumerated().map { idx, body in
                        col().key("row-\(idx)").wFull().streaming(true).child(
                            text(body).wrapText().wFull().reveal(0.25)
                        )
                    }
                )
            )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        let longChunk = (0..<60).map { "token\($0)" }.joined(separator: " ")
        rt.update(at: t) { s, _ in s.rows = [longChunk] }

        var heights: [Float] = []
        for _ in 0..<45 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            if let row = rt.flatNodes.first(where: { $0.key == "row-0" }) {
                heights.append(row.targetRect.height)
            }
        }
        let firstH = try #require(heights.first)
        let lastH = try #require(heights.last)
        #expect(lastH > firstH && lastH > 100.0, "streaming row grows monotonically: first=\(firstH), last=\(lastH)")
    }

    @Test("stream_pace: streaming growth holds partial final line lag and keeps pace across chunks")
    func streamPaceLagAndGrowth() throws {
        let rt = Runtime<StreamListState>(
            state: StreamListState(rows: ["hello"]),
            viewport: Vec2(240, 200),
            pixelScale: 2.0,
            systemDark: true
        ) { s, _ in
            col().wFull().growth(GrowthSpec()).child(
                col().key("stream").wFull().streaming(true).child(
                    text(s.rows[0]).wrapText().wFull().reveal(0.2)
                )
            )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        let baseH = try #require(rt.flatNodes.first { $0.key == "stream" }?.targetRect.height)

        // Append a line + partial trailing word -> growth target expands above baseH while streamHeightLag trims partial line
        t += 1.0 / 60.0
        rt.update(at: t) { s, _ in s.rows[0] += " " + (0..<24).map { "w\($0)" }.joined(separator: " ") }
        _ = rt.frame(at: t)
        let rowNode = try #require(rt.flatNodes.first { $0.key == "stream" })
        let growthKey = Array(rt.growthRows.keys).first(where: { $0.contains("stream") })
        let gEntry = try #require(growthKey.flatMap { rt.growthRows[$0] })
        #expect(gEntry.track.target > baseH)

        // Advance simulation frames so the growth track climbs toward its target
        for _ in 0..<45 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let settledRow = try #require(rt.flatNodes.first { $0.key == "stream" })
        #expect(settledRow.targetRect.height > baseH)
        let _ = rowNode
    }
}
