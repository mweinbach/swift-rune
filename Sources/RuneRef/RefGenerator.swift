import Foundation

/// Deterministic scene generator for property-based and differential testing.
///
/// Mirrors upstream `rune-ref/src/generate.rs` adapted to `RuneRef`'s `[x, y, w, h]` clip
/// and straight-alpha `Primitive` conventions.
public enum RefGenerator {
    /// Sentinel clip covering the entire coordinate space.
    public static let noClip = SIMD4<Float>(-1e6, -1e6, 2e6, 2e6)

    /// Builds a deterministic `64x64` `RefScene` from 32-byte records (at most 32 primitives).
    public static func scene(from records: [[UInt8]]) -> RefScene {
        var atlas = R8Atlas(width: 32, height: 32)
        for n in 0..<1024 {
            atlas.texels[n] = UInt8((n * 73 + (n / 32) * 19) % 256)
        }

        var primitives: [Primitive] = []
        for b in records.prefix(32) {
            guard b.count >= 32 else { continue }
            let a = Float(b[9]) / 255.0
            func color(_ start: Int) -> SIMD4<Float> {
                SIMD4<Float>(
                    Float(b[start]) / 255.0,
                    Float(b[start + 1]) / 255.0,
                    Float(b[start + 2]) / 255.0,
                    a
                )
            }

            let kindRaw = Int(b[0] % 5)
            let rect = SIMD4<Float>(
                Float(b[1]) / 4.0 - 8.0,
                Float(b[2]) / 4.0 - 8.0,
                1.0 + Float(b[3] % 128) / 4.0,
                1.0 + Float(b[4] % 128) / 4.0
            )
            var radii = SIMD4<Float>(
                Float(b[20]) / 8.0,
                Float(b[21]) / 8.0,
                Float(b[22]) / 8.0,
                Float(b[23]) / 8.0
            )
            var clip = noClip
            var fade = SIMD4<Float>.zero
            let fadeOrigin = SIMD2<Float>.zero
            if (b[16] & 1) != 0 {
                clip = SIMD4<Float>(
                    Float(b[17]) / 8.0,
                    Float(b[18]) / 8.0,
                    24.0 + Float(b[19]) / 8.0,
                    24.0 + Float(b[24]) / 8.0
                )
                fade = SIMD4<Float>.zero
            }

            switch kindRaw {
            case 0:
                primitives.append(.roundedRect(
                    rect: rect,
                    radii: radii,
                    fill: color(6),
                    borderColor: color(10),
                    borderWidth: Float(b[13]) / 32.0,
                    clip: clip
                ))
            case 1:
                radii = SIMD4<Float>(repeating: radii.x)
                primitives.append(.dropShadow(
                    rect: rect,
                    radii: radii,
                    color: color(6),
                    blur: Float(b[14]) / 16.0,
                    offset: .zero,
                    clip: clip
                ))
            case 2:
                let gw = 1.0 + Float(b[3] % 24)
                let gh = 1.0 + Float(b[4] % 24)
                let scale: Float = (b[16] & 2) != 0 ? (0.5 + Float(b[29] % 8) / 4.0) : 1.0
                let gRect = SIMD4<Float>(rect.x, rect.y, gw * scale, gh * scale)
                let u0: Float = 1.0 / 32.0
                let v0: Float = 1.0 / 32.0
                let u1: Float = min(1.0, (1.0 + gw) / 32.0)
                let v1: Float = min(1.0, (1.0 + gh) / 32.0)
                primitives.append(.glyph(
                    rect: gRect,
                    uv: SIMD4<Float>(u0, v0, u1, v1),
                    color: color(6),
                    gamma: 0.7 + Float(b[15]) / 255.0,
                    clip: clip
                ))
            case 3:
                let ox = Float(b[30]) / 32.0 - 4.0
                let oy = Float(b[31]) / 32.0 - 4.0
                primitives.append(.insetShadow(
                    rect: rect,
                    radii: radii,
                    color: color(6),
                    blur: Float(b[14]) / 16.0,
                    spread: Float(b[13]) / 32.0,
                    offset: SIMD2<Float>(ox, oy),
                    clip: clip
                ))
            default:
                primitives.append(.linearGradient(
                    rect: rect,
                    radii: radii,
                    topColor: color(6),
                    bottomColor: color(29),
                    borderWidth: Float(b[13]) / 32.0,
                    clip: clip
                ))
            }
            _ = fade
            _ = fadeOrigin
        }

        return RefScene(
            width: 64,
            height: 64,
            srgbBlend: false,
            clearColor: SIMD4<Float>(0.025, 0.04, 0.06, 1.0),
            glyphs: atlas,
            primitives: primitives
        )
    }

    /// Stable SplitMix64 corpus generator.
    public static func seeded(seed: UInt64, count: Int) -> RefScene {
        var state = seed
        let capped = min(max(0, count), 32)
        var records: [[UInt8]] = []
        records.reserveCapacity(capped)
        for _ in 0..<capped {
            var rec = [UInt8](repeating: 0, count: 32)
            for i in 0..<32 {
                state &+= 0x9e37_79b9_7f4a_7c15
                var z = state
                z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
                z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
                rec[i] = UInt8(truncatingIfNeeded: z ^ (z >> 31))
            }
            records.append(rec)
        }
        return scene(from: records)
    }

    /// Generates a seeded scene where every primitive is a dashed border ring.
    public static func dashed(seed: UInt64, count: Int) -> RefScene {
        var s = seeded(seed: seed, count: count)
        s.primitives = s.primitives.map { p in
            let b: (Int) -> UInt32 = { n in
                UInt32(max(0, Int((p.radii[n % 4] * 8.0 + p.rect[n % 4] * 4.0).rounded())))
            }
            let bw = 0.5 + Float(b(0) % 8) * 0.25
            let dash = 1.0 + Float(b(2) % 24) * 0.5
            let gap = 1.0 + Float(b(3) % 16) * 0.5
            let phase = Float(b(1) % 32) * 0.75 - 6.0
            return .dashedRing(
                rect: p.rect,
                radii: p.radii,
                color: p.fill,
                borderWidth: bw,
                dashLength: dash,
                gapLength: gap,
                phase: phase,
                clip: p.clip
            )
        }
        return s
    }

    /// Translates all primitives and non-sentinel clip rects in `scene` by `(dx, dy)`.
    public static func translate(_ scene: inout RefScene, dx: Float, dy: Float) {
        for i in scene.primitives.indices {
            scene.primitives[i].rect.x += dx
            scene.primitives[i].rect.y += dy
            if scene.primitives[i].clip != noClip {
                scene.primitives[i].clip.x += dx
                scene.primitives[i].clip.y += dy
            }
            switch scene.primitives[i].kind {
            case .dropShadow:
                if scene.primitives[i].border.z > 0 && scene.primitives[i].border.w > 0 {
                    scene.primitives[i].border.x += dx
                    scene.primitives[i].border.y += dy
                }
            case .segment:
                scene.primitives[i].uv.x += dx
                scene.primitives[i].uv.y += dy
                scene.primitives[i].uv.z += dx
                scene.primitives[i].uv.w += dy
            case .triangle:
                scene.primitives[i].uv.x += dx
                scene.primitives[i].uv.y += dy
                scene.primitives[i].uv.z += dx
                scene.primitives[i].uv.w += dy
                scene.primitives[i].fadeOrigin.x += dx
                scene.primitives[i].fadeOrigin.y += dy
            case .multiGradient:
                scene.primitives[i].uv.x += dx
                scene.primitives[i].uv.y += dy
            default:
                break
            }
            if scene.primitives[i].fade.z != 0 {
                scene.primitives[i].fadeOrigin.x += dx
                scene.primitives[i].fadeOrigin.y += dy
            }
        }
    }
}
