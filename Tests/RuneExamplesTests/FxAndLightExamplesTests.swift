import Foundation
import Testing
#if canImport(Metal)
import Metal
#endif
@testable import RuneFxFirstGlow
@testable import RuneFxGallery
@testable import RuneLightShaderFirstUse
@testable import RuneLightFrameBench
@testable import RuneLightDemos
@testable import RuneLightLive
@testable import RuneLightReel

@Suite("RuneFX & RuneLight Examples Parity Tests", .serialized)
struct FxAndLightExamplesTests {
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-fx-light-examples-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func assertValidPNG(at url: URL) throws {
        let data = try Data(contentsOf: url)
        #expect(data.count > 64)
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    @Test("rune-fx-first-glow creates FxRenderer, renders first glow, and writes PNG snap")
    func fxFirstGlowSnap() throws {
        #if canImport(Metal)
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        try withTempDir { dir in
            let snap = dir.appendingPathComponent("first-glow.png")
            try RuneFxFirstGlowApp.run(args: ["--snap", snap.path])
            try assertValidPNG(at: snap)
        }
        #endif
    }

    @Test("rune-fx-gallery lists effects and renders glow & blend snaps")
    func fxGallerySnaps() throws {
        #if canImport(Metal)
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        try withTempDir { dir in
            try RuneFxGalleryApp.run(args: ["--list-effects"])
            let glowSnap = dir.appendingPathComponent("glow.png")
            try RuneFxGalleryApp.run(args: ["--snap", glowSnap.path, "--effect", "glow"])
            try assertValidPNG(at: glowSnap)

            let blendSnap = dir.appendingPathComponent("blend.png")
            try RuneFxGalleryApp.run(args: ["--snap", blendSnap.path, "--effect", "blend"])
            try assertValidPNG(at: blendSnap)
        }
        #endif
    }

    @Test("rune-light-shader-first-use builds every Fx/Light/Glass pipeline and writes PNG snap")
    func lightShaderFirstUseSnap() throws {
        #if canImport(Metal)
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        try withTempDir { dir in
            let snap = dir.appendingPathComponent("first-use.png")
            try RuneLightShaderFirstUseApp.run(args: ["--snap", snap.path])
            try assertValidPNG(at: snap)
        }
        #endif
    }

    @Test("rune-light-frame-bench runs --fast GPU recording benchmark and writes PNG snap")
    func lightFrameBenchFastSnap() throws {
        #if canImport(Metal)
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        try withTempDir { dir in
            let snap = dir.appendingPathComponent("bench.png")
            try RuneLightFrameBenchApp.run(args: ["--fast", "--snap", snap.path])
            try assertValidPNG(at: snap)
        }
        #endif
    }

    @Test("rune-light-demos verifies soft-shadow accuracy and renders chat scene snap")
    func lightDemosVerifyAndSnap() throws {
        #if canImport(Metal)
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        try withTempDir { dir in
            let outDir = dir.appendingPathComponent("out", isDirectory: true)
            try RuneLightDemosApp.run(args: ["verify", "--out", outDir.path])
            let snap = dir.appendingPathComponent("chat.png")
            try RuneLightDemosApp.run(args: ["--snap", snap.path, "--scene", "chat"])
            try assertValidPNG(at: snap)
        }
        #endif
    }

    @Test("rune-light-live renders flashlight and chat snaps headlessly")
    func lightLiveSnaps() throws {
        #if canImport(Metal)
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        try withTempDir { dir in
            let flashSnap = dir.appendingPathComponent("flashlight.png")
            try RuneLightLiveApp.run(args: ["--snap", flashSnap.path, "--scene", "flashlight", "--at", "640,400"])
            try assertValidPNG(at: flashSnap)

            let chatSnap = dir.appendingPathComponent("live-chat.png")
            try RuneLightLiveApp.run(args: ["--snap", chatSnap.path, "--scene", "chat", "--click"])
            try assertValidPNG(at: chatSnap)
        }
        #endif
    }

    @Test("rune-light-reel renders deterministic frame still at t=5.5")
    func lightReelSnap() throws {
        #if canImport(Metal)
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        try withTempDir { dir in
            let snap = dir.appendingPathComponent("reel-5.5.png")
            try RuneLightReelApp.run(args: ["--snap", snap.path, "--t", "5.5"])
            try assertValidPNG(at: snap)
        }
        #endif
    }
}
