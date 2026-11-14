import Foundation
import Testing
@testable import Rune
@testable import RuneKit

@Suite("Markdown Phase 2 Parity Tests (#882, #853)", .serialized)
struct MarkdownPhase2ParityTests {

    private static func collectTextElements<S>(_ root: El<S>) -> [El<S>] {
        var out: [El<S>] = []
        func walk(_ el: El<S>) {
            if el.role == .text || el.plainText != nil || (el.richSpans != nil && !el.richSpans!.isEmpty) {
                out.append(el)
            }
            for child in el.children {
                walk(child)
            }
        }
        walk(root)
        return out
    }

    @Test("#882: Streaming Markdown sets wrapGreedy only on the last block while settled earlier blocks allow pretty wrap")
    @MainActor
    func streamingLastBlockWrapGreedy() {
        defer { TextSystem.setPrettyWrap(false) }
        TextSystem.setPrettyWrap(true)

        let source = "First settled paragraph with enough prose.\n\nSecond active trailing paragraph still streaming"
        let style = MarkdownStyle.fromKit(Kit.neutral(dark: true))
        let streamingRoot: El<Int> = Markdown(source).streaming(true).render(style)
        let settledRoot: El<Int> = Markdown(source).streaming(false).render(style)

        let streamingTexts = Self.collectTextElements(streamingRoot).filter {
            let txt = $0.plainText ?? $0.richSpans?.map(\.text).joined() ?? ""
            return txt.contains("First settled") || txt.contains("Second active")
        }
        let settledTexts = Self.collectTextElements(settledRoot).filter {
            let txt = $0.plainText ?? $0.richSpans?.map(\.text).joined() ?? ""
            return txt.contains("First settled") || txt.contains("Second active")
        }

        #expect(streamingTexts.count == 2)
        #expect(settledTexts.count == 2)
        if streamingTexts.count == 2 {
            #expect(streamingTexts[0].isWrapGreedy == false)
            #expect(streamingTexts[1].isWrapGreedy == true)
        }
        for el in settledTexts {
            #expect(el.isWrapGreedy == false)
        }
    }

    @Test("#853: Inline code keeps its own inlineCodeWeight inside bold and linked bold Markdown spans")
    @MainActor
    func inlineCodeWeightOverridesBold() throws {
        let style = MarkdownStyle.fromKit(Kit.neutral(dark: true))
            .inlineCodeFont(scale: 0.9, weight: 530)
            .inlineCodePad(4)

        let root: El<Int> = Markdown("**bold `code` bold**").render(style)
        let richEl = try #require(Self.collectTextElements(root).first { el in
            el.richSpans?.contains(where: { $0.text.contains("code") }) == true
        })
        let spans = try #require(richEl.richSpans)

        let boldSpans = spans.filter { $0.text.contains("bold") }
        let codeSpans = spans.filter { $0.text.trimmingCharacters(in: .whitespaces) == "code" || ($0.monospace && $0.text.contains("code")) }
        #expect(boldSpans.count == 2)
        #expect(!codeSpans.isEmpty)
        for sp in boldSpans {
            #expect(sp.weight == style.strongWeight)
        }
        for sp in codeSpans {
            #expect(sp.weight == 530)
            #expect(sp.monospace)
        }

        // Code inside a link inside bold text also retains inlineCodeWeight (530) over strongWeight.
        let linkedRoot: El<Int> = Markdown("**[`linked_code`](https://example.com) tail**").render(style)
        let linkedEl = try #require(Self.collectTextElements(linkedRoot).first { el in
            el.richSpans?.contains(where: { $0.text.contains("linked_code") }) == true
        })
        let linkedCode = try #require(linkedEl.richSpans?.first(where: { $0.text.contains("linked_code") }))
        let linkedTail = try #require(linkedEl.richSpans?.first(where: { $0.text.contains("tail") }))
        #expect(linkedCode.weight == 530)
        #expect(linkedTail.weight == style.strongWeight)
    }
}
