import Foundation

/// Source location for a `Player` (`rune::video::MediaSource`).
public enum MediaSource: Sendable, Hashable {
    case file(URL)
    case url(URL)

    public var locationURL: URL {
        switch self {
        case .file(let u), .url(let u): return u
        }
    }

    public var isFile: Bool {
        if case .file = self { return true }
        return locationURL.isFileURL
    }

    public static func parse(_ pathOrUrl: String) -> MediaSource {
        let lower = pathOrUrl.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://"),
           let u = URL(string: pathOrUrl) {
            return .url(u)
        }
        return .file(URL(fileURLWithPath: pathOrUrl))
    }
}

/// Snapshot of desired playback controls & URL request headers (`rune::video::MediaRequest`).
public struct MediaRequest: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var source: MediaSource
    public var kind: MediaKind
    public var headers: [(name: String, value: String)]
    public var playing: Bool
    public var looping: Bool
    public var muted: Bool
    public var volume: Float
    public var rate: Float
    public var seek: (time: Double, generation: UInt64)?

    public var description: String {
        let names = headers.map(\.name)
        return "MediaRequest(source: \(source), kind: \(kind), headers: \(names))"
    }

    public var debugDescription: String {
        description
    }

    public init(
        source: MediaSource,
        kind: MediaKind = .video,
        headers: [(name: String, value: String)] = [],
        playing: Bool = false,
        looping: Bool = false,
        muted: Bool? = nil,
        volume: Float = 1.0,
        rate: Float = 1.0,
        seek: (time: Double, generation: UInt64)? = nil
    ) {
        self.source = source
        self.kind = kind
        self.headers = headers
        self.playing = playing
        self.looping = looping
        self.muted = muted ?? (kind == .video)
        self.volume = volume
        self.rate = rate
        self.seek = seek
    }

    public func header(_ name: String, _ value: String) -> MediaRequest {
        var copy = self
        copy.headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        copy.headers.append((name, value))
        return copy
    }

    public func audio() -> Player {
        var copy = self
        copy.kind = .audio
        copy.muted = false
        return Player(copy)
    }

    public func video() -> Player {
        var copy = self
        copy.kind = .video
        copy.muted = true
        return Player(copy)
    }

    public static func == (lhs: MediaRequest, rhs: MediaRequest) -> Bool {
        lhs.source == rhs.source &&
        lhs.kind == rhs.kind &&
        lhs.headers.count == rhs.headers.count &&
        zip(lhs.headers, rhs.headers).allSatisfy { $0.name == $1.name && $0.value == $1.value } &&
        lhs.playing == rhs.playing &&
        lhs.looping == rhs.looping &&
        lhs.muted == rhs.muted &&
        lhs.volume == rhs.volume &&
        lhs.rate == rhs.rate &&
        lhs.seek?.time == rhs.seek?.time &&
        lhs.seek?.generation == rhs.seek?.generation
    }
}

/// Public playback lifecycle state (`rune::PlayerState`).
public enum PlayerState: Sendable, Equatable {
    case loading
    case ready
    case playing
    case ended
    case failed(String)

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Media stream classification (`rune::video::Kind`).
public enum MediaKind: String, Sendable, Equatable {
    case video
    case audio
}

/// Discovered stream metadata (`rune::video::Meta`).
public struct VideoMeta: Sendable, Equatable {
    public var kind: MediaKind
    public var duration: Double?
    public var size: (UInt32, UInt32)?
    public var hasSound: Bool
    public var frameDuration: Double

    public init(
        kind: MediaKind = .video,
        duration: Double? = nil,
        size: (UInt32, UInt32)? = nil,
        hasSound: Bool = false,
        frameDuration: Double = 1.0 / 30.0
    ) {
        self.kind = kind
        self.duration = duration
        self.size = size
        self.hasSound = hasSound
        self.frameDuration = frameDuration > 0 && frameDuration.isFinite ? frameDuration : (1.0 / 30.0)
    }

    public var frameCount: Int64 {
        guard let duration, duration > 0, frameDuration.isFinite, frameDuration > 0 else { return 1 }
        let count = (duration / frameDuration).rounded()
        return count < Double(Int64.max) ? max(1, Int64(count)) : .max
    }

    public func frameIndex(at time: Double) -> Int64 {
        let last = frameCount - 1
        guard time > 0, last > 0 else { return 0 }
        let raw = (time / frameDuration + 1e-6).rounded(.down)
        return raw < Double(last) ? Int64(raw) : last
    }

    public func frameTime(for index: Int64) -> Double {
        let t = (Double(index) + 0.5) * frameDuration
        return duration.map { min(t, $0) } ?? t
    }

    public static func == (lhs: VideoMeta, rhs: VideoMeta) -> Bool {
        lhs.kind == rhs.kind &&
        lhs.duration == rhs.duration &&
        lhs.size?.0 == rhs.size?.0 &&
        lhs.size?.1 == rhs.size?.1 &&
        lhs.hasSound == rhs.hasSound &&
        lhs.frameDuration == rhs.frameDuration
    }
}

/// Thread-safe slot holding a single wake callback (`rune::video::WakerSlot`).
/// Replaced callbacks are dropped OUTSIDE the lock to prevent re-entrant lock deadlocks.
public final class WakerSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var waker: (@Sendable () -> Void)?

    public init() {}

    public func set(_ callback: (@Sendable () -> Void)?) {
        var old: (@Sendable () -> Void)?
        lock.lock()
        old = waker
        waker = callback
        lock.unlock()
        withExtendedLifetime(old) {}
        old = nil
    }

    public func wake() {
        let cb: (@Sendable () -> Void)?
        lock.lock()
        cb = waker
        lock.unlock()
        cb?()
    }

    internal var isLockFreeForTest: Bool {
        if lock.try() {
            lock.unlock()
            return true
        }
        return false
    }
}

internal protocol HeadlessVideoDriver: AnyObject {
    func advanceHeadless(to now: Double)
    func resetHeadlessClock()
}

/// A headless runtime on this thread drives the audio clips created here. Video is
/// advanced separately when its surface is drawn, as in upstream `video::headless_frame`.
public enum VideoHeadless {
    private static let playbackKey = "rune.video.headlessPlayback"

    private final class WeakDriver {
        weak var driver: HeadlessVideoDriver?
        init(_ driver: HeadlessVideoDriver) { self.driver = driver }
    }

    private final class Playback {
        var clock: Double = 0
        var clips: [WeakDriver] = []

        func liveDrivers() -> [HeadlessVideoDriver] {
            clips.removeAll { $0.driver == nil }
            return clips.compactMap(\.driver)
        }
    }

    private static var playback: Playback {
        let storage = RuneExecutionContext.locals
        if let existing = storage[playbackKey] as? Playback { return existing }
        let playback = Playback()
        storage[playbackKey] = playback
        return playback
    }

    public static var virtualClock: Double { playback.clock }

    internal static func registerAudio(_ driver: HeadlessVideoDriver) {
        let playback = Self.playback
        playback.clips.removeAll { $0.driver == nil }
        playback.clips.append(WeakDriver(driver))
    }

    public static func reset() {
        let playback = Self.playback
        playback.clock = 0
        for driver in playback.liveDrivers() {
            driver.resetHeadlessClock()
        }
    }

    public static func frame(at now: Double) {
        let playback = Self.playback
        playback.clock = now
        for driver in playback.liveDrivers() {
            driver.advanceHeadless(to: now)
        }
    }
}

/// Pushes a minimal opaque black 2x2 fallback frame onto `surface` so failed video elements still render cleanly.
public func pushVideoPlaceholder(onto surface: NativeSurface) {
    let bytes = Data([
        0, 0, 0, 255, 0, 0, 0, 255,
        0, 0, 0, 255, 0, 0, 0, 255
    ])
    if let frame = try? ByteFrame(width: 2, height: 2, format: .bgra, color: .srgb, planes: [bytes]) {
        try? surface.pushBytes(frame, frameId: 0)
    }
}

/// Signature folding helpers matching `video::fold` / `video::fold_unpulled`.
public enum VideoSignature {
    public static let wakeMinSeconds: Double = 0.020

    public static func fold(_ signature: UInt64, generation: UInt64, surfaceKey: UInt) -> UInt64 {
        var h = signature
        h ^= UInt64(surfaceKey) &* 0x9E37_79B9_7F4A_7C15
        h = (h &<< 13) | (h &>> 51)
        h &+= generation &* 0xBF58_476D_1CE4_E5B9
        return h ^ (h &>> 29)
    }

    public static func foldUnpulled(_ signature: UInt64, surface: NativeSurface) -> UInt64 {
        fold(signature, generation: surface.generation, surfaceKey: surface.key)
    }
}

/// Per-paint video clock and wake schedule, shared by the production and reference painters.
internal struct SurfaceVideoPaint {
    var signature: UInt64 = 0
    var snapshots: [String: VideoSnapshot] = [:]
    var nextWake: Double?
    var active = false

    mutating func snapshot(_ surface: NativeSurface, path: String) {
        if let snapshot = surface.videoSnapshot() { snapshots[path] = snapshot }
    }

    mutating func unpulled(_ surface: NativeSurface) {
        signature = VideoSignature.foldUnpulled(signature, surface: surface)
    }

    mutating func pull(_ surface: NativeSurface, at clock: Double, wallTime: Double, waker: Waker) {
        guard let result = surface.pullVideo(clock: clock, wake: { waker.wake() }) else { return }
        signature = VideoSignature.fold(signature, generation: result.generation, surfaceKey: surface.key)
        guard result.active else { return }
        if let due = result.due {
            let duration = ContinuousClock.now.duration(to: due).components
            let seconds = Double(duration.seconds) + Double(duration.attoseconds) * 1e-18
            if seconds > VideoSignature.wakeMinSeconds {
                let deadline = wallTime + seconds
                nextWake = min(nextWake ?? deadline, deadline)
                return
            }
        }
        active = true
    }
}
