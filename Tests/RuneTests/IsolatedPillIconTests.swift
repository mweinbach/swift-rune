#if canImport(CoreText) || os(Linux) || os(Windows)
import Testing
@testable import Rune

@Suite("Inline pill icons and caret geometry")
@MainActor
struct IsolatedPillIconTests {
    private let textSystem = TextSystem()
    private let icon = BareIcon(SVGIcon(viewBox: 12, paths: ["M1 1H11V11H1Z"]), size: 12)

    @Test("the icon leads the label in the surrounding paragraph's direction",
          arguments: [TextFlow.rtl, .ltr], [false, true])
    func exteriorIcon(flow: TextFlow, bare: Bool) throws {
        let prefix = flow == .rtl ? "שלום " : "Review "
        let label = flow == .rtl ? "Pending" : "עבודות"
        let bytes = prefix.utf8.count..<(prefix.utf8.count + label.utf8.count)
        let pill = PillChip(bytes, icon: icon, isBare: bare, bareGap: 4)
        var style = TextStyle(size: 16, wrap: .wrap)
        style.byParagraphStart = flow
        let shaped = textSystem.shape(text: prefix + label, pills: [pill], style: style,
                                      maxWidth: 320, pixelScale: 2, emitGlyphs: true)
        #expect(shaped.lineIsRTL == [flow == .rtl])
        let iconRect: SIMD4<Float>
        if bare {
            #expect(shaped.inlineIcons.count == 1)
            #expect(shaped.pillChips.isEmpty)
            iconRect = try #require(shaped.inlineIcons.first).rect
        } else {
            #expect(shaped.pillChips.count == 1)
            let chip = try #require(shaped.pillChips.first)
            iconRect = try #require(chip.iconRect)
            #expect(chip.rect.x <= iconRect.x && iconRect.x + iconRect.z <= chip.rect.x + chip.rect.z)
        }
        // The rendered label glyphs have authored byte offsets and unambiguous positions,
        // including when an isolate boundary has distinct strong and weak carets.
        let glyphs = shaped.glyphs.filter { bytes.contains($0.utf8Offset) && $0.rect.z > 0 }
        let left = try #require(glyphs.map(\.rect.x).min())
        let right = try #require(glyphs.map { $0.rect.x + $0.rect.z }.max())
        if flow == .rtl {
            #expect(iconRect.x >= right - 1)
        } else {
            #expect(iconRect.x + iconRect.z <= left + 1)
        }
    }

    @Test("only the first fragment of a wrapped isolated pill carries the icon")
    func wrappedIcon() throws {
        let label = "Review every change before publishing this package"
        let pill = PillChip(0..<label.utf8.count, icon: icon)
        var style = TextStyle(size: 16, wrap: .wrap)
        style.byParagraphStart = .rtl
        let shaped = textSystem.shape(text: label, pills: [pill], style: style, maxWidth: 115,
                                      pixelScale: 2, emitGlyphs: true)
        #expect(shaped.pillChips.count > 1)
        let first = try #require(shaped.pillChips.first)
        let iconRect = try #require(first.iconRect)
        #expect(shaped.pillChips.dropFirst().allSatisfy { $0.iconRect == nil && $0.rect.y > first.rect.y })
        let firstLine = shaped.lineUTF8Range(at: 0)
        let firstGlyphs = shaped.glyphs.filter { firstLine.contains($0.utf8Offset) && $0.rect.z > 0 }
        let labelRight = try #require(firstGlyphs.map { $0.rect.x + $0.rect.z }.max())
        #expect(iconRect.x >= labelRight - 1)
    }

    @Test("ordinary pill padding and icons map to authored caret boundaries", arguments: [TextFlow.ltr, .rtl])
    func ordinaryPillCursor(flow: TextFlow) throws {
        let rtl = flow == .rtl
        let prefix = rtl ? "אב " : "go "
        let label = rtl ? "שָל" : "e\u{301}x"
        let text = prefix + label + (rtl ? " גד" : " on")
        let bytes = prefix.utf8.count..<(prefix.utf8.count + label.utf8.count)
        let shaped = textSystem.shape(text: text, pills: [PillChip(bytes, icon: icon)],
                                      style: TextStyle(size: 18, direction: flow),
                                      maxWidth: nil, pixelScale: 2, emitGlyphs: false)
        let chip = try #require(shaped.pillChips.first)
        let iconRect = try #require(chip.iconRect)
        let begin = textSystem.caretRect(in: shaped, utf8Offset: bytes.lowerBound, affinity: .downstream, pixelScale: 2)
        let end = textSystem.caretRect(in: shaped, utf8Offset: bytes.upperBound, affinity: .upstream, pixelScale: 2)
        let left = chip.rect.x
        let right = chip.rect.x + chip.rect.z
        #expect(rtl ? begin.x >= right - 0.5 : begin.x <= left + 0.5)
        #expect(rtl ? end.x <= left + 0.5 : end.x >= right - 0.5)
        func hit(_ x: Float) -> Int {
            textSystem.hitTestUTF8Offset(in: shaped, localX: x, localY: iconRect.y + iconRect.w / 2, pixelScale: 2)
        }
        #expect(hit(iconRect.x + iconRect.z * 0.25) == bytes.lowerBound)
        #expect(hit(iconRect.x + iconRect.z * 0.75) == bytes.lowerBound)
        #expect(hit(rtl ? left + 1 : right - 1) == bytes.upperBound)

        // This is a visual pill over editable text. The editor advances once per
        // authored grapheme, including the combining mark in the first letter.
        let firstEnd = bytes.lowerBound + (try #require(label.first)).utf8.count
        let stops = [bytes.lowerBound - 1, bytes.lowerBound, firstEnd, bytes.upperBound, bytes.upperBound + 1]
        var edit = TextEdit(text)
        edit.setCursor(utf8Offset: stops[0])
        for next in stops.dropFirst() {
            _ = edit.handleKey(KeyEvent(key: rtl ? .arrowLeft : .arrowRight), layout: shaped)
            try #require(edit.cursor == next)
        }
        for previous in stops.dropLast().reversed() {
            _ = edit.handleKey(KeyEvent(key: rtl ? .arrowRight : .arrowLeft), layout: shaped)
            try #require(edit.cursor == previous)
        }
    }
}
#endif
