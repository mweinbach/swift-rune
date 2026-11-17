#if os(Windows)
import CRuneWin32
import Foundation

/// The worker owns its context and renderer until its native completion is published.
/// A window may close before the worker finishes. Destroying that context frees its GL objects.
private final class WindowsGPUPreparation: @unchecked Sendable {
    private let lock = NSLock()
    private var renderer: PortableGLRenderer?
    private var diagnostic: String?

    func build() -> Int32 {
        do {
            let candidate = try PortableGLRenderer(resolve: rune_win_gl_proc, isGLES: false)
            try candidate.prepareFrameProgram()
            lock.withLock { renderer = candidate }
            return 1
        } catch {
            lock.withLock { diagnostic = String(describing: error) }
            return 0
        }
    }

    func takeRenderer() -> PortableGLRenderer? {
        lock.withLock {
            defer { renderer = nil }
            return renderer
        }
    }

    var errorMessage: String? { lock.withLock { diagnostic } }

    deinit { renderer?.abandon() }
}

// Both callbacks run on the native WGL thread, including the release after a rejected context.
private func prepareWindowsGPU(_ pointer: UnsafeMutableRawPointer?) -> Int32 {
    guard let pointer else { return 0 }
    return Unmanaged<WindowsGPUPreparation>.fromOpaque(pointer).takeUnretainedValue().build()
}

private func releaseWindowsGPU(_ pointer: UnsafeMutableRawPointer?) {
    if let pointer { Unmanaged<WindowsGPUPreparation>.fromOpaque(pointer).release() }
}

@MainActor
final class WindowsCPUWindow {
    private let painter = CpuPainter(threads: min(6, max(1, ProcessInfo.processInfo.activeProcessorCount)))
    private var target = CpuBootTarget(width: 0, height: 0)
    private var edges: [Int32] = []
    private let only: Bool
    private var job: WindowsGPUPreparation?
    private var attempts = 0
    private var retryAt: Double?
    private var requiresGPU = false
    private let wake: Win32Wake

    init(only: Bool, wake: Win32Wake, atlas: GlyphAtlas) {
        self.only = only
        self.wake = wake
        painter.attachMasks(to: atlas)
    }

    var idleStartOwed: Bool { !only && attempts == 0 }

    func startGPU(_ window: OpaquePointer, required: Bool = false) {
        if required { requiresGPU = true }
        if job != nil {
            if required { rune_win_gpu_raise(window) }
            return
        }
        guard (!only || requiresGPU) && attempts < 3 else { return }
        if let retryAt, ProcessInfo.processInfo.systemUptime < retryAt { return }
        retryAt = nil
        attempts += 1
        let build = WindowsGPUPreparation()
        job = build
        GpuEvents.starting()
        rune_win_gpu_start(window, requiresGPU ? 1 : 0, Unmanaged.passRetained(build).toOpaque(),
                           prepareWindowsGPU, releaseWindowsGPU)
    }

    func takeGPU(_ window: OpaquePointer) -> PortableGLRenderer? {
        if retryAt != nil { startGPU(window) }
        guard let job else { return nil }
        let state = rune_win_gpu_state(window)
        guard state != 0 else { return nil }
        guard state > 0, rune_win_make_current(window) != 0 else {
            failedGPU(window, reason: job.errorMessage ?? "Opening the Windows GPU context failed")
            return nil
        }
        let slot = rune_win_take_frame_slot(window)
        guard slot != 0 else { return nil }
        guard slot > 0, let renderer = job.takeRenderer() else {
            failedGPU(window, reason: "The Windows GPU presentation surface is unavailable")
            return nil
        }
        return renderer
    }

    func failedGPU(_ window: OpaquePointer, reason: String) {
        // Returning from an already-promoted window starts with one failed device.
        attempts = max(1, attempts)
        RuneStandardIO.error("Rune is keeping the Windows CPU renderer after GPU attempt \(attempts) of 3: \(reason)\n")
        job = nil
        rune_win_gpu_abandon(window)
        if attempts < 3 {
            retryAt = ProcessInfo.processInfo.systemUptime + 30
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [wake] in wake.post() }
        }
    }

    /// Only a complete CPU-painted scene replaces the pixels already on the window.
    func present<State>(_ frame: RenderFrame, runtime: Runtime<State>, to window: OpaquePointer) throws -> Bool {
        let resized = target.width != frame.width || target.height != frame.height
        if resized {
            guard frame.width > 0, frame.height > 0,
                  frame.width <= Int(Int32.max) / 4, frame.height <= Int(Int32.max) else {
                startGPU(window, required: true)
                return false
            }
            target = CpuBootTarget(width: frame.width, height: frame.height)
            painter.forget()
        }
        let scene = CpuBootScene(frame: frame, smoothing: runtime.fontSmoothing,
                                 atlasResets: Int(clamping: runtime.textSystem.glyphAtlas.resets))
        do {
            let painted = try painter.paint(scene, into: &target)
            edges.removeAll(keepingCapacity: true)
            for rect in painted.rects {
                for edge in rect { edges.append(Int32(clamping: edge)) }
            }
            let copied = target.pixels.withUnsafeBufferPointer { pixels in
                edges.withUnsafeBufferPointer { rects in
                    rune_win_cpu_present(window, pixels.baseAddress, Int32(frame.width), Int32(frame.height),
                                         Int32(target.stride), rects.baseAddress, Int32(painted.rects.count), resized ? 1 : 0)
                }
            }
            if copied == 0 {
                painter.forget()
                startGPU(window, required: true)
                return false
            }
            return true
        } catch is NeedsGpu {
            startGPU(window, required: true)
            return false
        }
    }
}
#endif
