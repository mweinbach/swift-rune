import Foundation
import Testing
import RuneRef
@testable import Rune
@testable import RuneMotion

/// Full 1:1 port of upstream `crates/rune/src/rewind/tests.rs` (all 13 `#[test]`s).
@Suite("Rewind Full Parity Tests (13/13)", .serialized)
struct RewindFullParityTests {

    private struct AppState {
        var y: Float = 0
        var rewind: Rewind
        var scrub = Scrub()
        var sent: [RewindSent] = []
        var inset: Float = 0
    }

    private func makeApp(rewind: Rewind = Rewind()) -> Runtime<AppState> {
        let rt = Runtime(
            state: AppState(rewind: rewind),
            viewport: Vec2(400, 300),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            let appEl: El<AppState> = el()
                .size(400, 300)
                .child(el().key("title").absolute(x: 10, y: s.y).size(100, 20).bg(.white))
                .child(el().key("still").absolute(x: 200, y: 200).size(40, 40).bg(.white))
            return el()
                .size(400, 300)
                .child(appEl)
                .child(
                    el()
                        .absolute(x: s.inset, y: s.inset)
                        .size(400 - s.inset, 300 - s.inset)
                        .child(s.scrub.view(\.scrub) { st, sent, _ in st.sent.append(sent) })
                )
        }
        _ = rt.frame(at: 0.0)
        return rt
    }

    private func record(_ rt: Runtime<AppState>) {
        rt.update { s, tx in tx.recordRewind(s.rewind) }
        _ = rt.frame(at: rt.currentTime + 1.0 / 60.0)
    }

    private func jump(_ rt: Runtime<AppState>, y: Float) {
        rt.update { s, tx in
            s.y = y
            tx.settle()
        }
    }

    private func stepFrames(_ rt: Runtime<AppState>, _ count: Int) {
        for _ in 0..<count {
            _ = rt.frame(at: rt.currentTime + 1.0 / 60.0)
        }
    }

    private func keyPress(_ key: Key, shift: Bool = false) -> KeyEvent {
        KeyEvent(key: key, mods: Mods(shift: shift))
    }

    // 1. nothing_records_or_allocates_until_a_recorder_is_attached
    @Test func nothingRecordsOrAllocatesUntilARecorderIsAttached() {
        let rt = makeApp()
        stepFrames(rt, 5)
        #expect(rt.rewind() == nil)
        #expect(rt.state.rewind.frameCount == 0)
        #expect(rt.state.rewind.estimatedBytes == 0)
        // Runtime.recordRewind() early-returns on `guard rewindRecorder != nil else { return }`
        for _ in 0..<100 {
            rt.recordRewind()
        }
        #expect(rt.rewind() == nil)
        #expect(rt.state.rewind.frameCount == 0)
        #expect(rt.state.rewind.estimatedBytes == 0)
    }

    @Test("Runtime rewind includes visible traced and keyed elements in both paint paths", arguments: [false, true])
    func paintedRewindUsesVisibleTraceNames(native: Bool) throws {
        let recorder = RewindRecorder(windowSeconds: 5)
        let rt = Runtime<Void>(state: (), viewport: Vec2(100, 100), pixelScale: 1) { _, _ in
            col().wFull().hFull().opacity(0.5)
                .child(el().size(10, 10).traceName("traceOnly"))
                .child(el().key("authored").size(10, 10).traceName("preferred").opacity(0.5))
                .child(el().key("rewindUserKey").size(10, 10))
                .child(el().key("outside").absolute(x: 120, y: 120).size(5, 5))
        }
        rt.update { _, tx in tx.recordRewind(recorder) }
        if native { _ = rt.renderFrame(at: 0) } else { _ = rt.frame(at: 0) }
        let frame = try #require(recorder.freeze().frames.last)
        #expect(Set(frame.elements.map(\.key)) == ["traceOnly", "preferred", "rewindUserKey"])
        let preferred = try #require(frame.elements.first { $0.key == "preferred" })
        #expect(preferred.rect.xywh == rt.presented("authored")?.rect)
        #expect(preferred.opacity == 0.25)
    }

    // 2. a_poll_can_attach_the_recorder
    @Test func aPollCanAttachTheRecorder() {
        let rt = makeApp()
        rt.poll = { s, _, tx in
            if s.y == 0.0 {
                s.y = 1.0
                tx.recordRewind(s.rewind)
                return true
            }
            return false
        }
        stepFrames(rt, 3)
        #expect(rt.rewind() != nil)
        #expect(rt.state.rewind.frameCount > 0)
    }

    // 3. records_each_frame_and_stops_when_detached
    @Test func recordsEachFrameAndStopsWhenDetached() {
        let rt = makeApp()
        record(rt)
        stepFrames(rt, 9)
        let n = rt.state.rewind.frameCount
        #expect(n >= 10)
        rt.update { _, tx in tx.recordRewind(nil) }
        stepFrames(rt, 5)
        #expect(rt.state.rewind.frameCount == n, "nothing records once detached")
    }

    // 4. the_ring_keeps_only_its_window_and_rebuilds_old_frames
    @Test func theRingKeepsOnlyItsWindowAndRebuildsOldFrames() {
        let rt = makeApp(rewind: Rewind().seconds(1.0))
        record(rt)
        stepFrames(rt, 30)
        jump(rt, y: 40.0)
        stepFrames(rt, 300)
        let held = rt.state.rewind.frameCount
        #expect((59...62).contains(held), "a second at 60 Hz, held \(held)")
        let clip = rt.state.rewind.freeze()
        let first = clip.frame(0)
        #expect(first.count == 2)
        let title = first.first { clip.name($0.id) == "title" }!.snapshot
        #expect(title.rect == MotionRect.fromXYWH(10.0, 40.0, 100.0, 20.0))
    }

    // 5. the_ring_stays_within_its_byte_budget
    @Test func theRingStaysWithinItsByteBudget() {
        let budget = 4096
        let rt = makeApp(rewind: Rewind().maxBytes(budget))
        record(rt)
        for k in 0..<400 {
            jump(rt, y: Float(k % 50))
            _ = rt.frame(at: rt.currentTime + 1.0 / 60.0)
        }
        #expect(rt.state.rewind.estimatedBytes <= budget)
        #expect(rt.state.rewind.frameCount > 10)
    }

    // 6. a_one_frame_jump_is_found_and_labelled
    @Test func aOneFrameJumpIsFoundAndLabelled() {
        let rt = makeApp()
        record(rt)
        stepFrames(rt, 10)
        jump(rt, y: 7.5)
        stepFrames(rt, 10)
        let clip = rt.state.rewind.freeze()
        let k = (0..<clip.len).first { clip.hasJump($0) }!
        let changes = clip.changes(k)
        #expect(changes.count == 1)
        #expect(changes[0].jump)
        #expect(changes[0].label() == "title ↓7.5 pt")
        #expect(abs(clip.activity(k) - 7.5) < 0.01)
        #expect(clip.activity(k + 1) == 0.0, "nothing moves after")
        let path = clip.path(id: changes[0].id, range: 0..<clip.len)
        #expect(path.first?.snapshot.rect.top == 0.0)
        #expect(path.last?.snapshot.rect.top == 7.5)
    }

    // 7. a_one_frame_blip_out_and_back_is_a_jump
    @Test func aOneFrameBlipOutAndBackIsAJump() {
        let rt = makeApp()
        record(rt)
        stepFrames(rt, 10)
        jump(rt, y: 9.0)
        _ = rt.frame(at: rt.currentTime + 1.0 / 60.0)
        jump(rt, y: 0.0)
        stepFrames(rt, 10)
        let clip = rt.state.rewind.freeze()
        let jumps = (0..<clip.len).filter { clip.hasJump($0) }
        #expect(jumps.count == 1, "only the frame it went out in: \(jumps)")
        #expect(clip.changes(jumps[0])[0].label() == "title ↓9.0 pt")
    }

    // 8. smooth_motion_is_not_a_jump
    @Test func smoothMotionIsNotAJump() {
        let rt = makeApp()
        record(rt)
        for k in 1...30 {
            jump(rt, y: Float(k) * 3.0)
            _ = rt.frame(at: rt.currentTime + 1.0 / 60.0)
        }
        let clip = rt.state.rewind.freeze()
        #expect((0..<clip.len).allSatisfy { !clip.hasJump($0) })
        #expect((0..<clip.len).filter { clip.activity($0) > 0.0 }.count >= 29)
    }

    // 9. freezing_pauses_recording_and_the_keys_step_select_and_resume
    @Test func freezingPausesRecordingAndTheKeysStepSelectAndResume() {
        let rt = makeApp()
        record(rt)
        stepFrames(rt, 10)
        jump(rt, y: 20.0)
        stepFrames(rt, 10)
        let rewind = rt.state.rewind
        rt.state.scrub.open(rewind)
        let scrub = rt.state.scrub
        #expect(scrub.isOpen && rewind.isPaused)
        let held = rewind.frameCount
        let clip = scrub.clip!
        let k = scrub.currentFrameIndex
        #expect(clip.hasJump(k))
        #expect(scrub.key(keyPress(.arrowLeft)) == .handled)
        #expect(scrub.currentFrameIndex == k - 1)
        _ = scrub.key(keyPress(.arrowRight, shift: true))
        _ = scrub.key(keyPress(.arrowRight, shift: true))
        #expect(scrub.selection == (k - 1)..<(k + 2))
        guard case .send(let sent) = scrub.key(keyPress(.enter)) else {
            Issue.record("Return sends")
            return
        }
        #expect(sent.frames == (k - 1)..<(k + 2))
        stepFrames(rt, 5)
        #expect(rewind.frameCount == held, "nothing records while frozen")
        #expect(rt.state.scrub.key(keyPress(.escape)) == .closed)
        #expect(!rt.state.scrub.isOpen && !rewind.isPaused)
        stepFrames(rt, 5)
        #expect(rewind.frameCount == held + 5)
    }

    // 10. the_scrubber_draws_the_moved_element_and_sends_from_its_button
    @Test func theScrubberDrawsTheMovedElementAndSendsFromItsButton() {
        let rt = makeApp()
        record(rt)
        stepFrames(rt, 5)
        jump(rt, y: 30.0)
        stepFrames(rt, 5)
        rt.update { s, _ in
            s.scrub.open(s.rewind)
            s.scrub.setNote("title jumps")
        }
        _ = rt.frame(at: rt.currentTime + 1.0 / 60.0)
        let id = rt.state.scrub.clip!.changes(rt.state.scrub.currentFrameIndex)[0].id
        #expect(rt.element(byKey: "rewind-box-\(id)")?.rect == [10.0, 30.0, 100.0, 20.0])
        #expect(rt.element(byKey: "rewind-was-\(id)")?.rect == [10.0, 0.0, 100.0, 20.0])
        #expect(rt.lastElements.contains { ($0.key ?? "").hasPrefix("rewind-bin-") }, "the track lights up")
        let sendRect = rt.element(byKey: "rewind-send")!.rect
        let x = sendRect[0] + sendRect[2] * 0.5
        let y = sendRect[1] + sendRect[3] * 0.5
        rt.pointerDown(at: Vec2(x, y), at: rt.currentTime + 1.0 / 120.0)
        rt.pointerUp(at: Vec2(x, y), at: rt.currentTime + 1.0 / 60.0)
        _ = rt.frame(at: rt.currentTime + 1.0 / 60.0)
        #expect(rt.state.sent.count == 1)
        #expect(rt.state.sent[0].note == "title jumps")
    }

    // 11. a_scrubber_on_an_inset_stage_still_outlines_where_the_window_drew
    @Test func aScrubberOnAnInsetStageStillOutlinesWhereTheWindowDrew() {
        let rt = makeApp()
        rt.update { s, tx in
            s.inset = 50.0
            tx.settle()
        }
        record(rt)
        stepFrames(rt, 5)
        jump(rt, y: 30.0)
        stepFrames(rt, 5)
        rt.update { s, _ in s.scrub.open(s.rewind) }
        stepFrames(rt, 2)
        let id = rt.state.scrub.clip!.changes(rt.state.scrub.currentFrameIndex)[0].id
        let rect = rt.element(byKey: "rewind-box-\(id)")?.rect
        #expect(rect == [10.0, 30.0, 100.0, 20.0])
        let bar = rt.element(byKey: "rewind-bar")?.rect
        #expect(bar.map { $0[0] >= 50.0 } ?? true, "the bar stays on the stage")
    }

    // 12. a_bundle_holds_a_trace_a_contact_sheet_and_a_summary
    @Test func aBundleHoldsATraceAContactSheetAndASummary() throws {
        let rt = makeApp()
        record(rt)
        stepFrames(rt, 10)
        jump(rt, y: 7.5)
        stepFrames(rt, 10)
        let clip = rt.state.rewind.freeze()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-rewind-full-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try clip.writeBundle(to: dir, range: 0..<clip.len, note: "the title hops")
        let trace = try String(contentsOf: dir.appendingPathComponent("trace.jsonl"), encoding: .utf8)
        let lines = trace.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.first?.contains("\"type\":\"header\"") == true)
        let first = lines.dropFirst().first ?? ""
        #expect(first.contains("\"nm\":\"title\"") && first.contains("\"nm\":\"still\""))
        #expect(lines.count == clip.len + 1)
        #expect(trace.contains(",10,7.5,100,20,1,0,0]"))
        let png = try Data(contentsOf: dir.appendingPathComponent("contact.png"))
        #expect(Array(png[1..<4]) == [0x50, 0x4E, 0x47])
        let summary = try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(summary == bundle.summary)
        #expect(summary.contains("> the title hops"))
        #expect(summary.contains("## Jumps") && summary.contains("title ↓7.5 pt"))
    }

    @Test("A selected bundle replays distinct nodes that share a trace name")
    func bundlePreservesDuplicateTraceNames() throws {
        let recorder = Rewind()
        recorder.setViewport(Vec2(320, 120))
        func mark(_ node: UInt64, at x: Float) -> RewindElementSnapshot {
            RewindElementSnapshot(key: "same", rect: .fromXYWH(x, 10, 12, 10), opacity: 1, nodeID: node)
        }
        recorder.recordFrame(at: 0, elements: [mark(91, at: 10), mark(42, at: 50)])
        recorder.recordFrame(at: 0.02, elements: [mark(42, at: 50), mark(91, at: 20)])
        recorder.recordFrame(at: 0.04, elements: [mark(42, at: 60)])
        recorder.recordFrame(at: 0.14, elements: [mark(91, at: 30), mark(42, at: 60)])
        recorder.recordFrame(at: 0.16, elements: [mark(91, at: 30), mark(42, at: 60)])

        let clip = try RewindClip.importJSON(recorder.freeze().exportJSON())
        let scrub = Scrub()
        scrub.show(clip)
        scrub.selectionStartFrame = 1
        scrub.selectionEndFrame = 3
        scrub.setNote("two labels")
        let sent = try #require(scrub.sent())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rune-rewind-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try sent.write(to: dir)

        let trace = try String(contentsOf: dir.appendingPathComponent("trace.jsonl"), encoding: .utf8)
        let lines = try trace.split(separator: "\n").map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        #expect(lines.count == 4)
        let header = try #require(lines.first)
        #expect(header["hz"] as? Double == 50)
        let frame = try #require(lines.dropFirst().first)
        let meta = try #require(frame["m"] as? [[String: Any]])
        #expect(meta.compactMap { $0["id"] as? Int } == [1, 2])
        #expect(meta.compactMap { $0["nm"] as? String } == ["same", "same"])
        #expect(frame["e"] as? [[Int]] == [[1,20,10,12,10,1,0,0], [2,50,10,12,10,1,0,0]])
        let moved = try #require(lines.dropFirst(2).first)
        #expect(moved["e"] as? [[Int]] == [[2,60,10,12,10,1,0,0]])
        #expect(moved["g"] as? [Int] == [1])
        let returned = try #require(lines.dropFirst(3).first)
        #expect(returned["e"] as? [[Int]] == [[1,30,10,12,10,1,0,0]])
        #expect(returned["m"] == nil)
        #expect(bundle.summary.contains("same →10 pt at frame 1 (changed in 3 frames)"))
        #expect(bundle.summary.contains("same →10 pt at frame 2 (changed in 1 frames)"))

        // RGBA produced by pinned Rust's rewind/bundle.rs for these five tape frames and this selection.
        let png = try PortablePNG.decode(Data(contentsOf: dir.appendingPathComponent("contact.png")))
        let hash = png.rgba.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        #expect(hash == 0x3c9148002e89f7ad)
    }

    // 13. opening_over_an_open_scrubber_resumes_the_recorder_it_froze
    @Test func openingOverAnOpenScrubberResumesTheRecorderItFroze() {
        let first = Rewind()
        let second = Rewind()
        let scrub = Scrub()
        scrub.open(first)
        scrub.open(second)
        #expect(!first.isPaused, "the first recorder records again")
        #expect(second.isPaused)
        scrub.show(first.freeze())
        first.resume()
        #expect(second.isPaused, "a story over it keeps it frozen")
        scrub.close()
        #expect(!scrub.isOpen && !second.isPaused)
        // Reopening the same recorder leaves it frozen.
        scrub.open(first)
        scrub.open(first)
        #expect(first.isPaused)
        scrub.close()
        #expect(!first.isPaused)
    }
}
