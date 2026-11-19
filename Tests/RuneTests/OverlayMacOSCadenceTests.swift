#if os(macOS)
import AppKit
import Metal
import Testing
@testable import Rune

@Suite(.serialized)
struct OverlayMacOSCadenceTests {
    /// Runs `CFRunLoopRunInMode` from a `CFRunLoopTimer` on the main run loop so:
    /// 1. Neither Swift's `MainActor` nor `DispatchQueue.main` is occupied during the wait,
    ///    allowing `Task { @MainActor }` and display-link/timer callbacks to execute normally.
    /// 2. Any `CFRunLoopStop(CFRunLoopGetMain())` posted by HIToolbox's `SignalMainThread()`
    ///    only exits this nested `CFRunLoopRunInMode` call instead of terminating Swift 6.4's
    ///    top-level `CFMainExecutor` run loop.
    private func runNestedMainLoop(
        timeoutMilliseconds: Int,
        stopWhen: (@MainActor @Sendable () -> Bool)? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), 0, 0, 0) { _ in
                let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
                var matched = false
                while true {
                    if let stopWhen, MainActor.assumeIsolated(stopWhen) {
                        matched = true
                        break
                    }
                    if ContinuousClock.now >= deadline {
                        break
                    }
                    _ = CFRunLoopRunInMode(.defaultMode, 0.005, false)
                    MainActor.assumeIsolated {
                        if NSApp != nil {
                            while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
                        }
                    }
                }
                if !matched, let stopWhen {
                    matched = MainActor.assumeIsolated(stopWhen)
                }
                MainActor.assumeIsolated {
                    if NSApp != nil {
                        while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
                    }
                }
                continuation.resume(returning: matched)
            }
            CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func pumpRunLoop(milliseconds: Int) async {
        _ = await runNestedMainLoop(timeoutMilliseconds: milliseconds, stopWhen: nil)
    }

    private func drainPendingAppKitEvents() async {
        _ = await runNestedMainLoop(timeoutMilliseconds: 20, stopWhen: nil)
    }

    private func wait(until predicate: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        // Other AppKit tests can occupy the main actor for several seconds. Give
        // the pending run-loop callback a chance after that work returns.
        await runNestedMainLoop(timeoutMilliseconds: 3_000, stopWhen: predicate)
    }

    @Test func pollAwaitsDeadlineWithoutCreatingAHiddenPanel() async throws {
        let overlay = await MainActor.run {
            let options = OverlayOptions(input: .none)
            return OverlaySpec<ContinuousClock.Instant?>(
                name: "Hidden timer", size: Vec2(16, 16), options: options, makeState: { nil },
                view: { _, _ in el() }
            ).configured(options).poll { firedAt, _, _ in firedAt = .now; return false }.makeHandle()
        }
        let earliestPoll = ContinuousClock.now + .milliseconds(50)
        await MainActor.run {
            _ = overlay.updateIf { _, tx in tx.wakeAfter(0.05); return false }
        }
        try #require(await wait { overlay.readState { $0 != nil } })
        let fired = await MainActor.run { overlay.readState { $0 } }
        #expect(try #require(fired) >= earliestPoll)
        await MainActor.run {
            overlay.update { $0 = nil }
            overlay.runtime.waker.wake()
        }
        #expect(await wait { overlay.readState { $0 != nil } })
        let (windowNumber, frameCount) = await MainActor.run { (overlay.windowNumber, overlay.surfaceStats.frameCount) }
        #expect(windowNumber == nil)
        #expect(frameCount == 0)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func retainedPanelKeepsItsPixelsPastANonzeroReleaseDelay() async throws {
        let (overlay, number, hidden) = try await MainActor.run {
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
            return (overlay, number, hidden)
        }
        await pumpRunLoop(milliseconds: 200)
        let (afterNumber, afterFrames) = await MainActor.run { (overlay.windowNumber, overlay.surfaceStats.frameCount) }
        #expect(afterNumber == number)
        #expect(afterFrames == hidden)
        await drainPendingAppKitEvents()
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func retriesMissedFirstVisibleSubmission() async throws {
        final class RetryBox: @unchecked Sendable {
            var attempts = 0
            var countAtRetry: UInt64?
            var view: RuneOverlayMetalView<Void>?
        }
        let box = RetryBox()
        let (overlay, beforeReveal) = try await MainActor.run {
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
            view.onPresentFrame = { [weak overlay] frame, drawable, renderer, time, update, synced in
                box.attempts += 1
                if box.attempts == 2 { box.countAtRetry = overlay?.surfaceStats.frameCount }
                return box.attempts > 1 && present(frame, drawable, renderer, time, update, synced)
            }
            box.view = view
            overlay.show()
            return (overlay, beforeReveal)
        }
        let submitted = await wait { (box.view?.submittedFrames ?? 0) > beforeReveal }
        await MainActor.run {
            overlay.hide()
            box.view = nil
        }
        await drainPendingAppKitEvents()
        #expect(submitted)
        #expect(box.attempts > 1)
        #expect(box.countAtRetry == beforeReveal)
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
        let alpha = Live<Float>(1)
        let overlay = await MainActor.run {
            _ = NSApplication.shared
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
            return overlay
        }

        // A hit region needs pointer monitoring even on a completely stationary overlay.
        await pumpRunLoop(milliseconds: 120)
        let idle = await MainActor.run { overlay.surfaceStats.frameCount }
        #expect(idle > 0)
        await pumpRunLoop(milliseconds: 100)
        #expect(await MainActor.run { overlay.surfaceStats.frameCount } == idle)

        await MainActor.run { overlay.update { $0.revision = 1 } }
        #expect(await wait { overlay.surfaceStats.frameCount > idle })
        let (showedUpdate, changed) = await MainActor.run {
            (overlay.runtime.elements().contains { $0.key == "box-1" }, overlay.surfaceStats.frameCount)
        }
        #expect(showedUpdate)

        await MainActor.run { _ = alpha.snap(0.4) }
        #expect(await wait { overlay.surfaceStats.frameCount > changed })

        // The poll observes a deadline without changing the view. It must not acquire
        // another drawable for a frame already on screen.
        await MainActor.run { overlay.update { $0.due = -1 } }
        #expect(await wait { overlay.wakeDeadline != nil })
        let beforeTimer = await MainActor.run { overlay.surfaceStats.frameCount }
        #expect(await wait { overlay.readState(\.timerFired) })
        #expect(await MainActor.run { overlay.surfaceStats.frameCount } == beforeTimer)

        await MainActor.run { overlay.update { $0.due = -1; $0.timerFired = false; $0.commitOnTimer = true } }
        #expect(await wait { overlay.wakeDeadline != nil })
        let beforeCommit = await MainActor.run { overlay.surfaceStats.frameCount }
        #expect(await wait { overlay.readState(\.timerFired) })
        await pumpRunLoop(milliseconds: 80)
        #expect(await MainActor.run { overlay.surfaceStats.frameCount } == beforeCommit)

        await MainActor.run { overlay.update { $0.due = -1; $0.timerFired = false; $0.recolor = true } }
        #expect(await wait { overlay.wakeDeadline != nil })
        let beforeRecolor = await MainActor.run { overlay.surfaceStats.frameCount }
        #expect(await wait { overlay.surfaceStats.frameCount > beforeRecolor && overlay.readState(\.timerFired) })

        await MainActor.run { overlay.update { $0.due = -1; $0.timerFired = false } }
        #expect(await wait { overlay.wakeDeadline != nil })
        let hidden = await MainActor.run {
            overlay.hide()
            let hidden = overlay.surfaceStats.frameCount
            alpha.snap(0.8)
            overlay.update { $0.revision = 2 }
            return hidden
        }
        #expect(await wait { overlay.readState(\.timerFired) })
        #expect(await MainActor.run { overlay.surfaceStats.frameCount } == hidden)
        let showedHiddenUpdate = await MainActor.run {
            overlay.show()
            let showed = overlay.runtime.elements().contains { $0.key == "box-2" }
            overlay.hide()
            return showed
        }
        await drainPendingAppKitEvents()
        #expect(showedHiddenUpdate)
    }
}
#endif
