import Foundation
import Testing
@testable import Rune
import RuneRef

@Suite("Headless snapshot cropping")
struct HeadlessCropTests {
    private let width = 20
    private let height = 16

    private func pixels() -> Frame {
        var rgba = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                rgba.append(contentsOf: [UInt8(x), UInt8(y), 0, 255])
            }
        }
        return Frame(width: width, height: height, rgba: rgba)
    }

    #if !os(WASI)
    @Test("The CLI returns status 2 and prints the crop diagnostic")
    func invalidArgumentExitStatus() {
        let diagnostic = "--crop other: no element has that key or path"
        var message = ""
        var status: Int32?
        let started = RuneStartup.handleResult(.failure(ToolingError.invalidArgument(diagnostic)),
                                               writeStderr: { message = $0 }, exitProcess: { status = $0 })
        #expect(!started && message == diagnostic && status == 2)
    }
    #endif

    @Test("Malformed crop rectangles and key crops without a snapshot fail before the app starts")
    func invalidCropArguments() throws {
        let spec = AppSpec(state: ()) { _, _ in el() }
        for crop in ["1,2", "1,2,3,4,x", "1,2,,4"] {
            let argv = ["--crop", crop]
            let error = ToolingError.invalidArgument("--crop is x,y,w,h in points, or an element's key or path")
            #expect(throws: error) { try ToolingArgs.parseChecked(argv) }
            let parsed = ToolingArgs.parse(argv)
            #expect(parsed.isHeadlessRequested)
            #expect(throws: error) { try HeadlessRunner.run(spec, args: parsed) }
        }
        let keyOnly = ToolingArgs.parse(["--crop", "one"])
        #expect(keyOnly.isHeadlessRequested)
        #expect(throws: ToolingError.invalidArgument("--crop KEY needs --snap")) {
            try HeadlessRunner.run(spec, args: keyOnly)
        }
    }

    @Test("A keyed or pathed crop rounds out and clips to the viewport; missing and empty targets report errors")
    func viewportCrop() throws {
        let runtime = Runtime(state: (), viewport: Vec2(10, 8), pixelScale: 2) { _, _ in
            col().sizeFull()
                .child(el().key("part").absolute(x: -1, y: 2).size(4, 3).offset(0.25, 0.25))
                .child(el().key("outside").absolute(x: 12, y: 1).size(2, 3))
                .child(el().key("empty").size(0, 0))
        }
        _ = runtime.frame(at: 0)
        let path = try #require(runtime.element(byKey: "part")?.path)
        for key in ["part", path] {
            let args = ToolingArgs.parse(["--snap", "frame.png", "--crop", key, "--scale", "2"])
            let crop = try HeadlessRunner.snapshotCrop(pixels(), runtime: runtime, args: args)
            try #require(crop.width == 7 && crop.height == 7)
            #expect(crop.pixel(x: 0, y: 0) == SIMD4<UInt8>(0, 4, 0, 255))
            #expect(crop.pixel(x: 6, y: 6) == SIMD4<UInt8>(6, 10, 0, 255))
        }
        for key in ["outside", "empty", "missing"] {
            let args = ToolingArgs.parse(["--snap", "frame.png", "--crop", key, "--scale", "2"])
            let reason = key == "missing" ? "no element has that key or path" : "the element is empty or outside the frame"
            #expect(throws: ToolingError.invalidArgument("--crop \(key): \(reason)")) {
                try HeadlessRunner.snapshotCrop(pixels(), runtime: runtime, args: args)
            }
        }
    }

    @Test("The playground searches onstage until --whole-window is requested and ignores an exiting target")
    func stageScope() throws {
        let runtime = Runtime(state: true, viewport: Vec2(20, 16), pixelScale: 1) { show, _ in
            let target: El<Bool> = el().key("target").size(2, 2).transition(.opacity)
            let stage: El<Bool> = col().key("playground-stage-2").size(8, 4)
            return col().sizeFull().child(el().key("outside").size(3, 3)).child(show ? stage.child(target) : stage)
        }
        _ = runtime.frame(at: 0)
        let frame = pixels()
        func crop(_ argv: [String]) throws -> Frame {
            let args = ToolingArgs.parse(["--snap", "frame.png", "--playground", "--scale", "1"] + argv)
            return try HeadlessRunner.snapshotCrop(frame, runtime: runtime, args: args)
        }
        let stage = try crop([])
        #expect(stage.width == 8 && stage.height == 4)
        #expect(try crop(["--crop", "target"]).width == 2)
        #expect(throws: ToolingError.invalidArgument("--crop outside: no element on the playground's stage has that key or path; --whole-window searches the whole window")) {
            try crop(["--crop", "outside"])
        }
        #expect(try crop(["--whole-window", "--crop", "outside"]).width == 3)
        #expect(try crop(["--whole-window"]) == frame)
        _ = runtime.frame(at: 1)
        runtime.update(at: 1) { show, _ in show = false }
        _ = runtime.frame(at: 1.01)
        #expect(runtime.elements().contains { $0.key == "target" && $0.exiting })
        #expect(throws: ToolingError.invalidArgument("--crop target: no element on the playground's stage has that key or path; --whole-window searches the whole window")) {
            try crop(["--crop", "target"])
        }
    }

    @Test("Numeric strip crops do not override the named snapshot; without a stage the whole window is searchable")
    func stripAndSnapSelections() throws {
        let runtime = Runtime(state: (), viewport: Vec2(20, 16), pixelScale: 1) { _, _ in
            el().key("panel").size(9, 4)
        }
        _ = runtime.frame(at: 0)
        let frame = pixels()
        let strip = ["--scale", "1", "--crop", "2,3,4,5"]
        let tiled = try HeadlessRunner.snapshotCrop(frame, runtime: runtime, args: .parse(strip))
        #expect(tiled.width == 4 && tiled.height == 5)
        #expect(tiled.pixel(x: 0, y: 0) == SIMD4<UInt8>(2, 3, 0, 255))
        let args = ToolingArgs.parse(strip + ["--snap", "frame.png", "--playground", "--crop", "panel"])
        let snap = try HeadlessRunner.snapshotCrop(frame, runtime: runtime, args: args)
        #expect(snap.width == 9 && snap.height == 4)
        #expect(try HeadlessRunner.snapshotCrop(frame, runtime: runtime, args: .parse(strip + ["--snap", "frame.png"])) == frame)
        let outside: [[Float]] = [[1000, 0, 1, 1]]
        #expect(throws: ToolingError.invalidArgument("--crop outside the frame")) {
            try HeadlessRunner.tileCrops(frame, cropRectsPt: outside, scale: 1)
        }
        let outOnly = ToolingArgs.parse(["--scale", "1", "--out", "frames", "--crop", "1000,0,1,1"])
        #expect(try HeadlessRunner.snapshotCrop(frame, runtime: runtime, args: outOnly) == frame)
        let emptyTile = try HeadlessRunner.tileCrops(frame, cropRectsPt: [[0, 0, 0, 2], [0, 0, 3, 1]], scale: 1)
        #expect(emptyTile.width == 3 && emptyTile.height == 7)
    }

    @Test("An out directory contains whole sampled frames while the scaled strip tiles only the requested regions")
    func samplesAndStripGeometry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rune-crops-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = directory.appendingPathComponent("out")
        let snap = directory.appendingPathComponent("snap.png")
        let strip = directory.appendingPathComponent("strip.png")
        let args = ToolingArgs.parse(["--force-cpu", "--scale", "2", "--size", "20x16",
                                      "--frames", "5", "--at", "0", "--every", "2", "--cols", "3",
                                      "--crop", "1.25,2.25,3.25,2.75", "--crop", "7,6,2,1",
                                      "--out", out.path, "--snap", snap.path, "--strip", strip.path])
        let spec = AppSpec(state: ()) { _, _ in el().sizeFull().bg(.black) }
        _ = try HeadlessRunner.run(spec, args: args)
        let sampled = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        #expect(sampled == ["frame_0000.png", "frame_0002.png", "frame_0004.png"])
        for path in [snap] + sampled.map({ out.appendingPathComponent($0) }) {
            let f = try Frame.fromPNG(data: Data(contentsOf: path))
            #expect(f.width == 40 && f.height == 32)
        }
        let sheet = try Frame.fromPNG(data: Data(contentsOf: strip))
        try #require(sheet.width == 37 && sheet.height == 16)
        #expect(sheet.pixel(x: 0, y: 0) == SIMD4<UInt8>(0, 0, 0, 255))
        #expect(sheet.pixel(x: 7, y: 0) == SIMD4<UInt8>(128, 128, 128, 255))
        #expect(sheet.pixel(x: 0, y: 6) == SIMD4<UInt8>(128, 128, 128, 255))
        #expect(sheet.pixel(x: 0, y: 14) == SIMD4<UInt8>(0, 0, 0, 255))
    }

    @Test("A single uncropped strip row samples every frame and floors the scaled inter-frame gutter")
    func fractionalScaleStrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rune-strip-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let args = ToolingArgs.parse(["--force-cpu", "--scale", "1.375", "--size", "20x16",
                                      "--frames", "2", "--strip", url.path])
        _ = try HeadlessRunner.run(AppSpec(state: ()) { _, _ in el().sizeFull().bg(.black) }, args: args)
        let sheet = try Frame.fromPNG(data: Data(contentsOf: url))
        try #require(sheet.width == 61 && sheet.height == 22)
        #expect(sheet.pixel(x: 27, y: 0) == SIMD4<UInt8>(0, 0, 0, 255))
        #expect(sheet.pixel(x: 32, y: 0) == SIMD4<UInt8>(128, 128, 128, 255))
        #expect(sheet.pixel(x: 33, y: 0) == SIMD4<UInt8>(0, 0, 0, 255))
    }
}
