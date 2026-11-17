import Foundation

/// The Windows nonclient buttons Rune draws over an app's custom titlebar.
public enum TitlebarCaptionButton: String, Equatable, Sendable {
    case minimize, maximize, close
}

/// Pointer state reported by the window procedure for nonclient caption buttons.
public enum TitlebarCaptionState: Equatable, Sendable {
    case idle
    case hovered(TitlebarCaptionButton)
    case pressed(TitlebarCaptionButton, over: Bool)
}

extension Runtime {
    func setHeadlessWindowsTitlebar(_ titlebar: Titlebar?, borderless: Bool) {
        let base = borderless ? nil : titlebar
        kitHooks.titlebar.headlessWindowsTitlebar = base
        setBaseTitlebar(base)
        syncWindowsCaption(base.map { TitlebarCaption(height: cxSettings.titlebarOverride.over($0).height) })
    }

    /// Updates the Windows custom frame and the controls' reserved room in window points.
    public func syncWindowsCaption(_ caption: TitlebarCaption?) {
        setTitlebarInset(0)
        let width = caption.map { $0.buttonSize(scale: windowScale()).x * Float($0.buttons.count) } ?? 0
        let mirrored = caption?.mirrored == true
        setChromeInsets(ChromeInsets(leading: mirrored ? width : 0, trailing: mirrored ? 0 : width,
                                     height: caption?.height ?? 0))
        setCaption(caption)
    }
}

extension TitlebarCaption {
    fileprivate var buttons: [TitlebarCaptionButton] {
        guard !hidden else { return [] }
        return minimizable || maximizable ? [.minimize, .maximize, .close] : [.close]
    }

    fileprivate func buttonSize(scale: Float) -> SIMD2<Float> {
        func snap(_ value: Float) -> Float { max(1, (value * scale).rounded()) / scale }
        return SIMD2(snap(Titlebar.captionButtonWidth), snap(height))
    }

    private func enabled(_ button: TitlebarCaptionButton) -> Bool {
        switch button {
        case .minimize: return minimizable
        case .maximize: return maximizable
        case .close: return true
        }
    }

    static let frameKey = "rune-frame"
    static let buttonsKey = "rune-caption"

    /// Size the app separately so its padding, transform, and clip cannot move the caption.
    func frame<State>(around root: El<State>, symbol: Color, scale: Float, zoom: Float, fitHeight: Bool) -> El<State> {
        let frame = el().key(Self.frameKey).child(fitHeight ? root.wFull() : root.wFull().hFull())
        guard !hidden else { return frame }
        let windowScale = scale / zoom
        let size = buttonSize(scale: windowScale) / zoom
        let order = mirrored ? Array(buttons.reversed()) : buttons
        let strip: El<State> = row().key(Self.buttonsKey).dir(.ltr)
            .pin(top: 0, right: mirrored ? nil : 0, left: mirrored ? 0 : nil)
            .children(order.map { button($0, symbol: symbol, size: size, scale: scale, windowScale: windowScale) })
        return frame.child(strip)
    }

    private func button<State>(_ target: TitlebarCaptionButton, symbol: Color, size: SIMD2<Float>,
                               scale: Float, windowScale: Float) -> El<State> {
        let enabled = enabled(target)
        let red = Color(r: 0.8075, g: 0.0058, b: 0.0169)
        var fill = Color.transparent
        var ink = symbol
        if !enabled {
            ink = symbol.scaleAlpha(92.0 / 255)
        } else if state == .pressed(target, over: true) {
            fill = target == .close ? red.alpha(152.0 / 255) : symbol.scaleAlpha(51.0 / 255)
            if target == .close { ink = .white }
        } else if state == .hovered(target) {
            fill = target == .close ? red : symbol.scaleAlpha(26.0 / 255)
            if target == .close { ink = .white }
        }
        let label: String = switch target {
        case .minimize: "Minimize"
        case .maximize: maximized ? "Restore" : "Maximize"
        case .close: "Close"
        }
        var control: El<State> = el().key("rune-caption-\(target.rawValue)").role(.button).label(label)
            .focusable(false).disabled(!enabled).size(size.x, size.y).bg(fill)
            .child(glyph(target, ink: ink, size: size, scale: scale, windowScale: windowScale))
        if enabled {
            control = control.onClick { _, tx in
                switch target {
                case .minimize: tx.minimize()
                case .maximize: tx.toggleMaximized()
                case .close: tx.closeWindow()
                }
            }
        }
        return control
    }

    /// Build in device pixels so fractional DPI and app zoom keep the native stroke width.
    private func glyph<State>(_ target: TitlebarCaptionButton, ink: Color, size: SIMD2<Float>,
                              scale: Float, windowScale: Float) -> El<State> {
        let extent = (10 * windowScale).rounded()
        let stroke = max(1, windowScale.rounded())
        let point = 1 / scale
        let origin = SIMD2((((size.x * scale).rounded() - extent) / 2).rounded(.down),
                           (((size.y * scale).rounded() - extent) / 2).rounded(.down)) * point
        let shape: Shape
        switch target {
        case .minimize:
            let top = (extent / 2).rounded(.down)
            let vertices = [Vec2(0, top), Vec2(extent, top), Vec2(extent, top + stroke), Vec2(0, top + stroke)]
            shape = Shape().fill(vertices.map { Vec2($0.x * point, $0.y * point) }, color: ink)
        case .close:
            let end = extent * point
            let width = stroke * point * 1.05
            shape = Shape().line(Vec2.zero, Vec2(end, end), width: width, cap: .butt, color: ink)
                .line(Vec2(end, 0), Vec2(0, end), width: width, cap: .butt, color: ink)
        case .maximize:
            let half = stroke / 2
            let inset = maximized ? 2 * windowScale : 0
            let radius = (1.5 * windowScale).rounded(.down)
            let first = SIMD2(half, half + inset)
            let last = SIMD2(extent - half - inset, extent - half)
            let front = rounded(from: first, to: last, radius: radius, point: point)
            let outline = Shape().strokeWith(front, closed: true, width: stroke * point, cap: .round, color: ink)
            if maximized {
                let delta = SIMD2(inset, -inset)
                let back = rounded(from: first + delta, to: last + delta, radius: radius,
                                   topRight: radius * 2, point: point)
                let visible = back.filter { $0.y < (first.y - half) * point || $0.x > (last.x + half) * point }
                shape = outline.strokeWith(visible, closed: false, width: stroke * point, cap: .round, color: ink)
            } else {
                shape = outline
            }
        }
        return el().absolute(x: origin.x, y: origin.y).size(extent * point, extent * point).shape(shape).a11yHidden()
    }

    private func rounded(from first: SIMD2<Float>, to last: SIMD2<Float>, radius: Float, topRight: Float? = nil,
                         point: Float) -> [Vec2] {
        let corners = [first, SIMD2(last.x, first.y), last, SIMD2(first.x, last.y)]
        let signs: [SIMD2<Float>] = [SIMD2(1, 1), SIMD2(-1, 1), SIMD2(-1, -1), SIMD2(1, -1)]
        let degrees: [Float] = [180, 270, 0, 90]
        var path: [Vec2] = []
        for i in corners.indices {
            let r = i == 1 ? topRight ?? radius : radius
            let center = corners[i] + signs[i] * r
            let steps = r > 0 ? 4 : 0
            for j in 0...steps {
                // The nearest Float radians-per-degree keeps the rear outline's corner
                // on the same side of the strict front-outline clip as the native painter.
                let angle = (degrees[i] + 90 * Float(j) / Float(max(1, steps))) * Float(Double.pi / 180)
                let vertex = (center + SIMD2(cosf(angle), sinf(angle)) * r) * point
                path.append(Vec2(vertex.x, vertex.y))
            }
        }
        return path
    }
}
