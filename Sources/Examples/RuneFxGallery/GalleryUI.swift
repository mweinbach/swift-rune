import Foundation
import RuneRef

#if canImport(CoreGraphics) && canImport(CoreText)
import CoreGraphics
import CoreText
#endif

#if canImport(Metal)
import Metal
#endif

let galleryAtlasSize: Int = 2048

struct UiInst: Sendable {
    var rect: SIMD4<Float>
    var p: SIMD4<Float>
    var fill: SIMD4<Float>
    var fill2: SIMD4<Float>
    var border: SIMD4<Float>
    var uv: SIMD4<Float>
    var vp: SIMD4<Float>
}

/// sRGB hex + alpha -> premultiplied linear.
func col(_ hex: UInt32, _ a: Float) -> SIMD4<Float> {
    func ch(_ shift: UInt32) -> Float {
        let srgb = Float((hex >> shift) & 0xff) / 255.0
        return RefShader.srgbToLinear(srgb) * a
    }
    return SIMD4<Float>(ch(16), ch(8), ch(0), a)
}

struct TextRegion: Sendable {
    var uv: SIMD4<Float>
    var w: Float
    var h: Float
    var ascent: Float
}

private struct AtlasKey: Hashable {
    var text: String
    var sizeQ16: UInt32
    var weight: UInt8
}

final class TextAtlas {
    var data: [UInt8]
    private var map: [AtlasKey: TextRegion] = [:]
    private var x: Int = 1
    private var y: Int = 1
    private var rowH: Int = 0
    var dirty: Bool = true

    init() {
        self.data = [UInt8](repeating: 0, count: galleryAtlasSize * galleryAtlasSize)
    }

    func get(_ text: String, sizePx: Float, weight: UInt8) -> TextRegion {
        let key = AtlasKey(text: text, sizeQ16: UInt32(max(1, Int((sizePx * 16.0).rounded()))), weight: weight)
        if let existing = map[key] {
            return existing
        }

        #if canImport(CoreGraphics) && canImport(CoreText)
        let ctWeight: CGFloat = switch weight {
        case 0: 0.0
        case 1: 0.23
        default: 0.30
        }
        let baseFont = CTFontCreateUIFontForLanguage(.system, CGFloat(sizePx), nil)
            ?? CTFontCreateWithName("HelveticaNeue" as CFString, CGFloat(sizePx), nil)
        let desc = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(baseFont),
            [kCTFontTraitsAttribute: [kCTFontWeightTrait: ctWeight]] as CFDictionary
        )
        let font = CTFontCreateCopyWithAttributes(baseFont, CGFloat(sizePx), nil, desc)

        let tracking: CGFloat = sizePx > 40.0 ? CGFloat(-0.02 * sizePx) : 0.0
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTKernAttributeName: tracking as CFNumber,
            kCTForegroundColorAttributeName: CGColor(gray: 1.0, alpha: 1.0),
        ]
        let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascentCG: CGFloat = 0
        var descentCG: CGFloat = 0
        var leadingCG: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascentCG, &descentCG, &leadingCG)
        let w = max(1, Int(ceil(max(advance, 0))) + 4)
        let h = max(1, Int(ceil(ascentCG + descentCG)) + 4)

        if x + w + 1 > galleryAtlasSize {
            x = 1
            y += rowH + 1
            rowH = 0
        }

        var local = [UInt8](repeating: 0, count: w * h)
        let gray = CGColorSpaceCreateDeviceGray()
        if let ctx = CGContext(
            data: &local,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: gray,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) {
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            ctx.setAllowsFontSmoothing(false)
            ctx.setShouldSmoothFonts(false)
            // Unflipped CGContext places bitmap row 0 at the top of the image.
            let baselineY = CGFloat(h) - 2.0 - ascentCG
            ctx.textPosition = CGPoint(x: 2.0, y: baselineY)
            CTLineDraw(line, ctx)
        }

        for row in 0..<h {
            let dy = y + row
            guard dy < galleryAtlasSize else { break }
            let dstBase = dy * galleryAtlasSize + x
            let srcBase = row * w
            for colIdx in 0..<w where x + colIdx < galleryAtlasSize {
                data[dstBase + colIdx] = max(data[dstBase + colIdx], local[srcBase + colIdx])
            }
        }

        let r = TextRegion(
            uv: SIMD4<Float>(
                Float(x) / Float(galleryAtlasSize),
                Float(y) / Float(galleryAtlasSize),
                Float(x + w) / Float(galleryAtlasSize),
                Float(y + h) / Float(galleryAtlasSize)
            ),
            w: Float(w),
            h: Float(h),
            ascent: Float(ascentCG) + 2.0
        )
        #else
        let w = max(4, Int((Float(text.count) * sizePx * 0.55).rounded()))
        let h = max(4, Int((sizePx * 1.2).rounded()))
        if x + w + 1 > galleryAtlasSize {
            x = 1
            y += rowH + 1
            rowH = 0
        }
        let r = TextRegion(
            uv: SIMD4<Float>(
                Float(x) / Float(galleryAtlasSize),
                Float(y) / Float(galleryAtlasSize),
                Float(x + w) / Float(galleryAtlasSize),
                Float(y + h) / Float(galleryAtlasSize)
            ),
            w: Float(w),
            h: Float(h),
            ascent: sizePx * 0.8 + 2.0
        )
        #endif

        x += w + 1
        rowH = max(rowH, h)
        dirty = true
        map[key] = r
        return r
    }
}

#if canImport(Metal)
final class UiRenderer {
    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let atlasTex: MTLTexture
    let sampler: MTLSamplerState
    private var buf: MTLBuffer
    private var cap: Int

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        precondition(MemoryLayout<UiInst>.stride == 112, "UiInst must be 112 bytes")
        self.device = device
        let lib = try device.makeLibrary(source: GalleryShaders.uiMetalSource, options: nil)
        guard let vs = lib.makeFunction(name: "ui_vs"),
              let fs = lib.makeFunction(name: "ui_fs") else {
            throw NSError(domain: "GalleryUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing ui shader functions"])
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "ui"
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.pipeline = try device.makeRenderPipelineState(descriptor: desc)

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: galleryAtlasSize,
            height: galleryAtlasSize,
            mipmapped: false
        )
        texDesc.usage = [.shaderRead]
        texDesc.storageMode = .shared
        self.atlasTex = device.makeTexture(descriptor: texDesc)!
        self.atlasTex.label = "gallery atlas"

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.sAddressMode = .clampToEdge
        sampDesc.tAddressMode = .clampToEdge
        self.sampler = device.makeSamplerState(descriptor: sampDesc)!

        self.cap = 1024
        self.buf = device.makeBuffer(length: self.cap * MemoryLayout<UiInst>.stride, options: .storageModeShared)!
        self.buf.label = "ui insts"
    }

    func prepare(atlas: TextAtlas, insts: [UiInst]) {
        if atlas.dirty {
            atlas.data.withUnsafeBytes { raw in
                atlasTex.replace(
                    region: MTLRegionMake2D(0, 0, galleryAtlasSize, galleryAtlasSize),
                    mipmapLevel: 0,
                    withBytes: raw.baseAddress!,
                    bytesPerRow: galleryAtlasSize
                )
            }
            atlas.dirty = false
        }
        if insts.count > cap {
            var nextCap = cap
            while nextCap < insts.count { nextCap *= 2 }
            cap = nextCap
            buf = device.makeBuffer(length: cap * MemoryLayout<UiInst>.stride, options: .storageModeShared)!
            buf.label = "ui insts"
        }
        if !insts.isEmpty {
            _ = insts.withUnsafeBytes { raw in
                memcpy(buf.contents(), raw.baseAddress!, raw.count)
            }
        }
    }

    func draw(encoder: MTLRenderCommandEncoder, range: Range<Int>) {
        guard !range.isEmpty else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        encoder.setFragmentBuffer(buf, offset: 0, index: 0)
        encoder.setFragmentTexture(atlasTex, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0,
            vertexCount: 4,
            instanceCount: range.count,
            baseInstance: range.lowerBound
        )
    }
}
#endif
