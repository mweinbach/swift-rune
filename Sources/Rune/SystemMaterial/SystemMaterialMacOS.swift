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

    /// The application runner reads its launch configuration once.
    static let launchMode = fromEnv()

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
        assignSlots(draws, mode: mode, liveResize: liveResize, owners: previousIds.map(Optional.some), materials: [])
    }

    fileprivate static func assignSlots(
        _ draws: [MaterialDraw], mode: MaterialMode, liveResize: Bool,
        owners: [UInt64?], materials: [SystemMaterial?]
    ) -> MaterialAssignment {
        let hasActive = owners.contains { $0 != nil }
        guard !draws.isEmpty else {
            return MaterialAssignment(
                nativeSlots: [],
                fallbackDraws: [],
                presentFlag: hasActive ? .immediate : .skipped
            )
        }
        if mode == .fallback {
            return MaterialAssignment(
                nativeSlots: [],
                fallbackDraws: draws,
                presentFlag: hasActive ? .immediate : .skipped
            )
        }

        // Preserve slot index stability across frames for matching `id`s (matches `system_material::assign`).
        var chosen: [MaterialAssignment.SlotBinding] = []
        var usedSlots = Set<Int>()
        var remaining: [MaterialDraw] = []

        let visible = draws.filter { $0.rect.width > 0 && $0.rect.height > 0 && $0.opacity > 0.001 }
        for draw in visible.prefix(MAX_NATIVE_MATERIALS) {
            if let prevSlot = owners.indices.prefix(MAX_NATIVE_MATERIALS).first(where: { i in
                owners[i] == draw.id && (materials.isEmpty || materials[i] == draw.material) && !usedSlots.contains(i)
            }) {
                usedSlots.insert(prevSlot)
                let r = clampRadius(draw.radius, width: Float(draw.rect.width), height: Float(draw.rect.height))
                chosen.append(.init(slotIndex: prevSlot, draw: draw, clampedRadius: r))
            } else {
                remaining.append(draw)
            }
        }

        let fallback = Array(visible.dropFirst(MAX_NATIVE_MATERIALS))
        for draw in remaining {
            let available = (0..<MAX_NATIVE_MATERIALS).filter { !usedSlots.contains($0) }
            if let freeSlot = available.first(where: { !materials.isEmpty && materials[$0] == draw.material })
                ?? available.first(where: { !materials.isEmpty && materials[$0] == nil })
                ?? available.first {
                usedSlots.insert(freeSlot)
                let r = clampRadius(draw.radius, width: Float(draw.rect.width), height: Float(draw.rect.height))
                chosen.append(.init(slotIndex: freeSlot, draw: draw, clampedRadius: r))
            }
        }

        chosen.sort { $0.slotIndex < $1.slotIndex }
        let flag: PresentFlag = chosen.isEmpty && !hasActive
            ? .skipped
            : (liveResize ? .synchronized : .immediate)
        return MaterialAssignment(nativeSlots: chosen, fallbackDraws: fallback, presentFlag: flag)
    }
}

#if os(macOS)
import AppKit
@preconcurrency import ObjectiveC
import QuartzCore

/// Ends live-resize presentation on AppKit's notification. Frame motion is held
/// until its last step has drawn, including steps that move the window's origin.
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
        tokens = [liveEnd]
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

@MainActor
private final class RuneMetalContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Flipped, hit-test-transparent `NSView` container hosting native `NSVisualEffectView` / `NSGlassEffectView` slots
/// behind the transparent Metal surface (`system_material/macos.rs`).
@MainActor
public final class RuneMaterialHost: NSView {
    private struct SlotEntry {
        let material: SystemMaterial
        let view: NSView
        var draw: MaterialDraw?
    }

    private var slots: [SlotEntry?] = Array(repeating: nil, count: MAX_NATIVE_MATERIALS)
    private var spares: [SystemMaterial: NSView] = [:]
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

    /// Transparent windows stack native backdrops and the Metal view as siblings.
    /// A subview of a Metal-backed content view would composite above its drawable.
    internal static func install(_ metalView: NSView, in window: NSWindow) {
        guard !window.isOpaque else {
            window.contentView = metalView
            return
        }
        let content = RuneMetalContentView(frame: metalView.frame)
        content.wantsLayer = true
        window.contentView = content
        metalView.frame = content.bounds
        metalView.autoresizingMask = [.width, .height]
        content.addSubview(metalView)
    }

    /// Keep AppKit geometry and Metal pixels in the same transaction while a
    /// window spring or a live resize changes its frame, even on opaque windows.
    internal static func syncWindowFrame(moving: Bool, live: Bool, host: RuneMaterialHost?, layer: CAMetalLayer) {
        let unsynced = MaterialMode.launchMode == .unsynced
        _ = host?.syncWatcher.setMoving(moving, unsynced: unsynced)
        let synced = !unsynced && (moving || live || host?.syncWatcher.flag.isSynced == true)
        if layer.presentsWithTransaction != synced { layer.presentsWithTransaction = synced }
    }

    /// AppKit geometry and the corresponding Metal drawable become visible in one transaction.
    internal static func present<T>(
        host: inout RuneMaterialHost?, draws: [MaterialDraw], in view: NSView,
        layer: CAMetalLayer, scale: CGFloat, mode: MaterialMode, _ draw: (Bool) -> T
    ) -> T {
        if host == nil && draws.isEmpty { return draw(layer.presentsWithTransaction && mode != .unsynced) }
        let native = view.window?.isOpaque == false && mode != .fallback
        if host == nil && native && !draws.isEmpty { host = RuneMaterialHost(frame: view.bounds) }
        guard let host else { return draw(layer.presentsWithTransaction && mode != .unsynced) }
        if mode == .unsynced {
            host.update(draws: draws, in: view, layer: layer, scale: scale, mode: mode)
            return draw(false)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        host.update(draws: draws, in: view, layer: layer, scale: scale, mode: mode)
        return draw(layer.presentsWithTransaction)
    }

    internal func update(draws: [MaterialDraw], in view: NSView, layer: CAMetalLayer, scale: CGFloat, mode: MaterialMode) {
        guard let window = view.window else { return }
        setLiveResizing(view.inLiveResize, mode: mode)
        guard !window.isOpaque, mode != .fallback, !draws.isEmpty else {
            hideAll(mode: mode)
            return
        }
        attach(to: window, below: view, metalLayer: layer)
        apply(draws, scale: scale, mode: mode)
    }

    public func attach(to window: NSWindow, below metalView: NSView, metalLayer: CAMetalLayer? = nil) {
        guard let contentView = window.contentView else { return }
        if superview !== contentView {
            removeFromSuperview()
            frame = contentView.bounds
            autoresizingMask = [.width, .height]
            contentView.addSubview(self, positioned: .below, relativeTo: metalView.superview === contentView ? metalView : nil)
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
        let pointDraws = draws.map {
            var draw = $0.points(scale: Float(scale))
            if draw.material == .glass && (mode == .legacy || !Self.hasGlassClass) { draw.material = .popover }
            return draw
        }
        let assignment = MaterialMath.assignSlots(
            pointDraws,
            mode: mode,
            liveResize: isLiveResizing,
            owners: slots.map { $0?.draw?.id }, materials: slots.map { $0?.material }
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

        var active = Set<Int>()
        for binding in assignment.nativeSlots {
            let idx = binding.slotIndex
            let draw = binding.draw
            active.insert(idx)
            if let old = slots[idx], old.material != draw.material {
                old.view.alphaValue = 0
                keepSpare(old.view, material: old.material)
                slots[idx] = nil
            }
            if slots[idx] == nil {
                let view = spares.removeValue(forKey: draw.material) ?? makeView(material: draw.material)
                if view.superview !== self { addSubview(view) }
                slots[idx] = SlotEntry(material: draw.material, view: view, draw: nil)
            }
            guard var slot = slots[idx] else { continue }
            let view = slot.view
            if slot.draw?.opacity != draw.opacity { view.alphaValue = CGFloat(draw.opacity.clamped(to: 0...1)) }
            if slot.draw?.rect != draw.rect || slot.draw?.radius != draw.radius ||
                slot.draw?.continuous != draw.continuous || slot.draw?.blending != draw.blending {
                view.frame = NSRect(x: CGFloat(draw.rect.x), y: CGFloat(draw.rect.y),
                                    width: CGFloat(draw.rect.width), height: CGFloat(draw.rect.height))
                if draw.material == .glass {
                    Self.setGlassCornerRadius(view, radius: CGFloat(binding.clampedRadius))
                } else if let effect = view as? NSVisualEffectView {
                    effect.blendingMode = draw.nsBlendingMode
                    effect.layer?.cornerRadius = CGFloat(binding.clampedRadius)
                    effect.layer?.cornerCurve = draw.continuous ? .continuous : .circular
                    effect.layer?.masksToBounds = binding.clampedRadius > 0
                }
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
            }
            slot.draw = draw
            slots[idx] = slot
        }

        for i in slots.indices where !active.contains(i) {
            if let slot = slots[i] {
                if slot.draw != nil { slot.view.alphaValue = 0 }
                keepSpare(slot.view, material: slot.material)
                slots[i] = nil
            }
        }
        return assignment
    }

    public func hideAll(mode: MaterialMode = MaterialMode.fromEnv()) {
        guard slots.contains(where: { $0 != nil }) else { return }
        _ = apply([], mode: mode)
    }

    private func keepSpare(_ view: NSView, material: SystemMaterial) {
        if let old = spares.updateValue(view, forKey: material), old !== view { old.removeFromSuperview() }
    }

    private func makeView(material: SystemMaterial) -> NSView {
        if material == .glass, let type = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let view = type.init(frame: .zero)
            view.wantsLayer = true
            Self.setGlassStyle(view, style: 0)
            return view
        }
        let effect = NSVisualEffectView(frame: .zero)
        effect.wantsLayer = true
        effect.material = Self.nsMaterial(for: material)
        effect.state = .active
        return effect
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
