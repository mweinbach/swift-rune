#if canImport(CRuneMedia)
import Foundation
import Testing
@testable import Rune

@Suite("Desktop video frame extraction")
struct DesktopVideoFrameTests {
    @Test("A rotated H.264 frame exposes upright dimensions and RGBA quadrants")
    func uprightQuadrants() throws {
        let player = VideoPlayer(source: .file(mediaFixtureURL("quadrants-rot90.mp4")))
        #expect(player.state == .ready)
        #expect(player.naturalSize.x == 32 && player.naturalSize.y == 64)
        let frame = try #require(player.frame(at: 0.125))
        try #require(frame.width == 32 && frame.height == 64)
        let samples = [(4, 8), (28, 8), (4, 56), (28, 56)]
        let colors = [[0, 255, 0], [255, 255, 255], [255, 0, 0], [0, 0, 255]]
        for ((x, y), expected) in zip(samples, colors) {
            let offset = (y * Int(frame.width) + x) * 4
            for channel in 0..<3 {
                #expect(abs(Int(frame.rgba[offset + channel]) - expected[channel]) <= 8)
            }
            #expect(frame.rgba[offset + 3] == 255)
        }
    }

    @Test("Muted live playback advances, pauses at a seek, delivers later frames and reaches EOS")
    func liveTransport() async throws {
        var request = MediaRequest(source: .file(mediaFixtureURL("rgbw.mp4")), playing: true, muted: true)
        let decoder = try DesktopMediaDecoder(source: DesktopMediaSource(request: request), kind: .video, headless: false)
        #expect(!decoder.meta.hasSound)
        let poster = try decoder.frame(at: nil)
        let red = try #require(poster)
        #expect(red.planes[0][2] > 240)
        try decoder.setTransport(request, seek: nil)
        let clock = ContinuousClock()
        let startupDeadline = clock.now + .seconds(5)
        var status = try decoder.status()
        while status.time < 0.05, clock.now < startupDeadline {
            try await Task.sleep(for: .milliseconds(10))
            status = try decoder.status()
        }
        #expect(status.time >= 0.05)

        request.playing = false
        try decoder.setTransport(request, seek: 0.375)
        let pausedFrame = try decoder.frame(at: nil)
        let green = try #require(pausedFrame)
        #expect(green.format == .bgra && green.planes[0][1] > 240 && green.planes[0][2] < 15)
        let paused = try decoder.status().time
        #expect(abs(paused - 0.375) < 0.04)
        try await Task.sleep(for: .milliseconds(75))
        let held = try decoder.status().time
        #expect(abs(held - paused) < 0.025)

        request.playing = true
        try decoder.setTransport(request, seek: 0.51)
        let endDeadline = clock.now + .seconds(5)
        var sawBlueOrWhite = false
        repeat {
            if let frame = try decoder.frame(at: nil) {
                sawBlueOrWhite = sawBlueOrWhite || (frame.planes[0][0] > 240 && frame.planes[0][3] == 255)
            }
            status = try decoder.status()
            if !status.ended { try await Task.sleep(for: .milliseconds(10)) }
        } while !status.ended && clock.now < endDeadline
        #expect(sawBlueOrWhite)
        #expect(status.ended)
        #expect(abs(status.time - 1) < 0.05)
    }
}
#endif
