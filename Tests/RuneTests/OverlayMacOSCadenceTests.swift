#if os(macOS)
import AppKit
import Metal
import Testing
@testable import Rune

@MainActor
@Suite(.serialized)
struct OverlayMacOSCadenceTests {
    private func wait(until predicate: () -> Bool, timeout: Double = 3) async throws -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !predicate(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    @Test func pollAwaitsDeadlineWithoutCreatingAHiddenPanel() async throws {
        let options = OverlayOptions(input: .none)
        let overlay = OverlaySpec<Bool>(
            name: "Hidden timer", size: Vec2(16, 16), options: options, makeState: { false },
            view: { _, _ in el() }
        ).configured(options).poll { fired, _, _ in fired = true; return false }.makeHandle()
        _ = overlay.updateIf { _, tx in tx.wakeAfter(0.05); return false }
        #expect(try await wait { overlay.readState { $0 } })
        overlay.update { $0 = false }
        overlay.runtime.waker.wake()
        #expect(try await wait { overlay.readState { $0 } })
        #expect(overlay.windowNumber == nil)
        #expect(overlay.surfaceStats.frameCount == 0)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func retainedPanelKeepsItsPixelsPastANonzeroReleaseDelay() async throws {
        _ = NSApplication.shared
        let options = OverlayOptions(input: .none)
        let overlay = OverlaySpec<Void>(
            name: "Deferred GPU release", size: Vec2(16, 16), options: options, makeState: { () },
            view: { _, _ in el() }
        ).configured(options).releaseGpuAfter(0.1).makeHandle()
        overlay.show()
        let number = try #require(overlay.windowNumber)
        overlay.hide()
        let hidden = overlay.surfaceStats.frameCount
        try await Task.sleep(for: .milliseconds(200))
        #expect(overlay.windowNumber == number)
        #expect(overlay.surfaceStats.frameCount == hidden)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func retriesMissedFirstVisibleSubmission() async throws {
        _ = NSApplication.shared
        let options = OverlayOptions(input: .none, prewarm: true)
        let overlay = OverlaySpec<Void>(
            name: "Overlay retry", size: Vec2(24, 24), options: options, makeState: { () },
            view: { _, _ in el().size(24, 24).bg(.white) }
        ).configured(options).makeHandle()
        let number = try #require(overlay.windowNumber)
        let panel = try #require(NSApplication.shared.window(withWindowNumber: Int(number)))
        let view = try #require(panel.contentView?.subviews.compactMap { $0 as? RuneOverlayMetalView<Void> }.first)
        let present = try #require(view.onPresentFrame)
        let beforeReveal = overlay.surfaceStats.frameCount
        var attempts = 0
        var countAtRetry: UInt64?
        view.onPresentFrame = { [weak overlay] frame, drawable, renderer, time, update, synced in
            attempts += 1
            if attempts == 2 { countAtRetry = overlay?.surfaceStats.frameCount }
            return attempts > 1 && present(frame, drawable, renderer, time, update, synced)
        }
        overlay.show()
        defer { overlay.hide() }
        #expect(try await wait { view.submittedFrames > beforeReveal })
        #expect(attempts > 1)
        #expect(countAtRetry == beforeReveal)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func shownPanelSleepsUntilInputPublicationOrTimer() async throws {
        struct State {
            var revision = 0
            var due: Double?
            var timerFired = false
            var commitOnTimer = false
            var recolor = false
        }
        _ = NSApplication.shared
        let alpha = Live<Float>(1)
        let options = OverlayOptions(input: .regions)
        let spec = OverlaySpec<State>(
            name: "Overlay pacing", size: Vec2(32, 32), options: options, makeState: { State() }
        ) { state, _ in
            el().key("box-\(state.revision)").size(32, 32).bg(state.recolor && state.timerFired ? .black : .white)
                .hit().liveOpacity(alpha.binding)
        }.configured(options).poll { state, now, tx in
            if let due = state.due {
                if due < 0 {
                    state.due = now + 0.25
                    tx.wakeAfter(0.25)
                } else if due <= now {
                    state.timerFired = true
                    state.due = nil
                    return state.commitOnTimer
                } else {
                    tx.wakeAfter(due - now)
                }
            }
            return false
        }
        let overlay = spec.makeHandle()
        overlay.show()
        defer { overlay.hide() }

        // A hit region needs pointer monitoring even on a completely stationary overlay.
        try await Task.sleep(for: .milliseconds(120))
        let idle = overlay.surfaceStats.frameCount
        #expect(idle > 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(overlay.surfaceStats.frameCount == idle)

        overlay.update { $0.revision = 1 }
        #expect(try await wait { overlay.surfaceStats.frameCount > idle })
        let showedUpdate = overlay.runtime.elements().contains { $0.key == "box-1" }
        #expect(showedUpdate)
        let changed = overlay.surfaceStats.frameCount

        alpha.snap(0.4)
        #expect(try await wait { overlay.surfaceStats.frameCount > changed })

        // The poll observes a deadline without changing the view. It must not acquire
        // another drawable for a frame already on screen.
        overlay.update { $0.due = -1 }
        #expect(try await wait { overlay.wakeDeadline != nil })
        let beforeTimer = overlay.surfaceStats.frameCount
        #expect(try await wait { overlay.readState(\.timerFired) })
        #expect(overlay.surfaceStats.frameCount == beforeTimer)

        overlay.update { $0.due = -1; $0.timerFired = false; $0.commitOnTimer = true }
        #expect(try await wait { overlay.wakeDeadline != nil })
        let beforeCommit = overlay.surfaceStats.frameCount
        #expect(try await wait { overlay.readState(\.timerFired) })
        try await Task.sleep(for: .milliseconds(80))
        #expect(overlay.surfaceStats.frameCount == beforeCommit)

        overlay.update { $0.due = -1; $0.timerFired = false; $0.recolor = true }
        #expect(try await wait { overlay.wakeDeadline != nil })
        let beforeRecolor = overlay.surfaceStats.frameCount
        #expect(try await wait { overlay.surfaceStats.frameCount > beforeRecolor && overlay.readState(\.timerFired) })

        overlay.update { $0.due = -1; $0.timerFired = false }
        #expect(try await wait { overlay.wakeDeadline != nil })
        overlay.hide()
        let hidden = overlay.surfaceStats.frameCount
        alpha.snap(0.8)
        overlay.update { $0.revision = 2 }
        #expect(try await wait { overlay.readState(\.timerFired) })
        #expect(overlay.surfaceStats.frameCount == hidden)
        overlay.show()
        let showedHiddenUpdate = overlay.runtime.elements().contains { $0.key == "box-2" }
        #expect(showedHiddenUpdate)
    }
}
#endif
