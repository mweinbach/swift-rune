import Foundation
import Testing
@testable import Rune

@Suite struct WebCPUCanvasTests {
    @Test func dirtyStripsRecolorResizeAndDeferNativeSurfaces() throws {
        let canvas = WebCPUCanvas()
        let pixelRect = RenderInstance(rect: SIMD4(12, 10, 8, 6), fill: SIMD4(1, 0, 0, 1),
                                       params: SIMD4(0, KIND_RECT, 0, 1), clip: NO_CLIP)
        var scene = RenderFrame(width: 320, height: 180, srgbBlend: true, instances: [pixelRect])
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: 65_536, alignment: 8)
        defer { bytes.deallocate() }
        func draw(_ force: Bool = false) throws {
            try canvas.paint(scene, smoothing: .classic, compositor: false, force: force)
        }
        func readRow(_ row: Int) -> [UInt8] {
            let length = canvas.copyRGBA(rect: 0, row: row, count: 1) { $0 <= 65_536 ? bytes : nil }
            return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: length))
        }
        try canvas.paint(scene, smoothing: .classic, compositor: false, force: false, fillNs: 12_500)
        #expect(canvas.rects == [[0, 0, 320, 180]])
        canvas.writeHeader(to: bytes)
        #expect(Double(bitPattern: UInt64(littleEndian: bytes.load(fromByteOffset: canvas.byteCount - 8, as: UInt64.self))) == 12.5)
        #expect(Array(readRow(12)[48..<52]) == [255, 0, 0, 255])
        #expect(canvas.copyRGBA(rect: 0, row: 0, count: 180) { _ in bytes } == 0)
        try draw()
        #expect(canvas.rects.isEmpty)
        scene.instances[0].fill = SIMD4(0, 0, 1, 1)
        try draw()
        #expect(canvas.rects == [[0, 0, 64, 32]])
        #expect(Array(readRow(12)[48..<52]) == [0, 0, 255, 255])
        scene.surfaces = [SurfaceDraw(surface: NativeSurface(), fit: .fit, beforeInstance: 0, rect: SIMD4(0, 0, 8, 8), clip: NO_CLIP)]
        try draw()
        canvas.writeHeader(to: bytes)
        #expect(bytes.load(fromByteOffset: 12, as: UInt32.self) == 1)
        #expect(canvas.rects.isEmpty)
        scene.surfaces = []
        try draw()
        #expect(canvas.rects.isEmpty)
        scene.height = 211
        try draw()
        #expect(canvas.rects == [[0, 0, 320, 211]])
        #expect(Array(readRow(12)[48..<52]) == [0, 0, 255, 255])
    }

    @Test func deferredSurfaceKeepsTheLastPaintedAtlasRevision() throws {
        let image = RenderInstance(rect: SIMD4(0, 0, 8, 8), fill: SIMD4(repeating: 1),
                                   params: SIMD4(0, KIND_IMAGE, 0, 1), uv: SIMD4(0, 0, 1, 1), clip: NO_CLIP)
        var frame = RenderFrame(width: 128, height: 32, srgbBlend: true, instances: [image])
        frame.images = RGBA8Atlas(width: 1, height: 1, texels: [255, 0, 0, 255])
        let painter = CpuPainter(threads: 1)
        var target = CpuBootTarget(width: frame.width, height: frame.height)
        _ = try painter.paint(CpuBootScene(frame: frame), into: &target)
        #expect(Array(target.pixels.prefix(4)) == [0, 0, 255, 255])
        frame.images.texels = [0, 255, 0, 255]
        frame.surfaces = [SurfaceDraw(surface: NativeSurface(), fit: .fit, beforeInstance: 0, rect: image.rect, clip: NO_CLIP)]
        #expect(throws: NeedsGpu.nativeSurfaces) { try painter.paint(CpuBootScene(frame: frame), into: &target) }
        #expect(Array(target.pixels.prefix(4)) == [0, 0, 255, 255])
        frame.surfaces = []
        let result = try painter.paint(CpuBootScene(frame: frame), into: &target)
        #expect(result.rects == [[0, 0, 64, 32]])
        #expect(Array(target.pixels.prefix(4)) == [0, 255, 0, 255])
    }

    @Test func aFullRetinaFrameIsOneUploadAndScrolledPixelsStayInDamage() {
        let width = 2560, height = 1600
        let cols = UInt32(width) / CpuBootBin.tileW
        let rows = UInt32(height) / CpuBootBin.tileH
        #expect(CpuBootDamage.rects(dirtyTiles: Array(0..<cols * rows), cols: cols,
                                    size: (width, height), maxRects: 8) == [[0, 0, UInt32(width), UInt32(height)]])
        // Pinned Rust uses the earliest pair on an equal merge cost, including after moving the last rectangle.
        let scattered: [UInt32] = [0, 2, 5, 7, 8, 10, 12, 15, 17, 21, 22, 24, 26, 29, 30, 34]
        #expect(CpuBootDamage.rects(dirtyTiles: scattered, cols: 7, size: (423, 150), maxRects: 3)
                == [[0, 0, 256, 150], [384, 128, 423, 150], [320, 0, 384, 128]])
        var rects = (0..<8).map { i in [UInt32(i * 100), 0, UInt32(i * 100 + 10), 10] }
        CpuBootDamage.add([30, 30, 60, 160], to: &rects, maxRects: 8)
        #expect(rects.count == 8)
        #expect(rects.contains { $0[0] <= 30 && $0[1] <= 30 && $0[2] >= 60 && $0[3] >= 160 })
    }
}
