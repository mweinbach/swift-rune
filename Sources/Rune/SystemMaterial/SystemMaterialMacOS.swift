import Foundation
import RuneMotion
#if canImport(simd)
import simd
#endif

// MARK: - System Material Parity (`system_material/mod.rs`)

public let MAX_NATIVE_MATERIALS: Int = 4

/// Controls whether `El.systemMaterial` uses native macOS material views or shader fallback fills.
public enum MaterialMode: String, Sendable, Equatable, Codable {
    case auto
    case native
    case legacy
    case unsynced
    case fallback

    /// Parses `RUNE_SYSTEM_MATERIAL` (`auto` | `native` | `legacy` | `unsynced` | `fallback` | `off`).
    public static func fromEnv(_ env: [String: String] = ProcessInfo.processInfo.environment) -> MaterialMode {
        guard let raw = env["RUNE_SYSTEM_MATERIAL"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else {
            return .auto
        }
        switch raw {
        case "fallback", "off", "0", "false", "shader":
            return .fallback
        case "legacy":
            return .legacy
        case "unsynced":
            return .unsynced
        case "native", "on", "1", "true":
            return .native
        default:
            return .auto
        }
    }
}

/// Coordinates AppKit `NSVisualEffectView` / `NSGlassEffectView` geometry updates with Metal presentation.
public enum PresentFlag: Sendable, Equatable {
    /// Normal immediate present (commit `CATransaction` alongside Metal drawable).
    case immediate
    /// Inside AppKit live-resize or appearance transition; commit synchronized `CATransaction`.
    case synchronized
    /// No native material slots changed or active; skip extra `CATransaction` churn.
    case skipped
}

/// Three-reason `CAMetalLayer.presentsWithTransaction` gate (`system_material::PresentFlag`).
public struct PresentSyncFlag: Sendable, Equatable {
    public var moving: Bool
    public var materials: Bool
    public var live: Bool

    public init(moving: Bool = false, materials: Bool = false, live: Bool = false) {
        self.moving = moving
        self.materials = materials
        self.live = live
    }

    public var isSynced: Bool {
        moving || materials || live
    }

    public mutating func setMoving(_ active: Bool) -> Bool? {
        let before = isSynced
        moving = active
        let after = isSynced
        return after == before ? nil : after
    }

    public mutating func setMaterials(_ active: Bool) -> Bool? {
        let before = isSynced
        materials = active
        let after = isSynced
        return after == before ? nil : after
    }

    public mutating func setLive(_ active: Bool) -> Bool? {
        let before = isSynced
        live = active
        let after = isSynced
        return after == before ? nil : after
    }
}

/// Assignment result of mapping arbitrary frame `MaterialDraw` requests onto the bounded 4-slot native pool.
public struct MaterialAssignment: Sendable, Equatable {
    public struct SlotBinding: Sendable, Equatable {
        public let slotIndex: Int
        public let draw: MaterialDraw
        public let clampedRadius: Float

        public init(slotIndex: Int, draw: MaterialDraw, clampedRadius: Float) {
            self.slotIndex = slotIndex
            self.draw = draw
            self.clampedRadius = clampedRadius
        }
    }

    public let nativeSlots: [SlotBinding]
    public let fallbackDraws: [MaterialDraw]
    public let presentFlag: PresentFlag

    public init(nativeSlots: [SlotBinding], fallbackDraws: [MaterialDraw], presentFlag: PresentFlag) {
        self.nativeSlots = nativeSlots
        self.fallbackDraws = fallbackDraws
        self.presentFlag = presentFlag
    }
}

public enum MaterialMath {
    /// Clamps material corner radius to `[0, min(w, h) * 0.5]` (`system_material::clamp_radius`).
    @inlinable
    public static func clampRadius(_ radius: Float, width: Float, height: Float) -> Float {
        let half = max(0.0, min(width, height) * 0.5)
        return min(max(radius, 0.0), half)
    }

    /// Clamps the maximum corner radius across `[tl, tr, br, bl]` (including negative continuous signs).
    @inlinable
    public static func clampRadius(_ radii: [Float], width: Float, height: Float) -> Float {
        var maxR: Float = 0.0
        for r in radii {
            let a = abs(r)
            if a > maxR { maxR = a }
        }
        return clampRadius(maxR, width: width, height: height)
    }

    /// Fallback translucent fill color matching `system_material::fallback_fill` when native views are disabled
    /// or `MAX_NATIVE_MATERIALS` (`4`) is exceeded.
    public static func fallbackFill(
        material: SystemMaterial,
        fill: SIMD4<Float>? = nil,
        dark: Bool = true,
        opacity: Float = 1.0
    ) -> SIMD4<Float> {
        let _ = material
        let a = min(max(opacity, 0.0), 1.0)
        if let fill, fill.w > 0.0 {
            return SIMD4<Float>(fill.x, fill.y, fill.z, fill.w * a)
        }
        let base = dark
            ? SIMD4<Float>(0.16, 0.16, 0.17, 0.94)
            : SIMD4<Float>(0.96, 0.96, 0.97, 0.94)
        return SIMD4<Float>(base.x, base.y, base.z, base.w * a)
    }

    /// Deterministically assigns visible `MaterialDraw` entries up to `MAX_NATIVE_MATERIALS` (`4`) and routes
    /// overflow / fallback-mode / zero-area draws to `fallbackDraws`.
    public static func assignSlots(
        _ draws: [MaterialDraw],
        mode: MaterialMode = .auto,
        liveResize: Bool = false,
        previousIds: [UInt64] = []
    ) -> MaterialAssignment {
        guard !draws.isEmpty else {
            return MaterialAssignment(
                nativeSlots: [],
                fallbackDraws: [],
                presentFlag: previousIds.isEmpty ? .skipped : .immediate
            )
        }
        if mode == .fallback {
            return MaterialAssignment(
                nativeSlots: [],
                fallbackDraws: draws,
                presentFlag: previousIds.isEmpty ? .skipped : .immediate
            )
        }

        // Preserve slot index stability across frames for matching `id`s (matches `system_material::assign`).
        var chosen: [MaterialAssignment.SlotBinding] = []
        var usedSlots = Set<Int>()
        var remaining: [MaterialDraw] = []

        for draw in draws {
            guard draw.rect.width > 0.5 && draw.rect.height > 0.5 && draw.opacity > 0.001 else {
                continue
            }
            if let prevSlot = previousIds.firstIndex(of: draw.id),
               prevSlot < MAX_NATIVE_MATERIALS,
               !usedSlots.contains(prevSlot)
            {
                usedSlots.insert(prevSlot)
                let r = clampRadius(draw.radius, width: Float(draw.rect.width), height: Float(draw.rect.height))
                chosen.append(.init(slotIndex: prevSlot, draw: draw, clampedRadius: r))
            } else {
                remaining.append(draw)
            }
        }

        var fallback: [MaterialDraw] = []
        for draw in remaining {
            if let freeSlot = (0..<MAX_NATIVE_MATERIALS).first(where: { !usedSlots.contains($0) }) {
                usedSlots.insert(freeSlot)
                let r = clampRadius(draw.radius, width: Float(draw.rect.width), height: Float(draw.rect.height))
                chosen.append(.init(slotIndex: freeSlot, draw: draw, clampedRadius: r))
            } else {
                fallback.append(draw)
            }
        }

        chosen.sort { $0.slotIndex < $1.slotIndex }
        let flag: PresentFlag = chosen.isEmpty && previousIds.isEmpty
            ? .skipped
            : (liveResize ? .synchronized : .immediate)
        return MaterialAssignment(nativeSlots: chosen, fallbackDraws: fallback, presentFlag: flag)
    }
}

#if os(macOS)
import AppKit
@preconcurrency import ObjectiveC
import QuartzCore

/// Watches `NSWindow.didEndLiveResizeNotification` and `NSWindow.didMoveNotification` to drive
/// `CAMetalLayer.presentsWithTransaction` via `PresentSyncFlag` (`system_material/macos.rs`).
@MainActor
public final class MaterialPresentWatcher {
    public var flag: PresentSyncFlag
    public weak var metalLayer: CAMetalLayer?
    private weak var windowObject: AnyObject?
    private var tokens: [NSObjectProtocol] = []

    public init(window: AnyObject? = nil, metalLayer: CAMetalLayer? = nil, flag: PresentSyncFlag = PresentSyncFlag()) {
        self.flag = flag
        self.metalLayer = metalLayer
        if let window {
            attach(window: window, metalLayer: metalLayer)
        }
    }

    isolated deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    public func attach(window: AnyObject, metalLayer: CAMetalLayer? = nil) {
        if let metalLayer {
            self.metalLayer = metalLayer
        }
        guard windowObject !== window else { return }
        detach()
        windowObject = window
        let center = NotificationCenter.default
        let liveEnd = center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.setLive(false)
            }
        }
        let moved = center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.setMoving(false)
            }
        }
        tokens = [liveEnd, moved]
    }

    public func detach() {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        tokens.removeAll()
        windowObject = nil
    }

    @discardableResult
    public func setLive(_ active: Bool, unsynced: Bool = false) -> Bool? {
        let changed = flag.setLive(active)
        if !unsynced, let v = changed {
            metalLayer?.presentsWithTransaction = v
        }
        return changed
    }

    @discardableResult
    public func setMaterials(_ active: Bool, unsynced: Bool = false) -> Bool? {
        let changed = flag.setMaterials(active)
        if !unsynced, let v = changed {
            metalLayer?.presentsWithTransaction = v
        }
        return changed
    }

    @discardableResult
    public func setMoving(_ active: Bool, unsynced: Bool = false) -> Bool? {
        let changed = flag.setMoving(active)
        if !unsynced, let v = changed {
            metalLayer?.presentsWithTransaction = v
        }
        return changed
    }
}

/// Flipped, hit-test-transparent `NSView` container hosting native `NSVisualEffectView` / `NSGlassEffectView` slots
/// behind the transparent Metal surface (`system_material/macos.rs`).
@MainActor
public final class RuneMaterialHost: NSView {
    private enum SlotKind {
        case glass
        case visualEffect
    }

    private struct SlotEntry {
        var kind: SlotKind
        var view: NSView
    }

    private var slots: [SlotEntry?] = Array(repeating: nil, count: MAX_NATIVE_MATERIALS)
    private var spareGlass: [NSView] = []
    private var spareVisual: [NSView] = []
    private var currentIds: [UInt64] = []
    private var isLiveResizing: Bool = false
    private weak var observedWindow: NSWindow?
    private weak var attachedMetalLayer: CAMetalLayer?
    public let syncWatcher = MaterialPresentWatcher()

    public override var isFlipped: Bool { true }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        // Material backdrops never intercept pointer/scroll events.
        nil
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func attach(to window: NSWindow, below metalView: NSView, metalLayer: CAMetalLayer? = nil) {
        guard let contentView = window.contentView else { return }
        if superview !== contentView {
            removeFromSuperview()
            frame = contentView.bounds
            autoresizingMask = [.width, .height]
            contentView.addSubview(self, positioned: .below, relativeTo: metalView)
        }
        attachedMetalLayer = metalLayer
        metalLayer?.zPosition = 1.0
        syncWatcher.attach(window: window, metalLayer: metalLayer)
        if observedWindow !== window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didEndLiveResizeNotification, object: observedWindow)
            observedWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleEndLiveResize),
                name: NSWindow.didEndLiveResizeNotification,
                object: window
            )
        }
    }

    @objc private func handleEndLiveResize(_ notification: Notification) {
        isLiveResizing = false
        _ = syncWatcher.setLive(false, unsynced: MaterialMode.fromEnv() == .unsynced)
    }

    public func setLiveResizing(_ active: Bool, mode: MaterialMode = MaterialMode.fromEnv()) {
        isLiveResizing = active
        _ = syncWatcher.setLive(active, unsynced: mode == .unsynced)
    }

    /// Applies physical-pixel `draws` (converted to points by `scale`) onto pooled native material slots
    /// inside an action-disabled `CATransaction`.
    @discardableResult
    public func apply(
        _ draws: [MaterialDraw],
        scale: CGFloat = 1.0,
        mode: MaterialMode = MaterialMode.fromEnv()
    ) -> MaterialAssignment {
        let pointDraws = draws.map { $0.points(scale: Float(scale)) }
        let assignment = MaterialMath.assignSlots(
            pointDraws,
            mode: mode,
            liveResize: isLiveResizing,
            previousIds: currentIds
        )
        let unsynced = (mode == .unsynced)
        _ = syncWatcher.setMaterials(!assignment.nativeSlots.isEmpty, unsynced: unsynced)

        guard assignment.presentFlag != .skipped else {
            return assignment
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        attachedMetalLayer?.zPosition = 1.0

        var activeSlotSet = Set<Int>()
        var nextIds = [UInt64](repeating: 0, count: MAX_NATIVE_MATERIALS)

        for binding in assignment.nativeSlots {
            let idx = binding.slotIndex
            guard idx >= 0 && idx < MAX_NATIVE_MATERIALS else { continue }
            activeSlotSet.insert(idx)
            nextIds[idx] = binding.draw.id

            let desiredKind: SlotKind = (binding.draw.material == .glass && mode != .legacy && Self.hasGlassClass)
                ? .glass
                : .visualEffect
            let view = ensureSlot(at: idx, kind: desiredKind)
            view.isHidden = false
            view.frame = NSRect(
                x: CGFloat(binding.draw.rect.x),
                y: CGFloat(binding.draw.rect.y),
                width: CGFloat(binding.draw.rect.width),
                height: CGFloat(binding.draw.rect.height)
            )
            view.alphaValue = CGFloat(min(max(binding.draw.opacity, 0.0), 1.0))

            if desiredKind == .glass {
                Self.setGlassCornerRadius(view, radius: CGFloat(binding.clampedRadius))
                if let layer = view.layer {
                    layer.cornerCurve = .continuous
                }
            } else if let vev = view as? NSVisualEffectView {
                vev.material = Self.nsMaterial(for: binding.draw.material)
                vev.blendingMode = binding.draw.blending == .withinWindow ? .withinWindow : .behindWindow
                vev.state = .active
                if let layer = vev.layer {
                    layer.cornerRadius = CGFloat(binding.clampedRadius)
                    layer.cornerCurve = binding.draw.continuous ? .continuous : .circular
                    layer.masksToBounds = binding.clampedRadius > 0
                }
            }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }

        // Hide inactive slots with `alphaValue = 0.0` rather than `isHidden = true` so Core Animation keeps slots warm.
        for idx in 0..<MAX_NATIVE_MATERIALS where !activeSlotSet.contains(idx) {
            if let entry = slots[idx] {
                entry.view.alphaValue = 0.0
            }
        }
        trimSpares()
        currentIds = nextIds.filter { $0 != 0 }
        return assignment
    }

    public func hideAll(mode: MaterialMode = MaterialMode.fromEnv()) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in slots {
            entry?.view.alphaValue = 0.0
        }
        CATransaction.commit()
        currentIds.removeAll()
        _ = syncWatcher.setMaterials(false, unsynced: mode == .unsynced)
    }

    private func ensureSlot(at index: Int, kind: SlotKind) -> NSView {
        if let existing = slots[index] {
            if existing.kind == kind {
                return existing.view
            }
            existing.view.alphaValue = 0.0
            recycleView(existing.view, kind: existing.kind)
        }
        let view = dequeueOrMakeView(kind: kind)
        if view.superview !== self {
            addSubview(view)
            view.displayIfNeeded()
        }
        slots[index] = SlotEntry(kind: kind, view: view)
        return view
    }

    private func dequeueOrMakeView(kind: SlotKind) -> NSView {
        switch kind {
        case .glass:
            if let reused = spareGlass.popLast() {
                return reused
            }
            if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
                let view = glassClass.init(frame: .zero)
                view.wantsLayer = true
                Self.setGlassStyle(view, style: 0)
                return view
            }
            fallthrough
        case .visualEffect:
            if let reused = spareVisual.popLast() {
                return reused
            }
            let vev = NSVisualEffectView(frame: .zero)
            vev.wantsLayer = true
            vev.material = .hudWindow
            vev.blendingMode = .behindWindow
            vev.state = .active
            return vev
        }
    }

    private func recycleView(_ view: NSView, kind: SlotKind) {
        switch kind {
        case .glass:
            spareGlass.append(view)
        case .visualEffect:
            spareVisual.append(view)
        }
    }

    private func trimSpares() {
        while spareGlass.count > 1 {
            let dead = spareGlass.removeFirst()
            dead.removeFromSuperview()
        }
        while spareVisual.count > 1 {
            let dead = spareVisual.removeFirst()
            dead.removeFromSuperview()
        }
    }

    private static var hasGlassClass: Bool {
        NSClassFromString("NSGlassEffectView") is NSView.Type
    }

    private static func setGlassCornerRadius(_ view: NSView, radius: CGFloat) {
        let sel = NSSelectorFromString("setCornerRadius:")
        guard view.responds(to: sel), let cls = object_getClass(view) else {
            view.layer?.cornerRadius = radius
            return
        }
        let imp = class_getMethodImplementation(cls, sel)
        typealias SetCornerRadiusFn = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        let fn = unsafeBitCast(imp, to: SetCornerRadiusFn.self)
        fn(view, sel, radius)
    }

    private static func setGlassStyle(_ view: NSView, style: Int) {
        let sel = NSSelectorFromString("setStyle:")
        guard view.responds(to: sel), let cls = object_getClass(view) else { return }
        let imp = class_getMethodImplementation(cls, sel)
        typealias SetStyleFn = @convention(c) (AnyObject, Selector, Int) -> Void
        let fn = unsafeBitCast(imp, to: SetStyleFn.self)
        fn(view, sel, style)
    }

    private static func nsMaterial(for material: SystemMaterial) -> NSVisualEffectView.Material {
        switch material {
        case .glass:
            return .popover
        case .popover:
            return .popover
        case .hudWindow:
            return .hudWindow
        case .sidebar:
            return .sidebar
        case .underWindowBackground:
            return .underWindowBackground
        case .menu:
            return .menu
        }
    }
}
#endif
