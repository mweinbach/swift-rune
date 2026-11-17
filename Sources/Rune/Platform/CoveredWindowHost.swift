import Foundation

// Upstream 2e23d0fa (#995), host side: `window/sight.rs::Host::set_cover` and the host paths that
// run `covered_step` for a shown window that can't draw (`window/any_host.rs`, `window/draw.rs`).
// `covered_step` now runs `Runtime::covered_wake`: a covered window an assistive client reads
// builds what changed at once, so its tree and asked focus don't wait for it to draw.
//
// The AppKit hosts (`RuneMetalHostView` in `MacOSApp.swift`, `RuneHostedMetalView` in
// `WindowHostingMacOS.swift`) feed this driver the occlusion and miniaturize notifications and
// route every wake, due timer and redraw through `step` while the window can't draw. It holds no
// AppKit state, so headless tests drive it exactly as the hosts do.

/// What a host's covered-window driver needs of a runtime (`Runtime` conforms).
public protocol CoveredWindowRuntime: AnyObject {
    /// `Runtime::set_live_visible`.
    func setLiveVisible(_ visible: Bool, at now: Double?)
    /// `Runtime::settle_all`.
    func settleAll()
    /// `Runtime::cancel_timer_frame`.
    func cancelTimerFrame()
    /// `Runtime::stale`.
    var isStale: Bool { get }
    /// `Runtime.a11y.is_some()`: an assistive client reads the window's tree.
    var assistiveTechnology: Bool { get set }
    /// Commits so far; a covered step that commits has a new tree for the reader.
    var commitCount: UInt64 { get }
    /// `Runtime::covered_wake`.
    @discardableResult
    func coveredWake(at now: Double?) -> Bool
}

extension Runtime: CoveredWindowRuntime {}

/// A shown window's sight as its host tracks it, and what each change asks of the host
/// (`window/sight.rs`, `Host::set_cover`). On macOS minimising is occlusion too: AppKit's
/// occlusion state drops `.visible` for a miniaturized window, and `Win::minimized()` is always
/// false there (`isMiniaturized` stays true into a deminiaturize whose first redraws would
/// otherwise draw nothing).
public struct CoveredWindowDriver: Equatable, Sendable {
    /// What a cover change asks of the host.
    public enum Outcome: Equatable, Sendable {
        /// Covered: stop pacing and rest (`stop_pacing`, `rest_step(RestEvent::Unseen)`).
        case rest
        /// Uncovered with something to draw: request a redraw (`request_redraw`).
        case redraw
        /// Uncovered and current: nothing to do.
        case none
    }

    /// The window's life; a host's window is shown while it drives it.
    public private(set) var life: WindowLife = .shown(sight: .seen)

    public init() {}

    /// The window can draw: shown and uncovered. Otherwise every wake, due timer and redraw runs
    /// `step` (`covered_step`) instead of a frame.
    public var canDraw: Bool { life.isUncovered }

    /// `cover` starts (`on`) or stops covering the window (`Host::set_cover`). Covered, the
    /// runtime is no longer live and its timer frame is cancelled; uncovered after being covered,
    /// its first frame paints the settled state of what changed meanwhile (guarantee 8).
    public mutating func setCover(_ cover: WindowCover, on: Bool, runtime: any CoveredWindowRuntime, at now: Double? = nil) -> Outcome {
        let was = life.cover(cover, on: on)
        runtime.setLiveVisible(life.isUncovered, at: now)
        if life.isCovered {
            runtime.cancelTimerFrame()
            return .rest
        }
        if was {
            runtime.settleAll()
            return .redraw
        }
        return runtime.isStale ? .redraw : .none
    }

    /// The system's occlusion report (`WindowEvent::Occluded`, minimising included): `Cover::System`.
    public mutating func setOccluded(_ occluded: Bool, runtime: any CoveredWindowRuntime, at now: Double? = nil) -> Outcome {
        setCover(.system, on: occluded, runtime: runtime, at: now)
    }

    /// What a shown window that can't draw runs for an update, a wake, a due timer or a redraw
    /// (`window::covered_step` -> `Runtime::covered_wake`). Returns whether it committed a new
    /// tree, which the host hands to the assistive client reading it.
    @discardableResult
    public func step(_ runtime: any CoveredWindowRuntime, at now: Double? = nil) -> Bool {
        let before = runtime.commitCount
        runtime.coveredWake(at: now)
        return runtime.commitCount != before
    }

    /// An assistive client asked for the window's tree (AccessKit's `Asked::Activate`,
    /// `Runtime::a11y_activate`): from now on a covered window builds what changed for it.
    public func assistiveClientAttached(_ runtime: any CoveredWindowRuntime) {
        if !runtime.assistiveTechnology { runtime.assistiveTechnology = true }
    }
}
