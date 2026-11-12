import Foundation
import Rune

/// Port of `examples/video-tiles`: 2x2 grid of `NativeSurface` video tiles fed with synthetic RGBA8 frames.
struct VideoTilesState {
    var surfaces: [NativeSurface]
    var frameIndex: UInt64 = 0

    static func syntheticFrame(width: UInt32, height: UInt32, id: UInt64) -> NativeSurfaceFrame {
        let w = Int(width)
        let h = Int(height)
        var bytes = Data(count: w * h * 4)
        let barColors: [(UInt8, UInt8, UInt8)] = [
            (235, 235, 235), (235, 235, 16), (16, 235, 235), (16, 235, 16),
            (235, 16, 235), (235, 16, 16), (16, 16, 235), (24, 24, 28),
        ]
        let scanY = Int((id * 6) % UInt64(max(1, h)))
        let shift = Int((id * 4) % UInt64(max(1, w)))
        bytes.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<h {
                let isScan = abs(y - scanY) <= 2
                for x in 0..<w {
                    let off = (y * w + x) * 4
                    if isScan {
                        ptr[off] = 255
                        ptr[off + 1] = 255
                        ptr[off + 2] = 255
                        ptr[off + 3] = 255
                    } else {
                        let bar = ((x + shift) * barColors.count / max(1, w)) % barColors.count
                        let c = barColors[bar]
                        ptr[off] = c.0
                        ptr[off + 1] = c.1
                        ptr[off + 2] = c.2
                        ptr[off + 3] = 255
                    }
                }
            }
        }
        return NativeSurfaceFrame(
            width: width,
            height: height,
            format: .rgba8,
            bytes: bytes,
            timestampSeconds: Double(id) / 60.0
        )
    }

    static func initial() -> VideoTilesState {
        let surfaces = (0..<4).map { NativeSurface(id: UInt64($0 + 1)) }
        let frame = syntheticFrame(width: 320, height: 180, id: 0)
        for s in surfaces {
            s.publish(frame)
        }
        return VideoTilesState(surfaces: surfaces, frameIndex: 0)
    }

    mutating func advance(to index: UInt64) {
        frameIndex = index
        for (i, s) in surfaces.enumerated() {
            let frame = Self.syntheticFrame(width: 320, height: 180, id: index + UInt64(i * 12))
            s.publish(frame)
        }
    }
}

func surfaceAtlas(_ surface: NativeSurface) -> RGBA8Atlas {
    guard let f = surface.latestFrame() else {
        return RGBA8Atlas(width: 320, height: 180)
    }
    return RGBA8Atlas(width: Int(f.width), height: Int(f.height), texels: [UInt8](f.bytes))
}

func videoTilesView(_ s: VideoTilesState, _ cx: inout Cx<VideoTilesState>) -> El<VideoTilesState> {
    let t = Tok.theme(dark: true)
    var grid: El<VideoTilesState> = col().key("tiles").gap(8).p(8).bg(t.bg)
    for y in 0..<2 {
        var r: El<VideoTilesState> = row().gap(8)
        for x in 0..<2 {
            let idx = y * 2 + x
            let atlas = surfaceAtlas(s.surfaces[idx])
            let tile: El<VideoTilesState> = el()
                .key("tile-\(x)-\(y)")
                .size(320, 180)
                .rounded(8)
                .clip(true)
                .child(image(atlas).size(320, 180))
                .onClick { state in
                    state.advance(to: state.frameIndex + 10)
                }
            r = r.child(tile)
        }
        grid = grid.child(r)
    }
    return grid
}

if CommandLine.arguments.contains("--bench-native") {
    let surface = NativeSurface(id: 99)
    let frame = VideoTilesState.syntheticFrame(width: 640, height: 360, id: 1)
    let start = CFAbsoluteTimeGetCurrent()
    for i in 0..<240 {
        surface.publish(NativeSurfaceFrame(
            width: frame.width,
            height: frame.height,
            format: .rgba8,
            bytes: frame.bytes,
            timestampSeconds: Double(i) / 60.0
        ))
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    print(String(format: "Published 240 640x360 NativeSurface frames in %.3f s (%.1f fps)", elapsed, 240.0 / max(0.0001, elapsed)))
    exit(0)
}

let spec = AppSpec<VideoTilesState>(
    title: "Video tiles",
    size: Vec2(664, 384),
    dark: true,
    state: VideoTilesState.initial(),
    onKey: { state, event, _ in
        if event.key == .space || event.key == .arrowRight {
            state.advance(to: state.frameIndex + 15)
            return true
        }
        return false
    },
    view: videoTilesView
)
.scene("initial") { $0.advance(to: 0) }
.scene("frame-30") { $0.advance(to: 30) }

try RuneApp.run(spec)
