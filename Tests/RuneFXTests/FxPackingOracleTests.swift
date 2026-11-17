import Foundation
import Testing
@testable import RuneFX

/// The Rust packer writes its native GPU instance and CPU-generated texture/particle tables.
@Suite("RuneFX pinned Rust packing oracle")
struct FxPackingOracleTests {
    private struct Oracle: Decodable {
        let upstream: String
        let cases: [String: Data]
    }

    private func effects() -> [(String, Fx)] {
        var effects: [(String, Fx)] = []
        for style in fillStyles() {
            for preset in style.presets { effects.append((style.id + "-" + preset.id, .fill(preset.fill()))) }
        }
        effects.append(("glow-soft", .glow(GlowParams(style: .soft))))
        effects.append(("glow-neon", .glow(GlowParams(style: .neon))))
        effects.append(("glow-aura", .glow(GlowParams(style: .aura))))
        effects.append(("glow-mask", .glow(GlowParams(style: .mask))))
        effects.append(("pulse-radar", .pulse(PulseParams(style: .radar))))
        effects.append(("pulse-breathe", .pulse(PulseParams(style: .breathe))))
        effects.append(("pulse-heartbeat", .pulse(PulseParams(style: .heartbeat))))
        effects.append(("pulse-ping", .pulse(PulseParams(style: .ping(from: SIMD2(8, 9), dir: SIMD2(3, 4), travel: 32)))))
        effects.append(("pulse-ripple", .pulse(PulseParams(style: .ripple(at: SIMD2(25, 27))))))
        effects.append(("electric-arc", .electric(ElectricParams(style: .arc(a: SIMD2(3, 10), b: SIMD2(52, 45))))))
        effects.append(("electric-border", .electric(ElectricParams(style: .border))))
        effects.append(("electric-charged", .electric(ElectricParams(style: .charged))))
        effects.append(("fire-top", .fire(FireParams(style: .top))))
        effects.append(("fire-border", .fire(FireParams(style: .border))))
        effects.append(("fire-heat", .fire(FireParams(style: .heat))))
        effects.append(("fire-embers", .fire(FireParams(style: .embers))))
        effects.append(("distort-heat", .distort(.heatHaze(height: 10, scale: 8, speed: 2, amount: 1, wholeShape: true))))
        effects.append(("distort-chroma", .distort(.chromaSplit(offset: SIMD2(2, 3)))))
        effects.append(("distort-crt", .distort(.crt())))
        effects.append(("distort-shock", .distort(.shockwave(at: SIMD2(16, 18), t0: 0.5))))
        effects.append(("distort-lens", .distort(.lens(LensParams(frost: 0.5)))))
        effects.append(("extras-shimmer", .shimmer(ShimmerParams())))
        effects.append(("extras-shimmer-mask", .shimmer(ShimmerParams(useMask: true))))
        effects.append(("extras-sparkles", .sparkles(SparkleParams())))
        effects.append(("extras-burst", .sparkles(SparkleParams(burst: 0.25))))
        effects.append(("extras-aurora", .aurora(AuroraParams())))
        effects.append(("extras-grain", .grain(GrainParams())))
        let rest = FxRect(x: 4, y: 6, w: 52, h: 48)
        for (name, mode): (String, BlurMode) in [("motion-directional", .directional), ("motion-shutter", .shutter)] {
            let blur = MotionBlurParams(mode: mode)
            let samples = MotionSamples.fromTrack(blur, rest: rest, at: 0.625, scale: 1) { t in
                Pose(x: (t - 0.625) * 300, rotation: (t - 0.625) * 1.2)
            }
            effects.append((name, .motionBlur(blur, samples)))
        }
        return effects
    }

    @Test func allFamiliesAndFillPresetsPackLikeUpstream() throws {
        let url = try #require(Bundle.module.url(forResource: "upstream-fx-packed", withExtension: "json"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        let cases = effects()
        #expect(oracle.upstream == "842c28c2ca5dd1506c1e4a67052db61800aed721")
        #expect(Set(oracle.cases.keys) == Set(cases.map { $0.0 }))
        for (name, effect) in cases {
            let expected = try #require(oracle.cases[name])
            let shape: FxShape = name == "fire-embers"
                ? .rounded(x: 4, y: 50, w: 52, h: 8, radius: 2)
                : .rounded(x: 4, y: 6, w: 52, h: 48, radius: 8)
            var layer = effect.on(shape).at(0.625).seed(17)
            if name.hasPrefix("motion-") || name == "glow-mask" || name == "extras-shimmer-mask" {
                layer = layer.source(slot: 0, rect: FxRect(x: 4, y: 6, w: 52, h: 48))
            }
            let (kind, raw, bounds) = try #require(layer.pack())
            var instance = raw
            var table: [SIMD4<Float>] = []
            layer.fillTables(into: &instance, data: &table)
            let values = [bounds.x, bounds.y, bounds.w, bounds.h]
                + withUnsafeBytes(of: instance) { Array($0.bindMemory(to: Float.self)) }
                + table.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            #expect(expected.count == (values.count + 1) * 4, "\(name) GPU table length")
            guard expected.count == (values.count + 1) * 4 else { continue }
            expected.withUnsafeBytes { bytes in
                func word(_ i: Int) -> UInt32 {
                    UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                }
                #expect(UInt32(kind.rawValue) == word(0), "\(name) pipeline family")
                for (i, value) in values.enumerated() {
                    let reference = Float(bitPattern: word(i + 1))
                    // Independent libm implementations can round transcendental functions differently.
                    let tolerance = max(0.000002, 16 * reference.ulp)
                    if value != reference && !(abs(value - reference) <= tolerance) {
                        Issue.record("\(name) packed float \(i) expected \(reference), got \(value)")
                        break
                    }
                }
            }
        }
    }
}
