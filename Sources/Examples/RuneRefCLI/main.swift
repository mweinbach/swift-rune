import Foundation
import Rune
import RuneRef

/// CLI for `RuneRef` deterministic scene listing, PNG generation, pixel blame, and CPU-vs-Metal differential checks.
enum RuneRefCLI {
    static let availableScenes: [(name: String, description: String)] = [
        ("seeded", "64x64 SplitMix64 corpus (roundedRect, dropShadow, glyph, insetShadow, linearGradient)"),
        ("dashed", "64x64 SplitMix64 corpus of dashed border rings (kind 10)"),
        ("radial", "64x64 SplitMix64 corpus of radial / multi-stop gradients (kind 11)"),
        ("text-run", "64x64 seeded corpus augmented with shaped TextSystem glyph quads"),
        ("showcase", "256x256 multi-primitive showcase (rects, shadows, gradients, segments, triangles, dashed rings)"),
        ("layers", "128x128 offscreen layer stack with opacity, clipping, and additive compositing"),
    ]

    static func printHelp() {
        let help = """
        rune-ref — RuneRef deterministic reference renderer & differential checker

        USAGE:
          rune-ref <subcommand> [options]
          rune-ref [--seed <n>] [--count <n>] [--scene <name|file.json>] [--save <scene.json>] [--out <file.png>] [--blame <x,y>] [--diff]

        SUBCOMMANDS:
          list                         List built-in deterministic reference scenes
          generate [options]           Render a scene (prints blake3=<hex> for oracle scenes, or fnv1a)
          check [options]              Run CPU vs MetalRenderer differential comparison

        OPTIONS:
          --scene <name|path.json>     Built-in scene name, 'all' (for check), or OracleScene JSON path
          --seed <u64>                 Seed for 'seeded' / 'dashed' / 'radial' / 'text-run' (default: 0)
          --count <int>                Primitive count for generated scenes (default: 8)
          --save <path.json>           Serialize generated/loaded OracleScene to JSON
          --out, -o <path>             Write rendered PNG to <path>
          --gpu                        Use MetalRenderer instead of CPU renderer
          --blame <x,y>                Inspect pixel (x, y) and print topmost covering primitive
          --tolerance <int>            Per-channel tolerance for 'check' / '--diff' (default: 2)
          --max-failing <int>          Allowed failing pixels (default: 0)
          --diff                       Run GPU vs CPU differential comparison
          --help, -h                   Show this help message
        """
        print(help)
    }

    static func buildScene(name: String, seed: UInt64, count: Int) throws -> RefScene {
        switch name {
        case "seeded":
            return RefGenerator.seeded(seed: seed, count: count)
        case "dashed":
            return RefGenerator.dashed(seed: seed, count: count)
        case "radial":
            return RefGenerator.radial(seed: seed, count: count)
        case "text-run":
            return try buildOracleScene(name: name, seed: seed, count: count).toRefScene()
        case "showcase":
            return showcaseScene()
        case "layers":
            return layersScene()
        default:
            throw CLIError.unknownScene(name)
        }
    }

    static func isOracleSceneName(_ name: String) -> Bool {
        name == "seeded" || name == "dashed" || name == "radial" || name == "text-run"
            || name.hasSuffix(".json") || FileManager.default.fileExists(atPath: name)
    }

    static func buildOracleScene(name: String, seed: UInt64, count: Int) throws -> OracleScene {
        switch name {
        case "seeded":
            return OracleGenerator.seeded(seed: seed, count: count)
        case "dashed":
            return OracleGenerator.dashed(seed: seed, count: count)
        case "radial":
            return OracleGenerator.radial(seed: seed, count: count)
        case "text-run":
            var scene = OracleGenerator.seeded(seed: seed, count: count)
            addTextRun(to: &scene, seed: seed)
            return scene
        default:
            if name.hasSuffix(".json") || FileManager.default.fileExists(atPath: name) {
                let data = try Data(contentsOf: URL(fileURLWithPath: name))
                return try JSONDecoder().decode(OracleScene.self, from: data)
            }
            throw CLIError.unknownScene(name)
        }
    }

    static func addTextRun(to scene: inout OracleScene, seed: UInt64) {
        let strings = ["Rune ffi", "Ág jW", "012345", "a\u{301} test"]
        let textSystem = TextSystem()
        let style = TextStyle(size: Float(9 + seed % 15), weight: 400)
        let shaped = textSystem.shape(
            text: strings[Int(seed % UInt64(strings.count))],
            style: style,
            maxWidth: 60.0,
            pixelScale: 1.0
        )
        for i in scene.primitives.indices where scene.primitives[i].params.count > 1 && scene.primitives[i].params[1] == 2.0 {
            scene.primitives[i].uv[0] += 960.0
            scene.primitives[i].uv[1] += 960.0
        }
        let atlas = textSystem.glyphAtlas.atlas
        var atlasBytes = atlas.texels
        let copyH = min(Int(scene.atlas.height), 32)
        let copyW = min(Int(scene.atlas.width), 32)
        if atlas.width >= 992 && atlas.height >= 992 {
            for y in 0..<copyH {
                let dstStart = (y + 960) * atlas.width + 960
                let srcStart = y * Int(scene.atlas.width)
                for x in 0..<copyW {
                    atlasBytes[dstStart + x] = scene.atlas.data[srcStart + x]
                }
            }
        }
        let first = UInt32(scene.primitives.count + 1)
        for (n, q) in shaped.glyphs.enumerated() {
            let u0 = q.uv.x * Float(atlas.width)
            let v0 = q.uv.y * Float(atlas.height)
            scene.primitives.append(OraclePrimitive(
                node: first + UInt32(n),
                source: "text/\(seed)/glyph-\(n)",
                rect: [q.rect.x + 2.0, q.rect.y + 2.0, q.rect.z, q.rect.w],
                radii: [0, 0, 0, 0],
                fill: [0.7, 0.6, 0.5, 0.8],
                border: [0, 0, 0, 0],
                params: [0.0, 2.0, 0.0, 0.85],
                uv: [u0, v0, 0.0, 0.0],
                clip: oracleNoClip,
                fade: [0, 0, 0, 0]
            ))
        }
        scene.atlas = OracleAtlas(width: UInt32(atlas.width), height: UInt32(atlas.height), data: atlasBytes)
    }

    static func showcaseScene() -> RefScene {
        let clip = RefGenerator.noClip
        let prims: [Primitive] = [
            .roundedRect(
                rect: SIMD4<Float>(16, 16, 224, 224),
                radii: SIMD4<Float>(18, 18, 18, 18),
                fill: SIMD4<Float>(0.10, 0.12, 0.16, 1.0),
                borderColor: SIMD4<Float>(0.24, 0.28, 0.36, 1.0),
                borderWidth: 1.5,
                clip: clip
            ),
            .dropShadow(
                rect: SIMD4<Float>(32, 34, 92, 64),
                radii: SIMD4<Float>(12, 12, 12, 12),
                color: SIMD4<Float>(0.0, 0.0, 0.0, 0.65),
                blur: 10.0,
                offset: SIMD2<Float>(0, 4),
                clip: clip
            ),
            .linearGradient(
                rect: SIMD4<Float>(32, 32, 92, 64),
                radii: SIMD4<Float>(12, 12, 12, 12),
                topColor: SIMD4<Float>(0.22, 0.52, 0.96, 1.0),
                bottomColor: SIMD4<Float>(0.55, 0.30, 0.92, 1.0),
                angleRadians: .pi * 0.35,
                clip: clip
            ),
            .radialGradient(
                rect: SIMD4<Float>(138, 32, 86, 64),
                radii: SIMD4<Float>(12, 12, 12, 12),
                innerColor: SIMD4<Float>(0.98, 0.68, 0.24, 1.0),
                outerColor: SIMD4<Float>(0.82, 0.22, 0.36, 1.0),
                center: SIMD2<Float>(181, 64),
                clip: clip
            ),
            .insetShadow(
                rect: SIMD4<Float>(32, 114, 192, 46),
                radii: SIMD4<Float>(10, 10, 10, 10),
                color: SIMD4<Float>(0.0, 0.0, 0.0, 0.55),
                blur: 6.0,
                offset: SIMD2<Float>(0, 2),
                clip: clip
            ),
            .dashedRing(
                rect: SIMD4<Float>(32, 174, 88, 48),
                radii: SIMD4<Float>(10, 10, 10, 10),
                color: SIMD4<Float>(0.32, 0.85, 0.65, 1.0),
                borderWidth: 2.0,
                dashLength: 7.0,
                gapLength: 4.0,
                phase: 0.0,
                clip: clip
            ),
            .segment(
                from: SIMD2<Float>(138, 214),
                to: SIMD2<Float>(218, 178),
                width: 3.5,
                color: SIMD4<Float>(0.95, 0.86, 0.32, 1.0),
                clip: clip
            ),
            .triangle(
                v0: SIMD2<Float>(186, 180),
                v1: SIMD2<Float>(220, 218),
                v2: SIMD2<Float>(152, 218),
                color: SIMD4<Float>(0.38, 0.78, 0.98, 0.85),
                clip: clip
            ),
        ]
        return RefScene(
            width: 256,
            height: 256,
            srgbBlend: false,
            clearColor: SIMD4<Float>(0.04, 0.05, 0.07, 1.0),
            primitives: prims
        )
    }

    static func layersScene() -> RefScene {
        let clip = RefGenerator.noClip
        let prims: [Primitive] = [
            .roundedRect(
                rect: SIMD4<Float>(12, 12, 104, 104),
                radii: SIMD4<Float>(14, 14, 14, 14),
                fill: SIMD4<Float>(0.12, 0.14, 0.20, 1.0),
                clip: clip
            ),
            .layerBegin(
                rect: SIMD4<Float>(20, 20, 88, 88),
                opacity: 0.75,
                additive: false,
                clip: SIMD4<Float>(20, 20, 88, 88)
            ),
            .roundedRect(
                rect: SIMD4<Float>(24, 24, 56, 56),
                radii: SIMD4<Float>(12, 12, 12, 12),
                fill: SIMD4<Float>(0.92, 0.28, 0.36, 1.0),
                clip: clip
            ),
            .roundedRect(
                rect: SIMD4<Float>(48, 48, 56, 56),
                radii: SIMD4<Float>(12, 12, 12, 12),
                fill: SIMD4<Float>(0.24, 0.64, 0.96, 1.0),
                clip: clip
            ),
            .layerEnd(clip: clip),
        ]
        return RefScene(
            width: 128,
            height: 128,
            srgbBlend: false,
            clearColor: SIMD4<Float>(0.03, 0.04, 0.06, 1.0),
            primitives: prims
        )
    }

    enum CLIError: Error, CustomStringConvertible {
        case invalidArgument(String)
        case unknownScene(String)
        case checkFailed(String)

        var description: String {
            switch self {
            case .invalidArgument(let msg): return "invalid argument: \(msg)"
            case .unknownScene(let name): return "unknown scene '\(name)' (use 'rune-ref list' to see available scenes)"
            case .checkFailed(let msg): return msg
            }
        }
    }

    struct Options {
        var scene: String = "seeded"
        var sceneExplicit: Bool = false
        var seed: UInt64 = 0
        var count: Int = 8
        var savePath: String? = nil
        var outPath: String? = nil
        var useGPU: Bool = false
        var blame: (Int, Int)? = nil
        var tolerance: Int = 2
        var maxFailing: Int = 0
        var diffFlag: Bool = false
    }

    static func parseOptions(_ args: ArraySlice<String>) throws -> Options {
        var opts = Options()
        var i = args.startIndex
        while i < args.endIndex {
            let arg = args[i]
            func nextVal() throws -> String {
                let next = args.index(after: i)
                guard next < args.endIndex else {
                    throw CLIError.invalidArgument("missing value for \(arg)")
                }
                i = next
                return args[i]
            }
            switch arg {
            case "--scene":
                opts.scene = try nextVal()
                opts.sceneExplicit = true
            case "--seed":
                let raw = try nextVal()
                guard let v = UInt64(raw) else { throw CLIError.invalidArgument("invalid --seed '\(raw)'") }
                opts.seed = v
            case "--count":
                let raw = try nextVal()
                guard let v = Int(raw), v > 0 else { throw CLIError.invalidArgument("invalid --count '\(raw)'") }
                opts.count = v
            case "--save":
                opts.savePath = try nextVal()
            case "--out", "-o":
                opts.outPath = try nextVal()
            case "--gpu":
                opts.useGPU = true
            case "--blame":
                let raw = try nextVal()
                let parts = raw.split(separator: ",", maxSplits: 1)
                guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) else {
                    throw CLIError.invalidArgument("--blame expects x,y")
                }
                opts.blame = (x, y)
            case "--tolerance":
                let raw = try nextVal()
                guard let v = Int(raw), v >= 0 else { throw CLIError.invalidArgument("invalid --tolerance '\(raw)'") }
                opts.tolerance = v
            case "--max-failing":
                let raw = try nextVal()
                guard let v = Int(raw), v >= 0 else { throw CLIError.invalidArgument("invalid --max-failing '\(raw)'") }
                opts.maxFailing = v
            case "--diff":
                opts.diffFlag = true
            case "--help", "-h":
                printHelp()
                Foundation.exit(0)
            default:
                throw CLIError.invalidArgument("unexpected argument '\(arg)'")
            }
            i = args.index(after: i)
        }
        return opts
    }

    static func printBlame(scene: RefScene, frame: Frame, x: Int, y: Int) throws {
        guard x >= 0 && y >= 0 && x < scene.width && y < scene.height else {
            throw CLIError.invalidArgument("pixel (\(x), \(y)) outside \(scene.width)x\(scene.height) viewport")
        }
        let px = frame.pixel(x: x, y: y)
        let frag = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
        var hitIndex: Int? = nil
        var hitKind: PrimitiveKind? = nil
        for (idx, prim) in scene.primitives.enumerated().reversed() {
            if prim.kind == .layerBegin || prim.kind == .layerEnd { continue }
            let cov = RefShader.evaluatePrimitive(prim, fragCoord: frag, glyphs: scene.glyphs, images: scene.images, srgbBlend: scene.srgbBlend)
            if cov.w > 0 {
                hitIndex = idx
                hitKind = prim.kind
                break
            }
        }
        if let idx = hitIndex, let kind = hitKind {
            print("blame (\(x),\(y)): rgba=(\(px.x),\(px.y),\(px.z),\(px.w)) primitive=\(idx) kind=\(kind)")
        } else {
            print("blame (\(x),\(y)): rgba=(\(px.x),\(px.y),\(px.z),\(px.w)) clear")
        }
    }

    static func runGenerate(_ opts: Options) throws {
        if isOracleSceneName(opts.scene) {
            let oracleScene = try buildOracleScene(name: opts.scene, seed: opts.seed, count: opts.count)
            try oracleScene.validate()
            var frame = OracleFrame(width: oracleScene.width, height: oracleScene.height, provenance: true)
            frame.render(oracleScene)

            if opts.useGPU {
                let renderer = try MetalRenderer()
                let gpuFrame = try renderer.renderOffscreen(oracleScene.toRefScene())
                print("blake3=\(Blake3.hashHex(gpuFrame.rgba))")
                if let outPath = opts.outPath {
                    try gpuFrame.writePNG(to: URL(fileURLWithPath: outPath))
                    print("wrote \(outPath)")
                }
            } else {
                print("blake3=\(frame.hash())")
                if let outPath = opts.outPath {
                    let pngFrame = Frame(width: Int(oracleScene.width), height: Int(oracleScene.height), rgba: frame.rgba)
                    try pngFrame.writePNG(to: URL(fileURLWithPath: outPath))
                    print("wrote \(outPath)")
                }
            }
            if let savePath = opts.savePath {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try enc.encode(oracleScene)
                try data.write(to: URL(fileURLWithPath: savePath), options: .atomic)
            }
            if let (bx, by) = opts.blame {
                guard bx >= 0, by >= 0, UInt32(bx) < oracleScene.width, UInt32(by) < oracleScene.height else {
                    throw CLIError.invalidArgument("pixel (\(bx), \(by)) outside \(oracleScene.width)x\(oracleScene.height) viewport")
                }
                if let p = frame.blame(oracleScene, x: UInt32(bx), y: UInt32(by)) {
                    print("node=\(p.node) source=\(p.source) kind=\(p.params.count > 1 ? p.params[1] : 0)")
                } else {
                    print("clear")
                }
            }
            if opts.diffFlag {
                let renderer = try MetalRenderer()
                let gpuFrame = try renderer.renderOffscreen(oracleScene.toRefScene())
                let report = Oracle.compare(
                    scene: oracleScene,
                    cpu: frame,
                    gpu: gpuFrame.rgba,
                    tolerance: UInt8(clamping: opts.tolerance)
                )
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let json = String(data: try enc.encode(report), encoding: .utf8) {
                    print(json)
                }
                if report.outlierPixels > opts.maxFailing {
                    throw CLIError.checkFailed("GPU differs from reference (\(report.outlierPixels) outlier pixels)")
                }
            }
            return
        }

        let scene = try buildScene(name: opts.scene, seed: opts.seed, count: opts.count)
        try scene.validate()
        let frame: Frame
        if opts.useGPU {
            let renderer = try MetalRenderer()
            frame = try renderer.renderOffscreen(scene)
        } else {
            frame = try RuneRef.render(scene)
        }
        print("scene=\(opts.scene) size=\(frame.width)x\(frame.height) blake3=\(frame.blake3Hash()) fnv1a=\(frame.fnv1aHash())")
        if let (bx, by) = opts.blame {
            try printBlame(scene: scene, frame: frame, x: bx, y: by)
        }
        if let outPath = opts.outPath {
            let url = URL(fileURLWithPath: outPath)
            try frame.writePNG(to: url)
            print("wrote \(outPath)")
        }
    }

    static func runCheck(_ opts: Options) throws {
        if opts.sceneExplicit && isOracleSceneName(opts.scene) && opts.scene != "all" {
            var diffOpts = opts
            diffOpts.diffFlag = true
            try runGenerate(diffOpts)
            return
        }

        let names: [String]
        if !opts.sceneExplicit || opts.scene == "all" {
            names = availableScenes.map(\.name)
        } else {
            names = [opts.scene]
        }

        let renderer = try MetalRenderer()
        var failures = 0
        for name in names {
            let scene = try buildScene(name: name, seed: opts.seed, count: opts.count)
            try scene.validate()
            let expected = try RuneRef.render(scene)
            let actual = try renderer.renderOffscreen(scene)
            let diff = RuneRef.compare(
                scene: scene,
                expected: expected,
                actual: actual,
                channelTolerance: opts.tolerance,
                maxFailingPixels: opts.maxFailing
            )
            let status = diff.passed ? "PASS" : "FAIL"
            print("[\(status)] \(name) (\(scene.width)x\(scene.height)): diffPixels=\(diff.differingPixels) maxDelta=\(diff.maxChannelDelta) cpu=\(expected.fnv1aHash()) gpu=\(actual.fnv1aHash())")
            if let blame = diff.worstBlame {
                print("  worstBlame=(\(blame.x),\(blame.y)) expected=\(blame.expected) actual=\(blame.actual) delta=\(blame.maxChannelDelta) prim=\(blame.primitiveIndex.map(String.init) ?? "none") kind=\(blame.primitiveKind.map { "\($0)" } ?? "none")")
            }
            if !diff.passed {
                failures += 1
            }
        }
        if failures > 0 {
            throw CLIError.checkFailed("\(failures) of \(names.count) scene(s) failed differential check")
        }
    }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            guard let first = args.first else {
                let opts = Options()
                try runGenerate(opts)
                return
            }
            switch first {
            case "--help", "-h", "help":
                printHelp()
            case "list":
                for entry in availableScenes {
                    print("\(entry.name)\t\(entry.description)")
                }
            case "generate":
                let opts = try parseOptions(args.dropFirst())
                try runGenerate(opts)
            case "check":
                let opts = try parseOptions(args.dropFirst())
                try runCheck(opts)
            default:
                let opts = try parseOptions(args[...])
                try runGenerate(opts)
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}

RuneRefCLI.main()
