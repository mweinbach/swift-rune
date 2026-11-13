import Foundation
import Testing
@testable import Rune

#if os(macOS)
import AppKit
import ObjectiveC
#endif

@Suite("Platform Increment 2 Parity (Multi-Window, #819 Rest, #836 RTL Traffic Lights)")
struct RunePlatformIncrement2Tests {

    // MARK: - WindowSpec / WindowOptions / MacWindowOptions (window/spec.rs)

    @Test("WindowSpec: launcher preset is hidden and preserves ordinary defaults")
    func launcherPresetIsHiddenAndPreservesOrdinaryDefaults() {
        let preset = RuneWindowOptions.launcherPanel()
        #expect(preset.native.nonactivatingPanel && preset.native.launcher)
        #expect(!preset.options.visible && preset.options.borderless && preset.options.transparent)
        #expect(!RuneMacWindowOptions().nonactivatingPanel(true).launcher)
        #expect(!preset.native.nonactivatingPanel(false).launcher)
        #expect(RuneWindowOptions.default.visible)

        let spec = AppSpec<Int>(title: "launcher", size: Vec2(300, 100), state: 0) { _, _ in El<Int>() }
        let window = RuneWindowSpec(key: "launcher", app: spec).configuredOptions(RuneWindowOptions.launcherPanel())
        #expect(window.macosWindow.launcher)
        #expect(!window.options.visible && window.options.transparent)
    }

    @Test("WindowSpec: amending launcher preset keeps launcher behaviour")
    func amendingPresetKeepsLauncherBehaviour() {
        let preset = RuneWindowOptions.launcherPanel().macos { native in
            native.cornerRadius(16.0).shadow(true)
        }
        #expect(preset.native.launcher && preset.native.nonactivatingPanel)
        #expect(preset.native.cornerRadius == 16.0 && preset.native.shadow == true)
        #expect(!preset.options.visible && preset.options.transparent)

        let spec = AppSpec<Int>(title: "launcher", size: Vec2(300, 100), state: 0) { _, _ in El<Int>() }
        let window = RuneWindowSpec(key: "launcher", app: spec).configuredOptions(preset)
        #expect(window.macosWindow.launcher)
        #expect(window.macosWindow.cornerRadius == 16.0)
    }

    @Test("WindowSpec: app child windows follow their app and share its key space")
    func appWindowsFollowTheirAppAndShareKeySpace() throws {
        let mainSpec = AppSpec<Int>(title: "main", size: Vec2(100, 100), state: 0) { _, _ in El<Int>() }
        let settingsSpec = AppSpec<String>(title: "settings", size: Vec2(100, 100), state: "") { _, _ in El<String>() }
        let otherSpec = AppSpec<Int>(title: "other", size: Vec2(100, 100), state: 0) { _, _ in El<Int>() }

        let (main, handle) = RuneWindowSpec(key: "main", app: mainSpec)
            .window(RuneWindowSpec(key: "settings", app: settingsSpec))
        #expect(handle.key == "settings")

        let other = RuneWindowSpec(key: "other", app: otherSpec)
        let flat = RuneMultiWindow.flatten([main.boxed(), other.boxed()])
        #expect(flat.map(\.key) == ["main", "settings", "other"])
        #expect(flat[1].secondary)
        #expect(!flat[0].secondary && !flat[2].secondary)
        try RuneMultiWindow.validate(flat)

        let (clash, _) = RuneWindowSpec(key: "settings", app: mainSpec)
            .window(RuneWindowSpec(key: "settings", app: settingsSpec))
        #expect(throws: MultiWindowError.emptyOrDuplicateKey("settings")) {
            try RuneMultiWindow.validate(RuneMultiWindow.flatten([clash.boxed()]))
        }
        #expect(throws: MultiWindowError.emptyOrDuplicateKey("")) {
            try RuneMultiWindow.validate([RuneWindowSpec(key: "", app: mainSpec).boxed()])
        }
    }

    @Test("WindowOptions: compact window overrides legacy minimum without changing defaults")
    func compactWindowOverridesLegacyMinimum() {
        let defaults = RuneWindowOptions.default.attributes(title: "app", size: (560, 440), appMin: nil, visible: true)
        #expect(defaults.minInnerSize == (420, 400))
        #expect(defaults.resizable && defaults.decorations && defaults.visible)
        #expect(defaults.maxInnerSize == nil)

        var compactOpts = RuneWindowOptions.default
        compactOpts.minSize = (280, 80)
        compactOpts.maxSize = (320, 120)
        compactOpts.resizable = false
        compactOpts.borderless = true
        let compact = compactOpts.attributes(title: "compact", size: (300, 100), appMin: (860, 560), visible: false)
        #expect(compact.innerSize == (300, 100))
        #expect(compact.minInnerSize == (280, 80))
        #expect(compact.maxInnerSize?.0 == 320 && compact.maxInnerSize?.1 == 120)
        #expect(!compact.resizable && !compact.maximizeButtonEnabled && !compact.decorations && !compact.visible)
    }

    @Test("WindowOptions: maximum alone caps inherited minimum per axis")
    func maximumAloneCapsInheritedMinimumPerAxis() {
        var opts = RuneWindowOptions.default
        opts.maxSize = (320, 120)

        let a = opts.attributes(title: "compact", size: (300, 100), appMin: nil, visible: true)
        #expect(a.minInnerSize == (320, 120))
        #expect(a.maxInnerSize?.0 == 320 && a.maxInnerSize?.1 == 120)

        let b = opts.attributes(title: "compact", size: (300, 100), appMin: (860, 80), visible: true)
        #expect(b.minInnerSize == (320, 80))
        #expect(b.maxInnerSize?.0 == 320 && b.maxInnerSize?.1 == 120)
    }

    @Test("WindowOptions: default options inherit app minimum and fit-height drops min height")
    func defaultOptionsInheritAppMinAndFitMinSize() {
        let attrs = RuneWindowOptions.default.attributes(title: "app", size: (900, 600), appMin: (860, 560), visible: true)
        #expect(attrs.minInnerSize == (860, 560))

        let fit = RuneWindowOptions.default.fitMinSize(appMin: nil)
        let (minLim, maxLim) = RuneWindowOptions.default.sizeLimits(appMin: fit)
        #expect(minLim == (420, 0) && maxLim == nil)
        #expect(RuneWindowOptions.default.fitMinSize(appMin: (300, 200))?.0 == 300)
        #expect(RuneWindowOptions.default.fitMinSize(appMin: (300, 200))?.1 == 200)

        var custom = RuneWindowOptions.default
        custom.minSize = (300, 500)
        let (customMin, _) = custom.sizeLimits(appMin: custom.fitMinSize(appMin: nil))
        #expect(customMin == (300, 500))
    }

    @Test("WindowOptions: overlay preset targets display bounds")
    func overlayPresetTargetsDisplay() {
        let display = DisplayInfo(
            id: RuneDisplayId(native: .macOS(42)),
            name: "Main",
            position: (-1920, 100),
            size: (3840, 2160),
            scale: 2.0,
            primary: false
        )
        let opts = RuneWindowOptions.overlay(display: display)
        #expect(opts.transparent && opts.borderless && opts.clickThrough && opts.alwaysOnTop && opts.visible)
        #expect(opts.position?.0 == -1920 && opts.position?.1 == 100)
        #expect(opts.physicalSize?.0 == 3840 && opts.physicalSize?.1 == 2160)
        #expect(opts.minSize?.0 == 0 && opts.minSize?.1 == 0)
        #expect(display.nativeBounds == [-1920.0, 100.0, 3840.0, 2160.0])
    }

    // MARK: - WindowHandle (window/handle_tests.rs)

    @Test("WindowHandle: unbound handle queues requests for host or headless run")
    func unboundHandleQueuesRequestsForHostOrHeadlessRun() {
        let handle = RuneWindowHandle(key: "w")
        #expect(!handle.headlessPending)
        handle.focus()
        handle.setPosition((3, 4))
        #expect(handle.headlessPending)

        let taken = handle.takeHeadless()
        #expect(taken.count == 2)
        #expect(taken[0].slot == 0 && taken[0].request == .focus)
        #expect(taken[1].slot == 0 && taken[1].request == .setPosition(x: 3, y: 4))
        #expect(!handle.headlessPending && handle.takeHeadless().isEmpty)

        handle.hide()
        let next = handle.takeHeadless()
        #expect(next.count == 1 && next[0].request == .hide)
    }

    @Test("WindowHandle: bound handle flushes queued requests and unbinds cleanly")
    func boundHandleFlushesQueuedRequests() {
        final class Collector: @unchecked Sendable {
            var items: [(Int, WindowHandleRequest)] = []
        }
        let collector = Collector()
        let handle = RuneWindowHandle(key: "doc")
        handle.open()
        handle.resize((640, 480))
        handle.bind(slot: 2) { slot, req in
            collector.items.append((slot, req))
        }
        #expect(collector.items.count == 2)
        #expect(collector.items[0].0 == 2 && collector.items[0].1 == .open)
        #expect(collector.items[1].0 == 2 && collector.items[1].1 == .resize(width: 640, height: 480, animate: true))

        handle.setTitle("Updated")
        #expect(collector.items.count == 3 && collector.items[2].1 == .setTitle("Updated"))

        handle.unbind()
        #expect(!handle.isReady && handle.windowNumber == nil)
        handle.show()
        #expect(handle.headlessPending)
    }

    // MARK: - WindowRestMachine (#819 window/rest.rs)

    @Test("WindowRestMachine (#819): normal 10s rest, 1s low-memory press, unseen gives back all once")
    func windowRestStateMachineParity() {
        var machine = WindowRestMachine()
        #expect(machine.state == .rested && machine.deadline == nil)

        // Unseen while already rested emits nothing.
        #expect(machine.step(.unseen).isEmpty)

        // Frame drawn -> 10s deadline; waking before deadline emits nothing.
        #expect(machine.step(.drew(now: 100.0, lowMemory: false)).isEmpty)
        #expect(machine.deadline == 110.0)
        #expect(machine.step(.woke(now: 105.0)).isEmpty)
        #expect(machine.state == .drawing(due: 110.0))

        // Waking at deadline -> .idle + giveBackUnused once.
        #expect(machine.step(.woke(now: 110.0)) == [.giveBackUnused])
        #expect(machine.state == .idle && machine.deadline == nil)
        #expect(machine.step(.woke(now: 120.0)).isEmpty)

        // Going unseen while idle -> .rested + giveBackAll once.
        #expect(machine.step(.unseen) == [.giveBackAll])
        #expect(machine.state == .rested)
        #expect(machine.step(.unseen).isEmpty)

        // Low memory cuts deadline to 1s; going unseen while drawing gives back all.
        _ = machine.step(.drew(now: 200.0, lowMemory: true))
        #expect(machine.deadline == 201.0)
        #expect(machine.step(.unseen) == [.giveBackAll])
        #expect(machine.state == .rested)
    }

    // MARK: - OpenAs, Chrome, Titlebar, ChromeInsets, El.windowDrag

    @Test("OpenAs, Chrome, Titlebar, ChromeInsets & El.windowDrag")
    func openAsChromeTitlebarAndDragRegionParity() {
        var openAs = RuneOpenAs.normal
        openAs = openAs.maximized(true)
        #expect(openAs.maximizes && !openAs.fullScreens)
        openAs = openAs.fullScreen(true)
        #expect(openAs.maximizes && openAs.fullScreens)
        openAs = openAs.fullScreen(false)
        #expect(openAs == .maximized)

        let tb = RuneTitlebar(height: 38.0)
        let macChrome = tb.macChrome(.default)
        // y = round((38 - 14) / 2) = 12
        #expect(macChrome.fullSizeContent && macChrome.dragRegions)
        #expect(macChrome.trafficLights?.0 == 16.0 && macChrome.trafficLights?.1 == 12.0)
        #expect(macChrome.titlebarInset() == 16.0 + 2.0 * 23.0 + 14.0)

        let override = TitlebarSet(titlebar: nil, height: 44.0).over(tb)
        #expect(override.height == 44.0)

        let insets = RuneChromeInsets(leading: 76.0, trailing: 0.0, height: 38.0)
        let zoomed = insets.zoomed(2.0)
        #expect(zoomed.leading == 38.0 && zoomed.height == 19.0)
        #expect(insets.bits().count == 3)

        let dragEl = El<Int>().windowDrag()
        #expect(dragEl.isWindowDrag)
        #expect(!El<Int>().isWindowDrag)
        #expect(!dragEl.windowDrag(false).isWindowDrag)

        #expect(RuneChrome.usesDragRegions(chrome: macChrome, borderless: false, isPanel: false))
        #expect(!RuneChrome.usesDragRegions(chrome: macChrome, borderless: false, isPanel: true))
    }

    // MARK: - #836 RTL Traffic Lights & macOS Subclass Tests

    #if os(macOS)
    @Test("Traffic Lights (#836): RTL mirrors traffic lights to trailing edge with Close outermost")
    func rtlTrafficLightsGeometryParity() {
        let widths: [CGFloat] = [14.0, 14.0, 14.0]
        let ltr = RuneTrafficLights.computeOrigins(
            x: 16.0,
            y: 12.0,
            pitch: 23.0,
            buttonWidths: widths,
            parentWidth: 720.0,
            rtl: false
        )
        #expect(ltr.map(\.x) == [16.0, 39.0, 62.0])

        let rtl = RuneTrafficLights.computeOrigins(
            x: 16.0,
            y: 12.0,
            pitch: 23.0,
            buttonWidths: widths,
            parentWidth: 720.0,
            rtl: true
        )
        // Close at 720 - 16 - 14 = 690, Mini at 720 - 39 - 14 = 667, Zoom at 720 - 62 - 14 = 644
        #expect(rtl.map(\.x) == [690.0, 667.0, 644.0])
        #expect(rtl[0].x > rtl[1].x && rtl[1].x > rtl[2].x)

        let ltrInset = RuneTrafficLights.computeTitlebarInset(
            windowWidth: 720.0,
            zoomFrameInWindow: CGRect(x: 62.0, y: 694.0, width: 14.0, height: 14.0),
            fullScreen: false,
            fullSizeContent: true,
            zoomHidden: false,
            rtl: false
        )
        #expect(ltrInset == 76.0)

        let rtlInset = RuneTrafficLights.computeTitlebarInset(
            windowWidth: 720.0,
            zoomFrameInWindow: CGRect(x: 644.0, y: 694.0, width: 14.0, height: 14.0),
            fullScreen: false,
            fullSizeContent: true,
            zoomHidden: false,
            rtl: true
        )
        #expect(rtlInset == 76.0)

        #expect(RuneTrafficLights.computeTitlebarInset(
            windowWidth: 720.0,
            zoomFrameInWindow: CGRect(x: 62.0, y: 694.0, width: 14.0, height: 14.0),
            fullScreen: true,
            fullSizeContent: true,
            zoomHidden: false,
            rtl: false
        ) == 0.0)
    }

    @Test("Drag Regions (window/mac_tests.rs): subclass changes only the selected instance")
    func dragSubclassChangesOnlySelectedInstance() {
        let selected = NSObject()
        let sibling = NSObject()
        let base: AnyClass = object_getClass(selected)!
        let sel = sel_registerName("mouseDownCanMoveWindow")
        let originalMethod = class_getInstanceMethod(base, sel)

        RuneDragRegions.scopeDragRegions(on: selected)
        let scoped: AnyClass = object_getClass(selected)!
        #expect(ObjectIdentifier(scoped) != ObjectIdentifier(base))
        #expect(class_getSuperclass(scoped).map(ObjectIdentifier.init) == ObjectIdentifier(base))
        #expect(class_getInstanceSize(scoped) == class_getInstanceSize(base))
        #expect(object_getClass(sibling).map(ObjectIdentifier.init) == ObjectIdentifier(base))
        #expect(class_getInstanceMethod(base, sel) == originalMethod)

        let imp = class_getMethodImplementation(scoped, sel)!
        typealias MoveFn = @convention(c) (AnyObject, Selector) -> ObjCBool
        let fn = unsafeBitCast(imp, to: MoveFn.self)
        #expect(!fn(selected, sel).boolValue)

        // Idempotent when already scoped.
        RuneDragRegions.scopeDragRegions(on: selected)
        #expect(object_getClass(selected).map(ObjectIdentifier.init) == ObjectIdentifier(scoped))
    }

    @Test("ShadowResampleState (window_shape_tests.rs): resamples once after drawable lands")
    func shadowResampleStateMachineParity() {
        struct Sim {
            var state = ShadowResampleState()
            var acquired: UInt64 = 0
            var onScreen: UInt64 = 0
            var resamples = 0

            mutating func present() -> UInt64 {
                acquired += 1
                state.presented(acquired)
                return acquired
            }
            mutating func land(_ n: UInt64) { onScreen = max(onScreen, n) }
            mutating func turn() { if state.turn(onScreen: onScreen) { resamples += 1 } }
            mutating func frame() {
                let n = present()
                turn()
                land(n)
                turn()
            }
        }

        // First show resamples once its first frame is on screen.
        var sim = Sim()
        sim.state.shown(last: 0)
        sim.turn()
        #expect(sim.resamples == 0)
        let n = sim.present()
        sim.turn()
        #expect(sim.resamples == 0)
        sim.land(n)
        sim.turn()
        #expect(sim.resamples == 1)
        sim.turn()
        #expect(sim.resamples == 1)

        // Resize/scale waits for a frame drawn after it; live resize settles at end.
        var live = Sim()
        for _ in 0..<10 {
            live.state.redraw()
            let k = live.present()
            live.turn()
            live.state.redraw()
            live.land(k)
            live.turn()
        }
        #expect(live.resamples == 0)
        live.frame()
        #expect(live.resamples == 1)

        // Hiding cancels pending resample.
        var hidden = Sim()
        hidden.state.shown(last: 0)
        let h = hidden.present()
        hidden.state.hidden()
        hidden.land(h)
        hidden.turn()
        #expect(hidden.resamples == 0)
    }
    #endif
}
