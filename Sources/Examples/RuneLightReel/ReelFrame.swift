import Foundation
import Rune
import RuneFX
import RuneLight

#if canImport(Metal)
import Metal
#endif

struct ReelOverlay {
    var items: [(Float, Float, String, Float, Float, Color)] = []
    var rects: [ReelUIInst] = []

    mutating func text(_ x: Float, _ y: Float, _ s: String, _ size: Float, _ weight: Float, _ c: Color) {
        items.append((x, y, s, size, weight, c))
    }
}

struct ReelBench: Sendable {
    var timings: LightTimings?
    var glassMs: Double = 0
}

struct ReelBenchNumbers: Sendable {
    var gpu: String
    var gi: Double
    var field: Double
    var scene: Double
    var cascades: [Double]
    var fluence: Double
    var glass: Double
    var frame: Double
}

func loadReelBench(outDir: URL) -> ReelBenchNumbers {
    var b = ReelBenchNumbers(gpu: "M5 Max", gi: 2.3, field: 0.07, scene: 0.05, cascades: [0.4, 0.4, 0.4, 0.4, 0.4], fluence: 0.01, glass: 0.5, frame: 4.0)
    let jsonURL = outDir.appendingPathComponent("bench.json")
    guard let data = try? Data(contentsOf: jsonURL),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return b
    }
    if let s = obj["gpu"] as? String { b.gpu = s }
    if let v = obj["gi"] as? Double { b.gi = v }
    if let v = obj["field"] as? Double { b.field = v }
    if let v = obj["gi_scene"] as? Double { b.scene = v }
    if let v = obj["fluence"] as? Double { b.fluence = v }
    if let v = obj["glass"] as? Double { b.glass = v }
    if let v = obj["frame"] as? Double { b.frame = v }
    for n in 0..<5 {
        if let v = obj["c\(n)"] as? Double { b.cascades[n] = v }
    }
    return b
}

func reelGlowSettings(t: Float) -> LightSettings {
    LightSettings(
        ambient: SIMD3<Float>(0.2, 0.205, 0.235),
        exposure: 1.0,
        text: TextPolicy(floor: 0.84, ceiling: 1.3, lit: 1.0, specular: 0.1),
        gi: GIParams(strength: 1.15, air: 0.10, bounce: 0.0, absorption: 0.22, emission: 0.9),
        backgroundGloss: 0.35,
        contactAO: 0.35,
        rim: 0.5,
        albedoFloor: 0.035,
        time: t
    )
}

func reelGlassAt(t: Float) -> Glass? {
    guard t >= reelTGlass - 0.1 && t < reelTArc + 0.4 else { return nil }
    let x = ReelKeys(
        initValue: -520.0,
        keys: [
            (reelTGlass, 300.0, reelSp(1.3, 0.08)),
            (reelTGlass + 3.4, 330.0, reelSp(1.0, 0.0)),
            (reelTArc - 1.3, 1500.0, reelSp(1.4, 0.0)),
        ]
    ).at(t)
    let y = ReelKeys(initValue: 300.0, keys: [(reelTGlass + 3.4, 360.0, reelSp(1.2, 0.0))]).at(t)
    let presence = reelRise(t, reelTGlass, 0.9)
    let w: Float = 380.0
    let h: Float = 240.0
    let r: Float = 56.0
    let a = dpx(x, y, w, h)
    let bud = reelWindow(t, reelTGlass + 1.7, reelTGlass + 3.9, 0.9)
    let bx = x + w - 40.0 + bud * 210.0
    let by = y + h - 50.0 + bud * 110.0
    let br = 46.0 + 14.0 * bud
    let b = dpx(bx, by, br * 2.0, br * 2.0)
    let frost = 0.85 * reelWindow(t, reelTGlass + 4.3, reelTGlass + 6.1, 0.7)
    let k = reelUIScale * reelS
    return Glass.rounded(a.x, a.y, a.z, a.w, radius: r * k)
        .thickness(34.0 * k)
        .bevel(24.0 * k)
        .gap(12.0 * k)
        .dome(10.0 * k)
        .ior(1.5)
        .dispersion(0.045)
        .frost(frost)
        .presence(presence)
        .rimGlow(0.45)
        .union(rect: b, radius: br * k, k: 60.0 * k, morph: 0.0)
}

private func reelSubframes(t: Float) -> Int {
    let h: Float = 1.0 / 480.0
    let toast: (Float) -> Float = { reelState(t: $0).toastX * reelUIScale * reelS }
    let gx: (Float) -> Float = { reelGlassAt(t: $0).map { $0.a.x + $0.a.y + $0.b.x + $0.b.y } ?? 0.0 }
    let v = max(abs(toast(t + h) - toast(t - h)), abs(gx(t + h) - gx(t - h))) / (2.0 * h)
    let travel = v * 0.5 / Float(reelFPS)
    return min(max(Int(ceil(travel / 2.0)), 1), 24)
}

#if canImport(Metal)
struct Reel {
    var bench: ReelBenchNumbers
    var hp: [SIMD2<Float>]

    func frame(ctx: ReelCtx, t: Float, bench: Bool) throws -> (MTLTexture, ReelBench) {
        let n = bench ? 1 : reelSubframes(t: t)
        var frameTex: MTLTexture
        var bOut: ReelBench
        if n <= 1 {
            (frameTex, bOut) = try image(ctx: ctx, t: t, bench: bench)
        } else {
            let shutter: Float = 0.5 / Float(reelFPS)
            let ws = (0..<n).map { k -> Float in
                0.5 - 0.5 * cos(2.0 * Float.pi * (Float(k) + 0.5) / Float(n))
            }
            let wsum = max(ws.reduce(0.0, +), 1e-6)
            var last = ReelBench()
            let vpPtr = ctx.viz.vpBuffer.contents().bindMemory(to: ReelVP.self, capacity: reelMaxVP)
            for k in 0..<n {
                let tk = t + shutter * ((Float(k) + 0.5) / Float(n) - 0.5)
                let (view, b) = try image(ctx: ctx, t: tk, bench: false)
                last = b
                var vp = ReelVP()
                vp.a = SIMD4<Float>(ws[k] / wsum, 0, 0, 0)
                vpPtr[60] = vp

                if let cmd = ctx.queue.makeCommandBuffer() {
                    let rp = MTLRenderPassDescriptor()
                    rp.colorAttachments[0].texture = ctx.accum
                    rp.colorAttachments[0].loadAction = (k == 0) ? .clear : .load
                    if k == 0 {
                        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                    }
                    rp.colorAttachments[0].storeAction = .store
                    if let re = cmd.makeRenderCommandEncoder(descriptor: rp) {
                        re.setRenderPipelineState(ctx.viz.accum)
                        ctx.bindViz(re, level: 0, layer: view)
                        re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1, baseInstance: 60)
                        re.endEncoding()
                    }
                    cmd.commit()
                    cmd.waitUntilCompleted()
                }
            }
            frameTex = ctx.accum
            bOut = last
        }

        var ov = ReelOverlay()
        if t >= reelTTilt && t < reelTUntilt + 1.4 {
            frameTex = breakdown(ctx: ctx, t: t, lit: frameTex, ov: &ov)
        }
        ctx.runBloom(frameTex)
        captions(t: t, ov: &ov)

        var insts = ov.rects
        for (x, y, s, size, weight, c) in ov.items {
            let style = TextStyle(size: size, weight: weight, family: .systemUI, wrap: .noWrap)
            let shaped = ctx.ts.shape(text: s, style: style, maxWidth: nil, pixelScale: reelS, emitGlyphs: true)
            let ox = (x * reelS).rounded()
            let oy = (y * reelS).rounded()
            let fill = reelPremul(c)
            for g in shaped.glyphs {
                insts.append(ReelUIInst(
                    rect: SIMD4<Float>(ox + g.rect.x * reelS, oy + g.rect.y * reelS, g.rect.z * reelS, g.rect.w * reelS),
                    radii: .zero,
                    fill: fill,
                    border: .zero,
                    params: SIMD4<Float>(0, 1, 0, 1),
                    uv: g.uv,
                    vp: SIMD4<Float>(Float(reelW), Float(reelH), 0, 0)
                ))
            }
        }
        ctx.drawRune(insts, target: ctx.overlay, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        return (frameTex, bOut)
    }

    func image(ctx: ReelCtx, t: Float, bench: Bool) throws -> (MTLTexture, ReelBench) {
        let st = reelState(t: t)
        let built = buildReelUI(ts: ctx.ts, st: st)
        let bgc = oklch(reelBG.0, reelBG.1, reelBG.2)
        ctx.drawRune(built.base, target: ctx.base, clear: MTLClearColor(red: Double(bgc.r), green: Double(bgc.g), blue: Double(bgc.b), alpha: 1.0))
        ctx.drawRune(built.text, target: ctx.text, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))

        var fxLayers: [FxLayer] = []
        if st.arc > 0.0 {
            let b = dpt(924.0 + 20.0, 424.0, 150.0, 36.0)
            let e = ElectricParams(
                style: .border,
                color: rgb(0xff5a4a),
                core: rgb(0xfff1e8),
                cool: rgb(0x9b4dff),
                amplitude: 3.2,
                frequency: 2.6,
                speed: 3.0,
                intensity: 1.15 * st.arc,
                glow: 5.5,
                forks: 0.5,
                flicker: 0.35,
                gap: 3.0
            )
            fxLayers.append(
                Fx.electric(e)
                    .on(FxShape.rounded(x: b.x, y: b.y, w: b.z, h: b.w, radius: 10.0 * reelUIScale))
                    .seed(7)
                    .at(t)
                    .over()
            )
        }

        let click: Float = 3.3
        let shock = t >= click && t < click + 1.2

        if let cmd = ctx.queue.makeCommandBuffer() {
            if !fxLayers.isEmpty {
                let graph = ctx.fx.prepare(frame: FxFrame(viewport: SIMD2<UInt32>(UInt32(reelW), UInt32(reelH)), scale: reelS, layers: fxLayers))
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = ctx.emission
                rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                rp.colorAttachments[0].storeAction = .store
                if let re = cmd.makeRenderCommandEncoder(descriptor: rp) {
                    try ctx.fx.encode(graph: graph, viewport: SIMD2<UInt32>(UInt32(reelW), UInt32(reelH)), encoder: re)
                    re.endEncoding()
                }
            }

            let scene = LightScene(
                prims: built.prims,
                lights: [],
                settings: reelGlowSettings(t: t),
                emission: fxLayers.isEmpty ? nil : ctx.emission
            )
            ctx.light.inspectCascades = (t >= reelTTilt - 0.1 && t < reelTUntilt + 1.5) || bench
            ctx.light.render(
                scene: scene,
                commandBuffer: cmd,
                baseTexture: ctx.base,
                textTexture: ctx.text,
                targetTexture: ctx.lit
            )
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        let timings: LightTimings? = bench ? ctx.light.readTimings(commandBuffer: nil) : nil

        if !fxLayers.isEmpty, let cmd = ctx.queue.makeCommandBuffer() {
            let graph = ctx.fx.prepare(frame: FxFrame(viewport: SIMD2<UInt32>(UInt32(reelW), UInt32(reelH)), scale: reelS, layers: fxLayers))
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = ctx.lit
            rp.colorAttachments[0].loadAction = .load
            rp.colorAttachments[0].storeAction = .store
            if let re = cmd.makeRenderCommandEncoder(descriptor: rp) {
                try ctx.fx.encode(graph: graph, viewport: SIMD2<UInt32>(UInt32(reelW), UInt32(reelH)), encoder: re)
                re.endEncoding()
            }
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        if shock, let cmdCopy = ctx.queue.makeCommandBuffer() {
            let sb = dpt(272.0 + 628.0 - 58.0, 712.0, 38.0, 38.0)
            let at = SIMD2<Float>(sb.x + sb.z * 0.5, sb.y + sb.w * 0.5)
            let d = DistortParams.shockwave(at: at, reach: 260.0, width: 16.0, amount: 9.0, chroma: 0.35, t0: click, duration: 1.1)
            let layers = [
                Fx.distort(d)
                    .on(FxShape.rounded(x: at.x - 280.0, y: at.y - 280.0, w: 560.0, h: 560.0, radius: 0.0))
                    .at(t)
            ]
            ctx.copy(cmdCopy, src: ctx.lit, dst: ctx.backdrop)
            cmdCopy.commit()
            cmdCopy.waitUntilCompleted()

            if let cmd = ctx.queue.makeCommandBuffer() {
                let graph = ctx.fx.prepare(frame: FxFrame(viewport: SIMD2<UInt32>(UInt32(reelW), UInt32(reelH)), scale: reelS, layers: layers, backdrop: ctx.backdrop))
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = ctx.lit
                rp.colorAttachments[0].loadAction = .load
                rp.colorAttachments[0].storeAction = .store
                if let re = cmd.makeRenderCommandEncoder(descriptor: rp) {
                    try ctx.fx.encode(graph: graph, viewport: SIMD2<UInt32>(UInt32(reelW), UInt32(reelH)), encoder: re, backdrop: ctx.backdrop)
                    re.endEncoding()
                }
                cmd.commit()
                cmd.waitUntilCompleted()
            }
        }

        var frameTex = ctx.lit
        var glassMs: Double = 0
        if let g = reelGlassAt(t: t) ?? (bench ? reelGlassAt(t: reelTGlass + 1.0) : nil) {
            let lights = built.prims.compactMap { GlassLight.fromEmitter($0, z: 18.0 * reelS, gain: 0.9) }
            if let cmd = ctx.queue.makeCommandBuffer() {
                try ctx.glass.render(
                    commandBuffer: cmd,
                    glass: [g],
                    lights: lights,
                    settings: GlassSettings(),
                    backdrop: ctx.lit,
                    fluence: ctx.light.inspect().fluence,
                    target: ctx.glassed
                )
                cmd.commit()
                cmd.waitUntilCompleted()
                if bench, cmd.gpuEndTime > cmd.gpuStartTime {
                    glassMs = (cmd.gpuEndTime - cmd.gpuStartTime) * 1000.0
                }
            }
            frameTex = ctx.glassed
        }

        return (frameTex, ReelBench(timings: timings, glassMs: glassMs))
    }

    func captions(t: Float, ov: inout ReelOverlay) {
        let b = bench
        let caps: [(Float, Float, String, String)] = [
            (1.0, reelTTilt - 0.3, "Lit only by its own glowing elements", "2D radiance cascades · every emitter lights its neighbours, with soft coloured shadow"),
            (reelTTilt + 0.2, reelTInputs - 0.1, "How it's lit", "rune-light's real GI buffers, frame by frame"),
            (reelTInputs, reelTCascades - 0.1, "① The scene as a distance field", String(format: "Rune draws analytic rounded rects, so the SDF is exact (no jump flood) · ½ res · %.2f ms", b.field)),
            (reelTCascades, reelTMerge - 0.1, "② Five cascades of probes", "each level: probes 2× sparser, rays 4× longer, 4× the directions · same memory per level"),
            (reelTMerge, reelTFluence - 0.1, "③ Merge, top cascade down", "each ray continues into the four nearest upper probes (Sannikov's bilinear fix: no leaks between probes)"),
            (reelTFluence, reelTUntilt - 0.1, "④ Fluence", "cascade 0's directions averaged: the light arriving at every point"),
            (reelTUntilt, reelTGlass - 0.2, "⑤ Back onto the UI", String(format: "whole GI pass %.1f ms on %@ at 2560×1600 · cost fixed by the grid, not the number of lights", b.gi, b.gpu)),
            (reelTGlass + 0.3, reelTArc - 0.4, "Thick glass, refracted per pixel", String(format: "Snell n = 1.50 · exact Fresnel · 8-wavelength dispersion · total internal reflection at the bevel · frost · %.2f ms", b.glass)),
            (reelTArc + 0.2, reelTEnd - 0.3, "Effects are light too", "the electric arc is emission: it enters the cascades and lights the cards around it"),
        ]
        for (a, z, title, sub) in caps {
            let k = reelWindow(t, a, z, 0.35)
            guard k > 0.01 else { continue }
            let y: Float = 754.0 + (1.0 - k) * 6.0
            let x: Float = reelUIO.x + 4.0
            ov.text(x, y, title, 15.0, 600.0, oklcha(0.95, 0.005, 268.0, k))
            ov.text(x, y + 22.0, sub, 12.5, 400.0, oklcha(0.68, 0.012, 268.0, k))
        }
        let k = reelRise(t, reelTEnd + 0.3, 0.8)
        if k > 0.01 {
            let x: Float = 640.0 - 150.0
            ov.text(x, 760.0 + (1.0 - k) * 6.0, "Rune  ·  radiance cascades  ·  120 Hz", 16.0, 600.0, oklcha(0.95, 0.005, 268.0, k))
        }
    }

    func breakdown(ctx: ReelCtx, t: Float, lit: MTLTexture, ov: inout ReelOverlay) -> MTLTexture {
        let ins = ctx.light.inspect()
        let gs = ins.giSize
        let texel = ins.texel
        let tilt = reelRise(t, reelTTilt, 1.3) * (1.0 - reelRise(t, reelTUntilt, 1.2))
        let cam = ReelCam(pitch: 0.84 * tilt, yaw: -0.28 * tilt, scale: reelLerp(1.0, 0.6, tilt), ty: -20.0 * tilt, tx: -190.0 * tilt)
        let inputs = reelWindow(t, reelTInputs - 0.2, reelTCascades + 0.3, 0.6)
        let uiLift = reelRise(t, reelTInputs - 0.3, 0.9) * (1.0 - reelRise(t, reelTFluence + 0.6, 1.0))
        let uiAlpha = 1.0 - 0.9 * reelRise(t, reelTInputs - 0.3, 0.7) + 0.9 * reelRise(t, reelTUntilt - 0.2, 0.8)

        func mergeK(_ n: Int) -> Float {
            let tn = reelTMerge + 0.45 * Float(Int(lightCascades) - 1 - n)
            return reelRise(t, tn, 0.5)
        }

        let guPtr = ctx.viz.gBuffer.contents().bindMemory(to: ReelGU.self, capacity: 1)
        guPtr.pointee = ReelGU(
            size: SIMD4<Float>(Float(reelW), Float(reelH), Float(gs.0), Float(gs.1)),
            gi: SIMD4<Float>(texel, t, 2.0, 0.0),
            hp0: SIMD4<Float>(hp[0].x, hp[0].y, hp[1].x, hp[1].y),
            hp1: .zero
        )

        let vpPtr = ctx.viz.vpBuffer.contents().bindMemory(to: ReelVP.self, capacity: reelMaxVP)
        for i in 0..<reelMaxVP { vpPtr[i] = ReelVP() }

        let expo: [Float] = [0.9, 1.6, 2.6, 4.0, 6.0]
        var content: [(Int, MTLRenderPipelineState, Int)] = [
            (0, ctx.viz.field, 0),
            (1, ctx.viz.scene, 0),
        ]
        for n in 0..<Int(lightCascades) {
            let ownToMerged: Float = (n == Int(lightCascades) - 1) ? 1.0 : mergeK(n + 1)
            let grow = reelRise(t, reelTCascades + 0.25 + 0.5 * Float(n), 0.8)
            vpPtr[2 + n] = ReelVP(
                a: SIMD4<Float>(Float(n), ownToMerged, expo[n] * reelLerp(1.0, 0.6, ownToMerged), 0),
                b: SIMD4<Float>(1, 1, 1, 1),
                c: SIMD4<Float>(grow, 1, 0, 3.2)
            )
            content.append((2 + n, ctx.viz.cascade, n))
        }
        vpPtr[1].a = SIMD4<Float>(0, 0, 0.9, 0)
        vpPtr[7].a = SIMD4<Float>(0, 0, 1.5, 0)
        content.append((7, ctx.viz.fluence, 0))

        if let cmd = ctx.queue.makeCommandBuffer() {
            ctx.means(cmd)
            for (slot, pipe, level) in content {
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = ctx.layers[slot].mips[0]
                rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                rp.colorAttachments[0].storeAction = .store
                if let re = cmd.makeRenderCommandEncoder(descriptor: rp) {
                    re.setRenderPipelineState(pipe)
                    ctx.bindViz(re, level: level)
                    re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1, baseInstance: slot)
                    re.endEncoding()
                }
            }
            ctx.copy(cmd, src: lit, dst: ctx.layers[8].tex)
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        if let cmd = ctx.queue.makeCommandBuffer() {
            for slot in 0..<9 {
                ctx.buildMips(cmd, layerIdx: slot)
            }
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        var stackItems: [(Int, Float, Float, String)] = []
        let sep: Float = 210.0
        stackItems.append((0, -sep * 1.0 * inputs - 80.0 * (1.0 - inputs), inputs, "Distance field · ½ res, exact"))
        stackItems.append((1, 0.0, inputs, "Emitters + cards · \(gs.0)×\(gs.1) texels · sub-texel coverage"))
        for n in 0..<Int(lightCascades) {
            let aIn = reelRise(t, reelTCascades + 0.5 * Float(n), 0.7)
            let aOut = reelRise(t, reelTFluence + 0.2, 0.6)
            let baseZ = (Float(n) - 2.0) * sep * 0.95
            let collapsed: Float = (n == 0) ? 0.0 : mergeK(n)
            let below = (Float(n) - 3.0) * sep * 0.95
            let z = reelLerp(baseZ - 300.0 * (1.0 - aIn), min(below, baseZ), collapsed)
            let nextIn: Float = (n + 1 < Int(lightCascades)) ? reelRise(t, reelTCascades + 0.5 * Float(n + 1), 0.6) : 0.0
            let refocus = reelRise(t, reelTMerge - 0.2, 0.6)
            let focus = 1.0 - 0.6 * nextIn * (1.0 - refocus)
            let alpha = aIn * (1.0 - aOut) * focus * (1.0 - 0.85 * (n > 0 ? mergeK(n) : 0.0))
            let p = (gs.0 >> n, gs.1 >> n)
            let t0 = (pow(4.0, Float(n)) - 1.0) / 3.0 * texel
            let t1 = (pow(4.0, Float(n + 1)) - 1.0) / 3.0 * texel
            let ms = self.bench.cascades[n]
            stackItems.append((
                2 + n,
                z,
                alpha,
                String(format: "C%d · %u×%u probes · %d rays · %.0f–%.0f px · %.2f ms", n, p.0, p.1, 4 << (2 * n), t0, t1, ms)
            ))
        }
        let fl = reelWindow(t, reelTFluence, reelTUntilt + 0.5, 0.6)
        stackItems.append((7, -sep * 1.9 + sep * 1.9 * reelRise(t, reelTFluence, 0.8), fl, String(format: "Fluence · %.2f ms", self.bench.fluence)))
        stackItems.append((8, sep * 3.2 * uiLift, min(max(uiAlpha, 0.0), 1.0), ""))

        var order = stackItems.indices.filter { stackItems[$0].2 > 0.003 }
        order.sort { a, b in
            let za = reelProject(cam, Float(reelW) * 0.5, Float(reelH) * 0.5, stackItems[a].1).w
            let zb = reelProject(cam, Float(reelW) * 0.5, Float(reelH) * 0.5, stackItems[b].1).w
            return zb < za
        }

        let firstVP = 16
        for (k, i) in order.enumerated() {
            let (_, z, alpha, _) = stackItems[i]
            vpPtr[firstVP + k] = ReelVP(
                a: .zero,
                b: .zero,
                c: SIMD4<Float>(0, alpha, 0.55 * tilt, 0),
                q0: reelProject(cam, 0, 0, z),
                q1: reelProject(cam, Float(reelW), 0, z),
                q2: reelProject(cam, 0, Float(reelH), z),
                q3: reelProject(cam, Float(reelW), Float(reelH), z)
            )
        }

        let bgc = oklch(reelBG.0, reelBG.1, reelBG.2)
        if let cmd = ctx.queue.makeCommandBuffer() {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = ctx.stack
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: Double(bgc.r), green: Double(bgc.g), blue: Double(bgc.b), alpha: 1.0)
            rp.colorAttachments[0].storeAction = .store
            if let re = cmd.makeRenderCommandEncoder(descriptor: rp) {
                re.setRenderPipelineState(ctx.viz.layer)
                for (k, i) in order.enumerated() {
                    ctx.bindViz(re, level: 0, layer: ctx.layers[stackItems[i].0].tex)
                    re.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1, baseInstance: firstVP + k)
                }
                re.endEncoding()
            }
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        var labels: [(Float, Float, Float, String)] = []
        for i in order {
            let (_, z, alpha, label) = stackItems[i]
            if label.isEmpty || alpha < 0.05 || tilt < 0.3 { continue }
            let p = reelToScreen(reelProject(cam, Float(reelW), Float(reelH) * 0.5, z))
            let a = min(alpha, 1.0) * min(max((tilt - 0.3) / 0.4, 0.0), 1.0)
            labels.append((p.x / reelS + 44.0, p.y / reelS - 8.0, a, label))
        }
        labels.sort { $0.1 < $1.1 }
        if labels.count > 1 {
            for k in 1..<labels.count {
                let minY = labels[k - 1].1 + 22.0
                if labels[k].1 < minY { labels[k].1 = minY }
            }
        }
        for (x, y, a, l) in labels {
            ov.text(x, y, l, 12.0, 500.0, oklcha(0.9, 0.01, 268.0, a))
        }
        return ctx.stack
    }
}
#endif
