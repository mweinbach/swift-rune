import Foundation
import Rune
import RuneKit

public struct VideoTilesState: @unchecked Sendable {
    public static let tileWidth: UInt32 = 640
    public static let tileHeight: UInt32 = 360

    public var tiles: [NativeSurface]
    public var frameTick: UInt64 = 0

    public init(tileCount: Int = 4, initialTick: UInt64 = 0) {
        self.tiles = (0..<tileCount).map { _ in NativeSurface() }
        self.frameTick = initialTick
        pushFrames(tick: initialTick)
    }

    public func pushFrames(tick: UInt64) {
        let frameId = tick + 1
        for i in 0..<tiles.count {
            let frame = ByteFrame.synthetic(
                width: Self.tileWidth,
                height: Self.tileHeight,
                index: tick + UInt64(i)
            )
            #if os(macOS)
            if let pb = try? CoreVideoPixelBuffer.fromBytes(frame) {
                try? tiles[i].push(pb, frameId: frameId)
            } else {
                try? tiles[i].pushBytes(frame, frameId: frameId)
            }
            #else
            try? tiles[i].pushBytes(frame, frameId: frameId)
            #endif
        }
    }
}

@main
public enum RuneVideoTilesApp {
    public static func videoTilesView(_ s: VideoTilesState, _ cx: inout Cx<VideoTilesState>) -> El<VideoTilesState> {
        let t = Tok.theme(dark: true)

        func tileEl(_ idx: Int) -> El<VideoTilesState> {
            let surfaceEl: El<VideoTilesState> = el().nativeSurface(s.tiles[idx], .fit).sizeFull()
            return el()
                .key("tile-\(idx)")
                .grow(1)
                .hFull()
                .rounded(8)
                .clip(true)
                .bg(t.card)
                .child(surfaceEl)
        }

        let topRow: El<VideoTilesState> = row()
            .grow(1)
            .gap(8)
            .child(tileEl(0))
            .child(tileEl(1))
        let bottomRow: El<VideoTilesState> = row()
            .grow(1)
            .gap(8)
            .child(tileEl(2))
            .child(tileEl(3))

        return col()
            .sizeFull()
            .p(8)
            .gap(8)
            .bg(t.bg)
            .child(topRow)
            .child(bottomRow)
    }

    public static func makeSpec(
        arguments: [String] = Array(CommandLine.arguments.dropFirst())
    ) -> AppSpec<VideoTilesState> {
        let state = VideoTilesState()
        let tiles = state.tiles
        let parsed = ToolingArgs.parse(arguments)
        let isHeadless = parsed.isHeadlessRequested || arguments.contains("--headless")

        return AppSpec<VideoTilesState>(
            title: "Video tiles (2x2 NativeSurface)",
            size: Vec2(820, 500),
            dark: true,
            state: state,
            setup: { waker in
                for tile in tiles {
                    tile.setWaker { waker.wake() }
                }
                guard !isHeadless else { return }
                let producer = Thread {
                    var tick: UInt64 = 1
                    while !Thread.current.isCancelled {
                        Thread.sleep(forTimeInterval: 1.0 / 60.0)
                        let frameId = tick + 1
                        for i in 0..<tiles.count {
                            let frame = ByteFrame.synthetic(
                                width: VideoTilesState.tileWidth,
                                height: VideoTilesState.tileHeight,
                                index: tick + UInt64(i)
                            )
                            #if os(macOS)
                            if let pb = try? CoreVideoPixelBuffer.fromBytes(frame) {
                                try? tiles[i].push(pb, frameId: frameId)
                            }
                            #else
                            try? tiles[i].pushBytes(frame, frameId: frameId)
                            #endif
                        }
                        tick += 1
                    }
                }
                producer.name = "video-tiles-producer"
                producer.start()
            },
            view: videoTilesView
        )
        .scene("initial") { s in
            s.frameTick = 0
            s.pushFrames(tick: 0)
        }
        .scene("frame-30") { s in
            s.frameTick = 30
            s.pushFrames(tick: 30)
        }
    }

    @MainActor
    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let (_, extra) = ToolingProcessArgs.parseSplit(args)
        if extra.contains("--bench-native") {
            _ = try VideoTilesBench.runNativeBench()
            return
        }
        try RuneApp.run(makeSpec(arguments: args), arguments: args)
    }
}
