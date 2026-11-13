import Foundation
import Rune
import RuneMotion

// MARK: - Toast & ToastStack (`rune_kit::toast` + `rune_kit::toast_stack`)

/// Variant / visual tone for `Toast` (`rune_kit::toast::Variant`).
public typealias ToastVariant = BadgeTone

/// Sonner stack layout & motion constants (`rune_kit::toast_stack`).
public enum ToastMetrics {
    public static let gap: Float = 12.0
    public static let peek: Float = 12.0
    public static let shrink: Float = 0.05
    public static let visible: Int = 3
    public static let moveSecs: Float = 0.28
    public static let fadeSecs: Float = 0.16
    public static let contentFadeSecs: Float = 0.4
    public static let toastWidth: Float = 320.0
    public static let regionRight: Float = 32.0
    public static let regionBottom: Float = 48.0
}

/// Item descriptor used by `Kit.toastStack(toasts:...)`.
public struct ToastEntry: Sendable, Equatable {
    public var id: String
    public var message: String
    public var description: String?
    public var tone: BadgeTone
    public var actionLabel: String?

    public init(
        id: String,
        message: String,
        description: String? = nil,
        tone: BadgeTone = .neutral,
        actionLabel: String? = nil
    ) {
        self.id = id
        self.message = message
        self.description = description
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

/// Whether the window hosting the toast stack is shown (`rune_kit::toast_stack::ToastPage`).
public enum ToastPage: Sendable, Equatable, Hashable {
    case shown
    case hidden
}

/// Sonner stack interaction state (`rune_kit::toast_stack::ToastStackState`).
public enum ToastStackState: Sendable, Equatable, Hashable {
    case collapsed
    case expanded
    case held(left: Bool)

    public var isExpanded: Bool {
        self != .collapsed
    }
}

/// Auto-dismiss clock state for an entry in `ToastStack` (`rune_kit::toast_stack::ToastTimer`).
public enum ToastTimer: Sendable, Equatable {
    case forever
    case running(due: Double)
    case paused(left: Double)
}

/// Sonner toast entry stored in `ToastStack.entries` (`rune_kit::toast_stack::ToastEntry<O>`).
public struct ToastStackEntry<Payload: Sendable>: Sendable {
    public let id: UInt64
    public var key: String
    public var options: Payload
    public var timer: ToastTimer

    public init(id: UInt64, key: String, options: Payload, timer: ToastTimer) {
        self.id = id
        self.key = key
        self.options = options
        self.timer = timer
    }
}

extension ToastStackEntry: Equatable where Payload: Equatable {}

/// Events stepping the Sonner `ToastStack` machine (`rune_kit::toast_stack::ToastEvent`).
public enum ToastEvent<Payload: Sendable>: Sendable {
    case shown(key: String, options: Payload, secs: Double?, now: Double)
    case dismissed(id: UInt64?, now: Double)
    case pointerOver(now: Double)
    case pointerLeft(now: Double)
    case pressed(now: Double)
    case released(now: Double)
    case hotkey(now: Double)
    case escape(now: Double)
    case tick(now: Double)
    case page(ToastPage, now: Double)
}

/// Effects returned from `ToastStack.step(_:)` (`rune_kit::toast_stack::ToastEffect`).
public enum ToastEffect: Sendable, Equatable {
    case pulse(UInt64)
    case closed(UInt64)
    case wakeAt(Double)
}

/// Computed Sonner placement for a toast relative to the front toast (`rune_kit::toast_stack::ToastPlacement`).
public struct ToastSlotPlacement: Sendable, Equatable {
    public var lift: Float
    public var scale: Float
    public var height: Float
    public var content: Bool
    public var visible: Bool
    public var index: Int

    public init(lift: Float, scale: Float, height: Float, content: Bool, visible: Bool, index: Int) {
        self.lift = lift
        self.scale = scale
        self.height = height
        self.content = content
        self.visible = visible
        self.index = index
    }
}

/// Pure timer phase for an individual active toast slot.
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
    @discardableResult
    public mutating func step(_ event: ToastTimerEvent) -> [ToastTimerEffect] {
        switch (self, event) {
        case (.expired, _):
            return []
        case (_, .dismiss):
            self = .expired
            return []
        case (.armed(let r), .pointerEnter):
            self = .paused(remaining: r)
            return []
        case (.paused(let r), .pointerLeave):
            self = .armed(remaining: r)
            return []
        case (.paused, .tick), (.paused, .pointerEnter), (.armed, .pointerLeave):
            return []
        case (.armed(let r), .tick(let dt)):
            guard dt > 0 else { return [] }
            if !r.isFinite {
                return []
            }
            let next = r - dt
            if next <= 0 {
                self = .expired
                return [.dismiss]
            }
            self = .armed(remaining: next)
            return []
        }
    }
}

/// Sonner toast stack state machine (`rune_kit::toast_stack::ToastStack<O>`), also preserving
/// bounded FIFO `visible`/`queued` slot helpers.
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

    // Legacy FIFO state
    public var maxVisible: Int
    public var defaultDuration: Double
    public private(set) var visible: [Slot] = []
    public private(set) var queued: [Slot] = []
    private var nextId: UInt64 = 1

    // Upstream Sonner state
    private var issued: UInt64 = 0
    public private(set) var entries: [ToastStackEntry<Payload>] = []
    public private(set) var stackState: ToastStackState = .collapsed
    public private(set) var page: ToastPage = .shown

    public init(maxVisible: Int = ToastMetrics.visible, defaultDuration: Double = 4.0) {
        self.maxVisible = max(1, maxVisible)
        self.defaultDuration = max(0, defaultDuration)
    }

    // MARK: - Sonner Stack API (`toast_stack.rs`)

    public var front: ToastStackEntry<Payload>? { entries.last }

    public var nextDue: Double? {
        entries.compactMap { entry in
            if case .running(let due) = entry.timer { return due }
            return nil
        }.min()
    }

    private var isClockPaused: Bool {
        stackState.isExpanded || page == .hidden
    }

    public func place(id: UInt64, height: (UInt64) -> Float) -> ToastSlotPlacement? {
        guard let at = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let index = entries.count - 1 - at
        let vis = index < ToastMetrics.visible
        let own = height(id)
        if stackState.isExpanded {
            let lift: Float = entries[(at + 1)...].reduce(0) { $0 + height($1.id) + ToastMetrics.gap }
            return ToastSlotPlacement(lift: lift, scale: 1.0, height: own, content: true, visible: vis, index: index)
        }
        if index == 0 {
            return ToastSlotPlacement(lift: 0.0, scale: 1.0, height: own, content: true, visible: vis, index: index)
        }
        let frontH = front.map { height($0.id) } ?? own
        let k = Float(index)
        return ToastSlotPlacement(
            lift: k * ToastMetrics.peek,
            scale: 1.0 - k * ToastMetrics.shrink,
            height: frontH,
            content: false,
            visible: vis,
            index: index
        )
    }

    @discardableResult
    public mutating func step(_ event: ToastEvent<Payload>) -> [ToastEffect] {
        let wasPaused = isClockPaused
        let beforeCount = entries.count
        var effects: [ToastEffect] = []
        let now: Double

        switch event {
        case .dismissed(let id, let t):
            if let id {
                entries.removeAll { $0.id == id }
            } else {
                entries.removeAll()
            }
            now = t

        case .shown(let key, let options, let secs, let t):
            effects.append(contentsOf: shown(key: key, options: options, secs: secs, now: t))
            now = t

        case .pointerOver(let t):
            if case .held = stackState {
                stackState = .held(left: false)
            } else {
                stackState = .expanded
            }
            now = t

        case .pointerLeft(let t):
            if case .held = stackState {
                stackState = .held(left: true)
            } else {
                stackState = .collapsed
            }
            now = t

        case .pressed(let t):
            stackState = .held(left: false)
            now = t

        case .released(let t):
            switch stackState {
            case .held(let left):
                stackState = left ? .collapsed : .expanded
            default:
                break
            }
            now = t

        case .hotkey(let t):
            if stackState == .collapsed {
                stackState = .expanded
            }
            now = t

        case .escape(let t):
            if stackState == .expanded {
                stackState = .collapsed
            }
            now = t

        case .tick(let t):
            entries.removeAll { entry in
                if case .running(let due) = entry.timer, t + 1e-3 >= due {
                    effects.append(.closed(entry.id))
                    return true
                }
                return false
            }
            now = t

        case .page(let nextPage, let t):
            page = nextPage
            now = t
        }

        if entries.count <= 1 && entries.count != beforeCount && stackState == .expanded {
            stackState = .collapsed
        }
        retime(wasPaused: wasPaused, now: now)
        if let due = nextDue {
            effects.append(.wakeAt(due))
        }
        return effects
    }

    private mutating func shown(key: String, options: Payload, secs: Double?, now: Double) -> [ToastEffect] {
        let timer: ToastTimer
        if let secs {
            timer = isClockPaused ? .paused(left: secs) : .running(due: now + secs)
        } else {
            timer = .forever
        }
        if let lastIndex = entries.indices.last, entries[lastIndex].key == key {
            entries[lastIndex].options = options
            entries[lastIndex].timer = timer
            return [.pulse(entries[lastIndex].id)]
        }
        entries.removeAll { $0.key == key }
        issued &+= 1
        entries.append(ToastStackEntry(id: issued, key: key, options: options, timer: timer))
        return []
    }

    private mutating func retime(wasPaused: Bool, now: Double) {
        switch (wasPaused, isClockPaused) {
        case (false, true):
            for i in entries.indices {
                if case .running(let due) = entries[i].timer {
                    entries[i].timer = .paused(left: max(0, due - now))
                }
            }
        case (true, false):
            for i in entries.indices {
                if case .paused(let left) = entries[i].timer {
                    entries[i].timer = .running(due: now + left)
                }
            }
        default:
            break
        }
    }

    // MARK: - Bounded FIFO Compatibility API

    public var queuedCount: Int { queued.count }
    public var totalCount: Int { visible.count + queued.count }
    public var isEmpty: Bool { visible.isEmpty && queued.isEmpty && entries.isEmpty }

    public func contains(id: UInt64) -> Bool {
        visible.contains(where: { $0.id == id })
            || queued.contains(where: { $0.id == id })
            || entries.contains(where: { $0.id == id })
    }

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

    public mutating func clear() {
        visible.removeAll()
        queued.removeAll()
        entries.removeAll()
    }

    public mutating func pause(id: UInt64) {
        guard let idx = visible.firstIndex(where: { $0.id == id }) else { return }
        _ = visible[idx].timer.step(.pointerEnter)
    }

    public mutating func resume(id: UInt64) {
        guard let idx = visible.firstIndex(where: { $0.id == id }) else { return }
        _ = visible[idx].timer.step(.pointerLeave)
    }

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

/// Fluent toast card matching `rune_kit::toast::Toast` (`@opencode/ui` feedback/toast).
public struct Toast<State> {
    public struct ActionItem {
        public var label: String
        public var primary: Bool
        public var handler: (inout State, inout Tx) -> Void
    }

    public var key: String
    public var titleText: String
    public var descriptionText: String?
    public var variant: ToastVariant
    public var customLead: El<State>?
    public var iconSvg: SVGIcon?
    public var iconColor: Color?
    public var actionItems: [ActionItem] = []
    public var closeHandler: ((inout State, inout Tx) -> Void)?
    public var showCloseWithoutHandler: Bool = false

    public var message: String {
        get { titleText }
        set { titleText = newValue }
    }

    public init(key: String = "toast", title: String, variant: ToastVariant = .neutral) {
        self.key = key
        self.titleText = title
        self.variant = variant
    }

    public init(
        key: String = "toast",
        message: String,
        variant: ToastVariant = .neutral,
        actionLabel: String? = nil,
        onAction: ((inout State, inout Tx) -> Void)? = nil,
        onDismiss: ((inout State, inout Tx) -> Void)? = nil
    ) {
        self.key = key
        self.titleText = message
        self.variant = variant
        if let actionLabel, let onAction {
            self.actionItems = [ActionItem(label: actionLabel, primary: false, handler: onAction)]
        }
        self.closeHandler = onDismiss
    }

    public func key(_ value: String) -> Self { var c = self; c.key = value; return c }
    public func description(_ value: String?) -> Self { var c = self; c.descriptionText = value; return c }
    public func variant(_ value: ToastVariant) -> Self { var c = self; c.variant = value; return c }
    public func tone(_ value: BadgeTone) -> Self { variant(value) }
    public func icon(_ svg: SVGIcon, color: Color? = nil) -> Self {
        var c = self
        c.iconSvg = svg
        c.iconColor = color
        c.customLead = nil
        return c
    }
    public func lead(_ element: El<State>) -> Self {
        var c = self
        c.customLead = element
        c.iconSvg = nil
        return c
    }
    public func action(
        _ label: String,
        primary: Bool = true,
        onClick: @escaping (inout State, inout Tx) -> Void
    ) -> Self {
        var c = self
        c.actionItems.append(ActionItem(label: label, primary: primary, handler: onClick))
        return c
    }
    public func onClose(_ handler: @escaping (inout State, inout Tx) -> Void) -> Self {
        var c = self
        c.closeHandler = handler
        return c
    }
    public func onDismiss(_ handler: @escaping (inout State, inout Tx) -> Void) -> Self {
        onClose(handler)
    }
    public func closable() -> Self {
        var c = self
        c.showCloseWithoutHandler = true
        return c
    }

    public func build(using kit: Kit) -> El<State> {
        let (bgCol, fgCol, borderCol, toneIcon): (Color, Color, Color, SVGIcon?) = {
            switch variant {
            case .neutral: return (kit.c.layer01, kit.c.textBase, .transparent, nil)
            case .accent: return (kit.c.layer01, kit.c.textBase, kit.c.bgAccent.alpha(0.45), KitIcons.info)
            case .success: return (kit.c.success.bg, kit.c.success.fg, kit.c.success.border, KitIcons.check)
            case .warning: return (kit.c.warning.bg, kit.c.warning.fg, kit.c.warning.border, KitIcons.info)
            case .danger: return (kit.c.danger.bg, kit.c.danger.fg, kit.c.danger.border, KitIcons.circleX)
            case .info: return (kit.c.info.bg, kit.c.info.fg, kit.c.info.border, KitIcons.info)
            }
        }()

        var contentCol: El<State> = col()
            .key("\(key)-content")
            .grow(1)
            .minW(0)
            .gap(4)
            .child(
                text(titleText)
                    .key("\(key)-title")
                    .font(kit.ty.uiMedium.lh(20))
                    .color(fgCol)
                    .ellipsis()
                    .a11yHidden()
            )
        if let descriptionText, !descriptionText.isEmpty {
            contentCol = contentCol.child(
                text(descriptionText)
                    .key("\(key)-description")
                    .font(kit.ty.ui)
                    .color(variant == .neutral ? kit.c.textMuted : fgCol.alpha(0.85))
                    .wFull()
                    .a11yHidden()
            )
        }

        var topRow: El<State> = row().key("\(key)-top").wFull().gap(12).itemsStart()
        if let customLead {
            topRow = topRow.child(el().key("\(key)-icon").w(16).h(20).center().a11yHidden().child(customLead))
        } else if let svg = iconSvg ?? toneIcon {
            let tint = iconColor ?? ((variant == .accent) ? kit.c.textAccent : (variant == .neutral ? kit.c.iconBase : fgCol))
            topRow = topRow.child(el().key("\(key)-icon").w(16).h(20).center().a11yHidden().child(Rune.icon(svg, size: 16).color(tint)))
        }
        topRow = topRow.child(contentCol)

        if closeHandler != nil || showCloseWithoutHandler {
            var closeBtn: El<State> = row()
                .key("\(key)-dismiss")
                .role(.button)
                .label("Close")
                .w(20)
                .h(20)
                .center()
                .rounded(4)
                .focusable()
                .focusRing(kit.c.borderFocus, offset: 0)
                .hover(kit.c.hover)
                .child(Rune.icon(kit.glyph.close, size: 16).color(kit.c.iconMuted).a11yHidden())
            if let closeHandler {
                closeBtn = closeBtn.onClick(closeHandler)
            }
            topRow = topRow.child(closeBtn)
        }

        var root: El<State> = col()
            .key(key)
            .role(.alert) // Blocked on @el: ElementRole.status
            .liveRegion(.polite)
            .label(titleText)
            .w(ToastMetrics.toastWidth)
            .p(12)
            .gap(12)
            .rounded(8)
            .bg(bgCol)
            .shadows(kit.shadowLayers(kit.elevation.floating))
            .transition(.move(edge: .bottom))
            .animate(Spring(duration: ToastMetrics.moveSecs, bounce: 0.0))
        if borderCol.a > 0 {
            root = root.border(1.0, borderCol)
        }
        if let descriptionText, !descriptionText.isEmpty {
            root = root.description(descriptionText)
        }
        root = root.child(topRow)

        if !actionItems.isEmpty {
            var actionsRow: El<State> = row().key("\(key)-actions").pl(28).gap(8).flexWrap()
            for (idx, act) in actionItems.enumerated() {
                let buttonVariant: ButtonVariant = act.primary ? .neutral : .ghost
                actionsRow = actionsRow.child(
                    kit.button(
                        key: idx == 0 ? "\(key)-action" : "\(key)-action-\(idx)",
                        act.label,
                        variant: buttonVariant,
                        size: .sm,
                        onClick: act.handler
                    )
                )
            }
            root = root.child(actionsRow)
        }
        return root
    }
}

/// Positioned viewport region holding a vertical stack of toasts (`rune_kit::toast_stack::ToastRegion`).
public struct ToastRegion<State> {
    public var key: String
    public var placement: ToastPlacement
    public var rightInset: Float
    public var bottomInset: Float
    public var inset: Float
    public var gap: Float
    public var zIndex: Int
    public var children: [El<State>]

    public init(
        key: String = "toast-region",
        placement: ToastPlacement = .bottomTrailing,
        inset: Float? = nil,
        gap: Float = ToastMetrics.gap,
        zIndex: Int = 95,
        children: [El<State>] = []
    ) {
        self.key = key
        self.placement = placement
        self.rightInset = inset ?? ToastMetrics.regionRight
        self.bottomInset = inset ?? ToastMetrics.regionBottom
        self.inset = inset ?? ToastMetrics.regionRight
        self.gap = gap
        self.zIndex = zIndex
        self.children = children
    }

    public func child(_ element: El<State>) -> Self {
        var copy = self
        copy.children.append(element)
        return copy
    }

    public func toast(_ element: El<State>) -> Self {
        child(element)
    }

    public func build() -> El<State> {
        var stack: El<State> = col()
            .key(key)
            .role(.region)
            .label("Notifications")
            .gap(gap)
            .z(zIndex)

        switch placement {
        case .topLeading:
            stack = stack.pin(top: inset, left: inset).itemsStart()
        case .topTrailing:
            stack = stack.pin(top: rightInset, right: rightInset).itemsEnd()
        case .bottomLeading:
            stack = stack.pin(bottom: bottomInset, left: inset).itemsStart()
        case .bottomTrailing:
            stack = stack.pin(right: rightInset, bottom: bottomInset).itemsEnd()
        case .bottomCenter:
            stack = stack.pin(right: inset, bottom: bottomInset, left: inset).itemsCenter()
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
        key: String = "toast-region",
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
                )
                .description(entry.description)
                .build(using: self)
            )
        }
        return region.build()
    }

    /// Renders a `ToastStack` queue with per-toast hover pause/resume and dismiss callbacks.
    public func toastStack<State, Payload: Sendable>(
        key: String = "toast-region",
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

    public func toast<State>(
        key: String,
        message: String,
        tone: BadgeTone = .neutral,
        actionLabel: String,
        onAction: @escaping (inout State, inout Tx) -> Void,
        onDismiss: ((inout State) -> Void)? = nil
    ) -> El<State> {
        Toast<State>(
            key: key,
            message: message,
            variant: tone,
            actionLabel: actionLabel,
            onAction: onAction,
            onDismiss: onDismiss.map { handler in { s, _ in handler(&s) } }
        ).build(using: self)
    }
}
