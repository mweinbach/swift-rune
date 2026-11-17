#if canImport(Metal)
import Metal
import RuneRef

/// Raised before Metal receives an unsupported 2D texture or an incomplete atlas upload.
public enum MetalTextureSizeError: Error, Equatable, Sendable, CustomStringConvertible {
    case dimensions(resource: String, width: Int, height: Int, maximum: Int)
    case byteCount(resource: String, expected: Int, actual: Int)

    public var description: String {
        switch self {
        case let .dimensions(resource, width, height, maximum):
            return "\(resource) is \(width)×\(height). This Metal device accepts sides of 1...\(maximum) pixels."
        case let .byteCount(resource, expected, actual):
            return "\(resource) requires \(expected) bytes, received \(actual)."
        }
    }
}

enum MetalTextureLimits {
    // Apple Metal Feature Set Tables, "Maximum 2D texture width and height".
    static func max2D(on device: MTLDevice) -> Int {
        if device.supportsFamily(.apple10) { return 32_768 }
        #if os(macOS) || targetEnvironment(macCatalyst)
        return 16_384
        #else
        return device.supportsFamily(.apple3) ? 16_384 : 8_192
        #endif
    }

    static func contains(width: Int, height: Int, on device: MTLDevice) -> Bool {
        let limit = max2D(on: device)
        return width > 0 && height > 0 && width <= limit && height <= limit
    }

    static func validate(width: Int, height: Int, resource: String, on device: MTLDevice) throws(MetalTextureSizeError) {
        guard contains(width: width, height: height, on: device) else {
            throw .dimensions(resource: resource, width: width, height: height, maximum: max2D(on: device))
        }
    }

    static func validate(_ frame: RenderFrame, viewport: (Int, Int)?, on device: MTLDevice) throws(MetalTextureSizeError) {
        try validate(width: frame.width, height: frame.height, resource: "Frame", on: device)
        if let viewport, viewport != (frame.width, frame.height) {
            try validate(width: viewport.0, height: viewport.1, resource: "Viewport", on: device)
        }
        let glyph = frame.glyphs
        try validate(width: glyph.width, height: glyph.height, resource: "Glyph atlas", on: device)
        let glyphBytes = glyph.width * glyph.height
        if glyph.texels.count != glyphBytes && !(glyphBytes == 1 && glyph.texels.isEmpty) {
            throw .byteCount(resource: "Glyph atlas", expected: glyphBytes, actual: glyph.texels.count)
        }
        if frame.imagePages.isEmpty {
            try validateImage(frame.images, resource: "Image atlas", on: device)
        } else {
            for (index, page) in frame.imagePages.enumerated() {
                try validateImage(page, resource: "Image atlas page \(index)", on: device)
            }
        }
    }

    static func validateImage(_ image: RGBA8Atlas, resource: String, on device: MTLDevice) throws(MetalTextureSizeError) {
        try validate(width: image.width, height: image.height, resource: resource, on: device)
        let expected = image.width * image.height * 4
        guard image.texels.count == expected else {
            throw .byteCount(resource: resource, expected: expected, actual: image.texels.count)
        }
    }
}
#endif
