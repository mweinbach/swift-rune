import Foundation

/// Pixel placement used when a window shows a playing clip in its own DirectComposition visual.
internal struct WindowsVideoLayerGeometry: Equatable {
    let x, y: Int32
    let width, height: UInt32
    let clip: SIMD4<Int32>
    let sourceWidth, sourceHeight: UInt32
    let format: SurfacePixelFormat
    let color: SurfaceColorInfo

    static func destination(_ frame: RenderFrame, index: Int, picture: NativeSurfaceVideoFrame) -> Self? {
        let draw = frame.surfaces[index]
        guard draw.opacity == 1, draw.radii == .zero, draw.fade == .zero, draw.clipFade == .zero else { return nil }
        let image = draw.imageGeometry(frame: picture).rect
        let right = image.x + image.z, bottom = image.y + image.w
        guard let x = Int32(exactly: image.x), let y = Int32(exactly: image.y),
              let width = UInt32(exactly: image.z), let height = UInt32(exactly: image.w),
              width > 0, height > 0, width <= 16_384, height <= 16_384 else { return nil }
        let left = max(0, image.x, draw.clip.x, draw.rect.x)
        let top = max(0, image.y, draw.clip.y, draw.rect.y)
        let visibleRight = min(Float(frame.width), right, draw.clip.z, draw.rect.x + draw.rect.z)
        let visibleBottom = min(Float(frame.height), bottom, draw.clip.w, draw.rect.y + draw.rect.w)
        guard left < visibleRight, top < visibleBottom,
              let l = Int32(exactly: left - image.x), let t = Int32(exactly: top - image.y),
              let r = Int32(exactly: visibleRight - image.x), let b = Int32(exactly: visibleBottom - image.y) else { return nil }
        // The UI's WGL/DXGI presentation is opaque. A top visual is equivalent to
        // the original painter order only when no later operation can touch it.
        func overlaps(_ rect: SIMD4<Float>, extra: Float = 0) -> Bool {
            rect.x - extra < visibleRight && rect.y - extra < visibleBottom &&
            rect.x + rect.z + extra > left && rect.y + rect.w + extra > top
        }
        let stop = Int(draw.beforeInstance)
        guard stop <= frame.instances.count else { return nil }
        var depth = 0
        for p in frame.instances[..<stop] {
            if p.params.y == KIND_LAYER { depth += 1 }
            if p.params.y == KIND_LAYER_END { depth -= 1 }
        }
        guard depth == 0 else { return nil }
        for p in frame.instances[stop...] {
            switch p.params.y {
            case KIND_GLYPH where p.params.x != 0:
                return nil // a rotated glyph's ink can fall outside its original quad
            case KIND_RECT, KIND_GLYPH, KIND_IMAGE, KIND_GRADIENT, KIND_INSET, KIND_RADIAL, KIND_DASHED:
                if overlaps(p.rect, extra: 2 + max(0, p.params.z) * 2) { return nil }
            case KIND_SHADOW:
                if overlaps(p.rect, extra: max(0, p.params.z) * 3 + 2) { return nil }
            default:
                // Custom effects, transformed groups and backdrop kernels may sample
                // pixels beyond their instance rectangle.
                return nil
            }
        }
        guard !frame.surfaces[(index + 1)...].contains(where: { overlaps($0.rect, extra: 1) }) else { return nil }
        return .init(x: x, y: y, width: width, height: height, clip: SIMD4(l, t, r, b), sourceWidth: picture.size.0,
                     sourceHeight: picture.size.1, format: picture.format, color: picture.color)
    }
}
