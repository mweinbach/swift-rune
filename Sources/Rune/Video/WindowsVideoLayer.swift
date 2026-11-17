#if os(Windows) && canImport(CRuneMedia)
import CRuneWin32
import Foundation

/// Shared by every placement of one video, including placements in different windows.
internal final class WindowsVideoPublication: @unchecked Sendable {
    private let lock = NSLock()
    private var placements: [ObjectIdentifier: WindowsVideoPlacement] = [:]

    fileprivate func add(_ placement: WindowsVideoPlacement) {
        lock.withLock { placements[ObjectIdentifier(placement)] = placement }
    }

    fileprivate func remove(_ placement: WindowsVideoPlacement) {
        _ = lock.withLock { placements.removeValue(forKey: ObjectIdentifier(placement)) }
    }

    var wantsPictures: Bool {
        let current = lock.withLock { placements }
        return current.values.contains { $0.wantsPictures }
    }

    var isPresenting: Bool {
        let current = lock.withLock { placements }
        return !current.isEmpty && current.values.allSatisfy(\.isPresenting)
    }

    func requestRedraw() {
        let current = lock.withLock { placements }
        for placement in current.values { placement.wake.post() }
    }

    /// A blocked placement needs the ordinary compositor's wake. The other windows can
    /// continue presenting their own copies on the decoder queue.
    func present(_ frame: NativeSurfaceVideoFrame) -> Bool {
        let current = lock.withLock { placements }
        var all = !current.isEmpty
        for placement in current.values {
            if !placement.present(frame) { all = false }
        }
        return all
    }
}

private final class WindowsVideoPlacement: @unchecked Sendable {
    let publication: WindowsVideoPublication
    let wake: Win32Wake
    private let lock = NSLock()
    private var layer: OpaquePointer?
    private var failed = false
    // `wanted` carries the window's request to the decoder, `layer` its primed
    // swap chain back to the window. Only an attached visual can replace UI wakes.
    private var lastDevice: UInt = 0
    private var last: WindowsVideoLayerGeometry?
    private var wanted: (geometry: WindowsVideoLayerGeometry, host: OpaquePointer)?
    private var attached = false

    init(publication: WindowsVideoPublication, wake: Win32Wake) {
        self.publication = publication
        self.wake = wake
        publication.add(self)
    }

    var wantsPictures: Bool {
        lock.withLock { wanted != nil && !failed }
    }

    var isPresenting: Bool {
        // A frame arriving during decoder setup can continue through the UI.
        guard lock.try() else { return false }
        defer { lock.unlock() }
        return attached && !failed
    }

    func present(_ frame: NativeSurfaceVideoFrame) -> Bool {
        lock.withLock {
            guard !failed, let (desired, host) = wanted,
                  desired.sourceWidth == frame.size.0, desired.sourceHeight == frame.size.1,
                  desired.format == frame.format, desired.color == frame.color, frame.orient == .up,
                  case .decoded(let picture) = frame.source, let texture = picture.texture else { return false }
            if let layer {
                if rune_win_video_present(layer, texture, 0) == 0 { failed = true }
                return attached && !failed
            }
            layer = rune_win_video_prepare(host, texture, 0, desired.sourceWidth, desired.sourceHeight,
                                           desired.x, desired.y, desired.width, desired.height,
                                           desired.clip.x, desired.clip.y, desired.clip.z, desired.clip.w,
                                           frame.format == .nv12Full ? 1 : 0, frame.color.matrix == .bt709 ? 1 : 0)
            failed = layer == nil
            return false // ask the UI thread to attach the primed swap chain
        }
    }

    func covers(_ destination: WindowsVideoLayerGeometry?, device: UInt) -> Bool {
        // Only this window thread attaches or removes the visual. An in-flight
        // decoder present still leaves its previous picture on glass.
        guard attached, destination != nil, destination == last, device == lastDevice else { return false }
        guard lock.try() else { return true }
        defer { lock.unlock() }
        return !failed
    }

    /// A failed visual that covered the just-presented UI stays up until a replacement
    /// frame has drawn the clip underneath it.
    @discardableResult
    func update(_ destination: WindowsVideoLayerGeometry?, device: UInt, omittedFromUI: Bool, host: () -> OpaquePointer?) -> Bool {
        // Repainting unrelated UI must never wait for decoder work at an unchanged
        // placement. Geometry changes synchronize removal before the next presentation.
        let differentDevice = device != lastDevice
        let changed = destination != last || differentDevice
        last = destination
        lastDevice = device
        if changed { lock.lock() } else if !lock.try() { return false }
        defer { lock.unlock() }
        if failed && omittedFromUI { return true }
        if destination != wanted?.geometry || differentDevice || failed {
            if let layer { rune_win_video_hide(wanted?.host, layer); self.layer = nil }
            attached = false
            wanted = nil
        }
        // Give geometry one complete UI frame to settle. Retry an unsupported driver
        // only when the placement changes or the stream leaves the window.
        if changed { failed = false; return false }
        guard let destination, !failed, !attached else { return false }
        if let layer, let wanted {
            attached = rune_win_video_attach(wanted.host, layer) != 0
            failed = !attached
        } else if wanted == nil, let native = host() {
            wanted = (destination, native)
        }
        return false
    }

    func close(host: OpaquePointer?) {
        publication.remove(self)
        lock.withLock {
            if let layer { rune_win_video_hide(host, layer) }
            layer = nil
            wanted = nil
            attached = false
        }
    }
}

internal final class WindowsVideoLayers {
    fileprivate struct Candidate {
        let surface: NativeSurface
        let destination: WindowsVideoLayerGeometry?
        let device: UInt
        let omitted: Bool
    }

    struct Prepared {
        let ui: RenderFrame
        fileprivate let placements: [Candidate]
    }

    private static let enabled = ProcessInfo.processInfo.environment["RUNE_VIDEO_LAYER"] != "0"
    private let hwnd: UnsafeMutableRawPointer?
    private let wake: Win32Wake
    private var native: OpaquePointer?
    private var triedOpening = false
    private var entries: [UInt: WindowsVideoPlacement] = [:]

    init(hwnd: UnsafeMutableRawPointer?, wake: Win32Wake) {
        self.hwnd = hwnd
        self.wake = wake
    }
    deinit { clear() }

    private func host() -> OpaquePointer? {
        if !triedOpening {
            triedOpening = true
            native = rune_win_video_window(hwnd)
        }
        return native
    }

    func clear() {
        for placement in entries.values { placement.close(host: native) }
        entries.removeAll()
        if let native { rune_win_video_window_free(native) }
        native = nil
        triedOpening = false
    }

    /// The renderer only omits a picture while this particular window has a committed
    /// visual covering its entire visible rectangle. Other consumers still see the
    /// original frame and its retained decoder picture.
    func prepare(_ frame: RenderFrame, allowPromotion: Bool) -> Prepared {
        guard Self.enabled, !frame.surfaces.isEmpty else { return Prepared(ui: frame, placements: []) }
        var candidates: [Candidate] = []
        var omitted: Set<UInt> = []
        var seen: Set<UInt> = []
        for i in frame.surfaces.indices {
            let draw = frame.surfaces[i]
            let key = draw.surface.key
            guard draw.surface.videoAttachment != nil, seen.insert(key).inserted else { continue }
            let shot = draw.surface.renderSnapshot()
            let destination: WindowsVideoLayerGeometry?
            var device: UInt = 0
            if allowPromotion, let shot, !shot.mirrored, !draw.surface.isObserved, draw.surface.videoSnapshot()?.state == .playing,
               shot.frame.orient == .up, case .decoded(let picture) = shot.frame.source,
               !frame.surfaces[(i + 1)...].contains(where: { $0.surface.key == key }) {
                device = rune_win_video_device_id(picture.texture)
                destination = WindowsVideoLayerGeometry.destination(frame, index: i, picture: shot.frame)
            } else {
                destination = nil
            }
            let covered = entries[key]?.covers(destination, device: device) == true
            if covered { omitted.insert(key) }
            candidates.append(Candidate(surface: draw.surface, destination: destination, device: device, omitted: covered))
        }
        var ui = frame
        if !omitted.isEmpty { ui.surfaces.removeAll { omitted.contains($0.surface.key) } }
        return Prepared(ui: ui, placements: candidates)
    }

    func didPresent(_ prepared: Prepared) -> Bool {
        var remaining = entries
        var redraw = false
        for candidate in prepared.placements {
            let key = candidate.surface.key
            let placement: WindowsVideoPlacement
            if let old = remaining.removeValue(forKey: key) {
                placement = old
            } else {
                placement = WindowsVideoPlacement(publication: candidate.surface.registerWindowsVideoLayers(), wake: wake)
                entries[key] = placement
            }
            if placement.update(candidate.destination, device: candidate.device, omittedFromUI: candidate.omitted, host: host) {
                redraw = true
            }
        }
        for (key, placement) in remaining {
            placement.close(host: native)
            entries.removeValue(forKey: key)
        }
        return redraw
    }
}
#endif
