import Rune
import RuneKit
import Testing

@Suite("Diff code and line-number fonts")
struct DiffTypographyTests {
    @Test("Stock rows use 13-point monospace on 20-point lines and preserve an explicit kit font")
    @MainActor
    func codeAndGutterFonts() throws {
        let lines = ["MMMMMMMMMMMM", "first\nsecond\nthird"].enumerated().map { i, value in
            DiffLine(kind: .context, oldNumber: i + 1, newNumber: i + 1, text: value)
        }
        let hunk = DiffHunk(oldStart: 1, oldCount: 2, newStart: 1, newCount: 2, lines: lines)
        let file = FileDiff(oldPath: "text", newPath: "text", hunks: [hunk])

        struct Sample {
            var code: [SIMD4<Float>]
            var number: [SIMD4<Float>]
            var numberRight: Float
            var singleHeight: Float
            var multiHeight: Float
        }

        func sample(kit: Kit, scale: Float) throws -> Sample {
            let rt = Runtime(state: DiffState(diff: file), viewport: Vec2(700, 240), pixelScale: scale) { state, cx in
                DiffView<DiffState>(key: "f", kit: kit, get: { $0 }, set: { $0 = $1 }).build(state: state, cx: cx)
            }
            _ = rt.frame(at: 0)
            let scene = rt.frame(at: 0.1)
            func glyphs(in key: String) throws -> [SIMD4<Float>] {
                let r = try #require(rt.element(byKey: key)).rect
                return scene.primitives.compactMap { p in
                    guard p.kind == .glyph else { return nil }
                    let x = (p.rect.x + 0.5 * p.rect.z) / scale
                    let y = (p.rect.y + 0.5 * p.rect.w) / scale
                    guard x >= r[0], x < r[0] + r[2], y >= r[1], y < r[1] + r[3] else { return nil }
                    return p.rect
                }
            }
            let numberRect = try #require(rt.element(byKey: "f-n-0")).rect
            return try Sample(code: glyphs(in: "f-code-0"), number: glyphs(in: "f-n-0"),
                              numberRight: numberRect[0] + numberRect[2],
                              singleHeight: #require(rt.element(byKey: "f-df0.c1")).rect[3],
                              multiHeight: #require(rt.element(byKey: "f-df0.c2")).rect[3])
        }

        let stock = Kit.neutral(dark: true)
        var explicitStock = stock
        explicitStock.ty.mono = TextStyle(size: 13).mono().lh(20)
        var legacy = stock
        legacy.ty.mono = stock.ty.mono
        #expect(stock.ty.mono.size == 12 && stock.ty.mono.lineHeight == 18)
        #expect(stock.ty != legacy.ty)
        #expect(Set([stock.ty, legacy.ty]).count == 2)
        for scale: Float in [1, 1.25, 2] {
            let baseline = try sample(kit: stock, scale: scale)
            let desired = try sample(kit: explicitStock, scale: scale)
            let smaller = try sample(kit: legacy, scale: scale)
            #expect(!baseline.code.isEmpty && !baseline.number.isEmpty)
            let digitRight = try #require(baseline.number.map { $0.x + $0.z }.max()) / scale
            #expect(abs(baseline.numberRight - digitRight - 8) <= 2)
            #expect(baseline.code == desired.code)
            #expect(baseline.number == desired.number)
            #expect(baseline.code != smaller.code)
            #expect(baseline.singleHeight == 20 && baseline.multiHeight == 60)
            #expect(smaller.singleHeight == 20 && smaller.multiHeight == 54)
        }
    }
}
