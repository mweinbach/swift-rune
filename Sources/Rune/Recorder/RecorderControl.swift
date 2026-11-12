import Foundation

internal enum RecorderBackendHolder: @unchecked Sendable {
    case macos(RecorderBackendSession)
}

internal struct FakeSession: @unchecked Sendable {
    let input: FakeInput
    let url: URL
    var meter: RecorderMeter
    var metered: UInt64
    let unplug: Double?

    init(input: FakeInput, url: URL, unplug: Double?) {
        self.input = input
        self.url = url
        self.meter = RecorderMeter()
        self.metered = 0
        self.unplug = unplug
    }

    func unplugged(at elapsed: Double) -> Double? {
        guard let unplug, elapsed + RecorderControl.clockSlack >= unplug else { return nil }
        return unplug
    }

    func write(seconds: Double) -> Result<Recording, RecorderError> {
        let s = unplug.map { min(seconds, $0) } ?? seconds
        let frames = RecorderControl.framesAt(seconds: s, rate: input.rate)
        return FakeMicrophone.writeWAV(to: url, input: input, frames: frames).map { _ in
            Recording(url: url, duration: Double(frames) / Double(input.rate))
        }
    }

    mutating func meterTo(elapsed: Double) -> Level {
        let inp = self.input
        let rate = inp.rate
        let target = RecorderControl.framesAt(seconds: elapsed, rate: rate)
        let block = UInt64(max(1, rate / 100))
        let windowFrames = 10 * UInt64(rate)
        let floorBlock = (target > windowFrames ? (target - windowFrames) : 0) / block * block
        metered = max(metered, floorBlock)
        while metered + block <= target {
            let start = metered
            meter.pushSamples(rate: rate, count: Int(block)) { i in
                inp.sample(start + UInt64(i))
            }
            metered += block
        }
        return meter.level()
    }
}

internal enum RecorderSource: @unchecked Sendable {
    case device(RecorderBackendSession)
    case fake(FakeSession)
}

internal enum RecorderPhase: @unchecked Sendable {
    case idle
    case asking(attempt: UInt64)
    case opening(attempt: UInt64, session: RecorderBackendSession)
    case recording(attempt: UInt64, source: RecorderSource, anchor: (clock: Double, at: Double)?)
    case paused(attempt: UInt64, source: RecorderSource)
    case stopping(attempt: UInt64, paused: Bool)
    case interrupted(attempt: UInt64, reason: String, saved: Recording)
    case stopped
    case failed(String)
}

internal enum RecorderEvent {
    case start(url: URL, virtualClock: Bool)
    case permission(attempt: UInt64, granted: Result<Void, RecorderError>)
    case fakeOpened(attempt: UInt64, opened: Result<FakeSession, RecorderError>)
    case deviceOpened(attempt: UInt64, opened: Result<RecorderBackendSession, RecorderError>)
    case began(attempt: UInt64)
    case failed(attempt: UInt64, error: String)
    case interrupted(attempt: UInt64, reason: String, duration: Double)
    case metered(attempt: UInt64, level: Level)
    case tick
    case pause
    case resume
    case stop
    case stopped(attempt: UInt64, result: Result<Double, RecorderError>)
    case cancel
}

internal enum RecorderEffect {
    case silence
    case publish(Level)
    case ask(attempt: UInt64)
    case open(attempt: UInt64)
    case followHeadless
    case pauseDevice
    case resumeDevice
    case stopDevice(attempt: UInt64, session: RecorderBackendSession)
    case cancelDevice(RecorderBackendSession)
    case removeFile(URL)
    case reply(Result<Recording, RecorderError>)
}

internal struct RecorderControl: @unchecked Sendable {
    static let clockSlack: Double = 1e-9
    static let notRecordingMessage = "not recording"
    static let stoppedEarlyMessage = "stopped before recording started"

    var phase: RecorderPhase = .idle
    var seq = Seq()
    var generation: UInt64 = 0
    var elapsed: Double = 0.0
    var virtualClock: Bool = false
    var url: URL

    init(url: URL) {
        self.url = url
    }

    static func framesAt(seconds: Double, rate: UInt32) -> UInt64 {
        let scaled = floor((seconds + clockSlack) * Double(rate))
        return scaled > 0.0 ? UInt64(scaled) : 0
    }

    static func advance(elapsed: inout Double, anchor: inout (clock: Double, at: Double)?, now: Double?) {
        guard let now else { return }
        if let (clock, at) = anchor, clock <= now {
            elapsed = at + (now - clock)
        } else {
            anchor = (now, elapsed)
        }
    }

    func status() -> RecorderState {
        switch phase {
        case .idle: return .idle
        case .asking, .opening: return .starting
        case .recording, .stopping(_, paused: false): return .recording
        case .paused, .stopping(_, paused: true): return .paused
        case let .interrupted(_, reason, _): return .interrupted(reason)
        case .stopped: return .stopped
        case let .failed(msg): return .failed(msg)
        }
    }

    var isFake: Bool {
        switch phase {
        case .recording(_, .fake, _), .paused(_, .fake): return true
        default: return false
        }
    }

    var deviceSession: RecorderBackendSession? {
        switch phase {
        case let .recording(_, .device(s), _), let .paused(_, .device(s)): return s
        default: return nil
        }
    }

    mutating func restartClock() {
        if case let .recording(attempt, source, .some) = phase {
            phase = .recording(attempt: attempt, source: source, anchor: (0.0, elapsed))
        }
    }

    mutating func step(_ event: RecorderEvent, now: Double?) -> Effects<RecorderEffect> {
        let before = status()
        let effects = transition(event, now: now)
        if status() != before {
            generation &+= 1
        }
        return effects
    }

    private mutating func transition(_ event: RecorderEvent, now: Double?) -> Effects<RecorderEffect> {
        switch (phase, event) {
        case (.asking, .start), (.opening, .start), (.recording, .start), (.paused, .start), (.stopping, .start):
            return .none

        case let (_, .start(newURL, vc)):
            let attempt = seq.next()
            elapsed = 0.0
            url = newURL
            virtualClock = vc
            phase = .asking(attempt: attempt)
            return .two(.silence, .ask(attempt: attempt))

        case let (.asking(attempt), .permission(a, granted)) where a == attempt:
            switch granted {
            case .success:
                return .one(.open(attempt: attempt))
            case .failure(let err):
                phase = .failed(err.message)
                return .none
            }

        case let (.asking(attempt), .fakeOpened(a, opened)) where a == attempt:
            switch opened {
            case .success(let fake):
                let anchor = now.map { ($0, 0.0) }
                phase = .recording(attempt: attempt, source: .fake(fake), anchor: anchor)
                return virtualClock ? .one(.followHeadless) : .none
            case .failure(let err):
                phase = .failed(err.message)
                return .none
            }

        case let (.asking(attempt), .deviceOpened(a, opened)) where a == attempt:
            switch opened {
            case .success(let session):
                phase = .opening(attempt: attempt, session: session)
                return .none
            case .failure(let err):
                phase = .failed(err.message)
                return .none
            }

        case let (_, .deviceOpened(_, .success(session))):
            return .one(.cancelDevice(session))

        case let (.opening(attempt, session), .began(a)) where a == attempt:
            let anchor = now.map { ($0, 0.0) }
            phase = .recording(attempt: attempt, source: .device(session), anchor: anchor)
            return .none

        case let (.asking(attempt), .failed(a, err)) where a == attempt,
             let (.opening(attempt, _), .failed(a, err)) where a == attempt:
            phase = .failed(err)
            return .none

        case let (.recording(attempt, _, anchorInit), .interrupted(a, reason, duration)) where a == attempt:
            var anchor = anchorInit
            Self.advance(elapsed: &elapsed, anchor: &anchor, now: now)
            let saved = Recording(url: url, duration: duration)
            phase = .interrupted(attempt: attempt, reason: reason, saved: saved)
            return .one(.silence)

        case let (.paused(attempt, _), .interrupted(a, reason, duration)) where a == attempt,
             let (.stopping(attempt, _), .interrupted(a, reason, duration)) where a == attempt:
            let saved = Recording(url: url, duration: duration)
            phase = .interrupted(attempt: attempt, reason: reason, saved: saved)
            return .one(.silence)

        case let (.recording(attempt, .device, _), .metered(a, level)) where a == attempt:
            return .one(.publish(level))

        case let (.recording(attempt, source, anchorInit), .tick):
            var anchor = anchorInit
            Self.advance(elapsed: &elapsed, anchor: &anchor, now: now)
            return catchUp(attempt: attempt, source: source, anchor: anchor)

        case let (.recording(attempt, source, anchorInit), .pause):
            var anchor = anchorInit
            Self.advance(elapsed: &elapsed, anchor: &anchor, now: now)
            var effects = catchUp(attempt: attempt, source: source, anchor: anchor)
            if case let .recording(att, src, _) = phase {
                effects.push(.silence)
                if case .device = src {
                    effects.push(.pauseDevice)
                }
                phase = .paused(attempt: att, source: src)
            }
            return effects

        case let (.paused(attempt, source), .resume):
            let anchor = now.map { ($0, elapsed) }
            phase = .recording(attempt: attempt, source: source, anchor: anchor)
            if case .device = source {
                return .one(.resumeDevice)
            }
            return .none

        case let (.recording(attempt, source, anchorInit), .stop):
            var anchor = anchorInit
            Self.advance(elapsed: &elapsed, anchor: &anchor, now: now)
            var effects = catchUp(attempt: attempt, source: source, anchor: anchor)
            let more = stopCurrentPhase()
            for e in more { effects.push(e) }
            return effects

        case (_, .stop):
            return stopCurrentPhase()

        case let (.stopping(attempt, _), .stopped(a, res)) where a == attempt:
            let mapped = res.map { Recording(url: url, duration: $0) }
            switch mapped {
            case .success:
                phase = .stopped
            case .failure(let err):
                phase = .failed(err.message)
            }
            return .two(.silence, .reply(mapped))

        case let (.interrupted(attempt, _, saved), .stopped(a, _)) where a == attempt:
            phase = .stopped
            return .two(.silence, .reply(.success(saved)))

        case (.asking, .cancel):
            phase = .idle
            return .one(.silence)

        case let (.opening(_, session), .cancel),
             let (.recording(_, .device(session), _), .cancel),
             let (.paused(_, .device(session)), .cancel):
            phase = .idle
            return .two(.silence, .cancelDevice(session))

        case let (.recording(_, .fake(fake), _), .cancel),
             let (.paused(_, .fake(fake)), .cancel):
            phase = .idle
            return .two(.silence, .removeFile(fake.url))

        case let (.interrupted(_, _, saved), .cancel):
            phase = .idle
            return .two(.silence, .removeFile(saved.url))

        default:
            return .none
        }
    }

    private mutating func stopCurrentPhase() -> Effects<RecorderEffect> {
        let current = phase
        let attempt: UInt64
        let source: RecorderSource
        let paused: Bool

        switch current {
        case let .recording(a, s, _):
            attempt = a; source = s; paused = false
        case let .paused(a, s):
            attempt = a; source = s; paused = true
        case let .interrupted(_, _, saved):
            phase = .stopped
            return .one(.reply(.success(saved)))
        case .asking:
            phase = .idle
            return .one(.reply(.failure(RecorderError(Self.stoppedEarlyMessage))))
        case let .opening(_, session):
            phase = .idle
            return .two(.cancelDevice(session), .reply(.failure(RecorderError(Self.stoppedEarlyMessage))))
        case let .failed(msg):
            return .one(.reply(.failure(RecorderError(msg))))
        case .idle, .stopped, .stopping:
            return .one(.reply(.failure(RecorderError(Self.notRecordingMessage))))
        }

        switch source {
        case .fake(let fake):
            let res = fake.write(seconds: elapsed)
            switch res {
            case .success:
                phase = .stopped
            case .failure(let err):
                phase = .failed(err.message)
            }
            return .two(.silence, .reply(res))
        case .device(let session):
            phase = .stopping(attempt: attempt, paused: paused)
            return .one(.stopDevice(attempt: attempt, session: session))
        }
    }

    private mutating func catchUp(
        attempt: UInt64,
        source: RecorderSource,
        anchor: (clock: Double, at: Double)?
    ) -> Effects<RecorderEffect> {
        switch source {
        case .device:
            phase = .recording(attempt: attempt, source: source, anchor: anchor)
            return .none
        case var .fake(fake):
            if let unplug = fake.unplugged(at: elapsed) {
                elapsed = unplug
                switch fake.write(seconds: unplug) {
                case .success(let saved):
                    phase = .interrupted(attempt: attempt, reason: "the microphone went away", saved: saved)
                case .failure(let err):
                    phase = .failed(err.message)
                }
                return .one(.silence)
            }
            let level = fake.meterTo(elapsed: elapsed)
            phase = .recording(attempt: attempt, source: .fake(fake), anchor: anchor)
            return .one(.publish(level))
        }
    }
}
