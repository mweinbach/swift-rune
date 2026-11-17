#if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
import Foundation
import RuneRef
import RuneMotion
import Testing
@testable import Rune

@MainActor
@Suite("OpenGL native surface readback")
struct PortableGLSurfaceTests {
    @Test("Production runtime draws a native surface between its background, border and children")
    func productionFrame() throws {
        let surface = NativeSurface()
        let bytes = try ByteFrame(width: 1, height: 1, format: .rgba, color: .srgb, planes: [Data([255,0,0,255])])
        try surface.pushBytes(bytes, frameId: 5)
        let ui = Runtime(state: false, viewport: Vec2(20, 20), pixelScale: 1) { _, _ in
            nativeSurface(surface, .stretch).size(20, 20)
                .bg(Color(r: 0, g: 0, b: 1, a: 1))
                .border(2, Color(r: 0, g: 1, b: 0, a: 1))
                .child(el().size(6, 6).bg(Color(r: 1, g: 1, b: 1, a: 1)))
        }
        let frame = ui.renderFrame(at: 0)
        try #require(frame.surfaces.count == 1)
        try withTestGLTarget { renderer, target in
            let image = try target(20, 20) { try renderer.draw(frame) }
            #expect(image.pixel(x: 10, y: 10) == SIMD4(255,0,0,255))
            #expect(image.pixel(x: 19, y: 10) == SIMD4(0,255,0,255))
            #expect(image.pixel(x: 3, y: 3) == SIMD4(255,255,255,255))
        }
    }

    @Test("Surface keeps painter order inside a translucent layer, with mirrored BGRA and an atlas draw on top")
    func orderAndPlacement() throws {
        let surface = NativeSurface()
        let colors = Data([0, 0, 255, 255, 0, 255, 0, 255])
        try surface.pushBytes(ByteFrame(width: 2, height: 1, format: .bgra, color: .srgb, planes: [colors]), frameId: 7)
        surface.setMirrored(true)
        surface.setObserver { _ in }
        let rect = SIMD4<Float>(0, 0, 6, 6)
        let draw = SurfaceDraw(surface: surface.placed(SurfacePlace(anchor: (.center, .center), unscaled: true)),
                               fit: .fit, beforeInstance: 1, rect: rect, clip: rect)
        let scene = RefScene(width: 6, height: 6, srgbBlend: true, clearColor: SIMD4(0, 0, 0, 1),
                             images: RGBA8Atlas(texels: [0,0,255,255]), primitives: [
            .layerBegin(rect: rect, opacity: 0.5, clip: rect), .layerEnd(clip: rect),
            .image(rect: SIMD4(3, 3, 1, 1), uv: SIMD4(0, 0, 1, 1), clip: rect)
        ])
        try withTestGLTarget { renderer, target in
            let frame = try target(6, 6) { try renderer.draw(scene, surfaces: [draw]) }
            let capture = try NativeSurfaceReference.capture([draw], srgbBlend: scene.srgbBlend)
            let reference = try RuneRef.render(scene, surfaces: capture)
            let difference = RuneRef.compare(scene: scene, expected: reference, actual: frame, channelTolerance: 1)
            #expect(difference.passed)
            let green = frame.pixel(x: 2, y: 3)
            #expect(abs(Int(green.y) - 128) <= 1 && green.x == 0 && green.z == 0)
            #expect(frame.pixel(x: 3, y: 3) == SIMD4(0,0,255,255))
            #expect(frame.pixel(x: 2, y: 2) == SIMD4(0,0,0,255))
            #expect(surface.counts().0 == 1 && surface.counts().1 == 1)
            #expect(surface.timing()?.frameId == 7 && surface.timing()?.completedAt != nil)
        }
    }

    @Test("Both NV12 ranges use matrix and transfer metadata and replace texture bytes when frame IDs repeat")
    func nv12RevisionAndConversion() throws {
        let surface = NativeSurface()
        let bounds = SIMD4<Float>(0, 0, 2, 2)
        let draw = SurfaceDraw(surface: surface, fit: .stretch, beforeInstance: 0, rect: bounds, clip: bounds)
        let scene = RefScene(width: 2, height: 2)
        try withTestGLTarget { renderer, target in
            for (format, matrix, transfer) in [(SurfacePixelFormat.nv12Video, SurfaceMatrix.bt601, SurfaceTransfer.bt709), (.nv12Full, .bt709, .srgb)] {
                let bytes = try ByteFrame(width: 2, height: 2, format: format, color: SurfaceColorInfo(matrix: matrix, transfer: transfer),
                                          planes: [Data([100, 100, 100, 100]), Data([90, 180])])
                try surface.pushBytes(bytes, frameId: 1)
                let frame = try target(2, 2) { try renderer.draw(scene, surfaces: [draw]) }
                let capture = try NativeSurfaceReference.capture([draw], srgbBlend: scene.srgbBlend)
                let reference = try RuneRef.render(scene, surfaces: capture)
                let difference = RuneRef.compare(scene: scene, expected: reference, actual: frame, channelTolerance: 2)
                #expect(difference.passed)
                let expected = ByteFrame.nv12Reference(y: 100, cb: 90, cr: 180, fullRange: format == .nv12Full, matrix: matrix, transfer: transfer)
                let actual = frame.pixel(x: 1, y: 1)
                for channel in 0..<3 {
                    #expect(abs(Int(actual[channel]) - Int((RefShader.linearToSRGB(expected[channel]) * 255).rounded())) <= 2)
                }
            }
            surface.clear()
            let cleared = try target(2, 2) { try renderer.draw(scene, surfaces: [draw]) }
            #expect(cleared.pixel(x: 1, y: 1) == SIMD4(0,0,0,255))
        }
    }

    @Test("A scaled, rotated translucent surface matches the reference through soft and rounded clips")
    func maskedOrientedSurface() throws {
        let surface = NativeSurface()
        var colors = Data()
        for y in 0..<3 {
            for x in 0..<5 {
                colors.append(contentsOf: [UInt8(30 + 40 * x), UInt8(50 + 65 * y), 160, UInt8(70 + 20 * (x + y))])
            }
        }
        let source = try ByteFrame(width: 5, height: 3, format: .rgba, color: .srgb, planes: [colors])
        try surface.pushBytesOriented(source, orient: Orient(m00: 0, m01: 1, m10: -1, m11: 0), frameId: 1)
        let clip = SIMD4<Float>(3, 1, 11, 8)
        var edges = packFade(width: SIMD4(-3, 0, 2, 0), origin: SIMD4(2, 1, 11, 8), clip: clip)
        edges.w = packClipRadii(clip: clip, radii: SIMD4(2, -2, 2, 0))
        let draw = SurfaceDraw(surface: surface, fit: .stretch, beforeInstance: 0,
                               rect: SIMD4(2, 1, 9, 7), radii: SIMD4(0, 2, 2, 0), clip: clip,
                               fade: SIMD4(0, 1, 0.2, 0.25), fadeOrigin: SIMD2(0, 1), clipFade: edges)
        let scene = RefScene(width: 12, height: 9, srgbBlend: true, clearColor: SIMD4(0, 0, 0, 1))
        let capture = try NativeSurfaceReference.capture([draw], srgbBlend: scene.srgbBlend)
        let reference = try RuneRef.render(scene, surfaces: capture)
        #expect(reference.pixel(x: 6, y: 5).x > 10)
        try withTestGLTarget { renderer, target in
            let image = try target(12, 9) { try renderer.draw(scene, surfaces: [draw]) }
            let difference = RuneRef.compare(scene: scene, expected: reference, actual: image, channelTolerance: 2)
            #expect(difference.passed)
        }
    }

    @Test("An offset production layer preserves source UV and clip coordinates")
    func croppedLayer() throws {
        let surface = NativeSurface()
        let columns = Data([255,0,0,255, 0,255,0,255])
        try surface.pushBytes(ByteFrame(width: 2, height: 1, format: .rgba, color: .srgb, planes: [columns]), frameId: 1)
        let rect = SIMD4<Float>(19, 7, 2, 1)
        let clip = SIMD4<Float>(20, 7, 21, 8)
        let frame = RenderFrame(
            width: 32, height: 20, srgbBlend: true, clearColor: SIMD4(0,0,0,1),
            instances: [.beginLayer(bounds: rect, clip: NO_CLIP, spec: LayerSpec(opacity: 0.5)), .endLayer()],
            surfaces: [SurfaceDraw(surface: surface, fit: .stretch, beforeInstance: 1, rect: rect, clip: clip)]
        )
        try withTestGLTarget { renderer, target in
            let image = try target(32, 20) { try renderer.draw(frame) }
            #expect(image.pixel(x: 19, y: 7) == SIMD4(0,0,0,255))
            let green = image.pixel(x: 20, y: 7)
            #expect(green.x == 0 && abs(Int(green.y) - 128) <= 1 && green.z == 0)
        }
    }
}
#endif
