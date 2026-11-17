import Foundation
import RuneRef
import Testing
@testable import Rune

@Suite("CPU boot capture CLI")
struct CpuBootCaptureTests {
    @Test("The capture option consumes its directory and validates the snapshot and worker arguments")
    func arguments() throws {
        let parsed = try ToolingArgs.parseChecked(["--cpu-boot", "capture", "--snap", "snap.png", "custom"])
        #expect(parsed.cpuBootDirectory == "capture")
        #expect(parsed.cpuBootThreads == 6)
        #expect(parsed.isHeadlessRequested)
        #expect(parsed.extraArgs == ["custom"])
        #expect(try ToolingArgs.parseChecked(["--cpu-boot-threads", "0"]).cpuBootThreads == 1)
        #expect(try ToolingArgs.parseChecked(["--cpu-boot-threads", "3.5"]).cpuBootThreads == 3)
        for invalid in [["--cpu-boot"], ["--cpu-boot", "dir"], ["--cpu-boot-threads", "many"]] {
            #expect(throws: ToolingError.self) { try ToolingArgs.parseChecked(invalid) }
        }
    }

    @Test("A CPU mask burst publishes each atlas page once and preserves earlier frame snapshots")
    func queuedMaskPages() throws {
        let atlas = GlyphAtlas(width: 90, height: 60)
        atlas.defersOutlineMasks = true
        let shape = atlas.withOutlineStore { store in
            store.glyph(.init(font: 1, glyph: 1)) {
                OutlineBuilder.build(commands: [.moveTo(SIMD2(0, 0)), .lineTo(SIMD2(34, 0)),
                    .quadTo(SIMD2(25, 26), SIMD2(8, 36)), .close], upem: 40)
            }
        }
        guard case let .outline(record) = shape else { Issue.record("Missing glyph outline"); return }
        for i in 0..<6 {
            let fill = OutlineFillParams(record: record.record, scale: 1,
                pen: SIMD2(2 + Float(i) / 8, 38 + Float(i % 3) / 4))
            _ = try #require(atlas.placeOutlineMask(width: 40, height: 42, fill: fill))
        }
        let deferred = atlas.framePages()
        try #require(deferred.bases.count == 3)
        let expected = try deferred.fills.map { try #require($0).cpuAtlas() }
        let pool = CpuBootPool(threads: 4)
        atlas.fillMasks(on: pool)
        try withExtendedLifetime(pool) {
            let filled = atlas.framePages()
            #expect(filled.fills.isEmpty)
            #expect(filled.bases.map(\.texels) == expected.map(\.texels))
            #expect(deferred.bases.allSatisfy { !$0.texels.contains { $0 > 0 } })
            #expect(filled.rawRevisions != deferred.rawRevisions)
            #expect(atlas.outlineFillStats.masks == 6)
            #expect(atlas.outlineFillStats.texels == 6 * 40 * 42)
            #expect(atlas.framePages().rawRevisions == filled.rawRevisions)
            #expect(atlas.outlineFillStats.masks == 6)
            atlas.defersOutlineMasks = false
            let next = OutlineFillParams(record: record.record, scale: 1, pen: SIMD2(2.25, 38))
            _ = try #require(atlas.placeOutlineMask(width: 40, height: 42, fill: next))
            #expect(atlas.outlineFillStats.masks == 6)
            #expect(atlas.framePages().fills.isEmpty)
            #expect(atlas.outlineFillStats.masks == 7)
        }
    }

    #if os(macOS)
    @Test("GPU comparison consumes the CPU's resting outline masks once")
    @MainActor
    func restingOutlineFills() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = App(title: "outline fill", size: Vec2(112, 48), state: ()) { _, _ in
            col().sizeFull().center().bg(.white)
                .child(text("Rune").font(Tok.Typography.title).color(.black))
        }.fontSmoothing(.windfoil)
        let args = try ToolingArgs.parseChecked(["--cpu-boot", dir.path, "--snap",
            dir.appendingPathComponent("snap.png").path, "--at", "0.1", "--fps", "10", "--scale", "1"])
        do { _ = try HeadlessRunner.run(app, args: args) }
        catch OffscreenRenderError.unavailable { return }

        let log = try String(contentsOf: dir.appendingPathComponent("frames.jsonl"), encoding: .utf8)
        let rows = try log.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        try #require(rows.count == 2)
        let first = try #require(rows[0]["fill"] as? [String: Int])
        #expect((first["masks"] ?? 0) >= 4)
        #expect((first["texels"] ?? 0) > 0)
        let cost = try #require(first["cover_ns"]) + (try #require(first["copy_ns"]))
        let cpuNs = try #require(rows[0]["cpu_ns"] as? Int)
        #expect(cost > 0 && cpuNs >= cost)
        let last = try #require(rows[1]["fill"] as? [String: Int])
        #expect(last.values.allSatisfy { $0 == 0 })
        let cpu = try Frame.fromPNG(data: Data(contentsOf: dir.appendingPathComponent("cpu.png")))
        let gpu = try Frame.fromPNG(data: Data(contentsOf: dir.appendingPathComponent("gpu.png")))
        #expect(cpu.rgba.contains { $0 < 128 })
        #expect(zip(cpu.rgba, gpu.rgba).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
    }
    #endif

    @Test("CPU and GPU snapshots describe the selected tick while subsequent scripted frames continue")
    func captureBeforeLaterInput() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let red = Color.srgb(1, 0, 0), green = Color.srgb(0, 1, 0)
        let spec = AppSpec(title: "capture", size: Vec2(32, 16), state: false) { changed, _ in
            el().key("box").wFull().hFull().bg(changed ? green : red).onClick { state, tx in
                state = true
                tx.instant()
            }
        }
        let snap = dir.appendingPathComponent("snap.png")
        let frames = dir.appendingPathComponent("output")
        let args = try ToolingArgs.parseChecked([
            "--cpu-boot", dir.path, "--cpu-boot-threads", "2", "--snap", snap.path,
            "--out", frames.path, "--frames", "5", "--at", "0.1", "--fps", "10", "--scale", "1",
            "--script", #"[{"t":0.2,"type":"click","key":"box","hold":0.01}]"#
        ])
        do { _ = try HeadlessRunner.run(spec, args: args) }
        catch OffscreenRenderError.unavailable { return }

        let log = try String(contentsOf: dir.appendingPathComponent("frames.jsonl"), encoding: .utf8)
        let rows = try log.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(rows.compactMap { $0["k"] as? Int } == Array(0...4))
        let first = try #require(rows[0]["paint"] as? [String: Any])
        let second = try #require(rows[1]["paint"] as? [String: Any])
        #expect(first["dirty_px"] as? Int == 32 * 16)
        #expect(second["dirty_tiles"] as? Int == 0)
        #expect(rows.allSatisfy { $0["threads"] as? Int == 2 && $0["fill"] != nil && $0["kinds"] == nil })
        func read(_ url: URL) throws -> Frame { try Frame.fromPNG(data: Data(contentsOf: url)) }
        let cpu = try read(dir.appendingPathComponent("cpu.png"))
        let gpu = try read(dir.appendingPathComponent("gpu.png"))
        #expect(cpu == gpu)
        #expect(try read(snap) == gpu)
        #expect(gpu.pixel(x: 15, y: 8) == SIMD4(255, 0, 0, 255))
        let finalPixel = try read(frames.appendingPathComponent("frame_0004.png")).pixel(x: 15, y: 8)
        #expect(finalPixel == SIMD4(0, 255, 0, 255))
        let file = try Data(contentsOf: dir.appendingPathComponent("draw.bin"))
        let replay = try #require(CpuBootRecord.decode(Array(file)))
        #expect(replay.instances.filter { $0.params.y == KIND_RECT }.allSatisfy { $0.params.z == 0 })
        var target = CpuBootTarget(width: 32, height: 16)
        _ = try CpuBoot.paint(replay.scene(), into: &target, threads: 1)
        #expect(target.toRGBA8Tight() == cpu.rgba)
    }
}
