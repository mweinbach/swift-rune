import CPUProbeDriver
import Foundation
import Rune

private func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private final class GPUEventsSeen: @unchecked Sendable {
    private let lock = NSLock()
    private let began = ProcessInfo.processInfo.systemUptime
    private var starts: [Double] = []
    private var draws = 0

    func record(_ event: GpuEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .starting: starts.append(ProcessInfo.processInfo.systemUptime)
        case .drew: draws += 1
        }
        log("GPU ms=\(Int((ProcessInfo.processInfo.systemUptime - began) * 1000)) event=\(event) attempts=\(starts.count) draws=\(draws)")
    }

    var counts: (attempts: Int, draws: Int, lastAttempt: Double?) {
        lock.lock()
        defer { lock.unlock() }
        return (starts.count, draws, starts.last)
    }
}

private enum Mode: String { case handoff, failure, only, direct }

private let colors: [Color] = [.rgba8(255, 0, 0), .rgba8(0, 255, 0), .rgba8(0, 0, 255)]
private let rgb: [Int32] = [0xff0000, 0x00ff00, 0x0000ff]

private func hex(_ value: Int32) -> String {
    value < 0 ? "unavailable" : String(format: "%06X", value)
}

private func matchingSource(_ pixels: CPUProbePixels, expected: Int32, gpu: Bool) -> String? {
    let choices: [(String, Int32)] = gpu
        ? [("WGL GL_FRONT", pixels.front), ("visible child DC", pixels.child_dc), ("HWND client DC", pixels.dc),
           ("HWND PrintWindow after swap", pixels.print)]
        : [("HWND client DC", pixels.dc), ("retained DIB via WM_PRINTCLIENT", pixels.print_client),
           ("HWND PrintWindow", pixels.print)]
    return choices.first(where: { $0.1 == expected })?.0
}

@MainActor
private func exercise(_ mode: Mode) throws {
    cpu_probe_child_entered()
    log("CHILD enter mode=\(mode.rawValue) pid=\(ProcessInfo.processInfo.processIdentifier)")
    let gpu = GPUEventsSeen()
    let token = onGpu { gpu.record($0) }
    defer { GpuEvents.removeListener(token) }
    var window: WindowHandle?
    var ready = 0, closes = 0, frames = 0, nextClick = 0
    var mismatchSince: Double?
    var lastFrame: (gpu: Bool, state: Int)?
    var firstCPU = false, updatedCPU = false, firstGPU = false
    var finalFrame = false, closing = false
    let started = ProcessInfo.processInfo.systemUptime

    func closeWhenReady() {
        if !closing && ready == 1 && finalFrame {
            closing = true
            window?.close()
        }
    }
    let app = App<Int>("Rune CPU-first public fixture", size: Vec2(128, 96), init: { 0 }, view: { state, _ in
        el().wFull().hFull().motion(.none).bg(colors[state]).hit().onClick { state, tx in
            state += 1
            tx.settle()
        }
    })
    .openInactive(true)
    .onWindow { handle in
        precondition(cpu_probe_attach() != 0, "could not subclass this process's ordinary Rune window")
        window = handle
        log("CALLBACK window")
    }
    .onReady { handle in
        ready += 1
        log("READY frames=\(frames) isReady=\(handle.isReady) paint=\(cpu_probe_in_paint())")
        precondition(ready == 1 && handle.isReady && frames >= 1 && cpu_probe_in_paint() == 0)
        closeWhenReady()
    }
    .onClose { _, _ in closes += 1; return true }
    .onFrameDrawn { runtime in
        frames += 1
        let now = ProcessInfo.processInfo.systemUptime
        let status = gpu.counts
        let isGPU = status.draws > 0
        let value = runtime.state
        precondition(cpu_probe_in_paint() != 0 && rgb.indices.contains(value))
        if lastFrame?.gpu != isGPU || lastFrame?.state != value {
            log("CALLBACK before sample frame=\(frames) state=\(value) gpu=\(isGPU)")
            let pixels = cpu_probe_sample()
            let source = matchingSource(pixels, expected: rgb[value], gpu: isGPU)
            log("FRAME seq=\(frames) ms=\(Int((now-started)*1000)) state=\(value) gpu=\(isGPU) " +
                "glLoaded=\(cpu_probe_gl_loaded()) wgl=\(cpu_probe_has_current_wgl()) childVisible=\(pixels.gpu_child_visible) " +
                "dc=\(hex(pixels.dc)) print=\(hex(pixels.print)) retained=\(hex(pixels.print_client)) " +
                "child=\(hex(pixels.child_dc)) front=\(hex(pixels.front)) back=\(hex(pixels.back)) source=\(source ?? "unverified")")
            if source == nil {
                // A report can observe the new runtime state before its queued view commit.
                // The very first GPU frame of a handoff must already equal the last CPU paint.
                precondition(!(mode == .handoff && isGPU && !firstGPU),
                             "First handoff RGB differs from the CPU frame")
                let firstMismatch = mismatchSince ?? now
                mismatchSince = firstMismatch
                precondition(now - firstMismatch < 3, "No presented-source RGB equals \(hex(rgb[value]))")
                precondition(cpu_probe_arm_timer(16) != 0)
                return
            }
            mismatchSince = nil
            if lastFrame == nil {
                precondition(value == 0 && isGPU == (mode == .direct))
                if !isGPU { precondition(cpu_probe_has_current_wgl() == 0) }
                firstCPU = !isGPU
            }
            if isGPU && !firstGPU {
                precondition(mode == .direct || (mode == .handoff && updatedCPU && value == 1),
                             "First GPU presentation must preserve the most recent CPU click")
                precondition(cpu_probe_has_current_wgl() != 0)
                firstGPU = true
            }
            if !isGPU && value == 1 { updatedCPU = true }
            lastFrame = (isGPU, value)
        }
        if nextClick == 0 {
            nextClick = 1
            log("POST click=1")
            precondition(cpu_probe_click() != 0)
        } else if value == 1 && nextClick == 1 {
            let mayClick: Bool
            switch mode {
            case .direct, .handoff: mayClick = isGPU
            case .only: mayClick = ready == 1 && now - started >= 1.5
            case .failure: mayClick = status.attempts == 3 && now - (status.lastAttempt ?? now) >= 31
            }
            if mayClick {
                nextClick = 2
                log("POST click=2")
                precondition(cpu_probe_click() != 0)
            } else {
                precondition(cpu_probe_arm_timer(mode == .failure ? 1000 : 250) != 0)
            }
        } else if value == 2 {
            finalFrame = true
            closeWhenReady()
        }
    }
    try app.run(arguments: [])
    let status = gpu.counts
    precondition(firstCPU == (mode != .direct) && updatedCPU == (mode != .direct))
    precondition(firstGPU == (mode == .direct || mode == .handoff))
    precondition(status.attempts == (mode == .failure ? 3 : mode == .only ? 0 : 1))
    precondition(status.draws == (firstGPU ? 1 : 0) && finalFrame && ready == 1 && closes == 1)
    log("PASS \(mode.rawValue) nativeFrames=\(frames) clicks=\(nextClick) ready=\(ready) close=\(closes) " +
        "attempts=\(status.attempts) firstGPU=\(firstGPU) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime-started)*1000))")
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.count == 2, arguments[0] == "--child", let mode = Mode(rawValue: arguments[1]) {
    try exercise(mode)
} else if arguments.count == 1, let mode = Mode(rawValue: arguments[0]) {
    let status = (Array(mode.rawValue.utf16) + [0]).withUnsafeBufferPointer { cpu_probe_launch($0.baseAddress) }
    exit(status)
} else {
    fatalError("Expected one of handoff, failure, only, direct")
}
