import Foundation

/// Faithful port of `crates/rune-ref/src/generate.rs` for `OracleScene`.
public enum OracleGenerator {
    public static func scene(records: [[UInt8]]) -> OracleScene {
        var atlasData: [UInt8] = []
        atlasData.reserveCapacity(1024)
        for n in 0..<1024 {
            atlasData.append(UInt8((n * 73 + (n / 32) * 19) % 256))
        }
        var primitives: [OraclePrimitive] = []
        for (index, b) in records.prefix(32).enumerated() {
            guard b.count >= 32 else { continue }
            let a = Float(b[9]) / 255.0
            func color(_ start: Int) -> [Float] {
                [
                    Float(b[start]) / 255.0 * a,
                    Float(b[start + 1]) / 255.0 * a,
                    Float(b[start + 2]) / 255.0 * a,
                    a,
                ]
            }
            let kind = Float(b[0] % 5)
            var p = OraclePrimitive(
                node: UInt32(index + 1),
                source: "generated/\(index)",
                rect: [
                    Float(b[1]) / 4.0 - 8.0,
                    Float(b[2]) / 4.0 - 8.0,
                    1.0 + Float(b[3] % 128) / 4.0,
                    1.0 + Float(b[4] % 128) / 4.0,
                ],
                radii: (0..<4).map { n in Float(b[20 + n]) / 8.0 },
                fill: color(6),
                border: color(10),
                params: [
                    Float(b[13]) / 32.0,
                    kind,
                    Float(b[14]) / 32.0,
                    0.7 + Float(b[15]) / 255.0,
                ],
                uv: [0, 0, 0, 0],
                clip: oracleNoClip,
                fade: [0, 0, 0, 0],
                fadeOrigin: nil,
                turn: nil
            )
            if (b[16] & 1) != 0 {
                p.clip = [
                    Float(b[17]) / 8.0,
                    Float(b[18]) / 8.0,
                    32.0 + Float(b[19]) / 8.0,
                    32.0 + Float(b[24]) / 8.0,
                ]
                p.fade = (0..<4).map { n in Float(b[25 + n] % 32) / 4.0 }
            }
            switch UInt32(kind) {
            case 1:
                p.radii = [p.radii[0], p.radii[0], p.radii[0], p.radii[0]]
            case 2:
                p.params[0] = 0.0
                p.uv = [1.0, 1.0, 0.0, 0.0]
                p.rect[2] = 1.0 + Float(b[3] % 24)
                p.rect[3] = 1.0 + Float(b[4] % 24)
                if (b[16] & 2) != 0 {
                    p.uv[2] = p.rect[2]
                    p.uv[3] = p.rect[3]
                    let scale = 0.5 + Float(b[29] % 8) / 4.0
                    p.rect[2] *= scale
                    p.rect[3] *= scale
                }
            case 3:
                p.uv = [
                    Float(b[30]) / 32.0 - 4.0,
                    Float(b[31]) / 32.0 - 4.0,
                    0.0,
                    0.0,
                ]
            case 4:
                p.uv = color(29)
            default:
                break
            }
            primitives.append(p)
        }
        return OracleScene(
            width: 64,
            height: 64,
            clear: [0.025, 0.04, 0.06, 1.0],
            primitives: primitives,
            atlas: OracleAtlas(width: 32, height: 32, data: atlasData)
        )
    }

    public static func seeded(seed: UInt64, count: Int = 8) -> OracleScene {
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
        return scene(records: records)
    }

    private static func satUInt32(_ x: Float) -> UInt32 {
        if x.isNaN || x <= 0 { return 0 }
        if x >= Float(UInt32.max) { return UInt32.max }
        return UInt32(x)
    }

    public static func dashed(seed: UInt64, count: Int = 8) -> OracleScene {
        var scene = seeded(seed: seed, count: count)
        for idx in scene.primitives.indices {
            let p = scene.primitives[idx]
            func b(_ n: Int) -> UInt32 {
                satUInt32(p.radii[n % 4] * 8.0 + p.rect[n % 4] * 4.0)
            }
            var np = p
            np.params = [
                0.5 + Float(b(0) % 8) * 0.25,
                10.0,
                b(1) % 4 == 0 ? p.params[2] : 0.0,
                1.0,
            ]
            np.uv = [
                1.0 + Float(b(2) % 24) * 0.5,
                1.0 + Float(b(3) % 16) * 0.5,
                Float(b(1) % 32) * 0.75 - 6.0,
                0.0,
            ]
            if b(0) % 3 == 0 {
                np.border = np.fill
            }
            scene.primitives[idx] = np
        }
        return scene
    }

    public static func radial(seed: UInt64, count: Int = 8) -> OracleScene {
        var scene = seeded(seed: seed, count: count)
        var out: [OraclePrimitive] = []
        out.reserveCapacity(scene.primitives.count * 2)
        for var p in scene.primitives {
            func b(_ n: Int) -> UInt32 {
                satUInt32(p.radii[n % 4] * 8.0 + p.rect[n % 4] * 4.0)
            }
            let t0 = Float(b(0) % 4) * 0.1
            let t1 = min(t0 + 0.35 + Float(b(1) % 6) * 0.1, 1.0)
            let soft: Float = b(1) % 4 == 0 ? p.params[2] : 0.0
            if b(0) % 4 == 0 {
                let angle = Float(b(2) % 16) * (Float.pi * 2.0 / 16.0)
                let dx = sinf(angle)
                let dy = -cosf(angle)
                let span = max(abs(dx) * p.rect[2] + abs(dy) * p.rect[3], 1.0)
                p.uv = [dx / span, dy / span, 0.0, 0.0]
            } else {
                let cx = (0.2 + Float(b(2) % 7) * 0.1) * p.rect[2]
                let cy = (0.2 + Float(b(3) % 7) * 0.1) * p.rect[3]
                let rx = max(4.0 + Float(b(0) % 24), 1.0)
                let ry = b(1) % 2 == 0 ? rx : max(4.0 + Float(b(1) % 24), 1.0)
                p.uv = [cx, cy, rx, ry]
            }
            if b(2) % 2 == 0 {
                let tMid = 0.5 * (t0 + t1)
                let mid = (0..<4).map { 0.5 * (p.fill[$0] + p.border[$0]) }
                var inner = p
                inner.border = mid
                inner.params = [t0, 11.0, soft, tMid + 2.0]
                out.append(inner)
                p.fill = mid
                p.params = [tMid + 2.0, 11.0, soft, t1]
                out.append(p)
            } else {
                p.params = [t0, 11.0, soft, t1]
                out.append(p)
            }
        }
        scene.primitives = out
        return scene
    }

    public static func translate(_ scene: inout OracleScene, x: Float, y: Float) {
        for idx in scene.primitives.indices {
            scene.primitives[idx].rect[0] += x
            scene.primitives[idx].rect[1] += y
            if scene.primitives[idx].clip != oracleNoClip {
                scene.primitives[idx].clip[0] += x
                scene.primitives[idx].clip[2] += x
                scene.primitives[idx].clip[1] += y
                scene.primitives[idx].clip[3] += y
            }
        }
    }
}
