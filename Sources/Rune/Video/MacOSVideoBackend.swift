import Foundation
#if os(macOS)
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
#endif

/// Native video/audio player driving a `NativeSurface` (`rune::Player`).
public final class Player: @unchecked Sendable, SurfaceVideoAttachment {
    public static let parkedPlayerLimit: Int = 4
    public static let posterMaxDimension: CGFloat = 1920.0
    public static let audioTickSeconds: Double = 0.05

    private final class Inner: @unchecked Sendable {
        let lock = NSLock()
        let key: UInt64
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

        init(key: UInt64, request: MediaRequest) {
            self.key = key
            self.request = request
            self.meta = VideoMeta(kind: .video, duration: nil, size: nil)
            self.machine = VideoPhases.Machine(
                isAudio: false,
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
    }

    private let inner: Inner
    public let surface: NativeSurface

    public var videoKey: UInt64 { inner.key }

    // Global LRU registry for parked players so memory stays bounded (`PARKED_PLAYERS = 4`).
    private static let parkedLock = NSLock()
    private nonisolated(unsafe) static var parkedPlayers: [ObjectIdentifier: WeakPlayer] = [:]
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
        self.surface.withVideo(self)
        VideoHeadless.register(self)
        probeAndInitialize()
    }

    public convenience init(
        source: MediaSource,
        playing: Bool = false,
        looping: Bool = false,
        muted: Bool = false,
        volume: Float = 1.0,
        rate: Float = 1.0
    ) {
        self.init(MediaRequest(
            source: source,
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
        muted: Bool = false,
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
        muted: Bool = false,
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

    deinit {
        VideoHeadless.unregister(self)
        #if os(macOS)
        inner.lock.lock()
        let timer = inner.audioTimer
        inner.audioTimer = nil
        inner.statusObs = nil
        let obs = inner.endObserver
        inner.endObserver = nil
        let avp = inner.avPlayer
        inner.avPlayer = nil
        inner.lock.unlock()
        timer?.cancel()
        if let obs { NotificationCenter.default.removeObserver(obs) }
        avp?.pause()
        #endif
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
        _ = inner.machine.apply(.play, at: currentClockLocked())
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

        if needsAttach {
            scheduleOnMain { [weak self] in
                self?.syncAVPlayer()
            }
        }
        inner.waker.wake()
    }

    public func pause() {
        var needsSync = false
        inner.lock.lock()
        if case .failed = inner.state {
            inner.lock.unlock()
            return
        }
        inner.request.playing = false
        _ = inner.machine.apply(.pause, at: currentClockLocked())
        if case .playing = inner.state {
            inner.state = .ready
        }
        inner.lastHeadlessClock = nil
        needsSync = MediaPlaybackGate.isEnabled
        inner.generation &+= 1
        inner.lock.unlock()

        if needsSync {
            scheduleOnMain { [weak self] in
                self?.syncAVPlayer()
            }
        }
        inner.waker.wake()
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
        _ = inner.machine.apply(.seek(target), at: currentClockLocked())
        if case .ended = inner.state {
            inner.state = inner.request.playing ? .playing : .ready
        }
        inner.lastDecodedTime = nil
        shouldDecodeHeadless = !MediaPlaybackGate.isEnabled && (inner.meta.kind == .video)
        inner.generation &+= 1
        inner.lock.unlock()

        if shouldDecodeHeadless {
            decodeHeadlessFrame(at: target)
        } else if MediaPlaybackGate.isEnabled {
            scheduleOnMain { [weak self] in
                self?.syncAVPlayer(seekTo: target)
            }
        }
        inner.waker.wake()
    }

    public func setLooping(_ looping: Bool) {
        var restartNeeded = false
        inner.lock.lock()
        inner.request.looping = looping
        let effects = inner.machine.apply(.setLooping(looping), at: currentClockLocked())
        if case .ended = inner.state, looping {
            inner.state = .playing
            inner.currentTime = 0.0
            inner.lastDecodedTime = nil
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
        _ = inner.machine.apply(.setMuted(muted), at: currentClockLocked())
        inner.generation &+= 1
        inner.lock.unlock()
        if MediaPlaybackGate.isEnabled {
            scheduleOnMain { [weak self] in
                self?.syncAVPlayer()
            }
        }
        inner.waker.wake()
    }

    public func setVolume(_ volume: Float) {
        let clamped = min(max(0.0, volume), 1.0)
        inner.lock.lock()
        inner.request.volume = clamped
        _ = inner.machine.apply(.setVolume(clamped), at: currentClockLocked())
        inner.generation &+= 1
        inner.lock.unlock()
        if MediaPlaybackGate.isEnabled {
            scheduleOnMain { [weak self] in
                self?.syncAVPlayer()
            }
        }
        inner.waker.wake()
    }

    public func setRate(_ rate: Float) {
        let clamped = max(0.0, rate)
        inner.lock.lock()
        inner.request.rate = clamped
        _ = inner.machine.apply(.setRate(clamped), at: currentClockLocked())
        inner.generation &+= 1
        inner.lock.unlock()
        if MediaPlaybackGate.isEnabled {
            scheduleOnMain { [weak self] in
                self?.syncAVPlayer()
            }
        }
        inner.waker.wake()
    }

    // MARK: - Inspection

    public var state: PlayerState {
        inner.lock.lock()
        defer { inner.lock.unlock() }
        return inner.state
    }

    public var time: Double {
        inner.lock.lock()
        defer { inner.lock.unlock() }
        return inner.currentTime
    }

    public var duration: Double? {
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
        if case .playing = state { return true }
        return false
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
        inner.lock.lock()
        defer { inner.lock.unlock() }
        return VideoSnapshot(
            kind: inner.meta.kind == .audio ? .audio : .video,
            state: inner.state,
            time: inner.currentTime,
            duration: inner.meta.duration,
            size: inner.meta.size,
            rate: inner.request.rate,
            looping: inner.request.looping,
            muted: inner.request.muted
        )
    }

    // MARK: - `SurfaceVideoAttachment` & Pull

    public func pull(clock: Double, wake: (@Sendable () -> Void)?) -> VideoPullResult {
        inner.waker.set(wake)

        if MediaPlaybackGate.isEnabled {
            driveLiveOnPull()
        } else {
            advanceHeadless(to: clock)
        }

        var needPlaceholder = false
        inner.lock.lock()
        let active: Bool
        switch inner.state {
        case .playing, .loading:
            active = true
        case .failed:
            active = false
            if !inner.placeholderPushed && surface.currentFrame() == nil {
                inner.placeholderPushed = true
                needPlaceholder = true
            }
        case .ready, .ended:
            active = inner.machine.settle.isWaiting
        }
        let gen = inner.generation &+ surface.generation
        inner.lock.unlock()

        if needPlaceholder {
            pushVideoPlaceholder(onto: surface)
        }
        return VideoPullResult(active: active, generation: gen, due: nil)
    }

    // MARK: - Probing, Format Rules, and Headless Advancement

    /// Rejects unsupported formats matching `video/macos.rs` / `video/foreign.rs` parity rules.
    public static func unsupportedFormatReason(for url: URL, oggAudioEnabled: Bool = false) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "ogv" {
            return "unsupported video container .ogv (Ogg Theora)"
        }
        if (ext == "ogg" || ext == "webm") && !oggAudioEnabled {
            return "unsupported audio container .\(ext) (ogg-audio feature disabled)"
        }
        if FileManager.default.fileExists(atPath: url.path),
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
        let url: URL
        inner.lock.lock()
        url = inner.request.source.locationURL
        inner.lock.unlock()

        if url.isFileURL && !FileManager.default.fileExists(atPath: url.path) {
            markFailed("media file not found: \(url.path)")
            return
        }

        if let reason = Self.unsupportedFormatReason(for: url) {
            markFailed(reason)
            return
        }

        #if os(macOS)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        // Probe synchronously for local files so tests & initial layout see exact metadata/errors cleanly.
        if url.isFileURL {
            do {
                try loadAssetMetadataSynchronously(asset)
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
    private func loadAssetMetadataSynchronously(_ asset: AVURLAsset) throws {
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
        if box.videoTrack != nil {
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

        let initialTime: Double
        let shouldDecodePoster: Bool
        inner.lock.lock()
        inner.asset = asset
        inner.orient = orient
        inner.meta = VideoMeta(kind: kind, duration: box.duration, size: uprightSize)
        inner.machine.isAudio = (kind == .audio)
        inner.machine.duration = box.duration
        inner.state = inner.request.playing ? .playing : .ready
        if let seek = inner.request.seek {
            inner.currentTime = box.duration.map { min(max(0.0, seek.time), $0) } ?? max(0.0, seek.time)
        }
        initialTime = inner.currentTime
        shouldDecodePoster = (kind == .video)
        inner.generation &+= 1
        inner.lock.unlock()

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
    #endif

    internal func advanceHeadless(to now: Double) {
        var decodeAt: Double? = nil
        var shouldWake = false

        inner.lock.lock()
        if case .failed = inner.state {
            inner.lock.unlock()
            return
        }
        if inner.request.playing {
            if case .ready = inner.state {
                inner.state = .playing
            }
            let prevClock = inner.lastHeadlessClock ?? now
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
                        shouldWake = true
                    }
                }
            }
            if case .playing = inner.state {
                inner.currentTime = nextTime
                shouldWake = true
            }
            if inner.meta.kind == .video {
                let t = inner.currentTime
                if inner.lastDecodedTime == nil || abs(t - (inner.lastDecodedTime ?? -1)) >= (1.0 / 120.0) {
                    decodeAt = t
                }
            }
        } else {
            inner.lastHeadlessClock = nil
            if inner.meta.kind == .video && surface.currentFrame() == nil && inner.lastDecodedTime == nil {
                decodeAt = inner.currentTime
            }
        }
        inner.lock.unlock()

        if let t = decodeAt {
            decodeHeadlessFrame(at: t)
        }
        if shouldWake {
            inner.waker.wake()
        }
    }

    private func decodeHeadlessFrame(at timeSeconds: Double) {
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
    private func readCVPixelBuffer(from asset: AVURLAsset, at timeSeconds: Double) -> CVPixelBuffer? {
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

    private func generateCGImageFrame(from asset: AVURLAsset, at timeSeconds: Double) -> ByteFrame? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = false
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

    // MARK: - Live AVPlayer Driver (Windowed Mode)

    private func scheduleOnMain(_ block: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
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
                inner.lock.unlock()
                let t = targetSeek ?? inner.currentTime
                decodeHeadlessFrame(at: t)
                return
            }
            let item = AVPlayerItem(asset: asset)
            let output: AVPlayerItemVideoOutput?
            if inner.meta.kind == .video {
                let attrs: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferIOSurfacePropertiesKey as String: NSDictionary(),
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
                let out = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
                item.add(out)
                output = out
            } else {
                output = nil
            }
            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            inner.avPlayer = player
            inner.avItem = item
            inner.videoOutput = output
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
        player.isMuted = req.muted
        player.volume = req.volume
        let targetRate: Float = req.playing ? req.rate : 0.0
        if req.playing {
            Self.unparkPlayer(self)
            inner.isParked = false
        } else {
            inner.isParked = true
            Self.parkPlayer(self)
        }
        inner.lock.unlock()

        if let s = targetSeek {
            let cm = CMTime(seconds: max(0.0, s), preferredTimescale: 600)
            player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.rate = targetRate
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
        if t.isFinite && t >= 0 {
            inner.currentTime = t
        }
        if inner.request.playing && avp.rate == 0 && avp.currentItem?.status == .readyToPlay {
            if let dur = inner.meta.duration, inner.currentTime < dur - 0.02 {
                avp.rate = inner.request.rate
            }
        }
        inner.lock.unlock()

        if let output {
            let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            var dispTime = CMTime.invalid
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &dispTime) {
                inner.lock.lock()
                let fid = inner.nextFrameId
                inner.nextFrameId &+= 1
                inner.generation &+= 1
                inner.lock.unlock()
                try? surface.pushOriented(CoreVideoPixelBuffer.fromRaw(pb), orient: orient, frameId: fid)
            }
        }
    }

    private static func parkPlayer(_ player: Player) {
        var evicted: [Player] = []
        parkedLock.lock()
        parkedPlayers = parkedPlayers.filter { $0.value.player != nil }
        parkedPlayers[ObjectIdentifier(player)] = WeakPlayer(player)
        if parkedPlayers.count > parkedPlayerLimit {
            let sorted = parkedPlayers.sorted { $0.value.touchedAt < $1.value.touchedAt }
            let overflow = sorted.count - parkedPlayerLimit
            for (k, box) in sorted.prefix(overflow) {
                if let p = box.player { evicted.append(p) }
                parkedPlayers.removeValue(forKey: k)
            }
        }
        parkedLock.unlock()

        for p in evicted {
            p.dropAVPlayer()
        }
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
        inner.statusObs = nil
        let obs = inner.endObserver
        inner.endObserver = nil
        inner.isParked = false
        inner.lock.unlock()

        if let obs { NotificationCenter.default.removeObserver(obs) }
        avp?.pause()
    }
    #endif

    private func markFailed(_ message: String) {
        inner.lock.lock()
        inner.state = .failed(message)
        inner.request.playing = false
        inner.machine.failed = message
        inner.generation &+= 1
        inner.lock.unlock()
        inner.waker.wake()
    }

    private func currentClockLocked() -> Double {
        MediaPlaybackGate.isEnabled ? ProcessInfo.processInfo.systemUptime : VideoHeadless.virtualClock
    }
}
