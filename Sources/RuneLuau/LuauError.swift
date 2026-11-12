import Foundation

/// What went wrong when compiling or running a Luau script.
public enum ErrorKind: String, Sendable, Equatable, Hashable {
    /// The source doesn't parse. A reload with a syntax error keeps the running VM.
    case syntax
    /// The script raised an error, or called something with the wrong arguments.
    case runtime
    /// One entry into the VM ran past the watchdog limit (250 ms by default).
    case timeout
    /// The VM reached its memory limit.
    case memory
    /// The script has no entry module, or the entry module has no such function.
    case missing
}

/// A script error, with the Luau traceback when there is one.
public struct ScriptError: Error, Sendable, Equatable, CustomStringConvertible {
    public var kind: ErrorKind
    public var message: String

    public init(kind: ErrorKind, message: String) {
        self.kind = kind
        self.message = message
    }

    /// The first line of the message: `init.luau:12: attempt to index nil`.
    public var summary: String {
        if let idx = message.firstIndex(of: "\n") {
            return String(message[..<idx])
        }
        return message
    }

    public var description: String {
        message
    }
}

/// Sentinel message raised by the watchdog when an entry exceeds its budget.
internal let watchdogMessage = "script ran longer than its time limit (watchdog)"

/// Internal VM error carrying an arbitrary `LuauValue` (for `pcall` / `xpcall` / `error(val)`).
internal struct LuauRuntimeError: Error, LocalizedError {
    let value: LuauValue
    let traceback: String
    let isTimeout: Bool

    var errorDescription: String? {
        let msg = value.displayString
        return traceback.isEmpty ? msg : "\(msg)\n\(traceback)"
    }

    init(value: LuauValue, traceback: String = "", isTimeout: Bool = false) {
        self.value = value
        self.traceback = traceback
        self.isTimeout = isTimeout
    }

    func toScriptError() -> ScriptError {
        let msg = value.displayString
        let full = traceback.isEmpty ? msg : "\(msg)\n\(traceback)"
        if isTimeout || msg.contains(watchdogMessage) {
            return ScriptError(kind: .timeout, message: full)
        }
        return ScriptError(kind: .runtime, message: full)
    }
}
