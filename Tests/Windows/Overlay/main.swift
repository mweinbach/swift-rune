import Foundation
import Rune

// Run with the private-desktop Windows probe. Its worker sends a click to the
// overlay's interactive child and checks hit testing in the surrounding canvas.
FileHandle.standardError.write(Data("overlay fixture entered\n".utf8))
let app = App<Bool>("Rune overlay test owner", size: Vec2(64, 48), init: { false }, view: { _, _ in el() })
    .openInactive(true).windowless(true).keepRunning(true)
let owner = app.handle()
final class ProbeCompositor: Compositor {
    var frames = 0
    var prewarmed = false
    var presented = false
    func render(frame: CompositorFrame<Int>) {
        frames += 1
        frame.drawUI()
        guard let target = frame.openGL, let get = target.resolve("glGetIntegerv"),
              let bind = target.resolve("glBindFramebuffer"), let read = target.resolve("glReadPixels") else { return }
        typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Int32>) -> Void
        typealias Bind = @convention(c) (UInt32, UInt32) -> Void
        typealias Read = @convention(c) (Int32, Int32, Int32, Int32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Void
        var previous: Int32 = 0
        unsafeBitCast(get, to: Get.self)(0x8CAA, &previous) // GL_READ_FRAMEBUFFER_BINDING
        let set = unsafeBitCast(bind, to: Bind.self)
        set(0x8CA8, target.framebuffer) // GL_READ_FRAMEBUFFER
        defer { set(0x8CA8, UInt32(bitPattern: previous)) }
        func pixel(_ x: Int) -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: 4)
            let px = Int32(target.pixelSize.width * x / 96)
            let py = Int32(target.pixelSize.height * 3 / 4)
            rgba.withUnsafeMutableBytes { unsafeBitCast(read, to: Read.self)(px, py, 1, 1, 0x1908, 0x1401, $0.baseAddress) }
            return rgba
        }
        let ink = pixel(12), clear = pixel(75)
        let matches = ink.allSatisfy { $0 >= 250 } && clear.allSatisfy { $0 <= 1 }
        if frames <= 3 { print("overlay draw \(frames) framebuffer=\(target.framebuffer) ink=\(ink) clear=\(clear)") }
        if target.framebuffer != 0 { prewarmed = prewarmed || matches }
        else { presented = presented || matches }
    }
}
let compositor = ProbeCompositor()
let spec = OverlaySpec<Int>(name: "Rune overlay test", size: Vec2(96, 48),
    options: OverlayOptions(placement: .rect(MotionRect(left: 12, top: 12, right: 108, bottom: 60)), input: .regions, prewarm: true),
    makeState: { 0 }, view: { _, _ in
        el().wFull().hFull().child(el().absolute(x: 4, y: 4).size(32, 32).bg(.white).hit().onClick { $0 += 1 })
    })
var result: OverlayHandle<Int>?
try app.overlay(ConfiguredOverlay(spec: spec).compositor(compositor)) { overlay in
    FileHandle.standardError.write(Data("App delivered overlay handle\n".utf8))
    result = overlay
    overlay.fadeIn(0.05)
    Thread.detachNewThread {
        let end = ProcessInfo.processInfo.systemUptime + 40
        while overlay.readState({ $0 }) == 0 && ProcessInfo.processInfo.systemUptime < end {
            Thread.sleep(forTimeInterval: 0.025)
        }
        guard overlay.capabilities.globalPointer == .supported else { fatalError("Win32 motion hook did not start") }
        print("PASS Windows overlay motion hook installed")
        overlay.fadeOut(0.075)
        Thread.sleep(forTimeInterval: 0.25)
        owner.quit()
    }
}.run(arguments: [])
guard let result, result.readState({ $0 }) == 1, result.surfaceStats.frameCount > 0, compositor.prewarmed, compositor.presented,
      result.availability == .available, result.failure == nil, !result.overlayPresence.isDrawing else {
    fatalError("overlay click, presentation or fade failed: frames=\(result?.surfaceStats.frameCount ?? 0), clicks=\(result?.readState({ $0 }) ?? -1), failure=\(result?.failure ?? "none")")
}
print("PASS Swift App.overlay receiver, GPU frames=\(result.surfaceStats.frameCount), compositor draws=\(compositor.frames), click, fade and teardown")
