import Foundation
import RuneRef
#if !canImport(CoreText) || !canImport(CoreGraphics)
import Rune
#endif

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
    private var sceneName: String?
    private var overflowingLabel: String?
    #if !canImport(CoreText) || !canImport(CoreGraphics)
    private let textSystem = TextSystem()
    #endif
    var dirty: Bool = true

    init() {
        self.data = [UInt8](repeating: 0, count: galleryAtlasSize * galleryAtlasSize)
    }

    func beginScene(_ name: String) {
        guard sceneName != name else { return }
        if sceneName != nil {
            data = [UInt8](repeating: 0, count: galleryAtlasSize * galleryAtlasSize)
            map.removeAll(keepingCapacity: true)
            x = 1
            y = 1
            rowH = 0
            overflowingLabel = nil
            dirty = true
        }
        sceneName = name
    }

    func checkCapacity() throws {
        if let overflowingLabel {
            throw NSError(domain: "RuneFxGallery", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Gallery text atlas is full while packing '\(overflowingLabel)'"
            ])
        }
    }

    /// Shelf positions and UVs stay valid until the next scene, including GUI and mask passes.
    private func place(width: Int, height: Int, label: String) -> Bool {
        guard width <= galleryAtlasSize - 2, height <= galleryAtlasSize - 2 else {
            overflowingLabel = label
            return false
        }
        if x + width + 1 > galleryAtlasSize {
            x = 1
            y += rowH + 1
            rowH = 0
        }
        if y + height + 1 > galleryAtlasSize {
            overflowingLabel = label
            return false
        }
        return true
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

        let ascent = Float(ascentCG) + 2.0
        guard place(width: w, height: h, label: text) else {
            return TextRegion(uv: .zero, w: Float(w), h: Float(h), ascent: ascent)
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

        #else
        let style = TextStyle(
            size: sizePx,
            weight: weight == 0 ? 400 : (weight == 1 ? 500 : 600),
            letterSpacing: sizePx > 40 ? -0.02 * sizePx : 0
        )
        textSystem.glyphAtlas.beginFrame()
        let line = textSystem.shape(text: text, style: style, maxWidth: nil, pixelScale: 1)
        let w = max(1, Int(ceil(line.size.x)) + 4)
        let h = max(1, Int(ceil(line.size.y)) + 4)
        let ascent = (TextBoxGeometry.roundedBaselines(originYPx: 0, shaped: line).first ?? 0) + 2
        guard place(width: w, height: h, label: text) else {
            return TextRegion(uv: .zero, w: Float(w), h: Float(h), ascent: ascent)
        }
        var local = [UInt8](repeating: 0, count: w * h)
        let atlas = textSystem.glyphAtlas
        for glyph in line.glyphs {
            let dx = 2 + Int(glyph.rect.x.rounded())
            let dy = 2 + Int(glyph.rect.y.rounded())
            let glyphW = Int(glyph.rect.z.rounded())
            let glyphH = Int(glyph.rect.w.rounded())
            if let color = textSystem.colorGlyph(for: glyph) {
                let stride = color.pixelSize.x * 4
                blitMask(color.rgba, from: 3, stride: stride, step: 4,
                         width: min(glyphW, color.pixelSize.x), height: min(glyphH, color.pixelSize.y),
                         atX: dx, y: dy, into: &local, width: w, height: h)
            } else if let page = atlas.pageData(Int(glyph.atlasPage)) {
                let stride = atlas.atlas.width
                let sx = Int((glyph.uv.x * Float(stride)).rounded())
                let sy = Int((glyph.uv.y * Float(atlas.atlas.height)).rounded())
                blitMask(page, from: sy * stride + sx, stride: stride, step: 1,
                         width: glyphW, height: glyphH, atX: dx, y: dy,
                         into: &local, width: w, height: h)
            }
        }
        #endif

        for row in 0..<h {
            let dst = (y + row) * galleryAtlasSize + x
            data.replaceSubrange(dst..<(dst + w), with: local[(row * w)..<((row + 1) * w)])
        }
        let r = TextRegion(
            uv: SIMD4<Float>(Float(x), Float(y), Float(x + w), Float(y + h)) / Float(galleryAtlasSize),
            w: Float(w), h: Float(h), ascent: ascent
        )
        x += w + 1
        rowH = max(rowH, h)
        dirty = true
        map[key] = r
        return r
    }

    #if !canImport(CoreText) || !canImport(CoreGraphics)
    private func blitMask<Bytes: RandomAccessCollection>(
        _ src: Bytes, from start: Int, stride: Int, step: Int, width: Int, height: Int,
        atX x: Int, y: Int, into dst: inout [UInt8], width dstWidth: Int, height dstHeight: Int
    ) where Bytes.Element == UInt8, Bytes.Index == Int {
        let x0 = max(0, -x), x1 = min(width, dstWidth - x)
        let y0 = max(0, -y), y1 = min(height, dstHeight - y)
        guard x0 < x1, y0 < y1 else { return }
        for row in y0..<y1 {
            let srcRow = start + row * stride
            let dstRow = (y + row) * dstWidth + x
            for col in x0..<x1 {
                let alpha = Int(src[srcRow + col * step])
                let idx = dstRow + col
                dst[idx] = UInt8(alpha + (Int(dst[idx]) * (255 - alpha) + 127) / 255)
            }
        }
    }
    #endif
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
