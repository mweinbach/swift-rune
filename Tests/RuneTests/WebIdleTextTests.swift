import Foundation
import Testing
@testable import Rune

@MainActor
@Suite("Browser idle text")
struct WebIdleTextTests {
    private struct State {}

    @Test func inputDrawsBeforeThePreparedViewIsMeasured() throws {
        let host = WebAppHost(spec: AppSpec(title: "Idle", size: Vec2(100, 50), state: State()) { _, _ in
            text("Current view")
        })
        let browser = WebBrowserSession(host)
        var tx = Tx()
        tx.prepareText { (_: State, _: inout Cx<State>) in text("Prepared view") }
        #expect(!browser.idleText(perform: true))
        #expect(host.runtime.textIdleOwed)
        let firstFrame = try browser.renderFrame(at: 0)
        _ = try #require(firstFrame)
        #expect(browser.idleText(perform: false))

        _ = browser.send(Data(#"{"kind":"pointermove","x":12,"y":8}"#.utf8), at: 0.01)
        #expect(!browser.idleText(perform: true))
        #expect(host.runtime.textIdleOwed)
        let inputFrame = try browser.renderFrame(at: 0.02)
        _ = try #require(inputFrame)
        let commits = host.runtime.viewCommitCount
        #expect(!browser.idleText(perform: true))
        #expect(!host.runtime.textIdleOwed)
        #expect(host.runtime.textSystem.layoutKeys().contains { $0.authText == "Prepared view" })
        #expect(host.runtime.viewCommitCount == commits)
        let afterIdle = try browser.renderFrame(at: 0.03)
        #expect(afterIdle == nil)
    }
}
