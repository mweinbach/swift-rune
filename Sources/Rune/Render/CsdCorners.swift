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

    /// Vertex layout matching `render/csd_corners.rs`: `(clipX, clipY, squareX, squareY, radiusPx)`.
    public struct Vertex: Sendable, Equatable {
        public var clipX: Float
        public var clipY: Float
        public var squareX: Float
        public var squareY: Float
        public var radius: Float
    }

    /// Builds the 12 triangle vertices (2 corner squares × 2 triangles) in NDC space for the
    /// bottom-left and bottom-right corners.
    public func vertices() -> [Vertex] {
        let r = radiusPx
        guard r > 0, sizePx.width > 0, sizePx.height > 0 else { return [] }
        let w = Float(sizePx.width)
        let h = Float(sizePx.height)
        let dx = (2.0 * r) / w
        let dy = (2.0 * r) / h
        // Bottom-left corner: NDC x in [-1, -1 + dx], y in [-1, -1 + dy]
        // square coordinates measure from arc center (0, 0) to corner (-1, 1).
        let bl: [Vertex] = [
            Vertex(clipX: -1.0,      clipY: -1.0 + dy, squareX: -1.0, squareY: 0.0, radius: r),
            Vertex(clipX: -1.0,      clipY: -1.0,      squareX: -1.0, squareY: 1.0, radius: r),
            Vertex(clipX: -1.0 + dx, clipY: -1.0,      squareX:  0.0, squareY: 1.0, radius: r),
            Vertex(clipX: -1.0,      clipY: -1.0 + dy, squareX: -1.0, squareY: 0.0, radius: r),
            Vertex(clipX: -1.0 + dx, clipY: -1.0,      squareX:  0.0, squareY: 1.0, radius: r),
            Vertex(clipX: -1.0 + dx, clipY: -1.0 + dy, squareX:  0.0, squareY: 0.0, radius: r),
        ]
        // Bottom-right corner: NDC x in [1 - dx, 1], y in [-1, -1 + dy]
        let br: [Vertex] = [
            Vertex(clipX: 1.0 - dx, clipY: -1.0 + dy, squareX: 0.0, squareY: 0.0, radius: r),
            Vertex(clipX: 1.0 - dx, clipY: -1.0,      squareX: 0.0, squareY: 1.0, radius: r),
            Vertex(clipX: 1.0,      clipY: -1.0,      squareX: 1.0, squareY: 1.0, radius: r),
            Vertex(clipX: 1.0 - dx, clipY: -1.0 + dy, squareX: 0.0, squareY: 0.0, radius: r),
            Vertex(clipX: 1.0,      clipY: -1.0,      squareX: 1.0, squareY: 1.0, radius: r),
            Vertex(clipX: 1.0,      clipY: -1.0 + dy, squareX: 1.0, squareY: 0.0, radius: r),
        ]
        return bl + br
    }

    /// Evaluates the fraction of the pixel cleared outside the arc (`0` inside, `1` outside,
    /// 1-pixel smoothstep band across the arc), matching `render/csd_corners.rs::fs`.
    public static func outsideFraction(squareX: Float, squareY: Float, radiusPx: Float) -> Float {
        guard radiusPx > 0 else { return 0 }
        let dist = hypotf(squareX, squareY) * radiusPx
        let edge0 = radiusPx - 0.5
        let edge1 = radiusPx + 0.5
        let t = min(1.0, max(0.0, (dist - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)
    }

    /// Applies the bottom-corner fade in place to a top-down premultiplied RGBA8 framebuffer
    /// (for CPU verification and software surfaces).
    public func applyInPlace(rgba: inout [UInt8]) {
        let r = radiusPx
        let w = Int(sizePx.width)
        let h = Int(sizePx.height)
        guard r > 0, w > 0, h > 0, rgba.count >= w * h * 4 else { return }
        let span = min(Int(ceilf(r)), min(w, h))
        let yStart = max(0, h - span)
        for py in yStart..<h {
            let cy = (Float(py) + 0.5) - (Float(h) - r)
            guard cy > 0 else { continue }
            // Bottom-left
            for px in 0..<span {
                let cx = (Float(px) + 0.5) - r
                guard cx < 0 else { continue }
                let outside = Self.outsideFraction(squareX: cx / r, squareY: cy / r, radiusPx: r)
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
                let cx = (Float(px) + 0.5) - (Float(w) - r)
                guard cx > 0 else { continue }
                let outside = Self.outsideFraction(squareX: cx / r, squareY: cy / r, radiusPx: r)
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

    /// GLSL 330 core fragment shader matching `crates/rune/src/render/csd_corners.rs`.
    public static let glslFragmentSource: String = """
    #version 330 core
    in vec2 v_square;
    flat in float v_radius;
    out vec4 out_color;
    void main() {
        float dist = length(v_square) * v_radius;
        float outside = smoothstep(v_radius - 0.5, v_radius + 0.5, dist);
        if (outside <= 0.0) discard;
        out_color = vec4(0.0, 0.0, 0.0, outside);
    }
    """

    /// WGSL shader matching `crates/rune/src/render/csd_corners.rs`.
    public static let wgslSource: String = """
    struct Vertex {
        @builtin(position) at: vec4<f32>,
        @location(0) square: vec2<f32>,
        @location(1) @interpolate(flat) radius: f32,
    };
    @vertex fn vs(@location(0) at: vec2<f32>, @location(1) square: vec2<f32>, @location(2) radius: f32) -> Vertex {
        return Vertex(vec4(at, 0.0, 1.0), square, radius);
    }
    @fragment fn fs(frag: Vertex) -> @location(0) vec4<f32> {
        let distance = length(frag.square) * frag.radius;
        let outside = smoothstep(frag.radius - 0.5, frag.radius + 0.5, distance);
        if outside <= 0.0 {
            discard;
        }
        return vec4(0.0, 0.0, 0.0, outside);
    }
    """
}
