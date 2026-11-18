import Testing
@testable import Rune
import RuneRef

@Suite struct WebAtlasLifetimeTests {
    @Test func pagedHistoryReleasesRawTexelsAndKeepsIndependentFramesValid() throws {
        let atlas = GlyphAtlas(width: 18, height: 6)
        func append(_ width: Int, byte: UInt8) throws -> UInt16 {
            try #require(atlas.placeMask(width: width, height: 4,
                                         bitmap: Array(repeating: byte, count: width * 4))).page
        }
        func frame() -> RenderFrame {
            let pages = atlas.framePages()
            var scene = RenderFrame(width: 100, height: 50, glyphs: pages.bases[0],
                                    glyphPages: pages.bases, glyphGeneration: pages.generation)
            scene.glyphPageFills = pages.fills
            scene.glyphPageRevisions = pages.revisions
            scene.glyphPagePatches = pages.patches
            scene.rawGlyphPageRevisions = pages.rawRevisions
            scene.rawGlyphPagePatches = pages.rawPatches
            return scene
        }
        func address() throws -> UInt {
            let texels = try #require(atlas.pageData(1))
            return texels.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        }
        var history = WebAtlasHistory()
        func publish() {
            let scene = frame()
            history.record(scene, history.prepare(scene, force: false, patches: true))
        }
        #expect(try append(16, byte: 61) == 0)
        #expect(try append(2, byte: 97) == 1)
        publish()
        let residentAddress = try address()
        #expect(try append(2, byte: 117) == 1)
        #expect(try address() == residentAddress)
        let retained = frame()
        let savedTexels = retained.glyphPages[1].texels
        let dirty = history.prepare(retained, force: false, patches: true)
        #expect(dirty.glyphs?.updates == [.none, .patch(SIMD4(3, 0, 7, 6))])
        history.record(retained, dirty)
        #expect(try append(2, byte: 161) == 1)
        _ = frame()
        #expect(try append(1, byte: 183) == 1)
        let latest = frame()
        let missed = history.prepare(latest, force: false, patches: true)
        #expect(missed.glyphs?.updates[1] == .full)
        #expect(history.prepare(latest, force: false, patches: true).sequence == missed.sequence)
        #expect(retained.glyphPages[1].texels == savedTexels)
        #expect(atlas.pageData(1) != savedTexels)
        history.record(latest, missed)
        var edited = latest
        edited.glyphPages[1].texels[6] = 7
        let publicEdit = history.prepare(edited, force: false, patches: true)
        #expect(publicEdit.glyphs?.updates[1] == .full)
        #expect(publicEdit.glyphs?.pages[1].texels[6] == 7)
    }

    @Test func pagedOutlineMasksSurviveRepeatedForcedUploads() throws {
        let store = OutlineStore()
        let found = store.glyph(.init(font: 1, glyph: 1)) {
            OutlineBuilder.build(commands: [.moveTo(.zero), .lineTo(SIMD2(4, 0)),
                                            .lineTo(SIMD2(4, 4)), .lineTo(SIMD2(0, 4)), .close], upem: 4)
        }
        guard case let .outline(record) = found else { Issue.record("Fixture produced no outline"); return }
        let base = R8Atlas(width: 8, height: 8, texels: [UInt8](repeating: 85, count: 64))
        let job = QueuedOutlineFill(rect: SIMD4(1, 1, 5, 5),
                                    fill: .init(record: record.record, scale: 1, pen: SIMD2(0, 4)))
        let plan = OutlineMaskPlan(base: base, curves: try #require(store.snapshot()), fills: [job],
                                   baseGeneration: 7, epoch: 0)
        var scene = RenderFrame(width: 10, height: 10, glyphs: base, glyphPages: [base, base])
        scene.glyphPageRevisions = [6, 8]
        scene.rawGlyphPageRevisions = [6, 7]
        scene.glyphPageFills = [nil, plan]
        var history = WebAtlasHistory()
        let first = history.prepare(scene, force: false, patches: true)
        let pixels = try #require(first.glyphs?.pages[1].texels)
        #expect(pixels != base.texels && pixels == plan.cpuAtlas().texels)
        history.record(scene, first)
        scene.glyphPageFills = [nil, nil]
        for _ in 0..<2 {
            let restore = history.prepare(scene, force: true, patches: true)
            #expect(restore.glyphs?.updates == [.full, .full])
            #expect(restore.glyphs?.pages[1].texels == pixels)
            history.record(scene, restore)
        }
    }

    @Test func recyclingRawAndDeferredShelvesPreservesTheirDistinctPixelChanges() throws {
        let atlas = GlyphAtlas(width: 18, height: 8)
        let bitmap = [UInt8](repeating: 50, count: 12)
        _ = try #require(atlas.placeMask(width: 3, height: 4, bitmap: bitmap))
        let first = atlas.framePages()
        atlas.evictPage(0)
        #expect(atlas.framePages().revisions == first.revisions)
        _ = try #require(atlas.placeMask(width: 2, height: 3, bitmap: [UInt8](repeating: 200, count: 6)))
        let rewritten = atlas.framePages()
        #expect(rewritten.patches[0]?.fromRevision == first.revisions[0])
        #expect(rewritten.patches[0]?.edges == SIMD4(0, 0, 4, 5))
        #expect(rewritten.bases[0].texels != first.bases[0].texels)

        atlas.defersOutlineMasks = true
        let glyph = atlas.withOutlineStore { store in
            store.glyph(.init(font: 1, glyph: 1)) {
                OutlineBuilder.build(commands: [.moveTo(.zero), .lineTo(SIMD2(3, 0)),
                                                .lineTo(SIMD2(0, 3)), .close], upem: 3)
            }
        }
        guard case let .outline(record) = glyph else { Issue.record("Fixture produced no outline"); return }
        _ = try #require(atlas.placeOutlineMask(width: 4, height: 4,
                                                fill: .init(record: record.record, scale: 1, pen: SIMD2(0, 3))))
        let outlined = atlas.framePages()
        let filled = try #require(outlined.fills.first ?? nil).cpuAtlas()
        #expect(filled.texels != outlined.bases[0].texels)
        atlas.evictPage(0)
        let cleared = atlas.framePages()
        #expect(cleared.revisions[0] != outlined.revisions[0])
        #expect(cleared.patches[0] == nil)
        #expect(cleared.bases[0].texels == outlined.bases[0].texels)
        #expect(cleared.fills.isEmpty)
    }
}
