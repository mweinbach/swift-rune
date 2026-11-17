import Dispatch
import Foundation
import Rune
import WinSDK

// Run on an interactive Windows desktop with `swift run --package-path Tests/Support/WindowsPopupWindowHandle`.
@main
enum WindowsPopupWindowHandle {
    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var dismissed: [Int] = []

        func record(_ sequence: Int, selected: String?) {
            if let selected { fail("Unexpected selection \(selected)") }
            lock.withLock { dismissed.append(sequence) }
        }

        var values: [Int] { lock.withLock { dismissed } }
    }

    private final class CloseAttempts: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts: [Int] = []

        func allowClose(of primary: Int) -> Bool {
            lock.withLock {
                let allow = primary == 1 || attempts.contains(primary)
                attempts.append(primary)
                return allow
            }
        }

        var values: [Int] { lock.withLock { attempts } }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Windows popup handle regression: \(message)\n".utf8))
        ExitProcess(1)
    }

    private static func open(_ sequence: Int, using app: AppHandle<Int>, answers: Answers) {
        app.update { _, tx in
            tx.popupMenu(PopupMenu().item("action", "Action"), at: Vec2(24, 24)) { (_: inout Int, picked, _) in
                answers.record(sequence, selected: picked)
            }
        }
    }

    private static func visiblePopup(on thread: DWORD) -> HWND? {
        "#32768".withCString(encodedAs: UTF16.self) { menuClass in
            var previous: HWND?
            while let popup = FindWindowExW(nil, previous, menuClass, nil) {
                if GetWindowThreadProcessId(popup, nil) == thread && IsWindowVisible(popup) { return popup }
                previous = popup
            }
            return nil
        }
    }

    private static func waitFor(_ description: String, _ predicate: () -> Bool) {
        let start = GetTickCount64()
        while !predicate() {
            guard GetTickCount64() - start < 10_000 else { fail("Timed out waiting for \(description)") }
            Sleep(10)
        }
    }

    @MainActor
    static func main() throws {
        try closePopupOwner()
        try closeOtherPrimaries()
        print("PASS Worker placement preserved native tracking. Worker hide, owner close and final primary close each dismissed one popup.")
    }

    @MainActor
    private static func closePopupOwner() throws {
        let answers = Answers()
        let title = "Worker popup handle probe \(GetCurrentProcessId())"
        let app = App(title: title, size: Vec2(240, 140), state: 0) { _, _ in
            text("Window handle during native popup tracking")
        }.openInactive()
        let handle = app.sharedHandle
        try app.onReady { window in
            let ownerThread = GetCurrentThreadId()
            // A broken synchronous placement call can block its worker forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 35) {
                if answers.values != [1, 2] { fail("Worker or native menu loop did not return") }
            }
            DispatchQueue.global().async {
                guard let owner = title.withCString(encodedAs: UTF16.self, { FindWindowW(nil, $0) }),
                      GetWindowThreadProcessId(owner, nil) == ownerThread else { fail("Owner window unavailable") }
                open(1, using: handle, answers: answers)
                waitFor("the first native popup") { visiblePopup(on: ownerThread) != nil }
                guard let popup = visiblePopup(on: ownerThread) else { fail("Native popup closed early") }
                FileHandle.standardOutput.write(Data("Native popup visible. Worker requesting window placement.\n".utf8))

                let start = GetTickCount64()
                guard let placement = window.placement(), placement.contentSize.0 > 0, placement.contentSize.1 > 0 else {
                    fail("Worker did not receive the visible window's placement")
                }
                let elapsed = GetTickCount64() - start
                guard elapsed < 5_000, visiblePopup(on: ownerThread) == popup, answers.values.isEmpty else {
                    fail("Querying window placement stalled or dismissed the native popup")
                }
                print("Placement returned after \(elapsed) ms with the same native popup visible.")
                window.hide()
                waitFor("hide to dismiss the menu once") {
                    answers.values == [1] && visiblePopup(on: ownerThread) == nil && !IsWindowVisible(owner)
                }

                window.show()
                waitFor("the owner window to reappear") { IsWindowVisible(owner) }
                open(2, using: handle, answers: answers)
                waitFor("the second native popup") { visiblePopup(on: ownerThread) != nil }
                window.close()
            }
        }.run(arguments: [])
        guard answers.values == [1, 2] else { fail("Expected one cancellation per menu, got \(answers.values)") }
    }

    @MainActor
    private static func closeOtherPrimaries() throws {
        let answers = Answers()
        let attempts = CloseAttempts()
        func primary(_ id: Int) -> AnyWindowSpec {
            let app = App(title: "Primary \(id)", size: Vec2(180, 100), state: 0) { _, _ in
                text("Primary \(id)")
            }.openInactive().onClose { _, _ in attempts.allowClose(of: id) }
            return AppWindowSpec(app: app).boxed()
        }
        let first = primary(1), last = primary(2)
        let firstHandle = first.handle, lastHandle = last.handle
        let secondary = App(title: "Secondary popup owner", size: Vec2(240, 140), state: 0) { _, _ in
            text("Secondary hosting a native popup")
        }.openInactive()
        let appHandle = secondary.sharedHandle
        let secondarySpec = AppWindowSpec(app: secondary).onReady { window in
            let ownerThread = GetCurrentThreadId()
            DispatchQueue.global().asyncAfter(deadline: .now() + 35) {
                if answers.values != [3] { fail("Secondary popup kept the window group alive") }
            }
            DispatchQueue.global().async {
                open(3, using: appHandle, answers: answers)
                waitFor("the secondary native popup") { visiblePopup(on: ownerThread) != nil }
                guard let popup = visiblePopup(on: ownerThread) else { fail("Secondary popup closed early") }
                firstHandle.close()
                waitFor("the first primary to accept its close") { attempts.values == [1] }
                guard window.placement() != nil, visiblePopup(on: ownerThread) == popup, answers.values.isEmpty else {
                    fail("Closing the first primary dismissed the secondary popup")
                }
                lastHandle.close()
                waitFor("the last primary to veto its close") { attempts.values == [1, 2] }
                guard window.placement() != nil, visiblePopup(on: ownerThread) == popup, answers.values.isEmpty else {
                    fail("Vetoing the last primary close dismissed the secondary popup")
                }
                lastHandle.close()
            }
        }
        try RuneMultiWindow.runWindows([first, last, AnyWindowSpec(secondarySpec, secondary: true)], arguments: [])
        guard attempts.values == [1, 2, 2], answers.values == [3] else {
            fail("Unexpected primary close attempts \(attempts.values) or secondary dismissals \(answers.values)")
        }
    }
}
