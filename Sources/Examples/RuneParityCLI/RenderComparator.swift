import Foundation
import RuneRef

/// Pixel-level differential report between a Rust reference PNG and a Swift PNG.
public struct ImageDiffReport: Codable, Sendable, Equatable {
    public var rustWidth: Int
    public var rustHeight: Int
    public var swiftWidth: Int
    public var swiftHeight: Int
    public var dimensionsMatch: Bool
    public var totalPixels: Int
    public var differingPixels: Int
    public var diffPct: Double
    public var maxChannelDelta: Int
    public var psnr: Double
    public var worstX: Int?
    public var worstY: Int?
    public var worstRustRGBA: [UInt8]?
    public var worstSwiftRGBA: [UInt8]?
    public var outDiffPath: String?
    public var tolerance: Int
    public var maxDiffPct: Double
    public var passed: Bool

    public init(
        rustWidth: Int,
        rustHeight: Int,
        swiftWidth: Int,
        swiftHeight: Int,
        dimensionsMatch: Bool,
        totalPixels: Int,
        differingPixels: Int,
        diffPct: Double,
        maxChannelDelta: Int,
        psnr: Double,
        worstX: Int?,
        worstY: Int?,
        worstRustRGBA: [UInt8]?,
        worstSwiftRGBA: [UInt8]?,
        outDiffPath: String?,
        tolerance: Int,
        maxDiffPct: Double,
        passed: Bool
    ) {
        self.rustWidth = rustWidth
        self.rustHeight = rustHeight
        self.swiftWidth = swiftWidth
        self.swiftHeight = swiftHeight
        self.dimensionsMatch = dimensionsMatch
        self.totalPixels = totalPixels
        self.differingPixels = differingPixels
        self.diffPct = diffPct
        self.maxChannelDelta = maxChannelDelta
        self.psnr = psnr
        self.worstX = worstX
        self.worstY = worstY
        self.worstRustRGBA = worstRustRGBA
        self.worstSwiftRGBA = worstSwiftRGBA
        self.outDiffPath = outDiffPath
        self.tolerance = tolerance
        self.maxDiffPct = maxDiffPct
        self.passed = passed
    }
}

/// Flattened node from a `--tree` JSON dump.
public struct LayoutTreeNode: Codable, Sendable, Equatable {
    public var index: Int
    public var label: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(index: Int, label: String, x: Double, y: Double, width: Double, height: Double) {
        self.index = index
        self.label = label
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Bounding-box delta for a paired node between Rust and Swift trees.
public struct TreeNodeDelta: Codable, Sendable, Equatable {
    public var index: Int
    public var rustLabel: String
    public var swiftLabel: String
    public var dx: Double
    public var dy: Double
    public var dw: Double
    public var dh: Double
    public var maxDelta: Double

    public init(
        index: Int,
        rustLabel: String,
        swiftLabel: String,
        dx: Double,
        dy: Double,
        dw: Double,
        dh: Double,
        maxDelta: Double
    ) {
        self.index = index
        self.rustLabel = rustLabel
        self.swiftLabel = swiftLabel
        self.dx = dx
        self.dy = dy
        self.dw = dw
        self.dh = dh
        self.maxDelta = maxDelta
    }
}

/// Layout tree JSON differential report.
public struct TreeDiffReport: Codable, Sendable, Equatable {
    public var rustNodeCount: Int
    public var swiftNodeCount: Int
    public var nodeCountDelta: Int
    public var maxBBoxDelta: Double
    public var mismatchCount: Int
    public var mismatches: [TreeNodeDelta]
    public var passed: Bool

    public init(
        rustNodeCount: Int,
        swiftNodeCount: Int,
        nodeCountDelta: Int,
        maxBBoxDelta: Double,
        mismatchCount: Int,
        mismatches: [TreeNodeDelta],
        passed: Bool
    ) {
        self.rustNodeCount = rustNodeCount
        self.swiftNodeCount = swiftNodeCount
        self.nodeCountDelta = nodeCountDelta
        self.maxBBoxDelta = maxBBoxDelta
        self.mismatchCount = mismatchCount
        self.mismatches = mismatches
        self.passed = passed
    }
}

/// Combined render + tree differential report for `compare-renders`.
public struct CompareRendersReport: Codable, Sendable, Equatable {
    public var example: String?
    public var scene: String?
    public var imageDiff: ImageDiffReport?
    public var treeDiff: TreeDiffReport?
    public var passed: Bool

    public init(
        example: String?,
        scene: String?,
        imageDiff: ImageDiffReport?,
        treeDiff: TreeDiffReport?,
        passed: Bool
    ) {
        self.example = example
        self.scene = scene
        self.imageDiff = imageDiff
        self.treeDiff = treeDiff
        self.passed = passed
    }
}

/// Differential PNG and layout-tree comparator using `RuneRef`.
public enum RenderComparator {
    /// Compares two PNG files using `Frame.fromPNG` and `RuneRef.diff`, optionally writing a highlighted diff PNG.
    public static func compareImages(
        rustPNG: URL,
        swiftPNG: URL,
        outDiffPNG: URL? = nil,
        tolerance: Int = 2,
        maxDiffPct: Double = 0.0
    ) throws -> ImageDiffReport {
        guard FileManager.default.fileExists(atPath: rustPNG.path) else {
            throw ParityError.fileNotFound(rustPNG.path)
        }
        guard FileManager.default.fileExists(atPath: swiftPNG.path) else {
            throw ParityError.fileNotFound(swiftPNG.path)
        }

        let rustFrame = try Frame.fromPNG(data: Data(contentsOf: rustPNG))
        let swiftFrame = try Frame.fromPNG(data: Data(contentsOf: swiftPNG))

        let dimsMatch = (rustFrame.width == swiftFrame.width) && (rustFrame.height == swiftFrame.height)
        guard dimsMatch else {
            let total = max(rustFrame.width * rustFrame.height, swiftFrame.width * swiftFrame.height)
            return ImageDiffReport(
                rustWidth: rustFrame.width,
                rustHeight: rustFrame.height,
                swiftWidth: swiftFrame.width,
                swiftHeight: swiftFrame.height,
                dimensionsMatch: false,
                totalPixels: total,
                differingPixels: total,
                diffPct: 100.0,
                maxChannelDelta: 255,
                psnr: 0.0,
                worstX: nil,
                worstY: nil,
                worstRustRGBA: nil,
                worstSwiftRGBA: nil,
                outDiffPath: nil,
                tolerance: tolerance,
                maxDiffPct: maxDiffPct,
                passed: false
            )
        }

        let w = rustFrame.width
        let h = rustFrame.height
        let totalPixels = max(1, w * h)

        let refScene = RefScene(width: w, height: h, primitives: [])
        let diff = RuneRef.compare(
            scene: refScene,
            expected: rustFrame,
            actual: swiftFrame,
            channelTolerance: tolerance,
            maxFailingPixels: 0
        )

        var sumSquaredError: Double = 0.0
        var diffBytes = Array<UInt8>(repeating: 0, count: w * h * 4)

        for y in 0..<h {
            for x in 0..<w {
                let r = rustFrame.pixel(x: x, y: y)
                let s = swiftFrame.pixel(x: x, y: y)
                let dr = abs(Int(r.x) - Int(s.x))
                let dg = abs(Int(r.y) - Int(s.y))
                let db = abs(Int(r.z) - Int(s.z))
                let da = abs(Int(r.w) - Int(s.w))
                sumSquaredError += Double(dr * dr + dg * dg + db * db + da * da)

                let maxC = max(max(dr, dg), max(db, da))
                let idx = (y * w + x) * 4
                if maxC > tolerance {
                    // Highlight differing pixels in bright magenta-red scaled by delta.
                    let boost = min(255, 140 + maxC / 2)
                    diffBytes[idx] = UInt8(boost)
                    diffBytes[idx + 1] = 28
                    diffBytes[idx + 2] = 110
                    diffBytes[idx + 3] = 255
                } else {
                    // Dimmed grayscale context for matching pixels.
                    let luma = (Int(r.x) * 30 + Int(r.y) * 59 + Int(r.z) * 11) / 100
                    let dimmed = UInt8(min(255, max(0, luma / 3)))
                    diffBytes[idx] = dimmed
                    diffBytes[idx + 1] = dimmed
                    diffBytes[idx + 2] = dimmed
                    diffBytes[idx + 3] = 255
                }
            }
        }

        if let outURL = outDiffPNG {
            let diffFrame = Frame(width: w, height: h, rgba: diffBytes)
            try diffFrame.writePNG(to: outURL)
        }

        let mse = sumSquaredError / Double(totalPixels * 4)
        let psnr: Double = mse == 0.0 ? 999.0 : 10.0 * log10((255.0 * 255.0) / mse)
        let diffPct = (Double(diff.differingPixels) / Double(totalPixels)) * 100.0
        let passed = diffPct <= maxDiffPct

        let blame: PixelBlame? = diff.worstBlame
        return ImageDiffReport(
            rustWidth: w,
            rustHeight: h,
            swiftWidth: w,
            swiftHeight: h,
            dimensionsMatch: true,
            totalPixels: totalPixels,
            differingPixels: diff.differingPixels,
            diffPct: diffPct,
            maxChannelDelta: diff.maxChannelDelta,
            psnr: psnr,
            worstX: blame?.x,
            worstY: blame?.y,
            worstRustRGBA: blame.map { [$0.expected.x, $0.expected.y, $0.expected.z, $0.expected.w] },
            worstSwiftRGBA: blame.map { [$0.actual.x, $0.actual.y, $0.actual.z, $0.actual.w] },
            outDiffPath: outDiffPNG?.path,
            tolerance: tolerance,
            maxDiffPct: maxDiffPct,
            passed: passed
        )
    }

    /// Compares two `--tree` JSON dumps by node count and per-node bounding-box deltas.
    public static func compareTrees(
        rustTreeURL: URL,
        swiftTreeURL: URL,
        bboxTolerance: Double = 1.0
    ) throws -> TreeDiffReport {
        guard FileManager.default.fileExists(atPath: rustTreeURL.path) else {
            throw ParityError.fileNotFound(rustTreeURL.path)
        }
        guard FileManager.default.fileExists(atPath: swiftTreeURL.path) else {
            throw ParityError.fileNotFound(swiftTreeURL.path)
        }

        let rustNodes = try parseTreeNodes(from: Data(contentsOf: rustTreeURL))
        let swiftNodes = try parseTreeNodes(from: Data(contentsOf: swiftTreeURL))

        let pairedCount = min(rustNodes.count, swiftNodes.count)
        var maxDelta = 0.0
        var mismatches: [TreeNodeDelta] = []

        for i in 0..<pairedCount {
            let r = rustNodes[i]
            let s = swiftNodes[i]
            let dx = abs(r.x - s.x)
            let dy = abs(r.y - s.y)
            let dw = abs(r.width - s.width)
            let dh = abs(r.height - s.height)
            let d = max(max(dx, dy), max(dw, dh))
            maxDelta = max(maxDelta, d)
            if d > bboxTolerance {
                mismatches.append(TreeNodeDelta(
                    index: i,
                    rustLabel: r.label,
                    swiftLabel: s.label,
                    dx: dx,
                    dy: dy,
                    dw: dw,
                    dh: dh,
                    maxDelta: d
                ))
            }
        }

        let countDelta = abs(rustNodes.count - swiftNodes.count)
        let passed = (countDelta == 0) && mismatches.isEmpty
        return TreeDiffReport(
            rustNodeCount: rustNodes.count,
            swiftNodeCount: swiftNodes.count,
            nodeCountDelta: countDelta,
            maxBBoxDelta: maxDelta,
            mismatchCount: mismatches.count,
            mismatches: mismatches,
            passed: passed
        )
    }

    /// Parses arbitrary `--tree` JSON into a flat pre-order list of `LayoutTreeNode`.
    public static func parseTreeNodes(from data: Data) throws -> [LayoutTreeNode] {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ParityError.invalidJSON("Tree JSON parse failed: \(error)")
        }

        var nodes: [LayoutTreeNode] = []
        collectNodes(from: obj, into: &nodes)
        return nodes
    }

    private static func collectNodes(from value: Any, into nodes: inout [LayoutTreeNode]) {
        if let dict = value as? [String: Any] {
            if let root = dict["root"] {
                collectNodes(from: root, into: &nodes)
                return
            }
            if let list = (dict["elements"] as? [Any]) ?? (dict["nodes"] as? [Any]) {
                for item in list {
                    collectNodes(from: item, into: &nodes)
                }
                return
            }

            if let bbox = extractBBox(from: dict) {
                let label = (dict["key"] as? String)
                    ?? (dict["id"] as? String)
                    ?? (dict["kind"] as? String)
                    ?? (dict["role"] as? String)
                    ?? (dict["tag"] as? String)
                    ?? (dict["text"] as? String)
                    ?? "node"
                nodes.append(LayoutTreeNode(
                    index: nodes.count,
                    label: label,
                    x: bbox.x,
                    y: bbox.y,
                    width: bbox.w,
                    height: bbox.h
                ))
            }

            if let children = dict["children"] as? [Any] {
                for child in children {
                    collectNodes(from: child, into: &nodes)
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                collectNodes(from: item, into: &nodes)
            }
        }
    }

    private static func extractBBox(from dict: [String: Any]) -> (x: Double, y: Double, w: Double, h: Double)? {
        for key in ["rect", "frame", "bounds", "layout"] {
            if let rectDict = dict[key] as? [String: Any] {
                return extractDirectBBox(from: rectDict)
            }
            if let rectArr = dict[key] as? [Any], rectArr.count >= 4,
               let x = doubleVal(rectArr[0]),
               let y = doubleVal(rectArr[1]),
               let w = doubleVal(rectArr[2]),
               let h = doubleVal(rectArr[3]) {
                return (x, y, w, h)
            }
        }
        return extractDirectBBox(from: dict)
    }

    private static func extractDirectBBox(from dict: [String: Any]) -> (x: Double, y: Double, w: Double, h: Double)? {
        guard let x = doubleVal(dict["x"]),
              let y = doubleVal(dict["y"]),
              let w = doubleVal(dict["w"] ?? dict["width"]),
              let h = doubleVal(dict["h"] ?? dict["height"]) else {
            return nil
        }
        return (x, y, w, h)
    }

    private static func doubleVal(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    /// Runs both upstream Rust (`cargo run`) and Swift (`xcrun swift run`) for an example, then compares PNGs & trees.
    public static func runDifferentialExample(
        upstreamRoot: URL,
        swiftRoot: URL,
        mapURL: URL,
        exampleName: String,
        scene: String?,
        size: String?,
        outDiffPNG: URL?,
        tolerance: Int,
        maxDiffPct: Double
    ) throws -> CompareRendersReport {
        let map = try ParityMapper.loadMap(at: mapURL)
        guard let mapping = map.examples.first(where: {
            $0.upstreamName == exampleName || $0.swiftProduct == exampleName || $0.cargoPackage == exampleName
        }) else {
            throw ParityError.missingExampleMapping(exampleName)
        }

        // Verify cargo is available
        let whichCargo = try ProcessRunner.run(executable: "/usr/bin/which", arguments: ["cargo"])
        let cargoBin = whichCargo.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard whichCargo.exitCode == 0 && !cargoBin.isEmpty else {
            throw ParityError.commandFailed(
                command: "which cargo",
                exitCode: whichCargo.exitCode,
                stderr: "cargo is not installed or not in PATH; pass --rust-png / --swift-png to compare pre-captured renders."
            )
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let rustPNG = tmpDir.appendingPathComponent("rust.png")
        let rustTree = tmpDir.appendingPathComponent("rust-tree.json")
        let swiftPNG = tmpDir.appendingPathComponent("swift.png")
        let swiftTree = tmpDir.appendingPathComponent("swift-tree.json")

        var extraFlags: [String] = []
        if let scene { extraFlags += ["--scene", scene] }
        if let size { extraFlags += ["--size", size] }

        let manifest = upstreamRoot.appendingPathComponent("Cargo.toml").path
        let cargoTarget = mapping.cargoPackage ?? mapping.upstreamName
        var cargoArgs = [
            "run", "--manifest-path", manifest,
            "--example", cargoTarget, "--",
            "--snap", rustPNG.path,
            "--tree", rustTree.path,
        ]
        cargoArgs.append(contentsOf: extraFlags)
        _ = try ProcessRunner.runChecked(executable: cargoBin, arguments: cargoArgs, currentDirectory: upstreamRoot)

        var swiftArgs = [
            "swift", "run", mapping.swiftProduct,
            "--snap", swiftPNG.path,
            "--tree", swiftTree.path,
        ]
        swiftArgs.append(contentsOf: extraFlags)
        _ = try ProcessRunner.runChecked(executable: "/usr/bin/xcrun", arguments: swiftArgs, currentDirectory: swiftRoot)

        let imgDiff = try compareImages(
            rustPNG: rustPNG,
            swiftPNG: swiftPNG,
            outDiffPNG: outDiffPNG,
            tolerance: tolerance,
            maxDiffPct: maxDiffPct
        )
        let treeDiff: TreeDiffReport?
        if FileManager.default.fileExists(atPath: rustTree.path)
            && FileManager.default.fileExists(atPath: swiftTree.path) {
            treeDiff = try compareTrees(rustTreeURL: rustTree, swiftTreeURL: swiftTree)
        } else {
            treeDiff = nil
        }

        let passed = imgDiff.passed && (treeDiff?.passed ?? true)
        return CompareRendersReport(
            example: mapping.upstreamName,
            scene: scene,
            imageDiff: imgDiff,
            treeDiff: treeDiff,
            passed: passed
        )
    }
}
