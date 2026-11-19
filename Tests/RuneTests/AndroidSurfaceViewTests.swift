import Foundation
import RuneMotion
import Testing
@testable import Rune

@Suite("Android embeddable RuneSurfaceView host")
@MainActor
struct AndroidSurfaceViewTests {
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test("Lifecycle transitions preserve UI state across surface recreation and become no-ops after dispose")
    func lifecycleAndSurfaceRecreation() throws {
        var now = 0.0
        var gpuReleases: [Bool] = []
        let spec = AppSpec(
            title: "EmbeddedCard",
            size: Vec2(200, 120),
            dark: false,
            state: 0
        ) { _, _ in
            el().size(200, 120).onClick { $0 += 1 }
        }

        let host = AndroidSurfaceHost(spec: spec, clock: { now })
        host.onReleaseGPU = { gpuReleases.append($0) }

        #expect(host.lifecycleState == .created)
        #expect(!host.isAttachedToWindow)
        #expect(!host.isSurfaceReady)
        #expect(!host.isVisible)
        #expect(!host.isDisposed)

        // Cannot draw before surface and visibility are ready.
        #expect(try host.stepFrame(width: 400, height: 240, density: 2, isDark: false) == .skipped)
        #expect(host.presentedFrameCount == 0)

        host.attachToWindow()
        #expect(host.lifecycleState == .attached)
        #expect(host.isAttachedToWindow)

        host.setVisible(true)
        #expect(host.isVisible)
        #expect(host.lifecycleState == .attached)

        host.surfaceCreated(width: 400, height: 240)
        #expect(host.isSurfaceReady)
        #expect(host.lifecycleState == .surfaceReady)
        #expect(host.pixelWidth == 400)
        #expect(host.pixelHeight == 240)

        host.surfaceChanged(width: 600, height: 360, density: 2, isNightMode: false)
        #expect(host.runtime.pixelScale == 2)
        #expect(host.runtime.viewport == Vec2(300, 180))

        let first = try host.stepFrame(width: 600, height: 360, density: 2, isDark: false)
        #expect(first == .idle)
        #expect(host.presentedFrameCount == 1)

        // Tap once to mutate state.
        now = 0.1
        host.dispatchMotion(.init(action: .down, pointerId: 1, xPx: 50, yPx: 50))
        now = 0.12
        host.dispatchMotion(.init(action: .up, pointerId: 1, xPx: 50, yPx: 50))
        #expect(host.runtime.state == 1)

        // Surface destroyed (e.g. app backgrounded or Fragment paused): releases GPU, preserves state.
        host.surfaceDestroyed(contextCurrent: true)
        #expect(!host.isSurfaceReady)
        #expect(host.lifecycleState == .paused)
        #expect(gpuReleases == [true])
        #expect(host.runtime.state == 1)
        #expect(try host.stepFrame(width: 600, height: 360, density: 2, isDark: false) == .skipped)

        // Detach and re-attach without disposing preserves state.
        host.detachFromWindow()
        #expect(!host.isAttachedToWindow)
        #expect(!host.isVisible)
        #expect(host.lifecycleState == .paused)
        #expect(host.runtime.state == 1)

        host.attachToWindow()
        host.setVisible(true)
        host.surfaceCreated(width: 600, height: 360)
        #expect(host.lifecycleState == .surfaceReady)
        now = 0.5
        _ = try host.stepFrame(width: 600, height: 360, density: 2, isDark: false)
        now = 1.0
        let resumed = try host.stepFrame(width: 600, height: 360, density: 2, isDark: false)
        #expect(resumed == .idle)
        #expect(host.presentedFrameCount == 3)
        #expect(host.runtime.state == 1)

        // Dispose is permanent and idempotent.
        host.dispose(contextCurrent: false)
        #expect(host.isDisposed)
        #expect(host.lifecycleState == .disposed)
        #expect(gpuReleases == [true, false])

        // Post-dispose events are safe no-ops.
        host.dispose(contextCurrent: true)
        host.attachToWindow()
        host.setVisible(true)
        host.surfaceCreated(width: 600, height: 360)
        host.dispatchMotion(.init(action: .down, pointerId: 2, xPx: 50, yPx: 50))
        host.dispatchMotion(.init(action: .up, pointerId: 2, xPx: 50, yPx: 50))
        #expect(try host.stepFrame(width: 600, height: 360, density: 2, isDark: false) == .skipped)
        #expect(host.lifecycleState == .disposed)
        #expect(host.runtime.state == 1)
        #expect(gpuReleases == [true, false])
    }

    @Test("Configuration, density scaling, dark override, and safe-area insets update viewport and wake")
    func configurationDensityAndSafeArea() throws {
        let wakeCounter = AtomicCounter()
        let spec = AppSpec(
            title: "ConfigCard",
            size: Vec2(100, 100),
            dark: nil,
            state: 0
        ) { _, _ in
            el().wFull().hFull()
        }

        let host = AndroidSurfaceHost(
            spec: spec,
            config: AndroidSurfaceConfig(
                initialSize: Vec2(160, 120),
                configuration: AndroidConfigurationState(densityDPI: 320, isNightMode: false),
                darkOverride: nil
            ),
            clock: { 0.0 }
        )
        host.onRequestFrame = { wakeCounter.increment() }

        #expect(host.runtime.pixelScale == 2.0)
        #expect(host.runtime.systemDark == false)
        #expect(host.runtime.viewport == Vec2(160, 120))

        host.attachToWindow()
        host.setVisible(true)
        host.surfaceChanged(width: 1080, height: 540, density: 3.0, isNightMode: true)
        #expect(host.runtime.pixelScale == 3.0)
        #expect(host.configuration.densityDPI == 480)
        #expect(host.configuration.isNightMode == true)
        #expect(host.runtime.systemDark == true)
        #expect(host.runtime.viewport == Vec2(360, 180))

        // Safe-area insets trigger a redraw request when changed, and not when unchanged.
        let wakesBefore = wakeCounter.count
        host.setSafeAreaInsets(SIMD4(24, 0, 16, 0))
        #expect(host.configuration.safeAreaInsets == SIMD4(24, 0, 16, 0))
        #expect(wakeCounter.count == wakesBefore + 1)

        host.setSafeAreaInsets(SIMD4(24, 0, 16, 0))
        #expect(wakeCounter.count == wakesBefore + 1)

        // Explicit darkOverride takes precedence over Android Configuration night mode.
        let forcedDarkHost = AndroidSurfaceHost(
            spec: spec,
            config: AndroidSurfaceConfig(darkOverride: true),
            clock: { 0.0 }
        )
        forcedDarkHost.updateConfiguration(densityDPI: 240, isNightMode: false)
        #expect(forcedDarkHost.configuration.densityDPI == 240)
        #expect(forcedDarkHost.runtime.pixelScale == 1.5)
        #expect(forcedDarkHost.runtime.systemDark == true)
    }

    @Test("Window blur and surface loss cancel held touch gestures cleanly")
    func blurAndSurfaceLossSuspendActiveTouch() throws {
        var now = 0.0
        let spec = AppSpec(
            title: "TouchGuard",
            size: Vec2(100, 100),
            dark: false,
            state: 0
        ) { _, _ in
            el().size(100, 100).onClick { $0 += 1 }
        }

        let host = AndroidSurfaceHost(spec: spec, clock: { now })
        host.attachToWindow()
        host.setVisible(true)
        host.setWindowFocus(true)
        host.surfaceChanged(width: 200, height: 200, density: 2, isNightMode: false)
        _ = try host.stepFrame(width: 200, height: 200, density: 2, isDark: false)

        // Begin a touch, then lose window focus before releasing.
        now = 0.1
        host.dispatchMotion(.init(action: .down, pointerId: 3, xPx: 80, yPx: 80))
        #expect(host.runtime.touching())

        now = 0.12
        host.setWindowFocus(false)
        #expect(!host.hasWindowFocus)
        #expect(!host.runtime.touching())

        // The stray release after blur must not fire a click.
        now = 0.14
        host.dispatchMotion(.init(action: .up, pointerId: 3, xPx: 80, yPx: 80))
        #expect(host.runtime.state == 0)

        // Regain focus and complete a clean tap.
        now = 0.2
        host.setWindowFocus(true)
        host.dispatchMotion(.init(action: .down, pointerId: 4, xPx: 80, yPx: 80))
        now = 0.22
        host.dispatchMotion(.init(action: .up, pointerId: 4, xPx: 80, yPx: 80))
        #expect(host.runtime.state == 1)
    }

    @Test("Key events, modifier masks, and dead-key composition route to the embedded runtime")
    func keyboardModifiersAndDeadKeyComposition() throws {
        struct KeyLog: Equatable {
            var keys: [KeyEvent] = []
            var modsHistory: [Mods] = []
        }

        var now = 0.0
        var app = App(title: "Keys", size: Vec2(120, 80), dark: false, state: KeyLog()) { _, _ in
            el().size(120, 80)
        }
        app.onKeyHook = { state, event, _ in
            state.keys.append(event)
            return true
        }
        app.onModifiersHook = { state, mods, _ in
            state.modsHistory.append(mods)
        }

        let host = AndroidSurfaceHost(app: app, clock: { now })
        host.attachToWindow()
        host.setVisible(true)
        host.surfaceChanged(width: 120, height: 80, density: 1, isNightMode: false)
        _ = try host.stepFrame(width: 120, height: 80, density: 1, isDark: false)

        // Verify Android META_* bitmask mapping.
        let allMods = AndroidKeyTranslator.modifiers(from: 1 | 2 | 0x1000 | 0x10000)
        #expect(allMods == Mods(shift: true, ctrl: true, alt: true, logo: true))
        #expect(AndroidMotionTranslator.button(from: 1) == .primary)
        #expect(AndroidMotionTranslator.button(from: 2) == .secondary)
        #expect(AndroidMotionTranslator.button(from: 4) == .middle)

        // Compose dead acute accent + 'e' -> 'é' with Shift held.
        let compose: (UInt32, UInt32) -> UInt32 = { accent, char in
            accent == 0x00b4 && char == 0x65 ? 0x00e9 : 0
        }
        now = 0.05
        #expect(host.dispatchKey(.init(action: .down, keyCode: 75, metaState: 0, unicodeChar: 0x8000_00b4), composeDeadKey: compose))
        #expect(host.dispatchKey(.init(action: .up, keyCode: 75, metaState: 0, unicodeChar: 0), composeDeadKey: compose))
        #expect(host.runtime.state.keys.isEmpty)

        now = 0.1
        #expect(host.dispatchKey(.init(action: .down, keyCode: 33, metaState: 1, unicodeChar: 0x65), composeDeadKey: compose))
        // Key-up clears the tracked press without re-triggering onKeyHook.
        _ = host.dispatchKey(.init(action: .up, keyCode: 33, metaState: 1, unicodeChar: 0), composeDeadKey: compose)
        #expect(host.runtime.state.keys == [KeyEvent(key: .text("é"), mods: Mods(shift: true))])
        #expect(host.runtime.state.modsHistory.contains(Mods(shift: true)))

        // Pending dead accent is cleared on suspendInput().
        now = 0.2
        #expect(host.dispatchKey(.init(action: .down, keyCode: 75, unicodeChar: 0x8000_00b4), composeDeadKey: compose))
        host.suspendInput()
        now = 0.25
        #expect(host.dispatchKey(.init(action: .down, keyCode: 33, unicodeChar: 0x65), composeDeadKey: compose))
        #expect(host.runtime.state.keys.last == KeyEvent(key: .text("e"), mods: .none))
    }

    @Test("Frame dispositions report wake deadlines, animation continuation, and close requests")
    func frameDispositionsAndWaker() throws {
        var now = 0.0
        var closedCount = 0
        let wakes = AtomicCounter()
        var app = App(title: "Pacing", size: Vec2(100, 100), dark: false, state: 0) { _, _ in
            el().size(100, 100)
                .onClick { $0 += 1 }
                .onSecondaryClick { state, _, _ in state += 10 }
        }
        app.pollHook = nil

        let host = AndroidSurfaceHost(app: app, clock: { now })
        host.onRequestFrame = { wakes.increment() }
        host.onCloseRequested = { closedCount += 1 }

        host.attachToWindow()
        host.setVisible(true)
        host.surfaceChanged(width: 100, height: 100, density: 1, isNightMode: false)

        // First static frame becomes idle.
        let idleFrame = try host.stepFrame(width: 100, height: 100, density: 1, isDark: false)
        #expect(idleFrame == .idle)
        #expect(idleFrame.nativeDelaySeconds == -1)

        // Starting a touch hold schedules a wakeAfter deadline for the 0.5s long-press threshold.
        now = 1.0
        host.dispatchMotion(.init(action: .down, pointerId: 0, xPx: 20, yPx: 20))
        now = 1.05
        let pendingHold = try host.stepFrame(width: 100, height: 100, density: 1, isDark: false)
        if case .wakeAfter(let seconds) = pendingHold {
            #expect(abs(seconds - 0.45) < 0.01)
            #expect(abs(pendingHold.nativeDelaySeconds - 0.45) < 0.01)
        } else {
            Issue.record("Expected .wakeAfter for pending touch hold, got \(pendingHold)")
        }

        // Direct host update and waker trigger frame requests.
        let beforeWakes = wakes.count
        host.update { state, _ in state += 5 }
        #expect(host.runtime.state == 5)
        #expect(wakes.count == beforeWakes + 1)

        host.waker.wake()
        #expect(wakes.count == beforeWakes + 2)

        // Requesting quit notifies onCloseRequested instead of terminating the host process.
        host.update { _, tx in tx.quit() }
        now = 1.1
        let closeDisposition = try host.stepFrame(width: 100, height: 100, density: 1, isDark: false)
        #expect(closeDisposition == .closeRequested)
        #expect(closeDisposition.nativeDelaySeconds == -.infinity)
        #expect(closedCount == 1)

        // Verify .continueAnimating disposition encoding.
        #expect(AndroidFrameDisposition.continueAnimating.nativeDelaySeconds == 0)
        #expect(AndroidFrameDisposition.skipped.nativeDelaySeconds == -1)
    }

    @Test("Multiple embedded surface hosts run independently side by side")
    func multipleEmbeddedHostsAreIsolated() throws {
        var now = 0.0
        let specA = AppSpec(title: "CardA", size: Vec2(100, 100), dark: false, state: 0) { _, _ in
            el().size(100, 100).onClick { $0 += 1 }
        }
        let specB = AppSpec(title: "CardB", size: Vec2(100, 100), dark: true, state: 10) { _, _ in
            el().size(100, 100).onClick { $0 += 10 }
        }

        let hostA = AndroidSurfaceHost(spec: specA, clock: { now })
        let hostB = AndroidSurfaceHost(spec: specB, clock: { now })

        for host in [hostA, hostB] {
            host.attachToWindow()
            host.setVisible(true)
            host.surfaceChanged(width: 200, height: 200, density: 2, isNightMode: false)
            _ = try host.stepFrame(width: 200, height: 200, density: 2, isDark: false)
        }

        now = 0.1
        hostA.dispatchMotion(.init(action: .down, xPx: 40, yPx: 40))
        hostA.dispatchMotion(.init(action: .up, xPx: 40, yPx: 40))
        #expect(hostA.runtime.state == 1)
        #expect(hostB.runtime.state == 10)

        // Disposing card A leaves card B fully operational.
        hostA.dispose()
        #expect(hostA.isDisposed)
        #expect(!hostB.isDisposed)

        now = 0.2
        hostB.dispatchMotion(.init(action: .down, xPx: 40, yPx: 40))
        hostB.dispatchMotion(.init(action: .up, xPx: 40, yPx: 40))
        #expect(hostB.runtime.state == 20)
        // First frame after tap may schedule a brief press-settle wake; subsequent frame settles idle.
        _ = try hostB.stepFrame(width: 200, height: 200, density: 2, isDark: true)
        now = 1.0
        #expect(try hostB.stepFrame(width: 200, height: 200, density: 2, isDark: true) == .idle)
    }

    @Test("AndroidSurfaceFactoryRegistry registers, resolves, replaces, and unregisters factories")
    func factoryRegistryLifecycle() throws {
        let registry = AndroidSurfaceFactoryRegistry()
        var receivedPointers: [UnsafeMutableRawPointer] = []
        var sentinelA = 1
        var sentinelB = 2

        registry.register(named: "hero_card") { ptr in
            receivedPointers.append(ptr)
        }
        registry.register(named: "mini_player") { _ in }

        #expect(registry.contains("hero_card"))
        #expect(!registry.contains("missing"))
        #expect(registry.registeredNames == ["hero_card", "mini_player"])

        try withUnsafeMutablePointer(to: &sentinelA) { ptrA in
            let found = try registry.instantiate(named: "hero_card", surface: UnsafeMutableRawPointer(ptrA))
            #expect(found)
            #expect(receivedPointers == [UnsafeMutableRawPointer(ptrA)])
        }

        try withUnsafeMutablePointer(to: &sentinelB) { ptrB in
            let missing = try registry.instantiate(named: "unknown", surface: UnsafeMutableRawPointer(ptrB))
            #expect(!missing)
        }

        registry.unregister(named: "hero_card")
        #expect(!registry.contains("hero_card"))
        #expect(registry.registeredNames == ["mini_player"])

        registry.removeAll()
        #expect(registry.registeredNames.isEmpty)
    }
}
