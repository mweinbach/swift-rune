import Foundation

/// Upstream `rune-ref` oracle constant (`NO_CLIP`).
public let oracleNoClip: [Float] = [-1e6, -1e6, 1e6, 1e6]

/// Errors thrown by `OracleScene.validate()` matching upstream `Scene::validate()`.
public enum OracleValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case message(String)

    public var description: String {
        switch self {
        case .message(let msg): return msg
        }
    }
}

/// Faithful port of `rune_ref::Primitive` with JSON replay schema parity (`node`, `source`, `fade_origin`, `turn`).
public struct OraclePrimitive: Codable, Sendable, Equatable {
    public var node: UInt32
    public var source: String
    public var rect: [Float]
    public var radii: [Float]
    public var fill: [Float]
    /// Border paint; for a layer (kind 8), signed per-corner clip radii `[tl, tr, br, bl]`.
    public var border: [Float]
    public var params: [Float]
    public var uv: [Float]
    /// Scissor box `[x0, y0, x1, y1]` in device pixels.
    public var clip: [Float]
    public var fade: [Float]
    public var fadeOrigin: [Float]?
    /// For a layer (kind 8), `[turn, pivot_x, pivot_y]`.
    public var turn: [Float]?

    enum CodingKeys: String, CodingKey {
        case node, source, rect, radii, fill, border, params, uv, clip, fade
        case fadeOrigin = "fade_origin"
        case turn
    }

    public init(
        node: UInt32,
        source: String,
        rect: [Float],
        radii: [Float],
        fill: [Float],
        border: [Float],
        params: [Float],
        uv: [Float],
        clip: [Float],
        fade: [Float],
        fadeOrigin: [Float]? = nil,
        turn: [Float]? = nil
    ) {
        self.node = node
        self.source = source
        self.rect = rect
        self.radii = radii
        self.fill = fill
        self.border = border
        self.params = params
        self.uv = uv
        self.clip = clip
        self.fade = fade
        self.fadeOrigin = fadeOrigin
        self.turn = turn
    }

    /// Converts a Swift `RuneRef.Primitive` (straight alpha, `[x, y, w, h]` clip) into an `OraclePrimitive`.
    public static func fromInstance(_ p: Primitive, node: UInt32 = 0, source: String = "") -> OraclePrimitive {
        func premul(_ v: SIMD4<Float>) -> [Float] {
            let a = min(max(v.w, 0), 1)
            return [v.x * a, v.y * a, v.z * a, a]
        }
        let clipBox: [Float] = if p.clip == RefGenerator.noClip {
            oracleNoClip
        } else {
            [p.clip.x, p.clip.y, p.clip.x + p.clip.z, p.clip.y + p.clip.w]
        }
        let fadeArr: [Float] = [p.fade.x, p.fade.y, p.fade.z, p.fade.w]
        let originArr: [Float]? = p.fade.z != 0 ? [p.fadeOrigin.x, p.fadeOrigin.y, p.fadeOrigin.x, p.fadeOrigin.y] : nil
        let isLayer = p.params.y == 8.0
        let turnArr: [Float]? = (isLayer && p.turn != 0)
            ? [p.turn, p.rect.x + p.rect.z * 0.5, p.rect.y + p.rect.w * 0.5]
            : nil
        let borderArr = isLayer ? [0, 0, 0, 0] : premul(p.border)
        let uvArr = p.params.y == 4.0 ? premul(p.border) : [p.uv.x, p.uv.y, p.uv.z, p.uv.w]
        return OraclePrimitive(
            node: node,
            source: source,
            rect: [p.rect.x, p.rect.y, p.rect.z, p.rect.w],
            radii: [p.radii.x, p.radii.y, p.radii.z, p.radii.w],
            fill: premul(p.fill),
            border: borderArr,
            params: [p.params.x, p.params.y, p.params.z, p.params.w],
            uv: uvArr,
            clip: clipBox,
            fade: fadeArr,
            fadeOrigin: originArr,
            turn: turnArr
        )
    }

    /// Converts this `OraclePrimitive` into a Swift `RuneRef.Primitive` for `MetalRenderer` interop.
    public func toInstance() -> Primitive {
        func unpremul(_ c: [Float]) -> SIMD4<Float> {
            guard c.count == 4 else { return .zero }
            let a = min(max(c[3], 0), 1)
            if a <= 1e-6 { return .zero }
            return SIMD4<Float>(min(1, c[0] / a), min(1, c[1] / a), min(1, c[2] / a), a)
        }
        let kind = params.count > 1 ? params[1] : 0
        let clipRect: SIMD4<Float> = if clip == oracleNoClip {
            RefGenerator.noClip
        } else if clip.count == 4 {
            SIMD4<Float>(clip[0], clip[1], max(0, clip[2] - clip[0]), max(0, clip[3] - clip[1]))
        } else {
            RefGenerator.noClip
        }
        let isLinearGrad = kind == 4.0
        let borderOut = isLinearGrad ? unpremul(uv) : unpremul(border)
        return Primitive(
            rect: SIMD4<Float>(rect[0], rect[1], rect[2], rect[3]),
            radii: SIMD4<Float>(radii[0], radii[1], radii[2], radii[3]),
            fill: unpremul(fill),
            border: borderOut,
            params: SIMD4<Float>(params[0], params[1], params[2], params[3]),
            uv: SIMD4<Float>(uv[0], uv[1], uv[2], uv[3]),
            clip: clipRect,
            fade: SIMD4<Float>(fade[0], fade[1], fade[2], fade[3]),
            fadeOrigin: fadeOrigin.map { SIMD2<Float>($0[0], $0[1]) } ?? .zero,
            turn: turn?.first ?? 0
        )
    }

    /// IEEE-754 binary32 -> binary16 -> binary32 round-to-nearest-even (matches `half::f16::from_f32`).
    public static func float32To16Bits(_ value: Float) -> UInt16 {
        let f = value.bitPattern
        let sign = UInt16((f >> 16) & 0x8000)
        let exp = Int((f >> 23) & 0xFF) - 127 + 15
        var mantissa = f & 0x007F_FFFF

        if exp <= 0 {
            if exp < -10 { return sign }
            mantissa = (mantissa | 0x0080_0000) >> (1 - exp)
            let roundBit = mantissa & 0x1000
            if roundBit != 0 && ((mantissa & 0x2FFF) != 0) {
                mantissa += 0x2000
            }
            return sign | UInt16(mantissa >> 13)
        } else if exp == 0xFF - 127 + 15 {
            if mantissa == 0 {
                return sign | 0x7C00
            }
            let nanPayload = UInt16(mantissa >> 13)
            return sign | 0x7C00 | (nanPayload == 0 ? 1 : nanPayload)
        } else if exp > 30 {
            return sign | 0x7C00
        }

        let roundBit = mantissa & 0x1000
        if roundBit != 0 && ((mantissa & 0x0FFF) != 0 || ((mantissa >> 13) & 1) != 0) {
            mantissa += 0x2000
            if (mantissa & 0x0080_0000) != 0 {
                mantissa = 0
                let newExp = exp + 1
                if newExp > 30 { return sign | 0x7C00 }
                return sign | UInt16(newExp << 10)
            }
        }
        return sign | UInt16(exp << 10) | UInt16(mantissa >> 13)
    }

    public static func float16BitsTo32(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exp = UInt32((h >> 10) & 0x1F)
        let frac = UInt32(h & 0x03FF)
        if exp == 0 {
            if frac == 0 { return Float(bitPattern: sign) }
            var e = 127 - 15 + 1
            var m = frac
            while (m & 0x0400) == 0 {
                m <<= 1
                e -= 1
            }
            m &= 0x03FF
            return Float(bitPattern: sign | (UInt32(e) << 23) | (m << 13))
        } else if exp == 31 {
            return Float(bitPattern: sign | 0x7F80_0000 | (frac << 13))
        }
        return Float(bitPattern: sign | ((exp + (127 - 15)) << 23) | (frac << 13))
    }

    /// Upstream `rune::render::pack_fade`.
    public static func packFade(width: [Float], origin: [Float], clip: [Float]) -> [UInt32] {
        var halves: [UInt32] = [0, 0, 0, 0]
        var offsets: UInt32 = 0
        for edge in 0..<4 {
            let clamped = min(max(width[edge], -65504.0), 65504.0)
            halves[edge] = UInt32(float32To16Bits(clamped))
            let distance = edge < 2 ? (clip[edge] - origin[edge]) : (origin[edge] - clip[edge])
            let w = abs(width[edge])
            let offset = w > 0.0 ? min(max(distance / w, 0.0), 1.0) : 0.0
            offsets |= UInt32(offset * 255.0 + 0.5) << UInt32(edge * 8)
        }
        return [halves[0] | (halves[1] << 16), halves[2] | (halves[3] << 16), offsets, 0]
    }

    /// Upstream `rune::render::unpack_fade`.
    public static func unpackFade(_ fade: [UInt32]) -> (width: [Float], offset: [Float]) {
        var widths: [Float] = []
        var offsets: [Float] = []
        widths.reserveCapacity(4)
        offsets.reserveCapacity(4)
        for e in 0..<4 {
            let bits = UInt16(truncatingIfNeeded: fade[e / 2] >> UInt32((e % 2) * 16))
            widths.append(float16BitsTo32(bits))
            offsets.append(Float((fade[2] >> UInt32(e * 8)) & 255) / 255.0)
        }
        return (widths, offsets)
    }

    /// Upstream `rune::render::pack_clip_radii`.
    public static func packClipRadii(clip: [Float], radii: [Float]) -> UInt32 {
        let half = max(0.0, min(clip[2] - clip[0], clip[3] - clip[1]) * 0.5)
        let cap = Float(bitPattern: 0x5FFF_FFFF)
        let clamped: [Float] = radii.map { radius in
            let r = min(min(abs(radius), half), cap)
            return (radius < 0.0 && r > 0.0) ? -r : r
        }
        if clamped[0] == clamped[1] && clamped[1] == clamped[2] && clamped[2] == clamped[3] {
            return clamped[0] == 0.0 ? 0 : clamped[0].bitPattern
        }
        let continuous = clamped.contains { $0 < 0.0 }
        let maxR = clamped.reduce(0.0) { max($0, abs($1)) }
        let coarse = maxR > 63.5
        let invStep: Float = coarse ? 0.5 : 2.0
        var bits: UInt32 = 0x6000_0000
            | (continuous ? 0x8000_0000 : 0)
            | (coarse ? 0x1000_0000 : 0)
        for idx in 0..<4 {
            let q = min(127, UInt32((abs(clamped[idx]) * invStep).rounded()))
            bits |= q << UInt32(idx * 7)
        }
        return bits
    }

    /// Upstream `rune::render::unpack_clip_radii`.
    public static func unpackClipRadii(_ w: UInt32) -> [Float] {
        if w == 0 { return [0, 0, 0, 0] }
        if (w & 0x6000_0000) != 0x6000_0000 {
            let v = Float(bitPattern: w)
            return [v, v, v, v]
        }
        let step: Float = (w & 0x1000_0000) != 0 ? 2.0 : 0.5
        let sign: Float = (w & 0x8000_0000) != 0 ? -1.0 : 1.0
        return (0..<4).map { idx in
            let q = (w >> UInt32(idx * 7)) & 0x7F
            return q == 0 ? 0.0 : Float(q) * step * sign
        }
    }
}

/// Faithful port of `rune_ref::Atlas`.
public struct OracleAtlas: Codable, Sendable, Equatable {
    public var width: UInt32
    public var height: UInt32
    public var data: [UInt8]

    public init(width: UInt32, height: UInt32, data: [UInt8]) {
        self.width = width
        self.height = height
        self.data = data
    }

    @inline(__always)
    func load(_ x: Int32, _ y: Int32) -> Float {
        if x < 0 || y < 0 || x >= Int32(width) || y >= Int32(height) {
            return 0.0
        }
        return Float(data[Int(UInt32(y) * width + UInt32(x))]) / 255.0
    }
}

/// Faithful port of `rune_ref::Scene` supporting JSON replay (`serde_json` schema).
public struct OracleScene: Codable, Sendable, Equatable {
    public static let maxLayerDepth = 16

    public var width: UInt32
    public var height: UInt32
    public var clear: [Float]
    public var primitives: [OraclePrimitive]
    public var atlas: OracleAtlas

    public init(width: UInt32, height: UInt32, clear: [Float], primitives: [OraclePrimitive], atlas: OracleAtlas) {
        self.width = width
        self.height = height
        self.clear = clear
        self.primitives = primitives
        self.atlas = atlas
    }

    public func validate() throws {
        if width == 0 || height == 0 || width > 4096 || height > 4096 {
            throw OracleValidationError.message("viewport must be 1..=4096")
        }
        if primitives.count > 65536
            || atlas.width == 0
            || atlas.height == 0
            || atlas.width > 2048
            || atlas.height > 2048
            || atlas.data.count != Int(atlas.width) * Int(atlas.height)
        {
            throw OracleValidationError.message("invalid atlas or primitive count")
        }
        func isValidColor(_ c: [Float]) -> Bool {
            guard c.count == 4 else { return false }
            guard c.allSatisfy({ $0.isFinite && $0 >= 0.0 && $0 <= 1.0 }) else { return false }
            return c[0] <= c[3] && c[1] <= c[3] && c[2] <= c[3]
        }
        if !isValidColor(clear) {
            throw OracleValidationError.message("clear must be premultiplied linear RGBA")
        }
        var layerDepth = 0
        for p in primitives {
            guard p.rect.count == 4, p.radii.count == 4, p.fill.count == 4, p.border.count == 4,
                  p.params.count == 4, p.uv.count == 4, p.clip.count == 4, p.fade.count == 4 else {
                throw OracleValidationError.message("invalid primitive \(p.node) (\(p.source))")
            }
            if let fo = p.fadeOrigin, fo.count != 4 {
                throw OracleValidationError.message("invalid primitive \(p.node) (\(p.source))")
            }
            if let t = p.turn, t.count != 3 {
                throw OracleValidationError.message("invalid primitive \(p.node) (\(p.source))")
            }

            if p.params[1] == 8.0 {
                if layerDepth == Self.maxLayerDepth || p.params[2] != 0.0 {
                    throw OracleValidationError.message("unsupported layer \(p.node) (\(p.source))")
                }
                let p0ok = p.params[0] == 0.0 || p.params[0] == 1.0
                let p3ok = p.params[3] == 0.0 || p.params[3] == 1.0
                let cachedBad = p.params[3] == 1.0 && (p.radii + p.uv).contains {
                    !$0.isFinite || $0 < 0.0 || $0 > 65535.0 || $0.truncatingRemainder(dividingBy: 1.0) != 0.0
                }
                if !p0ok || !p3ok || cachedBad {
                    throw OracleValidationError.message("invalid layer \(p.node) (\(p.source))")
                }
                layerDepth += 1
            } else if p.params[1] == 9.0 {
                if layerDepth == 0 {
                    throw OracleValidationError.message("unbalanced layer end \(p.node) (\(p.source))")
                }
                layerDepth -= 1
            }

            let allScalars = p.rect + p.radii + p.fill + p.border + p.params + p.uv + p.clip + p.fade + (p.fadeOrigin ?? p.clip)
            let anyOutOfRange = allScalars.contains { !$0.isFinite || abs($0) > 1e6 }
            let kindInt = Int(p.params[1])
            let validKind = [0, 1, 2, 3, 4, 8, 9, 10, 11, 12].contains(where: { p.params[1] == Float($0) })
            let badEmptySize = !(kindInt == 9 || kindInt == 12) && (p.rect[2] <= 0.0 || p.rect[3] <= 0.0)
            let badNegativeSize = p.rect[2] < 0.0 || p.rect[3] < 0.0
            let badRadii = (p.params[1] != 8.0 && p.radii.contains { $0 < 0.0 })
                || (p.params[1] == 8.0 && p.params[3] == 0.0 && (p.radii[2] < 0.0 || p.radii[3] < p.radii[2]))
            let badParams = (p.params[0] < 0.0 && p.params[1] != 2.0) || p.params[2] < 0.0
            let badBorder: Bool = if p.params[1] == 8.0 {
                p.border.contains { $0 < 0.0 } && p.border.contains { $0 > 0.0 }
            } else {
                !isValidColor(p.border)
            }
            let badTurn = p.turn.map { t in
                p.params[1] != 8.0
                    || p.params[3] == 1.0
                    || t[0] == 0.0
                    || t.contains { !$0.isFinite || abs($0) > 1e6 }
            } ?? false
            let badKind4 = p.params[1] == 4.0 && !isValidColor(p.uv)
            let badKind10 = p.params[1] == 10.0 && (p.uv[0] <= 0.0 || p.uv[1] <= 0.0)
            let badKind11 = p.params[1] == 11.0 && (p.uv[2] < 0.0 || p.uv[3] < 0.0 || ((p.uv[2] > 0.0) != (p.uv[3] > 0.0)))
            let badKind2 = p.params[1] == 2.0 && (p.params[3] <= 0.0 || p.uv.contains { $0 < 0.0 })

            if anyOutOfRange || badEmptySize || badNegativeSize || badRadii || !validKind
                || badParams || !isValidColor(p.fill) || badBorder || badTurn
                || badKind4 || badKind10 || badKind11 || badKind2 {
                throw OracleValidationError.message("invalid primitive \(p.node) (\(p.source))")
            }
        }
        if layerDepth != 0 {
            throw OracleValidationError.message("unclosed layer scope")
        }
    }

    /// Converts an upstream `OracleScene` into a `RefScene` for Swift `MetalRenderer` execution.
    public func toRefScene() -> RefScene {
        let ca = clear.count == 4 ? min(max(clear[3], 0), 1) : 1
        let clearStraight: SIMD4<Float> = if ca > 1e-6 {
            SIMD4<Float>(min(1, clear[0] / ca), min(1, clear[1] / ca), min(1, clear[2] / ca), ca)
        } else {
            .zero
        }
        return RefScene(
            width: Int(width),
            height: Int(height),
            srgbBlend: false,
            clearColor: clearStraight,
            glyphs: R8Atlas(width: Int(atlas.width), height: Int(atlas.height), texels: atlas.data),
            primitives: primitives.map { $0.toInstance() }
        )
    }
}

/// Faithful port of `rune_ref::Frame` with per-operation sRGB quantization, layer turns, provenance, and BLAKE3 hashing.
public struct OracleFrame: Sendable, Equatable {
    public let width: UInt32
    public let height: UInt32
    public var rgba: [UInt8]
    public var owners: [Int?]?

    public init(width: UInt32, height: UInt32, provenance: Bool = true) {
        precondition(width > 0 && height > 0 && width <= 4096 && height <= 4096)
        self.width = width
        self.height = height
        let n = Int(width) * Int(height)
        self.rgba = [UInt8](repeating: 0, count: n * 4)
        self.owners = provenance ? [Int?](repeating: nil, count: n) : nil
    }

    public mutating func render(_ scene: OracleScene) {
        precondition(width == scene.width && height == scene.height)
        let clear = Self.encode(scene.clear)
        let n = Int(width) * Int(height)
        for i in 0..<n {
            let base = i * 4
            rgba[base] = clear[0]
            rgba[base + 1] = clear[1]
            rgba[base + 2] = clear[2]
            rgba[base + 3] = clear[3]
        }
        if owners != nil {
            owners = [Int?](repeating: nil, count: n)
        }
        Self.renderRange(
            width: width,
            height: height,
            rgba: &rgba,
            owners: &owners,
            scene: scene,
            cursorStart: 0,
            end: scene.primitives.count
        )
    }

    private static func renderRange(
        width: UInt32,
        height: UInt32,
        rgba: inout [UInt8],
        owners: inout [Int?]?,
        scene: OracleScene,
        cursorStart: Int,
        end: Int
    ) {
        var cursor = cursorStart
        while cursor < end {
            let p = scene.primitives[cursor]
            if p.params[1] == 8.0 {
                var depth = 1
                var close = cursor + 1
                while close < end && depth > 0 {
                    if scene.primitives[close].params[1] == 8.0 {
                        depth += 1
                    } else if scene.primitives[close].params[1] == 9.0 {
                        depth -= 1
                    }
                    if depth > 0 {
                        close += 1
                    }
                }
                if p.params[3] == 0.0 && p.fill[3] == 1.0 && p.params[0] == 0.0 && p.params[2] == 0.0
                    && p.clip == oracleNoClip && p.border == [0, 0, 0, 0] && p.radii[3] == 0.0 && p.turn == nil
                {
                    renderRange(width: width, height: height, rgba: &rgba, owners: &owners, scene: scene, cursorStart: cursor + 1, end: close)
                } else if p.fill[3] > 0.0 {
                    var layerRgba = [UInt8](repeating: 0, count: Int(width) * Int(height) * 4)
                    var layerOwners: [Int?]? = owners != nil ? [Int?](repeating: nil, count: Int(width) * Int(height)) : nil
                    renderRange(width: width, height: height, rgba: &layerRgba, owners: &layerOwners, scene: scene, cursorStart: cursor + 1, end: close)

                    let activeTurn: (Float, Float, [Float])? = p.turn.flatMap { t in
                        t[0] != 0.0 ? (sinf(t[0]), cosf(t[0]), [t[1], t[2]]) : nil
                    }
                    let x0: UInt32
                    let y0: UInt32
                    let x1: UInt32
                    let y1: UInt32
                    if activeTurn != nil {
                        x0 = 0; y0 = 0; x1 = width; y1 = height
                    } else {
                        x0 = UInt32(max(0.0, floorf(p.rect[0])))
                        y0 = UInt32(max(0.0, floorf(p.rect[1])))
                        x1 = min(width, UInt32(max(0.0, ceilf(p.rect[0] + p.rect[2]))))
                        y1 = min(height, UInt32(max(0.0, ceilf(p.rect[1] + p.rect[3]))))
                    }
                    let alpha = min(max(p.fill[3], 0.0), 1.0)
                    for y in y0..<y1 {
                        for x in x0..<x1 {
                            let cov = alpha * OracleShader.layerClipCoverage(p, screen: (Float(x) + 0.5, Float(y) + 0.5))
                            if cov <= 0.0 { continue }
                            let at = Int(y * width + x)
                            let src: (Float, Float, Float, Float)
                            if let (sn, cs, pivot) = activeTurn {
                                let qx = Float(x) + 0.5 - pivot[0]
                                let qy = Float(y) + 0.5 - pivot[1]
                                let ux = pivot[0] + cs * qx + sn * qy - 0.5
                                let uy = pivot[1] + cs * qy - sn * qx - 0.5
                                let bx = floorf(ux)
                                let by = floorf(uy)
                                let fx = ux - bx
                                let fy = uy - by
                                @inline(__always)
                                func texel(_ tx: Float, _ ty: Float) -> (Float, Float, Float, Float) {
                                    if tx < 0.0 || ty < 0.0 || tx >= Float(width) || ty >= Float(height) {
                                        return (0, 0, 0, 0)
                                    }
                                    let idx = Int(UInt32(ty) * width + UInt32(tx)) * 4
                                    return decode4(layerRgba[idx], layerRgba[idx + 1], layerRgba[idx + 2], layerRgba[idx + 3])
                                }
                                let a = texel(bx, by)
                                let b = texel(bx + 1.0, by)
                                let c = texel(bx, by + 1.0)
                                let d = texel(bx + 1.0, by + 1.0)
                                let omfx = 1.0 - fx
                                let omfy = 1.0 - fy
                                src = (
                                    (a.0 * omfx + b.0 * fx) * omfy + (c.0 * omfx + d.0 * fx) * fy,
                                    (a.1 * omfx + b.1 * fx) * omfy + (c.1 * omfx + d.1 * fx) * fy,
                                    (a.2 * omfx + b.2 * fx) * omfy + (c.2 * omfx + d.2 * fx) * fy,
                                    (a.3 * omfx + b.3 * fx) * omfy + (c.3 * omfx + d.3 * fx) * fy
                                )
                            } else {
                                let idx = at * 4
                                src = decode4(layerRgba[idx], layerRgba[idx + 1], layerRgba[idx + 2], layerRgba[idx + 3])
                            }
                            let col = (src.0 * cov, src.1 * cov, src.2 * cov, src.3 * cov)
                            if col.3 <= 0.0 { continue }
                            let idx = at * 4
                            let dst = decode4(rgba[idx], rgba[idx + 1], rgba[idx + 2], rgba[idx + 3])
                            let out: (Float, Float, Float, Float)
                            if p.params[0] == 1.0 {
                                out = (col.0 + dst.0, col.1 + dst.1, col.2 + dst.2, col.3 + dst.3)
                            } else {
                                let invA = 1.0 - col.3
                                out = (col.0 + dst.0 * invA, col.1 + dst.1 * invA, col.2 + dst.2 * invA, col.3 + dst.3 * invA)
                            }
                            let enc = encode4(out.0, out.1, out.2, out.3)
                            rgba[idx] = enc.0
                            rgba[idx + 1] = enc.1
                            rgba[idx + 2] = enc.2
                            rgba[idx + 3] = enc.3
                            if owners != nil, let lOwners = layerOwners {
                                owners![at] = lOwners[at] ?? cursor
                            }
                        }
                    }
                }
                cursor = close + 1
                continue
            }
            if p.params[1] == 9.0 {
                cursor += 1
                continue
            }
            for y in 0..<height {
                let fy = Float(y) + 0.5
                for x in 0..<width {
                    let col = OracleShader.fragment(p, atlas: scene.atlas, screen: (Float(x) + 0.5, fy))
                    if col.3 <= 0.0 { continue }
                    let at = Int(y * width + x)
                    let idx = at * 4
                    let dst = decode4(rgba[idx], rgba[idx + 1], rgba[idx + 2], rgba[idx + 3])
                    let invA = 1.0 - col.3
                    let enc = encode4(
                        col.0 + dst.0 * invA,
                        col.1 + dst.1 * invA,
                        col.2 + dst.2 * invA,
                        col.3 + dst.3 * invA
                    )
                    rgba[idx] = enc.0
                    rgba[idx + 1] = enc.1
                    rgba[idx + 2] = enc.2
                    rgba[idx + 3] = enc.3
                    if owners != nil {
                        owners![at] = cursor
                    }
                }
            }
            cursor += 1
        }
    }

    public func hash() -> String {
        Blake3.hashHex(rgba)
    }

    public func blame(_ scene: OracleScene, x: UInt32, y: UInt32) -> OraclePrimitive? {
        guard x < width, y < height, let owners else { return nil }
        guard let index = owners[Int(y * width + x)] else { return nil }
        guard index >= 0 && index < scene.primitives.count else { return nil }
        return scene.primitives[index]
    }

    @inline(__always)
    static func encode(_ c: [Float]) -> [UInt8] {
        let q = encode4(c[0], c[1], c[2], c[3])
        return [q.0, q.1, q.2, q.3]
    }

    @inline(__always)
    private static func encodeChannel(_ raw: Float, isAlpha: Bool) -> UInt8 {
        let clamped = min(max(raw, 0.0), 1.0)
        let encoded: Float
        if isAlpha {
            encoded = clamped
        } else if clamped <= 0.0031308 {
            encoded = clamped * 12.92
        } else {
            encoded = 1.055 * powf(clamped, 1.0 / 2.4) - 0.055
        }
        return UInt8(roundf(encoded * 255.0))
    }

    @inline(__always)
    private static func encode4(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> (UInt8, UInt8, UInt8, UInt8) {
        (
            encodeChannel(r, isAlpha: false),
            encodeChannel(g, isAlpha: false),
            encodeChannel(b, isAlpha: false),
            encodeChannel(a, isAlpha: true)
        )
    }

    @inline(__always)
    private static func decodeChannel(_ byte: UInt8, isAlpha: Bool) -> Float {
        let v = Float(byte) / 255.0
        if isAlpha { return v }
        if v <= 0.04045 { return v / 12.92 }
        return powf((v + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    private static func decode4(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> (Float, Float, Float, Float) {
        (
            decodeChannel(r, isAlpha: false),
            decodeChannel(g, isAlpha: false),
            decodeChannel(b, isAlpha: false),
            decodeChannel(a, isAlpha: true)
        )
    }
}

public struct OraclePixelBlame: Codable, Sendable, Equatable {
    public var x: UInt32
    public var y: UInt32
    public var expected: [UInt8]
    public var actual: [UInt8]
    public var node: UInt32?
    public var source: String?
}

public struct OracleDifference: Codable, Sendable, Equatable {
    public var maxChannel: UInt8
    public var outlierPixels: Int
    public var first: OraclePixelBlame?

    enum CodingKeys: String, CodingKey {
        case maxChannel = "max_channel"
        case outlierPixels = "outlier_pixels"
        case first
    }
}

public enum Oracle {
    /// Strict per-channel gate matching `rune_ref::compare`.
    public static func compare(scene: OracleScene, cpu: OracleFrame, gpu: [UInt8], tolerance: UInt8) -> OracleDifference {
        precondition(cpu.rgba.count == gpu.count)
        var diff = OracleDifference(maxChannel: 0, outlierPixels: 0, first: nil)
        let pixelCount = gpu.count / 4
        for at in 0..<pixelCount {
            let base = at * 4
            let a = [cpu.rgba[base], cpu.rgba[base + 1], cpu.rgba[base + 2], cpu.rgba[base + 3]]
            let b = [gpu[base], gpu[base + 1], gpu[base + 2], gpu[base + 3]]
            let d = max(
                max(UInt8(abs(Int(a[0]) - Int(b[0]))), UInt8(abs(Int(a[1]) - Int(b[1])))),
                max(UInt8(abs(Int(a[2]) - Int(b[2]))), UInt8(abs(Int(a[3]) - Int(b[3]))))
            )
            diff.maxChannel = max(diff.maxChannel, d)
            if d <= tolerance { continue }
            diff.outlierPixels += 1
            if diff.first == nil {
                let x = UInt32(at) % cpu.width
                let y = UInt32(at) / cpu.width
                let p = cpu.blame(scene, x: x, y: y)
                diff.first = OraclePixelBlame(
                    x: x,
                    y: y,
                    expected: a,
                    actual: b,
                    node: p?.node,
                    source: p?.source
                )
            }
        }
        return diff
    }
}
