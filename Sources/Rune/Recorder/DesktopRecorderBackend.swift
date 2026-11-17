#if canImport(CRuneMedia) && (os(Windows) || os(Linux))
import CRuneMedia
import Dispatch
import Foundation

internal enum RecorderBackend {
    static func permission() -> MicPermission {
        switch rune_mic_permission() {
        case 1: return .granted
        case -1: return .denied
        case -2: return .restricted
        default: return .undetermined
        }
    }

    static func preflight() -> Result<Void, RecorderError> { .success(()) }
    static func requestPermission(_ callback: @escaping @Sendable (MicPermission) -> Void) {
        callback(permission())
    }

    static func start(shared: RecorderShared, attempt: UInt64, url: URL,
                      options: RecorderOptions) -> Result<RecorderBackendSession, RecorderError> {
        .success(startCapture(shared: shared, attempt: attempt, url: url, options: options, synthetic: false))
    }

    static func startCapture(shared: RecorderShared, attempt: UInt64, url: URL,
                             options: RecorderOptions, synthetic: Bool) -> RecorderBackendSession {
        let session = RecorderBackendSession()
        let capture = DesktopMicCapture(shared: shared, attempt: attempt, url: url,
                                        options: options, session: session)
        let thread = Thread { capture.run(synthetic: synthetic) }
        thread.name = "rune-recorder"
        thread.start()
        return session
    }
}

/// The originating thread owns every native operation. Runtime callbacks have a separate serial
/// queue so a waker can call stop synchronously without waiting for its own capture thread.
private final class DesktopMicCapture: @unchecked Sendable {
    private enum End {
        case stop(RecorderBackendSession.CheckedReply<Result<Double, RecorderError>>)
        case cancel(RecorderBackendSession.CheckedReply<Void>)
        case disappeared(String)
        case ownerReleased
    }

    private weak var shared: RecorderShared?
    private let attempt: UInt64
    private let url: URL
    private let options: RecorderOptions
    private let session: RecorderBackendSession
    private let notifications = DispatchQueue(label: "rune.recorder.events")

    init(shared: RecorderShared, attempt: UInt64, url: URL, options: RecorderOptions, session: RecorderBackendSession) {
        self.shared = shared
        self.attempt = attempt
        self.url = url
        self.options = options
        self.session = session
    }

    func run(synthetic: Bool) {
        RecorderBackend.markRecorderThread()
        do {
            let output = try DesktopRecordingFile(url: url, options: options)
            var error = [CChar](repeating: 0, count: 512)
            let size = error.count
            guard let mic = rune_mic_open(options.sampleRate, options.channels, synthetic ? 1 : 0, &error, size) else {
                throw RecorderError.native(error)
            }
            let end: End
            do {
                defer { rune_mic_close(mic) }
                notifications.async { [weak shared, attempt] in shared?.began(attempt: attempt) }
                end = try record(mic, output: output)
            }
            if case .cancel(let reply) = end {
                output.close()
                session.complete(.failure(RecorderError("The recording was cancelled")))
                reply.send(())
                return
            }
            let saved = Result { try output.finish() }.mapError { RecorderError(String(describing: $0)) }
            output.close()
            session.complete(saved)
            switch end {
            case .stop(let reply): reply.send(saved)
            case .disappeared(let reason):
                switch saved {
                case .success(let duration):
                    notifications.async { [weak shared, attempt] in
                        shared?.interrupted(attempt: attempt, reason: reason, duration: duration)
                    }
                case .failure(let error): notifyFailure(error)
                }
            case .ownerReleased, .cancel: break
            }
        } catch {
            let failure = RecorderError(String(describing: error))
            session.complete(.failure(failure))
            notifyFailure(failure)
        }
    }

    private func notifyFailure(_ error: RecorderError) {
        notifications.async { [weak shared, attempt] in shared?.beganFailure(attempt: attempt, error: error.message) }
    }

    private func record(_ mic: OpaquePointer, output: DesktopRecordingFile) throws -> End {
        let capacity = max(1, Int(options.sampleRate) / 50)
        var samples = [Float](repeating: 0, count: capacity * Int(options.channels))
        var error = [CChar](repeating: 0, count: 512)
        let errorSize = error.count
        var meter = RecorderMeter()
        var framesSinceMeter = 0
        var paused = false
        while shared != nil {
            if let command = session.pop(timeout: paused ? 0.25 : 0) {
                switch command {
                case .stop(let reply): return .stop(reply)
                case .cancel(let reply): return .cancel(reply)
                case .pause: paused = true
                case .resume: paused = false
                }
                guard rune_mic_set_paused(mic, paused ? 1 : 0, &error, errorSize) != 0 else {
                    return .disappeared(RecorderError.native(error).message)
                }
            }
            if paused { continue }
            let count = Int(rune_mic_read(mic, &samples, UInt32(capacity), 20, &error, errorSize))
            guard count >= 0 else { return .disappeared(RecorderError.native(error).message) }
            if count == 0 { continue }
            guard count <= capacity else { throw RecorderError("Microphone returned too many frames") }
            try output.append(samples, frames: count)
            meter.pushSamples(rate: options.sampleRate * UInt32(options.channels), count: count * Int(options.channels)) {
                samples[$0]
            }
            framesSinceMeter += count
            if framesSinceMeter >= Int(Double(options.sampleRate) * Recorder.meterInterval) {
                let level = meter.level()
                notifications.async { [weak shared, attempt] in shared?.metered(attempt: attempt, level: level) }
                framesSinceMeter = 0
            }
        }
        return .ownerReleased
    }
}
#endif
