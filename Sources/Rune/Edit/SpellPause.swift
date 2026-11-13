import Foundation

/// Delay before flagging the word currently under the caret as misspelled while typing (`rune::spell::pause`).
public enum SpellPause {
    /// Seconds to wait after typing before showing a red squiggle on the word under the caret.
    public static let pauseDuration: Double = 1.0

    public enum State: Sendable, Equatable {
        case settled
        case typing(caret: Int, until: Double)
    }

    public enum Event: Sendable, Equatable {
        case typed(caret: Int, now: Double)
        case caretMoved(caret: Int, now: Double)
        case tick(now: Double)
    }

    public enum Effect: Sendable, Equatable {
        case schedule(at: Double)
        case clearTimer
        case repaint
    }

    /// Advances the typing pause state machine.
    public static func step(_ state: State, event: Event) -> (State, Effect?) {
        switch (state, event) {
        case let (_, .typed(caret, now)):
            let until = now + pauseDuration
            return (.typing(caret: caret, until: until), .schedule(at: until))

        case (.settled, .caretMoved):
            return (.settled, nil)

        case let (.typing(prevCaret, _), .caretMoved(caret, _)):
            if prevCaret == caret {
                return (state, nil)
            }
            return (.settled, .repaint)

        case (.settled, .tick):
            return (.settled, .clearTimer)

        case let (.typing(_, until), .tick(now)):
            if now >= until {
                return (.settled, .repaint)
            }
            return (state, .schedule(at: until))
        }
    }

    /// Returns the paused caret byte offset if typing suppression is active.
    public static func waitingCaret(in state: State) -> Int? {
        if case let .typing(caret, _) = state { return caret }
        return nil
    }

    /// Returns the word byte range around `caret` in `text`, or `nil` when not inside a word.
    public static func wordRange(at caret: Int, in text: String) -> Range<Int>? {
        guard !text.isEmpty else { return nil }
        let len = text.utf8.count
        let clamped = min(max(0, caret), len)

        func isWordScalar(_ scalar: UnicodeScalar) -> Bool {
            CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "\u{2019}"
        }

        // Collect UTF-8 scalar spans.
        var spans: [(range: Range<Int>, isWord: Bool)] = []
        var offset = 0
        for scalar in text.unicodeScalars {
            let next = offset + scalar.utf8.count
            let word = isWordScalar(scalar)
            if let last = spans.last, last.isWord == word {
                spans[spans.count - 1].range = last.range.lowerBound..<next
            } else {
                spans.append((offset..<next, word))
            }
            offset = next
        }

        // Caret inside or immediately at the end of a word matches that word.
        for span in spans where span.isWord {
            if clamped >= span.range.lowerBound && clamped <= span.range.upperBound {
                return span.range
            }
        }
        return nil
    }
}

/// Per-field spellcheck pause & cached range watcher (`rune::spell::pause::Watch`).
public struct SpellPauseWatch: Sendable, Equatable {
    public var path: String
    public var lastText: String
    public var state: SpellPause.State = .settled
    public var wakeAt: Double? = nil

    public init(path: String, text: String = "") {
        self.path = path
        self.lastText = text
    }

    /// Observes the focused field's current text & caret at timestamp `now`, returning the paused caret offset if suppressed.
    public mutating func observe(path: String, text: String, caret: Int, now: Double) -> Int? {
        let textChanged = (self.path != path || self.lastText != text)
        self.path = path
        self.lastText = text

        let event: SpellPause.Event = textChanged
            ? .typed(caret: caret, now: now)
            : .caretMoved(caret: caret, now: now)
        let (next, effect) = SpellPause.step(state, event: event)
        state = next
        if case let .schedule(t) = effect {
            wakeAt = t
        } else if case .clearTimer = effect {
            wakeAt = nil
        } else if case .settled = next {
            wakeAt = nil
        }
        return SpellPause.waitingCaret(in: state)
    }

    /// Advances the timer at `now`, returning `(nextWakeAt, needsRepaint)`.
    public mutating func tick(now: Double) -> (wakeAt: Double?, needsRepaint: Bool) {
        let (next, effect) = SpellPause.step(state, event: .tick(now: now))
        state = next
        switch effect {
        case let .schedule(t):
            wakeAt = t
            return (t, false)
        case .clearTimer:
            wakeAt = nil
            return (nil, false)
        case .repaint:
            wakeAt = nil
            return (nil, true)
        case nil:
            return (wakeAt, false)
        }
    }
}

/// Misspelled squiggle geometry helper & caret-pause filtering.
public enum SpellSquiggle {
    /// Builds polyline wave vertices `(x, y)` for a red spellcheck underline along `rect`.
    public static func wavePoints(rect: MotionRect, amplitude: Float = 1.25, period: Float = 4.0) -> [Vec2] {
        guard rect.width > 0 else { return [] }
        let step = max(1.0, period * 0.5)
        var points: [Vec2] = []
        var x = rect.left
        var up = false
        let baseY = rect.bottom - amplitude * 0.5
        while x < rect.right {
            let y = up ? baseY - amplitude : baseY + amplitude
            points.append(Vec2(x, y))
            up.toggle()
            x += step
        }
        points.append(Vec2(rect.right, up ? baseY - amplitude : baseY + amplitude))
        return points
    }
}

public extension SpellChecker {
    /// Returns misspelled UTF-8 ranges excluding the word currently under the caret while `SpellPauseWatch` is typing.
    func misspelledUTF8Ranges(
        in text: String,
        caretUTF8: Int,
        watch: inout SpellPauseWatch,
        path: String,
        now: Double
    ) -> [Range<Int>] {
        let pausedCaret = watch.observe(path: path, text: text, caret: caretUTF8, now: now)
        let raw = misspelledUTF8Ranges(in: text)
        guard let pausedCaret,
              let activeWord = SpellPause.wordRange(at: pausedCaret, in: text) else {
            return raw
        }
        return raw.filter { !($0.overlaps(activeWord)) }
    }
}
