import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
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
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
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
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Result<(UInt32, UInt32), ImageLoadError> {
        lock.lock()
        if let existing = outcome {
            lock.unlock()
            return existing
        }
        lock.unlock()
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        if let existing = outcome {
            return existing
        }
        if waitResult == .timedOut {
            return .failure(ImageLoadError("timed out waiting for image"))
        }
        return .failure(ImageLoadError("image load cancelled"))
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

    /// Blocks until the image finishes loading or `timeout` elapses (`Image::wait`).
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
    private let session: URLSession?
    private let remoteLoader: RemoteLoader?

    /// Number of live (handle or drawn `Pixels` still retained) entries currently tracked (`image.rs:760`).
    public var liveEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter { $0.state != nil }.count
    }

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

    /// Wraps raw straight-alpha RGBA8 bytes immediately without assigning a `sourceURLString` (`ImageCache::rgba`).
    public func rgba(width: UInt32, height: UInt32, data: [UInt8]) -> CachedImage {
        let raw = Data(data)
        let id = ImageId.contentHash(raw)
        let hexId = id.bytes.map { String(format: "%02x", $0) }.joined()
        let key = CacheKey(url: "rgba:\(width)x\(height):\(hexId)", pixelSize: max(width, height), srcset: nil)
        let handle: CachedImage
        var needResolve = false
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
                handle = CachedImage(id: id, pixels: pixels)
                entries[key] = WeakEntry(handle: handle, state: handle.state, pixels: pixels)
                needResolve = true
            }
        } else {
            let pixels = Pixels()
            handle = CachedImage(id: id, pixels: pixels)
            entries[key] = WeakEntry(handle: handle, state: handle.state, pixels: pixels)
            needResolve = true
        }
        lock.unlock()
        if needResolve {
            switch Self.land(url: "rgba", fetched: .rgba(width: width, height: height, data: raw), pixelSize: max(width, height)) {
            case .success(let decoded):
                handle.resolve(with: .success(decoded))
            case .failure(let err):
                handle.resolve(with: .failure(err))
            }
            wake()
        }
        return handle
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

        let wakeFn = self.wake
        let customLoader = self.remoteLoader
        let urlSession = self.session

        DispatchQueue.global(qos: .userInitiated).async {
            Self.executeLoad(
                url: url,
                pixelSize: pixelSize,
                handle: handle,
                session: urlSession,
                remoteLoader: customLoader,
                wake: wakeFn
            )
        }
        return handle
    }

    private static func executeLoad(
        url: String,
        pixelSize: UInt32,
        handle: CachedImage,
        session: URLSession?,
        remoteLoader: RemoteLoader?,
        wake: @escaping @Sendable () -> Void
    ) {
        switch filePath(for: url) {
        case .success(let path):
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let decoded = try decodeEncodedOrSVG(url: url, data: data, pixelSize: pixelSize)
                handle.resolve(with: .success(decoded))
            } catch let err as ImageLoadError {
                handle.resolve(with: .failure(err))
            } catch {
                handle.resolve(with: .failure(ImageLoadError("\(url): \(error.localizedDescription)")))
            }
            wake()
        case .failure(let nativeError):
            if let remoteLoader {
                Task {
                    do {
                        let fetched = try await remoteLoader(url, pixelSize)
                        handle.resolve(with: land(url: url, fetched: fetched, pixelSize: pixelSize))
                    } catch let err as ImageLoadError {
                        handle.resolve(with: .failure(err))
                    } catch {
                        handle.resolve(with: .failure(ImageLoadError("\(url): \(error.localizedDescription)")))
                    }
                    wake()
                }
                return
            }
            if let session, let parsedURL = URL(string: url) {
                let task = session.dataTask(with: parsedURL) { data, response, err in
                    if let err {
                        handle.resolve(with: .failure(ImageLoadError("\(url): \(err.localizedDescription)")))
                    } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        handle.resolve(with: .failure(ImageLoadError("\(url): HTTP \(http.statusCode)")))
                    } else if let data {
                        do {
                            let decoded = try decodeEncodedOrSVG(url: url, data: data, pixelSize: pixelSize)
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
            handle.resolve(with: .failure(nativeError))
            wake()
        }
    }

    private static func decodeEncodedOrSVG(url: String, data: Data, pixelSize: UInt32) throws -> DecodedImage {
        let looksSVG = url.lowercased().hasSuffix(".svg")
            || (String(data: data.prefix(256), encoding: .utf8)?.contains("<svg") == true)
        if looksSVG {
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

    private static func rasterizeSVG(_ data: Data, targetMaxSide: UInt32) throws -> (UInt32, UInt32, Data) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImageLoadError("SVG is not valid UTF-8")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("<svg"), trimmed.contains(">"), (trimmed.contains("</svg>") || trimmed.contains("/>")) else {
            throw ImageLoadError("malformed SVG document")
        }
        let svgTag = extractFirstTag(named: "svg", in: trimmed) ?? ""
        let attrW = parseNumericAttribute("width", in: svgTag)
        let attrH = parseNumericAttribute("height", in: svgTag)
        let vb = parseViewBox(in: svgTag)
        let srcW = max(1.0, attrW ?? vb?.2 ?? 16.0)
        let srcH = max(1.0, attrH ?? vb?.3 ?? 16.0)
        let scale = Float(max(1, targetMaxSide)) / max(srcW, srcH)
        let outW = max(1, UInt32((srcW * scale).rounded()))
        let outH = max(1, UInt32((srcH * scale).rounded()))
        guard outW <= IMAGE_MAX_SIDE, outH <= IMAGE_MAX_SIDE else {
            throw ImageLoadError("SVG rasterized size exceeds \(IMAGE_MAX_SIDE)")
        }

        var bytes = [UInt8](repeating: 0, count: Int(outW) * Int(outH) * 4)
        #if canImport(CoreGraphics)
        let cs = CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(
            data: &bytes,
            width: Int(outW),
            height: Int(outH),
            bitsPerComponent: 8,
            bytesPerRow: Int(outW) * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.scaleBy(x: CGFloat(outW) / CGFloat(srcW), y: CGFloat(outH) / CGFloat(srcH))
            if trimmed.contains("<rect") {
                for rectTag in extractAllTags(named: "rect", in: trimmed) {
                    let rx = parseNumericAttribute("x", in: rectTag) ?? 0
                    let ry = parseNumericAttribute("y", in: rectTag) ?? 0
                    let rw = parseNumericAttribute("width", in: rectTag) ?? srcW
                    let rh = parseNumericAttribute("height", in: rectTag) ?? srcH
                    let fill = parseHexColor(parseStringAttribute("fill", in: rectTag) ?? "#000")
                    ctx.setFillColor(red: CGFloat(fill.0), green: CGFloat(fill.1), blue: CGFloat(fill.2), alpha: CGFloat(fill.3))
                    ctx.fill(CGRect(x: CGFloat(rx), y: CGFloat(ry), width: CGFloat(rw), height: CGFloat(rh)))
                }
            } else {
                // Fallback path/shape silhouette rasterization via `SVGIcon` when SVG contains `<path>` elements.
                let paths = extractPathData(in: trimmed)
                if !paths.isEmpty {
                    let icon = SVGIcon(viewBox: max(srcW, srcH), paths: paths)
                    let cov = GlyphAtlas.rasterizeIconBitmap(icon, pixelSize: Int(max(outW, outH)))
                    for py in 0..<Int(outH) {
                        for px in 0..<Int(outW) {
                            let idx = (py * Int(max(outW, outH)) + px)
                            let a = idx < cov.count ? cov[idx] : 0
                            let dst = (py * Int(outW) + px) * 4
                            bytes[dst] = a; bytes[dst + 1] = a; bytes[dst + 2] = a; bytes[dst + 3] = a
                        }
                    }
                }
            }
        }
        #endif
        return (outW, outH, Data(bytes))
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

    private static func extractFirstTag(named tag: String, in xml: String) -> String? {
        extractAllTags(named: tag, in: xml).first
    }

    private static func extractAllTags(named tag: String, in xml: String) -> [String] {
        var out: [String] = []
        var searchStart = xml.startIndex
        let needle = "<\(tag)"
        while let r = xml.range(of: needle, range: searchStart..<xml.endIndex) {
            guard let end = xml[r.lowerBound...].firstIndex(of: ">") else { break }
            out.append(String(xml[r.lowerBound...end]))
            searchStart = xml.index(after: end)
        }
        return out
    }

    private static func parseStringAttribute(_ name: String, in tag: String) -> String? {
        for quote in ["\"", "'"] {
            let pattern = "\(name)=\(quote)"
            if let r = tag.range(of: pattern) {
                let rest = tag[r.upperBound...]
                if let end = rest.firstIndex(of: Character(quote)) {
                    return String(rest[..<end])
                }
            }
        }
        return nil
    }

    private static func parseNumericAttribute(_ name: String, in tag: String) -> Float? {
        guard let raw = parseStringAttribute(name, in: tag) else { return nil }
        let cleaned = raw.trimmingCharacters(in: CharacterSet.letters.union(.whitespaces))
        return Float(cleaned)
    }

    private static func parseViewBox(in tag: String) -> (Float, Float, Float, Float)? {
        guard let raw = parseStringAttribute("viewBox", in: tag) else { return nil }
        let nums = raw.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Float($0) }
        guard nums.count == 4 else { return nil }
        return (nums[0], nums[1], nums[2], nums[3])
    }

    private static func extractPathData(in xml: String) -> [String] {
        extractAllTags(named: "path", in: xml).compactMap { parseStringAttribute("d", in: $0) }
    }

    private static func parseHexColor(_ s: String) -> (Float, Float, Float, Float) {
        let hex = s.trimmingCharacters(in: .whitespaces).dropFirst(s.hasPrefix("#") ? 1 : 0)
        if hex.count == 3 {
            let chars = Array(hex)
            let r = Float(Int(String([chars[0], chars[0]]), radix: 16) ?? 0) / 255.0
            let g = Float(Int(String([chars[1], chars[1]]), radix: 16) ?? 0) / 255.0
            let b = Float(Int(String([chars[2], chars[2]]), radix: 16) ?? 0) / 255.0
            return (r, g, b, 1.0)
        }
        if hex.count == 6 || hex.count == 8 {
            let val = UInt32(hex, radix: 16) ?? 0
            if hex.count == 6 {
                return (
                    Float((val >> 16) & 0xFF) / 255.0,
                    Float((val >> 8) & 0xFF) / 255.0,
                    Float(val & 0xFF) / 255.0,
                    1.0
                )
            }
            return (
                Float((val >> 24) & 0xFF) / 255.0,
                Float((val >> 16) & 0xFF) / 255.0,
                Float((val >> 8) & 0xFF) / 255.0,
                Float(val & 0xFF) / 255.0
            )
        }
        return (1, 1, 1, 1)
    }
}
