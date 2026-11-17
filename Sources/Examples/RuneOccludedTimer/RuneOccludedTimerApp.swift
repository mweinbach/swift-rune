import Foundation
import Rune

public final class OccludedTimerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired: Int = 0
    private var _worstMs: Int = 0

    public init() {}

    public func incrementFired() {
        lock.lock()
        _fired += 1
        lock.unlock()
    }

    public func recordWorstMs(_ ms: Int) {
        lock.lock()
        _worstMs = max(_worstMs, ms)
        lock.unlock()
    }

    public var fired: Int {
        lock.lock()
        defer { lock.unlock() }
        return _fired
    }

    public var worstMs: Int {
        lock.lock()
        defer { lock.unlock() }
        return _worstMs
    }
}

public struct OccludedTimerState: Sendable {
    public var next: Double = 0.0
    public var armedAt: Date? = nil
    public var updatesMode: Bool
    public var counter: OccludedTimerCounter

    public init(updatesMode: Bool = false, counter: OccludedTimerCounter = OccludedTimerCounter()) {
        self.updatesMode = updatesMode
        self.counter = counter
    }
}

private final class OccludedTimerRetainer: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OverlayHandle<OccludedTimerState>?

    func hold(_ handle: OverlayHandle<OccludedTimerState>) {
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
public enum RuneOccludedTimerApp {
    public static let period: Double = 0.1
    public static let armedDuration: Double = 0.1

    public static func view(_ s: OccludedTimerState, _ cx: inout Cx<OccludedTimerState>) -> El<OccludedTimerState> {
        _ = cx
        return el()
            .key("pill")
            .hit()
            .p(12)
            .rounded(16)
            .bg(Color(r: 0.1, g: 0.12, b: 0.16, a: 0.95))
            .child(text("fired \(s.counter.fired)").color(.white))
    }

    public static func poll(_ s: inout OccludedTimerState, at t: Double, _ tx: inout Tx) -> Bool {
        if s.updatesMode {
            return pollArmed(&s)
        }
        let fired = t >= s.next
        if fired {
            s.counter.incrementFired()
            s.next = t + period
        }
        tx.wakeAfter(max(0.0, s.next - t))
        return fired
    }

    public static func pollArmed(_ s: inout OccludedTimerState, now: Date = Date()) -> Bool {
        guard let armedAt = s.armedAt else { return false }
        let elapsed = now.timeIntervalSince(armedAt)
        guard elapsed >= armedDuration else { return false }
        s.armedAt = nil
        s.counter.incrementFired()
        s.counter.recordWorstMs(Int(elapsed * 1000.0))
        return true
    }

    public static func arm(_ s: inout OccludedTimerState, _ tx: inout Tx, now: Date = Date()) {
        s.armedAt = now
        tx.wakeAfter(armedDuration)
    }

    public static func makeOverlaySpec(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        counter: OccludedTimerCounter = OccludedTimerCounter()
    ) -> ConfiguredOverlay<OccludedTimerState> {
        let updates = environment["OCCLUDED_TIMER_UPDATE"] != nil
        let input: OverlayInput = environment["OCCLUDED_TIMER_REGIONS"] != nil ? .regions : .all
        let edge: ScreenEdge = environment["OCCLUDED_TIMER_BOTTOM"] != nil ? .bottom : .top
        let prewarm = environment["OCCLUDED_TIMER_PREWARM"] != nil

        return OverlaySpec<OccludedTimerState>(
            name: "Occluded timer",
            size: Vec2(220, 60),
            edge: edge,
            makeState: { OccludedTimerState(updatesMode: updates, counter: counter) },
            view: view
        )
        .configured(OverlayOptions(input: input, prewarm: prewarm))
        .poll { s, t, tx in
            poll(&s, at: t, &tx)
        }
    }

    public static func makeApp(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> App<OccludedTimerState> {
        let isHeadless = ToolingArgs.parse(arguments).isHeadlessRequested || arguments.contains("--headless")
        let windowMode = environment["OCCLUDED_TIMER_WINDOW"] != nil
        let updates = environment["OCCLUDED_TIMER_UPDATE"] != nil
        let bottom = environment["OCCLUDED_TIMER_BOTTOM"] != nil
        let quitSeconds = environment["OCCLUDED_TIMER_SECONDS"].flatMap(Int.init)
        let counter = OccludedTimerCounter()

        if windowMode || isHeadless {
            let x: Int32 = bottom ? 900 : 100
            var app = App<OccludedTimerState>(
                "Occluded timer",
                size: windowMode ? Vec2(420, 400) : Vec2(220, 60),
                init: { OccludedTimerState(updatesMode: updates, counter: counter) },
                view: view
            )
            .accessory(true)
            .args(arguments)
            .windowOptions(WindowOptions(position: (x, 200)))
            .poll { s, t, tx in
                poll(&s, at: t, &tx)
            }

            if !isHeadless {
                let commands = app.handle()
                app = app.setup { _ in
                    startReporter(counter: counter, quitSeconds: quitSeconds, onQuit: { commands.quit() }) {
                        if updates {
                            commands.update { s, tx in
                                arm(&s, &tx)
                            }
                        }
                    }
                }
            }
            return app
        }

        let retainer = OccludedTimerRetainer()
        var app = App<OccludedTimerState>(
            "Occluded timer",
            size: Vec2(1, 1),
            init: { OccludedTimerState(updatesMode: updates, counter: counter) },
            view: view
        )
        .windowless(true)
        .accessory(true)
        .args(arguments)

        let commands = app.handle()
        app = app
            .onQuit { _, _ in
                retainer.release()
            }
            .setup { _ in
                let overlay = OverlayHandle(configured: makeOverlaySpec(environment: environment, counter: counter))
                retainer.hold(overlay)
                overlay.show()
                startReporter(counter: counter, quitSeconds: quitSeconds, onQuit: {
                    retainer.release()
                    commands.quit()
                }) {
                    if updates {
                        overlay.updateTx { s, tx in
                            arm(&s, &tx)
                        }
                    }
                }
            }
        return app
    }

    private static func startReporter(
        counter: OccludedTimerCounter,
        quitSeconds: Int?,
        onQuit: @escaping @Sendable () -> Void,
        onTick: @escaping @Sendable () -> Void
    ) {
        Thread.detachNewThread {
            let start = Date()
            while true {
                Thread.sleep(forTimeInterval: 1.0)
                let elapsed = Int(Date().timeIntervalSince(start))
                RuneStandardIO.error("occluded-timer t=\(elapsed) fired=\(counter.fired) worst_ms=\(counter.worstMs)\n")
                if let quitSeconds, elapsed >= quitSeconds {
                    onQuit()
                    return
                }
                onTick()
            }
        }
    }

    @MainActor
    public static func main() throws {
        try RuneApp.run(makeApp())
    }
}
