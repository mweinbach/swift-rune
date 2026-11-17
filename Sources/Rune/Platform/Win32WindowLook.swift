/// Win32's compositor does not send a notification when another window covers or uncovers ours.
/// Visible frames reuse a recent z-order query. Only a covered window with visible looping
/// content keeps asking when it may resume (window/look.rs).
enum Win32WindowLook: Equatable {
    case due
    case seen(at: Double)
    case covered(again: Double?, delay: Double)

    func shouldLook(at time: Double) -> Bool {
        if case let .seen(at) = self { return time >= at + 0.25 }
        return true
    }

    mutating func found(seen: Bool, moving: Bool, at time: Double) {
        guard !seen else { self = .seen(at: time); return }
        var delay = 0.25
        if case let .covered(.some, previous) = self { delay = min(1, previous * 2) }
        self = .covered(again: moving ? time + delay : nil, delay: delay)
    }

    var deadline: Double? {
        if case let .covered(again, _) = self { return again }
        return nil
    }
}

/// Window changes received while covered still reach the compositor after a quiet period.
/// The upper bound keeps a continuous producer from postponing that settled picture indefinitely.
struct Win32CoveredDraw: Equatable {
    private var first: Double?
    private(set) var deadline: Double?

    mutating func asked(at time: Double) {
        let first = first ?? time
        self.first = first
        deadline = min(first + 1, time + 0.25)
    }

    func isDue(at time: Double) -> Bool { deadline.map { time >= $0 } ?? false }

    mutating func takeDue(at time: Double) -> Bool {
        guard isDue(at: time) else { return false }
        self = .init()
        return true
    }
}
