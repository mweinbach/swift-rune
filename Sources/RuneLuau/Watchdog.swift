import Foundation

/// Per-VM execution watchdog enforcing wall-clock and optional instruction budgets.
public final class LuauWatchdog: @unchecked Sendable {
    private var deadline: ContinuousClock.Instant?
    private var instructionLimit: Int?
    private var instructionsExecuted: Int = 0
    private var ticks: UInt32 = 0

    public init() {}

    public struct Armed {
        fileprivate let armedOuter: Bool
        fileprivate weak var watchdog: LuauWatchdog?

        public func disarm() {
            if armedOuter {
                watchdog?.deadline = nil
                watchdog?.instructionLimit = nil
            }
        }
    }

    /// Arms the watchdog for one VM entry unless an outer entry already armed it.
    public func arm(timeLimit: Duration, instructionLimit: Int? = nil) -> Armed {
        let wasArmed = deadline != nil || self.instructionLimit != nil
        if !wasArmed {
            deadline = ContinuousClock.now + timeLimit
            self.instructionLimit = instructionLimit
            instructionsExecuted = 0
            ticks = 0
        }
        return Armed(armedOuter: !wasArmed, watchdog: self)
    }

    /// Checks the budget at a VM safepoint (every 256 instructions for clock, every instruction for count).
    @inline(__always)
    internal func tick() throws {
        if let limit = instructionLimit {
            instructionsExecuted += 1
            if instructionsExecuted > limit {
                throw LuauRuntimeError(value: .string(watchdogMessage), isTimeout: true)
            }
        }
        ticks &+= 1
        if (ticks & 255) == 0, let deadline {
            if ContinuousClock.now >= deadline {
                throw LuauRuntimeError(value: .string(watchdogMessage), isTimeout: true)
            }
        }
    }
}
