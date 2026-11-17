#if os(WASI)
import Foundation

/// The DOM drives this queue on its single WebAssembly thread. Standalone WASI
/// commands never enable it and continue to use the portable PNG decoder.
enum BrowserImageCodec {
    enum Source {
        case bytes(Data), url(String), thumbnailURL(String)

        var payload: (kind: UInt32, bytes: Data) {
            switch self {
            case .bytes(let data): (0, data)
            case .url(let url): (1, Data(url.utf8))
            case .thumbnailURL(let url): (2, Data(url.utf8))
            }
        }
    }

    typealias Completion = @Sendable (Result<DecodedImage, ImageLoadError>) -> Void

    private final class Request {
        let name: String
        let limit: UInt32
        let completion: Completion
        var source: Source?
        var frames: [AnimatedImageFrame] = []

        init(_ source: Source, name: String, limit: Int?, completion: @escaping Completion) {
            self.source = source
            self.name = name
            self.limit = UInt32(min(Int(IMAGE_MAX_SIDE), max(0, limit ?? 0)))
            self.completion = completion
        }
    }

    nonisolated(unsafe) static var enabled = false
    nonisolated(unsafe) private static var sequence: UInt32 = 0
    nonisolated(unsafe) private static var requests: [UInt32: Request] = [:]
    nonisolated(unsafe) private static var queue: [UInt32] = []
    nonisolated(unsafe) private static var head = 0
    nonisolated(unsafe) private static var decoding = 0

    static var canStart: Bool { enabled && decoding < IMAGE_DECODERS && head < queue.count }

    static func submit(_ source: Source, name: String, limit: Int? = nil, completion: @escaping Completion) {
        repeat { sequence &+= 1 } while sequence == 0 || requests[sequence] != nil
        requests[sequence] = Request(source, name: name, limit: limit, completion: completion)
        let hadReadyWork = canStart
        queue.append(sequence)
        if !hadReadyWork && canStart { WASIEventLoop.wake(after: 0) }
    }

    @MainActor static func next() -> Int {
        guard canStart else { return 0 }
        let id = queue[head]
        head += 1
        if head == queue.count {
            queue.removeAll(keepingCapacity: true)
            head = 0
        }
        guard let job = requests[id], let source = job.source else { return 0 }
        let (kind, bytes) = source.payload
        job.source = nil
        guard bytes.count <= Int.max - 12, let buffer = RuneWebReactor.reserve(12 + bytes.count) else {
            requests.removeValue(forKey: id)
            job.completion(.failure(ImageLoadError("\(job.name): browser image request is too large")))
            return 0
        }
        decoding += 1
        let fields = buffer.assumingMemoryBound(to: UInt32.self)
        fields[0] = id
        fields[1] = job.limit
        fields[2] = kind
        bytes.copyBytes(to: (buffer + 12).assumingMemoryBound(to: UInt8.self), count: bytes.count)
        return 12 + bytes.count
    }

    @MainActor static func append(_ id: UInt32, width: UInt32, height: UInt32, duration: Double) -> Int32 {
        guard let job = requests[id], job.source == nil else { return 0 }
        let count = UInt64(width) * UInt64(height)
        guard width > 0, height > 0, width <= IMAGE_MAX_SIDE, height <= IMAGE_MAX_SIDE,
              count * 4 <= UInt64(RuneWebReactor.capacity), let buffer = RuneWebReactor.buffer,
              let cost = DecodedImage.animationStorage(width: width, height: height),
              job.frames.first.map({ $0.width == width && $0.height == height }) ?? true,
              job.frames.isEmpty || cost <= UInt64(LinearMipGenerator.maxDecodedBytes) / UInt64(job.frames.count + 1)
        else {
            finish(id, error: "invalid browser image frame", plays: 0)
            return 0
        }
        job.frames.append(AnimatedImageFrame(decodedWidth: width, height: height,
            rgba: Data(bytes: buffer, count: Int(count * 4)), durationSeconds: duration))
        return 1
    }

    @MainActor static func finish(_ id: UInt32, error: String?, plays: UInt32) {
        guard let job = requests[id], job.source == nil else { return }
        let result: Result<DecodedImage, ImageLoadError>
        if let error {
            result = .failure(ImageLoadError("\(job.name): \(error)"))
        } else if let first = job.frames.first {
            result = .success(DecodedImage(id: job.name, width: first.width, height: first.height,
                mips: [], frames: job.frames, loopCount: Int(clamping: plays)))
        } else {
            result = .failure(ImageLoadError("\(job.name): image contains no frames"))
        }
        settle(id, result)
    }

    /// Fetched APNGs use the same compositor as byte-based loads, including on browsers
    /// whose image element can only expose the default PNG canvas.
    @MainActor static func portablePNG(_ id: UInt32, length: Int, limit: UInt32) -> Int32 {
        guard let job = requests[id], job.source == nil, length > 0, length <= RuneWebReactor.capacity,
              let buffer = RuneWebReactor.buffer,
              let image = try? AnimatedPNG.decodeIfAnimated(Data(bytes: buffer, count: length),
                id: job.name, maxDimension: limit == 0 ? nil : Int(clamping: limit)) else { return 0 }
        settle(id, .success(image))
        return 1
    }

    @MainActor private static func settle(_ id: UInt32, _ result: Result<DecodedImage, ImageLoadError>) {
        guard let job = requests.removeValue(forKey: id) else { return }
        decoding -= 1
        job.completion(result)
        RuneWebReactor.session?.requestPaint()
        WASIEventLoop.wake(after: 0)
    }

    static func reset() {
        enabled = false
        let jobs = requests.values
        requests.removeAll()
        queue.removeAll()
        head = 0
        decoding = 0
        for job in jobs { job.completion(.failure(ImageLoadError("\(job.name): browser image request cancelled"))) }
    }
}

@MainActor @_cdecl("rune_web_image_enable")
func runeWebImageEnable() { BrowserImageCodec.enabled = true }

@MainActor @_cdecl("rune_web_image_next")
func runeWebImageNext() -> Int { BrowserImageCodec.next() }

@MainActor @_cdecl("rune_web_image_frame")
func runeWebImageFrame(_ id: UInt32, _ width: UInt32, _ height: UInt32, _ duration: Double) -> Int32 {
    BrowserImageCodec.append(id, width: width, height: height, duration: duration)
}

@MainActor @_cdecl("rune_web_image_apng")
func runeWebImageAPNG(_ id: UInt32, _ length: Int, _ limit: UInt32) -> Int32 {
    BrowserImageCodec.portablePNG(id, length: length, limit: limit)
}

@MainActor @_cdecl("rune_web_image_finish")
func runeWebImageFinish(_ id: UInt32, _ plays: UInt32, _ errorLength: Int) {
    var message: String?
    if errorLength != 0 {
        if errorLength > 0, errorLength <= RuneWebReactor.capacity, let bytes = RuneWebReactor.buffer {
            message = String(decoding: UnsafeRawBufferPointer(start: bytes, count: errorLength), as: UTF8.self)
        } else {
            message = "browser image decoder failed"
        }
    }
    BrowserImageCodec.finish(id, error: message, plays: plays)
}
#endif
