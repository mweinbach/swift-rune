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
        max(maxNaturalZoom / max(fitRatio, 0.0001), 1.0)
    }

    public static func detailScale(fitRatio: Float) -> Float {
        let actual = 1.0 / max(fitRatio, 0.0001)
        return actual >= 1.5 ? actual : 2.0
    }

    public static func wheelZoomFactor(deltaY: Float) -> Float {
        exp(-deltaY.clamped(to: -30.0...30.0) / 100.0)
    }

    public static func clampAxis(offset: Float, size: Float, viewport: Float) -> Float {
        let limit = max((size - viewport) / 2.0, 0.0)
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
        let next = scale.clamped(to: 1.0...max(bounds.maxScale, 1.0))
        let ratio = next / max(view.scale, 0.0001)
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
    public var isOpen: Bool
    public var bounds: ZoomBounds

    public init(
        view: ZoomView = .fit,
        isOpen: Bool = false,
        bounds: ZoomBounds = ZoomBounds()
    ) {
        self.view = view
        self.glide = ImageZoomGlide(view: view)
        self.gesture = .idle
        self.isOpen = isOpen
        self.bounds = bounds
    }

    public var isZoomed: Bool { view.scale > 1.001 }

    public var isDragging: Bool {
        if case .panning = gesture { return true }
        return false
    }

    public mutating func openLightbox() {
        isOpen = true
        reset()
    }

    public mutating func closeLightbox() {
        isOpen = false
        gesture = .idle
    }

    public mutating func reset() {
        view = .fit
        glide = ImageZoomGlide(view: .fit)
        gesture = .idle
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
