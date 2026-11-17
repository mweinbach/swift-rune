import Foundation
import Rune
#if os(Windows)
import WinSDK

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private final class WakeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func wake() { lock.withLock { count += 1 } }
}

@main
struct VideoConsumption {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw Failure("Pass the silent-video and video-with-audio fixture paths") }
        let original = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Rune-\(UUID().uuidString).mp4")
        try FileManager.default.copyItem(at: original, to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        MediaPlaybackGate.enable()
        let player = Player.file(file.path, playing: true, looping: true, muted: true, rate: 0.5)
        let wakes = WakeCount()
        func pull() {
            _ = player.surface.pullVideo(clock: ProcessInfo.processInfo.systemUptime, wake: { wakes.wake() })
        }
        func awaitTime(_ title: String, _ accepts: (Double) -> Bool) throws {
            let limit = Date().addingTimeInterval(8)
            repeat {
                pull()
                if player.surface.currentFrame() != nil && accepts(player.time) { return }
                if case .failed(let reason) = player.state { throw Failure(reason) }
                Thread.sleep(forTimeInterval: 0.01)
            } while Date() < limit
            throw Failure("\(title) timed out at \(player.time) in \(player.state)")
        }
        func exclusiveRead() -> Bool {
            let h = file.path.withCString(encodedAs: UTF16.self) {
                CreateFileW($0, DWORD(GENERIC_READ), 0, nil, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            }
            guard let h, h != INVALID_HANDLE_VALUE else { return false }
            CloseHandle(h)
            return true
        }

        Thread.sleep(forTimeInterval: 0.35)
        guard exclusiveRead(), player.surface.currentFrame() == nil else { throw Failure("Unseen clip opened a reader") }
        try awaitTime("first visible green sample", { $0 >= 0.25 && $0 < 0.5 })
        guard !exclusiveRead(), let visible = player.surface.currentFrame() else { throw Failure("Missing live reader") }
        let time = player.time
        let calls = wakes.value
        Thread.sleep(forTimeInterval: 1.1)
        guard player.surface.currentFrame()?.id == visible.id, player.time == time, wakes.value - calls <= 1 else {
            throw Failure("Hidden clip advanced to \(player.time) or woke \(wakes.value - calls) times")
        }
        pull()
        guard player.time == time && player.surface.currentFrame()?.id == visible.id else { throw Failure("Resume skipped the last drawn sample") }
        try awaitTime("resumed blue sample", { $0 >= 0.5 && $0 < 0.75 })
        guard let retained = player.surface.currentFrame() else { throw Failure("Missing held blue sample") }
        let parkedTime = player.time
        let timeout = Date().addingTimeInterval(6)
        while !exclusiveRead(), Date() < timeout { Thread.sleep(forTimeInterval: 0.025) }
        guard exclusiveRead(), player.surface.currentFrame()?.id == retained.id, player.time == parkedTime else {
            throw Failure("Unseen reader remained open or discarded its displayed frame")
        }
        // A seek after parking must reopen against the new request, even without another timed draw.
        player.pause()
        player.seek(to: 0.75)
        try awaitTime("explicit paused seek after parking", { $0 >= 0.75 && player.surface.currentFrame()?.id != retained.id })
        guard player.state == .ready else { throw Failure("Parked seek restarted playback") }
        player.setLooping(false)
        player.play()
        Thread.sleep(forTimeInterval: 0.9)
        guard player.state == .playing && player.time == 0.75 else { throw Failure("Hidden silent final frame advanced to EOS") }
        pull()
        guard player.state == .playing else { throw Failure("Last visible picture did not resume after an offscreen gap") }
        let endDeadline = Date().addingTimeInterval(4)
        while player.state != .ended && Date() < endDeadline {
            pull()
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard player.state == .ended else { throw Failure("Visible clip never delivered EOS") }
        let sounding = Player.file(CommandLine.arguments[2], playing: true, muted: false)
        let sndWakes = WakeCount()
        let sndDeadline = Date().addingTimeInterval(8)
        while sounding.surface.currentFrame() == nil && Date() < sndDeadline {
            _ = sounding.surface.pullVideo(clock: ProcessInfo.processInfo.systemUptime, wake: { sndWakes.wake() })
            Thread.sleep(forTimeInterval: 0.015)
        }
        guard sounding.hasSound == true, sounding.surface.currentFrame() != nil else {
            throw Failure("Silenced audio track fixture did not start: \(sounding.state)")
        }
        let sndBefore = sndWakes.value
        while sounding.state != .ended && Date() < sndDeadline { Thread.sleep(forTimeInterval: 0.025) }
        guard sounding.state == .ended && sndWakes.value - sndBefore <= 3 else {
            throw Failure("Audio clock while hidden: \(sounding.state), \(sndWakes.value - sndBefore) wakes")
        }
        print("PASS lazy open, one hidden wake, retained sample, resumed clock, released file handle, paused seek, hidden final picture, visible EOS, background audio EOS")
    }
}
#else
@main struct VideoConsumption { static func main() {} }
#endif
