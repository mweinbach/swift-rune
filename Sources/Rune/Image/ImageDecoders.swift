import Foundation

// MARK: - Image Decoder Threads & Inline RGBA (`rune::image` `DECODERS`, `INLINE_RGBA_PIXELS`, `Input`, `decoders`)

/// Decoder threads for the process, at most one per core (`image.rs` `DECODERS`).
public let IMAGE_DECODERS: Int = 4

/// Straight RGBA images up to this many pixels (64 x 64) finish on the calling thread
/// (`image.rs` `INLINE_RGBA_PIXELS`).
public let INLINE_RGBA_PIXELS: UInt64 = 64 * 64

/// A decoder failure that, upstream, unwinds as a Rust panic (a codec bug). Swift cannot
/// unwind a trap, so a decoder that would panic throws this instead; `decodeCaught` turns it
/// into the image's error exactly as `catch_unwind` does (`image.rs` `Input::decode_caught`).
struct ImageDecoderPanic: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Test-only gate a decode waits on before it runs (`image.rs` `Input::Gated`'s
/// `mpsc::Receiver<()>`): `release()` lets exactly one waiting decode proceed.
#if !os(WASI)
final class ImageDecodeGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    init() {}

    /// `release.send(())`.
    func release() { semaphore.signal() }

    /// `release.recv()`.
    func wait() { semaphore.wait() }
}

#endif

/// What an `ImageCache` request decodes (`image.rs` `Input`).
indirect enum ImageDecodeInput: Sendable {
    /// `ImageCache.load(_:)` bytes (`Input::Encoded`).
    case encoded(Data)
    /// Straight-alpha sRGB RGBA8 (`Input::Rgba`).
    case rgba(UInt32, UInt32, Data)
    /// A decoder that panics, standing in for a codec bug (`#[cfg(test)] Input::Panic`).
    case panic
    /// A decode that waits on `gate` first (`#[cfg(test)] Input::Gated`).
    #if !os(WASI)
    case gated(ImageDecodeInput, ImageDecodeGate)
    #endif

    /// The straight RGBA size, for the inline-finish check in `ImageCache::request_set`.
    var rgbaPixelCount: UInt64? {
        if case .rgba(let w, let h, _) = self { return UInt64(w) * UInt64(h) }
        return nil
    }

    /// `Input::decode`. Ordinary failures are the image's error; a thrown
    /// `ImageDecoderPanic` is the panic `decodeCaught` recovers from.
    func decode() throws -> Result<DecodedImage, ImageLoadError> {
        switch self {
        case .encoded(let bytes):
            return ImageCache.decodeEncoded(bytes)
        case .rgba(let w, let h, let bytes):
            return ImageCache.land(url: "rgba", fetched: .rgba(width: w, height: h, data: bytes), pixelSize: max(w, h))
        case .panic:
            throw ImageDecoderPanic("decoder bug")
        #if !os(WASI)
        case .gated(let input, let gate):
            gate.wait()
            return try input.decode()
        #endif
        }
    }

    /// `decode`, with a panic in a codec failing this image instead of unwinding the worker,
    /// which would leave it pending and fail every later one (`Input::decode_caught`).
    func decodeCaught() -> Result<DecodedImage, ImageLoadError> {
        do {
            return try decode()
        } catch let panic as ImageDecoderPanic {
            return .failure(ImageLoadError("image decoder panicked: \(panic.message)"))
        } catch {
            return .failure(ImageLoadError("image decoder panicked: no message"))
        }
    }
}

/// The process's decoder threads, shared by every cache and started by the first image to
/// decode: an app that makes a cache per feature, or shows no image, pays no thread for it.
/// The caller starts one; that one starts the others, so the first image costs its thread one
/// spawn, not four (`image.rs` `decoders` / `decode_jobs`).
final class ImageDecoderPool: @unchecked Sendable {
    struct Job: Sendable {
        let image: CachedImage
        let input: ImageDecodeInput
        let wake: @Sendable () -> Void
    }

    static let shared = ImageDecoderPool()

    #if os(WASI)
    let threadCount = 1

    func submit(_ job: Job) {
        if BrowserImageCodec.enabled, case .encoded(let bytes) = job.input {
            // Keep APNG playback on browsers without an animated WebCodecs decoder.
            // Static PNGs and encodings outside the portable reader use the async host.
            if let image = try? AnimatedPNG.decodeIfAnimated(bytes, id: "image", maxDimension: nil) {
                job.image.resolve(with: .success(image))
                job.wake()
                return
            }
            BrowserImageCodec.submit(.bytes(bytes), name: "image") { result in
                job.image.resolve(with: result)
                job.wake()
            }
            return
        }
        job.image.resolve(with: job.input.decodeCaught())
        job.wake()
    }
    #else
    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var started = false
    /// `DECODERS.min(available_parallelism)`.
    let threadCount: Int

    private init() {
        threadCount = min(IMAGE_DECODERS, max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// `decoders().send(Job { .. })`.
    func submit(_ job: Job) {
        condition.lock()
        jobs.append(job)
        let start = !started
        started = true
        condition.signal()
        condition.unlock()
        guard start else { return }
        let count = threadCount
        spawn { [self] in
            for _ in 1..<count {
                spawn { [self] in decodeJobs() }
            }
            decodeJobs()
        }
    }

    private func spawn(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = "rune-images"
        thread.start()
    }

    /// `decode_jobs`: finish each job's image, then wake its cache's app.
    private func decodeJobs() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            job.image.resolve(with: job.input.decodeCaught())
            job.wake()
        }
    }
    #endif
}
