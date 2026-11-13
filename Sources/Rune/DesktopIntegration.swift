import Foundation
import RuneMotion
import RuneRef

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(macOS)
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#elseif canImport(UIKit)
import UIKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#elseif canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

// MARK: - 1. Rich Clipboard & Secret Pasteboard

/// PNG-encoded image payload for clipboard and drag-out operations (`rune::clipboard::ClipboardImage`).
public struct ClipboardImage: Sendable, Equatable {
    public let width: UInt32
    public let height: UInt32
    public let pngData: Data

    public static let maxImageBytes: Int = 32 * 1024 * 1024
    public static let maxImagePixels: UInt64 = 64 * 1024 * 1024

    public init(width: UInt32, height: UInt32, pngData: Data) {
        self.width = width
        self.height = height
        self.pngData = pngData
    }

    /// Encodes straight-alpha RGBA8 pixels into PNG data. Returns `nil` if dimensions or byte count are invalid.
    public static func fromRGBA(width: UInt32, height: UInt32, rgba: Data) -> ClipboardImage? {
        guard width > 0, height > 0 else { return nil }
        let pixelCount = UInt64(width) * UInt64(height)
        guard pixelCount <= maxImagePixels else { return nil }
        guard rgba.count == Int(pixelCount) * 4 else { return nil }
        guard let png = encodeRGBAAsPNG(width: Int(width), height: Int(height), rgba: rgba),
              png.count <= maxImageBytes else {
            return nil
        }
        return ClipboardImage(width: width, height: height, pngData: png)
    }

    /// Decodes PNG data into straight-alpha RGBA8 bytes, if valid.
    public func decodeRGBA() -> Data? {
        Self.decodeImageDataToRGBA(pngData)?.rgba
    }

    static func encodeRGBAAsPNG(width: Int, height: Int, rgba: Data) -> Data? {
        #if canImport(ImageIO)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let provider = CGDataProvider(data: rgba as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutable as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutable as Data
        #else
        return try? PortablePNG.encode(width: width, height: height, rgba: Array(rgba))
        #endif
    }

    static func decodeImageDataToRGBA(_ data: Data) -> (width: Int, height: Int, rgba: Data)? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0, UInt64(w) * UInt64(h) <= maxImagePixels else { return nil }
        var out = Data(count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let ok = out.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: w,
                      height: h,
                      bitsPerComponent: 8,
                      bytesPerRow: w * 4,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo.rawValue
                  ) else {
                return false
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (w, h, out) : nil
        #else
        if let decoded = try? PortablePNG.decode(data) {
            return (decoded.width, decoded.height, Data(decoded.rgba))
        }
        return nil
        #endif
    }
}

/// Full rich clipboard payload supporting plain text, HTML, RTF, PNG image, file URLs,
/// custom MIME/UTI payloads, and concealed/secret pasteboard tagging.
public struct RichClipboardPayload: Sendable, Equatable {
    public var content: ClipboardContent
    public var image: ClipboardImage?
    public var files: [URL]
    public var customPayloads: [String: Data]
    public var isConcealed: Bool

    public init(
        text: String = "",
        html: String? = nil,
        rtf: String? = nil,
        image: ClipboardImage? = nil,
        files: [URL] = [],
        customPayloads: [String: Data] = [:],
        isConcealed: Bool = false
    ) {
        self.content = ClipboardContent(text, html: html, rtf: rtf, image: image)
        self.image = image
        self.files = files
        self.customPayloads = customPayloads
        self.isConcealed = isConcealed
    }

    public init(
        content: ClipboardContent,
        image: ClipboardImage? = nil,
        files: [URL] = [],
        customPayloads: [String: Data] = [:],
        isConcealed: Bool = false
    ) {
        self.content = content
        self.image = image
        self.files = files
        self.customPayloads = customPayloads
        self.isConcealed = isConcealed
    }

    public var isRich: Bool {
        content.html != nil || content.rtf != nil || image != nil || !files.isEmpty || !customPayloads.isEmpty
    }

    public var isEmpty: Bool {
        content.text.isEmpty && !isRich
    }

    /// Strips `<script>`, `<iframe>`, `<object>`, `<embed>`, and `on*` event attributes from untrusted HTML.
    public static func sanitizeHTML(_ html: String) -> String {
        var result = html
        let dangerousTags = ["script", "iframe", "object", "embed", "style"]
        for tag in dangerousTags {
            let pattern = "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>"
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            let selfClosing = "(?is)<\(tag)\\b[^>]*/>"
            result = result.replacingOccurrences(of: selfClosing, with: "", options: .regularExpression)
        }
        result = result.replacingOccurrences(
            of: "(?is)\\s+on[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?is)javascript\\s*:",
            with: "",
            options: .regularExpression
        )
        return result
    }
}

/// Lifecycle state of a secret/concealed clipboard write (`rune::clipboard::SecretState`).
public enum SecretState: Sendable, Equatable {
    case pending
    case holding
    case cleared
    case replaced
    case failed(String)
}

/// Handle to a concealed/secret clipboard item that can auto-expire or be cleared explicitly.
public final class SecretClipboardHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: SecretState
    private weak var clipboard: Clipboard?
    private let writtenChangeCount: Int

    init(state: SecretState, clipboard: Clipboard?, changeCount: Int) {
        self._state = state
        self.clipboard = clipboard
        self.writtenChangeCount = changeCount
    }

    public var state: SecretState {
        lock.lock()
        defer { lock.unlock() }
        if _state == .holding, let cb = clipboard, cb.changeCount != writtenChangeCount {
            _state = .replaced
        }
        return _state
    }

    func markCleared() {
        lock.lock()
        _state = .cleared
        lock.unlock()
    }

    func markReplaced() {
        lock.lock()
        if _state == .holding || _state == .pending {
            _state = .replaced
        }
        lock.unlock()
    }

    /// Clears the clipboard immediately if it still holds this secret item.
    @discardableResult
    public func clearNow() -> Bool {
        lock.lock()
        let current = _state
        lock.unlock()
        guard current == .holding else { return false }
        guard let cb = clipboard else { return false }
        if cb.changeCount != writtenChangeCount {
            markReplaced()
            return false
        }
        cb.clear()
        markCleared()
        return true
    }
}

/// Cross-platform clipboard supporting macOS `NSPasteboard` (including `org.nspasteboard.ConcealedType`)
/// and an in-memory headless backend for deterministic tests.
public final class Clipboard: @unchecked Sendable {
    public enum BackendKind: Sendable, Equatable {
        case system
        case memory
    }

    /// Standard pasteboard marker type recognized by macOS clipboard managers to exclude secrets from history.
    public static let concealedPasteboardType = "org.nspasteboard.ConcealedType"

    public static let shared = Clipboard(kind: .system)

    public let kind: BackendKind
    private let lock = NSLock()
    private var memoryPayload = RichClipboardPayload()
    private var memoryChangeCount: Int = 0
    private var activeSecret: SecretClipboardHandle?

    public init(kind: BackendKind = .memory) {
        self.kind = kind
    }

    public var changeCount: Int {
        switch kind {
        case .memory:
            lock.lock()
            defer { lock.unlock() }
            return memoryChangeCount
        case .system:
            #if os(macOS)
            return NSPasteboard.general.changeCount
            #elseif canImport(UIKit) && !os(watchOS)
            return UIPasteboard.general.changeCount
            #else
            lock.lock()
            defer { lock.unlock() }
            return memoryChangeCount
            #endif
        }
    }

    public func writeText(_ text: String) {
        writeRich(RichClipboardPayload(text: text))
    }

    public func writeRich(_ payload: RichClipboardPayload) {
        lock.lock()
        activeSecret?.markReplaced()
        activeSecret = nil
        lock.unlock()

        switch kind {
        case .memory:
            lock.lock()
            memoryPayload = payload
            memoryChangeCount += 1
            lock.unlock()
        case .system:
            #if os(macOS)
            let pb = NSPasteboard.general
            pb.clearContents()
            var types: [NSPasteboard.PasteboardType] = []
            if !payload.content.text.isEmpty || !payload.isRich {
                types.append(.string)
            }
            if payload.content.html != nil { types.append(.html) }
            if payload.content.rtf != nil { types.append(.rtf) }
            if payload.image != nil { types.append(.png) }
            if !payload.files.isEmpty { types.append(.fileURL) }
            for customType in payload.customPayloads.keys {
                types.append(NSPasteboard.PasteboardType(customType))
            }
            if payload.isConcealed {
                types.append(NSPasteboard.PasteboardType(Self.concealedPasteboardType))
            }
            pb.declareTypes(types, owner: nil)
            if !payload.content.text.isEmpty || !payload.isRich {
                pb.setString(payload.content.text, forType: .string)
            }
            if let html = payload.content.html {
                pb.setString(html, forType: .html)
            }
            if let rtf = payload.content.rtf {
                pb.setString(rtf, forType: .rtf)
            }
            if let img = payload.image {
                pb.setData(img.pngData, forType: .png)
            }
            if !payload.files.isEmpty {
                pb.writeObjects(payload.files as [NSURL])
            }
            for (customType, data) in payload.customPayloads {
                pb.setData(data, forType: NSPasteboard.PasteboardType(customType))
            }
            if payload.isConcealed {
                pb.setData(Data(), forType: NSPasteboard.PasteboardType(Self.concealedPasteboardType))
            }
            #elseif canImport(UIKit) && !os(watchOS)
            let pb = UIPasteboard.general
            var item: [String: Any] = [:]
            if !payload.content.text.isEmpty || !payload.isRich {
                item[UTType.utf8PlainText.identifier] = payload.content.text
            }
            if let html = payload.content.html {
                item[UTType.html.identifier] = html
            }
            if let rtf = payload.content.rtf {
                item[UTType.rtf.identifier] = rtf
            }
            if let img = payload.image {
                item[UTType.png.identifier] = img.pngData
            }
            if let firstURL = payload.files.first {
                item[UTType.fileURL.identifier] = firstURL
            }
            for (customType, data) in payload.customPayloads {
                item[customType] = data
            }
            if payload.isConcealed {
                item[Self.concealedPasteboardType] = Data()
            }
            pb.items = item.isEmpty ? [] : [item]
            #else
            lock.lock()
            memoryPayload = payload
            memoryChangeCount += 1
            lock.unlock()
            #endif
        }
    }

    /// Writes a concealed/secret text item (tagged with `org.nspasteboard.ConcealedType` on macOS)
    /// and optionally schedules automatic clearing after `ttlSeconds`.
    @discardableResult
    public func writeSecret(_ text: String, ttlSeconds: Double? = nil) -> SecretClipboardHandle {
        let payload = RichClipboardPayload(text: text, isConcealed: true)
        writeRich(payload)
        let handle = SecretClipboardHandle(state: .holding, clipboard: self, changeCount: changeCount)
        lock.lock()
        activeSecret = handle
        lock.unlock()
        if let ttl = ttlSeconds, ttl > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ttl) {
                _ = handle.clearNow()
            }
        }
        return handle
    }

    public func readRich(sanitizeUntrustedHTML: Bool = true) -> RichClipboardPayload {
        switch kind {
        case .memory:
            lock.lock()
            var p = memoryPayload
            lock.unlock()
            if sanitizeUntrustedHTML, let html = p.content.html {
                p.content.html = RichClipboardPayload.sanitizeHTML(html)
            }
            return p
        case .system:
            #if os(macOS)
            let pb = NSPasteboard.general
            let text = pb.string(forType: .string) ?? ""
            var html = pb.string(forType: .html)
            if sanitizeUntrustedHTML, let h = html {
                html = RichClipboardPayload.sanitizeHTML(h)
            }
            let rtf = pb.string(forType: .rtf)
            var image: ClipboardImage? = nil
            if let png = pb.data(forType: .png) ?? pb.data(forType: .tiff),
               let decoded = ClipboardImage.decodeImageDataToRGBA(png),
               let normalizedPNG = ClipboardImage.encodeRGBAAsPNG(width: decoded.width, height: decoded.height, rgba: decoded.rgba) {
                image = ClipboardImage(width: UInt32(decoded.width), height: UInt32(decoded.height), pngData: normalizedPNG)
            }
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
            let concealed = pb.types?.contains(NSPasteboard.PasteboardType(Self.concealedPasteboardType)) ?? false
            var customs: [String: Data] = [:]
            if let types = pb.types {
                let standard: Set<String> = [
                    NSPasteboard.PasteboardType.string.rawValue,
                    NSPasteboard.PasteboardType.html.rawValue,
                    NSPasteboard.PasteboardType.rtf.rawValue,
                    NSPasteboard.PasteboardType.png.rawValue,
                    NSPasteboard.PasteboardType.tiff.rawValue,
                    NSPasteboard.PasteboardType.fileURL.rawValue,
                    Self.concealedPasteboardType,
                ]
                for t in types where !standard.contains(t.rawValue) {
                    if let d = pb.data(forType: t) {
                        customs[t.rawValue] = d
                    }
                }
            }
            return RichClipboardPayload(
                text: text,
                html: html,
                rtf: rtf,
                image: image,
                files: urls,
                customPayloads: customs,
                isConcealed: concealed
            )
            #elseif canImport(UIKit) && !os(watchOS)
            let pb = UIPasteboard.general
            let text = pb.string ?? ""
            var html: String? = nil
            if let hData = pb.data(forPasteboardType: UTType.html.identifier),
               let h = String(data: hData, encoding: .utf8) {
                html = sanitizeUntrustedHTML ? RichClipboardPayload.sanitizeHTML(h) : h
            }
            var rtf: String? = nil
            if let rData = pb.data(forPasteboardType: UTType.rtf.identifier),
               let r = String(data: rData, encoding: .utf8) {
                rtf = r
            }
            var image: ClipboardImage? = nil
            if let png = pb.data(forPasteboardType: UTType.png.identifier),
               let decoded = ClipboardImage.decodeImageDataToRGBA(png),
               let normalizedPNG = ClipboardImage.encodeRGBAAsPNG(width: decoded.width, height: decoded.height, rgba: decoded.rgba) {
                image = ClipboardImage(width: UInt32(decoded.width), height: UInt32(decoded.height), pngData: normalizedPNG)
            }
            let urls = pb.urls ?? []
            let concealed = pb.contains(pasteboardTypes: [Self.concealedPasteboardType])
            return RichClipboardPayload(
                text: text,
                html: html,
                rtf: rtf,
                image: image,
                files: urls,
                customPayloads: [:],
                isConcealed: concealed
            )
            #else
            lock.lock()
            defer { lock.unlock() }
            return memoryPayload
            #endif
        }
    }

    public func readCustomPayload(type: String) -> Data? {
        switch kind {
        case .memory:
            lock.lock()
            defer { lock.unlock() }
            return memoryPayload.customPayloads[type]
        case .system:
            #if os(macOS)
            return NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(type))
            #elseif canImport(UIKit) && !os(watchOS)
            return UIPasteboard.general.data(forPasteboardType: type)
            #else
            lock.lock()
            defer { lock.unlock() }
            return memoryPayload.customPayloads[type]
            #endif
        }
    }

    public func clear() {
        lock.lock()
        activeSecret?.markCleared()
        activeSecret = nil
        lock.unlock()
        switch kind {
        case .memory:
            lock.lock()
            memoryPayload = RichClipboardPayload()
            memoryChangeCount += 1
            lock.unlock()
        case .system:
            #if os(macOS)
            NSPasteboard.general.clearContents()
            #elseif canImport(UIKit) && !os(watchOS)
            UIPasteboard.general.items = []
            #else
            lock.lock()
            memoryPayload = RichClipboardPayload()
            memoryChangeCount += 1
            lock.unlock()
            #endif
        }
    }
}

// MARK: - 2. Drag Out & File Drop

/// Allowed OS drag operations (`rune::drag_out::DragOperation`).
public struct DragOperation: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let copy = DragOperation(rawValue: 1 << 0)
    public static let move = DragOperation(rawValue: 1 << 1)
    public static let link = DragOperation(rawValue: 1 << 2)
    public static let generic = DragOperation(rawValue: 1 << 3)
}

/// Outcome of an outbound OS drag session (`rune::drag_out::DragOutcome`).
public enum DragOutcome: Sendable, Equatable {
    case copied
    case moved
    case linked
    case cancelled
}

/// Custom image preview shown under the cursor during an OS drag session (`rune::drag_out::DragImage`).
public struct DragImage: Sendable, Equatable {
    public enum Placement: Sendable, Equatable {
        case pointer
        case element
        case at(Vec2)
    }

    public var width: UInt32
    public var height: UInt32
    public var rgba: Data
    public var hotspot: Vec2
    public var pngData: Data?
    public var pointsSize: Vec2?
    public var placement: Placement

    public init(width: UInt32, height: UInt32, rgba: Data, hotspot: Vec2 = .zero) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.hotspot = hotspot
        self.pngData = nil
        self.pointsSize = nil
        self.placement = .pointer
    }

    private init(
        width: UInt32,
        height: UInt32,
        rgba: Data,
        hotspot: Vec2,
        pngData: Data?,
        pointsSize: Vec2?,
        placement: Placement
    ) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.hotspot = hotspot
        self.pngData = pngData
        self.pointsSize = pointsSize
        self.placement = placement
    }

    public static func png(_ data: Data) -> DragImage {
        let decoded = ClipboardImage.decodeImageDataToRGBA(data)
        return DragImage(
            width: UInt32(decoded?.width ?? 0),
            height: UInt32(decoded?.height ?? 0),
            rgba: decoded?.rgba ?? Data(),
            hotspot: .zero,
            pngData: data,
            pointsSize: nil,
            placement: .pointer
        )
    }

    public static func rgba(width: UInt32, height: UInt32, pixels: Data) -> DragImage? {
        guard width > 0, height > 0, pixels.count >= Int(width) * Int(height) * 4,
              let png = ClipboardImage.encodeRGBAAsPNG(width: Int(width), height: Int(height), rgba: pixels) else {
            return nil
        }
        return DragImage(
            width: width,
            height: height,
            rgba: pixels,
            hotspot: .zero,
            pngData: png,
            pointsSize: nil,
            placement: .pointer
        )
    }

    public func size(_ width: Float, _ height: Float) -> DragImage {
        var copy = self
        copy.pointsSize = Vec2(width, height)
        return copy
    }

    public func overElement() -> DragImage {
        var copy = self
        copy.placement = .element
        return copy
    }

    public func at(_ point: Vec2) -> DragImage {
        var copy = self
        copy.placement = .at(point)
        return copy
    }
}

/// Payload carried by an outbound OS drag session (`rune::drag_out::DragItem`).
public struct DragItem: Sendable, Equatable {
    public static let defaultThreshold: Float = 4.0

    public var files: [URL] = []
    public var pngData: Data? = nil
    public var text: String? = nil
    public var image: DragImage? = nil
    public var operations: DragOperation = .copy
    public var backingColor: Color? = nil
    public var withinApp: Bool = false

    public init() {}

    public func file(_ url: URL) -> DragItem {
        var copy = self
        copy.files.append(url)
        return copy
    }

    public func file(path: String) -> DragItem {
        file(URL(fileURLWithPath: path))
    }

    public func png(_ data: Data) -> DragItem {
        var copy = self
        copy.pngData = data
        return copy
    }

    public func rgba(width: UInt32, height: UInt32, pixels: Data) -> DragItem {
        guard let img = ClipboardImage.fromRGBA(width: width, height: height, rgba: pixels) else {
            return self
        }
        return png(img.pngData)
    }

    public func text(_ value: String) -> DragItem {
        var copy = self
        copy.text = value
        return copy
    }

    public func image(_ dragImage: DragImage) -> DragItem {
        var copy = self
        copy.image = dragImage
        return copy
    }

    public func opaque(_ color: Color) -> DragItem {
        var copy = self
        copy.backingColor = color.alpha(1.0)
        return copy
    }

    public func operation(_ op: DragOperation) -> DragItem {
        var copy = self
        copy.operations = op
        return copy
    }

    public func allow(_ op: DragOperation) -> DragItem {
        var copy = self
        copy.operations = copy.operations.union(op)
        return copy
    }

    public func allowMove() -> DragItem {
        allow(.move)
    }

    public func withinApp(_ allow: Bool = true) -> DragItem {
        allowWithinApp(allow)
    }

    public func allowWithinApp(_ allow: Bool = true) -> DragItem {
        var copy = self
        copy.withinApp = allow
        return copy
    }

    public var paths: [URL] { files }
    public var plainText: String? { text }
    public var dragImage: DragImage? { image }
    public var allowsMove: Bool { operations.contains(.move) }
    public var dropsWithinApp: Bool { withinApp }
    public var backing: Color? { backingColor }
    public var isEmpty: Bool { files.isEmpty && pngData == nil && text == nil }

    public func offers(_ op: DragOperation) -> Bool {
        operations.contains(op)
    }

    public static func pastThreshold(from: Vec2, to: Vec2, threshold: Float = defaultThreshold) -> Bool {
        let dx = to.x - from.x
        let dy = to.y - from.y
        return dx * dx + dy * dy > threshold * threshold
    }
}

/// A file dropped onto a Rune window (`rune::DroppedFile`).
public struct DroppedFile: Sendable, Equatable, Codable {
    public let path: String
    public let name: String
    public let sizeBytes: UInt64?

    public var url: URL { URL(fileURLWithPath: path) }

    public init(url: URL, sizeBytes: UInt64? = nil) {
        self.path = url.path
        self.name = url.lastPathComponent
        if let sizeBytes {
            self.sizeBytes = sizeBytes
        } else {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            self.sizeBytes = attrs?[.size] as? UInt64
        }
    }

    public init(path: String, name: String? = nil, sizeBytes: UInt64? = nil) {
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.sizeBytes = sizeBytes
    }
}

/// Inbound OS file-drop event delivered to `Runtime`.
public enum FileDropPhase: Sendable, Equatable {
    case entered([DroppedFile], at: Vec2)
    case hovered(at: Vec2)
    case dropped([DroppedFile], at: Vec2)
    case exited
}

/// Tracks active file-drop hover state and pending outbound drag sessions.
public final class FileDropState: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var isHovering: Bool = false
    public private(set) var hoverPosition: Vec2? = nil
    public private(set) var hoveredFiles: [DroppedFile] = []
    public private(set) var lastDroppedFiles: [DroppedFile] = []
    public private(set) var lastDropPosition: Vec2? = nil
    public private(set) var lastDragOutItem: DragItem? = nil

    public init() {}

    public func handle(_ phase: FileDropPhase) {
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .entered(let files, let at):
            isHovering = true
            hoveredFiles = files
            hoverPosition = at
        case .hovered(let at):
            isHovering = true
            hoverPosition = at
        case .dropped(let files, let at):
            isHovering = false
            hoveredFiles = []
            hoverPosition = at
            lastDroppedFiles = files
            lastDropPosition = at
        case .exited:
            isHovering = false
            hoveredFiles = []
            hoverPosition = nil
        }
    }

    public func recordOutboundDrag(_ item: DragItem) {
        lock.lock()
        lastDragOutItem = item
        lock.unlock()
    }
}

// MARK: - 3. File Dialogs

public struct FileDialogFilter: Sendable, Equatable {
    public var name: String
    public var extensions: [String]

    public init(name: String, extensions: [String]) {
        self.name = name
        self.extensions = extensions
    }
}

public enum FileDialogKind: String, Sendable, Equatable {
    case open
    case save
    case folder
}

public struct FileDialogOptions: Sendable, Equatable {
    public var title: String
    public var directory: URL?
    public var fileName: String?
    public var filters: [FileDialogFilter]
    public var allowsMultipleSelection: Bool

    public init(
        title: String = "",
        directory: URL? = nil,
        fileName: String? = nil,
        filters: [FileDialogFilter] = [],
        allowsMultipleSelection: Bool = false
    ) {
        self.title = title
        self.directory = directory
        self.fileName = fileName
        self.filters = filters
        self.allowsMultipleSelection = allowsMultipleSelection
    }

    public func filter(_ name: String, extensions: [String]) -> FileDialogOptions {
        var copy = self
        copy.filters.append(FileDialogFilter(name: name, extensions: extensions))
        return copy
    }
}

public struct FileDialogError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct ScriptedFileDialog: Sendable, Equatable {
    public let kind: FileDialogKind
    public let urls: [URL]?

    public init(kind: FileDialogKind, url: URL?) {
        self.kind = kind
        self.urls = url.map { [$0] }
    }

    public init(kind: FileDialogKind, urls: [URL]?) {
        self.kind = kind
        self.urls = urls
    }
}

/// File dialog runner backed by `NSOpenPanel`/`NSSavePanel` on macOS and a programmable
/// scripted queue for deterministic headless tests.
public final class FileDialog: @unchecked Sendable {
    public enum Mode: @unchecked Sendable {
        case native
        case scripted([ScriptedFileDialog])
    }

    private let lock = NSLock()
    private let isNative: Bool
    private var queue: [ScriptedFileDialog]

    public static func native() -> FileDialog {
        FileDialog(isNative: true, queue: [])
    }

    public static func scripted(_ responses: [ScriptedFileDialog]) -> FileDialog {
        FileDialog(isNative: false, queue: responses)
    }

    private init(isNative: Bool, queue: [ScriptedFileDialog]) {
        self.isNative = isNative
        self.queue = queue
    }

    public func enqueue(_ response: ScriptedFileDialog) {
        lock.lock()
        queue.append(response)
        lock.unlock()
    }

    @MainActor
    public func open(_ options: FileDialogOptions = FileDialogOptions()) async throws -> [URL]? {
        try await show(kind: .open, options: options)
    }

    @MainActor
    public func save(_ options: FileDialogOptions = FileDialogOptions()) async throws -> URL? {
        let urls = try await show(kind: .save, options: options)
        return urls?.first
    }

    @MainActor
    public func openFolder(_ options: FileDialogOptions = FileDialogOptions()) async throws -> URL? {
        let urls = try await show(kind: .folder, options: options)
        return urls?.first
    }

    /// Synchronous scripted-only helper for deterministic unit tests without async suspension.
    public func runScripted(kind: FileDialogKind, options: FileDialogOptions = FileDialogOptions()) throws -> [URL]? {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else {
            throw FileDialogError("file dialog fixture exhausted")
        }
        let next = queue[0]
        guard next.kind == kind else {
            let exp = next.kind.rawValue.prefix(1).uppercased() + next.kind.rawValue.dropFirst()
            let got = kind.rawValue.prefix(1).uppercased() + kind.rawValue.dropFirst()
            throw FileDialogError("expected \(exp) dialog, received \(got)")
        }
        queue.removeFirst()
        return next.urls
    }

    @MainActor
    private func show(kind: FileDialogKind, options: FileDialogOptions) async throws -> [URL]? {
        if !isNative {
            return try runScripted(kind: kind, options: options)
        }
        #if os(macOS)
        switch kind {
        case .open, .folder:
            let panel = NSOpenPanel()
            panel.title = options.title
            panel.directoryURL = options.directory
            panel.canChooseFiles = (kind == .open)
            panel.canChooseDirectories = (kind == .folder)
            panel.allowsMultipleSelection = (kind == .open) && options.allowsMultipleSelection
            if kind == .open && !options.filters.isEmpty {
                let exts = options.filters.flatMap(\.extensions)
                panel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
            }
            let response = panel.runModal()
            return response == .OK ? panel.urls : nil
        case .save:
            let panel = NSSavePanel()
            panel.title = options.title
            panel.directoryURL = options.directory
            if let name = options.fileName {
                panel.nameFieldStringValue = name
            }
            if !options.filters.isEmpty {
                let exts = options.filters.flatMap(\.extensions)
                panel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
            }
            let response = panel.runModal()
            if response == .OK, let url = panel.url {
                return [url]
            }
            return nil
        }
        #else
        throw FileDialogError("native file dialogs are unsupported on this platform")
        #endif
    }
}

// MARK: - 4. Open URL

public enum OpenUrlError: Error, Sendable, Equatable, CustomStringConvertible {
    case empty
    case invalid
    case unsupportedScheme(String)
    case failed(String)

    public var description: String {
        switch self {
        case .empty: return "empty link"
        case .invalid: return "not a valid link"
        case .unsupportedScheme(let s): return "links with the \(s): scheme can't be opened"
        case .failed(let why): return "couldn't open the link: \(why)"
        }
    }
}

public struct OpenUrlRequest: Sendable, Equatable {
    public let url: String
    public let sameTab: Bool

    public init(url: String, sameTab: Bool = false) {
        self.url = url
        self.sameTab = sameTab
    }
}

public final class UrlOpener: @unchecked Sendable {
    public static let maxLength = 8192

    private let lock = NSLock()
    private var recordedRequests: [OpenUrlRequest] = []
    public var headless: Bool

    public init(headless: Bool = false) {
        self.headless = headless
    }

    public static func validate(_ raw: String) throws -> String {
        try checkLink(raw, relative: false)
    }

    public static func checkSameTab(_ raw: String) throws -> String {
        #if os(WASI)
        return try checkLink(raw, relative: true)
        #else
        return try checkLink(raw, relative: false)
        #endif
    }

    /// Validates an outbound or web same-tab link (`open_url::check_same_tab`).
    public static func validateSameTab(_ raw: String, allowRelative: Bool = false) throws -> String {
        try checkLink(raw, relative: allowRelative)
    }

    internal static func checkLink(_ raw: String, relative: Bool) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenUrlError.empty }
        let utf8 = Array(trimmed.utf8)
        let forbiddenChars = CharacterSet(charactersIn: "\\\"<>`^{|}")
        let hasBadScalar = trimmed.unicodeScalars.contains { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
                || forbiddenChars.contains(scalar)
        }
        if utf8.count > maxLength || hasBadScalar || badPercent(utf8) {
            throw OpenUrlError.invalid
        }
        if relative {
            if let idx = trimmed.firstIndex(where: { $0 == ":" || $0 == "/" || $0 == "?" || $0 == "#" }) {
                if trimmed[idx] != ":" {
                    return trimmed
                }
            } else {
                return trimmed
            }
        }
        guard let colonIdx = trimmed.firstIndex(of: ":") else {
            throw OpenUrlError.invalid
        }
        let rawScheme = String(trimmed[..<colonIdx])
        let scheme = rawScheme.lowercased()
        let rest = String(trimmed[trimmed.index(after: colonIdx)...])
        guard
            let first = scheme.first,
            first.isASCII,
            first.isLetter,
            scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") })
        else {
            throw OpenUrlError.invalid
        }
        switch scheme {
        case "http", "https":
            guard rest.hasPrefix("//") else { throw OpenUrlError.invalid }
            let after = rest.dropFirst(2)
            let tailStart = after.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? after.endIndex
            let authority = String(after[..<tailStart])
            let tail = after[tailStart...]
            if tail.contains("[") || tail.contains("]") || !validAuthority(authority) {
                throw OpenUrlError.invalid
            }
        case "mailto":
            if rest.isEmpty || rest.hasPrefix("//") || rest.contains("[") || rest.contains("]") {
                throw OpenUrlError.invalid
            }
        default:
            throw OpenUrlError.unsupportedScheme(scheme)
        }
        return "\(scheme):\(rest)"
    }

    private static func badPercent(_ bytes: [UInt8]) -> Bool {
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25 {
                guard i + 2 < bytes.count else { return true }
                let a = bytes[i + 1]
                let b = bytes[i + 2]
                if !isAsciiHexDigit(a) || !isAsciiHexDigit(b) || (a == 0x30 && b == 0x30) {
                    return true
                }
                i += 3
            } else {
                i += 1
            }
        }
        return false
    }

    private static func isAsciiHexDigit(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x46).contains(b) || (0x61...0x66).contains(b)
    }

    private static func validAuthority(_ authority: String) -> Bool {
        let hostPort: String
        if let atIdx = authority.lastIndex(of: "@") {
            let userinfo = authority[..<atIdx]
            if userinfo.isEmpty || userinfo.contains("[") || userinfo.contains("]") || userinfo.contains("@") {
                return false
            }
            hostPort = String(authority[authority.index(after: atIdx)...])
        } else {
            hostPort = authority
        }

        let port: String?
        if hostPort.hasPrefix("[") {
            let rest = hostPort.dropFirst()
            guard let closeIdx = rest.firstIndex(of: "]") else { return false }
            let ipv6 = rest[..<closeIdx]
            let portPart = rest[rest.index(after: closeIdx)...]
            guard
                ipv6.count >= 2,
                ipv6.contains(":"),
                !ipv6.hasPrefix("."),
                !ipv6.contains(".."),
                ipv6.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") })
            else {
                return false
            }
            if !portPart.isEmpty && !portPart.hasPrefix(":") {
                return false
            }
            port = portPart.hasPrefix(":") ? String(portPart.dropFirst()) : nil
        } else if hostPort.contains("[") || hostPort.contains("]") {
            return false
        } else {
            let host: String
            if let colonIdx = hostPort.firstIndex(of: ":") {
                host = String(hostPort[..<colonIdx])
                port = String(hostPort[hostPort.index(after: colonIdx)...])
            } else {
                host = hostPort
                port = nil
            }
            if host.isEmpty || host.hasPrefix(".") || host.contains("..") || host.contains("%") || host.contains(":") {
                return false
            }
        }

        if let p = port {
            return !p.isEmpty && p.allSatisfy { $0.isASCII && $0.isNumber } && UInt16(p) != nil
        }
        return true
    }

    internal static func percentEncodeNonAscii(_ url: String) -> String {
        let utf8 = url.utf8
        if utf8.allSatisfy({ $0 < 0x80 }) { return url }
        var out = ""
        out.reserveCapacity(utf8.count + 16)
        for byte in utf8 {
            if byte < 0x80 {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }
    @discardableResult
    public func open(_ raw: String, sameTab: Bool = false) throws -> String {
        let normalized = sameTab ? try Self.checkSameTab(raw) : try Self.validate(raw)
        let req = OpenUrlRequest(url: normalized, sameTab: sameTab)
        if headless {
            lock.lock()
            recordedRequests.append(req)
            lock.unlock()
            return normalized
        }
        #if os(macOS)
        let ascii = Self.percentEncodeNonAscii(normalized)
        guard let nsUrl = URL(string: ascii) else {
            throw OpenUrlError.invalid
        }
        guard NSWorkspace.shared.open(nsUrl) else {
            throw OpenUrlError.failed("no app opened it")
        }
        return normalized
        #elseif canImport(UIKit) && !os(watchOS)
        guard let nsUrl = URL(string: normalized) else {
            throw OpenUrlError.failed("Invalid URL \(normalized)")
        }
        Task { @MainActor in
            UIApplication.shared.open(nsUrl, options: [:], completionHandler: nil)
        }
        return normalized
        #else
        lock.lock()
        recordedRequests.append(req)
        lock.unlock()
        return normalized
        #endif
    }

    public func takeRequests() -> [OpenUrlRequest] {
        lock.lock()
        defer { lock.unlock() }
        let out = recordedRequests
        recordedRequests.removeAll()
        return out
    }
}

// MARK: - 5. Popup Menu & Native Menu

public struct PopupMenuItem: Sendable, Equatable {
    public var id: String
    public var title: String
    public var enabled: Bool
    public var checked: Bool
    public var keyEquivalent: String?
    public var symbolName: String?

    public init(
        id: String,
        title: String,
        enabled: Bool = true,
        checked: Bool = false,
        keyEquivalent: String? = nil,
        symbolName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.enabled = enabled
        self.checked = checked
        self.keyEquivalent = keyEquivalent
        self.symbolName = symbolName
    }
}

public indirect enum PopupMenuEntry: Sendable, Equatable {
    case item(PopupMenuItem)
    case separator
    case submenu(title: String, menu: PopupMenu, enabled: Bool)
}

public struct PopupMenu: Sendable, Equatable {
    public var entries: [PopupMenuEntry]
    public var selectedId: String?

    public init(entries: [PopupMenuEntry] = [], selectedId: String? = nil) {
        self.entries = entries
        self.selectedId = selectedId
    }

    public static func picker(_ choices: [(String, String)], selected: String? = nil) -> PopupMenu {
        var menu = PopupMenu(
            entries: choices.map { pair in
                .item(PopupMenuItem(id: pair.0, title: pair.1, checked: selected == pair.0))
            },
            selectedId: selected
        )
        if let selected {
            menu = menu.selected(selected)
        }
        return menu
    }

    public static func picker(_ choices: [PopupMenuItem], selected: String? = nil) -> PopupMenu {
        let entries: [PopupMenuEntry] = choices.map { item in
            var copy = item
            if let selected, copy.id == selected {
                copy.checked = true
            }
            return .item(copy)
        }
        return PopupMenu(entries: entries, selectedId: selected)
    }

    public func item(_ item: PopupMenuItem) -> PopupMenu {
        var copy = self
        copy.entries.append(.item(item))
        return copy
    }

    public func item(
        _ id: String,
        _ title: String,
        enabled: Bool = true,
        checked: Bool = false,
        keyEquivalent: String? = nil,
        symbolName: String? = nil
    ) -> PopupMenu {
        item(PopupMenuItem(
            id: id,
            title: title,
            enabled: enabled,
            checked: checked,
            keyEquivalent: keyEquivalent,
            symbolName: symbolName
        ))
    }

    public func separator() -> PopupMenu {
        var copy = self
        copy.entries.append(.separator)
        return copy
    }

    public func submenu(_ title: String, _ menu: PopupMenu, enabled: Bool = true) -> PopupMenu {
        var copy = self
        copy.entries.append(.submenu(title: title, menu: menu, enabled: enabled))
        return copy
    }

    /// Sets which item the menu opens over (`PopupMenu::selected`), without altering checkmarks.
    public func selected(_ id: String?) -> PopupMenu {
        var copy = self
        copy.selectedId = id
        return copy
    }

    public mutating func addItem(_ item: PopupMenuItem) {
        entries.append(.item(item))
    }

    public mutating func addSeparator() {
        entries.append(.separator)
    }

    public mutating func addSubmenu(title: String, menu: PopupMenu, enabled: Bool = true) {
        entries.append(.submenu(title: title, menu: menu, enabled: enabled))
    }

    public func findItem(id: String) -> PopupMenuItem? {
        for entry in entries {
            switch entry {
            case .item(let item) where item.id == id:
                return item
            case .submenu(_, let sub, _):
                if let found = sub.findItem(id: id) { return found }
            default:
                break
            }
        }
        return nil
    }

    public func validate() throws {
        var seen = Set<String>()
        try validate(seen: &seen)
    }

    private func validate(seen: inout Set<String>) throws {
        for entry in entries {
            switch entry {
            case .item(let item):
                if item.id.isEmpty {
                    throw PopupMenuError.emptyId
                }
                if !seen.insert(item.id).inserted {
                    throw PopupMenuError.duplicateId(item.id)
                }
            case .submenu(_, let sub, _):
                try sub.validate(seen: &seen)
            case .separator:
                break
            }
        }
    }

    public func checkSelectable(id: String) throws {
        guard let found = findItem(id: id) else {
            throw PopupMenuError.unknownItem(id)
        }
        guard found.enabled else {
            throw PopupMenuError.disabled(id)
        }
    }

    public func toJSONObject() -> [String: Any] {
        let itemsJSON: [[String: Any]] = entries.map { entry in
            switch entry {
            case .item(let item):
                var d: [String: Any] = [
                    "id": item.id,
                    "title": item.title,
                    "enabled": item.enabled,
                    "checked": item.checked,
                ]
                if let eq = item.keyEquivalent { d["keyEquivalent"] = eq }
                if let sym = item.symbolName { d["symbol"] = sym }
                return d
            case .separator:
                return ["separator": true]
            case .submenu(let title, let sub, let enabled):
                var d: [String: Any] = [
                    "submenu": title,
                    "menu": sub.toJSONObject(),
                ]
                if !enabled {
                    d["enabled"] = false
                }
                return d
            }
        }
        var out: [String: Any] = ["items": itemsJSON]
        if let selectedId {
            out["selected"] = selectedId
        }
        return out
    }

    #if os(macOS)
    @MainActor
    public func buildNSMenu(target: AnyObject? = nil, action: Selector? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .item(let item):
                let nsItem = NSMenuItem(title: item.title, action: action, keyEquivalent: item.keyEquivalent ?? "")
                nsItem.target = target
                nsItem.representedObject = item.id
                nsItem.isEnabled = item.enabled
                nsItem.state = item.checked ? .on : .off
                if let sym = item.symbolName {
                    nsItem.image = NSImage(systemSymbolName: sym, accessibilityDescription: item.title)
                }
                menu.addItem(nsItem)
            case .submenu(let title, let sub, let enabled):
                let nsItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                nsItem.isEnabled = enabled
                nsItem.submenu = sub.buildNSMenu(target: target, action: action)
                menu.addItem(nsItem)
            }
        }
        return menu
    }
    #endif
}

public enum NativeMenuLocation: Sendable, Equatable {
    case app
    case named(String)
    case dock
}

public enum MenuError: Error, Sendable, Equatable {
    case unsupported
    case notRunning
    case invalid(String)
    case unknownItem(String)
    case ambiguousTitle(String)
    case disabled(String)
    case inUse
    case backend(String)
}

public struct NativeMenuItem<State> {
    public var id: String
    public var title: String
    public var location: NativeMenuLocation
    public var afterId: String?
    public var keyEquivalent: String?
    public var keysFirst: Bool
    public var enabled: Bool
    public var checked: Bool
    public var isSeparator: Bool
    public var action: (inout State, inout Tx) -> Void

    public init(
        id: String? = nil,
        title: String,
        location: NativeMenuLocation = .app,
        afterId: String? = nil,
        keyEquivalent: String? = nil,
        keysFirst: Bool = false,
        enabled: Bool = true,
        checked: Bool = false,
        action: @escaping (inout State, inout Tx) -> Void
    ) {
        self.id = id ?? title
        self.title = title
        self.location = location
        self.afterId = afterId
        self.keyEquivalent = keyEquivalent
        self.keysFirst = keysFirst
        self.enabled = enabled
        self.checked = checked
        self.isSeparator = false
        self.action = action
    }

    public static func separator(location: NativeMenuLocation = .app) -> NativeMenuItem<State> {
        var item = NativeMenuItem(id: "__sep__", title: "", location: location, action: { _, _ in })
        item.isSeparator = true
        return item
    }
}

/// Manages top-level native application menus and dispatches menu item actions deterministically.
public final class NativeMenuBar<State> {
    public private(set) var items: [NativeMenuItem<State>] = []

    public init(items: [NativeMenuItem<State>] = []) {
        self.items = items
    }

    public func setItems(_ newItems: [NativeMenuItem<State>]) {
        self.items = newItems
    }

    public func setValidatedItems(_ newItems: [NativeMenuItem<State>]) throws {
        try NativeMenuValidator.validate(newItems)
        self.items = newItems
    }

    public func dispatch(id selector: String, state: inout State, tx: inout Tx) throws {
        let idx = try NativeMenuValidator.lookupIndex(selector: selector, in: items)
        items[idx].action(&state, &tx)
    }

    #if os(macOS)
    @MainActor
    public func buildMainMenu(target: AnyObject? = nil, action: Selector? = nil) -> NSMenu {
        let mainMenu = NSMenu()
        var grouped: [(String, [NativeMenuItem<State>])] = []
        var appItems: [NativeMenuItem<State>] = []

        for item in items {
            switch item.location {
            case .app:
                appItems.append(item)
            case .named(let name):
                if let idx = grouped.firstIndex(where: { $0.0 == name }) {
                    grouped[idx].1.append(item)
                } else {
                    grouped.append((name, [item]))
                }
            case .dock:
                break
            }
        }

        func populate(_ menu: NSMenu, from list: [NativeMenuItem<State>]) {
            for entry in list {
                if entry.isSeparator {
                    menu.addItem(.separator())
                } else {
                    let nsItem = NSMenuItem(title: entry.title, action: action, keyEquivalent: entry.keyEquivalent ?? "")
                    nsItem.target = target
                    nsItem.representedObject = entry.id
                    nsItem.isEnabled = entry.enabled
                    nsItem.state = entry.checked ? .on : .off
                    menu.addItem(nsItem)
                }
            }
        }

        if !appItems.isEmpty {
            let root = NSMenuItem(title: "App", action: nil, keyEquivalent: "")
            let sub = NSMenu(title: "App")
            sub.autoenablesItems = false
            populate(sub, from: appItems)
            root.submenu = sub
            mainMenu.addItem(root)
        }
        for (name, list) in grouped {
            let root = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: name)
            sub.autoenablesItems = false
            populate(sub, from: list)
            root.submenu = sub
            mainMenu.addItem(root)
        }
        return mainMenu
    }
    #endif
}

// MARK: - 6. System Tray

public struct TrayIcon: Sendable, Equatable {
    public let width: UInt32
    public let height: UInt32
    public let rgba: Data

    public init(width: UInt32, height: UInt32, rgba: Data) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public var isValid: Bool {
        width > 0 && height > 0 && width <= 4096 && height <= 4096 && rgba.count == Int(width) * Int(height) * 4
    }

    public func validated() throws -> TrayIcon {
        guard isValid else {
            throw TrayError.backend("invalid tray icon dimensions or RGBA length (\(width)x\(height), \(rgba.count) bytes)")
        }
        return self
    }
}

public enum TrayItem: Sendable, Equatable {
    case action(id: String, label: String, enabled: Bool)
    case separator

    public static func action(id: String, label: String) -> TrayItem {
        .action(id: id, label: label, enabled: true)
    }

    public func enabled(_ value: Bool) -> TrayItem {
        switch self {
        case .separator:
            return .separator
        case let .action(id, label, _):
            return .action(id: id, label: label, enabled: value)
        }
    }
}

public enum TrayEvent: Sendable, Equatable {
    case activate(token: String?)
    case menu(String)
}

public struct TraySpec: Sendable, Equatable {
    public var id: String
    public var title: String
    public var tooltip: String
    public var iconName: String
    public var icon: TrayIcon?
    public var menu: [TrayItem]

    public init(
        id: String,
        title: String,
        tooltip: String = "",
        iconName: String = "",
        icon: TrayIcon? = nil,
        menu: [TrayItem] = []
    ) {
        self.id = id
        self.title = title
        self.tooltip = tooltip
        self.iconName = iconName
        self.icon = icon
        self.menu = menu
    }
}

public enum TrayError: Error, Sendable, Equatable {
    case unsupported
    case backend(String)
}

/// System tray / macOS `NSStatusItem` controller with deterministic headless state.
public final class SystemTray: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var spec: TraySpec
    public private(set) var isVisible: Bool = false
    private var handler: (@Sendable (TrayEvent) -> Void)?
    #if os(macOS)
    @MainActor
    private final class TrayTarget: NSObject {
        weak var owner: SystemTray?
        init(owner: SystemTray) { self.owner = owner }
        @objc func onMenuItem(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            owner?.simulateEvent(.menu(id))
        }
        @objc func onActivate(_ sender: Any?) {
            _ = sender
            owner?.simulateEvent(.activate(token: nil))
        }
    }

    @MainActor private var statusItem: NSStatusItem?
    @MainActor private var trayTarget: TrayTarget?
    #endif

    public init(spec: TraySpec, onEvent: (@Sendable (TrayEvent) -> Void)? = nil) {
        self.spec = spec
        self.handler = onEvent
    }

    public func update(_ newSpec: TraySpec) {
        lock.lock()
        self.spec = newSpec
        lock.unlock()
        #if os(macOS)
        if isVisible {
            Task { @MainActor in
                self.syncStatusItem()
            }
        }
        #endif
    }

    public func showHeadless() {
        lock.lock()
        isVisible = true
        lock.unlock()
    }

    public func simulateEvent(_ event: TrayEvent) {
        lock.lock()
        let h = handler
        lock.unlock()
        h?(event)
    }

    #if os(macOS)
    @MainActor
    public func showNative() {
        lock.lock()
        isVisible = true
        lock.unlock()
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        syncStatusItem()
    }

    @MainActor
    public func removeNative() {
        lock.lock()
        isVisible = false
        lock.unlock()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @MainActor
    private func syncStatusItem() {
        guard let item = statusItem else { return }
        if trayTarget == nil {
            trayTarget = TrayTarget(owner: self)
        }
        lock.lock()
        let current = spec
        lock.unlock()
        item.button?.title = current.title
        item.button?.toolTip = current.tooltip
        if let icon = current.icon, icon.isValid, let appIcon = AppIcon(width: Int(icon.width), height: Int(icon.height), rgba: icon.rgba) {
            item.button?.image = MacOSDockIconApplier.makeNSImage(from: appIcon)
        } else if !current.iconName.isEmpty {
            item.button?.image = NSImage(systemSymbolName: current.iconName, accessibilityDescription: current.title)
        }
        if current.menu.isEmpty {
            item.menu = nil
            item.button?.target = trayTarget
            item.button?.action = #selector(TrayTarget.onActivate(_:))
        } else {
            item.button?.target = nil
            item.button?.action = nil
            let menu = NSMenu()
            menu.autoenablesItems = false
            for entry in current.menu {
                switch entry {
                case .separator:
                    menu.addItem(.separator())
                case .action(let id, let label, let enabled):
                    let mi = NSMenuItem(title: label, action: #selector(TrayTarget.onMenuItem(_:)), keyEquivalent: "")
                    mi.target = trayTarget
                    mi.representedObject = id
                    mi.isEnabled = enabled
                    menu.addItem(mi)
                }
            }
            item.menu = menu
        }
    }
    #endif
}

// MARK: - 7. System Material & Native Surface

public enum SystemMaterial: String, Sendable, Equatable, Hashable {
    case glass
    case popover
    case hudWindow
    case sidebar
    case underWindowBackground
    case menu
}

public enum MaterialBlendingMode: String, Sendable, Equatable, Hashable {
    case behindWindow
    case withinWindow
}

public struct MaterialDraw: Sendable, Equatable {
    public var id: UInt64
    public var material: SystemMaterial
    public var blending: MaterialBlendingMode
    public var rect: MotionRect
    public var radius: Float
    public var continuous: Bool
    public var opacity: Float

    public init(
        id: UInt64,
        material: SystemMaterial,
        blending: MaterialBlendingMode = .behindWindow,
        rect: MotionRect,
        radius: Float = 0,
        continuous: Bool = true,
        opacity: Float = 1.0
    ) {
        self.id = id
        self.material = material
        self.blending = blending
        self.rect = rect
        self.radius = radius
        self.continuous = continuous
        self.opacity = opacity
    }

    /// Converts physical-pixel `rect` and `radius` to logical points for AppKit hosting.
    public func points(scale: Float) -> MaterialDraw {
        let s = max(scale, 1e-3)
        return MaterialDraw(
            id: id,
            material: material,
            blending: blending,
            rect: MotionRect(
                left: rect.left / s,
                top: rect.top / s,
                right: rect.right / s,
                bottom: rect.bottom / s
            ),
            radius: radius / s,
            continuous: continuous,
            opacity: opacity
        )
    }

    #if os(macOS)
    public var nsMaterial: NSVisualEffectView.Material {
        switch material {
        case .glass, .popover: return .popover
        case .hudWindow: return .hudWindow
        case .sidebar: return .sidebar
        case .underWindowBackground: return .underWindowBackground
        case .menu: return .menu
        }
    }

    public var nsBlendingMode: NSVisualEffectView.BlendingMode {
        switch blending {
        case .behindWindow: return .behindWindow
        case .withinWindow: return .withinWindow
        }
    }
    #endif
}

// MARK: - 8. Multi-Window Manager

public struct WindowSpec: Sendable, Equatable {
    public var id: String
    public var title: String
    public var size: Vec2
    public var minSize: Vec2?
    public var resizable: Bool
    public var material: SystemMaterial?

    public init(
        id: String,
        title: String,
        size: Vec2 = Vec2(800, 600),
        minSize: Vec2? = nil,
        resizable: Bool = true,
        material: SystemMaterial? = nil
    ) {
        self.id = id
        self.title = title
        self.size = size
        self.minSize = minSize
        self.resizable = resizable
        self.material = material
    }
}

public struct ManagedWindowState: Sendable, Equatable {
    public var spec: WindowSpec
    public var isOpen: Bool
    public var isFocused: Bool
    public var isMinimized: Bool
    public var taskbar: TaskbarState

    public init(spec: WindowSpec, isOpen: Bool = true, isFocused: Bool = false, isMinimized: Bool = false, taskbar: TaskbarState = TaskbarState()) {
        self.spec = spec
        self.isOpen = isOpen
        self.isFocused = isFocused
        self.isMinimized = isMinimized
        self.taskbar = taskbar
    }
}

public final class WindowManager: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [String: ManagedWindowState] = [:]
    private var order: [String] = []

    public init() {}

    @discardableResult
    public func open(_ spec: WindowSpec, focused: Bool = true) -> ManagedWindowState {
        lock.lock()
        defer { lock.unlock() }
        if focused {
            for key in windows.keys {
                windows[key]?.isFocused = false
            }
        }
        let st = ManagedWindowState(spec: spec, isOpen: true, isFocused: focused)
        windows[spec.id] = st
        if !order.contains(spec.id) {
            order.append(spec.id)
        }
        return st
    }

    public func close(id: String) {
        lock.lock()
        defer { lock.unlock() }
        windows[id]?.isOpen = false
        windows[id]?.isFocused = false
        if let nextId = order.last(where: { $0 != id && (windows[$0]?.isOpen ?? false) }) {
            windows[nextId]?.isFocused = true
        }
    }

    public func focus(id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard windows[id]?.isOpen == true else { return }
        for key in windows.keys {
            windows[key]?.isFocused = (key == id)
        }
    }

    public func setTitle(_ title: String, for id: String) {
        lock.lock()
        windows[id]?.spec.title = title
        lock.unlock()
    }

    public func setTaskbar(_ taskbar: TaskbarState, for id: String) {
        lock.lock()
        windows[id]?.taskbar = taskbar
        lock.unlock()
    }

    public func state(for id: String) -> ManagedWindowState? {
        lock.lock()
        defer { lock.unlock() }
        return windows[id]
    }

    public func openWindows() -> [ManagedWindowState] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { id in
            guard let st = windows[id], st.isOpen else { return nil }
            return st
        }
    }

    public var focusedWindowId: String? {
        lock.lock()
        defer { lock.unlock() }
        return windows.values.first(where: { $0.isOpen && $0.isFocused })?.spec.id
    }
}

// MARK: - 9. AppDirs, Prefs, Quit Machine, Task, Taskbar, JumpList

public struct AppDirs: Sendable, Equatable {
    public static let rootEnv = "RUNE_DIRS_ROOT"
    public static let prefsDirEnv = "RUNE_PREFS_DIR"

    public let id: String
    public let home: URL?
    public let config: URL
    public let data: URL
    public let cache: URL
    public let state: URL
    public let logs: URL
    public let downloads: URL
    public let isRooted: Bool

    public init(
        id: String,
        home: URL?,
        config: URL,
        data: URL,
        cache: URL,
        state: URL,
        logs: URL,
        downloads: URL,
        isRooted: Bool = false
    ) {
        self.id = id
        self.home = home
        self.config = config
        self.data = data
        self.cache = cache
        self.state = state
        self.logs = logs
        self.downloads = downloads
        self.isRooted = isRooted
    }

    /// Sanitizes an app id into a safe single directory component (`rune::prefs::sanitize`).
    public static func sanitize(_ appId: String) -> String {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        let mapped = appId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .map { invalid.contains($0) ? "_" : String($0) }
            .joined()
        var end = mapped.endIndex
        while end > mapped.startIndex {
            let prev = mapped.index(before: end)
            let ch = mapped[prev]
            if ch.isWhitespace || ch == "." {
                end = prev
            } else {
                break
            }
        }
        let cleaned = String(mapped[..<end])
        return cleaned.isEmpty ? "app" : cleaned
    }

    public static var defaultHomeURL: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    /// Resolves the user's home folder from the process environment (`rune::dirs::home`).
    public static func home() -> URL? {
        homeFrom { ProcessInfo.processInfo.environment[$0] }
    }

    /// Resolves the user's home folder via `lookup` (`rune::dirs::home_from`).
    public static func homeFrom(_ lookup: (String) -> String?) -> URL? {
        func nonEmpty(_ k: String) -> String? {
            guard let v = lookup(k), !v.isEmpty else { return nil }
            return v
        }
        #if os(Windows)
        if let profile = nonEmpty("USERPROFILE") {
            return URL(fileURLWithPath: profile, isDirectory: true)
        }
        if let drive = nonEmpty("HOMEDRIVE"), let path = nonEmpty("HOMEPATH") {
            return URL(fileURLWithPath: drive + path, isDirectory: true)
        }
        return nil
        #else
        return nonEmpty("HOME").map { URL(fileURLWithPath: $0, isDirectory: true) }
        #endif
    }

    /// Resolves standard directories via `lookup`, returning `nil` if no home folder is available (`AppDirs::from_env`).
    public static func fromEnv(appId: String, lookup: (String) -> String?) -> AppDirs? {
        func nonEmpty(_ k: String) -> String? {
            guard let v = lookup(k), !v.isEmpty else { return nil }
            return v
        }
        let homeURL = nonEmpty("HOME").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let root = nonEmpty(rootEnv) {
            return rooted(at: URL(fileURLWithPath: root, isDirectory: true), appId: appId, home: homeURL)
        }
        guard let homeURL else { return nil }
        return resolveWithHome(appId: appId, homeURL: homeURL, lookup: nonEmpty, isRooted: false)
    }

    /// Resolves the `config` base directory (`crate::dirs::config_base`), honoring `RUNE_DIRS_ROOT` even without `HOME`.
    internal static func configBase(lookup: (String) -> String?) -> URL? {
        fromEnv(appId: "app", lookup: lookup)?.config.deletingLastPathComponent()
    }

    public static func resolve(appId: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> AppDirs {
        if let resolved = fromEnv(appId: appId, lookup: { environment[$0] }) {
            return resolved
        }
        return resolveWithHome(appId: appId, homeURL: defaultHomeURL, lookup: {
            guard let v = environment[$0], !v.isEmpty else { return nil }
            return v
        }, isRooted: false)
    }

    private static func resolveWithHome(
        appId: String,
        homeURL: URL,
        lookup: (String) -> String?,
        isRooted: Bool
    ) -> AppDirs {
        let cleanId = sanitize(appId)
        #if os(macOS) || os(iOS)
        let appSupport = homeURL.appendingPathComponent("Library/Application Support/\(cleanId)", isDirectory: true)
        let caches = homeURL.appendingPathComponent("Library/Caches/\(cleanId)", isDirectory: true)
        let logsDir = homeURL.appendingPathComponent("Library/Logs/\(cleanId)", isDirectory: true)
        let downloadsDir = homeURL.appendingPathComponent("Downloads", isDirectory: true)
        return AppDirs(
            id: cleanId,
            home: homeURL,
            config: appSupport,
            data: appSupport,
            cache: caches,
            state: appSupport,
            logs: logsDir,
            downloads: downloadsDir,
            isRooted: isRooted
        )
        #else
        let absXdg: (String, String) -> URL = { key, fallbackRel in
            if let v = lookup(key), v.hasPrefix("/") {
                return URL(fileURLWithPath: v, isDirectory: true)
            }
            return homeURL.appendingPathComponent(fallbackRel, isDirectory: true)
        }
        let xdgConfig = absXdg("XDG_CONFIG_HOME", ".config")
        let xdgData = absXdg("XDG_DATA_HOME", ".local/share")
        let xdgCache = absXdg("XDG_CACHE_HOME", ".cache")
        let xdgState = absXdg("XDG_STATE_HOME", ".local/state")
        let xdgDownload = absXdg("XDG_DOWNLOAD_DIR", "Downloads")
        return AppDirs(
            id: cleanId,
            home: homeURL,
            config: xdgConfig.appendingPathComponent(cleanId, isDirectory: true),
            data: xdgData.appendingPathComponent(cleanId, isDirectory: true),
            cache: xdgCache.appendingPathComponent(cleanId, isDirectory: true),
            state: xdgState.appendingPathComponent(cleanId, isDirectory: true),
            logs: xdgState.appendingPathComponent("\(cleanId)/logs", isDirectory: true),
            downloads: xdgDownload,
            isRooted: isRooted
        )
        #endif
    }

    public static func rooted(at root: URL, appId: String, home: URL? = nil) -> AppDirs {
        let cleanId = sanitize(appId)
        return AppDirs(
            id: cleanId,
            home: home,
            config: root.appendingPathComponent("config/\(cleanId)", isDirectory: true),
            data: root.appendingPathComponent("data/\(cleanId)", isDirectory: true),
            cache: root.appendingPathComponent("cache/\(cleanId)", isDirectory: true),
            state: root.appendingPathComponent("state/\(cleanId)", isDirectory: true),
            logs: root.appendingPathComponent("logs/\(cleanId)", isDirectory: true),
            downloads: root.appendingPathComponent("downloads", isDirectory: true),
            isRooted: true
        )
    }

    public func sibling(_ appId: String) -> AppDirs {
        let cleanId = Self.sanitize(appId)
        #if os(macOS) || os(iOS) || os(Windows)
        let siblingLogs = logs.deletingLastPathComponent().appendingPathComponent(cleanId, isDirectory: true)
        #else
        let siblingLogs: URL = isRooted
            ? logs.deletingLastPathComponent().appendingPathComponent(cleanId, isDirectory: true)
            : logs.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("\(cleanId)/logs", isDirectory: true)
        #endif
        return AppDirs(
            id: cleanId,
            home: home,
            config: config.deletingLastPathComponent().appendingPathComponent(cleanId, isDirectory: true),
            data: data.deletingLastPathComponent().appendingPathComponent(cleanId, isDirectory: true),
            cache: cache.deletingLastPathComponent().appendingPathComponent(cleanId, isDirectory: true),
            state: state.deletingLastPathComponent().appendingPathComponent(cleanId, isDirectory: true),
            logs: siblingLogs,
            downloads: downloads,
            isRooted: isRooted
        )
    }
}

public enum PrefsError: Error, Sendable {
    case serialize(String)
    case io(String)
}

/// Atomic JSON-backed key-value preferences store (`rune::prefs::Prefs`).
public final class Prefs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    public let path: URL?

    public var isPersistent: Bool { path != nil }

    /// Resolves the root preferences directory via `lookup` (`prefs::config_dir`), returning `nil` if unconfigured.
    public static func configDir(lookup: (String) -> String?) -> URL? {
        if let custom = lookup(AppDirs.prefsDirEnv), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return AppDirs.configBase(lookup: lookup)
    }

    public static func open(appId: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Prefs {
        guard let dir = configDir(lookup: { environment[$0] }) else {
            return memory()
        }
        return at(dir.appendingPathComponent("\(AppDirs.sanitize(appId))/prefs.json"))
    }

    public static func at(_ url: URL) -> Prefs {
        let prefs = Prefs(path: url)
        prefs.loadFromDisk()
        return prefs
    }

    public static func memory() -> Prefs {
        Prefs(path: nil)
    }

    private init(path: URL?) {
        self.path = path
    }

    private func loadFromDisk() {
        guard let path, FileManager.default.fileExists(atPath: path.path) else { return }
        guard let raw = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            let bad = path.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: path, to: bad)
            return
        }
        for (k, v) in obj {
            if let encoded = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) {
                values[k] = encoded
            }
        }
    }

    public func get<T: Decodable>(_ key: String, as type: T.Type = T.self) -> T? {
        lock.lock()
        let data = values[key]
        lock.unlock()
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func set<T: Encodable>(_ key: String, value: T) throws {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(value)
        } catch {
            throw PrefsError.serialize(error.localizedDescription)
        }
        lock.lock()
        values[key] = encoded
        let snapshot = values
        lock.unlock()
        try persist(snapshot)
    }

    public func remove(_ key: String) throws {
        lock.lock()
        values.removeValue(forKey: key)
        let snapshot = values
        lock.unlock()
        try persist(snapshot)
    }

    public func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values[key] != nil
    }

    public var keys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values.keys.sorted()
    }

    private func persist(_ snapshot: [String: Data]) throws {
        guard let path else { return }
        let dir = path.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var dict: [String: Any] = [:]
            for (k, d) in snapshot {
                dict[k] = try JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
            }
            let out = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            let tmp = dir.appendingPathComponent(".prefs.\(UUID().uuidString).tmp")
            try out.write(to: tmp, options: .atomic)
            if rename(tmp.path, path.path) != 0 {
                let err = errno
                try? FileManager.default.removeItem(at: tmp)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
            }
        } catch {
            throw PrefsError.io(error.localizedDescription)
        }
    }
}

public enum QuitHooks: Sendable, Equatable {
    case owed
    case ran
}

public enum QuitAfter: Sendable, Equatable {
    case exit
    case relaunch
}

public enum QuitState: Sendable, Equatable {
    case running
    case quitting(hooks: QuitHooks, after: QuitAfter)
    case closed
    case done
}

public enum QuitEvent: Sendable, Equatable {
    case start(ending: Bool, after: QuitAfter)
    case hooksRan
    case windowsClosed
    case cancel
    case exited
}

public enum QuitEffect: Sendable, Equatable {
    case runHooks
    case closeAndExit
    case relaunch
}

public enum QuitMachine {
    public static func step(_ state: QuitState, event: QuitEvent) -> (QuitState, [QuitEffect]) {
        switch (state, event) {
        case (.done, _):
            return (.done, [])
        case (.quitting(_, .relaunch), .exited):
            return (.done, [.relaunch])
        case (_, .exited):
            return (.done, [])
        case (.closed, _):
            return (.closed, [])
        case (.running, .start(let ending, let after)):
            var effects: [QuitEffect] = [.runHooks]
            if ending { effects.append(.closeAndExit) }
            return (.quitting(hooks: .owed, after: after), effects)
        case (.quitting(let hooks, let currentAfter), .start(let ending, let nextAfter)):
            let mergedAfter: QuitAfter = (currentAfter == .relaunch || nextAfter == .relaunch) ? .relaunch : .exit
            var effects: [QuitEffect] = []
            if hooks == .owed { effects.append(.runHooks) }
            if ending { effects.append(.closeAndExit) }
            return (.quitting(hooks: hooks, after: mergedAfter), effects)
        case (.quitting(_, let after), .hooksRan):
            return (.quitting(hooks: .ran, after: after), [])
        case (.quitting, .windowsClosed):
            return (.closed, [])
        case (.quitting, .cancel):
            return (.running, [])
        case (.running, _):
            return (.running, [])
        }
    }
}

public enum RuneTask {
    @discardableResult
    public static func spawn(name: String, work: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            work()
        }
    }

    @discardableResult
    public static func spawnAfter(name: String, delaySeconds: Double, work: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            if delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            if !Task.isCancelled {
                work()
            }
        }
    }

    /// Consumes messages from `stream` in order until `each` returns `false` or the stream finishes (`task::serve`).
    @discardableResult
    public static func serve<T: Sendable>(
        name: String,
        stream: AsyncStream<T>,
        each: @escaping @Sendable (T) -> Bool
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            for await msg in stream {
                if Task.isCancelled || !each(msg) {
                    break
                }
            }
        }
    }

    /// Suspends the current task for `seconds` (`task::sleep`).
    public static func sleep(seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

public enum TaskbarProgress: String, Sendable, Equatable {
    case none
    case busy
    case paused
    case error
}

public typealias Taskbar = TaskbarState

public struct TaskbarState: Sendable, Equatable {
    public var progress: TaskbarProgress
    public var badgeCount: UInt32
    public var badgeDescription: String

    public init(progress: TaskbarProgress = .none, badgeCount: UInt32 = 0, badgeDescription: String = "") {
        self.progress = progress
        self.badgeCount = badgeCount
        self.badgeDescription = badgeCount == 0 ? "" : badgeDescription
    }

    /// Returns a copy with `progress` set (`Taskbar::progress`).
    public func progress(_ progress: TaskbarProgress) -> TaskbarState {
        var copy = self
        copy.progress = progress
        return copy
    }

    /// Returns a copy with `count` and screen-reader `description` (`Taskbar::badge`); clears `badgeDescription` when `count == 0`.
    public func badge(_ count: UInt32, _ description: String = "") -> TaskbarState {
        var copy = self
        copy.badgeCount = count
        copy.badgeDescription = count == 0 ? "" : description
        return copy
    }

    /// Badge count (`Taskbar::count`).
    public var count: UInt32 { badgeCount }

    /// Shown progress bar state (`Taskbar::shown_progress`).
    public var shownProgress: TaskbarProgress { progress }

    #if os(macOS)
    @MainActor
    public static func applyDockBadge(totalCount: UInt32) {
        if totalCount == 0 {
            NSApp.dockTile.badgeLabel = nil
        } else if totalCount > 9 {
            NSApp.dockTile.badgeLabel = "9+"
        } else {
            NSApp.dockTile.badgeLabel = "\(totalCount)"
        }
    }
    #endif
}

public struct JumpItem: Sendable, Equatable, Hashable {
    public var title: String
    public var argument: String
    public var description: String

    public init(title: String, argument: String, description: String = "") {
        self.title = title
        self.argument = argument
        self.description = description
    }
}

public struct JumpList: Sendable, Equatable, Hashable {
    public var tasks: [JumpItem] = []
    public var categories: [(name: String, items: [JumpItem])] = []
    public var lead: String? = nil

    public init() {}

    public func task(_ item: JumpItem) -> JumpList {
        var copy = self
        copy.tasks.append(item)
        return copy
    }

    public func category(_ name: String, items: [JumpItem]) -> JumpList {
        guard !items.isEmpty else { return self }
        var copy = self
        copy.categories.append((name, items))
        return copy
    }

    public func lead(_ argument: String) -> JumpList {
        var copy = self
        copy.lead = argument
        return copy
    }

    public static func == (lhs: JumpList, rhs: JumpList) -> Bool {
        lhs.tasks == rhs.tasks &&
        lhs.lead == rhs.lead &&
        lhs.categories.count == rhs.categories.count &&
        zip(lhs.categories, rhs.categories).allSatisfy { $0.name == $1.name && $0.items == $1.items }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(tasks)
        hasher.combine(lead)
        for cat in categories {
            hasher.combine(cat.name)
            hasher.combine(cat.items)
        }
    }
}

/// Queued playground navigation/trigger actions recorded on `Tx` (`playground/open.rs`).
public enum PlaygroundTxRequest: Sendable, Equatable {
    case open
    case openAt(story: String, variant: String?)
    case close
    case replay
    case trigger(Character)
    case toggle
    case keep
}

// MARK: - 10. Tx & El Extensions

extension Tx {
    /// Opens the built-in Playground UI.
    public mutating func openPlayground() {
        enqueuePlaygroundRequest(.open)
    }

    /// Opens the built-in Playground UI on `story` (path, name, or slug) and optional `variant` (`Tx::open_playground_at`).
    public mutating func openPlaygroundAt(_ story: String, variant: String? = nil) {
        enqueuePlaygroundRequest(.openAt(story: story, variant: variant))
    }

    /// Closes the built-in Playground UI.
    public mutating func closePlayground() {
        enqueuePlaygroundRequest(.close)
    }

    /// Toggles the built-in Playground UI open or closed (`Tx::toggle_playground`).
    public mutating func togglePlayground() {
        enqueuePlaygroundRequest(.toggle)
    }

    /// Closes the playground while keeping the active scene's edits (`Tx::keep_playground`).
    public mutating func keepPlayground() {
        enqueuePlaygroundRequest(.keep)
    }

    /// Replays the open Playground story and runs its `'r'` trigger (`Tx::replay_playground`).
    public mutating func replayPlayground() {
        enqueuePlaygroundRequest(.replay)
    }

    /// Fires a Playground trigger by key on the open story (`Tx::playground_trigger`).
    public mutating func playgroundTrigger(_ key: Character) {
        let lower = Character(key.lowercased())
        enqueuePlaygroundRequest(lower == "r" ? .replay : .trigger(lower))
    }

    private mutating func enqueuePlaygroundRequest(_ req: PlaygroundTxRequest) {
        var list = (runtimeActions["playgroundRequests"] as? [PlaygroundTxRequest]) ?? []
        list.append(req)
        runtimeActions["playgroundRequests"] = list
    }
    /// Copies a rich clipboard payload (text, HTML, RTF, image, files, concealed).
    public mutating func copyRich(_ payload: RichClipboardPayload) {
        clipboardWrite = payload.content
        runtimeActions["richClipboardWrite"] = payload
    }

    /// Copies plain text along with HTML markup (`text/html`) to the clipboard (#832).
    public mutating func copyHTML(_ text: String, html: String) {
        copyRich(RichClipboardPayload(text: text, html: html))
    }

    /// Requests opening an `http:`, `https:`, or `mailto:` URL.
    public mutating func openUrl(_ url: String, sameTab: Bool = false) throws {
        let normalized = sameTab ? try UrlOpener.checkSameTab(url) : try UrlOpener.validate(url)
        var list = (runtimeActions["openUrlRequests"] as? [OpenUrlRequest]) ?? []
        list.append(OpenUrlRequest(url: normalized, sameTab: sameTab))
        runtimeActions["openUrlRequests"] = list
    }

    /// Requests opening a URL in the same tab on web (allows relative paths on web; rejects on native).
    public mutating func openUrlSameTab(_ url: String) throws {
        try openUrl(url, sameTab: true)
    }

    /// Initiates an outbound OS drag session with `item`.
    public mutating func dragOut(_ item: DragItem) {
        runtimeActions["dragOutItem"] = item
    }

    /// Shows a native popup menu at `anchor` after the current handler frame commits.
    public mutating func popupMenu<State>(
        _ menu: PopupMenu,
        at anchor: PopupAnchor,
        _ onPick: @escaping (inout State, String?, inout Tx) -> Void
    ) {
        let req = ErasedPopupRequest(
            menu: menu,
            anchor: anchor,
            onPick: { anyState, picked, tx in
                guard var typed = anyState as? State else { return }
                onPick(&typed, picked, &tx)
                anyState = typed
            }
        )
        var list = (runtimeActions["erasedActions"] as? [ErasedRuntimeAction]) ?? []
        list.append(.popup(req))
        runtimeActions["erasedActions"] = list
    }

    public mutating func popupMenu<State>(
        _ menu: PopupMenu,
        at key: String,
        _ onPick: @escaping (inout State, String?, inout Tx) -> Void
    ) {
        popupMenu(menu, at: .key(key), onPick)
    }

    public mutating func popupMenu<State>(
        _ menu: PopupMenu,
        at press: PointerPress,
        _ onPick: @escaping (inout State, String?, inout Tx) -> Void
    ) {
        popupMenu(menu, at: PopupAnchor(press), onPick)
    }

    public mutating func popupMenu<State>(
        _ menu: PopupMenu,
        at point: Vec2,
        _ onPick: @escaping (inout State, String?, inout Tx) -> Void
    ) {
        popupMenu(menu, at: PopupAnchor(point), onPick)
    }

    /// Opens an asynchronous OS file-open sheet (`NSOpenPanel`) after this frame commits.
    public mutating func openFile<State>(
        _ options: FileDialogOptions = FileDialogOptions(),
        _ onAnswer: @escaping (inout State, FileDialogResult, inout Tx) -> Void
    ) {
        enqueueFileDialog(kind: .open, options: options, onAnswer)
    }

    /// Opens an asynchronous OS file-save sheet (`NSSavePanel`) after this frame commits.
    public mutating func saveFile<State>(
        _ options: FileDialogOptions = FileDialogOptions(),
        _ onAnswer: @escaping (inout State, FileDialogResult, inout Tx) -> Void
    ) {
        enqueueFileDialog(kind: .save, options: options, onAnswer)
    }

    /// Opens an asynchronous OS folder-picker sheet (`NSOpenPanel` directories) after this frame commits.
    public mutating func openFolder<State>(
        _ options: FileDialogOptions = FileDialogOptions(),
        _ onAnswer: @escaping (inout State, FileDialogResult, inout Tx) -> Void
    ) {
        enqueueFileDialog(kind: .folder, options: options, onAnswer)
    }

    private mutating func enqueueFileDialog<State>(
        kind: FileDialogKind,
        options: FileDialogOptions,
        _ onAnswer: @escaping (inout State, FileDialogResult, inout Tx) -> Void
    ) {
        let req = ErasedFileDialogRequest(
            kind: kind,
            options: options,
            onAnswer: { anyState, result, tx in
                guard var typed = anyState as? State else { return }
                onAnswer(&typed, result, &tx)
                anyState = typed
            }
        )
        var list = (runtimeActions["erasedActions"] as? [ErasedRuntimeAction]) ?? []
        list.append(.fileDialog(req))
        runtimeActions["erasedActions"] = list
    }

    /// Cursor position inside the element during `onDropFiles`, `onDropMove`, or `onDropRejected`
    /// (also readable in `onDropHover` when `true` / `onDropRejectedHover` when `true`).
    public var dropPoint: PointerPress? {
        get { runtimeActions["dropPoint"] as? PointerPress }
        set { runtimeActions["dropPoint"] = newValue }
    }
}

extension El {
    /// Attaches a system backdrop material (`NSVisualEffectView`) to this element.
    public func systemMaterial(_ material: SystemMaterial, blending: MaterialBlendingMode = .behindWindow) -> Self {
        var copy = self
        copy.runtimeExtras["systemMaterial"] = material
        copy.runtimeExtras["systemMaterialBlending"] = blending
        return copy
    }

    /// Marks this element as an outbound OS drag source carrying `item`.
    public func dragOut(_ item: DragItem) -> Self {
        var copy = self
        copy.runtimeExtras["dragOutItem"] = item
        return copy
    }

    public var attachedSystemMaterial: SystemMaterial? {
        runtimeExtras["systemMaterial"] as? SystemMaterial
    }

    public var attachedDragOutItem: DragItem? {
        runtimeExtras["dragOutItem"] as? DragItem
    }
}

// MARK: - 11. Floating Overlay Panel (overlay.rs)

public enum ScreenEdge: String, Sendable, Equatable {
    case top
    case bottom
}

public enum OverlayPlacement: Sendable, Equatable {
    case edge(ScreenEdge, margin: Float)
    case edgeAligned(ScreenEdge, margin: Float, align: OverlayAlign, inset: Float)
    case rect(MotionRect)
    case fullDisplay

    public static func edge(
        _ edge: ScreenEdge,
        margin: Float,
        align: OverlayAlign,
        inset: Float = 0
    ) -> OverlayPlacement {
        .edgeAligned(edge, margin: margin, align: align, inset: inset)
    }
}

public enum OverlayKeyPolicy: Sendable, Equatable {
    case nonActivating
    case activating
    case none
}

public struct OverlayOptions: Sendable, Equatable {
    public var placement: OverlayPlacement
    public var legacyPlacement: OverlayPlacement?
    public var display: DisplayTarget
    public var followPointer: Bool
    public var level: OverlayLevel
    public var excludeFromCapture: Bool
    public var keyPolicy: OverlayKeyPolicy
    public var input: OverlayInput
    public var prewarm: Bool
    public var releaseGpuWhenHidden: Bool
    public var releaseGpuAfter: Double?
    public var levelOffset: Int
    public var interactive: Bool
    public var srgbBlend: Bool
    public var macosLevel: Int?
    public var modifierKeys: Bool
    public var animateReveal: Bool

    public init(
        placement: OverlayPlacement = .edge(.top, margin: 16),
        keyPolicy: OverlayKeyPolicy = .nonActivating,
        releaseGpuWhenHidden: Bool = false,
        levelOffset: Int = 0
    ) {
        self.placement = placement
        self.legacyPlacement = nil
        self.display = .primary
        self.followPointer = false
        self.level = .status
        self.excludeFromCapture = false
        self.keyPolicy = keyPolicy
        self.input = .legacy
        self.prewarm = false
        self.releaseGpuWhenHidden = releaseGpuWhenHidden
        self.releaseGpuAfter = releaseGpuWhenHidden ? 0.0 : nil
        self.levelOffset = levelOffset
        self.interactive = false
        self.srgbBlend = true
        self.macosLevel = nil
        self.modifierKeys = false
        self.animateReveal = false
    }

    public init(
        placement: OverlayPlacement? = nil,
        display: DisplayTarget = .primary,
        followPointer: Bool = false,
        level: OverlayLevel = .status,
        excludeFromCapture: Bool = false,
        keyPolicy: OverlayKeyPolicy = .nonActivating,
        input: OverlayInput = .legacy,
        prewarm: Bool = false,
        releaseGpuWhenHidden: Bool = false,
        releaseGpuAfter: Double? = nil,
        levelOffset: Int = 0,
        interactive: Bool = false,
        srgbBlend: Bool = true,
        macosLevel: Int? = nil,
        modifierKeys: Bool = false,
        animateReveal: Bool = false
    ) {
        self.placement = placement ?? .edge(.top, margin: 16)
        self.legacyPlacement = placement
        self.display = display
        self.followPointer = followPointer
        self.level = level
        self.excludeFromCapture = excludeFromCapture
        self.keyPolicy = keyPolicy
        self.input = input
        self.prewarm = prewarm
        self.releaseGpuWhenHidden = releaseGpuWhenHidden
        self.releaseGpuAfter = releaseGpuAfter ?? (releaseGpuWhenHidden ? 0.0 : nil)
        self.levelOffset = levelOffset
        self.interactive = interactive
        self.srgbBlend = srgbBlend
        self.macosLevel = macosLevel
        self.modifierKeys = modifierKeys
        self.animateReveal = animateReveal
    }

    public var resolvedPlacement: OverlayPlacement? {
        legacyPlacement ?? placement
    }
}

public struct OverlaySpec<State> {
    public var name: String
    public var size: Vec2
    public var edge: ScreenEdge
    public var margin: Float
    public var align: OverlayAlign
    public var inset: Float
    public var interactive: Bool
    public var options: OverlayOptions
    public var makeState: () -> State
    public var view: (State, inout Cx<State>) -> El<State>

    public init(
        name: String,
        size: Vec2,
        edge: ScreenEdge = .top,
        margin: Float = 0,
        align: OverlayAlign = .center,
        inset: Float = 0,
        interactive: Bool = false,
        options: OverlayOptions = OverlayOptions(),
        makeState: @escaping () -> State,
        view: @escaping (State, inout Cx<State>) -> El<State>
    ) {
        self.name = name
        self.size = size
        self.edge = edge
        self.margin = margin
        self.align = align
        self.inset = inset
        self.interactive = interactive
        var merged = options
        if interactive {
            merged.interactive = true
        }
        self.options = merged
        self.makeState = makeState
        self.view = view
    }

    public func configured(_ options: OverlayOptions) -> ConfiguredOverlay<State> {
        var copy = options
        if interactive { copy.interactive = true }
        return ConfiguredOverlay(spec: self, options: copy)
    }
}

/// Builder wrapper preserving source compatibility on `OverlaySpec` (`overlay/options.rs`).
public struct ConfiguredOverlay<State> {
    public var spec: OverlaySpec<State>
    public var options: OverlayOptions
    public var onKey: ((inout State, KeyEvent, inout Tx) -> Bool)?
    public var onFocus: ((inout State, Bool, inout Tx) -> Void)?
    public var poll: ((inout State, Double, inout Tx) -> Bool)?
    public var onCreated: ((OverlayCreated) -> Void)?
    public var setup: ((inout State, Waker) -> Void)?

    public init(spec: OverlaySpec<State>, options: OverlayOptions? = nil) {
        self.spec = spec
        var resolved = options ?? spec.options
        if spec.interactive { resolved.interactive = true }
        self.options = resolved
    }

    public func onKey(_ handler: @escaping (inout State, KeyEvent, inout Tx) -> Bool) -> Self {
        var copy = self; copy.onKey = handler; return copy
    }

    public func onFocus(_ handler: @escaping (inout State, Bool, inout Tx) -> Void) -> Self {
        var copy = self; copy.onFocus = handler; return copy
    }

    public func poll(_ handler: @escaping (inout State, Double, inout Tx) -> Bool) -> Self {
        var copy = self; copy.poll = handler; return copy
    }

    public func onCreated(_ handler: @escaping (OverlayCreated) -> Void) -> Self {
        var copy = self; copy.onCreated = handler; return copy
    }

    public func setup(_ handler: @escaping (inout State, Waker) -> Void) -> Self {
        var copy = self; copy.setup = handler; return copy
    }

    public func srgbBlend(_ enabled: Bool) -> Self {
        var copy = self; copy.options.srgbBlend = enabled; return copy
    }

    public func macosLevel(_ level: Int) -> Self {
        var copy = self; copy.options.macosLevel = level; return copy
    }

    public func modifierKeys(_ enabled: Bool = true) -> Self {
        var copy = self; copy.options.modifierKeys = enabled; return copy
    }

    public func animateReveal(_ enabled: Bool = true) -> Self {
        var copy = self; copy.options.animateReveal = enabled; return copy
    }

    public func releaseGpuWhenHidden() -> Self {
        var copy = self
        copy.options.releaseGpuWhenHidden = true
        copy.options.releaseGpuAfter = 0.0
        return copy
    }

    public func releaseGpuAfter(_ seconds: Double) -> Self {
        var copy = self
        copy.options.releaseGpuAfter = max(0.0, seconds)
        copy.options.releaseGpuWhenHidden = seconds <= 0.0
        return copy
    }

    public func prewarm(_ enabled: Bool = true) -> Self {
        var copy = self; copy.options.prewarm = enabled; return copy
    }

    public func makeHandle() -> OverlayHandle<State> {
        OverlayHandle(configured: self)
    }
}

/// Live handle to a floating overlay (`overlay.rs`), backed on macOS by a real `NSPanel` + `MetalRenderer` + `Runtime`.
public final class OverlayHandle<State>: @unchecked Sendable {
    private let lock = NSLock()
    public let name: String
    public private(set) var isVisible: Bool = false
    public private(set) var size: Vec2
    public private(set) var options: OverlayOptions
    public private(set) var placementSpec: OverlayGeometry.Placement
    public private(set) var availability: OverlayAvailability = .pending
    public private(set) var failure: String? = nil
    public private(set) var surfaceDescription: String? = nil
    public private(set) var surfaceStats: OverlaySurfaceSnapshot = OverlaySurfaceSnapshot()
    public private(set) var overlayPresence: OverlayPresence = .initial
    public private(set) var releasePolicy: OverlayGpuRelease
    public private(set) var isDirty: Bool = true
    public private(set) var isIdle: Bool = true
    public private(set) var isFrameless: Bool = true
    public private(set) var systemDark: Bool = true
    public private(set) var systemContrast: Bool = false
    public private(set) var systemScrollBars = SystemScrollBars.current()
    public private(set) var wakeDeadline: Double? = nil
    private var cachedWindowNumber: UInt32? = nil
    private var cachedCapabilities = OverlayCapabilities()

    public let runtime: Runtime<State>
    private let pollHandler: ((inout State, Double, inout Tx) -> Bool)?
    private let focusHandler: ((inout State, Bool, inout Tx) -> Void)?
    private let onCreatedHandler: ((OverlayCreated) -> Void)?
    private var didRunSetup: Bool = false
    private let setupHandler: ((inout State, Waker) -> Void)?

    #if os(macOS)
    @MainActor private var macHost: RuneOverlayMacOSHost<State>?
    @MainActor private lazy var overlayPopupPresenter = MacOSPopupMenuPresenter()
    @MainActor private lazy var overlayDragOutCoordinator = MacOSDragOutCoordinator()
    #endif

    public convenience init(spec: OverlaySpec<State>) {
        self.init(configured: ConfiguredOverlay(spec: spec))
    }

    public init(configured: ConfiguredOverlay<State>) {
        let spec = configured.spec
        let opts = configured.options
        self.name = spec.name
        self.size = Vec2(max(1, spec.size.x), max(1, spec.size.y))
        self.options = opts
        self.placementSpec = OverlayGeometry.Placement(
            size: self.size,
            edge: spec.edge,
            margin: spec.margin,
            align: spec.align,
            inset: spec.inset
        )
        #if os(macOS)
        let isMacOS = true
        #else
        let isMacOS = false
        #endif
        self.releasePolicy = OverlayGpuRelease.make(afterSeconds: opts.releaseGpuAfter, isMacOS: isMacOS)
        self.pollHandler = configured.poll
        self.focusHandler = configured.onFocus
        self.onCreatedHandler = configured.onCreated
        self.setupHandler = configured.setup

        let prefs = SystemPreferences.current()
        let dark = prefs.darkMode ?? true
        self.systemDark = dark
        self.systemContrast = prefs.contrast != nil

        let initialState = spec.makeState()
        let onKey = configured.onKey
        let rt = Runtime<State>(
            state: initialState,
            viewport: self.size,
            pixelScale: 2.0,
            systemDark: dark,
            reducedMotion: prefs.reducedMotion,
            onKey: onKey.map { handler in
                { state, event, tx in handler(&state, event, &tx) }
            },
            view: spec.view
        )
        rt.nativeOverlay = true
        rt.modifierKeysEnabled = opts.modifierKeys
        rt.srgbBlend = opts.srgbBlend
        rt.clearColor = Color.transparent
        rt.setSystemContrast(prefs.contrast)
        self.runtime = rt

        if let setupHandler {
            didRunSetup = true
            var st = rt.state
            setupHandler(&st, rt.waker)
            rt.state = st
            rt.markNeedsCommit(settle: true)
        }

        #if os(macOS)
        if opts.prewarm {
            runOnMainActor {
                let host = self.makeMacHostIfNeeded()
                host.prewarm()
                self.lock.lock()
                self.surfaceDescription = host.surfaceDescription
                self.cachedWindowNumber = host.windowNumber
                self.cachedCapabilities = host.capabilities
                self.lock.unlock()
            }
        }
        #else
        lock.lock()
        self.availability = .available
        self.surfaceDescription = "Software headless overlay"
        lock.unlock()
        #endif
    }

    #if os(macOS)
    @MainActor
    private func makeMacHostIfNeeded() -> RuneOverlayMacOSHost<State> {
        if let macHost { return macHost }
        lock.lock()
        let currentSize = size
        let currentPlacement = placementSpec
        let currentOptions = options
        let release = releasePolicy == .now
        lock.unlock()

        let host = RuneOverlayMacOSHost<State>(
            size: currentSize,
            placement: currentPlacement,
            options: currentOptions,
            releaseWhenHidden: release
        )
        host.onCreated = { [weak self] created in
            guard let self else { return }
            self.lock.lock()
            self.availability = .available
            self.cachedWindowNumber = created.windowNumber
            self.cachedCapabilities = created.capabilities
            self.lock.unlock()
            self.onCreatedHandler?(created)
        }
        host.onPanelStateChanged = { [weak self] winNum, caps in
            guard let self else { return }
            self.lock.lock()
            self.cachedWindowNumber = winNum
            self.cachedCapabilities = caps
            self.lock.unlock()
        }
        host.onFadeCompleted = { [weak self] _, ordered in
            guard let self, !ordered else { return }
            self.overlayPopupPresenter.cancel()
            self.lock.lock()
            self.runtime.cancelPopups()
            self.lock.unlock()
            self.lock.lock()
            let now: Double
            if let fadeEnd = self.overlayPresence.fadeEnd {
                now = max(Date().timeIntervalSinceReferenceDate, fadeEnd)
            } else {
                now = Date().timeIntervalSinceReferenceDate
            }
            let effects = self.overlayPresence.step(.due(now: now), release: self.releasePolicy)
            self.isVisible = false
            if !self.overlayPresence.isDrawing {
                self.isFrameless = true
                self.isIdle = true
                self.isDirty = false
                self.wakeDeadline = self.overlayPresence.deadline
            }
            self.lock.unlock()
            if effects.contains(.releaseGpu) {
                self.macHost?.releasePanel()
            }
        }
        host.onFailure = { [weak self] msg in
            self?.lock.lock()
            self?.failure = msg
            self?.availability = .unavailable
            self?.lock.unlock()
        }
        host.onSurfaceSnapshot = { [weak self] snap in
            self?.lock.lock()
            self?.surfaceStats = snap
            self?.lock.unlock()
        }
        host.shouldKeepDrawing = { [weak self] in
            guard let self else { return false }
            self.lock.lock()
            let keep = self.overlayPresence.isDrawing && !self.overlayPresence.isOccluded &&
                (self.isDirty || !self.isIdle || self.runtime.isAnimating || self.wakeDeadline != nil)
            self.lock.unlock()
            return keep
        }
        host.onHideCleanup = { [weak self] in
            guard let self else { return }
            self.overlayPopupPresenter.cancel()
            self.lock.lock()
            self.runtime.cancelPopups()
            self.lock.unlock()
        }
        host.configureView = { [weak self] view in
            guard let self else { return }
            view.onEvaluateFrame = { [weak self] now, settle in
                guard let self else {
                    return (
                        RefScene(width: 1, height: 1, srgbBlend: true, clearColor: .zero, glyphs: R8Atlas(), images: RGBA8Atlas(), primitives: []),
                        [],
                        false,
                        true
                    )
                }
                return self.evaluateLockedFrame(at: now, forceSettle: settle)
            }
            view.onPointerMove = { [weak self] pt, mods, now in
                self?.withLockedRuntime { rt in
                    rt.pointerMove(to: pt, mods: mods, at: now)
                }
                view.renderFrame(settle: false, visible: true, drawing: true)
            }
            view.onPointerExit = { [weak self] now in
                self?.withLockedRuntime { rt in rt.pointerExit(at: now) }
                view.renderFrame(settle: false, visible: true, drawing: true)
            }
            view.onPointerDown = { [weak self] pt, btn, mods, now in
                self?.withLockedRuntime { rt in rt.pointerDown(at: pt, button: btn, mods: mods, at: now) }
                view.renderFrame(settle: false, visible: true, drawing: true)
            }
            view.onPointerUp = { [weak self] pt, btn, mods, now in
                self?.withLockedRuntime { rt in rt.pointerUp(at: pt, button: btn, mods: mods, at: now) }
                view.renderFrame(settle: false, visible: true, drawing: true)
            }
            view.onPointerReleaseLost = { [weak self] pt, now in
                self?.withLockedRuntime { rt in rt.pointerReleaseLost(at: pt, at: now) }
                view.renderFrame(settle: false, visible: true, drawing: true)
            }
            view.onWheel = { [weak self] wev, pt, now in
                self?.withLockedRuntime { rt in rt.wheel(wev, at: pt, now: now) }
                view.renderFrame(settle: false, visible: true, drawing: true)
            }
            view.onKeyDown = { [weak self] kev, now in
                guard let self else { return false }
                let handled = self.withLockedRuntime { rt in rt.keyDown(kev, at: now) }
                if handled {
                    view.renderFrame(settle: false, visible: true, drawing: true)
                }
                return handled
            }
            view.onAppearanceChanged = { [weak self] dark in
                self?.setThemeDark(dark)
            }
            view.onAfterFrame = { [weak self] metalView in
                guard let self else { return }
                let dragStart = self.withLockedRuntime { rt in rt.takeDragOutStart() }
                if let dragStart {
                    self.overlayDragOutCoordinator.start(dragStart, in: metalView) { [weak self] outcome in
                        guard let self else { return }
                        let now = Date().timeIntervalSinceReferenceDate
                        self.withLockedRuntime { rt in rt.finishDragOut(outcome, at: now) }
                        metalView.renderFrame(settle: false, visible: true, drawing: true)
                    }
                }
                if !self.overlayPopupPresenter.isPresenting {
                    let showOpt: PopupShow? = self.withLockedRuntime { rt in
                        while let taken = rt.takePopup() {
                            switch taken {
                            case .failure: continue
                            case .success(let show): return show
                            }
                        }
                        return nil
                    }
                    if let show = showOpt {
                        self.overlayPopupPresenter.present(show, in: metalView) { [weak self] picked in
                            guard let self else { return }
                            self.withLockedRuntime { rt in try? rt.resolvePopup(picked) }
                            metalView.renderFrame(settle: false, visible: true, drawing: true)
                        }
                    }
                }
            }
            view.onNeedsResyncGeometry = { [weak self] w, h, scale in
                self?.withLockedRuntime { rt in
                    rt.viewport = Vec2(max(1, w), max(1, h))
                    rt.pixelScale = max(0.5, scale)
                }
            }
        }
        self.macHost = host
        return host
    }
    #endif

    public var windowNumber: UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return cachedWindowNumber
    }

    public var capabilities: OverlayCapabilities {
        lock.lock()
        defer { lock.unlock() }
        return cachedCapabilities
    }

    public var captureExclusion: OverlaySupport {
        capabilities.captureExclusion
    }

    public func show() {
        fadeIn(0.0)
    }

    public func hide() {
        fadeOut(0.0)
    }

    public func fadeIn(_ durationSeconds: Double) {
        let dur = max(0.0, durationSeconds)
        lock.lock()
        let wasFading = overlayPresence.isFading
        _ = overlayPresence.step(.show, release: releasePolicy)
        isVisible = true
        isFrameless = false
        let settle = !wasFading && !options.animateReveal
        if settle {
            runtime.markNeedsCommit(settle: true)
        }
        isDirty = true
        isIdle = false
        lock.unlock()

        #if os(macOS)
        runOnMainActor {
            let host = self.makeMacHostIfNeeded()
            host.show(fadeSeconds: dur, settleBeforeReveal: settle)
            self.lock.lock()
            self.surfaceDescription = host.surfaceDescription
            self.cachedWindowNumber = host.windowNumber
            self.cachedCapabilities = host.capabilities
            self.lock.unlock()
        }
        #endif
    }

    public func fadeOut(_ durationSeconds: Double, now: Double = Date().timeIntervalSinceReferenceDate) {
        let dur = max(0.0, durationSeconds)
        lock.lock()
        let effects = overlayPresence.step(.hide(fadeSeconds: dur, now: now), release: releasePolicy)
        isVisible = false
        if effects.contains(.stopDrawing) || !overlayPresence.isShown {
            runtime.releaseHeldModifiers(at: now)
        }
        for effect in effects {
            switch effect {
            case .stopDrawing:
                isFrameless = true
                isIdle = true
                wakeDeadline = nil
            case .hideWindow:
                if let deadline = overlayPresence.deadline {
                    wakeDeadline = deadline
                }
            case .releaseGpu:
                break
            }
        }
        lock.unlock()

        #if os(macOS)
        runOnMainActor {
            self.macHost?.hide(fadeSeconds: dur)
        }
        #endif
    }

    public func advanceDue(at now: Double) {
        lock.lock()
        let effects = overlayPresence.step(.due(now: now), release: releasePolicy)
        for effect in effects {
            switch effect {
            case .stopDrawing:
                isFrameless = true
                isIdle = true
                wakeDeadline = nil
            case .hideWindow:
                break
            case .releaseGpu:
                break
            }
        }
        lock.unlock()
        #if os(macOS)
        if effects.contains(.releaseGpu) {
            runOnMainActor {
                self.macHost?.releasePanel()
            }
        }
        #endif
    }

    @discardableResult
    public func setOccluded(_ covered: Bool) -> Bool {
        lock.lock()
        let accepted = overlayPresence.setOccluded(covered)
        lock.unlock()
        return accepted
    }

    public func requestKeys() {
        #if os(macOS)
        runOnMainActor {
            self.macHost?.requestKeys()
        }
        #endif
    }

    public func setInput(_ input: OverlayInput) {
        lock.lock()
        options.input = input
        let currentPlacement = placementSpec
        let opts = options
        lock.unlock()
        #if os(macOS)
        runOnMainActor {
            self.macHost?.updatePlacement(currentPlacement, options: opts)
        }
        #endif
    }

    public func setFollowPointer(_ follow: Bool) {
        lock.lock()
        options.followPointer = follow
        let currentPlacement = placementSpec
        let opts = options
        lock.unlock()
        #if os(macOS)
        runOnMainActor {
            self.macHost?.updatePlacement(currentPlacement, options: opts)
        }
        #endif
    }

    public func refollowPointer() {
        #if os(macOS)
        runOnMainActor {
            self.macHost?.placePanel()
        }
        #endif
    }

    public func setPlacement(_ placement: OverlayPlacement?) {
        lock.lock()
        options.legacyPlacement = placement
        if let placement {
            options.placement = placement
        }
        let currentPlacement = placementSpec
        let opts = options
        isDirty = true
        lock.unlock()
        #if os(macOS)
        runOnMainActor {
            self.macHost?.updatePlacement(currentPlacement, options: opts)
        }
        #endif
    }

    public func setDisplay(_ display: DisplayTarget) {
        lock.lock()
        options.display = display
        let currentPlacement = placementSpec
        let opts = options
        lock.unlock()
        #if os(macOS)
        runOnMainActor {
            self.macHost?.updatePlacement(currentPlacement, options: opts)
        }
        #endif
    }

    public func setEdge(_ edge: ScreenEdge) {
        lock.lock()
        placementSpec.edge = edge
        options.legacyPlacement = nil
        let currentPlacement = placementSpec
        let opts = options
        lock.unlock()
        #if os(macOS)
        runOnMainActor {
            self.macHost?.updatePlacement(currentPlacement, options: opts)
        }
        #endif
    }

    public func place(edge: ScreenEdge, margin: Float) {
        lock.lock()
        placementSpec.edge = edge
        placementSpec.margin = margin
        options.legacyPlacement = nil
        let currentPlacement = placementSpec
        let opts = options
        lock.unlock()
        #if os(macOS)
        runOnMainActor {
            self.macHost?.updatePlacement(currentPlacement, options: opts)
        }
        #endif
    }

    public func setAlign(_ align: OverlayAlign, inset: Float) {
        lock.lock()
        placementSpec.align = align
        placementSpec.inset = inset
        options.legacyPlacement = nil
        let currentPlacement = placementSpec
        let opts = options
        lock.unlock()
        #if os(macOS)
        runOnMainActor {
            self.macHost?.updatePlacement(currentPlacement, options: opts)
        }
        #endif
    }

    public func resize(_ newSize: Vec2) {
        let clamped = Vec2(max(1, newSize.x), max(1, newSize.y))
        lock.lock()
        size = clamped
        placementSpec.size = clamped
        runtime.viewport = clamped
        isDirty = true
        let currentPlacement = placementSpec
        let opts = options
        lock.unlock()
        #if os(macOS)
        runOnMainActor {
            self.macHost?.updatePlacement(currentPlacement, options: opts)
        }
        #endif
    }

    public func setMacosLevel(_ level: Int) {
        lock.lock()
        options.macosLevel = level
        lock.unlock()
        #if os(macOS)
        runOnMainActor {
            self.macHost?.setMacosLevel(level)
        }
        #endif
    }

    public func setExcludeFromCapture(_ exclude: Bool) {
        lock.lock()
        options.excludeFromCapture = exclude
        lock.unlock()
        #if os(macOS)
        runOnMainActor {
            self.macHost?.setCaptureExclusion(exclude)
        }
        #endif
    }

    public func update(_ body: (inout State) -> Void) {
        lock.lock()
        var s = runtime.state
        body(&s)
        runtime.state = s
        runtime.markNeedsCommit(settle: false)
        isDirty = true
        isIdle = false
        lock.unlock()
    }

    public func updateTx(_ body: (inout State, inout Tx) -> Void) {
        _ = updateIf { state, tx in
            body(&state, &tx)
            return true
        }
    }

    @discardableResult
    public func updateIf(_ body: (inout State, inout Tx) -> Bool) -> Bool {
        lock.lock()
        var s = runtime.state
        var tx = Tx()
        let changed = body(&s, &tx)
        runtime.state = s
        if changed {
            runtime.markNeedsCommit(settle: tx.settleRequested)
            isDirty = true
            isIdle = false
        }
        if let wake = tx.runtimeActions["wakeAfter"] as? Double {
            wakeDeadline = runtime.currentTime + wake
            isIdle = false
        }
        lock.unlock()
        return changed
    }

    public func readState<R>(_ body: (State) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(runtime.state)
    }

    public func setThemeDark(_ dark: Bool) {
        lock.lock()
        if systemDark != dark || runtime.systemDark != dark {
            systemDark = dark
            runtime.systemDark = dark
            isDirty = true
            isIdle = false
        }
        lock.unlock()
    }

    public func setScrollBars(_ prefs: SystemScrollBars) {
        lock.lock()
        if systemScrollBars != prefs {
            systemScrollBars = prefs
            runtime.markNeedsCommit(settle: false)
            isDirty = true
            isIdle = false
        }
        lock.unlock()
    }

    public func setContrast(_ highContrast: Bool) {
        lock.lock()
        if systemContrast != highContrast {
            systemContrast = highContrast
            runtime.markNeedsCommit(settle: false)
            isDirty = true
            isIdle = false
        }
        lock.unlock()
    }

    public func setAccent(_ accent: SystemAccent) {
        lock.lock()
        if runtime.systemAccent() != accent {
            runtime.setSystemAccent(accent)
            runtime.markNeedsCommit(settle: false)
            isDirty = true
            isIdle = false
        }
        lock.unlock()
    }

    public func deliverFocus(_ focused: Bool) {
        lock.lock()
        if !focused {
            runtime.releaseHeldModifiers(at: runtime.currentTime)
        }
        if let focusHandler {
            var s = runtime.state
            var tx = Tx()
            focusHandler(&s, focused, &tx)
            runtime.state = s
            runtime.markNeedsCommit(settle: tx.settleRequested)
            isDirty = true
        }
        lock.unlock()
    }

    /// Evaluates a single frame deterministically at `now` (used both live and in headless tests).
    @discardableResult
    public func present(at now: Double) -> RefScene? {
        lock.lock()
        if let deadline = overlayPresence.deadline, deadline <= now {
            _ = overlayPresence.step(.due(now: now), release: releasePolicy)
        }
        guard overlayPresence.isDrawing else {
            isFrameless = true
            isIdle = true
            lock.unlock()
            return nil
        }
        isFrameless = false
        let (scene, _, _, _) = evaluateStateAndFrameLocked(at: now, forceSettle: false)
        lock.unlock()
        return scene
    }

    private func evaluateLockedFrame(
        at now: Double,
        forceSettle: Bool
    ) -> (scene: RefScene, regions: [MotionRect], isAnimating: Bool, srgbBlend: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return evaluateStateAndFrameLocked(at: now, forceSettle: forceSettle)
    }

    private func evaluateStateAndFrameLocked(
        at now: Double,
        forceSettle: Bool
    ) -> (scene: RefScene, regions: [MotionRect], isAnimating: Bool, srgbBlend: Bool) {
        if forceSettle {
            runtime.markNeedsCommit(settle: true)
        }
        var pollAskedNextFrame = false
        if let pollHandler {
            var s = runtime.state
            var tx = Tx()
            let changed = pollHandler(&s, now, &tx)
            runtime.state = s
            if changed {
                runtime.markNeedsCommit(settle: tx.settleRequested)
            }
            if let wake = tx.runtimeActions["wakeAfter"] as? Double {
                wakeDeadline = now + wake
                pollAskedNextFrame = true
            } else {
                wakeDeadline = nil
            }
        }

        let scene = runtime.frame(at: now)
        let regions = runtime.overlayInteractiveRegions()
        isDirty = false
        isIdle = !(runtime.isAnimating || pollAskedNextFrame)
        surfaceStats = OverlaySurfaceSnapshot(
            frameCount: surfaceStats.frameCount &+ 1,
            pixelWidth: scene.width,
            pixelHeight: scene.height,
            backingScale: runtime.pixelScale,
            srgbBlend: runtime.srgbBlend,
            isVisible: isVisible,
            isDrawing: overlayPresence.isDrawing,
            isAnimating: runtime.isAnimating
        )
        return (scene, regions, runtime.isAnimating, runtime.srgbBlend)
    }

    private func withLockedRuntime<R>(_ body: (Runtime<State>) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(runtime)
    }

    #if os(macOS)
    private func runOnMainActor(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            Task { @MainActor in work() }
        }
    }
    #endif
}

// MARK: - 12. Web Scene Export (runtime/web/)

/// Serializes a `RefScene` into portable JSON or standalone HTML5 Canvas markup for web showcase targets.
public enum WebSceneExporter {
    public static func exportJSON(scene: RefScene) throws -> Data {
        let prims: [[String: Any]] = scene.primitives.map { p in
            [
                "kind": Int(p.params.y),
                "rect": [p.rect.x, p.rect.y, p.rect.z, p.rect.w],
                "radii": [p.radii.x, p.radii.y, p.radii.z, p.radii.w],
                "fill": [p.fill.x, p.fill.y, p.fill.z, p.fill.w],
                "border": [p.border.x, p.border.y, p.border.z, p.border.w],
                "clip": [p.clip.x, p.clip.y, p.clip.z, p.clip.w],
            ]
        }
        let doc: [String: Any] = [
            "width": scene.width,
            "height": scene.height,
            "primitiveCount": scene.primitives.count,
            "primitives": prims,
        ]
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }

    public static func exportHTML(title: String, scene: RefScene) throws -> String {
        let json = String(data: try exportJSON(scene: scene), encoding: .utf8) ?? "{}"
        return """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="margin:0;background:#111;display:grid;place-items:center;min-height:100vh;">
        <canvas id="rune" width="\(scene.width)" height="\(scene.height)"></canvas>
        <script>const RUNE_SCENE = \(json);</script>
        </body>
        </html>
        """
    }
}
