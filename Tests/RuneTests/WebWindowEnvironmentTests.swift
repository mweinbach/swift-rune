import Foundation
import Testing
@testable import Rune

@Suite @MainActor
struct WebWindowEnvironmentTests {
    @Test func fittedCanvasMeasuresAtEmbeddedWidthAndDrainsHeightRequests() throws {
        let spec = AppSpec<Void>(title: "Inline", size: Vec2(130, 70), state: ()) { _, cx in
            el().h(cx.viewport.x / 4)
        }
        let host = WebAppHost(spec: spec, config: .init(canvasId: "chart", fitContentHeight: true))
        let session = WebBrowserSession(host)
        let resize = Data(#"{"kind":"resize","x":260,"y":90,"scale":2}"#.utf8)
        #expect(session.send(resize, at: 0))
        #expect(session.takeWindowHeight() == 65)
        #expect(session.takeWindowHeight() == nil)
        _ = host.runtime.updateIf(at: 1) { _, tx in tx.resizeWindow((80, 117)); return true }
        #expect(session.takeWindowHeight() == 117)
        #expect(session.takeWindowHeight() == nil)
        let vertical = Data(#"{"kind":"wheel","x":25,"y":10,"dx":1,"dy":20,"deltaMode":0}"#.utf8)
        let horizontal = Data(#"{"kind":"wheel","x":25,"y":10,"dx":20,"dy":1,"deltaMode":0}"#.utf8)
        #expect(!session.send(vertical, at: 2))
        #expect(session.send(horizontal, at: 2))
        let article = WebAppHost(spec: spec, config: .init(webDocument: true))
        let page = WebBrowserSession(article)
        _ = article.runtime.updateIf(at: 1) { _, tx in tx.resizeWindowInstant((80, 117)); return true }
        #expect(page.takeWindowHeight() == nil)
        #expect(!article.runtime.hasPendingWindowFrame)
    }

    @Test func resizeUpdatesSafeAreaInMemoizedContentAndMeasurement() throws {
        var captured: [Float] = []
        let app = AppSpec<Void>(title: "Shell", size: Vec2(200, 100), state: ()) { _, cx in
            let insets = cx.safeArea()
            return memo("inset", 0) {
                captured = insets
                return el().h(20 + insets[0] + insets[2])
            }
        }
        let host = WebAppHost(spec: app)
        let session = WebBrowserSession(host)
        let change = Data(#"{"kind":"resize","x":200,"y":100,"scale":1,"insets":[11,7,9,3]}"#.utf8)
        _ = try session.renderFrame(at: 0)
        #expect(captured == [0, 0, 0, 0])
        #expect(session.send(change, at: 1))
        _ = try session.renderFrame(at: 1)
        #expect(captured == [11, 7, 9, 3])
        #expect(!session.send(change, at: 2))
        #expect(host.runtime.contentHeight() == 40)
        #expect(session.takeWindowTitle() == "Shell")
        #expect(session.takeWindowTitle() == nil)
        _ = host.runtime.updateIf(at: 2) { _, tx in tx.setWindowTitle(""); return true }
        #expect(session.takeWindowTitle() == "")
        #expect(session.takeWindowTitle() == nil)
        #expect(host.runtime.setSafeAreaInsets(SIMD4(.nan, -.infinity, -4, 6)))
        _ = try session.renderFrame(at: 3)
        #expect(captured == [0, 0, 0, 6])
    }
}
