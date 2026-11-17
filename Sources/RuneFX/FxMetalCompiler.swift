#if canImport(Metal)
import Dispatch

/// Independent Metal pipeline descriptors can compile in parallel. Each job owns its
/// result until concurrentPerform joins. The renderer publishes the states afterwards.
enum FxMetalCompiler {
    private final class Job<Value>: @unchecked Sendable {
        let build: () throws -> Value
        private(set) var result: Result<Value, Error>?

        init(_ build: @escaping () throws -> Value) { self.build = build }
        func run() { result = Result(catching: build) }
    }

    static func compile<Input, Value>(
        _ inputs: [Input], using build: @escaping (Input) throws -> Value
    ) throws -> [Value] {
        guard inputs.count > 1 else { return try inputs.map(build) }
        let jobs = inputs.map { input in Job { try build(input) } }
        DispatchQueue.concurrentPerform(iterations: jobs.count) { jobs[$0].run() }
        return try jobs.map { try $0.result!.get() }
    }
}
#endif
