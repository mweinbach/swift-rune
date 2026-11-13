import Foundation

/// Platform player port abstraction matching `crates/rune/src/video/turn.rs`.
public protocol VideoPort {
    func playerReady() -> Bool
    func playerHasFrame() -> Bool
    func apply(request: MediaRequest)
    func play()
    func seek(to time: Double)
    func seekAndPlay(to time: Double)
    func setRate(_ rate: Float)
    func pause()
    func requestPoster(at time: Double)
    func releasePlayer()
    func fail(_ message: String)
}

/// Synchronized snapshot of one control turn passed into `VideoTurn.reconcile`.
public struct VideoTurnState: Sendable, Equatable {
    public var playing: Bool
    public var looping: Bool
    public var rate: Float
    public var volume: Float
    public var muted: Bool
    public var seekGeneration: UInt64
    public var time: Double
    public var failed: String?

    public init(
        playing: Bool = false,
        looping: Bool = false,
        rate: Float = 1.0,
        volume: Float = 1.0,
        muted: Bool = false,
        seekGeneration: UInt64 = 0,
        time: Double = 0.0,
        failed: String? = nil
    ) {
        self.playing = playing
        self.looping = looping
        self.rate = rate
        self.volume = volume
        self.muted = muted
        self.seekGeneration = seekGeneration
        self.time = time
        self.failed = failed
    }
}

/// Reconciles control mutations, seek generations, and failure state across `VideoPort` turns (`video::turn`).
public enum VideoTurn {
    public static func carry(from request: MediaRequest, into turn: inout VideoTurnState, lastSeekGen: inout UInt64) -> Bool {
        var seekRequested = false
        turn.playing = request.playing
        turn.looping = request.looping
        turn.rate = request.rate
        turn.volume = request.volume
        turn.muted = request.muted
        if let seek = request.seek, seek.generation != lastSeekGen {
            lastSeekGen = seek.generation
            turn.seekGeneration = seek.generation
            turn.time = max(0.0, seek.time)
            seekRequested = true
        }
        return seekRequested
    }

    public static func reconcile(
        turn: VideoTurnState,
        seekRequested: Bool,
        wasPlaying: Bool,
        port: VideoPort
    ) {
        if let err = turn.failed {
            port.fail(err)
            return
        }
        if seekRequested {
            if turn.playing {
                port.seekAndPlay(to: turn.time)
            } else {
                port.seek(to: turn.time)
                port.pause()
            }
            return
        }
        if turn.playing && !wasPlaying {
            port.play()
        } else if !turn.playing && wasPlaying {
            port.pause()
        }
        if turn.playing && port.playerReady() {
            port.setRate(turn.rate)
        }
    }

    // MARK: - Full `turn.rs` Port & Turn Runner

    public enum PhaseTurnResult: Sendable, Equatable {
        case idle
        case loading
        case finished
    }

    public static func phaseCarry<P: PhasePort>(
        _ c: inout VideoPhases.PhaseControl,
        port: inout P,
        effects: Effects<VideoPhases.PhaseEffect>
    ) {
        for effect in effects {
            switch effect {
            case .placeholder:
                break
            case .askPoster(let at, let attempt):
                port.askPoster(at: at, attempt: attempt)
            case .showPoster:
                switch port.showPoster(nextId: { c.nextFrameId() }) {
                case .success:
                    break
                case .failure(let err):
                    c.fail(err)
                }
            case .makePlayer:
                switch port.makePlayer() {
                case .success(let created):
                    _ = VideoPhases.phaseStep(&c, .playerMade(created: created))
                case .failure(let err):
                    c.fail(err)
                }
            case .dropPlayer:
                port.dropPlayer()
            case .orient:
                port.orient()
            case .readFacts:
                c.open(.success(port.itemFacts()))
            case .setMuted(let muted):
                port.setMuted(muted)
            case .setVolume(let volume):
                port.setVolume(volume)
            case .seekTo(let at):
                port.seekTo(at)
            case .setRate(let rate):
                port.setRate(rate)
            case .restart(let rate):
                port.restart(rate)
            }
        }
    }

    private static func phaseSend<P: PhasePort>(
        _ c: inout VideoPhases.PhaseControl,
        port: inout P,
        event: VideoPhases.PhaseEvent
    ) {
        let effects = VideoPhases.phaseStep(&c, event)
        phaseCarry(&c, port: &port, effects: effects)
    }

    public static func phaseReconcile<P: PhasePort>(
        _ c: inout VideoPhases.PhaseControl,
        port: inout P,
        now: Double
    ) {
        if port.alive() {
            phaseSend(&c, port: &port, event: .reconcile(now: now))
        }
    }

    private static func takePoster<P: PhasePort>(
        _ c: inout VideoPhases.PhaseControl,
        port: inout P
    ) {
        if let (attempt, result) = port.takePoster() {
            phaseSend(&c, port: &port, event: .posterDone(attempt: attempt, result: result))
        }
    }

    private static func follow<P: PhasePort>(
        _ c: inout VideoPhases.PhaseControl,
        port: inout P,
        frameTime: Double?,
        now: Double
    ) {
        let current = port.current()
        let stopped = c.stage.isRunning && port.stopped()
        phaseSend(&c, port: &port, event: .follow(current: current, stopped: stopped, frameTime: frameTime, now: now))
    }

    public static func phaseTurn<P: PhasePort>(
        _ c: inout VideoPhases.PhaseControl,
        port: inout P,
        now: Double
    ) -> PhaseTurnResult {
        takePoster(&c, port: &port)
        if c.isFailed {
            phaseSend(&c, port: &port, event: .release)
            return .idle
        }
        if !port.onMain() {
            return .idle
        }
        let fresh = !c.stage.hasPlayer
        phaseSend(&c, port: &port, event: .pull)
        if !c.stage.hasPlayer {
            return .idle
        }
        if fresh {
            port.unpark()
        }
        let item = port.item()
        phaseSend(&c, port: &port, event: .item(item, now: now))
        if !c.stage.hasPlayer {
            return .idle
        }
        phaseReconcile(&c, port: &port, now: now)
        switch (c.kind, c.stage.isReady) {
        case (.video, true):
            let (itemTime, landed) = port.frame(nextId: { c.nextFrameId() })
            switch landed {
            case .success(let shown?):
                _ = VideoPhases.phaseStep(&c, .framed(shown: shown))
            case .success(nil):
                break
            case .failure(let err):
                c.fail(err)
                phaseSend(&c, port: &port, event: .release)
                return .idle
            }
            follow(&c, port: &port, frameTime: itemTime, now: now)
        case (.video, false):
            break
        case (.audio, false):
            return .loading
        case (.audio, true):
            follow(&c, port: &port, frameTime: nil, now: now)
        }
        _ = VideoPhases.phaseStep(&c, .finish(now: now))
        return .finished
    }
}

public protocol PhasePort {
    mutating func onMain() -> Bool
    mutating func takePoster() -> (AttemptToken, Result<VideoPhases.PhaseMeta, VideoPhases.PhaseError>)?
    mutating func showPoster(nextId: () -> UInt64) -> Result<Void, VideoPhases.PhaseError>
    mutating func askPoster(at: Double, attempt: AttemptToken)
    mutating func makePlayer() -> Result<Double, VideoPhases.PhaseError>
    mutating func dropPlayer()
    mutating func unpark()
    func item() -> VideoPhases.PhaseItem
    mutating func orient()
    func itemFacts() -> VideoPhases.PhaseMeta
    func alive() -> Bool
    mutating func setMuted(_ muted: Bool)
    mutating func setVolume(_ volume: Float)
    mutating func seekTo(_ at: Double)
    mutating func setRate(_ rate: Float)
    mutating func restart(_ rate: Float)
    mutating func frame(nextId: () -> UInt64) -> (Double, Result<Double?, VideoPhases.PhaseError>)
    func current() -> Double
    mutating func stopped() -> Bool
}
