import Foundation
import Rune
import RuneMotion

public struct LiveValuesState: Sendable {
    public var levels: [Float]
    public var cursors: [Vec2]
    public var tick: UInt64 = 0
    public var liveLevels: [Live<Float>]
    public var liveCursors: [Live<Vec2>]
    public var rebuild: Bool = false
    public var smooth: Bool = false
    public var fixedSceneTick: Bool = false

    public init(rebuild: Bool = false) {
        self.levels = Array(repeating: 0.5, count: 16)
        self.cursors = Array(repeating: .zero, count: 4)
        self.liveLevels = (0..<16).map { _ in Live<Float>(0.5) }
        self.liveCursors = (0..<4).map { _ in Live<Vec2>(.zero) }
        self.rebuild = rebuild
        sample(tick: 0)
    }

    public mutating func sample(tick: UInt64) {
        self.tick = tick
        if tick % 2 == 0 {
            for i in 0..<16 {
                let v = 0.5 + 0.45 * sinf(Float(tick) / 120.0 * 3.0 + Float(i))
                levels[i] = v
            }
        }
        for i in 0..<4 {
            let t = Float(tick) / 120.0 + Float(i)
            cursors[i] = Vec2(
                250.0 + 180.0 * sinf(t),
                190.0 + 120.0 * cosf(t * 0.7)
            )
        }
        if !rebuild {
            for i in 0..<16 {
                liveLevels[i].set(levels[i])
            }
            for i in 0..<4 {
                liveCursors[i].set(cursors[i])
            }
        }
    }
}

public func liveValuesView(_ s: LiveValuesState, _ cx: inout Cx<LiveValuesState>) -> El<LiveValuesState> {
    let green = Color(r: 0.1, g: 0.8, b: 0.4, a: 1.0)
    var grid: El<LiveValuesState> = col().gap(20).p(40)
    for y in 0..<4 {
        var line: El<LiveValuesState> = row().gap(24)
        for x in 0..<4 {
            let i = y * 4 + x
            let ring: El<LiveValuesState> = el()
                .key("speaker-\(i)")
                .size(64, 64)
                .rounded(32)
                .border(3, green)
            line = line.child(
                s.rebuild
                    ? ring.opacity(s.levels[i])
                    : ring.liveOpacity(s.liveLevels[i].binding)
            )
        }
        grid = grid.child(line)
    }

    var root: El<LiveValuesState> = el()
        .bg(Color(r: 0.018, g: 0.024, b: 0.03, a: 1.0))
        .size(560, 440)
        .onClick { state in
            state.sample(tick: state.tick + 12)
        }
        .child(grid)

    for i in 0..<4 {
        let p = s.cursors[i]
        let cursor: El<LiveValuesState> = el()
            .key("cursor-\(i)")
            .size(12, 18)
            .rounded(3)
            .bg(green)

        if s.rebuild {
            root = root.child(cursor.pin(top: p.y, left: p.x))
        } else {
            let pinned = cursor.pin(top: 0, left: 0)
            if s.smooth {
                root = root.child(pinned.liveOffset(s.liveCursors[i].smooth(Spring(duration: 0.16, bounce: 0))))
            } else {
                root = root.child(pinned.liveOffset(s.liveCursors[i].binding))
            }
        }
    }

    return root
}

@main
public enum RuneLiveValuesApp {
    public static func makeSpec(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        windowed: Bool = false
    ) -> AppSpec<LiveValuesState> {
        let rebuildMode = arguments.contains("--rebuild")
        let initialState = LiveValuesState(rebuild: rebuildMode)
        let levels = initialState.liveLevels
        let cursors = initialState.liveCursors

        return AppSpec(
            title: "Live values",
            size: Vec2(560, 440),
            state: initialState,
            setup: { _ in
                guard windowed && !rebuildMode else { return }
                Thread.detachNewThread {
                    let start = Date()
                    for tick in 1...480 {
                        let target = start.addingTimeInterval(Double(tick) / 120.0)
                        let delay = target.timeIntervalSinceNow
                        if delay > 0 {
                            Thread.sleep(forTimeInterval: delay)
                        }
                        if tick % 2 == 0 {
                            for i in 0..<16 {
                                let v = 0.5 + 0.45 * sinf(Float(tick) / 120.0 * 3.0 + Float(i))
                                levels[i].set(v)
                            }
                        }
                        for i in 0..<4 {
                            let t = Float(tick) / 120.0 + Float(i)
                            cursors[i].set(Vec2(
                                250.0 + 180.0 * sinf(t),
                                190.0 + 120.0 * cosf(t * 0.7)
                            ))
                        }
                    }
                }
            },
            poll: { state, t, tx in
                if (windowed && !state.rebuild) || state.fixedSceneTick {
                    return false
                }
                let tick = UInt64((min(t, 4.0) * 120.0).rounded())
                guard tick != state.tick else { return false }
                state.sample(tick: tick)
                tx.instant()
                return state.rebuild
            },
            onKey: { state, ev, _ in
                if case .space = ev.key {
                    state.smooth.toggle()
                    return true
                }
                if case .text("r") = ev.key {
                    state.sample(tick: state.tick + 12)
                    return true
                }
                return false
            },
            view: liveValuesView
        )
        .scene("smooth") { $0.smooth = true }
        .scene("mid") {
            $0.fixedSceneTick = true
            $0.sample(tick: 120)
        }
    }

    public static func main() throws {
        let rawArgs = Array(CommandLine.arguments.dropFirst())
        let filteredArgs = rawArgs.filter { $0 != "--rebuild" }
        let isHeadless = ToolingArgs.parse(filteredArgs).isHeadlessRequested
        try RuneApp.run(makeSpec(arguments: rawArgs, windowed: !isHeadless), arguments: filteredArgs)
    }
}
