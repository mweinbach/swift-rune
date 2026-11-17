import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

extension Data.WritingOptions {
    /// WASI Preview 1 has no temporary directory for Foundation's atomic replacement.
    package static var runeOutput: Self {
        #if os(WASI)
        []
        #else
        .atomic
        #endif
    }
}

/// Rendered RGBA8 image produced by `RuneRef` or read back from `MetalRenderer`.
public struct Frame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Row-major top-to-bottom sRGB8 straight/premultiplied output bytes (`width * height * 4`).
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    @inlinable
    public func pixel(x: Int, y: Int) -> SIMD4<UInt8> {
        let idx = (y * width + x) * 4
        return SIMD4<UInt8>(rgba[idx], rgba[idx + 1], rgba[idx + 2], rgba[idx + 3])
    }

    /// Encodes the frame as PNG data using CoreGraphics / ImageIO on Apple platforms,
    /// or `PortablePNG` on non-Apple platforms.
    public func pngData() throws -> Data {
        #if canImport(CoreGraphics) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw CocoaError(.coderInvalidValue)
        }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.coderInvalidValue)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.coderInvalidValue)
        }
        return mutableData as Data
        #else
        return try PortablePNG.encode(width: width, height: height, rgba: rgba)
        #endif
    }

    public func writePNG(to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let bytes = try pngData()
        try bytes.write(to: url, options: .runeOutput)
    }

    public static func fromPNG(data: Data) throws -> Frame {
        #if canImport(CoreGraphics) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let w = cgImage.width
        let h = cgImage.height
        var rgba = Array<UInt8>(repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext only supports premultiplied alpha; unpremultiply to match Frame's straight RGBA8 format.
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let a = rgba[i + 3]
            if a > 0 && a < 255 {
                let scale = 255.0 / Float(a)
                rgba[i] = UInt8(min(255, Int((Float(rgba[i]) * scale).rounded())))
                rgba[i + 1] = UInt8(min(255, Int((Float(rgba[i + 1]) * scale).rounded())))
                rgba[i + 2] = UInt8(min(255, Int((Float(rgba[i + 2]) * scale).rounded())))
            }
        }
        return Frame(width: w, height: h, rgba: rgba)
        #else
        let decoded = try PortablePNG.decode(data)
        return Frame(width: decoded.width, height: decoded.height, rgba: decoded.rgba)
        #endif
    }

    /// Deterministic 64-bit FNV-1a hex digest of `rgba` for legacy Swift tests.
    public func fnv1aHash() -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in rgba {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16, uppercase: false)
        return hex.count >= 16 ? hex : String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// Deterministic BLAKE3 hex digest of `rgba` matching upstream `rune-ref`.
    public func blake3Hash() -> String {
        Blake3.hashHex(rgba)
    }

    /// Canonical frame hash (BLAKE3).
    public func hash() -> String {
        blake3Hash()
    }
}

/// Blame record attributing a differing pixel to the topmost primitive covering `(x, y)`.
public struct PixelBlame: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var expected: SIMD4<UInt8>
    public var actual: SIMD4<UInt8>
    public var maxChannelDelta: Int
    public var primitiveIndex: Int?
    public var primitiveKind: PrimitiveKind?
}

/// Differential report between two rendered `Frame`s (e.g. CPU `RuneRef` vs GPU `MetalRenderer`).
public struct Difference: Sendable, Equatable {
    public var differingPixels: Int
    public var maxChannelDelta: Int
    public var worstBlame: PixelBlame?
    public var passed: Bool
}

/// A captured surface in display-list order. Its sampler takes a scene-space pixel
/// center and returns premultiplied RGBA in the scene's blending color space.
public struct RefSurfaceDraw: Sendable {
    public let beforeInstance: UInt32
    public let rect: SIMD4<Float>
    public let shade: @Sendable (SIMD2<Float>) -> SIMD4<Float>

    public init(beforeInstance: UInt32, rect: SIMD4<Float>,
                shade: @escaping @Sendable (SIMD2<Float>) -> SIMD4<Float>) {
        self.beforeInstance = beforeInstance
        self.rect = rect
        self.shade = shade
    }
}

/// Deterministic CPU reference renderer for `RefScene`.
public enum RuneRef {
    private struct LayerTarget {
        var rect: SIMD4<Float>
        var radii: SIMD4<Float>
        var clip: SIMD4<Float>
        var fade: SIMD4<Float>
        var fadeOrigin: SIMD2<Float>
        var opacity: Float
        var additive: Bool
        var blurRadius: Float
        var turn: Float
        var buffer: [SIMD4<Float>]
    }

    /// Renders `scene` deterministically on the CPU into an sRGB8 `Frame`.
    public static func render(_ scene: RefScene) throws(RefSceneError) -> Frame {
        try render(scene, surfaces: [])
    }

    /// Draws captured surfaces at their insertion indices in the active layer.
    public static func render(_ scene: RefScene, surfaces: [RefSurfaceDraw]) throws(RefSceneError) -> Frame {
        try scene.validate()
        let w = scene.width
        let h = scene.height
        let pixelCount = w * h

        let clearA = RefShader.clamp01(scene.clearColor.w)
        let clearPremul = SIMD4<Float>(
            scene.clearColor.x * clearA,
            scene.clearColor.y * clearA,
            scene.clearColor.z * clearA,
            clearA
        )
        var rootBuffer = Array(repeating: clearPremul, count: pixelCount)
        var layerStack: [LayerTarget] = []

        @inline(__always)
        func compositeOver(_ dst: SIMD4<Float>, _ src: SIMD4<Float>, additive: Bool = false) -> SIMD4<Float> {
            if src.w <= 0 && !additive { return dst }
            if additive {
                return SIMD4<Float>(
                    min(1.0, dst.x + src.x),
                    min(1.0, dst.y + src.y),
                    min(1.0, dst.z + src.z),
                    min(1.0, dst.w + src.w)
                )
            }
            let invSa = 1.0 - src.w
            return src + dst * invSa
        }

        let orderedSurfaces = surfaces.sorted { $0.beforeInstance < $1.beforeInstance }
        var nextSurface = 0
        func drawSurfaces(before index: UInt32) {
            while nextSurface < orderedSurfaces.count && orderedSurfaces[nextSurface].beforeInstance <= index {
                let draw = orderedSurfaces[nextSurface]
                nextSurface += 1
                let r = draw.rect
                guard r.x.isFinite, r.y.isFinite, r.z.isFinite, r.w.isFinite,
                      r.z > 0, r.w > 0 else { continue }
                // Match the half-open coverage of the GPU quad at pixel centers.
                func bound(_ edge: Float, _ limit: Int) -> Int {
                    Int(min(Float(limit), max(0, ceilf(edge - 0.5))))
                }
                let xs = bound(r.x, w)..<bound(r.x + r.z, w)
                let ys = bound(r.y, h)..<bound(r.y + r.w, h)
                for y in ys {
                    for x in xs {
                        let src = draw.shade(SIMD2(Float(x) + 0.5, Float(y) + 0.5))
                        if src.w <= 0 { continue }
                        let i = y * w + x
                        if layerStack.isEmpty {
                            rootBuffer[i] = compositeOver(rootBuffer[i], src)
                        } else {
                            let top = layerStack.count - 1
                            layerStack[top].buffer[i] = compositeOver(layerStack[top].buffer[i], src)
                        }
                    }
                }
            }
        }

        for (index, prim) in scene.primitives.enumerated() {
            if nextSurface < orderedSurfaces.count { drawSurfaces(before: UInt32(index)) }
            switch prim.kind {
            case .layerBegin:
                layerStack.append(
                    LayerTarget(
                        rect: prim.rect,
                        radii: prim.radii,
                        clip: prim.clip,
                        fade: prim.fade,
                        fadeOrigin: prim.fadeOrigin,
                        opacity: RefShader.clamp01(prim.params.x),
                        additive: prim.params.z >= 0.5,
                        blurRadius: max(0, prim.params.w),
                        turn: prim.turn,
                        buffer: Array(repeating: .zero, count: pixelCount)
                    )
                )

            case .layerEnd:
                guard var finished = layerStack.popLast() else { continue }
                if finished.blurRadius >= 0.5 {
                    finished.buffer = boxBlur(finished.buffer, width: w, height: h, radius: finished.blurRadius, bounds: finished.rect)
                }
                let center = SIMD2<Float>(finished.rect.x + finished.rect.z * 0.5, finished.rect.y + finished.rect.w * 0.5)
                let blurPad = finished.blurRadius >= 0.5 ? min(24.0, finished.blurRadius.rounded()) : 0.0
                let layerMinX: Float
                let layerMinY: Float
                let layerMaxX: Float
                let layerMaxY: Float
                if finished.turn != 0 {
                    let cs = abs(cosf(finished.turn))
                    let sn = abs(sinf(finished.turn))
                    let hw = (finished.rect.z * 0.5 + blurPad) * cs + (finished.rect.w * 0.5 + blurPad) * sn
                    let hh = (finished.rect.z * 0.5 + blurPad) * sn + (finished.rect.w * 0.5 + blurPad) * cs
                    layerMinX = min(center.x - hw, finished.clip.x)
                    layerMinY = min(center.y - hh, finished.clip.y)
                    layerMaxX = max(center.x + hw, finished.clip.x + finished.clip.z)
                    layerMaxY = max(center.y + hh, finished.clip.y + finished.clip.w)
                } else {
                    layerMinX = min(finished.rect.x - blurPad, finished.clip.x)
                    layerMinY = min(finished.rect.y - blurPad, finished.clip.y)
                    layerMaxX = max(finished.rect.x + finished.rect.z + blurPad, finished.clip.x + finished.clip.z)
                    layerMaxY = max(finished.rect.y + finished.rect.w + blurPad, finished.clip.y + finished.clip.w)
                }
                let minX = max(0, Int(floorf(layerMinX - 2)))
                let minY = max(0, Int(floorf(layerMinY - 2)))
                let maxX = min(w - 1, Int(ceilf(layerMaxX + 2)))
                let maxY = min(h - 1, Int(ceilf(layerMaxY + 2)))
                if minX <= maxX && minY <= maxY {
                    for py in minY...maxY {
                        for px in minX...maxX {
                            let frag = SIMD2<Float>(Float(px) + 0.5, Float(py) + 0.5)
                            var clipCov = RefShader.clipCoverage(pixelCenter: frag, clip: finished.clip)
                            if clipCov <= 0 { continue }
                            if finished.radii.x > 0 || finished.radii.y > 0 || finished.radii.z > 0 || finished.radii.w > 0 {
                                var relClip = frag - center
                                if finished.turn != 0 {
                                    let cs = cosf(-finished.turn)
                                    let sn = sinf(-finished.turn)
                                    relClip = SIMD2<Float>(relClip.x * cs - relClip.y * sn, relClip.x * sn + relClip.y * cs)
                                }
                                let halfClip = SIMD2<Float>(finished.rect.z * 0.5, finished.rect.w * 0.5)
                                let sdClip = RefShader.sdBox(relClip, halfSize: halfClip, radii: finished.radii)
                                clipCov *= RefShader.boxCoverage(sdClip)
                                if clipCov <= 0 { continue }
                            }
                            if finished.fade.z != 0 {
                                let d = ((frag.x - finished.fadeOrigin.x) * finished.fade.x + (frag.y - finished.fadeOrigin.y) * finished.fade.y) * finished.fade.z
                                clipCov *= finished.fade.w + (1.0 - finished.fade.w) * RefShader.clamp01(d)
                                if clipCov <= 0 { continue }
                            }
                            let srcSample: SIMD4<Float>
                            if finished.turn != 0 {
                                let rel = frag - center
                                let cs = cosf(-finished.turn)
                                let sn = sinf(-finished.turn)
                                let srcPos = center + SIMD2<Float>(rel.x * cs - rel.y * sn, rel.x * sn + rel.y * cs)
                                srcSample = sampleLayerBilinear(finished.buffer, width: w, height: h, at: srcPos)
                            } else {
                                srcSample = finished.buffer[py * w + px]
                            }
                            let scaled = srcSample * (finished.opacity * clipCov)
                            if scaled.w <= 0 && scaled.x <= 0 && scaled.y <= 0 && scaled.z <= 0 { continue }
                            let dstIdx = py * w + px
                            if layerStack.isEmpty {
                                rootBuffer[dstIdx] = compositeOver(rootBuffer[dstIdx], scaled, additive: finished.additive)
                            } else {
                                let top = layerStack.count - 1
                                layerStack[top].buffer[dstIdx] = compositeOver(layerStack[top].buffer[dstIdx], scaled, additive: finished.additive)
                            }
                        }
                    }
                }

            case .backdropBlur:
                let radius = max(0, prim.params.x)
                if radius >= 0.5 {
                    if layerStack.isEmpty {
                        let blurred = boxBlur(rootBuffer, width: w, height: h, radius: radius, bounds: prim.rect)
                        compositeBackdropBlur(&rootBuffer, blurred: blurred, prim: prim, width: w, height: h)
                    } else {
                        let top = layerStack.count - 1
                        let blurred = boxBlur(layerStack[top].buffer, width: w, height: h, radius: radius, bounds: prim.rect)
                        compositeBackdropBlur(&layerStack[top].buffer, blurred: blurred, prim: prim, width: w, height: h)
                    }
                }

            case .effectSlot:
                continue

            default:
                // Compute conservative bounding box in device pixels (accounting for rotation if any)
                let cx = prim.rect.x + prim.rect.z * 0.5
                let cy = prim.rect.y + prim.rect.w * 0.5
                let halfExtentX: Float
                let halfExtentY: Float
                if prim.turn != 0 {
                    let cs = abs(cosf(prim.turn))
                    let sn = abs(sinf(prim.turn))
                    halfExtentX = prim.rect.z * 0.5 * cs + prim.rect.w * 0.5 * sn + 2.0
                    halfExtentY = prim.rect.z * 0.5 * sn + prim.rect.w * 0.5 * cs + 2.0
                } else {
                    halfExtentX = prim.rect.z * 0.5 + 1.5
                    halfExtentY = prim.rect.w * 0.5 + 1.5
                }

                let minX = max(0, max(Int(floorf(prim.clip.x - 1)), Int(floorf(cx - halfExtentX))))
                let minY = max(0, max(Int(floorf(prim.clip.y - 1)), Int(floorf(cy - halfExtentY))))
                let maxX = min(w - 1, min(Int(ceilf(prim.clip.x + prim.clip.z + 1)), Int(ceilf(cx + halfExtentX))))
                let maxY = min(h - 1, min(Int(ceilf(prim.clip.y + prim.clip.w + 1)), Int(ceilf(cy + halfExtentY))))
                if minX > maxX || minY > maxY { continue }

                for py in minY...maxY {
                    let rowBase = py * w
                    let fragY = Float(py) + 0.5
                    for px in minX...maxX {
                        let frag = SIMD2<Float>(Float(px) + 0.5, fragY)
                        let src = RefShader.evaluatePrimitive(
                            prim,
                            fragCoord: frag,
                            glyphs: scene.glyphs,
                            images: scene.images,
                            srgbBlend: scene.srgbBlend
                        )
                        if src.w <= 0 { continue }
                        let idx = rowBase + px
                        if layerStack.isEmpty {
                            rootBuffer[idx] = compositeOver(rootBuffer[idx], src)
                        } else {
                            let top = layerStack.count - 1
                            layerStack[top].buffer[idx] = compositeOver(layerStack[top].buffer[idx], src)
                        }
                    }
                }
            }
        }

        drawSurfaces(before: .max)

        // Convert premultiplied floating buffer to output RGBA8 bytes
        var rgba = Array<UInt8>(repeating: 0, count: pixelCount * 4)
        for i in 0..<pixelCount {
            let p = rootBuffer[i]
            let a = RefShader.clamp01(p.w)
            let straightR: Float
            let straightG: Float
            let straightB: Float
            if a > 1e-5 {
                let invA = 1.0 / a
                straightR = RefShader.clamp01(p.x * invA)
                straightG = RefShader.clamp01(p.y * invA)
                straightB = RefShader.clamp01(p.z * invA)
            } else {
                straightR = 0
                straightG = 0
                straightB = 0
            }
            let outR = scene.srgbBlend ? straightR : RefShader.linearToSRGB(straightR)
            let outG = scene.srgbBlend ? straightG : RefShader.linearToSRGB(straightG)
            let outB = scene.srgbBlend ? straightB : RefShader.linearToSRGB(straightB)

            let base = i * 4
            rgba[base] = UInt8((outR * 255.0).rounded())
            rgba[base + 1] = UInt8((outG * 255.0).rounded())
            rgba[base + 2] = UInt8((outB * 255.0).rounded())
            rgba[base + 3] = UInt8((a * 255.0).rounded())
        }

        return Frame(width: w, height: h, rgba: rgba)
    }

    /// Compares two frames against `scene` and attributes any pixel failure to the exact `Primitive`.
    public static func compare(
        scene: RefScene,
        expected: Frame,
        actual: Frame,
        channelTolerance: Int = 2,
        maxFailingPixels: Int = 0
    ) -> Difference {
        guard expected.width == actual.width && expected.height == actual.height else {
            return Difference(
                differingPixels: max(expected.width * expected.height, actual.width * actual.height),
                maxChannelDelta: 255,
                worstBlame: nil,
                passed: false
            )
        }
        var diffCount = 0
        var maxDelta = 0
        var worstCoords: (Int, Int, SIMD4<UInt8>, SIMD4<UInt8>)? = nil

        let w = expected.width
        let h = expected.height
        for y in 0..<h {
            for x in 0..<w {
                let e = expected.pixel(x: x, y: y)
                let a = actual.pixel(x: x, y: y)
                let dr = abs(Int(e.x) - Int(a.x))
                let dg = abs(Int(e.y) - Int(a.y))
                let db = abs(Int(e.z) - Int(a.z))
                let da = abs(Int(e.w) - Int(a.w))
                let d = max(max(dr, dg), max(db, da))
                if d > channelTolerance {
                    diffCount += 1
                    if d > maxDelta {
                        worstCoords = (x, y, e, a)
                    }
                }
                maxDelta = max(maxDelta, d)
            }
        }

        var blame: PixelBlame? = nil
        if let (wx, wy, e, a) = worstCoords {
            let frag = SIMD2<Float>(Float(wx) + 0.5, Float(wy) + 0.5)
            var blamedIdx: Int? = nil
            var blamedKind: PrimitiveKind? = nil
            for (idx, prim) in scene.primitives.enumerated().reversed() {
                if prim.kind == .layerBegin || prim.kind == .layerEnd { continue }
                let sample = RefShader.evaluatePrimitive(
                    prim,
                    fragCoord: frag,
                    glyphs: scene.glyphs,
                    images: scene.images,
                    srgbBlend: scene.srgbBlend
                )
                if sample.w > 0 {
                    blamedIdx = idx
                    blamedKind = prim.kind
                    break
                }
            }
            blame = PixelBlame(
                x: wx,
                y: wy,
                expected: e,
                actual: a,
                maxChannelDelta: maxDelta,
                primitiveIndex: blamedIdx,
                primitiveKind: blamedKind
            )
        }

        return Difference(
            differingPixels: diffCount,
            maxChannelDelta: maxDelta,
            worstBlame: blame,
            passed: diffCount <= maxFailingPixels
        )
    }

    private static func sampleLayerBilinear(_ buf: [SIMD4<Float>], width: Int, height: Int, at pos: SIMD2<Float>) -> SIMD4<Float> {
        let fx = pos.x - 0.5
        let fy = pos.y - 0.5
        let x0 = Int(floorf(fx))
        let y0 = Int(floorf(fy))
        let tx = fx - Float(x0)
        let ty = fy - Float(y0)

        func get(_ x: Int, _ y: Int) -> SIMD4<Float> {
            if x < 0 || x >= width || y < 0 || y >= height { return .zero }
            return buf[y * width + x]
        }

        let c00 = get(x0, y0)
        let c10 = get(x0 + 1, y0)
        let c01 = get(x0, y0 + 1)
        let c11 = get(x0 + 1, y0 + 1)
        let top = c00 + (c10 - c00) * tx
        let bot = c01 + (c11 - c01) * tx
        return top + (bot - top) * ty
    }

    private static func boxBlur(
        _ buf: [SIMD4<Float>],
        width: Int,
        height: Int,
        radius: Float,
        bounds: SIMD4<Float>
    ) -> [SIMD4<Float>] {
        let r = min(24, max(1, Int(radius.rounded())))
        let minX = max(0, Int(floorf(bounds.x)) - r)
        let minY = max(0, Int(floorf(bounds.y)) - r)
        let maxX = min(width - 1, Int(ceilf(bounds.x + bounds.z)) + r)
        let maxY = min(height - 1, Int(ceilf(bounds.y + bounds.w)) + r)
        if minX > maxX || minY > maxY { return buf }

        var temp = buf
        var out = buf
        let inv = 1.0 / Float(2 * r + 1)

        // Two-pass separable box blur (repeated twice approximates Gaussian closely)
        for _ in 0..<2 {
            for y in minY...maxY {
                for x in minX...maxX {
                    var sum = SIMD4<Float>.zero
                    for dx in -r...r {
                        let sx = min(max(x + dx, minX), maxX)
                        sum += out[y * width + sx]
                    }
                    temp[y * width + x] = sum * inv
                }
            }
            for y in minY...maxY {
                for x in minX...maxX {
                    var sum = SIMD4<Float>.zero
                    for dy in -r...r {
                        let sy = min(max(y + dy, minY), maxY)
                        sum += temp[sy * width + x]
                    }
                    out[y * width + x] = sum * inv
                }
            }
        }
        return out
    }

    private static func compositeBackdropBlur(
        _ dst: inout [SIMD4<Float>],
        blurred: [SIMD4<Float>],
        prim: Primitive,
        width: Int,
        height: Int
    ) {
        let minX = max(0, Int(floorf(max(prim.rect.x, prim.clip.x))))
        let minY = max(0, Int(floorf(max(prim.rect.y, prim.clip.y))))
        let maxX = min(width - 1, Int(ceilf(min(prim.rect.x + prim.rect.z, prim.clip.x + prim.clip.z))))
        let maxY = min(height - 1, Int(ceilf(min(prim.rect.y + prim.rect.w, prim.clip.y + prim.clip.w))))
        if minX > maxX || minY > maxY { return }
        let center = SIMD2<Float>(prim.rect.x + prim.rect.z * 0.5, prim.rect.y + prim.rect.w * 0.5)
        let halfSize = SIMD2<Float>(prim.rect.z * 0.5, prim.rect.w * 0.5)
        for y in minY...maxY {
            for x in minX...maxX {
                let frag = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                let sd = RefShader.sdBox(frag - center, halfSize: halfSize, radii: prim.radii)
                let cov = RefShader.boxCoverage(sd) * RefShader.clipCoverage(pixelCenter: frag, clip: prim.clip)
                if cov > 0 {
                    let idx = y * width + x
                    dst[idx] = dst[idx] * (1.0 - cov) + blurred[idx] * cov
                }
            }
        }
    }
}
