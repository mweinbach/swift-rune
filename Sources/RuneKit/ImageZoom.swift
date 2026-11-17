import Foundation
import Rune

/// Zoom and pan state for a fitted image inside a clipping viewport (`rune_kit::image_zoom::math`).
/// `scale` is relative to the fitted size (`1.0` = fit). `x` and `y` offset the image's center
/// from the viewport's center in points.
public struct ZoomView: Sendable, Equatable {
    public var scale: Float
    public var x: Float
    public var y: Float

    public static let fit = ZoomView(scale: 1.0, x: 0.0, y: 0.0)

    public init(scale: Float = 1.0, x: Float = 0.0, y: Float = 0.0) {
        self.scale = scale
        self.x = x
        self.y = y
    }
}

/// Fitted image and viewport dimensions for clamping zoom and pan (`rune_kit::image_zoom::math::ZoomBounds`).
public struct ZoomBounds: Sendable, Equatable {
    public var width: Float
    public var height: Float
    public var viewportWidth: Float
    public var viewportHeight: Float
    public var maxScale: Float

    public init(
        width: Float = 0,
        height: Float = 0,
        viewportWidth: Float = 0,
        viewportHeight: Float = 0,
        maxScale: Float = 8.0
    ) {
        self.width = width
        self.height = height
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.maxScale = maxScale
    }
}

/// Pure math helpers for zoom/pan clamping and anchor-preserving scaling (`rune_kit::image_zoom::math`).
public enum ImageZoomMath {
    public static let maxNaturalZoom: Float = 8.0
    public static let step: Float = Float(2.0).squareRoot()

    public static func maxScale(fitRatio: Float) -> Float {
        max(1.0, maxNaturalZoom / fitRatio)
    }

    public static func detailScale(fitRatio: Float) -> Float {
        let actual = 1.0 / fitRatio
        return actual >= 1.5 ? actual : 2.0
    }

    public static func wheelZoomFactor(deltaY: Float) -> Float {
        exp(-deltaY.clamped(to: -30.0...30.0) / 100.0)
    }

    public static func clampAxis(offset: Float, size: Float, viewport: Float) -> Float {
        let limit = max(0.0, (size - viewport) / 2.0)
        return offset.clamped(to: -limit...limit) + 0.0
    }

    public static func clampView(_ view: ZoomView, bounds: ZoomBounds) -> ZoomView {
        ZoomView(
            scale: view.scale,
            x: clampAxis(offset: view.x, size: bounds.width * view.scale, viewport: bounds.viewportWidth),
            y: clampAxis(offset: view.y, size: bounds.height * view.scale, viewport: bounds.viewportHeight)
        )
    }

    public static func zoomAt(
        _ view: ZoomView,
        scale: Float,
        anchor: Vec2,
        bounds: ZoomBounds
    ) -> ZoomView {
        let next = scale.clamped(to: 1.0...max(1.0, bounds.maxScale))
        let ratio = next / view.scale
        return clampView(
            ZoomView(
                scale: next,
                x: anchor.x - (anchor.x - view.x) * ratio,
                y: anchor.y - (anchor.y - view.y) * ratio
            ),
            bounds: bounds
        )
    }

    public static func panBy(_ view: ZoomView, delta: Vec2, bounds: ZoomBounds) -> ZoomView {
        clampView(
            ZoomView(scale: view.scale, x: view.x + delta.x, y: view.y + delta.y),
            bounds: bounds
        )
    }
}

/// Critically damped spring glide for smooth zoom transitions (`rune_kit::image_zoom::glide`).
public struct ImageZoomGlide: Sendable, Equatable {
    private static let duration: Double = 0.3

    public struct SpringAxis: Sendable, Equatable {
        public var value: Double
        public var target: Double
        public var velocity: Double

        public init(value: Double) {
            self.value = value
            self.target = value
            self.velocity = 0.0
        }

        public var isResting: Bool {
            abs(value - target) < 0.005 && abs(velocity) < 0.02
        }

        public mutating func step(dt: Double) {
            let x0 = value - target
            let v0 = velocity
            if x0 == 0.0 && v0 == 0.0 { return }
            let t = min(max(dt, 0.0), 0.1)
            if t == 0.0 { return }
            let w = (2.0 * Double.pi) / ImageZoomGlide.duration
            let e = exp(-w * t)
            let d = e * (1.0 + w * t) * x0 + e * t * v0
            let nextV = -e * w * w * t * x0 + e * (1.0 - w * t) * v0
            if abs(d) < 0.005 && abs(nextV) < 0.02 {
                value = target
                velocity = 0.0
                return
            }
            value = target + d
            velocity = nextV
        }
    }

    public var scale: SpringAxis
    public var x: SpringAxis
    public var y: SpringAxis

    public init(view: ZoomView = .fit) {
        self.scale = SpringAxis(value: Double(view.scale))
        self.x = SpringAxis(value: Double(view.x))
        self.y = SpringAxis(value: Double(view.y))
    }

    public var shown: ZoomView {
        ZoomView(scale: Float(scale.value), x: Float(x.value), y: Float(y.value))
    }

    public var goal: ZoomView {
        ZoomView(scale: Float(scale.target), x: Float(x.target), y: Float(y.target))
    }

    public mutating func setTarget(_ view: ZoomView) {
        scale.target = Double(view.scale)
        x.target = Double(view.x)
        y.target = Double(view.y)
    }

    @discardableResult
    public mutating func step(dt: Double) -> Bool {
        scale.step(dt: dt)
        x.step(dt: dt)
        y.step(dt: dt)
        return !(scale.isResting && x.isResting && y.isResting)
    }
}

/// Element keys used by `Preview` (`rune_kit::image_zoom`).
public enum ImageZoomKeys {
    public static let preview = "image-preview"
    public static let close = "image-preview-close"
    public static let body = "image-preview-body"
    public static let controls = "image-preview-controls"
    public static let zoomLevel = "image-preview-zoom-level"
    public static let zoomOut = "image-preview-zoom-out"
    public static let zoomIn = "image-preview-zoom-in"
    public static let divider = "image-preview-divider"
}

/// The press under way on the preview (`rune_kit::image_zoom::gesture::Gesture`).
public enum ImageZoomGesture: Sendable, Equatable {
    case idle
    case backdropPress
    case panning(onBackdrop: Bool, moved: Bool, cursor: Vec2)
}

/// Preview gesture + glide machine state (`rune_kit::image_zoom::gesture::State`).
public enum ImageZoomMachineState: Sendable, Equatable {
    case still(ImageZoomGesture)
    case gliding(gesture: ImageZoomGesture, last: Double)

    public static let `default`: ImageZoomMachineState = .still(.idle)

    public var isDragging: Bool {
        switch self {
        case .still(.panning), .gliding(.panning, _):
            return true
        default:
            return false
        }
    }
}

/// Events for `imageZoomStep` (`rune_kit::image_zoom::gesture::Event`).
public enum ImageZoomEvent: Sendable, Equatable {
    case pointerDown(onBody: Bool, onBackdrop: Bool, zoomed: Bool, at: Vec2)
    case pointerMoved(at: Vec2)
    case pointerUp
    case pointerCancel
    case click(onBackdrop: Bool)
    case follow(zoomed: Bool)
    case glideStart(now: Double)
    case glideSettled(zoomed: Bool)
}

/// Effects emitted by `imageZoomStep` (`rune_kit::image_zoom::gesture::Effect`).
public enum ImageZoomEffect: Sendable, Equatable {
    case pan(Vec2)
    case frames
    case close
}

/// Pure transition function for `ImageZoomMachineState` (`gesture::step`).
public func imageZoomStep(
    _ state: inout ImageZoomMachineState,
    _ event: ImageZoomEvent
) -> [ImageZoomEffect] {
    let gesture: ImageZoomGesture
    let glidingLast: Double?
    switch state {
    case .still(let g):
        gesture = g
        glidingLast = nil
    case .gliding(let g, let last):
        gesture = g
        glidingLast = last
    }

    func setGesture(_ g: ImageZoomGesture) {
        if let last = glidingLast {
            state = .gliding(gesture: g, last: last)
        } else {
            state = .still(g)
        }
    }

    let isPanning: Bool
    if case .panning = gesture { isPanning = true } else { isPanning = false }

    switch event {
    case .pointerDown(let onBody, let onBackdrop, let zoomed, let at):
        if zoomed && onBody {
            setGesture(.panning(onBackdrop: onBackdrop, moved: false, cursor: at))
        } else {
            setGesture(onBackdrop ? .backdropPress : .idle)
        }
        return []

    case .pointerMoved(let at):
        guard case .panning(_, _, let cursor) = gesture else { return [] }
        let delta = Vec2(at.x - cursor.x, at.y - cursor.y)
        if delta.x == 0 && delta.y == 0 { return [] }
        setGesture(.panning(onBackdrop: false, moved: true, cursor: at))
        return [.pan(delta)]

    case .pointerUp:
        if case .panning(let onBackdrop, let moved, _) = gesture {
            setGesture(!moved && onBackdrop ? .backdropPress : .idle)
        }
        return []

    case .pointerCancel:
        if isPanning { setGesture(.idle) }
        return []

    case .click(let onBackdrop):
        guard gesture == .backdropPress else { return [] }
        setGesture(.idle)
        return onBackdrop ? [.close] : []

    case .glideStart(let now):
        let nextGesture = isPanning ? .idle : gesture
        let started = (glidingLast == nil)
        state = .gliding(gesture: nextGesture, last: glidingLast ?? now)
        return started ? [.frames] : []

    case .follow(let zoomed):
        let nextGesture = (isPanning && !zoomed) ? .idle : gesture
        state = .still(nextGesture)
        return []

    case .glideSettled(let zoomed):
        guard glidingLast != nil else { return [] }
        state = .still((isPanning && !zoomed) ? .idle : gesture)
        return []
    }
}

public typealias ImageZoom = ImageZoomState

/// Interactive pan/zoom/double-click/wheel state for `ImageZoom` (`rune_kit::image_zoom`).
public struct ImageZoomState: Sendable, Equatable {
    public enum Gesture: Sendable, Equatable {
        case idle
        case backdropPress
        case panning(onBackdrop: Bool, moved: Bool, cursor: Vec2)
    }

    public var view: ZoomView
    public var glide: ImageZoomGlide
    public var gesture: Gesture
    public var phaseState: ImageZoomMachineState
    public var isOpen: Bool
    public var bounds: ZoomBounds
    public var fitRatio: Float
    public var reducedMotion: Bool

    public init(
        view: ZoomView = .fit,
        isOpen: Bool = false,
        bounds: ZoomBounds = ZoomBounds(),
        fitRatio: Float = 1.0,
        reducedMotion: Bool = false
    ) {
        self.view = view
        self.glide = ImageZoomGlide(view: view)
        self.gesture = .idle
        self.phaseState = .default
        self.isOpen = isOpen
        self.bounds = bounds
        self.fitRatio = fitRatio
        self.reducedMotion = reducedMotion
    }

    /// The view currently shown (`glide.shown`).
    public var currentView: ZoomView { glide.shown }

    /// Zoom as a whole percentage of the image's natural size (`image_zoom::ImageZoom::level`).
    public var level: UInt32 {
        let percent = (currentView.scale * max(Float.ulpOfOne, fitRatio) * 100).rounded()
        guard percent > 0 else { return 0 }
        return percent >= Float(UInt32.max) ? .max : UInt32(percent)
    }

    public var isZoomed: Bool { view.scale > 1.0 }

    /// Whether Escape should fit back to 1.0 before closing (`glide.goal.scale > 1.0`).
    public var ownsEscape: Bool { glide.goal.scale > 1.0 }

    /// Whether a glide animation is currently running.
    public var isGliding: Bool {
        if case .gliding = phaseState { return true }
        return false
    }

    public var isDragging: Bool {
        if case .panning = gesture { return true }
        return phaseState.isDragging
    }

    public mutating func openLightbox() {
        isOpen = true
        reset()
    }

    public mutating func closeLightbox() {
        isOpen = false
        gesture = .idle
        phaseState = .default
    }

    public mutating func reset() {
        view = .fit
        glide = ImageZoomGlide(view: .fit)
        gesture = .idle
        phaseState = .default
    }

    /// Steps an active glide to `now`; returns `true` while a glide is active.
    @discardableResult
    public mutating func poll(now: Double, tx: inout Tx) -> Bool {
        guard case .gliding(let g, let last) = phaseState else { return false }
        let moving = glide.step(dt: now - last)
        view = glide.shown
        phaseState = .gliding(gesture: g, last: now)
        if !moving {
            run(.glideSettled(zoomed: currentView.scale > 1.0), tx: &tx)
        }
        return true
    }

    /// Convenience `poll` without `Tx`.
    @discardableResult
    public mutating func poll(now: Double) -> Bool {
        var tx = Tx()
        return poll(now: now, tx: &tx)
    }

    /// Steps zoom in by `√2` toward center (`Cmd++`).
    public mutating func zoomIn(tx: inout Tx, now: Double = 0) {
        stepBy(ImageZoomMath.step, tx: &tx, now: now)
    }

    /// Steps zoom out by `√2` toward center (`Cmd+-`).
    public mutating func zoomOut(tx: inout Tx, now: Double = 0) {
        stepBy(1.0 / ImageZoomMath.step, tx: &tx, now: now)
    }

    /// Smoothly fits back to 100% fit (`Cmd+0` / `0` / Escape when zoomed).
    public mutating func fit(tx: inout Tx, now: Double = 0) {
        ease(to: .fit, tx: &tx, now: now)
    }

    /// Double-click at viewport-centered `at`: 100% natural scale (or 2x) / fit.
    public mutating func detail(at: Vec2, tx: inout Tx, now: Double = 0) {
        if glide.goal.scale > 1.0 {
            fit(tx: &tx, now: now)
            return
        }
        let targetScale = ImageZoomMath.detailScale(fitRatio: fitRatio)
        let to = ImageZoomMath.zoomAt(glide.goal, scale: targetScale, anchor: at, bounds: bounds)
        ease(to: to, tx: &tx, now: now)
    }

    public mutating func follow(_ to: ZoomView, tx: inout Tx) {
        run(.follow(zoomed: to.scale > 1.0), tx: &tx)
        glide = ImageZoomGlide(view: to)
        view = to
        tx.settle()
    }

    public mutating func ease(to: ZoomView, tx: inout Tx, now: Double = 0) {
        if reducedMotion {
            follow(to, tx: &tx)
            return
        }
        glide.setTarget(to)
        run(.glideStart(now: now), tx: &tx)
    }

    private mutating func stepBy(_ factor: Float, tx: inout Tx, now: Double) {
        let goal = glide.goal
        let to = ImageZoomMath.zoomAt(goal, scale: goal.scale * factor, anchor: .zero, bounds: bounds)
        ease(to: to, tx: &tx, now: now)
    }

    /// Runs the gesture machine on `event` and executes emitted effects; returns `true` when closing.
    @discardableResult
    public mutating func run(_ event: ImageZoomEvent, tx: inout Tx) -> Bool {
        var shouldClose = false
        for effect in imageZoomStep(&phaseState, event) {
            switch effect {
            case .pan(let d):
                let v = currentView
                let to = ZoomView(
                    scale: v.scale,
                    x: ImageZoomMath.clampAxis(offset: v.x + d.x, size: bounds.width * v.scale, viewport: bounds.viewportWidth),
                    y: ImageZoomMath.clampAxis(offset: v.y + d.y, size: bounds.height * v.scale, viewport: bounds.viewportHeight)
                )
                follow(to, tx: &tx)
            case .frames:
                break
            case .close:
                shouldClose = true
            }
        }
        return shouldClose
    }

    /// Measures the preview body rect `[x, y, w, h]` and fitted image size for `window` and `natural`.
    @discardableResult
    public mutating func measure(window: Vec2, natural: Vec2) -> (body: [Float], fitted: Vec2) {
        let band: Float = 44.0
        let pad: Float = 12.0
        let side = min(max(window.x * 0.03, 8.0), 36.0)
        let body = [side, band, max(window.x - 2.0 * side, 1.0), max(window.y - 2.0 * band, 1.0)]
        let nw = max(natural.x, 1.0)
        let nh = max(natural.y, 1.0)
        let k = min(min(max(body[2] - 2.0 * pad, 1.0) / nw, max(body[3] - 2.0 * pad, 1.0) / nh), 1.0)
        let fitted = Vec2(nw * k, nh * k)
        fitRatio = k
        bounds = ZoomBounds(
            width: fitted.x,
            height: fitted.y,
            viewportWidth: body[2],
            viewportHeight: body[3],
            maxScale: ImageZoomMath.maxScale(fitRatio: k)
        )
        return (body, fitted)
    }

    /// Where the image sits inside the body `[x, y, w, h]`.
    public func imageRect(body: [Float], fitted: Vec2) -> [Float] {
        let v = ImageZoomMath.clampView(currentView, bounds: bounds)
        let w = fitted.x * v.scale
        let h = fitted.y * v.scale
        return [body[2] * 0.5 + v.x - w * 0.5, body[3] * 0.5 + v.y - h * 0.5, w, h]
    }

    public func hitsImage(_ at: Vec2) -> Bool {
        let v = currentView
        let x = at.x - bounds.viewportWidth * 0.5 - v.x
        let y = at.y - bounds.viewportHeight * 0.5 - v.y
        return abs(x) <= bounds.width * v.scale * 0.5 && abs(y) <= bounds.height * v.scale * 0.5
    }

    public func centered(_ at: Vec2) -> Vec2 {
        Vec2(at.x - bounds.viewportWidth * 0.5, at.y - bounds.viewportHeight * 0.5)
    }

    /// Handles preview keys: `Cmd+=`/`Cmd++`, `Cmd+-`/`Cmd+_`, `Cmd+0`/`0`, and `Escape`.
    /// Returns `true` when Escape asks to close, `false` when handled, or `nil` when ignored.
    public mutating func handleKey(_ ev: KeyEvent, tx: inout Tx, now: Double = 0) -> Bool? {
        let m = ev.mods
        let bare = !m.cmd && !m.ctrl && !m.alt && !m.logo
        switch ev.key {
        case .escape where ownsEscape:
            fit(tx: &tx, now: now)
            return false
        case .escape:
            return true
        case .text(let t) where bare && t == "0":
            fit(tx: &tx, now: now)
            return false
        case .command(let ch) where m.primaryAlone:
            switch ch {
            case "=", "+":
                zoomIn(tx: &tx, now: now)
                return false
            case "-", "_":
                zoomOut(tx: &tx, now: now)
                return false
            case "0":
                fit(tx: &tx, now: now)
                return false
            default:
                return nil
            }
        case .text(let t) where (m.cmd || m.ctrl) && !m.alt:
            switch t {
            case "=", "+":
                zoomIn(tx: &tx, now: now)
                return false
            case "-", "_":
                zoomOut(tx: &tx, now: now)
                return false
            case "0":
                fit(tx: &tx, now: now)
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    public mutating func zoomIn(anchor: Vec2 = .zero) {
        let next = ImageZoomMath.zoomAt(view, scale: view.scale * ImageZoomMath.step, anchor: anchor, bounds: bounds)
        view = next
        glide.setTarget(next)
    }

    public mutating func zoomOut(anchor: Vec2 = .zero) {
        let next = ImageZoomMath.zoomAt(view, scale: view.scale / ImageZoomMath.step, anchor: anchor, bounds: bounds)
        view = next
        glide.setTarget(next)
    }

    public mutating func toggleDoubleClick(anchor: Vec2 = .zero, fitRatio: Float = 0.5) {
        let targetScale: Float = isZoomed ? 1.0 : ImageZoomMath.detailScale(fitRatio: fitRatio)
        let next = ImageZoomMath.zoomAt(view, scale: targetScale, anchor: anchor, bounds: bounds)
        view = next
        glide.setTarget(next)
    }

    public mutating func applyWheel(deltaY: Float, anchor: Vec2 = .zero) {
        let factor = ImageZoomMath.wheelZoomFactor(deltaY: deltaY)
        let next = ImageZoomMath.zoomAt(view, scale: view.scale * factor, anchor: anchor, bounds: bounds)
        view = next
        glide = ImageZoomGlide(view: next)
    }

    public mutating func pan(delta: Vec2) {
        let next = ImageZoomMath.panBy(view, delta: delta, bounds: bounds)
        view = next
        glide = ImageZoomGlide(view: next)
    }

    public mutating func pointerDown(onBody: Bool, onBackdrop: Bool, at: Vec2) {
        if isZoomed && onBody {
            gesture = .panning(onBackdrop: onBackdrop, moved: false, cursor: at)
        } else {
            gesture = onBackdrop ? .backdropPress : .idle
        }
    }

    @discardableResult
    public mutating func pointerMoved(to at: Vec2) -> Bool {
        guard case .panning(_, _, let cursor) = gesture else { return false }
        let delta = Vec2(at.x - cursor.x, at.y - cursor.y)
        if delta.x == 0 && delta.y == 0 { return false }
        gesture = .panning(onBackdrop: false, moved: true, cursor: at)
        pan(delta: delta)
        return true
    }

    /// Ends a pointer press; returns `true` when a clean backdrop click should close the lightbox.
    @discardableResult
    public mutating func pointerUp(onBackdrop: Bool) -> Bool {
        switch gesture {
        case .backdropPress:
            gesture = .idle
            if onBackdrop {
                closeLightbox()
                return true
            }
            return false
        case .panning(let startedOnBackdrop, let moved, _):
            gesture = .idle
            if !moved && startedOnBackdrop && onBackdrop {
                closeLightbox()
                return true
            }
            return false
        case .idle:
            return false
        }
    }
}

extension Kit {
    /// Inline zoomable image card with optional lightbox trigger (`rune_kit::image_zoom`).
    public func imageZoom<State>(
        key: String = "image-zoom",
        title: String? = nil,
        state: ImageZoomState,
        width: Float = 320,
        height: Float = 200,
        content: El<State>,
        onZoomIn: ((inout State) -> Void)? = nil,
        onZoomOut: ((inout State) -> Void)? = nil,
        onReset: ((inout State) -> Void)? = nil,
        onOpenLightbox: ((inout State) -> Void)? = nil
    ) -> El<State> {
        let pct = Int((state.view.scale * 100).rounded())
        var toolbar: El<State> = row()
            .key("\(key)-toolbar")
            .wFull()
            .px(10)
            .py(6)
            .itemsCenter()
            .justifyBetween()
            .bg(c.layer02)
            .borderSides(bottom: 1.0, color: c.borderMuted)
            .child(text(title ?? "Image").font(ty.smallMedium).color(c.textBase))

        var controls: El<State> = row().gap(6).itemsCenter()
            .child(text("\(pct)%").font(ty.small).color(c.textMuted))
        if let onZoomOut {
            controls = controls.child(button(key: "\(key)-out", "−", variant: .ghost, size: .sm) { s, _ in onZoomOut(&s) })
        }
        if let onZoomIn {
            controls = controls.child(button(key: "\(key)-in", "+", variant: .ghost, size: .sm) { s, _ in onZoomIn(&s) })
        }
        if let onReset, state.isZoomed {
            controls = controls.child(button(key: "\(key)-reset", "Fit", variant: .ghost, size: .sm) { s, _ in onReset(&s) })
        }
        if let onOpenLightbox {
            controls = controls.child(button(key: "\(key)-expand", "Expand", variant: .ghost, size: .sm) { s, _ in onOpenLightbox(&s) })
        }
        toolbar = toolbar.child(controls)

        let stage: El<State> = el()
            .key("\(key)-stage")
            .wFull()
            .h(height)
            .bg(c.bgDeep)
            .clip(true)
            .center()
            .child(
                content
                    .scale(state.view.scale)
                    .offset(state.view.x, state.view.y)
            )

        return col()
            .key(key)
            .w(width)
            .rounded(radius.lg)
            .bg(c.layer01)
            .border(1.0, c.borderMuted)
            .clip(true)
            .child(toolbar)
            .child(stage)
    }

    /// Full-screen image lightbox overlay with scrim, close button, and zoom controls.
    public func imageLightbox<State>(
        key: String = "image-lightbox",
        title: String? = nil,
        state: ImageZoomState,
        content: El<State>,
        onClose: @escaping (inout State) -> Void,
        onZoomIn: ((inout State) -> Void)? = nil,
        onZoomOut: ((inout State) -> Void)? = nil,
        onReset: ((inout State) -> Void)? = nil
    ) -> El<State> {
        guard state.isOpen else { return el().key("\(key)-closed") }
        let pct = Int((state.view.scale * 100).rounded())

        var header: El<State> = row()
            .wFull()
            .px(16)
            .py(10)
            .itemsCenter()
            .justifyBetween()
            .bg(c.layer01.alpha(0.92))
            .borderSides(bottom: 1.0, color: c.borderMuted)
            .child(text(title ?? "Preview").font(ty.uiMedium).color(c.textBase))

        var actions: El<State> = row().gap(8).itemsCenter()
            .child(text("\(pct)%").font(ty.small).color(c.textMuted))
        if let onZoomOut {
            actions = actions.child(button(key: "\(key)-out", "−", variant: .neutral, size: .sm) { s, _ in onZoomOut(&s) })
        }
        if let onZoomIn {
            actions = actions.child(button(key: "\(key)-in", "+", variant: .neutral, size: .sm) { s, _ in onZoomIn(&s) })
        }
        if let onReset {
            actions = actions.child(button(key: "\(key)-reset", "Reset", variant: .neutral, size: .sm) { s, _ in onReset(&s) })
        }
        actions = actions.child(iconButton(key: "\(key)-close", svg: KitIcons.close, label: "Close", size: .sm, variant: .ghost) { s, _ in onClose(&s) })
        header = header.child(actions)

        return col()
            .key(key)
            .wFull()
            .hFull()
            .bg(c.scrim)
            .child(header)
            .child(
                el()
                    .wFull()
                    .grow(1)
                    .clip(true)
                    .center()
                    .child(
                        content
                            .scale(state.view.scale)
                            .offset(state.view.x, state.view.y)
                    )
            )
    }
}

// MARK: - Preview & Stage (rune_kit::image_zoom::{Preview, Stage, StageZoom})

/// Full-window image preview with bottom floating zoom bar (`rune_kit::image_zoom::Preview`).
public struct Preview<State> {
    private let keyPath: WritableKeyPath<State, ImageZoomState>
    private let natural: Vec2
    private let image: El<State>
    private var closeHandler: (inout State, inout Tx) -> Void = { _, _ in }
    private var customIcons: (minus: SVGIcon, plus: SVGIcon)?
    private var labelStrings: (zoomOut: String, fit: String, zoomIn: String, close: String) = (
        "Zoom out", "Zoom to fit", "Zoom in", "Close"
    )
    private var levelFormatter: (UInt32) -> String = { "\($0)%" }
    private var controlsTransitionValue: Transition?

    public init(
        _ keyPath: WritableKeyPath<State, ImageZoomState>,
        natural: Vec2,
        image: El<State>
    ) {
        self.keyPath = keyPath
        self.natural = natural
        self.image = image
    }

    public func controlsTransition(_ t: Transition) -> Self {
        var copy = self
        copy.controlsTransitionValue = t
        return copy
    }

    public func onClose(_ f: @escaping (inout State, inout Tx) -> Void) -> Self {
        var copy = self
        copy.closeHandler = f
        return copy
    }

    public func icons(minus: SVGIcon, plus: SVGIcon) -> Self {
        var copy = self
        copy.customIcons = (minus, plus)
        return copy
    }

    public func labels(zoomOut: String, fit: String, zoomIn: String, close: String) -> Self {
        var copy = self
        copy.labelStrings = (zoomOut, fit, zoomIn, close)
        return copy
    }

    public func formatLevel(_ f: @escaping (UInt32) -> String) -> Self {
        var copy = self
        copy.levelFormatter = f
        return copy
    }

    public func build(
        _ zoom: ImageZoomState,
        kit k: Kit,
        window: Vec2,
        reducedMotion: Bool = false
    ) -> El<State> {
        var measured = zoom
        measured.reducedMotion = reducedMotion
        let (body, fitted) = measured.measure(window: window, natural: natural)
        let imgRect = measured.imageRect(body: body, fitted: fitted)
        let kp = keyPath
        let close = closeHandler
        let scale = measured.currentView.scale
        let bar = buildBar(zoom: measured, kit: k)

        let placedImage = image
            .absolute(x: imgRect[0], y: imgRect[1])
            .size(imgRect[2], imgRect[3])
            .rounded(k.radius.md * scale)

        func handleDragPhase(
            _ state: inout State,
            at: Vec2,
            onBody: Bool,
            phase: GesturePhase,
            clicks: Int,
            tx: inout Tx
        ) {
            state[keyPath: kp].reducedMotion = reducedMotion
            _ = state[keyPath: kp].measure(window: window, natural: natural)
            switch phase {
            case .began:
                tx.focus(ImageZoomKeys.preview)
                let onBackdrop = !onBody || !state[keyPath: kp].hitsImage(at)
                _ = state[keyPath: kp].run(
                    .pointerDown(
                        onBody: onBody,
                        onBackdrop: onBackdrop,
                        zoomed: state[keyPath: kp].isZoomed,
                        at: at
                    ),
                    tx: &tx
                )
            case .changed:
                _ = state[keyPath: kp].run(.pointerMoved(at: at), tx: &tx)
            case .cancelled:
                _ = state[keyPath: kp].run(.pointerCancel, tx: &tx)
            case .ended:
                _ = state[keyPath: kp].run(.pointerUp, tx: &tx)
                let onBackdrop = !onBody || !state[keyPath: kp].hitsImage(at)
                if state[keyPath: kp].run(.click(onBackdrop: onBackdrop), tx: &tx) {
                    close(&state, &tx)
                    return
                }
                if onBody && clicks == 2 {
                    let c = state[keyPath: kp].centered(at)
                    state[keyPath: kp].detail(at: c, tx: &tx)
                }
            }
            if case .still(.panning) = state[keyPath: kp].phaseState {
                tx.settle()
            }
        }

        var bodyEl: El<State> = el()
            .key(ImageZoomKeys.body)
            .absolute(x: body[0], y: body[1])
            .size(body[2], body[3])
            .onPointerDown { s, press, tx in
                handleDragPhase(&s, at: press.local, onBody: true, phase: .began, clicks: press.clicks, tx: &tx)
            }
            .onDrag { s, drag, tx in
                handleDragPhase(&s, at: drag.local, onBody: true, phase: .changed, clicks: drag.clicks, tx: &tx)
            }
            .onDragEnd { s, cancelled, tx in
                if cancelled {
                    handleDragPhase(&s, at: .zero, onBody: true, phase: .cancelled, clicks: 1, tx: &tx)
                }
            }
            .onPointerUp { s, press, tx in
                handleDragPhase(&s, at: press.local, onBody: true, phase: .ended, clicks: press.clicks, tx: &tx)
            }
            .onWheel { s, ev, tx in
                s[keyPath: kp].reducedMotion = reducedMotion
                _ = s[keyPath: kp].measure(window: window, natural: natural)
                let v = s[keyPath: kp].currentView
                let b = s[keyPath: kp].bounds
                let to: ZoomView
                if ev.mods.ctrl || ev.mods.cmd {
                    to = ImageZoomMath.zoomAt(v, scale: v.scale * ImageZoomMath.wheelZoomFactor(deltaY: -ev.dy), anchor: .zero, bounds: b)
                } else {
                    to = ImageZoomMath.panBy(v, delta: Vec2(ev.dx, ev.dy), bounds: b)
                }
                s[keyPath: kp].follow(to, tx: &tx)
                return true
            }
            .child(placedImage)

        if measured.isZoomed {
            bodyEl = bodyEl.clip(true)
        }

        return el()
            .key(ImageZoomKeys.preview)
            .wFull()
            .hFull()
            .focusable(true)
            .modal(true)
            .onPointerDown { s, press, tx in
                handleDragPhase(&s, at: press.local, onBody: false, phase: .began, clicks: press.clicks, tx: &tx)
            }
            .onPointerUp { s, press, tx in
                handleDragPhase(&s, at: press.local, onBody: false, phase: .ended, clicks: press.clicks, tx: &tx)
            }
            .onWheel { _, _, _ in true }
            .onKey { s, ev, tx in
                s[keyPath: kp].reducedMotion = reducedMotion
                _ = s[keyPath: kp].measure(window: window, natural: natural)
                switch s[keyPath: kp].handleKey(ev, tx: &tx) {
                case .some(true):
                    close(&s, &tx)
                    return true
                case .some(false):
                    return true
                case .none:
                    return false
                }
            }
            .child(bodyEl)
            .child(
                row()
                    .pin(right: 0, bottom: 12, left: 0)
                    .justifyCenter()
                    .child(bar)
            )
    }

    private func buildBar(zoom: ImageZoomState, kit k: Kit) -> El<State> {
        let kp = keyPath
        let close = closeHandler
        let glyphs = customIcons ?? (minus: k.glyph.dash, plus: KitIcons.plus)
        let levelText = levelFormatter(zoom.level)

        let levelBtn: El<State> = k.button(
            key: ImageZoomKeys.zoomLevel,
            levelText,
            variant: .ghost,
            size: .sm
        ) { s, tx in
            s[keyPath: kp].fit(tx: &tx)
        }
        .help(labelStrings.fit)
        .minW(58)

        let outBtn: El<State> = k.iconButton(
            key: ImageZoomKeys.zoomOut,
            svg: glyphs.minus,
            label: labelStrings.zoomOut,
            variant: .ghost
        ) { s, tx in
            s[keyPath: kp].zoomOut(tx: &tx)
        }

        let inBtn: El<State> = k.iconButton(
            key: ImageZoomKeys.zoomIn,
            svg: glyphs.plus,
            label: labelStrings.zoomIn,
            variant: .ghost
        ) { s, tx in
            s[keyPath: kp].zoomIn(tx: &tx)
        }

        let closeBtn: El<State> = k.iconButton(
            key: ImageZoomKeys.close,
            svg: k.glyph.close,
            label: labelStrings.close,
            variant: .ghost
        ) { s, tx in
            close(&s, &tx)
        }

        var barRow: El<State> = row()
            .key(ImageZoomKeys.controls)
            .gap(2)
            .p(2)
            .itemsCenter()
            .rounded(8)
            .bg(k.c.layer01)
            .child(outBtn)
            .child(levelBtn)
            .child(inBtn)
            .child(el().key(ImageZoomKeys.divider).size(1, 16).mx(2).bg(k.c.borderBase))
            .child(closeBtn)
        if let controlsTransitionValue {
            barRow = barRow.transition(controlsTransitionValue)
        }

        return k.elevate(
            barRow,
            k.elevation.floating
        )
    }
}

/// Stage gesture state machine (`rune_kit::image_zoom::stage::StageGesture`).
public enum StageGesture: Sendable, Equatable {
    case idle
    case panning(moved: Bool, origin: Vec2)
    case suppressClick
}

/// Stage gesture events (`rune_kit::image_zoom::stage::StageEvent`).
public enum StageEvent: Sendable, Equatable {
    case pointerDown(zoomed: Bool, at: Vec2)
    case pointerMoved(at: Vec2)
    case pointerUp
    case pointerCancel
    case zoomChanged(zoomed: Bool)
    case click
}

/// Stage gesture effects (`rune_kit::image_zoom::stage::StageEffect`).
public enum StageEffect: Sendable, Equatable {
    case pan(Vec2)
    case toggle
}

private let stageDragThreshold: Float = 3.0

/// Pure transition function for `StageGesture` (`stage_step`).
public func stageStep(_ state: inout StageGesture, _ event: StageEvent) -> [StageEffect] {
    switch (state, event) {
    case (_, .pointerDown(let zoomed, let at)):
        state = zoomed ? .panning(moved: false, origin: at) : .idle
        return []
    case (.panning(let moved, let origin), .pointerMoved(let at)):
        let dx = at.x - origin.x
        let dy = at.y - origin.y
        if (dx == 0 && dy == 0) || (!moved && hypot(dx, dy) < stageDragThreshold) {
            return []
        }
        state = .panning(moved: true, origin: at)
        return [.pan(Vec2(dx, dy))]
    case (.panning(let moved, _), .pointerUp):
        state = moved ? .suppressClick : .idle
        return []
    case (.panning, .pointerCancel):
        state = .idle
        return []
    case (.panning, .zoomChanged(zoomed: false)):
        state = .idle
        return []
    case (.suppressClick, .click):
        state = .idle
        return []
    case (.idle, .click):
        return [.toggle]
    default:
        return []
    }
}

/// Artifact pane image zoom & pan state (`rune_kit::image_zoom::StageZoom`).
public struct StageZoom: Sendable, Equatable {
    public var zoom: Float
    public var pan: Vec2
    public var gesture: StageGesture
    public var fit: Float
    public var size: Vec2
    public var natural: Vec2

    public init(
        zoom: Float = 1.0,
        pan: Vec2 = .zero,
        gesture: StageGesture = .idle,
        fit: Float = 1.0,
        size: Vec2 = .zero,
        natural: Vec2 = Vec2(1, 1)
    ) {
        self.zoom = zoom
        self.pan = pan
        self.gesture = gesture
        self.fit = fit
        self.size = size
        self.natural = natural
    }

    public var isZoomed: Bool { zoom > 1.0 }
    public func minZoom() -> Float { min(0.25, 1.0 / fit) }
    public func maxZoom() -> Float { max(8.0, 1.0 / fit) }

    private func bound(_ offset: Float, naturalAxis: Float) -> Float {
        let limit = max(naturalAxis * fit * (zoom - 1.0) * 0.5, 0.0)
        return min(max(offset, -limit), limit)
    }

    public mutating func setPan(_ next: Vec2) {
        pan = Vec2(bound(next.x, naturalAxis: natural.x), bound(next.y, naturalAxis: natural.y))
    }

    public mutating func setZoom(_ nextZoom: Float, pan nextPan: Vec2, tx: inout Tx) {
        zoom = nextZoom
        setPan(nextPan)
        _ = run(.zoomChanged(zoomed: nextZoom > 1.0), tx: &tx)
        tx.settle()
    }

    public mutating func reset(tx: inout Tx) {
        setZoom(1.0, pan: .zero, tx: &tx)
    }

    public mutating func zoomAt(_ nextZoom: Float, at: Vec2, tx: inout Tx) {
        let next = min(max(nextZoom, minZoom()), maxZoom())
        let ratio = next / zoom
        let ax = at.x - size.x * 0.5
        let ay = at.y - size.y * 0.5
        setZoom(next, pan: Vec2(ax - (ax - pan.x) * ratio, ay - (ay - pan.y) * ratio), tx: &tx)
    }

    public mutating func zoomBy(_ factor: Float, tx: inout Tx) {
        zoomAt(zoom * factor, at: Vec2(size.x * 0.5, size.y * 0.5), tx: &tx)
    }

    @discardableResult
    public mutating func run(_ event: StageEvent, tx: inout Tx) -> Vec2? {
        var toggleAt: Vec2?
        for effect in stageStep(&gesture, event) {
            switch effect {
            case .pan(let d):
                setPan(Vec2(pan.x + d.x, pan.y + d.y))
                tx.settle()
            case .toggle:
                toggleAt = .zero
            }
        }
        return toggleAt
    }

    public mutating func measure(size: Vec2, natural rawNatural: Vec2, grows: Bool) {
        let nw = max(rawNatural.x, 1.0)
        let nh = max(rawNatural.y, 1.0)
        let cap: Float = grows ? .infinity : 1.0
        self.fit = min(cap, min(max(size.x - 48.0, 1.0) / nw, max(size.y - 48.0, 1.0) / nh))
        self.size = size
        self.natural = Vec2(nw, nh)
    }

    public func rect() -> [Float] {
        let w = natural.x * fit * zoom
        let h = natural.y * fit * zoom
        let px = bound(pan.x, naturalAxis: natural.x)
        let py = bound(pan.y, naturalAxis: natural.y)
        return [size.x * 0.5 + px - w * 0.5, size.y * 0.5 + py - h * 0.5, w, h]
    }
}

/// Artifact stage view with bottom-right `PreviewControls` (`rune_kit::image_zoom::Stage`).
public struct Stage<State> {
    private let keyPath: WritableKeyPath<State, StageZoom>
    private let natural: Vec2
    private let image: El<State>
    private var growsFlag: Bool = false
    private var customIcons: (zoomIn: SVGIcon, zoomOut: SVGIcon, fit: SVGIcon)?
    private var labelStrings: (zoomIn: String, zoomOut: String, fit: String, group: String) = (
        "Zoom in", "Zoom out", "Fit", "Preview controls"
    )

    public init(
        _ keyPath: WritableKeyPath<State, StageZoom>,
        natural: Vec2,
        image: El<State>
    ) {
        self.keyPath = keyPath
        self.natural = natural
        self.image = image
    }

    public func grows(_ on: Bool) -> Self {
        var copy = self
        copy.growsFlag = on
        return copy
    }

    public func icons(zoomIn: SVGIcon, zoomOut: SVGIcon, fit: SVGIcon) -> Self {
        var copy = self
        copy.customIcons = (zoomIn, zoomOut, fit)
        return copy
    }

    public func labels(zoomIn: String, zoomOut: String, fit: String, group: String) -> Self {
        var copy = self
        copy.labelStrings = (zoomIn, zoomOut, fit, group)
        return copy
    }

    public func build(_ zoom: StageZoom, kit k: Kit, size: Vec2) -> El<State> {
        var measured = zoom
        measured.measure(size: size, natural: natural, grows: growsFlag)
        let r = measured.rect()
        let kp = keyPath
        let growsLocal = growsFlag
        let nat = natural

        let placedImage = image
            .absolute(x: r[0], y: r[1])
            .size(r[2], r[3])
            .onPointerDown { s, press, tx in
                s[keyPath: kp].measure(size: size, natural: nat, grows: growsLocal)
                let rect = s[keyPath: kp].rect()
                let at = Vec2(rect[0] + press.local.x, rect[1] + press.local.y)
                _ = s[keyPath: kp].run(.pointerDown(zoomed: s[keyPath: kp].isZoomed, at: at), tx: &tx)
            }
            .onDrag { s, drag, tx in
                let rect = s[keyPath: kp].rect()
                let at = Vec2(rect[0] + drag.local.x, rect[1] + drag.local.y)
                _ = s[keyPath: kp].run(.pointerMoved(at: at), tx: &tx)
            }
            .onDragEnd { s, cancelled, tx in
                if cancelled {
                    _ = s[keyPath: kp].run(.pointerCancel, tx: &tx)
                }
            }
            .onPointerUp { s, press, tx in
                let rect = s[keyPath: kp].rect()
                let at = Vec2(rect[0] + press.local.x, rect[1] + press.local.y)
                _ = s[keyPath: kp].run(.pointerUp, tx: &tx)
                if s[keyPath: kp].run(.click, tx: &tx) != nil {
                    if s[keyPath: kp].zoom != 1.0 {
                        s[keyPath: kp].reset(tx: &tx)
                    } else {
                        let fit = s[keyPath: kp].fit
                        s[keyPath: kp].zoomAt(1.0 / fit, at: at, tx: &tx)
                    }
                }
            }

        let controls = buildControls(zoom: measured, kit: k, size: size)

        return el()
            .key("artifact-stage")
            .wFull()
            .grow(1)
            .minH(0)
            .bg(k.c.layer01)
            .clip(true)
            .onWheel { s, ev, tx in
                s[keyPath: kp].measure(size: size, natural: nat, grows: growsLocal)
                let pinch = ev.mods.ctrl || ev.mods.cmd
                if !pinch && s[keyPath: kp].zoom <= 1.0 { return false }
                if pinch {
                    let cur = s[keyPath: kp].zoom
                    s[keyPath: kp].zoomAt(cur * exp(ev.dy / 100.0), at: Vec2(size.x * 0.5, size.y * 0.5), tx: &tx)
                } else {
                    let p = s[keyPath: kp].pan
                    s[keyPath: kp].setPan(Vec2(p.x + ev.dx, p.y + ev.dy))
                    tx.settle()
                }
                return true
            }
            .child(placedImage)
            .child(controls)
    }

    private func buildControls(zoom: StageZoom, kit k: Kit, size: Vec2) -> El<State> {
        let kp = keyPath
        let growsLocal = growsFlag
        let nat = natural
        let icons = customIcons ?? (zoomIn: KitIcons.plus, zoomOut: k.glyph.dash, fit: KitIcons.search)

        func divider() -> El<State> {
            el().size(0.5, 20).mx(4).bg(k.c.borderBase)
        }

        func btn(key: String, svg: SVGIcon, label: String, disabled: Bool, action: @escaping (inout StageZoom, inout Tx) -> Void) -> El<State> {
            k.iconButton(key: key, svg: svg, label: label, size: .lg, variant: .ghost, disabled: disabled) { s, tx in
                s[keyPath: kp].measure(size: size, natural: nat, grows: growsLocal)
                action(&s[keyPath: kp], &tx)
            }
        }

        return k.elevate(
            row()
                .key("preview-controls")
                .role(.group)
                .label(labelStrings.group)
                .p(4)
                .itemsCenter()
                .rounded(8)
                .bg(k.c.bgBase)
                .border(0.5, k.c.borderBase)
                .pin(right: 12, bottom: 12)
                .child(btn(key: "stage-zoom-in", svg: icons.zoomIn, label: labelStrings.zoomIn, disabled: zoom.zoom >= zoom.maxZoom()) { z, tx in z.zoomBy(1.25, tx: &tx) })
                .child(divider())
                .child(btn(key: "stage-zoom-out", svg: icons.zoomOut, label: labelStrings.zoomOut, disabled: zoom.zoom <= zoom.minZoom()) { z, tx in z.zoomBy(1.0 / 1.25, tx: &tx) })
                .child(divider())
                .child(btn(key: "stage-fit", svg: icons.fit, label: labelStrings.fit, disabled: false) { z, tx in z.reset(tx: &tx) }),
            k.elevation.raised
        )
    }
}
