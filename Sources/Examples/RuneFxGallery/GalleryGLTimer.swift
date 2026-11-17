#if canImport(CRuneGL) && (os(macOS) || os(Linux) || os(Windows))
import Rune

/// Elapsed GPU time on desktop GL and on GLES drivers offering disjoint timer queries.
final class GalleryGLTimer {
    private typealias Gen = @convention(c) (Int32, UnsafeMutablePointer<UInt32>) -> Void
    private typealias Delete = @convention(c) (Int32, UnsafePointer<UInt32>) -> Void
    private typealias Begin = @convention(c) (UInt32, UInt32) -> Void
    private typealias End = @convention(c) (UInt32) -> Void
    private typealias Result = @convention(c) (UInt32, UInt32, UnsafeMutablePointer<UInt64>) -> Void
    private typealias Integer = @convention(c) (UInt32, UnsafeMutablePointer<Int32>) -> Void
    private typealias IndexedString = @convention(c) (UInt32, UInt32) -> UnsafePointer<UInt8>?
    private typealias CounterBits = @convention(c) (UInt32, UInt32, UnsafeMutablePointer<Int32>) -> Void

    private let target: UInt32 = 0x88BF // GL_TIME_ELAPSED
    private var name: UInt32 = 0
    private let begin: Begin
    private let end: End
    private let read: Result
    private let delete: Delete
    private let getInteger: Integer

    private static func procedure<T>(_ name: String, _ type: T.Type) -> T? {
        guard let ptr = OffscreenGLContext.resolve(name) else { return nil }
        return unsafeBitCast(ptr, to: type)
    }

    init?() {
        guard let getInteger = Self.procedure("glGetIntegerv", Integer.self) else { return nil }
        let es = OffscreenGLContext.isGLES
        if es {
            guard let getString = Self.procedure("glGetStringi", IndexedString.self) else { return nil }
            var count: Int32 = 0
            getInteger(0x821D, &count) // GL_NUM_EXTENSIONS
            let available = (0..<max(0, count)).contains { index in
                getString(0x1F03, UInt32(index)).map { String(cString: $0) == "GL_EXT_disjoint_timer_query" } ?? false
            }
            guard available else { return nil }
        }
        let ext = es ? "EXT" : ""
        guard let gen = Self.procedure("glGenQueries" + ext, Gen.self),
              let delete = Self.procedure("glDeleteQueries" + ext, Delete.self),
              let begin = Self.procedure("glBeginQuery" + ext, Begin.self),
              let end = Self.procedure("glEndQuery" + ext, End.self),
              let read = Self.procedure("glGetQueryObjectui64v" + ext, Result.self),
              let caps = Self.procedure("glGetQueryiv" + ext, CounterBits.self) else { return nil }
        var bits: Int32 = 0
        caps(target, 0x8864, &bits) // GL_QUERY_COUNTER_BITS
        guard bits > 0 else { return nil }
        self.getInteger = getInteger
        self.delete = delete
        self.begin = begin
        self.end = end
        self.read = read
        gen(1, &name)
        guard name != 0 else { return nil }
    }

    /// A driver clock reset makes that interval unusable.
    func milliseconds(_ draw: () throws -> Void) throws -> Double? {
        begin(target, name)
        do { try draw() }
        catch { end(target); throw error }
        end(target)
        var nanoseconds: UInt64 = 0
        read(name, 0x8866, &nanoseconds) // GL_QUERY_RESULT
        if OffscreenGLContext.isGLES {
            var disjoint: Int32 = 0
            getInteger(0x8FBB, &disjoint) // GL_GPU_DISJOINT_EXT
            if disjoint != 0 { return nil }
        }
        return nanoseconds == 0 ? nil : Double(nanoseconds) / 1e6
    }

    deinit {
        if name != 0 { delete(1, &name) }
    }
}
#endif
