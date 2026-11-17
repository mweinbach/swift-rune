import Foundation
#if os(Android)
import Android
#endif
import RuneMotion
import RuneRef

#if canImport(simd)
import simd
#endif

#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension Align {
    internal var factor: Float {
        switch self {
        case .start: return 0.0
        case .center: return 0.5
        case .end: return 1.0
        }
    }
}

/// How a video or `NativeSurface` picture fits its element box (`rune::SurfaceFit`).
public enum SurfaceFit: UInt8, Sendable, Equatable, Hashable, Codable {
    /// Letterbox inside the box preserving aspect ratio (`SurfaceFit::Fit`).
    case fit
    /// Scale to cover/crop the box preserving aspect ratio (`SurfaceFit::Fill`).
    case fill
    /// Stretch non-uniformly to match the box exactly.
    case stretch

    public static var contain: SurfaceFit { .fit }
    public static var cover: SurfaceFit { .fill }
}

/// Where an image sits inside a surface element box (`rune::native_surface::SurfacePlace`).
public struct SurfacePlace: Sendable, Equatable, Hashable {
    public var anchor: (Align, Align)
    public var unscaled: Bool

    public static let centered = SurfacePlace(anchor: (.center, .center), unscaled: false)

    public init(anchor: (Align, Align) = (.center, .center), unscaled: Bool = false) {
        self.anchor = anchor
        self.unscaled = unscaled
    }

    public static func == (lhs: SurfacePlace, rhs: SurfacePlace) -> Bool {
        lhs.anchor.0 == rhs.anchor.0 && lhs.anchor.1 == rhs.anchor.1 && lhs.unscaled == rhs.unscaled
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(anchor.0)
        hasher.combine(anchor.1)
        hasher.combine(unscaled)
    }

    /// Share of extra space `[0, 1]` used for `(horizontal, vertical)` positioning.
    public var share: (Float, Float) {
        (anchor.0.factor, anchor.1.factor)
    }

    /// Computes `[x, y, w, h]` of the picture in pixel coordinates inside `node` `[x, y, w, h]`.
    public func imageRect(forNode node: SIMD4<Float>, imageSize: (UInt32, UInt32), fit: SurfaceFit) -> SIMD4<Float> {
        let iw = max(Float(imageSize.0), 1.0)
        let ih = max(Float(imageSize.1), 1.0)
        let nw = max(node.z, 0.0)
        let nh = max(node.w, 0.0)

        let outW: Float
        let outH: Float
        let scale: Float
        if unscaled {
            scale = 1.0
            outW = iw
            outH = ih
        } else {
            switch fit {
            case .fit:
                scale = min(nw / iw, nh / ih)
                outW = iw * scale
                outH = ih * scale
            case .fill:
                scale = max(nw / iw, nh / ih)
                outW = iw * scale
                outH = ih * scale
            case .stretch:
                scale = 0.0
                outW = nw
                outH = nh
            }
        }

        let (ax, ay) = share
        let ox = node.x + (nw - outW) * ax
        let oy = node.y + (nh - outH) * ay
        if abs(scale - 1.0) < 1e-6 {
            return SIMD4<Float>(ox.rounded(), oy.rounded(), outW, outH)
        }
        return SIMD4<Float>(ox, oy, outW, outH)
    }
}

/// 2x2 orientation matrix mapping upright normalized UVs `[0, 1]^2` (centered at `(0.5, 0.5)`)
/// into the stored buffer's normalized UV coordinates (`rune::native_surface::Orient`).
public struct Orient: Sendable, Equatable, Hashable {
    /// Column-major or row entries matching WGSL `mat2x2` row application:
    /// `duv = vec2(m00 * u + m01 * v, m10 * u + m11 * v)`.
    public var m00: Float
    public var m01: Float
    public var m10: Float
    public var m11: Float

    public static let up = Orient(m00: 1, m01: 0, m10: 0, m11: 1)

    public init(m00: Float, m01: Float, m10: Float, m11: Float) {
        self.m00 = m00
        self.m01 = m01
        self.m10 = m10
        self.m11 = m11
    }

    /// True if stored axes are transposed relative to upright presentation (e.g., 90° / 270° rotation).
    public var swaps: Bool {
        abs(m00) < 0.5 && abs(m11) < 0.5 && (abs(m01) > 0.5 || abs(m10) > 0.5)
    }

    /// Upright `(width, height)` after applying this orientation to stored `(width, height)`.
    public func upright(width: UInt32, height: UInt32) -> (UInt32, UInt32) {
        swaps ? (height, width) : (width, height)
    }

    /// Rounds an affine linear part `(a, b, c, d)` mapping stored buffer coordinates into upright display coordinates
    /// (`x' = a*x + c*y`, `y' = b*x + d*y`) into an axis-aligned quarter-turn/flip `Orient` (`Orient::from_transform`).
    ///
    /// Because orthogonal matrices invert by transpose, the upright->buffer matrix is `[a, b; c, d]`.
    public static func fromMatrix(a: Double, b: Double, c: Double, d: Double) -> Orient {
        let raw = [a, b, c, d]
        let m = raw.map { $0.rounded() }
        let unit = m.allSatisfy { abs($0) <= 1.0 } && zip(m, raw).allSatisfy { abs($0.0 - $0.1) < 1e-3 }
        let quarter = (m[0] != 0.0 && m[3] != 0.0 && m[1] == 0.0 && m[2] == 0.0)
            || (m[0] == 0.0 && m[3] == 0.0 && m[1] != 0.0 && m[2] != 0.0)
        if unit && quarter {
            return Orient(m00: Float(m[0]), m01: Float(m[1]), m10: Float(m[2]), m11: Float(m[3]))
        }
        return .up
    }

    #if canImport(CoreGraphics)
    public static func fromTransform(_ t: CGAffineTransform) -> Orient {
        fromMatrix(a: Double(t.a), b: Double(t.b), c: Double(t.c), d: Double(t.d))
    }
    #endif
}

/// YCbCr color matrix standard (`rune::native_surface::Matrix`).
public enum SurfaceMatrix: UInt32, Sendable, Equatable, Hashable, Codable {
    case bt601 = 0
    case bt709 = 1
}

/// Color transfer characteristic (`rune::native_surface::Transfer`).
public enum SurfaceTransfer: UInt32, Sendable, Equatable, Hashable, Codable {
    case srgb = 0
    case bt709 = 1
    case linear = 2
}

/// Pixel layout format of an imported frame (`rune::native_surface::Format`).
public enum SurfacePixelFormat: UInt32, Sendable, Equatable, Hashable, Codable {
    case bgra = 0
    case nv12Video = 1
    case nv12Full = 2
    case rgba = 3
}

/// Color metadata for conversion to linear RGB (`rune::native_surface::ColorInfo`).
public struct SurfaceColorInfo: Sendable, Equatable, Hashable, Codable {
    public var matrix: SurfaceMatrix
    public var transfer: SurfaceTransfer

    public static let bt709 = SurfaceColorInfo(matrix: .bt709, transfer: .bt709)
    public static let bt601 = SurfaceColorInfo(matrix: .bt601, transfer: .bt709)
    public static let srgb = SurfaceColorInfo(matrix: .bt709, transfer: .srgb)

    public init(matrix: SurfaceMatrix = .bt709, transfer: SurfaceTransfer = .srgb) {
        self.matrix = matrix
        self.transfer = transfer
    }
}

/// Errors thrown by `ByteFrame` or `NativeSurface` pixel imports.
public enum NativeSurfaceError: Error, Sendable, Equatable, CustomStringConvertible {
    case zeroDimensions
    case dimensionsOutOfRange(width: UInt32, height: UInt32)
    case oddNv12Dimensions(width: UInt32, height: UInt32)
    case wrongPlaneCount(expected: Int, got: Int)
    case wrongPlaneByteCount(plane: Int, expected: Int, got: Int)
    case importFailed(String)

    public var description: String {
        switch self {
        case .zeroDimensions:
            return "native surface frame dimensions must be non-zero"
        case .dimensionsOutOfRange(let w, let h):
            return "video size must be 1..16384, got \(w)x\(h)"
        case .oddNv12Dimensions(let w, let h):
            return "NV12 frame dimensions must be even, got \(w)x\(h)"
        case .wrongPlaneCount(let expected, let got):
            return "expected \(expected) plane(s), got \(got)"
        case .wrongPlaneByteCount(let plane, let expected, let got):
            return "plane \(plane) expected \(expected) bytes, got \(got)"
        case .importFailed(let msg):
            return "native surface import failed: \(msg)"
        }
    }
}

/// CPU byte-backed video/surface picture (`rune::native_surface::ByteFrame`).
public struct ByteFrame: Sendable, Equatable {
    public let width: UInt32
    public let height: UInt32
    public let format: SurfacePixelFormat
    public let color: SurfaceColorInfo
    public let planes: [Data]

    public init(
        width: UInt32,
        height: UInt32,
        format: SurfacePixelFormat,
        color: SurfaceColorInfo,
        planes: [Data]
    ) throws {
        guard width > 0 && height > 0 else {
            throw NativeSurfaceError.zeroDimensions
        }
        let pixels = UInt64(width) * UInt64(height)
        let channels: UInt64 = format == .rgba || format == .bgra ? 4 : 1
        guard pixels <= UInt64(Int.max) / channels else {
            throw NativeSurfaceError.dimensionsOutOfRange(width: width, height: height)
        }
        switch format {
        case .bgra, .rgba:
            guard planes.count == 1 else {
                throw NativeSurfaceError.wrongPlaneCount(expected: 1, got: planes.count)
            }
            let expected = Int(pixels * 4)
            guard planes[0].count == expected else {
                throw NativeSurfaceError.wrongPlaneByteCount(plane: 0, expected: expected, got: planes[0].count)
            }
        case .nv12Video, .nv12Full:
            guard width % 2 == 0 && height % 2 == 0 else {
                throw NativeSurfaceError.oddNv12Dimensions(width: width, height: height)
            }
            guard planes.count == 2 else {
                throw NativeSurfaceError.wrongPlaneCount(expected: 2, got: planes.count)
            }
            let yExpected = Int(pixels)
            let uvExpected = yExpected / 2
            guard planes[0].count == yExpected else {
                throw NativeSurfaceError.wrongPlaneByteCount(plane: 0, expected: yExpected, got: planes[0].count)
            }
            guard planes[1].count == uvExpected else {
                throw NativeSurfaceError.wrongPlaneByteCount(plane: 1, expected: uvExpected, got: planes[1].count)
            }
        }
        self.width = width
        self.height = height
        self.format = format
        self.color = color
        self.planes = planes
    }

    /// Reference CPU YCbCr->sRGB conversion for NV12 parity verification (`native_surface::nv12_reference`).
    public static func nv12Reference(
        y: UInt8,
        cb: UInt8,
        cr: UInt8,
        fullRange: Bool,
        matrix: SurfaceMatrix,
        transfer: SurfaceTransfer
    ) -> SIMD4<Float> {
        nv12Sample(y: Float(y), cb: Float(cb), cr: Float(cr), fullRange: fullRange, matrix: matrix, transfer: transfer)
    }

    /// Accepts fractional byte values after filtering the luma and chroma planes.
    internal static func nv12Sample(y: Float, cb: Float, cr: Float, fullRange: Bool,
                                    matrix: SurfaceMatrix, transfer: SurfaceTransfer) -> SIMD4<Float> {
        let yVal: Float
        let cbVal: Float
        let crVal: Float
        if fullRange {
            yVal = y / 255.0
            cbVal = (cb - 128.0) / 255.0
            crVal = (cr - 128.0) / 255.0
        } else {
            yVal = (y - 16.0) / 219.0
            cbVal = (cb - 128.0) / 224.0
            crVal = (cr - 128.0) / 224.0
        }
        let rN: Float
        let gN: Float
        let bN: Float
        switch matrix {
        case .bt601:
            rN = yVal + 1.402 * crVal
            gN = yVal - 0.344136 * cbVal - 0.714136 * crVal
            bN = yVal + 1.772 * cbVal
        case .bt709:
            rN = yVal + 1.5748 * crVal
            gN = yVal - 0.187324 * cbVal - 0.468124 * crVal
            bN = yVal + 1.8556 * cbVal
        }
        let cR = min(max(rN, 0.0), 1.0)
        let cG = min(max(gN, 0.0), 1.0)
        let cB = min(max(bN, 0.0), 1.0)
        return SIMD4<Float>(
            transferToLinear(cR, transfer),
            transferToLinear(cG, transfer),
            transferToLinear(cB, transfer),
            1.0
        )
    }

    /// Exact transfer-to-linear helper matching `video.wgsl` `linear()`.
    public static func transferToLinear(_ c: Float, _ transfer: SurfaceTransfer) -> Float {
        switch transfer {
        case .linear:
            return c
        case .srgb:
            return c <= 0.04045 ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4)
        case .bt709:
            return c < 0.081 ? (c / 4.5) : pow((c + 0.099) / 1.099, 1.0 / 0.45)
        }
    }

    /// Synthetic bars, gradient and one-pixel text-like strokes (`native_surface::synthetic`).
    public static func synthetic(width: UInt32, height: UInt32, index: UInt64) -> ByteFrame {
        precondition(width > 0 && height > 0 && width % 2 == 0 && height % 2 == 0,
                     "ByteFrame.synthetic requires non-zero even dimensions")
        let bars: [(UInt8, UInt8, UInt8)] = [
            (235, 128, 128),
            (210, 16, 146),
            (170, 166, 16),
            (145, 54, 34),
            (106, 202, 222),
            (81, 90, 240),
            (41, 240, 110),
            (16, 128, 128),
        ]
        let w = Int(width)
        let h = Int(height)
        let phase = UInt32(truncatingIfNeeded: index)
        var yPlane = Data(count: w * h)
        var uvPlane = Data(repeating: 128, count: (w * h) / 2)
        yPlane.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            for row in 0..<h {
                for x in 0..<w {
                    let val: UInt8
                    if row < h / 3 {
                        val = bars[(x * 8) / w].0
                    } else if row < (2 * h) / 3 {
                        val = UInt8(16 + (x * 219) / w)
                    } else if ((UInt32(x) &+ phase) % 8 == 0) || (row % 9 == 0) {
                        val = 235
                    } else {
                        val = 16
                    }
                    ptr[row * w + x] = val
                }
            }
        }
        uvPlane.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            for row in 0..<(h / 6) {
                for x in 0..<(w / 2) {
                    let bar = bars[(x * 16) / w]
                    let i = row * w + x * 2
                    ptr[i] = bar.1
                    ptr[i + 1] = bar.2
                }
            }
        }
        return try! ByteFrame(
            width: width,
            height: height,
            format: .nv12Video,
            color: .bt709,
            planes: [yPlane, uvPlane]
        )
    }
}

/// Source backing a `NativeSurfaceVideoFrame`.
public enum FrameSource: Sendable {
    case bytes(ByteFrame)
    #if os(Windows)
    case shared(WindowsSharedFrame)
    #if canImport(CRuneMedia)
    case decoded(WindowsDecodedPicture)
    #endif
    #endif
    #if canImport(CoreVideo) && canImport(IOSurface) && canImport(Metal)
    case pixelBuffer(CoreVideoPixelBuffer)
    #endif
}

/// Immutable surface frame pushed into a `NativeSurface`.
public struct NativeSurfaceVideoFrame: Sendable {
    public let id: UInt64
    public let size: (UInt32, UInt32)
    public let format: SurfacePixelFormat
    public let color: SurfaceColorInfo
    public let orient: Orient
    public let source: FrameSource

    public init(
        id: UInt64,
        size: (UInt32, UInt32),
        format: SurfacePixelFormat,
        color: SurfaceColorInfo,
        orient: Orient,
        source: FrameSource
    ) {
        self.id = id
        self.size = size
        self.format = format
        self.color = color
        self.orient = orient
        self.source = source
    }
}

/// GPU submission and completion timing delivered to `NativeSurface.setObserver`.
public struct FrameTiming: Sendable, Equatable {
    public let frameId: UInt64
    public let submittedAt: ContinuousClock.Instant
    public var completedAt: ContinuousClock.Instant?
    public var gpuStartSeconds: Double?
    public var gpuEndSeconds: Double?

    public init(
        frameId: UInt64,
        submittedAt: ContinuousClock.Instant,
        completedAt: ContinuousClock.Instant? = nil,
        gpuStartSeconds: Double? = nil,
        gpuEndSeconds: Double? = nil
    ) {
        self.frameId = frameId
        self.submittedAt = submittedAt
        self.completedAt = completedAt
        self.gpuStartSeconds = gpuStartSeconds
        self.gpuEndSeconds = gpuEndSeconds
    }
}

public typealias FrameObserver = @Sendable (FrameTiming) -> Void

/// Snapshot returned when `Runtime` pulls a `Player`-backed `NativeSurface`.
public struct VideoPullResult: Sendable {
    public let active: Bool
    public let generation: UInt64
    public let due: ContinuousClock.Instant?

    public init(active: Bool, generation: UInt64, due: ContinuousClock.Instant? = nil) {
        self.active = active
        self.generation = generation
        self.due = due
    }
}

/// Playback metadata snapshot exported for `--tree` JSON (`crate::video::Snapshot`).
public struct VideoSnapshot: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case video
        case audio
    }

    public typealias State = PlayerState

    public var kind: Kind
    public var state: PlayerState
    public var time: Double
    public var duration: Double?
    public var size: (UInt32, UInt32)?
    public var rate: Float
    public var looping: Bool
    public var muted: Bool

    public init(
        kind: Kind,
        state: State,
        time: Double,
        duration: Double?,
        size: (UInt32, UInt32)?,
        rate: Float,
        looping: Bool,
        muted: Bool
    ) {
        self.kind = kind
        self.state = state
        self.time = time
        self.duration = duration
        self.size = size
        self.rate = rate
        self.looping = looping
        self.muted = muted
    }

    public static func == (lhs: VideoSnapshot, rhs: VideoSnapshot) -> Bool {
        lhs.kind == rhs.kind &&
        lhs.state == rhs.state &&
        lhs.time == rhs.time &&
        lhs.duration == rhs.duration &&
        lhs.size?.0 == rhs.size?.0 &&
        lhs.size?.1 == rhs.size?.1 &&
        lhs.rate == rhs.rate &&
        lhs.looping == rhs.looping &&
        lhs.muted == rhs.muted
    }
}

/// Internal bridge from `NativeSurface` to the `Video` subsystem.
public protocol SurfaceVideoAttachment: AnyObject, Sendable {
    var videoKey: UInt64 { get }
    func pull(clock: Double, wake: (@Sendable () -> Void)?) -> VideoPullResult
    func snapshot() -> VideoSnapshot
}

// MARK: - Legacy Compat Types (used by existing RuneVideoTiles example)

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

    public init(
        width: UInt32,
        height: UInt32,
        format: NativeSurfaceFormat = .rgba8,
        bytes: Data,
        timestampSeconds: Double = 0
    ) {
        self.width = width
        self.height = height
        self.format = format
        self.bytes = bytes
        self.timestampSeconds = timestampSeconds
    }
}

/// Thread-safe latest-wins native picture slot consumed by `SurfaceRenderer` and `El.nativeSurface` (`rune::NativeSurface`).
public final class NativeSurface: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var current: NativeSurfaceVideoFrame?
        var generation: UInt64 = 0
        var frameRevision: UInt64 = 0
        var mirrored: Bool = false
        var waker: (@Sendable () -> Void)?
        var observer: FrameObserver?
        var legacyFrame: NativeSurfaceFrame?
        var video: SurfaceVideoAttachment?
        #if os(Windows) && canImport(CRuneMedia)
        var videoLayers: WindowsVideoPublication?
        #endif
        var error: String?
        var timing: FrameTiming?
        var submitted: UInt64 = 0
        var completed: UInt64 = 0
    }

    private let state: State
    private let retainedPlayer: Player?
    public let id: UInt64
    public let place: SurfacePlace

    private init(state: State, id: UInt64, place: SurfacePlace, retaining player: Player? = nil) {
        self.state = state
        self.id = id
        self.place = place
        self.retainedPlayer = player
    }

    public convenience init(id: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.init(state: State(), id: id, place: .centered)
    }

    /// Stable identity key for cache/signature correlation across `placed` shares.
    public var key: UInt {
        UInt(bitPattern: ObjectIdentifier(state))
    }

    /// Returns a view sharing the underlying frame slot with a different placement inside its element box.
    public func placed(_ place: SurfacePlace) -> NativeSurface {
        NativeSurface(state: state, id: id, place: place, retaining: retainedPlayer)
    }

    /// A mounted video owns its driver through the view handle. The shared picture
    /// slot and the original handle owned by the player remain independent.
    internal func retaining(_ player: Player) -> NativeSurface {
        NativeSurface(state: state, id: id, place: place, retaining: player)
    }

    /// Attaches a `Video` controller handle to this surface.
    public func withVideo(_ attachment: SurfaceVideoAttachment) {
        state.lock.lock()
        state.video = attachment
        state.lock.unlock()
    }

    public var videoAttachment: SurfaceVideoAttachment? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.video
    }

    #if os(Windows) && canImport(CRuneMedia)
    internal var windowsVideoLayers: WindowsVideoPublication? { state.lock.withLock { state.videoLayers } }

    internal func registerWindowsVideoLayers() -> WindowsVideoPublication {
        state.lock.withLock {
            if let existing = state.videoLayers { return existing }
            let publication = WindowsVideoPublication()
            state.videoLayers = publication
            return publication
        }
    }
    #endif

    public func videoSnapshot() -> VideoSnapshot? {
        videoAttachment?.snapshot()
    }

    public func pullVideo(clock: Double, wake: (@Sendable () -> Void)?) -> VideoPullResult? {
        guard let att = videoAttachment else { return nil }
        return att.pull(clock: clock, wake: wake)
    }

    public var generation: UInt64 {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.generation
    }

    public var isMirrored: Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.mirrored
    }

    public func setMirrored(_ mirrored: Bool) {
        let waker: (@Sendable () -> Void)?
        state.lock.lock()
        let changed = (state.mirrored != mirrored)
        state.mirrored = mirrored
        if changed {
            state.generation &+= 1
        }
        waker = changed ? state.waker : nil
        state.lock.unlock()
        waker?()
        #if os(Windows) && canImport(CRuneMedia)
        if changed { windowsVideoLayers?.requestRedraw() }
        #endif
    }

    public func currentFrame() -> NativeSurfaceVideoFrame? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.current
    }

    public func latestMirrored() -> (NativeSurfaceVideoFrame, Bool)? {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard let f = state.current else { return nil }
        return (f, state.mirrored)
    }

    /// A renderer must acquire the upload revision and its bytes in one read when
    /// a producer may replace the frame between draws.
    internal func renderSnapshot() -> (frame: NativeSurfaceVideoFrame, mirrored: Bool, revision: UInt64)? {
        state.lock.withLock {
            guard let frame = state.current else { return nil }
            return (frame, state.mirrored, state.frameRevision)
        }
    }

    public var isObserved: Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.observer != nil
    }

    public var lastError: String? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.error
    }

    internal func setLastError(_ err: String?) {
        state.lock.lock()
        state.error = err
        state.lock.unlock()
    }

    /// Latest submission/completion GPU timing recorded for this surface (`NativeSurface::timing`).
    public func timing() -> FrameTiming? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.timing
    }

    /// Counts draws submitted/completed (`NativeSurface::counts`).
    public func counts() -> (UInt64, UInt64) {
        state.lock.lock()
        defer { state.lock.unlock() }
        return (state.submitted, state.completed)
    }

    /// Installs a wake callback notified whenever a new frame or mirror toggle arrives.
    /// The previously installed closure is always dropped AFTER releasing the lock.
    public func setWaker(_ callback: (@Sendable () -> Void)?) {
        var old: (@Sendable () -> Void)?
        state.lock.lock()
        old = state.waker
        state.waker = callback
        state.lock.unlock()
        withExtendedLifetime(old) {}
        old = nil
    }

    /// Installs a frame GPU timing observer.
    /// The previously installed closure is always dropped AFTER releasing the lock.
    public func setObserver(_ callback: FrameObserver?) {
        var old: FrameObserver?
        state.lock.lock()
        old = state.observer
        state.observer = callback
        state.lock.unlock()
        #if os(Windows) && canImport(CRuneMedia)
        if (old == nil) != (callback == nil) { windowsVideoLayers?.requestRedraw() }
        #endif
        withExtendedLifetime(old) {}
        old = nil
    }

    /// Pushes CPU bytes using identity orientation.
    public func pushBytes(_ frame: ByteFrame, frameId: UInt64) throws {
        try pushBytesOriented(frame, orient: .up, frameId: frameId)
    }

    /// Pushes CPU bytes with explicit orientation matrix.
    public func pushBytesOriented(_ frame: ByteFrame, orient: Orient, frameId: UInt64) throws {
        guard frame.width >= 1 && frame.height >= 1 && frame.width <= 16_384 && frame.height <= 16_384 else {
            throw NativeSurfaceError.dimensionsOutOfRange(width: frame.width, height: frame.height)
        }
        let videoFrame = NativeSurfaceVideoFrame(
            id: frameId,
            size: (frame.width, frame.height),
            format: frame.format,
            color: frame.color,
            orient: orient,
            source: .bytes(frame)
        )
        replaceFrame(videoFrame)
    }

    #if canImport(CoreVideo) && canImport(IOSurface) && canImport(Metal)
    /// Pushes a CoreVideo pixel buffer using identity orientation.
    public func push(_ buffer: CoreVideoPixelBuffer, frameId: UInt64) throws {
        try pushOriented(buffer, orient: .up, frameId: frameId)
    }

    /// Pushes a CoreVideo pixel buffer with explicit orientation matrix.
    public func pushOriented(_ buffer: CoreVideoPixelBuffer, orient: Orient, frameId: UInt64) throws {
        let size = buffer.size
        guard size.0 > 0 && size.1 > 0 else {
            throw NativeSurfaceError.zeroDimensions
        }
        guard size.0 <= 16_384 && size.1 <= 16_384 else {
            throw NativeSurfaceError.dimensionsOutOfRange(width: size.0, height: size.1)
        }
        let fmt = try buffer.surfaceFormat()
        let col = buffer.colorInfo()
        let videoFrame = NativeSurfaceVideoFrame(
            id: frameId,
            size: size,
            format: fmt,
            color: col,
            orient: orient,
            source: .pixelBuffer(buffer)
        )
        replaceFrame(videoFrame)
    }
    #endif

    /// Clears the current frame slot and notifies the waker if one is installed.
    public func clear() {
        var oldFrame: NativeSurfaceVideoFrame?
        let waker: (@Sendable () -> Void)?
        state.lock.lock()
        oldFrame = state.current
        state.current = nil
        state.legacyFrame = nil
        if oldFrame != nil {
            state.generation &+= 1
        }
        waker = state.waker
        state.lock.unlock()
        withExtendedLifetime(oldFrame) {}
        oldFrame = nil
        waker?()
    }

    internal func replaceFrame(_ newFrame: NativeSurfaceVideoFrame, wake: Bool = true) {
        var oldFrame: NativeSurfaceVideoFrame?
        let waker: (@Sendable () -> Void)?
        state.lock.lock()
        oldFrame = state.current
        state.current = newFrame
        state.generation &+= 1
        state.frameRevision = state.generation
        waker = wake ? state.waker : nil
        state.lock.unlock()
        withExtendedLifetime(oldFrame) {}
        oldFrame = nil
        waker?()
    }

    /// Delivers GPU timing updates to the registered observer outside the surface lock.
    public func report(_ timing: FrameTiming) {
        let obs: FrameObserver?
        state.lock.lock()
        if state.timing.map({ $0.submittedAt <= timing.submittedAt }) ?? true {
            state.timing = timing
        }
        if timing.completedAt == nil {
            state.submitted &+= 1
        } else {
            state.completed &+= 1
        }
        obs = state.observer
        state.lock.unlock()
        obs?(timing)
    }

    // MARK: - Legacy `NativeSurfaceFrame` Compat

    private static func unpack(_ frame: NativeSurfaceFrame) -> ByteFrame? {
        guard frame.width > 0, frame.width <= 16_384, frame.height > 0, frame.height <= 16_384 else { return nil }
        let fmt: SurfacePixelFormat
        switch frame.format {
        case .rgba8: fmt = .rgba
        case .bgra8: fmt = .bgra
        case .nv12: fmt = .nv12Video
        }
        let planes: [Data]
        if frame.format == .nv12 {
            let yBytes = Int(frame.width) * Int(frame.height)
            if frame.bytes.count >= yBytes {
                planes = [frame.bytes.prefix(yBytes), frame.bytes.dropFirst(yBytes)]
            } else {
                planes = [frame.bytes, Data()]
            }
        } else {
            planes = [frame.bytes]
        }
        return try? ByteFrame(width: frame.width, height: frame.height, format: fmt, color: .srgb, planes: planes)
    }

    public func publish(_ frame: NativeSurfaceFrame) {
        let waker: (@Sendable () -> Void)?
        let bytes = Self.unpack(frame)
        var oldFrame: NativeSurfaceVideoFrame?
        state.lock.lock()
        state.legacyFrame = frame
        oldFrame = state.current
        state.generation &+= 1
        if let bytes {
            state.current = NativeSurfaceVideoFrame(
                id: state.generation, size: (bytes.width, bytes.height), format: bytes.format,
                color: bytes.color, orient: .up, source: .bytes(bytes)
            )
            state.frameRevision = state.generation
        }
        waker = state.waker
        state.lock.unlock()
        withExtendedLifetime(oldFrame) {}
        oldFrame = nil
        waker?()
    }

    public func latestFrame() -> NativeSurfaceFrame? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.legacyFrame
    }
}

/// Painter-order scheduled surface draw recorded by `Runtime` (`rune::native_surface::SurfaceDraw`).
public struct SurfaceDraw: @unchecked Sendable {
    public var surface: NativeSurface
    public var fit: SurfaceFit
    public var beforeInstance: UInt32
    /// Element bounds `[x, y, w, h]` in device pixels.
    public var rect: SIMD4<Float>
    /// Corner radii `(tl, tr, br, bl)` in device pixels.
    public var radii: SIMD4<Float>
    /// Scissor / clip rect `[l, t, r, b]` in device pixels.
    public var clip: SIMD4<Float>
    /// Feather / linear fade parameters matching `Primitive.fade`.
    public var fade: SIMD4<Float>
    public var fadeOrigin: SIMD2<Float>
    /// Packed `clip.wgsl` round/soft/linear fade mask (`RenderInstance.fade`).
    public var clipFade: SIMD4<UInt32>
    public var opacity: Float

    public init(
        surface: NativeSurface,
        fit: SurfaceFit,
        beforeInstance: UInt32,
        rect: SIMD4<Float>,
        radii: SIMD4<Float> = .zero,
        clip: SIMD4<Float>,
        fade: SIMD4<Float> = .zero,
        fadeOrigin: SIMD2<Float> = .zero,
        clipFade: SIMD4<UInt32> = .zero,
        opacity: Float = 1.0
    ) {
        self.surface = surface
        self.fit = fit
        self.beforeInstance = beforeInstance
        self.rect = rect
        self.radii = radii
        self.clip = clip
        self.fade = fade
        self.fadeOrigin = fadeOrigin
        self.clipFade = clipFade
        self.opacity = opacity
    }
}
