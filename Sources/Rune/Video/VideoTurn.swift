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
}
