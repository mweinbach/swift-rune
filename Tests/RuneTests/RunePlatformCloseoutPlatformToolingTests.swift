import Testing
import Foundation
import AppKit
@testable import Rune

@Suite("RunePlatformCloseoutPlatformToolingTests")
struct RunePlatformCloseoutPlatformToolingTests {
    // MARK: - platform/display_link.rs (5 tests)

    @Test("display_link: a frame defers starting the link only when it would draw at once anyway")
    func displayLinkDefersStartOnlyWhenDrawsAtOnce() {
        let period = 0.008
        let ms: (Int) -> Double = { Double($0) / 1000.0 }
        #expect(DisplayLinkPacer.defersStart(running: false, lastPresent: ms(100), lastTarget: ms(104), now: ms(133), period: period))
        for later in [133, 134, 150, 500] {
            #expect(DisplayLinkPacer.opportunity(tick: nil, lastPresent: ms(100), lastTarget: ms(104), now: ms(later), period: period) == .now)
        }
        #expect(DisplayLinkPacer.defersStart(running: false, lastPresent: nil, lastTarget: nil, now: ms(0), period: period))
        #expect(!DisplayLinkPacer.defersStart(running: false, lastPresent: ms(100), lastTarget: ms(100), now: ms(105), period: period))
        #expect(!DisplayLinkPacer.defersStart(running: false, lastPresent: ms(100), lastTarget: ms(130), now: ms(120), period: period))
        #expect(!DisplayLinkPacer.defersStart(running: true, lastPresent: ms(100), lastTarget: ms(104), now: ms(133), period: period))
    }

    @Test("display_link: late frames and idle restarts cannot catch up in a burst")
    func displayLinkLateFramesAndIdleRestartsNoBurst() {
        let period = 0.016
        let ms: (Int) -> Double = { Double($0) / 1000.0 }
        #expect(DisplayLinkPacer.permits(lastPresent: nil, lastTarget: nil, target: ms(16), now: ms(1), period: period))
        #expect(!DisplayLinkPacer.permits(lastPresent: ms(15), lastTarget: ms(16), target: ms(32), now: ms(17), period: period))
        #expect(!DisplayLinkPacer.permits(lastPresent: ms(15), lastTarget: ms(16), target: ms(32), now: ms(33), period: period))
        #expect(!DisplayLinkPacer.permits(lastPresent: ms(15), lastTarget: ms(32), target: ms(32), now: ms(30), period: period))
        #expect(DisplayLinkPacer.permits(lastPresent: ms(15), lastTarget: ms(16), target: ms(32), now: ms(30), period: period))
        #expect(!DisplayLinkPacer.permits(lastPresent: ms(100), lastTarget: ms(112), target: ms(128), now: ms(102), period: period))
    }

    @Test("display_link: a capped period skips ticks between frames")
    func displayLinkCappedPeriodSkipsTicks() {
        let capped = 0.016
        let ms: (Int) -> Double = { Double($0) / 1000.0 }
        #expect(!DisplayLinkPacer.permits(lastPresent: ms(0), lastTarget: ms(8), target: ms(16), now: ms(9), period: capped))
        #expect(DisplayLinkPacer.permits(lastPresent: ms(2), lastTarget: ms(8), target: ms(24), now: ms(17), period: capped))
        #expect(DisplayLinkPacer.permits(lastPresent: ms(2), lastTarget: ms(8), target: ms(16), now: ms(9), period: 0.008))
    }

    @Test("display_link: input at rest draws without waiting for a tick")
    func displayLinkInputAtRestDrawsNow() {
        let period = 0.008
        let ms: (Int) -> Double = { Double($0) / 1000.0 }
        #expect(DisplayLinkPacer.opportunity(tick: nil, lastPresent: ms(0), lastTarget: ms(8), now: ms(500), period: period) == .now)
        #expect(DisplayLinkPacer.opportunity(tick: nil, lastPresent: nil, lastTarget: nil, now: ms(0), period: period) == .now)
        #expect(DisplayLinkPacer.opportunity(tick: ms(400), lastPresent: ms(0), lastTarget: ms(8), now: ms(500), period: period) == .now)
        #expect(DisplayLinkPacer.opportunity(tick: ms(510), lastPresent: ms(0), lastTarget: ms(8), now: ms(500), period: period) == .tick(ms(510)))
    }

    @Test("display_link: a frame still on its way to the display waits for a tick")
    func displayLinkFrameInFlightWaitsForTick() {
        let period = 0.008
        let ms: (Int) -> Double = { Double($0) / 1000.0 }
        #expect(DisplayLinkPacer.opportunity(tick: nil, lastPresent: ms(100), lastTarget: ms(100), now: ms(111), period: period) == .wait)
        #expect(DisplayLinkPacer.opportunity(tick: nil, lastPresent: ms(100), lastTarget: ms(100), now: ms(112), period: period) == .now)
        #expect(DisplayLinkPacer.opportunity(tick: nil, lastPresent: ms(100), lastTarget: ms(130), now: ms(120), period: period) == .wait)
        #expect(DisplayLinkPacer.opportunity(tick: nil, lastPresent: ms(100), lastTarget: ms(100), now: ms(118), period: 0.016) == .wait)
        #expect(DisplayLinkPacer.opportunity(tick: ms(116), lastPresent: ms(100), lastTarget: ms(108), now: ms(102), period: period) == .wait)
    }

    // MARK: - platform/macos/help.rs (1 test)

    @Test("help: only changed regions are replaced")
    func helpOnlyChangedRegionsReplaced() {
        let toolbar: ([Float], String) = ([10, 4, 30, 24], "Copy")
        let row: (Float) -> ([Float], String) = { y in ([0, y, 200, y + 20], "Open") }

        let diff1 = MacOSToolTipOwner.diff(have: [toolbar, row(40)], want: [toolbar, row(30)])
        #expect(diff1.stays == [true, false])
        #expect(diff1.covered == [true, false])

        let diff2 = MacOSToolTipOwner.diff(have: [toolbar, toolbar], want: [toolbar])
        #expect(diff2.stays == [true, false])
        #expect(diff2.covered == [true])

        #expect(MacOSToolTipOwner.snap([10.3, 4.74, 30.0, 24.2], scale: 2.0) == [10.5, 4.5, 30.0, 24.0])
    }

    // MARK: - platform/accent.rs (1 test)

    @Test("accent: the default is macos blue with rings at half")
    func accentDefaultIsMacOSBlueWithRingsAtHalf() {
        let a = SystemAccent.default
        #expect(a.accent(dark: false).hex() == "#007affff")
        #expect(a.accent(dark: true).hex() == "#0a84ffff")
        #expect(a.focus(dark: false).hex() == "#007aff80")
        #expect(a.focus(dark: true).hex() == "#0a84ff80")
    }

    // MARK: - platform/app_icon.rs (1 test)

    @Test("app_icon: an icon must be valid RGBA and queues before launch")
    @MainActor
    func appIconValidatesAndQueuesBeforeLaunch() {
        #expect(AppIcon(width: 16, height: 16, rgba: Data("not an image".utf8)) == nil)
        #expect(AppIcon(width: 0, height: 16, rgba: Data()) == nil)
        let valid = AppIcon(
            width: 16,
            height: 16,
            rgba: Data((0..<(16 * 16)).flatMap { _ in [UInt8(40), 120, 220, 255] })
        )
        #expect(valid != nil)
        if let valid {
            #expect(MacOSDockIconApplier.makeNSImage(from: valid) != nil)
            let shared = AppShared<Int>()
            shared.requestDockIcon(valid)
            #expect(shared.take().dockIcon == valid)
        }
    }

    // MARK: - platform/layer_shell.rs (1 test)

    @Test("layer_shell: special keysyms are named keys")
    func layerShellSpecialKeysymsAreNamedKeys() {
        let expected: [(UInt32, Key)] = [
            (0xFF14, .scrollLock),
            (0xFF13, .pause),
            (0xFF6B, .pause),
            (0xFF67, .contextMenu),
            (0xFF61, .printScreen),
            (0xFF15, .printScreen),
            (0xFF63, .insert),
            (0xFFBE, .f(1)),
            (0xFFD5, .f(24)),
            (0xFF55, .pageUp),
        ]
        for (sym, key) in expected {
            #expect(LinuxKeyMap.namedKeysym(sym) == key)
        }
        #expect(LinuxKeyMap.namedKeysym(0x61) == nil)
    }

    // MARK: - window/keys.rs (1 test)

    @Test("keys: keys that type nothing reach handlers")
    func keysThatTypeNothingReachHandlers() throws {
        // Win32 virtual keys
        #expect(Win32KeyMap.translate(virtualKey: 0x91) == .scrollLock)
        #expect(Win32KeyMap.translate(virtualKey: 0x13) == .pause)
        #expect(Win32KeyMap.translate(virtualKey: 0x5D) == .contextMenu)
        #expect(Win32KeyMap.translate(virtualKey: 0x2C) == .printScreen)
        #expect(Win32KeyMap.translate(virtualKey: 0x2D) == .insert)

        // macOS NSEvent function-key scalars and key codes
        func makeKey(chars: String, keyCode: UInt16) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: chars,
                isARepeat: false,
                keyCode: keyCode
            )
        }
        let cases: [(String, UInt16, Key)] = [
            ("\u{F72F}", 0, .scrollLock),
            ("\u{F730}", 0, .pause),
            ("", 110, .contextMenu),
            ("\u{F72E}", 0, .printScreen),
            ("\u{F727}", 114, .insert),
        ]
        for (chars, code, expected) in cases {
            let ev = try #require(makeKey(chars: chars, keyCode: code))
            #expect(MacOSKeyMapper.makeKeyEvent(from: ev)?.key == expected)
        }
    }

    // MARK: - tooling/window_tests.rs (1 test)

    @Test("tooling: transparent png unpremultiplies in linear space")
    func toolingTransparentPNGUnpremultipliesInLinearSpace() {
        var pixels: [UInt8] = [188, 0, 0, 128, 255, 255, 255, 0, 12, 34, 56, 255]
        HeadlessRunner.straightAlpha(&pixels)
        #expect(pixels == [255, 0, 0, 128, 0, 0, 0, 0, 12, 34, 56, 255])
    }

    // MARK: - tooling/record.rs (3 tests)

    @Test("record: video containers follow the extension")
    func recordVideoContainersFollowExtension() throws {
        let mp4Args = try ToolingVideoEncoder.ffmpegArgs(outputPath: "out.mp4", width: 1920, height: 1200, fps: 60.0)
        let joined = mp4Args.joined(separator: " ")
        #expect(joined.contains("-f rawvideo -pix_fmt rgba -s 1920x1200 -r 60 -i -"))
        #expect(joined.contains("libx264") && joined.contains("+faststart") && joined.hasSuffix("out.mp4"))

        let movArgs = try ToolingVideoEncoder.ffmpegArgs(outputPath: "b.mov", width: 2, height: 2, fps: 60.0)
        #expect(movArgs.contains("prores_ks"))
        let webmArgs = try ToolingVideoEncoder.ffmpegArgs(outputPath: "b.webm", width: 2, height: 2, fps: 60.0)
        #expect(webmArgs.contains("libvpx-vp9"))

        #expect(throws: ToolingError.self) {
            _ = try ToolingVideoEncoder.ffmpegArgs(outputPath: "b.gif", width: 2, height: 2, fps: 60.0)
        }

        for (path, output) in [("-out.mp4", "./-out.mp4"), ("-dir/out.mov", "./-dir/out.mov"), ("dir/-out.webm", "dir/-out.webm")] {
            let args = try ToolingVideoEncoder.ffmpegArgs(outputPath: path, width: 2, height: 2, fps: 60.0)
            #expect(args.last == output)
        }
    }

    @Test("record: unpad drops row padding")
    func recordUnpadDropsRowPadding() {
        let data: [UInt8] = [1, 2, 3, 4, 9, 9, 9, 9, 5, 6, 7, 8, 9, 9, 9, 9]
        #expect(ToolingVideoEncoder.unpad(data, width: 1, height: 2, bytesPerRow: 8) == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test("record: encoder errors close stdin and report the exit status")
    func recordEncoderErrorsCloseStdinAndReportExitStatus() throws {
        func start(_ command: String) throws -> ToolingVideoEncoder {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", command]
            let pipe = Pipe()
            proc.standardInput = pipe
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            return ToolingVideoEncoder(process: proc, stdinPipe: pipe, outputPath: "test.mp4", width: 64, height: 64)
        }

        let frame = Frame(width: 64, height: 64, rgba: [UInt8](repeating: 0, count: 64 * 64 * 4))

        let early = try start("exit 17")
        var earlyMessage: String? = nil
        for _ in 0..<20 {
            do {
                try early.writeFrame(frame)
            } catch {
                earlyMessage = String(describing: error)
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        let msg1 = try #require(earlyMessage)
        #expect(msg1.contains("17") && msg1.contains("stopped reading"))

        let late = try start("cat >/dev/null; exit 23")
        try late.writeFrame(frame)
        var lateMessage: String? = nil
        do {
            try late.finish()
        } catch {
            lateMessage = String(describing: error)
        }
        let msg2 = try #require(lateMessage)
        #expect(msg2.contains("23") && msg2.contains("failed writing"))

        let success = try start("cat >/dev/null")
        try success.writeFrame(frame)
        #expect(try success.finish() == "test.mp4")
    }
}
