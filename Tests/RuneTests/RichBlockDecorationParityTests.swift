import Testing
@testable import Rune

@MainActor
@Suite("Rich field block decorations")
struct RichBlockDecorationParityTests {
    private struct State {
        var field: TextEdit
    }

    private let width: Float = 140
    private let scale: Float = 2
    private let padding: Float = 6
    private let font = TextStyle(size: 14, lineHeight: 20, family: .monospace, wrapAnywhere: true)
    private let red = Color.srgb(1, 0, 0, 1).simd4(srgb: true)
    private let green = Color.srgb(0, 1, 0, 1).simd4(srgb: true)
    private let blue = Color.srgb(0, 0, 1, 1).simd4(srgb: true)

    private func runtime(_ field: TextEdit) -> Runtime<State> {
        let height: Float = 420
        let palette = RichStyle(codeBlockBg: .srgb(0, 1, 0, 1), quoteBar: .srgb(1, 0, 0, 1), marker: .srgb(0, 0, 1, 1))
        return Runtime(state: State(field: field), viewport: Vec2(width, height), pixelScale: scale) { _, _ in
            textInput(key: "field", \State.field).size(width, height).p(padding).font(font).richStyle(palette)
        }
    }

    @Test("adjacent code and quote paragraphs cover their wrapped visual lines with one decoration per run")
    func codeAndQuoteRuns() throws {
        let paragraphs = [String(repeating: "x", count: 32), "c", "q", "q", "p", "c"]
        let blocks: [Block] = [.code, .code, .quote, .quote, .paragraph, .code]
        let rt = runtime(.fromRichParts(text: paragraphs.joined(separator: "\n"), blocks: blocks))
        let ref = rt.frame(at: 0)
        let shaped = try #require(rt.nodeTextLayouts.values.first(where: { $0.isInput })?.box.shaped)
        let lines = rt.textSystem.visualLines(in: shaped)
        let quoteStart = paragraphs[0].utf8.count + 3
        let quoteLine = try #require(lines.firstIndex(where: { $0.utf8Start == quoteStart }))
        #expect(quoteLine > 2)
        let last = try #require(lines.indices.last)
        let origin = padding * scale
        let boxWidth = (width - 2 * padding) * scale
        let qTop = origin + shaped.lineTopPt(quoteLine) * scale
        let qEnd = origin + shaped.lineTopPt(quoteLine + 2) * scale
        let codeRects = [
            SIMD4<Float>(origin, origin - 4, boxWidth, qTop - origin + 8),
            SIMD4<Float>(origin, origin + shaped.lineTopPt(last) * scale - 4, boxWidth, shaped.lineBoxHeightPt(last) * scale + 8)
        ]
        let quoteRect = SIMD4<Float>(origin + 4, qTop + 4, 6, qEnd - qTop - 8)
        let cpuCode = ref.primitives.filter { $0.kind == .roundedRect && $0.fill == green }
        let cpuQuotes = ref.primitives.filter { $0.kind == .roundedRect && $0.fill == red }
        #expect(cpuCode.map(\.rect) == codeRects)
        #expect(cpuCode.map(\.radii.x) == [12, 12])
        #expect(cpuQuotes.map(\.rect) == [quoteRect])
        #expect(cpuQuotes.map(\.radii.x) == [3])

        let metal = rt.renderFrame(at: 0.01)
        let gpuCode = metal.instances.filter { $0.fill == green }
        let gpuQuotes = metal.instances.filter { $0.fill == red }
        #expect(gpuCode.map(\.rect) == codeRects)
        #expect(gpuCode.map(\.radii.x) == [12, 12])
        #expect(gpuQuotes.map(\.rect) == [quoteRect])
        #expect(gpuQuotes.map(\.radii.x) == [3])
    }

    @Test("a wrapping placeholder leaves one marker in the empty field's font and gutter")
    func emptyFieldWithPlaceholder() throws {
        let placeholder = "Write a title or a brief description to get started"
        let placeholderFont = TextStyle(size: 24, lineHeight: 36, family: .monospace)
        let field = TextEdit.fromRichParts(text: "", blocks: [.bullet(0)])
        let rt = Runtime(state: State(field: field), viewport: Vec2(width, 350), pixelScale: scale) { _, _ in
            textInput(key: "field", \State.field).size(width, 350).p(padding).font(font)
                .richStyle(RichStyle(marker: .srgb(0, 0, 1, 1)))
                .placeholder(placeholder, color: .srgb(1, 0, 0, 1)).placeholderFont(placeholderFont)
        }
        let ref = rt.frame(at: 0)
        let dots = ref.primitives.filter { $0.kind == .roundedRect && $0.fill == blue }
        let dot = try #require(dots.first)
        let shaped = try #require(rt.nodeTextLayouts.values.first(where: { $0.isInput })?.box.shaped)
        let inset = Block.bullet(0).indentPt(fontSize: font.size)
        #expect(rt.textSystem.visualLines(in: shaped).allSatisfy { $0.originX == inset })
        let placeholderInk = ref.primitives.filter { $0.kind == .glyph && $0.fill == red }
        let top = try #require(placeholderInk.map(\.rect.y).min())
        let bottom = try #require(placeholderInk.map(\.rect.y).max())
        #expect(bottom - top > placeholderFont.linePx() * scale)
        #expect(dots.count == 1)
        let diameter: Float = 9
        let origin = padding * scale
        #expect(dot.rect.x == origin + (Block.bullet(0).indentPt(fontSize: font.size) * scale).rounded() - 14 - diameter)
        #expect(dot.rect.z == diameter && dot.rect.w == diameter)
        let baseline = origin + 0.8 * font.size * scale
        #expect(dot.rect.y == (baseline - 0.34 * font.size * scale - diameter / 2).rounded())
        #expect(dot.radii.x == diameter * 0.5)
        let markerIndex = try #require(ref.primitives.firstIndex(where: { $0.fill == blue }))
        let inkIndex = try #require(ref.primitives.firstIndex(where: { $0.fill == red }))
        #expect(markerIndex < inkIndex)

        let metal = rt.renderFrame(at: 0.01)
        let gpuDots = metal.instances.filter { $0.params.y == KIND_RECT && $0.fill == blue }
        #expect(gpuDots.map(\.rect) == [dot.rect])
        #expect(gpuDots.map(\.radii.x) == [dot.radii.x])
        let gpuMarker = try #require(metal.instances.firstIndex(where: { $0.fill == blue }))
        let gpuInk = try #require(metal.instances.firstIndex(where: { $0.fill == red }))
        #expect(gpuMarker < gpuInk)
    }

    @Test("nested counters resume, reset and skip a soft break; only the first wrapped line draws a marker")
    func listMarkers() throws {
        let blocks: [Block] = [
            .numbered(0), .numbered(1), .numbered(1), .numbered(1), .bullet(2),
            .numbered(0), .numbered(1), .paragraph, .numbered(0)
        ]
        let paragraphs = [String(repeating: "x", count: 32)] + Array(repeating: "x", count: blocks.count - 1)
        let rt = runtime(.fromRichParts(text: paragraphs.joined(separator: "\n"), blocks: blocks, softBreaks: [2]))
        let ref = rt.frame(at: 0)
        let numbers = ref.primitives.filter { $0.kind == .glyph && $0.fill == blue }
        let expected = ["1.", "1.", "2.", "2.", "1.", "1."].flatMap { label in
            rt.textSystem.shape(text: label, style: font, maxWidth: nil, pixelScale: scale).glyphs.map(\.uv)
        }
        #expect(expected.count == 12)
        #expect(numbers.map(\.uv) == expected)

        let shaped = try #require(rt.nodeTextLayouts.values.first(where: { $0.isInput })?.box.shaped)
        let lines = rt.textSystem.visualLines(in: shaped)
        let bulletByte = paragraphs.prefix(4).reduce(0) { $0 + $1.utf8.count + 1 }
        let visual = try #require(lines.firstIndex(where: { $0.utf8Start == bulletByte }))
        #expect(visual > 4)
        let origin = padding * scale
        let baseline = shaped.lineBaselinesPx.indices.contains(visual)
            ? shaped.lineBaselinesPx[visual] : (shaped.lineTopPt(visual) + 0.78 * shaped.lineHeight) * scale
        let diameter: Float = 9
        let x = origin + (Block.bullet(2).indentPt(fontSize: font.size) * scale).rounded() - 14 - diameter
        let y = (origin + baseline - 0.34 * font.size * scale - diameter / 2).rounded()
        let bulletRect = SIMD4<Float>(x, y, diameter, diameter)
        let bullets = ref.primitives.filter { $0.kind == .roundedRect && $0.fill == blue }
        #expect(bullets.map(\.rect) == [bulletRect])
        #expect(bullets.map(\.radii.x) == [2])

        let metal = rt.renderFrame(at: 0.01)
        let gpuNumbers = metal.instances.filter { $0.params.y == KIND_GLYPH && $0.fill == blue }
        let gpuBullets = metal.instances.filter { $0.params.y == KIND_RECT && $0.fill == blue }
        #expect(gpuNumbers.map(\.rect) == numbers.map(\.rect))
        let atlasW = Float(metal.glyphs.width), atlasH = Float(metal.glyphs.height)
        #expect(gpuNumbers.map { SIMD2($0.uv.x, $0.uv.y) } == expected.map { SIMD2($0.x * atlasW, $0.y * atlasH) })
        #expect(gpuBullets.map(\.rect) == [bulletRect])
        #expect(gpuBullets.map(\.radii.x) == [2])
    }
}
