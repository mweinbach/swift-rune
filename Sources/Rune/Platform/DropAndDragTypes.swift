import Foundation
import RuneMotion

// MARK: - Per-Element Drop Spec

/// Per-element drop callbacks and file filter attached via `El.onDropFiles` / `El.acceptsExtensions`
/// (`rune::el::DropSpec`).
public struct DropSpec<State> {
    public var accepts: ((URL) -> Bool)?
    public var onDropFiles: ((inout State, [URL], inout Tx) -> Void)?
    public var onDropHover: ((inout State, Bool, inout Tx) -> Void)?
    public var onDropMove: ((inout State, [URL], inout Tx) -> Void)?
    public var onDropRejected: ((inout State, [URL], inout Tx) -> Void)?
    public var onDropRejectedHover: ((inout State, Bool, inout Tx) -> Void)?

    public init(
        accepts: ((URL) -> Bool)? = nil,
        onDropFiles: ((inout State, [URL], inout Tx) -> Void)? = nil,
        onDropHover: ((inout State, Bool, inout Tx) -> Void)? = nil,
        onDropMove: ((inout State, [URL], inout Tx) -> Void)? = nil,
        onDropRejected: ((inout State, [URL], inout Tx) -> Void)? = nil,
        onDropRejectedHover: ((inout State, Bool, inout Tx) -> Void)? = nil
    ) {
        self.accepts = accepts
        self.onDropFiles = onDropFiles
        self.onDropHover = onDropHover
        self.onDropMove = onDropMove
        self.onDropRejected = onDropRejected
        self.onDropRejectedHover = onDropRejectedHover
    }

    public func matches(_ url: URL) -> Bool {
        accepts?(url) ?? true
    }

    public func split(_ urls: [URL]) -> (accepted: [URL], rejected: [URL]) {
        guard let accepts else {
            return (urls, [])
        }
        var accepted: [URL] = []
        var rejected: [URL] = []
        for url in urls {
            if accepts(url) {
                accepted.append(url)
            } else {
                rejected.append(url)
            }
        }
        return (accepted, rejected)
    }

    public static func matchesExtension(_ allowedExtensions: [String], url: URL) -> Bool {
        let normalizedAllowed = Set(allowedExtensions.map {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
        })
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return normalizedAllowed.contains(ext)
    }
}

// MARK: - Outbound Drag-Out Request

/// Pending outbound OS drag request emitted by `Runtime` when pointer movement crosses the
/// element's drag threshold or `Tx.dragOut(_:)` fires.
public struct DragOutStart: Sendable, Equatable {
    public var item: DragItem
    public var bounds: MotionRect
    public var press: Vec2
    public var key: String?

    public init(item: DragItem, bounds: MotionRect, press: Vec2, key: String? = nil) {
        self.item = item
        self.bounds = bounds
        self.press = press
        self.key = key
    }
}

// MARK: - DragImage Helpers

extension DragImage {
    internal static func srgbDecode(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    internal static func srgbEncode(_ c: Float) -> Float {
        let clamped = max(0, min(1, c))
        return clamped <= 0.0031308
            ? clamped * 12.92
            : 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
    }

    /// PNG bytes backing this drag image (encoding legacy `rgba` pixels if needed).
    public func resolvedPNGData() -> Data? {
        if let pngData, !pngData.isEmpty {
            return pngData
        }
        guard width > 0, height > 0, rgba.count >= Int(width) * Int(height) * 4 else {
            return nil
        }
        return ClipboardImage.encodeRGBAAsPNG(width: Int(width), height: Int(height), rgba: rgba)
    }

    /// Computes the starting `[x, y, width, height]` frame in window points for this drag image.
    public func frame(bounds: MotionRect, press: Vec2, natural: Vec2) -> MotionRect {
        let size = pointsSize ?? natural
        switch placement {
        case .pointer:
            return .fromXYWH(press.x - size.x / 2.0, press.y - size.y / 2.0, size.x, size.y)
        case .element:
            let elemSize = pointsSize ?? Vec2(bounds.width, bounds.height)
            return .fromXYWH(bounds.left, bounds.top, max(1.0, elemSize.x), max(1.0, elemSize.y))
        case .at(let pt):
            return .fromXYWH(pt.x, pt.y, size.x, size.y)
        }
    }

    /// Composites this image over an opaque linear-sRGB `backing` color. Returns `nil` if decoding fails.
    public func over(_ backing: Color) -> DragImage? {
        let decoded: (width: UInt32, height: UInt32, rgba: Data)?
        if let pngData, !pngData.isEmpty {
            if let pngDecoded = try? PortablePNG.decode(pngData) {
                decoded = (UInt32(pngDecoded.width), UInt32(pngDecoded.height), Data(pngDecoded.rgba))
            } else if let img = ClipboardImage.decodeImageDataToRGBA(pngData) {
                // Undo premultiplied alpha produced by CoreGraphics `premultipliedLast` context
                var straight = [UInt8](img.rgba)
                let count = img.width * img.height
                for i in 0..<count {
                    let base = i * 4
                    let a = straight[base + 3]
                    if a > 0 && a < 255 {
                        let inv = 255.0 / Float(a)
                        straight[base] = UInt8(min(255, Int((Float(straight[base]) * inv).rounded())))
                        straight[base + 1] = UInt8(min(255, Int((Float(straight[base + 1]) * inv).rounded())))
                        straight[base + 2] = UInt8(min(255, Int((Float(straight[base + 2]) * inv).rounded())))
                    }
                }
                decoded = (UInt32(img.width), UInt32(img.height), Data(straight))
            } else {
                decoded = nil
            }
        } else if width > 0, height > 0, rgba.count >= Int(width) * Int(height) * 4 {
            decoded = (width, height, rgba)
        } else {
            decoded = nil
        }
        guard let img = decoded else { return nil }

        var pixels = [UInt8](img.rgba)
        let pxCount = Int(img.width) * Int(img.height)
        guard pixels.count >= pxCount * 4 else { return nil }
        let bg = (backing.r, backing.g, backing.b)
        for i in 0..<pxCount {
            let base = i * 4
            let a = Float(pixels[base + 3]) / 255.0
            let inv = 1.0 - a
            let lr = Self.srgbDecode(Float(pixels[base]) / 255.0) * a + bg.0 * inv
            let lg = Self.srgbDecode(Float(pixels[base + 1]) / 255.0) * a + bg.1 * inv
            let lb = Self.srgbDecode(Float(pixels[base + 2]) / 255.0) * a + bg.2 * inv
            pixels[base] = UInt8(max(0, min(255, (Self.srgbEncode(lr) * 255.0).rounded())))
            pixels[base + 1] = UInt8(max(0, min(255, (Self.srgbEncode(lg) * 255.0).rounded())))
            pixels[base + 2] = UInt8(max(0, min(255, (Self.srgbEncode(lb) * 255.0).rounded())))
            pixels[base + 3] = 255
        }
        let outData = Data(pixels)
        guard let encoded = ClipboardImage.encodeRGBAAsPNG(width: Int(img.width), height: Int(img.height), rgba: outData) else {
            return nil
        }
        var copy = self
        copy.width = img.width
        copy.height = img.height
        copy.rgba = outData
        copy.pngData = encoded
        return copy
    }
}

// MARK: - Popup Menu Types (popup_menu/mod.rs & runtime/input/popup.rs)

/// Where a native popup menu opens (`rune::popup_menu::PopupAnchor`).
public enum PopupAnchor: Sendable, Equatable {
    case key(String)
    case point(Float, Float)

    public init(_ key: String) {
        self = .key(key)
    }

    public init(_ press: PointerPress) {
        self = .point(press.window.x, press.window.y)
    }

    public init(_ pt: Vec2) {
        self = .point(pt.x, pt.y)
    }
}

/// Errors reported by `PopupMenu.validate()` or `Runtime.resolvePopup(_:)`.
public enum PopupMenuError: Error, Sendable, Equatable, CustomStringConvertible {
    case notOpen
    case unknownItem(String)
    case disabled(String)
    case emptyId
    case duplicateId(String)
    case unsupported

    public var description: String {
        switch self {
        case .notOpen: return "no pop-up menu is open"
        case .unknownItem(let id): return "the pop-up menu has no item \(id)"
        case .disabled(let id): return "pop-up menu item \(id) is disabled"
        case .emptyId: return "an item has an empty id"
        case .duplicateId(let id): return "duplicate item id \(id)"
        case .unsupported: return "popup menus are unsupported on this platform"
        }
    }
}

/// Resolved placement passed to the native macOS menu host.
public enum PopupShowAnchor: Sendable, Equatable {
    case rect(MotionRect)
    case point(Float, Float)
}

/// Native host payload taken once from `Runtime.takePopup()`.
public struct PopupShow: Sendable, Equatable {
    public var menu: PopupMenu
    public var anchor: PopupShowAnchor

    public init(menu: PopupMenu, anchor: PopupShowAnchor) {
        self.menu = menu
        self.anchor = anchor
    }
}

/// Single-resolution guard shared with a native menu presenter so cancellation and item selection
/// never invoke the runtime callback more than once.
public final class PopupSession: @unchecked Sendable {
    private let lock = NSLock()
    private var resolveFn: ((String?) -> Void)?

    public init(_ resolveFn: @escaping (String?) -> Void) {
        self.resolveFn = resolveFn
    }

    @discardableResult
    public func resolve(_ pickedId: String?) -> Bool {
        lock.lock()
        let fn = resolveFn
        resolveFn = nil
        lock.unlock()
        guard let fn else { return false }
        fn(pickedId)
        return true
    }

    public func cancel() {
        resolve(nil)
    }

    public var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolveFn == nil
    }
}

/// Type-erased popup menu request captured from `Tx.popupMenu(...)`.
internal struct ErasedPopupRequest {
    var menu: PopupMenu
    var anchor: PopupAnchor
    var onPick: (inout Any, String?, inout Tx) -> Void
    var isFieldMenu: Bool = false
}

/// Runtime queue state for popup menus (`Closed`, `Queued`, `Showing`).
internal enum PopupQueueState {
    case closed
    case queued([ErasedPopupRequest])
    case showing(head: ErasedPopupRequest, rest: [ErasedPopupRequest])

    var isShowing: Bool {
        if case .showing = self { return true }
        return false
    }

    var isEmpty: Bool {
        if case .closed = self { return true }
        return false
    }

    var count: Int {
        switch self {
        case .closed: return 0
        case .queued(let items): return items.count
        case .showing(_, let rest): return 1 + rest.count
        }
    }

    var front: ErasedPopupRequest? {
        switch self {
        case .closed: return nil
        case .queued(let items): return items.first
        case .showing(let head, _): return head
        }
    }
}

// MARK: - File Dialog State Machine (file_dialog.rs & runtime/input/file_dialog.rs)

public typealias FileDialogResult = Result<URL?, FileDialogError>

public struct FileDialogPending: Sendable, Equatable {
    public var id: UInt64
    public var kind: FileDialogKind
    public var options: FileDialogOptions

    public init(id: UInt64, kind: FileDialogKind, options: FileDialogOptions) {
        self.id = id
        self.kind = kind
        self.options = options
    }

    public func toJSONObject() -> [String: Any] {
        var json: [String: Any] = [
            "kind": kind.rawValue,
            "title": options.title,
            "filters": options.filters.map { ["name": $0.name, "extensions": $0.extensions] },
        ]
        if let dir = options.directory {
            json["directory"] = dir.path
        }
        if let name = options.fileName {
            json["fileName"] = name
        }
        return json
    }
}

internal struct ErasedFileDialogRequest {
    var kind: FileDialogKind
    var options: FileDialogOptions
    var onAnswer: (inout Any, FileDialogResult, inout Tx) -> Void
}

internal struct ErasedFileDialogPendingEntry {
    var pending: FileDialogPending
    var onAnswer: (inout Any, FileDialogResult, inout Tx) -> Void
}

internal enum RuntimeFileDialogState {
    case closed
    case requested(ErasedFileDialogPendingEntry)
    case showing(ErasedFileDialogPendingEntry)

    var entry: ErasedFileDialogPendingEntry? {
        switch self {
        case .closed: return nil
        case .requested(let e), .showing(let e): return e
        }
    }

    var isOpen: Bool {
        if case .closed = self { return false }
        return true
    }

    var isShowing: Bool {
        if case .showing = self { return true }
        return false
    }
}

internal enum ErasedRuntimeAction {
    case popup(ErasedPopupRequest)
    case fileDialog(ErasedFileDialogRequest)
}
