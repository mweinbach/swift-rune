import Foundation
import RuneMotion

// MARK: - Platform Capabilities & Runtime ID Scope

/// Whether the window host presents pop-up menus requested through `Tx.popupMenu`.
public func popupMenuSupported() -> Bool {
    #if os(macOS) || os(Windows) || os(Linux)
    return true
    #else
    return false
    #endif
}

internal enum RuntimeIdScope {
    @TaskLocal static var current: UInt64? = nil
    private static let lock = NSLock()
    private nonisolated(unsafe) static var counter: UInt64 = 1

    static func nextId() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let id = counter
        counter &+= 1
        return id
    }
}

/// Returns the identifier of the active `Runtime` on the current evaluation/event turn, if any
/// (`platform/scroll_bars.rs:106`).
public func currentRuntimeId() -> UInt64? {
    RuntimeIdScope.current
}

// MARK: - Window Frame Requests, Geometry, & Stepping (`window/frame.rs`, `window/stepping.rs`)

/// A requested change to the host window's frame, merged across a commit (`window/frame.rs`).
public struct WindowFrameRequest: Sendable, Equatable {
    public var size: (Float, Float)?
    public var animate: Bool
    public var spring: Spring?
    public var center: Bool

    public init(
        size: (Float, Float)? = nil,
        animate: Bool = false,
        spring: Spring? = nil,
        center: Bool = false
    ) {
        self.size = size
        self.animate = animate
        self.spring = spring
        self.center = center
    }

    public static func == (lhs: WindowFrameRequest, rhs: WindowFrameRequest) -> Bool {
        lhs.size?.0 == rhs.size?.0 &&
        lhs.size?.1 == rhs.size?.1 &&
        lhs.animate == rhs.animate &&
        lhs.spring == rhs.spring &&
        lhs.center == rhs.center
    }

    /// A later request's size replaces an earlier one's; centering sticks.
    public func merged(with later: WindowFrameRequest) -> WindowFrameRequest {
        if let laterSize = later.size {
            return WindowFrameRequest(
                size: laterSize,
                animate: later.animate,
                spring: later.spring,
                center: center || later.center
            )
        }
        return WindowFrameRequest(
            size: size,
            animate: animate,
            spring: spring,
            center: center || later.center
        )
    }
}

/// Pure `[x, y, w, h]` rectangle alias matching `window/frame.rs`.
public typealias WindowFrameRect = (Float, Float, Float, Float)

extension Runtime {
    /// A WindowHandle frame event joins any transaction waiting for the next host frame.
    func queueWindowHandleFrame(_ request: WindowFrameRequest) {
        var resolved = request
        resolved.spring = request.animate && !reducedMotion ? MotionTokens.DEFAULT : nil
        pendingWindowFrame = pendingWindowFrame?.merged(with: resolved) ?? resolved
    }
}

/// A window frame moving to `to` on a spring, sampled on the host's clock (`window/frame.rs:51`).
public struct WindowFrameAnim: Sendable, Equatable {
    public var spring: Spring?
    public var start: Double
    public var from: [Float]
    public var velocity: [Float]
    public var to: [Float]
    public var end: Double

    /// Half a device pixel at 2x (`window/frame.rs:61`).
    public static let settleEpsilon: Float = 0.25

    public init(
        spring: Spring?,
        now: Double,
        from: [Float],
        velocity: [Float],
        to: [Float]
    ) {
        let f = from.count >= 4 ? Array(from.prefix(4)) : [0, 0, 0, 0]
        let v = velocity.count >= 4 ? Array(velocity.prefix(4)) : [0, 0, 0, 0]
        let t = to.count >= 4 ? Array(to.prefix(4)) : [0, 0, 0, 0]
        self.spring = spring
        self.start = now
        self.from = f
        self.velocity = v
        self.to = t
        if let spring {
            var maxSettle: Float = 0
            for i in 0..<4 {
                let d = spring.settlingDuration(from: f[i], velocity: v[i], target: t[i], epsilon: Self.settleEpsilon)
                if d > maxSettle { maxSettle = d }
            }
            self.end = now + Double(maxSettle)
        } else {
            self.end = now
        }
    }

    /// Starts from where an earlier animation is now, keeping position and velocity (`window/frame.rs:70`).
    public static func retarget(
        previous: WindowFrameAnim?,
        spring: Spring?,
        now: Double,
        from: [Float],
        to: [Float]
    ) -> WindowFrameAnim {
        let sampled = previous?.sample(at: now)
        let nextFrom = sampled?.position ?? from
        let nextVel = spring != nil ? (sampled?.velocity ?? [0, 0, 0, 0]) : [0, 0, 0, 0]
        return WindowFrameAnim(spring: spring, now: now, from: nextFrom, velocity: nextVel, to: to)
    }

    public func sample(at now: Double) -> (position: [Float], velocity: [Float]) {
        guard let spring, now < end else {
            return (to, [0, 0, 0, 0])
        }
        let t = Float(max(0.0, now - start))
        var at: [Float] = [0, 0, 0, 0]
        var vel: [Float] = [0, 0, 0, 0]
        for i in 0..<4 {
            let s = spring.sample(from: from[i], velocity: velocity[i], target: to[i], at: t)
            at[i] = s.position
            vel[i] = s.velocity
        }
        return (at, vel)
    }

    public func isDone(at now: Double) -> Bool {
        spring == nil || now >= end
    }

    /// Shifts origin by `(dx, dy)` when the user drags the window mid-flight (`window/frame.rs:91`).
    public mutating func shift(dx: Float, dy: Float) {
        from[0] += dx
        from[1] += dy
        to[0] += dx
        to[1] += dy
    }
}

/// Pure window frame placement, clamping, pixel snapping, and rescale helpers (`window/frame.rs`).
public enum WindowFrame {
    /// Computes the destination top-down outer frame `[x, y, w, h]` (`window/frame.rs:32`).
    public static func target(
        current: [Float],
        outer: (Float, Float)?,
        center: Bool,
        visible: [Float]
    ) -> [Float] {
        let w = outer?.0 ?? current[2]
        let h = outer?.1 ?? current[3]
        let vx = visible[0], vy = visible[1], vw = visible[2], vh = visible[3]
        var x = current[0]
        var y = current[1]
        if center {
            x = vx + ((vw - w) / 2.0).rounded(.down)
            y = vy + ((vh - h) / 4.0).rounded(.down)
        }
        let left = center ? vx : min(current[0], vx)
        let top = center ? vy : min(current[1], vy)
        let right = center ? (vx + vw) : max(current[0] + current[2], vx + vw)
        let bottom = center ? (vy + vh) : max(current[1] + current[3], vy + vh)
        x = max(left, min(right - w, x))
        y = max(top, min(bottom - h, y))
        return [x, y, w, h]
    }

    /// Clamps a requested content size to `[min, max]` (`window/frame.rs:100`).
    public static func clampSize(
        _ size: (Float, Float),
        min minSize: (Float, Float),
        max maxSize: (Float, Float)?
    ) -> (Float, Float) {
        let maxW = maxSize?.0 ?? Float.infinity
        let maxH = maxSize?.1 ?? Float.infinity
        return (
            Swift.min(Swift.max(size.0, minSize.0), maxW),
            Swift.min(Swift.max(size.1, minSize.1), maxH)
        )
    }

    /// Rounds a frame rectangle to whole device pixels (`window/frame.rs:106`).
    public static func snap(_ rect: [Float], scale: Float) -> [Float] {
        guard scale > 0 else { return rect }
        return rect.map { ($0 * scale).rounded() / scale }
    }

    /// Preserves logical point size across a scale change (`window/frame.rs:114`).
    public static func rescaled(_ size: (UInt32, UInt32), from: Double, to: Double) -> (UInt32, UInt32) {
        func rescale(_ v: UInt32) -> UInt32 {
            UInt32(max(0.0, (Double(v) / from * to).rounded()))
        }
        return (rescale(size.0), rescale(size.1))
    }
}

/// Exclusive window frame transition state (`window/stepping.rs:10`).
public enum WindowFrameMove: Sendable, Equatable {
    case moving(anim: WindowFrameAnim, originX: Float, originY: Float)
    case jumped(width: Float, height: Float)

    public static func moving(_ anim: WindowFrameAnim, origin: (Float, Float)) -> WindowFrameMove {
        .moving(anim: anim, originX: origin.0, originY: origin.1)
    }

    public static func jumped(_ size: (Float, Float)) -> WindowFrameMove {
        .jumped(width: size.0, height: size.1)
    }

    public static func isMoving(_ slot: WindowFrameMove?) -> Bool {
        if case .moving = slot { return true }
        return false
    }

    /// Consumes a jumped-size coupon against `viewport`, returning `true` when it matches within 1 pt (`window/stepping.rs:41`).
    public static func takeJump(_ slot: inout WindowFrameMove?, viewport: (Float, Float)) -> Bool {
        guard case .jumped(let w, let h) = slot else { return false }
        slot = nil
        return abs(w - viewport.0) < 1.0 && abs(h - viewport.1) < 1.0
    }

    /// Consumes the running frame animation, leaving any jump coupon untouched (`window/stepping.rs:49`).
    public static func takeMoving(_ slot: inout WindowFrameMove?) -> WindowFrameAnim? {
        guard case .moving(let anim, _, _) = slot else { return nil }
        slot = nil
        return anim
    }
}

// MARK: - Fit-Content Window State (`runtime/window_requests.rs:68`)

internal enum FitHoldPhase: Sendable, Equatable {
    case none
    case asked
    case held
}

internal struct FitWindowState: Sendable, Equatable {
    var asked: Float? = nil
    var hold: FitHoldPhase = .none

    mutating func ask(height: Float, current: Float) -> Bool {
        if (asked ?? current) == height { return false }
        asked = height
        return true
    }

    mutating func resized(to height: Float, current: Float) -> Bool {
        if abs((asked ?? current) - height) <= 0.5 { return false }
        asked = nil
        return true
    }

    mutating func frameHolds() -> Bool {
        hold = (hold == .asked) ? .held : .none
        return hold == .held
    }

    mutating func takeHeld() -> Bool {
        let wasHeld = (hold == .held)
        hold = .none
        return wasHeld
    }
}

// MARK: - Tx Window Frame Extensions (`el/tx.rs:458-473`)

extension Tx {
    /// Resizes this window's content to `(width, height)` points, animating on the change's spring (`Tx::resize_window`).
    public mutating func resizeWindow(_ size: (Float, Float)) {
        mergeWindowFrame(WindowFrameRequest(size: size, animate: true))
    }

    /// `Vec2` convenience overload for `resizeWindow(_:)`.
    public mutating func resizeWindow(_ size: Vec2) {
        resizeWindow((size.x, size.y))
    }

    /// Resizes this window's content immediately without animation (`Tx::resize_window_instant`).
    public mutating func resizeWindowInstant(_ size: (Float, Float)) {
        mergeWindowFrame(WindowFrameRequest(size: size, animate: false))
    }

    /// `Vec2` convenience overload for `resizeWindowInstant(_:)`.
    public mutating func resizeWindowInstant(_ size: Vec2) {
        resizeWindowInstant((size.x, size.y))
    }

    /// Centers the window on its current screen (`Tx::center_window`).
    public mutating func centerWindow() {
        mergeWindowFrame(WindowFrameRequest(center: true))
    }

    private mutating func mergeWindowFrame(_ request: WindowFrameRequest) {
        if let existing = runtimeActions["windowFrameRequest"] as? WindowFrameRequest {
            runtimeActions["windowFrameRequest"] = existing.merged(with: request)
        } else {
            runtimeActions["windowFrameRequest"] = request
        }
    }
}

// MARK: - AppHandle Native Menu Bridge (`native_menu/mod.rs:160-180`)

/// Each app owns its menu model and errors, including after its last window closes.
internal final class AppMenuState<State>: @unchecked Sendable {
    fileprivate let lock = NSLock()
    fileprivate var items: [NativeMenuItem<State>] = []
    fileprivate var revision: UInt64 = 0
    fileprivate var isRunning = false
    fileprivate var isHeadless = false
    fileprivate var nativeSupported = AppMenuBridge.defaultNativeSupported
    fileprivate var errors: [MenuError] = []

    fileprivate func replaceItems(_ items: [NativeMenuItem<State>]) {
        self.items = items
        revision &+= 1
        #if os(Linux) || os(Windows)
        if isRunning && nativeSupported && !isHeadless && items.contains(where: { $0.location == .dock }) {
            errors.append(.backend("The Dock menu location is only available on macOS"))
        }
        #endif
    }

    fileprivate func action(id: String, revision: UInt64) -> ((inout State, inout Tx) -> Void)? {
        guard isRunning, nativeSupported || isHeadless, self.revision == revision else { return nil }
        return items.first(where: { !$0.isSeparator && $0.id == id && $0.enabled })?.action
    }
}

/// Connects the app's menu model to a native window or headless runtime.
public final class AppMenuBridge: @unchecked Sendable {
    private init() {}

    public static var defaultNativeSupported: Bool {
        #if os(macOS) || os(Windows) || os(Linux)
        return true
        #else
        return false
        #endif
    }

    public static func markRunning<State>(
        _ appShared: AppShared<State>,
        running: Bool,
        headless: Bool = false,
        nativeSupported: Bool = defaultNativeSupported
    ) {
        let menu = appShared.menuState
        menu.lock.withLock {
            if menu.isRunning && !running {
                menu.items.removeAll()
                menu.revision &+= 1
            }
            menu.isRunning = running
            menu.isHeadless = running && headless
            menu.nativeSupported = running ? nativeSupported : defaultNativeSupported
        }
    }

    /// Attaches startup menu items for a run, keeping validation errors available on the handle.
    public static func attach<State>(
        _ items: [NativeMenuItem<State>],
        to appShared: AppShared<State>,
        headless: Bool = false,
        nativeSupported: Bool = defaultNativeSupported
    ) {
        let menu = appShared.menuState
        menu.lock.withLock {
            menu.isRunning = true
            menu.isHeadless = headless
            menu.nativeSupported = nativeSupported
            if !nativeSupported && !headless && !items.isEmpty {
                menu.replaceItems(items)
                menu.errors.append(.unsupported)
                return
            }
            do {
                try NativeMenuValidator.validate(items)
                menu.replaceItems(items)
            } catch let error as MenuError {
                menu.replaceItems([])
                menu.errors.append(error)
            } catch {
                menu.replaceItems([])
                menu.errors.append(.backend(String(describing: error)))
            }
        }
        appShared.wake()
    }

    public static func recordError<State>(_ error: MenuError, for appShared: AppShared<State>) {
        let menu = appShared.menuState
        menu.lock.withLock { menu.errors.append(error) }
    }

    public static func setMenu<State>(_ items: [NativeMenuItem<State>], for appShared: AppShared<State>) throws {
        let menu = appShared.menuState
        try menu.lock.withLock {
            guard menu.nativeSupported || menu.isHeadless else { throw MenuError.unsupported }
            guard menu.isRunning else { throw MenuError.notRunning }
            try NativeMenuValidator.validate(items)
            menu.replaceItems(items)
        }
        appShared.wake()
    }

    public static func snapshot<State>(for appShared: AppShared<State>) -> (items: [NativeMenuItem<State>], revision: UInt64) {
        let menu = appShared.menuState
        return menu.lock.withLock { (menu.items, menu.revision) }
    }

    internal static func desktopSnapshot<State>(
        for appShared: AppShared<State>, applicationTitle: String, after revision: UInt64?
    ) -> DesktopMenuSnapshot? {
        let snapshot = snapshot(for: appShared)
        guard snapshot.revision != revision else { return nil }
        return DesktopMenuSnapshot(revision: snapshot.revision, items: snapshot.items, applicationTitle: applicationTitle)
    }

    /// A platform menu supplies the revision it actually displayed so stale native events are harmless.
    @discardableResult
    internal static func fireIfCurrent<State>(id: String, revision: UInt64, for appShared: AppShared<State>) -> Bool {
        let menu = appShared.menuState
        guard menu.lock.withLock({ menu.action(id: id, revision: revision) != nil }) else { return false }
        enqueue(id: id, revision: revision, for: appShared)
        return true
    }

    /// Fires an item by id or unique title on the next frame, if its revision is still installed.
    public static func fire<State>(_ selector: String, for appShared: AppShared<State>) throws {
        let menu = appShared.menuState
        let (id, revision) = try menu.lock.withLock {
            guard menu.nativeSupported || menu.isHeadless else { throw MenuError.unsupported }
            guard menu.isRunning else { throw MenuError.notRunning }
            let index = try NativeMenuValidator.lookupIndex(selector: selector, in: menu.items)
            return (menu.items[index].id, menu.revision)
        }
        enqueue(id: id, revision: revision, for: appShared)
    }

    private static func enqueue<State>(id: String, revision: UInt64, for appShared: AppShared<State>) {
        appShared.enqueueUpdateIf { [weak appShared] state, tx in
            guard let menu = appShared?.menuState else { return false }
            let action = menu.lock.withLock { menu.action(id: id, revision: revision) }
            guard let action else { return false }
            action(&state, &tx)
            return true
        }
    }

    public static func takeMenuErrors<State>(for appShared: AppShared<State>) -> [MenuError] {
        let menu = appShared.menuState
        return menu.lock.withLock {
            let errors = menu.errors
            menu.errors.removeAll()
            return errors
        }
    }
}

extension AppHandle {
    /// Replaces all custom native menu items on a running `App`, preserving native defaults (`AppHandle::set_menu`).
    public func setMenu(_ items: [NativeMenuItem<State>]) throws {
        try AppMenuBridge.setMenu(items, for: shared)
    }

    /// Fires a custom native menu item by id or unique title on the next frame (`native_menu::fire`).
    public func fireMenu(_ selector: String) throws {
        try AppMenuBridge.fire(selector, for: shared)
    }

    /// Returns and clears deferred native menu installation errors (`AppHandle::take_menu_errors`).
    public func takeMenuErrors() -> [MenuError] {
        AppMenuBridge.takeMenuErrors(for: shared)
    }
}
