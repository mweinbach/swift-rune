import Foundation
import RuneMotion

// MARK: - Monotonic Fade Fence (`crate::machine::Attempt` / `Seq`)

/// Monotonic generation token fencing async AppKit fade completions against newer show/hide transitions.
public struct FenceAttempt: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// Monotonic fence generator matching `crate::machine::Seq`.
public struct FenceSequence: Equatable, Sendable {
    public private(set) var last: UInt64 = 0

    public init() {}

    public mutating func next() -> FenceAttempt {
        last &+= 1
        return FenceAttempt(last)
    }
}

// MARK: - Native macOS Panel Presence State Machine (`platform/macos/presence.rs`)

/// Pure state machine governing whether a macOS overlay NSPanel belongs on screen,
/// whether capture exclusion is applied, and how prewarm/fade completions fence against newer requests.
public struct MacOSPanelPresence: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case orderedOut
        case prewarmed
        case shown(warming: Bool)
        case fadingIn(fence: FenceAttempt, warming: Bool)
        /// `seen`: whether the panel was ordered on screen when the hide started.
        case fadingOut(fence: FenceAttempt, seen: Bool, warming: Bool)

        static func atRest(warming: Bool) -> Phase {
            warming ? .prewarmed : .orderedOut
        }

        var isWarming: Bool {
            switch self {
            case .orderedOut:
                return false
            case .prewarmed:
                return true
            case let .shown(warming),
                 let .fadingIn(_, warming),
                 let .fadingOut(_, _, warming):
                return warming
            }
        }

        func withWarming(_ warming: Bool) -> Phase {
            switch self {
            case .orderedOut, .prewarmed:
                return .atRest(warming: warming)
            case .shown:
                return .shown(warming: warming)
            case let .fadingIn(fence, _):
                return .fadingIn(fence: fence, warming: warming)
            case let .fadingOut(fence, seen, _):
                return .fadingOut(fence: fence, seen: seen, warming: warming)
            }
        }
    }

    public enum Event: Equatable, Sendable {
        case show(fadeSeconds: Double)
        case hide(fadeSeconds: Double)
        case prewarmBegins
        case prewarmEnds
        case fadeEnded(fence: FenceAttempt)
        case request(exclude: Bool)
    }

    public enum Effect: Equatable, Sendable {
        /// `sharingType` `.none` when true, `.readOnly` when false.
        case setSharing(Bool)
        case rejoinSpaces
        case orderIn(clearAlpha: Bool)
        case orderOut
        case setAlpha(Double)
        case ignoreMouse
        /// Switches what `occlusionState` override reports (`drawsOccluded`).
        case drawOccluded(Bool)
        /// Animates alpha toward target over optional `(durationSeconds, fence)`.
        case fade(alpha: Double, overSeconds: Double?, fence: FenceAttempt?)
        case resignKey
    }

    public private(set) var phase: Phase = .orderedOut
    public private(set) var fences = FenceSequence()
    public private(set) var requested: Bool
    public private(set) var drawsOccluded: Bool = false

    public init(requested: Bool = false) {
        self.requested = requested
    }

    /// Whether capture exclusion (`sharingType == .none`) should currently be active.
    public var isExcluded: Bool {
        requested && isOrdered
    }

    /// Outside a scoped prewarm acquisition, only shown or fading-out-after-show panels are ordered in.
    public var isOrdered: Bool {
        switch phase {
        case .orderedOut, .prewarmed:
            return false
        case .shown, .fadingIn:
            return true
        case let .fadingOut(_, seen, _):
            return seen
        }
    }

    /// Whether the app wants the panel seen (from show until hide; false during fade-out).
    public var isVisible: Bool {
        switch phase {
        case .shown, .fadingIn:
            return true
        case .orderedOut, .prewarmed, .fadingOut:
            return false
        }
    }

    public func withDrawsOccluded(_ value: Bool) -> MacOSPanelPresence {
        var copy = self
        copy.drawsOccluded = value
        return copy
    }

    private var wantsDrawOccluded: Bool {
        if phase.isWarming { return true }
        switch phase {
        case .fadingIn, .fadingOut:
            return true
        case .orderedOut, .prewarmed, .shown:
            return false
        }
    }

    public mutating func step(_ event: Event) -> [Effect] {
        switch event {
        case let .show(fadeSeconds):
            return stepShow(fadeSeconds: fadeSeconds)
        case let .hide(fadeSeconds):
            return stepHide(fadeSeconds: fadeSeconds)
        case .prewarmBegins:
            phase = phase.withWarming(true)
            return [.setAlpha(0.0), .ignoreMouse, .orderIn(clearAlpha: false), .drawOccluded(true)]
        case .prewarmEnds:
            phase = phase.withWarming(false)
            var effects: [Effect] = [.drawOccluded(wantsDrawOccluded)]
            if !isOrdered {
                effects.append(.orderOut)
            }
            return effects
        case let .fadeEnded(fence):
            return stepFadeEnded(fence: fence)
        case let .request(exclude):
            requested = exclude
            return [.setSharing(isExcluded)]
        }
    }

    private mutating func stepShow(fadeSeconds: Double) -> [Effect] {
        let fence = fences.next()
        let warming = phase.isWarming
        let fading = fadeSeconds > 0.0
        phase = fading ? .fadingIn(fence: fence, warming: warming) : .shown(warming: warming)
        return [
            .setSharing(isExcluded),
            .rejoinSpaces,
            .orderIn(clearAlpha: fading),
            .drawOccluded(wantsDrawOccluded),
            .fade(alpha: 1.0, overSeconds: fading ? fadeSeconds : nil, fence: fading ? fence : nil)
        ]
    }

    private mutating func stepHide(fadeSeconds: Double) -> [Effect] {
        let fence = fences.next()
        let warming = phase.isWarming
        let fading = fadeSeconds > 0.0
        let seen = isOrdered
        phase = fading ? .fadingOut(fence: fence, seen: seen, warming: warming) : .atRest(warming: warming)
        var effects: [Effect] = [
            .drawOccluded(warming),
            .ignoreMouse,
            .drawOccluded(wantsDrawOccluded),
            .fade(alpha: 0.0, overSeconds: fading ? fadeSeconds : nil, fence: fading ? fence : nil)
        ]
        if !fading {
            effects.append(.orderOut)
        }
        effects.append(.resignKey)
        effects.append(.setSharing(isExcluded))
        return effects
    }

    private mutating func stepFadeEnded(fence ended: FenceAttempt) -> [Effect] {
        switch phase {
        case let .fadingIn(fence, warming) where fence == ended:
            phase = .shown(warming: warming)
            return [.drawOccluded(warming)]
        case let .fadingOut(fence, _, warming) where fence == ended:
            phase = .atRest(warming: warming)
            return [.drawOccluded(warming), .orderOut, .setSharing(isExcluded)]
        default:
            return []
        }
    }
}

public typealias OverlayPresenceMachine = MacOSPanelPresence

// MARK: - Overlay-Level Presence & GPU Release State (`overlay/presence.rs`)

/// What a hidden overlay does with its GPU surface.
public enum OverlayGpuRelease: Equatable, Sendable {
    case keep
    case now
    case after(Double)

    /// Mirrors `overlay::presence::Release::new`: macOS honors only `release_gpu_when_hidden` (`.now`),
    /// retaining prewarmed panels with non-zero `after` as `.keep`.
    public static func make(afterSeconds: Double?, isMacOS: Bool) -> OverlayGpuRelease {
        guard let afterSeconds else { return .keep }
        if afterSeconds <= 0.0 { return .now }
        if !isMacOS { return .after(afterSeconds) }
        return .keep
    }
}

public enum OverlayPresenceEvent: Equatable, Sendable {
    case show
    case hide(fadeSeconds: Double, now: Double)
    case due(now: Double)
}

public enum OverlayPresenceEffect: Equatable, Sendable {
    case stopDrawing
    case hideWindow(fadeSeconds: Double)
    case releaseGpu
}

/// High-level overlay drawing/visibility/release state matching `crates/rune/src/overlay/presence.rs`.
public enum OverlayPresence: Equatable, Sendable {
    case hidden(releaseAt: Double?)
    case shown(occluded: Bool)
    case fadingOut(until: Double, length: Double, occluded: Bool)

    public static let initial = OverlayPresence.hidden(releaseAt: nil)

    public var isShown: Bool {
        if case .shown = self { return true }
        return false
    }

    public var isDrawing: Bool {
        if case .hidden = self { return false }
        return true
    }

    public var isFading: Bool {
        if case .fadingOut = self { return true }
        return false
    }

    public var isOccluded: Bool {
        switch self {
        case let .shown(occluded), let .fadingOut(_, _, occluded):
            return occluded
        case .hidden:
            return false
        }
    }

    public var fadeEnd: Double? {
        if case let .fadingOut(until, _, _) = self { return until }
        return nil
    }

    public var releaseAt: Double? {
        if case let .hidden(releaseAt) = self { return releaseAt }
        return nil
    }

    public var deadline: Double? {
        switch self {
        case let .hidden(releaseAt):
            return releaseAt
        case .shown:
            return nil
        case let .fadingOut(until, _, _):
            return until
        }
    }

    @discardableResult
    public mutating func setOccluded(_ covered: Bool) -> Bool {
        switch self {
        case .fadingOut where covered:
            return false
        case .shown:
            self = .shown(occluded: covered)
            return true
        case let .fadingOut(until, length, _):
            self = .fadingOut(until: until, length: length, occluded: covered)
            return true
        case .hidden:
            return true
        }
    }

    public mutating func step(_ event: OverlayPresenceEvent, release: OverlayGpuRelease) -> [OverlayPresenceEffect] {
        switch (self, event) {
        case (.shown, .show):
            return []
        case (_, .show):
            self = .shown(occluded: false)
            return []
        case let (.shown(occluded), .hide(fadeSeconds, now)) where fadeSeconds > 0.0,
             let (.fadingOut(_, _, occluded), .hide(fadeSeconds, now)) where fadeSeconds > 0.0:
            self = .fadingOut(until: now + fadeSeconds, length: fadeSeconds, occluded: occluded)
            return [.hideWindow(fadeSeconds: fadeSeconds)]
        case let (.hidden, .hide(fadeSeconds, _)):
            return [.stopDrawing, .hideWindow(fadeSeconds: fadeSeconds)]
        case let (_, .hide(_, now)):
            return hideNow(now: now, release: release)
        case let (.fadingOut(until, _, _), .due(now)) where until <= now:
            return hideNow(now: now, release: release)
        case let (.hidden(releaseAt?), .due(now)) where releaseAt <= now:
            self = .hidden(releaseAt: nil)
            return [.releaseGpu]
        case (_, .due):
            return []
        }
    }

    private mutating func hideNow(now: Double, release: OverlayGpuRelease) -> [OverlayPresenceEffect] {
        let nextReleaseAt: Double?
        switch release {
        case let .after(after):
            nextReleaseAt = now + after
        case .keep, .now:
            nextReleaseAt = nil
        }
        self = .hidden(releaseAt: nextReleaseAt)
        var effects: [OverlayPresenceEffect] = [.stopDrawing, .hideWindow(fadeSeconds: 0.0)]
        if release == .now {
            effects.append(.releaseGpu)
        }
        return effects
    }
}

// MARK: - Overlay Options, Capabilities, Availability & Geometry (`overlay/options.rs`, `overlay.rs`)

public enum OverlayLevel: Int, Sendable, Equatable, Hashable {
    case status = 25
    case aboveStatus = 26
    case aboveOverlays = 27

    public var macosWindowLevel: Int { rawValue }
}

public enum OverlayInput: String, Sendable, Equatable, Hashable {
    case legacy
    case none
    case regions
    case all

    public func resolved(interactive: Bool) -> OverlayInput {
        switch self {
        case .legacy:
            return interactive ? .all : .none
        case .none, .regions, .all:
            return self
        }
    }
}

public enum OverlayAlign: String, Sendable, Equatable, Hashable {
    case start
    case center
    case end
}

public enum OverlayDisplayTarget: Sendable, Equatable {
    case primary
    case underPointer
    case id(RuneDisplayId)
    case native(NativeDisplayId)
}

public enum OverlaySupport: String, Sendable, Equatable, Hashable {
    case unknown
    case supported
    case requested
    case unsupported
    case failed
}

public struct OverlayCapabilities: Sendable, Equatable {
    public var captureExclusion: OverlaySupport
    public var nonactivatingKeys: OverlaySupport
    public var globalPointer: OverlaySupport

    public init(
        captureExclusion: OverlaySupport = .unknown,
        nonactivatingKeys: OverlaySupport = .unknown,
        globalPointer: OverlaySupport = .unknown
    ) {
        self.captureExclusion = captureExclusion
        self.nonactivatingKeys = nonactivatingKeys
        self.globalPointer = globalPointer
    }
}

public enum OverlayAvailability: String, Sendable, Equatable, Hashable {
    case pending
    case available
    case unavailable
}

public struct OverlayCreated: Sendable, Equatable {
    public var windowNumber: UInt32?
    public var capabilities: OverlayCapabilities

    public init(windowNumber: UInt32? = nil, capabilities: OverlayCapabilities = OverlayCapabilities()) {
        self.windowNumber = windowNumber
        self.capabilities = capabilities
    }
}

public struct OverlaySurfaceSnapshot: Sendable, Equatable {
    public var frameCount: UInt64
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var backingScale: Float
    public var srgbBlend: Bool
    public var isVisible: Bool
    public var isDrawing: Bool
    public var isAnimating: Bool

    public init(
        frameCount: UInt64 = 0,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        backingScale: Float = 1,
        srgbBlend: Bool = true,
        isVisible: Bool = false,
        isDrawing: Bool = false,
        isAnimating: Bool = false
    ) {
        self.frameCount = frameCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.backingScale = backingScale
        self.srgbBlend = srgbBlend
        self.isVisible = isVisible
        self.isDrawing = isDrawing
        self.isAnimating = isAnimating
    }
}

/// Pure display-local placement & multi-monitor math matching `crates/rune/src/overlay/options.rs`.
public enum OverlayGeometry {
    public struct Placement: Sendable, Equatable {
        public var size: Vec2
        public var edge: ScreenEdge
        public var margin: Float
        public var align: OverlayAlign
        public var inset: Float

        public init(
            size: Vec2,
            edge: ScreenEdge = .top,
            margin: Float = 0,
            align: OverlayAlign = .center,
            inset: Float = 0
        ) {
            self.size = size
            self.edge = edge
            self.margin = margin
            self.align = align
            self.inset = inset
        }
    }

    /// Computes `[x, y, width, height]` in display-local top-left logical points.
    public static func localRect(
        at: Placement,
        placement: OverlayPlacement?,
        area: Vec2
    ) -> [Float] {
        let edge: ScreenEdge
        let margin: Float
        let align: OverlayAlign
        let inset: Float

        switch placement {
        case .fullDisplay:
            return [0, 0, area.x, area.y]
        case let .rect(rect):
            return [rect.x, rect.y, max(rect.width, 1), max(rect.height, 1)]
        case let .edge(e, m):
            edge = e
            margin = m
            align = at.align
            inset = at.inset
        case let .edgeAligned(e, m, a, i):
            edge = e
            margin = m
            align = a
            inset = i
        case nil:
            edge = at.edge
            margin = at.margin
            align = at.align
            inset = at.inset
        }

        let w = max(at.size.x, 1)
        let h = max(at.size.y, 1)
        let x: Float
        switch align {
        case .start:
            x = inset
        case .center:
            x = (area.x - w) / 2
        case .end:
            x = area.x - w - inset
        }
        let y: Float
        switch edge {
        case .top:
            y = margin
        case .bottom:
            y = area.y - h - margin
        }
        return [x, y, w, h]
    }

    /// Point-in-bounds check against `[left, top, right, bottom]` (`options::contains`).
    public static func contains(_ rect: [Float], x: Float, y: Float) -> Bool {
        guard rect.count >= 4 else { return false }
        return x >= rect[0] && y >= rect[1] && x < rect[2] && y < rect[3]
    }

    /// Point-in-XYWH check against `[x, y, width, height]`.
    public static func containsXYWH(_ rect: [Float], x: Float, y: Float) -> Bool {
        guard rect.count >= 4 else { return false }
        return x >= rect[0] && y >= rect[1] && x < rect[0] + rect[2] && y < rect[1] + rect[3]
    }

    /// Picks the target display index given native bounds `[left, top, right, bottom]`.
    public static func chooseDisplay(
        bounds: [[Double]],
        primary: Int?,
        requested: Int?,
        pointer: (Double, Double)?
    ) -> Int? {
        if let requested, bounds.indices.contains(requested) {
            return requested
        }
        if let (px, py) = pointer {
            if let hit = bounds.firstIndex(where: { r in
                r.count >= 4 && px >= r[0] && py >= r[1] && px < r[2] && py < r[3]
            }) {
                return hit
            }
        }
        if let primary, bounds.indices.contains(primary) {
            return primary
        }
        return bounds.isEmpty ? nil : 0
    }

    /// Scale of the display holding most overlap area of `frame` (`[x, y, w, h]`).
    public static func scaleUnder(
        frame: [Double],
        displays: [(frame: [Double], scale: Double)]
    ) -> Double? {
        guard frame.count >= 4 else { return nil }
        func overlapArea(_ d: [Double]) -> Double {
            guard d.count >= 4 else { return 0 }
            let w = min(frame[0] + frame[2], d[0] + d[2]) - max(frame[0], d[0])
            let h = min(frame[1] + frame[3], d[1] + d[3]) - max(frame[1], d[1])
            return max(w, 0) * max(h, 0)
        }

        var bestArea: Double = 0
        var bestScale: Double?
        for (displayFrame, scale) in displays {
            let area = overlapArea(displayFrame)
            if area > 0 && area > bestArea {
                bestArea = area
                bestScale = scale
            }
        }
        return bestScale
    }

    /// Converts top-left display-local `[x, y, w, h]` into AppKit bottom-left screen coordinates.
    public static func appKitFrame(
        localRect: [Float],
        screenOrigin: (Double, Double),
        screenSize: (Double, Double)
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        let x = Double(localRect[0])
        let y = Double(localRect[1])
        let w = Double(localRect[2])
        let h = Double(localRect[3])
        return (
            x: screenOrigin.0 + x,
            y: screenOrigin.1 + screenSize.1 - (y + h),
            width: w,
            height: h
        )
    }
}
