import Foundation
import Rune
#if os(macOS)
import AppKit
#endif

/// Live accessory overlay pacing probe mirroring `crates/rune/examples/pacing_overlay.rs`.
@main
public enum RunePacingOverlayApp {
    public struct State: Sendable {
        public init() {}
    }

    public struct Report: Sendable {
        public let visibleOnFadeIn: Bool
        public let visibleAfterFadeOut: Bool
        public let overlayInstances: Int
    }

    private static let chips = ["Area", "Window", "Screen", "iPhone", "Paste", "×"]

    public static func overlayView(nativePulse: Bool = ProcessInfo.processInfo.environment["PACING_NATIVE"] == "1") -> El<State> {
        var chipEls: [El<State>] = []
        chipEls.reserveCapacity(chips.count)
        for (idx, label) in chips.enumerated() {
            let accent = idx == 0
            var chip: El<State> = row()
                .key("chip-\(idx)")
                .px(14)
                .h(32)
                .centerY()
                .rounded(16)
                .bg(accent ? Color(r: 0.28, g: 0.56, b: 1.0, a: 0.92) : Color(r: 1, g: 1, b: 1, a: 0.12))
                .border(1, Color(r: 1, g: 1, b: 1, a: accent ? 0.35 : 0.14))
                .child(
                    text(label)
                        .font(Tok.Typography.label)
                        .color(Color(r: 0.97, g: 0.98, b: 1.0, a: 1.0))
                )
            if nativePulse && idx == 0 {
                chip = chip.looping(LoopSpec.opacity(period: 2.0, delay: 0.0, low: 0.8, high: 1.0))
            }
            chipEls.append(chip)
        }

        let bar = row()
            .key("pacing-overlay-pill")
            .px(12)
            .h(48)
            .gap(8)
            .centerY()
            .rounded(24)
            .bg(Color(r: 0.09, g: 0.10, b: 0.14, a: 0.86))
            .border(1, Color(r: 1, g: 1, b: 1, a: 0.16))
            .shadow(Shadow(x: 0, y: 12, blur: 28, spread: 0, color: Color(r: 0, g: 0, b: 0, a: 0.45)))
            .children(chipEls)

        return row()
            .wFull()
            .hFull()
            .center()
            .child(bar)
    }

    public static func overlaySpec(nativePulse: Bool = ProcessInfo.processInfo.environment["PACING_NATIVE"] == "1") -> ConfiguredOverlay<State> {
        OverlaySpec<State>(
            name: "Pacing Overlay",
            size: Vec2(680, 160),
            edge: .top,
            margin: 40,
            align: .center,
            interactive: false,
            options: OverlayOptions(
                placement: .edge(.top, margin: 40),
                display: .primary,
                level: .status,
                keyPolicy: .nonActivating,
                input: .none,
                prewarm: true,
                interactive: false
            ),
            makeState: { State() },
            view: { _, _ in overlayView(nativePulse: nativePulse) }
        )
        .configured(
            OverlayOptions(
                placement: .edge(.top, margin: 40),
                display: .primary,
                level: .status,
                keyPolicy: .nonActivating,
                input: .none,
                prewarm: true,
                interactive: false
            )
        )
    }

    @MainActor
    public static func main() throws {
        let nativePulse = ProcessInfo.processInfo.environment["PACING_NATIVE"] == "1"
        let hostApp = App<State>(
            "Pacing Overlay",
            size: Vec2(680, 160),
            init: { State() },
            view: { _, _ in overlayView(nativePulse: nativePulse) }
        )
        .args([])
        .accessory(true)
        .windowless(true)
        .keepRunning(true)

        let hostHandle = hostApp.handle()
        let windowSpec = AppWindowSpec.fromApp(hostApp)
            .options(WindowOptions(transparent: true, borderless: true, visible: false))
            .keepRunning(true)

        let isHeadless = ToolingArgs.parse().isHeadlessRequested
        var overlay: OverlayHandle<State>?
        if !isHeadless {
            let handle = OverlayHandle(configured: overlaySpec(nativePulse: nativePulse))
            handle.fadeIn(0.28)
            overlay = handle

            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 14.0)
                handle.fadeOut(0.22)
                Thread.sleep(forTimeInterval: 0.30)
                hostHandle.quit()
                #if os(macOS)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        NSApplication.shared.terminate(nil)
                    }
                }
                #endif
            }
        }

        _ = overlay
        try RuneMultiWindow.runWindows(
            [AnyWindowSpec(windowSpec)],
            options: RunOptions(arguments: [], accessory: true)
        )
    }

    public static func runHeadlessVerify() -> Report {
        let handle = OverlayHandle(configured: overlaySpec(nativePulse: true))
        handle.fadeIn(0.28)
        let visibleIn = handle.isVisible
        let scene = handle.runtime.frame(at: 0.0)
        handle.fadeOut(0.22)
        let pastFade = handle.overlayPresence.fadeEnd ?? Date().timeIntervalSinceReferenceDate
        handle.advanceDue(at: pastFade + 0.05)
        let visibleOut = handle.isVisible || handle.overlayPresence.isDrawing
        return Report(
            visibleOnFadeIn: visibleIn,
            visibleAfterFadeOut: visibleOut,
            overlayInstances: scene.primitives.count
        )
    }
}
