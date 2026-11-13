import Foundation
import RuneRef
#if canImport(Metal)
import Metal
#endif

/// Feature flags requested by a `Compositor` (`rune::compose::Features`).
public struct CompositorFeatures: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Pass an sRGB-encoded render target when `srgbBlend` is disabled, or linear/unorm matching `srgbBlend`.
    public static let prefersSurfaceFormatMatch = CompositorFeatures(rawValue: 1 << 0)
    /// Compositor clears the target itself before drawing.
    public static let customClear = CompositorFeatures(rawValue: 1 << 1)
}

/// Render frame context passed to `Compositor.render(frame:)` (`rune::compose::Frame<'a, S>`).
public final class CompositorFrame<State> {
    public let deviceKey: DeviceKey
    public let pixelSize: (width: Int, height: Int)
    public let dt: Float
    public let updateMilliseconds: Double
    public let srgbBlend: Bool
    public let runtime: Runtime<State>
    public private(set) var uiDrawCount: Int = 0

    private let drawUIImpl: () -> Void

    #if canImport(Metal)
    public let device: MTLDevice?
    public let commandQueue: MTLCommandQueue?
    public let commandBuffer: MTLCommandBuffer?
    public let targetTexture: MTLTexture?
    public let pixelFormat: MTLPixelFormat
    public let renderer: MetalRenderer?
    #endif

    #if canImport(Metal)
    public init(
        deviceKey: DeviceKey,
        pixelSize: (width: Int, height: Int),
        dt: Float,
        updateMilliseconds: Double,
        srgbBlend: Bool,
        runtime: Runtime<State>,
        device: MTLDevice? = nil,
        commandQueue: MTLCommandQueue? = nil,
        commandBuffer: MTLCommandBuffer? = nil,
        targetTexture: MTLTexture? = nil,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        renderer: MetalRenderer? = nil,
        drawUI: @escaping () -> Void = {}
    ) {
        self.deviceKey = deviceKey
        self.pixelSize = pixelSize
        self.dt = dt
        self.updateMilliseconds = updateMilliseconds
        self.srgbBlend = srgbBlend
        self.runtime = runtime
        self.device = device
        self.commandQueue = commandQueue
        self.commandBuffer = commandBuffer
        self.targetTexture = targetTexture
        self.pixelFormat = pixelFormat
        self.renderer = renderer
        self.drawUIImpl = drawUI
    }

    /// Copies bytes into a host-visible Metal buffer at `offset` (`Frame::write_buffer`).
    public func writeBuffer(
        _ buffer: MTLBuffer,
        offset: Int = 0,
        bytes: UnsafeRawPointer,
        length: Int
    ) {
        guard length > 0, offset >= 0, offset + length <= buffer.length else { return }
        memcpy(buffer.contents().advanced(by: offset), bytes, length)
    }
    #else
    public init(
        deviceKey: DeviceKey,
        pixelSize: (width: Int, height: Int),
        dt: Float,
        updateMilliseconds: Double,
        srgbBlend: Bool,
        runtime: Runtime<State>,
        drawUI: @escaping () -> Void = {}
    ) {
        self.deviceKey = deviceKey
        self.pixelSize = pixelSize
        self.dt = dt
        self.updateMilliseconds = updateMilliseconds
        self.srgbBlend = srgbBlend
        self.runtime = runtime
        self.drawUIImpl = drawUI
    }
    #endif

    /// Draws the Rune UI tree on top of the current target (`Frame::draw_ui`).
    public func drawUI() {
        uiDrawCount += 1
        drawUIImpl()
    }
}

/// True when `primitive` encodes a glyph quad (`rune::compose::is_glyph`).
public func isGlyph(_ primitive: Primitive) -> Bool {
    primitive.kind == .glyph
}

/// Custom GPU/Metal compositor protocol hooked onto `App` (`rune::compose::Compositor<S>`).
public protocol Compositor<State>: AnyObject {
    associatedtype State

    var features: CompositorFeatures { get }
    func render(frame: CompositorFrame<State>)
    var isAnimating: Bool { get }
    var drawsOwnContent: Bool { get }
    func summary() -> String?
}

public extension Compositor {
    var features: CompositorFeatures { [] }
    var isAnimating: Bool { false }
    var drawsOwnContent: Bool { false }
    func summary() -> String? { nil }
}

/// Type-erased wrapper for any `Compositor` or legacy `RuneCompositor`.
public final class AnyCompositor<State> {
    private let featuresImpl: () -> CompositorFeatures
    private let renderImpl: (CompositorFrame<State>) -> Void
    private let animatingImpl: () -> Bool
    private let drawsOwnImpl: () -> Bool
    private let summaryImpl: () -> String?

    public init<C: Compositor>(_ compositor: C) where C.State == State {
        self.featuresImpl = { compositor.features }
        self.renderImpl = { compositor.render(frame: $0) }
        self.animatingImpl = { compositor.isAnimating }
        self.drawsOwnImpl = { compositor.drawsOwnContent }
        self.summaryImpl = { compositor.summary() }
    }

    private init(
        features: @escaping () -> CompositorFeatures,
        render: @escaping (CompositorFrame<State>) -> Void,
        isAnimating: @escaping () -> Bool,
        drawsOwnContent: @escaping () -> Bool,
        summary: @escaping () -> String?
    ) {
        self.featuresImpl = features
        self.renderImpl = render
        self.animatingImpl = isAnimating
        self.drawsOwnImpl = drawsOwnContent
        self.summaryImpl = summary
    }

    /// Adapts a legacy `RuneCompositor` from `FlightAndMemo.swift`.
    public static func wrapping(_ legacy: RuneCompositor) -> AnyCompositor<State> {
        AnyCompositor(
            features: { [] },
            render: { frame in
                let info = CompositorFrameInfo(
                    deviceKey: frame.deviceKey,
                    pixelSize: frame.pixelSize,
                    dt: Double(frame.dt),
                    updateMilliseconds: frame.updateMilliseconds,
                    srgbBlend: frame.srgbBlend
                )
                legacy.render(frame: info)
                if !legacy.drawsOwnContent {
                    frame.drawUI()
                }
            },
            isAnimating: { legacy.isAnimating },
            drawsOwnContent: { legacy.drawsOwnContent },
            summary: { legacy.summary() }
        )
    }

    public var features: CompositorFeatures { featuresImpl() }
    public func render(frame: CompositorFrame<State>) { renderImpl(frame) }
    public var isAnimating: Bool { animatingImpl() }
    public var drawsOwnContent: Bool { drawsOwnImpl() }
    public func summary() -> String? { summaryImpl() }
}
