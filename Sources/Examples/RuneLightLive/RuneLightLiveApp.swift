import Foundation
import RuneLight
import RuneRef

#if canImport(Metal)
import Metal
#endif

#if canImport(AppKit) && canImport(MetalKit)
import AppKit
import MetalKit
#endif

#if canImport(Metal)
private func runSnap(
    path: String,
    which: LiveSceneKind,
    at: SIMD2<Float>?,
    rays: Bool,
    click: Bool?,
    after: Double,
    mode: LightMode,
    machined: Bool,
    bare: Bool
) throws {
    let w = 2560
    let h = 1600
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw NSError(domain: "RuneLightLive", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal unavailable"])
    }
    let gfx = try LiveGfx(device: device, width: w, height: h, outputFormat: .rgba8Unorm)
    let st = LiveState(which: which)
    st.fake = 0.0
    let vp = SIMD2<Float>(Float(w), Float(h))
    _ = st.buildFrame(ts: gfx.ts, scale: 2.0, viewportPx: vp)

    if let p = at {
        st.pointerMove(p)
        if which == .chat {
            st.jump(p)
        }
        if let release = click {
            st.button(down: true)
            if release {
                st.button(down: false)
            }
        }
    }
    st.rays = rays
    st.mode = mode
    st.machined = machined
    st.bare = bare
    st.fake = after

    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .shared
    let out = device.makeTexture(descriptor: desc)!

    let (frame, _) = st.buildFrame(ts: gfx.ts, scale: 2.0, viewportPx: vp)
    gfx.render(frame, into: out)

    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    out.getBytes(&rgba, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Frame(width: w, height: h, rgba: rgba).writePNG(to: url)
    fputs("wrote \(path)\n", stderr)
}
#endif

#if canImport(AppKit) && canImport(MetalKit) && canImport(Metal)
@MainActor
private final class LiveWindowController: NSObject, NSWindowDelegate, MTKViewDelegate {
    let state: LiveState
    let gfx: LiveGfx
    let mtkView: MTKView
    let window: NSWindow

    init(state: LiveState, device: MTLDevice) throws {
        self.state = state
        let rect = NSRect(x: 0, y: 0, width: CGFloat(livePtW), height: CGFloat(livePtH))
        self.mtkView = LiveMTKView(frame: rect, device: device)
        self.mtkView.colorPixelFormat = .bgra8Unorm_srgb
        self.mtkView.framebufferOnly = false
        self.mtkView.enableSetNeedsDisplay = false
        self.mtkView.isPaused = false
        self.mtkView.preferredFramesPerSecond = 60

        self.window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        self.window.title = "rune-light"
        self.window.minSize = NSSize(width: 480, height: 300)
        self.window.acceptsMouseMovedEvents = true
        self.window.contentView = self.mtkView
        self.window.center()

        let ds = self.mtkView.drawableSize
        self.gfx = try LiveGfx(device: device, width: Int(max(ds.width, 1)), height: Int(max(ds.height, 1)), outputFormat: .bgra8Unorm_srgb)
        super.init()

        self.window.delegate = self
        self.mtkView.delegate = self
        if let v = self.mtkView as? LiveMTKView {
            v.controller = self
        }
    }

    private func scaleAndOffset() -> (Float, SIMD2<Float>) {
        let w = Float(max(mtkView.drawableSize.width, 1))
        let h = Float(max(mtkView.drawableSize.height, 1))
        let k = max(min(w / livePtW, h / livePtH), 0.1)
        let ox = ((w - livePtW * k) * 0.5).rounded()
        let oy = ((h - livePtH * k) * 0.5).rounded()
        return (k, SIMD2<Float>(ox, oy))
    }

    func toCanvasPt(_ windowPoint: NSPoint) -> SIMD2<Float> {
        let local = mtkView.convert(windowPoint, from: nil)
        let backingScale = Float(mtkView.window?.backingScaleFactor ?? 1.0)
        let pxX = Float(local.x) * backingScale
        let pxY = (Float(mtkView.bounds.height) - Float(local.y)) * backingScale
        let (k, o) = scaleAndOffset()
        return SIMD2<Float>((pxX - o.x) / k, (pxY - o.y) / k)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        try? gfx.resize(width: Int(max(size.width, 1)), height: Int(max(size.height, 1)))
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        let w = drawable.texture.width
        let h = drawable.texture.height
        try? gfx.resize(width: w, height: h)
        let (k, o) = scaleAndOffset()
        var (frame, _) = state.buildFrame(ts: gfx.ts, scale: k, viewportPx: SIMD2<Float>(Float(w), Float(h)))
        translateLiveFrame(&frame, offset: o)
        gfx.render(frame, into: drawable.texture, present: drawable)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

@MainActor
private final class LiveMTKView: MTKView {
    weak var controller: LiveWindowController?

    override var acceptsFirstResponder: Bool { true }

    override func mouseMoved(with event: NSEvent) {
        guard let c = controller else { return }
        c.state.pointerMove(c.toCanvasPt(event.locationInWindow))
    }

    override func mouseDown(with event: NSEvent) {
        guard let c = controller else { return }
        c.state.pointerMove(c.toCanvasPt(event.locationInWindow))
        c.state.button(down: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = controller else { return }
        c.state.pointerMove(c.toCanvasPt(event.locationInWindow))
    }

    override func mouseUp(with event: NSEvent) {
        guard let c = controller else { return }
        c.state.pointerMove(c.toCanvasPt(event.locationInWindow))
        c.state.button(down: false)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let c = controller else { return }
        let dy = Float(event.scrollingDeltaY) / (event.hasPreciseScrollingDeltas ? 20.0 : 1.0)
        c.state.radius = min(max(c.state.radius * powf(1.12, dy), 0.1), 10.0)
    }

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { return }
        if event.keyCode == 53 {
            NSApp.terminate(nil)
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "1": c.state.switchScene(.flashlight)
        case "2": c.state.switchScene(.chat)
        case "d": c.state.direct.toggle()
        case "g": c.state.rays.toggle()
        case "r": c.state.radius = 1.0
        case "l":
            c.state.mode = c.state.mode.next()
            c.state.modeAt = c.state.now()
        case "m": c.state.machined.toggle()
        default: super.keyDown(with: event)
        }
    }
}
#endif

@main
enum RuneLightLiveApp {
    static func main() throws {
        try run(args: Array(CommandLine.arguments.dropFirst()))
    }

    static func run(args: [String]) throws {
        func arg(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let which: LiveSceneKind = arg("--scene") == "chat" ? .chat : .flashlight

        #if canImport(Metal)
        if let path = arg("--snap") {
            let at: SIMD2<Float>? = arg("--at").flatMap { s in
                let parts = s.split(separator: ",")
                guard parts.count == 2, let x = Float(parts[0]), let y = Float(parts[1]) else { return nil }
                return SIMD2<Float>(x, y)
            }
            let click: Bool? = args.contains("--click") ? true : (args.contains("--down") ? false : nil)
            let after = arg("--after").flatMap(Double.init) ?? 1.0
            let mode: LightMode = switch arg("--mode") {
            case "overhead": .overhead
            case "backlight": .backlight
            default: .behind
            }
            try runSnap(
                path: path,
                which: which,
                at: at,
                rays: args.contains("--rays"),
                click: click,
                after: after,
                mode: mode,
                machined: !args.contains("--soft"),
                bare: args.contains("--bare")
            )
            return
        }

        #if canImport(AppKit) && canImport(MetalKit)
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            guard let device = MTLCreateSystemDefaultDevice(),
                  let wc = try? LiveWindowController(state: LiveState(which: which), device: device) else {
                fputs("error: failed to create live Metal window\n", stderr)
                Foundation.exit(1)
            }
            wc.window.makeKeyAndOrderFront(nil)
            wc.window.makeFirstResponder(wc.mtkView)
            app.activate(ignoringOtherApps: true)
            _ = wc
            app.run()
        }
        #else
        fputs("error: interactive window requires AppKit/MetalKit; pass --snap PATH for headless rendering\n", stderr)
        Foundation.exit(1)
        #endif
        #else
        fputs("error: Metal unavailable on this platform\n", stderr)
        Foundation.exit(1)
        #endif
    }
}
