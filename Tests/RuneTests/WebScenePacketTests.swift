import Foundation
import Testing
import RuneRef
@testable import Rune

@Suite struct WebScenePacketTests {
    @Test func headerInstancesAndAtlasesMatchTheWebGLWireFormat() throws {
        let primitive = RenderInstance(rect: SIMD4(2, 3, 4, 5), fill: SIMD4(1, 0, 0, 1),
                                       clip: SIMD4(0, 0, 8, 9), fade: SIMD4(1, 2, 3, 0xAA551199))
        let scene = RenderFrame(width: 8, height: 9, srgbBlend: true, clearColor: SIMD4(0.1, 0.2, 0.3, 0.5),
                             glyphs: R8Atlas(width: 1, height: 2, texels: [11, 22]),
                             images: RGBA8Atlas(texels: [33, 44, 55, 66]), instances: [primitive])
        for full in [true, false] {
            let encoded = try WebScenePacket(scene: scene, sendGlyphs: full, sendImages: full)
            let packet = try #require(encoded)
            #expect(packet.byteCount == 56 + 128 + (full ? 6 : 0))
            let data = UnsafeMutableRawBufferPointer.allocate(byteCount: packet.byteCount, alignment: 4)
            defer { data.deallocate() }
            packet.write(to: data.baseAddress!)
            #expect(data.load(as: UInt32.self) == 0x32475352)
            #expect(data.load(fromByteOffset: 12, as: UInt32.self) == (full ? 7 : 1))
            #expect(data.load(fromByteOffset: 48, as: Float.self) == 0.5)
            #expect(data.load(fromByteOffset: 56, as: Float.self) == 2)
            #expect(data.load(fromByteOffset: 56 + 31 * 4, as: UInt32.self) == 0xAA551199)
            if full { #expect(Array(data.suffix(6)) == [11, 22, 33, 44, 55, 66]) }
        }
    }

    @Test func patchPacketCarriesOnlyChangedRowsAndPreservesUnalignedImageHeader() throws {
        let glyph = Array(UInt8(0)..<32)
        let image = Array(UInt8(0)..<128)
        let scene = RenderFrame(width: 8, height: 4, glyphs: R8Atlas(width: 8, height: 4, texels: glyph),
                                images: RGBA8Atlas(width: 8, height: 4, texels: image))
        let encoded = try WebScenePacket(scene: scene, glyphUpdate: .patch(SIMD4(1, 0, 2, 3)),
                                         imageUpdate: .patch(SIMD4(2, 1, 4, 3)), sequence: SIMD2(3, 4))
        let packet = try #require(encoded)
        #expect(packet.byteCount == 56 + 8 + 16 + 3 + 16 + 16)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: packet.byteCount, alignment: 4)
        defer { buffer.deallocate() }
        packet.write(to: buffer.baseAddress!)
        #expect(buffer.load(fromByteOffset: 12, as: UInt32.self) & 62 == 56)
        #expect(buffer.load(fromByteOffset: 56, as: UInt32.self) == 3)
        #expect(buffer.load(fromByteOffset: 60, as: UInt32.self) == 4)
        #expect(Array(buffer[80..<83]) == [1, 9, 17])
        #expect(buffer.loadUnaligned(fromByteOffset: 83, as: UInt32.self) == 2)
        #expect(buffer.loadUnaligned(fromByteOffset: 95, as: UInt32.self) == 2)
        #expect(Array(buffer.suffix(16)) == Array(image[40..<48]) + Array(image[72..<80]))
    }

    @Test func independentPagesKeepOriginalUVsAndSendOnlyDirtyTexels() throws {
        let dims = 16
        let first = RGBA8Atlas(width: dims, height: dims, texels: [UInt8](repeating: 41, count: 4 * dims * dims))
        var changed = first
        let start = (3 * dims + 2) * 4
        changed.texels.replaceSubrange(start..<start + 4, with: [11, 22, 33, 44])
        var vacant = RGBA8Atlas()
        vacant.texels = []
        let quad = RenderInstance(params: SIMD4(1, KIND_IMAGE, 0, 1), uv: SIMD4(2, 3, 1, 1))
        var scene = RenderFrame(width: 10, height: 7, glyphs: R8Atlas(texels: [127]),
                                imagePages: [first, changed, vacant], instances: [quad])
        scene.imagePageRevisions = [7, 9, 10]
        scene.imagePagePatches = [nil, ImageAtlasPatch(fromRevision: 8, edges: SIMD4(2, 3, 3, 4)), nil]
        try scene.validateForGL()
        let updates = WebAtlasUpdate.imagePages(scene, previous: [first, first, vacant], revisions: [7, 8, 10], force: false)
        #expect(updates == [.none, .patch(SIMD4(2, 3, 3, 4)), .none])
        #expect(WebAtlasUpdate.imagePages(scene, previous: [], revisions: [], force: true) == [.full, .full, .none])
        let encoded = try WebScenePacket(scene: scene, glyphUpdate: .full, imageUpdate: .none,
                                         sequence: SIMD2(10, 11), pageUpdates: updates)
        let packet = try #require(encoded)
        #expect(packet.byteCount == 56 + 128 + 8 + 1 + 3 * 12 + 16 + 4)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: packet.byteCount, alignment: 4)
        defer { buffer.deallocate() }
        packet.write(to: buffer.baseAddress!)
        func word(_ offset: Int) -> UInt32 { buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        #expect(word(0) == WebScenePacket.pagedMagic && word(28) == 3 && word(32) == 0)
        #expect(word(56 + 16 * 4) == Float(1).bitPattern && word(56 + 20 * 4) == Float(2).bitPattern)
        let descriptors = 56 + 128 + 8 + 1
        #expect(word(descriptors) == 16 && word(descriptors + 8) == 0)
        #expect(word(descriptors + 20) == 2 && word(descriptors + 24) == 2 && word(descriptors + 28) == 3)
        #expect(Array(buffer[(descriptors + 40)..<(descriptors + 44)]) == [11, 22, 33, 44])
        #expect(Array(buffer.suffix(12)) == [UInt8](repeating: 0, count: 12))
    }

    @Test func pagedGlyphsEncodeLocalUVsAndSparseR8UpdatesWithALegacyImage() throws {
        let base = R8Atlas(width: 8, height: 4, texels: [UInt8](repeating: 0, count: 32))
        var page = base
        page.texels[9] = 31
        page.texels[17] = 63
        let empty = R8Atlas(texels: [])
        let glyph = RenderInstance(params: SIMD4(0, KIND_GLYPH, 1, 1), uv: SIMD4(1, 1, 1, 2))
        let image = RGBA8Atlas(texels: [91, 92, 93, 94])
        var scene = RenderFrame(width: 8, height: 4, glyphs: base, images: image, instances: [glyph])
        scene.glyphPages = [base, page, empty]
        scene.glyphPageRevisions = [4, 7, 8]
        scene.glyphPagePatches = [nil, GlyphAtlasPatch(fromRevision: 5, edges: SIMD4(1, 1, 2, 3)), nil]
        let previous = [base, base, empty]
        let updates = WebAtlasUpdate.glyphPages(scene.glyphPages, frame: scene, previous: previous, revisions: [4, 5, 8], force: false)
        #expect(updates == [.none, .patch(SIMD4(1, 1, 2, 3)), .none])
        #expect(WebAtlasUpdate.glyphPages(scene.glyphPages, frame: scene, previous: previous, revisions: [4, 5, 8], force: true) == [.full, .full, .none])
        #expect(WebAtlasUpdate.slotsChanged([base, page, empty], since: [base, page, base]))
        #expect(WebAtlasUpdate.imagePages(scene, previous: [image], revisions: [scene.imageRevision], force: false) == [.none])
        let encoded = try WebScenePacket(scene: scene, glyphUpdate: .none, imageUpdate: .none, sequence: SIMD2(10, 11),
                                         pageUpdates: [.full], glyphTransfers: (scene.glyphPages, updates))
        let packet = try #require(encoded)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: packet.byteCount, alignment: 4)
        defer { buffer.deallocate() }
        packet.write(to: buffer.baseAddress!)
        func word(_ offset: Int) -> UInt32 { buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        #expect(word(0) == WebScenePacket.pagedMagic && word(12) == 160)
        #expect(word(20) == 3 && word(24) == 0 && word(28) == 1 && word(32) == 0)
        #expect(word(56 + 18 * 4) == Float(1).bitPattern && word(56 + 20 * 4) == Float(1).bitPattern)
        let start = 56 + 128 + 8
        #expect(word(start) == 8 && word(start + 4) == 4 && word(start + 8) == 0)
        #expect(word(start + 20) == 2 && word(start + 24) == 1 && word(start + 36) == 2)
        #expect(Array(buffer[(start + 40)..<(start + 42)]) == [31, 63])
        #expect(Array(buffer[(start + 42)..<(start + 54)]) == [UInt8](repeating: 0, count: 12))
        #expect(word(start + 54) == 1 && word(start + 58) == 1 && word(start + 62) == 1)
        #expect(Array(buffer.suffix(4)) == image.texels)
        #expect(packet.byteCount == start + 70)
    }

    @Test func glyphPageHistoryKeepsTexturesAcrossRetriesUntilTheirPacketIsPublished() throws {
        let base = R8Atlas(width: 10, height: 8)
        var scene = RenderFrame(width: 32, height: 16, glyphs: base)
        var history = WebAtlasHistory()

        let legacy = history.prepare(scene, force: false, patches: false)
        #expect(legacy.glyph == .full && legacy.image == .full && legacy.sequence == nil)
        history.record(scene, legacy)
        let upgrade = history.prepare(scene, force: false, patches: true)
        #expect(upgrade.glyph == .full && upgrade.image == .full && upgrade.sequence == SIMD2(0, 1))
        history.record(scene, upgrade)
        let still = history.prepare(scene, force: false, patches: true)
        #expect(still.glyph == .none && still.image == .none && still.sequence == SIMD2(1, 1))

        scene.glyphPages = [base, base]
        scene.glyphPageRevisions = [10, 11]
        let paged = history.prepare(scene, force: false, patches: true)
        #expect(paged.glyphs?.updates == [.full, .full] && paged.images == [.full])
        #expect(paged.glyph == .none && paged.image == .none && paged.sequence == SIMD2(1, 2))
        #expect(history.prepare(scene, force: false, patches: true).sequence == paged.sequence)
        history.record(scene, paged)

        scene.glyphPages[1].texels[13] = 177
        scene.glyphPageRevisions = [10, 12]
        scene.glyphPagePatches = [nil, .init(fromRevision: 11, edges: SIMD4(3, 1, 4, 2))]
        let updated = history.prepare(scene, force: false, patches: true)
        #expect(updated.glyphs?.updates == [.none, .patch(SIMD4(3, 1, 4, 2))])
        #expect(updated.images == [.none] && updated.sequence == SIMD2(2, 3))
        history.record(scene, updated)
        #expect(history.prepare(scene, force: false, patches: true).sequence == SIMD2(3, 3))
        let restored = history.prepare(scene, force: true, patches: true)
        #expect(restored.glyphs?.updates == [.full, .full] && restored.images == [.full])

        scene.glyphPages[1] = R8Atlas(texels: [])
        let vacated = history.prepare(scene, force: false, patches: true)
        #expect(vacated.glyphs?.updates == [.none, .none] && vacated.sequence == SIMD2(3, 4))
        history.record(scene, vacated)
        scene.glyphPages = []
        let single = history.prepare(scene, force: false, patches: true)
        #expect(single.glyphs == nil && single.images == nil)
        #expect(single.glyph == .full && single.image == .full && single.sequence == SIMD2(4, 5))
    }

    @Test func glyphSnapshotGrowsAtTheFilteringGutterAndRestoresAfterMissedUpdates() throws {
        let width = 6, height = 700
        let atlas = GlyphAtlas(width: width, height: height)
        func frame() -> RenderFrame {
            let pages = atlas.framePages()
            var scene = RenderFrame(width: 16, height: 16, glyphs: pages.bases[0],
                                    glyphPages: pages.bases.count > 1 ? pages.bases : [],
                                    glyphGeneration: pages.generation)
            scene.baseGlyphUsedRows = pages.baseUsedRows
            scene.glyphPageRevisions = pages.revisions
            scene.glyphPagePatches = pages.patches
            return scene
        }
        func wire(_ scene: RenderFrame, _ transfer: WebAtlasTransfer) throws -> [UInt8] {
            let encoded = try WebScenePacket(scene: scene, glyphUpdate: transfer.glyph, imageUpdate: transfer.image,
                                             sequence: transfer.sequence, pageUpdates: transfer.images, glyphTransfers: transfer.glyphs)
            let packet = try #require(encoded)
            var bytes = [UInt8](repeating: 0, count: packet.byteCount)
            bytes.withUnsafeMutableBytes { packet.write(to: $0.baseAddress!) }
            return bytes
        }
        func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }

        var history = WebAtlasHistory()
        _ = try #require(atlas.placeMask(width: 2, height: 254, bitmap: Array(repeating: 127, count: 2 * 254)))
        let first = frame(), start = WebScenePacket.headerSize + 8
        let initial = history.prepare(first, force: false, patches: true)
        let bytes = try wire(first, initial)
        #expect(first.baseGlyphUsedRows == 256 && word(bytes, 24) == 256)
        #expect(initial.glyph == .full && initial.image == .full)
        #expect(bytes.count == start + width * 256 + 4)
        #expect(Array(bytes[start..<(start + width * 256)]) == Array(first.glyphs.texels.prefix(width * 256)))
        #expect(bytes[start + 254 * width + 1] == 127 && bytes[start + 255 * width + 1] == 0)
        history.record(first, initial)

        _ = try #require(atlas.placeMask(width: 1, height: 255, bitmap: Array(repeating: 212, count: 255)))
        let grown = frame()
        let resize = history.prepare(grown, force: false, patches: true)
        let resized = try wire(grown, resize)
        #expect(grown.baseGlyphUsedRows == 257 && word(resized, 24) == 512)
        #expect(resize.glyph == .full && resize.image == .none)
        #expect(Array(resized.dropFirst(start)) == Array(grown.glyphs.texels.prefix(width * 512)))
        history.record(grown, resize)

        // The consumer missed the resize. Its forced recovery must be self-contained.
        let restore = history.prepare(grown, force: true, patches: true)
        let restored = try wire(grown, restore)
        #expect(restore.sequence?.x != initial.sequence?.y)
        #expect(restore.glyph == .full && restore.image == .full && word(restored, 24) == 512)
        #expect(Array(restored.dropFirst(start)) == Array(resized.dropFirst(start)) + grown.images.texels)
        history.record(grown, restore)

        var edited = grown
        edited.glyphs.texels[(height - 1) * width] = 233
        let changed = history.prepare(edited, force: false, patches: true)
        let editedBytes = try wire(edited, changed)
        #expect(edited.baseGlyphUsedRows == nil && word(editedBytes, 24) == UInt32(height))
        #expect(changed.glyph == .full && editedBytes[start + (height - 1) * width] == 233)

        let overflow = try #require(atlas.placeMask(width: 4, height: 698, bitmap: Array(repeating: 89, count: 4 * 698)))
        #expect(overflow.page == 1)
        let paged = frame()
        let bank = history.prepare(paged, force: false, patches: true)
        let pagedBytes = try wire(paged, bank)
        #expect(bank.glyphs?.updates == [.full, .full])
        #expect(word(pagedBytes, 0) == WebScenePacket.pagedMagic && word(pagedBytes, 20) == 2)
        #expect(word(pagedBytes, start + 4) == UInt32(height))
        #expect(word(pagedBytes, start + 12 + width * height + 4) == UInt32(height))
    }

    @Test func singlePageReceiptsKeepResidentPixelsAcrossSkippedFramesAndPublicEdits() {
        let width = 12, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height), resident = pixels
        var history = WebAtlasHistory()
        func send(_ revision: UInt64?, from: UInt64? = nil, edges: SIMD4<Int> = .zero,
                  force: Bool = false, deferred: Bool = false, expecting: WebAtlasUpdate) {
            var scene = RenderFrame(width: 16, height: 16, glyphs: R8Atlas(width: width, height: height, texels: pixels),
                                    glyphGeneration: 1)
            if let revision {
                scene.glyphPageRevisions = [revision]
                scene.rawGlyphPageRevisions = [revision]
                scene.rawGlyphPagePatches = [from.map { GlyphAtlasPatch(fromRevision: $0, edges: edges) }]
            }
            if deferred {
                let curves = RenderOutlineAtlas(storeID: UUID(), generation: 1, texels: [], usedTexels: 0, requestsLCD: false)
                scene.maskFills = OutlineMaskPlan(base: scene.glyphs, curves: curves, fills: [], baseGeneration: 1, epoch: 0)
            }
            let transfer = history.prepare(scene, force: force, patches: true)
            #expect(transfer.glyph == expecting)
            switch transfer.glyph {
            case .full: resident = pixels
            case .patch(let r):
                for y in r.y..<r.w {
                    let range = (y * width + r.x)..<(y * width + r.z)
                    resident.replaceSubrange(range, with: pixels[range])
                }
            case .none: break
            }
            #expect(resident == pixels)
            history.record(scene, transfer)
        }
        let area = SIMD4(2, 1, 5, 2)
        send(1, expecting: .full)
        pixels[width + 2] = 11
        send(2, from: 1, edges: area, expecting: .patch(area))
        send(2, expecting: .none)
        pixels[2 * width + 3] = 42
        pixels[3 * width + 5] = 53
        send(4, from: 3, edges: SIMD4(5, 3, 6, 4), expecting: .full)
        send(4, force: true, expecting: .full)
        pixels[width + 2] = 0
        send(5, expecting: .full) // Recycled shelves drop their old ancestry.
        pixels[0] = 60
        send(nil, expecting: .full)
        pixels[width + 8] = 70
        send(nil, expecting: .patch(SIMD4(8, 1, 9, 2)))
        send(nil, expecting: .none)
        pixels[width + 8] = 0
        send(6, from: 5, edges: area, expecting: .full)
        pixels[0] = 80
        send(6, deferred: true, expecting: .full)
        pixels[0] = 90
        send(6, deferred: true, expecting: .patch(SIMD4(0, 0, 1, 1)))
        send(6, expecting: .full)
    }

    @MainActor @Test func idleBrowserFramesServeScheduledHover() throws {
        struct Model { var entered = false }
        let spec = AppSpec(title: "Hover", size: Vec2(50, 50), state: Model()) { _, _ in
            el().size(50, 50).onHoverChange { model, inside, _ in model.entered = inside }
                .hoverDelays(enter: 0.2, leave: 0.1)
        }
        let host = WebAppHost(spec: spec)
        let session = WebBrowserSession(host)
        _ = try session.renderFrame(at: 0)
        _ = session.send(Data(#"{"kind":"pointermove","x":5,"y":5}"#.utf8), at: 1)
        _ = try session.renderFrame(at: 1)
        #expect(!host.runtime.state.entered)
        _ = try session.renderFrame(at: 1.21)
        #expect(host.runtime.state.entered)
    }

    @MainActor @Test func physicalKeyboardEdgesReachTheFocusedElement() throws {
        let spec = AppSpec(title: "Keyboard", size: Vec2(30, 30), state: [PhysicalInput]()) { _, _ in
            el().key("receiver").size(30, 30).focusable().autofocus()
                .onPhysicalInput { events, event, _ in events.append(event); return true }
        }
        let host = WebAppHost(spec: spec)
        let session = WebBrowserSession(host)
        _ = try session.renderFrame(at: 0)
        for (index, event) in [
            #"{"kind":"key","code":"KeyS","key":"o","shift":true}"#,
            #"{"kind":"key","code":"KeyS","key":"o","shift":true,"repeated":true}"#,
            #"{"kind":"keyup","code":"KeyS","key":"o","shift":true}"#,
            #"{"kind":"focuslost"}"#
        ].enumerated() {
            #expect(session.send(Data(event.utf8), at: Double(index) + 1))
        }
        let shift = Mods(shift: true)
        #expect(host.runtime.state == [
            .key(key: .keyS, mods: shift, pressed: true, repeat: false),
            .key(key: .keyS, mods: shift, pressed: true, repeat: true),
            .key(key: .keyS, mods: shift, pressed: false, repeat: false),
            .focusLost
        ])
    }

    @MainActor @Test func browserPreferencesAndScaleReachTheRuntime() {
        let spec = AppSpec(title: "Preferences", size: Vec2(200, 100), state: ()) { _, _ in el() }
        let host = WebAppHost(spec: spec)
        host.updatePreferences(dark: false, reducedMotion: true, increasedContrast: true, hover: false, coarse: true)
        #expect(!host.runtime.systemDark)
        #expect(host.runtime.reducedMotion)
        #expect(host.runtime.touchControls())
        // Changing DPR can preserve the physical surface size and still change its logical layout.
        #expect(host.resize(cssSize: (100, 50), reportedPixels: (200, 100), scale: 2))
        #expect(host.runtime.windowViewport() == Vec2(100, 50))
        #expect(host.runtime.windowScale() == 2)
        let fixed = WebAppHost(spec: spec, dark: false, forceReducedMotion: true)
        fixed.updatePreferences(dark: true, reducedMotion: false, increasedContrast: false, hover: true, coarse: false)
        #expect(!fixed.runtime.systemDark)
        #expect(fixed.runtime.reducedMotion)
    }

}
