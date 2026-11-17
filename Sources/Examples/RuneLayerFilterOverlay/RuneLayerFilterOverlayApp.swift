import Foundation
import Rune

public struct LayerFilterOverlayState: Sendable {
    public init() {}
}

private final class LayerFilterOverlayRetainer: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OverlayHandle<LayerFilterOverlayState>?

    func hold(_ handle: OverlayHandle<LayerFilterOverlayState>) {
        lock.lock()
        self.handle = handle
        lock.unlock()
    }

    func release() {
        lock.lock()
        let old = handle
        handle = nil
        lock.unlock()
        old?.hide()
    }
}

@main
public enum RuneLayerFilterOverlayApp {
    public static let size = Vec2(620.0, 176.0)
    public static let ink = Color(r: 0.06, g: 0.32, b: 1.0, a: 1.0)
    public static let surface = Color(r: 0.035, g: 0.035, b: 0.035, a: 1.0)

    public static func view(_ s: LayerFilterOverlayState, _ cx: inout Cx<LayerFilterOverlayState>) -> El<LayerFilterOverlayState> {
        _ = (s, cx)
        var root: El<LayerFilterOverlayState> = el().key("root").size(size.x, size.y)
        for (label, y, clipped) in [("Unmasked", Float(32.0), false), ("Clipped", Float(112.0), true)] {
            var capsule: El<LayerFilterOverlayState> = el()
                .key(clipped ? "capsule-clipped" : "capsule-unmasked")
                .size(400.0, 40.0)
                .absolute(x: 112.0, y: y)
                .rounded(20.0)
                .bg(surface)
            if clipped {
                capsule = capsule.clipRounded(20.0)
            }
            // Shared background stays outside the dissolve; blur is on the leaving state.
            let leaving: El<LayerFilterOverlayState> = el()
                .key(clipped ? "leaving-clipped" : "leaving-unmasked")
                .size(72.0, 28.0)
                .absolute(x: 370.0, y: 6.0)
                .opacity(0.65)
                .blur(1.5)
                .rounded(8.0)
                .bg(ink)
                .child(text("Leaving").absolute(x: 8.0, y: 6.0))
            root = root
                .child(text(label).absolute(x: 12.0, y: y + 11.0))
                .child(
                    capsule.child(
                        el()
                            .size(400.0, 40.0)
                            .dissolve()
                            .child(leaving)
                    )
                )
        }
        return root
    }

    public static func makeOverlaySpec(
        onCreated: ((OverlayCreated) -> Void)? = nil
    ) -> ConfiguredOverlay<LayerFilterOverlayState> {
        var configured = OverlaySpec<LayerFilterOverlayState>(
            name: "Layer filter capsule proof",
            size: size,
            makeState: { LayerFilterOverlayState() },
            view: view
        )
        .configured(
            OverlayOptions(
                display: .primary,
                level: .aboveOverlays,
                excludeFromCapture: false,
                input: .none,
                prewarm: true
            )
        )
        if let onCreated {
            configured = configured.onCreated(onCreated)
        }
        return configured
    }

    public static func makeApp(
        arguments: [String] = Array(CommandLine.arguments.dropFirst())
    ) -> App<LayerFilterOverlayState> {
        let isHeadless = ToolingArgs.parse(arguments).isHeadlessRequested || arguments.contains("--headless")
        let retainer = LayerFilterOverlayRetainer()
        var app = App<LayerFilterOverlayState>(
            "Layer filter overlay",
            size: size,
            init: { LayerFilterOverlayState() },
            view: view
        )
        .windowless(!isHeadless)
        .accessory(true)
        .args(arguments)

        if !isHeadless {
            let commands = app.handle()
            app = app
                .onQuit { _, _ in
                    retainer.release()
                }
                .setup { _ in
                    let pill = OverlayHandle(
                        configured: makeOverlaySpec { created in
                            RuneStandardIO.error("filter-overlay created \(created)\n")
                        }
                    )
                    retainer.hold(pill)
                    pill.show()

                    Thread.detachNewThread {
                        _ = readLine()
                        retainer.release()
                        commands.quit()
                    }
                }
        }
        return app
    }

    @MainActor
    public static func main() throws {
        try RuneApp.run(makeApp())
    }
}
