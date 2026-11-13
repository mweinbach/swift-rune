#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import RuneMac

@Suite("RuneMac Tests")
struct RuneMacTests {
    @Test func parsesAppKitFrameStrings() {
        let size = WindowFramePersistence.parseSize(from: "1645 0 716 1084 0 0 1728 1084 ")
        #expect(size == WindowFrameSize(width: 716, height: 1084))

        let rect = WindowFramePersistence.parseRect(from: "1645 0 716 1084 0 0 1728 1084 ")
        #expect(rect == CGRect(x: 1645, y: 0, width: 716, height: 1084))

        #expect(WindowFramePersistence.parseSize(from: "12 30") == nil)
        #expect(WindowFramePersistence.parseSize(from: "") == nil)
        #expect(WindowFramePersistence.parseSize(from: "0 0 0 100") == nil)
    }

    @Test func readsSavedSizeFromIsolatedUserDefaults() {
        let suiteName = "rune-mac-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("100 200 900 600 0 0 1920 1080 ", forKey: "NSWindow Frame MainWindow")
        let size = RuneMac.savedSize(named: "MainWindow", userDefaults: defaults)
        #expect(size == WindowFrameSize(width: 900, height: 600))
        #expect(RuneMac.savedSize(named: "Missing", userDefaults: defaults) == nil)
    }

    @Test func multiDisplayClampingKeepsWindowWithinBestScreen() {
        let primary = CGRect(x: 0, y: 0, width: 1728, height: 1080)
        let secondary = CGRect(x: 1728, y: 0, width: 2560, height: 1440)
        let screens = [primary, secondary]

        // Off-screen to the left on primary
        let offLeft = CGRect(x: -300, y: 100, width: 800, height: 600)
        let clampedLeft = RuneMac.clampFrame(offLeft, toVisibleFrames: screens)
        #expect(clampedLeft == CGRect(x: 0, y: 100, width: 800, height: 600))

        // Mostly on secondary display, sticking out the top-right
        let onSecondary = CGRect(x: 3800, y: 1000, width: 800, height: 600)
        let clampedSecondary = RuneMac.clampFrame(onSecondary, toVisibleFrames: screens)
        #expect(clampedSecondary == CGRect(x: 1728 + 2560 - 800, y: 1440 - 600, width: 800, height: 600))

        // Larger than primary screen -> shrunk to fit
        let oversized = CGRect(x: 100, y: 100, width: 3000, height: 2000)
        let clampedOversized = RuneMac.clampFrame(oversized, toVisibleFrames: [primary])
        #expect(clampedOversized == primary)

        // Completely disconnected from all screens -> falls back to first screen
        let disconnected = CGRect(x: 9000, y: 9000, width: 400, height: 300)
        let clampedDisconnected = RuneMac.clampFrame(disconnected, toVisibleFrames: screens)
        #expect(primary.contains(clampedDisconnected))
    }

    #if os(macOS)
    @Test func busyMarkerCreatesAndRemovesPidFile() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-mac-busy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let pid: Int32 = 42424
        #expect(!AppLifecycleHelpers.isBusy(pid: pid, homeDirectory: tempHome))

        AppLifecycleHelpers.setBusy(true, pid: pid, homeDirectory: tempHome)
        #expect(AppLifecycleHelpers.isBusy(pid: pid, homeDirectory: tempHome))

        AppLifecycleHelpers.setBusy(false, pid: pid, homeDirectory: tempHome)
        #expect(!AppLifecycleHelpers.isBusy(pid: pid, homeDirectory: tempHome))
    }
    #endif

    @Test func relaunchPlanHandlesAppBundleAndRawExecutable() {
        let bundlePlan = AppLifecycleHelpers.relaunchPlan(
            bundlePath: "/Applications/Rune.app",
            executablePath: "/Applications/Rune.app/Contents/MacOS/Rune",
            arguments: ["--workspace", "/tmp"],
            quiet: true
        )
        #expect(bundlePlan?.executablePath == "/usr/bin/open")
        #expect(bundlePlan?.arguments == ["-n", "-g", "/Applications/Rune.app", "--args", "--workspace", "/tmp"])
        #expect(bundlePlan?.environmentOverrides[AppLifecycleHelpers.quietEnvVar] == "1")

        let cliPlan = AppLifecycleHelpers.relaunchPlan(
            bundlePath: "/usr/local/bin",
            executablePath: "/usr/local/bin/rune",
            arguments: ["--help"],
            quiet: false
        )
        #expect(cliPlan?.executablePath == "/usr/local/bin/rune")
        #expect(cliPlan?.arguments == ["--help"])
        #expect(cliPlan?.environmentOverrides.isEmpty == true)
    }

    @Test func reexportsRuneNotify() {
        let mock = MockNotificationBackend()
        let service = NotificationService(backend: mock)
        #expect(service.post(Notification(id: "mac-1", title: "Hello")))
        #expect(mock.activeNotifications.count == 1)
    }

    @Test("RuneMac resolvedHomeDirectory honors HOME environment override")
    func runeMacHomeEnvResolution() {
        let resolved = AppLifecycleHelpers.resolvedHomeDirectory(
            explicit: nil,
            environment: ["HOME": "/tmp/custom-rune-home"]
        )
        #expect(resolved.path == "/tmp/custom-rune-home")
    }
}
