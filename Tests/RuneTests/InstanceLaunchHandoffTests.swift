import Foundation
import Testing
@testable import Rune

@Suite struct InstanceLaunchHandoffTests {
    private final class Probe: @unchecked Sendable {
        var time: TimeInterval = 0
        var quitting = false
        var started: [[String]] = []
        var delivered: [[String]] = []

        func make() -> InstanceLaunches {
            InstanceLaunches(now: { self.time }, quitting: { self.quitting }, restart: { self.started.append($0) })
        }

        func accept(_ arguments: [String]) -> Bool {
            delivered.append(arguments)
            return true
        }
    }

    @Test func servedLaunchIsNotRestartedWhenItsWindowCloses() {
        let probe = Probe()
        let handoff = probe.make()
        let urls = ["sample://one", "--ordinary", "sample://two"]
        handoff.receive(urls, deliver: probe.accept)
        #expect(handoff.launchesWaiting)
        handoff.served()
        #expect(!handoff.launchesWaiting)
        handoff.ended()
        #expect(handoff.loopExited)
        #expect(probe.started.isEmpty)
        #expect(probe.delivered == [urls])
    }

    @Test func exitRestartsOnlyRecentUnservedLaunchesKeepingTheirOriginalArguments() {
        let probe = Probe()
        let handoff = probe.make()
        handoff.receive(["sample://expired"], deliver: probe.accept)
        probe.time = 4
        handoff.receive(["--reopen"], deliver: probe.accept)
        probe.time = 5
        handoff.receive(["sample://new", "--path", "two words"], deliver: probe.accept)
        handoff.ended()
        handoff.ended()
        handoff.receive(["sample://after-exit"], deliver: probe.accept)
        #expect(probe.delivered.count == 3)
        #expect(probe.started == [["--reopen"], ["sample://new", "--path", "two words"], ["sample://after-exit"]])
    }

    @Test func quittingAndUnreachableLoopHandOffWithoutDuplicateDelivery() {
        let probe = Probe()
        let handoff = probe.make()
        handoff.receive([], deliver: { _ in false })
        #expect(handoff.loopExited)
        #expect(probe.started == [[]])
        handoff.started()
        probe.quitting = true
        handoff.receive(["sample://while-quitting"], deliver: probe.accept)
        #expect(probe.delivered.isEmpty)
        #expect(!handoff.launchesWaiting)
        #expect(probe.started == [[], ["sample://while-quitting"]])
    }
}
