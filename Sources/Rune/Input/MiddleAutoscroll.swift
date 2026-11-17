import Foundation
import RuneMotion

/// Middle-button autoscroll as on Chromium's Windows and Linux hosts.
internal struct MiddleAutoscroll {
    struct Active {
        let horizontal: String?
        let vertical: String?
        let origin: Vec2
        var at: Vec2
        var last: Double
        var held = true
        var away = false
        var armed = false

        var velocity: Vec2 {
            func speed(_ distance: Float) -> Float {
                guard abs(distance) > 15 else { return 0 }
                let magnitude = 0.04 * powf(abs(distance), 2.2)
                return distance < 0 ? -magnitude : magnitude
            }
            return Vec2(horizontal == nil ? 0 : speed(at.x - origin.x),
                        vertical == nil ? 0 : speed(at.y - origin.y))
        }
    }

    private(set) var active: Active?
    private var swallowed: PointerButton?
    var wantsFrame: Bool { active?.armed == true }

    mutating func start(horizontal: String?, vertical: String?, origin: Vec2, now: Double) {
        guard active == nil, swallowed == nil, horizontal != nil || vertical != nil else { return }
        active = Active(horizontal: horizontal, vertical: vertical, origin: origin, at: origin, last: now)
    }

    @discardableResult
    mutating func move(to point: Vec2, at now: Double) -> Bool {
        guard var current = active else { return false }
        current.at = point
        let moving = current.velocity != .zero
        let arm = moving && !current.armed
        if arm { current.last = now }
        current.armed = moving
        current.away = current.away || moving
        active = current
        return arm
    }

    mutating func step(at now: Double) -> (Active, Vec2)? {
        guard var current = active, current.armed else { return nil }
        let dt = Float(min(0.05, max(0, now - current.last)))
        current.last = now
        active = current
        let velocity = current.velocity
        return (current, Vec2(velocity.x * dt, velocity.y * dt))
    }

    mutating func stuck() { active?.armed = false }

    mutating func press(_ button: PointerButton) -> Bool {
        guard active != nil else { return false }
        active = nil
        swallowed = button
        return true
    }

    func willTakeRelease(_ button: PointerButton) -> Bool {
        swallowed == button || (button == .middle && active?.held == true)
    }

    mutating func release(_ button: PointerButton) -> Bool {
        guard willTakeRelease(button) else { return false }
        if swallowed == button { swallowed = nil }
        else if active?.away == true { active = nil }
        else { active?.held = false }
        return true
    }

    mutating func key() -> Bool {
        guard active != nil else { return false }
        cancel()
        return true
    }

    mutating func cancel() { active = nil; swallowed = nil }

    private static let panCursors: [String: Cursor] = {
        let names = ["middle", "middle_horizontal", "middle_vertical", "north", "north_east",
                     "north_west", "south", "south_east", "south_west", "east", "west"]
        var cursors: [String: Cursor] = [:]
        for name in names {
            if let url = Bundle.module.url(forResource: "pan_" + name, withExtension: "png", subdirectory: "Cursors"),
               let bytes = try? Data(contentsOf: url) {
                cursors[name] = .image(CursorImage(png: bytes, hot: SIMD2(16, 16), crisp: true))
            }
        }
        return cursors
    }()

    var cursor: Cursor? {
        guard let current = active else { return nil }
        let v = current.velocity
        let ns = v.y < 0 ? "north" : (v.y > 0 ? "south" : "")
        let ew = v.x < 0 ? "west" : (v.x > 0 ? "east" : "")
        let name: String
        if !ns.isEmpty { name = ew.isEmpty ? ns : ns + "_" + ew }
        else if !ew.isEmpty { name = ew }
        else if current.horizontal == nil { name = "middle_vertical" }
        else if current.vertical == nil { name = "middle_horizontal" }
        else { name = "middle" }
        return Self.panCursors[name]
    }
}

extension Runtime {
    internal func startMiddleAutoscroll(at point: Vec2, now: Double) {
        let x = scrollAtAxis(point.x, point.y, horizontal: true)
        let y = scrollAtAxis(point.x, point.y, horizontal: false)
        slice2State.autoscroll.start(horizontal: x, vertical: y, origin: point, now: now)
    }

    internal func fireMiddleAutoscroll(at now: Double) {
        guard let (views, delta) = slice2State.autoscroll.step(at: now) else { return }
        let hasX = views.horizontal.map { scrollMaxExtents[$0] != nil } ?? false
        let hasY = views.vertical.map { scrollMaxExtents[$0] != nil } ?? false
        guard hasX || hasY else { slice2State.autoscroll.cancel(); return }
        defer { wakeAt(now) }
        guard delta != .zero else { return }
        var moved = false
        if let path = views.horizontal, let limit = scrollMaxExtents[path]?.x {
            let before = scrollOffsets[path] ?? .zero
            let rtl = nodeByPath[path].map { flatNodes[$0].flow == .rtl } ?? false
            let x = min(limit, max(0, before.x + (rtl ? -delta.x : delta.x)))
            slice2State.scrollHorizontalVelocities.removeValue(forKey: path)
            if x != before.x {
                applyManualScroll(path: path, to: Vec2(x, before.y), at: now)
                moved = true
            }
        }
        if let path = views.vertical, let limit = scrollMaxExtents[path]?.y, let idx = nodeByPath[path] {
            let before = scrollOffsets[path] ?? .zero
            let y = min(limit, max(0, before.y + delta.y))
            if before.y != y {
                applyManualScroll(path: path, to: Vec2(before.x, y), at: now)
                moved = true
            }
            let pinned = flatNodes[idx].el.layout.stickBottom && delta.y >= 0 && y >= limit - 0.5
            updateScrollMode(forPath: path, event: pinned ? .pin : .rest)
            if pinned { wasPinnedToBottom.insert(path) } else { wasPinnedToBottom.remove(path) }
        }
        if !moved { slice2State.autoscroll.stuck() }
    }
}
