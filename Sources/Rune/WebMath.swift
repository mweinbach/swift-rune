import Foundation

// MARK: - Web Frame Gate, Acquire/Miss Policy, Post-Step Reblend & RTL Scroll Normalization
// Mirrors `crates/rune/src/platform/web_math.rs` and `crates/rune/src/frame/host_step.rs` (`#1253`).

public extension WebMath {
    /// Web draw state reduced to the facts `WebFrameHost::gate` needs to decide whether a frame runs.
    enum WebDrawKind: Equatable, Sendable {
        case cpu
        case handingOver(waitingForGpu: Bool)
        case gpu
        case contextLost
        case moving
    }

    /// Result of gating a frame before acquisition (`frame::host_step::Gate`).
    enum WebFrameGate: Equatable, Sendable {
        case draw
        case skip
    }

    /// Decides whether a web frame proceeds into `WebHostStep.run` or skips.
    static func webFrameGate(suspended: Bool, draw: WebDrawKind) -> WebFrameGate {
        if suspended {
            return .skip
        }
        switch draw {
        case .handingOver(waitingForGpu: true), .contextLost, .moving:
            return .skip
        case .cpu, .handingOver(waitingForGpu: false), .gpu:
            return .draw
        }
    }

    /// Outcome of one canvas surface texture acquisition without the texture payload (`web_math::WebAcquireStatus`).
    enum WebAcquireStatus: Equatable, Sendable {
        case ready
        case timeout
        case occluded
        case outdatedOrLost
        case validation
    }

    /// Classification of a missed frame (`window::Missed`).
    enum WebMissed: Error, Equatable, Sendable {
        case timeout
        case occluded
        case outdated
        case unconfigured
    }

    /// Action taken after `get_current_texture` returns `WebAcquireStatus`.
    enum WebAcquireAction: Equatable, Sendable {
        case useTexture
        case reconfigureAndRetry
        case miss(WebMissed)
    }

    /// Maps a canvas texture acquisition status and remaining reconfigure retries to an action.
    ///
    /// Transient `.timeout` and `.occluded` statuses return missed frames instead of terminating
    /// the app; `.outdatedOrLost` reconfigures once before becoming fatal `.unconfigured`.
    static func webAcquireAction(status: WebAcquireStatus, retriesLeft: UInt8) -> WebAcquireAction {
        switch status {
        case .ready:
            return .useTexture
        case .timeout:
            return .miss(.timeout)
        case .occluded:
            return .miss(.occluded)
        case .outdatedOrLost where retriesLeft > 0:
            return .reconfigureAndRetry
        case .outdatedOrLost, .validation:
            return .miss(.unconfigured)
        }
    }

    /// How the web host responds inside `onMissed`.
    enum WebMissAction: Equatable, Sendable {
        /// Canvas acquisition failed fatally: report the error and end the event loop.
        case fatal
        /// Surface is occluded: step covered work if unstepped, without requesting another rAF.
        case coveredOnly
        /// Transient miss: step covered work if unstepped and request a redraw on the next rAF.
        case retryNextFrame
    }

    /// Classifies a missed web frame for `WebFrameHost::on_missed`.
    static func webMissAction(_ missed: WebMissed) -> WebMissAction {
        switch missed {
        case .unconfigured:
            return .fatal
        case .occluded:
            return .coveredOnly
        case .timeout, .outdated:
            return .retryNextFrame
        }
    }

    /// Whether `postStepCheck` should drop the acquired drawable and reblend.
    ///
    /// Skips re-acquiring when this frame already tried reblending for `rtSRGB` (for example on a
    /// WebGL2 surface without an sRGB twin where the chosen format cannot match `rtSRGB`).
    static func shouldPostStepReblend(
        rendererSRGB: Bool,
        rtSRGB: Bool,
        reblendTried: Bool?
    ) -> Bool {
        rendererSRGB != rtSRGB && reblendTried != rtSRGB
    }

    /// How a browser represents `Element.scrollLeft` on a `direction: rtl` container.
    ///
    /// Matches `detectRtlScrollType()` in `rune-web-document-nodes.mjs` / upstream `bridge.js`:
    /// - `.negative` (CSSOM View standard: Chromium >= 85, Firefox, Safari >= 15.4): `0` at the
    ///   right (start) edge, `-max` at the left (end) edge.
    /// - `.reverse` (legacy Edge/IE): `0` at the right (start) edge, `+max` at the left (end) edge.
    /// - `.default` (legacy Blink/WebKit): `+max` at the right (start) edge, `0` at the left (end) edge.
    enum RtlScrollModel: Equatable, Sendable, CaseIterable {
        case negative
        case reverse
        case `default`
    }

    /// Converts a DOM `Element.scrollLeft` reading into Rune's logical horizontal scroll offset
    /// (`0...maxScroll`, measuring distance from the inline-start edge).
    static func scrollXFromDOM(
        scrollLeft: Float,
        maxScroll: Float,
        rtl: Bool,
        model: RtlScrollModel
    ) -> Float {
        guard scrollLeft.isFinite, maxScroll.isFinite else { return 0.0 }
        let maxVal = max(maxScroll, 0.0)
        let logical: Float
        if !rtl {
            logical = scrollLeft
        } else {
            switch model {
            case .negative:
                logical = -scrollLeft
            case .reverse:
                logical = scrollLeft
            case .default:
                logical = maxVal - scrollLeft
            }
        }
        return min(max(logical, 0.0), maxVal)
    }

    /// Converts Rune's logical horizontal scroll offset (`0...maxScroll`) into the DOM
    /// `Element.scrollLeft` value expected by the browser's RTL scroll model.
    static func scrollXToDOM(
        offset: Float,
        maxScroll: Float,
        rtl: Bool,
        model: RtlScrollModel
    ) -> Float {
        guard offset.isFinite, maxScroll.isFinite else { return 0.0 }
        let maxVal = max(maxScroll, 0.0)
        let clamped = min(max(offset, 0.0), maxVal)
        if !rtl {
            return clamped
        }
        switch model {
        case .negative:
            return clamped == 0.0 ? 0.0 : -clamped
        case .reverse:
            return clamped
        case .default:
            return maxVal - clamped
        }
    }
}

// MARK: - Shared Host Frame Sequencer (`frame/host_step.rs`, `#1253`)

/// Shared frame sequencer driving web frames through the canonical phase order:
/// `gate -> [pre-reblend] -> acquire -> step -> [post-reblend + reacquire] -> sync -> prepare -> render -> present -> settle`.
public enum WebHostStep {
    public enum Outcome: Equatable, Sendable {
        case skipped
        case missed
        case aborted
        case presented
    }

    public enum Acquire<Drawable> {
        case ready(Drawable)
        case missed(WebMath.WebMissed)
    }

    public enum ReacquireReason: Equatable, Sendable {
        case reblend
        case nativeMaterials
    }

    public enum PostStepCheck: Equatable, Sendable {
        case keep
        case reacquire(ReacquireReason)
    }

    public enum RenderPrep<Prepared> {
        case ready(Prepared)
        case abort
    }

    public struct StepInfo: Equatable, Sendable {
        public var runtimeAnimating: Bool
        public var animating: Bool
        public var dt: Double
        public var updateMs: Double
        public var presentsAt: Double?

        public init(
            runtimeAnimating: Bool,
            animating: Bool,
            dt: Double,
            updateMs: Double = 0,
            presentsAt: Double? = nil
        ) {
            self.runtimeAnimating = runtimeAnimating
            self.animating = animating
            self.dt = dt
            self.updateMs = updateMs
            self.presentsAt = presentsAt
        }
    }

    public protocol Host {
        associatedtype Drawable
        associatedtype Prepared

        mutating func gate() -> WebMath.WebFrameGate
        func needsReblend() -> Bool
        mutating func reblend() -> Bool
        mutating func acquire() -> Acquire<Drawable>
        mutating func stepRuntime() -> StepInfo
        mutating func postStepCheck(_ info: inout StepInfo) -> PostStepCheck
        mutating func prepareReacquire(_ reason: ReacquireReason, _ info: inout StepInfo) -> Bool
        mutating func onMissed(_ missed: WebMath.WebMissed, stepped: Bool)
        mutating func syncAfterStep(_ info: inout StepInfo)
        mutating func prepareRender(_ drawable: Drawable, _ info: inout StepInfo) -> RenderPrep<Prepared>
        mutating func render(_ prepared: inout Prepared, _ info: StepInfo) -> Bool
        mutating func submitAndPresent(_ prepared: Prepared, _ info: StepInfo) -> Double
        mutating func recordPresentation(submitted: Double, info: StepInfo)
        mutating func settle(submitted: Double, info: StepInfo)
    }

    @discardableResult
    public static func run<H: Host>(_ host: inout H) -> Outcome {
        guard host.gate() == .draw else {
            return .skipped
        }
        if host.needsReblend() {
            guard host.reblend() else {
                host.onMissed(.unconfigured, stepped: false)
                return .missed
            }
        }
        var drawable: H.Drawable
        switch host.acquire() {
        case let .ready(d):
            drawable = d
        case let .missed(m):
            host.onMissed(m, stepped: false)
            return .missed
        }
        var info = host.stepRuntime()
        switch host.postStepCheck(&info) {
        case .keep:
            break
        case let .reacquire(reason):
            // Drop old drawable before reconfiguring/reacquiring.
            guard host.prepareReacquire(reason, &info) else {
                host.onMissed(.unconfigured, stepped: true)
                return .missed
            }
            switch host.acquire() {
            case let .ready(d):
                drawable = d
            case let .missed(m):
                host.onMissed(m, stepped: true)
                return .missed
            }
        }
        host.syncAfterStep(&info)
        var prepared: H.Prepared
        switch host.prepareRender(drawable, &info) {
        case let .ready(p):
            prepared = p
        case .abort:
            return .aborted
        }
        let compAnimating = host.render(&prepared, info)
        if compAnimating {
            info.animating = true
        }
        let submitted = host.submitAndPresent(prepared, info)
        host.recordPresentation(submitted: submitted, info: info)
        host.settle(submitted: submitted, info: info)
        return .presented
    }
}
