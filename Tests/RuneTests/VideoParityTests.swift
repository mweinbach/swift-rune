import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("Video Parity Tests")
struct VideoParityTests {
    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    @Test("missing file, .ogv, and unsupported .ogg/.webm fail cleanly without resurrection")
    func unsupportedAndMissingFilesFailCleanly() {
        let missing = Player.file("/nonexistent/path/not-a-file.mp4")
        #expect(missing.state.isFailed)
        missing.play()
        #expect(missing.state.isFailed)
        missing.seek(to: 0.5)
        #expect(missing.state.isFailed)

        let ogv = Player.file("/tmp/sample.ogv")
        if case .failed(let msg) = ogv.snapshot().state {
            #expect(msg.contains(".ogv"))
        } else {
            Issue.record("expected .ogv to fail cleanly")
        }

        let oggVorbis = Player(source: .file(Self.fixtureURL("sine-vorbis.ogg")))
        #expect(oggVorbis.snapshot().state.isFailed)

        let oggOpus = Player(source: .file(Self.fixtureURL("sine-opus.ogg")))
        #expect(oggOpus.snapshot().state.isFailed)

        let webmOpus = Player(source: .file(Self.fixtureURL("sine-opus.webm")))
        #expect(webmOpus.snapshot().state.isFailed)
    }

    @Test("audio fixtures silence.m4a and silence.wav probe as audio and respect duration")
    func audioFixturesProbeAndPlay() {
        for name in ["silence.m4a", "silence.wav"] {
            let p = Player(source: .file(Self.fixtureURL(name)))
            let snap = p.snapshot()
            #expect(snap.kind == .audio)
            #expect(snap.state == .ready)
            #expect(snap.size == nil)
            #expect((snap.duration ?? 0) > 0.05)
        }
    }

    @Test("video fixture rgbw.mp4 decodes pixels and advances across virtual clock")
    func rgbwFixtureProbesAndPlaysInHeadlessRuntime() throws {
        struct S {}
        let p = Player(source: .file(Self.fixtureURL("rgbw.mp4")), playing: true, looping: false)
        #expect(p.meta.kind == .video)
        #expect(p.size != nil)
        #expect((p.duration ?? 0) > 0.1)

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(160, 120),
            pixelScale: 1.0,
            view: { _, _ in video(p, .fit).size(160, 120) }
        )

        _ = rt.frame(at: 0.0)
        #expect(p.surface.currentFrame() != nil)

        _ = rt.frame(at: 0.1)
        #expect(p.time > 0.05)

        // Tree JSON includes "video" snapshot metadata
        let data = try rt.treeJSONData(pretty: false, realTime: 0.1)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let els = obj?["elements"] as? [[String: Any]]
        let videoObj = els?.first?["video"] as? [String: Any]
        #expect(videoObj?["kind"] as? String == "video")
        #expect(videoObj?["state"] as? String != nil)
    }

    @Test("quadrants-rot90.mp4 detects 90-degree preferredTransform orientation and swaps upright size")
    func rotatedVideoOrientationAndGPU() throws {
        let p = Player(source: .file(Self.fixtureURL("quadrants-rot90.mp4")))
        #expect(p.meta.kind == .video)
        #expect(p.orient.swaps == true)
        let upright = p.size
        let frame = p.surface.currentFrame()
        #expect(frame != nil)
        if let f = frame, let up = upright {
            #expect(f.orient.swaps == true)
            #expect(f.orient.upright(width: f.size.0, height: f.size.1) == up)
        }

        #if canImport(Metal)
        let renderer = try MetalRenderer()
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(64, 64),
            pixelScale: 1.0,
            view: { _, _ in video(p, .fit).size(64, 64) }
        )
        let scene = rt.frame(at: 0)
        let out = try renderer.renderOffscreen(scene, surfaces: rt.surfaces)
        #expect(out.width == 64 && out.height == 64)
        // Center pixel should be non-transparent (rendered rotated frame)
        let mid = (32 * 64 + 32) * 4
        #expect(out.rgba[mid + 3] == 255)
        #endif
    }

    @Test("failed video element pushes black placeholder when rendered in Runtime")
    func failedVideoPushesPlaceholder() {
        struct S {}
        let p = Player.file("/tmp/missing-placeholder-video.ogv")
        #expect(p.state.isFailed)
        #expect(p.surface.currentFrame() == nil)

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(80, 60),
            pixelScale: 1.0,
            view: { _, _ in video(p, .fit).size(80, 60) }
        )
        _ = rt.frame(at: 0)
        let ph = p.surface.currentFrame()
        #expect(ph?.id == 0)
        #expect(ph?.size.0 == 2 && ph?.size.1 == 2)
    }

    @Test("VideoPhases state machine handles seek settle expiration, looping, and poster overtaking")
    func videoPhasesStateMachine() {
        var m = VideoPhases.Machine(isAudio: false, playing: false, looping: true, rate: 1.0)

        // Initial idle pull requests poster
        let step0 = m.step(item: nil, onMain: true, at: 0.0)
        #expect(step0.active == false)
        #expect(step0.effects.contains(where: { if case .requestPoster = $0 { return true }; return false }))

        let posterSeq = m.posterSequence.current
        #expect(m.posterOvertaken(seq: posterSeq) == false)

        // Starting play overtakes older poster
        _ = m.apply(.play, at: 0.1)
        #expect(m.posterOvertaken(seq: posterSeq) == true)

        // Seek creates pending settle with deadline; expires after SEEK_PATIENCE (2.0s)
        _ = m.apply(.seek(1.5), at: 0.2)
        #expect(m.settle.isWaiting == true)
        m.settle.expire(now: 1.0)
        #expect(m.settle.isWaiting == true)
        m.settle.expire(now: 2.3)
        #expect(m.settle.isWaiting == false)

        // Observing end with looping restarts to t=0
        let item = VideoPhases.Item(
            generation: m.generation,
            status: .ready(duration: 2.0),
            currentTime: 2.0,
            playerRate: 1.0,
            frameTime: 2.0
        )
        let loopStep = m.step(item: item, onMain: true, at: 3.0)
        #expect(loopStep.active == true)
        #expect(m.time == 0.0)
        #expect(loopStep.effects.contains(.restart(1.0)))
    }
}
