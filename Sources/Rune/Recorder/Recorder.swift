import Foundation

internal struct RecorderOptions: Sendable {
    var format: RecordFormat
    var sampleRate: UInt32
    var channels: UInt16
    var fake: FakeMicrophone?
}

internal final class RecorderShared: @unchecked Sendable {
    private let baseURL: URL
    private let optsLock = NSLock()
    private var opts: RecorderOptions
    private let ctlLock = NSLock()
    private var ctl: RecorderControl
    private let levelLock = NSLock()
    private var packedLevel: UInt64
    private var isFakedFlag: Bool = false
    let live: Live<Float>
    private let wakerLock = NSLock()
    private var waker: Waker?
    private var wakerLastGen: UInt64 = 0

    private static let headlessKey = "rune.headlessRecorders"

    private final class WeakBox {
        weak var value: RecorderShared?
        init(_ value: RecorderShared) { self.value = value }
    }

    init(url: URL, options: RecorderOptions) {
        self.baseURL = url
        self.opts = options
        self.ctl = RecorderControl(url: url)
        self.packedLevel = Recorder.pack(Level.silent)
        self.live = Live<Float>(0.0)
    }

    deinit {
        let phase = ctlLock.withLock {
            let p = ctl.phase
            ctl.phase = .idle
            return p
        }
        let now = ctl.virtualClock ? HeadlessClock.current() : Self.wallNow()
        let source: RecorderSource?
        switch phase {
        case let .recording(_, s, anchorInit):
            var anchor = anchorInit
            ctlLock.withLock {
                RecorderControl.advance(elapsed: &ctl.elapsed, anchor: &anchor, now: now)
            }
            source = s
        case let .paused(_, s):
            source = s
        case let .opening(_, session):
            source = .device(session)
        default:
            source = nil
        }
        guard let source else { return }
        switch source {
        case .fake(let fake):
            _ = fake.write(seconds: ctl.elapsed)
        case .device(let session):
            RecorderBackend.finish(session)
        }
    }

    private static let wallOrigin = ProcessInfo.processInfo.systemUptime
    static func wallNow() -> Double {
        ProcessInfo.processInfo.systemUptime - wallOrigin
    }

    func setFormat(_ format: RecordFormat) { optsLock.withLock { opts.format = format } }
    func setSampleRate(_ hz: UInt32) { optsLock.withLock { opts.sampleRate = min(192_000, max(8_000, hz)) } }
    func setChannels(_ ch: UInt16) { optsLock.withLock { opts.channels = min(2, max(1, ch)) } }
    func setFake(_ mic: FakeMicrophone) { optsLock.withLock { opts.fake = mic } }

    func currentPath() -> URL {
        let fmt = optsLock.withLock { opts.format }
        return Recorder.withFormatExtension(baseURL, format: fmt)
    }

    func setWaker(_ w: Waker) {
        wakerLock.withLock { waker = w }
        settle()
    }

    func setWaker(_ cb: @escaping @Sendable () -> Void) {
        setWaker(Waker(cb))
    }

    private func fakeMic() -> FakeMicrophone? {
        if let own = optsLock.withLock({ opts.fake }) { return own }
        return MediaPlaybackGate.isEnabled ? nil : FakeMicrophone.installed()
    }

    private func resolveFakePermission() -> MicPermission {
        optsLock.withLock {
            if var own = opts.fake {
                let p = own.resolve()
                opts.fake = own
                return p
            }
            return FakeMicrophone.requestInstalled()
        }
    }

    func start() {
        let fake = fakeMic() != nil
        let fmt = fake ? RecordFormat.wav : optsLock.withLock { opts.format }
        let targetURL = Recorder.withFormatExtension(baseURL, format: fmt)
        _ = apply(.start(url: targetURL, virtualClock: fake && !MediaPlaybackGate.isEnabled))
        settle()
    }

    func pause() {
        _ = apply(.pause)
        settle()
    }

    func resume() {
        _ = apply(.resume)
        settle()
    }

    func stop() -> Result<Recording, RecorderError> {
        let reply = apply(.stop) ?? .failure(RecorderError(RecorderControl.notRecordingMessage))
        settle()
        return reply
    }

    func cancel() {
        _ = apply(.cancel)
        settle()
    }

    func status() -> RecorderState {
        follow()
        return ctlLock.withLock { ctl.status() }
    }

    func elapsed() -> Double {
        follow()
        return ctlLock.withLock { ctl.elapsed }
    }

    func level() -> Level {
        let faked = levelLock.withLock { isFakedFlag }
        if faked { follow() }
        let bits = levelLock.withLock { packedLevel }
        return Recorder.unpack(bits)
    }

    func follow() {
        _ = apply(.tick)
        settle()
    }

    func restartClock() {
        _ = apply(.tick)
        ctlLock.withLock { ctl.restartClock() }
    }

    func began(attempt: UInt64) {
        _ = apply(.began(attempt: attempt))
        settle()
    }

    func beganFailure(attempt: UInt64, error: String) {
        _ = apply(.failed(attempt: attempt, error: error))
        settle()
    }

    func interrupted(attempt: UInt64, reason: String, duration: Double) {
        _ = apply(.interrupted(attempt: attempt, reason: reason, duration: duration))
        settle()
    }

    func metered(attempt: UInt64, level: Level) {
        _ = apply(.metered(attempt: attempt, level: level))
    }

    // Test inspection helpers
    internal func unsafeControlMutate(_ body: (inout RecorderControl) -> Void) {
        ctlLock.withLock { body(&ctl) }
    }
    internal func unsafeControlInspect<R>(_ body: (RecorderControl) -> R) -> R {
        ctlLock.withLock { body(ctl) }
    }

    private enum UnlockedJob {
        case ask(attempt: UInt64)
        case openFake(attempt: UInt64, mic: FakeMicrophone, url: URL)
        case stopDevice(attempt: UInt64, session: RecorderBackendSession)
        case cancelDevice(RecorderBackendSession)
        case removeFile(URL)
    }

    @discardableResult
    private func apply(_ initial: RecorderEvent) -> Result<Recording, RecorderError>? {
        var events = [initial]
        var reply: Result<Recording, RecorderError>?
        while !events.isEmpty {
            var unlocked: [UnlockedJob] = []
            ctlLock.withLock {
                while !events.isEmpty {
                    let ev = events.removeFirst()
                    let now = ctl.virtualClock ? HeadlessClock.current() : Self.wallNow()
                    for eff in ctl.step(ev, now: now) {
                        switch eff {
                        case .silence:
                            publish(Level.silent)
                        case .publish(let lvl):
                            publish(lvl)
                        case .ask(let attempt):
                            unlocked.append(.ask(attempt: attempt))
                        case .open(let attempt):
                            if let mic = fakeMic() {
                                unlocked.append(.openFake(attempt: attempt, mic: mic, url: ctl.url))
                            } else {
                                let optSnapshot = optsLock.withLock { opts }
                                let opened = RecorderBackend.start(shared: self, attempt: attempt, url: ctl.url, options: optSnapshot)
                                events.append(.deviceOpened(attempt: attempt, opened: opened))
                            }
                        case .followHeadless:
                            followHeadless()
                        case .pauseDevice:
                            if let s = ctl.deviceSession { RecorderBackend.pause(s) }
                        case .resumeDevice:
                            if let s = ctl.deviceSession { RecorderBackend.resume(s) }
                        case let .stopDevice(attempt, session):
                            unlocked.append(.stopDevice(attempt: attempt, session: session))
                        case .cancelDevice(let session):
                            unlocked.append(.cancelDevice(session))
                        case .removeFile(let u):
                            unlocked.append(.removeFile(u))
                        case .reply(let r):
                            reply = r
                        }
                    }
                }
                let fakedNow = ctl.isFake
                levelLock.withLock { isFakedFlag = fakedNow }
            }
            for job in unlocked {
                if let next = runUnlocked(job) {
                    events.append(next)
                }
            }
        }
        return reply
    }

    private func runUnlocked(_ job: UnlockedJob) -> RecorderEvent? {
        switch job {
        case .ask(let attempt):
            return ask(attempt: attempt)
        case let .openFake(attempt, mic, url):
            let opened: Result<FakeSession, RecorderError> = mic.open().flatMap { input in
                FakeMicrophone.writeWAV(to: url, input: input, frames: 0).map { _ in
                    FakeSession(input: input, url: url, unplug: mic.unplugSeconds)
                }
            }
            return .fakeOpened(attempt: attempt, opened: opened)
        case let .stopDevice(attempt, session):
            return .stopped(attempt: attempt, result: RecorderBackend.stop(session))
        case .cancelDevice(let session):
            RecorderBackend.cancel(session)
            return nil
        case .removeFile(let url):
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private func ask(attempt: UInt64) -> RecorderEvent? {
        let fake = fakeMic()
        if fake == nil, case .failure(let msg) = RecorderBackend.preflight() {
            return .permission(attempt: attempt, granted: .failure(msg))
        }
        let status = fake?.permissionState ?? RecorderBackend.permission()
        let answer: MicPermission
        switch (status, fake) {
        case (.undetermined, .some):
            answer = resolveFakePermission()
        case (.undetermined, .none):
            #if canImport(CRuneMedia) && (os(Windows) || os(Linux))
            // Desktop sound servers enforce access when opening the requested device.
            return .permission(attempt: attempt, granted: .success(()))
            #else
            weak let weakSelf = self
            RecorderBackend.requestPermission { ans in
                guard let strong = weakSelf else { return }
                _ = strong.apply(.permission(attempt: attempt, granted: Self.grantedResult(ans)))
                strong.settle()
            }
            return nil
            #endif
        default:
            answer = status
        }
        return .permission(attempt: attempt, granted: Self.grantedResult(answer))
    }

    private static func grantedResult(_ p: MicPermission) -> Result<Void, RecorderError> {
        switch p {
        case .granted:
            return .success(())
        case .restricted:
            return .failure("microphone access is restricted on this device")
        case .denied, .undetermined:
            #if os(Windows)
            return .failure("microphone access is denied: check Settings > Privacy & security > Microphone")
            #elseif os(Linux)
            return .failure("microphone access is denied by the audio service")
            #else
            return .failure("microphone access is denied: allow it in System Settings > Privacy & Security > Microphone")
            #endif
        }
    }

    private func publish(_ level: Level) {
        let packed = Recorder.pack(level)
        levelLock.withLock { packedLevel = packed }
        live.set(level.meter())
    }

    private func settle() {
        let gen = ctlLock.withLock { ctl.generation }
        let toWake: Waker? = wakerLock.withLock {
            if gen != wakerLastGen, let w = waker {
                wakerLastGen = gen
                return w
            }
            return nil
        }
        toWake?.wake()
    }

    private func followHeadless() {
        var list = (RuneExecutionContext.locals[Self.headlessKey] as? [WeakBox]) ?? []
        list.removeAll { $0.value == nil }
        if !list.contains(where: { $0.value === self }) {
            list.append(WeakBox(self))
        }
        RuneExecutionContext.locals[Self.headlessKey] = list
    }

    static func headlessList() -> [RecorderShared] {
        var list = (RuneExecutionContext.locals[headlessKey] as? [WeakBox]) ?? []
        list.removeAll { $0.value == nil }
        RuneExecutionContext.locals[headlessKey] = list
        return list.compactMap(\.value)
    }

    static func headlessFrame(_ clock: Double) {
        for r in headlessList() {
            r.follow()
        }
    }

    static func headlessReset() {
        for r in headlessList() {
            r.restartClock()
        }
    }
}

/// Records the microphone to a file (`rune::recorder::Recorder`).
///
/// Copies of a `Recorder` share one underlying session; when the last copy is released while
/// recording or paused, it stops and saves the file.
public struct Recorder: Sendable {
    /// How often a recording publishes its level in a window.
    public static let meterInterval: TimeInterval = 0.033

    internal let shared: RecorderShared

    private init(shared: RecorderShared) {
        self.shared = shared
    }

    public static func toFile(_ url: URL) -> Recorder {
        let isWav = url.pathExtension.lowercased() == "wav"
        let fmt: RecordFormat = isWav ? .wav : .aac
        let opts = RecorderOptions(format: fmt, sampleRate: 44_100, channels: 1, fake: nil)
        return Recorder(shared: RecorderShared(url: url, options: opts))
    }

    public static func toFile(_ path: String) -> Recorder {
        toFile(URL(fileURLWithPath: path))
    }

    public func format(_ format: RecordFormat) -> Recorder {
        shared.setFormat(format)
        return self
    }

    public func sampleRate(_ hz: UInt32) -> Recorder {
        shared.setSampleRate(hz)
        return self
    }

    public func channels(_ channels: UInt16) -> Recorder {
        shared.setChannels(channels)
        return self
    }

    public func fake(_ mic: FakeMicrophone) -> Recorder {
        shared.setFake(mic)
        return self
    }

    public func path() -> URL {
        shared.currentPath()
    }

    public static func permission() -> MicPermission {
        MediaPlaybackGate.isEnabled ? RecorderBackend.permission() : FakeMicrophone.installed().permissionState
    }

    public static func requestPermission(_ callback: @escaping @Sendable (MicPermission) -> Void) {
        if MediaPlaybackGate.isEnabled {
            RecorderBackend.requestPermission(callback)
        } else {
            callback(FakeMicrophone.requestInstalled())
        }
    }

    public func start() { shared.start() }
    public func pause() { shared.pause() }
    public func resume() { shared.resume() }
    public func stop() -> Result<Recording, RecorderError> { shared.stop() }
    public func cancel() { shared.cancel() }

    public func state() -> RecorderState { shared.status() }
    public func isRecording() -> Bool { shared.status() == .recording }
    public func elapsed() -> Double { shared.elapsed() }
    public func level() -> Level { shared.level() }
    public func liveLevel() -> Live<Float> { shared.live }

    public func setWaker(_ waker: Waker) { shared.setWaker(waker) }
    public func setWaker(_ callback: @escaping @Sendable () -> Void) { shared.setWaker(callback) }

    public static func headlessFrame(clock: Double) {
        RecorderShared.headlessFrame(clock)
    }

    public static func headlessReset() {
        RecorderShared.headlessReset()
    }

    internal static func withFormatExtension(_ url: URL, format: RecordFormat) -> URL {
        let ext = url.pathExtension.lowercased()
        let keep: [String]
        let want: String
        switch format {
        case .aac:
            keep = ["m4a", "mp4"]
            want = "m4a"
        case .wav:
            keep = ["wav"]
            want = "wav"
        }
        if keep.contains(ext) {
            return url
        }
        if url.pathExtension.isEmpty {
            return URL(fileURLWithPath: url.path + "." + want)
        }
        return url.deletingPathExtension().appendingPathExtension(want)
    }

    internal static func pack(_ level: Level) -> UInt64 {
        (UInt64(level.peakDB().bitPattern) << 32) | UInt64(level.rmsDB().bitPattern)
    }

    internal static func unpack(_ bits: UInt64) -> Level {
        let p = Float(bitPattern: UInt32(truncatingIfNeeded: bits >> 32))
        let r = Float(bitPattern: UInt32(truncatingIfNeeded: bits))
        return Level(peakDB: p, rmsDB: r)
    }
}
