#if canImport(Darwin)
import Darwin
import os
#elseif os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Synchronization
#elseif os(Windows)
import WinSDK
import Synchronization
#endif

// MARK: - Stack Segment Continuation for Deep Recursive Container Layout (#1120)

/// Minimum remaining stack bytes before continuing container layout on a fresh stack segment
/// (matching upstream `rune_taffy::stack::STACK_RED_ZONE` = 128 KiB).
internal let stackRedZoneBytes: Int = 128 * 1024

/// Virtual stack size requested when continuing deep container layout onto a fresh worker thread
/// stack (2 MiB demand-paged on macOS/iOS/Linux and reserved on Windows).
internal let stackSegmentBytes: Int = 2 * 1024 * 1024

/// Maximum inline container recursion depth per stack segment before continuing onto a fresh
/// worker stack. Ordinary UI trees stay well below this threshold and pay zero thread hops.
internal let maxInlineContainerDepth: Int = 64

#if canImport(Darwin)
private let stackGrowCounter = OSAllocatedUnfairLock<UInt64>(initialState: 0)
#elseif os(Linux) || os(Windows)
private let stackGrowCounter = Atomic<UInt64>(0)
#endif

/// Total number of stack segment continuations allocated by `RuneTaffy` in this process,
/// exposed for launch/frame diagnostics and depth probes (matching `rune_taffy::stack_grow_count`).
public func stackGrowCount() -> UInt64 {
    #if canImport(Darwin)
    stackGrowCounter.withLock { $0 }
    #elseif os(Linux) || os(Windows)
    stackGrowCounter.load(ordering: .relaxed)
    #else
    0
    #endif
}

@inline(__always)
private func incrementStackGrowCount() {
    #if canImport(Darwin)
    stackGrowCounter.withLock { $0 &+= 1 }
    #elseif os(Linux) || os(Windows)
    stackGrowCounter.wrappingAdd(1, ordering: .relaxed)
    #endif
}

#if canImport(Darwin) || os(Linux) || os(Windows)

@inline(never)
private func currentStackAddress() -> UInt {
    var marker: UInt8 = 0
    return withUnsafePointer(to: &marker) { UInt(bitPattern: $0) }
}

/// Estimates remaining usable stack bytes on the current thread, or `nil` if stack bounds
/// cannot be determined.
internal func remainingStackBytes() -> Int? {
    let sp = currentStackAddress()
    #if canImport(Darwin)
    let selfThread = pthread_self()
    let stackTop = UInt(bitPattern: pthread_get_stackaddr_np(selfThread))
    let stackSize = UInt(pthread_get_stacksize_np(selfThread))
    guard stackSize > 0, stackTop >= stackSize else { return nil }
    let stackBottom = stackTop &- stackSize
    guard sp > stackBottom, sp <= stackTop else { return nil }
    return Int(clamping: sp &- stackBottom)
    #elseif os(Linux)
    var attr = pthread_attr_t()
    guard pthread_getattr_np(pthread_self(), &attr) == 0 else { return nil }
    defer { _ = pthread_attr_destroy(&attr) }
    var stackAddr: UnsafeMutableRawPointer?
    var stackSize: Int = 0
    guard pthread_attr_getstack(&attr, &stackAddr, &stackSize) == 0,
          let addr = stackAddr,
          stackSize > 0
    else { return nil }
    let stackBottom = UInt(bitPattern: addr)
    let stackTop = stackBottom &+ UInt(stackSize)
    guard stackTop > stackBottom, sp > stackBottom, sp <= stackTop else { return nil }
    return Int(clamping: sp &- stackBottom)
    #elseif os(Windows)
    var low: ULONG_PTR = 0
    var high: ULONG_PTR = 0
    GetCurrentThreadStackLimits(&low, &high)
    let stackBottom = UInt(low)
    let stackTop = UInt(high)
    guard stackTop > stackBottom, sp > stackBottom, sp <= stackTop else { return nil }
    return Int(clamping: sp &- stackBottom)
    #else
    return nil
    #endif
}

private struct StackThunkBox {
    var run: () -> Void
}

#if canImport(Darwin)
private func posixStackTrampoline(_ raw: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    raw.assumingMemoryBound(to: StackThunkBox.self).pointee.run()
    return nil
}
#elseif os(Linux)
private func posixStackTrampoline(_ raw: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    raw?.assumingMemoryBound(to: StackThunkBox.self).pointee.run()
    return nil
}
#elseif os(Windows)
private func win32StackTrampoline(_ raw: LPVOID?) -> DWORD {
    raw?.assumingMemoryBound(to: StackThunkBox.self).pointee.run()
    return 0
}
#endif

/// Runs `body` synchronously on a fresh OS thread with a `stackSegmentBytes` stack, blocking
/// the caller until completion (`pthread_join` / `WaitForSingleObject`) so exclusive borrows
/// remain race-free without requiring `@Sendable`. Returns `nil` if thread creation fails.
private func runOnFreshStackSegment<R>(_ body: () -> R) -> R? {
    var result: R?
    let completed = withoutActuallyEscaping(body) { escapingBody -> Bool in
        var box = StackThunkBox {
            result = escapingBody()
        }
        return withUnsafeMutablePointer(to: &box) { boxPtr -> Bool in
            #if canImport(Darwin)
            var attr = pthread_attr_t()
            guard pthread_attr_init(&attr) == 0 else { return false }
            defer { _ = pthread_attr_destroy(&attr) }
            guard pthread_attr_setstacksize(&attr, stackSegmentBytes) == 0 else { return false }
            var thread: pthread_t?
            guard pthread_create(&thread, &attr, posixStackTrampoline, boxPtr) == 0,
                  let created = thread
            else { return false }
            incrementStackGrowCount()
            _ = pthread_join(created, nil)
            return true
            #elseif os(Linux)
            var attr = pthread_attr_t()
            guard pthread_attr_init(&attr) == 0 else { return false }
            defer { _ = pthread_attr_destroy(&attr) }
            guard pthread_attr_setstacksize(&attr, stackSegmentBytes) == 0 else { return false }
            #if canImport(Musl)
            var thread: pthread_t?
            guard pthread_create(&thread, &attr, posixStackTrampoline, boxPtr) == 0,
                  let created = thread
            else { return false }
            incrementStackGrowCount()
            _ = pthread_join(created, nil)
            return true
            #else
            var thread = pthread_t()
            guard pthread_create(&thread, &attr, posixStackTrampoline, boxPtr) == 0 else { return false }
            incrementStackGrowCount()
            _ = pthread_join(thread, nil)
            return true
            #endif
            #elseif os(Windows)
            // STACK_SIZE_PARAM_IS_A_RESERVATION = 0x0001_0000; INFINITE = 0xFFFF_FFFF.
            guard let handle = CreateThread(
                nil,
                SIZE_T(stackSegmentBytes),
                win32StackTrampoline,
                boxPtr,
                DWORD(0x0001_0000),
                nil
            ) else { return false }
            incrementStackGrowCount()
            _ = WaitForSingleObject(handle, DWORD(0xFFFF_FFFF))
            _ = CloseHandle(handle)
            return true
            #else
            return false
            #endif
        }
    }
    return completed ? result : nil
}

@inline(__always)
private func shouldGrowContainerStack(depth: Int) -> Bool {
    if depth >= maxInlineContainerDepth {
        return true
    }
    #if os(Linux)
    // `pthread_getattr_np` can inspect `/proc/self/maps` on the main thread; sample every
    // 8 levels (~32 KiB max stride, well inside the 128 KiB red zone) to keep shallow layouts free.
    if (depth & 7) == 0, let rem = remainingStackBytes(), rem < stackRedZoneBytes {
        return true
    }
    #else
    if let rem = remainingStackBytes(), rem < stackRedZoneBytes {
        return true
    }
    #endif
    return false
}

#else

internal func remainingStackBytes() -> Int? { nil }

#endif

/// Runs `body` on the current stack when sufficient stack headroom and depth remain, or
/// continues onto a fresh worker thread stack segment on Darwin, Linux, and Windows.
///
/// The boolean parameter tells `body` whether execution moved onto a fresh stack segment
/// (so callers can reset their per-segment recursion depth counter).
///
/// Non-desktop / single-threaded platforms (such as WASI) execute `body(false)` directly.
@inline(__always)
internal func maybeGrowContainerStack<R>(depth: Int, _ body: (_ grew: Bool) -> R) -> R {
    #if canImport(Darwin) || os(Linux) || os(Windows)
    if shouldGrowContainerStack(depth: depth), let output = runOnFreshStackSegment({ body(true) }) {
        return output
    }
    #endif
    return body(false)
}
