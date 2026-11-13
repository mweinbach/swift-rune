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
}

/// Snapshot of desired playback controls (`rune::video::MediaRequest`).
public struct MediaRequest: Sendable, Equatable {
    public var source: MediaSource
    public var playing: Bool
    public var looping: Bool
    public var muted: Bool
    public var volume: Float
    public var rate: Float
    public var seek: (time: Double, generation: UInt64)?

    public init(
        source: MediaSource,
        playing: Bool = false,
        looping: Bool = false,
        muted: Bool = false,
        volume: Float = 1.0,
        rate: Float = 1.0,
        seek: (time: Double, generation: UInt64)? = nil
    ) {
        self.source = source
        self.playing = playing
        self.looping = looping
        self.muted = muted
        self.volume = volume
        self.rate = rate
        self.seek = seek
    }

    public static func == (lhs: MediaRequest, rhs: MediaRequest) -> Bool {
        lhs.source == rhs.source &&
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

    public init(kind: MediaKind = .video, duration: Double? = nil, size: (UInt32, UInt32)? = nil) {
        self.kind = kind
        self.duration = duration
        self.size = size
    }

    public static func == (lhs: VideoMeta, rhs: VideoMeta) -> Bool {
        lhs.kind == rhs.kind &&
        lhs.duration == rhs.duration &&
        lhs.size?.0 == rhs.size?.0 &&
        lhs.size?.1 == rhs.size?.1
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
}

/// Virtual clock + frame hook shared by headless video tests (`video::headless_reset` / `headless_frame`).
public enum VideoHeadless {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var clock: Double = 0.0
    private nonisolated(unsafe) static var registered: [ObjectIdentifier: WeakBox] = [:]

    private final class WeakBox {
        weak var player: Player?
        init(_ player: Player) { self.player = player }
    }

    public static var virtualClock: Double {
        lock.lock()
        defer { lock.unlock() }
        return clock
    }

    internal static func register(_ player: Player) {
        lock.lock()
        registered[ObjectIdentifier(player)] = WeakBox(player)
        lock.unlock()
    }

    internal static func unregister(_ player: Player) {
        lock.lock()
        registered.removeValue(forKey: ObjectIdentifier(player))
        lock.unlock()
    }

    public static func reset() {
        lock.lock()
        clock = 0.0
        registered = registered.filter { $0.value.player != nil }
        lock.unlock()
    }

    public static func frame(at now: Double) {
        let players: [Player]
        lock.lock()
        clock = now
        registered = registered.filter { $0.value.player != nil }
        players = registered.values.compactMap { $0.player }
        lock.unlock()

        for p in players {
            p.advanceHeadless(to: now)
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
