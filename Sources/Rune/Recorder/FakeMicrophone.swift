import Foundation

/// Global playback gate (`true` when a real window event loop is active; headless runs keep `false`).
public enum MediaPlaybackGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _enabled: Bool = false

    public static var isEnabled: Bool {
        lock.withLock { _enabled }
    }

    public static func enable() {
        lock.withLock { _enabled = true }
        #if canImport(AVFoundation) && !os(watchOS)
        Player.startPreexistingApplePlayers()
        #elseif canImport(CRuneMedia)
        Player.startPreexistingDesktopPlayers()
        #endif
    }

    public static func setEnabled(_ enabled: Bool) {
        if enabled { enable() }
        else { lock.withLock { _enabled = false } }
    }
}

/// Thread-local virtual clock set by `Runtime` during headless frames.
public enum HeadlessClock {
    private static let dictKey = "rune.headlessClockSeconds"

    public static func set(_ seconds: Double) {
        RuneExecutionContext.locals[dictKey] = seconds
    }

    public static func clear() {
        RuneExecutionContext.locals.removeObject(forKey: dictKey)
    }

    public static func current() -> Double? {
        RuneExecutionContext.locals[dictKey] as? Double
    }
}

/// The file format a recorder writes.
public enum RecordFormat: String, Sendable, Equatable, Codable {
    /// AAC in an MPEG-4 container (`.m4a`), high quality.
    case aac
    /// 16-bit PCM WAV.
    case wav
}

/// Where a recorder is.
public enum RecorderState: Sendable, Equatable {
    /// Not started, or cancelled.
    case idle
    /// Asking for permission or opening the input.
    case starting
    case recording
    case paused
    /// Stopped with the file written.
    case stopped
    /// The input went away mid-recording; what was captured is saved.
    case interrupted(String)
    /// Couldn't record: no permission, no input, unwritable path, or unsupported platform.
    case failed(String)
}

/// Microphone access, as the system reports it.
public enum MicPermission: String, Sendable, Equatable {
    case granted
    case denied
    case undetermined
    case restricted
}

/// A finished recording.
public struct Recording: Sendable, Equatable {
    public var url: URL
    public var path: String { url.path }
    /// Seconds of audio, pauses excluded.
    public var duration: Double

    public init(url: URL, duration: Double) {
        self.url = url
        self.duration = duration
    }
}

public struct RecorderError: Error, Sendable, Equatable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public init(stringLiteral value: String) { self.message = value }
    public var description: String { message }
}

public enum WAVParseError: Error, Sendable, Equatable, CustomStringConvertible {
    case message(String)
    public var description: String {
        switch self { case .message(let m): return m }
    }
}

/// Fake microphone input for headless runs and tests (`rune::recorder::FakeMicrophone`).
public struct FakeMicrophone: Sendable, Equatable {
    public enum Signal: Sendable, Equatable {
        case swell
        case silence
        case sine(hz: Float, amplitude: Float)
        case samples(rate: UInt32, samples: [Float])
        case wav(URL)
    }

    public var signal: Signal
    public var permissionState: MicPermission
    public var answerState: MicPermission
    public var unplugSeconds: Double?

    // Legacy compatibility stored/computed helpers
    public var sampleRate: Int {
        switch signal {
        case let .samples(rate, _): return Int(rate)
        default: return 48_000
        }
    }
    public var frequencyHz: Float {
        switch signal {
        case let .sine(hz, _): return hz
        case .swell: return 220.0
        default: return 0.0
        }
    }
    public var amplitude: Float {
        switch signal {
        case let .sine(_, amp): return amp
        case .swell: return 0.3
        default: return 0.0
        }
    }

    public static let defaultRate: UInt32 = 48_000
    private static let threadLocalKey = "rune.installedFakeMicrophone"

    public init(
        signal: Signal = .swell,
        permission: MicPermission = .granted,
        answer: MicPermission = .granted,
        unplugSeconds: Double? = nil
    ) {
        self.signal = signal
        self.permissionState = permission
        self.answerState = answer
        self.unplugSeconds = unplugSeconds
    }

    /// Backwards-compatible convenience initializer generating a sine wave at `sampleRate`.
    public init(sampleRate: Int = 48_000, frequencyHz: Double = 440.0, amplitude: Float = 0.25) {
        let rate = UInt32(max(8_000, sampleRate))
        if rate == Self.defaultRate {
            self.init(signal: .sine(hz: Float(frequencyHz), amplitude: amplitude))
        } else {
            // Generate 1 second of looping samples at the requested sampleRate.
            let count = Int(rate)
            let tau = Double.pi * 2.0
            let amp = Double(amplitude.clamped(to: 0...1))
            let hz = frequencyHz
            let buf: [Float] = (0..<count).map { i in
                let t = Double(i) / Double(rate)
                return Float(amp * sin(tau * hz * t))
            }
            self.init(signal: .samples(rate: rate, samples: buf))
        }
    }

    /// A 220 Hz tone whose amplitude swells from silence to 0.3 and back every 1.6 s.
    public static var `default`: FakeMicrophone { FakeMicrophone() }

    /// Digital silence.
    public static func silence() -> FakeMicrophone {
        FakeMicrophone(signal: .silence)
    }

    /// A steady sine at `hz` with peak `amplitude` (1 is full scale), sampled at 48 kHz.
    public static func sine(_ hz: Float, _ amplitude: Float) -> FakeMicrophone {
        FakeMicrophone(signal: .sine(hz: hz, amplitude: amplitude))
    }

    /// Mono samples at `rate` Hz (-1 to 1).
    public static func samples(rate: UInt32, _ samples: [Float]) -> FakeMicrophone {
        FakeMicrophone(signal: .samples(rate: max(1, rate), samples: samples))
    }

    /// A WAV file (8, 16, 24, or 32-bit PCM, or 32-bit float), mixed to mono when recording starts.
    public static func wav(_ url: URL) -> FakeMicrophone {
        FakeMicrophone(signal: .wav(url))
    }

    public static func wav(_ path: String) -> FakeMicrophone {
        FakeMicrophone(signal: .wav(URL(fileURLWithPath: path)))
    }

    /// What `Recorder.permission()` reports (default `.granted`).
    public func permission(_ p: MicPermission) -> FakeMicrophone {
        var copy = self
        copy.permissionState = p
        return copy
    }

    /// How a permission request resolves while the permission is `.undetermined` (default `.granted`).
    public func answers(_ answer: MicPermission) -> FakeMicrophone {
        var copy = self
        copy.answerState = answer
        return copy
    }

    /// The microphone goes away after `seconds` of recording.
    public func unplugAfter(_ seconds: Double) -> FakeMicrophone {
        var copy = self
        copy.unplugSeconds = max(0.0, seconds)
        return copy
    }

    /// Recorders started on this thread while no window has run hear this microphone.
    public func install() {
        RuneExecutionContext.locals[Self.threadLocalKey] = self
    }

    /// Back to `FakeMicrophone.default` on this thread.
    public static func uninstall() {
        RuneExecutionContext.locals.removeObject(forKey: Self.threadLocalKey)
    }

    internal static func installed() -> FakeMicrophone {
        (RuneExecutionContext.locals[Self.threadLocalKey] as? FakeMicrophone) ?? .default
    }

    internal static func requestInstalled() -> MicPermission {
        var current = installed()
        let resolved = current.resolve()
        RuneExecutionContext.locals[Self.threadLocalKey] = current
        return resolved
    }

    internal mutating func resolve() -> MicPermission {
        if permissionState == .undetermined {
            permissionState = answerState
        }
        return permissionState
    }

    internal func open() -> Result<FakeInput, RecorderError> {
        switch signal {
        case .swell:
            return .success(FakeInput(rate: Self.defaultRate, kind: .swell))
        case .silence:
            return .success(FakeInput(rate: Self.defaultRate, kind: .silence))
        case let .sine(hz, amplitude):
            return .success(FakeInput(rate: Self.defaultRate, kind: .sine(hz: Double(hz), amplitude: Double(amplitude))))
        case let .samples(rate, samples):
            return .success(FakeInput(rate: rate, kind: .samples(samples)))
        case let .wav(url):
            switch Self.readWAV(at: url) {
            case let .success((rate, samples)):
                return .success(FakeInput(rate: rate, kind: .samples(samples)))
            case let .failure(err):
                return .failure(RecorderError(err.description))
            }
        }
    }

    /// Encodes `durationSeconds` of samples into 16-bit mono PCM WAV data.
    public func encodeWAV(durationSeconds: Double) -> Data {
        let input: FakeInput
        switch open() {
        case .success(let inp): input = inp
        case .failure: input = FakeInput(rate: Self.defaultRate, kind: .silence)
        }
        let frames = UInt64(max(0.0, durationSeconds * Double(input.rate)).rounded(.down))
        return Self.encodeWAVData(input: input, frames: frames) ?? Data()
    }

    internal static func wavHeader(rate: UInt32, dataBytes: UInt32, channels: UInt16 = 1) -> Data {
        var h = [UInt8](repeating: 0, count: 44)
        func put(_ at: Int, _ bytes: [UInt8]) {
            for i in 0..<bytes.count { h[at + i] = bytes[i] }
        }
        func putU16(_ at: Int, _ v: UInt16) {
            let le = v.littleEndian
            withUnsafeBytes(of: le) { put(at, Array($0)) }
        }
        func putU32(_ at: Int, _ v: UInt32) {
            let le = v.littleEndian
            withUnsafeBytes(of: le) { put(at, Array($0)) }
        }
        put(0, Array("RIFF".utf8))
        putU32(4, 36 &+ dataBytes)
        put(8, Array("WAVEfmt ".utf8))
        putU32(16, 16)
        putU16(20, 1) // PCM
        putU16(22, channels)
        putU32(24, rate)
        putU32(28, rate &* UInt32(channels) &* 2)
        putU16(32, channels * 2)
        putU16(34, 16)
        put(36, Array("data".utf8))
        putU32(40, dataBytes)
        return Data(h)
    }

    internal static func encodeWAVData(input: FakeInput, frames: UInt64) -> Data? {
        let byteCount64 = frames * 2
        guard byteCount64 <= UInt64(UInt32.max) - 36 else { return nil }
        var out = wavHeader(rate: input.rate, dataBytes: UInt32(byteCount64))
        out.reserveCapacity(44 + Int(byteCount64))
        for i in 0..<frames {
            let clamped = max(-1.0 as Float, min(1.0 as Float, input.sample(i)))
            let s = Int16((clamped * 32767.0).rounded()).littleEndian
            withUnsafeBytes(of: s) { out.append(contentsOf: $0) }
        }
        return out
    }

    internal static func writeWAV(to url: URL, input: FakeInput, frames: UInt64) -> Result<Void, RecorderError> {
        let byteCount64 = frames * 2
        guard byteCount64 <= UInt64(UInt32.max) - 36 else {
            return .failure("the recording is too long for a WAV file")
        }
        guard let data = encodeWAVData(input: input, frames: frames) else {
            return .failure("the recording is too long for a WAV file")
        }
        do {
            try data.write(to: url, options: [])
            return .success(())
        } catch {
            return .failure(RecorderError("couldn't write \(url.path): \(error.localizedDescription)"))
        }
    }

    public static func readWAV(at url: URL) -> Result<(UInt32, [Float]), WAVParseError> {
        do {
            let data = try Data(contentsOf: url)
            return parseWAV(data).mapError { .message("\(url.path): \($0.description)") }
        } catch {
            return .failure(.message("couldn't read \(url.path): \(error.localizedDescription)"))
        }
    }

    public static func parseWAV(_ data: Data) -> Result<(UInt32, [Float]), WAVParseError> {
        let b = [UInt8](data)
        guard b.count >= 12, Array(b[0..<4]) == Array("RIFF".utf8), Array(b[8..<12]) == Array("WAVE".utf8) else {
            return .failure(.message("not a WAV file"))
        }
        func u16(_ i: Int) -> UInt16 {
            UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
        }
        func u32(_ i: Int) -> UInt32 {
            UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
        }
        var fmtOffset: Int?
        var dataRange: Range<Int>?
        var at = 12
        while at + 8 <= b.count {
            let len = Int(u32(at + 4))
            let start = at + 8
            let end = min(b.count, start &+ len)
            let tag = String(decoding: b[at..<(at + 4)], as: UTF8.self)
            if tag == "fmt ", end - start >= 16 {
                fmtOffset = start
            } else if tag == "data" {
                dataRange = start..<end
            }
            at = end + (len & 1)
        }
        guard let f = fmtOffset, let dRange = dataRange else {
            return .failure(.message("no fmt or data chunk"))
        }
        var format = u16(f)
        if format == 0xFFFE, f + 26 <= b.count {
            format = u16(f + 24)
        }
        let channels = Int(u16(f + 2))
        let rate = u32(f + 4)
        let bits = u16(f + 14)
        let width = Int(bits) / 8
        guard channels > 0, rate > 0, width > 0 else {
            return .failure(.message("invalid fmt chunk"))
        }

        let decodeSample: (ArraySlice<UInt8>) -> Float
        switch (format, bits) {
        case (1, 8):
            decodeSample = { s in
                let i = s.startIndex
                return (Float(s[i]) - 128.0) / 128.0
            }
        case (1, 16):
            decodeSample = { s in
                let i = s.startIndex
                let raw = Int16(bitPattern: UInt16(s[i]) | (UInt16(s[i + 1]) << 8))
                return Float(raw) / 32768.0
            }
        case (1, 24):
            decodeSample = { s in
                let i = s.startIndex
                let v = (Int32(s[i]) << 8) | (Int32(s[i + 1]) << 16) | (Int32(s[i + 2]) << 24)
                return Float(v >> 8) / 8_388_608.0
            }
        case (1, 32):
            decodeSample = { s in
                let i = s.startIndex
                let raw = Int32(bitPattern: UInt32(s[i]) | (UInt32(s[i + 1]) << 8) | (UInt32(s[i + 2]) << 16) | (UInt32(s[i + 3]) << 24))
                return Float(raw) / 2_147_483_648.0
            }
        case (3, 32):
            decodeSample = { s in
                let i = s.startIndex
                let bits = UInt32(s[i]) | (UInt32(s[i + 1]) << 8) | (UInt32(s[i + 2]) << 16) | (UInt32(s[i + 3]) << 24)
                return Float(bitPattern: bits)
            }
        default:
            return .failure(.message("unsupported WAV sample format (use PCM or 32-bit float)"))
        }

        let frameBytes = width * channels
        guard frameBytes > 0 else { return .failure(.message("invalid fmt chunk")) }
        let frameCount = (dRange.upperBound - dRange.lowerBound) / frameBytes
        var out: [Float] = []
        out.reserveCapacity(frameCount)
        var cursor = dRange.lowerBound
        for _ in 0..<frameCount {
            var sum: Float = 0
            for ch in 0..<channels {
                let sStart = cursor + ch * width
                sum += decodeSample(b[sStart..<(sStart + width)])
            }
            out.append(sum / Float(channels))
            cursor += frameBytes
        }
        return .success((rate, out))
    }
}

internal struct FakeInput: Sendable {
    enum Kind: Sendable {
        case swell
        case silence
        case sine(hz: Double, amplitude: Double)
        case samples([Float])
    }

    let rate: UInt32
    let kind: Kind

    func sample(_ i: UInt64) -> Float {
        let t = Double(i) / Double(rate)
        let tau = Double.pi * 2.0
        switch kind {
        case .silence:
            return 0.0
        case let .sine(hz, amplitude):
            return Float(amplitude * sin(tau * hz * t))
        case .swell:
            return Float(0.3 * (0.5 - 0.5 * cos(tau * t / 1.6)) * sin(tau * 220.0 * t))
        case let .samples(buf):
            if buf.isEmpty { return 0.0 }
            return buf[Int(i % UInt64(buf.count))]
        }
    }
}
