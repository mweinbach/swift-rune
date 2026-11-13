import Foundation
import Rune
import RuneMotion

// MARK: - Toast & ToastStack (`rune_kit::toast` + `rune_kit::toast_stack`)

/// Variant / visual tone for `Toast` (`rune_kit::toast::Variant`).
public typealias ToastVariant = BadgeTone

/// Item descriptor used by `Kit.toastStack(toasts:...)`.
public struct ToastEntry: Sendable, Equatable {
    public var id: String
    public var message: String
    public var tone: BadgeTone
    public var actionLabel: String?

    public init(
        id: String,
        message: String,
        tone: BadgeTone = .neutral,
        actionLabel: String? = nil
    ) {
        self.id = id
        self.message = message
        self.tone = tone
        self.actionLabel = actionLabel
    }
}

/// Screen edge/corner placement for `ToastRegion` and `Kit.toastStack`.
public enum ToastPlacement: Sendable, Hashable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
    case bottomCenter
}

/// Pure timer phase for an individual active toast slot (`rune_kit::toast_stack::TimerPhase`).
public enum ToastTimerPhase: Sendable, Equatable {
    case armed(remaining: Double)
    case paused(remaining: Double)
    case expired

    public var isExpired: Bool {
        if case .expired = self { return true }
        return false
    }

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    public var remaining: Double {
        switch self {
        case .armed(let r), .paused(let r): return r
        case .expired: return 0
        }
    }
}

/// Events consumed by `ToastTimerPhase.step(_:)`.
public enum ToastTimerEvent: Sendable, Equatable {
    case tick(Double)
    case pointerEnter
    case pointerLeave
    case dismiss
}

/// Effects emitted by `ToastTimerPhase.step(_:)`.
public enum ToastTimerEffect: Sendable, Equatable {
    case dismiss
}

extension ToastTimerPhase {
    /// Deterministic transition matching upstream `toast_stack.rs` hover-pause and auto-dismiss.
    public mutating func step(_ event: ToastTimerEvent) -> [ToastTimerEffect] {
        switch (self, event) {
        case (.expired, _):
            return []
        case (_, .dismiss):
            self = .expired
            return [.dismiss]
        case (.armed(let r), .pointerEnter):
            self = .paused(remaining: r)
            return []
        case (.paused(let r), .pointerLeave):
            self = .armed(remaining: r)
            return []
        case (.paused, .tick):
            return []
        case (.armed(let r), .tick(let dt)):
            guard dt > 0 else { return [] }
            if !r.isFinite { return [] }
            let next = r - dt
            if next <= 0 {
                self = .expired
                return [.dismiss]
            }
            self = .armed(remaining: next)
            return []
        default:
            return []
        }
    }
}

/// FIFO bounded queue + auto-dismiss timer state machine (`rune_kit::toast_stack::ToastStack<T>`).
public struct ToastStack<Payload: Sendable>: Sendable {
    public struct Slot: Sendable {
        public let id: UInt64
        public var payload: Payload
        public var duration: Double
        public var timer: ToastTimerPhase

        public init(id: UInt64, payload: Payload, duration: Double) {
            self.id = id
            self.payload = payload
            self.duration = duration
            self.timer = .armed(remaining: max(0, duration))
        }

        public var isPaused: Bool { timer.isPaused }
        public var remaining: Double { timer.remaining }
    }

    public var maxVisible: Int
    public var defaultDuration: Double
    public private(set) var visible: [Slot] = []
    public private(set) var queued: [Slot] = []
    private var nextId: UInt64 = 1

    public init(maxVisible: Int = 3, defaultDuration: Double = 4.0) {
        self.maxVisible = max(1, maxVisible)
        self.defaultDuration = max(0, defaultDuration)
    }

    public var queuedCount: Int { queued.count }
    public var totalCount: Int { visible.count + queued.count }
    public var isEmpty: Bool { visible.isEmpty && queued.isEmpty }

    public func contains(id: UInt64) -> Bool {
        visible.contains(where: { $0.id == id }) || queued.contains(where: { $0.id == id })
    }

    /// Pushes a toast onto the visible set or FIFO queue. Returns the assigned unique id.
    @discardableResult
    public mutating func push(_ payload: Payload, duration: Double? = nil) -> UInt64 {
        let id = nextId
        nextId &+= 1
        let ttl = duration ?? defaultDuration
        let slot = Slot(id: id, payload: payload, duration: ttl)
        if visible.count < maxVisible {
            visible.append(slot)
        } else {
            queued.append(slot)
        }
        return id
    }

    /// Dismisses a toast by id from either `visible` or `queued`, promoting FIFO replacements.
    @discardableResult
    public mutating func dismiss(id: UInt64) -> Bool {
        if let idx = visible.firstIndex(where: { $0.id == id }) {
            visible.remove(at: idx)
            promoteWaiting()
            return true
        }
        if let idx = queued.firstIndex(where: { $0.id == id }) {
            queued.remove(at: idx)
            return true
        }
        return false
    }

    /// Dismisses all visible and queued toasts.
    public mutating func clear() {
        visible.removeAll()
        queued.removeAll()
    }

    /// Pauses auto-dismiss countdown for a visible toast (typically on pointer hover).
    public mutating func pause(id: UInt64) {
        guard let idx = visible.firstIndex(where: { $0.id == id }) else { return }
        _ = visible[idx].timer.step(.pointerEnter)
    }

    /// Resumes auto-dismiss countdown for a visible toast.
    public mutating func resume(id: UInt64) {
        guard let idx = visible.firstIndex(where: { $0.id == id }) else { return }
        _ = visible[idx].timer.step(.pointerLeave)
    }

    /// Advances all non-paused visible timers by `dt` seconds, returning auto-dismissed ids in order.
    @discardableResult
    public mutating func tick(_ dt: Double) -> [UInt64] {
        guard dt > 0 else { return [] }
        var dismissed: [UInt64] = []
        var kept: [Slot] = []
        kept.reserveCapacity(visible.count)

        for var slot in visible {
            let effects = slot.timer.step(.tick(dt))
            if effects.contains(.dismiss) || slot.timer.isExpired {
                dismissed.append(slot.id)
            } else {
                kept.append(slot)
            }
        }
        visible = kept
        promoteWaiting()
        return dismissed
    }

    /// Updates `maxVisible` and immediately promotes queued items if slots opened up.
    public mutating func setMaxVisible(_ limit: Int) {
        maxVisible = max(1, limit)
        promoteWaiting()
    }

    private mutating func promoteWaiting() {
        while visible.count < maxVisible, !queued.isEmpty {
            visible.append(queued.removeFirst())
        }
    }
}

extension ToastStack.Slot: Equatable where Payload: Equatable {}
extension ToastStack: Equatable where Payload: Equatable {}

/// Fluent builder for an individual toast banner (`rune_kit::toast::Toast`).
public struct Toast<State> {
    public var key: String
    public var message: String
    public var variant: ToastVariant
    public var actionLabel: String?
    public var onAction: ((inout State, inout Tx) -> Void)?
    public var onDismiss: ((inout State, inout Tx) -> Void)?

    public init(
        key: String = "toast",
        message: String,
        variant: ToastVariant = .neutral,
        actionLabel: String? = nil,
        onAction: ((inout State, inout Tx) -> Void)? = nil,
        onDismiss: ((inout State, inout Tx) -> Void)? = nil
    ) {
        self.key = key
        self.message = message
        self.variant = variant
        self.actionLabel = actionLabel
        self.onAction = onAction
        self.onDismiss = onDismiss
    }

    public func key(_ value: String) -> Self {
        var copy = self
        copy.key = value
        return copy
    }

    public func variant(_ value: ToastVariant) -> Self {
        var copy = self
        copy.variant = value
        return copy
    }

    public func tone(_ value: BadgeTone) -> Self {
        variant(value)
    }

    public func action(_ label: String, onClick: @escaping (inout State, inout Tx) -> Void) -> Self {
        var copy = self
        copy.actionLabel = label
        copy.onAction = onClick
        return copy
    }

    public func onDismiss(_ handler: @escaping (inout State, inout Tx) -> Void) -> Self {
        var copy = self
        copy.onDismiss = handler
        return copy
    }

    public func build(using kit: Kit) -> El<State> {
        let (bgCol, fgCol, borderCol, leadingSvg): (Color, Color, Color, SVGIcon?) = {
            switch variant {
            case .neutral: return (kit.c.surfaceRaised, kit.c.textBase, kit.c.borderBase, nil)
            case .accent: return (kit.c.surfaceRaised, kit.c.textBase, kit.c.bgAccent.alpha(0.45), KitIcons.info)
            case .success: return (kit.c.success.bg, kit.c.success.fg, kit.c.success.border, KitIcons.check)
            case .warning: return (kit.c.warning.bg, kit.c.warning.fg, kit.c.warning.border, KitIcons.info)
            case .danger: return (kit.c.danger.bg, kit.c.danger.fg, kit.c.danger.border, KitIcons.circleX)
            case .info: return (kit.c.info.bg, kit.c.info.fg, kit.c.info.border, KitIcons.info)
            }
        }()

        var bar: El<State> = row()
            .key(key)
            .px(14)
            .py(10)
            .gap(10)
            .itemsCenter()
            .rounded(kit.radius.lg)
            .bg(bgCol)
            .border(1.0, borderCol)
            .shadows(kit.shadowLayers(kit.elevation.floating))
            .transition(Transition.push(from: .bottom).spring(kit.motion.overlay))

        if let leadingSvg {
            let iconColor = (variant == .accent) ? kit.c.textAccent : fgCol
            bar = bar.child(icon(leadingSvg, size: 15).color(iconColor))
        }
        bar = bar.child(text(message).font(kit.ty.uiMedium).color(fgCol))

        if let actionLabel, let onAction {
            bar = bar.child(
                kit.button(key: "\(key)-action", actionLabel, variant: .ghost, size: .sm, onClick: onAction)
            )
        }

        if let onDismiss {
            bar = bar.child(
                kit.iconButton(key: "\(key)-dismiss", svg: KitIcons.close, label: "Dismiss", size: .sm) { s, tx in
                    onDismiss(&s, &tx)
                }
            )
        }
        return bar
    }
}

/// Positioned viewport region holding a vertical stack of toasts (`rune_kit::toast_stack::ToastRegion`).
public struct ToastRegion<State> {
    public var key: String
    public var placement: ToastPlacement
    public var inset: Float
    public var gap: Float
    public var zIndex: Int
    public var children: [El<State>]

    public init(
        key: String = "toast-stack",
        placement: ToastPlacement = .bottomTrailing,
        inset: Float = 16,
        gap: Float = 8,
        zIndex: Int = 95,
        children: [El<State>] = []
    ) {
        self.key = key
        self.placement = placement
        self.inset = inset
        self.gap = gap
        self.zIndex = zIndex
        self.children = children
    }

    public func child(_ element: El<State>) -> Self {
        var copy = self
        copy.children.append(element)
        return copy
    }

    public func build() -> El<State> {
        var stack: El<State> = col()
            .key(key)
            .gap(gap)
            .z(zIndex)

        switch placement {
        case .topLeading:
            stack = stack.pin(top: inset, left: inset).itemsStart()
        case .topTrailing:
            stack = stack.pin(top: inset, right: inset).itemsEnd()
        case .bottomLeading:
            stack = stack.pin(bottom: inset, left: inset).itemsStart()
        case .bottomTrailing:
            stack = stack.pin(right: inset, bottom: inset).itemsEnd()
        case .bottomCenter:
            stack = stack.pin(right: inset, bottom: inset, left: inset).itemsCenter()
        }

        for item in children {
            stack = stack.child(item)
        }
        return stack
    }
}

extension Kit {
    /// Positioned stack of active toast notifications (`Kit::toast_stack`).
    public func toastStack<State>(
        key: String = "toast-stack",
        toasts: [ToastEntry],
        placement: ToastPlacement = .bottomTrailing,
        onDismiss: @escaping (inout State, String) -> Void
    ) -> El<State> {
        var region = ToastRegion<State>(key: key, placement: placement)
        for entry in toasts {
            let entryId = entry.id
            region = region.child(
                Toast<State>(
                    key: "\(key)-\(entryId)",
                    message: entry.message,
                    variant: entry.tone,
                    onDismiss: { s, _ in onDismiss(&s, entryId) }
                ).build(using: self)
            )
        }
        return region.build()
    }

    /// Renders a `ToastStack` queue with per-toast hover pause/resume and dismiss callbacks.
    public func toastStack<State, Payload: Sendable>(
        key: String = "toast-stack",
        _ stack: ToastStack<Payload>,
        placement: ToastPlacement = .bottomTrailing,
        hoverKeyPath: WritableKeyPath<State, ToastStack<Payload>>? = nil,
        render: (ToastStack<Payload>.Slot) -> Toast<State>
    ) -> El<State> {
        var region = ToastRegion<State>(key: key, placement: placement)
        for slot in stack.visible {
            var toastEl = render(slot).build(using: self)
            if let hoverKeyPath {
                let slotId = slot.id
                toastEl = toastEl.onHover { s, inside, _ in
                    if inside {
                        s[keyPath: hoverKeyPath].pause(id: slotId)
                    } else {
                        s[keyPath: hoverKeyPath].resume(id: slotId)
                    }
                }
            }
            region = region.child(toastEl)
        }
        return region.build()
    }
}
