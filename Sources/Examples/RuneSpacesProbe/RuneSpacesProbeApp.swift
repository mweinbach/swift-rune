import Foundation
import Rune
#if canImport(Darwin)
import Darwin
#endif
#if os(macOS)
import CoreGraphics
#endif

/// Windowless overlay Spaces / capture-exclusion / layer probe mirroring `crates/rune/examples/spaces_probe.rs`.
@main
public enum RuneSpacesProbeApp {
    public struct State: Sendable {
        public var phase: String = "init"
        public init() {}
    }

    public struct Report: Sendable {
        public let excludedOption: Bool
        public let prewarmOption: Bool
        public let visibleDuringShow: Bool
        public let sizeAfterResize: Vec2
        public let visibleAfterHide: Bool
        public let instances: Int
    }

    public final class WindowNumBox: @unchecked Sendable {
        private let lock = NSLock()
        private var number: UInt32?
        func set(_ n: UInt32?) { lock.withLock { number = n } }
        func get() -> UInt32? { lock.withLock { number } }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: String?
        func fail(_ msg: String) { lock.withLock { if error == nil { error = msg } } }
        func getError() -> String? { lock.withLock { error } }
    }

    public static func overlaySpec(createdBox: WindowNumBox? = nil) -> ConfiguredOverlay<State> {
        let opts = OverlayOptions(
            placement: .edge(.top, margin: 40),
            display: .primary,
            level: .status,
            excludeFromCapture: true,
            keyPolicy: .nonActivating,
            input: .none,
            prewarm: true
        )
        return OverlaySpec<State>(
            name: "Spaces Probe",
            size: Vec2(32, 32),
            edge: .top,
            margin: 40,
            align: .center,
            interactive: false,
            options: opts,
            makeState: { State() },
            view: { _, _ in
                el()
                    .wFull()
                    .hFull()
                    .rounded(8)
                    .bg(Color(r: 0.2, g: 0.55, b: 0.95, a: 0.9))
            }
        )
        .configured(opts)
        .onCreated { created in
            createdBox?.set(created.windowNumber)
        }
    }

    @MainActor
    public static func main() throws {
        QuitLifecycle.orderlyExit()
        let app = App<State>(
            "Spaces Probe",
            size: Vec2(32, 32),
            init: { State() },
            view: { _, _ in el().size(32, 32) }
        )
        .args([])
        .keepRunning(true)
        .windowless(true)

        let handle = app.handle()
        let createdBox = WindowNumBox()
        let resultBox = ResultBox()

        if !ToolingArgs.parse().isHeadlessRequested {
            let overlay = OverlayHandle(configured: overlaySpec(createdBox: createdBox))

            Thread.detachNewThread {
                func check(step: Int, expectVisible: Bool, expectMinLayer: Int = 25) {
                    Thread.sleep(forTimeInterval: 0.08)
                    let wid = overlay.windowNumber ?? createdBox.get()
                    #if os(macOS)
                    if let wid {
                        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
                        if let entry = list.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == wid }) {
                            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
                            let onscreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
                            if layer < expectMinLayer {
                                resultBox.fail("step \(step): kCGWindowLayer \(layer) < \(expectMinLayer)")
                            }
                            if expectVisible != onscreen {
                                resultBox.fail("step \(step): kCGWindowIsOnscreen=\(onscreen) != expected \(expectVisible)")
                            }
                        }
                    }
                    #endif
                    if overlay.isVisible != expectVisible {
                        resultBox.fail("step \(step): overlay.isVisible=\(overlay.isVisible) != expected \(expectVisible)")
                    }
                }

                // 12 timed transitions mirroring spaces_probe.rs
                overlay.show()
                check(step: 1, expectVisible: true)
                overlay.hide()
                check(step: 2, expectVisible: false)
                overlay.fadeIn(0.05)
                check(step: 3, expectVisible: true)
                overlay.resize(Vec2(120, 48))
                check(step: 4, expectVisible: true)
                overlay.setExcludeFromCapture(false)
                check(step: 5, expectVisible: true)
                overlay.setExcludeFromCapture(true)
                check(step: 6, expectVisible: true)
                overlay.fadeOut(0.05)
                Thread.sleep(forTimeInterval: 0.08)
                overlay.hide()
                check(step: 7, expectVisible: false)
                overlay.show()
                check(step: 8, expectVisible: true)
                overlay.resize(Vec2(340, 64))
                check(step: 9, expectVisible: true)
                overlay.hide()
                check(step: 10, expectVisible: false)
                overlay.show()
                check(step: 11, expectVisible: true)
                overlay.hide()
                check(step: 12, expectVisible: false)

                if let err = resultBox.getError() {
                    print("spaces_probe: FAIL \(err)")
                } else {
                    print("spaces_probe: PASS 12/12 checks")
                }
                handle.quit()
            }
        }

        try app.run()
        if let err = resultBox.getError() {
            RuneStandardIO.error("spaces_probe assertion failed: \(err)\n")
            #if canImport(Darwin)
            Darwin.exit(1)
            #endif
        }
    }

    public static func runHeadlessVerify() -> Report {
        let overlay = OverlayHandle(configured: overlaySpec())
        let excludedOption = overlay.options.excludeFromCapture
        let prewarmOption = overlay.options.prewarm
        overlay.show()
        let visibleDuringShow = overlay.isVisible
        overlay.resize(Vec2(340, 64))
        let sizeAfterResize = overlay.size
        let scene = overlay.runtime.frame(at: 0.0)
        overlay.hide()
        let visibleAfterHide = overlay.isVisible
        return Report(
            excludedOption: excludedOption,
            prewarmOption: prewarmOption,
            visibleDuringShow: visibleDuringShow,
            sizeAfterResize: sizeAfterResize,
            visibleAfterHide: visibleAfterHide,
            instances: scene.primitives.count
        )
    }
}
