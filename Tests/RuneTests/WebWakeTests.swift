import Testing
@testable import Rune

@Suite("Browser frame wakes")
struct WebWakeTests {
    @MainActor @Test("A poll hook sleeps between scheduled deadlines")
    func restingPoll() throws {
        let spec = AppSpec(size: Vec2(48, 24), state: 0, poll: { _, _, _ in false }) { _, _ in el().sizeFull() }
        let host = WebAppHost(spec: spec)
        let session = WebBrowserSession(host)
        _ = try session.renderFrame(at: 0)
        #expect(session.nextDelay(at: 0) == .infinity)
        host.runtime.wakeAt(0.25)
        #expect(session.nextDelay(at: 0.10) == 0.15)
        #expect(try session.renderFrame(at: 0.24) == nil)
        #expect(try session.renderFrame(at: 0.25) != nil)
        #expect(session.nextDelay(at: 0.25) == .infinity)
    }

    @MainActor @Test("AppHandle state updates reach GPU and reference frames in order")
    func handleUpdates() throws {
        let app = App(size: Vec2(48, 24), state: [Int]()) { _, _ in el().sizeFull() }
        let host = WebAppHost(app: app)
        let handle = app.handle()
        handle.update { state, _ in state.append(1) }
        _ = try host.renderGPUFrame(at: 0)
        handle.update { state, _ in state.append(2) }
        _ = try host.renderFrame(at: 0.1)
        #expect(host.runtime.state == [1, 2])
    }
}
