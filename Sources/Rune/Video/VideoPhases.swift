import Foundation

/// Pure phase state machine matching `crates/rune/src/video/phases.rs`.
public enum VideoPhases {
    public static let seekPatienceSeconds: Double = 2.0
    public static let audioSeekSlopSeconds: Double = 0.25
    public static let loadPatienceSeconds: Double = 30.0

    public enum Run: Sendable, Equatable {
        case idle
        case waiting(UInt64)
        case loading(since: Double)
        case ready(duration: Double?)
        case failed(String)
    }

    public enum Stage: Sendable, Equatable {
        case clear
        case asked(seq: UInt64, at: Double)
        case ready
        case failed(String)
    }

    public struct Settle: Sendable, Equatable {
        public var time: Double = 0.0
        public var pending: Bool = false
        public var generation: UInt64 = 0
        public var deadline: Double? = nil
        public var exact: Bool = false

        public init() {}

        public var isWaiting: Bool { pending }

        public mutating func seek(to time: Double, exact: Bool, now: Double) {
            self.time = max(0.0, time)
            self.pending = true
            self.generation &+= 1
            self.deadline = now + seekPatienceSeconds
            self.exact = exact
        }

        public mutating func framed() {
            pending = false
            deadline = nil
        }

        public mutating func expire(now: Double) {
            if pending, let d = deadline, now >= d {
                pending = false
                deadline = nil
            }
        }

        public mutating func clear() {
            pending = false
            deadline = nil
        }
    }

    public enum ItemStatus: Sendable, Equatable {
        case loading
        case ready(duration: Double?)
        case failed(String)
    }

    public struct Item: Sendable, Equatable {
        public var generation: UInt64
        public var status: ItemStatus
        public var currentTime: Double
        public var playerRate: Float
        public var frameTime: Double?

        public init(
            generation: UInt64 = 0,
            status: ItemStatus = .loading,
            currentTime: Double = 0.0,
            playerRate: Float = 0.0,
            frameTime: Double? = nil
        ) {
            self.generation = generation
            self.status = status
            self.currentTime = currentTime
            self.playerRate = playerRate
            self.frameTime = frameTime
        }
    }

    public enum ControlAction: Sendable, Equatable {
        case play
        case pause
        case seek(Double)
        case setLooping(Bool)
        case setMuted(Bool)
        case setVolume(Float)
        case setRate(Float)
    }

    public enum Effect: Sendable, Equatable {
        case dropPlayer
        case ensurePlayer
        case setRate(Float)
        case seek(Double, exact: Bool)
        case requestPoster(Double, generation: UInt64)
        case fail(String)
        case park
        case unpark
        case restart(Float)
    }

    public struct Machine: Sendable, Equatable {
        public var isAudio: Bool
        public var playing: Bool = false
        public var looping: Bool = false
        public var rate: Float = 1.0
        public var volume: Float = 1.0
        public var muted: Bool = false
        public var time: Double = 0.0
        public var duration: Double? = nil
        public var generation: UInt64 = 0
        public var run: Run = .idle
        public var poster: Stage = .clear
        public var settle: Settle = Settle()
        public var failed: String? = nil
        public var hasPlayer: Bool = false
        public var ended: Bool = false
        public var seekSequence: Seq = Seq()
        public var posterSequence: Seq = Seq()

        public init(isAudio: Bool = false, playing: Bool = false, looping: Bool = false, muted: Bool = false, volume: Float = 1.0, rate: Float = 1.0) {
            self.isAudio = isAudio
            self.playing = playing
            self.looping = looping
            self.muted = muted
            self.volume = volume
            self.rate = rate
        }

        /// Evaluates `control` and updates pure control state + seek requests.
        public mutating func apply(_ action: ControlAction, at now: Double) -> [Effect] {
            var effects: [Effect] = []
            switch action {
            case .play:
                if failed != nil { return [] }
                if ended {
                    time = 0.0
                    ended = false
                    settle.seek(to: 0.0, exact: true, now: now)
                    effects.append(.seek(0.0, exact: true))
                }
                playing = true
                if !hasPlayer {
                    effects.append(.ensurePlayer)
                    effects.append(.unpark)
                }
                if case .ready = run {
                    effects.append(.setRate(rate))
                }
            case .pause:
                playing = false
                if hasPlayer {
                    effects.append(.setRate(0.0))
                }
            case .seek(let t):
                if failed != nil { return [] }
                let clamped = duration.map { min(max(0.0, t), max(0.0, $0)) } ?? max(0.0, t)
                time = clamped
                ended = false
                settle.seek(to: clamped, exact: true, now: now)
                if hasPlayer {
                    effects.append(.seek(clamped, exact: true))
                } else if !isAudio {
                    let g = posterSequence.next()
                    poster = .asked(seq: g, at: clamped)
                    effects.append(.requestPoster(clamped, generation: g))
                } else {
                    effects.append(.ensurePlayer)
                    effects.append(.seek(clamped, exact: true))
                }
            case .setLooping(let l):
                looping = l
                if l && ended && !failed.isSome {
                    ended = false
                    playing = true
                    time = 0.0
                    effects.append(.restart(rate))
                }
            case .setMuted(let m):
                muted = m
            case .setVolume(let v):
                volume = min(max(0.0, v), 1.0)
            case .setRate(let r):
                rate = max(0.0, r)
                if playing, case .ready = run, hasPlayer {
                    effects.append(.setRate(rate))
                }
            }
            return effects
        }

        /// Checks end-of-stream / looping when an item reports `currentTime` and `atEnd`.
        /// Returns true if playback restarted from the beginning due to looping.
        public mutating func observe(time observedTime: Double, atEnd: Bool) -> Bool {
            if atEnd && !settle.isWaiting {
                if looping {
                    time = 0.0
                    ended = false
                    return true
                }
                time = duration ?? observedTime
                if playing {
                    playing = false
                    ended = true
                }
                return false
            }
            time = observedTime
            if atEnd == false && playing {
                ended = false
            }
            return false
        }

        /// True if an older poster response is overtaken by newer playback or seek state.
        public func posterOvertaken(seq: UInt64) -> Bool {
            if playing || failed != nil { return true }
            if case .asked(let expected, _) = poster {
                return seq != expected
            }
            return true
        }

        /// Reconciles an active `Item` snapshot with desired control state, returning effects and whether active ticking is needed.
        public mutating func step(item: Item?, onMain: Bool, at now: Double) -> (active: Bool, effects: [Effect]) {
            if let f = failed {
                if hasPlayer {
                    hasPlayer = false
                    return (false, [.fail(f), .dropPlayer])
                }
                return (false, [])
            }
            guard onMain else {
                return (playing || settle.isWaiting, [])
            }

            var effects: [Effect] = []

            if !hasPlayer && !playing {
                if !isAudio, case .clear = poster, !ended {
                    let g = posterSequence.next()
                    poster = .asked(seq: g, at: time)
                    effects.append(.requestPoster(time, generation: g))
                }
                return (false, effects)
            }

            if !hasPlayer {
                hasPlayer = true
                run = .loading(since: now)
                effects.append(.ensurePlayer)
                effects.append(.unpark)
            }

            guard let item else {
                return (true, effects)
            }

            switch item.status {
            case .loading:
                if case .loading(let since) = run, now - since >= VideoPhases.loadPatienceSeconds {
                    let msg = "timed out waiting for media item"
                    failed = msg
                    run = .failed(msg)
                    hasPlayer = false
                    effects.append(.fail(msg))
                    effects.append(.dropPlayer)
                    return (false, effects)
                }
                return (true, effects)

            case .failed(let msg):
                failed = msg
                run = .failed(msg)
                hasPlayer = false
                effects.append(.fail(msg))
                effects.append(.dropPlayer)
                return (false, effects)

            case .ready(let dur):
                if let dur { duration = dur }
                run = .ready(duration: duration)
            }

            let seeking = settle.isWaiting
            if let ft = item.frameTime {
                if seeking && abs(ft - settle.time) <= 0.1 {
                    settle.framed()
                }
            } else if isAudio && seeking && abs(item.currentTime - settle.time) <= VideoPhases.audioSeekSlopSeconds {
                settle.framed()
            }

            settle.expire(now: now)

            let stopped = playing && !settle.isWaiting && (item.playerRate == 0.0)
            let atEnd: Bool
            if isAudio {
                atEnd = !settle.isWaiting && ((duration.map { item.currentTime >= $0 - 1e-3 } ?? false) || stopped)
            } else {
                atEnd = !settle.isWaiting && ((duration.map { item.currentTime >= $0 - 1e-3 } ?? false) || stopped)
            }

            let observed = settle.isWaiting ? time : (playing && !atEnd ? (item.frameTime ?? item.currentTime) : item.currentTime)
            if observe(time: observed, atEnd: atEnd) {
                settle.seek(to: 0.0, exact: false, now: now)
                generation &+= 1
                effects.append(.restart(rate))
                effects.append(.seek(0.0, exact: false))
            } else if !playing && item.playerRate != 0.0 {
                effects.append(.setRate(0.0))
            } else if playing && !atEnd && abs(item.playerRate - rate) > 1e-3 {
                effects.append(.setRate(rate))
            }

            let active = playing || settle.isWaiting
            effects.append(active ? .unpark : .park)
            return (active, effects)
        }
    }
}

private extension Optional {
    var isSome: Bool { self != nil }
}
