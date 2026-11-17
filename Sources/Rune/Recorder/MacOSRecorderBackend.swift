import Foundation

#if os(macOS) && canImport(AVFoundation) && canImport(CoreAudio)
@preconcurrency import AVFoundation
import CoreAudio

internal enum RecorderBackend {
    static let deviceCheckTicks: UInt32 = 15

    static func defaultInputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        return (status == noErr && device != 0) ? device : nil
    }

    static func permission() -> MicPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    static func preflight() -> Result<Void, RecorderError> {
        let bundle = Bundle.main
        if bundle.bundlePath.hasSuffix(".app") {
            if bundle.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") == nil {
                return .failure("the app's Info.plist has no NSMicrophoneUsageDescription, so macOS won't let it record")
            }
        }
        return .success(())
    }

    static func requestPermission(_ callback: @escaping @Sendable (MicPermission) -> Void) {
        if case .failure = preflight() {
            callback(.denied)
            return
        }
        let current = permission()
        if current != .undetermined {
            callback(current)
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            callback(granted ? .granted : .denied)
        }
    }

    static func makeRecorder(url: URL, options: RecorderOptions) -> Result<AVAudioRecorder, RecorderError> {
        let absURL = url.standardizedFileURL
        var settings: [String: Any] = [
            AVSampleRateKey: Double(options.sampleRate),
            AVNumberOfChannelsKey: Int(options.channels),
        ]
        switch options.format {
        case .aac:
            settings[AVFormatIDKey] = Int(kAudioFormatMPEG4AAC)
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue
        case .wav:
            settings[AVFormatIDKey] = Int(kAudioFormatLinearPCM)
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        do {
            let rec = try AVAudioRecorder(url: absURL, settings: settings)
            return .success(rec)
        } catch {
            return .failure(RecorderError("couldn't record to \(absURL.path): \(error.localizedDescription)"))
        }
    }

    static func start(
        shared: RecorderShared,
        attempt: UInt64,
        url: URL,
        options: RecorderOptions
    ) -> Result<RecorderBackendSession, RecorderError> {
        let session = RecorderBackendSession()
        let owner: @Sendable () -> RecorderShared? = { [weak shared] in shared }
        let thread = Thread {
            run(owner: owner, attempt: attempt, url: url, options: options, session: session)
        }
        thread.name = "rune-recorder"
        thread.start()
        return .success(session)
    }

    private static func open(url: URL, options: RecorderOptions) -> Result<(AVAudioRecorder, AudioObjectID?), RecorderError> {
        guard let device = defaultInputDevice() else {
            return .failure("no microphone is connected")
        }
        switch makeRecorder(url: url, options: options) {
        case .failure(let err):
            return .failure(err)
        case .success(let recorder):
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord() else {
                return .failure(RecorderError("couldn't create \(url.path)"))
            }
            guard recorder.record() else {
                recorder.deleteRecording()
                return .failure("couldn't start recording from the microphone")
            }
            return .success((recorder, device))
        }
    }

    private static func run(
        owner: () -> RecorderShared?,
        attempt: UInt64,
        url: URL,
        options: RecorderOptions,
        session: RecorderBackendSession
    ) {
        markRecorderThread()
        let opened: Result<(AVAudioRecorder, AudioObjectID?), RecorderError> = autoreleasepool {
            open(url: url, options: options)
        }
        let recorder: AVAudioRecorder
        let startDevice: AudioObjectID?
        switch opened {
        case .success(let pair):
            recorder = pair.0
            startDevice = pair.1
        case .failure(let err):
            session.complete(.failure(err))
            owner()?.beganFailure(attempt: attempt, error: err.message)
            return
        }

        owner()?.began(attempt: attempt)
        var meter = RecorderMeter()
        var last = ProcessInfo.processInfo.systemUptime
        var ticks: UInt32 = 0
        var paused = false
        var recorded: Double = 0.0

        while true {
            let cmd = session.pop(timeout: Recorder.meterInterval)
            let done: Bool = autoreleasepool {
                if let cmd {
                    switch cmd {
                    case .pause:
                        recorded = max(recorded, recorder.currentTime)
                        recorder.pause()
                        paused = true
                        return false
                    case .resume:
                        _ = recorder.record()
                        paused = false
                        last = ProcessInfo.processInfo.systemUptime
                        return false
                    case .stop(let reply):
                        recorded = max(recorded, recorder.currentTime)
                        recorder.stop()
                        session.complete(.success(recorded))
                        reply.send(.success(recorded))
                        return true
                    case .cancel(let reply):
                        recorder.stop()
                        recorder.deleteRecording()
                        session.complete(.failure(RecorderError("The recording was cancelled")))
                        reply.send(())
                        return true
                    }
                }
                guard let shared = owner() else {
                    recorded = max(recorded, recorder.currentTime)
                    recorder.stop()
                    session.complete(.success(recorded))
                    return true
                }
                if paused { return false }
                recorder.updateMeters()
                let peak = recorder.peakPower(forChannel: 0)
                let avg = recorder.averagePower(forChannel: 0)
                let isRec = recorder.isRecording
                recorded = max(recorded, recorder.currentTime)
                let now = ProcessInfo.processInfo.systemUptime
                meter.pushDB(peakDB: peak, rmsDB: avg, dt: now - last)
                last = now
                shared.metered(attempt: attempt, level: meter.level())
                ticks &+= 1
                let lostReason: String?
                if !isRec {
                    lostReason = "recording stopped: the input device went away"
                } else if ticks % deviceCheckTicks == 0 && defaultInputDevice() != startDevice {
                    lostReason = "the input device changed"
                } else {
                    lostReason = nil
                }
                if let reason = lostReason {
                    recorder.stop()
                    session.complete(.success(recorded))
                    shared.interrupted(attempt: attempt, reason: reason, duration: recorded)
                    return true
                }
                return false
            }
            if done { break }
        }
    }
}

#elseif !canImport(CRuneMedia) || (!os(Windows) && !os(Linux))

internal final class RecorderBackendSession: @unchecked Sendable {
    enum Command {
        case pause
        case resume
        case stop
        case cancel
    }
    func pop(timeout: TimeInterval) -> Command? { nil }
    func tryPopAll() -> [Command] { [] }
}

internal enum RecorderBackend {
    static func permission() -> MicPermission { .restricted }
    static func preflight() -> Result<Void, RecorderError> { .success(()) }
    static func requestPermission(_ callback: @escaping @Sendable (MicPermission) -> Void) {
        callback(.restricted)
    }
    static func start(shared: RecorderShared, attempt: UInt64, url: URL, options: RecorderOptions) -> Result<RecorderBackendSession, RecorderError> {
        .failure("recording is unsupported on this platform")
    }
    static func pause(_ session: RecorderBackendSession) {}
    static func resume(_ session: RecorderBackendSession) {}
    static func stop(_ session: RecorderBackendSession) -> Result<Double, RecorderError> {
        .failure("recording is unsupported on this platform")
    }
    static func finish(_ session: RecorderBackendSession) {}
    static func cancel(_ session: RecorderBackendSession) {}
    static func markRecorderThread() {}
    static func idleSession() -> RecorderBackendSession { RecorderBackendSession() }
}

#endif
