import Foundation
import Rune
import Testing

@Suite("Desktop window groups")
struct DesktopWindowGroupTests {
    @Test func requestsKeepOrderBeforeTheHostBinds() {
        let h = WindowHandle(key: "inspector")
        h.minimize()
        h.place(PlaceRequest(position: Vec2(10, 20), size: Vec2(220, 140), activate: false))
        #expect(h.takeHeadless().map(\.request) == [
            .minimize, .setPosition(x: 10, y: 20), .resize(width: 220, height: 140, animate: false), .show
        ])
    }

    #if os(Windows) || os(Linux)
    private struct HandleObservation {
        var completed = false
        var placement: WindowPlacement?
        var clickThroughError: String?
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUNE_TEST_NATIVE_WINDOWS"] == "1"))
    @MainActor func liveHandleReadsPlacementAndChangesHitTesting() throws {
        let app = App(title: "Rune window placement", size: Vec2(180, 100), state: HandleObservation()) { _, _ in
            el().sizeFull()
        }.windowOptions(WindowOptions(borderless: true, clickThrough: true))
        let appHandle = app.handle()
        var ownerPlacement: WindowPlacement?
        var final = HandleObservation()
        let spec = AppWindowSpec.fromApp("placement", app).onReady { handle in
            ownerPlacement = handle.placement()
            do { try handle.setClickThrough(false) } catch { Issue.record(error) }
            DispatchQueue.global().async {
                var observation = HandleObservation(completed: true, placement: handle.placement())
                do {
                    try handle.setClickThrough(true)
                    try handle.setClickThrough(false)
                } catch {
                    observation.clickThroughError = error.localizedDescription
                }
                appHandle.update { state, tx in state = observation; tx.quit() }
            }
        }.onQuit { state, _ in final = state }.boxed()
        let stopwatch = DispatchWorkItem { appHandle.quit() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: stopwatch)
        defer { stopwatch.cancel() }
        try RuneMultiWindow.runWindows([spec], arguments: [])
        #expect(final.completed)
        #expect(final.clickThroughError == nil)
        #expect(spec.handle.placement() == nil)

        #if os(Linux)
        let env = ProcessInfo.processInfo.environment
        if env["SDL_VIDEODRIVER"] == "wayland" || (env["SDL_VIDEODRIVER"] == nil && env["WAYLAND_DISPLAY"] != nil && ownerPlacement == nil) {
            #expect(ownerPlacement == nil)
            #expect(final.placement == nil)
            return
        }
        #endif
        let placement = try #require(ownerPlacement)
        let background = try #require(final.placement)
        #expect(placement.scale > 0 && placement.contentSize.0 > 0 && placement.contentSize.1 > 0)
        #expect(placement.display != nil)
        #expect(background.contentSize == placement.contentSize)
        #expect(background.display?.0.0 == placement.display?.0.0)
    }

    // This test needs a window server and owns the process-wide event queue.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUNE_TEST_NATIVE_WINDOWS"] == "1"))
    @MainActor func staticAndDynamicWindowsPresentOnOneNativeLoop() throws {
        let cold = ["rune-test://notification/first", "rune-test://notification/second"]
        let forwarded = "rune-test://notification/forwarded"
        var received: [String] = []
        var secondaryLinks: [String] = []
        let primary = App(title: "Rune Group Primary", size: Vec2(160, 100), state: 0) { _, _ in
            el().sizeFull().bg(Color(r: 1, g: 0, b: 0, a: 1))
        }.onOpenUrl { _, url, _ in received.append(url) }
        let appHandle = primary.handle()
        var ready = Set<String>()
        var reusedHandle = false
        func presented(_ handle: WindowHandle) {
            ready.insert(handle.key)
            if ready.count == 3 {
                SingleInstance.handleForwardedArguments([forwarded])
                // Process the forwarded hook before quitting the shared event loop.
                appHandle.update { _, _ in appHandle.quit() }
            }
        }
        let dynamic = AppWindowSpec(key: "dynamic", app: AppSpec(size: Vec2(120, 80), state: 1) { _, _ in
            el().sizeFull().bg(Color(r: 0, g: 0, b: 1, a: 1))
        }).onOpenUrl { _, url, _ in secondaryLinks.append(url) }.onReady(presented)
        let main = AppWindowSpec.fromApp("primary", primary).onReady { handle in
            presented(handle)
            let first = RuneMultiWindow.openWindow(dynamic)
            reusedHandle = RuneMultiWindow.openWindow(dynamic) === first
        }
        let child = AppWindowSpec(key: "inspector", app: AppSpec(size: Vec2(160, 80), state: "inspector") { _, _ in
            el().sizeFull().bg(Color(r: 0, g: 1, b: 0, a: 1))
        }).onOpenUrl { _, url, _ in secondaryLinks.append(url) }.onReady(presented)
        let (root, handle) = main.window(child)
        // Also exercise an external handle which posted a request before native initialization.
        handle.setTitle("Rune Group Inspector")
        let watchdog = DispatchWorkItem { appHandle.quit() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        defer { watchdog.cancel() }
        try RuneMultiWindow.runWindowsWithArgs(arguments: [cold[0], "unrelated", cold[1]]) { (displays: [DisplayInfo]) in
            #expect(displays.contains { $0.primary && $0.id != nil && $0.size.0 > 0 && $0.scale > 0 })
            return [root.boxed()]
        }
        #expect(ready == ["primary", "inspector", "dynamic"])
        #expect(reusedHandle)
        #expect(!handle.isReady)
        #expect(received == cold + [forwarded])
        #expect(secondaryLinks.isEmpty)
    }
    #endif
}
