#if os(macOS) && canImport(AppKit)
import AppKit
import Testing
@testable import Rune

@MainActor
private final class EditorAccessibilityView: NSView {
    override var isFlipped: Bool { true }
}

@Suite("Shaped field ranges through the macOS accessibility host")
@MainActor
struct A11yShapedFieldTests {
    @Test func aShortFieldWithAWaitingRowReadsItsWholeValue() throws {
        struct Form { var draft: TextEdit }
        let paragraph = "alpha bravo charlie delta echo foxtrot golf hotel"
        let text = paragraph + "\n🦀 tail"
        let runtime = Runtime(state: Form(draft: TextEdit(text, multiline: true)),
                              viewport: Vec2(180, 180), systemDark: false) { _, _ in
            textInput(key: "draft", \Form.draft).w(90).h(160)
        }
        _ = runtime.frame(at: 0)
        let start = paragraph.utf8.count + 1
        #expect(runtime.accessibilitySelectText("draft", range: start..<(start + 4), at: 0.01))
        _ = runtime.frame(at: 0.02)
        let host = MacOSAccessibilityHost()
        let view = EditorAccessibilityView(frame: NSRect(x: 0, y: 0, width: 180, height: 180))
        host.update(tree: runtime.accessibilitySnapshot(), parentView: view, onAction: { _, _ in })
        let field = try #require(host.accessibilityFocusedUIElement() as? NSAccessibilityElement)
        let firstLetter = NSRange(location: 0, length: 1)
        try #require(field.accessibilityFrame(for: firstLetter).height > 0)

        let node = try #require(runtime.flatNodes.first { $0.key == "draft" })
        var retained = try #require(runtime.nodeTextLayouts[node.nodeId])
        retained.box = retained.box.clone()
        try #require(retained.box.shaped.lineStrings.count >= 3)
        // Waiting paragraphs have an estimated position but no Core Text line yet.
        retained.box.shaped.lineStrings[1].ctLine = nil
        runtime.nodeTextLayouts[node.nodeId] = retained
        host.update(tree: runtime.accessibilitySnapshot(), parentView: view, onAction: { _, _ in })
        #expect(field.accessibilityValue() as? String == text)
        #expect(field.accessibilitySelectedText() == "🦀")
        #expect(field.accessibilityRange(forLine: 0) == NSRange(location: 0, length: start))
        #expect(field.accessibilityRange(forLine: 1) == NSRange(location: start, length: "🦀 tail".utf16.count))
        #expect(field.accessibilityFrame(for: firstLetter) == .zero)
    }

    @Test func aRetainedFieldUsesScreenGeometryForWrappedLinesAndFallsBackForLongValues() throws {
        struct Form { var draft: TextEdit }
        let short = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima"
        let runtime = Runtime(
            state: Form(draft: TextEdit(short, multiline: true)),
            viewport: Vec2(220, 220), pixelScale: 2, systemDark: false
        ) { _, _ in
            col().p(12).child(
                textInput(key: "draft", \Form.draft)
                    .font(TextStyle(size: 15, weight: 400).lh(20)).wrap(.wrap).w(112).h(168)
            )
        }

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 320, y: 210, width: 220, height: 220),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let view = EditorAccessibilityView(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
        window.contentView = view
        let host = MacOSAccessibilityHost()

        func refresh(at time: Double) {
            _ = runtime.frame(at: time)
            host.update(tree: runtime.accessibilitySnapshot(), parentView: view, onAction: { _, _ in })
        }
        refresh(at: 0)
        #expect(runtime.accessibilitySelectText("draft", range: 0..<5, at: 0.01))
        refresh(at: 0.02)
        let field = try #require(host.accessibilityFocusedUIElement() as? NSAccessibilityElement)

        #expect(field.accessibilitySelectedText() == "alpha")
        #expect(field.accessibilitySelectedTextRange() == NSRange(location: 0, length: 5))
        let firstLine = field.accessibilityRange(forLine: 0)
        let secondLine = field.accessibilityRange(forLine: 1)
        try #require(firstLine.length > 0 && firstLine.length < short.utf16.count)
        try #require(secondLine.length > 0 && secondLine.location == NSMaxRange(firstLine))
        #expect(field.accessibilityLine(for: secondLine.location) == 1)
        #expect(field.accessibilityString(for: secondLine) == (short as NSString).substring(with: secondLine))

        let firstLetter = NSRange(location: 0, length: 1)
        let secondLineLetter = NSRange(location: secondLine.location, length: 1)
        let top = field.accessibilityFrame(for: firstLetter)
        let next = field.accessibilityFrame(for: secondLineLetter)
        try #require(top.width > 0 && top.height > 0 && next.width > 0 && next.height > 0)
        let screen = window.convertToScreen(view.convert(view.bounds, to: nil))
        #expect(screen.contains(top) && screen.contains(next))
        #expect(next.midY < top.midY)
        #expect(next.height == top.height)
        for fraction in [0.25, 0.75] {
            let point = NSPoint(x: next.minX + next.width * fraction, y: next.midY)
            #expect(field.accessibilityRange(for: point) == secondLineLetter)
        }
        let start = secondLineLetter.location
        #expect(runtime.accessibilitySelectText("draft", range: start..<(start + 1), at: 0.025))
        refresh(at: 0.026)
        #expect(field.accessibilitySelectedTextRange() == secondLineLetter)
        #expect(field.accessibilityInsertionPointLineNumber() == 1)

        let paragraph = String(repeating: "x", count: 256) + "\n"
        let long = String(repeating: paragraph, count: 257) + "end"
        runtime.update(at: 0.03) { state, _ in state.draft = TextEdit(long, multiline: true) }
        refresh(at: 0.04)
        #expect(host.accessibilityFocusedUIElement() as? NSAccessibilityElement === field)
        #expect(field.accessibilityNumberOfCharacters() == long.utf16.count)
        #expect(field.accessibilityRange(forLine: 0) == NSRange(location: 0, length: paragraph.utf16.count))
        #expect(field.accessibilityRange(forLine: 257) == NSRange(location: 257 * paragraph.utf16.count, length: 3))
        #expect(field.accessibilityFrame(for: firstLetter) == .zero)

        runtime.update(at: 0.05) { state, _ in state.draft = TextEdit(short, multiline: true) }
        refresh(at: 0.06)
        #expect(host.accessibilityFocusedUIElement() as? NSAccessibilityElement === field)
        #expect(field.accessibilityRange(forLine: 1) == secondLine)
        #expect(field.accessibilityFrame(for: firstLetter) == top)
    }
}
#endif
