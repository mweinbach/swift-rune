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
        public var holding: Bool = false
        public var generation: UInt64 = 0
        public var deadline: Double? = nil
        public var exact: Bool = false
        public var since: Double = 0.0

        public init() {}

        public var isStill: Bool { !pending && !holding }
        public var isPending: Bool { pending || holding }
        public var isWaiting: Bool { pending }
        public var isHolding: Bool { holding }

        public mutating func seek(to time: Double, exact: Bool, now: Double) {
            self.time = max(0.0, time)
            self.pending = true
            self.holding = false
            self.generation &+= 1
            self.since = now
            self.deadline = now + seekPatienceSeconds
            self.exact = exact
        }

        public mutating func seek(to time: Double, sameFrame: Bool, now: Double) {
            self.time = max(0.0, time)
            self.generation &+= 1
            if sameFrame {
                self.pending = false
                self.holding = true
                self.deadline = nil
                self.exact = true
            } else {
                self.pending = true
                self.holding = false
                self.since = now
                self.deadline = now + seekPatienceSeconds
                self.exact = false
            }
        }

        public mutating func framed() {
            pending = false
            deadline = nil
        }

        public mutating func observe(current: Double, playing: Bool, isAudio: Bool) {
            if pending && isAudio && abs(current - time) < VideoPhases.audioSeekSlopSeconds {
                pending = false
                deadline = nil
            } else if holding && (playing || abs(current - time) < 1e-3) {
                holding = false
            }
        }

        public mutating func expire(now: Double) {
            if pending, let d = deadline, now > d {
                pending = false
                deadline = nil
            }
        }

        public mutating func clear() {
            pending = false
            holding = false
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
                guard r.isFinite && r > 0 else { return [] }
                rate = r
                if playing, case .ready = run, hasPlayer {
                    effects.append(.setRate(rate))
                }
            }
            return effects
        }

        /// Checks end-of-stream / looping when an item reports `currentTime` and `atEnd`.
        /// Returns true if playback restarted from the beginning due to looping.
        public mutating func observe(time observedTime: Double, atEnd: Bool) -> Bool {
            let clamped = duration.map { min(max(0.0, observedTime), max(0.0, $0)) } ?? observedTime
            time = clamped
            guard playing && atEnd else {
                if !atEnd && playing {
                    ended = false
                }
                return false
            }
            if looping {
                time = 0.0
                ended = false
                return true
            }
            playing = false
            ended = true
            generation &+= 1
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
                if !isAudio {
                    posterSequence.cancel()
                    poster = .clear
                }
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
            let atEnd = !settle.isWaiting && ((duration.map { item.currentTime >= $0 - 1e-3 } ?? false) || stopped)

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

    // MARK: - Full `phases.rs` Pure State Machine (`PhaseControl` + `phaseStep`)

    public enum PhaseError: Error, Sendable, Equatable {
        case loadFailed
        case posterPushFailed
        case openFailed
        case genericFailed
        case itemFailed
        case couldNotMakePlayer
        case framePushFailed
        case timedOutLoading
        case custom(String)

        public var message: String {
            switch self {
            case .loadFailed: return "load failed"
            case .posterPushFailed: return "poster push failed"
            case .openFailed: return "open failed"
            case .genericFailed: return "failed"
            case .itemFailed: return "item failed"
            case .couldNotMakePlayer: return "couldn't make a player"
            case .framePushFailed: return "frame push failed"
            case .timedOutLoading: return "timed out loading after 30 s"
            case .custom(let s): return s
            }
        }
    }

    public struct PhaseMeta: Sendable, Equatable {
        public var duration: Double
        public var size: (UInt32, UInt32)?
        public var frame: Double
        public var sound: Bool

        public init(duration: Double, size: (UInt32, UInt32)? = nil, frame: Double = 0.25, sound: Bool = false) {
            self.duration = duration
            self.size = size
            self.frame = frame
            self.sound = sound
        }

        public var frames: Int64 {
            max(1, Int64((duration / frame).rounded()))
        }

        public func frameIndex(_ t: Double) -> Int64 {
            let raw = Int64((t / frame + 1e-6).rounded(.down))
            return min(max(0, raw), frames - 1)
        }

        public func frameTime(_ i: Int64) -> Double {
            min((Double(i) + 0.5) * frame, duration)
        }

        public static func == (lhs: PhaseMeta, rhs: PhaseMeta) -> Bool {
            lhs.duration == rhs.duration &&
            lhs.size?.0 == rhs.size?.0 &&
            lhs.size?.1 == rhs.size?.1 &&
            lhs.frame == rhs.frame &&
            lhs.sound == rhs.sound
        }
    }

    public enum PhaseRun: Sendable, Equatable {
        case paused
        case playing(anchorClock: Double?, anchorTime: Double?)
        case ended
        case failed(error: PhaseError, drawn: Bool)

        public var anchor: (Double, Double)? {
            if case .playing(let c?, let t?) = self { return (c, t) }
            return nil
        }

        public static func == (lhs: PhaseRun, rhs: PhaseRun) -> Bool {
            switch (lhs, rhs) {
            case (.paused, .paused), (.ended, .ended):
                return true
            case let (.playing(lc, lt), .playing(rc, rt)):
                return lc == rc && lt == rt
            case let (.failed(le, ld), .failed(re, rd)):
                return le == re && ld == rd
            default:
                return false
            }
        }
    }

    public enum PhaseStage: Sendable, Equatable {
        case unasked
        case poster
        case bare
        case loading(created: Double, muted: Bool, volume: Float)
        case ready(created: Double, muted: Bool, volume: Float, rate: Float, settle: Settle, shown: Double?)

        public var hasPlayer: Bool {
            switch self {
            case .loading, .ready: return true
            default: return false
            }
        }

        public var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        public var isRunning: Bool {
            if case .ready(_, _, _, let rate, _, _) = self { return rate > 0.0 }
            return false
        }
    }

    public enum PhaseItem: Sendable, Equatable {
        case loading
        case ready
        case failed(PhaseError)
    }

    public enum PhaseEvent: Sendable, Equatable {
        case play
        case pause
        case seek(Double)
        case rate(Float)
        case open(Result<PhaseMeta, PhaseError>)
        case fail(PhaseError)
        case clock(Double)
        case drawn
        case preload
        case loadAudio
        case posterDone(attempt: AttemptToken, result: Result<PhaseMeta, PhaseError>)
        case pull
        case playerMade(created: Double)
        case item(PhaseItem, now: Double)
        case reconcile(now: Double)
        case framed(shown: Double)
        case follow(current: Double, stopped: Bool, frameTime: Double?, now: Double)
        case finish(now: Double)
        case release
        case parked
    }

    public enum PhaseEffect: Sendable, Equatable {
        case placeholder
        case askPoster(Double, AttemptToken)
        case showPoster
        case makePlayer
        case dropPlayer
        case orient
        case readFacts
        case setMuted(Bool)
        case setVolume(Float)
        case seekTo(Double)
        case setRate(Float)
        case restart(Float)
    }

    public struct PhaseControl: Sendable, Equatable {
        public var kind: MediaKind = .video
        public var rate: Float = 1.0
        public var looping: Bool = false
        public var muted: Bool = true
        public var volume: Float = 1.0
        public var seek: Double? = nil
        public var time: Double = 0.0
        public var duration: Double? = nil
        public var size: (UInt32, UInt32)? = nil
        public var meta: PhaseMeta? = nil
        public var run: PhaseRun = .paused
        public var stage: PhaseStage = .unasked
        public var posters: Seq = Seq()
        public var posterAt: Double? = nil
        public var generation: UInt64 = 0
        public var frameId: UInt64 = 0
        public var shown: Int64? = nil

        public init(
            kind: MediaKind = .video,
            muted: Bool? = nil,
            rate: Float = 1.0,
            looping: Bool = false,
            volume: Float = 1.0
        ) {
            self.kind = kind
            self.muted = muted ?? (kind == .video)
            self.rate = rate
            self.looping = looping
            self.volume = volume
        }

        public var state: PlayerState {
            if case .failed(let e, _) = run {
                return .failed(e.message)
            } else if meta == nil {
                return .loading
            } else {
                switch run {
                case .playing: return .playing
                case .ended: return .ended
                default: return .ready
                }
            }
        }

        public var isPlaying: Bool {
            if case .playing = run { return true }
            return false
        }

        public var isFailed: Bool {
            if case .failed = run { return true }
            return false
        }

        public var isOpened: Bool {
            meta != nil || isFailed
        }

        public var isLive: Bool {
            if case .ready(_, _, _, let rate, let settle, _) = stage {
                return rate > 0.0 && !settle.isWaiting
            }
            return false
        }

        public var isActive: Bool {
            switch stage {
            case .ready(_, _, _, _, let settle, _):
                return isPlaying || settle.isWaiting
            default:
                return true
            }
        }

        public var isParkable: Bool {
            stage.isReady && !isActive
        }

        public mutating func open(_ result: Result<PhaseMeta, PhaseError>) {
            _ = VideoPhases.phaseStep(&self, .open(result))
        }

        public mutating func fail(_ error: PhaseError) {
            _ = VideoPhases.phaseStep(&self, .fail(error))
        }

        public mutating func advanceVirtual(at now: Double) {
            _ = VideoPhases.phaseStep(&self, .clock(now))
        }

        public mutating func nextFrameId() -> UInt64 {
            frameId &+= 1
            return frameId
        }

        public mutating func observe(time observedTime: Double, atEnd: Bool) -> Bool {
            time = duration.map { min(max(0.0, observedTime), $0) } ?? observedTime
            guard isPlaying && atEnd else { return false }
            if looping {
                time = 0.0
                return true
            }
            run = .ended
            generation &+= 1
            return false
        }

        public static func == (lhs: PhaseControl, rhs: PhaseControl) -> Bool {
            lhs.kind == rhs.kind &&
            lhs.rate == rhs.rate &&
            lhs.looping == rhs.looping &&
            lhs.muted == rhs.muted &&
            lhs.volume == rhs.volume &&
            lhs.seek == rhs.seek &&
            lhs.time == rhs.time &&
            lhs.duration == rhs.duration &&
            lhs.size?.0 == rhs.size?.0 &&
            lhs.size?.1 == rhs.size?.1 &&
            lhs.meta == rhs.meta &&
            lhs.run == rhs.run &&
            lhs.stage == rhs.stage &&
            lhs.posters == rhs.posters &&
            lhs.posterAt == rhs.posterAt &&
            lhs.generation == rhs.generation &&
            lhs.frameId == rhs.frameId &&
            lhs.shown == rhs.shown
        }
    }

    @discardableResult
    public static func phaseStep(_ c: inout PhaseControl, _ event: PhaseEvent) -> Effects<PhaseEffect> {
        switch event {
        case .play:
            switch c.run {
            case .failed:
                return .none
            case .ended:
                c.seek = 0.0
                c.time = 0.0
            case .paused, .playing:
                break
            }
            c.run = .playing(anchorClock: nil, anchorTime: nil)

        case .pause:
            if case .playing = c.run {
                c.run = .paused
            }

        case .seek(let seconds):
            let s = seconds.isFinite ? max(0.0, seconds) : 0.0
            let clamped = c.duration.map { min(s, $0) } ?? s
            c.seek = clamped
            c.time = clamped
            switch c.run {
            case .ended:
                c.run = .paused
            case .playing:
                c.run = .playing(anchorClock: nil, anchorTime: nil)
            case .paused, .failed:
                break
            }

        case .rate(let r):
            c.rate = r
            if case .playing = c.run {
                c.run = .playing(anchorClock: nil, anchorTime: nil)
            }

        case .open(.success(let m)):
            phaseOpened(&c, m)

        case .open(.failure(let e)), .fail(let e):
            phaseFailed(&c, e)

        case .clock(let now):
            phaseAdvance(&c, now)

        case .drawn:
            if case .failed(let e, false) = c.run {
                c.run = .failed(error: e, drawn: true)
                return .one(.placeholder)
            }

        case .preload:
            if c.kind != .audio && c.stage == .unasked && !c.isFailed {
                return phaseAskPoster(&c, at: c.time)
            }

        case .loadAudio:
            if c.stage == .unasked && !c.isOpened {
                return phaseAskPoster(&c, at: 0.0)
            }

        case .posterDone(let attempt, let result):
            if c.isFailed {
                return .none
            }
            let current = (attempt == c.posters.currentAttempt)
            switch result {
            case .success(let m):
                if !c.isOpened {
                    phaseOpened(&c, m)
                }
                if current && !phaseOvertaken(c) && c.stage == .poster {
                    return .one(.showPoster)
                }
            case .failure(let e):
                if current && !phaseOvertaken(c) && (c.kind == .video || !c.isOpened) {
                    phaseFailed(&c, e)
                }
            }

        case .pull:
            return phasePull(&c)

        case .playerMade(let created):
            if c.time > 0.0 && c.seek == nil {
                c.seek = c.time
            }
            if c.kind == .video {
                _ = c.posters.next()
                c.posterAt = nil
            }
            c.stage = .loading(created: created, muted: false, volume: 1.0)

        case .item(let item, let now):
            return phaseItemReports(&c, item, now)

        case .reconcile(let now):
            return phaseReconcile(&c, now)

        case .framed(let shownAt):
            if case .ready(let created, let muted, let volume, let rate, var settle, _) = c.stage {
                settle.framed()
                c.stage = .ready(created: created, muted: muted, volume: volume, rate: rate, settle: settle, shown: shownAt)
            }

        case .follow(let current, let stopped, let frameTime, let now):
            return phaseFollow(&c, current: current, stopped: stopped, frameTime: frameTime, now: now)

        case .finish(let now):
            if case .ready(let created, let muted, let volume, let rate, var settle, let shown) = c.stage {
                settle.expire(now: now)
                c.stage = .ready(created: created, muted: muted, volume: volume, rate: rate, settle: settle, shown: shown)
            }

        case .release:
            if c.stage.hasPlayer {
                c.stage = .bare
                return .one(.dropPlayer)
            }

        case .parked:
            let shown: Bool
            if case .ready(_, _, _, _, _, let s) = c.stage {
                shown = (s != nil)
            } else {
                shown = false
            }
            if c.stage.hasPlayer {
                c.stage = (c.kind == .video && !shown) ? .unasked : .bare
            }
        }
        return .none
    }

    private static func phaseOvertaken(_ c: PhaseControl) -> Bool {
        guard let asked = c.posterAt, let target = c.seek else { return false }
        let clampedTarget = c.duration.map { min(target, $0) } ?? target
        let clampedAsked = c.duration.map { min(asked, $0) } ?? asked
        return clampedTarget != clampedAsked
    }

    private static func phaseOpened(_ c: inout PhaseControl, _ meta: PhaseMeta) {
        c.meta = meta
        c.duration = meta.duration
        c.size = meta.size
        c.time = min(c.time, meta.duration)
        c.seek = c.seek.map { min($0, meta.duration) }
        c.generation &+= 1
    }

    private static func phaseFailed(_ c: inout PhaseControl, _ error: PhaseError) {
        if !c.isFailed {
            c.run = .failed(error: error, drawn: false)
            c.generation &+= 1
        }
    }

    private static func phaseAdvance(_ c: inout PhaseControl, _ now: Double) {
        guard let meta = c.meta else { return }
        if let t = c.seek.take() {
            c.time = min(t, meta.duration)
            if case .playing = c.run {
                c.run = .playing(anchorClock: nil, anchorTime: nil)
            }
        }
        guard case .playing(let anchorClock, let anchorTime) = c.run else { return }
        let startClock: Double
        let startTime: Double
        if let ac = anchorClock, let at = anchorTime, ac <= now {
            startClock = ac
            startTime = at
        } else {
            startClock = now
            startTime = c.time
            c.run = .playing(anchorClock: startClock, anchorTime: startTime)
        }
        let t = startTime + max(0.0, now - startClock) * Double(c.rate)
        if t < meta.duration {
            c.time = t
        } else if c.looping && meta.duration > 0.0 {
            c.time = t.truncatingRemainder(dividingBy: meta.duration)
        } else {
            c.time = meta.duration
            c.run = .ended
            c.generation &+= 1
        }
    }

    private static func phaseAskPoster(_ c: inout PhaseControl, at: Double) -> Effects<PhaseEffect> {
        if c.kind == .video && c.posterAt != at {
            _ = c.posters.next()
            c.posterAt = at
        }
        c.stage = (c.kind == .video) ? .poster : .bare
        return .one(.askPoster(at, c.posters.currentAttempt))
    }

    private static func phasePull(_ c: inout PhaseControl) -> Effects<PhaseEffect> {
        if c.stage.hasPlayer {
            return .none
        }
        if !c.isPlaying {
            if c.kind == .video {
                if let at = c.seek.take() ?? (c.stage == .unasked ? c.time : nil) {
                    return phaseAskPoster(&c, at: at)
                }
            }
            return .none
        }
        if c.kind == .audio && !c.isOpened {
            if c.stage == .unasked {
                return phaseAskPoster(&c, at: 0.0)
            }
            return .none
        }
        return .one(.makePlayer)
    }

    private static func phaseItemReports(_ c: inout PhaseControl, _ item: PhaseItem, _ now: Double) -> Effects<PhaseEffect> {
        let created: Double
        let muted: Bool
        let volume: Float
        switch c.stage {
        case let .loading(cr, m, v), let .ready(cr, m, v, _, _, _):
            created = cr
            muted = m
            volume = v
        default:
            return .none
        }

        let failure: PhaseError?
        switch item {
        case .failed(let err):
            failure = err
        case .loading where (now - created) > loadPatienceSeconds:
            failure = .timedOutLoading
        default:
            failure = nil
        }

        if let err = failure {
            phaseFailed(&c, err)
            c.stage = .bare
            return .one(.dropPlayer)
        }
        if item == .ready && !c.stage.isReady {
            c.stage = .ready(created: created, muted: muted, volume: volume, rate: 0.0, settle: Settle(), shown: nil)
            var effects = Effects<PhaseEffect>.one(.orient)
            if !c.isOpened {
                effects.push(.readFacts)
            }
            return effects
        }
        return .none
    }

    private static func phaseReconcile(_ c: inout PhaseControl, _ now: Double) -> Effects<PhaseEffect> {
        var effects = Effects<PhaseEffect>.none
        switch c.stage {
        case .loading(let created, var muted, var volume):
            if muted != c.muted {
                muted = c.muted
                effects.push(.setMuted(c.muted))
            }
            if volume != c.volume {
                volume = c.volume
                effects.push(.setVolume(c.volume))
            }
            c.stage = .loading(created: created, muted: muted, volume: volume)

        case .ready(let created, var muted, var volume, var rate, var settle, let shown):
            if muted != c.muted {
                muted = c.muted
                effects.push(.setMuted(c.muted))
            }
            if volume != c.volume {
                volume = c.volume
                effects.push(.setVolume(c.volume))
            }
            let playing = c.isPlaying
            if let t = c.seek.take() {
                effects.push(.seekTo(t))
                let sameFrame = !playing && (c.meta.flatMap { m in
                    shown.map { m.frameIndex($0) == m.frameIndex(t) }
                } ?? false)
                settle.seek(to: t, sameFrame: sameFrame, now: now)
            }
            let want = playing ? c.rate : 0.0
            if rate != want {
                rate = want
                effects.push(.setRate(want))
            }
            c.stage = .ready(created: created, muted: muted, volume: volume, rate: rate, settle: settle, shown: shown)

        default:
            break
        }
        return effects
    }

    private static func phaseFollow(_ c: inout PhaseControl, current: Double, stopped: Bool, frameTime: Double?, now: Double) -> Effects<PhaseEffect> {
        let playing = c.isPlaying
        guard case .ready(let created, let muted, let volume, let rate, var settle, let shown) = c.stage else {
            return .none
        }
        settle.observe(current: current, playing: playing, isAudio: frameTime == nil)
        let seeking = settle.isPending
        let atEnd = !seeking && ((c.duration.map { current >= $0 - 1e-3 } ?? false) || stopped)
        let time: Double
        if seeking {
            time = c.time
        } else if playing && !atEnd {
            time = max(0.0, frameTime ?? current)
        } else {
            time = current
        }
        c.stage = .ready(created: created, muted: muted, volume: volume, rate: rate, settle: settle, shown: shown)

        let restart = c.observe(time: time, atEnd: atEnd)
        let nowPlaying = c.isPlaying
        guard case .ready(let cr2, let m2, let v2, var r2, var s2, let sh2) = c.stage else {
            return .none
        }
        if restart {
            r2 = c.rate
            s2.seek(to: 0.0, sameFrame: false, now: now)
            c.generation &+= 1
            c.stage = .ready(created: cr2, muted: m2, volume: v2, rate: r2, settle: s2, shown: sh2)
            return .one(.restart(c.rate))
        }
        if !nowPlaying {
            r2 = 0.0
        }
        c.stage = .ready(created: cr2, muted: m2, volume: v2, rate: r2, settle: s2, shown: sh2)
        return .none
    }
}

private extension Optional {
    var isSome: Bool { self != nil }
    mutating func take() -> Wrapped? {
        let v = self
        self = nil
        return v
    }
}
