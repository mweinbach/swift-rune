import Foundation

/// Wayland client-side decoration bottom-corner rounding (`render/csd_corners.rs` +
/// `window/surface/corners.rs`, upstream `#1188`).
///
/// Under `sctk-adwaita` and Wayland CSD frames, the headerbar rounds the top two corners while
/// the content surface stays rectangular. `CsdCorners` computes the bottom-left and bottom-right
/// corner vertices, coverage math, and GLSL/WGSL shader passes to fade pixels outside the two
/// arcs cleanly into the frame's border without seams.
public struct CsdCorners: Sendable, Equatable {
    /// Corner radius in logical points (0 when maximized, tiled, fullscreen, or server-decorated).
    public var radiusPt: Float
    /// Display scale factor (device pixels per logical point).
    public var scale: Float
    /// Surface size in physical device pixels.
    public var sizePx: (width: UInt32, height: UInt32)

    public init(radiusPt: Float = 0, scale: Float = 1, sizePx: (width: UInt32, height: UInt32) = (0, 0)) {
        self.radiusPt = max(0, radiusPt.isFinite ? radiusPt : 0)
        self.scale = max(0.5, scale.isFinite ? scale : 1)
        self.sizePx = sizePx
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.radiusPt == rhs.radiusPt && lhs.scale == rhs.scale
            && lhs.sizePx.width == rhs.sizePx.width && lhs.sizePx.height == rhs.sizePx.height
    }

    /// Corner radius in physical device pixels, clamped to half the smallest surface dimension.
    public var radiusPx: Float {
        guard radiusPt > 0, sizePx.width > 0, sizePx.height > 0 else { return 0 }
        let maxR = Float(min(sizePx.width, sizePx.height)) * 0.5
        return min(radiusPt * scale, maxR)
    }

    /// True when the bottom two corners need a corner-fade pass.
    public var isActive: Bool {
        radiusPx > 0
    }

    /// Vertex layout matching `render/csd_corners.rs` (`#1299`):
    /// `(clipX, clipY, centreX, centreY, radiusPx)` with flat corner arc centre in device pixels.
    public struct Vertex: Sendable, Equatable {
        public var clipX: Float
        public var clipY: Float
        public var centreX: Float
        public var centreY: Float
        public var radius: Float

        public init(clipX: Float, clipY: Float, centreX: Float, centreY: Float, radius: Float) {
            self.clipX = clipX
            self.clipY = clipY
            self.centreX = centreX
            self.centreY = centreY
            self.radius = radius
        }
    }

    /// Builds the 12 triangle vertices (2 corner squares × 2 triangles) in NDC space for the
    /// bottom-left and bottom-right corners, carrying each corner arc's flat centre in device pixels.
    public func vertices() -> [Vertex] {
        let r = radiusPx
        guard r > 0, sizePx.width > 0, sizePx.height > 0 else { return [] }
        let w = Float(sizePx.width)
        let h = Float(sizePx.height)
        var out: [Vertex] = []
        out.reserveCapacity(12)
        // Each corner's square runs from the arc's centre out to the window's edges, a radius
        // either way; the bottom two sit a radius in from the foot's sides and off its edge, one
        // reaching left and the other right.
        let corners: [(centre: (Float, Float), side: Float)] = [
            ((r, h - r), -1.0),
            ((w - r, h - r), 1.0),
        ]
        let unitSquare: [(Float, Float)] = [
            (0.0, 0.0), (1.0, 0.0), (0.0, 1.0),
            (1.0, 0.0), (1.0, 1.0), (0.0, 1.0),
        ]
        for (centre, side) in corners {
            for (u, v) in unitSquare {
                let x = centre.0 + side * u * r
                let y = centre.1 + v * r
                out.append(Vertex(
                    clipX: x / w * 2.0 - 1.0,
                    clipY: 1.0 - y / h * 2.0,
                    centreX: centre.0,
                    centreY: centre.1,
                    radius: r
                ))
            }
        }
        return out
    }

    /// Evaluates the fraction of the pixel at exact device-pixel centre `(pixelX, pixelY)` cleared
    /// outside the arc centred at `(centreX, centreY)` (`0` inside, `1` outside, 1-pixel smoothstep
    /// band across the arc), matching `render/csd_corners.rs::fs` (`#1299`).
    public static func outsideFraction(
        pixelX: Float,
        pixelY: Float,
        centreX: Float,
        centreY: Float,
        radiusPx: Float
    ) -> Float {
        guard radiusPx > 0 else { return 0 }
        let dist = hypotf(pixelX - centreX, pixelY - centreY)
        let edge0 = radiusPx - 0.5
        let edge1 = radiusPx + 0.5
        let t = min(1.0, max(0.0, (dist - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)
    }

    /// Normalized corner-square convenience overload (measures distance `hypot(squareX, squareY) * radiusPx`).
    public static func outsideFraction(squareX: Float, squareY: Float, radiusPx: Float) -> Float {
        outsideFraction(
            pixelX: squareX * radiusPx,
            pixelY: squareY * radiusPx,
            centreX: 0,
            centreY: 0,
            radiusPx: radiusPx
        )
    }

    /// Applies the bottom-corner fade in place to a top-down premultiplied RGBA8 framebuffer
    /// (for CPU verification and software surfaces), evaluating at exact pixel centres `(px + 0.5, py + 0.5)`.
    public func applyInPlace(rgba: inout [UInt8]) {
        let r = radiusPx
        let w = Int(sizePx.width)
        let h = Int(sizePx.height)
        guard r > 0, w > 0, h > 0, rgba.count >= w * h * 4 else { return }
        let span = min(Int(ceilf(r)), min(w, h))
        let yStart = max(0, h - span)
        let centreY = Float(h) - r
        let leftCentreX = r
        let rightCentreX = Float(w) - r
        for py in yStart..<h {
            let pixelY = Float(py) + 0.5
            guard pixelY > centreY else { continue }
            // Bottom-left
            for px in 0..<span {
                let pixelX = Float(px) + 0.5
                guard pixelX < leftCentreX else { continue }
                let outside = Self.outsideFraction(
                    pixelX: pixelX,
                    pixelY: pixelY,
                    centreX: leftCentreX,
                    centreY: centreY,
                    radiusPx: r
                )
                if outside > 0 {
                    let keep = 1.0 - outside
                    let idx = (py * w + px) * 4
                    for c in 0..<4 {
                        rgba[idx + c] = UInt8(min(255, max(0, Int((Float(rgba[idx + c]) * keep).rounded()))))
                    }
                }
            }
            // Bottom-right
            let xRightStart = max(span, w - span)
            for px in xRightStart..<w {
                let pixelX = Float(px) + 0.5
                guard pixelX > rightCentreX else { continue }
                let outside = Self.outsideFraction(
                    pixelX: pixelX,
                    pixelY: pixelY,
                    centreX: rightCentreX,
                    centreY: centreY,
                    radiusPx: r
                )
                if outside > 0 {
                    let keep = 1.0 - outside
                    let idx = (py * w + px) * 4
                    for c in 0..<4 {
                        rgba[idx + c] = UInt8(min(255, max(0, Int((Float(rgba[idx + c]) * keep).rounded()))))
                    }
                }
            }
        }
    }

    /// GLSL 330 core fragment shader matching `crates/rune/src/render/csd_corners.rs` (`#1299`).
    public static let glslFragmentSource: String = """
    #version 330 core
    uniform vec2 u_viewport;
    flat in vec2 v_centre;
    flat in float v_radius;
    out vec4 out_color;
    void main() {
        vec2 pixel = vec2(gl_FragCoord.x, u_viewport.y - gl_FragCoord.y);
        float dist = length(pixel - v_centre);
        float outside = smoothstep(v_radius - 0.5, v_radius + 0.5, dist);
        if (outside <= 0.0) discard;
        out_color = vec4(0.0, 0.0, 0.0, outside);
    }
    """

    /// WGSL shader matching `crates/rune/src/render/csd_corners.rs` (`#1299`).
    public static let wgslSource: String = """
    // `centre` is the corner arc's centre in device pixels, flat across the corner's square, and
    // `radius` is the arc's radius in device pixels, so the fade is one pixel wide whatever the scale.
    // Measuring from `@builtin(position).xy` uses the rasterizer's exact pixel centre instead of an
    // interpolated quad coordinate that can drift by subpixel ULPs on D3D12.
    struct Vertex {
        @builtin(position) at: vec4<f32>,
        @location(0) @interpolate(flat) centre: vec2<f32>,
        @location(1) @interpolate(flat) radius: f32,
    };
    @vertex fn vs(@location(0) at: vec2<f32>, @location(1) centre: vec2<f32>, @location(2) radius: f32) -> Vertex {
        return Vertex(vec4(at, 0.0, 1.0), centre, radius);
    }
    @fragment fn fs(frag: Vertex) -> @location(0) vec4<f32> {
        let distance = length(frag.at.xy - frag.centre);
        let outside = smoothstep(frag.radius - 0.5, frag.radius + 0.5, distance);
        if outside <= 0.0 {
            discard;
        }
        return vec4(0.0, 0.0, 0.0, outside);
    }
    """

    /// MSL shader matching `crates/rune/src/render/csd_corners.rs` (`#1299`).
    public static let mslSource: String = """
    #include <metal_stdlib>
    using namespace metal;
    struct CsdCornerVertexIn {
        float2 at [[attribute(0)]];
        float2 centre [[attribute(1)]];
        float radius [[attribute(2)]];
    };
    struct CsdCornerVertexOut {
        float4 at [[position]];
        float2 centre [[flat]];
        float radius [[flat]];
    };
    vertex CsdCornerVertexOut csd_corners_vs(CsdCornerVertexIn in [[stage_in]]) {
        CsdCornerVertexOut out;
        out.at = float4(in.at, 0.0, 1.0);
        out.centre = in.centre;
        out.radius = in.radius;
        return out;
    }
    fragment float4 csd_corners_fs(CsdCornerVertexOut frag [[stage_in]]) {
        float distance = length(frag.at.xy - frag.centre);
        float outside = smoothstep(frag.radius - 0.5, frag.radius + 0.5, distance);
        if (outside <= 0.0) {
            discard_fragment();
        }
        return float4(0.0, 0.0, 0.0, outside);
    }
    """
}
