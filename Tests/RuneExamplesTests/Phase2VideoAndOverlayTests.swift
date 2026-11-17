import Foundation
import Testing
@testable import Rune
@testable import RuneBackground
@testable import RuneGlassPanel
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

    @Test("video-player: CLI option parsing, default rgbw.mp4 muted/looping, paused audio, and headless render")
    func videoPlayerHeadlessAndParsing() throws {
        let defaultPath = RuneVideoPlayerApp.defaultVideoPath()
        #expect(FileManager.default.fileExists(atPath: defaultPath))

        let defOpts = RuneVideoPlayerApp.parseOptions(arguments: [])
        #expect(!defOpts.audio)
        #expect(defOpts.source == .file(defaultPath))

        let defaultPlayer = RuneVideoPlayerApp.makePlayer(arguments: [])
        #expect(!defaultPlayer.isAudio)
        #expect(defaultPlayer.isPlaying)
        #expect(defaultPlayer.isLooping)
        #expect(defaultPlayer.isMuted)

        let audioPlayer = RuneVideoPlayerApp.makePlayer(arguments: ["--audio"])
        #expect(audioPlayer.isAudio)
        #expect(!audioPlayer.isPlaying)
        #expect(!audioPlayer.isLooping)

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
        #expect(initialMuted)
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

    @Test("video-tiles: 2x2 NativeSurface grid renders synthetic frames and runs the native GPU benchmark")
    func videoTilesRenderAndBench() throws {
        #expect(VideoTilesBench.upstreamProfiles.count == 5)
        #expect(VideoTilesBench.upstreamProfiles.map(\.tiles) == [1, 4, 9, 1, 1])

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

        if try OffscreenGPURenderer.selected(for: ToolingArgs()) != nil {
            let result = try VideoTilesBench.runNativeBench(
                profiles: [(4, 640, 360)],
                runs: 2,
                framesPerRun: 4,
                pace60Hz: false
            )
            #expect(result.totalFrames == 8)
            #expect(result.profiles.count == 1)
            #expect(result.profiles[0].source == [640, 360])
            #expect(result.profiles[0].target == [1280, 720])
            #expect(result.profiles[0].warmupRuns == 1)
            #expect(result.profiles[0].runs.count == 1)
            #expect(result.fps > 0.0)
        }
    }

    // MARK: - RuneOverlay

    @Test("overlay: multi-window specs, stroke icon, click-through restore, and animated live cursor")
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
        #expect(controlsTree.contains("Display overlays"))
        #expect(controlsTree.contains("Test overlay input"))

        let overlay0At0 = try RuneMultiWindow.runHeadless(
            RuneOverlayApp.makeWindows(displays: displays, arguments: ["--headless"]),
            args: ToolingArgs.parse(["--window", "overlay-0", "--at", "0.0"])
        )
        let overlay0AtHalf = try RuneMultiWindow.runHeadless(
            RuneOverlayApp.makeWindows(displays: displays, arguments: ["--headless"]),
            args: ToolingArgs.parse(["--window", "overlay-0", "--at", "0.5"])
        )
        let overlayTree = String(decoding: overlay0AtHalf.treeJSON, as: UTF8.self)
        #expect(overlayTree.contains("\"stroke\""))
        #expect(overlayTree.contains("\"remote-cursor\""))
        #expect(overlay0At0.finalFrame.rgba != overlay0AtHalf.finalFrame.rgba)

        let rt = Runtime<OverlayCanvasState>(
            state: OverlayCanvasState(index: 0, bounds: Vec2(560, 440), cursor: Live(Vec2(120, 90))),
            viewport: Vec2(560, 440),
            pixelScale: 2.0,
            systemDark: true,
            view: RuneOverlayApp.overlayView
        )
        rt.frame(at: 0.0)
        rt.pointerDown(at: Vec2(20, 20), at: 0.05)
        rt.pointerUp(at: Vec2(20, 20), at: 0.10)
        rt.frame(at: 0.12)
        #expect(rt.state.restoredClickThroughCount == 1)

        let p0 = RuneOverlayApp.cursorPoint(forPhase: 0.0, bounds: Vec2(1440, 900), index: 0)
        let p1 = RuneOverlayApp.cursorPoint(forPhase: 0.5, bounds: Vec2(1440, 900), index: 0)
        #expect(p0 != p1)
    }

    // MARK: - RuneOverlayLab

    @Test("overlay-lab: capture exclusion default, underlay window options, picker button, commands, and scenes")
    func overlayLabOptionsCommandsAndScenes() throws {
        let displays = [
            DisplayInfo(id: RuneDisplayId(native: .macOS(10)), name: "Built-in", position: (0, 0), size: (1512, 982), scale: 2.0, primary: true),
            DisplayInfo(id: RuneDisplayId(native: .macOS(20)), name: "Studio", position: (1512, 0), size: (2560, 1440), scale: 2.0, primary: false),
        ]
        let lab = RuneOverlayLabApp.makeLab(displays: displays, excludeFromCapture: true, underlay: false)
        #expect(lab.excludeFromCapture)
        #expect(lab.pickers.count == 2)

        for picker in lab.pickers {
            #expect(picker.options.placement == .fullDisplay)
            #expect(picker.options.level == .aboveStatus)
            #expect(picker.options.input == .all)
            #expect(picker.options.keyPolicy == .activating)
            #expect(picker.options.excludeFromCapture)
            #expect(picker.options.prewarm)
        }

        #expect(lab.pill.options.display == .underPointer)
        #expect(lab.pill.options.followPointer)
        #expect(lab.pill.options.level == .aboveOverlays)
        #expect(lab.pill.options.input == .regions)
        #expect(lab.pill.options.keyPolicy == .nonActivating)
        #expect(lab.pill.options.excludeFromCapture)
        #expect(lab.pill.options.prewarm)

        let includeCaptureLab = RuneOverlayLabApp.makeLab(displays: displays, excludeFromCapture: false)
        #expect(!includeCaptureLab.pill.options.excludeFromCapture)
        #expect(!includeCaptureLab.pickers[0].options.excludeFromCapture)

        // Clicking Picker chip inside the pill triggers lab.showPicker() directly.
        lab.showPill()
        #expect(lab.pill.isVisible)
        lab.pill.runtime.state.expanded = true
        lab.pill.runtime.markNeedsCommit(settle: true)
        lab.pill.runtime.frame(at: 0.0)
        let pickerRect = try #require(lab.pill.runtime.element(byKey: "btn-picker")?.rect)
        let center = Vec2(pickerRect[0] + pickerRect[2] * 0.5, pickerRect[1] + pickerRect[3] * 0.5)
        lab.pill.runtime.pointerDown(at: center, at: 0.05)
        lab.pill.runtime.pointerUp(at: center, at: 0.10)
        lab.pill.runtime.frame(at: 0.12)
        #expect(!lab.pill.isVisible)
        #expect(lab.pickers[0].isVisible)
        lab.hideAll()

        #expect(lab.handleCommand("all") == "ok:all")
        #expect(lab.pill.options.input == .all)
        #expect(lab.handleCommand("hit") == "ok:regions")
        #expect(lab.pill.options.input == .regions)
        #expect(lab.handleCommand("expand") == "ok:expanded")
        #expect(lab.handleCommand("collapse") == "ok:collapsed")
        #expect(lab.handleCommand("status").contains("pickers=2"))

        let underlayWindows = RuneOverlayLabApp.makeUnderlayWindows(displays: displays, nativeWindow: true)
        #expect(underlayWindows.count == 1)

        for scene in ["pill", "expanded", "picker", "underlay", "hit-only"] {
            let out = try HeadlessRunner.run(
                RuneOverlayLabApp.makeApp(arguments: ["--headless"]),
                args: ToolingArgs.parse(["--scene", scene])
            )
            let tree = String(decoding: out.treeJSON, as: UTF8.self)
            if scene == "picker" {
                #expect(tree.contains("Display Picker #0"))
            } else if scene == "underlay" {
                #expect(tree.contains("Underlay clicks: 2"))
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

    // MARK: - RuneGlassPanel

    @Test("glass-panel: 3 overlays, levels, sRGB blend, continuous corners, system material, poll handoff, and scenes")
    func glassPanelOverlaysHandoffMaterialAndScenes() throws {
        let origin = GlassPanelConfig.defaultPlacementOrigin(environment: ["GLASS_PANEL_AT": "240,40"])
        #expect(origin.0 == 240 && origin.1 == 40)

        let coordinator = GlassPanelCoordinator()
        let backdropSpec = RuneGlassPanelApp.makeBackdropOverlaySpec(at: origin)
        let flightSpec = RuneGlassPanelApp.makeFlightOverlaySpec(at: origin, coordinator: coordinator)
        let dockSpec = RuneGlassPanelApp.makeDockOverlaySpec(at: origin)

        #expect(backdropSpec.options.macosLevel == 0)
        #expect(flightSpec.options.macosLevel == 4)
        #expect(dockSpec.options.macosLevel == 3)
        #expect(flightSpec.options.srgbBlend)
        #expect(dockSpec.options.srgbBlend)
        #expect(flightSpec.options.input == .none)
        #expect(flightSpec.options.keyPolicy == .none)
        #expect(flightSpec.options.prewarm)
        #expect(flightSpec.poll != nil)

        // Flight geometry: start -> lifted arc -> dock
        let f0 = RuneGlassPanelApp.flightFrame(0.0)
        #expect(abs(f0.rect.x - GlassPanelConfig.startRect.x) < 1e-3)
        #expect(abs(f0.radius - GlassPanelConfig.startRadius) < 1e-3)
        #expect(abs(f0.lift) < 1e-5)

        let fMid = RuneGlassPanelApp.flightFrame(0.5)
        #expect(fMid.lift > 0.99)
        #expect(fMid.rect.y < GlassPanelConfig.startRect.y)

        let f1 = RuneGlassPanelApp.flightFrame(1.0)
        #expect(abs(f1.rect.x - GlassPanelConfig.dockRect.x) < 1e-3)
        #expect(abs(f1.rect.width - GlassPanelConfig.dockRect.width) < 1e-3)
        #expect(abs(f1.radius - GlassPanelConfig.dockRadius) < 1e-3)

        // Headless poll + handoff transition on OverlayHandle states
        let backdrop = OverlayHandle(configured: backdropSpec)
        let flight = OverlayHandle(configured: flightSpec)
        let dock = OverlayHandle(configured: dockSpec)
        coordinator.install(backdrop: backdrop, flight: flight, dock: dock)

        var state = GlassPanelState(role: .flight, material: .glass, fly: true)
        var tx = Tx()
        #expect(RuneGlassPanelApp.pollFlight(&state, at: 1.0, &tx, coordinator: coordinator))
        #expect(state.started == 1.0)
        #expect(!state.handed)
        #expect(RuneGlassPanelApp.pollFlight(&state, at: 1.65, &tx, coordinator: coordinator))
        #expect(state.landed == 1.65)
        #expect(!state.handed)
        #expect(RuneGlassPanelApp.pollFlight(&state, at: 1.85, &tx, coordinator: coordinator))
        #expect(state.handed)
        #expect(dock.isVisible)
        #expect(!flight.isVisible)

        // SystemMaterial + continuous corners on card
        let rt = Runtime<GlassPanelState>(
            state: GlassPanelState(role: .dock, material: .popover, mark: true),
            viewport: GlassPanelConfig.dockWindowSize,
            pixelScale: 2.0,
            systemDark: true,
            view: RuneGlassPanelApp.view
        )
        rt.frame(at: 0.0)
        #expect(rt.element(byKey: "card") != nil)
        #expect(rt.element(byKey: "docked") != nil)
        #expect(rt.element(byKey: "mark") != nil)

        // Headless scenes match --scene asking / flight / docked / mark
        for scene in ["asking", "flight", "docked", "mark"] {
            let out = try HeadlessRunner.run(
                RuneGlassPanelApp.makeApp(arguments: ["--headless"]),
                args: ToolingArgs.parse(["--scene", scene])
            )
            let json = String(decoding: out.treeJSON, as: UTF8.self)
            #expect(json.contains("\"backdrop\""))
            #expect(json.contains("\"card\""))
            if scene == "asking" {
                #expect(json.contains("Allow screen recording?"))
            } else {
                #expect(json.contains("Waiting for access"))
            }
            if scene == "mark" {
                #expect(json.contains("\"mark\""))
            }
        }
    }
}
