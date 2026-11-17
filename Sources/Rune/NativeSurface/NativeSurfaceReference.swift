import Foundation
import RuneRef

/// Captures the picture and placement together so deferred CPU captures retain
/// the same video frame even when its producer has published a newer picture.
internal enum NativeSurfaceReference {
    private struct Source {
        let frame: NativeSurfaceVideoFrame
        let mirrored: Bool
        let sampler: SurfacePlaneSampler
    }

    static func capture(_ draws: [SurfaceDraw], srgbBlend: Bool) throws -> [RefSurfaceDraw] {
        var sources: [UInt: Source] = [:]
        var result: [RefSurfaceDraw] = []
        result.reserveCapacity(draws.count)
        for draw in draws where draw.rect.z > 0 && draw.rect.w > 0 {
            let key = draw.surface.key
            let source: Source
            if let existing = sources[key] {
                source = existing
            } else {
                guard let snapshot = draw.surface.renderSnapshot() else { continue }
                let sampler = try SurfacePlaneSampler(frame: snapshot.frame, srgbBlend: srgbBlend)
                source = Source(frame: snapshot.frame, mirrored: snapshot.mirrored, sampler: sampler)
                sources[key] = source
            }
            let placement = Placement(draw: draw, frame: source.frame, mirrored: source.mirrored)
            let sampler = source.sampler
            result.append(RefSurfaceDraw(beforeInstance: draw.beforeInstance, rect: draw.rect) { pixel in
                placement.shade(pixel, sampler: sampler)
            })
        }
        return result
    }

    private struct Placement: Sendable {
        let nodeCenter, nodeHalf: SIMD2<Float>
        let imageOrigin, imageSize, displaySize: SIMD2<Float>
        let radii, fade: SIMD4<Float>
        let fadeOrigin: SIMD2<Float>
        let clip: CpuBootShade.Clip
        let opacity: Float
        let orient: Orient
        let mirrored, exact: Bool

        init(draw: SurfaceDraw, frame: NativeSurfaceVideoFrame, mirrored: Bool) {
            let geometry = draw.imageGeometry(frame: frame)
            imageOrigin = SIMD2(geometry.rect.x, geometry.rect.y)
            imageSize = SIMD2(geometry.rect.z, geometry.rect.w)
            exact = geometry.exact
            orient = frame.orient
            self.mirrored = mirrored
            displaySize = SIMD2(abs(orient.m00) * imageSize.x + abs(orient.m01) * imageSize.y,
                                abs(orient.m10) * imageSize.x + abs(orient.m11) * imageSize.y)
            nodeHalf = SIMD2(draw.rect.z, draw.rect.w) * 0.5
            nodeCenter = SIMD2(draw.rect.x, draw.rect.y) + nodeHalf
            radii = draw.radii
            fade = draw.fade
            fadeOrigin = draw.fadeOrigin
            opacity = draw.opacity
            let (width, offset) = unpackFade(draw.clipFade)
            let clipRadii = unpackClipRadii(draw.clipFade.w)
            clip = CpuBootShade.Clip(rect: draw.clip, fadeWidth: width, fadeOffset: offset,
                                     radii: clipRadii == .zero ? nil : clipRadii)
        }

        func shade(_ p: SIMD2<Float>, sampler: SurfacePlaneSampler) -> SIMD4<Float> {
            var local = p - imageOrigin
            guard local.x >= 0, local.y >= 0, local.x < imageSize.x, local.y < imageSize.y else { return .zero }
            var mask = opacity * clip.alpha(p) * nodeCoverage(p - nodeCenter)
            if fade.z != 0 {
                let d = p - fadeOrigin
                let t = CpuBootShade.clamp01((d.x * fade.x + d.y * fade.y) * fade.z)
                mask *= fade.w + (1 - fade.w) * t
            }
            guard mask > 0 else { return .zero }
            if mirrored { local.x = imageSize.x - local.x }
            let d = local - imageSize * 0.5
            let mapped = SIMD2(orient.m00 * d.x + orient.m01 * d.y, orient.m10 * d.x + orient.m11 * d.y)
            return sampler.sample(bufferPixel: mapped + displaySize * 0.5, displaySize: displaySize, exact: exact) * mask
        }

        private func nodeCoverage(_ p: SIMD2<Float>) -> Float {
            let radius = p.x > 0 ? (p.y > 0 ? radii.z : radii.y) : (p.y > 0 ? radii.w : radii.x)
            if radius >= 0 {
                return CpuBootShade.clamp01(0.5 - CpuBootShade.sdRounded(p, half: nodeHalf, radii: radii))
            }
            // The native video quad uses a beveled node for signed corner radii.
            // Its enclosing clip uses the continuous-corner distance in Clip.alpha.
            let r = min(-radius, min(nodeHalf.x, nodeHalf.y))
            let q = SIMD2(abs(p.x), abs(p.y)) - nodeHalf + SIMD2<Float>(repeating: r)
            let distance = max(max(q.x, q.y), (q.x + q.y + 0.41421356 * r) * 0.70710678)
            return CpuBootShade.clamp01(0.5 - distance)
        }
    }
}
