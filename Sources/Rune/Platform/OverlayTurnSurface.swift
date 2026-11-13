import Foundation

// MARK: - Overlay Quiet / Rest Machine (`overlay/frame.rs`)

/// Tracks what a shown overlay's last frame drew while it rests, and whether only a due timer
/// asked for the next frame (`overlay/frame.rs`).
public enum OverlayQuiet<P> {
    case unknown
    case rests(presented: P, timer: Bool)

    public init() {
        self = .unknown
    }

    public var presented: P? {
        if case let .rests(presented, _) = self {
            return presented
        }
        return nil
    }

    public var hasTimerWaiting: Bool {
        if case let .rests(_, timer) = self {
            return timer
        }
        return false
    }

    @discardableResult
    public mutating func step(_ event: OverlayQuietEvent<P>) -> [OverlayQuietEffect] {
        switch (self, event) {
        case let (.rests(presented, _), .timerDue(resting: true)):
            self = .rests(presented: presented, timer: true)
            return []
        case (_, .timerDue):
            return []
        case let (.rests(presented, timer), .frameStarts):
            if timer {
                self = .rests(presented: presented, timer: false)
                return [.timerFrame]
            }
            return []
        case (.unknown, .frameStarts):
            return []
        case let (_, .presented(.some(presented))):
            self = .rests(presented: presented, timer: false)
            return []
        case (_, .presented(.none)), (_, .forget):
            self = .unknown
            return []
        }
    }

    public mutating func presentedFrame(rests: Bool, record: (inout P?) -> Void) {
        let next: P?
        if rests {
            var slot: P?
            if case let .rests(presented, _) = self {
                slot = presented
            } else {
                slot = nil
            }
            self = .unknown
            record(&slot)
            next = slot
        } else {
            self = .unknown
            next = nil
        }
        _ = step(.presented(next))
    }
}

extension OverlayQuiet: Equatable where P: Equatable {}
extension OverlayQuiet: Sendable where P: Sendable {}

public enum OverlayQuietEvent<P> {
    case timerDue(resting: Bool)
    case frameStarts
    case presented(P?)
    case forget
}

extension OverlayQuietEvent: Equatable where P: Equatable {}
extension OverlayQuietEvent: Sendable where P: Sendable {}

public enum OverlayQuietEffect: Equatable, Sendable {
    case timerFrame
}

// MARK: - Overlay Frame Turn Gate (`overlay/frame.rs`)

public enum OverlayTurn: Equatable, Sendable {
    case occluded(recheck: Bool)
    case rest
    case backedOff
    case draw

    /// Decides what a turn's frame does once the surface can draw, reading `now()` only when comparing `retry`.
    public static func decide(_ gate: OverlayTurnGate, now: () -> Double) -> OverlayTurn {
        if !gate.prewarm && gate.occluded {
            let recheck: Bool
            if let retry = gate.retry {
                recheck = retry <= now()
            } else {
                recheck = true
            }
            return .occluded(recheck: recheck)
        }
        if !gate.dirty && gate.idle {
            return .rest
        }
        if !gate.prewarm, let retry = gate.retry, retry > now() {
            return .backedOff
        }
        return .draw
    }
}

public struct OverlayTurnGate: Sendable, Equatable {
    public var prewarm: Bool
    public var occluded: Bool
    public var dirty: Bool
    public var idle: Bool
    public var retry: Double?

    public init(
        prewarm: Bool,
        occluded: Bool,
        dirty: Bool,
        idle: Bool,
        retry: Double?
    ) {
        self.prewarm = prewarm
        self.occluded = occluded
        self.dirty = dirty
        self.idle = idle
        self.retry = retry
    }
}

// MARK: - Overlay Surface Ownership State Machine (`overlay/surface.rs`)

public enum OverlaySurfaceState<L, B> {
    case none(announced: Bool)
    case parked(backing: B, announced: Bool)
    case live(live: L, announced: Bool)

    public static var initial: OverlaySurfaceState<L, B> {
        .none(announced: false)
    }

    public var live: L? {
        if case let .live(live, _) = self { return live }
        return nil
    }

    public var parked: B? {
        if case let .parked(backing, _) = self { return backing }
        return nil
    }

    public var isAnnounced: Bool {
        switch self {
        case let .none(announced),
             let .parked(_, announced),
             let .live(_, announced):
            return announced
        }
    }

    @discardableResult
    public mutating func step(_ event: OverlaySurfaceEvent<L, B>) -> [OverlaySurfaceEffect<L, B>] {
        let announced = isAnnounced
        switch event {
        case let .made(live):
            precondition(
                { if case .none = self { return true }; return false }(),
                "an overlay makes a window only while it holds none"
            )
            self = .live(live: live, announced: announced)
            return []

        case let .park(backing):
            precondition(
                { if case .none = self { return true }; return false }(),
                "an overlay parks a window only while it holds none"
            )
            self = .parked(backing: backing, announced: announced)
            return []

        case .takeLive:
            if case let .live(live, _) = self {
                self = .none(announced: announced)
                return [.live(live)]
            }
            return []

        case .takeParked:
            if case let .parked(backing, _) = self {
                self = .none(announced: announced)
                return [.parked(backing)]
            }
            return []

        case .announce:
            switch self {
            case .none:
                self = .none(announced: true)
            case let .parked(backing, _):
                self = .parked(backing: backing, announced: true)
            case let .live(live, _):
                self = .live(live: live, announced: true)
            }
            return []

        case .release:
            switch self {
            case let .live(live, _):
                self = .none(announced: false)
                return [.live(live)]
            case let .parked(backing, _):
                self = .none(announced: false)
                return [.parked(backing)]
            case .none:
                self = .none(announced: false)
                return []
            }
        }
    }

    public mutating func announce() { _ = step(.announce) }
    public mutating func made(_ live: L) { _ = step(.made(live)) }
    public mutating func park(_ backing: B) { _ = step(.park(backing)) }

    public mutating func takeLive() -> L? {
        if case let .live(live)? = step(.takeLive).first { return live }
        return nil
    }

    public mutating func takeParked() -> B? {
        if case let .parked(backing)? = step(.takeParked).first { return backing }
        return nil
    }

    public mutating func release() -> OverlaySurfaceEffect<L, B>? {
        step(.release).first
    }
}

extension OverlaySurfaceState: Equatable where L: Equatable, B: Equatable {}
extension OverlaySurfaceState: Sendable where L: Sendable, B: Sendable {}

public enum OverlaySurfaceEvent<L, B> {
    case made(L)
    case park(B)
    case takeLive
    case takeParked
    case announce
    case release
}

extension OverlaySurfaceEvent: Equatable where L: Equatable, B: Equatable {}
extension OverlaySurfaceEvent: Sendable where L: Sendable, B: Sendable {}

public enum OverlaySurfaceEffect<L, B> {
    case live(L)
    case parked(B)
}

extension OverlaySurfaceEffect: Equatable where L: Equatable, B: Equatable {}
extension OverlaySurfaceEffect: Sendable where L: Sendable, B: Sendable {}

// MARK: - Windows Overlay Linear Fade Alpha (`overlay.rs`)

public enum WindowsOverlayFade {
    public static func alpha(end: Double, length: Double, now: Double) -> UInt8 {
        if length <= 0 { return 0 }
        let left = max(0.0, end - now) / length
        return UInt8((min(max(left, 0.0), 1.0) * 255.0).rounded())
    }
}
