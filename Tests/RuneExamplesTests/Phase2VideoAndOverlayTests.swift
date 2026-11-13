import Foundation
import Metal
import Testing
@testable import Rune
@testable import RuneBackground
@testable import RuneOverlay
@testable import RuneOverlayLab
@testable import RuneVideoPlayer
@testable import RuneVideoTiles

@Suite("Phase 2 Video and Overlay Example Parity Tests", .serialized)
@MainActor
struct Phase2VideoAndOverlayTests {
    // MARK: - Helpers

    private func hasPixelVariation(_ rgba: [UInt8]) -> Bool {
        guard rgba.count >= 8 else { return false }
        let r0 = rgba[0], g0 = rgba[1], b0 = rgba[2]
        var i = 4
        while i + 3 < rgba.count {
            if rgba[i] != r0 || rgba[i + 1] != g0 || rgba[i + 2] != b0 {
                return true
            }
            i += 16
        }
        return false
    }

    // MARK: - RuneVideoPlayer

    @Test("video-player: CLI option parsing, default rgbw.mp4 fixture, and headless render")
    func videoPlayerHeadlessAndParsing() throws {
        let defaultPath = RuneVideoPlayerApp.defaultVideoPath()
        #expect(FileManager.default.fileExists(atPath: defaultPath))

        let defOpts = RuneVideoPlayerApp.parseOptions(arguments: [])
        #expect(!defOpts.audio)
        #expect(defOpts.source == .file(defaultPath))

        let audioUrlOpts = RuneVideoPlayerApp.parseOptions(arguments: ["--audio", "--url", "https://example.com/clip.m4a"])
        #expect(audioUrlOpts.audio)
        #expect(audioUrlOpts.source == .url("https://example.com/clip.m4a"))

        let playingOut = try HeadlessRunner.run(
            RuneVideoPlayerApp.makeSpec(arguments: ["--headless"]),
            args: ToolingArgs.parse(["--scene", "playing", "--at", "0.6"])
        )
        let playingTree = String(decoding: playingOut.treeJSON, as: UTF8.self)
        #expect(playingTree.contains("\"video\""))
        #expect(hasPixelVariation(playingOut.finalFrame.rgba))

        let hiddenOut = try HeadlessRunner.run(
            RuneVideoPlayerApp.makeSpec(arguments: ["--headless"]),
            args: ToolingArgs.parse(["--scene", "hidden"])
        )
        let hiddenTree = String(decoding: hiddenOut.treeJSON, as: UTF8.self)
        #expect(hiddenTree.contains("\"video\""))
        #expect(hiddenTree.contains("Paused"))

        let audioOut = try HeadlessRunner.run(
            RuneVideoPlayerApp.makeSpec(arguments: ["--headless", "--audio"]),
            args: ToolingArgs.parse(["--at", "0.2"])
        )
        let audioTree = String(decoding: audioOut.treeJSON, as: UTF8.self)
        #expect(audioTree.contains("\"progress\""))
    }

    @Test("video-player: keyboard transport toggles play, mute, volume, loop, hide, and seek")
    func videoPlayerKeyboardTransport() throws {
        let spec = RuneVideoPlayerApp.makeSpec(arguments: ["--headless"])
        let rt = Runtime<RuneVideoPlayer.VideoPlayerState>(
            state: spec.makeState(),
            viewport: spec.size,
            pixelScale: 2.0,
            systemDark: true,
            onKey: spec.onKey,
            view: spec.view
        )
        rt.poll = spec.poll

        let initialMuted = rt.state.clip.isMuted
        #expect(rt.keyDown(KeyEvent(key: .text("m")), at: 0.1))
        #expect(rt.state.clip.isMuted == !initialMuted)

        #expect(rt.keyDown(KeyEvent(key: .text("v")), at: 0.2))
        #expect(rt.state.clip.volume == 0.0)
        #expect(rt.keyDown(KeyEvent(key: .text("v")), at: 0.3))
        #expect(rt.state.clip.volume == 1.0)

        let initialLoop = rt.state.clip.isLooping
        #expect(rt.keyDown(KeyEvent(key: .text("l")), at: 0.4))
        #expect(rt.state.clip.isLooping == !initialLoop)

        #expect(!rt.state.hidden)
        #expect(rt.keyDown(KeyEvent(key: .text("h")), at: 0.5))
        #expect(rt.state.hidden)

        let wasPlaying = rt.state.clip.isPlaying
        #expect(rt.keyDown(KeyEvent(key: .space), at: 0.6))
        #expect(rt.state.clip.isPlaying != wasPlaying)

        #expect(rt.keyDown(KeyEvent(key: .arrowRight), at: 0.7))
        #expect(rt.keyDown(KeyEvent(key: .arrowLeft), at: 0.8))
        #expect(rt.keyDown(KeyEvent(key: .text("0")), at: 0.9))
    }

    // MARK: - RuneVideoTiles

    @Test("video-tiles: 2x2 NativeSurface grid renders synthetic frames and native Metal bench")
    func videoTilesRenderAndBench() throws {
        let initialOut = try HeadlessRunner.run(
            RuneVideoTilesApp.makeSpec(arguments: ["--headless"]),
            args: ToolingArgs.parse(["--scene", "initial"])
        )
        let initialTree = String(decoding: initialOut.treeJSON, as: UTF8.self)
        for i in 0..<4 {
            #expect(initialTree.contains("\"tile-\(i)\""))
        }
        #expect(hasPixelVariation(initialOut.finalFrame.rgba))

        let frame30Out = try HeadlessRunner.run(
            RuneVideoTilesApp.makeSpec(arguments: ["--headless"]),
            args: ToolingArgs.parse(["--scene", "frame-30"])
        )
        #expect(hasPixelVariation(frame30Out.finalFrame.rgba))
        #expect(initialOut.finalFrame.rgba != frame30Out.finalFrame.rgba)

        if MTLCreateSystemDefaultDevice() != nil {
            let result = try VideoTilesBench.runNativeBench(frameCount: 4)
            #expect(result.frames == 4)
            #expect(result.fps > 0.0)
        }
    }

    // MARK: - RuneOverlay

    @Test("overlay: multi-window specs, headless overlay selection, and animated live cursor")
    func overlayMultiWindowAndCursorMotion() throws {
        let displays = [
            DisplayInfo(id: RuneDisplayId(native: .macOS(1)), name: "Main", position: (0, 0), size: (1440, 900), scale: 2.0, primary: true),
            DisplayInfo(id: RuneDisplayId(native: .macOS(2)), name: "Side", position: (1440, 0), size: (1920, 1080), scale: 2.0, primary: false),
        ]
        let windows = RuneOverlayApp.makeWindows(displays: displays, arguments: ["--headless"])
        #expect(windows.map(\.key) == ["controls", "overlay-0", "overlay-1"])

        let controlsOut = try RuneMultiWindow.runHeadless(
            RuneOverlayApp.makeWindows(displays: displays, arguments: ["--headless"]),
            args: ToolingArgs.parse(["--window", "controls"])
        )
        #expect(controlsOut.windowKeys == ["controls"])
        let controlsTree = String(decoding: controlsOut.treeJSON, as: UTF8.self)
        #expect(controlsTree.contains("Overlay Controls"))
        #expect(controlsTree.contains("Click-through: ON"))
        #expect(controlsTree.contains("toggle-click-through"))

        let overlay0At0 = try RuneMultiWindow.runHeadless(
            RuneOverlayApp.makeWindows(displays: displays, arguments: ["--headless"]),
            args: ToolingArgs.parse(["--window", "overlay-0", "--at", "0.0"])
        )
        let overlay0AtHalf = try RuneMultiWindow.runHeadless(
            RuneOverlayApp.makeWindows(displays: displays, arguments: ["--headless"]),
            args: ToolingArgs.parse(["--window", "overlay-0", "--at", "0.5"])
        )
        let overlayTree = String(decoding: overlay0AtHalf.treeJSON, as: UTF8.self)
        #expect(overlayTree.contains("Overlay 0 (1440x900)"))
        #expect(overlayTree.contains("cursor-0"))
        #expect(overlay0At0.finalFrame.rgba != overlay0AtHalf.finalFrame.rgba)

        let p0 = RuneOverlayApp.cursorPoint(forPhase: 0.0, bounds: Vec2(1440, 900), index: 0)
        let p1 = RuneOverlayApp.cursorPoint(forPhase: 0.5, bounds: Vec2(1440, 900), index: 0)
        #expect(p0 != p1)
    }

    // MARK: - RuneOverlayLab

    @Test("overlay-lab: per-display pickers, pointer-following pill options, commands, and scenes")
    func overlayLabOptionsCommandsAndScenes() throws {
        let displays = [
            DisplayInfo(id: RuneDisplayId(native: .macOS(10)), name: "Built-in", position: (0, 0), size: (1512, 982), scale: 2.0, primary: true),
            DisplayInfo(id: RuneDisplayId(native: .macOS(20)), name: "Studio", position: (1512, 0), size: (2560, 1440), scale: 2.0, primary: false),
        ]
        let lab = RuneOverlayLabApp.makeLab(displays: displays, underlay: true)
        #expect(lab.underlay)
        #expect(lab.pickers.count == 2)

        for picker in lab.pickers {
            #expect(picker.options.placement == .fullDisplay)
            #expect(picker.options.level == .aboveStatus)
            #expect(picker.options.input == .all)
            #expect(picker.options.keyPolicy == .activating)
            #expect(picker.options.prewarm)
        }

        #expect(lab.pill.options.display == .underPointer)
        #expect(lab.pill.options.followPointer)
        #expect(lab.pill.options.level == .aboveOverlays)
        #expect(lab.pill.options.input == .regions)
        #expect(lab.pill.options.keyPolicy == .nonActivating)
        #expect(lab.pill.options.prewarm)

        #expect(lab.handleCommand("all") == "ok:all")
        #expect(lab.pill.options.input == .all)
        #expect(lab.handleCommand("hit") == "ok:regions")
        #expect(lab.pill.options.input == .regions)
        #expect(lab.handleCommand("expand") == "ok:expanded")
        #expect(lab.handleCommand("collapse") == "ok:collapsed")
        #expect(lab.handleCommand("status").contains("pickers=2"))

        for scene in ["pill", "expanded", "picker", "underlay", "hit-only"] {
            let out = try HeadlessRunner.run(
                RuneOverlayLabApp.makeApp(arguments: ["--headless"]),
                args: ToolingArgs.parse(["--scene", scene])
            )
            let tree = String(decoding: out.treeJSON, as: UTF8.self)
            if scene == "picker" || scene == "underlay" {
                #expect(tree.contains("Display Picker #0"))
            } else {
                #expect(tree.contains("Overlay Lab"))
                #expect(tree.contains("pill-card"))
            }
        }
    }

    // MARK: - RuneBackground

    @Test("background: windowless/open/accessory/release-gpu flags, --hud-large, and overlay specs")
    func backgroundWindowlessAndOverlaySpecs() throws {
        let defaultApp = RuneBackgroundApp.makeApp(arguments: [])
        #expect(defaultApp.isWindowless)
        #expect(!defaultApp.isAccessory)
        #expect(defaultApp.keepsRunning)
        #expect(!defaultApp.releasesGpuWhenClosed)
        #expect(defaultApp.overlayReceivers.map(\.0.name) == ["background-hud", "background-capsule"])
        #expect(defaultApp.overlayReceivers[0].0.size == Vec2(240, 44))

        let openApp = RuneBackgroundApp.makeApp(arguments: ["--open", "--accessory", "--release-gpu", "--hud-large"])
        #expect(!openApp.isWindowless)
        #expect(openApp.isAccessory)
        #expect(openApp.releasesGpuWhenClosed)
        #expect(openApp.overlayReceivers[0].0.size == Vec2(1200, 700))

        let hudHandle = OverlayHandle(spec: defaultApp.overlayReceivers[0].0)
        hudHandle.setEdge(.bottom)
        #expect(hudHandle.placementSpec.edge == .bottom)
        hudHandle.setEdge(.top)
        #expect(hudHandle.placementSpec.edge == .top)

        let capsuleHandle = OverlayHandle(spec: defaultApp.overlayReceivers[1].0)
        capsuleHandle.setAlign(.start, inset: 12.0)
        capsuleHandle.resize(Vec2(320, 48))
        #expect(capsuleHandle.placementSpec.align == .start)
        #expect(capsuleHandle.placementSpec.inset == 12.0)
        #expect(capsuleHandle.size == Vec2(320, 48))

        let tickedOut = try HeadlessRunner.run(
            RuneBackgroundApp.makeApp(arguments: ["--headless"]),
            args: ToolingArgs.parse(["--scene", "ticked"])
        )
        let tree = String(decoding: tickedOut.treeJSON, as: UTF8.self)
        #expect(tree.contains("\"window\""))
        #expect(tree.contains("42 ticks from a background thread"))
    }
}
