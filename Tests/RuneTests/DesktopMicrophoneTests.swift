#if canImport(CRuneMedia) && (os(Windows) || os(Linux))
import Foundation
import Testing
@testable import Rune

@Suite("Desktop recorder capture")
struct DesktopMicrophoneTests {
    private func beginGeneratedInput(_ url: URL) -> RecorderShared {
        let options = RecorderOptions(format: .wav, sampleRate: 16_000, channels: 2, fake: nil)
        let shared = RecorderShared(url: url, options: options)
        shared.unsafeControlMutate { ctl in
            let attempt = ctl.seq.next()
            let session = RecorderBackend.startCapture(shared: shared, attempt: attempt, url: url,
                                                        options: options, synthetic: true)
            ctl.phase = .opening(attempt: attempt, session: session)
        }
        return shared
    }

    private func waitFor(_ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    @Test("Native source meters and saves interleaved stereo PCM; cancelling a retake keeps the file")
    func captureAndCancel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("take.wav")
        let first = beginGeneratedInput(url)
        defer { first.cancel() }
        try #require(waitFor { first.status() == .recording && first.level().peakDB() > -50 })
        first.pause()
        #expect(first.status() == .paused)
        #expect(first.level() == .silent)
        first.resume()
        try #require(waitFor { first.level().peakDB() > -50 })
        let recording = try first.stop().get()
        #expect(recording.duration > 0)
        #expect(recording.url == url)
        let wav = try Data(contentsOf: url)
        #expect(Array(wav[22..<24]) == [2, 0])
        let (rate, samples) = try FakeMicrophone.parseWAV(wav).get()
        #expect(rate == 16_000)
        #expect(recording.duration == Double(samples.count) / Double(rate))
        #expect(samples.contains { abs($0) > 0.01 })

        let second = beginGeneratedInput(url)
        try #require(waitFor { second.status() == .recording && second.level().peakDB() > -50 })
        second.cancel()
        #expect(second.status() == .idle)
        #expect(try Data(contentsOf: url) == wav)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["take.wav"])
    }
}
#endif
