import Foundation
import Testing
@testable import Rune
@testable import RuneMotion
@testable import RuneRef

@Suite("Cx Environment, System Settings & Shell Integration Parity Tests", .serialized)
struct CxEnvAndSystemParityTests {
    private static let highContrastPalette = SystemContrast(
        window: .black,
        text: .white,
        highlight: .srgb(1.0, 1.0, 0.0),
        highlightText: .black,
        disabled: .srgb(0.5, 0.5, 0.5),
        button: .srgb(0.2, 0.2, 0.2),
        buttonText: .white,
        link: .srgb(0.3, 0.8, 1.0)
    )

    @Test func cxEnvGettersSettersAndDefaults() {
        struct S {
            var useWebFocus = false
            var forceRings = false
            var timeScale: Float = 1.0
            var zoom: Float = 1.0
            var reduced: Bool? = nil
            var titlebarH: Float? = nil
            var ticks = 0
        }

        final class Captured: @unchecked Sendable {
            var gen0: UInt64 = 0
            var dark = false
            var inset: Float = 0
            var accent: Color = .transparent
            var focus: Color = .transparent
            var safe: [Float] = []
            var contrast: SystemContrast? = nil
            var sysReduced = false
            var isReduced = false
            var bars: ScrollBars = .whenScrolling
            var overlay = false
            var env = Env()
            var scaleFromRetype: Float = 0
            var zoomFromAbsorb: Float = 0
        }
        let cap = Captured()
        let beforeGen = commitGeneration()

        let rt = Runtime(
            state: S(),
            viewport: Vec2(800, 600),
            pixelScale: 2.0,
            systemDark: true
        ) { s, cx in
            cap.gen0 = commitGeneration()
            cap.dark = cx.getSystemDark()
            cap.inset = cx.titlebarInset()
            cap.accent = cx.accent()
            cap.focus = cx.focusColor()
            cap.safe = cx.safeArea()
            cap.contrast = cx.systemContrast()
            cap.sysReduced = cx.systemReducedMotion()
            cap.isReduced = cx.isReducedMotion()
            cap.bars = cx.scrollBars()
            cap.overlay = cx.overlayScrollBars()
            cap.env = cx.env()

            // Retype + absorb preserves runtime zoom mutations while matching state retyping
            var subCx: Cx<Int> = cx.retype()
            cap.scaleFromRetype = subCx.env().scale
            subCx.zoom(s.zoom)
            cx.absorb(subCx)
            cap.zoomFromAbsorb = cx.envState.zoom

            cx.foreground(.srgb(0.9, 0.8, 0.7))
            cx.captionColor(.srgb(0.4, 0.5, 0.6))
            cx.focusRing(width: 2.5, offset: 1.5, color: .srgb(0.1, 0.6, 1.0))
            cx.helpLook(
                HelpLook.system(dark: true)
                    .fill(.srgb(0.1, 0.1, 0.2))
                    .ink(.white)
                    .ring(1.0, .srgb(0.5, 0.5, 0.6))
                    .radius(8)
                    .padding(10, 6)
                    .maxWidth(240)
                    .gap(8)
                    .margin(6)
                    .delay(0.4)
                    .skipDelay(0.2)
                    .fade(enter: 0.12, exit: 0.08, scale: 0.96)
                    .rowGap(5)
                    .keycapShape(height: 18, padX: 5, radius: 4, gap: 3, lead: 7)
            )
            if s.useWebFocus { cx.webFocus() }
            if s.forceRings { cx.forceFocusRings() }
            if let th = s.titlebarH { cx.titlebarHeight(th) }
            if let rm = s.reduced { cx.reducedMotion(rm) }
            cx.timeScale(s.timeScale)

            return col().children([
                text("hello").key("t"),
                el().key("btn").focusable().size(100, 30)
            ])
        }

        let customAccent = SystemAccent(
            lightAccent: .srgb(0.2, 0.4, 0.9),
            darkAccent: .srgb(0.2, 0.4, 0.9)
        )
        rt.setTitlebarInset(32)
        rt.setSystemAccent(customAccent)
        rt.setSystemContrast(Self.highContrastPalette)
        rt.setSystemReducedMotion(true)
        rt.setSystemScrollBars(.always)
        rt.setSystemScrollerOverlay(false)
        _ = rt.frame(at: 0.0)

        #expect(cap.gen0 > beforeGen)
        #expect(cap.dark)
        #expect(cap.inset == 32)
        #expect(cap.accent == .srgb(0.2, 0.4, 0.9))
        #expect(cap.focus == customAccent.focus(dark: true))
        #expect(cap.safe == [0, 0, 0, 0])
        #expect(cap.contrast == Self.highContrastPalette)
        #expect(cap.sysReduced)
        #expect(cap.isReduced)
        #expect(cap.bars == .always)
        #expect(cap.overlay == false)
        #expect(cap.env == Env(systemDark: true, scale: 2.0))
        #expect(cap.scaleFromRetype == 2.0)
        #expect(cap.zoomFromAbsorb == 1.0)

        #expect(rt.viewDefaults.foreground == .srgb(0.9, 0.8, 0.7))
        #expect(rt.viewDefaults.focusRing == Outline(width: 2.5, offset: 1.5, color: .srgb(0.1, 0.6, 1.0)))
        #expect(rt.viewDefaults.help?.maxW == 240)
        #expect(rt.viewDefaults.help?.rowGap == 5)
        #expect(rt.viewDefaults.help?.key.height == 18)
        #expect(rt.viewCaptionColor == .srgb(0.4, 0.5, 0.6))
        // Default text element inherits viewDefaults.foreground when textColor wasn't explicitly set
        #expect(rt.element(byKey: "t")?.textColor == .srgb(0.9, 0.8, 0.7))

        // Focus ring emission on forceFocusRings
        rt.update { st, tx in
            tx.focus("btn")
            st.forceRings = true
            st.useWebFocus = true
            st.titlebarH = 44
            st.reduced = false
            st.zoom = 2.0
        }
        let scene = rt.frame(at: 0.02)
        #expect(rt.viewDefaults.webFocus)
        #expect(rt.viewDefaults.forceFocusRings)
        #expect(rt.effectiveTitlebar()?.height == 44)
        #expect(rt.chromeInsets().height == 22)
        #expect(!rt.reducedMotion)
        #expect(rt.zoom() == 2.0)
        #expect(rt.viewport == Vec2(400, 300))
        #expect(rt.pixelScale == 4.0)
        #expect(rt.windowViewport() == Vec2(800, 600))
        #expect(rt.windowScale() == 2.0)
        #expect(rt.toWindow([10, 20, 30, 40]) == [20, 40, 60, 80])
        #expect(rt.element(byKey: "btn")?.focusVisible == true)
        #expect(!scene.primitives.isEmpty)
    }

    @Test func cxTimeScaleAndClockFreezing() {
        struct S { var scale: Float = 0.5 }
        let rt = Runtime(state: S(), viewport: Vec2(200, 100), pixelScale: 1.0) { s, cx in
            cx.timeScale(s.scale)
            return text("hi")
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.cxSettings.advanceClock(to: 1.0) == 0.5)
        rt.update { s, _ in s.scale = 0.0 }
        _ = rt.frame(at: 1.0)
        let frozenAt1 = rt.cxSettings.advanceClock(to: 3.0)
        let frozenAt5 = rt.cxSettings.advanceClock(to: 5.0)
        #expect(abs(frozenAt1 - frozenAt5) < 1e-6)
    }

    @Test func zoomStateAndChromeInsetsClampAndMath() {
        #expect(ZoomState.clamp(0.01) == 0.1)
        #expect(ZoomState.clamp(100.0) == 10.0)
        #expect(ZoomState.clamp(.nan) == 1.0)

        let zs = ZoomState(k: 2.0, window: Vec2(801, 601), windowScale: 1.5)
        let (vp, sc) = zs.view()
        #expect(vp == Vec2(400.5, 300.5))
        #expect(sc == 3.0)

        let ci = ChromeInsets(leading: 10, trailing: 20, top: 32)
        #expect(ci.height == 32)
        #expect(ci.zoomed(2.0) == ChromeInsets(leading: 5, trailing: 10, top: 16))
        #expect(ci.bits().count == 3)
    }

    @Test func scrollBarsOverlayRules() {
        #if os(iOS)
        #expect(ScrollBars.always.isOverlay(scrollerOverlay: false))
        #else
        #expect(ScrollBars.automatic.isOverlay(scrollerOverlay: true))
        #expect(!ScrollBars.automatic.isOverlay(scrollerOverlay: false))
        #expect(ScrollBars.whenScrolling.isOverlay(scrollerOverlay: false))
        #expect(!ScrollBars.always.isOverlay(scrollerOverlay: true))
        #endif
    }

    @Test func machineAttemptTokenAndSeqParity() {
        let a: Attempt<Int, String> = .ready(21)
        #expect(a.map { $0 * 2 } == .ready(42))
        let f: Attempt<Int, Int> = .failed(7)
        #expect(f.mapError { "e:\($0)" } == .failed("e:7"))

        var seq = Seq()
        let t1 = seq.nextAttempt()
        #expect(seq.isCurrent(t1))
        #expect(seq.currentAttempt == t1)
        let t2 = seq.nextAttempt()
        #expect(!seq.isCurrent(t1))
        #expect(seq.isCurrent(t2))
        #expect(t1 < t2)
        seq.cancel()
        #expect(!seq.isCurrent(t2))
    }

    @Test func localTimeCalendarMathAndHeadlessJumpList() {
        // 2024-02-29 13:14:15 UTC (leap day) -> 1709212455000 ms
        let leap = LocalTime.atOffset(epochMs: 1_709_212_455_000, offset: 0)
        #expect(leap.year == 2024)
        #expect(leap.month == 2)
        #expect(leap.day == 29)
        #expect(leap.hour == 13)
        #expect(leap.minute == 14)
        #expect(leap.second == 15)
        #expect(leap.offset == 0)

        // Offset +3600s shifts to 14:14:15
        let plus1h = LocalTime.atOffset(epochMs: 1_709_212_455_000, offset: 3600)
        #expect(plus1h.hour == 14)
        #expect(plus1h.offset == 3600)

        // Negative epoch (-1000 ms -> 1969-12-31 23:59:59 UTC)
        let preEpoch = LocalTime.atOffset(epochMs: -1000, offset: 0)
        #expect(preEpoch.year == 1969)
        #expect(preEpoch.month == 12)
        #expect(preEpoch.day == 31)
        #expect(preEpoch.hour == 23)
        #expect(preEpoch.minute == 59)
        #expect(preEpoch.second == 59)

        let local = LocalTime.at(epochMs: 1_709_212_455_000)
        #expect(local.year >= 2024)

        let jl = JumpList()
            .task(JumpItem(title: "Open", argument: "open"))
            .category("Recent", items: [JumpItem(title: "Doc", argument: "doc")])
        #expect(jl.tasks.count == 1)
        #expect(jl.categories.count == 1)
        let store = JumpListStore()
        #expect(!store.submit(jl, headless: true) { _ in })
        #expect(store.current == nil)
    }

    @Test func appDirsSanitizeEnvOverrideAndRootCheck() {
        #expect(AppDirs.sanitize("") == "app")
        #expect(AppDirs.sanitize("..") == "app")
        #expect(AppDirs.sanitize("...") == "app")
        #expect(AppDirs.sanitize("  My:App/Name?..  ") == "My_App_Name_")

        let rootedEnv: [String: String] = ["RUNE_DIRS_ROOT": "/tmp/rune-dirs-test"]
        let dirs = AppDirs.fromEnv(appId: "TestApp") { rootedEnv[$0] }
        #expect(dirs?.isRooted == true)
        #expect(dirs?.config.path.hasPrefix("/tmp/rune-dirs-test") == true)
        #expect(dirs?.config.lastPathComponent == "TestApp")

        #expect(AppDirs.fromEnv(appId: "TestApp") { _ in nil } == nil)
    }

    @Test func urlOpenerValidationParity() throws {
        #expect(try UrlOpener.validate("https://example.com/path?a=1") == "https://example.com/path?a=1")
        #expect(try UrlOpener.validate("https://user:pass@example.com") == "https://user:pass@example.com")
        #expect(try UrlOpener.validate("mailto:user@example.com") == "mailto:user@example.com")
        #expect(try UrlOpener.validate("http://[::1]:8080/test") == "http://[::1]:8080/test")

        #expect(throws: OpenUrlError.invalid) { _ = try UrlOpener.validate("https://example.com/bad%ZZ") }
        #expect(throws: OpenUrlError.invalid) { _ = try UrlOpener.validate("https://example.com/null%00") }
        #expect(throws: OpenUrlError.invalid) { _ = try UrlOpener.validate("https://@example.com") }
        #expect(throws: OpenUrlError.invalid) { _ = try UrlOpener.validate("https://example.com:99999") }
        #expect(throws: OpenUrlError.unsupportedScheme("javascript")) { _ = try UrlOpener.validate("javascript:alert(1)") }

        #expect(try UrlOpener.validateSameTab("/docs/guide#intro", allowRelative: true) == "/docs/guide#intro")
        #expect(try UrlOpener.validateSameTab("https://example.com", allowRelative: true) == "https://example.com")
        #expect(throws: OpenUrlError.invalid) { _ = try UrlOpener.validateSameTab("/docs/guide#intro", allowRelative: false) }
    }

    @Test func runeTaskServeAndSleep() async {
        let countBox = LockedCounter()
        let stream = AsyncStream<Int> { cont in
            cont.yield(1)
            cont.yield(2)
            cont.yield(3)
            cont.finish()
        }
        let task = RuneTask.serve(name: "test-serve", stream: stream) { v in
            countBox.add(v)
            return v < 2
        }
        await task.value
        await RuneTask.sleep(seconds: 0.01)
        #expect(countBox.value == 3)
    }

    @Test func cxChromeInsetsAndTitlebarZoomAndReset() {
        struct S {
            var zoomed = true
        }
        let seenBox = LockedRectPair()
        let rt = Runtime(state: S(), viewport: Vec2(800, 600), pixelScale: 2.0) { s, cx in
            if s.zoomed { cx.zoom(2.0) }
            seenBox.record(chrome: cx.chromeInsets(), titlebar: cx.titlebarInset())
            return text("\(seenBox.chrome.top),\(seenBox.titlebar)").key("out")
        }
        rt.setTitlebarInset(76.0)
        rt.setBaseTitlebar(Titlebar(height: 38.0))
        _ = rt.frame(at: 0.01)
        #expect(rt.zoom() == 2.0)
        #expect(rt.chromeInsets() == ChromeInsets(leading: 38.0, trailing: 0.0, top: 19.0))
        #expect(rt.element(byKey: "out") != nil)
        #expect(abs(seenBox.chrome.leading - 38.0) < 1e-4)
        #expect(abs(seenBox.chrome.top - 19.0) < 1e-4)
        #expect(abs(seenBox.titlebar - 38.0) < 1e-4)

        // Stopping `cx.zoom` resets zoom factor back to `1.0` cleanly on the next commit
        rt.update { s, _ in s.zoomed = false }
        _ = rt.frame(at: 0.02)
        #expect(rt.zoom() == 1.0)
        #expect(rt.viewport == Vec2(800, 600))
        #expect(rt.pixelScale == 2.0)
        #expect(abs(seenBox.chrome.leading - 76.0) < 1e-4)
        #expect(abs(seenBox.chrome.top - 38.0) < 1e-4)
        #expect(abs(seenBox.titlebar - 76.0) < 1e-4)
    }

    @Test func frozenTimeScaleStopsIsAnimatingAndScrollClockAndSyncsReducedMotion() {
        struct S {
            var frozen = false
        }
        let rt = Runtime(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0) { s, cx in
            if s.frozen { cx.timeScale(0.0) }
            return col().key("scroller").size(200, 100).scrollY()
                .child(el().size(200, 1000))
        }
        _ = rt.frame(at: 0.0)
        rt.fling(vy: -800, at: Vec2(50, 50), now: 0.0)
        _ = rt.frame(at: 0.05)
        #expect(rt.isAnimating)

        rt.update { s, _ in s.frozen = true }
        _ = rt.frame(at: 0.1)
        #expect(!rt.isAnimating)
        let scrollAtFreeze = rt.element(byKey: "scroller")?.scrolled
        _ = rt.frame(at: 0.5)
        #expect(!rt.isAnimating)
        #expect(rt.element(byKey: "scroller")?.scrolled == scrollAtFreeze)

        // Reduced motion propagates cleanly to scene + liveStore (`scale` cuts instantly)
        let liveScale = Live(Float(1.0))
        let rtLive = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            El<Int>().key("live-box").size(40, 40).bg(.white).liveScale(liveScale.smooth(MotionTokens.SNAPPY))
        }
        _ = rtLive.frame(at: 0.0)
        rtLive.setSystemReducedMotion(true)
        liveScale.set(2.0)
        _ = rtLive.frame(at: 0.01)
        let snapScale = rtLive.element(byKey: "live-box")?.scale ?? -1
        #expect(abs(snapScale - 2.0) < 1e-3)
        #expect(!rtLive.isAnimating)
    }

    @Test func webFocusAndKeyboardAccessFocusRouting() {
        struct S {
            var useWebFocus = false
            var edit = TextEdit("")
            var tapped = 0
        }
        let rt = Runtime(state: S(), viewport: Vec2(400, 300), pixelScale: 1.0) { s, cx in
            if s.useWebFocus { cx.webFocus() }
            return col().sizeFull().gap(8)
                .child(el().key("btn").size(80, 30).onClick { st, _ in st.tapped += 1 })
                .child(el().key("pd-btn").size(80, 30).role(.button).onPointerDown { st, _, _ in st.tapped += 10 })
                .child(el().key("opt-out").size(80, 30).role(.button).onPointerDown { _, _, _ in }.focusable(false))
                .child(textInput(key: "field", \.edit).size(160, 30))
        }
        _ = rt.frame(at: 0.0)

        // With Full Keyboard Access disabled, Tab visits text inputs, skipping buttons
        rt.setFullKeyboardAccess(false)
        rt.setTabVisitsControls(false)
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.1))
        #expect(rt.focusedKey == "field")
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.2))
        #expect(rt.focusedKey == "field")

        // App override `setTabVisitsControls(true)` restores button Tab stops
        rt.setTabVisitsControls(true)
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.3))
        #expect(rt.focusedKey == "btn")

        // Enabling `cx.webFocus()` lets pressable-role controls without `.focusable()` take focus while `.focusable(false)` opts out
        rt.update { s, _ in s.useWebFocus = true }
        _ = rt.frame(at: 0.4)
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.5))
        #expect(rt.focusedKey == "pd-btn")
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.6))
        #expect(rt.focusedKey == "field")
    }

    @Test func appDirsSiblingPreservesRootedAndLogHierarchy() {
        let rooted = AppDirs.rooted(at: URL(fileURLWithPath: "/tmp/rune-root", isDirectory: true), appId: "FirstApp")
        let sib = rooted.sibling("SecondApp")
        #expect(sib.isRooted)
        #expect(sib.config.path == "/tmp/rune-root/config/SecondApp")
        #expect(sib.state.path == "/tmp/rune-root/state/SecondApp")
        #expect(sib.logs.path == "/tmp/rune-root/logs/SecondApp")
    }

    @Test func sceneClockDefaultsToZeroAndScopesInitSceneAndSetup() throws {
        #expect(sceneClock() == SceneClock(now: 0.0, dt: 0.0))

        struct State: @unchecked Sendable {
            var initClock = SceneClock(now: -1, dt: -1)
            var sceneClockVal = SceneClock(now: -1, dt: -1)
        }
        final class ClockBox: @unchecked Sendable {
            private let lock = NSLock()
            var initClock = SceneClock(now: -1, dt: -1)
            var sceneClockVal = SceneClock(now: -1, dt: -1)
            var setupClock = SceneClock(now: -1, dt: -1)
            func recordInit(_ c: SceneClock) { lock.lock(); initClock = c; lock.unlock() }
            func recordScene(_ c: SceneClock) { lock.lock(); sceneClockVal = c; lock.unlock() }
            func setSetup(_ c: SceneClock) { lock.lock(); setupClock = c; lock.unlock() }
            var snapshot: (SceneClock, SceneClock, SceneClock) {
                lock.lock(); defer { lock.unlock() }; return (initClock, sceneClockVal, setupClock)
            }
        }
        let box = ClockBox()

        let app = App<State> {
            let c = sceneClock()
            box.recordInit(c)
            return State(initClock: c, sceneClockVal: SceneClock(now: -1, dt: -1))
        } view: { _, _ in
            text("hi")
        }
        .scene("zero") { state, _ in
            let c = sceneClock()
            state.sceneClockVal = c
            box.recordScene(c)
        }
        .setup { _ in
            box.setSetup(sceneClock())
        }

        let spec = app.intoSpec()
        var args = ToolingArgs()
        args.sceneName = "zero"
        _ = try HeadlessRunner.run(spec, args: args)
        let (initC, sceneC, setupC) = box.snapshot
        #expect(initC == SceneClock(now: 0.0, dt: 0.0))
        #expect(sceneC == SceneClock(now: 0.0, dt: 0.0))
        #expect(setupC == SceneClock(now: 0.0, dt: 0.0))

        let scoped = withSceneClock(SceneClock(now: 2.5, dt: 0.016)) {
            sceneClock()
        }
        #expect(scoped == SceneClock(now: 2.5, dt: 0.016))
        #expect(sceneClock() == SceneClock(now: 0.0, dt: 0.0))

        struct TestBoom: Error {}
        do {
            _ = try withSceneClock(SceneClock(now: 9.0, dt: 0.25)) {
                #expect(sceneClock() == SceneClock(now: 9.0, dt: 0.25))
                throw TestBoom()
            }
        } catch is TestBoom {}
        #expect(sceneClock() == SceneClock(now: 0.0, dt: 0.0))

        // PlaygroundHost.now drives evaluateSceneMatrix makeState sceneClock
        let host = PlaygroundHost<Int>()
        host.now = 3.5
        let seenMatrixClock = ClockBox()
        host.story(PlaygroundStory<Int>(
            path: "demo/clock",
            makeState: {
                seenMatrixClock.recordInit(sceneClock())
                return 1
            },
            view: { _, _, _ in text("ok").size(80, 20) }
        ))
        let cells = host.evaluateSceneMatrix { 0 }
        #expect(!cells.isEmpty)
        #expect(abs(seenMatrixClock.snapshot.0.now - 3.5) < 1e-6)
        #expect(abs(seenMatrixClock.snapshot.0.dt - (1.0 / 60.0)) < 1e-6)
        #expect(sceneClock() == SceneClock(now: 0.0, dt: 0.0))
    }

    @Test func taskbarBuilderAndAppDirsHome() {
        let tb = Taskbar()
            .progress(.paused)
            .badge(3, "3 alerts")
        #expect(tb.shownProgress == .paused)
        #expect(tb.count == 3)
        #expect(tb.badgeDescription == "3 alerts")

        let cleared = tb.badge(0, "should clear")
        #expect(cleared.count == 0)
        #expect(cleared.badgeDescription == "")

        #expect(AppDirs.homeFrom { $0 == "HOME" ? "/tmp/test-home" : nil }?.path == "/tmp/test-home")
        #expect(AppDirs.homeFrom { _ in nil } == nil)
    }

    @Test func txLaunchAndFlyTextDriveFlightsAndUnclippedAnimation() {
        struct State {
            var launched = false
            var flew = false
            var matchedMoved = false
            var unclipMatched = false
            var customMotion = false
        }
        func matchingFillPrims(_ scene: RefScene, _ target: SIMD4<Float>) -> [Primitive] {
            var out: [Primitive] = []
            for p in scene.primitives where p.kind == .roundedRect {
                if abs(p.fill.x - target.x) < 0.01
                    && abs(p.fill.y - target.y) < 0.01
                    && abs(p.fill.z - target.z) < 0.01 {
                    out.append(p)
                }
            }
            return out
        }
        let launchColor = Color.srgb(0.2, 0.45, 0.85)
        let matchedColor = Color.srgb(0.85, 0.35, 0.2)
        let rt = Runtime<State>(
            state: State(),
            viewport: Vec2(400, 300),
            pixelScale: 1.0
        ) { state, _ in
            let src: El<State> = text("hello").key("src-text").absolute(x: 240, y: 220).size(80, 24)
            let leftClipBase: El<State> = col()
            var leftClip = leftClipBase.key("left-clip").absolute(x: 0, y: 0).size(160, 300).clip(true)
            if state.launched {
                let launchText: El<State> = text("hello")
                let launchRowBase: El<State> = row()
                let launchRow = launchRowBase.children([launchText])
                    .key("dst-launch")
                    .bg(launchColor)
                    .absolute(x: 20, y: 40)
                    .size(100, 32)
                leftClip = leftClip.child(launchRow)
            }
            if state.flew {
                let flyTextEl: El<State> = text("hello")
                    .key("dst-fly")
                    .bg(.srgb(0.2, 0.7, 0.3))
                    .absolute(x: 20, y: 100)
                    .size(100, 24)
                leftClip = leftClip.child(flyTextEl)
            }
            if state.matchedMoved {
                let matchedDst: El<State> = el()
                leftClip = leftClip.child(
                    matchedDst.key("matched-dst").flightId("matched-badge").bg(matchedColor).absolute(x: 20, y: 160).size(40, 20)
                )
            }
            let rootBase: El<State> = col()
            var root = rootBase.size(400, 300).child(leftClip).child(src)
            if !state.matchedMoved {
                let matchedSrc: El<State> = el()
                root = root.child(
                    matchedSrc.key("matched-src").flightId("matched-badge").bg(matchedColor).absolute(x: 240, y: 160).size(40, 20)
                )
            }
            return root
        }

        _ = rt.frame(at: 0.0)
        #expect(!rt.isAnimating)

        // 1. Tx.launch: keeps own destination size (100x32), lifts unclipped beyond left-clip (160px), starts near (240, 220)
        rt.update(at: 0.1) { state, tx in
            state.launched = true
            tx.launch("src-text", to: "dst-launch")
        }
        let launchScene = rt.frame(at: 0.12)
        #expect(rt.isAnimating)
        let launchMid = rt.element(byKey: "dst-launch")
        #expect(launchMid != nil)
        if let rect = launchMid?.rect, rect.count >= 4 {
            #expect(rect[0] > 160.0)
            #expect(rect[1] > 45.0)
            #expect(abs(rect[2] - 100.0) < 0.5)
            #expect(abs(rect[3] - 32.0) < 0.5)
        }
        let targetLaunchFill = launchColor.simd4(srgb: rt.srgbBlend)
        let launchPrimitives = matchingFillPrims(launchScene, targetLaunchFill)
        #expect(!launchPrimitives.isEmpty)
        #expect(launchPrimitives.contains { $0.clip == SIMD4<Float>(0, 0, 400, 300) })

        _ = rt.frame(at: 2.0)
        #expect(!rt.isAnimating)

        // 2. Reduced motion bypasses Tx.launch without animating
        rt.update(at: 2.05) { state, _ in state.launched = false }
        _ = rt.frame(at: 2.06)
        rt.setSystemReducedMotion(true)
        rt.update(at: 2.1) { state, tx in
            state.launched = true
            tx.launch("src-text", to: "dst-launch")
        }
        _ = rt.frame(at: 2.1)
        #expect(!rt.isAnimating)
        if let rmRect = rt.element(byKey: "dst-launch")?.rect, rmRect.count >= 4 {
            #expect(abs(rmRect[0] - 20.0) < 0.5)
            #expect(abs(rmRect[1] - 40.0) < 0.5)
        }
        rt.setSystemReducedMotion(false)
        _ = rt.frame(at: 2.2)

        // 3. Regular El.flightId without unclippedFlights stays ancestor-clipped to left-clip (w <= 160)
        rt.update(at: 2.3) { state, _ in
            state.matchedMoved = true
        }
        let clippedMatchScene = rt.frame(at: 2.32)
        let targetMatchedFill = matchedColor.simd4(srgb: rt.srgbBlend)
        let clippedMatchPrims = matchingFillPrims(clippedMatchScene, targetMatchedFill)
        #expect(!clippedMatchPrims.isEmpty)
        #expect(clippedMatchPrims.allSatisfy { $0.clip.z <= 160.5 })
        _ = rt.frame(at: 4.5)

        // 4. El.flightId WITH tx.unclippedFlights() lifts clip to windowRect (w == 400)
        rt.update(at: 4.6) { state, _ in state.matchedMoved = false }
        _ = rt.frame(at: 6.5)
        rt.update(at: 6.6) { state, tx in
            state.matchedMoved = true
            tx.unclippedFlights()
        }
        let unclippedMatchScene = rt.frame(at: 6.62)
        let unclippedMatchPrims = matchingFillPrims(unclippedMatchScene, targetMatchedFill)
        #expect(unclippedMatchPrims.contains { $0.clip == SIMD4<Float>(0, 0, 400, 300) })
        _ = rt.frame(at: 8.5)

        // 5. Tx.flyText keeps destination box size intact (100x24) while flying "flight-source/dst-fly" unclipped at text extent
        rt.update(at: 8.6) { state, tx in
            state.flew = true
            tx.flyText("src-text", to: "dst-fly")
        }
        let flyScene = rt.frame(at: 8.65)
        #expect(rt.isAnimating)
        let flyMid = rt.element(byKey: "dst-fly")
        #expect(flyMid != nil)
        if let rect = flyMid?.rect, rect.count >= 4 {
            #expect(abs(rect[0] - 20.0) < 0.5)
            #expect(abs(rect[1] - 100.0) < 0.5)
            #expect(abs(rect[2] - 100.0) < 0.5)
            #expect(abs(rect[3] - 24.0) < 0.5)
        }
        let flyOverlay = rt.elements().first(where: { $0.path == "flight-source/dst-fly" })
        #expect(flyOverlay != nil)
        #expect(flyOverlay?.text == "hello")
        if let oRect = flyOverlay?.rect, oRect.count >= 4 {
            #expect(oRect[0] > 25.0)
            #expect(oRect[2] < 99.0)
        }
        #expect(flyScene.primitives.contains { isGlyph($0) && $0.clip == SIMD4<Float>(0, 0, 400, 300) })

        _ = rt.frame(at: 11.0)
        #expect(!rt.isAnimating)

        // 6. Tx.motion overrides launch spring
        rt.update(at: 11.1) { state, _ in state.launched = false }
        _ = rt.frame(at: 11.2)
        rt.update(at: 11.3) { state, tx in
            state.launched = true
            tx.launch("src-text", to: "dst-launch")
            tx.motion(Spring(duration: 0.15, bounce: 0.0))
        }
        _ = rt.frame(at: 11.35)
        #expect(rt.isAnimating)
        _ = rt.frame(at: 13.5)
        #expect(!rt.isAnimating)
    }

    @Test func frameProfileThreadCpuAndTakePhases() {
        FrameProfiling.withRecording { checkFramePhaseTotals() }
    }

    private func checkFramePhaseTotals() {
        _ = takeFramePhases()
        let t0 = threadCpuMs()
        #if canImport(Darwin) || os(Linux) || os(Android) || os(Windows)
        #expect(t0 > 0)
        #expect((PerfWarn.threadCpuMs() ?? 0) >= t0)
        #else
        #expect(t0 >= 0)
        #endif
        for phase in FramePhase.allCases {
            let weight = Double(phase.rawValue + 1)
            recordFramePhase(phase, wallMs: weight, cpuMs: weight / 4)
            recordFramePhase(phase, wallMs: weight / 2, cpuMs: weight / 4)
        }
        let taken = takeFramePhases()
        let cleared = takeFramePhases()
        #expect(cleared == Array(repeating: 0.0, count: 12))
        #expect(taken == [1.5, 3, 4.5, 6, 7.5, 9, 0.5, 1, 1.5, 2, 2.5, 3])

        // Verify Runtime.frame(at:) populates all 6 FramePhase slots
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            let root: El<Int> = col()
            return root.child(text("measured phase")).size(120, 40)
        }
        _ = rt.frame(at: 0.0)
        let framePhases = takeFramePhases()
        #expect(framePhases.count == 2 * FRAME_PHASES)
        for phase in FramePhase.allCases {
            #expect(framePhases[phase.rawValue] > 0.0)
        }
        _ = rt.renderFrame(at: 0.1)
        #expect(takeFramePhases()[FramePhase.paint.rawValue] > 0.0)
    }

    @Test func automaticPhasesPayForRequestedMeasurements() throws {
        enum Stop: Error { case done }
        try FrameProfiling.withRecording(false) {
            _ = takeFramePhases()
            var calls = 0
            func work() {
                calls += 1
                #if !os(WASI)
                Thread.sleep(forTimeInterval: 0.001)
                #endif
            }
            measureRuntimePhase(.view, work)
            #expect(takeFramePhases().allSatisfy { $0 == 0 })
            do {
                try FrameProfiling.withRecording {
                    #expect(FrameProfiling.isEnabled)
                    measureRuntimePhase(.view, work)
                    throw Stop.done
                }
            } catch Stop.done {}
            #expect(!FrameProfiling.isEnabled)
            let scoped = takeFramePhases()
            measureFramePhase(.apply, work)
            let explicit = takeFramePhases()
            #if !os(WASI)
            #expect(scoped[FramePhase.view.rawValue] > 0)
            #expect(explicit[FramePhase.apply.rawValue] > 0)
            #else
            #expect(scoped.count == 2 * FRAME_PHASES && explicit.count == scoped.count)
            #endif
            #expect(calls == 3)
        }
    }

    #if !os(WASI)
    @Test func framePhaseSnapshotsAreIsolatedBetweenThreads() {
        FrameProfiling.withRecording {
            _ = takeFramePhases()
            recordFramePhase(.view, wallMs: 5, cpuMs: 2)
            let finished = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                recordFramePhase(.layout, wallMs: 7, cpuMs: 3)
                #expect(takeFramePhases() == [0, 0, 7, 0, 0, 0, 0, 0, 3, 0, 0, 0])
                finished.signal()
            }
            finished.wait()
            #expect(takeFramePhases() == [5, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0])
        }
    }
    #endif

    @Test func appSharedMemoLayoutWithCompositorAndTextStyleParity() {
        let shared = AppShared<Int>()
        let woke = LockedCounter()
        shared.connect(Waker { woke.add(1) })
        #expect(woke.value == 1)

        shared.requestPlace(PlaceRequest(position: Vec2(10, 20), size: Vec2(300, 200)))
        let placed = shared.takePlace()
        #expect(placed?.position == Vec2(10, 20))
        #expect(shared.takePlace() == nil)

        shared.requestOpen()
        let drained = shared.take()
        #expect(drained.window == .open)
        #expect(shared.take().window == .none)

        let configuredApp = App<Int>(state: 0) { _, _ in text("ok") }
            .sameTabRouter { $0.hasPrefix("tab:") }
            .args(["--headless"])
        #expect(configuredApp.sameTabRouterHook?("tab:main") == true)

        let cache = MemoCache()
        let builds = LockedCounter()
        let e1: El<Int> = memoWithHash("card", 42, cache: cache) {
            builds.add(1)
            return text("v1")
        }
        let e2: El<Int> = memoWithHash("card", 42, cache: cache) {
            builds.add(1)
            return text("v1-cached")
        }
        let e3: El<Int> = memoWithHash("card", 43, cache: cache) {
            builds.add(1)
            return text("v2")
        }
        #expect(builds.value == 2)
        #expect(e1.plainText == "v1")
        #expect(e2.plainText == "v1")
        #expect(e3.plainText == "v2")

        final class CapturedLayout: @unchecked Sendable {
            private let lock = NSLock()
            private var _localW: Float?
            private var _winX: Float?
            func set(w: Float?, x: Float?) { lock.lock(); _localW = w; _winX = x; lock.unlock() }
            var w: Float? { lock.lock(); defer { lock.unlock() }; return _localW }
            var x: Float? { lock.lock(); defer { lock.unlock() }; return _winX }
        }
        let cap = CapturedLayout()
        let rtLayout = Runtime<Int>(state: 0, viewport: Vec2(300, 200), pixelScale: 1.0) { _, cx in
            let w1 = cx.layoutWith("box") { $0[2] }
            let w2 = layoutWith("box") { $0[2] }
            let wx = cx.windowLayoutWith("box") { $0[0] }
            let wxFree = windowLayoutWith("box") { $0[0] }
            if w1 == w2 && wx == wxFree {
                cap.set(w: w1, x: wx)
            }
            let container: El<Int> = col()
            let box: El<Int> = el()
            return container.size(300, 200).child(
                box.key("box").absolute(x: 24, y: 12).size(88, 36)
            )
        }
        _ = rtLayout.frame(at: 0.0)
        _ = rtLayout.frame(at: 0.05)
        #expect(cap.w == 88.0)
        #expect(cap.x == 24.0)

        let enc = FrameEncoded(outcome: .drawn, frameMs: 2.0, at: 1.25, window: "main", seq: 7, presentsAt: 1.26, started: 1.24, refreshHz: 120.0)
        #expect(enc.at == 1.25)
        #expect(enc.window == "main")
        #expect(enc.seq == 7)
        #expect(enc.presentsAt == 1.26)
        #expect(enc.started == 1.24)
        #expect(enc.refreshHz == 120.0)

        let gPrim = Primitive.glyph(rect: SIMD4(0, 0, 8, 8), uv: SIMD4(0, 0, 1, 1), color: SIMD4(1, 1, 1, 1), clip: SIMD4(0, 0, 100, 100))
        let rPrim = Primitive.roundedRect(rect: SIMD4(0, 0, 8, 8), fill: .zero, clip: SIMD4(0, 0, 100, 100))
        #expect(isGlyph(gPrim))
        #expect(!isGlyph(rPrim))

        let styled = TextStyle(size: 14)
            .family(.systemMono)
            .variations("wght=600")
            .features("ss01=1")
            .opticalSize(16)
            .opticalSizing(.auto)
        #expect(styled.family == .systemMono)
        #expect(FontFamily.named("Menlo") == .custom("Menlo"))
        #expect(styled.variations == "wght=600")
        #expect(styled.features == "ss01=1")
        #expect(styled.opticalSize == .auto)
        #expect(styled.linePx() == styled.resolvedLineHeight)
    }
}

private final class LockedRectPair: @unchecked Sendable {
    private let lock = NSLock()
    private var _chrome: ChromeInsets = .zero
    private var _titlebar: Float = 0
    func record(chrome: ChromeInsets, titlebar: Float) {
        lock.lock()
        _chrome = chrome
        _titlebar = titlebar
        lock.unlock()
    }
    var chrome: ChromeInsets { lock.lock(); defer { lock.unlock() }; return _chrome }
    var titlebar: Float { lock.lock(); defer { lock.unlock() }; return _titlebar }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add(_ delta: Int) { lock.lock(); n += delta; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
