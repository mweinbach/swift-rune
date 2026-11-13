import Foundation

/// A single generated mipmap step metadata (`crates/rune/src/image/mips.rs`).
public struct MipStep: Sendable, Equatable {
    public let level: Int
    public let width: UInt32
    public let height: UInt32
    public let pixelOffset: Int
    public let byteCount: Int

    public init(level: Int, width: UInt32, height: UInt32, pixelOffset: Int, byteCount: Int) {
        self.level = level
        self.width = width
        self.height = height
        self.pixelOffset = pixelOffset
        self.byteCount = byteCount
    }
}

/// Complete mip chain along with contiguous packed byte offsets per level.
public struct MipChainResult: Sendable, Equatable {
    public let levels: [ImageMipLevel]
    public let steps: [MipStep]
    public let packedRGBA: Data

    public init(levels: [ImageMipLevel], steps: [MipStep], packedRGBA: Data) {
        self.levels = levels
        self.steps = steps
        self.packedRGBA = packedRGBA
    }
}

/// Incremental linear-light mipmap generator (`crates/rune/src/image/mips.rs`, `MipSteps`).
/// Converts straight RGBA8 to linear-light premultiplied RGBA, downsamples odd and even edges
/// with exact area overlap, and encodes each level via a 4096-entry linear-to-sRGB LUT.
public final class MipStepper {
    public private(set) var levelIndex: Int = 0
    public private(set) var currentWidth: UInt32
    public private(set) var currentHeight: UInt32
    private var linearPremul: [Float]
    private var rawBaseRGBA: Data?

    public init?(width: UInt32, height: UInt32, straightRGBA: Data) {
        guard width > 0, height > 0 else { return nil }
        let pixelCount = Int(width) * Int(height)
        guard straightRGBA.count == pixelCount * 4 else { return nil }
        self.currentWidth = width
        self.currentHeight = height
        self.rawBaseRGBA = straightRGBA

        var linear = [Float](repeating: 0, count: pixelCount * 4)
        straightRGBA.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<pixelCount {
                let off = i * 4
                let a = Float(bytes[off + 3]) / 255.0
                linear[off] = LinearMipGenerator.srgbToLinear(bytes[off]) * a
                linear[off + 1] = LinearMipGenerator.srgbToLinear(bytes[off + 1]) * a
                linear[off + 2] = LinearMipGenerator.srgbToLinear(bytes[off + 2]) * a
                linear[off + 3] = a
            }
        }
        self.linearPremul = linear
    }

    /// Generates the next mip level (`nil` once `1x1` has already been emitted).
    public func nextStep() -> ImageMipLevel? {
        if levelIndex == 0 {
            levelIndex = 1
            let out = LinearMipGenerator.encodeLinearPremulToSRGB(
                linearPremul,
                width: currentWidth,
                height: currentHeight,
                rawBaseAlpha: rawBaseRGBA
            )
            rawBaseRGBA = nil
            return ImageMipLevel(width: currentWidth, height: currentHeight, rgba: out)
        }

        if currentWidth == 1 && currentHeight == 1 {
            return nil
        }

        let nextW = max(UInt32(1), currentWidth / 2)
        let nextH = max(UInt32(1), currentHeight / 2)
        let downsampled = LinearMipGenerator.downsampleLinearPremul(
            src: linearPremul,
            srcW: Int(currentWidth),
            srcH: Int(currentHeight),
            dstW: Int(nextW),
            dstH: Int(nextH)
        )
        linearPremul = downsampled
        currentWidth = nextW
        currentHeight = nextH
        levelIndex += 1

        let out = LinearMipGenerator.encodeLinearPremulToSRGB(
            linearPremul,
            width: nextW,
            height: nextH,
            rawBaseAlpha: nil
        )
        return ImageMipLevel(width: nextW, height: nextH, rgba: out)
    }
}

/// Linear-light premultiplied mipmap chain generator and decode bounds (`crates/rune/src/image/mips.rs`).
public enum LinearMipGenerator: Sendable {
    /// Maximum single dimension allowed during image decode (matching upstream 8192px cap).
    public static let maxDecodeDimension: Int = 8192
    /// Maximum RGBA8 pixel buffer allocation during image decode (256 MiB cap).
    public static let maxDecodedBytes: Int = 256 * 1024 * 1024

    @usableFromInline
    internal static let srgbToLinearTable: [Float] = {
        var table = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            let c = Double(i) / 255.0
            let lin = c <= 0.04045 ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4)
            table[i] = Float(lin)
        }
        return table
    }()

    @usableFromInline
    internal static let linearToSrgbTable: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 4096)
        for i in 0..<4096 {
            let lin = Double(i) / 4095.0
            let srgb = lin <= 0.0031308 ? (lin * 12.92) : (1.055 * pow(lin, 1.0 / 2.4) - 0.055)
            let q = Int((srgb * 255.0).rounded())
            table[i] = UInt8(max(0, min(255, q)))
        }
        return table
    }()

    @inlinable
    public static func srgbToLinear(_ byte: UInt8) -> Float {
        srgbToLinearTable[Int(byte)]
    }

    @inlinable
    public static func linearToSrgb(_ linear: Float) -> UInt8 {
        if !linear.isFinite || linear <= 0 { return 0 }
        if linear >= 1 { return 255 }
        let idx = Int((linear * 4095.0).rounded())
        return linearToSrgbTable[max(0, min(4095, idx))]
    }

    /// Generates all mip levels from `width`x`height` down to `1x1` in linear-light premultiplied space.
    public static func generateChain(
        width: UInt32,
        height: UInt32,
        straightRGBA: Data
    ) -> [ImageMipLevel] {
        guard let stepper = MipStepper(width: width, height: height, straightRGBA: straightRGBA) else {
            return []
        }
        var levels: [ImageMipLevel] = []
        while let level = stepper.nextStep() {
            levels.append(level)
        }
        return levels
    }

    /// Generates a full mip chain along with contiguous packed byte offsets (`MipSteps` layout).
    public static func generateSlicedChain(
        width: UInt32,
        height: UInt32,
        straightRGBA: Data
    ) -> MipChainResult {
        let levels = generateChain(width: width, height: height, straightRGBA: straightRGBA)
        var packed = Data()
        var totalBytes = 0
        for level in levels {
            totalBytes += level.rgba.count
        }
        packed.reserveCapacity(totalBytes)
        var steps: [MipStep] = []
        steps.reserveCapacity(levels.count)
        for (idx, level) in levels.enumerated() {
            let offset = packed.count
            packed.append(level.rgba)
            steps.append(MipStep(
                level: idx,
                width: level.width,
                height: level.height,
                pixelOffset: offset,
                byteCount: level.rgba.count
            ))
        }
        return MipChainResult(levels: levels, steps: steps, packedRGBA: packed)
    }

    fileprivate static func encodeLinearPremulToSRGB(
        _ linear: [Float],
        width: UInt32,
        height: UInt32,
        rawBaseAlpha: Data?
    ) -> Data {
        let count = Int(width) * Int(height)
        var out = Data(count: count * 4)
        out.withUnsafeMutableBytes { outRaw in
            let dst = outRaw.bindMemory(to: UInt8.self)
            if let rawBaseAlpha {
                rawBaseAlpha.withUnsafeBytes { alphaRaw in
                    let src = alphaRaw.bindMemory(to: UInt8.self)
                    for i in 0..<count {
                        let off = i * 4
                        dst[off] = linearToSrgb(linear[off])
                        dst[off + 1] = linearToSrgb(linear[off + 1])
                        dst[off + 2] = linearToSrgb(linear[off + 2])
                        dst[off + 3] = src[off + 3]
                    }
                }
            } else {
                for i in 0..<count {
                    let off = i * 4
                    dst[off] = linearToSrgb(linear[off])
                    dst[off + 1] = linearToSrgb(linear[off + 1])
                    dst[off + 2] = linearToSrgb(linear[off + 2])
                    let a = Int((max(0, min(1, linear[off + 3])) * 255.0).rounded())
                    dst[off + 3] = UInt8(max(0, min(255, a)))
                }
            }
        }
        return out
    }

    fileprivate static func downsampleLinearPremul(
        src: [Float],
        srcW: Int,
        srcH: Int,
        dstW: Int,
        dstH: Int
    ) -> [Float] {
        var dst = [Float](repeating: 0, count: dstW * dstH * 4)

        // Exact fractional area spans [dx * srcDim / dstDim, (dx + 1) * srcDim / dstDim]
        let xSpans = axisSpans(srcDim: srcW, dstDim: dstW)
        let ySpans = axisSpans(srcDim: srcH, dstDim: dstH)

        for dy in 0..<dstH {
            let ys = ySpans[dy]
            for dx in 0..<dstW {
                let xs = xSpans[dx]
                var accR: Float = 0
                var accG: Float = 0
                var accB: Float = 0
                var accA: Float = 0

                for (sy, wy) in ys {
                    let rowBase = sy * srcW
                    for (sx, wx) in xs {
                        let w = wx * wy
                        let off = (rowBase + sx) * 4
                        accR += src[off] * w
                        accG += src[off + 1] * w
                        accB += src[off + 2] * w
                        accA += src[off + 3] * w
                    }
                }

                let dstOff = (dy * dstW + dx) * 4
                dst[dstOff] = accR
                dst[dstOff + 1] = accG
                dst[dstOff + 2] = accB
                dst[dstOff + 3] = accA
            }
        }

        return dst
    }

    private static func axisSpans(srcDim: Int, dstDim: Int) -> [[(Int, Float)]] {
        let total = Float(srcDim)
        var result: [[(Int, Float)]] = []
        result.reserveCapacity(dstDim)
        for d in 0..<dstDim {
            let start = d * srcDim
            let end = (d + 1) * srcDim
            let sxMin = start / dstDim
            let sxMax = (end + dstDim - 1) / dstDim
            var taps: [(Int, Float)] = []
            taps.reserveCapacity(max(1, sxMax - sxMin))
            for s in sxMin..<min(srcDim, sxMax) {
                let overlap = min((s + 1) * dstDim, end) - max(s * dstDim, start)
                if overlap > 0 {
                    taps.append((s, Float(overlap) / total))
                }
            }
            result.append(taps)
        }
        return result
    }
}
