import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

#if (canImport(AVFoundation) && !os(watchOS)) || canImport(CRuneMedia)
let nativeMediaAvailableForTests = true
#else
let nativeMediaAvailableForTests = false
#endif

func mediaFixtureURL(_ name: String) -> URL {
    let resources = Bundle.module.resourceURL ?? Bundle.module.bundleURL
    return resources.appendingPathComponent("Fixtures").appendingPathComponent(name)
}

@Suite("Video Parity Tests")
struct VideoParityTests {
    @Test("A mounted video view retains its player until the last placement is released")
    func retainedMountedPlayer() throws {
        func mount() -> (El<Void>, () -> Player?) {
            let player = Player.file("/nonexistent/rune-video-lifetime.mp4")
            return (video(player), { [weak player] in player })
        }
        var (element, player) = mount()
        var placement = element.surfacePayload?.surface.placed(.centered)
        #expect(player() != nil)
        #expect(placement?.key == player()?.surface.key)
        element = el()
        #expect(player() != nil)
        placement = nil
        #expect(player() == nil)
    }

    @Test("missing file, .ogv, and unsupported .ogg/.webm fail cleanly without resurrection")
    func unsupportedAndMissingFilesFailCleanly() async throws {
        let missing = Player.file("/nonexistent/path/not-a-file.mp4")
        for _ in 0..<100 {
            if missing.state.isFailed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let failure = missing.state
        guard case .failed(let reason) = failure else {
            Issue.record("Expected a missing-file error, got \(failure)")
            return
        }
        #expect(reason.hasPrefix("media file not found: "))
        missing.play()
        #expect(missing.state == failure)
        missing.seek(to: 0.5)
        #expect(missing.state == failure)

        let ogv = Player.file("/tmp/sample.ogv")
        if case .failed(let msg) = ogv.snapshot().state {
            #expect(msg.contains(".ogv"))
        } else {
            Issue.record("expected .ogv to fail cleanly")
        }

        let oggVorbis = Player(source: .file(mediaFixtureURL("sine-vorbis.ogg")))
        #expect(oggVorbis.snapshot().state.isFailed)

        let oggOpus = Player(source: .file(mediaFixtureURL("sine-opus.ogg")))
        #expect(oggOpus.snapshot().state.isFailed)

        let webmOpus = Player(source: .file(mediaFixtureURL("sine-opus.webm")))
        #expect(webmOpus.snapshot().state.isFailed)
    }

    @Test("audio fixtures silence.m4a and silence.wav probe as audio and respect duration", .enabled(if: nativeMediaAvailableForTests))
    func audioFixturesProbeAndPlay() {
        for name in ["silence.m4a", "silence.wav"] {
            let p = Player(source: .file(mediaFixtureURL(name)))
            let snap = p.snapshot()
            #expect(snap.kind == .audio)
            #expect(snap.state == .ready)
            #expect(snap.size == nil)
            #expect((snap.duration ?? 0) > 0.05)
        }
    }

    @Test("video fixture rgbw.mp4 decodes pixels and advances across virtual clock", .enabled(if: nativeMediaAvailableForTests))
    func rgbwFixtureProbesAndPlaysInHeadlessRuntime() throws {
        struct S {}
        let p = Player(source: .file(mediaFixtureURL("rgbw.mp4")), playing: true, looping: false)
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

    @Test("quadrants-rot90.mp4 detects 90-degree preferredTransform orientation and swaps upright size", .enabled(if: nativeMediaAvailableForTests))
    func rotatedVideoOrientationAndGPU() throws {
        let p = Player(source: .file(mediaFixtureURL("quadrants-rot90.mp4")))
        #expect(p.meta.kind == .video)
        #expect(p.orient.swaps == true)
        let upright = p.size
        let frame = p.surface.currentFrame()
        #expect(frame != nil)
        if let f = frame, let up = upright {
            #expect(f.orient.swaps == true)
            #expect(f.orient.upright(width: f.size.0, height: f.size.1) == up)
        }

        #if canImport(Metal) || canImport(CRuneOffscreenGL)
        let renderer = try OffscreenGPURenderer()
        let rt = Runtime(state: (), viewport: Vec2(32, 64), pixelScale: 1) { _, _ in
            video(p, .fit).size(32, 64)
        }
        rt.srgbBlend = true
        let out = try renderer.renderOffscreen(rt.renderFrame(at: 0))
        try #require(out.width == 32 && out.height == 64)
        let decoded = try #require(p.surface.currentFrame())
        try #require(decoded.size == (64, 32))
        let sampler = try SurfacePlaneSampler(frame: decoded, srgbBlend: true)

        // The track turns the landscape buffer counterclockwise. Read the four source
        // quadrants directly, independent of the renderer's orientation transform.
        let quadrants = [(8, 16, 48, 8), (24, 16, 48, 24), (8, 48, 16, 8), (24, 48, 16, 24)]
        var colours = Set<SIMD4<UInt8>>()
        for (x, y, sourceX, sourceY) in quadrants {
            let sample = sampler.sample(bufferPixel: SIMD2(Float(sourceX), Float(sourceY)),
                                        displaySize: SIMD2(64, 32), exact: true)
            let expected = SIMD4<UInt8>((sample * 255).rounded(.toNearestOrAwayFromZero))
            let pixel = out.pixel(x: x, y: y)
            colours.insert(expected)
            for channel in 0..<4 {
                #expect(abs(Int(pixel[channel]) - Int(expected[channel])) <= 2,
                        "Rotated video at (\(x), \(y)): got \(pixel), expected \(expected)")
            }
        }
        #expect(colours.count == 4)
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
        _ = rt.frame(at: 0.1)
        _ = rt.frame(at: 0.2)
        #expect(rt.isAnimating == false)
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

    // MARK: - Ported Upstream `video/tests.rs:8-220` Parity Tests

    @Test("new_videos_are_muted_paused_and_loading")
    func newVideosAreMutedPausedAndLoading() {
        let v = Player.file("missing.mp4")
        #expect(v.isMuted == true)
        #expect(v.isLooping == false)
        #expect(v.isPlaying == false)
        #expect(v.rate == 1.0)
        #expect(v.time == 0.0)
        #expect(v.duration == nil)
        #expect(v.size == nil)
        #expect(v.hasSound == nil)
        #expect(v.isAudio == false)
        #expect(v.state == .loading)

        v.setRate(0.0)
        v.setRate(-2.0)
        v.setRate(.nan)
        #expect(v.rate == 1.0)
        v.setRate(1.5)
        #expect(v.rate == 1.5)
    }

    @Test("audio_starts_unmuted_with_no_size")
    func audioStartsUnmutedWithNoSize() {
        let a = Player.audio("missing.m4a")
        #expect(a.isAudio == true)
        #expect(a.isMuted == false)
        #expect(a.size == nil)

        let reqAudio = Player.request("https://example.com/audio.m4a").header("Authorization", "Bearer tok").audio()
        #expect(reqAudio.isAudio == true)
        #expect(reqAudio.isMuted == false)
    }

    @Test("extensions_come_from_the_last_path_segment")
    func extensionsFromLastPathSegmentOnly() {
        let ext: (String) -> String? = { Player.extensionFromLastSegment(of: MediaSource.parse($0)) }
        #expect(ext("https://example.com/media/clip") == nil)
        #expect(ext("https://host.ogg/clip") == nil)
        #expect(ext("https://host.ogg") == nil)
        #expect(ext("https://example.com/a.b/clip?x=1.ogg#t=2.webm") == nil)
        #expect(ext("https://example.com/media/clip.OGG?v=2#t") == "ogg")
        #expect(ext("file:///tmp/a.b/clip.opus") == "opus")
        #expect(ext("sounds.d/clip") == nil)
        #expect(ext("sounds/clip.webm") == "webm")
        #expect(ext("sounds/clip.") == nil)
    }

    @Test("the_waker_hears_each_state_change_once")
    func wakerHearsEachStateChangeOnce() {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func inc() { lock.lock(); count += 1; lock.unlock() }
            func get() -> Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let p = Player.audio("missing-waker.m4a")
        let calls = Counter()
        p.setWaker { calls.inc() }
        #expect(calls.get() == 0)

        p.openMetadataForTest(VideoMeta(kind: .audio, duration: 2.0, size: nil, hasSound: true))
        #expect(calls.get() == 1)
        // Re-settling without state transition must not double-wake
        p.settleStateWaker()
        #expect(calls.get() == 1)

        p.failForTest("gone")
        #expect(calls.get() == 2)
    }

    @Test("a_seek_before_the_clip_opens_is_clamped_when_it_does")
    func seekBeforeOpenIsClampedWhenOpened() {
        let v = Player.file("missing-seek-clamp.mp4")
        v.seek(to: 30.0)
        #expect(v.time == 30.0)
        v.openMetadataForTest(VideoMeta(kind: .video, duration: 1.0, size: (64, 36), hasSound: false))
        #expect(v.time == 1.0)
    }

    #if canImport(AVFoundation) && !os(watchOS)
    @Test("parking_never_releases_a_playing_clip")
    func parkingNeverReleasesPlayingClip() {
        let url = mediaFixtureURL("rgbw.mp4")
        let clips = (0..<6).map { _ in Player(source: .url(url)) }
        _ = Player.parkedWithForTest(clips[0])
        clips[0].openMetadataForTest(VideoMeta(kind: .video, duration: 1.0, size: (64, 36), hasSound: false))
        clips[0].play()
        var evicted: [Player] = []
        for clip in clips.dropFirst() {
            evicted.append(contentsOf: Player.parkedWithForTest(clip))
        }
        #expect(!evicted.contains(where: { $0 === clips[0] }))
        #expect(evicted.count == 1)
        #expect(evicted.first === clips[1])
    }
    #endif

    @Test("sources_tell_urls_from_paths")
    func sourcesTellUrlsFromPaths() {
        #expect(MediaSource.parse("https://example.com/a.mp3") == .url(URL(string: "https://example.com/a.mp3")!))
        #expect(MediaSource.parse("file:///tmp/a.wav") == .url(URL(string: "file:///tmp/a.wav")!))
        #expect(MediaSource.parse("sounds/a.m4a") == .file(URL(fileURLWithPath: "sounds/a.m4a")))
    }

    @Test("handle_edits_are_shared_and_validated")
    func handleEditsAreSharedAndValidated() {
        let v = Player.url("https://example.com/clip.mp4")
        #expect(v.source == .url(URL(string: "https://example.com/clip.mp4")!))
        let other = v
        other.setRate(2.0)
        other.setRate(-1.0)
        other.setRate(.nan)
        other.setLooping(true)
        other.setMuted(false)
        other.seek(to: -3.0)
        #expect(v.rate == 2.0)
        #expect(v.isLooping == true)
        #expect(v.isMuted == false)
        #expect(v.time == 0.0)
        v.play()
        if nativeMediaAvailableForTests {
            #expect(other.isPlaying)
            #expect(v.state == .loading)
        } else {
            #expect(!other.isPlaying)
            #expect(v.state.isFailed)
        }
    }

    @Test("state_follows_open_play_end_and_failure")
    func stateFollowsOpenPlayEndAndFailure() {
        var c = VideoPhases.PhaseControl()
        let meta = VideoPhases.PhaseMeta(duration: 1.0, size: (64, 36), frame: 0.25, sound: false)
        c.open(.success(meta))
        #expect(c.state == .ready)
        #expect(c.duration == 1.0 && c.size?.0 == 64 && c.size?.1 == 36)
        _ = VideoPhases.phaseStep(&c, .play)
        #expect(c.state == .playing)
        c.advanceVirtual(at: 10.0)
        c.advanceVirtual(at: 10.5)
        #expect(abs(c.time - 0.5) < 1e-9)
        let gen = c.generation
        c.advanceVirtual(at: 11.25)
        #expect(c.time == 1.0 && c.run == .ended)
        #expect(c.state == .ended)
        #expect(c.generation > gen)
        c.fail(.custom("boom"))
        c.fail(.custom("second"))
        #expect(c.state == .failed("boom"))
    }

    @Test("virtual_time_loops_rates_and_seeks")
    func virtualTimeLoopsRatesAndSeeks() {
        var c = VideoPhases.PhaseControl()
        c.open(.success(VideoPhases.PhaseMeta(duration: 1.0, size: (64, 36), frame: 0.25, sound: false)))
        _ = VideoPhases.phaseStep(&c, .play)
        c.looping = true
        c.rate = 2.0
        c.advanceVirtual(at: 0.0)
        c.advanceVirtual(at: 0.6)
        #expect(abs(c.time - 0.2) < 1e-9)
        #expect(c.isPlaying)
        _ = VideoPhases.phaseStep(&c, .seek(0.75))
        c.advanceVirtual(at: 5.0)
        #expect(c.time == 0.75)
        c.advanceVirtual(at: 5.1)
        #expect(abs(c.time - 0.95) < 1e-9)
        _ = VideoPhases.phaseStep(&c, .pause)
        c.advanceVirtual(at: 9.0)
        #expect(abs(c.time - 0.95) < 1e-9)
    }
}
