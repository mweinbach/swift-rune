import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("Scrolled text rasterization")
struct ScrollGlyphRasterWindowTests {
    enum Painter: CaseIterable, Sendable {
        case reference, native
    }

    enum Content: CaseIterable, Sendable {
        case label, field
    }

    enum Breaks: CaseIterable, Sendable {
        case hard, wrapped
    }

    private struct Note {
        var edit: TextEdit
    }

    private struct Glyph {
        let rect: SIMD4<Float>
        let fill: SIMD4<Float>
    }

    private func draw<State>(_ runtime: Runtime<State>, using painter: Painter, at time: Double) -> [Glyph] {
        switch painter {
        case .reference:
            return runtime.frame(at: time).primitives.compactMap {
                $0.kind == .glyph ? Glyph(rect: $0.rect, fill: $0.fill) : nil
            }
        case .native:
            return runtime.renderFrame(at: time).instances.compactMap {
                $0.params.y == KIND_GLYPH ? Glyph(rect: $0.rect, fill: $0.fill) : nil
            }
        }
    }

    private func scrollView(_ content: Content, breaks: Breaks, lastLine: String) -> Runtime<Note> {
        let separator = breaks == .hard ? "\n" : " "
        let document = String(repeating: "plain lowercase words only" + separator, count: 500) + lastLine
        return Runtime(state: Note(edit: TextEdit(document, multiline: true)), viewport: Vec2(300, 300), pixelScale: 2) { note, _ in
            let body: El<Note>
            switch content {
            case .label:
                body = text(note.edit.text).key("note")
            case .field:
                body = textInput(key: "note", \Note.edit).singleLine(false)
            }
            return col().sizeFull().child(
                col().key("viewport").wFull().h(200).shrink(0).scrollY().child(
                    body.wFull().shrink(0).font(TextStyle(size: 14, weight: 400, lineHeight: 20, wrap: .wrap))
                )
            )
        }
    }

    static let documents = Content.allCases.flatMap { content in Breaks.allCases.map { (content, $0) } }

    @Test("An unseen last line adds no glyph masks until it scrolls into view",
          arguments: Painter.allCases, documents)
    func deferredAtlasMasks(painter: Painter, document: (Content, Breaks)) throws {
        let (content, breaks) = document
        let control = scrollView(content, breaks: breaks, lastLine: "words only")
        let runtime = scrollView(content, breaks: breaks, lastLine: "QUIZ JOKE VEX")
        let controlGlyphs = draw(control, using: painter, at: 0)
        let firstGlyphs = draw(runtime, using: painter, at: 0)
        let firstEntries = runtime.textSystem.glyphAtlas.cachedEntryCount
        #expect(firstEntries > 0)
        #expect(firstEntries == control.textSystem.glyphAtlas.cachedEntryCount)
        let firstCount = firstGlyphs.count
        #expect((1..<400).contains(firstCount))
        let sameVisibleGlyphs = firstGlyphs.elementsEqual(controlGlyphs) { $0.rect == $1.rect }
        #expect(sameVisibleGlyphs)

        let viewport = try #require(runtime.element(byKey: "viewport")?.rect)
        let body = try #require(runtime.element(byKey: "note")?.rect)
        #expect(viewport == [0, 0, 300, 200])
        #expect(body[3] > viewport[3] * 10)
        if breaks == .hard {
            #expect(body[3] == 10_020)
            let lineHeightPx = 20 * runtime.pixelScale
            let paintedRows = Set(firstGlyphs.map { glyph in
                let centerY = glyph.rect.y + glyph.rect.w / 2
                return Int((centerY / lineHeightPx).rounded(.down))
            })
            #expect(paintedRows.isSuperset(of: 0..<10))
        }
        runtime.update(at: 1.0 / 60) { _, tx in
            tx.scrollToInstant("viewport", x: 0, y: 100_000)
        }
        let lastGlyphs = draw(runtime, using: painter, at: 2.0 / 60)
        #expect(abs(runtime.scrollOffset(forKey: "viewport").y - (body[3] - viewport[3])) < 1)
        let lastCount = lastGlyphs.count
        #expect((1..<400).contains(lastCount))
        #expect(runtime.textSystem.glyphAtlas.cachedEntryCount > firstEntries)
    }

    private func tightLeadingView(linesAbove: Int, largeSpan: Bool = true) -> Runtime<Void> {
        let document = String(repeating: "a\n", count: linesAbove) + (largeSpan ? "T" : "a")
        let start = document.utf8.count - 1
        return Runtime(state: (), viewport: Vec2(200, 200), pixelScale: 2) { _, _ in
            col().sizeFull().child(
                col().key("viewport").wFull().h(50).shrink(0).scrollY().child(
                    text(document).wFull().shrink(0)
                        .font(TextStyle(size: 10, weight: 400, lineHeight: 5, wrap: .wrap))
                        .spans(largeSpan ? [RichSpan(start..<(start + 1)).size(120).color(.srgb(1, 0, 0))] : [])
                )
            )
        }
    }

    private func hasRedInk(_ runtime: Runtime<Void>, using painter: Painter) throws -> Bool? {
        let frame: Frame
        switch painter {
        case .reference:
            frame = try RuneRef.render(runtime.frame(at: 0))
        case .native:
            #if canImport(Metal) || canImport(CRuneOffscreenGL)
            do {
                frame = try OffscreenGPURenderer().renderOffscreen(runtime.renderFrame(at: 0))
            } catch OffscreenRenderError.unavailable {
                return nil
            }
            #else
            return nil
            #endif
        }
        return stride(from: 0, to: frame.rgba.count, by: 4).contains { i in
            let red = Int(frame.rgba[i])
            return red > Int(frame.rgba[i + 1]) + 20 && red > Int(frame.rgba[i + 2]) + 20
        }
    }

    @Test("Large spans preserve ink overhang across the viewport edge", arguments: Painter.allCases)
    func overhangingAscender(painter: Painter) throws {
        // The original Rust fixture caches both sizes and submits eleven glyphs.
        // Native text backends differ in mask padding and tiling at the clip edge.
        let upstreamFixture = tightLeadingView(linesAbove: 15)
        let original = draw(upstreamFixture, using: painter, at: 0)
        let control = tightLeadingView(linesAbove: 15, largeSpan: false)
        _ = draw(control, using: painter, at: 0)
        #expect(upstreamFixture.textSystem.glyphAtlas.cachedEntryCount > control.textSystem.glyphAtlas.cachedEntryCount)
        #if os(macOS)
        #expect(original.count == 11)
        if painter == .reference { #expect(upstreamFixture.textSystem.glyphAtlas.cachedEntryCount == 2) }
        #else
        #expect((10...11).contains(original.count))
        #endif
        if let redInk = try hasRedInk(upstreamFixture, using: painter) { #expect(!redInk) }

        // This T's line starts at 60 pt. Its ascender crosses the 50 pt clip.
        let runtime = tightLeadingView(linesAbove: 12)
        let glyphs = draw(runtime, using: painter, at: 0)
        let ascender = try #require(glyphs.first { $0.fill.x > 0.9 && $0.fill.y < 0.1 })
        let viewport = try #require(runtime.element(byKey: "viewport")?.rect)
        #expect(ascender.rect.y < viewport[3] * runtime.pixelScale)
        #expect(ascender.rect.y + ascender.rect.w > 0)
        if let redInk = try hasRedInk(runtime, using: painter) { #expect(redInk) }
    }
}
