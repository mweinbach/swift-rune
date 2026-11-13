import Foundation
import Rune
import RuneMotion

/// Cardinal side relative to an anchor element (`rune::Side`).
public enum Side: String, Sendable, Hashable {
    case top
    case bottom
    case left
    case right

    public var runeSide: Rune.Side {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .left: .left
        case .right: .right
        }
    }
}

/// Alignment along the cross axis of an anchored overlay (`rune::Align`).
public enum Align: String, Sendable, Hashable {
    case start
    case center
    case end

    public var runeAlign: Rune.Align {
        switch self {
        case .start: .start
        case .center: .center
        case .end: .end
        }
    }
}

/// Where an overlay sits relative to its trigger (`rune_kit::Placement`).
public enum Placement: String, Sendable, Hashable {
    case top
    case topStart
    case topEnd
    case bottom
    case bottomStart
    case bottomEnd
    case left
    case right
    case rightStart

    public func split() -> (Side, Align) {
        switch self {
        case .top: (.top, .center)
        case .topStart: (.top, .start)
        case .topEnd: (.top, .end)
        case .bottom: (.bottom, .center)
        case .bottomStart: (.bottom, .start)
        case .bottomEnd: (.bottom, .end)
        case .left: (.left, .center)
        case .right: (.right, .center)
        case .rightStart: (.right, .start)
        }
    }
}

/// Building blocks for anchored surfaces (`rune_kit::popover`).
public enum PopoverAnchor {
    public static let viewportMargin: Float = 8.0

    /// Origin factor inside the overlay element for directional reveal scaling.
    public static func anchorOrigin(side: Side, align: Align) -> Vec2 {
        let along: Float = switch align {
        case .start: 0.0
        case .center: 0.5
        case .end: 1.0
        }
        return switch side {
        case .top: Vec2(along, 1.0)
        case .bottom: Vec2(along, 0.0)
        case .left: Vec2(1.0, along)
        case .right: Vec2(0.0, along)
        }
    }

    /// Computes `[x0, y0, x1, y1]` for a surface of `size` `(width, height)` next to `trigger`
    /// `[x0, y0, x1, y1]` inside `window` `(width, height)` with `gap` points separation.
    /// Flips to the opposite side or alignment when outside `[8, window - 8]` and clamps inside.
    public static func anchorRect(
        trigger: [Float],
        size: (Float, Float),
        placement: Placement,
        gap: Float,
        window: (Float, Float)
    ) -> [Float] {
        guard trigger.count >= 4 else { return [0, 0, size.0, size.1] }
        let (side, align) = placement.split()
        let (w, h) = size
        let (winW, winH) = window
        let margin = viewportMargin

        let tx0 = trigger[0]
        let ty0 = trigger[1]
        let tx1 = trigger[2]
        let ty1 = trigger[3]

        func posAlong(t0: Float, t1: Float, s: Float, win: Float, a: Align) -> Float {
            func candidate(_ al: Align) -> Float {
                switch al {
                case .start: return t0
                case .center: return (t0 + t1 - s) * 0.5
                case .end: return t1 - s
                }
            }
            var p = candidate(a)
            let fitsPrimary = p >= margin && p + s <= win - margin
            if !fitsPrimary {
                switch a {
                case .start:
                    let alt = candidate(.end)
                    if alt >= margin && alt + s <= win - margin { p = alt }
                case .end:
                    let alt = candidate(.start)
                    if alt >= margin && alt + s <= win - margin { p = alt }
                case .center:
                    break
                }
            }
            let maxOrigin = max(margin, win - margin - s)
            return min(max(p, margin), maxOrigin)
        }

        let x0: Float
        let y0: Float
        switch side {
        case .bottom, .top:
            func yFor(_ s: Side) -> Float {
                s == .bottom ? (ty1 + gap) : (ty0 - gap - h)
            }
            var y = yFor(side)
            if side == .bottom && y + h > winH - margin {
                let flipped = yFor(.top)
                if flipped >= margin { y = flipped }
            } else if side == .top && y < margin {
                let flipped = yFor(.bottom)
                if flipped + h <= winH - margin { y = flipped }
            }
            let maxY = max(margin, winH - margin - h)
            y0 = min(max(y, margin), maxY)
            x0 = posAlong(t0: tx0, t1: tx1, s: w, win: winW, a: align)

        case .left, .right:
            func xFor(_ s: Side) -> Float {
                s == .right ? (tx1 + gap) : (tx0 - gap - w)
            }
            var x = xFor(side)
            if side == .right && x + w > winW - margin {
                let flipped = xFor(.left)
                if flipped >= margin { x = flipped }
            } else if side == .left && x < margin {
                let flipped = xFor(.right)
                if flipped + w <= winW - margin { x = flipped }
            }
            let maxX = max(margin, winW - margin - w)
            x0 = min(max(x, margin), maxX)
            y0 = posAlong(t0: ty0, t1: ty1, s: h, win: winH, a: align)
        }

        return [x0, y0, x0 + w, y0 + h]
    }

    /// Surface chrome for popovers, menus, and selects (`popover::raised`).
    public static func raised<State>(_ k: Kit, _ element: El<State>, radius: Float? = nil) -> El<State> {
        let r = radius ?? k.radius.md
        let border = k.c.stdBorder.a > 0 ? k.c.stdBorder : k.c.borderBase
        return element
            .rounded(r)
            .bg(k.c.surfaceRaised)
            .border(1.0, k.alpha(border, 0.5))
            .shadows(k.shadowLayers(k.elevation.md.isEmpty ? k.elevation.floating : k.elevation.md))
            .onPointerDown { _, _, _ in }
    }

    /// A scroll viewport for long popup lists that shrinks cleanly with its surface (`popover::fit_scroll`).
    public static func fitScroll<State>(_ rows: El<State>, key: String = "scroll") -> El<State> {
        col()
            .key(key)
            .wFull()
            .shrink(1.0)
            .minH(0.0)
            .scrollY()
            .child(rows)
    }

    /// Mounts a full-window transparent press scrim that dismisses an open overlay (`overlay::scrim`).
    public static func scrim<State>(key: String, onClose: @escaping (inout State) -> Void) -> El<State> {
        el()
            .key(key)
            .a11yHidden()
            .absolute(x: 0.0, y: 0.0)
            .wFull()
            .hFull()
            .onClick { s, _ in onClose(&s) }
            .focusable(false)
    }

    /// Wraps an overlay's optional scrim and surface inside a single `.modal(true)` container so
    /// the scrim remains clickable while underlying page elements become inert.
    public static func modalOverlay<State>(
        key: String,
        z: Int = 60,
        scrim: El<State>?,
        content: El<State>
    ) -> El<State> {
        var wrapper: El<State> = el()
            .key("\(key)-modal")
            .absolute(x: 0.0, y: 0.0)
            .wFull()
            .hFull()
            .z(z)
            .modal(true)
        if let scrim {
            wrapper = wrapper.child(scrim.z(z))
        }
        wrapper = wrapper.child(content.z(z + 1))
        return wrapper
    }

    /// Mounts an anchored overlay surface into the window layer.
    /// Note: when core `El.anchored` / `El.anchoredFit` land, this wires into core layout anchoring;
    /// until then it positions via explicit offset/pinning so overlays mount, stay modal, and respond in headless Runtime.
    public static func anchored<State>(
        _ k: Kit,
        _ content: El<State>,
        anchor anchorKey: String,
        placement: Placement,
        gap: Float = 4.0,
        at point: (x: Float, y: Float)? = nil,
        window: Vec2? = nil,
        estimatedSize: (Float, Float) = (260.0, 200.0),
        instant: Bool = true
    ) -> El<State> {
        let fade = Transition.asymmetric(insertion: .identity, removal: .opacity)
            .springs(SpringPair(enter: MotionTokens.INSTANT, exit: Spring(duration: 0.25, bounce: 0.0)))
        var styled = content
            .transition(fade)
            .motionIntent(.cut)
            .tokenMotion(k.motion.overlay)
            .z(60)
        if instant {
            styled = styled.instantChanges()
        }
        if let point {
            let win = window ?? Vec2(800, 600)
            let rect = anchorRect(
                trigger: [point.x, point.y, point.x, point.y],
                size: estimatedSize,
                placement: placement,
                gap: gap,
                window: (win.x, win.y)
            )
            return styled.absolute(x: rect[0], y: rect[1])
        }
        let (side, align) = placement.split()
        if side == .top || side == .bottom {
            return styled.anchoredFit(anchorKey, side: side.runeSide, align: align.runeAlign, gap: gap)
        }
        return styled.anchored(anchorKey, side: side.runeSide, align: align.runeAlign, gap: gap)
    }
}

/// Mounts the primary body and any floating overlay `layer` items at the root (`rune_kit::root`).
public func root<State>(_ body: El<State>, _ layer: [El<State>]) -> El<State> {
    var container: El<State> = col().wFull().hFull().child(body)
    let ordered = layer.enumerated().sorted { a, b in
        if a.element.zIndex != b.element.zIndex {
            return a.element.zIndex < b.element.zIndex
        }
        return a.offset < b.offset
    }.map(\.element)
    for item in ordered {
        container = container.child(item)
    }
    return container
}

extension Kit {
    /// Mounts the primary body and any floating overlay `layer` items at the root (`rune_kit::root`).
    public func root<State>(_ body: El<State>, _ layer: [El<State>]) -> El<State> {
        RuneKit.root(body, layer)
    }
}

/// Anchored popover surface (`rune_kit::overlay::Popover`).
public struct Popover<State> {
    private let key: String
    private var triggerEl: El<State>?
    private var titleText: String?
    private var labelText: String?
    private var descriptionText: String?
    private var body: [El<State>] = []
    private var isOpen: Bool = false
    private var placementValue: Placement = .bottom
    private var gutterValue: Float = 4.0
    private var paddingValue: Float = 12.0
    private var closeHandler: ((inout State, inout Tx) -> Void)?

    public init(_ key: String) {
        self.key = key
    }

    public func trigger(_ el: El<State>) -> Popover<State> {
        var copy = self
        copy.triggerEl = el
        return copy
    }

    public func padding(_ p: Float) -> Popover<State> {
        var copy = self
        copy.paddingValue = p
        return copy
    }

    public func title(_ t: String) -> Popover<State> {
        var copy = self
        copy.titleText = t
        return copy
    }

    public func label(_ l: String) -> Popover<State> {
        var copy = self
        copy.labelText = l
        return copy
    }

    public func description(_ d: String) -> Popover<State> {
        var copy = self
        copy.descriptionText = d
        return copy
    }

    public func child(_ c: El<State>) -> Popover<State> {
        var copy = self
        copy.body.append(c)
        return copy
    }

    public func open(_ o: Bool) -> Popover<State> {
        var copy = self
        copy.isOpen = o
        return copy
    }

    public func placement(_ p: Placement) -> Popover<State> {
        var copy = self
        copy.placementValue = p
        return copy
    }

    public func gutter(_ g: Float) -> Popover<State> {
        var copy = self
        copy.gutterValue = g
        return copy
    }

    public func onClose(_ f: @escaping (inout State) -> Void) -> Popover<State> {
        var copy = self
        copy.closeHandler = { s, _ in
            f(&s)
        }
        return copy
    }

    public func onCloseTx(_ f: @escaping (inout State, inout Tx) -> Void) -> Popover<State> {
        var copy = self
        copy.closeHandler = f
        return copy
    }

    public func build(kit k: Kit, layer: inout [El<State>], cx: Cx<State>? = nil) -> El<State> {
        let anchorKey = "\(key)-trigger"
        let returnKey = triggerEl?.keyId ?? anchorKey
        var triggerWrap: El<State> = row().key(anchorKey)
        if let trig = triggerEl {
            triggerWrap = triggerWrap.child(trig.expanded(isOpen))
        }
        guard isOpen else {
            return triggerWrap
        }

        let c = k.c
        let strong = c.textStrong.a > 0 ? c.textStrong : c.textBase
        let descColor = c.stdText.a > 0 ? c.stdText : c.textMuted

        var content: El<State> = col()
            .key("\(key)-content")
            .role(.dialog)
            .minW(200.0)
            .maxW(320.0)

        if let lbl = labelText ?? titleText {
            content = content.label(lbl)
        }
        if let desc = descriptionText {
            content = content.description(desc)
        }

        if let title = titleText {
            var closeBtn: El<State> = k.iconButton(
                key: "\(key)-close",
                svg: KitIcons.close,
                label: "Close",
                size: .sm,
                variant: .ghost
            ) { s, tx in
                closeHandler?(&s, &tx)
                tx.focus(returnKey)
            }.key("close")
            closeBtn = closeBtn.size(20, 20)
            content = content.child(
                row()
                    .key("header")
                    .p(12.0)
                    .pb(0.0)
                    .gap(8.0)
                    .itemsCenter()
                    .justifyBetween()
                    .child(text(title).key("title").font(k.ty.bodyMedium).color(strong).grow(1.0).a11yHidden())
                    .child(closeBtn)
            )
        }

        if let desc = descriptionText {
            content = content.child(
                row().key("description").px(12.0).child(text(desc).font(k.ty.textSmall).color(descColor).a11yHidden())
            )
        }

        var bodyCol: El<State> = col().key("body").p(paddingValue).shrink(1.0).minH(0.0)
        for childEl in body {
            bodyCol = bodyCol.child(childEl)
        }
        content = content.child(bodyCol)

        if let close = closeHandler {
            let scrimEl: El<State> = el()
                .key("\(key)-scrim")
                .a11yHidden()
                .absolute(x: 0.0, y: 0.0)
                .wFull()
                .hFull()
                .onClick { s, tx in
                    close(&s, &tx)
                    tx.focus(returnKey)
                }
                .focusable(false)
            content = content
                .onKey { s, ev, tx in
                    if ev.key == .escape {
                        close(&s, &tx)
                        tx.focus(returnKey)
                        return true
                    }
                    return false
                }
            let anchoredSurface = PopoverAnchor.anchored(
                k,
                content,
                anchor: anchorKey,
                placement: placementValue,
                gap: gutterValue,
                window: cx?.viewport
            )
            let raisedSurface = PopoverAnchor.raised(k, anchoredSurface, radius: k.radius.md)
                .focusReturn(returnKey)
            layer.append(
                PopoverAnchor.modalOverlay(key: key, z: 60, scrim: scrimEl, content: raisedSurface)
                    .focusReturn(returnKey)
            )
        } else {
            let surface = PopoverAnchor.raised(k, content, radius: k.radius.md)
            layer.append(
                PopoverAnchor.anchored(k, surface, anchor: anchorKey, placement: placementValue, gap: gutterValue, window: cx?.viewport)
                    .focusReturn(returnKey)
            )
        }
        return triggerWrap
    }
}
