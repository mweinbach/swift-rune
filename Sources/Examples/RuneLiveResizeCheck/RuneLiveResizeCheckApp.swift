import Foundation
import Rune
#if canImport(Darwin)
import Darwin
#endif
#if os(macOS)
import AppKit
import Metal
import ObjectiveC.runtime
import QuartzCore
#endif

/// Automated live-resize check probe mirroring `crates/rune/examples/live_resize_check.rs`.
@main
public enum RuneLiveResizeCheckApp {
    public struct State: Sendable {
        public var width: Float = 480
        public var height: Float = 400
        public var step: Int = 0
        public init() {}
    }

    public struct Report: Sendable {
        public let compositorFrames: Int
        public let barRights: [Float]
        public let widths: [Float]
    }

    public final class SlowCompositor: Compositor, @unchecked Sendable {
        public typealias State = RuneLiveResizeCheckApp.State
        private let lock = NSLock()
        public let slowMs: UInt64
        nonisolated(unsafe) public var inLiveResize: Bool = false
        private var _renderedCount: Int = 0

        public init(slowMs: UInt64) {
            self.slowMs = slowMs
        }

        public var renderedCount: Int {
            lock.withLock { _renderedCount }
        }

        public func render(frame: CompositorFrame<State>) {
            lock.withLock { _renderedCount &+= 1 }
            if inLiveResize && slowMs > 0 {
                Thread.sleep(forTimeInterval: Double(slowMs) / 1000.0)
            }
            frame.drawUI()
        }
    }

    private final class DrawableProbe: @unchecked Sendable {
        static let shared = DrawableProbe()
        private let lock = NSLock()
        nonisolated(unsafe) private var swizzled = false
        nonisolated(unsafe) private var nextDrawableCalls: Int = 0
        nonisolated(unsafe) private var maxWaitMs: Double = 0

        #if os(macOS)
        private typealias NextFn = @convention(c) (AnyObject, Selector) -> AnyObject?
        #endif

        func install() {
            #if os(macOS)
            lock.withLock {
                guard !swizzled else { return }
                swizzled = true
                guard let cls = NSClassFromString("CAMetalLayer"),
                      let m = class_getInstanceMethod(cls, NSSelectorFromString("nextDrawable")) else { return }
                let orig = method_getImplementation(m)
                let block: @convention(block) (AnyObject) -> AnyObject? = { obj in
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let drawable = unsafeBitCast(orig, to: NextFn.self)(obj, NSSelectorFromString("nextDrawable"))
                    let waitMs = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6
                    DrawableProbe.shared.lock.withLock {
                        DrawableProbe.shared.nextDrawableCalls &+= 1
                        if waitMs > DrawableProbe.shared.maxWaitMs {
                            DrawableProbe.shared.maxWaitMs = waitMs
                        }
                    }
                    return drawable
                }
                method_setImplementation(m, imp_implementationWithBlock(block))
            }
            #endif
        }

        func snapshot() -> (calls: Int, maxWaitMs: Double) {
            lock.withLock { (nextDrawableCalls, maxWaitMs) }
        }
    }

    public static func liveView(_ s: State, _: inout Cx<State>) -> El<State> {
        col()
            .key("live-resize-root")
            .wFull()
            .hFull()
            .bg(Color(r: 0.08, g: 0.09, b: 0.12, a: 1.0))
            .gap(12)
            .children([
                row()
                    .key("top-bar")
                    .wFull()
                    .h(44)
                    .justifyBetween()
                    .centerY()
                    .bg(Color(r: 0.14, g: 0.17, b: 0.22, a: 1.0))
                    .children([
                        row().key("bar-left").px(12).gap(8).centerY().child(
                            text("Live Resize Check").font(Tok.Typography.title).color(.white)
                        ),
                        row().key("bar-right").px(12).gap(8).centerY().child(
                            text("\(Int(s.width))×\(Int(s.height))")
                                .font(Tok.Typography.label)
                                .color(Color(r: 0.75, g: 0.85, b: 1.0, a: 1.0))
                        ),
                    ]),
                col()
                    .grow(1.0)
                    .p(16)
                    .child(
                        el()
                            .grow(1.0)
                            .rounded(12)
                            .bg(Color(r: 0.11, g: 0.13, b: 0.17, a: 1.0))
                            .border(1, Color(r: 1, g: 1, b: 1, a: 0.08))
                            .center()
                            .child(
                                text("Step \(s.step)")
                                    .font(Tok.Typography.body)
                                    .color(Color(r: 0.86, g: 0.88, b: 0.94, a: 1.0))
                            )
                    ),
            ])
    }

    @MainActor
    public static func main() throws {
        let env = ProcessInfo.processInfo.environment
        let slowMs = UInt64(env["RUNE_LIVE_RESIZE_SLOW_MS"] ?? "") ?? 18
        let events = max(2, Int(env["RUNE_LIVE_RESIZE_EVENTS"] ?? "") ?? 6)

        DrawableProbe.shared.install()
        let comp = SlowCompositor(slowMs: slowMs)
        let app = App<State>(
            "Live Resize Check",
            size: Vec2(480, 400),
            init: { State() },
            view: liveView
        )
        .minSize(200, 200)
        .compositor(comp)

        let handle = app.handle()
        let probePassed = LockBox(true)

        #if os(macOS)
        if !ToolingArgs.parse().isHeadlessRequested {
            final class ObserverState: @unchecked Sendable {
                private let lock = NSLock()
                var frameChanges = 0
                nonisolated(unsafe) var observer: NSObjectProtocol?
                func inc() { lock.withLock { frameChanges &+= 1 } }
                func count() -> Int { lock.withLock { frameChanges } }
            }

            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.35)
                var failures: [String] = []
                let obsState = ObserverState()

                let initMsg: String? = DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        guard let win = NSApplication.shared.windows.first(where: { $0.title == "Live Resize Check" }),
                              let cv = win.contentView else {
                            return "missing Live Resize Check NSWindow"
                        }
                        obsState.observer = NotificationCenter.default.addObserver(
                            forName: NSView.frameDidChangeNotification,
                            object: cv,
                            queue: .main
                        ) { _ in
                            obsState.inc()
                        }

                        @MainActor func findMetalLayer(_ v: NSView) -> CAMetalLayer? {
                            if let ml = v.layer as? CAMetalLayer { return ml }
                            for sub in v.subviews {
                                if let found = findMetalLayer(sub) { return found }
                            }
                            return nil
                        }
                        if let ml = findMetalLayer(cv) {
                            if ml.contentsGravity != .topLeft && ml.contentsGravity != .bottomLeft {
                                return "unexpected CAMetalLayer.contentsGravity=\(ml.contentsGravity.rawValue)"
                            }
                            if abs(ml.contentsScale - win.backingScaleFactor) > 0.01 {
                                return "contentsScale \(ml.contentsScale) != backingScaleFactor \(win.backingScaleFactor)"
                            }
                            if ml.presentsWithTransaction {
                                return "idle presentsWithTransaction unexpectedly true"
                            }
                        }
                        return nil
                    }
                }
                if let initMsg { failures.append(initMsg) }

                comp.inLiveResize = true
                for i in 1...events {
                    let w = Float(480 + i * 14)
                    let h = Float(400 + i * 10)
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            if let win = NSApplication.shared.windows.first(where: { $0.title == "Live Resize Check" }) {
                                let f = win.frame
                                let dragPt = NSPoint(x: f.width - 2, y: 2)
                                if let ev = NSEvent.mouseEvent(
                                    with: i == 1 ? .leftMouseDown : (i == events ? .leftMouseUp : .leftMouseDragged),
                                    location: dragPt,
                                    modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: win.windowNumber,
                                    context: nil,
                                    eventNumber: i,
                                    clickCount: 1,
                                    pressure: i == events ? 0 : 1
                                ) {
                                    NSApplication.shared.sendEvent(ev)
                                }
                            }
                        }
                    }
                    handle.update { s, tx in
                        s.width = w
                        s.height = h
                        s.step &+= 1
                        tx.resizeWindow((w, h))
                    }
                    Thread.sleep(forTimeInterval: 0.03)
                }
                comp.inLiveResize = false

                handle.update { s, tx in
                    s.width = 560
                    s.height = 460
                    tx.resizeWindow((560, 460))
                }
                Thread.sleep(forTimeInterval: 0.08)
                handle.update { s, tx in
                    s.width = 480
                    s.height = 400
                    tx.resizeWindow((480, 400))
                }
                Thread.sleep(forTimeInterval: 0.10)

                DispatchQueue.main.sync {
                    if let observer = obsState.observer {
                        NotificationCenter.default.removeObserver(observer)
                        obsState.observer = nil
                    }
                }

                let snap = DrawableProbe.shared.snapshot()
                if snap.maxWaitMs >= 50.0 {
                    failures.append(String(format: "nextDrawable max wait %.1fms >= 50ms", snap.maxWaitMs))
                }
                if comp.renderedCount == 0 {
                    failures.append("compositor recorded 0 frames")
                }

                if failures.isEmpty {
                    print(String(
                        format: "live_resize_check: PASS compositor_frames=%d drawables=%d max_wait=%.1fms frame_changes=%d",
                        comp.renderedCount, snap.calls, snap.maxWaitMs, obsState.count()
                    ))
                } else {
                    probePassed.set(false)
                    for f in failures {
                        print("live_resize_check: FAIL \(f)")
                    }
                }
                handle.quit()
            }
        }
        #endif

        try app.run()
        if !probePassed.get() {
            #if canImport(Darwin)
            Darwin.exit(1)
            #endif
        }
    }

    public static func runHeadlessVerify() -> Report {
        let comp = SlowCompositor(slowMs: 0)
        let sizes: [(Float, Float)] = [(480, 400), (560, 400), (640, 420), (480, 400)]
        let rt = Runtime<State>(
            state: State(),
            viewport: Vec2(480, 400),
            pixelScale: 2.0,
            view: liveView
        )
        var barRights: [Float] = []
        var widths: [Float] = []
        for (idx, sz) in sizes.enumerated() {
            rt.update(at: Double(idx) * 0.05) { s, _ in
                s.width = sz.0
                s.height = sz.1
                s.step = idx
            }
            rt.setViewport(Vec2(sz.0, sz.1))
            let f = CompositorFrame<State>(
                deviceKey: DeviceKey.next(),
                pixelSize: (Int(sz.0 * 2), Int(sz.1 * 2)),
                dt: 1.0 / 60.0,
                updateMilliseconds: 0.1,
                srgbBlend: true,
                runtime: rt,
                drawUI: { _ = rt.frame(at: Double(idx) * 0.05) }
            )
            comp.render(frame: f)
            if let rect = rt.element(byKey: "bar-right")?.rect, rect.count >= 3 {
                barRights.append(rect[0] + rect[2])
            }
            widths.append(sz.0)
        }
        return Report(compositorFrames: comp.renderedCount, barRights: barRights, widths: widths)
    }

    private final class LockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ v: Bool) { self.value = v }
        func set(_ v: Bool) { lock.withLock { value = v } }
        func get() -> Bool { lock.withLock { value } }
    }
}
