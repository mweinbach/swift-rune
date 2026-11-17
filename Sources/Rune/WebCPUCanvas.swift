import Foundation

/// Pixel backing for a CPU-first browser window. Only damage crosses into page-owned ImageData.
final class WebCPUCanvas {
    private let painter = CpuPainter(threads: 1)
    private var target = CpuBootTarget(width: 0, height: 0)
    private(set) var rects: [[UInt32]] = []
    private var rasterUs: Double = 0
    private var paintUs: Double = 0
    private var fillUs: Double = 0
    private var needsGPU = false

    init(glyphAtlas: GlyphAtlas? = nil) {
        if let glyphAtlas { painter.attachMasks(to: glyphAtlas) }
    }

    /// An unsupported frame leaves the displayed pixels intact until the GPU is ready.
    func paint(_ frame: RenderFrame, smoothing: FontSmoothing, compositor: Bool, force: Bool, fillNs: UInt64 = 0) throws {
        if target.width != frame.width || target.height != frame.height {
            target = CpuBootTarget(width: frame.width, height: frame.height)
            painter.forget()
        } else if force {
            painter.forget()
        }
        rects.removeAll(keepingCapacity: true)
        rasterUs = 0
        paintUs = 0
        fillUs = Double(fillNs) / 1_000
        needsGPU = false
        let scene = CpuBootScene(frame: frame, compositor: compositor, smoothing: smoothing)
        do {
            let result = try painter.paint(scene, into: &target)
            rects = result.rects
            rasterUs = Double(result.report.rasterNs) / 1_000
            paintUs = Double(result.report.totalNs) / 1_000
        } catch is NeedsGpu {
            needsGPU = true
        }
    }

    // Width, height, rectangle count, deferred flag, paint/raster microseconds, exclusive pixel edges, fill microseconds.
    var byteCount: Int { 40 + rects.count * 16 }

    func writeHeader(to output: UnsafeMutableRawPointer) {
        let words = output.assumingMemoryBound(to: UInt32.self)
        words[0] = UInt32(target.width).littleEndian
        words[1] = UInt32(target.height).littleEndian
        words[2] = UInt32(rects.count).littleEndian
        words[3] = needsGPU ? 1 : 0
        words[4] = UInt32(truncatingIfNeeded: paintUs.bitPattern).littleEndian
        words[5] = UInt32(paintUs.bitPattern >> 32).littleEndian
        words[6] = UInt32(truncatingIfNeeded: rasterUs.bitPattern).littleEndian
        words[7] = UInt32(rasterUs.bitPattern >> 32).littleEndian
        for (index, rect) in rects.enumerated() {
            for side in 0..<4 { words[8 + index * 4 + side] = rect[side].littleEndian }
        }
        words[8 + rects.count * 4] = UInt32(truncatingIfNeeded: fillUs.bitPattern).littleEndian
        words[9 + rects.count * 4] = UInt32(fillUs.bitPattern >> 32).littleEndian
    }

    /// Swizzle in bounded strips so even a full-viewport scene never retains a second frame in WASM memory.
    func copyRGBA(rect index: Int, row: Int, count: Int, reserve: (Int) -> UnsafeMutableRawPointer?) -> Int {
        guard rects.indices.contains(index), row >= 0, count > 0 else { return 0 }
        let rect = rects[index]
        let w = Int(rect[2] - rect[0]), h = Int(rect[3] - rect[1])
        guard w > 0, row < h, count <= h - row, count <= max(1, 16_384 / w) else { return 0 }
        let bytes = w * count * 4
        guard let output = reserve(bytes) else { return 0 }
        let out = output.assumingMemoryBound(to: UInt32.self)
        let stride = target.stride / 4
        let offset = (Int(rect[1]) + row) * stride + Int(rect[0])
        target.pixels.withUnsafeBytes { source in
            for y in 0..<count {
                let line = (offset + y * stride) * 4
                for x in 0..<w {
                    let bgra = UInt32(littleEndian: source.loadUnaligned(fromByteOffset: line + x * 4, as: UInt32.self))
                    out[y * w + x] = ((bgra & 0xff00_ff00) | ((bgra >> 16) & 0xff) | ((bgra & 0xff) << 16)).littleEndian
                }
            }
        }
        return bytes
    }
}
