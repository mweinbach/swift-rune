#if canImport(CRuneMedia)
import Foundation
import Testing
@testable import Rune

@Suite("Desktop video frame extraction")
struct DesktopVideoFrameTests {
    @Test("Opening a file as video requires a video track")
    func audioFileHasNoVideoTrack() throws {
        let request = MediaRequest(source: .file(mediaFixtureURL("silence.wav")))
        let source = try DesktopMediaSource(request: request)
        do {
            _ = try DesktopMediaDecoder(source: source, kind: .video, headless: true)
            Issue.record("A video player accepted an audio-only WAV file")
        } catch {
            #expect(String(describing: error).contains("no playable video track"))
        }
    }

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
        let poster = try firstPixel(decoder)
        let red = try #require(poster)
        #expect(red.x > 0.9 && red.y < 0.08)
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
        let pausedFrame = try firstPixel(decoder)
        let green = try #require(pausedFrame)
        #expect(green.y > 0.9 && green.x < 0.08)
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
            if let pixel = try firstPixel(decoder) {
                sawBlueOrWhite = sawBlueOrWhite || (pixel.z > 0.9 && pixel.w == 1)
            }
            status = try decoder.status()
            if !status.ended { try await Task.sleep(for: .milliseconds(10)) }
        } while !status.ended && clock.now < endDeadline
        #expect(sawBlueOrWhite)
        #expect(status.ended)
        #expect(abs(status.time - 1) < 0.05)
    }
    #if os(Windows)
    @Test("Windows video schedules variable-rate sample timestamps at the current playback rate")
    func variableRatePictureDeadline() throws {
        var request = MediaRequest(source: .file(mediaFixtureURL("rgbw-variable-rate.mp4")), muted: true)
        let decoder = try DesktopMediaDecoder(source: DesktopMediaSource(request: request), kind: .video, headless: false)
        // The four samples start at 0, 60, 400 and 590 ms.
        for (seek, shown, nextPTS, rate) in [(0.10, 0.06, 0.40, 0.5), (0.42, 0.40, 0.59, 2.0)] {
            request.playing = false
            request.rate = Float(rate)
            try decoder.setTransport(request, seek: seek)
            let frame = try decoder.frame(at: nil)
            _ = try #require(frame)
            #expect(abs(try #require(decoder.lastPictureTime) - shown) < 0.001)
            request.playing = true
            try decoder.setTransport(request, seek: nil)
            let before = try decoder.status().time
            let delay = decoder.nextVideoDelay()
            let after = try decoder.status().time
            // DWM can shift a wake by one refresh, and reading a heavily loaded
            // desktop can consume time between the before and after clock reads.
            #expect(delay >= max(0, (nextPTS - after) / rate - 0.04))
            #expect(delay <= max(0, (nextPTS - before) / rate) + 0.04)
        }
    }

    @Test("Windows headless H.264 selects the nearest sample, retains both planes and seeks backward")
    func nearestNV12Still() throws {
        let request = MediaRequest(source: .file(mediaFixtureURL("rgbw.mp4")))
        let decoder = try DesktopMediaDecoder(source: DesktopMediaSource(request: request), kind: .video, headless: true)
        func luma(_ time: Double) throws -> Int {
            guard case .bytes(let frame)? = try decoder.frame(at: time) else {
                Issue.record("The headless decoder did not return a CPU picture")
                return -1
            }
            #expect(frame.format == .nv12Video)
            #expect(frame.color == .bt709)
            #expect(frame.planes.count == 2)
            return Int(frame.planes[0][0])
        }
        #expect(abs(try luma(0.14) - 173) <= 3)
        let unchanged = try decoder.frame(at: 0.16, retaining: decoder.lastPictureTime)
        #expect(unchanged == nil)
        #expect(abs(try luma(0.40) - 32) <= 3)
        #expect(abs(try luma(0) - 63) <= 3)
        #expect(abs(try luma(1) - 235) <= 3)
    }
    #endif

    private func firstPixel(_ decoder: DesktopMediaDecoder) throws -> SIMD4<Float>? {
        guard let image = try decoder.frame(at: nil) else { return nil }
        let surface = NativeSurface()
        _ = try image.publish(to: surface, orient: decoder.orient, id: 1)
        let frame = try #require(surface.currentFrame())
        let sampler = try SurfacePlaneSampler(frame: frame, srgbBlend: true)
        return sampler.sample(bufferPixel: .zero, displaySize: SIMD2(Float(frame.size.0), Float(frame.size.1)), exact: true)
    }
}
#endif
