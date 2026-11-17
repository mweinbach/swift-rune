import Foundation
import RuneRef

internal struct RenderFrameInputError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension RenderFrame {
    private static let matchesGLVertexLayout: Bool = {
        let slots: [PartialKeyPath<RenderInstance>] = [
            \.rect, \.radii, \.fill, \.border, \.params, \.uv, \.clip, \.fade
        ]
        return MemoryLayout<RenderInstance>.stride == 128 && slots.enumerated().allSatisfy {
            MemoryLayout<RenderInstance>.offset(of: $1) == $0 * 16
        }
    }()

    /// Validates the ABI and reports whether any instance samples a missing image page.
    /// A native frame that only uses the primary atlas can skip per-draw page selection entirely.
    @discardableResult
    func validateForGL() throws -> Bool {
        guard Self.matchesGLVertexLayout else {
            throw RenderFrameInputError("Rune RenderInstance is incompatible with the GL vertex layout")
        }
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
            throw RefSceneError.invalidDimensions(width: width, height: height)
        }
        guard Self.finite(clearColor) else { throw RefSceneError.nonFiniteClearColor }
        guard materials.isEmpty else {
            throw RenderFrameInputError("Native window materials require a platform material host")
        }
        if baseGlyphPages.isEmpty {
            try Self.validateAtlas(width: baseGlyphAtlas.width, height: baseGlyphAtlas.height, channels: 1, bytes: baseGlyphAtlas.texels.count)
        }
        for page in baseGlyphPages where !page.texels.isEmpty {
            try Self.validateAtlas(width: page.width, height: page.height, channels: 1, bytes: page.texels.count)
        }
        if imagePages.isEmpty {
            try Self.validateAtlas(width: images.width, height: images.height, channels: 4, bytes: images.texels.count)
        }
        for page in imagePages where !page.texels.isEmpty {
            try Self.validateAtlas(width: page.width, height: page.height, channels: 4, bytes: page.texels.count)
        }

        var depth = 0
        var needsImageFallback = false
        let imagePageCount = Float(max(1, imagePages.count))
        for (index, item) in instances.enumerated() {
            // Effect payloads are four opaque bit patterns; applications can store any UInt32.
            let validUV = item.params.y == KIND_EFFECT || Self.finite(item.uv)
            guard Self.finite(item.rect), Self.finite(item.radii), Self.finite(item.fill),
                  Self.finite(item.border), Self.finite(item.params), validUV,
                  Self.finite(item.clip) else { throw RefSceneError.nonFinitePrimitive(index: index) }
            switch item.params.y {
            case KIND_IMAGE:
                if item.params.x >= imagePageCount { needsImageFallback = true }
            case KIND_LAYER:
                depth += 1
            case KIND_LAYER_END:
                guard depth > 0 else { throw RefSceneError.unbalancedLayerEnd(index: index) }
                depth -= 1
            default:
                guard item.params.y >= 0, item.params.y <= KIND_BACKDROP_BLUR,
                      item.params.y == item.params.y.rounded() else {
                    throw RenderFrameInputError("Unknown Rune render instance kind \(item.params.y) at index \(index)")
                }
            }
        }
        guard depth == 0 else { throw RefSceneError.unclosedLayers(remaining: depth) }
        return needsImageFallback
    }

    /// The original browser packet represents a single texture. Native GL binds each page
    /// independently and never enters this packing path.
    func packedForLegacyWebPacket() throws -> RenderFrame {
        let needsImageFallback = try validateForGL()
        guard !imagePages.isEmpty || needsImageFallback else { return self }
        var pages = imagePages.isEmpty ? [images] : imagePages.map { $0.texels.isEmpty ? RGBA8Atlas() : $0 }
        let pageCount = pages.count
        if needsImageFallback { pages.append(RGBA8Atlas()) }
        var frame = self
        frame.imagePages = []
        if pages.count == 1 {
            frame.images = pages[0]
            return frame
        }

        // Keep equal-size pages near square, to fit within the driver's dimension limit.
        let maxWidth = pages.map(\.width).max()!
        let totalArea = pages.reduce(0.0) { $0 + Double($1.width) * Double($1.height) }
        let perRow = max(1, Int(ceil(sqrt(totalArea) / Double(maxWidth))))
        let rowLimit = min(16_384, perRow * maxWidth)
        var offsets: [(x: Int, y: Int)] = []
        var x = 0, y = 0, rowHeight = 0, atlasWidth = 0
        for page in pages {
            if x > 0, x + page.width > rowLimit {
                x = 0
                y += rowHeight
                rowHeight = 0
            }
            guard y + page.height <= 16_384 else {
                throw RenderFrameInputError("Image pages exceed the maximum packed GL atlas height")
            }
            offsets.append((x, y))
            rowHeight = max(rowHeight, page.height)
            x += page.width
            atlasWidth = max(x, atlasWidth)
        }
        let atlasHeight = y + rowHeight
        var pixels = [UInt8](repeating: 0, count: atlasWidth * atlasHeight * 4)
        for (page, offset) in zip(pages, offsets) {
            let rowBytes = page.width * 4
            for row in 0..<page.height {
                let dst = ((offset.y + row) * atlasWidth + offset.x) * 4
                let src = row * rowBytes
                pixels.replaceSubrange(dst..<(dst + rowBytes), with: page.texels[src..<(src + rowBytes)])
            }
        }
        frame.images = RGBA8Atlas(width: atlasWidth, height: atlasHeight, texels: pixels)
        for index in frame.instances.indices where frame.instances[index].params.y == KIND_IMAGE {
            let requested = frame.instances[index].params.x
            let page = requested >= Float(pageCount) ? pageCount : Int(max(0, requested))
            let dx = Float(offsets[page].x)
            let dy = Float(offsets[page].y)
            frame.instances[index].uv.x += dx
            frame.instances[index].uv.y += dy
            let bounds = frame.instances[index].border
            if bounds.z > bounds.x && bounds.w > bounds.y {
                frame.instances[index].border = bounds + SIMD4(dx, dy, dx, dy)
            }
            frame.instances[index].params.x = 0
        }
        return frame
    }

    private static func validateAtlas(width: Int, height: Int, channels: Int, bytes: Int) throws {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
            throw RenderFrameInputError("Invalid Rune atlas dimensions \(width) by \(height)")
        }
        let expected = width * height * channels
        guard bytes == expected else {
            if channels == 1 { throw RefSceneError.invalidGlyphAtlasSize(expected: expected, actual: bytes) }
            throw RefSceneError.invalidImageAtlasSize(expected: expected, actual: bytes)
        }
    }

    private static func finite(_ value: SIMD4<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite
    }
}
