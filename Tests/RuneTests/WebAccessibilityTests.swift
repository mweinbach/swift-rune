import Foundation
import Testing
@testable import Rune

@Suite @MainActor
struct WebAccessibilityTests {
    private func send(_ action: String, _ path: String, _ host: WebBrowserSession, at time: Double) throws -> Bool {
        let data = try JSONSerialization.data(withJSONObject: ["kind": "accessibility", "action": action, "key": path])
        return host.send(data, at: time)
    }

    @Test func focusAndPressAreDistinctAndStateReachesTheBrowser() throws {
        let app = AppSpec<Bool>(title: "Browser switch", size: Vec2(150, 80), state: false) { value, _ in
            el().key("toggle").role(.switchControl).label("Lights").selected(value ? "true" : "false")
                .focusable(true).size(80, 30).onClick { $0.toggle() }
        }
        let host = WebAppHost(spec: app)
        let session = WebBrowserSession(host)
        _ = try session.renderFrame(at: 0)
        func accessibilityRoot() throws -> [String: Any] {
            let data = try #require(session.takeAccessibility())
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return try #require(result?["root"] as? [String: Any])
        }
        let first = try accessibilityRoot()
        let path = try #require(first["path"] as? String)
        #expect(first["role"] as? String == "switch")
        #expect(first["name"] as? String == "Lights")
        #expect(first["value"] as? String == "false")
        #expect(session.takeAccessibility() == nil)
        #expect(try send("focus", path, session, at: 0.1))
        _ = try session.renderFrame(at: 0.1)
        #expect(!host.runtime.state)
        let focused = try accessibilityRoot()["states"] as? [String]
        #expect(focused?.contains("focused") == true)
        #expect(try send("press", path, session, at: 0.2))
        _ = try session.renderFrame(at: 0.2)
        #expect(host.runtime.state)
        #expect(try accessibilityRoot()["value"] as? String == "true")
    }

    @Test func secretStaysInsideTheModel() throws {
        struct State { var edit = TextEdit("private-value") }
        let host = WebAppHost(spec: AppSpec<State>(title: "Credentials", size: Vec2(150, 80), state: State()) { _, _ in
            textInput(key: "secret", \.edit).label("Account password").secure(true).size(120, 30)
        })
        let session = WebBrowserSession(host)
        _ = try session.renderFrame(at: 0)
        let packet = try #require(session.takeAccessibility())
        let json = String(decoding: packet, as: UTF8.self)
        #expect(json.contains("Account password"))
        #expect(json.contains("password-input"))
        #expect(!json.contains("private-value"))
    }

    @Test func focusOnTheSecondInlineLinkDoesNotFollowIt() throws {
        let app = AppSpec<String>(title: "Documentation", size: Vec2(320, 80), state: "") { _, _ in
            text("Docs About").key("content").size(180, 32).focusable(true)
                .link(TextLink(0..<4, id: "docs")).link(TextLink(5..<10, id: "about"))
                .onLink { last, id in last = id }
        }
        let host = WebAppHost(spec: app)
        let session = WebBrowserSession(host)
        let idle = try #require(try session.renderFrame(at: 0))
        let link = try #require(host.runtime.elements().first { $0.key == "about" })
        #expect(try send("focus", link.path, session, at: 0.1))
        #expect(host.runtime.focusedKey == "about")
        #expect(host.runtime.focusedLinkIndex == 1)
        #expect(host.runtime.state.isEmpty)
        let focused = try #require(try session.renderFrame(at: 0.1))
        let idleRects = idle.instances.filter { $0.params.y == KIND_RECT }
        let focusedRects = focused.instances.filter { $0.params.y == KIND_RECT }
        #expect(focusedRects.count > idleRects.count)
        #expect(try send("press", link.path, session, at: 0.2))
        #expect(host.runtime.state == "about")
    }
    #if canImport(Metal) || canImport(CRuneOffscreenGL)
    @Test func retainedCardMovesItsInlineLinkHitBounds() throws {
        let pan = Live<Vec2>(.zero)
        let runtime = Runtime<String>(state: "", viewport: Vec2(320, 100), pixelScale: 1) { _, _ in
            let links: El<String> = text("Docs About").key("content").size(100, 30).focusable()
                .link(TextLink(0..<4, id: "docs")).link(TextLink(5..<10, id: "about"))
                .onLink { last, id in last = id }
            return el().sizeFull().child(el().sizeFull().liveOffset(pan.binding).child(
                el().size(100, 30).cache().child(links)
            ))
        }
        let gpu = try OffscreenGPURenderer()
        _ = try gpu.renderOffscreen(gpu.frame(runtime, at: 0))
        let old = try #require(runtime.find("about"))
        pan.set(Vec2(120, 16))
        let moved = try gpu.frame(runtime, at: 0.1)
        #expect(moved.elidedLayers.count == 1)
        _ = try gpu.renderOffscreen(moved)
        let point = try #require(runtime.find("about"))
        #expect(abs(point.x - old.x - 120) < 1 && abs(point.y - old.y - 16) < 1)

        #expect(runtime.accessibilityAction("about", .focus, at: 0.12))
        let focused = try gpu.frame(runtime, at: 0.13)
        #expect(focused.elidedLayers.isEmpty)
        _ = try gpu.renderOffscreen(focused)
        let retainedFocus = try gpu.frame(runtime, at: 0.14)
        #expect(retainedFocus.elidedLayers.count == 1)
        #expect(runtime.elements().first { $0.key == "about" }?.focusVisible == true)
        runtime.pointerDown(at: old, at: 0.2)
        runtime.pointerUp(at: old, at: 0.21)
        #expect(runtime.state.isEmpty)
        runtime.pointerDown(at: point, at: 0.3)
        runtime.pointerUp(at: point, at: 0.31)
        #expect(runtime.state == "about")

        pan.set(Vec2(400, 0))
        _ = try gpu.frame(runtime, at: 0.4)
        let clipped = try #require(runtime.elements().first { $0.key == "about" })
        #expect(clipped.visible[2] == 0 && clipped.visible[3] == 0)
    }
    #endif
}
