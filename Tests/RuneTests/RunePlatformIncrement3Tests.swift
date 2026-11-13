import Foundation
import Testing
import RuneMotion
import RuneRef
@testable import Rune

#if os(macOS)
import AppKit
#endif

@Suite("Platform Increment 3 Parity — Overlay Content & Presence")
struct RunePlatformIncrement3Tests {
    // MARK: - Helpers mirroring platform/macos/presence_tests.rs

    private let fadeDuration: Double = 0.200
    private let immediate: Double = 0.0

    private func apply(_ p: inout MacOSPanelPresence, _ effect: MacOSPanelPresence.Effect) {
        if case let .drawOccluded(on) = effect {
            p = p.withDrawsOccluded(on)
        }
    }

    private func carried(_ p: inout MacOSPanelPresence, _ event: MacOSPanelPresence.Event) -> [(MacOSPanelPresence.Effect, Bool)] {
        var out: [(MacOSPanelPresence.Effect, Bool)] = []
        for effect in p.step(event) {
            let answer = p.drawsOccluded
            apply(&p, effect)
            out.append((effect, answer))
        }
        return out
    }

    private func step(_ p: inout MacOSPanelPresence, _ event: MacOSPanelPresence.Event) -> [MacOSPanelPresence.Effect] {
        carried(&p, event).map(\.0)
    }

    private func fenceOf(_ p: inout MacOSPanelPresence, _ event: MacOSPanelPresence.Event) -> FenceAttempt {
        for effect in step(&p, event) {
            if case let .fade(_, overSeconds: _?, fence: fence?) = effect {
                return fence
            }
        }
        Issue.record("expected a fade with a duration and fence")
        return FenceAttempt(0)
    }

    private func showFading(_ p: inout MacOSPanelPresence) -> FenceAttempt {
        fenceOf(&p, .show(fadeSeconds: fadeDuration))
    }

    private func hideFading(_ p: inout MacOSPanelPresence) -> FenceAttempt {
        fenceOf(&p, .hide(fadeSeconds: fadeDuration))
    }

    private func showNow(_ p: inout MacOSPanelPresence) {
        _ = step(&p, .show(fadeSeconds: immediate))
    }

    private func hideNow(_ p: inout MacOSPanelPresence) {
        _ = step(&p, .hide(fadeSeconds: immediate))
    }

    private func assertStale(_ p: inout MacOSPanelPresence, _ fence: FenceAttempt) {
        let before = p
        #expect(step(&p, .fadeEnded(fence: fence)) == [])
        #expect(p == before)
    }

    private func isOrderIn(_ effect: MacOSPanelPresence.Effect) -> Bool {
        if case .orderIn = effect { return true }
        return false
    }

    private func isFade(_ effect: MacOSPanelPresence.Effect) -> Bool {
        if case .fade = effect { return true }
        return false
    }

    // MARK: - platform/macos/presence_tests.rs

    @Test
    func showExcludesBeforeOrderingInAndAlphaRises() {
        var p = MacOSPanelPresence(requested: true)
        let fence = FenceAttempt(1)
        #expect(step(&p, .show(fadeSeconds: fadeDuration)) == [
            .setSharing(true),
            .rejoinSpaces,
            .orderIn(clearAlpha: true),
            .drawOccluded(true),
            .fade(alpha: 1.0, overSeconds: fadeDuration, fence: fence)
        ])
    }

    @Test
    func showWithoutFadeKeepsAlphaUntilItLands() {
        var p = MacOSPanelPresence(requested: false)
        #expect(step(&p, .show(fadeSeconds: immediate)) == [
            .setSharing(false),
            .rejoinSpaces,
            .orderIn(clearAlpha: false),
            .drawOccluded(false),
            .fade(alpha: 1.0, overSeconds: nil, fence: nil)
        ])
        #expect(p.isVisible && !p.drawsOccluded)
    }

    @Test
    func hideStopsInputFirstAndFadeKeepsPanelOrdered() {
        var p = MacOSPanelPresence(requested: true)
        showNow(&p)
        #expect(step(&p, .hide(fadeSeconds: fadeDuration)) == [
            .drawOccluded(false),
            .ignoreMouse,
            .drawOccluded(true),
            .fade(alpha: 0.0, overSeconds: fadeDuration, fence: FenceAttempt(2)),
            .resignKey,
            .setSharing(true)
        ])
    }

    @Test
    func hideWithoutFadeOrdersOutBeforeRestoringSharing() {
        var p = MacOSPanelPresence(requested: true)
        showNow(&p)
        #expect(step(&p, .hide(fadeSeconds: immediate)) == [
            .drawOccluded(false),
            .ignoreMouse,
            .drawOccluded(false),
            .fade(alpha: 0.0, overSeconds: nil, fence: nil),
            .orderOut,
            .resignKey,
            .setSharing(false)
        ])
        #expect(!p.isOrdered)
        #expect(!p.isExcluded && p.requested)
    }

    @Test
    func fadeOutEndsByOrderingOutThenRestoringSharing() {
        var p = MacOSPanelPresence(requested: true)
        showNow(&p)
        let out = hideFading(&p)
        #expect(p.isOrdered && p.isExcluded && !p.isVisible)
        #expect(p.drawsOccluded)
        #expect(step(&p, .fadeEnded(fence: out)) == [.drawOccluded(false), .orderOut, .setSharing(false)])
        #expect(!p.isOrdered && !p.isExcluded && !p.drawsOccluded)
    }

    @Test
    func fadeInEndsShownAndAsksNothing() {
        var p = MacOSPanelPresence(requested: true)
        let fence = showFading(&p)
        #expect(p.isVisible && p.drawsOccluded)
        #expect(step(&p, .fadeEnded(fence: fence)) == [.drawOccluded(false)])
        #expect(p.isVisible && p.isExcluded && !p.drawsOccluded)
    }

    @Test
    func hideDuringFadeInReplacesIt() {
        var p = MacOSPanelPresence(requested: true)
        let shown = showFading(&p)
        let out = hideFading(&p)
        #expect(!p.isVisible && p.isOrdered && p.drawsOccluded)
        assertStale(&p, shown)
        #expect(p.isOrdered)
        #expect(step(&p, .fadeEnded(fence: out)) == [.drawOccluded(false), .orderOut, .setSharing(false)])

        var p2 = MacOSPanelPresence(requested: true)
        let shown2 = showFading(&p2)
        hideNow(&p2)
        #expect(!p2.isOrdered && !p2.drawsOccluded)
        assertStale(&p2, shown2)
        #expect(!p2.isExcluded)
    }

    @Test
    func showDuringFadeOutWins() {
        var p = MacOSPanelPresence(requested: true)
        showNow(&p)
        let out = hideFading(&p)
        let back = showFading(&p)
        assertStale(&p, out)
        #expect(p.isOrdered && p.isVisible)
        #expect(p.drawsOccluded)
        #expect(step(&p, .fadeEnded(fence: back)) == [.drawOccluded(false)])
        #expect(p.isExcluded && !p.drawsOccluded)

        var p2 = MacOSPanelPresence(requested: true)
        showNow(&p2)
        let out2 = hideFading(&p2)
        showNow(&p2)
        #expect(!p2.drawsOccluded)
        assertStale(&p2, out2)
        #expect(p2.isOrdered && p2.isExcluded)
    }

    @Test
    func secondHideDuringFadeOutReplacesIt() {
        var p = MacOSPanelPresence(requested: true)
        showNow(&p)
        let first = hideFading(&p)
        let second = hideFading(&p)
        assertStale(&p, first)
        #expect(p.isOrdered)
        #expect(step(&p, .fadeEnded(fence: second)) == [.drawOccluded(false), .orderOut, .setSharing(false)])
    }

    @Test
    func prewarmTransitionsAndCaptureExclusionAndOcclusion() {
        var p = MacOSPanelPresence(requested: true)
        #expect(step(&p, .prewarmBegins) == [.setAlpha(0.0), .ignoreMouse, .orderIn(clearAlpha: false), .drawOccluded(true)])
        #expect(!p.isOrdered && !p.isVisible && p.drawsOccluded)
        #expect(p.requested && !p.isExcluded)
        #expect(step(&p, .prewarmEnds) == [.drawOccluded(false), .orderOut])
        #expect(!p.drawsOccluded)
        showNow(&p)
        #expect(p.isExcluded)

        var p2 = MacOSPanelPresence(requested: true)
        _ = step(&p2, .prewarmBegins)
        #expect(step(&p2, .hide(fadeSeconds: immediate)).contains(.orderOut))
        #expect(p2.drawsOccluded)
        #expect(step(&p2, .prewarmEnds) == [.drawOccluded(false), .orderOut])
        #expect(!p2.drawsOccluded && !p2.isOrdered)

        var p3 = MacOSPanelPresence(requested: true)
        _ = step(&p3, .prewarmBegins)
        let out = hideFading(&p3)
        #expect(!p3.isOrdered && !p3.isExcluded)
        #expect(step(&p3, .prewarmEnds) == [.drawOccluded(true), .orderOut])
        #expect(p3.drawsOccluded)
        #expect(step(&p3, .fadeEnded(fence: out)) == [.drawOccluded(false), .orderOut, .setSharing(false)])
        #expect(!p3.drawsOccluded)

        var p4 = MacOSPanelPresence(requested: true)
        _ = step(&p4, .prewarmBegins)
        let fence = showFading(&p4)
        #expect(step(&p4, .prewarmEnds) == [.drawOccluded(true)])
        #expect(p4.isOrdered && p4.isExcluded && p4.drawsOccluded)
        _ = step(&p4, .fadeEnded(fence: fence))
        #expect(!p4.drawsOccluded)

        var p5 = MacOSPanelPresence(requested: true)
        showNow(&p5)
        let out5 = hideFading(&p5)
        _ = step(&p5, .prewarmBegins)
        _ = step(&p5, .fadeEnded(fence: out5))
        #expect(!p5.isOrdered && p5.drawsOccluded)
        #expect(step(&p5, .prewarmEnds) == [.drawOccluded(false), .orderOut])
        #expect(!p5.drawsOccluded)
    }

    @Test
    func occlusionOverrideTimingMatchesCarriedEffects() {
        var p = MacOSPanelPresence(requested: false)
        let show = carried(&p, .show(fadeSeconds: fadeDuration))
        let duringOrderIn = show.first(where: { isOrderIn($0.0) })!.1
        let duringFade = show.first(where: { isFade($0.0) })!.1
        #expect(!duringOrderIn)
        #expect(duringFade)

        var p2 = MacOSPanelPresence(requested: false)
        showNow(&p2)
        _ = hideFading(&p2)
        let immediateShow = carried(&p2, .show(fadeSeconds: immediate))
        #expect(immediateShow.first(where: { isOrderIn($0.0) })!.1)
        #expect(!immediateShow.first(where: { isFade($0.0) })!.1)

        var p3 = MacOSPanelPresence(requested: false)
        let warm = carried(&p3, .prewarmBegins)
        #expect(!warm.first(where: { isOrderIn($0.0) })!.1)
        #expect(p3.drawsOccluded)

        var p4 = MacOSPanelPresence(requested: false)
        _ = showFading(&p4)
        let hide = carried(&p4, .hide(fadeSeconds: fadeDuration))
        #expect(!hide.first(where: { $0.0 == .ignoreMouse })!.1)
        #expect(hide.first(where: { isFade($0.0) })!.1)
    }

    @Test
    func exhaustiveSixStepSequenceWalkMatchesReferenceFlags() {
        struct Flags {
            var generation: UInt64 = 0
            var shown = false
            var requested = false
            var visible = false
            var revealing = false
            var warming = false

            var answer: Bool { warming || revealing }

            mutating func fadeTo(_ alpha: Double, length: Double, out: inout [MacOSPanelPresence.Effect]) {
                let fading = length > 0.0
                revealing = fading
                out.append(.drawOccluded(answer))
                out.append(.fade(alpha: alpha, overSeconds: fading ? length : nil, fence: fading ? FenceAttempt(generation) : nil))
                if !fading && !shown {
                    out.append(.orderOut)
                }
            }

            mutating func show(_ fade: Double) -> [MacOSPanelPresence.Effect] {
                var out: [MacOSPanelPresence.Effect] = []
                visible = true
                shown = true
                generation += 1
                out.append(.setSharing(requested && shown))
                out.append(.rejoinSpaces)
                out.append(.orderIn(clearAlpha: fade > 0.0))
                fadeTo(1.0, length: fade, out: &out)
                return out
            }

            mutating func hide(_ fade: Double) -> [MacOSPanelPresence.Effect] {
                var out: [MacOSPanelPresence.Effect] = []
                visible = false
                revealing = false
                out.append(.drawOccluded(answer))
                out.append(.ignoreMouse)
                if fade <= 0.0 { shown = false }
                generation += 1
                let excluded = requested && shown
                fadeTo(0.0, length: fade, out: &out)
                out.append(.resignKey)
                out.append(.setSharing(excluded))
                return out
            }

            mutating func prewarm() -> [MacOSPanelPresence.Effect] {
                warming = true
                return [.setAlpha(0.0), .ignoreMouse, .orderIn(clearAlpha: false), .drawOccluded(answer)]
            }

            mutating func prewarmEnds() -> [MacOSPanelPresence.Effect] {
                warming = false
                var out: [MacOSPanelPresence.Effect] = [.drawOccluded(answer)]
                if !shown { out.append(.orderOut) }
                return out
            }

            mutating func fadeDone(generation gen: UInt64, hiding: Bool) -> [MacOSPanelPresence.Effect] {
                guard gen == generation else { return [] }
                if hiding { shown = false }
                revealing = false
                var out: [MacOSPanelPresence.Effect] = [.drawOccluded(answer)]
                if !shown { out.append(.orderOut) }
                if hiding { out.append(.setSharing(requested && shown)) }
                return out
            }
        }

        enum StepKind {
            case show(Double), hide(Double), prewarm, prewarmEnds, toggle, endOldest, endNewest
        }

        let steps: [StepKind] = [
            .show(fadeDuration), .show(immediate),
            .hide(fadeDuration), .hide(immediate),
            .prewarm, .prewarmEnds,
            .toggle, .endOldest, .endNewest
        ]

        func walk(_ p: MacOSPanelPresence, _ flags: Flags, _ fades: [(UInt64, Bool)], _ depth: Int) {
            if depth == 0 { return }
            for s in steps {
                var np = p
                var nflags = flags
                var nfades = fades
                let asked: [MacOSPanelPresence.Effect]
                let expected: [MacOSPanelPresence.Effect]
                switch s {
                case let .show(f):
                    asked = np.step(.show(fadeSeconds: f))
                    expected = nflags.show(f)
                case let .hide(f):
                    asked = np.step(.hide(fadeSeconds: f))
                    expected = nflags.hide(f)
                case .prewarm:
                    asked = np.step(.prewarmBegins)
                    expected = nflags.prewarm()
                case .prewarmEnds:
                    asked = np.step(.prewarmEnds)
                    expected = nflags.prewarmEnds()
                case .toggle:
                    nflags.requested.toggle()
                    asked = np.step(.request(exclude: nflags.requested))
                    expected = [.setSharing(nflags.requested && nflags.shown)]
                case .endOldest, .endNewest:
                    if nfades.isEmpty { continue }
                    let idx = if case .endOldest = s { 0 } else { nfades.count - 1 }
                    let (gen, hiding) = nfades.remove(at: idx)
                    asked = np.step(.fadeEnded(fence: FenceAttempt(gen)))
                    expected = nflags.fadeDone(generation: gen, hiding: hiding)
                }
                #expect(asked == expected)
                for eff in asked {
                    if case let .drawOccluded(on) = eff { np = np.withDrawsOccluded(on) }
                    if case let .fade(alpha, overSeconds: _?, fence: fence?) = eff {
                        nfades.append((fence.rawValue, alpha == 0.0))
                    }
                }
                #expect(np.isVisible == nflags.visible)
                #expect(np.isOrdered == nflags.shown)
                #expect(np.isExcluded == (nflags.requested && nflags.shown))
                #expect(np.requested == nflags.requested)
                #expect(np.drawsOccluded == nflags.answer)
                walk(np, nflags, nfades, depth - 1)
            }
        }

        for requested in [false, true] {
            var flags = Flags()
            flags.requested = requested
            walk(MacOSPanelPresence(requested: requested), flags, [], 6)
        }
    }

    // MARK: - overlay/options.rs pure geometry & display math

    @Test
    func scaleUnderSelectsDisplayHoldingMostOfFrame() {
        let displays: [(frame: [Double], scale: Double)] = [
            ([0, 0, 1512, 982], 2.0),
            ([1512, 0, 1920, 1080], 1.0)
        ]
        #expect(OverlayGeometry.scaleUnder(frame: [100, 100, 400, 300], displays: displays) == 2.0)
        #expect(OverlayGeometry.scaleUnder(frame: [1400, 100, 400, 300], displays: displays) == 1.0)
        #expect(OverlayGeometry.scaleUnder(frame: [1400, 100, 200, 300], displays: displays) == 2.0)
        #expect(OverlayGeometry.scaleUnder(frame: [-900, 0, 400, 300], displays: displays) == nil)
    }

    @Test
    func displaySelectionHandlesNegativeOriginsSharedEdgesAndDisconnects() {
        let bounds: [[Double]] = [
            [-3840, -200, 0, 1960],
            [0, 0, 1920, 1080]
        ]
        #expect(OverlayGeometry.chooseDisplay(bounds: bounds, primary: 1, requested: nil, pointer: (-100, 0)) == 0)
        #expect(OverlayGeometry.chooseDisplay(bounds: bounds, primary: 1, requested: nil, pointer: (0, 0)) == 1)
        #expect(OverlayGeometry.chooseDisplay(bounds: bounds, primary: 1, requested: 0, pointer: nil) == 0)
        #expect(OverlayGeometry.chooseDisplay(bounds: bounds, primary: 1, requested: 4, pointer: nil) == 1)
        #expect(OverlayGeometry.chooseDisplay(bounds: bounds, primary: nil, requested: nil, pointer: nil) == 0)
        #expect(OverlayGeometry.chooseDisplay(bounds: [], primary: nil, requested: nil, pointer: nil) == nil)
    }

    @Test
    func edgeAndRectUseDisplayLocalPoints() {
        let at = OverlayGeometry.Placement(
            size: Vec2(300, 80),
            edge: .bottom,
            margin: 24,
            align: .end,
            inset: 12
        )
        #expect(OverlayGeometry.localRect(at: at, placement: nil, area: Vec2(960, 540)) == [648, 436, 300, 80])
        #expect(OverlayGeometry.localRect(at: at, placement: .fullDisplay, area: Vec2(960, 540)) == [0, 0, 960, 540])
        #expect(OverlayGeometry.localRect(at: at, placement: .rect(MotionRect(left: -10, top: 20, right: 90, bottom: 70)), area: Vec2(960, 540)) == [-10, 20, 100, 50])
    }

    // MARK: - overlay/tests.rs & OverlayHandle parity

    @Test
    func fadeOutDrawsExitUntilDeadlineAndImmediateHideStopsAtOnce() {
        let spec = OverlaySpec(
            name: "fade-test",
            size: Vec2(220, 60),
            makeState: { Float(12.0) },
            view: { width, _ in
                el().key("box").w(width).h(20).bg(.srgb(0.2, 0.7, 0.4))
            }
        )
        let handle = OverlayHandle(spec: spec)
        handle.fadeIn(0.0)
        _ = handle.present(at: 1.0)
        #expect(handle.overlayPresence.isShown && handle.overlayPresence.isDrawing)
        #expect(!handle.isFrameless)

        handle.update { $0 = 180.0 }
        handle.fadeOut(0.15, now: 1.0)
        #expect(!handle.isVisible)
        #expect(!handle.overlayPresence.isShown)
        #expect(handle.overlayPresence.isDrawing && !handle.isFrameless)
        #expect(handle.setOccluded(true) == false, "fading-out panel stays unoccluded to draw its exit")

        let midScene = handle.present(at: 1.05)
        #expect(midScene != nil)
        #expect(handle.overlayPresence.isDrawing)

        handle.advanceDue(at: 1.20)
        #expect(!handle.overlayPresence.isDrawing && handle.isFrameless)
        #expect(handle.present(at: 1.25) == nil)

        // Hiding immediately stops drawing at once, and fading an already-hidden overlay draws nothing
        let h2 = OverlayHandle(spec: spec)
        h2.fadeIn(0.0)
        h2.hide()
        #expect(!h2.overlayPresence.isDrawing && h2.isFrameless)
        h2.fadeOut(0.15, now: 2.0)
        #expect(!h2.overlayPresence.isDrawing)
    }

    @Test
    func updateIfFalseAvoidsDirtyRebuildAndPreferencesDirtyHiddenOverlay() {
        let spec = OverlaySpec(
            name: "prefs-test",
            size: Vec2(160, 40),
            makeState: { 1 },
            view: { val, _ in text("Count: \(val)") }
        )
        let handle = OverlayHandle(spec: spec)
        handle.fadeIn(0.0)
        _ = handle.present(at: 0.0)
        #expect(!handle.isDirty)

        let unchanged = handle.updateIf { _, _ in false }
        #expect(!unchanged)
        #expect(!handle.isDirty)

        let changed = handle.updateIf { state, _ in
            state = 2
            return true
        }
        #expect(changed)
        #expect(handle.isDirty)
        #expect(handle.readState { $0 } == 2)

        handle.hide()
        _ = handle.present(at: 0.1)
        let dark = !handle.systemDark
        handle.setThemeDark(dark)
        #expect(handle.systemDark == dark)
        #expect(handle.isDirty)

        let alwaysBars = SystemScrollBars(bars: .always, scrollerOverlay: false, jumpToClick: false)
        handle.setScrollBars(alwaysBars)
        #expect(handle.systemScrollBars == alwaysBars)
        #expect(handle.isDirty)
    }

    @Test
    func gpuReleasePolicyMatchesPlatformSemantics() {
        #expect(OverlayGpuRelease.make(afterSeconds: nil, isMacOS: true) == .keep)
        #expect(OverlayGpuRelease.make(afterSeconds: 0.0, isMacOS: true) == .now)
        #expect(OverlayGpuRelease.make(afterSeconds: 30.0, isMacOS: true) == .keep)
        #expect(OverlayGpuRelease.make(afterSeconds: 30.0, isMacOS: false) == .after(30.0))
    }

    #if os(macOS)
    @Test @MainActor
    func macOSOverlayPanelHostsRealMetalViewAndHitRegionsAndRelease() {
        var createdInfo: OverlayCreated?
        let spec = OverlaySpec<Int>(
            name: "macos-content",
            size: Vec2(240, 80),
            makeState: { 0 },
            view: { clicks, _ in
                el()
                    .w(240)
                    .h(80)
                    .bg(Color.transparent)
                    .child(
                        el()
                            .key("hit-btn")
                            .absolute(x: 20, y: 10)
                            .w(80)
                            .h(30)
                            .onClick { $0 += 1 }
                            .child(text("Clicks: \(clicks)"))
                    )
            }
        )
        let configured = spec
            .configured(OverlayOptions(
                placement: .edge(.top, margin: 16),
                excludeFromCapture: true,
                keyPolicy: .nonActivating,
                input: .regions,
                releaseGpuWhenHidden: true
            ))
            .onCreated { info in createdInfo = info }

        let handle = OverlayHandle(configured: configured)
        handle.show()

        #expect(createdInfo != nil)
        #expect(createdInfo?.capabilities.nonactivatingKeys == .supported)
        #expect(handle.windowNumber != nil)
        #expect(handle.availability == .available)
        #expect(handle.captureExclusion == .requested)

        let regions = handle.runtime.overlayInteractiveRegions()
        #expect(!regions.isEmpty)

        let tester = RuneOverlayHitTester(input: .regions, interactive: false, regions: regions)
        #expect(tester.shouldIntercept(at: Vec2(40, 20)))
        #expect(!tester.shouldIntercept(at: Vec2(200, 60)))

        // Simulate click directly into runtime hosted by the overlay
        handle.runtime.pointerDown(at: Vec2(40, 20), button: .primary, mods: .none, at: 0.1)
        handle.runtime.pointerUp(at: Vec2(40, 20), button: .primary, mods: .none, at: 0.11)
        #expect(handle.readState { $0 } == 1)

        // Hiding with releaseGpuWhenHidden drops panel + GPU while keeping State intact
        handle.hide()
        #expect(!handle.isVisible)
        #expect(handle.readState { $0 } == 1)
        #expect(handle.windowNumber == nil)
    }
    #endif
}
