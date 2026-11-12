import Foundation
import RuneMotion
import RuneRef

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
        self.content = ClipboardContent(text, html: html, rtf: rtf)
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

/// Custom image preview shown under the cursor during an OS drag session.
public struct DragImage: Sendable, Equatable {
    public var width: UInt32
    public var height: UInt32
    public var rgba: Data
    public var hotspot: Vec2

    public init(width: UInt32, height: UInt32, rgba: Data, hotspot: Vec2 = .zero) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.hotspot = hotspot
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

    public func allowWithinApp(_ allow: Bool = true) -> DragItem {
        var copy = self
        copy.withinApp = allow
        return copy
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
            throw FileDialogError("expected \(next.kind.rawValue) dialog, received \(kind.rawValue)")
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
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenUrlError.empty }
        guard trimmed.count <= maxLength else { throw OpenUrlError.invalid }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "\\\"<>`^{|}"))
        if trimmed.unicodeScalars.contains(where: { forbidden.contains($0) }) {
            throw OpenUrlError.invalid
        }
        guard let colonIdx = trimmed.firstIndex(of: ":") else {
            throw OpenUrlError.invalid
        }
        let scheme = String(trimmed[..<colonIdx]).lowercased()
        let rest = String(trimmed[trimmed.index(after: colonIdx)...])
        guard !scheme.isEmpty else { throw OpenUrlError.invalid }
        switch scheme {
        case "http", "https":
            guard rest.hasPrefix("//") else { throw OpenUrlError.invalid }
            let after = String(rest.dropFirst(2))
            let hostPart = after.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
            guard !hostPart.isEmpty, !hostPart.contains("["), !hostPart.contains("]") else {
                throw OpenUrlError.invalid
            }
        case "mailto":
            guard !rest.isEmpty, !rest.hasPrefix("//") else { throw OpenUrlError.invalid }
        default:
            throw OpenUrlError.unsupportedScheme(scheme)
        }
        return "\(scheme):\(rest)"
    }

    @discardableResult
    public func open(_ raw: String, sameTab: Bool = false) throws -> String {
        let normalized = try Self.validate(raw)
        let req = OpenUrlRequest(url: normalized, sameTab: sameTab)
        if headless {
            lock.lock()
            recordedRequests.append(req)
            lock.unlock()
            return normalized
        }
        #if os(macOS)
        guard let nsUrl = URL(string: normalized), NSWorkspace.shared.open(nsUrl) else {
            throw OpenUrlError.failed("NSWorkspace refused to open \(normalized)")
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
                nsItem.state = (item.checked || selectedId == item.id) ? .on : .off
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

    public func dispatch(id: String, state: inout State, tx: inout Tx) throws {
        guard let item = items.first(where: { !$0.isSeparator && $0.id == id }) else {
            throw MenuError.unknownItem(id)
        }
        guard item.enabled else {
            throw MenuError.disabled(id)
        }
        item.action(&state, &tx)
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
}

public enum TrayItem: Sendable, Equatable {
    case action(id: String, label: String, enabled: Bool)
    case separator

    public static func action(id: String, label: String) -> TrayItem {
        .action(id: id, label: label, enabled: true)
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
    @MainActor private var statusItem: NSStatusItem?
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
        lock.lock()
        let current = spec
        lock.unlock()
        item.button?.title = current.title
        item.button?.toolTip = current.tooltip
        if !current.iconName.isEmpty {
            item.button?.image = NSImage(systemSymbolName: current.iconName, accessibilityDescription: current.title)
        }
        let menu = NSMenu()
        for entry in current.menu {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .action(let id, let label, let enabled):
                let mi = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                mi.representedObject = id
                mi.isEnabled = enabled
                menu.addItem(mi)
            }
        }
        item.menu = menu
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

public enum NativeSurfaceFormat: String, Sendable, Equatable {
    case rgba8
    case bgra8
    case nv12
}

public struct NativeSurfaceFrame: Sendable, Equatable {
    public let width: UInt32
    public let height: UInt32
    public let format: NativeSurfaceFormat
    public let bytes: Data
    public let timestampSeconds: Double

    public init(width: UInt32, height: UInt32, format: NativeSurfaceFormat = .rgba8, bytes: Data, timestampSeconds: Double = 0) {
        self.width = width
        self.height = height
        self.format = format
        self.bytes = bytes
        self.timestampSeconds = timestampSeconds
    }
}

public final class NativeSurface: @unchecked Sendable {
    private let lock = NSLock()
    public let id: UInt64
    private var currentFrame: NativeSurfaceFrame?

    public init(id: UInt64) {
        self.id = id
    }

    public func publish(_ frame: NativeSurfaceFrame) {
        lock.lock()
        currentFrame = frame
        lock.unlock()
    }

    public func latestFrame() -> NativeSurfaceFrame? {
        lock.lock()
        defer { lock.unlock() }
        return currentFrame
    }
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
    public let home: URL
    public let config: URL
    public let data: URL
    public let cache: URL
    public let state: URL
    public let logs: URL
    public let downloads: URL

    public static func sanitize(_ appId: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return appId.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
    }

    public static var defaultHomeURL: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    public static func resolve(appId: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> AppDirs {
        let cleanId = sanitize(appId)
        let homeURL: URL
        if let h = environment["HOME"], !h.isEmpty {
            homeURL = URL(fileURLWithPath: h, isDirectory: true)
        } else {
            homeURL = defaultHomeURL
        }

        if let root = environment[rootEnv], !root.isEmpty {
            return rooted(at: URL(fileURLWithPath: root, isDirectory: true), appId: appId, home: homeURL)
        }

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
            downloads: downloadsDir
        )
        #else
        let xdgConfig = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? homeURL.appendingPathComponent(".config", isDirectory: true)
        let xdgData = environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? homeURL.appendingPathComponent(".local/share", isDirectory: true)
        let xdgCache = environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? homeURL.appendingPathComponent(".cache", isDirectory: true)
        let xdgState = environment["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? homeURL.appendingPathComponent(".local/state", isDirectory: true)
        return AppDirs(
            id: cleanId,
            home: homeURL,
            config: xdgConfig.appendingPathComponent(cleanId, isDirectory: true),
            data: xdgData.appendingPathComponent(cleanId, isDirectory: true),
            cache: xdgCache.appendingPathComponent(cleanId, isDirectory: true),
            state: xdgState.appendingPathComponent(cleanId, isDirectory: true),
            logs: xdgState.appendingPathComponent("\(cleanId)/logs", isDirectory: true),
            downloads: homeURL.appendingPathComponent("Downloads", isDirectory: true)
        )
        #endif
    }

    public static func rooted(at root: URL, appId: String, home: URL = AppDirs.defaultHomeURL) -> AppDirs {
        let cleanId = sanitize(appId)
        return AppDirs(
            id: cleanId,
            home: home,
            config: root.appendingPathComponent("config/\(cleanId)", isDirectory: true),
            data: root.appendingPathComponent("data/\(cleanId)", isDirectory: true),
            cache: root.appendingPathComponent("cache/\(cleanId)", isDirectory: true),
            state: root.appendingPathComponent("state/\(cleanId)", isDirectory: true),
            logs: root.appendingPathComponent("logs/\(cleanId)", isDirectory: true),
            downloads: root.appendingPathComponent("downloads", isDirectory: true)
        )
    }

    public func sibling(_ appId: String) -> AppDirs {
        let cleanId = Self.sanitize(appId)
        return AppDirs(
            id: cleanId,
            home: home,
            config: config.deletingLastPathComponent().appendingPathComponent(cleanId, isDirectory: true),
            data: data.deletingLastPathComponent().appendingPathComponent(cleanId, isDirectory: true),
            cache: cache.deletingLastPathComponent().appendingPathComponent(cleanId, isDirectory: true),
            state: state.deletingLastPathComponent().appendingPathComponent(cleanId, isDirectory: true),
            logs: logs.deletingLastPathComponent().appendingPathComponent(cleanId, isDirectory: true),
            downloads: downloads
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

    public static func open(appId: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Prefs {
        if let custom = environment[AppDirs.prefsDirEnv], !custom.isEmpty {
            let dir = URL(fileURLWithPath: custom, isDirectory: true)
            return at(dir.appendingPathComponent("\(AppDirs.sanitize(appId))/prefs.json"))
        }
        let dirs = AppDirs.resolve(appId: appId, environment: environment)
        return at(dirs.config.appendingPathComponent("prefs.json"))
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
            if FileManager.default.fileExists(atPath: path.path) {
                _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: path)
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
            return (.quitting(hooks: hooks, after: mergedAfter), ending ? [.closeAndExit] : [])
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
}

public enum TaskbarProgress: String, Sendable, Equatable {
    case none
    case busy
    case paused
    case error
}

public struct TaskbarState: Sendable, Equatable {
    public var progress: TaskbarProgress
    public var badgeCount: UInt32
    public var badgeDescription: String

    public init(progress: TaskbarProgress = .none, badgeCount: UInt32 = 0, badgeDescription: String = "") {
        self.progress = progress
        self.badgeCount = badgeCount
        self.badgeDescription = badgeCount == 0 ? "" : badgeDescription
    }

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

// MARK: - 10. Tx & El Extensions

extension Tx {
    /// Copies a rich clipboard payload (text, HTML, RTF, image, files, concealed).
    public mutating func copyRich(_ payload: RichClipboardPayload) {
        clipboardWrite = payload.content
        runtimeActions["richClipboardWrite"] = payload
    }

    /// Requests opening an `http:`, `https:`, or `mailto:` URL.
    public mutating func openUrl(_ url: String, sameTab: Bool = false) throws {
        let normalized = try UrlOpener.validate(url)
        var list = (runtimeActions["openUrlRequests"] as? [OpenUrlRequest]) ?? []
        list.append(OpenUrlRequest(url: normalized, sameTab: sameTab))
        runtimeActions["openUrlRequests"] = list
    }

    /// Initiates an outbound OS drag session with `item`.
    public mutating func dragOut(_ item: DragItem) {
        runtimeActions["dragOutItem"] = item
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
    case rect(MotionRect)
    case fullDisplay
}

public enum OverlayKeyPolicy: Sendable, Equatable {
    case nonActivating
    case activating
}

public struct OverlayOptions: Sendable, Equatable {
    public var placement: OverlayPlacement
    public var keyPolicy: OverlayKeyPolicy
    public var releaseGpuWhenHidden: Bool
    public var levelOffset: Int

    public init(
        placement: OverlayPlacement = .edge(.top, margin: 16),
        keyPolicy: OverlayKeyPolicy = .nonActivating,
        releaseGpuWhenHidden: Bool = false,
        levelOffset: Int = 0
    ) {
        self.placement = placement
        self.keyPolicy = keyPolicy
        self.releaseGpuWhenHidden = releaseGpuWhenHidden
        self.levelOffset = levelOffset
    }
}

public struct OverlaySpec<State> {
    public var name: String
    public var size: Vec2
    public var options: OverlayOptions
    public var makeState: () -> State
    public var view: (State, inout Cx<State>) -> El<State>

    public init(
        name: String,
        size: Vec2,
        options: OverlayOptions = OverlayOptions(),
        makeState: @escaping () -> State,
        view: @escaping (State, inout Cx<State>) -> El<State>
    ) {
        self.name = name
        self.size = size
        self.options = options
        self.makeState = makeState
        self.view = view
    }
}

public final class OverlayHandle<State>: @unchecked Sendable {
    private let lock = NSLock()
    public let name: String
    public private(set) var isVisible: Bool = false
    public private(set) var size: Vec2
    public private(set) var options: OverlayOptions
    private var state: State

    #if os(macOS)
    @MainActor private var panel: NSPanel?
    #endif

    public init(spec: OverlaySpec<State>) {
        self.name = spec.name
        self.size = spec.size
        self.options = spec.options
        self.state = spec.makeState()
    }

    public func show() {
        lock.lock()
        isVisible = true
        lock.unlock()
        #if os(macOS)
        Task { @MainActor in
            if self.panel == nil {
                let p = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: CGFloat(self.size.x), height: CGFloat(self.size.y)),
                    styleMask: [.nonactivatingPanel, .borderless],
                    backing: .buffered,
                    defer: false
                )
                p.level = .statusBar
                p.isOpaque = false
                p.backgroundColor = .clear
                p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                self.panel = p
            }
            self.panel?.orderFrontRegardless()
        }
        #endif
    }

    public func hide() {
        lock.lock()
        isVisible = false
        let release = options.releaseGpuWhenHidden
        lock.unlock()
        #if os(macOS)
        Task { @MainActor in
            self.panel?.orderOut(nil)
            if release {
                self.panel = nil
            }
        }
        #endif
    }

    public func update(_ body: (inout State) -> Void) {
        lock.lock()
        body(&state)
        lock.unlock()
    }

    public func readState<R>(_ body: (State) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }
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
