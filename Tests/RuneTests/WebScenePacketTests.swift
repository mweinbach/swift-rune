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
