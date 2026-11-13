import Foundation
import Rune

/// Port of `crates/rune/examples/canvas_input.rs`: infinite canvas with live camera pan/zoom
/// (`liveOffset`/`liveScale`, `onWheel`, `onMagnify`, `pointerButtons([.middle])` + `Tx.button`,
/// Space + drag with `onKeyUp`, `Tx.scrollTo`, `onDrawnLayout`, and `Tx.liveOnly`).
public let canvasSize: Float = 400.0
public let canvasNodeCount = 30
public let canvasLayerRowHeight: Float = 40.0

public struct CanvasInputState: Sendable {
    public var pan: Vec2
    public var zoom: Float
    public var livePan: Live<Vec2>
    public var liveZoom: Live<Float>
    public var space: Bool
    public var panAtPress: Vec2
    public var selected: Int
    public var toolbar: [Float]?

    public init(
        pan: Vec2 = .zero,
        zoom: Float = 1.0,
        space: Bool = false,
        panAtPress: Vec2 = .zero,
        selected: Int = 7,
        toolbar: [Float]? = nil
    ) {
        self.pan = pan
        self.zoom = zoom
        self.livePan = Live(pan)
        self.liveZoom = Live(zoom)
        self.space = space
        self.panAtPress = panAtPress
        self.selected = selected
        self.toolbar = toolbar
    }

    public mutating func setCamera(_ pan: Vec2, _ zoom: Float) {
        self.pan = pan
        self.zoom = min(max(zoom, 0.1), 8.0)
        livePan.set(self.pan)
        liveZoom.set(self.zoom)
    }

    public func world(_ q: Vec2) -> Vec2 {
        let c = canvasSize / 2.0
        return Vec2(
            c + (q.x - c - pan.x) / zoom,
            c + (q.y - c - pan.y) / zoom
        )
    }

    public func screen(_ p: Vec2) -> Vec2 {
        let c = canvasSize / 2.0
        return Vec2(
            c + (p.x - c) * zoom + pan.x,
            c + (p.y - c) * zoom + pan.y
        )
    }
}

public func canvasNodeAt(_ i: Int) -> Vec2 {
    Vec2(20.0 + 150.0 * Float(i % 6), 20.0 + 120.0 * Float(i / 6))
}

public func canvasInputView(_ s: CanvasInputState, _ cx: inout Cx<CanvasInputState>) -> El<CanvasInputState> {
    let nodes: [El<CanvasInputState>] = (0..<canvasNodeCount).map { i in
        let pos = canvasNodeAt(i)
        let node: El<CanvasInputState> = el()
            .key("node\(i)")
            .pin(top: pos.y, left: pos.x)
            .size(80.0, 60.0)
            .rounded(8.0)
            .bg(i == s.selected ? Color.white : Color.white.alpha(0.3))
            .onClick { state, _ in state.selected = i }
        if i == s.selected {
            return node.onDrawnLayout { state, rect in state.toolbar = rect }
        }
        return node
    }

    let world: El<CanvasInputState> = el()
        .key("world")
        .size(canvasSize, canvasSize)
        .liveOffset(s.livePan.binding)
        .liveScale(s.liveZoom.binding)
        .children(nodes)

    let canvas: El<CanvasInputState> = el()
        .key("canvas")
        .size(canvasSize, canvasSize)
        .clipSoft(0.0)
        .child(world)
        .onWheel { state, ev, tx in
            state.setCamera(Vec2(state.pan.x + ev.dx, state.pan.y + ev.dy), state.zoom)
            tx.liveOnly()
            return true
        }
        .onMagnify { state, ev, tx in
            let q = Vec2(ev.x, ev.y)
            let p = state.world(q)
            let c = canvasSize / 2.0
            let zoom = min(max(state.zoom * (1.0 + ev.delta), 0.1), 8.0)
            state.setCamera(
                Vec2(q.x - c - (p.x - c) * zoom, q.y - c - (p.y - c) * zoom),
                zoom
            )
            tx.liveOnly()
            return true
        }
        .pointerButtons([.middle])
        .onPointerDown { state, _, tx in
            if tx.button == .middle || state.space {
                state.panAtPress = state.pan
                tx.liveOnly()
            }
        }
        .onDrag { state, drag, tx in
            if tx.button == .middle || state.space {
                state.setCamera(
                    Vec2(state.panAtPress.x + drag.delta.x, state.panAtPress.y + drag.delta.y),
                    state.zoom
                )
                tx.liveOnly()
            }
        }
        .onDragEnd { state, cancelled, tx in
            if cancelled, tx.button == .middle || state.space {
                state.setCamera(state.panAtPress, state.zoom)
                tx.liveOnly()
            }
        }

    let focus: El<CanvasInputState> = el()
        .key("focus")
        .h(canvasLayerRowHeight)
        .wFull()
        .bg(Color.white.alpha(0.1))
        .onClick { state, tx in
            let pos = canvasNodeAt(state.selected)
            let c = canvasSize / 2.0
            let centre = Vec2(pos.x + 40.0, pos.y + 30.0)
            state.setCamera(
                Vec2(-(centre.x - c) * state.zoom, -(centre.y - c) * state.zoom),
                state.zoom
            )
            tx.scrollTo("layers", x: 0.0, y: Float(state.selected) * canvasLayerRowHeight)
        }

    let layerRows: [El<CanvasInputState>] = (0..<canvasNodeCount).map { i in
        let row: El<CanvasInputState> = el()
        return row
            .key("layer\(i)")
            .wFull()
            .h(canvasLayerRowHeight)
            .onClick { state, _ in state.selected = i }
    }

    let layers: El<CanvasInputState> = col()
        .key("layers")
        .wFull()
        .h(canvasSize - canvasLayerRowHeight)
        .scroll(ScrollSpec(stickBottom: false))
        .children(layerRows)

    let side = col()
        .w(200.0)
        .hFull()
        .child(focus)
        .child(layers)

    return row()
        .wFull()
        .hFull()
        .onKeyUp { state, ev, _ in
            let isSpace = ev.key == .text(" ") || ev.key == .space
            if isSpace { state.space = false }
            return isSpace
        }
        .child(canvas)
        .child(side)
}

public func onCanvasInputKey(_ state: inout CanvasInputState, _ ev: KeyEvent, _: inout Tx) -> Bool {
    let isSpace = ev.key == .text(" ") || ev.key == .space
    if isSpace { state.space = true }
    return isSpace
}

@main
public enum RuneCanvasInputApp {
    public static func makeApp() -> App<CanvasInputState> {
        App(
            title: "Canvas Input",
            size: Vec2(600.0, canvasSize),
            state: CanvasInputState(),
            view: canvasInputView
        )
        .onKey(onCanvasInputKey)
    }

    public static func makeSpec() -> AppSpec<CanvasInputState> {
        makeApp().intoSpec()
    }

    public static func main() throws {
        try makeApp().run()
    }
}
