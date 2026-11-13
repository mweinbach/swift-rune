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
    case fallback

    /// Parses `RUNE_SYSTEM_MATERIAL` (`auto` | `native` | `on` | `fallback` | `off`).
    public static func fromEnv(_ env: [String: String] = ProcessInfo.processInfo.environment) -> MaterialMode {
        guard let raw = env["RUNE_SYSTEM_MATERIAL"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else {
            return .auto
        }
        switch raw {
        case "fallback", "off", "0", "false", "shader":
            return .fallback
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

    /// Fallback translucent fill color matching `system_material::fallback_fill` when native views are disabled
    /// or `MAX_NATIVE_MATERIALS` (`4`) is exceeded.
    public static func fallbackFill(
        material: SystemMaterial,
        dark: Bool = true,
        opacity: Float = 1.0
    ) -> SIMD4<Float> {
        let a = min(max(opacity, 0.0), 1.0)
        let base: SIMD4<Float>
        switch (material, dark) {
        case (.glass, true):
            base = SIMD4<Float>(0.16, 0.17, 0.20, 0.68)
        case (.glass, false):
            base = SIMD4<Float>(0.94, 0.95, 0.97, 0.72)
        case (.hudWindow, true):
            base = SIMD4<Float>(0.10, 0.11, 0.13, 0.84)
        case (.hudWindow, false):
            base = SIMD4<Float>(0.90, 0.91, 0.93, 0.84)
        case (.popover, true), (.menu, true):
            base = SIMD4<Float>(0.14, 0.14, 0.16, 0.82)
        case (.popover, false), (.menu, false):
            base = SIMD4<Float>(0.96, 0.96, 0.98, 0.86)
        case (.sidebar, true):
            base = SIMD4<Float>(0.12, 0.13, 0.15, 0.78)
        case (.sidebar, false):
            base = SIMD4<Float>(0.92, 0.93, 0.95, 0.78)
        case (.underWindowBackground, true):
            base = SIMD4<Float>(0.09, 0.09, 0.11, 0.90)
        case (.underWindowBackground, false):
            base = SIMD4<Float>(0.88, 0.89, 0.91, 0.90)
        }
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
import QuartzCore

/// Flipped, hit-test-transparent `NSView` container hosting native `NSVisualEffectView` / `NSGlassEffectView` slots
/// behind the transparent Metal surface (`system_material/macos.rs`).
@MainActor
public final class RuneMaterialHost: NSView {
    private var effectSlots: [NSView] = []
    private var currentIds: [UInt64] = []
    private var isLiveResizing: Bool = false
    private weak var observedWindow: NSWindow?

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

    public func attach(to window: NSWindow, below metalView: NSView) {
        guard let contentView = window.contentView else { return }
        if superview !== contentView {
            removeFromSuperview()
            frame = contentView.bounds
            autoresizingMask = [.width, .height]
            contentView.addSubview(self, positioned: .below, relativeTo: metalView)
        }
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
    }

    public func setLiveResizing(_ active: Bool) {
        isLiveResizing = active
    }

    /// Applies `draws` onto pooled native material slots inside an action-disabled `CATransaction`.
    @discardableResult
    public func apply(
        _ draws: [MaterialDraw],
        mode: MaterialMode = MaterialMode.fromEnv()
    ) -> MaterialAssignment {
        let assignment = MaterialMath.assignSlots(
            draws,
            mode: mode,
            liveResize: isLiveResizing,
            previousIds: currentIds
        )
        guard assignment.presentFlag != .skipped else {
            return assignment
        }

        while effectSlots.count < MAX_NATIVE_MATERIALS {
            let v = makeBackdropView()
            v.isHidden = true
            addSubview(v)
            effectSlots.append(v)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var activeSlotSet = Set<Int>()
        var nextIds = [UInt64](repeating: 0, count: MAX_NATIVE_MATERIALS)

        for binding in assignment.nativeSlots {
            let idx = binding.slotIndex
            guard idx >= 0 && idx < effectSlots.count else { continue }
            activeSlotSet.insert(idx)
            nextIds[idx] = binding.draw.id
            let view = effectSlots[idx]
            view.isHidden = false
            view.frame = NSRect(
                x: CGFloat(binding.draw.rect.x),
                y: CGFloat(binding.draw.rect.y),
                width: CGFloat(binding.draw.rect.width),
                height: CGFloat(binding.draw.rect.height)
            )
            view.alphaValue = CGFloat(min(max(binding.draw.opacity, 0.0), 1.0))
            if let vev = view as? NSVisualEffectView {
                vev.material = Self.nsMaterial(for: binding.draw.material)
                vev.blendingMode = binding.draw.blending == .withinWindow ? .withinWindow : .behindWindow
                vev.state = .followsWindowActiveState
            }
            if let layer = view.layer {
                layer.cornerRadius = CGFloat(binding.clampedRadius)
                layer.cornerCurve = binding.draw.continuous ? .continuous : .circular
                layer.masksToBounds = binding.clampedRadius > 0
            }
        }

        for idx in 0..<effectSlots.count where !activeSlotSet.contains(idx) {
            effectSlots[idx].isHidden = true
        }
        currentIds = nextIds.filter { $0 != 0 }
        return assignment
    }

    public func hideAll() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for view in effectSlots {
            view.isHidden = true
        }
        CATransaction.commit()
        currentIds.removeAll()
    }

    private func makeBackdropView() -> NSView {
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let view = glassClass.init(frame: .zero)
            view.wantsLayer = true
            return view
        }
        let vev = NSVisualEffectView(frame: .zero)
        vev.wantsLayer = true
        vev.material = .hudWindow
        vev.blendingMode = .behindWindow
        vev.state = .followsWindowActiveState
        return vev
    }

    private static func nsMaterial(for material: SystemMaterial) -> NSVisualEffectView.Material {
        switch material {
        case .glass:
            return .hudWindow
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
