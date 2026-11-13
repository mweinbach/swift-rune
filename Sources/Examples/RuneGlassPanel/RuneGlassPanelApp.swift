import Foundation
import Rune

public enum GlassPanelRole: Sendable, Equatable {
    case backdrop
    case flight
    case dock
}

public enum GlassPanelConfig {
    /// The flight window's size. Reaches the top of the screen so the arc passes over the menu bar.
    public static let flightWindow = Vec2(1000.0, 640.0)
    /// Start and dock card rects inside the flight window, with corner radii.
    public static let startRect = MotionRect.fromXYWH(120.0, 300.0, 420.0, 236.0)
    public static let dockRect = MotionRect.fromXYWH(600.0, 64.0, 320.0, 92.0)
    public static let startRadius: Float = 26.0
    public static let dockRadius: Float = 18.0
    /// Room for the shadows around the docked card in its own window.
    public static let margin: Float = 48.0
    public static let flightSeconds: Double = 0.6
    /// The landed card holds still this long in the flight window before the hand-off.
    public static let holdSeconds: Double = 0.15
    public static let black = Color(r: 0.0, g: 0.0, b: 0.0, a: 1.0)

    public static var dockWindowSize: Vec2 {
        Vec2(dockRect.width + 2.0 * margin, dockRect.height + 2.0 * margin)
    }

    public static func defaultPlacementOrigin(environment: [String: String] = ProcessInfo.processInfo.environment) -> (Float, Float) {
        if let raw = environment["GLASS_PANEL_AT"] {
            let parts = raw.split(separator: ",", maxSplits: 1)
            if parts.count == 2,
               let x = Float(parts[0].trimmingCharacters(in: .whitespaces)),
               let y = Float(parts[1].trimmingCharacters(in: .whitespaces)) {
                return (x, y)
            }
        }
        return (360.0, 0.0)
    }
}

public struct GlassPanelState: Sendable {
    public var role: GlassPanelRole
    public var material: SystemMaterial
    /// Start flying on the next frame.
    public var fly: Bool = false
    public var started: Double? = nil
    public var landed: Double? = nil
    public var handed: Bool = false
    public var now: Double = 0.0
    public var frames: UInt32 = 0
    /// `GLASS_PANEL_MARK`: a few marker pixels beside the docked card, magenta from the
    /// docked window and cyan from the flight window, to find the hand-off in a recording.
    public var mark: Bool
    /// Headless `--scene` support: renders backdrop + card in a single runtime when true.
    public var headlessPreview: Bool = false
    public var previewT: Float? = nil

    public init(
        role: GlassPanelRole = .flight,
        material: SystemMaterial = ProcessInfo.processInfo.environment["GLASS_PANEL_POPOVER"] != nil ? .popover : .glass,
        fly: Bool = false,
        started: Double? = nil,
        landed: Double? = nil,
        handed: Bool = false,
        now: Double = 0.0,
        frames: UInt32 = 0,
        mark: Bool = ProcessInfo.processInfo.environment["GLASS_PANEL_MARK"] != nil,
        headlessPreview: Bool = false,
        previewT: Float? = nil
    ) {
        self.role = role
        self.material = material
        self.fly = fly
        self.started = started
        self.landed = landed
        self.handed = handed
        self.now = now
        self.frames = frames
        self.mark = mark
        self.headlessPreview = headlessPreview
        self.previewT = previewT
    }
}

public final class GlassPanelCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let handedCond = NSCondition()
    private var handedFlag = false
    private var stopped = false
    public var flight: OverlayHandle<GlassPanelState>?
    public var dock: OverlayHandle<GlassPanelState>?
    public var backdrop: OverlayHandle<GlassPanelState>?

    public init() {}

    public func install(
        backdrop: OverlayHandle<GlassPanelState>,
        flight: OverlayHandle<GlassPanelState>,
        dock: OverlayHandle<GlassPanelState>
    ) {
        lock.lock()
        self.backdrop = backdrop
        self.flight = flight
        self.dock = dock
        lock.unlock()
    }

    public func notifyHandOff() {
        lock.lock()
        let flight = self.flight
        let dock = self.dock
        lock.unlock()
        dock?.show()
        flight?.hide()

        handedCond.lock()
        handedFlag = true
        handedCond.broadcast()
        handedCond.unlock()
    }

    public func resetHandOff() {
        handedCond.lock()
        handedFlag = false
        handedCond.unlock()
    }

    public func waitForHandOff() {
        handedCond.lock()
        while !handedFlag && !stopped {
            handedCond.wait()
        }
        handedCond.unlock()
    }

    public func stop() {
        handedCond.lock()
        stopped = true
        handedCond.broadcast()
        handedCond.unlock()
    }

    public var isStopped: Bool {
        handedCond.lock()
        defer { handedCond.unlock() }
        return stopped
    }
}

private final class GlassPanelRetainer: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [OverlayHandle<GlassPanelState>] = []
    private var coordinator: GlassPanelCoordinator?

    func hold(handles: [OverlayHandle<GlassPanelState>], coordinator: GlassPanelCoordinator) {
        lock.lock()
        self.handles = handles
        self.coordinator = coordinator
        lock.unlock()
    }

    func release() {
        lock.lock()
        let coord = coordinator
        let old = handles
        handles = []
        coordinator = nil
        lock.unlock()
        coord?.stop()
        for h in old {
            h.hide()
        }
    }
}

@main
public enum RuneGlassPanelApp {
    public static func ease(_ t: Float) -> Float {
        let clamped = min(max(t, 0.0), 1.0)
        return clamped * clamped * (3.0 - 2.0 * clamped)
    }

    public static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    /// The card at flight time `t` (0 to 1): its rect, corner radius and lift.
    /// Width leads height, and the centre rides an arc that rises over the dock before it settles.
    public static func flightFrame(_ t: Float) -> (rect: MotionRect, radius: Float, lift: Float) {
        let p = ease(t)
        let w = lerp(GlassPanelConfig.startRect.width, GlassPanelConfig.dockRect.width, ease(t * 1.25))
        let h = lerp(GlassPanelConfig.startRect.height, GlassPanelConfig.dockRect.height, ease(t * 1.25 - 0.25))

        let fromX = GlassPanelConfig.startRect.x + GlassPanelConfig.startRect.width * 0.5
        let fromY = GlassPanelConfig.startRect.y + GlassPanelConfig.startRect.height * 0.5
        let toX = GlassPanelConfig.dockRect.x + GlassPanelConfig.dockRect.width * 0.5
        let toY = GlassPanelConfig.dockRect.y + GlassPanelConfig.dockRect.height * 0.5
        let ctrlX = lerp(fromX, toX, 0.6)
        let ctrlY: Float = 0.0

        let omp = 1.0 - p
        let cx = omp * omp * fromX + 2.0 * p * omp * ctrlX + p * p * toX
        let cy = omp * omp * fromY + 2.0 * p * omp * ctrlY + p * p * toY

        let radius = lerp(GlassPanelConfig.startRadius, GlassPanelConfig.dockRadius, p)
        let lift = sinf(.pi * p)
        return (
            MotionRect.fromXYWH(cx - w * 0.5, cy - h * 0.5, w, h),
            radius,
            lift
        )
    }

    /// Steps the flight from the frame clock, and hands off once the card has held still.
    public static func pollFlight(
        _ s: inout GlassPanelState,
        at now: Double,
        _ tx: inout Tx,
        coordinator: GlassPanelCoordinator?
    ) -> Bool {
        _ = tx
        if s.fly {
            s.fly = false
            s.started = now
            s.landed = nil
            s.handed = false
            s.frames = 0
        }
        guard let started = s.started else { return false }
        if s.handed { return false }
        s.now = now
        s.frames &+= 1
        if s.landed == nil && now - started >= GlassPanelConfig.flightSeconds {
            s.landed = now
            let elapsed = String(format: "%.3f", now - started)
            fputs("glass-panel: flight drew \(s.frames) frames in \(elapsed) s\n", stderr)
        }
        if let landed = s.landed, now - landed >= GlassPanelConfig.holdSeconds {
            s.handed = true
            coordinator?.notifyHandOff()
        }
        return true
    }

    private static func buttonView(_ label: String, ink: Color, fillAlpha: Float) -> El<GlassPanelState> {
        row()
            .key(label)
            .role(.button)
            .label(label)
            .h(30)
            .px(14)
            .center()
            .continuousRounded(9)
            .bg(ink.alpha(fillAlpha))
            .child(
                text(label)
                    .font(TextStyle(size: 13.0, weight: 560.0))
                    .color(ink.alpha(0.847))
            )
    }

    private static func markerView(x: Float, y: Float, color: Color) -> El<GlassPanelState> {
        el()
            .key("mark")
            .absolute(x: x, y: y)
            .size(4, 4)
            .bg(color)
    }

    /// Colour tiles and sweeping bars behind the flight, so the glass has something to bend.
    public static func backdropView() -> El<GlassPanelState> {
        let w = GlassPanelConfig.flightWindow.x
        let h = GlassPanelConfig.flightWindow.y
        let cols = 20
        let rows = 13
        let tileW = w / Float(cols)
        let tileH = h / Float(rows)

        var children: [El<GlassPanelState>] = []
        children.reserveCapacity(cols * rows + 4)

        for i in 0..<(cols * rows) {
            let c = i % cols
            let r = i / cols
            let light: Float = (c + r).isMultiple(of: 2) ? 0.8 : 0.5
            let hue = Float((i * 23) % 360)
            children.append(
                el()
                    .absolute(x: Float(c) * tileW, y: Float(r) * tileH)
                    .size(tileW, tileH)
                    .bg(oklch(light, 0.14, hue))
            )
        }

        for k in 0..<4 {
            children.append(
                el()
                    .absolute(x: 0, y: 0)
                    .size(30, h)
                    .bg(k.isMultiple(of: 2) ? .white : GlassPanelConfig.black)
                    .loopSlide(
                        period: 4.8,
                        from: Vec2(-1.0, 0.0),
                        to: Vec2(w / 30.0, 0.0),
                        delay: Double(k) * 0.8
                    )
            )
        }

        return el()
            .key("backdrop")
            .wFull()
            .hFull()
            .children(children)
    }

    /// The card: glass, frost, hairline and contents, clipped with continuous corners,
    /// over two shadows that deepen and spread with `lift`.
    public static func cardView(
        _ s: GlassPanelState,
        dark: Bool,
        rect: MotionRect,
        radius: Float,
        lift: Float,
        docked: Bool
    ) -> El<GlassPanelState> {
        let ink: Color = dark ? .white : GlassPanelConfig.black
        let frostBase = dark ? (Color.hex("#1e1e1e") ?? GlassPanelConfig.black) : .white
        let frost = frostBase.alpha(0.62)
        let swapTransition = Transition(
            insertion: TransitionEffect(zeroOpacity: 0, zeroScale: Vec2(0.96, 0.96), zeroBlur: 3.0),
            removal: TransitionEffect(zeroOpacity: 0, zeroScale: Vec2(0.96, 0.96), zeroBlur: 3.0)
        )

        let content: El<GlassPanelState>
        if docked {
            content = row()
                .key("docked")
                .absolute(x: 0, y: 0)
                .size(GlassPanelConfig.dockRect.width, GlassPanelConfig.dockRect.height)
                .px(20)
                .gap(12)
                .itemsCenter()
                .transition(swapTransition)
                .child(
                    col()
                        .gap(3)
                        .child(
                            text("Waiting for access")
                                .font(TextStyle(size: 15.0, weight: 620.0))
                                .color(ink.alpha(0.847))
                        )
                        .child(
                            text("Turn it on in System Settings")
                                .font(TextStyle(size: 12.0, weight: 450.0))
                                .color(ink.alpha(0.5))
                        )
                )
                .child(el().grow(1))
                .child(buttonView("Open", ink: ink, fillAlpha: 0.12))
        } else {
            content = col()
                .key("asking")
                .absolute(x: 0, y: 0)
                .size(GlassPanelConfig.startRect.width, GlassPanelConfig.startRect.height)
                .p(22)
                .gap(12)
                .transition(swapTransition)
                .child(
                    text("Allow screen recording?")
                        .font(TextStyle(size: 19.0, weight: 650.0))
                        .color(ink.alpha(0.847))
                )
                .child(
                    text("The assistant needs to see the window you are working in to help with it.")
                        .wFull()
                        .font(TextStyle(size: 13.5, weight: 450.0))
                        .color(ink.alpha(0.5))
                )
                .child(
                    row()
                        .key("setting")
                        .wFull()
                        .h(44)
                        .px(14)
                        .itemsCenter()
                        .continuousRounded(11)
                        .bg(ink.alpha(0.065))
                        .child(
                            text("Screen & System Audio Recording")
                                .font(TextStyle(size: 13.0, weight: 550.0))
                                .color(ink.alpha(0.847))
                        )
                )
                .child(el().grow(1))
                .child(
                    row()
                        .wFull()
                        .gap(10)
                        .child(el().grow(1))
                        .child(buttonView("Not Now", ink: ink, fillAlpha: 0.065))
                        .child(buttonView("Open Settings", ink: ink, fillAlpha: 0.12))
                )
        }

        let frosted: El<GlassPanelState> = el()
            .key("frost")
            .wFull()
            .hFull()
            .continuousRounded(radius)
            .clipRounded(radius)
            .bg(frost)
            .border(1.0, ink.alpha(0.08))
            .child(content)

        let contactShadow = Shadow(
            x: 0,
            y: 0.5,
            blur: 1.5,
            color: GlassPanelConfig.black.alpha(0.3 - 0.1 * lift)
        )
        let ambientShadow = Shadow(
            x: 0,
            y: 8.0 + 12.0 * lift,
            blur: 18.0 + 14.0 * lift,
            color: GlassPanelConfig.black.alpha(0.32 + 0.14 * lift)
        )

        return el()
            .key("card")
            .absolute(x: rect.x, y: rect.y)
            .size(rect.width, rect.height)
            .continuousRounded(radius)
            .shadows([contactShadow, ambientShadow])
            .systemMaterial(s.material)
            .child(frosted)
    }

    public static func view(_ s: GlassPanelState, _ cx: inout Cx<GlassPanelState>) -> El<GlassPanelState> {
        let dark = cx.systemDark
        var root: El<GlassPanelState> = el().key("root").wFull().hFull()

        if s.headlessPreview {
            root = root.child(backdropView())
            switch s.role {
            case .backdrop:
                return root
            case .dock:
                root = root.child(
                    cardView(
                        s,
                        dark: dark,
                        rect: GlassPanelConfig.dockRect,
                        radius: GlassPanelConfig.dockRadius,
                        lift: 0.0,
                        docked: true
                    )
                )
                if s.mark {
                    root = root.child(
                        markerView(
                            x: GlassPanelConfig.dockRect.x - GlassPanelConfig.margin + 4.0,
                            y: GlassPanelConfig.dockRect.y - GlassPanelConfig.margin + 4.0,
                            color: Color(r: 1.0, g: 0.0, b: 1.0, a: 1.0)
                        )
                    )
                }
                return root
            case .flight:
                let t = s.previewT ?? 0.0
                let (rect, radius, lift) = flightFrame(t)
                root = root.child(cardView(s, dark: dark, rect: rect, radius: radius, lift: lift, docked: t >= 0.4))
                if s.mark {
                    root = root.child(
                        markerView(
                            x: GlassPanelConfig.dockRect.x - GlassPanelConfig.margin + 12.0,
                            y: GlassPanelConfig.dockRect.y - GlassPanelConfig.margin + 4.0,
                            color: Color(r: 0.0, g: 1.0, b: 1.0, a: 1.0)
                        )
                    )
                }
                return root
            }
        }

        switch s.role {
        case .backdrop:
            return backdropView()
        case .dock:
            root = root.child(
                cardView(
                    s,
                    dark: dark,
                    rect: MotionRect.fromXYWH(
                        GlassPanelConfig.margin,
                        GlassPanelConfig.margin,
                        GlassPanelConfig.dockRect.width,
                        GlassPanelConfig.dockRect.height
                    ),
                    radius: GlassPanelConfig.dockRadius,
                    lift: 0.0,
                    docked: true
                )
            )
            if s.mark {
                root = root.child(markerView(x: 4.0, y: 4.0, color: Color(r: 1.0, g: 0.0, b: 1.0, a: 1.0)))
            }
            return root
        case .flight:
            let t = s.started.map { Float((s.now - $0) / GlassPanelConfig.flightSeconds) } ?? 0.0
            let (rect, radius, lift) = flightFrame(t)
            root = root.child(cardView(s, dark: dark, rect: rect, radius: radius, lift: lift, docked: t >= 0.4))
            if s.mark {
                root = root.child(
                    markerView(
                        x: GlassPanelConfig.dockRect.x - GlassPanelConfig.margin + 12.0,
                        y: GlassPanelConfig.dockRect.y - GlassPanelConfig.margin + 4.0,
                        color: Color(r: 0.0, g: 1.0, b: 1.0, a: 1.0)
                    )
                )
            }
            // Keeps frames, and so `poll`, coming until the hand-off.
            if s.started != nil && !s.handed {
                root = root.child(
                    el()
                        .key("frames")
                        .absolute(x: 0, y: 0)
                        .size(1, 1)
                        .loopRotation(period: 1.0)
                )
            }
            return root
        }
    }

    public static func overlayOptions(placement: OverlayPlacement) -> OverlayOptions {
        OverlayOptions(
            placement: placement,
            display: .primary,
            followPointer: false,
            level: .status,
            excludeFromCapture: false,
            keyPolicy: .none,
            input: .none,
            prewarm: true
        )
    }

    public static func makeBackdropOverlaySpec(
        at origin: (Float, Float) = GlassPanelConfig.defaultPlacementOrigin()
    ) -> ConfiguredOverlay<GlassPanelState> {
        let rect = MotionRect.fromXYWH(
            origin.0,
            origin.1,
            GlassPanelConfig.flightWindow.x,
            GlassPanelConfig.flightWindow.y
        )
        return OverlaySpec<GlassPanelState>(
            name: "Glass panel backdrop",
            size: GlassPanelConfig.flightWindow,
            makeState: { GlassPanelState(role: .backdrop) },
            view: view
        )
        .configured(overlayOptions(placement: .rect(rect)))
        .macosLevel(0)
    }

    public static func makeFlightOverlaySpec(
        at origin: (Float, Float) = GlassPanelConfig.defaultPlacementOrigin(),
        coordinator: GlassPanelCoordinator? = nil
    ) -> ConfiguredOverlay<GlassPanelState> {
        let rect = MotionRect.fromXYWH(
            origin.0,
            origin.1,
            GlassPanelConfig.flightWindow.x,
            GlassPanelConfig.flightWindow.y
        )
        return OverlaySpec<GlassPanelState>(
            name: "Glass panel flight",
            size: GlassPanelConfig.flightWindow,
            makeState: { GlassPanelState(role: .flight) },
            view: view
        )
        .configured(overlayOptions(placement: .rect(rect)))
        .macosLevel(4)
        .srgbBlend(true)
        .poll { s, now, tx in
            pollFlight(&s, at: now, &tx, coordinator: coordinator)
        }
    }

    public static func makeDockOverlaySpec(
        at origin: (Float, Float) = GlassPanelConfig.defaultPlacementOrigin()
    ) -> ConfiguredOverlay<GlassPanelState> {
        let dockSize = GlassPanelConfig.dockWindowSize
        let homeX = origin.0 + GlassPanelConfig.dockRect.x - GlassPanelConfig.margin
        let homeY = origin.1 + GlassPanelConfig.dockRect.y - GlassPanelConfig.margin
        let rect = MotionRect.fromXYWH(homeX, homeY, dockSize.x, dockSize.y)
        return OverlaySpec<GlassPanelState>(
            name: "Glass panel dock",
            size: dockSize,
            makeState: { GlassPanelState(role: .dock) },
            view: view
        )
        .configured(overlayOptions(placement: .rect(rect)))
        .macosLevel(3)
        .srgbBlend(true)
    }

    public static func makeApp(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> App<GlassPanelState> {
        let isHeadless = ToolingArgs.parse(arguments).isHeadlessRequested || arguments.contains("--headless")
        let origin = GlassPanelConfig.defaultPlacementOrigin(environment: environment)
        let dockSize = GlassPanelConfig.dockWindowSize
        let homeX = origin.0 + GlassPanelConfig.dockRect.x - GlassPanelConfig.margin
        let homeY = origin.1 + GlassPanelConfig.dockRect.y - GlassPanelConfig.margin

        var app = App<GlassPanelState>(
            "Glass panel",
            size: isHeadless ? GlassPanelConfig.flightWindow : Vec2(1, 1),
            init: { GlassPanelState(role: .flight, headlessPreview: isHeadless) },
            view: view
        )
        .windowless(!isHeadless)
        .accessory(true)
        .args(arguments)
        .scene("asking") { s, _ in
            s.role = .flight
            s.headlessPreview = true
            s.previewT = 0.0
        }
        .scene("flight") { s, _ in
            s.role = .flight
            s.headlessPreview = true
            s.previewT = 0.45
        }
        .scene("docked") { s, _ in
            s.role = .dock
            s.headlessPreview = true
            s.previewT = 1.0
        }
        .scene("mark") { s, _ in
            s.role = .dock
            s.headlessPreview = true
            s.previewT = 1.0
            s.mark = true
        }

        if !isHeadless {
            let retainer = GlassPanelRetainer()
            let commands = app.handle()
            app = app
                .onQuit { _, _ in
                    retainer.release()
                }
                .setup { _ in
                    let coordinator = GlassPanelCoordinator()
                    let backdrop = OverlayHandle(configured: makeBackdropOverlaySpec(at: origin))
                    let flight = OverlayHandle(configured: makeFlightOverlaySpec(at: origin, coordinator: coordinator))
                    let dock = OverlayHandle(configured: makeDockOverlaySpec(at: origin))
                    coordinator.install(backdrop: backdrop, flight: flight, dock: dock)
                    retainer.hold(handles: [backdrop, flight, dock], coordinator: coordinator)

                    backdrop.show()

                    Thread.detachNewThread {
                        Thread.sleep(forTimeInterval: 0.8)
                        while !coordinator.isStopped {
                            flight.update { s in
                                s.started = nil
                                s.landed = nil
                                s.handed = false
                            }
                            flight.setMacosLevel(4)
                            flight.fadeIn(0.180)
                            Thread.sleep(forTimeInterval: 0.7)
                            if coordinator.isStopped { break }
                            coordinator.resetHandOff()
                            flight.update { s in
                                s.fly = true
                            }
                            coordinator.waitForHandOff()
                            if coordinator.isStopped { break }
                            Thread.sleep(forTimeInterval: 0.25)

                            // The docked window follows a target that moves side to side, 60 times a second.
                            let followStart = Date()
                            while !coordinator.isStopped {
                                let elapsed = Date().timeIntervalSince(followStart)
                                if elapsed >= 2.4 { break }
                                let dx = 60.0 * sinf(Float.pi * 2.0 * Float(elapsed) / 2.4)
                                dock.setPlacement(.rect(MotionRect.fromXYWH(homeX + dx, homeY, dockSize.x, dockSize.y)))
                                Thread.sleep(forTimeInterval: 1.0 / 60.0)
                            }
                            dock.setPlacement(.rect(MotionRect.fromXYWH(homeX, homeY, dockSize.x, dockSize.y)))
                            dock.fadeOut(0.144)
                            Thread.sleep(forTimeInterval: 0.6)
                        }
                    }

                    if let secondsStr = environment["GLASS_PANEL_SECONDS"],
                       let seconds = Double(secondsStr),
                       seconds > 0 {
                        Thread.detachNewThread {
                            Thread.sleep(forTimeInterval: seconds)
                            retainer.release()
                            commands.quit()
                        }
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
