import Foundation
import Testing
@testable import Rune
@testable import RuneMotion

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
        setJumpList(jl)
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
