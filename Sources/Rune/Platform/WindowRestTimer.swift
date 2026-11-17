import Foundation

/// Frames move the rest deadline forward without replacing an already scheduled wake.
/// An earlier wake (for example under memory pressure) still takes precedence.
struct WindowRestTimer {
    enum Update: Equatable { case keep, cancel, arm(TimeInterval) }
    private var machine = WindowRestMachine()
    private var armed: TimeInterval?

    mutating func step(_ event: WindowRestMachine.Event) -> (WindowRestMachine.Effect?, Update) {
        if case .woke = event { armed = nil }
        let effect = machine.step(event).first
        if let due = machine.deadline {
            if let armed, armed <= due { return (effect, .keep) }
            armed = due
            return (effect, .arm(due))
        }
        guard armed != nil else { return (effect, .keep) }
        armed = nil
        return (effect, .cancel)
    }
}

#if canImport(AppKit) || canImport(UIKit)
@MainActor
final class AppleWindowRest {
    private var state = WindowRestTimer()
    private var timer: Timer?
    private let giveBack: (Bool) -> Void

    init(giveBack: @escaping (Bool) -> Void) { self.giveBack = giveBack }

    func step(_ event: WindowRestMachine.Event) {
        let (effect, update) = state.step(event)
        switch update {
        case .keep: break
        case .cancel: cancel()
        case .arm(let due):
            timer?.invalidate()
            let delay = max(0, due - ProcessInfo.processInfo.systemUptime)
            let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.step(.woke(now: ProcessInfo.processInfo.systemUptime))
                }
            }
            timer = next
            RunLoop.main.add(next, forMode: .common)
        }
        if let effect { giveBack(effect == .giveBackAll) }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        state = WindowRestTimer()
    }
}
#endif
