import Foundation
#if canImport(simd)
import simd
#endif

/// How a GPU's `rgba16Float` layer/blur texels round values below half precision (`cpu_boot::HalfRounding`).
public enum HalfRounding: Sendable, Equatable {
    case towardZero
    case nearestEven

    public static func ofVendor(_ vendor: UInt32) -> HalfRounding {
        // Measured toward zero on Intel (0x8086) and NVIDIA (0x10de); assumed toward zero for all others (`cpu_boot.rs`).
        switch vendor {
        case 0x8086, 0x10de: return .towardZero
        default: return .towardZero
        }
    }
}

/// Reasons `CpuBoot` defers rendering a `CpuBootScene` to the GPU (`cpu_boot::NeedsGpu`).
public enum NeedsGpu: Error, Sendable, Equatable, CustomStringConvertible {
    case target
    case linearBlend
    case nativeSurfaces
    case slugText
    case compositor
    case atlasResets
    case effect
    case rotatedLayer
    case filteredLayer
    case layerBlurUnsupported
    case backdropInLayer
    case outlineGlyph
    case unbalancedLayer
    case unknownKind(UInt32)

    public var description: String {
        switch self {
        case .target: return "Target buffer size/stride does not match scene dimensions"
        case .linearBlend: return "Scene blends in linear light (srgbBlend == false)"
        case .nativeSurfaces: return "Scene contains native video/surface layers"
        case .slugText: return "Scene uses Slug text coverage"
        case .compositor: return "Scene requires compositor-backed surfaces"
        case .atlasResets: return "Scene experienced glyph atlas resets"
        case .effect: return "Scene contains GPU-only KIND_EFFECT primitives"
        case .rotatedLayer: return "Scene contains rotated layer scope"
        case .filteredLayer: return "Scene contains layer Gaussian blur scope"
        case .layerBlurUnsupported: return "Layer blur is unsupported on CPU boot"
        case .backdropInLayer: return "Scene contains backdrop blur inside an isolated layer"
        case .outlineGlyph: return "Scene contains GPU-only outline glyph"
        case .unbalancedLayer: return "Scene contains unbalanced KIND_LAYER / KIND_LAYER_END"
        case .unknownKind(let k): return "Unsupported primitive kind \(k)"
        }
    }
}

/// One RGBA8 image page borrowed/copied into a `CpuBootScene` (`cpu_boot::Image`).
public struct CpuBootImage: Sendable {
    public var width: Int
    public var height: Int
    public var data: [UInt8]
    public var dirty: (UInt32, UInt32)?

    public init(width: Int, height: Int? = nil, data: [UInt8], dirty: (UInt32, UInt32)? = nil) {
        self.width = max(0, width)
        if let height {
            self.height = max(0, height)
        } else {
            let rowBytes = max(width * 4, 1)
            self.height = data.count / rowBytes
        }
        self.data = data
        self.dirty = dirty
    }
}

/// Retained BGRA8 pixel buffer painted by `CpuBoot` (`cpu_boot::Target`).
public struct CpuBootTarget: Sendable {
    public let width: Int
    public let height: Int
    public let stride: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, stride: Int? = nil, pixels: [UInt8]? = nil) {
        let w = max(0, width)
        let h = max(0, height)
        let s = max(stride ?? (w * 4), w * 4)
        self.width = w
        self.height = h
        self.stride = s
        self.pixels = pixels ?? Array(repeating: 0, count: h * s)
    }

    public static func withStride(width: Int, height: Int, stride: Int, pixels: [UInt8]? = nil) -> CpuBootTarget {
        CpuBootTarget(width: width, height: height, stride: stride, pixels: pixels)
    }

    /// Converts stored BGRA8 pixels to tightly packed straight/premultiplied RGBA8 for PNG/comparison.
    public func toRGBA8Tight() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let srcRow = y * stride
            let dstRow = y * width * 4
            for x in 0..<width {
                let s = srcRow + x * 4
                let d = dstRow + x * 4
                out[d + 0] = pixels[s + 2]
                out[d + 1] = pixels[s + 1]
                out[d + 2] = pixels[s + 0]
                out[d + 3] = pixels[s + 3]
            }
        }
        return out
    }
}

/// Per-frame timing and pixel statistics returned by `CpuBoot.paint` (`cpu_boot::Report`).
public struct CpuBootReport: Sendable, Equatable {
    public var threads: Int = 1
    public var binNs: UInt64 = 0
    public var rasterNs: UInt64 = 0
    public var totalNs: UInt64 = 0
    public var tiles: Int = 0
    public var binned: Int = 0
    public var culled: Int = 0
    public var cleared: Int = 0
    public var spanPx: UInt64 = 0
    public var shadedPx: UInt64 = 0
    public var glyphPx: UInt64 = 0
    public var slowestTileNs: UInt64 = 0
    public var blurNs: UInt64 = 0

    public init() {}
}

/// Complete scene snapshot accepted by the CPU fallback rasterizer (`cpu_boot::Scene`).
public struct CpuBootScene: Sendable {
    public var instances: [RenderInstance]
    public var glyphPages: [[UInt8]]
    public var glyphPageWidth: Int
    public var glyphPageHeight: Int
    public var images: [CpuBootImage]
    public var size: (Int, Int)
    public var clear: SIMD4<Float>
    public var lcd: Bool
    public var srgbBlend: Bool
    public var nativeSurfaces: Bool
    public var compositor: Bool
    public var smoothing: FontSmoothing?
    public var outlines: OutlineStore?
    public var atlasResets: Int
    public var half: HalfRounding

    public init(
        instances: [RenderInstance],
        glyphPages: [[UInt8]] = [],
        glyphPageWidth: Int = 512,
        glyphPageHeight: Int = 512,
        images: [CpuBootImage] = [],
        size: (Int, Int),
        clear: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
        lcd: Bool = false,
        srgbBlend: Bool = true,
        nativeSurfaces: Bool = false,
        compositor: Bool = false,
        smoothing: FontSmoothing? = nil,
        outlines: OutlineStore? = nil,
        atlasResets: Int = 0,
        half: HalfRounding = .towardZero
    ) {
        self.instances = instances
        self.glyphPages = glyphPages
        self.glyphPageWidth = max(1, glyphPageWidth)
        self.glyphPageHeight = max(1, glyphPageHeight)
        self.images = images
        self.size = size
        self.clear = clear
        self.lcd = lcd
        self.srgbBlend = srgbBlend
        self.nativeSurfaces = nativeSurfaces
        self.compositor = compositor
        self.smoothing = smoothing
        self.outlines = outlines
        self.atlasResets = atlasResets
        self.half = half
    }

    /// Adapts a `RenderFrame` for CPU fallback rasterization.
    public init(
        frame: RenderFrame,
        lcd: Bool = false,
        compositor: Bool = false,
        smoothing: FontSmoothing? = nil,
        outlines: OutlineStore? = nil,
        atlasResets: Int = 0,
        half: HalfRounding = .towardZero
    ) {
        let gPages = frame.glyphs.texels.isEmpty ? [] : [frame.glyphs.texels]
        let iPages = frame.images.texels.isEmpty
            ? []
            : [CpuBootImage(width: frame.images.width, height: frame.images.height, data: frame.images.texels)]
        self.init(
            instances: frame.instances,
            glyphPages: gPages,
            glyphPageWidth: frame.glyphs.width,
            glyphPageHeight: frame.glyphs.height,
            images: iPages,
            size: (frame.width, frame.height),
            clear: frame.clearColor,
            lcd: lcd,
            srgbBlend: frame.srgbBlend,
            nativeSurfaces: !frame.surfaces.isEmpty,
            compositor: compositor,
            smoothing: smoothing,
            outlines: outlines,
            atlasResets: atlasResets,
            half: half
        )
    }

    /// Returns why the scene must be drawn by the GPU, or `nil` when CPU boot can rasterize it accurately (`cpu_boot.rs`).
    public func needsGpu() -> NeedsGpu? {
        if !srgbBlend { return .linearBlend }
        if nativeSurfaces { return .nativeSurfaces }
        if smoothing == .slug { return .slugText }

        var layerDepth = 0
        for inst in instances {
            let k = inst.params.y
            guard (0.0...13.0).contains(k), k.truncatingRemainder(dividingBy: 1.0) == 0.0 else {
                let raw = k.isFinite ? max(0, Int(k.rounded(.towardZero))) : 0
                return .unknownKind(UInt32(raw))
            }
            if k == KIND_LAYER && inst.params.z != 0.0 {
                return .filteredLayer
            }
            if k == KIND_LAYER && inst.border.y != 0.0 {
                return .rotatedLayer
            }
            if k == KIND_LAYER {
                layerDepth += 1
                continue
            }
            if k == KIND_LAYER_END {
                layerDepth = max(0, layerDepth - 1)
                continue
            }
            if k == KIND_BACKDROP_BLUR && layerDepth > 0 {
                return .backdropInLayer
            }
            if k == KIND_EFFECT && compositor {
                return .effect
            }
            if k == KIND_GLYPH && inst.radii.w > 0.0 && (outlines == nil || inst.border.w == 1.0) {
                return .outlineGlyph
            }
        }
        return nil
    }
}

/// Incremental damage paint summary (`cpu_boot::Painted`).
public struct CpuBootPainted: Sendable, Equatable {
    public var dirtyTiles: Int
    public var tiles: Int
    public var rects: [[UInt32]]
    public var scrolled: (Int32, Int)?
    public var hashNs: UInt64
    public var planNs: UInt64
    public var moveNs: UInt64
    public var report: CpuBootReport

    public static func == (lhs: CpuBootPainted, rhs: CpuBootPainted) -> Bool {
        lhs.dirtyTiles == rhs.dirtyTiles
            && lhs.tiles == rhs.tiles
            && lhs.rects == rhs.rects
            && lhs.scrolled?.0 == rhs.scrolled?.0
            && lhs.scrolled?.1 == rhs.scrolled?.1
            && lhs.hashNs == rhs.hashNs
            && lhs.planNs == rhs.planNs
            && lhs.moveNs == rhs.moveNs
            && lhs.report == rhs.report
    }
}

// MARK: - Drift Comparison (`cpu_boot::drift`)

public enum CpuBootPixelFormat: Sendable, Equatable {
    case bgra
    case rgba
}

public struct CpuBootPixels: Sendable {
    public let bytes: [UInt8]
    public let width: Int
    public let height: Int
    public let stride: Int
    public let format: CpuBootPixelFormat

    public static func bgra(_ bytes: [UInt8], width: Int, height: Int, stride: Int? = nil) -> CpuBootPixels {
        CpuBootPixels(bytes: bytes, width: width, height: height, stride: stride ?? width * 4, format: .bgra)
    }

    public static func rgba(_ bytes: [UInt8], width: Int, height: Int, stride: Int? = nil) -> CpuBootPixels {
        CpuBootPixels(bytes: bytes, width: width, height: height, stride: stride ?? width * 4, format: .rgba)
    }
}

public struct CpuBootDrift: Sendable, Equatable {
    public var pixels: Int
    public var differ: Int
    public var overTwo: Int
    public var max: UInt8

    public init(pixels: Int = 0, differ: Int = 0, overTwo: Int = 0, max: UInt8 = 0) {
        self.pixels = pixels
        self.differ = differ
        self.overTwo = overTwo
        self.max = max
    }
}

public enum CpuBootDriftMeter {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var last: CpuBootDrift?
    }

    private static let state = State()

    public static func driftWanted() -> Int? {
        guard let raw = ProcessInfo.processInfo.environment["RUNE_CPU_BOOT_DRIFT"] else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    public static func lastDrift() -> CpuBootDrift? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.last
    }

    public static func record(_ d: CpuBootDrift) {
        state.lock.lock()
        state.last = d
        state.lock.unlock()
    }

    /// Computes per-channel RGBA channel max-diff statistics between two pixel buffers (`cpu_boot::drift`).
    public static func drift(_ a: CpuBootPixels, _ b: CpuBootPixels) -> CpuBootDrift {
        let w = min(a.width, b.width)
        let h = min(a.height, b.height)
        var differ = 0
        var overTwo = 0
        var worst: UInt8 = 0

        for y in 0..<h {
            let ra = y * a.stride
            let rb = y * b.stride
            for x in 0..<w {
                let pa = ra + x * 4
                let pb = rb + x * 4
                let aR = a.format == .bgra ? a.bytes[pa + 2] : a.bytes[pa + 0]
                let aG = a.bytes[pa + 1]
                let aB = a.format == .bgra ? a.bytes[pa + 0] : a.bytes[pa + 2]
                let aA = a.bytes[pa + 3]

                let bR = b.format == .bgra ? b.bytes[pb + 2] : b.bytes[pb + 0]
                let bG = b.bytes[pb + 1]
                let bB = b.format == .bgra ? b.bytes[pb + 0] : b.bytes[pb + 2]
                let bA = b.bytes[pb + 3]

                let d = Swift.max(
                    Swift.max(aR >= bR ? aR - bR : bR - aR, aG >= bG ? aG - bG : bG - aG),
                    Swift.max(aB >= bB ? aB - bB : bB - aB, aA >= bA ? aA - bA : bA - aA)
                )
                if d > 0 { differ += 1 }
                if d > 2 { overTwo += 1 }
                if d > worst { worst = d }
            }
        }
        let result = CpuBootDrift(pixels: w * h, differ: differ, overTwo: overTwo, max: worst)
        record(result)
        return result
    }
}
