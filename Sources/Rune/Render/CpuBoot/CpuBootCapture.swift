import Foundation
import RuneRef

/// Captures the same production instances on the retained CPU painter and the offscreen GPU.
final class CpuBootCapture {
    private let directory: URL
    private let log: FileHandle
    private let painter: CpuPainter
    private let threads: Int
    private let vendor: UInt32
    private var target = CpuBootTarget(width: 0, height: 0)
    private var lastFills = TextOutlineFillStats()
    private var snapshotReport: [String: Any]?

    init(directory: String, threads: Int, adapter: DisplayGpuAdapter, atlas: GlyphAtlas) throws {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        self.threads = max(1, threads)
        self.vendor = Self.pciVendor(adapter)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let logURL = self.directory.appendingPathComponent("frames.jsonl")
        try Data().write(to: logURL)
        self.log = try FileHandle(forWritingTo: logURL)
        self.painter = CpuPainter(threads: self.threads)
        self.painter.attachMasks(to: atlas)
    }

    // Metal on Apple silicon exposes no PCI vendor ID to wgpu. GL reports vendor names.
    private static func pciVendor(_ adapter: DisplayGpuAdapter) -> UInt32 {
        let name = "\(adapter.vendor ?? "") \(adapter.device)".lowercased()
        if name.contains("intel") { return 0x8086 }
        if name.contains("nvidia") { return 0x10de }
        if name.contains("amd") || name.contains("radeon") || name.contains("ati technologies") { return 0x1002 }
        return 0
    }

    private func resize(_ width: Int, _ height: Int) {
        guard width != target.width || height != target.height else { return }
        let oldRows = target.stride == 0 ? 0 : target.pixels.count / target.stride
        if width * 4 > target.stride || height > oldRows {
            let stride = max(width * 4, target.stride)
            target = CpuBootTarget(width: width, height: height, stride: stride,
                                   pixels: Array(repeating: 0, count: stride * max(height, oldRows)))
            painter.forget()
        } else {
            target = CpuBootTarget(width: width, height: height, stride: target.stride, pixels: target.pixels)
        }
    }

    func paint(_ frame: RenderFrame, smoothing: FontSmoothing, atlasResets: Int,
               frameIndex: Int, updateNs: UInt64, snapshot: Bool, fills: TextOutlineFillStats) throws {
        let start = RuneExecutionContext.uptimeNanoseconds
        let scene = CpuBootScene(frame: frame, smoothing: smoothing, atlasResets: atlasResets,
                                 half: .ofVendor(vendor))
        resize(frame.width, frame.height)
        let fillNs = fills.elapsedNs &- lastFills.elapsedNs
        let fill = ["masks": fills.masks &- lastFills.masks, "texels": fills.texels &- lastFills.texels,
                    "cover_ns": fills.coverNs &- lastFills.coverNs, "copy_ns": fills.copyNs &- lastFills.copyNs]
        lastFills = fills
        var row: [String: Any] = ["k": frameIndex, "vendor": vendor, "update_ns": updateNs,
                                   "instances": frame.instances.count, "threads": threads, "fill": fill]
        do {
            let p = try painter.paint(scene, into: &target)
            let r = p.report
            let dirtyPixels = p.rects.reduce(UInt64(0)) { sum, rect in
                sum + UInt64(rect[2] - rect[0]) * UInt64(rect[3] - rect[1])
            }
            let scrolled: Any
            if let rect = p.scrolledRect, let (dy, _) = p.scrolled {
                scrolled = [rect, dy] as [Any]
            } else {
                scrolled = NSNull()
            }
            row["paint"] = ["bin_ns": r.binNs, "hash_ns": p.hashNs, "plan_ns": p.planNs,
                            "move_ns": p.moveNs, "scrolled": scrolled, "slowest_tile_ns": r.slowestTileNs,
                            "blur_ns": r.blurNs, "raster_ns": r.rasterNs, "total_ns": r.totalNs,
                            "threads": r.threads, "dirty_tiles": p.dirtyTiles, "tiles": p.tiles,
                            "rects": p.rects, "span_px": r.spanPx, "shaded_px": r.shadedPx,
                            "glyph_px": r.glyphPx, "dirty_px": dirtyPixels] as [String: Any]
        } catch let reason as NeedsGpu {
            row["needs_gpu"] = Self.reasonName(reason)
        }
        row["cpu_ns"] = (RuneExecutionContext.uptimeNanoseconds - start) &+ fillNs
        var line = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
        line.append(10)
        try log.write(contentsOf: line)
        guard snapshot else { return }
        var kinds = [Int](repeating: 0, count: 16)
        for i in frame.instances {
            let kind = i.params.y
            kinds[kind.isFinite ? Int(max(0, min(15, kind))) : 0] += 1
        }
        row["kinds"] = kinds
        try Data(CpuBootRecord.encodeForReplay(scene)).write(to: directory.appendingPathComponent("draw.bin"))
        try Frame(width: frame.width, height: frame.height, rgba: target.toRGBA8Tight())
            .writePNG(to: directory.appendingPathComponent("cpu.png"))
        snapshotReport = row
    }

    /// Called with the un-cropped GPU readback before advancing the CPU target.
    func gpu(_ frame: Frame) throws {
        guard var report = snapshotReport else { return }
        snapshotReport = nil
        try frame.writePNG(to: directory.appendingPathComponent("gpu.png"))
        if target.width == frame.width, target.height == frame.height {
            let d = CpuBootDriftMeter.drift(.bgra(target.pixels, width: target.width, height: target.height,
                                                  stride: target.stride),
                                            .rgba(frame.rgba, width: frame.width, height: frame.height))
            report["drift"] = ["pixels": d.pixels, "differ": d.differ, "over_two": d.overTwo, "max": Int(d.max)]
        }
        let encoded = try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
        RuneStandardIO.output("rune-cpu-boot \(String(decoding: encoded, as: UTF8.self))\n")
    }

    private static func reasonName(_ reason: NeedsGpu) -> String {
        switch reason {
        case .target: return "Target"
        case .linearBlend: return "LinearBlend"
        case .nativeSurfaces: return "NativeSurface"
        case .slugText: return "SlugText"
        case .compositor: return "Compositor"
        case .atlasResets: return "AtlasResets"
        case .effect: return "Effect"
        case .rotatedLayer: return "TurnedLayer"
        case .filteredLayer, .layerBlurUnsupported: return "LayerBlur"
        case .backdropInLayer: return "BackdropBlur"
        case .outlineGlyph: return "OutlineGlyph"
        case .unbalancedLayer: return "UnbalancedLayer"
        case .unknownKind: return "UnknownKind"
        }
    }
}
