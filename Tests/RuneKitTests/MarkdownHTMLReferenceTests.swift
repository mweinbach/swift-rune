import Testing
@testable import RuneKit

struct MarkdownHTMLReferenceTests {
    @Test func onlyMarkdownBlockStartsDefineReferences() {
        let source = """
        [x].

            [x]: /indented

        ```
        [x]: /fenced
        ```

        Words
        [x]: /paragraph

        > <div>
        > [x]: /quotedHtml

        - <section>
          [x]: /listHtml

        See [x].
        """
        let expected: [MarkdownDocBlock] = [
            .para(MarkdownInline(text: "[x].")), .code("[x]: /indented"), .code("[x]: /fenced"),
            .para(MarkdownInline(text: "Words [x]: /paragraph")),
            .quote([]), .list(start: nil, items: [[]]), .para(MarkdownInline(text: "See [x].")),
        ]
        #expect(MarkdownParser.parseAST(source) == expected)
        #expect(Markdown(source).streaming(true).document().blocks == expected)
    }

    @Test func nestedDefinitionResolvesEarlierLinksAndKeepsFirstDestination() {
        let source = """
        [a][r].

        <div>
        [r]: /hidden
        </div>

        > - [r]: /public

        [r]: /later

        [b][r].
        """
        let style = MarkdownStyleSpan(start: 0, end: 1, style: .link)
        let link = MarkdownLinkSpan(start: 0, end: 1, url: "/public")
        let expected: [MarkdownDocBlock] = [
            .para(MarkdownInline(text: "a.", spans: [style], links: [link])),
            .quote([.list(start: nil, items: [[]])]),
            .para(MarkdownInline(text: "b.", spans: [style], links: [link])),
        ]
        #expect(MarkdownParser.parseAST(source) == expected)
        #expect(Markdown(source).streaming(true).document().blocks == expected)
        let leading = "[r]: /public\n[r]: /later\n\n[a][r]."
        #expect(MarkdownParser.parseAST(leading) == [expected[0]])
    }

    @Test func streamedMultilineDefinitionsResolveRetainedImagesAndLinks() {
        let chunks = [
            "![P][Some  Label]\n\nSee [link][some label].\n\n",
            "[some\n", "label]", ":", "\n", "  <img&amp;", "x>\n",
            "  \"hello\n", "    world\"", "\n\n[SOME Label]: /later",
        ]
        let cache = MarkdownDocCache(budgetBytes: 1 << 20, frameGeneration: { 0 })
        var source = ""
        let before = cache.docCached(chunks[0])
        for chunk in chunks {
            source += chunk
            #expect(cache.docCached(source) == MarkdownParser.parseDocument(source))
            #expect(cache.streamCached(source) == MarkdownTailStream.parseStreaming(source, autolink: true))
        }
        let expected: [MarkdownDocBlock] = [
            .image(src: "img&x", alt: "P", title: "hello\nworld"),
            .para(MarkdownInline(text: "See link.", spans: [.init(start: 4, end: 8, style: .link)],
                                 links: [.init(start: 4, end: 8, url: "img&x")])),
        ]
        let after = cache.docCached(source)
        #expect(after.blocks == expected)
        #expect(cache.streamCached(source).blocks == expected)
        #expect(before.blocks != expected)
        #expect(MarkdownFind.findAll(in: source, doc: after, query: "link", caseSensitivity: .sensitive) == [[24..<28]])
    }

    @Test func referenceDefinitionsRespectContainerAndParagraphBoundaries() {
        let nested = "[link][Some Label].\n\n> - [SOME\n>   LABEL]:\n>    <url>\n>   (title\n>     line)\n\n![P][some label]."
        let link = MarkdownInline(text: "link.", spans: [.init(start: 0, end: 4, style: .link)],
                                  links: [.init(start: 0, end: 4, url: "url")])
        #expect(MarkdownParser.parseAST(nested) == [
            .para(link), .quote([.list(start: nil, items: [[]])]),
            .image(src: "url", alt: "P", title: "title\nline"), .para(MarkdownInline(text: ".")),
        ])
        let ordinary = "Words\n[a\nb]: /one\n\n- words\n  [a\n  b]: /two\n\nCheck [a b]."
        #expect(MarkdownParser.parseAST(ordinary) == [
            .para(MarkdownInline(text: "Words [a b]: /one")),
            .list(start: nil, items: [[.para(MarkdownInline(text: "words [a b]: /two"))]]),
            .para(MarkdownInline(text: "Check [a b].")),
        ])
        let interrupted = "[r]:\n# heading\n\n[r]."
        #expect(MarkdownParser.parseAST(interrupted) == [
            .para(MarkdownInline(text: "[r]:")), .heading(level: 1, MarkdownInline(text: "heading")),
            .para(MarkdownInline(text: "[r].")),
        ])
        let invalidTitle = "[r]: /uri\n\"unfinished\n\nSee [r]."
        #expect(MarkdownParser.parseAST(invalidTitle) == [
            .para(MarkdownInline(text: "\"unfinished")),
            .para(MarkdownInline(text: "See r.", spans: [.init(start: 4, end: 5, style: .link)],
                                 links: [.init(start: 4, end: 5, url: "/uri")])),
        ])
    }

    @Test func escapedAndUnicodeReferenceKeysMatchUpstream() {
        let refs = "[a\\]b]: /escaped\n[ß]: /case\n[e\u{301}]: /accent\n\n[X][a\\]b] [Y][SS] [é]."
        guard case let .para(inline) = MarkdownParser.parseAST(refs).last else {
            Issue.record("Expected the paragraph after the definitions")
            return
        }
        #expect(inline.text == "X Y [é].")
        #expect(inline.links == [.init(start: 0, end: 1, url: "/escaped"), .init(start: 2, end: 3, url: "/case")])
        let unresolved = "[r]: /ok\n\n[r][missing]."
        #expect(MarkdownParser.parseAST(unresolved) == [.para(MarkdownInline(text: "[r][missing]."))])
    }
}
