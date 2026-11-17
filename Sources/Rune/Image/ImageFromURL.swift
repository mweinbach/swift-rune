import Foundation
import RuneRef
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Image URL Fetch, Selection, SVG Rasterization & Single-Flight Cache (`rune::image::from_url`)

/// Decoded or rasterizable image payload returned by a URL loader (`from_url::Fetched`).
public enum FetchedImage: Sendable, Equatable {
    case rgba(width: UInt32, height: UInt32, data: Data)
    case svg(Data)
}

/// Error from URL image validation, fetching, or decoding, always prefixed with the URL (`from_url::ImageError`).
public struct ImageLoadError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Shared decode state retained by both `CachedImage` and its `Pixels` (`rune::image::State`).
public final class CachedImageState: @unchecked Sendable {
    public let id: ImageId
    private let lock = NSCondition()
    private var settled = false
    private var outcome: Result<(UInt32, UInt32), ImageLoadError>?

    init(id: ImageId) {
        self.id = id
    }

    var error: ImageLoadError? {
        lock.lock()
        defer { lock.unlock() }
        if case .failure(let err) = outcome { return err }
        return nil
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settled
    }

    func resolve(with result: Result<DecodedImage, ImageLoadError>, into pixels: Pixels) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        switch result {
        case .success(let decoded):
            pixels.setDecoded(decoded)
            outcome = .success((decoded.width, decoded.height))
        case .failure(let err):
            outcome = .failure(err)
        }
        settled = true
        lock.broadcast()
        lock.unlock()
    }

    func wait(timeout: TimeInterval) -> Result<(UInt32, UInt32), ImageLoadError> {
        lock.lock()
        defer { lock.unlock() }
        #if os(WASI)
        // A synchronous wait would prevent the reactor from delivering the image.
        return outcome ?? .failure(ImageLoadError("image is pending on the browser event loop"))
        #else
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let outcome { return outcome }
            if !lock.wait(until: deadline) {
                return outcome ?? .failure(ImageLoadError("timed out waiting for image"))
            }
        }
        #endif
    }
}

/// Shared handle to an asynchronous or immediate cached image load (`rune::Image`).
public final class CachedImage: @unchecked Sendable {
    public let id: ImageId
    public let pixels: Pixels
    public let state: CachedImageState

    init(id: ImageId, pixels: Pixels, state: CachedImageState? = nil) {
        self.id = id
        self.pixels = pixels
        let resolvedState = state ?? CachedImageState(id: id)
        self.state = resolvedState
        pixels.cacheRetainOwner = resolvedState
    }

    public var size: (width: UInt32, height: UInt32)? {
        let s = pixels.size
        guard s.width > 0, s.height > 0 else { return nil }
        return s
    }

    public var error: ImageLoadError? { state.error }

    public var isReady: Bool { state.isReady }

    internal func resolve(with result: Result<DecodedImage, ImageLoadError>) {
        state.resolve(with: result, into: pixels)
    }

    /// Waits for the image or its timeout. In a browser, a pending handle returns
    /// immediately so the event loop can deliver the result and call the cache's wake closure.
    @discardableResult
    public func wait(timeout: TimeInterval = 5.0) -> Result<(UInt32, UInt32), ImageLoadError> {
        state.wait(timeout: timeout)
    }
}

/// URL, responsive `srcset`, local file, and HTTP/`URLProtocol` image cache (`rune::ImageCache`).
public final class ImageCache: @unchecked Sendable {
    public typealias RemoteLoader = @Sendable (String, UInt32) async throws -> FetchedImage

    private struct CacheKey: Hashable {
        var url: String
        var pixelSize: UInt32
        var srcset: String?
    }

    private struct WeakEntry {
        weak var handle: CachedImage?
        weak var state: CachedImageState?
        weak var pixels: Pixels?
    }

    private let lock = NSLock()
    private var entries: [CacheKey: WeakEntry] = [:]
    private let wake: @Sendable () -> Void
    #if !os(WASI)
    private let session: URLSession?
    #endif
    private let remoteLoader: RemoteLoader?

    /// Number of live (handle or drawn `Pixels` still retained) entries currently tracked (`image.rs:760`).
    public var liveEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter { $0.state != nil }.count
    }

    #if os(WASI)
    public init(wake: @escaping @Sendable () -> Void = {}, remoteLoader: RemoteLoader? = nil) {
        self.wake = wake
        self.remoteLoader = remoteLoader
    }
    #else
    /// Creates an image cache with an optional redraw `wake` closure, `URLSession` (for custom
    /// `URLProtocol` testing/HTTP), or injectable `remoteLoader`.
    public init(
        wake: @escaping @Sendable () -> Void = {},
        session: URLSession? = nil,
        remoteLoader: RemoteLoader? = nil
    ) {
        self.wake = wake
        self.session = session
        self.remoteLoader = remoteLoader
    }
    #endif

    /// Parses a native path or `file:` URL, rejecting `http:`/`https:`/`data:` and invalid escapes (`from_url::file_path`).
    public static func filePath(for url: String) -> Result<String, ImageLoadError> {
        if let colon = url.firstIndex(of: ":") {
            let prefix = String(url[..<colon])
            let isScheme = prefix.count > 1
                && (prefix.first?.isASCII == true && prefix.first?.isLetter == true)
                && prefix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
            if isScheme {
                let unsupported = ImageLoadError("\(url): only web or URLSession fetches URLs; on native fetch the bytes and call ImageCache::load")
                guard prefix.lowercased() == "file" else {
                    return .failure(unsupported)
                }
                let restIdx = url.index(after: colon)
                let rest = String(url[restIdx...])
                let rawPath: String
                if rest.hasPrefix("//") {
                    let afterSlashes = String(rest.dropFirst(2))
                    if afterSlashes.lowercased().hasPrefix("localhost/") {
                        rawPath = String(afterSlashes.dropFirst("localhost".count))
                    } else if afterSlashes.lowercased() == "localhost" {
                        rawPath = ""
                    } else {
                        rawPath = afterSlashes
                    }
                } else {
                    rawPath = rest
                }
                guard rawPath.hasPrefix("/") else {
                    return .failure(unsupported)
                }
                guard let decoded = percentDecodeUTF8(rawPath) else {
                    return .failure(ImageLoadError("\(url): not a valid file URL"))
                }
                return .success(decoded)
            }
        }
        return .success(url)
    }

    /// Validates, decodes/rasterizes, and builds mipmaps for fetched bytes, prefixing any error with `url` (`from_url::land`).
    public static func land(url: String, fetched: FetchedImage, pixelSize: UInt32) -> Result<DecodedImage, ImageLoadError> {
        do {
            switch fetched {
            case .rgba(let width, let height, let data):
                return try .success(buildMipDecoded(id: url, width: width, height: height, data: data))
            case .svg(let svgData):
                let (w, h, rgba) = try rasterizeSVG(svgData, targetMaxSide: max(1, pixelSize))
                return try .success(buildMipDecoded(id: url, width: w, height: h, data: rgba))
            }
        } catch let err as ImageLoadError {
            if err.message.hasPrefix("\(url): ") {
                return .failure(err)
            }
            return .failure(ImageLoadError("\(url): \(err.message)"))
        } catch {
            return .failure(ImageLoadError("\(url): \(error.localizedDescription)"))
        }
    }

    /// Returns a shared handle for `(url, sizePt, scale)` (`ImageCache::url`).
    public func url(_ url: String, sizePt: Float, scale: Float) -> CachedImage {
        let px = Self.iconPixels(sizePt: sizePt, scale: scale)
        let id = ImageId.forURL(url, pixelSize: px)
        return request(key: CacheKey(url: url, pixelSize: px, srcset: nil), id: id, url: url, pixelSize: px, srcset: nil)
    }

    /// Selects the narrowest source `>= ceil(sizePt * scale)` (or the widest), sharing handles by chosen file (`ImageCache::url_set`).
    public func urlSet(_ sources: [(String, UInt32)], sizePt: Float, scale: Float) -> CachedImage {
        let mapped = sources.map { ImageURLSet.Source(url: $0.0, widthPixels: $0.1) }
        guard let selection = ImageURLSet.select(sources: mapped, sizePt: sizePt, scale: scale) else {
            return url("", sizePt: sizePt, scale: scale)
        }
        let px = max(1, selection.selected.widthPixels)
        return request(
            key: CacheKey(url: selection.selected.url, pixelSize: px, srcset: selection.srcset),
            id: selection.id,
            url: selection.selected.url,
            pixelSize: px,
            srcset: selection.srcset
        )
    }

    /// Straight-alpha sRGB RGBA8, without a `sourceURLString` (`ImageCache::rgba`). Validation,
    /// premultiplication and mips happen on the decoder threads, except for an image of at most
    /// `INLINE_RGBA_PIXELS`, which is ready (and wakes the app once) before this returns.
    public func rgba(width: UInt32, height: UInt32, data: [UInt8]) -> CachedImage {
        let raw = Data(data)
        let id = ImageId.contentHash(raw)
        let key = CacheKey(url: "rgba:\(width)x\(height):\(Self.hex(id))", pixelSize: max(width, height), srcset: nil)
        return requestDecode(key: key, id: id, input: .rgba(width, height, raw))
    }

    /// Encoded image bytes (PNG, JPEG, GIF, WebP, HEIC, AVIF, ... or SVG content, rasterized at
    /// twice its own size), decoded on the decoder threads (`ImageCache::load`).
    public func load(_ bytes: Data) -> CachedImage {
        var payload = Data("rune-encoded\0".utf8)
        payload.append(bytes)
        let id = ImageId.contentHash(payload)
        return requestDecode(key: CacheKey(url: "encoded:\(Self.hex(id))", pixelSize: 0, srcset: nil), id: id, input: .encoded(bytes))
    }

    /// `ImageCache::request` with an explicit id, for tests that queue a test-only input
    /// (`Input::Panic`, `Input::Gated`).
    internal func request(id: ImageId, input: ImageDecodeInput) -> CachedImage {
        requestDecode(key: CacheKey(url: "id:\(Self.hex(id))", pixelSize: 0, srcset: nil), id: id, input: input)
    }

    /// `ImageCache::request_set` for decoded inputs: a cache hit hands back the live entry and
    /// does not wake; a small straight RGBA image finishes inline and wakes once before
    /// returning; anything else queues on the process's decoder threads, which wake on finish.
    private func requestDecode(key: CacheKey, id: ImageId, input: ImageDecodeInput) -> CachedImage {
        lock.lock()
        entries = entries.filter { $0.value.state != nil }
        if let existing = entries[key] {
            if let liveHandle = existing.handle {
                lock.unlock()
                return liveHandle
            }
            if let state = existing.state, let pixels = existing.pixels {
                let reused = CachedImage(id: state.id, pixels: pixels, state: state)
                entries[key] = WeakEntry(handle: reused, state: state, pixels: pixels)
                lock.unlock()
                return reused
            }
        }
        let pixels = Pixels()
        let handle = CachedImage(id: id, pixels: pixels)
        entries[key] = WeakEntry(handle: handle, state: handle.state, pixels: pixels)
        // A small straight RGBA image (a 16 pt tile at 2x) is ready at once: its mips take
        // microseconds, less than handing it to a decoder, and the view that asked for it draws it
        // in the same frame rather than a placeholder first. It still wakes the app once, as a
        // decoded one does: a caller outside a view's build (an overlay's state, a poll) is
        // redrawn by that wake alone.
        if let count = input.rgbaPixelCount, count <= INLINE_RGBA_PIXELS {
            handle.resolve(with: input.decodeCaught())
            lock.unlock()
            wake()
            return handle
        }
        lock.unlock()
        ImageDecoderPool.shared.submit(.init(image: handle, input: input, wake: wake))
        return handle
    }

    private static func hex(_ id: ImageId) -> String {
        id.bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes `ImageCache.load` bytes: SVG content rasterizes at twice its own size, anything
    /// else through the platform codecs (`image.rs` `decode`).
    static func decodeEncoded(_ bytes: Data) -> Result<DecodedImage, ImageLoadError> {
        do {
            if isSVGContent(bytes) {
                let (w, h, rgba) = try rasterizeSVG(bytes, targetMaxSide: 0)
                return try .success(buildMipDecoded(id: "image", width: w, height: h, data: rgba))
            }
            let decoded = try DecodedImage.decode(data: bytes, id: "image", maxDimension: Int(IMAGE_MAX_SIDE))
            guard decoded.width <= IMAGE_MAX_SIDE, decoded.height <= IMAGE_MAX_SIDE else {
                return .failure(ImageLoadError("image dimensions exceed \(IMAGE_MAX_SIDE)"))
            }
            return .success(decoded)
        } catch let err as ImageLoadError {
            return .failure(err)
        } catch {
            return .failure(ImageLoadError(String(describing: error)))
        }
    }

    /// Gzip (SVGZ), or markup after an optional BOM and whitespace (`image.rs` `is_svg`).
    static func isSVGContent(_ bytes: Data) -> Bool {
        if bytes.starts(with: [0x1f, 0x8b]) { return true }
        var body = bytes[...]
        if body.starts(with: [0xef, 0xbb, 0xbf]) { body = body.dropFirst(3) }
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0a, 0x0c, 0x0d]
        return body.first(where: { !whitespace.contains($0) }) == UInt8(ascii: "<")
    }

    /// Feeds already-fetched bytes manually for `url` (`ImageCache::load`).
    public func load(url: String, sizePt: Float = 0, scale: Float = 1, fetched: FetchedImage) -> CachedImage {
        let px = Self.iconPixels(sizePt: sizePt, scale: scale)
        let key = CacheKey(url: url, pixelSize: px, srcset: nil)
        let handle: CachedImage
        lock.lock()
        entries = entries.filter { $0.value.state != nil }
        if let existing = entries[key] {
            if let liveHandle = existing.handle {
                handle = liveHandle
            } else if let state = existing.state, let pixels = existing.pixels {
                handle = CachedImage(id: state.id, pixels: pixels, state: state)
                entries[key] = WeakEntry(handle: handle, state: state, pixels: pixels)
            } else {
                let pixels = Pixels()
                pixels.setSourceURL(url)
                handle = CachedImage(id: ImageId.forURL(url, pixelSize: px), pixels: pixels)
                entries[key] = WeakEntry(handle: handle, state: handle.state, pixels: pixels)
            }
        } else {
            let pixels = Pixels()
            pixels.setSourceURL(url)
            handle = CachedImage(id: ImageId.forURL(url, pixelSize: px), pixels: pixels)
            entries[key] = WeakEntry(handle: handle, state: handle.state, pixels: pixels)
        }
        lock.unlock()
        handle.resolve(with: Self.land(url: url, fetched: fetched, pixelSize: px))
        wake()
        return handle
    }

    private func request(
        key: CacheKey,
        id: ImageId,
        url: String,
        pixelSize: UInt32,
        srcset: String?
    ) -> CachedImage {
        lock.lock()
        entries = entries.filter { $0.value.state != nil }
        if let existing = entries[key] {
            if let liveHandle = existing.handle {
                lock.unlock()
                return liveHandle
            }
            if let state = existing.state, let pixels = existing.pixels {
                let reused = CachedImage(id: state.id, pixels: pixels, state: state)
                entries[key] = WeakEntry(handle: reused, state: state, pixels: pixels)
                lock.unlock()
                return reused
            }
        }
        let pixels = Pixels()
        pixels.setSourceURL(url)
        if let srcset {
            pixels.setSourceSet(srcset)
        }
        let handle = CachedImage(id: id, pixels: pixels)
        entries[key] = WeakEntry(handle: handle, state: handle.state, pixels: pixels)
        lock.unlock()

        let load: @Sendable () -> Void = { [self] in
            executeLoad(url: url, pixelSize: pixelSize, handle: handle)
        }
        #if os(WASI)
        load()
        #else
        DispatchQueue.global(qos: .userInitiated).async(execute: load)
        #endif
        return handle
    }

    private func executeLoad(url: String, pixelSize: UInt32, handle: CachedImage) {
        #if os(WASI)
        if BrowserImageCodec.enabled, remoteLoader == nil, !url.lowercased().hasPrefix("file:") {
            BrowserImageCodec.submit(.url(url), name: url, limit: Int(clamping: pixelSize)) { [wake] result in
                handle.resolve(with: result)
                wake()
            }
            return
        }
        #endif
        switch Self.filePath(for: url) {
        case .success(let path):
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                #if os(WASI)
                if BrowserImageCodec.enabled {
                    BrowserImageCodec.submit(.bytes(data), name: url,
                        limit: Self.isSVGContent(data) ? Int(clamping: pixelSize) : nil) { [wake] result in
                        handle.resolve(with: result)
                        wake()
                    }
                    return
                }
                #endif
                let decoded = try Self.decodeEncodedOrSVG(url: url, data: data, pixelSize: pixelSize)
                handle.resolve(with: .success(decoded))
            } catch let err as ImageLoadError {
                handle.resolve(with: .failure(err))
            } catch {
                handle.resolve(with: .failure(ImageLoadError("\(url): \(error.localizedDescription)")))
            }
            wake()
        case .failure(let nativeError):
            if let remoteLoader {
                Task { [wake] in
                    do {
                        let fetched = try await remoteLoader(url, pixelSize)
                        handle.resolve(with: Self.land(url: url, fetched: fetched, pixelSize: pixelSize))
                    } catch let err as ImageLoadError {
                        handle.resolve(with: .failure(err))
                    } catch {
                        handle.resolve(with: .failure(ImageLoadError("\(url): \(error.localizedDescription)")))
                    }
                    wake()
                }
                return
            }
            #if !os(WASI)
            if let session, let parsedURL = URL(string: url) {
                let task = session.dataTask(with: parsedURL) { [wake] data, response, err in
                    if let err {
                        handle.resolve(with: .failure(ImageLoadError("\(url): \(err.localizedDescription)")))
                    } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        handle.resolve(with: .failure(ImageLoadError("\(url): HTTP \(http.statusCode)")))
                    } else if let data {
                        do {
                            let decoded = try Self.decodeEncodedOrSVG(url: url, data: data, pixelSize: pixelSize)
                            handle.resolve(with: .success(decoded))
                        } catch let loadErr as ImageLoadError {
                            handle.resolve(with: .failure(loadErr))
                        } catch {
                            handle.resolve(with: .failure(ImageLoadError("\(url): \(error.localizedDescription)")))
                        }
                    } else {
                        handle.resolve(with: .failure(ImageLoadError("\(url): empty response")))
                    }
                    wake()
                }
                task.resume()
                return
            }
            #endif
            handle.resolve(with: .failure(nativeError))
            wake()
        }
    }

    private static func decodeEncodedOrSVG(url: String, data: Data, pixelSize: UInt32) throws -> DecodedImage {
        let pathExtension = (URL(string: url)?.pathExtension ?? "").lowercased()
        if pathExtension == "svg" || pathExtension == "svgz" || isSVGContent(data) {
            switch land(url: url, fetched: .svg(data), pixelSize: pixelSize) {
            case .success(let decoded): return decoded
            case .failure(let err): throw err
            }
        }
        let decoded = try DecodedImage.decode(data: data, id: url, maxDimension: Int(IMAGE_MAX_SIDE))
        guard decoded.width <= IMAGE_MAX_SIDE, decoded.height <= IMAGE_MAX_SIDE else {
            throw ImageLoadError("\(url): image dimensions exceed \(IMAGE_MAX_SIDE)")
        }
        return decoded
    }

    private static func buildMipDecoded(id: String, width: UInt32, height: UInt32, data: Data) throws -> DecodedImage {
        guard width > 0, height > 0 else {
            throw ImageLoadError("image dimensions must be non-zero")
        }
        guard width <= IMAGE_MAX_SIDE, height <= IMAGE_MAX_SIDE else {
            throw ImageLoadError("image side \(max(width, height)) exceeds max \(IMAGE_MAX_SIDE)")
        }
        let needed = Int(width) * Int(height) * 4
        guard data.count == needed else {
            throw ImageLoadError("expected \(needed) RGBA bytes for \(width)x\(height), got \(data.count)")
        }
        let mips = DecodedImage.generateMipChain(width: width, height: height, rgba: data)
        return DecodedImage(
            id: id,
            width: width,
            height: height,
            mips: mips,
            frames: [AnimatedImageFrame(width: width, height: height, rgba: data, durationSeconds: 0)],
            loopCount: 0
        )
    }

    private static func rasterizeSVG(_ encoded: Data, targetMaxSide: UInt32) throws -> (UInt32, UInt32, Data) {
        let data: Data
        if encoded.starts(with: [0x1f, 0x8b]) {
            do {
                data = try PortablePNG.gunzip(encoded, maximumSize: LinearMipGenerator.maxDecodedBytes)
            } catch {
                throw ImageLoadError("invalid SVGZ: \(error)")
            }
        } else {
            data = encoded
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImageLoadError("SVG is not valid UTF-8")
        }
        guard let rootStart = text.range(of: "<svg"),
              let tagEnd = text[rootStart.upperBound...].firstIndex(of: ">"),
              text[rootStart.lowerBound...tagEnd].hasSuffix("/>") || text[tagEnd...].contains("</svg>") else {
            throw ImageLoadError("malformed SVG document")
        }
        let tag = String(text[rootStart.lowerBound...tagEnd])
        func attribute(_ key: String) -> String? { SVGIconRenderer.attribute(in: tag, named: key) }

        var viewBox: (x: Double, y: Double, width: Double, height: Double)?
        if let raw = attribute("viewBox") {
            let parts = raw.split { $0.isWhitespace || $0 == "," }
            guard parts.count == 4, let x = Double(parts[0]), let y = Double(parts[1]),
                  let w = Double(parts[2]), let h = Double(parts[3]),
                  x.isFinite, y.isFinite, w.isFinite, h.isFinite, w > 0, h > 0 else {
                throw ImageLoadError("invalid SVG viewBox")
            }
            viewBox = (x, y, w, h)
        }
        var width = svgLength(attribute("width")), height = svgLength(attribute("height"))
        if let viewBox {
            let ratio = viewBox.width / viewBox.height
            if let height, width == nil { width = height * ratio }
            if let width, height == nil { height = width / ratio }
        }
        let viewportWidth = width ?? viewBox?.width ?? 16
        let viewportHeight = height ?? viewBox?.height ?? 16
        guard viewportWidth.isFinite, viewportHeight.isFinite, viewportWidth > 0, viewportHeight > 0 else {
            throw ImageLoadError("invalid SVG dimensions")
        }
        // Decode at twice the intrinsic size unless the caller requests a particular pixel size.
        let longest = max(viewportWidth, viewportHeight)
        let side = targetMaxSide == 0 ? min(max((longest * 2).rounded(.up), 1), 4096) : Double(targetMaxSide)
        guard side <= Double(IMAGE_MAX_SIDE) else { throw ImageLoadError("SVG rasterized size exceeds \(IMAGE_MAX_SIDE)") }
        let outW = max(1, Int((viewportWidth / longest * side).rounded()))
        let outH = max(1, Int((viewportHeight / longest * side).rounded()))
        let box = viewBox ?? (0, 0, viewportWidth, viewportHeight)
        let aspect = (attribute("preserveAspectRatio") ?? "").split(whereSeparator: { $0.isWhitespace })
        let align = aspect.first ?? "xMidYMid"
        var sx = Double(outW) / box.width, sy = Double(outH) / box.height
        var dx = 0.0, dy = 0.0
        if viewBox != nil, align != "none" {
            let scale = aspect.last == "slice" ? max(sx, sy) : min(sx, sy)
            sx = scale
            sy = scale
            let extraX = Double(outW) - box.width * scale
            let extraY = Double(outH) - box.height * scale
            dx = align.hasPrefix("xMin") ? 0 : (align.hasPrefix("xMax") ? extraX : extraX / 2)
            dy = align.hasSuffix("YMin") ? 0 : (align.hasSuffix("YMax") ? extraY : extraY / 2)
        }
        let transform = GTransform(xx: Float(sx), xy: 0, yx: 0, yy: Float(sy),
                                   tx: Float(dx - box.x * sx), ty: Float(dy - box.y * sy))
        guard transform.xx.isFinite, transform.yy.isFinite, transform.tx.isFinite, transform.ty.isFinite else {
            throw ImageLoadError("invalid SVG transform")
        }
        let drawing = SVGIconRenderer.parseBody(String(text[rootStart.lowerBound...]), defaultFill: "black")
        let bytes = SVGIconRenderer.rasterize(drawing, width: outW, height: outH, transform: transform, currentColor: .black)
        return (UInt32(outW), UInt32(outH), Data(bytes))
    }

    private static func svgLength(_ raw: String?) -> Double? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        for (unit, factor) in [("px", 1.0), ("pt", 96 / 72.0), ("pc", 16.0), ("in", 96.0),
                               ("cm", 96 / 2.54), ("mm", 96 / 25.4), ("Q", 96 / 101.6)] where value.hasSuffix(unit) {
            return Double(value.dropLast(unit.count)).map { $0 * factor }
        }
        return Double(value)
    }

    private static func iconPixels(sizePt: Float, scale: Float) -> UInt32 {
        let px = (max(1.0, sizePt) * max(1.0, scale)).rounded()
        return max(1, UInt32(px))
    }

    private static func percentDecodeUTF8(_ input: String) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(input.utf8.count)
        let utf8 = Array(input.utf8)
        var i = 0
        while i < utf8.count {
            let b = utf8[i]
            if b == 0x25 {
                guard i + 2 < utf8.count,
                      let hi = hexVal(utf8[i + 1]),
                      let lo = hexVal(utf8[i + 2]) else {
                    return nil
                }
                bytes.append((hi << 4) | lo)
                i += 3
            } else {
                bytes.append(b)
                i += 1
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func hexVal(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }
}
