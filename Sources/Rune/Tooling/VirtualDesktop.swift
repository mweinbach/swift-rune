import Foundation
import RuneMotion
import RuneRef

#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

// MARK: - VirtualDisplay & VirtualDesktop (tooling/virtual_desktop/displays.rs)

public struct VirtualDisplay: Sendable, Equatable {
    public var id: UInt32
    /// `[x, y, width, height]` in global top-left logical points.
    public var frame: [Double]
    public var scale: Double
    public var primary: Bool

    public init(id: UInt32, frame: [Double], scale: Double, primary: Bool = false) {
        self.id = id
        self.frame = frame
        self.scale = scale
        self.primary = primary
    }
}

public enum VirtualDesktopError: Error, LocalizedError, Equatable {
    case invalidScript(String)
    case invalidBackdrop(String)

    public var errorDescription: String? {
        switch self {
        case .invalidScript(let msg), .invalidBackdrop(let msg):
            return msg
        }
    }
}

/// Scripted multi-display desktop for headless runs (`tooling::virtual_desktop::VirtualDesktop`).
public struct VirtualDesktop: Sendable, Equatable {
    public var displays: [VirtualDisplay]
    public var pointer: (Double, Double)?

    public init(displays: [VirtualDisplay], pointer: (Double, Double)? = nil) {
        self.displays = displays
        self.pointer = pointer
    }

    public static func == (lhs: VirtualDesktop, rhs: VirtualDesktop) -> Bool {
        lhs.displays == rhs.displays
            && lhs.pointer?.0 == rhs.pointer?.0
            && lhs.pointer?.1 == rhs.pointer?.1
    }

    /// Single 1920x1080-pixel display matching the headless factory default.
    public static func single(scale: Double) -> VirtualDesktop {
        let s = max(scale, 0.5)
        return VirtualDesktop(
            displays: [VirtualDisplay(id: 1, frame: [0.0, 0.0, 1920.0 / s, 1080.0 / s], scale: s, primary: true)],
            pointer: nil
        )
    }

    /// Parses `"displays"` and `"pointer"` from a `--script` JSON object or Data.
    public static func fromScript(jsonData: Data?, scale: Double, size: (Double, Double)? = nil) throws -> VirtualDesktop {
        guard let jsonData else {
            return try fromScript(object: nil, scale: scale, size: size)
        }
        let parsed = try JSONSerialization.jsonObject(with: jsonData, options: [])
        return try fromScript(object: parsed, scale: scale, size: size)
    }

    public static func fromScript(object: Any?, scale: Double, size: (Double, Double)? = nil) throws -> VirtualDesktop {
        var desktop = single(scale: scale)
        if let (w, h) = size {
            desktop.displays[0].frame = [0.0, 0.0, w, h]
        }
        guard let dict = object as? [String: Any] else {
            return desktop
        }

        if let rawDisplays = dict["displays"] {
            guard let list = rawDisplays as? [[String: Any]] else {
                throw VirtualDesktopError.invalidScript("script: \"displays\" must be an array")
            }
            if list.isEmpty {
                throw VirtualDesktopError.invalidScript("script: \"displays\" is empty")
            }
            var parsedDisplays: [VirtualDisplay] = []
            parsedDisplays.reserveCapacity(list.count)
            for (i, d) in list.enumerated() {
                guard let rawFrame = d["frame"] as? [Any], rawFrame.count == 4,
                      let x = (rawFrame[0] as? NSNumber)?.doubleValue,
                      let y = (rawFrame[1] as? NSNumber)?.doubleValue,
                      let w = (rawFrame[2] as? NSNumber)?.doubleValue,
                      let h = (rawFrame[3] as? NSNumber)?.doubleValue,
                      w > 0, h > 0 else {
                    throw VirtualDesktopError.invalidScript("script: display \(i) needs \"frame\": [x, y, width, height]")
                }
                let dScale: Double
                if let rawScale = d["scale"] {
                    if rawScale is NSNull {
                        dScale = scale
                    } else if let n = rawScale as? NSNumber, n.doubleValue.isFinite, n.doubleValue > 0 {
                        dScale = n.doubleValue
                    } else {
                        throw VirtualDesktopError.invalidScript("script: display \(i) \"scale\" must be a number above 0")
                    }
                } else {
                    dScale = scale
                }
                let id = (d["id"] as? NSNumber)?.uint32Value ?? UInt32(i + 1)
                let primary = (d["primary"] as? Bool) ?? false
                parsedDisplays.append(VirtualDisplay(id: id, frame: [x, y, w, h], scale: dScale, primary: primary))
            }
            desktop.displays = parsedDisplays
        }

        if let rawPointer = dict["pointer"] {
            guard let arr = rawPointer as? [Any], arr.count == 2,
                  let px = (arr[0] as? NSNumber)?.doubleValue,
                  let py = (arr[1] as? NSNumber)?.doubleValue else {
                throw VirtualDesktopError.invalidScript("script: \"pointer\" must be [x, y]")
            }
            desktop.pointer = (px, py)
        }
        return desktop
    }

    /// Primary display (or the first display if none is marked `primary`).
    public var primaryDisplay: VirtualDisplay {
        displays.first(where: \.primary) ?? displays[0]
    }

    /// Converts desktop pixel coordinates (`WindowOptions.position`) into global logical points.
    public func toPoints(_ pixelPoint: (Int32, Int32)) -> (Float, Float) {
        let d = displayAt(pixelPoint)
        let x = Double(pixelPoint.0)
        let y = Double(pixelPoint.1)
        let px = d.frame[0] + (x - d.frame[0] * d.scale) / d.scale
        let py = d.frame[1] + (y - d.frame[1] * d.scale) / d.scale
        return (Float(px), Float(py))
    }

    /// Display containing desktop pixel point `at`, or the primary display when omitted/outside.
    public func displayAt(_ at: (Int32, Int32)?) -> VirtualDisplay {
        guard let at else { return primaryDisplay }
        let x = Double(at.0)
        let y = Double(at.1)
        func inside(_ rect: [Double]) -> Bool {
            x >= rect[0] && y >= rect[1] && x < rect[0] + rect[2] && y < rect[1] + rect[3]
        }
        let owners = displays.filter { d in
            inside(d.frame.map { $0 * d.scale })
        }
        if let pointMatch = owners.first(where: { inside($0.frame) }) {
            return pointMatch
        }
        return owners.first ?? primaryDisplay
    }

    /// Global `[x, y, w, h]` frame where a window opens (`position` in desktop pixels, or centered on primary).
    public func openAt(position: (Int32, Int32)?, size: (Float, Float)) -> [Float] {
        if let p = position {
            let (x, y) = toPoints(p)
            return [x, y, size.0, size.1]
        }
        let d = displayAt(nil).frame.map(Float.init)
        return [
            d[0] + ((d[2] - size.0) / 2.0).rounded(),
            d[1] + ((d[3] - size.1) / 2.0).rounded(),
            size.0,
            size.1,
        ]
    }

    /// Snapshot as `DisplayInfo` matching native display descriptors.
    public func displayInfos() -> [DisplayInfo] {
        displays.map { d in
            DisplayInfo(
                id: nil,
                name: "headless",
                position: (Int32((d.frame[0] * d.scale).rounded()), Int32((d.frame[1] * d.scale).rounded())),
                size: (UInt32(max(0, (d.frame[2] * d.scale).rounded())), UInt32(max(0, (d.frame[3] * d.scale).rounded()))),
                scale: d.scale,
                primary: d.primary
            )
        }
    }

    /// Resolves `PlaceRequest` onto a virtual display and returns `(displayId, [x, y, width, height])`.
    public func place(request: PlaceRequest, size: (Float, Float)) -> (displayId: UInt32, frame: [Float]) {
        let targetIndex = resolveDisplayIndex(target: request.display ?? .primary)
        let d = displays[targetIndex]
        let w = request.size?.x ?? size.0
        let h = request.size?.y ?? size.1
        let lx = request.position?.x ?? ((Float(d.frame[2]) - w) / 2.0).rounded()
        let ly = request.position?.y ?? ((Float(d.frame[3]) - h) / 2.0).rounded()
        return (d.id, [Float(d.frame[0]) + lx, Float(d.frame[1]) + ly, w, h])
    }

    /// Resolves overlay placement onto a virtual display and returns `(displayId, [x, y, width, height])`.
    public func placeOverlay(
        requested: DisplayTarget,
        placement: OverlayPlacement?,
        size: (Float, Float)
    ) -> (displayId: UInt32, frame: [Float]) {
        let targetIndex = resolveDisplayIndex(target: requested)
        let d = displays[targetIndex]
        let local = OverlayGeometry.localRect(
            at: OverlayGeometry.Placement(size: Vec2(size.0, size.1)),
            placement: placement,
            area: Vec2(Float(d.frame[2]), Float(d.frame[3]))
        )
        return (d.id, [Float(d.frame[0]) + local[0], Float(d.frame[1]) + local[1], local[2], local[3]])
    }

    private func resolveDisplayIndex(target: DisplayTarget) -> Int {
        let requestedID: Int64?
        switch target {
        case .id(let rid):
            switch rid.native {
            case .macOS(let n): requestedID = Int64(n)
            case .other(let n): requestedID = Int64(n)
            case .wayland, nil: requestedID = nil
            }
        case .native(let nid):
            switch nid {
            case .macOS(let n): requestedID = Int64(n)
            case .other(let n): requestedID = Int64(n)
            case .wayland: requestedID = nil
            }
        case .index(let idx):
            return displays.indices.contains(idx) ? idx : 0
        case .primary, .underPointer, .named:
            requestedID = nil
        }

        let bounds = displays.map { [$0.frame[0], $0.frame[1], $0.frame[0] + $0.frame[2], $0.frame[1] + $0.frame[3]] }
        let primaryIdx = displays.firstIndex(where: \.primary)
        let requestedIdx = requestedID.flatMap { rid in displays.firstIndex(where: { Int64($0.id) == rid }) }
        let pointerPt: (Double, Double)? = (target == .underPointer) ? pointer : nil
        return OverlayGeometry.chooseDisplay(
            bounds: bounds,
            primary: primaryIdx,
            requested: requestedIdx,
            pointer: pointerPt
        ) ?? 0
    }
}

// MARK: - Backdrop & Rounded-Window Compositor (tooling/virtual_desktop/composite.rs)

public enum DesktopComposite {
    public static let keyShadow = (sigma: Float(14.0), offset: Float(14.0), opacity: Float(0.5))
    public static let normalShadow = (sigma: Float(6.0), offset: Float(5.0), opacity: Float(0.32))
    public static let maxBackdropSide: Int = 16384

    /// Validates that `size * scale` fits in `[1, maxSide]` whole pixels per side.
    public static func pixels(size: (Float, Float), scale: Float, maxSide: Int) -> (Int, Int)? {
        guard size.0.isFinite, size.1.isFinite, scale.isFinite, scale > 0 else { return nil }
        func side(_ v: Float) -> Int? {
            let px = (v * scale).rounded()
            guard px.isFinite, px >= 1.0, px <= Float(maxSide) else { return nil }
            return Int(px)
        }
        guard let w = side(size.0), let h = side(size.1) else { return nil }
        return (w, h)
    }

    /// Reads, aspect-crops, scales, and premultiplies a backdrop image file over opaque black.
    public static func fitBackdrop(imagePath: String, targetSize: (Int, Int)) throws -> [UInt8] {
        let url = URL(fileURLWithPath: imagePath)
        let (w, h) = targetSize
        guard w > 0, h > 0 else {
            throw VirtualDesktopError.invalidBackdrop("\(imagePath): invalid target size \(w)x\(h)")
        }

        #if canImport(ImageIO) && canImport(CoreGraphics)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw VirtualDesktopError.invalidBackdrop("\(imagePath): cannot open image")
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let iw = props[kCGImagePropertyPixelWidth] as? Int,
           let ih = props[kCGImagePropertyPixelHeight] as? Int {
            if max(iw, ih) > maxBackdropSide {
                throw VirtualDesktopError.invalidBackdrop(
                    "\(imagePath): \(iw)x\(ih) pixels; a backdrop is at most \(maxBackdropSide) pixels a side"
                )
            }
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VirtualDesktopError.invalidBackdrop("\(imagePath): failed to decode image")
        }
        let iw = cgImage.width
        let ih = cgImage.height
        if max(iw, ih) > maxBackdropSide {
            throw VirtualDesktopError.invalidBackdrop(
                "\(imagePath): \(iw)x\(ih) pixels; a backdrop is at most \(maxBackdropSide) pixels a side"
            )
        }

        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var srcRGBA = [UInt8](repeating: 0, count: iw * ih * 4)
        let srcCtx = srcRGBA.withUnsafeMutableBytes { raw -> CGContext? in
            CGContext(
                data: raw.baseAddress,
                width: iw,
                height: ih,
                bitsPerComponent: 8,
                bytesPerRow: iw * 4,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
        guard let srcCtx else {
            throw VirtualDesktopError.invalidBackdrop("\(imagePath): failed to allocate image buffer")
        }
        srcCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: iw, height: ih))
        return fitBackdrop(rgba: srcRGBA, width: iw, height: ih, targetSize: targetSize, alreadyPremultiplied: true)
        #else
        throw VirtualDesktopError.invalidBackdrop("\(imagePath): image decoding unavailable on this platform")
        #endif
    }

    /// Crops `rgba` (`width x height`) to `targetSize`'s aspect ratio, scales, and returns opaque RGBA8.
    public static func fitBackdrop(
        rgba: [UInt8],
        width iw: Int,
        height ih: Int,
        targetSize: (Int, Int),
        alreadyPremultiplied: Bool = false
    ) -> [UInt8] {
        let (tw, th) = targetSize
        guard iw > 0, ih > 0, tw > 0, th > 0, rgba.count >= iw * ih * 4 else { return [] }

        let cw: Int
        let ch: Int
        if Int64(iw) * Int64(th) > Int64(ih) * Int64(tw) {
            cw = max(1, min(iw, Int((Double(ih) * Double(tw) / Double(th)).rounded())))
            ch = ih
        } else {
            cw = iw
            ch = max(1, min(ih, Int((Double(iw) * Double(th) / Double(tw)).rounded())))
        }
        let cropX = (iw - cw) / 2
        let cropY = (ih - ch) / 2

        var out = [UInt8](repeating: 255, count: tw * th * 4)
        for dy in 0..<th {
            let syFloat = (cw == tw && ch == th) ? Double(cropY + dy) : (Double(cropY) + (Double(dy) + 0.5) * Double(ch) / Double(th) - 0.5)
            let sy0 = max(0, min(ih - 1, Int(floor(syFloat))))
            let sy1 = max(0, min(ih - 1, sy0 + 1))
            let fy = max(0.0, min(1.0, syFloat - Double(sy0)))

            for dx in 0..<tw {
                let sxFloat = (cw == tw && ch == th) ? Double(cropX + dx) : (Double(cropX) + (Double(dx) + 0.5) * Double(cw) / Double(tw) - 0.5)
                let sx0 = max(0, min(iw - 1, Int(floor(sxFloat))))
                let sx1 = max(0, min(iw - 1, sx0 + 1))
                let fx = max(0.0, min(1.0, sxFloat - Double(sx0)))

                func sample(_ x: Int, _ y: Int, _ chIdx: Int) -> Double {
                    let base = (y * iw + x) * 4
                    let c = Double(rgba[base + chIdx])
                    if alreadyPremultiplied { return c }
                    let a = Double(rgba[base + 3]) / 255.0
                    return c * a
                }

                let dst = (dy * tw + dx) * 4
                for cIdx in 0..<3 {
                    let c00 = sample(sx0, sy0, cIdx)
                    let c10 = sample(sx1, sy0, cIdx)
                    let c01 = sample(sx0, sy1, cIdx)
                    let c11 = sample(sx1, sy1, cIdx)
                    let top = c00 + (c10 - c00) * fx
                    let bot = c01 + (c11 - c01) * fx
                    let val = top + (bot - top) * fy
                    out[dst + cIdx] = UInt8(max(0, min(255, Int(val.rounded()))))
                }
                out[dst + 3] = 255
            }
        }
        return out
    }

    /// Software-composites visible rounded windows (and soft drop shadows) over `backdropRGBA`.
    public static func compositeFrame(
        backdropRGBA: [UInt8],
        width: Int,
        height: Int,
        scale: Float,
        windows: [(rgba: [UInt8], width: Int, height: Int, originPx: (Float, Float), cornerRadiusPx: Float, hasShadow: Bool, isKey: Bool)]
    ) -> Frame {
        var out = backdropRGBA.count >= width * height * 4
            ? Array(backdropRGBA.prefix(width * height * 4))
            : [UInt8](repeating: 0, count: width * height * 4)

        func roundedSDF(_ px: Float, _ py: Float, _ w: Float, _ h: Float, _ radius: Float) -> Float {
            let hx = w * 0.5
            let hy = h * 0.5
            let r = min(radius, min(hx, hy))
            let qx = abs(px - hx) - hx + r
            let qy = abs(py - hy) - hy + r
            let outside = hypot(max(qx, 0), max(qy, 0))
            let inside = min(max(qx, qy), 0)
            return outside + inside - r
        }

        for win in windows {
            let ww = Float(win.width)
            let wh = Float(win.height)
            let ox = win.originPx.0
            let oy = win.originPx.1

            if win.hasShadow {
                let (sigmaPt, offsetPt, opacity) = win.isKey ? keyShadow : normalShadow
                let sigmaPx = max(1.0, sigmaPt * scale)
                let padPx = Int(ceil(sigmaPx * 2.5))
                let offY = offsetPt * scale
                let minX = max(0, Int(floor(ox)) - padPx)
                let minY = max(0, Int(floor(oy + offY)) - padPx)
                let maxX = min(width - 1, Int(ceil(ox + ww)) + padPx)
                let maxY = min(height - 1, Int(ceil(oy + offY + wh)) + padPx)
                if minX <= maxX && minY <= maxY {
                    for y in minY...maxY {
                        let ly = Float(y) + 0.5 - (oy + offY)
                        for x in minX...maxX {
                            let lx = Float(x) + 0.5 - ox
                            let d = roundedSDF(lx, ly, ww, wh, win.cornerRadiusPx)
                            let falloff = d <= 0 ? 1.0 : expf(-(d * d) / (2.0 * sigmaPx * sigmaPx))
                            let sa = max(0, min(1, falloff * opacity))
                            if sa > 0.002 {
                                let dst = (y * width + x) * 4
                                let inv = 1.0 - sa
                                out[dst + 0] = UInt8(max(0, min(255, Int((Float(out[dst + 0]) * inv).rounded()))))
                                out[dst + 1] = UInt8(max(0, min(255, Int((Float(out[dst + 1]) * inv).rounded()))))
                                out[dst + 2] = UInt8(max(0, min(255, Int((Float(out[dst + 2]) * inv).rounded()))))
                            }
                        }
                    }
                }
            }

            let minX = max(0, Int(floor(ox)))
            let minY = max(0, Int(floor(oy)))
            let maxX = min(width - 1, Int(ceil(ox + ww)) - 1)
            let maxY = min(height - 1, Int(ceil(oy + wh)) - 1)
            guard minX <= maxX && minY <= maxY else { continue }

            for y in minY...maxY {
                let wy = Int((Float(y) - oy).rounded(.towardZero))
                guard wy >= 0 && wy < win.height else { continue }
                let ly = Float(y) + 0.5 - oy
                for x in minX...maxX {
                    let wx = Int((Float(x) - ox).rounded(.towardZero))
                    guard wx >= 0 && wx < win.width else { continue }
                    let lx = Float(x) + 0.5 - ox
                    let cov = max(0, min(1, 0.5 - roundedSDF(lx, ly, ww, wh, win.cornerRadiusPx)))
                    if cov <= 0.001 { continue }

                    let srcIdx = (wy * win.width + wx) * 4
                    let sr = Float(win.rgba[srcIdx + 0]) * cov
                    let sg = Float(win.rgba[srcIdx + 1]) * cov
                    let sb = Float(win.rgba[srcIdx + 2]) * cov
                    let sa = (Float(win.rgba[srcIdx + 3]) / 255.0) * cov
                    let dstIdx = (y * width + x) * 4
                    let inv = 1.0 - sa
                    out[dstIdx + 0] = UInt8(max(0, min(255, Int((sr + Float(out[dstIdx + 0]) * inv).rounded()))))
                    out[dstIdx + 1] = UInt8(max(0, min(255, Int((sg + Float(out[dstIdx + 1]) * inv).rounded()))))
                    out[dstIdx + 2] = UInt8(max(0, min(255, Int((sb + Float(out[dstIdx + 2]) * inv).rounded()))))
                    out[dstIdx + 3] = 255
                }
            }
        }

        return Frame(width: width, height: height, rgba: out)
    }
}

// MARK: - Window Life & Reopen (window/life.rs, platform/reopen.rs)

public struct DesktopReopenCandidate: Sendable, Equatable {
    public var reopenable: Bool
    public var visible: Bool
    public var minimized: Bool
    public var hiddenAt: UInt64?
    public var main: Bool

    public init(
        reopenable: Bool = true,
        visible: Bool,
        minimized: Bool = false,
        hiddenAt: UInt64? = nil,
        main: Bool = false
    ) {
        self.reopenable = reopenable
        self.visible = visible
        self.minimized = minimized
        self.hiddenAt = hiddenAt
        self.main = main
    }
}

public enum DesktopReopen {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counter: UInt64 = 0

    /// Monotonically increasing hide timestamp (`platform::reopen::stamp`).
    public static func stamp() -> UInt64 {
        lock.lock()
        counter += 1
        let value = counter
        lock.unlock()
        return value
    }

    public static func hasVisible(_ windows: [DesktopReopenCandidate]) -> Bool {
        windows.contains { $0.reopenable && $0.visible }
    }

    public static func target(_ windows: [DesktopReopenCandidate]) -> Int? {
        if hasVisible(windows) { return nil }
        let ok = windows.enumerated().filter { $0.element.reopenable }
        if let minIdx = ok.first(where: { $0.element.minimized })?.offset {
            return minIdx
        }
        if let lastHidden = ok.compactMap({ item -> (stamp: UInt64, index: Int)? in
            guard let h = item.element.hiddenAt else { return nil }
            return (h, item.offset)
        }).max(by: { $0.stamp < $1.stamp }) {
            return lastHidden.index
        }
        return ok.first(where: { $0.element.main })?.offset
    }

    public static func appKitHandles(sent: Bool, appKitSeesVisible: Bool) -> Bool {
        !sent || appKitSeesVisible
    }
}

public enum DesktopWindowLife: Equatable, Sendable {
    case unopened
    case shown
    case hidden(at: UInt64)
    case finished

    public var isShown: Bool {
        if case .shown = self { return true }
        return false
    }

    public var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }

    public var hiddenAt: UInt64? {
        if case .hidden(let at) = self { return at }
        return nil
    }

    @discardableResult
    public mutating func show() -> Bool {
        guard !isFinished, !isShown else { return false }
        self = .shown
        return true
    }

    public mutating func hide(_ stampFn: () -> UInt64 = DesktopReopen.stamp) {
        guard isShown else { return }
        self = .hidden(at: stampFn())
    }

    @discardableResult
    public mutating func closes(keepRunning: Bool, headless: Bool = true) -> Bool {
        _ = (keepRunning, headless)
        guard !isFinished else { return false }
        return true
    }

    public mutating func finish() {
        self = .finished
    }
}

// MARK: - Desk State Machine & Members (tooling/virtual_desktop.rs, window.rs)

public struct DesktopFocus: Equatable, Sendable {
    public var keyIndex: Int?
    public var active: Bool

    public init(keyIndex: Int? = nil, active: Bool = true) {
        self.keyIndex = keyIndex
        self.active = active
    }

    public var focusedIndex: Int? {
        active ? keyIndex : nil
    }
}

public enum DesktopPointerState: Equatable, Sendable {
    case out
    case over(Int)
    case pressed(Int)

    public var windowIndex: Int? {
        switch self {
        case .out: return nil
        case .over(let i), .pressed(let i): return i
        }
    }
}

public enum DesktopFilesState: Equatable, Sendable {
    case none
    case over(Int)

    public var windowIndex: Int? {
        switch self {
        case .none: return nil
        case .over(let i): return i
        }
    }
}

public struct DesktopChanges: Equatable, Sendable {
    public var front: Bool
    public var keys: Bool

    public init(front: Bool = false, keys: Bool = false) {
        self.front = front
        self.keys = keys
    }
}

public enum DesktopInputKind: Equatable, Sendable {
    case move
    case down(PointerButton = .primary, Mods = .none)
    case up(PointerButton = .primary, Mods = .none)
    case leave
    case wheel(dx: Float, dy: Float, mods: Mods = .none)
    case keyDown(KeyEvent)
    case fileDrop(FileDropPhase)

    public var isDown: Bool {
        if case .down = self { return true }
        return false
    }

    public var isUp: Bool {
        if case .up = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .move: return "Move"
        case .down: return "Down"
        case .up: return "Up"
        case .leave: return "Leave"
        case .wheel: return "Wheel"
        case .keyDown: return "Key"
        case .fileDrop: return "Files"
        }
    }
}

public protocol DesktopMember: AnyObject {
    var key: String { get }
    var frame: [Float] { get }
    var visible: Bool { get }
    var clickThrough: Bool { get }
    var onTop: Bool { get }
    var cornerRadius: Float { get }
    var hasShadow: Bool { get }

    func start(desktop: VirtualDesktop)
    func drain(desktop: VirtualDesktop, t: Double) -> DesktopChanges
    var hasPending: Bool { get }
    var isStale: Bool { get }
    func advance(dt: Double)
    func setFocused(_ focused: Bool)
    func input(_ kind: DesktopInputKind, at localPt: (Float, Float))
    func leave()
    func find(key: String) -> (Float, Float)?
    func pointer() -> (Float, Float)?
    func reopenCandidate() -> DesktopReopenCandidate
    func runReopenHook(hasVisibleWindows: Bool) -> Bool
    func reopen() -> DesktopChanges
    func backdropDark() -> Bool?
    func treeJSON(at t: Double) -> [String: Any]
    func renderFrame(scale: Float) -> Frame?
}

/// Real `Runtime<State>` window member for `VirtualDesk` (`tooling::virtual_desktop::Window`).
public final class DesktopWindow<State>: DesktopMember {
    public let key: String
    public let runtime: Runtime<State>
    public private(set) var frame: [Float]
    public private(set) var life: DesktopWindowLife
    public let clickThrough: Bool
    public let onTop: Bool
    public let cornerRadius: Float
    public let hasShadow: Bool
    public let keepRunning: Bool
    public let isPanel: Bool
    public let isMain: Bool
    public let position: (Int32, Int32)?

    private var currentTime: Double = 0
    private var lastScene: RefScene?
    private var pendingClose = false
    private let onCloseHook: ((inout State, inout Tx) -> Bool)?
    private let onReopenHook: ((inout State, Bool, inout Tx) -> Bool)?
    private let waker: Waker

    public init(
        key: String = "main",
        spec: AppWindowSpec<State>,
        scale: Float = 2.0,
        dark: Bool = true,
        isMain: Bool = true,
        onClose: ((inout State, inout Tx) -> Bool)? = nil,
        onFocus: ((inout State, Bool, inout Tx) -> Void)? = nil,
        tabVisitsControls: Bool = false
    ) {
        self.key = key
        let w = Waker()
        self.waker = w
        let rt = Runtime<State>(
            state: spec.appSpec.makeState(),
            viewport: spec.appSpec.size,
            pixelScale: max(0.5, scale),
            systemDark: spec.appSpec.dark ?? dark,
            waker: w,
            onKey: spec.appSpec.onKey,
            view: spec.appSpec.view
        )
        rt.windowTitle = spec.appSpec.title
        rt.tabVisitsControls = tabVisitsControls
        let resolvedChrome = spec.titlebar?.macChrome(spec.chrome) ?? spec.chrome
        if resolvedChrome.fullSizeContent && !(spec.options.borderless || spec.chrome.borderless) {
            rt.cxSettings.titlebarInset = resolvedChrome.titlebarInset()
        } else {
            rt.cxSettings.titlebarInset = 0.0
        }
        rt.onClose = onClose
        rt.onReopen = spec.onReopen
        rt.onFocus = onFocus
        self.runtime = rt
        self.onCloseHook = onClose
        self.onReopenHook = spec.onReopen
        self.keepRunning = spec.keepRunning
        self.isPanel = spec.macosWindow.nonactivatingPanel
        self.isMain = isMain
        self.clickThrough = spec.options.clickThrough
        self.onTop = spec.options.alwaysOnTop
        self.hasShadow = spec.options.hasShadow
        let decorated = !spec.options.borderless && !spec.options.transparent
        self.cornerRadius = decorated ? 10.0 : 0.0
        self.position = spec.options.position
        self.frame = [0, 0, spec.appSpec.size.x, spec.appSpec.size.y]
        let vis = spec.options.visible
        self.life = vis ? .shown : .unopened
    }

    public convenience init(
        key: String? = nil,
        app: App<State>,
        scale: Float = 2.0,
        dark: Bool = true,
        isMain: Bool = true
    ) {
        self.init(
            key: key ?? app.title,
            spec: AppWindowSpec(app: app),
            scale: scale,
            dark: dark,
            isMain: isMain,
            onClose: app.onCloseHook,
            onFocus: app.onFocusHook,
            tabVisitsControls: app.tabVisitsControlsEnabled
        )
    }

    public var visible: Bool { life.isShown }

    public var hasPending: Bool {
        runtime.closeWindowRequested || runtime.hasPendingCommit
    }

    public var isStale: Bool {
        runtime.hasPendingCommit
    }

    public func start(desktop: VirtualDesktop) {
        let f = desktop.openAt(position: position, size: (frame[2], frame[3]))
        frame = f
        runtime.viewport = Vec2(f[2], f[3])
    }

    public func drain(desktop: VirtualDesktop, t: Double) -> DesktopChanges {
        _ = desktop
        currentTime = t
        let changes = DesktopChanges()
        if runtime.closeWindowRequested && !pendingClose {
            pendingClose = true
            close()
            pendingClose = false
        }
        return changes
    }

    public func close() {
        guard life.closes(keepRunning: keepRunning, headless: true) else { return }
        if let hook = onCloseHook {
            var tx = Tx()
            _ = hook(&runtime.state, &tx)
        }
        hide()
        if !keepRunning {
            life.finish()
        }
        runtime.clearShellRequests()
    }

    public func hide() {
        guard life.isShown else { return }
        life.hide()
        runtime.pointerExit(at: currentTime)
    }

    public func show() {
        guard life.show() else { return }
        runtime.markNeedsCommit(settle: true)
    }

    public func advance(dt: Double) {
        currentTime += dt
        lastScene = runtime.frame(at: currentTime)
    }

    public func setFocused(_ focused: Bool) {
        runtime.windowFocused = focused
        if let onFocus = runtime.onFocus {
            var tx = Tx()
            onFocus(&runtime.state, focused, &tx)
            runtime.markNeedsCommit()
        }
    }

    public func input(_ kind: DesktopInputKind, at localPt: (Float, Float)) {
        let p = Vec2(localPt.0, localPt.1)
        switch kind {
        case .move:
            runtime.pointerMove(to: p, mods: .none, at: currentTime)
        case .down(let btn, let mods):
            runtime.pointerDown(at: p, button: btn, mods: mods, at: currentTime)
        case .up(let btn, let mods):
            runtime.pointerUp(at: p, button: btn, mods: mods, at: currentTime)
        case .leave:
            runtime.pointerExit(at: currentTime)
        case .wheel(let dx, let dy, let mods):
            runtime.wheel(WheelEvent(dx: dx, dy: dy, mods: mods), at: p, now: currentTime)
        case .keyDown(let ev):
            _ = runtime.keyDown(ev, at: currentTime)
        case .fileDrop(let phase):
            runtime.fileDrop(phase, at: currentTime)
        }
    }

    public func leave() {
        runtime.pointerExit(at: currentTime)
    }

    public func find(key: String) -> (Float, Float)? {
        runtime.find(key).map { ($0.x, $0.y) }
    }

    public func pointer() -> (Float, Float)? {
        let pos = runtime.pointerPosition
        if pos.x < -5000 || pos.y < -5000 { return nil }
        return (pos.x, pos.y)
    }

    public func reopenCandidate() -> DesktopReopenCandidate {
        DesktopReopenCandidate(
            reopenable: !life.isFinished && !isPanel,
            visible: life.isShown,
            minimized: false,
            hiddenAt: life.hiddenAt,
            main: isMain
        )
    }

    public func runReopenHook(hasVisibleWindows: Bool) -> Bool {
        guard let hook = onReopenHook else { return false }
        var tx = Tx()
        return hook(&runtime.state, hasVisibleWindows, &tx)
    }

    public func reopen() -> DesktopChanges {
        show()
        return DesktopChanges(front: true, keys: true)
    }

    public func backdropDark() -> Bool? {
        runtime.backdropDark() ?? runtime.systemDark
    }

    public func treeJSON(at t: Double) -> [String: Any] {
        runtime.treeJSON(realTime: t)
    }

    public func renderFrame(scale: Float) -> Frame? {
        runtime.pixelScale = scale
        let scene = lastScene ?? runtime.frame(at: currentTime)
        lastScene = scene
        #if canImport(Metal) && canImport(QuartzCore)
        if let renderer = try? MetalRenderer(), let frame = try? renderer.renderOffscreen(scene) {
            return frame
        }
        #endif
        return try? RuneRef.render(scene)
    }
}

/// Multi-window z-order, focus, pointer capture, and file-drag router (`virtual_desktop::Desk`).
public final class VirtualDesk {
    public static let maxDrainPasses: Int = 8

    public var members: [any DesktopMember]
    public var zOrder: [Int]
    public var focus: DesktopFocus
    public var pointer: DesktopPointerState
    public var files: DesktopFilesState
    public var origin: (Float, Float)
    public var scale: Float

    public init(
        members: [any DesktopMember],
        origin: (Float, Float) = (0, 0),
        scale: Float = 1.0
    ) {
        self.members = members
        self.zOrder = Array(members.indices)
        self.focus = DesktopFocus(keyIndex: nil, active: true)
        self.pointer = .out
        self.files = .none
        self.origin = origin
        self.scale = max(0.5, scale)
        self.zOrder.sort { !members[$0].onTop && members[$1].onTop }
        let initial = topmostVisible()
        setFocus(initial, active: true)
    }

    public func setFocus(_ keyIndex: Int?, active: Bool) {
        let next = DesktopFocus(keyIndex: keyIndex, active: active)
        let before = focus.focusedIndex
        let after = next.focusedIndex
        if before != after {
            if let i = before { members[i].setFocused(false) }
            if let i = after { members[i].setFocused(true) }
        }
        focus = next
    }

    public func setActive(_ active: Bool) {
        setFocus(focus.keyIndex, active: active)
    }

    public func bringToFront(_ index: Int) {
        zOrder.removeAll { $0 == index }
        zOrder.append(index)
        zOrder.sort { !members[$0].onTop && members[$1].onTop }
    }

    public func topmostVisible() -> Int? {
        zOrder.reversed().first { canKey($0) }
    }

    public func canKey(_ index: Int) -> Bool {
        members[index].visible && !members[index].clickThrough
    }

    public func apply(index: Int, changes: DesktopChanges) {
        if changes.front && members[index].visible { bringToFront(index) }
        if changes.keys && canKey(index) { setFocus(index, active: true) }
    }

    public func settleKey() {
        if let idx = pointer.windowIndex, !members[idx].visible {
            pointer = .out
        }
        if let k = focus.keyIndex, canKey(k) { return }
        let next = topmostVisible()
        if next != focus.keyIndex {
            setFocus(next, active: focus.active)
        }
    }

    public func drain(desktop: VirtualDesktop, t: Double) {
        for _ in 0..<Self.maxDrainPasses {
            for i in members.indices {
                let changes = members[i].drain(desktop: desktop, t: t)
                apply(index: i, changes: changes)
            }
            settleKey()
            if !members.contains(where: \.hasPending) { return }
        }
    }

    public func catchUp(desktop: VirtualDesktop, t: Double) {
        for _ in 0..<Self.maxDrainPasses {
            var stepped = false
            for m in members where m.visible && m.isStale {
                m.advance(dt: 0.0)
                stepped = true
            }
            if !stepped { return }
            drain(desktop: desktop, t: t)
        }
    }

    public func originPx(for index: Int) -> (Float, Float) {
        let f = members[index].frame
        return (
            ((f[0] - origin.0) * scale).rounded(),
            ((f[1] - origin.1) * scale).rounded()
        )
    }

    public func originPt(for index: Int) -> (Float, Float) {
        let (x, y) = originPx(for: index)
        return (x / scale, y / scale)
    }

    public func hit(at point: (Float, Float)) -> Int? {
        zOrder.reversed().first { i in
            let m = members[i]
            let (ox, oy) = originPt(for: i)
            let f = m.frame
            return m.visible && !m.clickThrough
                && point.0 >= ox && point.1 >= oy
                && point.0 < ox + f[2] && point.1 < oy + f[3]
        }
    }

    public func find(key: String) -> (Float, Float)? {
        var order: [Int] = []
        if let k = focus.keyIndex { order.append(k) }
        for i in zOrder.reversed() where i != focus.keyIndex { order.append(i) }
        for i in order where members[i].visible {
            if let local = members[i].find(key: key) {
                let (ox, oy) = originPt(for: i)
                return (local.0 + ox, local.1 + oy)
            }
        }
        return nil
    }

    public func pointerLocation() -> (Float, Float)? {
        guard let i = pointer.windowIndex, let local = members[i].pointer() else { return nil }
        let (ox, oy) = originPt(for: i)
        return (local.0 + ox, local.1 + oy)
    }

    public func pointerInput(kind: DesktopInputKind, at point: (Float, Float)) {
        let captured: Int?
        if case .pressed(let i) = pointer, case .move = kind {
            captured = i
        } else if case .pressed(let i) = pointer, kind.isUp {
            captured = i
        } else {
            captured = nil
        }

        let target = captured ?? hit(at: point)
        if (kind == .move || kind.isDown) && pointer.windowIndex != target && captured == nil {
            if let prev = pointer.windowIndex {
                members[prev].leave()
            }
            pointer = target.map { .over($0) } ?? .out
        }
        if kind.isDown {
            pointer = target.map { .pressed($0) } ?? .out
            if let i = target {
                bringToFront(i)
                setFocus(i, active: true)
            } else {
                setActive(false)
            }
        }
        if kind.isUp, case .pressed(let i) = pointer {
            pointer = .over(i)
        }
        if let i = target {
            let (ox, oy) = originPt(for: i)
            members[i].input(kind, at: (point.0 - ox, point.1 - oy))
        }
    }

    public func fileInput(phase: FileDropPhase, at point: (Float, Float)) {
        let isLeave: Bool
        if case .exited = phase { isLeave = true } else { isLeave = false }
        let isHover: Bool
        if case .hovered = phase { isHover = true } else { isHover = false }

        let target = isLeave ? files.windowIndex : hit(at: point)
        if let old = files.windowIndex, old != target {
            members[old].input(.fileDrop(.exited), at: (0, 0))
        }
        files = (isHover ? target : nil).map { .over($0) } ?? .none
        if let i = target {
            let (ox, oy) = originPt(for: i)
            members[i].input(.fileDrop(phase), at: (point.0 - ox, point.1 - oy))
        }
    }

    public func reopen(accessory: Bool, desktop: VirtualDesktop, t: Double) {
        let candidates = members.map { $0.reopenCandidate() }
        let hasVisible = DesktopReopen.hasVisible(candidates)
        var handled = false
        for m in members {
            if m.runReopenHook(hasVisibleWindows: hasVisible) {
                handled = true
            }
        }
        if handled || accessory { return }
        drain(desktop: desktop, t: t)
        let refreshed = members.map { $0.reopenCandidate() }
        if let targetIdx = DesktopReopen.target(refreshed) {
            let changes = members[targetIdx].reopen()
            apply(index: targetIdx, changes: changes)
        }
    }

    public func stateSnapshot(for index: Int) -> (frame: [Float], visible: Bool, focused: Bool) {
        let m = members[index]
        let f = m.frame
        return (
            [f[0] - origin.0, f[1] - origin.1, f[2], f[3]],
            m.visible,
            focus.focusedIndex == index
        )
    }

    public func snapshot(for index: Int, t: Double) -> HeadlessWindowFrame {
        let st = stateSnapshot(for: index)
        return HeadlessWindowFrame(
            t: t,
            key: members[index].key,
            frame: st.frame,
            visible: st.visible,
            focused: st.focused
        )
    }

    /// Renders all visible windows in z-order and composites them over `backdropRGBA`.
    public func renderCompositeFrame(backdropRGBA: [UInt8], width: Int, height: Int) -> Frame {
        let keyIndex = focus.focusedIndex
        var layers: [(rgba: [UInt8], width: Int, height: Int, originPx: (Float, Float), cornerRadiusPx: Float, hasShadow: Bool, isKey: Bool)] = []
        for i in zOrder {
            let m = members[i]
            guard m.visible, let frame = m.renderFrame(scale: scale) else { continue }
            layers.append((
                rgba: frame.rgba,
                width: frame.width,
                height: frame.height,
                originPx: originPx(for: i),
                cornerRadiusPx: m.cornerRadius * scale,
                hasShadow: m.hasShadow,
                isKey: keyIndex == i
            ))
        }
        return DesktopComposite.compositeFrame(
            backdropRGBA: backdropRGBA,
            width: width,
            height: height,
            scale: scale,
            windows: layers
        )
    }
}
