import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("Rune Multi-Platform Parity Tests")
struct RunePlatformParityTests {

    // MARK: - 1. layer_shell_machine_tests.rs

    private func eachSequence<T>(
        alphabet: [T],
        depth: Int,
        seq: inout [T],
        each: ([T]) -> Void
    ) {
        each(seq)
        if seq.count == depth { return }
        for symbol in alphabet {
            seq.append(symbol)
            eachSequence(alphabet: alphabet, depth: depth, seq: &seq, each: each)
            _ = seq.popLast()
        }
    }

    private struct OldTouch {
        var id: Int32?

        mutating func step(_ event: LayerShellTouchEvent) -> [LayerShellTouchEffect] {
            switch event {
            case .down(let id, let x, let y) where self.id == nil:
                self.id = id
                return [.move(x, y), .press]
            case .motion(let id, let x, let y) where self.id == id:
                return [.move(x, y)]
            case .up(let id) where self.id == id:
                self.id = nil
                return [.release, .leave]
            case .cancel where self.id != nil:
                self.id = nil
                return [.leave, .release]
            case .gone:
                self.id = nil
                return []
            default:
                return []
            }
        }
    }

    @Test("LayerShellTouchMachine: every sequence up to depth 5 matches reference finger")
    func everyTouchSequenceMatchesOldFinger() {
        let alphabet: [LayerShellTouchEvent] = [
            .down(id: 0, x: 1.0, y: 2.0),
            .down(id: 1, x: 3.0, y: 4.0),
            .motion(id: 0, x: 5.0, y: 6.0),
            .motion(id: 1, x: 7.0, y: 8.0),
            .up(id: 0),
            .up(id: 1),
            .cancel,
            .gone,
        ]
        var seq: [LayerShellTouchEvent] = []
        eachSequence(alphabet: alphabet, depth: 5, seq: &seq) { seq in
            var finger = LayerShellTouchState.up
            var old = OldTouch()
            var presses = 0
            var releases = 0
            var orphaned = 0
            for event in seq {
                if case .gone = event, old.id != nil {
                    orphaned += 1
                }
                let got = LayerShellTouchMachine.step(&finger, event: event)
                #expect(got == old.step(event))
                for eff in got {
                    switch eff {
                    case .press: presses += 1
                    case .release: releases += 1
                    case .move, .leave: break
                    }
                }
                if case .down(let id) = finger {
                    #expect(old.id == id)
                } else {
                    #expect(old.id == nil)
                }
                #expect(releases <= presses && presses - releases <= 1 + orphaned)
            }
        }
    }

    private struct OldReadiness {
        var configured: (UInt32, UInt32)?
        var scale: Int32?
        var closed: Bool = false
        var ever: Bool = false

        mutating func step(_ event: LayerShellReadinessEvent) {
            switch event {
            case .configure(let w, let h):
                configured = (w, h)
                ever = true
            case .scale(let s):
                scale = s
            case .closed:
                closed = true
            }
        }
    }

    private struct ReadinessUsed: Equatable {
        var closed: Bool
        var width: UInt32?
        var height: UInt32?
        var scale: Int32?
    }

    private func readinessUsed(_ closed: Bool, _ size: (UInt32, UInt32)?, _ scale: Int32?) -> ReadinessUsed {
        if closed {
            return ReadinessUsed(closed: true, width: nil, height: nil, scale: nil)
        }
        return ReadinessUsed(closed: false, width: size?.0, height: size?.1, scale: scale)
    }

    @Test("LayerShellReadinessMachine: every sequence up to depth 6 reports identical size and scale")
    func everyReadinessSequenceMatches() {
        enum Symbol {
            case event(LayerShellReadinessEvent)
            case read
        }
        let alphabet: [Symbol] = [
            .event(.configure(width: 10, height: 20)),
            .event(.configure(width: 30, height: 40)),
            .event(.scale(2)),
            .event(.scale(3)),
            .event(.closed),
            .read,
        ]
        var seq: [Symbol] = []
        eachSequence(alphabet: alphabet, depth: 6, seq: &seq) { seq in
            var state = LayerShellReadinessState.configuring(scale: nil)
            var old = OldReadiness()
            for sym in seq {
                switch sym {
                case .event(let ev):
                    LayerShellReadinessMachine.step(&state, event: ev)
                    old.step(ev)
                case .read:
                    let got = readinessUsed(state.isClosed, state.takeSize(), state.takeScale())
                    let oldSize = old.configured
                    old.configured = nil
                    let oldScale = old.scale
                    old.scale = nil
                    let was = readinessUsed(old.closed, oldSize, oldScale)
                    #expect(got == was)
                }
                #expect(state.isClosed == old.closed)
                #expect(state.isConfigured == (old.ever || old.closed))
            }
        }
    }

    @Test("LayerShellReadinessMachine: second configure replaces unread size")
    func secondConfigureReplacesUnreadSize() {
        var state = LayerShellReadinessState.configuring(scale: nil)
        LayerShellReadinessMachine.step(&state, event: .scale(2))
        #expect(!state.isConfigured)
        #expect(state.size == nil)
        LayerShellReadinessMachine.step(&state, event: .configure(width: 10, height: 20))
        #expect(state.isConfigured)
        LayerShellReadinessMachine.step(&state, event: .configure(width: 30, height: 40))
        #expect(state.size?.0 == 30 && state.size?.1 == 40)
        let taken = state.takeSize()
        #expect(taken?.0 == 30 && taken?.1 == 40)
        #expect(state.takeSize() == nil)
        #expect(state.isConfigured)
        #expect(state.takeScale() == 2)
        LayerShellReadinessMachine.step(&state, event: .closed)
        #expect(state.isClosed)
        #expect(state.takeSize() == nil)
    }

    // MARK: - 2. portal_appearance_tests.rs

    @Test("PortalAppearance: schemeDark and nested Variant unwrapping")
    func portalAppearanceParsing() {
        #expect(PortalAppearance.schemeDark(1) == true)
        #expect(PortalAppearance.schemeDark(2) == false)
        #expect(PortalAppearance.schemeDark(0) == nil)
        #expect(PortalAppearance.schemeDark(7) == nil)

        #expect(PortalAppearance.parseScheme(.u32(2)) == 2)
        #expect(PortalAppearance.parseScheme(.variant(.u32(1))) == 1)
        #expect(PortalAppearance.parseScheme(.variant(.variant(.u32(2)))) == 2)
        #expect(PortalAppearance.parseScheme(.str("prefer-dark")) == nil)

        #expect(PortalAppearance.parseAccentColor(.variant(.tuple3(0.0, 0.5, 1.0))) != nil)
        #expect(PortalAppearance.parseAccentColor(.tuple3(-0.1, 0.5, 1.0)) == nil)
    }

    // MARK: - 3. ready_signal_tests.rs

    @Test("ReadySignal: writes JSON readiness file once per process and clears on exit")
    func readySignalLifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-ready-test-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("ready", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        ReadySignal.runStarts()
        let state1 = ReadySignal.readyIn(dir, forceResetForTesting: true)
        guard case .at(let path) = state1 else {
            Issue.record("Expected ReadySignal.readyIn to write file")
            return
        }
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1)
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(obj?["pid"] as? UInt32 == ReadySignal.currentPID || (obj?["pid"] as? Int).map(UInt32.init) == ReadySignal.currentPID)
        #expect(obj?["bundle_id"] as? String == ReadySignal.defaultBundleId())
        #expect(obj?["rune"] as? String == ReadySignal.runeVersion)
        #expect(obj?["ready_ms"] != nil)

        let dirItems = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(dirItems.count == 1)

        #if !os(Windows) && !os(WASI)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        let posix = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect((posix & 0o777) == 0o700)
        #endif

        let other = root.appendingPathComponent("other", isDirectory: true)
        _ = ReadySignal.readyIn(other)
        #expect(!FileManager.default.fileExists(atPath: other.path))

        ReadySignal.clear()
        #expect(!FileManager.default.fileExists(atPath: path.path))

        let emptyPayload = ReadySignal.SignalPayload(pid: 7, bundleId: "com.example.app", readyMs: 412)
        #expect(emptyPayload.write(in: nil) == nil)
        #expect(emptyPayload.write(in: URL(string: "file://")!) == nil)
        #expect(emptyPayload.jsonLine() == "{\"pid\":7,\"bundle_id\":\"com.example.app\",\"ready_ms\":412,\"rune\":\"0.1.0\"}")
    }

    // MARK: - 4. web_math_tests.rs

    @Test("WebMath: fixCanvasSize, shouldReconfigureSurface, and wheel delta normalization")
    func webMathParity() {
        // Phone canvas reported in CSS pixels gets its device height
        #expect(WebMath.fixCanvasSize(css: (390, 844), reported: (390, 844), spec: (1200, 900), scale: 2.0, fitHeight: false) == (780, 1688))
        // Canvas at intrinsic 300x150 gets sized to its box
        #expect(WebMath.fixCanvasSize(css: (393, 852), reported: (300, 150), spec: (1200, 900), scale: 3.0, fitHeight: false) == (1179, 2556))
        // fitContentHeight keeps measured height
        #expect(WebMath.fixCanvasSize(css: (600, 640), reported: (600, 640), spec: (1200, 900), scale: 2.0, fitHeight: true).1 == 640)
        #expect(WebMath.fixCanvasSize(css: (600, 640), reported: (300, 150), spec: (1200, 900), scale: 2.0, fitHeight: true).1 == 150)
        // No box falls back to spec
        #expect(WebMath.fixCanvasSize(css: (0, 0), reported: (0, 0), spec: (1200, 900), scale: 2.0, fitHeight: false) == (2400, 1800))
        #expect(WebMath.fixCanvasSize(css: (0, 0), reported: (0, 0), spec: (1200, 900), scale: 1.0, fitHeight: true) == (1200, 900))
        // Size the box agrees with is left alone
        #expect(WebMath.fixCanvasSize(css: (1001, 700), reported: (1502, 1050), spec: (1200, 900), scale: 1.5, fitHeight: false) == (1502, 1050))

        // Page surface never shrinks for mobile toolbar
        let phone: (UInt32, UInt32) = (1179, 2556)
        let r1 = WebMath.shouldReconfigureSurface(current: phone, next: (1179, 2400), document: true)
        #expect(r1.0 == phone && r1.1 == false)
        let r2 = WebMath.shouldReconfigureSurface(current: phone, next: phone, document: true)
        #expect(r2.0 == phone && r2.1 == false)
        let r3 = WebMath.shouldReconfigureSurface(current: phone, next: (2556, 1179), document: true)
        #expect(r3.0 == (2556, 1179) && r3.1 == true)

        // Other windows reconfigure on every size change except 0
        let r4 = WebMath.shouldReconfigureSurface(current: (800, 600), next: (800, 500), document: false)
        #expect(r4.0 == (800, 500) && r4.1 == true)
        let r5 = WebMath.shouldReconfigureSurface(current: (800, 600), next: (0, 0), document: false)
        #expect(r5.0 == (800, 600) && r5.1 == false)

        // Wheel normalization
        #expect(WebMath.normalizeWheelDelta(Vec2(0, 3), mode: .line, lineHeightPx: 20) == Vec2(0, 60))
        #expect(WebMath.normalizeWheelDelta(Vec2(0, 1), mode: .page, pageHeightPx: 800) == Vec2(0, 800))
    }

    // MARK: - 5. Win32, Android, Linux, WebKeyMap, PlatformCommon & PortableText

    @Test("Win32, Linux, Android, and Web key & DPI/motion translators")
    @MainActor
    func platformTranslators() {
        #expect(Win32DpiScale.scaleFactor(forDPI: 96) == 1.0)
        #expect(Win32DpiScale.scaleFactor(forDPI: 192) == 2.0)
        #expect(Win32DpiScale.physicalPixels(logical: 100, dpi: 144) == 150)

        #expect(Win32KeyMap.translate(virtualKey: 0x0D) == .enter)
        #expect(Win32KeyMap.translate(virtualKey: 0x41, shift: false) == .text("a"))
        #expect(Win32KeyMap.translate(virtualKey: 0x41, shift: true) == .text("A"))
        #expect(Win32KeyMap.translate(virtualKey: 0x70) == .f(1))

        #expect(LinuxKeyMap.translate(keysym: 0xFF0D) == .enter)
        #expect(LinuxKeyMap.translate(keysym: 0xFF51) == .arrowLeft)
        #expect(LinuxKeyMap.translate(keysym: 0x0061) == .text("a"))

        #expect(AndroidKeyTranslator.translate(keyCode: 66) == .enter)
        #expect(AndroidKeyTranslator.translate(keyCode: 21) == .arrowLeft)
        #expect(AndroidKeyTranslator.translate(keyCode: 29, unicodeChar: 0x7A) == .text("z"))

        let cfg = AndroidConfigurationState(densityDPI: 320, isNightMode: true)
        #expect(cfg.pixelScale == 2.0)

        #expect(WebKeyMap.translate(code: "Enter", key: "Enter") == .enter)
        #expect(WebKeyMap.translate(code: "KeyK", key: "k") == .text("k"))

        let spec = AppSpec<Int>(
            title: "WebHostTest",
            size: Vec2(320, 240),
            state: 0,
            view: { _, _ in text("Hello") }
        )
        let host = WebAppHost(spec: spec, devicePixelRatio: 2.0)
        #expect(host.surfaceSize == (640, 480))
        host.handlePointerMove(x: 10, y: 10, at: 0.01)
        host.handlePointerDown(x: 10, y: 10, at: 0.02)
        host.handlePointerUp(x: 10, y: 10, at: 0.03)
        let frame = try? host.renderFrame(at: 0.04)
        #expect(frame != nil && frame?.width == 640 && frame?.height == 480)
    }

    @Test("PlatformCommon: InputMethodState, MainQueueDispatcher, FramePacer, and PortableGlyphFont")
    func platformCommonAndPortableText() {
        var ime = InputMethodState()
        ime.setEnabled(true)
        ime.updatePreedit(ImePreedit(text: "nihon", cursorUTF8: 0..<5, clauses: [ImeClause(utf8Range: 0..<5, isTarget: true)]))
        #expect(ime.candidateWindow.isVisible)
        ime.cancelComposition()
        #expect(ime.preedit == nil)
        #expect(!ime.candidateWindow.isVisible)

        var pacer = FramePacer(targetFPS: 60)
        _ = pacer.step(at: 1.0)
        let dt = pacer.step(at: 1.016)
        #expect(abs(dt - 0.016) < 0.001)
        #expect(pacer.frameCount == 2)

        final class Counter: @unchecked Sendable { var n = 0 }
        let c = Counter()
        MainQueueDispatcher.shared.enqueue { c.n += 1 }
        #expect(MainQueueDispatcher.shared.drain() >= 1)
        #expect(c.n == 1)

        // Verify PortableGlyphFont produces non-empty coverage for visible ASCII characters
        let scaled = PortableGlyphFont.rasterizeScaled(scalar: "A", fontSizePx: 24.0, bold: false, italic: false)
        #expect(scaled.width > 0 && scaled.height > 0)
        #expect(scaled.bitmap.contains { $0 > 0 })

        let icon = SVGIcon(viewBox: 24, paths: ["M 2 2 L 22 22"], strokeWidth: 2)
        let iconBuf = PortableSVGRasterizer.rasterize(icon, pixelSize: 24)
        #expect(iconBuf.count == 24 * 24 && iconBuf.contains { $0 > 0 })
    }

    @Test("RuneApp.run executes headlessly with --snap across all platforms")
    @MainActor
    func runeAppHeadlessExecution() throws {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-app-headless-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let spec = AppSpec<Int>(
            title: "CrossPlatformHeadless",
            size: Vec2(160, 120),
            state: 1,
            view: { _, _ in
                col()
                    .p(12)
                    .bg(Color.srgb(0.1, 0.12, 0.18))
                    .child(text("Rune").color(.white))
            }
        )
        try RuneApp.run(spec, arguments: ["test", "--snap", outURL.path, "--cpu"])
        let data = try Data(contentsOf: outURL)
        let decoded = try PortablePNG.decode(data)
        #expect(decoded.width > 0 && decoded.height > 0)
    }
}
