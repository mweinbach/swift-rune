import Foundation

extension SurfaceDraw {
    internal func imageGeometry(frame: NativeSurfaceVideoFrame) -> (rect: SIMD4<Float>, exact: Bool) {
        let upright = frame.orient.upright(width: frame.size.0, height: frame.size.1)
        let image = surface.place.imageRect(forNode: rect, imageSize: upright, fit: fit)
        let exact = abs(image.z - Float(upright.0)) < 0.001 && abs(image.w - Float(upright.1)) < 0.001
            && abs(image.x - image.x.rounded()) < 0.001 && abs(image.y - image.y.rounded()) < 0.001
        return (image, exact)
    }

    /// Shared GLSL uniform layout for native GL and WebGL byte-backed surfaces.
    internal func glUniforms(frame: NativeSurfaceVideoFrame, mirrored: Bool, srgbBlend: Bool,
                             width: Int, height: Int) -> [SIMD4<Float>] {
        let (image, exact) = imageGeometry(frame: frame)
        let (widths, offsets) = unpackFade(clipFade)
        let transfer: SurfaceTransfer = srgbBlend ? .linear : frame.color.transfer
        return [
            SIMD4(Float(width), Float(height), 0, 0), rect, image, radii, clip, fade, SIMD4(fadeOrigin.x, fadeOrigin.y, 0, 0),
            SIMD4(Float(frame.format.rawValue), Float(frame.color.matrix.rawValue), Float(transfer.rawValue), opacity),
            SIMD4(exact ? 1 : 0, Float(frame.size.0), Float(frame.size.1), mirrored ? 1 : 0),
            SIMD4(frame.orient.m00, frame.orient.m01, frame.orient.m10, frame.orient.m11),
            widths, offsets, unpackClipRadii(clipFade.w)
        ]
    }
}
