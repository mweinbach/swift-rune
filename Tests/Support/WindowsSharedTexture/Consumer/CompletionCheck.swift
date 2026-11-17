#if os(Windows)
import Dispatch
import Foundation
import Rune
import RuneMotion

private struct CompletionFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class Observations: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var values: [UInt64] = []
    private var timedOut = false

    func receive(_ timing: FrameTiming) {
        guard timing.completedAt != nil else { return }
        if timing.frameId == 1 {
            started.signal()
            if resume.wait(timeout: .now() + 5) != .success { lock.withLock { timedOut = true } }
        }
        lock.withLock { values.append(timing.frameId) }
    }

    func verify() throws {
        try lock.withLock {
            guard !timedOut, values == [1, 2] else {
                throw CompletionFailure("WGL stalled the render thread or lost an ordered completion: \(values), timeout \(timedOut)")
            }
        }
    }
}

func validateWGLCompletions() throws {
    let surface = NativeSurface()
    let ui = Runtime(state: false, viewport: Vec2(2, 2), pixelScale: 1) { _, _ in
        nativeSurface(surface, .stretch).size(2, 2)
    }
    let observations = Observations()
    surface.setObserver { observations.receive($0) }
    let bytes = try ByteFrame(width: 1, height: 1, format: .rgba, color: .srgb, planes: [Data([0, 255, 0, 255])])
    var renderer: OffscreenGPURenderer? = try OffscreenGPURenderer()
    for id in 1...2 {
        try surface.pushBytes(bytes, frameId: UInt64(id))
        let frame = try renderer!.frame(ui, at: 0)
        guard frame.surfaces.count == 1 else { throw CompletionFailure("Runtime skipped the observed surface") }
        _ = try renderer!.renderOffscreen(frame)
        if id == 1, observations.started.wait(timeout: .now() + 5) != .success {
            throw CompletionFailure("WGL completion callback did not start. Submission/completion counts \(surface.counts()), error \(surface.lastError ?? "none")")
        }
    }
    // The second frame was submitted while the first completion callback was held.
    observations.resume.signal()
    renderer = nil
    try observations.verify()
    guard surface.counts() == (2, 2) else { throw CompletionFailure("Renderer teardown did not drain the GPU queue") }
}
#endif

#if os(Windows)
import CRuneWin32

private final class FenceTicket {
    let complete: (Int32) -> Void
    let released: DispatchSemaphore

    init(released: DispatchSemaphore, complete: @escaping (Int32) -> Void) {
        self.released = released
        self.complete = complete
    }

    deinit { released.signal() }
}

// The first callback requests context-loss cleanup while a second flushed fence is enqueued.
// Both callback contexts must be released, including the canceled one.
func validateWGLAbandonment() throws {
    let context = try OffscreenGLContext()
    defer { context.close() }
    guard let worker = rune_win_gl_completion_create(),
          let fenceProc = rune_win_gl_proc("glFenceSync"), let flushProc = rune_win_gl_proc("glFlush") else {
        throw CompletionFailure("WGL could not create a sharing completion context")
    }
    let fence = unsafeBitCast(fenceProc, to: (@convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?).self)
    let flush = unsafeBitCast(flushProc, to: (@convention(c) () -> Void).self)
    guard let finishProc = rune_win_gl_proc("glFinish") else { throw CompletionFailure("glFinish unavailable") }
    let finish = unsafeBitCast(finishProc, to: (@convention(c) () -> Void).self)
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0), good = DispatchSemaphore(value: 0)

    func enqueue(_ body: @escaping (Int32) -> Void) throws {
        guard let sync = fence(0x9117, 0) else { throw CompletionFailure("glFenceSync failed") }
        flush()
        let ticket = Unmanaged.passRetained(FenceTicket(released: released, complete: body))
        let queued = rune_win_gl_completion_submit(worker, sync, ticket.toOpaque()) { opaque, result in
            Unmanaged<FenceTicket>.fromOpaque(opaque!).takeRetainedValue().complete(result)
        }
        if queued == 0 { ticket.release(); throw CompletionFailure("Failed to queue native completion") }
    }

    try enqueue { completed in
        entered.signal()
        let mayClose = resume.wait(timeout: .now() + 5) == .success
        rune_win_gl_completion_destroy(worker, 1)
        if mayClose && completed == 1 { good.signal() }
    }
    // This standalone test uses a hidden HWND without running a window message loop.
    finish()
    rune_win_gl_completion_poll_current()
    guard entered.wait(timeout: .now() + 5) == .success else { throw CompletionFailure("First fence did not complete") }
    try enqueue { completed in if completed == 0 { good.signal() } }
    resume.signal()
    for _ in 0..<2 {
        guard released.wait(timeout: .now() + 5) == .success,
              good.wait(timeout: .now() + 5) == .success else {
            throw CompletionFailure("Context abandonment reported a false completion or retained a callback")
        }
    }
}
#endif
