import Dispatch
import Foundation
import Rune
import WinSDK

private func log(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

private struct ViewState {
    var obscured = false
    var flash = false
}

private final class Frames: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var origin: SIMD2<Float>?
    private var observations = 0
    private var failure: String?

    var drawn: Int { lock.withLock { count } }
    func didDraw(_ rect: [Float]?) {
        lock.withLock {
            count += 1
            if count == 1 { log("first window frame") }
            if let rect, rect.count >= 2 { origin = SIMD2(rect[0], rect[1]) }
        }
    }
    var videoOrigin: SIMD2<Float>? { lock.withLock { origin } }
    func observed() { lock.withLock { observations += 1 } }
    var observedCount: Int { lock.withLock { observations } }
    func fail(_ reason: String) { lock.withLock { failure = reason } }
    var reason: String? { lock.withLock { failure } }
}

@main struct PlayerProbe {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static let title = "Rune independent video"

    /// Wait for a nonwhite picture and check that only the control covers its center.
    private static func showsControl(_ expected: Bool, _ frames: Frames) -> Bool {
        guard let window = title.withCString(encodedAs: UTF16.self, { FindWindowW(nil, $0) }),
              let origin = frames.videoOrigin else { return false }
        let scale = Float(GetDpiForWindow(window)) / 96
        func pixel(_ x: Float, _ y: Float, _ dc: HDC) -> DWORD {
            var p = POINT(x: LONG(((origin.x + x) * scale).rounded()), y: LONG(((origin.y + y) * scale).rounded()))
            guard ClientToScreen(window, &p) else { return 0xffff_ffff }
            return GetPixel(dc, p.x, p.y)
        }
        func white(_ c: DWORD) -> Bool { (c & 0x00f8_f8f8) == 0x00f8_f8f8 }
        let end = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            guard let dc = GetDC(nil) else { return false }
            let inside = pixel(20, 22, dc), outside = pixel(38, 22, dc)
            ReleaseDC(nil, dc)
            if inside < 0x0100_0000 && outside < 0x0100_0000,
               (inside & 0x00f8_f8f8) != 0, (outside & 0x00f8_f8f8) != 0,
               !white(outside), white(inside) == expected { return true }
            Thread.sleep(forTimeInterval: 0.03)
        } while ProcessInfo.processInfo.systemUptime < end
        return false
    }

    private static func check(_ player: Player, _ app: AppHandle<ViewState>, _ frames: Frames) {
        defer { app.quit() }
        func sample(_ duration: TimeInterval) -> (draws: Int, pictures: UInt64) {
            let draws = frames.drawn
            let first = player.surface.currentFrame()?.id ?? 0
            Thread.sleep(forTimeInterval: duration)
            return (frames.drawn - draws, (player.surface.currentFrame()?.id ?? 0) &- first)
        }

        func waitForLayer(_ phase: String) -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            repeat {
                let result = sample(0.75)
                if result.pictures >= 2 && result.draws <= Int(result.pictures / 6) {
                    log("\(phase): \(result.pictures) pictures, \(result.draws) UI draws")
                    return true
                }
                log("\(phase) waiting: \(result.pictures) pictures, \(result.draws) UI draws, state \(player.state)")
            } while ProcessInfo.processInfo.systemUptime < deadline
            return false
        }

        guard waitForLayer("first promotion") else {
            frames.fail("The independent Windows layer never presented while the UI rested (player \(player.state), draws \(frames.drawn)).")
            return
        }
        guard showsControl(false, frames), player.surface.counts().0 > 0 else {
            frames.fail("The first picture was not drawn in the window before promotion.")
            return
        }
        let submits = player.surface.counts().0
        for _ in 0 ..< 6 {
            let before = frames.drawn
            app.update { state, _ in state.flash.toggle() }
            let end = ProcessInfo.processInfo.systemUptime + 2
            while frames.drawn == before && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.01) }
            guard frames.drawn > before else { frames.fail("Unrelated UI content never repainted."); return }
        }
        guard player.surface.counts().0 == submits else {
            frames.fail("Unrelated UI draws sent the decoder's committed visual through GL again.")
            return
        }
        log("six unrelated UI draws, zero duplicate video submissions")
        app.update { state, _ in state.obscured = true }
        Thread.sleep(forTimeInterval: 0.3)
        let covered = sample(1.25)
        log("opaque control over video: \(covered.pictures) pictures, \(covered.draws) UI draws")
        guard covered.draws >= 2 && covered.pictures >= 2 && showsControl(true, frames) else {
            frames.fail("The UI did not take back pictures for the overlaid control.")
            return
        }
        app.update { state, _ in state.obscured = false }
        guard waitForLayer("second promotion"), showsControl(false, frames) else {
            frames.fail("Removing the overlaid control did not restore independent presentation.")
            return
        }
        let beforeObserver = player.surface.counts().0
        player.surface.setObserver { _ in frames.observed() }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while (frames.observedCount == 0 || player.surface.counts().0 == beforeObserver) && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        player.surface.setObserver(nil)
        guard frames.observedCount > 0, player.surface.counts().0 > beforeObserver, waitForLayer("promotion after observer removed") else {
            frames.fail("A timing observer did not receive the UI's video submissions and then release the layer.")
            return
        }
        player.pause()
        Thread.sleep(forTimeInterval: 0.4)
        let paused = sample(0.55)
        guard !player.isPlaying && paused.pictures == 0 else {
            frames.fail("The paused player continued publishing pictures.")
            return
        }
        log("PASS App + Player, handback, re-promotion and pause")
    }

    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure(description: "Pass a local color video file with at least 4 frames per second.") }
        log("opening player")
        let player = Player.file(CommandLine.arguments[1], playing: true, looping: true, muted: true)
        let frames = Frames()
        let spec = App<ViewState>(title: title, size: Vec2(256, 144),
                                  minSize: Vec2(128, 72), state: ViewState()) { state, _ in
            let picture = el().key("picture").video(player, .stretch).w(128).h(72) as El<ViewState>
            var stage = el().pin(top: 0, left: 0).w(128).h(72).child(picture)
            if state.obscured {
                stage = stage.child(el().pin(top: 16, left: 10).w(24).h(16).bg(.white))
            }
            return col().sizeFull().bg(.black).child(stage)
                .child(el().pin(top: 4, left: 148).w(8).h(8).bg(state.flash ? .white : .black))
        }.onFrameDrawn { runtime in frames.didDraw(runtime.element(byKey: "picture")?.rect) }
        let handle = spec.handle()
        log("opening window")
        try spec.onReady { _ in
            log("window ready")
            DispatchQueue.global(qos: .utility).async { check(player, handle, frames) }
        }.run(arguments: [])
        if let reason = frames.reason {
            FileHandle.standardError.write(Data("FAIL \(reason)\n".utf8))
            ExitProcess(1)
        }
    }
}
