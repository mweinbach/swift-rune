import Foundation
import Testing
@testable import Rune

@Suite @MainActor
struct WebAccessibilityDocumentTests {
    private func flatten(_ node: AccessibilityNode) -> [String: AccessibilityNode] {
        var nodes: [String: AccessibilityNode] = [:]
        func visit(_ item: AccessibilityNode) {
            nodes[item.id] = item
            for child in item.children { visit(child) }
        }
        visit(node)
        return nodes
    }

    @Test func documentAnchorsFocusAndBandPositions() throws {
        let rt = Runtime(state: (), viewport: Vec2(400, 200), pixelScale: 3) { _, _ in
            col().key("doc").role(.main).wFull()
                .child(el().wFull().h(100.05).shrink(0))
                .child(text("Guide").key("guide-title").role(.heading).wFull().h(30).shrink(0))
                .child(text("No fragment").key("9 invalid").role(.heading).wFull().h(30).shrink(0))
                .child(text("Read guide").key("jump").role(.link).href("#guide-title").focusable().wFull().h(40).shrink(0))
                .child(el().key("chapter").htmlRole("article").label("Chapter").wFull().h(50).shrink(0))
                .child(el().wFull().h(1500).shrink(0))
        }
        #expect(WebAccessibilityDocument(rt) == nil)
        rt.pageMode()
        _ = rt.frame(at: 0)
        let document = try #require(WebAccessibilityDocument(rt))
        func snapshot() -> [String: AccessibilityNode] {
            var tree = rt.accessibilitySnapshot()
            document.project(&tree)
            return flatten(tree)
        }
        let first = snapshot()
        let heading = try #require(first["guide-title"])
        #expect(heading.webDocument?.anchor == "guide-title")
        #expect(heading.webDocument?.selectable == true)
        #expect(heading.webDocument?.font?.family.isEmpty == false)
        #expect(first["9 invalid"]?.webDocument?.anchor == nil)
        #expect(first["jump"]?.url == "#guide-title")
        #expect(first["jump"]?.webDocument?.selectable == false)
        let chapter = try #require(first["chapter"])
        let html = AccessibilityDump.dictionary(from: chapter, isRoot: false, forBrowser: true)
        #expect(html["role"] as? String == "article" && html["name"] as? String == "Chapter")
        #expect(chapter.webDocument?.anchor == "chapter")
        let path = try #require(first["jump"]?.runtimePath)
        #expect(rt.accessibilityAction(path, .focus, at: 0))
        _ = rt.frame(at: 0)
        #expect(snapshot()["jump"]?.isFocused == true)
        for y in [-42] + (1..<20).map({ Float($0) * 137.3333 }) {
            #expect(rt.setPageScroll(y, at: 0))
            _ = rt.frame(at: 0)
            let moved = snapshot()
            #expect(try #require(moved["guide-title"]).frame == heading.frame)
            #expect(moved["jump"]?.isFocused == true)
        }
        rt.pageMode(false)
        #expect(WebAccessibilityDocument(rt) == nil)
    }

    @Test func documentLinksCarryPrintableUnicodeRanges() throws {
        let rt = Runtime(state: (), viewport: Vec2(400, 100), pixelScale: 1) { _, _ in
            text("See 🦊 *Rune and café.").key("intro").p(4).size(300, 50).label("Documentation links")
                .link(TextLink(10..<14, id: "https://example.com", label: "Rune website"))
                .link(TextLink(19..<24, id: "more")).uncopied(9..<10)
        }
        rt.pageMode()
        _ = rt.frame(at: 0)
        var tree = rt.accessibilitySnapshot()
        try #require(WebAccessibilityDocument(rt)).project(&tree)
        let items = flatten(tree)
        let intro = try #require(items["intro"])
        #expect(intro.frame.left == 4 && intro.frame.top == 4)
        #expect(intro.label == "Documentation links")
        #expect(intro.webDocument?.text == "See 🦊 Rune and café.")
        let first = try #require(items["https://example.com"])
        #expect(first.label == "Rune website")
        #expect(first.webDocument?.inlineRange == 7..<11)
        #expect(items["more"]?.webDocument?.inlineRange == 16..<20)
        let json = AccessibilityDump.dictionary(from: first, isRoot: false, forBrowser: true)
        #expect(json["inlineStart"] as? Int == 7 && json["inlineEnd"] as? Int == 11)
    }

    @Test func nestedHorizontalContainersRetainOwnOffsetsAndContentPositions() throws {
        let rt = Runtime(state: (), viewport: Vec2(400, 200), pixelScale: 1) { _, _ in
            let inner: El<Void> = row().key("inner").size(180, 40).shrink(0).scrollX()
                .child(text("Code sample").key("code").w(410).h(40).shrink(0))
            let outer: El<Void> = row().key("outer").size(200, 40).shrink(0).scrollX()
                .child(el().size(60, 40).shrink(0)).child(inner).child(el().size(360, 40).shrink(0))
            return col().role(.main).wFull().child(outer)
        }
        rt.pageMode()
        _ = rt.frame(at: 0)
        let document = try #require(WebAccessibilityDocument(rt))
        var initial = rt.accessibilitySnapshot()
        document.project(&initial)
        let before = flatten(initial)
        let outer = try #require(before["outer"]), inner = try #require(before["inner"]), code = try #require(before["code"])
        #expect(outer.webDocument?.contentWidth == 600)
        #expect(inner.webDocument?.contentWidth == 410)
        #expect(rt.setPageScrollX(try #require(outer.runtimePath), x: 40))
        #expect(rt.setPageScrollX(try #require(inner.runtimePath), x: 95))
        _ = rt.frame(at: 0)
        var updated = rt.accessibilitySnapshot()
        document.project(&updated)
        let after = flatten(updated)
        #expect(after["outer"]?.webDocument?.scrollX == 40)
        #expect(after["inner"]?.webDocument?.scrollX == 95)
        #expect(after["inner"]?.frame == inner.frame)
        #expect(after["code"]?.frame == code.frame)
    }

    @Test func browserCanFocusAndPressAnInlineDocumentLinkOutsideThePaintBand() throws {
        let spec = AppSpec<String>(title: "Long article", size: Vec2(300, 120), state: "") { _, _ in
            col().role(.main).wFull()
                .child(text("Top link").key("top").link(TextLink(4..<8, id: "first")).wFull().h(30).shrink(0))
                .child(el().h(2200).shrink(0))
                .child(text("Last link").key("bottom").link(TextLink(5..<9, id: "last"))
                    .onLink { state, id in state = id }.wFull().h(30).shrink(0))
        }
        let host = WebAppHost(spec: spec, config: WebAppConfig(webDocument: true))
        let session = WebBrowserSession(host)
        session.enableAccessibilityPatches()
        _ = host.runtime.frame(at: 0)
        let owner = try #require(host.runtime.element(byKey: "bottom")).path
        #expect(host.runtime.linkBoxesByPath[owner] == nil)
        let initial = try #require(session.takeAccessibility())
        let json = String(decoding: initial, as: UTF8.self)
        #expect(json.contains("first") && json.contains("last"))
        let path = owner + "#link-0"
        for action in ["focus", "press"] {
            let event = try JSONSerialization.data(withJSONObject: ["kind": "accessibility", "action": action, "key": path])
            #expect(session.send(event, at: 0.1))
            #expect(host.runtime.focusedKey == "last")
            #expect(host.runtime.state == (action == "focus" ? "" : "last"))
        }
        _ = try session.renderFrame(at: 0.1)
        _ = session.takeAccessibility()
        #expect(session.send(Data(#"{"kind":"pageScroll","y":2150}"#.utf8), at: 0.2))
        _ = try session.renderFrame(at: 0.2)
        #expect(session.takeAccessibility() == nil)
    }

    @Test func nativeHorizontalScrollDoesNotPatchTheDocumentThatSentIt() throws {
        let spec = AppSpec<Void>(title: "Code", size: Vec2(300, 120), state: ()) { _, _ in
            row().key("strip").size(200, 40).scrollX().child(text("Code").size(600, 40).shrink(0))
        }
        let host = WebAppHost(spec: spec, config: WebAppConfig(webDocument: true))
        let session = WebBrowserSession(host)
        session.enableAccessibilityPatches()
        _ = try session.renderFrame(at: 0)
        #expect(session.takeAccessibility() != nil)
        let path = try #require(host.runtime.element(byKey: "strip")).path
        let event = try JSONSerialization.data(withJSONObject: ["kind": "pageScrollX", "key": path, "x": 120])
        #expect(session.send(event, at: 0.1))
        _ = try session.renderFrame(at: 0.1)
        #expect(host.runtime.scrollOffset(forKey: "strip").x == 120)
        #expect(session.takeAccessibility() == nil)

        #expect(host.runtime.setPageScrollX(path, x: 160))
        _ = try session.renderFrame(at: 0.2)
        let update = try #require(session.takeAccessibility())
        let packet = try #require(JSONSerialization.jsonObject(with: update) as? [String: Any])
        let nodes = try #require(packet["nodes"] as? [[String: Any]])
        let strip = try #require(nodes.first { ($0["path"] as? String) == path })
        #expect((strip["pageScrollX"] as? NSNumber)?.floatValue == 160)
        #expect(session.send(event, at: 0.3))
        _ = try session.renderFrame(at: 0.3)
        #expect(session.takeAccessibility() == nil)
    }
}
