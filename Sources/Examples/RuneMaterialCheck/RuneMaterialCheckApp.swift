import Foundation
import Rune
#if canImport(Darwin)
import Darwin
#endif
#if os(macOS)
import AppKit
import QuartzCore
#endif

/// Real-window + overlay AppKit backdrop material (`NSVisualEffectView` / `NSGlassEffectView`) probe
/// mirroring `crates/rune/examples/material_check.rs`.
///
/// NOTE: `Sources/Rune` does not yet wire `App.overlay(_:receiver:)` into `MacOSApp`, so `PREWARMED`
/// and `FADING` `OverlayHandle`s are created directly alongside the window on `@MainActor`.
@main
public enum RuneMaterialCheckApp {
    public struct State: Sendable {
        public var showPopover: Bool = false
        public var tick: Int = 0
        public init() {}
    }

    public struct Report: Sendable {
        public let mainMaterialCount: Int
        public let overlayPrewarmed: Bool
        public let overlayVisible: Bool
        public let overlayInstances: Int
    }

    private final class ProbeResult: @unchecked Sendable {
        private let lock = NSLock()
        var passed = true
        var messages: [String] = []

        func fail(_ msg: String) {
            lock.withLock {
                passed = false
                messages.append("FAIL: \(msg)")
            }
        }

        func pass(_ msg: String) {
            lock.withLock {
                messages.append("PASS: \(msg)")
            }
        }
    }

    public static func mainView(_ s: State, _: inout Cx<State>) -> El<State> {
        var cardChildren: [El<State>] = [
            el()
                .key("card-popover")
                .absolute(x: 20, y: 20)
                .size(120, 80)
                .rounded(12)
                .systemMaterial(.popover, blending: .behindWindow)
                .center()
                .child(
                    text("Popover")
                        .font(Tok.Typography.label)
                        .color(Color(r: 0.96, g: 0.97, b: 0.99, a: 1.0))
                ),
            el()
                .key("card-glass")
                .absolute(x: 160, y: 20)
                .size(120, 80)
                .rounded(12)
                .systemMaterial(.glass, blending: .behindWindow)
                .center()
                .child(
                    text("Glass")
                        .font(Tok.Typography.label)
                        .color(Color(r: 0.96, g: 0.97, b: 0.99, a: 1.0))
                ),
        ]

        if s.showPopover {
            cardChildren.append(
                el()
                    .key("card-dynamic-popover")
                    .absolute(x: 20, y: 120)
                    .size(260, 120)
                    .rounded(14)
                    .systemMaterial(.popover, blending: .behindWindow)
                    .center()
                    .child(
                        text("Mounted Popover #\(s.tick)")
                            .font(Tok.Typography.label)
                            .color(Color(r: 0.96, g: 0.97, b: 0.99, a: 1.0))
                    )
            )
        }

        return el()
            .wFull()
            .hFull()
            .bg(Color(r: 0.05, g: 0.05, b: 0.07, a: 0.5))
            .children(cardChildren)
    }

    public static func prewarmedOverlaySpec() -> ConfiguredOverlay<State> {
        OverlaySpec<State>(
            name: "PREWARMED",
            size: Vec2(300, 180),
            edge: .top,
            margin: 40,
            align: .center,
            interactive: false,
            options: OverlayOptions(
                placement: .edge(.top, margin: 40),
                keyPolicy: .nonActivating,
                input: .none,
                prewarm: true
            ),
            makeState: { State() },
            view: { _, _ in
                el()
                    .key("prewarmed-mat")
                    .wFull()
                    .hFull()
                    .rounded(16)
                    .systemMaterial(.hudWindow)
                    .center()
                    .child(text("Prewarmed HUD").font(Tok.Typography.label).color(.white))
            }
        )
        .configured(
            OverlayOptions(
                placement: .edge(.top, margin: 40),
                keyPolicy: .nonActivating,
                input: .none,
                prewarm: true
            )
        )
    }

    public static func fadingOverlaySpec() -> ConfiguredOverlay<State> {
        OverlaySpec<State>(
            name: "FADING",
            size: Vec2(260, 180),
            edge: .bottom,
            margin: 40,
            align: .center,
            interactive: false,
            options: OverlayOptions(
                placement: .edge(.bottom, margin: 40),
                keyPolicy: .nonActivating,
                input: .none,
                prewarm: false
            ),
            makeState: { State() },
            view: { _, _ in
                el()
                    .key("fading-mat")
                    .wFull()
                    .hFull()
                    .rounded(16)
                    .systemMaterial(.glass)
                    .center()
                    .child(text("Fading Glass").font(Tok.Typography.label).color(.white))
            }
        )
        .configured(
            OverlayOptions(
                placement: .edge(.bottom, margin: 40),
                keyPolicy: .nonActivating,
                input: .none,
                prewarm: false
            )
        )
    }

    @MainActor
    public static func main() throws {
        let app = App<State>(
            "Material Check",
            size: Vec2(400, 300),
            init: { State() },
            view: mainView
        )
        .accessory(true)
        .windowOptions(WindowOptions(
            transparent: true,
            borderless: true,
            position: (200, 200)
        ))

        let handle = app.handle()
        let result = ProbeResult()

        #if os(macOS)
        if !ToolingArgs.parse().isHeadlessRequested {
            let prewarmed = OverlayHandle(configured: prewarmedOverlaySpec())
            let fading = OverlayHandle(configured: fadingOverlaySpec())

            Thread.detachNewThread {
                // Wait for window appearance & initial settle.
                Thread.sleep(forTimeInterval: 0.35)

                let initialSnap = MainActor.assumeIsolatedOrSync { inspectWindow(title: "Material Check") }
                if initialSnap.materialViews.count < 2 {
                    result.fail("expected >= 2 initial material subviews, got \(initialSnap.materialViews.count)")
                } else if initialSnap.materialViews.contains(where: { $0.alpha == 0 }) {
                    result.fail("initial material subview had zero alpha")
                } else {
                    result.pass("initial material count=\(initialSnap.materialViews.count) occlusion=\(initialSnap.isVisible)")
                }
                let glassIdBefore = initialSnap.materialViews.first?.id

                // Mount dynamic popover, verify existing view identity survives.
                handle.update { s, _ in s.showPopover = true; s.tick &+= 1 }
                Thread.sleep(forTimeInterval: 0.12)
                let mountedSnap = MainActor.assumeIsolatedOrSync { inspectWindow(title: "Material Check") }
                if mountedSnap.materialViews.count < initialSnap.materialViews.count + 1 {
                    result.fail("popover mount did not add material view (\(mountedSnap.materialViews.count))")
                } else if let glassIdBefore, !mountedSnap.materialViews.contains(where: { $0.id == glassIdBefore }) {
                    result.fail("existing material view identity changed across popover mount")
                } else {
                    result.pass("popover mounted cleanly; preserved identity")
                }

                // Unmount + remount cycle.
                handle.update { s, _ in s.showPopover = false; s.tick &+= 1 }
                Thread.sleep(forTimeInterval: 0.08)
                handle.update { s, _ in s.showPopover = true; s.tick &+= 1 }
                Thread.sleep(forTimeInterval: 0.12)
                let remountSnap = MainActor.assumeIsolatedOrSync { inspectWindow(title: "Material Check") }
                if remountSnap.materialViews.contains(where: { $0.alpha == 0 }) {
                    result.fail("remounted material subview stuck at alpha=0")
                } else {
                    result.pass("unmount/remount alpha intact (count=\(remountSnap.materialViews.count))")
                }

                // Programmatic resize check + CAMetalLayer.presentsWithTransaction probe.
                handle.update { _, tx in tx.resizeWindow((520, 360)) }
                Thread.sleep(forTimeInterval: 0.15)
                let resizedSnap = MainActor.assumeIsolatedOrSync { inspectWindow(title: "Material Check") }
                if let glassIdBefore, !resizedSnap.materialViews.contains(where: { $0.id == glassIdBefore }) {
                    result.fail("material view identity lost across resize")
                } else {
                    result.pass("post-resize identity preserved (presentsWithTransaction=\(resizedSnap.presentsWithTransaction))")
                }

                // Exercise PREWARMED & FADING overlays.
                prewarmed.show()
                fading.fadeIn(0.18)
                Thread.sleep(forTimeInterval: 0.25)
                if !prewarmed.isVisible || !fading.isVisible {
                    result.fail("expected both PREWARMED and FADING overlays visible")
                } else {
                    result.pass("PREWARMED and FADING overlays visible")
                }
                prewarmed.hide()
                fading.hide()

                for line in result.messages { print(line) }
                handle.quit()
                if !result.passed {
                    #if canImport(Darwin)
                    Darwin.exit(1)
                    #endif
                }
            }
        }
        #endif

        try app.run()
        if !result.passed {
            #if canImport(Darwin)
            Darwin.exit(1)
            #endif
        }
    }

    public static func runHeadlessVerify() -> Report {
        let rt = Runtime<State>(
            state: State(),
            viewport: Vec2(400, 300),
            pixelScale: 2.0,
            view: mainView
        )
        rt.nativeMaterials = true
        let renderFrame = rt.renderFrame(at: 0.0)
        let prewarm = OverlayHandle(configured: prewarmedOverlaySpec())
        prewarm.show()
        let overlayScene = prewarm.runtime.frame(at: 0.0)
        return Report(
            mainMaterialCount: renderFrame.materials.count,
            overlayPrewarmed: prewarm.options.prewarm,
            overlayVisible: prewarm.isVisible,
            overlayInstances: overlayScene.primitives.count
        )
    }

    #if os(macOS)
    private struct MatViewSnapshot: Sendable {
        let id: ObjectIdentifier
        let className: String
        let alpha: CGFloat
    }

    private struct WindowSnapshot: Sendable {
        let materialViews: [MatViewSnapshot]
        let presentsWithTransaction: Bool
        let isVisible: Bool
    }

    @MainActor
    private static func inspectWindow(title: String) -> WindowSnapshot {
        guard let win = NSApplication.shared.windows.first(where: { $0.title == title }),
              let content = win.contentView else {
            return WindowSnapshot(materialViews: [], presentsWithTransaction: false, isVisible: false)
        }
        var mats: [MatViewSnapshot] = []
        var presentsTx = false
        func walk(_ view: NSView) {
            let cls = String(describing: type(of: view))
            if cls.contains("VisualEffect") || cls.contains("GlassEffect") {
                mats.append(MatViewSnapshot(id: ObjectIdentifier(view), className: cls, alpha: view.alphaValue))
            }
            if let ml = view.layer as? CAMetalLayer {
                presentsTx = presentsTx || ml.presentsWithTransaction
            }
            for sub in view.subviews {
                walk(sub)
            }
        }
        walk(content)
        let occluded = !win.occlusionState.contains(.visible)
        return WindowSnapshot(
            materialViews: mats,
            presentsWithTransaction: presentsTx,
            isVisible: !occluded
        )
    }
    #endif
}

#if os(macOS)
private extension MainActor {
    static func assumeIsolatedOrSync<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(body)
        }
    }
}
#endif
