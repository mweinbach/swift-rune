import Testing
@testable import Rune

/// Upstream captures warnings and deduplicates sites per test thread. Swift Testing runs
/// multiple tests in the same process and can move a test between threads.
struct PerfWarningScope: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing body: @Sendable () async throws -> Void) async throws {
        try await PerfWarn.$testLog.withValue(PerfWarn.WarningLog()) { try await body() }
    }
}
