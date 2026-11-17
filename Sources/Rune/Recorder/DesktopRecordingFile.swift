#if canImport(CRuneMedia) && (os(Linux) || os(Windows))
import CRuneMedia
import Foundation

internal extension RecorderError {
    static func native(_ buffer: [CChar]) -> RecorderError {
        RecorderError(String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
}

/// Streams into a sibling of the destination. A cancelled take leaves an earlier recording intact.
internal final class DesktopRecordingFile {
    private enum Sink { case wav(FileHandle), aac(OpaquePointer) }
    private var sink: Sink?
    private let staged: URL
    private let destination: URL
    private let options: RecorderOptions
    private var frames: UInt64 = 0
    private var pcm: [Int16] = []
    var duration: Double { Double(frames) / Double(options.sampleRate) }

    init(url: URL, options: RecorderOptions) throws {
        self.options = options
        destination = url.standardizedFileURL
        staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".rune-recording-\(UUID().uuidString)")
            .appendingPathExtension(options.format == .wav ? "wav" : "m4a")
        do {
            switch options.format {
            case .wav:
                let header = FakeMicrophone.wavHeader(rate: options.sampleRate, dataBytes: 0, channels: options.channels)
                try header.write(to: staged, options: .withoutOverwriting)
                let file = try FileHandle(forWritingTo: staged)
                sink = .wav(file)
                try file.seekToEnd()
            case .aac:
                var error = [CChar](repeating: 0, count: 512)
                let size = error.count
                guard let handle = rune_mic_aac_open(staged.path, options.sampleRate, options.channels, &error, size) else {
                    throw RecorderError.native(error)
                }
                sink = .aac(handle)
            }
        } catch {
            close()
            throw error
        }
    }

    func append(_ samples: [Float], frames count: Int) throws {
        let sampleCount = count * Int(options.channels)
        switch sink {
        case .wav(let file):
            let bytes = (frames + UInt64(count)) * UInt64(options.channels) * 2
            guard bytes <= UInt32.max - 36 else { throw RecorderError("The recording is too long for a WAV file") }
            if pcm.count < sampleCount { pcm = Array(repeating: 0, count: sampleCount) }
            for i in 0..<sampleCount {
                let x = samples[i].isFinite ? min(1, max(-1, samples[i])) : 0
                pcm[i] = Int16(clamping: Int((x * 32_768).rounded())).littleEndian
            }
            try pcm.withUnsafeBytes { try file.write(contentsOf: $0.prefix(sampleCount * 2)) }
        case .aac(let handle):
            var error = [CChar](repeating: 0, count: 512)
            let size = error.count
            guard rune_mic_aac_write(handle, samples, UInt32(count), &error, size) != 0 else {
                throw RecorderError.native(error)
            }
        case nil: throw RecorderError("The recording file is closed")
        }
        frames += UInt64(count)
    }

    func finish() throws -> Double {
        var error = [CChar](repeating: 0, count: 512)
        let size = error.count
        switch sink {
        case .wav(let file):
            let bytes = UInt32(frames * UInt64(options.channels) * 2)
            try file.seek(toOffset: 0)
            try file.write(contentsOf: FakeMicrophone.wavHeader(rate: options.sampleRate, dataBytes: bytes,
                                                                 channels: options.channels))
            try file.close()
        case .aac(let handle):
            guard rune_mic_aac_finish(handle, &error, size) != 0 else { throw RecorderError.native(error) }
            rune_mic_aac_close(handle)
        case nil: throw RecorderError("The recording file is closed")
        }
        sink = nil
        guard rune_mic_publish(staged.path, destination.path, &error, size) != 0 else { throw RecorderError.native(error) }
        return duration
    }

    func close() {
        switch sink {
        case .aac(let handle): rune_mic_aac_close(handle)
        case .wav(let file): try? file.close()
        case nil: break
        }
        sink = nil
        try? FileManager.default.removeItem(at: staged)
    }

    deinit { close() }
}
#endif
