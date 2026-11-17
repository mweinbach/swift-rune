import Dispatch
import Foundation
import Rune
import WinSDK

// On Windows run `swift run --package-path Tests/Support/WindowsWindowFrame`.
// The worker reads the actual HWND of this process on a private, unswitched desktop.
@main
enum FrameProbe {
    private static func log(_ message: String) {
        FileHandle.standardOutput.write(Data("\(message)\n".utf8))
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
        ExitProcess(1)
    }

    private static func runOnTestDesktop() {
        let name = "RuneWindowFrame-\(GetCurrentProcessId())"
        var nameUTF16 = Array(name.utf16) + [0]
        let desktop = nameUTF16.withUnsafeBufferPointer {
            CreateDesktopW($0.baseAddress, nil, nil, 0, DWORD(GENERIC_ALL), nil)
        }
        guard let desktop else { fail("CreateDesktopW error \(GetLastError())") }
        defer { CloseDesktop(desktop) }

        var executable = [WCHAR](repeating: 0, count: 32_768)
        let count = GetModuleFileNameW(nil, &executable, DWORD(executable.count))
        guard count > 0, count < executable.count else { fail("GetModuleFileNameW") }
        var command = Array("\"frame-probe\" --probe".utf16) + [0]
        var process = PROCESS_INFORMATION()
        var start = STARTUPINFOW()
        start.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        start.dwFlags = DWORD(STARTF_USESTDHANDLES)
        start.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE)
        start.hStdError = GetStdHandle(STD_ERROR_HANDLE)
        start.hStdInput = GetStdHandle(STD_INPUT_HANDLE)
        let launched = nameUTF16.withUnsafeMutableBufferPointer {
            start.lpDesktop = $0.baseAddress
            return CreateProcessW(&executable, &command, nil, nil, true, 0, nil, nil, &start, &process)
        }
        guard launched else { fail("CreateProcessW error \(GetLastError())") }
        defer { CloseHandle(process.hThread); CloseHandle(process.hProcess) }
        guard WaitForSingleObject(process.hProcess, 180_000) == WAIT_OBJECT_0 else {
            TerminateProcess(process.hProcess, 2)
            fail("Window host timed out")
        }
        var status: DWORD = 1
        guard GetExitCodeProcess(process.hProcess, &status), status == 0 else { fail("Child exit \(status)") }
    }

    private struct Geometry: CustomStringConvertible {
        var client: RECT
        var clientOrigin: POINT
        var outer: RECT
        var monitor: RECT
        var dpi: UINT

        init(_ hwnd: HWND) {
            var client = RECT(), outer = RECT(), monitor = MONITORINFO(), origin = POINT()
            monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
            guard GetClientRect(hwnd, &client), GetWindowRect(hwnd, &outer), ClientToScreen(hwnd, &origin),
                  GetMonitorInfoW(MonitorFromWindow(hwnd, DWORD(MONITOR_DEFAULTTONEAREST)), &monitor)
            else { fail("Could not read native window geometry") }
            self.client = client
            self.clientOrigin = origin
            self.outer = outer
            self.monitor = monitor.rcMonitor
            self.dpi = GetDpiForWindow(hwnd)
        }

        func hasContent(_ width: Float, _ height: Float) -> Bool {
            let scale = Float(dpi) / 96
            return client.right - client.left == Int32((width * scale).rounded()) &&
                client.bottom - client.top == Int32((height * scale).rounded())
        }

        var centered: Bool {
            let spareWidth = (monitor.right - monitor.left) - (outer.right - outer.left)
            let spareHeight = (monitor.bottom - monitor.top) - (outer.bottom - outer.top)
            return outer.left == monitor.left + spareWidth / 2 && outer.top == monitor.top + spareHeight / 4
        }

        var description: String {
            "client \(client.right)x\(client.bottom), outer [\(outer.left),\(outer.top),\(outer.right),\(outer.bottom)], DPI \(dpi)"
        }
    }

    private final class LayoutReadback: @unchecked Sendable {
        private let lock = NSLock()
        private var local: [Float] = []
        private var screen: [Float] = []

        func localChanged(_ rect: [Float]) { lock.withLock { local = rect } }
        func screenChanged(_ rect: [Float]) { lock.withLock { screen = rect } }
        func matches(_ geometry: Geometry) -> Bool {
            lock.withLock {
                guard local.count == 4, screen.count == 4 else { return false }
                let scale = Float(geometry.dpi) / 96
                return abs((screen[0] - local[0]) * scale - Float(geometry.clientOrigin.x)) < 0.5 &&
                    abs((screen[1] - local[1]) * scale - Float(geometry.clientOrigin.y)) < 0.5
            }
        }
    }

    private static func waitFor(_ hwnd: HWND, _ label: String, _ matches: (Geometry) -> Bool) {
        let deadline = GetTickCount64() + 10_000
        while true {
            let geometry = Geometry(hwnd)
            if matches(geometry) {
                log("PASS \(label)  \(geometry)")
                return
            }
            if GetTickCount64() >= deadline { fail("\(label) timed out with \(geometry)") }
            Sleep(10)
        }
    }

    // The window procedure accesses these values exclusively on its owning UI thread.
    nonisolated(unsafe) private static var insideModalSize = false
    nonisolated(unsafe) private static var resizeDepth = 0
    nonisolated(unsafe) private static var paintedInSize = false
    private static let queryModalPaint = UINT(WM_APP) + 0x610

    private static func observePaint(of hwnd: HWND) {
        guard SetWindowSubclass(hwnd, { hwnd, message, w, l, _, _ in
            switch message {
            case UINT(WM_ENTERSIZEMOVE):
                FrameProbe.insideModalSize = true
                FrameProbe.paintedInSize = false
            case UINT(WM_EXITSIZEMOVE):
                FrameProbe.insideModalSize = false
            case UINT(WM_SIZE) where FrameProbe.insideModalSize:
                FrameProbe.resizeDepth += 1
                defer { FrameProbe.resizeDepth -= 1 }
                return DefSubclassProc(hwnd, message, w, l)
            case UINT(WM_PAINT) where FrameProbe.resizeDepth > 0:
                FrameProbe.paintedInSize = true
            case FrameProbe.queryModalPaint:
                return FrameProbe.paintedInSize ? 1 : 0
            default:
                break
            }
            return DefSubclassProc(hwnd, message, w, l)
        }, 1, 0) else { fail("Could not attach WM_PAINT observer") }
    }

    private static func checkModalResize(of hwnd: HWND) {
        let before = Geometry(hwnd)
        SendMessageW(hwnd, UINT(WM_ENTERSIZEMOVE), 0, 0)
        defer { SendMessageW(hwnd, UINT(WM_EXITSIZEMOVE), 0, 0) }
        guard SetWindowPos(hwnd, nil, 0, 0, before.outer.right - before.outer.left - 20,
                           before.outer.bottom - before.outer.top - 20,
                           UINT(SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE)),
              SendMessageW(hwnd, queryModalPaint, 0, 0) == 1 else {
            fail("Expected WM_PAINT before the modal WM_SIZE returned")
        }
        log("PASS native modal resize painted before WM_SIZE returned")
    }

    @MainActor static func main() throws {
        guard CommandLine.arguments.dropFirst().contains("--probe") else {
            runOnTestDesktop()
            return
        }
        let checkScreenLayout = !CommandLine.arguments.contains("--geometry-only")
        log("Creating Rune window. Screen layout readback \(checkScreenLayout ? "enabled" : "disabled").")
        let title = "Rune frame fixture \(GetCurrentProcessId())"
        let options = WindowOptions(minSize: Vec2(240, 140), maxSize: Vec2(440, 320))
        let layout = LayoutReadback()
        let app = App(title: title, size: Vec2(300, 200), state: 0) { _, _ in
            let content: El<Int> = el().wFull().hFull().bg(.white)
            guard checkScreenLayout else { return content }
            return content.onLayout { _, rect in layout.localChanged(rect) }
                .onScreenLayout { _, rect in layout.screenChanged(rect) }
        }.windowOptions(options).openInactive().onWindow { _ in log("Rune window bound") }
        let updates = app.sharedHandle
        try app.onReady { window in
            log("Rune first frame ready")
            guard let ready = title.withCString(encodedAs: UTF16.self, { FindWindowW(nil, $0) }) else {
                fail("The ready Rune window has no matching HWND")
            }
            observePaint(of: ready)
            DispatchQueue.global().async {
                guard let hwnd = title.withCString(encodedAs: UTF16.self, { FindWindowW(nil, $0) }) else {
                    fail("The ready Rune window has no matching HWND")
                }
                let previousDPI = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(hwnd))
                defer {
                    if let previousDPI { _ = SetThreadDpiAwarenessContext(previousDPI) }
                }
                waitFor(hwnd, "initial content") { $0.hasContent(300, 200) }
                if checkScreenLayout {
                    waitFor(hwnd, "initial screen layout matches ClientToScreen") { layout.matches($0) }
                }

                updates.update { state, tx in
                    state += 1
                    tx.resizeWindow((1000, 90))
                    tx.centerWindow()
                }
                waitFor(hwnd, "Tx clamps and centers the decorated window") {
                    $0.hasContent(440, 140) && $0.centered
                }
                updates.update { state, tx in
                    state += 1
                    tx.resizeWindowInstant((281.5, 210.5))
                }
                waitFor(hwnd, "Tx instant resize scales fractional points") { $0.hasContent(281.5, 210.5) }

                window.resize((180, 420))
                waitFor(hwnd, "handle clamps both axes") { $0.hasContent(240, 320) }
                window.resizeInstant((340, 260))
                waitFor(hwnd, "handle instant resize") { $0.hasContent(340, 260) }
                window.center()
                waitFor(hwnd, "handle center preserves content size") { $0.hasContent(340, 260) && $0.centered }
                if checkScreenLayout {
                    waitFor(hwnd, "moved screen layout matches ClientToScreen") { layout.matches($0) }
                }
                checkModalResize(of: hwnd)
                window.close()
            }
        }.run(arguments: [])
    }
}
