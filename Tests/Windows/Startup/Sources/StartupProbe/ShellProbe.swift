import Dispatch
import Foundation
import Rune
import WinSDK

private func waitForShell(_ label: String, _ ready: () -> Bool) {
    let deadline = GetTickCount64() + 5_000
    while !ready() {
        precondition(GetTickCount64() < deadline, "timed out waiting for \(label)")
        Sleep(10)
    }
}

private func nativeTitle(_ window: HWND) -> String {
    var utf16 = [WCHAR](repeating: 0, count: 256)
    let count = GetWindowTextW(window, &utf16, Int32(utf16.count))
    return String(decoding: utf16.prefix(Int(count)), as: UTF16.self)
}

@MainActor
func exerciseShellRequests() throws {
    let specs: [(String, WindowOptions)] = [
        ("ordinary", WindowOptions(minSize: Vec2(60, 40), position: (10, 10))),
        ("hidden", WindowOptions(visible: false)),
        ("borderless", WindowOptions(minSize: Vec2(60, 40), borderless: true, position: (150, 10))),
        ("fixed", WindowOptions(minSize: Vec2(60, 40), minimizable: false, position: (290, 10))),
    ]
    let names = specs.map { "Rune shell \($0.0) \(GetCurrentProcessId())" }
    var apps = specs.enumerated().map { index, spec in
        App<Int>(names[index], size: Vec2(96, 72), init: { 0 }, view: { _, _ in el() })
            .windowOptions(spec.1).openInactive(true)
    }
    let handles = apps.map { $0.handle() }
    apps[0] = apps[0].onReady { _ in
        DispatchQueue.global().async {
            let windows: [HWND] = names.map { name in
                var result: HWND?
                waitForShell(name) {
                    result = name.withCString(encodedAs: UTF16.self) { FindWindowW(nil, $0) }
                    return result != nil
                }
                return result!
            }
            for index in [1, 2, 3] {
                let window = windows[index], handle = handles[index]
                let name = "Changed \(names[index])"
                handle.minimize()
                handle.update { _, tx in tx.setTitle(name); tx.minimize() }
                waitForShell(name) { nativeTitle(window) == name }
                // Another acknowledged update ensures the previous shell turn completed.
                let acknowledged = name + " acknowledged"
                handle.update { _, tx in tx.setTitle(acknowledged) }
                waitForShell(acknowledged) { nativeTitle(window) == acknowledged }
                precondition(!IsIconic(window))
                precondition(IsWindowVisible(window) == (index != 1))
            }
            handles[0].update { _, tx in tx.minimize() }
            waitForShell("ordinary window minimization") { IsIconic(windows[0]) }
            print("PASS native titles while hidden, no minimize for hidden/borderless/disabled, normal minimize")
            handles[0].quit()
        }
    }
    let batch = apps.map { AnyWindowSpec(.fromApp($0)) }
    try runWindowsWithArgs(arguments: []) { (_: ToolingArgs) in batch }
}
