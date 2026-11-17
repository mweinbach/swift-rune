import Foundation
import Rune
import StartupDriver
import WinSDK

@MainActor
func exerciseStartup(grouped: Bool) throws {
    var events: [String] = []
    var sibling: WindowHandle?
    let app = App<Int>("Rune startup ordering fixture", size: Vec2(96, 72), init: { 0 }, view: { state, _ in
        el().wFull().hFull().bg(state == 0 ? .black : .white)
    })
    .windowOptions(WindowOptions(minSize: Vec2(64, 48), position: (20, 40)))
    .openInactive(true)
    .onWindow { _ in
        precondition(startup_observe_paint() != 0, "could not observe the app's window procedure")
        events.append("created")
    }
    .onKey { state, event, _ in
        guard event.key == .f(6) else { return false }
        events.append("key")
        state += 1
        return true
    }
    .onFrameDrawn { runtime in
        if events.last == "created" {
            // Posted from inside the first actual presentation. It cannot dispatch
            // until the window procedure returns to the host's message loop.
            precondition(startup_is_painting() != 0 && startup_post_key() != 0)
            events.append("first frame")
        } else if events.last == "key" && runtime.state == 1 {
            events.append("key frame")
        }
    }
    .onReady { handle in
        events.append(startup_is_painting() == 0 ? "ready" : "ready inside WM_PAINT")
        sibling?.close()
        handle.close()
    }
    if grouped {
        let second = App<Int>("Rune startup sibling", size: Vec2(96, 72), init: { 0 }, view: { _, _ in el() })
            .windowOptions(WindowOptions(minSize: Vec2(64, 48), position: (250, 40)))
            .openInactive(true)
            .onWindow { sibling = $0 }
        try runWindowsWithArgs(arguments: []) { (_: ToolingArgs) in
            [AnyWindowSpec(.fromApp(app)), AnyWindowSpec(.fromApp(second))]
        }
        precondition(sibling != nil)
    } else {
        try app.run(arguments: [])
    }
    let mode = grouped ? "window group" : "single window"
    print("\(mode) startup events: \(events)")
    precondition(events == ["created", "first frame", "key", "key frame", "ready"],
                 "\(mode) received \(events)")
}

@MainActor
func exerciseHiddenStartup() throws {
    var opened = 0.0
    var readyCalls = 0
    var frames = 0
    var window: WindowHandle?
    let app = App<Int>("Rune hidden startup fixture", size: Vec2(96, 72), init: { 0 }, view: { _, _ in
        el().wFull().hFull().bg(.white)
    })
    .windowOptions(WindowOptions(visible: false))
    .openInactive(true)
    .onWindow { handle in
        opened = ProcessInfo.processInfo.systemUptime
        window = handle
    }
    .onReady { handle in
        readyCalls += 1
        let wait = ProcessInfo.processInfo.systemUptime - opened
        precondition(wait < 3 && readyCalls == 1 && frames == 0 && !handle.isReady,
                     "hidden ready at \(wait)s, callbacks=\(readyCalls) frames=\(frames) isReady=\(handle.isReady)")
        print("hidden onReady after \(wait)s, before first presentation")
        handle.show()
    }
    .onFrameDrawn { _ in
        frames += 1
        precondition(readyCalls == 1 && window?.isReady == true)
        window?.close()
    }
    try app.run(arguments: [])
    precondition(frames > 0 && readyCalls == 1)
    print("hidden window shown, \(frames) frame(s) and one ready callback")
}

if let mode = CommandLine.arguments.dropFirst().first {
    if mode == "hidden" { try exerciseHiddenStartup() }
    else if mode == "shell" { try exerciseShellRequests() }
    else { try exerciseStartup(grouped: mode == "group") }
} else {
    var failures: [String] = []
    for mode in ["single", "group", "hidden", "shell"] {
        let result = (Array(mode.utf16) + [0]).withUnsafeBufferPointer { startup_launch_child(nil, $0.baseAddress) }
        if result != 0 { failures.append("\(mode)=\(result)") }
    }
    if !failures.isEmpty {
        FileHandle.standardError.write(Data("Failed startup scenarios: \(failures.joined(separator: ", "))\n".utf8))
        ExitProcess(1)
    }
}
