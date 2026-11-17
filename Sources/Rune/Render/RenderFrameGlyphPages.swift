import RuneRef

extension RenderFrame {
    /// Rewrites page-local mask texels for clients whose frame ABI accepts one R8 texture.
    public func flattenedGlyphPages() throws -> RenderFrame {
        let pages = glyphPages
        guard !pages.isEmpty else { return self }
        var width = 0
        for page in pages {
            guard page.width > 0, page.width <= 16_384, page.height > 0, page.height <= 16_384 else {
                throw RefSceneError.invalidAtlasDimensions(width: page.width, height: page.height)
            }
            guard page.texels.isEmpty || page.texels.count == page.width * page.height else {
                throw RefSceneError.invalidGlyphAtlasSize(expected: page.width * page.height, actual: page.texels.count)
            }
            width = max(width, page.width)
        }
        var origins: [Int] = []
        var height = 0
        for (index, page) in pages.enumerated() {
            if index > 0 {
                let previous = pages[index - 1]
                let lastRow = (previous.height - 1) * previous.width
                // Keep linear filtering clamped at both page edges. Normal shelf pages
                // already have matching zero gutters and can be stacked directly.
                let needsGutter = (0..<max(previous.width, page.width)).contains { x in
                    let upper = previous.texels.isEmpty ? 0 : previous.texels[lastRow + min(x, previous.width - 1)]
                    let lower = page.texels.isEmpty ? 0 : page.texels[min(x, page.width - 1)]
                    return upper != lower
                }
                if needsGutter { height += 2 }
            }
            guard page.height <= 16_384 - height else {
                throw RefSceneError.invalidAtlasDimensions(width: width, height: height + page.height)
            }
            origins.append(height)
            height += page.height
        }
        var combined = R8Atlas(width: width, height: height)
        combined.texels.withUnsafeMutableBufferPointer { target in
            for (index, page) in pages.enumerated() where !page.texels.isEmpty {
                page.texels.withUnsafeBufferPointer { source in
                    let origin = origins[index]
                    let top = index > 0 && origins[index - 1] + pages[index - 1].height < origin ? -1 : 0
                    let end = index + 1 < pages.count && origin + page.height < origins[index + 1] ? page.height + 1 : page.height
                    for row in top..<end {
                        let sourceRow = source.baseAddress! + min(max(0, row), page.height - 1) * page.width
                        let destination = target.baseAddress! + (origin + row) * width
                        destination.update(from: sourceRow, count: page.width)
                        (destination + page.width).update(repeating: sourceRow[page.width - 1], count: width - page.width)
                    }
                }
            }
        }
        var result = self
        result.glyphPages = []
        result.glyphs = combined
        for index in result.instances.indices where result.instances[index].params.y == KIND_GLYPH {
            let page = Int(exactly: result.instances[index].params.z.rounded(.towardZero)) ?? 0
            if origins.indices.contains(page) { result.instances[index].uv.y += Float(origins[page]) }
            result.instances[index].params.z = 0
        }
        return result
    }
}
