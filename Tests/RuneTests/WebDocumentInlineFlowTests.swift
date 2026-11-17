import Foundation
import Testing
@testable import Rune

@Suite @MainActor
struct WebDocumentInlineFlowTests {
    private func allNodes(_ root: AccessibilityNode) -> [AccessibilityNode] {
        [root] + root.children.flatMap { allNodes($0) }
    }

    @Test func tokenRowsMirrorAsLinesAndDistantColumnsRemainSeparate() throws {
        func line(_ n: Int, _ words: [String]) -> El<Void> {
            var tokens: El<Void> = row().key("tokens").h(20)
            for (i, word) in words.enumerated() {
                tokens = tokens.child(text(word).key("t\(i)").mono().size(Float(word.count * 8), 20).shrink(0))
            }
            return row().key("line\(n)").h(20)
                .child(row().key("gutter").size(32, 20).shrink(0).child(text(String(n)).mono()))
                .child(tokens)
        }
        let rt = Runtime(state: (), viewport: Vec2(480, 300), pixelScale: 1) { _, _ in
            col().wFull()
                .child(line(1, ["type", " ", "Port", " = ", "Int"]))
                .child(line(2, ["listen", "(", "port", ")"]))
                .child(row().key("words").gap(4).child(text("Hello")).child(text("world")))
                .child(row().key("pair").w(300).justifyBetween().child(text("Name")).child(text("Kit")))
        }
        rt.pageMode()
        _ = rt.frame(at: 0)
        var tree = rt.accessibilitySnapshot()
        try #require(WebAccessibilityDocument(rt)).project(&tree)
        let lines = allNodes(tree).filter { $0.role == .text }
        let words = lines.compactMap(\.label)
        #expect(words == ["1", "type Port = Int", "2", "listen(port)", "Hello world", "Name", "Kit"])
        let declaration = try #require(lines.first { $0.label == "type Port = Int" })
        #expect(declaration.frame.left == 32 && declaration.frame.width == 120)
    }

    @Test func wrappedWordsKeepPunctuationAndOriginalLinkActions() throws {
        let spec = AppSpec<String>(title: "Flow", size: Vec2(200, 150), state: "") { _, _ in
            let reference: El<String> = text("café").key("flow-1").size(40, 20)
                .link(TextLink(0..<5, id: "cafe-link", label: "Café details"))
                .onLink { last, id in last = id }
            return col().role(.main).wFull()
                .child(row().key("sentence").w(88).flexWrap()
                    .child(row().size(40, 20).child(text("🦊").key("flow-0").size(40, 20)))
                    .child(row().size(52, 20).child(reference))
                    // A variation selector joins the comma's grapheme cluster. Rust checks the first scalar.
                    .child(text(",\u{FE0F}").key("flow-2").size(8, 20))
                    .child(text("today").key("flow-3").size(44, 20)))
                .child(text("Continue").key("reader").label("Read more").role(.button).focusable())
        }
        let host = WebAppHost(spec: spec, config: WebAppConfig(webDocument: true))
        let session = WebBrowserSession(host)
        _ = try session.renderFrame(at: 0)
        let data = try #require(session.takeAccessibility())
        let packet = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let root = try #require(packet["root"] as? [String: Any])
        #expect(packet["document"] as? Bool == true)
        func descendants(_ item: [String: Any]) -> [[String: Any]] {
            [item] + (item["children"] as? [[String: Any]] ?? []).flatMap(descendants)
        }
        let nodes = descendants(root)
        let sentence = try #require(nodes.first { ($0["documentText"] as? String ?? $0["name"] as? String) == "🦊 café,\u{FE0F} today" })
        let links = try #require(sentence["children"] as? [[String: Any]])
        let link = try #require(links.first { $0["name"] as? String == "Café details" })
        #expect(link["inlineStart"] as? Int == 3 && link["inlineEnd"] as? Int == 7)
        let target = try #require(host.runtime.elements().first { $0.key == "cafe-link" })
        let path = try #require(link["path"] as? String)
        #expect(path == target.path)
        let press = try JSONSerialization.data(withJSONObject: ["kind": "accessibility", "key": path, "action": "press"])
        #expect(session.send(press, at: 0.1))
        #expect(host.runtime.state == "cafe-link")
        #expect(nodes.contains { $0["role"] as? String == "button" && $0["name"] as? String == "Read more" })
    }

    @Test func adjacentWordsRetainReferencedKeysAndExplicitSpokenLabels() throws {
        let rt = Runtime(state: (), viewport: Vec2(400, 100), pixelScale: 1) { _, _ in
            col().wFull()
                .child(row().h(20)
                    .child(text("Pay").key("before").size(40, 20))
                    .child(text("in").key("unit").size(16, 20))
                    .child(text("USD").key("currency").label("US dollars").size(32, 20))
                    .child(text("today").key("after").size(48, 20)))
                .child(el().key("field").role(.button).labelledBy("unit").size(40, 20))
        }
        rt.pageMode()
        _ = rt.frame(at: 0)
        var tree = rt.accessibilitySnapshot()
        try #require(WebAccessibilityDocument(rt)).project(&tree)
        let nodes = allNodes(tree)
        let line = nodes.filter { $0.role == .text }
        #expect(line.map(\.id) == ["before", "unit", "currency", "after"])
        #expect(line.compactMap(\.label) == ["Pay", "in", "US dollars", "today"])
        #expect(line.first { $0.id == "currency" }?.webDocument?.text == "USD")
    }
}
