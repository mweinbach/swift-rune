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
/// Converts straight RGBA8 to linear-light premultiplied RGBA8 without intermediate `[Float]` image buffers,
/// downsamples odd and even edges with exact area overlap, and caps encoded RGB to quantized alpha.
public final class MipStepper {
    public private(set) var levelIndex: Int = 0
    public private(set) var currentWidth: UInt32
    public private(set) var currentHeight: UInt32
    public private(set) var mips: [ImageMipLevel]

    private let source: Data
    private var nextBytes: [UInt8] = []
    private var nextRow: Int = 0
    private var emittedCount: Int = 0

    public init?(width: UInt32, height: UInt32, straightRGBA: Data) {
        guard width > 0, height > 0,
              Int(width) <= LinearMipGenerator.maxDecodeDimension,
              Int(height) <= LinearMipGenerator.maxDecodeDimension else {
            return nil
        }
        let pixelCount = Int(width) * Int(height)
        guard straightRGBA.count == pixelCount * 4 else { return nil }

        self.currentWidth = width
        self.currentHeight = height
        self.source = straightRGBA

        // Mip 0: source with RGB premultiplied in linear light; opaque pixels pass through unchanged.
        var top = [UInt8](straightRGBA)
        top.withUnsafeMutableBufferPointer { buf in
            var i = 0
            while i < buf.count {
                let aByte = buf[i + 3]
                if aByte == 255 {
                    i += 4
                    continue
                }
                if aByte == 0 {
                    buf[i] = 0
                    buf[i + 1] = 0
                    buf[i + 2] = 0
                    i += 4
                    continue
                }
                let a = Float(aByte) / 255.0
                buf[i] = LinearMipGenerator.encodePremulLinearToSRGB(LinearMipGenerator.srgbToLinear(buf[i]) * a, alphaByte: aByte)
                buf[i + 1] = LinearMipGenerator.encodePremulLinearToSRGB(LinearMipGenerator.srgbToLinear(buf[i + 1]) * a, alphaByte: aByte)
                buf[i + 2] = LinearMipGenerator.encodePremulLinearToSRGB(LinearMipGenerator.srgbToLinear(buf[i + 2]) * a, alphaByte: aByte)
                i += 4
            }
        }
        self.mips = [ImageMipLevel(width: width, height: height, rgba: Data(top))]
    }

    /// Generates up to about `budgetPixels` more target pixels (at least one whole row per call);
    /// returns `true` once the chain has reached `1x1` (`MipSteps::step`).
    @discardableResult
    public func step(budgetPixels: Int) -> Bool {
        var remaining = budgetPixels
        while true {
            guard let last = mips.last else { return true }
            let w = Int(last.width)
            let h = Int(last.height)
            if w == 1 && h == 1 { return true }
            if remaining <= 0 { return false }

            let nw = max(1, w / 2)
            let nh = max(1, h / 2)
            if nextRow == 0 {
                nextBytes.removeAll(keepingCapacity: true)
                nextBytes.reserveCapacity(nw * nh * 4)
            }
            let rowsLeft = nh - nextRow
            let rows = max(1, min(rowsLeft, remaining / nw))
            let rowRange = nextRow..<(nextRow + rows)

            if mips.count == 1 {
                source.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: UInt8.self)
                    LinearMipGenerator.downsampleRows(
                        w: w,
                        h: h,
                        src: src,
                        rows: rowRange,
                        straightAlphaSource: true,
                        out: &nextBytes
                    )
                }
            } else {
                last.rgba.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: UInt8.self)
                    LinearMipGenerator.downsampleRows(
                        w: w,
                        h: h,
                        src: src,
                        rows: rowRange,
                        straightAlphaSource: false,
                        out: &nextBytes
                    )
                }
            }

            nextRow += rows
            remaining = remaining > rows * nw ? (remaining - rows * nw) : 0
            if nextRow == nh {
                let completed = Data(nextBytes)
                nextBytes.removeAll(keepingCapacity: true)
                mips.append(ImageMipLevel(width: UInt32(nw), height: UInt32(nh), rgba: completed))
                currentWidth = UInt32(nw)
                currentHeight = UInt32(nh)
                nextRow = 0
                levelIndex = mips.count
            }
        }
    }

    /// Generates and returns the next mip level (`nil` once `1x1` has already been emitted).
    public func nextStep() -> ImageMipLevel? {
        if emittedCount == 0 {
            emittedCount = 1
            levelIndex = 1
            return mips[0]
        }
        guard emittedCount < mips.count || !(mips.last?.width == 1 && mips.last?.height == 1) else {
            return nil
        }
        while emittedCount >= mips.count {
            let last = mips.last!
            let nw = max(1, Int(last.width) / 2)
            let nh = max(1, Int(last.height) / 2)
            _ = step(budgetPixels: nw * nh)
        }
        let level = mips[emittedCount]
        emittedCount += 1
        return level
    }
}

/// Linear-light premultiplied mipmap chain generator and decode bounds (`crates/rune/src/image/mips.rs`).
public enum LinearMipGenerator: Sendable {
    /// Maximum single dimension allowed during image decode (matching upstream 8192px cap).
    public static let maxDecodeDimension: Int = 8192
    /// Maximum RGBA8 pixel buffer allocation during image decode (256 MiB cap).
    public static let maxDecodedBytes: Int = 256 * 1024 * 1024

    @usableFromInline
    internal static let encodingSteps: Int = 4096

    @usableFromInline
    internal static let srgbToLinearTable: [Float] = {
        var table = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            table[i] = srgbDecodeExact(Double(i) / 255.0)
        }
        return table
    }()

    /// `upThresholds[k]`: linear threshold at and above which sRGB rounds past byte `k`.
    @usableFromInline
    internal static let upThresholds: [Float] = {
        var up = [Float](repeating: 0, count: 256)
        for k in 0..<255 {
            up[k] = srgbDecodeExact((Double(k) + 0.5) / 255.0)
        }
        up[255] = .infinity
        return up
    }()

    /// Coarse byte index for `v * 4096` so one `upThresholds` comparison finishes exact rounding.
    @usableFromInline
    internal static let coarseByteTable: [UInt8] = {
        let up = upThresholds
        var coarse = [UInt8](repeating: 0, count: encodingSteps + 1)
        for i in 0...encodingSteps {
            let t = Float(i) / Float(encodingSteps)
            var idx = 0
            while idx < 256 && up[idx] <= t {
                idx += 1
            }
            coarse[i] = UInt8(min(255, idx))
        }
        return coarse
    }()

    private static func srgbDecodeExact(_ c: Double) -> Float {
        let clamped = max(0.0, c)
        let lin = clamped <= 0.04045 ? (clamped / 12.92) : pow((clamped + 0.055) / 1.055, 2.4)
        return Float(lin)
    }

    @inlinable
    public static func srgbToLinear(_ byte: UInt8) -> Float {
        srgbToLinearTable[Int(byte)]
    }

    /// Encodes premultiplied linear `linear` capped to quantized `alphaByte` so clear pixels emit zero RGB (`mips.rs:139`).
    @inlinable
    public static func encodePremulLinearToSRGB(_ linear: Float, alphaByte: UInt8) -> UInt8 {
        if !linear.isFinite || linear <= 0 || alphaByte == 0 { return 0 }
        let maxVal = Float(alphaByte) / 255.0
        let v = min(linear, maxVal)
        let b = Int(coarseByteTable[min(encodingSteps, Int(v * Float(encodingSteps)))])
        return UInt8(b) &+ (v >= upThresholds[b] ? 1 : 0)
    }

    @inlinable
    public static func linearToSrgb(_ linear: Float) -> UInt8 {
        encodePremulLinearToSRGB(linear, alphaByte: 255)
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
        _ = stepper.step(budgetPixels: Int.max)
        return stepper.mips
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

    @inline(__always)
    private static func quantizeByte(_ v: Float) -> UInt8 {
        let clamped = max(Float(0), min(Float(1), v))
        return UInt8((clamped * 255.0).rounded())
    }

    fileprivate static func downsampleRows(
        w: Int,
        h: Int,
        src: UnsafeBufferPointer<UInt8>,
        rows: Range<Int>,
        straightAlphaSource: Bool,
        out: inout [UInt8]
    ) {
        let nw = max(1, w / 2)
        let nh = max(1, h / 2)
        let decode = srgbToLinearTable

        @inline(__always)
        func emit(r: Float, g: Float, b: Float, a: Float, area: Float) {
            let inv = 1.0 / area
            let aByte = quantizeByte(a * inv)
            out.append(encodePremulLinearToSRGB(r * inv, alphaByte: aByte))
            out.append(encodePremulLinearToSRGB(g * inv, alphaByte: aByte))
            out.append(encodePremulLinearToSRGB(b * inv, alphaByte: aByte))
            out.append(aByte)
        }

        if (w & 1) == 0 && (h & 1) == 0 {
            for y in rows {
                let row0 = 2 * y * w
                let row1 = row0 + w
                for x in 0..<nw {
                    let i0 = (row0 + 2 * x) * 4
                    let i1 = i0 + 4
                    let i2 = (row1 + 2 * x) * 4
                    let i3 = i2 + 4

                    var sumR: Float = 0
                    var sumG: Float = 0
                    var sumB: Float = 0
                    var sumA: Float = 0

                    if straightAlphaSource {
                        for off in [i0, i1, i2, i3] {
                            let a = Float(src[off + 3]) / 255.0
                            sumR += decode[Int(src[off])] * a
                            sumG += decode[Int(src[off + 1])] * a
                            sumB += decode[Int(src[off + 2])] * a
                            sumA += a
                        }
                    } else {
                        for off in [i0, i1, i2, i3] {
                            sumR += decode[Int(src[off])]
                            sumG += decode[Int(src[off + 1])]
                            sumB += decode[Int(src[off + 2])]
                            sumA += Float(src[off + 3]) / 255.0
                        }
                    }
                    emit(r: sumR, g: sumG, b: sumB, a: sumA, area: 4.0)
                }
            }
            return
        }

        let wf = Float(w)
        let hf = Float(h)
        let nwf = Float(nw)
        let nhf = Float(nh)
        for y in rows {
            let y0 = Float(y) * hf / nhf
            let y1 = Float(y + 1) * hf / nhf
            let syStart = Int(floorf(y0))
            let syEnd = min(h, Int(ceilf(y1)))
            for x in 0..<nw {
                let x0 = Float(x) * wf / nwf
                let x1 = Float(x + 1) * wf / nwf
                let sxStart = Int(floorf(x0))
                let sxEnd = min(w, Int(ceilf(x1)))

                var sumR: Float = 0
                var sumG: Float = 0
                var sumB: Float = 0
                var sumA: Float = 0

                for sy in syStart..<syEnd {
                    let wy = min(Float(sy + 1), y1) - max(Float(sy), y0)
                    let rowOff = sy * w
                    for sx in sxStart..<sxEnd {
                        let wx = min(Float(sx + 1), x1) - max(Float(sx), x0)
                        let weight = wx * wy
                        let off = (rowOff + sx) * 4
                        let a = Float(src[off + 3]) / 255.0
                        if straightAlphaSource {
                            let wa = a * weight
                            sumR += decode[Int(src[off])] * wa
                            sumG += decode[Int(src[off + 1])] * wa
                            sumB += decode[Int(src[off + 2])] * wa
                            sumA += wa
                        } else {
                            sumR += decode[Int(src[off])] * weight
                            sumG += decode[Int(src[off + 1])] * weight
                            sumB += decode[Int(src[off + 2])] * weight
                            sumA += a * weight
                        }
                    }
                }
                emit(r: sumR, g: sumG, b: sumB, a: sumA, area: (x1 - x0) * (y1 - y0))
            }
        }
    }
}
