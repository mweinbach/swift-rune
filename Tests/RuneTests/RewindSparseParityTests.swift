import Foundation
import Testing
@testable import Rune
import RuneMotion

@Suite("Rewind sparse recording")
struct RewindSparseParityTests {
    @Test("Runtime recording keeps same-named nodes distinct", arguments: [false, true])
    func runtimeNodeIdentity(native: Bool) throws {
        let recorder = RewindRecorder()
        let rt = Runtime<Bool>(state: true, viewport: Vec2(120, 120), pixelScale: 1) { both, _ in
            var view: El<Bool> = col().size(100, 100).child(
                el().key("first").traceName("duplicate").size(15, 20)
            )
            if both { view = view.child(el().key("second").traceName("duplicate").size(30, 20)) }
            return view
        }
        rt.update { _, tx in tx.recordRewind(recorder) }
        if native { _ = rt.renderFrame(at: 0) } else { _ = rt.frame(at: 0) }
        rt.update { both, tx in
            both = false
            tx.settle()
        }
        if native { _ = rt.renderFrame(at: 1) } else { _ = rt.frame(at: 1) }

        let clip = recorder.freeze()
        let first = clip.frame(0)
        #expect(first.map { $0.snapshot.key } == ["duplicate", "duplicate"])
        #expect(Set(first.compactMap { $0.snapshot.nodeID }).count == 2)
        let second = try #require(first.first { $0.snapshot.rect.width == 30 })
        #expect(clip.frame(1).map(\.id) == first.filter { $0.id != second.id }.map(\.id))
        #expect(clip.changes(1).contains { $0.id == second.id && $0.toRect == nil })
        #expect(clip.path(id: second.id, range: 0..<2).map(\.frame) == [0])
    }

    @Test("Checkpoint boundaries, eviction, serialization and resume preserve identities")
    func checkpointsAndEviction() throws {
        let recorder = RewindRecorder(windowSeconds: 140)
        func shot(_ id: UInt64, _ x: Int) -> RewindElementSnapshot {
            RewindElementSnapshot(key: "row", rect: .fromXYWH(Float(x), 0, 8, 8), opacity: 1, nodeID: id)
        }
        func row(_ t: Int) -> [RewindElementSnapshot] {
            var result = [shot(7, t)]
            if !(125...150).contains(t) { result.append(shot(8, 400)) }
            return result
        }
        for t in 0...200 { recorder.recordFrame(at: Double(t), elements: row(t)) }
        let clip = recorder.freeze()
        let restored = try RewindClip.importJSON(clip.exportJSON())
        for c in [clip, restored] {
            #expect(c.len == 141)
            for index in [0, 1, 63, 64, 65, 90, 91, 127, 128, 140] {
                let frame = try #require(c.recordedFrame(index))
                #expect(frame.index == index + 60)
                #expect(frame.timeSeconds == Double(index + 60))
                #expect(frame.elements == row(index + 60))
            }
            let moving = try #require(c.frame(0).first { $0.snapshot.nodeID == 7 }?.id)
            let stationary = try #require(c.frame(0).first { $0.snapshot.nodeID == 8 }?.id)
            #expect(c.changes(0).first { $0.id == moving }?.fromRect?.x == 59)
            #expect(c.changes(65).contains { $0.id == stationary && $0.toRect == nil })
            #expect(c.changes(91).contains { $0.id == stationary && $0.fromRect == nil })
            #expect(c.path(id: stationary, range: 60..<95).map(\.frame) == Array(60..<65) + Array(91..<95))
        }
        recorder.resume()
        recorder.recordFrame(at: 500, elements: [shot(7, 500)])
        recorder.rest()
        #expect(recorder.freeze().recordedFrame(0)?.elements == [shot(7, 500)])
        #expect(clip.recordedFrame(140)?.elements == row(200))
    }

    @Test("Long static recordings keep only their deltas")
    func sparseExportAndLegacyDecode() throws {
        let recorder = RewindRecorder(windowSeconds: 300)
        let rows = (0..<256).map {
            RewindElementSnapshot(key: "row", rect: .fromXYWH(Float($0), 0, 5, 5),
                                  opacity: 1, nodeID: UInt64($0))
        }
        for t in 0..<192 { recorder.recordFrame(at: Double(t), elements: rows) }
        let clip = recorder.freeze()
        let data = try clip.exportJSON()
        #expect(data.count < 180_000)
        let decoded = try RewindClip.importJSON(data)
        #expect(decoded.recordedFrame(191)?.elements == rows)
        #expect(decoded.changes(128).isEmpty)

        let legacy = Data(#"{"frames":[{"index":32,"timeSeconds":1.25,"elements":[{"key":"historic","left":1.2345,"top":0,"right":10,"bottom":12,"opacity":0.3333}]}],"viewportWidth":100,"viewportHeight":90}"#.utf8)
        let old = try RewindClip.importJSON(legacy)
        let frame = try #require(old.recordedFrame(0))
        #expect(frame.index == 32)
        #expect(frame.elements[0].left == 1.2345)
        #expect(frame.elements[0].opacity == 0.3333)
        #expect(frame.elements[0].nodeID == nil)
        #expect(try RewindClip.importJSON(old.exportJSON()).frames == old.frames)
    }

    @Test("Closing a scrubber releases its frozen recorder after a different clip is shown")
    func closingResumesHeldRecorder() {
        let first = RewindRecorder()
        let second = RewindRecorder()
        let scrubber = RewindScrubber()
        scrubber.open(first)
        scrubber.show(second.freeze())
        #expect(first.isPaused && second.isPaused)
        scrubber.close(resuming: second)
        #expect(!first.isPaused && !second.isPaused)
    }
}
