import Foundation
#if os(Android)
import Android
#endif
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

    public var claimsRejects: Bool {
        onDropRejected != nil || onDropRejectedHover != nil
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
///
/// `takeDragOutStart()` hands it over in window points (the view's times its zoom); the
/// runtime keeps it in view points until then (`drag_out::DragOutStart`).
public struct DragOutStart: Sendable, Equatable {
    public var item: DragItem
    /// The element's visible drawn rect, cut to its scroll clip.
    public var rect: MotionRect
    /// The element's whole drawn rect, before scroll clipping.
    public var bounds: MotionRect
    /// Where the pointer went down.
    public var press: Vec2
    public var key: String?

    /// `rect` defaults to `bounds` (an element no scroll clips).
    public init(item: DragItem, rect: MotionRect? = nil, bounds: MotionRect, press: Vec2, key: String? = nil) {
        self.item = item
        self.rect = rect ?? bounds
        self.bounds = bounds
        self.press = press
        self.key = key
    }
}

// MARK: - DragImage Helpers

extension DragImage {
    static func containsRGBA(width: UInt32, height: UInt32, bytes: Int) -> Bool {
        width > 0 && height > 0 && UInt64(width) * UInt64(height) <= UInt64(bytes / 4)
    }

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
        guard Self.containsRGBA(width: width, height: height, bytes: rgba.count) else {
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
        } else if Self.containsRGBA(width: width, height: height, bytes: rgba.count) {
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

    /// Clamps `rect` (points) in device pixels `[x, y, w, h]` to `size` (`drag_out/mod.rs::crop`).
    public static func snapshotCrop(rect: MotionRect, scale: Float, size: (UInt32, UInt32)) -> [UInt32]? {
        guard scale.isFinite, scale > 0, rect.x.isFinite, rect.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        let factor = Double(scale)
        let x = Double(rect.x), y = Double(rect.y)
        let x0 = UInt32(max(0, min(Double(size.0), floor(x * factor))))
        let y0 = UInt32(max(0, min(Double(size.1), floor(y * factor))))
        let x1 = UInt32(max(0, min(Double(size.0), ceil((x + Double(rect.width)) * factor))))
        let y1 = UInt32(max(0, min(Double(size.1), ceil((y + Double(rect.height)) * factor))))
        guard x1 > x0, y1 > y0 else { return nil }
        return [x0, y0, x1 - x0, y1 - y0]
    }

    /// Converts premultiplied RGBA/BGRA readback pixels to straight RGBA (`drag_out/mod.rs::to_straight_rgba`, `#1212`).
    ///
    /// On `*Srgb` targets (`srgbTarget == true`) the bytes hold `srgbEncode(linearRGB * a)` and are
    /// un-premultiplied in linear light; on non-sRGB targets (`srgb_blend`) they divide directly.
    /// Fully transparent pixels always zero their RGB channels.
    public static func toStraightRGBA(_ pixels: inout [UInt8], bgra: Bool, srgbTarget: Bool = false) {
        let count = pixels.count - (pixels.count % 4)
        if bgra {
            for i in stride(from: 0, to: count, by: 4) {
                pixels.swapAt(i, i + 2)
            }
        }
        if srgbTarget {
            for i in stride(from: 0, to: count, by: 4) {
                let aByte = pixels[i + 3]
                if aByte == 0 {
                    pixels[i] = 0
                    pixels[i + 1] = 0
                    pixels[i + 2] = 0
                } else if aByte < 255 {
                    let a = Float(aByte) / 255.0
                    for c in 0..<3 {
                        let lin = srgbDecode(Float(pixels[i + c]) / 255.0) / a
                        let clamped = min(1.0, max(0.0, lin))
                        pixels[i + c] = UInt8(min(255, max(0, Int((srgbEncode(clamped) * 255.0).rounded()))))
                    }
                }
            }
        } else {
            for i in stride(from: 0, to: count, by: 4) {
                let a = pixels[i + 3]
                if a == 0 {
                    pixels[i] = 0
                    pixels[i + 1] = 0
                    pixels[i + 2] = 0
                } else if a != 255 {
                    let alpha = UInt32(a)
                    for c in 0..<3 {
                        let v = (UInt32(pixels[i + c]) * 255 + alpha / 2) / alpha
                        pixels[i + c] = UInt8(min(255, v))
                    }
                }
            }
        }
    }

    /// Resolves the drag image: item's custom image else `snapshot` composited over `item.backing` (`drag_out/mod.rs::picture`).
    public static func picture(for item: DragItem, snapshot: DragImage?) -> DragImage? {
        if let own = item.image {
            return own
        }
        guard let snap = snapshot else { return nil }
        if let backing = item.backing {
            return snap.over(backing) ?? snap
        }
        return snap
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

    func scaled(by factor: Float) -> Self {
        switch self {
        case .rect(let rect): .rect(rect.scaled(by: factor))
        case .point(let x, let y): .point(x * factor, y * factor)
        }
    }
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
/// One-shot native popup menu presentation session (`popup_menu/macos.rs::Session`).
public final class PopupSession: @unchecked Sendable {
    private enum Phase {
        case pending
        case open
        case answered(pickedId: String?, pointer: Vec2?)
        case closed
    }

    private let lock = NSLock()
    private var phase: Phase
    private var resolveFn: ((String?) -> Void)?
    private var trackingObject: AnyObject?

    public init() {
        self.phase = .pending
        self.resolveFn = nil
    }

    public init(_ resolveFn: @escaping (String?) -> Void) {
        self.phase = .open
        self.resolveFn = resolveFn
    }

    /// Transitions a newly-created session from pending to open; returns `true` at most once.
    @discardableResult
    public func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = phase else { return false }
        phase = .open
        return true
    }

    /// Associates a native tracking menu/runloop token while the session is open.
    public func tracking(_ object: AnyObject?) {
        lock.lock()
        defer { lock.unlock() }
        guard case .open = phase else { return }
        trackingObject = object
    }

    @discardableResult
    public func resolve(_ pickedId: String?, at pointer: Vec2? = nil) -> Bool {
        lock.lock()
        guard case .open = phase else {
            lock.unlock()
            return false
        }
        let fn = resolveFn
        resolveFn = nil
        if fn != nil {
            phase = .closed
            trackingObject = nil
        } else {
            phase = .answered(pickedId: pickedId, pointer: pointer)
        }
        lock.unlock()
        fn?(pickedId)
        return true
    }

    /// Takes the resolved selection and pointer position once, then closes the session.
    public func takeAnswer() -> (pickedId: String?, pointer: Vec2?)? {
        lock.lock()
        defer { lock.unlock() }
        guard case .answered(let pickedId, let pointer) = phase else {
            return nil
        }
        phase = .closed
        trackingObject = nil
        return (pickedId, pointer)
    }

    /// Cancels a pending or open session and returns any active tracking token.
    @discardableResult
    public func cancelTracking() -> AnyObject? {
        lock.lock()
        switch phase {
        case .pending, .open:
            phase = .closed
            let fn = resolveFn
            resolveFn = nil
            let tracked = trackingObject
            trackingObject = nil
            lock.unlock()
            fn?(nil)
            return tracked
        case .answered, .closed:
            lock.unlock()
            return nil
        }
    }

    public func cancel() {
        _ = cancelTracking()
    }

    public var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .answered, .closed:
            return true
        case .pending, .open:
            return false
        }
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .closed = phase { return true }
        return false
    }
}

/// Type-erased popup menu request captured from `Tx.popupMenu(...)`.
internal final class ErasedPopupRequest: @unchecked Sendable {
    let menu: PopupMenu
    let anchor: PopupAnchor
    let onPick: (inout Any, String?, inout Tx) -> Void
    let isFieldMenu: Bool
    var fieldMenuId: UInt64?
    private let lock = NSLock()
    private var taken = false

    init(
        menu: PopupMenu,
        anchor: PopupAnchor,
        onPick: @escaping (inout Any, String?, inout Tx) -> Void,
        isFieldMenu: Bool = false,
        fieldMenuId: UInt64? = nil
    ) {
        self.menu = menu
        self.anchor = anchor
        self.onPick = onPick
        self.isFieldMenu = isFieldMenu
        self.fieldMenuId = fieldMenuId
    }

    /// Claims this request once across cloned `Tx` values (`popup_menu/tests.rs::clones_of_a_tx_share_one_request`).
    func take() -> ErasedPopupRequest? {
        lock.lock()
        defer { lock.unlock() }
        guard !taken else { return nil }
        taken = true
        return self
    }
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
