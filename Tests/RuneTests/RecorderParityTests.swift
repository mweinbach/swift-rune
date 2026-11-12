import Foundation
import Testing
import RuneMotion
@testable import Rune

#if os(macOS) && canImport(AVFoundation)
import AVFoundation
#endif

@Suite("Recorder Parity Tests (control_tests.rs + tests.rs)", .serialized)
struct RecorderParityTests {
    private final class Scratch {
        let dir: URL
        init(_ name: String) {
            self.dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("rune-recorder-\(ProcessInfo.processInfo.processIdentifier)-\(name)-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        deinit {
            try? FileManager.default.removeItem(at: dir)
        }
        func join(_ name: String) -> URL { dir.appendingPathComponent(name) }
    }

    private final class StepRuntime<S> {
        let rt: Runtime<S>
        private(set) var clock: Double = 0
        init(_ state: S, view: @escaping (S, inout Cx<S>) -> El<S>) {
            self.rt = Runtime(state: state, viewport: Vec2(10, 10), pixelScale: 2.0, view: view)
        }
        func frame(_ dt: Double) {
            clock += dt
            _ = rt.frame(at: clock)
        }
        func presented(_ key: String) -> ElementInfo? {
            rt.element(byKey: key)
        }
    }

    private func makeRuntime() -> StepRuntime<()> {
        StepRuntime(()) { _, _ in el().size(10, 10) }
    }

    private func near(_ got: Double, _ want: Double, _ tolerance: Double = 1e-9) {
        #expect(abs(got - want) <= tolerance, "got \(got), want \(want)")
    }

    // MARK: - control_tests.rs (7 tests)

    private func makeControl() -> RecorderControl {
        RecorderControl(url: URL(fileURLWithPath: "note.m4a"))
    }

    private func startControl(_ c: inout RecorderControl) -> UInt64 {
        let effects = Array(c.step(.start(url: URL(fileURLWithPath: "note.m4a"), virtualClock: false), now: 0.0))
        guard effects.count == 2,
              case .silence = effects[0],
              case let .ask(attempt) = effects[1] else {
            Issue.record("start did not emit [silence, ask]")
            return 0
        }
        return attempt
    }

    private func isEmpty(_ effects: Effects<RecorderEffect>) -> Bool {
        var it = effects.makeIterator()
        return it.next() == nil
    }

    @Test("a_permission_answer_after_cancel_opens_nothing")
    func permissionAnswerAfterCancelOpensNothing() {
        var c = makeControl()
        let attempt = startControl(&c)
        #expect(c.status() == .starting)
        _ = c.step(.cancel, now: nil)
        #expect(isEmpty(c.step(.permission(attempt: attempt, granted: .success(())), now: nil)))
        #expect(c.status() == .idle)

        let again = startControl(&c)
        #expect(isEmpty(c.step(.permission(attempt: attempt, granted: .success(())), now: nil)))
        let opened = Array(c.step(.permission(attempt: again, granted: .success(())), now: nil))
        #expect(opened.count == 1)
        if case let .open(a) = opened.first {
            #expect(a == again)
        } else {
            Issue.record("expected open(again)")
        }
    }

    @Test("stale_reports_change_nothing")
    func staleReportsChangeNothing() {
        var c = makeControl()
        let stale = startControl(&c)
        _ = c.step(.stop, now: nil)
        let attempt = startControl(&c)
        let generation = c.generation
        let staleEvents: [RecorderEvent] = [
            .failed(attempt: stale, error: "late"),
            .permission(attempt: stale, granted: .failure("late")),
            .interrupted(attempt: stale, reason: "late", duration: 1.0),
            .stopped(attempt: stale, result: .success(1.0)),
            .began(attempt: attempt),
        ]
        for ev in staleEvents {
            #expect(isEmpty(c.step(ev, now: 1.0)))
        }
        if case let .asking(a) = c.phase {
            #expect(a == attempt)
        } else {
            Issue.record("expected asking(attempt)")
        }
        #expect(c.generation == generation)
    }

    @Test("a_start_while_starting_changes_nothing")
    func startWhileStartingChangesNothing() {
        var c = makeControl()
        let attempt = startControl(&c)
        #expect(isEmpty(c.step(.start(url: URL(fileURLWithPath: "other.m4a"), virtualClock: true), now: nil)))
        if case let .asking(a) = c.phase {
            #expect(a == attempt)
        } else {
            Issue.record("expected asking(attempt)")
        }
        #expect(c.url.path == URL(fileURLWithPath: "note.m4a").path)
        #expect(!c.virtualClock)
    }

    @Test("an_interruption_while_the_device_finishes_returns_what_it_saved")
    func interruptionWhileDeviceFinishesReturnsWhatItSaved() {
        var c = makeControl()
        let attempt = c.seq.next()
        c.phase = .stopping(attempt: attempt, paused: false)
        #expect(c.status() == .recording)
        _ = c.step(.interrupted(attempt: attempt, reason: "the input device changed", duration: 2.0), now: nil)
        #expect(c.status() == .interrupted("the input device changed"))
        let reply = Array(c.step(.stopped(attempt: attempt, result: .failure("the recording already ended")), now: nil))
        #expect(reply.count == 2)
        if case .silence = reply[0], case let .reply(.success(r)) = reply[1] {
            #expect(r.duration == 2.0)
        } else {
            Issue.record("expected [silence, reply(ok(2.0))]")
        }
        #expect(c.status() == .stopped)
    }

    @Test("stopping_reads_as_the_phase_it_left")
    func stoppingReadsAsPhaseItLeft() {
        var c = makeControl()
        let attempt = c.seq.next()
        c.phase = .stopping(attempt: attempt, paused: true)
        #expect(c.status() == .paused)
        if case .reply(.failure) = Array(c.step(.stop, now: nil)).first {
        } else {
            Issue.record("expected reply(err)")
        }
        #expect(isEmpty(c.step(.cancel, now: nil)))
        #expect(isEmpty(c.step(.start(url: URL(fileURLWithPath: "note.m4a"), virtualClock: false), now: nil)))
        #expect(c.status() == .paused)
    }

    @Test("an_input_opened_for_a_gone_attempt_is_cancelled")
    func inputOpenedForGoneAttemptIsCancelled() {
        var c = makeControl()
        let attempt = startControl(&c)
        _ = c.step(.cancel, now: nil)
        let session = RecorderBackend.idleSession()
        let effects = Array(c.step(.deviceOpened(attempt: attempt, opened: .success(session)), now: nil))
        #expect(effects.count == 1)
        if case .cancelDevice = effects[0] {
        } else {
            Issue.record("expected cancelDevice")
        }
        #expect(c.status() == .idle)
    }

    @Test("a_device_recording_pauses_resumes_and_hands_its_session_to_stop")
    func deviceRecordingPausesResumesAndHandsSessionToStop() {
        var c = makeControl()
        let attempt = startControl(&c)
        _ = c.step(.permission(attempt: attempt, granted: .success(())), now: 0.0)
        let session = RecorderBackend.idleSession()
        _ = c.step(.deviceOpened(attempt: attempt, opened: .success(session)), now: 0.0)
        #expect(c.status() == .starting)
        _ = c.step(.began(attempt: attempt), now: 1.0)
        _ = c.step(.tick, now: 3.0)
        #expect(c.status() == .recording)
        #expect(c.elapsed == 2.0)

        let paused = Array(c.step(.pause, now: 4.0))
        #expect(paused.count == 2)
        if case .silence = paused[0], case .pauseDevice = paused[1] {} else { Issue.record("expected [silence, pauseDevice]") }
        _ = c.step(.tick, now: 10.0)
        #expect(c.elapsed == 3.0)

        let resumed = Array(c.step(.resume, now: 10.0))
        #expect(resumed.count == 1)
        if case .resumeDevice = resumed[0] {} else { Issue.record("expected [resumeDevice]") }

        let stopped = Array(c.step(.stop, now: 11.0))
        #expect(stopped.count == 1)
        if case let .stopDevice(a, _) = stopped[0] {
            #expect(a == attempt)
        } else {
            Issue.record("expected stopDevice")
        }
        #expect(c.status() == .recording)
        #expect(c.elapsed == 4.0)
        _ = c.step(.stopped(attempt: attempt, result: .success(4.0)), now: 11.5)
        #expect(c.status() == .stopped)
    }

    // MARK: - tests.rs (24 tests)

    @Test("a_recording_starts_pauses_resumes_and_stops")
    func recordingStartsPausesResumesAndStops() {
        FakeMicrophone.silence().install()
        defer { FakeMicrophone.uninstall() }
        let dir = Scratch("states")
        let rec = Recorder.toFile(dir.join("note.wav"))
        let rt = makeRuntime()
        #expect(rec.state() == .idle)
        #expect(rec.stop() == .failure("not recording"))
        rec.start()
        #expect(rec.state() == .recording)
        #expect(rec.isRecording())
        rt.frame(0.25)
        near(rec.elapsed(), 0.25)
        rec.pause()
        #expect(rec.state() == .paused)
        rt.frame(0.5)
        near(rec.elapsed(), 0.25)
        rec.resume()
        rec.start()
        rt.frame(0.1)
        near(rec.elapsed(), 0.35)
        let note = try! rec.stop().get()
        #expect(note.url == dir.join("note.wav"))
        near(note.duration, 0.35)
        #expect(rec.state() == .stopped)
        rt.frame(0.2)
        near(rec.elapsed(), 0.35)
        #expect(rec.stop() == .failure("not recording"))
        rec.start()
        #expect(rec.elapsed() == 0.0)
        rt.frame(0.1)
        near(rec.elapsed(), 0.1)
    }

    @Test("a_new_runtime_restarts_elapsed_from_its_own_clock")
    func newRuntimeRestartsElapsedFromItsOwnClock() {
        FakeMicrophone.silence().install()
        defer { FakeMicrophone.uninstall() }
        let dir = Scratch("clock")
        let old = makeRuntime()
        old.frame(5.0)
        let rec = Recorder.toFile(dir.join("note.wav"))
        rec.start()
        let rt = makeRuntime()
        rt.frame(0.1)
        rt.frame(0.1)
        near(rec.elapsed(), 0.2)
    }

    @Test("a_known_sine_reads_its_known_peak_and_rms")
    func knownSineReadsKnownPeakAndRMS() {
        let dir = Scratch("sine")
        FakeMicrophone.sine(1000.0, 0.5).install()
        defer { FakeMicrophone.uninstall() }
        let rec = Recorder.toFile(dir.join("a.wav"))
        let rt = makeRuntime()
        #expect(rec.level() == .silent)
        rec.start()
        rt.frame(1.0)
        let lvl = rec.level()
        near(Double(lvl.peakDB()), 20.0 * log10(0.5), 0.01)
        near(Double(lvl.rmsDB()), 20.0 * log10(0.5 / sqrt(2.0)), 0.01)
        near(Double(lvl.meter()), (60.0 - 9.0309) / 60.0, 0.001)
        #expect(rec.liveLevel().get() == lvl.meter())
        rec.pause()
        #expect(rec.level() == .silent)
        #expect(rec.liveLevel().get() == 0.0)
        _ = try! rec.stop().get()

        let rec2 = Recorder.toFile(dir.join("b.wav"))
        let rt2 = makeRuntime()
        rec2.start()
        for _ in 0..<64 {
            rt2.frame(1.0 / 64.0)
        }
        #expect(rec2.level() == lvl)

        FakeMicrophone.silence().install()
        let quiet = Recorder.toFile(dir.join("c.wav"))
        quiet.start()
        rt2.frame(0.5)
        #expect(quiet.level() == .silent)
        #expect(quiet.level().meter() == 0.0)
    }

    @Test("the_meter_rises_fast_and_falls_slowly")
    func meterRisesFastAndFallsSlowly() {
        var m = RecorderMeter()
        for _ in 0..<3 {
            m.push(peak: 0.5, meanSquare: 0.125, dt: 0.01)
        }
        let rising = m.level()
        #expect(rising.rmsDB() > -12.0)
        for _ in 0..<10 {
            m.push(peak: 0.0, meanSquare: 0.0, dt: 0.01)
        }
        let falling = m.level()
        #expect(falling.rmsDB() > -13.0 && falling.rmsDB() < rising.rmsDB())
        near(Double(falling.peakDB()), -6.0206 - 2.0, 0.01)
        m.push(peak: .nan, meanSquare: .infinity, dt: 0.01)
        #expect(m.level().rmsDB().isFinite)
    }

    @Test("a_bound_meter_follows_the_level_on_the_same_frame")
    func boundMeterFollowsLevelOnSameFrame() {
        let dir = Scratch("bound")
        FakeMicrophone.sine(1000.0, 0.5).install()
        defer { FakeMicrophone.uninstall() }
        let rec = Recorder.toFile(dir.join("a.wav"))
        let stepRt = StepRuntime(rec) { r, _ in
            el().key("meter").size(10, 10).bg(Color.white).liveOpacity(r.liveLevel().binding)
        }
        stepRt.frame(0.0)
        #expect(stepRt.presented("meter")?.opacity == 0.0)
        rec.start()
        stepRt.frame(1.0)
        near(Double(stepRt.presented("meter")!.opacity), Double(rec.level().meter()), 1e-6)
        #expect(rec.level().meter() > 0.8)
        _ = try! rec.stop().get()
        stepRt.frame(0.1)
        #expect(stepRt.presented("meter")?.opacity == 0.0)
    }

    @Test("stopping_writes_a_wav_of_the_recorded_length")
    func stoppingWritesWAVOfRecordedLength() {
        let dir = Scratch("length")
        FakeMicrophone.sine(1000.0, 0.5).install()
        defer { FakeMicrophone.uninstall() }
        let rec = Recorder.toFile(dir.join("note.wav"))
        let rt = makeRuntime()
        rec.start()
        rt.frame(1.5)
        let note = try! rec.stop().get()
        near(note.duration, 1.5)
        let (rate, samples) = try! FakeMicrophone.readWAV(at: note.url).get()
        #expect(rate == 48_000)
        #expect(samples.count == 72_000)
        near(Double(samples[12]), 0.5, 1.0 / 32_000.0)
        near(Double(samples[36]), -0.5, 1.0 / 32_000.0)
    }

    @Test("an_aac_recorder_on_a_fake_microphone_writes_wav_beside_its_path")
    func aacRecorderOnFakeWritesWAVBesidePath() {
        let dir = Scratch("aac")
        FakeMicrophone.silence().install()
        defer { FakeMicrophone.uninstall() }
        let rec = Recorder.toFile(dir.join("note.m4a"))
        let rt = makeRuntime()
        rec.start()
        rt.frame(0.2)
        let note = try! rec.stop().get()
        #expect(note.url == dir.join("note.wav"))
        #expect(FileManager.default.fileExists(atPath: note.url.path))
        #expect(!FileManager.default.fileExists(atPath: dir.join("note.m4a").path))
        #expect(rec.path() == dir.join("note.m4a"))
    }

    @Test("the_format_decides_the_file_extension")
    func formatDecidesFileExtension() {
        let dir = Scratch("extension")
        FakeMicrophone.silence().install()
        defer { FakeMicrophone.uninstall() }
        func rel(_ rec: Recorder) -> String {
            rec.path().lastPathComponent
        }
        #expect(rel(Recorder.toFile(dir.join("x.wav")).format(.aac)) == "x.m4a")
        #expect(rel(Recorder.toFile(dir.join("x.m4a")).format(.wav)) == "x.wav")
        #expect(rel(Recorder.toFile(dir.join("x"))) == "x.m4a")
        #expect(rel(Recorder.toFile(dir.join("x.mp3"))) == "x.m4a")
        #expect(rel(Recorder.toFile(dir.join("x.MP4"))) == "x.MP4")
        #expect(rel(Recorder.toFile(dir.join("x.WAV"))) == "x.WAV")

        let wav = Recorder.toFile(dir.join("note.m4a")).format(.wav)
        wav.start()
        let note = try! wav.stop().get()
        #expect(note.url == dir.join("note.wav"))
        let data = try! Data(contentsOf: note.url)
        #expect(Array(data.prefix(4)) == Array("RIFF".utf8))
        #expect(!FileManager.default.fileExists(atPath: dir.join("note.m4a").path))
    }

    @Test("dropping_the_last_handle_keeps_the_recording")
    func droppingLastHandleKeepsRecording() {
        let dir = Scratch("drop")
        FakeMicrophone.sine(1000.0, 0.5).install()
        defer { FakeMicrophone.uninstall() }
        let rt = makeRuntime()

        var recA: Recorder? = Recorder.toFile(dir.join("a.wav"))
        recA!.start()
        rt.frame(0.25)
        var cloneA: Recorder? = recA
        recA = nil
        rt.frame(0.25)
        #expect(cloneA!.isRecording())
        cloneA = nil
        let (_, samplesA) = try! FakeMicrophone.readWAV(at: dir.join("a.wav")).get()
        #expect(samplesA.count == 24_000)

        var recB: Recorder? = Recorder.toFile(dir.join("b.wav"))
        recB!.start()
        rt.frame(0.1)
        recB!.pause()
        rt.frame(0.5)
        recB = nil
        #expect(try! FakeMicrophone.readWAV(at: dir.join("b.wav")).get().1.count == 4_800)

        var recC: Recorder? = Recorder.toFile(dir.join("c.wav"))
        recC!.start()
        rt.frame(0.1)
        recC!.cancel()
        recC = nil
        #expect(!FileManager.default.fileExists(atPath: dir.join("c.wav").path))
    }

    @Test("cancelling_a_pending_start_keeps_an_earlier_file")
    func cancellingPendingStartKeepsEarlierFile() {
        let dir = Scratch("pending")
        FakeMicrophone.silence().install()
        defer { FakeMicrophone.uninstall() }
        let path = dir.join("note.wav")
        let rec = Recorder.toFile(path)
        let rt = makeRuntime()
        rec.start()
        rt.frame(0.2)
        _ = try! rec.stop().get()
        rec.shared.unsafeControlMutate { c in
            let attempt = c.seq.next()
            c.phase = .asking(attempt: attempt)
        }
        rec.cancel()
        #expect(rec.state() == .idle)
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test("frame_rate_never_moves_a_sample_level_or_unplug")
    func frameRateNeverMovesSampleLevelOrUnplug() {
        let dir = Scratch("rate")
        FakeMicrophone.default.install()
        defer { FakeMicrophone.uninstall() }

        let rt1 = makeRuntime()
        let one = Recorder.toFile(dir.join("one.wav"))
        one.start()
        rt1.frame(1.0)
        let (level, note) = (one.level(), try! one.stop().get())

        let rt60 = makeRuntime()
        let sixty = Recorder.toFile(dir.join("sixty.wav"))
        sixty.start()
        for _ in 0..<60 {
            rt60.frame(1.0 / 60.0)
        }
        #expect(sixty.level() == level)
        let other = try! sixty.stop().get()
        #expect(other.duration == note.duration)
        #expect(try! FakeMicrophone.readWAV(at: other.url).get().1.count == 48_000)

        FakeMicrophone.silence().unplugAfter(0.3).install()
        let rtU = makeRuntime()
        let rec = Recorder.toFile(dir.join("unplug.wav"))
        rec.start()
        for _ in 0..<18 {
            rtU.frame(1.0 / 60.0)
        }
        if case .interrupted = rec.state() {} else {
            Issue.record("expected interrupted on 18th frame, got \(rec.state())")
        }
        #expect(try! rec.stop().get().duration == 0.3)
    }

    @Test("a_restarted_recorder_is_followed_once")
    func restartedRecorderFollowedOnce() {
        let dir = Scratch("restart")
        FakeMicrophone.silence().install()
        defer { FakeMicrophone.uninstall() }
        let rt = makeRuntime()
        let rec = Recorder.toFile(dir.join("note.wav"))
        for _ in 0..<3 {
            rec.start()
            rt.frame(0.1)
            _ = try! rec.stop().get()
        }
        let followed = RecorderShared.headlessList().filter { $0 === rec.shared }.count
        #expect(followed == 1)
    }

    @Test("levels_pack_into_one_word")
    func levelsPackIntoOneWord() {
        for lvl in [Level.silent, Level.new(-6.0, -9.0), Level.new(0.0, -160.0)] {
            #expect(Recorder.unpack(Recorder.pack(lvl)) == lvl)
        }
    }

    @Test("a_stale_failure_leaves_the_current_session")
    func staleFailureLeavesCurrentSession() {
        let rec = Recorder.toFile(FileManager.default.temporaryDirectory.appendingPathComponent("rune-recorder-stale.m4a"))
        let session = RecorderBackend.idleSession()
        let (stale, attempt) = rec.shared.unsafeControlMutateAndReturn { c -> (UInt64, UInt64) in
            let s = c.seq.next()
            let a = c.seq.next()
            c.phase = .opening(attempt: a, session: session)
            return (s, a)
        }
        rec.shared.beganFailure(attempt: stale, error: "late")
        let stillOpening = rec.shared.unsafeControlInspect { c in
            if case .opening = c.phase { return true }
            return false
        }
        #expect(stillOpening)
        rec.shared.beganFailure(attempt: attempt, error: "now")
        let failedNow = rec.shared.unsafeControlInspect { c in
            if case .failed = c.phase { return true }
            return false
        }
        #expect(failedNow)
    }

    @Test("a_second_stop_while_the_device_finishes_changes_nothing")
    func secondStopWhileDeviceFinishesChangesNothing() {
        let rec = Recorder.toFile(FileManager.default.temporaryDirectory.appendingPathComponent("rune-recorder-second-stop.m4a"))
        let session = RecorderBackend.idleSession()
        rec.shared.unsafeControlMutate { c in
            let attempt = c.seq.next()
            c.phase = .recording(attempt: attempt, source: .device(session), anchor: nil)
        }
        let firstDone = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var res: Result<Recording, RecorderError>? }
        let box = Box()
        Thread {
            box.res = rec.stop()
            firstDone.signal()
        }.start()

        var stopReply: RecorderBackendSession.CheckedReply<Result<Double, RecorderError>>?
        let deadline = Date().addingTimeInterval(2.0)
        while stopReply == nil && Date() < deadline {
            if let cmd = session.pop(timeout: 0.05), case let .stop(r) = cmd {
                stopReply = r
            }
        }
        guard let reply = stopReply else {
            Issue.record("the device was never asked to stop")
            return
        }
        #expect(rec.stop() == .failure("not recording"))
        rec.cancel()
        #expect(rec.state() == .recording)
        reply.send(.success(1.5))
        _ = firstDone.wait(timeout: .now() + 2.0)
        #expect(box.res.map { $0.map(\.duration) } == .success(1.5))
        #expect(rec.state() == .stopped)
    }

    @Test("finishing_on_the_recorder_thread_doesnt_wait_on_itself")
    func finishingOnRecorderThreadDoesntWaitOnItself() {
        let session = RecorderBackend.idleSession()
        let started = ProcessInfo.processInfo.systemUptime
        let done = DispatchSemaphore(value: 0)
        Thread {
            RecorderBackend.markRecorderThread()
            RecorderBackend.finish(session)
            done.signal()
        }.start()
        #expect(done.wait(timeout: .now() + 1.0) == .success)
        #expect(ProcessInfo.processInfo.systemUptime - started < 1.0)
        #expect(session.tryPopAll().isEmpty)
    }

    @Test("cancel_deletes_the_file_of_a_recording_in_progress")
    func cancelDeletesFileOfRecordingInProgress() {
        let dir = Scratch("cancel")
        FakeMicrophone.silence().install()
        defer { FakeMicrophone.uninstall() }
        let path = dir.join("note.wav")
        let rec = Recorder.toFile(path)
        let rt = makeRuntime()
        rec.start()
        #expect(FileManager.default.fileExists(atPath: path.path))
        rt.frame(0.3)
        rec.cancel()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(rec.state() == .idle)
        if case .failure = rec.stop() {} else { Issue.record("expected err") }

        rec.start()
        rt.frame(0.3)
        rec.pause()
        rec.cancel()
        #expect(!FileManager.default.fileExists(atPath: path.path))

        rec.start()
        rt.frame(0.3)
        _ = try! rec.stop().get()
        rec.cancel()
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(rec.state() == .stopped)
    }

    @Test("starting_without_permission_fails_clearly")
    func startingWithoutPermissionFailsClearly() {
        let dir = Scratch("permission")
        let path = dir.join("note.wav")
        FakeMicrophone.silence().permission(.denied).install()
        defer { FakeMicrophone.uninstall() }
        #expect(Recorder.permission() == .denied)
        let rec = Recorder.toFile(path)
        rec.start()
        guard case let .failed(msg) = rec.state() else {
            Issue.record("expected failed, got \(rec.state())")
            return
        }
        #expect(msg.contains("denied"))
        #expect(!rec.isRecording())
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(rec.stop() == .failure(RecorderError(msg)))

        FakeMicrophone.silence().permission(.restricted).install()
        rec.start()
        if case let .failed(m) = rec.state() { #expect(m.contains("restricted")) } else { Issue.record("expected failed") }

        FakeMicrophone.silence().permission(.undetermined).answers(.denied).install()
        rec.start()
        if case let .failed(m) = rec.state() { #expect(m.contains("denied")) } else { Issue.record("expected failed") }
        #expect(Recorder.permission() == .denied)

        FakeMicrophone.silence().permission(.undetermined).install()
        final class Box: @unchecked Sendable { var p: MicPermission? }
        let box = Box()
        Recorder.requestPermission { p in box.p = p }
        #expect(box.p == .granted)
        #expect(Recorder.permission() == .granted)
        rec.start()
        #expect(rec.state() == .recording)

        let own = Recorder.toFile(dir.join("own.wav")).fake(FakeMicrophone.silence().permission(.undetermined).answers(.granted))
        own.start()
        #expect(own.state() == .recording)
    }

    @Test("an_unplugged_microphone_keeps_what_was_captured")
    func unpluggedMicrophoneKeepsWhatWasCaptured() {
        let dir = Scratch("unplug")
        FakeMicrophone.sine(440.0, 0.25).unplugAfter(0.5).install()
        defer { FakeMicrophone.uninstall() }
        let rec = Recorder.toFile(dir.join("note.wav"))
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var n = 0
            func inc() { lock.withLock { n += 1 } }
            func get() -> Int { lock.withLock { n } }
        }
        let changes = Counter()
        rec.setWaker { changes.inc() }
        let rt = makeRuntime()
        rec.start()
        rt.frame(0.3)
        #expect(rec.state() == .recording)
        let before = changes.get()
        rt.frame(0.4)
        #expect(changes.get() == before + 1)
        #expect(rec.state() == .interrupted("the microphone went away"))
        near(rec.elapsed(), 0.5)
        #expect(rec.level() == .silent)
        let note = try! rec.stop().get()
        near(note.duration, 0.5)
        #expect(try! FakeMicrophone.readWAV(at: note.url).get().1.count == 24_000)
        #expect(rec.state() == .stopped)

        rec.start()
        rt.frame(0.6)
        if case .interrupted = rec.state() {} else { Issue.record("expected interrupted") }
        rec.cancel()
        #expect(!FileManager.default.fileExists(atPath: note.url.path))
    }

    @Test("the_waker_hears_state_changes_not_progress")
    func wakerHearsStateChangesNotProgress() {
        let dir = Scratch("waker")
        FakeMicrophone.silence().install()
        defer { FakeMicrophone.uninstall() }
        let rec = Recorder.toFile(dir.join("note.wav"))
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var n = 0
            func inc() { lock.withLock { n += 1 } }
            func get() -> Int { lock.withLock { n } }
        }
        let calls = Counter()
        rec.setWaker { calls.inc() }
        #expect(calls.get() == 0)
        let rt = makeRuntime()
        rec.start()
        #expect(calls.get() == 1)
        rt.frame(0.1)
        rt.frame(0.1)
        _ = (rec.elapsed(), rec.level())
        #expect(calls.get() == 1)
        rec.pause()
        rec.resume()
        _ = try! rec.stop().get()
        #expect(calls.get() == 4)
    }

    @Test("wav_and_sample_inputs_record_their_samples")
    func wavAndSampleInputsRecordTheirSamples() {
        let dir = Scratch("wav")
        let ramp: [Float] = (0..<800).map { Float($0) / 800.0 - 0.5 }
        let rec = Recorder.toFile(dir.join("ramp.wav")).fake(FakeMicrophone.samples(rate: 8_000, ramp))
        let rt = makeRuntime()
        rec.start()
        rt.frame(0.25)
        let rampFile = try! rec.stop().get().url
        let (rate, got) = try! FakeMicrophone.readWAV(at: rampFile).get()
        #expect(rate == 8_000)
        #expect(got.count == 2_000)
        for (i, s) in got.enumerated() {
            near(Double(s), Double(ramp[i % 800]), 1.0 / 32_000.0)
        }

        let again = Recorder.toFile(dir.join("again.wav")).fake(FakeMicrophone.wav(rampFile))
        again.start()
        rt.frame(0.125)
        let (_, copy) = try! FakeMicrophone.readWAV(at: try! again.stop().get().url).get()
        #expect(copy.count == 1_000)
        for (a, b) in zip(copy, got) {
            near(Double(a), Double(b), 1.0 / 32_000.0)
        }

        let missing = Recorder.toFile(dir.join("x.wav")).fake(FakeMicrophone.wav(dir.join("missing.wav")))
        missing.start()
        if case let .failed(m) = missing.state() {
            #expect(m.contains("couldn't read"))
        } else {
            Issue.record("expected failed")
        }
    }

    @Test("an_unwritable_path_fails_to_start")
    func unwritablePathFailsToStart() {
        FakeMicrophone.silence().install()
        defer { FakeMicrophone.uninstall() }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-recorder-missing-dir-\(UUID().uuidString)")
            .appendingPathComponent("deeper")
            .appendingPathComponent("note.wav")
        let rec = Recorder.toFile(url)
        rec.start()
        if case let .failed(m) = rec.state() {
            #expect(m.contains("couldn't write"), "\(m)")
        } else {
            Issue.record("expected failed, got \(rec.state())")
        }
    }

    @Test("wav_files_parse_formats_and_reject_others")
    func wavFilesParseFormatsAndRejectOthers() {
        if case .failure = FakeMicrophone.parseWAV(Data("RIFF\0\0\0\0WAVE".utf8)) {} else { Issue.record("expected err") }
        if case .failure = FakeMicrophone.parseWAV(Data("not a wav".utf8)) {} else { Issue.record("expected err") }

        var b = Data()
        func putU16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { b.append(contentsOf: $0) } }
        func putU32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { b.append(contentsOf: $0) } }
        func putF32(_ v: Float) { var le = v.bitPattern.littleEndian; withUnsafeBytes(of: &le) { b.append(contentsOf: $0) } }
        b.append(contentsOf: "RIFF".utf8)
        putU32(0)
        b.append(contentsOf: "WAVEfmt ".utf8)
        putU32(16)
        putU16(3)
        putU16(2)
        putU32(22_050)
        putU32(22_050 * 8)
        putU16(8)
        putU16(32)
        b.append(contentsOf: "data".utf8)
        putU32(16)
        for s: Float in [0.5, -0.5, 1.0, 0.0] {
            putF32(s)
        }
        let parsed = try! FakeMicrophone.parseWAV(b).get()
        #expect(parsed.0 == 22_050)
        #expect(parsed.1 == [0.0, 0.5])
    }

    #if os(macOS) && canImport(AVFoundation)
    @Test("the_macos_recorder_builds_without_capturing")
    func macosRecorderBuildsWithoutCapturing() {
        let dir = Scratch("macos")
        for (name, fmt) in [("a.m4a", RecordFormat.aac), ("b.wav", RecordFormat.wav)] {
            let opts = RecorderOptions(format: fmt, sampleRate: 44_100, channels: 1, fake: nil)
            let avRec = try! RecorderBackend.makeRecorder(url: dir.join(name), options: opts).get()
            #expect(!avRec.isRecording)
        }
        #expect((try? RecorderBackend.preflight().get()) != nil)
        _ = RecorderBackend.permission()
    }
    #endif
}

private extension RecorderShared {
    func unsafeControlMutateAndReturn<R>(_ body: (inout RecorderControl) -> R) -> R {
        var out: R!
        unsafeControlMutate { c in out = body(&c) }
        return out
    }
}
