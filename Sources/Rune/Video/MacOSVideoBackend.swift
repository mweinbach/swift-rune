import Foundation
#if os(macOS)
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
#endif

/// Native video/audio player driving a `NativeSurface` (`rune::Player`).
public final class Player: @unchecked Sendable, SurfaceVideoAttachment, CustomStringConvertible, CustomDebugStringConvertible {
    public static let parkedPlayerLimit: Int = 4
    public static let posterMaxDimension: CGFloat = 1920.0
    public static let audioTickSeconds: Double = 0.05

    private final class Inner: @unchecked Sendable, SurfaceVideoAttachment, HeadlessVideoDriver {
        let lock = NSLock()
        let key: UInt64
        weak var surface: NativeSurface?
        var request: MediaRequest
        var meta: VideoMeta
        var orient: Orient = .up
        var state: PlayerState = .loading
        var currentTime: Double = 0.0
        var lastHeadlessClock: Double? = nil
        var nextFrameId: UInt64 = 1
        var seekGen: UInt64 = 0
        var generation: UInt64 = 0
        var lastDecodedTime: Double? = nil
        var waker: WakerSlot = WakerSlot()
        var machine: VideoPhases.Machine
        var turnState: VideoTurnState = VideoTurnState()
        var lastTurnSeekGen: UInt64 = 0
        var hasLoadedMeta: Bool = false
        var didAttemptHeadlessAudioProbe: Bool = false
        var lastNotifiedState: PlayerState? = .loading
        var placeholderPushed: Bool = false

        #if os(macOS)
        var asset: AVURLAsset?
        var avPlayer: AVPlayer?
        var avItem: AVPlayerItem?
        var videoOutput: AVPlayerItemVideoOutput?
        var statusObs: NSKeyValueObservation?
        var endObserver: NSObjectProtocol?
        var audioTimer: DispatchSourceTimer?
        var heldImageGenerator: AVAssetImageGenerator?
        var isParked: Bool = false
        var lastParkedUsedAt: ContinuousClock.Instant = .now
        #endif

        var videoKey: UInt64 { key }

        init(key: UInt64, request: MediaRequest) {
            self.key = key
            self.request = request
            self.meta = VideoMeta(kind: request.kind, duration: nil, size: nil, hasSound: false)
            self.machine = VideoPhases.Machine(
                isAudio: request.kind == .audio,
                playing: request.playing,
                looping: request.looping,
                muted: request.muted,
                volume: request.volume,
                rate: request.rate
            )
            if let seek = request.seek {
                self.currentTime = max(0.0, seek.time)
                self.seekGen = seek.generation
            }
        }

        deinit {
            VideoHeadless.unregister(self)
            #if os(macOS)
            lock.lock()
            let timer = audioTimer
            audioTimer = nil
            statusObs = nil
            let obs = endObserver
            endObserver = nil
            let avp = avPlayer
            avPlayer = nil
            lock.unlock()
            timer?.cancel()
            if let obs { NotificationCenter.default.removeObserver(obs) }
            avp?.pause()
            #endif
        }

        func snapshot() -> VideoSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return VideoSnapshot(
                kind: meta.kind == .audio ? .audio : .video,
                state: state,
                time: currentTime,
                duration: meta.duration,
                size: meta.size,
                rate: request.rate,
                looping: request.looping,
                muted: request.muted
            )
        }

        func pull(clock: Double, wake: (@Sendable () -> Void)?) -> VideoPullResult {
            Player.pullInner(self, surface: surface, clock: clock, wake: wake)
        }

        func advanceHeadless(to now: Double) {
            Player.advanceHeadlessInner(self, surface: surface, to: now)
        }

        func resetHeadlessClock() {
            lock.lock()
            if lastHeadlessClock != nil {
                lastHeadlessClock = 0.0
            }
            lock.unlock()
        }
    }

    private let inner: Inner
    public let surface: NativeSurface

    public var videoKey: UInt64 { inner.key }

    public var description: String {
        inner.lock.lock()
        let kind = inner.meta.kind
        let src = inner.request.source
        let st = inner.state
        let t = inner.currentTime
        let headerNames = inner.request.headers.map(\.name)
        inner.lock.unlock()
        return "Player(kind: \(kind), source: \(src), state: \(st), time: \(t), headers: \(headerNames))"
    }

    public var debugDescription: String {
        description
    }

    // Global LRU registry for parked players so memory stays bounded (`PARKED_PLAYERS = 4`).
    private static let parkedLock = NSLock()
    private nonisolated(unsafe) static var parkedPlayers: [ObjectIdentifier: WeakPlayer] = [:]
    private static let heldScratchThreadKey = "rune.video.parkedHeldScratch"
    private static let keptHookThreadKey = "rune.video.parkedKeptHook"
    private final class HeldScratch {
        var players: [Player] = []
    }
    private final class WeakPlayer {
        weak var player: Player?
        var touchedAt: ContinuousClock.Instant
        init(_ player: Player) {
            self.player = player
            self.touchedAt = .now
        }
    }

    public init(_ request: MediaRequest) {
        let key = UInt64.random(in: 1...UInt64.max)
        self.inner = Inner(key: key, request: request)
        self.surface = NativeSurface(id: key)
        self.inner.surface = self.surface
        self.surface.withVideo(self.inner)
        VideoHeadless.register(self.inner)
        probeAndInitialize()
    }

    public convenience init(
        source: MediaSource,
        playing: Bool = false,
        looping: Bool = false,
        muted: Bool = true,
        volume: Float = 1.0,
        rate: Float = 1.0
    ) {
        self.init(MediaRequest(
            source: source,
            kind: .video,
            playing: playing,
            looping: looping,
            muted: muted,
            volume: volume,
            rate: rate
        ))
    }

    public static func file(
        _ path: String,
        playing: Bool = false,
        looping: Bool = false,
        muted: Bool = true,
        volume: Float = 1.0,
        rate: Float = 1.0
    ) -> Player {
        Player(
            source: .file(URL(fileURLWithPath: path)),
            playing: playing,
            looping: looping,
            muted: muted,
            volume: volume,
            rate: rate
        )
    }

    public static func url(
        _ urlString: String,
        playing: Bool = false,
        looping: Bool = false,
        muted: Bool = true,
        volume: Float = 1.0,
        rate: Float = 1.0
    ) -> Player {
        let url = URL(string: urlString) ?? URL(fileURLWithPath: urlString)
        return Player(
            source: .url(url),
            playing: playing,
            looping: looping,
            muted: muted,
            volume: volume,
            rate: rate
        )
    }

    /// Audio-only player starting unmuted (`Player::audio`).
    public static func audio(
        _ source: MediaSource,
        playing: Bool = false,
        looping: Bool = false,
        muted: Bool = false,
        volume: Float = 1.0,
        rate: Float = 1.0
    ) -> Player {
        Player(MediaRequest(
            source: source,
            kind: .audio,
            playing: playing,
            looping: looping,
            muted: muted,
            volume: volume,
            rate: rate
        ))
    }

    /// Audio-only player parsed from file path or URL (`Player::audio`).
    public static func audio(
        _ pathOrUrl: String,
        playing: Bool = false,
        looping: Bool = false,
        muted: Bool = false,
        volume: Float = 1.0,
        rate: Float = 1.0
    ) -> Player {
        audio(MediaSource.parse(pathOrUrl), playing: playing, looping: looping, muted: muted, volume: volume, rate: rate)
    }

    /// Builds a `MediaRequest` with optional HTTP headers (`Player::request`).
    public static func request(_ urlString: String) -> MediaRequest {
        let url = URL(string: urlString) ?? URL(fileURLWithPath: urlString)
        return MediaRequest(source: .url(url), kind: .video)
    }

    // MARK: - Playback Controls

    public func play() {
        var needsAttach = false
        inner.lock.lock()
        if case .failed = inner.state {
            inner.lock.unlock()
            return
        }
        inner.request.playing = true
        if case .ended = inner.state {
            inner.currentTime = 0.0
            inner.seekGen &+= 1
            inner.request.seek = (0.0, inner.seekGen)
        }
        let playEffects = inner.machine.apply(.play, at: currentClockLocked())
        if !MediaPlaybackGate.isEnabled {
            if case .ready = inner.state {
                inner.state = .playing
            } else if case .ended = inner.state {
                inner.state = .playing
            }
            inner.lastHeadlessClock = VideoHeadless.virtualClock
        } else {
            needsAttach = true
        }
        inner.generation &+= 1
        inner.lock.unlock()

        applyMachineEffects(playEffects)
        if needsAttach {
            scheduleOnMain { [weak self] in
                self?.syncAVPlayer()
            }
        }
        settleStateWaker()
    }

    public func pause() {
        var needsSync = false
        inner.lock.lock()
        if case .failed = inner.state {
            inner.lock.unlock()
            return
        }
        inner.request.playing = false
        let pauseEffects = inner.machine.apply(.pause, at: currentClockLocked())
        if case .playing = inner.state {
            inner.state = .ready
        }
        inner.lastHeadlessClock = nil
        needsSync = MediaPlaybackGate.isEnabled
        inner.generation &+= 1
        inner.lock.unlock()

        applyMachineEffects(pauseEffects)
        if needsSync {
            scheduleOnMain { [weak self] in
                self?.syncAVPlayer()
            }
        }
        settleStateWaker()
    }

    public func toggle() {
        if isPlaying { pause() } else { play() }
    }

    public func seek(to seconds: Double) {
        let clampedInput = max(0.0, seconds)
        var shouldDecodeHeadless = false
        inner.lock.lock()
        if case .failed = inner.state {
            inner.lock.unlock()
            return
        }
        let target: Double
        if let dur = inner.meta.duration {
            target = min(clampedInput, max(0.0, dur))
        } else {
            target = clampedInput
        }
        inner.currentTime = target
        inner.seekGen &+= 1
        inner.request.seek = (target, inner.seekGen)
        let seekEffects = inner.machine.apply(.seek(target), at: currentClockLocked())
        if case .ended = inner.state {
            inner.state = inner.request.playing ? .playing : .ready
        }
        inner.lastDecodedTime = nil
        shouldDecodeHeadless = !MediaPlaybackGate.isEnabled && (inner.meta.kind == .video)
        inner.generation &+= 1
        inner.lock.unlock()

        applyMachineEffects(seekEffects)
        if shouldDecodeHeadless {
            decodeHeadlessFrame(at: target)
        } else if MediaPlaybackGate.isEnabled {
            scheduleOnMain { [weak self] in
                self?.syncAVPlayer(seekTo: target)
            }
        }
        settleStateWaker()
    }

    public func setLooping(_ looping: Bool) {
        var restartNeeded = false
        inner.lock.lock()
        inner.request.looping = looping
        let effects = inner.machine.apply(.setLooping(looping), at: currentClockLocked())
        if case .ended = inner.state, looping {
            inner.state = .playing
            inner.request.playing = true
            inner.currentTime = 0.0
            inner.lastDecodedTime = nil
            if !MediaPlaybackGate.isEnabled {
                inner.lastHeadlessClock = VideoHeadless.virtualClock
            }
            restartNeeded = true
        }
        if effects.contains(where: { if case .restart = $0 { return true }; return false }) {
            restartNeeded = true
        }
        inner.generation &+= 1
        inner.lock.unlock()

        if restartNeeded {
            if MediaPlaybackGate.isEnabled {
                scheduleOnMain { [weak self] in
                    self?.syncAVPlayer(seekTo: 0.0)
                }
            } else if inner.meta.kind == .video {
                decodeHeadlessFrame(at: 0.0)
            }
        }
        inner.waker.wake()
    }

    public func setMuted(_ muted: Bool) {
        inner.lock.lock()
        inner.request.muted = muted
        let muteEffects = inner.machine.apply(.setMuted(muted), at: currentClockLocked())
        inner.generation &+= 1
        inner.lock.unlock()
        applyMachineEffects(muteEffects)
        if MediaPlaybackGate.isEnabled {
            scheduleOnMain { [weak self] in
                self?.syncAVPlayer()
            }
        }
    }

    /// Registers a state-change waker (`Player::set_waker`). Fires immediately once if already loaded or failed.
    public func setWaker(_ callback: (@Sendable () -> Void)?) {
        if callback != nil {
            inner.lock.lock()
            inner.lastNotifiedState = .loading
            inner.lock.unlock()
        }
        inner.waker.set(callback)
        settleStateWaker()
    }

    internal func settleStateWaker() {
        Self.settleStateWakerInner(inner)
    }

    private static func settleStateWakerInner(_ inner: Inner) {
        inner.lock.lock()
        let cur = inner.state
        let changed = (cur != inner.lastNotifiedState)
        if changed {
            inner.lastNotifiedState = cur
        }
        inner.lock.unlock()
        if changed {
            inner.waker.wake()
        }
    }

    public func setVolume(_ volume: Float) {
        guard volume.isFinite else { return }
        let clamped = min(max(0.0, volume), 1.0)
        inner.lock.lock()
        inner.request.volume = clamped
        let effects = inner.machine.apply(.setVolume(clamped), at: currentClockLocked())
        inner.generation &+= 1
        inner.lock.unlock()
        applyMachineEffects(effects)
        if MediaPlaybackGate.isEnabled {
            scheduleOnMain { [weak self] in
                self?.syncAVPlayer()
            }
        }
    }

    public func setRate(_ rate: Float) {
        guard rate.isFinite && rate > 0.0 else { return }
        inner.lock.lock()
        inner.request.rate = rate
        let effects = inner.machine.apply(.setRate(rate), at: currentClockLocked())
        inner.generation &+= 1
        inner.lock.unlock()
        applyMachineEffects(effects)
        if MediaPlaybackGate.isEnabled {
            scheduleOnMain { [weak self] in
                self?.syncAVPlayer()
            }
        }
    }

    /// Preloads the first frame off the main thread in windowed mode (`Player::preload`).
    public func preload() {
        #if os(macOS)
        guard MediaPlaybackGate.isEnabled else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.inner.lock.lock()
            let t = self.inner.currentTime
            let needDecode = self.inner.meta.kind == .video && self.surface.currentFrame() == nil
            self.inner.lock.unlock()
            if needDecode {
                self.decodeHeadlessFrame(at: t)
            }
        }
        #endif
    }

    /// True if this is an audio-only player (`Player::is_audio`).
    public var isAudio: Bool {
        inner.lock.lock()
        defer { inner.lock.unlock() }
        return inner.meta.kind == .audio
    }

    /// Whether the loaded clip has an audio track (`Player::has_sound`), or `nil` while loading.
    public var hasSound: Bool? {
        openHeadlessAudioIfNeeded()
        inner.lock.lock()
        defer { inner.lock.unlock() }
        return inner.hasLoadedMeta ? inner.meta.hasSound : nil
    }

    // MARK: - Inspection

    public var state: PlayerState {
        openHeadlessAudioIfNeeded()
        inner.lock.lock()
        defer { inner.lock.unlock() }
        return inner.state
    }

    public var time: Double {
        openHeadlessAudioIfNeeded()
        inner.lock.lock()
        defer { inner.lock.unlock() }
        return inner.currentTime
    }

    public var duration: Double? {
        openHeadlessAudioIfNeeded()
        inner.lock.lock()
        defer { inner.lock.unlock() }
        return inner.meta.duration
    }

    public var size: (UInt32, UInt32)? {
        inner.lock.lock()
        defer { inner.lock.unlock() }
        return inner.meta.size
    }

    public var orient: Orient {
        inner.lock.lock()
        defer { inner.lock.unlock() }
        return inner.orient
    }

    public var isPlaying: Bool {
        inner.lock.lock()
        defer { inner.lock.unlock() }
        switch inner.state {
        case .failed, .ended:
            return false
        case .playing:
            return true
        case .loading, .ready:
            return inner.request.playing
        }
    }

    public var isLooping: Bool {
        inner.lock.lock()
        defer { inner.lock.unlock() }
        return inner.request.looping
    }

    public var isMuted: Bool {
        inner.lock.lock()
        defer { inner.lock.unlock() }
        return inner.request.muted
    }

    public var volume: Float {
        inner.lock.lock()
        defer { inner.lock.unlock() }
        return inner.request.volume
    }

    public var rate: Float {
        inner.lock.lock()
        defer { inner.lock.unlock() }
        return inner.request.rate
    }

    public var meta: VideoMeta {
        inner.lock.lock()
        defer { inner.lock.unlock() }
        return inner.meta
    }

    public func snapshot() -> VideoSnapshot {
        openHeadlessAudioIfNeeded()
        return inner.snapshot()
    }

    // MARK: - `SurfaceVideoAttachment` & Pull

    public func pull(clock: Double, wake: (@Sendable () -> Void)?) -> VideoPullResult {
        if MediaPlaybackGate.isEnabled {
            if let wake { inner.waker.set(wake) }
            driveLiveOnPull()
            return Self.finalizePull(inner, surface: surface)
        }
        return Self.pullInner(inner, surface: surface, clock: clock, wake: wake)
    }

    private static func pullInner(
        _ inner: Inner,
        surface: NativeSurface?,
        clock: Double,
        wake: (@Sendable () -> Void)?
    ) -> VideoPullResult {
        if let wake {
            inner.waker.set(wake)
        }

        if !MediaPlaybackGate.isEnabled {
            advanceHeadlessInner(inner, surface: surface, to: clock)
        }

        return finalizePull(inner, surface: surface)
    }

    private static func finalizePull(_ inner: Inner, surface: NativeSurface?) -> VideoPullResult {
        var needPlaceholder = false
        inner.lock.lock()
        let active: Bool
        switch inner.state {
        case .playing, .loading:
            active = true
        case .failed:
            active = false
            if !inner.placeholderPushed && (surface?.currentFrame() == nil) {
                inner.placeholderPushed = true
                needPlaceholder = true
            }
        case .ready, .ended:
            active = inner.machine.settle.isWaiting
        }
        let gen = inner.generation &+ (surface?.generation ?? 0)
        inner.lock.unlock()

        if needPlaceholder, let surface {
            pushVideoPlaceholder(onto: surface)
        }
        return VideoPullResult(active: active, generation: gen, due: nil)
    }

    // MARK: - Probing, Format Rules, and Headless Advancement

    /// Extracts lowercase extension strictly from the final path segment (ignoring host, query, fragment, trailing `.`).
    public static func extensionFromLastSegment(of source: MediaSource) -> String? {
        let raw: String
        switch source {
        case .file(let u):
            raw = u.path
        case .url(let u):
            guard let comps = URLComponents(url: u, resolvingAgainstBaseURL: false) else {
                return nil
            }
            // Reject bare host URLs with no path component (`https://host.ogg`)
            if comps.host != nil && (comps.path.isEmpty || comps.path == "/") {
                return nil
            }
            raw = comps.path
        }
        let segment = raw.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        guard !segment.isEmpty, let dot = segment.lastIndex(of: ".") else { return nil }
        let afterDot = segment.index(after: dot)
        guard afterDot < segment.endIndex else { return nil }
        let ext = String(segment[afterDot...]).lowercased()
        return ext.isEmpty ? nil : ext
    }

    /// Rejects unsupported formats matching `video/macos.rs` / `video/foreign.rs` parity rules.
    public static func unsupportedFormatReason(for source: MediaSource, oggAudioEnabled: Bool = false) -> String? {
        if let ext = extensionFromLastSegment(of: source) {
            if ext == "ogv" {
                return "unsupported video container .ogv (Ogg Theora)"
            }
            if (ext == "ogg" || ext == "webm") && !oggAudioEnabled {
                return "unsupported audio container .\(ext) (ogg-audio feature disabled)"
            }
        }
        let url = source.locationURL
        if url.isFileURL,
           FileManager.default.fileExists(atPath: url.path),
           let fh = try? FileHandle(forReadingFrom: url) {
            let head = (try? fh.read(upToCount: 4)) ?? Data()
            try? fh.close()
            if head.count >= 4 {
                let bytes = [UInt8](head)
                // "OggS" or EBML/WebM 0x1A 0x45 0xDF 0xA3
                if (bytes == [0x4F, 0x67, 0x67, 0x53] || bytes == [0x1A, 0x45, 0xDF, 0xA3]) && !oggAudioEnabled {
                    return "unsupported Ogg/WebM stream (ogg-audio feature disabled)"
                }
            }
        }
        return nil
    }

    private func probeAndInitialize() {
        let source: MediaSource
        let headers: [(name: String, value: String)]
        let kind: MediaKind
        inner.lock.lock()
        source = inner.request.source
        headers = inner.request.headers
        kind = inner.request.kind
        inner.lock.unlock()
        let url = source.locationURL

        if let reason = Self.unsupportedFormatReason(for: source) {
            markFailed(reason)
            return
        }

        if source.isFile && url.isFileURL && !FileManager.default.fileExists(atPath: url.path) {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self else { return }
                // Avoid overwriting if already opened/failed via test hooks
                self.inner.lock.lock()
                let stillLoading = !self.inner.hasLoadedMeta && self.inner.machine.failed == nil
                self.inner.lock.unlock()
                if stillLoading {
                    self.markFailed("media file not found: \(url.path)")
                }
            }
            return
        }

        #if os(macOS)
        var assetOptions: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        if !headers.isEmpty {
            var headerDict: [String: String] = [:]
            for h in headers { headerDict[h.name] = h.value }
            assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headerDict
        }
        let asset = AVURLAsset(url: url, options: assetOptions)
        // Probe synchronously for local files so tests & initial layout see exact metadata/errors cleanly.
        if url.isFileURL {
            do {
                try loadAssetMetadataSynchronously(asset, requestedKind: kind)
            } catch {
                markFailed("\(error)")
                return
            }
        } else {
            inner.lock.lock()
            inner.asset = asset
            inner.lock.unlock()
            if MediaPlaybackGate.isEnabled {
                scheduleOnMain { [weak self] in
                    self?.syncAVPlayer()
                }
            }
        }
        #else
        markFailed("video playback is only supported on macOS")
        #endif
    }

    #if os(macOS)
    private func loadAssetMetadataSynchronously(_ asset: AVURLAsset, requestedKind: MediaKind) throws {
        // AVAsset.tracks / duration in macOS SDK: use semaphore only when not synchronously loaded yet
        final class Box: @unchecked Sendable {
            var error: Error?
            var duration: Double?
            var videoTrack: AVAssetTrack?
            var hasAudio: Bool = false
            var naturalSize: CGSize = .zero
            var preferredTransform: CGAffineTransform = .identity
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let isPlayable = try await asset.load(.isPlayable)
                guard isPlayable else {
                    throw NativeSurfaceError.importFailed("asset is not playable")
                }
                let cmDur = try await asset.load(.duration)
                if cmDur.isNumeric && !cmDur.isIndefinite {
                    box.duration = max(0.0, CMTimeGetSeconds(cmDur))
                }
                let vTracks = try await asset.loadTracks(withMediaType: .video)
                let aTracks = try await asset.loadTracks(withMediaType: .audio)
                box.hasAudio = !aTracks.isEmpty
                if requestedKind == .audio && aTracks.isEmpty {
                    throw NativeSurfaceError.importFailed("media has no playable audio track")
                }
                if let vt = vTracks.first {
                    box.videoTrack = vt
                    box.naturalSize = try await vt.load(.naturalSize)
                    box.preferredTransform = try await vt.load(.preferredTransform)
                } else if aTracks.isEmpty {
                    throw NativeSurfaceError.importFailed("media has neither video nor audio tracks")
                }
            } catch {
                box.error = error
            }
            sem.signal()
        }
        sem.wait()
        if let err = box.error {
            throw err
        }

        let orient: Orient
        let uprightSize: (UInt32, UInt32)?
        let kind: MediaKind
        if requestedKind == .video, box.videoTrack != nil {
            kind = .video
            orient = Orient.fromTransform(box.preferredTransform)
            let w = UInt32(max(1, Int(abs(box.naturalSize.width).rounded())))
            let h = UInt32(max(1, Int(abs(box.naturalSize.height).rounded())))
            uprightSize = orient.upright(width: w, height: h)
        } else {
            kind = .audio
            orient = .up
            uprightSize = nil
        }

        let meta = VideoMeta(
            kind: kind,
            duration: box.duration,
            size: uprightSize,
            hasSound: box.hasAudio || kind == .audio
        )
        let (initialTime, shouldDecodePoster) = commitLoadedMetadata(meta, orient: orient, asset: asset)

        if !MediaPlaybackGate.isEnabled {
            if shouldDecodePoster {
                decodeHeadlessFrame(at: initialTime)
            }
        } else {
            scheduleOnMain { [weak self] in
                self?.syncAVPlayer()
            }
        }
    }

    private func commitLoadedMetadata(_ meta: VideoMeta, orient: Orient, asset: AVURLAsset?) -> (Double, Bool) {
        inner.lock.lock()
        inner.asset = asset
        inner.orient = orient
        inner.meta = meta
        inner.hasLoadedMeta = true
        inner.machine.isAudio = (meta.kind == .audio)
        inner.machine.duration = meta.duration
        inner.machine.run = .ready(duration: meta.duration)
        if let seek = inner.request.seek {
            let clamped = meta.duration.map { min(max(0.0, seek.time), max(0.0, $0)) } ?? max(0.0, seek.time)
            inner.currentTime = clamped
            inner.request.seek = (clamped, seek.generation)
            inner.machine.time = clamped
        }
        inner.state = inner.request.playing ? .playing : .ready
        let initialTime = inner.currentTime
        let shouldDecodePoster = (meta.kind == .video)
        inner.generation &+= 1
        inner.lock.unlock()
        settleStateWaker()
        return (initialTime, shouldDecodePoster)
    }
    #endif

    private func openHeadlessAudioIfNeeded() {
        #if os(macOS)
        guard !MediaPlaybackGate.isEnabled else { return }
        inner.lock.lock()
        let shouldProbe = (inner.meta.kind == .audio)
            && !inner.hasLoadedMeta
            && inner.machine.failed == nil
            && !inner.didAttemptHeadlessAudioProbe
            && !inner.request.source.isFile
        let asset = inner.asset
        if shouldProbe {
            inner.didAttemptHeadlessAudioProbe = true
        }
        inner.lock.unlock()
        guard shouldProbe, let asset else { return }
        do {
            try loadAssetMetadataSynchronously(asset, requestedKind: .audio)
        } catch {
            markFailed("\(error)")
        }
        #endif
    }

    // MARK: - Test & State Helpers

    internal var sharedTokenForTest: AnyObject { inner }

    internal func setEndedForTest(at timeSeconds: Double) {
        inner.lock.lock()
        inner.currentTime = timeSeconds
        inner.state = .ended
        inner.request.playing = false
        inner.machine.time = timeSeconds
        inner.machine.ended = true
        inner.machine.playing = false
        inner.generation &+= 1
        inner.lock.unlock()
        settleStateWaker()
    }

    internal func clearSurfaceForPreloadTest() {
        inner.lock.lock()
        inner.lastDecodedTime = nil
        inner.lock.unlock()
        surface.clear()
    }

    internal func preloadPosterDirectForTest() {
        #if os(macOS)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.inner.lock.lock()
            let t = self.inner.currentTime
            let needDecode = self.inner.meta.kind == .video && self.surface.currentFrame() == nil
            self.inner.lock.unlock()
            if needDecode {
                self.decodeHeadlessFrame(at: t)
            }
        }
        #endif
    }

    internal static func parkedLockFreeForTest() -> Bool {
        if parkedLock.try() {
            parkedLock.unlock()
            return true
        }
        return false
    }

    internal static func onKeptForTest(_ hook: (@Sendable () -> Void)?) {
        if let hook {
            Thread.current.threadDictionary[keptHookThreadKey] = hook
        } else {
            Thread.current.threadDictionary.removeObject(forKey: keptHookThreadKey)
        }
    }

    internal static func heldCapacityForTest() -> Int {
        (Thread.current.threadDictionary[heldScratchThreadKey] as? HeldScratch)?.players.capacity ?? 0
    }

    internal static func resetParkedForTest() {
        parkedLock.lock()
        parkedPlayers.removeAll()
        parkedLock.unlock()
        Thread.current.threadDictionary.removeObject(forKey: heldScratchThreadKey)
        Thread.current.threadDictionary.removeObject(forKey: keptHookThreadKey)
    }

    internal func openMetadataForTest(_ meta: VideoMeta) {
        inner.lock.lock()
        inner.meta = meta
        inner.hasLoadedMeta = true
        inner.machine.isAudio = (meta.kind == .audio)
        inner.machine.duration = meta.duration
        inner.machine.run = .ready(duration: meta.duration)
        if let seek = inner.request.seek {
            let clamped = meta.duration.map { min(max(0.0, seek.time), max(0.0, $0)) } ?? max(0.0, seek.time)
            inner.currentTime = clamped
            inner.request.seek = (clamped, seek.generation)
            inner.machine.time = clamped
        }
        if !inner.state.isFailed {
            inner.state = inner.request.playing ? .playing : .ready
        }
        inner.generation &+= 1
        inner.lock.unlock()
        settleStateWaker()
    }

    internal func failForTest(_ message: String) {
        markFailed(message)
    }

    internal func testFramesForTest(at timeSeconds: Double) -> (upright: ByteFrame, raw: ByteFrame, orient: Orient)? {
        #if os(macOS)
        inner.lock.lock()
        let asset = inner.asset
        let orient = inner.orient
        inner.lock.unlock()
        guard let asset else { return nil }
        guard let up = generateCGImageFrame(from: asset, at: timeSeconds, applyTransform: true),
              let raw = generateCGImageFrame(from: asset, at: timeSeconds, applyTransform: false) else {
            return nil
        }
        return (up, raw, orient)
        #else
        return nil
        #endif
    }

    internal static func parkedWithForTest(_ player: Player) -> [Player] {
        #if os(macOS)
        return parkPlayerReturningEvicted(player)
        #else
        return []
        #endif
    }

    internal func advanceHeadless(to now: Double) {
        Self.advanceHeadlessInner(inner, surface: surface, to: now)
    }

    private static func advanceHeadlessInner(_ inner: Inner, surface: NativeSurface?, to now: Double) {
        var decodeAt: Double? = nil
        var shouldSettleWaker = false

        inner.lock.lock()
        if case .failed = inner.state {
            inner.lock.unlock()
            return
        }
        if inner.request.playing {
            if case .ready = inner.state {
                inner.state = .playing
                shouldSettleWaker = true
            }
            let prevClock: Double
            if let prev = inner.lastHeadlessClock {
                prevClock = prev > now ? 0.0 : prev
            } else {
                prevClock = now
            }
            inner.lastHeadlessClock = now
            let dt = max(0.0, now - prevClock)
            var nextTime = inner.currentTime + dt * Double(inner.request.rate)
            if let dur = inner.meta.duration, dur > 0 {
                if nextTime >= dur - 1e-6 {
                    if inner.request.looping {
                        nextTime = nextTime.truncatingRemainder(dividingBy: dur)
                    } else {
                        nextTime = dur
                        inner.currentTime = dur
                        inner.state = .ended
                        inner.request.playing = false
                        inner.machine.ended = true
                        inner.machine.playing = false
                        shouldSettleWaker = true
                    }
                }
            }
            if case .playing = inner.state {
                inner.currentTime = nextTime
            }
            if inner.meta.kind == .video {
                let t = inner.currentTime
                if inner.lastDecodedTime == nil || abs(t - (inner.lastDecodedTime ?? -1)) >= (1.0 / 120.0) {
                    decodeAt = t
                }
            }
        } else {
            inner.lastHeadlessClock = nil
            if inner.meta.kind == .video && (surface?.currentFrame() == nil) && inner.lastDecodedTime == nil {
                decodeAt = inner.currentTime
            }
        }
        inner.lock.unlock()

        if let t = decodeAt, let surface {
            decodeHeadlessFrameInner(inner, surface: surface, at: t)
        }
        if shouldSettleWaker {
            settleStateWakerInner(inner)
        }
    }

    private func decodeHeadlessFrame(at timeSeconds: Double) {
        Self.decodeHeadlessFrameInner(inner, surface: surface, at: timeSeconds)
    }

    private static func decodeHeadlessFrameInner(_ inner: Inner, surface: NativeSurface, at timeSeconds: Double) {
        #if os(macOS)
        inner.lock.lock()
        guard let asset = inner.asset, inner.meta.kind == .video else {
            inner.lock.unlock()
            return
        }
        let orient = inner.orient
        let frameId = inner.nextFrameId
        inner.nextFrameId &+= 1
        inner.lastDecodedTime = timeSeconds
        inner.lock.unlock()

        // Decode real CVPixelBuffer via AVAssetReaderTrackOutput (preserving buffer layout + Orient)
        // at requested timestamp, falling back cleanly to AVAssetImageGenerator if needed.
        if let pb = readCVPixelBuffer(from: asset, at: timeSeconds) {
            try? surface.pushOriented(CoreVideoPixelBuffer.fromRaw(pb), orient: orient, frameId: frameId)
            return
        }
        if let bgraFrame = generateCGImageFrame(from: asset, at: timeSeconds) {
            try? surface.pushBytesOriented(bgraFrame, orient: orient, frameId: frameId)
        }
        #endif
    }

    #if os(macOS)
    private static func readCVPixelBuffer(from asset: AVURLAsset, at timeSeconds: Double) -> CVPixelBuffer? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        // Load tracks safely via blocking helper or cached track
        final class TrackBox: @unchecked Sendable { var track: AVAssetTrack? }
        let tb = TrackBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            tb.track = try? await asset.loadTracks(withMediaType: .video).first
            sem.signal()
        }
        sem.wait()
        guard let track = tb.track else { return nil }

        let target = CMTime(seconds: max(0.0, timeSeconds), preferredTimescale: 600)
        let window = CMTimeRange(start: target, duration: CMTime(seconds: 2.0, preferredTimescale: 600))
        reader.timeRange = window

        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var chosen: CVPixelBuffer?
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if let pb = CMSampleBufferGetImageBuffer(sample) {
                chosen = pb
                if CMTimeGetSeconds(pts) >= timeSeconds - 0.015 {
                    break
                }
            }
        }
        reader.cancelReading()
        return chosen
    }

    private func generateCGImageFrame(from asset: AVURLAsset, at timeSeconds: Double, applyTransform: Bool = false) -> ByteFrame? {
        Self.generateCGImageFrame(from: asset, at: timeSeconds, applyTransform: applyTransform)
    }

    private static func generateCGImageFrame(from asset: AVURLAsset, at timeSeconds: Double, applyTransform: Bool = false) -> ByteFrame? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = applyTransform
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let target = CMTime(seconds: max(0.0, timeSeconds), preferredTimescale: 600)
        guard let cgImg = try? gen.copyCGImage(at: target, actualTime: nil) else {
            return nil
        }
        let w = cgImg.width
        let h = cgImg.height
        guard w > 0 && h > 0 else { return nil }
        var data = Data(count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ptr = raw.baseAddress,
                  let cs = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                    data: ptr,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w * 4,
                    space: cs,
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
                  ) else { return false }
            ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return try? ByteFrame(width: UInt32(w), height: UInt32(h), format: .bgra, color: .srgb, planes: [data])
    }
    #endif

    // MARK: - Live AVPlayer Driver & VideoPhases/VideoTurn Wiring

    private func scheduleOnMain(_ block: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func applyMachineEffects(_ effects: [VideoPhases.Effect]) {
        guard !effects.isEmpty else { return }
        for effect in effects {
            switch effect {
            case .requestPoster(let time, let gen):
                if !MediaPlaybackGate.isEnabled {
                    decodeHeadlessFrame(at: time)
                    inner.lock.lock()
                    if !inner.machine.posterOvertaken(seq: gen) {
                        inner.machine.poster = .ready
                    }
                    inner.lock.unlock()
                }
            case .fail(let msg):
                markFailed(msg)
            case .dropPlayer:
                #if os(macOS)
                scheduleOnMain { [weak self] in self?.dropAVPlayer() }
                #endif
            case .park:
                #if os(macOS)
                _ = Self.parkPlayerReturningEvicted(self)
                #endif
            case .unpark:
                #if os(macOS)
                Self.unparkPlayer(self)
                #endif
            case .ensurePlayer, .setRate, .seek, .restart:
                break
            }
        }
    }

    #if os(macOS)
    private struct PlayerVideoPort: VideoPort {
        weak var owner: Player?
        let player: AVPlayer

        func playerReady() -> Bool {
            player.currentItem?.status == .readyToPlay
        }
        func playerHasFrame() -> Bool {
            owner?.surface.currentFrame() != nil
        }
        func apply(request: MediaRequest) {
            player.isMuted = request.muted
            player.volume = request.volume
        }
        func play() {
            guard let owner else { return }
            owner.inner.lock.lock()
            let r = owner.inner.request.rate
            owner.inner.lock.unlock()
            player.rate = r
        }
        func seek(to time: Double) {
            let cm = CMTime(seconds: max(0.0, time), preferredTimescale: 600)
            player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        func seekAndPlay(to time: Double) {
            guard let owner else { return }
            owner.inner.lock.lock()
            let r = owner.inner.request.rate
            owner.inner.lock.unlock()
            let cm = CMTime(seconds: max(0.0, time), preferredTimescale: 600)
            player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                player.rate = r
            }
        }
        func setRate(_ rate: Float) {
            player.rate = rate
        }
        func pause() {
            player.rate = 0.0
        }
        func requestPoster(at time: Double) {
            owner?.decodeHeadlessFrame(at: time)
        }
        func releasePlayer() {
            owner?.dropAVPlayer()
        }
        func fail(_ message: String) {
            owner?.markFailed(message)
        }
    }

    private func syncAVPlayer(seekTo: Double? = nil) {
        inner.lock.lock()
        if case .failed = inner.state {
            inner.lock.unlock()
            return
        }
        guard let asset = inner.asset else {
            inner.lock.unlock()
            return
        }
        let wantsPlay = inner.request.playing
        let req = inner.request
        let targetSeek = seekTo

        if inner.avPlayer == nil {
            if !wantsPlay && inner.meta.kind == .video {
                // Keep paused video parked using poster image until played.
                let t = targetSeek ?? inner.currentTime
                inner.lock.unlock()
                decodeHeadlessFrame(at: t)
                return
            }
            let item = AVPlayerItem(asset: asset)
            let output: AVPlayerItemVideoOutput?
            if inner.meta.kind == .video {
                output = Self.makeVideoOutput()
                if let out = output { item.add(out) }
            } else {
                output = nil
            }
            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            inner.avPlayer = player
            inner.avItem = item
            inner.videoOutput = output
            inner.machine.hasPlayer = true
            inner.isParked = false

            inner.statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
                if it.status == .failed {
                    self?.markFailed(it.error?.localizedDescription ?? "AVPlayerItem failed")
                } else if it.status == .readyToPlay {
                    self?.inner.waker.wake()
                }
            }
            inner.endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.handleItemEnded()
            }
            ensureAudioTimerIfNeededLocked()
        }

        guard let player = inner.avPlayer else {
            inner.lock.unlock()
            return
        }
        let wasPlaying = inner.turnState.playing
        var requestWithSeek = req
        if let targetSeek {
            inner.seekGen &+= 1
            requestWithSeek.seek = (targetSeek, inner.seekGen)
        }
        let seekRequested = VideoTurn.carry(from: requestWithSeek, into: &inner.turnState, lastSeekGen: &inner.lastTurnSeekGen)
        let turnSnapshot = inner.turnState
        inner.isParked = !req.playing
        inner.lock.unlock()

        let port = PlayerVideoPort(owner: self, player: player)
        port.apply(request: req)
        VideoTurn.reconcile(turn: turnSnapshot, seekRequested: seekRequested, wasPlaying: wasPlaying, port: port)
        if req.playing {
            Self.unparkPlayer(self)
        } else {
            _ = Self.parkPlayerReturningEvicted(self)
        }
    }

    private static func makeVideoOutput() -> AVPlayerItemVideoOutput {
        let emptyProps: [String: Bool] = [:]
        let attrs: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: emptyProps,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        return AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
    }

    private func ensureAudioTimerIfNeededLocked() {
        guard inner.meta.kind == .audio && inner.audioTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.audioTickSeconds, repeating: Self.audioTickSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.driveLiveOnPull()
            self.inner.waker.wake()
        }
        timer.resume()
        inner.audioTimer = timer
    }

    private func handleItemEnded() {
        var shouldSeekZero = false
        inner.lock.lock()
        if inner.request.looping {
            inner.currentTime = 0.0
            shouldSeekZero = true
        } else {
            inner.state = .ended
            inner.request.playing = false
            inner.currentTime = inner.meta.duration ?? inner.currentTime
            inner.machine.ended = true
            inner.machine.playing = false
        }
        inner.generation &+= 1
        let avp = inner.avPlayer
        let r = inner.request.rate
        inner.lock.unlock()

        if shouldSeekZero, let avp {
            avp.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                avp.rate = r
            }
        }
        inner.waker.wake()
    }

    private func driveLiveOnPull() {
        guard Thread.isMainThread else {
            scheduleOnMain { [weak self] in self?.driveLiveOnPull() }
            return
        }
        inner.lock.lock()
        guard let avp = inner.avPlayer else {
            inner.lock.unlock()
            return
        }
        let output = inner.videoOutput
        let orient = inner.orient
        let t = CMTimeGetSeconds(avp.currentTime())
        let itemStatus: VideoPhases.ItemStatus
        switch avp.currentItem?.status {
        case .readyToPlay: itemStatus = .ready(duration: inner.meta.duration)
        case .failed: itemStatus = .failed(avp.currentItem?.error?.localizedDescription ?? "AVPlayerItem failed")
        default: itemStatus = .loading
        }
        let playerRate = avp.rate
        let nowClock = currentClockLocked()
        inner.lock.unlock()

        var frameTime: Double? = nil
        if let output {
            let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            var dispTime = CMTime.invalid
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &dispTime) {
                let ft = CMTimeGetSeconds(dispTime.isValid ? dispTime : itemTime)
                if ft.isFinite && ft >= 0 { frameTime = ft }
                inner.lock.lock()
                let fid = inner.nextFrameId
                inner.nextFrameId &+= 1
                inner.generation &+= 1
                inner.lock.unlock()
                try? surface.pushOriented(CoreVideoPixelBuffer.fromRaw(pb), orient: orient, frameId: fid)
            }
        }

        let item = VideoPhases.Item(
            generation: inner.generation,
            status: itemStatus,
            currentTime: t.isFinite && t >= 0 ? t : 0.0,
            playerRate: playerRate,
            frameTime: frameTime
        )
        inner.lock.lock()
        let (_, effects) = inner.machine.step(item: item, onMain: true, at: nowClock)
        if t.isFinite && t >= 0 {
            inner.currentTime = t
        }
        inner.lock.unlock()

        let port = PlayerVideoPort(owner: self, player: avp)
        for eff in effects {
            switch eff {
            case .setRate(let r): port.setRate(r)
            case .seek(let s, _): port.seek(to: s)
            case .restart(let r): port.seekAndPlay(to: 0.0); _ = r
            case .dropPlayer: port.releasePlayer()
            case .fail(let msg): port.fail(msg)
            case .park: _ = Self.parkPlayerReturningEvicted(self)
            case .unpark: Self.unparkPlayer(self)
            case .ensurePlayer, .requestPoster: break
            }
        }
    }

    @discardableResult
    private static func parkPlayerReturningEvicted(_ player: Player) -> [Player] {
        let heldScratch: HeldScratch
        if let existingScratch = Thread.current.threadDictionary[heldScratchThreadKey] as? HeldScratch {
            heldScratch = existingScratch
        } else {
            let fresh = HeldScratch()
            Thread.current.threadDictionary[heldScratchThreadKey] = fresh
            heldScratch = fresh
        }
        heldScratch.players.removeAll(keepingCapacity: true)

        let keptHook = Thread.current.threadDictionary[keptHookThreadKey] as? (@Sendable () -> Void)
        if keptHook != nil {
            Thread.current.threadDictionary.removeObject(forKey: keptHookThreadKey)
        }

        var evicted: [Player] = []
        parkedLock.lock()
        var deadKeys: [ObjectIdentifier] = []
        var livePaused: [(ObjectIdentifier, Player, ContinuousClock.Instant)] = []
        for (k, box) in parkedPlayers {
            if let p = box.player {
                heldScratch.players.append(p)
                if !p.isPlaying {
                    livePaused.append((k, p, box.touchedAt))
                }
            } else {
                deadKeys.append(k)
            }
        }
        for k in deadKeys {
            parkedPlayers.removeValue(forKey: k)
        }
        keptHook?()

        let playerId = ObjectIdentifier(player)
        let nowInstant = ContinuousClock.Instant.now
        if let existing = parkedPlayers[playerId] {
            existing.touchedAt = nowInstant
            if let idx = livePaused.firstIndex(where: { $0.0 == playerId }) {
                livePaused[idx].2 = nowInstant
            }
        } else {
            parkedPlayers[playerId] = WeakPlayer(player)
            heldScratch.players.append(player)
            if !player.isPlaying {
                livePaused.append((playerId, player, nowInstant))
            }
        }

        if livePaused.count > parkedPlayerLimit {
            livePaused.sort { $0.2 < $1.2 }
            let overflow = livePaused.count - parkedPlayerLimit
            for i in 0..<overflow {
                let (k, p, _) = livePaused[i]
                evicted.append(p)
                parkedPlayers.removeValue(forKey: k)
            }
        }
        parkedLock.unlock()

        // Drop upgraded strong references OUTSIDE `parkedLock` while keeping capacity warm.
        livePaused.removeAll(keepingCapacity: false)
        heldScratch.players.removeAll(keepingCapacity: true)

        for p in evicted {
            p.dropAVPlayer()
        }
        return evicted
    }

    private static func unparkPlayer(_ player: Player) {
        parkedLock.lock()
        parkedPlayers.removeValue(forKey: ObjectIdentifier(player))
        parkedLock.unlock()
    }

    private func dropAVPlayer() {
        inner.lock.lock()
        let avp = inner.avPlayer
        inner.avPlayer = nil
        inner.avItem = nil
        inner.videoOutput = nil
        inner.machine.hasPlayer = false
        inner.statusObs = nil
        let obs = inner.endObserver
        inner.endObserver = nil
        inner.isParked = false
        inner.lock.unlock()

        if let obs { NotificationCenter.default.removeObserver(obs) }
        avp?.pause()
    }
    #else
    private func syncAVPlayer(seekTo: Double? = nil) {}
    private func driveLiveOnPull() {}
    #endif

    private func markFailed(_ message: String) {
        inner.lock.lock()
        inner.state = .failed(message)
        inner.request.playing = false
        inner.machine.failed = message
        inner.generation &+= 1
        inner.lock.unlock()
        settleStateWaker()
    }

    private func currentClockLocked() -> Double {
        MediaPlaybackGate.isEnabled ? ProcessInfo.processInfo.systemUptime : VideoHeadless.virtualClock
    }
}
