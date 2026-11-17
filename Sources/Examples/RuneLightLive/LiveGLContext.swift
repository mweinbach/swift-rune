#if canImport(CRuneGL)
import Foundation
import Rune
import RuneLight

private func liveCanvas(_ size: SIMD2<Float>) -> (scale: Float, offset: SIMD2<Float>) {
    let canvas = SIMD2(livePtW, livePtH)
    let scale = max(min(size.x / canvas.x, size.y / canvas.y), 0.1)
    let offset = (size - canvas * scale) * 0.5
    return (scale, SIMD2(offset.x.rounded(), offset.y.rounded()))
}

private final class LiveGLCompositor: Compositor {
    var features: CompositorFeatures { .customClear }
    private(set) var isAnimating = true
    private var layers: LightGLLayers?
    private(set) var failure: (any Error)?
    var stop: (() -> Void)?

    func render(frame: CompositorFrame<LiveState>) {
        guard failure == nil else { return }
        do {
            guard let target = frame.openGL else { throw LightRendererError.shaderCompileFailed("OpenGL compositor target unavailable") }
            let gfx: LightGLLayers
            if let layers {
                gfx = layers
            } else {
                gfx = try LightGLLayers(resolve: target.resolve)
                layers = gfx
            }
            let (width, height) = target.pixelSize
            let viewport = SIMD2(Float(width), Float(height))
            let (scale, offset) = liveCanvas(viewport)
            var (scene, animating) = frame.runtime.state.buildFrame(ts: gfx.ts, scale: scale, viewportPx: viewport)
            translateLiveFrame(&scene, offset: offset)
            scene.settings.seed = 0
            try gfx.drawUI(base: scene.base, text: scene.text, clear: scene.clear, width: width, height: height)
            try gfx.composite(scene: LightScene(prims: scene.prims, lights: scene.lights, settings: scene.settings),
                              framebuffer: target.framebuffer)
            isAnimating = animating
        } catch {
            failure = error
            isAnimating = false
            stop?()
        }
    }

    func close() {
        layers?.close()
        layers = nil
    }
}

@MainActor
func runGLLiveWindow(which: LiveSceneKind) throws {
    let compositor = LiveGLCompositor()
    func move(_ state: LiveState, _ press: PointerPress) {
        let (scale, offset) = liveCanvas(SIMD2(press.elementSize.x, press.elementSize.y))
        state.pointerMove((SIMD2(press.local.x, press.local.y) - offset) / scale)
    }
    let app = App(title: "rune-light", size: Vec2(livePtW, livePtH), minSize: Vec2(480, 300),
                  state: LiveState(which: which)) { _, _ in
        El<LiveState>().sizeFull()
            .onPointerMove { state, press, _ in move(state, press) }
            .onPointerDown { state, press, _ in
                move(state, press)
                state.button(down: true)
            }
            .onPointerUp { state, press, _ in
                move(state, press)
                state.button(down: false)
            }
            .onWheel { state, event, _ in
                let steps = event.dy / (event.precise ? 20 : WheelDistance.linePoints)
                state.radius = min(max(state.radius * powf(1.12, steps), 0.1), 10)
                return true
            }
    }
    .onKey { state, event, tx in
        switch event.key {
        case .escape: tx.closeWindow()
        case .text(let key):
            switch key.lowercased() {
            case "1": state.switchScene(.flashlight)
            case "2": state.switchScene(.chat)
            case "d": state.direct.toggle()
            case "g": state.rays.toggle()
            case "r": state.radius = 1
            case "l":
                state.mode = state.mode.next()
                state.modeAt = state.now()
            case "m": state.machined.toggle()
            default: return false
            }
        default: return false
        }
        return true
    }
    .compositor(compositor)
    .onQuit { _, _ in compositor.close() }
    let handle = app.handle()
    compositor.stop = { handle.close() }
    try RuneApp.run(app)
    if let failure = compositor.failure { throw failure }
}
#endif
